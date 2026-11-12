-- Grade.lua: how well you played a fight, graded at the end of it (S+ to D), with four parts:
--   Accuracy      each press (of a spell that uses the global cooldown) against what slot 1 showed then: the
--                 spell in slot 1 = 1, the one in slot 2 or 3 = 0.75, anything else = 0. What slot 1 showed up to
--                 Gr.LATE_SWITCH before still counts (a late switch is never your fault). Interrupts, defensives,
--                 trinkets and potions from their own icons don't count either way.
--   Always be casting  share of the fight NOT spent with slot 1 ready ("press now") and nothing pressed; the
--                 first Gr.IDLE_GRACE of each "press now" is free (nobody presses in 0 ms).
--   Reaction      from the moment slot 1 said "press now" to your press of that spell (pressed early and queued
--                 counts as instant). 0.25 s or less is full marks, 1.5 s or more is none.
--   Cooldowns     how quickly major cooldowns, trinkets and the potion were used once slot 1 or the items icon
--                 showed them ready: within 2 s full marks, 10 s none. A major cooldown shown and never used
--                 counts as 10 s; an item never used doesn't count (nobody spends a potion on a dummy).
-- Letters (decided 2026-11-09): B+ is reachable for most players, A takes accurate play, S is rare.
-- Overall: 35% accuracy, 25% always be casting, 20% reaction, 20% cooldowns. It never claims damage: addons can't
-- read the combat log in Midnight, and damage depends on gear; the game's damage meter shows that.
-- Saved account-wide per spec: the best grade and the last 20 fights (DMGAssistDB global grades).

local _, ns = ...
local U, L = ns.U, ns.L

local Gr = {}
ns.Grade = Gr

-- mitigation: tanks only (Tanks.lua), how quickly the defensive icon's mitigation was pressed once it showed
Gr.WEIGHTS = { accuracy = 0.35, abc = 0.25, reaction = 0.20, cooldowns = 0.20, mitigation = 0.25 }
Gr.LETTERS = { { 96, "S+" }, { 91, "S" }, { 86, "A+" }, { 80, "A" }, { 72, "B+" }, { 64, "B" }, { 50, "C" },
  { 0, "D" } }
Gr.COLORS = { ["S+"] = { 1, 0.85, 0.25 }, S = { 1, 0.6, 0.15 }, ["A+"] = { 0.85, 0.5, 1 }, A = { 0.7, 0.4, 1 },
  ["B+"] = { 0.35, 0.75, 1 }, B = { 0.3, 0.6, 1 }, C = { 0.35, 0.85, 0.35 }, D = { 0.65, 0.65, 0.65 } }
Gr.SLOT23 = 0.75
Gr.WEAK_GAP = 6
Gr.LATE_SWITCH = 0.6
Gr.IDLE_GRACE = 0.25
Gr.MIN_SHOWN = 2 -- a cooldown shown for less than this before slot 1 moved on isn't graded
Gr.HISTORY = 20
Gr.MIN_FIGHT = 20

local fight -- the fight being graded

-- The fight's clock without the time spent moving: reaction, cooldown and mitigation delays are measured on it,
-- so stepping out of a boss's damage doesn't count as slow (asked for 2026-11-10).
local function Clock(f)
  -- (and without the time between chained fights, including the one being waited out)
  local waiting = f.pausedAt and (GetTime() - f.pausedAt) or 0
  return GetTime() - (f.moveT or 0) - (f.gaps or 0) - waiting
end

local function DB()
  local g = ns.global or ns.db
  if type(g) ~= "table" then
    return nil
  end
  g.grades = type(g.grades) == "table" and g.grades or {}
  return g.grades
end

local function SpecKey()
  return ns.Specs.current and ns.Specs.current.key or "?"
end
Gr.SpecKey = SpecKey

function Gr.Enabled()
  return not (ns.db and ns.db.grade == false)
end

local function Base(id)
  return (ns.SpellMap.baseOf and ns.SpellMap.baseOf[id]) or id
end

local function Same(a, b)
  return a ~= nil and b ~= nil and (a == b or Base(a) == Base(b))
end

---------------------------------------------------------------------------
-- During the fight
---------------------------------------------------------------------------
-- Quick fights chain (questing, mob to mob): a fight that starts within Gr.CHAIN_GAP of the last one's end
-- continues it, and the grade comes once you've been out of combat that long, or at a fight's end once the chain
-- has run Gr.CHAIN_MAX. A popup after every 10 s mob, six a minute, was too much; and fights shorter than
-- Gr.MIN_FIGHT were never graded at all (Balance, Springpaw Lynx, 2026-11-10). Time between fights counts
-- for nothing. Bosses are graded at once. Setting gradeChain (default on).
Gr.CHAIN_GAP = 10
Gr.CHAIN_MAX = 180
local pending -- the chain waiting out the gap

local function Publish(f, at)
  local r = Gr.Finish(f, at)
  if r then
    Gr.Show(r)
  elseif ns.Game and ns.Game.On() then
    ns.Game.EndSet() -- too short to grade (breaks taken out): the Flow set still ends, the next starts fresh
  end
end

local function GameOn()
  return ns.Game ~= nil and ns.Game.On()
end

-- Game mode plays a whole set of pulls as one: chained always, until Game.SET_GAP out of combat, bosses included.
local function Chaining()
  return GameOn() or not (ns.db and ns.db.gradeChain == false)
end

local function ChainGap()
  return GameOn() and ns.Game.SET_GAP or Gr.CHAIN_GAP
end

function Gr.OnCombat(on)
  local now = GetTime()
  if on then
    -- a new fight: the last one's grade makes way (it stayed up when a dummy pulled you back in, 2026-11-10)
    local fr = Gr.frame
    if fr and fr:IsShown() and not fr.sample then
      fr:Hide()
    end
    local p = pending
    pending = nil
    if p and now - p.pausedAt <= ChainGap() then
      p.gaps = (p.gaps or 0) + (now - p.pausedAt)
      p.lastTick, p.pausedAt = nil, nil
      p.fights = (p.fights or 1) + 1
      fight = p
      return
    end
    fight = { start = now, presses = 0, score = 0, reactions = {}, idle = 0, lastTick = nil, fights = 1,
      ready = nil, cds = {}, cdShown = {}, cdReady = {}, missed = {}, instead = {}, targets = 0, mit = {}, mitShown = {}, slips = {} }
    return
  end
  local f = fight
  fight = nil
  if not (f and Gr.Enabled()) then
    return
  end
  local boss = ns.State and ns.State.FightContext and ns.State.FightContext() == "boss"
  if not Chaining() or (not GameOn() and (boss or now - f.start - (f.gaps or 0) >= Gr.CHAIN_MAX)) then
    Publish(f, now)
    return
  end
  -- wait out the gap: another fight soon continues this one
  f.pausedAt, f.endAt = now, now
  pending = f
  if C_Timer and C_Timer.After then
    C_Timer.After(ChainGap() + 0.05, function()
      if pending == f and not fight then
        pending = nil
        Publish(f, f.endAt)
      end
    end)
  end
end

-- The chain waiting for its gap to pass (for the report and tests).
function Gr.Pending()
  return pending
end

-- Display: slot 1 says "press now" for this spell.
function Gr.OnReady(id, _, main) -- (2nd: the time; the fight clock is used)
  local f = fight
  if not f or not id then
    return
  end
  if not (f.ready and Same(f.ready.id, id)) then
    f.ready = { id = id, t = Clock(f) }
  end

  if Gr.IsCooldown(main) and f.cdShown[Base(id)] and not f.cdReady[Base(id)] then
    f.cdReady[Base(id)] = Clock(f) -- "press now" for this cooldown: its delay is timed from here
  end
end

-- Every frame while the HUD shows: count the time slot 1 was ready and nothing was pressed.
function Gr.Tick(pressNow)
  local f = fight
  if not f then
    return
  end
  local now = GetTime()
  -- what slot 1 shows, and when it changed (every frame): a press of the previous one just after a switch counts
  local main = ns.last and ns.last.main
  if main and main.id and not (f.shown and Same(f.shown.id, main.id)) then
    -- a major cooldown slot 1 showed only briefly before switching away: not long enough to be judged on
    local gone = f.shown and Base(f.shown.id)
    if gone and f.cdShown[gone] and now - f.cdShown[gone] < Gr.MIN_SHOWN then
      f.cdShown[gone], f.cdReady[gone] = nil, nil
    end
    f.prevShown, f.shown = f.shown, { id = main.id, t = now }
  end
  if Gr.IsCooldown(main) and not f.cdShown[Base(main.id)] then
    f.cdShown[Base(main.id)] = now -- a cooldown appears in slot 1
  end
  if pressNow and not f.wasReady then
    f.readySince = now
  end
  -- idle only when you could have pressed it: in range and usable (out of range or short of resources is not on you)
  -- moving (out of boss damage, to a new spot): the clocks below stop, and it's never idle time
  local moving = ns.State.moving == true
  if f.lastTick and moving then
    f.moveT = (f.moveT or 0) + math.min(0.25, now - f.lastTick)
  end
  local couldPress = pressNow and not moving and main and main.id
    and U.Read((U.Call(C_Spell and C_Spell.IsSpellInRange, main.id, "target"))) ~= false
    and U.Read((U.Call(C_Spell and C_Spell.IsSpellUsable, main.id))) ~= false
  if f.lastTick and couldPress and f.wasReady and now - (f.readySince or now) > Gr.IDLE_GRACE then
    f.idle = f.idle + math.min(0.25, now - f.lastTick)
  elseif not pressNow then
    f.ready = nil -- reaction is timed from the latest "press now", not an earlier one
  end
  if f.lastTick and not moving then
    Gr.CompareTick(f, main, math.min(0.25, now - f.lastTick))
  end
  f.lastTick, f.wasReady = now, pressNow
  local t = ns.last and ns.last.trinket
  local key = t and (t.item or t.id)
  if key and not f.cdShown["item:" .. tostring(key)] and not (f.itemsUsed and f.itemsUsed[key]) then
    f.cdShown["item:" .. tostring(key)] = now
  end
  f.targets = math.max(f.targets, tonumber((ns.State.Targets())) or 0)
  local w = ns.last and ns.last.weave
  if w and w.source == "mitigation" and w.id and not f.mitShown[Base(w.id)] then
    f.mitShown[Base(w.id)] = Clock(f)
  end
end

-- Beyond Assisted Combat: every moment slot 1 and Blizzard's assistant both name a spell, whether they agree, and
-- when they don't, why ours differs. Never a damage claim (addons can't read damage): it shows where DMGAssist
-- plays differently from Blizzard's suggestion, by kind (asked for 2026-11-10).
--   cooldowns: a 20 s+ cooldown timed by SimC (Blizzard names them whenever ready, or never)
--   upkeep:    a DoT / buff kept up by our own rules or timers (Moonfire, Sunfire, forms)
--   utility:   an interrupt, defensive or gap closer in slot 1 (Blizzard's assistant has none)
--   rotation:  a different core spell, SimC's priority over Blizzard's
-- Extras: presses of what Blizzard never shows at all (the off-GCD badge, trinkets, the defensive icon).
Gr.VS_KINDS = { "cooldowns", "rotation", "upkeep", "utility" }
local UTILITY = { interrupt = true, defensive = true, mitigation = true, gapcloser = true, form = true }
function Gr.VsKind(main, ac)
  if main.source and UTILITY[main.source] then
    return "utility"
  end
  if main.source == "keepup" then
    return "upkeep"
  end
  if Gr.IsCooldown(main) or Gr.IsCooldown({ id = ac }) then
    return "cooldowns"
  end
  return "rotation"
end

function Gr.CompareTick(f, main, dt)
  local ac = ns.Engine and ns.Engine.acNow
  if not (main and main.id and ac and dt > 0) or (ns.Engine.acStuck == true) then
    return
  end
  local vs = f.vs or { total = 0, same = 0, cooldowns = 0, rotation = 0, upkeep = 0, utility = 0 }
  f.vs = vs
  vs.total = vs.total + dt
  if Same(main.id, ac) then
    vs.same = vs.same + dt
  else
    local kind = Gr.VsKind(main, ac)
    vs[kind] = vs[kind] + dt
  end
end

-- The comparison as shares of the compared time (percent), nil when there is too little to say anything.
function Gr.VsShares(vs, extras)
  if not (vs and vs.total and vs.total >= 10) then
    return nil
  end
  local out = { extras = extras or 0, same = 100 * vs.same / vs.total }
  local diff = 0
  for _, k in ipairs(Gr.VS_KINDS) do
    out[k] = 100 * (vs[k] or 0) / vs.total
    diff = diff + out[k]
  end
  out.differs = diff
  return out
end

-- One line: "Beyond Assisted Combat: 28% of the fight - cooldowns 16% · rotation 12% · 9 extras" (kinds under 1%
-- left out).
function Gr.VsText(v)
  if not v then
    return nil
  end
  local parts = {}
  local names = { cooldowns = L["cooldowns %d%%"], rotation = L["rotation %d%%"], upkeep = L["upkeep %d%%"],
    utility = L["utility %d%%"] }
  for _, k in ipairs(Gr.VS_KINDS) do
    if (v[k] or 0) >= 1 then
      parts[#parts + 1] = string.format(names[k], math.floor(v[k] + 0.5))
    end
  end
  if (v.extras or 0) > 0 then
    parts[#parts + 1] = string.format(L["%d extras"], v.extras)
  end
  local head = string.format(L["Beyond Assisted Combat: %d%% of the fight"], math.floor((v.differs or 0) + 0.5))
  if #parts == 0 then
    return head
  end
  return head .. " - " .. table.concat(parts, " · ")
end

-- A cooldown worth grading: a major cooldown, or any spell with a cooldown of Gr.KEY_CD seconds or more (Fury of
-- Elune isn't a "major" cooldown and wasn't graded, 2026-11-10).
Gr.KEY_CD = 20
function Gr.IsCooldown(p)
  if not (p and p.id) or p.source == "interrupt" then
    return false
  end
  if p.major then
    return true
  end
  local len = ns.State.CooldownLength and ns.State.CooldownLength(p.id)
  return type(len) == "number" and len >= Gr.KEY_CD
end

local function IsOffGCD(id)
  local info = ns.SpellMap.Info(id)
  return info and (info.gcd == nil or info.gcd == 0) or false
end

-- Every cast of yours: r = the recommendation that was showing; press = it was a button press (Main.lua IsPress:
-- one per press, and only spells you know, so item uses are never presses).
-- Key slips: a wrong press on the key right next to the one slot 1 showed (5 for 6, Q for W, F2 for F3), or the
-- same key without (or with) its Shift / Ctrl / Alt. Asked for 2026-11-11: "my hand was one key to the left and I
-- didn't realize". Slot 1 shows it for a moment ("5 » 6"), and a slip that keeps happening becomes the fight's tip.
Gr.KEY_ROWS = { "1234567890-=", "QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM" }
Gr.SLIP_TIP = 3 -- the same slip this many times in a fight: it's the tip

local function SplitKey(k)
  if type(k) ~= "string" or k == "" or k:find("|", 1, true) or k:find("+", 1, true) then
    return nil -- no key, or a controller button / glyph: no keyboard neighbours
  end
  return k:match("^([SCA]*)(.+)$")
end

local function RowPos(base)
  for r, row in ipairs(Gr.KEY_ROWS) do
    local i = row:find(base, 1, true)
    if #base == 1 and i then
      return r, i
    end
  end
  return nil
end

-- true when `got` is a likely slip for `want` (both key texts as the HUD shows them: "5", "S5", "F3", "CQ").
function Gr.IsSlip(want, got)
  local wm, wb = SplitKey(want)
  local gm, gb = SplitKey(got)
  if not (wb and gb) or want == got then
    return false
  end
  if wb == gb then
    return wm ~= gm -- the right key, the wrong modifier
  end
  if wm ~= gm then
    return false
  end
  local wf, gf = tonumber(wb:match("^F(%d+)$")), tonumber(gb:match("^F(%d+)$"))
  if wf and gf then
    return math.abs(wf - gf) == 1
  end
  local wr, wi = RowPos(wb)
  local gr, gi = RowPos(gb)
  return wr ~= nil and wr == gr and math.abs(wi - gi) == 1
end

local function NoteSlip(f, main, id)
  local D = ns.Display
  if not (D and D.PickKeybind and D.Keybind) then
    return
  end
  local want, got = D.PickKeybind(main), D.Keybind(id)
  if not Gr.IsSlip(want, got) then
    return
  end
  local key = want .. ">" .. got
  local e = f.slips[key] or { want = want, got = got, n = 0, id = main.id }
  e.n = e.n + 1
  f.slips[key] = e
  if D.ShowSlip then
    D.ShowSlip(got, want)
  end
end
Gr.NoteSlip = NoteSlip

function Gr.OnPress(id, r, press)
  local f = fight
  if not (f and id and r) then
    return
  end
  local now = GetTime()
  -- items and the staying-alive icon: cooldown use, never accuracy
  local t = r.trinket
  local game = ns.Game
  if t and Same(t.id, id) then
    if game then
      game.OnBonus("item")
    end
    local key = "item:" .. tostring(t.item or t.id)
    f.itemsUsed = f.itemsUsed or {}
    f.itemsUsed[t.item or t.id] = true
    f.extras = (f.extras or 0) + 1
    if f.cdShown[key] then
      f.cds[#f.cds + 1] = now - f.cdShown[key]
      f.cdShown[key] = nil
    end
    return
  end
  if r.weave and r.weave.source == "mitigation" and Same(r.weave.id, id) then
    f.extras = (f.extras or 0) + 1
    if game then
      game.OnBonus("defend")
    end
    local key = Base(id)
    if f.mitShown[key] then
      f.mit[#f.mit + 1] = Clock(f) - f.mitShown[key]
      f.mitShown[key] = nil
    end
    return
  end
  if not press or (r.weave and Same(r.weave.id, id)) then
    if press and r.weave then
      f.extras = (f.extras or 0) + 1 -- the off-GCD badge (Ironfur): Blizzard never shows it
      if game and r.weave.source == "defensive" then
        game.OnBonus("defend")
      end
    end
    return
  end
  local main = r.main
  local queue = r.queue or { main }
  -- An interrupt in slot 1 is your call: judge against the rotation behind it.
  if main and main.source == "interrupt" then
    if Same(main.id, id) then
      if game then
        game.OnBonus("kick")
      end
      return
    end
    queue = { queue[2], queue[3] }
    main = queue[1]
  end
  -- Only what we gave you to do counts: nothing shown, or a spell outside the rotation (movement, utility, a
  -- defensive or tank button pressed early, a racial) is neither right nor wrong.
  if not (main and main.id) then
    f.neutral = (f.neutral or 0) + 1
    return
  end
  local inQueue = Same(main.id, id) or (queue[2] and Same(queue[2].id, id)) or (queue[3] and Same(queue[3].id, id))
    or (f.prevShown and Same(f.prevShown.id, id))
  if not inQueue and (ns.Engine.IsRotationSpell(id) == false or (ns.Defensives and ns.Defensives.InSet
    and ns.Defensives.InSet(ns.SpellMap.TokenForID(id))) or (ns.Tanks and ns.Tanks.InIcon(ns.SpellMap.TokenForID(id)))) then
    f.neutral = (f.neutral or 0) + 1
    return
  end
  local matched = main and Same(main.id, id)
  if not matched and f.prevShown and f.shown and now - f.shown.t <= Gr.LATE_SWITCH and Same(f.prevShown.id, id) then
    matched = true -- slot 1 had just switched away from this spell: your press was right when you made it
  end
  if matched or not IsOffGCD(id) then
    -- A break: BREAK seconds or more with no spell (between packs, a cutscene, a boss walking across the room, Flow
    -- mode's pause). Nothing was on you: the stretch leaves the fight's length and its idle time is given back
    -- (2026-11-12: "Always casting" 33% after waiting between packs on dummies).
    local gap = f.lastPress and (now - f.lastPress) or 0
    if gap >= Gr.BREAK then
      local moved = (f.moveT or 0) - (f.moveAtPress or 0) -- already off the clock
      local cut = math.max(0, gap - moved)
      f.idle = f.idleAtPress or f.idle
      f.gaps = (f.gaps or 0) + cut
      f.breaks = (f.breaks or 0) + 1
      f.ready = nil -- no reaction time from a "press now" before the break
      local clock = Clock(f)
      for k, at in pairs(f.cdReady) do
        f.cdReady[k] = math.min(at, clock) -- ready during the break: from now, not before
      end
    end
    f.presses = f.presses + 1
    f.lastPress, f.lastPressClock, f.idleAtPress = now, Clock(f), f.idle
    f.moveAtPress = f.moveT or 0
    if f.vs then
      local snap = {}
      for k, v in pairs(f.vs) do
        snap[k] = v
      end
      f.vsAtPress = snap
    end
    if matched then
      f.score = f.score + 1
      f.right = (f.right or 0) + 1
      if game then
        game.OnJudged("hit", id)
      end
    elseif (queue[2] and Same(queue[2].id, id)) or (queue[3] and Same(queue[3].id, id)) then
      f.score = f.score + Gr.SLOT23
      f.slot23 = (f.slot23 or 0) + 1
      if game then
        game.OnJudged("near", id)
      end
    else
      f.wrong = (f.wrong or 0) + 1
      if game then
        game.OnJudged("miss", id)
      end
      NoteSlip(f, main, id)
      local want = main and (main.token or tostring(main.id))
      if want then
        f.missed[want] = (f.missed[want] or 0) + 1
      end
    end
  end
  if matched and f.ready and Same(f.ready.id, id) then
    f.reactions[#f.reactions + 1] = math.max(0, Clock(f) - f.ready.t)
    f.ready = nil
  end
  local key = Base(id)
  if f.cdShown[key] then
    -- from the moment it was ready; pressed before that (the game queues it): on time
    f.cds[#f.cds + 1] = f.cdReady[key] and (Clock(f) - f.cdReady[key]) or 0
    f.cdShown[key], f.cdReady[key] = nil, nil
  elseif inQueue and Gr.IsCooldown({ id = id }) then
    f.cds[#f.cds + 1] = 0 -- a cooldown from slot 2 or 3, used as it came up
  end
end

---------------------------------------------------------------------------
-- The grade
---------------------------------------------------------------------------
local function Pct(v)
  return v and string.format("%d%%", math.floor(v + 0.5)) or "-"
end

local function Clamp(x)
  return math.max(0, math.min(100, x))
end

function Gr.Letter(score)
  for _, l in ipairs(Gr.LETTERS) do
    if score >= l[1] then
      return l[2]
    end
  end
  return "D"
end

local function Median(list)
  if #list == 0 then
    return nil
  end
  local t = {}
  for i, v in ipairs(list) do
    t[i] = v
  end
  table.sort(t)
  return t[math.floor((#t + 1) / 2)]
end

-- Reaction (seconds) to a score: 0.25 s or less = 100, 1.5 s or more = 0, straight in between.
function Gr.ReactionScore(sec)
  if not sec then
    return nil
  end
  return Clamp(100 - (sec - 0.25) / 1.25 * 100)
end

-- Mitigation delay (seconds) to a score: within 1 s = 100, 5 s or more = 0 (keep-up matters sooner).
function Gr.MitigationScore(sec)
  return Clamp(100 - (sec - 1) / 4 * 100)
end

-- Cooldown delay (seconds) to a score: within 2 s = 100, 10 s or more = 0.
function Gr.DelayScore(sec)
  return Clamp(100 - (sec - 2) / 8 * 100)
end

-- "n:low/median/high" of a list of seconds (25th / 50th / 75th percentile, ms), for the report.
local function Spread(list)
  if #list == 0 then
    return nil
  end
  local t = {}
  for i, v in ipairs(list) do
    t[i] = v
  end
  table.sort(t)
  local function at(q)
    return math.floor(t[math.max(1, math.min(#t, math.floor(q * #t + 0.5)))] * 1000 + 0.5)
  end
  return string.format("%d:%d/%d/%d", #t, at(0.25), at(0.5), at(0.75))
end

-- The fight is graded up to your last rotation press plus Gr.TAIL seconds: a dummy keeps you in combat after you
-- stop, and walking away from it isn't idle time or an unused cooldown (Guardian, 2026-11-10: 20 s of walking off
-- at the end counted as 14 s idle and Lunar Beam "never used", a C for a clean fight).
Gr.TAIL = 3
Gr.BREAK = 6 -- seconds with no spell that make a break (same as Flow mode's pause)
function Gr.Finish(f, now)
  local endClock = Clock(f)
  if f.lastPress and now - f.lastPress > Gr.TAIL then
    now = f.lastPress + Gr.TAIL
    endClock = f.lastPressClock + Gr.TAIL
    f.idle = math.min(f.idle, (f.idleAtPress or 0) + Gr.TAIL)
    f.vs = f.vsAtPress or f.vs
  end
  local length = now - f.start - (f.gaps or 0)
  if length < (tonumber(ns.db and ns.db.gradeMinFight) or Gr.MIN_FIGHT) or f.presses < 5 then
    return nil
  end
  for key in pairs(f.cdShown) do
    if type(key) == "string" and key:find("^item:") then -- luacheck: ignore 542
      -- an item never used isn't graded
    elseif f.cdReady[key] and endClock - f.cdReady[key] > 3 then
      f.cds[#f.cds + 1] = math.max(10, endClock - f.cdReady[key]) -- a cooldown slot 1 called ready, never used
    end
  end
  local accuracy = Clamp(f.score / f.presses * 100)
  local abc = Clamp(100 - f.idle / length * 100)
  local reactionSec = Median(f.reactions)
  local reaction = Gr.ReactionScore(reactionSec)
  local cd
  if #f.cds > 0 then
    local sum = 0
    for _, d in ipairs(f.cds) do
      sum = sum + Gr.DelayScore(d)
    end
    cd = sum / #f.cds
  end
  for _, shownAt in pairs(f.mitShown) do
    if endClock - shownAt > 2 then
      f.mit[#f.mit + 1] = math.max(5, endClock - shownAt) -- shown, never pressed
    end
  end
  local mit
  if #f.mit > 0 then
    local sum = 0
    for _, d in ipairs(f.mit) do
      sum = sum + Gr.MitigationScore(d)
    end
    mit = sum / #f.mit
  end
  local parts = { accuracy = accuracy, abc = abc, reaction = reaction, cooldowns = cd, mitigation = mit }
  local total, weight = 0, 0
  for k, w in pairs(Gr.WEIGHTS) do
    if parts[k] then
      total, weight = total + parts[k] * w, weight + w
    end
  end
  local score = weight > 0 and total / weight or 0
  -- One clearly weaker part can't hide behind the others: the total is at most Gr.WEAK_GAP above the weakest
  -- part (2026-11-10: 99% accuracy, full reaction and cooldowns hid 88% always-casting and gave S+ for an easy
  -- dummy fight). S+ takes every part strong.
  local lowest
  for k in pairs(Gr.WEIGHTS) do
    if parts[k] and (not lowest or parts[k] < lowest) then
      lowest = parts[k]
    end
  end
  local capped = lowest and math.min(score, lowest + Gr.WEAK_GAP) or score
  local limitedBy = capped < score - 0.05
  score = capped
  local r = { score = score, letter = Gr.Letter(score), accuracy = accuracy, abc = abc, reaction = reaction,
    reactionMs = reactionSec and math.floor(reactionSec * 1000 + 0.5), cooldowns = cd, mitigation = mit,
    length = length, fights = f.fights,
    idle = f.idle, presses = f.presses, targets = f.targets, at = _G.time and _G.time() or 0,
    vs = Gr.VsShares(f.vs, f.extras) }
  -- the tip: the weakest part
  local weakest, low = nil, 101
  for k in pairs(Gr.WEIGHTS) do
    if parts[k] and parts[k] < low then
      weakest, low = k, parts[k]
    end
  end
  local topMissed, n = nil, 0
  for want, c in pairs(f.missed) do
    if c > n then
      topMissed, n = want, c
    end
  end
  r.weakest, r.topMissed, r.topMissedCount = weakest, topMissed, n
  local slip
  for _, e in pairs(f.slips or {}) do
    if not slip or e.n > slip.n then
      slip = e
    end
  end
  if slip then
    r.slipWant, r.slipGot, r.slipCount, r.slipSpell = slip.want, slip.got, slip.n, slip.id
  end
  r.game = ns.Game and ns.Game.EndSet() or nil -- Game mode: the set's score and best streak
  Gr.Save(r)
  U.Log("grade", { letter = r.letter, score = string.format("%.1f", score), accuracy = math.floor(accuracy),
    abc = math.floor(abc), reaction = r.reactionMs, cooldowns = cd and math.floor(cd),
    mitigation = mit and math.floor(mit), length = math.floor(length),
    -- what the accuracy is made of, to check it against the fight's log
    capped = limitedBy and "yes" or nil, presses = f.presses, right = f.right or 0, slot23 = f.slot23 or 0,
    wrong = f.wrong or 0, neutral = f.neutral or 0,
    idle = string.format("%.1f", f.idle), missed = topMissed and (topMissed .. "x" .. n) or nil,
    slip = slip and (slip.got .. "for" .. slip.want .. "x" .. slip.n) or nil,
    cds = #f.cds, mits = #f.mit, reactions = Spread(f.reactions), cdDelays = Spread(f.cds),
    vs = r.vs and string.format("same%d cd%d rot%d keep%d util%d extras%d", r.vs.same, r.vs.cooldowns,
      r.vs.rotation, r.vs.upkeep, r.vs.utility, r.vs.extras) or nil })
  return r
end

-- Tips: several wordings of each piece of advice, one picked at random from the ones that fit the weakest part,
-- so the popup doesn't read the same after every fight (asked for 2026-11-10). %s / %d / %.1f as noted per pool.
Gr.TIPS = {
  -- %s = the key you pressed, %d = how many times, %s = the key slot 1 showed, %s = its spell
  slip = { "Tip: you pressed %s %d times when slot 1 showed %s (%s). If that key is hard to reach, move the spell "
    .. "to one that's easier to hit." },
  named = { -- %s = the spell slot 1 asked for, %d = how many times
    "Tip: slot 1 asked for %s %d times when you pressed something else.",
    "Tip: %s came up in slot 1 %d times and something else got pressed. Give it the priority.",
    "Tip: watch for %s - slot 1 wanted it %d times this fight.",
  },
  accuracy = {
    "Tip: press what slot 1 shows; slots 2 and 3 are what comes after it.",
    "Tip: slot 1 is always the next press. Slots 2 and 3 are a preview, not a choice.",
    "Tip: follow slot 1 in order; the priority already accounts for your procs and cooldowns.",
    "Tip: if two spells look good, trust slot 1 - it's the one that does the most right now.",
  },
  idle = { -- %.1f = seconds with slot 1 ready and nothing pressed
    "Tip: slot 1 was ready for %.1f s without a press. Keep the global cooldown rolling.",
    "Tip: %.1f s went by with a spell ready and nothing pressed. Something to press is almost always there.",
    "Tip: you lost %.1f s of casting this fight. Press the next spell as the last one finishes.",
  },
  abc = {
    "Tip: keep a button going at all times; even a filler beats waiting.",
    "Tip: when you have to move, use instant spells so the casting doesn't stop.",
  },
  reaction = {
    "Tip: press as the flash comes, or a little before: the game queues a press made just before it's ready.",
    "Tip: you can press a moment before slot 1 is ready; the game queues it for you.",
    "Tip: watch the sweep on slot 1 and press as it closes, not after.",
    "Tip: a key close to your hand makes slot 1 quicker to press.",
    "Tip: react to the flash on slot 1; every small pause adds up over a fight.",
  },
  cooldowns = {
    "Tip: use major cooldowns, trinkets and your potion as soon as they show.",
    "Tip: a cooldown sitting ready is damage lost. Press it when slot 1 shows it.",
    "Tip: cooldowns come back sooner the sooner you use them.",
    "Tip: bind your cooldowns where you can reach them in a hurry.",
    "Tip: when slot 1 shows a cooldown it's already lined up with your other buffs: press it.",
  },
  mitigation = {
    "Tip: press your mitigation (the red icon) as soon as it shows; it's timed to keep you safe.",
    "Tip: keep your mitigation rolling: press the red icon as it lights up, before the hits land.",
    "Tip: tanking is timing. The red icon shows your mitigation exactly when it's due.",
    "Tip: late mitigation means a big hit taken. Keep an eye on the red icon.",
  },
  none = {
    "Nothing to improve: keep it up.",
    "Nothing to improve: that was clean.",
    "Great fight: every part was on point.",
    "Nothing to fix this time. Try it on a harder target.",
  },
}

local function Pick(pool)
  return L[pool[math.random(#pool)]]
end

function Gr.Tip(r)
  local T = Gr.TIPS
  if (tonumber(r.slipCount) or 0) >= Gr.SLIP_TIP and r.weakest ~= nil then
    local name = r.slipSpell and U.Get(C_Spell and C_Spell.GetSpellName, r.slipSpell) or "?"
    return string.format(Pick(T.slip), r.slipGot, r.slipCount, r.slipWant, name)
  end
  if r.weakest == "accuracy" then
    if r.topMissed then
      local name = r.topMissed:gsub("_", " ")
      return string.format(Pick(T.named), name, r.topMissedCount or 1)
    end
    return Pick(T.accuracy)
  elseif r.weakest == "abc" then
    if (tonumber(r.idle) or 0) >= 1 then
      return string.format(Pick(T.idle), r.idle)
    end
    return Pick(T.abc)
  elseif r.weakest == "reaction" then
    return Pick(T.reaction)
  elseif r.weakest == "mitigation" then
    return Pick(T.mitigation)
  elseif r.weakest == "cooldowns" then
    return Pick(T.cooldowns)
  end
  return Pick(T.none)
end

function Gr.TipsOn()
  return not (ns.db and ns.db.gradeTips == false)
end

---------------------------------------------------------------------------
-- Saved results
---------------------------------------------------------------------------
function Gr.Save(r)
  local db = DB()
  if not db then
    return
  end
  local key = SpecKey()
  local s = type(db[key]) == "table" and db[key] or { history = {} }
  db[key] = s
  s.history = type(s.history) == "table" and s.history or {}
  table.insert(s.history, 1, { score = r.score, letter = r.letter, accuracy = r.accuracy, abc = r.abc,
    reaction = r.reaction, reactionMs = r.reactionMs, cooldowns = r.cooldowns, mitigation = r.mitigation, at = r.at,
    targets = r.targets,
    weakest = r.weakest, idle = r.idle, length = r.length, fights = r.fights, topMissed = r.topMissed,
    topMissedCount = r.topMissedCount, slipWant = r.slipWant, slipGot = r.slipGot, slipCount = r.slipCount,
    slipSpell = r.slipSpell,
    vs = r.vs })
  while #s.history > Gr.HISTORY do
    table.remove(s.history)
  end
  if not s.best or r.score > s.best.score then
    r.newBest = s.best ~= nil
    s.best = { score = r.score, letter = r.letter, at = r.at }
  end
end

function Gr.Summary(key)
  local db = DB()
  local s = db and db[key or SpecKey()]
  return type(s) == "table" and s or nil
end

-- key = one spec's results (nil = every spec's).
function Gr.Reset(key)
  local db = DB()
  if not db then
    return
  end
  if key then
    db[key] = nil
  else
    for k in pairs(db) do
      db[k] = nil
    end
  end
end

-- The report on the settings page, for the spec you are in: best, the trend of the last 10 fights, the average of
-- each part, and where to improve. Returns text lines (nil when no fight was graded yet).
Gr.TREND_FIGHTS = 10
local function Colored(letter)
  local c = Gr.COLORS[letter] or Gr.COLORS.D
  return string.format("|cff%02x%02x%02x%s|r", c[1] * 255, c[2] * 255, c[3] * 255, letter)
end
Gr.Colored = Colored

local function Average(list, field, from, to)
  local sum, n = 0, 0
  for i = from, math.min(to, #list) do
    local v = list[i][field]
    if type(v) == "number" then
      sum, n = sum + v, n + 1
    end
  end
  return n > 0 and sum / n or nil
end

function Gr.Report(key)
  local s = Gr.Summary(key)
  local h = s and s.history
  if not (h and #h > 0) then
    return nil
  end
  local lines = {}
  local fmtDate = _G.date
  if s.best then
    lines[#lines + 1] = string.format("|cffffd100%s|r  %s  %.1f%s", L["Best"], Colored(s.best.letter), s.best.score,
      (fmtDate and s.best.at and s.best.at > 0) and ("  (" .. fmtDate("%Y-%m-%d", s.best.at) .. ")") or "")
  end
  local n = math.min(#h, Gr.TREND_FIGHTS)
  local row = {}
  for i = n, 1, -1 do -- oldest first, newest last
    row[#row + 1] = Colored(h[i].letter or "D")
  end
  lines[#lines + 1] = string.format("|cffffd100%s|r  %s", string.format(L["Last %d fights (newest last)"], n),
    table.concat(row, " "))
  if #h >= 6 then
    local recent, before = Average(h, "score", 1, 3), Average(h, "score", 4, 10)
    local word = L["steady"]
    if recent and before and recent - before >= 3 then
      word = "|cff33dd33" .. L["improving"] .. "|r"
    elseif recent and before and before - recent >= 3 then
      word = "|cffff6060" .. L["slipping"] .. "|r"
    end
    lines[#lines + 1] = string.format("|cffffd100%s|r  %s", L["Trend"], word)
  end
  local avg = {
    accuracy = Average(h, "accuracy", 1, n), abc = Average(h, "abc", 1, n), reaction = Average(h, "reaction", 1, n),
    cooldowns = Average(h, "cooldowns", 1, n), mitigation = Average(h, "mitigation", 1, n),
  }
  local ms = Average(h, "reactionMs", 1, n)
  lines[#lines + 1] = string.format("|cffffd100%s|r  %s %s   %s %s   %s %s   %s %s",
    string.format(L["Average of the last %d"], n), L["Accuracy"], Pct(avg.accuracy), L["Always casting"],
    Pct(avg.abc), L["Reaction"], ms and (math.floor(ms + 0.5) .. " ms") or "-", L["Cooldowns"], Pct(avg.cooldowns))
  if avg.mitigation then
    lines[#lines] = lines[#lines] .. string.format("   %s %s", L["Mitigation"], Pct(avg.mitigation))
  end
  -- Beyond Assisted Combat, on average over the fights that have it
  local vs, vn = { differs = 0, cooldowns = 0, rotation = 0, upkeep = 0, utility = 0, extras = 0 }, 0
  for i = 1, n do
    local v = h[i].vs
    if type(v) == "table" then
      vn = vn + 1
      for k in pairs(vs) do
        vs[k] = vs[k] + (tonumber(v[k]) or 0)
      end
    end
  end
  if vn > 0 then
    for k in pairs(vs) do
      vs[k] = vs[k] / vn
    end
    vs.extras = math.floor(vs.extras + 0.5)
    lines[#lines + 1] = string.format("|cffffd100%s|r  %s", string.format(L["Average of the last %d"], vn),
      Gr.VsText(vs))
  end
  -- where to improve: the weakest part on average, with the most-missed spell of the latest fight that had one
  local weakest, low = nil, 101
  for k in pairs(Gr.WEIGHTS) do
    if avg[k] and avg[k] < low then
      weakest, low = k, avg[k]
    end
  end
  local tip = { weakest = low < 90 and weakest or nil, idle = Average(h, "idle", 1, n) or 0 }
  for i = 1, n do
    if h[i].topMissed then
      tip.topMissed, tip.topMissedCount = h[i].topMissed, h[i].topMissedCount or 1
      break
    end
  end
  lines[#lines + 1] = string.format("|cffffd100%s|r  %s", L["Where to improve"], Gr.Tip(tip))
  return lines
end

---------------------------------------------------------------------------
-- The popup
---------------------------------------------------------------------------
Gr.SHOW_SECONDS = 6
local FADE_IN, FADE_OUT = 0.15, 0.8

-- Default place: just above the three icons where you keep them (ns.Display.Home: the HUD's saved place, even
-- while the HUD itself is docked beside the settings window as a preview).
local function Place(f)
  f:ClearAllPoints()
  local pos = ns.db and type(ns.db.gradePoint) == "table" and ns.db.gradePoint
  if pos then
    f:SetPoint(pos[1] or "CENTER", UIParent, pos[2] or "CENTER", tonumber(pos[3]) or 0, tonumber(pos[4]) or 0)
  elseif ns.Game and ns.Game.On() and ns.Game.frame and ns.Game.frame:IsShown() then
    -- Flow mode: above the lanes, never over them (it sat on the lane, 2026-11-11: "doesn't look clean")
    f:SetPoint("BOTTOM", ns.Game.frame, "TOP", 0, 10)
  elseif ns.Display.Home then
    f:SetPoint("BOTTOM", ns.Display.Home(), "TOP", 0, 14)
  else
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
  end
end

function Gr.ResetPosition()
  if Gr.frame then
    Place(Gr.frame)
  end
end

-- The bar: D on the left to S+ on the right, coloured in steps; the score's marker slides along it.
Gr.BAR_FROM = 30 -- scores below this sit at the bar's left end
Gr.BAR_STOPS = { { 30, "D" }, { 50, "C" }, { 64, "B" }, { 80, "A" }, { 91, "S" }, { 100, "S+" } }
-- PAD: the margin inside the box (2026-11-10: the letter sat too close to the top and side)
local PAD = 14
local W, BAR_W, BAR_H = 340 + 2 * PAD, 300, 10
local H_TIP = 196 + 2 * PAD
local PARTS = { { "accuracy", "Accuracy" }, { "abc", "Always casting" }, { "reaction", "Reaction" },
  { "cooldowns", "Cooldowns" }, { "mitigation", "Mitigation" } }

local function BarX(score)
  return (math.max(Gr.BAR_FROM, math.min(100, score)) - Gr.BAR_FROM) / (100 - Gr.BAR_FROM) * BAR_W
end

local function Shade(v) -- a part's colour: red (0) to amber to green (100)
  if not v then
    return 0.6, 0.6, 0.6
  end
  if v >= 85 then
    return 0.35, 0.9, 0.4
  elseif v >= 65 then
    return 1, 0.82, 0.25
  end
  return 1, 0.4, 0.35
end

-- The letter: the game's damage-number font (Skurri on English clients: heavy, slanted, made to pop; each
-- language's own damage font elsewhere, so the letter always renders), thick outline. Chosen 2026-11-09.
Gr.LETTER_SIZE = 80
local function LetterFont(fs, size)
  local face = _G.DAMAGE_TEXT_FONT or "Fonts\\SKURRI.TTF"
  if not (fs.SetFont and fs:SetFont(face, size, "THICKOUTLINE")) then
    ns.Display.SetFont(fs, size)
  end
end

local function Frame()
  if Gr.frame then
    return Gr.frame
  end
  local f = CreateFrame("Frame", "DMGAssistGrade", UIParent)
  f:SetSize(W, H_TIP)
  f:SetFrameStrata("HIGH")
  Place(f)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self)
    if (ns.db and ns.db.locked == false) or (ns.Integrations and ns.Integrations.editMode) then
      self:StartMoving()
    end
  end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p1, _, p2, x, y = self:GetPoint()
    if ns.db then
      ns.db.gradePoint = { p1, p2, x, y }
    end
  end)
  -- a dark panel, lighter at the top
  f.bg = f:CreateTexture(nil, "BACKGROUND")
  f.bg:SetAllPoints()
  f.bg:SetColorTexture(0.05, 0.05, 0.07, 0.82)
  f.edge = f:CreateTexture(nil, "BORDER")
  f.edge:SetPoint("TOPLEFT")
  f.edge:SetPoint("TOPRIGHT")
  f.edge:SetHeight(2)
  -- the letter and the title
  f.letter = f:CreateFontString(nil, "OVERLAY")
  f.letter:SetPoint("CENTER", f, "TOPLEFT", 50 + PAD, -38 - PAD)
  f.title = f:CreateFontString(nil, "OVERLAY")
  f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 104 + PAD, -14 - PAD)
  f.score = f:CreateFontString(nil, "OVERLAY")
  f.score:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -9)
  f.best = f:CreateFontString(nil, "OVERLAY")
  f.best:SetPoint("LEFT", f.score, "RIGHT", 14, 0)
  -- the bar
  f.bar = CreateFrame("Frame", nil, f)
  f.bar:SetSize(BAR_W, BAR_H)
  f.bar:SetPoint("TOP", f, "TOP", 0, -88 - PAD)
  f.segments = {}
  for i = 1, #Gr.BAR_STOPS - 1 do
    local a, b = Gr.BAR_STOPS[i], Gr.BAR_STOPS[i + 1]
    local seg = f.bar:CreateTexture(nil, "ARTWORK")
    seg:SetPoint("LEFT", f.bar, "LEFT", BarX(a[1]), 0)
    seg:SetSize(math.max(1, BarX(b[1]) - BarX(a[1])), BAR_H)
    local c1, c2 = Gr.COLORS[a[2]] or Gr.COLORS.D, Gr.COLORS[b[2]] or Gr.COLORS.D
    seg:SetColorTexture(1, 1, 1, 1)
    if seg.SetGradient and CreateColor then
      seg:SetGradient("HORIZONTAL", CreateColor(c1[1], c1[2], c1[3], 0.9), CreateColor(c2[1], c2[2], c2[3], 0.9))
    else
      seg:SetVertexColor(c1[1], c1[2], c1[3], 0.9)
    end
    f.segments[i] = seg
    local tick = f.bar:CreateFontString(nil, "OVERLAY")
    tick:SetPoint("TOP", f.bar, "BOTTOMLEFT", BarX(b[1]) - (i == #Gr.BAR_STOPS - 1 and 6 or 0), -2)
    ns.Display.SetFont(tick, 10) -- a font before any text
    tick:SetTextColor(0.8, 0.8, 0.8)
    tick:SetText(b[2])
  end
  f.marker = f.bar:CreateTexture(nil, "OVERLAY")
  f.marker:SetSize(3, BAR_H + 8)
  f.marker:SetColorTexture(1, 1, 1, 1)
  -- the parts: value on top, name under it
  f.cells = {}
  for i, part in ipairs(PARTS) do
    local cell = CreateFrame("Frame", nil, f)
    cell:SetSize((W - 2 * PAD) / #PARTS, 36)
    cell:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + (i - 1) * (W - 2 * PAD) / #PARTS, -116 - PAD)
    cell.value = cell:CreateFontString(nil, "OVERLAY")
    cell.value:SetPoint("TOP", cell, "TOP", 0, 0)
    cell.name = cell:CreateFontString(nil, "OVERLAY")
    cell.name:SetPoint("TOP", cell.value, "BOTTOM", 0, -2)
    cell.key = part[1]
    cell.label = part[2]
    f.cells[i] = cell
  end
  -- Flow mode's line: its own row the box's width (beside the score it ran out of the box, 2026-11-11)
  f.flow = f:CreateFontString(nil, "OVERLAY")
  f.flow:SetJustifyH("LEFT")
  f.vsLine = f:CreateFontString(nil, "OVERLAY")
  f.vsLine:SetWidth(W - 24 - 2 * PAD)
  f.vsLine:SetJustifyH("LEFT")
  f.tip = f:CreateFontString(nil, "OVERLAY")
  f.tip:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12 + PAD, 10 + PAD) -- inside the box, at the bottom
  f.tip:SetWidth(W - 24 - 2 * PAD)
  f.tip:SetJustifyH("LEFT")
  f:Hide()
  f:SetScript("OnUpdate", function(self)
    local t = GetTime() - (self.shownAt or 0)
    -- the pop: the letter lands big, overshoots a little smaller, settles (0.35 s); the marker sweeps the bar
    if self.letterSize and self.letter and t < 0.4 then
      local k
      if t < 0.15 then
        k = 1.7 - 0.8 * (t / 0.15) -- 1.7 -> 0.9
      elseif t < 0.3 then
        k = 0.9 + 0.1 * ((t - 0.15) / 0.15) -- 0.9 -> 1.0
      else
        k = 1
      end
      local size = math.floor(self.letterSize * k + 0.5)
      if size ~= self.lastLetterSize then
        self.lastLetterSize = size
        LetterFont(self.letter, size)
      end
    end
    if self.markerTo then
      self.marker:SetPoint("CENTER", self.bar, "LEFT", self.markerTo * math.min(1, t / 0.6), 0)
    end
    if self.sample then
      self:SetAlpha(1)
      return
    end
    local hold = tonumber(ns.db and ns.db.gradeSeconds) or Gr.SHOW_SECONDS
    if t < FADE_IN then
      self:SetAlpha(t / FADE_IN)
    elseif t < FADE_IN + hold then
      self:SetAlpha(1)
    elseif t < FADE_IN + hold + FADE_OUT then
      self:SetAlpha(1 - (t - FADE_IN - hold) / FADE_OUT)
    else
      self:Hide()
    end
  end)
  Gr.frame = f
  return f
end

function Gr.Render(r, sample, test)
  local f = Frame()
  if not (ns.db and type(ns.db.gradePoint) == "table") then
    Place(f) -- follows the icons when they move
  end
  local D = ns.Display
  local c = Gr.COLORS[r.letter] or Gr.COLORS.D
  f.letterSize, f.lastLetterSize = Gr.LETTER_SIZE, nil
  LetterFont(f.letter, Gr.LETTER_SIZE)
  f.letter:SetShadowOffset(3, -3)
  f.letter:SetShadowColor(0, 0, 0, 0.9)
  f.letter:SetText(r.letter)
  f.letter:SetTextColor(c[1], c[2], c[3])
  f.edge:SetColorTexture(c[1], c[2], c[3], 0.9)
  D.SetFont(f.title, 14)
  f.title:SetText(L["Fight grade"])
  f.title:SetTextColor(0.85, 0.85, 0.85)
  D.SetFont(f.score, 20)
  f.score:SetText(string.format("%.1f", r.score))
  f.score:SetTextColor(1, 1, 1)
  D.SetFont(f.best, 14)
  f.best:SetText(r.newBest and L["New best!"] or "")
  local flow = r.game and (string.format(L["Flow score %d, best streak %d, %d%% perfect"], r.game.score,
    r.game.bestStreak, r.game.perfect) .. (r.game.newBest and (" " .. L["(new high score)"]) or "")) or nil
  f.best:SetTextColor(1, 0.82, 0.1)
  -- Settings > Performance grade: the box's opacity, the size, and which parts show (the box re-flows to fit)
  local db = ns.db or {}
  local bgA = (tonumber(db.gradeBg) or 82) / 100
  f.bg:SetColorTexture(0.05, 0.05, 0.07, bgA)
  f.edge:SetAlpha(bgA > 0 and 1 or 0)
  f:SetScale(math.max(0.5, math.min(1.5, (tonumber(db.gradeScale) or 100) / 100)))
  local showBar, showParts = db.gradeBar ~= false, db.gradeParts ~= false
  local y = 88 + PAD
  f.flow:ClearAllPoints()
  f.flow:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(y - 10))
  f.flow:SetWidth(W - 2 * PAD)
  if f.flow.SetWordWrap then
    f.flow:SetWordWrap(true)
  end
  D.SetFont(f.flow, 12)
  f.flow:SetText(flow or "")
  f.flow:SetTextColor(1, 0.82, 0.1)
  f.flow:SetShown(flow ~= nil)
  if flow then
    y = y + 26 -- room for two lines
  end
  f.bar:ClearAllPoints()
  f.bar:SetPoint("TOP", f, "TOP", 0, -y)
  f.bar:SetShown(showBar)
  if showBar then
    y = y + 28
  end
  f.partsY = y
  if showParts then
    y = y + 44
  end
  local vsText = db.gradeVs ~= false and Gr.VsText(r.vs) or nil
  f.vsLine:ClearAllPoints()
  f.vsLine:SetPoint("TOPLEFT", f, "TOPLEFT", 12 + PAD, -y)
  D.SetFont(f.vsLine, 11)
  f.vsLine:SetText(vsText or "")
  f.vsLine:SetTextColor(0.55, 0.8, 1)
  f.vsLine:SetShown(vsText ~= nil)
  if vsText then
    y = y + 30 -- room for two lines
  end
  f.contentH = y
  f.markerTo = BarX(r.score)
  f.marker:SetPoint("CENTER", f.bar, "LEFT", 0, 0)
  -- the grid: the parts this fight has (Mitigation only for tanks), spread over the width
  local shown = {}
  for _, cell in ipairs(f.cells) do
    if showParts and (cell.key ~= "mitigation" or r.mitigation ~= nil) then
      shown[#shown + 1] = cell
      cell:Show()
    else
      cell:Hide()
    end
  end
  for i, cell in ipairs(shown) do
    cell:ClearAllPoints()
    cell:SetSize((W - 2 * PAD) / #shown, 36)
    cell:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + (i - 1) * (W - 2 * PAD) / #shown, -f.partsY)
  end
  for _, cell in ipairs(shown) do
    local v = r[cell.key]
    D.SetFont(cell.value, 18)
    if cell.key == "reaction" then
      cell.value:SetText(r.reactionMs and (r.reactionMs .. " ms") or "-")
    else
      cell.value:SetText(Pct(v))
    end
    cell.value:SetTextColor(Shade(v))
    D.SetFont(cell.name, 10)
    cell.name:SetText(L[cell.label])
    cell.name:SetTextColor(0.75, 0.75, 0.75)
  end
  D.SetFont(f.tip, 11)
  f.tip:SetText(Gr.TipsOn() and Gr.Tip(r) or "")
  f:SetHeight(f.contentH + PAD + (Gr.TipsOn() and 36 or 4)) -- the box ends under what shows
  f.tip:SetTextColor(0.9, 0.9, 0.9)
  f.sample = sample
  f.shownAt = GetTime()
  f:EnableMouse((ns.db and ns.db.locked == false) or (ns.Integrations and ns.Integrations.editMode) or false)
  f:SetAlpha(sample and 1 or 0)
  f:Show()
  if not (sample or test) then
    Gr.last = r
  end
end

function Gr.Show(r)
  Gr.Render(r, false)
end

-- Settings button: the sample, popping up and fading like a real grade.
function Gr.Test()
  Gr.Render(Gr.SAMPLE, false, true)
end

Gr.SAMPLE = { score = 93.4, letter = "S", accuracy = 96, abc = 91, reaction = 88, reactionMs = 245, cooldowns = 95,
  weakest = "reaction", idle = 3.2,
  vs = { differs = 27, same = 73, cooldowns = 15, rotation = 10, upkeep = 2, utility = 0, extras = 9 } }

-- In Edit Mode, while unlocked or on the grade's settings page: a sample to place and size it.
function Gr.ShowSample(on)
  if on then
    Gr.Render(Gr.SAMPLE, true)
  elseif Gr.frame and Gr.frame.sample then
    Gr.frame.sample = false
    Gr.frame:Hide()
  end
end

-- The sample shows while the grade can be placed: in Edit Mode or with the HUD unlocked.
function Gr.SyncSample()
  local I = ns.Integrations
  local on = Gr.Enabled() and ((ns.db and ns.db.locked == false) or (I and I.editMode)) or false
  if on then
    Gr.ShowSample(true)
  elseif Gr.frame and Gr.frame.sample then
    Gr.ShowSample(false)
  end
end
