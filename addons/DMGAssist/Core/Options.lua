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

-- Re-read every control (after a profile switch the values come from another table).
function O.Refresh()
  for _, setting in pairs(O.settings) do
    if setting.NotifyUpdate then
      pcall(setting.NotifyUpdate, setting)
    end
  end
end

-- Profiles: shared "Default" for every character, or one per character; copy and delete.
function O.RegisterProfiles(main)
  local P = ns.Profiles
  Header(main, "Profile")
  local function Options(withNone)
    return function()
      local container = Settings.CreateControlTextContainer()
      if withNone then
        container:Add("", L["Choose a profile..."])
      end
      for _, name in ipairs(P.List()) do
        container:Add(name, name)
      end
      return container:GetData()
    end
  end
  local use = Settings.RegisterProxySetting(main, "DMGASSIST_PROFILE", Settings.VarType.String, L["Profile in use"],
    P.DEFAULT, function()
      return P.current or P.DEFAULT
    end, function(value)
      if value ~= P.current then
        P.Use(value)
      end
    end)
  Settings.CreateDropdown(main, use, Options(false),
    L["Settings this character uses. \"Default\" is shared by every character that has no profile of its own."])
  Button(main, "This character", "Use a profile for this character only", function()
    P.UseCharacterProfile()
    U.Print(L["This character now has its own profile: %s."], P.current)
  end, "Starts as a copy of the current settings; other characters are not affected.")
  local copy = Settings.RegisterProxySetting(main, "DMGASSIST_PROFILE_COPY", Settings.VarType.String,
    L["Copy settings from"], "", function()
      return ""
    end, function(value)
      if value ~= "" and P.CopyFrom(value) then
        U.Print(L["Settings copied from %s into %s."], value, P.current)
      end
    end)
  Settings.CreateDropdown(main, copy, Options(true), L["Replaces the settings of the profile in use."])
  Button(main, "Delete", "Delete the profile in use", function()
    local name = P.current
    if name == P.DEFAULT then
      U.Print(L["The Default profile can't be deleted."])
    elseif P.Delete(name) then
      U.Print(L["Profile %s deleted; this character uses Default again."], name)
    end
  end, "Characters that used it go back to Default.")
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
  { "smart", "Smart: all in the open world, important ones in instances" },
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
  burst = "Cooldown ready" }

local KEYS_TIP = "Bind keys in Options > Keybindings > AddOns > DMGAssist: switch target mode (Auto / Single / "
  .. "AoE), major cooldowns on/off, show/hide."

function O.Register()
  if O.category or not (Settings and Settings.RegisterVerticalLayoutCategory and ns.db) then
    return O.category
  end
  local H = ns.Display.DEFAULTS
  local G = ns.DEFAULTS or {}

  -- Pages: DMGAssist (the essentials), Status (what is working), Combat (how it thinks and what it shows),
  -- Display (visuals only), Sounds, Integrations (what it uses from Blizzard and other addons), Advanced.

  ---------------------------------------------------------------- main page
  local main = Category("DMGAssist")
  Header(main, "DMGAssist")
  Check(main, DB, "enabled", "Show recommendations", true)
  Check(main, DB, "minimap", "Minimap button", true,
    "Left-click: show / hide. Right-click: menu and settings. Drag to move it.")
  Check(main, DB, "locked", "Lock position", true,
    "Unlock to drag the icons; they are also shown while this panel is open.")
  -- Language: the game's (default) or any other; account-wide, applied after a /reload.
  local langProxy = setmetatable({}, {
    __index = function(_, k)
      return ns.global and ns.global[k]
    end,
    __newindex = function(_, k, v)
      if ns.global and ns.global[k] ~= v then
        ns.global[k] = v
        U.Print("%s", L["Language saved. Type /reload to switch to it."])
      end
    end,
  })
  Choice(main, function()
    return langProxy
  end, "language", "Language", "auto", ns.LANGUAGES,
    "DMGAssist's text in another language than the game's. Chinese and Korean need a game client in that "
      .. "language (its fonts). Applied after /reload.")
  Button(main, "Quick setup", "Run the setup again", function()
    ns.Welcome.Open()
  end, "Three questions: where the HUD goes, how big, and when it shows.")
  Button(main, "Key bindings", "Set key bindings", O.OpenKeybindings, KEYS_TIP)
  Button(main, "Defaults", "Reset everything to defaults", O.ResetAll,
    "Every setting on every DMGAssist page, in the profile in use.")
  O.RegisterProfiles(main)

  O.RegisterStatus(main)

  ---------------------------------------------------------------- combat: how it thinks and what it shows
  local combat = Category("Combat", main)
  Header(combat, "Recommendations")
  Slider(combat, DB, "queue", "Spells shown", G.queue or 3, 1, 3, 1, "The next spell, plus up to two after it.")
  Check(combat, DB, "burst", "Major cooldowns", true,
    "On: big cooldowns show in the three slots in SimC's order. Off: they are never shown.")
  Choice(combat, DB, "burstWhen", "Use major cooldowns", "always", { { "always", "Every fight" },
    { "big", "Bosses and big pulls" } },
    "Every fight, or save them for bosses, PvP and big pulls (size set below).")
  Slider(combat, DB, "bigPull", "Big pull size", G.bigPull or 5, 2, 10, 1,
    "With \"Bosses and big pulls\": this many enemies or more counts as a big pull.")
  Check(combat, DB, "gapClosers", "Gap closers", true,
    "Melee: out of range of your target, show your charge / leap (Wild Charge, Charge, Shadowstep...) first.")
  Check(combat, DB, "tankEssentials", "Tank essentials", true,
    "Tanks: keep active mitigation and your threat DoT up (Guardian: Ironfur stacks, Moonfire on the target).")
  Slider(combat, DB, "ironfurStacks", "Ironfur stacks", G.ironfurStacks or 3, 0, 5, 1,
    "Guardian: keep this many Ironfur stacks up (counted from your casts). 0 = off.")
  Check(combat, DB, "skipHold", "Hold skipped spells", true,
    "Skip the spell in the first slot three times and it is held until combat ends. Cast it yourself to bring it back.")
  Check(combat, DB, "castWhileMoving", "Casts while moving", false,
    "Off: while you move, spells with a cast time are skipped (instants and procs still show).")
  Header(combat, "Leveling and alts")
  Choice(combat, DB, "levelingMode", "Leveling", "auto", {
    { "auto", "Automatic (suggested)" }, { "blizzard", "Always Blizzard's suggestions" },
    { "simc", "Always DMGAssist's priority list" } },
    "Automatic: below max level, while a character knows few of the spells the priority list expects, "
      .. "Blizzard's Assisted Combat leads. It switches by itself as you learn more. Always Blizzard: for an alt "
      .. "whose talents are far from the usual build.")
  Check(combat, DB, "levelNotices", "New spell and talent notices", true,
    "A chat line when you learn a spell DMGAssist can recommend that has no key (not when the game already put "
      .. "it on a keyed button), and when you have unspent talent points after a level-up.")
  Check(combat, DB, "buffReminders", "Buff reminders", true,
    "Out of combat, a missing buff goes in slot 1: raid buffs, shields, weapon imbues, poisons, and Earth Shield "
      .. "or Beacon of Light on your tank. Each can be hidden on the Spells & trinkets page.")
  Header(combat, "Trinkets")
  Check(combat, DB, "trinkets", "On-use trinkets", true,
    "Show your on-use trinkets (off-GCD badge on slot 1) when they are ready, with your cooldowns, in combat.")
  Button(combat, "Each trinket", "Spells & trinkets", function()
    if O.trinketCategory and Settings.OpenToCategory then
      Settings.OpenToCategory(O.trinketCategory:GetID())
    end
  end, "Every equipped on-use trinket and every spell can be switched off on the Spells & trinkets page.")
  Header(combat, "Targets")
  Check(combat, DB, "autoDetect", "Auto-detect targets", true,
    "Counts enemies in combat with you, within range of your spells, from their nameplates (enemy nameplates "
    .. "must be on). Training dummies count once you have hit them.")
  Choice(combat, DB, "mode", "Default target mode", "aoe", { { "st", "Single target" }, { "aoe", "AoE" } },
    "Used when the count isn't available. The key binding switches during a fight.")
  Choice(combat, DB, "aoeCount", "AoE target count", "spec", { { "spec", "Spec default" },
    { "custom", "Custom (slider below)" } },
    "Your spec's switch point comes from its SimC list (when it uses an AoE list): the count where it changes.")
  Slider(combat, DB, "aoeTargets", "Custom AoE count", G.aoeTargets or 3, 2, 10, 1,
    "Used when \"AoE target count\" is Custom: this many targets or more counts as AoE.")
  Button(combat, "Target mode keybind", "Set key bindings", O.OpenKeybindings, KEYS_TIP)
  Header(combat, "Fight length")
  Choice(combat, DB, "fightMode", "Fight length", "learned", {
    { "learned", "Learned from your fights" }, { "simc", "SimC default (300 s bosses, short trash)" },
    { "custom", "Custom (slider below)" } },
    "SimC holds or uses cooldowns by how long the fight lasts. Learned: the typical length of your recent fights "
    .. "of the same kind (open world, dungeon/raid trash, bosses, PvP); SimC's defaults until it has 5.")
  Slider(combat, DB, "fightLength", "Custom fight length", G.fightLength or 300, 30, 600, 10, nil, "s")
  Header(combat, "Interrupts")
  Check(combat, HUD, "interrupt", "Suggest interrupts", H.interrupt)
  Choice(combat, DB, "interruptMode", "When", "smart", INTERRUPT_CHOICES,
    "In dungeons and raids, important means your boss mod calls for it or Blizzard flags the spell.")
  Header(combat, "Discipline: Atonement")
  Check(combat, DB, "atonementRamp", "Ramp before big hits", true,
    "When your boss mod warns of AoE damage, show Power Word: Radiance, then Shield, until enough Atonements are up.")
  Slider(combat, DB, "atonementTarget", "Atonement goal", G.atonementTarget or 5, 1, 20, 1,
    "Counted from your own casts (Shield, Flash Heal, Plea, Renew: 1; Radiance: 5). 5 for a party, more for raids.")
  Slider(combat, DB, "atonementLead", "Ramp lead time", G.atonementLead or 8, 3, 20, 1,
    "Seconds before the hit your boss mod announces.", "s")
  Header(combat, "Self-heals")
  Slider(combat, DB, "healAt", "Self-heal below", G.healAt or 35, 0, 90, 5,
    "Self-heals your rotation can suggest (Desperate Prayer, Regrowth, Crimson Vial...) show only at or below this "
    .. "health. 0 = never.", "%")
  Check(combat, DB, "healInRaids", "Self-heals in raids", false,
    "Off: never suggested in raids (healing there is the healers' job).")
  Header(combat, "Defensives")
  Check(combat, HUD, "defensive", "Suggest defensives", H.defensive)
  Choice(combat, DB, "defensiveMode", "When", "smart", DEFENSIVE_CHOICES,
    "Before big hits your boss mod warns about, and when you are low.")
  Slider(combat, DB, "defensiveHealth", "Low health", G.defensiveHealth or 35, 10, 70, 5, nil, "%")
  Slider(combat, DB, "defensiveLead", "Big hit warning", G.defensiveLead or 3, 1, 8, 1,
    "Suggest a defensive this long before a big hit that a boss mod announces.", "s")
  Header(combat, "When to show")
  Check(combat, HUD, "hideOutOfCombat", "Hide out of combat", H.hideOutOfCombat)
  Check(combat, HUD, "showWithTarget", "Show with a target", H.showWithTarget, "Show the HUD out of combat while an enemy is targeted.")
  Check(combat, HUD, "hideMounted", "Hide while mounted", H.hideMounted)
  Check(combat, HUD, "hideVehicle", "Hide in vehicles", H.hideVehicle)

  ---------------------------------------------------------------- display: visuals only
  local display = Category("Display", main)
  Header(display, "Layout")
  Slider(display, HUD, "scale", "Scale", H.scale, 0.5, 2, 0.05)
  Slider(display, HUD, "iconSize", "Main icon size", H.iconSize, 24, 96, 1)
  Slider(display, HUD, "nextSize", "Next icon size", H.nextSize, 16, 80, 1)
  Slider(display, HUD, "spacing", "Icon spacing", H.spacing, 0, 24, 1)
  Slider(display, HUD, "padding", "Frame padding", H.padding, 0, 24, 1)
  Slider(display, HUD, "alpha", "Opacity", H.alpha, 0.2, 1, 0.05)
  Slider(display, HUD, "queueAlpha", "Next icons opacity", H.queueAlpha, 0.2, 1, 0.05)
  Header(display, "Frame")
  Check(display, HUD, "modeBar", "Target mode title", H.modeBar,
    "In combat: ST (blue) or AOE (orange) with the number of targets counted, so you can see auto-detect work.")
  Check(display, HUD, "header", "Title bar", H.header, "A line above the icons with your spec and a settings button.")
  Check(display, HUD, "background", "Background", H.background)
  Slider(display, HUD, "bgAlpha", "Background opacity", H.bgAlpha, 0, 1, 0.05)
  Choice(display, HUD, "border", "Border", H.border, { { "none", "None" }, { "thin", "Thin" }, { "thick", "Thick" } })
  Slider(display, HUD, "borderAlpha", "Border opacity", H.borderAlpha, 0, 1, 0.05)
  Header(display, "Text")
  Choice(display, HUD, "font", "Font", H.font, ns.Display.FontChoices,
    "Game fonts, plus any registered with LibSharedMedia.")
  Choice(display, HUD, "outline", "Outline", H.outline, ns.Display.OUTLINES)
  Header(display, "Off-GCD badge (Ironfur)")
  Choice(display, HUD, "weavePos", "Badge position", H.weavePos, ns.Display.WEAVE_POSITIONS,
    "Where the small badge for spells pressed alongside slot 1 (no GCD, e.g. Ironfur) sits.")
  Slider(display, HUD, "weaveSize", "Badge size", H.weaveSize, 25, 80, 5, "Size, as a percentage of slot 1.", "%")
  Header(display, "Stack count")
  Check(display, HUD, "stackCount", "Show stack count", H.stackCount,
    "Our count of your stacking buff (Guardian: Ironfur), counted from your casts. Put the same buff in "
    .. "Blizzard's Cooldown Manager next to it to check the count.")
  Slider(display, HUD, "stackSize", "Stack text size", H.stackSize, 8, 28, 1)
  Choice(display, HUD, "stackPos", "Stack position", H.stackPos, ns.Display.STACK_POSITIONS)
  Check(display, HUD, "keybind", "Keybind on icons", H.keybind)
  Slider(display, HUD, "keybindSize", "Keybind text size", H.keybindSize, 8, 24, 1)
  Choice(display, HUD, "keybindPos", "Keybind position", H.keybindPos,
    { { "CENTER", "Center" }, { "TOPRIGHT", "Top right" }, { "TOPLEFT", "Top left" }, { "BOTTOMLEFT", "Bottom left" },
      { "BOTTOMRIGHT", "Bottom right" } })
  Choice(display, HUD, "keybindColor", "Keybind color", H.keybindColor, ns.Display.TEXT_COLORS)
  Check(display, HUD, "rangeTint", "Out of range and resource colors", H.rangeTint,
    "Like your action bars: an icon turns red when your target is out of that spell's range, and slot 1 turns blue "
      .. "when you are short of resource for it.")
  Choice(display, HUD, "padLabels", "Controller button names", H.padLabels,
    { { "xbox", "Xbox (A B X Y, LB RB)" }, { "playstation", "PlayStation (X O, L1 R1)" } },
    "With a controller (the game's gamepad support), keybinds show as controller buttons, for example LT+A.")
  Check(display, HUD, "spellNames", "Spell names under icons", H.spellNames)
  Slider(display, HUD, "nameSize", "Spell name size", H.nameSize, 8, 18, 1)
  Choice(display, HUD, "nameColor", "Spell name color", H.nameColor, ns.Display.TEXT_COLORS)
  Check(display, HUD, "labels", "NOW / NEXT labels", H.labels)
  Header(display, "Effects")
  Choice(display, HUD, "glow", "Main icon glow", H.glow,
    { { "none", "None" }, { "border", "Steady" }, { "pulse", "Pulse" } })
  Check(display, HUD, "pressCue", "Press-now flash", H.pressCue,
    "The main icon is darkened until your GCD or cast is about to end, then flashes: press it then.")
  Slider(display, HUD, "pressLead", "Flash lead time", H.pressLead, 0, 300, 10,
    "How long before the exact moment the flash comes, for reaction time.", " ms")
  Check(display, HUD, "gcdBar", "GCD bar", H.gcdBar)
  Check(display, HUD, "dimGuesses", "Dim uncertain picks", H.dimGuesses)
  Check(display, HUD, "highlight", "Action bar highlight", H.highlight,
    "Glows the real action button for the next spell (Blizzard bars, Bartender, ElvUI, Dominos).")
  Check(display, HUD, "callout", "Boss callouts", H.callout,
    "'AOE 3', 'TANK HIT 2', 'ADDS 8', 'INTERRUPT', 'DEFENSIVE' from your boss mod or Blizzard's timeline.")
  Slider(display, HUD, "calloutSize", "Callout text size", H.calloutSize, 10, 28, 1)

  ---------------------------------------------------------------- sounds
  local sounds = Category("Sounds", main)
  Header(sounds, "Sounds")
  Check(sounds, DB, "sounds", "Sound alerts", true)
  for _, event in ipairs(ns.Sounds.EVENTS) do
    Choice(sounds, DB, "sound_" .. event, SOUND_LABELS[event], ns.Sounds.DEFAULTS[event], ns.Sounds.CHOICES)
  end
  Button(sounds, "Test", "Play the interrupt sound", function()
    ns.Sounds.Play("interrupt")
  end)

  ---------------------------------------------------------------- integrations: Blizzard and other addons
  local integrations = Category("Integrations", main)
  Header(integrations, "Blizzard")
  Check(integrations, DB, "useAssisted", "Assisted Combat", true,
    "Midnight only: it sees hidden procs and resources, so it confirms uncertain SimC lines. Forever has none.")
  Button(integrations, "Test", "Test Assisted Combat", function()
    SlashCmdList.DMGASSIST("test assisted")
  end, "Shows the spell Blizzard's Assisted Combat suggests right now. Target an enemy first.")
  Header(integrations, "Boss mods")
  Check(integrations, DB, "bossMods", "Boss mod timers", true,
    "Upcoming adds, AoE, tank hits and interrupts: used for defensives, interrupts and SimC's add timing.")
  Button(integrations, "Test", "Detect boss mods", function()
    SlashCmdList.DMGASSIST("test bossmods")
  end, "Lists the boss mods DMGAssist detected: DBM, BigWigs or LittleWigs.")
  Button(integrations, "Test", "Test defensive alert", function()
    SlashCmdList.DMGASSIST("test")
  end, "Shows in slot 1, for 8 seconds, the defensive DMGAssist would suggest before a big hit.")
  Button(integrations, "Test", "Test interrupt alert", function()
    SlashCmdList.DMGASSIST("test interrupt")
  end, "Shows your interrupt in slot 1 for 8 seconds, as when an enemy casts something important.")
  Header(integrations, "Action bars")
  Button(integrations, "Keybinds", "Refresh keybinds", function()
    if SlashCmdList.DMGASSIST then
      SlashCmdList.DMGASSIST("keys")
    end
  end, "Reads keybinds again from Blizzard, Bartender, ElvUI and Dominos bars.")
  Check(integrations, DB, "bindWarn", "Warn about missing keybinds", true,
    "Once per spec each session: a chat line when spells DMGAssist can recommend have no key binding.")

  ---------------------------------------------------------------- advanced
  local advanced = Category("Advanced", main)
  Header(advanced, "Hidden game values")
  Check(advanced, HUD, "secretBranches", "Show both options when unsure", H.secretBranches,
    "When a hidden resource decides (e.g. 4 or 5 combo points), show both spells; the game makes the right one visible.")
  Header(advanced, "Troubleshooting")
  Check(advanced, HUD, "debugText", "Decision details", H.debugText,
    "Shows where each pick came from: SimC, Assisted Combat, Blizzard rules, or a guess.")
  Button(advanced, "Snapshot", "Save a decision snapshot", function()
    if SlashCmdList.DMGASSIST then
      SlashCmdList.DMGASSIST("snapshot")
    end
  end, "Saves every line the engine checked into the Watchdog log (same as /dmga snapshot).")

  O.RegisterSpellChoices(main)
  O.RegisterBindcheck(main)
  O.RegisterHelp(main)

  Settings.RegisterAddOnCategory(main)
  O.category = main
  return main
end

---------------------------------------------------------------------------
-- Status page: what DMGAssist sees right now (ns.StatusLines), where to get help, and a reset of everything.
-- A canvas page (Settings.RegisterCanvasLayoutSubcategory, live 12.1.5 and forever 1.60.1), refreshed whenever
-- it is shown. Links are in read-only boxes to copy: the game cannot open web pages.
---------------------------------------------------------------------------
local function CopyBox(parent, text, width)
  local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  box:SetSize(width, 20)
  box:SetAutoFocus(false)
  box:SetText(text)
  box:SetCursorPosition(0)
  box:SetScript("OnTextChanged", function(self, user)
    if user then
      self:SetText(text) -- read-only: put the link back
      self:HighlightText()
    end
  end)
  box:SetScript("OnEditFocusGained", function(self)
    self:HighlightText()
  end)
  box:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
  end)
  return box
end

function O.RegisterStatus(parent)
  local frame = CreateFrame("Frame")
  frame:SetSize(600, 560)
  local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText(L["Status"])
  local body = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
  body:SetWidth(560)
  body:SetJustifyH("LEFT")
  body:SetSpacing(4)

  local help = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  help:SetPoint("TOPLEFT", body, "BOTTOMLEFT", 0, -18)
  help:SetText(L["Help and updates"])
  local rows = {
    { "Download (CurseForge)", ns.LINKS.curseforge },
    { "Report a problem", ns.LINKS.issues },
  }
  local anchor = help
  for _, row in ipairs(rows) do
    local label = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)
    label:SetWidth(130)
    label:SetJustifyH("LEFT")
    label:SetText(L[row[1]])
    local box = CopyBox(frame, row[2], 400)
    box:SetPoint("LEFT", label, "RIGHT", 8, 0)
    anchor = label
  end
  local how = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  how:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -12)
  how:SetWidth(560)
  how:SetJustifyH("LEFT")
  how:SetText(L["To report a problem or give feedback: press Report an issue (or type /dmga report). It walks "
    .. "you through it: say what went wrong, copy the report, paste it on the issue page."])

  local report = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  report:SetSize(220, 24)
  report:SetPoint("TOPLEFT", how, "BOTTOMLEFT", 0, -12)
  report:SetText(L["Report an issue"])
  report:SetScript("OnClick", function()
    ns.OpenReport()
  end)

  local reset = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  reset:SetSize(220, 24)
  reset:SetPoint("TOPLEFT", report, "BOTTOMLEFT", 0, -10)
  reset:SetText(L["Reset everything to defaults"])
  reset:SetScript("OnClick", function()
    O.ResetAll()
    frame:GetScript("OnShow")(frame)
  end)

  frame:SetScript("OnShow", function()
    local lines = {}
    for _, kv in ipairs(ns.StatusLines and ns.StatusLines() or {}) do
      lines[#lines + 1] = "|cffffd100" .. kv[1] .. ":|r  " .. kv[2]
    end
    body:SetText(table.concat(lines, "\n"))
  end)
  local category = Settings.RegisterCanvasLayoutSubcategory(parent, frame, L["Status"])
  O.statusFrame, O.statusBody = frame, body
  return category
end

---------------------------------------------------------------------------
-- Spells & trinkets page: for the spec you are in, every spell DMGAssist can show (from its priority lists, plus
-- the interrupt, defensives, gap closer and keep-ups) and every equipped on-use trinket, each with a checkbox.
-- Unchecked = never shown (the next spell takes its place; no other priority changes). Spells are remembered per
-- spec, trinkets per item, in the profile: list updates and gear swaps keep the choices. Rebuilt whenever the page
-- is shown, the spec or talents change, or gear changes.
---------------------------------------------------------------------------
function O.RegisterSpellChoices(parent)
  local frame = CreateFrame("Frame")
  frame:SetSize(600, 560)
  local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText(L["Spells & trinkets"])
  -- The whole spec on or off (an alt's healing spec played without DMGAssist).
  local specOn = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
  specOn:SetSize(24, 24)
  specOn:SetPoint("LEFT", title, "RIGHT", 24, 0)
  specOn.label = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  specOn.label:SetPoint("LEFT", specOn, "RIGHT", 4, 0)
  specOn.label:SetText(L["On for this spec"])
  specOn:SetScript("OnClick", function(self)
    ns.Choices.SetSpecOff(not self:GetChecked())
    ns.Update()
  end)
  local intro = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  intro:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
  intro:SetWidth(560)
  intro:SetJustifyH("LEFT")
  local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -10)
  scroll:SetSize(540, 440)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(520, 10)
  scroll:SetScrollChild(content)
  local rows = {}
  local function Row(i)
    local row = rows[i]
    if not row then
      row = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
      row:SetSize(24, 24)
      row.icon = row:CreateTexture(nil, "ARTWORK")
      row.icon:SetSize(24, 24)
      row.icon:SetPoint("LEFT", row, "RIGHT", 4, 0)
      row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
      row.label:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
      row.label:SetWidth(300)
      row.label:SetJustifyH("LEFT")
      -- second checkbox: "first when ready" (spells only)
      row.first = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
      row.first:SetSize(24, 24)
      row.first:SetPoint("LEFT", row, "LEFT", 360, 0)
      row.firstText = row.first:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
      row.firstText:SetPoint("LEFT", row.first, "RIGHT", 2, 0)
      row.firstText:SetText(L["First when ready"])
      row.first:SetScript("OnClick", function(self)
        local parentRow = self:GetParent()
        local on = self:GetChecked() and true or false
        ns.Choices.SetFirst(parentRow.spell, on)
        if on and not parentRow:GetChecked() then
          parentRow:SetChecked(true) -- first implies shown
          ns.Choices.SetHidden(parentRow.spell, false)
        end
      end)
      row:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        if self.item then
          ns.Trinkets.SetOff(self.item, not on)
        else
          ns.Choices.SetHidden(self.spell, not on)
          if not on then
            ns.Choices.SetFirst(self.spell, false) -- hidden can't be first
            self.first:SetChecked(false)
          end
        end
      end)
      rows[i] = row
    end
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -(i - 1) * 28)
    return row
  end
  local function Refresh()
    local state = ns.Specs.current
    specOn:SetChecked(not ns.Choices.SpecOff())
    local entries = {}
    for _, info in ipairs(ns.Trinkets.List()) do
      entries[#entries + 1] = { item = info.item, name = tostring(info.name), texture = info.texture,
        on = not ns.Trinkets.IsOff(info.item),
        note = info.slot == 13 and L["trinket, top slot"] or L["trinket, bottom slot"] }
    end
    local spells = {}
    for _, id in ipairs(ns.Choices.Spells()) do
      spells[#spells + 1] = { spell = id, name = ns.Choices.Name(id),
        texture = U.Get(C_Spell and C_Spell.GetSpellTexture, id), on = not ns.Choices.IsHidden(id),
        first = ns.Choices.IsFirst(id) }
    end
    table.sort(spells, function(a, b)
      return a.name < b.name
    end)
    for _, e in ipairs(spells) do
      entries[#entries + 1] = e
    end
    local specName = state and state.key and state.key:gsub("_", " ") or "?"
    intro:SetText(string.format(L["For %s. Unchecked: never shown (the next spell takes its place). First when "
      .. "ready: in slot 1 whenever it can be cast (only interrupts, defensives and gap closers come before it). "
      .. "Spells are remembered per spec and trinkets per item, so updates and gear swaps keep your choices."],
      specName)
      .. (ns.db and ns.db.trinkets == false and ("\n" .. L["On-use trinkets are switched off (Combat > Trinkets)."])
        or ""))
    for i, e in ipairs(entries) do
      local row = Row(i)
      row.item, row.spell = e.item, e.spell
      row:SetChecked(e.on)
      row.first:SetShown(e.spell ~= nil)
      row.first:SetChecked(e.first == true)
      row.icon:SetTexture(e.texture or 134400)
      row.label:SetText(e.note and string.format("%s |cff999999(%s)|r", e.name, e.note) or e.name)
      row:Show()
    end
    for i = #entries + 1, #rows do
      rows[i]:Hide()
    end
    content:SetHeight(math.max(10, #entries * 28))
  end
  frame:SetScript("OnShow", Refresh)
  for _, event in ipairs({ "PLAYER_EQUIPMENT_CHANGED", "PLAYER_SPECIALIZATION_CHANGED", "TRAIT_CONFIG_UPDATED",
    "SPELLS_CHANGED" }) do
    pcall(frame.RegisterEvent, frame, event)
  end
  frame:SetScript("OnEvent", function(self)
    if self:IsShown() then
      C_Timer.After(0.5, function()
        if self:IsShown() then
          Refresh()
        end
      end)
    end
  end)
  local category = Settings.RegisterCanvasLayoutSubcategory(parent, frame, L["Spells & trinkets"])
  O.trinketCategory, O.choicesFrame = category, frame
  return category
end

---------------------------------------------------------------------------
-- Help page: the few things worth knowing, in plain words.
---------------------------------------------------------------------------
O.HELP = {
  { "The icons",
    "NOW is the spell to press next; the two NEXT icons follow. A small label on an icon says where a pick came "
      .. "from: none = SimC's priority list, AC = Blizzard's Assisted Combat, B = Blizzard's written rules, "
      .. "? = a best guess (dimmed), ... = waiting for a resource. The small badge on slot 1's corner is an off-GCD "
      .. "spell (Ironfur, trinkets) to press alongside." },
  { "Where the rotation comes from",
    "Each spec follows SimulationCraft's priority list, the same lists theorycrafters use. The game hides a lot "
      .. "in combat (procs, exact resources); Blizzard's Assisted Combat and the glow on your buttons fill those "
      .. "gaps." },
  { "Healers",
    "SimulationCraft publishes no rotation for most healing specs (Discipline, Holy Priest, Holy Paladin, "
      .. "Mistweaver, Restoration Shaman, Preservation). For those DMGAssist has its own damage lists, learned from "
      .. "the current class guides, for your damage between heals (SimC's list replaces ours as soon as it publishes one). "
      .. "Healing stays your call. Interrupts, defensives with your boss mod, on-use trinkets, keybinds and your "
      .. "spell choices all work. Restoration Druid has a full SimC list, including cat weaving. A spec with no "
      .. "list at all (some on WoW Forever) follows Blizzard's Assisted Combat." },
  { "Leveling and alts",
    "Below max level, and for a new character's starter spec, Blizzard's Assisted Combat leads while you know few "
      .. "of the spells the priority list expects; DMGAssist's list takes over by itself as you learn more. New spells "
      .. "without a key and unspent talent points get one chat line. Combat > Leveling." },
  { "Fits your UI",
    "Move the HUD in Blizzard's Edit Mode. Masque skins the icons. With a controller, keybinds show as its buttons "
      .. "(Display > Controller button names). Titan Panel and ElvUI data texts get a DMGAssist launcher. Addon authors: "
      .. "DMGAssistAPI." },
  { "Skipping a spell",
    "Skip the spell in slot 1 three times and it is held for the rest of the fight (\"saving it\"). Cast it "
      .. "yourself and it comes back. Only spells with a real cooldown are held." },
  { "Your choices",
    "Spells & trinkets: untick a spell or trinket to never see it, or tick First when ready to put a spell in "
      .. "slot 1 whenever it can be cast. Kept per spec, through updates." },
  { "Buff reminders",
    "Out of combat, a buff your rotation expects is put in slot 1 when it is missing or runs out within 5 minutes: "
      .. "raid buffs (on you or anyone in range), shields, weapon imbues, poisons, and Earth Shield or Beacon of "
      .. "Light on your tank. Combat > Buff reminders switches it off." },
  { "Defensives, interrupts and boss mods",
    "With DBM, BigWigs or LittleWigs, a defensive is shown a few seconds before a big hit they warn about (lighter "
      .. "ones first; on cooldown, the next). Also when you are low. Integrations has buttons to test both." },
  { "Targets",
    "AUTO counts enemies in combat with you within your spells' range (training dummies count while you fight). "
      .. "ST or AOE in the title is what the rotation plays. A key binding switches it by hand." },
  { "Keybinds",
    "Keys are read from Blizzard's bars, Bartender, ElvUI, Dominos and macros. Missing keybinds lists what the "
      .. "rotation can ask for that has no key." },
  { "Reporting a problem",
    "Right after it happens: /dmga report (or the minimap menu, or Status > Report an issue). Step 1: say what "
      .. "went wrong. Step 2: Ctrl+C copies your words and the report together. Step 3: open the link and paste "
      .. "it into a new issue. /dmga help lists every command." },
}

function O.RegisterHelp(parent)
  local frame = CreateFrame("Frame")
  frame:SetSize(600, 560)
  local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText(L["Help"])
  local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
  scroll:SetSize(560, 480)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(540, 10)
  scroll:SetScrollChild(content)
  local y = 0
  for _, entry in ipairs(O.HELP) do
    local head = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    head:SetPoint("TOPLEFT", 0, -y)
    head:SetText(L[entry[1]])
    local body = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    body:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -4)
    body:SetWidth(530)
    body:SetJustifyH("LEFT")
    body:SetSpacing(2)
    body:SetText(L[entry[2]])
    local h = (body.GetStringHeight and body:GetStringHeight()) or 60
    y = y + 18 + (type(h) == "number" and h > 0 and h or 60) + 14
  end
  content:SetHeight(y)
  return Settings.RegisterCanvasLayoutSubcategory(parent, frame, L["Help"])
end

---------------------------------------------------------------------------
-- Missing keybinds page: every spell (and on-use trinket) DMGAssist can recommend that has no key, with its icon,
-- so you can bind them before the pull instead of finding out mid-fight. Refreshed whenever it is shown.
---------------------------------------------------------------------------
function O.RegisterBindcheck(parent)
  local frame = CreateFrame("Frame")
  frame:SetSize(600, 560)
  local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText(L["Missing keybinds"])
  local intro = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  intro:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
  intro:SetWidth(560)
  intro:SetJustifyH("LEFT")
  local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -12)
  scroll:SetSize(540, 420)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(520, 10)
  scroll:SetScrollChild(content)
  local rows = {}
  local function Row(i)
    local row = rows[i]
    if not row then
      row = CreateFrame("Frame", nil, content)
      row:SetSize(520, 28)
      row:SetPoint("TOPLEFT", 0, -(i - 1) * 30)
      row.icon = row:CreateTexture(nil, "ARTWORK")
      row.icon:SetSize(26, 26)
      row.icon:SetPoint("LEFT")
      row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
      row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
      row.text:SetWidth(480)
      row.text:SetJustifyH("LEFT")
      rows[i] = row
    end
    return row
  end
  local function Refresh()
    ns.Display.InvalidateKeybinds()
    local list = ns.Bindcheck.Missing()
    if #list == 0 then
      intro:SetText(L["Every spell DMGAssist can recommend has a key binding."])
    else
      intro:SetText(string.format(L["%d spells DMGAssist can recommend have no key binding. Put them on a bar "
        .. "and bind a key (Options > Keybindings, or your bar addon's key binding mode)."], #list))
    end
    for i, entry in ipairs(list) do
      local row = Row(i)
      row.icon:SetTexture(entry.texture or 134400)
      row.text:SetText(ns.Bindcheck.Describe(entry))
      row:Show()
    end
    for i = #list + 1, #rows do
      rows[i]:Hide()
    end
    content:SetHeight(math.max(10, #list * 30))
  end
  frame:SetScript("OnShow", Refresh)
  -- Keeps up while open: binding a key or moving a spell onto a bar updates the list.
  for _, event in ipairs({ "UPDATE_BINDINGS", "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_PAGE_CHANGED", "UPDATE_MACROS",
    "PLAYER_EQUIPMENT_CHANGED", "SPELLS_CHANGED" }) do
    pcall(frame.RegisterEvent, frame, event)
  end
  local pending = false
  frame:SetScript("OnEvent", function(self)
    if self:IsShown() and not pending then
      pending = true
      C_Timer.After(0.3, function() -- bar addons update their buttons right after the event
        pending = false
        if self:IsShown() then
          Refresh()
        end
      end)
    end
  end)
  local again = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  again:SetSize(120, 22)
  again:SetPoint("TOPRIGHT", -24, -14)
  again:SetText(L["Refresh"])
  again:SetScript("OnClick", Refresh)
  local category = Settings.RegisterCanvasLayoutSubcategory(parent, frame, L["Missing keybinds"])
  O.bindFrame = frame
  return category
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

-- Blizzard's Keybindings page, scrolled to DMGAssist's section (the same call Blizzard's Ping settings use:
-- Blizzard_SettingsDefinitions_Frame/PingSystem.lua, live and forever).
function O.OpenKeybindings()
  if InCombatLockdown() then
    U.Print("%s", L["Key bindings can be changed after combat."])
    return false
  end
  if Settings.KEYBINDINGS_CATEGORY_ID and Settings.OpenToCategory then
    Settings.OpenToCategory(Settings.KEYBINDINGS_CATEGORY_ID, BINDING_HEADER_DMGASSIST)
    return true
  end
  U.Print("%s", L["Options > Keybindings > AddOns > DMGAssist."])
  return false
end

function O.OnCombatEnded()
  if O.openAfterCombat then
    O.Open()
  end
end
