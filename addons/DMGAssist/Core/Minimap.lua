-- Minimap.lua: the minimap button and the Midnight addon compartment entry.
--
--   Left-click   open the settings
--   Right-click  show / hide the HUD
--   Shift-click  open the Watchdog report (when DMGAssist_Watchdog is installed)
--   Drag         move it around the minimap (the angle is saved in DMGAssistDB.minimapAngle)
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

-- One handler for the minimap button and the compartment.
local function OnClick(mouse)
  if IsShiftKeyDown() then
    OpenWatchdogReport()
  elseif mouse == "RightButton" then
    DMGAssist_Toggle()
  else
    ns.Options.Open()
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

  button:SetScript("OnClick", function(_, mouse)
    OnClick(mouse)
  end)
  button:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", FollowCursor)
  end)
  button:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
  end)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("DMGAssist")
    GameTooltip:AddLine(L["Left-click: settings"], 1, 1, 1)
    GameTooltip:AddLine(L["Right-click: show / hide"], 1, 1, 1)
    GameTooltip:AddLine(L["Shift-click: Watchdog report"], 1, 1, 1)
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
  OnClick(mouse)
end
