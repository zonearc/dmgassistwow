-- Defensives.lua: when to suggest a personal defensive, and which one.
--
-- Mode (DMGAssistDB.defensiveMode, Options > Combat > Defensives): "smart" (default) = boss mod calls + low health,
-- "bossmods" = only boss mod calls, "health" = only low health, "off".
--   Boss mods: a DBM/BigWigs "defensive" alert, or an AoE / tank-hit timer (tank hits only for tanks) landing within
--   defensiveLead seconds (default 3) -> a real decision.
--   Low health: UnitHealthPercent("player") is secret in combat; a step curve at the threshold (default 35%) turns
--   it into the icon's alpha, so the game shows the defensive only while you are actually low.
-- The spell: the first defensive the player knows that is off cooldown, in the order below (lighter first, so the
-- big ones stay for emergencies), matched by spell ID from SimC's data (any client language).

local _, ns = ...
local U = ns.U

local F = {}
ns.Defensives = F

F.TOKENS = {
  -- druid
  "barkskin", "survival_instincts", "frenzied_regeneration", "renewal",
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
  "divine_protection", "shield_of_vengeance", "ardent_defender", "guardian_of_ancient_kings", "divine_shield",
  -- priest
  "desperate_prayer", "dispersion", "fade",
  -- rogue
  "crimson_vial", "feint", "evasion", "cloak_of_shadows",
  -- shaman
  "astral_shift",
  -- warlock
  "dark_pact", "unending_resolve",
  -- warrior
  "ignore_pain", "die_by_the_sword", "enraged_regeneration", "shield_wall", "last_stand",
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
    if id and ns.State.CooldownReady(id) ~= false and not ns.Choices.IsHidden(id) then
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
  local id = F.Spell()
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
    local threshold = (tonumber(ns.db and ns.db.defensiveHealth) or 35) / 100
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

-- A decided defensive goes into the queue: slot 1, or slot 2 behind a decided interrupt; the rest shifts right.
-- (One that depends on hidden health is drawn over slot 1 by the HUD instead, visible only when low.)
local function IntoQueue(result, d)
  local def = { id = d.id, token = "defensive", source = "defensive" }
  local queue, placed = {}, false
  for _, p in ipairs(result.queue or {}) do
    if not placed and p.source ~= "interrupt" then
      queue[#queue + 1] = def
      placed = true
    end
    queue[#queue + 1] = p
  end
  if not placed then
    queue[#queue + 1] = def
  end
  while #queue > 3 do
    queue[#queue] = nil
  end
  result.queue, result.main = queue, queue[1]
  result.branch = nil
end

function F.Apply(result)
  local d = F.Evaluate()
  result.defensive = d
  if d and ns.Engine.IsHeld(d.id) then
    d = nil -- skipped three times this fight: held until it ends or you cast it
    result.defensive = nil
  end
  if d and d.how == "decided" and not (ns.Display and ns.Display.Settings().defensive == false) then
    IntoQueue(result, d)
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
