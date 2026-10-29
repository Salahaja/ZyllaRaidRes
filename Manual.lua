--[[ Manual reserves, and somewhere to see the list.

     raidres signs people in through Discord or Steam, and not everyone in a
     raid can or will do that. Those people tell the raid leader in chat, and
     the raid leader has had nowhere to put it: RollFor can import a list but
     has no way to add one line to it, and its only soft-res window is a box
     you paste base64 into.

     So: the fetched list and anything added by hand are kept apart and merged
     on the way to RollFor. Apart, because a refetch from raidres must not
     discard what was typed in, and what was typed in must not be mistaken for
     something the website knows about -- if someone later signs up properly,
     the two have to be reconcilable.

     Everything leaves through RollFor.key_bindings.import, the same door the
     fetched list uses, so there is one path in and no second idea of what a
     reserve is. ]]

local RB = RaidResBridge

RaidResBridge_Manual = RaidResBridge_Manual or {}

local function say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff8fd3ffRaidRes|r: " .. msg)
end

--[[ Names are matched case-insensitively but kept as typed.

     WoW capitalises names itself, but a leader typing in a hurry will not, and
     "aldwyn" and "Aldwyn" must not become two people holding one
     reserve each. ]]
local function key(name)
    return string.lower(string.gsub(name or "", "%s", ""))
end

function RB.ManualList()
    local out = {}
    for _, row in pairs(RaidResBridge_Manual) do table.insert(out, row) end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function RB.AddManual(name, itemId, quality)
    name = string.gsub(name or "", "^%s*(.-)%s*$", "%1")
    itemId = tonumber(itemId)
    if name == "" or not itemId then return false, "need a name and an item" end

    local k = key(name)
    local row = RaidResBridge_Manual[k]
    if not row then
        row = { name = name, items = {} }
        RaidResBridge_Manual[k] = row
    end
    for i = 1, table.getn(row.items) do
        if row.items[i].id == itemId then
            return false, name .. " already has that reserved"
        end
    end
    table.insert(row.items, { id = itemId, quality = quality or 4, sr_plus = 0 })
    return true
end

function RB.RemoveManual(name, itemId)
    local row = RaidResBridge_Manual[key(name)]
    if not row then return false end
    if not itemId then
        RaidResBridge_Manual[key(name)] = nil
        return true
    end
    for i = 1, table.getn(row.items) do
        if row.items[i].id == itemId then
            table.remove(row.items, i)
            if table.getn(row.items) == 0 then
                RaidResBridge_Manual[key(name)] = nil
            end
            return true
        end
    end
    return false
end

function RB.ClearManual()
    RaidResBridge_Manual = {}
end

--[[ The fetched list with the manual entries folded in.

     A name on both sides keeps ONE set of items: the website's, plus anything
     manual it does not already have. The website is the better record of what
     someone reserved -- they clicked it themselves -- but a leader who typed
     an extra line meant it, and silently dropping either would be the kind of
     wrong that only shows up when the item drops. ]]
function RB.Merged()
    -- Renamed to the in-game names of whoever Names.lua matched.
    local fetched = (RB.Fetched or RB.Read)()
    local data
    if fetched then
        data = { metadata = fetched.metadata,
                 hardreserves = fetched.hardreserves or {},
                 softreserves = {} }
        for _, p in ipairs(fetched.softreserves or {}) do
            local items = {}
            for _, it in ipairs(p.items or {}) do table.insert(items, it) end
            table.insert(data.softreserves,
                { name = p.name, role = p.role or "", items = items })
        end
    else
        --[[ No fetched list at all is a perfectly ordinary state: a raid
             organised entirely in chat. RollFor still needs the metadata
             shape, so it gets one that says where this came from. ]]
        data = { metadata = { id = "manual", instance = 0,
                              instances = { "Manual" }, origin = "raidres" },
                 hardreserves = {}, softreserves = {} }
    end

    local byName = {}
    for _, p in ipairs(data.softreserves) do byName[key(p.name)] = p end

    for _, row in pairs(RaidResBridge_Manual) do
        local existing = byName[key(row.name)]
        if not existing then
            existing = { name = row.name, role = "", items = {} }
            byName[key(row.name)] = existing
            table.insert(data.softreserves, existing)
        end
        for _, it in ipairs(row.items) do
            local already = false
            for _, have in ipairs(existing.items) do
                if have.id == it.id then already = true end
            end
            if not already then
                table.insert(existing.items,
                    { id = it.id, quality = it.quality, sr_plus = it.sr_plus or 0 })
            end
        end
    end

    return data
end

-- ---------------------------------------------------------------------------
-- RollFor
-- ---------------------------------------------------------------------------

function RB.RollForReady()
    return RollFor and RollFor.key_bindings
        and type(RollFor.key_bindings.import) == "function" and true or false
end

--[[ A fingerprint of a list: who holds what, in any order.

     The merge visits the typed reserves with pairs(), so the same list can
     come out in another order after a reload; a sum over (name, item) pairs
     doesn't care. Kept with what was sent, so "has RollFor got this list?"
     survives a /reload. ]]
function RB.Signature(data)
    local players, items, sum = 0, 0, 0
    for _, p in ipairs(data.softreserves or {}) do
        players = players + 1
        local k, weight = key(p.name), 0
        for i = 1, string.len(k) do weight = weight + string.byte(k, i) * i end
        for _, it in ipairs(p.items or {}) do
            items = items + 1
            sum = sum + (it.id or 0) * (weight + 1)
        end
    end
    for _, h in ipairs(data.hardreserves or {}) do sum = sum + (h.id or 0) end
    local ref = data.metadata and data.metadata.id or ""
    return ref .. ":" .. players .. ":" .. items .. ":" .. string.format("%.0f", sum),
        players, items
end

--[[ What RollFor itself holds. RollFor 4.x keeps the list it imported, and
     when, in RollForCharDb.softres. Read here, never written. Any other shape
     returns nil -- "can't tell" -- and the window goes by what it sent. ]]
function RB.RollForHolds()
    local db = type(RollForCharDb) == "table" and RollForCharDb.softres
    if type(db) ~= "table" then return nil end
    return (db.data ~= nil and db.data ~= "") and true or false, db.import_timestamp
end

--[[ Where RollFor stands with this list: its signature and how many
     reserves it has, both from RB.Signature.

       missing  RollFor isn't loaded
       failed   RollFor refused the last send
       empty    nothing reserved, so nothing for RollFor to hold
       synced   RollFor holds exactly this list
       stale    the list changed after it was sent
       other    RollFor holds a list sent from somewhere else
       cleared  RollFor's list was cleared after this one was sent
       unsent   nothing has been sent from here yet ]]
function RB.RollForState(sig, reserved)
    if not RB.RollForReady() then return "missing" end
    if RB.sendError then return "failed" end
    if not sig or (reserved or 0) == 0 then return "empty" end
    local sent = RaidResBridge_Sent
    local holds, stamp = RB.RollForHolds()
    if not sent then return holds and "other" or "unsent" end
    if holds == false then return "cleared" end
    if holds and stamp and sent.stamp and stamp ~= sent.stamp then return "other" end
    if sent.sig ~= sig then return "stale" end
    return "synced"
end

--[[ RollFor answers every import in chat: "Soft-res data loaded
     successfully!" and then its soft-res check. After a fetch, or when Send
     is pressed, that is the confirmation that was asked for. After every
     click in the window it is a wall of chat saying what the window's RollFor
     box already says -- so a quiet send keeps RollFor quiet too. ]]
local function hushed(fn, arg)
    local chat = DEFAULT_CHAT_FRAME
    if not chat then return pcall(fn, arg) end
    local own = rawget(chat, "AddMessage")
    chat.AddMessage = function() end
    local ok, err = pcall(fn, arg)
    -- nil hands the method back to the frame; a chat addon's hook goes back as it was
    chat.AddMessage = own
    return ok, err
end

--- Push the merged list into RollFor.
function RB.Apply(quiet)
    if not RB.RollForReady() then
        if not quiet then say("|cffff5179RollFor is not loaded|r.") end
        return false
    end
    local rf = RollFor.key_bindings
    local data = RB.Merged()
    local sig, players, items = RB.Signature(data)
    if players == 0 then
        if not quiet then say("there is nothing to import yet.") end
        return false
    end
    local ok, err
    if quiet then ok, err = hushed(rf.import, data) else ok, err = pcall(rf.import, data) end
    if not ok then
        RB.sendError = tostring(err)
        say("|cffff5179RollFor refused it|r: " .. RB.sendError)
        if RB.DrawRollFor then RB.DrawRollFor() end
        return false
    end
    RB.sendError = nil
    local _, stamp = RB.RollForHolds()
    RaidResBridge_Sent = { sig = sig, players = players, items = items,
                           stamp = stamp, at = time and time() or nil }
    RB.sentAt = GetTime()
    if not quiet then
        local manual = table.getn(RB.ManualList())
        say("imported |cffffffff" .. players .. "|r player(s), " .. items ..
            " reservation(s)" ..
            (manual > 0 and (" |cff888888(" .. manual .. " added by hand)|r") or "") .. ".")
    end
    if RB.DrawRollFor then RB.DrawRollFor() end
    return true
end

--- RollFor's own soft-res window, to see the list as RollFor has it.
function RB.ViewInRollFor()
    local rf = RollFor and RollFor.key_bindings
    if not rf or type(rf.softres_toggle) ~= "function" then return false end
    return (pcall(rf.softres_toggle))
end
