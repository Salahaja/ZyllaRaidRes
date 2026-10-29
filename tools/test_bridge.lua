--[[ test_bridge.lua -- run from the AddOns directory:
       lua ZyllaRaidRes/tools/test_bridge.lua

     Driven against the file the real fetcher produced, not a fixture, because
     the thing most likely to break is the shape of that file rather than the
     logic around it.

     The claim being tested: a list fetched outside the game reaches RollFor
     through the same entry point RollFor's own keybinding uses, and every way
     that can fail says so instead of failing quietly. A soft-reserve list that
     silently does not load is worse than one that never loaded, because the
     raid finds out when the loot drops. ]]

-- The addon folder, from where this script is: works whatever the folder is
-- called (ZyllaRaidRes from git, RaidResBridge in older installs).
local ROOT = string.gsub(arg and arg[0] or "", "tools.[%w_]+%.lua$", "")

--[[ The list the fetcher wrote: the real one when this runs inside a live
     install, otherwise the anonymised one in fixtures. ]]
local function openFetched()
    return io.open("../../CustomData/RaidResBridge_data.lua")
        or io.open(ROOT .. "tools/fixtures/RaidResBridge_data.lua")
end
local failures, checks = 0, 0
local function check(label, got, want)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print("  FAIL " .. label .. ": got " .. tostring(got) ..
            ", wanted " .. tostring(want))
    end
end

-- ------------------------------------------------------------------ stubs
table.getn = table.getn or function(t) return #t end
string.gfind = string.gfind or string.gmatch
-- 1.12 has loadstring; 5.4 renamed it load. The addon is right for the client
-- it runs on, so the harness adapts.
loadstring = loadstring or load
local noop = function() end

local SAID, FILES = {}, {}
local function freshWorld()
    SAID = {}
    -- A fresh folder too. Leaving the previous test's file behind meant
    -- "nothing has been fetched yet" was being asked with something fetched.
    for k in pairs(FILES) do FILES[k] = nil end
    DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(SAID, m) end }
    SlashCmdList = {}
    CreateFrame = function()
        return setmetatable({}, { __index = function() return noop end })
    end
    UIParent = CreateFrame()
    UISpecialFrames = {}
    GameTooltip = CreateFrame()
    GetNumRaidMembers = function() return 0 end
    GetNumPartyMembers = function() return 0 end
    GetRaidRosterInfo = function() return nil end
    UnitName = function() return "Tester" end
    UnitClass = function() return "Warrior", "WARRIOR" end
    RaidResBridge_Raids = nil
    RaidResBridge_Limit = nil
    WriteCustomFile = function(n, t) FILES[n] = t end
    ReadCustomFile = function(n) return FILES[n] end
    RollFor = nil
    RaidResBridge_Data, RaidResBridge_Ref = nil, nil
    RaidResBridge = nil
    RaidResBridge_Manual = nil
    dofile(ROOT .. "RaidResBridge.lua")
    RaidResBridge_Names = nil
    dofile(ROOT .. "Names.lua")
    dofile(ROOT .. "Manual.lua")
    dofile(ROOT .. "Gui.lua")
    return RaidResBridge
end

--[[ A Load that throws is a failed check, not the end of the run. Removing
     one of the addon's guards should name the guard, not take the remaining
     checks down with it. ]]
local function safeLoad(RB)
    -- No argument: Load's first parameter is `quiet`, and passing anything
    -- truthy suppresses the very message these checks look for.
    local ok, result = pcall(RB.Load)
    if not ok then return "raised: " .. tostring(result) end
    return result
end

local function heard(text)
    for i = 1, table.getn(SAID) do
        if string.find(SAID[i], text, 1, true) then return true end
    end
    return false
end

print("\nRaidResBridge: does a fetched list reach RollFor?\n")

----------------------------------------------------------------------
-- reading a link
----------------------------------------------------------------------
local RB = freshWorld()
check("a full link gives the reference", RB.Reference("https://raidres.top/res/DEMO42"), "DEMO42")
check("a trailing slash is tolerated", RB.Reference("https://raidres.top/res/DEMO42/"), "DEMO42")
check("a bare reference is taken as-is", RB.Reference("DEMO42"), "DEMO42")
--[[ Taken from the end rather than matched against a host: the same list is
     served from more than one domain. ]]
check("another domain serving the same list works",
    RB.Reference("https://raidres.fly.dev/res/DEMO42"), "DEMO42")
check("nothing usable gives nothing", RB.Reference("   "), nil)
check("and so does nonsense", RB.Reference("https://"), nil)

----------------------------------------------------------------------
-- the file the real fetcher wrote
----------------------------------------------------------------------
--[[ The actual artefact, not a hand-made one. If raidres changes its shape
     this is the check that notices. ]]
local real = openFetched()
if not real then
    print("  (skipped: run tools/raidres_bridge.py once <link> first)")
else
    local text = real:read("*a")
    real:close()
    RB = freshWorld()
    FILES["RaidResBridge_data.lua"] = text

    local data, err, ref = RB.Read()
    check("the fetched file loads", data ~= nil, true)
    check("without an error", err, nil)
    check("and carries its reference", ref ~= nil and ref ~= "", true)
    check("in RollFor's shape", data.metadata and data.metadata.origin, "raidres")
    check("naming the raid", type(data.metadata.instances[1]), "string")

    local players, items, hard = RB.Describe(data)
    check("with players on it", players > 0, true)
    check("and reservations", items >= players, true)
    print(string.format("  (%d players, %d reservations, %d hard-reserved)",
        players, items, hard))

    --[[ Real WoW item ids, not raidres's internal numbering. Getting this
         wrong is the failure that looks fine: RollFor would import happily and
         then match nothing that ever drops. ]]
    local sane = true
    for _, p in ipairs(data.softreserves) do
        for _, it in ipairs(p.items) do
            if type(it.id) ~= "number" or it.id < 1 or it.id > 99999 then sane = false end
            if type(it.quality) ~= "number" then sane = false end
        end
    end
    check("every reserved item is a plausible WoW item id", sane, true)

    ----------------------------------------------------------------------
    -- handing it to RollFor
    ----------------------------------------------------------------------
    local got
    RollFor = { key_bindings = { import = function(d) got = d end } }
    check("it imports", safeLoad(RB), true)
    check("through RollFor's own entry point", got ~= nil, true)
    check("passing it the same list", got and got.metadata.id, data.metadata.id)
    check("with every player", got and table.getn(got.softreserves),
        table.getn(data.softreserves))
    check("and says what went in", heard("imported"), true)

    --[[ RollFor missing is not an error to swallow: the list was fetched and
         is sitting there, and the player needs to know why nothing happened. ]]
    RB = freshWorld()
    FILES["RaidResBridge_data.lua"] = text
    RollFor = nil
    check("with RollFor absent it refuses", safeLoad(RB), false)
    check("and says so", heard("RollFor is not loaded"), true)

    --[[ A RollFor that throws must not take the addon down with it. ]]
    RB = freshWorld()
    FILES["RaidResBridge_data.lua"] = text
    RollFor = { key_bindings = { import = function() error("nope") end } }
    check("a failing import is caught", safeLoad(RB), false)
    check("and reported", heard("refused it"), true)
end

----------------------------------------------------------------------
-- asking for one
----------------------------------------------------------------------
RB = freshWorld()
RB.Request("https://raidres.top/res/ABC123")
check("the request is written where the watcher looks",
    FILES["RaidResBridge_request.txt"], "ABC123")
check("and the player is told it is waiting", heard("waiting for the watcher"), true)

RB = freshWorld()
RB.Request("   ")
check("an empty link writes no request", FILES["RaidResBridge_request.txt"], nil)
check("and says why", heard("does not look like"), true)

--[[ A scheme with nothing after it is not a reference. Before this it came
     back as "https", which the watcher would have gone and asked the site
     about. ]]
RB = freshWorld()
RB.Request("https://")
check("a bare scheme writes no request", FILES["RaidResBridge_request.txt"], nil)

--[[ Without Nampower there is no folder to meet in, and saying so points at
     the actual fix rather than leaving a request that nothing will ever read. ]]
RB = freshWorld()
WriteCustomFile, ReadCustomFile = nil, nil
RB.Request("DEMO42")
check("without the file API it declines", heard("Nampower"), true)

----------------------------------------------------------------------
-- nothing fetched yet
----------------------------------------------------------------------
RB = freshWorld()
check("loading with nothing fetched fails", safeLoad(RB), false)
check("and explains", heard("nothing has been fetched yet"), true)

RB = freshWorld()
FILES["RaidResBridge_data.lua"] = "this is not lua {{{"
check("a corrupt file is refused", safeLoad(RB), false)
check("rather than erroring", heard("will not parse"), true)

----------------------------------------------------------------------
-- reserves added by hand
----------------------------------------------------------------------
--[[ raidres signs people in through Discord or Steam, and not everyone in a
     raid will do that. They tell the leader in chat, and the leader needs
     somewhere to put it that a refetch will not wipe out. ]]
RB = freshWorld()
check("adding one works", RB.AddManual("Grimtusk", 19019, 5), true)
check("and it is listed", table.getn(RB.ManualList()), 1)
check("the same item twice is refused",
    RB.AddManual("Grimtusk", 19019, 5), false)
--[[ Names are matched without case, because a leader typing in a hurry will
     not capitalise, and two spellings must not become two people each holding
     one reserve. ]]
RB.AddManual("grimtusk", 17182, 5)
check("a different case is the same player", table.getn(RB.ManualList()), 1)
check("with both their items", table.getn(RB.ManualList()[1].items), 2)
check("and the name as first typed", RB.ManualList()[1].name, "Grimtusk")

check("a nameless entry is refused", RB.AddManual("", 123), false)
check("and one with no item", RB.AddManual("Someone", nil), false)

check("one item can be removed", RB.RemoveManual("Grimtusk", 19019), true)
check("leaving the other", table.getn(RB.ManualList()[1].items), 1)
check("removing the last one drops the player", RB.RemoveManual("GRIMTUSK", 17182), true)
check("who is now gone", table.getn(RB.ManualList()), 0)

----------------------------------------------------------------------
-- merging with a fetched list
----------------------------------------------------------------------
local fetched = openFetched()
if not fetched then
    print("  (skipped merge: no fetched list on disk)")
else
    local text = fetched:read("*a")
    fetched:close()

    RB = freshWorld()
    FILES["RaidResBridge_data.lua"] = text
    local base = RB.Read()
    local basePlayers = table.getn(base.softreserves)

    --[[ Someone the website has never heard of is added whole. ]]
    RB.AddManual("Grimtusk", 19019, 5)
    local merged = RB.Merged()
    check("a new name joins the list",
        table.getn(merged.softreserves), basePlayers + 1)
    check("the fetched players are all still there",
        table.getn(merged.softreserves) > basePlayers, true)
    check("and the hard reserves survive",
        table.getn(merged.hardreserves), table.getn(base.hardreserves or {}))
    check("as does which list this is",
        merged.metadata.id, base.metadata.id)

    --[[ Merging twice must give the same answer.

         The obvious check here -- "read the fetched list again and see it
         unchanged" -- cannot fail, because Read re-parses the file every
         call and hands back fresh tables either way. Repeating the merge can
         fail, and catches the real version of that worry: entries
         accumulating, or items being appended to a list that is already in
         the result. ]]
    local twice = RB.Merged()
    check("merging twice gives the same players",
        table.getn(twice.softreserves), table.getn(merged.softreserves))
    local before, after = 0, 0
    for _, pl in ipairs(merged.softreserves) do before = before + table.getn(pl.items) end
    for _, pl in ipairs(twice.softreserves) do after = after + table.getn(pl.items) end
    check("and the same reservations", after, before)

    --[[ A name on both sides keeps ONE entry holding both sets of items,
         rather than appearing twice with one each. ]]
    local who = base.softreserves[1].name
    local hadItems = table.getn(base.softreserves[1].items)
    RB.AddManual(who, 11111, 4)
    merged = RB.Merged()
    local found, items = 0, 0
    for _, p in ipairs(merged.softreserves) do
        if string.lower(p.name) == string.lower(who) then
            found = found + 1
            items = table.getn(p.items)
        end
    end
    check("a player on both lists appears once", found, 1)
    check("holding both their website and typed items", items, hadItems + 1)

    --[[ And an item the website already has them down for is not duplicated
         just because somebody typed it in as well. ]]
    local dupId = base.softreserves[1].items[1].id
    RB.AddManual(who, dupId, 4)
    merged = RB.Merged()
    for _, p in ipairs(merged.softreserves) do
        if string.lower(p.name) == string.lower(who) then
            items = table.getn(p.items)
        end
    end
    check("an item reserved on both sides is not doubled", items, hadItems + 1)
end

----------------------------------------------------------------------
-- with nothing fetched at all
----------------------------------------------------------------------
--[[ A raid organised entirely in chat is an ordinary case, not an error. ]]
RB = freshWorld()
RB.AddManual("Grimtusk", 19019, 5)
local only = RB.Merged()
check("a typed-only list still works", table.getn(only.softreserves), 1)
check("and carries the shape RollFor needs", only.metadata.origin, "raidres")
check("saying where it came from", only.metadata.instances[1], "Manual")

local sent
RollFor = { key_bindings = { import = function(d) sent = d end } }
check("it sends", RB.Apply(true), true)
check("the typed entry included", sent and table.getn(sent.softreserves), 1)

RB = freshWorld()
RollFor = { key_bindings = { import = function() end } }
check("with nothing at all there is nothing to send", RB.Apply(true), false)

----------------------------------------------------------------------
-- the window's two panes
----------------------------------------------------------------------
--[[ The frames cannot be exercised here, but everything that decides what
     goes IN them can, and that is where the mistakes are. ]]
RB = freshWorld()
check("the limit defaults to two", RB.Limit(), 2)
RaidResBridge_Limit = 1
--[[ The event's own limit, not an assumption. Guessing two on a list that
     allows one would quietly let a second reserve through. ]]
check("but the event's own limit wins", RB.Limit(), 1)
RaidResBridge_Limit = nil

----------------------------------------------------------------------
-- who can be given one
----------------------------------------------------------------------
GetNumRaidMembers = function() return 3 end
GetRaidRosterInfo = function(i)
  local names = { "Zed", "Ayla", "Morn" }
  local classes = { "WARRIOR", "PRIEST", "ROGUE" }
  return names[i], nil, nil, nil, nil, classes[i]
end
RB = freshWorld()
GetNumRaidMembers = function() return 3 end
GetRaidRosterInfo = function(i)
  local names = { "Zed", "Ayla", "Morn" }
  local classes = { "WARRIOR", "PRIEST", "ROGUE" }
  return names[i], nil, nil, nil, nil, classes[i]
end

local players = RB.Players()
check("the raid is the player list", table.getn(players), 3)
check("with their classes", players[1].class ~= nil, true)

--[[ The point of the window: whoever has reserved nothing comes first, since
     they are the reason it is open. ]]
--[[ Given to AYLA on purpose. She sorts first alphabetically, so a plain
     name sort would leave her at the top and this check would pass while
     testing nothing -- the ordering that matters is "who still needs one". ]]
RB.AddManual("Ayla", 19019, 5)
RB.AddManual("Ayla", 17182, 5)
players = RB.Players()
check("the one who is full is not first", players[1].name ~= "Ayla", true)
check("they sink to the bottom", players[table.getn(players)].name, "Ayla")
check("with the right count", players[table.getn(players)].count, 2)
check("and whoever has none leads", players[1].count, 0)

--[[ Someone on the list who has not zoned in is still worth seeing. ]]
local fetched = openFetched()
if fetched then
  local text = fetched:read("*a")
  fetched:close()
  RB = freshWorld()
  GetNumRaidMembers = function() return 1 end
  GetRaidRosterInfo = function() return "Zed", nil, nil, nil, nil, "WARRIOR" end
  FILES["RaidResBridge_data.lua"] = text
  players = RB.Players()
  check("signups who are not in the raid still appear",
    table.getn(players) > 1, true)
  local inRaid = 0
  for _, pl in ipairs(players) do if pl.inRaid then inRaid = inRaid + 1 end end
  check("and the raid members are marked as such", inRaid, 1)
end

----------------------------------------------------------------------
-- the loot table
----------------------------------------------------------------------
RB = freshWorld()
RaidResBridge_Raids = {
  [100] = { name = "Zul'Gurub", items = {
    { g = 19802, n = "Heart of Hakkar", q = 5, b = "Hakkar", c = {} },
    { g = 19803, n = "Another Thing",   q = 4, b = "Hakkar", c = {} },
    { g = 19019, n = "Something Else",  q = 4, b = "Jeklik", c = {} },
  } },
  [95] = { name = "Molten Core", items = {} },
}
local list = RB.RaidList()
check("every cached raid is offered", table.getn(list), 2)
check("sorted by name", list[1].name, "Molten Core")

local rows = RB.ItemRows(100)
--[[ Flattened to header-then-items so the scroll offset stays a plain index.
     Two bosses and three items is five rows. ]]
check("the loot comes back grouped by boss", table.getn(rows), 5)
check("a header leads", rows[1].header, "Hakkar")
check("then its items", rows[2].item.n, "Heart of Hakkar")
check("and the next boss follows its own", rows[4].header, "Jeklik")
check("an unknown raid gives nothing", table.getn(RB.ItemRows(999)), 0)

----------------------------------------------------------------------
-- who holds what
----------------------------------------------------------------------
RB.AddManual("Ayla", 19802, 5)
check("an item shows who has it", RB.WhoHas(19802)[1], "Ayla")
check("and an unclaimed one shows nobody", table.getn(RB.WhoHas(19803)), 0)

----------------------------------------------------------------------
-- clicking loot
----------------------------------------------------------------------
--[[ A click gives the item to whoever is selected, and clicking it again
     takes it back -- but only ever from the typed list. ]]
RB = freshWorld()
RaidResBridge_Raids = { [100] = { name = "ZG", items = {
  { g = 19802, n = "Heart", q = 5, b = "Hakkar", c = {} } } } }
RB.raid = 100
local row = RB.ItemRows(100)[2]

RB.player = nil
RB.ClickItem(row)
check("nothing happens with nobody selected", table.getn(RB.ManualList()), 0)
check("and it says to pick someone", heard("pick a player"), true)

RB.player = "Ayla"
RB.ClickItem(row)
check("with a player selected it is reserved", table.getn(RB.WhoHas(19802)), 1)
RB.ClickItem(row)
check("and clicking again takes it back", table.getn(RB.WhoHas(19802)), 0)

--[[ The limit is enforced where the click happens, not just displayed. ]]
RaidResBridge_Limit = 1
RB.ClickItem(row)
check("the first fits", table.getn(RB.WhoHas(19802)), 1)
RaidResBridge_Raids[100].items[2] = { g = 19803, n = "Other", q = 4, b = "Hakkar", c = {} }
local row2 = RB.ItemRows(100)[3]
SAID = {}
RB.ClickItem(row2)
check("the second is refused at the limit", table.getn(RB.WhoHas(19803)), 0)
check("and says why", heard("already has"), true)

----------------------------------------------------------------------
-- matching raidres names to the raid
----------------------------------------------------------------------
RB = freshWorld()
check("the same name scores 1", RB.NameScore("Aldwyn", "aldwyn"), 1)
check("an accent doesn't make another person", RB.NameScore("J\195\182runn", "Jorunn"), 1)
check("neither does a capital accented letter", RB.FoldName("\195\137lowen"), "elowen")
check("one letter off is close", RB.NameScore("Corvane", "Corvanne") >= 0.75, true)
check("strangers are not", RB.NameScore("Tester", "Hestia") < RB.NameGuess, true)
check("an empty name never matches", RB.NameScore("", "Zed"), 0)

local m, g = RB.MatchNames({ "Corvane", "Ivor", "Aldwyn", "Gone" },
                           { "Corvanne", "Ivo", "Ivar", "Aldwyn", "Zed" })
check("a clear typo is matched", m.corvane and m.corvane.name, "Corvanne")
check("automatically", m.corvane and m.corvane.how, "auto")
check("someone on both sides is left alone", m.aldwyn, nil)
check("two equally close names aren't guessed between", m.ivor, nil)
check("but one is offered", g.ivor and (g.ivor.name == "Ivo" or g.ivor.name == "Ivar"), true)
check("nobody alike stays unmatched", m.gone == nil and g.gone == nil, true)

m = RB.MatchNames({ "J\195\182runn" }, { "Jorunn" })
check("accented signups match", m["j\195\182runn"] and m["j\195\182runn"].name, "Jorunn")

m = RB.MatchNames({ "Dagny", "Dagnyy" }, { "Dagnyx" })
check("a member equally close to two signups is matched to neither", (m.dagny and 1 or 0) + (m.dagnyy and 1 or 0), 0)
m, g = RB.MatchNames({ "Brisa" }, { "Brosy" })
check("fairly alike is only a guess", m.brisa, nil)
check("but it is offered", g.brisa and g.brisa.name, "Brosy")

RB.SetMatch("Ivor", "Ivar")
m = RB.MatchNames({ "Ivor" }, { "Ivo", "Ivar" })
check("the leader's pick wins", m.ivor and m.ivor.name, "Ivar")
check("and says so", m.ivor and m.ivor.how, "manual")
m = RB.MatchNames({ "Ivor", "Ivo2" }, { "Ivar", "Ivo" })
check("a picked member isn't given to anyone else", m.ivo2 == nil or m.ivo2.name ~= "Ivar", true)
RB.SetMatch("Ivor", "Nobodyhome")
m = RB.MatchNames({ "Ivor" }, { "Ivo" })
check("a pick for someone who isn't here falls back to matching", m.ivor and m.ivor.name, "Ivo")
RB.SetMatch("Corvane", false)
m, g = RB.MatchNames({ "Corvane" }, { "Corvanne" })
check("'nobody here' stops it being matched", m.corvane, nil)
check("or guessed", g.corvane, nil)

-- The list as RollFor and the window see it: renamed.
RB = freshWorld()
local fx = io.open(ROOT .. "tools/fixtures/RaidResBridge_data.lua")
FILES["RaidResBridge_data.lua"] = fx:read("*a")
fx:close()
GetNumRaidMembers = function() return 2 end
GetRaidRosterInfo = function(i)
  if i == 1 then return "Corvanne", 0, 1, 60, "Warlock", "WARLOCK" end
  return "Tester", 0, 1, 60, "Warrior", "WARRIOR"
end
local function entry(data, name)
  for _, p in ipairs(data.softreserves) do if p.name == name then return p end end
end
local merged = RB.Merged()
check("the signup goes by their in-game name", entry(merged, "Corvanne") ~= nil, true)
check("not their raidres one", entry(merged, "Corvane"), nil)
check("with their reserves", table.getn(entry(merged, "Corvanne").items), 2)
local data = RB.Read()
check("the fetched list itself is untouched", entry(data, "Corvane") ~= nil, true)
RB.AddManual("Corvanne", 19019, 5)
merged = RB.Merged()
check("a typed reserve joins the same person", table.getn(entry(merged, "Corvanne").items), 3)
local sent
RollFor = { key_bindings = { import = function(d) sent = d end } }
RB.Apply(true)
check("RollFor gets the in-game name", sent and entry(sent, "Corvanne") ~= nil, true)
-- Without the file API the list lives in memory, read back as the same
-- table every time; renaming it in place would outlast the match.
WriteCustomFile, ReadCustomFile = nil, nil
RB.fetched = { data = data, ref = "DEMO42", unsaved = true }
check("matched while they're here", entry(RB.Merged(), "Corvanne") ~= nil, true)
local roster2 = GetNumRaidMembers
GetNumRaidMembers = function() return 0 end
check("and back to the raidres name once they're not", entry(RB.Merged(), "Corvane") ~= nil, true)
GetNumRaidMembers = roster2
local players = RB.Players()
local seen = 0
for _, pl in ipairs(players) do
  if pl.name == "Corvanne" or pl.name == "Corvane" then seen = seen + 1 end
end
check("and the window lists them once", seen, 1)

----------------------------------------------------------------------
-- is the list locked on raidres?
----------------------------------------------------------------------
GetTime = function() return 100 end
RB = freshWorld()
local lockFx = io.open(ROOT .. "tools/fixtures/RaidResBridge_data.lua")
local lockText = lockFx:read("*a")
lockFx:close()
check("the fixture says locked", string.find(lockText, "RaidResBridge_Locked = true", 1, true) ~= nil, true)
FILES["RaidResBridge_data.lua"] = lockText
check("nothing is known before the file is read", RB.LockState("DEMO42"), nil)
RB.Read()
check("the file's lock line is read", RB.LockState("DEMO42"), true)
check("for the list it belongs to, however it's cased", RB.LockState("demo42"), true)
check("and for no other", RB.LockState("OTHER1"), nil)
check("a manual-only list has no lock to speak of", RB.LockState("manual"), nil)
RB.SetLock("manual", true)
check("even if one were recorded for it", RB.LockState("manual"), nil)
RB.lockInfo = nil
check("neither does no list", RB.LockState(nil), nil)
local _, checkedAt = RB.LockState("DEMO42")
check("from a file it has no 'checked' time", checkedAt, nil)

FILES["RaidResBridge_data.lua"] = string.gsub(lockText, "RaidResBridge_Locked = true", "RaidResBridge_Locked = false")
RB.Read()
check("unlocked is read as unlocked, not unknown", RB.LockState("DEMO42"), false)

--[[ A file from an older watcher has no lock line. The value left by the
     file before it must not be read as this one's. ]]
FILES["RaidResBridge_data.lua"] = string.gsub(lockText, "RaidResBridge_Locked = true\n", "")
check("the line is really gone from this one", string.find(FILES["RaidResBridge_data.lua"], "Locked", 1, true), nil)
RB.Read()
check("a file without it is unknown", RB.LockState("DEMO42"), nil)

--[[ Only a real true or false counts. An event that doesn't say is not an
     unlocked one. ]]
FILES["RaidResBridge_data.lua"] = string.gsub(lockText, "RaidResBridge_Locked = true", 'RaidResBridge_Locked = "yes"')
RB.Read()
check("anything but a boolean is unknown", RB.LockState("DEMO42"), nil)

RB.SetLock("DEMO42", "locked")
check("and a non-boolean is never recorded", RB.LockState("DEMO42"), nil)
local told
RB.OnLockChanged = function(l) told = l end
RB.SetLock("DEMO42", true)
check("the first sighting is not a change", told, nil)
RB.SetLock("DEMO42", true)
check("nor is the same again", told, nil)
RB.SetLock("DEMO42", false)
check("unlocking is announced", told, false)
RB.SetLock("DEMO42", true)
check("and locking", told, true)
told = nil
RB.SetLock("OTHER2", false)
check("a different list's state is not a change in this one's", told, nil)
check("it has its own", RB.LockState("OTHER2"), false)
-- One list is active at a time, so only its state is kept.
check("and the earlier list's is no longer held", RB.LockState("DEMO42"), nil)

-- A change since the file was written is a change too.
RB = freshWorld()
FILES["RaidResBridge_data.lua"] = lockText
RB.Read()
told = nil
RB.OnLockChanged = function(l) told = l end
RB.SetLock("DEMO42", false)
check("unlocked since the file was written is announced", told, false)

print(string.format("\n%d checks, %d failed\n", checks, failures))
if failures > 0 then os.exit(1) end
