-- State.lua: everything the engine can know about "now", and the trackers that fill the gaps in combat.
--
-- Three sources, best first:
--   1. Read  — the game tells us (out of combat nearly everything; in combat the NeverSecret/whitelisted bits).
--   2. Track — our own clock: casts we saw, cooldown/aura durations we learned while they were readable.
--   3. Unknown — E.UNKNOWN; the engine needs corroboration before acting on it.
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

-- Learned facts survive between fights (saved in DMGAssistDB.learned per spec key).
S.learned = { cd = {}, aura = {}, castAura = {} }
S.history = {}      -- recent own casts, newest first: { id=, token=, t= }
S.auraUntil = {}    -- token -> expiry (tracked from casts; player buffs)
S.dotUntil = {}     -- token -> expiry on the current target
S.lastCast = {}     -- spellID -> GetTime() of the last cast we saw
S.wasActive = {}    -- spellID -> last isActive (for cast inference)
S.glow = {}         -- spellID -> true while the proc glow is shown
S.combatStart = nil
S.unknownTerms = {}
S.drift = {}        -- token -> count of times a tracked value disagreed with an observed truth
S.castsSeen, S.castsSecret, S.castsInferred = 0, 0, 0

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
  return GetTime()
end

local function PowerType(name)
  local key = POWER[name]
  if not key then
    return nil
  end
  local enum = Enum and Enum.PowerType and U.Read(Enum.PowerType[key])
  return enum or POWER_FALLBACK[key]
end

---------------------------------------------------------------------------
-- Settings that stand in for things we cannot read (see docs/design/engine-priority.md, class M)
---------------------------------------------------------------------------
function S.Settings()
  local db = ns.db or {}
  return {
    mode = db.mode or "st",
    aoeTargets = tonumber(db.aoeTargets) or 3,
    fightLength = tonumber(db.fightLength) or 300,
  }
end

function S.Targets()
  local set = S.Settings()
  if set.mode == "aoe" then
    return set.aoeTargets
  end
  if set.mode == "auto" then
    local plates = U.Read(U.Call(C_NamePlate and C_NamePlate.GetNamePlates))
    if type(plates) == "table" then
      local n = 0
      for _, plate in ipairs(plates) do
        local unit = type(plate) == "table" and U.Read(plate.namePlateUnitToken)
        if unit and U.Read(U.Call(UnitCanAttack, "player", unit)) and U.Read(U.Call(UnitAffectingCombat, unit)) then
          n = n + 1
        end
      end
      if n > 0 then
        return n
      end
    end
  end
  return 1
end

---------------------------------------------------------------------------
-- Cooldowns
---------------------------------------------------------------------------
local function CooldownInfo(id)
  local info = U.Read(U.Call(C_Spell and C_Spell.GetSpellCooldown, id))
  if type(info) ~= "table" then
    return nil
  end
  return info
end

-- Learn a spell's cooldown duration while it is readable (out of combat or whitelisted).
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

function S.CooldownReady(id)
  local info = CooldownInfo(id)
  if not info then
    return UNKNOWN
  end
  local active, onGCD = U.Read(info.isActive), U.Read(info.isOnGCD)
  if active == nil then
    return UNKNOWN
  end
  return active == false or onGCD == true
end

function S.CooldownRemains(id)
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
  local last, learned = S.lastCast[id], S.learned.cd[id]
  if last and learned then
    local left = learned - (Now() - last)
    if left > 0 then
      return left
    end
    -- Our clock says ready, the game says active: we are out of sync (haste, cooldown reduction, reset).
    S.drift[id] = (S.drift[id] or 0) + 1
  end
  return UNKNOWN
end

---------------------------------------------------------------------------
-- Casts
---------------------------------------------------------------------------
local function RecordCast(id, how)
  local token = M.TokenForID and M.TokenForID(id)
  table.insert(S.history, 1, { id = id, token = token, t = Now(), how = how })
  if #S.history > 10 then
    S.history[#S.history] = nil
  end
  S.lastCast[id] = Now()
  -- Buffs we learned this spell applies: start our own clock for them.
  local auraToken = S.learned.castAura[id]
  if auraToken then
    local d = S.learned.aura[auraToken]
    if d then
      if d.harmful then
        S.dotUntil[auraToken] = Now() + d.duration
      else
        S.auraUntil[auraToken] = Now() + d.duration
      end
    end
  end
  if token then
    local d = S.learned.aura[token]
    if d and not auraToken then
      if d.harmful then
        S.dotUntil[token] = Now() + d.duration
      else
        S.auraUntil[token] = Now() + d.duration
      end
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
  RecordCast(id, "event")
  if C_Timer and C_Timer.After then
    C_Timer.After(0.1, function()
      LearnCooldown(id)
      S.wasActive[id] = true
    end)
  end
end

-- SPELL_UPDATE_COOLDOWN: infer casts of cooldown spells from isActive edges (works with secret cast events).
function S.OnCooldownUpdate()
  for _, id in pairs(M.spells) do
    local info = CooldownInfo(id)
    if info then
      local active, onGCD = U.Read(info.isActive), U.Read(info.isOnGCD)
      if active ~= nil then
        if active == true and onGCD ~= true and S.wasActive[id] == false then
          local last = S.lastCast[id]
          if not last or Now() - last > 0.5 then
            S.castsInferred = S.castsInferred + 1
            RecordCast(id, "cooldown")
          end
          LearnCooldown(id, info)
        end
        S.wasActive[id] = active == true and onGCD ~= true
      end
    end
  end
end

function S.OnGlow(spellID, shown)
  local id = U.Read(spellID)
  if type(id) == "number" then
    S.glow[id] = shown or nil
  end
end

---------------------------------------------------------------------------
-- Auras (read while readable, learn durations and which cast applies which aura)
---------------------------------------------------------------------------
local readAuras = { player = nil, target = nil }  -- token -> { expires, stacks } when the last scan was readable

local function ScanAuras(unit, filter, harmful)
  local getter = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
  if type(getter) ~= "function" then
    return nil
  end
  -- While auras are secret an empty scan proves nothing, so the whole scan counts as unreadable.
  if U.Read(U.Call(C_Secrets and C_Secrets.ShouldAurasBeSecret)) == true then
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
    local name, dur, exp = U.Read(aura.name), U.Read(aura.duration), U.Read(aura.expirationTime)
    if name == nil then
      return nil -- fields are secret: this scan tells us nothing
    end
    local token = M.Token(name)
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
  -- Link a new aura to the cast just before it.
  local last = S.history[1]
  if last and Now() - last.t <= TRACK_WINDOW then
    for token in pairs(now) do
      if not (before and before[token]) and last.token ~= token then
        S.learned.castAura[last.id] = token
      end
    end
  end
  -- Resync our clocks with the truth while we can see it.
  local clocks = unit == "player" and S.auraUntil or S.dotUntil
  for token, untilT in pairs(clocks) do
    local seen = now[token]
    if (seen == nil) ~= (untilT <= Now()) then
      S.drift[token] = (S.drift[token] or 0) + 1
    end
    clocks[token] = seen and seen.expires or 0
  end
  for token, a in pairs(now) do
    clocks[token] = a.expires
  end
end

function S.OnTargetChanged()
  S.dotUntil = {}
  readAuras.target = nil
  S.OnAura("target")
end

-- Up/remains for an aura token on "player" or "target": read if possible, else our own clock, else UNKNOWN.
local function AuraState(unit, token)
  local list = M.Candidates(token)
  local read = readAuras[unit]
  local clocks = unit == "player" and S.auraUntil or S.dotUntil
  local now = Now()
  for _, t in ipairs(list) do
    if read and read[t] then
      return true, read[t].expires - now, read[t].stacks
    end
  end
  for _, t in ipairs(list) do
    local untilT = clocks[t]
    if untilT then
      if untilT > now then
        return true, untilT - now, 1
      end
      return false, 0, 0
    end
  end
  -- A readable scan without the aura means it is down; otherwise if we know its duration but never saw it
  -- applied this fight, it is down as far as our clock knows (we would have seen our own cast).
  if read then
    return false, 0, 0
  end
  for _, t in ipairs(list) do
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

local function AuraDuration(token)
  for _, t in ipairs(M.Candidates(token)) do
    local d = S.learned.aura[t]
    if d then
      return d.duration
    end
  end
  return UNKNOWN
end

---------------------------------------------------------------------------
-- GCD and haste
---------------------------------------------------------------------------
local lastGCD = 1.5

function S.GCD()
  local haste = U.Read(U.Call(UnitSpellHaste, "player"))
  if type(haste) == "number" then
    lastGCD = math.max(0.75, 1.5 / (1 + haste / 100))
  else
    local info = CooldownInfo(GCD_SPELL)
    local dur = info and U.Read(info.duration)
    if type(dur) == "number" and dur > 0 then
      lastGCD = dur
    end
  end
  return lastGCD
end

function S.GCDRemains()
  local info = CooldownInfo(GCD_SPELL)
  if info then
    local start, dur = U.Read(info.startTime), U.Read(info.duration)
    if type(start) == "number" and type(dur) == "number" and dur > 0 then
      return math.max(0, start + dur - Now())
    end
    if U.Read(info.isActive) == false then
      return 0
    end
  end
  local last = S.history[1]
  if last then
    return math.max(0, S.GCD() - (Now() - last.t))
  end
  return 0
end

---------------------------------------------------------------------------
-- Resources
---------------------------------------------------------------------------
local function Power(name, field)
  local pt = PowerType(name)
  if not pt then
    return nil
  end
  local cur = U.Read(U.Call(UnitPower, "player", pt))
  local max = U.Read(U.Call(UnitPowerMax, "player", pt))
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

---------------------------------------------------------------------------
-- The resolver: SimC identifier -> number / boolean / UNKNOWN
---------------------------------------------------------------------------
local function Split(name)
  local parts = {}
  for p in name:gmatch("[^%.]+") do
    parts[#parts + 1] = p
  end
  return parts
end

local function Bool(v)
  if v == UNKNOWN then
    return UNKNOWN
  end
  return v and 1 or 0
end

local function CooldownTerm(token, field)
  local id = M.AnySpellID(token)
  if not id then
    return UNKNOWN
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
    return S.learned.cd[id] or UNKNOWN
  end
  local charges = U.Read(U.Call(C_Spell and C_Spell.GetSpellCharges, id))
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
  elseif field == "pmultiplier" or field == "value" then
    return UNKNOWN
  end
  return UNKNOWN
end

local STATIC_ZERO = { set_bonus = true, equipped = true, trinket = true, main_hand = true, off_hand = true,
  item = true, bugs = true, covenant = true, runeforge = true, this_trinket = true, other_trinket = true,
  consumable = true, potion = true, apex = true }

-- ctx: { action = token of the line being evaluated, vars = table, targets = n }
function S.Resolve(name, ctx)
  local p = Split(name)
  local head = p[1]

  if POWER[head] then
    return Power(head, p[2])
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
    if not M.talentsRead then
      return UNKNOWN
    end
    return M.heroTree == p[2] and 1 or 0
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
    return (ctx and ctx.targets) or S.Targets()
  elseif head == "fight_remains" or head == "time_to_die" or head == "expected_combat_length" then
    local elapsed = S.combatStart and (Now() - S.combatStart) or 0
    return math.max(1, S.Settings().fightLength - elapsed)
  elseif head == "target" then
    local f = p[2]
    if f == "time_to_die" then
      local elapsed = S.combatStart and (Now() - S.combatStart) or 0
      return math.max(1, S.Settings().fightLength - elapsed)
    elseif f == "distance" then
      return 5 -- SimC's own default: the player stands where the spec wants to stand
    elseif f == "health" and p[3] == "pct" then
      local hp, max = U.Read(U.Call(UnitHealth, "target")), U.Read(U.Call(UnitHealthMax, "target"))
      if type(hp) == "number" and type(max) == "number" and max > 0 then
        return 100 * hp / max
      end
      return UNKNOWN
    elseif f == "level" then
      return U.Read(U.Call(UnitLevel, "target")) or UNKNOWN
    end
    return UNKNOWN
  elseif head == "gcd" then
    if p[2] == "remains" then
      return S.GCDRemains()
    end
    return S.GCD()
  elseif head == "time" or head == "combat_time" then
    return S.combatStart and (Now() - S.combatStart) or 0
  elseif head == "prev_gcd" or head == "prev" or head == "prev_off_gcd" then
    local n, token = 1, p[2]
    if tonumber(p[2]) then
      n, token = tonumber(p[2]), p[3]
    end
    local h = S.history[n]
    if not h then
      return 0
    end
    if not h.token then
      return UNKNOWN
    end
    for _, t in ipairs(M.Candidates(token or "")) do
      if t == h.token then
        return 1
      end
    end
    return 0
  elseif head == "fight_style" then
    return p[2] == "patchwerk" and 1 or 0
  elseif head == "raid_event" then
    local f = p[3]
    if f == "in" or f == "cooldown" then
      return 10000
    end
    return 0
  elseif STATIC_ZERO[head] then
    return 0
  elseif head == "level" then
    return U.Read(U.Call(UnitLevel, "player")) or UNKNOWN
  elseif head == "stealthed" then
    local st = U.Read(U.Call(IsStealthed))
    if st == nil then
      return UNKNOWN
    end
    return Bool(st == true)
  elseif head == "moving" then
    local speed = U.Read(U.Call(GetUnitSpeed, "player"))
    if type(speed) == "number" then
      return speed > 0 and 1 or 0
    end
    return UNKNOWN
  elseif head == "action" then
    local id = M.SpellID(p[2] or "")
    if not id then
      return UNKNOWN
    end
    local f = p[3]
    if f == "ready" or f == "usable" then
      local usable = U.Read(U.Call(C_Spell and C_Spell.IsSpellUsable, id))
      if usable == nil then
        return UNKNOWN
      end
      if not usable then
        return 0
      end
      return Bool(S.CooldownReady(id))
    elseif f == "execute_time" then
      return S.GCD()
    elseif f == "cast_time" then
      local info = U.Read(U.Call(C_Spell and C_Spell.GetSpellInfo, id))
      local ms = type(info) == "table" and U.Read(info.castTime)
      return type(ms) == "number" and ms / 1000 or UNKNOWN
    end
    return CooldownTerm(p[2], f)
  end

  -- Bare names refer to the line's own action (dot / cooldown of the spell being considered).
  local own = ctx and ctx.action
  if own and #p == 1 then
    if head == "ticking" or head == "refreshable" or head == "remains" or head == "pmultiplier" then
      return AuraTerm("target", own, head)
    elseif head == "charges" or head == "charges_fractional" or head == "full_recharge_time"
      or head == "max_charges" then
      return CooldownTerm(own, head)
    elseif head == "cooldown_react" then
      return CooldownTerm(own, "ready")
    elseif head == "execute_time" or head == "cast_time" then
      return S.GCD()
    elseif head == "persistent_multiplier" then
      return 1
    end
  end
  return UNKNOWN
end

---------------------------------------------------------------------------
-- Combat bookkeeping and persistence
---------------------------------------------------------------------------
function S.OnCombat(inCombat)
  if inCombat then
    S.combatStart = Now()
    S.drift = {}
    S.castsSeen, S.castsSecret, S.castsInferred = 0, 0, 0
  else
    U.Log("tracking", { seen = S.castsSeen, secret = S.castsSecret, inferred = S.castsInferred, drift = S.drift })
    S.combatStart = nil
    S.history = {}
  end
end

-- Learned durations are kept per spec in DMGAssistDB.learned[key].
function S.Bind(key)
  local db = ns.db
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
  S.learned = l
  S.auraUntil, S.dotUntil, S.lastCast, S.wasActive, S.glow = {}, {}, {}, {}, {}
  readAuras.player, readAuras.target = nil, nil
end
