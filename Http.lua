--[[ Fetching from inside the game, when RaidResHttp.dll is loaded.

     The DLL adds two functions and nothing else: RaidResHttpGet(path) starts a
     GET on raidres.top and returns an id; RaidResHttpResult(id) says
     "pending", or "done" with the status and body, or "failed" with a reason.
     It cannot reach any other host and cannot send anything but a GET.

     Everything the watcher did once a page arrived is done here instead:
     parse the JSON, turn raidres's own item numbers into real WoW item ids,
     and write the same files into CustomData that the watcher wrote. Writing
     the same files is deliberate. The rest of the addon -- RB.Read, the merge
     with typed reserves, the window -- keeps working on exactly what it
     already knows, and a fetched list is still there after a /reload.

     Without the DLL nothing here runs, and /rrb goes to the watcher as before. ]]

local RB = RaidResBridge

local TIMEOUT = 30     -- seconds before a request is given up on
local TICK = 0.2       -- seconds between asking the DLL how it is going
local GAME = "TURTLE"  -- raidres serves other versions' loot tables too
local RAID_FIRST, RAID_LAST = 90, 124

local function say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff8fd3ffRaidRes|r: " .. msg)
end

function RB.Http()
    return RaidResHttpGet ~= nil and RaidResHttpResult ~= nil
end

-- ---------------------------------------------------------------------------
-- JSON
-- ---------------------------------------------------------------------------

--[[ Just enough JSON for raidres's replies, in Lua 5.0.

     Strings are cut out with string.find rather than walked a character at a
     time; the raid files run to 80KB, and a per-byte loop over that is a
     visible hitch on this client. null becomes nil, which drops it from an
     object and closes the gap in an array rather than leaving a hole that
     table.getn would stop at. ]]
local Json = {}
RB.Json = Json

local sub, find, byte, char = string.sub, string.find, string.byte, string.char

local function skip(s, i)
    local _, e = find(s, "^[ \t\r\n]*", i)
    return e + 1
end

local function utf8(cp)
    if cp < 0x80 then return char(cp) end
    if cp < 0x800 then
        return char(0xC0 + math.floor(cp / 64), 0x80 + math.mod(cp, 64))
    end
    if cp < 0x10000 then
        return char(0xE0 + math.floor(cp / 4096),
                    0x80 + math.mod(math.floor(cp / 64), 64),
                    0x80 + math.mod(cp, 64))
    end
    return char(0xF0 + math.floor(cp / 262144),
                0x80 + math.mod(math.floor(cp / 4096), 64),
                0x80 + math.mod(math.floor(cp / 64), 64),
                0x80 + math.mod(cp, 64))
end

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b",
                  f = "\f", n = "\n", r = "\r", t = "\t" }

local value

local function str(s, i)
    -- i is just past the opening quote.
    local parts, n = {}, 0
    while true do
        local a = find(s, '["\\]', i)
        if not a then error("unterminated string") end
        if a > i then n = n + 1; parts[n] = sub(s, i, a - 1) end
        if sub(s, a, a) == '"' then
            return table.concat(parts), a + 1
        end
        local e = sub(s, a + 1, a + 1)
        if e == "u" then
            local cp = tonumber(sub(s, a + 2, a + 5), 16)
            if not cp then error("bad \\u escape") end
            local nexti = a + 6
            -- A surrogate pair is one character written as two escapes.
            if cp >= 0xD800 and cp <= 0xDBFF and sub(s, nexti, nexti + 1) == "\\u" then
                local lo = tonumber(sub(s, nexti + 2, nexti + 5), 16)
                if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                    cp = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00)
                    nexti = nexti + 6
                end
            end
            n = n + 1; parts[n] = utf8(cp)
            i = nexti
        else
            local c = ESCAPES[e]
            if not c then error("bad escape \\" .. e) end
            n = n + 1; parts[n] = c
            i = a + 2
        end
    end
end

local function array(s, i)
    local t, n = {}, 0
    i = skip(s, i)
    if sub(s, i, i) == "]" then return t, i + 1 end
    while true do
        local v
        v, i = value(s, i)
        if v ~= nil then n = n + 1; t[n] = v end
        i = skip(s, i)
        local c = sub(s, i, i)
        if c == "]" then return t, i + 1 end
        if c ~= "," then error("expected , or ] at " .. i) end
        i = i + 1
    end
end

local function object(s, i)
    local t = {}
    i = skip(s, i)
    if sub(s, i, i) == "}" then return t, i + 1 end
    while true do
        i = skip(s, i)
        if sub(s, i, i) ~= '"' then error("expected a key at " .. i) end
        local k
        k, i = str(s, i + 1)
        i = skip(s, i)
        if sub(s, i, i) ~= ":" then error("expected : at " .. i) end
        local v
        v, i = value(s, i + 1)
        t[k] = v
        i = skip(s, i)
        local c = sub(s, i, i)
        if c == "}" then return t, i + 1 end
        if c ~= "," then error("expected , or } at " .. i) end
        i = i + 1
    end
end

value = function(s, i)
    i = skip(s, i)
    local c = sub(s, i, i)
    if c == "{" then return object(s, i + 1) end
    if c == "[" then return array(s, i + 1) end
    if c == '"' then return str(s, i + 1) end
    if sub(s, i, i + 3) == "true" then return true, i + 4 end
    if sub(s, i, i + 4) == "false" then return false, i + 5 end
    if sub(s, i, i + 3) == "null" then return nil, i + 4 end
    local _, e = find(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if e then
        local num = tonumber(sub(s, i, e))
        if num then return num, e + 1 end
    end
    error("unexpected " .. (c == "" and "end of text" or ("'" .. c .. "'")) .. " at " .. i)
end

function Json.decode(s)
    local v, i = value(s, 1)
    if skip(s, i) <= string.len(s) then error("text after the value at " .. i) end
    return v
end

-- ---------------------------------------------------------------------------
-- raidres -> RollFor
-- ---------------------------------------------------------------------------

--[[ The same conversion the watcher does, line for line, so a list comes out
     identical whichever way it was fetched. The tests hold the two to that. ]]
function RB.Convert(ref, event, raid)
    local byItem = {}
    for _, it in ipairs(raid.raidItems or {}) do byItem[it.id] = it end

    local chars, order, skipped = {}, {}, 0
    for _, r in ipairs(event.reservations or {}) do
        local item = byItem[r.raidItemId]
        local name = r.character and r.character.name
        --[[ An item the raid file does not list is dropped, not guessed at:
             inventing an id would put somebody's name on the wrong loot. ]]
        if not item or not name then
            skipped = skipped + 1
        else
            if not chars[name] then
                chars[name] = { name = name, role = "", items = {} }
                table.insert(order, name)
            end
            table.insert(chars[name].items, {
                id = item.gameDbItemId,
                quality = item.quality or 4,
                sr_plus = r.srPlus or 0,
            })
        end
    end

    local hard = {}
    for _, h in ipairs(event.advancedHrItems or {}) do
        local item = byItem[h.raidItemId]
        if item and h.isHardReserved then
            table.insert(hard, { id = item.gameDbItemId, quality = item.quality or 4 })
        end
    end

    local soft, reservations = {}, 0
    for _, n in ipairs(order) do
        table.insert(soft, chars[n])
        reservations = reservations + table.getn(chars[n].items)
    end

    local data = {
        metadata = { id = ref, instance = event.raidId,
                     instances = { raid.name or "" }, origin = "raidres" },
        hardreserves = hard,
        softreserves = soft,
    }
    return data, {
        players = table.getn(order), reservations = reservations,
        hard = table.getn(hard), skipped = skipped, raid = raid.name or "?",
        limit = event.reservationLimit, locked = event.locked,
    }
end

--[[ raidres's item-select filters, in its order: each matches an item whose
     tooltip has one of these words as a whole tag's text (">Plate</"). The
     site's own list, so "Plate" shows here exactly what it shows there; the
     watcher's raidres_bridge.py holds the same, and the tests hold the two
     to each other. ]]
local PROFESSIONS = { "Alchemy", "Blacksmithing", "Cooking", "Enchanting", "Engineering",
    "First Aid", "Fishing", "Herbalism", "Jewelcrafting", "Leatherworking", "Mining",
    "Skinning", "Tailoring" }
local ITEM_TYPES = {
    { "cloth", { "Cloth" } },
    { "leather", { "Leather" } },
    { "mail", { "Mail" } },
    { "plate", { "Plate" } },
    { "weapon", { "Arrow", "Bullet", "Held In Off-Hand", "Main Hand", "Off Hand",
                  "One-hand", "Ranged", "Thrown", "Two-hand" } },
    { "neck", { "Neck" } },
    { "back", { "Back" } },
    { "ring", { "Finger" } },
    { "trinket", { "Trinket" } },
    { "profession", { "Enchanting Bag", "Explosive", "Fishing Pole", "Herb Bag" } },
    { "class", { "Ammo Pouch", "Bag", "Book", "Idol", "Libram", "Part", "Quiver",
                 "Reagent", "Relic", "Soul Bag", "Totem", "Classes: " } },
}
for _, p in ipairs(PROFESSIONS) do table.insert(ITEM_TYPES[10][2], "Requires " .. p) end
local SHARED = 999      -- raidres's position for loot more than one boss drops

--[[ Does the tooltip have a "Requires" line that isn't a level -- a
     profession's recipe? The site's /requires (?!level 1-120\b)/, by hand:
     Lua 5.0's patterns have no look-ahead. ]]
local function requiresOther(tt)
    local from = 1
    while true do
        local _, e = string.find(tt, ">requires ", from, true)
        if not e then return false end
        local _, _, digits = string.find(tt, "^level (%d+)", e + 1)
        local after = digits and string.sub(tt, e + 7 + string.len(digits), e + 7 + string.len(digits))
        local level = digits and string.sub(digits, 1, 1) ~= "0" and tonumber(digits) <= 120
            and not string.find(after, "[%w_]")
        if not level then return true end
        from = e + 1
    end
end

--- The ITEM_TYPES keys an item's tooltip matches, space-separated.
function RB.ItemTypes(tooltip)
    if type(tooltip) ~= "string" then return "" end
    local tt = string.lower(tooltip)
    local other = requiresOther(tt)
    local out = {}
    for _, kind in ipairs(ITEM_TYPES) do
        for _, word in ipairs(kind[2]) do
            local w = string.lower(word)
            local hit
            if string.find(w, "requires ", 1, true) then
                hit = other and (string.find(tt, ">" .. w .. "</", 1, true)
                                 or string.find(tt, ">" .. w .. " (", 1, true))
            else
                hit = not other and string.find(tt, ">" .. w .. "</", 1, true)
            end
            if hit then
                table.insert(out, kind[1])
                break
            end
        end
    end
    return table.concat(out, " ")
end

--- One raid's loot table, in the shape the window's picker reads.
function RB.ConvertRaid(raid)
    local bosses, places = {}, {}
    for _, b in ipairs(raid.raidBosses or {}) do
        bosses[b.id] = b.name or "?"
        places[b.id] = b.position or 0
    end
    local items = {}
    for _, it in ipairs(raid.raidItems or {}) do
        local droppedBy = it.raidBosses or {}
        local first = droppedBy[1]
        -- where it sorts: its boss's place in the kill order, or SHARED when
        -- more than one boss drops it, as on raidres
        local place = SHARED
        if table.getn(droppedBy) <= 1 and first and places[first] then place = places[first] end
        table.insert(items, {
            g = it.gameDbItemId, n = it.name or "?", q = it.quality or 4,
            b = (first and bosses[first]) or "", c = it.characterClasses or {},
            o = place, t = RB.ItemTypes(it.tooltip),
        })
    end
    return { name = raid.name or "?", items = items }
end

-- ---------------------------------------------------------------------------
-- Writing what the watcher would have written
-- ---------------------------------------------------------------------------

--[[ A Lua literal, for RB.Read to loadstring later. Every key is written as
     [k]= -- arrays too -- which is a little longer than {a,b} and cannot get
     an array with a gap wrong. %q quotes strings the way loadstring reads. ]]
local function literal(v, out)
    local t = type(v)
    if t == "string" then
        table.insert(out, string.format("%q", v))
    elseif t == "number" then
        table.insert(out, tostring(v))
    elseif t == "boolean" then
        table.insert(out, v and "true" or "false")
    elseif t == "table" then
        table.insert(out, "{")
        for k, x in pairs(v) do
            table.insert(out, "[")
            literal(k, out)
            table.insert(out, "]=")
            literal(x, out)
            table.insert(out, ",")
        end
        table.insert(out, "}")
    else
        table.insert(out, "nil")
    end
end

function RB.Literal(v)
    local out = {}
    literal(v, out)
    return table.concat(out)
end

local function write(name, text)
    if not RB.FileAPI() then return false end
    return (pcall(WriteCustomFile, name, text, "w"))
end

--[[ Kept in memory as well as on disk, so a client without Nampower's file
     API can still import what it fetched. RB.Read falls back to it. ]]
function RB.Store(ref, data, stats)
    local limit = stats.limit or 2

    -- Whether raidres has it locked, as of this fetch. Compared with what was
    -- known before, so this goes first: the globals below are about to be
    -- overwritten. Left out of the file when the event doesn't say, so that
    -- reads back as unknown.
    local locked = stats.locked
    if type(locked) ~= "boolean" then locked = nil end
    if locked ~= nil then RB.SetLock(ref, locked) end

    RaidResBridge_Data, RaidResBridge_Ref, RaidResBridge_Limit = data, ref, limit
    RaidResBridge_Locked = locked
    RB.activeRef = ref
    RB.fetched = { data = data, ref = ref, unsaved = true }

    local saved = write(RB.REPLY,
        "-- GENERATED by RaidResBridge in game -- do not edit.\n" ..
        "-- " .. stats.raid .. ", " .. stats.players .. " player(s), " ..
        stats.reservations .. " reservation(s).\n" ..
        "RaidResBridge_Data = " .. RB.Literal(data) .. "\n" ..
        "RaidResBridge_Ref = " .. RB.Literal(ref) .. "\n" ..
        "RaidResBridge_Limit = " .. RB.Literal(limit) .. "\n" ..
        (locked ~= nil and ("RaidResBridge_Locked = " .. RB.Literal(locked) .. "\n") or ""))
    RB.fetched.unsaved = not saved
    return saved
end

local function writeRaids()
    return write("RaidResBridge_raids.lua",
        "-- GENERATED by RaidResBridge in game -- do not edit.\n" ..
        "RaidResBridge_Raids = " .. RB.Literal(RaidResBridge_Raids) .. "\n")
end

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------

local jobs = {}
local driver = CreateFrame("Frame")
driver:Hide()
local since = 0

--[[ Asked every fifth of a second, and only while something is in flight:
     the frame hides itself when the last request is answered, so OnUpdate
     costs nothing the rest of the time. ]]
driver:SetScript("OnUpdate", function()
    since = since + arg1
    if since < TICK then return end
    since = 0
    local i = 1
    while i <= table.getn(jobs) do
        local job = jobs[i]
        local state, a, b = RaidResHttpResult(job.id)
        if state == "pending" and GetTime() - job.started < TIMEOUT then
            i = i + 1
        else
            table.remove(jobs, i)
            local ok, err
            if state == "done" then
                ok, err = pcall(job.done, a, b)
            elseif state == "pending" then
                ok, err = pcall(job.done, nil, "no answer after " .. TIMEOUT .. "s")
            else
                ok, err = pcall(job.done, nil, a or "the request was lost")
            end
            if not ok then say("|cffff5179" .. tostring(err) .. "|r") end
        end
    end
    if table.getn(jobs) == 0 then driver:Hide() end
end)

--- GET a path on raidres.top; done(status, body), or done(nil, reason).
function RB.Get(path, done, quiet)
    local id, err = RaidResHttpGet(path)
    if not id then
        done(nil, err or "the request was refused")
        return
    end
    table.insert(jobs, { id = id, done = done, started = GetTime(), quiet = quiet })
    driver:Show()
end

-- A parsed reply, or nil and something to tell the raid leader.
local function decoded(status, body, what)
    if not status then return nil, what .. " could not be fetched: " .. tostring(body) end
    if status == 404 then return nil, "raidres has no " .. what end
    if status < 200 or status >= 300 then
        return nil, "raidres answered " .. status .. " for " .. what
    end
    local ok, v = pcall(Json.decode, body)
    if not ok or type(v) ~= "table" then return nil, what .. " was not readable JSON" end
    return v
end

--[[ Is a fetch the leader asked for under way? A quiet look at the lock
     doesn't count: it must not say "Fetching..." or turn a /rrb away. ]]
function RB.HttpBusy()
    for _, job in ipairs(jobs) do
        if not job.quiet then return true end
    end
    return false
end

local POLL_EVERY = 30      -- seconds between looks while the window is open
local POLL_BACKOFF = 60    -- after a look that failed

--[[ Ask raidres whether the list is locked: the same public event page a
     fetch reads, on its own and quietly. One at a time, and a reply that
     arrives after another list became the active one is dropped. ]]
function RB.HttpPollLock(ref)
    if not (RB.Http and RB.Http()) or not ref or ref == "" or ref == "manual" then return false end
    if RB.polling then return false end
    RB.polling = true
    RB.pollAt = GetTime()
    RB.Get("/api/events/" .. ref, function(status, body)
        RB.polling = nil
        local event = decoded(status, body, "list " .. ref)
        if not event or type(event.locked) ~= "boolean" then
            RB.pollFailed = (RB.pollFailed or 0) + 1
            return
        end
        RB.pollFailed = 0
        if RB.activeRef and string.lower(RB.activeRef) ~= string.lower(ref) then return end
        RB.SetLock(ref, event.locked)
        -- The window draws from its last snapshot: bring its lock up to date.
        local s = RB.gui and RB.gui:IsVisible() and RB.gui.snap
        if s then
            s.locked, s.lockAt = RB.LockState(s.ref)
            if RB.DrawStatus then RB.DrawStatus() end
        end
    end, true)
    return true
end

--[[ Called as the window ticks: look again if it's time. `force` is the
     button, which asks now. Nothing happens without the DLL or a list. ]]
function RB.MaybePollLock(force)
    local s = RB.gui and RB.gui.snap
    local ref = s and s.ref
    if not ref or ref == "manual" then return false end
    local every = ((RB.pollFailed or 0) > 0) and POLL_BACKOFF or POLL_EVERY
    if not force and RB.pollAt and GetTime() - RB.pollAt < every then return false end
    return RB.HttpPollLock(ref)
end

--- How many requests this addon is waiting on, and the oldest one's age.
function RB.HttpWaiting()
    local oldest = 0
    for _, job in ipairs(jobs) do
        local age = GetTime() - job.started
        if age > oldest then oldest = age end
    end
    return table.getn(jobs), oldest
end

--[[ Fetch a list and import it: the event, then the raid it is for.

     Two requests because raidres numbers its items its own way and keeps the
     translation to real WoW item ids in the raid file. The raid file is also
     that instance's loot table, so it goes into the window's cache while it is
     here -- one less reason to press "Get loot". ]]
function RB.HttpRequest(ref)
    say("fetching |cffffffff" .. ref .. "|r...")
    RB.Get("/api/events/" .. ref, function(status, body)
        local event, why = decoded(status, body, "list " .. ref)
        if not event then say("|cffff5179" .. why .. "|r") return end
        if type(event.raidId) ~= "number" then
            say("|cffff5179that list does not say which raid it is for|r.")
            return
        end

        RB.Get("/raids/raid_" .. tostring(event.raidId) .. ".json", function(st, rbody)
            local raid, rwhy = decoded(st, rbody, "the loot table for that raid")
            if not raid then say("|cffff5179" .. rwhy .. "|r") return end

            local data, stats = RB.Convert(ref, event, raid)
            RB.Store(ref, data, stats)

            RB.LoadRaids()
            RaidResBridge_Raids = RaidResBridge_Raids or {}
            RaidResBridge_Raids[event.raidId] = RB.ConvertRaid(raid)
            writeRaids()
            RB.RememberList(ref, data)

            if stats.skipped > 0 then
                say("|cffffcc00" .. stats.skipped .. " reservation(s) skipped|r: " ..
                    "items the loot table does not list.")
            end
            if stats.locked then say("the list is locked, so it will not change again.") end
            if stats.players == 0 then say("nothing reserved on that list yet.") end

            if RB.Apply then RB.Apply() else RB.Load() end
            if RB.gui and RB.gui:IsVisible() then RB.Refresh() end
        end)
    end)
end

--[[ Every raid's loot table, for the window's instance picker.

     The ids are not contiguous, so the range is swept and whatever answers is
     what exists. Four at a time: quick, without asking the site for 35 pages
     at once. Replaces the cache outright, because a sweep is the whole list. ]]
function RB.HttpRaids()
    local found, left, nextId = {}, RAID_LAST - RAID_FIRST + 1, RAID_FIRST
    say("fetching the loot tables...")

    local function finish()
        local count = 0
        for _ in pairs(found) do count = count + 1 end
        if count == 0 then
            say("|cffff5179no loot tables came back|r.")
            return
        end
        RaidResBridge_Raids = found
        writeRaids()
        say("cached |cffffffff" .. count .. "|r loot table(s).")
        if RB.gui and RB.gui:IsVisible() then RB.Refresh() end
    end

    local function one()
        if nextId > RAID_LAST then return end
        local id = nextId
        nextId = nextId + 1
        RB.Get("/raids/raid_" .. tostring(id) .. ".json", function(status, body)
            local raid = decoded(status, body, "raid " .. id)
            if raid and raid.game == GAME then found[id] = RB.ConvertRaid(raid) end
            left = left - 1
            if left == 0 then finish() else one() end
        end)
    end

    one(); one(); one(); one()
end

-- ---------------------------------------------------------------------------
-- Lock control via the helper script (tools/raidres_lock.py)
--
-- The addon writes a one-line command to CustomData, the Python script reads
-- it, tells Chrome to call the raidres API, and writes the result back.
-- ---------------------------------------------------------------------------

local LOCK_CMD    = "RaidResBridge_lock_cmd.txt"
local LOCK_RESULT = "RaidResBridge_lock_result.txt"
local LOCK_POLL   = 0.5
local LOCK_TIMEOUT = 15

function RB.LockControlReady()
    if RaidResLockReady then return RB.FileAPI() end
    return RaidResBridge_LockControl and RB.FileAPI()
end

local lockTick = CreateFrame("Frame")
lockTick:Hide()
lockTick:SetScript("OnUpdate", function()
    this.t = (this.t or 0) + arg1
    if this.t < LOCK_POLL then return end
    this.t = 0
    if not RB.lockPending and not RB.reservePending then this:Hide() return end
    RB.CheckLockResult()
    RB.CheckReserveResult()
end)

-- One command file, so one command at a time: a lock and a reserve sent
-- together would have the second overwrite the first.
function RB.HelperBusy()
    return (RB.lockPending or RB.reservePending) and true or false
end

function RB.SendLockCommand(ref, lock)
    if not RB.LockControlReady() or RB.HelperBusy() then return false end
    pcall(WriteCustomFile, LOCK_RESULT, "", "w")
    local cmd = (lock and "lock " or "unlock ") .. ref
    local ok = pcall(WriteCustomFile, LOCK_CMD, cmd, "w")
    if not ok then return false end
    RB.lockPending = { ref = ref, lock = lock, sent = GetTime() }
    lockTick:Show()
    return true
end

function RB.SendOpenCommand(ref)
    if not RB.FileAPI() then return false end
    local ok = pcall(WriteCustomFile, LOCK_CMD, "open " .. ref, "w")
    return ok
end

function RB.SendSigninCommand(ref)
    if not RB.FileAPI() or RB.HelperBusy() then return false end
    pcall(WriteCustomFile, LOCK_RESULT, "", "w")
    local ok = pcall(WriteCustomFile, LOCK_CMD, "signin " .. ref, "w")
    if not ok then return false end
    RB.lockPending = { ref = ref, signin = true, sent = GetTime() }
    lockTick:Show()
    return true
end

-- ---------------------------------------------------------------------------
-- Your own reserves on raidres, through the same helper
--
--   reserve REF ITEMID NAME CLASS [SPEC]   ->  ok reserved [SPEC] | needspec
--   unreserve REF ITEMID NAME              ->  ok removed
--   either                                 ->  signin [expiry] | error: why
--
-- ITEMID is the WoW item id; the helper finds raidres's own. NAME is who you
-- signed up as, CLASS raidres's word for your class ("Paladin"). Longer to
-- answer than a lock: the helper reads the list, its loot table and who you
-- are before it sends anything.
-- ---------------------------------------------------------------------------

local RESERVE_TIMEOUT = 45

function RB.SendReserveCommand(ref, itemId, name, class, spec, remove)
    if not RB.LockControlReady() or RB.HelperBusy() then return false end
    local cmd
    if remove then
        cmd = "unreserve " .. ref .. " " .. itemId .. " " .. name
    else
        cmd = "reserve " .. ref .. " " .. itemId .. " " .. name .. " " .. class ..
            (spec and (" " .. spec) or "")
    end
    pcall(WriteCustomFile, LOCK_RESULT, "", "w")
    if not pcall(WriteCustomFile, LOCK_CMD, cmd, "w") then return false end
    RB.reservePending = { ref = ref, item = itemId, name = name, class = class,
                          remove = remove, sent = GetTime() }
    lockTick:Show()
    return true
end

function RB.CheckReserveResult()
    local pending = RB.reservePending
    if not pending then return end
    if GetTime() - pending.sent > RESERVE_TIMEOUT then
        RB.reservePending = nil
        if RB.Notice then RB.Notice("the lock script did not answer. Is it running?") end
        if RB.Draw then RB.Draw() end
        return
    end
    local ok, text = pcall(ReadCustomFile, LOCK_RESULT)
    if not ok or type(text) ~= "string" or text == "" then return end
    pcall(WriteCustomFile, LOCK_RESULT, "", "w")
    RB.reservePending = nil
    if RB.OnReserveResult then RB.OnReserveResult(pending, text) end
end

function RB.CheckLockResult()
    if not RB.lockPending then return end
    local pending = RB.lockPending
    if GetTime() - pending.sent > LOCK_TIMEOUT then
        RB.lockPending = nil
        if RB.Notice then RB.Notice("lock script did not answer. Is it running?") end
        if RB.DrawStatus then RB.DrawStatus() end
        return
    end
    local ok, text = pcall(ReadCustomFile, LOCK_RESULT)
    if not ok or type(text) ~= "string" or text == "" then return end
    pcall(WriteCustomFile, LOCK_RESULT, "", "w")
    RB.lockPending = nil
    if text == "ok" or string.sub(text, 1, 3) == "ok " then
        if pending.signin then
            RB.sessionExpired = nil
            if RB.Notice then RB.Notice("Chrome opened. Sign in on raidres, then try again.") end
        else
            RB.sessionExpired = nil
            RB.SetLock(pending.ref, pending.lock)
            local s = RB.gui and RB.gui:IsVisible() and RB.gui.snap
            if s then
                s.locked, s.lockAt = RB.LockState(s.ref)
            end
            if string.len(text) > 3 then
                RB.sessionExpiry = string.sub(text, 4)
            end
        end
    elseif text == "signin" or string.sub(text, 1, 7) == "signin " then
        RB.sessionExpired = true
        if string.len(text) > 7 then
            RB.sessionExpiry = string.sub(text, 8)
        else
            RB.sessionExpiry = nil
        end
        if RB.Notice then RB.Notice("raidres session expired. Click Sign in.") end
    else
        if RB.Notice then RB.Notice(text) end
    end
    if RB.DrawStatus then RB.DrawStatus() end
end
