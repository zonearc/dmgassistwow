-- Combos.lua: short chains a spec casts right after a major cooldown (decided 2026-11-12: "a 2-4 queue cluster
-- of abilities becomes a combo ... when you complete them it gives you a cool COMBO announcement and a unique
-- flash", a small achievement of its own, not more streak). The chains are found per spec by tools/mine_combos.lua
-- (long simulated fights through the real pipeline) and kept in Data/Combos.lua (ns.COMBO_DATA).
--
-- Following one: the cooldown starts it; each next spell of the chain moves it on; a spell off the global cooldown
-- (Ironfur, a trinket) is ignored; any other spell, or WINDOW seconds without the next one, quietly ends it.
-- Finishing it calls Game.OnCombo (Flow mode): COMBO! with its own flash and bonus points. Classic shows nothing.

local _, ns = ...

local C = {}
ns.Combos = C

C.WINDOW = 6 -- seconds allowed between two spells of a chain

local function Base(id)
  local baseOf = ns.SpellMap and ns.SpellMap.baseOf or {}
  return baseOf[id] or id
end

-- this spec's chains, each { ids... } with the cooldown first
function C.Chains()
  local cur = ns.Specs and ns.Specs.current
  local data = ns.COMBO_DATA
  return cur and cur.key and data and data[cur.key] or {}
end

local function OffGCD(id)
  local info = ns.SpellMap and ns.SpellMap.Info and ns.SpellMap.Info(id)
  return info ~= nil and tonumber(info.gcd) == 0
end

-- Our own cast, in combat (Main.lua): moves a chain on, finishes it, or ends it.
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
    elseif OffGCD(id) then
      C.run = run
      return nil
    end
  end
  C.run = nil
  for _, chain in ipairs(C.Chains()) do
    if Base(chain[1]) == id then
      C.run = { chain = chain, step = 1, at = now }
      if ns.Game and ns.Game.OnComboStep then
        ns.Game.OnComboStep(1, #chain)
      end
      return "start"
    end
  end
  return nil
end

function C.Reset()
  C.run = nil
end
