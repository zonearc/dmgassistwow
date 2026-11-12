-- Trinkets.lua: on-use trinkets (inventory slots 13 and 14).
--
-- Found from what is equipped: a trinket with a use spell (C_Item.GetItemSpell) is an on-use trinket. Read again
-- on every decision, so a gear change is picked up at once.
-- Every equipped on-use trinket counts by default; each can be switched off (Settings > DMGAssist > Trinkets) to
-- press it yourself, and a master switch turns all of it off.
-- When: in combat, at a hostile target, when major cooldowns are allowed (the same "Use cooldowns on" setting),
-- off cooldown, and when the spec's SimC list does not say "not now" (its use_items / use_item lines are checked
-- by the engine; an unknown answer counts as yes).
-- Shown in its own badge on slot 1 (bottom-left by default; trinkets don't use the GCD), next to the off-GCD spell badge.

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

---------------------------------------------------------------------------
-- What each trinket does, for SimC's trinket questions (this_trinket.has_use_damage, trinket.1.has_buff.haste,
-- this_trinket.cooldown.duration, trinket.2.is.<name>, ...). From the game's own description of the use effect
-- ("Use: ... dealing 58035 Cosmic damage ..." / "Use: ... gain 13 Agility per stack for 20 sec. (30 Sec
-- Cooldown)"), read once per item. Before this, every such question was "no", so lists that only use a trinket
-- by what it does (Survival) never showed one (2026-11-09).
---------------------------------------------------------------------------
T.traits = {} -- item -> traits
local STATS = { agility = "agility", strength = "strength", intellect = "intellect", haste = "haste",
  ["critical strike"] = "crit", mastery = "mastery", versatility = "versatility" }

local function UseText(info)
  local text
  if C_Spell and C_Spell.GetSpellDescription then
    text = Read(C_Spell.GetSpellDescription, info.spell)
  end
  if (type(text) ~= "string" or text == "") and C_TooltipInfo and C_TooltipInfo.GetInventoryItem then
    local data = U.Read((U.Call(C_TooltipInfo.GetInventoryItem, "player", info.slot)))
    if type(data) == "table" and type(data.lines) == "table" then
      for _, line in ipairs(data.lines) do
        local t = U.Read(line.leftText)
        if type(t) == "string" and t:find("^Use:") then
          text = t
        end
      end
    end
  end
  return type(text) == "string" and text ~= "" and text or nil
end

function T.ParseUse(text)
  local low = text:lower()
  local tr = { buffs = {} }
  for word, stat in pairs(STATS) do
    if low:find("gain[^.]-" .. word) or low:find("increas[^.]-" .. word) or low:find(word .. " increased") then
      tr.buffs[stat] = true
      tr.buff = true
    end
  end
  if not tr.buff and (low:find("^gain ") or low:find(" gain ") or low:find("increases your")) then
    tr.buff = true
  end
  tr.damage = low:find("damage") ~= nil and (low:find("deal") ~= nil or low:find("inflict") ~= nil
    or low:find("damage to") ~= nil) or false
  local n, unit = low:match("%((%d+%.?%d*) (%a+) cooldown%)")
  if n then
    tr.cd = tonumber(n) * ((unit:find("^min") and 60) or (unit:find("^hour") and 3600) or 1)
  end
  local dur = low:match("for (%d+%.?%d*) sec")
  tr.duration = dur and tonumber(dur) or nil
  return tr
end

function T.Traits(slot)
  local info = T.Info(slot)
  if not info then
    return nil
  end
  local tr = T.traits[info.item]
  if tr == nil then
    local text = UseText(info)
    tr = text and T.ParseUse(text) or false -- false: unreadable for now, asked again next time
    if tr then
      tr.token = T.Token(info.name)
      T.traits[info.item] = tr
      local stats = {}
      for k in pairs(tr.buffs) do
        stats[#stats + 1] = k
      end
      table.sort(stats)
      U.Log("trinket_read", { name = tr.token, damage = tr.damage and 1 or 0, buff = tr.buff and 1 or 0,
        stats = table.concat(stats, "+"), cd = tr.cd or "?", slot = slot })
    end
  end
  return tr or nil, info
end

local function Num(v)
  return v and 1 or 0
end

-- p = the term split on dots, i = index of the field after the trinket ("has_use_buff", "is", "cooldown", ...).
function T.Term(slot, p, i)
  local UNKNOWN = ns.Expr and ns.Expr.UNKNOWN
  local item = Read(GetInventoryItemID, "player", slot)
  local f = p[i]
  if f == "is" then
    local info = T.Info(slot)
    local name = info and info.name
    if not name and type(item) == "number" then
      name = C_Item and C_Item.GetItemNameByID and Read(C_Item.GetItemNameByID, item)
    end
    if not name then
      return type(item) == "number" and UNKNOWN or 0
    end
    return Num(T.Token(name) == p[i + 1])
  end
  if f == "ilvl" then
    local lvl = type(item) == "number" and GetDetailedItemLevelInfo and Read(GetDetailedItemLevelInfo, item)
    return type(lvl) == "number" and lvl or UNKNOWN
  end
  if f == "cast_time" then
    return 0
  end
  local tr, info = T.Traits(slot)
  if not info then
    -- nothing to use in this slot (empty or a passive trinket)
    if f == "has_use_buff" or f == "has_use_damage" or f == "has_buff" or f == "has_cooldown" then
      return 0
    end
    return UNKNOWN
  end
  if f == "cooldown" then
    local g = p[i + 1] or "ready"
    local cd = (tr and tr.cd) or T.cd[slot]
    if g == "duration" then
      return cd or UNKNOWN
    end
    local ready = T.Ready(info)
    if g == "ready" or g == "up" then
      return Num(ready)
    end
    if g == "remains" then
      if ready then
        return 0
      end
      local start, duration = U.Call(GetInventoryItemCooldown, "player", slot)
      start, duration = U.Read(start), U.Read(duration)
      if type(start) == "number" and type(duration) == "number" and duration > 0 then
        return math.max(0, start + duration - GetTime())
      end
      local last = T.used[slot]
      return last and cd and math.max(0, cd - (GetTime() - last)) or UNKNOWN
    end
    return UNKNOWN
  end
  if f == "has_cooldown" then
    return Num(info ~= nil)
  end
  if not tr then
    return UNKNOWN
  end
  if f == "has_use_buff" then
    return Num(tr.buff)
  elseif f == "has_use_damage" then
    return Num(tr.damage)
  elseif f == "has_buff" or f == "has_stat" then
    local stat = p[i + 1]
    if stat == "any" or stat == "any_dps" or stat == "main_stat" or stat == "primary" then
      return Num(tr.buff)
    end
    if stat == "crit_rating" then
      stat = "crit"
    end
    return Num(tr.buffs[(stat or ""):gsub("_rating$", "")])
  elseif f == "proc" then
    if p[i + 2] == "duration" then
      return tr.duration or (tr.buff and UNKNOWN) or 0
    end
    return UNKNOWN
  end
  return UNKNOWN
end

-- this_trinket / other_trinket: the trinket a use_items line is being checked for (Engine sets T.this).
function T.ThisSlot(which)
  if not T.this then
    return nil
  end
  if which == "this_trinket" then
    return T.this
  end
  return T.this == 13 and 14 or 13
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

---------------------------------------------------------------------------
-- Potions: one you choose per spec (drag it onto the Spells, trinkets & potion page). Shown in the items icon in combat
-- when the spec's SimC list has a potion line that says now, the potion is in your bags and off cooldown.
---------------------------------------------------------------------------
local function SpecKey()
  return ns.Specs.current and ns.Specs.current.key or "?"
end

function T.ChosenPotion()
  local t = ns.db and ns.db.potion
  return type(t) == "table" and t[SpecKey()] or nil
end

function T.SetPotion(item)
  if not ns.db then
    return
  end
  ns.db.potion = type(ns.db.potion) == "table" and ns.db.potion or {}
  ns.db.potion[SpecKey()] = item
end

-- Potions in your bags (item class Consumable, subclass Potion), one entry per item: the list to choose from.
-- (The settings panel covers the bags, so choosing is done from this list, not by dragging.)
function T.PotionsInBags()
  local out, seen = {}, {}
  local C = C_Container
  if not (C and C.GetContainerNumSlots and C.GetContainerItemInfo) then
    return out
  end
  for bag = 0, 5 do
    local n = U.Read((U.Call(C.GetContainerNumSlots, bag))) or 0
    for slot = 1, (type(n) == "number" and n or 0) do
      local info = U.Read((U.Call(C.GetContainerItemInfo, bag, slot)))
      local item = type(info) == "table" and U.Read(info.itemID) or nil
      if type(item) == "number" and not seen[item] then
        seen[item] = true
        local _, _, _, _, icon, classID, subclassID = U.Call(C_Item and C_Item.GetItemInfoInstant, item)
        if U.Read(classID) == 0 and U.Read(subclassID) == 1 then
          local name = C_Item and C_Item.GetItemNameByID and Read(C_Item.GetItemNameByID, item)
          out[#out + 1] = { item = item, name = name or ("item " .. item), icon = U.Read(icon) }
        end
      end
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

function T.PotionReady(item)
  local count = C_Item and C_Item.GetItemCount and Read(C_Item.GetItemCount, item)
  if type(count) == "number" and count < 1 then
    return false
  end
  local f = (C_Container and C_Container.GetItemCooldown) or GetItemCooldown
  if f then
    local start, duration, enable = U.Call(f, item)
    start, duration, enable = U.Read(start), U.Read(duration), U.Read(enable)
    if enable == 0 or enable == false then
      return false -- used this fight: no more until it ends
    end
    if type(start) == "number" and type(duration) == "number" and start > 0 and duration > 1.5 then
      return start + duration - GetTime() <= 0.1
    end
  end
  return true
end

function T.PotionPick(result)
  local item = T.ChosenPotion()
  if not item or (result and result.potion == false) or not T.PotionReady(item) then
    return nil
  end
  local _, spell = U.Call(C_Item and C_Item.GetItemSpell or GetItemSpell, item)
  local texture = C_Item and C_Item.GetItemIconByID and Read(C_Item.GetItemIconByID, item)
  return { id = U.Read(spell) or item, item = item, texture = texture, token = "potion", source = "potion",
    weave = true }
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
  -- Its own icon (bottom-left of slot 1 by default): never takes a slot or the defensive icon. A potion first: SimC
  -- times it with your biggest cooldowns, and it's once per fight.
  local potion
  if ns.State.combatStart and (not ns.BurstAllowed or ns.BurstAllowed()) then
    potion = T.PotionPick(result)
  end
  result.trinket = potion or T.Pick(result)
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
