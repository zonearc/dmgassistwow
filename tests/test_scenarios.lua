-- Run from the repo root:  lua5.1 tests/test_scenarios.lua [--update] [spec-filter]
--
-- Every spec, through the real pipeline (ns.Update: engine, steady slot 1, leveling lead, essentials, buffs,
-- interrupts, defensives), in simulated dummy fights with the game's restrictions on (hidden resources, cooldowns
-- and auras): a player who presses slot 1 whenever the GCD allows, and a simple Blizzard assistant that names the
-- first rotation spell that is ready. Three fights per spec: one target, five targets, and leveling mode.
--
-- Why: a fix for one class must not quietly break another (2026-11-10: Destruction's Summon Infernal sat in slot 2
-- for 40 s in leveling mode while Balance and Guardian were being fixed). Two kinds of checks:
--   rules     must hold for every spec, always (any failure fails the build):
--               no errors; something in slot 1 nearly all the time; a ready major cooldown never waits in slot
--               2/3 behind Blizzard's pick for long; no spell held longer than the hold lasts
--   baseline  each spec's numbers (major cooldowns used, distinct spells pressed, empty slots, slot 1 flips) are
--             compared with tests/scenario_baseline.lua: getting worse fails the build. After an intended change,
--             run with --update to record the new numbers (and say why in the commit).
package.path = "./tests/?.lua;" .. package.path

local mock = require("wow_mock")
local print = print
mock.Install(_G)

local UPDATE, FILTER = false, nil
for _, a in ipairs(arg or {}) do
  if a == "--update" then
    UPDATE = true
  else
    FILTER = a
  end
end

local FIGHT = tonumber(_G.SCEN_FIGHT) or 40 -- seconds per fight (the combo miner runs longer ones)
local TICK = 0.2      -- seconds between decisions
local STUCK_MAX = 6   -- a ready major cooldown may wait behind Blizzard's pick at most this long
local NO_PICK_MAX = 10 -- percent of the fight with nothing in slot 1
local BASELINE = "tests/scenario_baseline.lua"
local AC_EARLY = 1.5 -- s: Blizzard's assistant names a spell this long before it is back
local PERF_NONE_MAX = 20 -- ms per update (this interpreter) when nothing can be cast: no repeated look-ahead

local function Boot()
  mock.frames, mock.timers, mock.printed = {}, {}, {}
  mock.restricted, mock.inCombat, mock.hasTarget = false, false, true
  mock.gameType = "standard"
  WOW_PROJECT_ID = 1
  DMGAssistDB = nil
  mock.class, mock.specs, mock.specIndex = { "Druid", "DRUID", 11 }, { [1] = 103 }, 1
  local ns = mock.LoadAddon("addons/DMGAssist", "DMGAssist")
  mock.Fire("ADDON_LOADED", "DMGAssist")
  mock.Fire("PLAYER_LOGIN")
  return ns
end

-- One castable spell per action token the data knows (like the fuzz test). No racials: a character has one
-- race's, and the data lists every race's (some without their real cooldown, so they'd be pressed forever).
local RACIALS = { arcane_torrent = true, berserking = true, blood_fury = true, fireblood = true,
  ancestral_call = true, bag_of_tricks = true, lights_judgment = true, arcane_pulse = true, haymaker = true,
  rocket_barrage = true, azerite_surge = true, shadowmeld = true, war_stomp = true, quaking_palm = true }
local function BookFor(record)
  local book, seen = {}, {}
  for token, e in pairs(record.spells or {}) do
    local id = e.a and e.a[1]
    local info = id and record.spellInfo[id]
    if id and not seen[id] and info and not info.pas and not RACIALS[token] then
      seen[id] = true
      book[#book + 1] = { spellID = id, name = token }
    end
  end
  table.sort(book, function(a, b) return a.spellID < b.spellID end)
  return book
end

-- Major cooldowns: the ones Blizzard leaves out of its assistant, minus movement (Fel Rush, Vengeful Retreat are on
-- that list but aren't damage cooldowns, and are never forced in: Engine G.NO_ESCALATE).
local NS -- set after boot
local function Majors(record)
  local set = {}
  for _, t in ipairs(record.blizzardExcluded or {}) do
    if not (NS and NS.Engine.NO_ESCALATE[t]) then
      set[t] = true
    end
  end
  return set
end

-- The spells the spec's keep-ups need (Hunter's Mark, Shield / Radiance, Renewing Mist): SimC's lists leave them
-- out, so the spellbook built from the lists lacks them. Added for the group fight only; Blizzard's simulated
-- assistant never names them (the real one doesn't for keep-ups either).
local KEEPUP_SPELLS = { hunters_mark = 257284, power_word_shield = 17, power_word_radiance = 194509,
  renewing_mist = 115151 }
local function KeepUpBook(ns, key, book)
  local extra, have = {}, {}
  for _, b in ipairs(book) do
    have[b.spellID] = true
  end
  for _, k in ipairs(ns.Essentials.KEEPUPS[key] or {}) do
    for _, token in ipairs(k.ramp or { k.token }) do
      local id = KEEPUP_SPELLS[token]
      if id and not have[id] then
        have[id] = true
        extra[id] = token
      end
    end
  end
  local out = {}
  for i, b in ipairs(book) do
    out[i] = b
  end
  for id, token in pairs(extra) do
    out[#out + 1] = { spellID = id, name = token }
  end
  return out, extra
end

local function Fight(ns, key, record, book, scenario)
  local M, G = ns.SpellMap, ns.Engine
  local majors = Majors(record)
  local keepIDs, baseBook = {}, book
  if scenario.group then
    book, keepIDs = KeepUpBook(ns, key, book)
    mock.book = book
    M.Refresh()
  end
  mock.boss, mock.groupSize = scenario.boss or nil, scenario.group or nil
  ns.db.healSupport = scenario.group and true or nil
  -- the game state at the pull
  mock.cooldowns, mock.usable, mock.auras = {}, {}, { player = {}, target = {} }
  mock.power, mock.powerMax, mock.powerReadable = {}, {}, {}
  for pt = 0, 19 do
    mock.powerMax[pt] = (pt == 4 or pt == 7 or pt == 9 or pt == 12 or pt == 16 or pt == 19) and 5 or 100
    mock.power[pt] = math.floor(mock.powerMax[pt] * 0.6)
  end
  mock.nameplates = scenario.targets
  mock.restricted, mock.inCombat = false, false
  ns.Specs.current = { key = key, status = "ready", data = record, branch = "midnight", client = "Midnight",
    leveling = scenario.leveling or nil }
  ns.db.levelingMode = scenario.leveling and "blizzard" or "simc"
  G.ResetSteady()
  mock.Advance(1)
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  local start = mock.now
  local m = { ticks = 0, noMain = 0, no2 = 0, no3 = 0, flips = 0, maxStuck = 0, maxHold = 0, errors = 0,
    presses = 0, pressed = {}, majorsCast = {}, majorsKnown = 0, firstError = nil, onCd = 0, skipShown = {} }
  for token in pairs(majors) do
    if M.SpellID(token) then
      m.majorsKnown = m.majorsKnown + 1
    end
  end
  local gcdEnd, lastMain, lastPress, stuck, charges = 0, nil, -10, {}, {}
  local predict -- slot 2's spell when slot 1 was pressed: checked against slot 1 on the next tick
  m.predN, m.predHit = 0, 0
  while mock.now - start < FIGHT do
    mock.Advance(TICK)
    local now = mock.now
    for id, c in pairs(charges) do
      while c.next and now >= c.next do
        c.n = c.n + 1
        c.next = c.n < c.max and (c.next + c.len) or nil
      end
    end
    for id, c in pairs(mock.cooldowns) do
      if c.start + c.duration <= now then
        mock.cooldowns[id] = nil
      end
    end
    -- Blizzard's assistant: the first rotation spell that is ready or about to be (never a major cooldown). The
    -- real one names a spell up to a second or two before it is back (Holy Shock 1.6 s, Judgment 2.8 s early in
    -- a Holy Paladin log, 2026-11-10); one that named only ready spells taught our clock wrong numbers.
    mock.acSpell = nil
    for _, b in ipairs(book) do
      local token = M.TokenForID(b.spellID)
      local cd = mock.cooldowns[b.spellID]
      local soon = not cd or (cd.start + cd.duration - now) <= AC_EARLY
      -- (forms and buffs only when you're out of them: the real assistant names those just then)
      if soon and not (token and majors[token]) and not ns.Essentials.FORMS[b.spellID]
        and not keepIDs[b.spellID]
        and not ns.Buffs.IsBuffSpell(b.spellID) and not (token and G.SKIP[token]) then
        mock.acSpell = b.spellID
        break
      end
    end
    if scenario.unusable then
      for _, b in ipairs(book) do
        mock.usable[b.spellID] = { false, false } -- no weapon: nothing can be cast
      end
    end
    local c0 = os.clock()
    local ok, r = pcall(ns.Update)
    local ms = (os.clock() - c0) * 1000
    m.msTotal, m.msPeak = (m.msTotal or 0) + ms, math.max(m.msPeak or 0, ms)
    if _G.SCEN_DEBUG and scenario.name == (_G.SCEN_ONLY or scenario.name) then
      _G.SCEN_DEBUG(now - start, r)
    end
    if not ok then
      m.errors = m.errors + 1
      m.firstError = m.firstError or tostring(r)
      ns.State.EndLookahead()
      r = nil
    end
    m.ticks = m.ticks + 1
    local main = r and r.main
    local q = r and r.queue or {}
    if not (main and main.id) then
      m.noMain = m.noMain + 1
    end
    if not q[2] then
      m.no2 = m.no2 + 1
    end
    if not q[3] then
      m.no3 = m.no3 + 1
    end
    -- shown as ready while its cooldown is still running (not marked "not yet")
    if main and main.id and mock.cooldowns[main.id] and not main.readyAt and main.source ~= "soon"
      and now - lastPress > 0.3 then
      m.onCd = m.onCd + 1
    end
    -- never something that isn't pressed by hand (auto attacks, group cooldowns)
    for _, p in ipairs(q) do
      if p and p.token and G.SKIP[p.token] then
        m.skipShown[p.token] = true
      end
    end
    if main and lastMain and main.id ~= lastMain and now - lastPress > 0.45 then
      m.flips = m.flips + 1
    end
    lastMain = main and main.id
    -- a ready major cooldown waiting in slot 2 / 3 while slot 1 shows Blizzard's pick
    local waiting = {}
    if main and main.source == "assisted" then
      for i = 2, #q do
        local p = q[i]
        if p and p.id and (p.major or (p.token and majors[p.token])) and not mock.cooldowns[p.id]
          and G.Castable(p.id) == true then
          waiting[p.id] = true
        end
      end
    end
    for id in pairs(stuck) do
      if not waiting[id] then
        stuck[id] = nil
      end
    end
    for id in pairs(waiting) do
      stuck[id] = stuck[id] or now
      m.maxStuck = math.max(m.maxStuck, now - stuck[id])
    end
    for _, t in pairs(G.held) do
      if type(t) == "number" then
        m.maxHold = math.max(m.maxHold, now - t)
      end
    end
    -- the player: presses slot 1 when the GCD allows and it isn't shown as "not yet"
    if r and main and main.id and now >= gcdEnd and not (main.readyAt and main.readyAt > now)
      and not mock.cooldowns[main.id] then
      local id = main.id
      -- prediction: was slot 2 at the last press what you pressed next? (as the in-game summary measures it)
      if predict then
        m.predN = m.predN + 1
        if id == predict then
          m.predHit = m.predHit + 1
        end
      end
      predict = q[2] and q[2].id or nil
      local info = M.Info(id) or {}
      local gcd = tonumber(info.gcd) or 1.5
      local ct = tonumber(info.ct) or 0
      gcdEnd = now + math.max(gcd, ct, 0.5)
      mock.cooldowns[61304] = { active = true, start = now, duration = math.max(gcd, 0.5), onGCD = true }
      local chcd = tonumber(info.chcd)
      local cd = tonumber(info.cd) or 0
      if chcd and chcd > 0 then
        -- charges: on cooldown only when the last one is spent; one recharges at a time
        local c = charges[id] or { n = tonumber(info.ch) or 2, max = tonumber(info.ch) or 2 }
        charges[id] = c
        c.n = c.n - 1
        c.next = c.next or (now + chcd)
        c.len = chcd
        if c.n <= 0 then
          mock.cooldowns[id] = { active = true, start = c.next - chcd, duration = chcd }
        end
      elseif cd > 1.5 then
        mock.cooldowns[id] = { active = true, start = now, duration = cd }
      end
      mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-" .. m.presses, id)
      m.presses = m.presses + 1
      if _G.SCEN_PRESS then _G.SCEN_PRESS(now - start, id) end
      m.pressed[id] = true
      lastPress = now
      local token = M.TokenForID(id)
      if token and majors[token] then
        m.majorsCast[token] = true
      end
    end
  end
  mock.inCombat, mock.restricted = false, false
  mock.Fire("PLAYER_REGEN_ENABLED")
  local keepPressed, keepKnown = {}, {}
  for id, token in pairs(keepIDs) do
    keepKnown[token] = true
    if m.pressed[id] then
      keepPressed[token] = true
    end
  end
  if scenario.group then
    mock.boss, mock.groupSize, ns.db.healSupport = nil, nil, nil
    ns.Essentials.marked = nil
    mock.book = baseBook
    M.Refresh()
  end
  local distinct, majorsCast = 0, 0
  for _ in pairs(m.pressed) do
    distinct = distinct + 1
  end
  for _ in pairs(m.majorsCast) do
    majorsCast = majorsCast + 1
  end
  return {
    errors = m.errors, firstError = m.firstError, maxStuck = m.maxStuck, maxHold = m.maxHold,
    noMainPct = 100 * m.noMain / m.ticks, no2Pct = 100 * m.no2 / m.ticks, no3Pct = 100 * m.no3 / m.ticks,
    flipsPerMin = m.flips * 60 / FIGHT, distinct = distinct, majorsCast = majorsCast, majorsKnown = m.majorsKnown,
    presses = m.presses, onCdPct = 100 * m.onCd / m.ticks, skipShown = m.skipShown,
    predPct = m.predN > 0 and 100 * m.predHit / m.predN or nil,
    msAvg = (m.msTotal or 0) / m.ticks, msPeak = m.msPeak or 0, keepPressed = keepPressed, keepKnown = keepKnown,
  }
end

local SCENARIOS = {
  { name = "st", targets = 1 },
  { name = "aoe", targets = 5 },
  { name = "lvl", targets = 1, leveling = true },
  { name = "none", targets = 1, unusable = true }, -- nothing castable (no weapon, silenced, out of resources)
  -- a boss in a 5-player party with healing support on: Hunter's Mark, Atonement upkeep, Renewing Mist
  { name = "group", targets = 1, boss = true, group = 5 },
}

local ns = Boot()
_G.SCEN_NS = ns
NS = ns
local keys = {}
for key in pairs(ns.Data.specs.midnight) do
  if not FILTER or key:find(FILTER, 1, true) then
    keys[#keys + 1] = key
  end
end
table.sort(keys)

local okBase, baseline = pcall(dofile, BASELINE)
baseline = okBase and type(baseline) == "table" and baseline or {}

local results, failures, notes = {}, {}, {}
local function Fail(msg)
  failures[#failures + 1] = msg
end

local t0 = os.clock()
for _, key in ipairs(keys) do
  -- every spec from a fresh load: nothing learned in one spec's fights may change another's
  ns = Boot()
  _G.SCEN_NS, NS = ns, ns
  -- the last spec's load is garbage now: collect it here so its cost isn't timed as this spec's
  collectgarbage("collect")
  local record = ns.Data.specs.midnight[key]
  local book = BookFor(record)
  mock.book = book
  -- a hero talent tree, as every max-level character has: the first one the spec's lists branch on
  mock.heroTree = nil
  for _, name in ipairs(record.simcOrder or {}) do
    for _, e in ipairs(record.simc[name] or {}) do
      local tree = type(e.c) == "string" and e.c:match("hero_tree%.([%w_]+)")
      if tree and not mock.heroTree then
        mock.heroTree = tree
      end
    end
  end
  ns.SpellMap.SetData(record)
  ns.SpellMap.Refresh()
  ns.State.Bind(key)
  for _, sc in ipairs(SCENARIOS) do
    math.randomseed(20261110)
    local id = key .. "/" .. sc.name
    local r = Fight(ns, key, record, book, sc)
    results[id] = r
    if _G.SCEN_RESULTS then _G.SCEN_RESULTS(id, r) end
    -- rules
    if r.errors > 0 then
      Fail(string.format("%s: %d errors (first: %s)", id, r.errors, tostring(r.firstError)))
    end
    if r.noMainPct > NO_PICK_MAX and not sc.unusable then
      Fail(string.format("%s: nothing in slot 1 for %.0f%% of the fight", id, r.noMainPct))
    end
    if r.maxStuck > STUCK_MAX then
      Fail(string.format("%s: a ready major cooldown waited %.1f s in slot 2/3 behind Blizzard's pick", id, r.maxStuck))
    end
    for token in pairs(r.skipShown) do
      Fail(string.format("%s: showed %s (never pressed by hand)", id, token))
    end
    -- the keep-ups do their job: each spec's keep-up spell is cast at least once in the group fight (Atonement:
    -- Shield or Radiance, either will do)
    if sc.group then
      local anyKnown, anyPressed = false, false
      for token in pairs(r.keepKnown) do
        anyKnown = true
        anyPressed = anyPressed or r.keepPressed[token] == true
      end
      if anyKnown and not anyPressed then
        local names = {}
        for token in pairs(r.keepKnown) do
          names[#names + 1] = token
        end
        table.sort(names)
        Fail(string.format("%s: keep-up never cast (%s)", id, table.concat(names, " / ")))
      end
    end
    if sc.unusable and r.msAvg > PERF_NONE_MAX then
      Fail(string.format("%s: %.1f ms per update with nothing castable (limit %d)", id, r.msAvg, PERF_NONE_MAX))
    end
    if r.maxHold > ns.Engine.HOLD_FOR + 1 then
      Fail(string.format("%s: a spell was held %.1f s", id, r.maxHold))
    end
    -- baseline
    local b = baseline[id]
    if b and not UPDATE then
      if r.majorsCast < (b.majorsCast or 0) then
        Fail(string.format("%s: major cooldowns used %d, was %d", id, r.majorsCast, b.majorsCast))
      end
      if r.distinct < (b.distinct or 0) - 1 then
        Fail(string.format("%s: distinct spells pressed %d, was %d", id, r.distinct, b.distinct))
      end
      if r.no3Pct > (b.no3Pct or 0) + 10 then
        Fail(string.format("%s: slot 3 empty %.0f%% of the time, was %.0f%%", id, r.no3Pct, b.no3Pct))
      end
      if r.noMainPct > (b.noMainPct or 0) + 5 then
        Fail(string.format("%s: slot 1 empty %.0f%%, was %.0f%%", id, r.noMainPct, b.noMainPct))
      end
      -- shown ready while its cooldown still runs (Holy Judgment, Void Volley): never more than before
      if b.onCdPct and r.onCdPct > b.onCdPct + 5 then
        Fail(string.format("%s: shown ready while on cooldown %.0f%% of the time, was %.0f%%", id, r.onCdPct, b.onCdPct))
      end
      -- slot 2 predicting slot 1 (the row reshuffling, Outlaw 2026-11-13): never much worse than before
      if b.predPct and r.predPct and r.predPct < b.predPct - 10 then
        Fail(string.format("%s: slot 2 right %.0f%% of the time, was %.0f%%", id, r.predPct, b.predPct))
      end
      if r.flipsPerMin > (b.flipsPerMin or 0) * 1.5 + 3 then
        Fail(string.format("%s: slot 1 flips %.1f/min, was %.1f/min", id, r.flipsPerMin, b.flipsPerMin))
      end
      if r.majorsCast > (b.majorsCast or 0) or r.distinct > (b.distinct or 0) + 1 then
        notes[#notes + 1] = id .. " improved (run with --update to record it)"
      end
    elseif not b then
      notes[#notes + 1] = id .. ": no baseline yet"
    end
  end
end

print("DMGAssist scenarios: every spec, simulated dummy fights with the game's restrictions")
print(string.format("  %-34s %6s %6s %7s %7s %8s %7s %7s %6s %6s", "spec/fight", "majors", "spells", "slot1-",
  "slot3-", "flips/m", "stuck", "held", "oncd", "pred"))
for _, key in ipairs(keys) do
  for _, sc in ipairs(SCENARIOS) do
    local id = key .. "/" .. sc.name
    local r = results[id]
    print(string.format("  %-34s %3d/%-2d %6d %6.0f%% %6.0f%% %8.1f %6.1fs %6.1fs %5.0f%% %5s", id, r.majorsCast,
      r.majorsKnown, r.distinct, r.noMainPct, r.no3Pct, r.flipsPerMin, r.maxStuck, r.maxHold, r.onCdPct,
      r.predPct and string.format("%.0f%%", r.predPct) or "-"))
  end
end
print(string.format("\n%d specs x %d fights in %.1f s", #keys, #SCENARIOS, os.clock() - t0))

if UPDATE then
  if FILTER then
    for id, b in pairs(baseline) do
      results[id] = results[id] or b
    end
  end
  local ids = {}
  for id in pairs(results) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  local out = { "-- Written by: lua5.1 tests/test_scenarios.lua --update. Each spec's numbers in the simulated fights;",
    "-- tests/test_scenarios.lua fails when one gets worse. Update only for an intended change.",
    "-- luacheck: no max line length", "return {" }
  for _, id in ipairs(ids) do
    local r = results[id]
    out[#out + 1] = string.format('  ["%s"] = { majorsCast = %d, distinct = %d, noMainPct = %.1f, no3Pct = %.1f, '
      .. "flipsPerMin = %.1f, onCdPct = %.1f%s },", id, r.majorsCast, r.distinct, r.noMainPct, r.no3Pct, r.flipsPerMin,
      r.onCdPct, r.predPct and string.format(", predPct = %.1f", r.predPct) or "")
  end
  out[#out + 1] = "}"
  local f = assert(io.open(BASELINE, "w"))
  f:write(table.concat(out, "\n") .. "\n")
  f:close()
  print("baseline written: " .. BASELINE)
end

for _, n in ipairs(notes) do
  if not n:find("no baseline", 1, true) or UPDATE then -- luacheck: ignore 542
  end
end
local missing = 0
for _, n in ipairs(notes) do
  if n:find("no baseline", 1, true) then
    missing = missing + 1
  else
    print("  note: " .. n)
  end
end
if missing > 0 and not UPDATE then
  print(string.format("  note: %d fights have no baseline yet (run with --update)", missing))
end

if #failures > 0 then
  print("\nFAILED:")
  for _, f in ipairs(failures) do
    print("  " .. f)
  end
  if not _G.SCEN_NOEXIT then
    os.exit(1)
  end
end
print("all rules hold")
