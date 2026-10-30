--[[ A new raidres event, from in game.

     raidres's own "Create event" form, made of the client's parts:
       - the raid, grouped by size the way raidres groups it;
       - the day and the time, on this PC's clock;
       - how many soft reserves each;
       - the switches a raid leader reaches for;
       - a description.
     The lock helper makes the event in the signed-in Chrome, exactly as
     the form would. Then its link goes into the window's box, the list is
     fetched, and the raid can be told in chat.

     What the form keeps for later -- hard reserves, extra admins, banned
     users -- is left to raidres's site, where each is a list to manage
     rather than one field.

     The choices are remembered (RaidResBridge_NewEvent), because next
     week's event is usually this week's. Every menu entry's func reads
     this.value; nothing is captured from a loop. ]]

local RB = RaidResBridge
local UI            -- RB.UI, once Gui.lua has made it

local W, H = 360, 420
local EDGE = 20
local COL = EDGE + 88       -- where the controls start, after their labels

local HEADER = "Interface\\DialogFrame\\UI-DialogBox-Header"

-- raidres's raid kinds, in the order its own picker shows them.
local KINDS = {
    { kind = "RAID40", name = "40-man" },
    { kind = "RAID25", name = "25-man" },
    { kind = "RAID20", name = "20-man" },
    { kind = "RAID10", name = "10-man" },
    { kind = "WORLDBOSS", name = "World boss" },
}
local MINUTES = { 0, 15, 30, 45 }
local DAYS = 14
local MOST = 6              -- reserves each, at most, on offer here
local INCREASES = { 0, 5, 10, 15, 20, 25, 50 }   -- SR+ added each event

local function say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff8fd3ffRaidRes|r: " .. msg)
end

local function remembered()
    RaidResBridge_NewEvent = RaidResBridge_NewEvent or {}
    return RaidResBridge_NewEvent
end

local function byName(a, b) return a.name < b.name end

--[[ The raids to offer, as menu rows: raidres's own list, grouped by kind,
     once the DLL has fetched it; until then, or without the DLL, whichever
     loot tables are cached, in one group. ]]
function RB.EventRaids()
    local rows = {}
    if RB.raidList then
        for _, k in ipairs(KINDS) do
            local group = {}
            for _, r in ipairs(RB.raidList) do
                if r.kind == k.kind then table.insert(group, r) end
            end
            table.sort(group, byName)
            if table.getn(group) > 0 then
                table.insert(rows, { title = k.name })
                for _, r in ipairs(group) do table.insert(rows, { id = r.id, name = r.name }) end
            end
        end
        return rows
    end
    for id, raid in pairs(RaidResBridge_Raids or {}) do
        table.insert(rows, { id = id, name = raid.name or "?" })
    end
    table.sort(rows, byName)
    return rows
end

local function raidName(id)
    for _, r in ipairs(RB.EventRaids()) do
        if r.id == id then return r.name end
    end
    return nil
end

-- The next two weeks, on this PC's clock.
local function days()
    local out, now = {}, time()
    for i = 0, DAYS - 1 do
        local t = now + i * 86400
        local name = date("%a %d %b", t)
        if i == 0 then name = "Today, " .. name elseif i == 1 then name = "Tomorrow, " .. name end
        table.insert(out, { value = date("%Y-%m-%d", t), text = name })
    end
    return out
end

local function dayName(value)
    for _, d in ipairs(days()) do
        if d.value == value then return d.text end
    end
    return value
end

local function two(n) return string.format("%02d", n) end

-- ---------------------------------------------------------------------------
-- The menus
-- ---------------------------------------------------------------------------

local function form() return RB.eventForm end

local function picked()
    if CloseDropDownMenus then CloseDropDownMenus() end
    RB.DrawNewEvent()
end

local function onPickRaid()
    local e = form()
    -- another raid's loot can't be hard-reserved here
    if e.raid ~= this.value then
        e.hr, e.tpl, e.tplName, e.prev = {}, nil, nil, nil
        e.skip, e.input, e.valid = nil, nil, nil
    end
    e.raid = this.value
    picked()
end
local function onPickDay() form().day = this.value; picked() end
local function onPickHour() form().hour = this.value; picked() end
local function onPickMinute() form().minute = this.value; picked() end
local function onPickLimit() form().limit = this.value; picked() end

local function add(text, value, func, checked)
    local info = {}
    info.text = text
    if value == nil then
        info.isTitle = 1
    elseif value == "-" then
        info.disabled = 1       -- a line to read, not to pick
    else
        info.value = value
        info.func = func
        info.checked = checked and 1 or nil
    end
    UIDropDownMenu_AddButton(info)
end

function RB.InitEventRaidMenu()
    local e = form()
    if not e then return end
    local rows = RB.EventRaids()
    if table.getn(rows) == 0 then
        add(RB.eventRaidsAsked and "Fetching raidres's raids..." or "No raids known yet")
        return
    end
    for _, r in ipairs(rows) do
        if r.title then add(r.title) else add(r.name, r.id, onPickRaid, r.id == e.raid) end
    end
end

function RB.InitEventDayMenu()
    local e = form()
    if not e then return end
    for _, d in ipairs(days()) do add(d.text, d.value, onPickDay, d.value == e.day) end
end

function RB.InitEventHourMenu()
    local e = form()
    if not e then return end
    for h = 0, 23 do add(two(h), h, onPickHour, h == e.hour) end
end

function RB.InitEventMinuteMenu()
    local e = form()
    if not e then return end
    for _, m in ipairs(MINUTES) do add(two(m), m, onPickMinute, m == e.minute) end
end

function RB.InitEventLimitMenu()
    local e = form()
    if not e then return end
    for n = 1, MOST do add(tostring(n), n, onPickLimit, n == e.limit) end
end

-- ---------------------------------------------------------------------------
-- Hard reserves: none, one of your saved lists, or items picked boss by boss
-- ---------------------------------------------------------------------------

-- The chosen raid's cached loot, by boss, in the loot table's order.
local function bosses(raidId)
    local raid = (RaidResBridge_Raids or {})[raidId]
    local out, at = {}, {}
    for _, it in ipairs(raid and raid.items or {}) do
        local b = it.b or ""
        if not at[b] then
            at[b] = { name = (b ~= "" and b) or "Elsewhere", items = {} }
            table.insert(out, at[b])
        end
        table.insert(at[b].items, it)
    end
    return out
end

local function hrHas(e, id)
    for _, g in ipairs(e.hr) do if g == id then return true end end
    return false
end

local function onPickHrNone()
    local e = form()
    e.tpl, e.tplName, e.hr, e.hrChanged = nil, nil, {}, true
    picked()
end

local function onPickHrList()
    local e = form()
    e.tpl, e.hr, e.hrChanged = this.value, {}, true
    for _, l in ipairs(RB.savedLists or {}) do
        if l.id == this.value then e.tplName = l.name end
    end
    picked()
end

-- An item ticked or unticked; the menu stays open for the next one.
local function onToggleHrItem()
    local e = form()
    e.tpl, e.tplName, e.hrChanged = nil, nil, true
    local id = this.value
    if hrHas(e, id) then
        for i = table.getn(e.hr), 1, -1 do
            if e.hr[i] == id then table.remove(e.hr, i) end
        end
    else
        table.insert(e.hr, id)
    end
    RB.DrawNewEvent()
end

--[[ Level 1: none, your saved lists for this raid, then each boss with an
     arrow; level 2: that boss's loot, ticked as hard reserves. 1.12 hands
     the level and the opened entry's value over in globals. ]]
function RB.InitEventHrMenu()
    local e = form()
    if not e then return end
    local level = UIDROPDOWNMENU_MENU_LEVEL or 1
    if level == 2 then
        local b = bosses(e.raid)[UIDROPDOWNMENU_MENU_VALUE or 0]
        for _, it in ipairs(b and b.items or {}) do
            local info = {}
            info.text = it.n
            info.value = it.g
            info.func = onToggleHrItem
            info.checked = hrHas(e, it.g) and 1 or nil
            info.keepShownOnClick = 1
            UIDropDownMenu_AddButton(info, 2)
        end
        return
    end
    add("None", "none", onPickHrNone, not e.tpl and table.getn(e.hr) == 0)
    add("Your saved lists")
    local any = false
    for _, l in ipairs(RB.savedLists or {}) do
        if l.raid == e.raid then
            any = true
            add(l.name .. UI.hex(UI.GREY, "  " .. (l.hr or 0) .. " HR"), l.id, onPickHrList, e.tpl == l.id)
        end
    end
    if not any then
        local info = {}
        if RB.savedLists then
            info.text = "None for this raid"
            info.disabled = 1
        elseif RB.templatesState == "asking" then
            info.text = "Asking raidres..."
            info.disabled = 1
        else
            -- it failed, or the helper was busy: asked again from here
            info.text = "Couldn't get them. Ask again"
            info.value = "retry"
            info.func = RB.RetryTemplates
        end
        UIDropDownMenu_AddButton(info)
    end
    add("Pick items")
    local list = bosses(e.raid)
    if table.getn(list) == 0 then
        local info = {}
        info.text = "Get the loot tables first"
        info.disabled = 1
        UIDropDownMenu_AddButton(info)
    end
    for i = 1, table.getn(list) do
        local info = {}
        info.text = list[i].name
        info.value = i
        info.hasArrow = 1
        info.notClickable = 1
        UIDropDownMenu_AddButton(info)
    end
end

--[[ Your saved HR lists, asked of raidres once a session. RB.templatesState
     is "asking" while it's out and "failed" when it came back without them:
     the HR menu then offers to ask again, and so does opening the dialog. ]]
local function askTemplates()
    if RB.savedLists or RB.templatesState or RB.HelperBusy() then return end
    if RB.SendTemplatesCommand() then RB.templatesState = "asking" end
end

function RB.RetryTemplates()
    if CloseDropDownMenus then CloseDropDownMenus() end
    RB.templatesState = nil
    askTemplates()
    RB.DrawNewEvent()
end

function RB.OnTemplatesResult(text)
    RB.savedLists = RB.ReadTemplates(text) or RB.savedLists
    RB.templatesState = (not RB.savedLists) and "failed" or nil
    if not RB.savedLists and string.sub(text, 1, 6) == "signin" then RB.sessionExpired = true end
    RB.DrawNewEvent()
end

-- What failed last time is asked again when the dialog opens.
local function forgetFailures()
    if RB.templatesState == "failed" then RB.templatesState = nil end
    for raid, v in pairs(RB.prevAsked or {}) do
        if v == "failed" then RB.prevAsked[raid] = nil end
    end
end

-- ---------------------------------------------------------------------------
-- SR+: how much each event adds, and the list it carries over from
-- ---------------------------------------------------------------------------

-- What was changed here, field by field: Event settings saves only those
-- and what raidres was read to have, never a default it wasn't.
local function touched(e, field) e.set = e.set or {}; e.set[field] = true end

local function onPickInc() touched(form(), "inc"); form().inc = this.value; picked() end
local function onPickPrev()
    if CloseDropDownMenus then CloseDropDownMenus() end
    if this.value == "type" then
        RB.AskPrevCode()
        return
    end
    if this.value == "retry" then
        RB.prevAsked[form().raid] = nil
        RB.DrawNewEvent()       -- which asks again
        return
    end
    local e = form()
    local got
    for _, s in ipairs((RB.prevSuggest and RB.prevSuggest[e.raid]) or {}) do
        if s.ref == this.value then got = s end
    end
    RB.PickPrev(this.value ~= "none" and this.value or nil, got)
end

function RB.InitEventIncMenu()
    local e = form()
    if not e then return end
    for _, n in ipairs(INCREASES) do add("+" .. n, n, onPickInc, n == e.inc) end
end

--[[ Where SR+ carries from: nothing; one of your own earlier events of this
     raid that had SR+ on, as raidres's form lists them (asked of raidres
     through the helper); one of the lists fetched here lately, marked when
     raidres said SR+ was off on it; or any code or link, typed. ]]
RB.prevSuggest, RB.prevAsked = {}, {}

local function same(a, b) return string.lower(a or "") == string.lower(b or "") end

function RB.InitEventPrevMenu()
    local e = form()
    if not e then return end
    local f = RB.eventFrame
    local own = f and f.mode       -- in Event settings, the event itself isn't offered
    add("Start fresh", "none", onPickPrev, not e.prev)
    local shown = {}
    local name = e.raid and raidName(e.raid)
    add("Your SR+ events" .. (name and (" of " .. name) or "") .. " on raidres")
    local list = e.raid and RB.prevSuggest[e.raid]
    if list then
        local any = false
        for _, s in ipairs(list) do
            if not same(s.ref, own) then
                any = true
                shown[string.lower(s.ref)] = true
                local when = (s.start and s.start > 0) and date("%a %d %b", s.start) or ""
                add(s.ref .. UI.hex(UI.GREY, "  " .. when .. "  +" .. (s.inc or 0)),
                    s.ref, onPickPrev, same(e.prev, s.ref))
            end
        end
        if not any then add(UI.hex(UI.GREY, "  none yet"), "-", nil) end
    elseif RB.prevAsked[e.raid] == "failed" then
        add("  raidres didn't say. Ask again", "retry", onPickPrev)
    elseif e.raid then
        add(UI.hex(UI.GREY, "  asking raidres..."), "-", nil)
    end
    local first = true
    for _, r in ipairs(RaidResBridge_Recent or {}) do
        if name and r.place == name and not shown[string.lower(r.ref)] and not same(r.ref, own) then
            if first then add("Fetched lately") first = false end
            shown[string.lower(r.ref)] = true
            if r.sr == false then
                add(UI.hex(UI.GREY, r.ref .. "  SR+ was off"), "-", nil)
            else
                add(r.ref, r.ref, onPickPrev, same(e.prev, r.ref))
            end
        end
    end
    if e.prev and not shown[string.lower(e.prev)] then add(e.prev, e.prev, onPickPrev, true) end
    add("Other")
    add("Type a code or link...", "type", onPickPrev)
end

-- ---------------------------------------------------------------------------
-- Building it
-- ---------------------------------------------------------------------------

local function label(f, text, y)
    local l = UI.text(f, "GameFontNormalSmall")
    l:SetPoint("TOPLEFT", f, "TOPLEFT", EDGE + 4, y)
    l:SetText(text)
    return l
end

local function dropdown(f, name, width, init, x, y)
    local d = UI.part("drop", CreateFrame("Frame", name, f, "UIDropDownMenuTemplate"))
    d:SetPoint("TOPLEFT", f, "TOPLEFT", x - 16, y + 8)
    UIDropDownMenu_SetWidth(width, d)
    UIDropDownMenu_Initialize(d, init)
    if UIDropDownMenu_JustifyText then UIDropDownMenu_JustifyText("LEFT", d) end
    return d
end

local function toggle(f, name, text, field, tipText, y)
    local c = UI.checkbox(f, name, text)
    c:SetPoint("TOPLEFT", f, "TOPLEFT", COL - 4, y + 4)
    c.field = field
    c:SetScript("OnClick", function()
        form()[this.field] = this:GetChecked() and true or false
        form().set = form().set or {}
        form().set[this.field] = true
        RB.DrawNewEvent()       -- SR+ shows or hides its own row
    end)
    c.tipText = tipText
    c:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText(this.label and this.label:GetText() or "", 1, 0.82, 0)
        GameTooltip:AddLine(this.tipText, 1, 1, 1, 1)
        GameTooltip:Show()
    end)
    c:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return c
end

local function build()
    local f = CreateFrame("Frame", "ZyllaRaidResEventFrame", UIParent)
    f:SetWidth(W)
    f:SetHeight(H)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    -- above the window (HIGH), level with the popups that follow it
    f:SetFrameStrata("DIALOG")
    if f.SetToplevel then f:SetToplevel(true) end
    if f.SetClampedToScreen then f:SetClampedToScreen(true) end
    f:SetBackdrop(UI.DIALOG)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:Hide()
    table.insert(UISpecialFrames, "ZyllaRaidResEventFrame")

    f.header = f:CreateTexture(nil, "ARTWORK")
    f.header:SetTexture(HEADER)
    f.header:SetWidth(300)
    f.header:SetHeight(64)
    f.header:SetPoint("TOP", f, "TOP", 0, 12)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOP", f.header, "TOP", 0, -14)
    f.title:SetText("New raidres event")

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

    f.raidLabel = label(f, "Raid", -42)
    f.raid = dropdown(f, "ZyllaRaidResEventRaid", 200, RB.InitEventRaidMenu, COL, -42)
    f.startsLabel = label(f, "Starts", -74)
    f.day = dropdown(f, "ZyllaRaidResEventDay", 130, RB.InitEventDayMenu, COL, -74)
    f.hour = dropdown(f, "ZyllaRaidResEventHour", 36, RB.InitEventHourMenu, COL + 150, -74)
    f.minute = dropdown(f, "ZyllaRaidResEventMinute", 36, RB.InitEventMinuteMenu, COL + 206, -74)
    f.clock = UI.text(f, "GameFontDisableSmall")
    f.clock:SetPoint("TOPLEFT", f, "TOPLEFT", COL, -98)
    f.clock:SetText("Your own clock, as raidres's site takes it.")
    f.limitLabel = label(f, "Reserves each", -120)
    f.limit = dropdown(f, "ZyllaRaidResEventLimit", 36, RB.InitEventLimitMenu, COL, -120)

    f.hrLabel = label(f, "Hard reserves", -152)
    f.hr = dropdown(f, "ZyllaRaidResEventHR", 200, RB.InitEventHrMenu, COL, -152)

    f.lock = toggle(f, "ZyllaRaidResEventLock", "Lock at the start time", "lock",
        "raidres locks the list itself when the raid starts, so nobody changes a reserve mid-raid.", -184)
    f.comments = toggle(f, "ZyllaRaidResEventComments", "Allow comments", "comments",
        "People can add a note to their reserve.", -208)
    f.srplus = toggle(f, "ZyllaRaidResEventSrPlus", "Use SR+", "srplus",
        "Reserving the same item event after event earns extra on the roll.", -232)
    f.dupes = toggle(f, "ZyllaRaidResEventDupes", "Same item twice", "dupes",
        "One person may reserve the same item more than once.", -256)

    -- shown only with SR+ on: what each event adds, and where it carries from
    f.srLabel = label(f, "SR+ each event", -288)
    f.inc = dropdown(f, "ZyllaRaidResEventInc", 40, RB.InitEventIncMenu, COL, -288)
    f.fromLabel = UI.text(f, "GameFontNormalSmall")
    f.fromLabel:SetPoint("TOPLEFT", f, "TOPLEFT", COL + 76, -288)
    f.fromLabel:SetText("from")
    f.prev = dropdown(f, "ZyllaRaidResEventPrev", 100, RB.InitEventPrevMenu, COL + 104, -288)

    f.descLabel = label(f, "Description", -322)
    f.desc = UI.editBox(f, "ZyllaRaidResEventDesc", W - COL - EDGE - 4, "Optional")
    f.desc:SetPoint("TOPLEFT", f, "TOPLEFT", COL + 4, -318)
    f.desc:SetMaxLetters(200)
    f.desc:SetScript("OnEnterPressed", function() this:ClearFocus() end)

    f.status = UI.text(f, "GameFontHighlightSmall")
    f.status:SetPoint("TOPLEFT", f, "TOPLEFT", EDGE + 4, -350)
    f.status:SetWidth(W - EDGE * 2 - 8)
    f.status:SetHeight(24)

    f.create = UI.button(f, "Create event", 110)
    f.create:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -EDGE + 2, 18)
    f.create:SetScript("OnClick", function() RB.CreateEvent() end)
    f.cancel = UI.button(f, "Cancel", 80)
    f.cancel:SetPoint("RIGHT", f.create, "LEFT", -4, 0)
    f.cancel:SetScript("OnClick", function() this:GetParent():Hide() end)

    f:SetScript("OnShow", function() if PlaySound then PlaySound("igMainMenuOpen") end end)
    f:SetScript("OnHide", function()
        if PlaySound then PlaySound("igMainMenuClose") end
        if CloseDropDownMenus then CloseDropDownMenus() end
    end)
    return f
end

-- ---------------------------------------------------------------------------
-- Using it
-- ---------------------------------------------------------------------------

local function note(text, colour)
    local f = RB.eventFrame
    if f then f.status:SetText(colour and UI.hex(colour, text) or text) end
end

--[[ The prior event picked: its SR+ settings come along with it, as the
     site copies them -- when it says how much each event adds, anyway. ]]
function RB.PickPrev(ref, from)
    local e = form()
    if not e then return end
    e.prev = ref
    touched(e, "prev")
    if not ref then
        e.skip, e.input, e.valid = nil, nil, nil
    elseif from and (from.inc or 0) > 0 then
        e.inc, e.skip, e.input, e.valid = from.inc, from.skip, from.input, from.valid
        note("SR+ carries on from " .. ref .. ", +" .. from.inc .. " each event, as it had.")
    else
        note("SR+ carries on from " .. ref .. ".")
    end
    RB.DrawNewEvent()
end

-- raidres's codes are six letters and digits; a link ends in one.
function RB.ParsePrevCode(text)
    text = string.gsub(text or "", "%s", "")
    local _, _, tail = string.find(text, "/res/([%w]+)")
    local code = tail or text
    if not string.find(code, "^%w%w%w%w%w%w$") then return nil end
    return string.upper(code)
end

function RB.AskPrevCode()
    if not StaticPopupDialogs.ZYLLARAIDRES_PREVCODE then
        StaticPopupDialogs.ZYLLARAIDRES_PREVCODE = {
            text = "Carry SR+ on from which event? Its code or link:",
            button1 = "OK",
            button2 = "Cancel",
            hasEditBox = 1,
            maxLetters = 60,
            OnAccept = function()
                local box = getglobal(this:GetParent():GetName() .. "EditBox")
                RB.SetPrevCode(box and box:GetText())
            end,
            EditBoxOnEnterPressed = function()
                RB.SetPrevCode(this:GetText())
                this:GetParent():Hide()
            end,
            timeout = 0, whileDead = 1, hideOnEscape = 1,
        }
    end
    StaticPopup_Show("ZYLLARAIDRES_PREVCODE")
end

--[[ A typed one is looked at first, with the DLL: raidres takes SR+ only
     from an event of the same raid that had it on, so this says so here
     rather than after Create. Without the DLL, raidres says it then. ]]
function RB.SetPrevCode(text)
    local f, e = RB.eventFrame, form()
    if not f or not e then return end
    local ref = RB.ParsePrevCode(text)
    if not ref then
        note("That isn't a raidres code: six letters and digits, or its link.", UI.RED)
        return
    end
    if same(ref, f.mode) then
        note("That's this event itself.", UI.RED)
        return
    end
    if not (RB.Http and RB.Http()) then
        RB.PickPrev(ref)
        note("SR+ carries on from " .. ref .. "; raidres checks it when you save.", UI.GOLD)
        return
    end
    note("Looking at " .. ref .. " on raidres...", UI.GOLD)
    local raid = e.raid
    RB.HttpEventSettings(ref, function(got, why)
        local now = form()
        if not now or now.raid ~= raid then return end
        if not got then
            note(why or ("raidres has no list " .. ref), UI.RED)
        elseif got.raid ~= raid then
            note(ref .. " is for another raid: SR+ carries on only within one raid.", UI.RED)
        elseif not got.srplus then
            note(ref .. " didn't have SR+ on, so there's nothing to carry on from.", UI.RED)
        else
            RB.PickPrev(got.ref, got)
        end
    end)
end

-- Your SR+ events of the raid picked, asked once a session when SR+ is on.
local function askSuggestions(e)
    if not (e.srplus and e.raid) or RB.prevSuggest[e.raid] or RB.prevAsked[e.raid] then return end
    if RB.sessionExpired or not (RB.LockControlReady and RB.LockControlReady()) then return end
    if RB.HelperBusy() then return end
    if RB.SendSuggestCommand(e.raid) then RB.prevAsked[e.raid] = true end
end

function RB.OnSuggestResult(pending, text)
    local raid, list = RB.ReadSuggest(text)
    if raid and list then
        RB.prevSuggest[raid], RB.prevAsked[raid] = list, nil
        for _, s in ipairs(list) do RB.eventSr[s.ref] = true end
    else
        RB.prevAsked[pending.suggest] = "failed"
        if string.sub(text, 1, 6) == "signin" then RB.sessionExpired = true end
    end
    RB.DrawNewEvent()
end

function RB.DrawNewEvent()
    local f, e = RB.eventFrame, RB.eventForm
    if not f or not e then return end
    askTemplates()              -- the helper may have been busy when it opened
    askSuggestions(e)
    UIDropDownMenu_SetText((e.raid and raidName(e.raid)) or "Pick a raid", f.raid)
    UIDropDownMenu_SetText(dayName(e.day), f.day)
    UIDropDownMenu_SetText(two(e.hour), f.hour)
    UIDropDownMenu_SetText(two(e.minute), f.minute)
    UIDropDownMenu_SetText(tostring(e.limit), f.limit)
    f.lock:SetChecked(e.lock)
    f.comments:SetChecked(e.comments)
    f.srplus:SetChecked(e.srplus)
    f.dupes:SetChecked(e.dupes)
    local hr = "None"
    if e.tpl then
        hr = "Saved: " .. (e.tplName or "?")
    elseif table.getn(e.hr) > 0 then
        hr = table.getn(e.hr) .. (table.getn(e.hr) == 1 and " item" or " items")
    end
    UIDropDownMenu_SetText(hr, f.hr)
    -- an event's settings not read from raidres show as not known
    local known = not f.mode or e.known
    local set = e.set or {}
    UIDropDownMenu_SetText((known or set.inc) and ("+" .. e.inc) or "+?", f.inc)
    UIDropDownMenu_SetText((known or set.prev) and (e.prev or "Start fresh") or "?", f.prev)
    local sr = { f.srLabel, f.inc, f.fromLabel, f.prev }
    for i = 1, table.getn(sr) do
        if e.srplus then sr[i]:Show() else sr[i]:Hide() end
    end
    if RB.createPending or not e.raid then f.create:Disable() else f.create:Enable() end
end

--[[ One dialog, two uses. A new event shows every row; an existing one's
     settings show only its hard reserves and SR+, moved up to the top, and
     save instead of create. Rows are moved while the dialog stands still. ]]
local function layout(f, settings)
    local newOnly = { f.raidLabel, f.raid, f.startsLabel, f.day, f.hour, f.minute, f.clock,
                      f.limitLabel, f.limit, f.lock, f.comments, f.dupes, f.descLabel, f.desc }
    for i = 1, table.getn(newOnly) do
        if settings then newOnly[i]:Hide() else newOnly[i]:Show() end
    end
    local hrY, srY, rowY, statusY = -152, -232, -288, -350
    if settings then hrY, srY, rowY, statusY = -46, -82, -112, -146 end
    f.hrLabel:ClearAllPoints()
    f.hrLabel:SetPoint("TOPLEFT", f, "TOPLEFT", EDGE + 4, hrY)
    f.hr:ClearAllPoints()
    f.hr:SetPoint("TOPLEFT", f, "TOPLEFT", COL - 16, hrY + 8)
    f.srplus:ClearAllPoints()
    f.srplus:SetPoint("TOPLEFT", f, "TOPLEFT", COL - 4, srY + 4)
    f.srLabel:ClearAllPoints()
    f.srLabel:SetPoint("TOPLEFT", f, "TOPLEFT", EDGE + 4, rowY)
    f.inc:ClearAllPoints()
    f.inc:SetPoint("TOPLEFT", f, "TOPLEFT", COL - 16, rowY + 8)
    f.fromLabel:ClearAllPoints()
    f.fromLabel:SetPoint("TOPLEFT", f, "TOPLEFT", COL + 76, rowY)
    f.prev:ClearAllPoints()
    f.prev:SetPoint("TOPLEFT", f, "TOPLEFT", COL + 88, rowY + 8)
    f.status:ClearAllPoints()
    f.status:SetPoint("TOPLEFT", f, "TOPLEFT", EDGE + 4, statusY)
    f:SetHeight(settings and 236 or H)
    f.create:SetText(settings and "Save" or "Create event")
end

--[[ Open it, with last time's choices, or raidres's own defaults the
     first time: comments on, everything else off, one reserve each. The
     raid starts as the window's: the one you're in, or the list's. ]]
function RB.OpenNewEvent()
    if not (RB.LockControlReady and RB.LockControlReady()) then
        say("making events from in game needs RaidResLock.dll (the lock helper) running.")
        return
    end
    UI = RB.UI
    local f = RB.eventFrame
    if not f then
        f = RB.BuildDialog(build)
        RB.eventFrame = f
    end
    local last = remembered()
    local today = date("%Y-%m-%d")
    RB.eventForm = {
        raid = last.raid or RB.raid,
        day = (last.day and last.day >= today) and last.day or today,
        hour = last.hour or 20,
        minute = last.minute or 0,
        limit = last.limit or 1,
        lock = last.lock or false,
        comments = (last.comments == nil) and true or last.comments,
        srplus = last.srplus or false,
        dupes = last.dupes or false,
        hr = {},                -- hard reserves are picked fresh each event
        inc = last.inc or 10,
        prev = nil,
    }
    f.desc:SetText(last.description or "")
    f.mode = nil
    f.title:SetText("New raidres event")
    layout(f, false)
    note("")
    -- your saved HR lists, through the helper, once a session
    forgetFailures()
    askTemplates()
    -- raidres's own raid list, grouped; quietly, once a session
    if RB.Http and RB.Http() and not RB.raidList and not RB.eventRaidsAsked then
        RB.eventRaidsAsked = true
        RB.HttpRaidList(function(list)
            RB.eventRaidsAsked = nil
            if list and table.getn(list) > 0 then RB.raidList = list end
            RB.DrawNewEvent()
        end)
    end
    RB.DrawNewEvent()
    f:Show()
end

--[[ The list in the window, if it's a raidres one: its hard reserves (as
     the fetched list has them) and SR+ settings (asked of raidres, with the
     DLL), changed and saved through the helper. Only its owner can save. ]]
function RB.OpenEventSettings()
    local g = RB.gui
    local s = g and g.snap
    if not (RB.LockControlReady and RB.LockControlReady()) then
        say("changing an event from in game needs RaidResLock.dll (the lock helper) running.")
        return
    end
    if not s or not s.ref or s.ref == "manual" or not s.instance then
        say("fetch a raidres list first: its settings are what this changes.")
        return
    end
    UI = RB.UI
    local f = RB.eventFrame
    if not f then
        f = RB.BuildDialog(build)
        RB.eventFrame = f
    end
    local hr = {}
    for id in pairs(s.hard) do table.insert(hr, id) end
    table.sort(hr)
    -- SR+ as raidres has it isn't known until it's read (with the DLL):
    -- until then Save sends only what is changed here (e.set)
    RB.eventForm = { raid = s.instance, hr = hr, srplus = false, inc = 10, prev = nil,
                     day = date("%Y-%m-%d"), hour = 20, minute = 0, limit = 1,
                     known = false, set = {} }
    f.mode = s.ref
    f.title:SetText("Event settings: " .. s.ref)
    layout(f, true)
    local unread = "raidres's SR+ settings for this event couldn't be read, so Save " ..
        "leaves SR+ as it is there unless you change it here."
    if RB.Http and RB.Http() then
        note("Reading SR+ from raidres...", UI.GOLD)
        RB.HttpEventSettings(s.ref, function(now, why)
            local e = RB.eventForm
            if not e or f.mode ~= s.ref or e.known then return end
            if not now then
                note((why and (why .. ". ") or "") .. unread, UI.GOLD)
                return
            end
            -- what was already changed here stays as changed
            local set = e.set or {}
            if not set.srplus then e.srplus = now.srplus end
            if not set.prev then e.prev = now.prev end
            if not set.inc then e.inc = now.inc end
            e.known = true
            note("")
            RB.DrawNewEvent()
        end)
    else
        note("Without RaidResHttp.dll, " .. unread, UI.GOLD)
    end
    forgetFailures()
    askTemplates()
    RB.DrawNewEvent()
    f:Show()
end

function RB.CreateEvent()
    local f, e = RB.eventFrame, RB.eventForm
    if not f or not e then return end
    if f.mode then
        if RB.sessionExpired then
            note("Your raidres session expired: click Sign in in the main window first.", UI.RED)
            return
        end
        if not RB.SendSettingsCommand(f.mode, e) then
            note(RB.HelperBusy() and "The lock helper is busy; try again in a moment."
                or "Can't reach the lock script. Is Nampower loaded?", UI.RED)
            return
        end
        note("Saving it on raidres...", UI.GOLD)
        RB.DrawNewEvent()
        return
    end
    if not e.raid then
        note("Pick a raid first.", UI.RED)
        return
    end
    local clock = two(e.hour) .. ":" .. two(e.minute)
    if e.day .. " " .. clock < date("%Y-%m-%d %H:%M") then
        note("That time has already passed.", UI.RED)
        return
    end
    if RB.sessionExpired then
        note("Your raidres session expired: click Sign in in the main window first.", UI.RED)
        return
    end
    if RB.HelperBusy() then
        note("The lock helper is busy; try again in a moment.", UI.RED)
        return
    end
    local desc = f.desc:GetText() or ""
    local sent = RB.SendCreateCommand({
        raid = e.raid, day = e.day, clock = clock, limit = e.limit, lock = e.lock,
        comments = e.comments, srplus = e.srplus, dupes = e.dupes, description = desc,
        name = raidName(e.raid), tpl = e.tpl, hr = e.hr, inc = e.inc, prev = e.prev,
        skip = e.skip, input = e.input, valid = e.valid,
    })
    if not sent then
        note("Can't reach the lock script. Is Nampower loaded?", UI.RED)
        return
    end
    local last = remembered()
    last.raid, last.day, last.hour, last.minute = e.raid, e.day, e.hour, e.minute
    last.limit, last.lock, last.comments = e.limit, e.lock, e.comments
    last.srplus, last.dupes, last.description, last.inc = e.srplus, e.dupes, desc, e.inc
    note("Creating it on raidres...", UI.GOLD)
    RB.DrawNewEvent()
end

--[[ Made: into the window, fetched, and offered to the raid -- or the
     party -- as one line. Chat.lua turns it into a link for anyone else
     running this. ]]
function RB.OfferToPost(ref, name)
    local link = "https://raidres.top/res/" .. ref
    local raid = (GetNumRaidMembers and GetNumRaidMembers() or 0) > 0
    local party = (GetNumPartyMembers and GetNumPartyMembers() or 0) > 0
    local channel = (raid and "RAID") or (party and "PARTY") or nil
    if not channel or not StaticPopupDialogs then
        say("event created: |cffffffff" .. link .. "|r")
        return
    end
    RB.postLine = { text = "Soft reserves are open: " .. link .. (name and (" (" .. name .. ")") or ""),
                    channel = channel }
    if not StaticPopupDialogs.ZYLLARAIDRES_POST then
        StaticPopupDialogs.ZYLLARAIDRES_POST = {
            text = "Event created:\n%s\n\nPost the link in %s chat?",
            button1 = "Post",
            button2 = "Not now",
            OnAccept = function()
                local p = RB.postLine
                RB.postLine = nil
                if p then SendChatMessage(p.text, p.channel) end
            end,
            OnCancel = function() RB.postLine = nil end,
            timeout = 0, whileDead = 1, hideOnEscape = 1,
        }
    end
    StaticPopup_Show("ZYLLARAIDRES_POST", link, string.lower(channel))
end

function RB.OnCreateResult(pending, text)
    local f = RB.eventFrame
    if pending.settings and text == "ok saved" then
        if f then f:Hide() end
        RB.Notice("saved on raidres. Fetching the list again...")
        RB.Request(pending.settings)
        return
    end
    local _, _, ref = string.find(text, "^ok created (%w+)$")
    if ref then
        if f then f:Hide() end
        local g = RB.BuildGui()
        if not g:IsVisible() then RB.ToggleGui() end
        g.link:SetText("https://raidres.top/res/" .. ref)
        RB.Request(ref)
        RB.OfferToPost(ref, pending.event and pending.event.name)
        return
    end
    local msg
    if string.sub(text, 1, 6) == "signin" then
        RB.sessionExpired = true
        msg = "Your raidres session expired. Click Sign in in the main window, then try again."
    else
        msg = (string.gsub(text, "^error: ", "raidres: "))
    end
    if f and f:IsVisible() then
        note(msg, UI.RED)
        RB.DrawNewEvent()
    else
        say(msg)
    end
end
