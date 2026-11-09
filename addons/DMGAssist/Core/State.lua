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
function S.Unhurt()
  local st = U.Get(UnitStagger, "player")
  if type(st) == "number" and st > 0 then
    return false
  end
  local hp, max = U.Get(UnitHealth, "player"), U.Get(UnitHealthMax, "player")
  if type(hp) == "number" and type(max) == "number" and max > 0 then
    return hp >= max
  end
  if type(st) == "number" then
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
      if hostile == false or dead == true or inRange == false then
        S.seenEnemies[key] = nil -- not an enemy, dead, or someone else's fight far away
      elseif hostile and inCombat then
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
function S.Targets()
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

-- UNIT_SPELL_HASTE: haste changed (Bloodlust, a proc). If the value is readable we use it directly;
-- otherwise the next measured GCD updates it.
function S.OnHasteChanged()
  local h = U.Get(UnitSpellHaste, "player")
  if type(h) == "number" then
    lastHaste, S.hasteSource = h, "read"
  else
    S.hasteStale = true
  end
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
end

local function HasteFactor()
  local h = U.Get(UnitSpellHaste, "player")
  if type(h) == "number" then
    lastHaste = h
  end
  return 1 + lastHaste / 100
end

local function DataCooldown(id)
  local info = M.Info(id)
  if not info then
    return nil
  end
  -- A charge spell's recharge is its real cooldown: Celestial Alignment is "cd 1, 1 charge, 180 s recharge",
  -- Eclipse "cd 1, 1 charge, 32 s recharge" (the 1 s is only the minimum between uses).
  local cd = math.max(info.cd or 0, info.chcd or 0)
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

local function CooldownLength(id)
  return S.learned.cd[id] or DataCooldown(id) or BaseCooldown(id)
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
    local left = length - (Now() - last)
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
  if info and (info.ch or info.chLive) and (info.chcd or 0) > 0 then
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
  local n = (info.chLive or info.ch) - #PendingRecharges(group, Now())
  if not V then
    local c = U.Get(C_Spell and C_Spell.GetSpellCharges, id)
    local cur = type(c) == "table" and U.Read(c.currentCharges)
    if type(cur) == "number" then
      -- The game's count, unless our own casts say fewer are left: in restricted combat it reported an Eclipse
      -- charge 2 s after the only one was spent (Balance, 2026-11-08). The same rule as cooldowns.
      return math.max(0, math.min(cur, n))
    end
  end
  if V and V.cast then
    for castID in pairs(V.cast) do
      if GroupOf(castID) == group then
        n = n - 1
      end
    end
  end
  return math.max(0, n)
end

-- Seconds until a charge is available (0 with one ready), or nil for a spell without charges.
function S.ChargeRemains(id)
  local c = S.Charges(id)
  if c == nil then
    return nil
  end
  if c > 0 then
    return 0
  end
  local pending = PendingRecharges(GroupOf(id), Now())
  if pending[1] then
    return math.max(0, pending[1] - Now())
  end
  return nil -- the game says none left but we saw no cast: unknown, fall back to the cooldown API
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
  local from = list[#list] or GetTime() -- one charge recharges at a time
  list[#list + 1] = math.max(from, GetTime()) + info.chcd
end

-- Ready by our own clock (last cast + cooldown length): true / false, or UNKNOWN without a cast this fight.
function S.OwnClockReady(id)
  local last, length = S.lastCast[id], CooldownLength(id)
  if not (last and length) or last < (S.combatStart or 0) - 3 then
    return UNKNOWN
  end
  local glowAt = S.glowAt and S.glowAt[id]
  if S.glow[id] and glowAt and glowAt >= last then
    return true
  end
  return Now() - last >= length - 0.05
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
    return info.ap
  end
  local token = info and info.n
  for _, aid in ipairs(token and M.AuraIDs(token) or NONE) do
    local ai = aid ~= id and M.Info(aid)
    local ap = ai and ai.ap and ai.ap[1]
    if ap and ap[1] == aid and ai.n == token and ai.d then
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

local function RecordCast(id, how)
  local token = M.TokenForID(id)
  local info = M.Info(id)
  if info and info.n then
    token = info.n
  end
  table.insert(S.history, 1, { id = id, token = token, t = GetTime(), how = how })
  if #S.history > 10 then
    S.history[#S.history] = nil
  end
  S.lastCast[id] = GetTime()
  OnChargeSpent(id)
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

function S.OnOwnCastStart(spellID)
  local id = U.Read(spellID)
  if type(id) ~= "number" then
    return
  end
  local info = M.Info(id)
  local ct = info and info.ct or 0
  local live = U.Get(C_Spell and C_Spell.GetSpellInfo, id)
  local ms = type(live) == "table" and U.Read(live.castTime)
  local len = type(ms) == "number" and ms / 1000 or ct / HasteFactor()
  S.myCast = { id = id, t = GetTime(), len = len, base = ct }
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
    return id, math.max(0, endMs / 1000 - GetTime())
  end
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
  return exists == true and U.Get(UnitIsDead, "pet") ~= true
end

-- Stealth buffs: the game tells us whether we are stealthed (IsStealthed), and attacking ends them. Our own clock
-- for them never ends by itself (Prowl has no duration), so without this a Prowl cast before the pull stayed "up"
-- all fight and Feral's "rake if buff.prowl.up" opener line won every decision (2026-11-08).
local STEALTH = { prowl = true, stealth = true, shadowmeld = true, vanish = true, camouflage = true }
S.STEALTH = STEALTH

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
  -- Inferred facts (assistant oracle, glows) about the present, when the game won't show the aura itself.
  if not read and not (V and #V.prev > 0) then
    local up, remains = ns.Clues.AuraFact(unit, token)
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
        return true, untilT - now, 1
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

-- lo, hi for a resource term whose exact value is hidden ("combo_points", "energy.deficit"); nil otherwise.
function S.Bounds(name)
  if name == "target.distance" then
    return ns.Clues.DistanceBounds()
  elseif name == "target.health.pct" then
    return ns.Clues.NamedBounds(name)
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
  local lo, hi = ns.Clues.ResourceBounds(pt)
  if not lo then
    return nil
  end
  if V and V.power[pt] then
    lo, hi = math.max(0, lo + V.power[pt]), hi + V.power[pt]
  end
  if type(max) == "number" and max > 0 then
    hi = math.min(hi, max)
    lo = math.min(lo, max)
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
  V = { dt = dt or 0, cd = {}, aura = {}, dot = {}, power = {}, powerAbs = {}, prev = {}, cast = {} }
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
  if field == "max_charges" and info and (info.chLive or info.ch) then
    return info.chLive or info.ch
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
  item = true, bugs = true, covenant = true, runeforge = true, this_trinket = true, other_trinket = true,
  consumable = true, potion = true, apex = true }

local function CombatTime()
  if S.combatStart then
    return Now() - S.combatStart
  end
  return V and V.dt or 0
end

-- ctx: { action = token of the line being evaluated, vars = table, targets = n }
function S.Resolve(name, ctx)
  local p = Split(name)
  local head = p[1]

  if POWER[head] then
    return Power(head, p[2], ctx)
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
    return AuraTerm("player", p[2] or "", p[3])
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
  elseif head == "fight_remains" or head == "time_to_die" or head == "expected_combat_length" then
    return math.max(1, S.FightLength() - CombatTime())
  elseif head == "target" then
    local f = p[2]
    if f == "time_to_die" then
      return math.max(1, S.FightLength() - CombatTime())
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
      local charges = U.Get(C_Spell and C_Spell.GetSpellCharges, id)
      local maxC = type(charges) == "table" and U.Read(charges.maxCharges)
      if type(maxC) == "number" then
        info.chLive = maxC
      end
    end
  end
  HasteFactor()
  return n
end

---------------------------------------------------------------------------
-- Combat bookkeeping and persistence
---------------------------------------------------------------------------
function S.OnCombat(inCombat)
  if inCombat then
    S.combatStart = GetTime()
    S.fightContext = S.FightContext()
    S.timingLogged = 0
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
    S.combatStart = nil
    S.combatEnd = GetTime()
    S.history = {}
  end
end

-- Learned durations are kept per spec in DMGAssistDB.learned[key].
function S.Bind(key)
  local db = ns.global or ns.db
  if type(db) ~= "table" then
    return
  end
  db.learned = type(db.learned) == "table" and db.learned or {}
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
  S.stackUntil = {}
  l.stacking = type(l.stacking) == "table" and l.stacking or {}
  readAuras.player, readAuras.target = nil, nil
end
