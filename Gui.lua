--[[ The window: pick a player, pick an instance, click the loot.

     Typing a name and shift-clicking an item worked, but it is the wrong shape
     for the job. On the night the raid leader is looking at a roster and a
     list of people who have not reserved, not at an empty text box -- so the
     players come from the raid itself, each showing how many reserves they
     have against the limit, and the loot comes from raidres's own table for
     the instance, grouped by boss.

     Plain 1.12 frames rather than RollFor's widgets, so this survives RollFor
     reorganising its own.

     The left pane does double duty: players normally, and the instance list
     when you are choosing one. Two uses of one set of row widgets rather than
     a dropdown, because UIDropDownMenu in 1.12 is fiddly enough that an
     untested one is a liability, and a list that is already there is not. ]]

local RB = RaidResBridge

local ROWS = 14
local ROW_H = 16
local LEFT_W = 150
local RIGHT_W = 290

local QUALITY = {
    [0] = "9d9d9d", [1] = "ffffff", [2] = "1eff00",
    [3] = "0070dd", [4] = "a335ee", [5] = "ff8000",
}

local CLASS_COLOUR = {
    WARRIOR = "c79c6e", PALADIN = "f58cba", HUNTER = "abd473", ROGUE = "fff569",
    PRIEST = "ffffff", SHAMAN = "0070de", MAGE = "69ccf0", WARLOCK = "9482c9",
    DRUID = "ff7d0a",
}

local function say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff8fd3ffRaidRes|r: " .. msg)
end

local function itemIdFrom(link)
    if not link then return nil end
    local _, _, id = string.find(link, "item:(%d+)")
    return tonumber(id)
end

-- ---------------------------------------------------------------------------
-- What the panes show
-- ---------------------------------------------------------------------------

--[[ Who can be given a reserve.

     The raid first, because that is who is actually there, and anyone already
     on the list after it -- a signup who has not zoned in yet still has
     reserves worth seeing. Sorted with the people who have reserved nothing at
     the top, since they are the reason this window is open. ]]
function RB.Players()
    local counts, classes = {}, {}
    local data = RB.Merged()
    for _, p in ipairs(data.softreserves or {}) do
        counts[string.lower(p.name)] = table.getn(p.items or {})
    end

    local out, seen = {}, {}
    local function add(name, class)
        if not name or name == "" then return end
        local k = string.lower(name)
        if seen[k] then return end
        seen[k] = true
        table.insert(out, { name = name, class = class,
                            count = counts[k] or 0, inRaid = class ~= nil })
    end

    local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
    if raid > 0 then
        for i = 1, raid do
            local name, _, _, _, _, class = GetRaidRosterInfo(i)
            add(name, class and string.upper(class))
        end
    else
        add(UnitName("player"), select and nil or nil)
        local _, cls = UnitClass("player")
        if out[1] then out[1].class = cls end
        local party = GetNumPartyMembers and GetNumPartyMembers() or 0
        for i = 1, party do
            local unit = "party" .. i
            local _, c = UnitClass(unit)
            add(UnitName(unit), c)
        end
    end

    for _, p in ipairs(data.softreserves or {}) do add(p.name, nil) end

    --[[ Nobody-yet first, then by name. The ones at the limit sink, because
         there is nothing left to do with them. ]]
    local limit = RB.Limit()
    table.sort(out, function(a, b)
        local af = (a.count >= limit) and 1 or 0
        local bf = (b.count >= limit) and 1 or 0
        if af ~= bf then return af < bf end
        if a.count ~= b.count then return a.count < b.count end
        return a.name < b.name
    end)
    return out
end

--- How many reserves each player is allowed. The event says; two is the usual.
function RB.Limit()
    return RaidResBridge_Limit or 2
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

--[[ One instance's loot, boss by boss.

     Flattened into rows with headers rather than nested, so the scroll offset
     stays a plain index into a list. ]]
function RB.ItemRows(raidId)
    local raid = (RaidResBridge_Raids or {})[raidId]
    if not raid then return {} end
    local groups, order = {}, {}
    for _, it in ipairs(raid.items or {}) do
        local boss = it.b or ""
        if not groups[boss] then
            groups[boss] = {}
            table.insert(order, boss)
        end
        table.insert(groups[boss], it)
    end
    local rows = {}
    for _, boss in ipairs(order) do
        table.insert(rows, { header = boss ~= "" and boss or "Elsewhere" })
        for _, it in ipairs(groups[boss]) do table.insert(rows, { item = it }) end
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

-- ---------------------------------------------------------------------------
-- The window
-- ---------------------------------------------------------------------------

function RB.BuildGui()
    if RB.gui then return RB.gui end

    local f = CreateFrame("Frame", "RaidResBridgeFrame", UIParent)
    f:SetWidth(LEFT_W + RIGHT_W + 50)
    f:SetHeight(ROWS * ROW_H + 110)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    f:Hide()
    table.insert(UISpecialFrames, "RaidResBridgeFrame")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -14)
    title:SetText("Soft Reserves")

    f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.sub:SetPoint("TOP", title, "BOTTOM", 0, -2)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)

    -- left: players, or the instance list while choosing one
    f.leftHead = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.leftHead:SetWidth(LEFT_W)
    f.leftHead:SetHeight(18)
    f.leftHead:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -48)
    f.leftHead:SetScript("OnClick", function()
        --[[ The same button both enters and leaves the instance list, so the
             way back is where the way in was. ]]
        RB.pickingRaid = not RB.pickingRaid
        RB.Refresh()
    end)

    f.left = {}
    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, f)
        row:SetWidth(LEFT_W)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", f.leftHead, "BOTTOMLEFT", 0, -2 - (i - 1) * ROW_H)
        local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("LEFT", row, "LEFT", 4, 0)
        text:SetWidth(LEFT_W - 8)
        text:SetJustifyH("LEFT")
        row.text = text
        row:SetScript("OnClick", function()
            local d = this.data
            if not d then return end
            if d.raidId then
                RB.raid = d.raidId
                RB.pickingRaid = false
            else
                RB.player = d.name
            end
            RB.Refresh()
        end)
        f.left[i] = row
    end

    -- right: the chosen instance's loot
    f.rightHead = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.rightHead:SetPoint("TOPLEFT", f.leftHead, "TOPRIGHT", 14, -4)

    f.right = {}
    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, f)
        row:SetWidth(RIGHT_W)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", f.leftHead, "BOTTOMLEFT", LEFT_W + 14, -2 - (i - 1) * ROW_H)
        local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("LEFT", row, "LEFT", 4, 0)
        text:SetWidth(RIGHT_W - 10)
        text:SetJustifyH("LEFT")
        row.text = text

        row:SetScript("OnClick", function() RB.ClickItem(this.data) end)
        row:SetScript("OnEnter", function()
            local d = this.data
            if d and d.item and d.item.g then
                GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink("item:" .. d.item.g .. ":0:0:0")
                local who = RB.WhoHas(d.item.g)
                if table.getn(who) > 0 then
                    GameTooltip:AddLine("Reserved by " .. table.concat(who, ", "),
                        0.56, 0.83, 1)
                end
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.right[i] = row
    end

    local scroll = CreateFrame("ScrollFrame", "RaidResBridgeScroll", f,
        "FauxScrollFrameTemplate")
    scroll:SetWidth(RIGHT_W)
    scroll:SetHeight(ROWS * ROW_H)
    scroll:SetPoint("TOPLEFT", f.leftHead, "BOTTOMLEFT", LEFT_W + 14, -2)
    scroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(ROW_H, RB.Refresh)
    end)
    f.scroll = scroll

    -- bottom
    local apply = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    apply:SetWidth(110)
    apply:SetHeight(20)
    apply:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 16)
    apply:SetText("Send to RollFor")
    apply:SetScript("OnClick", function() RB.Apply() end)

    local refetch = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refetch:SetWidth(80)
    refetch:SetHeight(20)
    refetch:SetPoint("LEFT", apply, "RIGHT", 6, 0)
    refetch:SetText("Re-fetch")
    refetch:SetScript("OnClick", function()
        local _, _, got = RB.Read()
        local ref = RB.loaded or got
        if ref then RB.Request(ref)
        else say("nothing to re-fetch. |cffffffff/rrb <link>|r first.") end
    end)

    local loot = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    loot:SetWidth(80)
    loot:SetHeight(20)
    loot:SetPoint("LEFT", refetch, "RIGHT", 6, 0)
    loot:SetText("Get loot")
    loot:SetScript("OnClick", function()
        --[[ The loot tables are a separate, rarely-changing download, so they
             are asked for explicitly rather than with every list. ]]
        if RB.Http and RB.Http() then
            if RB.HttpBusy() then
                say("still fetching; give it a moment.")
            else
                RB.HttpRaids()
            end
        elseif RB.FileAPI() then
            pcall(WriteCustomFile, RB.REQUEST, "RAIDS", "w")
            say("asked the watcher for the loot tables; |cffffffff/reload|r " ..
                "once it says it has written them.")
        else
            say("|cffff5179Nampower's file API is missing|r.")
        end
    end)

    local wipe = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    wipe:SetWidth(80)
    wipe:SetHeight(20)
    wipe:SetPoint("LEFT", loot, "RIGHT", 6, 0)
    wipe:SetText("Clear typed")
    wipe:SetScript("OnClick", function()
        RB.ClearManual()
        RB.Refresh()
        RB.Apply(true)
        say("cleared everything added by hand; the fetched list is untouched.")
    end)

    RB.gui = f
    return f
end

--[[ Clicking an item gives it to whoever is selected, or takes it back.

     Only ever the typed list: an item somebody reserved on the website is
     shown as theirs and cannot be removed here, because it would come straight
     back on the next fetch and look like the window was lying. ]]
function RB.ClickItem(data)
    if not data or not data.item then return end
    local who = RB.player
    if not who then
        say("pick a player on the left first.")
        return
    end
    local id = data.item.g
    if not id then return end

    if RB.RemoveManual(who, id) then
        RB.Refresh()
        RB.Apply(true)
        return
    end

    local held = RB.WhoHas(id)
    for i = 1, table.getn(held) do
        if string.lower(held[i]) == string.lower(who) then
            say(who .. " has that from the website; it cannot be removed here.")
            return
        end
    end

    local count = 0
    for _, p in ipairs(RB.Merged().softreserves or {}) do
        if string.lower(p.name) == string.lower(who) then
            count = table.getn(p.items or {})
        end
    end
    if count >= RB.Limit() then
        say(who .. " already has " .. count .. " of " .. RB.Limit() ..
            ". Remove one first.")
        return
    end

    local ok, err = RB.AddManual(who, id, data.item.q or 4)
    if not ok then
        say("|cffffcc00" .. (err or "could not add that") .. "|r")
        return
    end
    RB.Refresh()
    RB.Apply(true)
end

function RB.Refresh()
    local f = RB.gui
    if not f or not f:IsVisible() then return end

    local limit = RB.Limit()
    local data = RB.Merged()
    local total, manual = 0, 0
    for _, p in ipairs(data.softreserves or {}) do
        total = total + table.getn(p.items or {})
    end
    for _, row in pairs(RaidResBridge_Manual or {}) do
        manual = manual + table.getn(row.items or {})
    end
    f.sub:SetText(total .. " reservation(s), limit " .. limit .. " each" ..
        (manual > 0 and ("  |cff8fd3ff" .. manual .. " by hand|r") or ""))

    -- left
    local leftRows
    if RB.pickingRaid then
        f.leftHead:SetText("< back")
        leftRows = RB.RaidList()
    else
        f.leftHead:SetText(RB.player or "pick a player")
        leftRows = RB.Players()
    end
    for i = 1, ROWS do
        local row = f.left[i]
        local d = leftRows[i]
        row.data = d
        if d then
            if d.raidId or d.id then
                d.raidId = d.id
                row.text:SetText("|cffffffff" .. d.name .. "|r |cff888888" ..
                    d.count .. "|r")
            else
                local colour = CLASS_COLOUR[d.class or ""] or "ffffff"
                local full = d.count >= limit
                row.text:SetText("|cff" .. (full and "666666" or colour) ..
                    d.name .. "|r  |cff" ..
                    (full and "666666" or (d.count == 0 and "ff5179" or "888888")) ..
                    d.count .. "/" .. limit .. "|r" ..
                    (RB.player and string.lower(RB.player) == string.lower(d.name)
                        and "  |cff8fd3ff<|r" or ""))
            end
            row:Show()
        else
            row:Hide()
        end
    end

    -- right
    local raids = RaidResBridge_Raids or {}
    local raid = RB.raid and raids[RB.raid]
    if not raid then
        local list = RB.RaidList()
        if table.getn(list) > 0 then
            RB.raid = list[1].id
            raid = raids[RB.raid]
        end
    end

    if not raid then
        f.rightHead:SetText("|cffffcc00no loot tables yet - press 'Get loot'|r")
        for i = 1, ROWS do f.right[i]:Hide() end
        FauxScrollFrame_Update(f.scroll, 0, ROWS, ROW_H)
        return
    end

    f.rightHead:SetText(raid.name .. "  |cff888888(click the name on the left " ..
        "to change)|r")
    if not RB.pickingRaid then
        f.leftHead:SetText((RB.player or "pick a player") .. "   |cff888888[" ..
            raid.name .. "]|r")
    end

    local rows = RB.ItemRows(RB.raid)
    local n = table.getn(rows)
    FauxScrollFrame_Update(f.scroll, n, ROWS, ROW_H)
    local offset = FauxScrollFrame_GetOffset(f.scroll)

    for i = 1, ROWS do
        local row = f.right[i]
        local d = rows[i + offset]
        row.data = d
        if d then
            if d.header then
                row.text:SetText("|cffffd100" .. d.header .. "|r")
            else
                local it = d.item
                local who = RB.WhoHas(it.g)
                local colour = QUALITY[it.q] or "ffffff"
                local tag = ""
                if table.getn(who) > 0 then
                    tag = "  |cff8fd3ff" .. table.concat(who, ", ") .. "|r"
                end
                row.text:SetText("  |cff" .. colour .. it.n .. "|r" .. tag)
            end
            row:Show()
        else
            row:Hide()
        end
    end
end

function RB.ToggleGui()
    local f = RB.BuildGui()
    if f:IsVisible() then
        f:Hide()
    else
        f:Show()
        RB.Refresh()
    end
end
