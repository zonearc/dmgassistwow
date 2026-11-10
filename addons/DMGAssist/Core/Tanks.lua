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

T.PROFILES = {
  warrior_protection = {
    keep = {
      { t = "shield_block", id = 2565, dur = 6, refresh = 1 },
      { t = "ignore_pain", id = 190456, dur = 4, refresh = 0, ragePool = 60 },
    },
    big = { { t = "demoralizing_shout", id = 1160 }, { t = "shield_wall", id = 871 }, { t = "last_stand", id = 12975 } },
    reflect = { { t = "spell_reflection", id = 23920 } },
    low = { { t = "last_stand", id = 12975 }, { t = "shield_wall", id = 871 }, { t = "impending_victory", id = 202168 } },
  },
  druid_guardian = {
    keep = {}, -- Ironfur stacks: Essentials (counted from your casts)
    big = { { t = "barkskin", id = 22812 }, { t = "rage_of_the_sleeper", id = 200851 },
      { t = "survival_instincts", id = 61336 } },
    reflect = {},
    low = { { t = "frenzied_regeneration", id = 22842 }, { t = "survival_instincts", id = 61336 },
      { t = "barkskin", id = 22812 } },
    alsoIcon = { "ironfur" },
  },
  deathknight_blood = {
    keep = {},
    big = { { t = "vampiric_blood", id = 55233 }, { t = "rune_tap", id = 194679 },
      { t = "icebound_fortitude", id = 48792 } },
    reflect = { { t = "antimagic_shell", id = 48707 } },
    low = { { t = "vampiric_blood", id = 55233 }, { t = "icebound_fortitude", id = 48792 },
      { t = "rune_tap", id = 194679 } },
  },
  demonhunter_vengeance = {
    keep = { { t = "demon_spikes", id = 203720, dur = 8, refresh = 1 } },
    big = { { t = "fiery_brand", id = 204021 }, { t = "demon_spikes", id = 203720 } },
    reflect = {},
    low = { { t = "fiery_brand", id = 204021 } },
  },
  monk_brewmaster = {
    keep = {
      { t = "purifying_brew", id = 119582, dur = 4, refresh = 0, stagger = true },
      { t = "celestial_brew", id = 322507, dur = 8, refresh = 0 },
    },
    big = { { t = "fortifying_brew", id = 115203 }, { t = "dampen_harm", id = 122278 } },
    reflect = { { t = "diffuse_magic", id = 122783 } },
    low = { { t = "fortifying_brew", id = 115203 }, { t = "celestial_brew", id = 322507 } },
  },
  paladin_protection = {
    keep = { { t = "shield_of_the_righteous", id = 53600, dur = 4.5, refresh = 1 } },
    big = { { t = "eye_of_tyr", id = 387174 }, { t = "ardent_defender", id = 31850 },
      { t = "guardian_of_ancient_kings", id = 86659 }, { t = "divine_protection", id = 498 } },
    reflect = {},
    low = { { t = "word_of_glory", id = 85673 }, { t = "ardent_defender", id = 31850 },
      { t = "lay_on_hands", id = 633 }, { t = "divine_shield", id = 642 } },
  },
}

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
  local M = ns.SpellMap
  local id = M.SpellID(e.t)
  M.unresolved[e.t] = nil
  if id then
    return id
  end
  if e.id and (U.Get(IsPlayerSpell, e.id) == true or (M.book and M.book[e.id])) then
    return e.id
  end
  return nil
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
  for _, e in ipairs(list or {}) do
    local id = Resolve(e)
    if id and Ready(id) then
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
  return tonumber(by and by[spec]) or T.HEALTH
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
