-- wow_mock.lua: a small fake WoW client for running addon code under plain Lua 5.1.
--
-- Secret values are simulated with newproxy() userdata whose metatable raises an
-- error on every operation Blizzard forbids for tainted code: comparison,
-- arithmetic, concatenation, length, indexing, calling, tostring. Plain Lua
-- cannot make `if secret then` error (userdata is truthy), so that one case is
-- covered by code review and luacheck instead; everything else fails loudly.
--
-- mock.restricted = true makes the documented "contextually secret" APIs return
-- secrets, like the real client in combat.

local mock = {}

mock.restricted = false
mock.now = 1000
mock.printed = {}
mock.timers = {}
mock.cvars = {}
mock.cvarsMissing = {}
mock.gameType = "standard"     -- "standard" = Midnight; anything else (e.g. "camelot") behaves like Forever
mock.project = 1               -- WOW_PROJECT_ID
mock.class = { "Paladin", "PALADIN", 2 }
mock.usable = {}       -- spellID -> { isUsable, insufficientPower }
mock.cooldowns = {}    -- spellID -> { active =, onGCD =, start =, duration = }
mock.talents = {}
mock.auras = {}
mock.acSpell = nil
mock.power, mock.powerMax, mock.powerReadable = {}, {}, {}  -- per power type overrides
mock.casting = nil
mock.nameplates = 0
mock.locale = "enUS"
mock.hasTarget = false
mock.specIndex = 3
mock.specs = { [1] = 65, [2] = 66, [3] = 70 }  -- index -> specID

---------------------------------------------------------------------------
-- Secret values
---------------------------------------------------------------------------
local secretSet = setmetatable({}, { __mode = "k" })
local secretMeta

local function forbidden(op)
  return function()
    error("attempted " .. op .. " on a secret value", 2)
  end
end

local template = newproxy(true)
secretMeta = getmetatable(template)
secretMeta.__index = forbidden("index")
secretMeta.__newindex = forbidden("index")
secretMeta.__call = forbidden("call")
secretMeta.__eq = forbidden("compare")
secretMeta.__lt = forbidden("compare")
secretMeta.__le = forbidden("compare")
secretMeta.__add = forbidden("arithmetic")
secretMeta.__sub = forbidden("arithmetic")
secretMeta.__mul = forbidden("arithmetic")
secretMeta.__div = forbidden("arithmetic")
secretMeta.__mod = forbidden("arithmetic")
secretMeta.__pow = forbidden("arithmetic")
secretMeta.__unm = forbidden("arithmetic")
secretMeta.__concat = forbidden("concatenation")
secretMeta.__len = forbidden("length")
secretMeta.__tostring = forbidden("tostring")

function mock.Secret()
  local s = newproxy(template)
  secretSet[s] = true
  return s
end

function mock.IsSecret(v)
  return secretSet[v] == true
end

-- Value that is secret only while restricted.
local function ctx(v)
  if mock.restricted then
    return mock.Secret()
  end
  return v
end

---------------------------------------------------------------------------
-- Globals the client provides
---------------------------------------------------------------------------
function mock.Install(env)
  env = env or _G

  -- tostring/tonumber/string.format must refuse secrets like the client does.
  local rawTostring = tostring
  env.tostring = function(v)
    if secretSet[v] then
      error("tostring on a secret value", 2)
    end
    return rawTostring(v)
  end

  env.issecretvalue = function(v)
    return secretSet[v] == true
  end
  env.canaccessvalue = function(v)
    return secretSet[v] ~= true
  end

  env.GetTime = function()
    return mock.now
  end
  env.debugprofilestop = function()
    return mock.now * 1000
  end
  env.debugstack = function()
    return "Interface/AddOns/DMGAssist_Watchdog/Fake.lua:1: in function <mock>"
  end

  local errorHandler = function(msg)
    mock.lastDefaultError = msg
  end
  env.geterrorhandler = function()
    return errorHandler
  end
  env.seterrorhandler = function(fn)
    errorHandler = fn
  end

  env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
      parts[#parts + 1] = rawTostring((select(i, ...)))
    end
    mock.printed[#mock.printed + 1] = table.concat(parts, " ")
  end

  env.date = os.date
  env.time = os.time
  env.wipe = function(t)
    for k in pairs(t) do
      t[k] = nil
    end
    return t
  end
  env.tinsert = table.insert
  env.UISpecialFrames = {}
  env.SlashCmdList = {}
  env.ChatFontNormal = {}
  env.UIParent = {}

  -- Frames: just enough to record events and scripts.
  mock.frames = {}
  local FrameMethods = {}
  FrameMethods.__index = FrameMethods
  function FrameMethods:RegisterEvent(e)
    self.events[e] = true
  end
  function FrameMethods:RegisterUnitEvent(e, unit)
    self.events[e] = unit
  end
  function FrameMethods:SetScript(name, fn)
    self.scripts[name] = fn
  end
  function FrameMethods:GetScript(name)
    return self.scripts[name]
  end
  function FrameMethods:GetWidth()
    return self.width or 0
  end
  function FrameMethods:SetSize(w, h)
    self.width, self.height = w, h
  end
  function FrameMethods:SetWidth(w)
    self.width = w
  end
  function FrameMethods:SetText(t)
    self.text = t
  end
  function FrameMethods:GetText()
    return self.text
  end
  function FrameMethods:CreateFontString()
    return setmetatable({ events = {}, scripts = {} }, FrameMethods)
  end
  function FrameMethods:IsShown()
    return self.shown == true
  end
  function FrameMethods:Show()
    self.shown = true
  end
  function FrameMethods:Hide()
    self.shown = false
  end
  function FrameMethods:CreateTexture()
    return setmetatable({ events = {}, scripts = {} }, FrameMethods)
  end
  function FrameMethods:SetTexture(t)
    self.texture = t
  end
  function FrameMethods:EnableMouse(on)
    self.mouse = on
  end
  function FrameMethods:GetPoint()
    local p = self.point
    if p then
      return p[1], p[2], p[3], p[4], p[5]
    end
    return "CENTER", nil, "CENTER", 0, -150
  end
  function FrameMethods:SetPoint(a, rel, b, x, y)
    if type(rel) == "string" or type(rel) == "number" then
      rel, b, x, y = nil, rel, b, x
    end
    self.point = { a, rel, b or a, x or 0, y or 0 }
  end
  function FrameMethods:ClearAllPoints()
    self.point = nil
  end
  function FrameMethods:GetFrameStrata()
    return self.strata or "MEDIUM"
  end
  function FrameMethods:SetFrameStrata(s)
    self.strata = s
  end
  function FrameMethods:GetRight()
    return self.right or 1000
  end
  function FrameMethods:SetValue(v)
    self.value = v
  end
  function FrameMethods:SetAlpha(a)
    self.alpha = a
  end
  function FrameMethods:SetAlphaFromBoolean(value, ifTrue, ifFalse)
    self.alpha = { fromBoolean = value, ifTrue = ifTrue, ifFalse = ifFalse }
  end
  function FrameMethods:SetScale(v)
    self.scale = v
  end
  function FrameMethods:SetBackdrop(b)
    self.backdrop = b
  end
  local noop = function() end
  function FrameMethods:SetFont()
    return true
  end
  function FrameMethods:IsVisible()
    return self.shown ~= false
  end
  for _, name in ipairs({ "SetShadowOffset", "SetShadowColor", "SetWordWrap", "SetBlendMode", "SetTexCoord", "SetColorTexture",
    "SetDrawLayer", "SetBackdropColor",
    "SetBackdropBorderColor", "SetStatusBarTexture", "SetStatusBarColor", "SetMinMaxValues",
    "SetJustifyH", "SetTextColor", "SetAllPoints", "SetMovable", "RegisterForDrag",
    "SetClampedToScreen", "SetMultiLine", "SetAutoFocus", "SetFontObject", "SetScrollChild",
    "SetCursorPosition", "SetFocus", "HighlightText", "ClearFocus", "StartMoving", "StopMovingOrSizing",
    "RegisterForClicks", "SetVertexColor", "HasFocus", "SetMaxLetters", "SetSpacing", "SetHighlightTexture", "SetOwner", "AddLine" }) do
    FrameMethods[name] = noop
  end
  env.CreateFrame = function(frameType, name)
    local f = setmetatable({ type = frameType, name = name, events = {}, scripts = {} }, FrameMethods)
    mock.frames[#mock.frames + 1] = f
    if name then
      env[name] = f
    end
    return f
  end

  function FrameMethods:SetShown(on)
    self.shown = on and true or false
  end
  function FrameMethods:GetHeight()
    return self.height or 0
  end
  function FrameMethods:SetHeight(h)
    self.height = h
  end
  function FrameMethods:GetFrameLevel()
    return self.level or 1
  end
  function FrameMethods:SetFrameLevel(n)
    self.level = n
  end
  function FrameMethods:GetCenter()
    return 100, 100
  end
  function FrameMethods:GetLeft()
    return 80
  end
  function FrameMethods:GetBottom()
    return 80
  end
  function FrameMethods:GetEffectiveScale()
    return 1
  end
  env.UIParent = setmetatable({ events = {}, scripts = {} }, FrameMethods)
  env.Minimap = setmetatable({ events = {}, scripts = {}, width = 140 }, FrameMethods)
  env.GameTooltip = setmetatable({ events = {}, scripts = {} }, FrameMethods)
  env.GetCursorPosition = function()
    return 160, 100
  end
  env.IsShiftKeyDown = function()
    return mock.shift == true
  end
  env.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"

  -- Blizzard Settings API (the parts DMGAssist uses). mock.settings[variable] = { get, set, control, options }.
  mock.settings, mock.settingsCategories, mock.openedCategory = {}, {}, nil
  local function Category(name, parent)
    local c = { name = name, parent = parent, id = #mock.settingsCategories + 1, layout = { items = {} } }
    function c.layout.AddInitializer(self, init)
      self.items[#self.items + 1] = init
    end
    function c.GetID()
      return c.id
    end
    mock.settingsCategories[#mock.settingsCategories + 1] = c
    return c
  end
  env.Settings = {
    VarType = { Boolean = "boolean", String = "string", Number = "number" },
    RegisterVerticalLayoutCategory = function(name)
      local c = Category(name)
      return c, c.layout
    end,
    RegisterVerticalLayoutSubcategory = function(parent, name)
      local c = Category(name, parent)
      return c, c.layout
    end,
    RegisterCanvasLayoutSubcategory = function(parent, frame, name)
      local c = Category(name, parent)
      c.frame = frame
      return c, c.layout
    end,
    RegisterProxySetting = function(category, variable, varType, name, default, get, set)
      local setting = { category = category, variable = variable, varType = varType, name = name, default = default,
        get = get, set = set }
      function setting.GetValue()
        return get()
      end
      function setting.SetValue(_, v)
        set(v)
      end
      mock.settings[variable] = setting
      return setting
    end,
    CreateSliderOptions = function(minV, maxV, step)
      local o = { minValue = minV, maxValue = maxV, step = step }
      function o.SetLabelFormatter(self, _, fn)
        self.formatter = fn
      end
      return o
    end,
    CreateControlTextContainer = function()
      local c = { data = {} }
      function c.Add(self, value, label)
        self.data[#self.data + 1] = { value = value, label = label }
      end
      function c.GetData(self)
        return self.data
      end
      return c
    end,
    CreateCheckbox = function(_, setting, tooltip)
      setting.control, setting.tooltip = "checkbox", tooltip
    end,
    CreateSlider = function(_, setting, options, tooltip)
      setting.control, setting.options, setting.tooltip = "slider", options, tooltip
    end,
    CreateDropdown = function(_, setting, options, tooltip)
      setting.control, setting.options, setting.tooltip = "dropdown", options, tooltip
    end,
    RegisterAddOnCategory = function(category)
      category.registered = true
    end,
    OpenToCategory = function(id)
      mock.openedCategory = id
    end,
  }
  env.MinimalSliderWithSteppersMixin = { Label = { Right = 3 } }
  env.CreateSettingsButtonInitializer = function(name, text, click)
    return { name = name, text = text, click = click }
  end
  env.CreateSettingsListSectionHeaderInitializer = function(name)
    return { header = name }
  end
  env.GetActionInfo = function(slot)
    local a = mock.actionInfo and mock.actionInfo[slot]
    if a then
      return a[1], a[2]
    end
    return nil
  end
  env.GetMacroSpell = function(id)
    return mock.macroSpell and mock.macroSpell[id]
  end
  -- Curves: step/linear evaluation like the client; UnitPowerPercent feeds power/max (0..1) through a curve.
  env.C_CurveUtil = {
    CreateCurve = function()
      local c = { points = {} }
      function c.SetType(self, t)
        self.type = t
      end
      function c.AddPoint(self, x, y)
        self.points[#self.points + 1] = { x, y }
        table.sort(self.points, function(a, b) return a[1] < b[1] end)
      end
      function c.Evaluate(self, x)
        local y = self.points[1] and self.points[1][2] or 0
        for _, p in ipairs(self.points) do
          if x >= p[1] then
            y = p[2]
          end
        end
        return y
      end
      return c
    end,
  }
  env.UnitHealthPercent = function(unit, _, curve)
    local pct = (mock.healthPct and mock.healthPct[unit]) or 1
    if curve then
      return ctx(curve:Evaluate(pct))
    end
    return ctx(pct)
  end
  env.IsMounted = function()
    return mock.mounted == true
  end
  env.UnitInVehicle = function()
    return false
  end
  env.SOUNDKIT = { RAID_WARNING = 8959, READY_CHECK = 8960, ALARM_CLOCK_WARNING_3 = 12889, ALARM_CLOCK_WARNING_2 = 12867,
    PVP_THROUGH_QUEUE = 8459, UI_BNET_TOAST = 18019, TELL_MESSAGE = 3081 }
  mock.sounds = {}
  env.PlaySound = function(kit, channel)
    mock.sounds[#mock.sounds + 1] = { kit, channel }
  end
  env.UnitPowerPercent = function(_, pt, _, curve)
    local cur = mock.power[pt] or 0
    local max = mock.powerMax[pt] or 1
    local pct = cur / max
    if curve then
      return ctx(curve:Evaluate(pct))
    end
    return ctx(pct)
  end
  env.C_EncounterTimeline = {
    GetEventList = function()
      local ids = {}
      for id in pairs(mock.timeline or {}) do
        ids[#ids + 1] = id
      end
      return ids
    end,
    GetEventTimeRemaining = function(id)
      return (mock.timeline or {})[id]
    end,
  }
  env.GetBindingKey = function(command)
    return mock.bindings and mock.bindings[command]
  end
  env.GetBindingText = function(key)
    return key
  end
  env.C_Timer = {
    After = function(delay, fn)
      mock.timers[#mock.timers + 1] = { at = mock.now + delay, fn = fn }
    end,
  }

  env.InCombatLockdown = function()
    return mock.inCombat == true
  end
  env.GetBuildInfo = function()
    return "1.60.1", "70862", "Nov 7 2026", 16001, "1.60.1", "release"
  end
  env.GetPhysicalScreenSize = function()
    return 2560, 1440
  end
  env.GetFramerate = function()
    return 120
  end
  env.GetNumGroupMembers = function()
    return mock.groupSize or 0
  end
  env.ERR_SPELL_COOLDOWN = "Spell is not ready yet."
  env.ERR_ABILITY_COOLDOWN = "Ability is not ready yet."
  env.GetLocale = function()
    return mock.locale or "enUS"
  end
  env.GetRealZoneText = function()
    return "Elwynn Forest"
  end
  env.IsInInstance = function()
    if mock.instance then
      return true, type(mock.instance) == "string" and mock.instance or "party"
    end
    return false, "none"
  end
  env.UnitClass = function()
    return mock.class[1], mock.class[2], mock.class[3]
  end
  env.WOW_PROJECT_MAINLINE = 1
  env.WOW_PROJECT_CAMELOT = 18
  env.WOW_PROJECT_ID = mock.project
  env.C_SpecializationInfo = {
    GetSpecialization = function()
      return mock.specIndex
    end,
    GetSpecializationInfo = function(index)
      local id = mock.specs[index]
      return id, "Spec" .. tostring(id), "description", 0, "DAMAGER"
    end,
  }
  env.UnitLevel = function(unit)
    if unit == "target" and mock.targetLevel then
      return mock.targetLevel
    end
    return 60
  end
  env.UnitHealth = function()
    return ctx(1000)
  end
  env.UnitPower = function(_, pt)
    if mock.power[pt] ~= nil then
      if mock.powerReadable[pt] then
        return mock.power[pt]
      end
      return ctx(mock.power[pt])
    end
    if pt == 9 then -- holy power stays readable
      return 3
    end
    return ctx(50)
  end
  env.UnitPowerMax = function(_, pt)
    if mock.powerMax[pt] ~= nil then
      return mock.powerMax[pt]
    end
    if pt == 0 or pt == 9 then
      return pt == 0 and 1000 or 5
    end
    return 0
  end
  -- mock.casting = { id =, endsIn = seconds }
  env.UnitCastingInfo = function(unit)
    if unit == "target" then
      local t = mock.targetCast
      if not t then
        return nil
      end
      return ctx("Bolt"), ctx("Bolt"), ctx(1), ctx(0), ctx(1000), false, ctx("guid"), ctx(t.notInterruptible), ctx(t.id)
    end
    local c = mock.casting
    if not c then
      return nil
    end
    return ctx("Cast"), ctx("Cast"), ctx(1), ctx((mock.now - 1) * 1000), ctx((mock.now + c.endsIn) * 1000), false,
      ctx("guid"), ctx(false), ctx(c.id)
  end
  env.UnitChannelInfo = function()
    return nil
  end

  env.Enum = {
    AddOnRestrictionType = { Combat = 0, Encounter = 1, ChallengeMode = 2, PvPMatch = 3, Map = 4, Chat = 5 },
    PowerType = { Mana = 0, HolyPower = 9, Rage = 1 },
    SpellBookSpellBank = { Player = 0, Pet = 1 },
    SpellBookItemType = { None = 0, Spell = 1 },
    CompressionMethod = { Deflate = 0 },
    AddOnProfilerMetric = { RecentAverageTime = 1, PeakTime = 4 },
    LuaCurveType = { Linear = 0, Step = 1 },
  }

  env.C_CVar = {
    GetCVar = function(name)
      if mock.cvarsMissing[name] then
        return nil
      end
      return mock.cvars[name] or "0"
    end,
    SetCVar = function(name, value)
      mock.cvars[name] = value
    end,
  }
  env.C_GameRules = {
    IsStandard = function()
      return false
    end,
    GetActiveGameMode = function()
      return 7
    end,
  }
  mock.addons = { { "DMGAssist", "1.0", true }, { "DMGAssist_Watchdog", "0.1.0", true }, { "BigWigs", "v400", true },
    { "Details", "2026", false } }
  env.C_AddOns = {
    IsAddOnLoaded = function(i)
      local a = type(i) == "number" and mock.addons[i]
      return a and a[3] or false
    end,
    GetNumAddOns = function()
      return #mock.addons
    end,
    GetAddOnInfo = function(i)
      local a = mock.addons[i]
      return a[1], a[1], "", true, nil, "INSECURE"
    end,
    GetAddOnMetadata = function(name, field)
      for _, a in ipairs(mock.addons) do
        if a[1] == name and field == "Version" then
          return a[2]
        end
      end
    end,
    IsAddOnLoadOnDemand = function()
      return false
    end,
    GetAddOnEnableState = function()
      return 2
    end,
  }
  env.C_AssistedCombat = {
    IsAvailable = function()
      return false, "Not available in this game mode"
    end,
    GetActionSpell = function()
      return nil
    end,
    GetNextCastSpell = function()
      return mock.acSpell
    end,
    GetRotationSpells = function()
      return mock.rotationSpells or {}
    end,
  }
  env.C_ActionBar = {
    HasAssistedCombatActionButtons = function()
      return false
    end,
    FindSpellActionButtons = function(id)
      if mock.actionSlots and mock.actionSlots[id] then
        return mock.actionSlots[id]
      end
      if id == 35395 then
        return { 1 }
      end
      return {}
    end,
    GetBonusBarOffset = function()
      return mock.bonusBar or 0
    end,
    GetActionBarPage = function()
      return 1
    end,
    IsUsableAction = function()
      return true, false
    end,
  }
  env.C_CooldownViewer = {
    IsCooldownViewerAvailable = function()
      return true, ""
    end,
    GetCooldownViewerCooldownInfo = function(id)
      return mock.cdmInfo and mock.cdmInfo[id]
    end,
  }
  env.C_RestrictedActions = {
    GetAddOnRestrictionState = function(rtype)
      if mock.restricted and rtype == 0 then
        return 2
      end
      return 0
    end,
  }
  env.C_Secrets = {
    HasSecretRestrictions = function()
      return mock.restricted
    end,
    ShouldCooldownsBeSecret = function()
      return mock.restricted
    end,
    ShouldAurasBeSecret = function()
      return mock.restricted
    end,
    ShouldUnitStatsBeSecret = function()
      return mock.restricted
    end,
    ShouldSpellCooldownBeSecret = function(id)
      return mock.restricted and id ~= 61304
    end,
    ShouldSpellAuraBeSecret = function()
      return mock.restricted
    end,
    GetSpellCastSecrecy = function()
      return 0
    end,
    GetSpellCooldownSecrecy = function()
      return 2
    end,
    GetSpellAuraSecrecy = function()
      return 2
    end,
    ShouldUnitPowerBeSecret = function(_, pt)
      return mock.restricted and pt ~= 9
    end,
    GetPowerTypeSecrecy = function(pt)
      return pt == 9 and 0 or 2
    end,
  }

  -- Spellbook: one skill line with two active spells and one passive.
  mock.book = mock.book or {
    { spellID = 35395, name = "Crusader Strike" },
    { spellID = 20271, name = "Judgment" },
    { spellID = 99999, name = "Passive Thing", isPassive = true },
  }
  local function book()
    return mock.book
  end
  env.C_SpellBook = {
    GetNumSpellBookSkillLines = function()
      return 1
    end,
    GetSpellBookSkillLineInfo = function()
      return { name = "Paladin", itemIndexOffset = 0, numSpellBookItems = #book(), shouldHide = false }
    end,
    GetSpellBookItemInfo = function(slot)
      local b = book()[slot]
      return { actionID = b.spellID, spellID = b.spellID, itemType = 1, name = b.name, isPassive = b.isPassive == true, isOffSpec = false }
    end,
  }
  env.C_Spell = {
    GetSpellName = function(id)
      for _, b in ipairs(book()) do
        if b.spellID == id then
          return b.name
        end
      end
    end,
    IsSpellUsable = function(id)
      local u = mock.usable[id]
      if u then
        return u[1], u[2]
      end
      return true, false
    end,
    GetSpellCooldown = function(id)
      local c = mock.cooldowns[id]
      if c then
        return { startTime = ctx(c.start or 0), duration = ctx(c.duration or 0), isEnabled = true,
          isActive = c.active == true, modRate = ctx(1), isOnGCD = c.onGCD == true }
      end
      return { startTime = ctx(0), duration = ctx(0), isEnabled = true, isActive = false, modRate = ctx(1), isOnGCD = false }
    end,
    GetSpellTexture = function(id)
      return 1000000 + id
    end,
    GetOverrideSpell = function(id)
      return (mock.overrides and mock.overrides[id]) or id
    end,
    IsSpellInRange = function(id)
      if mock.inRange then
        return mock.inRange[id]
      end
      return nil
    end,
    IsSpellImportant = function(id)
      if mock.restricted then
        return mock.Secret()
      end
      return mock.important and mock.important[id] or false
    end,
    GetSpellPowerCost = function(id)
      return mock.powerCost and mock.powerCost[id]
    end,
    GetSpellInfo = function(id)
      return { name = "x", spellID = id, castTime = (mock.castTimes and mock.castTimes[id]) or 0 }
    end,
    GetSpellCharges = function(id)
      local c = mock.charges and mock.charges[id]
      if c then
        return { currentCharges = c[1], maxCharges = c[2] }
      end
      return nil
    end,
  }
  -- Talents: mock.talents = { { name = "Lunar Inspiration", spellID = 1, rank = 1 }, ... }; one tree, one node each.
  env.C_ClassTalents = {
    GetActiveConfigID = function()
      return 1
    end,
    GetActiveHeroTalentSpec = function()
      return mock.heroTree and 7 or nil
    end,
  }
  env.C_Traits = {
    GetConfigInfo = function()
      return { ID = 1, treeIDs = { 100 } }
    end,
    GetTreeNodes = function()
      local ids = {}
      for i = 1, #mock.talents do
        ids[i] = i
      end
      return ids
    end,
    GetNodeInfo = function(_, nodeID)
      local t = mock.talents[nodeID]
      return { ID = nodeID, entryIDs = { nodeID }, activeEntry = { entryID = nodeID, rank = t.rank },
        activeRank = t.rank, ranksPurchased = t.rank }
    end,
    GetEntryInfo = function(_, entryID)
      return { definitionID = entryID }
    end,
    GetDefinitionInfo = function(defID)
      return { spellID = mock.talents[defID].spellID }
    end,
    GetSubTreeInfo = function()
      return { ID = 7, name = mock.heroTree }
    end,
  }
  -- Auras: mock.auras[unit] = { { name =, spellId =, duration =, expirationTime =, applications = } }
  env.C_UnitAuras = {
    -- mock.directAuras[spellID] = { expirationTime =, applications = }: auras the game leaves readable in combat
    GetPlayerAuraBySpellID = function(spellID)
      return mock.directAuras and mock.directAuras[spellID] or nil
    end,
    GetAuraDataByIndex = function(unit, index)
      local list = mock.auras[unit] or {}
      local a = list[index]
      if not a then
        return nil
      end
      if mock.restricted then
        return { name = mock.Secret(), spellId = mock.Secret(), duration = mock.Secret(),
          expirationTime = mock.Secret(), applications = mock.Secret() }
      end
      return a
    end,
  }
  local function PlateIndex(unit)
    return tonumber(tostring(unit):match("^nameplate(%d+)$"))
  end
  env.UnitExists = function(unit)
    local i = PlateIndex(unit)
    if i then
      return i <= (mock.nameplates or 0)
    end
    return unit == "player" or (unit == "target" and mock.hasTarget == true)
  end
  env.UnitCanAttack = function(_, unit)
    if PlateIndex(unit) then
      return true
    end
    return unit == "target" and mock.hasTarget == true
  end
  env.UnitAffectingCombat = function(unit)
    local i = PlateIndex(unit)
    if i and mock.plateCombat and mock.plateCombat[i] ~= nil then
      return mock.plateCombat[i]
    end
    return mock.inCombat == true
  end
  env.UnitGUID = function(unit)
    local i = PlateIndex(unit)
    if i then
      return "Creature-0-0-0-0-" .. i
    end
    if unit == "target" then
      return mock.targetGUID
    end
    return unit == "player" and "Player-0-1" or nil
  end
  env.UnitName = function(unit)
    local i = PlateIndex(unit)
    if i then
      return mock.plateNames and mock.plateNames[i] or "Enemy"
    end
    return unit == "player" and "Tester" or nil
  end
  env.UnitIsDead = function()
    return false
  end
  env.UnitIsBossMob = function()
    return mock.boss == true
  end
  env.UnitClassification = function()
    return mock.classification or "normal"
  end
  env.UnitHealthMax = function()
    return 1000
  end
  env.UnitSpellHaste = function()
    return ctx(mock.haste or 0)
  end
  env.IsStealthed = function()
    return false
  end
  env.GetUnitSpeed = function()
    return ctx(0)
  end
  env.C_SpellActivationOverlay = {
    IsSpellOverlayed = function()
      return false
    end,
  }
  env.C_AddOnProfiler = {
    GetAddOnMetric = function()
      return 0.05
    end,
  }

  return env
end

---------------------------------------------------------------------------
-- Driving the addon
---------------------------------------------------------------------------
-- Does a TOC line's [AllowLoadGameType ...] / [ExcludeLoadGameType ...] condition let it load?
local function GameTypeAllows(cond)
  if not cond then
    return true
  end
  local kind, list = cond:match("^%[(%a+)LoadGameType%s+(.-)%]$")
  if not kind then
    error("unknown TOC condition " .. cond)
  end
  local listed = false
  for name in list:gmatch("[^,%s]+") do
    if name == mock.gameType then
      listed = true
    end
  end
  if kind == "Allow" then
    return listed
  end
  return not listed
end

function mock.LoadAddon(dir, addonName)
  local ns = {}
  local tocPath = dir .. "/" .. addonName .. ".toc"
  local toc = assert(io.open(tocPath, "r"))
  mock.loadedFiles = {}
  for line in toc:lines() do
    line = line:gsub("%s+$", "")
    if line ~= "" and not line:match("^#") then
      local file, cond = line:match("^(.-)%s+(%[.*%])$")
      file = file or line
      if GameTypeAllows(cond) and not file:match("%.xml$") then
        file = file:gsub("\\", "/")
        local chunk = assert(loadfile(dir .. "/" .. file))
        chunk(addonName, ns)
        mock.loadedFiles[#mock.loadedFiles + 1] = file
      end
    end
  end
  toc:close()
  return ns
end

-- Fire an event on every mock frame registered for it.
function mock.Fire(event, ...)
  for _, f in ipairs(mock.frames) do
    if f.events[event] and f.scripts.OnEvent then
      f.scripts.OnEvent(f, event, ...)
    end
  end
end

function mock.Advance(seconds)
  mock.now = mock.now + seconds
  local due = {}
  for i = #mock.timers, 1, -1 do
    if mock.timers[i].at <= mock.now then
      due[#due + 1] = mock.timers[i]
      table.remove(mock.timers, i)
    end
  end
  for i = #due, 1, -1 do
    due[i].fn()
  end
end

return mock
