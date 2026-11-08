-- Options.lua: the settings panel, in the game's own Options > AddOns > DMGAssist (Blizzard Settings API:
-- Settings.RegisterVerticalLayoutCategory / RegisterVerticalLayoutSubcategory / RegisterProxySetting /
-- CreateCheckbox / CreateSlider / CreateDropdown / RegisterAddOnCategory / OpenToCategory — identical on the
-- forever and live branches of Blizzard_Settings_Shared). Every control reads and writes DMGAssistDB and applies
-- immediately (no reload). Slash commands change the same values.

local _, ns = ...
local L = ns.L

local O = {}
ns.Options = O

local GENERAL_DEFAULTS = { enabled = true, burst = true, useAssisted = true, queue = 3, locked = false,
  mode = "st", autoDetect = true, aoeTargets = 3, fightLength = 300 }

local function Apply()
  if ns.Display and ns.Display.frame then
    ns.Display.Rebuild()
  end
  if ns.State then
    ns.State.modeOverride = nil
  end
end

local function Make(category, tbl, key, name, default, varType, tooltip)
  return Settings.RegisterProxySetting(category, "DMGASSIST_" .. key:upper(), varType, L[name], default,
    function()
      local v = tbl()[key]
      if v == nil then
        return default
      end
      return v
    end,
    function(value)
      tbl()[key] = value
      Apply()
    end), tooltip and L[tooltip] or nil
end

local function Check(category, tbl, key, name, default, tooltip)
  local setting, tip = Make(category, tbl, key, name, default, Settings.VarType.Boolean, tooltip)
  Settings.CreateCheckbox(category, setting, tip)
  return setting
end

local function Slider(category, tbl, key, name, default, minV, maxV, step, tooltip)
  local setting, tip = Make(category, tbl, key, name, default, Settings.VarType.Number, tooltip)
  local options = Settings.CreateSliderOptions(minV, maxV, step)
  if MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label then
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(v)
      if step < 1 then
        return string.format("%.2f", v)
      end
      return tostring(math.floor(v + 0.5))
    end)
  end
  Settings.CreateSlider(category, setting, options, tip)
  return setting
end

local function Choice(category, tbl, key, name, default, choices, tooltip)
  local setting, tip = Make(category, tbl, key, name, default, Settings.VarType.String, tooltip)
  local function GetOptions()
    local container = Settings.CreateControlTextContainer()
    for _, c in ipairs(choices) do
      container:Add(c[1], L[c[2]])
    end
    return container:GetData()
  end
  Settings.CreateDropdown(category, setting, GetOptions, tip)
  return setting
end

local function DB()
  return ns.db
end

local function HUD()
  return ns.Display.Settings()
end

O.settings = {}

function O.Register()
  if O.category or not (Settings and Settings.RegisterVerticalLayoutCategory and ns.db) then
    return O.category
  end
  local H = ns.Display.DEFAULTS
  local G = GENERAL_DEFAULTS
  local s = O.settings

  local main = Settings.RegisterVerticalLayoutCategory("DMGAssist")
  s.enabled = Check(main, DB, "enabled", "Show recommendations", G.enabled)
  s.burst = Check(main, DB, "burst", "Major cooldowns", G.burst,
    "Show the next major cooldown (the spells Blizzard's assistant leaves out) in its own icon.")
  s.useAssisted = Check(main, DB, "useAssisted", "Use Blizzard's Assisted Combat as backup", G.useAssisted,
    "Midnight only: confirms uncertain SimC lines and reveals hidden buffs. Forever has no Assisted Combat.")
  s.queue = Slider(main, DB, "queue", "Spells shown", G.queue, 1, 3, 1)
  s.locked = Check(main, DB, "locked", "Lock position", G.locked)

  local combat = Settings.RegisterVerticalLayoutSubcategory(main, L["Combat"])
  s.mode = Choice(combat, DB, "mode", "Primary target mode", G.mode, { { "st", "Single target" }, { "aoe", "AoE" } },
    "Used when targets can't be counted. The key binding switches during a fight.")
  s.autoDetect = Check(combat, DB, "autoDetect", "Auto-detect targets", G.autoDetect,
    "Count enemies in combat from their nameplates (nameplates must be shown).")
  s.aoeTargets = Slider(combat, DB, "aoeTargets", "Targets assumed in AoE mode", G.aoeTargets, 2, 10, 1)
  s.fightLength = Slider(combat, DB, "fightLength", "Assumed fight length (seconds)", G.fightLength, 30, 600, 10,
    "SimC holds or uses cooldowns based on how long the fight lasts.")
  s.hideOutOfCombat = Check(combat, HUD, "hideOutOfCombat", "Hide out of combat", H.hideOutOfCombat)
  s.showWithTarget = Check(combat, HUD, "showWithTarget", "Show when targeting an enemy", H.showWithTarget)

  local display = Settings.RegisterVerticalLayoutSubcategory(main, L["Display"])
  s.scale = Slider(display, HUD, "scale", "Scale", H.scale, 0.5, 2, 0.05)
  s.alpha = Slider(display, HUD, "alpha", "Opacity", H.alpha, 0.2, 1, 0.05)
  s.iconSize = Slider(display, HUD, "iconSize", "Main icon size", H.iconSize, 24, 96, 1)
  s.nextSize = Slider(display, HUD, "nextSize", "Next icon size", H.nextSize, 16, 80, 1)
  s.cdSize = Slider(display, HUD, "cdSize", "Cooldown icon size", H.cdSize, 16, 80, 1)
  s.spacing = Slider(display, HUD, "spacing", "Icon spacing", H.spacing, 0, 24, 1)
  s.padding = Slider(display, HUD, "padding", "Frame padding", H.padding, 0, 24, 1)
  s.queueAlpha = Slider(display, HUD, "queueAlpha", "Next icons opacity", H.queueAlpha, 0.2, 1, 0.05)
  s.dimGuesses = Check(display, HUD, "dimGuesses", "Dim uncertain picks", H.dimGuesses)
  s.background = Check(display, HUD, "background", "Background", H.background)
  s.bgAlpha = Slider(display, HUD, "bgAlpha", "Background opacity", H.bgAlpha, 0, 1, 0.05)
  s.border = Choice(display, HUD, "border", "Border", H.border,
    { { "none", "None" }, { "thin", "Thin" }, { "thick", "Thick" } })
  s.borderAlpha = Slider(display, HUD, "borderAlpha", "Border opacity", H.borderAlpha, 0, 1, 0.05)
  s.header = Check(display, HUD, "header", "Header (spec, mode, settings button)", H.header)
  s.keybind = Check(display, HUD, "keybind", "Keybind on icons", H.keybind)
  s.keybindSize = Slider(display, HUD, "keybindSize", "Keybind text size", H.keybindSize, 8, 24, 1)
  s.keybindPos = Choice(display, HUD, "keybindPos", "Keybind position", H.keybindPos,
    { { "TOPRIGHT", "Top right" }, { "TOPLEFT", "Top left" }, { "BOTTOMLEFT", "Bottom left" }, { "CENTER", "Center" } })
  s.spellNames = Check(display, HUD, "spellNames", "Spell names under icons", H.spellNames)
  s.nameSize = Slider(display, HUD, "nameSize", "Spell name size", H.nameSize, 8, 18, 1)
  s.labels = Check(display, HUD, "labels", "NOW / NEXT labels", H.labels)
  s.gcdBar = Check(display, HUD, "gcdBar", "GCD bar", H.gcdBar)
  s.glow = Choice(display, HUD, "glow", "Main icon glow", H.glow,
    { { "none", "None" }, { "border", "Steady" }, { "pulse", "Pulse" } })

  local advanced = Settings.RegisterVerticalLayoutSubcategory(main, L["Advanced"])
  s.debugText = Check(advanced, HUD, "debugText", "Show decision text under the HUD", H.debugText,
    "The queue with where each pick came from (SimC, assistant, Blizzard rules, guess).")

  Settings.RegisterAddOnCategory(main)
  O.category = main
  return main
end

function O.Open()
  local cat = O.Register()
  if cat and Settings.OpenToCategory then
    Settings.OpenToCategory(cat:GetID())
  end
end
