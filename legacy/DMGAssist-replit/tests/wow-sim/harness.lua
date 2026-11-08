local json = {}

local function jsonEncode(val, indent, level)
  level = level or 0
  indent = indent or ""
  local t = type(val)
  if t == "nil" then return "null"
  elseif t == "boolean" then return val and "true" or "false"
  elseif t == "number" then
    if val ~= val then return "null" end
    if val == math.huge or val == -math.huge then return "null" end
    return tostring(val)
  elseif t == "string" then
    val = val:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    return '"' .. val .. '"'
  elseif t == "table" then
    local isArray = #val > 0 or next(val) == nil
    if isArray and next(val) == nil then return "[]" end
    if isArray then
      local parts = {}
      for i, v in ipairs(val) do
        parts[i] = jsonEncode(v, indent, level + 1)
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, v in pairs(val) do
        parts[#parts + 1] = '"' .. tostring(k) .. '":' .. jsonEncode(v, indent, level + 1)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

json.encode = jsonEncode

local MockState = dofile(arg[1] .. "/tests/wow-sim/mock-api.lua")

local configPath = arg[2]
local scenarioPath = arg[3]

local addonName = "DMGAssist"
local CLF = {}
_G.CLF = CLF

local chunk, err = loadfile(configPath)
if not chunk then
  io.write(json.encode({error = "Failed to load Config: " .. tostring(err)}))
  os.exit(1)
end

local ok, loadErr = pcall(chunk, addonName, CLF)
if not ok then
  io.write(json.encode({error = "Failed to execute Config: " .. tostring(loadErr)}))
  os.exit(1)
end

local config = _G.CLF_DefaultConfig or _G.CLF_AllSpecs

if not config then
  local allSpecs = _G.CLF_AllSpecs
  if allSpecs then
    config = allSpecs
  else
    io.write(json.encode({error = "No CLF_DefaultConfig or CLF_AllSpecs found after loading config"}))
    os.exit(1)
  end
end

local function getSpecConfig(specId)
  if _G.CLF_DefaultConfig then
    return _G.CLF_DefaultConfig
  end
  if _G.CLF_AllSpecs and _G.CLF_AllSpecs[specId] then
    return _G.CLF_AllSpecs[specId]
  end
  return nil
end

local function normalize(name)
  if not name then return "" end
  return name:lower():gsub("[%s%-']", "_"):gsub("[^%w_]", "")
end

local function setupCLFHelpers()
  CLF._snap = {}
  CLF._vars = MockState.vars
  CLF._prevGCD = MockState.prevGCD
  CLF._combatStart = MockState.combatStartTime
  CLF._spellData = {}
  CLF._lastInterruptState = false
  CLF.combatMode = "ST"

  function CLF.BuffUp(name)
    local n = normalize(name)
    local b = MockState.buffs[n]
    return b ~= nil and b.up == true
  end

  function CLF.BuffRemains(name)
    local n = normalize(name)
    local b = MockState.buffs[n]
    if b then return math.max(0, b.remains) end
    return 0
  end

  function CLF.BuffStacks(name)
    local n = normalize(name)
    local b = MockState.buffs[n]
    if b then return b.stacks or 0 end
    return 0
  end

  function CLF.BuffDuration(name)
    local n = normalize(name)
    local b = MockState.buffs[n]
    if b then return b.duration or 0 end
    return 0
  end

  function CLF.BuffMaxStacks(name)
    local n = normalize(name)
    local b = MockState.buffs[n]
    if b then return b.maxStacks or 1 end
    return 1
  end

  function CLF.DebuffUp(name)
    local n = normalize(name)
    local d = MockState.debuffs[n]
    return d ~= nil and d.up == true
  end

  function CLF.DebuffRemains(name)
    local n = normalize(name)
    local d = MockState.debuffs[n]
    if d then return math.max(0, d.remains) end
    return 0
  end

  function CLF.DebuffStacks(name)
    local n = normalize(name)
    local d = MockState.debuffs[n]
    if d then return d.stacks or 0 end
    return 0
  end

  function CLF.DebuffPandemic(name, baseDur)
    local remains = CLF.DebuffRemains(name)
    baseDur = baseDur or 10
    return remains < (baseDur * 0.3)
  end

  function CLF.ActiveDot(name)
    return CLF.DebuffUp(name) and 1 or 0
  end

  function CLF.CooldownReady(name)
    local n = normalize(name)
    local cd = MockState.cooldowns[n]
    return cd == nil or cd.remains <= 0
  end

  function CLF.CooldownRemains(name)
    local n = normalize(name)
    local cd = MockState.cooldowns[n]
    if cd then return math.max(0, cd.remains) end
    return 0
  end

  function CLF.CooldownCharges(name)
    local n = normalize(name)
    local c = MockState.spellCharges[n]
    if c then return c.charges end
    return CLF.CooldownReady(name) and 1 or 0
  end

  function CLF.CooldownDuration(name)
    local n = normalize(name)
    local cd = MockState.cooldowns[n]
    if cd then return cd.duration or 0 end
    return 0
  end

  function CLF.ChargesFractional(name)
    local n = normalize(name)
    local c = MockState.spellCharges[n]
    if c then
      local partial = 0
      if c.start and c.duration and c.duration > 0 then
        partial = (MockState.time - c.start) / c.duration
      end
      return c.charges + math.min(1, math.max(0, partial))
    end
    return CLF.CooldownReady(name) and 1 or 0
  end

  function CLF.Power()
    return MockState.power
  end

  function CLF.PowerMax()
    return MockState.powerMax
  end

  function CLF.PowerPct()
    if MockState.powerMax == 0 then return 100 end
    return (MockState.power / MockState.powerMax) * 100
  end

  function CLF.PowerDeficit()
    return MockState.powerMax - MockState.power
  end

  function CLF.Runes()
    local count = 0
    for _, ready in ipairs(MockState.runes) do
      if ready then count = count + 1 end
    end
    return count
  end

  function CLF.PlayerHealthPct()
    if MockState.playerHealthMax == 0 then return 100 end
    return (MockState.playerHealth / MockState.playerHealthMax) * 100
  end

  function CLF.TargetHealthPct()
    if MockState.targetHealthMax == 0 then return 100 end
    return (MockState.targetHealth / MockState.targetHealthMax) * 100
  end

  function CLF.FightRemains()
    return 300
  end

  function CLF.ActiveEnemies()
    return MockState.activeEnemies
  end

  function CLF.TargetIsCasting()
    return MockState.targetCasting
  end

  function CLF.IsSpellUsable(name)
    local n = normalize(name)
    return MockState.usableSpells[n] ~= false
  end

  function CLF.IsSpellKnown(name)
    local n = normalize(name)
    return MockState.knownSpells[n] ~= false
  end

  function CLF.SpellCastTime(name)
    local n = normalize(name)
    return MockState.spellCastTimes[n] or 0
  end

  function CLF.SpellCost(name)
    local n = normalize(name)
    return MockState.spellCosts[n] or 0
  end

  function CLF.TalentEnabled(name)
    local n = normalize(name)
    return MockState.talentsEnabled[n] ~= false
  end

  function CLF.GCDRemains()
    if MockState.gcdStart > 0 and MockState.gcdDuration > 0 then
      local remaining = (MockState.gcdStart + MockState.gcdDuration) - MockState.time
      return math.max(0, remaining)
    end
    return 0
  end

  function CLF.GCDMax()
    return math.max(0.75, 1.5 / (1 + MockState.haste / 100))
  end

  function CLF.PrevGCD(name)
    local n = normalize(name)
    local prev = normalize(MockState.prevGCD)
    return n == prev
  end

  function CLF.IsMoving()
    return MockState.moving
  end

  function CLF.IsForm(name)
    local n = normalize(name)
    local current = normalize(MockState.shapeshiftFormName)
    return n == current and MockState.shapeshiftForm > 0
  end

  function CLF.IsStealthed()
    return MockState.stealthed
  end

  function CLF.PetAlive()
    return MockState.petAlive
  end

  function CLF.PetActive(name)
    return MockState.petAlive
  end

  function CLF.PetRemains(name)
    return MockState.petAlive and 999 or 0
  end

  function CLF.TotemActive(name)
    local n = normalize(name)
    local t = MockState.totems[n]
    return t ~= nil and t.active
  end

  function CLF.TotemRemains(name)
    local n = normalize(name)
    local t = MockState.totems[n]
    if t then return t.remains or 0 end
    return 0
  end

  function CLF.GetVar(name)
    return MockState.vars[name] or 0
  end

  function CLF.SetVar(name, value)
    MockState.vars[name] = value
  end

  function CLF.SpellStatus(name)
    local usable = CLF.IsSpellUsable(name)
    local ready = CLF.CooldownReady(name)
    local remains = CLF.CooldownRemains(name)
    return usable, ready, remains
  end

  function CLF.IsInRange(name)
    return true
  end

  function CLF.CombatTime()
    if not MockState.inCombat then return 0 end
    return MockState.time - MockState.combatStartTime
  end

  function CLF.ShouldShowInterrupt()
    return MockState.targetCasting and MockState.targetCastInterruptible, nil
  end

  function CLF.RefreshSnapshot()
    CLF._snap = {
      health = MockState.playerHealth,
      healthMax = MockState.playerHealthMax,
      healthPct = CLF.PlayerHealthPct(),
      power = MockState.power,
      powerMax = MockState.powerMax,
      time = MockState.time,
    }
  end

  function CLF.Log(level, msg) end

  function CLF.GetKeybind(name) return nil end
  function CLF.RefreshHUD() end
  function CLF.IsDotRefreshable(name) return CLF.DebuffPandemic(name) end
end

local function evaluateRotation(specConfig)
  setupCLFHelpers()

  local rotation = specConfig.apl or specConfig.rotation or {}
  local interrupts = specConfig.interrupts or {}

  local results = {
    queue = {},
    precombatNeeded = {},
    interruptAvailable = false,
    conditionResults = {},
    errors = {},
  }

  for i, entry in ipairs(rotation) do
    local condSrc = entry.conditionSrc
    local spellName = entry.spellName or "Unknown"
    local condResult = {
      spell = spellName,
      priority = entry.priority or 999,
      mode = entry.mode or "Both",
      isPrecombat = entry.isPrecombat or false,
      precombatType = entry.precombatType,
      isInterrupt = entry.isInterrupt or false,
      isCooldown = entry.isCooldown or false,
    }

    if condSrc and condSrc ~= "" then
      local fn, compileErr = load(condSrc)
      if fn then
        local ok, condValue = pcall(fn)
        if ok then
          condResult.conditionMet = condValue and true or false
        else
          condResult.conditionMet = false
          condResult.error = tostring(condValue)
          table.insert(results.errors, {spell = spellName, error = tostring(condValue)})
        end
      else
        condResult.conditionMet = false
        condResult.error = "compile: " .. tostring(compileErr)
        table.insert(results.errors, {spell = spellName, error = "compile: " .. tostring(compileErr)})
      end
    else
      condResult.conditionMet = true
    end

    local usable = CLF.IsSpellUsable(normalize(spellName))
    local ready = CLF.CooldownReady(normalize(spellName))
    condResult.usable = usable
    condResult.ready = ready

    table.insert(results.conditionResults, condResult)

    if condResult.conditionMet and usable and ready then
      if condResult.isPrecombat and condResult.precombatType == "state" then
        table.insert(results.precombatNeeded, spellName)
      end
      table.insert(results.queue, {
        spell = spellName,
        priority = entry.priority or 999,
        mode = entry.mode or "Both",
        isPrecombat = entry.isPrecombat or false,
        isInterrupt = entry.isInterrupt or false,
        isCooldown = entry.isCooldown or false,
      })
    end
  end

  if MockState.targetCasting and MockState.targetCastInterruptible then
    for _, intEntry in ipairs(rotation) do
      if intEntry.isInterrupt then
        local spellName = intEntry.spellName or ""
        local usable = CLF.IsSpellUsable(normalize(spellName))
        local ready = CLF.CooldownReady(normalize(spellName))
        if usable and ready and spellName ~= "" then
          results.interruptAvailable = true
          table.insert(results.queue, 1, {
            spell = spellName,
            priority = 0,
            isInterrupt = true,
          })
          break
        end
      end
    end
  end

  return results
end

local function validateQueueIntegrity(queue, mode)
  local violations = {}

  local seenNames = {}
  for i, q in ipairs(queue) do
    local cn = normalize(q.spell)

    if seenNames[cn] then
      table.insert(violations, {
        type = "DUPLICATE",
        slot = i,
        spell = q.spell,
        detail = "Duplicate: already in slot " .. seenNames[cn],
      })
    else
      seenNames[cn] = i
    end

    if q.mode and q.mode ~= "Both" and mode and mode ~= "Both" then
      if q.mode ~= mode then
        table.insert(violations, {
          type = "MODE_MISMATCH",
          slot = i,
          spell = q.spell,
          detail = "Spell mode=" .. q.mode .. " but combat mode=" .. mode,
        })
      end
    end

    local cd = MockState.cooldowns[cn]
    if cd and cd.remains > 1.5 and i == 1 then
      table.insert(violations, {
        type = "CD_VIOLATION",
        slot = i,
        spell = q.spell,
        detail = "On cooldown (remains=" .. string.format("%.1f", cd.remains) .. "s) but in slot 1",
      })
    end
  end

  return violations
end

local function simulateMultiTick(specConfig, ticks, combatSetup)
  local allTickResults = {}
  local allViolations = {}

  MockState:Reset()
  if combatSetup then
    combatSetup(MockState)
  end

  for tick = 1, ticks do
    setupCLFHelpers()

    local mode = "ST"
    if MockState.activeEnemies > 1 then mode = "AoE" end

    local result = evaluateRotation(specConfig)

    local rawQueue = {}
    for _, q in ipairs(result.queue) do
      if not q.isPrecombat then
        table.insert(rawQueue, q)
      end
    end

    local rawViolations = validateQueueIntegrity(rawQueue, mode)
    for _, v in ipairs(rawViolations) do
      v.tick = tick
      v.time = MockState.time
      v.phase = "raw"
      table.insert(allViolations, v)
    end

    local modeFiltered = {}
    for _, q in ipairs(rawQueue) do
      local qMode = q.mode or "Both"
      if qMode == "Both" or qMode == mode then
        table.insert(modeFiltered, q)
      end
    end

    local filteredQueue = {}
    local seenDedup = {}
    for _, q in ipairs(modeFiltered) do
      local cn = normalize(q.spell)
      if not seenDedup[cn] then
        seenDedup[cn] = true
        table.insert(filteredQueue, q)
      end
    end

    local violations = validateQueueIntegrity(filteredQueue, mode)
    for _, v in ipairs(violations) do
      v.tick = tick
      v.time = MockState.time
      table.insert(allViolations, v)
    end

    local tickResult = {
      tick = tick,
      time = MockState.time,
      mode = mode,
      queueSize = #filteredQueue,
      queue = {},
      violationCount = #violations,
    }

    local maxSlots = math.min(3, #filteredQueue)
    for i = 1, maxSlots do
      table.insert(tickResult.queue, {
        slot = i,
        spell = filteredQueue[i].spell,
        priority = filteredQueue[i].priority,
        mode = filteredQueue[i].mode,
        isCooldown = filteredQueue[i].isCooldown,
      })
    end
    table.insert(allTickResults, tickResult)

    if filteredQueue[1] then
      local castSpell = filteredQueue[1].spell
      local cn = normalize(castSpell)
      local cdDur = 0
      if filteredQueue[1].isCooldown then
        cdDur = 15
      end
      MockState:CastSpell(castSpell, cdDur)
    end

    local gcdTime = math.max(0.75, 1.5 / (1 + MockState.haste / 100))
    MockState:AdvanceTime(gcdTime)
  end

  return {
    ticks = allTickResults,
    violations = allViolations,
    totalViolations = #allViolations,
  }
end

local scenario = dofile(scenarioPath)

if not scenario then
  io.write(json.encode({error = "Failed to load scenario"}))
  os.exit(1)
end

local specId = scenario.specId
local specConfig

if _G.CLF_DefaultConfig then
  specConfig = _G.CLF_DefaultConfig
elseif _G.CLF_AllSpecs then
  specConfig = _G.CLF_AllSpecs[specId]
end

if not specConfig then
  io.write(json.encode({error = "Spec config not found for: " .. tostring(specId)}))
  os.exit(1)
end

if scenario.multiTick then
  local mtResult = simulateMultiTick(specConfig, scenario.multiTick.ticks or 10, scenario.multiTick.setup)
  io.write(json.encode({
    specId = specId,
    scenarioName = scenario.name or "unnamed",
    multiTick = true,
    ticks = mtResult.ticks,
    violations = mtResult.violations,
    totalViolations = mtResult.totalViolations,
    totalTicks = #mtResult.ticks,
  }))
else
  local allResults = {}

  for i, step in ipairs(scenario.steps) do
    MockState:Reset()
    setupCLFHelpers()

    if step.setup then
      step.setup(MockState)
    end

    local result = evaluateRotation(specConfig)
    result.stepName = step.name or ("Step " .. i)
    result.stepIndex = i
    table.insert(allResults, result)
  end

  io.write(json.encode({
    specId = specId,
    scenarioName = scenario.name or "unnamed",
    results = allResults,
    totalSteps = #scenario.steps,
  }))
end
