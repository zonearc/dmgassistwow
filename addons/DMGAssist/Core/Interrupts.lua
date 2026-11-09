-- Interrupts.lua: when to put our interrupt in slot 1.
--
-- Policy (DMGAssistDB.interruptMode, Options > Combat):
--   "off"        never
--   "smart"      (default) open world: any interruptible cast. Dungeons/raids: only casts that matter —
--                the boss mod (DBM / BigWigs / LittleWigs) calls an interrupt, or Blizzard marks the spell
--                important (C_Spell.IsSpellImportant: "lethal if not interrupted").
--   "everywhere" any interruptible cast, anywhere
--   "instances"  any interruptible cast, only in dungeons and raids
--   "bossmods"   only when the boss mod calls an interrupt (nothing in the open world)
--
-- In combat "interruptible" and "important" are usually secret. Then we can't decide, but we can let the game
-- render it: the interrupt is drawn over slot 1 and its alpha comes from those secret booleans (nested frames
-- multiply alpha = logical AND). When the facts are readable, or the boss mod said so, it is a real decision:
-- the interrupt becomes slot 1 and the rest of the queue shifts right.
--
-- Pressed: the interrupt's cooldown starts -> gone. Skipped: the player cast something else while it was shown ->
-- hidden until the target starts its next cast (UNIT_SPELLCAST_START/CHANNEL_START on "target" fire even when
-- their payload is secret) or the target changes.

local _, ns = ...
local U = ns.U

local I = {}
ns.Interrupts = I

I.MODES = { "smart", "everywhere", "instances", "bossmods", "off" }

I.skipped = false
I.shown = false
I.stats = { shown = 0, used = 0, skipped = 0 }

function I.Mode()
  local m = ns.db and ns.db.interruptMode
  if m == nil then
    return "smart"
  end
  return m
end

local function InInstance()
  local inside, kind = U.Call(IsInInstance)
  inside, kind = U.Read(inside), U.Read(kind)
  return inside == true and (kind == "party" or kind == "raid" or kind == "scenario")
end

-- The decision for this tick. Returns nil, or { id =, how = "decided" | "render", needImportant = bool, why = }.
function I.Evaluate()
  local mode = I.Mode()
  if mode == "off" then
    return nil
  end
  local id = ns.Display.InterruptSpell()
  if not id or ns.State.CooldownReady(id) == false then
    return nil
  end
  if I.testUntil and GetTime() < I.testUntil then
    return { id = id, how = "decided", why = "test" } -- /dmga test interrupt (Settings > Integrations)
  end
  local casting, notInterruptible, spellID = ns.Display.TargetCast()
  if not casting or I.skipped then
    return nil
  end
  local instance = InInstance()
  local bossCall = ns.BossMods.Alert("interrupt") ~= nil
  if mode == "instances" and not instance then
    return nil
  end
  if mode == "bossmods" and not bossCall then
    return nil
  end
  local needImportant = mode == "smart" and instance and not bossCall
  -- Readable facts: decide here.
  local niSecret = U.IsSecret(notInterruptible)
  local important = needImportant and spellID ~= nil and U.Call(C_Spell and C_Spell.IsSpellImportant, spellID) or nil
  local impSecret = needImportant and U.IsSecret(important)
  if not niSecret and notInterruptible == true then
    return nil
  end
  if needImportant and not impSecret and important ~= true then
    return nil
  end
  local result = { id = id, needImportant = needImportant, notInterruptible = notInterruptible,
    important = important, why = bossCall and "bossmod" or (needImportant and "important" or mode) }
  if bossCall or (not niSecret and not impSecret) then
    result.how = "decided"
  else
    result.how = "render"
  end
  return result
end

-- Put a decided interrupt at the front of the queue. Called by Main after the engine's recommendation.
function I.Apply(result)
  local intr = I.Evaluate()
  result.interrupt = intr
  if intr and not I.shown then
    I.shown = true
    I.stats.shown = I.stats.shown + 1
    U.Log("interrupt_shown", { how = intr.how, why = intr.why })
  elseif not intr then
    I.shown = false
  end
  if intr and intr.how == "decided" then
    local kick = { id = intr.id, token = "interrupt", source = "interrupt" }
    local queue = { kick }
    for i, p in ipairs(result.queue or {}) do
      if i < 3 then
        queue[#queue + 1] = p
      end
    end
    result.queue, result.main = queue, kick
    result.branch = nil
  end
  return result
end

-- Our own cast while the interrupt was up: used it, or skipped it.
function I.OnOwnCast(id)
  if not I.shown then
    return
  end
  local kick = ns.Display.InterruptSpell()
  if id == kick then
    I.stats.used = I.stats.used + 1
    U.Log("interrupt_used", {})
  else
    I.skipped = true
    I.stats.skipped = I.stats.skipped + 1
    U.Log("interrupt_skipped", { cast = id })
  end
  I.shown = false
end

-- A GCD started while the interrupt was up. Interrupts are off the GCD, so another spell was pressed — unless the
-- interrupt's own cooldown also started (checked a moment later). Works even when cast events are secret.
function I.OnGCDStarted()
  if not I.shown then
    return
  end
  local kick = ns.Display.InterruptSpell()
  C_Timer.After(0.2, function()
    if I.shown and kick and ns.State.CooldownReady(kick) ~= false then
      I.skipped = true
      I.stats.skipped = I.stats.skipped + 1
      I.shown = false
      U.Log("interrupt_skipped", { via = "gcd" })
    end
  end)
end

-- The target began a new cast (or we changed target): a new chance to interrupt.
function I.OnTargetCastStart()
  I.skipped = false
end
