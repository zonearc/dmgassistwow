-- CLF Engine -- Enhanced Highlight Assist Pro (Midnight 12.0 compliant)
-- Architecture: Multi-signal intelligence layer over Blizzard's Assisted Combat system
--
-- Data sources (all legal in 12.0 -- information display, NOT automation):
--   1. C_AssistedCombat.GetNextCastSpell(false) -- Blizzard's SimC-powered recommendation
--   2. C_AssistedCombat.GetRotationSpells() -- full spec rotation spell discovery
--   3. C_SpellActivationOverlay.IsSpellOverlayed(id) -- proc/glow detection
--   4. C_Spell.IsSpellUsable(id) -- clean non-secret usability booleans
--   5. C_Spell.GetSpellCooldownDuration(id) -- DurationObject for shadow CD frames
--   6. Action bar button glow state -- fallback proc detection
--   7. Player buffs/debuffs (C_UnitAuras) -- YOUR auras, spell IDs readable
--   8. Player resources (UnitPower) -- mana/energy/rage/etc
--   9. SimC priority table -- static ranking data for queue depth
--
-- NOTE: C_SpellHighlight was REMOVED in WoW 12.0 Midnight.
-- This addon uses C_AssistedCombat (new 12.0 API) as the primary signal source.
local _, CLF = ...
local L = CLF.L or setmetatable({}, {__index = function(_, k) return k end})

local tableInsert = table.insert
local tableSort = table.sort
local tostring = tostring
local GetTime = GetTime
local UnitPower = UnitPower
local UnitPowerMax = UnitPowerMax
local mathMax = math.max
local mathMin = math.min
local snap = CLF._snap
local TaintCall = CLF.TaintCall
local TaintHit = CLF.TaintHit
local TaintClean = CLF.TaintClean
local TaintFallback = CLF.TaintFallback

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

CLF.lastRecommendation = nil
CLF.lastQueue = {}
CLF.combatMode = "ST"
CLF._lastInterruptState = false
CLF._modeLock = nil
CLF._stableSlot1Key = nil

CLF._assistedEverSeen = false
CLF._assistedCheckTicks = 0
CLF._assistedWarningShown = false
CLF._assistedDismissed = false

-- C_AssistedCombat state (new 12.0 APIs)
CLF._acNextCastId = nil
CLF._acNextCastName = nil
CLF._acAvailable = nil
CLF._acRotationSpells = nil
CLF._acRotationSet = nil
CLF._acRotationNames = nil
CLF._acLastRotationRefresh = 0

-- Refresh the Assisted Combat recommendation (called every tick)
function CLF.RefreshAssistedCombat()
  if not C_AssistedCombat then
    CLF._acAvailable = false
    CLF._acNextCastId = nil
    CLF._acNextCastName = nil
    return
  end

  if CLF._acAvailable == nil then
    local avOk, avail, reason = pcall(C_AssistedCombat.IsAvailable)
    if avOk then
      local availClean = false
      if issecretvalue and issecretvalue(avail) then
        availClean = true
      else
        availClean = avail and true or false
      end
      if availClean then
        CLF._acAvailable = true
      else
        CLF._acAvailable = false
        if CLF.debugEnabled then
          local reasonStr = ""
          if reason and not (issecretvalue and issecretvalue(reason)) then reasonStr = tostring(reason) end
          CLF.Log("AC", "C_AssistedCombat not available: " .. reasonStr)
        end
        return
      end
    else
      CLF._acAvailable = false
      return
    end
  end

  if CLF._acAvailable == false then return end

  local ok, nextId = pcall(C_AssistedCombat.GetNextCastSpell, false)
  if ok and nextId then
    if issecretvalue and issecretvalue(nextId) then
    else
      local numId = tonumber(nextId)
      if numId and numId > 0 then
        CLF._acNextCastId = numId
        CLF._acNextCastTime = GetTime()
        local nOk, nName = pcall(function()
          return C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(numId)
        end)
        if nOk and nName and not (issecretvalue and issecretvalue(nName)) then
          CLF._acNextCastName = nName
        end
      end
    end
  end
  if CLF._acNextCastId and CLF._acNextCastTime then
    local age = GetTime() - CLF._acNextCastTime
    if age > 3.0 then
      CLF._acNextCastId = nil
      CLF._acNextCastName = nil
      CLF._acNextCastTime = nil
    end
  end
end

-- Build the rotation spell map from C_AssistedCombat.GetRotationSpells()
-- Called on login, talent changes, and periodically (every 30s).
-- Filters by IsPlayerSpell to exclude untalented spells and pre-caches icons.
function CLF.BuildRotationSpellMap()
  if not C_AssistedCombat or not C_AssistedCombat.GetRotationSpells then
    return
  end

  local ok, spells = pcall(C_AssistedCombat.GetRotationSpells)
  if not ok or not spells then return end
  if issecretvalue and issecretvalue(spells) then return end

  local idSet = {}
  local nameMap = {}
  local count = 0
  local skipped = 0

  for i = 1, #spells do
    local sid = spells[i]
    if sid and not (issecretvalue and issecretvalue(sid)) then
      local numId = tonumber(sid)
      if numId and numId > 0 then
        local known = false
        if IsPlayerSpell then
          local kOk, kVal = pcall(IsPlayerSpell, numId)
          if kOk then
            if issecretvalue and issecretvalue(kVal) then
              known = true
            else
              known = kVal and true or false
            end
          end
        else
          known = true
        end

        if known then
          idSet[numId] = true
          count = count + 1
          local nOk, sName = pcall(function()
            return C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(numId)
          end)
          if nOk and sName and not (issecretvalue and issecretvalue(sName)) then
            local cleanName = string.gsub(string.gsub(string.lower(sName), "_", " "), ":", "")
            nameMap[cleanName] = numId

            if C_Spell and C_Spell.EnableSpellRangeCheck then
              pcall(C_Spell.EnableSpellRangeCheck, numId, true)
            end

            CLF.ResolveSpellIcon(cleanName, numId)
          end
        else
          skipped = skipped + 1
        end
      end
    end
  end

  CLF._acRotationSpells = spells
  CLF._acRotationSet = idSet
  CLF._acRotationNames = nameMap
  CLF._acLastRotationRefresh = GetTime()

  if not CLF._spellSlotIds then CLF._spellSlotIds = {} end
  for cleanName, sid in pairs(nameMap) do
    if not CLF._spellSlotIds[cleanName] then
      CLF._spellSlotIds[cleanName] = sid
    end
  end

  CLF.Log("INFO", "AssistedCombat rotation: " .. count .. " spells known, " .. skipped .. " untalented filtered")

  if not CLF._inCombat then
    if CLF.DiscoverSpellOverrides then
      CLF.DiscoverSpellOverrides()
    end
    if CLF.ClassifySpells then
      CLF.ClassifySpells()
    end
    if CLF._ScanPlayerBuffsForEclipse then
      CLF._ScanPlayerBuffsForEclipse()
    end
  end
end

-- ── §E1: Combat Mode Detection ──
-- Auto-switches between ST and AoE based on enemy count vs. aoeThreshold.
-- Supports manual lock via /dmga mode st|aoe|auto.
function CLF.SetCombatMode(mode)
  CLF.combatMode = mode
end

function CLF.LockMode(mode)
  CLF._modeLock = mode
  CLF.combatMode = mode
  if mode == "AoE" then
    CLF.PlayEventSound("aoeSwitch")
  elseif mode == "ST" then
    CLF.PlayEventSound("stSwitch")
  end
  print("|cFFD4A632[DMGAssist]|r Mode locked: |cFFFFD100" .. mode .. "|r (type /dmga mode auto to unlock)")
end

function CLF.ToggleModeLock()
  if CLF._modeLock then
    CLF._modeLock = nil
    local contentDefault = CLF.GetContentDefault()
    CLF.combatMode = contentDefault
    print("|cFFD4A632[DMGAssist]|r Mode: |cFF00FF00" .. contentDefault .. "|r (content default)")
    CLF.ShowModeFlash(contentDefault)
    if contentDefault == "AoE" then
      CLF.PlayEventSound("aoeSwitch")
    elseif contentDefault == "ST" then
      CLF.PlayEventSound("stSwitch")
    end
  else
    local newMode = CLF.combatMode == "ST" and "AoE" or "ST"
    CLF.LockMode(newMode)
    CLF.ShowModeFlash(newMode)
  end
end

function CLF.CycleMode()
  if CLF._modeLock == "ST" or (not CLF._modeLock and CLF.combatMode == "ST") then
    CLF._modeLock = "AoE"
    CLF.combatMode = "AoE"
    CLF.ShowModeFlash("AoE")
    CLF.PlayEventSound("aoeSwitch")
  else
    CLF._modeLock = "ST"
    CLF.combatMode = "ST"
    CLF.ShowModeFlash("ST")
    CLF.PlayEventSound("stSwitch")
  end
end

function CLF.ToggleCombatRole()
  local config = CLF_Config or CLF_DefaultConfig
  if not config then return end
  local hud = config.hud or {}
  local cur = hud.combatRole or "auto"
  if cur == "auto" then
    local wasAuto = CLF._isTankSpec
    if wasAuto then
      hud.combatRole = "dps"
      CLF.ShowModeFlash("DPS")
      print("|cFFD4A632[DMGAssist]|r Combat role: |cFFFFFF00DPS|r (manual override -- defensive boost OFF)")
    else
      hud.combatRole = "tank"
      CLF.ShowModeFlash("Tank")
      print("|cFFD4A632[DMGAssist]|r Combat role: |cFF00FF00TANK|r (manual override -- defensive boost ON)")
      if not hud.showDefensives then
        hud.showDefensives = true
        print("|cFFD4A632[DMGAssist]|r Show Defensives auto-enabled for Tank Mode")
      end
    end
  elseif cur == "tank" then
    hud.combatRole = "dps"
    CLF.ShowModeFlash("DPS")
    print("|cFFD4A632[DMGAssist]|r Combat role: |cFFFFFF00DPS|r (manual override -- defensive boost OFF)")
  else
    hud.combatRole = "tank"
    CLF.ShowModeFlash("Tank")
    print("|cFFD4A632[DMGAssist]|r Combat role: |cFF00FF00TANK|r (manual override -- defensive boost ON)")
    if not hud.showDefensives then
      hud.showDefensives = true
      print("|cFFD4A632[DMGAssist]|r Show Defensives auto-enabled for Tank Mode")
    end
  end
end

do
  local flashFrame = nil
  local flashText = nil
  local flashTimer = 0

  function CLF.ShowModeFlash(mode)
    if not flashFrame then
      flashFrame = CreateFrame("Frame", "CLF_ModeFlash", UIParent)
      flashFrame:SetFrameStrata("FULLSCREEN_DIALOG")
      flashFrame:SetAllPoints(UIParent)
      flashFrame:SetAlpha(1)
      flashText = flashFrame:CreateFontString(nil, "OVERLAY")
      flashText:SetFont("Fonts\\FRIZQT__.TTF", 64, "THICKOUTLINE")
      flashText:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
      flashText:SetShadowOffset(3, -3)
      flashText:SetShadowColor(0, 0, 0, 0.8)
      flashFrame:Hide()
    end
    local label
    if string.find(mode, "Default", 1, true) then
      label = string.upper(mode) .. " MODE"
    elseif mode == "AoE" then
      label = "AOE MODE"
    elseif mode == "Tank" then
      label = "TANK MODE"
    elseif mode == "DPS" then
      label = "DPS MODE"
    else
      label = "ST MODE"
    end
    flashText:SetText("DMGAssist: " .. label)
    flashText:SetTextColor(1, 0.15, 0.15, 1)
    flashFrame:SetAlpha(1)
    flashFrame:Show()
    flashTimer = GetTime()
    flashFrame:SetScript("OnUpdate", function(self)
      local elapsed = GetTime() - flashTimer
      if elapsed > 1.5 then
        self:Hide()
        self:SetScript("OnUpdate", nil)
      elseif elapsed > 0.8 then
        self:SetAlpha(1 - ((elapsed - 0.8) / 0.7))
      end
    end)
  end
end

function CLF.GetContentDefault()
  local config = CLF_Config or CLF_DefaultConfig
  local hud = config and config.hud
  if not hud then return "AoE" end
  local ok, iType, diffId = pcall(GetInstanceInfo)
  if not ok then return hud.defaultModeWorld or "AoE" end
  if iType == "party" then
    return hud.defaultModeDungeon or "AoE"
  elseif iType == "raid" then
    return hud.defaultModeRaid or "AoE"
  elseif iType == "scenario" then
    return hud.defaultModeDelve or "AoE"
  else
    return hud.defaultModeWorld or "AoE"
  end
end

function CLF.DetectCombatMode()
  if CLF._modeLock then
    CLF.combatMode = CLF._modeLock
    return
  end
  CLF.combatMode = CLF.GetContentDefault()
end

CLF.activeAlerts = {}

CLF._testInterruptSpell = nil

-- ── §E2: Interrupt Override ──
-- When target is casting an interruptible spell, force-promotes interrupt to slot 1.
-- Also triggered by DBM/BigWigs boss mod callbacks.
function CLF.ShouldShowInterrupt()
  if CLF._testInterruptActive then
    return true, CLF._testInterruptSpell
  end

  if CLF._lastInterruptCastTime then
    local elapsed = GetTime() - CLF._lastInterruptCastTime
    if elapsed < 1.0 then return false, nil end
    if elapsed >= 1.0 then CLF._lastInterruptCastTime = nil end
  end

  if not CLF.TargetIsCasting() then return false, nil end

  local config = CLF_Config or CLF_DefaultConfig
  if not config then return false, nil end
  local interrupts = config.interrupts or {}

  for _, alert in ipairs(interrupts) do
    if CLF.activeAlerts[alert.spellId] then
      return true, alert.interruptSpell
    end
  end

  local cs = CLF._castState and CLF._castState.target
  if cs and cs.casting and cs.spellName then
    local castName = cs.spellName
    for _, alert in ipairs(interrupts) do
      if castName == alert.alertName then
        return true, alert.interruptSpell
      end
    end
    return true, nil
  end
  if CLF.TargetIsCasting() then
    return true, nil
  end

  return false, nil
end

-- ── §E3: SimC APL Builder ──
-- Converts CLF_APL (data table from Config.lua) into runtime-ready form:
-- 1. Uses inline conditionFn closures (compiled at file parse time, NOT loadstring)
-- 2. Resolves spell IDs from names using SafeGetSpellName()
-- 3. Caches spell icons, keybinds, and "known" status
-- 4. Filters by combat mode (ST/AoE/Both) based on current CLF.combatMode
-- Priority map: spell name -> best priority number (lower = higher priority)
-- Mode map: spell name -> mode tag (ST/AoE/Both) for smart filtering
-- Spell data: spell name -> {icon, keybind, mode, isOffensive} for display
CLF._priorityMap = nil
CLF._modeMap = nil
CLF._cdMap = {}
CLF._spellData = nil
CLF._filteredAPL = nil

local RACIAL_BY_RACE = {
  ["Troll"]             = { ["berserking"] = true },
  ["Orc"]               = { ["blood fury"] = true },
  ["DarkIronDwarf"]     = { ["fireblood"] = true },
  ["MagharOrc"]         = { ["ancestral call"] = true },
  ["BloodElf"]          = { ["arcane torrent"] = true },
  ["NightElf"]          = { ["shadowmeld"] = true },
  ["Tauren"]            = { ["war stomp"] = true },
  ["HighmountainTauren"]= { ["war stomp"] = true },
  ["Dwarf"]             = { ["stoneform"] = true },
  ["LightforgedDraenei"]= { ["lights judgment"] = true },
  ["Goblin"]            = { ["rocket barrage"] = true },
  ["KulTiran"]          = { ["haymaker"] = true },
  ["Vulpera"]           = { ["bag of tricks"] = true },
}

local ALL_RACIALS = {
  ["berserking"] = true, ["blood fury"] = true, ["fireblood"] = true,
  ["ancestral call"] = true, ["arcane torrent"] = true, ["shadowmeld"] = true,
  ["war stomp"] = true, ["stoneform"] = true, ["rocket barrage"] = true,
  ["lights judgment"] = true, ["bag of tricks"] = true, ["haymaker"] = true,
}

local PRE_MIDNIGHT_OVERRIDES = {
  ["druid-balance"] = {
    modeOverrides = {
      ["wild mushroom"] = "AoE",
    },
    priorityOverrides = {
      ["starfire"] = 9,
    },
    cdOverrides = {
      ["celestial alignment"] = true,
      ["incarnation chosen of elune"] = true,
      ["fury of elune"] = true,
      ["starfall"] = true,
    },
  },
  ["rogue-ass"] = {
    priorityOverrides = {
      ["deathmark"] = 2,
      ["kingsbane"] = 3,
    },
    cdOverrides = {
      ["deathmark"] = true,
    },
  },
  ["evoker-aug"] = {
    priorityOverrides = {
      ["ebon might"] = 2,
      ["breath of eons"] = 1,
    },
    cdOverrides = {
      ["breath of eons"] = true,
    },
  },
}

local function ApplyPreMidnightOverrides(specId, aplBranch, pMap, mMap, cdMap, sData)
  if aplBranch == "midnight" or aplBranch == "community" then return false end
  local overrides = PRE_MIDNIGHT_OVERRIDES[specId]
  if not overrides then return false end
  local applied = 0
  if overrides.priorityOverrides then
    for spell, prio in pairs(overrides.priorityOverrides) do
      if pMap[spell] then
        pMap[spell] = prio
        applied = applied + 1
      end
    end
  end
  if overrides.modeOverrides then
    for spell, m in pairs(overrides.modeOverrides) do
      if mMap[spell] then
        mMap[spell] = m
        applied = applied + 1
      end
    end
  end
  if overrides.cdOverrides then
    for spell, val in pairs(overrides.cdOverrides) do
      if sData[spell] then
        cdMap[spell] = val
        if sData[spell] then sData[spell].isCooldown = val end
        applied = applied + 1
      end
    end
  end
  if applied > 0 then
    CLF.Log("INFO", "Pre-Midnight overlay applied for " .. specId .. " (" .. applied .. " adjustments, aplBranch=" .. aplBranch .. ")")
  end
  return applied > 0
end

function CLF.BuildFilteredAPL()
  local config = CLF_Config or CLF_DefaultConfig
  if not config then
    CLF.LogIssue("Config", "BuildFilteredAPL skipped -- no config loaded yet")
    CLF._filteredAPL = { interrupts = {}, rotation = {}, precombatState = {}, precombatOpener = {} }
    CLF._priorityMap = {}
    CLF._modeMap = {}
    CLF._cdMap = {}
    CLF._spellData = {}
    return
  end
  local apl = config.apl or {}

  local myRacials = {}
  local playerRace = CLF._playerRace
  if playerRace and RACIAL_BY_RACE[playerRace] then
    myRacials = RACIAL_BY_RACE[playerRace]
  end

  local specRole = config.spec and config.spec.role or "dps"
  local isHealer = (specRole == "Healer")
  local isTank = (specRole == "Tank")
  if isHealer and CLF._dpsAPL then
    local currentForm = CLF.CurrentForm and CLF.CurrentForm() or "caster"
    local formAPLs = CLF._formDpsAPLs or {}
    local dpsEntries = formAPLs[currentForm] or CLF._dpsAPL

    local mergedAPL = {}
    local existingSpells = {}
    for _, e in ipairs(apl) do
      tableInsert(mergedAPL, e)
      if not e.isPrecombat and not e.isInterrupt then
        existingSpells[string.lower(e.spellName)] = true
      end
    end
    local basePrio = 100
    for _, e in ipairs(dpsEntries) do
      if not e.isPrecombat and not e.isInterrupt then
        local dpsKey = string.lower(e.spellName)
        if not existingSpells[dpsKey] then
          local copy = {}
          for k, v in pairs(e) do copy[k] = v end
          copy.priority = basePrio
          basePrio = basePrio + 1
          tableInsert(mergedAPL, copy)
        end
      end
    end
    apl = mergedAPL
    if CLF.debugEnabled then
      local safeForm = (DetaintStr and DetaintStr(currentForm)) or "?"
      CLF.Log("INFO", "Healer DPS fallback: merged " .. safeForm .. " rotation (" .. #mergedAPL .. " entries)")
    end
  end

  local f = { interrupts = {}, rotation = {}, precombatState = {}, precombatOpener = {} }
  local disabled = config._disabledSpells or {}
  local pMap = {}
  local mMap = {}
  local sData = {}
  CLF._cdMap = {}

  CLF._trinketPriority = {}
  CLF._trinketPriority["trinket1"] = 50
  CLF._trinketPriority["trinket2"] = 50

  local autoSpells = { ["auto shot"] = true, ["auto attack"] = true, ["auto_shot"] = true, ["auto_attack"] = true }
  for _, entry in ipairs(apl) do
    local cleanLower = string.gsub(string.gsub(string.lower(entry.spellName), "_", " "), ":", "")
    local isWrongRacial = ALL_RACIALS[cleanLower] and not myRacials[cleanLower]
    if not isWrongRacial and entry.enabled ~= false and not disabled[entry.spellName] and not autoSpells[cleanLower] then
      local isTrinketEntry = string.find(entry.spellName, "^%[Trinket%]") ~= nil

      if entry.isPrecombat then
        local icon = entry.spellIcon
        if not icon or icon == "" then
          icon = CLF.ResolveSpellIcon(entry.spellName)
        end
        entry._resolvedIcon = icon
        if entry.conditionSrc and entry.conditionSrc ~= "" and entry.conditionSrc ~= "return true" then
          local buffArg = string.match(entry.conditionSrc, 'CLF%.BuffUp%("([^"]+)"%)')
          local formArg = string.match(entry.conditionSrc, 'CLF%.IsForm%("([^"]+)"%)')
          local stealthCheck = string.find(entry.conditionSrc, "CLF%.IsStealthed%(%)") ~= nil
          if buffArg then
            entry._stateCheck = "buff"
            entry._stateArg = buffArg
          elseif formArg then
            entry._stateCheck = "form"
            entry._stateArg = formArg
          elseif stealthCheck then
            entry._stateCheck = "stealth"
          end
        end
        if entry.precombatType == "state" then
          tableInsert(f.precombatState, entry)
        else
          tableInsert(f.precombatOpener, entry)
        end
        local cleanName = string.gsub(string.gsub(string.lower(entry.spellName), "_", " "), ":", "")
        pMap[cleanName] = entry.priority < 0 and entry.priority or -200
        mMap[cleanName] = "Both"
        if not sData[cleanName] then
          sData[cleanName] = {
            icon = icon or entry.spellIcon,
            keybind = entry.keybind,
            mode = "Both",
            isOffensive = false,
            conditionFns = {},
          }
        end
        if entry.precombatType == "state" then
          sData[cleanName].isPrecombatStateOnly = true
        end

      elseif isTrinketEntry then
        local trinketTag = string.match(entry.spellName, "^%[Trinket%]%s*(.+)") or ""
        local trinketClean = string.gsub(string.gsub(string.gsub(string.gsub(string.lower(trinketTag), "_", " "), ":", ""), "^%s+", ""), "%s+$", "")
        local matched = false
        for _, t in pairs(CLF._trinkets) do
          if t.hasUse then
            local tNameClean = t.itemName and string.lower(t.itemName) or ""
            local tSlot = t.slotName or ""
            if trinketClean == tSlot or string.find(tNameClean, trinketClean, 1, true) or (trinketClean == "trinket1" and tSlot == "trinket1") or (trinketClean == "trinket2" and tSlot == "trinket2") then
              matched = true
              if entry.priority < (CLF._trinketPriority[tSlot] or 999) then
                CLF._trinketPriority[tSlot] = entry.priority
              end
              if CLF.debugEnabled then
                CLF.Log("INFO", "Trinket APL match: " .. entry.spellName .. " -> " .. (t.itemName or t.slotName) .. " (prio=" .. entry.priority .. ")")
              end
              break
            end
          end
        end
        if not matched and CLF.debugEnabled then
          CLF.Log("DEBUG", "Trinket APL entry unmatched: " .. entry.spellName)
        end

      elseif entry.isInterrupt then
        local intKnown = CLF.IsSpellKnown and CLF.IsSpellKnown(entry.spellName, entry.spellId)
        if intKnown ~= false then
          tableInsert(f.interrupts, entry)
          if not CLF._interruptSpells then CLF._interruptSpells = {} end
          CLF._interruptSpells[string.lower(entry.spellName)] = true
        end
      else
        do
          local entryClean = string.gsub(string.gsub(string.lower(entry.spellName), "_", " "), ":", "")
          local isHardBlocked = CLF._hardBlockSpells and CLF._hardBlockSpells[entryClean]
          local isOOCBlocked = CLF._oocOnlySpells[entryClean]
          local isNRBlocked = CLF._nonRotationSpells[entryClean]
          local spellKnown = CLF.IsSpellKnown and CLF.IsSpellKnown(entry.spellName, entry.spellId)
          if isHardBlocked or isOOCBlocked or isNRBlocked then
            if CLF.debugEnabled then
              CLF.Log("DEBUG", "BuildFilteredAPL: skipping blocked spell: " .. entry.spellName)
            end
          elseif spellKnown == false then
            if CLF.debugEnabled then
              CLF.Log("DEBUG", "BuildFilteredAPL: skipping untalented spell: " .. entry.spellName)
            end
          else
          local liveId = entry.spellId
          if liveId and C_Spell and C_Spell.GetSpellInfo then
            local nOk, nInfo = pcall(C_Spell.GetSpellInfo, NormalizeName(entry.spellName))
            local nameResolvedId = nOk and nInfo and nInfo.spellID and Detaint(nInfo.spellID) or nil
            if nameResolvedId and nameResolvedId ~= liveId then
              local pOk, pVal = false, false
              if IsPlayerSpell then
                pOk, pVal = pcall(IsPlayerSpell, nameResolvedId)
              end
              if pOk and pVal and not (issecretvalue and issecretvalue(pVal)) then
                liveId = nameResolvedId
                if CLF.debugEnabled then
                  CLF.Log("DEBUG", "BuildFilteredAPL: ID override for " .. entry.spellName .. ": " .. entry.spellId .. " -> " .. nameResolvedId)
                end
              end
            end
          end
          tableInsert(f.rotation, entry)
          local cleanName = string.gsub(string.gsub(string.lower(entry.spellName), "_", " "), ":", "")

          if not pMap[cleanName] or entry.priority < pMap[cleanName] then
            pMap[cleanName] = entry.priority
          end

          if entry.isCooldown then
            CLF._cdMap[cleanName] = true
          end

          if not mMap[cleanName] then
            mMap[cleanName] = entry.mode or "Both"
          elseif mMap[cleanName] ~= entry.mode then
            mMap[cleanName] = "Both"
          end

          if not sData[cleanName] then
            local buildIcon = entry._resolvedIcon or CLF.ResolveSpellIcon(entry.spellName, liveId or entry.spellId)
            if not buildIcon then
              buildIcon = entry.spellIcon
            end
            sData[cleanName] = {
              icon = buildIcon,
              keybind = entry.keybind,
              mode = entry.mode or "Both",
              isOffensive = entry.isOffensive,
              isCooldown = entry.isCooldown or false,
              conditionFns = {},
              id = liveId or entry.spellId,
            }
          else
            if entry.spellId and not sData[cleanName].id then
              sData[cleanName].id = entry.spellId
            end
            if entry.isCooldown then
              sData[cleanName].isCooldown = true
            end
          end
          if entry.conditionFn then
            tableInsert(sData[cleanName].conditionFns, entry.conditionFn)
          end
          if entry.conditionText and entry.conditionText ~= "" then
            sData[cleanName].conditionText = entry.conditionText
          end
          end
        end
      end
    end
  end

  CLF._filteredAPL = f
  CLF._priorityMap = pMap
  CLF._modeMap = mMap
  CLF._spellData = sData
  CLF._isHealerSpec = isHealer
  CLF._isTankSpec = isTank

  local specId = config.spec and config.spec.id or ""
  local aplBranch = config.spec and config.spec.aplBranch or "fallback"
  CLF._aplBranch = aplBranch
  ApplyPreMidnightOverrides(specId, aplBranch, pMap, mMap, CLF._cdMap, sData)

  local trinketCount = 0
  for _, t in pairs(CLF._trinkets) do
    if t.hasUse then trinketCount = trinketCount + 1 end
  end
  local aplTier = config.spec and config.spec.aplTier or "unknown"
  CLF.Log("INFO", "APL source: branch=" .. aplBranch .. ", tier=" .. aplTier .. ", spec=" .. specId)
  CLF.Log("INFO", "Highlight Assist Pro loaded: " .. #f.rotation .. " rotation, " .. #f.precombatState .. " state-check, " .. #f.precombatOpener .. " opener, " .. #f.interrupts .. " interrupt, " .. trinketCount .. " trinket(s)")

  if CLF._acRotationNames then
    local aplSpellSet = {}
    for _, sec in ipairs({ "rotation", "precombatState", "precombatOpener", "interrupts" }) do
      if f[sec] then
        for _, e in ipairs(f[sec]) do
          if e.spellId then aplSpellSet[e.spellId] = true end
          if e.spellName then
            local cn = string.gsub(string.gsub(string.lower(e.spellName), "_", " "), ":", "")
            aplSpellSet[cn] = true
          end
        end
      end
    end
    local slots = CLF._spellSlots or {}
    local pruned = 0
    local prunedNames = {}
    local kept = 0
    for cn, sid in pairs(CLF._acRotationNames) do
      local inAPL = aplSpellSet[sid] or aplSpellSet[cn]
      local onBar = slots[cn]
      if not onBar and CLF._spellAliases then
        local aliases = CLF._spellAliases[cn]
        if aliases then
          for _, alt in ipairs(aliases) do
            if slots[alt] then onBar = true; break end
          end
        end
      end
      local isBlocked = CLF._hardBlockSpells and CLF._hardBlockSpells[cn]
      local isOOC = CLF._oocOnlySpells[cn]
      local isNR = CLF._nonRotationSpells[cn]
      if isBlocked or isOOC or isNR then
        CLF._acRotationNames[cn] = nil
        if CLF._acRotationSet then CLF._acRotationSet[sid] = nil end
        pruned = pruned + 1
        tableInsert(prunedNames, cn)
      elseif not inAPL and not onBar then
        CLF._acRotationNames[cn] = nil
        if CLF._acRotationSet then CLF._acRotationSet[sid] = nil end
        pruned = pruned + 1
        tableInsert(prunedNames, cn)
      else
        kept = kept + 1
      end
    end
    if pruned > 0 then
      CLF.Log("INFO", "AC rotation pruned " .. pruned .. " spell(s): " .. table.concat(prunedNames, ", "))
    end
    CLF.Log("INFO", "AC rotation verified: " .. kept .. " spells confirmed (APL + bar cross-ref)")
  end
end

-- -- §E4: Multi-Signal Action Bar Scanner --
-- Two-phase scanning:
--   Phase 1 (BuildSlotMap): Full 180-slot scan done once on load, and again on
--     ACTIONBAR_SLOT_CHANGED / talent events / lazy OOC rescan every ~2min.
--     Builds CLF._spellSlots map: cleanName -> slotID for all spell/item slots.
--   Phase 2 (ScanActionBars): Signal-only scan during combat -- only iterates
--     CLF._spellSlots (mapped slots), NOT all 180 slots. Much faster.
--
-- Signal tiers (lower = stronger recommendation):
--   SIGNAL_ANTS     (1) = C_AssistedCombat.GetNextCastSpell match (Blizzard says "cast this")
--   SIGNAL_PROC     (2) = C_SpellActivationOverlay.IsSpellOverlayed or button glow
--   SIGNAL_ASSISTED (3) = Action bar highlight/glow child visible
--   SIGNAL_READY    (4) = C_Spell.IsSpellUsable + CooldownReady

local SLOT_TO_BUTTON = {}
local function InitSlotMap()
  if next(SLOT_TO_BUTTON) then return end
  for i = 1, 12 do SLOT_TO_BUTTON[i] = "ActionButton" .. i end
  for i = 1, 12 do SLOT_TO_BUTTON[24 + i] = "MultiBarRightButton" .. i end
  for i = 1, 12 do SLOT_TO_BUTTON[36 + i] = "MultiBarLeftButton" .. i end
  for i = 1, 12 do SLOT_TO_BUTTON[48 + i] = "MultiBarBottomRightButton" .. i end
  for i = 1, 12 do SLOT_TO_BUTTON[60 + i] = "MultiBarBottomLeftButton" .. i end
  for i = 1, 12 do SLOT_TO_BUTTON[72 + i] = "MultiBar5Button" .. i end
  for i = 1, 12 do SLOT_TO_BUTTON[96 + i] = "MultiBar6Button" .. i end
  for i = 1, 12 do SLOT_TO_BUTTON[120 + i] = "MultiBar7Button" .. i end
end

CLF._slotMapDirty = true
CLF._lastSlotMapTime = 0
local SLOT_MAP_OOC_INTERVAL = 120

CLF._oocOnlySpells = {
  ["prowl"] = true,
  ["stealth"] = true,
  ["shadowmeld"] = true,
  ["camouflage"] = true,
  ["mass resurrection"] = true,
  ["revive"] = true,
  ["resurrection"] = true,
  ["ancestral spirit"] = true,
  ["redemption"] = true,
  ["raise ally"] = true,
  ["soulstone"] = true,
  ["ritual of summoning"] = true,
  ["astral recall"] = true,
  ["hearthstone"] = true,
  ["mount up"] = true,
  ["fishing"] = true,
  ["cooking fire"] = true,
  ["survey"] = true,
  ["aspect of the cheetah"] = true,
  ["mark of the wild"] = true,
  ["arcane intellect"] = true,
  ["power word fortitude"] = true,
  ["battle shout"] = true,
  ["windfury totem"] = true,
}

CLF._nonRotationSpells = {
  ["cat form"] = true,
  ["bear form"] = true,
  ["moonkin form"] = true,
  ["travel form"] = true,
  ["aquatic form"] = true,
  ["flight form"] = true,
  ["mount form"] = true,
  ["ghost wolf"] = true,
  ["shadowform"] = true,
  ["earth elemental"] = true,
  ["water elemental"] = true,
  ["charge"] = true,
  ["heroic leap"] = true,
  ["intervene"] = true,
  ["wild charge"] = true,
  ["blink"] = true,
  ["shimmer"] = true,
  ["roll"] = true,
  ["chi torpedo"] = true,
  ["disengage"] = true,
  ["grappling hook"] = true,
  ["shadowstep"] = true,
  ["door of shadows"] = true,
  ["flying serpent kick"] = true,
  ["divine steed"] = true,
  ["angelic feather"] = true,
  ["leap of faith"] = true,
  ["demonic gateway"] = true,
  ["burning rush"] = true,
  ["infernal strike"] = true,
  ["fel rush"] = true,
  ["vengeful retreat"] = true,
  ["death's advance"] = true,
  ["wraith walk"] = true,
  ["spirit walk"] = true,
  ["dash"] = true,
  ["stampeding roar"] = true,
  ["sprint"] = true,
  ["rocket jump"] = true,
  ["transcendence"] = true,
  ["transcendence transfer"] = true,
}

CLF._healingSpells = {
  ["regrowth"] = true,
  ["healing touch"] = true,
  ["rejuvenation"] = true,
  ["wild growth"] = true,
  ["swiftmend"] = true,
  ["lifebloom"] = true,
  ["tranquility"] = true,
  ["nourish"] = true,
  ["efflorescence"] = true,
  ["flash heal"] = true,
  ["greater heal"] = true,
  ["heal"] = true,
  ["prayer of healing"] = true,
  ["prayer of mending"] = true,
  ["renew"] = true,
  ["circle of healing"] = true,
  ["divine hymn"] = true,
  ["healing surge"] = true,
  ["healing wave"] = true,
  ["chain heal"] = true,
  ["riptide"] = true,
  ["healing rain"] = true,
  ["flash of light"] = true,
  ["holy light"] = true,
  ["light of dawn"] = true,
  ["beacon of light"] = true,
  ["lay on hands"] = true,
  ["vivify"] = true,
  ["enveloping mist"] = true,
  ["renewing mist"] = true,
  ["essence font"] = true,
  ["revival"] = true,
  ["life cocoon"] = true,
  ["soothing mist"] = true,
}
CLF._seedHealingSpells = {}
for _seedK, _seedV in pairs(CLF._healingSpells) do
  CLF._seedHealingSpells[_seedK] = _seedV
end
CLF._defensiveSpells = {}

local _movementSpells = {
  ["roll"] = true,
  ["chi torpedo"] = true,
  ["transcendence"] = true,
  ["transcendence transfer"] = true,
  ["blink"] = true,
  ["shimmer"] = true,
  ["heroic leap"] = true,
  ["charge"] = true,
  ["intervene"] = true,
  ["disengage"] = true,
  ["wild charge"] = true,
  ["dash"] = true,
  ["stampeding roar"] = true,
  ["door of shadows"] = true,
  ["flying serpent kick"] = true,
  ["grappling hook"] = true,
  ["shadowstep"] = true,
  ["sprint"] = true,
  ["death's advance"] = true,
  ["wraith walk"] = true,
  ["spirit walk"] = true,
  ["ghost wolf"] = true,
  ["divine steed"] = true,
  ["angelic feather"] = true,
  ["body and soul"] = true,
  ["leap of faith"] = true,
  ["demonic gateway"] = true,
  ["burning rush"] = true,
  ["rocket jump"] = true,
  ["darkflight"] = true,
}

local _classifyExclude = {
  ["black arrow"] = true,
  ["kill shot"] = true,
  ["execute"] = true,
  ["hammer of wrath"] = true,
  ["shadow word death"] = true,
  ["spinning crane kick"] = true,
  ["chi burst"] = true,
  ["chi wave"] = true,
  ["whirling dragon punch"] = true,
  ["crackling jade lightning"] = true,
  ["death strike"] = true,
  ["spirit bomb"] = true,
  ["soul cleave"] = true,
  ["judgment of light"] = true,
  ["word of glory"] = true,
  ["impending victory"] = true,
  ["victory rush"] = true,
  ["leech"] = true,
  ["bloodthirst"] = true,
  ["drain life"] = true,
  ["siphon life"] = true,
  ["touch of death"] = true,
}

function CLF.RuntimeHealCheck(cleanName, spellId)
  if CLF._healingSpells[cleanName] then return true end
  if CLF._executeSpells[cleanName] or _classifyExclude[cleanName] then return false end
  if CLF._defensiveSpells and CLF._defensiveSpells[cleanName] then return false end
  if CLF._acRotationNames and CLF._acRotationNames[cleanName] then return false end
  if CLF._spellData and CLF._spellData[cleanName] then return false end
  if not spellId then
    return false
  end
  if IsHelpfulSpell then
    local hOk, hVal = pcall(IsHelpfulSpell, spellId)
    if hOk and hVal and not (issecretvalue and issecretvalue(hVal)) then
      local isAlsoHarmful = false
      if IsHarmfulSpell then
        local harmOk, harmVal = pcall(IsHarmfulSpell, spellId)
        if harmOk and harmVal and not (issecretvalue and issecretvalue(harmVal)) then
          isAlsoHarmful = true
        end
      end
      if not isAlsoHarmful then
        local descOk = false
        if C_Spell and C_Spell.GetSpellDescription then
          local dOk, desc = pcall(C_Spell.GetSpellDescription, spellId)
          if dOk and desc and type(desc) == "string" and not (issecretvalue and issecretvalue(desc)) then
            local lowerDesc = string.lower(desc)
            local hasDmg = string.find(lowerDesc, "damage", 1, true) or string.find(lowerDesc, "attack", 1, true)
            if hasDmg then
              descOk = true
            end
          end
        end
        if not descOk then
          CLF._healingSpells[cleanName] = true
          return true
        end
      end
    end
  end
  return false
end


CLF._hardBlockSpells = {
  ["heart of the wild"] = true,
  ["overrun"] = true,
  ["nature's vigil"] = true,
  ["remove corruption"] = true,
  ["soothe"] = true,
  ["hibernate"] = true,
  ["cyclone"] = true,
  ["entangling roots"] = true,
  ["ursol's vortex"] = true,
  ["mass entanglement"] = true,
  ["innervate"] = true,
  ["rebirth"] = true,
}

CLF._executeSpells = {
  ["kill shot"] = true,
  ["execute"] = true,
  ["black arrow"] = true,
  ["hammer of wrath"] = true,
  ["shadow word death"] = true,
  ["touch of death"] = true,
}

CLF._spellRequiresForm = {
  ["rake"] = "cat",
  ["shred"] = "cat",
  ["rip"] = "cat",
  ["ferocious bite"] = "cat",
  ["savage roar"] = "cat",
  ["primal wrath"] = "cat",
  ["brutal slash"] = "cat",
  ["tigers fury"] = "cat",
  ["tiger's fury"] = "cat",
  ["feral frenzy"] = "cat",
  ["ravage"] = "cat",
  ["mangle"] = "bear",
  ["ironfur"] = "bear",
  ["maul"] = "bear",
  ["raze"] = "bear",
  ["frenzied regeneration"] = "bear",
  ["pulverize"] = "bear",
  ["bristling fur"] = "bear",
  ["rage of the sleeper"] = "bear",
}
CLF._spellMultiForm = {
  ["swipe"] = { ["cat"] = true, ["bear"] = true },
  ["thrash"] = { ["cat"] = true, ["bear"] = true },
}
CLF._casterOnlySpells = {
  ["regrowth"] = true,
  ["wild growth"] = true,
  ["rejuvenation"] = true,
  ["ironbark"] = true,
  ["lifebloom"] = true,
  ["nourish"] = true,
  ["tranquility"] = true,
  ["efflorescence"] = true,
  ["swiftmend"] = true,
  ["entangling roots"] = true,
  ["hibernate"] = true,
  ["cyclone"] = true,
  ["nature's swiftness"] = true,
  ["natures swiftness"] = true,
  ["cenarion ward"] = true,
  ["remove corruption"] = true,
  ["natures cure"] = true,
  ["nature's cure"] = true,
  ["rebirth"] = true,
  ["wrath"] = true,
  ["starfire"] = true,
  ["starsurge"] = true,
}
CLF._catBlockedSpells = {
  ["moonfire"] = true,
  ["sunfire"] = true,
}

local function IsFormGated(cleanName)
  local config = CLF_Config or CLF_DefaultConfig
  if not config or not config.spec then return false end
  local className = config.spec.className
  if className ~= "Druid" then return false end
  local currentForm = CLF.CurrentForm and CLF.CurrentForm() or "caster"
  local requiredForm = CLF._spellRequiresForm[cleanName]
  if requiredForm then
    return currentForm ~= requiredForm
  end
  local multiForm = CLF._spellMultiForm[cleanName]
  if multiForm then
    return not multiForm[currentForm]
  end
  if CLF._casterOnlySpells[cleanName] then
    if currentForm == "cat" or currentForm == "bear" then
      return true
    end
  end
  if CLF._catBlockedSpells[cleanName] then
    if currentForm == "cat" then
      return true
    end
  end
  return false
end

CLF._knownDefensives = {
  ["ironfur"] = true,
  ["shield block"] = true,
  ["shield of the righteous"] = true,
  ["demon spikes"] = true,
  ["bone shield"] = true,
  ["celestial brew"] = true,
  ["ignore pain"] = true,
  ["barkskin"] = true,
  ["survival instincts"] = true,
  ["fortifying brew"] = true,
  ["shield wall"] = true,
  ["last stand"] = true,
  ["ardent defender"] = true,
  ["guardian of ancient kings"] = true,
  ["metamorphosis"] = true,
  ["vampiric blood"] = true,
  ["icebound fortitude"] = true,
  ["anti-magic shell"] = true,
  ["fiery brand"] = true,
  ["frenzied regeneration"] = true,
  ["incarnation guardian of ursoc"] = true,
  ["rage of the sleeper"] = true,
  ["ironbark"] = true,
  ["diffuse magic"] = true,
  ["dampen harm"] = true,
  ["astral shift"] = true,
  ["die by the sword"] = true,
  ["enraged regeneration"] = true,
  ["aspect of the turtle"] = true,
  ["exhilaration"] = true,
  ["divine shield"] = true,
  ["blessing of protection"] = true,
  ["dispersion"] = true,
  ["fade"] = true,
  ["cloak of shadows"] = true,
  ["evasion"] = true,
  ["ice block"] = true,
  ["anti-magic zone"] = true,
  ["lichborne"] = true,
  ["rune tap"] = true,
  ["mark of blood"] = true,
  ["tombstone"] = true,
  ["purgatory"] = true,
  ["blur"] = true,
  ["netherwalk"] = true,
  ["darkness"] = true,
  ["soul barrier"] = true,
  ["bulk extraction"] = true,
  ["renewal"] = true,
  ["nature's vigil"] = true,
  ["obsidian scales"] = true,
  ["renewing blaze"] = true,
  ["zephyr"] = true,
  ["fire within"] = true,
  ["tip the scales"] = true,
  ["survival of the fittest"] = true,
  ["fortitude of the bear"] = true,
  ["alter time"] = true,
  ["greater invisibility"] = true,
  ["blazing barrier"] = true,
  ["ice barrier"] = true,
  ["prismatic barrier"] = true,
  ["mass barrier"] = true,
  ["temporal shield"] = true,
  ["touch of karma"] = true,
  ["zen meditation"] = true,
  ["expel harm"] = true,
  ["divine protection"] = true,
  ["blessing of sacrifice"] = true,
  ["blessing of spellwarding"] = true,
  ["eye of tyr"] = true,
  ["lay on hands"] = true,
  ["word of glory"] = true,
  ["power word shield"] = true,
  ["desperate prayer"] = true,
  ["feint"] = true,
  ["crimson vial"] = true,
  ["riposte"] = true,
  ["spirit wolf"] = true,
  ["earth elemental"] = true,
  ["spirit link totem"] = true,
  ["spell reflection"] = true,
  ["defensive stance"] = true,
  ["rallying cry"] = true,
  ["bitter immunity"] = true,
  ["unending resolve"] = true,
  ["dark pact"] = true,
  ["nether ward"] = true,
  ["mortal coil"] = true,
  ["soul link"] = true,
  ["stoneform"] = true,
  ["fireblood"] = true,
  ["gift of the naaru"] = true,
  ["darkflight"] = true,
  ["shadowmeld"] = true,
  ["will to survive"] = true,
  ["escape artist"] = true,
  ["regeneratin"] = true,
  ["bull rush"] = true,
}

local DEFENSIVE_KEYWORDS = {
  "reduce.*damage",
  "damage taken",
  "damage reduction",
  "absorbs.-damage",
  "damage.*absorb",
  "absorb shield",
  "immune",
  "all damage taken",
  "deflect",
  "parry all",
  "cannot be reduced below",
  "increases armor",
  "block chance",
  "stagger",
}

function CLF.ClassifySpells()
  if CLF._inCombat then return end
  local rotNames = CLF._acRotationNames

  local newHeals = {}
  for seedName, _ in pairs(CLF._seedHealingSpells) do
    newHeals[seedName] = true
  end
  local newDefs = {}
  local hCount = 0
  local dCount = 0

  if not rotNames then
    if CLF._knownDefensives then
      for kd, _ in pairs(CLF._knownDefensives) do
        newDefs[kd] = true
        dCount = dCount + 1
      end
    end
    CLF._healingSpells = newHeals
    CLF._defensiveSpells = newDefs
    CLF.Log("INFO", "Spell classification (pre-AC): " .. hCount .. " healing, " .. dCount .. " defensive (from hardcoded list)")
    return
  end

  for cleanName, sid in pairs(rotNames) do
    if _classifyExclude[cleanName] or CLF._executeSpells[cleanName] then
      if CLF.debugEnabled then
        CLF.Log("DEBUG", "ClassifySpells: skip " .. cleanName .. " (execute/excluded)")
      end
    else

    local isHeal = false
    local isDef = false

    if IsHelpfulSpell then
      local hOk, hVal = pcall(IsHelpfulSpell, sid)
      if hOk and hVal and not (issecretvalue and issecretvalue(hVal)) then
        local isAlsoHarmful = false
        if IsHarmfulSpell then
          local harmOk, harmVal = pcall(IsHarmfulSpell, sid)
          if harmOk and harmVal and not (issecretvalue and issecretvalue(harmVal)) then
            isAlsoHarmful = true
          end
        end
        if not isAlsoHarmful then
          isHeal = true
        end
      end
    end

    if not isHeal and C_Spell and C_Spell.GetSpellDescription then
      local dOk, desc = pcall(C_Spell.GetSpellDescription, sid)
      if dOk and desc and type(desc) == "string" and not (issecretvalue and issecretvalue(desc)) then
        local lowerDesc = string.lower(desc)
        local hasDamageKeyword = string.find(lowerDesc, "damage", 1, true) or string.find(lowerDesc, "attack", 1, true)
        if not hasDamageKeyword and (string.find(lowerDesc, "heal", 1, true) or string.find(lowerDesc, "restores.-health")) then
          isHeal = true
        end
        if not isHeal then
          for _, kw in ipairs(DEFENSIVE_KEYWORDS) do
            if string.find(lowerDesc, kw) then
              isDef = true
              break
            end
          end
        end
      end
    end

    if isHeal then
      newHeals[cleanName] = true
      hCount = hCount + 1
    elseif isDef then
      newDefs[cleanName] = true
      dCount = dCount + 1
    end
    end
  end

  local cfg = CLF_Config or CLF_DefaultConfig
  local aplSections = cfg and cfg.apl
  if aplSections then
    local secKeys = { "rotation", "precombatState", "precombatOpener", "interrupts" }
    for _, sk in ipairs(secKeys) do
      local sec = aplSections[sk]
      if sec then
        for _, e in ipairs(sec) do
          if e.spellId then
            local cn = string.lower(string.gsub(e.spellName or "", "_", " "))
            if not newHeals[cn] and not newDefs[cn] and not _classifyExclude[cn] and not CLF._executeSpells[cn] then
              local isHeal2 = false
              if IsHelpfulSpell then
                local hOk2, hVal2 = pcall(IsHelpfulSpell, e.spellId)
                if hOk2 and hVal2 and not (issecretvalue and issecretvalue(hVal2)) then
                  local alsoHarm2 = false
                  if IsHarmfulSpell then
                    local harm2Ok, harm2Val = pcall(IsHarmfulSpell, e.spellId)
                    if harm2Ok and harm2Val and not (issecretvalue and issecretvalue(harm2Val)) then
                      alsoHarm2 = true
                    end
                  end
                  if not alsoHarm2 then
                    isHeal2 = true
                  end
                end
              end
              if not isHeal2 and C_Spell and C_Spell.GetSpellDescription then
                local dOk2, desc2 = pcall(C_Spell.GetSpellDescription, e.spellId)
                if dOk2 and desc2 and type(desc2) == "string" and not (issecretvalue and issecretvalue(desc2)) then
                  local lowerDesc2 = string.lower(desc2)
                  local hasDmg2 = string.find(lowerDesc2, "damage", 1, true) or string.find(lowerDesc2, "attack", 1, true)
                  if not hasDmg2 and (string.find(lowerDesc2, "heal", 1, true) or string.find(lowerDesc2, "restores.-health")) then
                    isHeal2 = true
                  end
                  if not isHeal2 then
                    for _, kw in ipairs(DEFENSIVE_KEYWORDS) do
                      if string.find(lowerDesc2, kw) then
                        newDefs[cn] = true
                        dCount = dCount + 1
                        break
                      end
                    end
                  end
                end
              end
              if isHeal2 then
                newHeals[cn] = true
                hCount = hCount + 1
              end
            end
          end
        end
      end
    end
  end

  if CLF._knownDefensives then
    for kd, _ in pairs(CLF._knownDefensives) do
      if not newDefs[kd] then
        newDefs[kd] = true
        dCount = dCount + 1
      end
    end
  end

  CLF._healingSpells = newHeals
  CLF._defensiveSpells = newDefs
  CLF.Log("INFO", "Spell classification: " .. hCount .. " healing, " .. dCount .. " defensive")
end


CLF._removedOrPassiveSpells = {
  ["new moon"] = true,
  ["half moon"] = true,
  ["full moon"] = true,
  ["celestial infusion"] = true,
}

CLF._castableCache = {}

CLF._classInterruptMap = {
  ["DEATHKNIGHT"] = { spell = "Mind Freeze", icon = "spell_deathknight_mindfreeze" },
  ["DEMONHUNTER"] = { spell = "Disrupt", icon = "ability_demonhunter_consumemagic" },
  ["DRUID"] = {
    spell = "Skull Bash", icon = "inv_bone_skull_04",
    alt = { spell = "Solar Beam", icon = "ability_vehicle_sonicshockwave" },
    specOverride = {
      ["Balance"] = { spell = "Solar Beam", icon = "ability_vehicle_sonicshockwave", alt = { spell = "Skull Bash", icon = "inv_bone_skull_04" } },
    },
  },
  ["EVOKER"] = { spell = "Quell", icon = "ability_evoker_quell" },
  ["HUNTER"] = {
    spell = "Counter Shot", icon = "ability_hunter_glowingshot",
    alt = { spell = "Muzzle", icon = "ability_hunter_noskill" },
    specOverride = {
      ["Survival"] = { spell = "Muzzle", icon = "ability_hunter_noskill", alt = { spell = "Counter Shot", icon = "ability_hunter_glowingshot" } },
    },
  },
  ["MAGE"] = { spell = "Counterspell", icon = "spell_frost_iceshock" },
  ["MONK"] = { spell = "Spear Hand Strike", icon = "ability_monk_spearhand" },
  ["PALADIN"] = { spell = "Rebuke", icon = "spell_holy_rebuke" },
  ["PRIEST"] = { spell = "Silence", icon = "ability_priest_silence" },
  ["ROGUE"] = { spell = "Kick", icon = "ability_kick" },
  ["SHAMAN"] = { spell = "Wind Shear", icon = "spell_nature_cyclone" },
  ["WARLOCK"] = { spell = "Spell Lock", icon = "spell_shadow_mindrot", alt = { spell = "Axe Toss", icon = "ability_warrior_punishingblow" } },
  ["WARRIOR"] = { spell = "Pummel", icon = "ability_warrior_pummel" },
}

function CLF.GetClassInterrupt(playerClass)
  local base = CLF._classInterruptMap[playerClass]
  if not base then return nil end
  if base.specOverride then
    local specCfg = CLF_Config and CLF_Config.spec
    local specName = specCfg and specCfg.specName
    if specName and base.specOverride[specName] then
      return base.specOverride[specName]
    end
  end
  return base
end


function CLF.BuildSlotMap()
  local inCombat = DetaintBool(InCombatLockdown(), "BuildSlotMap")
  if inCombat then
    if CLF._spellSlots and next(CLF._spellSlots) then return end
    CLF.RestoreSlotMapFromSaved()
    return
  end
  InitSlotMap()
  local newSlots = {}
  local newSlotIds = {}
  local newItemSlots = {}
  local macroSlots = {}
  local macroSlotIds = {}
  local slotHasKeybind = {}
  local newOverrideBaseIds = {}
  for slotID = 1, 180 do
    local rawType, rawId = GetActionInfo(slotID)
    local actionType = DetaintStr(rawType)
    local id = Detaint(rawId)
    if actionType == "spell" and id then
      local baseId = id
      local getOverride = C_Spell and C_Spell.GetOverrideSpell
      if getOverride then
        local ovOk, ovId = pcall(getOverride, id)
        if ovOk and ovId and type(ovId) == "number" and not (issecretvalue and issecretvalue(ovId)) and ovId ~= id then
          id = ovId
        end
      end
      local spellName = SafeGetSpellName(id)
      if spellName then
        local cleanKey = string.lower(NormalizeName(spellName))
        local existing = newSlots[cleanKey]
        if not existing then
          newSlots[cleanKey] = slotID
          newSlotIds[cleanKey] = id
          if baseId ~= id then
            newOverrideBaseIds[cleanKey] = baseId
          end
          local btnName = SLOT_TO_BUTTON[slotID]
          if btnName then
            local bOk, bKey = pcall(GetBindingKey, btnName)
            if bOk and bKey and not (issecretvalue and issecretvalue(bKey)) then
              slotHasKeybind[cleanKey] = true
            end
          end
        else
          if not slotHasKeybind[cleanKey] then
            local btnName = SLOT_TO_BUTTON[slotID]
            if btnName then
              local bOk, bKey = pcall(GetBindingKey, btnName)
              if bOk and bKey and not (issecretvalue and issecretvalue(bKey)) then
                newSlots[cleanKey] = slotID
                newSlotIds[cleanKey] = id
                if baseId ~= id then
                  newOverrideBaseIds[cleanKey] = baseId
                end
                slotHasKeybind[cleanKey] = true
              end
            end
          end
        end
      end
    elseif actionType == "macro" and id then
      if GetMacroSpell then
        local mOk, mSpell, mSpellId = pcall(GetMacroSpell, id)
        if mOk and mSpell and type(mSpell) == "string" and not (issecretvalue and issecretvalue(mSpell)) then
          local cleanKey = string.lower(NormalizeName(mSpell))
          if not newSlots[cleanKey] and not macroSlots[cleanKey] then
            macroSlots[cleanKey] = slotID
            if mSpellId and type(mSpellId) == "number" and not (issecretvalue and issecretvalue(mSpellId)) then
              macroSlotIds[cleanKey] = mSpellId
            end
          end
        end
      end
    elseif actionType == "item" and id then
      newItemSlots[id] = slotID
    end
  end
  for mk, mSlot in pairs(macroSlots) do
    if not newSlots[mk] then
      newSlots[mk] = mSlot
      if macroSlotIds[mk] then
        newSlotIds[mk] = macroSlotIds[mk]
      end
    end
  end
  CLF._spellSlots = newSlots
  CLF._spellSlotIds = newSlotIds
  CLF._overrideBaseIds = newOverrideBaseIds
  CLF._itemSlots = newItemSlots
  CLF._castableCache = {}
  if CLF._spellAliases then
    for base, alts in pairs(CLF._spellAliases) do
      for _, alt in ipairs(alts) do
        if newSlots[alt] and not newSlots[base] then
          newSlots[base] = newSlots[alt]
          if newSlotIds[alt] then newSlotIds[base] = newSlotIds[alt] end
          if newOverrideBaseIds[alt] then newOverrideBaseIds[base] = newOverrideBaseIds[alt] end
        end
      end
    end
  end
  CLF._slotMapDirty = false
  CLF._lastSlotMapTime = GetTime()
  CLF.PersistSlotMap()
end

function CLF.PersistSlotMap()
  if not CLF._spellSlots then return end
  local saved = {}
  for k, v in pairs(CLF._spellSlots) do
    saved[k] = { slot = v, id = CLF._spellSlotIds and CLF._spellSlotIds[k] or nil, ovBase = CLF._overrideBaseIds and CLF._overrideBaseIds[k] or nil }
  end
  CLF_SlotMap = saved
end

function CLF.RestoreSlotMapFromSaved()
  if not CLF_SlotMap or not next(CLF_SlotMap) then return end
  local slots = {}
  local slotIds = {}
  local ovBaseIds = {}
  for k, entry in pairs(CLF_SlotMap) do
    if type(entry) == "table" and entry.slot then
      slots[k] = entry.slot
      if entry.id then slotIds[k] = entry.id end
      if entry.ovBase then ovBaseIds[k] = entry.ovBase end
    end
  end
  if next(slots) then
    CLF._spellSlots = slots
    CLF._spellSlotIds = slotIds
    CLF._overrideBaseIds = ovBaseIds
    CLF._castableCache = {}
    CLF._slotMapDirty = false
    CLF._lastSlotMapTime = GetTime()
    local cnt = 0
    for _ in pairs(slots) do cnt = cnt + 1 end
    CLF.Log("INFO", "Restored slot map from SavedVariables (" .. cnt .. " spells)")
  end
end

function CLF.MarkSlotMapDirty()
  CLF._slotMapDirty = true
end

function CLF.MaybeRefreshSlotMap()
  local inCombat = DetaintBool(InCombatLockdown(), "MaybeRefreshSlotMap")
  if inCombat then
    if not CLF._spellSlots or not next(CLF._spellSlots) then
      CLF.RestoreSlotMapFromSaved()
    end
    return
  end
  if CLF._slotMapDirty then
    CLF.BuildSlotMap()
    return
  end
  local now = GetTime()
  if now - CLF._lastSlotMapTime >= SLOT_MAP_OOC_INTERVAL then
    CLF.BuildSlotMap()
  end
end

local SafeGetSpellName = CLF._SafeGetSpellName or function(id)
  if C_Spell and C_Spell.GetSpellName then
    local raw = C_Spell.GetSpellName(id)
    if raw ~= nil then
      if issecretvalue and issecretvalue(raw) then
        if type(id) == "number" then return CLF._spellIdNameCache and CLF._spellIdNameCache[id] end
        return nil
      end
      return DetaintStr(raw)
    end
  end
  if GetSpellInfo then
    local raw = GetSpellInfo(id)
    if raw ~= nil then return DetaintStr(raw) end
  end
  if type(id) == "number" and CLF._spellIdNameCache then return CLF._spellIdNameCache[id] end
  return nil
end

local function CheckButtonGlow(slotID)
  local btnName = SLOT_TO_BUTTON[slotID]
  if not btnName then return 0 end
  local btn = _G[btnName]
  if not btn then return 0 end

  if btn.SpellHighlightTexture then
    local ok, shown = pcall(btn.SpellHighlightTexture.IsShown, btn.SpellHighlightTexture)
    if ok and shown ~= nil then
      if issecretvalue and issecretvalue(shown) then
        return 2
      elseif shown then return 2 end
    end
  end
  if btn.SpellHighlightAnim and btn.SpellHighlightAnim.IsPlaying then
    local ok, playing = pcall(btn.SpellHighlightAnim.IsPlaying, btn.SpellHighlightAnim)
    if ok and playing ~= nil then
      if issecretvalue and issecretvalue(playing) then
        return 2
      elseif playing then return 2 end
    end
  end
  local highlightNames = { "AssistHighlight", "CooldownHighlight" }
  for _, childName in ipairs(highlightNames) do
    local child = btn[childName]
    if child and child.IsShown then
      local ok, shown = pcall(child.IsShown, child)
      if ok and shown ~= nil then
        if issecretvalue and issecretvalue(shown) then
          return 2
        elseif shown then return 2 end
      end
    end
  end
  if btn.GetChildren then
    local chOk, c1, c2, c3, c4, c5, c6, c7, c8 = pcall(btn.GetChildren, btn)
    if chOk then
      local chList = { c1, c2, c3, c4, c5, c6, c7, c8 }
      for ci = 1, 8 do
        local child = chList[ci]
        if not child then break end
        if child.GetObjectType and child.IsShown and child.GetName then
          local nOk, cName = pcall(child.GetName, child)
          if nOk and cName and type(cName) == "string" then
            local lName = string.lower(cName)
            if string.find(lName, "highlight", 1, true) or string.find(lName, "assist", 1, true) then
              local sOk, cShown = pcall(child.IsShown, child)
              if sOk and cShown ~= nil then
                if issecretvalue and issecretvalue(cShown) then return 2
                elseif cShown then return 2 end
              end
            end
          end
        end
      end
    end
  end
  if ActionButton_IsOverlayGlowShowing then
    local ok, showing = pcall(ActionButton_IsOverlayGlowShowing, btn)
    if ok and showing ~= nil then
      if issecretvalue and issecretvalue(showing) then
        return 1
      elseif showing then return 1 end
    end
  end
  if btn.SpellActivationAlert then
    local ok, shown = pcall(btn.SpellActivationAlert.IsShown, btn.SpellActivationAlert)
    if ok and shown ~= nil then
      if issecretvalue and issecretvalue(shown) then
        return 1
      elseif shown then return 1 end
    end
  end
  if btn.__LBGoverlay then
    local ok, shown = pcall(btn.__LBGoverlay.IsShown, btn.__LBGoverlay)
    if ok and shown ~= nil then
      if issecretvalue and issecretvalue(shown) then
        return 1
      elseif shown then return 1 end
    end
  end
  return 0
end

local SIGNAL_ANTS = 1
local SIGNAL_PROC = 2
local SIGNAL_ASSISTED = 3
local SIGNAL_READY = 4

local function ScanActionBars()
  InitSlotMap()
  local chargeDiscovery = CLF._slotMapDirty or false
  CLF.MaybeRefreshSlotMap()
  local bestSignal = {}
  local spellInfo = {}
  local signalDiag = {}
  CLF._signalDiag = signalDiag

  local cachedIds = CLF._spellSlotIds or {}
  local inCombatNow = CLF._inCombat == true
  for cleanKey, slotID in pairs(CLF._spellSlots) do
    local actionType = nil
    local id = nil
    if inCombatNow then
      id = cachedIds[cleanKey]
      if id then actionType = "spell" end
    else
      local rawType, rawId = GetActionInfo(slotID)
      actionType = DetaintStr(rawType)
      id = Detaint(rawId)
      if actionType == "macro" and id then
        if GetMacroSpell then
          local mOk, mSpellName, mSpellId = pcall(GetMacroSpell, id)
          if mOk and mSpellId then
            local rawSpellId = mSpellId
            if issecretvalue and issecretvalue(rawSpellId) then
            elseif type(rawSpellId) == "number" then
              id = rawSpellId
              actionType = "spell"
            end
          end
        end
      end
      if not actionType or (actionType ~= "spell" and actionType ~= "macro" and actionType ~= "item") then
        local cachedId = cachedIds[cleanKey]
        if cachedId then
          id = cachedId
          actionType = "spell"
        end
      end
      if actionType == "spell" and id then
        cachedIds[cleanKey] = id
      end
    end
    if actionType == "spell" and id then
      local getOverride = C_Spell and C_Spell.GetOverrideSpell
      if getOverride then
        local ovOk, ovId = pcall(getOverride, id)
        if ovOk and ovId and type(ovId) == "number" and not (issecretvalue and issecretvalue(ovId)) and ovId ~= id then
          id = ovId
        end
      end
      local overrideBaseId = CLF._overrideBaseIds and CLF._overrideBaseIds[cleanKey]
      if overrideBaseId and getOverride then
        local bOk, curOv = pcall(getOverride, overrideBaseId)
        if bOk and curOv and type(curOv) == "number" and not (issecretvalue and issecretvalue(curOv)) then
          if curOv ~= cachedIds[cleanKey] then
            local curOvName = SafeGetSpellName(curOv)
            if curOvName then
              local curOvClean = string.lower(NormalizeName(curOvName))
              if curOvClean == cleanKey then
                id = curOv
              else
                local baseName = SafeGetSpellName(overrideBaseId)
                if baseName and string.lower(NormalizeName(baseName)) == cleanKey then
                  id = overrideBaseId
                else
                  actionType = nil
                end
              end
            else
              actionType = nil
            end
          end
        end
      end
    end
    if actionType == "spell" and id then
      local signal = nil
      local spellName = SafeGetSpellName(id)
      if not spellName then
        spellName = NormalizeName(cleanKey)
      end

      if spellName then
        if not inCombatNow and C_Spell and C_Spell.GetSpellCharges then
          local knownCharge = CLF.Charges.IsChargeSpell(string.lower(NormalizeName(spellName)))
          if knownCharge or chargeDiscovery then
            local cleanCharge = string.lower(NormalizeName(spellName))
            local hasCharges = false
            local chCur, chMax = 0, 1
            local chCurTainted = false
            local chCdStart, chCdDur = 0, 0
            local chCdReadable = false
            local parseOk = pcall(function()
              local info = C_Spell.GetSpellCharges(id)
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
                  local rawStart = info.cooldownStartTime
                  local rawDur = info.cooldownDuration
                  if rawStart and not (issecretvalue and issecretvalue(rawStart)) then
                    chCdStart = rawStart
                  end
                  if rawDur and not (issecretvalue and issecretvalue(rawDur)) then
                    chCdDur = rawDur
                    chCdReadable = true
                  end
                end
              end
            end)
            if parseOk and hasCharges then
              if chCurTainted then
                CLF.Charges.SetFromAPI(cleanCharge, nil, chMax, chCdReadable and chCdDur or nil, chCdReadable and chCdStart or nil, chCdReadable and chCdDur or nil, id)
              else
                CLF.Charges.SetFromAPI(cleanCharge, chCur, chMax, chCdReadable and chCdDur or nil, chCdReadable and chCdStart or nil, chCdReadable and chCdDur or nil, id)
              end
            elseif chargeDiscovery then
              CLF.Charges.Remove(cleanCharge, id)
            end
          end
        elseif inCombatNow then
          local cleanCharge = string.lower(NormalizeName(spellName))
          CLF.Charges.Tick(cleanCharge)
        end
        if not inCombatNow then
          local barReady, barRem, barDur, barStart, barTainted = CLF.GetActionBarCD(slotID)
          if not barTainted then
            if barStart and barStart > 0 and barDur > 1.5 then
              local charges = SafeGetSpellCharges(spellName)
              if charges and charges > 0 then
                CLF._barCD[cleanKey] = nil
              else
                CLF._barCD[cleanKey] = { start = barStart, duration = barDur }
              end
            else
              CLF._barCD[cleanKey] = nil
            end
          end
        end
      end

      local diagAcMatch = false
      local diagOlRaw = "NO_API"
      local diagOlSecret = false
      local diagGlow = 0
      local diagBtnKids = nil

      -- Signal 1: C_AssistedCombat match (highest priority)
      -- If this spell matches what Blizzard's rotation engine recommends, it
      -- gets the strongest signal. This replaces C_SpellHighlight (removed in 12.0).
      if CLF._acNextCastId and CLF._acNextCastId == id then
        signal = SIGNAL_ANTS
        diagAcMatch = true
        TaintCall("AssistedCombat")
        TaintClean("AssistedCombat")
      end

      -- Signal 2: C_SpellActivationOverlay.IsSpellOverlayed (proc detection)
      -- Detects active proc/glow overlays on spells. Returns clean booleans.
      if C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed then
        diagOlRaw = "nil"
        if not signal then
          local olOk, rawOverlayed = pcall(C_SpellActivationOverlay.IsSpellOverlayed, id)
          if olOk and rawOverlayed ~= nil then
            if issecretvalue and issecretvalue(rawOverlayed) then
              diagOlRaw = "SECRET"
              diagOlSecret = true
              signal = SIGNAL_PROC
            elseif rawOverlayed then
              diagOlRaw = "true"
              signal = SIGNAL_PROC
            else
              diagOlRaw = "false"
            end
          end
        end
      end

      -- Signal 3: Action bar button glow (fallback for addon-created glows)
      -- When AC recommends spell X but it can't be cast (resource/CD), WoW may
      -- highlight a fallback filler (e.g. Wrath) on the bars instead. We detect
      -- this by checking if AC recommends a DIFFERENT spell. If so, downgrade
      -- the glow to SIGNAL_READY so the fallback filler doesn't steal priority.
      if not signal then
        local glowType = CheckButtonGlow(slotID)
        diagGlow = glowType or 0
        if glowType == 2 then
          local isACFallbackGlow = CLF._acNextCastId and CLF._acNextCastId ~= id
          if isACFallbackGlow then
            signal = SIGNAL_READY
          else
            signal = SIGNAL_ASSISTED
          end
        elseif glowType == 1 then
          signal = SIGNAL_PROC
        end
      end

      -- Signal 4: Spell usable + off cooldown (READY)
      if not signal and spellName then
        local spUsable = false
        if C_Spell and C_Spell.IsSpellUsable then
          local uOk, rawUsable = pcall(C_Spell.IsSpellUsable, id)
          if uOk and rawUsable ~= nil then
            if issecretvalue and issecretvalue(rawUsable) then
              spUsable = true
            elseif rawUsable then
              spUsable = true
            end
          end
        end
        if spUsable then
          local cdReady = CLF.CooldownReady(spellName)
          if cdReady then
            signal = SIGNAL_READY
          end
        end
      end

      -- Signal 5: In AC rotation but not usable right now
      -- If the spell is in the AC rotation list, give it a weak signal
      -- so it still appears in the candidate pool for CD prediction.
      -- Checks both by spell ID (idSet) and by clean name (nameMap) to handle
      -- cases where bar spell IDs differ from rotation spell IDs (macros, overrides).
      if not signal then
        local inACRot = CLF._acRotationSet and CLF._acRotationSet[id]
        if not inACRot and CLF._acRotationNames and spellName then
          local cn5 = string.gsub(string.gsub(string.lower(spellName), "_", " "), ":", "")
          inACRot = CLF._acRotationNames[cn5] ~= nil
        end
        if not inACRot and spellName then
          local cn5b = string.gsub(string.gsub(string.lower(spellName), "_", " "), ":", "")
          inACRot = (CLF._cdMap and CLF._cdMap[cn5b]) or (CLF._spellData and CLF._spellData[cn5b] and CLF._spellData[cn5b].isCooldown)
        end
        if inACRot then
          signal = SIGNAL_READY
        end
      end

      local btnName = SLOT_TO_BUTTON[slotID]
      if btnName then
        local btn = _G[btnName]
        if btn then
          local parts = {}
          if btn.SpellHighlightTexture then table.insert(parts, "SHT") end
          if btn.SpellHighlightAnim then table.insert(parts, "SHA") end
          if btn.SpellActivationAlert then table.insert(parts, "SAA") end
          if btn.AssistHighlight then table.insert(parts, "AH") end
          if btn.CooldownHighlight then table.insert(parts, "CH") end
          if btn.__LBGoverlay then table.insert(parts, "LBG") end
          if btn.GetChildren then
            local chOk, c1, c2, c3, c4, c5, c6, c7, c8 = pcall(btn.GetChildren, btn)
            if chOk then
              local chList = { c1, c2, c3, c4, c5, c6, c7, c8 }
              for ci = 1, 8 do
                local ch = chList[ci]
                if not ch then break end
                if ch.GetName then
                  local nOk, cn = pcall(ch.GetName, ch)
                  if nOk and cn and type(cn) == "string" then
                    table.insert(parts, "kid:" .. cn)
                  else
                    table.insert(parts, "kid:?")
                  end
                end
              end
            end
          end
          diagBtnKids = table.concat(parts, "|")
          if diagBtnKids == "" then diagBtnKids = "EMPTY" end
        else
          diagBtnKids = "NO_BTN"
        end
      end

      if spellName then
        signalDiag[string.lower(NormalizeName(spellName))] = {
          id = id, slot = slotID, signal = signal or 0,
          acMatch = diagAcMatch,
          ol = diagOlRaw, olS = diagOlSecret,
          glow = diagGlow, kids = diagBtnKids,
        }
      end

      if signal and spellName then
        local cleanEvt = string.lower(NormalizeName(spellName))
        local onEventCD, eventCDRem = CLF.IsOnEventCD(spellName)
        if onEventCD and signal <= SIGNAL_PROC then
          local bookEvt = CLF._spellBook[cleanEvt]
          local hasRealCD = (bookEvt and bookEvt.cdReadyAt and bookEvt.cdReadyAt > 0) or
            (CLF._knownCDDur[cleanEvt] and CLF._knownCDDur[cleanEvt] > 3.0) or
            (bookEvt and bookEvt.cdDuration and bookEvt.cdDuration > 3.0)
          if not hasRealCD and eventCDRem and eventCDRem < 3.0 then
            if CLF._castLog and CLF._castLog[cleanEvt] then
              CLF._castLog[cleanEvt] = nil
            end
            if CLF._barCD and CLF._barCD[cleanKey] then
              CLF._barCD[cleanKey] = nil
            end
            if CLF.debugEnabled then
              CLF.Log("GLOW", "Glow override: " .. spellName .. " -- clearing CD timer (glow is authoritative)")
            end
          end
        end
      end

      if signal then
        local prev = bestSignal[id]
        if not prev or signal < prev then
          bestSignal[id] = signal
          if not spellInfo[id] and spellName then
            local iconID = CLF.ResolveSpellIcon(spellName)
            if not iconID and not inCombatNow and GetActionTexture then
              local rawTex = GetActionTexture(slotID)
              if type(rawTex) ~= "nil" and not (issecretvalue and issecretvalue(rawTex)) then
                if type(rawTex) == "number" then
                  iconID = rawTex
                elseif type(rawTex) == "string" then
                  iconID = tonumber(rawTex) or rawTex
                end
              end
            end
            if not iconID then
              local cleanName = string.gsub(string.gsub(string.lower(spellName), "_", " "), ":", "")
              local sd = CLF._spellData and CLF._spellData[cleanName]
              if sd and sd.icon then iconID = sd.icon end
            end
            local barRem, barDur = 0, 0
            if not inCombatNow then
              local _, br, bd = CLF.GetActionBarCD(slotID)
              barRem = br or 0
              barDur = bd or 0
            end
            spellInfo[id] = {
              spellName = spellName,
              spellId = id,
              spellID = id,
              slotID = slotID,
              icon = iconID,
              cdRemaining = barRem,
              cdTotal = barDur,
            }
          end
        end
      end

    end
  end

  local itemSlots = CLF._itemSlots or {}
  for itemID, slotID in pairs(itemSlots) do
    local trinketSlot = nil
    for _, t in pairs(CLF._trinkets) do
      if t.itemID == itemID and t.hasUse then trinketSlot = t.slotName break end
    end
    if trinketSlot then
      local signal = nil
      local glowType = CheckButtonGlow(slotID)
      if glowType == 2 then
        signal = SIGNAL_ANTS
      elseif glowType == 1 then
        signal = SIGNAL_PROC
      end
      if not signal then
        local cdRem, cdReady = CLF.GetTrinketCooldown(trinketSlot)
        if cdReady or cdRem <= 0 then
          signal = SIGNAL_READY
        end
      end
      if signal then
        local itemKey = "item_" .. itemID
        local prev = bestSignal[itemKey]
        if not prev or signal < prev then
          bestSignal[itemKey] = signal
          if not spellInfo[itemKey] then
            local t = CLF._trinkets[trinketSlot]
            spellInfo[itemKey] = {
              spellName = t.spellName,
              itemName = t.itemName,
              itemID = itemID,
              slotID = slotID,
              icon = t.icon,
              isTrinket = true,
              trinketSlot = trinketSlot,
            }
          end
        end
      end

    end
  end

  local results = {}
  for id, signal in pairs(bestSignal) do
    local info = spellInfo[id]
    if info then
      info.signal = signal
      tableInsert(results, info)
    end
  end

  return results
end

-- ── §E5: Scoring Function ──
-- Combines signal type + SimC priority rank + mode relevance + stuck penalty
-- into a composite score. Lower score = higher priority (shown first in queue).
-- Scoring tiers (lower = shown first):
--   T0: Interrupts/Defensives       = 0 (injected before scoring)
--   T1: CD + Blizzard highlight     = -12000 + basePrio (both SimC and WoW agree)
--   T2: CD ready (short, <15s)      = -11000 + basePrio (rotational CD, tight loop)
--   T2b: Major CD ready (15s+)      = -10800 + basePrio (strategic long-CD spell)
--   T3: ANTS / AC recommended       = -10500 + basePrio (highest Blizzard signal / AC promotion)
--   T4: ASSISTED highlight          = -10000 + basePrio (Blizzard static highlight)
--   T5: SimC mode-match/both filler  = -7000 + basePrio + neglect (rotation spell)
--   T6: PROC overlay                = -5000 + basePrio
--   T7: SimC mode-mismatch          = -3000 + basePrio
--   T8: Unknown / filler            = 500+ (not in SimC data)
--   T9: On cooldown                 = 9000+ (waiting, with CD remaining factor)
-- Neglect escalator: spells not cast in 2x+ their expected interval get -500/extra
-- interval boost (capped at -2000). Expected interval approximated from basePrio.
-- Anti-stuck penalty: progressively added (+500/s after 4s threshold, cap 15000)
-- to spells that sit at #1 for too long without the player casting them.
-- Mode mismatch for non-major-CDs adds +5000 penalty (wrong ST/AoE context).
local function NeglectBoost(cleanName, hasSimcData, basePrio)
  if not hasSimcData then return 0 end
  local castLog = CLF._castLog
  if not castLog then return 0 end
  local lastCast = castLog[cleanName]
  if not lastCast then
    if not CLF._spellAliases then return 0 end
    local aliases = CLF._spellAliases[cleanName]
    if aliases then
      for _, alt in ipairs(aliases) do
        if castLog[alt] then lastCast = castLog[alt]; break end
      end
    end
  end
  if not lastCast then
    local firstCast = CLF._firstCombatCastTime
    if not firstCast or firstCast <= 0 then return 0 end
    lastCast = firstCast
  end
  local now = GetTime()
  local elapsed = now - lastCast
  local prio = basePrio or 500
  local expectedInterval = mathMax(3, prio * 0.3)
  local grace = expectedInterval * 2
  if grace < 6 then grace = 6 end
  if elapsed < grace then return 0 end
  local extra = math.floor((elapsed - grace) / expectedInterval)
  if extra < 1 then return 0 end
  local boost = extra * -500
  if boost < -2000 then boost = -2000 end
  return boost
end

local function ScoreCandidate(spellName, signal, mode, isCooldown)
  local pMap = CLF._priorityMap or {}
  local mMap = CLF._modeMap or {}
  local cdMap = CLF._cdMap or {}
  local cleanName = string.gsub(string.gsub(string.lower(spellName), "_", " "), ":", "")

  local basePrio = pMap[cleanName]
  if not basePrio and CLF._spellAliases then
    for base, alts in pairs(CLF._spellAliases) do
      for _, alt in ipairs(alts) do
        if alt == cleanName and pMap[base] then
          cleanName = base
          basePrio = pMap[base]
          break
        end
      end
      if basePrio then break end
    end
  end
  basePrio = basePrio or 500
  local stuckPenalty = CLF._stuckPenalties and CLF._stuckPenalties[cleanName] or 0
  local hasSimcData = basePrio < 500

  local knownDur = CLF._knownCDDur and CLF._knownCDDur[cleanName] or 0
  local isCD = isCooldown or cdMap[cleanName] or (knownDur >= 8)

  local spellMode = mMap[cleanName] or "Both"
  local modeMismatch = spellMode ~= "Both" and spellMode ~= mode
  local modeMatch = (spellMode == mode)

  if isCD and signal <= SIGNAL_ASSISTED then
    return -12000 + basePrio
  end

  if modeMismatch and not isCD then
    return basePrio + 50000 + stuckPenalty
  end

  if signal == SIGNAL_ANTS then
    return -11500 + (hasSimcData and basePrio or 100)
  elseif signal == SIGNAL_ASSISTED then
    return -10000 + (hasSimcData and basePrio or 100)
  elseif signal == SIGNAL_PROC then
    return -5000 + basePrio
  end

  if modeMismatch then
    return basePrio + 50000 + stuckPenalty
  end

  local isMajorCD = isCD and (knownDur >= 15)

  if isCD then
    if isMajorCD then
      return -10800 + basePrio + stuckPenalty
    end
    return -11000 + basePrio + stuckPenalty
  end

  local neglect = NeglectBoost(cleanName, hasSimcData, basePrio)
  if hasSimcData then
    local base
    if modeMatch or spellMode == "Both" then
      base = -7000
    else
      base = -3000
    end
    return base + basePrio + stuckPenalty + neglect
  end
  return basePrio + stuckPenalty + neglect
end

CLF._prevPrimarySpell = nil
CLF._prevPrimaryTime = 0
CLF._primaryLock = nil
CLF._stableSlot1Key = nil
CLF._slot1FadeStart = 0
CLF._slot1FadeDur = 0.25
CLF._lastRotationCastTime = 0
CLF._stalenessActive = false
CLF._stuckSpell = nil
CLF._stuckCount = 0
CLF._stuckThreshold = 60
CLF._stuckPenalties = {}
CLF._stuckTopSpell = nil
CLF._stuckTopSince = 0

-- ── §E6: Main APL Evaluation ──
-- Called every combat tick (20 Hz). Orchestrates the full evaluation pipeline:
-- 1. Refresh snapshot cache
-- 2. Detect combat mode (ST/AoE)
-- 3. Check interrupt override
-- 4. Scan action bars for signals
-- 5. Score & rank candidates
-- 6. Return top N abilities as the queue for HUD rendering
function CLF.EvaluateAPL()
  local config = CLF_Config or CLF_DefaultConfig
  if not config then return {} end
  local hud = config.hud or {}
  local mode = CLF.combatMode or "ST"
  local maxSlots = mathMin(hud.queueSlots or 3, 3)
  local queue = {}

  local isTankRole = hud.combatRole == "tank" or (hud.combatRole == "auto" and CLF._isTankSpec)
  local suppressHeals = not CLF._isHealerSpec and hud.showSelfHeals == false
  local suppressDefs = not CLF._isHealerSpec and not isTankRole and hud.showDefensives == false

  local snapOk = pcall(CLF.RefreshSnapshot)
  if not snapOk and CLF.debugEnabled then
    CLF.Log("WARN", "RefreshSnapshot failed -- using stale data")
  end

  local regenNow = GetTime()
  local rt = CLF._resTracker
  if rt and rt.lastTick and rt.lastTick > 0 then
    local regenElapsed = regenNow - rt.lastTick
    if regenElapsed > 0 and regenElapsed < 2.0 then
      pcall(CLF.TickResourceRegen, regenElapsed)
    end
  end
  if rt then rt.lastTick = regenNow end

  if not CLF._filteredAPL then
    local buildOk = pcall(CLF.BuildFilteredAPL)
    if not buildOk then return CLF.lastQueue or {} end
  end
  local fAPL = CLF._filteredAPL
  if not fAPL then return CLF.lastQueue or {} end

  local now = GetTime()
  local debugThisTick = false
  if CLF.debugEnabled then
    if not CLF._lastDebugLog or (now - CLF._lastDebugLog) >= 2.0 then
      debugThisTick = true
      CLF._lastDebugLog = now
    end
  end

  if debugThisTick then
    local s = CLF._snap or {}
    CLF.Log("DEBUG", "--- Scan (mode=" .. mode .. ", enemies=" .. CLF.ActiveEnemies() .. ", power=" .. (s.power or 0) .. "/" .. (s.powerMax or 0) .. ") ---")
  end

  -- §E6.0: Layer 0 -- Precombat State Check (forms, stances, buffs)
  -- Evaluates precombat "state" entries (isPrecombat=true, precombatType="state").
  -- If the condition is true (state is MISSING) and the spell is known+usable,
  -- force it to the front of the queue with max priority.
  -- Works BOTH in and out of combat -- if you're Balance in caster form mid-fight,
  -- Moonkin Form should be your #1 priority.
  local inCombat = CLF._inCombat or false

  local STALENESS_TIMEOUT = hud.stalenessTimeout or 12
  if inCombat and CLF._lastRotationCastTime > 0 then
    local idleTime = now - CLF._lastRotationCastTime
    if idleTime >= STALENESS_TIMEOUT and not CLF._stalenessActive then
      CLF._stalenessActive = true
      CLF._dotCastLogStale = true
      CLF._prevGCD = nil
      CLF._prevPrimarySpell = nil
      CLF._prevPrimaryTime = 0
      CLF._primaryLock = nil
      CLF._stableSlot1Key = nil
      CLF._stuckPenalties = {}
      CLF._stuckTopSpell = nil
      CLF._stuckTopSince = 0
      CLF.Log("SYSTEM", "Staleness falloff triggered (" .. string.format("%.0f", idleTime) .. "s idle) -- rotation reset")
    end
  end
  if not inCombat then
    CLF._stalenessActive = false
    CLF._lastRotationCastTime = 0
    CLF._primaryLock = nil
  end

  -- §E6.0-PET: Layer 0-Pet -- Pet Management Override (Hunter/Warlock)
  -- For pet classes, having no pet is catastrophic. This MUST override everything.
  -- Call Pet when no pet exists, Revive Pet when pet is dead.
  -- Only runs for classes that rely on pets (Hunter, Warlock).
  -- MM Hunters are petless by default in 12.0; only those with Unbreakable Bond talent use pets.
  local isPetless = false
  do
    local pClass = CLF._playerClass or select(2, UnitClass("player"))
    local isLoneWolf = false
    if pClass == "HUNTER" then
      local specName = CLF_Config and CLF_Config.spec and CLF_Config.spec.specName
      if specName == "Marksmanship" then
        isLoneWolf = true
        local hasUB = CLF.IsSpellKnown and CLF.IsSpellKnown("Unbreakable Bond", 444680)
        if hasUB then
          isLoneWolf = false
        end
      end
    end
    isPetless = isLoneWolf
    if (pClass == "HUNTER" or pClass == "WARLOCK") and not isLoneWolf then
      local rawPetExists = nil
      if not inCombat then
        rawPetExists = UnitExists("pet")
      else
        local okPE, rpe = pcall(UnitExists, "pet")
        rawPetExists = okPE and rpe or nil
      end
      local petExists = DetaintBool(rawPetExists)
      if not petExists then
        local callId = pClass == "HUNTER" and 883 or 688
        local callName = SafeGetSpellName(callId) or (pClass == "HUNTER" and "Call Pet 1" or "Summon Imp")
        local callIcon = CLF.ResolveSpellIcon(callName, callId) or "Ability_Hunter_BeastCall"
        local usable = false
        local ok, result = pcall(function() return CLF.SpellStatus(callName, callId) end)
        if ok then usable = result end
        if usable or not inCombat then
          queue[1] = {
            spellName = callName,
            spellIcon = callIcon,
            keybind = CLF.GetKeybind and CLF.GetKeybind(callName) or "",
            isInterrupt = false,

            priority = -50000,
            isGlowing = true,
            inRange = true,
            cdRemaining = 0,
            signalType = "pet_management",
          }
          if debugThisTick then CLF.Log("PET", "No pet -- suggesting " .. callName) end
        end
      else
        local rawPetDead = nil
        if not inCombat then
          rawPetDead = UnitIsDead("pet")
        else
          local okPD, rpd = pcall(UnitIsDead, "pet")
          rawPetDead = okPD and rpd or nil
        end
        local petDead = false
        if rawPetDead ~= nil and not (issecretvalue and issecretvalue(rawPetDead)) then
          petDead = rawPetDead and true or false
        end
        if petDead then
          local reviveId = pClass == "HUNTER" and 982 or 333889
          local reviveName = SafeGetSpellName(reviveId) or (pClass == "HUNTER" and "Revive Pet" or "Fel Domination")
          local reviveIcon = CLF.ResolveSpellIcon(reviveName, reviveId) or "Ability_Hunter_BeastSoothe"
          local usable = false
          local ok, result = pcall(function() return CLF.SpellStatus(reviveName, reviveId) end)
          if ok then usable = result end
          if usable or not inCombat then
            queue[1] = {
              spellName = reviveName,
              spellIcon = reviveIcon,
              keybind = CLF.GetKeybind and CLF.GetKeybind(reviveName) or "",
              isInterrupt = false,
  
              priority = -50000,
              isGlowing = true,
              inRange = true,
              cdRemaining = 0,
              signalType = "pet_management",
            }
            if debugThisTick then CLF.Log("PET", "Pet dead -- suggesting " .. reviveName) end
          end
          if pClass == "HUNTER" and not inCombat then
            local heartName = "Heart of the Phoenix"
            local hOk, hUsable = pcall(function() return CLF.SpellStatus(heartName) end)
            if hOk and hUsable and #queue < maxSlots then
              queue[2] = {
                spellName = heartName,
                spellIcon = CLF.ResolveSpellIcon(heartName) or "Ability_Hunter_BeastSoothe",
                keybind = "",
                isInterrupt = false,
    
                priority = -49000,
                isGlowing = false,
                inRange = true,
                cdRemaining = 0,
                signalType = "pet_management",
              }
            end
          end
        end
      end
    end
  end

  if fAPL.precombatState then
    for _, entry in ipairs(fAPL.precombatState) do
      if #queue >= maxSlots then break end
      local skipPet = false
      if isPetless then
        local petSpell = string.gsub(string.gsub(string.lower(entry.spellName), "_", " "), ":", "")
        if petSpell == "summon pet" or petSpell == "call pet" or petSpell == "call pet 1" then
          skipPet = true
          if debugThisTick then CLF.Log("STATE", "SKIP: " .. entry.spellName .. " (petless MM Hunter)") end
        end
      end
      if not skipPet then
        local condOk = false
        if entry._stateCheck == "buff" then
          local buffFound = CLF.BuffUp(entry._stateArg)
          if not buffFound and entry.spellId then
            local sid = tonumber(entry.spellId)
            if sid and sid > 0 then
              local aName, aStk, aExp = CLF.FindAuraInternal("player", sid, entry._stateArg)
              if aName then buffFound = true end
            end
          end
          if not buffFound and not inCombat then
            local buffName = entry._stateArg or ""
            local cleanBuff = string.gsub(buffName, "_", " ")
            if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID and C_Spell and C_Spell.GetSpellInfo then
              local ok3, sInfo = pcall(C_Spell.GetSpellInfo, cleanBuff)
              if ok3 and type(sInfo) == "table" and sInfo.spellID then
                local rawId = sInfo.spellID
                local sid2 = nil
                if issecretvalue and issecretvalue(rawId) then
                  sid2 = nil
                else
                  sid2 = tonumber(rawId)
                end
                if sid2 and sid2 > 0 then
                  local ok5, aura2 = pcall(C_UnitAuras.GetPlayerAuraBySpellID, sid2)
                  if ok5 and type(aura2) == "table" then buffFound = true end
                end
              end
            end
            if not buffFound and GetWeaponEnchantInfo then
              local rawArg = string.gsub(string.lower(buffName), " ", "_")
              if rawArg == "flametongue_weapon" or rawArg == "windfury_weapon" then
                local wOk, wHas = pcall(GetWeaponEnchantInfo)
                if wOk and wHas then buffFound = true end
              end
            end
          end
          condOk = not buffFound
        elseif entry._stateCheck == "form" then
          local formName = string.gsub(string.gsub(string.lower(entry.spellName), "_", " "), ":", "")
          local specCfg = (CLF_Config or CLF_DefaultConfig or {}).spec
          local sName = specCfg and specCfg.specName or ""
          local wrongForm = false
          if sName == "Guardian" and (formName == "cat form" or formName == "moonkin form") then
            wrongForm = true
          elseif sName == "Feral" and (formName == "bear form" or formName == "moonkin form") then
            wrongForm = true
          elseif sName == "Balance" and (formName == "bear form" or formName == "cat form") then
            wrongForm = true
          elseif sName == "Restoration" and (formName == "bear form" or formName == "cat form" or formName == "moonkin form") then
            wrongForm = true
          end
          if wrongForm then
            condOk = false
          else
            condOk = not CLF.IsForm(entry._stateArg)
          end
        elseif entry._stateCheck == "stealth" then
          if inCombat then
            condOk = false
          else
            local inCorrectForm = true
            local cleanSpell = string.gsub(string.gsub(string.lower(entry.spellName), "_", " "), ":", "")
            if cleanSpell == "prowl" then
              inCorrectForm = CLF.CurrentForm() == "cat"
            end
            condOk = inCorrectForm and not CLF.IsStealthed()
          end
        elseif entry.conditionFn then
          local ok, result = pcall(entry.conditionFn)
          condOk = ok and result
          if not ok and debugThisTick then
            local resultOk, resultStr = pcall(tostring, result)
            CLF.Log("STATE", "Condition error for " .. entry.spellName .. ": " .. (resultOk and resultStr or "?"))
          end
        else
          condOk = true
        end
        if condOk then
          local known = CLF.IsSpellKnown(entry.spellName, entry.spellId)
          if known then
            local cleanKey = string.gsub(string.gsub(string.lower(entry.spellName), "_", " "), ":", "")
            local alreadyApplied = CLF._precombatApplied and CLF._precombatApplied[cleanKey]
            if alreadyApplied then
              if debugThisTick then
                CLF.Log("STATE", "SKIP: " .. entry.spellName .. " (already applied this session)")
              end
            elseif not (CLF._spellSlots and CLF._spellSlots[cleanKey]) then
              if debugThisTick then
                CLF.Log("STATE", "SKIP: " .. entry.spellName .. " (not on action bars)")
              end
            else
              local icon = entry._resolvedIcon or entry.spellIcon or ""
              if not icon or icon == "" then
                icon = CLF.ResolveSpellIcon(entry.spellName, entry.spellId) or "INV_Misc_QuestionMark"
              end
              local keybind = CLF.GetKeybind and CLF.GetKeybind(entry.spellName) or entry.keybind or ""
              tableInsert(queue, {
                spellName = entry.spellName,
                spellIcon = icon,
                keybind = keybind,
                isInterrupt = false,

                priority = -2000,
                isGlowing = true,
                inRange = true,
                cdRemaining = 0,
                signalType = "precombat_state",
                isPrecombat = true,
              })
              if debugThisTick then
                CLF.Log("STATE", "MISSING -> " .. entry.spellName .. " (precombat state)")
              end
            end
          end
        end
      end
    end
  end

  -- §E6.0b: Layer 0b -- Precombat Opener (pre-pull casts, OUT OF COMBAT ONLY)
  -- Shows the SimC opener sequence when out of combat and all state requirements met.
  -- Suppressed entirely during combat (the combat APL handles these spells in rotation).
  -- Only shows when the player has a hostile target (indicating intent to pull).
  local hasHostileTarget = false
  if not inCombat then
    local rawReaction = UnitReaction("target", "player")
    local reaction = Detaint(rawReaction)
    hasHostileTarget = reaction and reaction <= 4
    if not hasHostileTarget then
      local rawExists = UnitExists("target")
      local rawCanAttack = UnitCanAttack("player", "target")
      hasHostileTarget = DetaintBool(rawExists) and DetaintBool(rawCanAttack)
    end
  end
  if not inCombat and hasHostileTarget and #queue < maxSlots and fAPL.precombatOpener then
    for _, entry in ipairs(fAPL.precombatOpener) do
      if #queue >= maxSlots then break end
      if CLF.IsSpellKnown(entry.spellName, entry.spellId) then
      local condOk = true
      if entry.conditionFn then
        local ok, result = pcall(entry.conditionFn)
        condOk = ok and result
      end
      if condOk then
        local icon = entry._resolvedIcon or entry.spellIcon or ""
        if not icon or icon == "" then
          icon = CLF.ResolveSpellIcon(entry.spellName) or "INV_Misc_QuestionMark"
        end
        local keybind = CLF.GetKeybind and CLF.GetKeybind(entry.spellName) or entry.keybind or ""
        tableInsert(queue, {
          spellName = entry.spellName,
          spellIcon = icon,
          keybind = keybind,
          isInterrupt = false,

          priority = -500,
          isGlowing = false,
          inRange = true,
          cdRemaining = 0,
          signalType = "precombat_opener",
          isPrecombat = true,
        })
        if debugThisTick then
          CLF.Log("OPENER", "PRE-PULL -> " .. entry.spellName)
        end
      end
      end
    end
  end

  -- §E6.1: Layer 1 -- Interrupt override (always highest priority)
  local shouldInterrupt, interruptSpell = CLF.ShouldShowInterrupt()

  if shouldInterrupt then
    local isTest = CLF._testInterruptActive
    local preferredInterrupt = interruptSpell
    local _, _intPlayerClass = UnitClass("player")

    local function TryInjectInterrupt(spellName)
      local usable, ready = CLF.SpellStatus(spellName)
      if not usable and not isTest then return false end
      if not ready and not isTest then return false end

      local icon = CLF.ResolveSpellIcon(spellName)
      local kb = CLF.GetKeybind and CLF.GetKeybind(spellName) or nil
      for _, entry in ipairs(fAPL.interrupts) do
        if entry.spellName == spellName then
          if not icon or icon == "" then icon = entry.spellIcon end
          if not kb or kb == "" then kb = entry.keybind end
          break
        end
      end
      if not icon or icon == "" then
        local ce = _intPlayerClass and CLF.GetClassInterrupt(_intPlayerClass)
        if ce then
          if ce.spell == spellName then
            icon = ce.icon
          elseif ce.alt and ce.alt.spell == spellName then
            icon = ce.alt.icon
          end
        end
      end
      if not icon or icon == "" then
        icon = "Interface\\Icons\\ability_kick"
      end
      tableInsert(queue, {
        spellName = spellName,
        spellIcon = icon,
        keybind = kb,
        isInterrupt = true,

        priority = 0,
        isGlowing = true,
        inRange = isTest or CLF.IsInRange(spellName),
        cdRemaining = 0,
        signalType = "interrupt",
      })
      if not CLF._lastInterruptState and hud.interruptSound then
        CLF.PlayEventSound("interrupt")
      end
      return true
    end

    if preferredInterrupt then
      TryInjectInterrupt(preferredInterrupt)
    end

    if #queue == 0 then
      for _, entry in ipairs(fAPL.interrupts) do
        if TryInjectInterrupt(entry.spellName) then break end
      end
    end

    if #queue == 0 then
      local config = CLF_Config or CLF_DefaultConfig
      local interrupts = config and config.interrupts or {}
      for _, alert in ipairs(interrupts) do
        if alert.interruptSpell and alert.interruptSpell ~= "" then
          if TryInjectInterrupt(alert.interruptSpell) then break end
        end
      end
    end

    if #queue == 0 then
      local classEntry = _intPlayerClass and CLF.GetClassInterrupt(_intPlayerClass)
      if classEntry then
        if not TryInjectInterrupt(classEntry.spell) then
          if classEntry.alt then
            TryInjectInterrupt(classEntry.alt.spell)
          end
        end
      end
    end

    if #queue == 0 and isTest then
      local classEntry = _intPlayerClass and CLF.GetClassInterrupt(_intPlayerClass)
      local fallbackName = preferredInterrupt
      local fallbackIcon = nil
      if not fallbackName and classEntry then
        fallbackName = classEntry.spell
        fallbackIcon = classEntry.icon
      end
      if not fallbackName then
        fallbackName = "Interrupt"
      end
      local icon = fallbackIcon or CLF.ResolveSpellIcon(fallbackName) or "Interface\\Icons\\ability_kick"
      local kb = CLF.GetKeybind and CLF.GetKeybind(fallbackName) or nil
      tableInsert(queue, {
        spellName = fallbackName,
        spellIcon = icon,
        keybind = kb,
        isInterrupt = true,

        priority = 0,
        isGlowing = true,
        inRange = isTest or CLF.IsInRange(fallbackName),
        cdRemaining = 0,
        signalType = "interrupt",
      })
    end
  end

  CLF._lastInterruptState = shouldInterrupt and #queue > 0

  -- §E6.2a: Refresh C_AssistedCombat state
  -- Query Blizzard's rotation engine for the current recommendation.
  -- Must run BEFORE ScanActionBars so the AC match check works.
  pcall(CLF.RefreshAssistedCombat)

  -- Periodically refresh the rotation spell map (every 30s or on first run)
  if not CLF._acRotationSet or (now - CLF._acLastRotationRefresh > 30) then
    pcall(CLF.BuildRotationSpellMap)
  end

  -- §E6.3: Layer 3 -- Multi-signal scan + SimC-ranked queue
  -- Scans action bars for AC match > PROC > READY signals, scores by priority + mode
  local barResults = ScanActionBars()
  local candidates = {}
  local sData = CLF._spellData or {}
  local _gcdActive = false
  do
    local gc = CLF._gcdCache
    if gc and gc.start > 0 and gc.duration > 0 then
      local gcdAge = GetTime() - gc.start
      if gcdAge < gc.duration then _gcdActive = true end
    end
  end

  if not CLF._assistedEverSeen and not CLF._assistedDismissed then
    -- With C_AssistedCombat, we can check directly if the system is available
    if CLF._acAvailable then
      CLF._assistedEverSeen = true
      CLF._assistedWarningShown = false
      if CLF._assistedWarningFrame then
        CLF._assistedWarningFrame:Hide()
      end
    elseif CLF._acNextCastId then
      CLF._assistedEverSeen = true
    else
      -- Also check for any AC match or proc signals from bar scan
      local sawSignal = false
      for _, br in ipairs(barResults) do
        if br.signal and br.signal <= SIGNAL_PROC then
          sawSignal = true
          break
        end
      end
      if sawSignal then
        CLF._assistedEverSeen = true
      else
        CLF._assistedCheckTicks = CLF._assistedCheckTicks + 1
        if CLF._assistedCheckTicks > 900 and not CLF._assistedWarningShown then
          CLF._assistedWarningShown = true
          if CLF.ShowAssistedWarning then
            CLF.ShowAssistedWarning()
          end
        end
      end
    end
  end

  for _, result in ipairs(barResults) do
    if result.isTrinket and hud.trinketsEnabled ~= false then
      local trinketPrio = (CLF._trinketPriority and CLF._trinketPriority[result.trinketSlot]) or 50
      local keybind = CLF.GetKeybind and CLF.GetKeybind(result.itemName or result.spellName) or nil
      local cdRemaining = 0
      local trinketReady = true
      if result.trinketSlot then
        cdRemaining, trinketReady = CLF.GetTrinketCooldown(result.trinketSlot)
        if not trinketReady and cdRemaining <= 0 then
          cdRemaining = 0
          trinketReady = true
        end
      end
      local trinketUsable = true
      if result.spellName then
        trinketUsable = CLF.IsSpellUsable(result.spellName)
      end

      local score
      if trinketReady and trinketUsable then
        score = -11000 + trinketPrio
        if result.signal == SIGNAL_ANTS then score = score - 500
        elseif result.signal == SIGNAL_ASSISTED then score = score - 200
        elseif result.signal == SIGNAL_PROC then score = score - 100 end
      else
        score = 9000 + trinketPrio
      end

      local signalLabel = "ready"
      if not trinketReady or not trinketUsable then signalLabel = "cooldown"
      elseif result.signal <= SIGNAL_ASSISTED then signalLabel = "assisted"
      elseif result.signal == SIGNAL_PROC then signalLabel = "proc" end

      tableInsert(candidates, {
        spellName = result.itemName or result.spellName,
        spellIcon = result.icon or "INV_Misc_Trinket",
        keybind = keybind,
        isInterrupt = false,

        priority = score,
        inRange = true,
        isGlowing = (trinketReady and trinketUsable) and (result.signal <= SIGNAL_PROC),
        cdRemaining = cdRemaining,
        signalType = signalLabel,
        hlIcon = result.icon,
        isTrinket = true,
        trinketSlot = result.trinketSlot,
        reason = "trinket:" .. signalLabel,
      })

      if debugThisTick then
        CLF.Log("DEBUG", "  TRINKET " .. string.upper(signalLabel) .. ": " .. (result.itemName or "?") .. " (score=" .. score .. ", slot=" .. (result.trinketSlot or "?") .. ")")
      end
    else
      local cleanName = string.gsub(string.gsub(string.lower(result.spellName), "_", " "), ":", "")
      local data = sData[cleanName]
      if not data and CLF._spellAliases then
        for base, alts in pairs(CLF._spellAliases) do
          for _, alt in ipairs(alts) do
            if alt == cleanName then
              data = sData[base]
              if data then cleanName = base end
              break
            end
          end
          if data then break end
        end
      end

      local isAutoSpell = cleanName == "auto shot" or cleanName == "auto attack" or cleanName == "auto_shot" or cleanName == "auto_attack"
      local isOOCOnly = CLF._oocOnlySpells[cleanName]
      local isNonRotation = CLF._nonRotationSpells[cleanName] and not (data and not data.isPrecombatStateOnly)
      local isHardBlocked = CLF._hardBlockSpells and CLF._hardBlockSpells[cleanName]
      local isFormBlocked = IsFormGated(cleanName)
      local isMovement = _movementSpells[cleanName]
      local isPetSpellBlocked = false
      if isPetless then
        local pn = string.gsub(cleanName, "_", " ")
        if pn == "call pet 1" or pn == "call pet 2" or pn == "call pet 3" or pn == "call pet 4" or pn == "call pet 5"
           or pn == "call pet" or pn == "summon pet" or pn == "revive pet" or pn == "mend pet"
           or pn == "dismiss pet" or pn == "eyes of the beast" then
          isPetSpellBlocked = true
        end
      end
      if isPetSpellBlocked then
        if debugThisTick then
          CLF.Log("DEBUG", "  SKIP: " .. result.spellName .. " (pet spell, petless MM Hunter)")
        end
      elseif isMovement then
        if debugThisTick then
          CLF.Log("DEBUG", "  SKIP: " .. result.spellName .. " (movement ability)")
        end
      elseif isHardBlocked then
        if debugThisTick then
          CLF.Log("DEBUG", "  SKIP: " .. result.spellName .. " (hard-blocked spell)")
        end
      elseif isFormBlocked then
        if debugThisTick then
          CLF.Log("DEBUG", "  SKIP: " .. result.spellName .. " (wrong form -- form-gated)")
        end
      elseif isAutoSpell then
        if debugThisTick then
          CLF.Log("DEBUG", "  SKIP: " .. result.spellName .. " (auto attack/shot)")
        end
      elseif isOOCOnly then
        if debugThisTick then
          CLF.Log("DEBUG", "  SKIP: " .. result.spellName .. " (out-of-combat only)")
        end
      elseif isNonRotation then
        if debugThisTick then
          CLF.Log("DEBUG", "  SKIP: " .. result.spellName .. " (non-rotation spell)")
        end
      elseif data and data.isPrecombatStateOnly then
        if debugThisTick then
          CLF.Log("DEBUG", "  SKIP: " .. result.spellName .. " (precombat state -- handled by Layer 0)")
        end
      elseif CLF._isHealerSpec and not data then
        if debugThisTick then
          CLF.Log("DEBUG", "  SKIP: " .. result.spellName .. " (not in DPS APL, healer spec)")
        end
      elseif CLF._isTankSpec and not data and not (result.signal <= SIGNAL_PROC) then
        if debugThisTick then
          CLF.Log("DEBUG", "  SKIP: " .. result.spellName .. " (not in APL, tank spec)")
        end
      elseif CLF._isHealerSpec and data and (not data.isOffensive or CLF._healingSpells[cleanName] or CLF.RuntimeHealCheck(cleanName, result.spellId) or (CLF._defensiveSpells and CLF._defensiveSpells[cleanName])) then
        if debugThisTick then
          CLF.Log("DEBUG", "  SKIP: " .. result.spellName .. " (non-offensive/heal/def spell, healer spec)")
        end
      elseif CLF._executeSpells[cleanName] and result.signal > SIGNAL_PROC then
        local acRotSet = CLF._acRotationNames
        local execAcId = acRotSet and acRotSet[cleanName]
        local execIsAcRec = (execAcId and CLF._acNextCastId and CLF._acNextCastId == execAcId)
        if not execIsAcRec then
          if debugThisTick then
            CLF.Log("DEBUG", "  SKIP: " .. result.spellName .. " (execute spell, no AC recommendation -- cannot verify target health)")
          end
        else
          local keybind = CLF.GetKeybind and CLF.GetKeybind(result.spellName) or (data and data.keybind) or nil
          local icon = (data and data.icon) or result.icon or "INV_Misc_QuestionMark"
          tableInsert(candidates, {
            spellName = result.spellName,
            spellIcon = icon,
            keybind = keybind,
            isInterrupt = false,
            priority = -11000,
            inRange = true,
            isGlowing = true,
            cdRemaining = 0,
            cdTotal = 0,
            signalType = "assisted",
            hlIcon = result.icon,
            isCooldown = data and data.isCooldown or false,
            reason = "bar:execute(AC)",
          })
          if debugThisTick then
            CLF.Log("DEBUG", "  EXECUTE-BOOST: " .. result.spellName .. " (AC-confirmed execute -> priority -11000)")
          end
        end
      elseif (CLF._healingSpells[cleanName] or CLF.RuntimeHealCheck(cleanName, result.spellId)) then
        if suppressHeals then
          if debugThisTick then
            CLF.Log("DEBUG", "  SKIP: " .. result.spellName .. " (healing spell, suppressed)")
          end
        end
      elseif CLF._defensiveSpells and CLF._defensiveSpells[cleanName] then
        if suppressDefs then
          if debugThisTick then
            CLF.Log("DEBUG", "  SKIP: " .. result.spellName .. " (defensive spell, suppressed)")
          end
        end
      elseif data or result.signal <= SIGNAL_ASSISTED or (CLF._acRotationNames and CLF._acRotationNames[cleanName]) then
        if not CLF.IsDotRefreshable(cleanName) then
          if debugThisTick then
            CLF.Log("DEBUG", "  SKIP: " .. result.spellName .. " (DoT active, not refreshable)")
          end
        else

        local condPass = true
        if data and data.conditionFns and #data.conditionFns > 0 then
          CLF._lastEvalSpell = result.spellName
          condPass = false
          for _, fn in ipairs(data.conditionFns) do
            local ok, condResult = pcall(fn)
            if ok and condResult then
              condPass = true
              break
            end
          end
          if debugThisTick then
            local condText = data.conditionText or "?"
            if condPass then
              CLF.Log("DEBUG", "  COND-OK: " .. result.spellName .. " cond=[" .. condText .. "]")
            else
              CLF.Log("DEBUG", "  COND-FAIL: " .. result.spellName .. " cond=[" .. condText .. "] signal=" .. result.signal)
            end
          end
        end

        if not condPass and isTankRole and CLF._defensiveSpells and CLF._defensiveSpells[cleanName] and result.signal == SIGNAL_READY then
          condPass = true
          if debugThisTick then
            CLF.Log("DEBUG", "  TANK-COND-OVERRIDE: " .. result.spellName .. " (defensive in tank mode, bypassing SimC conditions)")
          end
        end

        local cdMap = CLF._cdMap or {}
        local spellIsCooldown = (data and data.isCooldown) or cdMap[cleanName] or false

        if not condPass then
          if debugThisTick then
            CLF.Log("DEBUG", "  SKIP: " .. result.spellName .. " (APL condition=false, signal=" .. result.signal .. ")")
          end
        else

          local actuallyUsable = CLF.IsSpellUsable(result.spellName)
          if result.slotID and IsUsableAction then
            local iuaOk, iuaUsable, iuaNoMana = pcall(IsUsableAction, result.slotID)
            if iuaOk and iuaUsable ~= nil then
              if issecretvalue and issecretvalue(iuaUsable) then
              elseif iuaNoMana then
                actuallyUsable = false
              elseif not iuaUsable then
                actuallyUsable = false
              end
            end
          end
          local _, _, cdRemaining, cdTotalVal = CLF.SpellStatus(result.spellName)
          local onEventCD, eventCDRem = CLF.IsOnEventCD(result.spellName)
          if onEventCD and eventCDRem <= 0.5 then
            onEventCD = false
            eventCDRem = 0
          end
          if onEventCD and eventCDRem > 1.5 then
            if not cdRemaining or cdRemaining < eventCDRem then
              cdRemaining = eventCDRem
            end
            if not cdTotalVal or cdTotalVal < eventCDRem then
              cdTotalVal = CLF._knownCDDur[cleanName] or eventCDRem
            end
          end
          local blizzardSignal = result.signal <= SIGNAL_ASSISTED
          if blizzardSignal and onEventCD and eventCDRem > 3.0 then
          elseif blizzardSignal and not onEventCD then
            if cdRemaining and cdRemaining > 0 and cdRemaining < 1.0 then
              cdRemaining = 0
            end
          end
          local hasAPLData = data ~= nil
          local isAcRecommendedBar = false
          if CLF._acRotationNames and CLF._acRotationNames[cleanName] then
            isAcRecommendedBar = CLF._acNextCastId and CLF._acNextCastId == CLF._acRotationNames[cleanName]
          end
          local vc = CLF.ValidateCandidate(result.spellName, cleanName, {
            cdRemaining = cdRemaining or 0,
            cdTotal = cdTotalVal or 0,
            eventCDActive = onEventCD,
            eventCDRemaining = eventCDRem,
            isCooldownSpell = spellIsCooldown,
            isAcRecommended = isAcRecommendedBar,
            inCombat = inCombat,
            barUsable = actuallyUsable,
            hasAPLData = hasAPLData,
            gcdActive = _gcdActive,
          })
          local onCooldown = vc.onCooldown
          cdRemaining = vc.cdRemaining
          cdTotalVal = vc.cdTotal
          isAcRecommendedBar = vc.isAcRecommended
          local affordable = vc.affordable
          local resourceStarved = vc.resourceStarved
          local gcdOnlyWait = vc.gcdOnlyWait
          local effectiveCD = vc.effectiveCD
          local isChargeSpell = vc.isChargeSpell
          if vc.buffBlocked and debugThisTick then
            CLF.Log("DEBUG", "  BUFF-ACTIVE: " .. result.spellName .. " charge-spell self-buff up, treating as on CD (rem=" .. string.format("%.1f", cdRemaining or 0) .. ")")
          end
          local score = ScoreCandidate(result.spellName, result.signal, mode, spellIsCooldown and actuallyUsable and not effectiveCD)
          if vc.movePenalty and vc.movePenalty > 0 then
            score = score + vc.movePenalty
          end
          if vc.executePenalty and vc.executePenalty ~= 0 then
            score = score + vc.executePenalty
          end
          if resourceStarved and not isAcRecommendedBar then
            local stuckPen = CLF._stuckPenalties and CLF._stuckPenalties[cleanName] or 0
            score = (score < 500 and score or 500) + 200 + stuckPen
          elseif effectiveCD and not isAcRecommendedBar then
            local rem = cdRemaining or eventCDRem or 30
            if rem < 1.5 then rem = 1.5 end
            if rem > 300 then rem = 300 end
            local stuckPen = CLF._stuckPenalties and CLF._stuckPenalties[cleanName] or 0
            score = 9000 + rem * 30 + (score < 0 and 0 or score) + stuckPen
          elseif condPass and isTankRole and CLF._defensiveSpells and CLF._defensiveSpells[cleanName] and result.signal == SIGNAL_READY then
            local tbPrio = CLF._priorityMap and CLF._priorityMap[cleanName] or 0
            score = -9500 + tbPrio
            if debugThisTick then
              CLF.Log("DEBUG", "  TANK-BOOST: " .. result.spellName .. " (score=" .. score .. ")")
            end
          end
          local keybind = CLF.GetKeybind and CLF.GetKeybind(result.spellName) or (data and data.keybind) or nil
          local icon = (data and data.icon) or result.icon or "INV_Misc_QuestionMark"

          local signalLabel = "ready"
          if effectiveCD and not isAcRecommendedBar then signalLabel = "cooldown"
          elseif resourceStarved and not isAcRecommendedBar then signalLabel = "starved"
          elseif isAcRecommendedBar then signalLabel = "assisted"
          elseif result.signal <= SIGNAL_ASSISTED then signalLabel = "assisted"
          elseif result.signal == SIGNAL_PROC then signalLabel = "proc" end

          local isTankBoosted = false
          local reason = "bar"
          if effectiveCD and not isAcRecommendedBar then reason = "bar:onCD(" .. string.format("%.0f", cdRemaining or 0) .. "s)"
          elseif resourceStarved and not isAcRecommendedBar then reason = "bar:starved"
          elseif not condPass then reason = "bar:condFail"
          elseif isTankBoosted then reason = "bar:tankBoost"
          elseif result.signal <= SIGNAL_ANTS then reason = "bar:ants"
          elseif result.signal <= SIGNAL_ASSISTED then reason = "bar:assisted"
          elseif result.signal == SIGNAL_PROC then reason = "bar:proc"
          else reason = "bar:ready" end
          local isReady = not effectiveCD and not resourceStarved
          if isAcRecommendedBar then isReady = true end
          local displayCDRem = isReady and 0 or (cdRemaining or 0)
          local displayCDTotal = isReady and 0 or (cdTotalVal or 0)
          tableInsert(candidates, {
            spellName = result.spellName,
            spellIcon = icon,
            spellId = result.spellId or (data and data.spellId) or nil,
            keybind = keybind,
            isInterrupt = false,

            priority = score,
            inRange = true,
            isGlowing = isAcRecommendedBar or ((result.signal <= SIGNAL_PROC or spellIsCooldown or hasAPLData) and isReady),
            cdRemaining = displayCDRem,
            cdTotal = displayCDTotal,
            signalType = signalLabel,
            hlIcon = result.icon,
            isCooldown = spellIsCooldown,
            reason = reason,
          })

          if debugThisTick then
            CLF.Log("DEBUG", "  " .. string.upper(signalLabel) .. ": " .. result.spellName .. " (score=" .. score .. ", CD=" .. string.format("%.1f", cdRemaining or 0) .. ", usable=" .. tostring(actuallyUsable) .. ", afford=" .. tostring(affordable) .. ", src=" .. reason .. ")")
          end
        end
        end
      end
    end
  end

  -- §E6.3-APL: APL rotation spell fallback injection
  -- Spells on action bars may be missed by the signal scan (macros, hidden bars,
  -- stance-paged bars). Re-evaluate them from APL data + bar slot confirmation.
  -- Only injects spells confirmed on the player's action bars to avoid showing
  -- untalented or removed spells that still exist in WoW's spell database.
  local candidateNameSet = {}
  for _, c in ipairs(candidates) do
    candidateNameSet[string.lower(c.spellName)] = true
    if CLF._spellAliases then
      for base, alts in pairs(CLF._spellAliases) do
        if string.lower(c.spellName) == base then
          for _, alt in ipairs(alts) do candidateNameSet[alt] = true end
        end
        for _, alt in ipairs(alts) do
          if string.lower(c.spellName) == alt then
            candidateNameSet[base] = true
          end
        end
      end
    end
  end
  CLF._lastAplFallbackCount = 0
  CLF._lastAplFallbackSkipped = 0

  -- §E6.3-AC: AssistedCombat recommended spell injection
  -- AC recommendation: inject OR promote
  -- If the recommended spell is not yet a candidate, inject it.
  -- If it IS already a candidate but scored worse than -10500, promote it.
  -- This ensures AC's recommendation always wins over fillers like Wrath.
  -- Exception: for DPS/tank specs, healing spells are suppressed when HP > 70%.
  if CLF._acNextCastId and CLF._acRotationNames then
    local acId = CLF._acNextCastId
    local acName = nil
    local acMorphBase = nil
    for rName, rId in pairs(CLF._acRotationNames) do
      if rId == acId then
        acName = rName
        break
      end
    end
    if not acName then
      local getOverride = C_Spell and C_Spell.GetSpellIDForSpellIdentifier
      if getOverride then
        for rName, rId in pairs(CLF._acRotationNames) do
          local ovOk, ovId = pcall(getOverride, rId)
          if ovOk and ovId and type(ovId) == "number" and not (issecretvalue and issecretvalue(ovId)) then
            if ovId == acId then
              acName = rName
              acMorphBase = rName
              if not CLF._spellAliases then CLF._spellAliases = {} end
              local ovName = CLF._acNextCastName and string.gsub(string.gsub(string.lower(CLF._acNextCastName), "_", " "), ":", "") or nil
              if ovName and ovName ~= rName then
                if not CLF._spellAliases[rName] then CLF._spellAliases[rName] = {} end
                local found = false
                for _, a in ipairs(CLF._spellAliases[rName]) do
                  if a == ovName then found = true; break end
                end
                if not found then
                  table.insert(CLF._spellAliases[rName], ovName)
                  CLF._spellAliases[ovName] = CLF._spellAliases[ovName] or {}
                  local found2 = false
                  for _, a in ipairs(CLF._spellAliases[ovName]) do
                    if a == rName then found2 = true; break end
                  end
                  if not found2 then table.insert(CLF._spellAliases[ovName], rName) end
                  CLF._keybindCacheDirty = true
                end
              end
              if debugThisTick then
                CLF.Log("DEBUG", "AC-MORPH-RESOLVE: id=" .. acId .. " is override of " .. rName .. " (baseId=" .. rId .. ")")
              end
              break
            end
          end
        end
      end
    end
    if not acName and CLF._acNextCastName then
      local fallbackName = string.gsub(string.gsub(string.lower(CLF._acNextCastName), "_", " "), ":", "")
      if CLF._acRotationNames[fallbackName] then
        acName = fallbackName
        if debugThisTick then
          CLF.Log("DEBUG", "AC-NAME-FALLBACK: id=" .. acId .. " not in rotNames, matched by name: " .. fallbackName)
        end
      elseif CLF._spellAliases then
        for base, alts in pairs(CLF._spellAliases) do
          for _, alt in ipairs(alts) do
            if alt == fallbackName then
              acName = base
              acMorphBase = base
              break
            end
          end
          if acName then break end
        end
      end
      if not acName then
        acName = fallbackName
        if debugThisTick then
          CLF.Log("DEBUG", "AC-NAME-INJECT: " .. fallbackName .. " (id=" .. acId .. ") not in rotNames -- injecting by name")
        end
      end
    end
    if acName then
      local isOOC = CLF._oocOnlySpells[acName]
      local isNR = CLF._nonRotationSpells[acName]
      local isHB = CLF._hardBlockSpells and CLF._hardBlockSpells[acName]
      local isFG = IsFormGated(acName)
      if isHB or isFG then isNR = true end
      local isHealSuppressed = false
      local isDefSuppressed = false
      if not CLF._isHealerSpec and (CLF._healingSpells[acName] or CLF.RuntimeHealCheck(acName, acId)) then
        isHealSuppressed = true
        if debugThisTick then
          CLF.Log("DEBUG", "AC-HEAL-SUPPRESS: " .. acName .. " (non-healer, heal blocked)")
        end
      end
      if not isTankRole and CLF._defensiveSpells and CLF._defensiveSpells[acName] then
        isDefSuppressed = true
        if debugThisTick then
          CLF.Log("DEBUG", "AC-DEF-SUPPRESS: " .. acName .. " (non-tank, defensive blocked)")
        end
      end
      local acSpellKnown = true
      if CLF.IsSpellKnown then
        local kResult = CLF.IsSpellKnown(acName, acId)
        if kResult == false then
          acSpellKnown = false
          if debugThisTick then
            CLF.Log("DEBUG", "AC-SPELL-UNKNOWN: " .. acName .. " (id=" .. acId .. ") -- IsSpellKnown=false, trusting AC anyway")
          end
          acSpellKnown = true
        end
      end
      local acPetBlocked = false
      if isPetless then
        local apn = string.gsub(string.gsub(string.lower(acName), "_", " "), ":", "")
        if apn == "call pet 1" or apn == "call pet 2" or apn == "call pet 3" or apn == "call pet 4" or apn == "call pet 5"
           or apn == "call pet" or apn == "summon pet" or apn == "revive pet" or apn == "mend pet"
           or apn == "dismiss pet" then
          acPetBlocked = true
          if debugThisTick then
            CLF.Log("DEBUG", "AC-PET-BLOCK: " .. acName .. " (petless MM Hunter)")
          end
        end
      end
      if not isOOC and not isNR and not isHealSuppressed and not isDefSuppressed and acSpellKnown and not acPetBlocked then
        local alreadyIdx = nil
        local acNameLower = string.lower(acName)
        for ci, c in ipairs(candidates) do
          if string.lower(c.spellName) == acNameLower or string.gsub(string.gsub(string.lower(c.spellName), "_", " "), ":", "") == acNameLower then
            alreadyIdx = ci
            break
          end
        end
        if not alreadyIdx and CLF._spellAliases then
          local aliases = CLF._spellAliases[acNameLower]
          if aliases then
            for ci, c in ipairs(candidates) do
              local cLow = string.lower(c.spellName)
              local cClean = string.gsub(cLow, "_", " ")
              for _, alt in ipairs(aliases) do
                if cLow == alt or cClean == alt then
                  alreadyIdx = ci
                  if debugThisTick then
                    CLF.Log("DEBUG", "AC-ALIAS-MATCH: " .. acName .. " matched candidate " .. c.spellName .. " via alias " .. alt)
                  end
                  break
                end
              end
              if alreadyIdx then break end
            end
          end
        end

        if alreadyIdx then
          local existing = candidates[alreadyIdx]
          if acMorphBase then
            local morphName = CLF._acNextCastName or SafeGetSpellName(acId)
            if morphName then
              local morphIcon = CLF.ResolveSpellIcon(morphName, acId)
              if morphIcon then existing.spellIcon = morphIcon; existing.hlIcon = morphIcon end
              existing.spellName = morphName
            end
          end
          local onCD = existing.signalType == "cooldown"
          if onCD then
            local exCD = existing.cdRemaining or 0
            if exCD <= 3.0 then
              local cdTrustResOk = true
              if CLF.CheckResourceAffordable then
                local cdResCheck = CLF.CheckResourceAffordable(existing.spellName)
                if cdResCheck == false then cdTrustResOk = false end
              end
              if cdTrustResOk then
                local trustClean = string.gsub(string.gsub(string.lower(existing.spellName), "_", " "), ":", "")
                local trustIsExec = CLF._executeSpells[trustClean]
                existing.priority = trustIsExec and -12000 or -11500
                existing.signalType = "assisted"
                existing.isGlowing = true
                existing.cdRemaining = 0
                existing.reason = "ac:promoted"
                onCD = false
                if debugThisTick then
                  CLF.Log("DEBUG", "AC-CD-TRUST: " .. existing.spellName .. " CD=" .. string.format("%.1f", exCD) .. " < 3s -- trusting AC" .. (trustIsExec and " [EXECUTE]" or ""))
                end
              end
            end
          end
          if not onCD and existing.priority > -11500 then
            local execClean = NormalizeName(string.lower(existing.spellName))
            local isExec = CLF._executeSpells[execClean]
            local promoPrio = isExec and -12000 or -11500
            if debugThisTick then
              CLF.Log("DEBUG", "AC-PROMOTE: " .. existing.spellName .. " from " .. existing.priority .. " -> " .. promoPrio .. " (was " .. (existing.reason or "?") .. ")" .. (isExec and " [EXECUTE]" or ""))
            end
            existing.priority = promoPrio
            existing.signalType = "assisted"
            existing.isGlowing = true
            existing.reason = isExec and "ac:execute" or "ac:promoted"
          end
        else
          local injCleanName = NormalizeName(string.lower(SafeGetSpellName(acId) or acName))
          local injSlotMapEmpty = not CLF._spellSlots or not next(CLF._spellSlots)
          local injOnBar = false
          if injSlotMapEmpty then
            injOnBar = CLF.IsSpellKnown(SafeGetSpellName(acId) or acName, acId)
          else
            injOnBar = CLF._spellSlots[injCleanName] or CLF._spellSlots[acName] or false
            if not injOnBar and CLF._spellAliases then
              local injAliases = CLF._spellAliases[injCleanName]
              if injAliases then
                for _, injAlt in ipairs(injAliases) do
                  if CLF._spellSlots[injAlt] then injOnBar = true; break end
                end
              end
            end
          end
          if not injOnBar then
            if debugThisTick then
              CLF.Log("DEBUG", "AC-INJECT-SKIP: " .. acName .. " (not on action bar)")
            end
          elseif _movementSpells[injCleanName] or CLF._nonRotationSpells[injCleanName] then
            if debugThisTick then
              CLF.Log("DEBUG", "AC-INJECT-SKIP: " .. acName .. " (movement/non-rotation ability)")
            end
          else
          local spName = SafeGetSpellName(acId) or acName
          local icon = CLF.ResolveSpellIcon(acName, acId) or "INV_Misc_QuestionMark"
          local keybind = CLF.GetKeybind and CLF.GetKeybind(spName) or nil
          if not keybind and acMorphBase then
            keybind = CLF.GetKeybind and CLF.GetKeybind(acMorphBase) or nil
          end
          local cdLookup = acMorphBase or spName
          local _, _, injCdRem, injCdTotal = CLF.SpellStatus(cdLookup)
          local injOnEventCD, injEventRem = CLF.IsOnEventCD(cdLookup)
          if injOnEventCD and injEventRem <= 0.5 then
            injOnEventCD = false
            injEventRem = 0
          end
          local injIsCharge = CLF.Charges.IsChargeSpell(NormalizeName(string.lower(cdLookup)))
          if injIsCharge then
            injOnEventCD = false
            injEventRem = 0
            injCdRem = nil
            if debugThisTick then
              CLF.Log("DEBUG", "AC-CHARGE-TRUST: " .. cdLookup .. " is charge spell -- trusting AC over event CD")
            end
          end
          if injOnEventCD and injEventRem > 1.5 then
            if not injCdRem or injCdRem < injEventRem then injCdRem = injEventRem end
            if not injCdTotal or injCdTotal < injEventRem then injCdTotal = injEventRem end
          end
          local injOnCD = (injCdRem and injCdRem > 1.5) or injOnEventCD

          local injClean = NormalizeName(string.lower(spName))
          local injIsChargeOrCD = injIsCharge or (CLF._cdMap and CLF._cdMap[injClean])
          if not injOnCD and injIsChargeOrCD and CLF.IsSelfBuffBlocking(injClean) then
            injOnCD = true
            if not injCdRem or injCdRem < 1.5 then
              local br = CLF.SelfBuffBlockRemains(injClean)
              if br > 0 then injCdRem = br end
            end
            if not injCdTotal or injCdTotal < (injCdRem or 0) then
              injCdTotal = injCdRem
            end
            if debugThisTick then
              CLF.Log("DEBUG", "AC-INJECT-BUFF-ACTIVE: " .. spName .. " self-buff up, treating as on CD (rem=" .. string.format("%.1f", injCdRem or 0) .. ")")
            end
          end
          local injScore, injSignal, injGlow
          if injOnCD then
            local rem = injCdRem or injEventRem or 30
            if rem <= 3.0 then
              local injIsExec = CLF._executeSpells[injClean]
              injScore = injIsExec and -12000 or -11500
              injSignal = "assisted"
              injGlow = true
              injOnCD = false
              injCdRem = 0
              if debugThisTick then
                CLF.Log("DEBUG", "AC-CD-TRUST-INJ: " .. spName .. " CD=" .. string.format("%.1f", rem) .. " < 3s -- trusting AC" .. (injIsExec and " [EXECUTE]" or ""))
              end
            else
              if rem < 1.5 then rem = 1.5 end
              if rem > 300 then rem = 300 end
              injScore = 9000 + rem * 30
              injSignal = "cooldown"
              injGlow = false
            end
          else
            local isExec = CLF._executeSpells[injClean]
            injScore = isExec and -12000 or -11500
            injSignal = "assisted"
            injGlow = true
          end

          local injReason = CLF._executeSpells[injClean] and "ac:execute" or ("ac:recommended" .. (injOnCD and "(onCD)" or ""))
          candidateNameSet[acName] = true
          tableInsert(candidates, {
            spellName = spName,
            spellIcon = icon,
            keybind = keybind,
            isInterrupt = false,
            priority = injScore,
            inRange = true,
            isGlowing = injGlow,
            cdRemaining = injCdRem or 0,
            cdTotal = injCdTotal or 0,
            signalType = injSignal,
            reason = injReason,
          })
          if debugThisTick then
            CLF.Log("DEBUG", "AC-INJECT: " .. spName .. " (score=" .. injScore .. ", CD=" .. string.format("%.1f", injCdRem or 0) .. ")")
          end
          end
        end
      end
    end
  end

  -- §E6.3a: Fallback trinket injection
  -- If on-use trinkets weren't found on action bars (player didn't place them there),
  -- inject them directly from CLF._trinkets so they still appear in the queue.
  if hud.trinketsEnabled ~= false then
    local trinketFoundOnBar = {}
    for _, c in ipairs(candidates) do
      if c.isTrinket and c.trinketSlot then
        trinketFoundOnBar[c.trinketSlot] = true
      end
    end
    for slotName, t in pairs(CLF._trinkets) do
      if t.hasUse and not trinketFoundOnBar[slotName] then
        local cdRemaining, isReady = CLF.GetTrinketCooldown(slotName)
        local trinketPrio = (CLF._trinketPriority and CLF._trinketPriority[slotName]) or 50
        local score = isReady and (-11000 + trinketPrio) or (9000 + trinketPrio)
        local signalLabel = isReady and "ready" or "cooldown"
        local keybind = CLF.GetKeybind and CLF.GetKeybind(t.itemName or t.spellName) or nil
        tableInsert(candidates, {
          spellName = t.itemName or t.spellName,
          spellIcon = t.icon or "INV_Misc_Trinket",
          keybind = keybind,
          isInterrupt = false,

          priority = score,
          inRange = true,
          isGlowing = isReady,
          cdRemaining = cdRemaining,
          signalType = signalLabel,
          hlIcon = t.icon,
          isTrinket = true,
          trinketSlot = slotName,
          reason = "trinketFB:" .. signalLabel,
        })
        if debugThisTick then
          CLF.Log("DEBUG", "  TRINKET FALLBACK: " .. (t.itemName or "?") .. " (score=" .. score .. ", slot=" .. slotName .. ", cd=" .. string.format("%.1f", cdRemaining) .. ")")
        end
      end
    end
  end

  -- §E6.3a: Detect if the player just cast a spell
  -- Uses _prevGCD (set by RecordCast on SPELL_CAST_SUCCESS) and the
  -- active cast state. Works for instant, cast-time, and channeled spells.
  local justCastSpell = nil
  local cs = CLF._castState and CLF._castState.player
  local isCasting = cs and cs.casting and cs.startTime and cs.duration and cs.duration > 0
  if isCasting and cs.spellName then
    justCastSpell = string.lower(cs.spellName)
  end
  local activeChannelSpell = nil
  if not justCastSpell and CLF._activeChannel and CLF._activeChannel.spell then
    local ach = CLF._activeChannel
    local achAge = now - (ach.start or 0)
    if achAge < 12 then
      justCastSpell = string.lower(ach.spell)
      activeChannelSpell = justCastSpell
      isCasting = true
    end
  end
  if not justCastSpell and UnitChannelInfo then
    local chOk, chName = pcall(UnitChannelInfo, "player")
    if chOk and chName then
      local chClean = DetaintStr(chName)
      if chClean and chClean ~= "" then
        justCastSpell = string.lower(chClean)
        activeChannelSpell = justCastSpell
        isCasting = true
      end
    end
  end
  if not justCastSpell and CLF._prevGCD then
    local prevGCDKey = string.lower(CLF._prevGCD)
    local castLog = CLF._castLog
    if castLog and castLog[prevGCDKey] then
      local castAge = now - castLog[prevGCDKey]
      if castAge < 1.5 then
        justCastSpell = prevGCDKey
      end
    end
  end

  -- §E6.3b: Primary slot mode
  -- "Lookahead" (default): The instant a spell is cast, slot 1 shows the NEXT
  -- spell so the player can pre-position their finger on the keybind.
  -- "Current Cast": Slot 1 stays locked to the current cast/GCD spell until
  -- it finishes, then switches to the next spell.
  local lockedPrimary = nil
  local slotMode = hud.primarySlotMode or "Lookahead"

  if slotMode == "Current Cast" then
    if CLF._primaryLock and CLF._primaryLock.spell then
      local lock = CLF._primaryLock
      local lockAge = now - (lock.lockedAt or 0)
      local gcdActive = false
      local gc = CLF._gcdCache
      if gc and gc.start > 0 and gc.duration > 0 then
        local gcdAge = now - gc.start
        if gcdAge < gc.duration then gcdActive = true end
      end
      if justCastSpell and justCastSpell == lock.spell then
        CLF._primaryLock = nil
      elseif (isCasting or gcdActive) and lockAge < 4 then
        lockedPrimary = lock.spell
      else
        CLF._primaryLock = nil
      end
    end
  else
    CLF._primaryLock = nil
  end

  if #candidates > 0 then
    local filtered = {}
    for _, c in ipairs(candidates) do
      if c.isTrinket then
        tableInsert(filtered, c)
      else
        local cn = string.gsub(string.gsub(string.lower(c.spellName), "_", " "), ":", "")
        if _movementSpells[cn] then
          if debugThisTick then
            CLF.Log("DEBUG", "FINAL-GATE: " .. c.spellName .. " removed (movement ability)")
          end
        else
          tableInsert(filtered, c)
        end
      end
    end
    candidates = filtered
  end

  -- Deduplicate candidates by normalized spell name (keep best score)
  do
    local canonMap = {}
    local function canonical(name)
      if canonMap[name] then return canonMap[name] end
      local best = name
      if CLF._spellAliases then
        local al = CLF._spellAliases[name]
        if al then
          for _, alt in ipairs(al) do
            if alt < best then best = alt end
          end
          if name < best then best = name end
        else
          for base, alts in pairs(CLF._spellAliases) do
            for _, alt in ipairs(alts) do
              if alt == name then
                if base < best then best = base end
                break
              end
            end
          end
        end
      end
      canonMap[name] = best
      return best
    end
    local seen = {}
    local deduped = {}
    for _, c in ipairs(candidates) do
      local dk = string.gsub(string.gsub(string.lower(c.spellName), "_", " "), ":", "")
      local ck = canonical(dk)
      local prev = seen[ck]
      if not prev then
        seen[ck] = #deduped + 1
        tableInsert(deduped, c)
      else
        if c.priority < deduped[prev].priority then
          deduped[prev] = c
        end
      end
    end
    candidates = deduped
  end

  do
    local hasAcCandidate = false
    local acIsSpender = false
    for _, c in ipairs(candidates) do
      if c.reason and string.sub(c.reason, 1, 3) == "ac:" then
        hasAcCandidate = true
        local acClean = NormalizeName(string.lower(c.spellName))
        local cost = CLF._spellCosts and CLF._spellCosts[acClean]
        if cost and cost > 0 then
          acIsSpender = true
        end
        break
      end
    end
    if hasAcCandidate then
      for _, c in ipairs(candidates) do
        if not (c.reason and string.sub(c.reason, 1, 3) == "ac:") then
          local cClean = NormalizeName(string.lower(c.spellName))
          local cCost = CLF._spellCosts and CLF._spellCosts[cClean]
          if cCost and cCost > 0 and c.priority < 50000 then
            if debugThisTick then
              CLF.Log("DEBUG", "AC-SPENDER-SUPPRESS: " .. c.spellName .. " cost=" .. cCost .. " (AC=" .. (acIsSpender and "spender" or "generator") .. ") score " .. c.priority .. " -> " .. (c.priority + 60000))
            end
            c.priority = c.priority + 60000
            c.signalType = "starved"
          end
        end
      end
    end
  end

  -- Sort by composite score (lower = better)
  if #candidates > 1 then
    tableSort(candidates, function(a, b)
      if a.priority ~= b.priority then return a.priority < b.priority end
      return a.spellName < b.spellName
    end)
  end

  if debugThisTick and #candidates > 0 then
    CLF.Log("DEBUG", "--- SCORED CANDIDATES (" .. #candidates .. ") mode=" .. mode .. " ---")
    for ci, c in ipairs(candidates) do
      local pMap = CLF._priorityMap or {}
      local aplP = pMap[string.lower(c.spellName)] or "?"
      CLF.Log("DEBUG", "  #" .. ci .. " " .. c.spellName .. " score=" .. c.priority .. " signal=" .. (c.signalType or "?") .. " cd=" .. string.format("%.1f", c.cdRemaining or 0) .. " glow=" .. tostring(c.isGlowing) .. " aplP=" .. tostring(aplP) .. " src=" .. (c.reason or "?"))
    end
  end

  -- §E6.3b: GCD-aware queue fill
  -- Slot 1 = must be ready NOW (cd <= 0)
  -- Slot 2 = must be ready within 1 GCD (cd <= gcdMax)
  -- Slot 3 = must be ready within 2 GCDs (cd <= gcdMax * 2)
  -- Assisted/Proc spells always qualify for slot 1 regardless of CD.
  -- This provides a true "lookahead" -- the player sees what to press next
  -- even if the spell is still finishing its GCD from a prior cast.
  local gcdMax = snap.gcdMax or CLF.GCDMax()
  local usedSpells = {}
  for _, q in ipairs(queue) do
    usedSpells[string.lower(q.spellName)] = true
  end

  local castingExclude = nil
  if isCasting and cs and cs.spellName and cs.duration and cs.duration > 0.5 then
    castingExclude = string.lower(cs.spellName)
    if slotMode ~= "Current Cast" then
      local ceIsCD = (CLF._cdMap and CLF._cdMap[castingExclude]) or (CLF._spellData and CLF._spellData[castingExclude] and CLF._spellData[castingExclude].isCooldown)
      if ceIsCD then
        usedSpells[castingExclude] = true
      end
    end
  end
  if justCastSpell and slotMode ~= "Current Cast" then
    local jcIsCD = (CLF._cdMap and CLF._cdMap[justCastSpell]) or (CLF._spellData and CLF._spellData[justCastSpell] and CLF._spellData[justCastSpell].isCooldown)
    if jcIsCD then
      usedSpells[justCastSpell] = true
    end
  end
  if activeChannelSpell and slotMode ~= "Current Cast" then
    usedSpells[activeChannelSpell] = true
  end

  local function MarkUsedWithAliases(key)
    usedSpells[key] = true
    local cleaned = string.gsub(key, "_", " ")
    usedSpells[cleaned] = true
    if CLF._spellAliases then
      local al = CLF._spellAliases[key] or CLF._spellAliases[cleaned]
      if al then
        for _, a in ipairs(al) do usedSpells[a] = true end
      end
    end
  end

  if lockedPrimary and #queue == 0 then
    for _, c in ipairs(candidates) do
      if string.lower(c.spellName) == lockedPrimary then
        tableInsert(queue, c)
        MarkUsedWithAliases(lockedPrimary)
        break
      end
    end
    if #queue == 0 then
      CLF._primaryLock = nil
      lockedPrimary = nil
    end
  end

  if not lockedPrimary and slotMode ~= "Current Cast" and #queue == 0 then
    local stableKey = CLF._stableSlot1Key
    if stableKey and not usedSpells[stableKey] then
      local stableCandidate = nil
      for _, c in ipairs(candidates) do
        if string.lower(c.spellName) == stableKey then
          stableCandidate = c
          break
        end
      end
      if stableCandidate then
        local stableReady, stableReject = CLF.IsSlotReady(stableCandidate, 1, inCombat, _gcdActive)
        if not stableReady and debugThisTick then
          CLF.Log("DEBUG", "SLOT1-STABLE: " .. stableCandidate.spellName .. " failed gate (" .. (stableReject or "unknown") .. ") -- removing stale stable")
        end
        if stableReady then
          local stableScore = stableCandidate.priority or 0
          local bestScore = stableScore
          for _, bc in ipairs(candidates) do
            local bcKey = string.lower(bc.spellName)
            if bcKey ~= stableKey and not usedSpells[bcKey] then
              local bcScore = bc.priority or 0
              if bcScore < bestScore then
                bestScore = bcScore
              end
            end
          end
          if bestScore < stableScore - 150 then
            CLF._stableSlot1Key = nil
            if debugThisTick then
              CLF.Log("DEBUG", "SLOT1-STABLE: breaking " .. stableCandidate.spellName .. " (score=" .. stableScore .. ") -- better candidate score=" .. bestScore)
            end
          else
            if not stableCandidate.isGlowing then stableCandidate.isGlowing = true end
            tableInsert(queue, stableCandidate)
            MarkUsedWithAliases(stableKey)
            if debugThisTick then
              CLF.Log("DEBUG", "SLOT1-STABLE: keeping " .. stableCandidate.spellName .. " (still ready, score=" .. stableScore .. ")")
            end
          end
        else
          CLF._stableSlot1Key = nil
        end
      else
        CLF._stableSlot1Key = nil
      end
    end
  end

  for slotIdx = 1, maxSlots do
    if #queue >= maxSlots then break end
    local effectiveSlot = #queue + 1
    if lockedPrimary and effectiveSlot == 1 then
      -- skip; locked primary already placed
    else
      local slotWindow = (effectiveSlot - 1) * gcdMax + (snap.gcdRemaining or 0)
      for _, c in ipairs(candidates) do
        local cKey = string.lower(c.spellName)
        if not usedSpells[cKey] then
          local cModeMap = CLF._modeMap or {}
          local cSpellMode = c.entryMode or cModeMap[string.gsub(cKey, "_", " ")] or "Both"
          local cModeMismatch = cSpellMode ~= "Both" and cSpellMode ~= mode
          local cIsAcSrc = c.reason and (string.sub(c.reason, 1, 3) == "ac:")
          if cModeMismatch and not cIsAcSrc then
            if debugThisTick then
              CLF.Log("DEBUG", "SLOT" .. effectiveSlot .. "-SKIP: " .. c.spellName .. " (mode mismatch: spell=" .. cSpellMode .. " current=" .. mode .. ")")
            end
          else
          local cd = c.cdRemaining or 0
          local isSignal = (c.signalType == "assisted" or c.signalType == "proc")
          local signalReady = isSignal and cd <= 1.5
          if cd <= slotWindow or signalReady then
            if effectiveSlot == 1 then
              local spUsable, rejectReason = CLF.IsSlotReady(c, 1, inCombat, _gcdActive)
              if spUsable and debugThisTick then
                CLF.Log("DEBUG", "SLOT1-FILL: " .. c.spellName .. " passed gate checks")
              elseif not spUsable and debugThisTick then
                CLF.Log("DEBUG", "SLOT1-FILL: " .. c.spellName .. " rejected (" .. (rejectReason or "unknown") .. ")")
              end
              if spUsable and not c.isTrinket then
                local cn1 = string.gsub(cKey, "_", " ")
                if not CLF._isHealerSpec and (CLF._healingSpells[cn1] or CLF.RuntimeHealCheck(cn1, c.spellId)) then
                  spUsable = false
                end
                if spUsable and not CLF._isTankSpec and CLF._defensiveSpells and CLF._defensiveSpells[cn1] then
                  spUsable = false
                end
                if spUsable and not _gcdActive then
                  if C_Spell and C_Spell.IsSpellUsable then
                    local isAcTrusted = c.reason and (string.sub(c.reason, 1, 3) == "ac:") or false
                    local fOk, fUsable = pcall(C_Spell.IsSpellUsable, c.spellId or c.spellName)
                    if fOk and fUsable ~= nil and not (issecretvalue and issecretvalue(fUsable)) and not fUsable then
                      spUsable = false
                      if debugThisTick and isAcTrusted then
                        CLF.Log("DEBUG", "SLOT1-FILL: " .. c.spellName .. " AC-trusted but clean-false from IsSpellUsable -- rejecting")
                      end
                    end
                  end
                end
              end
              if not spUsable then
                -- skip unusable spells for slot 1
              else
                if not c.isGlowing then c.isGlowing = true end
                MarkUsedWithAliases(cKey)
                tableInsert(queue, c)
                break
              end
            else
              local slot23ok = true
              if c.signalType == "cooldown" or c.signalType == "starved" then
                slot23ok = false
                if debugThisTick then
                  CLF.Log("DEBUG", "SLOT" .. effectiveSlot .. "-SKIP: " .. c.spellName .. " (on cooldown/starved)")
                end
              end
              if slot23ok and inCombat and not c.isTrinket then
                local s23AcTrusted = c.reason and (string.sub(c.reason, 1, 3) == "ac:")
                local s23BarTrusted = c.reason and (string.sub(c.reason, 1, 4) == "bar:")
                if slot23ok and not s23AcTrusted and not s23BarTrusted and CLF.CheckResourceAffordable then
                  local s23ResOk = CLF.CheckResourceAffordable(c.spellName)
                  if s23ResOk == false then
                    slot23ok = false
                    if debugThisTick then
                      CLF.Log("DEBUG", "SLOT" .. effectiveSlot .. "-SKIP: " .. c.spellName .. " not affordable (resource check)")
                    end
                  end
                end
                if slot23ok and not s23AcTrusted and not s23BarTrusted then
                  local s23Usable = CLF.IsSpellUsable and CLF.IsSpellUsable(c.spellName) or false
                  if not s23Usable and _gcdActive and (c.cdRemaining or 0) <= 0 then
                    s23Usable = true
                  end
                  if not s23Usable and (c.cdRemaining or 0) <= 0 then
                    local cn23Check = string.gsub(string.gsub(string.lower(c.spellName), "_", " "), ":", "")
                    local hasAPL23 = CLF._spellData and CLF._spellData[cn23Check]
                    if hasAPL23 and not (CLF.IsSpellUsable and CLF.IsSpellUsable(c.spellName)) then
                      s23Usable = true
                      if debugThisTick then
                        CLF.Log("DEBUG", "SLOT" .. effectiveSlot .. "-APL-PASS: " .. c.spellName .. " (APL spell, no CD, awaiting resources)")
                      end
                    end
                  end
                  if not s23Usable then
                    slot23ok = false
                    if debugThisTick then
                      CLF.Log("DEBUG", "SLOT" .. effectiveSlot .. "-SKIP: " .. c.spellName .. " (not usable)")
                    end
                  end
                end
              end
              if slot23ok and inCombat and c.isTrinket and c.trinketSlot then
                local tCD, tReady = CLF.GetTrinketCooldown(c.trinketSlot)
                if not tReady or (tCD and tCD > slotWindow) then
                  slot23ok = false
                  if debugThisTick then
                    CLF.Log("DEBUG", "SLOT" .. effectiveSlot .. "-SKIP: " .. c.spellName .. " (trinket on CD)")
                  end
                end
              end
              if slot23ok and inCombat and not c.isTrinket then
                local _, _, liveCD23 = CLF.SpellStatus(c.spellName)
                if liveCD23 and liveCD23 > slotWindow + 0.5 then
                  slot23ok = false
                  if debugThisTick then
                    CLF.Log("DEBUG", "SLOT" .. effectiveSlot .. "-SKIP: " .. c.spellName .. " (live CD=" .. string.format("%.1f", liveCD23) .. "s > window)")
                  end
                end
                if slot23ok and (not liveCD23 or liveCD23 <= 0) then
                  local cn23fb = string.lower(NormalizeName(c.spellName))
                  local logTime = CLF._castLog[cn23fb]
                  local logDur = CLF._knownCDDur[cn23fb]
                  if logTime and logDur and logDur > 1.5 then
                    local logRem = logDur - (GetTime() - logTime)
                    if logRem > slotWindow + 0.5 then
                      slot23ok = false
                      if debugThisTick then
                        CLF.Log("DEBUG", "SLOT" .. effectiveSlot .. "-SKIP: " .. c.spellName .. " (castLog CD=" .. string.format("%.1f", logRem) .. "s > window)")
                      end
                    end
                  end
                end
              end
              if slot23ok and not c.isTrinket then
                local cn23 = string.gsub(cKey, "_", " ")
                if not CLF._isHealerSpec and (CLF._healingSpells[cn23] or CLF.RuntimeHealCheck(cn23, c.spellId)) then
                  slot23ok = false
                end
                if slot23ok and not CLF._isTankSpec and CLF._defensiveSpells and CLF._defensiveSpells[cn23] then
                  slot23ok = false
                end
              end
              if slot23ok then
                local aliasClean = string.gsub(cKey, "_", " ")
                if usedSpells[aliasClean] then
                  slot23ok = false
                end
              end
              if slot23ok then
                MarkUsedWithAliases(cKey)
                tableInsert(queue, c)
                break
              end
            end
          end
          end
        end
      end
    end
  end

  if #queue == 0 and #candidates > 0 then
    local fallbackExclude = nil
    for _, c in ipairs(candidates) do
      local cKey = string.lower(c.spellName)
      local cnFB = string.gsub(cKey, "_", " ")
      local fbBlocked = false
      if not c.isTrinket then
        if not CLF._isHealerSpec and (CLF._healingSpells[cnFB] or CLF.RuntimeHealCheck(cnFB, c.spellId)) then
          fbBlocked = true
        end
        if not CLF._isTankSpec and CLF._defensiveSpells and CLF._defensiveSpells[cnFB] then
          fbBlocked = true
        end
        if not fbBlocked and not _gcdActive then
          local fbLiveOk = CLF.IsSpellUsable and CLF.IsSpellUsable(c.spellName) or true
          if not fbLiveOk then fbBlocked = true end
        end
      end
      if not fbBlocked then
        local cd = c.cdRemaining or 0
        if cd <= 0 and not usedSpells[cKey] then
          if not c.isGlowing then c.isGlowing = true end
          tableInsert(queue, c)
          MarkUsedWithAliases(cKey)
          break
        end
        if cd <= 0 and not fallbackExclude then
          fallbackExclude = c
        end
      end
    end
    if #queue == 0 then
      for _, c in ipairs(candidates) do
        local cKey = string.lower(c.spellName)
        local cnFB2 = string.gsub(cKey, "_", " ")
        local fb2Blocked = false
        if not c.isTrinket then
          if not CLF._isHealerSpec and (CLF._healingSpells[cnFB2] or CLF.RuntimeHealCheck(cnFB2, c.spellId)) then
            fb2Blocked = true
          end
          if not CLF._isTankSpec and CLF._defensiveSpells and CLF._defensiveSpells[cnFB2] then
            fb2Blocked = true
          end
          if not fb2Blocked and not _gcdActive then
            local fb2LiveOk = CLF.IsSpellUsable and CLF.IsSpellUsable(c.spellName) or true
            if not fb2LiveOk then fb2Blocked = true end
          end
        end
        if not fb2Blocked then
          local fCD = c.cdRemaining or 0
          if fCD <= 3.0 and not usedSpells[cKey] then
            if not c.isGlowing then c.isGlowing = true end
            tableInsert(queue, c)
            MarkUsedWithAliases(cKey)
            break
          end
        end
      end
    end
    if #queue == 0 then
      local pick = nil
      local bestShortCD = nil
      for _, c in ipairs(candidates) do
        local cKey = string.lower(c.spellName)
        if not usedSpells[cKey] and (not activeChannelSpell or cKey ~= activeChannelSpell) then
          local fb3Affordable = c.isTrinket or (CLF.IsSpellUsable and CLF.IsSpellUsable(c.spellName) or true)
          if fb3Affordable then
            local fcd = c.cdRemaining or 0
            if fcd <= 0 then
              pick = c
              break
            end
            if fcd <= 8 and (not bestShortCD or fcd < (bestShortCD.cdRemaining or 999)) then
              bestShortCD = c
            end
          end
        end
      end
      if not pick then
        pick = bestShortCD or fallbackExclude
        if not pick and candidates[1] then
          local c1cd = candidates[1].cdRemaining or 0
          if c1cd <= 8 then pick = candidates[1] end
        end
      end
      if pick then
        if not pick.isGlowing then pick.isGlowing = true end
        tableInsert(queue, pick)
        MarkUsedWithAliases(string.lower(pick.spellName))
      end
    end
  end

  -- §E6.3b: Per-tick decision summary
  if debugThisTick and #queue > 0 then
    local parts = {}
    for si = 1, math.min(#queue, 3) do
      local sq = queue[si]
      parts[si] = "S" .. si .. "=" .. sq.spellName .. "(" .. (sq.reason or "?") .. ")"
    end
    CLF.Log("TICK", "DECISION: " .. table.concat(parts, " ") .. " mode=" .. tostring(mode) .. " candidates=" .. tostring(#candidates))
  end

  if queue[1] then
    local newPrimary = string.lower(queue[1].spellName)
    CLF._stableSlot1Key = newPrimary
    local prevPrim = CLF._prevPrimarySpell
    CLF._prevPrimarySpell = newPrimary
    local spellChanged = newPrimary ~= prevPrim
    if spellChanged and debugThisTick then
      CLF.Log("TICK", "SLOT1-CHANGE: " .. tostring(prevPrim) .. " -> " .. newPrimary .. " reason=" .. (queue[1].reason or "?") .. " score=" .. tostring(queue[1].priority or "?"))
    end
    local sameCastAgain = not spellChanged and justCastSpell and justCastSpell == newPrimary
    local flashFired = false
    if CLF._slot1PendingFlash and not _gcdActive then
      CLF._slot1PendingFlash = false
      CLF._slot1FadeStart = now
      CLF._slot1FadeDur = 0.25
      flashFired = true
    end
    if not flashFired and (spellChanged or sameCastAgain) then
      CLF._prevPrimaryTime = now
      if not _gcdActive then
        CLF._slot1FadeStart = now
        CLF._slot1FadeDur = 0.25
      else
        CLF._slot1PendingFlash = true
      end
    end
    if slotMode == "Current Cast" and not lockedPrimary then
      local curCS = CLF._castState and CLF._castState.player
      local curIsCasting = curCS and curCS.casting and curCS.startTime and curCS.duration and curCS.duration > 0
      local curGcdActive = false
      local curGc = CLF._gcdCache
      if curGc and curGc.start > 0 and curGc.duration > 0 then
        if (now - curGc.start) < curGc.duration then curGcdActive = true end
      end
      if curIsCasting or curGcdActive then
        CLF._primaryLock = { spell = newPrimary, lockedAt = now }
      end
    end
  end

  -- §E6.4: Layer 4 -- Cooldown prediction backfill
  -- If queue isn't full, show highest-priority spells coming off CD soon (≤8s)
  -- These are spells not yet ready but approaching, shown dimmed in the HUD.
  if #queue < maxSlots and hud.showPrediction ~= false then
    local cdCandidates = {}
    for _, entry in ipairs(fAPL.rotation) do
      local cleanName = string.gsub(string.gsub(string.lower(entry.spellName), "_", " "), ":", "")
      if not usedSpells[cleanName] then
        local onBar = (CLF._acRotationNames and CLF._acRotationNames[cleanName]) or (CLF._spellSlots and CLF._spellSlots[cleanName])
        if not onBar and CLF._spellAliases then
          for base, alts in pairs(CLF._spellAliases) do
            if cleanName == base then
              for _, alt in ipairs(alts) do
                if CLF._spellSlots[alt] then onBar = true; break end
              end
            end
            if not onBar then
              for _, alt in ipairs(alts) do
                if alt == cleanName and CLF._spellSlots[base] then onBar = true; break end
              end
            end
            if onBar then break end
          end
        end
        if onBar then
        local modeMatch = (entry.mode == "Both") or (entry.mode == mode)
        if modeMatch then
          local _, _, cdRemaining = CLF.SpellStatus(entry.spellName, entry.spellId)
          local onEventCD, eventCDRem = CLF.IsOnEventCD(entry.spellName)
          if onEventCD and eventCDRem <= 0.5 then onEventCD = false; eventCDRem = 0 end
          if onEventCD and (not cdRemaining or eventCDRem > cdRemaining) then
            cdRemaining = eventCDRem
          end
          if cdRemaining and cdRemaining > 0 and cdRemaining <= 8 then
            usedSpells[cleanName] = true
            tableInsert(cdCandidates, {
              spellName = entry.spellName,
              spellIcon = entry.spellIcon,
              keybind = entry.keybind,
              isInterrupt = false,
  
              priority = entry.priority,
              inRange = true,
              isGlowing = false,
              cdRemaining = cdRemaining,
              signalType = "prediction",
            })
          end
        end
        end
      end
    end

    for _, t in pairs(CLF._trinkets) do
      if t.hasUse and not usedSpells[string.lower(t.itemName or "")] then
        local cdRemaining, ready = CLF.GetTrinketCooldown(t.slotName)
        if cdRemaining and cdRemaining > 0 and cdRemaining <= 8 then
          usedSpells[string.lower(t.itemName or "")] = true
          local tPrio = (CLF._trinketPriority and CLF._trinketPriority[t.slotName]) or 50
          tableInsert(cdCandidates, {
            spellName = t.itemName or t.spellName,
            spellIcon = t.icon or "INV_Misc_Trinket",
            keybind = CLF.GetKeybind and CLF.GetKeybind(t.itemName or t.spellName) or nil,
            isInterrupt = false,

            priority = tPrio,
            inRange = true,
            isGlowing = false,
            cdRemaining = cdRemaining,
            signalType = "prediction",
            isTrinket = true,
            trinketSlot = t.slotName,
          })
        end
      end
    end

    tableSort(cdCandidates, function(a, b) return a.priority < b.priority end)

    for _, c in ipairs(cdCandidates) do
      if #queue >= maxSlots then break end
      tableInsert(queue, c)
    end
  end

  if #queue < maxSlots then
    local fillerCandidates = {}
    for _, entry in ipairs(fAPL.rotation) do
      local cleanName = string.gsub(string.gsub(string.lower(entry.spellName), "_", " "), ":", "")
      if not usedSpells[cleanName] then
        local onBar = CLF._spellSlots and CLF._spellSlots[cleanName]
        if not onBar and CLF._spellAliases then
          for base, alts in pairs(CLF._spellAliases) do
            if cleanName == base then
              for _, alt in ipairs(alts) do
                if CLF._spellSlots[alt] then onBar = true; break end
              end
            end
            if not onBar then
              for _, alt in ipairs(alts) do
                if alt == cleanName and CLF._spellSlots[base] then onBar = true; break end
              end
            end
            if onBar then break end
          end
        end
        if onBar then
        local modeMatch = (entry.mode == "Both") or (entry.mode == mode)
        if modeMatch and CLF.IsDotRefreshable(cleanName) then
          local _, _, cdRemaining = CLF.SpellStatus(entry.spellName, entry.spellId)
          local onEventCD, eventCDRem = CLF.IsOnEventCD(entry.spellName)
          if onEventCD and eventCDRem <= 0.5 then onEventCD = false; eventCDRem = 0 end
          if onEventCD and (not cdRemaining or eventCDRem > cdRemaining) then
            cdRemaining = eventCDRem
          end
          if not cdRemaining or cdRemaining <= 0 then cdRemaining = 0 end
          local slotWindow = (#queue) * gcdMax + (snap.gcdRemaining or 0)
          if cdRemaining <= slotWindow then
            usedSpells[cleanName] = true
            local data = sData[cleanName]
            local icon = (data and data.icon) or entry.spellIcon or "INV_Misc_QuestionMark"
            local keybind = CLF.GetKeybind and CLF.GetKeybind(entry.spellName) or (data and data.keybind) or entry.keybind or nil
            tableInsert(fillerCandidates, {
              spellName = entry.spellName,
              spellIcon = icon,
              keybind = keybind,
              isInterrupt = false,
  
              priority = entry.priority + 1000,
              inRange = true,
              isGlowing = false,
              cdRemaining = cdRemaining,
              signalType = "ready",
            })
          end
        end
        end
      end
    end
    tableSort(fillerCandidates, function(a, b) return a.priority < b.priority end)
    for _, c in ipairs(fillerCandidates) do
      if #queue >= maxSlots then break end
      tableInsert(queue, c)
    end
  end

  if not inCombat and hud.consumablesEnabled ~= false then
    local now = GetTime()
    if now - (CLF._lastConsumableCheck or 0) > 5.0 then
      CLF._lastConsumableCheck = now
      pcall(CLF.CheckConsumableBuffs)
    end
    if CLF.UpdateConsumableBar then
      pcall(CLF.UpdateConsumableBar)
    end
  elseif inCombat and CLF.UpdateConsumableBar then
    pcall(CLF.UpdateConsumableBar)
  end

  if inCombat and #queue > 0 then
    local top = queue[1]
    local topKey = string.lower(top.spellName)
    if not top.isInterrupt and not top.isCasting then
      if CLF._stuckTopSpell == topKey then
        local elapsed = now - CLF._stuckTopSince
        if elapsed >= 4 then
          local cap = 15000
          local overElapsed = elapsed - 4
          local rate = overElapsed > 15 and 800 or 300
          local penalty = mathMin(math.floor((overElapsed + 1) * rate), cap)
          CLF._stuckPenalties[topKey] = penalty
          if debugThisTick then
            CLF.Log("DEBUG", "  ANTI-STUCK: " .. top.spellName .. " penalty=" .. penalty .. " (stuck " .. string.format("%.0f", elapsed) .. "s)")
          end
        end
      else
        CLF._stuckTopSpell = topKey
        CLF._stuckTopSince = now
      end
    else
      CLF._stuckTopSpell = nil
      CLF._stuckTopSince = 0
    end
  elseif not inCombat then
    CLF._stuckTopSpell = nil
    CLF._stuckTopSince = 0
    CLF._stuckPenalties = {}
  end

  if debugThisTick then
    local acName = CLF._acNextCastName or "none"
    local acId = CLF._acNextCastId or 0
    CLF.Log("QUEUE", "AC recommends: " .. acName .. " (id=" .. tostring(acId) .. ") | mode=" .. slotMode .. " | justCast=" .. (justCastSpell or "nil"))
    local topN = math.min(#candidates, 6)
    for ci = 1, topN do
      local c = candidates[ci]
      CLF.Log("QUEUE", "  #" .. ci .. " " .. c.spellName .. " score=" .. c.priority .. " sig=" .. (c.signalType or "?") .. " cd=" .. string.format("%.1f", c.cdRemaining or 0) .. " src=" .. (c.reason or "?"))
    end
    if #queue > 0 then
      local summary = {}
      for i, q in ipairs(queue) do
        tableInsert(summary, i .. ":" .. q.spellName .. "(" .. (q.signalType or "?") .. ",p=" .. q.priority .. ")")
      end
      CLF.Log("QUEUE", "  Final: " .. table.concat(summary, " > "))
    else
      CLF.Log("QUEUE", "  Final: (empty)")
    end
  end

  CLF._lastSnapshot = {
    time = GetTime(),
    mode = mode,
    enemies = CLF.ActiveEnemies(),
    inCombat = inCombat,
    power = snap.power or 0,
    powerMax = snap.powerMax or 0,
    form = CLF._cachedFormName or "caster",
    queue = {},
    candidates = {},
    stuckSpell = CLF._stuckSpell,
    stuckCount = CLF._stuckCount,
  }
  for i, q in ipairs(queue) do
    local qUsable = CLF.IsSpellUsable and CLF.IsSpellUsable(q.spellName) or false
    local qOnEventCD, qEventRem = CLF.IsOnEventCD(q.spellName)
    CLF._lastSnapshot.queue[i] = {
      spell = q.spellName,
      signal = q.signalType or "?",
      priority = q.priority or 0,
      isInterrupt = q.isInterrupt or false,
      isPrecombat = q.isPrecombat or false,
      inRange = q.inRange,
      cdRemaining = q.cdRemaining or 0,
      usable = qUsable,
      eventCD = qOnEventCD and string.format("%.1f", qEventRem) or nil,
    }
  end
  for i, c in ipairs(candidates) do
    if i > 25 then break end
    local cUsable = CLF.IsSpellUsable and CLF.IsSpellUsable(c.spellName) or false
    local cOnEventCD, cEventRem = CLF.IsOnEventCD(c.spellName)
    CLF._lastSnapshot.candidates[i] = {
      spell = c.spellName,
      signal = c.signalType or "?",
      score = c._score or c.priority or 0,
      inRange = c.inRange,
      usable = cUsable,
      eventCD = cOnEventCD and string.format("%.1f", cEventRem) or nil,
      reason = c.reason or "?",
    }
  end

  CLF._lastDefensiveSlot1 = false
  CLF._lastHealSlot1 = false

  local cs = CLF._castState and CLF._castState.player
  if cs and cs.casting and cs.spellName and cs.startTime and cs.duration then
    local castElapsed = now - cs.startTime
    local castRemaining = cs.duration - castElapsed
    if castRemaining > 0.15 then
      local topIsUrgent = queue[1] and queue[1].isInterrupt
      if not topIsUrgent then
      local castSpell = cs.spellName
      local castClean = string.lower(NormalizeName(castSpell))

      local skipCastInject = slotMode ~= "Current Cast"
      if skipCastInject then
        if debugThisTick then
          CLF.Log("DEBUG", "CAST-INJECT: skipping " .. castSpell .. " in Lookahead mode (showing next spell)")
        end
      else
      local alreadyAtTop = queue[1] and string.lower(NormalizeName(queue[1].spellName)) == castClean

      if not alreadyAtTop then
        local existIdx = nil
        for qi = 1, #queue do
          if string.lower(NormalizeName(queue[qi].spellName)) == castClean then
            existIdx = qi
            break
          end
        end
        if existIdx then
          table.remove(queue, existIdx)
        end

        local castIcon = CLF.ResolveSpellIcon(castSpell, cs.spellId) or "INV_Misc_QuestionMark"
        table.insert(queue, 1, {
          spellName = castSpell,
          spellIcon = castIcon,
          keybind = "",
          isInterrupt = false,

          priority = -60000,
          inRange = true,
          isGlowing = false,
          cdRemaining = 0,
          signalType = "casting",
          isCasting = true,
        })

        while #queue > maxSlots do
          table.remove(queue)
        end
      end
      end
      end
    end
  end

  if not CLF._prevSlot2 then CLF._prevSlot2 = nil end
  if not CLF._prevSlot3 then CLF._prevSlot3 = nil end
  if not CLF._prevSlot2Time then CLF._prevSlot2Time = 0 end
  if not CLF._prevSlot3Time then CLF._prevSlot3Time = 0 end

  local SLOT_HOLD = 2.0
  if #queue >= 3 and CLF._prevSlot2 and CLF._prevSlot3 then
    local cur2 = string.lower(queue[2].spellName)
    local cur3 = string.lower(queue[3].spellName)
    if cur2 == CLF._prevSlot3 and cur3 == CLF._prevSlot2
       and (now - math.max(CLF._prevSlot2Time, CLF._prevSlot3Time)) < SLOT_HOLD then
      queue[2], queue[3] = queue[3], queue[2]
      if debugThisTick then
        CLF.Log("DEBUG", "SLOT-STABLE: S2/S3 swap detected, restored previous order")
      end
    end
  end
  for slotN = 2, math.min(3, #queue) do
    local prevField = slotN == 2 and "_prevSlot2" or "_prevSlot3"
    local timeField = slotN == 2 and "_prevSlot2Time" or "_prevSlot3Time"
    local entryField = slotN == 2 and "_prevSlot2Entry" or "_prevSlot3Entry"
    local curName = string.lower(queue[slotN].spellName)
    local prevName = CLF[prevField]
    if prevName and curName ~= prevName and (now - CLF[timeField]) < SLOT_HOLD then
      local curPrio = queue[slotN].priority or 0
      local prevPrio = nil
      local prevCandidate = nil
      for i = slotN + 1, #candidates do
        if string.lower(candidates[i].spellName) == prevName then
          prevPrio = candidates[i].priority or 0
          prevCandidate = candidates[i]
          break
        end
      end
      if not prevPrio then
        for _, c in ipairs(candidates) do
          if string.lower(c.spellName) == prevName then
            prevPrio = c.priority or 0
            prevCandidate = c
            break
          end
        end
      end
      if not prevPrio and CLF[entryField] then
        prevPrio = CLF[entryField].priority or 0
        prevCandidate = CLF[entryField]
      end
      if prevPrio and math.abs(curPrio - prevPrio) < 1000 then
        local alreadyInQueue = false
        for qi = 1, #queue do
          if qi ~= slotN and string.lower(queue[qi].spellName) == prevName then
            alreadyInQueue = true
            break
          end
        end
        if not alreadyInQueue and prevCandidate then
          queue[slotN] = prevCandidate
        end
      end
    end
  end

  for slotN = 2, math.min(3, #queue) do
    local curName = string.lower(queue[slotN].spellName)
    local prevField = slotN == 2 and "_prevSlot2" or "_prevSlot3"
    local timeField = slotN == 2 and "_prevSlot2Time" or "_prevSlot3Time"
    local entryField = slotN == 2 and "_prevSlot2Entry" or "_prevSlot3Entry"
    if CLF[prevField] ~= curName then
      CLF[prevField] = curName
      CLF[timeField] = now
    end
    CLF[entryField] = queue[slotN]
  end

  if debugThisTick and #queue > 0 then
    CLF.Log("DEBUG", "--- FINAL QUEUE (" .. #queue .. " slots) ---")
    for qi, q in ipairs(queue) do
      local slotLabel = qi == 1 and "NOW" or ("NEXT-" .. qi)
      CLF.Log("DEBUG", "  [" .. slotLabel .. "] " .. q.spellName .. " score=" .. q.priority .. " signal=" .. (q.signalType or "?") .. " glow=" .. tostring(q.isGlowing) .. " src=" .. (q.reason or "?"))
    end
  elseif debugThisTick then
    CLF.Log("DEBUG", "--- FINAL QUEUE: EMPTY ---")
  end

  CLF.lastQueue = queue
  CLF.lastRecommendation = queue[1] or nil
  return queue
end
