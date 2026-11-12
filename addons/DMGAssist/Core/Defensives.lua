-- Defensives.lua: when to suggest a personal defensive, and which one.
--
-- Mode (DMGAssistDB.defensiveMode, Options > Combat > Defensives): "smart" (default) = boss mod calls + low health,
-- "bossmods" = only boss mod calls, "health" = only low health, "off".
--   Boss mods: a DBM/BigWigs "defensive" alert, or an AoE / tank-hit timer (tank hits only for tanks) landing within
--   the defensive's lead (F.Lead) -> a real decision.
--   Low health: UnitHealthPercent("player") is secret in combat; a step curve at the threshold (default 35%) turns
--   it into the icon's alpha, so the game shows the defensive only while you are actually low.
-- The spell: each spec's own lists from Data/Mitigation.lua (built by tools/mitigation.py from the reference
-- profiles in data/mitigation/, checked against the game's spell data): "big" ahead of a hit, "low" at low health,
-- the first one known, off cooldown and usable, in the profile's order. F.TOKENS below is only the fallback for a
-- spec with no profile (WoW Forever).

local _, ns = ...
local U = ns.U

local F = {}
ns.Defensives = F

F.TOKENS = {
  -- druid
  "barkskin", "survival_instincts", "frenzied_regeneration", "renewal", "regrowth",
  -- death knight
  "antimagic_shell", "icebound_fortitude", "vampiric_blood", "lichborne",
  -- demon hunter
  "blur", "fiery_brand", "netherwalk", "darkness",
  -- evoker
  "obsidian_scales", "renewing_blaze",
  -- hunter
  "exhilaration", "survival_of_the_fittest", "aspect_of_the_turtle",
  -- mage
  "ice_barrier", "blazing_barrier", "prismatic_barrier", "mirror_image", "alter_time", "ice_block",
  -- monk
  "fortifying_brew", "diffuse_magic", "dampen_harm", "touch_of_karma",
  -- paladin
  "divine_protection", "shield_of_vengeance", "word_of_glory", "flash_of_light", "ardent_defender",
  "guardian_of_ancient_kings", "lay_on_hands", "divine_shield",
  -- priest
  "power_word_shield", "desperate_prayer", "vampiric_embrace", "dispersion", "fade", -- Fade last: threat only
  -- rogue
  "crimson_vial", "feint", "evasion", "cloak_of_shadows",
  -- shaman
  "astral_shift", "healing_surge",
  -- warlock
  "dark_pact", "unending_resolve",
  -- warrior
  "ignore_pain", "die_by_the_sword", "enraged_regeneration", "impending_victory", "victory_rush", "shield_wall",
  "last_stand",
}

-- Some defensives only make sense in one shape: never tell a Balance Druid to leave Moonkin Form for Bear Form's
-- Frenzied Regeneration, or a Guardian to leave Bear Form for Regrowth.
local function InBearForm()
  return U.Get(GetShapeshiftFormID) == 5 -- BEAR_FORM
end

local function Spec()
  return ns.Specs.current and ns.Specs.current.key or ""
end

F.ONLY_WHEN = {
  frenzied_regeneration = function()
    return Spec() == "druid_guardian" or InBearForm()
  end,
  survival_instincts = function()
    return Spec() == "druid_guardian" or Spec() == "druid_feral"
  end,
  regrowth = function()
    return Spec() ~= "druid_guardian" and not InBearForm()
  end,
}

-- This spec's profile (Data/Mitigation.lua), nil on WoW Forever or a spec without one.
function F.Profile()
  local info = ns.Client and ns.Client.info
  if info and info.branch and info.branch ~= "midnight" then
    return nil
  end
  local m = ns.Data and ns.Data.mitigation
  return m and m[Spec()] or nil
end

-- A profile entry's spell: SimC's data first (any language), else its ID when you know it (most defensives are in
-- no rotation list: Evasion, Death Pact... were never found by token alone).
function F.Resolve(e)
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

-- A form an entry needs: "bear" (Frenzied Regeneration), "caster" (Regrowth, which would leave Bear Form).
F.ONLY = {
  bear = function()
    return Spec() == "druid_guardian" or InBearForm()
  end,
  caster = function()
    return Spec() ~= "druid_guardian" and not InBearForm()
  end,
}

-- Every token of this spec's profile (all parts) -> its entry; the legacy list without a profile.
local specSets = {}
function F.SpecSet()
  local p = F.Profile()
  if not p then
    return nil
  end
  local key = Spec()
  local set = specSets[key]
  if not set then
    set = {}
    for _, part in ipairs({ "keep", "big", "reflect", "low", "icon" }) do
      for _, e in ipairs(p[part] or {}) do
        set[e.t] = set[e.t] or e
      end
    end
    specSets[key] = set
  end
  return set
end

-- Is this token a way of staying alive (kept out of the damage slots, for the defensive icon)? This spec's
-- profile, and the class-wide defensives list: a defensive another spec of the class uses (Protection's Shield
-- Wall for Fury, Fade for Shadow) is never a damage pick either (left out, Fury pressed Shield Wall in the
-- leveling check, 2026-11-12). Spells that are rotation for one spec and a heal for another (Death Strike) are
-- only in the profiles, so Blood keeps it.
function F.InSet(token)
  if not token then
    return false
  end
  local set = F.SpecSet()
  return (set ~= nil and set[token] ~= nil) or F.SET[token] == true
end

function F.IsHeal(token)
  local set = F.SpecSet()
  local e = set and set[token]
  if e then
    return e.heal == true
  end
  return F.HEALS[token] == true
end

-- Heals and heal-like "defensives": for when you're actually low, never ahead of a boss mod's hit (a Balance Druid
-- at full health was told to cast Regrowth for an AoE once Barkskin was on cooldown, 1.6.0.185 dungeon report).
F.HEALS = { frenzied_regeneration = true, renewal = true, regrowth = true, renewing_blaze = true,
  exhilaration = true, word_of_glory = true, flash_of_light = true, lay_on_hands = true, desperate_prayer = true,
  crimson_vial = true, healing_surge = true, dark_pact = true, impending_victory = true, victory_rush = true }

-- A defensive you cast is up until its duration ends: the hit it was for is covered, don't ask for a second one.
F.upUntil = 0

-- A heal you just cast isn't asked for again for HEAL_GRACE seconds: let it land (2026-11-12: Regrowth stayed up
-- through three casts while a golem kept hitting; in combat health is hidden, the game shows it while you're low).
F.HEAL_GRACE = 6
F.healAt = {}

local function TokenOf(id)
  local M = ns.SpellMap
  local token = M.TokenForID and M.TokenForID(id)
  if token then
    return token
  end
  for t, e in pairs(F.SpecSet() or {}) do
    if e.id == id then
      return t
    end
  end
  return nil
end

function F.OnOwnCast(id)
  local M = ns.SpellMap
  local token = TokenOf(id)
  if token and F.IsHeal(token) then
    F.healAt[token] = GetTime()
  end
  if not F.InSet(token) or F.IsHeal(token) then
    return
  end
  local set = F.SpecSet()
  local info = M.Info(id)
  local dur = (set and set[token] and set[token].dur) or (info and tonumber(info.d)) or 0
  if dur > 0 then
    F.upUntil = math.max(F.upUntil, GetTime() + dur)
  end
end

function F.Covered()
  return GetTime() < F.upUntil
end

F.stats = { shown = 0 }
F.shown = false

function F.Mode()
  return (ns.db and ns.db.defensiveMode) or "smart"
end

local function IsTank()
  local role = ns.Specs.current and ns.Specs.current.role
  return role == "TANK"
end

local function Usable(id, token, e, noHeals)
  local allowed
  if e then
    allowed = not e.only or not F.ONLY[e.only] or F.ONLY[e.only]()
  else
    allowed = not F.ONLY_WHEN[token] or F.ONLY_WHEN[token]()
  end
  local heal = F.IsHeal(token)
  local usable = id and U.Read((U.Call(C_Spell and C_Spell.IsSpellUsable, id)))
  local blocked = id and ns.Engine.BlockedWhileActive and ns.Engine.BlockedWhileActive(id)
  if heal and F.healAt[token] and GetTime() - F.healAt[token] < F.HEAL_GRACE then
    blocked = true -- just cast: give it time to land
  end
  return id and allowed and usable ~= false and not blocked and ns.State.CooldownReady(id) ~= false
    and not ns.Choices.Skip(id) and not (noHeals and heal)
end

-- First known defensive that is ready. With a profile: its "big" list ahead of a hit (noHeals), its "low" list
-- otherwise. Without one, the legacy class list (noHeals: skip the heals, for a hit that hasn't landed yet).
function F.Spell(noHeals, part)
  local p = F.Profile()
  if p then
    for _, e in ipairs(p[part or (noHeals and "big" or "low")] or {}) do
      local id = F.Resolve(e)
      if Usable(id, e.t, e, noHeals) then
        return id, e.t
      end
    end
    return nil
  end
  local M = ns.SpellMap
  for _, token in ipairs(F.TOKENS) do
    local id = M.SpellID(token)
    M.unresolved[token] = nil
    if Usable(id, token, nil, noHeals) then
      return id, token
    end
  end
  return nil
end

-- How many seconds before a boss mod's big hit to show this defensive. Two things must hold whenever you press it
-- inside the window: you need time to see it and press it (REACT, plus SETTLE for the GCD / the buff applying), and
-- the hit must still land well inside the buff (TAIL spare at the end, for timer drift and hits that tick).
--   earliest useful lead = duration - TAIL (pressed the moment it shows, the buff still covers the hit)
--   latest lead          = REACT + SETTLE (pressed REACT seconds late, it's still up before the hit)
-- We show it at the middle of that range, never less than the "Big hit warning" setting and never more than MAX_LEAD
-- (boss timers drift). A buff too short for both shows late enough to still cover the hit; a heal with no duration
-- shows at the setting.
-- Barkskin (8 s): window 2.5..6.5 -> shown 4.5 s before the hit.
F.REACT, F.SETTLE, F.TAIL, F.MAX_LEAD = 2, 0.5, 1.5, 6

function F.Lead(id, setting)
  setting = setting or 3
  local info = id and ns.SpellMap.Info(id)
  local dur = info and tonumber(info.d)
  if not dur or dur <= 0 then
    return setting
  end
  local latest, earliest = F.REACT + F.SETTLE, dur - F.TAIL
  if earliest < latest then
    return math.min(setting, math.max(earliest, F.SETTLE))
  end
  local lead = math.max((latest + earliest) / 2, setting)
  return math.min(lead, earliest, F.MAX_LEAD)
end

-- nil, or { id =, how = "decided" | "render", why =, threshold = }
function F.Evaluate()
  local mode = F.Mode()
  if mode == "off" then
    return nil
  end
  local tank = ns.Tanks and ns.Tanks.Profile()
  local id = (tank and ns.Tanks.LowSpell()) or F.Spell()
  if not id then
    return nil
  end
  local B = ns.BossMods
  local pre = id -- ahead of a hit: a real defensive, not a heal (tanks: their own profile's choice)
  if not tank then
    pre = F.Spell(true)
  end
  if mode ~= "health" and pre and not F.Covered() then
    local lead = F.Lead(pre, tonumber(ns.db and ns.db.defensiveLead) or 3)
    if B.Alert("defensive") then
      return { id = pre, how = "decided", why = "bossmod" }
    end
    local aoe = B.NextHit("aoe")
    local hit = IsTank() and B.NextHit("role") or nil
    if (aoe and aoe <= lead) or (hit and hit <= lead) then
      return { id = pre, how = "decided", why = aoe and "aoe" or "tankhit" }
    end
  end
  if mode ~= "bossmods" then
    -- tanks: their own threshold per spec (Combat > Tanks, 50% by default), DPS: Combat > Defensives
    local prof = F.Profile()
    local threshold = (tank and ns.Tanks.Health() or tonumber(ns.db and ns.db.defensiveHealth)
      or (prof and prof.health) or 35) / 100
    local hp, max = U.Get(UnitHealth, "player"), U.Get(UnitHealthMax, "player")
    if type(hp) == "number" and type(max) == "number" and max > 0 then
      if hp / max <= threshold then
        return { id = id, how = "decided", why = "health" }
      end
      return nil
    end
    return { id = id, how = "render", why = "health", threshold = threshold }
  end
  return nil
end

-- Every way of staying alive has one place: the red-edged icon on slot 1 (top-left by default), for every class and
-- role, so slots 1-3 are only ever your damage rotation. In that icon, most urgent first:
--   a defensive decided now (boss mod hit coming, or low health we can read) - pulses while it's needed;
--   a self-heal / defensive the rotation itself picked (Frenzied Regeneration, Word of Glory, Crimson Vial...);
--   upkeep (Ironfur stacks, from Essentials) - a steady edge.
-- The low-health defensive we can't read (secret health) is drawn on top of it by the HUD, made visible by the
-- game only while you are low.
F.SET = {}
for _, t in ipairs(F.TOKENS) do
  F.SET[t] = true
end

local function IsDefensive(p)
  -- A keep-up's pick is there for its own reason: Discipline's Shield for Atonement (the ramp, healing support)
  -- isn't a defensive, though Shield is one on the priest list (moving it out broke the ramp, 1.6.0.168).
  if not (p and p.id) or p.source == "interrupt" or p.source == "keepup" or p.item then
    return false
  end
  local t = p.token or TokenOf(p.id)
  return F.InSet(t)
end
F.IsDefensive = IsDefensive

-- Rotation picks that are really about surviving leave the slots for the defensive icon.
local function OutOfQueue(result)
  local queue, found = {}, nil
  for _, p in ipairs(result.queue or {}) do
    if IsDefensive(p) then
      found = found or p
    else
      queue[#queue + 1] = p
    end
  end
  if found then
    result.queue, result.main = queue, queue[1] or result.main
    if result.main == found then
      result.main = nil
    end
  end
  return found
end

function F.Apply(result)
  local d = F.Evaluate()
  result.defensive = d
  if d and ns.Engine.IsHeld(d.id) then
    d = nil -- skipped three times this fight: held until it ends or you cast it
    result.defensive = nil
  end
  local fromList = OutOfQueue(result)
  local tankPick = ns.Tanks and ns.Tanks.Pick()
  result.mitigation = tankPick
  if d and d.how == "decided" and not (ns.Display and ns.Display.Settings().defensive == false) then
    result.weave = { id = d.id, token = "defensive", source = "defensive", urgent = true }
  elseif tankPick then
    result.weave = tankPick
  elseif fromList then
    result.weave = { id = fromList.id, token = fromList.token, source = "defensive" }
  end
  if d and d.how == "decided" and not F.shown then
    F.shown = true
    F.stats.shown = F.stats.shown + 1
    U.Log("defensive_shown", { why = d.why, spell = d.id })
    if ns.Sounds then
      ns.Sounds.Play("defensive")
    end
  elseif not (d and d.how == "decided") then
    F.shown = false
  end
  return d
end
