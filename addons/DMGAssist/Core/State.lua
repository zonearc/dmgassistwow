-- State.lua: everything the engine can know about "now" (or about a predicted moment a few GCDs ahead).
--
-- Three sources, best first:
--   1. Read  — the game tells us (out of combat nearly everything; in combat the NeverSecret/whitelisted bits).
--   2. Track — our own clock: casts we saw, durations from SimC's spell data or learned while readable.
--   3. Unknown — E.UNKNOWN; the engine needs corroboration before acting on it.
--
-- Prediction: S.BeginLookahead() installs an overlay (V) that shifts the clock forward and records the
-- effects of spells we expect to be cast (cooldowns started, auras applied, resources spent/gained, prev_gcd).
-- Every read below goes through Now() and the overlay, so the same SimC evaluation answers "what next, after that".
--
-- Own casts come from UNIT_SPELLCAST_SUCCEEDED, whose payload is SecretWhenUnitSpellCastRestricted. When the
-- spell ID is secret we still see casts of spells with a real cooldown: SpellCooldownInfo.isActive is NeverSecret,
-- so a spell whose isActive flips false -> true (and is not just on the GCD) was just cast.
--
-- Everything here goes through U.Read: a secret is treated as "not known", never compared.

local _, ns = ...
local U, E, M = ns.U, ns.Expr, ns.SpellMap
local UNKNOWN = E.UNKNOWN

local S = {}
ns.State = S

local GCD_SPELL = 61304
local TRACK_WINDOW = 0.5   -- seconds: an aura appearing this soon after a cast is linked to that cast
local MAX_NAMEPLATES = 40

S.learned = { cd = {}, aura = {}, castAura = {} }
S.history = {}      -- recent own casts, newest first: { id=, token=, t= }
S.auraUntil = {}    -- token -> expiry (tracked from casts; player buffs)
S.dotUntil = {}     -- token -> expiry on the current target
S.lastCast = {}     -- spellID -> GetTime() of the last cast we saw
S.lastCastToken = {} -- SimC token -> GetTime() of the last cast we saw (Lunar / Solar Eclipse share "eclipse")
S.wasActive = {}    -- spellID -> last isActive (for cast inference)
S.glow = {}         -- spellID -> true while the proc glow is shown
S.combatStart = nil
S.unknownTerms = {}
S.drift = {}
S.castsSeen, S.castsSecret, S.castsInferred = 0, 0, 0
S.modeOverride = nil -- "auto" / "st" / "aoe" set by the hotkey for this session
S.moving = false     -- from PLAYER_STARTED_MOVING / PLAYER_STOPPED_MOVING

local V = nil -- look-ahead overlay, nil = the real present

local POWER = {
  mana = "Mana", rage = "Rage", focus = "Focus", energy = "Energy", combo_points = "ComboPoints",
  runes = "Runes", rune = "Runes", runic_power = "RunicPower", soul_shard = "SoulShards", soul_shards = "SoulShards",
  astral_power = "LunarPower", lunar_power = "LunarPower", holy_power = "HolyPower", maelstrom = "Maelstrom",
  chi = "Chi", insanity = "Insanity", arcane_charges = "ArcaneCharges", fury = "Fury", pain = "Pain",
  essence = "Essence",
}
local POWER_FALLBACK = {
  Mana = 0, Rage = 1, Focus = 2, Energy = 3, ComboPoints = 4, Runes = 5, RunicPower = 6, SoulShards = 7,
  LunarPower = 8, HolyPower = 9, Maelstrom = 11, Chi = 12, Insanity = 13, ArcaneCharges = 16, Fury = 17, Pain = 18,
  Essence = 19,
}

local function Now()
  if V then
    return GetTime() + V.dt
  end
  return GetTime()
end
S.Now = Now

local function PowerType(name)
  local key = POWER[name]
  if not key then
    return nil
  end
  local enum = Enum and Enum.PowerType and U.Read(Enum.PowerType[key])
  return enum or POWER_FALLBACK[key]
end

-- Largest value a resource can have: readable max, else the last one seen (kept per spec), else nil.
function S.PowerMax(pt)
  local max = U.Get(UnitPowerMax, "player", pt)
  S.learned.powerMax = S.learned.powerMax or {}
  if type(max) == "number" and max > 0 then
    S.learned.powerMax[pt] = max
    return max
  end
  return S.learned.powerMax[pt]
end

-- Power type for a bare resource name ("combo_points" -> 4), nil for anything else.
function S.PowerTypeOf(name)
  return PowerType(name)
end

---------------------------------------------------------------------------
-- Target count: auto-detect from nameplates when readable, else the user's mode (hotkey switchable)
---------------------------------------------------------------------------
function S.Settings()
  local db = ns.db or {}
  return {
    mode = db.mode or "aoe",
    autoDetect = db.autoDetect ~= false,
    aoeTargets = tonumber(db.aoeTargets) or 3,
    fightLength = tonumber(db.fightLength) or 300,
  }
end

-- The spell that sets "in range" for counting: the most common range among the player's known spells
-- (40 yd for a caster, melee for Feral), so the count fits the spec without per-class tables.
local rangeProbe = { book = nil }
local function RangeProbe()
  if rangeProbe.book == M.book then
    return rangeProbe.id
  end
  local byRange, best, bestN = {}, nil, 0
  for id, b in pairs(M.book or {}) do
    local info = b.id == id and not b.passive and M.Info(id)
    if info and info.r and info.r > 0 then
      local entry = byRange[info.r] or { n = 0, id = id }
      entry.n = entry.n + 1
      byRange[info.r] = entry
      if entry.n > bestN then
        best, bestN = entry.id, entry.n
      end
    end
  end
  rangeProbe.book, rangeProbe.id = M.book, best
  return best
end
S.RangeProbe = RangeProbe

-- Is anything hurting the player? Stagger (Brewmaster) or missing health, when the game shows either.
-- true = readably untouched (full health, no stagger); false = being hurt; nil = can't tell.
-- true = nothing is hurting the player (skip mitigation SimC would press on cooldown), false = being hurt,
-- nil = can't tell (mitigation stays as the list says).
-- Health is hidden in combat in Midnight. Then a tank holding aggro on anything (threat status 2-3: "tanking") is
-- being hit; Stagger only tells for a Brewmaster (it is always 0 for everyone else: a Protection Warrior was told
-- "nothing to mitigate" for whole fights against the tank dummy, 2026-11-09).
function S.Unhurt()
  local st = U.Get(UnitStagger, "player")
  if type(st) == "number" and st > 0 then
    return false
  end
  local hp, max = U.Get(UnitHealth, "player"), U.Get(UnitHealthMax, "player")
  if type(hp) == "number" and type(max) == "number" and max > 0 and hp < max then
    return false
  end
  local spec = ns.Specs.current and ns.Specs.current.key
  local tank = ns.Engine and ns.Engine.TANK_SPECS and ns.Engine.TANK_SPECS[spec or ""]
  local threat = tank and U.Get(UnitThreatSituation, "player")
  if type(threat) == "number" and threat >= 2 then
    return false -- a tank with aggro: being hit, even at full health (mitigation goes up before the damage)
  end
  if type(hp) == "number" and type(max) == "number" and max > 0 then
    return true -- full health, nothing on us
  end
  if type(st) == "number" and spec == "monk_brewmaster" then
    return true
  end
  return nil
end

-- Stagger the player carries (Brewmaster), when readable.
function S.Stagger()
  local st = U.Get(UnitStagger, "player")
  return type(st) == "number" and st or nil
end

-- Hostile enemies in combat with a nameplate, within range of the player's usual spell when the game says;
-- nil when it won't tell us at all.
-- Remembered: an enemy counted once keeps counting for ENEMY_MEMORY seconds while its nameplate is up, alive and
-- in range, so a combat flag that flickers or goes secret for a moment does not drop it. Training dummies leave
-- combat within seconds of the last hit, so they are remembered for DUMMY_MEMORY (seen in game 2026-11-08: the
-- count on cleave dummies fell from 3 to 1 between AoE casts). One unreadable unit no longer voids the count.
S.ENEMY_MEMORY, S.DUMMY_MEMORY = 5, 12
S.seenEnemies = {}
S.lastCount = {}

-- "Training Dummy" in the client languages (dummies have no flag of their own; their names are stable).
local DUMMY_WORDS = { "dummy", "attrappe", "mannequin", "muñeco", "boneco", "manichino", "манекен", "假人",
  "木樁", "허수아비" }

function S.IsDummy(unit)
  local name = U.Get(UnitName, unit)
  if type(name) ~= "string" then
    return nil
  end
  name = name:lower()
  for _, w in ipairs(DUMMY_WORDS) do
    if name:find(w, 1, true) then
      return true
    end
  end
  return false
end

-- Training dummies often never show as in combat (Cleave Training Dummies, Dornogal, 2026-11-08: six dummies
-- being hit counted as 0), and cleave dummies refill their health at once, so neither flag nor health says we hit
-- them. While we are in combat, a dummy in range of our spells counts (they stand in tight groups for this).
local function HittingDummy()
  return S.combatStart ~= nil
end

S.RANGE_GRACE = 1.5 -- s an enemy we were fighting still counts after leaving range

-- Buffs that let cast-time spells be cast while moving, from our own cast (seconds, the data's duration first).
-- Found in the game's own spell descriptions ("cast while moving", "castable while moving", 12.0 dump): Spiritwalker's
-- Grace, Hover, Spatial Paradox. Channels the game marks usable while moving (Rapid Fire, Fists of Fury, Penance)
-- report no cast time, so they are never skipped in the first place.
S.MOVE_CASTS = { [79206] = 15, [358267] = 6, [406732] = 10 }
function S.CastsWhileMoving()
  local now = GetTime()
  for id, d in pairs(S.MOVE_CASTS) do
    local last = S.lastCast[id]
    local info = last and M.Info(id)
    if last and now - last < ((info and info.d and info.d > 0) and info.d or d) then
      return true
    end
  end
  return false
end

function S.CountEnemies()
  local probe = RangeProbe()
  local now = GetTime()
  local n, fighting, remembered, unknown, dummies, plates = 0, 0, 0, 0, 0, 0
  for i = 1, MAX_NAMEPLATES do
    local unit = "nameplate" .. i
    local exists = U.Get(UnitExists, unit)
    if exists == nil then
      unknown = unknown + 1
    elseif exists then
      plates = plates + 1
      local key = U.Get(UnitGUID, unit)
      key = type(key) == "string" and key or unit
      local hostile = U.Get(UnitCanAttack, "player", unit)
      local inCombat = U.Get(UnitAffectingCombat, unit)
      local dead = U.Get(UnitIsDead, unit)
      local inRange = probe and U.Get(C_Spell and C_Spell.IsSpellInRange, probe, unit)
      local seen = S.seenEnemies[key]
      local graced = inRange == false and seen and now - seen.t <= S.RANGE_GRACE
      if hostile == false or dead == true or (inRange == false and not graced) then
        S.seenEnemies[key] = nil -- not an enemy, dead, or someone else's fight far away
      elseif graced then
        -- just out of range while you move (Elemental walking among dummies: the count jumped 1..7 every
        -- tenth of a second, 2026-11-10): still in the fight for a moment
        n, remembered = n + 1, remembered + 1
        if seen.dummy then
          dummies = dummies + 1
        end
      elseif hostile and (inCombat or (S.combatStart and S.IsDummy(unit) and HittingDummy(unit))) then
        if not seen then
          seen = { dummy = S.IsDummy(unit) }
          S.seenEnemies[key] = seen
        end
        seen.t = now
        n, fighting = n + 1, fighting + 1
        if seen.dummy then
          dummies = dummies + 1
        end
      elseif seen and now - seen.t <= (seen.dummy and S.DUMMY_MEMORY or S.ENEMY_MEMORY) then
        n, remembered = n + 1, remembered + 1
        if seen.dummy then
          dummies = dummies + 1
        end
      elseif hostile == nil or inCombat == nil then
        unknown = unknown + 1
      end
    end
  end
  S.lastCount = { n = n, fighting = fighting, remembered = remembered, unknown = unknown, dummies = dummies,
    plates = plates }
  if n == 0 and unknown > 0 then
    return nil -- nothing readable about the nameplates that are up
  end
  return n
end

function S.ForgetEnemies()
  S.seenEnemies = {}
  if S.ForgetTargets then S.ForgetTargets() end
end

-- The spec's own AoE switch point, read from its priority list: the smallest target count at which it calls
-- or runs an AoE list ("run_action_list,name=aoe,if=spell_targets>=3" -> 3, "...>1" -> 2). nil if none.
local aoeCache = setmetatable({}, { __mode = "k" })
local AOE_TERMS = { "spell_targets[%w_%.]*", "active_enemies", "spell_targets" }

function S.SpecAoeTargets(record)
  if type(record) ~= "table" or type(record.simc) ~= "table" then
    return nil
  end
  if aoeCache[record] ~= nil then
    return aoeCache[record] or nil
  end
  local best
  for _, list in pairs(record.simc) do
    for _, e in ipairs(list) do
      local name = e.p and e.p.name
      if (e.a == "run_action_list" or e.a == "call_action_list") and type(name) == "string"
        and (name:find("aoe") or name:find("cleave"))
        and type(e.c) == "string" then
        for _, term in ipairs(AOE_TERMS) do
          for op, num in e.c:gmatch(term .. "%s*([>=]+)%s*(%d+)") do
            local n = tonumber(num)
            if op == ">" then
              n = n + 1
            end
            if n and n >= 2 and (not best or n < best) then
              best = n
            end
          end
        end
      end
    end
  end
  aoeCache[record] = best or false
  return best
end

-- Targets assumed in AoE mode: the spec's switch point (default), or DMGAssistDB.aoeTargets when the player
-- set "AoE target count" to Custom. 3 when the spec's list has no clear switch point.
function S.AoeTargets()
  local db = ns.db or {}
  if db.aoeCount == "custom" then
    return tonumber(db.aoeTargets) or 3
  end
  local state = ns.Specs and ns.Specs.current
  return S.SpecAoeTargets(state and state.data) or 3
end

-- The mode in force: hotkey override > auto (when enabled) > the primary mode.
function S.ActiveMode()
  if S.modeOverride then
    return S.modeOverride
  end
  local set = S.Settings()
  if set.autoDetect then
    return "auto"
  end
  return set.mode
end

-- Returns targets, label ("ST", "AOE", "AUTO 3", "ST?" = auto could not read, primary mode used).
-- Every timing lookup asks for the count (TimingKeys): reading all nameplates each time was a third of an update
-- with nothing castable. Inside one update pass (S.BeginPass .. S.EndPass) the first count is reused; outside a
-- pass, and in every new pass, it is read fresh, so a mode or settings change applies at once.
local targetsMemo = {}
local passSerial, inPass = 0, false
local CountTargets
function S.BeginPass()
  passSerial, inPass = passSerial + 1, true
end
function S.EndPass()
  inPass = false
end
function S.Targets()
  local m = targetsMemo
  if inPass and m.pass == passSerial then
    return m.n, m.label
  end
  local n, label = CountTargets()
  if inPass then
    m.pass, m.n, m.label = passSerial, n, label
  end
  return n, label
end
function S.ForgetTargets()
  targetsMemo.pass = nil
end

function CountTargets()
  local set = S.Settings()
  local mode = S.ActiveMode()
  if mode == "auto" then
    local n = S.CountEnemies()
    if n and n > 0 then
      return n, "AUTO " .. n
    end
    -- Nameplates are up but none counted (a dummy that never shows as in combat, out of range of the probe): the
    -- hostile target we are fighting is one enemy. Falling back to the AoE mode here ran Destruction's AoE list on
    -- a single dummy (2026-11-08). Only with no nameplates at all is the count truly unknown.
    if n == 0 and (S.lastCount.plates or 0) > 0 and S.combatStart and U.Get(UnitCanAttack, "player", "target") == true
      and U.Get(UnitIsDead, "target") ~= true then
      return 1, "AUTO 1"
    end
    -- Nothing counted (nameplates hidden, out of combat, or unreadable): the primary mode decides.
    if set.mode == "aoe" then
      return S.AoeTargets(), "AOE?"
    end
    return 1, "ST?"
  elseif mode == "aoe" then
    return S.AoeTargets(), "AOE"
  end
  return 1, "ST"
end

-- Hotkey: cycle AUTO -> ST -> AOE -> AUTO (or ST <-> AOE when auto-detect is off).
function S.CycleMode()
  local cur = S.ActiveMode()
  local nextMode
  if cur == "auto" then
    nextMode = "st"
  elseif cur == "st" then
    nextMode = "aoe"
  elseif S.Settings().autoDetect then
    nextMode = "auto"
  else
    nextMode = "st"
  end
  S.modeOverride = nextMode
  return nextMode
end

-- Fight length: your setting for bosses and encounters; in dungeons/raids trash dies fast, so cooldowns
-- aren't held for a long fight that won't happen. Open world (including target dummies) uses the setting.
S.inEncounter = false
local TRASH_FIGHT = 30
local SIMC_FIGHT = 300

-- Kind of fight, for the learned lengths: "boss" (encounter, boss or world boss target), "instance" (dungeon or
-- raid trash), "pvp" (battleground / arena), "world" (questing, grinding).
function S.FightContext()
  if S.inEncounter or U.Get(UnitIsBossMob, "target") == true or U.Get(UnitClassification, "target") == "worldboss" then
    return "boss"
  end
  local inInstance, kind = U.Call(IsInInstance)
  if U.Read(inInstance) == true then
    kind = U.Read(kind)
    if kind == "pvp" or kind == "arena" then
      return "pvp"
    end
    return "instance"
  end
  return "world"
end

-- Learned fight length: the median of this player's recent fights of the same kind (DMGAssistDB.fights, the
-- last 30 per kind, fights of 4 s or more). nil until there are 5.
local LEARN_KEEP, LEARN_MIN, LEARN_SHORTEST = 30, 5, 4
function S.LearnedFightLength(context)
  local g = ns.global or ns.db
  local list = g and type(g.fights) == "table" and g.fights[context]
  if type(list) ~= "table" or #list < LEARN_MIN then
    return nil
  end
  local sorted = {}
  for i, v in ipairs(list) do
    sorted[i] = v
  end
  table.sort(sorted)
  return sorted[math.floor((#sorted + 1) / 2)]
end

local function RecordFight(context, seconds)
  if not (ns.db and context and seconds >= LEARN_SHORTEST) then
    return
  end
  local g = ns.global or ns.db -- learned data is shared by every profile
  g.fights = type(g.fights) == "table" and g.fights or {}
  local list = g.fights[context] or {}
  g.fights[context] = list
  list[#list + 1] = math.floor(seconds + 0.5)
  while #list > LEARN_KEEP do
    table.remove(list, 1)
  end
end

-- Fight length for SimC's fight_remains / time_to_die. DMGAssistDB.fightMode:
--   "learned" (default): your own typical fight of this kind; SimC's defaults until 5 fights are recorded
--   "simc": SimC's 300 s for bosses, short for dungeon / raid trash
--   "custom": the slider's value (DMGAssistDB.fightLength) for every fight
function S.FightLength()
  local set = S.Settings()
  local db = ns.db or {}
  local mode = db.fightMode or "learned"
  if mode == "custom" then
    return set.fightLength
  end
  if mode == "learned" then
    local learned = S.LearnedFightLength(S.fightContext or S.FightContext())
    if learned then
      return learned
    end
  end
  -- SimC's default fight (Patchwerk, 300 s) for bosses and the open world; dungeon / raid trash is short, so
  -- cooldowns are not held for a 5-minute fight that ends in 30 s.
  local context = S.fightContext or S.FightContext()
  if context == "instance" and db.smartFight ~= false then
    return TRASH_FIGHT
  end
  return SIMC_FIGHT
end

---------------------------------------------------------------------------
-- Spell data helpers (SimC dump numbers, adjusted by haste where the game hastes them)
---------------------------------------------------------------------------
local lastHaste = 0
S.hasteSource = "default"

---------------------------------------------------------------------------
-- Haste boosts from the size of the jump: Bloodlust and its twins (+30%, 40 s), Power Infusion (+20%, 15 s).
-- The game tells us *when* haste changed (UNIT_SPELL_HASTE fires even when the value is hidden); the value itself,
-- or the next global cooldowns, tell us *how much*. Who cast it doesn't matter: your own Bloodlust and a shaman's
-- go through the same code. Our own tracked buffs are small next to these, and a jump has to hold for two global
-- cooldowns (or be read straight from the game) before it counts.
---------------------------------------------------------------------------
S.BOOSTS = {
  { kind = "lust", low = 1.25, high = 1.36, mult = 1.3, duration = 40 },
  { kind = "power_infusion", low = 1.16, high = 1.245, mult = 1.2, duration = 15 },
}
S.boost = {} -- kind -> { from, untilT, mult }
S.BOOST_TOKENS = { bloodlust = "lust", heroism = "lust", time_warp = "lust", primal_rage = "lust",
  fury_of_the_aspects = "lust", power_infusion = "power_infusion" }
local hasteChange -- { at, before, kind, seen } while a change waits to be measured

local function BoostOf(ratio)
  for _, b in ipairs(S.BOOSTS) do
    if ratio >= b.low and ratio <= b.high then
      return b
    end
  end
  return nil
end

-- Called with the new haste multiplier (1.3 = 30% haste), read or measured.
local function ClassifyHaste(factor, read)
  local now = GetTime()
  -- a drop of the boost's size while it runs: it ended early (dispelled, cancelled)
  if hasteChange and hasteChange.before then
    local drop = hasteChange.before / factor
    for kind, b in pairs(S.boost) do
      if math.abs(drop - b.mult) < 0.06 then
        S.boost[kind] = nil
        U.Log("haste_boost_end", { kind = kind, why = "dropped" })
        hasteChange = nil
        return
      end
    end
  end
  if not (hasteChange and hasteChange.before and now - hasteChange.at < 8) then
    return
  end
  local b = BoostOf(factor / hasteChange.before)
  if not b then
    hasteChange.kind, hasteChange.seen = nil, 0
    return
  end
  if hasteChange.kind == b.kind then
    hasteChange.seen = hasteChange.seen + 1
  else
    hasteChange.kind, hasteChange.seen = b.kind, 1
  end
  if (read or hasteChange.seen >= 2) and not S.boost[b.kind] then
    S.boost[b.kind] = { from = hasteChange.at, untilT = hasteChange.at + b.duration, mult = b.mult }
    U.Log("haste_boost", { kind = b.kind, ratio = string.format("%.2f", factor / hasteChange.before),
      how = read and "read" or "measured" })
    hasteChange = nil
  end
end

function S.OnHasteJump(before, after)
  if not S.combatStart then
    return -- out of combat the readable value just catches up after a fight; not a new boost
  end
  hasteChange = { at = GetTime(), before = before, seen = 0 }
  ClassifyHaste(after, true)
end

-- UNIT_SPELL_HASTE: haste changed (Bloodlust, a proc). If the value is readable we use it directly;
-- otherwise the next measured GCD updates it.
function S.OnHasteChanged()
  local now = GetTime()
  if not (hasteChange and now - hasteChange.at < 1) then
    hasteChange = { at = now, before = 1 + lastHaste / 100, seen = 0 }
  end
  local h = U.Get(UnitSpellHaste, "player")
  if type(h) == "number" then
    S.hasteSource = "read"
    S.HasteFactor() -- a jump, if any, is classified there (compared with the value before it)
  else
    S.hasteStale = true
  end
end

-- Remaining seconds of a detected boost (0 when none), and the boost ending: haste goes back down by its size
-- right away, instead of one global cooldown late.
-- The debuff Bloodlust leaves (Sated, Exhaustion, Temporal Displacement, Fatigued; 10 min, readable in combat):
-- applied less than 40 s ago means Bloodlust is up, with an exact end. Used when the haste jump wasn't seen.
S.LUST_DEBUFFS = { 57724, 57723, 80354, 264689, 390435 }
local function LustFromDebuff()
  for _, id in ipairs(S.LUST_DEBUFFS) do
    local d = S.DirectAura(id)
    if d and d.present and d.expires ~= math.huge then
      local left = 40 - (600 - (d.expires - GetTime()))
      if left > 0 then
        return left
      end
    end
  end
  return 0
end

-- Your own Bloodlust / Heroism / Time Warp / Primal Rage / Fury of the Aspects cast: the boost starts now, whatever
-- the game lets us read (haste was hidden for a whole fight when Primal Rage went unseen, 2026-11-09).
S.BOOST_CASTS = { [2825] = "lust", [32182] = "lust", [80353] = "lust", [264667] = "lust", [272678] = "lust",
  [390386] = "lust" }
function S.OnBoostCast(id)
  local kind = S.BOOST_CASTS[id]
  if not kind or S.boost[kind] or S.BoostRemains(kind) > 0 then
    return
  end
  for _, b in ipairs(S.BOOSTS) do
    if b.kind == kind then
      local now = GetTime()
      S.boost[kind] = { from = now, untilT = now + b.duration, mult = b.mult }
      if type(U.Get(UnitSpellHaste, "player")) ~= "number" then
        lastHaste = ((1 + lastHaste / 100) * b.mult - 1) * 100
      end
      hasteChange = nil
      U.Log("haste_boost", { kind = kind, how = "cast", id = id })
    end
  end
end

function S.BoostRemains(kind)
  if kind == "lust" and not S.boost.lust then
    local left = LustFromDebuff()
    if left > 0 then
      return left
    end
  end
  local b = S.boost[kind]
  if not b then
    return 0
  end
  local left = b.untilT - GetTime()
  if left <= 0 then
    S.boost[kind] = nil
    if type(U.Get(UnitSpellHaste, "player")) ~= "number" then
      lastHaste = ((1 + lastHaste / 100) / b.mult - 1) * 100
    end
    U.Log("haste_boost_end", { kind = kind, why = "expired" })
    return 0
  end
  return left
end

-- A measured 1.5s-base GCD (from the GCD's on/off edges, which are never secret) gives haste back.
function S.OnMeasuredGCD(seconds, base)
  if base ~= 1.5 or seconds < 0.74 or seconds > 1.6 then
    return
  end
  if type(U.Get(UnitSpellHaste, "player")) == "number" then
    return -- readable: no need to estimate
  end
  local h = (1.5 / seconds - 1) * 100
  if seconds <= 0.76 then
    return -- at the 0.75s floor haste can't be read off the GCD
  end
  lastHaste, S.hasteSource, S.hasteStale = h, "measured", false
  ClassifyHaste(1 + h / 100, false)
end

local function HasteFactor()
  for kind in pairs(S.boost) do
    S.BoostRemains(kind) -- a boost that ran out takes its haste with it
  end
  local h = U.Get(UnitSpellHaste, "player")
  if type(h) == "number" then
    if math.abs(h - lastHaste) > 1 then
      -- readable: compare with the value before the jump directly (the haste event can arrive after we've
      -- already read the new value, and then compared new with new: Primal Rage was missed, 2026-11-09)
      local before = 1 + lastHaste / 100
      lastHaste = h
      S.OnHasteJump(before, 1 + h / 100)
    end
    lastHaste = h
  end
  return 1 + lastHaste / 100
end
S.HasteFactor = HasteFactor

-- The game's own charge numbers for this character, by spell name (read out of combat, see S.Calibrate). By name,
-- because the spellbook's ID and the one the list uses can differ (Holy Shock 20473 / 25914): stored on the
-- book's ID, the engine never saw Holy Shock's second charge (2026-11-09).
S.liveCharges = {} -- token -> { max, recharge }
S.chargesLiveLogged = {}

local function Live(info)
  return info and info.n and S.liveCharges[info.n] or nil
end

local function MaxCharges(info)
  local l = Live(info)
  return (l and l.max) or info.chLive or info.ch or 1
end

local function DataCooldown(id)
  local info = M.Info(id)
  if not info then
    return nil
  end
  -- A charge spell's recharge is its real cooldown: Celestial Alignment is "cd 1, 1 charge, 180 s recharge",
  -- Eclipse "cd 1, 1 charge, 32 s recharge" (the 1 s is only the minimum between uses).
  local live = Live(info)
  local cd = math.max(info.cd or 0, (live and live.recharge) or info.chcd or 0)
  if cd <= 0 then
    return nil
  end
  if info.hc then
    cd = cd / HasteFactor()
  end
  return cd
end

-- The game's own base cooldown (static spell data, readable even in combat): racials and other spells our data
-- doesn't carry (Ancestral Call: 120 s). Milliseconds; GCD-only spells report 0.
local baseCd = {}
local function BaseCooldown(id)
  local v = baseCd[id]
  if v == nil then
    local ms = U.Get(GetSpellBaseCooldown, id)
    v = (type(ms) == "number" and ms > 1500) and ms / 1000 or false
    baseCd[id] = v
  end
  return v or nil
end

-- What this character's casts showed this session (seconds): a spell cast again sooner than our data's cooldown
-- allows proves the real cooldown is shorter (level, talents, haste: Holy's Judgment is 11 s in SimC's data and
-- came back every 6 s on a level 27 paladin, 2026-11-09). The latest sample wins, so a one-off reset doesn't stick.
-- Samples are kept at no haste for spells whose cooldown scales with it (seen x haste), and scaled back by the
-- haste we have now: a Judgment learned under Bloodlust is longer again once Bloodlust ends.
local function Hasted(info)
  local live = info and info.n and S.liveCharges and S.liveCharges[info.n]
  return info and (info.hc or (live and live.hasted)) and HasteFactor() or 1
end

-- Learned timing correction for a spell (seconds, + = it really takes longer than our clock): see "Timing
-- learning" below. Applied while the spell's measurements agree with each other.
-- Kept apart for 1-2 and 3+ targets: many cooldown effects come per target hit or per proc on any target
-- (Sentinel's Mark taking time off Wildfire Bomb), so a 5-dummy pull and a boss learn different numbers.
S.AOE_BAND = 3
local function TimingKeys(id)
  local info = M.Info(id)
  local name = info and info.n or M.TokenForID(id)
  if not name then
    return nil, nil
  end
  local aoe = name .. "@aoe"
  if (S.Targets() or 1) >= S.AOE_BAND then
    return aoe, name, name
  end
  return name, aoe, name
end
S.TimingKeys = TimingKeys

-- The record that applies now: this target band's, or the other band's while this one has nothing yet.
local function AppliedRecord(id)
  local key, other = TimingKeys(id)
  local all = S.learned and S.learned.timing
  if not (key and all) then
    return nil
  end
  local t = all[key]
  if t and (t.n or 0) >= 1 then
    return t
  end
  t = all[other]
  return (t and (t.n or 0) >= 1) and t or nil
end

local function Offset(id, base)
  local t = AppliedRecord(id)
  -- a spell left to Blizzard (flagged by its spread, or shipped volatile) keeps its mean but doesn't use it
  if not (t and base) or S.ClockUnreliable(id) then
    return 0
  end
  return math.max(-0.6 * base, math.min(0.6 * base, t.mean or 0))
end
S.TimingOffset = Offset

-- The cooldown the game's own tooltip shows ("1 min cooldown"), talents included: SimC's data has the base (Convoke
-- the Spirits 120 s; with the player's talents the tooltip said 1 min and we never showed it again, 2026-11-10).
-- Read out of combat only (in combat tooltip text can be hidden), matched with the game's own localized wording
-- (SPELL_RECAST_TIME_MIN / _SEC: any client language), cached until talents or gear change.
local tipCd = {}
local function RecastPattern(fmt)
  if type(fmt) ~= "string" or fmt == "" then
    return nil
  end
  local p = fmt:gsub("%%[sd]", "\1")
  p = p:gsub("[%(%)%.%+%-%*%?%[%]%^%$]", "%%%0")
  return "^%s*" .. p:gsub("\1", "([%%d%%.,]+)") .. "%s*$"
end

function S.TooltipCooldown(id)
  local v = tipCd[id]
  if v ~= nil then
    return v or nil
  end
  if S.combatStart or U.Get(InCombatLockdown) == true or not (C_TooltipInfo and C_TooltipInfo.GetSpellByID) then
    return nil
  end
  local data = U.Read((U.Call(C_TooltipInfo.GetSpellByID, id)))
  v = false
  if type(data) == "table" and type(data.lines) == "table" then
    local units = { { RecastPattern(_G.SPELL_RECAST_TIME_MIN), 60 }, { RecastPattern(_G.SPELL_RECAST_TIME_SEC), 1 } }
    for _, line in ipairs(data.lines) do
      for _, side in ipairs({ U.Read(line.rightText), U.Read(line.leftText) }) do
        if type(side) == "string" then
          for _, u in ipairs(units) do
            local n = u[1] and side:match(u[1])
            n = n and tonumber((n:gsub(",", ".")))
            if n and n > 0 then
              v = n * u[2]
              break
            end
          end
        end
        if v then
          break
        end
      end
      if v then
        break
      end
    end
  end
  tipCd[id] = v
  return v or nil
end

local function CooldownLength(id)
  local base = S.learned.cd[id] or S.TooltipCooldown(id) or DataCooldown(id) or BaseCooldown(id)
  if base then
    return math.max(0.5, base + Offset(id, base))
  end
  return nil
end
S.CooldownLength = CooldownLength

local function AuraLength(token, auraID)
  local l = S.learned.aura[token]
  if l and l.duration then
    return l.duration
  end
  local info = auraID and M.Info(auraID)
  if info and info.d and info.d > 0 then
    return info.d
  end
  -- the token's own aura IDs, then its aliases' (buff.eclipse -> the Lunar / Solar Eclipse buffs)
  for _, t in ipairs(M.Candidates(token)) do
    for _, id in ipairs(M.AuraIDs(t) or {}) do
      local i = M.Info(id)
      if i and i.d and i.d > 0 then
        return i.d
      end
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Cooldowns
---------------------------------------------------------------------------
local function CooldownInfo(id)
  local info = U.Get(C_Spell and C_Spell.GetSpellCooldown, id)
  if type(info) ~= "table" then
    return nil
  end
  return info
end

local function LearnCooldown(id, info)
  info = info or CooldownInfo(id)
  if not info then
    return
  end
  local dur, onGCD = U.Read(info.duration), U.Read(info.isOnGCD)
  if type(dur) == "number" and dur > 1.6 and onGCD ~= true then
    S.learned.cd[id] = dur
  end
end

function S.CooldownRemains(id)
  local charged = S.ChargeRemains(id)
  if charged then
    return charged
  end
  if V and V.cd[id] then
    return math.max(0, V.cd[id] - Now())
  end
  local info = CooldownInfo(id)
  if not info then
    return UNKNOWN
  end
  local active, onGCD = U.Read(info.isActive), U.Read(info.isOnGCD)
  if active == false or onGCD == true then
    return 0
  end
  local start, dur = U.Read(info.startTime), U.Read(info.duration)
  if type(start) == "number" and type(dur) == "number" then
    return math.max(0, start + dur - Now())
  end
  local last, length = S.lastCast[id], CooldownLength(id)
  if last and length then
    local left = length - (Now() + (V and V.cdShift[id] or 0) - last)
    if left > 0 then
      return left
    end
    if not V then
      -- Our clock says ready, the game says active: out of sync (cooldown reduction, haste, reset).
      S.drift[id] = (S.drift[id] or 0) + 1
    end
  end
  return UNKNOWN
end

---------------------------------------------------------------------------
-- Charges: counted from our casts (C_Spell.GetSpellCharges when readable). The cooldown API calls a charge
-- spell with charges left "not on cooldown", and IsSpellUsable ignores charges, so without this a spent
-- Eclipse looked ready (seen in game 2026-11-08). Spells that share charges (Lunar / Solar Eclipse) are
-- one group: the smallest charge-spell ID among the priority-list entries that contain them.
---------------------------------------------------------------------------
S.chargeUse = {}   -- group -> { recharge end times, oldest first }
local chargeGroup  -- id -> group (built lazily per data set)

local function ChargeInfo(id)
  local info = M.Info(id)
  if info and (info.ch or info.chLive or Live(info)) and ((info.chcd or 0) > 0 or (Live(info) or {}).recharge) then
    return info
  end
  return nil
end

local function GroupOf(id)
  if not chargeGroup or chargeGroup.data ~= M.data then
    chargeGroup = { data = M.data, map = {} }
    for _, e in pairs(M.data or {}) do
      local ids = type(e) == "table" and e.a
      if ids then
        local low
        for _, i in ipairs(ids) do
          if ChargeInfo(i) and (not low or i < low) then
            low = i
          end
        end
        if low then
          for _, i in ipairs(ids) do
            if ChargeInfo(i) and (not chargeGroup.map[i] or low < chargeGroup.map[i]) then
              chargeGroup.map[i] = low
            end
          end
        end
      end
    end
  end
  return chargeGroup.map[id] or id
end

local function PendingRecharges(group, at)
  local list = S.chargeUse[group]
  if not list then
    return {}
  end
  while list[1] and list[1] <= GetTime() do
    table.remove(list, 1)
  end
  local out = {}
  for _, t in ipairs(list) do
    if t > at then
      out[#out + 1] = t
    end
  end
  return out
end

-- Charges available now (or at the look-ahead moment), or nil for a spell without charges.
function S.Charges(id)
  local info = ChargeInfo(id)
  if not info then
    return nil
  end
  local group = GroupOf(id)
  local n = MaxCharges(info) - #PendingRecharges(group, Now() + (V and V.cdr[group] or 0))
  -- The game's count, unless our own casts say fewer are left: in restricted combat it reported an Eclipse charge
  -- 2 s after the only one was spent (Balance, 2026-11-08). The same rule as cooldowns. Also while looking ahead:
  -- ignoring it there showed Mind Blast in slot 1 with no charge left (Shadow, 2026-11-08).
  local c = U.Get(C_Spell and C_Spell.GetSpellCharges, id)
  local cur = type(c) == "table" and U.Read(c.currentCharges)
  if type(cur) == "number" then
    -- The game's own count for the exact ID the engine uses: the truth, both ways (a charge back sooner than our
    -- clock says counts too). Logged once per spell so a report shows it's readable.
    if S.combatStart and not S.chargesLiveLogged[id] then
      S.chargesLiveLogged[id] = true
      U.Log("charges_live", { spell = info.n, current = cur })
    end
    -- Right after a cast the game's count can still include the charge just spent (Balance's Eclipse): a higher
    -- count than ours is taken only from half a second after our last spend of it.
    if cur < n or GetTime() - (S.chargeSpentAt[group] or 0) > 0.5 then
      n = cur
    end
  end
  if V and V.castCount then
    -- every predicted cast in the look-ahead spends a charge (Mind Blast was shown three times in a row)
    for castID, count in pairs(V.castCount) do
      if GroupOf(castID) == group then
        n = n - count
      end
    end
  end
  return math.max(0, n)
end

-- Blizzard's assistant names a charge spell that our count says is empty, with its recharge still well off:
-- the character has a charge more than we know (talents). Twice in a row, half a second apart, before casting it,
-- and we add one. Logged, so a report shows it.

-- Seconds until a charge is available (0 with one ready), or nil for a spell without charges.
function S.ChargeRemains(id)
  local c = S.Charges(id)
  if c == nil then
    return nil
  end
  if c > 0 then
    return 0
  end
  local shift = V and V.cdr[GroupOf(id)] or 0
  local pending = PendingRecharges(GroupOf(id), Now() + shift)
  if pending[1] then
    return math.max(0, pending[1] - Now() - shift)
  end
  return nil -- the game says none left but we saw no cast: unknown, fall back to the cooldown API
end

-- Seconds one charge takes to come back: this session's casts, the game's own number (read out of combat), our data.
local function RechargeLength(group, info)
  local live = Live(info)
  local base = (live and live.recharge and live.recharge / ((live.hasted and HasteFactor()) or 1))
    or info.chcd / Hasted(info)
  return math.max(0.5, base + Offset(group, base))
end

---------------------------------------------------------------------------
-- Timing learning. Every spell's clock is checked against what really happened, from both sides:
--   our clock was late  - Blizzard's assistant names it, or you cast it, while our clock says it isn't back yet
--   our clock was early - we showed it ready, you waited (cast nothing else), and cast it later
-- Each measurement (seconds: + = really takes longer) goes into a running average and a running spread, per spell,
-- saved in DMGAssistDB per class and spec, so every character of that spec starts with it:
--   steady errors (a talent or gear we didn't account for) -> the average corrects our clock (Offset above)
--   scattered errors (cooldowns that move with effects we can't see) -> "Blizzard decides": slot 1 calls the
--     spell ready only when Blizzard's assistant names it; un-flagged again after it agrees with our clock 4 times
-- The list shipped with each update (M.volatile, from the weekly import) starts known-erratic spells flagged.
-- Settings > DMGAssist > "Forget learned timing" clears it all.
---------------------------------------------------------------------------
S.ASSISTED_EARLY = 1.5   -- Blizzard names a spell about this long before it is back: not counted as our error
S.ASSISTED_LEAD = 2.5    -- Blizzard naming a spell this far ahead of our clock: our clock is wrong (closer: just early)
S.SPREAD_UNRELIABLE = 1.5 -- running spread above this after 3+ measurements: erratic -> Blizzard decides
S.AGREE_TO_TRUST = 4     -- agreements with our clock that un-flag a spell
S.timingLogged = 0

-- This target band's record (created on the first measurement); name = the spell's token.
local function TimingRecord(id, create)
  local key, _, name = TimingKeys(id)
  if not key then
    return nil, nil
  end
  S.learned.timing = S.learned.timing or {}
  local t = S.learned.timing[key]
  if not t and create then
    t = { n = 0, mean = 0, spread = 0, agree = 0 }
    S.learned.timing[key] = t
  end
  return t, name, key
end

function S.ClockUnreliable(id)
  local t, name = TimingRecord(id, false)
  if not (t and t.unreliable ~= nil) then
    t = AppliedRecord(id)
  end
  if t and t.unreliable ~= nil then
    return t.unreliable == true
  end
  if name and S.learned.unreliable and S.learned.unreliable[name] then -- saved by 1.6.0.120
    return true
  end
  return name ~= nil and M.volatile ~= nil and M.volatile[name] == true
end

-- One measurement for a spell: err = real ready time - our ready time (seconds).
function S.LearnTiming(id, err, how)
  if type(err) ~= "number" or err ~= err or math.abs(err) > 30 then
    return
  end
  -- err is measured against our clock as it runs now, correction included: what's left over. The total
  -- correction the spell needs is the one applied plus that.
  local applied = AppliedRecord(id)
  applied = (applied and not applied.unreliable) and (applied.mean or 0) or 0
  local t, name, key = TimingRecord(id, true)
  if not t then
    return
  end
  local sample = applied + err
  -- never beyond what the correction can be (60% of the cooldown): a broken signal can't run away with it
  local info = M.Info(id)
  local base = info and (info.chcd or info.cd)
  if type(base) == "number" and base > 0 then
    sample = math.max(-0.6 * base, math.min(0.6 * base, sample))
  end
  t.n = (t.n or 0) + 1
  local a = t.n < 4 and 1 / t.n or 0.3
  t.mean = (t.mean or 0) + a * (sample - (t.mean or 0))
  t.spread = (t.spread or 0) + a * (math.abs(sample - t.mean) - (t.spread or 0))
  name = key or name
  local was = S.ClockUnreliable(id)
  if t.n >= 3 and t.spread > S.SPREAD_UNRELIABLE and not was then
    t.unreliable, t.agree = true, 0
    U.Log("clock_unreliable", { spell = name, spread = string.format("%.1f", t.spread) })
  end
  if S.timingLogged < 30 then
    S.timingLogged = S.timingLogged + 1
    U.Log("timing_learned", { spell = name, how = how, err = string.format("%.1f", err),
      mean = string.format("%.1f", t.mean), spread = string.format("%.1f", t.spread), n = t.n })
  end
end

-- Seconds until our clock says the spell is back (0 = ready by our clock), ignoring the look-ahead.
local function OurLeft(id, info)
  if info then
    if (S.Charges(id) or 0) > 0 then
      return 0
    end
    local r = S.ChargeRemains(id)
    return type(r) == "number" and r or nil
  end
  local last, length = S.lastCast[id], CooldownLength(id)
  if length then
    if not last then
      return 0 -- never cast: ready as far as we know
    end
    return math.max(0, length - (GetTime() - last))
  end
  return nil
end

S.ASSISTED_STALE = 1.5
-- Blizzard's assistant names this spell right now (called once per decision).
function S.ObserveAssistedCharge(id)
  -- Once each time Blizzard starts naming it, not every frame it keeps naming it: right after a correction our
  -- clock agrees for as long as Blizzard keeps naming the spell, which isn't news (1.6.0.124 counted every frame
  -- and un-flagged Wildfire Bomb within a second of flagging it).
  if S.acNamed == id then
    return
  end
  -- Still naming what you just cast is the assistant catching up, not "ready again": right after each Eternity
  -- Surge / Fire Breath (empowered: released a moment after the press) it was taken as "our clock is 10-28 s
  -- slow", the cooldown was marked done, and slot 2 showed key 5 for most of its 30 s (Devastation, 2026-11-11).
  -- (With 2+ charges a charge is left, so naming it again right away is true: Aimed Shot.)
  local token = M.TokenForID(id)
  local castAt = (token and S.lastCastToken[token]) or S.lastCast[id]
  local ci = M.Info(id)
  local multi = ci and ci.ch and ci.ch > 1
  if castAt and not multi and GetTime() - castAt < S.ASSISTED_STALE then
    return
  end
  S.acNamed = id
  S.notBefore[id] = nil -- Blizzard says it's ready: any refusal hold is over
  local info = ChargeInfo(id)
  local left = OurLeft(id, info)
  if type(left) ~= "number" then
    return
  end
  local t, name = TimingRecord(id, false)
  if left <= 0.75 then
    -- our clock agrees with the game
    if S.ClockUnreliable(id) then
      t = t or select(1, TimingRecord(id, true))
      t.agree = (t.agree or 0) + 1
      if t.agree >= S.AGREE_TO_TRUST then
        -- keep what was learned; the scatter starts over
        t.unreliable, t.spread, t.agree = false, 0, 0
        if S.learned.unreliable and name then
          S.learned.unreliable[name] = nil
        end
        U.Log("clock_trusted", { spell = name })
      end
    end
    return
  end
  if left <= S.ASSISTED_LEAD then
    return -- a moment early: Blizzard may simply be naming what comes next
  end
  if t then
    t.agree = 0
  end
  local now = GetTime()
  -- Learn only from a clock this fight's own cast started: at the pull our clock still runs from a cast before
  -- combat (and the cooldown cuts other spells gave it since), so the gap says nothing about the cooldown. Holy
  -- Judgment learned 4.5 s too short from one such sample and was shown 3 s after every cast (2026-11-10).
  -- Blizzard also names a spell a little before it is back (Holy Shock named 1.6 s before the game took it):
  -- that part isn't our clock's error.
  local last = S.lastCast[id]
  local fresh = last ~= nil and S.combatStart ~= nil and last >= S.combatStart
  if fresh then
    S.LearnTiming(id, -(left - S.ASSISTED_EARLY), "assisted")
  end
  -- and it's ready now: one charge back, or the cooldown done
  if info then
    local list = S.chargeUse[GroupOf(id)]
    if list and list[1] then
      local early = list[1] - now
      for i = 1, #list do
        list[i] = list[i] - early
      end
      table.remove(list, 1)
    end
  else
    S.lastCast[id] = now - (CooldownLength(id) or 0)
  end
  U.Log("assisted_ready", { spell = name, ours = string.format("%.1f", left), learned = fresh or nil })
end

-- The display shows a spell ready in slot 1 (the flash): if you then wait and cast it later with nothing in
-- between, our clock was early by that wait (minus a reaction allowance).
S.REACTION = 0.4
function S.NoteReadyShown(id)
  if not (S.readyShown and S.readyShown.id == id) then
    S.readyShown = { id = id, t = GetTime() }
  end
end

-- Pressing the button before it's ready (the "2222" style): each press the game refuses arrives as
-- UNIT_SPELLCAST_FAILED. When it finally goes through while you are still pressing, that moment IS when it came
-- back, to within one press: compared with when slot 1 showed it ready, our clock's error in both directions,
-- measured exactly, within seconds. Unless the global cooldown, not the spell, was what held it.
S.PRESS_GAP = 0.6     -- presses closer together than this count as pressing until it goes through
S.pressed = {}        -- spell -> { first, last, n } refused presses
function S.RefusedHold(id)
  local t = S.notBefore[id] or (M.baseOf and M.baseOf[id] and S.notBefore[M.baseOf[id]])
  return t ~= nil and GetTime() < t
end
S.notBefore = {}     -- spell -> not ready before this time: the game refused it while our clock said ready
S.REFUSE_HOLD = { 0.5, 1, 2, 3 } -- seconds held, by refused presses in a row

-- Cooldowns our data doesn't have (Void Volley only exists inside Voidform, so the game never shows its cooldown
-- out of combat, where we learn the others): learned from the game refusing it. A refusal counts only when the
-- game says why: "not ready yet" (ERR_SPELL_COOLDOWN / ERR_ABILITY_COOLDOWN), outside the global cooldown, and
-- not for lack of resources, range or facing. Each one is a lower bound (it has a cooldown at least that long
-- after our cast); pressing until it goes through measures it.
S.cdRefusal = {}        -- spell -> { after = our cast it followed, bound = s since that cast, at = time }
S.REFUSED_MARGIN = 1    -- not ready until this long past the longest refusal
S.REFUSAL_PAIR = 0.25   -- the failed cast and its error message arrive this close together
local lastFailed, lastCooldownError = nil, nil
local function NoteCooldownRefusal(id, t)
  if ChargeInfo(id) or CooldownLength(id) then
    return -- known cooldowns: the refused-press hold and the timing learning handle those
  end
  local last = S.lastCast[id]
  if not last or last < (S.combatStart or 0) - 3 or t - last <= 1.6 then
    return
  end
  local r = S.cdRefusal[id]
  if not r or r.after ~= last then
    r = { after = last, bound = 0 }
    S.cdRefusal[id] = r
  end
  r.bound, r.at = math.max(r.bound, t - last), t
end
S.NoteCooldownRefusal = NoteCooldownRefusal

local function IsCooldownError(msg)
  return type(msg) == "string" and ((ERR_SPELL_COOLDOWN and msg == ERR_SPELL_COOLDOWN)
    or (ERR_ABILITY_COOLDOWN and msg == ERR_ABILITY_COOLDOWN))
end
-- Any other reason the game gives (not enough Energy, out of range, facing) means the spell IS ready: the
-- refused-press hold is for cooldowns only. Feral pressing Rake a moment before the Energy was there got Rake
-- held and Swipe put in slot 1, again and again (2026-11-10).
local lastOtherError = nil
function S.OnUIError(_, msg)
  if type(msg) == "string" and not IsCooldownError(msg) then
    local now = GetTime()
    lastOtherError = now
    local f = lastFailed
    if f and now - f.t <= S.REFUSAL_PAIR and f.held then
      S.notBefore[f.id] = f.prevHold -- undo the hold this refusal set
      local p = S.pressed[f.id]
      if p then
        p.refusedInRow = f.prevRow
      end
      f.held = nil
    end
    return
  end
  if not IsCooldownError(msg) then
    return
  end
  local now = GetTime()
  lastCooldownError = now
  local f = lastFailed
  if f and not f.used and now - f.t <= S.REFUSAL_PAIR and f.offGCD then
    f.used = true
    NoteCooldownRefusal(f.id, f.t)
  end
end

-- A success right after refusals of a spell with no known cooldown: the time since our last cast is its cooldown
-- (to within a press). Learned for good, like the ones read out of combat.
local function LearnFromRefusals(id, now)
  local r = S.cdRefusal[id]
  S.cdRefusal[id] = nil
  if not r or r.after ~= S.lastCast[id] or CooldownLength(id) then
    return
  end
  local gap = now - r.after
  if r.at and now - r.at <= S.PRESS_GAP * 2 and gap > 1.6 and gap < 600 then
    S.learned.cd[id] = math.floor(gap * 2 + 0.5) / 2
    U.Log("cd_learned", { spell = M.TokenForID(id), cd = S.learned.cd[id], from = "refusals" })
  end
end
S.LearnFromRefusals = LearnFromRefusals

function S.OnCastFailed(id)
  id = U.Read(id)
  if type(id) ~= "number" or not S.combatStart then
    return
  end
  local now = GetTime()
  local offGCD = (S.GCDRemains() or 0) <= 0.05
  local p0 = S.pressed[id]
  lastFailed = { id = id, t = now, offGCD = offGCD, prevHold = S.notBefore[id], prevRow = p0 and p0.refusedInRow }
  if offGCD and lastCooldownError and now - lastCooldownError <= S.REFUSAL_PAIR then
    lastFailed.used = true
    NoteCooldownRefusal(id, now)
  end
  local otherReason = lastOtherError ~= nil and now - lastOtherError <= S.REFUSAL_PAIR
  -- Refused outside the global cooldown while our clock calls it ready: it isn't, right now. Hold it back so slot 1
  -- moves on to what you can press, longer with each refusal, until Blizzard names it or the hold runs out.
  if offGCD and not otherReason then
    lastFailed.held = true
    local left = OurLeft(id, ChargeInfo(id))
    if left == nil or left <= 0.3 then
      local k = (p0 and now - p0.last <= 2) and math.min(#S.REFUSE_HOLD, (p0.refusedInRow or 0) + 1) or 1
      S.notBefore[id] = now + S.REFUSE_HOLD[k]
      if p0 and now - p0.last <= 2 then
        p0.refusedInRow = k
      end
    end
  end
  local p = S.pressed[id]
  if not p or now - p.last > 2 then
    p = { first = now, last = now, n = 0, refusedInRow = S.notBefore[id] and S.notBefore[id] > now and 1 or 0 }
    S.pressed[id] = p
  end
  p.last, p.n = now, p.n + 1
  local gcd = S.GCDRemains() or 0
  p.gcdEnd = gcd > 0.05 and now + gcd or nil -- refused because of the global cooldown: it ends then
end

-- true when this cast came out of pressing it until it went through (measured here; skip the "waited" guess)
local function CheckPressed(id, r)
  local base = M.baseOf and M.baseOf[id] or id
  S.notBefore[id], S.notBefore[base] = nil, nil
  local p = S.pressed[id] or S.pressed[base]
  S.pressed[id], S.pressed[base] = nil, nil
  local now = GetTime()
  if not (p and now - p.last <= S.PRESS_GAP and S.combatStart) then
    return false
  end
  if not (ChargeInfo(id) or CooldownLength(id)) or S.ClockUnreliable(id) then
    return true
  end
  local shownAt = r and (r.id == id or r.id == base) and r.t or nil
  local heldByGCD = p.gcdEnd ~= nil and math.abs(now - p.gcdEnd) < 0.15
  local err
  if shownAt then
    -- slot 1 showed it ready at shownAt, the game let it go at now: our clock was early by the difference
    err = now - shownAt - (ns.Display and ns.Display.Latency and ns.Display.Latency() or 0)
    if heldByGCD or err < 0.2 then
      err = nil -- the GCD held it, or we agree to within a press
    end
  end
  if err then
    S.LearnTiming(id, err, "pressed")
  end
  if p.n >= 2 and S.pressLogged < 20 then
    S.pressLogged = S.pressLogged + 1
    U.Log("pressed_until_ready", { spell = TimingKeys(id), presses = p.n,
      pressing = string.format("%.1f", now - p.first),
      shown = shownAt and string.format("%.1f", now - shownAt) or "no", gcd = heldByGCD and 1 or 0 })
  end
  return true
end
S.pressLogged = 0

local function CheckWaited(id)
  local r = S.readyShown
  S.readyShown = nil
  if CheckPressed(id, r) then
    return
  end
  if not (r and S.combatStart) then
    return
  end
  local base = M.baseOf and M.baseOf[id] or id
  if r.id ~= id and r.id ~= base then
    return
  end
  local waited = GetTime() - r.t - S.REACTION
  if waited > 0.4 and waited < 8 and (ChargeInfo(id) or CooldownLength(id)) and not S.ClockUnreliable(id) then
    S.LearnTiming(id, waited, "waited")
  end
end

S.chargeSpentAt = {} -- group -> time of the last spend

-- Spell interdependencies (M.linksBySource / M.linksBySpend, from the game's spell descriptions): casting X
-- takes N seconds off Y, resets Y, gives a charge of Y, or takes N seconds per resource point X spent.
-- For real casts the clocks move; while looking ahead the look-ahead's shift does (V.cdr / V.cdShift).
local talentKnown = {}
local function Requires(req)
  if not req or req == 0 then
    return true
  end
  local k = talentKnown[req]
  if k == nil then
    k = U.Get(IsPlayerSpell, req) == true
    if not k then
      -- a set bonus is an aura on the player, not a known spell
      local a = S.DirectAura and S.DirectAura(req)
      k = type(a) == "table" and a.present == true
    end
    talentKnown[req] = k
  end
  return k
end
function S.ForgetTalentCache()
  talentKnown = {}
  tipCd = {}
  S.rotationSpells = nil
end

-- The spells Blizzard's assistant can ever suggest for this spec and talents (C_AssistedCombat.GetRotationSpells).
-- A spell outside that list (Stealth, most big cooldowns) can't be handed to Blizzard: we keep our own clock for it.
function S.BlizzardCanName(id)
  local set = S.rotationSpells
  if not set then
    set = {}
    local list = U.Call(C_AssistedCombat and C_AssistedCombat.GetRotationSpells)
    if type(list) == "table" then
      for _, sid in ipairs(list) do
        sid = U.Read(sid)
        if type(sid) == "number" then
          set[sid] = true
        end
      end
    end
    if next(set) then
      S.rotationSpells = set -- empty: not loaded yet, ask again next time
    end
  end
  if set[id] then
    return true
  end
  local base = M.baseOf and M.baseOf[id]
  return base ~= nil and set[base] == true
end

-- Slot 1 follows Blizzard for this spell: our clock is known wrong, and Blizzard can name it.
function S.BlizzardLeads(id)
  return S.ClockUnreliable(id) and S.BlizzardCanName(id)
end

local function ReduceTarget(token, amount, lookahead)
  local tid = M.SpellID(token)
  if not tid then
    return
  end
  local full = amount == "reset" or amount == "charge"
  local info = ChargeInfo(tid)
  if info then
    local group = GroupOf(tid)
    if lookahead then
      V.cdr[group] = (V.cdr[group] or 0) + (full and RechargeLength(group, info) or amount)
      return
    end
    local list = S.chargeUse[group]
    if not list or not list[1] then
      return
    end
    if amount == "reset" then
      S.chargeUse[group] = {}
    elseif amount == "charge" then
      table.remove(list, 1)
    else
      for i = 1, #list do
        list[i] = list[i] - amount
      end
      if S.chargeSpentAt[group] then
        S.chargeSpentAt[group] = S.chargeSpentAt[group] - amount
      end
    end
    return
  end
  local length = CooldownLength(tid) or 0
  if lookahead then
    V.cdShift[tid] = (V.cdShift[tid] or 0) + (full and length or amount)
    if V.cd[tid] then
      V.cd[tid] = V.cd[tid] - (full and length or amount)
    end
    return
  end
  local last = S.lastCast[tid]
  if last then
    S.lastCast[tid] = full and (last - length) or (last - amount)
  end
end

function S.ApplyLinks(id, lookahead)
  local info = M.Info(id)
  local token = (info and info.n) or M.TokenForID(id)
  if not token or not M.linksBySource then
    return
  end
  for _, l in ipairs(M.linksBySource[token] or {}) do
    if Requires(l[4]) then
      local amount = l[3]
      if l[6] and type(amount) == "number" and amount > 0 then
        -- per enemy hit, up to a cap (Lethal Calibration: 2 s per enemy hit, up to 10 s): our enemy count
        local n = (S.Targets()) or 1
        amount = math.min(amount * math.max(1, n), l[6])
      end
      ReduceTarget(l[2], amount, lookahead)
    end
  end
  local cost = M.Cost(info)
  for pt, list in pairs(M.linksBySpend) do
    local spent = cost and cost[pt]
    if spent and info.cmax and info.cmax[pt] then
      spent = info.cmax[pt] -- a finisher: assume a full spend (the usual case)
    end
    if spent and spent > 0 then
      for _, l in ipairs(list) do
        if Requires(l[4]) and type(l[3]) == "number" then
          ReduceTarget(l[2], l[3] * spent, lookahead)
        end
      end
    end
  end
end

local function OnChargeSpent(id)
  local info = ChargeInfo(id)
  if not info then
    return
  end
  local group = GroupOf(id)
  local list = S.chargeUse[group] or {}
  S.chargeUse[group] = list
  PendingRecharges(group, GetTime())
  local now, max = GetTime(), MaxCharges(info)
  -- The cast itself proves a charge was there: if our clock had none left, our recharge time is too long.
  if #list >= max then
    -- the recharge that should have finished first started (its end - our recharge length) ago: that's how long
    -- it really took (one-charge and multi-charge spells alike)
    local early = list[1] - now
    if early > 0.3 then
      S.LearnTiming(id, -early, "cast") -- you cast it: it was back that much before our clock said
    end
    for i = 1, #list do
      list[i] = list[i] - early
    end
    table.remove(list, 1)
  end
  S.chargeSpentAt[group] = now
  local from = list[#list] or now -- one charge recharges at a time
  list[#list + 1] = math.max(from, now) + RechargeLength(group, info)
end

-- A plain cooldown cast again sooner than our clock allows: our clock was late by the difference.
local function OnCooldownSpent(id)
  if ChargeInfo(id) then
    return
  end
  local last, length = S.lastCast[id], CooldownLength(id)
  if last and length and S.combatStart and last >= S.combatStart - 3 then
    local early = length - (GetTime() - last)
    if early > 0.3 and length > 1.6 then
      S.LearnTiming(id, -early, "cast")
    end
  end
end

-- Ready by our own clock (last cast + cooldown length): true / false, or UNKNOWN without a cast this fight.
function S.OwnClockReady(id)
  local last, length = S.lastCast[id], CooldownLength(id)
  if last and not length and last >= (S.combatStart or 0) - 3 then
    -- No cooldown in our data, but the game said "not ready yet" this long after our cast: it has one, at least
    -- that long. Not ready until a little past it (each new refusal moves it on).
    local r = S.cdRefusal[id]
    if r and r.after == last then
      return Now() - last >= r.bound + S.REFUSED_MARGIN
    end
  end
  if not (last and length) or last < (S.combatStart or 0) - 3 then
    return UNKNOWN
  end
  local glowAt = S.glowAt and S.glowAt[id]
  if S.glow[id] and glowAt and glowAt >= last then
    return true
  end
  return Now() + (V and V.cdShift[id] or 0) - last >= length - 0.05
end

function S.CooldownReady(id)
  if ChargeInfo(id) then
    local c = S.Charges(id)
    if c then
      return c > 0
    end
  end
  if V and V.cd[id] then
    return V.cd[id] <= Now()
  end
  local info = CooldownInfo(id)
  if not info then
    return S.OwnClockReady(id)
  end
  -- Our own clock first: a spell we cast less than its cooldown ago is not ready, whatever a readable flag says,
  -- unless the game's own timings (start + duration) say otherwise or a proc glow reset it. In restricted combat
  -- the game reported Thrash "ready" 0.5 s after it was cast (Guardian, 2026-11-08), so slot 1 kept flipping.
  local start, dur = U.Read(info.startTime), U.Read(info.duration)
  local timed = type(start) == "number" and type(dur) == "number"
  if not timed and S.OwnClockReady(id) == false then
    return false
  end
  local active, onGCD = U.Read(info.isActive), U.Read(info.isOnGCD)
  if active == nil then
    -- The game's flag is unreadable (in restricted combat it blinks between readable and not about once a
    -- second). Our own clock decides then: without it a spell cast 0.3 s ago looked ready again, because
    -- IsSpellUsable ignores cooldowns, and slot 1 flipped between it and the right spell (Guardian Thrash /
    -- Mangle, Balance, 2026-11-08). A proc glow (Gore on Mangle) means it was reset: ready.
    return S.OwnClockReady(id)
  end
  if active == false or onGCD == true then
    return true
  end
  if V and V.dt > 0 then
    -- Looking ahead: will it be back by then?
    local r = S.CooldownRemains(id)
    if r == UNKNOWN then
      return UNKNOWN
    end
    return r <= 0
  end
  return false
end

---------------------------------------------------------------------------
-- Casts
---------------------------------------------------------------------------
S.stackUntil = {} -- token -> { expiry, expiry, ... } for buffs where every cast is its own stack (Ironfur)

function S.IsStacking(token)
  return (S.learned.stacking and S.learned.stacking[token]) or false
end

-- The auras a cast applies: { {auraID, "self"|"enemy"}, ... } from SimC's data. When the button lists none,
-- the same-named aura that applies itself counts: the button and its aura can be separate spells with no link
-- in the data (Midnight Sunfire 93402 -> its DoT 164815, Moonfire 8921 -> 164812).
local NONE = {}
function S.AppliedAuras(id)
  local info = M.Info(id)
  if info and info.ap then
    -- not the cast's own short effect (see M.IsCastEffect): casting Eradicate ends buff.eradicate, it doesn't start it
    local list = {}
    for _, ap in ipairs(info.ap) do
      if not M.IsCastEffect(id, ap) then
        list[#list + 1] = ap
      end
    end
    return list
  end
  local token = info and info.n
  for _, aid in ipairs(token and M.AuraIDs(token) or NONE) do
    local ai = aid ~= id and M.Info(aid)
    local ap = ai and ai.ap and ai.ap[1]
    if ap and ap[1] == aid and ai.n == token and ai.d and not M.IsCastEffect(aid, ap) then
      return { ap }
    end
  end
  return NONE
end

local function StartAuraClock(token, auraID, target, from)
  local d = AuraLength(token, auraID)
  if not d then
    return
  end
  if target ~= "enemy" and S.IsStacking(token) then
    local list = S.stackUntil[token] or {}
    local alive = {}
    for _, e in ipairs(list) do
      if e > from then
        alive[#alive + 1] = e
      end
    end
    alive[#alive + 1] = from + d
    S.stackUntil[token] = alive
  end
  if target == "enemy" then
    S.dotUntil[token] = from + d
  else
    S.auraUntil[token] = from + d
  end
end

---------------------------------------------------------------------------
-- Buffs whose stacks your own attacks use up (the game hides them in combat): cast X gives N stacks, each listed
-- attack uses one. Fury's Improved Whirlwind: "your next 4 single-target attacks strike additional targets".
---------------------------------------------------------------------------
S.CONSUMED = {
  whirlwind = { stacks = 4, by = { bloodthirst = true, raging_blow = true, rampage = true, execute = true,
    onslaught = true, crushing_blow = true, bloodbath = true } },
}
S.consumeLeft = {} -- aura token -> stacks left
local lastConsumed = {} -- token -> time (one press reports several casts: counted once)
local function OnConsume(token, now)
  local c = S.CONSUMED[token]
  if c then
    S.consumeLeft[token] = c.stacks
    return
  end
  if lastConsumed[token] and now - lastConsumed[token] < 0.1 then
    return
  end
  for aura, def in pairs(S.CONSUMED) do
    if def.by[token] and (S.consumeLeft[aura] or 0) > 0 then
      lastConsumed[token] = now
      S.consumeLeft[aura] = S.consumeLeft[aura] - 1
      if S.consumeLeft[aura] <= 0 then
        S.auraUntil[aura] = now -- all used up
      end
    end
  end
end

-- The pieces of one press: Raging Blow's off-hand hit (85384, 96103) arrives 0.1 s after the main-hand one, Rampage
-- reports three, Whirlwind three. They are one cast: counted again, every off-hand hit looked like a second Raging
-- Blow cast 2.8 s "before our clock", and the learned correction ran away to -21 s (2026-11-09).
S.PIECE_WINDOW = 0.3
local lastToken, lastTokenAt = nil, 0

local function RecordCast(id, how)
  local token = M.TokenForID(id)
  local info = M.Info(id)
  if info and info.n then
    token = info.n
  end
  local now0 = GetTime()
  if token and token == lastToken and now0 - lastTokenAt < S.PIECE_WINDOW then
    return -- another piece of the same press
  end
  lastToken, lastTokenAt = token, now0
  CheckWaited(id)
  OnCooldownSpent(id) -- before lastCast moves on
  table.insert(S.history, 1, { id = id, token = token, t = GetTime(), how = how })
  if token then
    OnConsume(token, GetTime())
  end
  if #S.history > 10 then
    S.history[#S.history] = nil
  end
  LearnFromRefusals(id, GetTime())
  S.NoteBusy(id, token)
  S.lastCast[id] = GetTime()
  local byToken = M.TokenForID and M.TokenForID(id)
  for _, t in ipairs({ token, byToken }) do
    if type(t) == "string" then
      S.lastCastToken[t] = GetTime()
    end
  end
  OnChargeSpent(id)
  S.ApplyLinks(id, false)
  ns.Clues.OnCast()
  ns.Clues.OnOwnCast(id)
  if ns.Engine then
    ns.Engine.OnOwnCast()
  end
  if ns.OnOwnCast then
    ns.OnOwnCast(id)
  end
  if ns.Interrupts then
    ns.Interrupts.OnOwnCast(id)
  end
  -- Start our clocks for the auras this spell applies (SimC data, else what we learned in game).
  local started = false
  for _, ap in ipairs(S.AppliedAuras(id)) do
    local ai = M.Info(ap[1])
    if ai and ai.n then
      StartAuraClock(ai.n, ap[1], ap[2], GetTime())
      started = true
    end
  end
  if not started then
    local auraToken = S.learned.castAura[id] or token
    local l = auraToken and S.learned.aura[auraToken]
    if l then
      StartAuraClock(auraToken, nil, l.harmful and "enemy" or "self", GetTime())
    end
  end
  if how ~= "event" then
    U.Log("cast", { id = id, how = how }) -- the Watchdog already records cast events itself
  end
end

function S.OnSpellcastSucceeded(spellID)
  local id = U.Read(spellID)
  if type(id) ~= "number" then
    S.castsSecret = S.castsSecret + 1
    return
  end
  S.castsSeen = S.castsSeen + 1
  S.OnBoostCast(id)
  S.OnPetCast(id)
  if not (S.myCast and S.myCast.id == id) then
    S.gcdFrom = { id = id, t = GetTime() } -- an instant: the GCD starts now
  end
  S.OnOwnCastStop(id)
  RecordCast(id, "event")
  if C_Timer and C_Timer.After then
    C_Timer.After(0.1, function()
      LearnCooldown(id)
      S.wasActive[id] = true
    end)
  end
end

-- SPELL_UPDATE_COOLDOWN: infer casts of cooldown spells from isActive edges (works with secret cast events).
local gcdStart, gcdBase = nil, nil

function S.OnCooldownUpdate()
  local g = CooldownInfo(GCD_SPELL)
  local gActive = g and U.Read(g.isActive)
  if gActive == true and not gcdStart then
    gcdStart = GetTime()
    if ns.Interrupts then
      ns.Interrupts.OnGCDStarted()
    end
    local last = S.history[1]
    local info = last and M.Info(last.id)
    gcdBase = (info and info.gcd) or 1.5
    if info and info.gcd and info.gcd <= 1 and not info.hg then
      gcdBase = nil -- fixed 1s GCD tells nothing about haste
    end
  elseif gActive == false and gcdStart then
    if gcdBase then
      S.OnMeasuredGCD(GetTime() - gcdStart, gcdBase)
    end
    gcdStart = nil
  end
  -- A cast starts one cooldown (two with a shared one). Many starting in the same update is the GCD with its
  -- "on GCD" flag unreadable, a lockout or a silence: no casts (inferring them once restarted our cooldown
  -- clocks for twenty spells and emptied slots 2 and 3, Brewmaster).
  local started = {}
  for id, b in pairs(M.book) do
    if b.id == id and not b.passive then
      local info = CooldownInfo(id)
      if info then
        local active, onGCD = U.Read(info.isActive), U.Read(info.isOnGCD)
        if active ~= nil then
          if active == true and onGCD == false and S.wasActive[id] == false then
            started[#started + 1] = { id = id, info = info }
          end
          S.wasActive[id] = active == true and onGCD == false
        end
      end
    end
  end
  if #started > S.MAX_INFERRED then
    S.inferBursts = (S.inferBursts or 0) + 1
    return
  end
  for _, c in ipairs(started) do
    local last = S.lastCast[c.id]
    if not last or GetTime() - last > 0.5 then
      S.castsInferred = S.castsInferred + 1
      RecordCast(c.id, "cooldown")
    end
    LearnCooldown(c.id, c.info)
  end
end
S.MAX_INFERRED = 2

function S.OnGlow(spellID, shown)
  local id = U.Read(spellID)
  if type(id) == "number" then
    S.glow[id] = shown or nil
    if shown then
      S.glowAt = S.glowAt or {}
      S.glowAt[id] = GetTime()
    end
    ns.Clues.OnGlow(id, shown, S.AurasReadable())
  end
end

-- The spell being cast or channelled right now, if the game tells us: id, seconds left.
-- UnitCastingInfo returns ..., endTimeMs (5th), ..., castingSpellID (9th);
-- UnitChannelInfo returns ..., endTimeMs (5th), ..., spellID (8th). Both SecretWhenUnitSpellCastRestricted.
-- Our own cast, timed from its start event when the game hides UnitCastingInfo in combat (it does on
-- Midnight 12.1.5: the HUD's bar ran ahead of the real cast bar). Expected length = SimC's cast time / haste;
-- every finished cast measures the real length and corrects the haste estimate.
S.myCast = nil      -- { id =, t = start, len = expected seconds }
S.gcdFrom = nil     -- { id =, t = } when the latest GCD started (a cast's start, or an instant's success)

-- channel: a channelled spell (Fists of Fury, Eye Beam, Mind Flay) or an empowered one (Fire Breath): timed from
-- its duration in SimC's data (scaled by haste), since it has no cast time; the game reports it "succeeded" as it
-- starts, so only its stop event ends it. (Checked ahead of play 2026-11-09: a hidden channel bar timed as 0 s
-- would say "press now" in the middle of Fists of Fury.)
function S.OnOwnCastStart(spellID, channel)
  local id = U.Read(spellID)
  if type(id) ~= "number" then
    return
  end
  local info = M.Info(id)
  local ct = info and info.ct or 0
  local live = U.Get(C_Spell and C_Spell.GetSpellInfo, id)
  local ms = type(live) == "table" and U.Read(live.castTime)
  local len = type(ms) == "number" and ms > 0 and ms / 1000 or ct / HasteFactor()
  if channel and len <= 0 then
    len = ((info and tonumber(info.d)) or 2) / HasteFactor()
  end
  S.myCast = { id = id, t = GetTime(), len = len, base = (not channel) and ct or 0, channel = channel or nil }
  S.gcdFrom = { id = id, t = GetTime() }
end

-- The cast bar ended (UNIT_SPELLCAST_STOP): not casting any more; kept until SUCCEEDED measures it.
function S.OnOwnCastEnded()
  if S.myCast then
    S.myCast.ended = GetTime()
  end
end

function S.OnOwnCastStop(succeededID)
  local c = S.myCast
  if c and c.channel and succeededID ~= nil and not c.ended then
    return -- a channel "succeeds" as it starts: it runs on until its stop event
  end
  S.myCast = nil
  if not (c and succeededID and c.id == succeededID and c.base and c.base > 0) then
    return
  end
  local actual = (c.ended or GetTime()) - c.t
  -- First casts of each fight: predicted vs real length, so a report shows how far off the timing is.
  S.timingLogged = (S.timingLogged or 0) + 1
  if S.timingLogged <= 10 then
    U.Log("cast_timing", { id = c.id, predicted = math.floor(c.len * 1000), actual = math.floor(actual * 1000),
      haste = S.hasteSource })
  end
  if actual > 0.4 and type(U.Get(UnitSpellHaste, "player")) ~= "number" then
    local h = (c.base / actual - 1) * 100
    if h > -20 and h < 200 then
      lastHaste, S.hasteSource, S.hasteStale = h, "measured", false
    end
  end
end

function S.CurrentCast()
  local c = { U.Call(UnitCastingInfo, "player") }
  local endMs, id = U.Read(c[5]), U.Read(c[9])
  if type(endMs) ~= "number" or type(id) ~= "number" then
    c = { U.Call(UnitChannelInfo, "player") }
    endMs, id = U.Read(c[5]), U.Read(c[8])
  end
  if type(endMs) == "number" and type(id) == "number" then
    S.castSource = "game"
    return id, math.max(0, endMs / 1000 - GetTime())
  end
  S.castSource = "ours"
  local mine = S.myCast
  if mine and mine.ended then
    if GetTime() - mine.ended > 1 then
      S.myCast = nil
    end
    return nil
  end
  if mine then
    local left = mine.t + mine.len - GetTime()
    if left > -0.3 then
      return mine.id, math.max(0, left)
    end
    S.myCast = nil -- no stop event came (a missed event): forget it
  end
  return nil
end

-- Our own channel still running: spell ID and seconds left, or nil. The game's channel info when readable, else
-- our own clock from the channel's start event (S.OnOwnCastStart). Used for slot 1's HOLD cue: pressing anything
-- during a channel cuts it short.
function S.Channeling()
  local c = { U.Call(UnitChannelInfo, "player") }
  local endMs, id = U.Read(c[5]), U.Read(c[8])
  if type(endMs) == "number" and type(id) == "number" then
    return id, math.max(0, endMs / 1000 - GetTime())
  end
  local mine = S.myCast
  if mine and mine.channel and not mine.ended then
    local left = mine.t + mine.len - GetTime()
    if left > 0 then
      return mine.id, left
    end
  end
  -- Spells that aren't channels to the game but leave nothing else to press while they run (Bladestorm: the
  -- bar went empty for its 6 s, 2026-11-10): the same HOLD, from our cast.
  local b = S.busy
  if b then
    local left = b.t + b.len - GetTime()
    if left > 0 then
      return b.id, left
    end
    S.busy = nil
  end
  return nil
end

S.BUSY = { bladestorm = 6 } -- token -> seconds (the data's duration first)
function S.NoteBusy(id, token)
  local d = token and S.BUSY[token]
  if not d then
    return
  end
  local info = M.Info(id)
  S.busy = { id = id, t = GetTime(), len = (info and info.d and info.d > 0) and info.d or d }
end

---------------------------------------------------------------------------
-- Auras: read while readable (by spell ID, so any language), learn durations and cast -> aura links
---------------------------------------------------------------------------
local readAuras = { player = nil, target = nil }

local function ScanAuras(unit, filter, harmful)
  local getter = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
  if type(getter) ~= "function" then
    return nil
  end
  -- While auras are secret an empty scan proves nothing, so the whole scan counts as unreadable.
  if U.Get(C_Secrets and C_Secrets.ShouldAurasBeSecret) == true then
    return nil
  end
  local out = {}
  for i = 1, 80 do
    local aura = U.Call(getter, unit, i, filter)
    if aura == nil then
      break
    end
    if U.IsSecret(aura) then
      return nil
    end
    local name, sid = U.Read(aura.name), U.Read(aura.spellId)
    local dur, exp = U.Read(aura.duration), U.Read(aura.expirationTime)
    if name == nil and sid == nil then
      return nil
    end
    local token = M.AuraToken(sid, name)
    if token then
      local stacks = U.Read(aura.applications)
      out[token] = { expires = (type(exp) == "number" and exp > 0) and exp or math.huge,
        stacks = (type(stacks) == "number" and stacks > 0) and stacks or 1 }
      if type(dur) == "number" and dur > 0 then
        local known = S.learned.aura[token]
        if not known or known.duration ~= dur then
          S.learned.aura[token] = { duration = dur, harmful = harmful or nil }
        end
      end
    end
  end
  return out
end

function S.OnAura(unit)
  if unit ~= "player" and unit ~= "target" then
    return
  end
  local before = readAuras[unit]
  local now
  if unit == "player" then
    now = ScanAuras("player", "HELPFUL", false)
  else
    now = ScanAuras("target", "HARMFUL|PLAYER", true)
  end
  readAuras[unit] = now
  if not now then
    return
  end
  ns.Clues.Verify(unit, now)
  if unit == "player" then
    for token in pairs(now) do
      if not (before and before[token]) then
        ns.Clues.OnNewAura(token)
      end
    end
  end
  local last = S.history[1]
  if last and GetTime() - last.t <= TRACK_WINDOW then
    for token in pairs(now) do
      if not (before and before[token]) and last.token ~= token then
        S.learned.castAura[last.id] = token
      end
    end
  end
  local clocks = unit == "player" and S.auraUntil or S.dotUntil
  for token, untilT in pairs(clocks) do
    local seen = now[token]
    if (seen == nil) ~= (untilT <= GetTime()) then
      S.drift[token] = (S.drift[token] or 0) + 1
    end
    clocks[token] = seen and seen.expires or 0
  end
  for token, a in pairs(now) do
    clocks[token] = a.expires
    -- More than one stack of a buff our own casts apply: each cast is its own stack (Ironfur-style).
    if unit == "player" and a.stacks > 1 and (M.IsOwnAura(token) or S.learnedOwn(token)) then
      S.learned.stacking = S.learned.stacking or {}
      S.learned.stacking[token] = true
    end
  end
end

function S.AurasReadable()
  return readAuras.player ~= nil
end

-- The last readable scans ({ player = {...} | nil, target = {...} | nil }), for grading clue sources.
function S.ReadableAuras()
  if readAuras.player or readAuras.target then
    return readAuras
  end
  return nil
end

function S.OnTargetChanged()
  ns.Clues.OnTargetChanged()
  S.dotUntil = {}
  readAuras.target = nil
  S.OnAura("target")
end

-- up, remains, stacks for an aura token on "player" or "target": overlay, read, our clock, else UNKNOWN.
-- A living pet, or nil when the game won't say.
function S.PetActive()
  local exists = U.Get(UnitExists, "pet")
  if exists == nil then
    return nil
  end
  local alive = exists == true and U.Get(UnitIsDead, "pet") ~= true
  if alive then
    S.petDead = false
  end
  return alive
end

-- Your pet is dead: Call Pet does nothing then, only Revive Pet brings it back. Known from its body (dead pet
-- unit), or from calling it: the cast goes through but no pet appears (2026-11-09: Call Pet was suggested over and
-- over after the pet died on the dummies). Cleared by Revive Pet or a living pet.
S.CALL_PET = { [883] = true, [83242] = true, [83243] = true, [83244] = true, [83245] = true }
S.REVIVE_PET = 982
function S.PetDead()
  if U.Get(UnitExists, "pet") == true then
    S.petDead = U.Get(UnitIsDead, "pet") == true
  end
  return S.petDead == true
end

function S.OnPetCast(id)
  if id == S.REVIVE_PET then
    S.petDead = false
  elseif S.CALL_PET[id] and C_Timer and C_Timer.After then
    C_Timer.After(1, function()
      if U.Get(UnitExists, "pet") ~= true then
        S.petDead = true
        U.Log("pet_dead", { how = "called, nothing came" })
      end
    end)
  end
end

-- Stealth buffs: the game tells us whether we are stealthed (IsStealthed), and attacking ends them. Our own clock
-- for them never ends by itself (Prowl has no duration), so without this a Prowl cast before the pull stayed "up"
-- all fight and Feral's "rake if buff.prowl.up" opener line won every decision (2026-11-08).
local STEALTH = { prowl = true, stealth = true, shadowmeld = true, vanish = true, camouflage = true }
S.STEALTH = STEALTH

-- Some auras Blizzard leaves readable in combat ("Non-secret Aura" in the spell data: Tip of the Spear, Maelstrom
-- Weapon, Icicles, Stagger, raid buffs, poisons, Sated/Exhaustion...). Asked for by spell ID when the general aura
-- scan is hidden; nil when the game won't say (secret values are never used).
local directAt, directCache = 0, {}
function S.DirectAura(spellID)
  local now = GetTime()
  if now ~= directAt then
    directAt, directCache = now, {}
  end
  local c = directCache[spellID]
  if c == nil then
    c = false
    local data = U.Call(C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID, spellID)
    if data == nil then
      -- readable "no such aura" only when the call itself answered (not secret): a table means present
      c = { present = false }
    elseif type(data) == "table" then
      local exp, stacks = U.Read(data.expirationTime), U.Read(data.applications)
      if type(exp) == "number" then
        c = { present = true, expires = exp > 0 and exp or math.huge, stacks = (type(stacks) == "number" and stacks > 0) and stacks or 1 }
      end
    end
    directCache[spellID] = c
  end
  return c or nil
end

S.nonSecret = {} -- aura spell IDs seen readable while present: their absence is readable too
local function DirectAuraState(token, now)
  local knownAbsent = false
  for _, t in ipairs(M.Candidates(token)) do
    for _, aid in ipairs(M.AuraIDs(t) or {}) do
      local d = S.DirectAura(aid)
      if d and d.present then
        -- Readable in combat: then its absence in combat is readable too. Seen out of combat proves nothing (the
        -- game hides it once the fight starts and the read says "none": Whirlwind's buff, every GCD Whirlwind,
        -- 2026-11-09).
        if not S.nonSecret[aid] and S.combatStart then
          S.nonSecret[aid] = true
          U.Log("direct_aura", { aura = t, id = aid, stacks = d.stacks }) -- readable in combat: shows in reports
        end
        return true, d.expires - now, d.stacks
      elseif d and S.nonSecret[aid] then
        knownAbsent = true
      end
    end
  end
  if knownAbsent then
    return false, 0, 0
  end
  return nil
end

local function AuraState(unit, token)
  local list = M.Candidates(token)
  local now = Now()
  if unit == "player" and STEALTH[token] and not V then
    local st = U.Get(IsStealthed)
    if st == false then
      return false, 0, 0
    end
  end
  if V then
    local vt = unit == "player" and V.aura or V.dot
    for _, t in ipairs(list) do
      if vt[t] then
        if vt[t] > now then
          return true, vt[t] - now, 1
        end
        return false, 0, 0
      end
    end
  end
  local read = readAuras[unit]
  -- Auras the game leaves readable in combat: their answer wins (the general scan can come back partial, and then
  -- Tip of the Spear went back to unknown after one good read, Survival 2026-11-09)
  if unit == "player" and not (V and #V.prev > 0) then
    local up, remains, stacks = DirectAuraState(token, now)
    if up ~= nil then
      return up, math.max(0, remains), stacks
    end
  end
  -- Inferred facts (assistant oracle, glows) about the present, when the game won't show the aura itself.
  if not read and not (V and #V.prev > 0) then
    local up, remains = ns.Clues.AuraFact(unit, token)
    if up == true and remains == UNKNOWN then
      -- The clue says it's up but not for how long: our own clock still knows (a Sunfire we cast 6 s ago).
      -- Without this every "remains<2" / refreshable line stayed unknown all fight (Balance, 2026-11-10).
      local clocks = unit == "player" and S.auraUntil or S.dotUntil
      for _, t in ipairs(list) do
        if clocks[t] and clocks[t] > now then
          remains = clocks[t] - now
          break
        end
      end
    end
    if up ~= nil then
      return up, remains, up and 1 or 0
    end
  end
  for _, t in ipairs(list) do
    if read and read[t] then
      if read[t].expires > now then
        return true, read[t].expires - now, read[t].stacks
      end
      return false, 0, 0
    end
  end
  if unit == "player" and not read then
    for _, t in ipairs(list) do
      local stacks = S.stackUntil[t]
      if stacks then
        local n, last = 0, 0
        for _, e in ipairs(stacks) do
          if e > now then
            n, last = n + 1, math.max(last, e)
          end
        end
        if n > 0 then
          return true, last - now, n
        end
      end
    end
  end
  local clocks = unit == "player" and S.auraUntil or S.dotUntil
  for _, t in ipairs(list) do
    local untilT = clocks[t]
    if untilT then
      if untilT > now then
        local left = unit == "player" and S.consumeLeft[t]
        return true, untilT - now, (left and left > 0) and left or 1
      end
      -- Expired on our clock. Certain only for auras our own casts apply (we'd have seen the cast);
      -- a proc can come back unseen, so without a readable scan it is unknown.
      if read or M.IsOwnAura(t) or S.learnedOwn(t) then
        return false, 0, 0
      end
      return UNKNOWN, UNKNOWN, UNKNOWN
    end
  end
  if read then
    return false, 0, 0
  end
  -- Never seen this fight: if one of our own spells applies it (SimC's data says so), we would have seen that
  -- cast and started its clock, so it is down. Same for links learned in game.
  for _, t in ipairs(list) do
    if M.IsOwnAura(t) and AuraLength(t) then
      return false, 0, 0
    end
    if S.learned.aura[t] then
      for _, applied in pairs(S.learned.castAura) do
        if applied == t then
          return false, 0, 0
        end
      end
    end
  end
  return UNKNOWN, UNKNOWN, UNKNOWN
end
S.AuraState = AuraState

function S.learnedOwn(token)
  for _, applied in pairs(S.learned.castAura) do
    if applied == token then
      return true
    end
  end
  return false
end

local function AuraDuration(token)
  return AuraLength(token) or UNKNOWN
end

---------------------------------------------------------------------------
-- GCD and haste
---------------------------------------------------------------------------
local lastGCD = 1.5

-- GCD of a spell (or the default 1.5s GCD), hasted unless SimC's data says it is a fixed 1.0s GCD.
-- Haste: read when readable, else the last value read or measured (S.hasteSource), else the GCD's own duration.
function S.GCD(id)
  local info = id and M.Info(id)
  if info and info.gcd and info.gcd <= 1 and not info.hg then
    return info.gcd
  end
  local base = (info and info.gcd) or 1.5
  local haste = U.Get(UnitSpellHaste, "player")
  if type(haste) == "number" then
    lastHaste, S.hasteSource = haste, "read"
  end
  if S.hasteSource ~= "default" then
    lastGCD = math.max(0.75, base / (1 + lastHaste / 100))
    return lastGCD
  end
  local cd = CooldownInfo(GCD_SPELL)
  local dur = cd and U.Read(cd.duration)
  if type(dur) == "number" and dur > 0 then
    lastGCD = dur
  end
  return lastGCD
end

function S.GCDRemains()
  if V then
    return 0
  end
  -- The game's own GCD timer, if its duration object is readable.
  local gcdDur = U.Call(C_Spell and C_Spell.GetSpellCooldownDuration, GCD_SPELL)
  if type(gcdDur) == "table" and not U.IsSecret(gcdDur) and gcdDur.GetRemainingDuration then
    local left = U.Get(gcdDur.GetRemainingDuration, gcdDur)
    if type(left) == "number" then
      return math.max(0, left)
    end
  end
  local info = CooldownInfo(GCD_SPELL)
  if info then
    local start, dur = U.Read(info.startTime), U.Read(info.duration)
    if type(start) == "number" and type(dur) == "number" and dur > 0 then
      return math.max(0, start + dur - GetTime())
    end
    if U.Read(info.isActive) == false then
      return 0
    end
  end
  -- Our own clock: the GCD started at the latest cast's start (or an instant's success).
  local last = S.history[1]
  local from = S.gcdFrom
  if last and not (from and from.t >= last.t - 0.05) then
    from = last
  end
  if from then
    return math.max(0, S.GCD(from.id) - (GetTime() - from.t))
  end
  return 0
end

---------------------------------------------------------------------------
-- Resources
---------------------------------------------------------------------------
-- Passive regeneration per second for resources that refill on their own (energy 10/s, focus 5/s at no haste;
-- both scale with haste, so Bloodlust counts). The game's own number while readable (talents, gear and haste
-- included), kept at no haste for when it's hidden. Without it the look-ahead never saw energy coming back.
S.REGEN_BASE = { [3] = 10, [2] = 5 }
local regenSeen = {}

function S.RegenRate(pt)
  local base = S.REGEN_BASE[pt]
  if not base then
    return 0
  end
  local current = U.Get(UnitPowerType, "player")
  local readHaste = U.Get(UnitSpellHaste, "player")
  if current == pt then
    local r = U.Get(GetPowerRegen)
    if type(r) == "number" and r > 0 then
      regenSeen[pt] = { rate = r, haste = readHaste }
      return r
    end
  end
  -- Hidden in combat: the last rate the game showed, scaled only by haste it shows too. Our own haste estimate
  -- is unreliable where few spells have a cast time to measure it (Feral: energy came back slower than we
  -- thought and Rake showed ~1 s early, 2026-11-10); regeneration doesn't change between in and out of combat.
  local seen = regenSeen[pt]
  if type(seen) == "table" then
    if type(readHaste) == "number" and type(seen.haste) == "number" then
      return seen.rate * (1 + readHaste / 100) / (1 + seen.haste / 100)
    end
    return seen.rate
  end
  return base * HasteFactor()
end

local function PowerNow(pt)
  local cur = U.Get(UnitPower, "player", pt)
  local max = U.Get(UnitPowerMax, "player", pt)
  if type(cur) ~= "number" then
    cur = ns.Clues.ShadowValue(pt) -- counted from our casts, confirmed by power events
  end
  if V then
    if V.powerAbs[pt] then
      cur = V.powerAbs[pt]
    end
    if type(cur) == "number" and V.power[pt] then
      cur = cur + V.power[pt]
    end
    if type(cur) == "number" and V.dt > 0 and not V.powerAbs[pt] then
      cur = cur + S.RegenRate(pt) * V.dt -- what comes back by the look-ahead moment
    end
    if type(cur) == "number" then
      cur = math.max(0, cur)
      if type(max) == "number" and max > 0 then
        cur = math.min(cur, max)
      end
    end
  end
  return cur, max
end
S.PowerNow = PowerNow

local function Power(name, field, ctx)
  local pt = PowerType(name)
  if not pt then
    return nil
  end
  local cur, max = PowerNow(pt)
  if ctx and ctx.powerOverride and ctx.powerOverride[pt] then
    cur = ctx.powerOverride[pt] -- "what if" evaluation for a secret-rendered branch (Engine)
  end
  if field == "max" then
    return type(max) == "number" and max or UNKNOWN
  end
  if type(cur) ~= "number" then
    return UNKNOWN
  end
  if field == "deficit" then
    if type(max) ~= "number" then
      return UNKNOWN
    end
    return max - cur
  elseif field == "pct" then
    if type(max) ~= "number" or max == 0 then
      return UNKNOWN
    end
    return 100 * cur / max
  elseif field == nil then
    return cur
  end
  return UNKNOWN
end

-- Can we afford this spell (by SimC's cost data) at the overlay's moment? true/false/UNKNOWN.
function S.Affordable(id)
  local info = M.Info(id)
  local cost = M.Cost(info)
  if not cost then
    return UNKNOWN
  end
  local result = true
  for pt, amount in pairs(cost) do
    local cur = PowerNow(pt)
    if type(cur) ~= "number" then
      result = UNKNOWN
    elseif cur < amount then
      return false
    end
  end
  return result
end

-- Rogue effective_combo_points (sc_rogue.cpp current_effective_cp): combo points (at most the spendable maximum),
-- plus Supercharger's bonus while one of its hidden charges is up. lo, hi; nil when combo points are unknown.
S.SUPERCHARGE_BONUS = 3 -- Supercharger 2 + Forced Induction 1, the most it can add
local function EffectiveCP()
  local cur, max = PowerNow(4)
  if type(cur) ~= "number" then
    return nil
  end
  if type(max) == "number" and max > 0 then
    cur = math.min(cur, max)
  end
  local rank = M.TalentRank("supercharger")
  if cur == 0 or rank == 0 then
    return cur, cur
  end
  return cur, cur + S.SUPERCHARGE_BONUS
end

-- lo, hi for a hidden resource at the overlay's moment: the inferred range, capped at the maximum, then what the
-- pretend casts spent / gained and regeneration. Capped first: "100 or more" Fury minus Void Ray's 100 is 0-0, not
-- "up to 100" (slots 2 and 3 both said Void Ray, Devourer 2026-11-10).
function S.PowerBounds(pt, max)
  local lo, hi = ns.Clues.ResourceBounds(pt)
  if not lo then
    return nil
  end
  if type(max) ~= "number" then
    max = U.Get(UnitPowerMax, "player", pt)
  end
  if type(max) == "number" and max > 0 then
    hi = math.min(hi, max)
    lo = math.min(lo, max)
  end
  if V and V.power[pt] then
    lo, hi = math.max(0, lo + V.power[pt]), math.max(0, hi + V.power[pt])
  end
  if V and V.dt > 0 then
    local gained = S.RegenRate(pt) * V.dt
    lo, hi = lo + gained, hi + gained
  end
  if type(max) == "number" and max > 0 then
    hi = math.min(hi, max)
    lo = math.min(lo, max)
  end
  return lo, hi
end

-- lo, hi for a resource term whose exact value is hidden ("combo_points", "energy.deficit"); nil otherwise.
function S.Bounds(name)
  if name == "target.distance" then
    return ns.Clues.DistanceBounds()
  elseif name == "target.health.pct" then
    return ns.Clues.NamedBounds(name)
  end
  if name == "effective_combo_points" then
    return EffectiveCP()
  end
  local head, field = name:match("^([%w_]+)%.?([%w_]*)$")
  local pt = head and PowerType(head)
  if not pt or (field ~= "" and field ~= "deficit") then
    return nil
  end
  local cur, max = PowerNow(pt)
  if type(cur) == "number" then
    return nil -- exact value known; the resolver already returns it
  end
  local lo, hi = S.PowerBounds(pt, max)
  if not lo then
    return nil
  end
  if field == "deficit" then
    if type(max) ~= "number" then
      return nil
    end
    return max - hi, max - lo
  end
  return lo, hi
end

-- Grade inferred resource ranges whenever the real value is readable (out of combat, unrestricted resources).
function S.VerifyPowers()
  if V then
    return
  end
  for _, pt in pairs(ns.Clues.DISCRETE) do
    local cur = U.Get(UnitPower, "player", pt)
    if type(cur) == "number" then
      ns.Clues.SyncPower(pt, cur, U.Get(UnitPowerMax, "player", pt))
    end
  end
  for _, pt in pairs(ns.Clues.BUILT) do
    local cur = U.Get(UnitPower, "player", pt)
    if type(cur) == "number" then
      ns.Clues.SyncFloor(pt, cur, U.Get(UnitPowerMax, "player", pt))
    end
  end
  local seen = {}
  for pt in pairs(ns.Clues.bounds) do
    seen[pt] = true
  end
  for pt in pairs(ns.Clues.Affordability()) do
    seen[pt] = true
  end
  for pt in pairs(seen) do
    local cur = U.Get(UnitPower, "player", pt)
    if type(cur) == "number" then
      ns.Clues.VerifyPower(pt, cur)
    end
  end
end

---------------------------------------------------------------------------
-- Look-ahead overlay
---------------------------------------------------------------------------
function S.BeginLookahead(dt)
  V = { dt = dt or 0, cd = {}, aura = {}, dot = {}, power = {}, powerAbs = {}, prev = {}, cast = {},
    cdr = {}, cdShift = {} }
  return V
end

function S.EndLookahead()
  V = nil
end

function S.Lookahead()
  return V
end

-- Pretend `id` is cast at the overlay's moment: start its cooldown, apply its auras, pay its cost,
-- grant its resources, push it on prev_gcd, and move the clock past its GCD / cast time.
function S.Apply(id)
  if not V then
    return
  end
  local info = M.Info(id) or {}
  local at = Now()
  local cd = CooldownLength(id)
  if cd and not (info.ch and info.ch > 1) then
    V.cd[id] = at + cd
  end
  S.ApplyLinks(id, true)
  local cost = M.Cost(info)
  if cost then
    for pt, amount in pairs(cost) do
      local spend = amount
      local cmax = info.cmax and info.cmax[pt]
      if cmax then
        local cur, max = PowerNow(pt)
        if type(cur) == "number" then
          spend = math.min(cur, cmax)
        elseif type(max) == "number" and cmax >= max then
          -- A finisher spends everything: we know the result even without seeing the value.
          V.powerAbs[pt] = 0
          V.power[pt] = 0
          spend = 0
        end
      end
      V.power[pt] = (V.power[pt] or 0) - spend
    end
  end
  if info.gain then
    for pt, amount in pairs(info.gain) do
      V.power[pt] = (V.power[pt] or 0) + amount
    end
  end
  do
    for _, ap in ipairs(S.AppliedAuras(id)) do
      local ai = M.Info(ap[1])
      local tok = ai and ai.n
      local d = tok and AuraLength(tok, ap[1])
      if tok and d then
        if ap[2] == "enemy" then
          V.dot[tok] = at + d
        else
          V.aura[tok] = at + d
        end
      end
    end
  end
  V.cast[id] = at
  V.castCount = V.castCount or {}
  V.castCount[id] = (V.castCount[id] or 0) + 1
  table.insert(V.prev, 1, info.n or M.TokenForID(id))
  local castTime = info.ct and info.ct / HasteFactor() or 0
  V.dt = V.dt + math.max(S.GCD(id), castTime)
end

-- Seconds since `id` was last cast in this fight (a predicted cast in the look-ahead counts), or nil if it
-- has not been. Out of combat, casts since the last fight ended count, so a pre-pull cast is remembered.
-- Used for SimC's line_cd ("this line at most once every N seconds").
function S.SinceCast(id)
  if V and V.cast[id] then
    return Now() - V.cast[id]
  end
  local last = S.lastCast[id]
  local from = (S.combatStart or S.combatEnd or 0) - 3
  if last and last >= from then
    return Now() - last
  end
  return nil
end

---------------------------------------------------------------------------
-- The resolver: SimC identifier -> number / boolean / UNKNOWN
---------------------------------------------------------------------------
local Split = U.SplitDots

local function Bool(v)
  if v == UNKNOWN then
    return UNKNOWN
  end
  return v and 1 or 0
end

-- A spell the player doesn't have (talents read, not known) is never on cooldown, as in SimC.
local NOT_KNOWN_CD = { ready = 1, up = 1, remains = 0, remains_expected = 0, remains_guess = 0, down = 0,
  full_recharge_time = 0, recharge_time = 0, charges = 1, charges_fractional = 1, max_charges = 1, duration = 0 }

local function CooldownTerm(token, field)
  local id = M.AnySpellID(token)
  if not id then
    return UNKNOWN
  end
  if M.talentsRead and not M.SpellID(token) then
    M.unresolved[token] = nil
    local v = NOT_KNOWN_CD[field]
    if v ~= nil then
      return v
    end
    return UNKNOWN
  end
  -- One-charge spells (Celestial Alignment, Eclipse): their recharge is their cooldown.
  local info = M.Info(id)
  local single = info and info.ch == 1
  if single and (field == "full_recharge_time" or field == "recharge_time") then
    return S.CooldownRemains(id)
  elseif single and field == "charges_fractional" then
    local r, len = S.CooldownRemains(id), CooldownLength(id)
    if r == UNKNOWN or not len or len <= 0 then
      return UNKNOWN
    end
    return 1 - math.min(1, r / len)
  elseif single and field == "charges" then
    local r = S.CooldownReady(id)
    if r == UNKNOWN then
      return UNKNOWN
    end
    return r and 1 or 0
  end
  if field == "ready" or field == "up" then
    return Bool(S.CooldownReady(id))
  elseif field == "remains" or field == "remains_expected" or field == "remains_guess" then
    return S.CooldownRemains(id)
  elseif field == "down" then
    local r = S.CooldownReady(id)
    if r == UNKNOWN then
      return UNKNOWN
    end
    return r and 0 or 1
  elseif field == "duration" then
    return CooldownLength(id) or UNKNOWN
  end
  local charges = U.Get(C_Spell and C_Spell.GetSpellCharges, id)
  if type(charges) == "table" then
    local cur, max = U.Read(charges.currentCharges), U.Read(charges.maxCharges)
    if field == "charges" or field == "charges_fractional" then
      if type(cur) == "number" then
        return cur
      end
    elseif field == "max_charges" then
      if type(max) == "number" then
        return max
      end
    end
  end
  if field == "max_charges" and info and (info.chLive or info.ch or Live(info)) then
    return MaxCharges(info)
  end
  return UNKNOWN
end

local function AuraTerm(unit, token, field)
  local up, remains, stacks = AuraState(unit, token)
  if field == "up" or field == "react" or field == "ticking" or field == nil then
    return Bool(up)
  elseif field == "down" then
    if up == UNKNOWN then
      return UNKNOWN
    end
    return up and 0 or 1
  elseif field == "remains" then
    return remains
  elseif field == "stack" or field == "stacks" then
    return stacks
  elseif field == "duration" or field == "base_duration" then
    return AuraDuration(token)
  elseif field == "refreshable" then
    if up == UNKNOWN then
      return UNKNOWN
    end
    if not up then
      return 1
    end
    local d = AuraDuration(token)
    if d == UNKNOWN or remains == UNKNOWN then
      return UNKNOWN
    end
    return Bool(remains < 0.3 * d)
  end
  return UNKNOWN
end

local STATIC_ZERO = { set_bonus = true, equipped = true, trinket = true, main_hand = true, off_hand = true,
  item = true, bugs = true, covenant = true, runeforge = true,
  consumable = true, potion = true, apex = true }

local function CombatTime()
  if S.combatStart then
    return Now() - S.combatStart
  end
  return V and V.dt or 0
end

-- How much longer this fight lasts, for fight_remains / time_to_die. A fight that has already outlasted the usual
-- one is not ending on cue: 32 s into a dummy pull the learned length said "5 s left", and every "time_to_die>5"
-- DoT line (Sunfire, Moonfire) stopped refreshing for the rest of a 95 s fight (Balance, 2026-11-10). Past fights
-- that went on longer than this one say how much longer (their median); never less than S.FIGHT_LEFT_MIN seconds
-- while the fight is still going, so DoTs and cooldowns aren't dropped for an end we can't see. A custom length
-- (Settings) is taken as given.
S.FIGHT_LEFT_MIN = 10
function S.FightRemains()
  local len, t = S.FightLength(), CombatTime()
  local db = ns.db or {}
  if db.fightMode == "custom" then
    return math.max(1, len - t)
  end
  local left = len - t
  if left < 2 * S.FIGHT_LEFT_MIN and (db.fightMode or "learned") == "learned" then
    local g = ns.global or ns.db
    local list = g and type(g.fights) == "table" and g.fights[S.fightContext or S.FightContext()]
    local longer = {}
    for _, v in ipairs(type(list) == "table" and list or {}) do
      if type(v) == "number" and v > t then
        longer[#longer + 1] = v - t
      end
    end
    if #longer > 0 then
      table.sort(longer)
      left = math.max(left, longer[math.floor((#longer + 1) / 2)])
    end
  end
  return math.max(S.FIGHT_LEFT_MIN, left)
end

-- ctx: { action = token of the line being evaluated, vars = table, targets = n }
function S.Resolve(name, ctx)
  local p = Split(name)
  local head = p[1]

  if POWER[head] then
    return Power(head, p[2], ctx)
  elseif head == "cp_max_spend" then
    -- rogue: the most combo points a finisher uses (sc_rogue.cpp consume_cp_max: 5 + the stratagem talents), which
    -- is the maximum the game shows. Unread, every rogue's "finish at max combo points" list was unknown and a
    -- builder was shown at 7/7 (Subtlety, 2026-11-11).
    local max = U.Get(UnitPowerMax, "player", 4)
    return (type(max) == "number" and max > 0) and max or UNKNOWN
  elseif head == "effective_combo_points" then
    local lo, hi = EffectiveCP()
    if lo and lo == hi then
      return lo
    end
    return UNKNOWN
  elseif head == "talent" then
    local r = M.TalentRank(p[2] or "")
    if r == nil then
      return UNKNOWN
    end
    if p[3] == "rank" then
      return r
    end
    return r > 0 and 1 or 0
  elseif head == "hero_tree" then
    local h = M.HeroTree(p[2] or "")
    if h == nil then
      return UNKNOWN
    end
    return h
  elseif head == "cooldown" then
    return CooldownTerm(p[2] or "", p[3] or "ready")
  elseif head == "buff" then
    local v = AuraTerm("player", p[2] or "", p[3])
    local boost = v == UNKNOWN and S.BOOST_TOKENS[p[2] or ""]
    if boost then
      -- the buff is hidden in combat; the haste jump told us (see S.BOOSTS)
      local left = S.BoostRemains(boost)
      local f = p[3]
      if f == "remains" then
        return left
      elseif f == "down" then
        return left > 0 and 0 or 1
      elseif f == "up" or f == "react" or f == nil then
        return left > 0 and 1 or 0
      end
    end
    return v
  elseif head == "debuff" or head == "dot" then
    return AuraTerm("target", p[2] or "", p[3])
  elseif head == "active_dot" then
    return AuraTerm("target", p[2] or "", "ticking")
  elseif head == "variable" then
    local v = ctx and ctx.vars and ctx.vars[p[2]]
    if v == nil then
      return 0
    end
    return v
  elseif head == "active_enemies" or head == "spell_targets" or head == "enemies" then
    if ctx and ctx.targets then
      return ctx.targets
    end
    return (S.Targets())
  elseif head == "fight_remains" or head == "time_to_die" then
    return S.FightRemains()
  elseif head == "expected_combat_length" then
    return S.FightLength()
  elseif head == "target" then
    local f = p[2]
    if f == "time_to_die" then
      return S.FightRemains()
    elseif f == "distance" then
      if ns.Clues.DistanceBounds() then
        return UNKNOWN -- decided from the range bounds in comparisons
      end
      return 5 -- no range info: SimC's own default (the player stands where the spec wants to stand)
    elseif f == "health" and p[3] == "pct" then
      local hp, max = U.Get(UnitHealth, "target"), U.Get(UnitHealthMax, "target")
      if type(hp) == "number" and type(max) == "number" and max > 0 then
        return 100 * hp / max
      end
      return UNKNOWN
    elseif f == "level" then
      return U.Get(UnitLevel, "target") or UNKNOWN
    end
    return UNKNOWN
  elseif head == "spell_haste" or head == "attack_haste" then
    return 1 / HasteFactor() -- SimC: the haste multiplier (0.8 at 25% haste)
  elseif head == "gcd" then
    if p[2] == "remains" then
      return S.GCDRemains()
    end
    return S.GCD()
  elseif head == "time" or head == "combat_time" then
    return CombatTime()
  elseif head == "combo_strike" then
    -- Windwalker (sc_monk.cpp is_combo_strike): true unless this ability was the last one used (true at the start
    -- of a fight). From our own casts, pretend ones first. Unread, 63 Windwalker lines were guesses.
    local action = ctx and ctx.action
    if not action then
      return UNKNOWN
    end
    local last = (V and V.prev[1]) or (S.history[1] and S.history[1].token)
    if not last then
      return 1
    end
    return last == action and 0 or 1
  elseif head == "prev_gcd" or head == "prev" or head == "prev_off_gcd" then
    local n, token = 1, p[2]
    if tonumber(p[2]) then
      n, token = tonumber(p[2]), p[3]
    end
    local tok
    local vprev = V and #V.prev or 0
    if n <= vprev then
      tok = V.prev[n]
    else
      local h = S.history[n - vprev]
      if not h then
        return 0
      end
      tok = h.token
    end
    if not tok then
      return UNKNOWN
    end
    for _, t in ipairs(M.Candidates(token or "")) do
      if t == tok then
        return 1
      end
    end
    return 0
  elseif head == "known" then
    -- WoWSims lists: is this spell (any rank) in the player's spellbook / talents?
    if M.SpellID(p[2] or "") or M.AnySpellID(p[2] or "") then
      M.unresolved[p[2]] = nil
      return 1
    end
    M.unresolved[p[2] or ""] = nil
    return 0
  elseif head == "talentid" then
    -- WoWSims lists: talent by spell ID -> purchased rank (0 when the tree was read and it isn't taken).
    local id = tonumber(p[2])
    if not (id and M.talentsRead) then
      return UNKNOWN
    end
    return M.talentIDs[id] or 0
  elseif head == "casting" then
    local castID = S.CurrentCast()
    if not castID then
      return 0
    end
    local info = M.Info(castID)
    local tok = (info and info.n) or M.TokenForID(castID)
    for _, t in ipairs(M.Candidates(p[2] or "")) do
      if t == tok then
        return 1
      end
    end
    return 0
  elseif head == "health" and p[2] == "pct" then
    local hp, max = U.Get(UnitHealth, "player"), U.Get(UnitHealthMax, "player")
    if type(hp) == "number" and type(max) == "number" and max > 0 then
      return 100 * hp / max
    end
    return UNKNOWN
  elseif head == "fight_style" then
    return p[2] == "patchwerk" and 1 or 0
  elseif head == "raid_event" then
    local f = p[3]
    local fromMods = ns.BossMods and ns.BossMods.RaidEvent(p[2], f)
    if fromMods then
      return fromMods
    end
    if f == "in" or f == "cooldown" then
      return 10000
    end
    return 0
  elseif (head == "this_trinket" or head == "other_trinket") and ns.Trinkets then
    local slot = ns.Trinkets.ThisSlot(head)
    if not slot then
      return UNKNOWN
    end
    return ns.Trinkets.Term(slot, p, 2)
  elseif head == "trinket" and (p[2] == "1" or p[2] == "2") and ns.Trinkets then
    return ns.Trinkets.Term(12 + tonumber(p[2]), p, 3)
  elseif STATIC_ZERO[head] then
    return 0
  elseif head == "level" then
    return U.Get(UnitLevel, "player") or UNKNOWN
  elseif head == "pet" and (name:find("%.active$") or name == "pet.active") then
    -- pet.active, pet.any.active, pet.main.active, pet.<name>.active: whether the player has a living pet (the game
    -- tells us). Without it, Call Pet stayed undecided and filled slots 2-3 with a pet out (Beast Mastery).
    return Bool(S.PetActive())
  elseif head == "stealthed" then
    local st = U.Get(IsStealthed)
    if st == nil then
      return UNKNOWN
    end
    return Bool(st == true)
  elseif head == "moving" then
    local speed = U.Get(GetUnitSpeed, "player")
    if type(speed) == "number" then
      return speed > 0 and 1 or 0
    end
    return S.moving and 1 or 0 -- PLAYER_STARTED/STOPPED_MOVING are never secret
  elseif head == "action" then
    local id = M.SpellID(p[2] or "")
    if not id then
      return UNKNOWN
    end
    local f = p[3]
    if f == "ready" or f == "usable" then
      local usable = U.Get(C_Spell and C_Spell.IsSpellUsable, id)
      if usable == nil then
        return UNKNOWN
      end
      if not usable then
        return 0
      end
      return Bool(S.CooldownReady(id))
    elseif f == "execute_time" then
      return S.GCD(id)
    elseif f == "cast_time" then
      local info = M.Info(id)
      if info then
        return (info.ct or 0) / HasteFactor()
      end
      return UNKNOWN
    elseif f == "cost" then
      local info = M.Info(id)
      local cost = M.Cost(info)
      if cost then
        local _, amount = next(cost)
        return amount or 0
      end
      return 0
    end
    return CooldownTerm(p[2], f)
  end

  -- Bare names refer to the line's own action (dot / cooldown of the spell being considered).
  local own = ctx and ctx.action
  if own and #p == 1 then
    if head == "ticking" or head == "refreshable" or head == "remains" then
      return AuraTerm("target", own, head)
    elseif head == "charges" or head == "charges_fractional" or head == "full_recharge_time"
      or head == "max_charges" then
      return CooldownTerm(own, head)
    elseif head == "cooldown_react" then
      return CooldownTerm(own, "ready")
    elseif head == "execute_time" or head == "cast_time" then
      return S.GCD(M.SpellID(own))
    elseif head == "persistent_multiplier" or head == "pmultiplier" then
      return 1
    end
  end

  -- A ground effect named after the spell (consecration.up, death_and_decay.ticking): the game has no aura to read,
  -- so it's worked out from our own last cast and the spell's duration. Without it Holy's "consecration if it isn't
  -- down" line stayed a guess and sat in slot 2 all fight (2026-11-09).
  local field = p[2]
  if #p == 2 and (field == "up" or field == "down" or field == "remains" or field == "ticking" or field == "active") then
    local id = M.SpellID(head)
    local info = id and M.Info(id)
    local dur = info and tonumber(info.d)
    if dur and dur > 0 then
      local since = S.SinceCast(id)
      local left = since and math.max(0, dur - since) or 0
      if field == "remains" then
        return left
      elseif field == "down" then
        return left > 0 and 0 or 1
      end
      return left > 0 and 1 or 0
    end
  end
  return UNKNOWN
end

---------------------------------------------------------------------------
-- Out-of-combat calibration: read the real numbers for this character (talents, gear and buffs included)
---------------------------------------------------------------------------
-- C_Spell.GetSpellPowerCost (not secret) -> live resource costs; C_Spell.GetSpellCharges (readable out of combat)
-- -> live max charges; UnitSpellHaste -> haste. Run after login, spec/talent changes and at the end of each fight.
function S.Calibrate()
  if S.combatStart then
    return 0
  end
  S.ForgetTalentCache()
  local n = 0
  for id, b in pairs(M.book) do
    local info = b.id == id and not b.passive and M.Info(id)
    if info then
      local costs = U.Get(C_Spell and C_Spell.GetSpellPowerCost, id)
      if type(costs) == "table" then
        local live
        for _, c in ipairs(costs) do
          local pt, amount = U.Read(c.type), U.Read(c.cost)
          if type(pt) == "number" and type(amount) == "number" and amount > 0 then
            live = live or {}
            live[pt] = amount
          end
        end
        info.costLive = live
        n = n + 1
      end
    end
  end
  -- Charges: asked for the exact ID the engine uses for each of the list's spells, and taken as the game says.
  -- (Taking the highest count over every spellbook ID with that name counted Judgment at 2 and Holy Shock at 3,
  -- because variant IDs report other numbers, 2026-11-09.)
  S.liveCharges = {}
  for token in pairs(M.data or {}) do
    local id = M.SpellID(token)
    local info = id and M.Info(id)
    if info and (info.ch or info.chcd) then
      local charges = U.Get(C_Spell and C_Spell.GetSpellCharges, id)
      local maxC = type(charges) == "table" and U.Read(charges.maxCharges)
      local rc = type(charges) == "table" and U.Read(charges.cooldownDuration)
      if type(maxC) == "number" and maxC >= 1 then
        -- Talents included. Scales with haste when our data says so, or when the game's number is our base divided
        -- by the haste right now (Kill Command: 5 s / 1.14 = 4.4 s; read at 27% haste it was too short at 10%).
        -- Then kept at no haste and scaled back by the haste of the moment.
        local haste = HasteFactor()
        local recharge = (type(rc) == "number" and rc > 1.5) and rc or nil
        local hasted = recharge and (info.hc or (info.chcd and haste > 1.02
          and math.abs(info.chcd / haste - recharge) < 0.15)) or false
        S.liveCharges[info.n or token] = {
          max = maxC,
          recharge = recharge and (hasted and recharge * haste or recharge) or nil,
          hasted = hasted or nil,
        }
      end
    end
  end
  -- What the game said, in the report (once per change): "holy_shock=2/5.0 judgment=1/6.0"
  local parts = {}
  for token, l in pairs(S.liveCharges) do
    parts[#parts + 1] = string.format("%s=%s/%s%s", token, tostring(l.max),
      l.recharge and string.format("%.1f", l.recharge) or "-", l.hasted and "h" or "")
  end
  table.sort(parts)
  local text = table.concat(parts, " ")
  if text ~= S.chargesLogged then
    S.chargesLogged = text
    U.Log("charges_read", { spells = text ~= "" and text or "none readable" })
  end
  -- What was learned so far, in the report (once per change): "wildfire_bomb=+1.2±0.3x6 kill_command=B±2.1x5"
  -- (+/- seconds our clock is corrected by, the scatter, how many measurements; B = left to Blizzard).
  parts = {}
  for name, t in pairs(S.learned and S.learned.timing or {}) do
    if type(t) == "table" and (t.n or 0) >= 1 then
      parts[#parts + 1] = string.format("%s=%s±%.1fx%d", name, t.unreliable and "B" or string.format("%+.1f", t.mean or 0),
        t.spread or 0, t.n)
    end
  end
  table.sort(parts)
  text = table.concat(parts, " ")
  if text ~= S.timingSummary then
    S.timingSummary = text
    U.Log("learned_timing", { spells = text ~= "" and text or "nothing yet" })
  end
  HasteFactor()
  return n
end

-- What the timing learning has found for this spec, in plain words (Settings > Grade report): one line per spell
-- measured 3 times or more, spells left to Blizzard first. "@aoe" records are the same spell on many targets.
function S.LearningLines()
  local L = ns.L
  local lines = {}
  local keys = {}
  for key, t in pairs(S.learned and S.learned.timing or {}) do
    if type(t) == "table" and (t.n or 0) >= 3 then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys, function(a, b)
    local ta, tb = S.learned.timing[a], S.learned.timing[b]
    if (ta.unreliable == true) ~= (tb.unreliable == true) then
      return ta.unreliable == true
    end
    return a < b
  end)
  for _, key in ipairs(keys) do
    local t = S.learned.timing[key]
    local name, aoe = key:match("^(.-)(@aoe)$")
    name = (name or key):gsub("_", " ")
    if aoe then
      name = string.format(L["%s (several targets)"], name)
    end
    if t.unreliable then
      lines[#lines + 1] = string.format(L["%s: left to Blizzard's assistant (its cooldown moves with effects we can't see)"],
        name)
    else
      lines[#lines + 1] = string.format(L["%s: measured %d times, our clock corrected by %+.1f s, now within %.1f s"],
        name, t.n, t.mean or 0, t.spread or 0)
    end
  end
  return lines
end

---------------------------------------------------------------------------
-- Combat bookkeeping and persistence
---------------------------------------------------------------------------
function S.OnCombat(inCombat)
  if inCombat then
    S.combatStart = GetTime()
    S.fightContext = S.FightContext()
    S.timingLogged, S.pressLogged, S.pressed, S.notBefore, S.acNamed = 0, 0, {}, {}, nil
    if ns.Display then
      ns.Display.shadesLogged = 0
    end
    S.drift = {}
    S.castsSeen, S.castsSecret, S.castsInferred = 0, 0, 0
    S.ForgetEnemies()
    for t in pairs(STEALTH) do
      S.auraUntil[t] = nil -- the pull breaks stealth; a new one (Shadowmeld, Vanish) is seen when cast
    end
  else
    S.ForgetEnemies()
    U.Log("tracking", { seen = S.castsSeen, secret = S.castsSecret, inferred = S.castsInferred, drift = S.drift })
    if S.combatStart then
      RecordFight(S.fightContext, GetTime() - S.combatStart)
    end
    S.fightContext = nil
    -- Cooldowns cast this fight are readable again: learn their real length (talents shorten some, Convoke the
    -- Spirits: our data's 120 s, back much sooner in game and never shown again, 2026-11-10). In combat the
    -- length is hidden, so this is when it's learned.
    local castThisFight = {}
    for id, t in pairs(S.lastCast or {}) do
      if S.combatStart and t >= S.combatStart then
        castThisFight[#castThisFight + 1] = id
      end
    end
    if C_Timer and C_Timer.After and #castThisFight > 0 then
      C_Timer.After(0.5, function()
        if S.combatStart then
          return -- a new fight already: still hidden
        end
        for _, id in ipairs(castThisFight) do
          LearnCooldown(id)
        end
      end)
    end
    S.combatStart = nil
    S.combatEnd = GetTime()
    S.history = {}
  end
end

-- Settings > Learned timing, /dmga relearn: forget what was learned about cooldown timing, for every spec on
-- the account (the shipped list of erratic spells applies again). Settings are kept. Returns false in combat.
function S.ResetLearning()
  if S.combatStart or (InCombatLockdown and InCombatLockdown()) then
    return false
  end
  local db = ns.global or ns.db
  if type(db) == "table" and type(db.learned) == "table" then
    for _, l in pairs(db.learned) do
      if type(l) == "table" then
        l.timing, l.unreliable, l.cd = {}, {}, {}
      end
    end
  end
  S.chargeSpentAt, S.readyShown, S.rotationSpells = {}, nil, nil
  if S.learned then
    S.learned.timing = S.learned.timing or {}
  end
  if S.Calibrate then
    S.Calibrate()
  end
  return true
end

-- Learned durations are kept per spec in DMGAssistDB.learned[key].
function S.Bind(key)
  local db = ns.global or ns.db
  if type(db) ~= "table" then
    return
  end
  db.learned = type(db.learned) == "table" and db.learned or {}
  S.rotationSpells = nil
  local l = db.learned[key]
  if type(l) ~= "table" then
    l = {}
    db.learned[key] = l
  end
  l.cd = type(l.cd) == "table" and l.cd or {}
  l.aura = type(l.aura) == "table" and l.aura or {}
  l.castAura = type(l.castAura) == "table" and l.castAura or {}
  l.glowAura = type(l.glowAura) == "table" and l.glowAura or {}
  S.learned = l
  ns.Clues.Reset(l.glowAura)
  S.auraUntil, S.dotUntil, S.lastCast, S.wasActive, S.glow = {}, {}, {}, {}, {}
  S.cdRefusal = {}
  l.unreliable = type(l.unreliable) == "table" and l.unreliable or {}
  S.chargeSpentAt, S.readyShown = {}, nil -- liveCharges: re-read by S.Calibrate
  l.timing = type(l.timing) == "table" and l.timing or {}
  -- 1.6.0.170: corrections resting on one or two samples, learned before the stale-clock fix, are dropped once
  -- (relearned within a fight or two)
  if (l.timingVersion or 0) < 2 then
    for name, t in pairs(l.timing) do
      if type(t) ~= "table" or (t.n or 0) < 3 then
        l.timing[name] = nil
      end
    end
    l.timingVersion = 2
  end
  -- 1.6.0.178: "ready much earlier than our clock" learned from the assistant still naming a spell just cast
  -- (S.ASSISTED_STALE) is dropped once: Eternity Surge kept -18 s and showed in slot 2 most of its cooldown.
  if (l.timingVersion or 0) < 3 then
    for name, t in pairs(l.timing) do
      if type(t) == "table" and type(t.mean) == "number" and t.mean <= -3 then
        l.timing[name] = nil
      end
    end
    l.timingVersion = 3
  end
  S.stackUntil, S.consumeLeft = {}, {}
  l.stacking = type(l.stacking) == "table" and l.stacking or {}
  readAuras.player, readAuras.target = nil, nil
end
