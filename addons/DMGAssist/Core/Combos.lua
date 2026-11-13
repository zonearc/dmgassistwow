-- Combos.lua: a short run of presses the lane links together, Flow mode only (decided 2026-11-12: "a 2-4 queue
-- cluster of abilities becomes a combo ... when you complete them it gives you a cool COMBO announcement and a
-- unique flash", a small achievement of its own, not more streak).
--
-- Rules (the owner, 2026-11-12):
--   * it follows the lane: the linked notes are always the next ones the lane shows, and each press is judged the
--     way the streak is (Game.OnJudged): any hit moves the combo on - slot 1, slot 2 / 3, or the spell the addon
--     switched to a moment before the press - so a switch never costs the combo when it doesn't cost the streak;
--     only a miss (or a pause of WINDOW seconds) ends it;
--   * LENGTH presses (MAX_LENGTH when it starts on a major cooldown), never more;
--   * never back to back: GAP seconds at least after the last one;
--   * at least one every minute or so: DUE seconds without one and any spell in the box can start one, not only a
--     cooldown; the first of a fight already FIRST_DUE seconds after the pull (once the warm-up is done);
--   * never at the very start of a fight: WARMUP presses first, so you're settled before one is put in front of you.
-- A cooldown in slot 1 (a major one, or any spell with a cooldown of COOLDOWN s or more) starts one when the rules
-- allow. The chains mined from simulated fights (tools/mine_combos.lua, Data/Combos.lua) are no longer used for the
-- order: in game they didn't match real play (Elemental's Nature's Swiftness was never followed by Stormkeeper).
-- Finishing one calls Game.OnCombo: COMBO! with its own sweep and bonus points.

local _, ns = ...

local C = {}
ns.Combos = C

C.WINDOW = 6       -- seconds allowed between two presses of a combo
C.COOLDOWN = 30    -- a spell with at least this cooldown can start one
C.LENGTH, C.MAX_LENGTH = 3, 4
C.GAP = 15         -- seconds after the last combo before the next can start
C.DUE = 45         -- seconds without one: any spell in the box can start the next
C.FIRST_DUE = 15   -- the first of a fight comes sooner (Warrior: one only near the end of a dummy fight, 2026-11-13)
C.WARMUP = 5       -- presses into a fight before the first

local function Info(id)
  return ns.SpellMap and ns.SpellMap.Info and ns.SpellMap.Info(id)
end

local function Base(id)
  local baseOf = ns.SpellMap and ns.SpellMap.baseOf or {}
  return baseOf[id] or id
end

-- A pick that can start a combo on its own: a major cooldown, or a spell with a long cooldown.
function C.IsStarter(p)
  if not (p and p.id) or p.item then
    return false
  end
  if p.major or (ns.Grade and ns.Grade.IsCooldown and ns.Grade.IsCooldown(p)) then
    return true
  end
  local info = Info(p.id)
  return info ~= nil and (tonumber(info.cd) or 0) >= C.COOLDOWN
end

-- A new fight: the warm-up starts over (Main.lua / Game on combat start).
function C.OnFightStart(now)
  C.fightPresses = 0
  C.run, C.pending, C.lastAt = nil, nil, nil
  C.fightAt = now or GetTime() -- "due" counts from the pull until the first combo
end

-- May one start now? (not running, the warm-up done, not too soon after the last)
function C.CanStart(now)
  if C.run then
    return false
  end
  if (C.fightPresses or 0) < C.WARMUP then
    return false
  end
  return not C.lastAt or now - C.lastAt >= C.GAP
end

-- The combo the lane shows now (Game.lua links these notes, slot 1 first): returns the ids to link, how many
-- presses are done and the combo's length.
function C.Planned(queue)
  local now = GetTime()
  local run = C.run
  if run and now - run.at > C.WINDOW then
    C.End(now)
    run = nil
  end
  local ids = {}
  if run then
    for i = 1, 3 do
      local p = queue and queue[i]
      if not (p and p.id) or p.item or #ids >= run.total - run.step then
        break
      end
      ids[#ids + 1] = p.id
    end
    return ids, run.step, run.total
  end
  C.pending = nil
  local q1 = queue and queue[1]
  if not (q1 and q1.id) or q1.item or not C.CanStart(now) then
    return nil
  end
  local starter = C.IsStarter(q1)
  local since = C.lastAt or C.fightAt
  local due = since ~= nil and now - since >= (C.lastAt and C.DUE or C.FIRST_DUE)
  if not starter and not due then
    return nil
  end
  local total = (q1.major and C.MAX_LENGTH) or C.LENGTH
  for i = 1, math.min(3, total) do
    local p = queue[i]
    if p and p.id and not p.item then
      ids[#ids + 1] = p.id
    else
      break
    end
  end
  C.pending = { starter = q1.id, total = total }
  return ids, 0, total
end

-- A combo ended (finished or not): the gap to the next starts now.
function C.End(now)
  C.run = nil
  C.lastAt = now or GetTime()
end

-- Each press Flow judges (Game.OnJudged), the same judgement as the streak: "hit" / "near" move a combo on (or start
-- the pending one when it's the shown spell or the one it was switched from), "miss" ends it.
function C.OnJudged(kind, id, now)
  now = now or GetTime()
  if kind == "miss" then
    if C.run then
      C.End(now)
    end
    return "broken"
  end
  C.fightPresses = (C.fightPresses or 0) + 1
  local run = C.run
  if run and now - run.at > C.WINDOW then
    C.End(now)
    run = nil
  end
  if run then
    run.step, run.at = run.step + 1, now
    if run.step >= run.total then
      C.End(now)
      if ns.Game and ns.Game.OnCombo then
        ns.Game.OnCombo(run.total)
      end
      return "done"
    end
    if ns.Game and ns.Game.OnComboStep then
      ns.Game.OnComboStep(run.step, run.total)
    end
    return "step"
  end
  local pending = C.pending
  if pending and type(id) == "number" and C.CanStart(now) then
    -- any hit while the combo's first note is the one in the box counts, so a switch at the last moment (the
    -- streak's "hit" for the spell shown a moment before) starts it too
    C.run = { step = 1, total = pending.total, at = now, starter = Base(pending.starter) }
    C.pending = nil
    if ns.Game and ns.Game.OnComboStep then
      ns.Game.OnComboStep(1, pending.total)
    end
    return "start"
  end
  return nil
end

function C.Reset()
  C.run, C.pending, C.lastAt, C.fightAt, C.fightPresses = nil, nil, nil, nil, 0
end
