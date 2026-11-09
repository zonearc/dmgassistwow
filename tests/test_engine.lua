-- Run from the repo root:  lua5.1 tests/test_engine.lua
package.path = "./tests/?.lua;" .. package.path

local mock = require("wow_mock")
local print = print -- the mock captures the global print
mock.Install(_G)

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print("  FAIL " .. name .. "\n       " .. tostring(err))
  end
end
local function eq(a, b, msg)
  if a ~= b then
    error((msg or "values differ") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
  end
end

local ADDON = "DMGAssist"

local FERAL_BOOK = {
  { spellID = 5221, name = "Shred" },
  { spellID = 1822, name = "Rake" },
  { spellID = 1079, name = "Rip" },
  { spellID = 22568, name = "Ferocious Bite" },
  { spellID = 5217, name = "Tiger's Fury" },
  { spellID = 106951, name = "Berserk" },
  { spellID = 768, name = "Cat Form" },
  { spellID = 5215, name = "Prowl" },
  { spellID = 106830, name = "Thrash" },
  { spellID = 106785, name = "Swipe" },
  { spellID = 8921, name = "Moonfire" },
  { spellID = 16864, name = "Omen of Clarity", isPassive = true },
}

local function Reset()
  mock.frames, mock.timers, mock.printed = {}, {}, {}
  mock.restricted, mock.inCombat, mock.hasTarget = false, false, true
  mock.usable, mock.cooldowns, mock.auras, mock.talents = {}, {}, {}, {}
  mock.acSpell, mock.heroTree = nil, nil
  mock.power, mock.powerMax, mock.powerReadable = {}, {}, {}
  mock.casting, mock.nameplates, mock.locale = nil, 0, "enUS"
  mock.overrides, mock.inRange, mock.boss, mock.classification, mock.instance = nil, nil, nil, nil, nil
  mock.actionInfo, mock.macroSpell, mock.powerCost, mock.cdmInfo, mock.timeline = nil, nil, nil, nil, nil
  mock.bindings, mock.actionSlots, mock.bonusBar = nil, nil, nil
  mock.targetCast, mock.important = nil, nil
  mock.plateCombat, mock.plateNames = nil, nil
  mock.healthPct, mock.mounted, mock.sounds, mock.castTimes = nil, nil, {}, nil
  SettingsPanel, ActionButton3 = nil, nil
  DBM, BigWigsLoader, BT4Button1, BuffIconCooldownViewer = nil, nil, nil, nil
  mock.class, mock.specs, mock.specIndex = { "Druid", "DRUID", 11 }, { [1] = 102, [2] = 103, [3] = 104, [4] = 105 }, 2
  mock.book = FERAL_BOOK
  DMGAssistDB = nil
end

-- Enter restricted combat: secrets everywhere, auras unreadable.
local function Restrict()
  mock.restricted, mock.inCombat = true, true
  mock.auras.target = { { name = "Someone Else's Debuff" } }
  mock.auras.player = { { name = "Some Buff" } }
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Fire("UNIT_AURA", "target")
  mock.Fire("UNIT_AURA", "player")
end

local function Boot(gameType, project)
  mock.gameType = gameType or "standard"
  WOW_PROJECT_ID = project or 1
  local ns = mock.LoadAddon("addons/" .. ADDON, ADDON)
  mock.Fire("ADDON_LOADED", ADDON)
  mock.Fire("PLAYER_LOGIN")
  return ns
end

-- A small hand-made record in the generated format.
local function Record()
  return {
    key = "druid_feral",
    simcOrder = { "default", "finisher" },
    simc = {
      precombat = {
        { a = "variable", k = "S", p = { name = "big", value = "10" } },
      },
      default = {
        { a = "berserk", k = "R", c = "buff.tigers_fury.up" }, -- false until Tiger's Fury is cast
        { a = "variable", k = "S", p = { name = "big", op = "add", value = "5" } },
        { a = "call_action_list", k = "R", c = "combo_points>=5", p = { name = "finisher" } },
        { a = "rake", k = "T", c = "!dot.rake.ticking" },
        { a = "shred", k = "R", c = "variable.big=15" },
      },
      finisher = {
        { a = "rip", k = "T", c = "!dot.rip.ticking" },
        { a = "ferocious_bite", k = "R" },
      },
    },
    blizzardOrder = { "default" },
    blizzard = {
      default = {
        { a = "berserk", k = "R", x = true },
        { a = "rake", k = "T", c = "combo_points<5" },
        { a = "thrash", k = "R" },
      },
    },
    blizzardExcluded = { "berserk" },
  }
end

print("DMGAssist engine tests")

---------------------------------------------------------------------------
-- Expressions
---------------------------------------------------------------------------
test("expressions: SimC precedence and operators", function()
  Reset()
  local ns = Boot()
  local E = ns.Expr
  local function r()
    return 0
  end
  eq(E.Test("1+2*3=7", r), true)
  eq(E.Test("6%3=2", r), true, "% is division in SimC")
  eq(E.Test("7%%3=1", r), true, "%% is modulo")
  eq(E.Test("(2<?5)=5&(2>?5)=2", r), true, "SimC: <? is max, >? is min (engine/sim/expressions.cpp)")
  eq(E.Test("1|0&0", r), true, "& binds tighter than |")
  eq(E.Test("!0&!1", r), false)
  eq(E.Test("floor(2.7)=2&ceil(2.1)=3", r), true)
  eq(E.Test("-3<0", r), true)
  eq(E.Test("1<=1&2>=3", r), false)
  eq(E.Test("", r), true, "empty condition is true")
end)

test("expressions: unknown follows Kleene logic", function()
  Reset()
  local ns = Boot()
  local E = ns.Expr
  local function r(name)
    if name == "x" then
      return E.UNKNOWN
    end
    return 1
  end
  eq(E.Test("0&x", r), false)
  eq(E.Test("1|x", r), true)
  eq(E.Test("1&x", r), E.UNKNOWN)
  eq(E.Test("0|x", r), E.UNKNOWN)
  eq(E.Test("!x", r), E.UNKNOWN)
  eq(E.Test("x>3", r), E.UNKNOWN)
  eq(E.Test("x+1", r), E.UNKNOWN)
  eq(E.Test("y=1", r), true)
end)

test("expressions: unknown values keep their limits (flags 0..1, times >= 0)", function()
  Reset()
  local ns = Boot()
  local E = ns.Expr
  local function r(name)
    if name == "buff.eclipse.remains" then
      return 0
    elseif name == "cooldown.fury.remains" then
      return 5
    end
    return E.UNKNOWN
  end
  -- Balance's variable.cds: "the longest of these < 1", one term mixing in hidden procs.
  eq(E.Test("(0<?(buff.eclipse.remains-(10*(buff.bloodlust.up*buff.ascendant_stars.down))))<1", r), true,
    "the hidden term is at most eclipse.remains (0)")
  eq(E.Test("(cooldown.fury.remains<?buff.hidden.remains)<1", r), false, "a known term >= 1 decides MAX < 1")
  eq(E.Test("(cooldown.fury.remains>?buff.hidden.remains)<6", r), true, "MIN is at most the known term")
  eq(E.Test("buff.hidden.up<=1", r), true)
  eq(E.Test("buff.hidden.up*0=0", r), true)
  eq(E.Test("buff.hidden.remains>=0", r), true)
  eq(E.Test("buff.hidden.remains>3", r), E.UNKNOWN)
  eq(E.Test("x>3", r), E.UNKNOWN, "no limits from an unknown name")
  eq(E.Value("buff.hidden.up+1", r), E.UNKNOWN, "a range leaves Eval as UNKNOWN")
end)

test("expressions: a malformed condition is UNKNOWN, not an error", function()
  Reset()
  local ns = Boot()
  local E = ns.Expr
  eq(E.Test("1&(2", function() return 1 end), E.UNKNOWN)
  eq(E.Test("1 $ 2", function() return 1 end), E.UNKNOWN)
  eq(type(E.failures["1&(2"]), "string")
end)

local function AllExpressions(record, out)
  for _, lists in ipairs({ record.simc or {}, record.blizzard or {} }) do
    for _, list in pairs(lists) do
      for _, e in ipairs(list) do
        out[#out + 1] = e.c
        if e.p then
          out[#out + 1] = e.p.value
          out[#out + 1] = e.p.condition
          out[#out + 1] = e.p.value_else
        end
      end
    end
  end
end

for _, client in ipairs({ { "standard", 1, "midnight" }, { "camelot", 18, "forever" } }) do
  test("every condition in the " .. client[3] .. " data parses in Lua", function()
    Reset()
    local ns = Boot(client[1], client[2])
    local count, bad = 0, {}
    for _, record in pairs(ns.Data.specs[client[3]]) do
      local exprs = {}
      AllExpressions(record, exprs)
      for _, s in ipairs(exprs) do
        if type(s) == "string" and s ~= "" and not s:find("^[%a_]+$") then
          count = count + 1
          local node, err = ns.Expr.Parse(s)
          if not node then
            bad[#bad + 1] = s .. " -> " .. tostring(err)
          end
        end
      end
    end
    eq(count > 1000, true, "too few expressions found")
    eq(#bad, 0, "unparsed: " .. tostring(bad[1]))
  end)
end

---------------------------------------------------------------------------
-- Spell map
---------------------------------------------------------------------------
test("spell names tokenize like SimC and aliases resolve", function()
  Reset()
  local ns = Boot()
  local M = ns.SpellMap
  eq(M.Token("Tiger's Fury"), "tigers_fury")
  eq(M.Token("Ferocious Bite"), "ferocious_bite")
  eq(M.SpellID("tigers_fury"), 5217)
  eq(M.SpellID("swipe_cat"), 106785, "suffix _cat strips to swipe")
  eq(M.SpellID("moonfire_cat"), nil, "needs Lunar Inspiration: the caster Moonfire would leave Cat Form")
  eq(M.SpellID("bs_inc"), 106951, "bs_inc alias -> berserk")
  eq(M.SpellID("omen_of_clarity"), nil, "passives are not castable")
  eq(M.AnySpellID("omen_of_clarity"), 16864)
  eq(M.SpellID("not_a_spell"), nil)
end)

test("talents and hero tree are read from the trait tree", function()
  Reset()
  mock.talents = {
    { name = "Lunar Inspiration", spellID = 155580, rank = 1 },
    { name = "Panther's Guile", spellID = 400001, rank = 0 },
  }
  mock.heroTree = "Wildstalker"
  mock.book = {}
  for _, b in ipairs(FERAL_BOOK) do
    mock.book[#mock.book + 1] = b
  end
  mock.book[#mock.book + 1] = { spellID = 155580, name = "Lunar Inspiration", isPassive = true }
  mock.book[#mock.book + 1] = { spellID = 400001, name = "Panther's Guile", isPassive = true }
  local ns = Boot()
  local S = ns.State
  -- Hero trees are recognised by their talents' spell IDs (from SimC's data), not by the localized name.
  local heroIDs = ns.Specs.current.data.heroTrees.wildstalker
  eq(type(heroIDs), "table", "SimC data lists Wildstalker talents")
  mock.talents[#mock.talents + 1] = { name = "Some Wildstalker Talent", spellID = heroIDs[1], rank = 1 }
  mock.Fire("TRAIT_CONFIG_UPDATED", 1)
  mock.Advance(0.5)
  eq(S.Resolve("talent.lunar_inspiration", {}), 1)
  eq(S.Resolve("talent.panthers_guile", {}), 0)
  eq(S.Resolve("talent.never_heard_of_it", {}), ns.Expr.UNKNOWN)
  eq(S.Resolve("hero_tree.wildstalker", {}), 1)
  eq(S.Resolve("hero_tree.druid_of_the_claw", {}), 0)
end)

---------------------------------------------------------------------------
-- Engine decisions
---------------------------------------------------------------------------
test("confident SimC line wins, even against the assistant", function()
  Reset()
  local ns = Boot()
  mock.acSpell = 106830 -- the assistant wants Thrash
  -- combo points: mock UnitPower returns 50 for non-holy-power types out of restriction -> finisher list runs
  -- out of combat everything is readable: 50 combo points -> finisher list, Rip is not on the target
  local r = ns.Engine.Recommend(Record(), { useAssisted = true })
  eq(r.main.token, "rip")
  eq(r.main.source, "simc")
end)

test("major cooldowns are ordinary queue lines; switched off they never show", function()
  Reset()
  local ns = Boot()
  local regen = ns.State.REGEN_BASE
  ns.State.REGEN_BASE = {} -- this fixture's energy is about placement, not regeneration
  local now = Record()
  now.simc.default[1].c = nil
  local r = ns.Engine.Recommend(now, {})
  eq(r.main.token, "berserk", "the list wants it now: slot 1")
  eq(r.main.major, true)
  eq(r.cd, nil, "no separate cooldown slot")
  -- later in the list: it shows up in slot 2 / 3 like anything else
  local later = Record()
  later.simc.default[1].c = "prev_gcd.1.shred"
  r = ns.Engine.Recommend(later, {})
  local tokens = {}
  for i, p in ipairs(r.queue) do
    tokens[i] = p.token
  end
  eq(tokens[1] ~= "berserk" and (tokens[2] == "berserk" or tokens[3] == "berserk"), true,
    "berserk after shred in the queue: " .. table.concat(tokens, " > "))
  -- switched off: nowhere in the queue
  r = ns.Engine.Recommend(now, { burst = false })
  for _, p in ipairs(r.queue) do
    eq(p.token ~= "berserk", true, "major cooldowns off")
  end
  ns.State.REGEN_BASE = regen
end)

test("interrupt lines in a SimC list are never rotation picks (the Interrupts module shows them)", function()
  Reset()
  local book = {}
  for i, b in ipairs(FERAL_BOOK) do
    book[i] = b
  end
  book[#book + 1] = { spellID = 106839, name = "Skull Bash" }
  mock.book = book
  local ns = Boot()
  eq(ns.Engine.SKIP.skull_bash, true)
  eq(ns.Engine.SKIP.muzzle, true)
  eq(ns.Engine.SKIP.charge, true, "movement lines are left to the gap closer")
  local rec = Record()
  table.insert(rec.simc.default, 1, { a = "skull_bash", k = "R" })
  local r = ns.Engine.Recommend(rec, {})
  for _, p in ipairs(r.queue) do
    eq(p.token ~= "skull_bash", true, "skull bash not in the queue")
  end
end)

test("gap closer: melee specs probe with a melee spell even when most of their spells are ranged", function()
  Reset()
  local ns = Boot()
  local X = ns.Essentials
  eq(X.MELEE.hunter_survival, true)
  eq(X.MELEE.hunter_beast_mastery, nil, "ranged hunters get no gap closer")
  eq(X.MeleeProbe() ~= nil, true, "feral: a melee probe")
  local info = ns.SpellMap.Info(X.MeleeProbe())
  eq(info.r <= 8, true, "the probe is a melee-range spell")
end)

test("buff reminders: a missing raid buff, a weapon imbue, our shield on the tank; never in combat", function()
  Reset()
  local ns = Boot()
  local B = ns.Buffs
  local saved = { C_Spell.GetSpellName, C_UnitAuras.GetAuraDataBySpellName, UnitClass, GetNumGroupMembers,
    UnitExists, IsPlayerSpell }
  local known, up, tankUp = { [1126] = true }, {}, false
  IsPlayerSpell = function(id)
    return known[id] == true
  end
  local names = { [1126] = "Mark of the Wild", [974] = "Earth Shield", [33757] = "Windfury Weapon" }
  C_Spell.GetSpellName = function(id)
    return names[id]
  end
  C_UnitAuras.GetAuraDataBySpellName = function(unit, name, filter)
    if unit == "party1" and filter == "HELPFUL|PLAYER" then
      return tankUp and { name = name, expirationTime = GetTime() + 600 } or nil
    end
    return up[unit .. name] and { name = name, expirationTime = 0 } or nil
  end
  UnitClass = function()
    return "Druid", "DRUID", 11
  end
  local main = { id = 5221, token = "shred" }
  local r = B.Apply({ main = main, queue = { main } })
  eq(r.main.id, 1126, "Mark of the Wild missing: slot 1")
  eq(r.main.source, "buff")
  eq(r.queue[2], main, "the rotation moves along")
  up["playerMark of the Wild"] = true
  B.Invalidate()
  r = B.Apply({ main = main, queue = { main } })
  eq(r.main, main, "buff up: nothing")
  up["playerMark of the Wild"] = nil
  ns.db.buffReminders = false
  B.Invalidate()
  eq(B.Missing(), nil, "switched off")
  ns.db.buffReminders = true
  ns.Choices.SetHidden(1126, true)
  B.Invalidate()
  eq(B.Missing(), nil, "hidden on the Spells page")
  ns.Choices.SetHidden(1126, false)
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  B.Invalidate()
  eq(B.Missing(), nil, "never in combat")
  mock.inCombat = false
  mock.Fire("PLAYER_REGEN_ENABLED")
  -- Restoration Shaman: Earth Shield on the tank.
  UnitClass = function()
    return "Shaman", "SHAMAN", 7
  end
  known = { [974] = true }
  ns.Specs.current.key = "shaman_restoration"
  GetNumGroupMembers = function()
    return 2
  end
  UnitGroupRolesAssigned = function(unit)
    return unit == "party1" and "TANK" or "HEALER"
  end
  UnitExists = function()
    return true
  end
  B.Invalidate()
  eq(B.Missing() and B.Missing().id, 974, "Earth Shield missing on the tank")
  tankUp = true
  B.Invalidate()
  eq(B.Missing(), nil, "Earth Shield up on the tank")
  -- Enhancement: Windfury Weapon on the main hand.
  known = { [33757] = true }
  ns.Specs.current.key = "shaman_enhancement"
  GetWeaponEnchantInfo = function()
    return false
  end
  B.Invalidate()
  eq(B.Missing() and B.Missing().id, 33757, "no main-hand imbue")
  GetWeaponEnchantInfo = function()
    return true, 3600000
  end
  B.Invalidate()
  eq(B.Missing(), nil, "imbued for an hour")
  C_Spell.GetSpellName, C_UnitAuras.GetAuraDataBySpellName, UnitClass, GetNumGroupMembers, UnitExists,
    IsPlayerSpell = saved[1], saved[2], saved[3], saved[4], saved[5], saved[6]
  GetWeaponEnchantInfo, UnitGroupRolesAssigned = nil, nil
end)

test("trinkets: SimC's questions about what a trinket does are answered from its description (Survival)", function()
  Reset()
  local ns = Boot()
  local T, G = ns.Trinkets, ns.Engine
  local tr = T.ParseUse("Compel an oathbound Shadowguard squad to annihilate your target and nearby enemies, "
    .. "dealing 58035 Cosmic damage split between them. Damage increased by 30% per additional enemy, up to 150%. "
    .. "(2 Min Cooldown)")
  eq(tr.damage, true)
  eq(tr.buff, nil)
  eq(tr.cd, 120)
  tr = T.ParseUse("Consume all Latent Power to gain 13 Agility per stack for 20 sec. (30 Sec Cooldown)")
  eq(tr.buff, true)
  eq(tr.buffs.agility, true)
  eq(tr.buffs.haste, nil)
  eq(tr.damage, false)
  eq(tr.cd, 30)
  eq(tr.duration, 20)
  -- equipped: Perfidious Projector (damage) and Unyielding Netherprism (Agility)
  GetInventoryItemID = function(_, slot)
    return ({ [13] = 2001, [14] = 2002 })[slot]
  end
  local saved = { C_Item = C_Item, desc = C_Spell.GetSpellDescription, cd = GetInventoryItemCooldown }
  C_Item = { GetItemSpell = function(item)
    return "Use", item == 2001 and 9101 or 9102
  end, GetItemNameByID = function(item)
    return item == 2001 and "Perfidious Projector" or "Unyielding Netherprism"
  end }
  C_Spell.GetSpellDescription = function(id)
    if id == 9101 then
      return "Compel an oathbound Shadowguard squad to annihilate your target, dealing 58035 Cosmic damage. (2 Min Cooldown)"
    end
    return "Consume all Latent Power to gain 13 Agility per stack for 20 sec. (30 Sec Cooldown)"
  end
  GetInventoryItemCooldown = function()
    return 0, 0, 1
  end
  local rec = ns.Data.specs.midnight.hunter_survival
  ns.SpellMap.SetData(rec)
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  T.this = 13
  eq(ns.State.Resolve("this_trinket.has_use_damage", {}), 1)
  eq(ns.State.Resolve("other_trinket.has_use_buff", {}), 1)
  eq(ns.State.Resolve("this_trinket.cooldown.duration", {}), 120)
  eq(ns.State.Resolve("this_trinket.is.perfidious_projector", {}), 1)
  T.this = nil
  eq(ns.State.Resolve("trinket.2.has_buff.agility", {}), 1)
  eq(ns.State.Resolve("trinket.2.has_buff.haste", {}), 0)
  local r = G.Recommend(rec, { burst = true })
  eq(r.useItems.trinket1 ~= false, true, "the damage trinket: SimC says use it")
  local main = { id = 186270, token = "raptor_strike" }
  local applied = T.Apply({ main = main, queue = { main }, useItems = r.useItems })
  eq(applied.trinket and applied.trinket.item, 2001, "shown in the trinket badge")
  C_Item, C_Spell.GetSpellDescription, GetInventoryItemCooldown = saved.C_Item, saved.desc, saved.cd
  mock.inCombat = false
end)

test("potions: the one you chose shows in the items icon when SimC's potion line says now, once per fight", function()
  Reset()
  local ns = Boot()
  local T = ns.Trinkets
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  local main = { id = 5221, token = "shred" }
  eq(T.Apply({ main = main, queue = { main } }).trinket, nil, "no potion chosen: nothing")
  T.SetPotion(212265)
  local saved = { C_Item = C_Item, cd = C_Container, inv = GetInventoryItemID }
  GetInventoryItemID = function()
    return nil -- no on-use trinkets in this test
  end
  C_Item = { GetItemSpell = function()
    return "Tempered Potion", 431932
  end, GetItemCount = function()
    return 3
  end, GetItemIconByID = function()
    return 5000
  end }
  local used = false
  C_Container = { GetItemCooldown = function()
    if used then
      return GetTime() - 5, 300, 0
    end
    return 0, 0, 1
  end }
  local r = T.Apply({ main = main, queue = { main }, potion = true })
  eq(r.trinket and r.trinket.item, 212265, "SimC says now: in the items icon")
  eq(r.trinket.source, "potion")
  eq(r.queue[1].id, 5221, "slot 1 untouched")
  eq(T.Apply({ main = main, queue = { main }, potion = false }).trinket, nil, "SimC says not now")
  used = true
  eq(T.Apply({ main = main, queue = { main }, potion = true }).trinket, nil, "used this fight")
  -- choosing: the potions in your bags (the settings panel covers the bags, so no dragging)
  C_Container.GetContainerNumSlots = function(bag)
    return bag == 0 and 3 or 0
  end
  C_Container.GetContainerItemInfo = function(_, slot)
    return ({ { itemID = 212265 }, { itemID = 5512 }, { itemID = 212265 } })[slot]
  end
  C_Item.GetItemInfoInstant = function(item)
    if item == 212265 then
      return item, "Potion", "", "", 1, 0, 1 -- Consumable / Potion
    end
    return item, "Stone", "", "", 2, 0, 3 -- a healthstone-like consumable that isn't a potion
  end
  C_Item.GetItemNameByID = function()
    return "Tempered Potion"
  end
  local list = T.PotionsInBags()
  eq(#list, 1, "one potion, listed once")
  eq(list[1].item, 212265)
  SlashCmdList.DMGASSIST("potion off")
  eq(T.ChosenPotion(), nil, "/dmga potion off")
  SlashCmdList.DMGASSIST("potion |cffa335ee|Hitem:212265::::::::80:::::|h[Tempered Potion]|h|r")
  eq(T.ChosenPotion(), 212265, "/dmga potion <shift-click>")
  C_Item, C_Container, GetInventoryItemID = saved.C_Item, saved.cd, saved.inv
  T.SetPotion(nil)
  mock.inCombat = false
end)

test("defensive icon: a self-heal the rotation picks leaves the slots for the defensive icon", function()
  Reset()
  local ns = Boot()
  local regrowth = { id = 8936, token = "regrowth", source = "simc" }
  local shred = { id = 5221, token = "shred", source = "simc" }
  local r = { main = regrowth, queue = { regrowth, shred } }
  ns.Defensives.Apply(r)
  eq(r.main.token, "shred", "slot 1: the rotation")
  eq(#r.queue, 1)
  eq(r.weave and r.weave.token, "regrowth", "the self-heal: in the defensive icon")
end)

test("on-use trinkets: every equipped one by default, switched off per trinket, SimC's use_items respected", function()
  Reset()
  local ns = Boot()
  local T = ns.Trinkets
  local cd = { [13] = { 0, 0, 1 }, [14] = { 0, 0, 1 } }
  GetInventoryItemID = function(_, slot)
    return ({ [13] = 1001, [14] = 1002 })[slot]
  end
  C_Item = { GetItemSpell = function(item)
    if item == 1001 then
      return "Use: Power", 9001
    end
    return nil -- 1002: a passive trinket
  end, GetItemNameByID = function(item)
    return item == 1001 and "Mirror of Fractured Tomorrows" or "Passive Thing"
  end }
  GetInventoryItemCooldown = function(_, slot)
    return cd[slot][1], cd[slot][2], cd[slot][3]
  end
  eq(#T.List(), 1, "only the on-use trinket is listed")
  eq(T.Token("Mirror of Fractured Tomorrows"), "mirror_of_fractured_tomorrows")
  local main = { id = 5221, token = "shred" }
  local r = T.Apply({ main = main, queue = { main } })
  eq(r.trinket, nil, "out of combat: nothing")
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  r = T.Apply({ main = main, queue = { main } })
  eq(r.trinket and r.trinket.item, 1001, "in combat at a hostile target: the trinket badge")
  eq(r.trinket.source, "trinket")
  r = T.Apply({ main = main, queue = { main }, useItems = { all = false } })
  eq(r.trinket, nil, "SimC says not now")
  r = T.Apply({ main = main, queue = { main }, useItems = { all = false, trinket1 = true } })
  eq(r.trinket and r.trinket.item, 1001, "a line for this slot says yes")
  r = T.Apply({ main = main, queue = { main, { id = 1822 } }, weave = { id = 192081 } })
  eq(r.trinket and r.trinket.item, 1001, "Ironfur in its badge: the trinket still has its own")
  eq(r.weave.id, 192081, "Ironfur keeps its badge")
  eq(r.queue[2].id, 1822, "slot 2 stays the next GCD spell")
  cd[13] = { GetTime() - 10, 120, 1 }
  r = T.Apply({ main = main, queue = { main } })
  eq(r.trinket, nil, "on cooldown")
  cd[13] = { 0, 0, 1 }
  T.SetOff(1001, true)
  r = T.Apply({ main = main, queue = { main } })
  eq(r.trinket, nil, "switched off: you press it yourself")
  T.SetOff(1001, false)
  ns.db.trinkets = false
  r = T.Apply({ main = main, queue = { main } })
  eq(r.trinket, nil, "master switch off")
  ns.db.trinkets = true
  -- the key binding check lists it while it has no key
  local missing = ns.Bindcheck.Missing()
  local found
  for _, m in ipairs(missing) do
    if m.item == 1001 then
      found = m
    end
  end
  eq(found ~= nil, true, "unbound trinket listed")
  eq(found.onBar, false)
  mock.Fire("PLAYER_REGEN_ENABLED")
  mock.inCombat = false
  GetInventoryItemID, C_Item, GetInventoryItemCooldown = nil, nil, nil
end)

test("key binding check: rotation spells without a key are listed; bound ones are not", function()
  Reset()
  mock.bindings = { ACTIONBUTTON3 = "3" }
  mock.actionInfo = { [3] = { "spell", 5221 } }
  local ns = Boot()
  ns.Display.InvalidateKeybinds()
  local names = {}
  for _, m in ipairs(ns.Bindcheck.Missing()) do
    names[m.id] = true
  end
  eq(names[5221], nil, "Shred is bound")
  eq(names[1822], true, "Rake has no key")
  mock.actionInfo = nil
end)

test("Touch of Death only on a target with less health than your maximum", function()
  Reset()
  local ns = Boot()
  local G = ns.Engine
  local hp = 5000
  local oldHealth, oldMax = UnitHealth, UnitHealthMax
  UnitHealth = function(unit)
    return unit == "target" and hp or 1000
  end
  UnitHealthMax = function()
    return 1000
  end
  local ok, why = G.Castable(322109)
  eq(ok, false, "dummy with more health than you")
  eq(why, "target")
  hp = 900
  eq(G.Castable(322109) ~= false, true, "below your max health")
  -- the assistant's own fallback suggestion goes through the same rule, and through holds
  hp = 5000
  mock.acSpell = 322109
  local rec = Record()
  rec.simc = { default = {} }
  rec.blizzard = nil
  local r = ns.Engine.Recommend(rec, { useAssisted = true })
  eq(r.main == nil or r.main.id ~= 322109, true, "assistant's Touch of Death on a full-health dummy: dropped")
  mock.acSpell = 5221
  G.held[5221] = true
  r = ns.Engine.Recommend(rec, { useAssisted = true })
  eq(r.main == nil or r.main.id ~= 5221, true, "a held spell is not brought back by the assistant")
  G.held = {}
  mock.acSpell = nil
  UnitHealth, UnitHealthMax = oldHealth, oldMax
end)

test("nothing castable now: the slot shows the first spell ready within a few seconds, not nothing", function()
  Reset()
  local ns = Boot()
  mock.cooldowns[5221] = { active = true, start = mock.now - 9, duration = 10 } -- Shred back in 1 s
  local rec = Record()
  rec.simc = { default = { { a = "shred", k = "R" } } }
  rec.blizzard = nil
  local r = ns.Engine.Recommend(rec, {})
  eq(r.main and r.main.token, "shred", "shown ahead of time")
  eq(r.main.wait ~= nil and r.main.wait <= 1.5, true, "marked as a short wait")
  mock.cooldowns[5221] = { active = true, start = mock.now, duration = 60 }
  r = ns.Engine.Recommend(rec, {})
  eq(r.main == nil or r.main.token ~= "shred", true, "a long cooldown is not shown")
end)

test("short list, everything on cooldown: slots 2 and 3 show what comes off cooldown soonest", function()
  Reset()
  local ns = Boot()
  mock.acSpell = 106830 -- the assistant's pick fills slot 1 (Thrash)
  mock.cooldowns[5221] = { active = true, start = mock.now - 1, duration = 6 } -- Shred back in 5 s
  mock.cooldowns[1822] = { active = true, start = mock.now - 1, duration = 9 } -- Rake back in 8 s
  mock.cooldowns[106951] = { active = true, start = mock.now, duration = 120 } -- Berserk: too far off
  local rec = Record()
  rec.simc = { default = {
    { a = "berserk", k = "R" },
    { a = "rake", k = "R" },
    { a = "shred", k = "R" },
  } }
  rec.blizzard = nil
  local r = ns.Engine.Recommend(rec, { useAssisted = true })
  eq(r.main and r.main.id, 106830, "slot 1: the assistant's pick")
  eq(r.queue[2] and r.queue[2].token, "shred", "slot 2: back first")
  eq(r.queue[2].source, "soon")
  eq(r.queue[3] and r.queue[3].token, "rake", "slot 3: back next")
  mock.acSpell = nil
end)

test("the assistant's pick on cooldown is never shown as ready: slot 1 waits for it, marked not yet", function()
  Reset()
  local ns = Boot()
  mock.acSpell = 1822 -- the assistant names Rake, 2 s left on its cooldown
  mock.cooldowns[1822] = { active = true, start = mock.now - 7, duration = 9 }
  mock.cooldowns[5221] = { active = true, start = mock.now, duration = 60 }
  local rec = Record()
  rec.simc = { default = { { a = "shred", k = "R" } } }
  rec.blizzard = nil
  local r = ns.Engine.Recommend(rec, { useAssisted = true })
  eq(r.main and r.main.id, 1822, "shown ahead of time")
  eq(type(r.main.readyAt), "number", "marked not ready yet")
  eq(r.main.readyAt > GetTime() + 1, true, "ready when its cooldown ends, not now")
  mock.cooldowns[1822] = { active = true, start = mock.now, duration = 9 } -- 9 s left: too far off
  r = ns.Engine.Recommend(rec, { useAssisted = true })
  eq(r.main == nil or r.main.id ~= 1822 or r.main.readyAt ~= nil, true, "never as press-now")
  mock.acSpell = nil
end)

test("hero tree names: SimC's shadopan matches the game's Shado-Pan", function()
  Reset()
  local ns = Boot()
  local M = ns.SpellMap
  local saved = { M.talentsRead, M.hero, M.heroTree }
  M.talentsRead, M.hero, M.heroTree = true, {}, M.Token("Shado-Pan")
  eq(M.HeroTree("shadopan"), 1)
  eq(M.HeroTree("master_of_harmony"), 0)
  M.talentsRead, M.hero, M.heroTree = saved[1], saved[2], saved[3]
end)

test("tank damage reduction only when something is hurting you (Purifying Brew on a dummy)", function()
  Reset()
  local ns = Boot()
  local G = ns.Engine
  local st, hp = 0, 1000
  local old = { UnitStagger, UnitHealth, UnitHealthMax }
  UnitStagger = function() return st end
  UnitHealth = function() return hp end
  UnitHealthMax = function() return 1000 end
  eq(G.NotHurtSkip("purifying_brew"), true, "no stagger: nothing to purify")
  eq(G.NotHurtSkip("celestial_brew"), true, "full health, no stagger")
  eq(G.NotHurtSkip("keg_smash"), false, "not a mitigation spell")
  st = 500
  eq(G.NotHurtSkip("purifying_brew"), false, "stagger to clear")
  st, hp = 0, 800
  eq(G.NotHurtSkip("celestial_brew"), false, "taking damage")
  eq(G.NotHurtSkip("purifying_brew"), true, "Purifying Brew still needs stagger")
  UnitStagger, UnitHealth, UnitHealthMax = old[1], old[2], old[3]
end)

test("SimC's moving=1 lines only while moving; a proc glow confirms an uncertain line", function()
  Reset()
  local ns = Boot()
  local rec = Record()
  rec.blizzard = nil
  rec.simc = { default = { { a = "rake", k = "R", p = { moving = "1" } }, { a = "shred", k = "R" } } }
  local r = ns.Engine.Recommend(rec, {})
  eq(r.main.token, "shred", "standing still: the moving-only line is skipped")
  ns.State.moving = true
  r = ns.Engine.Recommend(rec, {})
  eq(r.main.token, "rake", "moving: it applies")
  ns.State.moving = false
  -- uncertain line (combo points hidden in restricted combat), confirmed by the button glow
  Restrict()
  rec.simc = { default = { { a = "rip", k = "T", c = "combo_points>=5" }, { a = "shred", k = "R" } } }
  r = ns.Engine.Recommend(rec, {})
  eq(r.main.token ~= "rip" or r.main.source ~= "simc+glow", true)
  ns.State.glow[1079] = true
  r = ns.Engine.Recommend(rec, {})
  eq(r.main.token, "rip", "glowing: shown")
  eq(r.main.source, "simc+glow")
  ns.State.glow[1079] = nil
end)

test("cooldown length from the game's base cooldown when our data has none (racials)", function()
  Reset()
  local ns = Boot()
  local old = GetSpellBaseCooldown
  GetSpellBaseCooldown = function(id) return id == 274738 and 120000 or 0 end
  eq(ns.State.CooldownLength(274738), 120)
  GetSpellBaseCooldown = old
end)

test("a spell the game calls known but that has no button (granted by a passive) is not recommended", function()
  Reset()
  local ns = Boot()
  local M = ns.SpellMap
  local old = IsPlayerSpell
  IsPlayerSpell = function() return true end
  eq(M.Pressable(999001), false, "not on a bar, not in the spellbook")
  mock.actionSlots = { [999001] = { 5 } }
  eq(M.Pressable(999001), true, "on a bar")
  mock.actionSlots = nil
  IsPlayerSpell = old
end)

test("the assistant spending a resource confirms SimC's uncertain spender of the same resource only", function()
  Reset()
  local ns = Boot()
  local G = ns.Engine
  eq(G.SameSpender(1079, 22568), true, "Rip and Ferocious Bite both spend combo points")
  eq(G.SameSpender(5221, 1822), false, "Shred and Rake only share energy: no evidence")
end)

test("spells you switch off are never shown; the next one takes their place; kept per spec", function()
  Reset()
  local ns = Boot()
  local C = ns.Choices
  local rec = Record()
  rec.blizzard = nil
  rec.simc = { default = { { a = "rake", k = "R" }, { a = "shred", k = "R" } } }
  local r = ns.Engine.Recommend(rec, {})
  eq(r.main.token, "rake")
  C.SetHidden(1822, true)
  eq(C.IsHidden(1822), true)
  r = ns.Engine.Recommend(rec, {})
  eq(r.main.token, "shred", "Rake hidden: Shred is next")
  for _, p in ipairs(r.queue) do
    eq(p.id ~= 1822, true, "hidden spell nowhere in the queue")
  end
  -- the final filter catches anything another module adds
  r = C.Filter({ main = { id = 1822 }, queue = { { id = 1822 }, { id = 5221 } } })
  eq(r.main.id, 5221)
  -- the page lists the rotation's spells
  local listed = {}
  for _, id in ipairs(C.Spells()) do
    listed[id] = true
  end
  eq(listed[1822] and listed[5221], true, "Rake and Shred listed")
  -- per spec: another spec has its own choices
  eq(type(ns.db.hidden[ns.Specs.current.key]), "table")
  C.SetHidden(1822, false)
  eq(C.IsHidden(1822), false)
  -- "first when ready": ahead of the list whenever castable, not repeated while on cooldown
  C.SetFirst(5221, true)
  r = ns.Engine.Recommend(rec, {})
  eq(r.main.token, "shred", "Shred marked first: slot 1 although Rake comes first in the list")
  eq(r.main.source, "first")
  mock.cooldowns[5221] = { active = true, start = mock.now, duration = 30 }
  r = ns.Engine.Recommend(rec, {})
  eq(r.main.token, "rake", "on cooldown: the list again")
  mock.cooldowns[5221] = nil
  C.SetHidden(5221, true)
  eq(#C.FirstSpells(), 0, "hidden beats first")
  C.SetHidden(5221, false)
  C.SetFirst(5221, false)
end)

test("training dummies that never show as in combat are counted while you fight", function()
  Reset()
  local ns = Boot()
  mock.nameplates = 6
  mock.plateCombat = { false, false, false, false, false, false }
  mock.plateNames = {}
  for i = 1, 6 do
    mock.plateNames[i] = "Cleave Training Dummy"
  end
  eq(ns.State.CountEnemies(), 0, "out of combat: not counted")
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  eq(ns.State.CountEnemies(), 6, "in combat: the dummies in range count")
  eq(ns.State.lastCount.dummies, 6)
  mock.plateNames[1] = "Angry Gnoll" -- a real enemy still needs its combat flag
  ns.State.ForgetEnemies()
  eq(ns.State.CountEnemies(), 5)
  mock.Fire("PLAYER_REGEN_ENABLED")
  mock.inCombat = false
  mock.nameplates, mock.plateCombat, mock.plateNames = 0, nil, nil
end)

test("charges: the game's count counts in the look-ahead too, and each predicted cast spends one", function()
  Reset()
  local book = {}
  for i, b in ipairs(FERAL_BOOK) do
    book[i] = b
  end
  book[#book + 1] = { spellID = 22842, name = "Frenzied Regeneration" }
  mock.book = book
  local ns = Boot()
  local S = ns.State
  mock.charges = { [22842] = { 0, 1 } }
  S.BeginLookahead(0)
  eq(S.Charges(22842), 0, "the game says none left: none, also while looking ahead")
  S.EndLookahead()
  mock.charges = { [22842] = { 1, 1 } }
  S.BeginLookahead(0)
  eq(S.Charges(22842), 1)
  S.Apply(22842)
  eq(S.Charges(22842), 0, "a predicted cast spends the charge")
  S.EndLookahead()
  mock.charges = nil
end)

test("a spell a button turns into is checked as itself, not as the button's base spell (Void Volley)", function()
  Reset()
  local ns = Boot()
  local M = ns.SpellMap
  mock.overrides = { [22568] = 441591 } -- Ferocious Bite's button casts Ravage now
  mock.Advance(1) -- the button overrides are re-read at most twice a second
  eq(M.SpellID("ravage"), 441591, "the spell the button casts")
  eq(M.baseOf[441591], 22568, "its button remembered for the key and highlight")
  -- the base on cooldown says nothing about the override's own readiness
  mock.cooldowns[22568] = { active = true, start = mock.now, duration = 30 }
  eq(ns.Engine.Castable(441591) ~= false, true, "Ravage is not held back by Bite's cooldown")
  mock.overrides = nil
  mock.cooldowns[22568] = nil
end)

test("self-heals only at or below the health setting, never in raids unless switched on", function()
  Reset()
  local ns = Boot()
  local G = ns.Engine
  local hp = 900
  local old = { UnitHealth, UnitHealthMax, IsInInstance }
  UnitHealth = function() return hp end
  UnitHealthMax = function() return 1000 end
  eq(G.NotHurtSkip("desperate_prayer"), true, "90 %: no self-heal")
  hp = 300
  eq(G.NotHurtSkip("desperate_prayer"), false, "30 % (default threshold 35 %): suggested")
  ns.db.healAt = 0
  eq(G.NotHurtSkip("desperate_prayer"), true, "0 = never")
  ns.db.healAt = 35
  IsInInstance = function() return true, "raid" end
  eq(G.NotHurtSkip("desperate_prayer"), true, "raid: off by default")
  ns.db.healInRaids = true
  eq(G.NotHurtSkip("desperate_prayer"), false, "raid, switched on")
  ns.db.healInRaids = false
  eq(G.NotHurtSkip("regrowth"), false, "Feral's Regrowth is rotation (Bloodtalons), not a heal")
  UnitHealth, UnitHealthMax, IsInInstance = old[1], old[2], old[3]
end)

test("/dmga test defensive: a pretend boss-mod call shows the first defensive that is ready", function()
  Reset()
  local book = {}
  for i, b in ipairs(FERAL_BOOK) do
    book[i] = b
  end
  book[#book + 1] = { spellID = 22812, name = "Barkskin" }
  book[#book + 1] = { spellID = 61336, name = "Survival Instincts" }
  mock.book = book
  local ns = Boot()
  SlashCmdList.DMGASSIST("test defensive")
  local d = ns.Defensives.Evaluate()
  eq(d and d.why, "bossmod")
  eq(d.id, 22812, "the lighter one first")
  mock.cooldowns[22812] = { active = true, start = mock.now, duration = 60 }
  ns.State.lastCast[22812] = mock.now
  d = ns.Defensives.Evaluate()
  eq(d and d.id, 61336, "on cooldown: the next one")
  mock.Advance(9)
  eq(ns.Defensives.Evaluate() == nil or ns.Defensives.Evaluate().why ~= "bossmod", true, "the test ends")
end)

test("keybind of a spell a button turns into is the button's key, found again after the button changes", function()
  Reset()
  mock.bindings = { ACTIONBUTTON4 = "4" }
  mock.actionInfo = { [4] = { "spell", 22568 } }
  local ns = Boot()
  ns.Display.InvalidateKeybinds()
  eq(ns.Display.Keybind(441591), nil, "Ravage, before the button turns into it: no key yet")
  mock.overrides = { [22568] = 441591 }
  mock.Advance(1)
  eq(ns.Display.Keybind(441591), "4", "the button now casts it: its key (no stale 'none')")
  mock.overrides, mock.actionInfo, mock.bindings = nil, nil, nil
end)

test("a run_action_list into a list with nothing to show does not stop the list (Restoration's healing)", function()
  Reset()
  local ns = Boot()
  local rec = Record()
  rec.blizzard = nil
  rec.simc = {
    default = {
      { a = "run_action_list", k = "R", p = { name = "healing", line_cd = "12" } },
      { a = "shred", k = "R" },
    },
    healing = { { a = "strict_sequence", k = "R", p = { name = "heal:regrowth:regrowth" } } },
  }
  local r = ns.Engine.Recommend(rec, {})
  eq(r.main and r.main.token, "shred", "the cat-weaving part is reached")
end)

test("Discipline: Atonements counted from our casts; ramp with Radiance, then Shield, before a big hit", function()
  Reset()
  local ns = Boot()
  local X, M = ns.Essentials, ns.SpellMap
  local oldSpec, oldSpellID, oldNext, oldIPS = ns.Specs.current, M.SpellID, ns.BossMods.Next, IsPlayerSpell
  ns.Specs.current = { key = "priest_discipline", status = "ready" }
  M.byID[17], M.byID[194509], M.byID[472433] = "power_word_shield", "power_word_radiance", "evangelism"
  IsPlayerSpell = function() return true end
  local ids = { power_word_radiance = 194509, power_word_shield = 17 }
  M.SpellID = function(token) return ids[token] end
  X.stacks[194509] = {}
  X.OnOwnCast(17)
  eq(X.Stacks(194509), 1, "Shield: one Atonement")
  X.OnOwnCast(194509)
  eq(X.Stacks(194509), 6, "Radiance: five more")
  mock.Advance(10)
  eq(X.Stacks(194509), 1, "Radiance's run out (9 s), Shield's still up (15 s)")
  X.OnOwnCast(472433)
  mock.Advance(10)
  eq(X.Stacks(194509), 1, "Evangelism extended it")
  -- ramp: an AoE in 5 s, fewer than 5 counted
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  ns.BossMods.Next = function(kind) return kind == "aoe" and 5 or nil end
  local r = X.Apply({ main = { id = 5221, token = "shred" }, queue = { { id = 5221, token = "shred" } } })
  eq(r.main.token, "power_word_radiance", "ramp: Radiance first")
  mock.cooldowns[194509] = { active = true, start = mock.now, duration = 18 }
  ns.State.lastCast[194509] = mock.now
  r = X.Apply({ main = { id = 5221, token = "shred" }, queue = { { id = 5221, token = "shred" } } })
  eq(r.main.token, "power_word_shield", "Radiance on cooldown: Shield")
  ns.BossMods.Next = function() return nil end
  r = X.Apply({ main = { id = 5221, token = "shred" }, queue = { { id = 5221, token = "shred" } } })
  eq(r.main.token, "shred", "no big hit coming: the damage list")
  mock.Fire("PLAYER_REGEN_ENABLED")
  mock.inCombat = false
  ns.Specs.current, M.SpellID, ns.BossMods.Next, IsPlayerSpell = oldSpec, oldSpellID, oldNext, oldIPS
end)

test("spells on cooldown or unusable are skipped", function()
  Reset()
  local ns = Boot()
  mock.cooldowns[22568] = { active = true, start = 999, duration = 10 } -- bite on cooldown
  mock.usable[106951] = { false, false }                              -- berserk not usable
  mock.auras.target = {
    { name = "Rip", duration = 24, expirationTime = mock.now + 20 },
    { name = "Rake", duration = 15, expirationTime = mock.now + 12 },
  }
  mock.Fire("UNIT_AURA", "target")
  local r = ns.Engine.Recommend(Record(), {})
  -- rip ticking, bite on cooldown; back in default: rake ticking, shred certain
  eq(r.main.token, "shred")
  eq(r.vars.big, 15, "precombat set + add")
end)

test("an UNKNOWN line wins only when the assistant agrees", function()
  Reset()
  local ns = Boot()
  Restrict()
  mock.acSpell = 1079 -- assistant says Rip
  local r = ns.Engine.Recommend(Record(), { useAssisted = true })
  eq(r.main.token, "rip")
  eq(r.main.source, "simc+assisted")
end)

test("major cooldowns: the assistant never names them, so Blizzard's rules confirm them", function()
  Reset()
  local ns = Boot()
  local rec = Record()
  rec.simc.default[1].c = "debuff.someone_elses.up" -- hidden in combat: berserk's line is UNKNOWN
  Restrict()
  mock.acSpell = 106830 -- the assistant says Thrash (it never says Berserk)
  local r = ns.Engine.Recommend(rec, { useAssisted = true })
  eq(r.main.token, "berserk")
  eq(r.main.source, "simc+rules")
end)

test("a key spell SimC keeps wanting comes in once it has waited long enough", function()
  Reset()
  local ns = Boot()
  local rec = Record()
  rec.simc.finisher = {}
  rec.simc.default[4].c = "!debuff.someone_elses.up" -- rake: UNKNOWN in combat
  Restrict()
  mock.Fire("PLAYER_REGEN_DISABLED")
  ns.State.learned.cd[1822] = 30 -- rake as a 30 s cooldown: a "key" spell
  mock.acSpell = 106830           -- the assistant keeps saying Thrash
  local r = ns.Engine.Recommend(rec, { useAssisted = true })
  eq(r.main.token ~= "rake", true, "not yet: " .. tostring(r.main.token))
  for _ = 1, 5 do
    mock.now = mock.now + 1
    r = ns.Engine.Recommend(rec, { useAssisted = true })
  end
  eq(r.main.token, "rake")
  eq(r.main.source, "simc+waited")
  -- a filler (no cooldown) never escalates
  Reset()
  ns = Boot()
  Restrict()
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.acSpell = 106830
  for _ = 1, 8 do
    mock.now = mock.now + 1
    r = ns.Engine.Recommend(rec, { useAssisted = true })
  end
  eq(r.main.token ~= "rake", true, "filler stayed out: " .. tostring(r.main.token))
end)

test("steady slot 1: short flips never show, nothing changes while you reach for it, a press shows the new pick", function()
  Reset()
  local ns = Boot()
  local G = ns.Engine
  mock.Fire("PLAYER_REGEN_DISABLED")
  G.ResetSteady()
  local rip, shred, rake = { id = 1079, token = "rip" }, { id = 5221, token = "shred" }, { id = 1822, token = "rake" }
  local function gcd(left) -- a long cast-time GCD, so there's a mid-GCD stretch to test
    mock.cooldowns[61304] = { start = mock.now - (2.5 - left), duration = 2.5, active = left > 0 }
  end
  gcd(2.4) -- just pressed something
  local r = G.Steady({ main = rip, queue = { rip, shred, rake } })
  eq(r.main.token, "rip")
  mock.now = mock.now + 0.1
  r = G.Steady({ main = shred, queue = { shred, rip, rake } })
  eq(r.main.token, "rip", "a 0.1 s flip: held")
  eq(r.queue[2].token, "shred", "the new pick is next")
  eq(r.queue[3].token, "rake")
  eq(#r.queue, 3)
  mock.now = mock.now + 0.1
  r = G.Steady({ main = rake, queue = { rake, rip, shred } })
  eq(r.main.token, "rip", "flipping on to a third spell: still held")
  mock.now = mock.now + 0.1
  G.Steady({ main = shred, queue = { shred, rip, rake } })
  mock.now = mock.now + 0.55
  r = G.Steady({ main = shred, queue = { shred, rip, rake } })
  eq(r.main.token, "shred", "mid-GCD, a change that holds for 0.5 s shows")
  -- the last moments before the press: nothing changes, however long the new pick holds
  mock.now = mock.now + 1.0
  r = G.Steady({ main = rake, queue = { rake, shred, rip } })
  eq(r.main.token, "shred", "reaching for it: frozen")
  eq(r.queue[2].token, "rake", "the newly ready spell waits in slot 2")
  mock.now = mock.now + 0.8
  r = G.Steady({ main = rake, queue = { rake, shred, rip } })
  eq(r.main.token, "shred", "still frozen while it sits ready")
  -- a press (a new GCD starts): the new pick at once
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5221)
  gcd(2.5)
  r = G.Steady({ main = rake, queue = { rake, rip, shred } })
  eq(r.main.token, "rake", "after a press: at once")
  mock.cooldowns[61304] = nil
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

test("skipping the slot-1 spell three times holds it until combat ends; casting it brings it back", function()
  Reset()
  local ns = Boot()
  local G = ns.Engine
  mock.Fire("PLAYER_REGEN_DISABLED")
  local r = ns.Engine.Recommend(Record(), {})
  eq(r.main.token, "rip")
  -- a spell without a long cooldown (a DoT, a builder) is never held: skipping it means "not this GCD"
  eq(G.OnPlayerCast(106830, r.main), nil)
  eq(G.OnPlayerCast(106830, r.main), nil)
  eq(G.IsHeld(1079), false, "no cooldown: not held")
  G.skips = {}
  ns.State.learned.cd[1079] = 120 -- treat it as a big cooldown for the rest of the test
  ns.State.learned.cd[5221] = 30 -- slot 2 is another cooldown
  eq(G.OnPlayerCast(5221, r.main, true, { r.main, { id = 5221 } }), nil, "casting another cooldown from slot 2 is no skip")
  eq(G.OnPlayerCast(5221, r.main, true, { r.main, { id = 5221 } }), nil)
  eq(G.IsHeld(1079), false)
  ns.State.learned.cd[5221] = nil
  eq(G.OnPlayerCast(5221, r.main, true, { r.main, { id = 5221 } }), nil, "a filler from slot 2: first skip")
  eq(G.OnPlayerCast(5221, r.main, true, { r.main, { id = 5221 } }), nil, "second skip")
  eq(G.OnPlayerCast(5221, r.main, true, { r.main, { id = 5221 } }), "held", "a filler from slot 2 three times holds it")
  G.held, G.skips = {}, {}
  eq(G.OnPlayerCast(106830, r.main), nil, "one skip is not enough")
  eq(G.OnPlayerCast(106830, r.main), nil, "two are not enough either")
  eq(G.OnPlayerCast(106830, r.main), "held", "third skip holds it")
  r = ns.Engine.Recommend(Record(), {})
  for _, p in ipairs(r.queue) do
    eq(p.token ~= "rip", true, "held: in no slot")
  end
  eq(ns.Display.HeldText():find("1 held", 1, true) ~= nil, true)
  eq(G.OnPlayerCast(1079, r.main), "released", "cast it yourself: it is back")
  r = ns.Engine.Recommend(Record(), {})
  eq(r.main.token, "rip")
  -- interrupts, guesses and switched off: no skips counted
  eq(G.OnPlayerCast(106830, { id = 1079, source = "interrupt" }), nil)
  eq(G.OnPlayerCast(106830, { id = 1079, source = "interrupt" }), nil)
  eq(G.OnPlayerCast(106830, r.main, false), nil)
  eq(G.OnPlayerCast(106830, r.main, false), nil)
  eq(G.IsHeld(1079), false)
  -- a new fight starts clean
  G.OnPlayerCast(106830, r.main)
  G.OnPlayerCast(106830, r.main)
  G.OnPlayerCast(106830, r.main)
  eq(G.IsHeld(1079), true)
  mock.Fire("PLAYER_REGEN_ENABLED")
  eq(G.IsHeld(1079), false, "combat ended: released")
end)

test("major cooldowns on bosses and big pulls only (optional)", function()
  Reset()
  local ns = Boot()
  eq(ns.BurstAllowed(), true, "default: every fight")
  ns.db.burstWhen = "big"
  mock.inCombat, mock.nameplates = true, 2
  mock.Fire("PLAYER_REGEN_DISABLED")
  eq(ns.BurstAllowed(), false, "two enemies: trash, save them")
  mock.nameplates = 6
  eq(ns.BurstAllowed(), true, "a big pull")
  ns.db.burst = false
  eq(ns.BurstAllowed(), false, "off is off")
  mock.inCombat, mock.nameplates = false, 0
end)

test("on Forever an UNKNOWN line can be corroborated by Blizzard's rule", function()
  Reset()
  local ns = Boot("camelot", 18)
  local rec = Record()
  rec.simc.finisher = {}
  rec.simc.default[4].c = "!debuff.someone_elses.up" -- not our debuff: hidden in combat
  mock.cooldowns[5221] = { active = true, start = 999, duration = 10 } -- shred on cooldown
  Restrict()
  -- rake's condition is UNKNOWN; Blizzard's rake rule (combo_points<5) is UNKNOWN too: no corroboration.
  -- (Major cooldowns off: with them on, Blizzard's unconditional Berserk would rightly come first.)
  local r = ns.Engine.Recommend(rec, { burst = false })
  eq(r.main.token, "thrash", "falls back to Blizzard's rules")
  eq(r.main.source, "rules")
  rec.blizzard.default[2].c = "level>10"
  r = ns.Engine.Recommend(rec, { burst = false })
  eq(r.main.token, "rake")
  eq(r.main.source, "simc+rules")
end)

test("restricted combat: secret resources become UNKNOWN, nothing errors", function()
  Reset()
  local ns = Boot()
  Restrict()
  eq(ns.State.Resolve("combo_points", {}), ns.Expr.UNKNOWN)
  eq(ns.State.Resolve("cooldown.tigers_fury.ready", {}), 1, "isActive is never secret")
  eq(ns.State.Resolve("gcd", {}) > 0, true)
  local rec = Record()
  rec.simc.default[4].c = "!debuff.someone_elses.up"
  local r = ns.Engine.Recommend(rec, { useAssisted = true })
  -- finisher list is UNKNOWN (combo points), rake UNKNOWN (someone else's debuff), shred certain
  eq(r.main.token, "shred")
end)

---------------------------------------------------------------------------
-- Tracking
---------------------------------------------------------------------------
test("cooldown durations are learned out of combat and count down in combat", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  mock.cooldowns[5217] = { active = true, start = mock.now, duration = 30 }
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  mock.Advance(0.2)
  eq(S.learned.cd[5217], 30)
  -- now restricted: duration secret, our clock answers
  mock.restricted = true
  mock.Advance(10)
  local left = S.Resolve("cooldown.tigers_fury.remains", {})
  eq(math.floor(left + 0.5), 20)
  eq(S.Resolve("cooldown.tigers_fury.ready", {}), 0)
  -- the learned value is saved per spec
  eq(DMGAssistDB.learned.druid_feral.cd[5217], 30)
end)

test("secret cast events are counted; cooldown edges still reveal the cast", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  mock.restricted, mock.inCombat = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Fire("SPELL_UPDATE_COOLDOWN")              -- baseline: nothing active
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", mock.Secret())
  eq(S.castsSecret, 1)
  mock.cooldowns[106951] = { active = true, start = mock.now, duration = 180 }
  mock.Fire("SPELL_UPDATE_COOLDOWN")
  eq(S.castsInferred, 1)
  eq(S.history[1].id, 106951)
  eq(S.Resolve("prev_gcd.1.berserk", {}), 1)
  eq(S.Resolve("prev_gcd.1.shred", {}), 0)
end)

test("buff durations learned while readable drive our own clock in combat", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  -- Out of combat: cast Tiger's Fury, the buff appears and is readable.
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  mock.auras.player = { { name = "Tiger's Fury", spellId = 5217, duration = 15, expirationTime = mock.now + 15,
    applications = 0 } }
  mock.Fire("UNIT_AURA", "player")
  eq(S.Resolve("buff.tigers_fury.up", {}), 1)
  eq(S.learned.aura.tigers_fury.duration, 15)
  mock.auras.player = {}
  mock.Advance(16)
  mock.Fire("UNIT_AURA", "player")
  eq(S.Resolve("buff.tigers_fury.up", {}), 0)
  -- In combat auras are secret; a new cast starts our clock.
  mock.restricted, mock.inCombat = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Fire("UNIT_AURA", "player")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  eq(S.Resolve("buff.tigers_fury.up", {}), 1)
  eq(S.Resolve("buff.tigers_fury.down", {}), 0)
  mock.Advance(10)
  eq(math.floor(S.Resolve("buff.tigers_fury.remains", {}) + 0.5), 5)
  mock.Advance(6)
  eq(S.Resolve("buff.tigers_fury.up", {}), 0)
  eq(S.Resolve("buff.never_seen.up", {}), ns.Expr.UNKNOWN)
end)

---------------------------------------------------------------------------
-- Whole addon with real data
---------------------------------------------------------------------------
for _, client in ipairs({ { "standard", 1, "Midnight" }, { "camelot", 18, "Forever" } }) do
  test(client[3] .. ": Feral with real SimC data shows a spell, in and out of restrictions", function()
    Reset()
    local ns = Boot(client[1], client[2])
    eq(ns.Specs.current.status, "ready")
    local r = ns.Update()
    eq(type(r), "table", "no result")
    eq(type(r.main), "table", "no main pick")
    eq(type(r.main.id), "number")
    eq(ns.Display.frame.main.tex.texture, 1000000 + r.main.id, "icon not drawn")
    eq(ns.Display.frame:IsShown(), true)
    Restrict()
    r = ns.Update()
    eq(type(r.main), "table", "no pick in restricted combat")
    -- no target, out of combat: hidden
    mock.restricted, mock.inCombat, mock.hasTarget = false, false, false
    mock.Fire("PLAYER_REGEN_ENABLED")
    eq(ns.Update(), nil)
    eq(ns.Display.frame:IsShown(), false)
  end)
end

test("slash commands change settings", function()
  Reset()
  local ns = Boot()
  SlashCmdList.DMGASSIST("burst")
  eq(ns.db.burst, false)
  SlashCmdList.DMGASSIST("burst")
  eq(ns.db.burst, true)
  SlashCmdList.DMGASSIST("mode aoe")
  eq(ns.db.mode, "aoe")
  eq(ns.State.Targets(), 2, "Feral's own list switches to AoE at 2 targets")
  SlashCmdList.DMGASSIST("targets 5")
  eq(ns.State.Targets(), 5)
  SlashCmdList.DMGASSIST("off")
  eq(ns.Update(), nil)
  SlashCmdList.DMGASSIST("on")
  SlashCmdList.DMGASSIST("why")
  SlashCmdList.DMGASSIST("help")
end)

test("picks are logged to the Watchdog once per change", function()
  Reset()
  local logged = {}
  DMGAssistWatchdog = { Log = function(kind) logged[#logged + 1] = kind end }
  local ns = Boot()
  ns.Update()
  ns.Update()
  ns.Update()
  DMGAssistWatchdog = nil
  local picks = 0
  for _, k in ipairs(logged) do
    if k == "pick" then
      picks = picks + 1
    end
  end
  eq(picks, 1)
  eq(ns.U.Flatten({ b = 1, a = "x", t = { k = 2 } }), "a=x b=1 t={k:2}")
  eq(ns.U.Flatten({ s = mock.Secret() }), "s=<secret>", "secrets are never stringified")
end)

---------------------------------------------------------------------------
-- SimC spell data, look-ahead queue, modes, languages
---------------------------------------------------------------------------
-- A record with SimC-style spell data (ids, costs, gains, cooldowns, auras).
local function QRecord(default)
  return {
    key = "druid_feral",
    simc = { default = default },
    spells = {
      rip = { a = { 1079 }, b = { 1079 } }, shred = { a = { 5221 } }, tigers_fury = { a = { 5217 }, b = { 5217 } },
      ferocious_bite = { a = { 22568 } },
    },
    spellInfo = {
      [1079] = { n = "rip", cost = { [3] = 20, [4] = 1 }, cmax = { [4] = 5 }, d = 24, gcd = 1, ap = { { 1079, "enemy" } } },
      [5221] = { n = "shred", cost = { [3] = 40 }, gain = { [4] = 1 }, gcd = 1 },
      [5217] = { n = "tigers_fury", cd = 30, d = 10, gain = { [3] = 50 }, ap = { { 5217, "self" } } },
      [22568] = { n = "ferocious_bite", cost = { [3] = 25, [4] = 1 }, cmax = { [4] = 5 }, gcd = 1 },
    },
  }
end

local function Tokens(r)
  local out = {}
  for i, p in ipairs(r.queue or {}) do
    out[i] = tostring(p.token)
  end
  return table.concat(out, " > ")
end

local function Feral(ns, rec)
  ns.SpellMap.SetData(rec)
  mock.power[3], mock.powerMax[3] = 100, 100
  mock.power[4], mock.powerMax[4] = 0, 5
end

test("real cooldowns: the game's own recharge on load, and casts sooner than our data allows correct it", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  local rec = QRecord({ { a = "tigers_fury", k = "R" } })
  rec.spellInfo[5217] = { n = "tigers_fury", ch = 1, chcd = 11, gcd = 1.5 } -- SimC's number: 11 s
  Feral(ns, rec)
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  mock.Advance(6)
  eq(S.Charges(5217), 0, "by our data it's still recharging")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217) -- the player cast it: it was ready after 6 s
  eq(math.floor(S.learned.timing.tigers_fury.mean + 0.5), -5, "learned: our clock was 5 s late")
  mock.Advance(6.1)
  eq(S.Charges(5217), 1, "ready again after 6 s, not 11")
  mock.inCombat, mock.restricted = false, false
end)

test("Bloodlust and Power Infusion from the size of the haste jump, whoever cast them", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  Restrict() -- haste and buffs hidden
  S.OnHasteChanged() -- the game says haste changed, not by how much
  S.OnMeasuredGCD(1.5 / 1.3, 1.5)
  eq(S.boost.lust, nil, "one global cooldown is not enough")
  S.OnMeasuredGCD(1.5 / 1.3, 1.5)
  eq(S.boost.lust ~= nil, true, "+30% held for two global cooldowns: Bloodlust")
  eq(S.Resolve("buff.bloodlust.up", {}), 1)
  eq(S.Resolve("buff.heroism.up", {}), 1, "its twins too")
  eq(S.Resolve("buff.bloodlust.remains", {}) > 39, true)
  mock.Advance(41)
  eq(S.Resolve("buff.bloodlust.up", {}), 0, "40 s later it's over")
  eq(math.abs(S.HasteFactor() - 1) < 0.02, true, "and its haste goes with it")
  -- a small proc is not Bloodlust
  S.OnHasteChanged()
  S.OnMeasuredGCD(1.5 / 1.06, 1.5)
  S.OnMeasuredGCD(1.5 / 1.06, 1.5)
  eq(S.boost.lust, nil)
  eq(S.boost.power_infusion, nil)
  mock.restricted, mock.inCombat = false, false
end)

test("execute range: the assistant naming an execute spell means the target is below its health line", function()
  Reset()
  local ns = Boot()
  local S, C = ns.State, ns.Clues
  C.EXECUTE.shred = 20 -- stand-in for Hammer of Wrath / Kill Shot / Execute in the Feral test book
  Restrict()
  mock.acSpell = 5221
  local rec = Record()
  ns.Engine.Recommend(rec, { useAssisted = true })
  local _, hi = S.Bounds("target.health.pct")
  eq(hi ~= nil and hi < 20, true, "below 20%")
  mock.acSpell = nil
  ns.Engine.Recommend(rec, { useAssisted = true })
  _, hi = S.Bounds("target.health.pct")
  eq(hi ~= nil and hi < 20, true, "health only goes down: it stays known for this target")
  mock.Fire("PLAYER_TARGET_CHANGED")
  eq(S.Bounds("target.health.pct"), nil, "a new target: unknown again")
  S.glow[5221] = true -- a proc lit the button: castable at any health, tells us nothing
  mock.acSpell = 5221
  ns.Engine.Recommend(rec, { useAssisted = true })
  eq(S.Bounds("target.health.pct"), nil)
  S.glow[5221], C.EXECUTE.shred, mock.acSpell = nil, nil, nil
  mock.restricted, mock.inCombat = false, false
end)

test("energy and focus come back during the look-ahead, faster with haste", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  mock.power[3], mock.powerMax[3] = 20, 100
  S.BeginLookahead(2)
  eq(S.PowerNow(3), 40, "10 energy a second")
  S.EndLookahead()
  mock.haste = 30
  S.BeginLookahead(2)
  eq(math.floor(S.PowerNow(3) + 0.5), 46, "13 a second with 30% haste")
  S.EndLookahead()
  mock.haste = nil
end)

test("charges: the game's count for the ID the engine uses, never raised from the assistant's picks", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  local rec = QRecord({ { a = "tigers_fury", k = "R" } })
  rec.spellInfo[5217] = { n = "tigers_fury", ch = 1, chcd = 6, gcd = 1.5 } -- SimC: one charge
  Feral(ns, rec)
  mock.charges = { [5217] = { 2, 2 } } -- the game: two
  S.Calibrate()
  eq(S.liveCharges.tigers_fury and S.liveCharges.tigers_fury.max, 2, "read out of combat")
  mock.inCombat, mock.restricted = true, true
  mock.charges = nil
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  eq(S.Charges(5217), 1, "one cast: one left, not zero")
  -- unreadable game data: the assistant naming it while we count zero teaches the extra charge
  S.liveCharges = {}
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  eq(S.Charges(5217), 0)
  S.ObserveAssistedCharge(5217)
  eq(S.liveCharges.tigers_fury, nil, "the count is never raised from the assistant's picks")
  mock.inCombat, mock.restricted = false, false
end)

test("spell interdependencies: casting one spell takes time off another (Shield of the Righteous -> Holy Shock)", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  local rec = QRecord({ { a = "tigers_fury", k = "R" } })
  rec.spellInfo[5217] = { n = "tigers_fury", ch = 1, chcd = 6, gcd = 1.5 }
  rec.cdLinks = { { "ferocious_bite", "tigers_fury", 2, 0, 0 }, { "*", "tigers_fury", 0.5, 0, 4 } }
  Feral(ns, rec)
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  mock.Advance(2)
  eq(S.Charges(5217), 0)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 22568) -- Bite: 2 s off, and 0.5 s per combo point (5)
  eq(math.floor(S.ChargeRemains(5217) * 10 + 0.5) / 10, 0, "6 - 2 elapsed - 2 - 2.5: ready now")
  -- the look-ahead sees it too
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  S.BeginLookahead(0)
  eq(S.Charges(5217), 0)
  S.Apply(22568)
  eq(S.Charges(5217), 0, "1.5 s left after Bite in the look-ahead")
  S.EndLookahead()
  S.BeginLookahead(1.6)
  S.Apply(22568)
  eq(S.Charges(5217), 1, "and back by the next GCD")
  S.EndLookahead()
  mock.inCombat, mock.restricted = false, false
end)

test("Bloodlust with readable haste: the jump is compared with the value before it", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  mock.haste = 10
  S.HasteFactor()
  mock.haste = 43 -- out of combat (after a fight): not a boost
  S.HasteFactor()
  eq(S.boost.lust, nil, "out of combat: no boost")
  mock.haste = 10
  S.HasteFactor()
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.haste = 43 -- 1.10 -> 1.43: x1.3
  S.HasteFactor() -- read before the event arrives
  S.OnHasteChanged()
  eq(S.boost.lust ~= nil, true, "detected")
  mock.haste = nil
  mock.inCombat = false
end)

test("Blizzard naming a spell our clock says is well off: our clock is wrong, it's ready; a moment early: ours stands", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  local rec = QRecord({ { a = "tigers_fury", k = "R" } })
  rec.spellInfo[5217] = { n = "tigers_fury", ch = 1, chcd = 16, gcd = 1.5 }
  Feral(ns, rec)
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  mock.Advance(14)
  S.acNamed = nil
  S.ObserveAssistedCharge(5217)
  eq(S.Charges(5217), 0, "2 s left: Blizzard may name it a moment early, our timing stands")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  mock.Advance(3)
  S.acNamed = nil
  S.ObserveAssistedCharge(5217)
  eq(S.Charges(5217), 1, "13 s left by our clock: ours is wrong, ready now")
  mock.inCombat, mock.restricted = false, false
end)

test("auras Blizzard leaves readable in combat (Tip of the Spear, Sated) are read directly", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  local rec = QRecord({ { a = "tigers_fury", k = "R" } })
  rec.spells.tip_of_the_spear = { b = { 260286 } }
  rec.spellInfo[260286] = { n = "tip_of_the_spear", d = 10, st = 3 }
  Feral(ns, rec)
  Restrict()
  mock.directAuras = { [260286] = { expirationTime = GetTime() + 6, applications = 2 } }
  mock.Advance(0.01)
  eq(S.Resolve("buff.tip_of_the_spear.stack", {}), 2, "stacks read in combat")
  mock.directAuras = {}
  mock.Advance(0.01)
  eq(S.Resolve("buff.tip_of_the_spear.up", {}), 0, "seen readable before: its absence is known too")
  -- Bloodlust from Sated, applied 10 s ago
  mock.directAuras = { [57724] = { expirationTime = GetTime() + 590, applications = 0 } }
  mock.Advance(0.01)
  eq(math.floor(S.Resolve("buff.bloodlust.remains", {}) + 0.5), 30)
  mock.directAuras = nil
  mock.restricted, mock.inCombat = false, false
end)

test("timing learning: steady errors correct our clock, scattered ones leave the spell to Blizzard", function()
  Reset()
  local ns = Boot()
  local S, G = ns.State, ns.Engine
  local rec = QRecord({ { a = "tigers_fury", k = "R" } })
  rec.spellInfo[5217] = { n = "tigers_fury", cd = 30, gcd = 1.5 }
  Feral(ns, rec)
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  -- steady: always about 2 s longer than our clock (a talent we don't know about)
  S.LearnTiming(5217, 2.0, "waited")
  for _ = 1, 3 do
    S.LearnTiming(5217, 0, "waited") -- measured against the corrected clock: nothing left over
  end
  eq(S.ClockUnreliable(5217), false, "consistent: still ours")
  eq(math.floor(S.CooldownLength(5217) + 0.5), 32, "corrected by 2 s")
  -- scattered: 4 s early, 7 s late, 2 s early...
  S.learned.timing = {}
  for _, e in ipairs({ -4, 7, -2, 6 }) do
    S.LearnTiming(5217, e, "assisted")
  end
  eq(S.ClockUnreliable(5217), true, "erratic: Blizzard decides")
  G.acNow = nil
  S.ForgetTalentCache()
  eq(G.Castable(5217) ~= false, true, "Blizzard can't suggest it (not in its rotation): our clock still decides")
  mock.rotationSpells = { 5217 }
  S.ForgetTalentCache()
  eq(G.Castable(5217), false, "ready by our clock alone isn't trusted")
  G.acNow = 5217
  eq(G.Castable(5217), true, "Blizzard names it: ready")
  G.acNow = nil
  -- Blizzard agreeing with our clock 4 times un-flags it
  for _ = 1, 4 do
    S.acNamed = nil -- Blizzard named something else in between
    S.ObserveAssistedCharge(5217) -- never cast: ready by our clock too
  end
  eq(S.ClockUnreliable(5217), false, "agreed 4 times: ours again")
  -- shipped flagged, learned otherwise
  S.learned.timing = {}
  ns.SpellMap.volatile = { tigers_fury = true }
  eq(S.ClockUnreliable(5217), true, "the shipped list starts it flagged")
  ns.SpellMap.volatile = {}
  mock.rotationSpells = nil
  -- the reset in Settings / /dmga relearn: refused in combat, then forgets everything learned
  S.LearnTiming(5217, 2.0, "waited")
  eq(S.ResetLearning(), false, "not in combat")
  mock.inCombat, mock.restricted = false, false
  mock.Fire("PLAYER_REGEN_ENABLED")
  eq(S.ResetLearning(), true, "out of combat")
  eq(next(S.learned.timing), nil, "learned timing forgotten")
end)

test("timing learning: we showed it ready, you waited and cast it later: our clock was early", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  local rec = QRecord({ { a = "tigers_fury", k = "R" } })
  rec.spellInfo[5217] = { n = "tigers_fury", cd = 30, gcd = 1.5 }
  Feral(ns, rec)
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  S.NoteReadyShown(5217)
  mock.Advance(2.4)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  local t = S.learned.timing.tigers_fury
  eq(t and math.floor(t.mean * 10 + 0.5) / 10, 2.0, "waited 2.4 s - 0.4 s reaction")
  -- casting something else in between: not a measurement
  S.learned.timing = {}
  S.NoteReadyShown(5217)
  mock.Advance(2)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5221)
  mock.Advance(2)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  eq(S.learned.timing.tigers_fury == nil or S.learned.timing.tigers_fury.n <= 1, true)
  mock.inCombat, mock.restricted = false, false
end)

test("timing learning: pressing until it goes through measures our clock exactly; never counts as a skip", function()
  Reset()
  local ns = Boot()
  local S, G = ns.State, ns.Engine
  local rec = QRecord({ { a = "tigers_fury", k = "R" } })
  rec.spellInfo[5217] = { n = "tigers_fury", cd = 30, gcd = 1.5 }
  Feral(ns, rec)
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  -- slot 1 shows it ready; you press 2222 and the game refuses until 1.8 s later
  S.NoteReadyShown(5217)
  for _ = 1, 4 do
    mock.Advance(0.45)
    mock.Fire("UNIT_SPELLCAST_FAILED", "player", "guid", 5217)
  end
  mock.Advance(0.1)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  local t = S.learned.timing.tigers_fury
  eq(t and t.n, 1, "one measurement")
  eq(t and math.floor(t.mean * 10 + 0.5) / 10, 1.9, "our clock was early by when it went through (no reaction guess)")
  eq(G.skips[5217], nil, "refused presses of the shown spell are never a skip")
  -- measured again, with the correction applied: what's left over adds to it rather than replacing it
  S.NoteReadyShown(5217)
  mock.Advance(0.5)
  mock.Fire("UNIT_SPELLCAST_FAILED", "player", "guid", 5217)
  mock.Advance(0.5)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  eq(math.floor(t.mean * 10 + 0.5) / 10, 2.4, "1.9 applied + 1.0 left over, averaged with 1.9")
  -- a single press long ago is not "pressing until it goes through"
  S.learned.timing = {}
  S.NoteReadyShown(5217)
  mock.Fire("UNIT_SPELLCAST_FAILED", "player", "guid", 5217)
  mock.Advance(3)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  eq(S.learned.timing.tigers_fury and S.learned.timing.tigers_fury.how, nil)
  mock.inCombat, mock.restricted = false, false
end)

test("refused presses: slot 1 moves on at once; Blizzard naming it releases it; one agreement per naming", function()
  Reset()
  local ns = Boot()
  local S, G = ns.State, ns.Engine
  local rec = QRecord({ { a = "tigers_fury", k = "R" } })
  rec.spellInfo[5217] = { n = "tigers_fury", cd = 30, gcd = 1.5 }
  Feral(ns, rec)
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  G.acNow = nil
  eq(G.Castable(5217) ~= false, true, "ready by our clock (never cast)")
  -- you press it, the game refuses (no GCD running): not ready, slot 1 moves on
  mock.Fire("UNIT_SPELLCAST_FAILED", "player", "guid", 5217)
  eq(G.Castable(5217), false, "refused: held back")
  mock.Advance(0.2)
  mock.Fire("UNIT_SPELLCAST_FAILED", "player", "guid", 5217)
  mock.Advance(0.2)
  mock.Fire("UNIT_SPELLCAST_FAILED", "player", "guid", 5217)
  mock.Advance(1.5)
  eq(G.Castable(5217), false, "three refusals in a row: held 2 s")
  G.acNow = 5217
  eq(G.Castable(5217), true, "Blizzard names it: ready, hold or not")
  S.ObserveAssistedCharge(5217)
  G.acNow = nil
  eq(G.Castable(5217) ~= false, true, "the hold is over once Blizzard named it")
  -- Blizzard naming it for many frames counts as one naming
  S.learned.timing = { tigers_fury = { n = 3, mean = 0, spread = 2, agree = 0, unreliable = true } }
  S.acNamed = nil
  for _ = 1, 10 do
    S.ObserveAssistedCharge(5217)
  end
  eq(S.learned.timing.tigers_fury.agree, 1, "one naming, one agreement")
  eq(S.ClockUnreliable(5217), true, "still Blizzard's")
  mock.inCombat, mock.restricted = false, false
end)

test("your own Primal Rage cast starts the haste boost even when haste is hidden", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  local before = S.HasteFactor()
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 272678)
  eq(math.floor(S.BoostRemains("lust") + 0.5), 40)
  eq(math.floor(S.HasteFactor() / before * 100 + 0.5), 130, "30% more haste right away")
  mock.inCombat, mock.restricted = false, false
end)

test("timing learning: a 5-target pull and a single target learn separately", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  local rec = QRecord({ { a = "tigers_fury", k = "R" } })
  rec.spellInfo[5217] = { n = "tigers_fury", cd = 30, gcd = 1.5 }
  Feral(ns, rec)
  local targets = 5
  local real = S.Targets
  S.Targets = function()
    return targets
  end
  S.LearnTiming(5217, -6, "assisted")
  eq(S.learned.timing["tigers_fury@aoe"].mean, -6)
  eq(S.learned.timing.tigers_fury, nil)
  eq(math.floor(S.CooldownLength(5217) + 0.5), 24, "5 targets: corrected")
  targets = 1
  eq(math.floor(S.CooldownLength(5217) + 0.5), 24, "1 target, nothing learned yet: borrows the other band")
  S.LearnTiming(5217, 4, "assisted") -- residual against the borrowed -6: really -2 on one target
  eq(S.learned.timing.tigers_fury.mean, -2)
  eq(math.floor(S.CooldownLength(5217) + 0.5), 28, "1 target: its own number")
  targets = 5
  eq(math.floor(S.CooldownLength(5217) + 0.5), 24, "5 targets: still its own")
  S.Targets = real
end)

test("every spec ships SimC spell data (ids, cooldowns, durations)", function()
  for _, client in ipairs({ { "standard", 1, "midnight" }, { "camelot", 18, "forever" } }) do
    Reset()
    local ns = Boot(client[1], client[2])
    for key, rec in pairs(ns.Data.specs[client[3]]) do
      eq(type(rec.spellInfo), "table", key .. " has no spell data")
      eq(next(rec.spellInfo) ~= nil, true, key .. " spell data empty")
    end
    local tf = ns.Data.specs[client[3]].druid_feral.spellInfo[5217]
    eq(tf.n, "tigers_fury")
    eq(tf.cd, 30)
    if client[3] == "midnight" then
      eq(tf.gain[3], 50, "Tiger's Fury restores 50 energy on Midnight")
    else
      eq(tf.gain, nil, "Forever's Tiger's Fury restores no energy (different game data)")
    end
  end
end)

test("spells are matched by ID, so a German client works", function()
  Reset()
  mock.locale = "deDE"
  mock.book = {
    { spellID = 5217, name = "Tigerfuror" }, { spellID = 5221, name = "Schreddern" },
    { spellID = 1079, name = "Zerfetzen" }, { spellID = 22568, name = "Wilder Biss" },
  }
  local ns = Boot()
  eq(ns.SpellMap.SpellID("tigers_fury"), 5217)
  eq(ns.SpellMap.SpellID("shred"), 5221)
  eq(ns.SpellMap.SpellID("ferocious_bite"), 22568)
  local r = ns.Update()
  eq(type(r.main), "table", "German client gets a recommendation")
  eq(ns.L["Recommendations on."], "Empfehlungen an.")
end)

test("leveling: below max level with few of the list's spells, Blizzard's assistant leads; at max it doesn't", function()
  Reset()
  local ns = Boot()
  local LV = ns.Leveling
  local state = ns.Specs.current
  local savedLevel = UnitLevel
  GetMaxLevelForPlayerExpansion = function()
    return 90
  end
  UnitLevel = function()
    return 25
  end
  LV.Evaluate(state)
  eq(state.leveling, true, "level 25, a handful of spells: Blizzard leads")
  local r = ns.Leveling.Lead({ acSpell = 184575, main = { id = 20271 },
    queue = { { id = 20271 }, { id = 184575 }, { id = 35395 } } })
  eq(r.main.id, 184575, "Blizzard's pick in slot 1")
  eq(r.queue[2].id, 20271, "the priority list fills slot 2")
  eq(r.queue[3].id, 35395, "and slot 3, without repeating slot 1")
  local realCastable = ns.Engine.Castable
  ns.Engine.Castable = function(id)
    return id ~= 184575
  end
  r = ns.Leveling.Lead({ acSpell = 184575, main = { id = 20271 }, queue = { { id = 20271 }, { id = 35395 } } })
  eq(r.main.id, 20271, "Blizzard's pick on cooldown: the ready spell keeps slot 1")
  eq(r.queue[2].id, 184575, "Blizzard's pick waits in slot 2")
  ns.Engine.Castable = realCastable
  eq(ns.Describe(state):find("leveling", 1, true) ~= nil, true, "Status says so")
  ns.db.levelingMode = "simc"
  LV.Evaluate(state)
  eq(state.leveling, false, "Always DMGAssist's list")
  ns.db.levelingMode = "auto"
  UnitLevel = function()
    return 90
  end
  LV.Evaluate(state)
  eq(state.leveling, false, "max level: the list leads")
  ns.db.levelingMode = "blizzard"
  LV.Evaluate(state)
  eq(state.leveling, true, "Always Blizzard")
  ns.db.levelingMode = "auto"
  LV.Evaluate(state)
  UnitLevel, GetMaxLevelForPlayerExpansion = savedLevel, nil
end)

test("leveling: a new spell with no key gets one chat line; none when the game placed it on a keyed button", function()
  Reset()
  local ns = Boot()
  local LV = ns.Leveling
  local spells = { 5221 }
  ns.Choices.Spells = function()
    return spells
  end
  LV.baseline = nil
  LV.told = {}
  LV.OnSpellsChanged() -- first call: baseline only
  spells = { 5221, 1079 }
  local keyed = false
  local realKey = ns.Display.Keybind
  ns.Display.Keybind = function(id)
    return keyed and "1" or nil
  end
  mock.printed = {}
  LV.OnSpellsChanged()
  mock.Advance(LV.NOTICE_DELAY + 0.1)
  local said = table.concat(mock.printed, "\n")
  eq(said:find("New spell", 1, true) ~= nil, true, "told about the new spell: " .. said)
  spells = { 5221, 1079, 22568 }
  keyed = true
  mock.printed = {}
  LV.OnSpellsChanged()
  mock.Advance(LV.NOTICE_DELAY + 0.1)
  eq(#mock.printed, 0, "the game put it on a keyed button: nothing to say")
  ns.Display.Keybind = realKey
end)

test("controller keys: pad bindings read as the controller's buttons, emulated modifiers included", function()
  Reset()
  local ns = Boot()
  local D = ns.Display
  local savedCVar = GetCVar
  GetCVar = function(name)
    return name == "GamePadEmulateShift" and "PADLTRIGGER" or nil
  end
  eq(D.KeyText("PAD1"), "A")
  eq(D.KeyText("SHIFT-PAD3"), "LT+X", "the emulated Shift is the left trigger")
  ns.db.hud.padLabels = "playstation"
  eq(D.KeyText("PADRSHOULDER"), "R1")
  ns.db.hud.padLabels = "xbox"
  GetCVar = savedCVar
end)

test("public API: the recommendation for WeakAuras and UI packs, callbacks on change, HUD can be hidden", function()
  Reset()
  local ns = Boot()
  local API = DMGAssistAPI
  eq(type(API), "table")
  local got = {}
  local h = API.RegisterCallback(function(rec)
    got[#got + 1] = rec
  end)
  ns.Integrations.OnRecommendation({ main = { id = 5221 }, queue = { { id = 5221 }, { id = 1079 } } })
  ns.Integrations.OnRecommendation({ main = { id = 5221 }, queue = { { id = 5221 }, { id = 1079 } } })
  eq(#got, 1, "fired once per change")
  eq(got[1].spells[1].spellID, 5221)
  eq(got[1].spells[2].spellID, 1079)
  API.RegisterCallback(function()
    error("broken weakaura")
  end)
  ns.Integrations.OnRecommendation({ main = { id = 1079 }, queue = { { id = 1079 } } })
  eq(#got, 2, "a broken callback doesn't stop the others")
  API.UnregisterCallback(h)
  API.SetHUDHidden(true)
  eq(ns.Integrations.hudHidden, true)
  API.SetHUDHidden(false)
end)

test("Masque: the icons join a DMGAssist group when Masque is installed; nothing happens without it", function()
  Reset()
  local ns = Boot()
  local f = ns.Display.Create()
  eq(ns.Integrations.Skin(f), false, "no Masque: no skinning")
  local added = 0
  _G.LibStub = function(name)
    if name == "Masque" then
      return { Group = function(_, addon)
        eq(addon, "DMGAssist")
        return { AddButton = function()
          added = added + 1
        end }
      end }
    end
  end
  eq(ns.Integrations.Skin(f), true)
  eq(added >= 3, true, "the three slots and the badges are skinned")
  _G.LibStub = nil
  ns.Integrations.group = nil
end)

test("welcome: three questions once per profile, suggestions applied, skipped for anyone already set up", function()
  Reset()
  local ns = Boot()
  ns.Display.Create()
  ns.db.welcomed, ns.db.point = nil, nil
  ns.Welcome.MaybeAsk()
  local w = DMGAssistWelcome
  eq(w and w:IsShown(), true, "asked on first login")
  for n = 1, 3 do
    w.buttons[2].scripts.OnClick(w.buttons[2]) -- the second answer each time
  end
  eq(ns.db.welcomed, true)
  eq(ns.db.point[1], "CENTER", "middle of the screen")
  eq(ns.db.hud.scale, 0.8, "small")
  eq(ns.db.hud.showWithTarget, false, "only in combat")
  w:Hide()
  ns.Welcome.MaybeAsk()
  eq(w:IsShown(), false, "not asked again")
  ns.db.welcomed, ns.db.point = nil, { "CENTER", "CENTER", 0, 0 }
  ns.Welcome.MaybeAsk()
  eq(ns.db.welcomed, true, "already placed the HUD: not asked")
  eq(w:IsShown(), false)
end)

test("per spec: DMGAssist can be switched off for one spec only", function()
  Reset()
  local ns = Boot()
  eq(ns.Choices.SpecOff(), false)
  ns.commands.spec("off")
  eq(ns.Choices.SpecOff(), true, "off for this spec")
  local saved = ns.Specs.current.key
  ns.Specs.current.key = "druid_balance"
  eq(ns.Choices.SpecOff(), false, "other specs unaffected")
  ns.Specs.current.key = saved
  ns.commands.spec("on")
  eq(ns.Choices.SpecOff(), false)
end)

test("forms: when Blizzard's assistant asks for Moonkin Form, it goes to slot 1; buffs never push defensives down", function()
  Reset()
  local ns = Boot()
  local main = { id = 190984, token = "wrath" }
  local r = ns.Essentials.Apply({ main = main, queue = { main }, acSpell = 24858 })
  eq(r.main.id, 24858, "Moonkin Form first")
  eq(r.queue[2], main, "the rotation follows")
  r = ns.Essentials.Apply({ main = main, queue = { main }, acSpell = 190984 })
  eq(r.main, main, "an ordinary suggestion changes nothing")
  local src = assert(io.open("addons/DMGAssist/Core/Main.lua")):read("*a")
  eq(src:find("ns.Buffs.Apply(result)", 1, true) < src:find("ns.Defensives.Apply(result)", 1, true), true,
    "buff reminders are applied before defensives")
end)

test("defensives: a Balance Druid is never sent to Bear Form for Frenzied Regeneration; a Guardian is", function()
  Reset()
  local ns = Boot()
  local F = ns.Defensives
  local saved = ns.Specs.current.key
  ns.Specs.current.key = "druid_balance"
  eq(F.ONLY_WHEN.frenzied_regeneration(), false, "Balance: no Bear Form heal")
  eq(F.ONLY_WHEN.regrowth(), true, "Balance: Regrowth")
  ns.Specs.current.key = "druid_guardian"
  eq(F.ONLY_WHEN.frenzied_regeneration(), true, "Guardian: Frenzied Regeneration")
  eq(F.ONLY_WHEN.regrowth(), false, "Guardian: no Regrowth (it leaves Bear Form)")
  ns.Specs.current.key = saved
end)

test("Eclipse is not recommended again while it is active, even with a charge left", function()
  Reset()
  local ns = Boot()
  local G, S = ns.Engine, ns.State
  ns.SpellMap.byID[1233272] = "eclipse"
  S.combatStart = GetTime()
  eq(G.BlockedWhileActive(1233272), false, "not cast yet")
  S.lastCastToken.eclipse = GetTime()
  eq(G.BlockedWhileActive(1233272), true, "just cast: blocked")
  mock.Advance(16)
  eq(G.BlockedWhileActive(1233272), false, "15 s later: allowed again")
  S.lastCastToken.incarnation_chosen_of_elune = GetTime()
  mock.Advance(16)
  eq(G.BlockedWhileActive(1233272), true, "Incarnation: 20 s")
  S.combatStart = nil
end)

test("keybinds: a spell on another form's bar page has no key until you are in that form", function()
  Reset()
  local ns = Boot()
  local D = ns.Display
  mock.actionInfo = { [112] = { "spell", 24858 } } -- page 10 (Moonkin Form's bar), slot 4
  mock.bindings = { ACTIONBUTTON4 = "4" }
  mock.bonusBar = 0
  D.InvalidateKeybinds()
  eq(D.Keybind(24858), nil, "caster form: pressing 4 casts page 1, not page 10")
  mock.bonusBar = 4
  D.InvalidateKeybinds()
  eq(D.Keybind(24858), "4", "in Moonkin Form page 10 is the main bar")
  mock.actionInfo, mock.bindings, mock.bonusBar = nil, nil, 0
  D.InvalidateKeybinds()
end)

test("blocked while active: Shadow Dance during Shadow Dance, Divine Shield under Forbearance", function()
  Reset()
  local ns = Boot()
  local G, S = ns.Engine, ns.State
  ns.SpellMap.byID[185313] = "shadow_dance"
  ns.SpellMap.byID[642] = "divine_shield"
  S.combatStart = GetTime()
  S.lastCastToken.shadow_dance = GetTime()
  eq(G.BlockedWhileActive(185313), true, "dancing: no second Shadow Dance")
  S.lastCastToken.lay_on_hands = GetTime()
  eq(G.BlockedWhileActive(642), true, "Forbearance after Lay on Hands")
  mock.Advance(31)
  eq(G.BlockedWhileActive(185313), false)
  eq(G.BlockedWhileActive(642), false)
  S.combatStart = nil
end)

test("Edit Mode: the HUD shows and can be dragged while Blizzard's Edit Mode is open", function()
  Reset()
  local ns = Boot()
  ns.Display.Create()
  ns.Integrations.OnEditMode(true)
  eq(ns.Previewing(), true)
  eq(ns.Display.frame.editOverlay:IsShown(), true)
  ns.Integrations.OnEditMode(false)
  eq(ns.Display.frame.editOverlay:IsShown(), false)
end)

test("look-ahead: a DoT applied in slot 1 is not recommended again in slot 2", function()
  Reset()
  local ns = Boot()
  local rec = QRecord({ { a = "rip", k = "T", c = "!dot.rip.ticking" }, { a = "shred", k = "R" } })
  Feral(ns, rec)
  mock.power[4] = 2
  eq(Tokens(ns.Engine.Recommend(rec, {})), "rip > shred > shred")
end)

test("look-ahead: cooldowns start, resources are spent and gained", function()
  Reset()
  local ns = Boot()
  local rec = QRecord({
    { a = "tigers_fury", k = "R" },
    { a = "ferocious_bite", k = "R", c = "combo_points>=5" },
    { a = "shred", k = "R" },
  })
  Feral(ns, rec)
  mock.power[4] = 5
  -- TF (then on cooldown) > Bite at 5 combo points (spends them all) > Shred (no combo points left)
  eq(Tokens(ns.Engine.Recommend(rec, {})), "tigers_fury > ferocious_bite > shred")
  -- Not enough energy for Shred later: 20 energy, Shred costs 40, nothing else usable -> queue stops early.
  mock.power[4], mock.power[3] = 0, 20
  rec.simc.default = { { a = "shred", k = "R" } }
  local r = ns.Engine.Recommend(rec, {})
  eq(r.queue[2], nil, "cannot afford a second Shred")
end)

test("look-ahead: the spell being cast counts as already cast", function()
  Reset()
  local ns = Boot()
  local rec = QRecord({ { a = "shred", k = "R", c = "!prev_gcd.1.shred" }, { a = "ferocious_bite", k = "R" } })
  Feral(ns, rec)
  mock.power[4] = 3
  eq(ns.Engine.Recommend(rec, {}).main.token, "shred")
  mock.casting = { id = 5221, endsIn = 1.2 }
  local r = ns.Engine.Recommend(rec, {})
  eq(r.casting, 5221)
  eq(r.main.token, "ferocious_bite", "Shred is mid-cast, so the next press is Bite")
  -- and the overlay is gone afterwards: the real present is untouched
  eq(ns.State.Lookahead(), nil)
end)

test("look-ahead with secret resources: a finisher still empties combo points", function()
  Reset()
  local ns = Boot()
  local rec = QRecord({
    { a = "ferocious_bite", k = "R", c = "combo_points>=5" },
    { a = "shred", k = "R" },
  })
  Feral(ns, rec)
  Restrict()
  mock.acSpell = 22568 -- the assistant (which can see combo points) wants Bite
  local r = ns.Engine.Recommend(rec, { useAssisted = true })
  eq(r.main.token, "ferocious_bite")
  eq(r.main.source, "simc+assisted")
  eq(r.queue[2].token, "shred", "after a finisher, combo points are known to be 0")
end)

test("modes: auto-detect counts enemies, hotkey cycles, primary mode is the fallback", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  mock.inCombat, mock.nameplates = true, 4
  local n, label = S.Targets()
  eq(n, 4)
  eq(label, "AUTO 4")
  DMGAssist_CycleMode()
  n, label = S.Targets()
  eq(n, 1)
  eq(label, "ST")
  DMGAssist_CycleMode()
  n, label = S.Targets()
  eq(n, 2, "the spec's AoE switch point (Feral: 2)")
  eq(label, "AOE")
  DMGAssist_CycleMode()
  eq(S.ActiveMode(), "auto")
  -- no nameplates (hidden or none in combat): the primary mode decides
  mock.nameplates = 0
  SlashCmdList.DMGASSIST("mode aoe")
  n, label = S.Targets()
  eq(n, 2)
  eq(label, "AOE?")
  SlashCmdList.DMGASSIST("auto off")
  n, label = S.Targets()
  eq(n, 2)
  eq(label, "AOE")
  SlashCmdList.DMGASSIST("targets 4") -- a typed number overrides the spec's switch point
  eq(S.Targets(), 4)
  eq(ns.db.aoeCount, "custom")
  DMGAssist_ToggleBurst()
  eq(ns.db.burst, false)
  DMGAssist_Toggle()
  eq(ns.db.enabled, false)
  DMGAssist_Toggle()
  eq(ns.db.enabled, true)
end)

test("HUD shows three icons, the mode in the header, keybinds and the GCD bar", function()
  Reset()
  mock.bindings = { ACTIONBUTTON3 = "SHIFT-3", MULTIACTIONBAR1BUTTON2 = "CTRL-F" }
  local ns = Boot()
  ns.db.hud.header = true -- off by default (icons only); switched on here to check its text
  ns.Display.Rebuild()
  ns.Update()
  eq(ns.Display.frame.modeText.text, "", "no mode shown before combat")
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  local r = ns.Update()
  local f = ns.Display.frame
  eq(f.slots[1]:IsShown(), true)
  eq(f.slots[2]:IsShown(), r.queue[2] ~= nil)
  eq(type(f.header.text), "string")
  local hdr = f.header.text
  eq(hdr:find("DMGAssist", 1, true) ~= nil, true, hdr)
  local mode = f.modeText.text
  eq(mode:find("AOE", 1, true) ~= nil or mode:find("ST", 1, true) ~= nil, true, "mode in the title row: " .. mode)
  eq(type(f.gcd.value), "number")
  -- keybinds: main bar slot 3 -> ACTIONBUTTON3; bar page 6 slot 62 -> MULTIACTIONBAR1BUTTON2; cat form bonus page 7
  mock.actionSlots = { [5221] = { 3 }, [1822] = { 62 }, [1079] = { 75 } }
  ns.Display.InvalidateKeybinds()
  eq(ns.Display.Keybind(5221), "S3")
  eq(ns.Display.Keybind(1822), "CF")
  mock.bindings.ACTIONBUTTON3 = nil
  mock.Fire("UPDATE_BINDINGS")
  eq(ns.Display.Keybind(5221), nil, "binding removed -> no text")
  mock.bonusBar = 1
  mock.bindings.ACTIONBUTTON3 = "3"
  mock.Fire("UPDATE_BONUS_ACTIONBAR")
  eq(ns.Display.Keybind(1079), "3", "cat form bar slot 75 uses the main bar key")
  mock.bonusBar, mock.actionSlots, mock.bindings = nil, nil, nil
  SlashCmdList.DMGASSIST("queue 1")
  ns.Update()
  eq(f.slots[2]:IsShown(), false)
end)

test("settings panel: every option is registered, reads and writes DMGAssistDB, and applies live", function()
  Reset()
  local ns = Boot()
  local s = mock.settings
  eq(type(s.DMGASSIST_ICONSIZE), "table", "icon size slider registered")
  eq(s.DMGASSIST_ICONSIZE.control, "slider")
  eq(s.DMGASSIST_MODE.control, "dropdown")
  local modes = s.DMGASSIST_MODE.options()
  eq(modes[1].value, "st")
  eq(modes[2].value, "aoe")
  -- every setting round-trips its own value without errors
  local count = 0
  for _, setting in pairs(s) do
    local v = setting:GetValue()
    eq(type(v), setting.varType, setting.variable)
    setting:SetValue(v)
    count = count + 1
  end
  eq(count >= 34, true, "expected the full set of options, got " .. count)
  s.DMGASSIST_ICONSIZE:SetValue(70)
  eq(ns.db.hud.iconSize, 70)
  eq(ns.Display.frame.slots[1].width, 70, "applied without reload")
  s.DMGASSIST_MODE:SetValue("aoe")
  eq(ns.db.mode, "aoe")
  s.DMGASSIST_HIDEOUTOFCOMBAT:SetValue(false)
  mock.hasTarget = false
  eq(type(ns.Update()), "table", "shown without a target when auto-hide is off")
  -- gear button and /dmga config open the panel
  ns.Display.frame.gear.scripts.OnClick()
  eq(mock.openedCategory, ns.Options.category:GetID())
  mock.openedCategory = nil
  SlashCmdList.DMGASSIST("config")
  eq(mock.openedCategory, ns.Options.category:GetID())
end)

test("translations: every language covers the same strings, Chinese client shows Chinese", function()
  Reset()
  mock.locale = "zhCN"
  local ns = Boot()
  eq(ns.L["Recommendations on."], "推荐已开启。")
  eq(BINDING_NAME_DMGASSIST_BURST, "开关大技能")
  local base = ns.LOCALES.deDE
  for locale, t in pairs(ns.LOCALES) do
    for k in pairs(base) do
      eq(type(t[k]), "string", locale .. " is missing: " .. k)
    end
    for k in pairs(t) do
      eq(type(base[k]), "string", locale .. " has an extra key: " .. k)
    end
  end
  -- English client: keys are the text
  ns.SetLocale("enUS")
  eq(ns.L["Recommendations on."], "Recommendations on.")
end)

test("language: the setting picks another language than the game's, applied at load", function()
  Reset()
  local ns = Boot()
  eq(ns.L["Recommendations on."], "Recommendations on.", "English client")
  ns.global.language = "deDE"
  ns.ApplyLanguage()
  eq(ns.L["Report an issue"], "Problem melden", "German chosen")
  eq(ns.L["Welcome to DMGAssist"], "Willkommen bei DMGAssist")
  ns.global.language = "auto"
  ns.SetLocale("enUS")
end)

test("key bindings file calls functions that exist", function()
  Reset()
  Boot()
  local xml = assert(io.open("addons/DMGAssist/Bindings.xml")):read("*a")
  local count = 0
  for fn in xml:gmatch("([%w_]+)%(%)") do
    eq(type(_G[fn]), "function", fn)
    count = count + 1
  end
  eq(count, 3)
  for name in xml:gmatch('name="([%w_]+)"') do
    eq(type(_G["BINDING_NAME_" .. name]), "string", name)
  end
end)

---------------------------------------------------------------------------
-- Clues: what the assistant, glows and affordability reveal about hidden state
---------------------------------------------------------------------------
test("oracle: the assistant's pick reveals Clearcasting and a ticking Rake", function()
  Reset()
  local ns = Boot()
  local rec = Record()
  rec.blizzard = { default = {
    { a = "rake", k = "T", c = "!dot.rake.ticking" },
    { a = "shred", k = "T", c = "buff.clearcasting.react" },
    { a = "thrash", k = "R" },
  } }
  rec.simc.default = { { a = "rake", k = "T", c = "!dot.rake.ticking" }, { a = "shred", k = "T", c = "buff.clearcasting.react" } }
  rec.simc.precombat = nil
  Restrict()
  local S, UNKNOWN = ns.State, ns.Expr.UNKNOWN
  eq(S.Resolve("buff.clearcasting.react", {}), UNKNOWN, "hidden before the oracle")
  mock.acSpell = 5221 -- the assistant says Shred
  local r = ns.Engine.Recommend(rec, { useAssisted = true })
  eq(S.Resolve("buff.clearcasting.react", {}), 1, "Shred's rule was true: Clearcasting is up")
  eq(S.Resolve("dot.rake.ticking", {}), 1, "Rake was castable but skipped: Rake is ticking")
  eq(r.main.token, "shred")
  eq(r.main.source, "simc", "SimC's own line is now certain, not just corroborated")
  -- our cast changes the state: those conclusions are dropped until the assistant speaks again
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5221)
  eq(S.Resolve("buff.clearcasting.react", {}), UNKNOWN)
end)

test("oracle: a skipped finisher bounds hidden combo points", function()
  Reset()
  local ns = Boot()
  local rec = Record()
  rec.blizzard = { default = { { a = "ferocious_bite", k = "R", c = "combo_points>=5" }, { a = "shred", k = "R" } } }
  Restrict()
  mock.acSpell = 5221
  ns.Engine.Recommend(rec, { useAssisted = true })
  local lo, hi = ns.State.Bounds("combo_points")
  eq(lo, 0)
  eq(hi, 4)
  eq(ns.Expr.Test("combo_points<5", function() return ns.Expr.UNKNOWN end, ns.State.Bounds), true)
  eq(ns.Expr.Test("combo_points>=5|combo_points=2", function() return ns.Expr.UNKNOWN end, ns.State.Bounds),
    ns.Expr.UNKNOWN, "still unknown where the range can't decide")
end)

test("affordability brackets hidden energy, and is graded when energy is readable", function()
  Reset()
  local ns = Boot()
  local rec = QRecord({ { a = "shred", k = "R" } })
  rec.spells.rake = { a = { 1822 } }
  rec.spellInfo[1822] = { n = "rake", cost = { [3] = 35 }, gcd = 1 }
  ns.SpellMap.SetData(rec)
  mock.usable[5221] = { false, true } -- Shred (40): not enough energy
  mock.usable[1822] = { true, false } -- Rake (35): affordable
  Restrict()
  local lo, hi = ns.State.Bounds("energy")
  eq(lo, 35)
  eq(hi, 39)
  -- out of combat the real value is readable: the bracket is checked against it
  mock.restricted = false
  mock.power[3], mock.powerReadable[3] = 37, true
  mock.Advance(0.01)
  ns.State.VerifyPowers()
  eq(ns.Clues.stats.usable.checks, 1)
  eq(ns.Clues.stats.usable.wrong, 0)
end)

test("glows: learned out of combat, then reveal the proc in combat", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  mock.Fire("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", 5221)
  mock.auras.player = { { name = "Clearcasting", spellId = 135700, duration = 15, expirationTime = mock.now + 15 } }
  mock.Fire("UNIT_AURA", "player")
  eq(ns.Clues.links[5221], "clearcasting", "glow on Shred = Clearcasting")
  mock.auras.player = {}
  mock.Fire("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE", 5221)
  mock.Fire("UNIT_AURA", "player")
  Restrict()
  mock.Advance(2)
  eq(S.Resolve("buff.clearcasting.up", {}), ns.Expr.UNKNOWN)
  mock.Fire("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", 5221)
  eq(S.Resolve("buff.clearcasting.up", {}), 1)
  mock.Fire("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE", 5221)
  eq(S.Resolve("buff.clearcasting.up", {}), 0)
  -- the link is saved for next time
  eq(DMGAssistDB.learned.druid_feral.glowAura[5221], "clearcasting")
end)

test("an inference source that keeps being wrong switches itself off", function()
  Reset()
  local ns = Boot()
  local Cl = ns.Clues
  for _ = 1, 25 do
    Cl.SetAura("player", "phantom", true, 1, "assisted")
    Cl.Verify("player", {}) -- readable truth: no such buff
  end
  eq(Cl.Enabled("assisted"), false)
  eq(Cl.AuraFact("player", "phantom"), nil, "facts from a disabled source are ignored")
end)

---------------------------------------------------------------------------
-- More clues: resource counting, range, button changes, haste, fight length, health from the oracle
---------------------------------------------------------------------------
test("shadow combo points: counted from casts, confirmed by power events, misses rolled back", function()
  Reset()
  local ns = Boot()
  local S, UNKNOWN = ns.State, ns.Expr.UNKNOWN
  mock.power[4], mock.powerMax[4] = 2, 5
  S.VerifyPowers()                       -- readable: the counter starts at 2
  Restrict()
  eq(S.Resolve("combo_points", {}), 2, "hidden now, but counted")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g1", 5221) -- Shred: +1 combo point (SimC data)
  mock.Fire("UNIT_POWER_UPDATE", "player", "COMBO_POINTS")   -- and the game confirms a change
  eq(S.Resolve("combo_points", {}), 3)
  mock.Advance(1)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g2", 5221) -- Shred again, but no power event: it missed
  mock.Advance(0.7)
  eq(S.Resolve("combo_points", {}), 3, "no confirmation -> rolled back")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g3", 22568) -- Ferocious Bite spends them all
  mock.Fire("UNIT_POWER_UPDATE", "player", "COMBO_POINTS")
  eq(S.Resolve("combo_points", {}), 0)
  mock.Advance(1)
  mock.Fire("UNIT_POWER_UPDATE", "player", "COMBO_POINTS")   -- a change we didn't cause (proc)
  eq(S.Resolve("combo_points", {}), UNKNOWN, "unexplained change -> no longer certain")
  -- graded when readable again
  mock.restricted = false
  mock.power[4] = 1
  S.VerifyPowers()
  eq(S.Resolve("combo_points", {}), 1)
end)

test("range: which spells are in range bounds the target's distance", function()
  Reset()
  local ns = Boot()
  local E = ns.Expr
  local function r() return E.UNKNOWN end
  mock.inRange = { [1822] = true }          -- Rake (5 yd) in range
  mock.Advance(0.01)
  eq(E.Test("target.distance<=8", r, ns.State.Bounds), true)
  mock.inRange = { [1822] = false, [8921] = true } -- out of melee, Moonfire (40 yd) in range
  mock.Advance(0.01)
  eq(E.Test("target.distance>5", r, ns.State.Bounds), true)
  eq(E.Test("target.distance<=8", r, ns.State.Bounds), E.UNKNOWN, "between 5 and 40: can't tell")
  eq(ns.State.Resolve("target.distance", {}), E.UNKNOWN, "no more assuming 5 yards when we can measure")
  mock.inRange = nil
  mock.Advance(0.01)
  eq(ns.State.Resolve("target.distance", {}), 5, "no range info: SimC's default")
end)

test("button changes and requirement-only spells are learned as buff signals", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  -- Out of combat: Bite turns into Ravage when a buff appears.
  mock.Fire("SPELL_UPDATE_ICON", 22568)           -- baseline: not transformed
  mock.overrides = { [22568] = 441591 }
  mock.Fire("SPELL_UPDATE_ICON", 22568)
  mock.auras.player = { { name = "Ravage!", spellId = 999001, duration = 15, expirationTime = mock.now + 15 } }
  mock.Fire("UNIT_AURA", "player")
  eq(ns.Clues.links["o22568"], "ravage", "override linked to the buff")
  -- A spell that is only castable while a buff is up.
  mock.Advance(1)
  mock.usable[5215] = { false, false }
  mock.Fire("SPELL_UPDATE_USABLE")
  mock.Advance(0.2) -- the scan is throttled to 10x per second
  mock.usable[5215] = { true, false }
  mock.Fire("SPELL_UPDATE_USABLE")
  mock.auras.player = { { name = "Ravage!", spellId = 999001, duration = 15, expirationTime = mock.now + 15 },
    { name = "Shadowmeld Ready", spellId = 999002, duration = 10, expirationTime = mock.now + 10 } }
  mock.Fire("UNIT_AURA", "player")
  eq(ns.Clues.links.u5215, "shadowmeld_ready")
  -- In combat (auras hidden) the signals tell us.
  mock.overrides = nil
  mock.Fire("SPELL_UPDATE_ICON", 22568)
  Restrict()
  mock.Advance(2)
  mock.overrides = { [22568] = 441591 }
  mock.Fire("SPELL_UPDATE_ICON", 22568)
  eq(S.Resolve("buff.ravage.up", {}), 1)
  mock.Advance(0.2)
  mock.usable[5215] = { false, false }
  mock.Fire("SPELL_UPDATE_USABLE")
  eq(S.Resolve("buff.shadowmeld_ready.up", {}), 0)
end)

test("haste: Bloodlust is caught by measuring the GCD when haste is hidden", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  Restrict()
  mock.Fire("UNIT_SPELL_HASTE", "player")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 8921) -- Moonfire: 1.5 s hasted GCD
  mock.cooldowns[61304] = { active = true }
  mock.Fire("SPELL_UPDATE_COOLDOWN")
  mock.Advance(1.2)
  mock.cooldowns[61304] = { active = false }
  mock.Fire("SPELL_UPDATE_COOLDOWN")
  eq(S.hasteSource, "measured")
  eq(math.floor(S.GCD(8921) * 100 + 0.5), 120, "GCD now 1.2 s (25% haste)")
end)

test("smart fight length: bosses use the setting, dungeon trash is short, dummies are long", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  eq(S.FightLength(), 300, "open world / target dummy")
  mock.instance = true
  eq(S.FightLength(), 30, "dungeon trash")
  mock.boss = true
  eq(S.FightLength(), 300, "boss")
  mock.boss = nil
  mock.Fire("ENCOUNTER_START", 1, "Boss", 1, 5)
  eq(S.FightLength(), 300, "encounter in progress")
  mock.Fire("ENCOUNTER_END", 1, "Boss", 1, 5, 1)
  ns.db.smartFight = false
  eq(S.FightLength(), 300, "switched off")
end)

test("oracle: a skipped execute-style rule bounds the target's health", function()
  Reset()
  local ns = Boot()
  local rec = Record()
  rec.blizzard = { default = { { a = "rake", k = "T", c = "target.health.pct<20" }, { a = "shred", k = "R" } } }
  Restrict()
  mock.acSpell = 5221
  ns.Engine.Recommend(rec, { useAssisted = true })
  local lo = ns.State.Bounds("target.health.pct")
  eq(lo, 20, "Rake's <20% rule was skipped although castable: health >= 20%")
end)

---------------------------------------------------------------------------
-- Boss mods, keybinds from macros and bar addons, calibration, stacking, press cue, Cooldown Manager
---------------------------------------------------------------------------
local function FakeBossMods()
  local dbm, bw = {}, {}
  DBM = { RegisterCallback = function(_, event, fn) dbm[event] = fn end }
  BigWigsLoader = { RegisterMessage = function(_, message, fn) bw[message] = fn end }
  return dbm, bw
end

test("DBM: timers by type feed SimC's raid_event.adds and the HUD callout", function()
  Reset()
  local dbm = FakeBossMods()
  local ns = Boot()
  local B, S = ns.BossMods, ns.State
  eq(table.concat(B.Detected(), ","), "DBM,BigWigs")
  dbm.DBM_Pull("DBM_Pull")
  dbm.DBM_TimerBegin("DBM_TimerBegin", "t1", "Adds", 20, 0, "cd", 1234, 1)       -- colorId 1 = adds
  dbm.DBM_TimerBegin("DBM_TimerBegin", "t2", "Shadow Nova", 5, 0, "cd", 5678, 2) -- colorId 2 = AoE
  eq(math.floor(S.Resolve("raid_event.adds.in", {}) + 0.5), 20, "adds in 20 s")
  eq(S.Resolve("raid_event.adds.exists", {}), 1)
  local c = B.Callout()
  eq(c.label, "AOE")
  eq(math.floor(c.seconds + 0.5), 5)
  dbm.DBM_Announce("DBM_Announce", "Interrupt Shadow Bolt!", 0, "interrupt", 999, 1, true)
  eq(B.Callout().label, "INTERRUPT", "alerts outrank timers")
  dbm.DBM_TimerStop("DBM_TimerStop", "t1")
  eq(S.Resolve("raid_event.adds.in", {}), 10000, "no adds expected -> SimC's default")
  ns.db.bossMods = false
  eq(B.Callout(), nil, "switched off in settings")
end)

test("BigWigs: bars with its 'adds'/'stages' keys, stop and wipe", function()
  Reset()
  local _, bw = FakeBossMods()
  local ns = Boot()
  local B = ns.BossMods
  bw.BigWigs_OnBossEngage("BigWigs_OnBossEngage")
  bw.BigWigs_StartBar("BigWigs_StartBar", {}, "adds", "Adds (2)", 12, 0)
  bw.BigWigs_StartBar("BigWigs_StartBar", {}, 4321, "Crushing Blow", 30, 0)
  eq(math.floor(B.Next("adds") + 0.5), 12)
  bw.BigWigs_StopBar("BigWigs_StopBar", {}, "Adds (2)")
  eq(B.Next("adds"), nil)
  bw.BigWigs_OnBossWipe("BigWigs_OnBossWipe")
  eq(B.Next(), nil, "wipe clears timers")
end)

test("no boss mod: Blizzard's encounter timeline still gives the next boss event", function()
  Reset()
  local ns = Boot()
  mock.timeline = { [7] = 6.5 }
  local left, t = ns.BossMods.Next()
  eq(left, 6.5)
  eq(t.source, "Blizzard")
end)

test("keybinds: spells in macros and on Bartender bars", function()
  Reset()
  mock.actionInfo = { [5] = { "macro", 3 }, [50] = { "spell", 1822 } }
  mock.macroSpell = { [3] = 5221 }  -- a macro that casts Shred, on main bar slot 5
  mock.bindings = { ACTIONBUTTON5 = "Q", ["CLICK BT4Button50:LeftButton"] = "SHIFT-E" }
  BT4Button50 = { _state_action = 50 }
  local ns = Boot()
  ns.Display.BuildKeymap()
  eq(ns.Display.Keybind(5221), "Q", "macro on the main bar")
  eq(ns.Display.Keybind(1822), "SE", "Bartender button bound with CLICK binding")
  mock.bindings.ACTIONBUTTON5 = "R"
  SlashCmdList.DMGASSIST("keys")
  eq(ns.Display.Keybind(5221), "R", "/dmga keys rebuilds")
  BT4Button50 = nil
end)

test("calibration: live costs from the game replace SimC's base costs", function()
  Reset()
  mock.powerCost = { [5221] = { { type = 3, cost = 32 } } } -- talented Shred costs 32, not 40
  local ns = Boot()
  local info = ns.SpellMap.Info(5221)
  eq(info.costLive[3], 32)
  eq(ns.SpellMap.Cost(info)[3], 32)
end)

test("stacking own buffs (Ironfur): learned from a readable scan, then tracked per cast", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  ns.SpellMap.applied = { ironfur = true }
  ns.SpellMap.info[192081] = { n = "ironfur", d = 7, ap = { { 192081, "self" } }, cost = { [1] = 40 }, cd = 0.5 }
  mock.auras.player = { { name = "Ironfur", spellId = 192081, duration = 7, expirationTime = mock.now + 7,
    applications = 2 } }
  mock.Fire("UNIT_AURA", "player")
  eq(S.IsStacking("ironfur"), true)
  Restrict()
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "a", 192081)
  mock.Advance(2)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "b", 192081)
  eq(S.Resolve("buff.ironfur.stack", {}), 2)
  mock.Advance(5.5) -- first one expired (7 s), second has 1.5 s left
  eq(S.Resolve("buff.ironfur.stack", {}), 1)
  eq(math.floor(S.Resolve("buff.ironfur.remains", {}) * 10 + 0.5), 15)
end)

test("press-now cue lights just before the GCD ends (50 ms lead, adjustable); spell_haste", function()
  Reset()
  local ns = Boot()
  mock.cooldowns[61304] = { active = true, start = mock.now, duration = 1.5 }
  ns.Update()
  eq(ns.Display.frame.pressNow, false, "1.5 s left")
  mock.Advance(1.2)
  ns.Update()
  eq(ns.Display.frame.pressNow, false, "0.3 s left: not yet")
  mock.Advance(0.26)
  ns.Update()
  eq(ns.Display.frame.pressNow, true, "40 ms left: inside the 50 ms lead")
  ns.Display.Settings().pressLead = 300
  mock.cooldowns[61304] = { active = true, start = mock.now, duration = 1.5 }
  mock.Advance(1.25)
  ns.Update()
  eq(ns.Display.frame.pressNow, true, "250 ms left with a 300 ms lead")
  ns.Display.Settings().pressLead = 50
  mock.haste = 25
  eq(math.floor(ns.State.Resolve("spell_haste", {}) * 100 + 0.5), 80)
end)

test("Cooldown Manager: tracked buffs read from its frames when readable, graded against the truth", function()
  Reset()
  local ns = Boot()
  local item = { cooldownID = 11, isActive = true }
  BuffIconCooldownViewer = { GetChildren = function() return item end }
  mock.cdmInfo = { [11] = { spellID = 135700 } }
  ns.SpellMap.info[135700] = { n = "clearcasting", d = 15 }
  -- readable now: graded, not used
  mock.auras.player = { { name = "Clearcasting", spellId = 135700, duration = 15, expirationTime = mock.now + 15 } }
  mock.Fire("UNIT_AURA", "player")
  ns.Clues.ReadCooldownManager(ns.State.ReadableAuras())
  eq(ns.Clues.stats.cdm.checks, 1)
  eq(ns.Clues.stats.cdm.wrong, 0)
  -- in combat (auras hidden) its active flag is used
  Restrict()
  mock.Advance(16) -- our own clock from the readable scan has run out: unknown without the Cooldown Manager
  eq(ns.State.Resolve("buff.clearcasting.up", {}), ns.Expr.UNKNOWN)
  ns.Clues.ReadCooldownManager(ns.State.ReadableAuras())
  eq(ns.State.Resolve("buff.clearcasting.up", {}), 1)
  item.isActive = mock.Secret() -- if Blizzard hides it, we simply get nothing
  mock.Advance(1)
  ns.Clues.ReadCooldownManager(ns.State.ReadableAuras())
  eq(ns.State.Resolve("buff.clearcasting.up", {}), ns.Expr.UNKNOWN)
end)

test("free combo point proc: 'v or v+1', and a finisher makes the count exact again", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  mock.power[4], mock.powerMax[4] = 4, 5
  S.VerifyPowers()
  Restrict()
  mock.Fire("UNIT_POWER_UPDATE", "player", "COMBO_POINTS") -- a point we didn't cause
  local lo, hi = S.Bounds("combo_points")
  eq(lo, 4)
  eq(hi, 5)
  eq(ns.Expr.Test("combo_points>=4", function() return ns.Expr.UNKNOWN end, S.Bounds), true)
  eq(ns.Expr.Test("combo_points>=5", function() return ns.Expr.UNKNOWN end, S.Bounds), ns.Expr.UNKNOWN,
    "can't claim 5: needs the assistant (Midnight) or shows as uncertain")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "f", 22568) -- Ferocious Bite spends up to 5
  mock.Fire("UNIT_POWER_UPDATE", "player", "COMBO_POINTS")
  eq(S.Resolve("combo_points", {}), 0, "exact again after the finisher")
end)

---------------------------------------------------------------------------
-- Rendering secrets: the game picks between two spells; interrupt reminder
---------------------------------------------------------------------------
test("secret branch: Bite-at-5 vs Shred, both shown, the game's curve picks the visible one", function()
  Reset()
  local ns = Boot()
  local rec = QRecord({ { a = "ferocious_bite", k = "R", c = "combo_points>=5" }, { a = "shred", k = "R" } })
  ns.SpellMap.SetData(rec)
  mock.power[4], mock.powerMax[4] = 4, 5
  mock.power[3], mock.powerMax[3] = 100, 100
  ns.State.PowerMax(4) -- seen while readable: 5
  Restrict()
  local r = ns.Engine.Recommend(rec, {})
  eq(r.main.token, "shred", "the engine's own pick: Bite can't be confirmed")
  eq(type(r.branch), "table", "branch detected")
  eq(r.branch.pick.token, "ferocious_bite")
  eq(r.branch.otherwise.token, "shred")
  eq(r.branch.truth[4], false)
  eq(r.branch.truth[5], true)
  -- HUD: both icons; alphas are the (secret) curve results: Bite visible only at 5
  ns.Display.Create()
  ns.Display.Update(r, true)
  local f = ns.Display.frame
  eq(f.branchShown, true)
  eq(mock.IsSecret(f.branch.alpha), true, "alpha set from a secret, never read by us")
  mock.restricted = false -- peek like the game would render it
  r = ns.Engine.Recommend(rec, {})
  ns.Display.Update(r, true)
  eq(r.branch, nil, "readable: no branch needed")
  -- render the branch with readable values to check the curve maths
  local branch = { pt = 4, max = 5, truth = { [0] = false, false, false, false, false, true },
    pick = { id = 22568, token = "ferocious_bite" }, otherwise = { id = 5221, token = "shred" } }
  for cp = 0, 5 do
    mock.power[4] = cp
    ns.Display.Update({ main = branch.otherwise, queue = { branch.otherwise }, branch = branch }, true)
    eq(f.branch.alpha, cp == 5 and 1 or 0, "Bite at " .. cp)
    eq(f.slots[1].alpha, cp == 5 and 0 or 1, "Shred at " .. cp)
  end
end)

local function KickBook()
  local book = {}
  for _, b in ipairs(FERAL_BOOK) do
    book[#book + 1] = b
  end
  book[#book + 1] = { spellID = 106839, name = "Skull Bash" }
  mock.book = book
end

test("interrupts: open world, readable -> slot 1, the rest of the queue shifts right", function()
  Reset()
  KickBook()
  local ns = Boot()
  local before = ns.Update()
  local first = before.queue[1].token
  mock.targetCast = { notInterruptible = false, id = 9999 }
  local r = ns.Update()
  eq(r.interrupt.how, "decided")
  eq(r.queue[1].id, 106839, "Skull Bash in slot 1")
  eq(r.queue[2].token, first, "previous #1 is now #2")
  mock.targetCast = { notInterruptible = true, id = 9999 }
  eq(ns.Update().interrupt, nil, "uninterruptible: nothing")
end)

test("interrupts: secret flags in combat -> drawn over slot 1, the game decides visibility", function()
  Reset()
  KickBook()
  local ns = Boot()
  mock.targetCast = { notInterruptible = false, id = 9999 }
  Restrict()
  local r = ns.Update()
  eq(r.interrupt.how, "render")
  local f = ns.Display.frame
  eq(f.kickGate:IsShown(), true)
  eq(mock.IsSecret(f.kick.alpha.fromBoolean), true, "alpha from the secret 'notInterruptible'")
  eq(f.kickGate.alpha, 1, "open world: no importance gate")
end)

test("interrupts: smart mode in dungeons only for important casts or boss mod calls", function()
  Reset()
  KickBook()
  local dbm = FakeBossMods()
  local ns = Boot()
  mock.instance = true
  mock.targetCast = { notInterruptible = false, id = 9999 }
  mock.important = {}
  eq(ns.Update().interrupt, nil, "trash cast that doesn't matter")
  mock.important = { [9999] = true }
  eq(ns.Update().interrupt.how, "decided", "Blizzard: lethal if not interrupted")
  mock.important = {}
  dbm.DBM_Announce("DBM_Announce", "Interrupt Void Bolt!", 0, "interrupt", 9999, 1, true)
  local r = ns.Update()
  eq(r.interrupt.why, "bossmod")
  eq(r.queue[1].id, 106839)
  -- in combat with secrets: rendered with both gates (important AND interruptible)
  ns.BossMods.Reset()
  Restrict()
  mock.targetCast = { notInterruptible = false, id = 9999 }
  r = ns.Update()
  eq(r.interrupt.how, "render")
  eq(mock.IsSecret(ns.Display.frame.kickGate.alpha.fromBoolean), true, "importance gate from a secret")
end)

test("interrupts: modes off / instances / bossmods", function()
  Reset()
  KickBook()
  local dbm = FakeBossMods()
  local ns = Boot()
  mock.targetCast = { notInterruptible = false, id = 9999 }
  ns.db.interruptMode = "off"
  eq(ns.Update().interrupt, nil)
  ns.db.interruptMode = "instances"
  eq(ns.Update().interrupt, nil, "open world")
  mock.instance = true
  eq(ns.Update().interrupt.how, "decided")
  ns.db.interruptMode = "bossmods"
  eq(ns.Update().interrupt, nil, "no call")
  dbm.DBM_Announce("DBM_Announce", "Interrupt!", 0, "interrupt", 9999, 1, true)
  eq(ns.Update().interrupt.how, "decided")
end)

test("interrupts: pressing it or skipping it (casting the next spell) clears it until the next cast", function()
  Reset()
  KickBook()
  local ns = Boot()
  mock.targetCast = { notInterruptible = false, id = 9999 }
  eq(ns.Update().interrupt.how, "decided")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "x", 5221) -- player pressed Shred instead
  eq(ns.Interrupts.stats.skipped, 1)
  eq(ns.Update().interrupt, nil, "skipped: stays out of the way for this cast")
  mock.Fire("UNIT_SPELLCAST_START", "target")             -- the mob starts its next cast
  eq(ns.Update().interrupt.how, "decided")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "y", 106839) -- player interrupts
  eq(ns.Interrupts.stats.used, 1)
  mock.cooldowns[106839] = { active = true, start = mock.now, duration = 15 }
  eq(ns.Update().interrupt, nil, "on cooldown")
end)

test("interrupts: skip detected from the GCD when cast events are secret", function()
  Reset()
  KickBook()
  local ns = Boot()
  mock.targetCast = { notInterruptible = false, id = 9999 }
  ns.Update()
  mock.Fire("SPELL_UPDATE_COOLDOWN")
  mock.cooldowns[61304] = { active = true, start = mock.now, duration = 1 }
  mock.Fire("SPELL_UPDATE_COOLDOWN") -- a GCD started: some on-GCD spell was pressed
  mock.Advance(0.3)
  eq(ns.Interrupts.skipped, true)
end)

---------------------------------------------------------------------------
-- Diagnostics: readability changes, ranges, summaries, failed calls
---------------------------------------------------------------------------
test("diagnostics: logs when an input goes dark, the ranges seen, and a per-fight summary", function()
  Reset()
  local logged = {}
  DMGAssistWatchdog = { Log = function(kind, data) logged[#logged + 1] = { kind, tostring(data) } end }
  local ns = Boot()
  local G = ns.Diagnostics
  mock.power[4], mock.powerMax[4] = 3, 5
  mock.Fire("PLAYER_REGEN_DISABLED")
  G.Tick(true)
  eq(G.state.combo_points, "ok")
  Restrict()
  G.Tick(true)
  eq(G.state.combo_points, "secret")
  local found
  for _, l in ipairs(logged) do
    if l[1] == "readability" and l[2]:find("input=combo_points", 1, true) then
      found = l[2]
    end
  end
  eq(type(found), "string", "transition logged")
  eq(found:find("from=ok", 1, true) ~= nil and found:find("to=secret", 1, true) ~= nil, true, found)
  eq(found:find("combat=true", 1, true) ~= nil, true, found)
  mock.restricted = false -- readable again before the fight ends
  G.Tick(true)
  mock.Fire("PLAYER_REGEN_ENABLED")
  local summary
  for _, l in ipairs(logged) do
    if l[1] == "readability_summary" then
      summary = l[2]
    end
  end
  eq(type(summary), "string")
  eq(summary:find("combo_points=ok2/secret2[3..3]", 1, true) ~= nil, true, summary)
  DMGAssistWatchdog = nil
end)

test("diagnostics: our own failing calls are counted and the first of each is logged", function()
  Reset()
  local logged = {}
  DMGAssistWatchdog = { Log = function(kind, data) logged[#logged + 1] = { kind, tostring(data) } end }
  local ns = Boot()
  local before = #logged
  local function Bad() error("attempted compare on a secret value") end
  ns.U.Call(Bad)
  ns.U.Call(Bad)
  local errs = 0
  for i = before + 1, #logged do
    if logged[i][1] == "call_error" then
      errs = errs + 1
    end
  end
  eq(errs, 1, "logged once")
  local count
  for msg, n in pairs(ns.U.callErrors) do
    if msg:find("secret value", 1, true) then
      count = n
    end
  end
  eq(count, 2, "counted every time")
  DMGAssistWatchdog = nil
end)

---------------------------------------------------------------------------
-- Defensives, sounds, highlight, visibility, pooling, movement, snapshot, reset
---------------------------------------------------------------------------
local function DefBook()
  local book = {}
  for _, b in ipairs(FERAL_BOOK) do
    book[#book + 1] = b
  end
  book[#book + 1] = { spellID = 22812, name = "Barkskin" }
  book[#book + 1] = { spellID = 61336, name = "Survival Instincts" }
  mock.book = book
end

test("defensives: boss mod warning -> decided with sound; low health in combat -> game-rendered", function()
  Reset()
  DefBook()
  local dbm = FakeBossMods()
  local ns = Boot()
  eq(ns.Update().defensive, nil, "nothing coming, full health")
  dbm.DBM_TimerBegin("DBM_TimerBegin", "nova", "Shadow Nova", 2, 0, "cd", 1, 2) -- AoE in 2 s
  local r = ns.Update()
  eq(r.defensive.how, "decided")
  eq(r.defensive.id, 22812, "lighter defensive first (Barkskin)")
  eq(r.weave and r.weave.id, 22812, "a decided defensive goes in the red defensive icon")
  eq(r.weave.urgent, true, "needed now: it pulses")
  eq(r.queue[1].source ~= "defensive", true, "slots 1-3 stay the rotation")
  eq(#r.queue <= 3, true, "still three slots")
  eq(#mock.sounds, 1, "defensive sound played")
  mock.cooldowns[22812] = { active = true }
  eq(ns.Update().defensive.id, 61336, "Barkskin on cooldown -> Survival Instincts")
  ns.BossMods.Reset()
  mock.cooldowns[22812] = nil
  Restrict()
  mock.healthPct = { player = 0.2 }
  r = ns.Update()
  eq(r.defensive.how, "render")
  eq(mock.IsSecret(ns.Display.frame.def.alpha), true, "alpha from the secret health curve")
  mock.restricted = false
  mock.healthPct = { player = 0.9 }
  r = ns.Update()
  eq(r.defensive, nil, "readable full health: nothing")
end)

test("sounds: on the rising edge only, throttled, 'none' silences, master switch", function()
  Reset()
  KickBook()
  local ns = Boot()
  mock.targetCast = { notInterruptible = false, id = 9999 }
  ns.Update()
  ns.Update()
  eq(#mock.sounds, 1, "once per interrupt, not every tick")
  eq(mock.sounds[1][2], "Master")
  ns.db.sound_interrupt = "none"
  eq(ns.Sounds.Play("interrupt"), false)
  ns.db.sound_interrupt = nil
  ns.db.sounds = false
  mock.Advance(3)
  eq(ns.Sounds.Play("interrupt"), false, "master switch")
end)

test("action bar highlight: the real button for slot 1 glows", function()
  Reset()
  local ns = Boot()
  local r = ns.Update()
  local id = r.queue[1].id
  ActionButton3 = { action = 3, commandName = "ACTIONBUTTON3", shown = true, events = {}, scripts = {} }
  setmetatable(ActionButton3, getmetatable(ns.Display.frame))
  mock.actionInfo = { [3] = { "spell", id } }
  mock.bindings = { ACTIONBUTTON3 = "3" }
  ns.Display.InvalidateKeybinds()
  ns.Update()
  local hl = ns.Display.frame.hl
  eq(hl:IsShown(), true)
  eq(hl.button, ActionButton3)
  eq(ns.Display.Keybind(id), "3", "binding from the button's commandName")
  ns.db.hud.highlight = false
  ns.Update()
  eq(hl:IsShown(), false)
end)

test("visibility: hidden while mounted out of combat; preview while the settings panel is open", function()
  Reset()
  local ns = Boot()
  mock.mounted = true
  eq(ns.Update(), nil, "mounted")
  mock.mounted = false
  mock.hasTarget = false
  eq(ns.Update(), nil, "no target, out of combat")
  SettingsPanel = { IsShown = function() return true end }
  eq(type(ns.Update()), "table", "previewing while the options are open")
  SettingsPanel = nil
end)

test("pooling: SimC's pool_resource waits for the next action instead of a filler", function()
  Reset()
  local ns = Boot()
  local rec = QRecord({
    { a = "pool_resource", k = "R", p = { for_next = "1" } },
    { a = "rip", k = "R", c = "combo_points>=1" },
    { a = "shred", k = "R" },
  })
  Feral(ns, rec)
  mock.power[4], mock.power[3] = 5, 10
  mock.usable[1079] = { false, true } -- Rip: not enough energy
  local r = ns.Engine.Recommend(rec, {})
  eq(r.main.token, "rip")
  eq(r.main.source, "pool", "pool for Rip, don't Shred")
end)

test("movement: cast-time spells are skipped while moving (setting), instants are not", function()
  Reset()
  local ns = Boot()
  local rec = QRecord({ { a = "rip", k = "R" }, { a = "shred", k = "R" } })
  Feral(ns, rec)
  mock.power[4] = 3
  mock.castTimes = { [1079] = 2000 } -- pretend Rip had a 2 s cast (live value from the game)
  mock.Fire("PLAYER_STARTED_MOVING")
  local r = ns.Engine.Recommend(rec, {})
  eq(r.main.token, "shred")
  mock.Fire("PLAYER_STOPPED_MOVING")
  eq(ns.Engine.Recommend(rec, {}).main.token, "rip")
  ns.db.castWhileMoving = true
  mock.Fire("PLAYER_STARTED_MOVING")
  eq(ns.Engine.Recommend(rec, {}).main.token, "rip", "setting allows it")
end)

test("snapshot: full decision trace stored in the Watchdog log", function()
  Reset()
  local logged = {}
  DMGAssistWatchdog = { Log = function(kind, data) logged[#logged + 1] = { kind, tostring(data) } end }
  Boot()
  SlashCmdList.DMGASSIST("snapshot")
  local lines = 0
  for _, l in ipairs(logged) do
    if l[1] == "snapshot_line" then
      lines = lines + 1
    end
  end
  eq(lines >= 1, true, "trace lines (the walk stops at the pick)")
  DMGAssistWatchdog = nil
end)

test("settings: every option has a tooltip, every section an explanation line", function()
  Reset()
  local ns = Boot()
  local missing = {}
  for name, setting in pairs(mock.settings) do
    if name:find("^DMGASSIST_") and setting.control and not (type(setting.tooltip) == "string" and #setting.tooltip > 10) then
      missing[#missing + 1] = name
    end
  end
  table.sort(missing)
  eq(table.concat(missing, ", "), "", "options without a tooltip")
  local bare = {}
  for _, s in ipairs(ns.Options.subtitles or {}) do
    if not (type(s.text) == "string" and #s.text > 10) then
      bare[#bare + 1] = s.title
    end
  end
  eq(table.concat(bare, ", "), "", "sections without an explanation")
  eq(#(ns.Options.subtitles or {}) >= 20, true, "sections registered")
end)

test("settings: sections on every page, fonts listed, reset restores defaults", function()
  Reset()
  local ns = Boot()
  local headers = 0
  local cats = mock.settingsCategories
  local mine = {}
  for i = #cats - 9, #cats do
    mine[#mine + 1] = cats[i]
  end
  for _, c in ipairs(mine) do
    for _, item in ipairs(c.layout.items) do
      if item.header then
        headers = headers + 1
      end
    end
  end
  eq(headers >= 12, true, "section headers: " .. headers)
  eq(mine[1].name, "DMGAssist", "basic page first")
  local names = {}
  for i, c in ipairs(mine) do
    names[i] = c.name
  end
  eq(table.concat(names, ","), "DMGAssist,Status,Combat,Display,Sounds,Integrations,Advanced,Spells & trinkets,Missing keybinds,Help")
  eq(mine[7].parent, mine[1], "every page under DMGAssist")
  local fonts = mock.settings.DMGASSIST_FONT.options()
  eq(fonts[1].value, "default")
  mock.settings.DMGASSIST_ICONSIZE:SetValue(80)
  mock.settings.DMGASSIST_INTERRUPTMODE:SetValue("off")
  ns.Options.ResetAll()
  eq(ns.db.hud.iconSize, 60)
  eq(ns.db.interruptMode, "smart")
end)

---------------------------------------------------------------------------
-- Forever: WoWSims lists, ranks, new terms, Feral cat/bear switch
---------------------------------------------------------------------------
test("Forever Feral uses the WoWSims list, credits it, and picks the highest rank known", function()
  Reset()
  mock.book = {
    { spellID = 1079, name = "Rip" }, { spellID = 9492, name = "Rip" }, -- ranks 1 and 2 known
    { spellID = 768, name = "Cat Form" }, { spellID = 5221, name = "Shred" },
  }
  local ns = Boot("camelot", 18)
  local rec = ns.Specs.current.data
  eq(rec.simcSource, "wowsims")
  eq(rec.credit, "WoWSims (wowsims.com/forever)")
  eq(ns.SpellMap.SpellID("rip"), 9492, "rank 2 known -> rank 2, not rank 1 or the list's rank 6")
  SlashCmdList.DMGASSIST("")
  local credited = false
  for _, line in ipairs(mock.printed) do
    if line:find("WoWSims", 1, true) then
      credited = true
    end
  end
  eq(credited, true, "credit shown to the player")
end)

test("WoWSims terms: known.<spell>, talentid.<id>, casting.<spell>, health.pct", function()
  Reset()
  mock.talents = { { name = "Blood Frenzy", spellID = 16954, rank = 2 } }
  local ns = Boot()
  local S, UNKNOWN = ns.State, ns.Expr.UNKNOWN
  eq(S.Resolve("known.shred", {}), 1)
  eq(S.Resolve("known.starfire", {}), 0)
  eq(S.Resolve("talentid.16954", {}), 2)
  eq(S.Resolve("talentid.99999", {}), 0, "tree read, not taken")
  eq(S.Resolve("casting.shred", {}), 0)
  mock.casting = { id = 5221, endsIn = 1 }
  eq(S.Resolve("casting.shred", {}), 1)
  mock.healthPct = nil
  eq(S.Resolve("health.pct", {}), 100, "readable out of combat")
  Restrict()
  eq(S.Resolve("health.pct", {}), UNKNOWN)
end)

test("Forever Feral switches to the bear list in Bear Form", function()
  Reset()
  local ns = Boot("camelot", 18)
  local state = ns.Specs.current
  eq(ns.ActiveRecord(state).key, "druid_feral")
  GetShapeshiftFormID = function() return 5 end
  eq(ns.ActiveRecord(state).key, "druid_guardian")
  GetShapeshiftFormID = function() return mock.Secret() end -- hidden: Maul castable means bear
  mock.book = { { spellID = 6807, name = "Maul" } }
  ns.SpellMap.Refresh()
  eq(ns.ActiveRecord(state).key, "druid_guardian", "Maul usable -> bear")
  mock.usable[6807] = { false, false }
  eq(ns.ActiveRecord(state).key, "druid_feral", "Maul unusable (not in bear) -> cat")
  GetShapeshiftFormID = nil
end)

-- Balance's opener, as SimC writes it: a once-per-fight Moonfire, a variable set before the pull and cleared
-- by Celestial Alignment, and a target_if filter that only passes with more than one target.
local function Opener()
  return {
    key = "druid_feral",
    simc = {
      precombat = { { a = "variable", k = "S", p = { name = "opener", value = "1" } } },
      default = {
        { a = "variable", k = "T", c = "buff.tigers_fury.up", p = { name = "opener", op = "set", value = "0" } },
        { a = "run_action_list", k = "T", c = "variable.opener", p = { name = "opener" } },
        { a = "shred", k = "R" },
      },
      opener = {
        { a = "moonfire", k = "R", p = { line_cd = "999" } },
        { a = "moonfire", k = "R", p = { target_if = "refreshable&spell_targets>1" } },
        { a = "tigers_fury", k = "R" },
      },
    },
    spells = { moonfire = { a = { 8921 } }, shred = { a = { 5221 } }, tigers_fury = { a = { 5217 } } },
    spellInfo = {
      [8921] = { n = "moonfire", gcd = 1, d = 16, ap = { { 8921, "enemy" } } },
      [5221] = { n = "shred", gcd = 1 },
      [5217] = { n = "tigers_fury", cd = 30, d = 10, ap = { { 5217, "self" } } },
    },
  }
end

test("line_cd, target_if and fight-long variables move an opener along", function()
  Reset()
  local ns = Boot()
  local rec = Opener()
  Feral(ns, rec)
  Restrict()
  eq(Tokens(ns.Engine.Recommend(rec, {})), "moonfire > tigers_fury > shred", "once-per-fight Moonfire, then on")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 8921)
  mock.Advance(1.5)
  eq(ns.Engine.Recommend(rec, {}).main.token, "tigers_fury", "Moonfire's line used; single target fails target_if")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  mock.Advance(1.5)
  eq(ns.Engine.Recommend(rec, {}).main.token, "shred", "opener variable cleared by the buff")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5221)
  mock.Advance(12)
  eq(ns.Engine.Recommend(rec, {}).main.token, "shred", "buff gone, but the opener stays over for the fight")
  mock.inCombat = false
  mock.Fire("PLAYER_REGEN_ENABLED")
  mock.Advance(5)
  eq(ns.Engine.Recommend(rec, {}).main.token, "moonfire", "a new fight starts with the opener again")
end)

test("hidden auras: one our spells apply and we never cast this fight is down", function()
  Reset()
  local ns = Boot()
  Feral(ns, QRecord({ { a = "shred", k = "R" } }))
  Restrict()
  eq(ns.State.Resolve("buff.tigers_fury.up", {}), 0, "never cast -> down")
  eq(ns.State.Resolve("buff.someone_elses.up", {}), ns.Expr.UNKNOWN, "not ours -> unknown")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  eq(ns.State.Resolve("buff.tigers_fury.up", {}), 1, "cast -> our clock runs")
end)

test("stuck detector: same pick while the player casts other spells stores one snapshot", function()
  Reset()
  local ns = Boot()
  Restrict()
  ns.Update()
  local shown = ns.last.main
  eq(type(shown), "table")
  local other = shown.id == 5221 and 1822 or 5221
  local logged = {}
  DMGAssistWatchdog = { Log = function(kind) logged[kind] = (logged[kind] or 0) + 1 end }
  for _ = 1, 5 do
    ns.OnOwnCast(other)
  end
  DMGAssistWatchdog = nil
  eq(logged.stuck, 1, "logged once")
  eq(logged.snapshot, 1, "one snapshot")
end)

test("each kind has its place: interrupt in slot 1, defensive in its icon, the rotation in the slots", function()
  Reset()
  DefBook()
  local book = mock.book
  KickBook()
  for _, b in ipairs(book) do
    mock.book[#mock.book + 1] = b
  end
  local dbm = FakeBossMods()
  local ns = Boot()
  ns.db.interruptMode = "everywhere"
  mock.targetCast = { notInterruptible = false, id = 9999 }
  dbm.DBM_TimerBegin("DBM_TimerBegin", "nova", "Shadow Nova", 2, 0, "cd", 1, 2)
  local r = ns.Update()
  eq(r.queue[1].source, "interrupt", "slot 1: interrupt")
  eq(r.weave and r.weave.source, "defensive", "the defensive icon: defensive")
  eq(r.queue[2].source ~= "defensive", true, "slot 2: the rotation")
  eq(ns.Display.frame.weave:IsShown(), true, "shown")
end)

test("timing: our cast is timed from its start event when the game hides it; wipe, then flash just before ready", function()
  Reset()
  local ns = Boot()
  ns.Update()
  Restrict()
  mock.castTimes = { [5221] = 2000 } -- shred given a 2 s cast for this test (readable cast time)
  mock.Fire("UNIT_SPELLCAST_START", "player", "guid", 5221)
  local id, left = ns.State.CurrentCast()
  eq(id, 5221, "the cast we started")
  eq(math.abs(left - 2) < 0.01, true, "2 s left: " .. tostring(left))
  local f = ns.Display.frame
  ns.Update()
  eq(f.wipe:IsShown(), true, "not ready: slot 1 darkened")
  eq(f.pressNow, false)
  mock.Advance(1.96) -- 40 ms before the end: inside the 50 ms lead
  ns.Display.RenderTiming(f, ns.Display.Settings())
  eq(f.pressNow, true, "ready 50 ms early")
  eq(f.flash:IsShown(), true, "flash")
  eq(f.wipe:IsShown(), false)
  mock.Advance(0.04)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5221)
  mock.Fire("UNIT_SPELLCAST_STOP", "player", "guid", 5221)
  eq(ns.State.CurrentCast(), nil, "cast over")
  mock.castTimes = nil
end)

test("decision traces: each pick change in combat logs resources, the lines checked and unknown terms", function()
  Reset()
  local ns = Boot()
  local logged = {}
  DMGAssistWatchdog = { Log = function(kind, data) logged[#logged + 1] = { kind, data } end }
  mock.power[3], mock.powerMax[3] = 80, 100
  ns.Update()
  Restrict()
  ns.Update()
  local trace
  for _, l in ipairs(logged) do
    if l[1] == "decision_trace" then
      trace = l[2]
    end
  end
  DMGAssistWatchdog = nil
  eq(type(trace), "string", "a trace was logged")
  eq(trace:find("show=", 1, true) ~= nil, true)
  eq(trace:find("res: ", 1, true) ~= nil, true)
  eq(trace:find("energy=", 1, true) ~= nil, true, "energy listed: " .. trace)
  eq(trace:find("lines: ", 1, true) ~= nil, true)
end)

test("resource floors: energy regenerates at least at base rate, spenders cost, graded after combat", function()
  Reset()
  local ns = Boot()
  Feral(ns, QRecord({ { a = "shred", k = "R" } }))
  mock.power[3] = 20
  ns.Update() -- readable: floor starts at 20
  Restrict()
  mock.Advance(2)
  local lo = ns.Clues.FloorBounds(3)
  eq(math.floor(lo + 0.5), 40, "20 + 2 s x 10/s")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5221) -- shred costs 40
  lo = ns.Clues.FloorBounds(3)
  eq(math.floor(lo + 0.5), 0, "spent 40")
  eq(ns.State.Bounds("energy") ~= nil, true, "the engine sees a range")
  local logged = {}
  DMGAssistWatchdog = { Log = function(kind, data) logged[kind] = data end }
  mock.restricted, mock.inCombat = false, false
  mock.power[3] = 35
  mock.Advance(1)
  mock.Fire("PLAYER_REGEN_ENABLED")
  ns.Update()
  DMGAssistWatchdog = nil
  eq(logged.floor_check ~= nil, true, "after combat: counted vs real logged")
  eq(ns.Clues.stats.floor.wrong, 0, "floor (10) was below the real 35")
end)

test("with the live assistant, only it confirms an uncertain line; a matching rule no longer does", function()
  Reset()
  local ns = Boot()
  local rec = Record()
  rec.simc.finisher = {}
  rec.simc.default[4].c = "!debuff.someone_elses.up" -- rake: uncertain
  rec.blizzard.default[2].c = "level>10"              -- Blizzard's rake rule: true
  Restrict()
  mock.acSpell = 5221                                 -- the live assistant says shred
  local r = ns.Engine.Recommend(rec, { useAssisted = true, burst = false })
  eq(r.main.token, "shred", "rake not taken on the rule's word; the walk reaches shred")
  mock.acSpell = 1822                                 -- the assistant says rake
  r = ns.Engine.Recommend(rec, { useAssisted = true, burst = false })
  eq(r.main.token, "rake")
  eq(r.main.source, "simc+assisted")
end)

test("charges: counted from casts, shared between spells of one entry, recharge one at a time", function()
  Reset()
  local ns = Boot()
  local rec = QRecord({ { a = "eclipse", k = "R" }, { a = "shred", k = "R" } })
  rec.spells.eclipse = { a = { 5217, 5221 } } -- two buttons sharing charges (stand-ins for Lunar / Solar)
  rec.spellInfo[5217] = { n = "lunar", cd = 1, ch = 2, chcd = 32, gcd = 0.5 }
  rec.spellInfo[5221] = { n = "solar", cd = 1, ch = 2, chcd = 32, gcd = 0.5 }
  Feral(ns, rec)
  Restrict()
  eq(ns.State.Charges(5217), 2)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  eq(ns.State.Charges(5221), 1, "the other button shares the charge")
  eq(ns.State.CooldownReady(5221), true)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5221)
  eq(ns.State.Charges(5217), 0)
  eq(ns.State.CooldownReady(5217), false, "no charges: not castable")
  eq(math.floor(ns.State.CooldownRemains(5217) + 0.5), 32)
  mock.now = mock.now + 32.1 -- (clock only: no update tick, which would load the real data again)
  eq(ns.State.Charges(5217), 1, "one charge back after 32 s")
  mock.now = mock.now + 32
  eq(ns.State.Charges(5217), 2, "the second 32 s later")
  -- the game's readable count says one is left right after we spent both: our count wins
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5221)
  local real = C_Spell.GetSpellCharges
  C_Spell.GetSpellCharges = function() -- luacheck: ignore 122
    return { currentCharges = 1, maxCharges = 2 }
  end
  eq(ns.State.Charges(5217), 0, "a wrong readable charge is ignored")
  C_Spell.GetSpellCharges = real -- luacheck: ignore 122
end)

test("fight length: learned per kind of fight from your own fights; SimC default until 5; custom", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  eq(S.FightLength(), 300, "nothing learned yet: SimC's default")
  for _, secs in ipairs({ 22, 30, 18, 25, 40 }) do
    mock.inCombat = true
    mock.Fire("PLAYER_REGEN_DISABLED")
    mock.Advance(secs)
    mock.inCombat = false
    mock.Fire("PLAYER_REGEN_ENABLED")
  end
  eq(S.LearnedFightLength("world"), 25, "median of the open-world fights")
  eq(S.FightLength(), 25, "learned length used")
  ns.db.fightMode = "simc"
  eq(S.FightLength(), 300)
  ns.db.fightMode, ns.db.fightLength = "custom", 120
  eq(S.FightLength(), 120)
  eq(S.LearnedFightLength("boss"), nil, "bosses learned separately")
end)

test("enemy count: remembered through combat-flag gaps; dummies longer; one unreadable plate is not fatal", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  mock.inCombat, mock.nameplates = true, 3
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.plateNames = { "Cleave Training Dummy", "Cleave Training Dummy", "Cleave Training Dummy" }
  eq(S.CountEnemies(), 3, "three dummies hit")
  eq(S.lastCount.dummies, 3)
  -- two of them drop the combat flag between AoE casts: dummies in range keep counting while we fight
  mock.plateCombat = { [2] = false, [3] = false }
  mock.now = mock.now + 6
  eq(S.CountEnemies(), 3, "dummies keep counting")
  mock.now = mock.now + 10
  eq(S.CountEnemies(), 3, "still in combat, still in range")
  -- ordinary mobs: shorter memory
  ns.State.ForgetEnemies()
  mock.plateNames, mock.plateCombat = nil, nil
  eq(S.CountEnemies(), 3)
  mock.plateCombat = { [3] = false }
  mock.now = mock.now + 3
  eq(S.CountEnemies(), 3, "a flicker does not drop it")
  mock.now = mock.now + 4
  eq(S.CountEnemies(), 2)
  -- one plate unreadable: the others still count
  local real = UnitAffectingCombat
  UnitAffectingCombat = function(unit)
    if unit == "nameplate2" then
      return nil
    end
    return real(unit)
  end
  ns.State.ForgetEnemies()
  eq(S.CountEnemies(), 1, "plate 1 counts; 2 unreadable; 3 out of combat")
  eq(S.lastCount.unknown, 1)
  UnitAffectingCombat = real
  mock.Fire("PLAYER_REGEN_ENABLED")
  mock.inCombat, mock.nameplates = false, 0
end)

test("essentials: keep-up stacks from own casts, gap closer only out of melee range", function()
  Reset()
  local book = {}
  for i, b in ipairs(FERAL_BOOK) do
    book[i] = b
  end
  book[#book + 1] = { spellID = 102401, name = "Wild Charge" }
  mock.book = book
  local ns = Boot()
  local X = ns.Essentials
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  -- a stacking keep-up (Ironfur-style), here on a Feral spell so the test book has it
  X.KEEPUPS.druid_feral = { { kind = "stacks", token = "tigers_fury", id = 5217, setting = "ironfurStacks",
    duration = 7 } }
  local realStacks = X.RealStacks
  X.RealStacks = function() return nil end -- in combat: the game hides auras (the check is tested below)
  local r = X.Apply({ main = { id = 5221, token = "shred" }, queue = { { id = 5221, token = "shred" } } })
  eq(r.main.token, "shred", "an off-GCD keep-up never takes slot 1")
  eq(r.weave and r.weave.token, "tigers_fury", "it is the weave badge")
  X.OnOwnCast(5217)
  r = X.Apply({ main = { id = 5221, token = "shred" }, queue = { { id = 5221, token = "shred" } } })
  eq(r.weave, nil, "one at a time: not again within a GCD")
  mock.Advance(1.6)
  r = X.Apply({ main = { id = 5221, token = "shred" }, queue = { { id = 5221, token = "shred" } } })
  eq(r.weave and r.weave.token, "tigers_fury", "next stack after a GCD")
  X.OnOwnCast(5217)
  mock.Advance(1.6)
  X.OnOwnCast(5217)
  mock.Advance(1.6)
  r = X.Apply({ main = { id = 5221, token = "shred" }, queue = { { id = 5221, token = "shred" } } })
  eq(r.weave, nil, "three stacks up (default 3)")
  mock.Advance(30) -- the spell's own duration from the data
  eq(X.Stacks(5217), 0, "stacks expire")
  ns.db.ironfurStacks = 0
  r = X.Apply({ main = { id = 5221, token = "shred" }, queue = { { id = 5221, token = "shred" } } })
  eq(r.main.token, "shred", "0 = off")
  -- the stack check: readable auras (out of combat) are compared with our count and correct it
  X.RealStacks = realStacks
  ns.db.ironfurStacks = 3
  X.stacks[5217] = { GetTime() + 5 }
  mock.auras.player = { { name = "Tiger's Fury", spellId = 5217, duration = 7, expirationTime = GetTime() + 6 },
    { name = "Tiger's Fury", spellId = 5217, duration = 7, expirationTime = GetTime() + 4 } }
  X.check.at = 0
  X.CheckStacks()
  eq(X.Stacks(5217), 2, "corrected to the game's count")
  eq(X.check.mismatch, 1)
  X.check.at = 0
  X.CheckStacks()
  eq(X.check.match, 1, "now they agree")
  mock.auras.player = nil
  X.KEEPUPS.druid_feral = nil
  -- gap closer
  mock.inRange = { [5221] = false, [1822] = false, [1079] = false, [22568] = false, [102401] = true }
  r = X.Apply({ main = { id = 5221, token = "shred" }, queue = { { id = 5221, token = "shred" } } })
  eq(r.main.source, "gapcloser", "out of melee: charge first")
  eq(r.main.id, 102401)
  mock.inRange = { [5221] = true, [1822] = true, [1079] = true, [22568] = true, [102401] = false }
  r = X.Apply({ main = { id = 5221, token = "shred" }, queue = { { id = 5221, token = "shred" } } })
  eq(r.main.token, "shred", "in melee: never shown")
  ns.db.gapClosers = false
  mock.inRange = { [5221] = false, [1822] = false, [1079] = false, [22568] = false, [102401] = true }
  r = X.Apply({ main = { id = 5221, token = "shred" }, queue = { { id = 5221, token = "shred" } } })
  eq(r.main.token, "shred", "setting off")
  mock.Fire("PLAYER_REGEN_ENABLED")
  mock.inCombat = false
end)

test("cooldown flag unreadable: our own clock decides, so a spell just cast is not 'ready'", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  S.learned.cd[1822] = 6
  local real = C_Spell.GetSpellCooldown
  C_Spell.GetSpellCooldown = function() -- luacheck: ignore 122
    return { isEnabled = true } -- isActive / startTime / duration unreadable
  end
  S.lastCast[1822] = GetTime()
  eq(S.CooldownReady(1822), false, "cast 0 s ago, 6 s cooldown")
  mock.Advance(6.1)
  eq(S.CooldownReady(1822), true)
  S.lastCast[1822] = GetTime()
  S.OnGlow(1822, true) -- a proc reset it
  eq(S.CooldownReady(1822), true, "glow after the cast: reset")
  S.OnGlow(1822, false)
  -- the game answers "not active" right after the cast (seen on Guardian Thrash): our clock wins
  C_Spell.GetSpellCooldown = function() -- luacheck: ignore 122
    return { isEnabled = true, isActive = false, isOnGCD = false }
  end
  mock.Advance(1)
  S.lastCast[1822] = GetTime()
  eq(S.CooldownReady(1822), false, "a wrong 'ready' right after the cast is ignored")
  mock.Advance(6.1)
  eq(S.CooldownReady(1822), true)
  C_Spell.GetSpellCooldown = real -- luacheck: ignore 122
  mock.Fire("PLAYER_REGEN_ENABLED")
  mock.inCombat = false
end)

test("stealth buffs end with stealth; talent-gated actions need their talent", function()
  Reset()
  local ns = Boot()
  local S, M = ns.State, ns.SpellMap
  S.auraUntil.prowl = GetTime() + 1000 -- Prowl cast before the pull: no duration of its own
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  eq(S.Resolve("buff.prowl.up", { vars = {} }), 0, "not stealthed: Prowl is down")
  S.auraUntil.prowl = GetTime() + 1000
  eq(S.Resolve("buff.prowl.up", { vars = {} }), 0, "IsStealthed says no")
  mock.Fire("PLAYER_REGEN_ENABLED")
  mock.inCombat = false
  -- moonfire_cat needs Lunar Inspiration
  M.data.moonfire_cat = { a = { 8921 }, req = "lunar_inspiration" }
  M.data.lunar_inspiration = { t = { 155580 } }
  M.talentsRead, M.talentIDs = true, {}
  eq(M.SpellID("moonfire_cat"), nil, "no talent: not castable")
  M.talentIDs[155580] = 1
  eq(M.SpellID("moonfire_cat"), 8921, "with the talent")
end)

test("profiles: old settings become Default; per character, copy, delete; learned data shared", function()
  Reset()
  DMGAssistDB = { queue = 2, hud = { iconSize = 70 }, fights = { world = { 20 } } } -- saved before profiles
  local ns = Boot()
  local P = ns.Profiles
  eq(P.current, "Default")
  eq(ns.db.queue, 2, "old settings kept, as the Default profile")
  eq(ns.db.hud.iconSize, 70)
  eq(DMGAssistDB.fights.world[1], 20, "learned data stays account-wide")
  eq(DMGAssistDB.queue, nil, "moved into the profile")
  P.UseCharacterProfile()
  eq(P.current, P.CharKey())
  eq(ns.db.queue, 2, "starts as a copy")
  ns.db.queue = 1
  eq(DMGAssistDB.profiles.Default.queue, 2, "Default untouched")
  P.Use("Default")
  eq(ns.db.queue, 2)
  P.Use(P.CharKey())
  eq(ns.db.queue, 1, "this character's own settings")
  P.CopyFrom("Default")
  eq(ns.db.queue, 2, "copied from Default")
  eq(P.Delete("Default"), false, "Default can't be deleted")
  P.Delete(P.CharKey())
  eq(P.current, "Default", "back to Default")
  eq(#P.List(), 1)
end)

test("ground effects (consecration.up) are worked out from our own last cast and the spell's duration", function()
  Reset()
  local ns = Boot()
  local rec = QRecord({ { a = "tigers_fury", k = "U", c = "!tigers_fury.up" } })
  Feral(ns, rec)
  local S = ns.State
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  S.combatStart = GetTime() - 30 -- half a minute into the fight
  eq(S.Resolve("tigers_fury.up", {}), 0, "never cast: not up")
  S.lastCast[5217] = GetTime() - 4
  eq(S.Resolve("tigers_fury.up", {}), 1, "cast 4 s ago, lasts 10 s: up")
  eq(math.floor(S.Resolve("tigers_fury.remains", {}) + 0.5), 6)
  S.lastCast[5217] = GetTime() - 11
  eq(S.Resolve("tigers_fury.up", {}), 0, "ran out")
  eq(S.Resolve("shred.up", {}) == ns.Expr.UNKNOWN, true, "a spell with no duration stays unknown")
  mock.inCombat = false
end)

test("enemy count: nameplates up but none counted -> the hostile target is one enemy, not the AoE fallback", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  mock.inCombat, mock.nameplates, mock.hasTarget = true, 2, true
  mock.plateCombat = { [1] = false, [2] = false } -- dummies that never show as in combat
  mock.Fire("PLAYER_REGEN_DISABLED")
  local n, label = S.Targets()
  eq(n, 1, label)
  eq(label, "AUTO 1")
  mock.nameplates = 0 -- no nameplates at all: truly unknown, the fallback mode decides
  label = select(2, S.Targets())
  eq(label, "AOE?")
  mock.Fire("PLAYER_REGEN_ENABLED")
  mock.inCombat, mock.plateCombat = false, nil
end)

test("pets: pet.any.active is read from the game; Call Pet is skipped while a pet is out", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  local exists = UnitExists
  UnitExists = function(unit) -- luacheck: ignore 121
    if unit == "pet" then
      return mock.petOut == true
    end
    return exists(unit)
  end
  mock.petOut = true
  eq(S.Resolve("pet.any.active", { vars = {} }), 1)
  local rec = Record()
  rec.simc.default = { { a = "call_pet_1", k = "R" }, { a = "shred", k = "R" } }
  rec.simc.finisher = {}
  rec.spells = rec.spells or {}
  ns.SpellMap.data.call_pet_1 = { a = { 5221 } } -- a stand-in button
  local r = ns.Engine.Recommend(rec, {})
  eq(r.main.token ~= "call_pet_1", true, "pet out: no Call Pet")
  mock.petOut = false
  eq(S.Resolve("pet.any.active", { vars = {} }), 0)
  UnitExists = exists -- luacheck: ignore 121
  mock.petOut = nil
end)

test("title row: colour-coded ST / AOE with the live count", function()
  Reset()
  local ns = Boot()
  local D = ns.Display
  eq(D.ModeText(), "", "out of combat: nothing")
  mock.inCombat, mock.nameplates = true, 1
  mock.Fire("PLAYER_REGEN_DISABLED")
  local text = D.ModeText()
  eq(text:find("ST 1 target", 1, true) ~= nil, true, text)
  eq(text:find("66ccff", 1, true) ~= nil, true, "ST is light blue")
  mock.nameplates = 4
  text = D.ModeText()
  eq(text:find("AOE 4 targets", 1, true) ~= nil, true, text)
  eq(text:find("ff9933", 1, true) ~= nil, true, "AOE is orange")
  DMGAssist_CycleMode() -- the key: auto -> ST (manual)
  text = D.ModeText()
  eq(text:find("manual", 1, true) ~= nil, true, text)
  mock.inCombat, mock.nameplates = false, 0
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
