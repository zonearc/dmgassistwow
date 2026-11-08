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
  Button(main, "Key bindings", "Set key bindings", O.OpenKeybindings, KEYS_TIP)
  Button(main, "Defaults", "Reset everything to defaults", O.ResetAll, "Every setting on every DMGAssist page.")

  O.RegisterStatus(main)

  ---------------------------------------------------------------- combat: how it thinks and what it shows
  local combat = Category("Combat", main)
  Header(combat, "Recommendations")
  Slider(combat, DB, "queue", "Spells shown", G.queue or 3, 1, 3, 1, "The next spell, plus up to two after it.")
  Check(combat, DB, "burst", "Major cooldowns", true,
    "On: big cooldowns show in the three slots in SimC's order. Off: they are never shown.")
  Choice(combat, DB, "burstWhen", "Use cooldowns on", "always", { { "always", "Every fight" },
    { "big", "Bosses and big pulls" } },
    "Every fight (default), or only bosses, PvP and pulls of at least the size below: trash keeps them saved.")
  Slider(combat, DB, "bigPull", "Big pull size", G.bigPull or 5, 2, 10, 1,
    "With \"Bosses and big pulls\": this many enemies or more counts as a big pull.")
  Check(combat, DB, "gapClosers", "Gap closers", true,
    "Melee: out of range of your target, show your charge / leap (Wild Charge, Charge, Shadowstep...) first.")
  Check(combat, DB, "tankEssentials", "Tank essentials", true,
    "Tanks: keep active mitigation and your threat DoT up (Guardian: Ironfur stacks, Moonfire on the target).")
  Slider(combat, DB, "ironfurStacks", "Ironfur stacks", G.ironfurStacks or 3, 0, 5, 1,
    "Guardian: keep this many Ironfur stacks up (counted from your casts). 0 = off.")
  Check(combat, DB, "skipHold", "Hold skipped spells", true,
    "Skip the spell in the first slot twice and it is held until combat ends. Cast it yourself to bring it back.")
  Check(combat, DB, "castWhileMoving", "Casts while moving", false,
    "Off: while you move, spells with a cast time are skipped (instants and procs still show).")
  Header(combat, "Targets")
  Check(combat, DB, "autoDetect", "Auto-detect targets", true,
    "Counts enemies in combat with you, within range of your spells, from their nameplates (enemy nameplates "
    .. "must be on). Training dummies count once you have hit them.")
  Choice(combat, DB, "mode", "Fallback mode", "aoe", { { "st", "Single target" }, { "aoe", "AoE" } },
    "Used when the count isn't available. The key binding switches during a fight.")
  Choice(combat, DB, "aoeCount", "AoE target count", "spec", { { "spec", "Your spec's switch point" },
    { "custom", "Custom (slider below)" } },
    "Your spec's switch point comes from its SimC list (when it uses an AoE list): the count where it changes.")
  Slider(combat, DB, "aoeTargets", "Custom AoE count", G.aoeTargets or 3, 2, 10, 1,
    "Used when \"AoE target count\" is Custom: this many targets or more counts as AoE.")
  Button(combat, "Switch with a key", "Set key bindings", O.OpenKeybindings, KEYS_TIP)
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
    "In dungeons and raids 'what matters' = your boss mod calls an interrupt or Blizzard marks the spell important.")
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
  Check(display, HUD, "modeBar", "Mode title", H.modeBar,
    "In combat: ST (blue) or AOE (orange) with the number of targets counted, so you can see auto-detect work.")
  Check(display, HUD, "header", "Header", H.header, "A line above the icons with your spec and a settings button.")
  Check(display, HUD, "background", "Background", H.background)
  Slider(display, HUD, "bgAlpha", "Background opacity", H.bgAlpha, 0, 1, 0.05)
  Choice(display, HUD, "border", "Border", H.border, { { "none", "None" }, { "thin", "Thin" }, { "thick", "Thick" } })
  Slider(display, HUD, "borderAlpha", "Border opacity", H.borderAlpha, 0, 1, 0.05)
  Header(display, "Text")
  Choice(display, HUD, "font", "Font", H.font, ns.Display.FontChoices,
    "Game fonts, plus any registered with LibSharedMedia.")
  Choice(display, HUD, "outline", "Outline", H.outline, ns.Display.OUTLINES)
  Check(display, HUD, "keybind", "Keybind on icons", H.keybind)
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
    "The main icon is darkened until your GCD or cast is about to end, then flashes: press it then.")
  Slider(display, HUD, "pressLead", "Flash this early", H.pressLead, 0, 300, 10,
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
  Header(integrations, "Boss mods")
  Check(integrations, DB, "bossMods", "Boss mod timers", true,
    "Upcoming adds, AoE, tank hits and interrupts: used for defensives, interrupts and SimC's add timing.")
  Header(integrations, "Action bars")
  Button(integrations, "Keybinds", "Refresh keybinds", function()
    if SlashCmdList.DMGASSIST then
      SlashCmdList.DMGASSIST("keys")
    end
  end, "Keybinds are read from Blizzard bars, Bartender, ElvUI and Dominos automatically; this re-reads them now.")

  ---------------------------------------------------------------- advanced
  local advanced = Category("Advanced", main)
  Header(advanced, "Hidden values")
  Check(advanced, HUD, "secretBranches", "Two-spell branches", H.secretBranches,
    "When a hidden resource decides (e.g. 4 or 5 combo points), show both spells; the game makes the right one visible.")
  Header(advanced, "Troubleshooting")
  Check(advanced, HUD, "debugText", "Decision text", H.debugText,
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
    { "Project page", ns.LINKS.home },
    { "Report a problem", ns.LINKS.issues },
    { "Latest build", ns.LINKS.downloads },
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
  how:SetText(L["To report a problem: type /dmgw, press Ctrl+C, open the Report a problem link and paste it "
    .. "into a new issue with a line about what happened. (Click a link box, Ctrl+C to copy it.)"])

  local reset = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  reset:SetSize(220, 24)
  reset:SetPoint("TOPLEFT", how, "BOTTOMLEFT", 0, -16)
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
