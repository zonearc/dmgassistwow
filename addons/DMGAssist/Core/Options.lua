-- Options.lua: the settings panel, in the game's own Options > AddOns > DMGAssist (Blizzard Settings API:
-- Settings.RegisterVerticalLayoutCategory / RegisterVerticalLayoutSubcategory / RegisterProxySetting /
-- CreateCheckbox / CreateSlider / CreateDropdown / CreateSettingsListSectionHeaderInitializer /
-- CreateSettingsButtonInitializer / RegisterAddOnCategory / OpenToCategory — identical on forever and live).
--
-- Layout follows what players like in the addons they rate best: the few choices everyone makes on the first page
-- (with sensible defaults), everything else grouped on sub-pages with section headers; the game's own panel gives
-- consistent spacing, search, and tooltips. Every control applies immediately; the HUD previews while the panel
-- is open so changes are visible as they are made. "Reset to defaults" restores every value on every page.

local _, ns = ...
local U, L = ns.U, ns.L

local O = {}
ns.Options = O

O.settings = {}   -- key -> setting
O.defaults = {}   -- key -> default value
O.layouts = {}    -- category -> layout

local function Apply()
  if ns.Display and ns.Display.frame then
    ns.Display.Rebuild()
  end
  if ns.State then
    ns.State.modeOverride = nil
  end
  if ns.Minimap then
    ns.Minimap.Apply()
  end
end

local function DB()
  return ns.db
end

local function HUD()
  return ns.Display.Settings()
end

local function Header(category, text)
  local layout = O.layouts[category]
  if layout and layout.AddInitializer and type(CreateSettingsListSectionHeaderInitializer) == "function" then
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L[text]))
  end
end

local function Button(category, label, text, onClick, tooltip)
  local layout = O.layouts[category]
  if layout and layout.AddInitializer and type(CreateSettingsButtonInitializer) == "function" then
    layout:AddInitializer(CreateSettingsButtonInitializer(L[label], L[text], onClick, tooltip and L[tooltip], true))
  end
end

local function Make(category, tbl, key, name, default, varType)
  local setting = Settings.RegisterProxySetting(category, "DMGASSIST_" .. key:upper(), varType, L[name], default,
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
    end)
  O.settings[key], O.defaults[key] = setting, default
  return setting
end

local function Tip(tooltip)
  return tooltip and L[tooltip] or nil
end

local function Check(category, tbl, key, name, default, tooltip)
  local setting = Make(category, tbl, key, name, default, Settings.VarType.Boolean)
  Settings.CreateCheckbox(category, setting, Tip(tooltip))
  return setting
end

local function Slider(category, tbl, key, name, default, minV, maxV, step, tooltip, unit)
  local setting = Make(category, tbl, key, name, default, Settings.VarType.Number)
  local options = Settings.CreateSliderOptions(minV, maxV, step)
  if MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label then
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(v)
      local text = step < 1 and string.format("%.2f", v) or tostring(math.floor(v + 0.5))
      return unit and (text .. unit) or text
    end)
  end
  Settings.CreateSlider(category, setting, options, Tip(tooltip))
  return setting
end

local function Choice(category, tbl, key, name, default, choices, tooltip)
  local setting = Make(category, tbl, key, name, default, Settings.VarType.String)
  local function GetOptions()
    local container = Settings.CreateControlTextContainer()
    local list = type(choices) == "function" and choices() or choices
    for _, c in ipairs(list) do
      container:Add(c[1], L[c[2]])
    end
    return container:GetData()
  end
  Settings.CreateDropdown(category, setting, GetOptions, Tip(tooltip))
  return setting
end

local function Category(name, parent)
  local category, layout
  if parent then
    category, layout = Settings.RegisterVerticalLayoutSubcategory(parent, L[name])
  else
    category, layout = Settings.RegisterVerticalLayoutCategory(name)
  end
  O.layouts[category] = layout
  return category
end

function O.ResetAll()
  for key, setting in pairs(O.settings) do
    if setting.SetValue then
      setting:SetValue(O.defaults[key])
    end
  end
  Apply()
  ns.U.Print(L["All settings are back to their defaults."])
end

local INTERRUPT_CHOICES = {
  { "smart", "Smart: all in the open world; dungeons/raids only what matters" },
  { "everywhere", "Every interruptible cast" },
  { "instances", "Only in dungeons and raids" },
  { "bossmods", "Only when DBM / BigWigs / LittleWigs calls it" },
  { "off", "Off" },
}
local DEFENSIVE_CHOICES = {
  { "smart", "Smart: boss mod warnings and low health" },
  { "bossmods", "Only boss mod warnings" },
  { "health", "Only low health" },
  { "off", "Off" },
}
local SOUND_LABELS = { interrupt = "Interrupt", defensive = "Defensive", bosscall = "Boss mod call",
  burst = "Major cooldown ready" }

function O.Register()
  if O.category or not (Settings and Settings.RegisterVerticalLayoutCategory and ns.db) then
    return O.category
  end
  local H = ns.Display.DEFAULTS
  local G = ns.DEFAULTS or {}

  ---------------------------------------------------------------- basic page
  local main = Category("DMGAssist")
  Header(main, "Recommendations")
  Check(main, DB, "enabled", "Show recommendations", true)
  Slider(main, DB, "queue", "Spells shown", G.queue or 3, 1, 3, 1, "The next spell, plus up to two after it.")
  Check(main, DB, "burst", "Major cooldowns", true,
    "Show the next major cooldown (the spells Blizzard's assistant leaves out) in its own icon.")
  Header(main, "Targets")
  Choice(main, DB, "mode", "Primary target mode", "st", { { "st", "Single target" }, { "aoe", "AoE" } },
    "Used when targets can't be counted. The key binding switches during a fight.")
  Check(main, DB, "autoDetect", "Auto-detect targets", true,
    "Count enemies in combat from their nameplates (enemy nameplates must be shown).")
  Header(main, "Help in combat")
  Choice(main, DB, "interruptMode", "Interrupts", "smart", INTERRUPT_CHOICES,
    "In dungeons and raids 'what matters' = your boss mod calls an interrupt or Blizzard marks the spell important.")
  Choice(main, DB, "defensiveMode", "Defensives", "smart", DEFENSIVE_CHOICES,
    "Suggests your next personal defensive before big hits your boss mod warns about, and when you are low.")
  Check(main, DB, "sounds", "Sound alerts", true, "Pick the sounds on the Alerts & Sounds page.")
  Header(main, "Look")
  Slider(main, HUD, "scale", "Scale", H.scale, 0.5, 2, 0.05)
  Check(main, HUD, "keybind", "Keybind on icons", H.keybind)
  Check(main, HUD, "highlight", "Highlight the button on your action bars", H.highlight,
    "Glows the real action button for the next spell (Blizzard bars, Bartender, ElvUI, Dominos).")
  Check(main, DB, "minimap", "Minimap button", true,
    "Left-click: settings. Right-click: menu. Shift-click: Watchdog report. Drag to move it.")
  Check(main, DB, "locked", "Lock position", true,
    "Unlock to drag the icons; they are also shown while this panel is open.")
  Button(main, "Keybinds", "Refresh keybinds", function()
    if SlashCmdList.DMGASSIST then
      SlashCmdList.DMGASSIST("keys")
    end
  end, "Re-read the keys bound to your action bars (also happens automatically).")
  Button(main, "Defaults", "Reset to defaults", O.ResetAll, "Every setting on every DMGAssist page.")

  ---------------------------------------------------------------- display
  local display = Category("Display", main)
  Header(display, "Layout")
  Slider(display, HUD, "iconSize", "Main icon size", H.iconSize, 24, 96, 1)
  Slider(display, HUD, "nextSize", "Next icon size", H.nextSize, 16, 80, 1)
  Slider(display, HUD, "cdSize", "Cooldown and defensive icon size", H.cdSize, 16, 80, 1)
  Slider(display, HUD, "spacing", "Icon spacing", H.spacing, 0, 24, 1)
  Slider(display, HUD, "padding", "Frame padding", H.padding, 0, 24, 1)
  Slider(display, HUD, "alpha", "Opacity", H.alpha, 0.2, 1, 0.05)
  Slider(display, HUD, "queueAlpha", "Next icons opacity", H.queueAlpha, 0.2, 1, 0.05)
  Header(display, "Frame")
  Check(display, HUD, "header", "Header (spec, mode, settings button)", H.header)
  Check(display, HUD, "background", "Background", H.background)
  Slider(display, HUD, "bgAlpha", "Background opacity", H.bgAlpha, 0, 1, 0.05)
  Choice(display, HUD, "border", "Border", H.border, { { "none", "None" }, { "thin", "Thin" }, { "thick", "Thick" } })
  Slider(display, HUD, "borderAlpha", "Border opacity", H.borderAlpha, 0, 1, 0.05)
  Header(display, "Text")
  Choice(display, HUD, "font", "Font", H.font, ns.Display.FontChoices,
    "Game fonts, plus any registered with LibSharedMedia.")
  Choice(display, HUD, "outline", "Outline", H.outline, ns.Display.OUTLINES)
  Slider(display, HUD, "keybindSize", "Keybind text size", H.keybindSize, 8, 24, 1)
  Choice(display, HUD, "keybindPos", "Keybind position", H.keybindPos,
    { { "TOPRIGHT", "Top right" }, { "TOPLEFT", "Top left" }, { "BOTTOMLEFT", "Bottom left" }, { "CENTER", "Center" } })
  Choice(display, HUD, "keybindColor", "Keybind color", H.keybindColor, ns.Display.TEXT_COLORS)
  Check(display, HUD, "spellNames", "Spell names under icons", H.spellNames)
  Slider(display, HUD, "nameSize", "Spell name size", H.nameSize, 8, 18, 1)
  Choice(display, HUD, "nameColor", "Spell name color", H.nameColor, ns.Display.TEXT_COLORS)
  Check(display, HUD, "labels", "NOW / NEXT labels", H.labels)
  Header(display, "Effects")
  Choice(display, HUD, "glow", "Main icon glow", H.glow,
    { { "none", "None" }, { "border", "Steady" }, { "pulse", "Pulse" } })
  Check(display, HUD, "pressCue", "Press-now cue", H.pressCue,
    "Brightens the main icon when your GCD or cast ends within the spell queue window: press now for no gap.")
  Check(display, HUD, "gcdBar", "GCD bar", H.gcdBar)
  Check(display, HUD, "dimGuesses", "Dim uncertain picks", H.dimGuesses)

  ---------------------------------------------------------------- alerts & sounds
  local alerts = Category("Alerts & Sounds", main)
  Header(alerts, "On screen")
  Check(alerts, HUD, "callout", "Boss callouts above the icons", H.callout,
    "'AOE 3', 'TANK HIT 2', 'ADDS 8', 'INTERRUPT', 'DEFENSIVE' from your boss mod or Blizzard's timeline.")
  Slider(alerts, HUD, "calloutSize", "Callout text size", H.calloutSize, 10, 28, 1)
  Check(alerts, HUD, "interrupt", "Show interrupts", H.interrupt)
  Check(alerts, HUD, "defensive", "Show defensives", H.defensive)
  Slider(alerts, DB, "defensiveHealth", "Low health for defensives", G.defensiveHealth or 35, 10, 70, 5, nil, "%")
  Slider(alerts, DB, "defensiveLead", "Warn this long before a big hit", G.defensiveLead or 3, 1, 8, 1, nil, "s")
  Header(alerts, "Sounds")
  for _, event in ipairs(ns.Sounds.EVENTS) do
    Choice(alerts, DB, "sound_" .. event, SOUND_LABELS[event], ns.Sounds.DEFAULTS[event], ns.Sounds.CHOICES)
  end
  Button(alerts, "Test", "Play the interrupt sound", function()
    ns.Sounds.Play("interrupt")
  end)

  ---------------------------------------------------------------- combat
  local combat = Category("Combat", main)
  Header(combat, "When to show")
  Check(combat, HUD, "hideOutOfCombat", "Hide out of combat", H.hideOutOfCombat)
  Check(combat, HUD, "showWithTarget", "Show when targeting an enemy", H.showWithTarget)
  Check(combat, HUD, "hideMounted", "Hide while mounted", H.hideMounted)
  Check(combat, HUD, "hideVehicle", "Hide in vehicles", H.hideVehicle)
  Header(combat, "Fight")
  Slider(combat, DB, "aoeTargets", "Targets assumed in AoE mode", G.aoeTargets or 3, 2, 10, 1)
  Slider(combat, DB, "fightLength", "Assumed fight length", G.fightLength or 300, 30, 600, 10,
    "SimC holds or uses cooldowns based on how long the fight lasts.", "s")
  Check(combat, DB, "smartFight", "Smart fight length", true,
    "Bosses and encounters use the length above; dungeon and raid trash is assumed short so cooldowns aren't held.")
  Check(combat, DB, "castWhileMoving", "Suggest cast-time spells while moving", false,
    "Off: while you move, spells with a cast time are skipped (instants and procs still show).")
  Header(combat, "Sources")
  Check(combat, DB, "useAssisted", "Use Blizzard's Assisted Combat as backup", true,
    "Midnight only: confirms uncertain SimC lines and reveals hidden buffs. Forever has no Assisted Combat.")
  Check(combat, DB, "bossMods", "Use boss mod timers (DBM / BigWigs / LittleWigs)", true,
    "Upcoming adds, AoE, tank hits and phase changes: shown on the HUD and used by SimC's add timing.")

  ---------------------------------------------------------------- advanced
  local advanced = Category("Advanced", main)
  Header(advanced, "Hidden values")
  Check(advanced, HUD, "secretBranches", "Let the game pick between two spells", H.secretBranches,
    "When a hidden resource decides (e.g. 4 or 5 combo points), show both spells; the game makes the right one visible.")
  Header(advanced, "Troubleshooting")
  Check(advanced, HUD, "debugText", "Show decision text under the HUD", H.debugText,
    "The queue with where each pick came from (SimC, assistant, Blizzard rules, guess).")
  Button(advanced, "Snapshot", "Store a decision snapshot", function()
    if SlashCmdList.DMGASSIST then
      SlashCmdList.DMGASSIST("snapshot")
    end
  end, "Saves every line the engine checked into the Watchdog log (same as /dmga snapshot).")

  Settings.RegisterAddOnCategory(main)
  O.category = main
  return main
end

-- The game won't let an addon open the Settings panel in combat (OpenSettingsPanel is protected), so a
-- request in combat waits for the fight to end.
O.openAfterCombat = false

function O.Open()
  if InCombatLockdown() then
    if not O.openAfterCombat then
      O.openAfterCombat = true
      U.Print("%s", L["Settings open when combat ends."])
    end
    return false
  end
  O.openAfterCombat = false
  local cat = O.Register()
  if cat and Settings.OpenToCategory then
    Settings.OpenToCategory(cat:GetID())
  end
  return true
end

function O.OnCombatEnded()
  if O.openAfterCombat then
    O.Open()
  end
end
