-- Tanks.lua: how each tank spec tanks, alongside SimC (decided 2026-11-09).
--
-- For a tank the three slots are the damage rotation only. Everything that keeps you alive goes in the red-edged
-- defensive icon on slot 1, chosen here, most urgent first:
--   big      a boss mod says a tank hit or raid-wide damage lands within the warning time (Combat > Defensives)
--            -> the first ready cooldown of the list, pulsing;
--   reflect  a boss mod times a spell at you ("targeted") -> Spell Reflection, Anti-Magic Shell, Diffuse Magic;
--   keep     while you are tanking (aggro: State.Unhurt), the keep-up buttons when they are due: Shield Block,
--            Demon Spikes, Shield of the Righteous, Purifying Brew... timed from your own casts (buffs are hidden
--            in combat), steady edge;
--   low      emergencies at low health (tanks: 50% by default, per spec, Combat > Tanks) - drawn by Defensives,
--            made visible by the game while you are low.
-- Every spell named here is left out of slots 1-3 for that spec (Engine), so SimC's own mitigation lines never
-- crowd the damage rotation. Profiles follow the class guides (Method, Wowhead, Icy Veins) and SimC's tank lists;
-- entries name a SimC token and the spell ID (some aren't in SimC's lists: Spell Reflection, Rune Tap...).
-- Keep-up fields: dur = how long its effect lasts (s), refresh = due this long before it ends, stagger = only
-- with Stagger, ragePool = a resource dump (Ignore Pain: due when that much rage is readable, or every few s).

local _, ns = ...
local U = ns.U

local T = {}
ns.Tanks = T

T.HEALTH = 50 -- default low-health threshold for tanks (DPS stay at Combat > Defensives > Low health)

-- Each tank's profile comes from Data/Mitigation.lua (tools/mitigation.py: the reference profiles in
-- data/mitigation/<branch>/<spec>.txt, every spell checked against the game's own spell data), in this shape:
--   keep, big, reflect, low = lists of { t = token, id = spell ID, dur, refresh, stagger, ragePool, ... }
--   alsoIcon = tokens kept out of the damage slots, cappedHeal = { id, health }
local converted = {}
local function FromData(spec)
  local m = ns.Data and ns.Data.mitigation and ns.Data.mitigation[spec]
  if not (m and m.role == "tank") then
    return nil
  end
  local p = converted[spec]
  if p and p.src == m then
    return p
  end
  p = { src = m, keep = m.keep or {}, big = m.big or {}, reflect = m.reflect or {}, low = m.low or {},
    alsoIcon = {}, health = m.health }
  for _, e in ipairs(m.icon or {}) do
    p.alsoIcon[#p.alsoIcon + 1] = e.t
  end
  if m.capped then
    p.cappedHeal = { id = m.capped.id, health = m.capped.health }
  end
  converted[spec] = p
  return p
end

-- T.PROFILES[spec]: read through to the data (kept as a table for the tests and the options).
T.PROFILES = setmetatable({}, { __index = function(_, spec)
  return FromData(spec)
end })

local function Spec()
  return ns.Specs.current and ns.Specs.current.key or ""
end

function T.Enabled()
  return not (ns.db and ns.db.tankProfile == false)
end

function T.Profile()
  if not T.Enabled() then
    return nil
  end
  local info = ns.Client and ns.Client.info
  if info and info.branch ~= "midnight" then
    return nil -- WoW Forever tanks with other spells and rules: its lists decide there
  end
  return T.PROFILES[Spec()]
end

-- Every token a profile uses, per spec (left out of the damage slots).
local sets = {}
local function Set(spec)
  local s = sets[spec]
  if s then
    return s
  end
  s = {}
  local p = T.PROFILES[spec]
  for _, part in ipairs({ "keep", "big", "reflect", "low" }) do
    for _, e in ipairs(p and p[part] or {}) do
      s[e.t] = true
    end
  end
  for _, t in ipairs(p and p.alsoIcon or {}) do
    s[t] = true
  end
  sets[spec] = s
  return s
end

-- Is this SimC token one of the current tank's mitigation buttons (shown in the defensive icon, not the slots)?
function T.InIcon(token)
  return T.Profile() ~= nil and token ~= nil and Set(Spec())[token] == true
end

-- The spell for an entry: SimC's data first (any language), else the ID if you know it.
local function Resolve(e)
  return ns.Defensives.Resolve(e)
end

local function Ready(id)
  if ns.Choices.Skip(id) or ns.Engine.IsHeld(id) then
    return false
  end
  local usable = U.Read((U.Call(C_Spell and C_Spell.IsSpellUsable, id)))
  if usable == false then
    return false
  end
  return ns.State.CooldownReady(id) ~= false
end

local function First(list)
  local F = ns.Defensives
  for _, e in ipairs(list or {}) do
    local id = Resolve(e)
    if id and Ready(id) and not (e.only and F.ONLY[e.only] and not F.ONLY[e.only]())
      and not (e.heal and F.healAt[e.t] and GetTime() - F.healAt[e.t] < F.HEAL_GRACE) then
      return id, e.t
    end
  end
  return nil
end

-- The first ready emergency button (for Defensives' low-health alert), nil when there's none.
function T.LowSpell()
  local p = T.Profile()
  if not p then
    return nil
  end
  return First(p.low)
end

function T.Health()
  local spec = Spec()
  local by = ns.db and type(ns.db.tankHealth) == "table" and ns.db.tankHealth
  local prof = T.Profile()
  local base = tonumber(by and by[spec]) or (prof and prof.health) or T.HEALTH
  -- the low-health heal with all its charges full: a higher threshold, so a charge isn't left capped
  local p = T.Profile()
  local c = p and p.cappedHeal
  if c and T.LowSpell() == c.id then
    local S = ns.State
    local n, max = S.Charges(c.id), S.MaxCharges(c.id)
    if type(n) == "number" and type(max) == "number" and max >= 2 and n >= max then
      return math.max(base, c.health)
    end
  end
  return base
end

-- A keep-up button is due: it was never cast this fight, or its effect ends within `refresh`.
local function Due(e, id)
  local S = ns.State
  if e.stagger then
    local st = S.Stagger()
    if st == nil or st <= 0 then
      return false
    end
  end
  local since = S.SinceCast(id)
  if e.capped then
    local c, max = S.Charges(id), S.MaxCharges(id)
    return type(c) == "number" and type(max) == "number" and max >= 2 and c >= max
      and (since == nil or since >= (e.dur or 0))
  end
  if e.ragePool then
    local rage = S.PowerNow(1)
    if type(rage) == "number" then
      return rage >= e.ragePool and (since == nil or since >= 1)
    end
    return since == nil or since >= (e.dur or 4) + 2
  end
  return since == nil or since >= (e.dur or 0) - (e.refresh or 0)
end

-- nil, or the pick for the defensive icon: { id, token, source = "mitigation", why, urgent }
function T.Pick()
  local p = T.Profile()
  if not p or not ns.State.combatStart then
    return nil
  end
  local B = ns.BossMods
  local lead = tonumber(ns.db and ns.db.defensiveLead) or 3
  local hit, aoe = B.Next("role"), B.Next("aoe")
  if B.Alert("defensive") or (hit and hit <= lead) or (aoe and aoe <= lead) then
    local id, token = First(p.big)
    if id then
      return { id = id, token = token, source = "mitigation", why = "big", urgent = true }
    end
  end
  local spell = B.Next("targeted")
  if spell and spell <= lead then
    local id, token = First(p.reflect)
    if id then
      return { id = id, token = token, source = "mitigation", why = "reflect", urgent = true }
    end
  end
  if ns.State.Unhurt() == false then -- holding aggro, or taking damage
    for _, e in ipairs(p.keep) do
      local id = Resolve(e)
      if id and Ready(id) and Due(e, id) then
        return { id = id, token = e.t, source = "mitigation", why = "keep" }
      end
    end
  end
  return nil
end
