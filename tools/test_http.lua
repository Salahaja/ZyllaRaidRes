--[[ test_http.lua -- run from the AddOns directory:
       lua ZyllaRaidRes/tools/test_http.lua

     The in-game fetch, against replies saved from the real site and a stand-in
     for RaidResHttp.dll that answers the way the real one does: "pending" for
     a few looks, then "done" with a status and body.

     The claim being tested: with the DLL loaded, /rrb <link> ends with RollFor
     holding exactly what the watcher would have given it, and every way that
     can fail says so in chat instead of failing quietly. ]]

local failures, checks = 0, 0
local function check(label, got, want)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print("  FAIL " .. label .. ": got " .. tostring(got) .. ", wanted " .. tostring(want))
    end
end

-- ------------------------------------------------------------------ 5.0 on 5.4
table.getn = table.getn or function(t) return #t end
string.gfind = string.gfind or string.gmatch
math.mod = math.mod or math.fmod
loadstring = loadstring or load

-- The addon folder, from where this script is: works whatever the folder is
-- called (ZyllaRaidRes from git, RaidResBridge in older installs).
local ROOT = string.gsub(arg and arg[0] or "", "tools.[%w_]+%.lua$", "")
local DIR = ROOT .. "tools/fixtures/"
local function slurp(name)
    local f = assert(io.open(DIR .. name, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

-- Two tables hold the same data, whatever order it was built in.
local function same(a, b, path)
    path = path or "value"
    if type(a) ~= type(b) then return false, path .. ": " .. type(a) .. " vs " .. type(b) end
    if type(a) ~= "table" then
        if a == b then return true end
        return false, path .. ": " .. tostring(a) .. " vs " .. tostring(b)
    end
    for k, v in pairs(a) do
        local ok, why = same(v, b[k], path .. "." .. tostring(k))
        if not ok then return false, why end
    end
    for k in pairs(b) do
        if a[k] == nil then return false, path .. "." .. tostring(k) .. ": missing" end
    end
    return true
end

local function checkSame(label, a, b)
    local ok, why = same(a, b)
    checks = checks + 1
    if not ok then
        failures = failures + 1
        print("  FAIL " .. label .. ": " .. why)
    end
end

-- ------------------------------------------------------------------ the world
local SAID, FILES, IMPORTED, FRAMES, NOW, DRIVER
local SITE, REQUESTED, PENDING_LOOKS, STATE

local function frame()
    local f = { shown = true, scripts = {} }
    function f:SetScript(name, fn) self.scripts[name] = fn end
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:IsVisible() return self.shown end
    table.insert(FRAMES, f)
    return setmetatable(f, { __index = function() return function() end end })
end

local function world(withDll)
    SAID, FILES, IMPORTED, FRAMES, NOW = {}, {}, nil, {}, 0
    SITE, REQUESTED, PENDING_LOOKS, STATE = {}, {}, 2, {}
    DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(SAID, m) end }
    SlashCmdList = {}
    CreateFrame = frame
    UIParent = frame()
    UISpecialFrames = {}
    GameTooltip = frame()
    GetTime = function() return NOW end
    GetNumRaidMembers = function() return 0 end
    GetNumPartyMembers = function() return 0 end
    GetRaidRosterInfo = function() return nil end
    UnitName = function() return "Tester" end
    UnitClass = function() return "Warrior", "WARRIOR" end
    WriteCustomFile = function(n, t) FILES[n] = t end
    ReadCustomFile = function(n) return FILES[n] end
    RollFor = { key_bindings = { import = function(d) IMPORTED = d end } }
    RaidResBridge, RaidResBridge_Raids, RaidResBridge_Limit = nil, nil, nil
    RaidResBridge_Data, RaidResBridge_Ref, RaidResBridge_Manual = nil, nil, nil
    RaidResBridge_Recent = nil

    if withDll then
        -- The DLL, as Lua sees it.
        local nextId = 0
        RaidResHttpGet = function(path)
            table.insert(REQUESTED, path)
            nextId = nextId + 1
            STATE[nextId] = { path = path, looks = 0 }
            return nextId
        end
        RaidResHttpResult = function(id)
            local s = STATE[id]
            if not s then return nil, "unknown request" end
            s.looks = s.looks + 1
            if s.looks <= PENDING_LOOKS then return "pending" end
            STATE[id] = nil
            local page = SITE[s.path]
            if page == nil then return "done", 404, "<html>not found</html>" end
            if page.failed then return "failed", page.failed end
            return "done", page.status or 200, page.body
        end
    else
        RaidResHttpGet, RaidResHttpResult = nil, nil
    end

    dofile(ROOT .. "RaidResBridge.lua")
    local before = table.getn(FRAMES)
    dofile(ROOT .. "Http.lua")
    RaidResBridge_Names = nil
    dofile(ROOT .. "Names.lua")
    DRIVER = FRAMES[before + 1]
    dofile(ROOT .. "Manual.lua")
    dofile(ROOT .. "Gui.lua")
    return RaidResBridge
end

-- Let time pass: every OnUpdate in the world, a tenth of a second at a time.
local function run(seconds)
    for _ = 1, math.floor(seconds * 10 + 0.5) do
        NOW = NOW + 0.1
        arg1 = 0.1
        for _, f in ipairs(FRAMES) do
            local fn = f.scripts.OnUpdate
            if fn and f.shown then fn() end
        end
    end
end

local function heard(text)
    for _, m in ipairs(SAID) do
        if string.find(m, text, 1, true) then return true end
    end
    return false
end

local function serve()
    SITE["/api/events/DEMO42"] = { status = 201, body = slurp("event_DEMO42.json") }
    SITE["/raids/raid_100.json"] = { body = slurp("raid_100.json") }
    SITE["/raids/raid_94.json"] = { body = slurp("raid_94.json") }
    SITE["/raids/raid_101.json"] = { body = slurp("raid_101.json") }
end

dofile(DIR .. "expected.lua")

-- ================================================================== JSON
print("json")
do
    local RB = world(true)
    local J = RB.Json
    checkSame("an object", J.decode('{"a":1,"b":"x","c":true,"d":false}'),
              { a = 1, b = "x", c = true, d = false })
    checkSame("nesting", J.decode(' { "a" : [ 1 , [2, {"b": []}] ] } '),
              { a = { 1, { 2, { b = {} } } } })
    check("numbers", J.decode("[-12.5e1]")[1], -125)
    check("escapes", J.decode('["a\\"b\\\\c\\/d\\n"]')[1], 'a"b\\c/d\n')
    check("\\u, two bytes", J.decode('["\\u00e9"]')[1], "\195\169")
    check("\\u, three bytes", J.decode('["\\u20ac"]')[1], "\226\130\172")
    check("a surrogate pair", J.decode('["\\ud83d\\ude00"]')[1], "\240\159\152\128")
    check("raw UTF-8 passes through", J.decode('["Zul\'Gurub \195\169"]')[1], "Zul'Gurub \195\169")
    local t = J.decode('[1,null,3]')
    check("null closes up in an array", table.getn(t), 2)
    check("null leaves an object", J.decode('{"a":null}').a, nil)
    for _, bad in ipairs({ "", "{", '{"a":}', "[1,]", '"open', "nope", "[1] x", '{"a" 1}' }) do
        check("refuses " .. string.format("%q", bad), (pcall(J.decode, bad)), false)
    end
end

-- ================================================================== conversion
print("conversion")
do
    local RB = world(true)
    local event = RB.Json.decode(slurp("event_DEMO42.json"))
    local raid = RB.Json.decode(slurp("raid_100.json"))
    local data, stats = RB.Convert("DEMO42", event, raid)
    checkSame("the list matches the watcher's", data, Expected_Data)
    checkSame("the counts match the watcher's", stats, Expected_Stats)

    for _, id in ipairs({ 94, 100, 101 }) do
        local r = RB.Json.decode(slurp("raid_" .. id .. ".json"))
        checkSame("loot table " .. id .. " matches the watcher's", RB.ConvertRaid(r), Expected_Raids[id])
    end

    -- Every id must be a plausible WoW item, not raidres's own numbering.
    local bad = 0
    for _, p in ipairs(data.softreserves) do
        for _, it in ipairs(p.items) do
            if type(it.id) ~= "number" or it.id < 1000 or it.id > 99999 then bad = bad + 1 end
        end
    end
    check("every item id looks like a WoW item", bad, 0)

    --[[ This list has every srPlus at 0 and every hard-reserve entry set,
         so the fixture alone cannot tell those fields being read from them
         being ignored. Change one of each and look. ]]
    local first = event.reservations[1]
    first.srPlus = 3
    local itemId = 0
    for _, it in ipairs(raid.raidItems) do
        if it.id == first.raidItemId then itemId = it.gameDbItemId end
    end
    local spare
    for _, it in ipairs(raid.raidItems) do
        if it.gameDbItemId ~= Expected_Data.hardreserves[1].id then spare = it end
    end
    table.insert(event.advancedHrItems, { raidItemId = spare.id, isHardReserved = false })
    local d3 = RB.Convert("DEMO42", event, raid)
    local plus
    for _, p in ipairs(d3.softreserves) do
        if p.name == first.character.name then
            for _, it in ipairs(p.items) do if it.id == itemId then plus = it.sr_plus end end
        end
    end
    check("srPlus is carried over", plus, 3)
    check("a hard-reserve entry that is not set is left out", table.getn(d3.hardreserves), 1)
    first.srPlus = 0
    table.remove(event.advancedHrItems)

    -- An item the loot table does not list is skipped, and counted.
    table.insert(event.reservations, { raidItemId = -1, character = { name = "Ghost" } })
    local _, s2 = RB.Convert("DEMO42", event, raid)
    check("an unknown item is skipped", s2.skipped, 1)
    check("and its owner is not invented", s2.players, Expected_Stats.players)

    -- What gets written down reads back as the same thing.
    local back = loadstring("return " .. RB.Literal(Expected_Data))()
    checkSame("the literal round-trips", back, Expected_Data)
    local odd = { s = "quote \" back \\ nl \n cr \r nul \0 end", [7] = 1.5, t = { true, false } }
    checkSame("awkward strings round-trip", loadstring("return " .. RB.Literal(odd))(), odd)
end

-- ================================================================== /rrb, with the DLL
print("/rrb with the DLL")
do
    local RB = world(true)
    serve()
    SlashCmdList.RAIDRESBRIDGE("https://raidres.top/res/DEMO42")
    check("asks for the event first", REQUESTED[1], "/api/events/DEMO42")
    check("no request file for the watcher", FILES["RaidResBridge_request.txt"], nil)
    run(1)
    check("then the raid it is for", REQUESTED[2], "/raids/raid_100.json")
    run(1)
    check("RollFor got a list", IMPORTED ~= nil, true)
    checkSame("RollFor got the watcher's list", IMPORTED, Expected_Data)
    check("chat says it imported", heard("imported"), true)
    check("chat mentions the lock", heard("locked"), true)
    check("the list was written down", FILES["RaidResBridge_data.lua"] ~= nil, true)

    -- Written down the way RB.Read reads it.
    RaidResBridge_Data, RaidResBridge_Ref = nil, nil
    RB.fetched = nil
    local data, err, ref = RB.Read()
    check("RB.Read finds it", err, nil)
    check("with its reference", ref, "DEMO42")
    checkSame("and the same list", data, Expected_Data)

    check("the raid's loot table is cached", RaidResBridge_Raids and RaidResBridge_Raids[100] ~= nil, true)
    checkSame("as the watcher would", RaidResBridge_Raids[100], Expected_Raids[100])
    check("and written down", FILES["RaidResBridge_raids.lua"] ~= nil, true)
    check("the list is remembered for the Recent menu", RaidResBridge_Recent and RaidResBridge_Recent[1].ref, "DEMO42")
    check("with its raid", RaidResBridge_Recent[1].place, Expected_Raids[100].name)
    check("the driver goes quiet", DRIVER.shown, false)
    check("and nothing is left in flight", RB.HttpBusy(), false)

    RaidResBridge_Raids = nil
    loadstring(FILES["RaidResBridge_raids.lua"])()
    checkSame("the raids file reads back", RaidResBridge_Raids[100], Expected_Raids[100])
end

do
    local RB = world(true)
    serve()
    SlashCmdList.RAIDRESBRIDGE("DEMO42")
    SlashCmdList.RAIDRESBRIDGE("DEMO42")
    check("a second /rrb while busy is turned away", heard("still fetching"), true)
    check("and asks nothing more", table.getn(REQUESTED), 1)
end

do
    -- Without the file API, the fetched list still reaches RollFor.
    local RB = world(true)
    serve()
    WriteCustomFile, ReadCustomFile = nil, nil
    SlashCmdList.RAIDRESBRIDGE("DEMO42")
    run(2)
    checkSame("no file API: RollFor still gets it", IMPORTED, Expected_Data)
end

-- ================================================================== failures
print("failures")
local function failing(setup, expect, label)
    local RB = world(true)
    serve()
    setup()
    SlashCmdList.RAIDRESBRIDGE("DEMO42")
    run(40)
    check(label .. ": nothing imported", IMPORTED, nil)
    check(label .. ": says " .. expect, heard(expect), true)
    if not heard(expect) then for _, m in ipairs(SAID) do print("      said: " .. m) end end
end

failing(function() SITE["/api/events/DEMO42"] = nil end, "raidres has no list DEMO42", "no such list")
failing(function() SITE["/api/events/DEMO42"] = { status = 503, body = "busy" } end,
        "raidres answered 503", "site down")
failing(function() SITE["/api/events/DEMO42"] = { failed = "the request failed (error 12007)" } end,
        "error 12007", "no network")
failing(function() SITE["/api/events/DEMO42"] = { body = "<html>cloudflare</html>" } end,
        "was not readable JSON", "not JSON")
failing(function() SITE["/raids/raid_100.json"] = nil end, "no the loot table", "no raid file")
failing(function() SITE["/api/events/DEMO42"] = { body = '{"reservations":[]}' } end,
        "does not say which raid", "no raidId")
failing(function() PENDING_LOOKS = 100000 end, "no answer after 30s", "never answers")
failing(function() RaidResHttpGet = function() return nil, "too many requests already running" end end,
        "too many requests", "DLL refuses")

do
    local RB = world(true)
    serve()
    SITE["/api/events/DEMO42"] = { body = '{"raidId":100,"reservations":[]}' }
    SlashCmdList.RAIDRESBRIDGE("DEMO42")
    run(2)
    check("an empty list says so", heard("nothing reserved"), true)
end

-- ================================================================== Get loot
print("get loot")
do
    local RB = world(true)
    serve()
    SITE["/raids/raid_101.json"].body = string.gsub(SITE["/raids/raid_101.json"].body,
        '"game":"TURTLE"', '"game":"CLASSIC"')
    RB.HttpRaids()
    check("four at a time", table.getn(REQUESTED), 4)
    run(30)
    check("sweeps the whole range", table.getn(REQUESTED), 35)
    check("keeps this game's raids", RaidResBridge_Raids[94] ~= nil and RaidResBridge_Raids[100] ~= nil, true)
    check("drops another game's", RaidResBridge_Raids[101], nil)
    check("says how many", heard("cached |cffffffff2|r"), true)
    check("writes them down", FILES["RaidResBridge_raids.lua"] ~= nil, true)
end

-- ================================================================== without the DLL
print("/rrb without the DLL")
do
    local RB = world(false)
    SlashCmdList.RAIDRESBRIDGE("DEMO42")
    check("falls back to the watcher", FILES["RaidResBridge_request.txt"], "DEMO42")
    check("says it is waiting for it", heard("waiting for the watcher"), true)
    SlashCmdList.RAIDRESBRIDGE("help")
    check("help mentions the DLL", heard("RaidResHttp.dll"), true)
end

-- ================================================================== /rrb debug
print("/rrb debug")
do
    local RB = world(true)
    serve()
    RaidResHttpStatus = function() return 1, 2, 3, 4.4 end
    PENDING_LOOKS = 100000
    SlashCmdList.RAIDRESBRIDGE("DEMO42")
    NOW = NOW + 7
    SAID = {}
    SlashCmdList.RAIDRESBRIDGE("debug")
    check("debug reports the DLL's threads", heard("1 talking, 2 waiting their turn, 3 not yet collected; oldest 4s"), true)
    check("and the addon's own waits", heard("waiting on 1 request(s); oldest 7s"), true)
    check("no alarm while all is well", heard("outlived its deadline"), false)
    RaidResHttpStatus = function() return 1, 0, 1, 90 end
    SAID = {}
    SlashCmdList.RAIDRESBRIDGE("debug")
    check("a request past its deadline is called out", heard("outlived its deadline"), true)
    RaidResHttpStatus = nil
    SAID = {}
    SlashCmdList.RAIDRESBRIDGE("debug")
    check("an older DLL is named as such", heard("older build"), true)
end
do
    local RB = world(false)
    SAID = {}
    SlashCmdList.RAIDRESBRIDGE("debug")
    check("and no DLL at all is said plainly", heard("isn't loaded"), true)
end

-- ================================================================== the lock
print("is it locked")
local function eventPage(change)
    return { status = 201, body = change(slurp("event_DEMO42.json")) }
end
do
    local RB = world(true)
    serve()
    SlashCmdList.RAIDRESBRIDGE("DEMO42")
    run(3)
    check("a fetch remembers whether raidres has the list locked", RB.LockState("DEMO42"), true)
    check("however it's asked for", RB.LockState("demo42"), true)
    check("and writes it down for next time",
        string.find(FILES["RaidResBridge_data.lua"], "RaidResBridge_Locked = true", 1, true) ~= nil, true)
    RaidResBridge_Locked, RB.lockInfo, RB.fetched = nil, nil, nil
    RB.Read()
    check("which reads back", RB.LockState("DEMO42"), true)

    -- it gets unlocked on the site; a refetch notices
    SITE["/api/events/DEMO42"] = eventPage(function(b) return (string.gsub(b, '"locked":true', '"locked":false')) end)
    SAID = {}
    SlashCmdList.RAIDRESBRIDGE("DEMO42")
    run(3)
    check("a refetch sees it unlocked", RB.LockState("DEMO42"), false)
    check("and says so", heard("unlocked on raidres"), true)
    check("writing that down too",
        string.find(FILES["RaidResBridge_data.lua"], "RaidResBridge_Locked = false", 1, true) ~= nil, true)

    -- an event that doesn't say
    SITE["/api/events/DEMO42"] = eventPage(function(b) return (string.gsub(b, '"locked":%a+,', "")) end)
    check("the page really lacks it", string.find(SITE["/api/events/DEMO42"].body, '"locked"', 1, true), nil)
    SlashCmdList.RAIDRESBRIDGE("DEMO42")
    run(3)
    check("is not assumed unlocked", string.find(FILES["RaidResBridge_data.lua"], "Locked", 1, true), nil)
    RaidResBridge_Locked, RB.lockInfo, RB.fetched = nil, nil, nil
    RB.Read()
    check("it reads back as unknown", RB.LockState("DEMO42"), nil)

    SITE["/api/events/DEMO42"] = eventPage(function(b) return (string.gsub(b, '"locked":true', '"locked":"yes"')) end)
    SlashCmdList.RAIDRESBRIDGE("DEMO42")
    run(3)
    check("nor is a lock that isn't true or false", string.find(FILES["RaidResBridge_data.lua"], "Locked", 1, true), nil)
end

print("looking again, quietly")
do
    local RB = world(true)
    serve()
    SlashCmdList.RAIDRESBRIDGE("DEMO42")
    run(3)
    check("locked to begin with", RB.LockState("DEMO42"), true)
    check("a manual list has nothing to look at", RB.HttpPollLock("manual"), false)
    check("nor does no list", RB.HttpPollLock(nil), false)

    SITE["/api/events/DEMO42"] = eventPage(function(b) return (string.gsub(b, '"locked":true', '"locked":false')) end)
    local before = table.getn(REQUESTED)
    check("it looks", RB.HttpPollLock("DEMO42"), true)
    check("at the event page", REQUESTED[before + 1], "/api/events/DEMO42")
    check("only one look at a time", RB.HttpPollLock("DEMO42"), false)
    check("the addon is waiting on it", (RB.HttpWaiting()), 1)
    check("but a look is not a fetch under way", RB.HttpBusy(), false)
    SAID = {}
    SlashCmdList.RAIDRESBRIDGE("DEMO42")
    check("so a /rrb in the meantime isn't turned away", heard("still fetching"), false)
    run(3)
    check("it sees the change", RB.LockState("DEMO42"), false)
    check("and says so", heard("unlocked on raidres"), true)
    local at = select(2, RB.LockState("DEMO42"))
    check("it's recorded as checked just now", at ~= nil and at > NOW - 4 and at <= NOW, true)

    SAID = {}
    RB.HttpPollLock("DEMO42")
    run(3)
    check("the same answer again says nothing", heard("raidres"), false)

    -- a reply that arrives after another list took over is dropped
    SITE["/api/events/DEMO42"] = { status = 201, body = slurp("event_DEMO42.json") }
    RB.HttpPollLock("DEMO42")
    RB.activeRef = "OTHER99"
    run(3)
    check("a late reply for a list that's no longer the active one is ignored", RB.LockState("DEMO42"), false)
    RB.activeRef = "DEMO42"

    -- it fails
    SITE["/api/events/DEMO42"] = nil
    RB.pollFailed = nil
    RB.HttpPollLock("DEMO42")
    run(3)
    check("a look that fails is counted", RB.pollFailed, 1)
    check("and leaves what was known", RB.LockState("DEMO42"), false)
    SITE["/api/events/DEMO42"] = eventPage(function(b) return (string.gsub(b, '"locked":true', '"locked":"yes"')) end)
    RB.HttpPollLock("DEMO42")
    run(3)
    check("an answer that isn't true or false is a failed look too", RB.pollFailed, 2)
    check("and changes nothing", RB.LockState("DEMO42"), false)
    SITE["/api/events/DEMO42"] = { status = 201, body = slurp("event_DEMO42.json") }
    RB.HttpPollLock("DEMO42")
    run(3)
    check("the next that works resets the count", RB.pollFailed, 0)
    check("and takes the new answer", RB.LockState("DEMO42"), true)

    check("with no window there is nothing to time the looks", RB.MaybePollLock(), false)
end
do
    local RB = world(false)
    check("without the DLL there is nothing to look with", RB.HttpPollLock("DEMO42"), false)
    check("or to time", RB.MaybePollLock(true), false)
end

print(string.format("\n%d check(s), %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
