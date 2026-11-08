-- Essentials.lua: things a priority list does not cover but a player needs, put in slot 1 ahead of the rotation
-- (interrupts and defensives still come first).
--
-- Keep-ups (tanks): SimC simulates damage, not survival or threat, so it spends Rage on Ironfur only in narrow
-- cases and never Moonfires a Guardian's target without Lunation. A keep-up is a per-spec rule:
--   stacks: keep N of our own stacking buff up (Ironfur: each cast is its own 7 s stack, counted from our casts,
--           since auras are hidden in combat). N is a setting, 0 = off.
--   dot:    keep our threat DoT on the target (Blizzard's own rule for Guardian: Moonfire if it isn't ticking).
-- Gap closers (melee): out of melee range of a hostile target, the spec's targeted charge / leap / step comes first
-- while it can reach; in range it is never shown. Directional dashes are left out (they need facing and aim).

local _, ns = ...
local U = ns.U

local X = {}
ns.Essentials = X

X.KEEPUPS = {
  druid_guardian = {
    { kind = "stacks", token = "ironfur", id = 192081, setting = "ironfurStacks", duration = 7 },
    { kind = "dot", token = "moonfire", id = 8921, cond = "!dot.moonfire.ticking" },
  },
}

-- Targeted gap closers, by spellbook ID (the form / talent override is what the game casts).
X.GAP_CLOSERS = {
  102401, -- Wild Charge (druid: Bear / Cat form versions)
  100,    -- Charge (warrior)
  36554,  -- Shadowstep (rogue)
  190925, -- Harpoon (survival hunter)
  196884, -- Feral Lunge (enhancement shaman)
  49576,  -- Death Grip (death knight: brings the target to you)
}

X.stacks = {} -- spell id -> { expiry, ... } from our own casts

function X.OnOwnCast(id)
  if not id then
    return
  end
  local keep = X.KEEPUPS[ns.Specs.current and ns.Specs.current.key or ""]
  for _, k in ipairs(keep or {}) do
    if k.kind == "stacks" and (id == k.id or ns.SpellMap.baseOf[id] == k.id) then
      local info = ns.SpellMap.Info(k.id)
      local list = X.stacks[k.id] or {}
      X.stacks[k.id] = list
      list[#list + 1] = GetTime() + ((info and info.d and info.d > 0) and info.d or k.duration)
    end
  end
end

-- Our stacks that will still be up `lead` seconds from now.
function X.Stacks(id, lead)
  local list, n, now = X.stacks[id] or {}, 0, GetTime()
  for i = #list, 1, -1 do
    if list[i] <= now then
      table.remove(list, i)
    elseif list[i] > now + (lead or 0) then
      n = n + 1
    end
  end
  return n
end

function X.Reset()
  X.stacks = {}
end

local function Known(id)
  local b = ns.SpellMap.book and ns.SpellMap.book[id]
  if b and not b.passive then
    return true
  end
  return U.Get(IsPlayerSpell, id) == true
end

local function Usable(id)
  local usable = U.Read((U.Call(C_Spell and C_Spell.IsSpellUsable, id)))
  return usable == true and ns.State.CooldownReady(id) ~= false and not ns.Engine.IsHeld(id)
end

local function HostileTarget()
  return U.Get(UnitExists, "target") == true and U.Get(UnitCanAttack, "player", "target") == true
    and U.Get(UnitIsDead, "target") ~= true
end

-- The keep-up due now, or nil.
function X.KeepUp()
  local keep = X.KEEPUPS[ns.Specs.current and ns.Specs.current.key or ""]
  if not keep or not ns.State.combatStart or ns.db.tankEssentials == false then
    return nil
  end
  for _, k in ipairs(keep) do
    if Known(k.id) and Usable(k.id) then
      if k.kind == "stacks" then
        local want = tonumber(ns.db[k.setting]) or 3
        if want > 0 and X.Stacks(k.id, 0.5) < want then
          return { id = k.id, token = k.token, source = "keepup" }
        end
      elseif k.kind == "dot" and HostileTarget() then
        local S = ns.State
        local ok = ns.Expr.Test(k.cond, function(name)
          return S.Resolve(name, { vars = {} })
        end)
        if ok == true then
          return { id = k.id, token = k.token, source = "keepup" }
        end
      end
    end
  end
  return nil
end

-- The melee range check: the spec's usual spell when that is a melee spell (nil for ranged specs).
local function MeleeProbe()
  local id = ns.State.RangeProbe and ns.State.RangeProbe()
  local info = id and ns.SpellMap.Info(id)
  if info and info.r and info.r <= 8 then
    return id
  end
  return nil
end

function X.GapCloser()
  if ns.db.gapClosers == false or not HostileTarget() then
    return nil
  end
  local probe = MeleeProbe()
  if not probe then
    return nil
  end
  local inMelee = U.Get(C_Spell and C_Spell.IsSpellInRange, probe, "target")
  if inMelee ~= false then
    return nil -- in range, or the game won't say
  end
  for _, id in ipairs(X.GAP_CLOSERS) do
    if Known(id) and Usable(id) and U.Get(C_Spell and C_Spell.IsSpellInRange, id, "target") == true then
      return { id = id, token = "gap_closer", source = "gapcloser" }
    end
  end
  return nil
end

local function Front(result, pick)
  local queue = { pick }
  for _, p in ipairs(result.queue or {}) do
    if p.id ~= pick.id and #queue < 3 then
      queue[#queue + 1] = p
    end
  end
  result.queue, result.main = queue, pick
  result.branch = nil
end

function X.Apply(result)
  if not result then
    return result
  end
  local keep = X.KeepUp()
  if keep then
    Front(result, keep)
  end
  local gap = X.GapCloser()
  if gap then
    Front(result, gap)
  end
  return result
end
