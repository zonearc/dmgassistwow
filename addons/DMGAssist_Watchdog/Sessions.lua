-- Sessions.lua: one record per combat (PLAYER_REGEN_DISABLED -> ENABLED).
--
-- Each event is a small array: { t, code, a, b } where t is seconds since the
-- session started. Codes:
--   C  = player cast succeeded (a = spellID)
--   G+ = proc glow shown (a = spellID)      G- = proc glow hidden
--   R  = addon restriction state changed (a = type, b = state)
--   E  = error/blocked action (a = kind, b = message)
--   X  = encounter start/end (a = "start"/"end", b = encounterID)
--   D  = message from DMGAssist itself (a = kind, b = data)  see DMGAssistWatchdog.Log
--   P  = in-combat probe ran (a = probe index)

local _, ns = ...
local U, S = ns.U, ns.Store

local M = {}
ns.Sessions = M

local current
local lastActivity = 0

function M.Active()
  return current ~= nil
end

function M.Current()
  return current
end

local function Zone()
  local zone = U.Safe(GetRealZoneText and GetRealZoneText())
  local inInstance, instanceType = false, nil
  if IsInInstance then
    local r = U.Try(IsInInstance)
    if r.ok then
      inInstance, instanceType = r[1], r[2]
    end
  end
  return zone, inInstance, instanceType
end

local recent, recentStop -- the session that just ended, for results logged a moment after it
M.LATE = 2

function M.Start()
  local db = ns.db
  if not db or current then
    return
  end
  local zone, inInstance, instanceType = Zone()
  recent = nil
  S.Count("sessions")
  current = {
    id = db.counters.sessions,
    login = db.loginCount,
    start = U.Round2(U.Now()),
    when = date("%Y-%m-%d %H:%M:%S"),
    zone = zone,
    inInstance = inInstance,
    instanceType = instanceType,
    events = {},
    dropped = 0,
    counts = {},
  }
  S.Push(db.sessions, current, db.settings.maxSessions)
end

function M.Stop(reason)
  if not current then
    return
  end
  current.stop = U.Round2(U.Now())
  current.duration = U.Round2(current.stop - current.start)
  current.endReason = reason
  -- Our own CPU cost, so we notice if the Watchdog (or DMGAssist) gets heavy.
  if C_AddOnProfiler and C_AddOnProfiler.GetAddOnMetric and Enum and Enum.AddOnProfilerMetric then
    local perf = {}
    for _, addon in ipairs({ "DMGAssist_Watchdog", "DMGAssist" }) do
      local avg = U.Try(C_AddOnProfiler.GetAddOnMetric, addon, Enum.AddOnProfilerMetric.RecentAverageTime)
      local peak = U.Try(C_AddOnProfiler.GetAddOnMetric, addon, Enum.AddOnProfilerMetric.PeakTime)
      perf[addon] = { recentAvgMs = avg.ok and avg[1] or nil, peakMs = peak.ok and peak[1] or nil }
    end
    current.perf = perf
  end
  -- What DMGAssist works out as the fight ends (the grade) arrives just after this event: it still belongs here.
  recent, recentStop = current, U.Now()
  current = nil
end

function M.Add(code, a, b)
  lastActivity = U.Now()
  local session = current
  if not session and recent and U.Now() - recentStop <= M.LATE then
    session = recent -- end-of-fight results, logged a moment after the session closed
  end
  if not session then
    return
  end
  local db = ns.db
  session.counts[code] = (session.counts[code] or 0) + 1
  if #session.events >= db.settings.maxEventsPerSession then
    session.dropped = session.dropped + 1
    return
  end
  -- No holes in the array: JSON export of sparse arrays is unreliable.
  if a == nil then
    a = false
  end
  session.events[#session.events + 1] = { U.Round2(U.Now() - session.start), code, a, b }
end

function M.HandleEvent(event, ...)
  local db = ns.db
  if not db then
    return
  end
  if event == "PLAYER_REGEN_DISABLED" then
    M.Start()
    if ns.Probe then
      ns.Probe.OnCombatStart()
    end
  elseif event == "PLAYER_REGEN_ENABLED" then
    M.Stop("regen")
  elseif event == "PLAYER_DEAD" then
    M.Add("X", "dead")
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    if db.settings.logCasts then
      local _, _, spellID = ...
      M.Add("C", U.Safe(spellID))
    end
  elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
    if db.settings.logGlows then
      M.Add("G+", U.Safe((...)))
    end
  elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
    if db.settings.logGlows then
      M.Add("G-", U.Safe((...)))
    end
  elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
    local rtype, state = ...
    rtype, state = U.Safe(rtype), U.Safe(state)
    M.Add("R", rtype, state)
    if not current then
      S.Note("restriction", { type = rtype, state = state })
    end
  elseif event == "ENCOUNTER_START" then
    local encounterID = ...
    M.Add("X", "start", U.Safe(encounterID))
    S.Note("encounter_start", U.Safe(encounterID))
  elseif event == "ENCOUNTER_END" then
    local encounterID, _, _, _, success = ...
    M.Add("X", "end", U.Safe(encounterID))
    S.Note("encounter_end", { id = U.Safe(encounterID), success = U.Safe(success) })
  end
end

M.EVENTS = {
  "PLAYER_REGEN_DISABLED",
  "PLAYER_REGEN_ENABLED",
  "PLAYER_DEAD",
  "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW",
  "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE",
  "ADDON_RESTRICTION_STATE_CHANGED",
  "ENCOUNTER_START",
  "ENCOUNTER_END",
}
M.UNIT_EVENTS = {
  UNIT_SPELLCAST_SUCCEEDED = "player",
}

function M.LastActivity()
  return lastActivity
end
