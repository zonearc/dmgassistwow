/**
 * @module generators/gen-settings
 * @description
 * Generates **Settings.lua** -- the in-game settings panel.
 *
 * Produces: `Settings.lua` in the addon ZIP
 *
 * Creates a full options panel with sliders, checkboxes, dropdowns, and
 * profile management. Integrates with WoW's Settings.RegisterAddOnCategory().
 *
 * @secret-safe All settings values are stored in CLF_Config (SavedVariable)
 * which only contains user-set values, never tainted API returns.
 */

import { ADDON_NAME, ADDON_VERSION, WOW_INTERFACE } from "./shared";

/**
 * Generates Settings.lua -- the in-game settings panel.
 *
 * Creates a tabbed settings interface accessible via `/dmga settings` or
 * the gear icon on the HUD. All settings modify CLF_Config in real-time
 * with a debounced `ApplyLive()` that refreshes the HUD without reload.
 *
 * ## Tabs
 * 1. **Setup** -- Welcome instructions, required setup steps, tips
 * 2. **Display** -- Quick actions, HUD scale/opacity, icon layout, position,
 *    border style, keybind overlays, spell names, GCD indicators, queue labels
 * 3. **Combat** -- ST/AoE mode, content defaults, smart switch, keybinds,
 *    auto-hide, form/stance awareness, interrupts (DBM/BigWigs status)
 * 4. **Consumables** -- Trinket tracking, potion tracking, flask/food reminders
 * 5. **Sounds** -- Alert sounds configuration
 * 6. **SimC** -- Spec data, APL rules, equipped trinket info
 * 7. **Profiles** -- Create/switch/delete named profiles, per-character binding
 * 8. **Issues/Diagnostics** -- Live issue log, condition errors, run diagnostics
 *
 * ## Widget Factories
 * Helper functions (Slider, Checkbox, Dropdown, Header, Label, Button) create
 * consistent UI widgets with standardized sizing and positioning.
 *
 * ## Live Preview
 * Changes are applied immediately via debounced `ApplyLive()` (150ms delay)
 * which calls `CLF.RefreshHUD()` without requiring a `/reload`.
 */
export function generateSettingsPanel(): string {
  return `-- DMGAssist Settings Panel -- Full in-game UI (Hekili/MaxDPS-style)
local _, CLF = ...
local L = CLF.L or setmetatable({}, {__index = function(_, k) return k end})

local function Detaint(val)
  if type(val) == "nil" then return nil end
  if issecretvalue and issecretvalue(val) then return nil end
  return tonumber(val)
end
local function DetaintStr(v)
  if type(v) == "nil" then return nil end
  if issecretvalue and issecretvalue(v) then return nil end
  if type(v) == "string" then return v end
  local ok, s = pcall(tostring, v)
  if ok then return s end
  return nil
end
local function DetaintBool(v)
  if type(v) == "nil" then return false end
  if issecretvalue and issecretvalue(v) then return false end
  if v then return true else return false end
end

local settingsFrame = nil
local currentTab = "display"
local tabButtons = {}
local tabPanels = {}
local spellCheckboxes = {}
local profileListButtons = {}
local GOLD = { 0.83, 0.65, 0.2 }
local WHITE = { 1, 1, 1 }
local GREY = { 0.65, 0.65, 0.65 }
local DIM = { 0.45, 0.45, 0.45 }
local BRIGHT = { 0.7, 0.7, 0.7 }
local RED = { 1, 0.3, 0.3 }
local GREEN = { 0.3, 1, 0.3 }
local BG_DARK = { 0.08, 0.08, 0.1, 0.95 }

local KEYBIND_POSITIONS = { "bottom-right", "top-right", "top-left", "bottom-left", "center" }

local function CapitalizeOption(s)
  if type(s) ~= "string" then return tostring(s) end
  return (string.gsub(s, "(%a)([%w_'-]*)", function(a, b) return string.upper(a) .. b end))
end
local KEYBIND_COLORS = {
  { name = "White", r = 1, g = 1, b = 1 },
  { name = "Gold", r = 0.83, g = 0.65, b = 0.2 },
  { name = "Class", r = -1, g = -1, b = -1 },
  { name = "Green", r = 0.3, g = 1, b = 0.3 },
  { name = "Cyan", r = 0.3, g = 0.9, b = 1 },
}
local GLOW_STYLES = { "gold", "class", "none" }
local BORDER_STYLES = { "thin", "thick", "none" }
local TEXT_COLORS = { "Gold", "White", "Class", "Green", "Cyan" }

local EMPTY_CONFIG = {
  spec = { id = "unknown", className = "Unknown", specName = "Unknown", role = "dps", resource = "Mana", classColor = "#FFFFFF" },
  hud = {},
  apl = {},
  interrupts = {},
}

local function DeepCopyHud(src)
  if not src then return {} end
  local copy = {}
  for k, v in pairs(src) do
    if type(v) == "table" then
      copy[k] = {}
      for k2, v2 in pairs(v) do copy[k][k2] = v2 end
    else
      copy[k] = v
    end
  end
  return copy
end

local function GetConfig()
  if CLF_Config then return CLF_Config end
  if CLF_DefaultConfig then return CLF_DefaultConfig end
  if CLF and CLF.LogIssue then
    CLF.LogIssue("Config", "Both CLF_Config and CLF_DefaultConfig are nil -- using empty fallback", "Config.lua may have failed to load or spec is not yet detected")
  end
  return EMPTY_CONFIG
end

local function GetHud()
  local c = GetConfig()
  return c.hud or {}
end

local function Msg(text)
  print("|cFFD4A632[DMGAssist]|r " .. text)
end

local refreshTimer = nil
local function SyncActiveProfile()
  if not CLF_CharConfig then return end
  local active = CLF_CharConfig.activeProfile or "Default"
  if not CLF_Profiles then CLF_Profiles = {} end
  local config = CLF_Config or CLF_DefaultConfig
  if config and config.hud then
    if not CLF_Profiles[active] then CLF_Profiles[active] = {} end
    CLF_Profiles[active].hud = DeepCopyHud(config.hud)
    CLF_Profiles[active]._v = 2
  end
end

local function ApplyLive()
  if refreshTimer then refreshTimer:Cancel() end
  refreshTimer = C_Timer.NewTimer(0.15, function()
    refreshTimer = nil
    SyncActiveProfile()
    if CLF.RefreshHUD then
      local ok, err = pcall(CLF.RefreshHUD)
      if not ok and CLF.Log then
        CLF.Log("SETTINGS", "RefreshHUD error: " .. tostring(err))
      end
    end
  end)
end

local function ApplyAndReload()
  Msg("Settings saved. Type |cFF00FF00/reload|r if a full UI reload is needed.")
  ApplyLive()
end

-- ── §S1: Widget Builders ──
-- Factory functions for consistent UI elements (Header, Label, Slider, Checkbox, etc.)

local function Header(parent, x, y, text)
  local h = parent:CreateFontString(nil, "OVERLAY")
  h:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  h:SetFont("Fonts\\\\FRIZQT__.TTF", 13, "OUTLINE")
  h:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
  h:SetText(text)
  local line = parent:CreateTexture(nil, "ARTWORK")
  line:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -2)
  line:SetSize(380, 1)
  line:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.3)
  return h
end

local function Label(parent, x, y, text, color, size)
  color = color or GREY
  size = size or 10
  local l = parent:CreateFontString(nil, "OVERLAY")
  l:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  l:SetFont("Fonts\\\\FRIZQT__.TTF", size, "")
  l:SetTextColor(color[1], color[2], color[3])
  l:SetWidth(390)
  l:SetJustifyH("LEFT")
  l:SetWordWrap(true)
  l:SetText(text)
  return l
end

local function Checkbox(parent, x, y, label, get, set)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  cb:SetSize(26, 26)
  local initVal = get()
  cb:SetChecked(initVal and true or false)
  cb:SetScript("OnClick", function(self)
    local raw = self:GetChecked()
    local val = not not raw
    if issecretvalue and issecretvalue(raw) then
      val = not (get() and true or false)
    end
    self:SetChecked(val)
    set(val)
  end)
  local t = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  t:SetPoint("LEFT", cb, "RIGHT", 4, 0)
  t:SetFont("Fonts\\\\FRIZQT__.TTF", 11, "")
  t:SetTextColor(0.85, 0.85, 0.85)
  t:SetText(label)
  cb._label = t
  return cb
end

local function Slider(parent, x, y, label, lo, hi, step, get, set)
  local c = CreateFrame("Frame", nil, parent)
  c:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  c:SetSize(340, 40)
  local title = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 0, 0)
  title:SetFont("Fonts\\\\FRIZQT__.TTF", 11, "")
  title:SetTextColor(0.85, 0.85, 0.85)
  local sl = CreateFrame("Slider", nil, c, "OptionsSliderTemplate")
  sl:SetPoint("TOPLEFT", 0, -16)
  sl:SetSize(260, 17)
  sl:SetMinMaxValues(lo, hi)
  sl:SetValueStep(step)
  sl:SetObeyStepOnDrag(true)
  sl:SetValue(get())
  sl.Low:SetText(tostring(lo))
  sl.High:SetText(tostring(hi))
  local vt = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  vt:SetPoint("LEFT", sl, "RIGHT", 8, 0)
  vt:SetFont("Fonts\\\\FRIZQT__.TTF", 11, "")
  local function Upd()
    local v = sl:GetValue()
    local txt = (step >= 1) and string.format("%.0f", v) or string.format("%.2f", v)
    vt:SetText(txt)
    title:SetText(label .. ": " .. txt)
  end
  sl:SetScript("OnValueChanged", function(_, v) set(v); Upd() end)
  Upd()
  return c
end

local function DropdownSelect(parent, x, y, label, options, get, set)
  local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
  btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  btn:SetSize(170, 22)
  btn:SetBackdrop({ bgFile = "Interface\\\\Buttons\\\\WHITE8x8", edgeFile = "Interface\\\\Buttons\\\\WHITE8x8", edgeSize = 1 })
  btn:SetBackdropColor(0.12, 0.12, 0.15, 0.8)
  btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.5)
  local bt = btn:CreateFontString(nil, "OVERLAY")
  bt:SetFont("Fonts\\\\FRIZQT__.TTF", 10, "")
  bt:SetPoint("LEFT", btn, "LEFT", 6, 0)
  bt:SetJustifyH("LEFT")
  local arrow = btn:CreateFontString(nil, "OVERLAY")
  arrow:SetFont("Fonts\\\\FRIZQT__.TTF", 10, "")
  arrow:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
  arrow:SetText("|cFF888888v|r")
  local lbl = parent:CreateFontString(nil, "OVERLAY")
  lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y + 14)
  lbl:SetFont("Fonts\\\\FRIZQT__.TTF", 10, "")
  lbl:SetTextColor(0.75, 0.75, 0.75)
  lbl:SetText(label)
  local cur = get()
  local function GetDisplayName(o)
    local raw = type(o) == "table" and o.name or tostring(o)
    return CapitalizeOption(raw)
  end
  local function UpdateText()
    bt:SetText("|cFFFFD100" .. GetDisplayName(cur) .. "|r")
  end
  btn:SetScript("OnClick", function(self)
    local menu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetBackdrop({ bgFile = "Interface\\\\Buttons\\\\WHITE8x8", edgeFile = "Interface\\\\Buttons\\\\WHITE8x8", edgeSize = 1 })
    menu:SetBackdropColor(0.1, 0.1, 0.12, 0.95)
    menu:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
    local itemH = 20
    local menuW = 170
    menu:SetSize(menuW, #options * itemH + 4)
    menu:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
    for i, o in ipairs(options) do
      local item = CreateFrame("Button", nil, menu)
      item:SetSize(menuW - 4, itemH)
      item:SetPoint("TOPLEFT", menu, "TOPLEFT", 2, -2 - (i - 1) * itemH)
      local itemText = item:CreateFontString(nil, "OVERLAY")
      itemText:SetFont("Fonts\\\\FRIZQT__.TTF", 10, "")
      itemText:SetPoint("LEFT", item, "LEFT", 6, 0)
      local val = type(o) == "table" and o.name or o
      local isCurrent = (DetaintStr(val) or "") == (DetaintStr(cur) or "")
      itemText:SetText((isCurrent and "|cFF00FF00" or "|cFFCCCCCC") .. GetDisplayName(o) .. "|r")
      local hl = item:CreateTexture(nil, "HIGHLIGHT")
      hl:SetAllPoints()
      hl:SetTexture("Interface\\\\Buttons\\\\WHITE8x8")
      hl:SetVertexColor(0.3, 0.3, 0.4, 0.3)
      item:SetScript("OnClick", function()
        cur = val
        set(val)
        UpdateText()
        menu:Hide()
      end)
    end
    menu:Show()
    menu:SetScript("OnUpdate", function(self)
      if not MouseIsOver(self) and not MouseIsOver(btn) then
        self._outTicks = (self._outTicks or 0) + 1
        if self._outTicks > 15 then self:Hide() end
      else
        self._outTicks = 0
      end
    end)
  end)
  btn:SetScript("OnEnter", function(self)
    self:SetBackdropBorderColor(0.6, 0.6, 0.3, 0.8)
  end)
  btn:SetScript("OnLeave", function(self)
    self:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.5)
  end)
  UpdateText()
  return btn
end

local function ActionButton(parent, x, y, w, text, onClick, isActive)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  b:SetSize(w, 24)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  if isActive then
    local highlight = CreateFrame("Frame", nil, b, "BackdropTemplate")
    highlight:SetPoint("TOPLEFT", b, "TOPLEFT", -2, 2)
    highlight:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 2, -2)
    highlight:SetFrameLevel(b:GetFrameLevel() + 1)
    highlight:SetBackdrop({
      edgeFile = "Interface\\\\Buttons\\\\WHITE8x8",
      edgeSize = 2,
    })
    highlight:SetBackdropBorderColor(0, 0.9, 0, 0.9)
  end
  return b
end

-- ── §S1b: Tab -- Setup (Instructions & Getting Started) ──
local function BuildSetupTab(panel)
  local y = -10

  Header(panel, 10, y, L["SETUP_HEADER_WELCOME"])
  y = y - 30

  local intro = panel:CreateFontString(nil, "OVERLAY")
  intro:SetFont("Fonts\\\\FRIZQT__.TTF", 11, "")
  intro:SetPoint("TOPLEFT", panel, "TOPLEFT", 15, y)
  intro:SetWidth(840)
  intro:SetJustifyH("LEFT")
  intro:SetTextColor(0.85, 0.85, 0.85)
  intro:SetText(L["SETUP_INTRO"])
  y = y - intro:GetStringHeight() - 20

  Header(panel, 10, y, L["SETUP_HEADER_REQUIRED"])
  y = y - 28

  local reqItems = {
    L["SETUP_REQ_1"],
    L["SETUP_REQ_2"],
    L["SETUP_REQ_3"],
  }
  for _, txt in ipairs(reqItems) do
    local line = panel:CreateFontString(nil, "OVERLAY")
    line:SetFont("Fonts\\\\FRIZQT__.TTF", 11, "")
    line:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, y)
    line:SetWidth(830)
    line:SetJustifyH("LEFT")
    line:SetTextColor(0.9, 0.9, 0.9)
    line:SetText(txt)
    y = y - line:GetStringHeight() - 12
  end

  y = y - 10
  Header(panel, 10, y, L["SETUP_HEADER_TIPS"])
  y = y - 28

  local tipItems = {
    L["SETUP_TIP_1"],
    L["SETUP_TIP_2"],
    L["SETUP_TIP_3"],
    L["SETUP_TIP_4"],
    L["SETUP_TIP_5"],
  }
  for _, txt in ipairs(tipItems) do
    local line = panel:CreateFontString(nil, "OVERLAY")
    line:SetFont("Fonts\\\\FRIZQT__.TTF", 11, "")
    line:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, y)
    line:SetWidth(830)
    line:SetJustifyH("LEFT")
    line:SetTextColor(0.9, 0.9, 0.9)
    line:SetText(txt)
    y = y - line:GetStringHeight() - 12
  end

  y = y - 20
  local verLabel = panel:CreateFontString(nil, "OVERLAY")
  verLabel:SetFont("Fonts\\\\FRIZQT__.TTF", 9, "")
  verLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 15, y)
  verLabel:SetTextColor(0.4, 0.4, 0.4)
  verLabel:SetText("DMGAssist v${ADDON_VERSION}")
end

-- ── §S2: Tab -- Display (Layout, Scale, Position, Keybinds, Text, Elements) ──
local COL2 = 450

local function BuildDisplayTab(panel)
  local hud = GetHud()
  local yL = -10
  local yR = -10

  Header(panel, 10, yL, L["HEADER_QUICK_ACTIONS"])
  yL = yL - 28
  ActionButton(panel, 15, yL, 120, "Toggle HUD", function() CLF.ToggleHUD() end)
  ActionButton(panel, 140, yL, 120, "Toggle Lock", function()
    local h = GetHud()
    local locked = h.lockPosition
    CLF.LockHUD(not locked)
  end)
  ActionButton(panel, 265, yL, 140, L["BTN_RESET_POS"], function()
    local h = GetHud()
    h.positionX = 50
    h.positionY = 70
    CLF_Position = {}
    local mf = _G["CLF_MainFrame"]
    if mf then
      mf:ClearAllPoints()
      mf:SetPoint("CENTER", UIParent, "BOTTOMLEFT",
        UIParent:GetWidth() * 0.5,
        UIParent:GetHeight() * 0.3
      )
    end
    Msg(L["MSG_POS_RESET"])
  end)
  yL = yL - 40

  Header(panel, 10, yL, L["HEADER_SCALE_OPACITY"])
  yL = yL - 30
  Slider(panel, 15, yL, "Overall Scale", 0.5, 3.0, 0.05,
    function() return hud.scale or 1.2 end,
    function(v) hud.scale = v; ApplyLive() end)
  yL = yL - 50
  Slider(panel, 15, yL, "Opacity", 0.1, 1.0, 0.05,
    function() return hud.opacity or 0.95 end,
    function(v) hud.opacity = v; ApplyLive() end)
  yL = yL - 60

  Header(panel, 10, yL, L["HEADER_ICON_LAYOUT"])
  yL = yL - 30
  Slider(panel, 15, yL, "Primary Icon Size", 20, 96, 2,
    function() return hud.iconSize or 48 end,
    function(v) hud.iconSize = v; ApplyLive() end)
  yL = yL - 50
  Slider(panel, 15, yL, "Next Icon Size", 16, 72, 2,
    function() return hud.predIconSize or 34 end,
    function(v) hud.predIconSize = v; ApplyLive() end)
  yL = yL - 50
  Slider(panel, 15, yL, "Queue Slots (next abilities)", 1, 3, 1,
    function() return hud.queueSlots or 3 end,
    function(v) hud.queueSlots = v; ApplyLive() end)
  yL = yL - 50
  Slider(panel, 15, yL, "Icon Spacing", 0, 40, 1,
    function() return hud.iconSpacing or 14 end,
    function(v) hud.iconSpacing = v; ApplyLive() end)
  yL = yL - 50
  Slider(panel, 15, yL, "Frame Padding", 2, 32, 2,
    function() return hud.framePadding or 16 end,
    function(v) hud.framePadding = v; ApplyLive() end)
  yL = yL - 50
  Slider(panel, 15, yL, "Min Frame Width", 120, 400, 5,
    function() return hud.minFrameWidth or 220 end,
    function(v) hud.minFrameWidth = v; ApplyLive() end)
  yL = yL - 50
  Slider(panel, 15, yL, "Queue Icon Opacity", 0.1, 1.0, 0.05,
    function() return hud.queueOpacity or 0.6 end,
    function(v) hud.queueOpacity = v; ApplyLive() end)
  yL = yL - 20

  Header(panel, COL2, yR, L["HEADER_BORDER_STYLE"])
  yR = yR - 30
  Slider(panel, COL2 + 5, yR, "Border Opacity", 0, 1.0, 0.05,
    function() return hud.borderOpacity or 0.25 end,
    function(v) hud.borderOpacity = v; ApplyLive() end)
  yR = yR - 55
  DropdownSelect(panel, COL2 + 5, yR, "Border Thickness", BORDER_STYLES,
    function() return hud.borderStyle or "thin" end,
    function(v) hud.borderStyle = v; ApplyLive() end)
  yR = yR - 50
  DropdownSelect(panel, COL2 + 5, yR, "Glow Style (active ability)", GLOW_STYLES,
    function() return hud.glowStyle or "gold" end,
    function(v) hud.glowStyle = v; ApplyLive() end)
  yR = yR - 50
  Slider(panel, COL2 + 5, yR, "Background Opacity", 0, 1.0, 0.05,
    function() return hud.bgOpacity or 0.75 end,
    function(v) hud.bgOpacity = v; ApplyLive() end)
  yR = yR - 60

  Header(panel, COL2, yR, L["HEADER_KEYBIND_OVERLAYS"])
  yR = yR - 30
  Checkbox(panel, COL2 + 5, yR, "Show Keybind Text on Icons",
    function() return hud.showKeybind ~= false end,
    function(v) hud.showKeybind = v; ApplyLive() end)
  yR = yR - 35
  DropdownSelect(panel, COL2 + 5, yR, "Keybind Position", KEYBIND_POSITIONS,
    function() return hud.keybindPosition or "bottom-right" end,
    function(v) hud.keybindPosition = v; ApplyLive() end)
  yR = yR - 45
  Slider(panel, COL2 + 5, yR, "Keybind Font Size", 6, 36, 1,
    function() return hud.keybindFontSize or 11 end,
    function(v) hud.keybindFontSize = v; ApplyLive() end)
  yR = yR - 55
  DropdownSelect(panel, COL2 + 5, yR, "Keybind Text Color", KEYBIND_COLORS,
    function() return hud.keybindColor or "White" end,
    function(v) hud.keybindColor = v; ApplyLive() end)
  yR = yR - 55

  Header(panel, COL2, yR, L["HEADER_SPELL_NAMES"])
  yR = yR - 30
  Checkbox(panel, COL2 + 5, yR, "Show Spell Name Below Icon",
    function() return hud.showSpellName ~= false end,
    function(v) hud.showSpellName = v; ApplyLive() end)
  yR = yR - 35
  Slider(panel, COL2 + 5, yR, "Spell Name Font Size", 6, 16, 1,
    function() return hud.spellNameFontSize or 10 end,
    function(v) hud.spellNameFontSize = v; ApplyLive() end)
  yR = yR - 55
  Slider(panel, COL2 + 5, yR, "Spell Name Padding", 0, 20, 1,
    function() return hud.spellNamePadding or 6 end,
    function(v) hud.spellNamePadding = v; ApplyLive() end)
  yR = yR - 55

  Header(panel, COL2, yR, L["HEADER_HUD_ELEMENTS"])
  yR = yR - 30
  Checkbox(panel, COL2 + 5, yR, "Show Header (spec, mode, gear icon)",
    function() return hud.showHeader ~= false end,
    function(v) hud.showHeader = v; ApplyLive() end)
  yR = yR - 28
  Label(panel, COL2 + 5, yR, "GCD Indicator on Primary Icon:", WHITE, 10)
  yR = yR - 30
  do
    local GCD_STYLES = { "Both (overlay + bar)", "Overlay (darken + desat)", "Bar (bottom 20%)", "None" }
    local GCD_VALUES = { "both", "overlay", "bar", "none" }
    DropdownSelect(panel, COL2 + 5, yR, "GCD Style", GCD_STYLES,
      function()
        local cur = hud.gcdIndicator or "both"
        for gi, g in ipairs(GCD_VALUES) do
          if g == cur then return GCD_STYLES[gi] end
        end
        return GCD_STYLES[1]
      end,
      function(v)
        for gi, g in ipairs(GCD_STYLES) do
          if g == v then hud.gcdIndicator = GCD_VALUES[gi] break end
        end
        ApplyLive()
      end)
    yR = yR - 55
  end
  Checkbox(panel, COL2 + 5, yR, "Show GCD Spark (progress bar)",
    function() return hud.showGcdSpark ~= false end,
    function(v) hud.showGcdSpark = v; ApplyLive() end)
  yR = yR - 28
  Checkbox(panel, COL2 + 5, yR, "Show Prediction Queue",
    function() return hud.showPrediction ~= false end,
    function(v) hud.showPrediction = v; ApplyLive() end)
  yR = yR - 28
  Checkbox(panel, COL2 + 5, yR, 'Show "NOW" / "NEXT" Labels',
    function() return hud.showQueueLabels ~= false end,
    function(v) hud.showQueueLabels = v; ApplyLive() end)
  yR = yR - 35

  Header(panel, COL2, yR, "Text Appearance")
  yR = yR - 30
  Slider(panel, COL2 + 5, yR, "Header Font Size", 6, 18, 1,
    function() return hud.headerFontSize or 11 end,
    function(v) hud.headerFontSize = v; ApplyLive() end)
  yR = yR - 50
  Slider(panel, COL2 + 5, yR, "Consumables Font Size", 6, 18, 1,
    function() return hud.consumablesFontSize or 11 end,
    function(v) hud.consumablesFontSize = v; ApplyLive() end)
  yR = yR - 65
  DropdownSelect(panel, COL2 + 5, yR, "Header / Consumable Text Color", TEXT_COLORS,
    function() return hud.headerTextColor or "Gold" end,
    function(v) hud.headerTextColor = v; ApplyLive() end)
  yR = yR - 10
end

-- ── §S4: Tab -- Combat (Mode, Auto-Hide, Form Awareness) ──
local function BuildCombatTab(panel)
  local hud = GetHud()
  local yL = -10
  local yR = -10

  Header(panel, 10, yL, L["HEADER_TARGET_MODE"])
  yL = yL - 28
  local modeLabel = CLF._modeLock and (CLF._modeLock .. " (OVERRIDE)") or (CLF.combatMode .. " (default)")
  Label(panel, 15, yL, "Current: |cFFFFD100" .. modeLabel .. "|r", WHITE, 11)
  yL = yL - 22
  Label(panel, 15, yL, "Sets which rotation the HUD uses. Default picks the mode based on content type below.", DIM, 10)
  yL = yL - 26
  local modeOptions = { { label = "Default", value = "default" }, { label = "Force ST", value = "ST" }, { label = "Force AoE", value = "AoE" } }
  local modeBtn = CreateFrame("Button", "CLF_TargetModeDD", panel, "BackdropTemplate")
  modeBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 15, yL + 4)
  modeBtn:SetSize(140, 22)
  modeBtn:SetBackdrop({ bgFile = "Interface\\\\ChatFrame\\\\ChatFrameBackground", edgeFile = "Interface\\\\Tooltips\\\\UI-Tooltip-Border", edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
  modeBtn:SetBackdropColor(0.12, 0.12, 0.12, 0.9)
  modeBtn:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
  local modeBtnText = modeBtn:CreateFontString(nil, "OVERLAY")
  modeBtnText:SetFont("Fonts\\\\FRIZQT__.TTF", 10, "")
  modeBtnText:SetPoint("LEFT", modeBtn, "LEFT", 8, 0)
  local currentMode = CLF._modeLock
  local modeDisplayColor = not currentMode and "|cFF00FF00" or (currentMode == "ST" and "|cFF33BBFF" or "|cFFFF8800")
  local modeDisplayLabel = not currentMode and "Default" or ("Force " .. currentMode)
  modeBtnText:SetText(modeDisplayColor .. modeDisplayLabel .. "|r")
  local modeArrow = modeBtn:CreateFontString(nil, "OVERLAY")
  modeArrow:SetFont("Fonts\\\\FRIZQT__.TTF", 9, "")
  modeArrow:SetPoint("RIGHT", modeBtn, "RIGHT", -6, 0)
  modeArrow:SetTextColor(0.7, 0.7, 0.7, 1)
  modeArrow:SetText("v")
  local modePopup = CreateFrame("Frame", "CLF_TargetModeDD_Popup", modeBtn, "BackdropTemplate")
  modePopup:SetSize(140, #modeOptions * 20 + 4)
  modePopup:SetPoint("TOP", modeBtn, "BOTTOM", 0, -1)
  modePopup:SetBackdrop({ bgFile = "Interface\\\\ChatFrame\\\\ChatFrameBackground", edgeFile = "Interface\\\\Tooltips\\\\UI-Tooltip-Border", edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
  modePopup:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
  modePopup:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.9)
  modePopup:SetFrameStrata("DIALOG")
  modePopup:Hide()
  for mi, opt in ipairs(modeOptions) do
    local item = CreateFrame("Button", nil, modePopup)
    item:SetSize(134, 18)
    item:SetPoint("TOPLEFT", modePopup, "TOPLEFT", 3, -(mi - 1) * 20 - 2)
    local itemText = item:CreateFontString(nil, "OVERLAY")
    itemText:SetFont("Fonts\\\\FRIZQT__.TTF", 10, "")
    itemText:SetPoint("LEFT", item, "LEFT", 6, 0)
    local optColor = opt.value == "default" and "|cFF00FF00" or (opt.value == "ST" and "|cFF33BBFF" or "|cFFFF8800")
    local isSelected = (opt.value == "default" and not CLF._modeLock) or (CLF._modeLock == opt.value)
    if isSelected then
      itemText:SetText(optColor .. opt.label .. "|r  |cFFFFD100*|r")
    else
      itemText:SetText(optColor .. opt.label .. "|r")
    end
    item:SetHighlightTexture("Interface\\\\QuestFrame\\\\UI-QuestTitleHighlight", "ADD")
    item:SetScript("OnClick", function()
      if opt.value == "default" then
        CLF._modeLock = nil
        CLF.DetectCombatMode()
        Msg("Mode: |cFF00FF00" .. CLF.combatMode .. "|r (content default)")
      else
        CLF.LockMode(opt.value)
      end
      modePopup:Hide()
      CLF.RebuildSettingsPanel()
    end)
  end
  modeBtn:SetScript("OnClick", function(self)
    if modePopup:IsShown() then modePopup:Hide() else modePopup:Show() end
  end)
  modeBtn:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 1) end)
  modeBtn:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8) end)
  yL = yL - 30
  Label(panel, 15, yL, "|cFFFFD100Content Defaults:|r  Set rotation mode per content type.", WHITE, 11)
  yL = yL - 24
  local contentModes = { "AoE", "ST" }
  local contentDropdownCount = (CLF._contentDropdownCount or 0)
  local function ContentDropdown(panel, x, yPos, label, getFunc, setFunc)
    Label(panel, x, yPos, label, WHITE, 11)
    local current = getFunc()
    contentDropdownCount = contentDropdownCount + 1
    local btnName = "CLF_ContentDD_" .. contentDropdownCount
    local btn = CreateFrame("Button", btnName, panel, "BackdropTemplate")
    btn:SetPoint("TOPLEFT", panel, "TOPLEFT", x + 170, yPos + 4)
    btn:SetSize(80, 20)
    btn:SetBackdrop({ bgFile = "Interface\\\\ChatFrame\\\\ChatFrameBackground", edgeFile = "Interface\\\\Tooltips\\\\UI-Tooltip-Border", edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
    btn:SetBackdropColor(0.12, 0.12, 0.12, 0.9)
    btn:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
    local btnText = btn:CreateFontString(nil, "OVERLAY")
    btnText:SetFont("Fonts\\\\FRIZQT__.TTF", 10, "")
    btnText:SetPoint("LEFT", btn, "LEFT", 8, 0)
    local displayColor = current == "AoE" and "|cFF00FF00" or "|cFF33BBFF"
    btnText:SetText(displayColor .. current .. "|r")
    local arrow = btn:CreateFontString(nil, "OVERLAY")
    arrow:SetFont("Fonts\\\\FRIZQT__.TTF", 9, "")
    arrow:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
    arrow:SetTextColor(0.7, 0.7, 0.7, 1)
    arrow:SetText("v")
    local popup = CreateFrame("Frame", btnName .. "_Popup", btn, "BackdropTemplate")
    popup:SetSize(80, #contentModes * 20 + 4)
    popup:SetPoint("TOP", btn, "BOTTOM", 0, -1)
    popup:SetBackdrop({ bgFile = "Interface\\\\ChatFrame\\\\ChatFrameBackground", edgeFile = "Interface\\\\Tooltips\\\\UI-Tooltip-Border", edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
    popup:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
    popup:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.9)
    popup:SetFrameStrata("DIALOG")
    popup:Hide()
    for mi, mode in ipairs(contentModes) do
      local item = CreateFrame("Button", nil, popup)
      item:SetSize(74, 18)
      item:SetPoint("TOPLEFT", popup, "TOPLEFT", 3, -(mi - 1) * 20 - 2)
      local itemText = item:CreateFontString(nil, "OVERLAY")
      itemText:SetFont("Fonts\\\\FRIZQT__.TTF", 10, "")
      itemText:SetPoint("LEFT", item, "LEFT", 6, 0)
      local modeColor = mode == "AoE" and "|cFF00FF00" or "|cFF33BBFF"
      local isSelected = current == mode
      if isSelected then
        itemText:SetText(modeColor .. mode .. "|r  |cFFFFD100*|r")
      else
        itemText:SetText(modeColor .. mode .. "|r")
      end
      item:SetHighlightTexture("Interface\\\\QuestFrame\\\\UI-QuestTitleHighlight", "ADD")
      item:SetScript("OnClick", function()
        setFunc(mode)
        if not CLF._modeLock then CLF.DetectCombatMode() end
        popup:Hide()
        CLF.RebuildSettingsPanel()
      end)
    end
    btn:SetScript("OnClick", function()
      if popup:IsShown() then popup:Hide() else popup:Show() end
    end)
    btn:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(0.8, 0.8, 0.2, 1) end)
    btn:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8) end)
  end
  CLF._contentDropdownCount = contentDropdownCount
  ContentDropdown(panel, 15, yL, "Dungeons:", function() return hud.defaultModeDungeon or "AoE" end, function(v) hud.defaultModeDungeon = v end)
  yL = yL - 24
  ContentDropdown(panel, 15, yL, "Raids:", function() return hud.defaultModeRaid or "AoE" end, function(v) hud.defaultModeRaid = v end)
  yL = yL - 24
  ContentDropdown(panel, 15, yL, "Delves:", function() return hud.defaultModeDelve or "AoE" end, function(v) hud.defaultModeDelve = v end)
  yL = yL - 24
  ContentDropdown(panel, 15, yL, "Open World / Questing:", function() return hud.defaultModeWorld or "AoE" end, function(v) hud.defaultModeWorld = v end)
  yL = yL - 34

  Checkbox(panel, 15, yL, "Smart Mode Switch",
    function() return hud.smartModeSwitch ~= false end,
    function(v)
      hud.smartModeSwitch = v
      CLF._smartModeSwitchEnabled = v
      Msg("Smart Mode Switch: " .. (v and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))
    end)
  yL = yL - 24
  Label(panel, 30, yL, "When a content default above is set to |cFF33BBFFST|r, smart mode will automatically switch to |cFF00FF00AoE|r for the remainder of combat if you cast any AoE ability.", DIM, 10)
  yL = yL - 44

  Header(panel, 10, yL, L["HEADER_KEYBINDS"])
  yL = yL - 26
  Label(panel, 15, yL, "You can also switch modes with a keybind or by right-clicking the HUD.", WHITE, 10)
  yL = yL - 22
  Label(panel, 15, yL, "Set keybinds in: |cFFFFD100Options|r > |cFFFFD100Keybindings|r > |cFFFFD100AddOns|r > |cFFFFD100DMGAssist|r", WHITE, 10)
  yL = yL - 22
  Label(panel, 15, yL, "Cycle Mode (AoE/ST) and other actions are bindable there.", DIM, 10)
  yL = yL - 26
  Label(panel, 15, yL, "|cFFFFD100How to bind:|r Press |cFF00FF00Escape|r, click |cFF00FF00Options|r, then |cFF00FF00Keybindings|r, scroll to |cFF00FF00AddOns|r section.", WHITE, 10)
  yL = yL - 28
  ActionButton(panel, 15, yL, 90, "Test Flash", function()
    CLF.ShowModeFlash(CLF._modeLock or CLF.combatMode or "AoE")
  end)
  yL = yL - 22
  Label(panel, 15, yL, "Flashes the current mode overlay on the HUD for a quick visual check.", DIM, 10)
  yL = yL - 20

  Header(panel, COL2, yR, L["HEADER_AUTOHIDE"])
  yR = yR - 30
  Checkbox(panel, COL2 + 5, yR, "Auto-Hide HUD when out of combat",
    function() return hud.hideOutOfCombat == true end,
    function(v)
      hud.hideOutOfCombat = v
      Msg("Auto-hide: " .. (v and "|cFF00FF00ON|r -- HUD hides after combat ends" or "|cFFFF0000OFF|r -- HUD stays visible"))
      if v and not DetaintBool(InCombatLockdown(), "InCombatLockdown") then
        CLF._manualShow = false
        CLF.HideHUD()
      elseif not v then
        CLF.ShowHUD()
      end
    end)
  yR = yR - 24
  Label(panel, COL2 + 10, yR, "Hides the spell queue when you leave combat.", DIM, 10)
  yR = yR - 28
  Checkbox(panel, COL2 + 20, yR, "Show HUD when targeting enemy (requires Auto-Hide)",
    function() return hud.outOfCombatMode == true end,
    function(v)
      hud.outOfCombatMode = v
      Msg("OOC target mode: " .. (v and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))
    end)
  yR = yR - 24
  Label(panel, COL2 + 25, yR, "Re-shows the HUD when you target a hostile unit while out of combat.", DIM, 10)
  yR = yR - 40

  Header(panel, COL2, yR, L["HEADER_FORM_AWARENESS"])
  yR = yR - 30
  Checkbox(panel, COL2 + 5, yR, "Enable Form/Stance Awareness",
    function() return hud.formAwareness ~= false end,
    function(v) hud.formAwareness = v end)
  yR = yR - 24
  Label(panel, COL2 + 10, yR, "Detects your current form and shows correct precombat suggestions.", DIM, 10)
  yR = yR - 35

  Header(panel, COL2, yR, "Queue Behavior")
  yR = yR - 30
  local QUEUE_MODES = { "Lookahead", "Current Cast" }
  Label(panel, COL2 + 5, yR, "Primary Slot Mode", DIM, 10)
  yR = yR - 22
  DropdownSelect(panel, COL2 + 5, yR, "", QUEUE_MODES,
    function() return hud.primarySlotMode or "Lookahead" end,
    function(v) hud.primarySlotMode = v; ApplyLive() end)
  yR = yR - 30
  if (hud.primarySlotMode or "Lookahead") == "Lookahead" then
    Label(panel, COL2 + 10, yR, "Slot 1 immediately shows the |cFF00FF00NEXT|r spell when you cast.", DIM, 10)
  else
    Label(panel, COL2 + 10, yR, "Slot 1 stays on the |cFFFFD100current cast|r until GCD/cast finishes.", DIM, 10)
  end
  yR = yR - 40

  Header(panel, COL2, yR, L["HEADER_TRINKET_TRACKING"])
  yR = yR - 28
  Checkbox(panel, COL2 + 5, yR, "Show On-Use Trinkets in Rotation",
    function() return hud.trinketsEnabled ~= false end,
    function(v)
      hud.trinketsEnabled = v
      Msg("Trinket tracking: " .. (v and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))
    end)
  yR = yR - 24
  Label(panel, COL2 + 10, yR, "Equipped on-use trinkets are suggested based on SimC priority.", DIM, 10)
  yR = yR - 35

  Header(panel, COL2, yR, "Combat Role")
  yR = yR - 28
  Label(panel, COL2 + 5, yR, "Controls how defensives are prioritized in the rotation queue.", DIM, 10)
  yR = yR - 26
  Checkbox(panel, COL2 + 5, yR, "Auto Tank Mode",
    function() return hud.combatRole == "auto" end,
    function(v)
      if v then
        hud.combatRole = "auto"
        local activeNow = CLF._isTankSpec and "active (tank spec detected)" or "inactive (DPS/healer spec)"
        Msg("Combat role: |cFF00FF00AUTO|r -- Tank mode automatically enabled for tank specs. Currently " .. activeNow)
        if CLF._isTankSpec and not hud.showDefensives then
          hud.showDefensives = true
          Msg("Show Defensives auto-enabled for Tank Mode")
        end
      else
        hud.combatRole = "dps"
        Msg("Combat role: |cFFFFFF00DPS|r -- Defensives only reach slot 1 via Cooldown Manager highlight")
      end
      ApplyLive()
    end)
  yR = yR - 24
  local autoStatus = CLF._isTankSpec and "|cFF00FF00Tank mode active|r (tank spec detected)" or "|cFF888888Tank mode inactive|r (DPS/healer spec)"
  Label(panel, COL2 + 10, yR, "Automatically enables Tank Mode for tank specs (Guardian, Prot, Brewmaster, etc.). " .. autoStatus, DIM, 10)
  yR = yR - 28
  Checkbox(panel, COL2 + 5, yR, "Force Tank Mode (Manual Override)",
    function() return hud.combatRole == "tank" end,
    function(v)
      if v then
        hud.combatRole = "tank"
        Msg("Combat role: |cFF00FF00TANK (forced)|r -- Tank mode always active regardless of spec")
        if not hud.showDefensives then
          hud.showDefensives = true
          Msg("Show Defensives auto-enabled for Tank Mode")
        end
      else
        hud.combatRole = "auto"
        local activeNow = CLF._isTankSpec and "active (tank spec detected)" or "inactive (DPS/healer spec)"
        Msg("Combat role: |cFF00FF00AUTO|r -- Reverting to auto-detect. Currently " .. activeNow)
      end
      ApplyLive()
    end)
  yR = yR - 24
  Label(panel, COL2 + 10, yR, "Forces Tank Mode on any spec. Use for off-tanking on a DPS spec (e.g. Feral bear form).", DIM, 10)
  yR = yR - 35

  Header(panel, COL2, yR, L["HEADER_INTERRUPTS"])
  yR = yR - 28
  local hasDBM = DBM and DBM.RegisterCallback
  local hasBW = BigWigsLoader and BigWigsLoader.RegisterMessage
  local dbmStatus = hasDBM and "|cFF00FF00Connected|r" or "|cFF888888Not installed|r"
  local bwStatus = hasBW and "|cFF00FF00Connected|r" or "|cFF888888Not installed|r"
  Label(panel, COL2 + 5, yR, "DBM: " .. dbmStatus .. "    BigWigs: " .. bwStatus, WHITE, 10)
  yR = yR - 24
  Label(panel, COL2 + 5, yR, "Boss mods provide priority interrupt alerts for dangerous casts.", DIM, 10)
  yR = yR - 24
  local testRoute = (hasDBM and DBM.callbacks and DBM.callbacks.Fire) and "via DBM" or ((hasBW and BigWigsLoader.SendMessage) and "via BigWigs" or "direct inject")
  ActionButton(panel, COL2 + 5, yR, 220, "Test Interrupt Alert (" .. testRoute .. ")", function()
    CLF.PlayEventSound("interrupt")
    SlashCmdList["CLF"]("testinterrupt")
  end)
  yR = yR - 30
  Label(panel, COL2 + 5, yR, "Fires a 5s test alert. Interrupt spell jumps to slot 1 with red border.", DIM, 10)
  yR = yR - 20
  Label(panel, COL2 + 5, yR, "Configure all sounds in the |cFFD4A632Sounds|r tab.", DIM, 10)
  yR = yR - 10
end

-- ── §S5: Tab -- Items (Potions, Flask, Food, Weapon Enhancements, Augment Runes) ──
local function BuildConsumablesTab(panel)
  local hud = GetHud()
  local yL = -10
  local yR = -10

  Header(panel, 10, yL, L["HEADER_CONSUMABLE_TRACKING"])
  yL = yL - 28
  Checkbox(panel, 15, yL, "Enable Consumable Alerts",
    function() return hud.consumablesEnabled ~= false end,
    function(v)
      hud.consumablesEnabled = v
      Msg("Consumable alerts: " .. (v and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))
      if CLF.InitConsumables then CLF.InitConsumables() end
      if CLF.UpdateConsumableBar then CLF.UpdateConsumableBar() end
    end)
  yL = yL - 22
  Label(panel, 15, yL, "Shows expired consumables below the HUD with icons.", DIM, 10)
  yL = yL - 28
  Label(panel, 15, yL, "Only appears out of combat. Hides when all consumables are active.", DIM, 10)
  yL = yL - 34

  Header(panel, 10, yL, "Alert Categories")
  yL = yL - 28
  Checkbox(panel, 15, yL, L["CONSUMABLE_FLASK"],
    function() return hud.flaskEnabled ~= false end,
    function(v)
      hud.flaskEnabled = v
      Msg("Flask/Phial alert: " .. (v and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))
      if CLF.InitConsumables then CLF.InitConsumables() end
    end)
  yL = yL - 22
  Label(panel, 30, yL, "Detects any Flask or Phial buff.", DIM, 10)
  yL = yL - 28
  Checkbox(panel, 15, yL, L["CONSUMABLE_FOOD"],
    function() return hud.foodEnabled ~= false end,
    function(v)
      hud.foodEnabled = v
      Msg("Food alert: " .. (v and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))
      if CLF.InitConsumables then CLF.InitConsumables() end
    end)
  yL = yL - 22
  Label(panel, 30, yL, "Detects Well Fed and similar food buffs.", DIM, 10)
  yL = yL - 28
  Checkbox(panel, 15, yL, L["CONSUMABLE_WEAPON_ENH"],
    function() return hud.weaponEnhEnabled ~= false end,
    function(v)
      hud.weaponEnhEnabled = v
      Msg("Weapon Enhancement alert: " .. (v and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))
      if CLF.InitConsumables then CLF.InitConsumables() end
    end)
  yL = yL - 22
  Label(panel, 30, yL, "Detects weapon oils, stones, and coatings.", DIM, 10)
  yL = yL - 28
  Checkbox(panel, 15, yL, L["CONSUMABLE_AUGMENT_RUNE"],
    function() return hud.augmentRuneEnabled ~= false end,
    function(v)
      hud.augmentRuneEnabled = v
      Msg("Augment Rune alert: " .. (v and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))
      if CLF.InitConsumables then CLF.InitConsumables() end
    end)
  yL = yL - 22
  Label(panel, 30, yL, "Detects Augment Rune buffs.", DIM, 10)

  Header(panel, COL2, yR, "Current Status")
  yR = yR - 28
  for _, catKey in ipairs({"flask", "food", "weaponEnh", "augmentRune"}) do
    local LABELS = { flask = L["CONSUMABLE_FLASK"], food = L["CONSUMABLE_FOOD"], weaponEnh = L["CONSUMABLE_WEAPON_ENH"], augmentRune = L["CONSUMABLE_AUGMENT_RUNE"] }
    local ENABLE_KEYS = { flask = "flaskEnabled", food = "foodEnabled", weaponEnh = "weaponEnhEnabled", augmentRune = "augmentRuneEnabled" }
    if hud[ENABLE_KEYS[catKey]] ~= false then
      local cData = CLF._consumables[catKey]
      local statusStr
      if cData and cData.buffActive then
        if cData.buffExpiry > 0 then
          local rem = cData.buffExpiry - GetTime()
          local mins = math.floor(rem / 60)
          statusStr = "|cFF00FF00ACTIVE|r (" .. mins .. "m remaining)"
        else
          statusStr = "|cFF00FF00ACTIVE|r"
        end
      else
        statusStr = "|cFFFF4444NOT ACTIVE|r"
      end
      Label(panel, COL2 + 5, yR, LABELS[catKey] .. ": " .. statusStr, WHITE, 11)
      yR = yR - 24
    end
  end
  yR = yR - 10
  Label(panel, COL2 + 5, yR, "Status updates every few seconds out of combat.", DIM, 10)
end

-- ── §S6b: Tab -- Sounds ──
local function BuildSoundsTab(panel)
  local hud = GetHud()
  local y = -10

  Header(panel, 10, y, "Event Sounds")
  y = y - 24
  Label(panel, 15, y, "Play a sound when certain events occur. Toggle each event on or off, and pick which WoW sound to use.", DIM, 10)
  y = y - 30

  local SOUND_NAMES = {
    "RaidWarning",
    "ReadyCheck",
    "PVP Flag",
    "Alarm Clock 1",
    "Alarm Clock 2",
    "Alarm Clock 3",
    "Map Ping",
    "Tell Message",
    "LFG Denied",
    "GM Chat Warning",
    "PVP Enter Queue",
    "Loot Coin",
    "Arrow Whoosh",
    "Fishing Reel",
    "UI Garrison Toast",
    "Auction Open",
    "Boss Emote Warning",
    "None",
  }
  local SOUND_IDS = {
    ["RaidWarning"] = SOUNDKIT.RAID_WARNING or 8959,
    ["ReadyCheck"] = SOUNDKIT.READY_CHECK or 8960,
    ["PVP Flag"] = SOUNDKIT.PVP_THROUGH_QUEUE or 8892,
    ["Alarm Clock 1"] = SOUNDKIT.ALARM_CLOCK_WARNING_1 or 12867,
    ["Alarm Clock 2"] = SOUNDKIT.ALARM_CLOCK_WARNING_2 or 12889,
    ["Alarm Clock 3"] = SOUNDKIT.ALARM_CLOCK_WARNING_3 or 7355,
    ["Map Ping"] = SOUNDKIT.MAP_PING or 3175,
    ["Tell Message"] = SOUNDKIT.TELL_MESSAGE or 3081,
    ["LFG Denied"] = SOUNDKIT.LFG_DENIED or 8959,
    ["GM Chat Warning"] = SOUNDKIT.GM_CHAT_WARNING or 12888,
    ["PVP Enter Queue"] = SOUNDKIT.PVP_ENTER_QUEUE or 8458,
    ["Loot Coin"] = SOUNDKIT.LOOT_WINDOW_COIN_SOUND or 120,
    ["Arrow Whoosh"] = (function()
      if SOUNDKIT then
        for k, v in pairs(SOUNDKIT) do
          if type(k) == "string" and type(v) == "number" then
            if string.find(k, "ARROW", 1, true) or string.find(k, "SWOOSH", 1, true) or string.find(k, "WHOOSH", 1, true) then
              return v
            end
          end
        end
      end
      return (SOUNDKIT and SOUNDKIT.UI_EPICLOOT_TOAST) or 31578
    end)(),
    ["Fishing Reel"] = SOUNDKIT.FISHING_REEL_IN or 3407,
    ["UI Garrison Toast"] = SOUNDKIT.UI_GARRISON_TOAST or 44295,
    ["Auction Open"] = SOUNDKIT.AUCTION_WINDOW_OPEN or 5274,
    ["Boss Emote Warning"] = 37666,
    ["None"] = 0,
  }

  local SOUND_EVENTS = {
    {
      key = "interrupt",
      label = "Interrupt Available",
      desc = "Plays when an interrupt opportunity appears in slot 1.",
      enableKey = "interruptSound",
      idKey = "interruptSoundId",
      defaultId = SOUNDKIT.RAID_WARNING or 8959,
      defaultName = "RaidWarning",
    },
    {
      key = "stSwitch",
      label = "Single Target Mode",
      desc = "Plays when you switch to Single Target mode (keybind or command).",
      enableKey = "stSwitchSound",
      idKey = "stSwitchSoundId",
      defaultId = SOUNDKIT.MAP_PING or 3175,
      defaultName = "Map Ping",
    },
    {
      key = "aoeSwitch",
      label = "AoE Mode",
      desc = "Plays when you switch to AoE mode (keybind, command, or smart switch).",
      enableKey = "aoeSwitchSound",
      idKey = "aoeSwitchSoundId",
      defaultId = SOUNDKIT.PVP_ENTER_QUEUE or 8458,
      defaultName = "PVP Enter Queue",
    },
  }

  for _, evt in ipairs(SOUND_EVENTS) do
    local evtEnabled = hud[evt.enableKey]
    if evtEnabled == nil then evtEnabled = true end
    Checkbox(panel, 15, y, evt.label,
      function() return evtEnabled end,
      function(v)
        evtEnabled = v
        hud[evt.enableKey] = v
        Msg(evt.label .. " sound: " .. (v and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))
      end)
    y = y - 22
    Label(panel, 35, y, evt.desc, DIM, 10)
    y = y - 26

    local currentId = hud[evt.idKey] or evt.defaultId
    local currentName = evt.defaultName
    for name, sid in pairs(SOUND_IDS) do
      if sid == currentId then currentName = name break end
    end

    DropdownSelect(panel, 35, y, "Sound", SOUND_NAMES,
      function() return currentName end,
      function(v)
        currentName = v
        local sid = SOUND_IDS[v] or 0
        hud[evt.idKey] = sid
        if sid ~= 0 then
          CLF.PlayAddonSound(sid)
        end
      end)
    y = y - 40

    ActionButton(panel, 35, y, 120, "Preview", function()
      CLF.PlayEventSound(evt.key)
    end)
    y = y - 35
  end

  y = y - 10
  Label(panel, 15, y, "Custom sounds are bundled OGG files. If a custom sound fails to play, it falls back to RaidWarning.", DIM, 10)
end

-- ── §S7: Tab -- Data (SimC Info, Spell List) ──
local function BuildDataTab(panel)
  local config = GetConfig()
  local hud = config.hud or {}
  local y = -10

  Header(panel, 10, y, L["HEADER_SIMC_DATA"])
  y = y - 24
  local specName = config.spec and (config.spec.specName .. " " .. config.spec.className) or "Unknown"
  local specRole = config.spec and config.spec.role or "?"
  local specResource = config.spec and config.spec.resource or "?"
  Label(panel, 15, y, "Current Spec: |cFFFFD100" .. specName .. "|r  (" .. specRole .. ")", WHITE, 11)
  y = y - 18
  Label(panel, 15, y, "Primary Resource: |cFFFFD100" .. specResource .. "|r", GREY, 10)
  y = y - 18
  Label(panel, 15, y, "Data Source: |cFFFFD100SimulationCraft APL (auto-synced weekly)|r", GREY, 10)
  y = y - 18
  local aplCount = config.apl and #config.apl or 0
  local intCount = config.interrupts and #config.interrupts or 0
  Label(panel, 15, y, "APL Priority Rules: |cFFFFD100" .. aplCount .. "|r    Interrupt Rules: |cFFFFD100" .. intCount .. "|r", GREY, 10)
  y = y - 18
  Label(panel, 15, y, "Addon Version: |cFFFFD100v${ADDON_VERSION}|r    Interface: |cFFFFD100${WOW_INTERFACE}|r", GREY, 10)
  y = y - 30

  Header(panel, 10, y, L["HEADER_TRINKETS"])
  y = y - 24

  if not CLF._trinketScanDone and CLF.ScanEquippedTrinkets then
    pcall(CLF.ScanEquippedTrinkets)
  end

  local trinketSlots = { "trinket1", "trinket2" }
  local trinketLabels = { "Trinket 1 (Slot 13)", "Trinket 2 (Slot 14)" }
  for idx, slotName in ipairs(trinketSlots) do
    local t = CLF._trinkets and CLF._trinkets[slotName]
    if t then
      local statusColor, statusText
      if t.hasUse then
        statusColor = "|cFF00FF00"
        statusText = "ON-USE"
      else
        statusColor = "|cFFFF4444"
        statusText = "PASSIVE"
      end

      local row = CreateFrame("Frame", nil, panel)
      row:SetSize(380, 36)
      row:SetPoint("TOPLEFT", panel, "TOPLEFT", 15, y)

      local iconBg = row:CreateTexture(nil, "BACKGROUND")
      iconBg:SetSize(32, 32)
      iconBg:SetPoint("LEFT", row, "LEFT", 0, 0)
      if t.icon then
        iconBg:SetTexture(t.icon)
      else
        iconBg:SetColorTexture(0.2, 0.2, 0.2, 0.8)
      end

      local statusDot = row:CreateTexture(nil, "OVERLAY")
      statusDot:SetSize(10, 10)
      statusDot:SetPoint("TOPLEFT", iconBg, "TOPRIGHT", -6, 2)
      if t.hasUse then
        statusDot:SetColorTexture(0, 0.9, 0, 1)
      else
        statusDot:SetColorTexture(0.9, 0.2, 0.2, 1)
      end

      local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      nameText:SetPoint("LEFT", iconBg, "RIGHT", 6, 4)
      nameText:SetText(statusColor .. (t.itemName or "Unknown Item") .. "|r")
      nameText:SetFont(nameText:GetFont() or "Fonts\\\\FRIZQT__.TTF", 11)

      local detailText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      detailText:SetPoint("TOPLEFT", nameText, "BOTTOMLEFT", 0, -2)
      if t.hasUse then
        local cdRemaining, ready = 0, true
        if CLF.GetTrinketCooldown then cdRemaining, ready = CLF.GetTrinketCooldown(slotName) end
        local cdStr = ready and "|cFF00FF00Ready|r" or ("|cFFFF6600CD: " .. string.format("%.0f", cdRemaining or 0) .. "s|r")
        detailText:SetText(statusColor .. statusText .. "|r  |cFFAAAAAA" .. (t.spellName or "") .. "|r  " .. cdStr)
      else
        detailText:SetText(statusColor .. statusText .. "|r  |cFF888888No active ability|r")
      end
      detailText:SetFont(detailText:GetFont() or "Fonts\\\\FRIZQT__.TTF", 9)

      y = y - 40
    else
      Label(panel, 15, y, trinketLabels[idx] .. ":  |cFF888888Empty|r", DIM, 10)
      y = y - 20
    end
  end

  local trinketPrioStr = "Not available"
  if CLF._trinketPriority then
    trinketPrioStr = "T1=" .. (CLF._trinketPriority["trinket1"] or "?") .. "  T2=" .. (CLF._trinketPriority["trinket2"] or "?")
  end
  Label(panel, 15, y, "SimC Trinket Priority: |cFFFFD100" .. trinketPrioStr .. "|r    |cFF888888(lower = higher prio)|r", GREY, 9)
  y = y - 30

  Header(panel, 10, y, L["HEADER_SPELL_PRIORITY"])
  y = y - 22
  Label(panel, 15, y, "Uncheck spells to exclude them from the rotation.", DIM, 9)
  y = y - 16
  Label(panel, 15, y, "|cFF00FF00+|r = known & on bar    |cFFFF8800?|r = known but not on bar    |cFFFF4444-|r = not talented", DIM, 9)
  y = y - 16
  Label(panel, 15, y, "Only spells placed on your action bars are used in the rotation.", DIM, 9)
  y = y - 20

  wipe(spellCheckboxes)
  if not config._disabledSpells then config._disabledSpells = {} end

  for i, entry in ipairs(config.apl or {}) do
    local spellName = entry.spellName
    local isKnown = CLF.IsSpellKnown and CLF.IsSpellKnown(spellName) or false
    local cleanKey = string.lower(string.gsub(spellName, "_", " "))
    local onBar = CLF._spellSlots and CLF._spellSlots[cleanKey] and true or false
    local isDisabled = config._disabledSpells[spellName]
    local modeTag = entry.mode and entry.mode ~= "both" and (" [" .. string.upper(entry.mode) .. "]") or ""
    local statusColor, statusIcon, barTag
    if isKnown and onBar then
      statusColor = "|cFF00FF00"
      statusIcon = "+"
      barTag = ""
    elseif isKnown and not onBar then
      statusColor = "|cFFFF8800"
      statusIcon = "?"
      barTag = " |cFFFF8800(Not On Bar)|r"
    else
      statusColor = "|cFFFF4444"
      statusIcon = "-"
      barTag = " |cFFFF4444(Not Found)|r"
    end

    local cb = Checkbox(panel, 15, y,
      statusColor .. statusIcon .. "|r  [" .. entry.priority .. "] " .. spellName .. modeTag .. barTag,
      function() return not isDisabled end,
      function(v)
        if v then
          config._disabledSpells[spellName] = nil
        else
          config._disabledSpells[spellName] = true
        end
        Msg(spellName .. (v and " |cFF00FF00enabled|r" or " |cFFFF0000disabled|r") .. " -- reload to apply")
      end)
    spellCheckboxes[i] = cb
    y = y - 24
  end

  y = y - 10
  ActionButton(panel, 15, y, 120, L["BTN_ENABLE_ALL"], function()
    local c = GetConfig()
    c._disabledSpells = {}
    Msg(L["ALL_SPELLS_ENABLED"])
  end)
  ActionButton(panel, 145, y, 120, L["BTN_DISABLE_UNKNOWN"], function()
    local c = GetConfig()
    if not c._disabledSpells then c._disabledSpells = {} end
    for _, entry in ipairs(c.apl or {}) do
      if CLF.IsSpellKnown and not CLF.IsSpellKnown(entry.spellName, entry.spellId) then
        c._disabledSpells[entry.spellName] = true
      end
    end
    Msg(L["UNKNOWN_SPELLS_DISABLED"])
  end)
  y = y - 35
  Label(panel, 15, y, "Type |cFF00FF00/reload|r in chat if changes need a full UI reload.", DIM, 10)
end

-- ── §S6: Tab -- Profiles ──
local function GetProfileNames()
  local names = {}
  local seen = {}
  if CLF_Profiles then
    for name, _ in pairs(CLF_Profiles) do
      names[#names + 1] = name
      seen[name] = true
    end
  end
  if not seen["Default"] then
    names[#names + 1] = "Default"
  end
  table.sort(names)
  return names
end

local function ApplyHudToConfig(sourceHud, config)
  if not sourceHud or not config then return end
  config.hud = DeepCopyHud(sourceHud)
  local defaults = CLF_DefaultConfig and CLF_DefaultConfig.hud
  if defaults then
    for k, v in pairs(defaults) do
      if config.hud[k] == nil then
        if type(v) == "table" then
          config.hud[k] = DeepCopyHud(v)
        else
          config.hud[k] = v
        end
      end
    end
  end
end

local function LoadProfile(name)
  local config = GetConfig()
  if not config then return end
  CLF_CharConfig.activeProfile = name
  local source = CLF_Profiles and CLF_Profiles[name]
  if not source and name == "Default" and CLF_DefaultConfig then
    source = CLF_DefaultConfig
  end
  if source and source.hud then
    ApplyHudToConfig(source.hud, config)
  end
  SyncActiveProfile()
  Msg("Loaded profile: |cFFFFD100" .. name .. "|r")
  if CLF.RefreshHUD then CLF.RefreshHUD() end
  if CLF.RebuildSettingsPanel then CLF.RebuildSettingsPanel() end
end

local function SaveCurrentToProfile(name)
  if not CLF_Profiles then CLF_Profiles = {} end
  local config = GetConfig()
  CLF_Profiles[name] = { hud = DeepCopyHud(config and config.hud or {}), _v = 2 }
  CLF_CharConfig.activeProfile = name
  Msg("Saved profile: |cFFFFD100" .. name .. "|r")
  if CLF.RebuildSettingsPanel then CLF.RebuildSettingsPanel() end
end

local function ProfileDropdown(parent, x, y, w, label, onClick)
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  frame:SetSize(w + 120, 30)

  local lbl = frame:CreateFontString(nil, "OVERLAY")
  lbl:SetFont("Fonts\\\\FRIZQT__.TTF", 10, "OUTLINE")
  lbl:SetTextColor(GOLD[1], GOLD[2], GOLD[3], 0.9)
  lbl:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -2)
  lbl:SetText(label)

  local btn = CreateFrame("Button", nil, frame, "BackdropTemplate")
  btn:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -16)
  btn:SetSize(w, 22)
  btn:SetBackdrop({
    bgFile = "Interface\\\\Buttons\\\\WHITE8x8",
    edgeFile = "Interface\\\\Buttons\\\\WHITE8x8",
    edgeSize = 1,
  })
  btn:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
  btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.6)

  local selectedText = btn:CreateFontString(nil, "OVERLAY")
  selectedText:SetFont("Fonts\\\\FRIZQT__.TTF", 10, "")
  selectedText:SetTextColor(1, 1, 1, 0.9)
  selectedText:SetPoint("LEFT", btn, "LEFT", 8, 0)
  selectedText:SetPoint("RIGHT", btn, "RIGHT", -20, 0)
  selectedText:SetJustifyH("LEFT")
  selectedText:SetText("")

  local arrow = btn:CreateFontString(nil, "OVERLAY")
  arrow:SetFont("Fonts\\\\FRIZQT__.TTF", 9, "")
  arrow:SetTextColor(0.7, 0.7, 0.7, 1)
  arrow:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
  arrow:SetText("v")

  local menuFrame = CreateFrame("Frame", nil, btn, "BackdropTemplate")
  menuFrame:SetBackdrop({
    bgFile = "Interface\\\\Buttons\\\\WHITE8x8",
    edgeFile = "Interface\\\\Buttons\\\\WHITE8x8",
    edgeSize = 1,
  })
  menuFrame:SetBackdropColor(0.08, 0.08, 0.08, 0.95)
  menuFrame:SetBackdropBorderColor(GOLD[1] * 0.5, GOLD[2] * 0.5, GOLD[3] * 0.5, 0.8)
  menuFrame:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -1)
  menuFrame:SetFrameStrata("DIALOG")
  menuFrame:Hide()

  local function RefreshMenu()
    for _, child in ipairs({menuFrame:GetChildren()}) do child:Hide(); child:SetParent(nil) end
    local names = GetProfileNames()
    local charName = DetaintStr(UnitName("player")) or "Unknown"
    local realmName = DetaintStr(GetRealmName()) or "Unknown"
    local charKey = charName .. " - " .. realmName
    local hasDefault = false
    for _, n in ipairs(names) do
      if n == "Default" then hasDefault = true; break end
    end
    if not hasDefault then table.insert(names, 1, "Default") end

    local itemH = 18
    menuFrame:SetSize(w, math.max(#names * itemH + 4, itemH + 4))

    for i, name in ipairs(names) do
      local item = CreateFrame("Button", nil, menuFrame)
      item:SetSize(w - 4, itemH)
      item:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 2, -(2 + (i - 1) * itemH))

      local active = (name == (CLF_CharConfig.activeProfile or "Default"))
      local itemText = item:CreateFontString(nil, "OVERLAY")
      itemText:SetFont("Fonts\\\\FRIZQT__.TTF", 10, "")
      itemText:SetPoint("LEFT", item, "LEFT", 6, 0)
      if active then
        itemText:SetText("|cFF00FF00\\226\\156\\147|r " .. name)
      else
        itemText:SetText(name)
      end
      itemText:SetTextColor(1, 1, 1, 0.9)

      item:SetScript("OnEnter", function(self)
        self.bg = self.bg or self:CreateTexture(nil, "BACKGROUND")
        self.bg:SetAllPoints()
        self.bg:SetColorTexture(GOLD[1] * 0.3, GOLD[2] * 0.3, GOLD[3] * 0.3, 0.5)
        self.bg:Show()
      end)
      item:SetScript("OnLeave", function(self)
        if self.bg then self.bg:Hide() end
      end)
      item:SetScript("OnClick", function()
        menuFrame:Hide()
        selectedText:SetText(name)
        if onClick then onClick(name) end
      end)
    end
  end

  btn:SetScript("OnClick", function()
    if menuFrame:IsShown() then
      menuFrame:Hide()
    else
      RefreshMenu()
      menuFrame:Show()
    end
  end)

  menuFrame:SetScript("OnShow", function() RefreshMenu() end)

  frame.SetSelected = function(_, text) selectedText:SetText(text or "") end

  return frame
end

local function ProfileEditBox(parent, x, y, w, label)
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  frame:SetSize(w + 80, 30)

  local lbl = frame:CreateFontString(nil, "OVERLAY")
  lbl:SetFont("Fonts\\\\FRIZQT__.TTF", 10, "OUTLINE")
  lbl:SetTextColor(GOLD[1], GOLD[2], GOLD[3], 0.9)
  lbl:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -2)
  lbl:SetText(label)

  local box = CreateFrame("EditBox", nil, frame, "BackdropTemplate")
  box:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -16)
  box:SetSize(w, 22)
  box:SetBackdrop({
    bgFile = "Interface\\\\Buttons\\\\WHITE8x8",
    edgeFile = "Interface\\\\Buttons\\\\WHITE8x8",
    edgeSize = 1,
  })
  box:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
  box:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.6)
  box:SetFont("Fonts\\\\FRIZQT__.TTF", 10, "")
  box:SetTextColor(1, 1, 1, 0.9)
  box:SetTextInsets(8, 8, 0, 0)
  box:SetAutoFocus(false)
  box:SetMaxLetters(40)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

  frame.editBox = box
  return frame
end

local function BuildProfilesTab(panel)
  local y = -10

  if not CLF_Profiles then CLF_Profiles = {} end
  if not CLF_CharConfig then CLF_CharConfig = {} end

  local charName = DetaintStr(UnitName("player")) or "Unknown"
  local realmName = DetaintStr(GetRealmName()) or "Unknown"
  local charKey = charName .. " - " .. realmName
  local activeProfile = CLF_CharConfig.activeProfile or "Default"

  Header(panel, 10, y, L["HEADER_PROFILES"])
  y = y - 20
  Label(panel, 15, y, "Manage profiles to keep different settings per character or spec. All changes auto-save instantly.", GREY, 9)
  y = y - 24

  ActionButton(panel, 15, y, 140, "Reset Profile", function()
    local config = GetConfig()
    if config and CLF_DefaultConfig and CLF_DefaultConfig.hud then
      ApplyHudToConfig(CLF_DefaultConfig.hud, config)
    end
    SyncActiveProfile()
    local curActive = CLF_CharConfig.activeProfile or "Default"
    Msg("Profile |cFFFFD100" .. curActive .. "|r reset to default values")
    if CLF.RefreshHUD then CLF.RefreshHUD() end
    if CLF.RebuildSettingsPanel then CLF.RebuildSettingsPanel() end
  end)
  local currentLabel = Label(panel, 200, y + 2, "Current Profile: |cFFFFD100" .. activeProfile .. "|r", WHITE, 11)
  y = y - 36

  Label(panel, 15, y, "You can either create a new profile by entering a name in the editbox, or choose one of the already existing profiles.", GREY, 9)
  y = y - 20

  local newBox = ProfileEditBox(panel, 15, y, 200, "New")
  local charDefault = charName .. " - " .. realmName

  local existingDropdown = ProfileDropdown(panel, 240, y, 180, "Existing Profiles", function(name)
    LoadProfile(name)
  end)
  existingDropdown:SetSelected(activeProfile)
  y = y - 54

  ActionButton(panel, 15, y, 120, "Create Profile", function()
    local name = newBox.editBox:GetText()
    if not name or name == "" then
      Msg("Enter a profile name first")
      return
    end
    name = string.match(name, "^%s*(.-)%s*$")
    if name == "" then
      Msg("Enter a profile name first")
      return
    end
    SaveCurrentToProfile(name)
    newBox.editBox:SetText("")
    newBox.editBox:ClearFocus()
    existingDropdown:SetSelected(name)
  end)
  y = y - 36

  Label(panel, 15, y, "Copy the settings from one existing profile into the currently active profile.", GREY, 9)
  y = y - 20
  ProfileDropdown(panel, 15, y, 200, "Copy From", function(name)
    local source = CLF_Profiles and CLF_Profiles[name]
    if not source then
      if name == "Default" and CLF_DefaultConfig then
        source = CLF_DefaultConfig
      else
        Msg("Profile not found: " .. name)
        return
      end
    end
    if source and source.hud then
      local config = GetConfig()
      if config then
        ApplyHudToConfig(source.hud, config)
      end
      SyncActiveProfile()
      local curActive = CLF_CharConfig.activeProfile or "Default"
      Msg("Copied settings from |cFFFFD100" .. name .. "|r into |cFFFFD100" .. curActive .. "|r")
      if CLF.RefreshHUD then CLF.RefreshHUD() end
      if CLF.RebuildSettingsPanel then CLF.RebuildSettingsPanel() end
    end
  end)
  y = y - 56

  Label(panel, 15, y, "Delete existing and unused profiles from the database to save space, and cleanup the SavedVariables file.", GREY, 9)
  y = y - 20
  ProfileDropdown(panel, 15, y, 200, "Delete a Profile", function(name)
    local curActive = CLF_CharConfig.activeProfile or "Default"
    if name == curActive then
      Msg("Cannot delete the active profile. Switch to another profile first.")
      return
    end
    if name == "Default" then
      Msg("Cannot delete the Default profile.")
      return
    end
    if CLF_Profiles then
      CLF_Profiles[name] = nil
    end
    Msg("Deleted profile: |cFFFFD100" .. name .. "|r")
  end)
  y = y - 56

  Header(panel, 10, y, L["HEADER_AUTO_CREATE"])
  y = y - 28
  Checkbox(panel, 15, y, "Automatically create a character-specific profile on login",
    function() return CLF_Config and CLF_Config._autoCreateCharProfile end,
    function(v)
      local config = GetConfig()
      if config then config._autoCreateCharProfile = v end
    end)
end

-- ── §S7: Tab -- Issues & Debug ──
local issueLabels = {}

local function BuildTroubleshootTab(panel)
  local hud = GetHud()
  local y = -10

  -- ── Live Diagnostics ──
  Header(panel, 10, y, L["HEADER_DIAGNOSTICS"])
  y = y - 24
  local diagY = y
  local function RefreshDiagLabels()
    for _, lbl in ipairs(issueLabels) do lbl:Hide() end
    wipe(issueLabels)
    local results = CLF.RunDiagnostics and CLF.RunDiagnostics() or {}
    local ly = diagY
    for _, r in ipairs(results) do
      local icon = r.severity == "ok" and "|cFF00FF00[OK]|r" or (r.severity == "warn" and "|cFFFFAA00[!]|r" or "|cFFFF3333[X]|r")
      local l = Label(panel, 18, ly, icon .. "  " .. r.text, WHITE, 10)
      table.insert(issueLabels, l)
      ly = ly - 16
    end
    return ly
  end
  y = RefreshDiagLabels()
  y = y - 10

  ActionButton(panel, 15, y, 160, "Re-run Diagnostics", function()
    RefreshDiagLabels()
    Msg("Diagnostics refreshed -- check Issues tab")
  end)
  y = y - 40

  -- ── Debug Logging ──
  Header(panel, 10, y, L["HEADER_DEBUG"])
  y = y - 30
  Checkbox(panel, 15, y, "Enable Debug Mode (log rotation decisions to chat)",
    function() return CLF.debugEnabled end,
    function(v)
      CLF.debugEnabled = v
      if not v then CLF.debugVerbose = false end
      local h = GetHud()
      h.debugMode = v
      Msg("Debug: " .. (v and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))
    end)
  y = y - 28
  Checkbox(panel, 15, y, "Verbose Mode (log every condition evaluation)",
    function() return CLF.debugVerbose end,
    function(v)
      CLF.debugVerbose = v
      if v then CLF.debugEnabled = true; GetHud().debugMode = true end
      Msg("Verbose: " .. (v and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))
    end)
  y = y - 28
  Checkbox(panel, 15, y, "Show Condition Text (debug evaluation below HUD)",
    function() return hud.showCondition end,
    function(v) hud.showCondition = v; if CLF.RefreshHUD then CLF.RefreshHUD() end end)
  y = y - 40

  -- ── Diagnostic Logging ──
  Header(panel, 10, y, "Diagnostic Logging")
  y = y - 24
  Label(panel, 15, y, "When enabled, captures combat events, queue snapshots, and system health data.", DIM, 9)
  y = y - 18
  Label(panel, 15, y, "End-users can use this to gather logs for bug reports.", DIM, 9)
  y = y - 24
  Checkbox(panel, 15, y, "Enable Diagnostic Logging",
    function() return DMGA_WD_Config and DMGA_WD_Config.enabled end,
    function(v)
      if v then
        if DMGA_WD_Enable then DMGA_WD_Enable() end
      else
        if DMGA_WD_Disable then DMGA_WD_Disable() end
      end
    end)
  y = y - 28
  ActionButton(panel, 15, y, 160, "Open Event Viewer", function()
    if not DMGA_WD_Config or not DMGA_WD_Config.enabled then
      Msg("Enable diagnostic logging first")
      return
    end
    SlashCmdList["DMGAWD"]("")
  end)
  y = y - 40

  -- ── Condition Errors ──
  Header(panel, 10, y, L["HEADER_COND_ERRORS"])
  y = y - 22
  Label(panel, 15, y, "These spells hit errors during evaluation. They still appear in the HUD (safe fallback).", DIM, 9)
  y = y - 20

  local condErrors = CLF.GetConditionErrors and CLF.GetConditionErrors() or {}
  local ceFound = false
  for spellName, info in pairs(condErrors) do
    ceFound = true
    Label(panel, 18, y, "|cFFFF6644" .. spellName .. "|r  (x" .. info.count .. ")", WHITE, 10)
    y = y - 14
    local errShort = string.sub(info.lastErr, 1, 90)
    Label(panel, 28, y, "|cFF888888" .. errShort .. "|r", DIM, 8)
    y = y - 18
  end
  if not ceFound then
    Label(panel, 18, y, "|cFF00FF00No condition errors|r", GREEN, 10)
    y = y - 18
  end
  y = y - 10

  -- ── Issue Log ──
  Header(panel, 10, y, L["HEADER_ISSUE_LOG"])
  y = y - 22

  local issueLog = CLF.GetIssueLog and CLF.GetIssueLog() or {}
  if #issueLog == 0 then
    Label(panel, 18, y, "|cFF00FF00No issues recorded|r", GREEN, 10)
    y = y - 18
  else
    local startIdx = math.max(1, #issueLog - 24)
    for i = #issueLog, startIdx, -1 do
      local entry = issueLog[i]
      local countStr = entry.count > 1 and (" (x" .. entry.count .. ")") or ""
      local catColor = entry.category == "Runtime" and "|cFFFF3333" or (entry.category == "Condition" and "|cFFFF6644" or "|cFFFFAA00")
      Label(panel, 18, y, "|cFF777777" .. entry.time .. "|r  " .. catColor .. "[" .. entry.category .. "]|r  " .. entry.message .. countStr, WHITE, 9)
      y = y - 14
      if entry.details and entry.details ~= "" then
        local short = string.sub(entry.details, 1, 80)
        Label(panel, 30, y, "|cFF666666" .. short .. "|r", DIM, 8)
        y = y - 12
      end
    end
  end
  y = y - 10

  ActionButton(panel, 15, y, 120, "Clear Log", function()
    if CLF.ClearIssueLog then CLF.ClearIssueLog() end
    Msg("Issue log cleared")
  end)
  ActionButton(panel, 145, y, 120, "Dump to Chat", function()
    local log = CLF.GetIssueLog and CLF.GetIssueLog() or {}
    if #log == 0 then
      Msg("No issues to dump")
      return
    end
    print("|cFFD4A632[DMGAssist]|r === Issue Log (" .. #log .. " entries) ===")
    for _, e in ipairs(log) do
      local countStr = e.count > 1 and (" (x" .. e.count .. ")") or ""
      print(e.time .. " [" .. e.category .. "] " .. e.message .. countStr)
      if e.details and e.details ~= "" then print("   " .. e.details) end
    end
  end)
  y = y - 40

  -- ── Quick Fix Tools ──
  Header(panel, 10, y, L["HEADER_QUICK_FIX"])
  y = y - 28
  ActionButton(panel, 15, y, 155, "Run Spell Check", function()
    SlashCmdList["CLF"]("spells")
  end)
  ActionButton(panel, 180, y, 155, "Show Full Status", function()
    SlashCmdList["CLF"]("status")
  end)
  y = y - 30
  ActionButton(panel, 15, y, 155, "Check Glow Settings", function()
    SlashCmdList["CLF"]("glows")
  end)
  ActionButton(panel, 180, y, 155, "Auto-Fix Glows", function()
    SlashCmdList["CLF"]("fixglows")
  end)
  y = y - 30
  ActionButton(panel, 15, y, 155, "Rescan Keybinds", function()
    if CLF.ScanKeybinds then CLF.ScanKeybinds() end
    Msg("Keybinds rescanned")
  end)
  ActionButton(panel, 180, y, 155, "Rebuild APL Cache", function()
    CLF._filteredAPL = nil
    CLF.InvalidateSpellKnownCache()
    if CLF.BuildFilteredAPL then CLF.BuildFilteredAPL() end
    Msg("APL cache rebuilt")
  end)
  y = y - 30
  ActionButton(panel, 15, y, 155, "Reset All Errors", function()
    if CLF.ResetErrors then CLF.ResetErrors() end
    Msg("All errors cleared")
  end)
  y = y - 40

  -- ── Common Issues FAQ ──
  Header(panel, 10, y, L["HEADER_COMMON_ISSUES"])
  y = y - 22
  local faq = {
    { q = "HUD not appearing?",
      a = "/dmga show -- or /dmga reset. Check OOC mode in Combat tab." },
    { q = "Spells missing?",
      a = "Use Spell Check above. Untalented abilities are auto-filtered." },
    { q = "Addon conflicts?",
      a = "Try Auto-Fix Glows. Disable other addon glow/overlay features." },
    { q = "Performance?",
      a = "Reduce Queue Slots or disable Prediction in Display tab." },
  }
  for _, f in ipairs(faq) do
    Label(panel, 15, y, "|cFFFFD100" .. f.q .. "|r", WHITE, 10)
    y = y - 14
    Label(panel, 25, y, f.a, DIM, 9)
    y = y - 22
  end

  y = y - 5
  Label(panel, 15, y, "Report bugs at: |cFFFFD100curseforge.com/wow/addons/dmgassist|r", {0.85, 0.75, 0.3}, 10)
end

-- ── §S8: Static Popup for Reset Confirmation ──
StaticPopupDialogs["CLF_CONFIRM_RESET"] = {
  text = "Reset ALL DMGAssist settings to defaults? This cannot be undone.",
  button1 = "Reset",
  button2 = "Cancel",
  OnAccept = function()
    CLF_Config = CLF_DefaultConfig
    CLF_Position = {}
    CLF_Profiles = {}
    CLF_CharConfig = {}
    CLF.SafeReload()
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

-- ── §S9: Main Settings Frame Builder ──
-- Creates the tabbed settings window and wires up tab switching.
function CLF.CreateSettingsPanel()
  if settingsFrame then
    if settingsFrame:IsShown() then
      settingsFrame:Hide()
    else
      settingsFrame:Show()
    end
    return
  end
  local function OnSettingsShow()
    if CLF.InitConsumables then
      SafeCall(CLF.InitConsumables, "SettingsRescan")
    end
  end

  local FRAME_W = 920
  local FRAME_H = 620

  settingsFrame = CreateFrame("Frame", "CLF_SettingsFrame", UIParent, "BackdropTemplate")
  settingsFrame:SetSize(FRAME_W, FRAME_H)
  settingsFrame:SetPoint("CENTER")
  settingsFrame:SetBackdrop({
    bgFile = "Interface\\\\Buttons\\\\WHITE8x8",
    edgeFile = "Interface\\\\Buttons\\\\WHITE8x8",
    edgeSize = 2,
  })
  settingsFrame:SetBackdropColor(BG_DARK[1], BG_DARK[2], BG_DARK[3], BG_DARK[4])
  settingsFrame:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 0.5)
  settingsFrame:SetMovable(true)
  settingsFrame:EnableMouse(true)
  settingsFrame:RegisterForDrag("LeftButton")
  settingsFrame:SetScript("OnDragStart", settingsFrame.StartMoving)
  settingsFrame:SetScript("OnDragStop", settingsFrame.StopMovingOrSizing)
  settingsFrame:SetFrameStrata("DIALOG")
  settingsFrame:SetClampedToScreen(true)
  settingsFrame:SetScript("OnShow", function()
    OnSettingsShow()
    if CLF.RebuildSettingsPanel then CLF.RebuildSettingsPanel() end
  end)

  tinsert(UISpecialFrames, "CLF_SettingsFrame")

  local titleBar = CreateFrame("Frame", nil, settingsFrame, "BackdropTemplate")
  titleBar:SetPoint("TOPLEFT", 0, 0)
  titleBar:SetPoint("TOPRIGHT", 0, 0)
  titleBar:SetHeight(34)
  titleBar:SetBackdrop({ bgFile = "Interface\\\\Buttons\\\\WHITE8x8" })
  titleBar:SetBackdropColor(0.12, 0.1, 0.06, 0.95)

  local titleText = titleBar:CreateFontString(nil, "OVERLAY")
  titleText:SetFont("Fonts\\\\FRIZQT__.TTF", 14, "OUTLINE")
  titleText:SetPoint("LEFT", titleBar, "LEFT", 12, 0)
  titleText:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
  titleText:SetText(L["SETTINGS_TITLE"])

  local config = GetConfig()
  local specStr = config.spec and (config.spec.specName .. " " .. config.spec.className) or "Unknown"
  local verText = titleBar:CreateFontString(nil, "OVERLAY")
  verText:SetFont("Fonts\\\\FRIZQT__.TTF", 9, "")
  verText:SetPoint("LEFT", titleText, "RIGHT", 10, 0)
  verText:SetTextColor(0.5, 0.5, 0.5)
  verText:SetText("v${ADDON_VERSION}  |  " .. specStr)

  local closeBtn = CreateFrame("Button", nil, settingsFrame, "UIPanelCloseButton")
  closeBtn:SetPoint("TOPRIGHT", settingsFrame, "TOPRIGHT", -2, -2)
  closeBtn:SetScript("OnClick", function() settingsFrame:Hide() end)

  local tabs = {
    { id = "setup",       label = L["TAB_SETUP"] },
    { id = "display",     label = L["TAB_DISPLAY"] },
    { id = "combat",      label = L["TAB_COMBAT"] },
    { id = "consumables", label = L["TAB_CONSUMABLES"] },
    { id = "sounds",      label = L["TAB_SOUNDS"] },
    { id = "data",        label = L["TAB_SIMC"] },
    { id = "profiles",    label = L["TAB_PROFILES"] },
    { id = "troubleshoot", label = L["TAB_ISSUES"] },
  }

  local tabBarY = -38
  local tabW = math.floor((FRAME_W - 16 - (#tabs - 1) * 2) / #tabs)
  for i, tab in ipairs(tabs) do
    local btn = CreateFrame("Button", nil, settingsFrame, "BackdropTemplate")
    btn:SetSize(tabW, 26)
    btn:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 8 + (i - 1) * (tabW + 2), tabBarY)
    btn:SetBackdrop({
      bgFile = "Interface\\\\Buttons\\\\WHITE8x8",
      edgeFile = "Interface\\\\Buttons\\\\WHITE8x8",
      edgeSize = 1,
    })
    local bt = btn:CreateFontString(nil, "OVERLAY")
    bt:SetFont("Fonts\\\\FRIZQT__.TTF", 9, "OUTLINE")
    bt:SetPoint("CENTER")
    bt:SetText(tab.label)
    btn.label = bt
    btn:SetScript("OnClick", function() CLF.SwitchSettingsTab(tab.id) end)
    tabButtons[tab.id] = btn
  end

  local contentY = tabBarY - 30
  for _, tab in ipairs(tabs) do
    local sf = CreateFrame("ScrollFrame", nil, settingsFrame, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 6, contentY)
    sf:SetPoint("BOTTOMRIGHT", settingsFrame, "BOTTOMRIGHT", -28, 10)
    local content = CreateFrame("Frame", nil, sf)
    local contentHeight = 1200
    if tab.id == "data" then
      local aplCount = config.apl and #config.apl or 0
      contentHeight = math.max(1200, 400 + aplCount * 26)
    end
    content:SetSize(FRAME_W - 50, contentHeight)
    sf:SetScrollChild(content)
    tabPanels[tab.id] = { scroll = sf, content = content }
    sf:Hide()
  end

  local function ClearPanel(panel)
    for _, child in ipairs({panel:GetChildren()}) do
      child:Hide()
      child:SetParent(nil)
    end
    for _, region in ipairs({panel:GetRegions()}) do
      region:Hide()
      region:SetParent(nil)
    end
  end

  local function RebuildAllTabs()
    for id, p in pairs(tabPanels) do
      ClearPanel(p.content)
    end
    BuildSetupTab(tabPanels["setup"].content)
    BuildDisplayTab(tabPanels["display"].content)
    BuildCombatTab(tabPanels["combat"].content)
    BuildConsumablesTab(tabPanels["consumables"].content)
    BuildSoundsTab(tabPanels["sounds"].content)
    BuildDataTab(tabPanels["data"].content)
    BuildProfilesTab(tabPanels["profiles"].content)
    BuildTroubleshootTab(tabPanels["troubleshoot"].content)
    CLF.SwitchSettingsTab(currentTab or "setup")
  end
  CLF.RebuildSettingsPanel = RebuildAllTabs

  BuildSetupTab(tabPanels["setup"].content)
  BuildDisplayTab(tabPanels["display"].content)
  BuildCombatTab(tabPanels["combat"].content)
  BuildConsumablesTab(tabPanels["consumables"].content)
  BuildSoundsTab(tabPanels["sounds"].content)
  BuildDataTab(tabPanels["data"].content)
  BuildProfilesTab(tabPanels["profiles"].content)
  BuildTroubleshootTab(tabPanels["troubleshoot"].content)

  CLF.SwitchSettingsTab("setup")
  settingsFrame:Show()
end

function CLF.SwitchSettingsTab(tabId)
  currentTab = tabId
  for id, p in pairs(tabPanels) do
    if id == tabId then p.scroll:Show() else p.scroll:Hide() end
  end
  for id, btn in pairs(tabButtons) do
    if id == tabId then
      btn:SetBackdropColor(GOLD[1]*0.3, GOLD[2]*0.3, GOLD[3]*0.3, 0.8)
      btn:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 0.7)
      btn.label:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    else
      btn:SetBackdropColor(0.1, 0.1, 0.12, 0.6)
      btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.3)
      btn.label:SetTextColor(0.6, 0.6, 0.6)
    end
  end
end

function CLF.ToggleSettings()
  CLF.CreateSettingsPanel()
end

CLF.OpenSettings = CLF.ToggleSettings
`;
}

/**
 * Generates the all-specs TOC file for the multi-spec combined addon.
 * Same load order as single-spec (LibStub → Helpers → Config → Engine → HUD → Settings → Core)
 * but the TOC notes reflect multi-spec support.
 *
 * @param allData - All spec data bundles.
 */
