-- DMGAssist: the prediction learner (shadow mode).
--
-- Slot 2 is a forecast: "after the spell you're about to press, this one". SimC's priority list decides what to
-- press now; it doesn't know which way a proc will fall, and on proc-heavy specs its forecast was right about half
-- the time (Outlaw, 2026-11-13). This learner watches your own damage rotation and counts, for each situation,
-- which spell you pressed next. A situation is the spell just pressed, the one before it, and what the game lets
-- us read in combat: the spec's secondary resource (combo points, holy power, chi...), which buttons are lit (a
-- proc glow), and single target or AoE.
--
-- SHADOW MODE: it predicts at every press but shows nothing. Each fight's log has its accuracy next to slot 2's on
-- the same presses (learner_summary), and one "press" line per press (what was pressed, the situation, what slot 2
-- said, what the learner said) so the sequences can be studied outside the game. It goes live only once it clearly
-- beats slot 2 (owner, 2026-11-13: "I dont want you to build anything new unless you are fairly positive it will
-- help"). Never slot 1: the decision stays SimC's, so the learner can't cost damage.
--
-- Only the damage rotation: spells in the spec's SimC lists, never defensives, trinkets, potions or interrupts.
-- Kept across sessions per spec and talent loadout (DMGAssistDB.learner); recent fights weigh more (each fight
-- scales the old counts by L.DECAY), so a hotfix or a changed habit wins over time without starting over.

local _, ns = ...
local L = {}
ns.Learner = L
local U = ns.U

L.MIN_N = 3          -- a situation needs this many samples before the learner guesses from it
-- Live in slot 2 once it has clearly beaten SimC's forecast on the same presses (per spec and loadout), and back to
-- shadow when its lead shrinks: L.LIVE_N presses (decayed like the counts), a lead of L.LIVE_LEAD to go live,
-- under L.DROP_LEAD to step back.
L.LIVE_N = 100
-- Before that, situation by situation: one the learner has seen at least LOCAL_N times, going the same way at least
-- LOCAL_CONF of the time, takes slot 2 at once (its confident guesses were right 18/22 and 19/22 on Outlaw while
-- the whole spec still trailed the 10-point bar: owner, 2026-11-14, "why isn't it adapting in real time?").
L.LOCAL_N = 8
L.LOCAL_CONF = 0.85
L.LOCAL_VS_N = 20   -- presses compared with SimC's forecast before a situation can take slot 2 on its own
L.LOCAL_LEAD = 0.15 -- its confidence must beat SimC's accuracy so far by this much
L.LIVE_LEAD = 0.10
L.DROP_LEAD = 0.03
L.CONFIDENT = 0.9    -- "confident" guesses: the share it would show live first
L.DECAY = 0.97       -- each fight end: old counts x this (recent fights weigh more)
L.FLOOR = 0.05       -- counts below this are forgotten
L.MAX_SITUATIONS = 3000
L.PRESS_SAME = 0.6   -- the same spell again within this is one press (Fan the Hammer's volley)
-- the secondary resource, in this order: combo points, holy power, chi, soul shards, arcane charges, essence
L.SECONDARY = { 4, 9, 12, 7, 16, 19 }
L.SITUATIONAL = { interrupt = true, defensive = true, gapcloser = true, potion = true, trinket = true, buff = true }

local fight -- this fight's scores
local prev  -- { token, before, pending = { guess, conf, slot2 } }
local lastPress

local function NewFight()
  return { n = 0, hit = 0, slot2n = 0, slot2hit = 0, both = 0, bothLearner = 0, bothSlot2 = 0, conf = 0,
    confHit = 0, presses = 0 }
end
fight = NewFight()

-- Per spec and talent loadout: switching talents keeps both sets.
local function ProfileKey()
  local state = ns.Specs and ns.Specs.current
  local key = state and state.key
  if not key then
    return nil
  end
  local config = U.Get(C_ClassTalents and C_ClassTalents.GetActiveConfigID)
  return key .. ":" .. tostring(type(config) == "number" and config or "?")
end

local function Store()
  local g = ns.global or ns.db
  if type(g) ~= "table" then
    return nil
  end
  g.learner = type(g.learner) == "table" and g.learner or {}
  local key = ProfileKey()
  if not key then
    return nil
  end
  local p = g.learner[key]
  if type(p) ~= "table" or type(p.next) ~= "table" then
    p = { next = {}, fights = 0 }
    g.learner[key] = p
  end
  return p
end
L.Store = Store

-- Specs without one: the spender's resource in steps of L.SPENDER_STEP (Astral Power, Maelstrom, Insanity, Fury,
-- Runic Power): Balance alternates Starfire / Starfall on Astral Power the game hides, and without it the learner
-- couldn't tell "enough for Starfall" from "not yet" (slot 2 repeated the spell just pressed 13 times in 22
-- misses, 2026-11-13). Our estimate of it (PowerNow) is enough for low / mid / high.
L.SPENDER = { 8, 11, 13, 17, 6 }
L.SPENDER_STEP = 20
local function Secondary()
  for _, pt in ipairs(L.SECONDARY) do
    local max = U.Get(UnitPowerMax, "player", pt)
    if type(max) == "number" and max > 0 then
      local cur = ns.State.PowerNow and ns.State.PowerNow(pt)
      return type(cur) == "number" and tostring(math.floor(cur + 0.5)) or "?"
    end
  end
  for _, pt in ipairs(L.SPENDER) do
    local max = U.Get(UnitPowerMax, "player", pt)
    if type(max) == "number" and max > 0 then
      local cur = ns.State.PowerNow and ns.State.PowerNow(pt)
      return type(cur) == "number" and ("p" .. math.floor(cur / L.SPENDER_STEP)) or "p?"
    end
  end
  return "-"
end

local function Lit()
  local out = {}
  for id, on in pairs(ns.State.glow or {}) do
    local token = on and ns.SpellMap.TokenForID(id)
    if token then
      out[#out + 1] = token
    end
  end
  table.sort(out)
  return #out > 0 and table.concat(out, ",") or "-"
end

local function Targets()
  local n = ns.State.Targets and ns.State.Targets()
  local aoe = ns.State.AoeTargets and ns.State.AoeTargets() or 3
  if type(n) ~= "number" then
    return "?"
  end
  return n >= aoe and "aoe" or "st"
end

-- The situation right after pressing `token`: most specific first, then coarser ones for when it is new. Chosen by
-- replaying the first real fight's presses (Outlaw, 2026-11-13, tools/prediction-report.py): the spell + secondary
-- resource + lit buttons, then the last two presses, then the spell alone guessed 52% from a cold start (55% with
-- slot 2 where it had no guess) against slot 2's 38%; adding the target count or a third press did worse.
local function Situations(token, before)
  local cp, lit, tg = Secondary(), Lit(), Targets()
  return {
    token .. "|" .. cp .. "|" .. lit,
    token .. "<" .. tostring(before or "-"),
    token,
  }, cp, lit, tg
end

local function Guess(store, keys)
  for level, k in ipairs(keys) do
    local counts = store and store.next[k]
    if counts then
      local total, best, bestN = 0, nil, 0
      for tok, c in pairs(counts) do
        total = total + c
        if c > bestN or (c == bestN and best and tok < best) then
          best, bestN = tok, c
        end
      end
      if total >= L.MIN_N and best then
        return best, bestN / total, level, total
      end
    end
  end
  return nil
end
L.Guess = Guess

local function Learn(store, keys, token)
  if not store then
    return
  end
  for _, k in ipairs(keys) do
    local counts = store.next[k] or {}
    store.next[k] = counts
    counts[token] = (counts[token] or 0) + 1
  end
end

-- A spell in the spec's SimC fight lists (read only: nothing here may change what the engine has loaded).
local actionsOf = setmetatable({}, { __mode = "k" })
local function Rotation(id)
  local state = ns.Specs and ns.Specs.current
  local record = state and state.data
  if type(record) ~= "table" or type(record.simc) ~= "table" then
    return false
  end
  local actions = actionsOf[record]
  if not actions then
    actions = {}
    for name, list in pairs(record.simc) do
      if name ~= "precombat" and type(list) == "table" then
        for _, e in ipairs(list) do
          if type(e) == "table" and e.a then
            actions[e.a] = true
          end
        end
      end
    end
    actionsOf[record] = actions
  end
  local M = ns.SpellMap
  for _, cand in ipairs({ id, M.baseOf and M.baseOf[id] }) do
    local token = cand and M.TokenForID(cand)
    if token and actions[token] then
      -- (a defensive some lists also name: not the damage rotation)
      local D = ns.Defensives
      return not (D and D.InSet and D.InSet(token))
    end
  end
  return false
end

-- Every press of your own (in combat). `shown`: slot 1 at the press; `last`: the full result then.
function L.OnPress(id, shown, last)
  if not id or not Rotation(id) then
    return
  end
  if shown and L.SITUATIONAL[shown.source or ""] and shown.id == id then
    return
  end
  local now = GetTime()
  local baseOf = ns.SpellMap.baseOf or {}
  local base = baseOf[id] or id
  if lastPress and lastPress.base == base and now - lastPress.at < L.PRESS_SAME then
    return -- the rest of one press
  end
  lastPress = { base = base, at = now }
  local token = ns.SpellMap.TokenForID(id) or tostring(id)
  local store = Store()
  fight.presses = fight.presses + 1
  -- score the guesses made at the last press, and learn what really came
  if prev then
    local p = prev.pending
    if p.guess then
      fight.n = fight.n + 1
      local ok = p.guess == token
      if ok then
        fight.hit = fight.hit + 1
      end
      if p.conf >= L.CONFIDENT then
        fight.conf = fight.conf + 1
        if ok then
          fight.confHit = fight.confHit + 1
        end
      end
      if p.slot2 then
        fight.both = fight.both + 1
        if ok then
          fight.bothLearner = fight.bothLearner + 1
        end
        if p.slot2 == token then
          fight.bothSlot2 = fight.bothSlot2 + 1
        end
        -- the running score that decides live or shadow
        if store then
          local vs = store.vs or { n = 0, learner = 0, simc = 0 }
          store.vs = vs
          vs.n = vs.n + 1
          vs.learner = vs.learner + (ok and 1 or 0)
          vs.simc = vs.simc + (p.slot2 == token and 1 or 0)
        end
      end
    end
    if p.slot2 then
      fight.slot2n = fight.slot2n + 1
      if p.slot2 == token then
        fight.slot2hit = fight.slot2hit + 1
      end
    end
    Learn(store, prev.keys, token)
  end
  -- the guess for the next press
  local keys, cp, lit, tg = Situations(token, prev and prev.token)
  local guess, conf, level = Guess(store, keys)
  local q2 = last and last.queue and last.queue[2]
  local slot2 = q2 and (q2.token or (q2.id and ns.SpellMap.TokenForID(q2.id)))
  if last and last.simcNext ~= nil then
    slot2 = last.simcNext or nil -- live: compare with SimC's own forecast, not the learner's slot 2
  end
  -- (slot 2 counts only when you pressed what slot 1 showed: otherwise it was a forecast for another press)
  local followed = shown and shown.id and (baseOf[shown.id] or shown.id) == base
  prev = { token = token, keys = keys,
    pending = { guess = guess, conf = conf or 0, slot2 = followed and slot2 or nil } }
  U.Log("press", { s = token, cp = cp, lit = lit, tg = tg, q2 = followed and slot2 or nil,
    q2src = followed and q2 and q2.source or nil, guess = guess,
    conf = conf and string.format("%.2f", conf) or nil, lvl = level })
end

local function Pct(a, b)
  return b > 0 and math.floor(100 * a / b + 0.5) or 0
end

-- Live or shadow, from the running score (with a gap between the two thresholds, so it doesn't flicker).
function L.Live(store)
  store = store or Store()
  local vs = store and store.vs
  if not vs or vs.n < L.LIVE_N then
    if store then
      store.live = nil
    end
    return false
  end
  local lead = (vs.learner - vs.simc) / vs.n
  if store.live then
    if lead < L.DROP_LEAD then
      store.live = nil
    end
  elseif lead >= L.LIVE_LEAD then
    store.live = true
  end
  return store.live == true
end

-- Live: slot 2 is the learner's guess for the press after slot 1 (SimC's forecast moves to slot 3). Never slot 1.
function L.Apply(result)
  local main = result and result.main
  local queue = result and result.queue
  if not (main and main.id and queue and ns.State.combatStart) or L.SITUATIONAL[main.source or ""] then
    return result
  end
  local store = Store()
  if not store or not Rotation(main.id) then
    return result
  end
  local token = main.token or ns.SpellMap.TokenForID(main.id)
  if not token then
    return result
  end
  local keys = Situations(token, prev and prev.token)
  local guess, conf, level, total = Guess(store, keys)
  -- (and clearly better than SimC's own forecast has been for this spec: where SimC is already right 90-100% of the
  -- time, an 80% guess would make slot 2 worse - Survival and Holy Priest in the simulated fights, 2026-11-14)
  local vs = store.vs
  local simcRate = vs and vs.n >= L.LOCAL_VS_N and vs.simc / vs.n or nil
  -- (not for healers: their next spell follows the group's health, which a situation here doesn't include - the
  -- Holy Priest group fights got worse with it)
  local profile = ns.Defensives and ns.Defensives.Profile and ns.Defensives.Profile()
  local healer = profile and profile.role == "healer"
  local confident = not healer and guess and level and level <= 2 and (total or 0) >= L.LOCAL_N and simcRate
    and conf >= math.max(L.LOCAL_CONF, simcRate + L.LOCAL_LEAD)
  if not (L.Live(store) or confident) then
    return result
  end
  local q2 = queue[2]
  local simcNext = q2 and (q2.token or (q2.id and ns.SpellMap.TokenForID(q2.id)))
  result.simcNext = simcNext or false
  local id = guess and ns.SpellMap.SpellID(guess)
  if not id or guess == simcNext then
    return result
  end
  local out, size = { queue[1], { id = id, token = guess, source = "learned" } }, math.max(#queue, 2)
  for i = 2, #queue do
    if #out < size and queue[i] and queue[i].token ~= guess then
      out[#out + 1] = queue[i]
    end
  end
  result.queue = out
  return result
end

function L.SummaryText()
  local f = fight
  if f.presses == 0 then
    return nil
  end
  local store = Store()
  local situations = 0
  for _ in pairs(store and store.next or {}) do
    situations = situations + 1
  end
  local vs = store and store.vs or { n = 0, learner = 0, simc = 0 }
  return string.format("learner=%d%% n=%d | simc_slot2=%d%% n=%d | same presses: learner=%d/%d simc=%d/%d | "
    .. "confident(>=%.0f%%)=%d/%d | presses=%d situations=%d fights=%d | running: learner=%d%% simc=%d%% n=%.0f %s"
    .. " | profile=%s",
    Pct(f.hit, f.n), f.n, Pct(f.slot2hit, f.slot2n), f.slot2n, f.bothLearner, f.both, f.bothSlot2, f.both,
    100 * L.CONFIDENT, f.confHit, f.conf, f.presses, situations, store and store.fights or 0,
    Pct(vs.learner, vs.n), Pct(vs.simc, vs.n), vs.n, L.Live(store) and "LIVE" or "shadow", tostring(ProfileKey()))
end

-- Fight end: older counts weigh less, tiny ones are forgotten, and the store stays bounded.
local function Decay(store)
  local n = 0
  for k, counts in pairs(store.next) do
    local any = false
    for tok, c in pairs(counts) do
      c = c * L.DECAY
      if c < L.FLOOR then
        counts[tok] = nil
      else
        counts[tok] = c
        any = true
      end
    end
    if any then
      n = n + 1
    else
      store.next[k] = nil
    end
  end
  if n > L.MAX_SITUATIONS then
    -- drop the least-seen situations
    local list = {}
    for k, counts in pairs(store.next) do
      local total = 0
      for _, c in pairs(counts) do
        total = total + c
      end
      list[#list + 1] = { k, total }
    end
    table.sort(list, function(a, b)
      return a[2] < b[2]
    end)
    for i = 1, n - L.MAX_SITUATIONS do
      store.next[list[i][1]] = nil
    end
  end
end

function L.OnCombat(inCombat)
  if inCombat then
    fight, prev, lastPress = NewFight(), nil, nil
    return
  end
  local text = L.SummaryText()
  if text then
    U.Log("learner_summary", text)
  end
  local store = Store()
  if store and fight.presses > 0 then
    store.fights = (store.fights or 0) + 1
    Decay(store)
    local vs = store.vs
    if vs then
      vs.n, vs.learner, vs.simc = vs.n * L.DECAY, vs.learner * L.DECAY, vs.simc * L.DECAY
    end
  end
  fight, prev, lastPress = NewFight(), nil, nil
end
