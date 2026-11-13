-- Diagnostics.lua: what the game is giving us, logged so a fix never starts blind.
--
-- Once a second (and at every state change) each input we depend on is classified:
--   "ok" (readable), "secret" (hidden by restrictions), "nil" (no value), "error" (the call failed).
-- Every change of class is logged to the Watchdog with the time, combat state and restriction state:
--   readability  input=combo_points from=ok to=secret combat=true restricted=2
-- Numeric inputs also keep the range seen this fight (min/max). At the end of each fight one summary per input,
-- the clue sources' grades (checks/wrong/facts/disabled), how picks were made (simc / assisted / rules / guess /
-- branch / interrupt) and interrupt use are logged. Failed calls inside U.Call are counted by message and the first
-- of each logged ("call_error"), so "it went dark because our call errored" is visible too.
-- Taint itself (ADDON_ACTION_BLOCKED / FORBIDDEN, LUA_WARNING, error handler) is captured by DMGAssist_Watchdog.

local _, ns = ...
local U = ns.U

local G = {}
ns.Diagnostics = G

local INTERVAL = 1.0
G.state = {}    -- input -> class
G.range = {}    -- input -> { min, max, ok, secret, nilc, err }
G.picks = {}    -- source -> count (this fight)
local lastRun = 0

local function Restriction()
  local st = U.Get(C_RestrictedActions and C_RestrictedActions.GetAddOnRestrictionState,
    Enum and Enum.AddOnRestrictionType and Enum.AddOnRestrictionType.Combat or 0)
  return st
end

local function Class(ok, v)
  if not ok then
    return "error"
  end
  if v == nil then
    return "nil"
  end
  if U.IsSecret(v) then
    return "secret"
  end
  return "ok"
end

-- Record one observation of an input. ok = the call succeeded; v = its value (may be secret); class = force a
-- class (when we know the answer is hidden without asking).
function G.Observe(input, ok, v, class)
  class = class or Class(ok, v)
  local r = G.range[input]
  if not r then
    r = { ok = 0, secret = 0, nilc = 0, err = 0 }
    G.range[input] = r
  end
  if class == "ok" then
    r.ok = r.ok + 1
    if type(v) == "number" then
      r.min = (r.min and math.min(r.min, v)) or v
      r.max = (r.max and math.max(r.max, v)) or v
    end
  elseif class == "secret" then
    r.secret = r.secret + 1
  elseif class == "nil" then
    r.nilc = r.nilc + 1
  else
    r.err = r.err + 1
  end
  local before = G.state[input]
  if before ~= class then
    G.state[input] = class
    -- (The assistant's pick comes and goes with the target out of combat: only its in-combat changes matter.)
    local noise = input == "assisted_pick" and ns.State.combatStart == nil
    if before ~= nil and not noise then
      U.Log("readability", { input = input, from = before, to = class, combat = ns.State.combatStart ~= nil,
        restricted = Restriction() })
    end
  end
  return class
end

local function Probe(input, fn, ...)
  if type(fn) ~= "function" then
    return G.Observe(input, false, nil)
  end
  local ok, v = pcall(fn, ...)
  return G.Observe(input, ok, v)
end

local POWERS = { combo_points = 4, energy = 3, rage = 1, focus = 2, runic_power = 6, holy_power = 9, chi = 12,
  soul_shards = 7, astral_power = 8, arcane_charges = 16, essence = 19, insanity = 13, maelstrom = 11, fury = 17,
  mana = 0 }

-- Which power types matter for this spec: anything our spell data costs or gains.
local function SpecPowers()
  local used = {}
  for _, info in pairs(ns.SpellMap.info or {}) do
    for _, t in ipairs({ info.cost, info.gain }) do
      if t then
        for pt in pairs(t) do
          used[pt] = true
        end
      end
    end
  end
  return used
end

local function Fmt(n)
  if type(n) ~= "number" then
    return tostring(n)
  end
  if n == math.floor(n) then
    return tostring(n)
  end
  return string.format("%.1f", n)
end

-- What we know about each resource this spec uses, right now: exact ("astral_power=46"), a range from our
-- clues ("astral_power=46..100": the cast-by-cast floor, what we can / can't afford), or "?" (nothing).
-- The game hides most resources in combat; this is what the engine decides with.
function G.ResourceText()
  local used, parts = SpecPowers(), {}
  for name, pt in pairs(POWERS) do
    if used[pt] then
      local cur = U.Get(UnitPower, "player", pt)
      if type(cur) == "number" then
        parts[#parts + 1] = name .. "=" .. Fmt(cur)
      else
        local exact = ns.Clues.ShadowValue(pt)
        local lo, hi = ns.Clues.ResourceBounds(pt)
        if exact then
          parts[#parts + 1] = name .. "=" .. Fmt(exact) .. "(counted)"
        elseif lo then
          parts[#parts + 1] = name .. "=" .. Fmt(lo) .. ".." .. (hi == math.huge and "?" or Fmt(hi))
        else
          parts[#parts + 1] = name .. "=?"
        end
      end
    end
  end
  table.sort(parts)
  return table.concat(parts, " ")
end

-- Decision trace for a pick change in combat (at most TRACE_MAX per fight): what was shown, the resources as
-- the engine saw them, every list line checked and why it was passed over, and the terms it could not read.
local TRACE_MAX = 40
G.traces = 0

function G.Trace(result, traced)
  if G.traces >= TRACE_MAX then
    return
  end
  G.traces = G.traces + 1
  local q = {}
  for i, p in ipairs(result.queue or {}) do
    q[i] = tostring(p.token) .. "(" .. tostring(p.source) .. ")"
  end
  local unknown, n = {}, 0
  for name, count in pairs(ns.State.unknownTerms or {}) do
    n = n + 1
    unknown[n] = { name, count }
  end
  table.sort(unknown, function(a, b)
    return a[2] > b[2]
  end)
  local top = {}
  for i = 1, math.min(8, n) do
    top[i] = unknown[i][1]
  end
  local targets, label = ns.State.Targets()
  local c = ns.State.lastCount or {}
  local counted = string.format("(fighting %s, remembered %s, unreadable %s, dummies %s)", tostring(c.fighting),
    tostring(c.remembered), tostring(c.unknown), tostring(c.dummies))
  U.Log("decision_trace", string.format("show=%s | mode: %s targets=%s %s aoeAt=%s | res: %s | lines: %s | unknown: %s",
    table.concat(q, " > "), tostring(label), tostring(targets), counted, tostring(ns.State.AoeTargets()),
    G.ResourceText(),
    table.concat(traced or {}, "; "), table.concat(top, " ")))
end

function G.Tick(force)
  local now = GetTime()
  if not force and now - lastRun < INTERVAL then
    return
  end
  lastRun = now
  local used = SpecPowers()
  for name, pt in pairs(POWERS) do
    if used[pt] then
      Probe(name, UnitPower, "player", pt)
    end
  end
  Probe("haste", UnitSpellHaste, "player")
  Probe("target_health", UnitHealth, "target")
  local gcd = U.Call(C_Spell and C_Spell.GetSpellCooldown, 61304)
  G.Observe("cooldown_duration", type(gcd) == "table", type(gcd) == "table" and gcd.duration or nil)
  G.Observe("cooldown_isActive", type(gcd) == "table", type(gcd) == "table" and gcd.isActive or nil)
  local gcdDur = U.Call(C_Spell and C_Spell.GetSpellCooldownDuration, 61304)
  if type(gcdDur) == "table" and not U.IsSecret(gcdDur) and gcdDur.GetRemainingDuration then
    Probe("gcd_duration_remaining", gcdDur.GetRemainingDuration, gcdDur)
  else
    G.Observe("gcd_duration_remaining", true, gcdDur)
  end
  local cast = { U.Call(UnitCastingInfo, "player") }
  if cast[1] ~= nil then
    G.Observe("player_cast_end", true, cast[5])
  end
  -- Asking for auras while the game hides them raises an error inside the call, so ask first.
  if U.Get(C_Secrets and C_Secrets.ShouldAurasBeSecret) == true then
    G.Observe("player_aura", true, nil, "secret")
  else
    local aura = U.Call(C_UnitAuras and C_UnitAuras.GetAuraDataByIndex, "player", 1, "HELPFUL")
    if U.IsSecret(aura) or type(aura) ~= "table" then
      G.Observe("player_aura", true, aura)
    else
      G.Observe("player_aura", true, aura.spellId)
    end
  end
  G.Observe("aura_scan", true, ns.State.AurasReadable() and true or nil)
  Probe("assisted_pick", C_AssistedCombat and C_AssistedCombat.GetNextCastSpell, false)
  local castName = U.Call(UnitCastingInfo, "target")
  if U.IsSecret(castName) or castName ~= nil then
    local c = { U.Call(UnitCastingInfo, "target") }
    G.Observe("target_cast_spell", true, c[9])
    G.Observe("target_cast_interruptible", true, c[8])
  end
  local sh = ns.Clues.shadow[4]
  if sh then
    G.Observe("shadow_combo_points", true, sh.certain and sh.v or nil)
  end
  local cdm = _G.BuffIconCooldownViewer
  if type(cdm) == "table" and cdm.GetChildren then
    local first = select(1, U.Call(cdm.GetChildren, cdm))
    if type(first) == "table" then
      G.Observe("cdm_isActive", true, first.isActive)
    end
  end
  local list = U.Call(C_EncounterTimeline and C_EncounterTimeline.GetEventList)
  if type(list) == "table" and not U.IsSecret(list) and list[1] then
    Probe("timeline_remaining", C_EncounterTimeline.GetEventTimeRemaining, list[1])
  end
end

-- Prediction: when you press what slot 1 showed, was slot 2 right about what comes next? Per fight: how often, and
-- which predictions most often turned out to be something else ("pred>actual"), the data for any learning later
-- (owner, 2026-11-13: "I want you to see what I'm seeing" - the row reshuffling on Outlaw).
G.PRED_SETTLE = 0.15 -- seconds after the press before the next slot 1 counts (the press has to register first)
G.PRESS_SAME = 0.6    -- the same spell again within this: one press (Fan the Hammer's volley is 3 casts)
-- Slot 1 swapped for one of these is a situation, not the rotation changing its mind (counted apart)
G.SITUATIONAL = { interrupt = true, defensive = true, gapcloser = true, potion = true, trinket = true, buff = true }
-- Targets (owner, 2026-11-13): slot 1 steady 95% of the time between presses, slot 2 right 80-85%; slot 3 matters
-- least. "steady": slot 1 didn't change between one press and the next. Slot 2 right: what it showed at the press
-- was slot 1 once the press settled; slot 3 right: it was slot 2 then. The baseline: how often "the spell that
-- followed this one most often in this fight" came next, a fixed guess from the last press alone.
local function NewPred()
  return { n = 0, hit = 0, miss = {}, bySource = {}, n3 = 0, hit3 = 0,
    win = { n = 0, steady = 0, changes = 0, situational = 0 }, follow = {}, presses = 0, followed = 0 }
end
G.pred = NewPred()

local function Base(id)
  local baseOf = ns.SpellMap.baseOf or {}
  return id and (baseOf[id] or id)
end

-- A change of slot 1 counts once it is clear it wasn't your press: with the game's spell queue the next cast starts
-- the moment the GCD ends and slot 1 moves on, but the cast event arrives up to ~0.2 s later. 23 of 29 "changes"
-- in an Outlaw fight were that (2026-11-13): the spell that left slot 1 was cast right after.
G.QUEUED_PRESS = 0.3
local function CommitChange()
  local c = G.pendingChange
  G.pendingChange = nil
  if not c then
    return
  end
  local pr = G.pred
  if c.situational then
    pr.win.situational = pr.win.situational + 1
  else
    pr.win.changes = pr.win.changes + 1
    G.windowChanged = true
  end
end

function G.OnPress(id, shown, last)
  local pr = G.pred
  local now = GetTime()
  local lp = G.lastPress
  if lp and Base(lp.id) == Base(id) and now - lp.at < G.PRESS_SAME then
    return -- the rest of one press
  end
  G.lastPress = { id = id, at = now }
  local c = G.pendingChange
  if c and c.from == Base(id) and now - c.at <= G.QUEUED_PRESS then
    G.pendingChange = nil -- it left slot 1 because you had pressed it
  else
    CommitChange()
  end
  pr.presses = pr.presses + 1
  local win = G.window
  G.window = nil
  if not (id and shown and shown.id and last and last.queue) or Base(shown.id) ~= Base(id) then
    G.prevToken = nil
    return -- something other than slot 1: nothing was predicted for that
  end
  pr.followed = pr.followed + 1
  if win then
    win = pr.win
    win.n = win.n + 1
    if not G.windowChanged then
      win.steady = win.steady + 1
    end
  end
  local token = shown.token or tostring(id)
  if G.prevToken and not G.SITUATIONAL[shown.source or ""] then
    local f = pr.follow[G.prevToken] or {}
    pr.follow[G.prevToken] = f
    f[token] = (f[token] or 0) + 1
  end
  G.prevToken = not G.SITUATIONAL[shown.source or ""] and token or nil
  local q2, q3 = last.queue[2], last.queue[3]
  if q2 and q2.id then
    G.pending = { token = q2.token or tostring(q2.id), id = q2.id, at = now, source = q2.source or "?",
      q3 = q3 and q3.id and { id = q3.id } or nil }
  end
end

local function Settle(result)
  local main = result and result.main
  local p = G.pending
  if not p then
    -- between presses: does slot 1 change its mind?
    if G.pendingChange and GetTime() - G.pendingChange.at > G.QUEUED_PRESS then
      CommitChange()
    end
    if G.window and main and main.id and Base(main.id) ~= G.window then
      CommitChange()
      G.pendingChange = { from = G.window, at = GetTime(),
        situational = G.SITUATIONAL[main.source or ""] or G.SITUATIONAL[G.windowSource or ""] }
      G.window, G.windowSource = Base(main.id), main.source
    end
    return
  end
  if GetTime() - p.at < G.PRED_SETTLE then
    return
  end
  G.pending = nil
  if not (main and main.id) then
    return
  end
  local pr = G.pred
  pr.n = pr.n + 1
  local src = pr.bySource[p.source] or { n = 0, hit = 0 }
  pr.bySource[p.source] = src
  src.n = src.n + 1
  if Base(main.id) == Base(p.id) then
    pr.hit = pr.hit + 1
    src.hit = src.hit + 1
  else
    local k = p.token .. ">" .. tostring(main.token or main.id)
    pr.miss[k] = (pr.miss[k] or 0) + 1
  end
  local q2 = result.queue and result.queue[2]
  if p.q3 and q2 and q2.id then
    pr.n3 = pr.n3 + 1
    if Base(q2.id) == Base(p.q3.id) then
      pr.hit3 = pr.hit3 + 1
    end
  end
  G.window, G.windowSource, G.windowChanged = Base(main.id), main.source, false
end
G.SettlePrediction = Settle

local function Pct(a, b)
  return math.floor(100 * a / b + 0.5)
end

function G.PredictionText()
  local pr = G.pred
  if pr.n == 0 then
    return nil
  end
  local misses = {}
  for k, v in pairs(pr.miss) do
    misses[#misses + 1] = { k, v }
  end
  table.sort(misses, function(a, b)
    if a[2] ~= b[2] then
      return a[2] > b[2]
    end
    return a[1] < b[1]
  end)
  local top = {}
  for i = 1, math.min(6, #misses) do
    top[i] = misses[i][1] .. "x" .. misses[i][2]
  end
  local text = string.format("hit=%d%% n=%d misses: %s", Pct(pr.hit, pr.n), pr.n,
    #top > 0 and table.concat(top, " ") or "none")
  local w = pr.win
  local extra = {}
  if w.n > 0 then
    extra[#extra + 1] = string.format("slot1_steady=%d%% windows=%d changes=%d situational=%d", Pct(w.steady, w.n), w.n,
      w.changes, w.situational)
  end
  if pr.n3 > 0 then
    extra[#extra + 1] = string.format("slot3=%d%% n3=%d", Pct(pr.hit3, pr.n3), pr.n3)
  end
  local srcs = {}
  for src, c in pairs(pr.bySource) do
    srcs[#srcs + 1] = string.format("%s=%d/%d", src, c.hit, c.n)
  end
  table.sort(srcs)
  if #srcs > 0 then
    extra[#extra + 1] = "slot2_by_source " .. table.concat(srcs, " ")
  end
  local best, total = 0, 0
  for _, f in pairs(pr.follow) do
    local top1 = 0
    for _, c in pairs(f) do
      total = total + c
      top1 = math.max(top1, c)
    end
    best = best + top1
  end
  if total > 0 then
    extra[#extra + 1] = string.format("lastpress_baseline=%d%% n=%d", Pct(best, total), total)
  end
  if pr.presses > 0 then
    extra[#extra + 1] = string.format("followed=%d%% presses=%d", Pct(pr.followed, pr.presses), pr.presses)
  end
  if #extra > 0 then
    text = text .. " | " .. table.concat(extra, " | ")
  end
  return text
end

-- Major cooldowns, per fight (Outlaw 2026-11-13: "it didn't redo Adrenaline Rush when it was ready"; the decision
-- traces stop after 40, so the end of a long fight wasn't visible): each one's state at the pull, every time it
-- becomes pressable or stops being, and the first slot it shows in after that. Its casts are the C lines.
G.MAJOR_LOGS = 40
local function MajorTokens()
  local state = ns.Specs and ns.Specs.current
  local record = state and state.data
  return type(record) == "table" and type(record.blizzardExcluded) == "table" and record.blizzardExcluded or {}
end

-- (its cooldown only: whether it could be pressed is the engine's business, and asking reads more of the game)
local function MajorReady(id)
  local S = ns.State
  return S.CooldownReady and S.CooldownReady(id) == true
end

function G.MajorsAtPull()
  G.majors, G.majorLogs = {}, 0
  local parts = {}
  for _, token in ipairs(MajorTokens()) do
    local id = ns.SpellMap.SpellID(token)
    if id then
      local ready = MajorReady(id)
      G.majors[token] = { id = id, ready = ready }
      local left = not ready and ns.State.CooldownRemains and ns.State.CooldownRemains(id)
      parts[#parts + 1] = token .. "=" .. (ready and "ready"
        or ("not_ready(left=" .. (type(left) == "number" and string.format("%.0f", left) or "?") .. ")"))
    end
  end
  if #parts > 0 then
    U.Log("majors_at_pull", table.concat(parts, " "))
  end
end

local function TrackMajors(result)
  if not G.majors then
    return
  end
  for token, m in pairs(G.majors) do
    local ready = MajorReady(m.id)
    if ready ~= m.ready then
      m.ready, m.shown = ready, nil
      if G.majorLogs < G.MAJOR_LOGS then
        G.majorLogs = G.majorLogs + 1
        U.Log("major", { s = token, ready = ready })
      end
    end
    if ready and not m.shown then
      for i, p in ipairs(result and result.queue or {}) do
        if p and (p.id == m.id or p.token == token) then
          m.shown = i
          if G.majorLogs < G.MAJOR_LOGS then
            G.majorLogs = G.majorLogs + 1
            U.Log("major_shown", { s = token, slot = i })
          end
          break
        end
      end
    end
  end
end

function G.OnPick(result)
  Settle(result)
  TrackMajors(result)
  local main = result and result.main
  local source = main and main.source or "none"
  if result and result.branch then
    source = "branch"
  end
  G.picks[source] = (G.picks[source] or 0) + 1
end

-- End of fight: compact one-line summaries (the Watchdog keeps "_summary" lines up to 2000 characters).
--   readability_summary  combo_points=ok12/secret48[0..5] energy=secret60 haste=ok60[12.3..12.3] ...

function G.Summary()
  local parts = {}
  for input, r in pairs(G.range) do
    local p = input .. "="
    local counts = {}
    for _, k in ipairs({ "ok", "secret", "nilc", "err" }) do
      if r[k] > 0 then
        counts[#counts + 1] = (k == "nilc" and "nil" or k) .. r[k]
      end
    end
    p = p .. table.concat(counts, "/")
    if r.min then
      p = p .. "[" .. Fmt(r.min) .. ".." .. Fmt(r.max) .. "]"
    end
    parts[#parts + 1] = p
  end
  table.sort(parts)
  U.Log("readability_summary", table.concat(parts, " "))
  local clues = {}
  for source, st in pairs(ns.Clues.stats) do
    clues[#clues + 1] = string.format("%s=%d/%d/%d%s", source, st.checks, st.wrong, st.facts,
      st.disabled and "/OFF" or "")
  end
  table.sort(clues)
  U.Log("clue_summary", "checks/wrong/facts " .. table.concat(clues, " "))
  U.Log("pick_summary", G.picks)
  U.Log("interrupt_summary", ns.Interrupts.stats)
  CommitChange()
  local pred = G.PredictionText()
  if pred then
    U.Log("prediction_summary", pred)
  end
  local errors = {}
  for msg, n in pairs(U.callErrors or {}) do
    errors[#errors + 1] = n .. "x " .. msg
  end
  if #errors > 0 then
    U.Log("call_error_summary", table.concat(errors, " | "))
  end
  U.Log("haste_summary", { source = ns.State.hasteSource })
  G.range, G.picks = {}, {}
  G.pred, G.pending = NewPred(), nil
  G.window, G.windowChanged, G.prevToken, G.lastPress, G.pendingChange = nil, nil, nil, nil, nil
end

function G.OnCombat(inCombat)
  G.traces = 0
  if inCombat then
    G.range, G.picks = {}, {}
    G.pred, G.pending = NewPred(), nil
    G.window, G.windowChanged, G.prevToken, G.lastPress, G.pendingChange = nil, nil, nil, nil, nil
    G.MajorsAtPull()
    G.Tick(true)
  else
    G.majors = nil
    G.Tick(true)
    G.Summary()
  end
end
