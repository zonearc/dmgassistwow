-- Defensives.lua: when to suggest a personal defensive, and which one.
--
-- Mode (DMGAssistDB.defensiveMode, Options > Combat > Defensives): "smart" (default) = boss mod calls + low health,
-- "bossmods" = only boss mod calls, "health" = only low health, "off".
--   Boss mods: a DBM/BigWigs "defensive" alert, or an AoE / tank-hit timer (tank hits only for tanks) landing within
--   defensiveLead seconds (default 3) -> a real decision.
--   Low health: UnitHealthPercent("player") is secret in combat; a step curve at the threshold (default 35%) turns
--   it into the icon's alpha, so the game shows the defensive only while you are actually low.
-- The spell: the first defensive the player knows that is off cooldown and usable now, in the order below (lighter
-- first, so the big ones stay for emergencies; self-heals such as Word of Glory or Healing Surge after the light
-- ones), matched by spell ID from SimC's data (any client language).

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

F.stats = { shown = 0 }
F.shown = false

function F.Mode()
  return (ns.db and ns.db.defensiveMode) or "smart"
end

local function IsTank()
  local role = ns.Specs.current and ns.Specs.current.role
  return role == "TANK"
end

-- First known defensive that is ready.
function F.Spell()
  local M = ns.SpellMap
  for _, token in ipairs(F.TOKENS) do
    local id = M.SpellID(token)
    M.unresolved[token] = nil
    local allowed = not F.ONLY_WHEN[token] or F.ONLY_WHEN[token]()
    local usable = id and U.Read((U.Call(C_Spell and C_Spell.IsSpellUsable, id)))
    local blocked = id and ns.Engine.BlockedWhileActive and ns.Engine.BlockedWhileActive(id)
    if id and allowed and usable ~= false and not blocked and ns.State.CooldownReady(id) ~= false
      and not ns.Choices.IsHidden(id) then
      return id, token
    end
  end
  return nil
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
  local lead = tonumber(ns.db and ns.db.defensiveLead) or 3
  if mode ~= "health" then
    if B.Alert("defensive") then
      return { id = id, how = "decided", why = "bossmod" }
    end
    local aoe = B.Next("aoe")
    local hit = IsTank() and B.Next("role") or nil
    if (aoe and aoe <= lead) or (hit and hit <= lead) then
      return { id = id, how = "decided", why = aoe and "aoe" or "tankhit" }
    end
  end
  if mode ~= "bossmods" then
    -- tanks: their own threshold per spec (Combat > Tanks, 50% by default), DPS: Combat > Defensives
    local threshold = (tank and ns.Tanks.Health() or tonumber(ns.db and ns.db.defensiveHealth) or 35) / 100
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
  if not (p and p.id) or p.source == "interrupt" or p.item then
    return false
  end
  local t = p.token or (ns.SpellMap.TokenForID and ns.SpellMap.TokenForID(p.id))
  return t ~= nil and F.SET[t] == true
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
