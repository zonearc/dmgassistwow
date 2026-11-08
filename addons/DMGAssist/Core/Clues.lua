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
  C.stats = {}
  C.links = links or {}
  C.lastGlow, C.lastNewAura = nil, nil
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
-- Proc glows
---------------------------------------------------------------------------
local function Link(spellID, token)
  if C.links[spellID] ~= token then
    C.links[spellID] = token
    U.Log("glow_link", { spell = spellID, aura = token })
  end
end

-- Glow shown/hidden on spellID. aurasReadable: whether the player's auras can be read right now.
function C.OnGlow(spellID, shown, aurasReadable)
  local now = GetTime()
  if shown then
    C.lastGlow = { id = spellID, t = now }
    local n = C.lastNewAura
    if aurasReadable and n and now - n.t <= LINK_WINDOW then
      Link(spellID, n.token)
    end
  end
  local token = C.links[spellID]
  if token then
    if shown then
      C.SetAura("player", token, true, 30, "glow")
    else
      C.SetAura("player", token, false, 1.0, "glow")
    end
  end
end

-- A new aura appeared on the player (readable scan).
function C.OnNewAura(token)
  local now = GetTime()
  C.lastNewAura = { token = token, t = now }
  local g = C.lastGlow
  if g and now - g.t <= LINK_WINDOW then
    Link(g.id, token)
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
      local cost = info and info.cost
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

local function Split(name)
  local p = {}
  for part in name:gmatch("[^%.]+") do
    p[#p + 1] = part
  end
  return p
end

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
