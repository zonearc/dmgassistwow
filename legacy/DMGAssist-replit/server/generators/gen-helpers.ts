/**
 * @module generators/gen-helpers
 * @description
 * Generates **Helpers.lua** -- the foundational runtime API layer.
 *
 * Produces: `Helpers.lua` in the addon ZIP
 *
 * This is the largest generated file. It provides the Detaint system,
 * API compatibility shims, snapshot cache, and all aura/cooldown/talent
 * helper functions that the transpiled APL conditions call at runtime.
 *
 * @taint-solution All API returns pass through Detaint/DetaintStr/DetaintBool
 * which use issecretvalue() to safely handle WoW 12.0 secret values.
 */

import type { Spec, AplEntry, HudConfig, CombatAlert } from "@shared/schema";
import { ADDON_NAME, ADDON_VERSION, WOW_INTERFACE, escapeLuaStr, safeLuaCondition, generateSpecLookupEntries, type AddonData } from "./shared";
import { conditionToLua } from "./transpiler";

/**
 * Generates Helpers.lua -- the foundational runtime API layer.
 *
 * This is the largest and most critical generated file. It provides:
 *
 * ## Detaint System (§H1)
 * WoW 12.0 marks many API returns as "secret" (tainted). Comparing or
 * concatenating tainted values crashes the client with:
 *   `attempt to compare a secret string value`
 * Three detaint functions use issecretvalue() to safely handle secret values:
 * - `Detaint(val)` → returns nil if secret, otherwise tonumber(val)
 * - `DetaintStr(val)` → returns nil if secret, otherwise the string
 * - `DetaintBool(val)` → returns false if secret, otherwise the boolean
 *
 * ## API Compat Shims (§H2)
 * WoW 12.0 moved many APIs to new namespaces (e.g. GetSpellName → C_Spell.GetSpellName).
 * Safe wrappers try the new API first, fall back to legacy, and detaint all returns.
 *
 * ## Snapshot Cache (§H3)
 * `CLF.RefreshSnapshot()` samples all game state once per tick into `CLF._snap`.
 * All downstream code reads from the snapshot, eliminating redundant API calls.
 *
 * ## Aura / Cooldown / Combat Helpers (§H4-H9)
 * Cached lookups for buffs, debuffs, cooldowns, spell known status, trinkets,
 * movement, stealth, GCD, resources, talents, and keybinds.
 *
 * ## Condition Evaluator Helpers (§H10)
 * Spell cast time, cost, buff duration, charges, runes, pandemic tracking, etc.
 *
 * ## Issue Logging (§H11)
 * `CLF.Log()` captures runtime diagnostics viewable in the Issues debug tab.
 *
 * @param data - Single spec's addon data bundle (used for resource type index).
 */
export function generateHelpers(data: AddonData): string {
  return `-- ═══════════════════════════════════════════════════════════════════════
-- Helpers.lua -- Runtime API layer for DMGAssist
-- Detaint wrappers, compat shims, snapshot cache, aura/CD/talent lookups
-- ═══════════════════════════════════════════════════════════════════════
local _, CLF = ...
_G.CLF = CLF
local L = CLF.L or setmetatable({}, {__index = function(_, k) return k end})

-- ── §H0: Upvalue frequently called globals ──
-- Storing globals as locals avoids hash table lookup on every call.
-- Critical for functions called 20× per second in the combat loop.
local GetTime = GetTime
local UnitPower = UnitPower
local UnitPowerMax = UnitPowerMax
local UnitHealth = UnitHealth
local UnitHealthMax = UnitHealthMax
local UnitExists = UnitExists
local UnitIsDead = UnitIsDead
local UnitCanAttack = UnitCanAttack
local UnitCastingInfo = UnitCastingInfo
local UnitChannelInfo = UnitChannelInfo
local GetUnitSpeed = GetUnitSpeed
local GetInstanceInfo = GetInstanceInfo
local GetHaste = GetHaste
local mathMax = math.max
local mathMin = math.min
local mathFloor = math.floor
local stringFormat = string.format
local tableInsert = table.insert

-- ── §H1: Detaint System ──
-- WoW 12.0 (Midnight) "Secret Values" system:
--   - issecretvalue(val) returns true if a value is secret
--   - type(val) returns the real type safely (never errors)
--   - string.format / string.join / concatenation (..) ARE allowed with secrets
--     but the RESULT inherits secret state
--   - tostring(), tonumber() are BLOCKED on secret values
--   - Comparisons (==, <, >, ~=) are BLOCKED on same-type secret values
--   - (if secretVal then) works as nil-check since Alpha 6 (true if non-nil)
--   - Arithmetic (+, -, *, /) is BLOCKED on secret values
--   - Player secondary resources (combo pts, runes, etc.) are NOT secret
--   - UnitHealthMax/UnitPowerMax for player are NOT secret
--   - Player's own spellcasts (even in combat) are NOT secret
--   - Enemy/boss data in instances IS secret
--
-- Strategy: Use issecretvalue() to check. If not secret, use normal ops.
-- If secret, return nil (we only need player data for rotation logic).
--
-- Taint hit tracking: counts how many times each tagged API returned a secret value.
-- Used by /dmga selftest and /dmga snapshot to identify which APIs are being blocked.
-- Adaptive throttling: after N consecutive taints on the same API category, we back off
-- and stop calling it, relying on internal tracking instead. Periodically retry (~10s)
-- to see if the API has become readable. Full reset on combat exit.
CLF._taintStats = {}
CLF._taintStreak = {}
CLF._taintBackoff = {}
CLF._taintLastRetry = {}
CLF._taintCalls = {}
CLF._taintFallbacks = {}
CLF._taintCombatStats = nil

local TAINT_BACKOFF_THRESHOLD = 5
local TAINT_RETRY_INTERVAL = 10

function CLF.TaintHit(tag)
  if not tag then return end
  CLF._taintStats[tag] = (CLF._taintStats[tag] or 0) + 1
  CLF._taintStreak[tag] = (CLF._taintStreak[tag] or 0) + 1
  if CLF._taintStreak[tag] >= TAINT_BACKOFF_THRESHOLD then
    CLF._taintBackoff[tag] = true
  end
end
local TaintHit = CLF.TaintHit

function CLF.TaintClean(tag)
  if not tag then return end
  CLF._taintStreak[tag] = 0
  CLF._taintBackoff[tag] = nil
end
local TaintClean = CLF.TaintClean

function CLF.TaintCall(tag)
  if not tag then return end
  CLF._taintCalls[tag] = (CLF._taintCalls[tag] or 0) + 1
end
local TaintCall = CLF.TaintCall

function CLF.TaintFallback(tag)
  if not tag then return end
  CLF._taintFallbacks[tag] = (CLF._taintFallbacks[tag] or 0) + 1
end
local TaintFallback = CLF.TaintFallback

function CLF.IsTaintedAPI(tag)
  if not tag then return false end
  if not CLF._taintBackoff[tag] then return false end
  local now = GetTime()
  local lastRetry = CLF._taintLastRetry[tag] or 0
  if now - lastRetry >= TAINT_RETRY_INTERVAL then
    CLF._taintLastRetry[tag] = now
    return false
  end
  return true
end

function CLF.ResetTaintTracking()
  CLF._taintStreak = {}
  CLF._taintBackoff = {}
  CLF._taintLastRetry = {}
end

function CLF.GetTaintReport()
  local report = {}
  for tag, hits in pairs(CLF._taintStats) do
    local calls = CLF._taintCalls[tag] or 0
    local fallbacks = CLF._taintFallbacks[tag] or 0
    local backedOff = CLF._taintBackoff[tag] and true or false
    tableInsert(report, tag .. ": " .. hits .. "/" .. calls .. " tainted" .. (fallbacks > 0 and (", " .. fallbacks .. " fallbacks") or "") .. (backedOff and " [BACKED OFF]" or ""))
  end
  return report
end

function CLF.SnapshotTaintForCombat()
  CLF._taintCombatStats = {
    stats = {},
    calls = {},
    fallbacks = {},
  }
  for tag, v in pairs(CLF._taintStats) do
    CLF._taintCombatStats.stats[tag] = v
  end
  for tag, v in pairs(CLF._taintCalls) do
    CLF._taintCombatStats.calls[tag] = v
  end
  for tag, v in pairs(CLF._taintFallbacks) do
    CLF._taintCombatStats.fallbacks[tag] = v
  end
end

function CLF.GetCombatTaintSummary()
  local pre = CLF._taintCombatStats
  if not pre then return "no_data" end
  local parts = {}
  for tag, postHits in pairs(CLF._taintStats) do
    local preHits = pre.stats[tag] or 0
    local combatHits = postHits - preHits
    if combatHits > 0 then
      local preCalls = pre.calls[tag] or 0
      local postCalls = CLF._taintCalls[tag] or 0
      local combatCalls = postCalls - preCalls
      local preFB = pre.fallbacks[tag] or 0
      local postFB = CLF._taintFallbacks[tag] or 0
      local combatFB = postFB - preFB
      tableInsert(parts, tag .. "=" .. combatHits .. "/" .. combatCalls .. (combatFB > 0 and ("+" .. combatFB .. "fb") or ""))
    end
  end
  if #parts == 0 then return "clean" end
  return table.concat(parts, ", ")
end

function Detaint(val, tag)
  if type(val) == "nil" then return nil end
  if issecretvalue and issecretvalue(val) then TaintHit(tag) return nil end
  return tonumber(val)
end

function DetaintStr(val, tag)
  if type(val) == "nil" then return nil end
  if issecretvalue and issecretvalue(val) then TaintHit(tag) return nil end
  if type(val) == "string" then return val end
  local ok, s = pcall(tostring, val)
  if ok then return s end
  return nil
end
CLF.DetaintStr = DetaintStr

function DetaintBool(val, tag)
  if type(val) == "nil" then return false end
  if issecretvalue and issecretvalue(val) then TaintHit(tag) return false end
  if val then return true else return false end
end
CLF.DetaintBool = DetaintBool
CLF.Detaint = Detaint

function CLF.PlayAddonSound(sid)
  if not sid or sid == 0 then return end
  if sid > 0 then
    PlaySound(sid, "Master")
  end
end

function CLF.PlayEventSound(eventKey)
  local config = CLF_Config or CLF_DefaultConfig
  if not config then return end
  local hud = config.hud or {}
  local enabled = hud[eventKey .. "Sound"]
  if enabled == false then return end
  local soundId = hud[eventKey .. "SoundId"] or 8959
  CLF.PlayAddonSound(soundId)
end

function CLF.SafeReload()
  C_Timer.After(0, function()
    ReloadUI()
  end)
end

-- ── §H2: API Compatibility Wrappers ──
-- WoW 11.0+ moved many spell APIs into C_Spell namespace.
-- WoW 12.0 (Midnight) continued this trend with C_SpellBook.
-- Each wrapper tries the new API first, falls back to legacy, and
-- detaints all return values at the source.
CLF._spellIdNameCache = {}

local function SafeGetSpellName(spellIdentifier)
  local raw = nil
  if C_Spell and C_Spell.GetSpellName then
    raw = C_Spell.GetSpellName(spellIdentifier)
  elseif GetSpellInfo then
    raw = GetSpellInfo(spellIdentifier)
  end
  if raw ~= nil then
    if issecretvalue and issecretvalue(raw) then
      if type(spellIdentifier) == "number" then
        return CLF._spellIdNameCache[spellIdentifier]
      end
      return nil
    end
    local clean = DetaintStr(raw)
    if clean and type(spellIdentifier) == "number" then
      CLF._spellIdNameCache[spellIdentifier] = clean
    end
    return clean
  end
  if type(spellIdentifier) == "number" then
    return CLF._spellIdNameCache[spellIdentifier]
  end
  return nil
end
CLF._SafeGetSpellName = SafeGetSpellName

local auraNameCache = {}
function NormalizeName(raw)
  local cached = auraNameCache[raw]
  if cached then return cached end
  cached = string.gsub(raw, "_", " ")
  cached = string.gsub(cached, ":", "")
  auraNameCache[raw] = cached
  return cached
end
CLF._NormalizeName = NormalizeName

local function SafeGetSpellID(spellIdentifier)
  if C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo(spellIdentifier)
    return info and Detaint(info.spellID) or nil
  end
  if GetSpellInfo then
    local raw = select(7, GetSpellInfo(spellIdentifier))
    return raw and Detaint(raw) or nil
  end
  return nil
end

local function SafeIsPlayerSpell(spellID)
  if IsPlayerSpell then
    local raw = IsPlayerSpell(spellID)
    if raw ~= nil then
      if issecretvalue and issecretvalue(raw) then return true end
      if raw then return true end
    end
  end
  if C_SpellBook and C_SpellBook.IsSpellKnown then
    local raw = C_SpellBook.IsSpellKnown(spellID)
    if raw ~= nil then
      if issecretvalue and issecretvalue(raw) then return true end
      if raw then return true end
    end
  end
  if IsSpellKnownOrOverridesKnown then
    local raw = IsSpellKnownOrOverridesKnown(spellID)
    if raw ~= nil then
      if issecretvalue and issecretvalue(raw) then return true end
      if raw then return true end
    end
  end
  return false
end

CLF._usableCache = {}
CLF._usableCacheTime = 0

function CLF.CacheSpellUsability()
  local fAPL = CLF._filteredAPL
  if not fAPL then return end
  local sections = { "rotation", "precombatState", "precombatOpener", "interrupts" }
  for _, sec in ipairs(sections) do
    if fAPL[sec] then
      for _, e in ipairs(fAPL[sec]) do
        if e.spellName then
          local clean = NormalizeName(e.spellName)
          local usable = false
          if C_Spell and C_Spell.IsSpellUsable then
            local raw = C_Spell.IsSpellUsable(clean)
            if type(raw) ~= "nil" and not (issecretvalue and issecretvalue(raw)) then
              usable = raw and true or false
            else
              usable = true
            end
          elseif IsUsableSpell then
            local rawU = IsUsableSpell(clean)
            if type(rawU) ~= "nil" and not (issecretvalue and issecretvalue(rawU)) then
              usable = rawU and true or false
            else
              usable = true
            end
          end
          local cleanKey = string.lower(NormalizeName(e.spellName))
          CLF._usableCache[cleanKey] = usable
        end
      end
    end
  end
  CLF._usableCacheTime = GetTime()
end

local function SafeNum(v, fallback)
  if type(v) ~= "number" then return fallback or 0 end
  if issecretvalue and issecretvalue(v) then return fallback or 0 end
  return v
end

local function EnsureCleanRT()
  local rt = CLF._resTracker
  if not rt then return end
  if type(rt.current) == "number" and issecretvalue and issecretvalue(rt.current) then
    rt.current = 0
    rt.source = "detaint_reset"
  end
  if type(rt.max) == "number" and issecretvalue and issecretvalue(rt.max) then
    rt.max = 1
  end
end

local function CheckResourceAffordable(spellName)
  local costs = CLF._spellCosts
  if not costs then return true end
  local cleanKey = nil
  local cost = nil
  if type(spellName) == "number" then
    cost = costs[spellName]
    if not cost then
      local name = CLF._spellIdToName and CLF._spellIdToName[spellName]
      if name then
        cost = costs[name]
        cleanKey = name
      end
    end
  else
    cleanKey = string.lower(NormalizeName(spellName))
    cost = costs[cleanKey]
  end
  if not cost and cleanKey and CLF._spellAliases then
    local al = CLF._spellAliases[cleanKey]
    if al then
      for _, a in ipairs(al) do
        cost = costs[a]
        if cost then break end
      end
    end
  end
  if cost and cost > 0 then
    local rt = CLF._resTracker
    if not rt then return true end
    local cur = SafeNum(rt.current, nil)
    local liveOk = false
    local pt = CLF.GetSpecPowerType and CLF.GetSpecPowerType()
    if pt ~= nil and UnitPower then
      local rawPow = UnitPower("player", pt)
      local livePow = SafeNum(rawPow, nil)
      if livePow then
        cur = livePow
        liveOk = true
        rt.current = livePow
        rt.lastCalibrate = GetTime()
        rt.source = "AffordCheck"
      end
    end
    if cur == nil then
      return true
    end
    if cur < cost then
      if not liveOk then
        if not rt.lastCalibrate or (GetTime() - rt.lastCalibrate) > 3 then
          return true
        end
      end
      return false
    end
  end
  local secCosts = CLF._spellSecondaryCosts
  if secCosts then
    if not cleanKey and type(spellName) == "number" then
      local name = CLF._spellIdToName and CLF._spellIdToName[spellName]
      if name then cleanKey = name end
    end
    if cleanKey then
      local secCost = secCosts[cleanKey]
      if not secCost and CLF._spellAliases then
        local al = CLF._spellAliases[cleanKey]
        if al then
          for _, a in ipairs(al) do
            secCost = secCosts[a]
            if secCost then break end
          end
        end
      end
      if secCost and secCost > 0 then
        local config = CLF_Config or CLF_DefaultConfig
        local secPT = config and config.spec and config.spec.secondaryPowerTypeId
        if secPT and UnitPower then
          local rawSec = UnitPower("player", secPT)
          local secCur = SafeNum(rawSec, 0)
          if secCur < secCost then return false end
        end
      end
    end
  end
  return true
end

function CLF.CheckResourceAffordable(spellName)
  local result = CheckResourceAffordable(spellName)
  if result == false and CLF.debugEnabled then
    local costs = CLF._spellCosts
    local cleanKey = type(spellName) == "number" and tostring(spellName) or string.lower(NormalizeName(spellName))
    local cost = costs and costs[cleanKey]
    local rt = CLF._resTracker
    local cur = rt and rt.current
    CLF.Log("RESOURCE", "NOT AFFORDABLE: " .. tostring(spellName) .. " cost=" .. tostring(cost) .. " power=" .. tostring(cur))
  end
  return result
end

function CLF.IsAffordableForSlot(spellName, cleanName, isAcRecommended, inCombat, barUsable)
  local dbg = CLF.debugEnabled
  if isAcRecommended then
    if barUsable == false then
      local hasCost = CLF._spellCosts and CLF._spellCosts[cleanName]
      if hasCost and hasCost > 0 then
        if dbg then
          CLF.Log("RESOURCE", "AC-UNAFFORDABLE: " .. tostring(spellName) .. " AC-recommended but bar greyed out, cost=" .. hasCost)
        end
        return false
      end
    end
    if dbg then
      CLF.Log("RESOURCE", "AC-AFFORDABLE: " .. tostring(spellName) .. " AC-recommended, barUsable=" .. tostring(barUsable))
    end
    return true
  end
  if barUsable == true then
    if dbg then
      CLF.Log("RESOURCE", "BAR-AFFORDABLE: " .. tostring(spellName) .. " barUsable=true (game says castable)")
    end
    return true
  end
  if barUsable == false then
    local hasCost = CLF._spellCosts and CLF._spellCosts[cleanName]
    if hasCost and hasCost > 0 then
      if dbg then
        CLF.Log("RESOURCE", "NOT AFFORDABLE: " .. tostring(spellName) .. " cost=" .. hasCost .. " power=" .. tostring(CLF._resTracker and CLF._resTracker.current or 0))
      end
      return false
    end
    if CLF.Charges.IsChargeSpell(cleanName) then
      local cur = CLF.Charges.Get(cleanName)
      if cur and cur >= 1 then
        if dbg then
          CLF.Log("RESOURCE", "CHARGE-AFFORDABLE: " .. tostring(spellName) .. " barUsable=false but charges=" .. cur)
        end
        return true
      end
    end
    if CLF._gcdActive then
      if dbg then
        CLF.Log("RESOURCE", "GCD-RESCUE: " .. tostring(spellName) .. " barUsable=false during GCD, assuming affordable")
      end
      return true
    end
    if dbg then
      CLF.Log("RESOURCE", "NOT AFFORDABLE: " .. tostring(spellName) .. " barUsable=false, no cost, no charges, no GCD")
    end
    return false
  end
  local usable = CLF.IsSpellUsable and CLF.IsSpellUsable(spellName) or false
  if not usable and CLF._gcdActive then usable = true end
  if usable and inCombat then
    local hasCost = CLF._spellCosts and CLF._spellCosts[cleanName]
    if hasCost and hasCost > 0 then
      local resOk = CLF.CheckResourceAffordable(spellName)
      if resOk == false then
        usable = false
        if dbg then
          CLF.Log("RESOURCE", "APL-UNAFFORDABLE: " .. tostring(spellName) .. " cost=" .. hasCost .. " IsSpellUsable=true(tainted?) but resource check says no")
        end
      end
    end
  end
  if dbg then
    CLF.Log("RESOURCE", "FALLBACK: " .. tostring(spellName) .. " result=" .. tostring(usable) .. " (barUsable=nil, APL path)")
  end
  return usable
end

function CLF.ValidateCandidate(spellName, cleanName, opts)
  local cdRemaining = opts.cdRemaining or 0
  local cdTotal = opts.cdTotal or 0
  local eventCDActive = opts.eventCDActive or false
  local eventCDRem = opts.eventCDRemaining or 0
  local isCooldownSpell = opts.isCooldownSpell or false
  local isAcRecommended = opts.isAcRecommended or false
  local inCombat = opts.inCombat or false
  local barUsable = opts.barUsable
  local hasAPLData = opts.hasAPLData or false
  local gcdActive = opts.gcdActive or false
  local dbg = CLF.debugEnabled

  -- Gate 1: CD normalization — non-CD spells with APL data ignore bar/event CD
  local barOnCD = cdRemaining > 1.5
  if barOnCD and hasAPLData and not isCooldownSpell then
    if dbg then CLF.Log("VALIDATE", cleanName .. " G1: CD-norm override (non-CD+APL), was cd=" .. string.format("%.1f", cdRemaining)) end
    barOnCD = false
    cdRemaining = 0
  end
  if eventCDActive and hasAPLData and not isCooldownSpell then
    if dbg then CLF.Log("VALIDATE", cleanName .. " G1: eventCD-norm override (non-CD+APL)") end
    eventCDActive = false
    eventCDRem = 0
  end
  local onCooldown = barOnCD or eventCDActive

  -- Gate 2: Eclipse detection (taint-proof side effect)
  if inCombat then
    CLF.DetectEclipseFromBar(cleanName, onCooldown)
  end

  -- Gate 3: Charge + Self-buff blocking
  local isChargeSpell = CLF.Charges.IsChargeSpell(cleanName)
  local buffBlocked = false
  if not onCooldown and (isChargeSpell or isCooldownSpell) then
    if CLF.IsSelfBuffBlocking(cleanName) then
      buffBlocked = true
      onCooldown = true
      if cdRemaining < 1.5 then
        local br = CLF.SelfBuffBlockRemains(cleanName)
        if br > 0 then cdRemaining = br end
      end
      if cdTotal < cdRemaining then
        cdTotal = cdRemaining
      end
      if dbg then CLF.Log("VALIDATE", cleanName .. " G3: buff-blocked, synth cd=" .. string.format("%.1f", cdRemaining)) end
    end
  end

  -- Gate 4: AC validation — demote if genuinely on long CD
  if isAcRecommended and onCooldown and cdRemaining > 3.0 then
    if dbg then CLF.Log("VALIDATE", cleanName .. " G4: AC demoted, on CD " .. string.format("%.1f", cdRemaining) .. "s") end
    isAcRecommended = false
  end

  -- Gate 5: Affordability (resource check with AC bypass + taint handling)
  local affordable = CLF.IsAffordableForSlot(spellName, cleanName, isAcRecommended, inCombat, barUsable)

  -- Gate 5 logging
  if dbg and not affordable then
    CLF.Log("VALIDATE", cleanName .. " G5: not affordable (ac=" .. tostring(isAcRecommended) .. " barUsable=" .. tostring(barUsable) .. ")")
  end

  -- Gate 6: Derived state — starved / GCD-wait / effective-CD
  local resourceStarved = (not barUsable) and (not onCooldown) and (not affordable) and not hasAPLData
  local gcdOnlyWait = gcdActive and not onCooldown and not barUsable and not resourceStarved
  local effectiveCD = onCooldown or (not barUsable and not resourceStarved and not gcdOnlyWait and not hasAPLData)

  -- Gate 6b: AC short-CD rescue (APL path)
  if isAcRecommended and effectiveCD and cdRemaining <= 3.0 then
    if dbg then CLF.Log("VALIDATE", cleanName .. " G6b: AC short-CD rescue, cd=" .. string.format("%.1f", cdRemaining)) end
    effectiveCD = false
    onCooldown = false
    cdRemaining = 0
  end

  -- Gate 7: Movement awareness — cast-time spells penalized while moving
  local movePenalty = 0
  local snap = CLF._snap
  if snap and snap.moving and inCombat and not isAcRecommended then
    local castTime = CLF._spellBook and CLF._spellBook[cleanName] and CLF._spellBook[cleanName].castTime
    if castTime and castTime > 0 then
      movePenalty = 5000
      if dbg then CLF.Log("VALIDATE", cleanName .. " G7: moving+castTime=" .. tostring(castTime) .. " penalty=" .. movePenalty) end
    end
  end

  -- Gate 8: Execute-range awareness — execute spells get priority shift based on target health
  local executePenalty = 0
  local targetHP = (snap and snap.targetHealthPct) or 100
  if CLF._executeSpells and CLF._executeSpells[cleanName] then
    if targetHP > 35 then
      executePenalty = 20000
      if dbg then CLF.Log("VALIDATE", cleanName .. " G8: execute spell above 35% HP (" .. string.format("%.0f", targetHP) .. "%), penalty=" .. executePenalty) end
    elseif targetHP <= 20 then
      executePenalty = -3000
      if dbg then CLF.Log("VALIDATE", cleanName .. " G8: execute spell in kill range (" .. string.format("%.0f", targetHP) .. "%), boost=" .. (-executePenalty)) end
    end
  end

  -- Gate 6 summary log
  if dbg and (resourceStarved or effectiveCD or buffBlocked) then
    CLF.Log("VALIDATE", cleanName .. " G6: starved=" .. tostring(resourceStarved) .. " effectiveCD=" .. tostring(effectiveCD) .. " buffBlk=" .. tostring(buffBlocked) .. " gcdWait=" .. tostring(gcdOnlyWait))
  end

  return {
    onCooldown = onCooldown,
    cdRemaining = cdRemaining,
    cdTotal = cdTotal,
    isChargeSpell = isChargeSpell,
    buffBlocked = buffBlocked,
    isAcRecommended = isAcRecommended,
    affordable = affordable,
    resourceStarved = resourceStarved,
    gcdOnlyWait = gcdOnlyWait,
    effectiveCD = effectiveCD,
    eventCDActive = eventCDActive,
    eventCDRem = eventCDRem,
    movePenalty = movePenalty,
    executePenalty = executePenalty,
  }
end

function CLF.IsSlotReady(candidate, slotIdx, inCombat, gcdActive)
  local spUsable = true
  local cKey = string.lower(candidate.spellName)
  local isAcTrusted = candidate.reason and (string.sub(candidate.reason, 1, 3) == "ac:") or false
  local dbg = CLF.debugEnabled

  -- Check 1: Starved spells cannot fill slot 1 (unless AC-trusted)
  if candidate.signalType == "starved" and not isAcTrusted then
    if dbg then CLF.Log("SLOTCHK", "S" .. slotIdx .. " " .. candidate.spellName .. " REJECT: starved signal") end
    return false, "starved"
  end

  -- Check 2: Resource affordability (unless AC-trusted)
  if spUsable and not isAcTrusted and CLF.CheckResourceAffordable then
    local resOk = CLF.CheckResourceAffordable(candidate.spellName)
    if resOk == false then
      if dbg then CLF.Log("SLOTCHK", "S" .. slotIdx .. " " .. candidate.spellName .. " REJECT: not affordable") end
      return false, "not_affordable"
    end
  end

  -- Check 3: Trinket CD
  if inCombat and candidate.isTrinket then
    local trinketCD = candidate.cdRemaining or 0
    if trinketCD > 1.5 then
      if dbg then CLF.Log("SLOTCHK", "S" .. slotIdx .. " " .. candidate.spellName .. " REJECT: trinket cd=" .. string.format("%.1f", trinketCD)) end
      return false, "trinket_cd"
    end
    if candidate.trinketSlot then
      local liveTrCD, liveTrReady = CLF.GetTrinketCooldown(candidate.trinketSlot)
      if (liveTrCD and liveTrCD > 1.5) or liveTrReady == false then
        if dbg then CLF.Log("SLOTCHK", "S" .. slotIdx .. " " .. candidate.spellName .. " REJECT: trinket live cd") end
        return false, "trinket_cd_live"
      end
    end
  elseif inCombat then
    -- Check 4: Live castability (unless AC-trusted)
    if not isAcTrusted then
      spUsable = CLF.IsSpellUsable and CLF.IsSpellUsable(candidate.spellName) or false
      if not spUsable and gcdActive and (candidate.cdRemaining or 0) <= 0 then
        spUsable = true
        if dbg then CLF.Log("SLOTCHK", "S" .. slotIdx .. " " .. candidate.spellName .. " GCD-rescue: IsSpellUsable=false during GCD") end
      end
      if not spUsable then
        local slotClean = string.gsub(string.gsub(cKey, ":", ""), "%s+", " ")
        if CLF.Charges.IsChargeSpell(slotClean) then
          local cur = CLF.Charges.Get(slotClean)
          if cur and cur > 0 then
            spUsable = true
            if dbg then CLF.Log("SLOTCHK", "S" .. slotIdx .. " " .. candidate.spellName .. " CHARGE-rescue: IsSpellUsable=false but charges=" .. cur) end
          end
        end
      end
    end

    if spUsable then
      local cIsCD = candidate.isCooldown or (CLF._cdMap and CLF._cdMap[cKey])

      -- Check 5: Live CD recheck
      if cIsCD then
        local _, _, liveCD = CLF.SpellStatus(candidate.spellName)
        if liveCD and liveCD > 1.5 then
          if dbg then CLF.Log("SLOTCHK", "S" .. slotIdx .. " " .. candidate.spellName .. " REJECT: live cd=" .. string.format("%.1f", liveCD)) end
          return false, "live_cd"
        end
      end

      -- Check 6: Event CD recheck
      if cIsCD then
        local onEvCD, evRem = CLF.IsOnEventCD(candidate.spellName)
        if onEvCD and evRem and evRem > 1.5 then
          if dbg then CLF.Log("SLOTCHK", "S" .. slotIdx .. " " .. candidate.spellName .. " REJECT: event cd=" .. string.format("%.1f", evRem)) end
          return false, "event_cd"
        end
      end

      -- Check 7: Self-buff blocking recheck
      local s1IsCharge = CLF.Charges.IsChargeSpell(cKey)
      if (s1IsCharge or cIsCD) and CLF.IsSelfBuffBlocking(candidate.spellName) then
        if dbg then CLF.Log("SLOTCHK", "S" .. slotIdx .. " " .. candidate.spellName .. " REJECT: self-buff active") end
        return false, "buff_active"
      end
    elseif not spUsable then
      if dbg then CLF.Log("SLOTCHK", "S" .. slotIdx .. " " .. candidate.spellName .. " REJECT: IsSpellUsable=false") end
      return false, "not_usable"
    end
  end

  if dbg then CLF.Log("SLOTCHK", "S" .. slotIdx .. " " .. candidate.spellName .. " PASS (ac=" .. tostring(isAcTrusted) .. ")") end
  return true, "pass"
end

function CLF.RecordOffGCD(castKey)
  if not CLF._offGCDSpells then CLF._offGCDSpells = {} end
  local preGCDStart = CLF._gcdCache and CLF._gcdCache.start or 0
  CLF.MarkGCDStart()
  local postGCDStart = CLF._gcdCache and CLF._gcdCache.start or 0
  local isOffGCD = false
  if postGCDStart > preGCDStart + 0.05 then
    CLF._offGCDSpells[castKey] = nil
  else
    local now = GetTime()
    local gc = CLF._gcdCache
    if gc and gc.start > 0 and gc.duration > 0 and (now - gc.start) < gc.duration then
      CLF._offGCDSpells[castKey] = nil
    else
      CLF._offGCDSpells[castKey] = true
      isOffGCD = true
    end
  end
  if CLF.debugEnabled then
    CLF.Log("CAST", "RecordOffGCD: " .. castKey .. " offGCD=" .. tostring(isOffGCD))
  end
end

function CLF.ClearStuckPenalty(castKey)
  local hadPenalty = CLF._stuckPenalties and CLF._stuckPenalties[castKey]
  local wasTop = CLF._stuckTopSpell == castKey
  if hadPenalty then
    CLF._stuckPenalties[castKey] = nil
  end
  if wasTop then
    CLF._stuckTopSpell = nil
    CLF._stuckTopSince = 0
  end
  if CLF.debugEnabled and (hadPenalty or wasTop) then
    CLF.Log("STUCK", "ClearStuckPenalty: " .. castKey .. " hadPenalty=" .. tostring(hadPenalty ~= nil) .. " wasTop=" .. tostring(wasTop))
  end
end

local function SafeIsUsableSpell(spellName)
  local clean = NormalizeName(spellName)
  local tag = "IsSpellUsable"
  TaintCall(tag)

  if CLF._inCombat then
    local cleanKey = string.lower(NormalizeName(spellName))
    if C_Spell and C_Spell.IsSpellUsable then
      local uOk, rawUsable = pcall(C_Spell.IsSpellUsable, clean)
      if uOk and rawUsable ~= nil then
        if issecretvalue and issecretvalue(rawUsable) then
          CLF._usableCache[cleanKey] = true
          TaintClean(tag)
          return true
        else
          local result = rawUsable and true or false
          CLF._usableCache[cleanKey] = result
          TaintClean(tag)
          return result
        end
      end
    end
    TaintClean(tag)
    local cached = CLF._usableCache[cleanKey]
    if cached ~= nil then return cached end
    local bookEntry = CLF._spellBook[cleanKey]
    if bookEntry and bookEntry.isKnown then return true end
    return false
  end

  if C_Spell and C_Spell.IsSpellUsable then
    local raw = C_Spell.IsSpellUsable(clean)
    if type(raw) ~= "nil" and issecretvalue and issecretvalue(raw) then
      TaintHit(tag)
      TaintFallback(tag)
      local cleanKey = string.lower(NormalizeName(spellName))
      local cached = CLF._usableCache[cleanKey]
      if cached ~= nil then return cached end
      return true
    end
    TaintClean(tag)
    local result = (type(raw) ~= "nil") and (raw and true or false) or false
    local cleanKey = string.lower(NormalizeName(spellName))
    CLF._usableCache[cleanKey] = result
    return result
  end
  if IsUsableSpell then
    local usable, noMana = IsUsableSpell(clean)
    local u = usable
    if type(u) ~= "nil" and issecretvalue and issecretvalue(u) then
      TaintHit(tag)
      TaintFallback(tag)
      local cleanKey = string.lower(NormalizeName(spellName))
      local cached = CLF._usableCache[cleanKey]
      if cached ~= nil then return cached end
      return true
    end
    TaintClean(tag)
    u = (type(u) ~= "nil") and (u and true or false) or false
    local nm = noMana
    if type(nm) ~= "nil" and issecretvalue and issecretvalue(nm) then nm = false
    else nm = (type(nm) ~= "nil") and (nm and true or false) or false end
    local result = u and not nm
    local cleanKey = string.lower(NormalizeName(spellName))
    CLF._usableCache[cleanKey] = result
    return result
  end
  return false
end

function SafeDetaintNum(val, fallback)
  if type(val) == "nil" then return fallback or 0 end
  if issecretvalue and issecretvalue(val) then return nil end
  return tonumber(val) or (fallback or 0)
end

local function HasteAdjust(knownDur)
  return knownDur
end

local function SafeGetSpellCooldown(spellIdentifier)
  local tag = "GetSpellCD"
  TaintCall(tag)
  local cleanName = string.lower(type(spellIdentifier) == "string" and NormalizeName(spellIdentifier) or tostring(spellIdentifier))

  local bookEntry = CLF._spellBook[cleanName]
  if bookEntry and bookEntry.cdReadyAt and bookEntry.cdReadyAt > 0 then
    local now = GetTime()
    if now >= bookEntry.cdReadyAt then
      bookEntry.cdReadyAt = 0
      TaintClean(tag)
      return 0, 0, true
    else
      local knownDur = bookEntry.cdDuration or CLF._knownCDDur[cleanName] or 0
      TaintClean(tag)
      return bookEntry.cdReadyAt - knownDur, knownDur, true
    end
  end

  local castTime = CLF._castLog[cleanName]
  local knownDur = CLF._knownCDDur[cleanName]
  if castTime and knownDur and knownDur > 1.5 then
    local elapsed = GetTime() - castTime
    if elapsed < knownDur then
      TaintClean(tag)
      return castTime, knownDur, true
    end
  end

  local cached = CLF._barCD and CLF._barCD[cleanName]
  if cached and cached.start and cached.duration and cached.duration > 1.5 then
    local rem = mathMax(0, (cached.start + cached.duration) - GetTime())
    if rem > 0 then
      TaintClean(tag)
      return cached.start, cached.duration, true
    end
  end

  if CLF._inCombat then
    if C_Spell and C_Spell.GetSpellCooldown then
      local cdOk, cdInfo = pcall(C_Spell.GetSpellCooldown, cleanName)
      if cdOk and cdInfo then
        local sOk, cdStart = pcall(function() return cdInfo.startTime end)
        local dOk, cdDur = pcall(function() return cdInfo.duration end)
        local startVal = sOk and cdStart or nil
        local durVal = dOk and cdDur or nil
        if startVal and durVal then
          local isSecStart = issecretvalue and issecretvalue(startVal)
          local isSecDur = issecretvalue and issecretvalue(durVal)
          if not isSecStart and not isSecDur then
            local nStart = tonumber(startVal) or 0
            local nDur = tonumber(durVal) or 0
            if nStart > 0 and nDur > 1.5 then
              if not CLF._knownCDDur[cleanName] or CLF._knownCDDur[cleanName] < nDur then
                CLF._knownCDDur[cleanName] = nDur
              end
              TaintClean(tag)
              return nStart, nDur, true
            end
          end
        end
      end
    end
    local probeUsable = SafeIsUsableSpell(cleanName)
    if probeUsable == false then
      local fallbackDur = CLF._knownCDDur[cleanName] or 120
      TaintClean(tag)
      return GetTime(), fallbackDur, true
    end
    local safetyDur = CLF._knownCDDur[cleanName]
    if safetyDur and safetyDur > 1.5 then
      local castTime = CLF._castLog[cleanName]
      if castTime then
        local elapsed = GetTime() - castTime
        if elapsed < safetyDur then
          TaintClean(tag)
          return castTime, safetyDur, true
        end
      end
    end
    if not safetyDur and CLF._cdMap and CLF._cdMap[cleanName] then
      local castTime = CLF._castLog[cleanName]
      if castTime then
        local defaultDur = 30
        local elapsed = GetTime() - castTime
        if elapsed < defaultDur then
          TaintClean(tag)
          return castTime, defaultDur, true
        end
      end
    end
    TaintClean(tag)
    return 0, 0, true
  end

  local clean = (type(spellIdentifier) == "string") and NormalizeName(spellIdentifier) or spellIdentifier
  if C_Spell and C_Spell.GetSpellCooldownDuration then
    local ok, durObj = pcall(C_Spell.GetSpellCooldownDuration, clean)
    if ok and durObj then
      local zOk, isZero = pcall(durObj.IsZero, durObj)
      local isSecret = zOk and issecretvalue and issecretvalue(isZero)
      if zOk and not isSecret and isZero then
        TaintClean(tag)
        return 0, 0, true
      end
      if zOk and not isSecret and not isZero then
        if castTime and knownDur and knownDur > 1.5 then
          return castTime, knownDur, true
        end
        TaintClean(tag)
        return GetTime(), 1.5, true
      end
    end
  end

  TaintClean(tag)
  return 0, 0, true
end

local function SafeGetSpellCharges(spellIdentifier)
  local tag = "GetSpellCharges"
  TaintCall(tag)
  local cleanName = string.lower(type(spellIdentifier) == "string" and NormalizeName(spellIdentifier) or tostring(spellIdentifier))
  local cur, maxCh, rechRem = CLF.Charges.Get(cleanName)
  if cur and maxCh and maxCh > 1 then
    TaintClean(tag)
    return cur, maxCh, 0, rechRem or 0
  end
  TaintClean(tag)
  return nil
end
CLF._SafeGetSpellCharges = SafeGetSpellCharges

-- ── §H2b: Runtime Spell Icon Resolution ──
-- NormalizeName already defined above (§H2a) -- converts underscores to spaces for API lookups.

-- Resolves spell icons at runtime via C_Spell.GetSpellTexture().
-- Falls back to GetSpellTexture() for older clients. Caches results.
-- This eliminates the need to bake icon slugs from the admin dashboard --
-- icons auto-update when Blizzard changes them.
CLF._iconCache = {}

function CLF.ResolveSpellIcon(spellName, spellId)
  if type(spellName) == "nil" and not spellId then return nil end
  local cacheKey = spellId and ("id:" .. spellId) or spellName
  local cached = CLF._iconCache[cacheKey]
  if cached then return cached end
  local rawIcon = nil
  local lookupId = spellId
  if lookupId and C_Spell and C_Spell.GetSpellTexture then
    local ok, tex = pcall(C_Spell.GetSpellTexture, lookupId)
    if ok and tex then rawIcon = tex end
  end
  if not rawIcon then
    local cleanName = NormalizeName(spellName or "")
    if C_Spell and C_Spell.GetSpellTexture then
      local ok, tex = pcall(C_Spell.GetSpellTexture, cleanName)
      if ok and tex then rawIcon = tex end
    end
    if not rawIcon and GetSpellTexture then
      local ok, tex = pcall(GetSpellTexture, cleanName)
      if ok and tex then rawIcon = tex end
    end
    if not rawIcon and C_Spell and C_Spell.GetSpellInfo then
      local ok, info = pcall(C_Spell.GetSpellInfo, lookupId or cleanName)
      if ok and info and info.iconID then rawIcon = info.iconID end
    end
    if not rawIcon and GetSpellInfo then
      local ok, _, _, tex = pcall(GetSpellInfo, cleanName)
      if ok and tex then rawIcon = tex end
    end
  end
  if rawIcon then
    if issecretvalue and issecretvalue(rawIcon) then
      return nil
    end
    local icon = rawIcon
    if type(rawIcon) == "number" then
      icon = rawIcon
    else
      local num = tonumber(rawIcon)
      if num then icon = num end
    end
    CLF._iconCache[cacheKey] = icon
    if spellName then CLF._iconCache[spellName] = icon end
    return icon
  end
  if spellName and CLF._spellAliases then
    local cleanLower = string.lower(NormalizeName(spellName))
    local aliases = CLF._spellAliases[cleanLower]
    if aliases then
      for _, alt in ipairs(aliases) do
        local altCached = CLF._iconCache[alt]
        if altCached then
          CLF._iconCache[cacheKey] = altCached
          if spellName then CLF._iconCache[spellName] = altCached end
          return altCached
        end
        if C_Spell and C_Spell.GetSpellTexture then
          local ok2, tex2 = pcall(C_Spell.GetSpellTexture, NormalizeName(alt))
          if ok2 and tex2 and not (issecretvalue and issecretvalue(tex2)) then
            CLF._iconCache[cacheKey] = tex2
            CLF._iconCache[alt] = tex2
            if spellName then CLF._iconCache[spellName] = tex2 end
            return tex2
          end
        end
      end
    end
  end
  return nil
end

function CLF.RefreshAPLIcons()
  CLF._iconCache = {}
  local f = CLF._filteredAPL
  if not f then return end
  local lists = { f.rotation, f.interrupts, f.precombatState, f.precombatOpener, f.offensives, f.cooldowns }
  local resolved = 0
  for _, list in ipairs(lists) do
    if list then
      for _, entry in ipairs(list) do
        local icon = CLF.ResolveSpellIcon(entry.spellName)
        if icon then
          entry._resolvedIcon = icon
          resolved = resolved + 1
        end
      end
    end
  end
  if resolved > 0 then
    CLF.Log("DEBUG", "RefreshAPLIcons: resolved " .. resolved .. " icons")
  end
end

CLF._rangeCache = {}

local function SafeIsSpellInRange(spellName, unit)
  local clean = NormalizeName(spellName)
  local cleanKey = string.lower(clean)
  if CLF._inCombat then
    local cached = CLF._rangeCache[cleanKey]
    if cached ~= nil then return cached end
    return true
  end
  if C_Spell and C_Spell.IsSpellInRange then
    local ok, inRange = pcall(C_Spell.IsSpellInRange, clean, unit)
    if not ok or type(inRange) == "nil" then return true end
    local result = DetaintBool(inRange)
    CLF._rangeCache[cleanKey] = result
    return result
  end
  if IsSpellInRange then
    local ok, val = pcall(IsSpellInRange, clean, unit)
    if not ok or type(val) == "nil" then return true end
    local result = DetaintStr(val) ~= "0"
    CLF._rangeCache[cleanKey] = result
    return result
  end
  return true
end

-- ── §H2c: Internal Resource Tracker ──
-- Tracks player resource (power) via OOC snapshot + UNIT_SPELLCAST_SUCCEEDED.
-- OOC: reads UnitPower/UnitPowerMax (clean outside combat).
-- Combat: UNIT_SPELLCAST_SUCCEEDED subtracts known costs and adds known gains.
-- CLEU events supplement when available (not in instances in 12.0).
-- UNIT_POWER_FREQUENT calibrates when UnitPower returns clean values.
CLF._resTracker = { current = 0, max = 1, regen = 0, lastTick = 0 }
CLF._spellCosts = {}
CLF._spellGains = {}
CLF._spellSecondaryCosts = {}
CLF._chargeState = {}
CLF._chargeSpellIds = {}

-- ═══════════════════════════════════════════════════════════
-- CHARGE MODULE (AUTHORITATIVE)
-- Single source of truth for all charge-based spell tracking.
-- All charge reads/writes MUST go through these functions.
-- Tables owned: _chargeState, _chargeSpellIds
-- ═══════════════════════════════════════════════════════════
CLF.Charges = {}

function CLF.Charges.Init(cleanName, maxCharges, rechargeDur, currentCharges, spellId)
  if not cleanName or not maxCharges or maxCharges <= 1 then return end
  cleanName = string.gsub(cleanName, ":", "")
  cleanName = string.gsub(cleanName, "%s+", " ")
  local prev = CLF._chargeState[cleanName]
  local entry = {
    current = currentCharges or maxCharges,
    max = maxCharges,
    rechargeDur = rechargeDur or 0,
    nextChargeAt = (prev and prev.nextChargeAt) or nil,
    lastConsumeAt = (prev and prev.lastConsumeAt) or nil,
  }
  CLF._chargeState[cleanName] = entry
  if spellId then
    CLF._chargeState[tostring(spellId)] = entry
    CLF._chargeSpellIds[spellId] = true
  end
  CLF._chargeSpellIds[cleanName] = true
  if rechargeDur and rechargeDur > 1.5 then
    local existDur = CLF._knownCDDur[cleanName]
    if not existDur or existDur > rechargeDur * 2 then
      CLF._knownCDDur[cleanName] = rechargeDur
    end
  end
  if CLF.debugEnabled then
    CLF.Log("CHARGE", "Init: " .. cleanName .. " " .. entry.current .. "/" .. entry.max .. " recharge=" .. string.format("%.1f", entry.rechargeDur) .. "s")
  end
end

function CLF.Charges.Resolve(cleanName)
  if not cleanName then return nil, nil end
  cleanName = string.gsub(cleanName, ":", "")
  cleanName = string.gsub(cleanName, "%s+", " ")
  local entry = CLF._chargeState[cleanName]
  if entry and entry.max > 1 then return entry, cleanName end
  if CLF._spellAliases then
    local aliases = CLF._spellAliases[cleanName]
    if aliases then
      for _, alt in ipairs(aliases) do
        local altEntry = CLF._chargeState[alt]
        if altEntry and altEntry.max > 1 then return altEntry, alt end
      end
    end
    for base, alts in pairs(CLF._spellAliases) do
      for _, alt in ipairs(alts) do
        if alt == cleanName then
          local baseEntry = CLF._chargeState[base]
          if baseEntry and baseEntry.max > 1 then return baseEntry, base end
        end
      end
    end
  end
  return nil, cleanName
end

function CLF.Charges.Get(cleanName)
  local entry, resolvedKey = CLF.Charges.Resolve(cleanName)
  if not entry then return nil, nil, 0 end
  local cur = entry.current
  local now = GetTime()
  if entry.nextChargeAt and cur < entry.max then
    if now >= entry.nextChargeAt then
      local rechDur = entry.rechargeDur
      if rechDur and rechDur > 0 then
        local overdue = now - entry.nextChargeAt
        local gained = 1 + math.floor(overdue / rechDur)
        cur = math.min(cur + gained, entry.max)
        entry.current = cur
        if cur >= entry.max then
          entry.nextChargeAt = nil
        else
          entry.nextChargeAt = entry.nextChargeAt + gained * rechDur
        end
      else
        cur = entry.max
        entry.current = cur
        entry.nextChargeAt = nil
      end
    end
  end
  local remaining = 0
  if entry.nextChargeAt and cur < entry.max then
    remaining = mathMax(0, entry.nextChargeAt - now)
  end
  return cur, entry.max, remaining
end

function CLF.Charges.Consume(cleanName)
  local entry, resolvedKey = CLF.Charges.Resolve(cleanName)
  if not entry then return end
  local before = entry.current
  if entry.current > 0 then
    entry.current = entry.current - 1
  end
  local rechDur = entry.rechargeDur
  if (not rechDur or rechDur <= 0) then
    rechDur = CLF._knownCDDur[cleanName] or 0
    if rechDur > 0 then entry.rechargeDur = rechDur end
  end
  if rechDur and rechDur > 0 and not entry.nextChargeAt then
    entry.nextChargeAt = GetTime() + rechDur
  end
  entry.lastConsumeAt = GetTime()
  if CLF.debugEnabled then
    CLF.Log("CHARGE", "Consume: " .. cleanName .. " " .. before .. "->" .. entry.current .. "/" .. entry.max .. (entry.nextChargeAt and (" nextAt=" .. string.format("%.1f", entry.nextChargeAt - GetTime()) .. "s") or ""))
  end
end

function CLF.Charges.IsChargeSpell(cleanName)
  local entry = CLF.Charges.Resolve(cleanName)
  return entry ~= nil
end

function CLF.Charges.SetFromAPI(cleanName, currentCharges, maxCharges, rechargeDur, cdStart, cdDur, spellId)
  if not maxCharges or maxCharges <= 1 then return end
  cleanName = string.gsub(cleanName, ":", "")
  cleanName = string.gsub(cleanName, "%s+", " ")
  local entry = CLF._chargeState[cleanName]
  if entry then
    entry.max = maxCharges
    if currentCharges ~= nil then
      entry.current = currentCharges
    end
    if rechargeDur and rechargeDur > 0 then
      entry.rechargeDur = rechargeDur
    end
    if cdStart and cdStart > 0 and cdDur and cdDur > 0 then
      entry.nextChargeAt = cdStart + cdDur
    elseif cdDur and cdDur == 0 then
      entry.current = maxCharges
      entry.nextChargeAt = nil
    end
  else
    entry = {
      current = currentCharges or maxCharges,
      max = maxCharges,
      rechargeDur = rechargeDur or 0,
      nextChargeAt = nil
    }
    if cdStart and cdStart > 0 and cdDur and cdDur > 0 then
      entry.nextChargeAt = cdStart + cdDur
    end
    CLF._chargeState[cleanName] = entry
    if spellId then
      CLF._chargeState[tostring(spellId)] = entry
      CLF._chargeSpellIds[spellId] = true
    end
    CLF._chargeSpellIds[cleanName] = true
  end
  if rechargeDur and rechargeDur > 1.5 then
    local existDur = CLF._knownCDDur[cleanName]
    if not existDur or existDur > rechargeDur * 2 then
      CLF._knownCDDur[cleanName] = rechargeDur
    end
  end
  if CLF.debugEnabled then
    CLF.Log("CHARGE", "SetFromAPI: " .. cleanName .. " " .. entry.current .. "/" .. entry.max)
  end
end

function CLF.Charges.Tick(cleanName)
  local entry = CLF._chargeState[cleanName]
  if not entry or not entry.nextChargeAt or entry.current >= entry.max then return end
  local now = GetTime()
  if now >= entry.nextChargeAt then
    local rechDur = entry.rechargeDur
    if rechDur and rechDur > 0 then
      entry.current = entry.current + 1
      if entry.current < entry.max then
        entry.nextChargeAt = entry.nextChargeAt + rechDur
      else
        entry.nextChargeAt = nil
      end
    else
      entry.current = entry.max
      entry.nextChargeAt = nil
    end
    if CLF.debugEnabled then
      CLF.Log("CHARGE", "Tick: " .. cleanName .. " recharged to " .. entry.current .. "/" .. entry.max)
    end
  end
end

function CLF.Charges.Remove(cleanName, spellId)
  CLF._chargeState[cleanName] = nil
  if spellId then
    CLF._chargeState[tostring(spellId)] = nil
    CLF._chargeSpellIds[spellId] = nil
  end
  CLF._chargeSpellIds[cleanName] = nil
end
-- ═══════════════════════════════════════════════════════════

CLF._spellBook = {}
CLF._statsSnapshot = {
  haste = 0,
  crit = 0,
  mastery = 0,
  versatility = 0,
  primaryStat = 0,
  gcdBase = 1.5,
  gcdMin = 0.75,
  gcdHasted = 1.5,
  regenBase = 0,
  regenHasted = 0,
  snapshotTime = 0,
}
CLF._castObservations = {}

function CLF.SnapshotStats()
  local ss = CLF._statsSnapshot
  ss.snapshotTime = GetTime()
  pcall(function()
    if GetHaste then
      local h = GetHaste()
      if h ~= nil then ss.haste = tonumber(h) or 0 end
    end
    if GetCritChance then
      local c = GetCritChance()
      if c ~= nil then ss.crit = tonumber(c) or 0 end
    end
    if GetMasteryEffect then
      local m = GetMasteryEffect()
      if m ~= nil then ss.mastery = tonumber(m) or 0 end
    end
    if GetCombatRatingBonus then
      local v = GetCombatRatingBonus(29)
      if v ~= nil then ss.versatility = tonumber(v) or 0 end
    end
    if UnitStat then
      local best = 0
      for i = 1, 5 do
        local ok2, base, stat = pcall(UnitStat, "player", i)
        if ok2 and stat and tonumber(stat) then
          local val = tonumber(stat)
          if val > best then best = val end
        end
      end
      ss.primaryStat = best
    end
  end)
  local hastePct = ss.haste or 0
  ss.gcdHasted = mathMax(ss.gcdMin, ss.gcdBase / (1 + hastePct / 100))
  CLF._hasteCache = ss.haste
  CLF.Log("SYSTEM", "Stats snapshot: haste=" .. string.format("%.1f", ss.haste) .. "% crit=" .. string.format("%.1f", ss.crit) .. "% GCD=" .. string.format("%.2f", ss.gcdHasted) .. "s")
end

function CLF.HasteMultiplier()
  local h = CLF._statsSnapshot.haste or CLF._hasteCache or 0
  return 1 + h / 100
end

function CLF.HastedValue(baseVal)
  if not baseVal or baseVal <= 0 then return 0 end
  return baseVal / CLF.HasteMultiplier()
end

CLF._pendingOOCScans = {}

function CLF.DeferOOCScan(name, fn)
  if CLF._pendingOOCScans[name] then return end
  CLF._pendingOOCScans[name] = fn
  if CLF.debugEnabled then
    CLF.Log("SYSTEM", "Deferred OOC scan queued: " .. name)
  end
end

function CLF.DrainOOCScans()
  if CLF._inCombat then return end
  local count = 0
  for name, fn in pairs(CLF._pendingOOCScans) do
    local ok, err = pcall(fn)
    if not ok then
      local errOk, errStr = pcall(tostring, err)
      CLF.LogIssue("Runtime", "Error in DeferredOOC_" .. name, errOk and errStr or "unknown")
    end
    CLF._pendingOOCScans[name] = nil
    count = count + 1
  end
  if CLF.debugEnabled and count > 0 then
    CLF.Log("SYSTEM", "Drained " .. count .. " deferred OOC scan(s)")
  end
end

function CLF.SnapshotSpellBook()
  if CLF._inCombat then
    CLF.DeferOOCScan("SnapshotSpellBook", CLF.SnapshotSpellBook)
    return
  end
  local ss = CLF._statsSnapshot
  local hasteM = CLF.HasteMultiplier()
  local book = CLF._spellBook
  local allSpells = {}

  local fAPL = CLF._filteredAPL
  if fAPL then
    local sections = { "rotation", "precombatState", "precombatOpener", "interrupts" }
    for _, sec in ipairs(sections) do
      if fAPL[sec] then
        for _, e in ipairs(fAPL[sec]) do
          if e.spellName then
            local cn = string.lower(NormalizeName(e.spellName))
            allSpells[cn] = { name = e.spellName, id = e.spellId }
          end
        end
      end
    end
  end
  local cfg = CLF_Config or CLF_DefaultConfig
  if cfg and cfg.entries then
    for _, e in ipairs(cfg.entries) do
      if e.spellName then
        local cn = string.lower(NormalizeName(e.spellName))
        if not allSpells[cn] then
          allSpells[cn] = { name = e.spellName, id = e.spellId }
        end
      end
    end
  end

  local learned = 0
  for cleanName, info in pairs(allSpells) do
    local entry = book[cleanName] or {}
    entry.name = info.name
    entry.spellId = info.id
    entry.cleanName = cleanName

    pcall(function()
      if C_Spell and C_Spell.GetSpellInfo then
        local si = C_Spell.GetSpellInfo(info.id or NormalizeName(info.name))
        if si then
          local rawCT = si.castTime
          if rawCT and type(rawCT) == "number" then
            entry.baseCastTimeMS = rawCT
            entry.baseCastTime = rawCT / 1000
            entry.hastedCastTime = (rawCT > 0) and (rawCT / 1000 / hasteM) or 0
          end
          if si.minRange then entry.minRange = tonumber(si.minRange) or 0 end
          if si.maxRange then entry.maxRange = tonumber(si.maxRange) or 0 end
        end
      end
    end)

    pcall(function()
      if C_Spell and C_Spell.GetSpellCooldown then
        local cdInfo = C_Spell.GetSpellCooldown(info.id or NormalizeName(info.name))
        if cdInfo and cdInfo.duration then
          local dur = SafeDetaintNum(cdInfo.duration)
          if dur and dur > 1.5 then
            entry.cdDuration = dur
            CLF._knownCDDur[cleanName] = dur
          end
        end
      end
      if not entry.cdDuration and GetSpellBaseCooldown then
        local ok2, ms = pcall(GetSpellBaseCooldown, info.id or NormalizeName(info.name))
        if ok2 and ms then
          local d = SafeDetaintNum(ms)
          if d and d > 1500 then
            entry.cdDuration = d / 1000
            CLF._knownCDDur[cleanName] = d / 1000
          end
        end
      end
    end)

    pcall(function()
      if C_Spell and C_Spell.GetSpellPowerCost then
        local costs = C_Spell.GetSpellPowerCost(info.id or NormalizeName(info.name))
        if costs then
          local specPT = CLF.GetSpecPowerType()
          local config = CLF_Config or CLF_DefaultConfig
          local secPT = config and config.spec and config.spec.secondaryPowerTypeId
          local fallbackCost = nil
          local fallbackType = nil
          for _, ci in ipairs(costs) do
            if ci.cost and type(ci.cost) == "number" then
              if specPT ~= nil and ci.type == specPT then
                entry.cost = ci.cost
                entry.costType = ci.type
                if ci.cost > 0 then
                  CLF._spellCosts[cleanName] = ci.cost
                end
              elseif secPT ~= nil and ci.type == secPT then
                if ci.cost > 0 then
                  CLF._spellSecondaryCosts[cleanName] = ci.cost
                end
              elseif not fallbackCost then
                fallbackCost = ci.cost
                fallbackType = ci.type
              end
            end
          end
          if fallbackCost and not entry.cost then
            entry.cost = fallbackCost
            entry.costType = fallbackType
          end
        end
      end
    end)

    pcall(function()
      if C_Spell and C_Spell.GetSpellCharges then
        local chInfo = C_Spell.GetSpellCharges(info.id or NormalizeName(info.name))
        if chInfo and chInfo.maxCharges and chInfo.maxCharges > 1 then
          entry.maxCharges = chInfo.maxCharges
          entry.currentCharges = chInfo.currentCharges or 0
          entry.rechargeDuration = chInfo.cooldownDuration or 0
          CLF.Charges.Init(cleanName, chInfo.maxCharges, chInfo.cooldownDuration or 0, chInfo.currentCharges or 0, info.id)
        end
      end
    end)

    pcall(function()
      entry.icon = CLF.ResolveSpellIcon(info.name, info.id)
    end)

    entry.isKnown = CLF.IsSpellKnown and CLF.IsSpellKnown(info.name, info.id) or false
    entry.cdReadyAt = entry.cdReadyAt or 0
    entry.lastCastAt = entry.lastCastAt or 0

    book[cleanName] = entry
    learned = learned + 1
  end

  CLF.Log("SYSTEM", "Spell Book snapshot: " .. learned .. " spells learned (haste=" .. string.format("%.1f", ss.haste) .. "%)")
  CLF.ResolveConditionAuraIds()
  CLF.DiscoverSpellOverrides()
  CLF.RefreshEclipseGrantMap()
end

function CLF.DiscoverSpellOverrides()
  if CLF._inCombat then
    CLF.DeferOOCScan("DiscoverSpellOverrides", CLF.DiscoverSpellOverrides)
    return
  end
  local getOverride = (C_Spell and C_Spell.GetOverrideSpell) or FindSpellOverrideByID
  local getName = C_Spell and C_Spell.GetSpellName
  if not getOverride or not getName then
    CLF.Log("SYSTEM", "Override discovery: API unavailable, skipping")
    return
  end

  CLF._spellAliases = {}
  CLF._dynamicAliasLog = {}

  local aplSpells = {}
  local fAPL = CLF._filteredAPL
  if fAPL then
    local sections = { "rotation", "precombatState", "precombatOpener", "interrupts" }
    for _, sec in ipairs(sections) do
      if fAPL[sec] then
        for _, e in ipairs(fAPL[sec]) do
          if e.spellName and e.spellId then
            local cn = string.lower(NormalizeName(e.spellName))
            if not aplSpells[cn] then
              aplSpells[cn] = e.spellId
            end
          end
        end
      end
    end
  end
  local cfg = CLF_Config or CLF_DefaultConfig
  if cfg and cfg.entries then
    for _, e in ipairs(cfg.entries) do
      if e.spellName and e.spellId then
        local cn = string.lower(NormalizeName(e.spellName))
        if not aplSpells[cn] then
          aplSpells[cn] = e.spellId
        end
      end
    end
  end

  local overridePairs = {}
  for cn, baseId in pairs(aplSpells) do
    local ok, ovId = pcall(getOverride, baseId)
    if ok and ovId and type(ovId) == "number" then
      if not (issecretvalue and issecretvalue(ovId)) and ovId ~= baseId then
        local ok2, ovName = pcall(getName, ovId)
        if ok2 and ovName and not (issecretvalue and issecretvalue(ovName)) then
          local ovCn = string.lower(tostring(ovName))
          if ovCn ~= cn then
            table.insert(overridePairs, { base = cn, baseId = baseId, override = ovCn, overrideId = ovId })
          end
        end
      end
    end
  end

  local groups = {}
  local spellToGroup = {}
  local gIdx = 0
  for _, pair in ipairs(overridePairs) do
    local gBase = spellToGroup[pair.base]
    local gOver = spellToGroup[pair.override]
    local g
    if gBase and gOver and gBase ~= gOver then
      g = gBase
      for name, _ in pairs(groups[gOver]) do
        groups[g][name] = true
        spellToGroup[name] = g
      end
      groups[gOver] = nil
    elseif gBase then
      g = gBase
    elseif gOver then
      g = gOver
    else
      gIdx = gIdx + 1
      g = gIdx
      groups[g] = {}
    end
    groups[g][pair.base] = true
    groups[g][pair.override] = true
    spellToGroup[pair.base] = g
    spellToGroup[pair.override] = g
  end

  for _, members in pairs(groups) do
    local names = {}
    for name, _ in pairs(members) do
      table.insert(names, name)
    end
    if #names > 1 then
      for _, name in ipairs(names) do
        local aliases = {}
        for _, other in ipairs(names) do
          if other ~= name then
            table.insert(aliases, other)
          end
        end
        CLF._spellAliases[name] = aliases
      end
    end
  end

  local aliasCount = 0
  for _ in pairs(CLF._spellAliases) do aliasCount = aliasCount + 1 end
  CLF.Log("SYSTEM", "Dynamic override discovery: " .. #overridePairs .. " overrides, " .. aliasCount .. " alias entries")
  for _, pair in ipairs(overridePairs) do
    CLF.Log("SYSTEM", "  Override: " .. pair.base .. " (id:" .. pair.baseId .. ") -> " .. pair.override .. " (id:" .. pair.overrideId .. ")")
  end
end

CLF._auraResolveAttempted = false

function CLF.ResolveConditionAuraIds()
  if CLF._inCombat then
    CLF.DeferOOCScan("ResolveConditionAuraIds", CLF.ResolveConditionAuraIds)
    return
  end
  CLF._spellNameToId = CLF._spellNameToId or {}
  CLF._spellIdToName = CLF._spellIdToName or {}
  local config = CLF_Config or CLF_DefaultConfig
  if not config then return end
  local auraNames = (CLF_Config and CLF_Config._conditionAuraNames) or (CLF_DefaultConfig and CLF_DefaultConfig._conditionAuraNames)
  local resolved = 0
  local total = 0
  if auraNames then
    for _, rawName in ipairs(auraNames) do
      local cleanName = string.lower(string.gsub(rawName, "_", " "))
      total = total + 1
      if not CLF._spellNameToId[cleanName] then
        local sid = nil
        if C_Spell and C_Spell.GetSpellInfo then
          local ok, info = pcall(C_Spell.GetSpellInfo, cleanName)
          if ok and type(info) == "table" and info.spellID then
            sid = Detaint and Detaint(info.spellID) or info.spellID
          end
        end
        if not sid and C_Spell and C_Spell.GetSpellInfo then
          local titleName = string.gsub(cleanName, "(%a)([%w]*)", function(first, rest)
            return string.upper(first) .. rest
          end)
          local ok2, info2 = pcall(C_Spell.GetSpellInfo, titleName)
          if ok2 and type(info2) == "table" and info2.spellID then
            sid = Detaint and Detaint(info2.spellID) or info2.spellID
          end
        end
        if not sid and GetSpellInfo then
          local ok3, _, _, _, _, _, spellId3 = pcall(GetSpellInfo, cleanName)
          if ok3 and spellId3 then
            sid = Detaint and Detaint(spellId3) or spellId3
          end
        end
        if sid and type(sid) == "number" and sid > 0 then
          CLF._spellNameToId[cleanName] = sid
          CLF._spellIdToName[sid] = cleanName
          resolved = resolved + 1
        end
      else
        resolved = resolved + 1
      end
    end
  end
  local fAPL = CLF._filteredAPL
  if fAPL then
    local sections = { "rotation", "precombatState", "precombatOpener", "interrupts" }
    for _, sec in ipairs(sections) do
      if fAPL[sec] then
        for _, e in ipairs(fAPL[sec]) do
          if e.spellName then
            local cn = string.lower(NormalizeName(e.spellName))
            if not CLF._spellNameToId[cn] and e.spellId then
              CLF._spellNameToId[cn] = e.spellId
              CLF._spellIdToName[e.spellId] = cn
            end
          end
        end
      end
    end
  end
  local sData = CLF._spellData or {}
  for sName, data in pairs(sData) do
    if data and data.id and not CLF._spellNameToId[sName] then
      CLF._spellNameToId[sName] = data.id
      CLF._spellIdToName[data.id] = sName
    end
  end
  CLF._auraResolveAttempted = true
  CLF.Log("SYSTEM", "Aura ID resolver: " .. resolved .. "/" .. total .. " condition auras resolved, " .. CLF._CountTable(CLF._spellNameToId) .. " total name-to-ID mappings")
end

function CLF._CountTable(t)
  local n = 0
  if t then for _ in pairs(t) do n = n + 1 end end
  return n
end

function CLF.SpellBookGet(spellName)
  if not spellName then return nil end
  local cleanName = string.lower(NormalizeName(spellName))
  return CLF._spellBook[cleanName]
end

function CLF.SpellBookCastTime(spellName)
  local entry = CLF.SpellBookGet(spellName)
  if not entry then return 0 end
  local observed = CLF._castObservations[entry.cleanName]
  if observed and observed.count >= 3 and observed.avgTime > 0 then
    return observed.avgTime
  end
  if entry.hastedCastTime and entry.hastedCastTime > 0 then
    return entry.hastedCastTime
  end
  if entry.baseCastTime and entry.baseCastTime > 0 then
    return entry.baseCastTime / CLF.HasteMultiplier()
  end
  return 0
end

function CLF.SpellBookCDReady(spellName)
  local entry = CLF.SpellBookGet(spellName)
  if not entry then return true end
  if entry.cdReadyAt and entry.cdReadyAt > 0 then
    return GetTime() >= entry.cdReadyAt
  end
  return true
end

function CLF.SpellBookCDRemaining(spellName)
  local entry = CLF.SpellBookGet(spellName)
  if not entry then return 0 end
  if entry.cdReadyAt and entry.cdReadyAt > 0 then
    return mathMax(0, entry.cdReadyAt - GetTime())
  end
  return 0
end

function CLF.RecordCastInBook(spellName, spellId)
  local cleanName = string.lower(NormalizeName(spellName))
  local entry = CLF._spellBook[cleanName]
  if not entry then
    entry = { name = spellName, spellId = spellId, cleanName = cleanName, isKnown = true }
    CLF._spellBook[cleanName] = entry
  end
  local now = GetTime()
  entry.lastCastAt = now
  if not entry.cdDuration or entry.cdDuration <= 1.5 then
    local kd = CLF._knownCDDur[cleanName]
    if kd and kd > 1.5 then
      entry.cdDuration = kd
    end
  end
  local isChargeSp = entry.maxCharges and entry.maxCharges > 1
  if (not entry.cdDuration or entry.cdDuration <= 1.5) and C_Spell and C_Spell.GetSpellCooldown then
    local id = spellId or entry.spellId
    if id then
      local ok, info = pcall(C_Spell.GetSpellCooldown, id)
      if ok and info then
        local dur = info.duration
        if dur and not (issecretvalue and issecretvalue(dur)) then
          local nd = tonumber(dur) or 0
          if nd > 1.5 and not isChargeSp then
            entry.cdDuration = nd
            CLF._knownCDDur[cleanName] = nd
          end
        end
      end
    end
  end
  local isChargeSpell = CLF.Charges.IsChargeSpell(cleanName)
  if isChargeSpell then
    CLF.Charges.Consume(cleanName)
    local chargesAfter = CLF.Charges.Get(cleanName) or 0
    if chargesAfter > 0 then
      entry.cdReadyAt = nil
    else
      local chEntry = CLF.Charges.Resolve(cleanName)
      local rechg = (chEntry and chEntry.rechargeDur) or CLF._knownCDDur[cleanName] or entry.cdDuration or 0
      if rechg > 1.5 then
        entry.cdReadyAt = now + rechg
      end
    end
  elseif entry.cdDuration and entry.cdDuration > 1.5 then
    entry.cdReadyAt = now + entry.cdDuration
  end
end

function CLF.ObserveCastTime(spellName, startTime, endTime)
  if not spellName or not startTime or not endTime then return end
  local cleanName = string.lower(NormalizeName(spellName))
  local actualTime = endTime - startTime
  if actualTime <= 0 or actualTime > 15 then return end
  local obs = CLF._castObservations[cleanName]
  if not obs then
    obs = { count = 0, totalTime = 0, avgTime = 0, lastTime = 0 }
    CLF._castObservations[cleanName] = obs
  end
  if obs.count >= 20 then
    obs.totalTime = obs.avgTime * 10
    obs.count = 10
  end
  obs.count = obs.count + 1
  obs.totalTime = obs.totalTime + actualTime
  obs.avgTime = obs.totalTime / obs.count
  obs.lastTime = actualTime
end

function CLF.RefreshSpellBookOOC()
  if CLF._inCombat then
    CLF.DeferOOCScan("RefreshSpellBookOOC", CLF.RefreshSpellBookOOC)
    return
  end
  CLF.SnapshotStats()
  CLF.SnapshotSpellBook()
end

function CLF.InitResourceTracker()
  local rt = CLF._resTracker
  local pt = CLF.GetSpecPowerType()
  local config = CLF_Config or CLF_DefaultConfig
  if config and config.knownResourceGains then
    CLF._spellGains = CLF._spellGains or {}
    for spellKey, gain in pairs(config.knownResourceGains) do
      if type(gain) == "number" and gain > 0 then
        CLF._spellGains[spellKey] = gain
      end
    end
  end
  if pt ~= nil and not CLF._inCombat then
    local rawPow = UnitPower("player", pt)
    local rawMax = UnitPowerMax("player", pt)
    if type(rawPow) == "number" and not (issecretvalue and issecretvalue(rawPow)) then
      rt.current = rawPow
      rt.lastCalibrate = GetTime()
      rt.source = "InitOOC"
    end
    if type(rawMax) == "number" and not (issecretvalue and issecretvalue(rawMax)) and rawMax > 0 then rt.max = rawMax end
  end
  local safeMax = SafeNum(rt.max, 0)
  if safeMax <= 1 and pt ~= nil then
    local DEFAULT_MAX = { [0] = 50000, [1] = 100, [2] = 100, [3] = 100, [4] = 5, [5] = 6, [6] = 125, [7] = 5, [8] = 120, [9] = 5, [11] = 100, [12] = 5, [13] = 100, [16] = 4, [17] = 120, [19] = 50 }
    rt.max = DEFAULT_MAX[pt] or 100
  end
  rt.lastTick = GetTime()
  local REGEN_TYPES = { [3] = 10, [1] = 0, [2] = 10 }
  rt.regen = REGEN_TYPES[pt] or 0
  if pt == 2 or pt == 3 then
    local haste = CLF.GetCachedHaste()
    if haste > 0 then
      rt.regen = rt.regen * (1 + haste / 100)
    end
  end
end

function CLF.TickResourceRegen(elapsed)
  local rt = CLF._resTracker
  if rt.regen > 0 and elapsed > 0 then
    local cur = SafeNum(rt.current, 0)
    local mx = SafeNum(rt.max, 1)
    rt.current = mathMin(mx, cur + rt.regen * elapsed)
  end
end

function CLF.OnResourceCLEU(subEvent, spellId, amount, powerType)
  local rt = CLF._resTracker
  local pt = CLF.GetSpecPowerType()
  EnsureCleanRT()
  local cleanAmt = SafeNum(amount, nil)
  if subEvent == "SPELL_ENERGIZE" then
    if not cleanAmt or cleanAmt <= 0 then return end
    local ptMatch = false
    if powerType == nil then
      ptMatch = true
    else
      local cleanPT = SafeNum(powerType, nil)
      if cleanPT and pt ~= nil then
        ptMatch = (cleanPT == pt)
      else
        ptMatch = true
      end
    end
    if ptMatch then
      local now = GetTime()
      local lastCastTime = CLF._lastCastTimeForGainLearn or 0
      local lastCast = CLF._lastCastForGainLearn
      if lastCast and (now - lastCastTime) < 0.4 then
        local gains = CLF._spellGains
        if gains then
          local oldGain = gains[lastCast]
          if oldGain then
            if oldGain ~= cleanAmt then
              local delta = cleanAmt - oldGain
              local cur = SafeNum(rt.current, 0)
              local mx = SafeNum(rt.max, 1)
              rt.current = mathMax(0, mathMin(mx, cur + delta))
              gains[lastCast] = cleanAmt
              rt.lastCalibrate = now
              rt.source = "CLEU_correction"
            end
            return
          else
            if cleanAmt > 0 and cleanAmt < 500 then
              gains[lastCast] = cleanAmt
            end
          end
        end
      end
      local cur = SafeNum(rt.current, 0)
      local mx = SafeNum(rt.max, 1)
      rt.current = mathMin(mx, cur + cleanAmt)
      rt.lastCalibrate = now
      rt.source = "SPELL_ENERGIZE"
    end
  elseif subEvent == "SWING_DAMAGE" then
    if pt == 1 then
      local swingAmt = cleanAmt or 0
      local cur = SafeNum(rt.current, 0)
      local mx = SafeNum(rt.max, 1)
      rt.current = mathMin(mx, cur + swingAmt)
      rt.lastCalibrate = GetTime()
      rt.source = "SwingDamage"
    end
  end
end

CLF._lastCastForGainLearn = nil
CLF._lastCastTimeForGainLearn = 0
CLF._lastPowerForGainLearn = nil

function CLF.OnUnitPowerFrequent()
  if CLF._inCombat then return end
  local pt = CLF.GetSpecPowerType()
  if pt == nil then return end
  local rt = CLF._resTracker
  if not rt then return end
  if UnitPower then
    local rawPow = UnitPower("player", pt)
    local cleanPow = SafeNum(rawPow, nil)
    if cleanPow then
      rt.current = cleanPow
      rt.lastCalibrate = GetTime()
      rt.source = "UnitPowerFreq"
    end
  end
  if UnitPowerMax then
    local rawMax = UnitPowerMax("player", pt)
    local cleanMax = SafeNum(rawMax, nil)
    if cleanMax and cleanMax > 0 then
      rt.max = cleanMax
    end
  end
end

function CLF.OnSpellCastResource(spellID, castKey)
  local rt = CLF._resTracker
  if not rt then return end
  EnsureCleanRT()
  CLF._lastCastForGainLearn = castKey
  CLF._lastCastTimeForGainLearn = GetTime()
  local changed = false
  local cost = nil
  if CLF._spellCosts then
    if type(spellID) == "number" then
      cost = CLF._spellCosts[spellID]
    end
    if not cost and type(castKey) == "string" then
      cost = CLF._spellCosts[castKey]
    end
    if not cost and type(spellID) == "number" then
      local name = CLF._spellIdToName and CLF._spellIdToName[spellID]
      if name then cost = CLF._spellCosts[name] end
    end
  end
  if cost and cost > 0 then
    local cur = SafeNum(rt.current, 0)
    rt.current = mathMax(0, cur - cost)
    changed = true
  end
  local gain = nil
  if CLF._spellGains then
    if type(spellID) == "number" then
      gain = CLF._spellGains[spellID]
    end
    if not gain and type(castKey) == "string" then
      gain = CLF._spellGains[castKey]
    end
    if not gain and type(spellID) == "number" then
      local name = CLF._spellIdToName and CLF._spellIdToName[spellID]
      if name then gain = CLF._spellGains[name] end
    end
  end
  if gain and gain > 0 then
    local cur = SafeNum(rt.current, 0)
    local mx = SafeNum(rt.max, 1)
    rt.current = mathMin(mx, cur + gain)
    changed = true
  end
  if changed then
    rt.lastCalibrate = GetTime()
    rt.source = "CastAccounting"
  end
end

function CLF.CalibrateResource()
  if CLF._inCombat then
    CLF.DeferOOCScan("CalibrateResource", CLF.CalibrateResource)
    return
  end
  local pt = CLF.GetSpecPowerType()
  if pt == nil then return end
  local rt = CLF._resTracker
  local rawPow = UnitPower("player", pt)
  if type(rawPow) == "number" and not (issecretvalue and issecretvalue(rawPow)) then
    rt.current = rawPow
    rt.lastCalibrate = GetTime()
    rt.source = "CalOOC"
  end
  local rawMax = UnitPowerMax("player", pt)
  if type(rawMax) == "number" and not (issecretvalue and issecretvalue(rawMax)) and rawMax > 0 then
    rt.max = rawMax
  end
end

-- ── §H2d: Internal Aura Tracker ──
-- Tracks player buffs/debuffs via CLEU SPELL_AURA events.
-- Falls back to C_UnitAuras OOC (clean outside combat).
CLF._auraState = {}
CLF._cleuTargetGUID = nil
CLF._debuffsByGUID = {}

function CLF._EstimateAuraExpiration(spellName, auraType)
  local now = GetTime()
  if auraType == "DEBUFF" and spellName then
    local dotKey = string.lower(spellName)
    local dotInfo = CLF._dotSpells[dotKey]
    if dotInfo and dotInfo.duration then
      return now + dotInfo.duration
    end
  end
  if spellName and auraType ~= "DEBUFF" then
    local lowerName = string.lower(spellName)
    local dotInfo = CLF._dotSpells[lowerName]
    if dotInfo and dotInfo.duration then
      return now + dotInfo.duration
    end
  end
  return now + 30
end

function CLF._RebuildTargetAuras(newGUID)
  local prefix = "target:"
  for k in pairs(CLF._auraState) do
    if string.sub(k, 1, #prefix) == prefix then
      CLF._auraState[k] = nil
    end
  end
  if not newGUID then return end
  local guidDebuffs = CLF._debuffsByGUID[newGUID]
  if not guidDebuffs then return end
  local now = GetTime()
  for sid, a in pairs(guidDebuffs) do
    if a.expiration and a.expiration > now then
      local key = prefix .. sid
      CLF._auraState[key] = {
        name = a.name or "",
        spellId = a.spellId,
        stacks = a.stacks or 1,
        applied = a.applied or now,
        expiration = a.expiration,
        auraType = a.auraType or "DEBUFF",
        unit = "target",
      }
    else
      guidDebuffs[sid] = nil
    end
  end
end

function CLF.GetCurrentTargetGUID()
  if CLF._targetGUID then return CLF._targetGUID end
  return CLF._cleuTargetGUID
end

CLF._auraLog = {}
local _auraLogMax = 50

local function LogAuraEvent(subEvent, unit, spellName, spellId, stacks, auraType)
  if not CLF.debugEnabled then return end
  local entry = {
    t = GetTime(),
    ev = subEvent,
    u = unit,
    spell = tostring(spellName or "?"),
    sid = spellId,
    stacks = stacks or 0,
    aType = auraType or "?",
  }
  table.insert(CLF._auraLog, entry)
  if #CLF._auraLog > _auraLogMax then
    table.remove(CLF._auraLog, 1)
  end
  CLF.Log("AURA", string.format("%s %s on %s (id=%s stk=%d type=%s)",
    subEvent, entry.spell, unit, tostring(spellId or "?"), stacks or 0, auraType or "?"))
end

function CLF.OnAuraCLEU(subEvent, sourceGUID, destGUID, spellId, spellName, auraType)
  local playerGUID = CLF._playerGUID
  if not destGUID then return end
  local isPlayer = (destGUID == playerGUID)
  local isTarget = false
  if not isPlayer then
    local tguid = CLF._targetGUID
    local cguid = CLF._cleuTargetGUID
    isTarget = (tguid and destGUID == tguid) or (cguid and destGUID == cguid)
  end
  if not isPlayer and not isTarget then
    if sourceGUID == playerGUID then
      if Detaint then spellId = Detaint(spellId) end
      if DetaintStr then spellName = DetaintStr(spellName) or tostring(spellId or 0) end
      if DetaintStr and type(auraType) ~= "nil" then auraType = DetaintStr(auraType) end
      local entry = {
        name = spellName or "",
        spellId = spellId,
        stacks = 1,
        applied = GetTime(),
        expiration = CLF._EstimateAuraExpiration(spellName, auraType),
        auraType = auraType or "DEBUFF",
        unit = "target",
      }
      if not CLF._debuffsByGUID[destGUID] then CLF._debuffsByGUID[destGUID] = {} end
      if subEvent == "SPELL_AURA_APPLIED" or subEvent == "SPELL_AURA_REFRESH" then
        CLF._debuffsByGUID[destGUID][spellId or 0] = entry
      elseif subEvent == "SPELL_AURA_REMOVED" then
        CLF._debuffsByGUID[destGUID][spellId or 0] = nil
      elseif subEvent == "SPELL_AURA_APPLIED_DOSE" then
        local ga = CLF._debuffsByGUID[destGUID][spellId or 0]
        if ga then ga.stacks = (ga.stacks or 0) + 1 end
      elseif subEvent == "SPELL_AURA_REMOVED_DOSE" then
        local ga = CLF._debuffsByGUID[destGUID][spellId or 0]
        if ga then ga.stacks = mathMax(0, (ga.stacks or 1) - 1) end
      end
    end
    return
  end
  local unit = isPlayer and "player" or "target"
  if Detaint then spellId = Detaint(spellId) end
  if DetaintStr then spellName = DetaintStr(spellName) or tostring(spellId or 0) end
  if DetaintStr and type(auraType) ~= "nil" then auraType = DetaintStr(auraType) end
  local key
  local useNameKey = (isPlayer and (spellId == nil or spellId == 0) and spellName and spellName ~= "" and spellName ~= "0")
  if useNameKey then
    key = "player:name:" .. spellName
  else
    key = unit .. ":" .. (spellId or 0)
  end
  local isDebuff = (unit == "target")
  if subEvent == "SPELL_AURA_APPLIED" or subEvent == "SPELL_AURA_REFRESH" then
    LogAuraEvent(subEvent, unit, spellName, spellId, 1, auraType)
    local expiration = CLF._EstimateAuraExpiration(spellName, auraType)
    local entry = {
      name = spellName or "",
      spellId = spellId,
      stacks = 1,
      applied = GetTime(),
      expiration = expiration,
      auraType = auraType or "BUFF",
      unit = unit,
    }
    CLF._auraState[key] = entry
    if spellId and type(spellId) == "number" and spellId > 0 and spellName and spellName ~= "" and spellName ~= tostring(spellId) then
      local lnm = string.lower(spellName)
      if not CLF._spellNameToId[lnm] then
        CLF._spellNameToId[lnm] = spellId
      end
      if not CLF._spellIdToName[spellId] then
        CLF._spellIdToName[spellId] = lnm
      end
    end
    if isPlayer and spellName and spellName ~= "" then
      local lowerBuff = string.lower(spellName)
      local isEclipseBuff = false
      local eclipseType = nil
      if string.find(lowerBuff, "eclipse", 1, true) then
        if string.find(lowerBuff, "lunar", 1, true) then
          isEclipseBuff = true
          eclipseType = "lunar"
        elseif string.find(lowerBuff, "solar", 1, true) then
          isEclipseBuff = true
          eclipseType = "solar"
        elseif lowerBuff == "eclipse" then
          isEclipseBuff = true
          eclipseType = "both"
        end
      end
      if string.find(lowerBuff, "incarnation", 1, true) or string.find(lowerBuff, "celestial alignment", 1, true) then
        isEclipseBuff = true
        eclipseType = "both"
      end
      if isEclipseBuff then
        if not CLF._eclipseActiveUntil then CLF._eclipseActiveUntil = {} end
        local dur = 15
        if string.find(lowerBuff, "incarnation", 1, true) or string.find(lowerBuff, "celestial alignment", 1, true) then
          dur = 20
        end
        if expiration and expiration > 0 then
          dur = expiration - GetTime()
          if dur < 0 then dur = 15 end
        end
        local until_time = GetTime() + dur
        if eclipseType == "both" then
          CLF._eclipseActiveUntil.lunar = until_time
          CLF._eclipseActiveUntil.solar = until_time
        elseif eclipseType then
          CLF._eclipseActiveUntil[eclipseType] = until_time
        end
        if CLF.debugEnabled then
          CLF.Log("ECLIPSE", "AURA_APPLIED eclipse buff detected: " .. lowerBuff .. " type=" .. tostring(eclipseType) .. " dur=" .. string.format("%.1f", dur))
        end
      end
    end
    if isDebuff and destGUID then
      if not CLF._debuffsByGUID[destGUID] then CLF._debuffsByGUID[destGUID] = {} end
      CLF._debuffsByGUID[destGUID][spellId or 0] = entry
    end
  elseif subEvent == "SPELL_AURA_APPLIED_DOSE" then
    local a = CLF._auraState[key]
    if a then
      a.stacks = (a.stacks or 0) + 1
      LogAuraEvent(subEvent, unit, spellName, spellId, a.stacks, auraType)
    end
    if isDebuff and destGUID then
      local gd = CLF._debuffsByGUID[destGUID]
      if gd then
        local ga = gd[spellId or 0]
        if ga then ga.stacks = (ga.stacks or 0) + 1 end
      end
    end
  elseif subEvent == "SPELL_AURA_REMOVED_DOSE" then
    local a = CLF._auraState[key]
    if a then
      a.stacks = mathMax(0, (a.stacks or 1) - 1)
    end
    if isDebuff and destGUID then
      local gd = CLF._debuffsByGUID[destGUID]
      if gd then
        local ga = gd[spellId or 0]
        if ga then ga.stacks = mathMax(0, (ga.stacks or 1) - 1) end
      end
    end
  elseif subEvent == "SPELL_AURA_REMOVED" then
    LogAuraEvent(subEvent, unit, spellName, spellId, 0, auraType)
    CLF._auraState[key] = nil
    if isPlayer and spellName and spellName ~= "" then
      local lowerBuff = string.lower(spellName)
      if CLF._eclipseActiveUntil then
        if string.find(lowerBuff, "eclipse", 1, true) then
          if string.find(lowerBuff, "lunar", 1, true) then
            CLF._eclipseActiveUntil.lunar = nil
          elseif string.find(lowerBuff, "solar", 1, true) then
            CLF._eclipseActiveUntil.solar = nil
          elseif lowerBuff == "eclipse" then
            CLF._eclipseActiveUntil.lunar = nil
            CLF._eclipseActiveUntil.solar = nil
          end
        end
        if string.find(lowerBuff, "incarnation", 1, true) or string.find(lowerBuff, "celestial alignment", 1, true) then
          CLF._eclipseActiveUntil.lunar = nil
          CLF._eclipseActiveUntil.solar = nil
        end
      end
    end
    if isDebuff and destGUID then
      local gd = CLF._debuffsByGUID[destGUID]
      if gd then gd[spellId or 0] = nil end
    end
  elseif subEvent == "SPELL_AURA_REFRESH" then
    local expiration = CLF._EstimateAuraExpiration(spellName, auraType)
    local a = CLF._auraState[key]
    if a then
      if a.expiration and a.expiration > expiration then
        expiration = a.expiration
      end
      local isPlayerRecast = isPlayer or (sourceGUID == CLF._playerGUID)
      if isPlayerRecast then
        a.applied = GetTime()
      end
      a.expiration = expiration
    else
      a = {
        name = spellName or "",
        spellId = spellId,
        stacks = 1,
        applied = GetTime(),
        expiration = expiration,
        auraType = auraType or "BUFF",
        unit = unit,
      }
      CLF._auraState[key] = a
    end
    if isDebuff and destGUID then
      if not CLF._debuffsByGUID[destGUID] then CLF._debuffsByGUID[destGUID] = {} end
      CLF._debuffsByGUID[destGUID][spellId or 0] = a
    end
  end
end

function CLF.FindAuraInternal(unit, spellId, searchName)
  if spellId then
    local key = unit .. ":" .. spellId
    local a = CLF._auraState[key]
    if a then
      return a.name, a.stacks or 0, a.expiration or 0
    end
  end
  if searchName then
    local lowerSearch = string.lower(searchName)
    if not spellId then
      local resolved = CLF._spellNameToId[lowerSearch]
      if resolved then
        local key = unit .. ":" .. resolved
        local a = CLF._auraState[key]
        if a then
          return a.name, a.stacks or 0, a.expiration or 0
        end
      end
    end
    local nameKey = unit .. ":name:" .. searchName
    local na = CLF._auraState[nameKey]
    if na then
      return na.name, na.stacks or 0, na.expiration or 0
    end
    local prefix = unit .. ":"
    for k, a in pairs(CLF._auraState) do
      if string.sub(k, 1, #prefix) == prefix then
        local lowerName = string.lower(a.name or "")
        if lowerName == lowerSearch or string.find(lowerName, lowerSearch, 1, true) then
          return a.name, a.stacks or 0, a.expiration or 0
        end
        if a.spellId and CLF._spellIdToName[a.spellId] == lowerSearch then
          return a.name, a.stacks or 0, a.expiration or 0
        end
      end
    end
  end
  return nil, 0, 0
end

function CLF.ResetAuraState()
  wipe(CLF._auraState)
  wipe(CLF._debuffsByGUID)
  CLF._cleuTargetGUID = nil
end

function CLF.ScanTargetDebuffs()
  local targetGUID = CLF._targetGUID
  if not targetGUID then
    local prefix = "target:"
    for k in pairs(CLF._auraState) do
      if string.sub(k, 1, #prefix) == prefix then
        CLF._auraState[k] = nil
      end
    end
    return
  end
  local inCombat = CLF._inCombat
  if inCombat then return end
  local oldKeys = {}
  local prefix = "target:"
  for k in pairs(CLF._auraState) do
    if string.sub(k, 1, #prefix) == prefix then
      oldKeys[k] = true
    end
  end
  for k in pairs(oldKeys) do
    CLF._auraState[k] = nil
  end
  if not C_UnitAuras then return end
  local getDebuff = C_UnitAuras.GetDebuffDataByIndex
  if not getDebuff then return end
  for i = 1, 40 do
    local ok, aura = pcall(getDebuff, "target", i)
    if not ok or type(aura) ~= "table" then break end
    local sid = aura.spellId
    if type(sid) ~= "nil" then
      local rawSid = Detaint and Detaint(sid) or nil
      if not rawSid then rawSid = 0 end
      local rawName = ""
      if type(aura.name) ~= "nil" then
        rawName = DetaintStr and DetaintStr(aura.name) or ""
      end
      local rawExp = 0
      if type(aura.expirationTime) ~= "nil" then
        rawExp = Detaint and Detaint(aura.expirationTime) or 0
      end
      local rawStacks = 0
      if type(aura.applications) ~= "nil" then
        rawStacks = Detaint and Detaint(aura.applications) or 0
      end
      local key = "target:" .. rawSid
      CLF._auraState[key] = {
        name = rawName,
        spellId = rawSid,
        stacks = rawStacks,
        applied = GetTime(),
        expiration = rawExp,
        auraType = "DEBUFF",
        unit = "target",
      }
    end
  end
end

function CLF.ScanPlayerBuffs()
  local inCombat = CLF._inCombat
  if not inCombat then
    local oldKeys = {}
    local prefix = "player:"
    for k in pairs(CLF._auraState) do
      if string.sub(k, 1, #prefix) == prefix then
        oldKeys[k] = true
      end
    end
    for k in pairs(oldKeys) do
      CLF._auraState[k] = nil
    end
  end
  if not C_UnitAuras then return end
  local getBuff = C_UnitAuras.GetBuffDataByIndex
  if not getBuff then return end
  local seenKeys = {}
  for i = 1, 40 do
    local ok, aura = pcall(getBuff, "player", i)
    if not ok or type(aura) ~= "table" then break end
    local sid = aura.spellId
    if type(sid) ~= "nil" then
      local rawSid = Detaint and Detaint(sid) or nil
      if not rawSid then rawSid = 0 end
      local rawName = ""
      if type(aura.name) ~= "nil" then
        rawName = DetaintStr and DetaintStr(aura.name) or ""
      end
      local rawExp = 0
      if type(aura.expirationTime) ~= "nil" then
        rawExp = Detaint and Detaint(aura.expirationTime) or 0
      end
      local rawStacks = 0
      if type(aura.applications) ~= "nil" then
        rawStacks = Detaint and Detaint(aura.applications) or 0
      end
      local useNameKey = (rawSid == 0 and rawName ~= "")
      local key
      if useNameKey then
        key = "player:name:" .. rawName
      else
        key = "player:" .. rawSid
      end
      seenKeys[key] = true
      local entry = {
        name = rawName,
        spellId = rawSid,
        stacks = rawStacks,
        applied = GetTime(),
        expiration = rawExp,
        auraType = "BUFF",
        unit = "player",
      }
      if inCombat then
        local existing = CLF._auraState[key]
        if existing then
          if rawExp > 0 then existing.expiration = rawExp end
          if rawStacks > 0 then existing.stacks = rawStacks end
          if rawName ~= "" then existing.name = rawName end
        else
          CLF._auraState[key] = entry
        end
        if useNameKey and rawSid == 0 then
          local idKey = "player:0"
          if CLF._auraState[idKey] then
            CLF._auraState[idKey] = nil
          end
        end
      else
        CLF._auraState[key] = entry
        if rawName ~= "" and rawSid > 0 then
          local lowerName = string.lower(rawName)
          if not CLF._spellNameToId[lowerName] then
            CLF._spellNameToId[lowerName] = rawSid
          end
          if not CLF._spellIdToName[rawSid] then
            CLF._spellIdToName[rawSid] = lowerName
          end
        end
      end
    end
  end
  if inCombat then
    for k in pairs(CLF._auraState) do
      if string.sub(k, 1, 7) == "player:" and not seenKeys[k] then
        CLF._auraState[k] = nil
      end
    end
  end
  for k, a in pairs(CLF._auraState) do
    if string.sub(k, 1, 7) == "player:" and a.name and a.name ~= "" then
      local lowerBuff = string.lower(a.name)
      local eclipseType = nil
      if string.find(lowerBuff, "eclipse", 1, true) then
        if string.find(lowerBuff, "lunar", 1, true) then
          eclipseType = "lunar"
        elseif string.find(lowerBuff, "solar", 1, true) then
          eclipseType = "solar"
        elseif lowerBuff == "eclipse" then
          eclipseType = "both"
        end
      end
      if string.find(lowerBuff, "incarnation", 1, true) or string.find(lowerBuff, "celestial alignment", 1, true) then
        eclipseType = "both"
      end
      if eclipseType then
        if not CLF._eclipseActiveUntil then CLF._eclipseActiveUntil = {} end
        local until_time
        if a.expiration and a.expiration > 0 then
          until_time = a.expiration
        else
          local dur = 15
          if string.find(lowerBuff, "incarnation", 1, true) or string.find(lowerBuff, "celestial alignment", 1, true) then
            dur = 20
          end
          until_time = GetTime() + dur
        end
        if eclipseType == "both" then
          CLF._eclipseActiveUntil.lunar = until_time
          CLF._eclipseActiveUntil.solar = until_time
        else
          CLF._eclipseActiveUntil[eclipseType] = until_time
        end
        if CLF.debugEnabled then
          CLF.Log("ECLIPSE", "ScanPlayerBuffs detected eclipse buff: " .. lowerBuff .. " type=" .. eclipseType .. " until=" .. string.format("%.1f", until_time - GetTime()) .. "s")
        end
      end
    end
  end
end

-- ── §H2e: Internal Casting Tracker ──
-- Tracks player/target casting state via CLEU events.
-- Player: SPELL_CAST_START/STOP/SUCCEEDED/FAILED/INTERRUPTED
-- Target: same events filtered by target GUID, plus DurationObject fallback
CLF._castState = { player = {}, target = {} }

function CLF.OnCastCLEU(subEvent, sourceGUID, spellId, spellName)
  local playerGUID = CLF._playerGUID
  local unit = nil
  if sourceGUID == playerGUID then
    unit = "player"
  elseif (CLF._targetGUID and sourceGUID == CLF._targetGUID) or (CLF._cleuTargetGUID and sourceGUID == CLF._cleuTargetGUID) then
    unit = "target"
  end
  if not unit then return end
  local cs = CLF._castState[unit]
  if subEvent == "SPELL_CAST_START" then
    cs.casting = true
    cs.spellId = spellId
    cs.spellName = spellName
    cs.startTime = GetTime()
    cs.duration = nil
    cs.notInterruptible = false
    if unit == "player" and UnitCastingInfo then
      pcall(function()
        local name, text, texture, startMS, endMS = UnitCastingInfo("player")
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
      local bookCT = CLF.SpellBookCastTime(spellName)
      if bookCT and bookCT > 0 then
        cs.duration = bookCT
      else
        local entry = CLF._spellBook[string.lower(NormalizeName(spellName or ""))]
        if entry and entry.baseCastTime and entry.baseCastTime > 0 then
          cs.duration = entry.baseCastTime / CLF.HasteMultiplier()
        else
          cs.duration = 1.5
        end
      end
    end
  elseif subEvent == "SPELL_CAST_SUCCESS" or subEvent == "SPELL_CAST_FAILED" then
    if cs.spellId == spellId then
      if unit == "player" and subEvent == "SPELL_CAST_SUCCESS" and cs.casting and cs.startTime then
        pcall(CLF.ObserveCastTime, cs.spellName, cs.startTime, GetTime())
      end
      cs.casting = false
      cs.spellId = nil
      cs.spellName = nil
    end
  elseif subEvent == "SPELL_INTERRUPT" then
    cs.casting = false
    cs.spellId = nil
    cs.spellName = nil
  end
end

function CLF.CacheSpellCosts()
  if not C_Spell or not C_Spell.GetSpellPowerCost then return end
  local sData = CLF._spellData or {}
  CLF._spellCosts = CLF._spellCosts or {}
  CLF._spellIdToName = CLF._spellIdToName or {}
  local specPT = CLF.GetSpecPowerType()
  for spellKey, data in pairs(sData) do
    if data then
      if data.id and type(data.id) == "number" then
        CLF._spellIdToName[data.id] = spellKey
      end
      if not CLF._spellCosts[spellKey] then
        local ok, costs = pcall(C_Spell.GetSpellPowerCost, spellKey)
        if ok and costs then
          for _, ci in ipairs(costs) do
            if ci.cost and type(ci.cost) == "number" and ci.cost > 0 then
              if specPT ~= nil and ci.type == specPT then
                CLF._spellCosts[spellKey] = ci.cost
                break
              elseif specPT == nil then
                CLF._spellCosts[spellKey] = ci.cost
                break
              end
            end
          end
        end
      end
    end
  end
  local apl = CLF._filteredAPL
  if apl then
    for _, bucket in pairs(apl) do
      if type(bucket) == "table" then
        for _, entry in ipairs(bucket) do
          if entry.spellId then
            if entry.name then
              CLF._spellIdToName[entry.spellId] = string.lower(entry.name)
            end
            if not CLF._spellCosts[entry.spellId] then
              local ok2, costs2 = pcall(C_Spell.GetSpellPowerCost, entry.spellId)
              if ok2 and costs2 then
                for _, ci2 in ipairs(costs2) do
                  if ci2.cost and type(ci2.cost) == "number" and ci2.cost > 0 then
                    if specPT ~= nil and ci2.type == specPT then
                      CLF._spellCosts[entry.spellId] = ci2.cost
                      break
                    elseif specPT == nil then
                      CLF._spellCosts[entry.spellId] = ci2.cost
                      break
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

function CLF.CacheChargeInfo()
  if not C_Spell or not C_Spell.GetSpellCharges then return end
  CLF._chargeState = CLF._chargeState or {}
  CLF._chargeSpellIds = CLF._chargeSpellIds or {}
  local sData = CLF._spellData or {}
  for spellKey, _ in pairs(sData) do
    pcall(function()
      local info = C_Spell.GetSpellCharges(spellKey)
      if info and info.maxCharges then
        local mc = info.maxCharges
        if not (issecretvalue and issecretvalue(mc)) and mc > 1 then
          local cur = info.currentCharges or 0
          local curTainted = issecretvalue and issecretvalue(cur)
          if curTainted then
            CLF.Charges.SetFromAPI(spellKey, nil, mc, nil, nil, nil, nil)
          else
            CLF.Charges.SetFromAPI(spellKey, cur, mc, nil, nil, nil, nil)
          end
        end
      end
    end)
  end
  local apl = CLF._filteredAPL
  if apl then
    for _, bucket in pairs(apl) do
      if type(bucket) == "table" then
        for _, e in ipairs(bucket) do
          if e.spellId then
            local cleanKey = e.cleanKey or string.lower(e.spellName or "")
            pcall(function()
              local info2 = C_Spell.GetSpellCharges(e.spellId)
              if info2 and info2.maxCharges then
                local mc2 = info2.maxCharges
                if not (issecretvalue and issecretvalue(mc2)) and mc2 > 1 then
                  local cur2 = info2.currentCharges or 0
                  local cur2Tainted = issecretvalue and issecretvalue(cur2)
                  if cur2Tainted then
                    CLF.Charges.SetFromAPI(cleanKey, nil, mc2, nil, nil, nil, e.spellId)
                  else
                    CLF.Charges.SetFromAPI(cleanKey, cur2, mc2, nil, nil, nil, e.spellId)
                  end
                end
              end
            end)
          end
        end
      end
    end
  end
end

function CLF.CalibrateHealth()
end

-- ── §H3: Snapshot Cache ──
-- Performance optimization: sample all game state ONCE per tick, store in CLF._snap.
-- All APL condition evaluations read from the snapshot, not raw APIs.
-- This eliminates O(N) API calls per spell candidate per tick.
function CLF.GetSpecPowerType()
  local config = CLF_Config or CLF_DefaultConfig
  if config and config.spec then
    return config.spec.powerTypeId
  end
  return nil
end
local GetSpecPowerType = CLF.GetSpecPowerType

function CLF.GetSecondaryPowerType()
  local config = CLF_Config or CLF_DefaultConfig
  if config and config.spec then
    return config.spec.secondaryPowerTypeId
  end
  return nil
end

CLF._snap = {}
local snap = CLF._snap

function CLF.RefreshSnapshot()
  local now = GetTime()
  if snap.time and (now - snap.time) < 0.03 then return end
  snap.time = now
  CLF._cachedForm = nil
  local inCombatNow = CLF._inCombat == true
  if not inCombatNow and (now - (CLF._lastHealthCal or 0)) > 1.0 then
    CLF._lastHealthCal = now
    if not CLF._auraResolveAttempted then
      pcall(CLF.ResolveConditionAuraIds)
    end
    local rt = CLF._resTracker
    if rt and not rt.lastCalibrate then
      pcall(CLF.CalibrateResource)
    end
  end
  local pt = GetSpecPowerType()
  local POWER_NAMES = { [0]="Mana",[1]="Rage",[2]="Focus",[3]="Energy",[4]="Combo Points",[5]="Runes",[6]="Runic Power",[7]="Soul Shards",[8]="Lunar Power",[9]="Holy Power",[11]="Maelstrom",[12]="Chi",[13]="Insanity",[16]="Arcane Charges",[17]="Fury",[19]="Pain" }
  snap.powerType = POWER_NAMES[pt] or tostring(pt or "?")
  snap.power = CLF._resTracker and SafeNum(CLF._resTracker.current, 0) or 0
  snap.powerMax = CLF._resTracker and SafeNum(CLF._resTracker.max, 1) or 1
  local rawPetE = UnitExists and UnitExists("pet")
  local petExists = false
  if rawPetE ~= nil then
    if issecretvalue and issecretvalue(rawPetE) then
      petExists = true
    else
      petExists = rawPetE and true or false
    end
  end
  local petDead = false
  if petExists then
    local rawPD = UnitIsDead and UnitIsDead("pet")
    if rawPD ~= nil and not (issecretvalue and issecretvalue(rawPD)) then
      petDead = rawPD and true or false
    end
  end
  snap.petAlive = petExists and not petDead
  local rawTargetE = UnitExists and UnitExists("target")
  local hasTarget = false
  if rawTargetE ~= nil then
    if issecretvalue and issecretvalue(rawTargetE) then
      hasTarget = true
    else
      hasTarget = rawTargetE and true or false
    end
  end
  snap.hasTarget = hasTarget
  local gcdElapsed, gcdDuration = CLF.GetGCD()
  snap.gcdRemaining = (gcdDuration > 0) and mathMax(0, gcdDuration - gcdElapsed) or 0
  snap.gcdMax = CLF.GCDMax()
  local rawHP = UnitHealth and UnitHealth("player") or 0
  local rawHPMax = UnitHealthMax and UnitHealthMax("player") or 1
  local hpSecret = issecretvalue and issecretvalue(rawHP)
  local hpVal = hpSecret and 0 or (tonumber(rawHP) or 0)
  local hpMax = (issecretvalue and issecretvalue(rawHPMax)) and 1 or (tonumber(rawHPMax) or 1)
  if hpSecret then
    snap.healthPct = 100
  elseif hpMax > 0 then
    local pct = (hpVal / hpMax) * 100
    snap.healthPct = mathMax(0, mathMin(100, pct))
  else
    snap.healthPct = 100
  end

  -- Target health (taint-safe)
  if snap.hasTarget then
    local rawTHP = UnitHealth and UnitHealth("target") or 0
    local rawTHPMax = UnitHealthMax and UnitHealthMax("target") or 1
    local tSecret = issecretvalue and issecretvalue(rawTHP)
    local tVal = tSecret and 0 or (tonumber(rawTHP) or 0)
    local tMax = (issecretvalue and issecretvalue(rawTHPMax)) and 1 or (tonumber(rawTHPMax) or 1)
    if tSecret then
      snap.targetHealthPct = 100
    elseif tMax > 0 then
      snap.targetHealthPct = mathMax(0, mathMin(100, (tVal / tMax) * 100))
    else
      snap.targetHealthPct = 100
    end
  else
    snap.targetHealthPct = 100
  end

  -- Secondary resource (combo points, holy power, soul shards, etc.)
  local secPT = CLF.GetSecondaryPowerType()
  if secPT then
    if UnitPower then
      local rawSec = UnitPower("player", secPT)
      snap.secondaryPower = SafeNum(rawSec, 0)
    else
      snap.secondaryPower = 0
    end
    if UnitPowerMax then
      local rawSecMax = UnitPowerMax("player", secPT)
      snap.secondaryPowerMax = SafeNum(rawSecMax, 0)
    else
      snap.secondaryPowerMax = 0
    end
  else
    snap.secondaryPower = 0
    snap.secondaryPowerMax = 0
  end

  -- Movement state
  local moving = false
  if GetUnitSpeed then
    local rawSpeed = GetUnitSpeed("player")
    if rawSpeed and not (issecretvalue and issecretvalue(rawSpeed)) then
      moving = (tonumber(rawSpeed) or 0) > 0
    end
  end
  snap.moving = moving
  if moving then
    if not snap.moveStartTime then snap.moveStartTime = now end
    snap.moveDuration = now - snap.moveStartTime
  else
    snap.moveStartTime = nil
    snap.moveDuration = 0
    if not snap.stopTime then snap.stopTime = now end
    snap.standingDuration = now - snap.stopTime
  end
  if not moving then snap.stopTime = snap.stopTime or now end

  -- Form/Stance (taint-safe)
  if GetShapeshiftForm then
    local rawForm = GetShapeshiftForm()
    if rawForm and not (issecretvalue and issecretvalue(rawForm)) then
      snap.form = tonumber(rawForm) or 0
    end
  end
end

function CLF.Power()
  local rt = CLF._resTracker
  if not rt then return 0 end
  return SafeNum(rt.current, 0)
end

function CLF.PowerMax()
  local rt = CLF._resTracker
  if not rt then return 1 end
  return SafeNum(rt.max, 1)
end

function CLF.PowerPct()
  local rt = CLF._resTracker
  if not rt then return 0 end
  local cur = SafeNum(rt.current, 0)
  local mx = SafeNum(rt.max, 1)
  if mx == 0 then return 0 end
  return (cur / mx) * 100
end

function CLF.SecondaryPower()
  return snap.secondaryPower or 0
end

function CLF.SecondaryPowerMax()
  return snap.secondaryPowerMax or 0
end

function CLF.MoveDuration()
  return snap.moveDuration or 0
end

function CLF.StandingDuration()
  return snap.standingDuration or 0
end

function CLF.GetForm()
  return snap.form or 0
end

function CLF.ComboPoints()
  local secPT = CLF.GetSecondaryPowerType()
  if secPT == 4 then
    if UnitPower then
      local raw = UnitPower("player", 4)
      return SafeNum(raw, 0)
    end
    return 0
  end
  local pt = CLF.GetSpecPowerType()
  if pt == 4 then
    local rt = CLF._resTracker
    return rt and SafeNum(rt.current, 0) or 0
  end
  return 0
end

function CLF.PlayerHealthPct()
  return snap.healthPct or 100
end

function CLF.TargetHealthPct()
  return snap.targetHealthPct or 100
end

function CLF.PetAlive()
  return snap.petAlive or false
end

-- ── §H4: Aura Lookup (Buff/Debuff System) ──
-- Searches for auras by name using AuraUtil (11.0+) with UnitBuff/UnitDebuff fallback.
-- Name matching is case-insensitive substring (handles localized & abbreviated names).
-- Returns: name, stack count, expiration time (or nil if not found).

local _auraCollect = {}
local _auraCount = 0

CLF._spellNameToId = CLF._spellNameToId or {}

local function FindAura(unit, searchName, filter)
  local cleanName = NormalizeName(searchName)
  local lowerClean = string.lower(cleanName)

  if CLF._inCombat == true then
    local cachedSid = CLF._spellNameToId[lowerClean]
    local name, stacks, applied = CLF.FindAuraInternal(unit, cachedSid, cleanName)
    if name then
      return name, stacks, applied
    end
    return nil, 0, 0
  end

  local spellIdForSearch = CLF._spellNameToId[lowerClean]
  if not spellIdForSearch then
    if C_Spell and C_Spell.GetSpellInfo then
      local ok, info = pcall(C_Spell.GetSpellInfo, cleanName)
      if ok and type(info) == "table" and info.spellID then
        spellIdForSearch = Detaint(info.spellID)
      end
    end
    if not spellIdForSearch and GetSpellInfo then
      local ok, _, _, _, _, _, sid = pcall(GetSpellInfo, cleanName)
      if ok and sid then spellIdForSearch = Detaint(sid) end
    end
    if spellIdForSearch then
      CLF._spellNameToId[lowerClean] = spellIdForSearch
    end
  end

  if C_UnitAuras then
    if unit == "player" and filter ~= "HARMFUL" and spellIdForSearch and C_UnitAuras.GetPlayerAuraBySpellID then
      local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellIdForSearch)
      if ok and type(aura) == "table" then
        local nameStr = DetaintStr(aura.name) or cleanName
        local count = Detaint(aura.applications) or 0
        local exp = Detaint(aura.expirationTime) or 0
        return nameStr, count, exp
      end
    end

    local getBuff = C_UnitAuras.GetBuffDataByIndex
    local getDebuff = C_UnitAuras.GetDebuffDataByIndex
    local hasSpecific = (filter == "HARMFUL") and getDebuff or getBuff
    local useGeneric = C_UnitAuras.GetAuraDataByIndex
    if hasSpecific or useGeneric then
      local nilRun = 0
      for i = 1, 40 do
        local ok, aura
        if hasSpecific then
          ok, aura = pcall(hasSpecific, unit, i)
        else
          ok, aura = pcall(useGeneric, unit, i, filter)
        end
        if not ok then break end
        if type(aura) ~= "table" then
          nilRun = nilRun + 1
          if nilRun > 2 then break end
        else
          nilRun = 0
          local rawName = aura.name
          if type(rawName) ~= "nil" then
            local auraSpellId = Detaint(aura.spellId)
            if spellIdForSearch and auraSpellId and auraSpellId == spellIdForSearch then
              local count = Detaint(aura.applications) or 0
              local exp = Detaint(aura.expirationTime) or 0
              local nameStr = DetaintStr(rawName) or cleanName
              return nameStr, count, exp
            end

            local nameStr = DetaintStr(rawName)
            if nameStr then
              local lowerName = string.lower(nameStr)
              if string.find(lowerName, lowerClean, 1, true) then
                local count = Detaint(aura.applications) or 0
                local exp = Detaint(aura.expirationTime) or 0
                return nameStr, count, exp
              end
            end
          end
        end
      end
      return nil, 0, 0
    end
  end

  if AuraUtil and AuraUtil.ForEachAura then
    _auraCount = 0
    AuraUtil.ForEachAura(unit, filter, nil, function(aura)
      _auraCount = _auraCount + 1
      local nameStr = DetaintStr(aura.name)
      _auraCollect[_auraCount] = {
        n = nameStr or "",
        c = Detaint(aura.applications) or 0,
        e = Detaint(aura.expirationTime) or 0,
        id = Detaint(aura.spellId),
      }
    end, true)
    for i = 1, _auraCount do
      local entry = _auraCollect[i]
      if spellIdForSearch and entry.id and entry.id == spellIdForSearch then
        return entry.n ~= "" and entry.n or cleanName, entry.c, entry.e
      end
      if entry.n ~= "" then
        local lowerName = string.lower(entry.n)
        if string.find(lowerName, lowerClean, 1, true) then
          return entry.n, entry.c, entry.e
        end
      end
    end
    return nil, 0, 0
  end

  return nil, 0, 0
end

local WEAPON_ENCHANT_BUFFS = {
  flametongue_weapon = true,
  windfury_weapon = true,
}

local function CheckWeaponEnchant()
  if not GetWeaponEnchantInfo then return false end
  local ok, hasMH = pcall(GetWeaponEnchantInfo)
  if ok and hasMH then return true end
  return false
end

function CLF.BuffUp(buffName)
  local name = FindAura("player", buffName, "HELPFUL")
  if name ~= nil then return true end
  local lowerBuff = string.lower(NormalizeName(buffName))
  local aliases = CLF._spellAliases and CLF._spellAliases[lowerBuff]
  if aliases then
    for _, alt in ipairs(aliases) do
      if FindAura("player", alt, "HELPFUL") then return true end
    end
  end
  local rawBuff = string.gsub(string.lower(buffName), " ", "_")
  if WEAPON_ENCHANT_BUFFS[rawBuff] then
    return CheckWeaponEnchant()
  end
  return false
end

function CLF.BuffRemains(buffName)
  local _, _, expTime = FindAura("player", buffName, "HELPFUL")
  if expTime and expTime > 0 then
    return mathMax(0, expTime - GetTime())
  end
  local aliases = CLF._spellAliases and CLF._spellAliases[string.lower(NormalizeName(buffName))]
  if aliases then
    for _, alt in ipairs(aliases) do
      local _, _, aExp = FindAura("player", alt, "HELPFUL")
      if aExp and aExp > 0 then return mathMax(0, aExp - GetTime()) end
    end
  end
  local rawBuff = string.gsub(string.lower(buffName), " ", "_")
  if WEAPON_ENCHANT_BUFFS[rawBuff] and GetWeaponEnchantInfo then
    local wOk, wHas, wExp = pcall(GetWeaponEnchantInfo)
    if wOk and wHas then
      if wExp and wExp > 0 then return wExp / 1000 end
      return 3600
    end
  end
  return 0
end

function CLF.BuffStacks(buffName)
  local _, count = FindAura("player", buffName, "HELPFUL")
  if count and count > 0 then return count end
  local aliases = CLF._spellAliases and CLF._spellAliases[string.lower(NormalizeName(buffName))]
  if aliases then
    for _, alt in ipairs(aliases) do
      local _, ac = FindAura("player", alt, "HELPFUL")
      if ac and ac > 0 then return ac end
    end
  end
  return count or 0
end

function CLF.DebuffUp(debuffName)
  local name = FindAura("target", debuffName, "HARMFUL")
  return name ~= nil
end

function CLF.DebuffRemains(debuffName)
  local _, _, expTime = FindAura("target", debuffName, "HARMFUL")
  if expTime and expTime > 0 then
    return mathMax(0, expTime - GetTime())
  end
  return 0
end

-- ── §H4b: Eclipse Buff Detection (Balance Druid) ──
-- In 12.0, Eclipse (Solar/Lunar) are CASTABLE SPELLS (Instant, 32s recharge,
-- Max 2 Charges) that apply a buff when cast. They are treated identically to
-- any other CD (Fury of Elune, Incarnation, etc.) by the generic system.
-- SimC APL handles all Eclipse logic via conditions (eclipse.in_none,
-- buff.eclipse_solar.up, cooldown.lunar_eclipse.ready, etc.).
-- This section ONLY detects the Eclipse BUFF state for condition evaluation.
-- Eclipse detection: CLEU spell names are tainted in 12.0, so name-based
-- detection on _auraState fails. Strategy:
-- 1. Scan ALL player buffs via GetAuraDataByIndex (clean outside combat)
--    to LEARN the real Eclipse buff spell IDs at runtime
-- 2. In combat, use learned IDs to check _auraState (CLEU-populated)
-- 3. Also do a live GetAuraDataByIndex scan as fallback (may be tainted
--    in combat but pcall-safe)
-- Cached per tick (0.1s) for performance.
CLF._eclipseCache = nil
CLF._eclipseCacheTime = 0
CLF._eclipseBuffIds = { solar = {}, lunar = {} }
CLF._eclipseIdScanDone = false

function CLF._LearnEclipseBuffId(which, sid)
  if not sid or sid == 0 then return end
  local list = CLF._eclipseBuffIds[which]
  if not list then return end
  for _, v in ipairs(list) do
    if v == sid then return end
  end
  list[#list + 1] = sid
  if CLF.debugEnabled then
    CLF.Log("ECLIPSE", "Learned " .. which .. " eclipse buff ID: " .. sid)
  end
end

function CLF._ScanPlayerBuffsForEclipse()
  if not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex then return end
  local idx = 1
  while idx <= 40 do
    local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", idx, "HELPFUL")
    if not ok or not aura then break end
    local nm = aura.name
    local sid = aura.spellId
    local nmOk = nm and type(nm) == "string" and nm ~= ""
    local sidOk = sid and type(sid) == "number" and sid > 0 and not (issecretvalue and issecretvalue(sid))
    if nmOk then
      local lower = string.lower(nm)
      if string.find(lower, "eclipse", 1, true) then
        if string.find(lower, "solar", 1, true) then
          if sidOk then CLF._LearnEclipseBuffId("solar", sid) end
          CLF._eclipseCache = CLF._eclipseCache or { solar = false, lunar = false }
          CLF._eclipseCache.solar = true
        elseif string.find(lower, "lunar", 1, true) then
          if sidOk then CLF._LearnEclipseBuffId("lunar", sid) end
          CLF._eclipseCache = CLF._eclipseCache or { solar = false, lunar = false }
          CLF._eclipseCache.lunar = true
        else
          local desc = aura.description
          if desc and type(desc) == "string" then
            local dLower = string.lower(desc)
            if string.find(dLower, "nature", 1, true) or string.find(dLower, "wrath", 1, true) then
              if sidOk then CLF._LearnEclipseBuffId("solar", sid) end
              CLF._eclipseCache = CLF._eclipseCache or { solar = false, lunar = false }
              CLF._eclipseCache.solar = true
            elseif string.find(dLower, "arcane", 1, true) or string.find(dLower, "starfire", 1, true) then
              if sidOk then CLF._LearnEclipseBuffId("lunar", sid) end
              CLF._eclipseCache = CLF._eclipseCache or { solar = false, lunar = false }
              CLF._eclipseCache.lunar = true
            end
          end
        end
      end
    end
    idx = idx + 1
  end
end

function CLF._UpdateEclipseState()
  local now = GetTime()
  if CLF._eclipseCache and (now - CLF._eclipseCacheTime) < 0.1 then return end
  CLF._eclipseCacheTime = now
  CLF._eclipseCache = { solar = false, lunar = false }
  for _, sid in ipairs(CLF._eclipseBuffIds.solar) do
    if CLF._auraState["player:" .. sid] then CLF._eclipseCache.solar = true end
  end
  for _, sid in ipairs(CLF._eclipseBuffIds.lunar) do
    if CLF._auraState["player:" .. sid] then CLF._eclipseCache.lunar = true end
  end
  if CLF._eclipseCache.solar and CLF._eclipseCache.lunar then return end
  if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
    if not CLF._eclipseCache.solar then
      for _, sid in ipairs(CLF._eclipseBuffIds.solar) do
        local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, sid)
        if ok and type(aura) == "table" then CLF._eclipseCache.solar = true; break end
      end
    end
    if not CLF._eclipseCache.lunar then
      for _, sid in ipairs(CLF._eclipseBuffIds.lunar) do
        local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, sid)
        if ok and type(aura) == "table" then CLF._eclipseCache.lunar = true; break end
      end
    end
    if CLF._eclipseCache.solar and CLF._eclipseCache.lunar then return end
  end
  local prefix = "player:"
  for k, a in pairs(CLF._auraState) do
    if string.sub(k, 1, #prefix) == prefix then
      local sid = a.spellId
      local matched = false
      for _, eid in ipairs(CLF._eclipseBuffIds.solar) do
        if sid == eid then CLF._eclipseCache.solar = true; matched = true; break end
      end
      if not matched then
        for _, eid in ipairs(CLF._eclipseBuffIds.lunar) do
          if sid == eid then CLF._eclipseCache.lunar = true; matched = true; break end
        end
      end
      if not matched then
        local nm = a.name or ""
        if type(nm) ~= "string" then nm = "" end
        local lower = string.lower(nm)
        if lower == "" or lower == tostring(sid or 0) then
          if sid and type(sid) == "number" and sid > 0 then
            local lookupName = SafeGetSpellName(sid)
            if lookupName and type(lookupName) == "string" then
              lower = string.lower(lookupName)
            end
          end
        end
        if string.find(lower, "eclipse", 1, true) then
          if string.find(lower, "solar", 1, true) then
            CLF._eclipseCache.solar = true
            CLF._LearnEclipseBuffId("solar", sid)
          elseif string.find(lower, "lunar", 1, true) then
            CLF._eclipseCache.lunar = true
            CLF._LearnEclipseBuffId("lunar", sid)
          else
            local desc = nil
            if C_Spell and C_Spell.GetSpellDescription then
              local dOk, dVal = pcall(C_Spell.GetSpellDescription, sid)
              if dOk and type(dVal) == "string" then desc = string.lower(dVal) end
            end
            if desc and (string.find(desc, "nature", 1, true) or string.find(desc, "wrath", 1, true)) then
              CLF._eclipseCache.solar = true
              CLF._LearnEclipseBuffId("solar", sid)
            elseif desc and (string.find(desc, "arcane", 1, true) or string.find(desc, "starfire", 1, true)) then
              CLF._eclipseCache.lunar = true
              CLF._LearnEclipseBuffId("lunar", sid)
            else
              CLF._eclipseCache.solar = true
              CLF._eclipseCache.lunar = true
            end
          end
        end
      end
    end
  end
  if not CLF._eclipseCache.solar or not CLF._eclipseCache.lunar then
    CLF._ScanPlayerBuffsForEclipse()
  end
end

function CLF.InSolarEclipse()
  CLF._UpdateEclipseState()
  return CLF._eclipseCache and CLF._eclipseCache.solar or false
end

function CLF.InLunarEclipse()
  CLF._UpdateEclipseState()
  return CLF._eclipseCache and CLF._eclipseCache.lunar or false
end

function CLF.InAnyEclipse()
  CLF._UpdateEclipseState()
  if not CLF._eclipseCache then return false end
  return CLF._eclipseCache.solar or CLF._eclipseCache.lunar
end

function CLF.EclipseNext(which)
  if which == "solar" then return not CLF.InSolarEclipse() end
  if which == "lunar" then return not CLF.InLunarEclipse() end
  return not CLF.InAnyEclipse()
end

function CLF._FindEclipseAura(idLists)
  for _, list in ipairs(idLists) do
    for _, sid in ipairs(list) do
      local a = CLF._auraState["player:" .. sid]
      if a and a.expiration and a.expiration > 0 then
        return a, sid
      end
    end
  end
  for _, list in ipairs(idLists) do
    for _, sid in ipairs(list) do
      if CLF._auraState["player:" .. sid] then
        return CLF._auraState["player:" .. sid], sid
      end
    end
  end
  return nil, nil
end

function CLF.EclipseRemains(which)
  local idLists
  if which == "solar" then
    if not CLF.InSolarEclipse() then return 0 end
    idLists = { ECLIPSE_SOLAR_IDS, CLF._eclipseBuffIds.solar }
  elseif which == "lunar" then
    if not CLF.InLunarEclipse() then return 0 end
    idLists = { ECLIPSE_LUNAR_IDS, CLF._eclipseBuffIds.lunar }
  else
    if not CLF.InAnyEclipse() then return 0 end
    if CLF.InSolarEclipse() then
      idLists = { ECLIPSE_SOLAR_IDS, CLF._eclipseBuffIds.solar }
    else
      idLists = { ECLIPSE_LUNAR_IDS, CLF._eclipseBuffIds.lunar }
    end
  end
  local a, sid = CLF._FindEclipseAura(idLists)
  if a and a.expiration and a.expiration > 0 then
    return mathMax(0, a.expiration - GetTime())
  end
  if sid and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
    local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, sid)
    if ok and type(aura) == "table" then
      local exp = Detaint and Detaint(aura.expirationTime) or 0
      if exp > 0 then return mathMax(0, exp - GetTime()) end
    end
  end
  return 15
end

function CLF.EclipseCounter(which)
  if which == "wrath" then
    return CLF.InLunarEclipse() and 0 or 2
  elseif which == "starfire" then
    return CLF.InSolarEclipse() and 0 or 2
  end
  return 0
end

-- ── §H4c: Spell Alias System (Talent-Swap Spells) ──
-- Some talents replace one spell with another (e.g. Incarnation replaces
-- Celestial Alignment). The APL references the base spell, but the player may
-- only know the replacement. These functions check ALL aliases for a match.
CLF._spellAliases = {}
CLF._dynamicAliasLog = {}

function CLF.BuffUpAlias(name)
  local clean = string.lower(NormalizeName(name))
  if CLF.BuffUp(clean) then return true end
  local aliases = CLF._spellAliases[clean]
  if aliases then
    for _, alt in ipairs(aliases) do
      if CLF.BuffUp(alt) then return true end
    end
  end
  return false
end

function CLF.BuffRemainsAlias(name)
  local clean = string.lower(NormalizeName(name))
  local r = CLF.BuffRemains(clean)
  if r > 0 then return r end
  local aliases = CLF._spellAliases[clean]
  if aliases then
    for _, alt in ipairs(aliases) do
      local ar = CLF.BuffRemains(alt)
      if ar > 0 then return ar end
    end
  end
  return 0
end

function CLF.DetectEclipseFromBar(cleanName, isOnCD)
  if not isOnCD then return end
  if not CLF._eclipseGrantMap then return end
  local grants = CLF._eclipseGrantMap[cleanName]
  if not grants then return end
  if not CLF._eclipseActiveUntil then CLF._eclipseActiveUntil = {} end
  local now = GetTime()
  if grants.lunar and (not CLF._eclipseActiveUntil.lunar or CLF._eclipseActiveUntil.lunar < now) then
    CLF._eclipseActiveUntil.lunar = now + grants.lunar
    if CLF.debugEnabled then
      CLF.Log("ECLIPSE", "BAR-SET: " .. cleanName .. " on CD -> lunar active for " .. grants.lunar .. "s")
    end
  end
  if grants.solar and (not CLF._eclipseActiveUntil.solar or CLF._eclipseActiveUntil.solar < now) then
    CLF._eclipseActiveUntil.solar = now + grants.solar
    if CLF.debugEnabled then
      CLF.Log("ECLIPSE", "BAR-SET: " .. cleanName .. " on CD -> solar active for " .. grants.solar .. "s")
    end
  end
end

CLF._eclipseGrantMap = {
  ["lunar eclipse"]                 = { lunar = 15 },
  ["solar eclipse"]                 = { solar = 15 },
  ["incarnation chosen of elune"]   = { lunar = 20, solar = 20 },
  ["incarnation: chosen of elune"]  = { lunar = 20, solar = 20 },
  ["celestial alignment"]           = { lunar = 20, solar = 20 },
}

CLF._eclipseGrantDefaults = {
  ["lunar eclipse"]                 = { lunar = 15 },
  ["solar eclipse"]                 = { solar = 15 },
  ["incarnation chosen of elune"]   = { lunar = 20, solar = 20 },
  ["incarnation: chosen of elune"]  = { lunar = 20, solar = 20 },
  ["celestial alignment"]           = { lunar = 20, solar = 20 },
}

local function _ParseDurationFromDescription(desc)
  if not desc or type(desc) ~= "string" then return nil end
  local lower = string.lower(desc)
  local sec = string.match(lower, "lasts%s+(%d+)%s+sec")
  if sec then return tonumber(sec) end
  sec = string.match(lower, "for%s+(%d+)%s+sec")
  if sec then return tonumber(sec) end
  sec = string.match(lower, "(%d+)%s+sec")
  if sec then return tonumber(sec) end
  return nil
end

local function _ParseDurationFromTooltip(spellIdentifier)
  if not spellIdentifier then return nil end
  if C_Spell and C_Spell.GetSpellDescription then
    local ok, desc = pcall(C_Spell.GetSpellDescription, spellIdentifier)
    if ok and desc then
      local dur = _ParseDurationFromDescription(desc)
      if dur and dur > 0 and dur < 120 then return dur end
    end
  end
  return nil
end

function CLF.RefreshEclipseGrantMap()
  if CLF._inCombat then
    CLF.DeferOOCScan("RefreshEclipseGrantMap", CLF.RefreshEclipseGrantMap)
    return
  end
  local updated = 0
  local eclipseSpellDefs = {
    { name = "Lunar Eclipse",                  key = "lunar eclipse",                  grantType = "lunar" },
    { name = "Solar Eclipse",                  key = "solar eclipse",                  grantType = "solar" },
    { name = "Incarnation: Chosen of Elune",   key = "incarnation: chosen of elune",   grantType = "both" },
    { name = "Celestial Alignment",            key = "celestial alignment",             grantType = "both" },
  }
  for _, def in ipairs(eclipseSpellDefs) do
    local dur = _ParseDurationFromTooltip(def.name)
    if not dur then
      local entry = CLF._spellBook and CLF._spellBook[string.lower(def.key)]
      if entry and entry.id then
        dur = _ParseDurationFromTooltip(entry.id)
      end
    end
    if dur then
      local defaults = CLF._eclipseGrantDefaults[def.key]
      if defaults then
        local newGrant = {}
        for gType, defDur in pairs(defaults) do
          newGrant[gType] = dur
        end
        CLF._eclipseGrantMap[def.key] = newGrant
        updated = updated + 1
      end
      if def.key == "incarnation: chosen of elune" then
        CLF._eclipseGrantMap["incarnation chosen of elune"] = CLF._eclipseGrantMap[def.key]
      end
    end
  end
  if CLF.debugEnabled and updated > 0 then
    local parts = {}
    for k, v in pairs(CLF._eclipseGrantMap) do
      local ds = {}
      for gt, d in pairs(v) do ds[#ds + 1] = gt .. "=" .. d end
      parts[#parts + 1] = k .. "(" .. table.concat(ds, ",") .. ")"
    end
    CLF.Log("ECLIPSE", "Grant map refreshed: " .. updated .. " updated -- " .. table.concat(parts, ", "))
  end
end

CLF._eclipseBuffNames = {
  lunar = { "eclipse (lunar)", "lunar eclipse", "eclipse" },
  solar = { "eclipse (solar)", "solar eclipse", "eclipse" },
}

local function _EclipseActiveFromCharges(whichType)
  local now = GetTime()
  local bestRemains = 0
  for spellClean, grants in pairs(CLF._eclipseGrantMap) do
    local dur = grants[whichType]
    if dur then
      local entry, resolvedKey = CLF.Charges.Resolve(spellClean)
      if CLF.debugEnabled then
        CLF.Log("ECLIPSE_DBG", "EclipseCheck " .. whichType .. ": key=" .. spellClean .. " resolved=" .. tostring(resolvedKey) .. " entry=" .. tostring(entry ~= nil) .. " lastConsumeAt=" .. tostring(entry and entry.lastConsumeAt) .. " dur=" .. tostring(dur))
      end
      if entry and entry.lastConsumeAt then
        local elapsed = now - entry.lastConsumeAt
        if elapsed < dur then
          local rem = dur - elapsed
          if rem > bestRemains then bestRemains = rem end
        end
      end
    end
  end
  if bestRemains <= 0 then
    local buffNames = CLF._eclipseBuffNames[whichType]
    if buffNames then
      for _, bn in ipairs(buffNames) do
        local br = CLF.BuffRemains(bn)
        if br > 0 then
          bestRemains = br
          if CLF.debugEnabled then
            CLF.Log("ECLIPSE_DBG", "EclipseBuffFallback " .. whichType .. ": found buff '" .. bn .. "' rem=" .. string.format("%.1f", br))
          end
          break
        end
        local aliases = CLF._spellAliases and CLF._spellAliases[bn]
        if aliases then
          for _, alt in ipairs(aliases) do
            local ar = CLF.BuffRemains(alt)
            if ar > 0 then
              bestRemains = ar
              if CLF.debugEnabled then
                CLF.Log("ECLIPSE_DBG", "EclipseBuffFallback " .. whichType .. ": found alias buff '" .. alt .. "' rem=" .. string.format("%.1f", ar))
              end
              break
            end
          end
        end
        if bestRemains > 0 then break end
      end
    end
  end
  if CLF.debugEnabled then
    CLF.Log("ECLIPSE_DBG", "EclipseActiveFromCharges(" .. whichType .. ") => " .. tostring(bestRemains > 0) .. " rem=" .. string.format("%.1f", bestRemains))
  end
  return bestRemains > 0, bestRemains
end

function CLF.IsSelfBuffBlocking(name)
  local dbg = CLF.debugEnabled
  local lower = string.lower(name)
  local cleanLower = string.gsub(string.gsub(lower, ":", ""), "%s+", " ")
  local isEclipseGranter = CLF._eclipseGrantMap and CLF._eclipseGrantMap[cleanLower]
  if CLF.Charges.IsChargeSpell(cleanLower) then
    local cur = CLF.Charges.Get(cleanLower)
    if cur and cur > 0 and not isEclipseGranter then
      if dbg then CLF.Log("BUFF_BLOCK", name .. " -> NOT BLOCKED (charge spell with " .. cur .. " charges)") end
      return false
    end
  end
  if CLF.BuffUpAlias(name) then
    if dbg then CLF.Log("BUFF_BLOCK", name .. " -> BLOCKED via BuffUpAlias") end
    return true
  end
  if CLF._selfBuffCastUntil and CLF._selfBuffCastUntil[cleanLower] then
    local elapsed = GetTime() - CLF._selfBuffCastUntil[cleanLower]
    if elapsed < 1.0 then
      if dbg then CLF.Log("BUFF_BLOCK", name .. " -> BLOCKED via recentCast (elapsed=" .. string.format("%.2f", elapsed) .. "s)") end
      return true
    end
  end
  local isEclipseSpell = string.find(lower, "eclipse", 1, true) and (string.find(lower, "lunar", 1, true) or string.find(lower, "solar", 1, true))
  if isEclipseSpell then
    local whichType = string.find(lower, "lunar", 1, true) and "lunar" or "solar"
    if CLF._eclipseActiveUntil and CLF._eclipseActiveUntil[whichType] then
      local rem = CLF._eclipseActiveUntil[whichType] - GetTime()
      if rem > 0 then
        if dbg then CLF.Log("BUFF_BLOCK", name .. " -> BLOCKED via eclipseActiveUntil[" .. whichType .. "] rem=" .. string.format("%.1f", rem)) end
        return true
      end
    end
    local active = _EclipseActiveFromCharges(whichType)
    if active then
      if dbg then CLF.Log("BUFF_BLOCK", name .. " -> BLOCKED via EclipseActiveFromCharges(" .. whichType .. ")") end
      return true
    end
    if CLF.BuffUpAlias("incarnation: chosen of elune") then
      if dbg then CLF.Log("BUFF_BLOCK", name .. " -> BLOCKED via incarnation buff up") end
      return true
    end
    if CLF.BuffUpAlias("celestial alignment") then
      if dbg then CLF.Log("BUFF_BLOCK", name .. " -> BLOCKED via celestial alignment buff up") end
      return true
    end
    local eclipseBuffNames = CLF._eclipseBuffNames[whichType]
    if eclipseBuffNames then
      for _, bn in ipairs(eclipseBuffNames) do
        if CLF.BuffUp(bn) then
          if dbg then CLF.Log("BUFF_BLOCK", name .. " -> BLOCKED via eclipseBuffName: " .. bn) end
          return true
        end
      end
    end
    if whichType == "lunar" and CLF.InLunarEclipse and CLF.InLunarEclipse() then
      if dbg then CLF.Log("BUFF_BLOCK", name .. " -> BLOCKED via InLunarEclipse()") end
      return true
    end
    if whichType == "solar" and CLF.InSolarEclipse and CLF.InSolarEclipse() then
      if dbg then CLF.Log("BUFF_BLOCK", name .. " -> BLOCKED via InSolarEclipse()") end
      return true
    end
  end
  local isIncarnation = string.find(lower, "incarnation", 1, true) or string.find(lower, "celestial alignment", 1, true)
  if isIncarnation then
    if CLF._eclipseActiveUntil then
      local now = GetTime()
      local lunarRem = CLF._eclipseActiveUntil.lunar and (CLF._eclipseActiveUntil.lunar - now) or 0
      local solarRem = CLF._eclipseActiveUntil.solar and (CLF._eclipseActiveUntil.solar - now) or 0
      if lunarRem > 0 or solarRem > 0 then
        if dbg then CLF.Log("BUFF_BLOCK", name .. " -> BLOCKED via eclipseActiveUntil (lunarRem=" .. string.format("%.1f", lunarRem) .. " solarRem=" .. string.format("%.1f", solarRem) .. ")") end
        return true
      end
    end
    local lunarActive = _EclipseActiveFromCharges("lunar")
    local solarActive = _EclipseActiveFromCharges("solar")
    if lunarActive or solarActive then
      if dbg then CLF.Log("BUFF_BLOCK", name .. " -> BLOCKED via EclipseActiveFromCharges (lunar=" .. tostring(lunarActive) .. " solar=" .. tostring(solarActive) .. ")") end
      return true
    end
    if CLF.BuffUpAlias("incarnation: chosen of elune") then
      if dbg then CLF.Log("BUFF_BLOCK", name .. " -> BLOCKED via incarnation buff (from incarnation check)") end
      return true
    end
    if CLF.BuffUpAlias("celestial alignment") then
      if dbg then CLF.Log("BUFF_BLOCK", name .. " -> BLOCKED via celestial alignment buff (from incarnation check)") end
      return true
    end
  end
  return false
end

function CLF.SelfBuffBlockRemains(name)
  local dbg = CLF.debugEnabled
  local br = CLF.BuffRemainsAlias(name)
  if br > 0 then
    if dbg then CLF.Log("BUFF_BLOCK", "Remains(" .. name .. ")=" .. string.format("%.1f", br) .. " via BuffRemainsAlias") end
    return br
  end
  local lower = string.lower(name)
  local isEclipseSpell = string.find(lower, "eclipse", 1, true) and (string.find(lower, "lunar", 1, true) or string.find(lower, "solar", 1, true))
  if isEclipseSpell then
    local whichType = string.find(lower, "lunar", 1, true) and "lunar" or "solar"
    local now = GetTime()
    if CLF._eclipseActiveUntil and CLF._eclipseActiveUntil[whichType] then
      local rem = CLF._eclipseActiveUntil[whichType] - now
      if rem > 0 then
        if dbg then CLF.Log("BUFF_BLOCK", "Remains(" .. name .. ")=" .. string.format("%.1f", rem) .. " via eclipseActiveUntil[" .. whichType .. "]") end
        return rem
      end
    end
    local _, chargeRem = _EclipseActiveFromCharges(whichType)
    if chargeRem > 0 then
      if dbg then CLF.Log("BUFF_BLOCK", "Remains(" .. name .. ")=" .. string.format("%.1f", chargeRem) .. " via EclipseActiveFromCharges(" .. whichType .. ")") end
      return chargeRem
    end
    local incRem = CLF.BuffRemainsAlias("incarnation: chosen of elune")
    if incRem > 0 then
      if dbg then CLF.Log("BUFF_BLOCK", "Remains(" .. name .. ")=" .. string.format("%.1f", incRem) .. " via incarnation buff") end
      return incRem
    end
    local caRem = CLF.BuffRemainsAlias("celestial alignment")
    if caRem > 0 then
      if dbg then CLF.Log("BUFF_BLOCK", "Remains(" .. name .. ")=" .. string.format("%.1f", caRem) .. " via celestial alignment buff") end
      return caRem
    end
    local ids = CLF._eclipseBuffIds and CLF._eclipseBuffIds[whichType]
    if ids then
      for _, sid in ipairs(ids) do
        local a = CLF._auraState["player:" .. sid]
        if a and a.expiration then
          local rem2 = a.expiration - now
          if rem2 > 0 then
            if dbg then CLF.Log("BUFF_BLOCK", "Remains(" .. name .. ")=" .. string.format("%.1f", rem2) .. " via auraState id=" .. sid) end
            return rem2
          end
        end
      end
    end
  end
  local isIncarnation = string.find(lower, "incarnation", 1, true) or string.find(lower, "celestial alignment", 1, true)
  if isIncarnation then
    local now = GetTime()
    local best = 0
    local bestSource = "none"
    if CLF._eclipseActiveUntil then
      if CLF._eclipseActiveUntil.lunar then
        local r = CLF._eclipseActiveUntil.lunar - now
        if r > best then best = r; bestSource = "eclipseActiveUntil.lunar" end
      end
      if CLF._eclipseActiveUntil.solar then
        local r = CLF._eclipseActiveUntil.solar - now
        if r > best then best = r; bestSource = "eclipseActiveUntil.solar" end
      end
    end
    local lunarActive, lunarRem = _EclipseActiveFromCharges("lunar")
    if lunarActive and lunarRem and lunarRem > best then best = lunarRem; bestSource = "chargesLunar" end
    local solarActive, solarRem = _EclipseActiveFromCharges("solar")
    if solarActive and solarRem and solarRem > best then best = solarRem; bestSource = "chargesSolar" end
    if best <= 0 then
      local incRem = CLF.BuffRemainsAlias("incarnation: chosen of elune")
      if incRem > best then best = incRem; bestSource = "incarnationBuff" end
      local caRem = CLF.BuffRemainsAlias("celestial alignment")
      if caRem > best then best = caRem; bestSource = "celestialAlignmentBuff" end
    end
    if best > 0 then
      if dbg then CLF.Log("BUFF_BLOCK", "Remains(" .. name .. ")=" .. string.format("%.1f", best) .. " via " .. bestSource) end
      return best
    end
  end
  return 0
end

function CLF.BuffStacksAlias(name)
  local clean = string.lower(NormalizeName(name))
  local s = CLF.BuffStacks(clean)
  if s > 0 then return s end
  local aliases = CLF._spellAliases[clean]
  if aliases then
    for _, alt in ipairs(aliases) do
      local as = CLF.BuffStacks(alt)
      if as > 0 then return as end
    end
  end
  return 0
end

function CLF.CooldownReadyAlias(name)
  local clean = string.lower(NormalizeName(name))
  local resolvedName = clean
  if CLF._spellAliases then
    local aliases = CLF._spellAliases[clean]
    if aliases then
      for _, alt in ipairs(aliases) do
        if CLF._spellBook[alt] or (CLF._spellSlots and CLF._spellSlots[alt]) then
          resolvedName = alt
          break
        end
      end
    end
  end

  local bookEntry = CLF._spellBook[resolvedName] or CLF._spellBook[clean]
  if bookEntry and bookEntry.cdReadyAt and bookEntry.cdReadyAt > 0 then
    local now = GetTime()
    if now >= bookEntry.cdReadyAt then
      bookEntry.cdReadyAt = 0
      return true
    end
    return false
  end

  local cached = CLF._barCD and (CLF._barCD[resolvedName] or CLF._barCD[clean])
  if cached and cached.start and cached.duration and cached.duration > 1.5 then
    local rem = mathMax(0, (cached.start + cached.duration) - GetTime())
    return rem <= 0
  end

  if not CLF._inCombat then
    local slotID = CLF._spellSlots and (CLF._spellSlots[resolvedName] or CLF._spellSlots[clean])
    if slotID then
      local barReady, _, _, _, barTainted = CLF.GetActionBarCD(slotID)
      if barReady == true then return true end
      if barReady == false then return false end
    end
    return CLF.CooldownReady(clean)
  end

  return true
end

function CLF.CooldownRemainsAlias(name)
  local clean = string.lower(NormalizeName(name))
  local resolvedName = clean
  if CLF._spellAliases then
    local aliases = CLF._spellAliases[clean]
    if aliases then
      for _, alt in ipairs(aliases) do
        if CLF._spellBook[alt] or (CLF._spellSlots and CLF._spellSlots[alt]) then
          resolvedName = alt
          break
        end
      end
    end
  end

  local bookEntry = CLF._spellBook[resolvedName] or CLF._spellBook[clean]
  if bookEntry and bookEntry.cdReadyAt and bookEntry.cdReadyAt > 0 then
    local now = GetTime()
    if now >= bookEntry.cdReadyAt then
      bookEntry.cdReadyAt = 0
      return 0
    end
    return bookEntry.cdReadyAt - now
  end

  local cached = CLF._barCD and (CLF._barCD[resolvedName] or CLF._barCD[clean])
  if cached and cached.start and cached.duration and cached.duration > 1.5 then
    return mathMax(0, (cached.start + cached.duration) - GetTime())
  end

  if not CLF._inCombat then
    local slotID = CLF._spellSlots and (CLF._spellSlots[resolvedName] or CLF._spellSlots[clean])
    if slotID then
      local barReady = CLF.GetActionBarCD(slotID)
      if barReady == true then return 0 end
    end
    return CLF.CooldownRemains(clean)
  end

  return 0
end

-- ── §H5: Cooldown System ──
-- Dual-source cooldown query: tries C_Spell.GetSpellCooldown first, then falls
-- back to the action-bar-based cooldown cache (CLF._barCD). During combat in
-- WoW 12.0, C_Spell cooldown data is SECRET → Detaint returns nil. The action
-- bar cache (populated by ScanActionBars via GetActionCooldown) is NOT secret
-- because the player's own UI cooldown sweeps are always visible.
CLF._barCD = {}
CLF._spellSlots = {}

local function ResolveAlias(cleanName)
  if not CLF._spellAliases then return cleanName end
  if CLF._spellBook[cleanName] and CLF._spellBook[cleanName].isKnown then return cleanName end
  local aliases = CLF._spellAliases[cleanName]
  if aliases then
    for _, alt in ipairs(aliases) do
      if CLF._spellBook[alt] and CLF._spellBook[alt].isKnown then
        return alt
      end
    end
    for _, alt in ipairs(aliases) do
      if CLF._spellSlots and CLF._spellSlots[alt] then
        return alt
      end
    end
    for _, alt in ipairs(aliases) do
      if CLF._spellBook[alt] then
        return alt
      end
    end
  end
  return cleanName
end

local function GetCDInfo(spellName)
  local cleanName = string.lower(NormalizeName(spellName))
  cleanName = ResolveAlias(cleanName)

  local bookEntry = CLF._spellBook[cleanName]
  local chCur, chMax, chRem = CLF.Charges.Get(cleanName)
  if chCur and chMax and chMax > 1 then
    if chCur > 0 then return true, 0, 0 end
    local chEntry = CLF.Charges.Resolve(cleanName)
    local rechDur = chEntry and chEntry.rechargeDur or CLF._knownCDDur[cleanName] or 120
    if chRem <= 0 and chEntry and chEntry.lastConsumeAt then
      local elapsed = GetTime() - chEntry.lastConsumeAt
      if elapsed < rechDur then
        chRem = rechDur - elapsed
      end
    end
    return false, chRem, rechDur
  end
  if bookEntry then
    if bookEntry.cdReadyAt and bookEntry.cdReadyAt > 0 then
      local now = GetTime()
      if now >= bookEntry.cdReadyAt then
        bookEntry.cdReadyAt = 0
        return true, 0, 0
      end
      local cdDur = bookEntry.cdDuration or CLF._knownCDDur[cleanName] or 0
      return false, bookEntry.cdReadyAt - now, cdDur
    end
  end

  local castTime = CLF._castLog[cleanName]
  local knownDur = CLF._knownCDDur[cleanName]
  if castTime and knownDur and knownDur > 1.5 then
    local elapsed = GetTime() - castTime
    if elapsed < knownDur then
      return false, knownDur - elapsed, knownDur
    end
  end

  local cached = CLF._barCD and CLF._barCD[cleanName]
  if cached and cached.start and cached.duration and cached.duration > 1.5 then
    local rem = mathMax(0, (cached.start + cached.duration) - GetTime())
    if rem > 0 then return false, rem, cached.duration end
  end

  if CLF._inCombat then
    if C_Spell and C_Spell.GetSpellCooldown then
      local cdOk, cdInfo = pcall(C_Spell.GetSpellCooldown, cleanName)
      if cdOk and cdInfo then
        local sOk, cdStart = pcall(function() return cdInfo.startTime end)
        local dOk, cdDur = pcall(function() return cdInfo.duration end)
        local startVal = sOk and cdStart or nil
        local durVal = dOk and cdDur or nil
        if startVal and durVal then
          local isSecStart = issecretvalue and issecretvalue(startVal)
          local isSecDur = issecretvalue and issecretvalue(durVal)
          if not isSecStart and not isSecDur then
            local nStart = tonumber(startVal) or 0
            local nDur = tonumber(durVal) or 0
            if nStart > 0 and nDur > 1.5 then
              local rem = mathMax(0, nStart + nDur - GetTime())
              if not CLF._knownCDDur[cleanName] or CLF._knownCDDur[cleanName] < nDur then
                CLF._knownCDDur[cleanName] = nDur
              end
              return rem <= 0, rem, nDur
            elseif nStart > 0 and nDur > 0 then
              return true, 0, 0
            end
          end
        end
      end
    end
    local probeUsable = SafeIsUsableSpell(cleanName)
    if probeUsable == false then
      local knownDur = CLF._knownCDDur[cleanName]
      local isCDSpell = knownDur or (CLF._cdMap and CLF._cdMap[cleanName])
      if isCDSpell then
        local castTime = CLF._castLog[cleanName]
        if castTime then
          local fallbackDur = knownDur or 30
          local elapsed = GetTime() - castTime
          if elapsed < fallbackDur then
            return false, fallbackDur - elapsed, fallbackDur
          end
        end
      end
    end
    local safetyDur = CLF._knownCDDur[cleanName]
    if safetyDur and safetyDur > 1.5 then
      local castTime = CLF._castLog[cleanName]
      if castTime then
        local elapsed = GetTime() - castTime
        if elapsed < safetyDur then
          return false, safetyDur - elapsed, safetyDur
        end
      end
    end
    if not safetyDur and CLF._cdMap and CLF._cdMap[cleanName] then
      local castTime = CLF._castLog[cleanName]
      if castTime then
        local defaultDur = 30
        local elapsed = GetTime() - castTime
        if elapsed < defaultDur then
          return false, defaultDur - elapsed, defaultDur
        end
      end
    end
    return true, 0, 0
  end

  local resolvedProbe = cleanName
  local charges, maxCharges = SafeGetSpellCharges(resolvedProbe)
  if charges and charges > 0 then
    return true, 0, 0
  end
  if charges and charges == 0 and maxCharges and maxCharges > 1 then
    return false, 0, 0
  end

  local start, duration = SafeGetSpellCooldown(resolvedProbe)
  if start > 0 and duration > 0 then
    local rem = mathMax(0, start + duration - GetTime())
    return rem <= 0, rem, duration
  end

  return true, 0, 0
end

function CLF.GetActionBarCD(slotID)
  local tag = "GetActionCD"
  TaintCall(tag)

  if CLF._inCombat then
    TaintClean(tag)
    return nil, 0, 0, 0, true
  end

  if C_ActionBar and C_ActionBar.GetActionCooldownDuration then
    local ok, durObj = pcall(C_ActionBar.GetActionCooldownDuration, slotID)
    if ok and durObj then
      local zOk, isZero = pcall(durObj.IsZero, durObj)
      local isSecret = zOk and issecretvalue and issecretvalue(isZero)
      if zOk and not isSecret and isZero then
        TaintClean(tag)
        return true, 0, 0, 0, false
      end
      if zOk and not isSecret then
        TaintClean(tag)
        return false, 0, 0, 0, false
      end
      TaintHit(tag)
      return nil, 0, 0, 0, true
    end
  end
  return nil, 0, 0, 0, true
end

function CLF.CooldownReady(spellName)
  local ready = GetCDInfo(spellName)
  return ready
end

function CLF.CooldownRemains(spellName)
  local _, rem = GetCDInfo(spellName)
  return rem
end

function CLF.CooldownCharges(spellName)
  local charges = SafeGetSpellCharges(spellName)
  return charges or 0
end

-- ── §H6: Casting Checks ──
-- Detects if the target is casting an interruptible spell.
-- Used by the interrupt priority override system in Engine.lua.
CLF._testInterruptActive = false

function CLF.TargetIsCasting()
  if CLF._testInterruptActive then return true end
  local cs = CLF._castState and CLF._castState.target
  if cs and cs.casting then return true end
  if UnitCastingDuration then
    local ok, durObj = pcall(UnitCastingDuration, "target")
    if ok and durObj and durObj.IsZero then
      local zOk, isZero = pcall(durObj.IsZero, durObj)
      if zOk and not (issecretvalue and issecretvalue(isZero)) and not isZero then return true end
    end
  end
  if UnitChannelDuration then
    local ok, durObj = pcall(UnitChannelDuration, "target")
    if ok and durObj and durObj.IsZero then
      local zOk, isZero = pcall(durObj.IsZero, durObj)
      if zOk and not (issecretvalue and issecretvalue(isZero)) and not isZero then return true end
    end
  end
  return false
end

-- ── §H7: Enemy Count (simplified -- returns fixed value based on combat mode) ──
CLF._smartSwitched = false
CLF._smartModeSwitchEnabled = true

function CLF.ActiveEnemies()
  if CLF._modeLock == "ST" or (not CLF._modeLock and CLF.combatMode == "ST") then
    return 1
  end
  return 5
end

-- ── §H8: Spell Known Cache ──
-- Spell availability doesn't change during combat, so we cache results.
-- Cache is invalidated on talent change events (PLAYER_TALENT_UPDATE).
local spellKnownCache = {}
CLF._spellKnownCache = spellKnownCache

function CLF.InvalidateSpellKnownCache()
  wipe(spellKnownCache)
end

function CLF.IsSpellKnown(spellName, spellId)
  local cacheKey = spellId and ("id:" .. spellId) or spellName
  local cached = spellKnownCache[cacheKey]
  if cached == true then return true end
  local known = false
  local resolvedID = spellId
  if not resolvedID then
    local cleanName = NormalizeName(spellName)
    resolvedID = SafeGetSpellID(cleanName)
  end
  if resolvedID then
    known = SafeIsPlayerSpell(resolvedID)
  end
  if not known and spellId and spellName then
    local nameResolved = SafeGetSpellID(NormalizeName(spellName))
    if nameResolved and nameResolved ~= spellId then
      if SafeIsPlayerSpell(nameResolved) then
        known = true
      elseif SafeIsUsableSpell(nameResolved) then
        known = true
      end
    end
  end
  if not known then
    local identifier = resolvedID or NormalizeName(spellName)
    known = SafeIsUsableSpell(identifier) or false
  end
  if not known and spellName then
    local cleanName = string.lower(NormalizeName(spellName))
    local aliases = CLF._spellAliases and CLF._spellAliases[cleanName]
    if aliases then
      for _, alt in ipairs(aliases) do
        local altID = SafeGetSpellID(alt)
        if altID then
          if SafeIsPlayerSpell(altID) then known = true; break end
          if SafeIsUsableSpell(altID) then known = true; break end
        end
        if SafeIsUsableSpell(alt) then known = true; break end
      end
    end
  end
  if known then
    spellKnownCache[cacheKey] = true
  end
  return known
end

function CLF.IsSpellUsable(spellName, spellId)
  local identifier = spellId or spellName
  return SafeIsUsableSpell(identifier)
end

function CLF.IsInRange(spellName)
  local rawTE = UnitExists and UnitExists("target")
  local hasTarget = rawTE ~= nil and ((issecretvalue and issecretvalue(rawTE)) or (rawTE and true or false))
  if not hasTarget then return true end
  return SafeIsSpellInRange(spellName, "target")
end

-- Combined usable+CD check: single pass, avoids redundant API calls
function CLF.SpellStatus(spellName, spellId)
  local identifier = spellId or spellName
  local usable = CLF.IsSpellUsable(spellName, spellId)
  local ready, cdRemaining, cdTotal = GetCDInfo(identifier)
  return usable, ready, cdRemaining, cdTotal
end

-- ── §H9: Trinket Detection + Tracking ──
-- Scans equipped trinket slots (13, 14) for on-use trinkets.
-- Builds CLF._trinkets table with item info, spell bindings, and cooldown helpers.
-- Trinket slot IDs: 13 = trinket1, 14 = trinket2
CLF._trinkets = {}
CLF._trinketScanDone = false

function CLF.ScanEquippedTrinkets()
  CLF._trinkets = {}
  for slotIndex = 13, 14 do
    local rawItemID = GetInventoryItemID("player", slotIndex)
    local itemID = rawItemID and Detaint(rawItemID) or nil
    if itemID then
      local trinket = {
        slotIndex = slotIndex,
        slotName = (slotIndex == 13) and "trinket1" or "trinket2",
        itemID = itemID,
        hasUse = false,
        spellName = nil,
        spellID = nil,
        itemName = nil,
        icon = nil,
      }

      local rawItemName, _, _, _, _, _, _, _, _, rawItemIcon = GetItemInfo(itemID)
      local itemName = DetaintStr(rawItemName)
      if itemName then
        trinket.itemName = itemName
        trinket.icon = rawItemIcon
      end
      if not trinket.icon and GetInventoryItemTexture then
        local ok, tex = pcall(GetInventoryItemTexture, "player", slotIndex)
        if ok and tex then trinket.icon = tex end
      end

      local rawSpellName, rawSpellID = GetItemSpell(itemID)
      local spellName = DetaintStr(rawSpellName)
      local spellID = Detaint(rawSpellID)
      if spellName then
        trinket.hasUse = true
        trinket.spellName = spellName
        trinket.spellID = spellID
      end

      if trinket.hasUse and trinket.itemID then
        local cdOk, cdStart, cdDur = pcall(GetItemCooldown, trinket.itemID)
        if cdOk then
          local dur = SafeDetaintNum(cdDur)
          if dur and dur > 1.5 then
            trinket._knownCD = dur
          end
        end
      end
      CLF._trinkets[trinket.slotName] = trinket
      if trinket.hasUse then
        CLF.Log("INFO", "Trinket " .. trinket.slotName .. ": " .. (trinket.itemName or "?") .. " (on-use: " .. (trinket.spellName or "?") .. ", cd=" .. (trinket._knownCD or "?") .. ")")
      end
    end
  end
  CLF._trinketScanDone = true
end

function CLF.GetTrinketCooldown(slotName)
  local trinket = CLF._trinkets[slotName]
  if not trinket or not trinket.hasUse then return 0, false end
  local apiResult = nil
  pcall(function()
    if GetItemCooldown then
      local start, duration, enable = GetItemCooldown(trinket.itemID)
      if start and duration then
        if start > 0 and duration > 1.5 then
          trinket._knownCD = duration
          local remaining = (start + duration) - GetTime()
          if remaining > 0 then
            apiResult = { remaining, false }
          else
            apiResult = { 0, true }
          end
        else
          apiResult = { 0, true }
        end
      end
    end
  end)
  if apiResult then return apiResult[1], apiResult[2] end
  local spellKey = trinket.spellName and string.lower(NormalizeName(trinket.spellName))
  if spellKey then
    local barEntry = CLF._barCD and CLF._barCD[spellKey]
    if barEntry and barEntry.start and barEntry.duration then
      local elapsed = GetTime() - barEntry.start
      if elapsed < barEntry.duration then
        return barEntry.duration - elapsed, false
      end
    end
  end
  if trinket._lastUseTime then
    local knownDur = trinket._knownCD or 90
    local elapsed = GetTime() - trinket._lastUseTime
    if elapsed < knownDur then
      return knownDur - elapsed, false
    end
  end
  return 0, true
end

function CLF.RecordTrinketUse(spellName)
  if not spellName then return end
  local cleanName = string.lower(NormalizeName(spellName))
  for slotName, t in pairs(CLF._trinkets) do
    if t.hasUse and t.spellName then
      local tKey = string.lower(NormalizeName(t.spellName))
      if tKey == cleanName then
        t._lastUseTime = GetTime()
        local knownDur = t._knownCD or 90
        CLF._barCD[cleanName] = { start = GetTime(), duration = knownDur }
        return
      end
    end
  end
end

function CLF.TrinketReady(slotName)
  local _, ready = CLF.GetTrinketCooldown(slotName)
  return ready
end

function CLF.TrinketUsable(slotName)
  local trinket = CLF._trinkets[slotName]
  if not trinket or not trinket.hasUse then return false end
  local result = true
  pcall(function()
    if IsItemInRange then
      local inRange = IsItemInRange(trinket.itemID, "target")
      if inRange == false then result = false end
    end
  end)
  return result
end

function CLF.GetTrinketInfo(slotName)
  return CLF._trinkets[slotName]
end

-- ── §H10: Movement & Stealth Checks ──
function CLF.IsMoving()
  local s = CLF._snap
  return (s and s.moving) or false
end

-- Stealth check -- used by Rogue/Druid conditions
-- Uses spell IDs for locale-independent detection:
-- 1784=Stealth, 5215=Prowl, 115192=Subterfuge, 185422=Shadow Dance, 11327=Vanish
function CLF.IsStealthed()
  if IsStealthed then
    local ok, result = pcall(IsStealthed)
    if ok and DetaintBool(result) then return true end
  end
  if FindAura("player", "stealth", "HELPFUL") then return true end
  if FindAura("player", "prowl", "HELPFUL") then return true end
  if FindAura("player", "subterfuge", "HELPFUL") then return true end
  if FindAura("player", "shadow_dance", "HELPFUL") then return true end
  if FindAura("player", "vanish", "HELPFUL") then return true end
  return false
end

-- ── §H11: Resource & Debuff Helpers ──
function CLF.DebuffStacks(debuffName)
  local _, count = FindAura("target", debuffName, "HARMFUL")
  return count or 0
end

-- Resource deficit -- how much resource the player can still gain
function CLF.PowerDeficit()
  local rt = CLF._resTracker
  if not rt then return 0 end
  local cur = SafeNum(rt.current, 0)
  local mx = SafeNum(rt.max, 1)
  return mathMax(0, mx - cur)
end

function CLF.HealthMax()
  return 1
end

-- ── §H12: GCD (Global Cooldown) Helpers ──
-- GCD varies by haste. Base GCD is 1.5s for most classes, reduced by haste.
function CLF.GCDRemains()
  local elapsed, duration = CLF.GetGCD()
  if duration > 0 then
    return mathMax(0, duration - elapsed)
  end
  return 0
end

function CLF.GCDMax()
  local ss = CLF._statsSnapshot
  if ss and ss.gcdHasted and ss.gcdHasted > 0 then
    return ss.gcdHasted
  end
  return 1.5 / CLF.HasteMultiplier()
end

-- ── §H13: Previous GCD Tracking & Self-Managed Cooldown System ──
-- Tracks the last spell cast via UNIT_SPELLCAST_SUCCEEDED events in Core.lua.
-- CD durations are learned at init/spec/talent change and tracked from casts.
-- This system does NOT rely on runtime tainted APIs for CD state.
CLF._prevGCD = nil
CLF._castLog = {}
CLF._knownCDDur = {}
CLF._cdLearnRetries = 0

local function TryReadSpellCDDuration(spellName, spellId)
  local identifier = spellId or NormalizeName(spellName)
  if C_Spell and C_Spell.GetSpellCooldown then
    local ok, info = pcall(C_Spell.GetSpellCooldown, identifier)
    if ok and info then
      local dur = SafeDetaintNum(info.duration)
      if dur and dur > 1.5 then return dur end
    end
  end
  if GetSpellBaseCooldown then
    local ok, ms = pcall(GetSpellBaseCooldown, identifier)
    if ok and ms then
      local d = SafeDetaintNum(ms)
      if d and d > 1500 then return d / 1000 end
    end
  end
  return nil
end

function CLF.LearnSpellCDs(force)
  local allSpells = {}
  local fAPL = CLF._filteredAPL
  if fAPL then
    local sections = { "rotation", "precombatState", "precombatOpener", "interrupts" }
    for _, sec in ipairs(sections) do
      if fAPL[sec] then
        for _, e in ipairs(fAPL[sec]) do
          if e.spellName then
            allSpells[string.lower(NormalizeName(e.spellName))] = { name = e.spellName, id = e.spellId }
          end
        end
      end
    end
  end
  local cfg = CLF_Config or CLF_DefaultConfig
  if cfg and cfg.entries then
    for _, e in ipairs(cfg.entries) do
      if e.spellName then
        local cn = string.lower(NormalizeName(e.spellName))
        if not allSpells[cn] then
          allSpells[cn] = { name = e.spellName, id = e.spellId }
        end
      end
    end
  end

  for cleanName, info in pairs(allSpells) do
    if info.id and type(info.id) == "number" then
      local displayName = SafeGetSpellName(info.id)
      if displayName then
        CLF._spellIdNameCache[info.id] = displayName
      elseif not CLF._spellIdNameCache[info.id] then
        CLF._spellIdNameCache[info.id] = NormalizeName(info.name)
      end
    end
  end

  local missing = 0
  local learned = 0
  for cleanName, info in pairs(allSpells) do
    if force or not CLF._knownCDDur[cleanName] then
      local dur = TryReadSpellCDDuration(info.name, info.id)
      if dur then
        CLF._knownCDDur[cleanName] = dur
        learned = learned + 1
      else
        missing = missing + 1
      end
    end
  end

  if missing > 0 and CLF._cdLearnRetries < 5 then
    CLF._cdLearnRetries = CLF._cdLearnRetries + 1
    local delay = CLF._cdLearnRetries <= 2 and 1 or (CLF._cdLearnRetries <= 4 and 3 or 5)
    C_Timer.After(delay, function()
      pcall(CLF.LearnSpellCDs, false)
    end)
  elseif missing == 0 then
    CLF._cdLearnRetries = 0
  end

  if learned > 0 then
    CLF.Log("SYSTEM", "Learned CD durations for " .. learned .. " spells" .. (missing > 0 and (" (" .. missing .. " still unknown)") or ""))
  end
end

function CLF.CacheSpellCDs()
  CLF.LearnSpellCDs(false)
end

CLF._precombatApplied = {}
local _dynamicStatePatterns = {
  ["form"] = true,
  ["stance"] = true,
  ["stealth"] = true,
  ["prowl"] = true,
  ["summon pet"] = true,
}

local function IsDynamicState(key)
  if _dynamicStatePatterns[key] then return true end
  if string.find(key, " form$") or string.find(key, " stance$") then return true end
  return false
end

function CLF.RecordCast(spellName)
  if not spellName then return end
  local cleanName = string.lower(NormalizeName(spellName))
  local now = GetTime()
  if not CLF._firstCombatCastTime or CLF._firstCombatCastTime <= 0 then
    CLF._firstCombatCastTime = now
  end
  CLF._castLog[cleanName] = now
  CLF._prevGCD = spellName
  CLF.RecordDotCast(cleanName)
  if CLF._spellAliases then
    local aliases = CLF._spellAliases[cleanName]
    if aliases then
      for _, alt in ipairs(aliases) do
        CLF._castLog[alt] = now
      end
    end
  end
  local fAPL = CLF._filteredAPL
  if fAPL and fAPL.precombatState then
    for _, ps in ipairs(fAPL.precombatState) do
      local psKey = string.gsub(string.gsub(string.lower(ps.spellName), "_", " "), ":", "")
      if psKey == cleanName and not IsDynamicState(cleanName) then
        CLF._precombatApplied[cleanName] = now
        break
      end
    end
  end

  if fAPL and fAPL.rotation then
    for _, e in ipairs(fAPL.rotation) do
      local aplKey = string.gsub(string.gsub(string.lower(e.spellName), "_", " "), ":", "")
      local isMatch = (aplKey == cleanName)
      if not isMatch and CLF._spellAliases then
        local aliases = CLF._spellAliases[cleanName]
        if aliases then
          for _, alt in ipairs(aliases) do
            if alt == aplKey then isMatch = true; break end
          end
        end
      end
      if isMatch then
        CLF._lastRotationCastTime = now
        if CLF._stalenessActive then
          CLF._stalenessActive = false
          CLF.Log("SYSTEM", "Staleness cleared -- rotation spell cast: " .. spellName)
        end
        break
      end
    end
  end

  local bookEntry = CLF._spellBook[cleanName]
  local knownDur = CLF._knownCDDur[cleanName]

  if bookEntry then
    bookEntry.lastCastAt = now
    local cdDur = bookEntry.cdDuration or knownDur
    if (not cdDur or cdDur <= 1.5) then
      local slotID = CLF._spellSlots and CLF._spellSlots[cleanName]
      if slotID and GetActionCooldown then
        pcall(function()
          local start, duration = GetActionCooldown(slotID)
          local s = SafeDetaintNum(start)
          local d = SafeDetaintNum(duration)
          if s and s > 0 and d and d > 1.5 then
            cdDur = d
          end
        end)
      end
    end
    local isChargeSp = CLF.Charges.IsChargeSpell(cleanName)
    if isChargeSp then
      local chEntry = CLF.Charges.Resolve(cleanName)
      if chEntry and chEntry.rechargeDur and chEntry.rechargeDur > 1.5 then
        cdDur = chEntry.rechargeDur
      end
    end
    if (not cdDur or cdDur <= 1.5) then
      local cdMap = CLF._cdMap or {}
      local isDef = CLF._defensiveSpells and CLF._defensiveSpells[cleanName]
      local isCDSpell = cdMap[cleanName] or isDef
      if isCDSpell then
        cdDur = 120
      end
    end
    if isChargeSp then
      local alreadyConsumed = CLF._cleuConsumedThisCast and CLF._cleuConsumedThisCast[cleanName]
      if not alreadyConsumed then
        CLF.Charges.Consume(cleanName)
      end
      local chargesLeft = CLF.Charges.Get(cleanName) or 0
      if chargesLeft > 0 then
        bookEntry.cdReadyAt = nil
      else
        local effCdDur = cdDur or 120
        bookEntry.cdReadyAt = now + effCdDur
      end
    end
    if cdDur and cdDur > 1.5 then
      local effCdDur = cdDur
      if not isChargeSp then
        bookEntry.cdReadyAt = now + effCdDur
      end
      CLF._barCD[cleanName] = { start = now, duration = effCdDur }
      if not knownDur or (isChargeSp and knownDur > effCdDur * 2) then
        CLF._knownCDDur[cleanName] = effCdDur
      end
      if not bookEntry.cdDuration then bookEntry.cdDuration = effCdDur end
    end
  elseif knownDur and knownDur > 1.5 then
    CLF._barCD[cleanName] = { start = now, duration = knownDur }
  else
    local cdMap = CLF._cdMap or {}
    local isDef = CLF._defensiveSpells and CLF._defensiveSpells[cleanName]
    if cdMap[cleanName] or isDef then
      local fallbackDur = 120
      CLF._barCD[cleanName] = { start = now, duration = fallbackDur }
      CLF._knownCDDur[cleanName] = fallbackDur
    end
  end

  if not knownDur and not (bookEntry and bookEntry.cdDuration) then
    C_Timer.After(0.3, function()
      local existingDur = CLF._knownCDDur[cleanName]
      local isFallbackDur = existingDur == 30 or existingDur == 120
      if existingDur and not isFallbackDur then return end
      if DetaintBool(InCombatLockdown(), "RecordCast_combat") then
        local cdMap = CLF._cdMap or {}
        local shouldTrack = cdMap[cleanName]
        if not shouldTrack then
          local isDef2 = CLF._defensiveSpells and CLF._defensiveSpells[cleanName]
          if isDef2 then
            shouldTrack = true
          end
        end
        local refinedDur = existingDur or 120
        if shouldTrack or isFallbackDur then
          pcall(function()
            local s, d = SafeGetSpellCooldown(cleanName)
            if s and s > 0 and d and d > 1.5 then
              refinedDur = d
            end
          end)
          if refinedDur == existingDur or refinedDur == 120 or refinedDur == 30 then
            local slotID = CLF._spellSlots and CLF._spellSlots[cleanName]
            if slotID and GetActionCooldown then
              pcall(function()
                local start, duration = GetActionCooldown(slotID)
                local s = SafeDetaintNum(start)
                local d = SafeDetaintNum(duration)
                if s and s > 0 and d and d > 1.5 then
                  refinedDur = d
                end
              end)
            end
          end
        end
        if shouldTrack or (isFallbackDur and refinedDur ~= existingDur) then
          CLF._knownCDDur[cleanName] = refinedDur
          local bc = CLF._barCD[cleanName]
          if bc then
            bc.duration = refinedDur
          else
            CLF._barCD[cleanName] = { start = now, duration = refinedDur }
          end
          local be = CLF._spellBook[cleanName]
          if be then
            be.cdDuration = refinedDur
            be.cdReadyAt = now + refinedDur
          end
        end
        return
      end
      pcall(function()
        local dur = TryReadSpellCDDuration(spellName)
        if dur then
          CLF._knownCDDur[cleanName] = dur
          if CLF._barCD[cleanName] and CLF._barCD[cleanName].start == now then
            CLF._barCD[cleanName].duration = dur
          end
          local be = CLF._spellBook[cleanName]
          if be then
            be.cdDuration = dur
            be.cdReadyAt = now + dur
          end
        end
      end)
    end)
  end
end

function CLF.IsOnEventCD(spellName)
  local cleanName = string.lower(NormalizeName(spellName))

  local bookEntry = CLF._spellBook[cleanName]

  local chCur, chMax, chRem = CLF.Charges.Get(cleanName)
  if chCur and chMax and chMax > 1 then
    if chCur > 0 then return false, 0 end
    return true, chRem
  end

  if not CLF.Charges.IsChargeSpell(cleanName) and not CLF._inCombat then
    pcall(function()
      if C_Spell and C_Spell.GetSpellCharges then
        local chInfo = C_Spell.GetSpellCharges(spellName)
        if chInfo and chInfo.maxCharges and chInfo.maxCharges > 1 then
          CLF.Charges.SetFromAPI(cleanName, chInfo.currentCharges or 0, chInfo.maxCharges, chInfo.cooldownDuration, chInfo.cooldownStartTime, chInfo.cooldownDuration, bookEntry and bookEntry.spellId)
          if bookEntry then
            bookEntry.maxCharges = chInfo.maxCharges
            bookEntry.currentCharges = chInfo.currentCharges or 0
            if chInfo.cooldownDuration and chInfo.cooldownDuration > 1.5 then
              bookEntry.rechargeDuration = chInfo.cooldownDuration
            end
          end
        end
      end
    end)
    local chCur2, chMax2, chRem2 = CLF.Charges.Get(cleanName)
    if chCur2 and chMax2 and chMax2 > 1 then
      if chCur2 > 0 then return false, 0 end
      return true, chRem2
    end
  end

  if bookEntry and bookEntry.cdReadyAt and bookEntry.cdReadyAt > 0 then
    local now = GetTime()
    if now >= bookEntry.cdReadyAt then
      bookEntry.cdReadyAt = 0
      return false, 0
    end
    return true, bookEntry.cdReadyAt - now
  end

  local castTime = CLF._castLog[cleanName]
  if not castTime then return false, 0 end

  local elapsed = GetTime() - castTime
  local knownDur = CLF._knownCDDur[cleanName]

  if knownDur and knownDur > 1.5 then
    if elapsed < knownDur then
      return true, knownDur - elapsed
    end
    return false, 0
  end

  if CLF._cdMap and CLF._cdMap[cleanName] and not knownDur then
    local defaultDur = 30
    if elapsed < defaultDur then
      return true, defaultDur - elapsed
    end
    return false, 0
  end

  if not CLF._inCombat then
    local charges, maxCharges = SafeGetSpellCharges(spellName)
    if charges and charges > 0 then return false, 0 end

    local slotID = CLF._spellSlots[cleanName]
    if slotID and C_ActionBar and C_ActionBar.GetActionCooldownDuration then
      local ok, durObj = pcall(C_ActionBar.GetActionCooldownDuration, slotID)
      if ok and durObj and durObj.IsZero then
        local zOk, isZero = pcall(durObj.IsZero, durObj)
        local isSecret = zOk and issecretvalue and issecretvalue(isZero)
        if zOk and not isSecret then
          if isZero then return false, 0 end
          return true, 1
        end
      end
    end
  end

  local cdMap = CLF._cdMap or {}
  if cdMap[cleanName] then
    local fallbackDur = 30
    if elapsed < fallbackDur then
      return true, fallbackDur - elapsed
    end
    return false, 0
  end
  local gcdLen = CLF.GCDMax and CLF.GCDMax() or 1.5
  local minSuppress = mathMax(gcdLen, 3.0)
  if elapsed < minSuppress then
    return true, minSuppress - elapsed
  end
  return false, 0
end

function CLF.PrevGCD(spellName)
  if not CLF._prevGCD then return false end
  local cleanSearch = string.lower(NormalizeName(spellName))
  local cleanPrev = string.lower(NormalizeName(CLF._prevGCD))
  return cleanPrev == cleanSearch
end

-- ── §H14: Combat Time & Fight Remains ──
CLF._combatStart = 0

function CLF.CombatTime()
  if CLF._combatStart == 0 then return 0 end
  return GetTime() - CLF._combatStart
end

-- Fight remains: estimates time until target dies based on HP loss rate.
-- Uses a simple linear extrapolation from current health / recent DPS.
CLF._lastTargetHP = nil
CLF._lastTargetTime = nil

function CLF.FightRemains()
  local hp = CLF.TargetHealthPct()
  local now = GetTime()
  if not CLF._lastTargetHP or not CLF._lastTargetTime then
    CLF._lastTargetHP = hp
    CLF._lastTargetTime = now
    return 300
  end
  local dt = now - CLF._lastTargetTime
  if dt < 2 then return 300 end
  local dhp = CLF._lastTargetHP - hp
  CLF._lastTargetHP = hp
  CLF._lastTargetTime = now
  if dhp <= 0 then return 300 end
  local rate = dhp / dt
  return mathMax(0, hp / rate)
end

-- ── §H15: Talent Check ──
-- Cached per session -- talents don't change during combat.
-- Uses fuzzy name matching against the entire spellbook + talent tree.
local talentCache = {}
CLF._talentCache = talentCache

function CLF.InvalidateTalentCache()
  wipe(talentCache)
end

function CLF.TalentEnabled(talentName)
  local cached = talentCache[talentName]
  if cached ~= nil then return cached end
  local cleanName = string.lower(NormalizeName(talentName))
  local known = false
  if C_ClassTalents and C_ClassTalents.GetActiveConfigID then
    local configID = C_ClassTalents.GetActiveConfigID()
    if configID and C_Traits and C_Traits.GetConfigInfo then
      local configInfo = C_Traits.GetConfigInfo(configID)
      if configInfo and configInfo.treeIDs then
        for _, treeID in ipairs(configInfo.treeIDs) do
          local nodes = C_Traits.GetTreeNodes(treeID)
          if nodes then
            for _, nodeID in ipairs(nodes) do
              local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
              if nodeInfo and nodeInfo.activeRank and nodeInfo.activeRank > 0 then
                for _, entryID in ipairs(nodeInfo.entryIDs or {}) do
                  local entryInfo = C_Traits.GetEntryInfo(configID, entryID)
                  if entryInfo and entryInfo.definitionID then
                    local defInfo = C_Traits.GetDefinitionInfo(entryInfo.definitionID)
                    if defInfo and defInfo.overrideName then
                      local defClean = DetaintStr(defInfo.overrideName)
                      if not defClean then break end
                      local defName = string.gsub(string.lower(defClean), "%s+", "_")
                      if defName == string.lower(cleanName) then
                        known = true
                        break
                      end
                    end
                  end
                end
              end
              if known then break end
            end
          end
          if known then break end
        end
      end
    end
  end
  if not known then
    known = CLF.IsSpellKnown(talentName)
  end
  talentCache[talentName] = known
  return known
end

-- ── §H15b: (Potion tracking removed -- DPS rotation only) ──

-- ── §H15c: Consumable Buff Alerts (Flask, Food, Weapon Enhancement, Augment Rune) ──
-- Detects whether each buff category is active via aura scanning (no item selection needed).
-- Shows a simple text alert under the HUD when any enabled buff is missing or expiring.
CLF._consumables = {}
CLF._consumableReminder = {}
CLF._lastConsumableCheck = 0

local CONSUMABLE_CATEGORIES = {
  { key = "flask",      enableKey = "flaskEnabled",      label = L["CONSUMABLE_FLASK"],      short = "Flask" },
  { key = "food",       enableKey = "foodEnabled",       label = L["CONSUMABLE_FOOD"],       short = "Food" },
  { key = "weaponEnh",  enableKey = "weaponEnhEnabled",  label = L["CONSUMABLE_WEAPON_ENH"], short = "Wpn" },
  { key = "augmentRune", enableKey = "augmentRuneEnabled", label = L["CONSUMABLE_AUGMENT_RUNE"], short = "Rune" },
}

function CLF.InitConsumables()
  local config = CLF_Config or CLF_DefaultConfig
  if not config then return end
  local hud = config.hud or {}
  if not hud.consumablesEnabled then
    CLF._consumables = {}
    CLF._consumableReminder = {}
    return
  end

  for _, cat in ipairs(CONSUMABLE_CATEGORIES) do
    if hud[cat.enableKey] then
      local prev = CLF._consumables[cat.key]
      CLF._consumables[cat.key] = {
        buffActive = prev and prev.buffActive or false,
        buffExpiry = prev and prev.buffExpiry or 0,
        category = cat.key,
        label = cat.label,
      }
    else
      CLF._consumables[cat.key] = nil
    end
  end

  CLF.CheckConsumableBuffs()
end

function CLF.CheckConsumableBuffs()
  local config = CLF_Config or CLF_DefaultConfig
  if not config then return end
  local hud = config.hud or {}
  if not hud.consumablesEnabled then return end

  for _, cat in ipairs(CONSUMABLE_CATEGORIES) do
    local cData = CLF._consumables[cat.key]
    if cData then
      cData.buffActive = false
      cData.buffExpiry = 0
    end
  end

  if C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
    local nilStreak = 0
    for i = 1, 40 do
      local ok, aura = pcall(C_UnitAuras.GetBuffDataByIndex, "player", i)
      if not ok or type(aura) ~= "table" then
        nilStreak = nilStreak + 1
        if nilStreak >= 3 then break end
      else
        local auraNameStr = DetaintStr(aura.name)
        if not auraNameStr then
          nilStreak = nilStreak + 1
          if nilStreak >= 3 then break end
        else
          nilStreak = 0
          local dur = Detaint(aura.duration) or 0
          local expiry = Detaint(aura.expirationTime) or 0

          local lowerAura = string.lower(auraNameStr)

          local foodData = CLF._consumables["food"]
          if foodData and not foodData.buffActive and dur > 0 then
            if lowerAura == "well fed"
              or string.find(lowerAura, "well fed", 1, true)
              or string.find(lowerAura, "food", 1, true)
              or string.find(lowerAura, "feast", 1, true)
              or string.find(lowerAura, "nourish", 1, true)
              or string.find(lowerAura, "sated", 1, true)
              or string.find(lowerAura, "hearty", 1, true)
              or (dur >= 600 and dur <= 7200 and (
                string.find(lowerAura, "stamina", 1, true)
                or string.find(lowerAura, "versatility", 1, true)
                or string.find(lowerAura, "haste", 1, true)
                or string.find(lowerAura, "mastery", 1, true)
                or string.find(lowerAura, "critical strike", 1, true)
                or string.find(lowerAura, "crit", 1, true)
                or string.find(lowerAura, "agility", 1, true)
                or string.find(lowerAura, "intellect", 1, true)
                or string.find(lowerAura, "strength", 1, true)
                or string.find(lowerAura, "speed", 1, true)
                or string.find(lowerAura, "leech", 1, true)
                or string.find(lowerAura, "avoidance", 1, true)
              ))
            then
              foodData.buffActive = true
              foodData.buffExpiry = expiry
            end
          end

          local flaskData = CLF._consumables["flask"]
          if flaskData and not flaskData.buffActive and dur >= 1200 then
            if string.find(lowerAura, "phial", 1, true)
              or string.find(lowerAura, "flask", 1, true)
              or string.find(lowerAura, "elixir", 1, true)
            then
              flaskData.buffActive = true
              flaskData.buffExpiry = expiry
            end
          end

          local runeData = CLF._consumables["augmentRune"]
          if runeData and not runeData.buffActive and dur >= 1200 then
            if string.find(lowerAura, "augment", 1, true)
              or string.find(lowerAura, "rune", 1, true)
              or string.find(lowerAura, "void-touched", 1, true)
              or string.find(lowerAura, "void touched", 1, true)
              or lowerAura == "void-touched"
            then
              runeData.buffActive = true
              runeData.buffExpiry = expiry
            end
          end
        end
      end
    end
  end

  if GetWeaponEnchantInfo then
    pcall(function()
      local hasMain, mainExp, _, hasOff, offExp = GetWeaponEnchantInfo()
      local weapData = CLF._consumables["weaponEnh"]
      if weapData and not weapData.buffActive then
        if hasMain then
          weapData.buffActive = true
          if mainExp and mainExp > 0 then
            weapData.buffExpiry = GetTime() + (mainExp / 1000)
          else
            weapData.buffExpiry = 0
          end
        elseif hasOff then
          weapData.buffActive = true
          if offExp and offExp > 0 then
            weapData.buffExpiry = GetTime() + (offExp / 1000)
          else
            weapData.buffExpiry = 0
          end
        end
      end
    end)
  end

  CLF._consumableReminder = {}
  local inCombat = DetaintBool(InCombatLockdown(), "InCombatLockdown")
  for _, cat in ipairs(CONSUMABLE_CATEGORIES) do
    if hud[cat.enableKey] then
      local cData = CLF._consumables[cat.key]
      if cData then
        if not cData.buffActive and not inCombat then
          table.insert(CLF._consumableReminder, {
            category = cat.key,
            label = cat.short or cat.label,
            status = "missing",
          })
        elseif cData.buffActive and cData.buffExpiry > 0 then
          local remaining = cData.buffExpiry - GetTime()
          if remaining > 0 and remaining < 300 then
            table.insert(CLF._consumableReminder, {
              category = cat.key,
              label = cat.short or cat.label,
              status = "expiring",
              remaining = remaining,
            })
          end
        end
      end
    end
  end
end

function CLF.GetKeybindForSlot(slotID)
  local barMap = {
    [0] = "ACTIONBUTTON",
    [2] = "MULTIACTIONBAR1BUTTON",
    [3] = "MULTIACTIONBAR2BUTTON",
    [4] = "MULTIACTIONBAR3BUTTON",
    [5] = "MULTIACTIONBAR4BUTTON",
    [6] = "MULTIACTIONBAR5BUTTON",
    [8] = "MULTIACTIONBAR6BUTTON",
    [10] = "MULTIACTIONBAR7BUTTON",
  }
  local bar = math.floor((slotID - 1) / 12)
  local idx = ((slotID - 1) % 12) + 1
  local bindPrefix = barMap[bar]
  if not bindPrefix then return nil end
  local bindCmd = bindPrefix .. idx
  local key1 = GetBindingKey(bindCmd)
  if key1 then return DetaintStr(key1) end
  return nil
end

-- ── §H16: Condition Evaluator Helpers ──
-- These functions support SimC condition expressions translated by conditionToLua().
function CLF.CooldownDuration(spellName)
  local _, duration = SafeGetSpellCooldown(spellName)
  return Detaint(duration) or 0
end

-- Fractional charges -- returns charge progress between 0.0 and maxCharges
function CLF.ChargesFractional(spellName)
  local cleanName = string.lower(NormalizeName(spellName))
  local cur, maxCh, rechRem = CLF.Charges.Get(cleanName)
  if cur and maxCh and maxCh > 1 then
    if cur >= maxCh then return cur end
    local chEntry = CLF.Charges.Resolve(cleanName)
    local rechDur = chEntry and chEntry.rechargeDur or 0
    if rechDur > 0 and rechRem > 0 then
      local progress = (rechDur - rechRem) / rechDur
      return cur + mathMin(1, progress)
    end
    return cur
  end
  return 0
end

-- ── §H17: Custom Variables ──
-- SimC variable definitions compiled to Lua functions + user overrides via /dmga var.
CLF._vars = {}

function CLF.GetVar(name)
  if CLF._vars[name] ~= nil then return CLF._vars[name] end
  local fn = CLF._varFns and CLF._varFns[name]
  if fn then
    local ok, val = pcall(fn)
    if ok then
      if type(val) == "boolean" then return val and 1 or 0 end
      return val or 0
    end
  end
  return 0
end

function CLF.SetVar(name, value)
  CLF._vars[name] = value
end

-- ── §H18: Keybind Priority System ──
-- Scans all action bars for keybinds, respecting the user's bar priority order.
-- Results are cached and only refreshed when bars change or invalidated manually.
local GetActionInfo = GetActionInfo
local GetBindingKey = GetBindingKey

CLF._keybindCache = {}
CLF._keybindCacheDirty = true

local BAR_SLOT_RANGES = {
  ["Main Action Bar"]  = { start = 1,  stop = 12,  bindPrefix = "ACTIONBUTTON" },
  ["Bottom Left"]      = { start = 61, stop = 72,  bindPrefix = "MULTIACTIONBAR1BUTTON" },
  ["Bottom Right"]     = { start = 49, stop = 60,  bindPrefix = "MULTIACTIONBAR2BUTTON" },
  ["Right Bar 1"]      = { start = 25, stop = 36,  bindPrefix = "MULTIACTIONBAR3BUTTON" },
  ["Right Bar 2"]      = { start = 37, stop = 48,  bindPrefix = "MULTIACTIONBAR4BUTTON" },
  ["Extra Bar 1"]      = { start = 145, stop = 156, bindPrefix = "MULTIACTIONBAR5BUTTON" },
  ["Extra Bar 2"]      = { start = 157, stop = 168, bindPrefix = "MULTIACTIONBAR6BUTTON" },
  ["Extra Bar 3"]      = { start = 169, stop = 180, bindPrefix = "MULTIACTIONBAR7BUTTON" },
}

local DEFAULT_BAR_PRIORITY = {
  "Main Action Bar", "Bottom Left", "Bottom Right", "Right Bar 1", "Right Bar 2",
  "Extra Bar 1", "Extra Bar 2", "Extra Bar 3",
}

function CLF.InvalidateKeybindCache()
  CLF._keybindCacheDirty = true
end

CLF._lastKeybindScan = 0

local function GetMainBarSlotOffset()
  local page = 1
  if GetActionBarPage then
    local rawPage = GetActionBarPage()
    if rawPage and type(rawPage) == "number" then
      page = rawPage
    elseif issecretvalue and rawPage and issecretvalue(rawPage) then
      page = 1
    end
  end
  local bonus = 0
  if GetBonusBarOffset then
    local rawBonus = GetBonusBarOffset()
    if rawBonus and type(rawBonus) == "number" and rawBonus > 0 then
      bonus = rawBonus
    elseif issecretvalue and rawBonus and issecretvalue(rawBonus) then
      bonus = 0
    end
  end
  if bonus > 0 then
    return (bonus + 5) * 12
  end
  return (page - 1) * 12
end

local function ScanBarSlots(barInfo, isMainBar)
  local slotStart = barInfo.start
  local slotStop = barInfo.stop
  if isMainBar then
    local offset = GetMainBarSlotOffset()
    slotStart = offset + 1
    slotStop = offset + 12
  end
  local results = {}
  for slot = slotStart, slotStop do
    local btnIndex = isMainBar and (slot - slotStart + 1) or (slot - barInfo.start + 1)
    local rawAT, rawAID = GetActionInfo(slot)
    local actionType = DetaintStr(rawAT)
    local id = Detaint(rawAID)
    local rawKey = GetBindingKey(barInfo.bindPrefix .. btnIndex)
    local key = DetaintStr(rawKey)
    if key then
      results[#results + 1] = { actionType = actionType, id = id, key = key }
    end
  end
  return results
end

function CLF.ScanAllKeybinds()
  local now = GetTime()
  if (now - CLF._lastKeybindScan) < 2 then return end
  CLF._lastKeybindScan = now

  wipe(CLF._keybindCache)

  local config = CLF_Config or CLF_DefaultConfig
  if not config then return end
  local hud = config.hud or {}

  local overrides = hud.keybindOverrides or {}
  for spellName, kb in pairs(overrides) do
    CLF._keybindCache[string.lower(spellName)] = kb
  end

  local barPriority = hud.keybindBarPriority
  if not barPriority or #barPriority == 0 then
    barPriority = DEFAULT_BAR_PRIORITY
  end

  for _, barName in ipairs(barPriority) do
    local barInfo = BAR_SLOT_RANGES[barName]
    if barInfo then
      local isMainBar = (barName == "Main Action Bar")
      local entries = ScanBarSlots(barInfo, isMainBar)
      for _, e in ipairs(entries) do
        if e.actionType == "spell" then
          local name = SafeGetSpellName(e.id)
          if name then
            local lowerName = string.lower(name)
            if not CLF._keybindCache[lowerName] then
              CLF._keybindCache[lowerName] = e.key
            end
          end
        elseif e.actionType == "item" and e.id then
          local rawItemName = GetItemInfo(e.id)
          local itemName = DetaintStr(rawItemName)
          if itemName then
            local lowerName = string.lower(itemName)
            if not CLF._keybindCache[lowerName] then
              CLF._keybindCache[lowerName] = e.key
            end
          end
        elseif e.actionType == "macro" and e.id then
          if GetMacroSpell then
            local mOk, mSpellName, mSpellId = pcall(GetMacroSpell, e.id)
            if mOk and mSpellId then
              local resolvedName = SafeGetSpellName(Detaint(mSpellId))
              if resolvedName then
                local lowerName = string.lower(resolvedName)
                if not CLF._keybindCache[lowerName] then
                  CLF._keybindCache[lowerName] = e.key
                end
              end
            elseif mOk and mSpellName then
              local cleanMacroSpell = DetaintStr(mSpellName)
              if cleanMacroSpell then
                local lowerName = string.lower(cleanMacroSpell)
                if not CLF._keybindCache[lowerName] then
                  CLF._keybindCache[lowerName] = e.key
                end
              end
            end
          end
          for _, t in pairs(CLF._trinkets) do
            if t.hasUse and t.itemID then
              local rawMacroSpell = GetMacroSpell and Detaint(GetMacroSpell(e.id)) or nil
              local rawMacroItem = GetMacroItem and Detaint(GetMacroItem(e.id)) or nil
              if rawMacroSpell and t.spellID and rawMacroSpell == t.spellID then
                CLF._keybindCache[string.lower(t.itemName or t.spellName)] = e.key
              elseif rawMacroItem and rawMacroItem == t.itemID then
                CLF._keybindCache[string.lower(t.itemName or t.spellName)] = e.key
              end
            end
          end
        end
      end
    end
  end

  if CLF._spellAliases then
    local propagated = 0
    for spellName, aliases in pairs(CLF._spellAliases) do
      local existingKb = CLF._keybindCache[spellName]
      if existingKb then
        for _, alt in ipairs(aliases) do
          if not CLF._keybindCache[alt] then
            CLF._keybindCache[alt] = existingKb
            propagated = propagated + 1
          end
        end
      else
        for _, alt in ipairs(aliases) do
          local altKb = CLF._keybindCache[alt]
          if altKb then
            CLF._keybindCache[spellName] = altKb
            propagated = propagated + 1
            for _, alt2 in ipairs(aliases) do
              if not CLF._keybindCache[alt2] then
                CLF._keybindCache[alt2] = altKb
                propagated = propagated + 1
              end
            end
            break
          end
        end
      end
    end
    if propagated > 0 and CLF.debugEnabled then
      CLF.Log("DEBUG", "Keybind alias propagation: " .. propagated .. " spell(s)")
    end
  end

  CLF._keybindCacheDirty = false
  if CLF.debugEnabled then
    CLF.Log("DEBUG", "Keybind scan: " .. (function()
      local c = 0; for _ in pairs(CLF._keybindCache) do c = c + 1 end; return c
    end)() .. " spell(s) mapped")
  end
end

function CLF.GetKeybind(spellName)
  if CLF._keybindCacheDirty then
    CLF.ScanAllKeybinds()
  end
  local lk = string.lower(spellName)
  local kb = CLF._keybindCache[lk]
  if kb then return kb end
  if CLF._spellAliases then
    local aliases = CLF._spellAliases[lk]
    if aliases then
      for _, alt in ipairs(aliases) do
        local altKb = CLF._keybindCache[alt]
        if altKb then return altKb end
      end
    end
  end
  return nil
end

-- ── §H19: Form / Stance / Shapeshift Awareness ──
-- Detects and caches the player's current shapeshift form (bear, cat, moonkin, etc.).
-- Used by Druid/Warrior/Paladin SimC conditions like form.bear_form.
-- In WoW 12.0, GetShapeshiftFormInfo() was removed. GetShapeshiftForm() still
-- returns the form index (NOT removed). We use a 3-tier detection chain:
-- 1. GetShapeshiftForm() → FORM_INDEX_MAP (hardcoded per class, always works)
-- 2. Buff-based scan via FindAura (final fallback if index is 0)
-- GetShapeshiftFormInfo is NOT used -- it was removed in 12.0.
local GetShapeshiftForm = GetShapeshiftForm
CLF._cachedForm = nil
CLF._cachedFormName = "caster"
CLF._cachedFormTime = 0

local FORM_KEYWORDS = {
  { pattern = "bear",       name = "bear" },
  { pattern = "dire bear",  name = "bear" },
  { pattern = "cat",        name = "cat" },
  { pattern = "moonkin",    name = "moonkin" },
  { pattern = "boomkin",    name = "moonkin" },
  { pattern = "travel",     name = "travel" },
  { pattern = "aquatic",    name = "travel" },
  { pattern = "flight",     name = "travel" },
  { pattern = "stag",       name = "travel" },
  { pattern = "cheetah",    name = "travel" },
  { pattern = "tree",       name = "tree" },
  { pattern = "treant",     name = "tree" },
  { pattern = "shadow",     name = "shadowform" },
  { pattern = "battle",     name = "battle" },
  { pattern = "defensive",  name = "defensive" },
  { pattern = "berserker",  name = "berserker" },
  { pattern = "stealth",    name = "stealth" },
  { pattern = "ghost",      name = "ghost_wolf" },
  { pattern = "wolf",       name = "ghost_wolf" },
}

local FORM_INDEX_MAP = {
  DRUID   = { [1] = "bear", [2] = "cat", [3] = "travel", [4] = "moonkin", [5] = "tree" },
  ROGUE   = { [1] = "stealth" },
  PRIEST  = { [1] = "shadowform" },
  SHAMAN  = { [1] = "ghost_wolf" },
}

local FORM_BUFFS = {
  { search = "moonkin form", name = "moonkin" },
  { search = "bear form",    name = "bear" },
  { search = "dire bear",    name = "bear" },
  { search = "cat form",     name = "cat" },
  { search = "travel form",  name = "travel" },
  { search = "tree of life", name = "tree" },
  { search = "treant form",  name = "tree" },
  { search = "shadowform",   name = "shadowform" },
  { search = "ghost wolf",   name = "ghost_wolf" },
  { search = "stealth",      name = "stealth" },
}

function CLF.InvalidateFormCache()
  CLF._cachedForm = nil
end

function CLF.IsForm(name)
  local config = CLF_Config or CLF_DefaultConfig
  if not config or not config.hud or not config.hud.formAwareness then return true end
  return CLF.CurrentForm() == name
end

function CLF.CurrentForm()
  if CLF._cachedForm ~= nil then
    local now = GetTime()
    if (now - CLF._cachedFormTime) < 3.0 then
      return CLF._cachedFormName
    end
    CLF._cachedForm = nil
  end

  local formIndex = 0
  if GetShapeshiftForm then
    local detainted = Detaint(GetShapeshiftForm(), "GetShapeshiftForm")
    if detainted and detainted > 0 then
      formIndex = detainted
    end
  end
  local formName = "caster"
  local matched = false

  for _, fb in ipairs(FORM_BUFFS) do
    local found = FindAura("player", fb.search, "HELPFUL")
    if found then
      formName = fb.name
      matched = true
      if formIndex > 0 then
        CLF._learnedFormIndex = CLF._learnedFormIndex or {}
        CLF._learnedFormIndex[formIndex] = fb.name
      end
      break
    end
  end

  if not matched and formIndex > 0 then
    if CLF._learnedFormIndex and CLF._learnedFormIndex[formIndex] then
      formName = CLF._learnedFormIndex[formIndex]
      matched = true
    else
      local config = CLF_Config or CLF_DefaultConfig
      local rawClass = config and config.spec and config.spec.className
      if rawClass then
        local classKey = string.upper(string.gsub(rawClass, " ", ""))
        local classMap = FORM_INDEX_MAP[classKey]
        if classMap and classMap[formIndex] then
          formName = classMap[formIndex]
          matched = true
        end
      end
      if not matched then
        formName = "form" .. formIndex
      end
    end
  end

  CLF._cachedForm = formIndex
  CLF._cachedFormName = formName
  CLF._cachedFormTime = GetTime()
  return formName
end

-- Pet/guardian tracking
function CLF.PetActive(petName)
  local rawPE = UnitExists and UnitExists("pet")
  local peOK = rawPE ~= nil and ((issecretvalue and issecretvalue(rawPE)) or (rawPE and true or false))
  if peOK then
    local rawPD = UnitIsDead and UnitIsDead("pet")
    local pDead = false
    if rawPD ~= nil and not (issecretvalue and issecretvalue(rawPD)) then
      pDead = rawPD and true or false
    end
    if not pDead then return true end
  end
  local searchLower = string.lower(string.gsub(petName, "_", " "))
  for i = 1, 5 do
    local haveTotem, rawName = GetTotemInfo(i)
    if DetaintBool(haveTotem) and type(rawName) ~= "nil" then
      local nameStr = DetaintStr(rawName)
      if nameStr then
        local lowerName = string.lower(nameStr)
        if string.find(lowerName, searchLower, 1, true) then return true end
      end
    end
  end
  return CLF.BuffUp(petName)
end

function CLF.PetRemains(petName)
  for i = 1, 5 do
    local haveTotem, rawName, startTime, duration = GetTotemInfo(i)
    local name = DetaintStr(rawName)
    if DetaintBool(haveTotem) and name and string.find(string.lower(name), string.gsub(petName, "_", " "), 1, true) then
      startTime = Detaint(startTime) or 0
      duration = Detaint(duration) or 0
      local remains = (startTime + duration) - GetTime()
      return remains > 0 and remains or 0
    end
  end
  return CLF.BuffRemains(petName)
end

-- Totem tracking
function CLF.TotemActive(totemName)
  for i = 1, 5 do
    local haveTotem, rawName = GetTotemInfo(i)
    local name = DetaintStr(rawName)
    if DetaintBool(haveTotem) and name and string.find(string.lower(name), string.gsub(totemName, "_", " "), 1, true) then return true end
  end
  return false
end

function CLF.TotemRemains(totemName)
  for i = 1, 5 do
    local haveTotem, rawName, startTime, duration = GetTotemInfo(i)
    local name = DetaintStr(rawName)
    if DetaintBool(haveTotem) and name and string.find(string.lower(name), string.gsub(totemName, "_", " "), 1, true) then
      startTime = Detaint(startTime) or 0
      duration = Detaint(duration) or 0
      local remains = (startTime + duration) - GetTime()
      return remains > 0 and remains or 0
    end
  end
  return 0
end

-- Active dots count (number of targets with a dot applied)
function CLF.ActiveDot(dotName)
  if CLF.DebuffUp(dotName) then return 1 end
  return 0
end

-- Spell cast time (uses spell book first, API as fallback OOC)
function CLF.SpellCastTime(spellName)
  local ct = CLF.SpellBookCastTime(spellName)
  if ct and ct > 0 then return ct end
  if not CLF._inCombat then
    local cleanName = NormalizeName(spellName)
    if C_Spell and C_Spell.GetSpellInfo then
      pcall(function()
        local info = C_Spell.GetSpellInfo(cleanName)
        if info and info.castTime then
          ct = info.castTime / 1000
        end
      end)
      if ct and ct > 0 then return ct end
    end
  end
  return 0
end

-- Spell cost
function CLF.SpellCost(spellName)
  local cleanName = NormalizeName(spellName)
  local cached = CLF._spellCosts and CLF._spellCosts[cleanName]
  if cached then return cached end
  if CLF._inCombat ~= true and C_Spell and C_Spell.GetSpellPowerCost then
    local ok, costs = pcall(C_Spell.GetSpellPowerCost, cleanName)
    if ok and costs then
      local specPT = CLF.GetSpecPowerType()
      for _, ci in ipairs(costs) do
        if ci.cost and type(ci.cost) == "number" and ci.cost > 0 then
          if specPT ~= nil and ci.type == specPT then
            CLF._spellCosts[cleanName] = ci.cost
            return ci.cost
          elseif specPT == nil then
            CLF._spellCosts[cleanName] = ci.cost
            return ci.cost
          end
        end
      end
    end
  end
  return 0
end

-- Buff duration (total base duration, not remaining)
function CLF.BuffDuration(buffName)
  local cleanName = NormalizeName(buffName)
  if CLF._inCombat ~= true and C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName then
    local ok, aura = pcall(C_UnitAuras.GetAuraDataBySpellName, "player", cleanName)
    if ok and aura then
      local d = Detaint(aura.duration)
      if d and d > 0 then return d end
    end
  end
  return 0
end

-- Buff max stacks (returns max possible stacks for a buff)
function CLF.BuffMaxStacks(buffName)
  local cleanName = NormalizeName(buffName)
  if CLF._inCombat ~= true and C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName then
    local ok, aura = pcall(C_UnitAuras.GetAuraDataBySpellName, "player", cleanName)
    if ok and aura then
      local mc = Detaint(aura.maxCharges)
      if mc and mc > 0 then return mc end
    end
  end
  return 1
end

-- Current spell charges (context-dependent, uses last evaluated spell)
CLF._lastEvalSpell = nil
function CLF.CurrentCharges()
  if CLF._lastEvalSpell then return CLF.CooldownCharges(CLF._lastEvalSpell) end
  return 0
end

function CLF.CurrentMaxCharges()
  if CLF._lastEvalSpell then
    local cleanName = string.lower(NormalizeName(CLF._lastEvalSpell))
    local chargeInfo = CLF._chargeState and CLF._chargeState[cleanName]
    if chargeInfo then return chargeInfo.max or 1 end
    local _, mx = SafeGetSpellCharges(CLF._lastEvalSpell)
    if mx then return mx end
  end
  return 1
end

-- DK runes
function CLF.Runes()
  local count = 0
  for i = 1, 6 do
    local _, _, ready = GetRuneCooldown(i)
    if DetaintBool(ready) then count = count + 1 end
  end
  return count
end

-- DoT pandemic tracking: returns true if debuff should be refreshed
-- Pandemic window = base duration * 0.3 (30% remaining = safe to reapply)
function CLF.DebuffPandemic(debuffName, baseDuration)
  baseDuration = baseDuration or 18
  local remains = CLF.DebuffRemains(debuffName)
  if remains <= 0 then return true end
  return remains < (baseDuration * 0.3)
end

CLF._dotSpells = {
  ["sunfire"]          = { debuff = "sunfire",          duration = 18 },
  ["moonfire"]         = { debuff = "moonfire",         duration = 22 },
  ["stellar flare"]    = { debuff = "stellar flare",    duration = 24 },
  ["rake"]             = { debuff = "rake",             duration = 15 },
  ["rip"]              = { debuff = "rip",              duration = 24 },
  ["thrash"]           = { debuff = "thrash",           duration = 15 },
  ["corruption"]       = { debuff = "corruption",       duration = 14 },
  ["agony"]            = { debuff = "agony",            duration = 18 },
  ["immolate"]         = { debuff = "immolate",         duration = 18 },
  ["flame shock"]      = { debuff = "flame shock",      duration = 18 },
  ["vampiric touch"]   = { debuff = "vampiric touch",   duration = 21 },
  ["shadow word pain"] = { debuff = "shadow word pain", duration = 16 },
  ["devouring plague"] = { debuff = "devouring plague", duration = 6 },
  ["serpent sting"]    = { debuff = "serpent sting",     duration = 18 },
  ["black arrow"]      = { debuff = "black arrow",      duration = 18 },
  ["rupture"]          = { debuff = "rupture",           duration = 24 },
  ["garrote"]          = { debuff = "garrote",           duration = 18 },
  ["crimson tempest"]  = { debuff = "crimson tempest",   duration = 14 },
  ["doom"]             = { debuff = "doom",              duration = 20 },
  ["unstable affliction"] = { debuff = "unstable affliction", duration = 16 },
}

CLF._dotCastLog = {}

function CLF.RecordDotCast(spellCleanName)
  local dotInfo = CLF._dotSpells[spellCleanName]
  if not dotInfo then return end
  local guid = CLF._targetGUID
  if not guid then
    if UnitGUID then
      local ok, raw = pcall(UnitGUID, "target")
      if ok and raw then
        local g = DetaintStr and DetaintStr(raw) or nil
        if g then guid = g end
      end
    end
  end
  if not guid then return end
  local now = GetTime()
  CLF._dotCastLog[spellCleanName] = { guid = guid, castTime = now }
  for k, v in pairs(CLF._dotCastLog) do
    if k ~= spellCleanName then
      local di = CLF._dotSpells[k]
      if di and (now - v.castTime) > di.duration then
        CLF._dotCastLog[k] = nil
      end
    end
  end
  if CLF.debugEnabled then
    CLF.Log("DOT", "Recorded DoT cast: " .. spellCleanName .. " on " .. string.sub(guid, 1, 18) .. " (lockout " .. dotInfo.duration .. "s)")
  end
end

function CLF.ClearDotCastLog()
  wipe(CLF._dotCastLog)
end

function CLF.IsDotRefreshable(spellCleanName)
  local dotInfo = CLF._dotSpells[spellCleanName]
  if not dotInfo then return true end
  local entry = CLF._dotCastLog[spellCleanName]
  if entry then
    local guid = CLF._targetGUID
    if not guid then
      if UnitGUID then
        local ok, raw = pcall(UnitGUID, "target")
        if ok and raw then
          local g = DetaintStr and DetaintStr(raw) or nil
          if g then guid = g end
        end
      end
    end
    local guidMatch = guid and entry.guid == guid
    local noGuid = not guid
    if guidMatch or noGuid then
      local elapsed = GetTime() - entry.castTime
      local pandemicWindow = dotInfo.duration * 0.15
      local lockoutEnd = dotInfo.duration - pandemicWindow
      if elapsed < lockoutEnd then
        if CLF.debugEnabled then
          CLF._dotLogThrottle = CLF._dotLogThrottle or {}
          local now = GetTime()
          local lastLog = CLF._dotLogThrottle[spellCleanName] or 0
          if now - lastLog >= 5 then
            CLF._dotLogThrottle[spellCleanName] = now
            CLF.Log("DOT", "DoT locked: " .. spellCleanName .. " (elapsed=" .. string.format("%.1f", elapsed) .. "s, lockout=" .. string.format("%.1f", lockoutEnd) .. "s)")
          end
        end
        return false
      end
    end
  end
  return CLF.DebuffPandemic(dotInfo.debuff, dotInfo.duration)
end

function CLF.ResolveDoTSpellIds()
  if not C_Spell or not C_Spell.GetSpellInfo then return end
  for dotName, dotInfo in pairs(CLF._dotSpells) do
    if not CLF._spellNameToId[dotName] then
      local displayName = string.gsub(dotName, "(%a)([%w_']*)", function(first, rest)
        return string.upper(first) .. rest
      end)
      local ok, info = pcall(C_Spell.GetSpellInfo, displayName)
      if ok and type(info) == "table" and info.spellID then
        local sid = Detaint(info.spellID)
        if sid then
          CLF._spellNameToId[dotName] = sid
          CLF._spellIdToName[sid] = dotName
          dotInfo.spellId = sid
        end
      end
    end
  end
end

-- GCD tracking
function CLF.GetGCD()
  local start, duration = SafeGetSpellCooldown(61304)
  if start and start > 0 and duration and duration > 0 then
    local elapsed = GetTime() - start
    return elapsed, duration
  end
  return 0, 0
end

CLF._gcdCache = { start = 0, duration = 0 }
CLF._hasteCache = 0

function CLF.UpdateHaste()
  if GetHaste then
    local raw = GetHaste()
    if raw ~= nil then
      local val = Detaint(raw, "GetHaste")
      if val ~= nil then
        CLF._hasteCache = val
        local ss = CLF._statsSnapshot
        if ss then
          ss.haste = val
          ss.gcdHasted = mathMax(ss.gcdMin or 0.75, (ss.gcdBase or 1.5) / (1 + val / 100))
        end
      end
    end
  end
end

function CLF.GetCachedHaste()
  CLF.UpdateHaste()
  return CLF._hasteCache or 0
end

function CLF.MarkGCDStart()
  local now = GetTime()
  local gcdDur = CLF.GCDMax()
  if gcdDur < 0.75 then gcdDur = 0.75 end
  if not CLF._inCombat and C_Spell and C_Spell.GetSpellCooldown then
    local ok, info = pcall(C_Spell.GetSpellCooldown, 61304)
    if ok and info then
      local s = info.startTime
      local d = info.duration
      if s and d then
        local sClean = Detaint(s, "GCDStart")
        local dClean = Detaint(d, "GCDDur")
        if sClean and dClean and dClean > 0 and dClean < 2.0 then
          CLF._gcdCache.start = sClean
          CLF._gcdCache.duration = dClean
          CLF._statsSnapshot.gcdHasted = dClean
          return
        end
      end
    end
  end
  local gc = CLF._gcdCache
  if gc.start > 0 and gc.duration > 0 then
    local age = now - gc.start
    if age >= 0 and age < gc.duration then
      return
    end
  end
  CLF._gcdCache.start = now
  CLF._gcdCache.duration = gcdDur
end

function CLF.GetGCDRaw()
  local cache = CLF._gcdCache
  if cache.start > 0 and cache.duration > 0 then
    local now = GetTime()
    if (now - cache.start) < cache.duration then
      return cache.start, cache.duration
    end
  end
  return 0, 0
end

-- Debug logging system
CLF.debugEnabled = false
CLF.debugVerbose = false
CLF.logBuffer = {}
CLF.LOG_COLORS = {
  DEBUG = "|cFF888888",
  INFO  = "|cFF44CCFF",
  WARN  = "|cFFFF6600",
  EVAL  = "|cFF88FF88",
  GLOW  = "|cFFFFDD00",
  DEF   = "|cFFFF4444",
}

function CLF.Log(level, msg)
  if not CLF.debugEnabled then return end
  if level == "DEBUG" and not CLF.debugVerbose then return end

  local color = CLF.LOG_COLORS[level] or "|cFFCCCCCC"
  local timestamp = string.format("%.1f", GetTime() % 1000)
  local line = string.format("|cFFD4A632[CLF %s]|r %s[%s]|r %s", timestamp, color, level, msg)

  table.insert(CLF.logBuffer, line)
  if #CLF.logBuffer > 200 then
    table.remove(CLF.logBuffer, 1)
  end

  if DMGA_WD_Log then
    local ev = {
      id = #DMGA_WD_Log + 1,
      type = "CLF_" .. level,
      summary = msg,
      time = date("%H:%M:%S"),
      gameTime = timestamp,
      rawGameTime = GetTime(),
      extra = {},
    }
    table.insert(DMGA_WD_Log, ev)
    if #DMGA_WD_Log > 500 then table.remove(DMGA_WD_Log, 1) end
  end

  if DMGA_WD_Config and DMGA_WD_Config.chatAlerts then
    print(line)
  end
end

-- Glow tracking: monitors which action buttons have overlay glows active
-- This catches WoW built-in procs AND third-party addon highlights (MaxDPS, etc.)
CLF.glowingSpells = {}
CLF.glowScanDirty = true

function CLF.ScanGlowingButtons()
  wipe(CLF.glowingSpells)

  for i = 1, 120 do
    local btn = _G["ActionButton" .. i]
      or _G["MultiBarBottomLeftButton" .. ((i - 13) > 0 and (i - 12) or nil)]
      or _G["MultiBarBottomRightButton" .. ((i - 25) > 0 and (i - 24) or nil)]
      or _G["MultiBarRightButton" .. ((i - 37) > 0 and (i - 36) or nil)]
      or _G["MultiBarLeftButton" .. ((i - 49) > 0 and (i - 48) or nil)]

    if not btn then
      -- Direct slot-based lookup for all standard bars
      local barButtons = {
        "ActionButton",           -- Main bar: 1-12
        "MultiBarBottomLeftButton", -- Bar 2: 1-12
        "MultiBarBottomRightButton", -- Bar 3: 1-12
        "MultiBarRightButton",    -- Bar 4: 1-12
        "MultiBarLeftButton",     -- Bar 5: 1-12
      }
      local barIdx = math.ceil(i / 12)
      local btnIdx = ((i - 1) % 12) + 1
      if barButtons[barIdx] then
        btn = _G[barButtons[barIdx] .. btnIdx]
      end
    end

    if btn then
      -- Check for overlay glow (WoW native proc highlight)
      local overlay = btn.SpellActivationAlert
        or btn.overlay
        or (btn.GetOverlayGlow and btn:GetOverlayGlow())

      local hasGlow = false
      if overlay and DetaintBool(overlay:IsShown()) then
        hasGlow = true
      end

      if not hasGlow and ActionButton_IsOverlayGlowShowing then
        hasGlow = DetaintBool(ActionButton_IsOverlayGlowShowing(btn))
      end

      if not hasGlow and btn.__LBGoverlay and DetaintBool(btn.__LBGoverlay:IsShown()) then
        hasGlow = true
      end

      if not hasGlow then
        for _, child in ipairs({btn:GetChildren()}) do
          if child.animIn or child.animOut then
            if DetaintBool(child:IsShown()) then
              hasGlow = true
              break
            end
          end
        end
      end

      if hasGlow then
        local rawAT2, rawAID2 = GetActionInfo(i)
        local actionType = DetaintStr(rawAT2)
        local id = Detaint(rawAID2)
        if actionType == "spell" then
          local name = SafeGetSpellName(id)
          if name then
            CLF.glowingSpells[string.lower(name)] = true
          end
        end
      end
    end
  end

  CLF.glowScanDirty = false
end

function CLF.IsSpellGlowing(spellName)
  if CLF.glowScanDirty then
    CLF.ScanGlowingButtons()
  end
  return CLF.glowingSpells[string.lower(spellName)] or false
end
`;
}

/**
 * Generates Engine.lua -- the combat intelligence core.
 *
 * This file implements the "brain" of the addon:
 *
 * ## Combat Mode Detection (§E1)
 * Auto-switches between Single Target and AoE based on enemy count
 * vs. the configurable aoeThreshold. Supports manual lock via `/dmga mode`.
 *
 * ## Interrupt Override (§E2)
 * When target is casting an interruptible spell, the interrupt ability is
 * force-promoted to slot 1 with a red border, overriding normal priority.
 * Integrates with DBM/BigWigs alert callbacks.
 *
 * ## SimC APL Builder (§E3)
 * At login, builds a filtered priority list from CLF_APL, compiles each
 * condition string into a callable function via `loadstring()`, and
 * caches spell metadata (icon, keybind, known status).
 *
 * ## Multi-Signal Action Bar Scanner (§E4)
 * Scans all 120+ action bar slots every tick, classifying each spell's
 * state into one of four signal tiers:
 *   - SIGNAL_ANTS (1) -- spinning/marching ants glow (highest Blizzard signal)
 *   - SIGNAL_ASSISTED (2) -- Blizzard's static yellow highlight
 *   - SIGNAL_PROC (3) -- glow/proc active
 *   - SIGNAL_READY (4) -- usable + off cooldown
 *
 * ## Scoring & APL Evaluation (§E5)
 * Combines signal type × SimC priority rank × mode relevance into a
 * composite score. The top N abilities become the Guitar Hero queue.
 *
 * @param data - Single spec's addon data bundle.
 */
