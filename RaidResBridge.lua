--[[ RaidResBridge -- pull a raidres list into RollFor without leaving the game.

     RollFor can already take a soft-reserve list; what it cannot do is go and
     get one, because nothing in WoW 1.12 can. The Lua sandbox has no network
     access and Nampower adds none -- sixty-odd custom functions, not one of
     them HTTP. Today that means opening the website, exporting, copying a
     base64 blob and pasting it into RollFor's import window.

     What Nampower DOES add is CustomData, a folder the client can read and
     write. So this writes down which list it wants, a small watcher outside
     the game leaves the answer beside it, and this reads it back and hands it
     to RollFor. From inside the game it is one command.

     With RaidResHttp.dll loaded there is no watcher at all: the game fetches
     the list itself, through two functions the DLL adds that can only GET
     pages from raidres.top. See Http.lua.

     It hooks RollFor at RollFor.key_bindings.import, which takes the list as a
     plain table and does the encoding, importing, persisting and checking
     itself. That is the same entry point RollFor's own keybinding uses, so
     there is no second implementation of its format to drift out of step. ]]

RaidResBridge = {}
local RB = RaidResBridge

RB.REQUEST = "RaidResBridge_request.txt"
RB.REPLY   = "RaidResBridge_data.lua"
RB.POLL    = 2      -- seconds between looks while waiting for the watcher
RB.PATIENCE = 30    -- seconds before giving up on it

local function say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff8fd3ffRaidRes|r: " .. msg)
end

function RB.FileAPI()
    return WriteCustomFile ~= nil and ReadCustomFile ~= nil
end

--[[ Who is in your group: the raid, or your party and you.

     Here in the core rather than in Names.lua, because the window needs it
     even when Names.lua didn't load -- a /reload after an update that added
     the file keeps the old file list until the game restarts. ]]
function RB.Roster()
    local out = {}
    local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
    if raid > 0 then
        for i = 1, raid do
            local name, _, _, _, _, class = GetRaidRosterInfo(i)
            if name then table.insert(out, { name = name, class = class and string.upper(class) }) end
        end
    else
        local _, cls = UnitClass("player")
        local me = UnitName("player")
        if me then table.insert(out, { name = me, class = cls }) end
        local party = GetNumPartyMembers and GetNumPartyMembers() or 0
        for i = 1, party do
            local _, c = UnitClass("party" .. i)
            local n = UnitName("party" .. i)
            if n then table.insert(out, { name = n, class = c }) end
        end
    end
    return out
end

--- The event id out of a full link or a bare id.
function RB.Reference(text)
    if not text then return nil end
    text = string.gsub(text, "%s", "")
    if text == "" then return nil end
    --[[ Taken from the end rather than matched against a fixed host: the same
         list is served from more than one domain, and a reference is a
         reference wherever it came from. ]]
    local last, parts = text, 0
    for part in string.gfind(text, "[^/]+") do
        last = part
        parts = parts + 1
    end
    --[[ A link has a host and a path after its scheme. Without them the last
         segment is the scheme itself, and "https://" would otherwise come back
         as the reference "https" -- which the watcher would dutifully go and
         ask the site about. ]]
    if string.find(text, "//", 1, true) and parts < 3 then return nil end
    last = string.gsub(last, "[^%w]", "")
    if last == "" then return nil end
    return last
end

--[[ Ask the watcher for a list.

     The request is written even when one is already pending, because asking
     twice for the same list is how you refresh it after more people have
     signed up. ]]
function RB.Request(text)
    local ref = RB.Reference(text)
    if not ref then
        say("that does not look like a raidres link. " ..
            "|cffffffff/rrb https://raidres.top/res/XXXXXX|r")
        return
    end
    if RB.Http and RB.Http() then
        if RB.HttpBusy() then
            say("still fetching the last one; give it a moment.")
            return
        end
        RB.HttpRequest(ref)
        return
    end
    if not RB.FileAPI() then
        say("|cffff5179Nampower's file API is missing|r, so there is no way to " ..
            "reach the watcher. In OctoLauncher: Mods -> Nampower.")
        return
    end

    local ok = pcall(WriteCustomFile, RB.REQUEST, ref, "w")
    if not ok then
        say("|cffff5179could not write the request|r.")
        return
    end

    RB.waiting = ref
    RB.waited = 0
    say("asked for |cffffffff" .. ref .. "|r, waiting for the watcher...")
end

--[[ Read whatever the watcher left.

     loadstring rather than a parser of our own: the file is Lua because the
     watcher writes it that way, and running it is both simpler and exactly as
     trustworthy as everything else in CustomData, which is to say it is a
     file on your own disk that only your own tools write. ]]
function RB.Read()
    --[[ Fetched in game but not written down -- no file API, or the write
         failed. The file would hand back an older list, or none. ]]
    local mem = RB.fetched
    if mem and mem.unsaved then
        RB.activeRef = mem.ref
        return mem.data, nil, mem.ref
    end
    if not RB.FileAPI() then return nil, "Nampower's file API is missing" end
    local ok, text = pcall(ReadCustomFile, RB.REPLY)
    if not ok or type(text) ~= "string" or text == "" then
        return nil, "nothing has been fetched yet"
    end
    local chunk = loadstring(text)
    if not chunk then return nil, "the fetched file will not parse" end
    --[[ Cleared first: a file from an older watcher has no lock line, and
         the value left by the file before it would be read as this one's. ]]
    RaidResBridge_Locked = nil
    local ran = pcall(chunk)
    if not ran or type(RaidResBridge_Data) ~= "table" then
        return nil, "the fetched file held nothing usable"
    end
    RB.activeRef = RaidResBridge_Ref
    return RaidResBridge_Data, nil, RaidResBridge_Ref
end

-- ---------------------------------------------------------------------------
-- Is the list locked on raidres?
--
-- Read-only: raidres's public event page says so (`locked`), and that is all
-- this knows. It comes from the last fetch, from the file the watcher left, or
-- -- with the DLL -- from a look every half minute while the window is open.
-- ---------------------------------------------------------------------------

local function sameRef(a, b)
    return a and b and string.lower(a) == string.lower(b)
end

--[[ Record what raidres says. `locked` must be a real true/false: an event
     that doesn't say is "unknown", not "unlocked". A change from what was
     known for this same list is announced. ]]
function RB.SetLock(ref, locked)
    if type(locked) ~= "boolean" or not ref then return end
    local was
    local info = RB.lockInfo
    if info and sameRef(info.ref, ref) then
        was = info.locked
    elseif sameRef(RaidResBridge_Ref, ref) and type(RaidResBridge_Locked) == "boolean" then
        was = RaidResBridge_Locked
    end
    RB.lockInfo = { ref = ref, locked = locked, at = GetTime() }
    if was ~= nil and was ~= locked and RB.OnLockChanged then RB.OnLockChanged(locked) end
end

--[[ locked (true, false or nil for unknown), and when it was last checked
     (GetTime, or nil when it only comes from the file). ]]
function RB.LockState(ref)
    if not ref or ref == "" or ref == "manual" then return nil end
    local info = RB.lockInfo
    if info and sameRef(info.ref, ref) then return info.locked, info.at end
    if sameRef(RaidResBridge_Ref, ref) and type(RaidResBridge_Locked) == "boolean" then
        return RaidResBridge_Locked, nil
    end
    return nil
end

--[[ The cached loot tables, loaded on demand.

     A separate file because it is 150KB that changes when the server patches,
     not when somebody reserves something -- and loading it at startup would
     cost every character that time whether the window is ever opened or not. ]]
function RB.LoadRaids()
    if RaidResBridge_Raids then return true end
    if not RB.FileAPI() then return false end
    local ok, text = pcall(ReadCustomFile, "RaidResBridge_raids.lua")
    if not ok or type(text) ~= "string" or text == "" then return false end
    local chunk = loadstring(text)
    if not chunk then return false end
    pcall(chunk)
    return RaidResBridge_Raids ~= nil
end

function RB.Describe(data)
    local players, items = 0, 0
    for _, p in ipairs(data.softreserves or {}) do
        players = players + 1
        items = items + table.getn(p.items or {})
    end
    return players, items, table.getn(data.hardreserves or {})
end

--[[ Hand it to RollFor.

     RollFor.key_bindings.import is the same entry its own keybinding uses: it
     takes the plain table, encodes it, imports it, persists it and refreshes
     the window. Going through that rather than reproducing any of it is what
     keeps this working when RollFor changes how it stores things. ]]
function RB.Load(quiet)
    local data, err, ref = RB.Read()
    if not data then
        if not quiet then
            say("|cffff5179" .. (err or "nothing to load") .. "|r. Start the " ..
                "watcher and run |cffffffff/rrb <link>|r.")
        end
        return false
    end

    local rf = RollFor and RollFor.key_bindings
    if not rf or type(rf.import) ~= "function" then
        say("|cffff5179RollFor is not loaded|r, so there is nothing to import " ..
            "into. The list was fetched and is waiting.")
        return false
    end

    local players, items, hard = RB.Describe(data)
    if players == 0 then
        say("that list has nobody on it yet.")
        return false
    end

    local ok, e = pcall(rf.import, data)
    if not ok then
        say("|cffff5179RollFor refused it|r: " .. tostring(e))
        return false
    end

    RB.loaded = ref
    say("imported |cffffffff" .. players .. "|r player(s), " .. items ..
        " reservation(s)" .. (hard > 0 and (", " .. hard .. " hard-reserved") or "") ..
        (ref and (" |cff888888(" .. ref .. ")|r") or "") .. ".")
    return true
end

-- ---------------------------------------------------------------------------
--[[ Waiting for the watcher.

     Polled rather than event-driven because a file changing is not an event
     the client can be told about. It stops on its own after half a minute so
     a watcher that was never started does not leave this looking forever. ]]
local poll = CreateFrame("Frame")
poll:SetScript("OnUpdate", function()
    if not RB.waiting then return end
    RB.waited = (RB.waited or 0) + arg1
    if RB.waited < RB.POLL then return end
    RB.waited = 0
    RB.elapsed = (RB.elapsed or 0) + RB.POLL

    local data, _, ref = RB.Read()
    if data and ref == RB.waiting then
        RB.waiting = nil
        RB.elapsed = 0
        if RB.Apply then RB.Apply() else RB.Load() end
        if RB.gui and RB.gui:IsVisible() then RB.Refresh() end
        return
    end

    if RB.elapsed >= RB.PATIENCE then
        local want = RB.waiting
        RB.waiting = nil
        RB.elapsed = 0
        say("|cffffcc00no answer for " .. want .. "|r after " .. RB.PATIENCE ..
            "s. Is the watcher running? |cffffffffpython raidres_bridge.py watch|r")
    end
end)

-- ---------------------------------------------------------------------------
SLASH_RAIDRESBRIDGE1 = "/rrb"
SLASH_RAIDRESBRIDGE2 = "/raidres"
SlashCmdList["RAIDRESBRIDGE"] = function(msg)
    msg = msg or ""
    local _, _, cmd = string.find(msg, "^%s*(%S*)")
    cmd = string.lower(cmd or "")

    --[[ The window is the front door: /rrb on its own opens it, and the
         chat-only forms are for macros and for anyone who prefers typing. ]]
    if cmd == "" or cmd == "gui" or cmd == "show" or cmd == "list" then
        RB.ToggleGui()
        return
    end

    --[[ What the DLL is doing right now. The first thing to look at when
         the game feels slow with RaidResHttp.dll loaded: a request should
         never be talking for longer than its 30-second deadline. ]]
    if cmd == "debug" then
        if RaidResHttpStatus then
            local talking, queued, uncollected, oldest = RaidResHttpStatus()
            say(string.format("RaidResHttp.dll: %d talking, %d waiting their turn, " ..
                "%d not yet collected; oldest %.0fs.", talking, queued, uncollected, oldest))
            if oldest > 45 then
                say("|cffff5179a request has outlived its deadline|r -- please report this.")
            end
        elseif RaidResHttpGet then
            say("RaidResHttp.dll is an older build without RaidResHttpStatus; update it.")
        else
            say("RaidResHttp.dll isn't loaded.")
        end
        if RB.HttpWaiting then
            local n, age = RB.HttpWaiting()
            say(string.format("The addon is waiting on %d request(s); oldest %.0fs.", n, age))
        end
        return
    end

    if cmd == "help" or cmd == "?" then
        say("|cffffffff/rrb|r opens the window: fetch a list, see who still " ..
            "needs reserves, and add them by hand.")
        say("|cffffffff/rrb <raidres link>|r fetches a list and imports it.")
        say("|cffffffff/rrb load|r imports what was fetched, plus anything typed.")
        say("|cffffffff/rrb lockcontrol|r toggle locking and unlocking from in game (needs the helper script).")
        say("|cffffffff/rrb restart|r restart the helper script's Chrome (if it gets stuck).")
        if RB.Http and RB.Http() then
            say("|cff888888Fetching in game (RaidResHttp.dll is loaded).|r")
        else
            say("|cff888888Needs RaidResHttp.dll, or the watcher running outside " ..
                "the game: |cffffffffpython raidres_bridge.py watch|r")
        end
        if RB.loaded then
            say("|cff888888last imported: " .. RB.loaded .. "|r")
        end
        return
    end

    if cmd == "lockcontrol" then
        local _, _, arg = string.find(msg, "lockcontrol%s+(%S+)")
        if arg == "on" or arg == "1" then
            RaidResBridge_LockControl = true
            say("Lock control |cff00ff00enabled|r. The lock button will lock and unlock via the helper script.")
        elseif arg == "off" or arg == "0" then
            RaidResBridge_LockControl = false
            say("Lock control |cffff5179disabled|r. The lock button only checks the state.")
        else
            local state = RaidResBridge_LockControl and "|cff00ff00on|r" or "|cffff5179off|r"
            say("Lock control is " .. state .. ". |cffffffff/rrb lockcontrol on|r or |cffffffffoff|r.")
        end
        if RB.DrawStatus then RB.DrawStatus() end
        return
    end

    if cmd == "restart" then
        if not RB.FileAPI() then
            say("can't reach the helper script (no file API).")
            return
        end
        pcall(WriteCustomFile, "RaidResBridge_lock_result.txt", "", "w")
        local ok = pcall(WriteCustomFile, "RaidResBridge_lock_cmd.txt", "restart", "w")
        if ok then
            RB.sessionExpired = nil
            say("restart sent to the helper script.")
        else
            say("could not write the restart command.")
        end
        if RB.DrawStatus then RB.DrawStatus() end
        return
    end

    if cmd == "load" then
        --[[ Through the merge, so a reload does not quietly drop the lines
             somebody typed in for the people who could not sign up. ]]
        if RB.Apply then RB.Apply() else RB.Load() end
        return
    end

    RB.Request(msg)
end
