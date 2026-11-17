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
K.HIDDEN_VERSION = 2
K.HIDDEN_MIN = 1
K.DECAY = 0.97
K.SNAP_LOGS = 100 -- (was 10: the rest of a fight's corrections went unseen)
K.since = {}  -- hidden power type -> { spellID -> casts since the last proof }
K.fight = {}  -- this fight: { raised = n, short = total, fixed = { text } }

local profileMemo = {}
local function ProfileKey()
  local state = ns.Specs and ns.Specs.current
  local key = state and state.key
  if not key then
    return nil
  end
  local ev = ns.State.inEvent -- (once per game event: asked 219 times in 14 casts)
  if not ev or profileMemo.event ~= ev or profileMemo.key ~= key then
    local config = U.Get(C_ClassTalents and C_ClassTalents.GetActiveConfigID)
    profileMemo.event, profileMemo.key = ev, key
    profileMemo.v = key .. ":" .. tostring(type(config) == "number" and config or "?")
  end
  return profileMemo.v
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
    p = { read = {}, hidden = {}, v = K.HIDDEN_VERSION }
    g.calibrate[key] = p
  end
  if p.v ~= K.HIDDEN_VERSION then
    -- hidden extras learned before 1.6.0.297 counted free spenders (procs) as paid and took "the game allows it" for
    -- proof: Starfire's +6 a cast was mostly that. Learned again from scratch.
    p.hidden, p.v = {}, K.HIDDEN_VERSION
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
  if gain <= 0 and old > 0 then
    -- never "learn" that a builder builds nothing: that is a measurement taken after the gain had landed (the
    -- offline grader: Sinister Strike's combo point went to 0 after six casts and Outlaw never finished again)
    return nil
  end
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
  if delta == 0 and not ((info.gain and info.gain[pt]) or (info.cost and info.cost[pt])) then
    return -- a resource this spell doesn't touch (Balance's combo points)
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
        -- the gain our data had for this cast: the extra is measured on top of it, and the data's number can change
        -- between fights (the tooltip is re-read out of combat, buffs included)
        -- (entries from before 1.6.0.295: their casts so far taken as built on today's gain)
        e.based = (e.based or e.casts * amount) + amount
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
    if f.moved or f.seeded then
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
      if a and not C.REGEN[pt] then
        K.NoteProof(pt, a.lo, a.hi)
      end
      if a and lo and a.hi < lo then
        C.CapFloor(pt, a.hi) -- the game: a spender we counted as affordable isn't: the count comes down
      elseif a and lo and not free and a.lo > lo + 0.5 then
        local short = a.lo - lo
        K.NoteError(pt, short)
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

---------------------------------------------------------------------------
-- 3. The fit: replay the fight, every spell and the clock (1.6.0.297)
---------------------------------------------------------------------------
-- The sharing above gives a correction only to spells our data says build the resource, and only when we were
-- found wrong. Balance showed what that misses (tools/resource-replay.py on the owner's fights 449-459, 2026-11-15):
-- on 8 targets Starfire builds ~16-22 Astral Power (data, from raid logs: 12), Fury of Elune and Incarnation build
-- some 20-40 our counting doesn't place, and more comes in by the second than the raid logs' average.
-- So each fight keeps its timeline for each counted hidden resource: our casts (with what our count did for each)
-- and every answer the game gave (a spender allowed: at least its cost; refused: less than it), whether our count
-- agreed or not. At the fight's end the last K.FIT_FIGHTS timelines are replayed under candidate models - an extra
-- per spell cast K.FIT_SEEN+ times, and a gain a second - and the model that strays least from the game's answers
-- is kept. The count and the look-ahead use K.FIT_SHARE of it (a little under: a spender isn't promised early),
-- once K.FIT_MIN answers back it. tools/resource-replay.py --learn runs the same fit on recorded fights.
K.FIT_MIN = 20
K.FIT_PRICE = 2 -- stray points per point of extra, per fight
K.FIT_OVER = 3
K.FIT_PROVE = 0.85 -- the latest fight's stray must drop to this share of it without the fit
K.FIT_FIGHTS = 3
K.FIT_EVENTS = 600 -- per fight and resource
K.FIT_SEEN = 3
K.FIT_SHARE = 0.75
K.FIT_MAX = 60
K.FIT_SWEEPS = 2
K.FIT_STEP = 2
K.FIT_RATE_STEP = 0.5
K.FIT_RATE_MAX = 15
K.tl = {} -- pt -> { casts = { {t, id, d} }, proofs = { {t, lo, hi} }, last = "lo:hi", t0 }

-- Fits are kept per number of targets: one target, two or three, four or more (what comes in by the second grows
-- with targets: Shooting Stars from damage over time; a fit made on 8 dummies would count far too much on a boss).
function K.Bucket(n)
  n = n or (ns.State.Targets and ns.State.Targets()) or 1
  n = type(n) == "number" and n or 1
  return n >= 4 and 4 or (n >= 2 and 2 or 1)
end

local function FitKey(pt, bucket)
  return pt .. ":" .. (bucket or K.Bucket())
end

function K.Fitted(pt)
  local store = K.Store()
  local f = store and store.fit and store.fit[FitKey(pt)]
  if f and (f.n or 0) >= K.FIT_MIN and f.validated then
    return f
  end
  return nil
end

-- The gain a second the fit found for `pt` (as used: K.FIT_SHARE of it), 0 without a fit.
function K.PassiveRate(pt)
  local f = K.Fitted(pt)
  return f and (f.rate or 0) * K.FIT_SHARE or 0
end

local function Timeline(pt)
  local tl = K.tl[pt]
  if not tl then
    tl = { casts = {}, proofs = {}, t0 = ns.State.combatStart or GetTime() }
    K.tl[pt] = tl
  end
  return tl
end

-- Our cast, as our count took it (`d`: gain - cost as charged, before any fitted extra).
function K.NoteCast(id, pt, d)
  if not ns.State.combatStart then
    return
  end
  local tl = Timeline(pt)
  -- the income our count took a second during this fight (the fit runs after it, when PassiveGain says 0: fitted
  -- against 0, the whole income was learned again and counted twice - offline Devourer, 2026-11-15)
  local passive = ns.State.PassiveGain and ns.State.PassiveGain(pt) or 0
  tl.base = (ns.Clues.PASSIVE_SHARE or 0) * passive
  if #tl.casts < K.FIT_EVENTS then
    tl.casts[#tl.casts + 1] = { GetTime() - tl.t0, id, d }
    local b = K.Bucket()
    tl.buckets = tl.buckets or {}
    tl.buckets[b] = (tl.buckets[b] or 0) + 1
  end
end

-- The game's answer this pass: at least lo, at most hi (each pass; kept when it changes).
function K.NoteProof(pt, lo, hi)
  if not ns.State.combatStart then
    return
  end
  local tl = Timeline(pt)
  hi = hi == math.huge and -1 or hi -- (saved variables can't hold infinity: -1 is "no upper answer")
  local key = lo .. ":" .. hi
  if tl.last ~= key and #tl.proofs < K.FIT_EVENTS then
    tl.last = key
    tl.proofs[#tl.proofs + 1] = { GetTime() - tl.t0, lo, hi }
  end
end

-- Replay one timeline under a model: how far the count strays from the game's answers (and how many answers).
local function Stray(tl, extra, rate, base, cap)
  local casts, proofs = tl.casts, tl.proofs
  local ci, pi = 1, 1
  local v, last = 0, 0
  local err, n = 0, 0
  while ci <= #casts or pi <= #proofs do
    local c, p = casts[ci], proofs[pi]
    local isCast = c and (not p or c[1] <= p[1])
    local t = isCast and c[1] or p[1]
    v = v + (base + rate) * (t - last)
    last = t
    if isCast then
      v = v + c[3] + (extra[c[2]] or 0)
      ci = ci + 1
    else
      if v < p[2] then
        err, v = err + p[2] - v, p[2]
      elseif p[3] >= 0 and v > p[3] then
        -- over counts K.FIT_OVER times: a count ahead of the truth promises a spender early, which costs slot 2
        -- more than one behind (offline Devourer: stray 1500 -> 274 with the fit, slot 2 92% -> 43%, all of it
        -- "Void Ray predicted, not affordable")
        err, v = err + (v - p[3]) * K.FIT_OVER, p[3]
      end
      n = n + 1
      pi = pi + 1
    end
    if v < 0 then
      v = 0
    elseif v > cap then
      v = cap
    end
  end
  return err, n
end

function K.Fit(pt)
  local store = K.Store()
  if not store then
    return nil
  end
  local tl = K.tl[pt]
  -- the fight's number of targets: the one most casts were made at
  local bucket, most = K.Bucket(), -1
  for b, n in pairs(tl and tl.buckets or {}) do
    if n > most then
      bucket, most = b, n
    end
  end
  local key = FitKey(pt, bucket)
  store.timelines = type(store.timelines) == "table" and store.timelines or {}
  local list = store.timelines[key] or {}
  store.timelines[key] = list
  if tl and #tl.proofs > 0 then
    list[#list + 1] = { casts = tl.casts, proofs = tl.proofs, base = tl.base }
    while #list > K.FIT_FIGHTS do
      table.remove(list, 1)
    end
  end
  local proofs, seen = 0, {}
  for _, f in ipairs(list) do
    proofs = proofs + #f.proofs
    for _, c in ipairs(f.casts) do
      seen[c[2]] = (seen[c[2]] or 0) + 1
    end
  end
  if proofs == 0 then
    return nil
  end
  local ids = {}
  for id, n in pairs(seen) do
    if n >= K.FIT_SEEN then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  local passive = ns.State.PassiveGain and ns.State.PassiveGain(pt) or 0
  local base = (ns.Clues.PASSIVE_SHARE or 0) * passive
  local cap = ns.State.PowerMax and ns.State.PowerMax(pt) or 100
  cap = (type(cap) == "number" and cap > 0) and cap or 100
  local old = store.fit and store.fit[key]
  -- coordinate search over `fights`, from the last fit: an extra per spell and the rate
  local function Search(fights)
    local extra, rate = {}, old and old.rate or 0
    for _, id in ipairs(ids) do
      extra[id] = old and old.w and old.w[id] or 0
    end
    -- (a small price per point of extra a spell is given: where a spell cast every few seconds and a gain by the
    -- second explain the answers about as well, the second wins - the offline Devourer fit put a steady Fury income
    -- on Consume, +40 a cast, and slot 2 then promised Void Ray right after every Consume)
    local function Score()
      local e = 0
      for _, f in ipairs(fights) do
        e = e + Stray(f, extra, rate, f.base or base, cap)
      end
      for _, x in pairs(extra) do
        e = e + x * K.FIT_PRICE * #fights
      end
      return e
    end
    local best = Score()
    for _ = 1, K.FIT_SWEEPS do
      do -- the rate first
        local keep = rate
        for r = 0, K.FIT_RATE_MAX, K.FIT_RATE_STEP do
          rate = r
          local e = Score()
          if e < best then
            best, keep = e, r
          end
        end
        rate = keep
      end
      for _, id in ipairs(ids) do
        local keep = extra[id]
        for x = 0, K.FIT_MAX, K.FIT_STEP do
          extra[id] = x
          local e = Score()
          if e < best then
            best, keep = e, x
          end
        end
        extra[id] = keep
      end
      local keep = rate
      for r = 0, K.FIT_RATE_MAX, K.FIT_RATE_STEP do
        rate = r
        local e = Score()
        if e < best then
          best, keep = e, r
        end
      end
      rate = keep
    end
    return extra, rate, best
  end
  -- Used only once it has proved itself: fitted on the earlier fights, it must cut the latest fight's stray (as the
  -- count would use it, at K.FIT_SHARE) by K.FIT_PROVE. Offline (tools/sim.py, 2026-11-15) an unproved fit made
  -- Shadow's single-target slot 2 worse (92-98% -> 65-74%) while helping Devourer's AoE and Havoc.
  local validated, heldOut, without = false, nil, nil
  if #list >= 2 then
    local train = {}
    for i = 1, #list - 1 do
      train[i] = list[i]
    end
    local tx, tr = Search(train)
    local used = {}
    for id, x in pairs(tx) do
      used[id] = math.floor(x * K.FIT_SHARE)
    end
    local last = list[#list]
    without = Stray(last, {}, 0, last.base or base, cap)
    heldOut = Stray(last, used, tr * K.FIT_SHARE, last.base or base, cap)
    validated = heldOut < without * K.FIT_PROVE
  end
  local extra, rate, best = Search(list)
  local fit = { n = proofs, w = {}, rate = rate, stray = best, validated = validated, heldOut = heldOut,
    without = without }
  for id, x in pairs(extra) do
    if x > 0 then
      fit.w[id] = x
    end
  end
  store.fit = type(store.fit) == "table" and store.fit or {}
  store.fit[key] = fit
  return fit
end

function K.FitText()
  local store = K.Store()
  local parts = {}
  for pt, f in pairs(store and store.fit or {}) do
    local spells = {}
    for id, x in pairs(f.w or {}) do
      spells[#spells + 1] = string.format("%s%+.0f", Token(tonumber(id) or id), x)
    end
    table.sort(spells)
    parts[#parts + 1] = string.format("pt%s targets=%s answers=%d stray=%.0f rate=+%.1f/s %s%s%s",
      tostring(pt):match("^(%d+)") or pt, ({ ["1"] = "1", ["2"] = "2-3", ["4"] = "4+" })[tostring(pt):match(":(%d+)$")
      or ""] or "?", f.n or 0, f.stray or 0,
      f.rate or 0, table.concat(spells, " "),
      f.heldOut and string.format(" latest fight: %.0f with it, %.0f without", f.heldOut, f.without) or "",
      ((f.n or 0) >= K.FIT_MIN and f.validated) and "" or " (not used yet)")
  end
  return #parts > 0 and table.concat(parts, " | ") or nil
end

-- The fit's extra per cast (as used: K.FIT_SHARE of it), 0 without a fit.
function K.FitExtra(id, pt)
  local fit = K.Fitted(pt)
  return fit and math.min(K.FIT_MAX, math.floor((fit.w[id] or 0) * K.FIT_SHARE)) or 0
end

-- The expected extra per cast of `id` for hidden resource `pt` (whole points): from the fit once there is one
-- (any spell, up to K.FIT_MAX), else from the sharing (builders only, at most the data's own gain).
function K.Extra(id, pt)
  local fit = K.Fitted(pt)
  if fit then
    local x = fit.w[id] or 0
    return math.min(K.FIT_MAX, math.floor(x * K.FIT_SHARE))
  end
  local store = K.Store()
  local e = store and store.hidden[id .. ":" .. pt]
  if not (e and e.casts >= K.HIDDEN_N) then
    return 0
  end
  local info = M.Info(id)
  local gain = info and info.gain and info.gain[pt] or 0
  local per = e.extra / e.casts
  -- Measured: what a cast really built = the data's gain at the time + the extra. Against today's gain: when the
  -- tooltip moved Starfire from 17 to 12 between fights, the old extra (+5) left the look-ahead 4-5 short a cast and
  -- slot 2 stopped offering Starfall after Starfire (owner's fights 452 / 455, 2026-11-15).
  if e.based and e.based > 0 then
    per = (e.based + e.extra) / e.casts - gain
  end
  if per < K.HIDDEN_MIN then
    return 0
  end
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

-- The numbers this fight's decisions start from, at the pull: each spell's cost and gain as the look-ahead uses
-- them (live cost, tooltip / measured gain, calibrated extra) and whether the Cooldown Manager is read. Learned
-- values change between fights without a release; comparing two fights needs both models side by side (fights 452
-- and 455: Starfire's gain moved 22 -> 17 and Starfall's cost 34 -> 45 with no code change, 2026-11-15).
function K.ModelAtPull()
  local rows = {}
  local book = M.book or {}
  for id, b in pairs(book) do
    local info = b.id == id and M.Info(id)
    if info and (info.gain or info.cost) then
      local parts = {}
      for pt, amount in pairs(M.Cost(info) or {}) do
        parts[#parts + 1] = string.format("c%d=%s%s", pt, amount, info.costLive and "" or "(data)")
      end
      for pt, amount in pairs(info.gain or {}) do
        local extra = K.Extra(id, pt)
        parts[#parts + 1] = string.format("g%d=%s%s%s", pt, amount,
          info.gainMeasured and info.gainMeasured[pt] and "(measured)"
            or (info.gainBase and info.gainBase[pt] ~= amount and "(tooltip)" or ""),
          extra ~= 0 and string.format("%+d", extra) or "")
      end
      table.sort(parts)
      rows[#rows + 1] = Token(id) .. ":" .. table.concat(parts, ",")
    end
  end
  table.sort(rows)
  local cdm = ns.db and ns.db.cdmIgnore and "ignored" or (ns.CDM and ns.CDM.Enabled() == false and "off" or "on")
  U.Log("model_at_pull_summary", "cdm=" .. cdm .. " | " .. table.concat(rows, " ") .. " | fit " ..
    (K.FitText() or "-"))
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
    K.since, K.fight, K.tl = {}, {}, {}
    K.ApplyAll()
    K.Anchor()
    -- which hidden resources we count from the pull, and from what (nothing listed: we can't count them)
    local floors = {}
    for pt, f in pairs(ns.Clues.floor) do
      floors[#floors + 1] = pt .. "=" .. math.floor(f.lo)
    end
    table.sort(floors)
    local reads, now = {}, GetTime()
    for pt, r in pairs(ns.State.powerRead or {}) do
      reads[#reads + 1] = string.format("%s:%s%s", pt, tostring(r.state),
        r.okAt and string.format("(ok %.1fs ago)", now - r.okAt) or "(never ok)")
    end
    table.sort(reads)
    U.Log("floors_at_pull", (#floors > 0 and table.concat(floors, " ") or "none") .. " | read " ..
      (#reads > 0 and table.concat(reads, " ") or "-"))
    K.ModelAtPull()
    return
  end
  -- (the fit replays up to three fights: ~0.25 s, done just after combat so it lands in this fight's log)
  for pt in pairs(ns.Clues.floor) do
    if not ns.Clues.REGEN[pt] then
      K.Fit(pt)
    end
  end
  local fitText = K.FitText()
  if fitText then
    U.Log("fit_summary", fitText)
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
      e.based = e.based and e.based * K.DECAY
      if e.casts < 0.05 then
        store.hidden[key] = nil
      end
    end
  end
  K.since, K.fight = {}, {}
end

-- How far our count of a hidden resource tends to be from what the game proves (a spender usable at a count below its
-- cost, or not usable above it): a slow running average per resource, kept with the loadout's other corrections
-- (DMGAssistDB.calibrate, across logins). The spending margin (K.Margin) is built from it.
K.ERROR_RATE = 0.1   -- each new proof's share of the average
K.ERROR_MIN_N = 5    -- proofs before the margin is used
function K.NoteError(pt, err)
  local p = K.Store()
  if not p or type(err) ~= "number" or err <= 0 then
    return
  end
  p.margin = type(p.margin) == "table" and p.margin or {}
  local m = p.margin[pt]
  if type(m) ~= "table" then
    m = { e = err, n = 0 }
    p.margin[pt] = m
  end
  m.e = m.e + K.ERROR_RATE * (err - m.e)
  m.n = m.n + 1
end

-- The spending margin for a hidden resource (owner, 2026-11-16: "make sure that with energy spending we always add a
-- comfortable buffer ... dynamic ... persistent across logins"): with the setting on (DMGAssistDB.spendMargin), a
-- spender waits until our count clears its cost by how far off we tend to be, so the cycle is predictable - one
-- more builder now and then instead of a spender the count can't promise. 0 when off or not learned yet.
function K.Margin(pt)
  if not (ns.db and ns.db.spendMargin) then
    return 0
  end
  local p = K.Store()
  local m = p and type(p.margin) == "table" and p.margin[pt]
  if type(m) ~= "table" or (m.n or 0) < K.ERROR_MIN_N then
    return 0
  end
  return m.e
end

-- The fight's line for the margin: on/off, the learned error per hidden resource (n proofs), how often it held a
-- spender back (Engine.HoldForMargin).
K.holds = 0
function K.LogMargin()
  local p = K.Store()
  local parts = { "on=" .. tostring(ns.db and ns.db.spendMargin and 1 or 0), "holds=" .. tostring(K.holds) }
  for pt, m in pairs(p and type(p.margin) == "table" and p.margin or {}) do
    if type(m) == "table" then
      parts[#parts + 1] = string.format("pt%s=%.1f(n=%d)", tostring(pt), m.e or 0, m.n or 0)
    end
  end
  U.Log("spend_margin", table.concat(parts, " "))
  K.holds = 0
end

