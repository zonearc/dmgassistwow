-- Engine.lua: picks the next spell. SimC leads, Blizzard backs it up (docs/design/engine-priority.md).
--
-- Per decision:
--   1. Walk the SimC list (precombat variables, then "default", following call/run_action_list).
--      A spell line that is usable, off cooldown and whose condition is TRUE on a certain path wins.
--      A line that is UNKNOWN anywhere on its path is a "maybe": it wins only when corroborated —
--      by the live Assisted Combat pick (Midnight) or by Blizzard's own rule for that spell being TRUE.
--   2. No SimC pick: the live Assisted Combat pick (Midnight), then Blizzard's rules evaluated by us (Forever),
--      then the first SimC maybe (shown as a guess).
--   3. Major cooldowns (the lines Blizzard leaves out of its assistant) go to a separate cooldown slot, only while
--      the burst toggle is on; they never block the main pick.

local _, ns = ...
local U, E, M, S = ns.U, ns.Expr, ns.SpellMap, ns.State
local UNKNOWN = E.UNKNOWN

local G = {}
ns.Engine = G

-- Actions that are not spells we recommend.
G.SKIP = {
  auto_attack = true, snapshot_stats = true, use_item = true, use_items = true, potion = true, flask = true,
  food = true, augmentation = true, invoke_external_buff = true, pool_resource = true, wait = true,
  cancel_buff = true, retarget_auto_attack = true, variable = true, call_action_list = true,
  run_action_list = true, start_moving = true, stop_moving = true, cancel_action = true, wait_for_cooldown = true,
  sequence = true, strict_sequence = true, swap_action_list = true,
}

local STOP = {}
local MAX_DEPTH = 8

local function Test(cond, run, action)
  run.ctx.action = action
  local t = E.Test(cond, run.resolve)
  if t == UNKNOWN then
    run.anyUnknown = true
  end
  return t
end

local function Value(expr, run)
  run.ctx.action = nil
  return E.Value(expr, run.resolve)
end

local function Combine(op, cur, v)
  if cur == UNKNOWN or v == UNKNOWN then
    return UNKNOWN
  end
  if op == "max" then
    return math.max(cur, v)
  elseif op == "min" then
    return math.min(cur, v)
  elseif op == "add" then
    return cur + v
  elseif op == "sub" then
    return cur - v
  elseif op == "mul" then
    return cur * v
  elseif op == "div" then
    if v == 0 then
      return 0
    end
    return cur / v
  end
  return v
end

local function DoVariable(e, run)
  local p = e.p or {}
  local name = p.name
  if not name then
    return
  end
  local vars = run.ctx.vars
  if vars[name] == nil and p.default then
    vars[name] = tonumber(p.default) or 0
  end
  local gate = Test(e.c, run)
  if gate == false then
    return
  end
  local op = p.op or "set"
  local v
  if op == "reset" then
    v = tonumber(p.default) or 0
  elseif op == "setif" then
    local c = Test(p.condition, run)
    if c == UNKNOWN then
      local a, b = Value(p.value, run), Value(p.value_else, run)
      v = (a == b) and a or UNKNOWN
    elseif c then
      v = Value(p.value, run)
    else
      v = Value(p.value_else, run)
    end
  else
    v = Combine(op, vars[name] or 0, Value(p.value, run))
  end
  if gate == UNKNOWN then
    v = UNKNOWN
  end
  vars[name] = v
end

-- Is the spell castable (now, or at the look-ahead moment)? true / false / UNKNOWN.
local function Castable(id)
  local usable, noPower = U.Call(C_Spell and C_Spell.IsSpellUsable, id)
  usable, noPower = U.Read(usable), U.Read(noPower)
  if usable == nil then
    return UNKNOWN
  end
  local ahead = S.Lookahead()
  if not usable then
    if noPower ~= true or not ahead then
      return false
    end
    -- Can't afford it now; by the look-ahead moment we may (resources gained in between).
    local afford = S.Affordable(id)
    if afford ~= true then
      return false
    end
  elseif ahead and S.Affordable(id) == false then
    return false
  end
  local ready = S.CooldownReady(id)
  if ready == false then
    return false
  end
  return ready
end
G.Castable = Castable

-- Does Blizzard (live assistant, or our evaluation of its rules) agree with this spell?
local function Corroborated(id, token, run)
  if run.acSpell and (run.acSpell == id or run.acSpell == run.override[id]) then
    return "assisted"
  end
  local rules = run.blizzardByAction[token]
  if rules then
    for _, e in ipairs(rules) do
      if Test(e.c, run, token) == true then
        return "rules"
      end
    end
  end
  return nil
end

local function Walk(lists, name, maybe, depth, run, isBlizzard)
  local list = lists[name]
  if not list or depth > MAX_DEPTH or run.visiting[name] then
    return nil
  end
  run.visiting[name] = true
  for _, e in ipairs(list) do
    local a = e.a
    if a == "variable" then
      if not isBlizzard then
        DoVariable(e, run)
      end
    elseif a == "call_action_list" or a == "run_action_list" then
      local sub = e.p and e.p.name
      local t = Test(e.c, run)
      if sub and t ~= false then
        local r = Walk(lists, sub, maybe or t == UNKNOWN, depth + 1, run, isBlizzard)
        if r then
          run.visiting[name] = nil
          return r
        end
        if a == "run_action_list" and t == true and not maybe then
          run.visiting[name] = nil
          return STOP
        end
      end
    elseif not G.SKIP[a] and not (isBlizzard and (e.x or run.cooldowns[a])) then
      -- (Blizzard's excluded lines are the major cooldowns: never a main pick from the fallback.)
      local id = M.SpellID(a)
      if id then
        local castable = Castable(id)
        if castable ~= false then
          local t = Test(e.c, run, a)
          if t ~= false then
            local certain = t == true and castable == true and not maybe
            if run.cooldowns[a] then
              if run.burst and not run.cd then
                if certain or Corroborated(id, a, run) == "rules" then
                  run.cd = { id = id, token = a }
                end
              end
            elseif certain then
              run.visiting[name] = nil
              return { id = id, token = a, source = isBlizzard and "rules" or "simc" }
            elseif not isBlizzard then
              local how = Corroborated(id, a, run)
              if how then
                run.visiting[name] = nil
                return { id = id, token = a, source = "simc+" .. how }
              end
              if not run.firstMaybe then
                run.firstMaybe = { id = id, token = a, source = "guess" }
              end
            elseif not run.firstRuleMaybe then
              run.firstRuleMaybe = { id = id, token = a, source = "rules?" }
            end
          end
        end
      else
        run.unresolved[a] = true
      end
    end
  end
  run.visiting[name] = nil
  return nil
end

local function SetOf(list)
  local out = {}
  if type(list) == "table" then
    for _, v in ipairs(list) do
      out[v] = true
    end
  end
  return out
end

-- Per-record caches: Blizzard rule lines grouped by action, and the cooldown set.
local prepared = setmetatable({}, { __mode = "k" })

local function Prepare(record)
  local p = prepared[record]
  if p then
    return p
  end
  p = { blizzardByAction = {}, cooldowns = SetOf(record.blizzardExcluded) }
  if type(record.blizzard) == "table" then
    for _, list in pairs(record.blizzard) do
      for _, e in ipairs(list) do
        if not G.SKIP[e.a] then
          local t = p.blizzardByAction[e.a]
          if not t then
            t = {}
            p.blizzardByAction[e.a] = t
          end
          t[#t + 1] = e
        end
      end
    end
  end
  prepared[record] = p
  return p
end

-- One decision at the current overlay moment.
local function Decide(record, opts, targets, first)
  local prep = Prepare(record)
  local run = {
    ctx = { vars = {}, targets = targets },
    visiting = {},
    unresolved = {},
    cooldowns = prep.cooldowns,
    blizzardByAction = prep.blizzardByAction,
    burst = first and opts.burst ~= false,
    override = {},
  }
  run.resolve = function(name)
    local v = S.Resolve(name, run.ctx)
    if v == UNKNOWN then
      S.unknownTerms[name] = (S.unknownTerms[name] or 0) + 1
    end
    return v
  end
  if first and opts.useAssisted then
    local ac = U.Read(U.Call(C_AssistedCombat and C_AssistedCombat.GetNextCastSpell, false))
    if type(ac) == "number" then
      run.acSpell = ac
      setmetatable(run.override, { __index = function(t, id)
        local o = U.Read(U.Call(C_Spell and C_Spell.GetOverrideSpell, id))
        t[id] = o or false
        return t[id]
      end })
    end
  end

  -- Precombat variables feed the main list (SimC evaluates them once; they are cheap, so every time).
  if type(record.simc) == "table" and record.simc.precombat then
    for _, e in ipairs(record.simc.precombat) do
      if e.a == "variable" then
        DoVariable(e, run)
      end
    end
  end

  local pick
  if type(record.simc) == "table" then
    pick = Walk(record.simc, "default", false, 0, run, false)
  end
  if pick == STOP then
    pick = nil
  end
  if not pick and run.acSpell then
    pick = { id = run.acSpell, token = M.TokenForID(run.acSpell), source = "assisted" }
  end
  if not pick and type(record.blizzard) == "table" then
    local start = record.blizzard.default and "default" or (record.blizzardOrder or {})[1]
    local r = start and Walk(record.blizzard, start, false, 0, run, true)
    if r and r ~= STOP then
      pick = r
    end
  end
  pick = pick or run.firstMaybe or run.firstRuleMaybe
  return { main = pick, cd = run.cd, acSpell = run.acSpell, unresolved = run.unresolved, vars = run.ctx.vars }
end

local function Queue(record, opts, targets)
  local depth = opts.depth or 3
  -- Slot 1 is what to press when the GCD (or the current cast) ends, with that cast already counted.
  local castID, castLeft = S.CurrentCast()
  local dt = math.max(S.GCDRemains(), castLeft or 0)
  local v = S.BeginLookahead(dt)
  if castID then
    S.Apply(castID)
    v.dt = dt
  end
  local result = Decide(record, opts, targets, true)
  result.queue = { result.main }
  local last = result.main
  for slot = 2, depth do
    if not (last and last.id) then
      break
    end
    S.Apply(last.id)
    local nextPick = Decide(record, opts, targets, false).main
    result.queue[slot] = nextPick
    last = nextPick
  end
  result.casting = castID
  return result
end

-- opts: { burst = bool, useAssisted = bool, depth = 1..3 }
-- Returns { main, queue = {pick, pick, pick}, cd, acSpell, unresolved, vars, targets, modeLabel }.
function G.Recommend(record, opts)
  opts = opts or {}
  local targets, label = S.Targets()
  local ok, result = pcall(Queue, record, opts, targets)
  S.EndLookahead()
  if not ok then
    error(result, 0)
  end
  result.targets, result.modeLabel = targets, label
  return result
end
