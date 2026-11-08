-- Minimap.lua: the minimap button and the Midnight addon compartment entry.
--
--   Left-click   show / hide the recommendations
--   Left-drag    move the button around the minimap (the angle is saved in DMGAssistDB.minimapAngle)
--   Right-click  menu: Settings, Watchdog report, quick toggles (shown, out of combat, cooldowns, lock,
--                sounds), target mode, hide this button
-- The menu is Blizzard_Menu's MenuUtil.CreateContextMenu with buttons, checkboxes and radios (present on live
-- 12.1.5 and forever 1.60.1). Its actions are the slash commands' (ns.commands), so both behave the same.
--
-- Options > DMGAssist > "Minimap button" (DMGAssistDB.minimap) shows or hides it. The compartment entry comes
-- from the TOC (AddonCompartmentFunc = DMGAssist_OnCompartmentClick); Blizzard_Minimap's AddonCompartment.lua
-- calls it with (addonName, mouseButton) on both clients.
-- Plain frames on Minimap only: nothing protected, nothing hooked.

local _, ns = ...
local U, L = ns.U, ns.L

local MM = {}
ns.Minimap = MM

local ICON = "Interface\\Icons\\Spell_Holy_FistOfJustice"
local button

local function OpenWatchdogReport()
  local wd = _G.DMGAssistWatchdog
  if type(wd) == "table" and type(wd.OpenReport) == "function" then
    wd.OpenReport()
    return true
  end
  U.Print("%s", L["The Watchdog addon is not installed."])
  return false
end

local function Run(command, arg)
  ns.commands[command](arg)
  ns.Update()
end

-- Checkbox helpers: a getter and a flip for a DMGAssistDB flag that defaults to on.
local function DbFlag(key)
  return function()
    return ns.db[key] ~= false
  end
end

-- Target mode as one choice: auto-detect, or a fixed single target / AoE.
local function ModeIs(mode)
  if mode == "auto" then
    return ns.db.autoDetect ~= false
  end
  return ns.db.autoDetect == false and ns.db.mode == mode
end

local function SetMode(mode)
  if mode == "auto" then
    Run("auto", "on")
  else
    ns.db.autoDetect = false
    Run("mode", mode)
  end
end

function MM.FillMenu(_, root)
  root:CreateTitle("DMGAssist")
  root:CreateButton(L["Settings"], function()
    ns.Options.Open()
  end)
  if type(_G.DMGAssistWatchdog) == "table" then
    root:CreateButton(L["Watchdog report"], OpenWatchdogReport)
  end
  root:CreateDivider()
  root:CreateCheckbox(L["Show recommendations"], DbFlag("enabled"), function()
    DMGAssist_Toggle()
  end)
  root:CreateCheckbox(L["Show out of combat"], function()
    return not ns.Display.Settings().hideOutOfCombat
  end, function()
    local cfg = ns.Display.Settings()
    cfg.hideOutOfCombat = not cfg.hideOutOfCombat
    ns.Update()
  end)
  root:CreateCheckbox(L["Major cooldowns"], DbFlag("burst"), function()
    Run("burst")
  end)
  root:CreateCheckbox(L["Lock position"], DbFlag("locked"), function()
    Run("lock")
  end)
  root:CreateCheckbox(L["Sound alerts"], DbFlag("sounds"), function()
    ns.db.sounds = ns.db.sounds == false
  end)
  root:CreateDivider()
  root:CreateTitle(L["Target mode"])
  for _, m in ipairs({ { "auto", "Auto-detect" }, { "st", "Single target" }, { "aoe", "AoE" } }) do
    root:CreateRadio(L[m[2]], function()
      return ModeIs(m[1])
    end, function()
      SetMode(m[1])
    end)
  end
  root:CreateDivider()
  root:CreateButton(L["Hide minimap button"], function()
    ns.db.minimap = false
    MM.Apply()
    U.Print("%s", L["Minimap button hidden. Turn it back on in Settings (/dmga config)."])
  end)
end

local function OpenMenu(owner)
  if MenuUtil and MenuUtil.CreateContextMenu then
    MenuUtil.CreateContextMenu(owner, MM.FillMenu)
  else
    ns.Options.Open() -- no menu system on this client: the settings have everything the menu has
  end
end

-- One handler for the minimap button and the compartment.
local function OnClick(mouse, owner)
  if mouse == "RightButton" then
    OpenMenu(owner)
  else
    DMGAssist_Toggle()
  end
end

local function Place()
  local angle = math.rad(tonumber(ns.db and ns.db.minimapAngle) or 220)
  local radius = (Minimap:GetWidth() / 2) + 5
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function FollowCursor()
  local mx, my = Minimap:GetCenter()
  local scale = Minimap:GetEffectiveScale()
  local cx, cy = GetCursorPosition()
  local angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
  ns.db.minimapAngle = math.floor(angle + 0.5) % 360
  Place()
end

local function Create()
  button = CreateFrame("Button", "DMGAssistMinimapButton", Minimap)
  button:SetSize(31, 31)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(8)
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:RegisterForDrag("LeftButton")
  button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local bg = button:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetSize(20, 20)
  bg:SetPoint("TOPLEFT", 7, -5)
  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetTexture(ICON)
  icon:SetSize(17, 17)
  icon:SetPoint("TOPLEFT", 7, -6)
  icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
  local border = button:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")

  button:SetScript("OnClick", function(self, mouse)
    if self.dragged then
      self.dragged = nil -- the mouse-up that ends a drag is not a click
      return
    end
    OnClick(mouse, self)
  end)
  button:SetScript("OnDragStart", function(self)
    self.dragged = true
    self:SetScript("OnUpdate", FollowCursor)
  end)
  button:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
  end)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("DMGAssist")
    GameTooltip:AddLine(L["Left-click: show / hide"], 1, 1, 1)
    GameTooltip:AddLine(L["Right-click: menu and settings"], 1, 1, 1)
    GameTooltip:AddLine(L["Drag: move this button"], 1, 1, 1)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)
end

-- Show or hide per the setting. Safe to call any time after the database exists.
function MM.Apply()
  if type(Minimap) ~= "table" then
    return
  end
  local show = not (ns.db and ns.db.minimap == false)
  if show and not button then
    Create()
  end
  if button then
    Place()
    button:SetShown(show)
  end
end

-- Midnight's addon compartment (the button under the minimap); named in the TOC.
function DMGAssist_OnCompartmentClick(_, mouse)
  OnClick(mouse, button)
end
