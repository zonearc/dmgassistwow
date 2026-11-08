local SECRET_MT = {
  __tostring = function(self) return "<SecretValue>" end,
  __concat = function(a, b)
    return MakeSecret(tostring(a) .. tostring(b))
  end,
  __add = function(a, b) return MakeSecret(0) end,
  __sub = function(a, b) return MakeSecret(0) end,
  __mul = function(a, b) return MakeSecret(0) end,
  __div = function(a, b) return MakeSecret(0) end,
  __lt = function(a, b) return false end,
  __le = function(a, b) return false end,
  __eq = function(a, b) return false end,
}

function MakeSecret(val)
  return setmetatable({ _val = val, _isSecret = true }, SECRET_MT)
end

local function IsSecret(val)
  return type(val) == "table" and val._isSecret == true
end

local MockState = {
  time = 1000,
  inCombat = false,
  combatStartTime = 0,
  playerHealth = 100000,
  playerHealthMax = 100000,
  targetHealth = 500000,
  targetHealthMax = 500000,
  targetExists = true,
  targetCasting = false,
  targetCastInterruptible = true,
  power = 0,
  powerMax = 100,
  powerType = 0,
  runes = {true, true, true, true, true, true},
  moving = false,
  stealthed = false,
  shapeshiftForm = 0,
  shapeshiftFormName = "",
  haste = 0,
  gcdStart = 0,
  gcdDuration = 0,
  prevGCD = "",
  activeEnemies = 1,

  buffs = {},
  debuffs = {},
  cooldowns = {},
  spellCharges = {},
  highlights = {},
  actionBarGlows = {},
  knownSpells = {},
  usableSpells = {},
  talentsEnabled = {},
  spellCastTimes = {},
  spellCosts = {},
  petAlive = false,
  totems = {},
  vars = {},

  taintMode = false,
  taintRules = {
    UnitPower = true,
    IsSpellUsable = true,
    GetSpellCooldown = true,
  },
}

local function deepCopy(t)
  if type(t) ~= "table" then return t end
  local copy = {}
  for k, v in pairs(t) do copy[k] = deepCopy(v) end
  return copy
end

function MockState:Reset()
  self.time = 1000
  self.inCombat = false
  self.combatStartTime = 0
  self.playerHealth = 100000
  self.playerHealthMax = 100000
  self.targetHealth = 500000
  self.targetHealthMax = 500000
  self.targetExists = true
  self.targetCasting = false
  self.targetCastInterruptible = true
  self.power = 0
  self.powerMax = 100
  self.powerType = 0
  self.runes = {true, true, true, true, true, true}
  self.moving = false
  self.stealthed = false
  self.shapeshiftForm = 0
  self.shapeshiftFormName = ""
  self.haste = 0
  self.gcdStart = 0
  self.gcdDuration = 0
  self.prevGCD = ""
  self.activeEnemies = 1
  self.buffs = {}
  self.debuffs = {}
  self.cooldowns = {}
  self.spellCharges = {}
  self.highlights = {}
  self.actionBarGlows = {}
  self.knownSpells = {}
  self.usableSpells = {}
  self.talentsEnabled = {}
  self.spellCastTimes = {}
  self.spellCosts = {}
  self.petAlive = false
  self.totems = {}
  self.vars = {}
  self.taintMode = false
  self.taintRules = {
    UnitPower = true,
    IsSpellUsable = true,
    GetSpellCooldown = true,
  }
end

function MockState:EnableTaint(rules)
  self.taintMode = true
  if rules then
    self.taintRules = rules
  end
end

function MockState:DisableTaint()
  self.taintMode = false
end

function MockState:ShouldTaint(apiName)
  return self.taintMode and self.inCombat and self.taintRules[apiName] == true
end

function MockState:AddBuff(name, remains, stacks, duration)
  self.buffs[name:lower()] = {
    up = true,
    remains = remains or 999,
    stacks = stacks or 1,
    duration = duration or remains or 10,
    maxStacks = stacks or 1,
    expirationTime = self.time + (remains or 999),
  }
end

function MockState:RemoveBuff(name)
  self.buffs[name:lower()] = nil
end

function MockState:AddDebuff(name, remains, stacks, duration)
  self.debuffs[name:lower()] = {
    up = true,
    remains = remains or 999,
    stacks = stacks or 1,
    duration = duration or remains or 10,
    expirationTime = self.time + (remains or 999),
  }
end

function MockState:RemoveDebuff(name)
  self.debuffs[name:lower()] = nil
end

function MockState:SetCooldown(name, remains, duration)
  self.cooldowns[name:lower()] = {
    start = self.time - ((duration or 10) - (remains or 0)),
    duration = duration or 10,
    remains = remains or 0,
  }
end

function MockState:SetCooldownReady(name)
  self.cooldowns[name:lower()] = nil
end

function MockState:SetHighlight(spellName, highlightType)
  self.highlights[spellName:lower()] = highlightType
end

function MockState:SetGlow(spellName, glowing)
  self.actionBarGlows[spellName:lower()] = glowing
end

function MockState:SetSpellKnown(name, known)
  self.knownSpells[name:lower()] = known ~= false
end

function MockState:SetSpellUsable(name, usable)
  self.usableSpells[name:lower()] = usable ~= false
end

function MockState:SetTalent(name, enabled)
  self.talentsEnabled[name:lower()] = enabled ~= false
end

function MockState:SetTotem(name, active, remains)
  self.totems[name:lower()] = { active = active ~= false, remains = remains or 0 }
end

function MockState:AdvanceTime(seconds)
  self.time = self.time + seconds
  for name, buff in pairs(self.buffs) do
    buff.remains = buff.remains - seconds
    buff.expirationTime = self.time + buff.remains
    if buff.remains <= 0 then self.buffs[name] = nil end
  end
  for name, debuff in pairs(self.debuffs) do
    debuff.remains = debuff.remains - seconds
    debuff.expirationTime = self.time + debuff.remains
    if debuff.remains <= 0 then self.debuffs[name] = nil end
  end
  for name, cd in pairs(self.cooldowns) do
    cd.remains = cd.remains - seconds
    if cd.remains <= 0 then self.cooldowns[name] = nil end
  end
end

function MockState:EnterCombat()
  self.inCombat = true
  self.combatStartTime = self.time
end

function MockState:LeaveCombat()
  self.inCombat = false
end

function MockState:CastSpell(name, cdDuration, resourceCost)
  local n = name:lower():gsub("[%s%-']", "_"):gsub("[^%w_]", "")
  cdDuration = cdDuration or 8
  if cdDuration > 0 then
    self.cooldowns[n] = {
      start = self.time,
      duration = cdDuration,
      remains = cdDuration,
    }
  end
  if resourceCost and resourceCost > 0 then
    self.power = math.max(0, self.power - resourceCost)
  end
  self.prevGCD = n
  local gcdDur = math.max(0.75, 1.5 / (1 + self.haste / 100))
  self.gcdStart = self.time
  self.gcdDuration = gcdDur
end

function MockState:SetSpellCharges(name, charges, maxCharges, start, duration)
  local n = name:lower():gsub("[%s%-']", "_"):gsub("[^%w_]", "")
  self.spellCharges[n] = {
    charges = charges or 1,
    maxCharges = maxCharges or 2,
    start = start or self.time,
    duration = duration or 15,
  }
end

local function normalize(name)
  if not name then return "" end
  return name:lower():gsub("[%s%-']", "_"):gsub("[^%w_]", "")
end

_G.GetTime = function() return MockState.time end

_G.UnitHealth = function(unit)
  if unit == "player" then return MockState.playerHealth end
  if unit == "target" then return MockState.targetHealth end
  return 100000
end

_G.UnitHealthMax = function(unit)
  if unit == "player" then return MockState.playerHealthMax end
  if unit == "target" then return MockState.targetHealthMax end
  return 100000
end

_G.UnitPower = function(unit, powerType)
  if MockState:ShouldTaint("UnitPower") then
    return MakeSecret(MockState.power)
  end
  return MockState.power
end

_G.UnitPowerMax = function(unit, powerType)
  return MockState.powerMax
end

_G.UnitExists = function(unit)
  if unit == "target" then return MockState.targetExists end
  if unit == "pet" then return MockState.petAlive end
  return true
end

_G.UnitIsDead = function(unit)
  if unit == "pet" then return not MockState.petAlive end
  if unit == "target" then return MockState.targetHealth <= 0 end
  return false
end

_G.UnitCanAttack = function(a, b) return true end

_G.UnitCastingInfo = function(unit)
  if unit == "target" and MockState.targetCasting then
    return "TestCast", nil, nil, nil, MockState.time + 2, nil, nil, not MockState.targetCastInterruptible
  end
  return nil
end

_G.UnitChannelInfo = function(unit) return nil end
_G.UnitName = function(unit) return unit end
_G.UnitClass = function(unit) return "Warrior", "WARRIOR", 1 end
_G.UnitLevel = function(unit) return 80 end
_G.UnitGUID = function(unit) return "Player-1-00000001" end

_G.InCombatLockdown = function() return MockState.inCombat end
_G.IsStealthed = function() return MockState.stealthed end
_G.GetUnitSpeed = function(unit) return MockState.moving and 7 or 0 end
_G.GetHaste = function() return MockState.haste end

_G.GetShapeshiftForm = function() return MockState.shapeshiftForm end
_G.GetShapeshiftFormInfo = function(index)
  if index == MockState.shapeshiftForm and MockState.shapeshiftForm > 0 then
    return nil, nil, nil, MockState.shapeshiftFormName
  end
  return nil
end
_G.GetNumShapeshiftForms = function() return MockState.shapeshiftForm > 0 and 4 or 0 end

_G.GetRuneCooldown = function(i)
  if MockState.runes[i] then return 0, 0, true end
  return MockState.time - 5, 10, false
end

_G.GetSpellCooldown = function(spellIdOrName)
  if spellIdOrName == 61304 then
    return MockState.gcdStart, MockState.gcdDuration, 1
  end
  local name = normalize(tostring(spellIdOrName))
  local cd = MockState.cooldowns[name]
  if cd and cd.remains > 0 then
    if MockState:ShouldTaint("GetSpellCooldown") then
      return MakeSecret(cd.start), MakeSecret(cd.duration), 1
    end
    return cd.start, cd.duration, 1
  end
  return 0, 0, 1
end

_G.GetSpellCharges = function(name)
  local n = normalize(name)
  local c = MockState.spellCharges[n]
  if c then return c.charges, c.maxCharges, c.start, c.duration, c.modRate or 1 end
  return nil
end

_G.GetItemCooldown = function(itemId) return 0, 0, 1 end

_G.IsPlayerSpell = function(name) return MockState.knownSpells[normalize(name)] ~= false end
_G.IsUsableSpell = function(name)
  local val = MockState.usableSpells[normalize(name)] ~= false
  if MockState:ShouldTaint("IsSpellUsable") then
    return MakeSecret(val), false
  end
  return val, false
end
_G.IsSpellInRange = function(name, unit) return 1 end

_G.GetActionInfo = function(slot) return nil end
_G.GetActionTexture = function(slot) return nil end
_G.HasAction = function(slot) return false end
_G.IsActionInRange = function(slot) return true end
_G.GetBindingKey = function(cmd) return nil end
_G.GetBonusBarOffset = function() return 0 end
_G.NUM_ACTIONBAR_BUTTONS = 12

_G.issecretvalue = function(val) return IsSecret(val) end

_G.C_Spell = {
  GetSpellTexture = function(id) return "Interface\\Icons\\INV_Misc_QuestionMark" end,
  GetSpellInfo = function(name)
    local n = normalize(name)
    return {
      name = name,
      castTime = (MockState.spellCastTimes[n] or 0) * 1000,
      spellID = 12345,
    }
  end,
  GetSpellCooldown = function(name)
    local n = normalize(name)
    local cd = MockState.cooldowns[n]
    if cd and cd.remains > 0 then
      if MockState:ShouldTaint("GetSpellCooldown") then
        return { startTime = MakeSecret(cd.start), duration = MakeSecret(cd.duration), isEnabled = true }
      end
      return { startTime = cd.start, duration = cd.duration, isEnabled = true }
    end
    return { startTime = 0, duration = 0, isEnabled = true }
  end,
  GetSpellCharges = function(name)
    local n = normalize(name)
    local c = MockState.spellCharges[n]
    if c then return { currentCharges = c.charges, maxCharges = c.maxCharges } end
    return nil
  end,
  IsSpellUsable = function(name)
    local val = MockState.usableSpells[normalize(name)] ~= false
    if MockState:ShouldTaint("IsSpellUsable") then
      return MakeSecret(val)
    end
    return val
  end,
  GetSpellPowerCost = function(name)
    local n = normalize(name)
    local cost = MockState.spellCosts[n]
    if cost then return {{cost = cost, type = MockState.powerType}} end
    return {}
  end,
  GetSpellName = function(id) return tostring(id) end,
}

_G.C_SpellHighlight = {
  GetHighlightType = function(spellId)
    return 0
  end,
}

local mockAuraData = {}

_G.C_UnitAuras = {
  GetBuffDataByIndex = function(unit, index, filter)
    return nil
  end,
  GetDebuffDataByIndex = function(unit, index, filter)
    return nil
  end,
  GetAuraDataBySpellName = function(unit, name, filter)
    local n = normalize(name)
    if unit == "player" then
      local b = MockState.buffs[n]
      if b then
        return {
          name = name,
          applications = b.stacks,
          expirationTime = b.expirationTime,
          duration = b.duration,
          maxCharges = b.maxStacks or 1,
          spellId = 99999,
        }
      end
    elseif unit == "target" then
      local d = MockState.debuffs[n]
      if d then
        return {
          name = name,
          applications = d.stacks,
          expirationTime = d.expirationTime,
          duration = d.duration,
          spellId = 99999,
        }
      end
    end
    return nil
  end,
  GetPlayerAuraBySpellID = function(spellId) return nil end,
}

_G.AuraUtil = {
  ForEachAura = function(unit, filter, maxCount, func)
    local source
    if unit == "player" then source = MockState.buffs
    elseif unit == "target" then source = MockState.debuffs
    else return end
    local i = 0
    for name, data in pairs(source) do
      i = i + 1
      local auraData = {
        name = name,
        applications = data.stacks,
        expirationTime = data.expirationTime,
        duration = data.duration,
        spellId = 99999,
        isHelpful = (unit == "player"),
        isHarmful = (unit == "target"),
      }
      if func(auraData) then return end
      if maxCount and i >= maxCount then return end
    end
  end,
}

_G.C_ClassTalents = {
  GetActiveConfigID = function() return 1 end,
}

_G.C_Traits = {
  GetConfigInfo = function(configID)
    return { treeIDs = {1} }
  end,
  GetTreeNodes = function(treeID)
    local nodes = {}
    local i = 1
    for name, enabled in pairs(MockState.talentsEnabled) do
      if enabled then nodes[i] = i; i = i + 1 end
    end
    return nodes
  end,
  GetNodeInfo = function(configID, nodeID)
    return { activeEntry = { entryID = nodeID }, currentRank = 1, maxRank = 1 }
  end,
  GetEntryInfo = function(configID, entryID)
    return { definitionID = entryID }
  end,
  GetDefinitionInfo = function(defID)
    return { spellID = 99990 + defID }
  end,
}

_G.C_NamePlate = {
  GetNamePlates = function()
    local plates = {}
    for i = 1, MockState.activeEnemies do
      plates[i] = { namePlateUnitToken = "nameplate" .. i }
    end
    return plates
  end,
}

_G.GetTotemInfo = function(slot)
  return false, nil, 0, 0
end

_G.PlaySoundFile = function() end
_G.PlaySound = function() end

_G.print = print
_G.date = os.date
_G.time = os.time
_G.strsplit = function(sep, str, max)
  local parts = {}
  local pattern = "([^" .. sep .. "]*)" .. sep .. "?"
  for part in str:gmatch(pattern) do
    parts[#parts + 1] = part
    if max and #parts >= max then break end
  end
  return table.unpack(parts)
end
_G.strjoin = function(sep, ...)
  return table.concat({...}, sep)
end
_G.tinsert = table.insert
_G.tremove = table.remove
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
_G.format = string.format

_G.CreateFrame = function(frameType, name, parent, template)
  local frame = {
    _scripts = {},
    _children = {},
    _shown = true,
    _width = 0,
    _height = 0,
    _points = {},
    _alpha = 1,
    Show = function(self) self._shown = true end,
    Hide = function(self) self._shown = false end,
    IsShown = function(self) return self._shown end,
    SetShown = function(self, s) self._shown = s end,
    SetSize = function(self, w, h) self._width = w; self._height = h end,
    SetWidth = function(self, w) self._width = w end,
    SetHeight = function(self, h) self._height = h end,
    GetWidth = function(self) return self._width end,
    GetHeight = function(self) return self._height end,
    SetPoint = function(self, ...) end,
    ClearAllPoints = function(self) end,
    SetAllPoints = function(self) end,
    SetParent = function(self, p) end,
    GetParent = function(self) return parent end,
    SetAlpha = function(self, a) self._alpha = a end,
    GetAlpha = function(self) return self._alpha end,
    SetScale = function(self, s) end,
    GetScale = function(self) return 1 end,
    SetFrameStrata = function(self, s) end,
    SetFrameLevel = function(self, l) end,
    GetFrameLevel = function(self) return 1 end,
    SetClampedToScreen = function(self, c) end,
    SetMovable = function(self, m) end,
    EnableMouse = function(self, e) end,
    SetResizable = function(self, r) end,
    RegisterForDrag = function(self, ...) end,
    SetScript = function(self, event, fn) self._scripts[event] = fn end,
    GetScript = function(self, event) return self._scripts[event] end,
    HookScript = function(self, event, fn) self._scripts[event] = fn end,
    RegisterEvent = function(self, event) end,
    UnregisterEvent = function(self, event) end,
    UnregisterAllEvents = function(self) end,
    SetBackdrop = function(self, bd) end,
    SetBackdropColor = function(self, ...) end,
    SetBackdropBorderColor = function(self, ...) end,
    CreateTexture = function(self, name, layer)
      return {
        SetTexture = function() end,
        SetTexCoord = function() end,
        SetAllPoints = function() end,
        SetPoint = function() end,
        SetSize = function() end,
        SetWidth = function() end,
        SetHeight = function() end,
        SetVertexColor = function() end,
        SetAlpha = function() end,
        Show = function() end,
        Hide = function() end,
        SetShown = function() end,
        ClearAllPoints = function() end,
        SetDesaturated = function() end,
        GetTexture = function() return nil end,
      }
    end,
    CreateFontString = function(self, name, layer, template)
      return {
        SetText = function(s, t) end,
        GetText = function() return "" end,
        SetFont = function() end,
        SetTextColor = function() end,
        SetJustifyH = function() end,
        SetJustifyV = function() end,
        SetPoint = function() end,
        SetAllPoints = function() end,
        SetSize = function() end,
        SetWidth = function() end,
        SetWordWrap = function() end,
        Show = function() end,
        Hide = function() end,
        SetShown = function() end,
        ClearAllPoints = function() end,
        SetAlpha = function() end,
      }
    end,
    CreateAnimationGroup = function(self)
      return {
        CreateAnimation = function(self, atype)
          return {
            SetDuration = function() end,
            SetFromAlpha = function() end,
            SetToAlpha = function() end,
            SetChange = function() end,
            SetSmoothing = function() end,
            SetOrder = function() end,
          }
        end,
        Play = function() end,
        Stop = function() end,
        SetLooping = function() end,
        IsPlaying = function() return false end,
        SetScript = function() end,
      }
    end,
    SetMinResize = function() end,
    SetMaxResize = function() end,
    SetResizeBounds = function() end,
  }
  if name then _G[name] = frame end
  return frame
end

_G.UIParent = CreateFrame("Frame", "UIParent")
_G.GameFontNormal = "GameFontNormal"
_G.GameFontHighlight = "GameFontHighlight"
_G.GameFontNormalSmall = "GameFontNormalSmall"
_G.GameFontHighlightSmall = "GameFontHighlightSmall"
_G.GameTooltip = CreateFrame("Frame", "GameTooltip")
_G.GameTooltip.SetOwner = function() end
_G.GameTooltip.AddLine = function() end
_G.GameTooltip.ClearLines = function() end
_G.GameTooltip.Show = function() end
_G.GameTooltip.Hide = function() end
_G.GameTooltip.SetHyperlink = function() end

_G.InterfaceOptionsFrame_OpenToCategory = function() end
_G.Settings = _G.Settings or {}
_G.Settings.OpenToCategory = function() end
_G.Settings.RegisterCanSaveCallback = function() end

_G.GetSpecialization = function() return 1 end
_G.GetSpecializationInfo = function(i) return 99, "Test", "Test spec", nil, nil, nil end

_G.SlashCmdList = {}
_G.SLASH_DMGA1 = "/dmga"
_G.SLASH_DMGA2 = "/dmgassist"

_G.C_Timer = {
  After = function(delay, fn) end,
  NewTicker = function(interval, fn, iterations)
    return { Cancel = function() end }
  end,
}

_G.Minimap = CreateFrame("Frame", "Minimap")
_G.MinimapBackdrop = CreateFrame("Frame", "MinimapBackdrop")

_G.BackdropTemplateMixin = {}
_G.DEFAULT_CHAT_FRAME = { AddMessage = function() end }

_G.IsAltKeyDown = function() return false end
_G.IsControlKeyDown = function() return false end
_G.IsShiftKeyDown = function() return false end

_G.GetAddOnMetadata = function(addon, key)
  if key == "Version" then return "1.5.0" end
  return nil
end

_G.C_AddOns = {
  GetAddOnMetadata = _G.GetAddOnMetadata,
}

_G.LibStub = false

_G.hooksecurefunc = function(table_or_name, name_or_fn, fn)
end

_G.securecall = function(fn, ...)
  if type(fn) == "function" then return fn(...) end
end

_G.pcall = pcall
_G.xpcall = xpcall
_G.loadstring = load
_G.mathMax = math.max
_G.mathMin = math.min
_G.mathFloor = math.floor
_G.mathCeil = math.ceil
_G.mathAbs = math.abs
_G.tableInsert = table.insert
_G.tableRemove = table.remove
_G.tableSort = table.sort
_G.strFormat = string.format
_G.tonumber = tonumber
_G.tostring = tostring
_G.type = type
_G.pairs = pairs
_G.ipairs = ipairs
_G.next = next
_G.select = select
_G.unpack = table.unpack or unpack
_G.rawset = rawset
_G.rawget = rawget
_G.setmetatable = setmetatable
_G.getmetatable = getmetatable
_G.error = error
_G.assert = assert

_G.CheckInteractDistance = function() return true end
_G.SpellIsTargeting = function() return false end

_G.GetContainerNumSlots = function() return 0 end
_G.GetContainerItemInfo = function() return nil end
_G.C_Container = {
  GetContainerNumSlots = function() return 0 end,
  GetContainerItemInfo = function() return nil end,
  GetContainerItemID = function() return nil end,
}

_G.GetInventoryItemID = function() return nil end
_G.GetInventoryItemLink = function() return nil end

return MockState
