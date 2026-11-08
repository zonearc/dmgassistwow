-- Probe.lua: ask the game, in a structured way, what an addon can see.
--
-- A probe is a snapshot. It records the client build and game mode, which
-- features are switched on (Assisted Combat, Cooldown Manager...), which
-- addon restrictions are active, and then sweeps the player's spellbook,
-- asking for every spell whether its cooldown / aura / cast is secret and what
-- the readable APIs return. Run once out of combat and once in combat, the
-- two snapshots tell us exactly which inputs a rotation engine can rely on.
--
-- Every call goes through U.Try (pcall + U.Safe), so a missing or protected
-- API shows up as an error string in the export instead of breaking anything.

local _, ns = ...
local U, S = ns.U, ns.Store

local P = {}
ns.Probe = P

local MAX_SPELLS = 160
local combatProbeDone = false
local COMBAT_PROBE_DELAY = 3

local RESTRICTION_CVARS = {
  "addonCombatRestrictionsForced",
  "addonEncounterRestrictionsForced",
  "addonChallengeModeRestrictionsForced",
  "addonPvPMatchRestrictionsForced",
  "addonMapRestrictionsForced",
  "addonChatRestrictionsForced",
}

local OTHER_CVARS = {
  "assistedCombatHighlight",
  "cooldownViewerEnabled",
  "scriptErrors",
  "taintLog",
  "taintLogObjectSecrets",
}

-- Primary and secondary power types we care about. Looked up through Enum so
-- a missing entry on some client is simply skipped.
local POWER_TYPES = {
  "Mana", "Rage", "Focus", "Energy", "ComboPoints", "Runes", "RunicPower",
  "SoulShards", "LunarPower", "HolyPower", "Maelstrom", "Chi", "Insanity",
  "ArcaneCharges", "Fury", "Pain", "Essence",
}

local function Call(path, ...)
  return U.Try(U.Resolve(path), ...)
end

local function First(path, ...)
  local r = Call(path, ...)
  if r.ok then
    return r[1]
  end
  return "error: " .. tostring(r.err)
end

-- First and second return of a U.Try result, or an error string. Written out
-- explicitly: `r.ok and r[1] or "error"` would turn a real `false` into "error".
local function Values(r)
  if not r.ok then
    return "error: " .. tostring(r.err), nil
  end
  return r[1], r[2]
end

local function GetCVarSafe(name)
  local getter = (C_CVar and C_CVar.GetCVar) or GetCVar
  local r = U.Try(getter, name)
  if not r.ok then
    return "error"
  end
  if r[1] == nil then
    return "<missing>"
  end
  return r[1]
end

local function Environment()
  local env = {}
  local b = U.Try(GetBuildInfo)
  if b.ok then
    env.version, env.build, env.buildDate, env.interface = b[1], b[2], b[3], b[4]
  end
  env.locale = First("GetLocale")
  env.gameModeStandard = First("C_GameRules.IsStandard")
  env.gameMode = First("C_GameRules.GetActiveGameMode")
  local c = U.Try(UnitClass, "player")
  if c.ok then
    env.class, env.classID = c[2], c[3]
  end
  env.level = First("UnitLevel", "player")
  local specIndex = First("C_SpecializationInfo.GetSpecialization")
  if type(specIndex) ~= "number" then
    specIndex = First("GetSpecialization")
  end
  env.specIndex = specIndex
  if type(specIndex) == "number" then
    local si = Call("C_SpecializationInfo.GetSpecializationInfo", specIndex)
    if not si.ok then
      si = Call("GetSpecializationInfo", specIndex)
    end
    if si.ok then
      env.specID, env.specName = si[1], si[2]
    end
  end
  env.inCombatLockdown = First("InCombatLockdown")
  env.inCombatSession = ns.Sessions.Active()
  env.zone = U.Safe(GetRealZoneText and GetRealZoneText())
  local inst = U.Try(IsInInstance)
  if inst.ok then
    env.inInstance, env.instanceType = inst[1], inst[2]
  end
  env.watchdogVersion = ns.VERSION
  env.mainAddonLoaded = First("C_AddOns.IsAddOnLoaded", "DMGAssist")
  return env
end

local function Features()
  local f = {}
  f.assistedCombatAvailable, f.assistedCombatFailureReason = Values(Call("C_AssistedCombat.IsAvailable"))
  f.assistedCombatActionSpell = First("C_AssistedCombat.GetActionSpell")
  f.assistedCombatNextCast = First("C_AssistedCombat.GetNextCastSpell", false)
  local getRotation = U.Resolve("C_AssistedCombat.GetRotationSpells")
  if getRotation then
    local okRaw, list = pcall(getRotation)
    if okRaw and type(list) == "table" and not U.IsSecret(list) then
      local ids = {}
      for i = 1, math.min(#list, 40) do
        ids[i] = U.Safe(list[i])
      end
      f.assistedCombatRotationSpells = ids
    else
      f.assistedCombatRotationSpells = "unreadable: " .. tostring(U.Safe(list))
    end
  else
    f.assistedCombatRotationSpells = "missing"
  end
  f.hasAssistedCombatActionButtons = First("C_ActionBar.HasAssistedCombatActionButtons")
  f.cooldownViewerAvailable, f.cooldownViewerFailureReason = Values(Call("C_CooldownViewer.IsCooldownViewerAvailable"))
  f.damageMeterAvailable = Values(Call("C_DamageMeter.IsDamageMeterAvailable"))
  f.encoderAvailable = U.Resolve("C_EncodingUtil.SerializeJSON") ~= nil
  return f
end

local function Restrictions()
  local r = { states = {} }
  if Enum and Enum.AddOnRestrictionType then
    for name, value in pairs(Enum.AddOnRestrictionType) do
      r.states[name] = First("C_RestrictedActions.GetAddOnRestrictionState", value)
    end
  end
  r.hasSecretRestrictions = First("C_Secrets.HasSecretRestrictions")
  r.cooldownsSecret = First("C_Secrets.ShouldCooldownsBeSecret")
  r.aurasSecret = First("C_Secrets.ShouldAurasBeSecret")
  r.unitStatsSecret = First("C_Secrets.ShouldUnitStatsBeSecret")
  r.cvars = {}
  for _, name in ipairs(RESTRICTION_CVARS) do
    r.cvars[name] = GetCVarSafe(name)
  end
  for _, name in ipairs(OTHER_CVARS) do
    r.cvars[name] = GetCVarSafe(name)
  end
  return r
end

-- Is the secret machinery itself usable from addon code? Grab values that are
-- documented as (possibly) secret and see whether issecretvalue/canaccessvalue
-- accept them without erroring.
local function SecretSelfTest()
  local t = {}
  t.issecretvalueExists = issecretvalue ~= nil
  t.canaccessvalueExists = canaccessvalue ~= nil
  local samples = {
    healthPlayer = { UnitHealth, "player" },
    healthTarget = { UnitHealth, "target" },
    powerPlayer = { UnitPower, "player" },
  }
  for label, spec in pairs(samples) do
    local okCall, value = pcall(spec[1], spec[2])
    local row = { callOk = okCall }
    if okCall then
      row.type = type(value)
      if issecretvalue then
        local okS, isS = pcall(issecretvalue, value)
        row.issecretvalueOk = okS
        if okS then
          row.isSecret = isS == true
        end
      end
      if canaccessvalue then
        local okA, canA = pcall(canaccessvalue, value)
        row.canaccessvalueOk = okA
        if okA then
          row.canAccess = canA == true
        end
      end
      row.value = U.Safe(value)
    end
    t[label] = row
  end
  return t
end

local function Powers()
  local out = {}
  if not (Enum and Enum.PowerType) then
    return out
  end
  for _, name in ipairs(POWER_TYPES) do
    local pt = Enum.PowerType[name]
    if pt ~= nil then
      local row = {
        max = Values(Call("UnitPowerMax", "player", pt)),
        value = First("UnitPower", "player", pt),
        secretFlag = First("C_Secrets.ShouldUnitPowerBeSecret", "player", pt),
        secrecy = First("C_Secrets.GetPowerTypeSecrecy", pt),
      }
      -- Only keep power types this character actually has (max > 0) or that
      -- came back unreadable, which is itself informative.
      local unreadable = type(row.max) == "string"
      if unreadable or (type(row.max) == "number" and row.max > 0) then
        out[name] = row
      end
    end
  end
  return out
end

local function CollectSpellIDs()
  local ids, seen = {}, {}
  local book = C_SpellBook
  if not (book and book.GetNumSpellBookSkillLines and book.GetSpellBookSkillLineInfo and book.GetSpellBookItemInfo) then
    return ids, "C_SpellBook missing"
  end
  local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
  local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell or 1
  local okN, numLines = pcall(book.GetNumSpellBookSkillLines)
  if not okN or type(numLines) ~= "number" or U.IsSecret(numLines) then
    return ids, "GetNumSpellBookSkillLines failed"
  end
  for line = 1, numLines do
    local okL, info = pcall(book.GetSpellBookSkillLineInfo, line)
    if okL and type(info) == "table" and not info.shouldHide and not info.offSpecID then
      local first = info.itemIndexOffset + 1
      local last = info.itemIndexOffset + info.numSpellBookItems
      for slot = first, last do
        local okI, item = pcall(book.GetSpellBookItemInfo, slot, bank)
        if okI and type(item) == "table" and item.itemType == spellType and not item.isPassive and not item.isOffSpec then
          local id = U.Safe(item.spellID or item.actionID)
          if type(id) == "number" and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
            if #ids >= MAX_SPELLS then
              return ids, "capped"
            end
          end
        end
      end
    end
  end
  return ids
end

local function ProbeSpell(id)
  local row = { id = id }
  row.name = First("C_Spell.GetSpellName", id)
  row.cdSecret = First("C_Secrets.ShouldSpellCooldownBeSecret", id)
  row.auraSecret = First("C_Secrets.ShouldSpellAuraBeSecret", id)
  row.castSecrecy = First("C_Secrets.GetSpellCastSecrecy", id)
  row.cdSecrecy = First("C_Secrets.GetSpellCooldownSecrecy", id)
  row.auraSecrecy = First("C_Secrets.GetSpellAuraSecrecy", id)
  local usable = Call("C_Spell.IsSpellUsable", id)
  if usable.ok then
    row.usable, row.noPower = usable[1], usable[2]
  else
    row.usable = "error: " .. tostring(usable.err)
  end
  local okCd, cd = pcall(U.Resolve("C_Spell.GetSpellCooldown"), id)
  if okCd and type(cd) == "table" and not U.IsSecret(cd) then
    row.cdActive = U.Safe(cd.isActive)
    row.cdEnabled = U.Safe(cd.isEnabled)
    row.cdOnGCD = U.Safe(cd.isOnGCD)
    row.cdDuration = U.Safe(cd.duration)
  elseif not okCd then
    row.cdError = U.Safe(cd)
  else
    row.cdError = "not a readable table"
  end
  local okCh, ch = pcall(U.Resolve("C_Spell.GetSpellCharges"), id)
  if okCh and type(ch) == "table" and not U.IsSecret(ch) then
    row.charges = U.Safe(ch.currentCharges)
    row.maxCharges = U.Safe(ch.maxCharges)
  end
  row.overlayed = First("C_SpellActivationOverlay.IsSpellOverlayed", id)
  local okB, slots = pcall(U.Resolve("C_ActionBar.FindSpellActionButtons"), id)
  if okB and type(slots) == "table" and not U.IsSecret(slots) then
    row.barSlots = #slots
    local slot = slots[1]
    if slot ~= nil and not U.IsSecret(slot) then
      local ua = Call("C_ActionBar.IsUsableAction", slot)
      if ua.ok then
        row.actionUsable, row.actionLackingResources = ua[1], ua[2]
      end
    end
  end
  return row
end

local function SpellSweep()
  local ids, note = CollectSpellIDs()
  local rows = {}
  for i = 1, #ids do
    rows[i] = ProbeSpell(ids[i])
  end
  return rows, note
end

-- label: "login", "combat", "manual"
-- Can addons read Blizzard's Cooldown Manager frames (item.isActive / IsShown) and the encounter timeline?
-- Records types only ("boolean", "number", "secret", "nil") so nothing secret is ever stored.
local function Kind(v)
  if v == nil then
    return "nil"
  end
  if U.IsSecret(v) then
    return "secret"
  end
  return type(v)
end

local function CooldownManager()
  local out = {}
  for _, name in ipairs({ "BuffIconCooldownViewer", "BuffBarCooldownViewer", "EssentialCooldownViewer",
    "UtilityCooldownViewer" }) do
    local viewer = _G[name]
    local entry = { exists = type(viewer) == "table" }
    if entry.exists and type(viewer.GetChildren) == "function" then
      local ok, kids = pcall(function()
        return { viewer:GetChildren() }
      end)
      kids = ok and kids or {}
      entry.children = #kids
      entry.items = {}
      for i = 1, math.min(#kids, 6) do
        local item = kids[i]
        local shownOk, shown = pcall(item.IsShown, item)
        entry.items[i] = {
          cooldownID = Kind(item.cooldownID),
          isActive = Kind(item.isActive),
          auraInstanceID = Kind(item.auraInstanceID),
          shown = shownOk and Kind(shown) or "error",
        }
      end
    end
    out[name] = entry
  end
  return out
end

local function Timeline()
  local out = { available = type(C_EncounterTimeline) == "table" }
  if out.available then
    local ok, list = pcall(C_EncounterTimeline.GetEventList)
    out.listKind = ok and Kind(list) or "error"
    if ok and type(list) == "table" and not U.IsSecret(list) then
      out.events = #list
      local id = list[1]
      if id ~= nil then
        local okR, remaining = pcall(C_EncounterTimeline.GetEventTimeRemaining, id)
        out.remainingKind = okR and Kind(remaining) or "error"
      end
    end
  end
  out.dbm = type(DBM) == "table" and Kind(DBM.Revision or DBM.DisplayVersion) or "absent"
  out.bigwigs = type(BigWigsLoader) == "table" and "present" or "absent"
  return out
end

function P.Run(label)
  local db = ns.db
  if not db then
    return nil
  end
  local started = debugprofilestop and debugprofilestop() or nil
  local result = {
    label = label,
    t = U.Round2(U.Now()),
    when = date("%Y-%m-%d %H:%M:%S"),
    env = Environment(),
    features = Features(),
    restrictions = Restrictions(),
    secretSelfTest = SecretSelfTest(),
    powers = Powers(),
  }
  local okC, cdm = pcall(CooldownManager)
  result.cooldownManager = okC and cdm or { error = U.Safe(cdm) }
  local okT, tl = pcall(Timeline)
  result.timeline = okT and tl or { error = U.Safe(tl) }
  result.spells, result.spellNote = SpellSweep()
  if started then
    result.costMs = U.Round2(debugprofilestop() - started)
  end
  S.Push(db.probes, result, db.settings.maxProbes)
  S.Count("probes")
  ns.Sessions.Add("P", #db.probes, label)
  return result
end

-- First real combat of this login: probe a few seconds in, while restrictions
-- are definitely active.
function P.OnCombatStart()
  local db = ns.db
  if combatProbeDone or not (db and db.settings.autoProbe) then
    return
  end
  if not (C_Timer and C_Timer.After) then
    return
  end
  C_Timer.After(COMBAT_PROBE_DELAY, function()
    if combatProbeDone or not ns.Sessions.Active() then
      return
    end
    combatProbeDone = true
    local ok, err = pcall(P.Run, "combat")
    if not ok then
      ns.Errors.Record("probe", err)
    end
  end)
end

function P.Latest(label)
  local probes = ns.db and ns.db.probes or {}
  for i = #probes, 1, -1 do
    if label == nil or probes[i].label == label then
      return probes[i]
    end
  end
end
