-- Trinkets.lua: on-use trinkets (inventory slots 13 and 14).
--
-- Found from what is equipped: a trinket with a use spell (C_Item.GetItemSpell) is an on-use trinket. Read again
-- on every decision, so a gear change is picked up at once.
-- Every equipped on-use trinket counts by default; each can be switched off (Settings > DMGAssist > Trinkets) to
-- press it yourself, and a master switch turns all of it off.
-- When: in combat, at a hostile target, when major cooldowns are allowed (the same "Use cooldowns on" setting),
-- off cooldown, and when the spec's SimC list does not say "not now" (its use_items / use_item lines are checked
-- by the engine; an unknown answer counts as yes).
-- Shown as the off-GCD badge on slot 1 when that is free (trinkets don't use the GCD), otherwise in slot 2.

local _, ns = ...
local U = ns.U

local T = {}
ns.Trinkets = T

T.SLOTS = { 13, 14 }
T.used = {}  -- slot -> time we last used it
T.cd = {}    -- slot -> cooldown length learned from the game
T.ASSUMED_CD = 120

local function Read(...)
  return U.Read((U.Call(...)))
end

-- "Mirror of Fractured Tomorrows" -> "mirror_of_fractured_tomorrows" (SimC's item names).
function T.Token(name)
  if type(name) ~= "string" then
    return nil
  end
  return (name:lower():gsub("[',%.:]", ""):gsub("%-", "_"):gsub("%s+", "_"))
end

-- { slot, item, spell, name, texture } for an on-use trinket in this slot, or nil.
function T.Info(slot)
  local item = Read(GetInventoryItemID, "player", slot)
  if type(item) ~= "number" then
    return nil
  end
  local spellName, spell
  if C_Item and C_Item.GetItemSpell then
    spellName, spell = U.Call(C_Item.GetItemSpell, item)
  elseif GetItemSpell then
    spellName, spell = U.Call(GetItemSpell, item)
  end
  spellName, spell = U.Read(spellName), U.Read(spell)
  if type(spell) ~= "number" then
    return nil -- no use effect
  end
  local name = (C_Item and C_Item.GetItemNameByID and Read(C_Item.GetItemNameByID, item))
    or (GetItemInfo and Read(GetItemInfo, item)) or spellName
  local texture = Read(GetInventoryItemTexture, "player", slot)
  return { slot = slot, item = item, spell = spell, name = name, texture = texture }
end

function T.List()
  local out = {}
  for _, slot in ipairs(T.SLOTS) do
    local info = T.Info(slot)
    if info then
      out[#out + 1] = info
    end
  end
  return out
end

-- Every equipped on-use trinket is used unless the player switched that trinket off (by item, so the choice
-- follows the trinket through gear sets and spec swaps: "I press this one myself").
function T.IsOff(item)
  local off = ns.db and ns.db.trinketOff
  return type(off) == "table" and off[item] == true
end

function T.SetOff(item, off)
  if not ns.db then
    return
  end
  ns.db.trinketOff = type(ns.db.trinketOff) == "table" and ns.db.trinketOff or {}
  ns.db.trinketOff[item] = off and true or nil
end

function T.Enabled(info)
  if not info or (ns.db and ns.db.trinkets == false) then
    return false
  end
  return not T.IsOff(info.item)
end

-- Off cooldown? From the game when it says; else from our own use and the length learned out of combat.
function T.Ready(info)
  local start, duration, enable = U.Call(GetInventoryItemCooldown, "player", info.slot)
  start, duration, enable = U.Read(start), U.Read(duration), U.Read(enable)
  if type(start) == "number" and type(duration) == "number" then
    if duration > 1.5 then
      T.cd[info.slot] = duration
    end
    if enable == 0 or enable == false then
      return false -- its effect is still running ("cooldown starts when the effect ends")
    end
    return start == 0 or duration <= 1.5 or start + duration - GetTime() <= 0.1
  end
  local last = T.used[info.slot]
  if not last then
    return true
  end
  return GetTime() - last >= (T.cd[info.slot] or T.ASSUMED_CD)
end

local function Usable(info)
  local f = (C_Item and C_Item.IsUsableItem) or IsUsableItem
  if not f then
    return true
  end
  return U.Read((U.Call(f, info.item))) ~= false
end

-- What the SimC list said about using items this decision (Engine records use_items / use_item lines).
function T.SimcAllows(result, info)
  local u = result and result.useItems
  if not u then
    return true
  end
  local keys = { "trinket" .. (info.slot - 12), "name:" .. tostring(T.Token(info.name)), "all" }
  for _, k in ipairs(keys) do
    local v = u[k]
    if v ~= nil then
      return v ~= false
    end
  end
  return true
end

local function HostileTarget()
  return U.Get(UnitExists, "target") == true and U.Get(UnitCanAttack, "player", "target") == true
    and U.Get(UnitIsDead, "target") ~= true
end

-- The trinket to use now, or nil.
function T.Pick(result)
  if (ns.db and ns.db.trinkets == false) or not ns.State.combatStart or not HostileTarget() then
    return nil
  end
  if ns.BurstAllowed and not ns.BurstAllowed() then
    return nil
  end
  for _, info in ipairs(T.List()) do
    if T.Enabled(info) and T.Ready(info) and Usable(info) and T.SimcAllows(result, info) then
      return { id = info.spell, item = info.item, slot = info.slot, texture = info.texture,
        token = "trinket" .. (info.slot - 12), source = "trinket", weave = true }
    end
  end
  return nil
end

function T.Apply(result)
  if not (result and result.main) then
    return result
  end
  local pick = T.Pick(result)
  if not pick then
    return result
  end
  if not result.weave then
    result.weave = pick
  else
    local queue = { result.main, pick }
    for i = 2, #(result.queue or {}) do
      if #queue < 3 then
        queue[#queue + 1] = result.queue[i]
      end
    end
    result.queue = queue
  end
  return result
end

-- Our own cast of a trinket's use spell (UNIT_SPELLCAST_SUCCEEDED).
function T.OnOwnCast(id)
  for _, slot in ipairs(T.SLOTS) do
    local info = T.Info(slot)
    if info and info.spell == id then
      T.used[slot] = GetTime()
    end
  end
end
