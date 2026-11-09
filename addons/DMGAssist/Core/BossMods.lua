-- BossMods.lua: what's coming in this boss fight, from Deadly Boss Mods, BigWigs, or Blizzard's own timeline.
--
-- In Midnight boss mods can't read the combat log either; they identify boss abilities from Blizzard's encounter
-- timeline (C_EncounterTimeline, by timing) and publish plain, named timers through their public callbacks:
--   DBM:      DBM:RegisterCallback(event, fn)  (DBM-Core/DBM-Core.lua; event list in its DBMCallbackEvent docs)
--             DBM_TimerBegin(event, id, msg, timer, icon, simpType, spellId, colorId, modId, ...)
--               colorId: 1 adds, 2 AoE, 3 targeted, 4 interrupt, 5 role (tank), 6 phase, 7 important
--             DBM_TimerStop(event, id), DBM_TimerUpdate(event, id, elapsed, total)
--             DBM_Announce(event, msg, icon, type, spellId, modId, isSpecial, count)  type: "interrupt",
--               "defensive", "switch", "taunt", "dodge", "moveaway", "run", "soak", ...
--             DBM_SetStage, DBM_Pull, DBM_Kill, DBM_Wipe
--   BigWigs:  BigWigsLoader.RegisterMessage(owner, message, fn)  (BigWigs/Loader.lua)
--             BigWigs_StartBar(event, module, key, text, time, icon, isApprox, maxTime)
--             BigWigs_StopBar(event, module, text), BigWigs_Message(event, module, key, text, color, icon, emph)
--             BigWigs_SetStage, BigWigs_OnBossEngage, BigWigs_OnBossWin, BigWigs_OnBossWipe
--             keys "adds" and "stages" are BigWigs' own conventions for add waves and phase changes.
--   Blizzard: C_EncounterTimeline.GetEventList / GetEventTimeRemaining (time remaining readable; what the event is
--             is secret during encounters) -> "next boss event in N s" when no boss mod is installed.
--
-- We only listen; nothing is sent to the boss mods. Everything lands in one normalised list (B.timers) that feeds:
--   * SimC's raid_event.adds.* terms (lists hold AoE cooldowns for incoming adds) and raid_event.*.in generally,
--   * the HUD callout ("AoE in 3", "ADDS in 8", "INTERRUPT", "DEFENSIVE"),
--   * later: defensive and interrupt advice (task: defensives/interrupts).
-- Switch: DMGAssistDB.bossMods (default on; Options > Combat).

local _, ns = ...
local U = ns.U

local B = {}
ns.BossMods = B

local DBM_COLOR = { [1] = "adds", [2] = "aoe", [3] = "targeted", [4] = "interrupt", [5] = "role", [6] = "phase",
  [7] = "important" }
local DBM_SIMPLE = { adds = "adds", addscustom = "adds", stage = "phase", stagecount = "phase", stagecontext = "phase" }
local ALERT_KINDS = { interrupt = "interrupt", defensive = "defensive", switch = "switch", switchcount = "switch",
  taunt = "taunt", dodge = "dodge", dodgecount = "dodge", moveaway = "move", run = "move", soak = "soak" }
local ALERT_TTL = 3

B.timers = {}   -- id -> { text, spellID, expires, kind, source }
B.alerts = {}   -- kind -> { text, spellID, until, source }
B.sources = {}  -- "DBM" / "BigWigs" -> true once hooked
B.stage = nil
B.engaged = false

function B.Enabled()
  return not (ns.db and ns.db.bossMods == false)
end

local function Now()
  return GetTime()
end

local function StartTimer(id, text, seconds, spellID, kind, source)
  if not B.Enabled() or type(seconds) ~= "number" or seconds <= 0 then
    return
  end
  B.timers[source .. ":" .. tostring(id)] = { text = text, spellID = spellID, expires = Now() + seconds,
    kind = kind or "generic", source = source }
end

local function StopTimer(id, source)
  B.timers[source .. ":" .. tostring(id)] = nil
end

local function Alert(kind, text, spellID, source)
  if not B.Enabled() or not kind then
    return
  end
  B.alerts[kind] = { text = text, spellID = spellID, untilT = Now() + ALERT_TTL, source = source }
  U.Log("bossmod_alert", { kind = kind, spell = spellID, source = source })
end

local function Reset()
  B.timers, B.alerts, B.stage = {}, {}, nil
end

-- /dmga test defensive | interrupt: a pretend boss-mod alert, to see the HUD react (works with or without a boss
-- mod installed; lasts `seconds`, default 8).
function B.Test(kind, seconds)
  B.alerts[kind] = { text = "Test", untilT = Now() + (tonumber(seconds) or 8), source = "test" }
end
B.Reset = Reset

---------------------------------------------------------------------------
-- DBM
---------------------------------------------------------------------------
B.dbm = {}

function B.dbm.TimerBegin(_, id, msg, timer, _, simpType, spellId, colorId)
  local kind = DBM_COLOR[U.Read(colorId)] or DBM_SIMPLE[U.Read(simpType)]
  StartTimer(U.Read(id), U.Read(msg), U.Read(timer), U.Read(spellId), kind, "DBM")
end

function B.dbm.TimerStop(_, id)
  StopTimer(U.Read(id), "DBM")
end

function B.dbm.TimerUpdate(_, id, elapsed, total)
  local t = B.timers["DBM:" .. tostring(U.Read(id))]
  elapsed, total = U.Read(elapsed), U.Read(total)
  if t and type(elapsed) == "number" and type(total) == "number" then
    t.expires = Now() + (total - elapsed)
  end
end

function B.dbm.Announce(_, msg, _, announceType, spellId, _, isSpecial)
  local kind = ALERT_KINDS[U.Read(announceType)]
  if kind and U.Read(isSpecial) ~= false then
    Alert(kind, U.Read(msg), U.Read(spellId), "DBM")
  end
end

function B.dbm.SetStage(_, _, _, stage)
  B.stage = U.Read(stage)
end

function B.dbm.Pull()
  Reset()
  B.engaged = true
end

function B.dbm.End()
  Reset()
  B.engaged = false
end

local function HookDBM()
  if B.sources.DBM or type(DBM) ~= "table" or type(DBM.RegisterCallback) ~= "function" then
    return false
  end
  local map = {
    DBM_TimerBegin = B.dbm.TimerBegin, DBM_TimerStop = B.dbm.TimerStop, DBM_TimerUpdate = B.dbm.TimerUpdate,
    DBM_Announce = B.dbm.Announce, DBM_SetStage = B.dbm.SetStage, DBM_Pull = B.dbm.Pull, DBM_Kill = B.dbm.End,
    DBM_Wipe = B.dbm.End,
  }
  for event, fn in pairs(map) do
    pcall(DBM.RegisterCallback, DBM, event, fn)
  end
  B.sources.DBM = true
  return true
end

---------------------------------------------------------------------------
-- BigWigs
---------------------------------------------------------------------------
B.bw = {}
local BW_KEY_KIND = { adds = "adds", stages = "phase" }

function B.bw.StartBar(_, _, key, text, time, _, _, maxTime)
  key, text = U.Read(key), U.Read(text)
  local seconds = U.Read(time)
  if type(seconds) ~= "number" then
    seconds = U.Read(maxTime)
  end
  local kind = BW_KEY_KIND[key]
  StartTimer(text or key, text, seconds, type(key) == "number" and key or nil, kind, "BigWigs")
end

function B.bw.StopBar(_, _, text)
  StopTimer(U.Read(text), "BigWigs")
end

function B.bw.StopBars()
  for id, t in pairs(B.timers) do
    if t.source == "BigWigs" then
      B.timers[id] = nil
    end
  end
end

function B.bw.Message(_, _, key, text, _, _, isEmphasized)
  key = U.Read(key)
  if key == "adds" then
    Alert("switch", U.Read(text), nil, "BigWigs")
  elseif U.Read(isEmphasized) == true then
    Alert("important", U.Read(text), type(key) == "number" and key or nil, "BigWigs")
  end
end

function B.bw.SetStage(_, _, stage)
  B.stage = U.Read(stage)
end

function B.bw.Engage()
  Reset()
  B.engaged = true
end

function B.bw.End()
  Reset()
  B.engaged = false
end

B.bwOwner = {} -- BigWigs requires a table as the registering "addon"

local function HookBigWigs()
  if B.sources.BigWigs or type(BigWigsLoader) ~= "table" or type(BigWigsLoader.RegisterMessage) ~= "function" then
    return false
  end
  local map = {
    BigWigs_StartBar = B.bw.StartBar, BigWigs_StopBar = B.bw.StopBar, BigWigs_StopBars = B.bw.StopBars,
    BigWigs_Message = B.bw.Message, BigWigs_SetStage = B.bw.SetStage, BigWigs_OnBossEngage = B.bw.Engage,
    BigWigs_OnBossWin = B.bw.End, BigWigs_OnBossWipe = B.bw.End,
  }
  for message, fn in pairs(map) do
    pcall(BigWigsLoader.RegisterMessage, B.bwOwner, message, fn)
  end
  B.sources.BigWigs = true
  return true
end

-- Hook whatever is installed (call at login and on ADDON_LOADED: boss mods may load on demand).
function B.Hook()
  local a = HookDBM()
  local b = HookBigWigs()
  return a or b
end

function B.Detected()
  local out = {}
  if B.sources.DBM then
    out[#out + 1] = "DBM"
  end
  if B.sources.BigWigs then
    out[#out + 1] = "BigWigs"
  end
  return out
end

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------
-- Soonest live timer of a kind (nil = any kind): seconds, timer. Expired timers are dropped.
function B.Next(kind)
  if not B.Enabled() then
    return nil
  end
  local now = Now()
  local best, bestT
  for id, t in pairs(B.timers) do
    local left = t.expires - now
    if left < -1 then
      B.timers[id] = nil
    elseif left >= 0 and (kind == nil or t.kind == kind) and (not best or left < best) then
      best, bestT = left, t
    end
  end
  if not best and kind == nil then
    -- No boss mod timer: Blizzard's timeline still says when the next boss event lands (not what it is).
    local list = U.Get(C_EncounterTimeline and C_EncounterTimeline.GetEventList)
    if type(list) == "table" then
      for _, id in ipairs(list) do
        local left = U.Get(C_EncounterTimeline.GetEventTimeRemaining, id)
        if type(left) == "number" and left >= 0 and (not best or left < best) then
          best, bestT = left, { text = nil, kind = "generic", source = "Blizzard" }
        end
      end
    end
  end
  return best, bestT
end

function B.Alert(kind)
  local a = B.alerts[kind]
  if a and a.untilT > Now() then
    return a
  end
  return nil
end

-- SimC raid_event terms: raid_event.<type>.<field>. Only "adds" is fed by boss mods; others keep defaults.
-- Returns a number, or nil to let State use its default.
function B.RaidEvent(eventType, field)
  if not B.Enabled() or eventType ~= "adds" then
    return nil
  end
  local left = B.Next("adds")
  local switching = B.Alert("switch")
  if field == "in" then
    if switching then
      return 0
    end
    return left -- nil -> default (10000: none expected)
  elseif field == "exists" then
    if left or switching then
      return 1
    end
    return nil
  elseif field == "up" then
    return switching and 1 or 0
  elseif field == "remains" then
    return switching and ALERT_TTL or 0
  elseif field == "count" then
    return (left or switching) and 1 or 0
  end
  return nil
end

-- One line for the HUD: the most urgent thing, or nil. Alerts first, then timers within LOOKAHEAD seconds.
local LOOKAHEAD = 10
local CALLOUT_ORDER = { "interrupt", "defensive", "taunt", "switch", "move", "dodge", "soak", "important" }
local TIMER_ORDER = { "aoe", "role", "adds", "phase", "interrupt", "targeted", "important" }
local CALLOUT_TEXT = { interrupt = "INTERRUPT", defensive = "DEFENSIVE", taunt = "TAUNT", switch = "SWITCH",
  move = "MOVE", dodge = "DODGE", soak = "SOAK", important = "!", aoe = "AOE", role = "TANK HIT", adds = "ADDS",
  phase = "PHASE", targeted = "TARGETED", generic = "BOSS" }

function B.Callout()
  if not B.Enabled() then
    return nil
  end
  for _, kind in ipairs(CALLOUT_ORDER) do
    local a = B.Alert(kind)
    if a then
      return { label = CALLOUT_TEXT[kind], kind = kind, spellID = a.spellID, text = a.text }
    end
  end
  for _, kind in ipairs(TIMER_ORDER) do
    local left, t = B.Next(kind)
    if left and left <= LOOKAHEAD then
      return { label = CALLOUT_TEXT[kind], kind = kind, seconds = left, spellID = t.spellID, text = t.text }
    end
  end
  return nil
end
