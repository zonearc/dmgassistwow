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
  -- Auto Shot runs by itself (a hunter's auto attack); Bloodlust and its twins are the group's call (Sated), not
  -- the rotation's: found by tests/test_scenarios.lua, 2026-11-10.
  auto_shot = true, bloodlust = true, heroism = true, time_warp = true, primal_rage = true,
  fury_of_the_aspects = true,
}

-- Interrupts: SimC only fires these while the target casts something interruptible, which the lists leave to
-- the simulator. Read as ordinary lines they would sit in slot 1 whenever off cooldown; the Interrupts module
-- shows them when a cast is really on.
for _, token in ipairs({
  "muzzle", "counter_shot", "kick", "pummel", "mind_freeze", "rebuke", "wind_shear", "spell_lock", "skull_bash",
  "solar_beam", "counterspell", "silence", "disrupt", "quell", "spear_hand_strike", "axe_toss", "optical_blast",
}) do
  G.SKIP[token] = true
end

-- Movement: SimC's charge / leap lines test time<=0.5 or a movement distance it simulates, so they read as
-- "now" out of combat and in melee. Essentials.GapCloser shows these only when the target is out of melee range
-- and within the spell's own range.
for _, token in ipairs({ "charge", "heroic_leap", "wild_charge", "harpoon", "shadowstep", "feral_lunge",
  "intervene" }) do
  G.SKIP[token] = true
end

local STOP = {}

-- Does this list (or a list it calls) hold anything we can recommend? Cached per list table.
local hasActions = setmetatable({}, { __mode = "k" })
function G.HasActions(lists, name, seen)
  local list = name and lists and lists[name]
  if type(list) ~= "table" then
    return false
  end
  if hasActions[list] ~= nil then
    return hasActions[list]
  end
  seen = seen or {}
  if seen[name] then
    return false
  end
  seen[name] = true
  local found = false
  for _, e in ipairs(list) do
    local a = e.a
    if a == "call_action_list" or a == "run_action_list" then
      found = G.HasActions(lists, e.p and e.p.name, seen)
    elseif a and not G.SKIP[a] then
      found = true
    end
    if found then
      break
    end
  end
  hasActions[list] = found
  return found
end
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

G.castSerial = 0
function G.OnOwnCast()
  G.castSerial = G.castSerial + 1
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
-- Spells the game reports usable whatever the target, that only work on some targets.
-- Touch of Death: only on a target with less health than your maximum; the button glows when it can be used.
-- Damage-reduction spells SimC casts on cooldown because its fights always have a boss hitting the tank. With
-- nothing hurting the player (a dummy, between pulls) they are skipped. Purifying Brew only clears Stagger, so it
-- needs Stagger when the game shows it.
G.WHEN_HURT = {
  purifying_brew = "stagger", celestial_brew = true, fortifying_brew = true, black_ox_brew = "stagger",
  shield_block = true, demon_spikes = true, ignore_pain = true, rune_tap = true, survival_instincts = true,
  barkskin = true, frenzied_regeneration = true, ardent_defender = true, guardian_of_ancient_kings = true,
  shield_wall = true, last_stand = true, icebound_fortitude = true, vampiric_blood = true, fiery_brand = true,
  word_of_glory = "hurt", expel_harm = "hurt", healing_elixir = "hurt", dampen_harm = true,
  -- self-heals and personal defensives any spec's list may carry
  regrowth = "hurt", rejuvenation = "hurt", flash_heal = "hurt", holy_light = "hurt", flash_of_light = "hurt",
  desperate_prayer = "hurt", vampiric_embrace = "hurt", dispersion = true, power_word_shield = "hurt",
  crimson_vial = "hurt", renewal = "hurt", exhilaration = "hurt", dark_pact = "hurt", mortal_coil = "hurt",
  impending_victory = "hurt", victory_rush = "hurt", healing_surge = "hurt", astral_shift = true,
}

G.TANK_SPECS = { deathknight_blood = true, demonhunter_vengeance = true, druid_guardian = true,
  monk_brewmaster = true, paladin_protection = true, warrior_protection = true }

-- Spells that are part of a spec's damage rotation there, not heals (Feral's Regrowth feeds Bloodtalons).
G.NOT_A_HEAL = { regrowth = { druid_feral = true } }

-- Self-heals ("hurt" rules): only at or below the player's threshold (Combat > Self-heals, default 35 %), never in
-- raids unless switched on (healing there is the healers' job). Hidden health counts as "not low": a heal is only
-- suggested when the game shows we need it.
local function InRaid()
  local inside, kind = U.Call(IsInInstance)
  return U.Read(inside) == true and U.Read(kind) == "raid"
end

local function HealAllowed()
  local db = ns.db or {}
  local at = tonumber(db.healAt) or 35
  if at <= 0 then
    return false
  end
  local spec = ns.Specs.current and ns.Specs.current.key or ""
  if InRaid() and db.healInRaids ~= true and not G.TANK_SPECS[spec] then -- tanks heal themselves in raids too
    return false
  end
  local hp, max = U.Get(UnitHealth, "player"), U.Get(UnitHealthMax, "player")
  if type(hp) ~= "number" or type(max) ~= "number" or max <= 0 then
    return false
  end
  return hp / max * 100 <= at
end
G.HealAllowed = HealAllowed

local function NotHurtSkip(token)
  local rule = G.WHEN_HURT[token]
  if not rule then
    return false
  end
  local spec = ns.Specs.current and ns.Specs.current.key
  if G.NOT_A_HEAL[token] and G.NOT_A_HEAL[token][spec or ""] then
    return false
  end
  if rule == "hurt" then
    return not HealAllowed()
  end
  if rule == "stagger" then
    local st = S.Stagger()
    if st ~= nil then
      return st <= 0
    end
  end
  return S.Unhurt() == true
end
G.NotHurtSkip = NotHurtSkip

G.TARGET_RULES = {
  [322109] = function(id)
    local hp, maxHp = U.Get(UnitHealth, "target"), U.Get(UnitHealthMax, "player")
    if type(hp) == "number" and type(maxHp) == "number" and hp > 0 then
      return hp <= maxHp or S.glow[id] == true
    end
    return S.glow[id] == true
  end,
  -- Black Arrow (Dark Ranger): only on enemies above 80% or below 20% health (effects #3 / #2 of 466930), or with
  -- Deathblow (it lights the button). It was shown on a dummy at 50% and couldn't be pressed (BM, 2026-11-12).
  -- Health unreadable: only when the game lights it or Blizzard's assistant names it.
  [466930] = function(id)
    if S.glow[id] == true then
      return true
    end
    local hp, maxHp = U.Get(UnitHealth, "target"), U.Get(UnitHealthMax, "target")
    if type(hp) == "number" and type(maxHp) == "number" and maxHp > 0 and hp > 0 then
      local pct = hp / maxHp * 100
      return pct <= 20 or pct >= 80
    end
    return G.acNow == id
  end,
}

-- Spells the game won't cast while an effect runs ("A more powerful spell is already active"), even with a charge
-- left or a cooldown shorter than the effect. SimC knows these inside its simulation (each is a ready() override
-- in its class code, audited 2026-11-09: 93 overrides, these are the ones a charge or short cooldown would let
-- through); the lists don't say it, and in combat the buffs are hidden from addons, so it's timed from our own casts.
-- token -> { trigger token = seconds }
G.BLOCKED_WHILE_ACTIVE = {
  -- Balance: Eclipse 15 s after Eclipse, Celestial Alignment, or Incarnation (20 s)
  eclipse = { eclipse = 15, lunar_eclipse = 15, solar_eclipse = 15, celestial_alignment = 15,
    incarnation_chosen_of_elune = 20 },
  -- Subtlety: no Shadow Dance during Shadow Dance (8 s, charges) or right after Vanish (3 s of stealth)
  shadow_dance = { shadow_dance = 8, vanish = 3 },
  -- Paladin: Forbearance (30 s) after Divine Shield, Blessing of Protection or Lay on Hands
  divine_shield = { divine_shield = 30, blessing_of_protection = 30, lay_on_hands = 30 },
  blessing_of_protection = { divine_shield = 30, blessing_of_protection = 30, lay_on_hands = 30 },
  lay_on_hands = { divine_shield = 30, blessing_of_protection = 30, lay_on_hands = 30 },
  -- Shadow: no Vampiric Embrace while it runs (15 s)
  vampiric_embrace = { vampiric_embrace = 15 },
}
-- The Eclipse button is Lunar or Solar Eclipse in game (its spell ID names the form): same rule. Without these
-- Eclipse was offered during Incarnation, the game refused it, and slot 1 flipped Eclipse / Starfall every
-- second (2026-11-10).
G.BLOCKED_WHILE_ACTIVE.lunar_eclipse = G.BLOCKED_WHILE_ACTIVE.eclipse
G.BLOCKED_WHILE_ACTIVE.solar_eclipse = G.BLOCKED_WHILE_ACTIVE.eclipse

local function BlockedWhileActive(id)
  local base = (M.baseOf and M.baseOf[id]) or id
  local rule
  for _, t in ipairs(M.TokenForID and { M.TokenForID(base) or false, M.TokenForID(id) or false } or {}) do
    rule = rule or (t and G.BLOCKED_WHILE_ACTIVE[t])
  end
  if not rule then
    return false
  end
  local now = GetTime()
  for trigger, duration in pairs(rule) do
    -- any cast still inside its duration, even from the last pull: the effect outlives combat (dummies drop combat
    -- between pulls; Eclipse was offered 5 s after Incarnation from the pull before, 2026-11-12)
    local at = S.lastCastToken[trigger]
    if at and now - at < duration then
      return true
    end
    local tid = M.SpellID(trigger)
    M.unresolved[trigger] = nil
    local since = tid and S.SinceCast(tid)
    local last = tid and S.lastCast[tid]
    if (since and since < duration) or (last and now - last < duration) then
      return true -- includes a cast predicted earlier in this look-ahead
    end
  end
  return false
end
G.BlockedWhileActive = BlockedWhileActive

-- Placeholders the assistant names instead of a spell (2026-11-10: "Waiting for Energy", 1249752, for Feral).
-- Known ones by ID (any client language); anything else it names that isn't in the spellbook, isn't a spell
-- the player knows and has no SimC data is treated the same, and logged once so reports show what else exists.
G.PLACEHOLDERS = { [1249752] = "energy" }
G.placeholderSeen = {}
function G.IsAssistantPlaceholder(id)
  if G.PLACEHOLDERS[id] then
    return true
  end
  if (M.book and M.book[id]) or M.Info(id) or (M.baseOf and M.baseOf[id]) then
    return false
  end
  if U.Get(IsPlayerSpell, id) == true or U.Get(C_Spell and C_Spell.GetOverrideSpell, id) ~= id then
    return false
  end
  return M.TokenForID(id) ~= nil and (M.TokenForID(id) or ""):find("^waiting") ~= nil
end

-- Nothing is affordable: the spec's main resource is below the cheapest spender of it. A ceiling for a moment.
function G.OnAssistantWait(id)
  if not G.placeholderSeen[id] then
    G.placeholderSeen[id] = true
    U.Log("assistant_placeholder", { id = id, name = M.TokenForID(id) })
  end
  local pt = U.Get(UnitPowerType, "player")
  if type(pt) ~= "number" then
    return
  end
  local cheapest
  for bid, b in pairs(M.book or {}) do
    if b.id == bid and not b.passive and not S.glow[bid] then
      local cost = M.Cost(M.Info(bid))
      local amount = cost and cost[pt]
      if amount and amount > 0 and (not cheapest or amount < cheapest) then
        cheapest = amount
      end
    end
  end
  if not cheapest then -- no spellbook scan yet: the spec's own data
    for _, info in pairs(M.info or {}) do
      local cost = M.Cost(info)
      local amount = cost and cost[pt]
      if amount and amount > 0 and not info.cmax and (not cheapest or amount < cheapest) then
        cheapest = amount
      end
    end
  end
  if cheapest and ns.Clues and ns.Clues.SetBound then
    ns.Clues.CapFloor(pt, cheapest - 1)
    ns.Clues.SetBound(pt, nil, cheapest - 1, 0.6, "wait")
  end
end

-- The upper end of what we know about a hidden resource is below this spell's cost.
function G.BelowCost(id)
  local cost = M.Cost(M.Info(id))
  if not cost then
    return false
  end
  for pt, amount in pairs(cost) do
    if amount > 0 and type(U.Get(UnitPower, "player", pt)) ~= "number" then
      local lo, hi = ns.Clues.ResourceBounds(pt)
      if lo and hi and hi < amount then
        return true
      end
    end
  end
  return false
end

-- Slots 2-3: the hidden resource's range after the casts we pretend (S.PowerBounds) is below the cost.
function G.BelowCostAhead(id)
  local cost = M.Cost(M.Info(id))
  if not cost then
    return false
  end
  for pt, amount in pairs(cost) do
    if amount > 0 and type(U.Get(UnitPower, "player", pt)) ~= "number" then
      local lo, hi = S.PowerBounds(pt)
      if hi and hi < amount then
        return true
      end
      -- A pretend cast already spent from this hidden pool: only promise another spender we know is affordable
      -- (Balance in AoE, 2026-11-11: "Starfall > Starfall" from Astral Power known only as "34 or more"; following
      -- slot 2 ran you dry).
      local V = S.Lookahead()
      if lo and lo < amount and V and V.power and (V.power[pt] or 0) < 0 then
        return true
      end
    end
  end
  return false
end

-- Is Blizzard's assistant naming a rotation spell right now (so its silence about a spell means "not yet")?
-- The assistant names one spell at a time. If it keeps naming the same one for G.FIXATED seconds and you don't cast
-- it, it can't name anything else meanwhile: spells left to it ("Blizzard decides") would never come back. Balance,
-- 2026-11-10: it named Sunfire for 45 s and Fury of Elune sat ready the whole time. Our own clock decides then.
G.FIXATED = 6
function G.AssistantHealthy()
  return not G.acStuck and not G.acFixated
end

function G.NoteAssistant(ac)
  local now = S.Now()
  if type(ac) ~= "number" then
    G.acName, G.acNamedAt, G.acFixated = nil, nil, false
    return
  end
  if ac ~= G.acName or not G.acNamedAt then
    G.acName, G.acNamedAt = ac, now
  end
  local since = S.SinceCast and S.SinceCast(ac)
  if type(since) == "number" and now - since > G.acNamedAt then
    G.acNamedAt = now - since -- cast since it was first named: it is naming the next one
  end
  G.acFixated = now - G.acNamedAt > G.FIXATED
end

-- The game calls a combo point finisher "not usable" (no reason given) while our combo point read says it can be
-- spent: trust the points. Outlaw showed 7 combo points for a whole fight with Dispatch and Between the Eyes
-- "not castable" and nothing but builders shown (2026-11-09). Only for spells that spend combo points, only with at
-- least one point read, and the cooldown clock still decides.
-- The same holds for the other hidden spender resources (Holy Power, Soul Shards, Chi, Runic Power...): checked
-- ahead of play on every spec, 2026-11-09.
function G.FinisherBlockedByHiddenPoints(id)
  local info = M.Info(id)
  if not info then
    return false
  end
  local found = false
  for _, tbl in ipairs({ info.cost, info.cmax }) do
    for pt, amount in pairs(type(tbl) == "table" and tbl or {}) do
      if G.SPENDER_POWER[pt] and (tonumber(amount) or 0) > 0 then
        local have = S.PowerNow(pt)
        local need = (type(info.cost) == "table" and tonumber(info.cost[pt])) or 1
        if type(have) ~= "number" or have < need then
          return false
        end
        found = true
      end
    end
  end
  return found and S.CooldownReady(id) ~= false
end

-- Area spells centred on you (yards): no use while the target is known to be farther than that (Holy Nova cast
-- from 40 yards, 2026-11-10). "Known" = one of your spells with a range is out of range (Clues.DistanceBounds);
-- without such a spell it can't be told and the spell stays allowed.
G.NEAR_ONLY = { holy_nova = 12, arcane_explosion = 10, spinning_crane_kick = 8, thunder_clap = 8, whirlwind = 8,
  consecration = 8, divine_storm = 8, fan_of_knives = 10, shuriken_storm = 10, swipe_bear = 8, swipe_cat = 8,
  thrash_bear = 8, thrash_cat = 8, blade_dance = 8, death_sweep = 8, immolation_aura = 8, crash_lightning = 8,
  bladestorm = 8, breath_of_sindragosa = 12, remorseless_winter = 8 }

local function TooFar(id)
  local token = M.TokenForID(id)
  local radius = token and G.NEAR_ONLY[token]
  if not radius then
    return false
  end
  local lo = ns.Clues.DistanceBounds()
  return type(lo) == "number" and lo > radius
end
G.TooFar = TooFar

local function CastableRaw(id)
  local rule = G.TARGET_RULES[id] or G.TARGET_RULES[(M.baseOf and M.baseOf[id]) or id]
  if rule and not rule(id) then
    return false, "target"
  end
  -- The game refused it for this target ("Invalid target": Touch of Death on a training dummy, 2026-11-12):
  -- not for this target, until you switch or the game lights it.
  if S.TargetRefused and S.TargetRefused(id) and S.glow[id] ~= true then
    return false, "target"
  end
  if TooFar(id) then
    return false, "range"
  end
  if BlockedWhileActive(id) then
    return false, "active"
  end
  -- Our clock for this spell is known wrong (Blizzard had to correct it twice this fight: see S.ClockUnreliable):
  -- for what to press now, it's ready exactly when Blizzard's assistant names it.
  do
    local v = S.Lookahead()
    local ac = G.acNow
    local named = ac == id or (ac and M.baseOf and M.baseOf[ac] == id)
    -- The game just refused it (you pressed it and it wasn't ready): not ready, until Blizzard names it.
    if (not v or #v.prev == 0) and not named and S.RefusedHold and S.RefusedHold(id) then
      return false, "refused"
    end
    -- Only while the assistant is naming rotation spells at all: stuck on something else (a missing poison, for
    -- a whole Outlaw fight) or naming nothing, our own clock decides again, or those spells never show.
    if (not v or #v.prev == 0) and S.BlizzardLeads(id) and G.AssistantHealthy() then
      return named and true or false
    end
  end
  local usable, noPower = U.Call(C_Spell and C_Spell.IsSpellUsable, id)
  usable, noPower = U.Read(usable), U.Read(noPower)
  if usable == nil then
    -- Hidden (restricted combat): our own cooldown clock still says when it can't be ready (a racial just used).
    if S.CooldownReady(id) == false then
      return false
    end
    -- Stealth can't be entered in combat (Vanish / Shadowmeld drop combat first): while the game hides whether
    -- it's usable, it isn't (Stealth and Prowl kept slot 1 in combat in the every-spec check, 2026-11-10).
    local token = M.TokenForID(id)
    if token and G.COMBAT_UNUSABLE[token] and S.combatStart then
      return false
    end
    return UNKNOWN
  end
  local ahead = S.Lookahead()
  local first = not ahead or #ahead.prev == 0
  -- Blizzard's assistant names this very spell right now: the game says it can be afforded (our estimate of a
  -- hidden resource can be low: Survival's focus held Raptor Strike back for seconds, 2026-11-09).
  local named = first and G.acNow and (G.acNow == id or (M.baseOf and M.baseOf[G.acNow] == id))
  if not usable and noPower ~= true and G.FinisherBlockedByHiddenPoints(id) then
    usable = true -- the points are there: trust them over an unexplained "not usable"
  end
  if not usable then
    if noPower ~= true then
      return false
    end
    if named then -- luacheck: ignore 542
      -- trust the game: affordable
    elseif not ahead then
      return false, "power"
    else
      -- Can't afford it now; by the look-ahead moment we may (resources gained in between).
      local afford = S.Affordable(id)
      if afford ~= true then
        return false, "power"
      end
    end
  elseif ahead and not first and (S.Affordable(id) == false or G.BelowCostAhead(id)) then
    -- (Usable now per the game: resources only grow until the next press. Our estimate is only for predicting
    -- slots 2-3 after casts we pretend.)
    return false, "power"
  end
  -- "Usable" from the game, but our range for the hidden resource is below its cost (Feral: Rake shown ready with
  -- energy known to be 0-24, 1 s before it could be pressed, 2026-11-10). The game's answer counts free procs it
  -- doesn't tell us about; a real free one glows, and the assistant naming it is trusted.
  if usable and first and not named and not S.glow[id] and G.BelowCost(id) then
    return false, "power"
  end
  -- (Spiritwalker's Grace and the like let you: the Elemental bar emptied while it ran, 2026-11-10)
  if first and S.moving and not (ns.db and ns.db.castWhileMoving) and CastTime(id) > 0 and not S.CastsWhileMoving() then
    return false, "moving"
  end
  local ready = S.CooldownReady(id)
  if ready == false then
    return false
  end
  return ready
end

-- A spell you can't press isn't shown: not on any of your action bars (a hero talent's new button, a class trial's
-- bars) means "not castable", like a cooldown, and the next spell takes its place. Chat says which spell, once,
-- when it would otherwise have been ready (Choices.OnBars). Asked for 2026-11-10: "why would we ever show a
-- spell someone can't find?"
-- A long cooldown we cast a moment ago can't be back yet, whatever spell ID the game reported it under (Havoc's
-- Metamorphosis: cast as one ID, looked up as another, our clock said "unknown" and slot 1 offered it every second
-- through Meta, 2026-11-10). By name, and only well inside the cooldown (40% left for talents that cut it).
G.RECENT_CD_MIN = 30
G.RECENT_CD_SHARE = 0.6
local function CastRecently(id)
  local token = M.TokenForID(id)
  local last = token and S.lastCastToken[token]
  if not last or (S.combatStart and last < S.combatStart - 3) then
    return false
  end
  local info = M.Info(id)
  local cd = (S.CooldownLength and S.CooldownLength(id)) or (info and (info.chcd or info.cd))
  if not (type(cd) == "number" and cd >= G.RECENT_CD_MIN) or (info and info.ch and info.ch > 1) then
    return false
  end
  return GetTime() - last < cd * G.RECENT_CD_SHARE
end
G.CastRecently = CastRecently

local function Castable(id)
  if id and M.IsAutomatic(id) then
    return false, "auto" -- the game casts it for you (M.AUTO_TRIGGERED)
  end
  local castable, why = CastableRaw(id)
  if castable ~= false and castable ~= true and id and CastRecently(id) then
    return false, "cast" -- (only when our clock can't tell: a known clock keeps the final say)
  end
  if castable ~= false and id and not ns.Choices.OnBars(id) then
    return false, "nobar" -- chat names it only when a line wants it right now (Walk)
  end
  return castable, why
end
G.Castable = Castable

-- Does Blizzard (live assistant, or our evaluation of its rules) agree with this spell?
-- Escalation. Blizzard's assistant never mentions many spells SimC relies on, so its silence is no "no". A key
-- spell (a real cooldown) that SimC keeps reaching while the assistant says something else is promoted once it
-- has waited long enough: "the assistant is clearly ignoring this, SimC says it matters, use it now". Fillers
-- (no cooldown) never escalate: that is what let an uncertain Starfire shadow Fury of Elune before.
-- Held spells. Skipping the spell in slot 1 three times in a fight ("not now, I'm saving it") holds it until the
-- fight ends: it is left out of every slot. Casting it yourself at any point releases it again.
G.SKIPS_TO_HOLD = 3
G.held, G.skips = {}, {}

local function Base(id)
  return (M.baseOf and M.baseOf[id]) or id
end

-- castID: the spell the player cast; shown: what slot 1 showed at that moment; queue: the slots shown.
-- Casting what slots 2 / 3 showed is choosing an order, not skipping (Eclipse from slot 2 held Fury of Elune).
function G.OnPlayerCast(castID, shown, enabled, queue)
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
  -- Casting another cooldown shown in slot 2 or 3 is choosing an order (Eclipse before Fury of Elune), not a skip.
  -- Casting a filler from slot 2/3 while a cooldown sits in slot 1 is a skip (Touch of Death, Monk).
  local castCd = S.CooldownLength and S.CooldownLength(castID)
  for i, p in ipairs(queue or {}) do
    if i > 1 and p.id and Base(p.id) == cast and castCd and castCd >= G.KEY_COOLDOWN then
      return nil
    end
  end
  -- Only spells worth saving can be held: a major cooldown or one of G.KEY_COOLDOWN (20 s) or more. Skipping a DoT or
  -- a builder means "not this GCD", not "save it": holding Immolate for a whole fight dropped the DoT (Destruction).
  local shownCd = S.CooldownLength and S.CooldownLength(shown.id)
  if not (shownCd and shownCd >= G.KEY_COOLDOWN) then
    return nil
  end
  local info = M.Info(castID)
  -- Off-GCD presses (no GCD in the data: Ironfur) are pressed alongside slot 1, not instead of it.
  if enabled == false or (info and (info.gcd == nil or info.gcd == 0)) or shown.source == "interrupt" or shown.source == "guess"
    or shown.source == "pool" then
    return nil -- off-GCD presses are no skip; a kick is tied to one enemy cast
  end
  local n = (G.skips[shown.id] or 0) + 1
  G.skips[shown.id] = n
  if n >= G.SKIPS_TO_HOLD then
    G.held[shown.id] = S.Now()
    G.skips[shown.id] = nil
    return "held", shown.id
  end
  return nil
end

-- A hold lapses after G.HOLD_FOR seconds: a spell you skipped three times comes back on its own instead of
-- staying away for the rest of the fight (Eclipse, 2026-11-10: held from 17 s to the end of a 95 s fight).
G.HOLD_FOR = 20
function G.IsHeld(id)
  local t = id and G.held[id]
  if not t then
    return false
  end
  if type(t) == "number" and S.Now() - t > G.HOLD_FOR then
    G.held[id] = nil
    return false
  end
  return true
end

G.KEY_COOLDOWN = 20 -- seconds of cooldown that make a spell "key"
G.WAIT = 4          -- seconds SimC must have wanted it, uncorroborated, before it comes in anyway
G.LAPSE = 1.5       -- a gap longer than this between sightings starts the wait again
G.waiting = {}

-- Never forced in by waiting: leaps and steps move you (Vengeful Retreat, Infernal Strike), and mana channels
-- depend on a mana level we may not see (Evocation). Their own conditions decide. Found 2026-11-10.
G.NO_ESCALATE = { vengeful_retreat = true, infernal_strike = true, fel_rush = true, heroic_leap = true,
  disengage = true, roll = true, chi_torpedo = true, blink = true, shimmer = true, evocation = true,
  death_grip = true, charge = true, wild_charge = true, shadowstep = true, harpoon = true, feral_lunge = true }
G.COMBAT_UNUSABLE = { stealth = true, prowl = true }

local function Waited(id, token, run, castable)
  if not run.first or castable ~= true or G.NO_ESCALATE[token] then
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

-- Spender resources (power types): combo points, runic power, soul shards, astral power, holy power,
-- maelstrom, chi, insanity, arcane charges, fury, essence. Not mana, rage, focus, energy or runes: everything
-- costs those, so "the assistant spends some" says nothing about a particular line.
G.SPENDER_POWER = { [4] = true, [6] = true, [7] = true, [8] = true, [9] = true, [11] = true, [12] = true,
  [13] = true, [16] = true, [17] = true, [19] = true }

-- Both spend the same spender resource: the assistant asking for one (Earthquake) says the resource is there for
-- SimC's uncertain spender of it (Earth Shock), whose line was uncertain only because the amount is hidden.
local function SameSpender(id, other)
  local a, b = M.Cost(M.Info(id)), M.Cost(M.Info(other))
  if not (a and b) then
    return false
  end
  for pt, amount in pairs(a) do
    if G.SPENDER_POWER[pt] and amount > 0 and (b[pt] or 0) > 0 then
      return true
    end
  end
  return false
end
G.SameSpender = SameSpender

local function Corroborated(id, token, run, castable)
  -- The game's own button highlight (a proc glow: Earthquake / Earth Shock with enough Maelstrom, a free
  -- spender) says "press this" about exactly the hidden state that made the line uncertain.
  if castable == true and (S.glow[id] or (run.override[id] and S.glow[run.override[id]])) then
    return "glow"
  end
  if run.acSpell then
    -- Blizzard's live assistant sees the hidden state (procs, resources); our evaluation of its rules does
    -- not. When it is there, only it can confirm an uncertain line: otherwise a rule that happens to hold
    -- would let an uncertain filler shadow the certain lines below it (Balance: an uncertain Starfire over
    -- Fury of Elune while the assistant was saying Fury of Elune, seen in game 2026-11-08).
    if run.acSpell == id or run.acSpell == run.override[id] then
      return "assisted"
    end
    -- Only when SimC's list has no line of its own for the named spender: Blizzard asking for Starfall on six
    -- targets made the uncertain Starsurge line above Starfall's "confirmed" (Balance, 2026-11-09).
    local named = M.TokenForID(run.acSpell)
    if castable == true and SameSpender(id, run.acSpell) and not (named and run.simcActions and run.simcActions[named]) then
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
    elseif (a == "call_action_list" or a == "run_action_list") and not G.HasActions(lists, e.p and e.p.name) then
      -- A list with nothing we can show (Restoration's "healing": a simulated Regrowth sequence). Running it
      -- would stop the whole list every time, so the rest (cat weaving) was never reached.
      if run.trace then
        run.trace[#run.trace + 1] = string.format("%s:%s %s skipped (nothing to show)", name, a, tostring(e.p.name))
      end
    elseif a == "call_action_list" or a == "run_action_list" then
      local sub = e.p and e.p.name
      local t = Test(e.c, run)
      if sub and t == false and not isBlizzard and not run.heroFallback and type(e.c) == "string"
        and e.c:match("^hero_tree%.[%w_]+$") and M.NoHeroTree() then
        -- Lists split by hero tree (Brewmaster: run_action_list,name=shado_pan,if=hero_tree.shadopan). Without a
        -- hero tree yet (levelling), none would run and SimC would have nothing to say: the first one is used
        -- (spells the player doesn't have are skipped as usual).
        run.heroFallback = sub
      end
      -- The same split written as the hero tree's keystone talent (Arms: run_action_list,name=colossus_st,
      -- if=talent.demolish / slayer_st if=talent.slayers_dominance). Without any hero tree neither ran, SimC said
      -- nothing and Blizzard's simpler rules filled every slot (2026-11-12): the first such list whose other
      -- conditions hold is used.
      if sub and t == false and not isBlizzard and not run.heroFallback and a == "run_action_list"
        and type(e.c) == "string" and M.talentsRead and not M.heroTree then
        local talent, rest = e.c:match("^talent%.([%w_]+)(.*)$")
        if talent and M.TalentRank(talent) == 0 and (rest == "" or rest:sub(1, 1) == "&") then
          local other = rest ~= "" and rest:sub(2) or nil
          if not other or Test(other, run) ~= false then
            run.heroFallback = sub
          end
        end
      end
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
    elseif (a == "use_items" or a == "use_item") and not isBlizzard then
      -- On-use trinkets are shown by the Trinkets module; here we only note what the list says about them.
      -- Checked per trinket: "this_trinket" is each equipped one in turn (use_items), or the one named (use_item).
      local p = e.p or {}
      local T = ns.Trinkets
      local checks = {}
      if a == "use_items" then
        for i, slot in ipairs(T.SLOTS) do
          checks[#checks + 1] = { "trinket" .. i, slot }
        end
      elseif p.slot then
        checks[1] = { tostring(p.slot), tostring(p.slot) == "trinket2" and 14 or 13 }
      elseif p.name then
        local this
        for _, slot in ipairs(T.SLOTS) do
          local info = T.Info(slot)
          if info and T.Token(info.name) == tostring(p.name) then
            this = slot
          end
        end
        checks[1] = { "name:" .. tostring(p.name), this }
      end
      run.useItems = run.useItems or {}
      for _, c in ipairs(checks) do
        local key = c[1]
        local was = run.useItems[key]
        if was ~= true then -- several lines for one item: any "yes" is a yes
          T.this = c[2]
          local t = Test(e.c, run)
          T.this = nil
          if maybe and t == true then
            t = UNKNOWN
          end
          if was == nil or t ~= false then
            run.useItems[key] = t
          end
        end
      end
    elseif a == "potion" and not isBlizzard then
      -- A potion you chose (Spells & trinkets page) is shown by the Trinkets module when a line here says now.
      if run.potion ~= true then
        local t = Test(e.c, run)
        if maybe and t == true then
          t = UNKNOWN
        end
        if run.potion == nil or t ~= false then
          run.potion = t
        end
      end
    elseif a == "pool_resource" then
      if not isBlizzard and e.p and tostring(e.p.for_next) == "1" and not maybe then
        run.poolNext = Test(e.c, run) == true or nil
      end
    elseif not G.SKIP[a] and not (isBlizzard and not run.burst and (e.x or run.cooldowns[a])) then
      -- (Blizzard's excluded lines are the major cooldowns: left out only when major cooldowns are off.)
      local id = M.SpellID(a)
      if id and (a:find("^call_pet") or a == "summon_pet") and not S.PetActive() and S.PetDead()
        and U.Get(IsPlayerSpell, S.REVIVE_PET) == true then
        id = S.REVIVE_PET -- the pet is dead: calling it does nothing, reviving it does
      end
      if id and (a:find("^call_pet") or a == "summon_pet") and S.PetActive() then
        -- SimC only summons when there is no pet: with one out, the line does nothing.
        if run.trace then
          run.trace[#run.trace + 1] = string.format("%s:%s pet already out", name, a)
        end
      elseif id and ns.Choices.IsHidden(id) then
        if run.trace then
          run.trace[#run.trace + 1] = string.format("%s:%s hidden by you", name, a)
        end
      elseif id and e.p and tostring(e.p.moving) == "1" and not S.moving then
        -- SimC's "moving=1": only while moving (Spiritwalker's Grace, instant shocks on the run).
        if run.trace then
          run.trace[#run.trace + 1] = string.format("%s:%s only while moving", name, a)
        end
      elseif id and ns.Tanks and ns.Tanks.InIcon(a) then
        -- a tank's mitigation: in the defensive icon (Tanks.lua), slots 1-3 stay the damage rotation
        if run.trace then
          run.trace[#run.trace + 1] = string.format("%s:%s in the defensive icon", name, a)
        end
      elseif id and NotHurtSkip(a) then
        if run.trace then
          run.trace[#run.trace + 1] = string.format("%s:%s nothing to mitigate", name, a)
        end
      elseif id and G.IsHeld(id) then
        if run.trace then
          run.trace[#run.trace + 1] = string.format("%s:%s held (you skipped it)", name, a)
        end
      elseif id and LineOnCooldown(e, id) then
        if run.trace then
          run.trace[#run.trace + 1] = string.format("%s:%s line_cd", name, a)
        end
      elseif id then
        local cond = Condition(e)
        -- once per spell per decision: lists name the same spell on many lines, and with nothing castable the
        -- whole list is walked (11 ms per decision for Windwalker, 2026-11-10)
        local memo = run.castMemo
        local c = memo[id]
        if not c then
          c = { Castable(id) }
          memo[id] = c
        end
        local castable, why = c[1], c[2]
        local pooling = run.poolNext
        run.poolNext = nil
        if run.trace then
          local charges = S.Charges(id)
          run.trace[#run.trace + 1] = string.format("%s:%s castable=%s%s%s", name, a, tostring(castable),
            why and ("(" .. why .. ")") or "", charges and (" charges=" .. charges) or "")
        end
        if castable == false and why == "power" and pooling and not isBlizzard and not maybe
          and Test(cond, run, a) == true then
          -- SimC said "pool for the next action" and this is it: wait for the resource instead of a filler.
          run.visiting[name] = nil
          return { id = id, token = a, source = "pool" }
        end
        -- The first line held back only by a resource it is waiting for: if nothing at all can be pressed
        -- (Blizzard's "Waiting for Energy"), this is what slot 1 shows, as "waiting", instead of an empty HUD.
        -- Off your bars: say so only when this line wants it right now. Checking every line named spells from the
        -- other hero tree and unused talent choices ("missing spells not even in this spec", 2026-11-11).
        if castable == false and why == "nobar" and run.first and not isBlizzard and Test(cond, run, a) == true then
          ns.Choices.NoteOffBars(id)
        end
        if castable == false and why == "power" and not run.powerBlocked and not isBlizzard and not maybe
          and Test(cond, run, a) ~= false then
          run.powerBlocked = { id = id, token = a, source = "pool" }
        end
        -- (also under an uncertain gate, e.g. Subtlety's "build if energy>60" with Energy hidden: used only when
        -- SimC rules out Blizzard's pick, see below)
        if castable == false and why == "power" and not run.powerBlockedMaybe and not isBlizzard
          and Test(cond, run, a) ~= false then
          run.powerBlockedMaybe = { id = id, token = a, source = "pool" }
        end
        if castable ~= false then
          local t = Test(cond, run, a)
          if run.trace then
            run.trace[#run.trace] = run.trace[#run.trace] .. " cond=" .. tostring(t)
          end
          if run.first and not isBlizzard then
            -- for G.PromoteReadyMajor: a token is "not now" when every one of its lines read so far was false
            if t == false then
              if run.notNow[a] == nil then
                run.notNow[a] = true
              end
            else
              run.notNow[a] = false
            end
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
            elseif not run.firstRuleMaybe and not (ns.Buffs and ns.Buffs.IsBuffSpell and ns.Buffs.IsBuffSpell(id)) then
              -- (a raid buff on an unknown "aura down" isn't guessed: in combat the aura is hidden, so Arcane
              -- Intellect, already up, filled slot 1 whenever the rest couldn't be cast while moving, 2026-11-12;
              -- the buff reminder handles those)
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

-- Channels SimC means to cut short: its line for the spell chains or interrupts it (Mind Flay "chain=1",
-- "interrupt_if=ticks>=2"). Those get no HOLD cue on slot 1; every other channel does.
local clipCache = setmetatable({}, { __mode = "k" })
function G.ClipAllowed(id, record)
  record = record or (ns.Specs.current and ns.Specs.current.data)
  local token = id and M.TokenForID(id)
  if not (token and type(record) == "table" and type(record.simc) == "table") then
    return false
  end
  local set = clipCache[record]
  if not set then
    set = {}
    for _, list in pairs(record.simc) do
      for _, e in ipairs(type(list) == "table" and list or {}) do
        local p = e.p
        if p and (p.chain or p.interrupt or p.interrupt_if or p.interrupt_immediate or p.early_chain_if) then
          set[e.a] = true
        end
      end
    end
    clipCache[record] = set
  end
  return set[token] == true
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
  p = { blizzardByAction = {}, cooldowns = SetOf(record.blizzardExcluded), simcActions = {}, fightActions = {} }
  for name, list in pairs(type(record.simc) == "table" and record.simc or {}) do
    for _, e in ipairs(type(list) == "table" and list or {}) do
      if type(e) == "table" and e.a then
        p.simcActions[e.a] = true
        if name ~= "precombat" then
          p.fightActions[e.a] = true -- used in the fight itself, not only as preparation
        end
      end
    end
  end
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

-- Is this spell part of the spec's damage rotation (any line of its SimC list)? Utility, movement and anything
-- the lists never use is not (the grade leaves such presses out).
function G.IsRotationSpell(id)
  local state = ns.Specs and ns.Specs.current
  local record = state and state.data and ns.ActiveRecord and ns.ActiveRecord(state)
  if not (record and id) then
    return true -- can't tell: count it
  end
  local actions = Prepare(record).simcActions
  for _, cand in ipairs({ id, M.baseOf and M.baseOf[id] }) do
    local token = cand and M.TokenForID(cand)
    if token and actions[token] then
      return true
    end
  end
  return false
end

-- A spell that's preparation, not play: a shapeshift / stance / aura (Bear Form, Moonkin Form), or one the lists
-- only use before the pull. Out of combat these don't start Flow mode (2026-11-12: "switching specs and hitting
-- Bear Form starts the flow").
function G.IsPrepSpell(id)
  local token = id and M.TokenForID(id)
  local base = id and M.baseOf and M.baseOf[id]
  token = token or (base and M.TokenForID(base))
  local info = not token and id and M.Info and M.Info(id)
  token = token or (info and info.n)
  if not token then
    return false
  end
  if token:find("_form$") or token:find("stance") or token:find("presence") or token:find("_aura$") then
    return true
  end
  local state = ns.Specs and ns.Specs.current
  local record = state and state.data and ns.ActiveRecord and ns.ActiveRecord(state)
  if not record then
    return false
  end
  local p = Prepare(record)
  return p.simcActions[token] == true and not p.fightActions[token]
end

-- One decision at the current overlay moment.
local function Decide(record, opts, targets, first)
  local prep = Prepare(record)
  local run = {
    ctx = { vars = CopyVars(G.fightVars), targets = targets },
    visiting = {},
    unresolved = {},
    cooldowns = prep.cooldowns,
    simcActions = prep.simcActions,
    blizzardByAction = prep.blizzardByAction,
    burst = opts.burst ~= false,
    override = {},
    trace = (first and opts.trace) and {} or nil,
  }
  run.first = first
  run.notNow = {}
  if first then
    G.notNow = run.notNow
  end
  run.castMemo = {}
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
  if first then
    G.acNow = nil
  end
  if first and opts.useAssisted then
    local ac = U.Get(C_AssistedCombat and C_AssistedCombat.GetNextCastSpell, false)
    -- A buff, poison or weapon imbue named in combat (Numbing Poison missing: the assistant named it for a whole
    -- fight) says nothing about the rotation: ignored, the buff reminder covers it.
    G.NoteAssistant(ac)
    G.acStuck = type(ac) == "number" and ((ns.Buffs and ns.Buffs.IsBuffSpell and ns.Buffs.IsBuffSpell(ac))
      or (S.rotationSpells ~= nil and not S.BlizzardCanName(ac))) or false
    if type(ac) == "number" and ns.Buffs and ns.Buffs.IsBuffSpell and ns.Buffs.IsBuffSpell(ac) then
      ac = nil
    end
    -- Never what we show for the rotation, whoever names it: interrupts (the Interrupts module shows them while
    -- a target casts), auto attacks, Bloodlust, movement (Essentials' gap closer handles that).
    local acToken = type(ac) == "number" and M.TokenForID(ac)
    if acToken and G.SKIP[acToken] then
      ac = nil
    end
    -- A placeholder the assistant uses when nothing can be pressed: "Waiting for Energy" (1249752, a stopwatch
    -- that isn't in any spellbook). Never shown; it tells us the resource is below every spender's cost.
    if type(ac) == "number" and G.IsAssistantPlaceholder(ac) then
      G.OnAssistantWait(ac)
      run.waiting = ac
      ac = nil
    end
    if type(ac) == "number" then
      run.acSpell = ac
      G.acNow = ac
      setmetatable(run.override, { __index = function(t, id)
        local o = U.Get(C_Spell and C_Spell.GetOverrideSpell, id)
        t[id] = o or false
        return t[id]
      end })
    end
  end

  -- What the assistant's pick tells us about hidden state (facts feed the resolver for this decision on).
  if not run.acSpell then
    S.acNamed = nil -- Blizzard names nothing: its next naming is a new one
  end
  if run.acSpell then
    ns.Clues.ObserveExecute(run.acSpell)
    S.ObserveAssistedCharge(run.acSpell)
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
  -- The player's "first when ready" spells come before the list whenever they can be cast.
  for _, fid in ipairs(ns.Choices.FirstSpells()) do
    if not G.IsHeld(fid) then
      local castable = Castable(fid)
      if castable == true or (castable == UNKNOWN and S.CooldownReady(fid) == true) then
        pick = { id = fid, token = M.TokenForID(fid), source = "first" }
        if run.trace then
          run.trace[#run.trace + 1] = "first:" .. tostring(pick.token) .. " your choice"
        end
        break
      end
    end
  end
  if not pick and type(record.simc) == "table" then
    pick = Walk(record.simc, "default", false, 0, run, false)
    if not pick and run.heroFallback and record.simc[run.heroFallback] then
      pick = Walk(record.simc, run.heroFallback, false, 1, run, false)
    end
  end
  if pick == STOP then
    pick = nil
  end
  -- Also when SimC's own line rules out Blizzard's pick right now: Subtlety on 5 targets waiting for Energy for
  -- Shuriken Storm showed Blizzard's Gloomblade (a single-target builder, cond=false), then switched to Shuriken
  -- Storm when the Energy came, 21 times in 3 minutes without a press (2026-11-11).
  local acToken = run.acSpell and M.TokenForID(run.acSpell)
  local acRuledOut = acToken and run.notNow and run.notNow[acToken] == true
  if not pick and run.first and run.powerBlocked and (run.waiting or not run.acSpell or acRuledOut) then
    pick = run.powerBlocked -- waiting for the resource: the spell it's for, shaded
  elseif not pick and run.first and acRuledOut and run.powerBlockedMaybe then
    pick = run.powerBlockedMaybe
  end
  -- Blizzard's assistant as the fallback: still subject to our own checks (target rules: it suggests Touch of
  -- Death on a full-health dummy; cooldown and power: it also names the next important spell while that is still
  -- on cooldown, and Judgment showed in slot 1 with 2 s left, 2026-11-09) and to spells the player is holding.
  -- On cooldown, the look-ahead below shows it a moment early, marked as not ready yet.
  if not pick and run.acSpell and not G.IsHeld(run.acSpell) and not ns.Choices.IsHidden(run.acSpell) then
    local castable, why = Castable(run.acSpell)
    if castable ~= false then
      pick = { id = run.acSpell, token = M.TokenForID(run.acSpell), source = "assisted" }
    elseif run.trace then
      run.trace[#run.trace + 1] = "assisted:" .. tostring(run.acSpell) .. " not castable (" .. tostring(why or "cooldown") .. ")"
    end
  end
  if not pick and type(record.blizzard) == "table" then
    local start = record.blizzard.default and "default" or (record.blizzardOrder or {})[1]
    local r = start and Walk(record.blizzard, start, false, 0, run, true)
    if r and r ~= STOP then
      pick = r
    end
  end
  pick = pick or run.firstMaybe or run.firstRuleMaybe
  -- Nothing at all: the spell it's waiting for, shaded, rather than an empty slot 1. Right after Fan of Knives every
  -- line was short of Energy and Blizzard's Mutilate sat in the GCD, so slot 1 blinked out after each press
  -- (Assassination, 2026-11-11).
  if not pick and run.first then
    pick = run.powerBlocked or run.powerBlockedMaybe
  end
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
    branch = branch, trace = run.trace, useItems = run.useItems, potion = run.potion }
end

-- Nothing castable at this moment (energy-starved, everything on cooldown): look a little further ahead, in
-- steps, and show the first spell that becomes ready, instead of an empty slot (Brewmaster at 15 energy).
G.WAIT_STEP = 0.5
G.WAIT_MAX = 3

local function DecideAhead(record, opts, targets, first)
  local r = Decide(record, opts, targets, first)
  local v = S.Lookahead()
  if (r.main and r.main.id) or not v then
    return r
  end
  local base = v.dt
  local waited = 0
  while waited < G.WAIT_MAX do
    waited = waited + G.WAIT_STEP
    v.dt = base + waited
    local later = Decide(record, opts, targets, first)
    if later.main and later.main.id then
      later.main.wait = waited
      -- When it comes off cooldown, from its own cooldown clock (the half-second steps above only find it; using
      -- them as the time made slot 1 jump between "not yet" and "now" and flash over and over, 2026-11-09).
      v.dt = base
      -- The "not yet" shade only from a real clock (its cooldown). A wait for a resource we estimate isn't shaded:
      -- the estimate can be seconds off (Raptor Strike shaded while ready on the bar, Survival 2026-11-09).
      local left = S.CooldownRemains(later.main.id)
      if type(left) == "number" and left > 0 then
        later.main.readyAt = GetTime() + base + math.min(left, waited)
      end
      return later
    end
  end
  v.dt = base
  return r
end

-- Slots still empty after the look-ahead (a short list with every spell on cooldown, a Holy Paladin between
-- heals): fill them with the list's spells that come off cooldown soonest, so the player sees what is next.
-- Only spells waiting on their cooldown, not ones held back by the target, power or an effect still running.
G.SOON_MAX = 15

function G.Soonest(record, have, count)
  local out = {}
  if count <= 0 or type(record) ~= "table" or type(record.simc) ~= "table" then
    return out
  end
  local seen, candidates = {}, {}
  for _, p in ipairs(have) do
    if p and p.id then
      seen[p.id] = true
    end
  end
  for _, list in pairs(record.simc) do
    for _, e in ipairs(list) do
      local id = not G.SKIP[e.a] and M.SpellID(e.a) or nil
      if id and not seen[id] then
        seen[id] = true
        if not G.IsHeld(id) and not ns.Choices.IsHidden(id) then
          local castable, why = Castable(id)
          local left = S.CooldownRemains(id)
          if castable ~= true and why == nil and type(left) == "number" and left > 0 and left <= G.SOON_MAX then
            candidates[#candidates + 1] = { id = id, token = e.a, left = left }
          end
        end
      end
    end
  end
  table.sort(candidates, function(a, b)
    if a.left ~= b.left then
      return a.left < b.left
    end
    return a.id < b.id
  end)
  for i = 1, math.min(count, #candidates) do
    local c = candidates[i]
    out[i] = { id = c.id, token = c.token, source = "soon", wait = c.left }
  end
  return out
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
  local result = DecideAhead(record, opts, targets, true)
  result.queue = { result.main }
  local last = result.main
  for slot = 2, depth do
    if not (last and last.id) then
      break
    end
    S.Apply(last.id)
    local nextPick = DecideAhead(record, opts, targets, false).main
    result.queue[slot] = nextPick
    last = nextPick
  end
  local have = #result.queue
  if result.main and have < depth then
    for _, p in ipairs(G.Soonest(record, result.queue, depth - have)) do
      result.queue[#result.queue + 1] = p
    end
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

-- Steady slot 1. Between two presses the decision can flip between spells several times a second as hidden
-- state shifts (Blizzard's pick changing, a clock crossing "ready"); switching three times in a second is hard to
-- follow (2026-11-09: Raptor Strike -> Wildfire Bomb -> Kill Command in 0.3 s). So:
--   * after each press (a new GCD or cast starts) slot 1 shows the new pick at once;
--   * after that, until the next press, a different pick replaces it only once it has held for G.DEBOUNCE;
--     a flip shorter than that never shows, and moves to slot 2 meanwhile (it may be next);
--   * in the last G.REACH seconds before the press, and while it sits ready, slot 1 doesn't change at all: you are
--     already reaching for it. Something that becomes ready then (a Wildfire Bomb charge 0.1 s before you pressed
--     Raptor Strike, five times in one fight, 2026-11-09) waits in slot 2 for the next press;
--   * the shown spell is dropped at once if the game refused your press of it, or once it has been
--     uncastable for G.UNCASTABLE_FOR.
-- Interrupts and defensives are applied after this and still take slot 1 at once.
G.DEBOUNCE = 0.5
G.REACH = 0.6
G.DEBOUNCE_FAST = 0.2 -- "Fast": changes show sooner, the hold before the press is short
G.REACH_FAST = 0.25
G.UNCASTABLE_FOR = 0.2
G.LOCK_MAX = 4.0 -- safety: a pick shown this long without a press is re-decided freely
local held -- { pick, at, cand, candAt, badSince }
local lastReady, pressedAt = 0, -10
-- Right after a press the game starts the GCD a moment before it reports which spell was cast: a decision made in
-- that gap still shows the spell you just pressed. For this long after a press slot 1 follows the decision freely
-- (2026-11-09: the stale Whirlwind was held through a short hasted GCD, and pressed again).
G.PRESS_SETTLE = 0.35

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
  local pressed = ready > lastReady + 0.3 -- a new GCD or cast just started: you pressed something
  lastReady = ready
  if pressed then
    pressedAt = now
  end
  if pressed or not held or now - held.at > G.LOCK_MAX then
    held = { pick = main, at = now, fresh = pressed }
    return result
  end
  -- Right after a press: one free change (the spell you just pressed is replaced by what comes next). A second
  -- change in the same moment waits like any other (Balance flipped Starsurge > Sunfire > Starsurge within
  -- 0.3 s of each cast while the player was pressing quickly, 2026-11-09).
  if now - pressedAt < G.PRESS_SETTLE and held.fresh and held.pick.id ~= main.id then
    held = { pick = main, at = now }
    return result
  end
  if held.pick.id == main.id then
    held.cand, held.badSince = nil, nil
    return result
  end
  -- is the shown spell still pressable?
  local ok, why = Castable(held.pick.id)
  if why == "refused" or why == "nobar" then -- (not on your bars: it never will be pressable)
    held = { pick = main, at = now }
    return result
  end
  if ok == false then
    held.badSince = held.badSince or now
    if now - held.badSince >= G.UNCASTABLE_FOR then
      held = { pick = main, at = now }
      return result
    end
  else
    held.badSince = nil
  end
  -- a different pick: never while you're reaching for slot 1; otherwise once it has held for G.DEBOUNCE.
  -- Settings > Combat > "Slot 1 changes": Steady (default) or Fast (for players who react quickly).
  local fast = ns.db and ns.db.slotHold == "fast"
  local reach, debounce = fast and G.REACH_FAST or G.REACH, fast and G.DEBOUNCE_FAST or G.DEBOUNCE
  if ready <= reach then
    held.cand = nil
  elseif held.cand ~= main.id then
    held.cand, held.candAt = main.id, now
  elseif now - held.candAt >= debounce then
    held = { pick = main, at = now }
    return result
  end
  local queue, out = result.queue or { main }, { held.pick }
  for _, p in ipairs(queue) do
    if p.id ~= held.pick.id and #out < math.max(#queue, 1) then
      out[#out + 1] = p
    end
  end
  result.queue, result.main, result.steadied = out, held.pick, main.token
  return result
end

-- One rule for every path (normal, leveling, Blizzard's pick as fallback): a major cooldown the priority list
-- wants and that can be pressed now never waits in slot 2 or 3 behind Blizzard's pick. Blizzard's assistant never
-- names major cooldowns, so behind its pick they would never come up (Summon Infernal 40 s in slot 2, 2026-11-10;
-- six more specs found by tests/test_scenarios.lua). Runs after Steady and the leveling lead, in Main.
-- Not one whose own SimC line said "not now" at this moment (all its lines false): from slot 3, two pretend casts
-- away, it comes and goes as the GCD runs down (Subtlety's Shadow Blades blinked into slot 1 every 4 s once slot 3
-- stopped repeating Shuriken Storm, 2026-11-11).
function G.PromoteReadyMajor(result)
  local queue = result and result.queue
  local main = result and result.main
  if not (queue and main and main.source == "assisted") then
    return result
  end
  for i = 2, #queue do
    local p = queue[i]
    if p and p.id and p.major and type(p.source) == "string" and (p.source:find("^simc") or p.source == "rules")
      and not p.readyAt
      and not (p.token and G.notNow and G.notNow[p.token])
      and Castable(p.id) == true then
      table.remove(queue, i)
      table.insert(queue, 1, p)
      result.main, result.branch = p, nil
      return result
    end
  end
  return result
end

function G.ResetSteady()
  held, lastReady, pressedAt = nil, 0, -10
end
