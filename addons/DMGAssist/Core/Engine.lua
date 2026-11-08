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

-- Priority-list variables live for the whole fight, as in SimC (e.g. Balance's "opener" stays 0 once
-- Celestial Alignment has been used). SimC runs the list once per action it takes, so the values from the
-- latest live decision are committed when the player actually casts something; look-ahead and repeated
-- refreshes between casts work on copies and never change them.
G.fightVars = {}
local pendingVars

local function CopyVars(from)
  local out = {}
  for k, v in pairs(from) do
    if v ~= UNKNOWN then
      out[k] = v
    end
  end
  return out
end

function G.OnOwnCast()
  if pendingVars and S.combatStart then
    G.fightVars = pendingVars
    pendingVars = nil
  end
end

function G.OnCombat()
  G.fightVars, pendingVars = {}, nil
  G.waiting = {}
  G.held, G.skips = {}, {}
end

-- SimC's target_if: "min:expr" / "max:expr" choose among targets (we only see the current one, so they add
-- nothing); a bare expression or "first:expr" is a filter the target must pass, so it joins the condition.
local filterCache = {}
local function Condition(e)
  local f = e.p and e.p.target_if
  if type(f) ~= "string" or f:find("^min:") or f:find("^max:") then
    return e.c
  end
  f = f:gsub("^first:", "")
  local key = (e.c or "") .. "\0" .. f
  local c = filterCache[key]
  if not c then
    c = e.c and ("(" .. e.c .. ")&(" .. f .. ")") or f
    filterCache[key] = c
  end
  return c
end

-- SimC's line_cd: this line may fire at most once every N seconds (999 = once per fight).
local function LineOnCooldown(e, id)
  local n = e.p and tonumber(e.p.line_cd)
  if not n then
    return false
  end
  local since = S.SinceCast(id)
  return since ~= nil and since < n
end

local function Test(cond, run, action)
  run.ctx.action = action
  local t = E.Test(cond, run.resolve, run.bounds)
  if t == UNKNOWN then
    run.anyUnknown = true
  end
  return t
end

local function Value(expr, run)
  run.ctx.action = nil
  return E.Value(expr, run.resolve, run.bounds)
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
-- Cast time right now in seconds (live from the game when readable, else SimC's data), for the movement check.
local function CastTime(id)
  local info = U.Get(C_Spell and C_Spell.GetSpellInfo, id)
  local ms = type(info) == "table" and U.Read(info.castTime)
  if type(ms) == "number" then
    return ms / 1000
  end
  local data = M.Info(id)
  return data and data.ct or 0
end

-- Is the spell castable (now, or at the look-ahead moment)? true / false / UNKNOWN, plus a reason when false:
-- "power" (not enough resources: a pooling candidate) or "moving" (has a cast time and we are moving).
local function Castable(id)
  local usable, noPower = U.Call(C_Spell and C_Spell.IsSpellUsable, id)
  usable, noPower = U.Read(usable), U.Read(noPower)
  if usable == nil then
    return UNKNOWN
  end
  local ahead = S.Lookahead()
  local first = not ahead or #ahead.prev == 0
  if not usable then
    if noPower ~= true then
      return false
    end
    if not ahead then
      return false, "power"
    end
    -- Can't afford it now; by the look-ahead moment we may (resources gained in between).
    local afford = S.Affordable(id)
    if afford ~= true then
      return false, "power"
    end
  elseif ahead and S.Affordable(id) == false then
    return false, "power"
  end
  if first and S.moving and not (ns.db and ns.db.castWhileMoving) and CastTime(id) > 0 then
    return false, "moving"
  end
  local ready = S.CooldownReady(id)
  if ready == false then
    return false
  end
  return ready
end
G.Castable = Castable

-- Does Blizzard (live assistant, or our evaluation of its rules) agree with this spell?
-- Escalation. Blizzard's assistant never mentions many spells SimC relies on, so its silence is no "no". A key
-- spell (a real cooldown) that SimC keeps reaching while the assistant says something else is promoted once it
-- has waited long enough: "the assistant is clearly ignoring this, SimC says it matters, use it now". Fillers
-- (no cooldown) never escalate: that is what let an uncertain Starfire shadow Fury of Elune before.
-- Held spells. Skipping the spell in slot 1 twice in a fight ("not now, I'm saving it") holds it until the
-- fight ends: it is left out of every slot. Casting it yourself at any point releases it again.
G.SKIPS_TO_HOLD = 2
G.held, G.skips = {}, {}

local function Base(id)
  return (M.baseOf and M.baseOf[id]) or id
end

-- castID: the spell the player cast; shown: what slot 1 showed at that moment.
function G.OnPlayerCast(castID, shown, enabled)
  if not castID then
    return nil
  end
  local cast = Base(castID)
  for id in pairs(G.held) do
    if Base(id) == cast then
      G.held[id] = nil
      G.skips[id] = nil
      return "released", id
    end
  end
  if not (shown and shown.id) then
    return nil
  end
  if Base(shown.id) == cast then
    G.skips[shown.id] = nil
    return nil
  end
  local info = M.Info(castID)
  if enabled == false or (info and info.gcd == 0) or shown.source == "interrupt" or shown.source == "guess"
    or shown.source == "pool" then
    return nil -- off-GCD presses are no skip; a kick is tied to one enemy cast
  end
  local n = (G.skips[shown.id] or 0) + 1
  G.skips[shown.id] = n
  if n >= G.SKIPS_TO_HOLD then
    G.held[shown.id] = true
    G.skips[shown.id] = nil
    return "held", shown.id
  end
  return nil
end

function G.IsHeld(id)
  return id and G.held[id] or false
end

G.KEY_COOLDOWN = 20 -- seconds of cooldown that make a spell "key"
G.WAIT = 4          -- seconds SimC must have wanted it, uncorroborated, before it comes in anyway
G.LAPSE = 1.5       -- a gap longer than this between sightings starts the wait again
G.waiting = {}

local function Waited(id, token, run, castable)
  if not run.first or castable ~= true then
    return nil
  end
  local cd = S.CooldownLength and S.CooldownLength(id)
  if not (cd and cd >= G.KEY_COOLDOWN) then
    return nil
  end
  local now = S.Now()
  local w = G.waiting[token]
  local since = S.SinceCast(id)
  if not w or now - w.seen > G.LAPSE or (since and since < now - w.since) then
    w = { since = now }
    G.waiting[token] = w
  end
  w.seen = now
  if now - w.since >= G.WAIT then
    return "waited"
  end
  return nil
end
G.Waited = Waited

local function Corroborated(id, token, run, castable)
  if run.acSpell then
    -- Blizzard's live assistant sees the hidden state (procs, resources); our evaluation of its rules does
    -- not. When it is there, only it can confirm an uncertain line: otherwise a rule that happens to hold
    -- would let an uncertain filler shadow the certain lines below it (Balance: an uncertain Starfire over
    -- Fury of Elune while the assistant was saying Fury of Elune, seen in game 2026-11-08).
    if run.acSpell == id or run.acSpell == run.override[id] then
      return "assisted"
    end
    -- The major cooldowns are left out of the assistant by design: it never names them, so for them its
    -- choice says nothing and Blizzard's written rules decide (Incarnation never reached slot 1, 2026-11-08).
    if not run.cooldowns[token] then
      return Waited(id, token, run, castable)
    end
  end
  local rules = run.blizzardByAction[token]
  if rules then
    for _, e in ipairs(rules) do
      if Test(e.c, run, token) == true then
        return "rules"
      end
    end
  end
  if run.acSpell then
    return Waited(id, token, run, castable)
  end
  return nil
end

-- A line that is UNKNOWN only because one hidden resource is unknown ("ferocious_bite if combo_points>=5"):
-- evaluate it for every possible value of that resource. If the answer depends on the value, the HUD can show
-- this spell and the next pick together and let the game render whichever is right: the alpha of each icon is a
-- step curve evaluated on the secret resource (UnitPowerPercent with a curve) - we never read the value.
function G.Branch(cond, run, id, token)
  if not cond then
    return nil
  end
  run.lineUnknown = {}
  E.Test(cond, run.resolve, run.bounds)
  local names = run.lineUnknown
  run.lineUnknown = nil
  local only, count = nil, 0
  for n in pairs(names) do
    only, count = n, count + 1
  end
  local pt = count == 1 and S.PowerTypeOf(only)
  local max = pt and S.PowerMax(pt)
  if not (pt and max and max <= 200) then
    return nil
  end
  local truth, anyTrue, anyFalse = {}, false, false
  run.ctx.powerOverride = { [pt] = 0 }
  for v = 0, max do
    run.ctx.powerOverride[pt] = v
    local t = E.Test(cond, run.resolve, run.bounds)
    if t == UNKNOWN then
      run.ctx.powerOverride = nil
      return nil
    end
    truth[v] = t
    anyTrue, anyFalse = anyTrue or t, anyFalse or not t
  end
  run.ctx.powerOverride = nil
  if not (anyTrue and anyFalse) then
    return nil
  end
  return { pt = pt, max = max, truth = truth, pick = { id = id, token = token, source = "branch" } }
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
    elseif a == "pool_resource" then
      if not isBlizzard and e.p and tostring(e.p.for_next) == "1" and not maybe then
        run.poolNext = Test(e.c, run) == true or nil
      end
    elseif not G.SKIP[a] and not (isBlizzard and not run.burst and (e.x or run.cooldowns[a])) then
      -- (Blizzard's excluded lines are the major cooldowns: left out only when major cooldowns are off.)
      local id = M.SpellID(a)
      if id and G.held[id] then
        if run.trace then
          run.trace[#run.trace + 1] = string.format("%s:%s held (you skipped it)", name, a)
        end
      elseif id and LineOnCooldown(e, id) then
        if run.trace then
          run.trace[#run.trace + 1] = string.format("%s:%s line_cd", name, a)
        end
      elseif id then
        local cond = Condition(e)
        local castable, why = Castable(id)
        local pooling = run.poolNext
        run.poolNext = nil
        if run.trace then
          run.trace[#run.trace + 1] = string.format("%s:%s castable=%s%s", name, a, tostring(castable),
            why and ("(" .. why .. ")") or "")
        end
        if castable == false and why == "power" and pooling and not isBlizzard and not maybe
          and Test(cond, run, a) == true then
          -- SimC said "pool for the next action" and this is it: wait for the resource instead of a filler.
          run.visiting[name] = nil
          return { id = id, token = a, source = "pool" }
        end
        if castable ~= false then
          local t = Test(cond, run, a)
          if run.trace then
            run.trace[#run.trace] = run.trace[#run.trace] .. " cond=" .. tostring(t)
          end
          if t ~= false then
            local certain = t == true and castable == true and not maybe
            if run.cooldowns[a] and not run.burst then
              -- Major cooldowns switched off: they are not recommended at all. Switched on (the default) they
              -- are ordinary lines in SimC's order, in the same three slots as everything else; lists such as
              -- Balance's opener wait for them, so they must never be set aside.
              if run.trace then
                run.trace[#run.trace] = run.trace[#run.trace] .. " (major cooldowns off)"
              end
            elseif certain then
              run.visiting[name] = nil
              return { id = id, token = a, source = isBlizzard and "rules" or "simc" }
            elseif not isBlizzard then
              local how = Corroborated(id, a, run, castable)
              if how then
                run.visiting[name] = nil
                return { id = id, token = a, source = "simc+" .. how }
              end
              if not run.firstMaybe then
                run.firstMaybe = { id = id, token = a, source = "guess" }
              end
              if run.first and not run.branch and not maybe and castable == true then
                run.branch = G.Branch(cond, run, id, a)
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
    ctx = { vars = CopyVars(G.fightVars), targets = targets },
    visiting = {},
    unresolved = {},
    cooldowns = prep.cooldowns,
    blizzardByAction = prep.blizzardByAction,
    burst = opts.burst ~= false,
    override = {},
    trace = (first and opts.trace) and {} or nil,
  }
  run.first = first
  run.resolve = function(name)
    local v = S.Resolve(name, run.ctx)
    if v == UNKNOWN then
      S.unknownTerms[name] = (S.unknownTerms[name] or 0) + 1
      if run.lineUnknown then
        run.lineUnknown[name] = true
      end
    end
    return v
  end
  run.bounds = S.Bounds
  if first and opts.useAssisted then
    local ac = U.Get(C_AssistedCombat and C_AssistedCombat.GetNextCastSpell, false)
    if type(ac) == "number" then
      run.acSpell = ac
      setmetatable(run.override, { __index = function(t, id)
        local o = U.Get(C_Spell and C_Spell.GetOverrideSpell, id)
        t[id] = o or false
        return t[id]
      end })
    end
  end

  -- What the assistant's pick tells us about hidden state (facts feed the resolver for this decision on).
  if run.acSpell then
    run.oracleLine = ns.Clues.ObserveAssisted(record, run.acSpell, {
      resolve = run.resolve,
      bounds = run.bounds,
      castable = Castable,
      same = function(id, ac)
        return id == ac or run.override[id] == ac
      end,
    })
  end

  -- Precombat variables feed the main list. Out of combat they are worked out fresh every time; in combat
  -- only the ones the fight has no value for yet (SimC sets them once, before the pull).
  if type(record.simc) == "table" and record.simc.precombat then
    local inCombat = S.combatStart ~= nil
    for _, e in ipairs(record.simc.precombat) do
      if e.a == "variable" and not (inCombat and e.p and run.ctx.vars[e.p.name] ~= nil) then
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
  if pick and pick.token and run.cooldowns[pick.token] then
    pick.major = true -- a major cooldown (for the "burst" sound); shown in the queue like any other spell
  end
  if first then
    pendingVars = CopyVars(run.ctx.vars)
  end
  local branch = run.branch
  if branch and pick and pick.id ~= branch.pick.id and pick.source ~= "guess" then
    branch.otherwise = pick
  else
    branch = nil
  end
  return { main = pick, acSpell = run.acSpell, unresolved = run.unresolved, vars = run.ctx.vars,
    branch = branch, trace = run.trace }
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

-- Steady slot 1. Close to the next press the decision can flip between two spells several times a second as
-- hidden state shifts; that is hard to follow. Inside the last moments before the GCD / cast ends, slot 1 is
-- locked to what it showed when the window opened, and a different new pick moves into slot 2 (it is next
-- anyway). The lock ends when the player presses something (a new GCD starts), when the locked spell stops
-- being castable, or after G.LOCK_MAX. Interrupts and defensives are applied after this and still take slot 1.
G.LOCK_WINDOW = 0.5
G.LOCK_MAX = 1.5
local held

function G.ReadyIn()
  local _, castLeft = S.CurrentCast()
  return math.max(S.GCDRemains() or 0, castLeft or 0)
end

function G.Steady(result)
  local main = result and result.main
  if not main or not main.id or not S.combatStart then
    held = nil
    return result
  end
  local now = S.Now()
  local ready = G.ReadyIn()
  if ready > G.LOCK_WINDOW then
    held = nil
    return result
  end
  if held and (now - held.at > G.LOCK_MAX or Castable(held.pick.id) == false) then
    held = nil
  end
  if not held then
    held = { pick = main, at = now }
    return result
  end
  if held.pick.id == main.id then
    return result
  end
  local queue, out = result.queue or { main }, { held.pick }
  for _, p in ipairs(queue) do
    if p.id ~= held.pick.id and #out < #queue then
      out[#out + 1] = p
    end
  end
  result.queue, result.main, result.steadied = out, held.pick, main.token
  return result
end

function G.ResetSteady()
  held = nil
end
