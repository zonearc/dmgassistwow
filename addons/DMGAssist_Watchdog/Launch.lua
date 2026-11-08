-- Launch.lua: the state of the game and the UI from the moment we load until the first fight, so problems that
-- start at launch (another addon, a CVar, a slow load, a restriction already active) are visible in the log.
--
-- Recorded into db.launch (the last few logins) and as notes:
--   timeline   our file load -> every ADDON_LOADED (name, ms) -> PLAYER_LOGIN -> loading screens -> entering world
--   client     build, interface, project/game type, locale, screen, UI scale, framerate
--   character  class, spec, level, instance/group (no character or realm names are stored)
--   addons     every installed addon: name, version, loaded, enabled, load-on-demand, why not loadable
--   cvars      the ones that change what we see (taint log, script errors, spell queue window, nameplates, ...)
--   secrets    restriction states and C_Secrets flags at login (should all be off out of combat)
--   bindings   DMGAssist key bindings
-- DMGAssist adds its own launch state (spec, data, spells matched, list match, boss mods, settings) via its log.
--
-- Testing mode (on while we test; off for release): turns on the game's taint log at login (restored when testing
-- mode is switched off), keeps more events per fight, and says once per login that logging is on.
-- /dmgw testing on|off

local _, ns = ...
local U, S = ns.U, ns.Store

local L = {}
ns.Launch = L

-- The default for new installs is Store.lua's settings.testingMode (true while testing; false for a release).

local loadedAt = debugprofilestop and debugprofilestop() or 0
local timeline = {}
local addonOrder = {}

local function Ms()
  if not debugprofilestop then
    return 0
  end
  return math.floor(debugprofilestop() - loadedAt + 0.5)
end

function L.Mark(what)
  timeline[#timeline + 1] = { what, Ms() }
end

L.Mark("watchdog_file_loaded")

function L.OnAddonLoaded(name)
  if #addonOrder < 200 then
    addonOrder[#addonOrder + 1] = { U.Safe(name, 60), Ms() }
  end
end

local CVARS = {
  "taintLog", "scriptErrors", "SpellQueueWindow", "nameplateShowEnemies", "nameplateShowAll",
  "nameplateMaxDistance", "uiScale", "useUiScale", "assistedCombatHighlight", "autoLootDefault",
  "addonCombatRestrictionsForced", "addonEncounterRestrictionsForced", "addonChallengeModeRestrictionsForced",
  "addonPvPMatchRestrictionsForced", "addonMapRestrictionsForced", "addonChatRestrictionsForced",
}

local function CVars()
  local out = {}
  for _, name in ipairs(CVARS) do
    local ok, v = pcall(C_CVar.GetCVar, name)
    out[name] = ok and U.Safe(v) or nil
  end
  return out
end

local function Addons()
  local list = {}
  local n = U.Try(C_AddOns and C_AddOns.GetNumAddOns)
  local count = n.ok and tonumber(n[1]) or 0
  for i = 1, math.min(count, 300) do
    local info = U.Try(C_AddOns.GetAddOnInfo, i)
    if info.ok and info[1] then
      local name = info[1]
      local loaded = U.Try(C_AddOns.IsAddOnLoaded, i)
      local version = U.Try(C_AddOns.GetAddOnMetadata, name, "Version")
      local lod = U.Try(C_AddOns.IsAddOnLoadOnDemand, i)
      local enabled = U.Try(C_AddOns.GetAddOnEnableState, name)
      -- explicit ifs: these values can be false, and `ok and v or nil` would turn false into nil
      local function First(r)
        if r.ok then
          return r[1]
        end
        return nil
      end
      local entry = { name = U.Safe(name, 60), loaded = First(loaded), enabled = First(enabled),
        loadOnDemand = First(lod) }
      if version.ok then
        entry.version = U.Safe(version[1], 30)
      end
      if info[4] == false then
        entry.notLoadable = U.Safe(info[5], 40)
      end
      list[#list + 1] = entry
    end
  end
  return list
end

local function Secrets()
  local out = {}
  local types = Enum and Enum.AddOnRestrictionType or {}
  for name, value in pairs(types) do
    local r = U.Try(C_RestrictedActions and C_RestrictedActions.GetAddOnRestrictionState, value)
    out["restriction_" .. name] = r.ok and r[1] or nil
  end
  for _, fn in ipairs({ "HasSecretRestrictions", "ShouldCooldownsBeSecret", "ShouldAurasBeSecret",
    "ShouldUnitStatsBeSecret" }) do
    local r = U.Try(C_Secrets and C_Secrets[fn])
    out[fn] = r.ok and r[1] or nil
  end
  out.inCombatLockdown = U.Try(InCombatLockdown)[1]
  return out
end

local function Client()
  local c = {}
  local b = U.Try(GetBuildInfo)
  if b.ok then
    c.version, c.build, c.interface = b[1], b[2], b[4]
  end
  c.project = U.Safe(WOW_PROJECT_ID)
  c.standardGameMode = U.Try(C_GameRules and C_GameRules.IsStandard)[1]
  c.gameMode = U.Try(C_GameRules and C_GameRules.GetActiveGameMode)[1]
  c.locale = U.Try(GetLocale)[1]
  local sz = U.Try(GetPhysicalScreenSize)
  c.screen = sz.ok and (tostring(sz[1]) .. "x" .. tostring(sz[2])) or nil
  c.uiScale = U.Safe(UIParent and UIParent.GetEffectiveScale and UIParent:GetEffectiveScale())
  c.fps = U.Try(GetFramerate)[1]
  return c
end

local function Character()
  local ch = {}
  local cl = U.Try(UnitClass, "player")
  ch.class = cl.ok and cl[2] or nil
  ch.level = U.Try(UnitLevel, "player")[1]
  local idx = U.Try(C_SpecializationInfo and C_SpecializationInfo.GetSpecialization)[1]
  ch.specIndex = idx
  if type(idx) == "number" then
    local si = U.Try(C_SpecializationInfo.GetSpecializationInfo, idx)
    ch.specID = si.ok and si[1] or nil
  end
  local inst = U.Try(IsInInstance)
  ch.inInstance, ch.instanceType = inst[1], inst[2]
  ch.groupSize = U.Try(GetNumGroupMembers)[1]
  return ch
end

local function Bindings()
  local out = {}
  for _, b in ipairs({ "DMGASSIST_CYCLEMODE", "DMGASSIST_BURST", "DMGASSIST_TOGGLE" }) do
    out[b] = U.Try(GetBindingKey, b)[1] or "unbound"
  end
  return out
end

-- Called once per login, a few seconds after PLAYER_LOGIN (out of combat), and again on demand.
function L.Snapshot(reason)
  local db = ns.db
  if not db then
    return nil
  end
  local snap = {
    reason = reason,
    when = date("%Y-%m-%d %H:%M:%S"),
    timeline = timeline,
    addonLoadOrder = addonOrder,
    client = Client(),
    character = Character(),
    cvars = CVars(),
    secrets = Secrets(),
    bindings = Bindings(),
    addons = Addons(),
    testingMode = db.settings.testingMode,
  }
  db.launch = type(db.launch) == "table" and db.launch or {}
  S.Push(db.launch, snap, 3)
  local loadedCount = 0
  for _, a in ipairs(snap.addons) do
    if a.loaded then
      loadedCount = loadedCount + 1
    end
  end
  S.Note("launch", { reason = reason, addons = #snap.addons, loaded = loadedCount,
    taintLog = snap.cvars.taintLog, restricted = snap.secrets.HasSecretRestrictions })
  return snap
end

---------------------------------------------------------------------------
-- Testing mode
---------------------------------------------------------------------------
function L.TestingMode()
  return ns.db and ns.db.settings.testingMode == true
end

-- Apply testing-mode side effects (out of combat only: CVars can't change in combat).
function L.ApplyTesting(announce)
  local db = ns.db
  if not db or InCombatLockdown() then
    return
  end
  local s = db.settings
  if s.testingMode then
    local ok, current = pcall(C_CVar.GetCVar, "taintLog")
    if ok and current ~= nil and current == "0" then
      s.taintLogBefore = current
      pcall(C_CVar.SetCVar, "taintLog", "1")
    end
    s.maxEventsPerSession = math.max(s.maxEventsPerSession or 600, 1500)
    s.maxSessions = math.max(s.maxSessions or 8, 12)
    s.autoProbe, s.logCasts, s.logGlows = true, true, true
    if announce then
      U.Print("Test build: logging is on (launch, combat, taint log). After playing: /reload, then run "
        .. "tools/send-logs.py. /dmgw testing off to stop.")
    end
  else
    if s.taintLogBefore then
      pcall(C_CVar.SetCVar, "taintLog", s.taintLogBefore)
      s.taintLogBefore = nil
    end
    s.maxEventsPerSession = 600
    s.maxSessions = 8
  end
end

function L.SetTesting(on)
  if not ns.db then
    return
  end
  ns.db.settings.testingMode = on and true or false
  L.ApplyTesting(false)
  S.Note("testing_mode", { on = ns.db.settings.testingMode })
  U.Print("Testing mode %s.", on and "on" or "off")
end
