--[[ Matching raidres names to the people in the raid.

     raidres names are whatever someone typed when they signed up: a typo, an
     accent the keyboard didn't have, last week's alt. Unmatched, that person
     shows twice in the window -- in the raid with nothing reserved, and on
     the list as someone who isn't here -- and RollFor gives their reserves to
     nobody.

     So, the way RollFor does it: raid members who aren't on the list are
     paired with signups who aren't in the raid, by how alike the names are.
     Then the fetched list is renamed to the in-game names before anything
     else sees it, so the window counts the right person and RollFor gets
     exact names, with nothing left for its own matcher to guess at.

     A pair is matched only when it's clear-cut: alike enough, and clearly
     better than any other pairing for both of them. Anything less is offered
     as a guess, and the leader settles it from the window. Those choices are
     kept in RaidResBridge_Names, keyed by the raidres name, across sessions:
     the same person tends to sign up the same way every week. ]]

local RB = RaidResBridge

RaidResBridge_Names = RaidResBridge_Names or {}

local AUTO = 0.75     -- this alike, and unambiguous, is matched outright
local GUESS = 0.6     -- this alike is offered as a guess
RB.NameGuess = GUESS
local MARGIN = 0.1    -- how much better than the next pairing a match must be

-- ---------------------------------------------------------------------------
-- How alike two names are
-- ---------------------------------------------------------------------------

--[[ Accented letters, folded to the plain ones. WoW names may use the
     Latin-1 letters, which UTF-8 spells as \195 and one more byte; a
     signup typed without the accent should still be the same person. ]]
local FOLD = {}
do
    local plain = {
        "a", "a", "a", "a", "a", "a", "ae", "c", "e", "e", "e", "e", "i", "i", "i", "i",
        "d", "n", "o", "o", "o", "o", "o", "", "o", "u", "u", "u", "u", "y", "th", "ss",
    }
    for i = 1, 32 do
        FOLD[127 + i] = plain[i]          -- U+00C0 .. U+00DF
        FOLD[159 + i] = plain[i]          -- U+00E0 .. U+00FF, the same letters
    end
    FOLD[159 + 24] = ""                   -- the division sign
    FOLD[159 + 32] = "y"
end

--- A name reduced to lower-case plain letters, for comparing.
function RB.FoldName(name)
    local s = string.gsub(name or "", "\195([\128-\191])", function(c)
        return FOLD[string.byte(c)] or ""
    end)
    s = string.lower(s)
    return (string.gsub(s, "[^a-z]", ""))
end

local function levenshtein(a, b)
    local la, lb = string.len(a), string.len(b)
    if la == 0 then return lb end
    if lb == 0 then return la end
    local prev = {}
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        local cur = { [0] = i }
        local ca = string.byte(a, i)
        for j = 1, lb do
            local cost = (ca == string.byte(b, j)) and 0 or 1
            local v = prev[j] + 1
            if cur[j - 1] + 1 < v then v = cur[j - 1] + 1 end
            if prev[j - 1] + cost < v then v = prev[j - 1] + cost end
            cur[j] = v
        end
        prev = cur
    end
    return prev[lb]
end

--- 1 for the same name (accents and case aside), down to 0.
function RB.NameScore(a, b)
    local fa, fb = RB.FoldName(a), RB.FoldName(b)
    if fa == "" or fb == "" then return 0 end
    if fa == fb then return 1 end
    local longest = string.len(fa)
    if string.len(fb) > longest then longest = string.len(fb) end
    return 1 - levenshtein(fa, fb) / longest
end

-- ---------------------------------------------------------------------------
-- Pairing them up
-- ---------------------------------------------------------------------------

local function key(name)
    return string.lower(string.gsub(name or "", "%s", ""))
end

--[[ Pair signups who aren't in the raid with raid members who aren't on
     the list.

     Returns matches -- signup key -> { signup, name, how = "manual" or
     "auto", score } -- and guesses -- signup key -> { signup, name, score }
     for the ones it wasn't sure enough to match. ]]
function RB.MatchNames(listNames, rosterNames)
    local onList, inRoster = {}, {}
    for _, n in ipairs(listNames) do onList[key(n)] = true end
    for _, n in ipairs(rosterNames) do inRoster[key(n)] = n end

    local signups, members = {}, {}
    for _, n in ipairs(listNames) do
        if not inRoster[key(n)] then table.insert(signups, n) end
    end
    for _, n in ipairs(rosterNames) do
        if not onList[key(n)] then table.insert(members, n) end
    end

    local matches, guesses, taken = {}, {}, {}

    -- The leader's own word first.
    for _, s in ipairs(signups) do
        local said = RaidResBridge_Names[RB.FoldName(s)]
        if type(said) == "string" then
            local present = inRoster[key(said)]
            if present and not onList[key(said)] and not taken[key(said)] then
                matches[key(s)] = { signup = s, name = present, how = "manual", score = 1 }
                taken[key(said)] = true
            end
        end
    end

    -- Every pairing still open, scored, best first.
    local pairs_, bestFor = {}, {}
    local function note(k, score)
        local b = bestFor[k]
        if not b then b = { 0, 0 }; bestFor[k] = b end
        if score > b[1] then b[2] = b[1]; b[1] = score
        elseif score > b[2] then b[2] = score end
    end
    for _, s in ipairs(signups) do
        if not matches[key(s)] and RaidResBridge_Names[RB.FoldName(s)] ~= false then
            for _, m in ipairs(members) do
                if not taken[key(m)] then
                    local sc = RB.NameScore(s, m)
                    note("s:" .. key(s), sc)
                    note("m:" .. key(m), sc)
                    if sc >= GUESS then
                        table.insert(pairs_, { s = s, m = m, score = sc })
                    end
                end
            end
        end
    end
    table.sort(pairs_, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a.s ~= b.s then return a.s < b.s end
        return a.m < b.m
    end)

    -- Clear-cut ones are matched: alike enough, and clearly the best pairing
    -- for both sides, so two equally close names never get a coin toss.
    for _, p in ipairs(pairs_) do
        local sk, mk = key(p.s), key(p.m)
        -- (taken[mk] can't be true past the margin test below; it stays as
        -- a guard in case the margins are ever relaxed.)
        if not matches[sk] and not taken[mk] and p.score >= AUTO then
            local sb, mb = bestFor["s:" .. sk], bestFor["m:" .. mk]
            if p.score - sb[2] >= MARGIN and p.score - mb[2] >= MARGIN then
                matches[sk] = { signup = p.s, name = p.m, how = "auto", score = p.score }
                taken[mk] = true
            end
        end
    end

    -- The rest are offered, closest first.
    for _, p in ipairs(pairs_) do
        local sk = key(p.s)
        if not matches[sk] and not guesses[sk] and not taken[key(p.m)] then
            guesses[sk] = { signup = p.s, name = p.m, score = p.score }
        end
    end

    return matches, guesses, signups, members
end

--[[ The fetched list, renamed to the in-game names of whoever it matched.

     A copy: RaidResBridge_Data is what was fetched and stays that way, so a
     match taken back undoes cleanly. ]]
function RB.Fetched()
    local data, err, ref = RB.Read()
    if not data then return nil, err, ref, {}, {}, {}, {} end
    local names, roster = {}, {}
    for _, p in ipairs(data.softreserves or {}) do table.insert(names, p.name) end
    for _, r in ipairs(RB.Roster()) do table.insert(roster, r.name) end
    local matches, guesses, signups, members = RB.MatchNames(names, roster)
    if next(matches) == nil then return data, nil, ref, matches, guesses, signups, members end

    local copy = { metadata = data.metadata, hardreserves = data.hardreserves, softreserves = {} }
    for _, p in ipairs(data.softreserves or {}) do
        local m = matches[key(p.name)]
        table.insert(copy.softreserves,
            { name = m and m.name or p.name, role = p.role, items = p.items })
    end
    return copy, nil, ref, matches, guesses, signups, members
end

--[[ The leader settles a pairing: signup is that raid member, or (false)
     isn't anyone here, which also stops it being matched automatically. ]]
function RB.SetMatch(signup, member)
    if not signup then return end
    RaidResBridge_Names[RB.FoldName(signup)] = member or false
end
