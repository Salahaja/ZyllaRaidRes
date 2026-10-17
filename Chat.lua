--[[ raidres links in raid chat, made clickable.

     The raid leader posts the list in raid chat; clicking it should make it
     the active list, with no copying into the window. 1.12 chat has no
     clickable URLs, so a raidres link in a raid message is turned into a
     [Raidres XXXXXX] link of our own, and clicking that fetches the list.

     Raid chat only -- raid, raid leader and raid warning. Guild, world,
     whispers and every channel are left exactly as they were. The click side
     holds to the same rule: only a link this window saw in raid chat this
     session does anything, so the same text turning up anywhere else is
     ignored.

     The rewrite happens in ChatFrame_OnEvent, before the message reaches any
     chat frame's AddMessage. That is where ShaguTweaks and pfUI turn URLs
     into their own copy-the-URL links; by then this one is already a
     raidres link, so the two never fight over it. arg1 is put back after
     each frame has drawn the message, so nothing else reading the event sees
     a changed message. ]]

local RB = RaidResBridge

RB.raidLinks = RB.raidLinks or {}   -- ref -> who posted it, raid chat only

local RAID_EVENTS = {
    CHAT_MSG_RAID = true,
    CHAT_MSG_RAID_LEADER = true,
    CHAT_MSG_RAID_WARNING = true,
}

local function say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff8fd3ffRaidRes|r: " .. msg)
end

--[[ One raid message with its raidres links made clickable.

     Word by word, so text around a link is untouched. A word that is already
     a hyperlink is left alone, which also makes this safe to run twice on the
     same message: the link it makes has no URL left in it to match. ]]
function RB.LinkifyRaid(msg, sender)
    if type(msg) ~= "string" or not string.find(msg, "raidres", 1, true) then
        return msg
    end
    return (string.gsub(msg, "(%S+)", function(word)
        if string.find(word, "|H", 1, true) then return nil end
        local _, e, ref = string.find(word, "raidres[%w%.%-]*%.%a+/res/(%w+)")
        ref = ref and RB.Reference(ref)
        if not ref then return nil end
        RB.raidLinks[ref] = sender or "someone"
        return "|cff8fd3ff|Hraidres:" .. ref .. "|h[Raidres " .. ref .. "]|h|r" ..
            string.sub(word, e + 1)
    end))
end

function RB.ShowGui()
    local f = RB.BuildGui()
    if not f:IsVisible() then
        RB.LoadRaids()
        f:Show()
    end
    return f
end

--- Make this list the active one: open the window on it and fetch it.
function RB.UseList(ref)
    local f = RB.ShowGui()
    f.link:SetText("https://raidres.top/res/" .. ref)
    RB.Request(ref)
    if RB.DrawStatus then RB.DrawStatus() end
end

local function currentList()
    local _, _, ref = RB.Read()
    return RB.loaded or ref
end

--[[ A click on a [Raidres XXXXXX] link.

     The same list again just refreshes it. A different one replaces the
     active list, so that asks first and says who posted it -- a stray click
     in raid chat should not swap the list out from under the raid. Reserves
     typed in the window are kept either way. ]]
function RB.ClickRaidLink(ref)
    ref = RB.Reference(ref)
    if not ref then return end

    if IsShiftKeyDown and IsShiftKeyDown() then
        if ChatFrameEditBox and ChatFrameEditBox:IsVisible() then
            ChatFrameEditBox:Insert("https://raidres.top/res/" .. ref)
        end
        return
    end

    local who = RB.raidLinks[ref]
    if not who then
        say("that raidres link didn't come from raid chat, so it's ignored.")
        return
    end

    local current = currentList()
    if not current or current == "manual" or current == ref then
        RB.UseList(ref)
        return
    end

    RB.pendingList = ref
    if StaticPopupDialogs then
        StaticPopupDialogs.ZYLLARAIDRES_SWITCH = {
            text = "Use " .. who .. "'s raidres list " .. ref .. "?\n" ..
                "It replaces " .. current .. ". Reserves you typed stay.",
            button1 = YES or "Yes",
            button2 = NO or "No",
            OnAccept = function()
                local pick = RB.pendingList
                RB.pendingList = nil
                if pick then RB.UseList(pick) end
            end,
            OnCancel = function() RB.pendingList = nil end,
            timeout = 0, whileDead = 1, hideOnEscape = 1,
        }
        StaticPopup_Show("ZYLLARAIDRES_SWITCH")
    end
end

local function hookChat()
    if RB.chatHooked or type(ChatFrame_OnEvent) ~= "function" then return end
    local original = ChatFrame_OnEvent
    ChatFrame_OnEvent = function(evt)
        if RAID_EVENTS[evt] and arg1 then
            local saved = arg1
            arg1 = RB.LinkifyRaid(arg1, arg2)
            original(evt)
            arg1 = saved
            return
        end
        return original(evt)
    end
    RB.chatHooked = true
end

local function hookLinks()
    if RB.linkHooked or type(SetItemRef) ~= "function" then return end
    local original = SetItemRef
    SetItemRef = function(link, text, button)
        if type(link) == "string" and string.sub(link, 1, 8) == "raidres:" then
            RB.ClickRaidLink(string.sub(link, 9))
            return
        end
        return original(link, text, button)
    end
    RB.linkHooked = true
end

hookChat()
hookLinks()
