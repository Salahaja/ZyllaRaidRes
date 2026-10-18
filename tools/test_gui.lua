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

local function new(kind, name, parent)
    local w = setmetatable({ kind = kind, name = name, parent = parent, shown = true,
        scripts = {}, txt = "", alpha = 1, enabled = true,
        level = parent and (parent.level + 1) or 0 }, meta)
    if name then NAMED[name] = w; _G[name] = w end
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
UIDropDownMenu_SetSelectedValue = function(frame, v) frame.ddValue = v end
UIDropDownMenu_JustifyText = function() end
UIDropDownMenu_AddButton = function(info) table.insert(MENU, info) end
CloseDropDownMenus = function() MENU_CLOSED = true end
-- ToggleDropDownMenu(level, value, frame, anchor): opening a menu builds it.
ToggleDropDownMenu = function(_, _, frame) MENU = {}; frame.ddInit(); frame.ddOpen = true end
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
local ROSTER, SOUNDS, SHOWN, REFS

local function world(withoutNames)
    NAMED = {}
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
    WriteCustomFile = function(n, t) FILES[n] = t end
    ReadCustomFile = function(n) return FILES[n] end
    RollFor = { key_bindings = { import = function(d) IMPORTED = d end } }
    RaidResHttpGet, RaidResHttpResult = nil, nil
    RaidResBridge, RaidResBridge_Manual, RaidResBridge_Limit = nil, nil, nil
    RaidResBridge_Data, RaidResBridge_Ref = nil, nil

    dofile(DIR .. "expected.lua")
    RaidResBridge_Raids = Expected_Raids
    FILES["RaidResBridge_data.lua"] = slurp(DIR .. "RaidResBridge_data.lua")

    dofile(ROOT .. "RaidResBridge.lua")
    dofile(ROOT .. "Http.lua")
    RaidResBridge_Names = nil
    if not withoutNames then dofile(ROOT .. "Names.lua") end
    dofile(ROOT .. "Manual.lua")
    dofile(ROOT .. "Gui.lua")
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
check("and its raid", string.find(plain(f.status:GetText()), "Zul'Gurub", 1, true) ~= nil, true)
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
check("and selects it in the dropdown", f.raidDrop.ddValue, 94)
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
check("the hint says RollFor is missing", string.find(hint(f), "RollFor isn't loaded", 1, true) ~= nil, true)
check("and Send is greyed out", f.send.enabled, false)
RollFor = { key_bindings = { import = function(d) IMPORTED = d end } }

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
check("and says how many are there", plain(f.lBox.label:GetText()), "Loot  2 of your raid are here")

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
check("counting the new raid", plain(f.lBox.label:GetText()), "Loot  3 of your raid are here")
check("with one redraw", refreshes, 1)
at("Orgrimmar", "Molten Core", "Orgrimmar", "Orgrimmar", "Orgrimmar")
tick(3)
check("people leaving updates the count", plain(f.lBox.label:GetText()), "Loot  1 of your raid is here")
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
    SkinCloseButton = rec("SkinCloseButton"),
} }
SlashCmdList.RAIDRESBRIDGE("")
f = RB.gui
check("pfUI skins it", f.pfui, true)
check("its frame and three boxes", CALLS.CreateBackdrop >= 4, true)
check("its five buttons", CALLS.SkinButton, 5)
check("both checkboxes", CALLS.SkinCheckbox, 2)
check("the dropdown", CALLS.SkinDropDown, 1)
check("both scroll bars", CALLS.SkinScrollbar, 2)
check("the close button", CALLS.SkinCloseButton, 1)
check("and drops the Blizzard banner", f.header:IsShown(), false)
click(findRow(f.pRows, "Newbie"))
check("and still works", RB.player, "Newbie")

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
