--[[ The minimap button: the window one click away, and the night at a
     glance -- whose reserves are missing, whether the list is locked, and
     whether RollFor has it -- without opening anything.

     Left-click opens the window, right-click opens the options, and a drag
     moves it round the minimap's edge: a circle, or pfUI's square. It is
     made of the parts the client's own tracking button is made of; in
     pfUI's look it is pfUI's flat square instead. Where it sits and whether
     it shows are kept in RaidResBridge_Options.minimap.

     A named child of Minimap, so pfUI's minimap-button bar can gather it
     like any other. Once gathered it stays wherever pfUI puts it. ]]

local RB = RaidResBridge

local NAME = "ZyllaRaidResMinimapButton"
local ICON = "Interface\\Icons\\INV_Scroll_03"
local BORDER = "Interface\\Minimap\\MiniMap-TrackingBorder"
local GLOW = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight"
local ANGLE = 200       -- degrees anticlockwise from the right, where it starts

local function say(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff8fd3ffRaidRes|r: " .. msg)
end

local function rgb(h)
    return tonumber(string.sub(h, 1, 2), 16) / 255,
           tonumber(string.sub(h, 3, 4), 16) / 255,
           tonumber(string.sub(h, 5, 6), 16) / 255
end

local function settings()
    RaidResBridge_Options = RaidResBridge_Options or {}
    RaidResBridge_Options.minimap = RaidResBridge_Options.minimap or {}
    return RaidResBridge_Options.minimap
end

-- pfUI's minimap is square; so is any other that says so the usual way.
local function squareMinimap()
    if GetMinimapShape then return GetMinimapShape() == "SQUARE" end
    return pfUI and pfUI.minimap and true or false
end

-- Still on the minimap, and so free to move: not gathered into pfUI's bar.
local function onMinimap(b) return b:GetParent() == Minimap end

function RB.PlaceMinimapButton()
    local b = RB.minimapButton
    if not b or not onMinimap(b) then return end
    local a = math.rad(settings().angle or ANGLE)
    local r = (Minimap:GetWidth() or 140) / 2
    local x, y
    if squareMinimap() then
        -- Out along the same line, then held to the square's edge.
        local edge = r + 5
        local reach = math.sqrt(2 * edge * edge) - 10
        x = math.max(-edge, math.min(math.cos(a) * reach, edge))
        y = math.max(-edge, math.min(math.sin(a) * reach, edge))
    else
        x, y = math.cos(a) * (r + 10), math.sin(a) * (r + 10)
    end
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- While dragging: wherever the cursor is, round the centre.
local function follow()
    local mx, my = Minimap:GetCenter()
    if not mx then return end
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale() or 1
    settings().angle = math.deg(math.atan2(py / scale - my, px / scale - mx))
    RB.PlaceMinimapButton()
end

-- ---------------------------------------------------------------------------
-- What it says
-- ---------------------------------------------------------------------------

local function line(left, right, colour)
    local r, g, b = rgb(colour or "ffffff")
    GameTooltip:AddDoubleLine(left, right, 1, 0.82, 0, r, g, b)
end

function RB.MinimapTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    local version = GetAddOnMetadata and GetAddOnMetadata("ZyllaRaidRes", "Version")
    GameTooltip:AddDoubleLine("Zylla RaidRes", version or "", 1, 0.82, 0, 0.5, 0.5, 0.5)

    local ok, s = pcall(RB.Snapshot)
    if ok and s then
        local fetched = s.ref and s.ref ~= "manual"
        if fetched then
            line("List", s.ref .. "  " .. RB.ListPlace(s))
        elseif s.typedCount > 0 then
            line("List", "Typed by hand")
        else
            line("List", "None yet", "808080")
        end
        local done, total = RB.Progress(s)
        if total > 0 then
            line("Players", done .. " of " .. total .. " done", done == total and "20ff20" or "ffd200")
        end
        if fetched then
            local lock = RB.LockLabel(s)
            if lock == "locked" then line("Raidres", "Locked", "20ff20")
            elseif lock == "unlocked" then line("Raidres", "Unlocked", "ffd200")
            else line("Raidres", "Not known", "808080") end
        end
        local _, _, word, colour = RB.RollForText(s)
        line("RollFor", word, colour)
    end

    GameTooltip:AddLine(" ")
    local open = RB.gui and RB.gui:IsVisible()
    GameTooltip:AddDoubleLine("Click", open and "Close the window" or "Open the window",
        0.5, 0.5, 0.5, 1, 1, 1)
    GameTooltip:AddDoubleLine("Right-click", "Options", 0.5, 0.5, 0.5, 1, 1, 1)
    if onMinimap(owner) then
        GameTooltip:AddDoubleLine("Drag", "Move this button", 0.5, 0.5, 0.5, 1, 1, 1)
    end
    GameTooltip:Show()
end

-- ---------------------------------------------------------------------------
-- The options menu
-- ---------------------------------------------------------------------------

local function onPick()
    local v = this.value
    if CloseDropDownMenus then CloseDropDownMenus() end
    if v == "window" then
        RB.ToggleGui()
    elseif v == "send" then
        RB.Apply()
    elseif v == "view" then
        RB.ViewInRollFor()
    elseif v == "hide" then
        RB.ShowMinimapButton(false)
    elseif v == "auto" or v == "blizzard" or v == "pfui" then
        RB.SetSkin(v)
    end
end

--[[ Built each time it opens. One shared func reads this.value, the way the
     window's own menus do, rather than capturing anything. ]]
function RB.InitMinimapMenu()
    local function add(text, value, checked, disabled)
        local info = {}
        info.text = text
        if value then
            info.value = value
            info.func = onPick
            info.checked = checked and 1 or nil
            info.disabled = disabled and 1 or nil
        else
            info.isTitle = 1
        end
        UIDropDownMenu_AddButton(info)
    end
    local rf = RollFor and RollFor.key_bindings
    add("Zylla RaidRes")
    add((RB.gui and RB.gui:IsVisible()) and "Close the window" or "Open the window", "window")
    add("Send to RollFor", "send", false, not RB.RollForReady())
    add("View in RollFor", "view", false, not (rf and type(rf.softres_toggle) == "function"))
    add("Look")
    local want = (RaidResBridge_Options and RaidResBridge_Options.skin) or "auto"
    add("Automatic", "auto", want == "auto")
    add("Blizzard", "blizzard", want == "blizzard")
    add("pfUI", "pfui", want == "pfui", not RB.HasPfUI())
    add("Minimap")
    add("Hide this button", "hide")
end

-- ---------------------------------------------------------------------------
-- Building it
-- ---------------------------------------------------------------------------

-- Pressed, the icon sinks a little, as the client's own buttons do.
local function press(b, down)
    local c = b.coords
    local d = down and 0.04 or 0
    b.icon:SetTexCoord(c[1] + d, c[2] - d, c[3] + d, c[4] - d)
end

-- The tracking button's own parts and measurements.
local function skinBlizzard(b)
    b:SetWidth(32)
    b:SetHeight(32)
    b.icon:SetWidth(20)
    b.icon:SetHeight(20)
    b.icon:SetPoint("TOPLEFT", b, "TOPLEFT", 6, -6)
    b.coords = { 0.075, 0.925, 0.075, 0.925 }
    press(b, false)
    b.border = b:CreateTexture(nil, "OVERLAY")
    b.border:SetTexture(BORDER)
    b.border:SetWidth(52)
    b.border:SetHeight(52)
    b.border:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
    b:SetHighlightTexture(GLOW)
end

--[[ pfUI's look: a flat square with pfUI's border, the icon cropped the way
     pfUI crops every icon. Any trouble puts the tracking-button look back. ]]
local function skinPfUI(b)
    local api = pfUI.api
    local ok = pcall(function()
        b.border:Hide()
        b:SetHighlightTexture("")
        b:SetWidth(24)
        b:SetHeight(24)
        api.CreateBackdrop(b)
        b.icon:ClearAllPoints()
        b.icon:SetPoint("TOPLEFT", b, "TOPLEFT", 3, -3)
        b.icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -3, 3)
        b.coords = { 0.08, 0.92, 0.08, 0.92 }
        press(b, false)
    end)
    if not ok then
        if b.backdrop and b.backdrop.Hide then b.backdrop:Hide() end
        b:SetWidth(32)
        b:SetHeight(32)
        b.icon:ClearAllPoints()
        b.icon:SetWidth(20)
        b.icon:SetHeight(20)
        b.icon:SetPoint("TOPLEFT", b, "TOPLEFT", 6, -6)
        b.coords = { 0.075, 0.925, 0.075, 0.925 }
        press(b, false)
        b.border:Show()
        b:SetHighlightTexture(GLOW)
    end
    return ok
end

local function build()
    local b = CreateFrame("Button", NAME, Minimap)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b.icon = b:CreateTexture(nil, "BACKGROUND")
    b.icon:SetTexture(ICON)
    skinBlizzard(b)
    b.skin = "blizzard"
    if RB.SkinName() == "pfui" and skinPfUI(b) then b.skin = "pfui" end
    RB.builtSkin = RB.builtSkin or b.skin

    b.menu = CreateFrame("Frame", NAME .. "Menu", b, "UIDropDownMenuTemplate")
    UIDropDownMenu_Initialize(b.menu, RB.InitMinimapMenu, "MENU")

    b:SetScript("OnClick", function()
        GameTooltip:Hide()
        if arg1 == "RightButton" then
            ToggleDropDownMenu(1, nil, this.menu, "cursor")
        else
            if CloseDropDownMenus then CloseDropDownMenus() end
            RB.ToggleGui()
        end
    end)
    b:SetScript("OnMouseDown", function() press(this, true) end)
    b:SetScript("OnMouseUp", function() press(this, false) end)
    b:SetScript("OnEnter", function()
        if not this.dragging then RB.MinimapTooltip(this) end
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnDragStart", function()
        if not onMinimap(this) then return end
        this.dragging = true
        this:LockHighlight()
        GameTooltip:Hide()
        this:SetScript("OnUpdate", follow)
    end)
    b:SetScript("OnDragStop", function()
        this:SetScript("OnUpdate", nil)
        this.dragging = nil
        this:UnlockHighlight()
        press(this, false)
    end)
    return b
end

function RB.ShowMinimapButton(show)
    settings().hide = (not show) and true or nil
    local b = RB.minimapButton
    if b then
        if show then b:Show() else b:Hide() end
    end
    if not show then say("minimap button hidden. |cffffffff/rrb minimap|r brings it back.") end
end

function RB.ToggleMinimapButton()
    RB.ShowMinimapButton(settings().hide and true or false)
end

--- Made once the saved settings are in; placed, and shown unless hidden.
function RB.SetupMinimap()
    if not Minimap then return nil end
    if not RB.minimapButton then RB.minimapButton = build() end
    RB.PlaceMinimapButton()
    if settings().hide then RB.minimapButton:Hide() else RB.minimapButton:Show() end
    return RB.minimapButton
end

-- PLAYER_LOGIN: the saved settings are loaded and pfUI has built its minimap.
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function() RB.SetupMinimap() end)
