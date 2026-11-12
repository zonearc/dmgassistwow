-- Minimap.lua: the minimap button and the Midnight addon compartment entry.
--
--   Left-click   show / hide the recommendations
--   Left-drag    move the button around the minimap (the angle is saved in DMGAssistDB.minimapAngle)
--   Right-click  menu: Settings, Watchdog report, quick toggles (shown, out of combat, cooldowns, lock,
--                sounds), target mode, hide this button
-- The menu is our own small frame (MM.ContextMenu), not Blizzard_Menu: the shared menu system ran Edit Mode's layout
-- dropdown "tainted by DMGAssist" afterwards, and Edit Mode then blocked in combat on every bar and unit frame
-- (taint.log, 2026-11-11 15:52). Same builder calls as MenuUtil (CreateTitle / CreateButton / CreateCheckbox /
-- CreateRadio / CreateDivider). Its actions are the slash commands' (ns.commands), so both behave the same.
--
-- Options > DMGAssist > "Minimap button" (DMGAssistDB.minimap) shows or hides it. The compartment entry comes
-- from the TOC (AddonCompartmentFunc = DMGAssist_OnCompartmentClick); Blizzard_Minimap's AddonCompartment.lua
-- calls it with (addonName, mouseButton) on both clients.
-- Plain frames on Minimap only: nothing protected, nothing hooked.

local _, ns = ...
local U, L = ns.U, ns.L

local MM = {}
ns.Minimap = MM

local ICON = "Interface\\AddOns\\DMGAssist\\Media\\DMGAssist" -- our own "D" (tools/make_icon.py)
local button

local function OpenWatchdogReport()
  local wd = _G.DMGAssistWatchdog
  if type(wd) == "table" and type(wd.OpenReport) == "function" then
    wd.OpenReport()
    return true
  end
  U.Print("%s", L["The DMGAssist_Watchdog addon (Report an issue) is not installed."])
  return false
end

ns.OpenReport = OpenWatchdogReport

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
    root:CreateButton(L["Report an issue"], OpenWatchdogReport)
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
  local spec = ns.Specs.current and (ns.Specs.current.specName or ns.Specs.current.key) or "?"
  root:CreateCheckbox(string.format(L["Use DMGAssist on %s"], tostring(spec)), function()
    return not ns.Choices.SpecOff()
  end, function()
    Run("spec")
  end)
  root:CreateCheckbox(L["Flow mode"], function()
    return ns.Game.On()
  end, function()
    ns.Game.Toggle()
  end)
  root:CreateCheckbox(L["Major cooldowns"], DbFlag("burst"), function()
    Run("burst")
  end)
  root:CreateCheckbox(L["Lock position"], DbFlag("locked"), function()
    Run("lock")
  end)
  -- Move: unlocks the HUD to drag (2026-11-12: "no edit mode in the new menu"). Blizzard's Edit Mode is never
  -- opened from here: an addon opening it taints Edit Mode (it stays in the game menu, Esc > Edit Mode).
  root:CreateButton(L["Move the HUD"], function()
    if ns.db then
      ns.db.locked = false
      ns.Display.SetLocked(false)
      U.Print("%s", L["The HUD is unlocked: drag it where you like, then lock it in Settings > DMGAssist."])
    end
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

-- Our own context menu: a plain frame of rows built with the MenuUtil-style calls, closed by a click elsewhere,
-- Escape, or picking a button. Checkboxes and radios stay open and refresh, like Blizzard's.
local menu
local ROW = 18
local function MenuFrame()
  if menu then
    return menu
  end
  menu = CreateFrame("Frame", "DMGAssistContextMenu", UIParent, "BackdropTemplate")
  menu:SetFrameStrata("FULLSCREEN_DIALOG")
  menu:SetClampedToScreen(true)
  if menu.SetBackdrop then
    menu:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    menu:SetBackdropColor(0.06, 0.06, 0.08, 0.96)
    menu:SetBackdropBorderColor(0.4, 0.4, 0.45, 1)
  end
  menu.rows = {}
  menu:EnableMouse(true)
  menu:RegisterEvent("GLOBAL_MOUSE_DOWN")
  menu:SetScript("OnEvent", function(self)
    if self:IsShown() and U.Get(self.IsMouseOver, self) ~= true then
      self:Hide()
    end
  end)
  if type(UISpecialFrames) == "table" then
    table.insert(UISpecialFrames, "DMGAssistContextMenu") -- Escape closes it
  end
  return menu
end

local function Row(i)
  local r = menu.rows[i]
  if not r then
    r = CreateFrame("Button", nil, menu)
    r:SetHeight(ROW)
    r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.text:SetPoint("LEFT", 22, 0)
    r.text:SetJustifyH("LEFT")
    r.mark = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.mark:SetPoint("LEFT", 6, 0)
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.08)
    r.line = r:CreateTexture(nil, "ARTWORK")
    r.line:SetHeight(1)
    r.line:SetPoint("LEFT", 6, 0)
    r.line:SetPoint("RIGHT", -6, 0)
    r.line:SetColorTexture(0.4, 0.4, 0.45, 0.8)
    menu.rows[i] = r
  end
  return r
end

function MM.ContextMenu(owner, fill)
  local f = MenuFrame()
  local items = {}
  local root = {}
  function root.CreateTitle(_, text)
    items[#items + 1] = { kind = "title", text = text }
  end
  function root.CreateButton(_, text, fn)
    items[#items + 1] = { kind = "button", text = text, fn = fn }
  end
  function root.CreateCheckbox(_, text, get, set)
    items[#items + 1] = { kind = "check", text = text, get = get, fn = set }
  end
  function root.CreateRadio(_, text, get, set)
    items[#items + 1] = { kind = "radio", text = text, get = get, fn = set }
  end
  function root.CreateDivider(_)
    items[#items + 1] = { kind = "divider" }
  end
  fill(owner, root)
  local width = 160
  local function Refresh()
    for i, it in ipairs(items) do
      local r = Row(i)
      r.text:SetText(it.text or "")
      r.line:SetShown(it.kind == "divider")
      r:SetHeight(it.kind == "divider" and 7 or ROW)
      U.Call(r.text.SetFontObject, r.text, it.kind == "title" and "GameFontNormalSmall" or "GameFontHighlightSmall")
      local mark = ""
      if it.kind == "check" then
        mark = it.get() and "|cff88ff88\226\156\147|r" or "|cff666666-|r"
      elseif it.kind == "radio" then
        mark = it.get() and "|cffffd100\226\151\143|r" or "|cff666666\226\151\139|r"
      end
      r.mark:SetText(mark)
      r:EnableMouse(it.kind ~= "title" and it.kind ~= "divider")
      width = math.max(width, (tonumber(U.Get(r.text.GetStringWidth, r.text)) or 0) + 34)
    end
  end
  Refresh()
  local y = -6
  for i, it in ipairs(items) do
    local r = menu.rows[i]
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", 4, y)
    r:SetPoint("RIGHT", -4, 0)
    r:SetScript("OnClick", function()
      if not it.fn then
        return
      end
      it.fn()
      if it.kind == "button" then
        f:Hide()
      else
        Refresh()
      end
    end)
    r:Show()
    y = y - r:GetHeight()
  end
  for i = #items + 1, #menu.rows do
    menu.rows[i]:Hide()
  end
  f:SetSize(width + 8, -y + 6)
  f:ClearAllPoints()
  local x, cy = U.Call(GetCursorPosition)
  local scale = tonumber(U.Get(UIParent.GetEffectiveScale, UIParent)) or 1
  if type(x) == "number" and type(cy) == "number" and scale > 0 then
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, cy / scale)
  else
    f:SetPoint("TOPLEFT", owner or UIParent, "BOTTOMLEFT")
  end
  f:Show()
end
ns.ContextMenu = MM.ContextMenu

local function OpenMenu(owner)
  MM.ContextMenu(owner, MM.FillMenu)
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
  icon:SetSize(20, 20) -- our round "D" fills the button (it has its own rim: no cropping like a spell icon)
  icon:SetPoint("TOPLEFT", 7, -5)
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
