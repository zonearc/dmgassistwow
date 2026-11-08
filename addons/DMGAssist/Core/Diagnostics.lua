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
  if castName ~= nil then
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

function G.OnPick(result)
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
  local errors = {}
  for msg, n in pairs(U.callErrors or {}) do
    errors[#errors + 1] = n .. "x " .. msg
  end
  if #errors > 0 then
    U.Log("call_error_summary", table.concat(errors, " | "))
  end
  U.Log("haste_summary", { source = ns.State.hasteSource })
  G.range, G.picks = {}, {}
end

function G.OnCombat(inCombat)
  G.traces = 0
  if inCombat then
    G.range, G.picks = {}, {}
    G.Tick(true)
  else
    G.Tick(true)
    G.Summary()
  end
end
