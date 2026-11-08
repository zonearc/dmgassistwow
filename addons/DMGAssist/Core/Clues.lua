-- Clues.lua: facts inferred from what the game still shows in combat, each checked against the truth whenever
-- the truth is readable, and switched off for this player if they turn out unreliable.
--
-- 1. Assisted Combat as an oracle (Midnight). Blizzard's assistant runs secure code that sees everything, and its
--    rules ship in our data (SimC's assisted_combat lists). If it recommends spell X, the first rule line for X
--    is TRUE and every earlier rule whose spell is castable right now is FALSE. From those we learn atoms:
--    "buff.clearcasting.react" was TRUE -> Clearcasting is up; "combo_points>=5" was FALSE -> combo points <= 4.
-- 2. Proc glows. SPELL_ACTIVATION_OVERLAY_GLOW_SHOW/HIDE carry plain spell IDs. Out of combat (auras readable) we
--    learn which buff appears together with which glow; in combat the glow then tells us the buff is up/gone.
-- 3. Affordability. C_Spell.IsSpellUsable returns isUsable + insufficientPower and is not secret. For spells
--    with a single resource cost (from SimC's spell data) that brackets the hidden resource: usable -> at least
--    the cost, "not enough" -> below it. Glowing spells are skipped (procs often make them free).
--
-- Facts are short-lived: oracle facts last FACT_TTL seconds and are dropped when we cast (state changed);
-- glow facts last until the glow goes away. While auras or resources are readable they are compared with the
-- facts; an inference source that is wrong more than MAX_WRONG of the time (after MIN_CHECKS) is disabled.

local _, ns = ...
local U, E, M = ns.U, ns.Expr, ns.SpellMap
local UNKNOWN = E.UNKNOWN

local C = {}
ns.Clues = C

local FACT_TTL = 1.0
local LINK_WINDOW = 0.3
local MIN_CHECKS = 20
local MAX_WRONG = 0.2

C.aura = { player = {}, target = {} } -- token -> { up = bool, untilT = time, source = "assisted"|"glow" }
C.bounds = {}                          -- powerType -> { lo =, hi =, untilT =, source = }
C.stats = {}                           -- source -> { checks =, wrong =, facts =, disabled = }
C.links = {}                           -- glowing spellID -> aura token (learned; saved per spec)

local function Stat(source)
  local s = C.stats[source]
  if not s then
    s = { checks = 0, wrong = 0, facts = 0, disabled = false }
    C.stats[source] = s
  end
  return s
end

function C.Enabled(source)
  return not Stat(source).disabled
end

local function Record(source, correct)
  local s = Stat(source)
  s.checks = s.checks + 1
  if not correct then
    s.wrong = s.wrong + 1
  end
  if not s.disabled and s.checks >= MIN_CHECKS and s.wrong / s.checks > MAX_WRONG then
    s.disabled = true
    U.Log("clue_disabled", { source = source, checks = s.checks, wrong = s.wrong })
  end
end

function C.Reset(links)
  C.aura = { player = {}, target = {} }
  C.bounds = {}
  C.named = {}
  C.shadow = {}
  C.floor = {}
  C.stats = {}
  C.links = links or {}
  C.lastSignal, C.lastNewAura = nil, nil
end

---------------------------------------------------------------------------
-- Aura facts
---------------------------------------------------------------------------
function C.SetAura(unit, token, up, ttl, source)
  if not C.Enabled(source) or not C.aura[unit] then
    return
  end
  C.aura[unit][token] = { up = up, untilT = GetTime() + ttl, source = source }
  Stat(source).facts = Stat(source).facts + 1
end

-- up, remains (UNKNOWN while up: an inferred fact says "up", not for how long) or nil when there is no live fact.
function C.AuraFact(unit, token)
  local facts = C.aura[unit]
  if not facts then
    return nil
  end
  local now = GetTime()
  for _, t in ipairs(M.Candidates(token)) do
    local f = facts[t]
    if f and f.untilT > now and C.Enabled(f.source) then
      if f.up then
        return true, UNKNOWN
      end
      return false, 0
    end
  end
  return nil
end

-- A readable aura scan arrived: grade our live facts against it.
function C.Verify(unit, readable)
  local facts = C.aura[unit]
  if not (facts and readable) then
    return
  end
  local now = GetTime()
  for token, f in pairs(facts) do
    if f.untilT > now then
      local actual = readable[token] ~= nil
      Record(f.source, actual == f.up)
    end
  end
end

-- Our own cast changed the state: oracle conclusions about "now" are stale.
function C.OnCast()
  for _, unit in ipairs({ "player", "target" }) do
    for token, f in pairs(C.aura[unit]) do
      if f.source == "assisted" then
        C.aura[unit][token] = nil
      end
    end
  end
  for pt, b in pairs(C.bounds) do
    if b.source == "assisted" then
      C.bounds[pt] = nil
    end
  end
end

function C.OnTargetChanged()
  C.aura.target = {}
end

---------------------------------------------------------------------------
-- On/off signals linked to buffs: proc glows, button overrides, requirement-based usability
---------------------------------------------------------------------------
-- A signal is anything the game shows in combat that switches on and off: a proc glow on a button
-- (key = spellID), a button turning into another spell ("o<baseID>", e.g. Bite -> Ravage), or a spell becoming
-- castable for reasons other than resources ("u<spellID>", e.g. a proc-only ability, or a form). Out of combat we
-- learn which buff appears with which signal; in combat the signal then says the buff is up or gone.
local function SignalSource(key)
  if type(key) == "number" then
    return "glow"
  elseif key:sub(1, 1) == "o" then
    return "override"
  end
  return "requirement"
end
C.SignalSource = SignalSource

local function Link(key, token)
  if C.links[key] ~= token then
    C.links[key] = token
    U.Log("signal_link", { signal = key, aura = token })
  end
end

function C.OnSignal(key, on, aurasReadable)
  local now = GetTime()
  if on then
    C.lastSignal = { key = key, t = now }
    local n = C.lastNewAura
    if aurasReadable and n and now - n.t <= LINK_WINDOW then
      Link(key, n.token)
    end
  end
  local token = C.links[key]
  if token then
    if on then
      C.SetAura("player", token, true, 30, SignalSource(key))
    else
      C.SetAura("player", token, false, 1.0, SignalSource(key))
    end
  end
end

-- Glow shown/hidden on spellID (kept as its own entry point: glows are the most common signal).
function C.OnGlow(spellID, shown, aurasReadable)
  C.OnSignal(spellID, shown, aurasReadable)
end

-- A new aura appeared on the player (readable scan).
function C.OnNewAura(token)
  local now = GetTime()
  C.lastNewAura = { token = token, t = now }
  local g = C.lastSignal
  if g and now - g.t <= LINK_WINDOW then
    Link(g.key, token)
  end
end

local overrideState, requirementState = {}, {}

-- SPELL_UPDATE_ICON / COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED: which buttons are transformed right now?
function C.ScanOverrides(aurasReadable)
  for id, b in pairs(M.book) do
    if b.id == id and not b.passive then
      local o = U.Get(C_Spell and C_Spell.GetOverrideSpell, id)
      if type(o) == "number" then
        local on = o ~= id
        if overrideState[id] ~= nil and overrideState[id] ~= on then
          C.OnSignal("o" .. id, on, aurasReadable)
        end
        overrideState[id] = on
      end
    end
  end
end

-- SPELL_UPDATE_USABLE: spells whose castability changed for a reason other than resources.
function C.ScanRequirements(aurasReadable)
  for id, b in pairs(M.book) do
    if b.id == id and not b.passive then
      local usable, noPower = U.Call(C_Spell and C_Spell.IsSpellUsable, id)
      usable, noPower = U.Read(usable), U.Read(noPower)
      if usable ~= nil then
        local met = usable == true or noPower == true
        if requirementState[id] ~= nil and requirementState[id] ~= met then
          C.OnSignal("u" .. id, met, aurasReadable)
        end
        requirementState[id] = met
      end
    end
  end
end

---------------------------------------------------------------------------
-- Resource bounds
---------------------------------------------------------------------------
local bracketAt, bracket = nil, {}

-- lo/hi for a hidden resource from what we can and can't afford right now (cached per frame).
local function Affordability()
  local now = GetTime()
  if bracketAt == now then
    return bracket
  end
  bracketAt, bracket = now, {}
  for id, b in pairs(M.book) do
    if b.id == id and not b.passive and not ns.State.glow[id] then
      local info = M.Info(id)
      local cost = M.Cost(info)
      if cost and not info.cmax then
        local pt, amount = next(cost)
        if pt and next(cost, pt) == nil and amount > 0 then
          local usable, noPower = U.Call(C_Spell and C_Spell.IsSpellUsable, id)
          usable, noPower = U.Read(usable), U.Read(noPower)
          local r = bracket[pt] or { lo = 0, hi = math.huge }
          if usable == true then
            r.lo = math.max(r.lo, amount)
          elseif usable == false and noPower == true then
            r.hi = math.min(r.hi, amount - 1)
          end
          bracket[pt] = r
        end
      end
    end
  end
  return bracket
end
C.Affordability = Affordability

function C.SetBound(pt, lo, hi, ttl, source)
  if not C.Enabled(source) then
    return
  end
  local b = C.bounds[pt]
  local now = GetTime()
  if not b or b.untilT <= now then
    b = { lo = 0, hi = math.huge }
  end
  b.lo, b.hi = math.max(b.lo, lo or 0), math.min(b.hi, hi or math.huge)
  b.untilT, b.source = now + ttl, source
  C.bounds[pt] = b
  Stat(source).facts = Stat(source).facts + 1
end

-- Combined lo, hi for a power type (nil when nothing is known). Contradictions (lo > hi) are dropped.
function C.ResourceBounds(pt)
  local lo, hi = 0, math.huge
  local known = false
  local now = GetTime()
  local o = C.bounds[pt]
  if o and o.untilT > now and C.Enabled(o.source) then
    lo, hi, known = math.max(lo, o.lo), math.min(hi, o.hi), true
  end
  local slo, shi = C.ShadowBounds(pt)
  if slo then
    lo, hi, known = math.max(lo, slo), math.min(hi, shi), true
  end
  local flo, fhi = C.FloorBounds(pt)
  if flo then
    lo, hi, known = math.max(lo, flo), math.min(hi, fhi), true
  end
  if C.Enabled("usable") then
    local a = Affordability()[pt]
    if a and (a.lo > 0 or a.hi < math.huge) then
      lo, hi, known = math.max(lo, a.lo), math.min(hi, a.hi), true
    end
  end
  if not known or lo > hi then
    return nil
  end
  return lo, hi
end

-- Grade bounds against a readable value (out of combat, or a resource that isn't secret).
function C.VerifyPower(pt, value)
  local now = GetTime()
  local o = C.bounds[pt]
  if o and o.untilT > now then
    Record(o.source, value >= o.lo and value <= o.hi)
  end
  local a = Affordability()[pt]
  if a and (a.lo > 0 or a.hi < math.huge) then
    Record("usable", value >= a.lo and value <= a.hi)
  end
end

---------------------------------------------------------------------------
-- Named bounds (target health, distance) and spell ranges
---------------------------------------------------------------------------
C.named = {} -- name -> { lo, hi, untilT, source }

function C.SetNamed(name, lo, hi, ttl, source)
  if not C.Enabled(source) then
    return
  end
  local now = GetTime()
  local b = C.named[name]
  if not b or b.untilT <= now then
    b = { lo = -math.huge, hi = math.huge }
  end
  b.lo, b.hi = math.max(b.lo, lo or -math.huge), math.min(b.hi, hi or math.huge)
  b.untilT, b.source = now + ttl, source
  C.named[name] = b
  Stat(source).facts = Stat(source).facts + 1
end

function C.NamedBounds(name)
  local b = C.named[name]
  if b and b.untilT > GetTime() and C.Enabled(b.source) and b.lo <= b.hi then
    return b.lo, b.hi
  end
  return nil
end

local rangeAt, rangeLo, rangeHi = nil, nil, nil

-- Distance to the target from which of our spells are in range (SimC ranges + C_Spell.IsSpellInRange).
function C.DistanceBounds()
  local now = GetTime()
  if rangeAt ~= now then
    rangeAt, rangeLo, rangeHi = now, 0, math.huge
    local any = false
    for id, b in pairs(M.book) do
      local info = b.id == id and not b.passive and M.Info(id)
      if info and info.r then
        local inRange = U.Get(C_Spell and C_Spell.IsSpellInRange, id, "target")
        if inRange == true then
          rangeHi, any = math.min(rangeHi, info.r), true
        elseif inRange == false then
          rangeLo, any = math.max(rangeLo, info.r + 0.5), true
        end
      end
    end
    if not any then
      rangeLo, rangeHi = nil, nil
    end
  end
  local lo, hi = rangeLo, rangeHi
  local nlo, nhi = C.NamedBounds("target.distance")
  if nlo then
    lo, hi = math.max(lo or nlo, nlo), math.min(hi or nhi, nhi)
  end
  if lo and lo <= hi then
    return lo, hi
  end
  return nil
end

---------------------------------------------------------------------------
-- Shadow counters for discrete resources (combo points, holy power, chi, shards, arcane charges, essence)
---------------------------------------------------------------------------
-- Start from the last readable value, apply SimC's cost/gain for every cast we see, and use UNIT_POWER_UPDATE
-- (whose payload names the resource and is never secret) as confirmation: an expected change without the event
-- did not happen (miss), an event we didn't expect (a proc granted or spent some) makes the count uncertain.
C.DISCRETE = { COMBO_POINTS = 4, SOUL_SHARDS = 7, HOLY_POWER = 9, CHI = 12, ARCANE_CHARGES = 16, ESSENCE = 19 }
local DISCRETE_PT = {}
for _, pt in pairs(C.DISCRETE) do
  DISCRETE_PT[pt] = true
end
local CONFIRM_WINDOW = 0.6
C.shadow = {} -- pt -> { v =, max =, certain =, pending = { prev =, t = } }

-- Called with the real value whenever it is readable: resync, and grade the counter.
function C.SyncPower(pt, value, max)
  if not DISCRETE_PT[pt] then
    return
  end
  local sh = C.shadow[pt]
  if sh and sh.certain and not sh.pending then
    Record("shadow", sh.v == value)
  end
  C.shadow[pt] = { v = value, max = max, certain = true }
end

local function Settle(sh)
  local p = sh.pending
  if p and GetTime() - p.t > CONFIRM_WINDOW then
    -- No UNIT_POWER_UPDATE followed our cast: the change didn't happen (miss/dodge, or already capped).
    if p.restoreLo then
      sh.certain, sh.lo, sh.hi = false, p.restoreLo, p.restoreHi
    else
      sh.v = p.prev
    end
    sh.pending = nil
  end
end

function C.OnOwnCast(id)
  local info = M.Info(id)
  if not info then
    return
  end
  C.FloorOnCast(info)
  local costs = M.Cost(info)
  for pt, sh in pairs(C.shadow) do
    Settle(sh)
    local cost = costs and costs[pt]
    local gain = info.gain and info.gain[pt]
    -- A finisher that can spend up to the cap empties the resource: exact again, whatever we knew before.
    local cmaxAll = cost and info.cmax and info.cmax[pt]
    if not sh.certain and cmaxAll and sh.max and cmaxAll >= sh.max then
      sh.pending = { t = GetTime(), restoreLo = sh.lo, restoreHi = sh.hi }
      sh.v, sh.certain, sh.lo, sh.hi = gain or 0, true, nil, nil
      cost, gain = nil, nil
    end
    if not sh.certain and (cost or gain) and sh.lo then
      local d = (gain or 0) - (cost or 0)
      sh.lo, sh.hi = math.max(0, sh.lo + d), math.max(0, sh.hi + d)
      if sh.max and sh.max > 0 then
        sh.lo, sh.hi = math.min(sh.lo, sh.max), math.min(sh.hi, sh.max)
      end
    end
    if sh.certain and (cost or gain) then
      local v = sh.v
      if cost then
        local cmax = info.cmax and info.cmax[pt]
        v = v - (cmax and math.min(v, cmax) or cost)
      end
      v = v + (gain or 0)
      if sh.max and sh.max > 0 then
        v = math.min(v, sh.max)
      end
      v = math.max(0, v)
      if v ~= sh.v then
        sh.pending = { prev = sh.v, t = GetTime() }
        sh.v = v
      end
    end
  end
end

-- UNIT_POWER_UPDATE("player", powerToken).
function C.OnPowerEvent(token)
  local pt = C.DISCRETE[token]
  local sh = pt and C.shadow[pt]
  if not sh then
    return
  end
  if sh.pending and GetTime() - sh.pending.t <= CONFIRM_WINDOW then
    sh.pending = nil -- the change we predicted happened
  elseif not U.Get(UnitPower, "player", pt) then
    -- Something we didn't cause changed it. Almost always a free point (crit bonus, talent proc), so the
    -- count becomes "v or v+1" instead of fully unknown; each further surprise widens it; a finisher that
    -- spends everything makes it exact again (see OnOwnCast).
    local lo, hi = sh.lo or sh.v, sh.hi or sh.v
    sh.lo, sh.hi = lo, math.min(hi + 1, sh.max and sh.max > 0 and sh.max or hi + 1)
    sh.certain = false
  end
end

---------------------------------------------------------------------------
-- Floors for built resources (Astral Power, Insanity, Maelstrom, Fury, Runic Power)
---------------------------------------------------------------------------
-- These have no passive regeneration in combat: they change through our own casts, plus bonus gains we can't
-- see (procs such as Shooting Stars). So "last readable value + SimC's gains - SimC's full costs, cast by
-- cast" never exceeds the truth: a floor. Talents that cut costs or add gains only make the truth higher.
-- It decides lines like Balance's "wrath while astral_power<80" once enough Wraths have been cast. Graded
-- against the real value whenever it is readable again ("floor"), and switched off if it is ever above it.
C.BUILT = { RUNIC_POWER = 6, ASTRAL_POWER = 8, MAELSTROM = 11, INSANITY = 13, FURY = 17 }
local BUILT_PT = {}
for _, pt in pairs(C.BUILT) do
  BUILT_PT[pt] = true
end
C.floor = {} -- pt -> { lo =, max =, moved = true once a cast changed it }

function C.SyncFloor(pt, value, max)
  if not BUILT_PT[pt] then
    return
  end
  local f = C.floor[pt]
  if f and f.moved then
    Record("floor", value >= f.lo)
  end
  C.floor[pt] = { lo = value, max = max }
end

function C.FloorOnCast(info)
  local costs = M.Cost(info)
  for pt, f in pairs(C.floor) do
    local d = ((info.gain and info.gain[pt]) or 0) - ((costs and costs[pt]) or 0)
    if d ~= 0 then
      f.lo = math.max(0, f.lo + d)
      if type(f.max) == "number" and f.max > 0 then
        f.lo = math.min(f.lo, f.max)
      end
      f.moved = true
    end
  end
end

function C.FloorBounds(pt)
  local f = C.floor[pt]
  if f and C.Enabled("floor") then
    return f.lo, (type(f.max) == "number" and f.max > 0) and f.max or math.huge
  end
  return nil
end

-- Range of a counted resource that became uncertain: lo, hi or nil.
function C.ShadowBounds(pt)
  local sh = C.shadow[pt]
  if sh and not sh.certain and sh.lo and C.Enabled("shadow") then
    return sh.lo, sh.hi
  end
  return nil
end

-- Exact value from the counter, or nil.
function C.ShadowValue(pt)
  local sh = C.shadow[pt]
  if not (sh and sh.certain and C.Enabled("shadow")) then
    return nil
  end
  Settle(sh)
  return sh.v
end

---------------------------------------------------------------------------
-- Blizzard's Cooldown Manager (the built-in buff/cooldown tracker)
---------------------------------------------------------------------------
-- Its buff icons decide "active" in Blizzard's own (secure) code and keep the result on the item frames
-- (item.isActive, item.cooldownID -> C_CooldownViewer.GetCooldownViewerCooldownInfo(...).spellID).
-- Whether those fields are readable to addons in combat is unverified (frames carry "secret aspects", and aura
-- instance IDs are secret); U.Read drops anything secret, and the source is graded against readable truth like
-- every other clue. Only buffs the player chose to track in the Cooldown Manager are visible here.
C.CDM_VIEWERS = { "BuffIconCooldownViewer", "BuffBarCooldownViewer" }

function C.ReadCooldownManager(readable)
  if not C.Enabled("cdm") then
    return 0
  end
  local seen = 0
  for _, name in ipairs(C.CDM_VIEWERS) do
    local viewer = _G[name]
    if type(viewer) == "table" and type(viewer.GetChildren) == "function" then
      for _, item in ipairs({ U.Call(viewer.GetChildren, viewer) }) do
        local cdID = type(item) == "table" and U.Read(item.cooldownID)
        local active = type(item) == "table" and U.Read(item.isActive)
        if type(cdID) == "number" and type(active) == "boolean" then
          local info = U.Get(C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
          local sid = type(info) == "table" and U.Read(info.spellID)
          local token = sid and M.AuraToken(sid, U.Get(C_Spell and C_Spell.GetSpellName, sid))
          if token then
            local unit = U.Get(item.GetAuraDataUnit, item)
            if unit ~= "target" then
              unit = "player"
            end
            seen = seen + 1
            local truth = readable and readable[unit]
            if truth then
              Record("cdm", (truth[token] ~= nil) == active)
            else
              C.SetAura(unit, token, active, 0.5, "cdm")
            end
          end
        end
      end
    end
  end
  return seen
end

---------------------------------------------------------------------------
-- Assisted Combat as an oracle
---------------------------------------------------------------------------
-- Blizzard's rules flattened in evaluation order: { a = action, c = "(call cond)&(line cond)" }, excluded lines dropped.
local flatCache = setmetatable({}, { __mode = "k" })

local function Flatten(lists, name, prefix, out, depth, seen)
  local list = lists[name]
  if not list or depth > 6 or seen[name] then
    return
  end
  seen[name] = true
  for _, e in ipairs(list) do
    local cond = e.c
    if prefix and cond then
      cond = "(" .. prefix .. ")&(" .. cond .. ")"
    elseif prefix then
      cond = prefix
    end
    if e.a == "call_action_list" or e.a == "run_action_list" then
      if e.p and e.p.name then
        Flatten(lists, e.p.name, cond, out, depth + 1, seen)
      end
    elseif not e.x and e.a ~= "variable" then
      out[#out + 1] = { a = e.a, c = cond }
    end
  end
  seen[name] = nil
end

function C.BlizzardOrder(record)
  local flat = flatCache[record]
  if not flat then
    flat = {}
    if type(record.blizzard) == "table" then
      Flatten(record.blizzard, record.blizzard.default and "default" or "assisted_combat", nil, flat, 0, {})
    end
    flatCache[record] = flat
  end
  return flat
end

local Split = U.SplitDots

local CMP = { [">="] = true, [">"] = true, ["<="] = true, ["<"] = true, ["="] = true }
local NEGATE = { [">="] = "<", [">"] = "<=", ["<="] = ">", ["<"] = ">=", ["="] = "!=" }

-- Learn what must be true for `node` to have evaluated to `truth`.
local function Learn(node, truth, ctx)
  local kind = node[1]
  if kind == "un" and node[2] == "!" then
    return Learn(node[3], not truth, ctx)
  elseif kind == "bin" then
    local op = node[2]
    if op == "&" or op == "&&" then
      if truth then
        Learn(node[3], true, ctx)
        Learn(node[4], true, ctx)
      else
        local ta = E.Truth(E.Eval(node[3], ctx.resolve, ctx.bounds))
        local tb = E.Truth(E.Eval(node[4], ctx.resolve, ctx.bounds))
        if ta == true then
          Learn(node[4], false, ctx)
        elseif tb == true then
          Learn(node[3], false, ctx)
        end
      end
    elseif op == "|" or op == "||" then
      if not truth then
        Learn(node[3], false, ctx)
        Learn(node[4], false, ctx)
      else
        local ta = E.Truth(E.Eval(node[3], ctx.resolve, ctx.bounds))
        local tb = E.Truth(E.Eval(node[4], ctx.resolve, ctx.bounds))
        if ta == false then
          Learn(node[4], true, ctx)
        elseif tb == false then
          Learn(node[3], true, ctx)
        end
      end
    elseif CMP[op] and node[3][1] == "id" and node[4][1] == "num" then
      local pt = ns.State.PowerTypeOf(node[3][2])
      local name = node[3][2]
      if not pt and (name == "target.health.pct" or name == "target.distance") then
        local c = node[4][2]
        local eff = truth and op or NEGATE[op]
        if eff == ">=" or eff == ">" then
          C.SetNamed(name, c, nil, FACT_TTL, "assisted")
        elseif eff == "<=" or eff == "<" then
          C.SetNamed(name, nil, c, FACT_TTL, "assisted")
        end
      end
      if pt then
        local c = node[4][2]
        local effective = truth and op or NEGATE[op]
        if effective == ">=" then
          C.SetBound(pt, c, nil, FACT_TTL, "assisted")
        elseif effective == ">" then
          C.SetBound(pt, c + 1, nil, FACT_TTL, "assisted")
        elseif effective == "<=" then
          C.SetBound(pt, nil, c, FACT_TTL, "assisted")
        elseif effective == "<" then
          C.SetBound(pt, nil, c - 1, FACT_TTL, "assisted")
        elseif effective == "=" then
          C.SetBound(pt, c, c, FACT_TTL, "assisted")
        end
      end
    end
  elseif kind == "id" then
    local p = Split(node[2])
    local head, token, field = p[1], p[2], p[3]
    if not token then
      return
    end
    local unit
    if head == "buff" then
      unit = "player"
    elseif head == "debuff" or head == "dot" then
      unit = "target"
    end
    if unit then
      if field == nil or field == "up" or field == "react" or field == "ticking" then
        C.SetAura(unit, token, truth, FACT_TTL, "assisted")
      elseif field == "down" then
        C.SetAura(unit, token, not truth, FACT_TTL, "assisted")
      end
    end
  end
end
C.Learn = Learn

-- The assistant recommends acSpell. ctx = { resolve =, bounds =, castable = fn(id) -> true/false/UNKNOWN,
-- same = fn(id, acSpell) -> bool }. Returns the index of the rule line it matched, or nil.
function C.ObserveAssisted(record, acSpell, ctx)
  if not acSpell or not C.Enabled("assisted") then
    return nil
  end
  local lines = C.BlizzardOrder(record)
  local k
  for i, line in ipairs(lines) do
    local id = M.SpellID(line.a)
    if id and ctx.same(id, acSpell) then
      k = i
      break
    end
  end
  if not k then
    return nil
  end
  local node = lines[k].c and E.Compile(lines[k].c)
  if node then
    Learn(node, true, ctx)
  end
  for j = 1, k - 1 do
    local line = lines[j]
    local id = M.SpellID(line.a)
    if id and not ctx.same(id, acSpell) and line.c and ctx.castable(id) == true then
      local n = E.Compile(line.c)
      if n then
        Learn(n, false, ctx)
      end
    end
  end
  return k
end
