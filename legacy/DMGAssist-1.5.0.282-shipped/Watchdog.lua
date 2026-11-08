
local ADDON_NAME = "DMGAssist"
local WD_VERSION = "1.5.0.282"
local POLL_INTERVAL = 0.5
local MAX_EVENTS = 200
local STUCK_THRESHOLD = 4.0
local HEARTBEAT_TIMEOUT = 6.0
local EMPTY_QUEUE_COMBAT_THRESHOLD = 3.0

local function Detaint(val)
  if type(val) == "nil" then return nil end
  if issecretvalue and issecretvalue(val) then return nil end
  return tonumber(val)
end

DMGA_WD_Log = DMGA_WD_Log or {}
DMGA_WD_Config = DMGA_WD_Config or {}
DMGA_WD_APIScan = DMGA_WD_APIScan or {}

local defaults = {
  enabled = false,
  monitorHeartbeat = true,
  monitorStuckQueue = true,
  monitorTaint = true,
  monitorCombat = true,
  monitorErrors = true,
  monitorActionBlocked = true,
  monitorEmptyQueue = true,
  chatAlerts = false,
  autoSnapshot = true,
  minimapIcon = true,
}
for k, v in pairs(defaults) do
  if DMGA_WD_Config[k] == nil then DMGA_WD_Config[k] = v end
end

local wdFrame = CreateFrame("Frame", "DMGAWatchdogFrame")
local lastHeartbeat = 0
local lastHeartbeatVal = 0
local lastQueueStr = ""
local stuckSince = 0
local lastAlertTimes = {}
local addonLoaded = false
local lastErrorCount = 0
local lastEmptyQueueTime = 0
local emptyQueueReported = false
local lastTrackedGCD = nil
local lastTrackedSlot1 = nil
local lastTrackedAcRec = nil
local lastTrackedAcRecName = nil
local sessionEvents = {}
local viewerFrame, activeTab, lastSeenEventCount, unseenCount
lastSeenEventCount = 0
unseenCount = 0
activeTab = "log"

local combatSessions = {}
local currentSessionIdx = nil

local function StartCombatSession(ev)
  if currentSessionIdx and combatSessions[currentSessionIdx] then
    local prev = combatSessions[currentSessionIdx]
    if not prev.endTime then
      prev.endTime = ev.time
      local dur = (ev.rawGameTime or 0) - (prev.startGameTime or 0)
      prev.duration = string.format("%.1fs", math.max(0, dur))
    end
  end
  local session = {
    startTime = ev.time,
    startGameTime = ev.rawGameTime or 0,
    endTime = nil,
    duration = nil,
    events = { ev },
  }
  table.insert(combatSessions, session)
  currentSessionIdx = #combatSessions
end

local function EndCombatSession(ev)
  if currentSessionIdx and combatSessions[currentSessionIdx] then
    local s = combatSessions[currentSessionIdx]
    s.endTime = ev.time
    local dur = (ev.rawGameTime or 0) - (s.startGameTime or 0)
    s.duration = string.format("%.1fs", math.max(0, dur))
    table.insert(s.events, ev)
    currentSessionIdx = nil
  end
end

local function AddEventToCurrentSession(ev)
  if currentSessionIdx and combatSessions[currentSessionIdx] then
    table.insert(combatSessions[currentSessionIdx].events, ev)
  end
end

-- ═══════════════════════════════════════════════════════════════════════
-- Subsystem Health Registry
-- Each subsystem registers a name + health check function.
-- On combat end (or /dmgawd health), all checks run and failures log.
-- ═══════════════════════════════════════════════════════════════════════
local subsystemRegistry = {}

local function RegisterSubsystem(name, checkFn)
  subsystemRegistry[name] = checkFn
end

local function RunHealthChecks()
  local results = {}
  for name, checkFn in pairs(subsystemRegistry) do
    local ok, result = pcall(checkFn)
    if ok and type(result) == "table" then
      results[name] = result
    else
      results[name] = { ok = false, lastUpdate = 0, eventCount = 0, errors = { SafeToString(result or "check failed") } }
    end
  end
  return results
end

local function FormatHealthReport(results)
  local lines = {}
  table.insert(lines, "--- Subsystem Health ---")
  local sortedNames = {}
  for name in pairs(results) do table.insert(sortedNames, name) end
  table.sort(sortedNames)
  for _, name in ipairs(sortedNames) do
    local r = results[name]
    local status = r.ok and "|cFF00CC00OK|r" or "|cFFFF4444FAIL|r"
    local line = "  " .. name .. ": " .. status
    if r.eventCount and r.eventCount > 0 then
      line = line .. " (events: " .. r.eventCount .. ")"
    end
    if r.lastUpdate and r.lastUpdate > 0 then
      line = line .. " (updated: " .. string.format("%.1fs ago", GetTime() - r.lastUpdate) .. ")"
    end
    table.insert(lines, line)
    if r.errors and #r.errors > 0 then
      for _, err in ipairs(r.errors) do
        table.insert(lines, "    ! " .. err)
      end
    end
  end
  if #sortedNames == 0 then
    table.insert(lines, "  (no subsystems registered)")
  end
  return lines
end

local function FormatHealthReportPlain(results)
  local lines = {}
  table.insert(lines, "--- Subsystem Health ---")
  local sortedNames = {}
  for name in pairs(results) do table.insert(sortedNames, name) end
  table.sort(sortedNames)
  for _, name in ipairs(sortedNames) do
    local r = results[name]
    local status = r.ok and "OK" or "FAIL"
    local line = "  " .. name .. ": " .. status
    if r.eventCount and r.eventCount > 0 then
      line = line .. " (events: " .. r.eventCount .. ")"
    end
    if r.lastUpdate and r.lastUpdate > 0 then
      line = line .. " (updated: " .. string.format("%.1fs ago", GetTime() - r.lastUpdate) .. ")"
    end
    table.insert(lines, line)
    if r.errors and #r.errors > 0 then
      for _, err in ipairs(r.errors) do
        table.insert(lines, "    ! " .. err)
      end
    end
  end
  if #sortedNames == 0 then
    table.insert(lines, "  (no subsystems registered)")
  end
  return lines
end

-- Register CLF subsystems if DMGAssist is loaded
local function RegisterCLFSubsystems()
  local clf = SafeRead(function() return _G.CLF end, nil)
  if not clf then return end

  RegisterSubsystem("ResourceTracker", function()
    local snap = SafeReadField(clf, "_snap", nil)
    return {
      ok = snap ~= nil and SafeReadField(snap, "power", nil) ~= nil,
      lastUpdate = SafeReadField(clf, "_lastSnapshotTime", 0),
      eventCount = SafeReadField(clf, "_resourceEventCount", 0),
      errors = {},
    }
  end)

  RegisterSubsystem("AuraTracker", function()
    local auraState = SafeReadField(clf, "_auraState", nil)
    return {
      ok = auraState ~= nil,
      lastUpdate = SafeReadField(clf, "_lastAuraUpdate", 0),
      eventCount = SafeReadField(clf, "_auraEventCount", 0),
      errors = {},
    }
  end)

  RegisterSubsystem("CastTracker", function()
    return {
      ok = true,
      lastUpdate = SafeReadField(clf, "_lastCastUpdate", 0),
      eventCount = SafeReadField(clf, "_castEventCount", 0),
      errors = {},
    }
  end)

  RegisterSubsystem("SnapshotCache", function()
    local snap = SafeReadField(clf, "_snap", nil)
    return {
      ok = snap ~= nil and SafeReadField(snap, "time", nil) ~= nil,
      lastUpdate = SafeReadField(clf, "_lastSnapshotTime", 0),
      errors = {},
    }
  end)

  RegisterSubsystem("CDTracker", function()
    return {
      ok = true,
      lastUpdate = SafeReadField(clf, "_lastCDUpdate", 0),
      eventCount = SafeReadField(clf, "_cdEventCount", 0),
      errors = {},
    }
  end)

  RegisterSubsystem("ActionBarScanner", function()
    local slots = SafeReadField(clf, "_actionBarSlots", nil)
    local count = 0
    if slots then for _ in pairs(slots) do count = count + 1 end end
    return {
      ok = count > 0,
      lastUpdate = SafeReadField(clf, "_lastScanTime", 0),
      eventCount = count,
      errors = count == 0 and { "No action bar slots scanned" } or {},
    }
  end)

  RegisterSubsystem("APLEvaluator", function()
    local topSpells = SafeReadField(clf, "_topSpells", nil)
    return {
      ok = topSpells ~= nil,
      lastUpdate = SafeReadField(clf, "_lastEvalTime", 0),
      eventCount = SafeReadField(clf, "_evalCount", 0),
      errors = {},
    }
  end)

  RegisterSubsystem("HUDRenderer", function()
    local hudFrame = SafeReadField(clf, "_hudFrame", nil)
    return {
      ok = hudFrame ~= nil,
      lastUpdate = SafeReadField(clf, "_lastHUDUpdate", 0),
      eventCount = SafeReadField(clf, "_hudUpdateCount", 0),
      errors = {},
    }
  end)

  RegisterSubsystem("EnemyCounter", function()
    return {
      ok = true,
      lastUpdate = SafeReadField(clf, "_lastEnemyUpdate", 0),
      eventCount = SafeReadField(clf, "_enemyCount", 0),
      errors = {},
    }
  end)

  RegisterSubsystem("BossModBridge", function()
    local bmActive = SafeReadField(clf, "_bossModActive", false)
    return {
      ok = true,
      lastUpdate = SafeReadField(clf, "_lastBossModUpdate", 0),
      eventCount = 0,
      errors = not bmActive and { "No boss mod detected (DBM/BigWigs)" } or {},
    }
  end)
end

local function UpdateUnseenBadge()
  local total = #DMGA_WD_Log
  if total > lastSeenEventCount then
    unseenCount = total - lastSeenEventCount
  end
end

local function SafeRead(func, fallback)
  local ok, result = pcall(func)
  if ok then return result end
  return fallback
end

local function SafeReadField(tbl, key, fallback)
  if type(tbl) ~= "table" then return fallback end
  local ok, val = pcall(function() return tbl[key] end)
  if not ok or val == nil then return fallback end
  if issecretvalue and issecretvalue(val) then return fallback end
  return val
end

local function SafeToString(val)
  if val == nil then return "nil" end
  if issecretvalue and issecretvalue(val) then return "<tainted>" end
  local ok, s = pcall(tostring, val)
  if ok then
    if issecretvalue and issecretvalue(s) then return "<tainted>" end
    return s
  end
  return "<unreadable>"
end

local function ThrottleCheck(key, cooldown)
  local now = GetTime()
  cooldown = cooldown or 15
  if lastAlertTimes[key] and (now - lastAlertTimes[key]) < cooldown then return false end
  lastAlertTimes[key] = now
  return true
end

local function GetContentType()
  local ok, name, iType, diffID, diffName = pcall(function()
    return GetInstanceInfo()
  end)
  if not ok then return "unknown", "unknown", 0, "unknown" end
  local ctype = "open_world"
  if iType == "party" then ctype = "dungeon"
  elseif iType == "raid" then ctype = "raid"
  elseif iType == "scenario" then
    if diffName and string.find(string.lower(SafeToString(diffName)), "delve") then ctype = "delve"
    else ctype = "scenario" end
  elseif iType == "arena" then ctype = "arena"
  elseif iType == "pvp" then ctype = "battleground"
  end
  return ctype, SafeToString(name or ""), diffID or 0, SafeToString(diffName or "")
end

local function GetPlayerContext()
  local ctx = { time = date("%H:%M:%S"), gameTime = string.format("%.1f", GetTime() % 1000) }
  ctx.class = SafeRead(function() return select(2, UnitClass("player")) end, "?")
  ctx.level = SafeRead(function() return UnitLevel("player") end, 0)
  ctx.health = SafeRead(function()
    local rawHP = UnitHealth("player")
    local rawMax = UnitHealthMax("player")
    if rawHP == nil or rawMax == nil then return 1 end
    if issecretvalue and issecretvalue(rawHP) then return 1 end
    if issecretvalue and issecretvalue(rawMax) then return 1 end
    local mx = tonumber(rawMax) or 0
    if mx > 0 then return (tonumber(rawHP) or 0) / mx end
    return 1
  end, 1)
  ctx.inCombat = SafeRead(function()
    local v = InCombatLockdown()
    if issecretvalue and issecretvalue(v) then return "tainted" end
    return v and true or false
  end, false)
  ctx.contentType, ctx.instanceName, ctx.difficultyID, ctx.difficultyName = GetContentType()
  local clf = _G.CLF
  if clf then
    ctx.heartbeat = SafeReadField(clf, "_heartbeat", 0)
    ctx.degraded = SafeReadField(clf, "_runtimeDegraded", false)
    ctx.errorCount = SafeReadField(clf, "_runtimeErrorCount", 0)
    ctx.combatMode = SafeReadField(clf, "combatMode", "?")
    ctx.form = SafeReadField(clf, "_cachedFormName", "caster")
    ctx.spec = SafeRead(function()
      local cfg = CLF_Config or CLF_DefaultConfig
      if cfg and cfg.spec then return cfg.spec.specName .. " " .. cfg.spec.className end
      return "?"
    end, "?")
    ctx.power = SafeRead(function()
      local snap = clf._snap
      if snap then return { current = snap.power or 0, max = snap.powerMax or 0, type = snap.powerType or "?" } end
      return { current = 0, max = 0, type = "?" }
    end, { current = 0, max = 0, type = "?" })
    ctx.enemies = SafeRead(function() return clf.ActiveEnemies and clf.ActiveEnemies() or 0 end, 0)
    ctx.castState = SafeRead(function()
      local cs = clf._castState and clf._castState.player
      if cs and cs.casting then
        local elapsed = GetTime() - (cs.startTime or GetTime())
        return { spell = cs.spellName or "?", dur = string.format("%.2f", cs.duration or 0), elapsed = string.format("%.2f", elapsed), src = cs.channeling and "channel" or "cast" }
      end
      return nil
    end, nil)
    ctx.castObs = SafeRead(function()
      local obs = clf._castObservations
      if not obs then return nil end
      local result = {}
      local count = 0
      for name, data in pairs(obs) do
        if data.count >= 3 then
          result[name] = string.format("%.2fs (n=%d)", data.avgTime, data.count)
          count = count + 1
          if count >= 10 then break end
        end
      end
      if count == 0 then return nil end
      return result
    end, nil)
    ctx.stuckSpell = SafeReadField(clf, "_stuckSpell", nil)
    ctx.stuckCount = SafeReadField(clf, "_stuckCount", 0)
    ctx.aplFallbackAdded = SafeReadField(clf, "_lastAplFallbackCount", 0)
    ctx.aplFallbackSkipped = SafeReadField(clf, "_lastAplFallbackSkipped", 0)
    local ls = SafeReadField(clf, "_lastSnapshot", nil)
    if ls then
      ctx.queueSize = SafeRead(function() return ls.queue and #ls.queue or 0 end, 0)
      ctx.candidateSize = SafeRead(function() return ls.candidates and #ls.candidates or 0 end, 0)
      ctx.queue = {}
      SafeRead(function()
        if ls.queue then
          for i, q in ipairs(ls.queue) do
            if i > 5 then break end
            ctx.queue[i] = {
              spell = SafeReadField(q, "spell", "?"),
              signal = SafeReadField(q, "signal", "?"),
              priority = SafeReadField(q, "priority", 0),
              cd = SafeReadField(q, "cdRemaining", 0),
              range = SafeReadField(q, "inRange", true),
              usable = SafeReadField(q, "usable", false),
              eventCD = SafeReadField(q, "eventCD", nil),
            }
          end
        end
      end, nil)
      ctx.candidates = {}
      SafeRead(function()
        if ls.candidates then
          for i, c in ipairs(ls.candidates) do
            if i > 25 then break end
            ctx.candidates[i] = {
              spell = SafeReadField(c, "spell", "?"),
              signal = SafeReadField(c, "signal", "?"),
              usable = SafeReadField(c, "usable", false),
              score = SafeReadField(c, "score", 0),
              range = SafeReadField(c, "inRange", true),
              eventCD = SafeReadField(c, "eventCD", nil),
              reason = SafeReadField(c, "reason", nil),
            }
          end
        end
      end, nil)
    end
    ctx.taintStats = {}
    SafeRead(function()
      local ts = clf._taintStats
      if ts then
        for k, v in pairs(ts) do
          if v and v > 0 then ctx.taintStats[k] = v end
        end
      end
    end, nil)
    ctx.conditionErrors = {}
    SafeRead(function()
      local ce = clf._conditionErrors
      if ce then
        for k, v in pairs(ce) do
          ctx.conditionErrors[k] = SafeReadField(v, "count", 0)
        end
      end
    end, nil)
    ctx.recentIssues = {}
    SafeRead(function()
      local il = clf._issueLog
      if il and #il > 0 then
        local start = math.max(1, #il - 7)
        for i = start, #il do
          local issue = il[i]
          table.insert(ctx.recentIssues, {
            cat = SafeReadField(issue, "category", "?"),
            msg = SafeReadField(issue, "message", "?"),
            n = SafeReadField(issue, "count", 1),
          })
        end
      end
    end, nil)
    ctx.wdEvents = {}
    SafeRead(function()
      local wde = clf._wdEvents
      if wde and #wde > 0 then
        local start = math.max(1, #wde - 9)
        for i = start, #wde do
          local ev = wde[i]
          table.insert(ctx.wdEvents, {
            t = SafeReadField(ev, "t", "?"),
            clock = SafeReadField(ev, "clock", "?"),
            d = SafeReadField(ev, "d", {}),
          })
        end
      end
    end, nil)
    ctx.spellBookSummary = SafeRead(function()
      local sb = clf._spellBook
      if not sb then return { total = 0, withCD = 0, onCD = 0, missing = 0 } end
      local total, withCD, onCD, missing = 0, 0, 0, 0
      local onCDList = {}
      local now = GetTime()
      for k, v in pairs(sb) do
        total = total + 1
        if v.cdDuration and v.cdDuration > 1.5 then withCD = withCD + 1 end
        if v.cdReadyAt and v.cdReadyAt > now then
          onCD = onCD + 1
          if #onCDList < 5 then
            table.insert(onCDList, (v.name or k) .. "=" .. string.format("%.0fs", v.cdReadyAt - now))
          end
        end
        if v.isKnown == false then missing = missing + 1 end
      end
      return { total = total, withCD = withCD, onCD = onCD, missing = missing, onCDSpells = table.concat(onCDList, ", ") }
    end, { total = 0 })

    ctx.statsSnapshot = SafeRead(function()
      local ss = clf._statsSnapshot
      if not ss then return nil end
      return {
        haste = string.format("%.1f", ss.haste or 0),
        crit = string.format("%.1f", ss.crit or 0),
        mastery = string.format("%.1f", ss.mastery or 0),
        vers = string.format("%.1f", ss.versatility or 0),
        gcdHasted = string.format("%.2f", ss.gcdHasted or 1.5),
        age = ss.snapshotTime and string.format("%.0fs", GetTime() - ss.snapshotTime) or "never",
      }
    end, nil)

    ctx.resourceTracker = SafeRead(function()
      local rt = clf._resTracker
      if not rt then return nil end
      local curVal = rt.current
      local maxVal = rt.max
      if issecretvalue and type(curVal) == "number" and issecretvalue(curVal) then curVal = "<tainted>" end
      if issecretvalue and type(maxVal) == "number" and issecretvalue(maxVal) then maxVal = "<tainted>" end
      return {
        current = curVal,
        max = maxVal,
        regen = string.format("%.1f", rt.regenRate or 0),
        lastCalibrate = rt.lastCalibrate and string.format("%.0fs ago", GetTime() - rt.lastCalibrate) or "never",
        source = rt.source or "?",
      }
    end, nil)

    ctx.cdSources = {}
    SafeRead(function()
      local snap = clf._lastSnapshot
      if snap and snap.candidates then
        for i, c in ipairs(snap.candidates) do
          if i > 10 then break end
          local cn = string.gsub(string.gsub(string.lower(c.spell or ""), "_", " "), ":", "")
          local src = "none"
          local be = clf._spellBook and clf._spellBook[cn]
          if be and be.cdReadyAt and be.cdReadyAt > 0 then
            src = "book(cdReadyAt)"
          elseif clf._castLog and clf._castLog[cn] and clf._knownCDDur and clf._knownCDDur[cn] then
            src = "castLog"
          elseif clf._barCD and clf._barCD[cn] then
            src = "barCD"
          elseif be then
            src = "book(ready)"
          end
          ctx.cdSources[c.spell or cn] = src
        end
      end
    end, nil)

    ctx.activeAuras = {}
    SafeRead(function()
      if C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
        for i = 1, 40 do
          local ok, aura = pcall(C_UnitAuras.GetBuffDataByIndex, "player", i)
          if not ok or type(aura) ~= "table" then break end
          local nameStr = DetaintStr(aura.name)
          if nameStr then
            table.insert(ctx.activeAuras, nameStr)
          end
        end
      end
    end, nil)
    ctx.targetDebuffs = {}
    SafeRead(function()
      local auraState = clf._auraState
      if not auraState then return end
      local prefix = "target:"
      local now = GetTime()
      for k, a in pairs(auraState) do
        if string.sub(k, 1, #prefix) == prefix and a.name then
          local rem = (a.expiration or 0) - now
          if rem > 0 then
            table.insert(ctx.targetDebuffs, a.name .. "(" .. string.format("%.0f", rem) .. "s)")
          else
            table.insert(ctx.targetDebuffs, a.name .. "(expired)")
          end
        end
      end
    end, nil)
    ctx.targetGUIDInfo = SafeRead(function()
      return {
        unitGUID = clf._targetGUID or "nil",
        cleuGUID = clf._cleuTargetGUID or "nil",
      }
    end, { unitGUID = "nil", cleuGUID = "nil" })
    ctx.gcdInfo = SafeRead(function()
      if C_Spell and C_Spell.GetSpellCooldown then
        local ok, cd = pcall(C_Spell.GetSpellCooldown, 61304)
        if ok and type(cd) == "table" then
          return { start = Detaint(cd.startTime) or 0, duration = Detaint(cd.duration) or 0 }
        end
      end
      return { start = 0, duration = 0 }
    end, { start = 0, duration = 0 })
    ctx.signalDiag = {}
    SafeRead(function()
      local sd = clf._signalDiag
      if sd then
        for spellKey, d in pairs(sd) do
          table.insert(ctx.signalDiag, {
            spell = spellKey,
            id = SafeReadField(d, "id", 0),
            slot = SafeReadField(d, "slot", 0),
            signal = SafeReadField(d, "signal", 0),
            hl = SafeReadField(d, "hl", "nil"),
            hlS = SafeReadField(d, "hlS", false),
            ol = SafeReadField(d, "ol", "nil"),
            olS = SafeReadField(d, "olS", false),
            glow = SafeReadField(d, "glow", 0),
            kids = SafeReadField(d, "kids", nil),
          })
        end
      end
    end, nil)
    ctx.slot1Diag = SafeRead(function()
      local s1 = clf._slot1Diag
      if not s1 then return nil end
      return {
        spell = SafeReadField(s1, "spell", "?"),
        signal = SafeReadField(s1, "signal", "?"),
        texType = SafeReadField(s1, "texType", "?"),
        texVal = SafeReadField(s1, "texVal", "?"),
        isCD = SafeReadField(s1, "isCD", "?"),
        baseA = SafeReadField(s1, "baseA", 0),
        fadeA = SafeReadField(s1, "fadeA", 0),
        finalA = SafeReadField(s1, "finalA", 0),
        shown = SafeReadField(s1, "shown", "?"),
        iconShown = SafeReadField(s1, "iconShown", "?"),
      }
    end, nil)
  else
    ctx.clfMissing = true
  end
  return ctx
end

local function PushEvent(eventType, summary, extraData)
  local rawGT = GetTime()
  local ev = {
    id = #DMGA_WD_Log + 1,
    type = eventType,
    summary = summary,
    time = date("%H:%M:%S"),
    gameTime = string.format("%.1f", rawGT % 1000),
    rawGameTime = rawGT,
    context = nil,
    extra = extraData or {},
  }
  if DMGA_WD_Config.autoSnapshot then
    ev.context = SafeRead(GetPlayerContext, {})
  end
  table.insert(DMGA_WD_Log, ev)
  if #DMGA_WD_Log > MAX_EVENTS then table.remove(DMGA_WD_Log, 1) end
  table.insert(sessionEvents, ev)
  if #sessionEvents > MAX_EVENTS then table.remove(sessionEvents, 1) end
  if eventType == "COMBAT_START" then
    StartCombatSession(ev)
  elseif eventType == "COMBAT_END" then
    if currentSessionIdx then
      EndCombatSession(ev)
    end
  else
    AddEventToCurrentSession(ev)
  end
  if DMGA_WD_Config.chatAlerts then
    local colors = {
      ALERT = "|cFFFF4444", WARN = "|cFFFFAA00", INFO = "|cFF00CC00",
      SCAN = "|cFF44AAFF", EVENT = "|cFFCCCCCC",
    }
    local sev = "EVENT"
    if eventType == "CRASH" or eventType == "DEGRADED" or eventType == "ACTION_BLOCKED" or eventType == "HEARTBEAT_LOST" or eventType == "INIT_FAILURE" then sev = "ALERT"
    elseif eventType == "QUEUE_STUCK" or eventType == "EMPTY_QUEUE" or eventType == "TAINT_SPIKE" or eventType == "ERROR_BURST" then sev = "WARN"
    elseif eventType == "INIT" or eventType == "COMBAT_START" or eventType == "COMBAT_END" or eventType == "SPEC_CHANGE" then sev = "INFO"
    elseif eventType == "API_SCAN" then sev = "SCAN"
    end
    local isCombatData = (eventType == "CAST" or eventType == "QUEUE" or eventType == "AC_REC")
    if not isCombatData then
      local c = colors[sev] or "|cFFCCCCCC"
      print("|cFF8866CC[DMGA]|r " .. c .. "[" .. eventType .. "]|r " .. (summary or ""))
    end
  end
  UpdateUnseenBadge()
  if viewerFrame and viewerFrame:IsShown() and DMGAWDRefreshViewer then
    DMGAWDRefreshViewer()
  end
  return ev
end

local function FormatValue(val, indent)
  indent = indent or ""
  if issecretvalue and issecretvalue(val) then return "<tainted>" end
  if type(val) == "table" then
    local parts = {}
    local isArray = #val > 0
    if isArray then
      for i, v in ipairs(val) do
        table.insert(parts, indent .. "  " .. FormatValue(v, indent .. "  "))
      end
    else
      local keys = {}
      for k in pairs(val) do
        if not (issecretvalue and issecretvalue(k)) then
          table.insert(keys, k)
        end
      end
      table.sort(keys, function(a, b) return SafeToString(a) < SafeToString(b) end)
      for _, k in ipairs(keys) do
        local fOk, fv = pcall(function() return val[k] end)
        local child = fOk and FormatValue(fv, indent .. "  ") or "<unreadable>"
        table.insert(parts, indent .. "  " .. SafeToString(k) .. ": " .. child)
      end
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts, "\n") .. "\n" .. indent .. "}"
  else
    return SafeToString(val)
  end
end

local function FormatEventForCopy(ev)
  local lines = {}
  table.insert(lines, "=== DMGA WATCHDOG EVENT ===")
  table.insert(lines, "Type: " .. SafeToString(ev.type))
  table.insert(lines, "Time: " .. SafeToString(ev.time) .. " (game: " .. SafeToString(ev.gameTime) .. ")")
  table.insert(lines, "Summary: " .. SafeToString(ev.summary))
  table.insert(lines, "Version: " .. WD_VERSION)
  table.insert(lines, "")
  if ev.extra and next(ev.extra) then
    table.insert(lines, "--- Event Data ---")
    for k, v in pairs(ev.extra) do
      table.insert(lines, SafeToString(k) .. ": " .. FormatValue(v))
    end
    table.insert(lines, "")
  end
  if ev.context and next(ev.context) then
    local ctx = ev.context
    table.insert(lines, "--- Player State ---")
    table.insert(lines, "Spec: " .. SafeToString(ctx.spec))
    table.insert(lines, "Class: " .. SafeToString(ctx.class))
    table.insert(lines, "Health: " .. string.format("%.0f%%", (ctx.health or 1) * 100))
    table.insert(lines, "InCombat: " .. SafeToString(ctx.inCombat))
    table.insert(lines, "Form: " .. SafeToString(ctx.form))
    table.insert(lines, "CombatMode: " .. SafeToString(ctx.combatMode))
    table.insert(lines, "Enemies: " .. SafeToString(ctx.enemies))
    table.insert(lines, "Content: " .. SafeToString(ctx.contentType) .. " (" .. SafeToString(ctx.instanceName) .. " " .. SafeToString(ctx.difficultyName) .. ")")
    if ctx.power then
      table.insert(lines, "Power: " .. SafeToString(ctx.power.current) .. "/" .. SafeToString(ctx.power.max) .. " (" .. SafeToString(ctx.power.type) .. ")")
    end
    table.insert(lines, "Heartbeat: " .. SafeToString(ctx.heartbeat))
    table.insert(lines, "Degraded: " .. SafeToString(ctx.degraded))
    table.insert(lines, "ErrorCount: " .. SafeToString(ctx.errorCount))
    if ctx.stuckSpell then
      table.insert(lines, "StuckSpell: " .. SafeToString(ctx.stuckSpell) .. " x" .. SafeToString(ctx.stuckCount))
    end
    if ctx.gcdInfo then
      table.insert(lines, "GCD: start=" .. SafeToString(ctx.gcdInfo.start) .. " dur=" .. SafeToString(ctx.gcdInfo.duration))
    end
    table.insert(lines, "")
    if ctx.queue and #ctx.queue > 0 then
      table.insert(lines, "--- Queue (" .. #ctx.queue .. ") ---")
      for i, q in ipairs(ctx.queue) do
        local qUsableTag = q.usable and "Y" or "N"
        local qECD = q.eventCD and (" ecd=" .. SafeToString(q.eventCD)) or ""
        table.insert(lines, "  " .. i .. ". " .. SafeToString(q.spell) .. " [" .. SafeToString(q.signal) .. "] p=" .. SafeToString(q.priority) .. " cd=" .. SafeToString(q.cd) .. " usable=" .. qUsableTag .. qECD .. " range=" .. SafeToString(q.range))
      end
      table.insert(lines, "")
    end
    if ctx.candidates and #ctx.candidates > 0 then
      table.insert(lines, "--- All Candidates (" .. #ctx.candidates .. ") ---")
      for i, c in ipairs(ctx.candidates) do
        local cUsableTag = c.usable and "Y" or "N"
        local cECD = c.eventCD and (" ecd=" .. SafeToString(c.eventCD)) or ""
        local cReason = c.reason and (" why=" .. SafeToString(c.reason)) or ""
        table.insert(lines, "  " .. i .. ". " .. SafeToString(c.spell) .. " [" .. SafeToString(c.signal) .. "] score=" .. SafeToString(c.score) .. " usable=" .. cUsableTag .. cECD .. " range=" .. SafeToString(c.range) .. cReason)
      end
      table.insert(lines, "")
    end
    if ctx.spellBookSummary then
      local sb = ctx.spellBookSummary
      table.insert(lines, "--- Spell Book ---")
      table.insert(lines, "  Tracked: " .. SafeToString(sb.total) .. "  WithCD: " .. SafeToString(sb.withCD) .. "  OnCD: " .. SafeToString(sb.onCD) .. "  Missing: " .. SafeToString(sb.missing))
      if sb.onCDSpells and sb.onCDSpells ~= "" then
        table.insert(lines, "  OnCD: " .. SafeToString(sb.onCDSpells))
      end
      table.insert(lines, "")
    end
    if ctx.aplFallbackAdded or ctx.aplFallbackSkipped then
      table.insert(lines, "--- APL Fallback ---")
      table.insert(lines, "  Injected: " .. SafeToString(ctx.aplFallbackAdded or 0) .. "  Skipped(onBar): " .. SafeToString(ctx.aplFallbackSkipped or 0))
      table.insert(lines, "")
    end
    if ctx.statsSnapshot then
      local ss = ctx.statsSnapshot
      table.insert(lines, "--- Stats Snapshot ---")
      table.insert(lines, "  Haste=" .. SafeToString(ss.haste) .. "% Crit=" .. SafeToString(ss.crit) .. "% Mastery=" .. SafeToString(ss.mastery) .. "% Vers=" .. SafeToString(ss.vers) .. "%")
      table.insert(lines, "  GCD=" .. SafeToString(ss.gcdHasted) .. "s  Age=" .. SafeToString(ss.age))
      table.insert(lines, "")
    end
    if ctx.resourceTracker then
      local rt = ctx.resourceTracker
      table.insert(lines, "--- Resource Tracker ---")
      table.insert(lines, "  Current=" .. SafeToString(rt.current) .. "/" .. SafeToString(rt.max) .. "  Regen=" .. SafeToString(rt.regen) .. "/s  Source=" .. SafeToString(rt.source) .. "  LastCal=" .. SafeToString(rt.lastCalibrate))
      table.insert(lines, "")
    end
    if ctx.cdSources and next(ctx.cdSources) then
      table.insert(lines, "--- CD Sources ---")
      for k, v in pairs(ctx.cdSources) do
        table.insert(lines, "  " .. SafeToString(k) .. " = " .. SafeToString(v))
      end
      table.insert(lines, "")
    end
    if ctx.taintStats and next(ctx.taintStats) then
      table.insert(lines, "--- Taint Hits ---")
      for k, v in pairs(ctx.taintStats) do
        table.insert(lines, "  " .. SafeToString(k) .. " = " .. SafeToString(v))
      end
      table.insert(lines, "")
    end
    if ctx.conditionErrors and next(ctx.conditionErrors) then
      table.insert(lines, "--- Condition Errors ---")
      for k, v in pairs(ctx.conditionErrors) do
        table.insert(lines, "  " .. SafeToString(k) .. " = " .. SafeToString(v) .. "x")
      end
      table.insert(lines, "")
    end
    if ctx.activeAuras and #ctx.activeAuras > 0 then
      table.insert(lines, "--- Active Buffs (" .. #ctx.activeAuras .. ") ---")
      table.insert(lines, "  " .. table.concat(ctx.activeAuras, ", "))
      table.insert(lines, "")
    end
    if ctx.targetDebuffs and #ctx.targetDebuffs > 0 then
      table.insert(lines, "--- Target Debuffs (" .. #ctx.targetDebuffs .. ") ---")
      table.insert(lines, "  " .. table.concat(ctx.targetDebuffs, ", "))
      table.insert(lines, "")
    end
    if ctx.targetGUIDInfo then
      table.insert(lines, "--- Target GUID ---")
      table.insert(lines, "  UnitGUID=" .. SafeToString(ctx.targetGUIDInfo.unitGUID) .. "  CLEU=" .. SafeToString(ctx.targetGUIDInfo.cleuGUID))
      table.insert(lines, "")
    end
    if ctx.slot1Diag then
      local s1 = ctx.slot1Diag
      table.insert(lines, "--- Slot 1 Render ---")
      table.insert(lines, "  Spell=" .. SafeToString(s1.spell) .. "  Signal=" .. SafeToString(s1.signal))
      table.insert(lines, "  TexType=" .. SafeToString(s1.texType) .. "  TexVal=" .. SafeToString(s1.texVal))
      table.insert(lines, "  IsCD=" .. SafeToString(s1.isCD) .. "  BaseAlpha=" .. SafeToString(s1.baseA) .. "  FadeAlpha=" .. SafeToString(s1.fadeA) .. "  FinalAlpha=" .. SafeToString(s1.finalA))
      table.insert(lines, "  FrameShown=" .. SafeToString(s1.shown) .. "  IconShown=" .. SafeToString(s1.iconShown))
      table.insert(lines, "")
    end
    if ctx.signalDiag and #ctx.signalDiag > 0 then
      table.sort(ctx.signalDiag, function(a, b) return SafeToString(a.spell) < SafeToString(b.spell) end)
      table.insert(lines, "--- Signal Diagnostics (" .. #ctx.signalDiag .. " spells) ---")
      local sigNames = { [0] = "none", [1] = "ANTS", [2] = "ASST", [3] = "PROC", [4] = "READY" }
      for _, d in ipairs(ctx.signalDiag) do
        local sigStr = sigNames[d.signal] or tostring(d.signal)
        local hlStr = SafeToString(d.hl)
        if d.hlS then hlStr = hlStr .. "(S)" end
        local olStr = SafeToString(d.ol)
        if d.olS then olStr = olStr .. "(S)" end
        local kidsStr = d.kids and (" kids=" .. SafeToString(d.kids)) or ""
        table.insert(lines, "  " .. SafeToString(d.spell) .. " id=" .. SafeToString(d.id) .. " slot=" .. SafeToString(d.slot) .. " sig=" .. sigStr .. " HL=" .. hlStr .. " OL=" .. olStr .. " glow=" .. SafeToString(d.glow) .. kidsStr)
      end
      table.insert(lines, "")
    end
    if ctx.recentIssues and #ctx.recentIssues > 0 then
      table.insert(lines, "--- Recent Issues ---")
      for _, issue in ipairs(ctx.recentIssues) do
        table.insert(lines, "  [" .. SafeToString(issue.cat) .. "] " .. SafeToString(issue.msg) .. " (x" .. SafeToString(issue.n) .. ")")
      end
      table.insert(lines, "")
    end
    if ctx.wdEvents and #ctx.wdEvents > 0 then
      table.insert(lines, "--- Recent Engine Events ---")
      for _, we in ipairs(ctx.wdEvents) do
        local dParts = {}
        if type(we.d) == "table" then
          for dk, dv in pairs(we.d) do
            table.insert(dParts, SafeToString(dk) .. "=" .. SafeToString(dv))
          end
        end
        table.insert(lines, "  " .. SafeToString(we.clock) .. " " .. SafeToString(we.t) .. ": " .. table.concat(dParts, " "))
      end
      table.insert(lines, "")
    end
    if ctx.clfMissing then
      table.insert(lines, "*** CLF NAMESPACE MISSING -- DMGAssist not loaded ***")
      table.insert(lines, "")
    end
  end
  table.insert(lines, "=== END EVENT ===")
  return table.concat(lines, "\n")
end

local function FormatSessionForCopy(session)
  local lines = {}
  table.insert(lines, "========================================")
  table.insert(lines, "  DMGA WATCHDOG - COMBAT SESSION EXPORT")
  table.insert(lines, "========================================")
  table.insert(lines, "Start: " .. SafeToString(session.startTime))
  if session.endTime then
    table.insert(lines, "End: " .. SafeToString(session.endTime))
    table.insert(lines, "Duration: " .. SafeToString(session.duration))
  else
    table.insert(lines, "Status: IN PROGRESS")
  end
  table.insert(lines, "Events: " .. #session.events)
  table.insert(lines, "Version: " .. WD_VERSION)
  table.insert(lines, "")
  for i, ev in ipairs(session.events) do
    table.insert(lines, FormatEventForCopy(ev))
    if i < #session.events then
      table.insert(lines, "")
    end
  end
  table.insert(lines, "")
  local healthResults = RunHealthChecks()
  local healthLines = FormatHealthReportPlain(healthResults)
  for _, hl in ipairs(healthLines) do
    table.insert(lines, hl)
  end
  table.insert(lines, "")
  table.insert(lines, "========================================")
  table.insert(lines, "  END SESSION EXPORT (" .. #session.events .. " events)")
  table.insert(lines, "========================================")
  return table.concat(lines, "\n")
end

local function GetSessionLabel(session, idx)
  local label = "#" .. idx .. " " .. SafeToString(session.startTime)
  if session.duration then
    label = label .. " (" .. session.duration .. ")"
  elseif not session.endTime then
    label = label .. " (active)"
  end
  label = label .. " [" .. #session.events .. "]"
  return label
end

local eventListScroll, eventButtons, detailBox, selectedEventIdx, selectedSessionIdx
local logTabBtn, eventsTabBtn, logScrollFrame, logEditBox, eventsContainer


local typeColorsShared = {
  CRASH = "|cFFFF4444", DEGRADED = "|cFFFF4444", ACTION_BLOCKED = "|cFFFF4444",
  HEARTBEAT_LOST = "|cFFFF4444", INIT_FAILURE = "|cFFFF4444",
  QUEUE_STUCK = "|cFFFFAA00", EMPTY_QUEUE = "|cFFFFAA00", TAINT_SPIKE = "|cFFFFAA00",
  ERROR_BURST = "|cFFFFAA00",
  INIT = "|cFF00CC00", COMBAT_START = "|cFF00CC00", COMBAT_END = "|cFF00CC00",
  SPEC_CHANGE = "|cFF00CC00",
  API_SCAN = "|cFF44AAFF",
  CAST = "|cFF88DDFF",
  QUEUE = "|cFFAADDFF",
  AC_REC = "|cFFFFDD44",
  MANUAL = "|cFFCCCCCC",
  PLAYER_DIED = "|cFFFF4444",
  PLAYER_ALIVE = "|cFF00CC00",
}

local function RefreshActivityLog()
  if not logEditBox then return end
  local lines = {}
  local events = DMGA_WD_Log
  local start = math.max(1, #events - 199)
  for i = start, #events do
    local ev = events[i]
    local tc = typeColorsShared[ev.type] or "|cFFCCCCCC"
    local line = "|cFF666666" .. SafeToString(ev.time) .. "|r " .. tc .. "[" .. SafeToString(ev.type) .. "]|r " .. SafeToString(ev.summary or "")
    table.insert(lines, line)
  end
  if #lines == 0 then
    logEditBox:SetText("|cFF888888No events yet. Watchdog is monitoring in the background.|r")
  else
    logEditBox:SetText(table.concat(lines, "\n"))
  end
  C_Timer.After(0.05, function()
    if logScrollFrame then
      logScrollFrame:SetVerticalScroll(logScrollFrame:GetVerticalScrollRange())
    end
  end)
end

local function ShowTab(tab)
  activeTab = "log"
  if logScrollFrame then logScrollFrame:Show() end
  if eventsContainer then eventsContainer:Hide() end
  RefreshActivityLog()
end

local function CreateViewerUI()
  if viewerFrame then return end
  viewerFrame = CreateFrame("Frame", "DMGAWatchdogViewer", UIParent, "BasicFrameTemplateWithInset")
  viewerFrame:SetSize(820, 520)
  viewerFrame:SetPoint("CENTER")
  viewerFrame:SetMovable(true)
  viewerFrame:EnableMouse(true)
  viewerFrame:RegisterForDrag("LeftButton")
  viewerFrame:SetScript("OnDragStart", viewerFrame.StartMoving)
  viewerFrame:SetScript("OnDragStop", viewerFrame.StopMovingOrSizing)
  viewerFrame:SetFrameStrata("DIALOG")
  viewerFrame.TitleText:SetText("DMGAssist Diagnostics")
  if viewerFrame.CloseButton then
    viewerFrame.CloseButton:SetScript("OnClick", function() viewerFrame:Hide() end)
  end
  table.insert(UISpecialFrames, "DMGAWatchdogViewer")

  local function MakeTabBtn(parent, x, label, w)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(w, 24)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -28)
    btn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    btn:SetBackdropColor(0.08, 0.08, 0.1, 0.9)
    btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.6)
    local txt = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    txt:SetPoint("CENTER")
    txt:SetText(label)
    btn._label = txt
    return btn
  end

  local contentTop = -30

  logScrollFrame = CreateFrame("ScrollFrame", "DMGAWDLogScroll", viewerFrame, "UIPanelScrollFrameTemplate")
  logScrollFrame:SetPoint("TOPLEFT", viewerFrame, "TOPLEFT", 10, contentTop)
  logScrollFrame:SetPoint("BOTTOMRIGHT", viewerFrame, "BOTTOMRIGHT", -30, 30)
  local logBg = logScrollFrame:CreateTexture(nil, "BACKGROUND")
  logBg:SetAllPoints()
  logBg:SetColorTexture(0, 0, 0, 0.3)
  logEditBox = CreateFrame("EditBox", "DMGAWDLogBox", logScrollFrame)
  logEditBox:SetMultiLine(true)
  logEditBox:SetAutoFocus(false)
  logEditBox:SetFontObject(GameFontHighlightSmall)
  logEditBox:SetWidth(760)
  logEditBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  logScrollFrame:SetScrollChild(logEditBox)

  local logCopyBtn = CreateFrame("Button", nil, viewerFrame, "UIPanelButtonTemplate")
  logCopyBtn:SetSize(100, 22)
  logCopyBtn:SetPoint("BOTTOMRIGHT", viewerFrame, "BOTTOMRIGHT", -8, 6)
  logCopyBtn:SetText("Select All")
  logCopyBtn:SetScript("OnClick", function()
    if activeTab == "log" then
      logEditBox:SetFocus()
      logEditBox:HighlightText()
    else
      detailBox:SetFocus()
      detailBox:HighlightText()
    end
  end)

  eventsContainer = CreateFrame("Frame", nil, viewerFrame)
  eventsContainer:SetPoint("TOPLEFT", viewerFrame, "TOPLEFT", 0, contentTop)
  eventsContainer:SetPoint("BOTTOMRIGHT", viewerFrame, "BOTTOMRIGHT", 0, 0)

  local listFrame = CreateFrame("Frame", nil, eventsContainer)
  listFrame:SetPoint("TOPLEFT", eventsContainer, "TOPLEFT", 8, 0)
  listFrame:SetSize(240, 430)
  local listBg = listFrame:CreateTexture(nil, "BACKGROUND")
  listBg:SetAllPoints()
  listBg:SetColorTexture(0, 0, 0, 0.3)

  eventListScroll = CreateFrame("ScrollFrame", "DMGAWDEventScroll", listFrame, "UIPanelScrollFrameTemplate")
  eventListScroll:SetPoint("TOPLEFT", 2, -2)
  eventListScroll:SetPoint("BOTTOMRIGHT", -22, 2)
  local scrollChild = CreateFrame("Frame")
  scrollChild:SetSize(210, 1)
  eventListScroll:SetScrollChild(scrollChild)

  eventButtons = {}
  for i = 1, 50 do
    local btn = CreateFrame("Button", nil, scrollChild)
    btn:SetSize(210, 22)
    btn:SetPoint("TOPLEFT", 0, -((i - 1) * 22))
    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.1)
    local sel = btn:CreateTexture(nil, "BACKGROUND")
    sel:SetAllPoints()
    sel:SetColorTexture(0.3, 0.3, 0.6, 0.4)
    sel:Hide()
    btn._sel = sel
    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", 4, 0)
    text:SetPoint("RIGHT", -4, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    btn._text = text
    btn._idx = i
    btn:SetScript("OnClick", function(self)
      selectedSessionIdx = self._dataIdx
      DMGAWDRefreshViewer()
    end)
    btn:Hide()
    eventButtons[i] = btn
  end

  local detailFrame = CreateFrame("Frame", nil, eventsContainer)
  detailFrame:SetPoint("TOPLEFT", listFrame, "TOPRIGHT", 4, 0)
  detailFrame:SetPoint("BOTTOMRIGHT", eventsContainer, "BOTTOMRIGHT", -8, 30)
  local detailBg = detailFrame:CreateTexture(nil, "BACKGROUND")
  detailBg:SetAllPoints()
  detailBg:SetColorTexture(0, 0, 0, 0.3)

  local detailScroll = CreateFrame("ScrollFrame", "DMGAWDDetailScroll", detailFrame, "UIPanelScrollFrameTemplate")
  detailScroll:SetPoint("TOPLEFT", 4, -4)
  detailScroll:SetPoint("BOTTOMRIGHT", -22, 4)
  detailBox = CreateFrame("EditBox", "DMGAWDDetailBox", detailScroll)
  detailBox:SetMultiLine(true)
  detailBox:SetAutoFocus(false)
  detailBox:SetFontObject(GameFontHighlightSmall)
  detailBox:SetWidth(540)
  detailBox:SetHeight(10000)
  detailBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  detailBox:SetScript("OnTextChanged", function(self)
    local _, h = self:GetFont()
    if h then
      local numLines = select(2, self:GetText():gsub("\n", "\n")) + 1
      local newH = math.max(200, numLines * (h + 2))
      self:SetHeight(newH)
    end
  end)
  detailScroll:SetScrollChild(detailBox)
  detailBox:SetText("Select a combat session from the left to view all events.\n\nCtrl+A then Ctrl+C to copy the full session export.")

  local snapBtn = CreateFrame("Button", nil, viewerFrame, "UIPanelButtonTemplate")
  snapBtn:SetSize(130, 22)
  snapBtn:SetPoint("BOTTOMRIGHT", logCopyBtn, "BOTTOMLEFT", -4, 0)
  snapBtn:SetText("Capture Snapshot")
  snapBtn:SetScript("OnClick", function()
    PushEvent("MANUAL", "Manual snapshot captured")
    DMGAWDRefreshViewer()
  end)

  local clearBtn = CreateFrame("Button", nil, viewerFrame, "UIPanelButtonTemplate")
  clearBtn:SetSize(80, 22)
  clearBtn:SetPoint("BOTTOMLEFT", viewerFrame, "BOTTOMLEFT", 8, 6)
  clearBtn:SetText("Clear All")
  clearBtn:SetScript("OnClick", function()
    wipe(DMGA_WD_Log)
    wipe(sessionEvents)
    wipe(combatSessions)
    currentSessionIdx = nil
    selectedEventIdx = nil
    selectedSessionIdx = nil
    lastSeenEventCount = 0
    unseenCount = 0
    DMGAWDRefreshViewer()
  end)

  viewerFrame:Hide()
end

function DMGAWDRefreshViewer()
  if not viewerFrame or not viewerFrame:IsShown() then return end

  lastSeenEventCount = #DMGA_WD_Log
  unseenCount = 0

  if activeTab == "log" then
    RefreshActivityLog()
    return
  end

  local sessions = combatSessions
  local scrollChild = eventListScroll:GetScrollChild()
  scrollChild:SetHeight(math.max(1, #sessions * 22))

  for i = 1, 50 do
    local btn = eventButtons[i]
    local sIdx = #sessions - i + 1
    if sIdx >= 1 then
      local s = sessions[sIdx]
      local label = GetSessionLabel(s, sIdx)
      local hasAlert = false
      for _, ev in ipairs(s.events) do
        if ev.type == "CRASH" or ev.type == "DEGRADED" or ev.type == "ACTION_BLOCKED" or ev.type == "HEARTBEAT_LOST" then
          hasAlert = true
          break
        end
      end
      if hasAlert then
        label = "|cFFFF4444" .. label .. "|r"
      elseif not s.endTime then
        label = "|cFF00CC00" .. label .. "|r"
      end
      btn._text:SetText(label)
      btn._dataIdx = sIdx
      btn._sel:SetShown(selectedSessionIdx == sIdx)
      btn:Show()
    else
      btn:Hide()
    end
  end

  if selectedSessionIdx and combatSessions[selectedSessionIdx] then
    local s = combatSessions[selectedSessionIdx]
    local ok, text = pcall(FormatSessionForCopy, s)
    if ok then
      detailBox:SetText(text)
    else
      detailBox:SetText("Error formatting session: " .. SafeToString(text))
    end
    detailBox:SetCursorPosition(0)
  elseif #combatSessions == 0 then
    detailBox:SetText("No combat sessions yet.\n\nEnter combat and events will be grouped here automatically.\nSelect a session from the left to view all events.\nCtrl+A then Ctrl+C to copy the full session.")
  end
end

local function ToggleViewer()
  CreateViewerUI()
  if viewerFrame:IsShown() then
    viewerFrame:Hide()
  else
    lastSeenEventCount = #DMGA_WD_Log
    unseenCount = 0
    viewerFrame:Show()
    ShowTab("log")
  end
end

local optionsFrame
local function CreateOptionsPanel()
  if optionsFrame then return end
  optionsFrame = CreateFrame("Frame", "DMGAWatchdogOptions", UIParent, "BasicFrameTemplateWithInset")
  optionsFrame:SetSize(320, 380)
  optionsFrame:SetPoint("CENTER")
  optionsFrame:SetMovable(true)
  optionsFrame:EnableMouse(true)
  optionsFrame:RegisterForDrag("LeftButton")
  optionsFrame:SetScript("OnDragStart", optionsFrame.StartMoving)
  optionsFrame:SetScript("OnDragStop", optionsFrame.StopMovingOrSizing)
  optionsFrame:SetFrameStrata("DIALOG")
  optionsFrame.TitleText:SetText("Diagnostics Options")
  if optionsFrame.CloseButton then
    optionsFrame.CloseButton:SetScript("OnClick", function() optionsFrame:Hide() end)
  end
  table.insert(UISpecialFrames, "DMGAWatchdogOptions")

  local checkboxes = {
    { key = "monitorHeartbeat", label = "Monitor Heartbeat Loss" },
    { key = "monitorStuckQueue", label = "Monitor Stuck Queue" },
    { key = "monitorTaint", label = "Monitor Taint Spikes" },
    { key = "monitorCombat", label = "Monitor Combat Transitions" },
    { key = "monitorErrors", label = "Monitor Error Bursts" },
    { key = "monitorActionBlocked", label = "Monitor ADDON_ACTION_BLOCKED" },
    { key = "monitorEmptyQueue", label = "Monitor Empty Queue in Combat" },
    { key = "chatAlerts", label = "Also Print to Chat (verbose)" },
    { key = "autoSnapshot", label = "Auto-capture State on Events" },
    { key = "minimapIcon", label = "Show Minimap Icon" },
  }

  for i, info in ipairs(checkboxes) do
    local cb = CreateFrame("CheckButton", "DMGAWDOpt_" .. info.key, optionsFrame, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", 20, -28 - (i - 1) * 28)
    cb.text = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cb.text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    cb.text:SetText(info.label)
    cb:SetChecked(DMGA_WD_Config[info.key])
    cb:SetScript("OnClick", function(self)
      DMGA_WD_Config[info.key] = self:GetChecked()
      if info.key == "minimapIcon" and DMGAWDMinimapBtn then
        if self:GetChecked() then DMGAWDMinimapBtn:Show() else DMGAWDMinimapBtn:Hide() end
      end
    end)
  end

  local scanBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
  scanBtn:SetSize(180, 26)
  scanBtn:SetPoint("BOTTOM", optionsFrame, "BOTTOM", 0, 40)
  scanBtn:SetText("Run API Scan")
  scanBtn:SetScript("OnClick", function()
    RunAPIScan()
    optionsFrame:Hide()
  end)

  optionsFrame:Hide()
end

local function ToggleOptions()
  CreateOptionsPanel()
  if optionsFrame:IsShown() then optionsFrame:Hide() else optionsFrame:Show() end
end

local function CreateMinimapButton()
  local btn = CreateFrame("Button", "DMGAWDMinimapBtn", Minimap)
  btn:SetSize(32, 32)
  btn:SetFrameStrata("MEDIUM")
  btn:SetFrameLevel(8)
  btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local overlay = btn:CreateTexture(nil, "OVERLAY")
  overlay:SetSize(53, 53)
  overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  overlay:SetPoint("TOPLEFT")
  local icon = btn:CreateTexture(nil, "BACKGROUND")
  icon:SetSize(20, 20)
  icon:SetTexture("Interface\\Icons\\INV_Pet_BabyBlizzardBear")
  icon:SetPoint("CENTER", 0, 1)
  local angle = math.rad(200)
  local mw, mh = Minimap:GetSize()
  local radius = (mw or 140) / 2 + 5
  btn:SetPoint("CENTER", Minimap, "CENTER", radius * math.cos(angle), radius * math.sin(angle))
  local isDragging = false
  btn:RegisterForDrag("LeftButton")
  btn:SetScript("OnDragStart", function(self)
    isDragging = true
    self:SetScript("OnUpdate", function(self)
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local s = UIParent:GetEffectiveScale()
      cx, cy = cx / s, cy / s
      local dx, dy = cx - mx, cy - my
      local dist = math.sqrt(dx * dx + dy * dy)
      if dist < 10 then dist = 10 end
      self:ClearAllPoints()
      local mmw = Minimap:GetSize() or 140
      local r = mmw / 2 + 5
      self:SetPoint("CENTER", Minimap, "CENTER", (dx / dist) * r, (dy / dist) * r)
    end)
  end)
  btn:SetScript("OnDragStop", function(self)
    isDragging = false
    self:SetScript("OnUpdate", nil)
  end)
  btn:SetScript("OnClick", function(self, button)
    if button == "LeftButton" then
      ToggleViewer()
    elseif button == "RightButton" then
      ToggleOptions()
    end
  end)
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("DMGAssist Diagnostics", 0.53, 0.4, 0.8)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cFFFFFFFFLeft-click:|r Activity Log")
    GameTooltip:AddLine("|cFFFFFFFFRight-click:|r Options")
    local alerts = 0
    for _, ev in ipairs(sessionEvents) do
      if ev.type == "CRASH" or ev.type == "DEGRADED" or ev.type == "ACTION_BLOCKED" or ev.type == "HEARTBEAT_LOST" then
        alerts = alerts + 1
      end
    end
    if alerts > 0 then
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine("|cFFFF4444" .. alerts .. " alert(s) this session|r")
    end
    if unseenCount > 0 then
      GameTooltip:AddLine("|cFFFFD100" .. unseenCount .. " new event(s)|r")
    end
    GameTooltip:AddLine("|cFF888888" .. #sessionEvents .. " events captured|r")
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  if not DMGA_WD_Config.minimapIcon then btn:Hide() end
end

function RunAPIScan()
  local results = {}
  local function Test(name, func)
    local entry = { api = name, status = "ok", value = nil, tainted = false, err = nil }
    local ok, val = pcall(func)
    if not ok then
      entry.status = "error"
      entry.err = SafeToString(val)
    elseif val == nil then
      entry.status = "nil"
    elseif issecretvalue and issecretvalue(val) then
      entry.status = "tainted"
      entry.tainted = true
    else
      entry.status = "ok"
      entry.value = SafeToString(val)
    end
    table.insert(results, entry)
    return entry
  end

  print("|cFF8866CC[DMGA]|r |cFF44AAFF=== API Scan Starting ===|r")

  Test("UnitClass", function() return select(2, UnitClass("player")) end)
  Test("UnitLevel", function() return UnitLevel("player") end)
  Test("UnitRace", function() return select(2, UnitRace("player")) end)
  Test("UnitHealth", function() return UnitHealth("player") end)
  Test("UnitHealthMax", function() return UnitHealthMax("player") end)
  Test("UnitPower", function() return UnitPower("player") end)
  Test("UnitPowerMax", function() return UnitPowerMax("player") end)
  Test("UnitPowerType", function() return UnitPowerType("player") end)
  Test("GetSpecialization", function() return GetSpecialization() end)
  Test("GetSpecializationInfo", function() return GetSpecializationInfo(GetSpecialization() or 1) end)
  Test("InCombatLockdown", function() return InCombatLockdown() end)
  Test("GetShapeshiftForm", function() if GetShapeshiftForm then return GetShapeshiftForm() end return nil end)
  Test("GetNumShapeshiftForms", function() if GetNumShapeshiftForms then return GetNumShapeshiftForms() end return nil end)
  Test("GetInstanceInfo", function() return GetInstanceInfo() end)
  Test("IsInInstance", function() return IsInInstance() end)
  Test("GetTime", function() return GetTime() end)
  Test("issecretvalue_exists", function() return issecretvalue and "yes" or "no" end)
  Test("C_Spell.GetSpellName(61304)", function() return C_Spell and C_Spell.GetSpellName(61304) end)
  Test("C_Spell.GetSpellCooldown(61304)", function()
    if C_Spell and C_Spell.GetSpellCooldown then
      local cd = C_Spell.GetSpellCooldown(61304)
      return cd and (cd.startTime .. "/" .. cd.duration) or "nil"
    end
    return nil
  end)
  Test("C_Spell.GetSpellInfo(61304)", function()
    if C_Spell and C_Spell.GetSpellInfo then
      local info = C_Spell.GetSpellInfo(61304)
      return info and info.name or "nil"
    end
    return nil
  end)
  Test("C_SpellBook.HasSpellBookItem", function()
    return C_SpellBook and C_SpellBook.HasSpellBookItem and "exists" or "missing"
  end)
  Test("C_UnitAuras.GetBuffDataByIndex", function()
    if C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
      local aura = C_UnitAuras.GetBuffDataByIndex("player", 1)
      return aura and SafeToString(aura.name) or "no_buffs"
    end
    return nil
  end)
  Test("C_Item.GetItemInfo_trinket13", function()
    if C_Item and C_Item.GetItemInfo then
      local link = GetInventoryItemLink("player", 13)
      return link and SafeToString(link) or "no_trinket"
    end
    return nil
  end)
  Test("C_Item.GetItemInfo_trinket14", function()
    if C_Item and C_Item.GetItemInfo then
      local link = GetInventoryItemLink("player", 14)
      return link and SafeToString(link) or "no_trinket"
    end
    return nil
  end)
  Test("GetInventoryItemCooldown_13", function()
    if GetInventoryItemCooldown then
      local ok, start, dur = pcall(GetInventoryItemCooldown, "player", 13)
      if ok then
        local s = start
        local d = dur
        if issecretvalue and issecretvalue(s) then s = "secret" else s = tostring(s or 0) end
        if issecretvalue and issecretvalue(d) then d = "secret" else d = tostring(d or 0) end
        return s .. "/" .. d
      end
      return "pcall_failed"
    end
    return nil
  end)
  Test("UnitExists_target", function() return UnitExists("target") end)
  Test("UnitCanAttack_target", function() return UnitCanAttack("player", "target") end)
  Test("GetNumGroupMembers", function() return GetNumGroupMembers() end)
  Test("IsInGroup", function() return IsInGroup() end)
  Test("C_NamePlate.GetNamePlates", function()
    if C_NamePlate and C_NamePlate.GetNamePlates then
      local plates = C_NamePlate.GetNamePlates()
      return plates and #plates or 0
    end
    return nil
  end)
  Test("GetActionBarToggles", function()
    if HasAction then return HasAction(1) and "has_slot1" or "empty_slot1" end
    return nil
  end)
  Test("IsSpellOverlayed_exists", function()
    return C_Spell and C_Spell.GetSpellActualLore and "C_Spell" or (IsSpellOverlayed and "legacy" or "missing")
  end)
  Test("GetCVar_SpellActivationOverlay", function()
    if GetCVar then return GetCVar("SpellActivationOverlayOpacity") end
    return nil
  end)

  local clf = _G.CLF
  if clf then
    Test("CLF.ActiveEnemies", function() return clf.ActiveEnemies and clf.ActiveEnemies() or "missing" end)
    Test("CLF.PlayerHealthPct", function() return clf.PlayerHealthPct and string.format("%.2f", clf.PlayerHealthPct()) or "missing" end)
    Test("CLF.GetGCD", function() return clf.GetGCD and clf.GetGCD() or "missing" end)
    Test("CLF.CurrentForm", function() return clf.CurrentForm and clf.CurrentForm() or "missing" end)
    Test("CLF.GetSpecPowerType", function() return clf.GetSpecPowerType and clf.GetSpecPowerType() or "missing" end)
    Test("CLF._filteredAPL_count", function()
      return clf._filteredAPL and #clf._filteredAPL or 0
    end)
    Test("CLF._runtimeErrorCount", function() return clf._runtimeErrorCount or 0 end)
    Test("CLF._runtimeDegraded", function() return clf._runtimeDegraded or false end)

    local config = CLF_Config or CLF_DefaultConfig
    if config and config.apl then
      local tested = 0
      for _, entry in ipairs(config.apl) do
        if tested >= 20 then break end
        local spellName = entry.spellName or entry.spell
        if spellName then
          tested = tested + 1
          Test("SpellKnown:" .. spellName, function()
            if clf.IsSpellKnown then return clf.IsSpellKnown(spellName) end
            if C_Spell and C_Spell.GetSpellInfo then
              local info = C_Spell.GetSpellInfo(spellName)
              return info and "found" or "not_found"
            end
            return "?"
          end)
          Test("SpellCD:" .. spellName, function()
            if C_Spell and C_Spell.GetSpellCooldown then
              local cd = C_Spell.GetSpellCooldown(spellName)
              if cd then return "start=" .. (cd.startTime or 0) .. " dur=" .. (cd.duration or 0) end
              return "no_cd_data"
            end
            return "no_api"
          end)
        end
      end
    end
  else
    Test("CLF_namespace", function() return "MISSING" end)
  end

  local formApis = { "GetShapeshiftForm", "GetNumShapeshiftForms" }
  for _, apiName in ipairs(formApis) do
    if _G[apiName] then
      Test("FormTaint:" .. apiName, function()
        local val = _G[apiName]()
        if issecretvalue and issecretvalue(val) then return "TAINTED" end
        return SafeToString(val)
      end)
    end
  end

  Test("C_AssistedCombat_EXISTS", function()
    if C_AssistedCombat then return "YES" end
    return "NO"
  end)

  Test("C_SpellActivationOverlay_EXISTS", function()
    if C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed then return "YES" end
    return "NO"
  end)

  if C_AssistedCombat then
    Test("C_AssistedCombat.IsAvailable", function()
      if not C_AssistedCombat.IsAvailable then return "METHOD_MISSING" end
      local avail, reason = C_AssistedCombat.IsAvailable()
      if avail then return "AVAILABLE" end
      return "UNAVAILABLE:" .. SafeToString(reason or "no_reason")
    end)
  end

  local acSummary = "UNKNOWN"
  if not C_AssistedCombat then
    acSummary = "NO_NAMESPACE"
  elseif not C_AssistedCombat.IsAvailable then
    acSummary = "NO_ISAVAILABLE"
  else
    local acOk, acAvail = pcall(C_AssistedCombat.IsAvailable)
    if not acOk then
      acSummary = "PCALL_FAIL"
    elseif acAvail then
      acSummary = "HOOKED"
    else
      acSummary = "DISABLED"
    end
  end

  DMGA_WD_APIScan = {
    time = date("%Y-%m-%d %H:%M:%S"),
    class = SafeRead(function() return select(2, UnitClass("player")) end, "?"),
    spec = SafeRead(function()
      local cfg = CLF_Config or CLF_DefaultConfig
      if cfg and cfg.spec then return cfg.spec.specName end
      return "?"
    end, "?"),
    level = SafeRead(function() return UnitLevel("player") end, 0),
    contentType = GetContentType(),
    assistedCombat = acSummary,
    results = results,
  }

  local okCount, errCount, taintCount, nilCount = 0, 0, 0, 0
  for _, r in ipairs(results) do
    if r.status == "ok" then okCount = okCount + 1
    elseif r.status == "error" then errCount = errCount + 1
    elseif r.status == "tainted" then taintCount = taintCount + 1
    elseif r.status == "nil" then nilCount = nilCount + 1 end
  end

  PushEvent("API_SCAN", okCount .. " ok, " .. errCount .. " errors, " .. taintCount .. " tainted, " .. nilCount .. " nil", {
    total = #results,
    ok = okCount,
    errors = errCount,
    tainted = taintCount,
    nilReturns = nilCount,
    scanResults = results,
  })

  print("|cFF8866CC[DMGA]|r |cFF44AAFF=== Scan Complete: " .. #results .. " APIs tested ===|r")
  print("|cFF8866CC[DMGA]|r   |cFF00CC00OK:|r " .. okCount .. "  |cFFFF4444Errors:|r " .. errCount .. "  |cFFFFAA00Tainted:|r " .. taintCount .. "  |cFF888888Nil:|r " .. nilCount)
  if errCount > 0 or taintCount > 0 then
    for _, r in ipairs(results) do
      if r.status == "error" then
        print("|cFF8866CC[DMGA]|r   |cFFFF4444ERR|r " .. r.api .. ": " .. (r.err or "?"))
      elseif r.status == "tainted" then
        print("|cFF8866CC[DMGA]|r   |cFFFFAA00TAINT|r " .. r.api)
      end
    end
  end
  print("|cFF8866CC[DMGA]|r Open Event Viewer to copy full results.")
end

local function PollCheck()
  local now = GetTime()
  local clf = SafeRead(function() return _G.CLF end, nil)

  if not clf then
    if addonLoaded and ThrottleCheck("clf_missing", 30) then
      PushEvent("CRASH", "CLF namespace missing -- DMGAssist may have crashed")
    end
    return
  end

  if DMGA_WD_Config.monitorErrors then
    local curErrors = SafeReadField(clf, "_runtimeErrorCount", 0)
    if curErrors > lastErrorCount then
      local burst = curErrors - lastErrorCount
      if burst >= 3 and ThrottleCheck("error_burst", 10) then
        PushEvent("ERROR_BURST", burst .. " new errors (total: " .. curErrors .. ")", {
          burst = burst,
          total = curErrors,
        })
      end
      lastErrorCount = curErrors
    end
  end

  if DMGA_WD_Config.monitorErrors then
    local degraded = SafeReadField(clf, "_runtimeDegraded", false)
    if degraded and ThrottleCheck("degraded", 30) then
      PushEvent("DEGRADED", "DMGAssist entered degraded mode (" .. SafeToString(SafeReadField(clf, "_runtimeErrorCount", 0)) .. " errors)")
    end
  end

  if DMGA_WD_Config.monitorHeartbeat then
    local hb = SafeReadField(clf, "_heartbeat", 0)
    if hb ~= lastHeartbeatVal then
      lastHeartbeatVal = hb
      lastHeartbeat = now
    elseif lastHeartbeat > 0 and (now - lastHeartbeat) > HEARTBEAT_TIMEOUT then
      if ThrottleCheck("heartbeat", 30) then
        PushEvent("HEARTBEAT_LOST", "No tick updates for " .. string.format("%.0f", now - lastHeartbeat) .. "s")
      end
    end
  end

  if DMGA_WD_Config.monitorStuckQueue then
    local stuckInCombat = SafeRead(function()
      local v = InCombatLockdown()
      if issecretvalue and issecretvalue(v) then return true end
      return v and true or false
    end, false)
    if stuckInCombat then
      local queue = SafeReadField(clf, "lastQueue", nil)
      if queue and type(queue) == "table" then
        local qStr = ""
        SafeRead(function()
          for _, q in ipairs(queue) do
            qStr = qStr .. SafeToString(q.spellName or "?") .. ","
          end
        end, nil)
        if qStr ~= lastQueueStr then
          lastQueueStr = qStr
          stuckSince = now
        elseif qStr ~= "" and (now - stuckSince) > STUCK_THRESHOLD then
          if ThrottleCheck("stuck", 10) then
            local topSpell = SafeRead(function() return queue[1] and queue[1].spellName or "?" end, "?")
            PushEvent("QUEUE_STUCK", "Unchanged " .. string.format("%.0f", now - stuckSince) .. "s -- top: " .. SafeToString(topSpell))
          end
        end
      end
    else
      stuckSince = now
      lastQueueStr = ""
    end
  end

  if DMGA_WD_Config.monitorEmptyQueue then
    local inCombat = SafeRead(function()
      local v = InCombatLockdown()
      if issecretvalue and issecretvalue(v) then return true end
      return v and true or false
    end, false)
    if inCombat then
      local queue = SafeReadField(clf, "lastQueue", nil)
      local isEmpty = not queue or (type(queue) == "table" and #queue == 0)
      if isEmpty then
        if not emptyQueueReported and (now - lastEmptyQueueTime) > EMPTY_QUEUE_COMBAT_THRESHOLD then
          if lastEmptyQueueTime > 0 and ThrottleCheck("empty_queue", 15) then
            PushEvent("EMPTY_QUEUE", "No spells in queue during combat for " .. string.format("%.0f", now - lastEmptyQueueTime) .. "s")
            emptyQueueReported = true
          end
          if lastEmptyQueueTime == 0 then lastEmptyQueueTime = now end
        end
      else
        lastEmptyQueueTime = 0
        emptyQueueReported = false
      end
    else
      lastEmptyQueueTime = 0
      emptyQueueReported = false
    end
  end

  local combatActive = SafeRead(function()
    local v = InCombatLockdown()
    if issecretvalue and issecretvalue(v) then return true end
    return v and true or false
  end, false)

  if combatActive then
    local curGCD = SafeReadField(clf, "_prevGCD", nil)
    if curGCD and curGCD ~= lastTrackedGCD then
      lastTrackedGCD = curGCD
      local castReason = ""
      SafeRead(function()
        local q = clf.lastQueue
        if q and type(q) == "table" and q[1] then
          local r = q[1].reason
          if r then castReason = " (" .. SafeToString(r) .. ")" end
        end
      end, nil)
      PushEvent("CAST", SafeToString(curGCD) .. castReason)
    end

    local curSlot1 = SafeRead(function()
      local q = clf.lastQueue
      if q and type(q) == "table" and q[1] then
        return q[1].spellName
      end
      return nil
    end, nil)
    if curSlot1 and curSlot1 ~= lastTrackedSlot1 then
      local slot2 = SafeRead(function()
        local q = clf.lastQueue
        if q and type(q) == "table" and q[2] then
          return SafeToString(q[2].spellName)
        end
        return ""
      end, "")
      local slot1Reason = SafeRead(function()
        local q = clf.lastQueue
        if q and type(q) == "table" and q[1] then
          return SafeToString(q[1].reason or "")
        end
        return ""
      end, "")
      local acId = SafeReadField(clf, "_acNextCastId", nil)
      local acLabel = ""
      if acId then
        local acName = SafeRead(function()
          if C_Spell and C_Spell.GetSpellName then
            local aOk, aName = pcall(C_Spell.GetSpellName, acId)
            if aOk and aName and not (issecretvalue and issecretvalue(aName)) then
              return aName
            end
          end
          return tostring(acId)
        end, tostring(acId))
        acLabel = " | AC=" .. SafeToString(acName)
      end
      PushEvent("QUEUE", SafeToString(curSlot1) .. " > " .. slot2 .. " [" .. slot1Reason .. "]" .. acLabel)
      lastTrackedSlot1 = curSlot1
    end

    local curAcId = SafeReadField(clf, "_acNextCastId", nil)
    if curAcId and curAcId ~= lastTrackedAcRec then
      local acSpellName = SafeRead(function()
        if C_Spell and C_Spell.GetSpellName then
          local aOk, aName = pcall(C_Spell.GetSpellName, curAcId)
          if aOk and aName and not (issecretvalue and issecretvalue(aName)) then
            return aName
          end
        end
        return nil
      end, nil)
      if acSpellName and acSpellName ~= lastTrackedAcRecName then
        PushEvent("AC_REC", SafeToString(acSpellName) .. " (id=" .. SafeToString(curAcId) .. ")")
        lastTrackedAcRecName = acSpellName
      end
      lastTrackedAcRec = curAcId
    end
  else
    if lastTrackedGCD then
      lastTrackedGCD = nil
      lastTrackedSlot1 = nil
      lastTrackedAcRec = nil
      lastTrackedAcRecName = nil
    end
  end

  if DMGA_WD_Config.monitorTaint then
    local ts = SafeReadField(clf, "_taintStats", nil)
    if ts and type(ts) == "table" then
      SafeRead(function()
        for k, v in pairs(ts) do
          if type(v) == "number" and v > 100 then
            if ThrottleCheck("taint_" .. k, 60) then
              PushEvent("TAINT_SPIKE", "High taint: " .. SafeToString(k) .. " = " .. v, { api = SafeToString(k), hits = v })
            end
          end
        end
      end, nil)
    end
  end
end

local elapsed_acc = 0
wdFrame:SetScript("OnUpdate", function(self, elapsed)
  if not DMGA_WD_Config.enabled then return end
  elapsed_acc = elapsed_acc + elapsed
  if elapsed_acc < POLL_INTERVAL then return end
  elapsed_acc = 0
  local ok, err = pcall(PollCheck)
  if not ok then
    if ThrottleCheck("poll_error", 30) then
      local safeErr = SafeToString(err)
      table.insert(DMGA_WD_Log, {
        id = #DMGA_WD_Log + 1,
        type = "WD_ERROR",
        summary = "Watchdog poll error: " .. safeErr,
        time = date("%H:%M:%S"),
        gameTime = string.format("%.1f", GetTime() % 1000),
        extra = { error = safeErr },
      })
      if #DMGA_WD_Log > MAX_EVENTS then table.remove(DMGA_WD_Log, 1) end
    end
  end
end)

wdFrame:RegisterEvent("ADDON_LOADED")
wdFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
wdFrame:RegisterEvent("ADDON_ACTION_BLOCKED")
wdFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
wdFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
wdFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
wdFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
wdFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
wdFrame:RegisterEvent("PLAYER_DEAD")
wdFrame:RegisterEvent("PLAYER_ALIVE")
wdFrame:RegisterEvent("PLAYER_UNGHOST")

wdFrame:SetScript("OnEvent", function(self, event, arg1, arg2)
  local ok, err = pcall(function()
    if event == "ADDON_LOADED" then
      if arg1 == "DMGAssist" then
        addonLoaded = true
        C_Timer.After(1, function() pcall(RegisterCLFSubsystems) end)
        if DMGA_WD_Config.enabled then
          PushEvent("INIT", "DMGAssist addon loaded (diagnostics enabled) build=1789702429108")
          C_Timer.After(0.5, function()
            if DMGA_WD_Config.minimapIcon then pcall(CreateMinimapButton) end
          end)
        end
      end

    elseif event == "PLAYER_ENTERING_WORLD" then
      if not DMGA_WD_Config.enabled then return end
      local isInitialLogin = arg1
      local isReloadingUi = arg2
      if isReloadingUi then
        wipe(sessionEvents)
        wipe(DMGA_WD_Log)
        wipe(combatSessions)
        currentSessionIdx = nil
        PushEvent("INIT", "UI reload detected -- diagnostics log cleared -- build=1789702429108")
      end
      C_Timer.After(3, function()
        pcall(function()
          local acStatus = "UNKNOWN"
          if not C_AssistedCombat then
            acStatus = "NO_NAMESPACE"
          elseif not C_AssistedCombat.IsAvailable then
            acStatus = "NO_METHOD"
          else
            local acOk, acAvail = pcall(C_AssistedCombat.IsAvailable)
            if not acOk then
              acStatus = "PCALL_FAIL"
            elseif acAvail then
              acStatus = "HOOKED"
            else
              acStatus = "DISABLED"
            end
          end
          local rotCount = 0
          if acStatus == "HOOKED" and C_AssistedCombat.GetRotationSpells then
            local rotOk, rotSpells = pcall(C_AssistedCombat.GetRotationSpells)
            if rotOk and rotSpells and not (issecretvalue and issecretvalue(rotSpells)) then
              rotCount = #rotSpells
            end
          end
          PushEvent("AC_STATUS", acStatus .. " | RotationSpells=" .. tostring(rotCount), {
            status = acStatus,
            rotationSpells = rotCount,
          })
        end)
      end)

      C_Timer.After(5, function()
        pcall(function()
          local clf = SafeRead(function() return _G.CLF end, nil)
          if not clf then
            PushEvent("INIT_FAILURE", "CLF namespace not found 5s after login")
          else
            local cfg = SafeRead(function() return CLF_Config or CLF_DefaultConfig end, nil)
            local aplBranch = SafeRead(function() return cfg and cfg.spec and cfg.spec.aplBranch or "?" end, "?")
            local aplTier = SafeRead(function() return cfg and cfg.spec and cfg.spec.aplTier or "?" end, "?")
            PushEvent("INIT", "Watchdog monitoring active -- " .. SafeRead(function()
              if cfg and cfg.spec then return cfg.spec.specName .. " " .. cfg.spec.className end
              return "no spec"
            end, "?") .. " (apl=" .. aplBranch .. ", tier=" .. aplTier .. ")", {
              heartbeat = SafeReadField(clf, "_heartbeat", 0),
              aplCount = SafeRead(function()
                if not clf._filteredAPL then return 0 end
                local f = clf._filteredAPL
                return (f.rotation and #f.rotation or 0) + (f.interrupts and #f.interrupts or 0) + (f.precombatState and #f.precombatState or 0) + (f.precombatOpener and #f.precombatOpener or 0)
              end, 0),
            })
            lastHeartbeat = GetTime()
            lastHeartbeatVal = SafeReadField(clf, "_heartbeat", 0)
          end
        end)
      end)

    elseif event == "ADDON_ACTION_BLOCKED" then
      if DMGA_WD_Config.enabled and DMGA_WD_Config.monitorActionBlocked then
        local addonName = SafeToString(arg1 or "unknown")
        local blockedFn = SafeToString(arg2 or "unknown")
        PushEvent("ACTION_BLOCKED", "Addon: " .. addonName .. " Function: " .. blockedFn, { addon = addonName, blockedFunction = blockedFn })
      end

    elseif event == "PLAYER_REGEN_DISABLED" then
      if DMGA_WD_Config.enabled and DMGA_WD_Config.monitorCombat then
        PushEvent("COMBAT_START", "Entered combat")
      end

    elseif event == "PLAYER_REGEN_ENABLED" then
      if DMGA_WD_Config.enabled and DMGA_WD_Config.monitorCombat then
        local taintInfo = SafeRead(function()
          local clf = _G.CLF
          if clf and clf.GetCombatTaintSummary then
            return clf.GetCombatTaintSummary()
          end
          return "no_clf"
        end, "error")
        PushEvent("COMBAT_END", "Left combat | taint: " .. SafeToString(taintInfo), {
          taint = SafeToString(taintInfo),
        })
      end

    elseif event == "PLAYER_TALENT_UPDATE" or event == "ACTIVE_TALENT_GROUP_CHANGED" or event == "TRAIT_CONFIG_UPDATED" then
      if not DMGA_WD_Config.enabled then return end
      local specName = SafeRead(function()
        local cfg = CLF_Config or CLF_DefaultConfig
        if cfg and cfg.spec then return cfg.spec.specName .. " " .. cfg.spec.className end
        return "?"
      end, "?")
      PushEvent("SPEC_CHANGE", "Talents/spec changed -- now: " .. specName)

    elseif event == "PLAYER_DEAD" then
      if not DMGA_WD_Config.enabled then return end
      PushEvent("PLAYER_DIED", "Player died")

    elseif event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
      if not DMGA_WD_Config.enabled then return end
      PushEvent("PLAYER_ALIVE", "Player alive/resurrected")
    end
  end)

  if not ok then
    local safeErr = SafeToString(err)
    table.insert(DMGA_WD_Log, {
      id = #DMGA_WD_Log + 1,
      type = "WD_ERROR",
      summary = "Event handler error (" .. SafeToString(event) .. "): " .. safeErr,
      time = date("%H:%M:%S"),
      gameTime = string.format("%.1f", GetTime() % 1000),
      extra = { event = SafeToString(event), error = safeErr },
    })
    if #DMGA_WD_Log > MAX_EVENTS then table.remove(DMGA_WD_Log, 1) end
  end
end)

function DMGA_WD_Enable()
  DMGA_WD_Config.enabled = true
  PushEvent("INIT", "Diagnostic logging enabled")
  if DMGA_WD_Config.minimapIcon and not DMGAWDMinimapBtn then
    pcall(CreateMinimapButton)
  elseif DMGA_WD_Config.minimapIcon and DMGAWDMinimapBtn then
    DMGAWDMinimapBtn:Show()
  end
  print("|cFF8866CC[DMGA]|r Diagnostic logging |cFF00CC00enabled|r. Use |cFFFFD100/dmgawd|r to open the viewer.")
end

function DMGA_WD_Disable()
  DMGA_WD_Config.enabled = false
  if DMGAWDMinimapBtn then DMGAWDMinimapBtn:Hide() end
  print("|cFF8866CC[DMGA]|r Diagnostic logging |cFFFF4444disabled|r.")
end


SLASH_DMGAWD1 = "/dmgawd"
SLASH_DMGAWD2 = "/watchdog"
SlashCmdList["DMGAWD"] = function(msg)
  local ok, err = pcall(function()
    local cmd = string.lower(string.gsub(msg or "", "^%s+", ""))

    if cmd == "enable" or cmd == "on" then
      DMGA_WD_Enable()
    elseif cmd == "disable" or cmd == "off" then
      DMGA_WD_Disable()
    elseif cmd == "" or cmd == "viewer" or cmd == "events" then
      if not DMGA_WD_Config.enabled then
        print("|cFF8866CC[DMGA]|r Diagnostic logging is disabled. Enable it in Options (Issues tab) or type |cFFFFD100/dmgawd enable|r")
        return
      end
      ToggleViewer()
    elseif cmd == "options" or cmd == "config" or cmd == "opt" then
      ToggleOptions()
    elseif cmd == "snap" or cmd == "snapshot" then
      if not DMGA_WD_Config.enabled then
        print("|cFF8866CC[DMGA]|r Enable diagnostic logging first: |cFFFFD100/dmgawd enable|r")
        return
      end
      PushEvent("MANUAL", "Manual snapshot captured")
      print("|cFF8866CC[DMGA]|r Snapshot captured. Open viewer to copy.")
    elseif cmd == "scan" or cmd == "apiscan" then
      RunAPIScan()
    elseif cmd == "clear" then
      wipe(DMGA_WD_Log)
      wipe(sessionEvents)
      wipe(combatSessions)
      wipe(DMGA_WD_APIScan)
      currentSessionIdx = nil
      selectedEventIdx = nil
      selectedSessionIdx = nil
      print("|cFF8866CC[DMGA]|r All diagnostic data cleared.")
    elseif cmd == "health" then
      local results = RunHealthChecks()
      local reportLines = FormatHealthReport(results)
      print("|cFF8866CC[DMGA]|r === Subsystem Health ===")
      for _, line in ipairs(reportLines) do
        if line ~= "--- Subsystem Health ---" then
          print("|cFF8866CC[DMGA]|r " .. line)
        end
      end
    elseif cmd == "status" then
      print("|cFF8866CC[DMGA]|r === Diagnostics Status ===")
      print("  Enabled: " .. (DMGA_WD_Config.enabled and "|cFF00CC00Yes|r" or "|cFFFF4444No|r"))
      print("  Events this session: " .. #sessionEvents)
      print("  Total saved events: " .. #DMGA_WD_Log)
      print("  DMGAssist loaded: " .. SafeToString(addonLoaded))
      local clfActive = SafeRead(function() return _G.CLF ~= nil end, false)
      print("  CLF active: " .. SafeToString(clfActive))
      if clfActive then
        local clf = SafeRead(function() return _G.CLF end, nil)
        if clf then
          print("  Heartbeat: " .. SafeToString(SafeReadField(clf, "_heartbeat", 0)))
          print("  Degraded: " .. SafeToString(SafeReadField(clf, "_runtimeDegraded", false)))
          print("  Errors: " .. SafeToString(SafeReadField(clf, "_runtimeErrorCount", 0)))
        end
      end
    else
      print("|cFF8866CC[DMGA]|r DMGAssist Diagnostics v" .. WD_VERSION)
      print("  Status: " .. (DMGA_WD_Config.enabled and "|cFF00CC00Enabled|r" or "|cFFFF4444Disabled|r"))
      print("  |cFFFFD100/dmgawd enable|r     -- Enable diagnostic logging")
      print("  |cFFFFD100/dmgawd disable|r    -- Disable diagnostic logging")
      print("  |cFFFFD100/dmgawd|r            -- Open Event Viewer")
      print("  |cFFFFD100/dmgawd options|r    -- Open Options panel")
      print("  |cFFFFD100/dmgawd snap|r       -- Capture manual snapshot")
      print("  |cFFFFD100/dmgawd scan|r       -- Run full API scan")
      print("  |cFFFFD100/dmgawd health|r     -- Run subsystem health checks")
      print("  |cFFFFD100/dmgawd status|r     -- Show monitoring status")
      print("  |cFFFFD100/dmgawd clear|r      -- Clear all saved data")
    end
  end)
  if not ok then
    print("|cFF8866CC[DMGA]|r |cFFFF4444Command error:|r " .. SafeToString(err))
  end
end
