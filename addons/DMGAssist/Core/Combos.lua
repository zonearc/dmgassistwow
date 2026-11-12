-- Combos.lua: short chains a spec plays right after a cooldown (decided 2026-11-12: "a 2-4 queue cluster of
-- abilities becomes a combo ... when you complete them it gives you a cool COMBO announcement and a unique flash",
-- a small achievement of its own, not more streak). Flow mode only.
--
-- The chain is what the rotation shows (SimC's order): when slot 1 is a cooldown (a major one, or any spell with a
-- cooldown of COOLDOWN seconds or more) and slots 2-3 hold what comes after it, those notes are linked in the lane
-- (violet edges and a line between them) before you get there. The chains mined from long simulated fights
-- (tools/mine_combos.lua -> Data/Combos.lua) are kept for when the queue is too short to show one: in game they
-- didn't match real play well (Elemental's Nature's Swiftness was never followed by Stormkeeper, 2026-11-12), so the
-- queue comes first.
--
-- Following one: pressing the cooldown starts it; each next spell of the chain moves it on; a spell off the global
-- cooldown or one that isn't in the spec's lists (the game's own follow-up casts: Elemental logged 451368 / 464059
-- after its spells) is ignored; any other spell, or WINDOW seconds without the next one, quietly ends it. Finishing
-- it calls Game.OnCombo: COMBO! with its own sweep and bonus points.

local _, ns = ...

local C = {}
ns.Combos = C

C.WINDOW = 6 -- seconds allowed between two spells of a chain
C.COOLDOWN = 30 -- a spell with at least this cooldown can start a chain

local function Base(id)
  local baseOf = ns.SpellMap and ns.SpellMap.baseOf or {}
  return baseOf[id] or id
end

-- this spec's mined chains, each { ids... } with the cooldown first
function C.Chains()
  local cur = ns.Specs and ns.Specs.current
  local data = ns.COMBO_DATA
  return cur and cur.key and data and data[cur.key] or {}
end

local function Info(id)
  return ns.SpellMap and ns.SpellMap.Info and ns.SpellMap.Info(id)
end

local function OffGCD(id)
  local info = Info(id)
  return info ~= nil and tonumber(info.gcd) == 0
end

-- not one of the spec's spells: a cast the game makes by itself after another
local function Unlisted(id)
  local M = ns.SpellMap
  return M and M.TokenForID and M.TokenForID(id) == nil
end

-- A pick that can start a chain: a major cooldown, or a spell with a long cooldown.
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

-- The chain the lane shows now (Game.lua links these notes): the run in progress, else slot 1's cooldown and what
-- follows it in slots 2-3. Returns the ids, the cooldown first, and how many are already done.
function C.Planned(queue)
  local run = C.run
  if run and GetTime() - run.at <= C.WINDOW then
    return run.chain, run.step
  end
  local q1 = queue and queue[1]
  if not C.IsStarter(q1) then
    C.pending = nil
    return nil
  end
  local chain = { q1.id }
  for i = 2, 3 do
    local p = queue[i]
    if p and p.id and not p.item and not C.IsStarter(p) then
      chain[#chain + 1] = p.id
    else
      break
    end
  end
  if #chain < 2 then
    -- the queue shows nothing after it: a mined chain for this cooldown, if there is one
    for _, mined in ipairs(C.Chains()) do
      if Base(mined[1]) == Base(q1.id) then
        chain = mined
        break
      end
    end
  end
  if #chain < 2 then
    C.pending = nil
    return nil
  end
  C.pending = chain
  return chain, 0
end

-- Our own cast, in combat (Main.lua): starts a chain, moves it on, finishes it, or ends it.
function C.OnCast(id, now)
  if type(id) ~= "number" then
    return nil
  end
  now = now or GetTime()
  id = Base(id)
  local run = C.run
  if run and now - run.at > C.WINDOW then
    run = nil
  end
  if run then
    local want = run.chain[run.step + 1]
    if want and id == Base(want) then
      run.step, run.at = run.step + 1, now
      if run.step >= #run.chain then
        C.run = nil
        if ns.Game and ns.Game.OnCombo then
          ns.Game.OnCombo(#run.chain)
        end
        return "done"
      end
      C.run = run
      if ns.Game and ns.Game.OnComboStep then
        ns.Game.OnComboStep(run.step, #run.chain)
      end
      return "step"
    elseif OffGCD(id) or Unlisted(id) then
      C.run = run
      return nil
    end
  end
  C.run = nil
  local candidates = {}
  if C.pending then
    candidates[1] = C.pending
  end
  for _, chain in ipairs(C.Chains()) do
    candidates[#candidates + 1] = chain
  end
  for _, chain in ipairs(candidates) do
    if Base(chain[1]) == id then
      C.run = { chain = chain, step = 1, at = now }
      C.pending = nil
      if ns.Game and ns.Game.OnComboStep then
        ns.Game.OnComboStep(1, #chain)
      end
      return "start"
    end
  end
  return nil
end

function C.Reset()
  C.run, C.pending = nil, nil
end
