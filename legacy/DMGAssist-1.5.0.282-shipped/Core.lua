-- CLF Core -- Addon initialization, event handling (performance-optimized)
local addonName, CLF = ...
_G.CLF = CLF
local L = CLF.L or setmetatable({}, {__index = function(_, k) return k end})

local COMBAT_INTERVAL = 0.05   -- 20 Hz in combat -- GCD-accurate
local OOC_INTERVAL = 0.25      -- 4 Hz out of combat -- saves CPU

local function Detaint(val)
  if type(val) == "nil" then return nil end
  if issecretvalue and issecretvalue(val) then return nil end
  return tonumber(val)
end
local DetaintStr = CLF.DetaintStr
local DetaintBool = CLF.DetaintBool
local SafeGetSpellName = CLF._SafeGetSpellName
local NormalizeName = CLF._NormalizeName
local SafeGetSpellCharges = CLF._SafeGetSpellCharges
local elapsed = 0
local isInCombat = false
CLF._inCombat = false
local currentInterval = OOC_INTERVAL

-- ── §C1: Issue Log ──
-- Ring buffer of runtime diagnostics, capped at MAX_ISSUES entries.
-- Categories: GLOW, ASSIST, KEYBIND, SPELL, TRINKET, APL, SNAPSHOT, COMBAT, INIT.
CLF._issueLog = CLF._issueLog or {}
CLF._conditionErrors = CLF._conditionErrors or {}
CLF._heartbeat = 0
CLF._wdEvents = {}
local MAX_ISSUE_LOG = 100
local MAX_WD_EVENTS = 60

function CLF.PushWDEvent(eventType, data)
  local ev = {
    t = eventType,
    ts = GetTime(),
    clock = date("%H:%M:%S"),
    d = data or {},
  }
  table.insert(CLF._wdEvents, ev)
  if #CLF._wdEvents > MAX_WD_EVENTS then table.remove(CLF._wdEvents, 1) end
end

function CLF.LogIssue(category, message, details)
  local entry = {
    time = date("%H:%M:%S"),
    timestamp = GetTime(),
    category = category or "General",
    message = message or "Unknown issue",
    details = details or "",
    count = 1,
  }
  local log = CLF._issueLog
  if #log > 0 then
    local last = log[#log]
    if last.category == entry.category and last.message == entry.message and last.details == entry.details then
      last.count = last.count + 1
      last.time = entry.time
      last.timestamp = entry.timestamp
      return
    end
  end
  table.insert(log, entry)
  if #log > MAX_ISSUE_LOG then table.remove(log, 1) end
end

function CLF.LogConditionError(spellName, errMsg)
  local ce = CLF._conditionErrors
  if not ce[spellName] then
    ce[spellName] = { count = 0, lastErr = "" }
  end
  ce[spellName].count = ce[spellName].count + 1
  local errOk2, errStr2 = pcall(tostring, errMsg)
  ce[spellName].lastErr = errOk2 and errStr2 or "?"
  if ce[spellName].count <= 3 then
    CLF.LogIssue("Condition", "Condition error for: " .. spellName, errOk2 and errStr2 or "?")
  end
end

function CLF.GetIssueLog() return CLF._issueLog end
function CLF.GetConditionErrors() return CLF._conditionErrors end
function CLF.ClearIssueLog()
  wipe(CLF._issueLog)
  wipe(CLF._conditionErrors)
end

CLF._runtimeErrorCount = 0
CLF._runtimeDegraded = false

-- ── §C2: Error Handling & Self-Recovery ──
-- Wraps tick code in pcall(). If errors exceed threshold, enters "degraded mode".
-- /dmga fixerrors resets and exits degraded mode.
local ERROR_THROTTLE = 5       -- seconds between error reports
local MAX_ERRORS_BEFORE_DEGRADE = 10  -- errors before switching to degraded mode
local errorCount = 0
local lastErrorTime = 0
local degradedMode = false
local lastErrorMsg = ""

local function SafeCall(func, context)
  local ok, err = pcall(func)
  if not ok then
    errorCount = errorCount + 1
    CLF._runtimeErrorCount = errorCount
    local now = GetTime()
    local errOk, errStr = pcall(tostring, err)
    local safeErr = errOk and errStr or "unknown error (secret value)"
    CLF.LogIssue("Runtime", "Error in " .. (context or "unknown"), safeErr)
    CLF.PushWDEvent("ERROR", { context = context or "unknown", msg = safeErr, count = errorCount })
    if now - lastErrorTime > ERROR_THROTTLE then
      lastErrorTime = now
      lastErrorMsg = safeErr
      local short = string.sub(safeErr, 1, 120)
      print("|cFFD4A632[DMGAssist]|r |cFFFF3333Error in " .. (context or "unknown") .. ":|r " .. short)
      if errorCount >= MAX_ERRORS_BEFORE_DEGRADE and not degradedMode then
        degradedMode = true
        CLF._runtimeDegraded = true
        CLF.PushWDEvent("DEGRADED", { errorCount = errorCount, lastError = safeErr })
        print("|cFFD4A632[DMGAssist]|r |cFFFF6600Entering degraded mode.|r HUD will show last known state. Type |cFFFFD100/dmga reset|r to recover.")
      end
    end
    if CLF.debugEnabled then
      CLF.Log("ERROR", (context or "unknown") .. ": " .. safeErr)
    end
    return false
  end
  return true
end

local DEGRADE_RECOVERY_TIME = 30  -- seconds of no errors before auto-recovering
local lastSuccessTime = 0

function CLF.IsDegraded() return degradedMode end
function CLF.ResetErrors()
  errorCount = 0
  degradedMode = false
  lastErrorMsg = ""
  CLF._runtimeErrorCount = 0
  CLF._runtimeDegraded = false
  lastSuccessTime = GetTime()
  CLF.ClearIssueLog()
  print("|cFFD4A632[DMGAssist]|r Error state cleared.")
end

function CLF.RunDiagnostics()
  local results = {}

  local config = CLF_Config
  if not config then
    table.insert(results, { severity = "error", text = "CLF_Config is nil -- spec not detected or Config.lua failed to load" })
  elseif not config.spec then
    table.insert(results, { severity = "error", text = "Config has no spec data" })
  else
    table.insert(results, { severity = "ok", text = "Spec: " .. config.spec.specName .. " " .. config.spec.className })
  end

  if not CLF_DefaultConfig then
    if CLF_AllSpecs then
      table.insert(results, { severity = "warn", text = "CLF_DefaultConfig is nil -- spec not yet detected (use /reload)" })
    else
      table.insert(results, { severity = "error", text = "CLF_DefaultConfig is nil -- Config.lua may have syntax errors" })
    end
  else
    table.insert(results, { severity = "ok", text = "Default config loaded" })
  end

  if config and config.apl then
    local count = #config.apl
    table.insert(results, { severity = count > 0 and "ok" or "warn", text = "APL entries: " .. count })
  else
    table.insert(results, { severity = "warn", text = "No APL data" })
  end

  if CLF.glowSettingsOk == false then
    table.insert(results, { severity = "warn", text = "Glow detection degraded -- use Auto-Fix Glows" })
  elseif CLF.glowSettingsOk then
    table.insert(results, { severity = "ok", text = "Glow detection: OK" })
  end

  if CLF._runtimeDegraded then
    table.insert(results, { severity = "error", text = "Addon in DEGRADED MODE (" .. CLF._runtimeErrorCount .. " errors). Type /dmga reset" })
  elseif CLF._runtimeErrorCount > 0 then
    table.insert(results, { severity = "warn", text = CLF._runtimeErrorCount .. " runtime error(s) caught" })
  else
    table.insert(results, { severity = "ok", text = "No runtime errors" })
  end

  local ceCount = 0
  for _ in pairs(CLF._conditionErrors) do ceCount = ceCount + 1 end
  if ceCount > 0 then
    table.insert(results, { severity = "warn", text = ceCount .. " spell(s) have condition errors (safe fallback active)" })
  else
    table.insert(results, { severity = "ok", text = "All spell conditions OK" })
  end

  if CLF._keybindCache then
    local kbCount = 0
    for _ in pairs(CLF._keybindCache) do kbCount = kbCount + 1 end
    table.insert(results, { severity = kbCount > 0 and "ok" or "warn", text = "Keybinds cached: " .. kbCount })
  end

  if CLF._bossModConnected then
    local mods = {}
    if DBM and DBM.RegisterCallback then table.insert(mods, "DBM") end
    if BigWigsLoader and BigWigsLoader.RegisterMessage then table.insert(mods, "BigWigs") end
    local timerCount = 0
    for _ in pairs(CLF._bossTimers or {}) do timerCount = timerCount + 1 end
    table.insert(results, { severity = "ok", text = "Boss Mods: |cFF00FF00" .. table.concat(mods, "+") .. "|r (timers:" .. timerCount .. " phase:" .. (CLF._bossPhase or 0) .. ")" })
  elseif DBM and DBM.RegisterCallback then
    table.insert(results, { severity = "ok", text = "DBM: |cFF00FF00Connected|r" })
  else
    table.insert(results, { severity = "warn", text = "DBM: |cFF888888Not installed|r" })
  end
  if not CLF._bossModConnected and BigWigsLoader and BigWigsLoader.RegisterMessage then
    table.insert(results, { severity = "ok", text = "BigWigs: |cFF00FF00Connected|r" })
  else
    table.insert(results, { severity = "warn", text = "BigWigs: |cFF888888Not installed|r" })
  end

  return results
end

local frame = CreateFrame("Frame", "CLF_CoreFrame", UIParent)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PLAYER_DEAD")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("PLAYER_TALENT_UPDATE")
frame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
frame:RegisterEvent("TRAIT_CONFIG_UPDATED")
frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
frame:RegisterEvent("UNIT_SPELLCAST_START")
frame:RegisterEvent("UNIT_SPELLCAST_STOP")
frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
frame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
frame:RegisterEvent("UPDATE_BINDINGS")
frame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
frame:RegisterEvent("SPELLS_CHANGED")
frame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterUnitEvent("UNIT_AURA", "player")
frame:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")

frame:SetScript("OnEvent", function(self, event, arg1, ...)
  if event == "ADDON_LOADED" and arg1 == "DMGAssist" then
    SafeCall(function() CLF.OnAddonLoaded() end, "ADDON_LOADED")
    return
  end
  if event == "COMBAT_LOG_EVENT_UNFILTERED" then
    if CombatLogGetCurrentEventInfo then
      local ts, subEvent, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags, p12, p13, p14, p15, p16, p17, p18, p19, p20, p21, p22, p23, p24 = CombatLogGetCurrentEventInfo()
      if type(subEvent) ~= "string" then return end
      local sub5 = string.sub(subEvent, 1, 5)
      local playerGUID = CLF._playerGUID
      if isInCombat and playerGUID then
        if subEvent == "UNIT_DIED" or subEvent == "SPELL_INSTAKILL" then
          if destGUID and CLF._debuffsByGUID then
            CLF._debuffsByGUID[destGUID] = nil
          end
        end
      end
      if subEvent == "SPELL_ENERGIZE" and destGUID == playerGUID then
        pcall(CLF.OnResourceCLEU, "SPELL_ENERGIZE", p12, p15, p17)
      elseif subEvent == "SPELL_CAST_SUCCESS" and sourceGUID == playerGUID then
        if destGUID and destGUID ~= playerGUID then
          local prevCleu = CLF._cleuTargetGUID
          CLF._cleuTargetGUID = destGUID
          if prevCleu ~= destGUID and not CLF._targetGUID then
            CLF._RebuildTargetAuras(destGUID)
          end
        end
        pcall(CLF.OnResourceCLEU, "SPELL_CAST_SUCCESS", p12)
        pcall(CLF.OnCastCLEU, "SPELL_CAST_SUCCESS", sourceGUID, p12, p13)
        pcall(function()
          local cleuSid = p12
          local cleuName = p13
          if Detaint then cleuSid = Detaint(cleuSid) end
          if DetaintStr then cleuName = DetaintStr(cleuName) end
          local resolvedName = nil
          if cleuName and type(cleuName) == "string" and cleuName ~= "" and cleuName ~= "0" and cleuName ~= tostring(cleuSid or 0) then
            resolvedName = cleuName
          end
          if not resolvedName and cleuSid and type(cleuSid) == "number" and cleuSid > 0 then
            resolvedName = CLF._spellIdToName and CLF._spellIdToName[cleuSid]
            if not resolvedName and CLF._spellIdNameCache then
              resolvedName = CLF._spellIdNameCache[cleuSid]
            end
            if not resolvedName and CLF._SafeGetSpellName then
              local ok, n = pcall(CLF._SafeGetSpellName, cleuSid)
              if ok and n then resolvedName = n end
            end
          end
          if resolvedName then
            local clean = string.lower(resolvedName)
            clean = string.gsub(clean, ":", "")
            clean = string.gsub(clean, "%s+", " ")
            if CLF.Charges.IsChargeSpell(clean) then
              if not CLF._cleuConsumedThisCast then CLF._cleuConsumedThisCast = {} end
              if not CLF._cleuConsumedThisCast[clean] then
                CLF._cleuConsumedThisCast[clean] = true
                CLF.Charges.Consume(clean)
                C_Timer.After(0.5, function() CLF._cleuConsumedThisCast[clean] = nil end)
              end
            end
            CLF.DetectEclipseFromBar(clean, true)
            if not CLF._selfBuffCastUntil then CLF._selfBuffCastUntil = {} end
            CLF._selfBuffCastUntil[clean] = GetTime()
          end
        end)
      elseif subEvent == "SWING_DAMAGE" and sourceGUID == playerGUID then
        local swingAmount = p12
        pcall(CLF.OnResourceCLEU, "SWING_DAMAGE", nil, swingAmount)
      elseif subEvent == "SPELL_CAST_START" then
        pcall(CLF.OnCastCLEU, "SPELL_CAST_START", sourceGUID, p12, p13)
      elseif subEvent == "SPELL_CAST_FAILED" then
        pcall(CLF.OnCastCLEU, "SPELL_CAST_FAILED", sourceGUID, p12, p13)
      elseif subEvent == "SPELL_INTERRUPT" then
        pcall(CLF.OnCastCLEU, "SPELL_INTERRUPT", sourceGUID, p12, p13)
      end
      if sub5 == "SPELL" then
        if subEvent == "SPELL_AURA_APPLIED" or subEvent == "SPELL_AURA_REMOVED" or subEvent == "SPELL_AURA_REFRESH"
           or subEvent == "SPELL_AURA_APPLIED_DOSE" or subEvent == "SPELL_AURA_REMOVED_DOSE" then
          pcall(CLF.OnAuraCLEU, subEvent, sourceGUID, destGUID, p12, p13, p15)
        end
      end
    end
    return
  end
  if event == "UNIT_SPELLCAST_SUCCEEDED" and arg1 == "player" then
    local castGUID, spellID = select(1, ...)
    if spellID then
      local cleanId = spellID
      local isSecret = issecretvalue and issecretvalue(spellID)
      if isSecret then
        cleanId = nil
      end
      local name = nil
      if cleanId and CLF._SafeGetSpellName then
        local ok, n = pcall(CLF._SafeGetSpellName, cleanId)
        if ok then name = n end
      end
      if not name and cleanId and CLF._spellIdNameCache then
        name = CLF._spellIdNameCache[cleanId]
      end
      if not name and isSecret then
        if CLF._SafeGetSpellName then
          local ok2, n2 = pcall(CLF._SafeGetSpellName, spellID)
          if ok2 and n2 then
            name = n2
          end
        end
        if not name and C_Spell and C_Spell.GetSpellName then
          local ok3, n3 = pcall(C_Spell.GetSpellName, spellID)
          if ok3 and type(n3) == "string" then
            local cleanN = DetaintStr and DetaintStr(n3) or n3
            if cleanN and cleanN ~= "" then
              name = cleanN
            end
          end
        end
      end
      if name then
        CLF.RecordCast(name)
        if CLF.RecordTrinketUse then CLF.RecordTrinketUse(name) end
        local castKey = string.lower(name)
        CLF.RecordOffGCD(castKey)
        if CLF._smartModeSwitchEnabled and CLF.combatMode == "ST" and not CLF._modeLock then
          local mMap = CLF._modeMap
          if mMap then
            local spellMode = mMap[castKey]
            if spellMode == "AoE" then
              CLF._smartSwitched = true
              CLF.combatMode = "AoE"
              CLF.ShowModeFlash("AoE")
              CLF.PlayEventSound("aoeSwitch")
              CLF.Msg("Smart switch: |cFFFFD100" .. name .. "|r cast, switching to |cFF00FF00AoE|r mode for this fight.")
            end
          end
        end
        if CLF.Charges.IsChargeSpell(castKey) then
          CLF.Charges.Consume(castKey)
        end
        pcall(CLF.OnSpellCastResource, cleanId or spellID, castKey)
        CLF.ClearStuckPenalty(castKey)
        if CLF._testInterruptActive and CLF._testInterruptSpell then
          local intKey = string.lower(CLF._testInterruptSpell)
          if castKey == intKey or string.find(castKey, intKey, 1, true) then
            CLF._testInterruptActive = false
            CLF._testInterruptSpell = nil
            CLF.Msg("|cFF00FF00Interrupt cast detected -- test cleared.|r")
          end
        end
        if CLF._interruptSpells and CLF._interruptSpells[castKey] then
          CLF._lastInterruptCastTime = GetTime()
        end
      end
    end
    return
  end
  if event == "UNIT_SPELLCAST_START" and arg1 == "player" then
    local castGUID, spellID = select(1, ...)
    SafeCall(function()
      local cs = CLF._castState.player
      cs.casting = true
      cs.channeling = false
      cs.startTime = GetTime()
      cs.duration = nil
      cs.spellId = spellID
      if spellID and CLF._SafeGetSpellName then
        local nOk, sn = pcall(CLF._SafeGetSpellName, spellID)
        if nOk and sn then cs.spellName = sn end
      end
      if UnitCastingInfo then
        pcall(function()
          local name, text, texture, startMS, endMS, isTradeSkill, notInterruptible = UnitCastingInfo("player")
          local sClean = Detaint(startMS)
          local eClean = Detaint(endMS)
          if sClean and eClean and eClean > sClean then
            local dur = (eClean - sClean) / 1000
            if dur > 0 and dur < 15 then
              cs.startTime = sClean / 1000
              cs.duration = dur
            end
          end
        end)
      end
      if not cs.duration or cs.duration <= 0 then
        local bookCT = CLF.SpellBookCastTime(cs.spellName)
        if bookCT and bookCT > 0 then
          cs.duration = bookCT
        else
          local entry = CLF._spellBook[string.lower(NormalizeName(cs.spellName or ""))]
          if entry and entry.baseCastTime and entry.baseCastTime > 0 then
            cs.duration = entry.baseCastTime / CLF.HasteMultiplier()
          else
            cs.duration = 1.5
          end
        end
      end
    end, "UNIT_SPELLCAST_START")
    return
  end
  if (event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP") and arg1 == "player" then
    SafeCall(function()
      local cs = CLF._castState.player
      if cs.casting and cs.startTime and cs.spellName then
        pcall(CLF.ObserveCastTime, cs.spellName, cs.startTime, GetTime())
      end
      cs.casting = false
      cs.channeling = false
      cs.spellId = nil
      cs.spellName = nil
      if event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        CLF._activeChannel = nil
      end
    end, event)
    return
  end
  if event == "UNIT_SPELLCAST_CHANNEL_START" and arg1 == "player" then
    local castGUID, spellID = select(1, ...)
    SafeCall(function()
      local cs = CLF._castState.player
      cs.casting = true
      cs.channeling = true
      cs.startTime = GetTime()
      cs.duration = nil
      cs.spellId = spellID
      local chSpellName = nil
      if spellID and CLF._SafeGetSpellName then
        local nOk, sn = pcall(CLF._SafeGetSpellName, spellID)
        if nOk and sn then
          cs.spellName = sn
          chSpellName = sn
        end
      end
      CLF._activeChannel = { spell = chSpellName, start = GetTime(), spellId = spellID }
      if UnitChannelInfo then
        pcall(function()
          local name, text, texture, startMS, endMS = UnitChannelInfo("player")
          local sClean = Detaint(startMS)
          local eClean = Detaint(endMS)
          if sClean and eClean and eClean > sClean then
            local dur = (eClean - sClean) / 1000
            if dur > 0 and dur < 30 then
              cs.startTime = sClean / 1000
              cs.duration = dur
            end
          end
        end)
      end
      if not cs.duration or cs.duration <= 0 then
        cs.duration = 3.0
      end
    end, "UNIT_SPELLCAST_CHANNEL_START")
    return
  end
  SafeCall(function() CLF.HandleEvent(event, arg1) end, event)
end)

-- ── §C3: ADDON_LOADED Initialization ──
-- Detects spec, merges config with defaults, builds APL, creates HUD, registers events.
local HEALER_DPS_FALLBACK = {
  ["druid-resto"]    = { default = "druid-balance", forms = { cat = "druid-feral", bear = "druid-guardian", moonkin = "druid-balance" } },
  ["monk-mw"]        = { default = "monk-ww" },
  ["paladin-holy"]   = { default = "paladin-ret" },
  ["priest-disc"]    = { default = "priest-shadow" },
  ["priest-holy"]    = { default = "priest-shadow" },
  ["shaman-resto"]   = { default = "shaman-ele" },
  ["evoker-pres"]    = { default = "evoker-dev" },
}

local function DeepCopyTable(src)
  if type(src) ~= "table" then return src end
  local copy = {}
  for k, v in pairs(src) do
    if type(v) == "table" then
      copy[k] = DeepCopyTable(v)
    else
      copy[k] = v
    end
  end
  return copy
end

local function DeepCopyHud(src)
  if not src then return {} end
  return DeepCopyTable(src)
end

function CLF.OnAddonLoaded()
  CLF._playerGUID = UnitGUID and DetaintStr(UnitGUID("player")) or nil
  if UnitRace then
    local ok, _, raceEn = pcall(UnitRace, "player")
    if ok and raceEn then
      CLF._playerRace = DetaintStr(raceEn)
    end
  end
  if CLF_AllSpecs and CLF_DetectSpec then
    local detected, specId = CLF_DetectSpec()
    if detected then
      CLF_DefaultConfig = DeepCopyTable(detected)
      CLF._varFns = detected._varFns or {}
      if not CLF_Config or (CLF_Config._specId and CLF_Config._specId ~= specId) then
        local savedHud = CLF_Config and DeepCopyHud(CLF_Config.hud)
        CLF_Config = DeepCopyTable(detected)
        CLF_Config._specId = specId
        CLF_Config._varFns = detected._varFns
        if savedHud then
          CLF_Config.hud = CLF_Config.hud or {}
          for k, v in pairs(savedHud) do
            CLF_Config.hud[k] = v
          end
        end
        print("|cFFD4A632[DMGAssist]|r Auto-detected: |cFF00FF00" .. detected.spec.specName .. " " .. detected.spec.className .. "|r")
      else
        CLF_Config._specId = specId
        CLF_Config.apl = DeepCopyTable(detected.apl)
        CLF_Config.interrupts = DeepCopyTable(detected.interrupts)
        CLF_Config.spec = DeepCopyTable(detected.spec)
        CLF_Config._varFns = detected._varFns
        CLF_Config._conditionAuraNames = detected._conditionAuraNames
        if detected.hud then
          CLF_Config.hud = CLF_Config.hud or {}
          for k, v in pairs(detected.hud) do
            if CLF_Config.hud[k] == nil then
              if type(v) == "table" then
                CLF_Config.hud[k] = DeepCopyTable(v)
              else
                CLF_Config.hud[k] = v
              end
            end
          end
        end
      end

      local fallback = HEALER_DPS_FALLBACK[specId]
      if fallback and CLF_AllSpecs then
        CLF._healerFallback = fallback
        local defaultDps = CLF_AllSpecs[fallback.default]
        if defaultDps then
          CLF._dpsAPL = defaultDps.apl
          print("|cFFD4A632[DMGAssist]|r Healer spec -- loaded |cFF00CCFF" .. (defaultDps.spec.specName or "?") .. "|r DPS rotation for damage")
        end
        if fallback.forms then
          CLF._formDpsAPLs = {}
          for formName, dpsSpecId in pairs(fallback.forms) do
            local formSpec = CLF_AllSpecs[dpsSpecId]
            if formSpec then
              CLF._formDpsAPLs[formName] = formSpec.apl
            end
          end
        end
      end
    else
      print("|cFFD4A632[DMGAssist]|r Could not detect spec -- will retry on PLAYER_ENTERING_WORLD")
    end
  end
  if not CLF_Config then
    CLF_Config = DeepCopyTable(CLF_DefaultConfig or {})
    if CLF_Config and CLF_Config.spec then
      print("|cFFD4A632[DMGAssist]|r Config loaded -- " .. CLF_Config.spec.specName .. " " .. CLF_Config.spec.className)
    end
  end
  if not CLF_Config or not CLF_Config.spec then
    if CLF_AllSpecs then
      for _, specData in pairs(CLF_AllSpecs) do
        CLF_Config = DeepCopyTable(specData)
        CLF_DefaultConfig = DeepCopyTable(specData)
        print("|cFFD4A632[DMGAssist]|r Using fallback config -- will re-detect on PLAYER_ENTERING_WORLD")
        break
      end
    end
  end

  if not CLF_Config then
    CLF_Config = {
      spec = { id = "unknown", className = "Unknown", specName = "Unknown", role = "dps", resource = "Mana", classColor = "#FFFFFF" },
      hud = {
        scale = 1.2, opacity = 0.95, iconSize = 48, predIconSize = 34, queueSlots = 3,
        framePadding = 16, iconSpacing = 14, positionX = 50, positionY = 50,
        showKeybind = true, keybindPosition = "bottom-right", keybindFontSize = 11, keybindColor = "White",
        showSpellName = true, spellNameFontSize = 10, spellNamePadding = 4, showHeader = true,
        resourceCapThreshold = 80, aoeThreshold = 3, showPrediction = true, predictionOpacity = 0.55, queueOpacity = 0.6,
        lockPosition = false, debugMode = false, showCooldownText = true, cooldownStyle = "sweep", showGcdSpark = true,
        outOfCombatMode = false, hideOutOfCombat = false,
        borderStyle = "thin", borderOpacity = 0.25, bgOpacity = 0.75, glowStyle = "gold",
        showQueueLabels = true, showCondition = false, formAwareness = true,
      },
      apl = {},
      interrupts = {},
    }
    print("|cFFD4A632[DMGAssist]|r Created default config -- will auto-detect your spec shortly")
  end

  if CLF_Config and CLF_Config.hud then
    local h = CLF_Config.hud
    h.showUtilityBox = nil
    h.showWeaveBox = nil
    h.weaveIconSize = nil
    h.weaveOffsetX = nil
    h.weaveOffsetY = nil
    h.weaveOpacity = nil
    h.showSelfHeals = nil
    h.showDefensives = nil
  end

  if CLF_Config and CLF_AllSpecs and CLF_Config.spec and CLF_Config.spec.id ~= "unknown" then
    local fresh = CLF_AllSpecs[CLF_Config.spec.id]
    if fresh then
      CLF_Config.apl = DeepCopyTable(fresh.apl)
      CLF_Config.interrupts = DeepCopyTable(fresh.interrupts)
      CLF_Config.spec = DeepCopyTable(fresh.spec)
      CLF_Config._varFns = fresh._varFns
      CLF_Config._conditionAuraNames = fresh._conditionAuraNames
      if fresh.hud then
        CLF_Config.hud = CLF_Config.hud or {}
        for k, v in pairs(fresh.hud) do
          if CLF_Config.hud[k] == nil then
            if type(v) == "table" then
              CLF_Config.hud[k] = DeepCopyTable(v)
            else
              CLF_Config.hud[k] = v
            end
          end
        end
      end
    end
  end

  if not CLF_DefaultConfig then
    CLF_DefaultConfig = DeepCopyTable(CLF_Config)
  end

  if not CLF_Position then CLF_Position = {} end
  if not CLF_Profiles then CLF_Profiles = {} end
  if not CLF_CharConfig then CLF_CharConfig = {} end
  if not CLF_SlotMap then CLF_SlotMap = {} end

  local activeProfile = CLF_CharConfig.activeProfile or "Default"
  if CLF_Profiles[activeProfile] then
    local saved = CLF_Profiles[activeProfile]
    if saved and saved._v and saved.hud and CLF_Config then
      CLF_Config.hud = CLF_Config.hud or {}
      for k, v in pairs(saved.hud) do
        if type(v) == "table" then
          CLF_Config.hud[k] = DeepCopyTable(v)
        else
          CLF_Config.hud[k] = v
        end
      end
      print("|cFFD4A632[DMGAssist]|r Loaded profile: |cFFFFD100" .. activeProfile .. "|r")
    elseif saved and not saved._v and CLF_Config and CLF_Config.hud then
      saved.hud = DeepCopyHud(CLF_Config.hud)
      saved._v = 2
      print("|cFFD4A632[DMGAssist]|r Upgraded profile: |cFFFFD100" .. activeProfile .. "|r (synced from current settings)")
    end
  end

  if CLF_Config and CLF_Config._autoCreateCharProfile then
    local cName = DetaintStr(UnitName("player")) or "Unknown"
    local cRealm = DetaintStr(GetRealmName()) or "Unknown"
    local cKey = cName .. " - " .. cRealm
    if not CLF_Profiles[cKey] then
      CLF_Profiles[cKey] = { hud = DeepCopyHud(CLF_Config and CLF_Config.hud or {}), _v = 2 }
      CLF_CharConfig.activeProfile = cKey
      print("|cFFD4A632[DMGAssist]|r Auto-created profile: |cFFFFD100" .. cKey .. "|r")
    elseif CLF_Profiles[cKey] then
      CLF_CharConfig.activeProfile = cKey
      local saved = CLF_Profiles[cKey]
      if saved and saved._v and saved.hud and CLF_Config then
        CLF_Config.hud = CLF_Config.hud or {}
        for k, v in pairs(saved.hud) do
          if type(v) == "table" then
            CLF_Config.hud[k] = DeepCopyTable(v)
          else
            CLF_Config.hud[k] = v
          end
        end
      elseif saved and not saved._v and CLF_Config and CLF_Config.hud then
        saved.hud = DeepCopyHud(CLF_Config.hud)
        saved._v = 2
      end
    end
  end

  if CLF_Config and CLF_Config.hud and CLF_Config.hud.debugMode then
    CLF.debugEnabled = true
  end
  if DMGA_WD_Config and DMGA_WD_Config.enabled and not CLF.debugEnabled then
    CLF.debugEnabled = true
  end
  if CLF_Config and CLF_Config.hud then
    local sms = CLF_Config.hud.smartModeSwitch
    if sms == false then
      CLF._smartModeSwitchEnabled = false
    else
      CLF._smartModeSwitchEnabled = true
    end
  end

  CLF.CreateHUD()
  CLF._manualShow = false
  local shouldHideOnLoad = CLF_Config and CLF_Config.hud and (CLF_Config.hud.hideOutOfCombat == true) and not DetaintBool(InCombatLockdown(), "InitLoad")
  if CLF_MainFrame then
    if shouldHideOnLoad then
      CLF_MainFrame:Hide()
    else
      CLF_MainFrame:Show()
    end
  end
  if DetaintBool(InCombatLockdown(), "InitLoad") then
    isInCombat = true
    CLF._inCombat = true
    currentInterval = COMBAT_INTERVAL
  end
  print("|cFFD4A632[DMGAssist]|r DMGAssist v1.5.0.282 loaded -- type /dmga options to configure")
  print("|cFFD4A632[DMGAssist]|r Type /dmga for commands")
  if CLF_Config and CLF_Config.hud and (CLF_Config.hud.hideOutOfCombat == true) then
    print("|cFFD4A632[DMGAssist]|r Auto-hide out of combat: |cFF00FF00ON|r")
  end

  CLF.CreateMinimapIcon()
  CLF.InitModeCycleKeybind()

  C_Timer.After(3, function()
    SafeCall(function()
      if CLF_CharConfig and CLF_CharConfig.welcomeSeen then return end
      CLF.ShowWelcomePopup()
    end, "WelcomePopup")
  end)
end

-- ── §C3.4b: First-Run Welcome Popup ──
function CLF.ShowWelcomePopup()
  if CLF._welcomeFrame then return end
  local POPUP_W = 460
  local POPUP_H = 300
  local gR, gG, gB = 0.83, 0.65, 0.2

  local f = CreateFrame("Frame", "CLF_WelcomeFrame", UIParent, "BackdropTemplate")
  f:SetSize(POPUP_W, POPUP_H)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
  f:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 2,
  })
  f:SetBackdropColor(0.08, 0.06, 0.03, 0.95)
  f:SetBackdropBorderColor(gR, gG, gB, 0.7)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)

  local title = f:CreateFontString(nil, "OVERLAY")
  title:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
  title:SetPoint("TOP", f, "TOP", 0, -14)
  title:SetTextColor(gR, gG, gB)
  title:SetText(L["WELCOME_TITLE"])

  local lineY = -42
  local lineTexts = {
    L["WELCOME_LINE_1"],
    L["WELCOME_LINE_2"],
    L["WELCOME_LINE_3"],
    L["WELCOME_LINE_4"],
  }
  for _, txt in ipairs(lineTexts) do
    local ln = f:CreateFontString(nil, "OVERLAY")
    ln:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    ln:SetPoint("TOPLEFT", f, "TOPLEFT", 20, lineY)
    ln:SetWidth(POPUP_W - 40)
    ln:SetJustifyH("LEFT")
    ln:SetTextColor(0.9, 0.9, 0.9)
    ln:SetText(txt)
    lineY = lineY - ln:GetStringHeight() - 10
  end

  local footer = f:CreateFontString(nil, "OVERLAY")
  footer:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
  footer:SetPoint("BOTTOM", f, "BOTTOM", 0, 50)
  footer:SetTextColor(0.5, 0.5, 0.5)
  footer:SetText(L["WELCOME_FOOTER"])

  local btnOk = CreateFrame("Button", nil, f, "BackdropTemplate")
  btnOk:SetSize(120, 28)
  btnOk:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -10, 14)
  btnOk:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  })
  btnOk:SetBackdropColor(gR*0.25, gG*0.25, gB*0.25, 0.8)
  btnOk:SetBackdropBorderColor(gR, gG, gB, 0.5)
  local okText = btnOk:CreateFontString(nil, "OVERLAY")
  okText:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
  okText:SetPoint("CENTER")
  okText:SetTextColor(gR, gG, gB)
  okText:SetText(L["WELCOME_BTN_OK"])
  btnOk:SetScript("OnClick", function()
    if not CLF_CharConfig then CLF_CharConfig = {} end
    CLF_CharConfig.welcomeSeen = true
    f:Hide()
    CLF._welcomeFrame = nil
  end)
  btnOk:SetScript("OnEnter", function(self) self:SetBackdropColor(gR*0.4, gG*0.4, gB*0.4, 0.9) end)
  btnOk:SetScript("OnLeave", function(self) self:SetBackdropColor(gR*0.25, gG*0.25, gB*0.25, 0.8) end)

  local btnSettings = CreateFrame("Button", nil, f, "BackdropTemplate")
  btnSettings:SetSize(140, 28)
  btnSettings:SetPoint("BOTTOMLEFT", f, "BOTTOM", 10, 14)
  btnSettings:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  })
  btnSettings:SetBackdropColor(0.12, 0.12, 0.14, 0.8)
  btnSettings:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.5)
  local settingsText = btnSettings:CreateFontString(nil, "OVERLAY")
  settingsText:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
  settingsText:SetPoint("CENTER")
  settingsText:SetTextColor(0.8, 0.8, 0.8)
  settingsText:SetText(L["WELCOME_BTN_SETTINGS"])
  btnSettings:SetScript("OnClick", function()
    if not CLF_CharConfig then CLF_CharConfig = {} end
    CLF_CharConfig.welcomeSeen = true
    f:Hide()
    CLF._welcomeFrame = nil
    CLF.ToggleSettings()
  end)
  btnSettings:SetScript("OnEnter", function(self) self:SetBackdropColor(0.2, 0.2, 0.22, 0.9) end)
  btnSettings:SetScript("OnLeave", function(self) self:SetBackdropColor(0.12, 0.12, 0.14, 0.8) end)

  CLF._welcomeFrame = f
  f:Show()
end

-- ── §C3.5: Mode Cycle Keybind ──
-- Keybinds are now registered via Bindings.xml and managed through
-- WoW's built-in Options → Keybindings → AddOns → DMGAssist panel.
-- Legacy stubs kept so saved configs referencing modeCycleKey don't error.
function CLF.InitModeCycleKeybind() end
function CLF.BindModeCycleKey() end
function CLF.UnbindModeCycleKey() end

-- ── §C4: Minimap Icon ──
-- Gold orb icon with tooltip showing addon info, left-click toggles HUD,
-- right-click opens context menu.
function CLF.CreateMinimapIcon()
  if CLF._minimapBtn then return end
  local pos = CLF_Position and CLF_Position.minimapAngle or 220

  local btn = CreateFrame("Button", "CLF_MinimapButton", Minimap)
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
  icon:SetTexture("Interface\\Icons\\Spell_Holy_FistOfJustice")
  icon:SetPoint("CENTER", 0, 1)

  local function UpdatePosition(angle)
    local rad = math.rad(angle)
    local mw, mh = Minimap:GetSize()
    local r = (mw or 140) / 2 + 5
    local x = r * math.cos(rad)
    local y = r * math.sin(rad)
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
  end

  UpdatePosition(pos)

  local isDragging = false
  btn:RegisterForDrag("LeftButton")
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

  btn:SetScript("OnDragStart", function()
    isDragging = true
  end)

  btn:SetScript("OnDragStop", function()
    isDragging = false
  end)

  btn:SetScript("OnUpdate", function()
    if not isDragging then return end
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local s = UIParent:GetEffectiveScale()
    cx, cy = cx / s, cy / s
    local angle = math.deg(math.atan2(cy - my, cx - mx))
    if not CLF_Position then CLF_Position = {} end
    CLF_Position.minimapAngle = angle
    btn:ClearAllPoints()
    UpdatePosition(angle)
  end)

  btn:SetScript("OnClick", function(self, button)
    if button == "LeftButton" then
      CLF.ToggleHUD()
    elseif button == "RightButton" then
      CLF.ShowMinimapMenu()
    end
  end)

  btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("|cFFD4A632DMGAssist|r v1.5.0.282")
    GameTooltip:AddLine("Left-click: Toggle HUD", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Right-click: Options menu", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Drag: Move icon", 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)

  btn:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)

  CLF._minimapBtn = btn
end

function CLF.ShowMinimapMenu()
  local menu = CreateFrame("Frame", "CLF_MinimapMenu", UIParent, "UIDropDownMenuTemplate")
  UIDropDownMenu_Initialize(menu, function(self, level)
    local info = UIDropDownMenu_CreateInfo()

    info.text = "|cFFD4A632DMGAssist|r"
    info.isTitle = true
    info.notCheckable = true
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.text = "Open Options"
    info.notCheckable = true
    info.func = function() CLF.ToggleSettings() end
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.text = "Show HUD"
    info.notCheckable = true
    info.func = function() CLF.ShowHUD() end
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.text = "Hide HUD"
    info.notCheckable = true
    info.func = function() CLF.HideHUD() end
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    local config = CLF_Config or CLF_DefaultConfig
    local locked = config and config.hud and config.hud.lockPosition
    info.text = locked and "Unlock Position" or "Lock Position"
    info.notCheckable = true
    info.func = function() CLF.LockHUD(not locked) end
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    local hideOOC = config and config.hud and (config.hud.hideOutOfCombat == true)
    info.text = "Hide Out of Combat"
    info.isNotRadio = true
    info.checked = hideOOC
    info.func = function()
      if config and config.hud then
        config.hud.hideOutOfCombat = not hideOOC
        local newVal = (config.hud.hideOutOfCombat == true)
        print("|cFFD4A632[DMGAssist]|r Auto-hide OOC: " .. (newVal and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))
        if newVal and not DetaintBool(InCombatLockdown(), "InCombatLockdown") then
          CLF._manualShow = false
          CLF.HideHUD()
        elseif not newVal then
          CLF.ShowHUD()
        end
      end
    end
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.text = "Force ST"
    info.notCheckable = true
    info.func = function() CLF.LockMode("ST") end
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.text = "Force AoE"
    info.notCheckable = true
    info.func = function() CLF.LockMode("AoE") end
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.text = "Content Default"
    info.notCheckable = true
    info.func = function()
      CLF._modeLock = nil
      CLF.DetectCombatMode()
      print("|cFFD4A632[DMGAssist]|r Mode: |cFF00FF00" .. CLF.combatMode .. "|r (content default)")
    end
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.text = " "
    info.isTitle = true
    info.notCheckable = true
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.text = "|cFFFF6666Reset All Settings|r"
    info.notCheckable = true
    info.func = function()
      CLF_Config = CLF_DefaultConfig
      CLF_Position = {}
      CLF.ResetErrors()
      CLF.SafeReload()
    end
    UIDropDownMenu_AddButton(info, level)
  end, "MENU")

  ToggleDropDownMenu(1, nil, menu, "cursor", 0, 0)
end

-- ── §C5: Event Dispatcher ──
-- Central event handler mapping WoW events to CLF functions.
function CLF.HandleEvent(event, arg1)
  if event == "PLAYER_ENTERING_WORLD" then
    C_Timer.After(2, function()
      SafeCall(function()
        if CLF_AllSpecs and CLF_DetectSpec then
          local detected, specId = CLF_DetectSpec()
          if detected then
            CLF_DefaultConfig = DeepCopyTable(detected)
            CLF._varFns = detected._varFns or {}
            if not CLF_Config or not CLF_Config._specId or CLF_Config._specId ~= specId then
              CLF._spellBook = {}
              CLF._chargeState = {}
              CLF._chargeSpellIds = {}
              CLF._knownCDDur = {}
              CLF._castLog = {}
              CLF._barCD = {}
              CLF._spellSlots = nil
              CLF.Log("SYSTEM", "Spec changed -- resetting spell book, charges, and CD tracking")
              local savedHud = CLF_Config and DeepCopyHud(CLF_Config.hud)
              CLF_Config = DeepCopyTable(detected)
              CLF_Config._specId = specId
              CLF_Config._varFns = detected._varFns
              if savedHud then
                CLF_Config.hud = CLF_Config.hud or {}
                for k, v in pairs(savedHud) do
                  CLF_Config.hud[k] = v
                end
              end
              print("|cFFD4A632[DMGAssist]|r Detected: |cFF00FF00" .. detected.spec.specName .. " " .. detected.spec.className .. "|r")
            else
              CLF_Config.apl = DeepCopyTable(detected.apl)
              CLF_Config.interrupts = DeepCopyTable(detected.interrupts)
              CLF_Config.spec = DeepCopyTable(detected.spec)
              CLF_Config._varFns = detected._varFns
              CLF_Config._conditionAuraNames = detected._conditionAuraNames
            end
          end
        end
        CLF.ScanEquippedTrinkets()
        C_Timer.After(3, function()
          SafeCall(function()
            local needRescan = false
            for _, t in pairs(CLF._trinkets) do
              if t.itemID and not t.hasUse then
                local rawSN = GetItemSpell(t.itemID)
                if rawSN then
                  needRescan = true
                  break
                end
              end
            end
            if needRescan then
              CLF.Log("INFO", "Trinket rescan: found new on-use data after delay")
              CLF.ScanEquippedTrinkets()
            end
          end, "TrinketDelayedRescan")
        end)
        CLF.InitConsumables()
        CLF.ScanKeybinds()
        CLF.RegisterBossModCallbacks()
        CLF.CheckGlowSettings()
        CLF.InvalidateSpellKnownCache()
        CLF._filteredAPL = nil
        if CLF_Config or CLF_DefaultConfig then
          CLF.BuildFilteredAPL()
          local f = CLF._filteredAPL
          local rotNow = f and f.rotation and #f.rotation or 0
          if rotNow == 0 then
            C_Timer.After(3, function()
              SafeCall(function()
                CLF.InvalidateSpellKnownCache()
                CLF.BuildFilteredAPL()
                local f2 = CLF._filteredAPL
                local rotRetry = f2 and f2.rotation and #f2.rotation or 0
                if rotRetry > 0 then
                  CLF.Msg("APL loaded (" .. rotRetry .. " rotation spells) after retry.")
                  CLF.PushWDEvent("APL_RETRY", { aplCount = rotRetry })
                end
              end, "APL_Retry")
            end)
          end
        end
        if not CLF_Config and not CLF_DefaultConfig then
          CLF.LogIssue("Config", "PLAYER_ENTERING_WORLD -- still no config available", "Config.lua may have a syntax error. Check for addon warnings.")
        end
        local cfg = CLF_Config or CLF_DefaultConfig
        SafeCall(function() CLF.CacheSpellCDs() end, "CacheSpellCDs_PEW")
        if not DetaintBool(InCombatLockdown(), "PEW_calRes") then
          pcall(CLF.CalibrateResource)
        end
        if DetaintBool(InCombatLockdown(), "PEW_combat") then
          isInCombat = true
          CLF._inCombat = true
          currentInterval = COMBAT_INTERVAL
          if CLF_MainFrame and not CLF_MainFrame:IsShown() then CLF_MainFrame:Show() end
        else
          isInCombat = false
          CLF._inCombat = false
          currentInterval = OOC_INTERVAL
          if cfg and cfg.hud and (cfg.hud.hideOutOfCombat == true) and not CLF._manualShow then
            if CLF_MainFrame then CLF_MainFrame:Hide() end
          end
        end
        local rotCount = 0
        if CLF._filteredAPL then
          rotCount = (CLF._filteredAPL.rotation and #CLF._filteredAPL.rotation or 0)
            + (CLF._filteredAPL.interrupts and #CLF._filteredAPL.interrupts or 0)
            + (CLF._filteredAPL.precombatState and #CLF._filteredAPL.precombatState or 0)
            + (CLF._filteredAPL.precombatOpener and #CLF._filteredAPL.precombatOpener or 0)
        end
        local rawAplCount = cfg and cfg.apl and #cfg.apl or 0
        CLF.PushWDEvent("INIT", {
          spec = cfg and cfg.spec and (cfg.spec.specName .. " " .. cfg.spec.className) or "none",
          aplCount = rotCount,
          rawAplCount = rawAplCount,
          config = cfg and "loaded" or "MISSING",
          version = "1.5.0.282",
        })
        C_Timer.After(2, function()
          SafeCall(function()
            CLF.RefreshAPLIcons()
            CLF.CacheSpellCDs()
            CLF.BuildSlotMap()
            CLF.CacheSpellUsability()
            CLF.CacheSpellCosts()
            CLF.CacheChargeInfo()
            CLF.ResolveDoTSpellIds()
            CLF.RefreshSpellBookOOC()
            if CLF.BuildRotationSpellMap then
              CLF.BuildRotationSpellMap()
            end
            if not DetaintBool(InCombatLockdown(), "PEW_calRes2") then
              pcall(CLF.CalibrateResource)
            end
          end, "IconRefresh_PEW")
        end)
      end, "PLAYER_ENTERING_WORLD_delayed")
    end)

  elseif event == "PLAYER_REGEN_DISABLED" then
    isInCombat = true
    CLF._inCombat = true
    currentInterval = COMBAT_INTERVAL
    CLF._combatStart = GetTime()
    CLF._lastTargetHP = nil
    CLF._lastTargetTime = nil
    CLF._manualShow = false
    if CLF.UpdateConsumableBar then
      pcall(CLF.UpdateConsumableBar)
    end
    CLF._stuckPenalties = {}
    CLF._stuckTopSpell = nil
    CLF._stuckTopSince = 0
    CLF._primaryLock = nil
    CLF._lastRotationCastTime = GetTime()
    CLF._stalenessActive = false
    CLF._spellCDAlwaysSecret = nil
    if CLF._dotCastLogOOCTime then
      local oocDuration = GetTime() - CLF._dotCastLogOOCTime
      if oocDuration > 30 then
        CLF.ClearDotCastLog()
      end
      CLF._dotCastLogOOCTime = nil
    end
    if CLF._dotCastLogStale then
      CLF.ClearDotCastLog()
      CLF._dotCastLogStale = false
    end
    CLF._playerGUID = UnitGUID and DetaintStr(UnitGUID("player")) or nil
    CLF._targetGUID = UnitGUID and DetaintStr(UnitGUID("target")) or nil
    pcall(CLF.SnapshotStats)
    CLF.InitResourceTracker()
    CLF.ScanPlayerBuffs()
    CLF.ScanTargetDebuffs()
    CLF.SnapshotTaintForCombat()
    CLF.CacheSpellUsability()
    CLF.ResolveDoTSpellIds()
    if not CLF_MainFrame then CLF.CreateHUD() end
    if CLF_MainFrame then CLF_MainFrame:Show() end
    CLF.PushWDEvent("COMBAT_START", {
      enemies = CLF.ActiveEnemies(),
      mode = CLF.combatMode or "?",
      health = CLF.PlayerHealthPct(),
      form = CLF._cachedFormName or "caster",
      heartbeat = CLF._heartbeat,
    })

  elseif event == "SPELL_UPDATE_COOLDOWN" then
    if not CLF._inCombat and C_ActionBar and C_ActionBar.GetActionCooldownDuration then
      for spellKey, slotID in pairs(CLF._spellSlots) do
        local ok, durObj = pcall(C_ActionBar.GetActionCooldownDuration, slotID)
        if ok and durObj and durObj.IsZero then
          local zOk, isZero = pcall(durObj.IsZero, durObj)
          if zOk and type(isZero) == "boolean" and not (issecretvalue and issecretvalue(isZero)) then
            if not isZero then
              CLF._barCD[spellKey] = { start = GetTime(), duration = CLF._knownCDDur[spellKey] or 0 }
            else
              CLF._barCD[spellKey] = nil
            end
          end
        end
        if C_Spell and C_Spell.GetSpellCharges and CLF._chargeSpellIds then
          local rawType, rawId = GetActionInfo(slotID)
          local spellId = rawId and (not issecretvalue or not issecretvalue(rawId)) and rawId or nil
          if spellId and CLF._chargeSpellIds[spellId] then
            local hasCharges = false
            local chCur, chMax = 0, 1
            local chCurTainted = false
            pcall(function()
              local info = C_Spell.GetSpellCharges(spellId)
              if info and info.maxCharges then
                local mc = info.maxCharges
                if not (issecretvalue and issecretvalue(mc)) and mc > 1 then
                  hasCharges = true
                  chCur = info.currentCharges or 0
                  chMax = mc
                  if issecretvalue and issecretvalue(chCur) then
                    chCurTainted = true
                    chCur = 0
                  end
                end
              end
            end)
            if hasCharges then
              if chCurTainted then
                local ex1 = CLF._chargeState[spellKey]
                if ex1 then ex1.max = chMax end
                local ex2 = CLF._chargeState[tostring(spellId)]
                if ex2 then ex2.max = chMax end
              else
                local chEntry = { current = chCur, max = chMax }
                CLF._chargeState[spellKey] = chEntry
                CLF._chargeState[tostring(spellId)] = chEntry
              end
            end
          end
        end
      end
    end

  elseif event == "PLAYER_REGEN_ENABLED" then
    isInCombat = false
    CLF._inCombat = false
    currentInterval = OOC_INTERVAL
    CLF.ResetAuraState()
    pcall(CLF.ScanPlayerBuffs)
    C_Timer.After(0.8, function()
      SafeCall(CLF.DrainOOCScans, "DrainOOCScans_RegenEnabled")
    end)
    CLF.CalibrateResource()
    CLF._prevPrimarySpell = nil
    CLF._castLog = {}
    CLF._firstCombatCastTime = 0
    CLF._dotCastLogOOCTime = GetTime()
    CLF._stuckPenalties = {}
    CLF._stuckTopSpell = nil
    CLF._stuckTopSince = 0
    if CLF._rangeCache then wipe(CLF._rangeCache) end
    if CLF._smartSwitched then
      CLF._smartSwitched = false
      CLF.DetectCombatMode()
    end
    SafeCall(function() CLF.CacheSpellCDs() end, "CacheSpellCDs")
    C_Timer.After(0.5, function()
      SafeCall(function() CLF.RefreshSpellBookOOC() end, "SpellBookOOC_RegenEnabled")
    end)
    local combatDuration = CLF._combatStart and (GetTime() - CLF._combatStart) or 0
    local taintSummary = CLF.GetCombatTaintSummary()
    CLF.PushWDEvent("COMBAT_END", {
      duration = string.format("%.1f", combatDuration),
      errors = CLF._runtimeErrorCount or 0,
      heartbeat = CLF._heartbeat,
      health = CLF.PlayerHealthPct(),
      taint = taintSummary,
    })
    CLF.ResetTaintTracking()
    CLF.CacheSpellUsability()
    CLF.MarkSlotMapDirty()
    C_Timer.After(0.3, function()
      SafeCall(function() CLF.BuildSlotMap() end, "SlotMap_RegenEnabled")
    end)
    CLF._combatStart = 0
    local config = CLF_Config or CLF_DefaultConfig
    local hideOOC = config and config.hud and (config.hud.hideOutOfCombat == true)
    if hideOOC and not CLF._manualShow then
      if CLF_MainFrame then CLF_MainFrame:Hide() end
      C_Timer.After(2, function()
        SafeCall(function()
          local c = CLF_Config or CLF_DefaultConfig
          local stillHide = c and c.hud and (c.hud.hideOutOfCombat == true)
          if stillHide and not CLF._manualShow and not DetaintBool(InCombatLockdown(), "InCombatLockdown") then
            if CLF_MainFrame then CLF_MainFrame:Hide() end
          end
        end, "REGEN_ENABLED_delayed")
      end)
    end
    C_Timer.After(1.5, function()
      SafeCall(function()
        CLF.CheckConsumableBuffs()
      end, "ConsumableOOCCheck")
    end)

  elseif event == "PLAYER_DEAD" then
    if CLF._precombatApplied then wipe(CLF._precombatApplied) end

  elseif event == "PLAYER_TARGET_CHANGED" then
    CLF._targetGUID = UnitGUID and DetaintStr(UnitGUID("target")) or nil
    CLF.DetectCombatMode()
    if isInCombat then
      if CLF._targetGUID then
        CLF._cleuTargetGUID = CLF._targetGUID
        CLF._RebuildTargetAuras(CLF._targetGUID)
      else
        local prefix = "target:"
        for k in pairs(CLF._auraState) do
          if string.sub(k, 1, #prefix) == prefix then
            CLF._auraState[k] = nil
          end
        end
      end
    else
      CLF.ScanTargetDebuffs()
    end
    if not isInCombat then
      local cfg = CLF_Config or CLF_DefaultConfig
      local cfgHud = cfg and cfg.hud
      if cfgHud and (cfgHud.hideOutOfCombat == true) and (cfgHud.outOfCombatMode == true) and not CLF._manualShow then
        local rawTE = UnitExists and UnitExists("target")
        local hasTarget = false
        if rawTE ~= nil then
          if issecretvalue and issecretvalue(rawTE) then
            hasTarget = true
          else
            hasTarget = rawTE and true or false
          end
        end
        local isHostile = false
        if hasTarget then
          local rawCA = UnitCanAttack and UnitCanAttack("player", "target")
          if rawCA ~= nil then
            if issecretvalue and issecretvalue(rawCA) then
              isHostile = true
            else
              isHostile = rawCA and true or false
            end
          end
          if not isHostile then
            local rawReact = UnitReaction and UnitReaction("player", "target")
            if rawReact ~= nil then
              if issecretvalue and issecretvalue(rawReact) then
                isHostile = true
              else
                local reaction = tonumber(rawReact) or 5
                isHostile = reaction <= 4
              end
            end
          end
        end
        if hasTarget and isHostile then
          if CLF_MainFrame and not CLF_MainFrame:IsShown() then CLF_MainFrame:Show() end
        else
          if CLF_MainFrame and CLF_MainFrame:IsShown() then CLF_MainFrame:Hide() end
        end
      end
    end

  elseif event == "PLAYER_TALENT_UPDATE" or event == "ACTIVE_TALENT_GROUP_CHANGED" or event == "TRAIT_CONFIG_UPDATED" then
    local oldSpec = CLF_Config and CLF_Config.spec and CLF_Config.spec.specName or "unknown"
    if CLF_AllSpecs and CLF_DetectSpec then
      local detected, specId = CLF_DetectSpec()
      if detected and (not CLF_Config or CLF_Config._specId ~= specId) then
        local savedHUD = CLF_Config and DeepCopyHud(CLF_Config.hud)
        CLF_Config = DeepCopyTable(detected)
        CLF_Config._specId = specId
        CLF_Config._varFns = detected._varFns
        if savedHUD then
          CLF_Config.hud = CLF_Config.hud or {}
          for k, v in pairs(savedHUD) do
            CLF_Config.hud[k] = v
          end
        end
        CLF_DefaultConfig = DeepCopyTable(detected)
        CLF._varFns = detected._varFns or {}
        CLF.PushWDEvent("SPEC_CHANGE", {
          from = oldSpec,
          to = detected.spec.specName .. " " .. detected.spec.className,
          aplCount = detected.apl and #detected.apl or 0,
        })
        print("|cFFD4A632[DMGAssist]|r Spec changed: |cFF00FF00" .. detected.spec.specName .. " " .. detected.spec.className .. "|r")
      end
    end
    CLF.InvalidateSpellKnownCache()
    CLF.InvalidateTalentCache()
    CLF.InvalidateFormCache()
    CLF.InvalidateKeybindCache()
    CLF.MarkSlotMapDirty()
    CLF._learnedFormIndex = nil
    CLF._filteredAPL = nil
    CLF._knownCDDur = {}
    if CLF._precombatApplied then wipe(CLF._precombatApplied) end
    CLF._cdLearnRetries = 0
    CLF._castLog = {}
    CLF._firstCombatCastTime = 0
    CLF._spellBook = {}
    CLF._castObservations = {}
    CLF._spellNameToId = {}
    CLF._spellIdToName = {}
    CLF._usableCache = {}
    CLF._usableCacheTime = 0
    CLF._spellCosts = {}
    CLF._barCD = {}
    CLF._auraResolveAttempted = false
    print("|cFFD4A632[DMGAssist]|r Talents changed -- rebuilding spell filter")
    C_Timer.After(0.5, function()
      SafeCall(function()
        CLF.ScanPlayerBuffs()
        CLF.BuildSlotMap()
        CLF.ScanKeybinds()
        CLF.BuildFilteredAPL()
        CLF.LearnSpellCDs(true)
        CLF.CacheSpellUsability()
        CLF.ResolveDoTSpellIds()
        CLF.RefreshSpellBookOOC()
        if CLF.BuildRotationSpellMap then
          CLF.BuildRotationSpellMap()
        end
      end, "BuildFilteredAPL_talent")
    end)

  elseif event == "UPDATE_SHAPESHIFT_FORM" then
    CLF.InvalidateFormCache()
    CLF.InvalidateKeybindCache()
    CLF.MarkSlotMapDirty()
    CLF.ScanPlayerBuffs()
    CLF._filteredAPL = nil
    SafeCall(function()
      CLF.BuildFilteredAPL()
      CLF.CacheSpellUsability()
    end, "BuildFilteredAPL_form")
    if CLF.debugEnabled then
      CLF.Log("INFO", "Form changed to: " .. CLF.CurrentForm() .. " -- APL re-filtered")
    end

  elseif event == "PLAYER_EQUIPMENT_CHANGED" then
    local equipSlot = arg1
    if equipSlot == 13 or equipSlot == 14 then
      CLF.Log("INFO", "Trinket slot " .. equipSlot .. " changed -- rescanning")
      C_Timer.After(0.5, function()
        SafeCall(function()
          CLF.ScanEquippedTrinkets()
          CLF._filteredAPL = nil
          CLF.BuildFilteredAPL()
        end, "TrinketRescan")
      end)
    end
    C_Timer.After(1.0, function()
      SafeCall(function() CLF.RefreshSpellBookOOC() end, "SpellBookOOC_EquipChange")
    end)

  elseif event == "BAG_UPDATE_DELAYED" then
    SafeCall(function() CLF.InitConsumables() end, "ConsumableBagRefresh")

  elseif event == "UPDATE_BINDINGS" or event == "ACTIONBAR_SLOT_CHANGED" then
    CLF.InvalidateKeybindCache()
    CLF.MarkSlotMapDirty()

  elseif event == "SPELLS_CHANGED" then
    CLF.InvalidateKeybindCache()
    CLF.InvalidateSpellKnownCache()
    CLF.MarkSlotMapDirty()
    CLF._filteredAPL = nil
    if CLF._spellChangeTimer then
      CLF._spellChangeTimer:Cancel()
    end
    CLF._spellChangeTimer = C_Timer.NewTimer(0.5, function()
      CLF._spellChangeTimer = nil
      SafeCall(function()
        CLF.BuildFilteredAPL()
        CLF.ScanKeybinds()
        CLF.RefreshAPLIcons()
        if CLF.debugEnabled then
          CLF.Log("INFO", "Spells changed -- APL rebuilt, keybinds rescanned")
        end
      end, "SpellsChanged_rebuild")
    end)
  elseif event == "PLAYER_LEVEL_UP" then
    CLF.InvalidateSpellKnownCache()
    CLF.InvalidateTalentCache()
    CLF._filteredAPL = nil
    C_Timer.After(1.0, function()
      SafeCall(function()
        CLF.BuildFilteredAPL()
        CLF.ScanKeybinds()
      end, "LevelUp_rebuild")
    end)
    if CLF.debugEnabled then
      CLF.Log("INFO", "Level up detected -- rebuilding APL with new spells")
    end

  elseif event == "PLAYER_LOGOUT" then
    if CLF_CharConfig and CLF_Profiles then
      local active = CLF_CharConfig.activeProfile
      if active and active ~= "Default" then
        local config = CLF_Config or CLF_DefaultConfig
        if config and config.hud then
          if not CLF_Profiles[active] then CLF_Profiles[active] = {} end
          CLF_Profiles[active].hud = {}
          for k, v in pairs(config.hud) do
            if type(v) == "table" then
              CLF_Profiles[active].hud[k] = {}
              for k2, v2 in pairs(v) do CLF_Profiles[active].hud[k][k2] = v2 end
            else
              CLF_Profiles[active].hud[k] = v
            end
          end
        end
      end
    end

  elseif event == "UNIT_AURA" then
    if arg1 == "player" and not isInCombat then
      local now = GetTime()
      if now - (CLF._lastConsumableCheck or 0) > 2.0 then
        CLF._lastConsumableCheck = now
        SafeCall(function()
          CLF.CheckConsumableBuffs()
        end, "ConsumableAuraCheck")
      end
    end

  elseif event == "UNIT_POWER_FREQUENT" then
    if arg1 == "player" then
      pcall(CLF.OnUnitPowerFrequent)
    end

  end
end

-- ── §C7: OnUpdate Loop ──
-- Throttled update loop: 20 Hz in combat (50ms), 4 Hz out of combat (250ms).
-- Each tick: RefreshSnapshot → EvaluateAPL → UpdateHUD.
frame:SetScript("OnUpdate", function(self, dt)
  elapsed = elapsed + dt
  if elapsed < currentInterval then return end
  elapsed = 0

  local config = CLF_Config or CLF_DefaultConfig
  if not config then return end

  CLF._heartbeat = CLF._heartbeat + 1

  local ooc = config.hud and (config.hud.outOfCombatMode == true)

  if not isInCombat then
    local testActive = CLF._testInterruptActive
    local hideOOC = config.hud and (config.hud.hideOutOfCombat == true)
    if hideOOC and not CLF._manualShow and not testActive then
      local rawTE = UnitExists and UnitExists("target")
      local hasTarget = rawTE ~= nil and ((issecretvalue and issecretvalue(rawTE)) or (rawTE and true or false))
      local isHostile = false
      if hasTarget then
        local rawCA = UnitCanAttack and UnitCanAttack("player", "target")
        if rawCA ~= nil then
          if issecretvalue and issecretvalue(rawCA) then
            isHostile = true
          else
            isHostile = rawCA and true or false
          end
        end
        if not isHostile then
          local rawReact = UnitReaction and UnitReaction("player", "target")
          if rawReact ~= nil then
            if issecretvalue and issecretvalue(rawReact) then
              isHostile = true
            else
              local reaction = tonumber(rawReact) or 5
              isHostile = reaction <= 4
            end
          end
        end
      end
      if ooc and hasTarget and isHostile then
        if CLF_MainFrame and not CLF_MainFrame:IsShown() then CLF_MainFrame:Show() end
      else
        if CLF_MainFrame and CLF_MainFrame:IsShown() then CLF_MainFrame:Hide() end
        CLF.lastQueue = {}
        return
      end
    end
    if testActive and CLF_MainFrame and not CLF_MainFrame:IsShown() then
      CLF_MainFrame:Show()
    end
  end

  if degradedMode then
    local now = GetTime()
    if now - lastErrorTime >= DEGRADE_RECOVERY_TIME then
      degradedMode = false
      errorCount = 0
      CLF._runtimeDegraded = false
      CLF._runtimeErrorCount = 0
      print("|cFFD4A632[DMGAssist]|r Auto-recovered from degraded mode.")
    else
      return
    end
  end

  local ok = SafeCall(function()
    if isInCombat then
      local now = GetTime()
      if now - (CLF._lastBuffRescan or 0) >= 1.5 then
        CLF._lastBuffRescan = now
        CLF.ScanPlayerBuffs()
      end
    end
    CLF.DetectCombatMode()
    local queue = CLF.EvaluateAPL()
    CLF.UpdateHUD(queue)
  end, "OnUpdate")
  if ok then
    lastSuccessTime = GetTime()
  end
end)


-- Keybind scanner -- builds cached spell→keybind map once, then O(1) lookups
function CLF.ScanKeybinds()
  CLF.ScanAllKeybinds()

  local config = CLF_Config or CLF_DefaultConfig
  if not config then return end
  local apl = config.apl or {}
  local found = 0
  for _, entry in ipairs(apl) do
    if not entry.keybind or entry.keybind == "" then
      local kb = CLF.GetKeybind(entry.spellName)
      if kb then
        entry.keybind = kb
        found = found + 1
      end
    end
  end
  if found > 0 then
    print("|cFFD4A632[DMGAssist]|r Auto-detected " .. found .. " keybind(s) from action bars")
  end
end

-- Glow settings diagnostic
-- WoW CVars that control spell overlay glows:
--   SpellActivationOverlayOpacity (0-1, default 0.5) -- proc glow brightness
--   displaySpellActivationOverlays (0/1) -- master toggle for proc overlays
-- If these are off, CLF's proc detection degrades -- only Assisted Highlights and spell readiness remain.
function CLF.CheckGlowSettings()
  local issues = {}
  CLF.glowSettingsOk = true

  -- Check master overlay toggle
  local overlayEnabled = DetaintStr(GetCVar("displaySpellActivationOverlays"))
  if overlayEnabled == "0" then
    table.insert(issues, "Spell Activation Overlays are DISABLED")
    CLF.glowSettingsOk = false
  end

  -- Check overlay opacity (too low = effectively invisible)
  local opacity = tonumber(DetaintStr(GetCVar("SpellActivationOverlayOpacity")) or "0.5") or 0.5
  if opacity < 0.1 then
    table.insert(issues, "Spell Activation Overlay Opacity is very low (" .. string.format("%.0f%%", opacity * 100) .. ")")
    CLF.glowSettingsOk = false
  end

  local assistedOk = false
  local assistedCvarNames = { "assistedCombatHighlight", "empowermentHighlight", "assistedHighlight" }
  for _, cname in ipairs(assistedCvarNames) do
    local ok, raw = pcall(GetCVar, cname)
    if ok and raw then
      local val = DetaintStr(raw)
      if val and val ~= "0" and val ~= "" then
        assistedOk = true
        break
      end
      if val == "0" then
        table.insert(issues, "Assisted Combat Highlights are DISABLED (CVar: " .. cname .. ")")
        CLF.glowSettingsOk = false
        break
      end
    end
  end

  if #issues > 0 then
    print("|cFFD4A632[DMGAssist]|r |cFFFF6600WARNING:|r Detected settings that reduce CLF effectiveness:")
    for _, issue in ipairs(issues) do
      print("|cFFD4A632[DMGAssist]|r   - " .. issue)
    end
    if not CLF.glowSettingsOk then
      print("|cFFD4A632[DMGAssist]|r   Type |cFFFFD100/dmga fixglows|r to auto-fix overlay settings.")
    end
    local showPopup = (DetaintStr(GetCVar("displaySpellActivationOverlays")) == "0")
    if showPopup then
      local config = CLF_Config or CLF_DefaultConfig
      local suppress = config and config.hud and config.hud.suppressGlowPopup
      if not suppress then
        C_Timer.After(3, function() CLF.ShowGlowPopup() end)
      end
    end
    if not assistedOk and not CLF._assistedDismissed then
      C_Timer.After(5, function()
        if CLF.ShowAssistedWarning and not CLF._assistedEverSeen then
          CLF._assistedWarningShown = true
          CLF.ShowAssistedWarning()
        end
      end)
    end
  else
    if assistedOk then
      CLF._assistedEverSeen = true
    end
    print("|cFFD4A632[DMGAssist]|r Glow detection: all settings OK")
  end
end

function CLF.FixGlowSettings()
  local fixed = {}

  local overlayEnabled = DetaintStr(GetCVar("displaySpellActivationOverlays"))
  if overlayEnabled == "0" then
    SetCVar("displaySpellActivationOverlays", "1")
    table.insert(fixed, "Enabled Spell Activation Overlays")
  end

  local opacity = tonumber(DetaintStr(GetCVar("SpellActivationOverlayOpacity")) or "0.5") or 0.5
  if opacity < 0.3 then
    SetCVar("SpellActivationOverlayOpacity", "0.5")
    table.insert(fixed, "Set overlay opacity to 50%")
  end

  if #fixed > 0 then
    print("|cFFD4A632[DMGAssist]|r Fixed " .. #fixed .. " setting(s):")
    for _, f in ipairs(fixed) do
      print("|cFFD4A632[DMGAssist]|r   - " .. f)
    end
    CLF.glowSettingsOk = true
  else
    print("|cFFD4A632[DMGAssist]|r All glow settings are already correct")
  end
end

function CLF.ShowGlowPopup()
  if CLF._glowPopupShown then return end
  CLF._glowPopupShown = true

  local popup = CreateFrame("Frame", "CLF_GlowPopup", UIParent, "BackdropTemplate")
  popup:SetSize(420, 260)
  popup:SetPoint("CENTER")
  popup:SetFrameStrata("DIALOG")
  popup:SetFrameLevel(100)
  popup:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 2,
  })
  popup:SetBackdropColor(0.08, 0.08, 0.1, 0.95)
  popup:SetBackdropBorderColor(0.83, 0.65, 0.2, 0.8)

  local title = popup:CreateFontString(nil, "OVERLAY")
  title:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE")
  title:SetPoint("TOP", popup, "TOP", 0, -16)
  title:SetTextColor(1, 0.82, 0.2, 1)
  title:SetText("DMGAssist -- Assisted Highlight Disabled")

  local icon = popup:CreateFontString(nil, "OVERLAY")
  icon:SetFont("Fonts\\FRIZQT__.TTF", 28, "OUTLINE")
  icon:SetPoint("TOP", title, "BOTTOM", 0, -8)
  icon:SetTextColor(1, 0.4, 0.2, 1)
  icon:SetText("!")

  local body = popup:CreateFontString(nil, "OVERLAY")
  body:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
  body:SetPoint("TOP", icon, "BOTTOM", 0, -8)
  body:SetWidth(380)
  body:SetJustifyH("CENTER")
  body:SetTextColor(0.85, 0.85, 0.85, 1)
  body:SetText("Your Spell Activation Overlays are turned off in WoW settings.\n\nDMGAssist uses these overlays to detect proc glows on your action bars -- one of its three signal sources for building your rotation queue.\n\nWithout it, only Assisted Highlights and spell readiness data will work. You'll get a less accurate queue.\n\nClick below to fix it instantly, or find it manually in:\nGame Menu > Options > Gameplay Enhancements > Assisted Highlight")

  local fixBtn = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
  fixBtn:SetSize(170, 30)
  fixBtn:SetPoint("BOTTOM", popup, "BOTTOM", -90, 48)
  fixBtn:SetText("|cFF00FF00Fix It Now|r")
  fixBtn:SetScript("OnClick", function()
    CLF.FixGlowSettings()
    popup:Hide()
    print("|cFFD4A632[DMGAssist]|r Glow settings fixed! Proc detection is now active.")
  end)

  local settingsBtn = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
  settingsBtn:SetSize(170, 30)
  settingsBtn:SetPoint("LEFT", fixBtn, "RIGHT", 10, 0)
  settingsBtn:SetText("Open WoW Settings")
  settingsBtn:SetScript("OnClick", function()
    CLF.Msg("To open settings: press |cFF00FF00Escape|r > |cFF00FF00Options|r > |cFF00FF00Gameplay Enhancements|r to toggle Assisted Highlight.")
  end)

  local dontShow = CreateFrame("CheckButton", nil, popup, "UICheckButtonTemplate")
  dontShow:SetSize(22, 22)
  dontShow:SetPoint("BOTTOMLEFT", popup, "BOTTOMLEFT", 14, 14)
  local dontShowLabel = dontShow:CreateFontString(nil, "OVERLAY")
  dontShowLabel:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
  dontShowLabel:SetPoint("LEFT", dontShow, "RIGHT", 2, 0)
  dontShowLabel:SetTextColor(0.6, 0.6, 0.6, 0.8)
  dontShowLabel:SetText("Don't show again")
  dontShow:SetScript("OnClick", function(self)
    if self:GetChecked() then
      local config = CLF_Config or CLF_DefaultConfig
      if config then
        if not config.hud then config.hud = {} end
        config.hud.suppressGlowPopup = true
      end
    end
  end)

  local dismissBtn = CreateFrame("Button", nil, popup)
  dismissBtn:SetSize(80, 20)
  dismissBtn:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -14, 14)
  local dismissText = dismissBtn:CreateFontString(nil, "OVERLAY")
  dismissText:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
  dismissText:SetPoint("CENTER")
  dismissText:SetTextColor(0.5, 0.5, 0.5, 0.8)
  dismissText:SetText("Dismiss")
  dismissBtn:SetScript("OnEnter", function() dismissText:SetTextColor(0.8, 0.8, 0.8, 1) end)
  dismissBtn:SetScript("OnLeave", function() dismissText:SetTextColor(0.5, 0.5, 0.5, 0.8) end)
  dismissBtn:SetScript("OnClick", function()
    popup:Hide()
  end)

  popup:Show()
end

-- ── §C6: Boss Mod Integration (DBM/BigWigs) ──
-- Registers callbacks for alerts from DBM-Core and/or BigWigs.
-- Tracks: interrupt alerts, preemptive defensive timers, boss phase changes.
CLF._bossTimers = {}
CLF._bossPhase = 0
CLF._bossModConnected = false

local INTERRUPT_KEYWORDS = {
  "interrupt", "kick", "cast", "channel", "heal", "bolt", "mend", "repair",
  "shadowbolt", "frostbolt", "firebolt", "chain", "summon",
}

local function ClassifyBossAlert(msg)
  if not msg or type(msg) ~= "string" then return "unknown" end
  local lower = string.lower(msg)
  for _, kw in ipairs(INTERRUPT_KEYWORDS) do
    if string.find(lower, kw, 1, true) then return "interrupt" end
  end
  return "mechanic"
end

function CLF.OnBossModTimer(timerType, spellId, duration, msg)
  local now = GetTime()
  local idStr = tostring(spellId or msg or "unknown")
  local alertClass = ClassifyBossAlert(msg)

  CLF._bossTimers[idStr] = {
    startTime = now,
    duration = duration or 5,
    alertClass = alertClass,
    msg = msg,
  }

  if alertClass == "interrupt" then
    CLF.activeAlerts[idStr] = now
    C_Timer.After(duration or 5, function()
      CLF.activeAlerts[idStr] = nil
      CLF._bossTimers[idStr] = nil
    end)
  else
    C_Timer.After(duration or 5, function()
      CLF._bossTimers[idStr] = nil
    end)
  end
end

function CLF.OnBossModPhase(phase)
  local oldPhase = CLF._bossPhase
  CLF._bossPhase = phase or 0
  CLF.PushWDEvent("BOSS_PHASE", { old = oldPhase, new = phase })
  if CLF.debugEnabled then
    CLF.Log("BOSSMOD", "Phase change: " .. tostring(oldPhase) .. " -> " .. tostring(phase))
  end
end

function CLF.RegisterBossModCallbacks()
  local connected = {}

  if DBM and DBM.RegisterCallback then
    DBM:RegisterCallback("DBM_Announce", function(event, mod, spellId, spellName)
      local idStr = DetaintStr(spellId) or "0"
      CLF.activeAlerts[idStr] = GetTime()
      C_Timer.After(5, function() CLF.activeAlerts[idStr] = nil end)
    end)

    DBM:RegisterCallback("DBM_TimerStart", function(event, id, msg, timer, icon, timerType, spellId)
      CLF.OnBossModTimer(timerType, spellId or id, timer, msg)
    end)

    DBM:RegisterCallback("DBM_TimerStop", function(event, id)
      local idStr = tostring(id or "")
      CLF._bossTimers[idStr] = nil
    end)

    if DBM.RegisterCallback then
      pcall(function()
        DBM:RegisterCallback("DBM_SetStage", function(event, mod, stage)
          CLF.OnBossModPhase(stage)
        end)
      end)
    end

    table.insert(connected, "DBM")
  end

  if BigWigsLoader and BigWigsLoader.RegisterMessage then
    BigWigsLoader.RegisterMessage(frame, "BigWigs_Message", function(_, _, msg, _, _, _, spellId)
      if spellId then
        local idStr = DetaintStr(spellId) or "0"
        CLF.activeAlerts[idStr] = GetTime()
        C_Timer.After(5, function() CLF.activeAlerts[idStr] = nil end)
      end
    end)

    BigWigsLoader.RegisterMessage(frame, "BigWigs_StartBar", function(_, _, _, text, duration, icon, _, _, spellId)
      CLF.OnBossModTimer(nil, spellId or text, duration, text)
    end)

    BigWigsLoader.RegisterMessage(frame, "BigWigs_StopBar", function(_, _, _, text)
      local idStr = tostring(text or "")
      CLF._bossTimers[idStr] = nil
    end)

    pcall(function()
      BigWigsLoader.RegisterMessage(frame, "BigWigs_SetStage", function(_, _, stage)
        CLF.OnBossModPhase(stage)
      end)
    end)

    table.insert(connected, "BigWigs")
  end

  CLF._bossModConnected = #connected > 0
  if #connected > 0 then
    print("|cFFD4A632[DMGAssist]|r Boss mod integration: " .. table.concat(connected, " + "))
  end
end

if C_RestrictedActions then
  local restrictFrame = CreateFrame("Frame")
  restrictFrame:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED")
  restrictFrame:SetScript("OnEvent", function(_, event)
    if event == "ADDON_RESTRICTION_STATE_CHANGED" then
      local states = {}
      if C_RestrictedActions.IsActionRestricted then
        pcall(function()
          states.combat = C_RestrictedActions.IsActionRestricted(Enum.AddOnRestrictionType.Combat) or false
          states.encounter = C_RestrictedActions.IsActionRestricted(Enum.AddOnRestrictionType.InstanceEncounter) or false
          states.challenge = C_RestrictedActions.IsActionRestricted(Enum.AddOnRestrictionType.ChallengeMode) or false
          states.pvp = C_RestrictedActions.IsActionRestricted(Enum.AddOnRestrictionType.PvPMatch) or false
          states.map = C_RestrictedActions.IsActionRestricted(Enum.AddOnRestrictionType.Map) or false
        end)
      end
      CLF.PushWDEvent("RESTRICTION_CHANGE", states)
      if CLF.debugEnabled then
        local parts = {}
        for k, v in pairs(states) do
          if v then table.insert(parts, k) end
        end
        CLF.Log("RESTRICT", "Active: " .. (#parts > 0 and table.concat(parts, ",") or "none"))
      end
    end
  end)
end

-- Slash commands
function CLF.Msg(text)
  print("|cFFD4A632[DMGAssist]|r " .. (text or ""))
end

SLASH_CLF1 = "/dmga"
SLASH_CLF2 = "/dmgassist"
SlashCmdList["CLF"] = function(msg)
  local cmd = string.lower(strtrim(msg))

  if cmd == "show" then
    CLF.ShowHUD()
    print("|cFFD4A632[DMGAssist]|r HUD shown")
  elseif cmd == "hide" then
    CLF.HideHUD()
    print("|cFFD4A632[DMGAssist]|r HUD hidden")
  elseif cmd == "toggle" then
    CLF.ToggleHUD()
  elseif cmd == "reset" then
    CLF.ResetErrors()
    CLF_Config = CLF_DefaultConfig
    CLF_Position = {}
    CLF.SafeReload()
  elseif cmd == "lock" then
    CLF.LockHUD(true)
  elseif cmd == "unlock" then
    CLF.LockHUD(false)
  elseif cmd == "mode" then
    CLF.ToggleModeLock()
  elseif cmd == "mode auto" or cmd == "mode default" then
    CLF._modeLock = nil
    CLF.DetectCombatMode()
    print("|cFFD4A632[DMGAssist]|r Mode: |cFF00FF00" .. CLF.combatMode .. "|r (content default)")
  elseif cmd == "mode st" then
    CLF.LockMode("ST")
  elseif cmd == "mode aoe" then
    CLF.LockMode("AoE")
  elseif cmd == "debug" then
    CLF.debugEnabled = not CLF.debugEnabled
    CLF.debugVerbose = false
    local config = CLF_Config or CLF_DefaultConfig
    if config and config.hud then config.hud.debugMode = CLF.debugEnabled end
    print("|cFFD4A632[DMGAssist]|r Debug mode: " .. (CLF.debugEnabled and "|cFF00FF00ON|r (saved)" or "|cFFFF0000OFF|r (saved)"))
    if CLF.debugEnabled then
      print("|cFFD4A632[DMGAssist]|r   Type |cFFFFD100/dmga debug verbose|r for condition-level detail")
      print("|cFFD4A632[DMGAssist]|r   Type |cFFFFD100/dmga debug off|r to disable")
    end
  elseif cmd == "debug verbose" then
    CLF.debugEnabled = true
    CLF.debugVerbose = true
    local config = CLF_Config or CLF_DefaultConfig
    if config and config.hud then config.hud.debugMode = true end
    print("|cFFD4A632[DMGAssist]|r Debug mode: |cFF00FF00VERBOSE|r -- all evaluation steps logged (saved)")
  elseif cmd == "debug off" then
    CLF.debugEnabled = false
    CLF.debugVerbose = false
    local config = CLF_Config or CLF_DefaultConfig
    if config and config.hud then config.hud.debugMode = false end
    print("|cFFD4A632[DMGAssist]|r Debug mode: |cFFFF0000OFF|r (saved)")
  elseif string.sub(cmd, 1, 9) == "debugbuff" then
    local searchArg = string.sub(cmd, 11)
    if searchArg == "" then searchArg = "mark_of_the_wild" end
    local cleanName = string.gsub(searchArg, "_", " ")
    local lowerClean = string.lower(cleanName)
    print("|cFFD4A632[DMGAssist]|r === Buff Debug: |cFFFFD100" .. cleanName .. "|r ===")

    print("|cFFD4A632[DMGAssist]|r API availability:")
    print("  C_UnitAuras: " .. (C_UnitAuras and "YES" or "NO"))
    if C_UnitAuras then
      print("  .GetBuffDataByIndex: " .. (C_UnitAuras.GetBuffDataByIndex and "YES" or "NO"))
      print("  .GetAuraDataByIndex: " .. (C_UnitAuras.GetAuraDataByIndex and "YES" or "NO"))
      print("  .GetPlayerAuraBySpellID: " .. (C_UnitAuras.GetPlayerAuraBySpellID and "YES" or "NO"))
    end
    print("  AuraUtil: " .. (AuraUtil and "YES" or "NO"))
    if AuraUtil then
      print("  .ForEachAura: " .. (AuraUtil.ForEachAura and "YES" or "NO"))
    end
    print("  C_Spell.GetSpellInfo: " .. (C_Spell and C_Spell.GetSpellInfo and "YES" or "NO"))

    local spellId = nil
    if C_Spell and C_Spell.GetSpellInfo then
      local ok, info = pcall(C_Spell.GetSpellInfo, cleanName)
      if ok and type(info) == "table" then
        spellId = Detaint(info.spellID)
        print("|cFFD4A632[DMGAssist]|r C_Spell.GetSpellInfo('" .. cleanName .. "'):")
        print("  spellID = " .. (spellId and tostring(spellId) or "<tainted>"))
        print("  name = " .. (DetaintStr(info.name) or "<tainted>"))
      else
        print("|cFFD4A632[DMGAssist]|r C_Spell.GetSpellInfo('" .. cleanName .. "'): " .. (ok and "returned non-table" or "FAILED"))
      end
    end

    if spellId and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
      local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellId)
      local auraDesc = "|cFFFF0000ERROR|r"
      if ok then
        if type(aura) == "table" then
          auraDesc = "|cFF00FF00FOUND|r name=" .. (DetaintStr(aura.name) or "<tainted>")
        else
          auraDesc = "nil (not on player)"
        end
      end
      print("|cFFD4A632[DMGAssist]|r GetPlayerAuraBySpellID(" .. tostring(spellId) .. "): " .. auraDesc)
    end

    print("|cFFD4A632[DMGAssist]|r Scanning all player HELPFUL auras:")
    local getter = nil
    local getterName = "none"
    if C_UnitAuras then
      if C_UnitAuras.GetBuffDataByIndex then
        getter = C_UnitAuras.GetBuffDataByIndex
        getterName = "GetBuffDataByIndex"
      elseif C_UnitAuras.GetAuraDataByIndex then
        getter = function(u, i) return C_UnitAuras.GetAuraDataByIndex(u, i, "HELPFUL") end
        getterName = "GetAuraDataByIndex"
      end
    end
    if getter then
      local found = false
      for i = 1, 40 do
        local ok, aura = pcall(getter, "player", i)
        if not ok then
          print("  [" .. i .. "] pcall FAILED: " .. tostring(aura))
          break
        end
        if type(aura) ~= "table" then
          print("  [" .. i .. "] nil (end of list)")
          break
        end
        local n = DetaintStr(aura.name) or "<tainted>"
        local sid = Detaint(aura.spellId) or "<tainted>"
        local secret = issecretvalue and issecretvalue(aura.name) or false
        print("  [" .. i .. "] name=" .. n .. " spellId=" .. tostring(sid) .. " secret=" .. tostring(secret))
        if not secret and n ~= "<tainted>" then
          local lower = string.lower(n)
          if string.find(lower, lowerClean, 1, true) then
            print("    ^^^ |cFF00FF00MATCH for '" .. cleanName .. "'|r")
            found = true
          end
        end
      end
      if not found then
        print("  |cFFFF4444No match found for '" .. cleanName .. "'|r")
      end
    elseif AuraUtil and AuraUtil.ForEachAura then
      print("  Using AuraUtil.ForEachAura fallback")
      local idx = 0
      AuraUtil.ForEachAura("player", "HELPFUL", nil, function(aura)
        idx = idx + 1
        local aName = DetaintStr(aura.name) or "<tainted>"
        local aSid = Detaint(aura.spellId) or "<tainted>"
        print("  [" .. idx .. "] name=" .. aName .. " spellId=" .. tostring(aSid))
      end, true)
      if idx == 0 then print("  (no auras returned)") end
    else
      print("  |cFFFF4444No aura scanning function available!|r")
    end

    print("|cFFD4A632[DMGAssist]|r --- CLF.BuffUp Test ---")
    local buffResult = CLF.BuffUp(searchArg)
    print("|cFFD4A632[DMGAssist]|r CLF.BuffUp('" .. searchArg .. "'): " .. (buffResult and "|cFF00FF00true|r" or "|cFFFF4444false|r"))

    local remains = CLF.BuffRemains(searchArg)
    print("|cFFD4A632[DMGAssist]|r CLF.BuffRemains('" .. searchArg .. "'): " .. tostring(remains))

    print("|cFFD4A632[DMGAssist]|r --- Precombat Condition Test ---")
    local buffIsUp = CLF.BuffUp(searchArg)
    local condResult = not buffIsUp
    print("|cFFD4A632[DMGAssist]|r not CLF.BuffUp('" .. searchArg .. "'): " .. tostring(condResult))
    print("|cFFD4A632[DMGAssist]|r Would queue spell: " .. (condResult and "|cFFFF4444YES (thinks buff missing)|r" or "|cFF00FF00NO (buff detected)|r"))

    print("|cFFD4A632[DMGAssist]|r --- Actual APL Entry Check ---")
    local config = CLF_Config or CLF_DefaultConfig
    if config and config.apl then
      for _, entry in ipairs(config.apl) do
        if entry.isPrecombat and string.find(string.lower(entry.spellName), lowerClean, 1, true) then
          print("|cFFD4A632[DMGAssist]|r Entry: " .. entry.spellName)
          print("  conditionSrc: " .. tostring(entry.conditionSrc))
          print("  conditionFn: " .. (entry.conditionFn and "EXISTS" or "|cFFFF4444NIL|r"))
          if entry.conditionFn then
            local eOk, eResult = pcall(entry.conditionFn)
            print("  conditionFn(): ok=" .. tostring(eOk) .. " result=" .. tostring(eResult))
          end
        end
      end
    end

  elseif cmd == "debugscan" then
    print("|cFFD4A632[DMGAssist]|r === Action Bar Signal Scan ===")

    print("|cFFD4A632[DMGAssist]|r API check:")
    print("  C_SpellHighlight: " .. (C_SpellHighlight and "YES" or "|cFFFF4444NO|r"))
    print("  C_SpellHighlight.GetHighlightType: " .. ((C_SpellHighlight and C_SpellHighlight.GetHighlightType) and "YES" or "|cFFFF4444NO|r"))
    print("  ActionButton_IsOverlayGlowShowing: " .. (ActionButton_IsOverlayGlowShowing and "YES" or "|cFFFF4444NO|r"))

    InitSlotMap()
    local scanCount = 0
    local signalCounts = { ants = 0, assisted = 0, proc = 0, ready = 0, none = 0 }
    for slotID = 1, 180 do
      local rawType, rawId = GetActionInfo(slotID)
      local actionType = DetaintStr(rawType)
      local id = Detaint(rawId)
      if actionType == "spell" and id then
        local spellName = SafeGetSpellName(id)
        if spellName then
          scanCount = scanCount + 1
          local signalStr = "none"
          local hlTypeRaw = nil
          local hlTypeVal = nil
          local glowVal = 0

          if C_SpellHighlight and C_SpellHighlight.GetHighlightType then
            local ok, rawHl = pcall(C_SpellHighlight.GetHighlightType, id)
            if ok then
              hlTypeRaw = tostring(type(rawHl))
              if issecretvalue and issecretvalue(rawHl) then
                hlTypeRaw = "SECRET"
              else
                hlTypeVal = tonumber(rawHl)
              end
            end
          end

          local btnName = SLOT_TO_BUTTON[slotID]
          if btnName then
            local btn = _G[btnName]
            if btn then
              if btn.SpellHighlightTexture then
                local shown = btn.SpellHighlightTexture:IsShown()
                if shown ~= nil then
                  if (issecretvalue and issecretvalue(shown)) or shown then glowVal = 2 end
                end
              end
              if glowVal == 0 and ActionButton_IsOverlayGlowShowing then
                local glowing = ActionButton_IsOverlayGlowShowing(btn)
                if glowing ~= nil then
                  if (issecretvalue and issecretvalue(glowing)) or glowing then glowVal = 1 end
                end
              end
              if glowVal == 0 and btn.SpellActivationAlert then
                local shown2 = btn.SpellActivationAlert:IsShown()
                if shown2 ~= nil then
                  if (issecretvalue and issecretvalue(shown2)) or shown2 then glowVal = 1 end
                end
              end
            end
          end

          if hlTypeVal and hlTypeVal >= 2 then signalStr = "|cFFFF8800ANTS|r"
          elseif hlTypeVal and hlTypeVal >= 1 then signalStr = "|cFFFFFF00ASSISTED|r"
          elseif glowVal == 2 then signalStr = "|cFFFF8800ANTS(glow)|r"
          elseif glowVal == 1 then signalStr = "|cFF00FFFFproc(glow)|r"
          else
            local usable = CLF.IsSpellUsable(spellName)
            if usable then
              local _, _, cdRem = CLF.SpellStatus(spellName)
              if not cdRem or cdRem <= 0 then signalStr = "ready" end
            end
          end

          if hlTypeRaw == "SECRET" or hlTypeVal or glowVal > 0 then
            print(string.format("  [%d] %s: hl=%s/%s glow=%d → %s",
              slotID, spellName,
              tostring(hlTypeRaw), tostring(hlTypeVal),
              glowVal, signalStr))
          end

          if signalStr == "|cFFFF8800ANTS|r" or signalStr == "|cFFFF8800ANTS(glow)|r" then signalCounts.ants = signalCounts.ants + 1
          elseif signalStr == "|cFFFFFF00ASSISTED|r" then signalCounts.assisted = signalCounts.assisted + 1
          elseif signalStr == "|cFF00FFFFproc(glow)|r" then signalCounts.proc = signalCounts.proc + 1
          elseif signalStr == "ready" then signalCounts.ready = signalCounts.ready + 1
          else signalCounts.none = signalCounts.none + 1 end
        end
      end
    end

    print("|cFFD4A632[DMGAssist]|r " .. scanCount .. " spells on bars:")
    print("  |cFFFF8800Ants: " .. signalCounts.ants .. "|r  |cFFFFFF00Assisted: " .. signalCounts.assisted .. "|r  |cFF00FFFFProc: " .. signalCounts.proc .. "|r  Ready: " .. signalCounts.ready .. "  None: " .. signalCounts.none)

    print("|cFFD4A632[DMGAssist]|r --- Health/Defensive Check ---")
    local rawHP = UnitHealth("player")
    local rawHPMax = UnitHealthMax("player")
    print("  UnitHealth raw type: " .. type(rawHP) .. (issecretvalue and issecretvalue(rawHP) and " |cFFFF4444(SECRET)|r" or " (clean)"))
    print("  UnitHealthMax raw type: " .. type(rawHPMax) .. (issecretvalue and issecretvalue(rawHPMax) and " |cFFFF4444(SECRET)|r" or " (clean)"))
    print("  CLF.PlayerHealthPct(): " .. string.format("%.1f", CLF.PlayerHealthPct()) .. "%%")
  elseif cmd == "ooc" then
    local config = CLF_Config or CLF_DefaultConfig
    if not config or not config.hud then print("|cFFD4A632[DMGAssist]|r No config loaded yet"); return end
    config.hud.hideOutOfCombat = not (config.hud.hideOutOfCombat == true)
    local state = (config.hud.hideOutOfCombat == true)
    print("|cFFD4A632[DMGAssist]|r Auto-hide OOC: " .. (state and "|cFF00FF00ON|r -- HUD hides after combat ends" or "|cFFFF0000OFF|r -- HUD stays visible"))
    if state and not DetaintBool(InCombatLockdown(), "InCombatLockdown") then
      CLF._manualShow = false
      CLF.HideHUD()
    elseif not state then
      CLF.ShowHUD()
    end
  elseif cmd == "glows" then
    CLF.CheckGlowSettings()
  elseif cmd == "fixglows" then
    CLF.FixGlowSettings()
  elseif cmd == "status" then
    local config = CLF_Config or CLF_DefaultConfig
    local hud = (config and config.hud) or {}
    local spec = (config and config.spec) or {}
    print("|cFFD4A632[DMGAssist]|r --- Status ---")
    print("|cFFD4A632[DMGAssist]|r Spec: " .. (spec.specName or "Unknown") .. " " .. (spec.className or "Unknown"))
    print("|cFFD4A632[DMGAssist]|r APL entries: " .. #(config and config.apl or {}))
    print("|cFFD4A632[DMGAssist]|r Interrupts: " .. #(config and config.interrupts or {}))
    print("|cFFD4A632[DMGAssist]|r Mode: " .. (CLF.combatMode or "AoE") .. (CLF._modeLock and " (OVERRIDE)" or " (default)"))
    print("|cFFD4A632[DMGAssist]|r AoE threshold: " .. ((hud and hud.aoeThreshold) or 3) .. " enemies")
    print("|cFFD4A632[DMGAssist]|r Icon size: " .. (hud.iconSize or 48) .. " / Next: " .. (hud.predIconSize or 34))
    print("|cFFD4A632[DMGAssist]|r Queue slots: " .. (hud.queueSlots or 3))
    print("|cFFD4A632[DMGAssist]|r Glow detection: " .. (CLF.glowSettingsOk and "|cFF00FF00OK|r" or "|cFFFF0000DEGRADED|r -- type /dmga fixglows"))
    print("|cFFD4A632[DMGAssist]|r Debug: " .. (CLF.debugEnabled and (CLF.debugVerbose and "|cFF00FF00VERBOSE|r" or "|cFF00FF00ON|r") or "OFF"))
    print("|cFFD4A632[DMGAssist]|r OOC mode: " .. (hud.outOfCombatMode and "|cFF00FF00ON|r" or "OFF"))
    print("|cFFD4A632[DMGAssist]|r CD text: " .. (hud.showCooldownText and "ON" or "OFF"))
    print("|cFFD4A632[DMGAssist]|r GCD spark: " .. (hud.showGcdSpark and "ON" or "OFF"))
    print("|cFFD4A632[DMGAssist]|r Interrupt sound: " .. (hud.interruptSound and "|cFF00FF00ON|r" or "OFF"))
    print("|cFFD4A632[DMGAssist]|r DBM: " .. ((DBM and DBM.RegisterCallback) and "|cFF00FF00Connected|r" or "|cFF888888Not installed|r"))
    print("|cFFD4A632[DMGAssist]|r BigWigs: " .. ((BigWigsLoader and BigWigsLoader.RegisterMessage) and "|cFF00FF00Connected|r" or "|cFF888888Not installed|r"))
    print("|cFFD4A632[DMGAssist]|r Form: " .. CLF.CurrentForm())
    print("|cFFD4A632[DMGAssist]|r Tick rate: " .. (isInCombat and "20 Hz (combat)" or "4 Hz (OOC)"))
  elseif cmd == "spells" then
    local config = CLF_Config or CLF_DefaultConfig
    if not config then print("|cFFD4A632[DMGAssist]|r No config loaded yet"); return end
    print("|cFFD4A632[DMGAssist]|r --- Spell Check ---")
    local known, unknown = 0, 0
    for _, entry in ipairs(config.apl or {}) do
      local isKnown = CLF.IsSpellKnown(entry.spellName, entry.spellId)
      if isKnown then
        known = known + 1
        print(string.format("  |cFF00FF00✓|r [%d] %s", entry.priority, entry.spellName))
      else
        unknown = unknown + 1
        print(string.format("  |cFFFF0000✗|r [%d] %s -- |cFF888888not learned/talented|r", entry.priority, entry.spellName))
      end
    end
    print(string.format("|cFFD4A632[DMGAssist]|r %d known, %d filtered out", known, unknown))
  elseif cmd == "trinkets" or cmd == "trinket" then
    print("|cFFD4A632[DMGAssist]|r Equipped Trinkets:")
    if not CLF._trinketScanDone then
      CLF.ScanEquippedTrinkets()
    end
    local found = false
    for _, t in pairs(CLF._trinkets) do
      found = true
      local cdRemaining, ready = CLF.GetTrinketCooldown(t.slotName)
      local status = ""
      if t.hasUse then
        status = ready and "|cFF00FF00READY|r" or ("|cFFFF6600CD: " .. string.format("%.1f", cdRemaining) .. "s|r")
      else
        status = "|cFF888888Passive|r"
      end
      print("  " .. t.slotName .. ": |cFFFFD100" .. (t.itemName or "Unknown") .. "|r -- " .. status)
      if t.hasUse then
        print("    On-Use: " .. (t.spellName or "Unknown"))
      end
    end
    if not found then
      print("  No trinkets detected. Equip trinkets and type |cFFFFD100/dmga trinkets|r")
    end
    if CLF._trinketPriority then
      print("  SimC priority: trinket1=" .. (CLF._trinketPriority["trinket1"] or "?") .. ", trinket2=" .. (CLF._trinketPriority["trinket2"] or "?"))
    end
  elseif cmd == "testinterrupt" then
    if CLF._testInterruptActive then return end
    local testSpellId = "999999"
    local duration = 5
    local routed = false

    local config = CLF_Config or CLF_DefaultConfig
    local firstInterruptSpell = nil
    local fAPL = CLF._filteredAPL or {}
    if fAPL.interrupts then
      for _, entry in ipairs(fAPL.interrupts) do
        if entry.spellName then
          firstInterruptSpell = entry.spellName
          break
        end
      end
    end
    if not firstInterruptSpell then
      local interrupts = config and config.interrupts or {}
      if #interrupts > 0 then
        firstInterruptSpell = interrupts[1].interruptSpell
      end
    end
    if not firstInterruptSpell and CLF._classInterruptMap then
      local _, playerClass = UnitClass("player")
      local classEntry = playerClass and CLF._classInterruptMap[playerClass]
      if classEntry then
        firstInterruptSpell = classEntry.spell
      end
    end

    CLF._testInterruptActive = true
    CLF._testInterruptSpell = firstInterruptSpell

    CLF.activeAlerts[testSpellId] = GetTime()

    local hasDBM = DBM and DBM.RegisterCallback
    local hasBW = BigWigsLoader and BigWigsLoader.RegisterMessage

    if hasDBM and DBM.callbacks and DBM.callbacks.Fire then
      pcall(function() DBM.callbacks:Fire("DBM_Announce", nil, testSpellId, "Test Boss Cast") end)
      CLF.Msg("Also routed test through |cFFFFD100DBM|r callback pipeline")
      routed = true
    elseif hasBW and BigWigsLoader.SendMessage then
      pcall(function() BigWigsLoader:SendMessage("BigWigs_Message", nil, "Test Boss Cast", nil, nil, nil, tonumber(testSpellId)) end)
      CLF.Msg("Also routed test through |cFFFFD100BigWigs|r callback pipeline")
      routed = true
    end

    if CLF_MainFrame and not CLF_MainFrame:IsShown() then CLF_MainFrame:Show() end

    C_Timer.After(duration, function()
      CLF._testInterruptActive = false
      CLF._testInterruptSpell = nil
      CLF.activeAlerts[testSpellId] = nil
      CLF.Msg("Test interrupt expired, queue restored to normal")
    end)
    if firstInterruptSpell then
      CLF.Msg("|cFF00FF00Test interrupt active for " .. duration .. "s!|r " .. firstInterruptSpell .. " should jump to slot 1 with a red border.")
    else
      CLF.Msg("|cFF00FF00Test interrupt active for " .. duration .. "s!|r Any interrupt spell should jump to slot 1 with a red border.")
    end
    CLF.Msg("Boss mods: DBM=" .. (hasDBM and "|cFF00FF00Installed|r" or "|cFF888888Not found|r") .. "  BigWigs=" .. (hasBW and "|cFF00FF00Installed|r" or "|cFF888888Not found|r"))
  elseif cmd == "consumables" or cmd == "cons" or cmd == "buffs" then
    CLF.Msg("|cFFFFD100=== Consumable Status ===|r")
    local config = CLF_Config or CLF_DefaultConfig
    local h = config and config.hud or {}
    if not h.consumablesEnabled then
      CLF.Msg("  Consumable tracking: |cFFFF0000DISABLED|r")
    else
      local catNames = { flask = "Flask/Phial", food = "Food", weaponEnh = "Weapon Enhancement", augmentRune = "Augment Rune" }
      local enableKeys = { flask = "flaskEnabled", food = "foodEnabled", weaponEnh = "weaponEnhEnabled", augmentRune = "augmentRuneEnabled" }
      for _, key in ipairs({"flask", "food", "weaponEnh", "augmentRune"}) do
        local label = catNames[key]
        if not h[enableKeys[key]] then
          CLF.Msg("  " .. label .. ": |cFF888888disabled|r")
        else
          local cData = CLF._consumables[key]
          if not cData then
            CLF.Msg("  " .. label .. ": |cFFFF6600no item selected|r")
          else
            local buffStr = cData.buffActive and "|cFF00FF00ACTIVE" or "|cFFFF4444MISSING"
            if cData.buffActive and cData.buffExpiry > 0 then
              local rem = cData.buffExpiry - GetTime()
              local mins = math.floor(rem / 60)
              buffStr = buffStr .. " (" .. mins .. "m)"
            end
            buffStr = buffStr .. "|r"
            CLF.Msg("  " .. label .. ": |cFFD4A632" .. cData.itemName .. "|r - " .. buffStr .. " (x" .. cData.count .. ")")
          end
        end
      end
    end
  elseif cmd == "spellbook" or cmd == "sb" then
    local G = "|cFF00FF00"
    local Y = "|cFFFFD100"
    local W = "|cFFFFFFFF"
    local D = "|cFF888888"
    local E = "|r"
    print("|cFFD4A632[DMGAssist] === SPELL BOOK ===|r")
    local ss = CLF._statsSnapshot or {}
    print(Y .. "Stats:|r Haste=" .. string.format("%.1f%%", ss.haste or 0) .. " Crit=" .. string.format("%.1f%%", ss.crit or 0) .. " Mastery=" .. string.format("%.1f%%", ss.mastery or 0) .. " Vers=" .. string.format("%.1f%%", ss.versatility or 0))
    print(Y .. "GCD:|r " .. string.format("%.2fs", ss.gcdHasted or 1.5) .. " (base " .. string.format("%.1fs", ss.gcdBase or 1.5) .. ")")
    print(Y .. "Snapshot Age:|r " .. ((ss.snapshotTime and ss.snapshotTime > 0) and string.format("%.0fs ago", GetTime() - ss.snapshotTime) or "never"))
    local count = 0
    local sorted = {}
    for k, v in pairs(CLF._spellBook) do
      table.insert(sorted, v)
      count = count + 1
    end
    table.sort(sorted, function(a, b) return (a.name or "") < (b.name or "") end)
    print(Y .. "Spells:|r " .. count .. " tracked")
    for _, entry in ipairs(sorted) do
      local parts = {}
      if entry.hastedCastTime and entry.hastedCastTime > 0 then
        table.insert(parts, "cast=" .. string.format("%.2fs", entry.hastedCastTime))
      end
      if entry.cdDuration and entry.cdDuration > 1.5 then
        local cdStr = string.format("%.0fs", entry.cdDuration)
        if entry.cdReadyAt and entry.cdReadyAt > GetTime() then
          cdStr = cdStr .. " (ready in " .. string.format("%.0fs", entry.cdReadyAt - GetTime()) .. ")"
        end
        table.insert(parts, "CD=" .. cdStr)
      end
      if entry.maxCharges and entry.maxCharges > 1 then
        table.insert(parts, "charges=" .. (entry.currentCharges or 0) .. "/" .. entry.maxCharges)
      end
      if entry.cost and entry.cost > 0 then
        table.insert(parts, "cost=" .. entry.cost)
      end
      local obs = CLF._castObservations[entry.cleanName]
      if obs and obs.count >= 3 then
        table.insert(parts, D .. "observed=" .. string.format("%.2fs", obs.avgTime) .. " (n=" .. obs.count .. ")" .. E)
      end
      local detail = #parts > 0 and ("  " .. table.concat(parts, "  ")) or ""
      local nameColor = entry.isKnown and G or D
      print("  " .. nameColor .. (entry.name or entry.cleanName) .. E .. detail)
    end

  elseif cmd == "snapshot" or cmd == "snap" then
    local s = CLF._lastSnapshot
    if not s then
      print("|cFFD4A632[DMGAssist]|r No snapshot yet -- wait for at least one evaluation tick.")
    else
      local G = "|cFF00FF00"
      local Y = "|cFFFFD100"
      local R = "|cFFFF4444"
      local W = "|cFFFFFFFF"
      local E = "|r"
      print("|cFFD4A632[DMGAssist] === LAST TICK SNAPSHOT ===|r")
      print(Y .. "Time:|r " .. string.format("%.1f", s.time % 1000) .. "  " .. Y .. "Mode:|r " .. (s.mode or "?") .. "  " .. Y .. "Enemies:|r " .. (s.enemies or 0))
      print(Y .. "Combat:|r " .. (s.inCombat and (G .. "YES" .. E) or (R .. "NO" .. E)) .. "  " .. Y .. "Health:|r " .. string.format("%.0f%%", (s.health or 0) * 100) .. "  " .. Y .. "Power:|r " .. (s.power or 0) .. "/" .. (s.powerMax or 0))
      print(Y .. "Form:|r " .. (s.form or "caster") .. "  " .. Y .. "Stuck:|r " .. (s.stuckSpell and (R .. s.stuckSpell .. " x" .. (s.stuckCount or 0) .. E) or (G .. "none" .. E)))
      print(Y .. "--- Queue (what you see) ---" .. E)
      if s.queue and #s.queue > 0 then
        for i, q in ipairs(s.queue) do
          local flags = {}
          if q.isInterrupt then table.insert(flags, R .. "INTERRUPT" .. E) end
          if q.isPrecombat then table.insert(flags, Y .. "PRECOMBAT" .. E) end
          local flagStr = #flags > 0 and (" [" .. table.concat(flags, ",") .. "]") or ""
          print(string.format("  %d: %s%s%s  signal=%s  prio=%d  cd=%.1f%s",
            i, W, q.spell, E, q.signal, q.priority, q.cdRemaining or 0, flagStr))
        end
      else
        print("  (empty)")
      end
      print(Y .. "--- Candidates (all scored spells) ---" .. E)
      if s.candidates and #s.candidates > 0 then
        for i, c in ipairs(s.candidates) do
          print(string.format("  %d: %s%s%s  signal=%s  score=%d  range=%s",
            i, W, c.spell, E, c.signal, c.score, c.inRange and "yes" or "no"))
        end
      else
        print("  (none)")
      end
      local ts = CLF._taintStats
      local taintEntries = {}
      for k, v in pairs(ts) do
        if v > 0 then table.insert(taintEntries, k .. "=" .. v) end
      end
      if #taintEntries > 0 then
        print(R .. "--- Taint Hits (APIs returning secret values) ---" .. E)
        for _, te in ipairs(taintEntries) do
          print("  " .. R .. te .. E)
        end
      end
      local ce = CLF._conditionErrors
      local hasCondErr = false
      for k, v in pairs(ce) do
        if not hasCondErr then
          print(R .. "--- Condition Errors ---" .. E)
          hasCondErr = true
        end
        print(string.format("  %s: %dx -- %s", k, v.count, v.lastErr))
      end
    end

  elseif cmd == "selftest" then
    local G = "|cFF00FF00"
    local R = "|cFFFF4444"
    local Y = "|cFFFFD100"
    local E = "|r"
    print("|cFFD4A632[DMGAssist] === SUBSYSTEM SELF-TEST ===|r")
    local pass = 0
    local fail = 0
    local warn = 0

    local function ok(name) pass = pass + 1 print("  " .. G .. "PASS" .. E .. " " .. name) end
    local function bad(name, reason) fail = fail + 1 print("  " .. R .. "FAIL" .. E .. " " .. name .. " -- " .. reason) end
    local function caution(name, reason) warn = warn + 1 print("  " .. Y .. "WARN" .. E .. " " .. name .. " -- " .. reason) end

    if CLF_Config or CLF_DefaultConfig then ok("Config loaded") else bad("Config loaded", "No config found") end
    local cfg = CLF_Config or CLF_DefaultConfig
    if cfg and cfg.spec and cfg.spec.className then ok("Spec detected: " .. cfg.spec.className .. " " .. (cfg.spec.specName or "?")) else bad("Spec detection", "Missing className") end

    if CLF._filteredAPL then
      local count = 0
      if CLF._filteredAPL.rotation then count = count + #CLF._filteredAPL.rotation end
      if CLF._filteredAPL.precombatState then count = count + #CLF._filteredAPL.precombatState end
      if count > 0 then ok("Filtered APL: " .. count .. " entries") else caution("Filtered APL", "0 entries -- no spells in rotation") end
    else
      bad("Filtered APL", "Not built yet -- try entering combat first")
    end

    if C_UnitAuras then ok("C_UnitAuras API available") else bad("C_UnitAuras", "Not available -- aura scanning broken") end
    if C_Spell then ok("C_Spell API available") else bad("C_Spell", "Not available -- spell queries broken") end
    if C_SpellBook then ok("C_SpellBook API available") else caution("C_SpellBook", "Not available -- using legacy fallbacks") end
    if GetShapeshiftForm then ok("GetShapeshiftForm available") else caution("GetShapeshiftForm", "Not available -- form detection uses buff scan only") end
    if issecretvalue then ok("issecretvalue() available") else bad("issecretvalue()", "Not available -- Detaint cannot check taint status") end

    local formResult = CLF.CurrentForm and CLF.CurrentForm()
    if formResult then ok("Form detection: " .. formResult) else caution("Form detection", "returned nil") end

    local testBuff = CLF.BuffUp and CLF.BuffUp("test_nonexistent_buff_12345")
    if testBuff == false or testBuff == nil then ok("Aura scan: not crashing") else caution("Aura scan", "unexpected result for missing buff") end

    local barFound = 0
    for i = 1, 12 do
      if _G["ActionButton" .. i] then barFound = barFound + 1 end
    end
    if barFound >= 10 then ok("Action bars: " .. barFound .. "/12 buttons found") else caution("Action bars", barFound .. "/12 buttons found -- some scanning may miss spells") end

    local knownCount = 0
    local missingCount = 0
    if CLF._filteredAPL and CLF._filteredAPL.rotation then
      for _, e in ipairs(CLF._filteredAPL.rotation) do
        if CLF.IsSpellKnown(e.spellName) then knownCount = knownCount + 1 else missingCount = missingCount + 1 end
      end
      if knownCount > 0 then ok("Known spells: " .. knownCount .. " known, " .. missingCount .. " filtered out") else bad("Known spells", "0 rotation spells are known -- wrong spec?") end
    end

    local ts = CLF._taintStats
    local taintTotal = 0
    for _, v in pairs(ts) do taintTotal = taintTotal + v end
    if taintTotal == 0 then ok("Taint: 0 secret values detected") else
      caution("Taint: " .. taintTotal .. " secret value hits", "")
      for k, v in pairs(ts) do
        if v > 0 then print("      " .. Y .. k .. " = " .. v .. E) end
      end
    end

    local ce = CLF._conditionErrors
    local condErrCount = 0
    for _, v in pairs(ce) do condErrCount = condErrCount + v.count end
    if condErrCount == 0 then ok("Conditions: 0 errors") else
      bad("Conditions: " .. condErrCount .. " errors", "")
      for k, v in pairs(ce) do
        print("      " .. R .. k .. ": " .. v.count .. "x -- " .. v.lastErr .. E)
      end
    end

    if CLF._runtimeDegraded then bad("Runtime", "DEGRADED MODE -- too many errors") else ok("Runtime: normal mode") end

    print("|cFFD4A632[DMGAssist]|r Self-test: " .. G .. pass .. " passed" .. E .. ", " .. R .. fail .. " failed" .. E .. ", " .. Y .. warn .. " warnings" .. E)

  elseif cmd == "taintreset" then
    wipe(CLF._taintStats)
    wipe(CLF._taintStreak)
    wipe(CLF._taintBackoff)
    wipe(CLF._taintLastRetry)
    wipe(CLF._taintCalls)
    wipe(CLF._taintFallbacks)
    CLF._taintCombatStats = nil
    print("|cFFD4A632[DMGAssist]|r Taint counters + adaptive backoff reset.")

  elseif cmd == "taintstats" then
    print("|cFFD4A632[DMGAssist]|r === Taint Statistics ===")
    local report = CLF.GetTaintReport()
    if #report == 0 then
      print("  No taint data recorded yet. Enter combat to start tracking.")
    else
      for _, line in ipairs(report) do
        print("  " .. line)
      end
    end
    local combatSummary = CLF.GetCombatTaintSummary()
    print("  Last combat summary: " .. combatSummary)

  elseif cmd == "taintmap" then
    print("|cFFD4A632[DMGAssist]|r |cFF44AAFF=== TAINT MAP SCAN ===|r")
    local inCombat = DetaintBool(InCombatLockdown(), "InCombatLockdown")
    if not inCombat then
      print("|cFFD4A632[DMGAssist]|r |cFFFFAA00WARNING:|r Not in combat. All APIs will likely read clean.")
      print("  For accurate results, enter combat first then type /dmga taintmap")
    end
    local results = {}
    local function Probe(category, testFn)
      local ok, val = pcall(testFn)
      local status = "ERROR"
      if ok then
        if val == nil then
          status = "NIL"
        elseif issecretvalue and issecretvalue(val) then
          status = "SECRET"
        else
          status = "CLEAN"
        end
      end
      tableInsert(results, { api = category, status = status })
      local color = status == "CLEAN" and "|cFF00CC00" or (status == "SECRET" and "|cFFFF4444" or "|cFFFFAA00")
      print("  " .. color .. status .. "|r  " .. category)
    end

    Probe("UnitHealth", function() return UnitHealth("player") end)
    Probe("UnitHealthMax", function() return UnitHealthMax("player") end)
    Probe("UnitPower", function() return UnitPower("player") end)
    Probe("UnitPowerMax", function() return UnitPowerMax("player") end)
    Probe("UnitPowerType", function() return UnitPowerType("player") end)
    Probe("InCombatLockdown", function() return DetaintBool(InCombatLockdown(), "TaintMap_ICL") and "yes" or "no" end)
    Probe("GetTime", function() return GetTime() end)
    Probe("GetSpecialization", function() return GetSpecialization() end)
    Probe("UnitLevel", function() return UnitLevel("player") end)
    Probe("UnitExists_target", function() return UnitExists("target") end)
    Probe("UnitCanAttack_target", function() return UnitCanAttack("player", "target") end)
    Probe("UnitAffectingCombat", function() return UnitAffectingCombat("player") end)
    Probe("GetShapeshiftForm", function() if GetShapeshiftForm then return GetShapeshiftForm() end return nil end)
    Probe("IsPlayerSpell(61304)", function() return IsPlayerSpell(61304) end)
    Probe("C_Spell.GetSpellName(61304)", function() return C_Spell and C_Spell.GetSpellName(61304) end)
    Probe("C_Spell.GetSpellInfo(61304)", function()
      if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(61304)
        return info and info.spellID or nil
      end
      return nil
    end)
    Probe("C_Spell.GetSpellCooldown(61304)", function()
      if C_Spell and C_Spell.GetSpellCooldown then
        local cd = C_Spell.GetSpellCooldown(61304)
        return cd and cd.startTime or nil
      end
      return nil
    end)
    Probe("C_Spell.GetSpellCooldown.duration(61304)", function()
      if C_Spell and C_Spell.GetSpellCooldown then
        local cd = C_Spell.GetSpellCooldown(61304)
        return cd and cd.duration or nil
      end
      return nil
    end)
    Probe("C_Spell.IsSpellUsable(61304)", function()
      if C_Spell and C_Spell.IsSpellUsable then
        return C_Spell.IsSpellUsable(61304)
      end
      return nil
    end)
    Probe("C_Spell.GetSpellCharges(61304)", function()
      if C_Spell and C_Spell.GetSpellCharges then
        local info = C_Spell.GetSpellCharges(61304)
        return info and info.currentCharges or nil
      end
      return nil
    end)
    Probe("C_SpellHighlight.GetHighlightType(61304)", function()
      if C_SpellHighlight and C_SpellHighlight.GetHighlightType then
        return C_SpellHighlight.GetHighlightType(61304)
      end
      return nil
    end)
    Probe("C_UnitAuras.GetBuffDataByIndex(1)", function()
      if C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
        local a = C_UnitAuras.GetBuffDataByIndex("player", 1)
        return a and a.name or nil
      end
      return nil
    end)
    Probe("GetActionInfo(1)", function() return GetActionInfo(1) end)
    Probe("GetActionCooldown(1)", function()
      if GetActionCooldown then return GetActionCooldown(1) end
      return nil
    end)
    Probe("GetActionTexture(1)", function()
      if GetActionTexture then return GetActionTexture(1) end
      return nil
    end)
    Probe("HasAction(1)", function()
      if HasAction then return HasAction(1) end
      return nil
    end)
    Probe("C_NamePlate.GetNamePlates", function()
      if C_NamePlate and C_NamePlate.GetNamePlates then
        local p = C_NamePlate.GetNamePlates()
        return p and #p or 0
      end
      return nil
    end)
    Probe("GetNumGroupMembers", function() return GetNumGroupMembers() end)
    Probe("IsInGroup", function() return IsInGroup() end)
    Probe("GetInstanceInfo", function() return GetInstanceInfo() end)
    Probe("GetCVar(SpellOverlay)", function()
      if GetCVar then return GetCVar("SpellActivationOverlayOpacity") end
      return nil
    end)
    Probe("C_SpellBook.IsSpellKnown(61304)", function()
      if C_SpellBook and C_SpellBook.IsSpellKnown then
        return C_SpellBook.IsSpellKnown(61304)
      end
      return nil
    end)
    Probe("GetInventoryItemLink(13)", function()
      if GetInventoryItemLink then return GetInventoryItemLink("player", 13) end
      return nil
    end)
    Probe("GetItemCooldown_trinket13", function()
      if GetInventoryItemCooldown then
        local s, d = GetInventoryItemCooldown("player", 13)
        return s
      end
      return nil
    end)

    print("|cFFD4A632[DMGAssist]|r |cFF44AAFF--- Aura/Buff Reading ---")
    Probe("C_UnitAuras.GetBuffDataByIndex.name", function()
      if C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
        local a = C_UnitAuras.GetBuffDataByIndex("player", 1)
        return a and a.name or nil
      end
      return nil
    end)
    Probe("C_UnitAuras.GetBuffDataByIndex.duration", function()
      if C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
        local a = C_UnitAuras.GetBuffDataByIndex("player", 1)
        return a and a.duration or nil
      end
      return nil
    end)
    Probe("C_UnitAuras.GetBuffDataByIndex.expirationTime", function()
      if C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
        local a = C_UnitAuras.GetBuffDataByIndex("player", 1)
        return a and a.expirationTime or nil
      end
      return nil
    end)
    Probe("C_UnitAuras.GetBuffDataByIndex.applications", function()
      if C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
        local a = C_UnitAuras.GetBuffDataByIndex("player", 1)
        return a and a.applications or nil
      end
      return nil
    end)
    Probe("C_UnitAuras.GetPlayerAuraBySpellID(exists)", function()
      if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        return "api_exists"
      end
      return nil
    end)
    Probe("AuraUtil.FindByName(exists)", function()
      local au = AuraUtil
      if au and au["FindAuraByName"] then
        return "api_exists"
      end
      return nil
    end)

    print("|cFFD4A632[DMGAssist]|r |cFF44AAFF--- Spell Cost / Power Info ---")
    Probe("C_Spell.GetSpellPowerCost(61304)", function()
      if C_Spell and C_Spell.GetSpellPowerCost then
        local costs = C_Spell.GetSpellPowerCost(61304)
        if costs and costs[1] then
          return costs[1].cost
        end
        return "no_cost_data"
      end
      return nil
    end)
    Probe("GetSpellPowerCost(61304)", function()
      if GetSpellPowerCost then
        return GetSpellPowerCost(61304)
      end
      return nil
    end)
    Probe("C_Spell.GetSpellDescription(61304)", function()
      if C_Spell and C_Spell.GetSpellDescription then
        local desc = C_Spell.GetSpellDescription(61304)
        return desc and "has_desc" or nil
      end
      return nil
    end)

    print("|cFFD4A632[DMGAssist]|r |cFF44AAFF--- Target/Enemy Info ---")
    Probe("UnitHealth_target", function() return UnitHealth("target") end)
    Probe("UnitHealthMax_target", function() return UnitHealthMax("target") end)
    Probe("UnitCastingInfo_target", function()
      if UnitCastingInfo then return UnitCastingInfo("target") end
      return nil
    end)
    Probe("UnitChannelInfo_target", function()
      if UnitChannelInfo then return UnitChannelInfo("target") end
      return nil
    end)
    Probe("UnitIsDead_target", function() return UnitIsDead("target") end)
    Probe("UnitClassification_target", function()
      if UnitClassification then return UnitClassification("target") end
      return nil
    end)

    print("|cFFD4A632[DMGAssist]|r |cFF44AAFF--- Talent / Spec Data ---")
    Probe("C_ClassTalents.GetActiveConfigID", function()
      if C_ClassTalents and C_ClassTalents.GetActiveConfigID then
        return C_ClassTalents.GetActiveConfigID()
      end
      return nil
    end)
    Probe("C_Traits.GetConfigInfo", function()
      if C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits and C_Traits.GetConfigInfo then
        local configID = C_ClassTalents.GetActiveConfigID()
        if configID then
          local info = C_Traits.GetConfigInfo(configID)
          return info and "has_config" or nil
        end
      end
      return nil
    end)

    print("|cFFD4A632[DMGAssist]|r |cFF44AAFF--- GCD / Haste ---")
    Probe("GetHaste", function()
      if GetHaste then return GetHaste() end
      return nil
    end)
    Probe("UnitSpellHaste", function()
      if UnitSpellHaste then return UnitSpellHaste("player") end
      return nil
    end)
    Probe("GetCombatRating(CR_HASTE_MELEE=18)", function()
      if GetCombatRating then return GetCombatRating(18) end
      return nil
    end)
    Probe("UnitAttackSpeed", function()
      if UnitAttackSpeed then return UnitAttackSpeed("player") end
      return nil
    end)
    Probe("GetGCD(61304)", function()
      if C_Spell and C_Spell.GetSpellCooldown then
        local cd = C_Spell.GetSpellCooldown(61304)
        return cd and cd.duration or nil
      end
      return nil
    end)

    print("|cFFD4A632[DMGAssist]|r |cFF44AAFF--- Combat Log Access ---")
    Probe("CombatLogGetCurrentEventInfo", function()
      if CombatLogGetCurrentEventInfo then
        return "api_exists"
      end
      return nil
    end)

    print("|cFFD4A632[DMGAssist]|r |cFF44AAFF--- Action Bar Button Glows ---")
    local testSlot = nil
    for _, s in pairs(CLF._spellSlots or {}) do testSlot = s break end
    if testSlot then
      local btnName = SLOT_TO_BUTTON and SLOT_TO_BUTTON[testSlot]
      if btnName then
        local btn = _G[btnName]
        if btn then
          Probe("ButtonGlow:SpellHighlightTexture:IsShown", function()
            if btn.SpellHighlightTexture then
              return btn.SpellHighlightTexture:IsShown()
            end
            return nil
          end)
          Probe("ActionButton_IsOverlayGlowShowing", function()
            if ActionButton_IsOverlayGlowShowing then
              return ActionButton_IsOverlayGlowShowing(btn)
            end
            return nil
          end)
          Probe("ButtonGlow:SpellActivationAlert:IsShown", function()
            if btn.SpellActivationAlert then
              return btn.SpellActivationAlert:IsShown()
            end
            return nil
          end)
        end
      end
    end

    if CLF._filteredAPL and CLF._filteredAPL.rotation then
      print("|cFFD4A632[DMGAssist]|r |cFF44AAFF--- Your APL Spells (per-spell) ---")
      local tested = 0
      for _, e in ipairs(CLF._filteredAPL.rotation) do
        if tested >= 15 then break end
        if e.spellName and e.spellId then
          tested = tested + 1
          local sid = e.spellId
          local sn = e.spellName
          Probe("GetSpellCD:" .. sn, function()
            if C_Spell and C_Spell.GetSpellCooldown then
              local cd = C_Spell.GetSpellCooldown(sid)
              return cd and cd.startTime or nil
            end
            return nil
          end)
          Probe("IsUsable:" .. sn, function()
            if C_Spell and C_Spell.IsSpellUsable then
              return C_Spell.IsSpellUsable(sid)
            end
            return nil
          end)
          Probe("Highlight:" .. sn, function()
            if C_SpellHighlight and C_SpellHighlight.GetHighlightType then
              return C_SpellHighlight.GetHighlightType(sid)
            end
            return nil
          end)
          Probe("SpellCost:" .. sn, function()
            if C_Spell and C_Spell.GetSpellPowerCost then
              local costs = C_Spell.GetSpellPowerCost(sid)
              if costs and costs[1] then return costs[1].cost end
              return "no_cost"
            end
            return nil
          end)
          Probe("Charges:" .. sn, function()
            if C_Spell and C_Spell.GetSpellCharges then
              local info = C_Spell.GetSpellCharges(sid)
              return info and info.currentCharges or "no_charges"
            end
            return nil
          end)
        end
      end
    end

    local clean, secret, nil_, err_ = 0, 0, 0, 0
    for _, r in ipairs(results) do
      if r.status == "CLEAN" then clean = clean + 1
      elseif r.status == "SECRET" then secret = secret + 1
      elseif r.status == "NIL" then nil_ = nil_ + 1
      else err_ = err_ + 1 end
    end
    print("|cFFD4A632[DMGAssist]|r |cFF44AAFF=== TAINT MAP COMPLETE ===|r")
    print("  |cFF00CC00CLEAN:|r " .. clean .. "  |cFFFF4444SECRET:|r " .. secret .. "  |cFFFFAA00NIL:|r " .. nil_ .. "  |cFF888888ERROR:|r " .. err_)

    local secretAPIs = {}
    for _, r in ipairs(results) do
      if r.status == "SECRET" then tableInsert(secretAPIs, r.api) end
    end
    if #secretAPIs > 0 then
      print("|cFFD4A632[DMGAssist]|r |cFFFF8800SECRET APIs that need internal tracking:|r")
      for _, api in ipairs(secretAPIs) do
        print("  |cFFFF4444>|r " .. api)
      end
      print("")
      print("|cFFD4A632[DMGAssist]|r |cFF44AAFFRecommendations based on results:|r")
      local needsInternalCD, needsInternalUsable, needsInternalAura = false, false, false
      local needsInternalHP, needsInternalPower, needsInternalCost = false, false, false
      for _, api in ipairs(secretAPIs) do
        if string.find(api, "SpellCooldown") or string.find(api, "GetSpellCD") or string.find(api, "ActionCooldown") then needsInternalCD = true end
        if string.find(api, "IsSpellUsable") or string.find(api, "IsUsable") then needsInternalUsable = true end
        if string.find(api, "UnitAuras") or string.find(api, "Aura") or string.find(api, "Buff") then needsInternalAura = true end
        if string.find(api, "UnitHealth") then needsInternalHP = true end
        if string.find(api, "UnitPower") then needsInternalPower = true end
        if string.find(api, "SpellCost") or string.find(api, "PowerCost") then needsInternalCost = true end
      end
      if needsInternalCD then print("  |cFFFFD100CD Tracking:|r Bake spell CD durations into addon config. Track via UNIT_SPELLCAST_SUCCEEDED.") end
      if needsInternalUsable then print("  |cFFFFD100Usability:|r Bake spell costs into addon. Resource-math during combat (power >= cost).") end
      if needsInternalAura then print("  |cFFFFD100Buff Tracking:|r Bake deterministic buff durations. Track via cast events.") end
      if needsInternalHP then print("  |cFFFFD100Health:|r Track via CLEU damage/heal events. Rare to be tainted.") end
      if needsInternalPower then print("  |cFFFFD100Resource:|r Track via CLEU energize events + spell cost subtraction.") end
      if needsInternalCost then print("  |cFFFFD100Spell Costs:|r Read all spell costs OOC at login. Bake into config table.") end
    else
      print("|cFFD4A632[DMGAssist]|r |cFF00CC00All APIs reading clean! No internal tracking needed.|r")
    end
    print("  |cFF888888Copy this from chat (Ctrl+A, Ctrl+C in chat window) and share with your addon developer.|r")

    CLF.PushWDEvent("TAINT_MAP", {
      inCombat = inCombat,
      clean = clean,
      secret = secret,
      nilResult = nil_,
      errors = err_,
      results = results,
      secretAPIs = secretAPIs,
    })

  elseif cmd == "ac" then
    print("|cFFD4A632[DMGAssist]|r |cFF44AAFF=== Assisted Combat Diagnostic ===|r")
    local G = "|cFF00FF00"
    local R = "|cFFFF4444"
    local Y = "|cFFFFAA00"
    local E = "|r"

    local function acOk(label, detail) print("  " .. G .. "OK" .. E .. " " .. label .. (detail and (" -- " .. detail) or "")) end
    local function acBad(label, detail) print("  " .. R .. "FAIL" .. E .. " " .. label .. (detail and (" -- " .. detail) or "")) end
    local function acWarn(label, detail) print("  " .. Y .. "WARN" .. E .. " " .. label .. (detail and (" -- " .. detail) or "")) end

    if C_AssistedCombat then
      acOk("C_AssistedCombat namespace exists")
    else
      acBad("C_AssistedCombat namespace", "NOT FOUND -- this WoW build may not support it")
    end

    if C_AssistedCombat and C_AssistedCombat.IsAvailable then
      local avOk, avail, reason = pcall(C_AssistedCombat.IsAvailable)
      if not avOk then
        acBad("IsAvailable()", "pcall error")
      elseif avail then
        acOk("IsAvailable()", "Assisted Combat is enabled")
      else
        local reasonStr = "unknown"
        if reason and not (issecretvalue and issecretvalue(reason)) then reasonStr = tostring(reason) end
        acBad("IsAvailable()", "DISABLED -- reason: " .. reasonStr)
        print("    |cFFAAAAAA> Check: Game Menu > Options > Gameplay > Combat > Assisted Combat|r")
      end
    elseif C_AssistedCombat then
      acBad("IsAvailable", "method missing from namespace")
    end

    if C_AssistedCombat and C_AssistedCombat.GetNextCastSpell then
      local nOk, nextId = pcall(C_AssistedCombat.GetNextCastSpell, false)
      if not nOk then
        acBad("GetNextCastSpell(false)", "pcall error")
      elseif nextId == nil then
        acWarn("GetNextCastSpell(false)", "nil -- no recommendation right now (normal out of combat)")
      elseif issecretvalue and issecretvalue(nextId) then
        acWarn("GetNextCastSpell(false)", "SECRET value returned")
      else
        local spName = "?"
        if C_Spell and C_Spell.GetSpellName then
          local snOk, sn = pcall(C_Spell.GetSpellName, nextId)
          if snOk and sn and not (issecretvalue and issecretvalue(sn)) then spName = sn end
        end
        acOk("GetNextCastSpell(false)", "recommends: " .. tostring(nextId) .. " (" .. spName .. ")")
      end
    elseif C_AssistedCombat then
      acBad("GetNextCastSpell", "method missing from namespace")
    end

    if C_AssistedCombat and C_AssistedCombat.GetRotationSpells then
      local rOk, rotSpells = pcall(C_AssistedCombat.GetRotationSpells)
      if not rOk then
        acBad("GetRotationSpells()", "pcall error")
      elseif not rotSpells then
        acBad("GetRotationSpells()", "returned nil")
      elseif issecretvalue and issecretvalue(rotSpells) then
        acWarn("GetRotationSpells()", "SECRET value returned")
      else
        local count = #rotSpells
        acOk("GetRotationSpells()", count .. " spells in rotation")
        local names = {}
        for i = 1, math.min(count, 8) do
          local sid = rotSpells[i]
          if sid and not (issecretvalue and issecretvalue(sid)) then
            local sn = "?"
            if C_Spell and C_Spell.GetSpellName then
              local snOk2, nm = pcall(C_Spell.GetSpellName, sid)
              if snOk2 and nm and not (issecretvalue and issecretvalue(nm)) then sn = nm end
            end
            table.insert(names, "    " .. tostring(sid) .. " = " .. sn)
          end
        end
        for _, line in ipairs(names) do print(line) end
        if count > 8 then print("    ... and " .. (count - 8) .. " more") end
      end
    elseif C_AssistedCombat then
      acBad("GetRotationSpells", "method missing from namespace")
    end

    if C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed then
      acOk("C_SpellActivationOverlay.IsSpellOverlayed", "proc detection available")
    else
      acBad("C_SpellActivationOverlay.IsSpellOverlayed", "NOT FOUND -- proc detection unavailable")
    end

    if AssistedCombatManager and AssistedCombatManager.GetUpdateRate then
      local rOk2, rate = pcall(function() return AssistedCombatManager:GetUpdateRate() end)
      if rOk2 and rate and not (issecretvalue and issecretvalue(rate)) then
        acOk("AssistedCombatManager.GetUpdateRate", tostring(rate) .. "s (" .. string.format("%.0f", 1/rate) .. " Hz)")
      else
        acWarn("AssistedCombatManager.GetUpdateRate", "could not read rate")
      end
    end

    print("|cFFD4A632[DMGAssist]|r |cFF44AAFF--- Internal State ---|r")
    local acAvailStr = CLF._acAvailable == true and (G .. "true" .. E) or (CLF._acAvailable == false and (R .. "false" .. E) or (Y .. "nil (not checked yet)" .. E))
    print("  _acAvailable: " .. acAvailStr)
    local nextStr = "nil"
    if CLF._acNextCastId then
      nextStr = tostring(CLF._acNextCastId)
      if CLF._acNextCastName then nextStr = nextStr .. " (" .. CLF._acNextCastName .. ")" end
    end
    print("  _acNextCastId: " .. nextStr)
    local rotMapCount = 0
    if CLF._acRotationNames then
      for _ in pairs(CLF._acRotationNames) do rotMapCount = rotMapCount + 1 end
    end
    print("  _acRotationNames: " .. rotMapCount .. " entries")
    if CLF._acLastRotationRefresh and CLF._acLastRotationRefresh > 0 then
      local ago = GetTime() - CLF._acLastRotationRefresh
      print("  _acLastRotationRefresh: " .. string.format("%.1f", ago) .. "s ago")
    else
      print("  _acLastRotationRefresh: never")
    end

  elseif cmd == "settings" or cmd == "options" or cmd == "config" or cmd == "opt" then
    CLF.ToggleSettings()
  elseif cmd == "export" then
    print("|cFFD4A632[DMGAssist]|r Export your config at the DMGAssist web companion")
  elseif cmd == "import" then
    print("|cFFD4A632[DMGAssist]|r Import via DMGAssist web companion -- download addon package from website")
  else
    print("|cFFD4A632[DMGAssist]|r Commands:")
    print("|cFFFFD100  Core:|r")
    print("  /dmga options      -- Options panel (also: gear icon, right-click minimap)")
    print("  /dmga show|hide|toggle -- HUD visibility")
    print("  /dmga lock|unlock  -- Lock/unlock HUD position")
    print("  /dmga ooc          -- Toggle auto-hide out of combat")
    print("|cFFFFD100  Mode:|r")
    print("  /dmga mode         -- Cycle AoE / ST")
    print("  /dmga mode st|aoe  -- Override mode")
    print("|cFFFFD100  Diagnostics:|r")
    print("  /dmga snapshot     -- Last tick: queue, candidates, scores, signals, taint")
    print("  /dmga selftest     -- Full subsystem health check (API, aura, spells, taint)")
    print("  /dmga status       -- Current spec, mode, toggles")
    print("  /dmga spells       -- Which APL spells are known/talented")
    print("  /dmga trinkets     -- Equipped trinkets + cooldown status")
    print("  /dmga glows        -- Check glow/overlay CVar health")
    print("  /dmga fixglows     -- Auto-fix overlay CVars")
    print("  /dmga testinterrupt -- Simulate boss mod interrupt alert")
    print("  /dmga consumables  -- Check consumable buff status")
    print("  /dmga spellbook    -- View spell book (learned cast times, CDs, costs)")
    print("  /dmga ac           -- Assisted Combat diagnostic (API + internal state)")
    print("  /dmga taintreset   -- Reset taint hit counters")
    print("  /dmga taintstats   -- View per-API taint statistics")
    print("  /dmga taintmap     -- Full API permission scan (best in combat)")
    print("  /dmga debug        -- Toggle debug (verbose/off)")
    print("  /dmga debugbuff    -- Debug buff detection (default: mark_of_the_wild)")
    print("  /dmga debugscan   -- Debug action bar signal detection + defensives")
    print("  /dmga debugbuff <name> -- Debug specific buff (e.g. moonfire)")
    print("  /dmga reset        -- Factory reset (reloads UI)")
    print("|cFFFFD100  Controls:|r")
    print("  Minimap icon: L-click = toggle HUD, R-click = menu")
    print("  HUD unlock: drag to move, R-click to lock")
    print("  HUD gear icon: open Options panel")
  end
end
