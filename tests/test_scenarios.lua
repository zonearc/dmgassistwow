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

local lastUsableSig -- (SPELL_UPDATE_USABLE: what you can cast, as the game last said it)
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

-- Grading (tools/grade.py): SCEN_GRADE names a Lua file { [spec] = { talents = { { name =, spellID =, rank = } } } }
-- built from data/reference/<spec>.json. Each spec then fights at 1 and 5 targets with the reference's talents and a
-- real resource model (costs, gains, regeneration, passive income; hidden in combat as in Midnight, with the game's
-- "can I afford it?" answer following the true value), and its presses per spell are printed for the grader.
local GRADE_FILE = os.getenv("SCEN_GRADE")
local GRADE = GRADE_FILE and dofile(GRADE_FILE) or nil
local FIGHT = tonumber(_G.SCEN_FIGHT) or tonumber(os.getenv("SCEN_FIGHT")) or 40 -- seconds per fight
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
-- Buttons an aura swaps for a while (data/overrides.lua, tools/override-map.py): Metamorphosis turns Blade Dance into
-- Death Sweep for 20 s. The swapped-in spell isn't a button of its own: offline it was, and Havoc was offered Death
-- Sweep outside Metamorphosis, which the game never does (owner, 2026-11-15: "fix it in sims so we are forced to fix
-- it before it goes in game").
local function SwapsFor(record)
  local list, overrideIDs = {}, {}
  local info = record.spellInfo or {}
  local ns = _G.SCEN_NS
  for _, s in ipairs(ns and ns.Data and ns.Data.overrides or {}) do
    if info[s.override] ~= nil then
      list[#list + 1] = s
      overrideIDs[s.override] = true
    end
  end
  return list, overrideIDs
end

local function BookFor(record)
  local book, seen = {}, {}
  local _, swapped = SwapsFor(record)
  for token, e in pairs(record.spells or {}) do
    -- the button among the IDs a name has: the one with a cooldown, cost, GCD or cast time (the game's spellbook
    -- holds that one; Windwalker's first "slicing_winds" ID is a 0.5 s effect with no cooldown, and the offline
    -- player pressed it every GCD)
    -- (a GCD or cast time first: Havoc's "metamorphosis" list starts with Vengeance's 187827, no GCD; Havoc's
    -- button is 191427 - offline Havoc never cast Metamorphosis)
    local id
    for _, cand in ipairs(e.a or {}) do
      local ci = record.spellInfo[cand]
      if ci and not ci.pas and not swapped[cand] and (ci.gcd or ci.ct) and (ci.n == nil or ci.n == token) then
        id = cand
        break
      end
    end
    for _, cand in ipairs(id and {} or e.a or {}) do
      local ci = record.spellInfo[cand]
      if ci and not ci.pas and not swapped[cand] and (ci.cd or ci.cost or ci.chcd) then
        id = cand
        break
      end
    end
    -- (no other fallback: a name with no entry that has a GCD, cast time, cooldown or cost isn't a button - the game's
    -- spellbook doesn't hold it. Champion's Leap (an effect of Champion's Spear) and Bone Shield (a buff) were
    -- "buttons" offline: Protection Warrior pressed Champion's Leap 116 times in two minutes, 2026-11-16)
    local info = id and record.spellInfo[id]
    if id and not seen[id] and info and not info.pas and not RACIALS[token] and not swapped[id] then
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

-- SCEN_LOG=path: the graded fights' log, as a decoded Watchdog report (the addon's own lines - press, pick,
-- decision_trace, ahead_trace, floor_raised... - plus our casts), so tools/why-report.py, prediction-report.py and
-- resource-replay.py read a simulated fight the way they read the owner's (offline: no one has to play it).
local LOG_FILE = os.getenv("SCEN_LOG")
local LOG = LOG_FILE and { sessions = {} } or nil
local logSession, logStart
if LOG then
  _G.DMGAssistWatchdog = { Log = function(kind, data)
    if logSession then
      local t = math.floor((mock.now - logStart) * 100 + 0.5) / 100
      logSession.events[#logSession.events + 1] = { t, "D", tostring(kind), tostring(data) }
    end
  end, Record = function(line) -- (Core/Record.lua: the input recording, as the game's Watchdog keeps it)
    if logSession then
      logSession.rec = logSession.rec or {}
      logSession.rec[#logSession.rec + 1] = line
      return true
    end
    return false
  end }
end
local function JsonStr(s)
  return '"' .. tostring(s):gsub('[%c"\\]', function(c)
    return string.format("\\u%04x", c:byte())
  end) .. '"'
end
local function WriteLog()
  local f = io.open(LOG_FILE, "w")
  f:write('{"sessions": [')
  for i, s in ipairs(LOG.sessions) do
    f:write(i > 1 and "," or "", '{"id": ', s.id, ', "name": ', JsonStr(s.name), ', "events": [')
    for j, e in ipairs(s.events) do
      local parts = {}
      for k, v in ipairs(e) do
        parts[k] = type(v) == "number" and tostring(v) or JsonStr(v)
      end
      f:write(j > 1 and "," or "", "[", table.concat(parts, ","), "]")
    end
    f:write("]")
    if s.rec then
      local lines = {}
      for j, l in ipairs(s.rec) do
        lines[j] = JsonStr(l)
      end
      f:write(', "rec": [', table.concat(lines, ","), "]")
    end
    f:write("}")
  end
  f:write("]}")
  f:close()
end
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

-- The resource world for grading: true values the addon can't read (except the counted ones), spent and gained by
-- the presses, refilled by regeneration and the spec's measured passive income.
local DISCRETE = { [4] = true, [7] = true, [9] = true, [12] = true, [16] = true, [19] = true, [5] = true }
local REGEN = { [3] = 10, [2] = 5, [5] = 0.6, [19] = 0.2 } -- per second (runes: 6 recharging ~10 s each)
local START = { [3] = "max", [2] = "max", [5] = "max", [19] = "max", [7] = 3, [0] = "max" }
-- Spells the game only offers while a same-named proc buff is up ("you may cast Ruination"): the world has no procs,
-- so they stay unusable (in the game, IsSpellUsable / the button swap decide).
-- Proc-only spells: the ones a button turns into only while an aura is up (Data/Overrides.lua, the game data) -
-- handled by the button swaps in Fight. (A guess from "has a self aura of its own name" blocked Eviscerate, Kill
-- Command, Colossus Smash, Rake, Stormstrike, Metamorphosis... in every offline fight, 2026-11-15.)
local function ProcGated()
  return {}
end
-- Random procs (tests/procs.lua, tools/build-procs.py: Warcraft Logs' rates x the game data): rolled each tick at
-- the rate top players get them; while up, the spells they act on glow (the addon's in-combat signal), cost nothing
-- or cast instantly, or the button swaps (Rushing Wind Kick); a cast of one of them uses the proc up. SCEN_NOPROCS=1
-- turns them off (to compare). Owner, 2026-11-15: "determine procs exist, execute at random".
local PROCS = (function()
  local ok, m = pcall(dofile, "tests/procs.lua")
  return (ok and type(m) == "table" and not os.getenv("SCEN_NOPROCS")) and m or {}
end)()
-- SCEN_SEED: which random run (procs, the player's timing); one seed is one sample of the luck, not the truth -
-- tools/sim.py --seeds N runs several and reports the spread (owner, 2026-11-15: "ensure the randomness is there ...
-- so we don't create models against flat behaviours").
local SEED = tonumber(os.getenv("SCEN_SEED") or "") or 20261110
-- SCEN_HUMAN=1: the player presses a moment after the GCD ends, as the owner does - delays after the GCD measured
-- from his Balance fights (1.6.0.291-296 reports, instant after instant, 272 pairs): median 0.25 s, p90 0.48 s,
-- 1% over a second. Without it the offline player presses the instant the GCD ends, every time.
local HUMAN = os.getenv("SCEN_HUMAN") == "1"
local WRONG = tonumber(os.getenv("SCEN_WRONG") or "") or 0.10 -- share of presses that aren't slot 1 (SCEN_HUMAN)
local HUMAN_DELAYS = { 0.06, 0.12, 0.17, 0.2, 0.22, 0.24, 0.25, 0.27, 0.29, 0.31, 0.33, 0.36, 0.4, 0.48, 0.6, 1.2 }
local MAX_RESOURCE = (function()
  local ok, m = pcall(dofile, "tests/max_resource.lua")
  return ok and type(m) == "table" and m or {}
end)()
local function World(record, targets, key)
  local w = { cur = {}, max = {}, passive = {}, gated = ProcGated(record), auras = {}, knownAura = {} }
  -- buffs the world can apply: the data's own (a cast's self aura), the logs' cast -> buff links, the procs
  for _, info in pairs(record.spellInfo or {}) do
    for _, ap in ipairs(type(info.ap) == "table" and info.ap or {}) do
      local ai = record.spellInfo[ap[1]]
      if ap[2] == "self" and ai and ai.n then
        w.knownAura[ai.n] = true
      end
    end
  end
  local ca = NS and NS.Data.castAuras and NS.Data.castAuras[key] or {}
  for _, row in pairs(ca) do
    w.knownAura[row[1]] = true
  end
  local pg = NS and NS.Data.procGlows and NS.Data.procGlows[key] or {}
  for _, row in pairs(pg) do
    w.knownAura[row[1]] = true
  end
  w.castAuras, w.procTokens = ca, {}
  for aid, row in pairs(pg) do
    w.procTokens[aid] = row[1]
  end
  local maxes = { [0] = 100000, [1] = 100, [2] = 100, [3] = 100, [4] = 5, [5] = 6, [6] = 100, [7] = 5, [8] = 100,
    [9] = 5, [11] = 100, [12] = 5, [13] = 100, [16] = 4, [17] = 120, [18] = 100, [19] = 5 }
  -- talents that raise a maximum (tests/max_resource.lua, from the game data: Deeper Stratagem and Secret
  -- Stratagem make Subtlety's 7 combo points - capped at 5 offline, the player and the list disagreed on spending)
  local raise = {}
  for _, tal in ipairs(mock.talents or {}) do
    for pt, n in pairs(MAX_RESOURCE[tal.spellID] or {}) do
      raise[pt] = (raise[pt] or 0) + n * (tal.rank or 1)
    end
  end
  for pt, n in pairs(raise) do
    maxes[pt] = (maxes[pt] or 0) + n
  end
  for _, info in pairs(record.spellInfo or {}) do
    for pt, n in pairs(type(info.cmax) == "table" and info.cmax or {}) do
      maxes[pt] = math.max(maxes[pt] or 0, n) -- finishers that spend up to 7 combo points: 7 is the cap
    end
  end
  for pt, mx in pairs(maxes) do
    w.max[pt] = mx
    local s = START[pt]
    w.cur[pt] = s == "max" and mx or (s or 0)
  end
  for pt, v in pairs(type(record.passiveGain) == "table" and record.passiveGain or {}) do
    if not DISCRETE[pt] then
      w.passive[pt] = v
    end
  end
  -- resources our data gives no income for at all (Soul Shards: Incinerate's fragments aren't in it): the rate the
  -- real players' casts show (tools/wcl-castdelta.py), so the world isn't starved where the game isn't
  local CASTDELTA = { warlock_destruction = { [7] = 0.45 } }
  for pt, v in pairs(key and CASTDELTA[key] or {}) do
    if not w.passive[pt] then
      w.passive[pt] = v
    end
  end
  -- income with nothing cast, by targets, where Warcraft Logs' dummy fights measured it (beyond: grows by the last
  -- step per target - the truth the addon has to find out, not what it is told)
  local byT = key and NS and NS.Data.resourceTargets and NS.Data.resourceTargets[key]
  for pt, t in pairs(byT or {}) do
    local ks = {}
    for k in pairs(t) do
      ks[#ks + 1] = k
    end
    table.sort(ks)
    local top, before = ks[#ks], ks[#ks - 1]
    local v = t[math.min(targets or 1, top)] or t[ks[1]]
    if os.getenv("SCEN_FLAT") == nil and (targets or 1) > top and before then
      v = t[top] + (t[top] - t[before]) / (top - before) * ((targets or 1) - top)
    end
    w.passive[pt] = v
  end
  return w
end
local function WorldPublish(w)
  local changed = false
  for pt, v in pairs(w.cur) do
    changed = changed or mock.power[pt] ~= math.floor(v)
    mock.power[pt], mock.powerMax[pt] = math.floor(v), w.max[pt]
    mock.powerReadable[pt] = DISCRETE[pt] or pt == 0
  end
  if changed then -- the game says when your power changes (runes, essence and shards refilling too)
    mock.Fire("UNIT_POWER_FREQUENT", "player")
  end
end
local function WorldTick(w, dt)
  for pt, rate in pairs(REGEN) do
    if w.cur[pt] then
      w.cur[pt] = math.min(w.max[pt], w.cur[pt] + rate * dt)
    end
  end
  for pt, rate in pairs(w.passive) do
    if w.cur[pt] then
      w.cur[pt] = math.min(w.max[pt], w.cur[pt] + rate * dt)
    end
  end
end
-- the game won't cast these in combat (IsSpellUsable says no)
local OUT_OF_COMBAT = { stealth = true, prowl = true, shadowmeld = true }
local function WorldAffordable(w, info, M)
  if info.n and (OUT_OF_COMBAT[info.n] or w.gated[info.n]) then
    return false
  end
  if w.freeNow and w.freeNow[info] then
    return true -- a proc made it free (Clearcasting)
  end
  for pt, amount in pairs(M.Cost(info) or {}) do
    if (w.cur[pt] or 0) < amount then
      return false
    end
  end
  return true
end
local function WorldAura(w, token, d, n, maxStacks, now)
  local a = w.auras[token]
  local stacks = (a and a.untilT > now and a.stacks or 0) + (n or 1)
  w.auras[token] = { untilT = now + (d or 30), stacks = math.min(maxStacks or 99, stacks) }
end
local function WorldCast(w, info, M)
  for pt, amount in pairs((w.freeNow and w.freeNow[info]) and {} or M.Cost(info) or {}) do
    local cmax = info.cmax and info.cmax[pt]
    local spend = cmax and math.max(amount, math.min(w.cur[pt] or 0, cmax)) or amount
    w.cur[pt] = math.max(0, (w.cur[pt] or 0) - spend)
  end
  for pt, amount in pairs(type(info.gain) == "table" and info.gain or {}) do
    if w.cur[pt] then
      w.cur[pt] = math.min(w.max[pt], w.cur[pt] + amount)
    end
  end
end

-- Grading: Blizzard's assistant as the game runs it, its own list (assisted_combat) evaluated against the true
-- state: resources from the world, the enemy count, everything else as our engine sees it (a line it can't decide
-- is passed over). The plain stand-in below names the first ready spell, which at 6 combo points was Sinister Strike
-- where the real one says Between the Eyes.
local function AssistantPick(ns, record, world, targets, skip)
  local S, M = ns.State, ns.SpellMap
  local function resolve(name)
    if name == "combo_points" or name == "effective_combo_points" then
      return math.floor(world.cur[4] or 0)
    end
    local head, field = name:match("^([%w_]+)%.?([%w_]*)$")
    local pt = head and S.PowerTypeOf(head)
    if pt and world.cur[pt] then
      if field == "deficit" then
        return world.max[pt] - math.floor(world.cur[pt])
      elseif field == "" then
        return math.floor(world.cur[pt])
      end
    end
    if name == "active_enemies" or name:match("^spell_targets") then
      return targets
    end
    -- buffs the offline world keeps (casts and procs apply them): the real assistant sees them
    local tok, f2 = name:match("^buff%.([%w_]+)%.([%w_]+)$")
    if tok and world.knownAura and world.knownAura[tok] then
      local a = world.auras[tok]
      local up = a and a.untilT > mock.now
      if f2 == "up" or f2 == "react" then
        return up and 1 or 0
      elseif f2 == "down" then
        return up and 0 or 1
      elseif f2 == "remains" then
        return up and (a.untilT - mock.now) or 0
      elseif f2 == "stack" then
        return up and a.stacks or 0
      end
    end
    return S.Resolve(name, {})
  end
  for _, line in ipairs(ns.Clues.BlizzardOrder(record)) do
    local id = M.SpellID(line.a)
    local info = id and M.Info(id)
    if id and info and not skip(line.a, id) and not mock.cooldowns[id] and WorldAffordable(world, info, M)
      and ns.Expr.Test(line.c, resolve) == true then
      return id
    end
  end
  return nil
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
  local world = GRADE and World(record, scenario.targets, key) or nil
  if world then
    WorldPublish(world)
    mock.inRange = setmetatable({}, { __index = function() return true end }) -- standing at the target
  end
  mock.nameplates = scenario.targets
  mock.restricted, mock.inCombat = false, false
  ns.Specs.current = { key = key, status = "ready", data = record, branch = "midnight", client = "Midnight",
    leveling = scenario.leveling or nil }
  ns.db.levelingMode = scenario.leveling and "blizzard" or "simc"
  ns.db.spendMargin = os.getenv("SCEN_MARGIN") == "1" or nil -- (the predictable-spending margin, measured on and off)
  if os.getenv("SCEN_MARGIN") == "1" and not G.marginWrapped then
    G.marginWrapped, G.marginHolds = true, 0
    local hold = G.HoldForMargin
    G.HoldForMargin = function(...)
      local r = hold(...)
      if r then
        G.marginHolds = G.marginHolds + 1
      end
      return r
    end
  end
  G.ResetSteady()
  mock.Advance(1)
  if LOG then
    logSession = { id = #LOG.sessions + 1, name = key .. " " .. scenario.targets .. " targets", events = {} }
    LOG.sessions[#LOG.sessions + 1] = logSession
    logStart = mock.now
  end
  mock.inCombat, mock.restricted = true, true
  if LOG and os.getenv("SCEN_RECORD") then
    ns.Record.Set(true) -- (the input recording too: tools/replay.py replays the fight)
  end
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
  local pressAt -- (SCEN_HUMAN) when the player will press, after this GCD
  local lastPressedID
  -- button swaps: aura index -> when it ends; the swapped-in spell is usable only while its aura is up
  local swaps, swapUntil, inBook = SwapsFor(record), {}, {}
  for _, b in ipairs(book) do
    inBook[b.spellID] = true
  end
  if world then
    for _, s in ipairs(swaps) do
      local si = record.spellInfo[s.override]
      if si and si.n then
        world.gated[si.n] = nil -- (the swap decides now)
      end
    end
  end
  local function PublishSwaps(now)
    local before = mock.overrides or {}
    mock.overrides = {}
    for i, s in ipairs(swaps) do
      local up = swapUntil[i] and swapUntil[i] > now
      for _, b in ipairs(s.base) do
        if up and inBook[b] then
          mock.overrides[b] = s.override
        end
      end
      local si = record.spellInfo[s.override]
      if not up then
        mock.usable[s.override] = { false, false }
      elseif world and si then
        mock.usable[s.override] = WorldAffordable(world, si, M) and { true, false } or { false, true }
      else
        mock.usable[s.override] = nil
      end
    end
    -- the game says when a button turns into another spell
    local changed = false
    for b, o in pairs(mock.overrides) do
      changed = changed or before[b] ~= o
    end
    for b in pairs(before) do
      changed = changed or mock.overrides[b] == nil
    end
    if changed then
      mock.Fire("SPELL_UPDATE_ICON")
    end
  end
  -- procs: index -> { up = until, stacks }
  local procs, procState = world and PROCS[key] or {}, {}
  local instantNow = {}
  m.procs = 0
  local function ProcIDs(p)
    local all = {}
    local seen = {}
    for _, list in ipairs({ p.free, p.instant, p.swap, p.glow or {} }) do
      for _, id in ipairs(list) do
        if not seen[id] then
          seen[id] = true
          all[#all + 1] = id
        end
      end
    end
    return all
  end
  local function RefreshProcs()
    world.freeNow, instantNow = {}, {}
    for i, p in ipairs(procs) do
      local st = procState[i]
      if st and st.stacks > 0 then
        for _, id in ipairs(p.free) do
          local info = record.spellInfo[id]
          if info then
            world.freeNow[info] = true
          end
        end
        for _, id in ipairs(p.instant) do
          instantNow[id] = true
        end
      end
    end
  end
  local function Glow(p, on)
    for _, id in ipairs(ProcIDs(p)) do
      mock.Fire(on and "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" or "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE", id)
    end
  end
  local function ProcSwaps(p, untilT)
    for _, ov in ipairs(p.swap) do
      for i, s in ipairs(swaps) do
        if s.override == ov and s.aura == p.aura then
          swapUntil[i] = untilT
        end
      end
    end
  end
  local function ProcDown(i)
    local p, st = procs[i], procState[i]
    st.stacks, st.up = 0, nil
    local ptk = world.procTokens[p.aura]
    if ptk then
      world.auras[ptk] = nil
    end
    ProcSwaps(p, nil)
    Glow(p, false)
    RefreshProcs()
  end
  local function ProcUp(i, now)
    local p = procs[i]
    local st = procState[i] or { stacks = 0 }
    procState[i] = st
    local was = st.stacks
    st.stacks, st.up = math.min(p.stacks or 1, st.stacks + 1), now + p.d
    m.procs = m.procs + 1
    ProcSwaps(p, st.up)
    local ptk = world.procTokens[p.aura]
    if ptk then
      world.auras[ptk] = { untilT = st.up, stacks = st.stacks }
    end
    -- a reset (Gore -> Mangle): the cooldown is over, every charge back
    for _, rid in ipairs(p.resets or {}) do
      mock.cooldowns[rid] = nil
      if charges[rid] then
        charges[rid].n, charges[rid].next = charges[rid].max, nil
      end
      mock.Fire("SPELL_UPDATE_COOLDOWN")
    end
    if was == 0 then
      Glow(p, true)
    end
    RefreshProcs()
  end
  local function ProcTick(now)
    for i, p in ipairs(procs) do
      local st = procState[i] or { stacks = 0 }
      procState[i] = st
      if st.up and now >= st.up then
        ProcDown(i)
      end
      if math.random() < p.rate * TICK then
        ProcUp(i, now)
      end
    end
  end
  -- what a cast brings (tools/wcl-triggers.py: Shred -> Clearcasting 27%, Rip -> Predatory Swiftness 92%)
  local function ProcCast(id, now)
    for i, p in ipairs(procs) do
      local c = p.by and p.by[id]
      if c and math.random() < c then
        ProcUp(i, now)
      end
    end
  end
  local function ProcUse(id)
    for i, p in ipairs(procs) do
      local st = procState[i]
      if st and st.stacks > 0 then
        for _, pid in ipairs(ProcIDs(p)) do
          if pid == id then
            st.stacks = st.stacks - 1
            if st.stacks <= 0 then
              ProcDown(i)
            end
            break
          end
        end
      end
    end
  end
  m.predN, m.predHit = 0, 0
  m.cast = {}
  while mock.now - start < FIGHT do
    mock.Advance(TICK)
    local now = mock.now
    if world then
      WorldTick(world, TICK)
      for _, b in ipairs(book) do
        local bi = M.Info(b.spellID)
        if bi and bi.n and (OUT_OF_COMBAT[bi.n] or world.gated[bi.n]) then
          mock.usable[b.spellID] = { false, false } -- not usable (not "short of resource")
        else
          mock.usable[b.spellID] = (not bi or WorldAffordable(world, bi, M)) and { true, false } or { false, true }
        end
      end
      ProcTick(now)
      WorldPublish(world)
    end
    PublishSwaps(now)
    local recharged = false
    for id, c in pairs(charges) do
      while c.next and now >= c.next do
        c.n = c.n + 1
        c.next = c.n < c.max and (c.next + c.len) or nil
        recharged = true
      end
    end
    if recharged then
      mock.Fire("SPELL_UPDATE_CHARGES")
    end
    local ended = false
    for id, c in pairs(mock.cooldowns) do
      if c.start + c.duration <= now then
        mock.cooldowns[id] = nil
        ended = ended or id ~= 61304 -- (the game says when a cooldown ends; the GCD ends silently - fight 488)
      end
    end
    if ended then
      mock.Fire("SPELL_UPDATE_COOLDOWN")
    end
    -- Blizzard's assistant: the first rotation spell that is ready or about to be (never a major cooldown). The
    -- real one names a spell up to a second or two before it is back (Holy Shock 1.6 s, Judgment 2.8 s early in
    -- a Holy Paladin log, 2026-11-10); one that named only ready spells taught our clock wrong numbers.
    mock.acSpell = nil
    if world then
      mock.acSpell = AssistantPick(ns, record, world, scenario.targets, function(token, id)
        return (majors[token] or ns.Essentials.FORMS[id] or keepIDs[id] or ns.Buffs.IsBuffSpell(id) or G.SKIP[token])
          and true or false
      end)
    end
    for _, b in ipairs(mock.acSpell and {} or book) do
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
    -- the game says when what you can cast changes (SPELL_UPDATE_USABLE); the world above changed it silently
    local usableSig = {}
    for id, u in pairs(mock.usable) do
      usableSig[#usableSig + 1] = id .. (u[1] and "1" or "0") .. (u[2] and "1" or "0")
    end
    table.sort(usableSig)
    usableSig = table.concat(usableSig, ",")
    if usableSig ~= lastUsableSig then
      lastUsableSig = usableSig
      mock.Fire("SPELL_UPDATE_USABLE")
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
    local dbgPt = tonumber(os.getenv("SCEN_POWER") or "")
    if dbgPt and world and math.floor((now - start) * 5 + 0.5) % 5 == 0 then
      local lo, hi = ns.Clues.ResourceBounds(dbgPt)
      local f = ns.Clues.floor[dbgPt]
      io.stderr:write(string.format("POWER t=%.1f world=%.1f bounds=%s..%s floor=%s main=%s\n", now - start,
        world.cur[dbgPt] or -1, tostring(lo and math.floor(lo)), tostring(hi and math.floor(hi)),
        tostring(f and math.floor(f.lo)), tostring(main and main.token)))
    end
    -- a slot 1 the game won't cast at all (not a resource wait: a proc-only spell, a movement ability) for 2 s:
    -- the player presses slot 2 instead (Windwalker's Slicing Winds held slot 1 for a whole offline fight, no press)
    if world and main and main.id then
      local bi = M.Info(main.id)
      local u = mock.usable[main.id]
      local blocked = (bi and bi.n and (OUT_OF_COMBAT[bi.n] or world.gated[bi.n])) or (u and u[1] == false and u[2] == false)
      if blocked then
        m.blockedSince = m.blockedSince or now
        if now - m.blockedSince >= 2 then
          -- slot 2, slot 3, else the assistant's pick: the first the game would cast
          for _, cand in ipairs({ q[2] or false, q[3] or false, mock.acSpell and { id = mock.acSpell } or false }) do
            local ci = cand and cand.id and M.Info(cand.id)
            local cu = cand and mock.usable[cand.id]
            if ci and not (ci.n and (OUT_OF_COMBAT[ci.n] or world.gated[ci.n])) and not mock.cooldowns[cand.id]
              and not (cu and cu[1] == false and cu[2] == false)
              and WorldAffordable(world, ci, M) then
              main = cand
              break
            end
          end
        end
      else
        m.blockedSince = nil
      end
    end
    -- the player: presses slot 1 when the GCD allows and it isn't shown as "not yet"
    if HUMAN and now >= gcdEnd and not pressAt then
      pressAt = gcdEnd + HUMAN_DELAYS[math.random(#HUMAN_DELAYS)]
    end
    if r and main and main.id and now >= gcdEnd and (not HUMAN or now >= (pressAt or 0))
      and not (main.readyAt and main.readyAt > now)
      and not mock.cooldowns[main.id]
      and not (mock.usable[main.id] and mock.usable[main.id][1] == false and mock.usable[main.id][2] == false)
      and not (world and M.Info(main.id) and not WorldAffordable(world, M.Info(main.id), M)) then
      local id = main.id
      -- (SCEN_HUMAN) now and then the player presses something else - in the owner's fights the other press was
      -- slot 2 40% of the time, the spell just pressed 28%, something else 32% (1.6.0.291-296 reports)
      local followed = true
      if HUMAN and math.random() < WRONG then
        local roll = math.random()
        local alt
        if roll < 0.40 then
          alt = q[2] and q[2].id
        elseif roll < 0.68 then
          alt = lastPressedID
        else
          local b = book[math.random(#book)]
          alt = b and b.spellID
        end
        local ai = alt and M.Info(alt)
        local au = alt and mock.usable[alt]
        if ai and alt ~= id and not mock.cooldowns[alt] and not (au and au[1] == false)
          and not (world and not WorldAffordable(world, ai, M)) then
          id, followed = alt, false
        end
      end
      -- prediction: was slot 2 at the last press what you pressed next? (as the in-game summary measures it)
      if predict then
        m.predN = m.predN + 1
        if id == predict then
          m.predHit = m.predHit + 1
        end
      end
      -- (slot 2 counts only after a press that followed slot 1, as in game)
      predict = followed and q[2] and q[2].id or nil
      pressAt = nil
      lastPressedID = id
      local info = M.Info(id) or {}
      local gcd = tonumber(info.gcd) or 1.5
      local ct = instantNow[id] and 0 or tonumber(info.ct) or 0
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
      for i, s in ipairs(swaps) do
        -- a swapped-in spell's cooldown is its button's (Death Sweep and Blade Dance share one)
        if s.override == id and swapUntil[i] and swapUntil[i] > now and mock.cooldowns[id] then
          for _, b in ipairs(s.base) do
            local bi = record.spellInfo[b]
            -- (not onto a button with charges: Void Blast over Mind Blast leaves Mind Blast's charges alone)
            if inBook[b] and not (bi and bi.chcd) then
              mock.cooldowns[b] = mock.cooldowns[id]
            end
          end
        end
        for _, tid in ipairs(s.triggers) do
          if tid == id then
            swapUntil[i] = now + s.duration
          end
        end
      end
      PublishSwaps(now)
      if world then
        WorldCast(world, info, M)
        -- the buffs this cast applies, in the world (the data's self auras; the logs' links with their stacks)
        for _, ap in ipairs(type(info.ap) == "table" and info.ap or {}) do
          local ai = record.spellInfo[ap[1]]
          if ap[2] == "self" and ai and ai.n and ai.d and ai.d > 1.5 then
            WorldAura(world, ai.n, ai.d, 1, ai.st, now)
          end
        end
        local link = world.castAuras[id]
        if link then
          local ai = record.spellInfo[link[2]] or {}
          WorldAura(world, link[1], ai.d or 30, link[4] or 1, ai.st, now)
        end
        ProcUse(id)
        ProcCast(id, now)
        WorldPublish(world)
        local tk = M.TokenForID(id) or tostring(id)
        m.cast[tk] = (m.cast[tk] or 0) + 1
      end
      if logSession then
        logSession.events[#logSession.events + 1] = { math.floor((mock.now - logStart) * 100 + 0.5) / 100, "C", id }
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
  mock.overrides = nil
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
    cast = m.cast, procs = m.procs,
  }
end

local SCENARIOS_ALL = {
  { name = "st", targets = 1 },
  { name = "aoe", targets = 5 },
  { name = "lvl", targets = 1, leveling = true },
  { name = "none", targets = 1, unusable = true }, -- nothing castable (no weapon, silenced, out of resources)
  -- a boss in a 5-player party with healing support on: Hunter's Mark, Atonement upkeep, Renewing Mist
  { name = "group", targets = 1, boss = true, group = 5 },
}
-- (SCEN_TARGETS="1,5,8": other target counts for the graded fights)
local function GradeScenarios()
  local out = {}
  for n in (os.getenv("SCEN_TARGETS") or "1,5"):gmatch("%d+") do
    out[#out + 1] = { name = "t" .. n, targets = tonumber(n) }
  end
  return out
end
local SCENARIOS = GRADE and GradeScenarios() or SCENARIOS_ALL

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
if GRADE then
  -- grading: each spec with a reference, its talents, 1 and 5 targets; presses per spell, then out
  for _, key in ipairs(keys) do
    local ref = GRADE[key]
    if ref then
      ns = Boot()
      _G.SCEN_NS, NS = ns, ns
      if os.getenv("SCEN_NOFIT") then
        ns.Calibrate.FIT_MIN = math.huge -- (the in-play fit off: to measure what it adds)
      end
      collectgarbage("collect")
      local record = ns.Data.specs.midnight[key]
      local book = BookFor(record)
      mock.book = book
      mock.talents, mock.playerSpells = {}, {}
      for _, t in ipairs(ref.talents or {}) do
        mock.talents[#mock.talents + 1] = { name = t.name, spellID = t.spellID, rank = t.rank or 1 }
        mock.playerSpells[t.spellID] = true
      end
      mock.heroTree = ref.heroTree
      ns.SpellMap.SetData(record)
      ns.SpellMap.Refresh()
      ns.State.Bind(key)
      -- the game says which spec you play (it was always "Feral" here: a spec re-check switched to Feral's data)
      for id, k in pairs(ns.Specs.KEYS) do
        if k == key then
          local cls = key:match("^(%a+)_"):upper()
          mock.class, mock.specs, mock.specIndex = { cls, cls, 0 }, { [1] = id }, 1
        end
      end
      if not os.getenv("SCEN_NOSC") then
        mock.Fire("SPELLS_CHANGED") -- (the game says when your talents change what you know)
      end
      for _, sc in ipairs(SCENARIOS) do
        math.randomseed(SEED)
        local r = Fight(ns, key, record, book, sc)
        local parts = {}
        for tk, n in pairs(r.cast or {}) do
          parts[#parts + 1] = tk .. "=" .. n
        end
        table.sort(parts)
        print(string.format("GRADE %s %d %d errors=%d procs=%d %s", key, sc.targets, FIGHT, r.errors, r.procs or 0,
          table.concat(parts, " ")))
        -- slot 2 right: pressing slot 1, was slot 2 the next press? (the in-game measure, offline)
        print(string.format("PRED %s %d %.1f", key, sc.targets, r.predPct or 0))
        if os.getenv("SCEN_SIGNALS") then
          print("SIGNALS " .. key .. " " .. sc.targets .. " " .. ns.Signals.Summary())
          for i, m in ipairs(ns.Signals.misses) do
            if i <= tonumber(os.getenv("SCEN_SIGNALS")) then
              print(string.format("  MISS %s %s held=%s game=%s age=%s last=%s (%s s ago)", m.piece, m.q, m.held,
                m.game, m.age, m.last, m.lastAgo))
            end
          end
        end
        local E2 = ns.Engine
        if E2.marginWrapped then print(string.format("MARGIN holds=%d margin8=%.1f", E2.marginHolds, ns.Calibrate.Margin(8))) end
      end
    end
  end
  if LOG then
    logSession = nil
    WriteLog()
  end
  os.exit(0)
end
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
