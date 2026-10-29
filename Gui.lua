--[[ The window. /rrb opens it.

     Built for the raid leader on the night, ten minutes before the pull, with
     a roster in front of them and people whispering what they want:

       1. Paste the raidres link at the top and press Fetch (or Enter).
       2. The players are the raid, whoever still has reserves to make at the
          top, each counted against the event's own limit.
       3. Pick one, and the loot is theirs to click: click to reserve, click
          again to take it back. Their reserves show under the list, with an X
          on the ones typed here.
       4. Every change goes to RollFor as it is made, and the RollFor box at
          the bottom says whether RollFor really holds this list -- read
          back from RollFor's own record, not assumed.

     The rules it keeps:
       - One selection drives everything, and the line under the lists
         always says what the next click will do.
       - Nothing here can remove what someone reserved on raidres. Those are
         marked and locked, because a refetch would bring them straight back
         and the window would have lied.
       - The loot shows the raid you are standing in, or the one the list is
         for -- never just whichever raid sorts first.

     It is meant to look like it shipped with the client, so it is made of the
     client's own parts: the dialog border and header banner of the Options
     window, its grey labelled boxes, the Who list's column headers, the quest
     log's highlight and its +/- headers, a real UIDropDownMenu, and the
     client's own class and item colours. With pfUI loaded it is skinned the
     way pfUI skins every Blizzard window. Every widget is registered by kind
     as it is built, and a skin works through those lists, so nothing added
     later can be left in the other look. The look can also be picked:
     RaidResBridge_Options.skin, from the minimap button's menu or /rrb skin.

     Every handler reads `this`, never a loop variable: Lua 5.0 shares a for
     loop's variables with the closures made inside it. Rows are sized
     outright rather than by their anchors, because this client reports stale
     sizes for anchor-sized frames. ]]

local RB = RaidResBridge

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

local W = 680
local ROW_H = 18
local EDGE = 20                 -- inside the dialog border
local BOX_TOP = 78              -- the boxes start here; their labels sit above
local GAP = 18
local P_W = 236                 -- players column
local P_ROWS = 12
local P_LIST_TOP = 32           -- under the column headers
local P_H = P_LIST_TOP + P_ROWS * ROW_H + 8
local D_ROWS = 4                -- the selected player's reserves
local D_H = D_ROWS * ROW_H + 14
local D_TOP = BOX_TOP + P_H + 22
local L_X = EDGE + P_W + GAP
local L_W = W - L_X - EDGE
local L_H = D_TOP + D_H - BOX_TOP
local L_LIST_TOP = 38           -- under the dropdown
local L_ROWS = 17
local SCROLLBAR = 22
local HINT_TOP = D_TOP + D_H + 6
local R_TOP = HINT_TOP + ROW_H + 22     -- the RollFor box; its label sits above
local R_H = 36
local H = R_TOP + R_H + EDGE

local DIALOG = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
}

-- The Options window's boxes: a thin grey border, a little darker inside.
local BOX = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 5, right = 5, top = 5, bottom = 5 },
}

local HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight"
local QMARK = "Interface\\Icons\\INV_Misc_QuestionMark"
local PLUS = "Interface\\Buttons\\UI-PlusButton-Up"
local MINUS = "Interface\\Buttons\\UI-MinusButton-Up"
local CHECK = "Interface\\Buttons\\UI-CheckBox-Check"
local DICE = "Interface\\Buttons\\UI-GroupLoot-Dice-Up"     -- the group loot roll button's

-- The client's own text colours (NORMAL_FONT_COLOR and friends).
local GOLD, WHITE, GREY = "ffd200", "ffffff", "808080"
local RED, GREEN = "ff2020", "20ff20"

local QUALITY = {
    [0] = "9d9d9d", [1] = "ffffff", [2] = "1eff00",
    [3] = "0070dd", [4] = "a335ee", [5] = "ff8000",
}

local CLASS_FALLBACK = {
    WARRIOR = "c79c6e", PALADIN = "f58cba", HUNTER = "abd473", ROGUE = "fff569",
    PRIEST = "ffffff", SHAMAN = "f58cba", MAGE = "69ccf0", WARLOCK = "9482c9",
    DRUID = "ff7d0a",
}

local function say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff8fd3ffRaidRes|r: " .. msg)
end

local function hex(colour, s) return "|cff" .. colour .. s .. "|r" end

local function rgb(h)
    return tonumber(string.sub(h, 1, 2), 16) / 255,
           tonumber(string.sub(h, 3, 4), 16) / 255,
           tonumber(string.sub(h, 5, 6), 16) / 255
end

local function toHex(r, g, b)
    return string.format("%02x%02x%02x", math.floor(r * 255 + 0.5),
        math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- Item and class colours from the client when it has them, so they match the
-- bags, the raid frame and the chat exactly.
local function qualityHex(q)
    if GetItemQualityColor and q then
        local r, g, b = GetItemQualityColor(q)
        if r then return toHex(r, g, b) end
    end
    return QUALITY[q or 1] or WHITE
end

local function classHex(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return toHex(c.r, c.g, c.b) end
    return CLASS_FALLBACK[class or ""] or WHITE
end

-- The same name key Manual.lua uses: case and spaces do not make two people.
local function key(name)
    return string.lower(string.gsub(name or "", "%s", ""))
end

-- ---------------------------------------------------------------------------
-- What the window shows
-- ---------------------------------------------------------------------------

--- How many reserves each player is allowed. The event says; two is the usual.
function RB.Limit()
    return RaidResBridge_Limit or 2
end

--[[ Who can be given a reserve.

     The raid first, because that is who is actually there, then anyone on the
     list who is not -- a signup who has not zoned in yet still has reserves
     worth seeing. By default whoever has reserved nothing comes first, since
     they are the reason the window is open, and anyone at the limit sinks.
     The Name column header sorts by name instead. ]]
function RB.Players(snap)
    local data = snap and snap.merged or RB.Merged()
    local counts = {}
    for _, p in ipairs(data.softreserves or {}) do
        counts[key(p.name)] = table.getn(p.items or {})
    end

    local out, seen = {}, {}
    local function add(name, class, inRaid)
        if not name or name == "" or name == UNKNOWNOBJECT then return end
        local k = key(name)
        if seen[k] then return end
        seen[k] = true
        table.insert(out, { name = name, class = class,
                            count = counts[k] or 0, inRaid = inRaid })
    end

    for _, r in ipairs(RB.Roster()) do add(r.name, r.class, true) end
    for _, p in ipairs(data.softreserves or {}) do add(p.name, nil, false) end

    local limit = RB.Limit()
    if RB.playerSort == "name" then
        table.sort(out, function(a, b) return a.name < b.name end)
    else
        table.sort(out, function(a, b)
            local af = (a.count >= limit) and 1 or 0
            local bf = (b.count >= limit) and 1 or 0
            if af ~= bf then return af < bf end
            if a.count ~= b.count then return a.count < b.count end
            return a.name < b.name
        end)
    end
    return out
end

--- Every raid whose loot table has been cached, by name.
function RB.RaidList()
    local out = {}
    for id, raid in pairs(RaidResBridge_Raids or {}) do
        table.insert(out, { id = id, name = raid.name,
                            count = table.getn(raid.items or {}) })
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--[[ Does an item pass the loot filters?

     The search matches the item or its boss, so "hakkar" finds Hakkar's loot.
     The class filter only ever hides items the loot table restricts to other
     classes; anything with no class list is for everyone and always shows. ]]
function RB.ItemMatches(it, search, class)
    if search and search ~= "" then
        if not string.find(string.lower(it.n or ""), search, 1, true)
           and not string.find(string.lower(it.b or ""), search, 1, true) then
            return false
        end
    end
    if class and it.c and table.getn(it.c) > 0 then
        for _, c in ipairs(it.c) do
            if string.upper(c) == class then return true end
        end
        return false
    end
    return true
end

--[[ One instance's loot, boss by boss, filtered.

     Flattened into rows with headers rather than nested, so the scroll offset
     stays a plain index into a list. A boss can be folded away like a zone in
     the quest log; a search opens every boss, so nothing found is hidden. A
     boss whose loot is all filtered out loses its header too. ]]
function RB.ItemRows(raidId, opts)
    local raid = (RaidResBridge_Raids or {})[raidId]
    if not raid then return {} end
    local search = opts and opts.search
    local class = opts and opts.class
    local folded = (opts and opts.collapsed) or {}
    local searching = search and search ~= ""
    local groups, order = {}, {}
    for _, it in ipairs(raid.items or {}) do
        if RB.ItemMatches(it, search, class) then
            local boss = it.b or ""
            if not groups[boss] then
                groups[boss] = {}
                table.insert(order, boss)
            end
            table.insert(groups[boss], it)
        end
    end
    local rows = {}
    for _, boss in ipairs(order) do
        local fold = tostring(raidId) .. ":" .. boss
        local closed = folded[fold] and not searching
        table.insert(rows, { header = boss ~= "" and boss or "Elsewhere",
                             fold = fold, collapsed = closed and true or false })
        if not closed then
            for _, it in ipairs(groups[boss]) do table.insert(rows, { item = it }) end
        end
    end
    return rows
end

--- Who already has this item, if anyone.
function RB.WhoHas(gameItemId)
    local out = {}
    for _, p in ipairs(RB.Merged().softreserves or {}) do
        for _, it in ipairs(p.items or {}) do
            if it.id == gameItemId then table.insert(out, p.name) end
        end
    end
    return out
end

--[[ Everything one draw needs, worked out once.

     RB.Read parses the list file, and the first window called it once per
     visible row. This reads it twice per change and indexes the rest:
     who holds what, which of a player's reserves came from raidres (locked)
     and which were typed here (removable), and what is hard-reserved. ]]
function RB.Snapshot()
    local fetched, _, ref, matches, guesses, signups, members = (RB.Fetched or RB.Read)()
    local merged = RB.Merged()
    local s = { merged = merged, ref = ref, holders = {}, items = {},
                web = {}, typed = {}, hard = {}, typedCount = 0 }
    s.locked, s.lockAt = RB.LockState(ref)

    -- Who Names.lua paired up, and who is still loose on either side.
    s.inRaid = (GetNumRaidMembers and GetNumRaidMembers() or 0) > 0
    s.matchedBy, s.absent, s.free, s.guesses = {}, {}, {}, guesses or {}
    s.toCheck = 0
    for _, m in pairs(matches or {}) do s.matchedBy[key(m.name)] = m end
    for _, n in ipairs(signups or {}) do
        if not (matches and matches[key(n)]) then s.absent[key(n)] = n end
    end
    for _, n in ipairs(members or {}) do
        if not s.matchedBy[key(n)] then s.free[key(n)] = n end
    end
    for _ in pairs(s.guesses) do s.toCheck = s.toCheck + 1 end

    for _, p in ipairs(merged.softreserves or {}) do
        s.items[key(p.name)] = p.items or {}
        for _, it in ipairs(p.items or {}) do
            if not s.holders[it.id] then s.holders[it.id] = {} end
            table.insert(s.holders[it.id], p.name)
        end
    end
    for _, h in ipairs(merged.hardreserves or {}) do s.hard[h.id] = true end

    if fetched then
        for _, p in ipairs(fetched.softreserves or {}) do
            local set = {}
            for _, it in ipairs(p.items or {}) do set[it.id] = true end
            s.web[key(p.name)] = set
        end
        s.instance = fetched.metadata and fetched.metadata.instance
    end

    for k, row in pairs(RaidResBridge_Manual or {}) do
        local set = {}
        for _, it in ipairs(row.items or {}) do
            set[it.id] = true
            s.typedCount = s.typedCount + 1
        end
        s.typed[k] = set
    end

    s.players = RB.Players(s)
    s.sig, _, s.reserved = RB.Signature(merged)
    return s
end

--- How many players have all their reserves, out of everyone shown.
function RB.Progress(s)
    local limit, done = RB.Limit(), 0
    for _, p in ipairs(s.players) do
        if p.count >= limit then done = done + 1 end
    end
    return done, table.getn(s.players)
end

--- The raid a list is for, by name, as well as anything knows it.
function RB.ListPlace(s)
    local raids = RaidResBridge_Raids or {}
    local meta = s.merged.metadata or {}
    return (s.instance and raids[s.instance] and raids[s.instance].name)
        or (meta.instances and meta.instances[1]) or "?"
end

--[[ Zones that are not called what raidres calls their raid.

     Every other raid zone has its raid's exact name, the server's own
     additions included (Tower of Karazhan, Lower Karazhan Halls, Emerald
     Sanctum, Timbermaw Hold); the server's zone list, as pfQuest's database
     has it, confirms them. World bosses are left out on purpose: they live
     in open country, and standing in Azshara says nothing about Azuregos. ]]
local ZONE_ALIAS = {
    ["ahn'qiraj"] = "temple of ahn'qiraj",
    ["blackrock spire"] = "upper blackrock spire",
}

-- Zone name -> cached raid id, rebuilt when the loot tables change.
local zoneIndex, zoneIndexOf, zoneIndexBuilt = nil, nil, false
local function raidForZone(zone)
    if not zone or zone == "" then return nil end
    if not zoneIndexBuilt or zoneIndexOf ~= RaidResBridge_Raids then
        zoneIndex, zoneIndexOf, zoneIndexBuilt = {}, RaidResBridge_Raids, true
        for id, raid in pairs(RaidResBridge_Raids or {}) do
            zoneIndex[string.lower(raid.name or "")] = id
        end
    end
    local want = string.lower(zone)
    return zoneIndex[ZONE_ALIAS[want] or want]
end

--- The cached raid you're standing in, if any, and the zone's name.
function RB.ZoneRaid()
    local zone = GetRealZoneText and GetRealZoneText() or ""
    return raidForZone(zone), zone
end

--[[ The raid your group is in: yours if you are in one, otherwise wherever
     the most of your raid is -- one member inside is enough -- so the loot
     is ready while you are still in town. The roster carries every member's
     zone, the same one their unit tooltip shows, however far away they are.
     Offline members don't count. A tie goes to the list's own raid when it
     is one of them, otherwise to the raid that sorts first.

     Returns the raid id, "zone" or "group", and how many are there. ]]
function RB.GroupRaid(prefer)
    local mine = RB.ZoneRaid()
    if mine then return mine, "zone", 1 end
    local counts = {}
    local n = GetNumRaidMembers and GetNumRaidMembers() or 0
    for i = 1, n do
        local _, _, _, _, _, _, zone, online = GetRaidRosterInfo(i)
        local id = online and raidForZone(zone)
        if id then counts[id] = (counts[id] or 0) + 1 end
    end
    -- Sorted rather than picked in one pass, so a tie never depends on the
    -- order pairs() happens to visit them in.
    local raids = RaidResBridge_Raids or {}
    local found = {}
    for id, c in pairs(counts) do table.insert(found, { id = id, n = c }) end
    if table.getn(found) == 0 then return nil end
    table.sort(found, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        if (a.id == prefer) ~= (b.id == prefer) then return a.id == prefer end
        return (raids[a.id].name or "") < (raids[b.id].name or "")
    end)
    return found[1].id, "group", found[1].n
end

--[[ Which instance the loot shows. The newest signal wins:

       - a newly loaded list brings its own raid;
       - the raid your group is in -- yours, or where the most of the raid
         already is -- brings that raid when it changes. Checked after the
         list, so opening the window with the raid inside shows that raid;
       - the leader's own pick from the dropdown stands until either of
         those happens again. Everyone leaving a raid changes nothing.

     RB.raidWhy remembers which, so the window can say why it chose. ]]
function RB.CurrentRaid(s)
    local raids = RaidResBridge_Raids or {}
    if s.ref and s.ref ~= RB.raidFor then
        RB.raidFor = s.ref
        if s.instance and raids[s.instance] then
            RB.raid, RB.raidWhy = s.instance, "list"
        end
    end
    local here, how, count = RB.GroupRaid(s.instance)
    RB.raidSignalKey = tostring(here) .. ":" .. tostring(how) .. ":" .. tostring(count)
    if here ~= RB.raidSignal then
        RB.raidSignal = here
        if here then RB.raid, RB.raidWhy, RB.raidCount = here, how, count end
    elseif here and here == RB.raid and RB.raidWhy ~= nil and RB.raidWhy ~= "list" then
        -- Same raid, but the reason or the head count moved on.
        RB.raidWhy, RB.raidCount = how, count
    end
    if not (RB.raid and raids[RB.raid]) then
        if here then
            RB.raid, RB.raidWhy, RB.raidCount = here, how, count
        elseif s.instance and raids[s.instance] then
            RB.raid, RB.raidWhy = s.instance, "list"
        else
            local list = RB.RaidList()
            RB.raid, RB.raidWhy = list[1] and list[1].id or nil, nil
        end
    end
    return RB.raid and raids[RB.raid]
end

-- Every cached item by id, for naming reserves outside the current instance.
local lootIndex, lootIndexOf, lootIndexBuilt = nil, nil, false
local function lootItem(id)
    if not lootIndexBuilt or lootIndexOf ~= RaidResBridge_Raids then
        lootIndex, lootIndexOf, lootIndexBuilt = {}, RaidResBridge_Raids, true
        for _, raid in pairs(RaidResBridge_Raids or {}) do
            for _, it in ipairs(raid.items or {}) do lootIndex[it.g] = it end
        end
    end
    return lootIndex[id]
end

--[[ Name, quality and icon for an item id, and whether the client has it.

     The client's cache when it has the item, which also gives the icon;
     the loot table's name otherwise. The fourth value matters: a tooltip
     must not ask the client for an item it has never seen. ]]
function RB.ItemInfo(id)
    local name, quality, icon
    if GetItemInfo then
        -- 1.12: name, link, quality, minLevel, type, subType, stack, equipLoc, icon
        local n, _, q, _, _, _, _, _, tex = GetItemInfo(id)
        name, quality, icon = n, q, tex
    end
    if name then return name, quality or 1, icon, true end
    local known = lootItem(id)
    return (known and known.n) or ("item " .. tostring(id)), (known and known.q) or 1, nil, false
end

function RB.ItemLink(id)
    local name, q = RB.ItemInfo(id)
    return "|cff" .. qualityHex(q) .. "|Hitem:" .. id .. ":0:0:0|h[" .. name .. "]|h|r"
end

-- ---------------------------------------------------------------------------
-- Acting on a click
-- ---------------------------------------------------------------------------

--[[ Say something about the last click: in the window when it is open, so the
     answer is where the eyes are, and in chat when it is not. ]]
function RB.Notice(msg)
    local f = RB.gui
    if f and f:IsVisible() then
        f.notice, f.noticeUntil = msg, GetTime() + 4
        RB.DrawHint()
    else
        say(msg)
    end
end

--- After any change: redraw, and hand the merged list to RollFor.
function RB.Commit()
    RB.Refresh()
    RB.Apply(true)
end

function RB.SelectPlayer(name)
    if not name then return end
    -- Clicking the selected player again lets go, so loot can be browsed
    -- without a stray click reserving it for someone.
    if RB.player and key(RB.player) == key(name) then
        RB.player = nil
    else
        RB.player = name
    end
    RB.Draw()
end

function RB.SortPlayers(how)
    RB.playerSort = how
    RB.Refresh()
end

function RB.ToggleBoss(fold)
    if not fold then return end
    RB.collapsed = RB.collapsed or {}
    RB.collapsed[fold] = not RB.collapsed[fold] or nil
    RB.Draw()
end

-- The way the rest of 1.12 does it: a focused WIM whisper box first, then the
-- chat box, but only while it is open.
local function linkInChat(id)
    local link = RB.ItemLink(id)
    if WIM_EditBoxInFocus then
        WIM_EditBoxInFocus:Insert(link)
    elseif ChatFrameEditBox and ChatFrameEditBox:IsVisible() then
        ChatFrameEditBox:Insert(link)
    else
        RB.Notice("open the chat box first (Enter), then shift-click the item.")
    end
end

--[[ Clicking an item gives it to whoever is selected, or takes it back.

     Only ever the typed list: an item somebody reserved on raidres is theirs,
     and only raidres can change it. Shift-click links the item in chat and
     ctrl-click tries it on, as everywhere else in the game. ]]
function RB.ClickItem(data)
    if not data or not data.item then return end
    local id = data.item.g
    if not id then return end

    if IsShiftKeyDown and IsShiftKeyDown() then
        linkInChat(id)
        return
    end
    if IsControlKeyDown and IsControlKeyDown() and DressUpItemLink then
        DressUpItemLink("item:" .. id .. ":0:0:0")
        return
    end

    local who = RB.player
    if not who then
        RB.Notice("pick a player on the left first.")
        return
    end

    if RB.RemoveManual(who, id) then
        RB.Commit()
        return
    end

    local s = RB.Snapshot()
    local k = key(who)
    if s.web[k] and s.web[k][id] then
        RB.Notice(who .. " reserved that on raidres; change it there.")
        return
    end
    if s.hard[id] then
        RB.Notice("that item is hard-reserved, so nobody can soft-reserve it.")
        return
    end
    local count = table.getn(s.items[k] or {})
    if count >= RB.Limit() then
        RB.Notice(who .. " already has " .. count .. " of " .. RB.Limit() ..
            ". Take one back first.")
        return
    end

    local ok, err = RB.AddManual(who, id, data.item.q or 4)
    if not ok then
        RB.Notice(err or "could not add that")
        return
    end
    RB.Commit()
end

--- Download every raid's loot table: in game with the DLL, else via the watcher.
function RB.FetchLoot()
    if RB.Http and RB.Http() then
        if RB.HttpBusy() then
            RB.Notice("still fetching; give it a moment.")
        else
            RB.HttpRaids()
        end
    elseif RB.FileAPI() then
        pcall(WriteCustomFile, RB.REQUEST, "RAIDS", "w")
        RB.Notice("asked the watcher for the loot tables. /reload once it has them.")
    else
        RB.Notice("can't download: needs RaidResHttp.dll, or Nampower and the watcher.")
    end
    RB.DrawStatus()
end

function RB.FetchFromBox()
    local f = RB.gui
    local text = f.link:GetText() or ""
    f.link:ClearFocus()
    if string.gsub(text, "%s", "") == "" then
        RB.Notice("paste a raidres link first.")
        return
    end
    RB.Request(text)
    RB.DrawStatus()
end

--- A choice from the instance dropdown: a raid id, or "loot" to download them.
function RB.PickRaid(value)
    if value == nil then return end
    if value == "loot" then
        RB.FetchLoot()
        return
    end
    RB.raid, RB.raidWhy = value, nil
    RB.ResetScroll(RB.gui.lScroll)
    RB.Draw()
end

-- ---------------------------------------------------------------------------
-- Tooltips
-- ---------------------------------------------------------------------------

local function plainTip(owner, title, body)
    GameTooltip:SetOwner(owner, "ANCHOR_TOPLEFT")
    GameTooltip:SetText(title, 1, 0.82, 0)
    if body and body ~= "" then GameTooltip:AddLine(body, 1, 1, 1, 1) end
    GameTooltip:Show()
end

local function tip(frame, title, body)
    frame.tipTitle, frame.tipBody = title, body
    frame:SetScript("OnEnter", function() plainTip(this, this.tipTitle, this.tipBody) end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function addGrey(line) GameTooltip:AddLine(line, 0.5, 0.5, 0.5) end

function RB.ItemTooltip(owner, id)
    if not id then return end
    local f = RB.gui
    local s = f and f.snap
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local name, q, _, cached = RB.ItemInfo(id)
    if cached then
        GameTooltip:SetHyperlink("item:" .. id .. ":0:0:0")
    else
        -- Asking the client about an item it has never seen can disconnect
        -- on some servers, so an unseen item gets its name and nothing more.
        local r, g, b = rgb(qualityHex(q))
        GameTooltip:SetText(name, r, g, b)
        addGrey("Not seen in game yet, so no stats.")
    end

    if s then
        local holders = s.holders[id] or {}
        if s.hard[id] then
            GameTooltip:AddLine("Hard reserved: nobody can soft-reserve it.", 1, 0.13, 0.13)
        elseif table.getn(holders) > 0 then
            GameTooltip:AddLine("Reserved by " .. table.concat(holders, ", "), 1, 0.82, 0)
        else
            addGrey("Nobody has reserved this yet.")
        end

        local who = RB.player
        if who then
            local k = key(who)
            local mine = false
            for _, it in ipairs(s.items[k] or {}) do
                if it.id == id then mine = true end
            end
            if mine and s.web[k] and s.web[k][id] then
                addGrey(who .. " reserved this on raidres.")
            elseif mine then
                GameTooltip:AddLine("Click: take it back from " .. who, 0.13, 1, 0.13)
            elseif not s.hard[id] then
                if table.getn(s.items[k] or {}) >= RB.Limit() then
                    GameTooltip:AddLine(who .. " is full.", 1, 0.82, 0)
                else
                    GameTooltip:AddLine("Click: reserve for " .. who, 0.13, 1, 0.13)
                end
            end
        else
            addGrey("Pick a player to reserve this.")
        end
    end
    addGrey("Shift-click: link in chat.  Ctrl-click: try it on.")
    GameTooltip:Show()
end

function RB.PlayerTooltip(row)
    local p = row.data
    local s = RB.gui and RB.gui.snap
    if not p or not s then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetText(p.name, rgb(classHex(p.class)))
    if p.inRaid then
        addGrey("In your group")
    else
        addGrey("Signed up on raidres, not in your group")
    end
    local m = s.matchedBy[key(p.name)]
    if m then
        addGrey("Signed up as " .. m.signup ..
            (m.how == "auto" and " (matched automatically)" or " (matched by you)"))
    end
    local g = not p.inRaid and s.inRaid and s.guesses[key(p.name)]
    if g then
        GameTooltip:AddLine("Maybe " .. g.name .. " in your raid? Select them and press Match.",
            1, 0.82, 0, 1)
    end
    local k = key(p.name)
    local items = s.items[k] or {}
    if table.getn(items) == 0 then
        GameTooltip:AddLine("No reserves yet", 1, 0.13, 0.13)
    end
    for _, it in ipairs(items) do
        local name, q = RB.ItemInfo(it.id)
        local typed = not (s.web[k] and s.web[k][it.id])
        local r, g, b = rgb(qualityHex(q))
        GameTooltip:AddLine(name .. (typed and "  (typed here)" or ""), r, g, b)
    end
    addGrey(RB.player and key(RB.player) == k and "Click to let go" or "Click to select")
    GameTooltip:Show()
end

-- ---------------------------------------------------------------------------
-- Widgets: the client's own
-- ---------------------------------------------------------------------------

--[[ Every widget, by kind, as it is made. The skin works through these
     lists rather than naming widgets one by one, so a button added next year
     is skinned without anyone remembering to add it there. ]]
local parts = { box = {}, button = {}, check = {}, edit = {}, drop = {},
                scroll = {}, close = {}, header = {}, row = {} }
local function part(kind, w)
    table.insert(parts[kind], w)
    return w
end

local function text(parent, template, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    fs:SetJustifyH(justify or "LEFT")
    return fs
end

-- An Options-window box: grey border, its label sitting just above it.
local function box(parent, label, w, h)
    local b = CreateFrame("Frame", nil, parent)
    b:SetWidth(w)
    b:SetHeight(h)
    b:SetBackdrop(BOX)
    b:SetBackdropBorderColor(0.4, 0.4, 0.4)
    b:SetBackdropColor(0, 0, 0, 0.3)
    b.label = b:CreateFontString(nil, "BACKGROUND", "GameFontHighlightSmall")
    b.label:SetPoint("BOTTOMLEFT", b, "TOPLEFT", 9, 3)
    b.label:SetText(label)
    return part("box", b)
end

local function button(parent, label, w, h, name)
    local b = CreateFrame("Button", name, parent, "UIPanelButtonTemplate")
    b:SetWidth(w)
    b:SetHeight(h or 22)
    b:SetText(label)
    return part("button", b)
end

local function checkbox(parent, name, label)
    local c = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    c:SetWidth(24)
    c:SetHeight(24)
    c.label = getglobal(name .. "Text")
    if c.label then
        c.label:SetFontObject(GameFontNormalSmall)
        c.label:SetText(label)
    end
    return part("check", c)
end

-- The Who list's column header, sized the way the Who list sizes its own.
local function columnHeader(parent, name, label, w)
    local h = CreateFrame("Button", name, parent, "WhoFrameColumnHeaderTemplate")
    if WhoFrameColumn_SetWidth then
        WhoFrameColumn_SetWidth(w, h)
    else
        h:SetWidth(w)
        local mid = getglobal(name .. "Middle")
        if mid then mid:SetWidth(w - 9) end
    end
    h:SetText(label)
    return part("header", h)
end

-- An edit box with grey placeholder text while it is empty and unfocused.
local function syncPlaceholder(e)
    if e.focused or (e:GetText() or "") ~= "" then e.placeholder:Hide()
    else e.placeholder:Show() end
end

local function editBox(parent, name, w, placeholder)
    local e = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
    e:SetWidth(w)
    e:SetHeight(20)
    e:SetAutoFocus(false)
    e.placeholder = text(e, "GameFontDisableSmall")
    e.placeholder:SetPoint("LEFT", e, "LEFT", 1, 0)
    e.placeholder:SetText(placeholder)
    e:SetScript("OnEditFocusGained", function()
        this.focused = true
        this:HighlightText()
        syncPlaceholder(this)
    end)
    e:SetScript("OnEditFocusLost", function()
        this.focused = nil
        this:HighlightText(0, 0)
        syncPlaceholder(this)
    end)
    e:SetScript("OnEscapePressed", function() this:ClearFocus() end)
    return part("edit", e)
end

--[[ A list row, lit the way the quest log and friends list light theirs: the
     quest-title glow on hover, and the same glow held on the selected row. ]]
local function listRow(parent, w)
    local row = CreateFrame("Button", nil, parent)
    row:SetWidth(w)
    row:SetHeight(ROW_H)
    row:SetHighlightTexture(HIGHLIGHT)
    local hl = row:GetHighlightTexture()
    if hl then hl:SetBlendMode("ADD") end
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetWidth(14)
    row.icon:SetHeight(14)
    row.icon:SetPoint("LEFT", row, "LEFT", 3, 0)
    row.icon:Hide()
    row.text = text(row)
    row.text:SetHeight(ROW_H)
    return part("row", row)
end

local function setSelected(row, on)
    row.selected = on
    if on then row:LockHighlight() else row:UnlockHighlight() end
end

function RB.ResetScroll(sf)
    if not sf then return end
    sf.offset = 0
    local bar = getglobal(sf:GetName() .. "ScrollBar")
    if bar then bar:SetValue(0) end
end

local function scrollFrame(parent, name, w, rows, top)
    local sf = CreateFrame("ScrollFrame", name, parent, "FauxScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -top)
    sf:SetWidth(w)
    sf:SetHeight(rows * ROW_H)
    sf:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(ROW_H, RB.Draw)
    end)
    local bar = getglobal(name .. "ScrollBar")
    if bar then part("scroll", bar) end
    return sf
end

-- ---------------------------------------------------------------------------
-- Building it
-- ---------------------------------------------------------------------------

local function buildPlayers(f)
    local pb = box(f, "Players", P_W, P_H)
    pb:SetPoint("TOPLEFT", f, "TOPLEFT", EDGE, -BOX_TOP)
    f.pBox = pb
    local inner = P_W - 16 - SCROLLBAR

    f.colName = columnHeader(pb, "ZyllaRaidResColName", "Name", inner - 50)
    f.colName:SetPoint("TOPLEFT", pb, "TOPLEFT", 6, -6)
    f.colName:SetScript("OnClick", function() RB.SortPlayers("name") end)
    f.colCount = columnHeader(pb, "ZyllaRaidResColCount", "Reserves", 72)
    f.colCount:SetPoint("LEFT", f.colName, "RIGHT", -2, 0)
    f.colCount:SetScript("OnClick", function() RB.SortPlayers("need") end)

    f.pScroll = scrollFrame(pb, "ZyllaRaidResPlayerScroll", inner, P_ROWS, P_LIST_TOP)
    f.pRows = {}
    for i = 1, P_ROWS do
        local row = listRow(pb, inner)
        row:SetPoint("TOPLEFT", pb, "TOPLEFT", 8, -P_LIST_TOP - (i - 1) * ROW_H)
        row:SetFrameLevel(f.pScroll:GetFrameLevel() + 2)
        row.text:SetPoint("LEFT", row, "LEFT", 6, 0)
        row.text:SetWidth(inner - 50)
        row.count = text(row, "GameFontHighlightSmall", "RIGHT")
        row.count:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.count:SetWidth(40)
        row.count:SetHeight(ROW_H)
        row:SetScript("OnClick", function()
            if this.data then RB.SelectPlayer(this.data.name) end
        end)
        row:SetScript("OnEnter", function() RB.PlayerTooltip(this) end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.pRows[i] = row
    end
    f.pEmpty = text(pb, "GameFontDisableSmall", "CENTER")
    f.pEmpty:SetPoint("TOP", pb, "TOP", 0, -P_LIST_TOP - 40)
    f.pEmpty:SetWidth(inner)

    -- beside the box's label, where the Options window puts a box's toggle
    f.missing = checkbox(pb, "ZyllaRaidResMissing", "Missing only")
    f.missing:SetPoint("RIGHT", pb, "TOPRIGHT", -80, 10)
    f.missing:SetScript("OnClick", function()
        RB.missingOnly = this:GetChecked() and true or false
        RB.ResetScroll(RB.gui.pScroll)
        RB.Draw()
    end)
    tip(f.missing, "Missing only", "Show only the players who still have reserves to make.")

    -- the selected player's reserves
    local db = box(f, "Reserves", P_W, D_H)
    db:SetPoint("TOPLEFT", f, "TOPLEFT", EDGE, -D_TOP)
    f.dBox = db
    f.dEmpty = text(db, "GameFontDisableSmall")
    f.dEmpty:SetPoint("TOPLEFT", db, "TOPLEFT", 10, -10)
    f.dEmpty:SetWidth(P_W - 20)

    -- Settling who is who, when the names don't quite match.
    f.matchBtn = button(db, "Match", 62, 18, "ZyllaRaidResMatchButton")
    f.matchBtn:SetPoint("BOTTOMRIGHT", db, "TOPRIGHT", -4, 1)
    f.matchBtn:SetScript("OnClick", function()
        ToggleDropDownMenu(1, nil, RB.gui.matchMenu, "ZyllaRaidResMatchButton", 0, 0)
    end)
    tip(f.matchBtn, "Match names",
        "Pair a raidres signup with the person in your raid when the names don't quite match.")
    f.matchBtn:Hide()
    f.matchMenu = CreateFrame("Frame", "ZyllaRaidResMatchMenu", f, "UIDropDownMenuTemplate")
    f.matchMenu:Hide()
    UIDropDownMenu_Initialize(f.matchMenu, RB.InitMatchMenu, "MENU")

    f.dRows = {}
    for i = 1, D_ROWS do
        local row = listRow(db, P_W - 16)
        row:SetPoint("TOPLEFT", db, "TOPLEFT", 8, -7 - (i - 1) * ROW_H)
        row.icon:Show()
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
        row.text:SetWidth(P_W - 16 - 22 - 52)
        row.tag = text(row, "GameFontDisableSmall", "RIGHT")
        row.tag:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.tag:SetWidth(48)
        row.tag:SetHeight(ROW_H)
        row.tag:SetText("raidres")
        row.remove = part("close", CreateFrame("Button", nil, row, "UIPanelCloseButton"))
        row.remove:SetWidth(22)
        row.remove:SetHeight(22)
        row.remove:SetPoint("RIGHT", row, "RIGHT", 3, 0)
        row.remove:SetScript("OnClick", function()
            local r = this:GetParent()
            if r.itemId and RB.player and RB.RemoveManual(RB.player, r.itemId) then
                RB.Commit()
            end
        end)
        tip(row.remove, "Take it back", "Remove this reserve. It was typed here, so it can go.")
        row:SetScript("OnClick", function()
            if this.itemId and IsShiftKeyDown and IsShiftKeyDown() then linkInChat(this.itemId) end
        end)
        row:SetScript("OnEnter", function() RB.ItemTooltip(this, this.itemId) end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.dRows[i] = row
    end
end

local function onPickMatch()
    local c = RB.matchChoices and RB.matchChoices[this.value]
    if not c then return end
    RB.SetMatch(c.signup, c.member)
    if c.member then RB.player = c.member end
    if CloseDropDownMenus then CloseDropDownMenus() end
    RB.Commit()
end

--[[ The Match menu, for whoever is selected:

       - a signup who isn't in the raid: who is it here? Closest first, or
         "Nobody here", which also stops it being guessed at;
       - a raid member not on the list: which signup is it?
       - a pair already matched: take it back, or keep an automatic one so
         it can't change.

     Each entry carries an index into RB.matchChoices, read back from
     this.value when it is clicked -- nothing captured from a loop. ]]
function RB.InitMatchMenu()
    local f = RB.gui
    local s = f and f.snap
    local sel = RB.player
    RB.matchChoices = {}
    if not s or not sel then return end
    local k = key(sel)

    local function add(text, choice)
        local info = {}
        info.text = text
        info.notCheckable = 1
        if choice then
            table.insert(RB.matchChoices, choice)
            info.value = table.getn(RB.matchChoices)
            info.func = onPickMatch
        else
            info.isTitle = 1
        end
        UIDropDownMenu_AddButton(info)
    end
    local function ranked(name, pool)
        local out = {}
        for _, n in pairs(pool) do
            table.insert(out, { name = n, score = RB.NameScore(name, n) })
        end
        table.sort(out, function(a, b)
            if a.score ~= b.score then return a.score > b.score end
            return a.name < b.name
        end)
        return out
    end

    local m = s.matchedBy[k]
    if m then
        add(sel .. " signed up as " .. m.signup)
        if m.how == "auto" then add("Keep this match", { signup = m.signup, member = sel }) end
        add("Unmatch", { signup = m.signup, member = false })
    elseif s.absent[k] then
        add("Who is " .. sel .. " in your raid?")
        local list = ranked(sel, s.free)
        for i = 1, table.getn(list) do
            local c = list[i]
            add(c.name .. (c.score >= RB.NameGuess and hex(GREY, "  close match") or ""),
                { signup = sel, member = c.name })
        end
        add(hex(GREY, "Nobody here"), { signup = sel, member = false })
    elseif s.free[k] then
        add("Which signup is " .. sel .. "?")
        local list = ranked(sel, s.absent)
        for i = 1, table.getn(list) do
            local c = list[i]
            add(c.name .. (c.score >= RB.NameGuess and hex(GREY, "  close match") or ""),
                { signup = c.name, member = sel })
        end
    end
end

local function onPickRaid() RB.PickRaid(this.value) end

--[[ The instance dropdown's contents, built each time it opens: every cached
     raid, the current one checked, and the download at the bottom. 1.12's
     UIDropDownMenu calls an item's func with `this` as the clicked button,
     so one shared func reads this.value rather than capturing anything. ]]
function RB.InitRaidMenu()
    local list = RB.RaidList()
    for i = 1, table.getn(list) do
        local r = list[i]
        local info = {}
        info.text = r.name
        info.value = r.id
        info.func = onPickRaid
        info.checked = (r.id == RB.raid) and 1 or nil
        UIDropDownMenu_AddButton(info)
    end
    local info = {}
    info.text = hex(GREEN, table.getn(list) > 0 and "Update loot tables" or "Download loot tables")
    info.value = "loot"
    info.func = onPickRaid
    UIDropDownMenu_AddButton(info)
end

local function buildLoot(f)
    local lb = box(f, "Loot", L_W, L_H)
    lb:SetPoint("TOPLEFT", f, "TOPLEFT", L_X, -BOX_TOP)
    f.lBox = lb
    local inner = L_W - 16 - SCROLLBAR

    f.raidDrop = part("drop", CreateFrame("Frame", "ZyllaRaidResRaidDrop", lb, "UIDropDownMenuTemplate"))
    f.raidDrop:SetPoint("TOPLEFT", lb, "TOPLEFT", -8, -4)
    UIDropDownMenu_SetWidth(150, f.raidDrop)
    UIDropDownMenu_Initialize(f.raidDrop, RB.InitRaidMenu)
    if UIDropDownMenu_JustifyText then UIDropDownMenu_JustifyText("LEFT", f.raidDrop) end

    f.search = editBox(lb, "ZyllaRaidResSearch", 108, "Search")
    f.search:SetPoint("LEFT", f.raidDrop, "RIGHT", -6, 2)
    f.search:SetScript("OnTextChanged", function()
        RB.search = string.lower(this:GetText() or "")
        syncPlaceholder(this)
        RB.ResetScroll(RB.gui.lScroll)
        RB.Draw()
    end)
    f.search:SetScript("OnEnterPressed", function() this:ClearFocus() end)

    f.classOnly = checkbox(lb, "ZyllaRaidResClassOnly", "Usable")
    f.classOnly:SetPoint("LEFT", f.search, "RIGHT", 8, -1)
    f.classOnly:SetScript("OnClick", function()
        RB.classOnly = this:GetChecked() and true or false
        RB.ResetScroll(RB.gui.lScroll)
        RB.Draw()
    end)
    tip(f.classOnly, "Usable only",
        "Hide loot the selected player's class can't use, such as other classes' tier pieces.")

    f.lScroll = scrollFrame(lb, "ZyllaRaidResLootScroll", inner, L_ROWS, L_LIST_TOP)
    f.lRows = {}
    for i = 1, L_ROWS do
        local row = listRow(lb, inner)
        row:SetPoint("TOPLEFT", lb, "TOPLEFT", 8, -L_LIST_TOP - (i - 1) * ROW_H)
        row:SetFrameLevel(f.lScroll:GetFrameLevel() + 2)
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
        row.text:SetWidth(inner - 22 - 146)
        -- a boss: the quest log's +/- and its gold header text
        row.toggle = row:CreateTexture(nil, "ARTWORK")
        row.toggle:SetWidth(14)
        row.toggle:SetHeight(14)
        row.toggle:SetPoint("LEFT", row, "LEFT", 3, 0)
        row.head = text(row, "GameFontNormal")
        row.head:SetPoint("LEFT", row.toggle, "RIGHT", 4, 0)
        row.head:SetWidth(inner - 30)
        row.head:SetHeight(ROW_H)
        row.check = row:CreateTexture(nil, "OVERLAY")
        row.check:SetTexture(CHECK)
        row.check:SetWidth(16)
        row.check:SetHeight(16)
        row.who = text(row, "GameFontHighlightSmall", "RIGHT")
        row.who:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.who:SetWidth(124)
        row.who:SetHeight(ROW_H)
        row.check:SetPoint("RIGHT", row.who, "LEFT", 0, 0)
        row:SetScript("OnClick", function()
            local d = this.data
            if d and d.header then RB.ToggleBoss(d.fold) else RB.ClickItem(d) end
        end)
        row:SetScript("OnEnter", function()
            if this.data and this.data.item then RB.ItemTooltip(this, this.data.item.g) end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.lRows[i] = row
    end

    f.lEmpty = text(lb, "GameFontHighlightSmall", "CENTER")
    f.lEmpty:SetPoint("TOP", lb, "TOP", 0, -L_LIST_TOP - 90)
    f.lEmpty:SetWidth(inner - 20)
    f.lEmptyButton = button(lb, "Download loot tables", 160)
    f.lEmptyButton:SetPoint("TOP", f.lEmpty, "BOTTOM", 0, -12)
    f.lEmptyButton:SetScript("OnClick", function() RB.FetchLoot() end)
end

--- Clear typed: every reserve added in this window, after asking.
function RB.AskClearTyped()
    if StaticPopupDialogs and not StaticPopupDialogs.ZYLLARAIDRES_CLEAR then
        StaticPopupDialogs.ZYLLARAIDRES_CLEAR = {
            text = "Remove the %s reserve(s) added by hand?\nReserves made on raidres stay.",
            button1 = YES or "Yes",
            button2 = NO or "No",
            OnAccept = function()
                RB.ClearManual()
                RB.Commit()
                RB.Notice("cleared everything added by hand.")
            end,
            timeout = 0, whileDead = 1, hideOnEscape = 1,
        }
    end
    local s = RB.gui and RB.gui.snap
    StaticPopup_Show("ZYLLARAIDRES_CLEAR", tostring(s and s.typedCount or 0))
end

--[[ The RollFor box: does RollFor hold this list, and the buttons that act
     on RollFor. On the left RollFor's dice -- the group loot roll button's --
     and two lines, the state and what RollFor holds; on the right Clear
     typed, set a little apart from the two that talk to RollFor. ]]
local function buildRollFor(f)
    local rb = box(f, "RollFor", W - EDGE * 2, R_H)
    rb:SetPoint("TOPLEFT", f, "TOPLEFT", EDGE, -R_TOP)
    f.rBox = rb

    f.rfIcon = rb:CreateTexture(nil, "ARTWORK")
    f.rfIcon:SetTexture(DICE)
    f.rfIcon:SetWidth(22)
    f.rfIcon:SetHeight(22)
    f.rfIcon:SetPoint("LEFT", rb, "LEFT", 9, 0)

    f.send = button(rb, "Send to RollFor", 124)
    f.send:SetPoint("RIGHT", rb, "RIGHT", -7, 0)
    f.send:SetScript("OnClick", function() RB.Apply() end)
    f.send:SetScript("OnEnter", function() RB.SendTooltip(this) end)
    f.send:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.view = button(rb, "View in RollFor", 112)
    f.view:SetPoint("RIGHT", f.send, "LEFT", -4, 0)
    f.view:SetScript("OnClick", function()
        if not RB.ViewInRollFor() then RB.Notice("this RollFor has no soft-res window to open.") end
    end)
    tip(f.view, "View in RollFor",
        "Open RollFor's own soft-res window, to see the list the way RollFor has it.")

    f.clear = button(rb, "Clear typed", 92)
    f.clear:SetPoint("RIGHT", f.view, "LEFT", -12, 0)
    f.clear:SetScript("OnClick", function() RB.AskClearTyped() end)
    tip(f.clear, "Clear typed", "Remove every reserve added in this window. Asks first.")

    -- two lines of 12 beside the dice, held to the box so they never overlap
    local textX = 9 + 22 + 8
    local textW = W - EDGE * 2 - textX - (7 + 124 + 4 + 112 + 12 + 92) - 8
    f.rfHead = text(rb, "GameFontHighlightSmall")
    f.rfHead:SetPoint("TOPLEFT", rb, "TOPLEFT", textX, -6)
    f.rfHead:SetWidth(textW)
    f.rfHead:SetHeight(12)
    f.rfBody = text(rb, "GameFontDisableSmall")
    f.rfBody:SetPoint("BOTTOMLEFT", rb, "BOTTOMLEFT", textX, 6)
    f.rfBody:SetWidth(textW)
    f.rfBody:SetHeight(12)
end

function RB.SendTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_TOPLEFT")
    GameTooltip:SetText("Send to RollFor", 1, 0.82, 0)
    GameTooltip:AddLine("Every change already goes to RollFor as you make it. " ..
        "This sends the whole list again, and RollFor says in chat what it took.", 1, 1, 1, 1)
    local sent = RaidResBridge_Sent
    if sent and sent.players then
        local when = RB.SentAgo()
        addGrey("Last sent: " .. sent.players .. " players, " .. sent.items .. " reserves" ..
            (when and (", " .. when) or "") .. ".")
    end
    GameTooltip:Show()
end

-- ---------------------------------------------------------------------------
-- The look
-- ---------------------------------------------------------------------------

local function pfApi()
    local api = pfUI and pfUI.api
    if api and api.CreateBackdrop and api.StripTextures then return api end
    return nil
end

function RB.HasPfUI() return pfApi() ~= nil end

--[[ Which look to build, "blizzard" or "pfui". RaidResBridge_Options.skin
     says: "auto" (the default: pfUI's whenever pfUI is loaded), "blizzard"
     or "pfui". pfUI's look needs pfUI, so without it everything is Blizzard. ]]
function RB.SkinName()
    local want = RaidResBridge_Options and RaidResBridge_Options.skin or "auto"
    if want ~= "blizzard" and pfApi() then return "pfui" end
    return "blizzard"
end

--[[ Picking a look. A frame can't be un-skinned -- pfUI strips textures it
     doesn't keep -- so a change that would alter what is already built asks
     to reload, which builds everything fresh in the new look. ]]
function RB.SetSkin(which)
    if which ~= "auto" and which ~= "blizzard" and which ~= "pfui" then return false end
    RaidResBridge_Options = RaidResBridge_Options or {}
    RaidResBridge_Options.skin = which
    local built = RB.builtSkin
    if built and built ~= RB.SkinName() and StaticPopupDialogs then
        if not StaticPopupDialogs.ZYLLARAIDRES_RELOAD then
            StaticPopupDialogs.ZYLLARAIDRES_RELOAD = {
                text = "Zylla RaidRes changes its look after a reload.\nReload the UI now?",
                button1 = "Reload",
                button2 = "Later",
                OnAccept = function() ReloadUI() end,
                timeout = 0, whileDead = 1, hideOnEscape = 1,
            }
        end
        StaticPopup_Show("ZYLLARAIDRES_RELOAD")
    end
    return true
end

--[[ pfUI restyles Blizzard's windows; with it loaded, this one gets the same
     treatment through pfUI's own skinning functions, so it matches whatever
     pfUI theme is in use. Any trouble leaves the Blizzard look in place. ]]
function RB.SkinForPfUI(f)
    local api = pfApi()
    if not api then return false end
    local function each(kind, fn)
        local list = parts[kind]
        for i = 1, table.getn(list) do fn(list[i]) end
    end
    local ok = pcall(function()
        f:SetBackdrop(nil)
        f.header:Hide()
        api.CreateBackdrop(f, nil, nil, 0.75)
        if api.CreateBackdropShadow then api.CreateBackdropShadow(f) end
        f.title:ClearAllPoints()
        f.title:SetPoint("TOP", f, "TOP", 0, -10)
        if api.SkinCloseButton then api.SkinCloseButton(f.close, f.backdrop or f, -6, -6) end
        each("box", function(b)
            b:SetBackdrop(nil)
            api.CreateBackdrop(b, nil, true)
        end)
        if api.SkinButton then each("button", function(b) api.SkinButton(b) end) end
        if api.SkinCheckbox then each("check", function(c) api.SkinCheckbox(c) end) end
        each("edit", function(e)
            api.StripTextures(e)
            api.CreateBackdrop(e)
        end)
        if api.SkinDropDown then
            each("drop", function(d) api.SkinDropDown(d, nil, nil, nil, true) end)
        end
        if api.SkinScrollbar then each("scroll", function(s) api.SkinScrollbar(s) end) end
        if api.SkinCloseButton then each("close", function(c) api.SkinCloseButton(c) end) end
        each("header", function(h) api.StripTextures(h) end)
        -- A row lights flat, the way pfUI's own lists do, not with the glow.
        each("row", function(r)
            local hl = r:GetHighlightTexture()
            if hl then
                hl:SetTexture(1, 1, 1, 0.1)
                hl:SetBlendMode("BLEND")
            end
        end)
    end)
    if not ok then
        -- A pfUI that changed underneath us: put the Blizzard frame back.
        if f.backdrop and f.backdrop.Hide then f.backdrop:Hide() end
        f:SetBackdrop(DIALOG)
        f.header:Show()
        f.title:ClearAllPoints()
        f.title:SetPoint("TOP", f.header, "TOP", 0, -14)
    end
    return ok
end

function RB.BuildGui()
    if RB.gui then return RB.gui end

    local f = CreateFrame("Frame", "ZyllaRaidResFrame", UIParent)
    f:SetWidth(W)
    f:SetHeight(H)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    -- HIGH, not DIALOG: the Clear typed confirmation is a StaticPopup on
    -- DIALOG, and must open in front of this window, not behind it.
    f:SetFrameStrata("HIGH")
    if f.SetToplevel then f:SetToplevel(true) end
    if f.SetClampedToScreen then f:SetClampedToScreen(true) end
    f:SetBackdrop(DIALOG)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:Hide()
    table.insert(UISpecialFrames, "ZyllaRaidResFrame")
    RB.gui = f

    -- the header banner, as on the Game Menu and Options windows
    f.header = f:CreateTexture(nil, "ARTWORK")
    f.header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    f.header:SetWidth(300)
    f.header:SetHeight(64)
    f.header:SetPoint("TOP", f, "TOP", 0, 12)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOP", f.header, "TOP", 0, -14)
    f.title:SetText("Zylla RaidRes")

    -- The top edge is the drag handle, so a drag never starts on a list.
    local bar = CreateFrame("Frame", nil, f)
    bar:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -2)
    bar:SetWidth(W - 60)
    bar:SetHeight(28)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function() this:GetParent():StartMoving() end)
    bar:SetScript("OnDragStop", function() this:GetParent():StopMovingOrSizing() end)

    f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    f.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -5)
    f.close:SetScript("OnClick", function() this:GetParent():Hide() end)

    -- fetching
    local linkLabel = text(f, "GameFontNormalSmall")
    linkLabel:SetPoint("TOPLEFT", f, "TOPLEFT", EDGE + 4, -38)
    linkLabel:SetText("Raidres link")
    f.link = editBox(f, "ZyllaRaidResLink", 214, "Paste a link or code")
    f.link:SetPoint("LEFT", linkLabel, "RIGHT", 12, 0)
    f.link:SetMaxLetters(120)
    f.link:SetScript("OnEnterPressed", function() RB.FetchFromBox() end)
    f.link:SetScript("OnTextChanged", function() syncPlaceholder(this) end)

    f.fetch = button(f, "Fetch", 70)
    f.fetch:SetPoint("LEFT", f.link, "RIGHT", 6, 0)
    f.fetch:SetScript("OnClick", function() RB.FetchFromBox() end)
    tip(f.fetch, "Fetch", "")

    f.status = text(f, "GameFontHighlightSmall")
    f.status:SetPoint("LEFT", f.fetch, "RIGHT", 10, 0)
    f.status:SetWidth(W - EDGE - (EDGE + 4 + 66 + 12 + 214 + 6 + 70 + 10) - 96 - 80 - 6)
    f.status:SetHeight(ROW_H)

    f.lockState = text(f, "GameFontHighlightSmall")
    f.lockState:SetPoint("RIGHT", f, "TOPRIGHT", -EDGE - 96 - 6, -35 + ROW_H / 2)
    f.lockState:SetJustifyH("RIGHT")
    f.lockState:Hide()

    f.lockBtn = button(f, "", 96)
    f.lockBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -EDGE, -35)
    f.lockBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f.lockBtn:SetScript("OnClick", function()
        if arg1 == "RightButton" then RB.LockRightClick() else RB.LockClick() end
    end)
    f.lockBtn:SetScript("OnEnter", function() RB.LockTooltip(this) end)
    f.lockBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.lockBtn:Hide()

    buildPlayers(f)
    buildLoot(f)

    -- what the next click will do, under the lists it is about
    f.hint = text(f, "GameFontNormalSmall")
    f.hint:SetPoint("TOPLEFT", f, "TOPLEFT", EDGE + 4, -HINT_TOP)
    f.hint:SetWidth(W - EDGE * 2 - 8)
    f.hint:SetHeight(ROW_H)

    buildRollFor(f)

    f:SetScript("OnShow", function()
        if PlaySound then PlaySound("igMainMenuOpen") end
        RB.Refresh()
        local box = RB.gui.link
        local s = RB.gui.snap
        if (box:GetText() or "") == "" and s and s.ref and s.ref ~= "manual" then
            box:SetText("https://raidres.top/res/" .. s.ref)
        end
        syncPlaceholder(box)
        if RB.MaybePollLock then RB.MaybePollLock() end
    end)
    f:SetScript("OnHide", function()
        if PlaySound then PlaySound("igMainMenuClose") end
        if CloseDropDownMenus then CloseDropDownMenus() end
        GameTooltip:Hide()
    end)
    -- Walking into a raid with the window open switches its loot.
    f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    f:SetScript("OnEvent", function()
        if event == "ZONE_CHANGED_NEW_AREA" then RB.Refresh() end
    end)
    -- Cheap while open, nothing while closed: watches for a fetch finishing
    -- and for the last notice running out.
    f:SetScript("OnUpdate", function()
        this.tick = (this.tick or 0) + arg1
        if this.tick < 0.25 then return end
        this.tick = 0
        local busy = ((RB.HttpBusy and RB.HttpBusy()) or RB.waiting) and true or false
        if busy ~= this.wasBusy then
            this.wasBusy = busy
            RB.DrawStatus()
        end
        if this.notice and GetTime() >= (this.noticeUntil or 0) then
            this.notice = nil
            RB.DrawHint()
        end
        -- Once a second: "sent 2 minutes ago" moves on, and an import made
        -- in RollFor's own window shows here without a click.
        this.rfTick = (this.rfTick or 0) + 1
        if this.rfTick >= 4 then
            this.rfTick = 0
            RB.DrawRollFor()
        end
        -- Is it still locked? A look every 30s, only while this is open.
        if RB.MaybePollLock then RB.MaybePollLock() end
        -- And a state nobody has confirmed for a few minutes stops being shown
        -- as fact, without waiting for something else to redraw.
        local label = RB.LockLabel(RB.gui.snap)
        if label ~= this.lockLabel then
            this.lockLabel = label
            RB.DrawStatus()
        end
        --[[ Raid members change zones without telling us, so every few
             seconds look at where they are. A full redraw only happens when
             the answer changes -- which raid, or how many are in it. ]]
        this.roster = (this.roster or 0) + 1
        if this.roster >= 12 then
            this.roster = 0
            local snap = RB.gui.snap
            local id, how, n = RB.GroupRaid(snap and snap.instance)
            if tostring(id) .. ":" .. tostring(how) .. ":" .. tostring(n) ~= RB.raidSignalKey then
                RB.Refresh()
            end
        end
    end)

    f.pfui = false
    if RB.SkinName() == "pfui" then f.pfui = RB.SkinForPfUI(f) end
    f.skin = f.pfui and "pfui" or "blizzard"
    RB.builtSkin = RB.builtSkin or f.skin
    return f
end

-- ---------------------------------------------------------------------------
-- Drawing it
-- ---------------------------------------------------------------------------

local STALE = 150   -- seconds without a look before the lock state is doubted

--[[ "locked", "unlocked", or "unknown". With the DLL the state is re-read
     every half minute, so one that hasn't been confirmed for a few minutes is
     doubted rather than shown as fact. Without it the state is as of the last
     fetch and can't be refreshed, so it stands. ]]
function RB.LockLabel(s)
    if not s or s.locked == nil then return "unknown" end
    if RB.Http and RB.Http() and s.lockAt and GetTime() - s.lockAt > STALE then return "unknown" end
    return s.locked and "locked" or "unlocked"
end

function RB.LockRightClick()
    local f = RB.gui
    if not f then return end
    local s = f.snap
    local ref = s and s.ref
    if not ref or ref == "manual" then return end
    if not (RB.LockControlReady and RB.LockControlReady()) then
        RB.Notice("enable lock control first: /rrb lockcontrol on")
        return
    end
    if RB.SendOpenCommand(ref) then
        RB.Notice("opening in Chrome...")
    else
        RB.Notice("can't reach the helper script. Is Nampower loaded?")
    end
end

function RB.LockClick()
    local f = RB.gui
    if not f then return end
    local s = f.snap
    local ref = s and s.ref

    if RB.LockControlReady and RB.LockControlReady() and ref and ref ~= "manual" then
        if RB.lockPending then
            RB.Notice("already sending...")
            return
        end
        if RB.sessionExpired then
            if RB.SendSigninCommand(ref) then
                RB.Notice("opening Chrome for sign in...")
                RB.DrawStatus()
            else
                RB.Notice("can't reach the lock script. Is Nampower loaded?")
            end
            return
        end
        local state = RB.LockLabel(s)
        if state == "unknown" then
            if RB.Http and RB.Http() then
                if RB.MaybePollLock(true) then RB.Notice("checking raidres...") end
            else
                RB.Notice("lock state unknown. Fetch the list first.")
            end
            return
        end
        local want = not s.locked
        if RB.SendLockCommand(ref, want) then
            RB.Notice(want and "locking..." or "unlocking...")
            RB.DrawStatus()
        else
            RB.Notice("can't reach the lock script. Is Nampower loaded?")
        end
        return
    end

    if RB.Http and RB.Http() then
        if RB.MaybePollLock(true) then
            RB.Notice("checking raidres...")
        else
            RB.Notice("already checking.")
        end
    else
        RB.Notice("press Fetch to check again.")
    end
end

function RB.LockTooltip(owner)
    local f = RB.gui
    local s = f and f.snap
    if not s or not s.ref then return end
    local state = RB.LockLabel(s)
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOMLEFT")
    GameTooltip:SetText("Raidres list " .. s.ref, 1, 0.82, 0)
    if state == "locked" then
        GameTooltip:AddLine("Locked: nobody can change their reserves on raidres.", 0.13, 1, 0.13, 1)
    elseif state == "unlocked" then
        GameTooltip:AddLine("Unlocked: people can still change their reserves on raidres.", 1, 0.82, 0, 1)
    else
        GameTooltip:AddLine("Not known right now.", 0.5, 0.5, 0.5, 1)
    end
    if RB.LockControlReady and RB.LockControlReady() then
        if RB.sessionExpired then
            GameTooltip:AddLine("Session expired. Click to open Chrome and sign in.", 1, 0.13, 0.13, 1)
        elseif RB.lockPending then
            GameTooltip:AddLine("Sending to the lock script...", 1, 0.82, 0, 1)
        elseif state ~= "unknown" then
            GameTooltip:AddLine("Click to " .. (s.locked and "unlock" or "lock") .. " it.", 1, 1, 1, 1)
        else
            GameTooltip:AddLine("Click to check the state.", 0.5, 0.5, 0.5, 1)
        end
        if RB.sessionExpiry then
            GameTooltip:AddLine("Session: " .. RB.sessionExpiry, 0.5, 0.5, 0.5, 1)
        end
        GameTooltip:AddLine("Right-click to open on raidres in Chrome.", 0.5, 0.5, 0.5, 1)
        GameTooltip:AddLine("Lock control on (/rrb lockcontrol). Needs the helper script.", 0.5, 0.5, 0.5, 1)
    elseif RB.Http and RB.Http() then
        if s.lockAt then
            GameTooltip:AddLine(string.format("Checked %.0f seconds ago; looks again every 30 while this window is open.",
                GetTime() - s.lockAt), 0.5, 0.5, 0.5, 1)
        else
            GameTooltip:AddLine("As of the last fetch; checking now.", 0.5, 0.5, 0.5, 1)
        end
        GameTooltip:AddLine("Click to check now.", 0.5, 0.5, 0.5)
    else
        GameTooltip:AddLine("As of the last fetch. Press Fetch to check again.", 0.5, 0.5, 0.5, 1)
    end
    if not (RB.LockControlReady and RB.LockControlReady()) then
        GameTooltip:AddLine("Lock or unlock it on the raidres site.", 0.5, 0.5, 0.5, 1)
    end
    GameTooltip:Show()
end

--- The list changed state on raidres while we were looking.
function RB.OnLockChanged(locked)
    if locked then
        RB.Notice("the list was locked on raidres.")
    else
        RB.Notice("the list was unlocked on raidres: reserves can change again.")
    end
end

function RB.DrawStatus()
    local f = RB.gui
    if not f then return end
    local s = f.snap
    local line
    if RB.HttpBusy and RB.HttpBusy() then
        line = hex(GOLD, "Fetching from raidres...")
    elseif RB.waiting then
        line = hex(GOLD, "Waiting for the watcher...")
    elseif s and s.ref then
        line = hex(WHITE, s.ref) .. hex(GREY, "  " .. RB.ListPlace(s))
    else
        line = hex(GREY, "No list yet. Paste a link, or add reserves by hand.")
    end
    f.status:SetText(line)

    -- The lock state indicator and button: only for a list from raidres.
    if s and s.ref and s.ref ~= "manual" then
        local state = RB.LockLabel(s)
        if RB.sessionExpired then
            f.lockState:SetText(hex(RED, "Session expired"))
        else
            f.lockState:SetText(state == "locked" and hex(GREEN, "Locked")
                or state == "unlocked" and hex(GOLD, "Unlocked") or hex(GREY, "Lock ?"))
        end
        f.lockState:Show()
        if RB.lockPending then
            f.lockBtn:SetText("...")
        elseif RB.sessionExpired then
            f.lockBtn:SetText("Sign in")
        elseif RB.LockControlReady and RB.LockControlReady() then
            if state == "locked" then
                f.lockBtn:SetText("Unlock")
            elseif state == "unlocked" then
                f.lockBtn:SetText("Lock")
            else
                f.lockBtn:SetText("Check")
            end
        else
            f.lockBtn:SetText("Check")
        end
        f.lockBtn:Show()
    else
        f.lockState:Hide()
        f.lockBtn:Hide()
    end

    if RB.Http and RB.Http() then
        f.fetch.tipBody = "Fetches the list in game, through RaidResHttp.dll."
    elseif RB.FileAPI() then
        f.fetch.tipBody = "Asks the watcher script outside the game for the list."
    else
        f.fetch.tipBody = "Can't fetch: needs RaidResHttp.dll, or Nampower and the watcher."
    end
end

-- Each RollFor state: its colour, the window's headline, the tooltip's word.
local ROLLFOR = {
    synced  = { GREEN, "In RollFor",                     "Up to date" },
    stale   = { GOLD,  "Changed since it was sent",      "Changed, not sent" },
    other   = { GOLD,  "RollFor holds a different list", "Holds another list" },
    cleared = { GOLD,  "RollFor's list was cleared",     "List cleared" },
    unsent  = { GOLD,  "Not sent to RollFor yet",        "Not sent yet" },
    failed  = { RED,   "RollFor refused the list",       "Refused the list" },
    missing = { RED,   "RollFor isn't loaded",           "Not loaded" },
    empty   = { GREY,  "Nothing to send yet",            "Nothing to send" },
}

local function plural(n, one, many) return n .. " " .. (n == 1 and one or many) end

local function ago(seconds)
    seconds = math.floor(seconds)
    if seconds < 10 then return "just now" end
    if seconds < 60 then return seconds .. " seconds ago" end
    local m = math.floor(seconds / 60)
    if m < 60 then return plural(m, "minute", "minutes") .. " ago" end
    return plural(math.floor(m / 60), "hour", "hours") .. " ago"
end

--- When the list RollFor holds was sent: by this session's clock, else the saved one.
function RB.SentAgo()
    if RB.sentAt then return ago(GetTime() - RB.sentAt) end
    local sent = RaidResBridge_Sent
    if sent and sent.at and time then return ago(time() - sent.at) end
    return nil
end

--[[ Where RollFor stands, in words: the coloured headline, the line under
     it, the short form for the minimap button's tooltip, its colour, and the
     state itself. ]]
function RB.RollForText(s)
    local state = RB.RollForState(s.sig, s.reserved)
    local look = ROLLFOR[state]
    local head, body = hex(look[1], look[2]), nil
    if state == "synced" then
        local when = RB.SentAgo()
        if when then head = head .. hex(GREY, "  sent " .. when) end
        body = plural(table.getn(s.merged.softreserves or {}), "player", "players") ..
            ", " .. plural(s.reserved, "reserve", "reserves") ..
            (s.typedCount > 0 and (", " .. s.typedCount .. " typed here") or "")
    elseif state == "stale" then body = "Press Send to bring RollFor up to date."
    elseif state == "other" then body = "Press Send to replace it with this one."
    elseif state == "cleared" then body = "Press Send to give it this list again."
    elseif state == "unsent" then body = "Press Send to import it."
    elseif state == "failed" then body = RB.sendError or ""
    elseif state == "missing" then body = "Reserves wait here until it is."
    else body = "Fetch a list, or add reserves by hand."
    end
    return head, body, look[3], look[1], state
end

function RB.DrawRollFor()
    local f = RB.gui
    if not f or not f:IsVisible() or not f.snap then return end
    local s = f.snap
    local head, body, _, _, state = RB.RollForText(s)
    f.rfHead:SetText(head)
    f.rfBody:SetText(body)
    -- RollFor's dice dim while there is no RollFor, or nothing for it.
    f.rfIcon:SetAlpha((state == "missing" or state == "empty") and 0.4 or 1)
    if state ~= "missing" and table.getn(s.merged.softreserves or {}) > 0 then
        f.send:Enable()
    else
        f.send:Disable()
    end
    local rf = RollFor and RollFor.key_bindings
    if rf and type(rf.softres_toggle) == "function" then f.view:Enable() else f.view:Disable() end
    if s.typedCount > 0 then f.clear:Enable() else f.clear:Disable() end
end

function RB.DrawHint()
    local f = RB.gui
    if not f then return end
    local s = f.snap
    local line
    if f.notice and GetTime() < (f.noticeUntil or 0) then
        line = hex(WHITE, f.notice)
    elseif not RB.player then
        line = "Pick a player, then click loot to reserve it for them."
    elseif s and s.inRaid and s.absent[key(RB.player)] and next(s.free) ~= nil then
        line = RB.player .. " isn't in your raid. If they're here under another name, press Match."
    else
        local n = table.getn(s and s.items[key(RB.player)] or {})
        local limit = RB.Limit()
        if n >= limit then
            line = RB.player .. " is full. Click one of their items to take it back."
        else
            line = "Click loot to reserve it for " .. RB.player .. " (" ..
                (limit - n) .. " left)."
        end
    end
    f.hint:SetText(line)
end

local function selected(s)
    if not RB.player then return nil end
    local k = key(RB.player)
    for _, p in ipairs(s.players) do
        if key(p.name) == k then return p end
    end
    return { name = RB.player, count = table.getn(s.items[k] or {}) }
end

local function drawPlayers(f, s)
    local limit = RB.Limit()
    local list = {}
    for _, p in ipairs(s.players) do
        if not RB.missingOnly or p.count < limit then table.insert(list, p) end
    end
    local done = RB.Progress(s)
    f.pBox.label:SetText("Players" .. hex(GREY, "  " .. done .. " of " ..
        table.getn(s.players) .. " done") ..
        ((s.inRaid and s.toCheck > 0) and hex(GOLD, "  " .. s.toCheck .. " to check") or ""))
    f.missing:SetChecked(RB.missingOnly)

    local n = table.getn(list)
    FauxScrollFrame_Update(f.pScroll, n, P_ROWS, ROW_H)
    local offset = FauxScrollFrame_GetOffset(f.pScroll)
    local sel = RB.player and key(RB.player)
    for i = 1, P_ROWS do
        local row = f.pRows[i]
        local p = list[i + offset]
        row.data = p
        if p then
            local full = p.count >= limit
            local tag = ""
            local m = s.matchedBy[key(p.name)]
            if p.inRaid and m then
                tag = hex(GREY, "  as " .. m.signup)
            elseif not p.inRaid then
                local g = s.inRaid and s.guesses[key(p.name)]
                tag = g and hex(GOLD, "  maybe " .. g.name .. "?") or hex(GREY, "  not here")
            end
            row.text:SetText(hex(classHex(p.class), p.name) .. tag)
            local cc = (p.count == 0 and RED) or (full and GREEN) or GOLD
            row.count:SetText(hex(cc, p.count .. "/" .. limit))
            row:SetAlpha(p.inRaid and 1 or 0.7)
            setSelected(row, sel == key(p.name))
            row:Show()
        else
            setSelected(row, false)
            row:Hide()
        end
    end
    if n == 0 then
        f.pEmpty:SetText(RB.missingOnly and "Everyone has their reserves." or "Nobody yet.")
        f.pEmpty:Show()
    else
        f.pEmpty:Hide()
    end
end

local function drawDetail(f, s, sel)
    for i = 1, D_ROWS do f.dRows[i]:Hide() end
    local mk = RB.player and key(RB.player)
    local canMatch = false
    if s.inRaid and mk then
        if s.matchedBy[mk] then canMatch = true
        elseif s.absent[mk] and next(s.free) ~= nil then canMatch = true
        elseif s.free[mk] and next(s.absent) ~= nil then canMatch = true end
    end
    if canMatch then f.matchBtn:Show() else f.matchBtn:Hide() end
    if not RB.player then
        f.dBox.label:SetText("Reserves")
        f.dEmpty:SetText("Pick a player to see and change their reserves.")
        f.dEmpty:Show()
        return
    end
    local limit = RB.Limit()
    local k = key(RB.player)
    local items = s.items[k] or {}
    local n = table.getn(items)
    f.dBox.label:SetText(hex(classHex(sel and sel.class), RB.player) ..
        hex(WHITE, "'s reserves") .. hex(GREY, "  " .. n .. " of " .. limit))
    if n == 0 then
        f.dEmpty:SetText("Nothing yet. Click loot to reserve it.")
        f.dEmpty:Show()
    else
        f.dEmpty:Hide()
    end

    local web = s.web[k] or {}
    local shown = n
    if n > D_ROWS then shown = D_ROWS - 1 end
    for i = 1, shown do
        local it = items[i]
        local row = f.dRows[i]
        local name, q, icon = RB.ItemInfo(it.id)
        row.itemId = it.id
        row.icon:SetTexture(icon or QMARK)
        row.icon:Show()
        row.text:SetText(hex(qualityHex(q), name))
        if web[it.id] then
            row.tag:Show()
            row.remove:Hide()
        else
            row.tag:Hide()
            row.remove:Show()
        end
        row:Show()
    end
    if n > D_ROWS then
        local row = f.dRows[D_ROWS]
        row.itemId = nil
        row.icon:Hide()
        row.text:SetText(hex(GREY, "+" .. (n - shown) .. " more (hover their name)"))
        row.tag:Hide()
        row.remove:Hide()
        row:Show()
    end
end

-- Who holds an item, as it fits on a row: the selected player first.
local function holdersText(holders, hard)
    if hard then return hex(RED, "Hard reserve") end
    local n = table.getn(holders)
    if n == 0 then return "" end
    local sk = RB.player and key(RB.player)
    local ordered = {}
    for _, name in ipairs(holders) do
        if sk and key(name) == sk then table.insert(ordered, 1, name)
        else table.insert(ordered, name) end
    end
    local parts = {}
    for i = 1, math.min(n, 2) do
        local name = ordered[i]
        table.insert(parts, hex((sk and key(name) == sk) and GREEN or GOLD, name))
    end
    return table.concat(parts, hex(GREY, ", ")) ..
        (n > 2 and hex(GREY, " +" .. (n - 2)) or "")
end

local function drawLoot(f, s, sel)
    local cls = sel and sel.class
    if cls then
        f.classOnly:Enable()
        if f.classOnly.label then f.classOnly.label:SetTextColor(1, 0.82, 0) end
    else
        f.classOnly:Disable()
        if f.classOnly.label then f.classOnly.label:SetTextColor(0.5, 0.5, 0.5) end
    end
    f.classOnly:SetChecked(RB.classOnly)

    local raid = RB.CurrentRaid(s)
    if not raid then
        UIDropDownMenu_SetText("No loot tables", f.raidDrop)
        f.lEmpty:SetText("No loot tables yet.\nDownload them once; they only change " ..
            "when the server patches.")
        f.lEmpty:Show()
        f.lEmptyButton:Show()
        for i = 1, L_ROWS do f.lRows[i]:Hide() end
        FauxScrollFrame_Update(f.lScroll, 0, L_ROWS, ROW_H)
        return
    end
    f.lEmptyButton:Hide()
    f.lBox.label:SetText("Loot" .. hex(GREY,
        (RB.raidWhy == "zone" and "  you're here")
        or (RB.raidWhy == "group" and ("  " .. (RB.raidCount or 1) ..
            ((RB.raidCount or 1) == 1 and " of your raid is here" or " of your raid are here")))
        or (RB.raidWhy == "list" and "  the list's raid") or ""))
    UIDropDownMenu_SetSelectedValue(f.raidDrop, RB.raid)
    UIDropDownMenu_SetText(raid.name, f.raidDrop)

    local rows = RB.ItemRows(RB.raid, {
        search = RB.search,
        class = (RB.classOnly and cls) or nil,
        collapsed = RB.collapsed,
    })
    local n = table.getn(rows)
    if n == 0 then
        f.lEmpty:SetText((RB.search and RB.search ~= "")
            and ("Nothing in " .. raid.name .. " matches \"" .. RB.search .. "\".")
            or "Nothing here for that class.")
        f.lEmpty:Show()
    else
        f.lEmpty:Hide()
    end

    FauxScrollFrame_Update(f.lScroll, n, L_ROWS, ROW_H)
    local offset = FauxScrollFrame_GetOffset(f.lScroll)

    local mine, full = {}, false
    if RB.player then
        local items = s.items[key(RB.player)] or {}
        for _, it in ipairs(items) do mine[it.id] = true end
        full = table.getn(items) >= RB.Limit()
    end

    for i = 1, L_ROWS do
        local row = f.lRows[i]
        local d = rows[i + offset]
        row.data = d
        if d and d.header then
            row.icon:Hide()
            row.check:Hide()
            row.text:SetText("")
            row.who:SetText("")
            row.toggle:SetTexture(d.collapsed and PLUS or MINUS)
            row.toggle:Show()
            row.head:SetText(d.header)
            row.head:Show()
            row:SetAlpha(1)
            row:Show()
        elseif d then
            local it = d.item
            local name, q, icon = RB.ItemInfo(it.g)
            row.toggle:Hide()
            row.head:Hide()
            row.icon:SetTexture(icon or QMARK)
            row.icon:Show()
            row.text:SetText(hex(qualityHex(q), name))
            row.who:SetText(holdersText(s.holders[it.g] or {}, s.hard[it.g]))
            if mine[it.g] then row.check:Show() else row.check:Hide() end
            row:SetAlpha((full and not mine[it.g]) and 0.45 or 1)
            row:Show()
        else
            row:Hide()
        end
    end
end

--[[ Redraw from the last snapshot. Scrolling calls this directly, so a wheel
     tick costs no file read. Guarded, because FauxScrollFrame_Update can
     scroll back to the top -- which calls this again from inside itself. ]]
function RB.Draw()
    local f = RB.gui
    if not f or not f:IsVisible() or not f.snap or f.drawing then return end
    f.drawing = true
    local ok, err = pcall(function()
        local s = f.snap
        local sel = selected(s)
        RB.DrawStatus()
        drawPlayers(f, s)
        drawDetail(f, s, sel)
        drawLoot(f, s, sel)
        RB.DrawHint()
        RB.DrawRollFor()
    end)
    f.drawing = nil
    if not ok then error(err, 0) end
end

--- Recompute everything after the data changed, then redraw.
function RB.Refresh()
    local f = RB.gui
    if not f or not f:IsVisible() then return end
    f.snap = RB.Snapshot()
    RB.Draw()
end

function RB.ToggleGui()
    local f = RB.BuildGui()
    if f:IsVisible() then
        f:Hide()
    else
        RB.LoadRaids()
        f:Show()
    end
end

-- The class filter starts on: it only ever hides other classes' items.
if RB.classOnly == nil then RB.classOnly = true end
