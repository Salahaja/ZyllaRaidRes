--[[ test_gui.lua -- run from anywhere:
       lua ZyllaRaidRes/tools/test_gui.lua

     The window itself, built and clicked. A small stand-in for the 1.12
     widget API records what each widget is showing, so these checks read
     what a raid leader would see: the row texts, the hint line, which
     buttons are enabled, what the tooltip says.

     It has no layout engine, so it cannot catch a misplaced frame. What it
     catches is everything else: a nil index three handlers deep, a click that
     does the wrong thing, a state the window forgets to redraw. Those are the
     bugs that would otherwise only show up in the client, mid-raid. ]]

local ROOT = string.gsub(arg and arg[0] or "", "tools.[%w_]+%.lua$", "")
local DIR = ROOT .. "tools/fixtures/"

table.getn = table.getn or function(t) return #t end
string.gfind = string.gfind or string.gmatch
math.mod = math.mod or math.fmod
math.atan2 = math.atan2 or math.atan
loadstring = loadstring or load

local failures, checks = 0, 0
local function check(label, got, want)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print("  FAIL " .. label .. ": got " .. tostring(got) .. ", wanted " .. tostring(want))
    end
end

local function plain(s)
    s = string.gsub(s or "", "|c%x%x%x%x%x%x%x%x", "")
    s = string.gsub(s, "|r", "")
    return s
end

local function slurp(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

-- ------------------------------------------------------------------ widgets
local NAMED = {}
local W = {}
local meta = { __index = function(_, k)
    local m = W[k]
    if m then return m end
    -- Any other WoW method is accepted and does nothing; fields stay nil.
    if type(k) == "string" and string.find(k, "^%u") then return function() end end
    return nil
end }

local function fire(w, script, a1)
    local fn = w.scripts[script]
    if not fn then return end
    local oldThis, oldArg = this, arg1
    this, arg1 = w, a1
    fn()
    this, arg1 = oldThis, oldArg
end

local ALLFRAMES = {}   -- every frame, so a clock can run their OnUpdate

local function new(kind, name, parent)
    local w = setmetatable({ kind = kind, name = name, parent = parent, shown = true,
        scripts = {}, txt = "", alpha = 1, enabled = true,
        level = parent and (parent.level + 1) or 0 }, meta)
    if name then NAMED[name] = w; _G[name] = w end
    table.insert(ALLFRAMES, w)
    return w
end

function W:GetName() return self.name end
function W:GetParent() return self.parent end
function W:SetScript(n, fn) self.scripts[n] = fn end
function W:GetScript(n) return self.scripts[n] end
function W:IsShown() return self.shown end
function W:IsVisible()
    local w = self
    while w do
        if not w.shown then return false end
        w = w.parent
    end
    return true
end
function W:Show()
    local was = self:IsVisible()
    self.shown = true
    if not was and self:IsVisible() then fire(self, "OnShow") end
end
function W:Hide()
    local was = self:IsVisible()
    self.shown = false
    if was then fire(self, "OnHide") end
end
function W:SetText(t)
    self.txt = t or ""
    if self.kind == "EditBox" then fire(self, "OnTextChanged") end
end
function W:GetText() return self.txt end
function W:SetAlpha(a) self.alpha = a end
function W:GetAlpha() return self.alpha end
function W:SetChecked(v) self.checked = v and 1 or nil end
function W:GetChecked() return self.checked end
function W:Enable() self.enabled = true end
function W:Disable() self.enabled = false end
function W:IsEnabled() return self.enabled and 1 or nil end
function W:GetFrameLevel() return self.level end
function W:SetFrameLevel(l) self.level = l end
function W:SetTexture(a) self.texture = a end
function W:CreateFontString(name) return new("FontString", name, self) end
function W:CreateTexture(name) return new("Texture", name, self) end
function W:SetFocus() self.focused = true; fire(self, "OnEditFocusGained") end
function W:ClearFocus()
    if self.focused then self.focused = nil; fire(self, "OnEditFocusLost") end
end
function W:Insert(t) self.inserted = t end
function W:SetHighlightTexture(path)
    self.hl = new("Texture", nil, self)
    self.hl.texture = path
end
function W:GetHighlightTexture() return self.hl end
function W:SetBlendMode(m) self.blend = m end
function W:SetPoint(p, rel, rp, x, y) self.point = { p, rel, rp, x, y } end
function W:LockHighlight() self.locked = true end
function W:UnlockHighlight() self.locked = false end
function W:SetValue(v)
    -- A scroll bar: moving it scrolls its frame, as OnValueChanged does.
    if v == self.value then return end
    self.value = v
    fire(self.parent, "OnVerticalScroll", v)
end

CreateFrame = function(kind, name, parent, template)
    local w = new(kind, name, parent)
    if template == "UICheckButtonTemplate" and name then new("FontString", name .. "Text", w) end
    if template == "FauxScrollFrameTemplate" then
        local bar = new("Slider", name .. "ScrollBar", w)
        bar.value = 0
    end
    return w
end
getglobal = function(n) return NAMED[n] end

FauxScrollFrame_Update = function(frame, n, shown)
    frame.total = n
    if n > shown then frame.shown = true
    else
        frame.shown = false
        NAMED[frame:GetName() .. "ScrollBar"]:SetValue(0)
    end
end
FauxScrollFrame_GetOffset = function(frame) return frame.offset or 0 end
FauxScrollFrame_OnVerticalScroll = function(itemHeight, fn)
    this.offset = math.floor(arg1 / itemHeight + 0.5)
    fn()
end

-- 1.12's UIDropDownMenu, argument order and all: SetWidth(width, frame),
-- SetText(text, frame), and an item's func called with `this` as the button.
local MENU, MENU_CLOSED = {}, false
UIDropDownMenu_SetWidth = function(w, frame) frame.ddWidth = w end
UIDropDownMenu_Initialize = function(frame, fn) frame.ddInit = fn end
UIDropDownMenu_SetText = function(t, frame) frame.ddText = t end
-- As the client's: it also redraws the ticks of whatever menu is open,
-- whichever dropdown that menu belongs to, ticking only `v`.
UIDropDownMenu_SetSelectedValue = function(frame, v)
    frame.selectedValue = v
    for _, info in ipairs(MENU) do info.checked = (info.value == v) and 1 or nil end
    local list = NAMED["DropDownList1"]
    if list and list:IsVisible() then
        for i = 1, (list.numButtons or 0) do
            local b = NAMED["DropDownList1Button" .. i]
            if b.value == v then NAMED[b:GetName() .. "Check"]:Show()
            else NAMED[b:GetName() .. "Check"]:Hide() end
        end
    end
end
UIDropDownMenu_JustifyText = function() end
UIDropDownMenu_AddButton = function(info) table.insert(MENU, info) end
CloseDropDownMenus = function() MENU_CLOSED = true end
-- ToggleDropDownMenu(level, value, frame, anchor): opening a menu builds it.
ToggleDropDownMenu = function(_, _, frame)
    MENU = {}
    frame.ddInit()
    frame.ddOpen = true
    UIDROPDOWNMENU_OPEN_MENU = frame:GetName()
end
local function openMenu(dd)
    MENU = {}
    dd.ddInit()
    return MENU
end
local function pick(info)
    local old = this
    this = { value = info.value }
    info.func()
    this = old
end

-- ------------------------------------------------------------------ the world
local SAID, FILES, IMPORTED, POPUP, NOW, SHIFT, CTRL, CACHED, TIP, DRESSED
local ROSTER, SOUNDS, SHOWN, REFS, CLOCK, CURSOR, VIEWED, RELOADED, CHAT

--[[ RollFor 4.x as far as this addon meets it: import says so in chat and
     keeps the list, and when, in RollForCharDb.softres -- unless nobody
     reserved anything, which it doesn't keep. ]]
local function fakeRollFor()
    RollForCharDb = {}
    RollFor = { key_bindings = {
        import = function(d)
            IMPORTED = d
            DEFAULT_CHAT_FRAME:AddMessage("RollFor: Soft-res data loaded successfully!")
            local items = 0
            for _, p in ipairs(d.softreserves or {}) do items = items + table.getn(p.items or {}) end
            if items > 0 then
                RollForCharDb.softres = { data = "encoded" .. items, import_timestamp = CLOCK }
            end
        end,
        softres_toggle = function() VIEWED = true end,
    } }
end

local function world(withoutNames)
    NAMED = {}
    ALLFRAMES = {}
    SAID, FILES, IMPORTED, POPUP, NOW, SHIFT, CTRL = {}, {}, nil, nil, 100, false, false
    CACHED, DRESSED, SOUNDS = {}, nil, {}
    PlaySound = function(name) table.insert(SOUNDS, name) end
    RAID_CLASS_COLORS, GetItemQualityColor, pfUI = nil, nil, nil
    GetRealZoneText = nil
    -- the client's own chat handler and link handler, for Chat.lua to hook:
    -- SHOWN records what each chat frame was given, REFS what reached the
    -- original link handler
    SHOWN, REFS = {}, {}
    ChatFrame_OnEvent = function(evt) table.insert(SHOWN, { event = evt, text = arg1 }) end
    SetItemRef = function(link) table.insert(REFS, link) end
    TIP = { lines = {} }
    CLOCK, CURSOR, VIEWED, RELOADED = 1700000000, { 0, 0 }, false, false
    time = function() return CLOCK end
    -- the client's date(), on the same stopped clock as time()
    date = function(fmt, t) return os.date(fmt, t or CLOCK) end
    CHAT = {}
    SendChatMessage = function(text, channel) table.insert(CHAT, { text = text, channel = channel }) end
    ReloadUI = function() RELOADED = true end
    GetCursorPosition = function() return CURSOR[1], CURSOR[2] end
    DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(SAID, m) end }
    SlashCmdList = {}
    UISpecialFrames = {}
    StaticPopupDialogs = {}
    StaticPopup_Show = function(which, a) POPUP = { which = which, arg = a } end
    YES, NO = "Yes", "No"
    UIParent = new("Frame", "UIParent")
    ChatFrameEditBox = new("EditBox", "ChatFrameEditBox", UIParent)
    ChatFrameEditBox.shown = false
    WIM_EditBoxInFocus = nil
    GameTooltip = {
        SetOwner = function(_, o) TIP = { owner = o, lines = {} } end,
        SetText = function(_, t) table.insert(TIP.lines, t) end,
        AddLine = function(_, t) table.insert(TIP.lines, t) end,
        AddDoubleLine = function(_, l, r) table.insert(TIP.lines, l .. "  " .. r) end,
        SetHyperlink = function(_, l) TIP.link = l; table.insert(TIP.lines, "<item>") end,
        Show = function() TIP.shown = true end,
        Hide = function() TIP.shown = false end,
    }
    GetTime = function() return NOW end
    IsShiftKeyDown = function() return SHIFT end
    IsControlKeyDown = function() return CTRL end
    DressUpItemLink = function(l) DRESSED = l end
    GetAddOnMetadata = function(_, f) if f == "Version" then return "1.2.0" end end
    GetItemInfo = function(id)
        local c = CACHED[id]
        if c then return c.name, "item:" .. id, c.q, 60, "Armor", "Plate", 1, "", c.icon end
    end
    UnitName = function(u) if u == "player" then return "Tester" end end
    UnitClass = function() return "Warrior", "WARRIOR" end
    ROSTER = {
        { "Tester", "WARRIOR" }, { "Newbie", "MAGE" }, { "Zed", "ROGUE" },
        { "Aldwyn", "PALADIN" }, { "Brisa", "PRIEST" },
    }
    GetNumRaidMembers = function() return table.getn(ROSTER) end
    GetRaidRosterInfo = function(i)
        local r = ROSTER[i]
        -- name, rank, subgroup, level, class, fileName, zone, online
        if r then return r[1], 0, 1, 60, r[2], r[2], r[3], r[4] ~= false end
    end
    GetNumPartyMembers = function() return 0 end
    -- The helper's side of its two files, as the watcher does it: the game's
    -- "#ID " comes off the command (FILES holds the command itself, RAWCMD
    -- what was written) and goes back on whatever answer a test leaves.
    TAG = nil
    WriteCustomFile = function(n, t)
        if n == "RaidResBridge_lock_cmd.txt" then
            RAWCMD = t
            local _, _, id, rest = string.find(t, "^#(%d+) (.*)$")
            if id then TAG, t = id, rest end
        end
        FILES[n] = t
    end
    ReadCustomFile = function(n)
        local t = FILES[n]
        if n == "RaidResBridge_lock_result.txt" and TAG and type(t) == "string" and t ~= ""
            and string.sub(t, 1, 1) ~= "#" then
            return "#" .. TAG .. " " .. t
        end
        return t
    end
    fakeRollFor()
    Minimap = new("Frame", "Minimap", UIParent)
    GetMinimapShape = nil
    RaidResHttpGet, RaidResHttpResult = nil, nil
    RaidResBridge, RaidResBridge_Manual, RaidResBridge_Limit = nil, nil, nil
    RaidResBridge_Sent, RaidResBridge_Options, RaidResBridge_Recent = nil, nil, nil
    RaidResBridge_Spec, RaidResLockReady, RaidResBridge_LockControl = nil, nil, nil
    RaidResBridge_Data, RaidResBridge_Ref, RaidResBridge_Locked = nil, nil, nil
    RaidResBridge_ForOthers = nil

    dofile(DIR .. "expected.lua")
    RaidResBridge_Raids = Expected_Raids
    FILES["RaidResBridge_data.lua"] = slurp(DIR .. "RaidResBridge_data.lua")

    dofile(ROOT .. "RaidResBridge.lua")
    dofile(ROOT .. "Http.lua")
    RaidResBridge_Names = nil
    if not withoutNames then dofile(ROOT .. "Names.lua") end
    dofile(ROOT .. "Manual.lua")
    dofile(ROOT .. "Gui.lua")
    dofile(ROOT .. "Event.lua")
    dofile(ROOT .. "Minimap.lua")
    dofile(ROOT .. "Chat.lua")
    return RaidResBridge
end

local function click(w) if w and w:IsVisible() and w.enabled then fire(w, "OnClick") end end
local function enter(w) fire(w, "OnEnter") end
local function tipHas(text)
    for _, l in ipairs(TIP.lines) do
        if string.find(plain(l), text, 1, true) then return true end
    end
    return false
end
local function heard(text)
    for _, m in ipairs(SAID) do if string.find(m, text, 1, true) then return true end end
    return false
end

-- Let time pass: every visible frame's OnUpdate, a quarter second at a time.
local function run(seconds)
    for _ = 1, math.floor(seconds / 0.25 + 0.5) do
        NOW = NOW + 0.25
        for _, w in ipairs(ALLFRAMES) do
            if w.scripts.OnUpdate and w:IsVisible() then fire(w, "OnUpdate", 0.25) end
        end
    end
end

--[[ A stand-in for RaidResHttp.dll. Pages are put in PAGES by path (nil is a
     404); every path asked for is recorded in ASKED. A request answers on its
     first look, so a second of `run` is plenty. ]]
local ASKED, PAGES = {}, {}
local function fakeDll()
    ASKED, PAGES = {}, {}
    local id, open = 0, {}
    RaidResHttpGet = function(path)
        id = id + 1
        open[id] = path
        table.insert(ASKED, path)
        return id
    end
    RaidResHttpResult = function(n)
        local path = open[n]
        if not path then return nil, "unknown request" end
        open[n] = nil
        local page = PAGES[path]
        if page == nil then return "done", 404, "" end
        if page.failed then return "failed", page.failed end
        return "done", 200, page.body
    end
end
local function eventJson(locked)
    local lock = (locked == nil) and "" or ('"locked":' .. tostring(locked) .. ",")
    return '{' .. lock .. '"raidId":100,"reservations":[]}'
end

-- The visible rows of a list, as text.
local function visible(rows)
    local out = {}
    for _, r in ipairs(rows) do if r:IsShown() then table.insert(out, r) end end
    return out
end
local function rowText(r)
    if r.head and r.head:IsShown() then return plain(r.head:GetText()) end
    return plain(r.text:GetText())
end
local function findRow(rows, text)
    for _, r in ipairs(visible(rows)) do
        if string.find(rowText(r), text, 1, true) then return r end
    end
end
local function itemRow(f, id)
    for _, r in ipairs(visible(f.lRows)) do
        if r.data and r.data.item and r.data.item.g == id then return r end
    end
end
local function firstItemRow(f)
    for _, r in ipairs(visible(f.lRows)) do
        if r.data and r.data.item then return r end
    end
end
local function hint(f) return plain(f.hint:GetText()) end

-- ================================================================== opening
print("opening")
local RB = world()
SlashCmdList.RAIDRESBRIDGE("")
local f = RB.gui
check("/rrb on its own opens the window", f and f:IsVisible(), true)
check("Escape closes it", UISpecialFrames[1], "ZyllaRaidResFrame")
check("the status names the list", string.find(plain(f.status:GetText()), "DEMO42", 1, true) ~= nil, true)
check("and its raid, on the line under it", plain(f.place:GetText()), "Zul'Gurub")
check("not squeezed in beside the code", string.find(plain(f.status:GetText()), "Zul'Gurub", 1, true), nil)
--[[ The bug this replaces: the loot opened on whatever sorted first, which
     here is Blackwing Lair. ]]
check("the loot opens on the list's own raid", f.raidDrop.ddText, "Zul'Gurub")
check("opening plays the menu sound", SOUNDS[1], "igMainMenuOpen")
check("the banner carries the title", f.title:GetText(), "Zylla RaidRes")
check("on the dialog header art", f.header.texture, "Interface\\DialogFrame\\UI-DialogBox-Header")
check("rows glow like the quest log's", f.pRows[1].hl and f.pRows[1].hl.texture,
    "Interface\\QuestFrame\\UI-QuestTitleHighlight")
check("additively, as the quest log's do", f.pRows[1].hl.blend, "ADD")
check("the link box is filled in to refetch", f.link:GetText(), "https://raidres.top/res/DEMO42")
check("so its placeholder is hidden", f.link.placeholder:IsShown(), false)
check("the hint says what to do first", string.find(hint(f), "Pick a player", 1, true) ~= nil, true)
check("nothing typed, so nothing to clear", f.clear.enabled, false)
check("RollFor is there, so Send works", f.send.enabled, true)

-- 5 in the raid + 10 more on the list who are not
local total = table.getn(RB.gui.snap.players)
check("raid and list together", total, 15)
check("the player list scrolls past its rows", f.pScroll.total, 15)
check("everyone on the list is done", plain(f.pBox.label:GetText()), "Players  12 of 15 done")
local first = visible(f.pRows)[1]
check("the first row is someone with nothing", plain(first.count:GetText()), "0/2")
check("a full one is green-counted 2/2", findRow(f.pRows, "Aldwyn") and
    plain(findRow(f.pRows, "Aldwyn").count:GetText()), "2/2")
local away
for _, r in ipairs(visible(f.pRows)) do
    if r.data and not r.data.inRaid then away = r end
end
check("a signup who isn't here is marked", away and string.find(rowText(away), "not here", 1, true) ~= nil, true)

-- ================================================================== scrolling
print("scrolling")
NAMED.ZyllaRaidResPlayerScrollScrollBar:SetValue(3 * 18)
check("scrolling moves the list", visible(f.pRows)[1].data.name, RB.gui.snap.players[4].name)
RB.ResetScroll(f.pScroll)
check("and back", visible(f.pRows)[1].data.name, RB.gui.snap.players[1].name)

--[[ Scrolled down, then the list shrinks to fit: FauxScrollFrame_Update
     scrolls back to the top, which calls the draw again from inside itself.
     It must draw once, not twice over itself. ]]
NAMED.ZyllaRaidResPlayerScrollScrollBar:SetValue(3 * 18)
local draws, realStatus = 0, RB.DrawStatus
RB.DrawStatus = function() draws = draws + 1; realStatus() end
local saveRoster, saveFile = ROSTER, FILES["RaidResBridge_data.lua"]
ROSTER = { { "Tester", "WARRIOR" } }
FILES["RaidResBridge_data.lua"] = nil
RB.Refresh()
check("a shrinking list scrolls back to the top", FauxScrollFrame_GetOffset(f.pScroll), 0)
check("drawing once, not re-entering itself", draws, 1)
RB.DrawStatus, ROSTER, FILES["RaidResBridge_data.lua"] = realStatus, saveRoster, saveFile
RB.Refresh()

-- ================================================================== no selection
print("clicking loot with nobody picked")
local row = firstItemRow(f)
click(row)
check("nothing is reserved", next(RaidResBridge_Manual), nil)
check("the hint says why", string.find(hint(f), "pick a player", 1, true) ~= nil, true)
check("in the window, not in chat", heard("pick a player"), false)
NOW = NOW + 5
fire(f, "OnUpdate", 0.3)
check("and the notice goes away", string.find(hint(f), "Pick a player, then", 1, true) ~= nil, true)

-- ================================================================== selecting
print("selecting a player")
click(findRow(f.pRows, "Newbie"))
check("the click selects", RB.player, "Newbie")
check("the row's glow is held, as in the friends list", findRow(f.pRows, "Newbie").locked, true)
check("and only that row's", findRow(f.pRows, "Zed").locked, false)
check("the reserves box names them", plain(f.dBox.label:GetText()), "Newbie's reserves  0 of 2")
check("and says they have nothing", f.dEmpty:IsShown(), true)
check("the hint counts what's left", hint(f), "Click loot to reserve it for Newbie (2 left).")
check("a mage can filter by class", f.classOnly.enabled, true)
check("and the filter starts on", f.classOnly:GetChecked(), 1)

-- Primal Hakkari Shawl is Paladin/Hunter/Mage; find something mages can't use.
local notMage
for _, it in ipairs(Expected_Raids[100].items) do
    local ok = table.getn(it.c) == 0
    for _, c in ipairs(it.c) do if c == "Mage" then ok = true end end
    if not ok then notMage = it break end
end
local function lootHas(id)
    -- the whole filtered list, not just the rows on screen
    for _, r in ipairs(RB.ItemRows(RB.raid, { search = RB.search, class = RB.classOnly and "MAGE" or nil })) do
        if r.item and r.item.g == id then return true end
    end
    return false
end
check("another class's item is hidden", lootHas(notMage.g), false)
f.classOnly:SetChecked(nil); click(f.classOnly)
check("until the filter is turned off", RB.classOnly, false)
check("then it shows", lootHas(notMage.g), true)
f.classOnly:SetChecked(1); click(f.classOnly)

click(findRow(f.pRows, "Newbie"))
check("clicking them again lets go", RB.player, nil)
click(findRow(f.pRows, "Newbie"))

-- ================================================================== reserving
print("reserving")
row = firstItemRow(f)
local id = row.data.item.g
click(row)
check("a click reserves it", RB.WhoHas(id)[1], "Newbie")
check("RollFor gets it straight away", IMPORTED ~= nil, true)
local sent = false
for _, p in ipairs(IMPORTED.softreserves) do if p.name == "Newbie" then sent = true end end
check("with Newbie in it", sent, true)
row = itemRow(f, id)
check("the row gets a check mark", row.check:IsShown(), true)
check("and shows who has it", string.find(plain(row.who:GetText()), "Newbie", 1, true) ~= nil, true)
check("the detail lists it", f.dRows[1]:IsShown() and f.dRows[1].itemId, id)
check("typed here, so it has an X", f.dRows[1].remove:IsShown(), true)
check("and no raidres tag", f.dRows[1].tag:IsShown(), false)
check("now there is something to clear", f.clear.enabled, true)
check("hint counts down", hint(f), "Click loot to reserve it for Newbie (1 left).")

click(itemRow(f, id))
check("clicking it again takes it back", table.getn(RB.WhoHas(id)), 0)

-- fill up
local picks = {}
for _, r in ipairs(visible(f.lRows)) do
    if r.data and r.data.item and not RB.gui.snap.hard[r.data.item.g]
       and table.getn(RB.gui.snap.holders[r.data.item.g] or {}) == 0 then
        table.insert(picks, r.data.item.g)
    end
end
click(itemRow(f, picks[1]))
click(itemRow(f, picks[2]))
check("two fits the limit", table.getn(RB.gui.snap.items.newbie), 2)
check("the hint says they're full", string.find(hint(f), "Newbie is full", 1, true) ~= nil, true)
check("other loot dims", itemRow(f, picks[3]).alpha, 0.45)
check("their own doesn't", itemRow(f, picks[1]).alpha, 1)
click(itemRow(f, picks[3]))
check("a third is refused", table.getn(RB.gui.snap.items.newbie), 2)
check("and says why", string.find(hint(f), "already has 2 of 2", 1, true) ~= nil, true)

click(f.dRows[1].remove)
check("the X takes one back", table.getn(RB.gui.snap.items.newbie), 1)

-- ================================================================== locked
print("what raidres owns")
click(findRow(f.pRows, "Aldwyn"))
check("a signup's reserves show", f.dRows[1]:IsShown(), true)
check("marked raidres", f.dRows[1].tag:IsShown(), true)
check("with no X", f.dRows[1].remove:IsShown(), false)
local webId = f.dRows[1].itemId
f.classOnly:SetChecked(nil); click(f.classOnly)
local before = table.getn(RB.WhoHas(webId))
local wr = nil
for _, r in ipairs(RB.ItemRows(RB.raid, {})) do if r.item and r.item.g == webId then wr = r end end
RB.ClickItem(wr)
check("clicking it in the loot leaves it alone", table.getn(RB.WhoHas(webId)), before)
check("and says where to change it", string.find(hint(f), "change it there", 1, true) ~= nil, true)

local hardId = Expected_Data.hardreserves[1].id
click(findRow(f.pRows, "Zed"))
local hr
for _, r in ipairs(RB.ItemRows(RB.raid, {})) do if r.item and r.item.g == hardId then hr = r end end
check("the hard reserve is in the loot table", hr ~= nil, true)
RB.ClickItem(hr)
check("a hard reserve can't be taken", table.getn(RB.WhoHas(hardId)), 0)
check("and it says so", string.find(hint(f), "hard-reserved", 1, true) ~= nil, true)

-- ================================================================== search
print("search")
local target = Expected_Raids[100].items[5]
local word = string.lower(string.sub(target.n, 1, 6))
f.search:SetFocus()
f.search:SetText(word)
check("typing filters", RB.search, word)
local ok = true
for _, r in ipairs(visible(f.lRows)) do
    if r.data and r.data.item then
        local hay = string.lower(r.data.item.n .. " " .. (r.data.item.b or ""))
        if not string.find(hay, word, 1, true) then ok = false end
    end
end
check("every row shown matches", ok, true)
check("and the one searched for is there", itemRow(f, target.g) ~= nil, true)
f.search:SetText("zzzz")
check("nothing matching says so", f.lEmpty:IsShown() and
    string.find(plain(f.lEmpty:GetText()), "zzzz", 1, true) ~= nil, true)
f.search:SetText("")
f.search:ClearFocus()
check("clearing it brings the placeholder back", f.search.placeholder:IsShown(), true)

-- ================================================================== filters
print("missing only")
f.missing:SetChecked(1); click(f.missing)
local allMissing = true
for _, r in ipairs(visible(f.pRows)) do
    if r.data and r.data.count >= 2 then allMissing = false end
end
check("only those still to reserve", allMissing, true)
f.missing:SetChecked(nil); click(f.missing)

-- ================================================================== the dropdown
print("instance dropdown")
local menu = openMenu(f.raidDrop)
local names, checked = {}, nil
for _, info in ipairs(menu) do
    table.insert(names, plain(info.text))
    if info.checked then checked = plain(info.text) end
end
check("it lists the cached raids", names[1], "Blackwing Lair")
check("with the current one ticked", checked, "Zul'Gurub")
check("and the download at the bottom", menu[table.getn(menu)].value, "loot")
pick(menu[1])
check("choosing one switches the loot", f.raidDrop.ddText, "Blackwing Lair")
check("and selects it in the dropdown", f.raidDrop.selectedValue, 94)
-- A new list brings its own raid back.
FILES["RaidResBridge_data.lua"] = string.gsub(FILES["RaidResBridge_data.lua"], "DEMO42", "DEMO43")
RB.Refresh()
check("a new list opens on its raid again", f.raidDrop.ddText, "Zul'Gurub")
check("the status follows", string.find(plain(f.status:GetText()), "DEMO43", 1, true) ~= nil, true)

-- ================================================================== bosses
print("folding bosses")
RB.ResetScroll(f.lScroll)
local bossRow = visible(f.lRows)[1]
check("a boss leads the loot", bossRow.data and bossRow.data.header ~= nil, true)
check("with the quest log's minus", bossRow.toggle.texture, "Interface\\Buttons\\UI-MinusButton-Up")
local bossName = bossRow.data.header
local secondBefore = visible(f.lRows)[2].data
click(bossRow)
check("clicking it folds it to a plus", visible(f.lRows)[1].toggle.texture, "Interface\\Buttons\\UI-PlusButton-Up")
check("hiding its loot", visible(f.lRows)[2].data.header ~= nil, true)
f.search:SetText(string.lower(string.sub(secondBefore.item.n, 1, 5)))
check("a search opens folded bosses", itemRow(f, secondBefore.item.g) ~= nil, true)
f.search:SetText("")
click(visible(f.lRows)[1])
check("clicking again unfolds it", visible(f.lRows)[2].data.item ~= nil, true)
check("the same boss", visible(f.lRows)[1].data.header, bossName)

-- ================================================================== sorting the loot
print("sorting the loot, as raidres does")
do
    -- Every row, not just the 17 on screen: what drawLoot asked for.
    local function allRows()
        return RB.ItemRows(RB.raid, { sort = RB.LootSort(), show = RB.LootShow(), hard = f.snap.hard })
    end
    local function itemsOf(rows)
        local out = {}
        for _, r in ipairs(rows) do if r.item then table.insert(out, r.item) end end
        return out
    end
    local function ordered(items, down)
        for i = 2, table.getn(items) do
            local a, b = string.lower(items[i - 1].n), string.lower(items[i].n)
            if (down and a < b) or (not down and a > b) then return false end
        end
        return true
    end
    local function menuValue(v)
        for _, info in ipairs(MENU) do if info.value == v then return info end end
    end
    local raid = RaidResBridge_Raids[RB.raid]
    local places, shared = {}, 0
    for _, it in ipairs(raid.items) do
        if it.o == 999 then shared = shared + 1 else places[it.b] = it.o end
    end

    check("by boss is the default", f.lootSort:GetText(), "By boss")
    local rows = allRows()
    local heads, lastPlace, inOrder, sortedWithin = {}, -1, true, true
    local run = {}
    for _, r in ipairs(rows) do
        if r.header then
            table.insert(heads, r.header)
            if not ordered(run) then sortedWithin = false end
            run = {}
            local p = places[r.header]
            if p then
                if p < lastPlace then inOrder = false end
                lastPlace = p
            end
        else
            table.insert(run, r.item)
        end
    end
    if not ordered(run) then sortedWithin = false end
    check("bosses come in kill order", inOrder, true)
    check("A to Z within each boss", sortedWithin, true)
    check("loot more than one boss drops comes last, under Shared", heads[table.getn(heads)], "Shared")
    local underShared = 0
    for i = table.getn(rows), 1, -1 do
        if rows[i].header then break end
        underShared = underShared + 1
    end
    check("all of it", underShared, shared)
    check("the window draws the same rows", visible(f.lRows)[1].data.header, heads[1])

    click(f.lootSort)
    check("Sort opens its menu", f.lootSortMenu.ddOpen, true)
    check("with by boss ticked", menuValue("boss").checked, 1)
    pick(menuValue("az"))
    rows = allRows()
    check("A to Z is one list, no headings", table.getn(itemsOf(rows)), table.getn(rows))
    check("A to Z", ordered(itemsOf(rows)), true)
    check("and every item is there", table.getn(rows), table.getn(raid.items))
    check("the button says so", f.lootSort:GetText(), "A to Z")
    check("and it's kept", RaidResBridge_Options.lootSort, "az")
    click(f.lootSort)
    pick(menuValue("za"))
    check("Z to A", ordered(itemsOf(allRows()), true), true)
    click(f.lootSort)
    pick(menuValue("boss"))
    check("and back to by boss", allRows()[1].header ~= nil, true)

    print("only some bosses' loot")
    local function picked()
        return RB.ItemRows(RB.raid, { sort = RB.LootSort(), show = RB.LootShow(), hard = f.snap.hard,
                                      bosses = RB.LootBosses(RB.raid) })
    end
    local function countOf(key)
        local n = 0
        for _, it in ipairs(raid.items) do
            if ((it.o == 999 and "*shared") or it.b or "") == key then n = n + 1 end
        end
        return n
    end
    check("every boss to start", f.lootBoss:GetText(), "All bosses")
    click(f.lootBoss)
    check("Bosses opens its menu", f.lootBossMenu.ddOpen, true)
    check("with every boss ticked", menuValue("*all").checked, 1)
    local listed = {}
    for _, info in ipairs(MENU) do
        if info.func and info.value ~= "*all" then table.insert(listed, plain(info.text)) end
    end
    check("then the raid's own bosses, in the list's order, Shared last",
        table.concat(listed, "|"), table.concat(heads, "|"))
    check("its ticks stay open, to pick two", menuValue(heads[1]).keepShownOnClick, 1)
    pick(menuValue(heads[1]))
    rows = picked()
    check("one boss: just its heading", rows[1].header, heads[1])
    check("and its loot", table.getn(itemsOf(rows)), countOf(heads[1]))
    check("the button names it", plain(f.lootBoss:GetText()), RB.Fit(heads[1], 14))
    click(f.lootBoss)
    pick(menuValue("*shared"))
    rows = picked()
    local hs = {}
    for _, r in ipairs(rows) do if r.header then table.insert(hs, r.header) end end
    check("two: just their headings", table.concat(hs, "|"), heads[1] .. "|Shared")
    check("and both their loot", table.getn(itemsOf(rows)), countOf(heads[1]) + shared)
    check("the button counts them", f.lootBoss:GetText(), "2 bosses")
    check("kept for this raid", RaidResBridge_Options.lootBosses[RB.raid]["*shared"], true)
    click(f.lootSort)
    pick(menuValue("az"))
    rows = picked()
    check("A to Z: one list of only theirs", table.getn(rows), countOf(heads[1]) + shared)
    check("in order", ordered(itemsOf(rows)), true)
    click(f.lootSort)
    pick(menuValue("boss"))
    -- a search looks through every boss, and the button says so
    f.search:SetText(string.lower(string.sub(raid.items[1].n, 1, 5)))
    fire(f.search, "OnTextChanged")
    local foundAll = RB.ItemRows(RB.raid, { search = RB.search, bosses = RB.LootBosses(RB.raid) })
    local outside = false
    for _, r in ipairs(foundAll) do
        if r.header and r.header ~= heads[1] and r.header ~= "Shared" then outside = true end
    end
    check("a search looks past the bosses ticked", outside or table.getn(foundAll) > 0, true)
    check("and the button says it", plain(f.lootBoss:GetText()), "All: search")
    f.search:SetText("")
    fire(f.search, "OnTextChanged")
    check("cleared, the ticks are back", f.lootBoss:GetText(), "2 bosses")
    -- Show on top: nothing left says so
    RB.ToggleLootShow("hr")
    RB.ToggleLootShow("weapon")
    if not visible(f.lRows)[1] then
        check("nothing left from the bosses picked says so",
            string.find(f.lEmpty:GetText() or "", "No loot from the bosses picked matches Show", 1, true) ~= nil, true)
    end
    RB.ToggleLootShow("all")
    check("another raid isn't emptied by these", RB.LootBosses(-1), nil)
    RaidResBridge_Options.lootBosses[RB.raid] = { ["Nobody Here"] = true }
    check("a boss this raid hasn't counts for nothing", RB.LootBosses(RB.raid), nil)
    click(f.lootBoss)
    pick(menuValue("*all"))
    check("All bosses clears them", RaidResBridge_Options.lootBosses, nil)
    check("a long name fits", RB.Fit("Basalthar & Smoldaris", 14), "Basalthar &...")

    print("ticks in a menu kept open stay true")
    -- The client's open list at `level`: one button per entry the menu
    -- built, each with its Check, as UIDropDownMenu_AddButton leaves them.
    local function shownList(level)
        local lname = "DropDownList" .. level
        local list = NAMED[lname] or CreateFrame("Frame", lname)
        list:Show()
        list.numButtons = table.getn(MENU)
        for i, info in ipairs(MENU) do
            local name = lname .. "Button" .. i
            local b = NAMED[name] or CreateFrame("Button", name, list)
            local mark = NAMED[name .. "Check"] or b:CreateTexture(name .. "Check")
            b.value, b.func, b.keep, b.checked = info.value, info.func, info.keepShownOnClick, info.checked
            if info.checked then mark:Show() else mark:Hide() end
        end
    end
    local function buttonOf(level, value)
        local list = NAMED["DropDownList" .. level]
        for i = 1, list.numButtons do
            local b = NAMED["DropDownList" .. level .. "Button" .. i]
            if b.value == value then return b end
        end
    end
    -- A click as the client makes it: the func first, then the clicked tick
    -- flipped, as the menu stays open; then a frame passes.
    local function clickInList(level, value)
        local b = buttonOf(level, value)
        local old = this
        this = b
        b.func()
        this = old
        if b.keep then
            if b.checked then NAMED[b:GetName() .. "Check"]:Hide(); b.checked = nil
            else NAMED[b:GetName() .. "Check"]:Show(); b.checked = 1 end
        end
        -- one frame (`run` is a list of rows in this block)
        for _, w in ipairs(ALLFRAMES) do
            if w.scripts.OnUpdate and w:IsVisible() then fire(w, "OnUpdate", 0.02) end
        end
    end
    local function tickShown(level, value)
        return NAMED[buttonOf(level, value):GetName() .. "Check"]:IsShown()
    end
    click(f.lootBoss)
    shownList(1)
    check("All bosses ticked to start", tickShown(1, "*all"), true)
    clickInList(1, heads[1])
    check("a boss ticked keeps its tick", tickShown(1, heads[1]), true)
    check("and All bosses loses its", tickShown(1, "*all"), false)
    clickInList(1, "*shared")
    check("a second keeps the first one's tick", tickShown(1, heads[1]), true)
    check("and shows its own", tickShown(1, "*shared"), true)
    clickInList(1, heads[1])
    check("unticking one leaves the other", tickShown(1, "*shared"), true)
    check("and takes its own", tickShown(1, heads[1]), false)
    RB.ToggleLootBoss(RB.raid, "*all")
    click(f.lootShow)
    shownList(1)
    clickInList(1, "plate")
    check("Show: a kind keeps its tick", tickShown(1, "plate"), true)
    check("and All items loses its", tickShown(1, "all"), false)
    UIDROPDOWNMENU_MENU_LEVEL = 2
    MENU = {}
    RB.InitLootShowMenu()
    UIDROPDOWNMENU_MENU_LEVEL = nil
    shownList(2)
    clickInList(2, "cls:PALADIN")
    check("a class in the side list keeps its tick", tickShown(2, "cls:PALADIN"), true)
    check("and Class beside it gets one", tickShown(1, "class"), true)
    check("and plate keeps its", tickShown(1, "plate"), true)
    NAMED["DropDownList1"]:Hide()
    NAMED["DropDownList2"]:Hide()
    UIDROPDOWNMENU_OPEN_MENU = nil
    RB.ToggleLootShow("all")

    print("showing only some kinds of loot")
    local function kinds(k)
        local n = 0
        for _, it in ipairs(raid.items) do
            if string.find(" " .. (it.t or "") .. " ", " " .. k .. " ", 1, true) then n = n + 1 end
        end
        return n
    end
    click(f.lootShow)
    check("Show opens its menu", f.lootShowMenu.ddOpen, true)
    check("raidres's kinds, in its order",
        menuValue("cloth") and menuValue("weapon") and menuValue("back") and menuValue("hr")
        and menuValue("back").text, "Cape")
    check("all of them, to start", menuValue("all").checked, 1)
    check("ticks stay open, to pick several", menuValue("plate").keepShownOnClick, 1)
    pick(menuValue("plate"))
    check("plate only", table.getn(itemsOf(allRows())), kinds("plate"))
    check("the button says what shows", f.lootShow:GetText(), "Plate")
    click(f.lootShow)
    check("plate is ticked", menuValue("plate").checked, 1)
    pick(menuValue("mail"))
    check("plate or mail", table.getn(itemsOf(allRows())), kinds("plate") + kinds("mail"))
    check("the first of them in the menu's order, and how many more", f.lootShow:GetText(), "Mail +1")
    check("it's kept", RaidResBridge_Options.lootShow.mail, true)
    click(f.lootShow)
    pick(menuValue("all"))
    check("All shows everything again", table.getn(itemsOf(allRows())), table.getn(raid.items))
    check("and the button says so", f.lootShow:GetText(), "All items")
    check("with nothing kept", RaidResBridge_Options.lootShow, nil)

    local hard = 0
    for _, it in ipairs(raid.items) do if f.snap.hard[it.g] then hard = hard + 1 end end
    click(f.lootShow)
    pick(menuValue("hr"))
    check("hard reserved only", table.getn(itemsOf(allRows())), hard)
    check("there is one in the list", hard > 0, true)
    click(f.lootShow)
    pick(menuValue("weapon"))
    check("hard reserved and a weapon: nothing here", visible(f.lRows)[1], nil)
    check("and the pane says why",
        string.find(f.lEmpty:GetText(), "matches Show: Weapon/Shield +1", 1, true) ~= nil, true)
    click(f.lootShow)
    pick(menuValue("all"))

    -- a loot table cached before kinds were kept
    local saved = raid.items
    local old = {}
    for _, it in ipairs(saved) do
        table.insert(old, { g = it.g, n = it.n, q = it.q, b = it.b, c = it.c })
    end
    raid.items = old
    RB.Refresh()
    check("an older loot table keeps its bosses", allRows()[1].header ~= nil, true)
    click(f.lootShow)
    check("can't be shown by kind", menuValue("plate").disabled, 1)
    check("hard reserved still can", menuValue("hr").disabled, nil)
    FILES["RaidResBridge_request.txt"] = nil
    pick(menuValue("update"))
    check("and the menu offers the update", FILES["RaidResBridge_request.txt"], "RAIDS")
    raid.items = saved
    RaidResBridge_Options.lootSort = nil
    RB.Refresh()
end

print("class items for one class")
do
    -- a loot table of its own: tier for one class, a token for three, a
    -- libram with no class list, a bag, and one cached before lists were kept
    local was = RaidResBridge_Raids[7777]
    RaidResBridge_Raids[7777] = { name = "Test Halls", items = {
        { g = 1, n = "Lawbringer Helm", b = "A", o = 1, t = "plate class", c = { "Paladin" } },
        { g = 2, n = "Cenarion Helm", b = "A", o = 1, t = "leather class", c = { "Druid" } },
        { g = 3, n = "Qiraji Bindings", b = "A", o = 1, t = "class", c = { "Paladin", "Hunter", "Rogue" } },
        { g = 4, n = "Libram of Truth", b = "A", o = 1, t = "class", c = {} },
        { g = 5, n = "Core Felcloth Bag", b = "A", o = 1, t = "class", c = {} },
        { g = 6, n = "Old Robe", b = "A", o = 1, t = "class" },
        { g = 7, n = "Plain Ring", b = "A", o = 1, t = "ring", c = {} },
    } }
    local function names(show)
        local out = {}
        for _, r in ipairs(RB.ItemRows(7777, { sort = "az", show = show })) do table.insert(out, r.item.n) end
        return table.concat(out, ",")
    end
    check("Class alone: every class item",
        names({ class = true }), "Cenarion Helm,Core Felcloth Bag,Lawbringer Helm,Libram of Truth,Old Robe,Qiraji Bindings")
    check("one class: its items, the libram by its name, and those that can't be told",
        names({ class = true, ["cls:PALADIN"] = true }),
        "Core Felcloth Bag,Lawbringer Helm,Libram of Truth,Old Robe,Qiraji Bindings")
    check("two classes", names({ class = true, ["cls:DRUID"] = true, ["cls:HUNTER"] = true }),
        "Cenarion Helm,Core Felcloth Bag,Old Robe,Qiraji Bindings")
    check("a class pick leaves the other kinds alone",
        names({ class = true, ["cls:DRUID"] = true, ring = true }), "Cenarion Helm,Core Felcloth Bag,Old Robe,Plain Ring")
    RaidResBridge_Raids[7777] = was

    local function menuValue(v)
        for _, info in ipairs(MENU) do if info.value == v then return info end end
    end
    RaidResBridge_Options.lootShow = nil
    click(f.lootShow)
    check("Class has a side list", menuValue("class").hasArrow, 1)
    UIDROPDOWNMENU_MENU_LEVEL = 2
    MENU = {}
    RB.InitLootShowMenu()
    UIDROPDOWNMENU_MENU_LEVEL = nil
    check("of the nine classes", table.getn(MENU), 9)
    check("in their colours", plain(MENU[4].text) == "Paladin" and MENU[4].text ~= "Paladin", true)
    check("its ticks stay open", MENU[4].keepShownOnClick, 1)
    pick(MENU[4])
    check("a class turns Class on", RaidResBridge_Options.lootShow.class, true)
    check("and the button says which", f.lootShow:GetText(), "Class: Paladin")
    check("and its tooltip", string.find(f.lootShow.tipBody, "Class: Paladin", 1, true) ~= nil, true)
    RB.ToggleLootShow("cls:WARRIOR")
    check("two say how many", f.lootShow:GetText(), "Class: 2")
    check("the tooltip names both", string.find(f.lootShow.tipBody, "Class: Paladin, Warrior", 1, true) ~= nil, true)
    RB.ToggleLootShow("class")
    check("Class off takes its classes with it", RaidResBridge_Options.lootShow, nil)
end

-- ================================================================== sorting
print("column headers")
click(f.colName)
local prev, sorted = "", true
for _, pl in ipairs(RB.gui.snap.players) do
    if pl.name < prev then sorted = false end
    prev = pl.name
end
check("Name sorts by name", sorted, true)
check("so a full player can lead", RB.gui.snap.players[1].name, "Aldwyn")
click(f.colCount)
check("Reserves puts the ones still to do first", RB.gui.snap.players[1].count < 2, true)

-- ================================================================== colours
print("the client's own colours")
RAID_CLASS_COLORS = { MAGE = { r = 1, g = 0, b = 0 } }
GetItemQualityColor = function(q) if q == 4 then return 0.5, 0, 1 end return 1, 1, 1 end
RB.Refresh()
check("class colours come from RAID_CLASS_COLORS",
    string.find(findRow(f.pRows, "Newbie").text:GetText(), "|cffff0000Newbie", 1, true) ~= nil, true)
local epic
for _, r in ipairs(visible(f.lRows)) do
    if r.data and r.data.item and r.data.item.q == 4 then epic = r end
end
check("item colours come from GetItemQualityColor",
    epic and string.find(epic.text:GetText(), "|cff8000ff", 1, true) ~= nil, true)
RAID_CLASS_COLORS, GetItemQualityColor = nil, nil
RB.Refresh()

-- ================================================================== links
print("links and tooltips")
SHIFT = true
ChatFrameEditBox.shown = true
local lid = firstItemRow(f).data.item.g
local beforeTyped = RB.gui.snap.typedCount
click(itemRow(f, lid))
check("shift-click links it in chat", ChatFrameEditBox.inserted and
    string.find(ChatFrameEditBox.inserted, "|Hitem:" .. lid .. ":0:0:0|h[", 1, true) ~= nil, true)
check("without reserving it", RB.gui.snap.typedCount, beforeTyped)
ChatFrameEditBox.shown = false
ChatFrameEditBox.inserted = nil
click(itemRow(f, lid))
check("with chat closed it says how", string.find(hint(f), "open the chat box", 1, true) ~= nil, true)
SHIFT = false
CTRL = true
click(itemRow(f, lid))
check("ctrl-click tries it on", DRESSED, "item:" .. lid .. ":0:0:0")
CTRL = false

enter(itemRow(f, lid))
check("an unseen item gets no hyperlink", TIP.link, nil)
check("but says it hasn't been seen", tipHas("Not seen in game yet"), true)
CACHED[lid] = { name = "Cached Thing", q = 4, icon = "Interface\\Icons\\X" }
RB.Refresh()
enter(itemRow(f, lid))
check("a cached item gets the real tooltip", TIP.link, "item:" .. lid .. ":0:0:0")
check("and its icon shows on the row", itemRow(f, lid).icon.texture, "Interface\\Icons\\X")
check("the tooltip says what a click does", tipHas("Click: reserve for Zed"), true)
enter(itemRow(f, hardId) or firstItemRow(f))
enter(findRow(f.pRows, "Aldwyn"))
check("a player's tooltip lists their reserves", table.getn(TIP.lines) >= 4, true)

-- ================================================================== clearing
print("clear typed")
click(itemRow(f, lid))
check("one typed", RB.gui.snap.typedCount >= 1, true)
click(f.clear)
check("clearing asks first", POPUP and POPUP.which, "ZYLLARAIDRES_CLEAR")
check("saying how many", POPUP.arg, tostring(RB.gui.snap.typedCount))
check("nothing gone yet", next(RaidResBridge_Manual) ~= nil, true)
StaticPopupDialogs.ZYLLARAIDRES_CLEAR.OnAccept()
check("accepting clears it", next(RaidResBridge_Manual), nil)
check("and the button greys out", f.clear.enabled, false)
check("raidres's own stay", table.getn(RB.WhoHas(webId)) > 0, true)

-- ================================================================== RollFor
print("without RollFor")
RollFor = nil
NOW = NOW + 5    -- past the "cleared" notice, which outranks it for 4s
RB.Refresh()
check("the RollFor box says RollFor is missing",
    string.find(plain(f.rfHead:GetText()), "RollFor isn't loaded", 1, true) ~= nil, true)
check("not the hint, which stays on what to click", string.find(hint(f), "RollFor", 1, true), nil)
check("and Send is greyed out", f.send.enabled, false)
check("and so is View", f.view.enabled, false)
fakeRollFor()

-- ================================================================== fetching
print("fetching from the window")
f.link:SetText("https://raidres.top/res/ABC123")
fire(f.link, "OnEnterPressed")
check("Enter in the box fetches", FILES["RaidResBridge_request.txt"], "ABC123")
fire(f, "OnUpdate", 0.3)
check("the status says it's waiting", string.find(plain(f.status:GetText()), "Waiting for the watcher", 1, true) ~= nil, true)
f.link:SetText("")
click(f.fetch)
check("an empty box asks for a link", string.find(hint(f), "paste a raidres link", 1, true) ~= nil, true)

print("no loot tables")
RaidResBridge_Raids = nil
RB.Refresh()
check("the loot pane says why it's empty", f.lEmpty:IsShown(), true)
check("with a button to fix it", f.lEmptyButton:IsVisible(), true)
FILES["RaidResBridge_request.txt"] = nil
click(f.lEmptyButton)
check("which asks for the loot tables", FILES["RaidResBridge_request.txt"], "RAIDS")
RaidResBridge_Raids = Expected_Raids

-- ================================================================== closing
print("closing")
MENU_CLOSED = false
f:Hide()
check("closing closes any open dropdown", MENU_CLOSED, true)
check("with the menu-close sound", SOUNDS[table.getn(SOUNDS)], "igMainMenuClose")
SlashCmdList.RAIDRESBRIDGE("gui")
check("/rrb gui still opens it", f:IsVisible(), true)
SlashCmdList.RAIDRESBRIDGE("")
check("/rrb again closes it", f:IsVisible(), false)
SAID = {}
SlashCmdList.RAIDRESBRIDGE("help")
check("/rrb help explains", heard("opens the window"), true)

-- ================================================================== the zone
print("the zone you're in")
RB = world()
local ZONE = "Orgrimmar"
GetRealZoneText = function() return ZONE end
-- Two raids named unlike their zones, for the aliases.
RaidResBridge_Raids[99] = { name = "Temple of Ahn'Qiraj",
    items = { { g = 21221, n = "Eye of C'Thun", q = 4, b = "C'Thun", c = {} } } }
RaidResBridge_Raids[106] = { name = "Upper Blackrock Spire",
    items = { { g = 12583, n = "Blackhand Doomsaw", q = 4, b = "Rend", c = {} } } }
check("open country is no raid", RB.ZoneRaid(), nil)
ZONE = "Blackwing Lair"
check("a raid's zone is that raid", RB.ZoneRaid(), 94)
ZONE = "Ahn'Qiraj"
check("AQ40's zone is Temple of Ahn'Qiraj", RB.ZoneRaid(), 99)
ZONE = "Blackrock Spire"
check("Blackrock Spire is Upper Blackrock Spire", RB.ZoneRaid(), 106)
ZONE = "zul'gurub"
check("case doesn't matter", RB.ZoneRaid(), 100)

local function zoneChanged(to)
    ZONE = to
    event = "ZONE_CHANGED_NEW_AREA"
    fire(RB.gui, "OnEvent")
end
local function menuEntry(value)
    for _, info in ipairs(openMenu(RB.gui.raidDrop)) do
        if info.value == value then return info end
    end
end

ZONE = "Orgrimmar"
SlashCmdList.RAIDRESBRIDGE("")
f = RB.gui
check("in town, the list's raid shows", f.raidDrop.ddText, "Zul'Gurub")
check("and says why", plain(f.lBox.label:GetText()), "Loot  the list's raid")
zoneChanged("Blackwing Lair")
check("walking into a raid switches to it", f.raidDrop.ddText, "Blackwing Lair")
check("and says so", plain(f.lBox.label:GetText()), "Loot  you're here")
pick(menuEntry(101))
check("the leader can still pick another", f.raidDrop.ddText, "Lower Karazhan Halls")
check("their pick needs no reason", plain(f.lBox.label:GetText()), "Loot")
event = "ZONE_CHANGED_NEW_AREA"
fire(f, "OnEvent")
check("and stands while the zone stays the same", f.raidDrop.ddText, "Lower Karazhan Halls")
FILES["RaidResBridge_data.lua"] = string.gsub(FILES["RaidResBridge_data.lua"], "DEMO42", "DEMO44")
RB.Refresh()
check("a new list brings its own raid", f.raidDrop.ddText, "Zul'Gurub")
zoneChanged("Orgrimmar")
check("leaving a raid keeps what's shown", f.raidDrop.ddText, "Zul'Gurub")
zoneChanged("Ahn'Qiraj")
check("walking into AQ40 finds it by its alias", f.raidDrop.ddText, "Temple of Ahn'Qiraj")

RB = world()
GetRealZoneText = function() return "Blackwing Lair" end
SlashCmdList.RAIDRESBRIDGE("")
check("opened inside a raid, it shows that raid", RB.gui.raidDrop.ddText, "Blackwing Lair")
check("even with a list for another", RB.gui.snap.instance, 100)

RB = world()
RaidResBridge_Raids = nil
GetRealZoneText = function() return "Blackwing Lair" end
SlashCmdList.RAIDRESBRIDGE("")
check("no loot tables, nothing to show", RB.gui.lEmpty:IsShown(), true)
RaidResBridge_Raids = Expected_Raids
RB.Refresh()
check("once they arrive, the zone's raid shows", RB.gui.raidDrop.ddText, "Blackwing Lair")

-- ================================================================== the raid's zone
print("where your raid is")
RB = world()
local MYZONE = "Orgrimmar"
GetRealZoneText = function() return MYZONE end
RaidResBridge_Raids[95] = { name = "Molten Core",
    items = { { g = 16800, n = "Arcanist Boots", q = 4, b = "Lucifron", c = {} } } }
-- The harness runs Lua 5.4, which has no implicit arg table for varargs.
local function at(...)
    local zones = { ... }
    for i = 1, table.getn(zones) do
        ROSTER[i][3], ROSTER[i][4] = zones[i], nil
    end
end
at("Orgrimmar", "Blackwing Lair", "Blackwing Lair", "Orgrimmar", "Molten Core")
local gid, ghow, gn = RB.GroupRaid()
check("in town, the raid where most of your raid is", gid, 94)
check("found through the group", ghow, "group")
check("counting them", gn, 2)
at("Orgrimmar", "Zul'Gurub", "Orgrimmar", "Orgrimmar", "Orgrimmar")
check("one member inside is enough", RB.GroupRaid(), 100)
ROSTER[2][4] = false
check("an offline member doesn't count", RB.GroupRaid(), nil)
at("Orgrimmar", "Molten Core", "Blackwing Lair", "Orgrimmar", "Orgrimmar")
check("a tie goes to the raid that sorts first", RB.GroupRaid(), 94)
check("unless the list's raid is in it", RB.GroupRaid(95), 95)
check("and the list's raid only breaks ties", RB.GroupRaid(100), 94)
at("Orgrimmar", "Molten Core", "Molten Core", "Blackwing Lair", "Zul'Gurub")
check("more people beat the list's raid", RB.GroupRaid(100), 95)
MYZONE = "Lower Karazhan Halls"
local yid, yhow = RB.GroupRaid()
check("your own raid beats the group's", yid, 101)
check("and says it's yours", yhow, "zone")
MYZONE = "Orgrimmar"

at("Orgrimmar", "Blackwing Lair", "Blackwing Lair", "Orgrimmar", "Orgrimmar")
SlashCmdList.RAIDRESBRIDGE("")
f = RB.gui
check("opened in town, it shows where the raid is", f.raidDrop.ddText, "Blackwing Lair")
check("and says how many are there", plain(f.lBox.label:GetText()), "Loot  raid: 2 here")

local refreshes, realSnap = 0, RB.Snapshot
RB.Snapshot = function() refreshes = refreshes + 1; return realSnap() end
local function tick(seconds)
    for _ = 1, math.floor(seconds / 0.25 + 0.5) do fire(f, "OnUpdate", 0.25) end
end
local looks, realGroup = 0, RB.GroupRaid
RB.GroupRaid = function(a) looks = looks + 1; return realGroup(a) end
tick(6)
check("nobody moving means no redraws", refreshes, 0)
check("and it looks every 3 seconds, not every frame", looks, 2)
RB.GroupRaid = realGroup
at("Orgrimmar", "Molten Core", "Molten Core", "Molten Core", "Blackwing Lair")
tick(3)
check("when they move, it follows within seconds", f.raidDrop.ddText, "Molten Core")
check("counting the new raid", plain(f.lBox.label:GetText()), "Loot  raid: 3 here")
check("with one redraw", refreshes, 1)
at("Orgrimmar", "Molten Core", "Orgrimmar", "Orgrimmar", "Orgrimmar")
tick(3)
check("people leaving updates the count", plain(f.lBox.label:GetText()), "Loot  raid: 1 here")
local function entry(value)
    for _, info in ipairs(openMenu(f.raidDrop)) do
        if info.value == value then return info end
    end
end
-- Kara, not the list's raid, so keeping the pick can't pass for falling back.
pick(entry(101))
tick(6)
check("your own pick stands while they stay put", f.raidDrop.ddText, "Lower Karazhan Halls")
at("Orgrimmar", "Orgrimmar", "Orgrimmar", "Orgrimmar", "Orgrimmar")
tick(3)
check("everyone leaving changes nothing", f.raidDrop.ddText, "Lower Karazhan Halls")
at("Orgrimmar", "Blackwing Lair", "Orgrimmar", "Orgrimmar", "Orgrimmar")
tick(3)
check("someone walking back in switches again", f.raidDrop.ddText, "Blackwing Lair")
MYZONE = "Blackwing Lair"
event = "ZONE_CHANGED_NEW_AREA"
fire(f, "OnEvent")
check("joining them yourself says you're here", plain(f.lBox.label:GetText()), "Loot  you're here")
RB.Snapshot = realSnap

-- ================================================================== chat links
print("raidres links in raid chat")
RB = world()
local function says(evt, text, who)
    event, arg1, arg2 = evt, text, who
    ChatFrame_OnEvent(evt)
    return SHOWN[table.getn(SHOWN)].text
end
local shown = says("CHAT_MSG_RAID", "SR is up https://raidres.top/res/ABC123 go go", "Leader")
check("a raid message's link becomes clickable",
    string.find(shown, "|Hraidres:ABC123|h[Raidres ABC123]|h", 1, true) ~= nil, true)
check("with the text around it untouched",
    string.find(shown, "^SR is up ") ~= nil and string.find(shown, " go go$") ~= nil, true)
check("and the message put back for everything else", arg1, "SR is up https://raidres.top/res/ABC123 go go")
check("raid leader chat too", string.find(says("CHAT_MSG_RAID_LEADER",
    "raidres.top/res/LDR111", "Leader"), "|Hraidres:LDR111|h", 1, true) ~= nil, true)
check("raid warnings too", string.find(says("CHAT_MSG_RAID_WARNING",
    "SR: https://raidres.top/res/RW2222!", "Leader"), "|Hraidres:RW2222|h[Raidres RW2222]|h|r!", 1, true) ~= nil, true)
check("other raidres hosts too", string.find(says("CHAT_MSG_RAID",
    "https://raidres.fly.dev/res/FLY333", "Leader"), "|Hraidres:FLY333|h", 1, true) ~= nil, true)
for _, other in ipairs({ "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER", "CHAT_MSG_CHANNEL", "CHAT_MSG_SAY",
                         "CHAT_MSG_YELL", "CHAT_MSG_WHISPER", "CHAT_MSG_PARTY" }) do
    check(other .. " is left alone", says(other, "https://raidres.top/res/NOPE99", "Rando"),
        "https://raidres.top/res/NOPE99")
end
check("nothing seen outside raid chat is remembered", RB.raidLinks.NOPE99, nil)
local twice = RB.LinkifyRaid(RB.LinkifyRaid("https://raidres.top/res/TWO222", "Leader"), "Leader")
local _, wraps = string.gsub(twice, "|Hraidres:", "")
check("one link, not two", wraps, 1)
local foreign = "|cffccccff|Hurl:https://raidres.top/res/URL555|h[https://raidres.top/res/URL555]|h|r"
check("another addon's link with a raidres URL inside is left intact", says("CHAT_MSG_RAID", foreign, "Leader"), foreign)
check("a message without one is passed through", says("CHAT_MSG_RAID", "pull in 10", "Leader"), "pull in 10")
check("an item link nearby is untouched", says("CHAT_MSG_RAID",
    "|cffa335ee|Hitem:19802:0:0:0|h[Heart of Hakkar]|h|r raidres.top/res/ITM444", "Leader"),
    "|cffa335ee|Hitem:19802:0:0:0|h[Heart of Hakkar]|h|r |cff8fd3ff|Hraidres:ITM444|h[Raidres ITM444]|h|r")

print("clicking them")
FILES["RaidResBridge_data.lua"] = nil       -- no active list yet
RB.fetched, RB.loaded = nil, nil
SetItemRef("raidres:ABC123", "[Raidres ABC123]", "LeftButton")
check("a click opens the window", RB.gui and RB.gui:IsVisible(), true)
check("puts the link in the box", RB.gui.link:GetText(), "https://raidres.top/res/ABC123")
check("and fetches it", FILES["RaidResBridge_request.txt"], "ABC123")
check("without asking, with nothing to replace", POPUP, nil)
check("the raidres link isn't passed on", table.getn(REFS), 0)

RB.loaded = "ABC123"
FILES["RaidResBridge_request.txt"] = nil
SetItemRef("raidres:ABC123", "[Raidres ABC123]", "LeftButton")
check("the same list again just refreshes it", FILES["RaidResBridge_request.txt"], "ABC123")
check("still without asking", POPUP, nil)

FILES["RaidResBridge_request.txt"] = nil
SetItemRef("raidres:LDR111", "[Raidres LDR111]", "LeftButton")
check("a different list asks first", POPUP and POPUP.which, "ZYLLARAIDRES_SWITCH")
local ask = StaticPopupDialogs.ZYLLARAIDRES_SWITCH.text
check("naming who posted it", string.find(ask, "Leader's raidres list LDR111", 1, true) ~= nil, true)
check("and what it replaces", string.find(ask, "replaces ABC123", 1, true) ~= nil, true)
check("nothing fetched before the answer", FILES["RaidResBridge_request.txt"], nil)
StaticPopupDialogs.ZYLLARAIDRES_SWITCH.OnAccept()
check("yes fetches it", FILES["RaidResBridge_request.txt"], "LDR111")
POPUP = nil
FILES["RaidResBridge_request.txt"] = nil
SetItemRef("raidres:RW2222", "[Raidres RW2222]", "LeftButton")
StaticPopupDialogs.ZYLLARAIDRES_SWITCH.OnCancel()
check("no leaves the list alone", FILES["RaidResBridge_request.txt"], nil)
check("and forgets the offer", RB.pendingList, nil)

POPUP = nil
SetItemRef("raidres:NOPE99", "[Raidres NOPE99]", "LeftButton")
check("a link that never came from raid chat does nothing", FILES["RaidResBridge_request.txt"], nil)
check("and says why", heard("didn't come from raid chat"), true)
check("without asking", POPUP, nil)

SHIFT = true
ChatFrameEditBox.shown = true
SetItemRef("raidres:ABC123", "[Raidres ABC123]", "LeftButton")
check("shift-click puts the URL in the chat box", ChatFrameEditBox.inserted, "https://raidres.top/res/ABC123")
SHIFT = false
ChatFrameEditBox.shown = false

SetItemRef("item:19802:0:0:0", "[Heart of Hakkar]", "LeftButton")
check("other links go on to the game as usual", REFS[1], "item:19802:0:0:0")

-- ================================================================== names
print("matching names")
-- A row anywhere in the list, scrolling to it: full players sort below the
-- visible rows.
local function findAnywhere(text)
    local g = RB.gui
    for off = 0, (g.pScroll.total or 0) do
        NAMED.ZyllaRaidResPlayerScrollScrollBar:SetValue(off * 18)
        local r = findRow(g.pRows, text)
        if r then return r end
    end
end
RB = world()
ROSTER = {
    { "Tester", "WARRIOR" }, { "Newbie", "MAGE" }, { "Zed", "ROGUE" },
    { "Aldwyn", "PALADIN" }, { "Brisa", "PRIEST" }, { "Corvanne", "WARLOCK" },
    { "Ivo", "HUNTER" }, { "Ivar", "DRUID" },
}
SlashCmdList.RAIDRESBRIDGE("")
f = RB.gui
local corv = findRow(f.pRows, "Corvanne")
check("a typo'd signup shows under their in-game name", corv and rowText(corv), "Corvanne  as Corvane")
check("with their reserves counted", corv and plain(corv.count:GetText()), "2/2")
check("and the raidres name doesn't show twice", findRow(f.pRows, "Corvane  "), nil)
check("the label says how many need a look",
    string.find(plain(f.pBox.label:GetText()), "1 to check", 1, true) ~= nil, true)
enter(corv)
check("the tooltip says how it was matched", tipHas("Signed up as Corvane (matched automatically)"), true)

NAMED.ZyllaRaidResPlayerScrollScrollBar:SetValue(5 * 18)
local ivor = findRow(f.pRows, "Ivor")
check("an unsure one is offered, not matched", ivor and rowText(ivor), "Ivor  maybe Ivar?")
click(ivor)
check("selecting it shows Match", f.matchBtn:IsShown(), true)
check("and the hint says what it's for",
    string.find(hint(f), "Ivor isn't in your raid. If they're here under another name, press Match.", 1, true) ~= nil, true)
click(f.matchBtn)
check("Match opens its menu", f.matchMenu.ddOpen, true)
check("asking who it is", plain(MENU[1].text), "Who is Ivor in your raid?")
check("closest first", plain(MENU[2].text), "Ivar  close match")
check("then the other close one", plain(MENU[3].text), "Ivo  close match")
check("and nobody, last", plain(MENU[table.getn(MENU)].text), "Nobody here")
pick(MENU[3])
check("picking one remembers it", RaidResBridge_Names.ivor, "Ivo")
check("the selection follows them", RB.player, "Ivo")
RB.ResetScroll(f.pScroll)
check("they now hold the reserves", findAnywhere("Ivo  as Ivor") ~= nil, true)
local sentIvo = false
for _, p in ipairs(IMPORTED.softreserves) do if p.name == "Ivo" then sentIvo = true end end
check("and RollFor knows them by it", sentIvo, true)
check("nothing left to check", string.find(plain(f.pBox.label:GetText()), "to check", 1, true), nil)

click(f.matchBtn)
check("a matched pair can be taken back", plain(MENU[1].text), "Ivo signed up as Ivor")
check("a pick of yours has nothing to keep", plain(MENU[2].text), "Unmatch")
pick(MENU[2])
check("unmatching says they're nobody here", RaidResBridge_Names.ivor, false)
check("so they aren't guessed at again", findRow(f.pRows, "maybe"), nil)

click(findAnywhere("Corvanne"))
click(f.matchBtn)
check("an automatic match can be kept", plain(MENU[2].text), "Keep this match")
pick(MENU[2])
check("keeping it pins it", RaidResBridge_Names.corvane, "Corvanne")

click(findAnywhere("Newbie"))
click(f.matchBtn)
check("a raid member not on the list can be given a signup", plain(MENU[1].text), "Which signup is Newbie?")
local lumi
for _, info in ipairs(MENU) do if plain(info.text) == "Lumi" then lumi = info end end
pick(lumi)
check("which is remembered the other way round", RaidResBridge_Names.lumi, "Newbie")
local nl = findAnywhere("Newbie  as Lumi")
check("Newbie now holds Lumi's reserves", nl and plain(nl.count:GetText()), "2/2")

click(findAnywhere("Aldwyn"))
check("someone matched exactly has no Match button", f.matchBtn:IsShown(), false)

RB = world()
GetNumRaidMembers = function() return 0 end
SlashCmdList.RAIDRESBRIDGE("")
click(findRow(RB.gui.pRows, "Ivor"))
check("outside a raid there's nothing to match", RB.gui.matchBtn:IsShown(), false)

print("updated mid-session")
-- A /reload after an update that added Names.lua keeps the old file list,
-- so the window must work without it.
RB = world(true)
SlashCmdList.RAIDRESBRIDGE("")
check("without Names.lua the window still opens", RB.gui and RB.gui:IsVisible(), true)
check("lists the raid", findRow(RB.gui.pRows, "Newbie") ~= nil, true)
click(findRow(RB.gui.pRows, "Newbie"))
check("works", RB.player, "Newbie")
check("just without matching", RB.gui.matchBtn:IsShown(), false)

-- ================================================================== the lock button
print("the lock button")
RB = world()
SlashCmdList.RAIDRESBRIDGE("")
f = RB.gui
local GREEN_TAG, GOLD_TAG = "|cff20ff20", "|cffffd200"
check("a list from raidres gets the button", f.lockBtn:IsShown(), true)
check("it says Locked", plain(f.lockState:GetText()), "Locked")
check("in green", string.find(f.lockState:GetText(), GREEN_TAG, 1, true) ~= nil, true)
check("the status is the list and its raid, no more",
    plain(f.status:GetText()) .. " / " .. plain(f.place:GetText()), "DEMO42 / Zul'Gurub")

local DATA = FILES["RaidResBridge_data.lua"]
FILES["RaidResBridge_data.lua"] = string.gsub(DATA, "RaidResBridge_Locked = true", "RaidResBridge_Locked = false")
RB.Refresh()
check("unlocked says Unlocked", plain(f.lockState:GetText()), "Unlocked")
check("in gold, as a thing to look at", string.find(f.lockState:GetText(), GOLD_TAG, 1, true) ~= nil, true)

FILES["RaidResBridge_data.lua"] = string.gsub(DATA, "RaidResBridge_Locked = true\n", "")
RB.Refresh()
check("a list that doesn't say is Lock ?, not Unlocked", plain(f.lockState:GetText()), "Lock ?")

FILES["RaidResBridge_data.lua"] = nil
RB.Refresh()
check("no list from raidres, no button", f.lockBtn:IsShown(), false)
FILES["RaidResBridge_data.lua"] = DATA
RB.Refresh()
check("and it comes back with one", f.lockBtn:IsShown(), true)

print("the lock button, without the DLL")
enter(f.lockBtn)
check("the tooltip says what it means", tipHas("Locked: nobody can change their reserves on raidres."), true)
check("that it's as of the last fetch", tipHas("As of the last fetch. Press Fetch to check again."), true)
check("and where to lock it", tipHas("Lock or unlock it on the raidres site."), true)
local askedBefore = table.getn(ASKED)
check("(there is no DLL to ask)", RaidResHttpGet, nil)
click(f.lockBtn)
check("clicking says how to check", string.find(hint(f), "press Fetch to check again", 1, true) ~= nil, true)
run(40)
check("and nothing is looked up behind your back", table.getn(ASKED), askedBefore)
check("nor is a watcher request written for it", FILES["RaidResBridge_request.txt"], nil)
-- With nothing able to look again, an old answer can't be doubted: it's the
-- only one there will be.
RB.lockInfo = { ref = "DEMO42", locked = true, at = NOW - 5000 }
RB.Refresh()
check("without the DLL an old state still stands", plain(f.lockState:GetText()), "Locked")

print("the lock button, with the DLL")
RB = world()
fakeDll()
PAGES["/api/events/DEMO42"] = { status = 201, body = eventJson(true) }
SlashCmdList.RAIDRESBRIDGE("")
f = RB.gui
check("opening the window looks at the lock", ASKED[1], "/api/events/DEMO42")
check("quietly, not as a fetch", RB.HttpBusy(), false)
check("so the status doesn't claim to be fetching", string.find(plain(f.status:GetText()), "Fetching", 1, true), nil)
enter(f.lockBtn)
check("until it's answered it's as of the last fetch", tipHas("As of the last fetch; checking now."), true)
run(1)
check("the answer: still locked", plain(f.lockState:GetText()), "Locked")
enter(f.lockBtn)
check("the tooltip now says when", tipHas("Checked "), true)
check("and how often", tipHas("looks again every 30 while this window is open"), true)

run(25)
check("no second look inside half a minute", table.getn(ASKED), 1)
run(10)
check("one every half minute", table.getn(ASKED), 2)

-- Until the next look has been made, then a moment for its answer: a notice
-- lasts 4 seconds, so what it says has to be read straight after.
local function nextLook()
    local n = table.getn(ASKED) + 1
    for _ = 1, 400 do
        if table.getn(ASKED) >= n then break end
        run(0.25)
    end
    run(0.5)
end

-- somebody unlocks it on the site
PAGES["/api/events/DEMO42"] = { status = 201, body = eventJson(false) }
nextLook()
check("the button follows", plain(f.lockState:GetText()), "Unlocked")
check("and the window says so", string.find(hint(f), "unlocked on raidres", 1, true) ~= nil, true)
PAGES["/api/events/DEMO42"] = { status = 201, body = eventJson(true) }
nextLook()
check("and back again", plain(f.lockState:GetText()), "Locked")
check("announced too", string.find(hint(f), "locked on raidres", 1, true) ~= nil, true)

-- the button asks now
local asked = table.getn(ASKED)
click(f.lockBtn)
check("clicking looks immediately", table.getn(ASKED), asked + 1)
check("and says so", string.find(hint(f), "checking raidres", 1, true) ~= nil, true)
click(f.lockBtn)
check("clicking while it's looking doesn't pile on", table.getn(ASKED), asked + 1)
check("and says it already is", string.find(hint(f), "already checking", 1, true) ~= nil, true)
run(1)

-- the site stops answering
PAGES["/api/events/DEMO42"] = nil
run(31)
local afterFail = table.getn(ASKED)
run(31)
check("after a failed look it waits a full minute", table.getn(ASKED), afterFail)
run(30)
check("then tries again", table.getn(ASKED), afterFail + 1)
check("meanwhile what was known is still shown", plain(f.lockState:GetText()), "Locked")
run(120)
check("but not as fact for ever", plain(f.lockState:GetText()), "Lock ?")
enter(f.lockBtn)
check("the tooltip says it isn't known", tipHas("Not known right now."), true)
PAGES["/api/events/DEMO42"] = { status = 201, body = eventJson(true) }
click(f.lockBtn)
run(1)
check("and the next good answer restores it", plain(f.lockState:GetText()), "Locked")

print("the lock button, closed")
f:Hide()
local closedAsked = table.getn(ASKED)
run(120)
check("a closed window looks at nothing", table.getn(ASKED), closedAsked)

-- ================================================================== the RollFor box
print("the RollFor box")
RB = world()
SlashCmdList.RAIDRESBRIDGE("")
f = RB.gui
local function rfHead() return plain(f.rfHead:GetText()) end
local function rfBody() return plain(f.rfBody:GetText()) end
check("nothing sent from here yet", rfHead(), "Not sent to RollFor yet")
check("and it says what to do", rfBody(), "Press Send to import it.")
SAID = {}
click(f.send)
check("Send imports", IMPORTED ~= nil, true)
check("and RollFor's own answer is heard", heard("Soft-res data loaded"), true)
check("the box says RollFor holds it", rfHead(), "In RollFor  sent just now")
local players, reserves = 0, 0
for _, p in ipairs(IMPORTED.softreserves) do
    players = players + 1
    reserves = reserves + table.getn(p.items)
end
check("and what it holds", rfBody(), players .. " players, " .. reserves .. " reserves")
run(65)
check("the time moves on by itself", rfHead(), "In RollFor  sent 1 minute ago")

print("the RollFor box, as changes are made")
click(findRow(f.pRows, "Newbie"))
SAID = {}
local before = IMPORTED
click(firstItemRow(f))
check("a click reaches RollFor", IMPORTED ~= before, true)
check("without RollFor answering in chat", heard("Soft-res data loaded"), false)
check("chat works again afterwards", (function()
    DEFAULT_CHAT_FRAME:AddMessage("hello")
    return heard("hello")
end)(), true)
check("the box keeps up", rfHead(), "In RollFor  sent just now")
check("counting the typed one", string.find(rfBody(), "1 typed here", 1, true) ~= nil, true)

-- RollFor's own import window, or another addon, puts another list in.
RollForCharDb.softres = { data = "someone else's", import_timestamp = CLOCK + 50 }
run(1)
check("another list in RollFor is noticed", rfHead(), "RollFor holds a different list")
RollForCharDb.softres = {}
run(1)
check("so is RollFor's list being cleared", rfHead(), "RollFor's list was cleared")
click(f.send)
check("and Send puts this one back", rfHead(), "In RollFor  sent just now")

-- Typed in without the window, so nothing sent it.
RB.AddManual("Zed", 19857, 4)
RB.Refresh()
check("a change nobody sent shows", rfHead(), "Changed since it was sent")

RollFor.key_bindings.import = function() error("bad data") end
click(f.send)
check("a refusal shows", rfHead(), "RollFor refused the list")
check("with RollFor's reason", string.find(rfBody(), "bad data", 1, true) ~= nil, true)
fakeRollFor()
click(f.send)
check("and clears on the next good send", rfHead(), "In RollFor  sent just now")

click(f.view)
check("View opens RollFor's own window", VIEWED, true)

print("the RollFor box, after a reload")
local keepSent, keepDb, keepManual = RaidResBridge_Sent, RollForCharDb, RaidResBridge_Manual
RB = world()
RaidResBridge_Sent, RollForCharDb, RaidResBridge_Manual = keepSent, keepDb, keepManual
CLOCK = CLOCK + 180
SlashCmdList.RAIDRESBRIDGE("")
f = RB.gui
check("RollFor still holds it", rfHead(), "In RollFor  sent 3 minutes ago")

print("the RollFor box, with nothing to send")
RB = world()
FILES["RaidResBridge_data.lua"] = nil
SlashCmdList.RAIDRESBRIDGE("")
f = RB.gui
check("nothing to send says so", rfHead(), "Nothing to send yet")
check("and Send has nothing to do", f.send.enabled, false)

-- ================================================================== recent lists
print("recent lists")
RB = world()
SlashCmdList.RAIDRESBRIDGE("")
f = RB.gui
click(f.recent)
check("the arrow opens the recent lists", f.recentMenu.ddOpen, true)
check("none yet, and it says so", MENU[2] and MENU[2].disabled, 1)
local zg = f.snap.instance
local function mc(ref) RB.RememberList(ref, { metadata = { instances = { "Molten Core" } } }) end
local function ony(ref) RB.RememberList(ref, { metadata = { instances = { "Onyxia's Lair" } } }) end
for i = 1, 5 do mc("MC" .. i) end
ony("ONY1")
RB.RememberList("DEMO42", { metadata = { instance = zg, instances = { "raidres's name" } } })
mc("mc4")
local function recentRefs()
    local out = {}
    for _, r in ipairs(RaidResBridge_Recent) do table.insert(out, r.ref) end
    return table.concat(out, ",")
end
check("the last three of each raid, newest first, a repeat moved up",
    recentRefs(), "mc4,DEMO42,ONY1,MC5,MC3")
check("the raid named as the loot tables name it", RaidResBridge_Recent[2].place, "Zul'Gurub")
RB.RememberList("DEMO42", { metadata = { instance = zg } })
check("fetched again, it moves to the top, once", recentRefs(), "DEMO42,mc4,ONY1,MC5,MC3")
for i = 1, 6 do RB.RememberList("R" .. i, { metadata = { instances = { "Raid " .. i } } }) end
local places = {}
for _, r in ipairs(RaidResBridge_Recent) do places[r.place] = true end
check("six raids at most: the one run longest ago goes", places["Molten Core"] == nil and places["Raid 6"], true)
RaidResBridge_Recent = nil
mc("MC1"); mc("MC2")
RB.RememberList("DEMO42", { metadata = { instance = zg } })
click(f.recent)
local shown = {}
for _, info in ipairs(MENU) do
    if info.value ~= "new" and info.value ~= "settings" then table.insert(shown, plain(info.text)) end
end
-- what raidres said of each list's SR+ stays with it for "SR+ from"
RB.NoteEventSr("MC2", { allowSrPlus = false })
check("raidres's word on SR+ marks the recent list", RaidResBridge_Recent[2].sr, false)
RB.eventSr.MC9 = true
mc("MC9")
check("and a list fetched has it from the start", RaidResBridge_Recent[1].sr, true)
mc("MC2")
check("fetched again, it keeps it", RaidResBridge_Recent[1].sr, false)
RaidResBridge_Recent = nil
mc("MC1"); mc("MC2")
RB.RememberList("DEMO42", { metadata = { instance = zg } })
click(f.recent)
shown = {}
for _, info in ipairs(MENU) do
    if info.value ~= "new" and info.value ~= "settings" then table.insert(shown, plain(info.text)) end
end
check("the menu groups them under each raid, the latest raid first", table.concat(shown, " | "),
    "Recent lists | Zul'Gurub | DEMO42  just now | Molten Core | MC2  just now | MC1  just now")
check("the raid names can't be picked", MENU[2].isTitle, 1)
check("the one loaded now is checked", MENU[3].checked, 1)
check("and only that one", MENU[5].checked, nil)
FILES["RaidResBridge_request.txt"] = nil
pick(MENU[5])
check("picking one puts its link in the box", f.link:GetText(), "https://raidres.top/res/MC2")
check("and fetches it", FILES["RaidResBridge_request.txt"], "MC2")
-- the watcher answers: that list is remembered too
FILES["RaidResBridge_data.lua"] = string.gsub(slurp(DIR .. "RaidResBridge_data.lua"), "DEMO42", "NEW777")
RB.Request("NEW777")
run(3)
check("a list the watcher fetched joins them", RaidResBridge_Recent[1].ref, "NEW777")

-- ================================================================== your own, on raidres
print("your own reserves, on raidres")
RB = world()
RaidResLockReady = function() return 1 end     -- RaidResLock.dll is loaded
SlashCmdList.RAIDRESBRIDGE("")
f = RB.gui
local CMD, RESULT = "RaidResBridge_lock_cmd.txt", "RaidResBridge_lock_result.txt"
click(findRow(f.pRows, "Tester"))
check("you are picked", RB.player, "Tester")
check("the hint says your loot goes to raidres",
    string.find(hint(f), "reserve it on raidres as Tester (2 left)", 1, true) ~= nil, true)
local mineRow = firstItemRow(f)
local mineId = mineRow.data.item.g
enter(mineRow)
check("and so does the tooltip", tipHas("Click: reserve it on raidres as Tester"), true)
FILES[CMD] = nil
click(mineRow)
check("a locked list is refused at once", string.find(hint(f), "locked on raidres", 1, true) ~= nil, true)
check("and nothing goes to raidres", FILES[CMD], nil)

RB.SetLock("DEMO42", false)
NOW = NOW + 5
RB.Refresh()
click(firstItemRow(f))
check("unlocked, the click goes to raidres", FILES[CMD], "reserve DEMO42 " .. mineId .. " Tester Warrior")
check("not as a typed reserve", RaidResBridge_Manual.tester, nil)
check("and the window says so", string.find(hint(f), "on raidres...", 1, true) ~= nil, true)
FILES[CMD] = nil
click(firstItemRow(f))
check("a second click waits for the first", string.find(hint(f), "still waiting on raidres", 1, true) ~= nil, true)
check("sending nothing over it", FILES[CMD], nil)
run(4.5)
check("while it waits the hint says so", hint(f), "Waiting on raidres...")

print("raidres wants your spec")
FILES[RESULT] = "needspec"
run(1)
check("the class's own specs open", f.specMenu.ddOpen, true)
check("as words, not raidres's ids", MENU[3] and MENU[3].text, "Fury")
pick(MENU[3])
check("the pick goes along", FILES[CMD], "reserve DEMO42 " .. mineId .. " Tester Warrior WarriorFury")
check("and is kept for next time", RaidResBridge_Spec and RaidResBridge_Spec.tester, "WarriorFury")

FILES["RaidResBridge_request.txt"] = nil
FILES[RESULT] = "ok reserved WarriorFury"
run(1)
check("done: the list is fetched again", FILES["RaidResBridge_request.txt"], "DEMO42")
check("and the window says what happened", string.find(hint(f), "reserved ", 1, true) == 1, true)

print("taking yours back on raidres")
loadstring(slurp(DIR .. "RaidResBridge_data.lua"))()
local withMine = RaidResBridge_Data
table.insert(withMine.softreserves, { name = "Tester", role = "", items = { { id = mineId, quality = 4 } } })
RB.fetched = { unsaved = true, ref = "DEMO42", data = withMine }
RB.waiting = nil
RB.Refresh()
check("yours on raidres say where they live", f.dRows[1].mine:IsShown(), true)
check("beside an X that takes them back there", f.dRows[1].remove:IsShown(), true)
check("not the plain raidres tag", f.dRows[1].tag:IsShown(), false)
enter(itemRow(f, mineId))
check("the loot tooltip offers the same", tipHas("Click: take it back on raidres"), true)
click(f.dRows[1].remove)
check("the X sends it", FILES[CMD], "unreserve DEMO42 " .. mineId .. " Tester")
FILES[RESULT] = "error: Tester hasn't reserved that on raidres"
run(1)
check("raidres's refusal comes back in its words", hint(f), "raidres: Tester hasn't reserved that on raidres")
click(itemRow(f, mineId))
check("clicking the loot itself takes it back too", FILES[CMD], "unreserve DEMO42 " .. mineId .. " Tester")
FILES[RESULT] = "signin"
run(1)
check("a lapsed sign-in says so", string.find(hint(f), "session expired", 1, true) ~= nil, true)
click(itemRow(f, mineId))
check("and nothing is sent until you sign in", string.find(hint(f), "click Sign in", 1, true) ~= nil, true)
RB.sessionExpired = nil
FILES[CMD] = nil
click(itemRow(f, mineId))
check("each command goes with an id", string.find(RAWCMD, "^#%d+ unreserve DEMO42 ") ~= nil, true)
local firstTag = TAG
run(46)
check("a slow helper is still waited on past 45 seconds", RB.reservePending ~= nil, true)
run(75)
check("a helper that never answers is given up on", string.find(hint(f), "did not answer", 1, true) ~= nil, true)
run(5)
check("and the window stops waiting", RB.reservePending == nil and hint(f) ~= "Waiting on raidres...", true)
NOW = NOW + 1
click(itemRow(f, mineId))
check("the next command has its own id", TAG ~= firstTag, true)
FILES[RESULT] = "#" .. firstTag .. " ok removed"
run(1)
check("the answer to the one given up on, late, isn't taken for it", RB.reservePending ~= nil, true)
check("and is cleared away", FILES[RESULT], "")
FILES[RESULT] = "error: bad command"
local saved = TAG
TAG = nil
run(1)
TAG = saved
check("an answer without an id says the helper running is an old one",
    string.find(hint(f), "older copy; restart the game", 1, true) ~= nil, true)

print("everyone else's, and without the helper")
local other = findRow(f.pRows, "Newbie")
click(other)
FILES[CMD] = nil
click(firstItemRow(f))
check("someone else's still go in as typed", RaidResBridge_Manual.newbie ~= nil, true)
check("not to raidres", FILES[CMD], nil)
RB = world()
SlashCmdList.RAIDRESBRIDGE("")
f = RB.gui
click(findRow(f.pRows, "Tester"))
click(firstItemRow(f))
check("without the lock helper, yours are typed too", RaidResBridge_Manual.tester ~= nil, true)
check("and the hint doesn't promise raidres", string.find(hint(f), "on raidres", 1, true), nil)

-- ================================================================== a new event
print("a new event")
RB = world()
SAID = {}
SlashCmdList.RAIDRESBRIDGE("new")
check("without the lock helper, /rrb new says what it needs", heard("needs RaidResLock.dll"), true)
check("and opens nothing", RB.eventFrame, nil)
SlashCmdList.RAIDRESBRIDGE("")
f = RB.gui
click(f.recent)
check("the Recent menu offers one, greyed without the helper",
    plain(MENU[table.getn(MENU)].text) .. " " .. tostring(MENU[table.getn(MENU)].disabled),
    "New event... (needs RaidResLock.dll) 1")

RaidResLockReady = function() return 1 end
click(f.recent)
local newEntry
for _, info in ipairs(MENU) do if info.value == "new" then newEntry = info end end
check("with it, the Recent menu ends with a new event", plain(newEntry.text), "New event...")
check("ready to pick", newEntry.disabled, nil)
pick(newEntry)
local ev = RB.eventFrame
check("opening asks raidres for your saved HR lists", FILES["RaidResBridge_lock_cmd.txt"], "templates")
FILES["RaidResBridge_lock_result.txt"] = 'ok templates [{"id":7,"name":"BWL HRs","raid":94,"hr":2},' ..
    '{"id":8,"name":"ZG HRs","raid":100,"hr":1}]'
run(1)
check("and keeps them", RB.savedLists and table.getn(RB.savedLists), 2)
check("which opens the dialog", ev and ev:IsVisible(), true)
check("titled on the dialog header", ev and ev.title:GetText(), "New raidres event")
local escapes = false
for _, n in ipairs(UISpecialFrames) do if n == "ZyllaRaidResEventFrame" then escapes = true end end
check("Escape closes it", escapes, true)
check("the raid starts as the window's", ev.raid.ddText, "Zul'Gurub")
check("today", string.find(ev.day.ddText, "Today, ", 1, true) == 1, true)
check("at 20:00", ev.hour.ddText .. ":" .. ev.minute.ddText, "20:00")
check("one reserve each, as raidres's form starts", ev.limit.ddText, "1")
check("comments on and the rest off, as raidres's form starts",
    tostring(ev.comments:GetChecked()) .. tostring(ev.lock:GetChecked()) ..
    tostring(ev.srplus:GetChecked()) .. tostring(ev.dupes:GetChecked()), "1nilnilnil")

local function entry(menu, value)
    for _, info in ipairs(menu) do if info.value == value then return info end end
end
local raids = openMenu(ev.raid)
check("without the DLL, the cached raids, in one group", raids[1].isTitle, nil)
pick(entry(raids, 94))
check("a raid is picked", ev.raid.ddText, "Blackwing Lair")
local days = openMenu(ev.day)
check("two weeks of days", table.getn(days), 14)
check("tomorrow second", string.find(days[2].text, "Tomorrow, ", 1, true) == 1, true)
pick(days[2])
pick(entry(openMenu(ev.hour), 19))
pick(entry(openMenu(ev.minute), 30))
pick(entry(openMenu(ev.limit), 2))
ev.lock:SetChecked(1)
fire(ev.lock, "OnClick")

print("a new event: hard reserves and SR+")
check("no hard reserves to begin with", ev.hr.ddText, "None")
local hrMenu = openMenu(ev.hr)
local hrText = {}
for _, info in ipairs(hrMenu) do table.insert(hrText, plain(info.text)) end
check("your saved lists for this raid, then the bosses to pick from",
    string.find(table.concat(hrText, "|"), "None|Your saved lists|BWL HRs  2 HR|Pick items|", 1, true) == 1, true)
check("not another raid's list", string.find(table.concat(hrText, "|"), "ZG HRs", 1, true), nil)
local firstBoss = nil
for _, info in ipairs(hrMenu) do if info.hasArrow then firstBoss = firstBoss or info end end
check("each boss opens its loot", firstBoss and firstBoss.hasArrow, 1)
UIDROPDOWNMENU_MENU_LEVEL, UIDROPDOWNMENU_MENU_VALUE = 2, firstBoss.value
local loot = openMenu(ev.hr)
check("ticked one by one, the menu staying open", loot[1] and loot[1].keepShownOnClick, 1)
pick(loot[1])
pick(loot[2])
UIDROPDOWNMENU_MENU_LEVEL, UIDROPDOWNMENU_MENU_VALUE = nil, nil
check("two picked", ev.hr.ddText, "2 items")
local hrIds = loot[1].value .. "," .. loot[2].value
UIDROPDOWNMENU_MENU_LEVEL, UIDROPDOWNMENU_MENU_VALUE = 2, firstBoss.value
pick(openMenu(ev.hr)[2])
UIDROPDOWNMENU_MENU_LEVEL, UIDROPDOWNMENU_MENU_VALUE = nil, nil
check("ticking one again takes it off", ev.hr.ddText, "1 item")
hrIds = tostring(loot[1].value)
check("SR+ settings hide while SR+ is off", ev.inc:IsShown(), false)
ev.srplus:SetChecked(1)
fire(ev.srplus, "OnClick")
check("and show with it on", ev.inc:IsShown(), true)
check("10 a time to start", ev.inc.ddText, "+10")
pick(entry(openMenu(ev.inc), 20))
check("SR+ on asks raidres for your SR+ events of this raid", FILES["RaidResBridge_lock_cmd.txt"], "suggest 94")
local prevMenu = openMenu(ev.prev)
check("while it asks, the menu says so", plain(prevMenu[3].text), "  asking raidres...")
FILES["RaidResBridge_lock_result.txt"] = 'ok suggest 94 [' ..
    '{"ref":"BWL222","start":' .. (CLOCK - 7 * 86400) .. ',"inc":15,"skip":2,"input":false,"valid":true},' ..
    '{"ref":"BWL111","start":' .. (CLOCK - 14 * 86400) .. ',"inc":0,"skip":0,"input":true,"valid":false}]'
run(1)
RaidResBridge_Recent = {
    { ref = "BWL111", place = "Blackwing Lair" },          -- raidres listed it already
    { ref = "OFF333", place = "Blackwing Lair", sr = false },
    { ref = "NEW444", place = "Blackwing Lair" },
    { ref = "ZG5555", place = "Zul'Gurub" },
}
prevMenu = openMenu(ev.prev)
local prevText = {}
for _, info in ipairs(prevMenu) do table.insert(prevText, plain(info.text)) end
check("fresh, raidres's own, the lists fetched here, then any code",
    table.concat(prevText, " | "),
    "Start fresh | Your SR+ events of Blackwing Lair on raidres | BWL222  " ..
    os.date("%a %d %b", CLOCK - 7 * 86400) .. "  +15 | BWL111  " .. os.date("%a %d %b", CLOCK - 14 * 86400) ..
    "  +0 | Fetched lately | OFF333  SR+ was off | NEW444 | Other | Type a code or link...")
local offRow
for _, info in ipairs(prevMenu) do if string.find(plain(info.text), "OFF333", 1, true) then offRow = info end end
check("one raidres said had SR+ off can't be picked", offRow and offRow.disabled, 1)
pick(entry(prevMenu, "BWL222"))
check("picked", ev.prev.ddText, "BWL222")
check("its SR+ settings come with it, as the site copies them",
    ev.inc.ddText .. " " .. tostring(RB.eventForm.skip) .. " " .. tostring(RB.eventForm.input) ..
    " " .. tostring(RB.eventForm.valid), "+15 2 false true")
check("and it says so", plain(ev.status:GetText()), "SR+ carries on from BWL222, +15 each event, as it had.")
pick(entry(openMenu(ev.prev), "BWL111"))
check("one that adds nothing leaves the rest alone", ev.inc.ddText .. " " .. tostring(RB.eventForm.skip), "+15 2")
pick(entry(openMenu(ev.prev), "type"))
check("Type a code asks for it", POPUP and POPUP.which, "ZYLLARAIDRES_PREVCODE")
RB.SetPrevCode("not a code")
check("a bad one is refused", plain(ev.status:GetText()), "That isn't a raidres code: six letters and digits, or its link.")
RB.SetPrevCode(" https://raidres.top/res/abc123 ")
check("a link, without the DLL, is taken as raidres will check it",
    ev.prev.ddText .. " / " .. plain(ev.status:GetText()),
    "ABC123 / SR+ carries on from ABC123; raidres checks it when you save.")
check("and stays on the menu, ticked", entry(openMenu(ev.prev), "ABC123").checked, 1)
local realHttp, realSettings = RB.Http, RB.HttpEventSettings
RB.Http = function() return true end
local answers = {
    OTHER1 = { ref = "OTHER1", raid = 100, srplus = true, inc = 10 },
    NOSR22 = { ref = "NOSR22", raid = 94, srplus = false, inc = 0 },
    GOOD33 = { ref = "GOOD33", raid = 94, srplus = true, inc = 25, skip = 1, input = true, valid = false },
}
RB.HttpEventSettings = function(ref, done)
    if answers[ref] then done(answers[ref]) else done(nil, "raidres has no list " .. ref) end
end
RB.SetPrevCode("MISS44")
check("with the DLL, one raidres hasn't is refused", plain(ev.status:GetText()), "raidres has no list MISS44")
RB.SetPrevCode("other1")
check("another raid's is refused", plain(ev.status:GetText()), "OTHER1 is for another raid: SR+ carries on only within one raid.")
RB.SetPrevCode("NOSR22")
check("one without SR+ is refused", plain(ev.status:GetText()), "NOSR22 didn't have SR+ on, so there's nothing to carry on from.")
check("and the pick stays as it was", ev.prev.ddText, "ABC123")
RB.SetPrevCode("GOOD33")
check("a good one is taken, its settings too", ev.prev.ddText .. " " .. ev.inc.ddText, "GOOD33 +25")
RB.Http, RB.HttpEventSettings = realHttp, realSettings
pick(entry(openMenu(ev.prev), "none"))
check("Start fresh drops it and what it carried",
    ev.prev.ddText .. " " .. tostring(RB.eventForm.skip), "Start fresh nil")
pick(entry(openMenu(ev.inc), 20))
ev.srplus:SetChecked(nil)
fire(ev.srplus, "OnClick")
ev.desc:SetText("BWL night, bring an Onyxia cloak")
local CMD, RESULT = "RaidResBridge_lock_cmd.txt", "RaidResBridge_lock_result.txt"
FILES[CMD] = nil
click(ev.create)
local tomorrow = os.date("%Y-%m-%d", CLOCK + 86400)
check("Create sends the form to the helper", FILES[CMD],
    "create 94 " .. tomorrow .. " 19:30 2 1 1 0 0 hr=" .. hrIds .. " BWL night, bring an Onyxia cloak")
check("and says it's working on it", plain(ev.status:GetText()), "Creating it on raidres...")
check("not twice", ev.create.enabled, false)

FILES["RaidResBridge_request.txt"] = nil
FILES[RESULT] = "ok created NEW777"
run(1)
check("made: the dialog closes", ev:IsVisible(), false)
check("its link goes in the window's box", f.link:GetText(), "https://raidres.top/res/NEW777")
check("and it is fetched", FILES["RaidResBridge_request.txt"], "NEW777")
check("the raid is offered the link", POPUP and POPUP.which, "ZYLLARAIDRES_POST")
check("saying where it would go", POPUP and POPUP.arg, "https://raidres.top/res/NEW777")
StaticPopupDialogs.ZYLLARAIDRES_POST.OnAccept()
check("Post says it in raid chat, once", table.getn(CHAT), 1)
check("as one plain line", CHAT[1] and (CHAT[1].channel .. ": " .. CHAT[1].text),
    "RAID: Soft reserves are open: https://raidres.top/res/NEW777 (Blackwing Lair)")

print("a new event, next time")
SlashCmdList.RAIDRESBRIDGE("new")
check("it starts from last time's choices",
    ev.raid.ddText .. " " .. ev.hour.ddText .. ":" .. ev.minute.ddText .. " x" .. ev.limit.ddText,
    "Blackwing Lair 19:30 x2")
check("with the lock still on", ev.lock:GetChecked(), 1)
check("and the description", ev.desc:GetText(), "BWL night, bring an Onyxia cloak")
pick(openMenu(ev.day)[1])
pick(entry(openMenu(ev.hour), 0))
pick(entry(openMenu(ev.minute), 0))
FILES[CMD] = nil
click(ev.create)
check("a time already gone is refused here", plain(ev.status:GetText()), "That time has already passed.")
check("and nothing is sent", FILES[CMD], nil)
pick(days[3])
pick(entry(openMenu(ev.hr), 7))
check("a saved list can be picked", ev.hr.ddText, "Saved: BWL HRs")
ev.srplus:SetChecked(1)
fire(ev.srplus, "OnClick")
FILES[CMD] = nil
click(ev.create)
check("it goes by its id, with the SR+ settings",
    string.find(FILES[CMD] or "", " 1 0 tpl=7 inc=20 BWL night", 1, true) ~= nil, true)
FILES[RESULT] = "error: Start time must be in the future"
run(1)
check("raidres's refusal shows in the dialog, in its words",
    plain(ev.status:GetText()), "raidres: Start time must be in the future")
check("which stays open to fix it", ev:IsVisible(), true)
check("and can try again", ev.create.enabled, true)
click(ev.create)
FILES[RESULT] = "signin"
run(1)
check("a lapsed sign-in says what to do",
    string.find(plain(ev.status:GetText()), "Click Sign in", 1, true) ~= nil, true)
RB.sessionExpired = nil
click(ev.create)
run(121)
check("a helper that never answers is given up on",
    string.find(plain(ev.status:GetText()), "did not answer", 1, true) ~= nil, true)
check("and Create works again", ev.create.enabled, true)

print("a new event, with the DLL")
RB = world()
RaidResLockReady = function() return 1 end
fakeDll()
PAGES["/raids/raids.json"] = { body = '[' ..
    '{"id":95,"name":"Molten Core","raidType":"RAID40","maxAttendance":40,"game":"TURTLE"},' ..
    '{"id":116,"name":"Azuregos","raidType":"WORLDBOSS","maxAttendance":40,"game":"TURTLE"},' ..
    '{"id":101,"name":"Lower Karazhan Halls","raidType":"RAID10","maxAttendance":10,"game":"TURTLE"},' ..
    '{"id":100,"name":"Zul\'Gurub","raidType":"RAID20","maxAttendance":20,"game":"TURTLE"},' ..
    '{"id":94,"name":"Blackwing Lair","raidType":"RAID40","maxAttendance":40,"game":"TURTLE"},' ..
    '{"id":7,"name":"Karazhan","raidType":"RAID10","maxAttendance":10,"game":"TBC"}]' }
SlashCmdList.RAIDRESBRIDGE("new")
ev = RB.eventFrame
run(1)
check("raidres's own raid list is asked for", ASKED[1], "/raids/raids.json")
local grouped = {}
for _, info in ipairs(openMenu(ev.raid)) do table.insert(grouped, plain(info.text)) end
check("grouped by size the way raidres groups them, this game's only",
    table.concat(grouped, ", "),
    "40-man, Blackwing Lair, Molten Core, 20-man, Zul'Gurub, 10-man, Lower Karazhan Halls, " ..
    "World boss, Azuregos")
check("the group names can't be picked", openMenu(ev.raid)[1].isTitle, 1)
SlashCmdList.RAIDRESBRIDGE("new")
run(1)
check("and asked for once a session", table.getn(ASKED), 1)

print("a new event: admins")
do
    RB = world()
    RaidResLockReady = function() return 1 end
    RaidResBridge_NewEvent = nil
    RaidResBridge_Users = nil
    SlashCmdList.RAIDRESBRIDGE("")
    SlashCmdList.RAIDRESBRIDGE("new")
    local ev4 = RB.eventFrame
    FILES["RaidResBridge_lock_result.txt"] = "ok templates []"
    run(1)
    check("none saved yet: it says where they come from",
        string.find(plain(openMenu(ev4.admins)[2].text), "No players saved yet", 1, true) ~= nil, true)
    ev4:Hide()
    local a, b = "221800000000000001", "221800000000000002"
    RaidResBridge_Users = { players = { brisa = { name = "Brisa", id = a }, corvane = { name = "Corvane", id = b } },
                            mine = {} }
    SlashCmdList.RAIDRESBRIDGE("new")
    check("it starts with none", ev4.admins.ddText, "None")
    local menu = openMenu(ev4.admins)
    local names = {}
    for _, info in ipairs(menu) do
        if info.func and info.value ~= "none" then table.insert(names, plain(info.text)) end
    end
    check("the saved players, by name", table.concat(names, ","), "Brisa,Corvane")
    pick(entry(menu, "brisa"))
    check("one ticked shows by name", ev4.admins.ddText, "Brisa")
    pick(entry(openMenu(ev4.admins), "corvane"))
    check("two show as a count", ev4.admins.ddText, "2 players")
    pick(entry(openMenu(ev4.raid), 100))
    pick(openMenu(ev4.day)[3])
    FILES["RaidResBridge_lock_cmd.txt"] = nil
    click(ev4.create)
    check("their raidres accounts go with the event, every digit",
        string.find(FILES["RaidResBridge_lock_cmd.txt"] or "", " admins=" .. a .. "," .. b, 1, true) ~= nil, true)
    FILES["RaidResBridge_lock_result.txt"] = "error: nope"
    run(1)
    ev4:Hide()
    RaidResBridge_Users.players.corvane = nil
    SlashCmdList.RAIDRESBRIDGE("new")
    check("next time, last time's, of those still saved", ev4.admins.ddText, "Brisa")
    pick(entry(openMenu(ev4.admins), "none"))
    check("and None clears them", ev4.admins.ddText, "None")
    ev4:Hide()
    RaidResBridge_Users = nil
end

print("a new event: when raidres doesn't answer")
do
    RB = world()
    RaidResBridge_NewEvent = nil      -- SR+ off, as raidres starts
    RaidResLockReady = function() return 1 end
    SlashCmdList.RAIDRESBRIDGE("")
    SlashCmdList.RAIDRESBRIDGE("new")
    local ev3 = RB.eventFrame
    FILES["RaidResBridge_lock_result.txt"] = "error: CDP eval failed"
    run(1)
    local function find(menu, value)
        for _, info in ipairs(menu) do if info.value == value then return info end end
    end
    local retry = find(openMenu(ev3.hr), "retry")
    check("the HR menu says the saved lists didn't come, and offers to ask again",
        retry and plain(retry.text), "Couldn't get them. Ask again")
    FILES["RaidResBridge_lock_cmd.txt"] = nil
    retry.func()
    check("asking again sends it again", FILES["RaidResBridge_lock_cmd.txt"], "templates")
    FILES["RaidResBridge_lock_result.txt"] = "ok templates []"
    run(1)
    ev3.srplus:SetChecked(1)
    fire(ev3.srplus, "OnClick")
    check("then SR+'s events are asked for", string.find(FILES["RaidResBridge_lock_cmd.txt"], "^suggest ") ~= nil, true)
    FILES["RaidResBridge_lock_result.txt"] = "error: raidres said HTTP 500"
    run(1)
    local again = find(openMenu(ev3.prev), "retry")
    check("SR+ from says raidres didn't, and offers to ask again", again and plain(again.text),
        "  raidres didn't say. Ask again")
    FILES["RaidResBridge_lock_cmd.txt"] = nil
    pick(again)
    check("asking again sends it again", string.find(FILES["RaidResBridge_lock_cmd.txt"] or "", "^suggest ") ~= nil, true)
    FILES["RaidResBridge_lock_result.txt"] = "error: still down"
    run(1)
    ev3:Hide()
    RB.savedLists, RB.templatesState = nil, "failed"    -- as if they had failed too
    FILES["RaidResBridge_lock_cmd.txt"] = nil
    SlashCmdList.RAIDRESBRIDGE("new")
    check("opening the dialog again asks again too", FILES["RaidResBridge_lock_cmd.txt"], "templates")
end

-- ================================================================== an event's settings
print("an existing event's settings")
RB = world()
RaidResLockReady = function() return 1 end
fakeDll()
PAGES["/api/events/DEMO42"] = { body = '{"raidId":100,"allowSrPlus":true,"defaultSrPlusIncrease":15,' ..
    '"previousRaidEventReference":"OLD111","reservations":[]}' }
SlashCmdList.RAIDRESBRIDGE("")
f = RB.gui
click(f.recent)
local setEntry
for _, info in ipairs(MENU) do if info.value == "settings" then setEntry = info end end
check("the Recent menu offers the open list's settings", setEntry and plain(setEntry.text),
    "Event settings for DEMO42...")
pick(setEntry)
local ev2 = RB.eventFrame
local CMD2, RESULT2 = "RaidResBridge_lock_cmd.txt", "RaidResBridge_lock_result.txt"
FILES[RESULT2] = "ok templates []"
run(1)
check("titled with the list", ev2.title:GetText(), "Event settings: DEMO42")
check("only hard reserves and SR+", tostring(ev2.raid:IsShown()) .. tostring(ev2.desc:IsShown()) ..
    tostring(ev2.hr:IsShown()) .. tostring(ev2.srplus:IsShown()), "falsefalsetruetrue")
check("starting from the list's hard reserves", ev2.hr.ddText,
    table.getn(Expected_Data.hardreserves) .. (table.getn(Expected_Data.hardreserves) == 1 and " item" or " items"))
check("and raidres's SR+ settings", tostring(ev2.srplus:GetChecked()) .. " " .. ev2.inc.ddText .. " " .. ev2.prev.ddText,
    "1 +15 OLD111")
check("saved, not created", ev2.create:GetText(), "Save")
check("with SR+ on, raidres is asked for the raid's SR+ events", FILES[CMD2], "suggest 100")
FILES[RESULT2] = 'ok suggest 100 [{"ref":"DEMO42","start":1,"inc":15},{"ref":"OLD111","start":1,"inc":15}]'
run(1)
local own = {}
for _, info in ipairs(openMenu(ev2.prev)) do table.insert(own, info.value or "") end
check("not offering the event itself", string.find(table.concat(own, ","), "DEMO42", 1, true), nil)
check("its own previous one ticked", entry(openMenu(ev2.prev), "OLD111").checked, 1)
FILES[CMD2] = nil
click(ev2.create)
check("an untouched save leaves the hard reserves alone", FILES[CMD2], "settings DEMO42 srplus=1 inc=15 prev=OLD111")
FILES[RESULT2] = "ok saved"
local askedBefore = table.getn(ASKED)
run(1)
check("saved: the dialog closes", ev2:IsVisible(), false)
local refetched = false
for i = askedBefore + 1, table.getn(ASKED) do
    if ASKED[i] == "/api/events/DEMO42" then refetched = true end
end
check("and the list is fetched again", refetched, true)
pick(setEntry)
pick(entry(openMenu(ev2.hr), "none"))
ev2.srplus:SetChecked(nil)
fire(ev2.srplus, "OnClick")
FILES[CMD2] = nil
click(ev2.create)
check("cleared hard reserves and SR+ off go as such", FILES[CMD2], "settings DEMO42 hr=none srplus=0")
FILES[RESULT2] = "error: The previous event does not have SR+ enabled."
run(1)
check("raidres's refusal stays in the dialog", plain(ev2.status:GetText()),
    "raidres: The previous event does not have SR+ enabled.")
ev2:Hide()

print("an existing event's settings, before or without raidres's word on them")
do
PAGES["/api/events/DEMO42"] = { body = '{"raidId":100,"allowSrPlus":true,"defaultSrPlusIncrease":0,' ..
    '"previousRaidEventReference":null,"reservations":[]}' }
pick(setEntry)
FILES[RESULT2] = "ok templates []"
run(1)
check("an event that adds +0 shows +0", ev2.inc.ddText, "+0")
FILES[CMD2] = nil
click(ev2.create)
check("and saves +0, not +10", FILES[CMD2], "settings DEMO42 srplus=1 inc=0 prev=none")
FILES[RESULT2] = "ok saved"
run(1)
local realGet = RB.Get
RB.Get = function() end             -- raidres hasn't answered yet
pick(setEntry)
check("while raidres is read, the dialog says so", plain(ev2.status:GetText()), "Reading SR+ from raidres...")
check("and SR+ shows as not known", ev2.inc.ddText .. " " .. ev2.prev.ddText, "+? ?")
FILES[CMD2] = nil
click(ev2.create)
check("Save before it answers leaves SR+ alone", FILES[CMD2], "settings DEMO42")
FILES[RESULT2] = "ok saved"
run(1)
pick(setEntry)
ev2.srplus:SetChecked(1)
fire(ev2.srplus, "OnClick")
pick(entry(openMenu(ev2.inc), 25))
FILES[CMD2] = nil
click(ev2.create)
check("what is changed goes, and only that", FILES[CMD2], "settings DEMO42 srplus=1 inc=25")
FILES[RESULT2] = "ok saved"
run(1)
RB.Get = realGet
local realHttp = RB.Http
RB.Http = function() return false end
pick(setEntry)
check("without the DLL, the dialog says SR+ is left as it is",
    string.find(plain(ev2.status:GetText()), "leaves SR+ as it is there unless you change it", 1, true) ~= nil, true)
FILES[CMD2] = nil
click(ev2.create)
check("and Save leaves it so", FILES[CMD2], "settings DEMO42")
FILES[RESULT2] = "ok saved"
run(1)
RB.Http = realHttp
PAGES["/api/events/DEMO42"] = nil
pick(setEntry)
run(1)
check("a failed read says so, and what Save will do",
    string.find(plain(ev2.status:GetText()), "couldn't be read", 1, true) ~= nil, true)
ev2:Hide()
end
SlashCmdList.RAIDRESBRIDGE("new")
check("New event afterwards has every row back", tostring(ev2.raid:IsShown()) .. ev2.create:GetText(),
    "trueCreate event")

-- ================================================================== editing one reserve's SR+
print("one reserve's SR+, edited")
RB = world()
RaidResLockReady = function() return 1 end
fakeDll()
PAGES["/api/events/DEMO42"] = { body = '{"locked":false,"allowSrPlus":true,"raidId":100,"reservations":[]}' }
SlashCmdList.RAIDRESBRIDGE("")
f = RB.gui
local aldwyn = findRow(f.pRows, "Aldwyn")
if aldwyn then click(aldwyn) else RB.player = "Aldwyn"; RB.Draw() end
local srRow = f.dRows[1]
fire(srRow, "OnClick", "RightButton")
check("not offered before raidres says SR+ is on", f.srMenu.ddOpen, nil)
run(1)
check("raidres's look at the list says SR+ is on", RB.eventSr.DEMO42, true)
check("asking nothing extra for it", table.getn(ASKED), 1)
enter(srRow)
check("the row says it can be changed", tipHas("Right-click: change its SR+"), true)
fire(srRow, "OnClick", "RightButton")
check("right-click opens its SR+ menu", f.srMenu.ddOpen, true)
check("naming whose and what", string.find(plain(MENU[1].text), "Aldwyn's ", 1, true) == 1, true)
check("set, validate, unvalidate", plain(MENU[2].text) .. " | " .. plain(MENU[3].text) .. " | " .. plain(MENU[4].text),
    "Set SR+... (now +0) | Validated | Not validated")
check("a state raidres hasn't told this list (fetched by the watcher) isn't ticked",
    tostring(MENU[3].checked) .. " " .. tostring(MENU[4].checked), "nil nil")
do
    -- raidres says an officer validated it: the menu and the row say so
    local sk = string.lower(RB.player)
    RB.srValid.demo42 = { [sk] = { [srRow.itemId] = true } }
    RB.Refresh()
    fire(srRow, "OnClick", "RightButton")
    check("validated, it's ticked so", tostring(MENU[3].checked) .. " " .. tostring(MENU[4].checked), "1 nil")
    enter(srRow)
    check("and the row's tooltip says it", tipHas("SR+ 0, validated"), true)
    RB.srValid.demo42 = { [sk] = {} }
    RB.Refresh()
    fire(srRow, "OnClick", "RightButton")
    check("not validated, it's ticked so", tostring(MENU[3].checked) .. " " .. tostring(MENU[4].checked), "nil 1")
end
local CMD3, RESULT3 = "RaidResBridge_lock_cmd.txt", "RaidResBridge_lock_result.txt"
pick(MENU[2])
check("Set asks for the number", POPUP and POPUP.which, "ZYLLARAIDRES_SRPLUS")
check("for that player", POPUP and POPUP.arg, "Aldwyn")
FILES[CMD3] = nil
RB.SendSrPlus(-5)
check("not a negative one", FILES[CMD3], nil)
RB.SendSrPlus(40)
check("the number goes to the helper", FILES[CMD3], "srplus DEMO42 " .. srRow.itemId .. " Aldwyn value=40")
FILES[RESULT3] = "ok srplus"
local before = table.getn(ASKED)
run(1)
local again = false
for i = before + 1, table.getn(ASKED) do if ASKED[i] == "/api/events/DEMO42" then again = true end end
check("saved: the list is fetched again", again, true)
fire(srRow, "OnClick", "RightButton")
pick(MENU[3])
check("validating goes as such", FILES[CMD3], "srplus DEMO42 " .. srRow.itemId .. " Aldwyn valid=1")
FILES[RESULT3] = "error: Forbidden"
run(1)
check("raidres's no comes back in its words", string.find(hint(f), "raidres: Forbidden", 1, true) ~= nil, true)
RB.eventSr.DEMO42 = false
f.srMenu.ddOpen = nil
fire(srRow, "OnClick", "RightButton")
check("a list without SR+ offers nothing", f.srMenu.ddOpen, nil)

-- ================================================================== reserving for someone else
print("reserving on raidres for someone else")
RB = world()
RaidResLockReady = function() return 1 end
SlashCmdList.RAIDRESBRIDGE("")
f = RB.gui
RB.SetLock("DEMO42", false)
NOW = NOW + 5
RB.Refresh()
local CMD4, RESULT4 = "RaidResBridge_lock_cmd.txt", "RaidResBridge_lock_result.txt"
local zed = findRow(f.pRows, "Zed")
enter(zed)
check("a player's tooltip offers it", tipHas("Right-click: reserve on raidres for them"), true)
fire(zed, "OnClick", "RightButton")
check("right-click opens their menu", f.playerMenu.ddOpen, true)
local toggleFor
for _, info in ipairs(MENU) do if info.value == "toggle" then toggleFor = info end end
check("with a tick to reserve on raidres for them", toggleFor and plain(toggleFor.text), "Reserve on raidres for them")
pick(toggleFor)
check("ticked, they are picked", RB.player, "Zed")
check("and the hint says what that means",
    string.find(hint(f), "On raidres for Zed (2 left), filed under your account", 1, true) ~= nil, true)
local zedItem = firstItemRow(f)
local zedId = zedItem.data.item.g
FILES[CMD4] = nil
click(zedItem)
check("their spec is asked for first", f.specMenu.ddOpen, true)
check("from their class's list", MENU[1] and plain(MENU[1].text), "Zed's rogue spec on raidres")
check("and nothing is sent yet", FILES[CMD4], nil)
pick(MENU[3])
check("then it goes to raidres for them", FILES[CMD4], "reserve-for DEMO42 " .. zedId .. " Zed Rogue RogueDaggers")
check("not typed here", RaidResBridge_Manual.zed, nil)
check("their spec is kept", RaidResBridge_Spec and RaidResBridge_Spec.zed, "RogueDaggers")
FILES["RaidResBridge_request.txt"] = nil
FILES[RESULT4] = "ok reserved RogueDaggers"
run(1)
check("done: fetched again", FILES["RaidResBridge_request.txt"], "DEMO42")
-- raidres now has it under Zed: the X takes it back as theirs
loadstring(slurp(DIR .. "RaidResBridge_data.lua"))()
local withZed = RaidResBridge_Data
table.insert(withZed.softreserves, { name = "Zed", role = "", items = { { id = zedId, quality = 4 } } })
RB.fetched = { unsaved = true, ref = "DEMO42", data = withZed }
RB.waiting = nil
RB.Refresh()
check("theirs on raidres can be taken back here", f.dRows[1].remove:IsShown(), true)
do
enter(itemRow(f, zedId))
check("the loot's tooltip says the click takes it back for them",
    tipHas("Click: take it back on raidres for Zed"), true)
check("not that it's theirs alone to change", tipHas("Zed reserved this on raidres."), false)
local zedOther
for _, r in ipairs(visible(f.lRows)) do
    if r.data and r.data.item and r.data.item.g ~= zedId and not f.snap.hard[r.data.item.g] then
        zedOther = zedOther or r
    end
end
enter(zedOther)
check("one they don't hold: reserve it on raidres for them", tipHas("Click: reserve it on raidres for Zed"), true)
do
    -- two copies of it: one row, x2, its X taking one back
    local twice = withZed.softreserves[table.getn(withZed.softreserves)]
    table.insert(twice.items, { id = zedId, quality = 4 })
    RB.Refresh()
    check("two copies show as one row, x2", string.find(plain(f.dRows[1].text:GetText()), " x2", 1, true) ~= nil, true)
    check("and only one row", f.dRows[2]:IsShown(), false)
    check("its X takes back one of them", f.dRows[1].remove.tipBody,
        "Take back one of the 2 copies on raidres. The list is fetched again after.")
    RaidResBridge_Limit = 2
    RB.Refresh()
    enter(zedOther)
    check("two copies make them full on raidres", tipHas("Zed is full on raidres."), true)
    RaidResBridge_Limit = nil
    table.remove(twice.items)
    RB.Refresh()
end
end
click(f.dRows[1].remove)
check("as theirs", FILES[CMD4], "unreserve-for DEMO42 " .. zedId .. " Zed")
FILES[RESULT4] = "error: Zed signed up on raidres themselves; they change it there"
run(1)
check("raidres's no in its words",
    string.find(hint(f), "raidres: Zed signed up on raidres themselves", 1, true) ~= nil, true)

print("someone not listed")
fire(zed, "OnClick", "RightButton")
local addEntry
for _, info in ipairs(MENU) do if info.value == "add" then addEntry = info end end
pick(addEntry)
check("asks their name", POPUP and POPUP.which, "ZYLLARAIDRES_ADDPLAYER")
RB.AddPlayerNamed("wired bro1")
check("not a name with digits", string.find(hint(f), "isn't a character name", 1, true) ~= nil, true)
RB.AddPlayerNamed("wirelock")
check("then their class", f.classMenu.ddOpen, true)
pick(entry(MENU, "WARRIOR"))
check("added, ticked and picked", RB.player .. " " .. tostring(RB.ForOther("DEMO42", "wirelock")), "Wirelock true")
check("kept with the list, for after a /reload", RaidResBridge_ForOthers.demo42.wirelock.on, true)
check("as added here, with their class", RaidResBridge_ForOthers.demo42.wirelock.class, "WARRIOR")
check("then their spec, from raidres's list for that class", MENU[1] and plain(MENU[1].text),
    "Wirelock's warrior spec on raidres")
pick(entry(MENU, "WarriorFury"))
check("kept for next time", RaidResBridge_Spec.wirelock, "WarriorFury")
check("and on the list", findRow(f.pRows, "Wirelock") ~= nil or (function()
    for _, p in ipairs(f.snap.players) do if p.name == "Wirelock" then return true end end
    return false end)(), true)
FILES[CMD4] = nil
click(firstItemRow(f))
check("their picks go to raidres with their class and spec",
    string.find(FILES[CMD4] or "", " Wirelock Warrior WarriorFury", 1, true) ~= nil, true)
FILES[RESULT4] = "ok reserved WarriorFury"
run(1)

do
    local kept = RaidResBridge_ForOthers.demo42.wirelock
    RaidResBridge_ForOthers.demo42.wirelock = nil
    check("not added here, their class comes back from the spec kept", RB.ClassOf("Wirelock"), "WARRIOR")
    RaidResBridge_ForOthers.demo42.wirelock = kept
    local others = RB.Players({ ref = "OTHER1", merged = { softreserves = {} } })
    local shownElsewhere = false
    for _, p in ipairs(others) do if p.name == "Wirelock" then shownElsewhere = true end end
    check("added to one list, they're not on another's", shownElsewhere, false)
    check("nor ticked there", RB.ForOther("OTHER1", "Wirelock"), false)
    -- a /reload: what's kept brings them back as they were
    local saved = RaidResBridge_ForOthers
    RB.fetched.unsaved = true
    RaidResBridge_ForOthers = saved
    RB.Refresh()
    check("after a /reload they're still reserved for on raidres", RB.ReservesForOther(f.snap, "Wirelock"), true)
    RB.RememberList("DEMO42", { metadata = {} })
    check("kept while the list is on the Recent menu", RaidResBridge_ForOthers.demo42 ~= nil, true)
    RaidResBridge_ForOthers.gone11 = { x = { name = "X", on = true } }
    RB.RememberList("DEMO42", { metadata = {} })
    check("forgotten with a list that's left it", RaidResBridge_ForOthers.gone11, nil)
end

print("names with accents")
RB.AddPlayerNamed("Ëlïsàbëthéàn")
check("twelve letters with accents are a name", RB.addingName, "Ëlïsàbëthéàn")
RB.addingName = nil
RB.AddPlayerNamed("Ëlïsàbëthéànë")
check("thirteen aren't", RB.addingName, nil)
RB.AddPlayerNamed("Ä")
check("nor one", RB.addingName, nil)
check("the box holds twelve accented letters' bytes",
    StaticPopupDialogs.ZYLLARAIDRES_ADDPLAYER.maxLetters >= string.len("Ëlïsàbëthéàn"), true)

print("making a player an admin of the list")
do
    local function menuEntry(value)
        for _, info in ipairs(MENU) do if info.value == value then return info end end
    end
    RB.OpenPlayerMenu({ name = "Brisa" })
    local make, unmake = menuEntry("admin"), menuEntry("unadmin")
    check("someone on the raidres list can be made an admin", make and plain(make.text), "Make admin of this list")
    check("or taken off", unmake and plain(unmake.text), "Remove as admin")
    FILES[CMD4] = nil
    pick(make)
    check("it goes to the helper by name", FILES[CMD4], "admin DEMO42 Brisa add")
    FILES[RESULT4] = "ok admin 2"
    run(1)
    check("and says so", string.find(hint(f), "Brisa is now an admin of the list on raidres (2 of 10)", 1, true) ~= nil,
        true)
    RB.OpenPlayerMenu({ name = "Brisa" })
    pick(menuEntry("unadmin"))
    check("taking them off goes as such", FILES[CMD4], "admin DEMO42 Brisa remove")
    FILES[RESULT4] = "error: Brisa isn't an admin of it"
    run(1)
    check("raidres's no in its words", string.find(hint(f), "raidres: Brisa isn't an admin of it", 1, true) ~= nil,
        true)
    RB.OpenPlayerMenu({ name = "Wirelock" })
    check("not someone only added here: raidres doesn't know their account", menuEntry("admin"), nil)
    RB.OpenPlayerMenu({ name = "Nobodyhere" })
    check("nor someone not on the raidres list", menuEntry("admin"), nil)
    -- an account saved from an earlier list: made up, as long as raidres's
    local far = "221800000000000009"
    RaidResBridge_Users = { players = { nobodyhere = { name = "Nobodyhere", id = far } }, mine = {} }
    RB.OpenPlayerMenu({ name = "Nobodyhere" })
    check("one whose account was saved can be, off the list", menuEntry("admin") ~= nil, true)
    pick(menuEntry("admin"))
    check("the saved account goes with the name, every digit", FILES[CMD4], "admin DEMO42 Nobodyhere add id=" .. far)
    FILES[RESULT4] = "ok admin 3"
    run(1)
    RaidResBridge_Users = nil
end

print("and not for yourself, or without the helper")
fire(findRow(f.pRows, "Tester"), "OnClick", "RightButton")
local selfToggle
for _, info in ipairs(MENU) do if info.value == "toggle" then selfToggle = info end end
check("your own row has no for-someone tick", selfToggle, nil)
check("nor an admin entry", (function()
    for _, info in ipairs(MENU) do if info.value == "admin" then return true end end
    return false end)(), false)
RaidResLockReady = nil
f.playerMenu.ddOpen = nil
fire(zed, "OnClick", "RightButton")
check("without the helper, no menu", f.playerMenu.ddOpen, nil)

-- ================================================================== SR+ in the window
print("SR+ beside each reserve")
RB = world()
loadstring(slurp(DIR .. "RaidResBridge_data.lua"))()
local srList = RaidResBridge_Data
srList.softreserves[1].items[1].sr_plus = 30
RB.fetched = { unsaved = true, ref = "DEMO42", data = srList }
SlashCmdList.RAIDRESBRIDGE("")
f = RB.gui
local srName = srList.softreserves[1].name
click(findRow(f.pRows, srName) or (function()
    RB.player = srName; RB.Draw(); return nil end)())
if RB.player ~= srName then RB.player = srName; RB.Draw() end
check("a reserve with SR+ says how much", string.find(plain(f.dRows[1].text:GetText()), "  +30", 1, true) ~= nil, true)
check("one without says nothing", string.find(plain(f.dRows[2].text:GetText() or ""), "+", 1, true), nil)

-- ================================================================== the minimap button
print("the minimap button")
RB = world()
local b = RB.SetupMinimap()
check("it is made at login", b ~= nil and b:IsVisible(), true)
check("named, so pfUI's button bar can gather it", NAMED.ZyllaRaidResMinimapButton, b)
check("on the minimap", b:GetParent(), Minimap)
check("in the tracking button's border", b.border.texture, "Interface\\Minimap\\MiniMap-TrackingBorder")
check("with its icon", b.icon.texture, "Interface\\Icons\\INV_Scroll_03")
local function at(axis) return math.floor(b.point[axis] + 0.5) end
check("it starts low on the left", at(4) .. "," .. at(5), "-75,-27")

enter(b)
check("the tooltip names the addon and version", tipHas("Zylla RaidRes  1.2.0"), true)
check("the list", tipHas("List  DEMO42  Zul'Gurub"), true)
check("who's done", tipHas("Players  12 of 15 done"), true)
check("and RollFor", tipHas("RollFor  Not sent yet"), true)
check("and how to use it", tipHas("Drag  Move this button"), true)

click(b)
check("a click opens the window", RB.gui and RB.gui:IsVisible(), true)
click(b)
check("and another closes it", RB.gui:IsVisible(), false)

-- dragged round to the top
Minimap.GetCenter = function() return 1000, 700 end
Minimap.GetEffectiveScale = function() return 1 end
CURSOR = { 1000, 900 }
fire(b, "OnDragStart")
fire(b, "OnUpdate", 0.1)
fire(b, "OnDragStop")
check("dragging moves it round the edge", at(4) .. "," .. at(5), "0,80")
check("and it stays there", math.floor(RaidResBridge_Options.minimap.angle + 0.5), 90)
check("the drag lets go", b.scripts.OnUpdate, nil)

-- pfUI's minimap is square: the button runs along its edge instead
GetMinimapShape = function() return "SQUARE" end
RaidResBridge_Options.minimap.angle = 10
RB.PlaceMinimapButton()
check("on a square minimap it sits on the edge", at(4), 75)

print("the minimap button's menu")
fire(b, "OnClick", "RightButton")
check("right-click opens the options", b.menu.ddOpen, true)
local function menuItem(value)
    for _, info in ipairs(MENU) do if info.value == value then return info end end
end
check("the look follows pfUI by default", menuItem("auto").checked, 1)
check("pfUI's look needs pfUI", menuItem("pfui").disabled, 1)
IMPORTED = nil
pick(menuItem("send"))
check("Send works from the menu too", IMPORTED ~= nil, true)
SAID = {}
pick(menuItem("hide"))
check("the button can be hidden", b:IsVisible(), false)
check("and remembers it", RaidResBridge_Options.minimap.hide, true)
check("saying how to get it back", heard("/rrb minimap"), true)
SlashCmdList.RAIDRESBRIDGE("minimap")
check("/rrb minimap brings it back", b:IsVisible(), true)

print("picking the look")
SAID = {}
SlashCmdList.RAIDRESBRIDGE("skin blizzard")
check("/rrb skin sets it", RaidResBridge_Options.skin, "blizzard")
check("and says so", heard("look set to"), true)
check("nothing built changes, so no reload", POPUP, nil)
SlashCmdList.RAIDRESBRIDGE("skin sparkly")
check("an unknown look is refused", RaidResBridge_Options.skin, "blizzard")

-- ================================================================== pfUI
print("with pfUI")
RB = world()
local CALLS = {}
local function rec(name) return function(frame) CALLS[name] = (CALLS[name] or 0) + 1; return frame end end
pfUI = { api = {
    CreateBackdrop = function(frame) CALLS.CreateBackdrop = (CALLS.CreateBackdrop or 0) + 1
        frame.backdrop = new("Frame", nil, frame) end,
    CreateBackdropShadow = rec("CreateBackdropShadow"), StripTextures = rec("StripTextures"),
    SkinButton = rec("SkinButton"), SkinCheckbox = rec("SkinCheckbox"),
    SkinDropDown = rec("SkinDropDown"), SkinScrollbar = rec("SkinScrollbar"),
    SkinCloseButton = rec("SkinCloseButton"), SkinArrowButton = rec("SkinArrowButton"),
} }
SlashCmdList.RAIDRESBRIDGE("")
f = RB.gui
check("pfUI skins it", f.pfui, true)
check("its frame and three boxes", CALLS.CreateBackdrop >= 4, true)
check("its ten buttons, the RollFor box's and the loot's Bosses, Sort and Show included", CALLS.SkinButton, 10)
check("both checkboxes", CALLS.SkinCheckbox, 2)
check("the dropdown", CALLS.SkinDropDown, 1)
check("both scroll bars", CALLS.SkinScrollbar, 2)
check("its close button and each reserve's", CALLS.SkinCloseButton, 5)
check("the Recent arrow", CALLS.SkinArrowButton, 1)
RaidResLockReady = function() return 1 end
local buttonsBefore = CALLS.SkinButton
SlashCmdList.RAIDRESBRIDGE("new")
check("the New event dialog takes pfUI's look too", RB.eventFrame and RB.eventFrame.pfui, true)
check("its own buttons, not the window's again", CALLS.SkinButton - buttonsBefore, 2)
check("its nine dropdowns", CALLS.SkinDropDown, 1 + 9)
check("its four checkboxes", CALLS.SkinCheckbox, 2 + 4)
check("without the Blizzard banner", RB.eventFrame.header:IsShown(), false)
RB.eventFrame:Hide()
RaidResLockReady = nil
check("and the RollFor box", f.rBox.backdrop ~= nil, true)
check("rows light flat, as pfUI's lists do", f.pRows[1].hl.blend, "BLEND")
check("and drops the Blizzard banner", f.header:IsShown(), false)
click(findRow(f.pRows, "Newbie"))
check("and still works", RB.player, "Newbie")
b = RB.SetupMinimap()
check("the minimap button takes pfUI's look too", b.skin, "pfui")
check("pfUI's square, not the round border", b.border:IsShown(), false)
check("on pfUI's backdrop", b.backdrop ~= nil, true)

print("with pfUI, choosing Blizzard's look")
POPUP = nil
fire(b, "OnClick", "RightButton")
pick(menuItem("blizzard"))
check("a change to what's built asks to reload", POPUP and POPUP.which, "ZYLLARAIDRES_RELOAD")
StaticPopupDialogs.ZYLLARAIDRES_RELOAD.OnAccept()
check("and reloads on yes", RELOADED, true)
-- what the reload builds
local keepOptions, keepPf = RaidResBridge_Options, pfUI
RB = world()
RaidResBridge_Options, pfUI = keepOptions, keepPf
SlashCmdList.RAIDRESBRIDGE("")
f = RB.gui
check("Blizzard's look, pfUI or not", f.skin, "blizzard")
check("with its banner", f.header:IsShown(), true)
check("and the minimap button's border", RB.SetupMinimap().border:IsShown(), true)

print("with a pfUI that breaks")
RB = world()
pfUI = { api = {
    CreateBackdrop = function(frame) frame.backdrop = new("Frame", nil, frame) end,
    StripTextures = function() end,
    SkinButton = function() error("pfUI changed") end,
} }
SlashCmdList.RAIDRESBRIDGE("")
f = RB.gui
check("a failed skin is reported", f.pfui, false)
check("and the Blizzard banner comes back", f.header:IsShown(), true)
check("the window still opens", f:IsVisible(), true)
click(findRow(f.pRows, "Newbie"))
check("and still works", RB.player, "Newbie")
pfUI = nil

print(string.format("\n%d check(s), %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
