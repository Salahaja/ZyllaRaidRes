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
    local fetched = RB.Read()
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

--- Push the merged list into RollFor.
function RB.Apply(quiet)
    local rf = RollFor and RollFor.key_bindings
    if not rf or type(rf.import) ~= "function" then
        if not quiet then say("|cffff5179RollFor is not loaded|r.") end
        return false
    end
    local data = RB.Merged()
    local players, items = 0, 0
    for _, p in ipairs(data.softreserves) do
        players = players + 1
        items = items + table.getn(p.items)
    end
    if players == 0 then
        if not quiet then say("there is nothing to import yet.") end
        return false
    end
    local ok, err = pcall(rf.import, data)
    if not ok then
        say("|cffff5179RollFor refused it|r: " .. tostring(err))
        return false
    end
    if not quiet then
        local manual = table.getn(RB.ManualList())
        say("imported |cffffffff" .. players .. "|r player(s), " .. items ..
            " reservation(s)" ..
            (manual > 0 and (" |cff888888(" .. manual .. " added by hand)|r") or "") .. ".")
    end
    return true
end
