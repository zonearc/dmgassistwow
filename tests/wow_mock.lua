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
  function FrameMethods:GetWidth()
    return self.width or 0
  end
  function FrameMethods:SetSize(w, h)
    self.width, self.height = w, h
  end
  function FrameMethods:SetText(t)
    self.text = t
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
  local noop = function() end
  for _, name in ipairs({ "SetPoint", "SetFrameStrata", "SetMovable", "EnableMouse", "RegisterForDrag",
    "SetClampedToScreen", "SetMultiLine", "SetAutoFocus", "SetFontObject", "SetWidth", "SetScrollChild",
    "SetCursorPosition", "SetFocus", "HighlightText", "ClearFocus", "StartMoving", "StopMovingOrSizing" }) do
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
  env.GetLocale = function()
    return "enUS"
  end
  env.GetRealZoneText = function()
    return "Elwynn Forest"
  end
  env.IsInInstance = function()
    return false, "none"
  end
  env.UnitClass = function()
    return "Paladin", "PALADIN", 2
  end
  env.UnitLevel = function()
    return 60
  end
  env.UnitHealth = function()
    return ctx(1000)
  end
  env.UnitPower = function(_, pt)
    if pt == 9 then -- holy power stays readable
      return 3
    end
    return ctx(50)
  end
  env.UnitPowerMax = function(_, pt)
    if pt == 0 or pt == 9 then
      return pt == 0 and 1000 or 5
    end
    return 0
  end

  env.Enum = {
    AddOnRestrictionType = { Combat = 0, Encounter = 1, ChallengeMode = 2, PvPMatch = 3, Map = 4, Chat = 5 },
    PowerType = { Mana = 0, HolyPower = 9, Rage = 1 },
    SpellBookSpellBank = { Player = 0, Pet = 1 },
    SpellBookItemType = { None = 0, Spell = 1 },
    CompressionMethod = { Deflate = 0 },
    AddOnProfilerMetric = { RecentAverageTime = 1, PeakTime = 4 },
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
  env.C_AddOns = {
    IsAddOnLoaded = function()
      return false
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
      return nil
    end,
    GetRotationSpells = function()
      return {}
    end,
  }
  env.C_ActionBar = {
    HasAssistedCombatActionButtons = function()
      return false
    end,
    FindSpellActionButtons = function(id)
      if id == 35395 then
        return { 1 }
      end
      return {}
    end,
    IsUsableAction = function()
      return true, false
    end,
  }
  env.C_CooldownViewer = {
    IsCooldownViewerAvailable = function()
      return true, ""
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
  local book = {
    { spellID = 35395, name = "Crusader Strike" },
    { spellID = 20271, name = "Judgment" },
    { spellID = 99999, name = "Passive Thing", isPassive = true },
  }
  env.C_SpellBook = {
    GetNumSpellBookSkillLines = function()
      return 1
    end,
    GetSpellBookSkillLineInfo = function()
      return { name = "Paladin", itemIndexOffset = 0, numSpellBookItems = #book, shouldHide = false }
    end,
    GetSpellBookItemInfo = function(slot)
      local b = book[slot]
      return { actionID = b.spellID, spellID = b.spellID, itemType = 1, name = b.name, isPassive = b.isPassive == true, isOffSpec = false }
    end,
  }
  env.C_Spell = {
    GetSpellName = function(id)
      for _, b in ipairs(book) do
        if b.spellID == id then
          return b.name
        end
      end
    end,
    IsSpellUsable = function()
      return true, false
    end,
    GetSpellCooldown = function()
      return { startTime = ctx(0), duration = ctx(0), isEnabled = true, isActive = false, modRate = ctx(1), isOnGCD = false }
    end,
    GetSpellCharges = function()
      return nil
    end,
  }
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
function mock.LoadAddon(dir, addonName)
  local ns = {}
  local tocPath = dir .. "/" .. addonName .. ".toc"
  local toc = assert(io.open(tocPath, "r"))
  for line in toc:lines() do
    line = line:gsub("%s+$", "")
    if line ~= "" and not line:match("^##") and not line:match("^#") then
      local chunk = assert(loadfile(dir .. "/" .. line))
      chunk(addonName, ns)
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
