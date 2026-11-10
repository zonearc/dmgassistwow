-- Buffs.lua: out-of-combat reminders for buffs a priority list assumes are already up.
--
-- SimC's precombat lists cast raid buffs, shields, weapon imbues and poisons before the pull, and its combat lists
-- take them for granted. DMGAssist puts a missing one in slot 1 while you are out of combat (not mounted, not
-- dead), so you see it before the pull:
--   raid buffs   Arcane Intellect, Power Word: Fortitude, Mark of the Wild, Battle Shout, Blessing of the Bronze,
--                Skyfury: missing on you, or on a group member in range
--   self         Lightning Shield (Elemental, Enhancement), Water Shield (Restoration)
--   weapons      Windfury + Flametongue (Enhancement), Flametongue (Elemental), Earthliving (Restoration): by
--                weapon slot, from the game's weapon enchant info
--   poisons      one lethal and one non-lethal poison (rogues)
--   auras        a paladin aura (Devotion, Concentration or Crusader)
--   on the tank  Earth Shield (Restoration Shaman), Beacon of Light (Holy Paladin): our own, on the group's tank
-- Also when it runs out within 5 minutes. Only spells you know and can cast now; each can be hidden on the
-- "Spells & trinkets" page like any spell, and the whole thing switched off (Combat > Buff reminders).
-- Auras are read only out of combat, where the game shows them in full. In combat, Blizzard's assistant naming one of
-- these buffs says it's missing (B.FromAssistant).

local _, ns = ...
local U = ns.U

local B = {}
ns.Buffs = B

B.REFRESH = 300 -- seconds left: remind again
B.CACHE = 0.5

local ENH, ELE, RSHAM = "shaman_enhancement", "shaman_elemental", "shaman_restoration"

-- id: the spell to cast. group: any one of these counts (rogue poisons). weapon: a weapon imbue for that hand.
-- group = true: a raid buff, checked on group members in range too. onTank: our own aura on the group's tank.
B.LIST = {
  { id = 1459, class = "MAGE", raid = true },     -- Arcane Intellect
  { id = 21562, class = "PRIEST", raid = true },  -- Power Word: Fortitude
  { id = 1126, class = "DRUID", raid = true },    -- Mark of the Wild
  { id = 6673, class = "WARRIOR", raid = true },  -- Battle Shout
  { id = 364342, class = "EVOKER", raid = true }, -- Blessing of the Bronze
  { id = 462854, class = "SHAMAN", raid = true }, -- Skyfury
  { id = 192106, specs = { [ELE] = true, [ENH] = true } }, -- Lightning Shield
  { id = 52127, specs = { [RSHAM] = true } },               -- Water Shield
  { id = 33757, weapon = "main", specs = { [ENH] = true } },   -- Windfury Weapon
  { id = 318038, weapon = "off", specs = { [ENH] = true } },   -- Flametongue Weapon
  { id = 318038, weapon = "main", specs = { [ELE] = true } },  -- Flametongue Weapon
  { id = 382021, weapon = "main", specs = { [RSHAM] = true } }, -- Earthliving Weapon
  { group = { 465, 317920, 32223 }, class = "PALADIN" },       -- an aura: Devotion / Concentration / Crusader
  { group = { 2823, 315584, 8679, 381664 }, class = "ROGUE" }, -- Deadly / Instant / Wound / Amplifying Poison
  { group = { 3408, 5761, 381637 }, class = "ROGUE" },         -- Crippling / Numbing / Atrophic Poison
  { id = 974, onTank = true, specs = { [RSHAM] = true } },     -- Earth Shield
  { id = 53563, onTank = true, specs = { paladin_holy = true } }, -- Beacon of Light
}

-- Is this one of the buffs above (raid buff, shield, poison, imbue, aura)?
local buffIDs
function B.IsBuffSpell(id)
  if not buffIDs then
    buffIDs = {}
    for _, e in ipairs(B.LIST) do
      if e.id then
        buffIDs[e.id] = true
      end
      for _, g in ipairs(type(e.group) == "table" and e.group or {}) do
        buffIDs[g] = true
      end
    end
  end
  return buffIDs[id] == true
end

local function Known(id)
  local b = ns.SpellMap.book and ns.SpellMap.book[id]
  if b then
    return not b.passive
  end
  return U.Get(IsPlayerSpell, id) == true
end

local function Usable(id)
  return U.Read((U.Call(C_Spell and C_Spell.IsSpellUsable, id))) ~= false
end

local function Name(id)
  return U.Get(C_Spell and C_Spell.GetSpellName, id)
end

-- Seconds left on a buff named `name` on `unit` (math.huge for no duration), or nil when it is missing.
local function Left(unit, name, filter)
  local f = C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName
  if not (f and name) then
    return math.huge -- can't tell: never nag
  end
  local a = U.Call(f, unit, name, filter or "HELPFUL")
  if type(a) ~= "table" then
    return nil
  end
  local exp = U.Read(a.expirationTime)
  if type(exp) ~= "number" or exp == 0 then
    return math.huge
  end
  return exp - GetTime()
end

local function Low(left)
  return left == nil or left < B.REFRESH
end

-- The group's units to check for raid buffs: you, and members in range who are alive and online.
local function Members()
  local out = { "player" }
  local n = tonumber(U.Get(GetNumGroupMembers)) or 0
  if n < 2 then
    return out
  end
  local raid = U.Get(IsInRaid) == true
  for i = 1, raid and n or (n - 1) do
    local unit = (raid and "raid" or "party") .. i
    if U.Get(UnitIsUnit, unit, "player") ~= true and U.Get(UnitExists, unit) == true
      and U.Get(UnitIsConnected, unit) ~= false and U.Get(UnitIsDeadOrGhost, unit) ~= true
      and U.Get(UnitInRange, unit) == true then
      out[#out + 1] = unit
    end
  end
  return out
end

local function Tank()
  local n = tonumber(U.Get(GetNumGroupMembers)) or 0
  if n < 2 then
    return nil
  end
  local raid = U.Get(IsInRaid) == true
  for i = 1, raid and n or (n - 1) do
    local unit = (raid and "raid" or "party") .. i
    if U.Get(UnitIsUnit, unit, "player") ~= true and U.Get(UnitGroupRolesAssigned, unit) == "TANK"
      and U.Get(UnitIsDeadOrGhost, unit) ~= true then
      return unit
    end
  end
  return nil
end

local function WeaponLeft(hand)
  if type(GetWeaponEnchantInfo) ~= "function" then
    return math.huge -- can't tell: never nag
  end
  local hasMain, mainExp, _, _, hasOff, offExp = U.Call(GetWeaponEnchantInfo)
  -- hidden in combat: read, never test a secret (hidden = not known: no reminder)
  hasMain, mainExp, hasOff, offExp = U.Read(hasMain), U.Read(mainExp), U.Read(hasOff), U.Read(offExp)
  if hand == "off" then
    if U.Get(GetInventoryItemID, "player", 17) == nil then
      return math.huge -- no off-hand
    end
    return hasOff and ((tonumber(offExp) or 0) / 1000) or nil
  end
  return hasMain and ((tonumber(mainExp) or 0) / 1000) or nil
end

local function Applies(entry, class, spec)
  if entry.class and entry.class ~= class then
    return false
  end
  return not entry.specs or entry.specs[spec] == true
end

-- The spells this spec can be reminded of (for the Spells & trinkets page).
function B.Spells()
  local state = ns.Specs.current
  local spec = state and state.key or ""
  local _, class = U.Call(UnitClass, "player")
  local out = {}
  for _, e in ipairs(B.LIST) do
    if Applies(e, class, spec) then
      for _, id in ipairs(e.group or { e.id }) do
        if Known(id) then
          out[#out + 1] = id
        end
      end
    end
  end
  return out
end

local function Check(entry)
  if entry.group then
    local best
    for _, id in ipairs(entry.group) do
      if Known(id) and not ns.Choices.IsHidden(id) then
        local left = Left("player", Name(id))
        if not Low(left) then
          return nil -- one of them is up
        end
        best = best or id
      end
    end
    return best and Usable(best) and best or nil
  end
  local id = entry.id
  if not Known(id) or ns.Choices.IsHidden(id) or not Usable(id) then
    return nil
  end
  if entry.weapon then
    return Low(WeaponLeft(entry.weapon)) and id or nil
  end
  local name = Name(id)
  if entry.onTank then
    local tank = Tank()
    if not tank then
      return nil
    end
    return Low(Left(tank, name, "HELPFUL|PLAYER")) and id or nil
  end
  if entry.raid then
    for _, unit in ipairs(Members()) do
      if Left(unit, name) == nil then
        return id
      end
    end
    return Low(Left("player", name)) and id or nil
  end
  return Low(Left("player", name)) and id or nil
end

-- The first missing buff, or nil. Out of combat only.
function B.Missing()
  if (ns.db and ns.db.buffReminders == false) or ns.State.combatStart or U.Get(InCombatLockdown) == true then
    return nil
  end
  if U.Get(IsMounted) == true or U.Get(UnitIsDeadOrGhost, "player") == true then
    return nil
  end
  local now = GetTime()
  if B.cachedAt and now - B.cachedAt < B.CACHE then
    return B.cached
  end
  local state = ns.Specs.current
  local spec = state and state.key or ""
  local _, class = U.Call(UnitClass, "player")
  local pick
  for _, e in ipairs(B.LIST) do
    if Applies(e, class, spec) then
      local id = Check(e)
      if id then
        pick = { id = id, token = ns.SpellMap.TokenForID and ns.SpellMap.TokenForID(id) or nil,
          source = "buff", why = e.onTank and "tank" or "buff" }
        break
      end
    end
  end
  B.cached, B.cachedAt = pick, now
  return pick
end

function B.Invalidate()
  B.cachedAt = nil
end

-- In combat the game hides our buffs, but Blizzard's assistant still sees them: when it names one of the buffs
-- above (Lightning Shield dropped mid-fight, 2026-11-10) for B.ASSIST_SETTLE seconds, that buff is missing. It goes
-- to slot 1 until you cast it; poisons go to slot 2 (a lethal / non-lethal swap mid-fight shouldn't push the
-- rotation aside). Only buffs you know, can cast now and haven't hidden.
B.ASSIST_SETTLE = 1
function B.FromAssistant()
  if (ns.db and ns.db.buffReminders == false) or not ns.State.combatStart then
    return nil
  end
  local G = ns.Engine
  local id, since = G and G.acName, G and G.acNamedAt
  if type(id) ~= "number" or not since or ns.State.Now() - since < B.ASSIST_SETTLE or not B.IsBuffSpell(id) then
    return nil
  end
  local state = ns.Specs.current
  local spec = state and state.key or ""
  local _, class = U.Call(UnitClass, "player")
  for _, e in ipairs(B.LIST) do
    local inGroup = false
    for _, g in ipairs(type(e.group) == "table" and e.group or {}) do
      inGroup = inGroup or g == id
    end
    if (e.id == id or inGroup) and Applies(e, class, spec) then
      if Known(id) and not ns.Choices.IsHidden(id) and Usable(id) then
        return { id = id, token = ns.SpellMap.TokenForID and ns.SpellMap.TokenForID(id) or nil, source = "buff",
          why = "assisted" }, inGroup and class == "ROGUE"
      end
      return nil
    end
  end
  return nil
end

-- Slot 1 out of combat: the missing buff first, the rest of the queue moves along. In combat: the buff Blizzard's
-- assistant asks for (slot 2 for a poison).
function B.Apply(result)
  local pick = B.Missing()
  local second
  if not pick then
    pick, second = B.FromAssistant()
  end
  if not (pick and result) then
    return result
  end
  local queue = { pick }
  if second and result.main then
    queue = { result.main, pick }
  end
  for _, p in ipairs(result.queue or { result.main }) do
    if p.id ~= pick.id and #queue < 3 and not (queue[1] and queue[1].id == p.id) then
      queue[#queue + 1] = p
    end
  end
  result.queue, result.main = queue, queue[1]
  result.branch = nil
  return result
end
