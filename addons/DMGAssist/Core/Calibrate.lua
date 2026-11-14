-- DMGAssist: resource calibration. Our resource numbers come from SimC's data and the tooltips; when the game
-- shows they're wrong during play, the numbers are corrected, and the corrections are kept across sessions per
-- spec and talent loadout (DMGAssistDB.calibrate). Asked 2026-11-14: "when we cast a spell we remove [it] from our
-- estimated resource counter... realtime assessments".
--
-- Two cases, because Midnight hides some resources in combat and not others:
--
-- 1. Readable in combat (combo points, holy power, chi, soul shards...): after each cast we see how much it really
--    changed (Diagnostics' audit, AUDIT_AFTER s later). Once a spell has READ_N samples and one value covers
--    READ_SHARE of them (a crit or proc now and then doesn't count), that value replaces our data for the spell:
--    the counter and the look-ahead use it from then on.
-- 2. Hidden in combat (Astral Power, Insanity, Maelstrom, Fury, Runic Power, Rage): we count it from the last
--    readable value, cast by cast (Clues' floor). The game still answers "can I afford this spender?". When it says
--    yes and our count is lower, the count is raised to what the game just proved, right away. How much we were
--    short is shared between the spells that built the resource since the last proof, and per cast that becomes
--    an "expected extra" (talents, procs, passive gains) the look-ahead adds to each pretend cast, once a spell has
--    HIDDEN_N casts and the extra is at least HIDDEN_MIN. The count itself (the floor) stays a proven lower bound.
--    Energy and Focus are left out of the sharing: their shortfall is regeneration, not a spell's gain.
--
-- Older fights weigh less (DECAY each fight), so a hotfix or a talent change wins over time.

local _, ns = ...
local U, M = ns.U, ns.SpellMap
local K = {}
ns.Calibrate = K

K.READ_N = 6
K.READ_SHARE = 0.7
K.HIDDEN_N = 15
K.HIDDEN_MIN = 1
K.DECAY = 0.97
K.SNAP_LOGS = 10
K.since = {}  -- hidden power type -> { spellID -> casts since the last proof }
K.fight = {}  -- this fight: { raised = n, short = total, fixed = { text } }

local function ProfileKey()
  local state = ns.Specs and ns.Specs.current
  local key = state and state.key
  if not key then
    return nil
  end
  local config = U.Get(C_ClassTalents and C_ClassTalents.GetActiveConfigID)
  return key .. ":" .. tostring(type(config) == "number" and config or "?")
end

function K.Store()
  local g = ns.global or ns.db
  if type(g) ~= "table" then
    return nil
  end
  g.calibrate = type(g.calibrate) == "table" and g.calibrate or {}
  local key = ProfileKey()
  if not key then
    return nil
  end
  local p = g.calibrate[key]
  if type(p) ~= "table" or type(p.read) ~= "table" or type(p.hidden) ~= "table" then
    p = { read = {}, hidden = {} }
    g.calibrate[key] = p
  end
  return p
end

local function Discrete(pt)
  for _, v in pairs(ns.Clues.DISCRETE) do
    if v == pt then
      return true
    end
  end
  return false
end

local function Token(id)
  local info = M.Info(id)
  return (M.TokenForID and M.TokenForID(id)) or (info and info.n) or tostring(id)
end

---------------------------------------------------------------------------
-- 1. Readable resources
---------------------------------------------------------------------------
-- The most common change and its share; nil while too few samples.
local function Mode(h)
  local total, best, bestN = 0, nil, 0
  for d, n in pairs(h) do
    total = total + n
    if n > bestN then
      best, bestN = d, n
    end
  end
  if total < K.READ_N or bestN / total < K.READ_SHARE then
    return nil, total
  end
  return tonumber(best), total
end

-- Put a measured change into the spell's data (gain = change + cost). Returns the old net change if it changed.
local function ApplyRead(id, pt, h)
  local seen, n = Mode(h)
  local info = M.Info(id)
  if not (seen and info) then
    return nil
  end
  local costs = M.Cost(info)
  local cost = costs and costs[pt] or 0
  local gain = seen + cost
  if gain < 0 then
    return nil -- spends more than the data says: not a gain to correct (left to the audit)
  end
  local old = info.gain and info.gain[pt] or 0
  if old == gain then
    return nil
  end
  info.gain = info.gain or {}
  info.gainBase = info.gainBase or {}
  if info.gainBase[pt] == nil then
    info.gainBase[pt] = old
  end
  info.gainMeasured = info.gainMeasured or {}
  info.gainMeasured[pt] = true
  info.gain[pt] = gain > 0 and gain or nil
  return old - cost, seen, n
end

-- Diagnostics' audit: `id` changed readable power `pt` by `delta` (AUDIT_AFTER s after the cast).
function K.OnReadDelta(id, pt, delta)
  if not (id and Discrete(pt) and type(delta) == "number") then
    return
  end
  local info = M.Info(id)
  if not info or (info.cmax and info.cmax[pt]) then
    return -- finishers spend "up to N": their change depends on what you had
  end
  local store = K.Store()
  if not store then
    return
  end
  local key = id .. ":" .. pt
  local h = store.read[key] or {}
  store.read[key] = h
  local d = tostring(math.floor(delta + 0.5))
  h[d] = (h[d] or 0) + 1
  local was, seen, n = ApplyRead(id, pt, h)
  if was then
    local text = string.format("%s pt%d data=%+d seen=%+d n=%d", Token(id), pt, was, seen, n)
    K.fight.fixed = K.fight.fixed or {}
    K.fight.fixed[#K.fight.fixed + 1] = text
    U.Log("gain_fixed", text)
  end
end

---------------------------------------------------------------------------
-- 2. Hidden resources
---------------------------------------------------------------------------
-- Our own cast (after Clues has counted it): note which hidden resources it built.
function K.OnOwnCast(id)
  local info = id and M.Info(id)
  if not (info and info.gain) then
    return
  end
  local store = K.Store()
  for pt, amount in pairs(info.gain) do
    if amount > 0 and ns.Clues.floor[pt] and not ns.Clues.REGEN[pt] then
      local s = K.since[pt] or {}
      K.since[pt] = s
      s[id] = (s[id] or 0) + 1
      if store then
        local key = id .. ":" .. pt
        local e = store.hidden[key] or { casts = 0, extra = 0 }
        store.hidden[key] = e
        e.casts = e.casts + 1
      end
    end
  end
end

-- `short` more of `pt` than we counted, proven now: share it between the spells that built it since the last proof.
function K.Attribute(pt, short)
  local s = K.since[pt]
  K.since[pt] = nil
  if not (s and short and short > 0) or ns.Clues.REGEN[pt] then
    return
  end
  local weights, total = {}, 0
  for id, n in pairs(s) do
    local info = M.Info(id)
    local w = n * ((info and info.gain and info.gain[pt]) or 0)
    if w > 0 then
      weights[id], total = w, total + w
    end
  end
  local store = K.Store()
  if total <= 0 or not store then
    return
  end
  for id, w in pairs(weights) do
    local key = id .. ":" .. pt
    local e = store.hidden[key] or { casts = 0, extra = 0 }
    store.hidden[key] = e
    e.extra = e.extra + short * w / total
  end
end

-- Each pass in combat: if the game proves more of a hidden resource than we counted, raise the count to it.
function K.Snap()
  if not ns.State.combatStart then
    return
  end
  local C = ns.Clues
  if not C.Enabled("usable") then
    return
  end
  local now = GetTime()
  local bracket
  for pt, f in pairs(C.floor) do
    if f.moved then
      bracket = bracket or C.Affordability()
      local a = bracket[pt]
      local lo = C.FloorBounds(pt)
      local o = C.bounds[pt]
      local waiting = o and o.source == "wait" and o.untilT > now
      -- Energy / Focus: an answer far above anything we could have regenerated is a free proc (Feral's Rake after
      -- a free Shred, 2026-11-10). Built resources have no such limit here: a whole Astral Power gap (Starfire 12
      -- where the data said 8) is exactly what this is for; free procs there light the spell up and are skipped.
      local ceiling = C.REGEN[pt] and C.FloorCeiling(pt)
      local free = waiting or (ceiling and a and a.lo > ceiling)
      if a and lo and not free and a.lo > lo + 0.5 then
        local short = a.lo - lo
        C.RaiseFloor(pt, a.lo)
        K.Attribute(pt, short)
        local fs = K.fight
        fs.raised, fs.short = (fs.raised or 0) + 1, (fs.short or 0) + short
        if fs.raised <= K.SNAP_LOGS then
          U.Log("floor_raised", { power = pt, was = math.floor(lo), now = a.lo })
        end
      end
    end
  end
end

-- The expected extra per cast of `id` for hidden resource `pt` (whole points, at most the data's own gain).
function K.Extra(id, pt)
  local store = K.Store()
  local e = store and store.hidden[id .. ":" .. pt]
  if not (e and e.casts >= K.HIDDEN_N) then
    return 0
  end
  local per = e.extra / e.casts
  if per < K.HIDDEN_MIN then
    return 0
  end
  local info = M.Info(id)
  local gain = info and info.gain and info.gain[pt] or 0
  return math.min(math.floor(per), gain)
end

---------------------------------------------------------------------------
-- Fights
---------------------------------------------------------------------------
-- Put stored corrections into the spell data (it is rebuilt when a spec loads).
function K.ApplyAll()
  local store = K.Store()
  if not store then
    return
  end
  for key, h in pairs(store.read) do
    local id, pt = key:match("^(%d+):(%d+)$")
    if id then
      ApplyRead(tonumber(id), tonumber(pt), h)
    end
  end
end

function K.SummaryText()
  local store = K.Store()
  local parts = {}
  for _, t in ipairs(K.fight.fixed or {}) do
    parts[#parts + 1] = "fixed " .. t
  end
  if K.fight.raised then
    parts[#parts + 1] = string.format("raised=%d short=%d", K.fight.raised, math.floor(K.fight.short or 0))
  end
  local rows = {}
  for key, e in pairs(store and store.hidden or {}) do
    local id, pt = key:match("^(%d+):(%d+)$")
    if id and e.casts >= 1 and e.extra > 0 then
      rows[#rows + 1] = { string.format("%s pt%s %+.1f/cast n=%d used=%+d", Token(tonumber(id)), pt,
        e.extra / e.casts, math.floor(e.casts + 0.5), K.Extra(tonumber(id), tonumber(pt))), e.extra }
    end
  end
  table.sort(rows, function(x, y)
    return x[2] > y[2]
  end)
  for i = 1, math.min(8, #rows) do
    parts[#parts + 1] = rows[i][1]
  end
  return #parts > 0 and table.concat(parts, " | ") or nil
end

---------------------------------------------------------------------------
-- Matching with the game's own combat log (owner, 2026-11-14: "so you can use outputs across both")
---------------------------------------------------------------------------
-- WoWCombatLog.txt (Advanced Combat Logging) has every cast with its resource values, ours and everyone's in
-- range; the addon can't read it, the offline tools can. To line the two up, each fight logs `anchor_summary`:
-- GetTime() and the wall clock at the same moment, your character's GUID (how the log names you), the spec and the
-- talent loadout string (the log's COMBATANT_INFO carries the talents too). Our C lines (GetTime, spell ID) then
-- match your SPELL_CAST_SUCCESS lines to the millisecond.
function K.Anchor()
  local state = ns.Specs and ns.Specs.current
  local config = U.Get(C_ClassTalents and C_ClassTalents.GetActiveConfigID)
  local loadout = type(config) == "number" and U.Get(C_Traits and C_Traits.GenerateImportString, config) or nil
  local version = ns.VERSION
  U.Log("anchor_summary", string.format("t=%.3f epoch=%s date=%s guid=%s spec=%s version=%s loadout=%s",
    GetTime(), tostring(U.Get(time)), tostring(U.Get(date, "%Y-%m-%d %H:%M:%S")),
    tostring(U.Get(UnitGUID, "player")), tostring(state and state.key), tostring(version),
    type(loadout) == "string" and loadout or "?"))
end

-- Everything this spec and loadout has learned, at the end of each fight (`corrections_summary`), so it can go
-- back into the shipped data: readable resource changes (id:pt=value/n), hidden extras per cast (id:pt=+x/n),
-- cooldown timing corrections (spell=+s/n, unreliable marked !), regeneration seen (pt=rate@haste).
function K.CorrectionsText()
  local store = K.Store()
  local parts = { "profile=" .. tostring(ProfileKey()) }
  local read, hidden, timing, regen = {}, {}, {}, {}
  for key, h in pairs(store and store.read or {}) do
    local v, n = Mode(h)
    if v then
      read[#read + 1] = string.format("%s=%+d/%d", key, v, math.floor(n + 0.5))
    end
  end
  for key, e in pairs(store and store.hidden or {}) do
    if e.casts >= 1 and e.extra > 0 then
      hidden[#hidden + 1] = string.format("%s=%+.1f/%d", key, e.extra / e.casts, math.floor(e.casts + 0.5))
    end
  end
  local learned = ns.State.learned and ns.State.learned.timing or {}
  for name, t in pairs(learned) do
    if type(t) == "table" and (t.n or 0) >= 1 then
      timing[#timing + 1] = string.format("%s=%+.1f/%d%s", name, t.mean or 0, t.n, t.unreliable and "!" or "")
    end
  end
  for pt, r in pairs(ns.State.RegenSeen and ns.State.RegenSeen() or {}) do
    regen[#regen + 1] = string.format("%s=%.1f@%s", pt, r.rate, type(r.haste) == "number"
      and string.format("%.1f", r.haste) or "?")
  end
  for _, list in ipairs({ read, hidden, timing, regen }) do
    table.sort(list)
  end
  parts[#parts + 1] = "read " .. (#read > 0 and table.concat(read, " ") or "-")
  parts[#parts + 1] = "hidden " .. (#hidden > 0 and table.concat(hidden, " ") or "-")
  parts[#parts + 1] = "timing " .. (#timing > 0 and table.concat(timing, " ") or "-")
  parts[#parts + 1] = "regen " .. (#regen > 0 and table.concat(regen, " ") or "-")
  return table.concat(parts, " | ")
end

function K.OnCombat(inCombat)
  if inCombat then
    K.since, K.fight = {}, {}
    K.ApplyAll()
    K.Anchor()
    -- which hidden resources we count from the pull, and from what (nothing listed: we can't count them)
    local floors = {}
    for pt, f in pairs(ns.Clues.floor) do
      floors[#floors + 1] = pt .. "=" .. math.floor(f.lo)
    end
    table.sort(floors)
    U.Log("floors_at_pull", #floors > 0 and table.concat(floors, " ") or "none")
    return
  end
  U.Log("corrections_summary", K.CorrectionsText())
  local text = K.SummaryText()
  if text then
    U.Log("calibration_summary", text)
  end
  local store = K.Store()
  if store then
    for key, h in pairs(store.read) do
      local left = false
      for d, n in pairs(h) do
        h[d] = n * K.DECAY
        left = left or h[d] >= 0.05
      end
      if not left then
        store.read[key] = nil
      end
    end
    for key, e in pairs(store.hidden) do
      e.casts, e.extra = e.casts * K.DECAY, e.extra * K.DECAY
      if e.casts < 0.05 then
        store.hidden[key] = nil
      end
    end
  end
  K.since, K.fight = {}, {}
end
