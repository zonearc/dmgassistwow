-- Signals.lua: what the game told us, kept per kind ("piece") until a game event says it changed (owner, 2026-11-16:
-- "passes need to be ... broken down in to specific calls and those calls only trigger on specific signals", and
-- "use the full passes as a cross-check to identify which smaller passes failed").
--
-- Every question the addon asks the game goes through U.Call. Each game function belongs to one piece (resources,
-- cooldowns, usable, auras, casting, haste, units, range, spellbook, overrides). A piece keeps the answers it has
-- seen; a game event that can change them (UNIT_AURA for auras, SPELL_UPDATE_COOLDOWN for cooldowns ...) only marks
-- the piece stale - a flag, not a pass, so a burst of events costs nothing. Some answers change with time alone
-- (range while you move): those pieces also go stale after `maxAge`.
--
-- Modes (DMGAssistDB.signalsMode):
--   "shadow" (default): every question is still asked fresh; the piece says what it would have answered, and any
--      difference is a miss, reported with the piece, the question, both answers, how old the kept one was and the
--      last signal the piece saw. Nothing the addon shows changes.
--   "live": a piece that isn't stale answers from what it kept (no game call); every REFEREE seconds a full pass asks
--      everything fresh and checks the pieces the same way.
--   "off": no pieces.
-- Unmapped functions are always asked fresh, and counted, so they can be given a piece.
local _, ns = ...
local U = ns.U
local Sig = {}
ns.Signals = Sig

Sig.REFEREE = 0.5      -- s between full passes in live mode
Sig.MISS_LOGS = 30     -- detailed miss lines per fight
Sig.SHADOW_LOGS = true

-- piece -> events that make it stale, and how long its answers can be trusted without an event (nil = until one)
Sig.PIECES = {
  resources = { events = { "UNIT_POWER_UPDATE", "UNIT_POWER_FREQUENT", "UNIT_MAXPOWER", "UNIT_DISPLAYPOWER",
    "UNIT_SPELLCAST_SUCCEEDED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" } },
  cooldowns = { events = { "SPELL_UPDATE_COOLDOWN", "SPELL_UPDATE_CHARGES", "ACTIONBAR_UPDATE_COOLDOWN",
    "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_START", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" } },
  usable = { events = { "SPELL_UPDATE_USABLE", "SPELL_UPDATE_COOLDOWN", "UNIT_POWER_UPDATE", "UNIT_POWER_FREQUENT",
    "UNIT_AURA", "UNIT_SPELLCAST_SUCCEEDED", "PLAYER_TARGET_CHANGED", "UPDATE_SHAPESHIFT_FORM",
    "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" } },
  auras = { events = { "UNIT_AURA", "PLAYER_TARGET_CHANGED", "UNIT_SPELLCAST_SUCCEEDED", "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED" } },
  casting = { events = { "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_SUCCEEDED",
    "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_DELAYED", "UNIT_SPELLCAST_CHANNEL_START",
    "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_CHANNEL_UPDATE", "UNIT_SPELLCAST_EMPOWER_START",
    "UNIT_SPELLCAST_EMPOWER_STOP", "UNIT_SPELLCAST_EMPOWER_UPDATE" } },
  haste = { events = { "UNIT_SPELL_HASTE", "UNIT_AURA", "COMBAT_RATING_UPDATE", "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED" } }, -- (combat hides it: the answer itself changes at the pull)
  units = { events = { "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "PLAYER_TARGET_CHANGED", "UNIT_FLAGS",
    "UNIT_HEALTH", "UNIT_TARGET", "UNIT_THREAT_LIST_UPDATE", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "PLAYER_FOCUS_CHANGED", "UNIT_NAME_UPDATE" }, maxAge = 0.5 },
  range = { events = { "PLAYER_TARGET_CHANGED", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED" }, maxAge = 0.2 },
  spellbook = { events = { "SPELLS_CHANGED", "TRAIT_CONFIG_UPDATED", "PLAYER_TALENT_UPDATE",
    "ACTIVE_TALENT_GROUP_CHANGED", "PLAYER_SPECIALIZATION_CHANGED", "LEARNED_SPELL_IN_TAB", "PLAYER_LEVEL_UP" } },
  overrides = { events = { "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED", "SPELL_UPDATE_ICON", "ACTIONBAR_SLOT_CHANGED",
    "UPDATE_BONUS_ACTIONBAR", "UNIT_AURA", "UPDATE_SHAPESHIFT_FORM", "SPELLS_CHANGED", "UNIT_SPELLCAST_SUCCEEDED",
    "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" } },
}

-- piece of each game function (built at first use: the client's tables exist by then)
local pieceOf
local function Build()
  pieceOf = {}
  local function Put(piece, fn)
    if type(fn) == "function" then
      pieceOf[fn] = piece
    end
  end
  local sp, ua = C_Spell or {}, C_UnitAuras or {}
  Put("resources", UnitPower)
  Put("resources", UnitPowerMax)
  Put("resources", UnitPowerType)
  Put("cooldowns", sp.GetSpellCooldown)
  Put("cooldowns", sp.GetSpellCharges)
  Put("cooldowns", sp.GetSpellCastCount)
  Put("usable", sp.IsSpellUsable)
  Put("usable", sp.GetSpellPowerCost)
  for _, name in ipairs({ "GetPlayerAuraBySpellID", "GetAuraDataBySpellName", "GetAuraDataByIndex",
    "GetAuraDataByAuraInstanceID", "GetUnitAuraBySpellID", "GetBuffDataByIndex", "GetDebuffDataByIndex",
    "GetAuraApplicationDisplayCount", "GetUnitAuras", "GetAuraDuration" }) do
    Put("auras", ua[name])
  end
  Put("casting", UnitCastingInfo)
  Put("casting", UnitChannelInfo)
  Put("haste", UnitSpellHaste)
  Put("haste", GetHaste)
  for _, fn in ipairs({ UnitExists, UnitGUID, UnitCanAttack, UnitIsDead, UnitAffectingCombat, UnitName, UnitLevel,
    UnitClassification, UnitIsPlayer, UnitIsFriend, UnitIsEnemy, UnitCreatureType }) do
    Put("units", fn)
  end
  Put("range", sp.IsSpellInRange)
  Put("haste", sp.GetSpellInfo) -- (its castTime: haste, and a proc making Starfire instant - 20 misses, fight 489)
  for _, fn in ipairs({ IsPlayerSpell, sp.GetSpellName, sp.GetSpellTexture,
    C_ClassTalents and C_ClassTalents.GetActiveConfigID, IsSpellKnown, IsSpellKnownOrOverridesKnown }) do
    Put("spellbook", fn)
  end
  Put("overrides", sp.GetOverrideSpell)
  local ab = C_ActionBar or {}
  Put("overrides", ab.FindSpellActionButtons)
  Put("overrides", ab.GetBonusBarOffset)
end

-- piece state: gen (bumped by its events), last signal and when
Sig.state = {}
local function State(piece)
  local s = Sig.state[piece]
  if not s then
    s = { gen = 0, last = "-", lastAt = 0 }
    Sig.state[piece] = s
  end
  return s
end

-- kept answers: piece -> fn -> a1 -> a2 -> { gen, t, vals }
local kept = {}
local NIL = {}
Sig.stats = {} -- piece -> { asked, valid, wrong }
Sig.unmapped = {} -- fn -> count
Sig.missLogs = 0
Sig.misses = {} -- this fight's first misses (also logged)

local function Stat(piece)
  local s = Sig.stats[piece]
  if not s then
    s = { asked = 0, valid = 0, wrong = 0 }
    Sig.stats[piece] = s
  end
  return s
end

function Sig.Mode()
  local m = ns.db and ns.db.signalsMode
  return m == "live" and "live" or m == "off" and "off" or "shadow"
end

-- An event: the pieces it touches are stale from now (and, for the record, which signal did it)
local touches = {}
for piece, p in pairs(Sig.PIECES) do
  for _, e in ipairs(p.events) do
    touches[e] = touches[e] or {}
    table.insert(touches[e], piece)
  end
end
Sig.touches = touches
function Sig.OnEvent(event)
  local list = touches[event]
  if not list then
    return
  end
  local now = GetTime()
  for _, piece in ipairs(list) do
    local s = State(piece)
    s.gen, s.last, s.lastAt = s.gen + 1, event, now
  end
end

-- How many signals a piece has seen (a memo is good while this hasn't moved)
function Sig.Gen(piece)
  return State(piece).gen
end

-- Everything stale (a referee pass, a reload)
function Sig.All(why)
  local now = GetTime()
  for piece in pairs(Sig.PIECES) do
    local s = State(piece)
    s.gen, s.last, s.lastAt = s.gen + 1, why or "all", now
  end
end

local function Secret(v)
  return v ~= nil and issecretvalue ~= nil and issecretvalue(v) == true
end

-- fields that count down by themselves (no event changes them): not compared
Sig.VOLATILE = { timeUntilEndOfStartRecovery = true }

local function Same(a, b, depth)
  local sa, sb = Secret(a), Secret(b)
  if sa or sb then
    return sa and sb -- (both hidden: the same as far as we can tell; hidden values can't even be compared)
  end
  if a == b then
    return true
  end
  if type(a) == "table" and type(b) == "table" and (depth or 0) < 2 then
    for k, v in pairs(a) do
      if not Sig.VOLATILE[k] and not Same(v, b[k], (depth or 0) + 1) then
        return false
      end
    end
    for k in pairs(b) do
      if a[k] == nil and not Sig.VOLATILE[k] then
        return false
      end
    end
    return true
  end
  return false
end

-- How long an answer can be trusted, beyond its piece's events:
--  * settling: an answer taken within SETTLE s of the piece's last signal isn't kept at all (the game sends some
--    signals a moment before the change lands: in fight 488 a pass right after UNIT_SPELLCAST_START still read no
--    cast);
--  * a cooldown we can read expires when it ends (a cooldown ending, the GCD above all, sends nothing);
--  * a hidden cooldown (secret times) can't say when it ends: trusted until the GCD ends (when it is on the GCD
--    that is all it is), at most HIDDEN_CD s.
Sig.SETTLE = 0.1
Sig.HIDDEN_CD = 0.25
Sig.gcdEnd = 0
local function Expiry(piece, st, now, vals)
  local x = math.huge
  local p = Sig.PIECES[piece]
  if p.maxAge then
    x = now + p.maxAge
  end
  if now - st.lastAt < Sig.SETTLE then
    return now
  end
  if piece == "casting" then -- a cast ends when it says (the game's signal can come a frame after)
    local endMS = vals[5]
    if type(endMS) == "number" and not Secret(endMS) then
      x = math.min(x, endMS / 1000)
    end
  end
  if piece == "cooldowns" then
    local v = vals[1]
    if type(v) == "table" and not Secret(v) then
      local s0 = v.startTime or v.cooldownStartTime
      local d = v.duration or v.cooldownDuration
      if Secret(s0) or Secret(d) then
        x = math.min(x, now + Sig.HIDDEN_CD, Sig.gcdEnd > now and Sig.gcdEnd or math.huge)
      elseif type(s0) == "number" and type(d) == "number" and d > 0 then
        x = math.min(x, s0 + d)
      end
    end
  end
  return x
end

local function SameVals(x, y)
  if x.n ~= y.n then
    return false
  end
  for i = 1, x.n do
    if not Same(x[i], y[i]) then
      return false
    end
  end
  return true
end

local function Plain(v)
  local t = type(v)
  return v == nil or ((t == "number" or t == "string" or t == "boolean") and not Secret(v))
end

local function Slot(piece, fn, n, a1, a2)
  if n > 2 or not Plain(a1) or not Plain(a2) then
    return nil
  end
  local byPiece = kept[piece]
  if not byPiece then
    byPiece = {}
    kept[piece] = byPiece
  end
  local byFn = byPiece[fn]
  if not byFn then
    byFn = {}
    byPiece[fn] = byFn
  end
  local k1 = a1 == nil and NIL or a1
  local by1 = byFn[k1]
  if not by1 then
    by1 = {}
    byFn[k1] = by1
  end
  return by1, a2 == nil and NIL or a2
end

local function Text(v)
  if Secret(v) then
    return "S"
  end
  if type(v) == "table" then
    local parts = {}
    for k, x in pairs(v) do
      if #parts < 6 then
        parts[#parts + 1] = tostring(k) .. "=" .. (Secret(x) and "S" or tostring(x))
      end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return tostring(v)
end

Sig.missBy = {} -- "piece q" -> misses this fight
local function Report(piece, fn, args, e, fresh, now)
  local q0 = ns.Record and ns.Record.Key and ns.Record.Key(fn, args) or tostring(fn)
  local k = piece .. " " .. tostring(q0):gsub("%(.*", "") .. " last=" .. State(piece).last
  Sig.missBy[k] = (Sig.missBy[k] or 0) + 1
  if Sig.missLogs >= Sig.MISS_LOGS then
    return
  end
  Sig.missLogs = Sig.missLogs + 1
  local q = ns.Record and ns.Record.Key and ns.Record.Key(fn, args) or tostring(fn)
  local s = State(piece)
  local m = { piece = piece, q = q, held = Text(e.vals[1]), game = Text(fresh[1]),
    age = string.format("%.2f", now - e.t), last = s.last, lastAgo = string.format("%.2f", now - s.lastAt) }
  Sig.misses[#Sig.misses + 1] = m
  U.Log("signal_miss", m)
end

-- U.Call's way in: `Ask(fn, ...)` returns the packed answers (fresh, or kept in live mode when the piece is clean).
-- `fresh` asks the game.
function Sig.Ask(fresh, fn, ...)
  local mode = Sig.Mode()
  if mode == "off" then
    return fresh(fn, ...)
  end
  if not pieceOf then
    Build()
  end
  local piece = pieceOf[fn]
  if not piece then
    Sig.unmapped[fn] = (Sig.unmapped[fn] or 0) + 1
    return fresh(fn, ...)
  end
  local n = select("#", ...)
  local slot, k2 = Slot(piece, fn, n, ...)
  if not slot then
    return fresh(fn, ...)
  end
  local st = State(piece)
  local now = GetTime()
  local e = slot[k2]
  local valid = e and e.gen == st.gen and now < e.untilT
  local stat = Stat(piece)
  stat.asked = stat.asked + 1
  if valid then
    stat.valid = stat.valid + 1
    if mode == "live" and not Sig.refereeing then
      return e.vals
    end
  end
  local vals = fresh(fn, ...)
  if piece == "cooldowns" and k2 == NIL and (...) == 61304 then -- the GCD: when it ends (hidden cooldowns use it)
    local v = vals[1]
    if type(v) == "table" and not Secret(v) and not Secret(v.startTime) and not Secret(v.duration)
        and type(v.startTime) == "number" and type(v.duration) == "number" then
      Sig.gcdEnd = v.duration > 0 and v.startTime + v.duration or 0
    end
  end
  if valid and not SameVals(e.vals, vals) then
    stat.wrong = stat.wrong + 1
    Report(piece, fn, { n = n, ... }, e, vals, now)
  end
  if valid then
    e.vals = vals -- (kept its time: its age is since the signal, not since the last check)
  else
    slot[k2] = { gen = st.gen, t = now, vals = vals, untilT = Expiry(piece, st, now, vals) }
  end
  return vals
end

-- A pass begins (State.BeginPass): in live mode, every REFEREE seconds this pass asks everything fresh and checks.
function Sig.BeginPass()
  if Sig.Mode() ~= "live" then
    return
  end
  local now = GetTime()
  Sig.refereeing = now - (Sig.lastReferee or 0) >= Sig.REFEREE
  if Sig.refereeing then
    Sig.lastReferee = now
  end
end

-- The decision itself: did the shown picks change while no piece saw a signal? (what skipping passes would miss)
Sig.decision = { passes = 0, quiet = 0, changedQuiet = 0 }
local lastSig, lastPick
function Sig.OnPick(result)
  local parts = {}
  for piece in pairs(Sig.PIECES) do
    parts[#parts + 1] = State(piece).gen
  end
  local sig = table.concat(parts, ",")
  local q = result and result.queue
  local pick = tostring(result and result.main and result.main.id) .. "/" .. tostring(q and q[2] and q[2].id)
  local d = Sig.decision
  d.passes = d.passes + 1
  if sig == lastSig then
    d.quiet = d.quiet + 1
    if pick ~= lastPick then
      d.changedQuiet = d.changedQuiet + 1 -- changed with no signal: time-based (a cooldown ending, a buff fading)
    end
  end
  lastSig, lastPick = sig, pick
end

-- Nothing signalled since the last pass (low power mode skips such passes, up to a limit)
local lastPassSig
function Sig.Quiet()
  local parts = {}
  for piece in pairs(Sig.PIECES) do
    parts[#parts + 1] = State(piece).gen
  end
  local sig = table.concat(parts, ",")
  local quiet = sig == lastPassSig
  lastPassSig = sig
  return quiet
end

-- Fight start / end
function Sig.Reset()
  Sig.stats, Sig.unmapped, Sig.missLogs, Sig.misses, Sig.missBy = {}, {}, 0, {}, {}
  Sig.decision = { passes = 0, quiet = 0, changedQuiet = 0 }
end

function Sig.Summary()
  local parts = { "mode=" .. Sig.Mode() }
  local names = {}
  for piece in pairs(Sig.stats) do
    names[#names + 1] = piece
  end
  table.sort(names)
  for _, piece in ipairs(names) do
    local s = Sig.stats[piece]
    parts[#parts + 1] = string.format("%s=%d/%d/%d", piece, s.wrong, s.valid, s.asked)
  end
  local un, unList = 0, {}
  for fn, c in pairs(Sig.unmapped) do
    un = un + c
    local name = ns.Record and ns.Record.Key and ns.Record.Key(fn, { n = 0 }) or "?"
    unList[#unList + 1] = { name = (name or "?"):gsub("%(%)$", ""), c = c }
  end
  table.sort(unList, function(a, b)
    return a.c > b.c
  end)
  local top = {}
  for i = 1, math.min(5, #unList) do
    top[i] = unList[i].name .. ":" .. unList[i].c
  end
  parts[#parts + 1] = "unmapped=" .. un .. (#top > 0 and ("(" .. table.concat(top, ",") .. ")") or "")
  local d = Sig.decision
  parts[#parts + 1] = string.format("passes=%d quiet=%d changed_quiet=%d", d.passes, d.quiet, d.changedQuiet)
  return table.concat(parts, " ")
end

function Sig.LogSummary()
  U.Log("signals", Sig.Summary()) -- piece=wrong/kept-and-valid/asked
end

-- the pieces hear the game's events on their own frame (all of them, whatever the addon itself listens to)
if CreateFrame then
  local f = CreateFrame("Frame")
  for e in pairs(touches) do
    pcall(f.RegisterEvent, f, e)
  end
  f:SetScript("OnEvent", function(_, event)
    Sig.OnEvent(event)
  end)
  Sig.frame = f
end

return Sig
