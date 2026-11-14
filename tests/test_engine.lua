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
  mock.targetGUID, mock.groupSize, mock.targetLevel = nil, nil, nil
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

test("look-ahead: a line hidden behind a proc now isn't confirmed by Blizzard's rules later", function()
  Reset()
  local ns = Boot()
  Restrict()
  local rec = Record()
  rec.simcOrder = { "default" }
  rec.simc.default = {
    { a = "shred", k = "R", c = "buff.clearcasting.up" }, -- a proc: hidden in combat
    { a = "thrash", k = "R" },
  }
  rec.blizzard = { default = { { a = "shred", k = "R" }, { a = "thrash", k = "R" } } }
  rec.blizzardExcluded = nil
  mock.acSpell = 106830 -- the assistant says Thrash: it doesn't see the proc either
  local r = ns.Engine.Recommend(rec, { useAssisted = true })
  eq(r.main.token, "thrash")
  for i = 2, #r.queue do
    eq(r.queue[i].token == "shred" and r.queue[i].source == "simc+rules", false,
      "slot " .. i .. " is not the proc spell on Blizzard's word (Elemental's Lava Burst, 2026-11-12)")
  end
  mock.acSpell = nil
end)

test("look-ahead: a hidden proc line is never predicted into slots 2-3 unless its button is lit (Outlaw Pistol Shot)", function()
  -- Outlaw: slots 2-3 kept showing Pistol Shot (Opportunity, a random proc), so the row rewrote itself (2026-11-13)
  Reset()
  local ns = Boot()
  Restrict()
  local rec = Record()
  rec.simcOrder = { "default" }
  rec.simc.default = {
    { a = "shred", k = "R", c = "buff.clearcasting.up" }, -- a proc: hidden in combat
    { a = "thrash", k = "R" },
  }
  rec.blizzard = nil
  rec.blizzardExcluded = nil
  mock.acSpell = nil -- no assistant pick (Outlaw often has none)
  -- once Thrash is used, nothing certain is left for slots 2-3
  rec.spellInfo = { [106830] = { n = "thrash", cd = 6, gcd = 1 } }
  ns.SpellMap.SetData(rec)
  local r = ns.Engine.Recommend(rec, { useAssisted = true })
  eq(r.main.token, "thrash")
  for i = 2, #r.queue do
    eq(r.queue[i].token ~= "shred", true, "slot " .. i .. ": no guessed proc spell")
  end
  ns.State.glow[5221] = true -- the game lights Shred: the proc is really up
  r = ns.Engine.Recommend(rec, { useAssisted = true })
  eq(r.main.token, "shred", "a lit button takes slot 1")
  ns.State.glow[5221] = nil
  mock.acSpell = nil
end)

test("look-ahead: pressing a lit proc spell spends its glow (Outlaw's Pistol Shot after Pistol Shot)", function()
  -- slot 2 said Pistol Shot again after a lit Pistol Shot 20 times; you pressed it 4 (Fan the Hammer fires the
  -- whole volley in one press and spends Opportunity, 2026-11-13)
  Reset()
  local ns = Boot()
  Restrict()
  local rec = Record()
  rec.simcOrder = { "default" }
  rec.simc.default = {
    { a = "shred", k = "R", c = "buff.clearcasting.up" }, -- a proc: hidden in combat
    { a = "thrash", k = "R" },
  }
  rec.blizzard = nil
  rec.blizzardExcluded = nil
  mock.acSpell = nil
  rec.spellInfo = { [106830] = { n = "thrash", cd = 6, gcd = 1 } }
  ns.SpellMap.SetData(rec)
  ns.State.glow[5221] = true
  local r = ns.Engine.Recommend(rec, { useAssisted = true })
  eq(r.main.token, "shred", "the lit button now")
  eq(r.queue[2] and r.queue[2].token, "thrash", "then not the same proc again")
  ns.State.glow[5221] = nil
  mock.acSpell = nil
end)

test("look-ahead: a lit proc spell, once pressed, isn't guessed back in (by SimC's lines or Blizzard's rules)", function()
  -- Outlaw 2026-11-13 (1.6.0.252): "pistol_shot(simc+glow) > pistol_shot(guess)" right 1 in 7, and Blizzard's
  -- "rules?" Pistol Shot after Sinister Strike right 3 in 15
  Reset()
  local ns = Boot()
  Restrict()
  local rec = Record()
  rec.simcOrder = { "default" }
  rec.simc.default = {
    { a = "shred", k = "R", c = "buff.clearcasting.up" }, -- a proc: hidden in combat
    { a = "thrash", k = "R" },
  }
  rec.blizzard = nil
  rec.blizzardExcluded = nil
  mock.acSpell = nil
  rec.spellInfo = { [106830] = { n = "thrash", cd = 6, gcd = 1 } }
  ns.SpellMap.SetData(rec)
  ns.State.glow[5221] = true
  local r = ns.Engine.Recommend(rec, { useAssisted = true })
  eq(r.main.token, "shred", "lit now")
  for i = 2, #r.queue do
    eq(r.queue[i].token ~= "shred", true, "slot " .. i .. ": not guessed back once pressed")
  end
  ns.State.glow[5221] = nil
  -- Blizzard's rules for it, its condition unknown: not in slots 2-3 either
  rec.blizzard = { default = { { a = "shred", c = "buff.clearcasting.up", k = "R" } } }
  rec.blizzardOrder = { "default" }
  ns.SpellMap.SetData(rec)
  r = ns.Engine.Recommend(rec, { useAssisted = true })
  eq(r.main.token, "thrash")
  for i = 2, #r.queue do
    eq(r.queue[i].token ~= "shred", true, "slot " .. i .. ": no 'rules?' guess of the proc spell")
  end
  mock.acSpell = nil
end)

test("a ready major cooldown whose line can't be decided (a hidden buff) is taken after a few seconds", function()
  -- Improved Adrenaline Rush "at 2 effective combo points or fewer", Supercharger hidden: slot 3 for a minute
  Reset()
  local ns = Boot()
  Restrict()
  local rec = Record()
  rec.simcOrder = { "default" }
  rec.simc.default = {
    { a = "shred", k = "R", c = "buff.clearcasting.up" }, -- a major here, its line hidden in combat
    { a = "thrash", k = "R" },
  }
  rec.blizzard = nil
  rec.blizzardExcluded = { "shred" }
  mock.acSpell = nil
  ns.SpellMap.SetData(rec)
  ns.Engine.OnCombat()
  local r = ns.Engine.Recommend(rec, { useAssisted = true })
  eq(r.main.token, "thrash", "undecided: not yet")
  mock.Advance(ns.Engine.MAJOR_PATIENCE + 0.5)
  r = ns.Engine.Recommend(rec, { useAssisted = true })
  eq(r.main.token, "shred", "ready a while: taken")
  mock.acSpell = nil
end)

test("combos: follow the lane by the streak's judgement; 3-4 presses, spaced, never at the pull, due when missing", function()
  Reset()
  local ns = Boot()
  local C = ns.Combos
  local done, steps = 0, {}
  local onCombo, onStep = ns.Game.OnCombo, ns.Game.OnComboStep
  ns.Game.OnCombo = function(n)
    done = done + n
  end
  ns.Game.OnComboStep = function(step, total)
    steps[#steps + 1] = step .. "/" .. total
  end
  local CD, KC, BS = { id = 300 }, { id = 400 }, { id = 500 }
  mock.cooldowns = mock.cooldowns or {}
  local isStarter = C.IsStarter
  C.IsStarter = function(p)
    return p and p.id == 300 -- Bestial Wrath: a cooldown
  end
  C.OnFightStart(mock.now)
  eq(C.Planned({ CD, KC, BS }), nil, "never at the pull: a few presses first")
  for _ = 1, C.WARMUP do
    C.OnJudged("hit", 400)
  end
  local ids, already, total = C.Planned({ CD, KC, BS })
  eq(ids and table.concat(ids, ","), "300,400,500") eq(already, 0) eq(total, 3, "three presses")
  eq(C.Planned({ KC, BS }), nil, "slot 1 not a cooldown, a combo not yet due: none")
  C.Planned({ CD, KC, BS })
  eq(C.OnJudged("hit", 300), "start")
  -- the addon switches what's next; the press it judges a hit (slot 2 / 3 or the spell just switched to) keeps it
  eq(C.OnJudged("near", 999), "step", "a press the streak counts keeps the combo (a mid-press switch)")
  eq(C.OnJudged("hit", 400), "done")
  eq(done, 3) eq(table.concat(steps, " "), "1/3 2/3")
  -- not back to back
  mock.now = mock.now + 5
  eq(C.Planned({ CD, KC, BS }), nil, "not within 15 s of the last")
  mock.now = mock.now + C.GAP
  eq(C.Planned({ CD, KC, BS }) ~= nil, true, "after the gap")
  C.OnJudged("hit", 300)
  eq(C.OnJudged("miss", 999), "broken", "only a miss ends it")
  eq(C.run, nil)
  -- a major cooldown: four presses
  mock.now = mock.now + C.GAP + 1
  local _, _, four = C.Planned({ { id = 300, major = true }, KC, BS })
  eq(four, 4)
  -- none for a while: any spell in the box can start one
  C.Planned({})
  mock.now = mock.now + C.DUE + 1
  local due = C.Planned({ KC, BS, KC })
  eq(due and due[1], 400, "due: the spell in the box starts one")
  -- a pause ends it
  C.OnJudged("hit", 400)
  mock.now = mock.now + C.WINDOW + 1
  C.Planned({ KC, BS })
  eq(C.run, nil, "too long a pause ends it")
  -- the first of a fight: sooner than the later ones (Warrior got one only near the end, 2026-11-13)
  C.OnFightStart(mock.now)
  for _ = 1, C.WARMUP do
    C.OnJudged("hit", 400)
  end
  eq(C.Planned({ KC, BS }), nil, "the first: not right after the warm-up")
  mock.now = mock.now + C.FIRST_DUE + 1
  local first = C.Planned({ KC, BS, KC })
  eq(first and first[1], 400, "the first: FIRST_DUE s after the pull, well before DUE")
  eq(C.FIRST_DUE < C.DUE, true)
  C.IsStarter = isStarter
  ns.Game.OnCombo, ns.Game.OnComboStep = onCombo, onStep
  C.Reset()
end)

test("a damage tick the game logs as a cast isn't a press (Spinning Crane Kick's first tick took the press)", function()
  Reset()
  local ns = Boot()
  local isPlayer = IsPlayerSpell
  IsPlayerSpell = function(id)
    return id == 107270 or (isPlayer and isPlayer(id))
  end
  mock.Advance(1)
  eq(ns.IsPress(107270), false, "the tick: known, but not in the spellbook or on a bar")
  IsPlayerSpell = isPlayer
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

test("Black Arrow only above 80% or below 20% target health, or with Deathblow", function()
  Reset()
  local ns = Boot()
  local G, S = ns.Engine, ns.State
  local hp = 500
  local oldHealth, oldMax = UnitHealth, UnitHealthMax
  UnitHealth = function(unit)
    return unit == "target" and hp or 1000
  end
  UnitHealthMax = function()
    return 1000
  end
  local ok, why = G.Castable(466930)
  eq(ok, false, "dummy at 50%")
  eq(why, "target")
  hp = 900
  eq(G.Castable(466930) ~= false, true, "above 80%")
  hp = 150
  eq(G.Castable(466930) ~= false, true, "below 20%")
  hp = 500
  S.glow[466930] = true
  eq(G.Castable(466930) ~= false, true, "Deathblow lights it")
  S.glow[466930] = nil
  UnitHealth, UnitHealthMax = oldHealth, oldMax
end)

test("'Invalid target': the spell is held for that target until you switch", function()
  Reset()
  local ns = Boot()
  local G, S = ns.Engine, ns.State
  S.combatStart = mock.now
  _G.SPELL_FAILED_BAD_TARGETS = "Invalid target"
  S.OnCastFailed(322109)
  S.OnUIError(nil, "Invalid target")
  local ok, why = G.Castable(322109)
  eq(ok, false, "refused for this target")
  eq(why, "target")
  S.OnTargetChanged()
  eq(S.TargetRefused(322109), false, "a new target clears it")
  S.combatStart = nil
end)

test("leveling: Blizzard's pick that can't be used on this target isn't shown in any slot", function()
  Reset()
  local ns = Boot()
  local oldHealth, oldMax = UnitHealth, UnitHealthMax
  UnitHealth = function(unit)
    return unit == "target" and 5000 or 1000
  end
  UnitHealthMax = function()
    return 1000
  end
  local A, B = { id = 5221, source = "simc" }, { id = 1822, source = "simc" }
  local r = ns.Leveling.Lead({ acSpell = 322109, main = A, queue = { A, B } }, nil)
  local shown = false
  for _, p in ipairs(r.queue or {}) do
    shown = shown or p.id == 322109
  end
  eq(shown, false, "Touch of Death on a full-health dummy: not in slot 2")
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
  -- the button is back to Bite (Wailing Arrow fired, Trueshot back on its button): Ravage can't be pressed
  mock.overrides = {}
  mock.Advance(1)
  eq(ns.Engine.Castable(441591), false, "gone with the override (Wailing Arrow stayed in slot 1, 2026-11-12)")
  -- looking ahead, once used it's gone: slots 2-3 don't repeat it (Glacial Spike x3, the second press a miss)
  mock.overrides = { [22568] = 441591 }
  mock.Advance(1)
  local rec = Record()
  rec.simcOrder = { "default" }
  rec.simc.default = { { a = "ravage", k = "R" }, { a = "shred", k = "R" } }
  rec.blizzard, rec.blizzardExcluded = nil, nil
  local r = ns.Engine.Recommend(rec, {})
  eq(r.main and r.main.id, 441591, "now: the button is Ravage")
  for i = 2, #r.queue do
    eq(r.queue[i].id == 441591, false, "slot " .. i .. " isn't Ravage again")
  end
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
  M.info[194509] = { n = "power_word_radiance", gcd = 1.5, cd = 18 } -- one charge here: the order is what's tested
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
  mock.now = mock.now + 0.4 -- past the moment after a press when the game is still reporting the cast
  G.Steady({ main = rip, queue = { rip, shred, rake } })
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
  eq(r.main.token, "rip", "mid-GCD, SimC still wants it: held until pressed (Steady, 2026-11-13)")
  local notNow = G.notNow
  G.notNow = { rip = true } -- SimC's own line rules it out now
  G.Steady({ main = shred, queue = { shred, rip, rake } })
  mock.now = mock.now + 0.55
  r = G.Steady({ main = shred, queue = { shred, rip, rake } })
  eq(r.main.token, "shred", "mid-GCD, ruled out by SimC: a change that holds for 0.5 s shows")
  G.notNow = notNow
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
  r = G.Steady({ main = shred, queue = { shred, rake, rip } })
  eq(r.main.token, "shred", "the decision made before the game reported the cast (still the pressed spell)")
  mock.now = mock.now + 0.1
  r = G.Steady({ main = rake, queue = { rake, rip, shred } })
  eq(r.main.token, "rake", "the real decision a moment later: shown, not held behind the stale one")
  mock.now = mock.now + 0.1
  r = G.Steady({ main = rip, queue = { rip, rake, shred } })
  eq(r.main.token, "rake", "a second change right after the press waits (one free change per press)")
  mock.cooldowns[61304] = nil
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

test("steady slot 1: a moment short of Energy keeps the shown spell (it waits); a long wait lets go", function()
  -- Outlaw 2026-11-13: Energy dipped under Sinister Strike's cost after a press and slot 1 jumped to Blade Flurry
  Reset()
  local ns = Boot()
  local G = ns.Engine
  mock.Fire("PLAYER_REGEN_DISABLED")
  G.ResetSteady()
  local rip, shred = { id = 1079, token = "rip", source = "simc" }, { id = 5221, token = "shred", source = "simc" }
  mock.cooldowns[61304] = { start = mock.now - 0.1, duration = 1.5, active = true }
  G.Steady({ main = rip, queue = { rip, shred } })
  mock.now = mock.now + 0.5
  mock.usable[1079] = { false, true } -- short of Energy
  G.Steady({ main = shred, queue = { shred, rip } })
  mock.now = mock.now + 0.6
  local r = G.Steady({ main = shred, queue = { shred, rip } })
  eq(r.main.token, "rip", "short a moment: still slot 1")
  eq(r.queue[2].token, "shred", "the other pick next")
  mock.now = mock.now + 1.6
  r = G.Steady({ main = shred, queue = { shred, rip } })
  eq(r.main.token, "shred", "short for over 2 s: lets go")
  mock.usable[1079] = nil
  mock.cooldowns[61304] = nil
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

test("steady slot 1: a major cooldown SimC wants now takes slot 1 at once (its window can be one press)", function()
  -- Improved Adrenaline Rush (at 2 combo points or fewer) waited 70 s behind held Sinister Strikes (2026-11-13)
  Reset()
  local ns = Boot()
  local G = ns.Engine
  mock.Fire("PLAYER_REGEN_DISABLED")
  G.ResetSteady()
  local rip, shred = { id = 1079, token = "rip", source = "simc" }, { id = 5221, token = "shred", source = "simc" }
  local tf = { id = 5217, token = "tigers_fury", source = "simc", major = true }
  mock.cooldowns[61304] = { start = mock.now - 0.1, duration = 1.5, active = true }
  G.Steady({ main = rip, queue = { rip, shred } })
  mock.now = mock.now + 0.5
  local r = G.Steady({ main = shred, queue = { shred, rip } })
  eq(r.main.token, "rip", "an ordinary change waits")
  mock.now = mock.now + 0.1
  r = G.Steady({ main = tf, queue = { tf, rip } })
  eq(r.main.token, "tigers_fury", "the major cooldown: at once")
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
  -- a hold lapses on its own
  G.OnPlayerCast(106830, r.main)
  G.OnPlayerCast(106830, r.main)
  G.OnPlayerCast(106830, r.main)
  eq(G.IsHeld(1079), true)
  mock.Advance(G.HOLD_FOR + 1)
  eq(G.IsHeld(1079), false, "back after G.HOLD_FOR seconds")
end)

test("skips: a press decided before slot 1 changed is judged by what slot 1 showed then", function()
  Reset()
  local ns = Boot()
  ns.NoteShown({ id = 1822, token = "rake" })
  mock.Advance(1)
  ns.NoteShown({ id = 106951, token = "berserk" })
  mock.Advance(0.05)
  eq(ns.ShownForPress(1822).id, 1822, "landed 50 ms after slot 1 changed: you pressed what it showed")
  eq(ns.ShownForPress(5221).id, 1822, "another spell: judged by what slot 1 showed when you pressed")
  mock.Advance(1)
  eq(ns.ShownForPress(5221).id, 106951, "long after the change: the current pick")
  -- a cast-time spell: decided when its cast started
  ns.OnOwnCastStart(194153)
  mock.Advance(1.5)
  ns.NoteShown({ id = 1233272, token = "eclipse" })
  mock.Advance(0.3)
  eq(ns.ShownForPress(194153).id, 106951, "Starfire started before Eclipse showed: no skip of Eclipse")
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

test("Outlaw data: Restless Blades - every finisher's combo points take time off Adrenaline Rush and the rest", function()
  -- Adrenaline Rush was counted at its full 180 s and never came back in a fight (2026-11-13). The game's text:
  -- "Finishing moves reduce the remaining cooldown of many Rogue skills by 1 sec per combo point spent."
  Reset()
  local ns = Boot()
  local rec = ns.Data.Get("midnight", "rogue_outlaw")
  local found = {}
  for _, l in ipairs(rec.cdLinks or {}) do
    if l[1] == "*" and l[3] == 1 and l[4] == 79096 and l[5] == 4 then
      found[l[2]] = true
    end
  end
  for _, t in ipairs({ "adrenaline_rush", "between_the_eyes", "blade_flurry", "blade_rush", "killing_spree",
    "roll_the_bones" }) do
    eq(found[t], true, t)
  end
end)

test("a cooldown ready before the pull stays ready until we see it cast, whatever combat's readout says", function()
  -- Adrenaline Rush: /reload, idle, pull - the game read "180 s left" all fight, never cast (Outlaw, 2026-11-13)
  Reset()
  local ns = Boot()
  local S = ns.State
  local rec = QRecord({ { a = "tigers_fury", k = "R" }, { a = "shred", k = "R" } })
  rec.spellInfo[5217] = { n = "tigers_fury", cd = 180, gcd = 0 }
  Feral(ns, rec)
  eq(ns.SpellMap.book[5217] ~= nil, true, "in the spellbook")
  ns.Update() -- out of combat: read ready
  mock.Advance(1.5)
  ns.Update()
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.cooldowns[5217] = { start = mock.now, duration = 180, active = true } -- the readout in combat
  eq(S.CooldownReady(5217), true, "never cast: still ready")
  eq(S.CooldownRemains(5217), 0)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217) -- now really cast
  mock.Advance(1)
  eq(S.CooldownReady(5217), false, "cast: on cooldown")
  mock.cooldowns[5217] = nil
  mock.inCombat, mock.restricted = false, false
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

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
  G.acNow, G.acStuck = nil, true
  eq(G.Castable(5217) ~= false, true, "Blizzard stuck on something outside its rotation (a poison): our clock decides")
  G.acStuck = false
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

test("dead pet: Revive Pet instead of Call Pet (calling a dead pet does nothing)", function()
  Reset()
  mock.book = { { spellID = 883, name = "Call Pet 1" }, { spellID = 982, name = "Revive Pet" },
    { spellID = 5221, name = "Shred" } }
  local ns = Boot()
  local S, G = ns.State, ns.Engine
  local rec = QRecord({ { a = "call_pet_1", k = "R" }, { a = "shred", k = "R" } })
  rec.spells.call_pet_1 = { a = { 883 } }
  rec.spellInfo[883] = { n = "call_pet_1", gcd = 1.5 }
  ns.SpellMap.SetData(rec)
  local saved = { IsPlayerSpell, UnitExists, UnitIsDead }
  local petOut, petBody = false, false
  IsPlayerSpell = function()
    return true
  end
  UnitExists = function(unit)
    if unit == "pet" then
      return petOut or petBody
    end
    return saved[2](unit)
  end
  UnitIsDead = function(unit)
    return unit == "pet" and petBody and not petOut
  end
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  eq(G.Recommend(rec, {}).main.id, 883, "no pet, not known to be dead: Call Pet")
  -- you call it, the cast goes through, no pet appears: it's dead
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 883)
  mock.Advance(1.1)
  eq(S.PetDead(), true)
  eq(G.Recommend(rec, {}).main.id, 982, "Revive Pet")
  -- revived
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 982)
  petOut = true
  eq(G.Recommend(rec, {}).main.token, "shred", "pet out and alive: neither")
  -- its body lies there: dead, read directly
  petOut, petBody = false, true
  S.petDead = nil
  eq(G.Recommend(rec, {}).main.id, 982, "a dead pet's body: Revive Pet")
  IsPlayerSpell, UnitExists, UnitIsDead = saved[1], saved[2], saved[3]
  mock.inCombat = false
end)

test("Fury Whirlwind: 4 stacks used up by attacks; a buff seen out of combat isn't trusted as gone in combat", function()
  Reset()
  mock.book = {}
  for _, id in ipairs({ 190411, 23881, 85288, 184367, 5308, 1719 }) do
    mock.book[#mock.book + 1] = { spellID = id, name = tostring(id) }
  end
  local ns = Boot()
  local S = ns.State
  ns.SpellMap.SetData(ns.Data.specs.midnight.warrior_fury)
  -- out of combat the buff is readable once
  mock.directAuras = { [85739] = { expirationTime = GetTime() + 20, applications = 4 } }
  S.Resolve("buff.whirlwind.up", {})
  mock.directAuras = {}
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 190411)
  mock.Advance(0.1)
  eq(S.Resolve("buff.whirlwind.stack", {}), 4, "Whirlwind: 4 stacks, even though the game now hides the buff")
  -- Rampage reports three casts for one press: one stack
  mock.Advance(1.5)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 184367)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 184367)
  eq(S.Resolve("buff.whirlwind.stack", {}), 3, "one press, one stack")
  for _, id in ipairs({ 23881, 85288, 5308 }) do
    mock.Advance(1.5)
    mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", id)
  end
  eq(S.Resolve("buff.whirlwind.stack", {}), 0, "four attacks: used up, Whirlwind again")
  mock.inCombat, mock.restricted, mock.directAuras = false, false, nil
end)

test("one press reporting several casts (Raging Blow's off-hand hit) is one cast for the clocks and learning", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  local rec = QRecord({ { a = "tigers_fury", k = "R" } })
  rec.spellInfo[5217] = { n = "tigers_fury", cd = 30, gcd = 1.5 }
  rec.spellInfo[5218] = { n = "tigers_fury" } -- a second piece of the same press
  ns.SpellMap.SetData(rec)
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 5217)
  mock.Advance(0.1)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 5218)
  eq(S.learned.timing.tigers_fury, nil, "the off-hand piece isn't a second cast 30 s early")
  -- and a measurement can't push the correction past 60% of the cooldown
  S.LearnTiming(5217, -25, "cast")
  eq(S.learned.timing.tigers_fury.mean, -18, "clamped to 60% of 30 s")
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
  -- a major cooldown the list picks for certain keeps slot 1 (Blizzard's assistant never names those)
  r = ns.Leveling.Lead({ acSpell = 184575, main = { id = 31884, major = true, source = "simc" },
    queue = { { id = 31884, major = true, source = "simc" }, { id = 184575 }, { id = 184575 } } })
  eq(r.main.id, 184575, "the lead itself puts Blizzard's pick first")
  ns.Engine.PromoteReadyMajor(r)
  eq(r.main.id, 31884, "a ready major cooldown takes slot 1 (the shared step, every path)")
  eq(r.queue[2].id, 184575, "Blizzard's pick next")
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

test("welcome: four questions once per profile, suggestions applied, skipped for anyone already set up", function()
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
  -- the style question: two cards side by side (Classic / Flow) with the "switch any time" note, no buttons
  eq(w.cards[1]:IsShown() and w.cards[2]:IsShown(), true, "Classic and Flow cards")
  eq(w.buttons[1]:IsShown(), false, "no plain buttons on the style question")
  eq(w.switchNote:IsShown(), true, "you can switch any time")
  w.cards[2].scripts.OnClick(w.cards[2])
  eq(ns.db.welcomed, true)
  eq(ns.db.gameMode, true, "Game mode chosen")
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

test("mitigation map: tank profiles come from Data/Mitigation.lua (no spells the game no longer has)", function()
  Reset()
  local ns = Boot()
  local T = ns.Tanks
  local war = T.PROFILES.warrior_protection
  eq(war.keep[1].t, "shield_block", "Shield Block kept up while tanking")
  eq(war.reflect[1].t, "spell_reflection")
  local bear = T.PROFILES.druid_guardian
  eq(bear.cappedHeal and bear.cappedHeal.id, 22842, "Frenzied Regeneration at 85% with charges full")
  eq(bear.alsoIcon[1], "ironfur")
  for spec, name in pairs({ deathknight_blood = "rune_tap", druid_guardian = "rage_of_the_sleeper" }) do
    for _, part in ipairs({ "big", "low", "keep", "reflect" }) do
      for _, e in ipairs(T.PROFILES[spec][part]) do
        eq(e.t ~= name, true, name .. " is not in Midnight")
      end
    end
  end
  eq(T.PROFILES.mage_frost, nil, "only tanks have a tank profile")
  eq(ns.Data.mitigation.mage_frost.role, "dps", "every spec has a profile")
end)

test("mitigation map: defensives are per spec - Blood's Death Strike stays in the rotation, Unholy's is a heal", function()
  Reset()
  local ns = Boot()
  local F = ns.Defensives
  local saved = ns.Specs.current.key
  ns.Specs.current.key = "deathknight_blood"
  eq(F.InSet("death_strike"), false, "Blood: Death Strike is the rotation")
  eq(F.IsDefensive({ id = 49998, token = "death_strike" }), false)
  ns.Specs.current.key = "deathknight_unholy"
  eq(F.InSet("death_strike"), true, "Unholy: a heal when low")
  eq(F.IsHeal("death_strike"), true)
  ns.Specs.current.key = saved
end)

test("mitigation map: a defensive in no rotation list is found by its ID; ahead of a hit the 'big' list, no heals", function()
  Reset()
  local ns = Boot()
  local F, M = ns.Defensives, ns.SpellMap
  local saved, spellID, ips = ns.Specs.current.key, M.SpellID, IsPlayerSpell
  ns.Specs.current.key = "rogue_outlaw"
  M.SpellID = function() return nil end -- none of them in SimC's spell list
  local known = { [5277] = true, [1966] = true, [185311] = true } -- Evasion, Feint, Crimson Vial
  IsPlayerSpell = function(id) return known[id] == true end -- luacheck: ignore 121
  local id, token = F.Spell()
  eq(token, "crimson_vial", "low health: the heal first")
  eq(id, 185311)
  token = select(2, F.Spell(true))
  eq(token, "feint", "ahead of a hit: Feint, never the heal")
  known[1966] = nil
  id, token = F.Spell(true)
  eq(token, "evasion", "next in the big list")
  eq(id, 5277)
  ns.Specs.current.key, M.SpellID = saved, spellID
  IsPlayerSpell = ips -- luacheck: ignore 121
end)

test("prep spells: shapeshifts and pre-pull-only spells are preparation, fight spells aren't", function()
  Reset()
  mock.specIndex = 1 -- Balance
  local ns = Boot()
  local E = ns.Engine
  eq(E.IsPrepSpell(24858), true, "Moonkin Form (24858): prep")
  eq(E.IsPrepSpell(194153), false, "Starfire: play")
end)

test("Eclipse is not recommended again while it is active, even with a charge left", function()
  Reset()
  mock.specIndex = 1 -- Balance
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
  ns.SpellMap.byID[1233272] = "lunar_eclipse"
  eq(G.BlockedWhileActive(1233272), true, "the button as Lunar Eclipse: same rule")
  -- Incarnation from the last pull (dummies drop combat between pulls): still blocked (2026-11-12)
  S.lastCastToken.incarnation_chosen_of_elune = GetTime()
  mock.Advance(5)
  S.combatStart = GetTime()
  eq(G.BlockedWhileActive(1233272), true, "a new pull 5 s into Incarnation: still blocked")
  -- and the Eclipse buffs run with it (SimC: celestial_alignment_buff_t starts both for its remains)
  S.auraUntil.incarnation_chosen_of_elune, S.auraUntil.eclipse_lunar = nil, nil
  S.OnSpellcastSucceeded(102560)
  eq((S.auraUntil.eclipse_lunar or 0) > GetTime() + 15, true, "Lunar Eclipse runs with Incarnation")
  eq((S.auraUntil.eclipse_solar or 0) > GetTime() + 15, true, "Solar Eclipse too")
  ns.SpellMap.byID[1233272] = "eclipse"
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

test("mark: the moment, labelled, with the slots, the lane as drawn and the resources", function()
  Reset()
  local logged = {}
  DMGAssistWatchdog = { Log = function(kind, data) logged[#logged + 1] = { kind, tostring(data) } end } -- luacheck: ignore 111
  Boot()
  DMGAssist_Mark()
  local mark, snap
  for _, l in ipairs(logged) do
    if l[1] == "mark" then mark = l[2] end
    if l[1] == "snapshot" then snap = true end
  end
  eq(mark ~= nil and mark:find("n=1", 1, true) ~= nil, true, tostring(mark))
  eq(snap, true, "with a full decision trace")
  DMGAssistWatchdog = nil -- luacheck: ignore 111
end)

test("resource audit: what each cast really did to a readable resource, against our data", function()
  -- Starfire: our data 8 Astral Power, the game 12 (2026-11-13) - this finds such numbers in one fight
  Reset()
  local ns = Boot()
  local G = ns.Diagnostics
  local rec = QRecord({ { a = "shred", k = "S" } })
  Feral(ns, rec) -- combo points readable: 0 of 5; Shred: +1 in our data
  G.OnCombat(true)
  for i = 1, 2 do
    G.AuditCast(5221)
    mock.power[4] = mock.power[4] + 2 -- the game gave 2
    mock.Advance(0.7)
  end
  local text = G.AuditText()
  eq(text ~= nil and text:find("shred pt4 data=+1 seen=+2.0 n=2", 1, true) ~= nil, true, tostring(text))
  G.OnCombat(false)
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
  eq(count, 5)
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

test("a clue that a DoT is up keeps our own clock's time left", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  S.dotUntil.moonfire = GetTime() + 10
  ns.Clues.SetAura("target", "moonfire", true, 5, "assisted")
  local r = S.Resolve("remains", { action = "moonfire", vars = {} })
  eq(type(r), "number", "time left known")
  eq(math.floor(r + 0.5), 10)
end)

test("keep-up DoT: skipped presses set it aside; not shown when it's on no bar you can see", function()
  Reset()
  local ns = Boot()
  local G, X = ns.Engine, ns.Essentials
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  local shown = { id = 8921, token = "moonfire", source = "keepup" }
  ns.SpellMap.info[5221] = ns.SpellMap.info[5221] or { n = "shred", gcd = 1 }
  for _ = 1, G.SKIPS_TO_HOLD do
    G.OnPlayerCast(5221, shown, true, { shown })
  end
  eq(G.IsHeld(8921), true, "pressed past it: set aside")
  G.held, G.skips = {}, {}
  local kb, bf = ns.Display.Keybind, ns.Display.ButtonFor
  ns.Display.Keybind = function() return nil end
  ns.Display.ButtonFor = function() return nil end
  eq(X.OnThisBar(8921), false, "no key and no visible button: not on this bar")
  ns.Display.Keybind = function() return "5" end
  eq(X.OnThisBar(8921), true, "bound: shown")
  ns.Display.Keybind, ns.Display.ButtonFor = kb, bf
  mock.inCombat = false
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
  ns.Specs.current.key = "rogue_subtlety" -- (no crit points: Feral's are tested below)
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

test("interrupts: a boss mod interrupt timer running out counts as its call (DBM /dbm test)", function()
  Reset()
  KickBook()
  local dbm = FakeBossMods()
  local ns = Boot()
  local logged = {}
  DMGAssistWatchdog = { Log = function(kind, data) logged[#logged + 1] = kind end }
  mock.instance = true
  mock.targetCast = { notInterruptible = false, id = 9999 }
  mock.important = {}
  dbm.DBM_TestModStarted("DBM_TestModStarted")
  dbm.DBM_TimerBegin("DBM_TimerBegin", "t4", "Important Interrupt", 20, "136116", "cd", nil, 4)
  eq(ns.Update().interrupt, nil, "20 s out: not yet")
  eq(ns.BossMods.Callout(), nil, "beyond the 10 s look-ahead: no callout yet")
  mock.now = mock.now + 15
  eq(ns.BossMods.Callout().label, "INTERRUPT", "countdown in the last 10 s")
  eq(ns.BossMods.Callout().seconds ~= nil, true)
  mock.now = mock.now + 5
  local r = ns.Update()
  eq(r.interrupt and r.interrupt.why, "bossmod", "timer ran out: the cast starts now")
  mock.now = mock.now + 4
  eq(ns.Update().interrupt, nil, "the call fades after a few seconds")
  local seen = table.concat(logged, ",")
  eq(seen:find("bossmod_test") ~= nil, true, "test start logged")
  eq(seen:find("bossmod_timer") ~= nil, true, "timer logged")
  eq(seen:find("bossmod_alert") ~= nil, true, "call logged")
  DMGAssistWatchdog = nil
  ns.BossMods.Reset()
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
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "x", 5221) -- a press already on its way as it appeared
  eq(ns.Interrupts.stats.skipped, 0, "not skipped within the first moments (Blood: gone after 0.8 s, 2026-11-12)")
  eq(ns.Update().interrupt.how, "decided", "still up")
  mock.Advance(2.1)
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

test("interrupts: the fight summary counts the target's casts and the ones it couldn't be interrupted on", function()
  -- "never saw an interrupt against this boss" (2026-11-13): nothing said whether the boss cast at all
  Reset()
  KickBook()
  local ns = Boot()
  local I = ns.Interrupts
  local casts0, locked0 = I.stats.targetCasts, I.stats.locked
  mock.targetCast = { notInterruptible = true, id = 9999 }
  mock.Fire("UNIT_SPELLCAST_START", "target")
  ns.Update()
  ns.Update()
  eq(I.stats.targetCasts - casts0, 1, "one cast")
  eq(I.stats.locked - locked0, 1, "counted once, however many updates")
  mock.targetCast = { notInterruptible = false, id = 9998 }
  mock.Fire("UNIT_SPELLCAST_START", "target")
  eq(ns.Update().interrupt.how, "decided")
  eq(I.stats.targetCasts - casts0, 2)
  eq(I.stats.locked - locked0, 1, "an interruptible one isn't locked")
end)

test("interrupts: each alert logs the cast's length and how long it stayed up", function()
  -- "popping for less than a second" (2026-11-13): the boss's short cast, or us hiding it early?
  Reset()
  local logged = {}
  DMGAssistWatchdog = { Log = function(kind, data) logged[#logged + 1] = { kind, data } end } -- luacheck: ignore 111
  KickBook()
  local ns = Boot()
  mock.targetCast = { notInterruptible = false, id = 9999 }
  ns.Update()
  mock.Advance(0.6)
  mock.targetCast = nil -- the cast ends
  ns.Update()
  local shown, gone
  for _, l in ipairs(logged) do
    if l[1] == "interrupt_shown" then shown = l[2] end
    if l[1] == "interrupt_gone" then gone = l[2] end
  end
  eq(tostring(shown):find("cast=1.0", 1, true) ~= nil, true, "the cast's whole length: " .. tostring(shown))
  eq(tostring(gone):find("up=0.6", 1, true) ~= nil, true, "how long it was up: " .. tostring(gone))
  DMGAssistWatchdog = nil -- luacheck: ignore 111
end)

test("interrupts: skip detected from the GCD when cast events are secret", function()
  Reset()
  KickBook()
  local ns = Boot()
  mock.targetCast = { notInterruptible = false, id = 9999 }
  ns.Update()
  mock.Advance(2.1) -- past the moment a press already on its way still lands
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

test("diagnostics: prediction - pressing slot 1, was slot 2 right about what came next?", function()
  Reset()
  local ns = Boot()
  local G = ns.Diagnostics
  G.OnCombat(true)
  local SS, PS, DI = { id = 193315, token = "sinister_strike", source = "simc" },
    { id = 185763, token = "pistol_shot", source = "simc" }, { id = 2098, token = "dispatch", source = "rules" }
  -- predicted Dispatch, Dispatch came: a hit
  G.OnPress(193315, SS, { main = SS, queue = { SS, DI, PS } })
  mock.Advance(0.2)
  G.OnPick({ main = DI, queue = { DI, PS } }) -- (slot 3 said Pistol Shot: it is slot 2 now)
  mock.Advance(0.5)
  G.OnPick({ main = DI, queue = { DI } })
  G.OnPick({ main = PS, queue = { PS } }) -- slot 1 changes its mind before the press
  G.OnPick({ main = { id = 6552, token = "kick", source = "interrupt" }, queue = {} }) -- a situation: apart
  G.OnPick({ main = PS, queue = { PS } })
  mock.Advance(0.5)
  -- predicted Dispatch, Pistol Shot came (a proc): a miss, named
  G.OnPress(185763, PS, { main = PS, queue = { PS, DI } })
  G.OnPress(185763, PS, { main = PS, queue = { PS, DI } }) -- the volley's next shot: the same press
  mock.Advance(0.2)
  G.OnPick({ main = SS, queue = { SS } })
  mock.Advance(0.7)
  G.OnPress(193315, SS, { main = SS, queue = { SS } }) -- a steady window
  mock.Advance(0.7)
  -- a press of something other than slot 1 predicts nothing
  G.OnPress(2098, SS, { main = SS, queue = { SS, DI } })
  mock.Advance(0.2)
  G.OnPick({ main = PS, queue = { PS } })
  eq(G.PredictionText(), "hit=50% n=2 misses: dispatch>sinister_strikex1 | slot1_steady=50% windows=2 changes=1 "
    .. "situational=2 | slot3=100% n3=1 | slot2_by_source rules=1/2 | lastpress_baseline=100% n=2 | "
    .. "followed=75% presses=4")
  G.OnCombat(false)
  eq(G.PredictionText(), nil, "starts over each fight")
end)

test("learner (shadow): learns what you press next per situation, scores itself against slot 2, keeps it", function()
  Reset()
  local logged = {}
  DMGAssistWatchdog = { Log = function(kind, data) logged[#logged + 1] = { kind, tostring(data) } end } -- luacheck: ignore 111
  local ns = Boot()
  local L = ns.Learner
  local rec = QRecord({ { a = "shred", k = "S" }, { a = "rip", k = "S" } })
  Feral(ns, rec)
  ns.Specs.current = { key = "druid_feral", status = "ready", data = rec, branch = "midnight", client = "Midnight" }
  ns.global = ns.global or {}
  ns.global.learner = nil
  L.OnCombat(true)
  local SH, RI = { id = 5221, token = "shred", source = "simc" }, { id = 1079, token = "rip", source = "simc" }
  for _ = 1, 8 do -- always Shred then Rip; slot 2 keeps saying Shred again
    L.OnPress(5221, SH, { main = SH, queue = { SH, SH } })
    L.OnPress(5221, SH, { main = SH, queue = { SH, SH } }) -- (the same press: ignored)
    mock.Advance(1)
    L.OnPress(1079, RI, { main = RI, queue = { RI, SH } })
    mock.Advance(1)
  end
  L.OnPress(999999, nil, nil) -- not a rotation spell: ignored
  local text = L.SummaryText()
  eq(text:find("presses=16", 1, true) ~= nil, true, text)
  eq(text:find("slot2=47% n=15", 1, true) ~= nil, true, "slot 2 right after Rip only (7 of 15): " .. text)
  local store = L.Store()
  local guess = L.Guess(store, { "shred" })
  eq(guess, "rip", "after Shred: Rip")
  L.OnCombat(false)
  local summary, presses = nil, 0
  for _, l in ipairs(logged) do
    if l[1] == "learner_summary" then summary = l[2] end
    if l[1] == "press" then presses = presses + 1 end
  end
  eq(summary ~= nil, true, "learner_summary logged")
  eq(presses, 16, "one press line per press")
  eq(store.fights, 1)
  eq(store.next.shred.rip < 8 and store.next.shred.rip > 7, true, "older counts weigh a little less after the fight")
  eq(ns.global.learner[next(ns.global.learner)] == store, true, "kept in DMGAssistDB (across sessions)")
  DMGAssistWatchdog = nil -- luacheck: ignore 111
end)

test("learner: live in slot 2 only after clearly beating SimC's forecast; steps back when its lead shrinks", function()
  Reset()
  local ns = Boot()
  local L = ns.Learner
  local rec = QRecord({ { a = "shred", k = "S" }, { a = "rip", k = "S" }, { a = "rake", k = "S" } })
  rec.spells.rake = { a = { 1822 } }
  Feral(ns, rec)
  ns.Specs.current = { key = "druid_feral", status = "ready", data = rec, branch = "midnight", client = "Midnight" }
  ns.global = ns.global or {}
  ns.global.learner = nil
  mock.Fire("PLAYER_REGEN_DISABLED")
  local store = L.Store()
  store.next["shred"] = { rip = 9, rake = 1 } -- after Shred: Rip, 9 times in 10
  local SH, RA = { id = 5221, token = "shred", source = "simc" }, { id = 1822, token = "rake", source = "simc" }
  local function Result()
    return { main = SH, queue = { SH, RA, { id = 22568, token = "ferocious_bite", source = "simc" } } }
  end
  store.vs = { n = 60, learner = 40, simc = 10 }
  local r = L.Apply(Result())
  eq(r.queue[2].token, "rake", "too few presses yet, and only the coarse situation known: SimC's slot 2")
  store.next["shred<-"] = { rip = 6 } -- this exact situation: 6 of 6
  r = L.Apply(Result())
  eq(r.queue[2].token, "rip", "a situation it knows well: slot 2 at once, before the whole spec qualifies")
  store.next["shred<-"] = nil
  store.vs = { n = 120, learner = 60, simc = 40 }
  r = L.Apply(Result())
  eq(r.queue[2].token, "rip", "a clear lead over 120 presses: live")
  eq(r.queue[2].source, "learned")
  eq(r.queue[3].token, "rake", "SimC's forecast moves to slot 3")
  eq(#r.queue, 3)
  eq(r.main.token, "shred", "slot 1 untouched")
  eq(r.simcNext, "rake", "SimC's own forecast kept for scoring")
  store.vs = { n = 120, learner = 50, simc = 45 } -- lead 4%: inside the gap, stays live
  eq(L.Live(store), true)
  store.vs = { n = 120, learner = 46, simc = 45 } -- lead under 3%: back to shadow
  eq(L.Live(store), false)
  store.vs = { n = 120, learner = 50, simc = 45 }
  eq(L.Live(store), false, "and stays there until it leads by 10% again")
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

test("diagnostics: slot 1 moving on because you'd already pressed it (spell queue) isn't a change", function()
  -- Outlaw 2026-11-13: 23 of 29 counted changes were the next cast starting from the queue, its event ~0.1 s later
  Reset()
  local ns = Boot()
  local G = ns.Diagnostics
  G.OnCombat(true)
  local SS, PS, DI = { id = 193315, token = "sinister_strike", source = "simc" },
    { id = 185763, token = "pistol_shot", source = "simc" }, { id = 2098, token = "dispatch", source = "simc" }
  G.OnPress(193315, SS, { main = SS, queue = { SS, PS } })
  mock.Advance(0.2)
  G.OnPick({ main = PS, queue = { PS, DI } }) -- settled: slot 1 is Pistol Shot
  mock.Advance(0.8)
  G.OnPick({ main = DI, queue = { DI } }) -- the queued Pistol Shot started: slot 1 moves on...
  mock.Advance(0.08)
  G.OnPress(185763, PS, { main = PS, queue = { PS, DI } }) -- ...and its cast event arrives
  mock.Advance(0.2)
  G.OnPick({ main = DI, queue = { DI } })
  mock.Advance(0.8)
  G.OnPick({ main = SS, queue = { SS } }) -- a real change: nothing pressed
  mock.Advance(0.5)
  G.OnPress(193315, SS, { main = SS, queue = { SS } })
  local text = G.PredictionText()
  eq(text:find("slot1_steady=50% windows=2 changes=1", 1, true) ~= nil, true, text)
  G.OnCombat(false)
end)

test("diagnostics: major cooldowns - state at the pull, when one comes back, the slot it first shows in", function()
  -- "it didn't redo Adrenaline Rush when it was ready" (Outlaw, 2026-11-13)
  Reset()
  local logged = {}
  DMGAssistWatchdog = { Log = function(kind, data) logged[#logged + 1] = { kind, tostring(data) } end } -- luacheck: ignore 111
  local ns = Boot()
  local G = ns.Diagnostics
  local rec = QRecord({ { a = "tigers_fury", k = "S" }, { a = "shred", k = "S" } })
  rec.blizzardExcluded = { "tigers_fury" }
  Feral(ns, rec)
  ns.Specs.current = { key = "druid_feral", status = "ready", data = rec, branch = "midnight", client = "Midnight" }
  mock.cooldowns[5217] = { start = mock.now - 10, duration = 30, active = true } -- used before the pull
  G.OnOwnCast(5217, false)
  mock.Advance(2)
  G.OnCombat(true)
  local TF, SH = { id = 5217, token = "tigers_fury", source = "simc" }, { id = 5221, token = "shred", source = "simc" }
  G.OnPick({ main = SH, queue = { SH } })
  mock.Advance(21)
  mock.cooldowns[5217] = nil -- back
  G.OnPick({ main = SH, queue = { SH, TF } })
  G.OnPick({ main = TF, queue = { TF, SH } })
  local lines = {}
  for _, l in ipairs(logged) do
    if l[1]:find("^major") then
      lines[#lines + 1] = l[1] .. " " .. l[2]
    end
  end
  eq(lines[1]:find("majors_at_pull tigers_fury=not_ready", 1, true) ~= nil, true, lines[1])
  eq(lines[2], "major ready=true s=tigers_fury")
  eq(lines[3], "major_shown s=tigers_fury slot=2", "first seen in slot 2")
  eq(#lines, 3, "logged once")
  local prepull
  for _, l in ipairs(logged) do
    if l[1] == "prepull_casts" then prepull = l[2] end
  end
  eq(prepull, "tigers_fury@-2.0", "the cast just before the pull")
  G.OnCombat(false)
  DMGAssistWatchdog = nil -- luacheck: ignore 111
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

test("defensives: a heal you just cast isn't asked for again while it lands (Regrowth stayed up, 2026-11-12)", function()
  Reset()
  local ns = Boot()
  local F, M = ns.Defensives, ns.SpellMap
  local tokens, sid, tfi = F.TOKENS, M.SpellID, M.TokenForID
  F.TOKENS = { "regrowth" }
  M.SpellID = function(t) return t == "regrowth" and 8936 or sid(t) end
  M.TokenForID = function(id) return id == 8936 and "regrowth" or tfi(id) end
  eq(F.Spell(), 8936, "low and nothing else: Regrowth")
  F.OnOwnCast(8936)
  eq(F.Spell(), nil, "just cast: not again for a moment")
  mock.Advance(F.HEAL_GRACE + 0.1)
  eq(F.Spell(), 8936, "still low after it landed: again")
  F.TOKENS, M.SpellID, M.TokenForID = tokens, sid, tfi
end)

test("defensives: timed from the buff's duration - time to press it, and the hit lands well inside it", function()
  Reset()
  DefBook()
  local dbm = FakeBossMods()
  local ns = Boot()
  local F = ns.Defensives
  local info = ns.SpellMap.Info(22812)
  eq(info and info.d, 8, "Barkskin lasts 8 s (spell data)")
  eq(F.Lead(22812, 3), 4.5, "8 s buff: shown 4.5 s before (2.5 s to press, 1.5 s spare at the end)")
  local real = ns.SpellMap.Info
  ns.SpellMap.Info = function(id)
    return ({ [1] = { d = 0 }, [2] = { d = 3 }, [3] = { d = 60 }, [4] = { d = 6 } })[id]
  end
  eq(F.Lead(1, 3), 3, "no duration (a heal): the Big hit warning setting")
  eq(F.Lead(2, 3), 1.5, "3 s buff: late enough that it still covers the hit")
  eq(F.Lead(3, 3), 6, "long buff: capped, boss timers drift")
  eq(F.Lead(4, 3), 3.5, "6 s buff")
  eq(F.Lead(4, 5), 4.5, "a longer setting is honoured up to what the buff can cover")
  ns.SpellMap.Info = real
  dbm.DBM_TimerBegin("DBM_TimerBegin", "boom", "Boom!", 6, 0, "cd", 1, 2) -- AoE in 6 s
  eq(ns.Update().defensive, nil, "6 s out: too early for Barkskin")
  mock.now = mock.now + 1.6
  local r = ns.Update()
  eq(r.defensive and r.defensive.why, "aoe", "4.4 s out: Barkskin now")
  ns.BossMods.Reset()
end)

test("defensives: one per hit - once Barkskin is up the hit is covered; a heal is never asked for ahead of a hit", function()
  Reset()
  DefBook()
  mock.book[#mock.book + 1] = { spellID = 8936, name = "Regrowth" }
  local dbm = FakeBossMods()
  local ns = Boot()
  dbm.DBM_TimerBegin("DBM_TimerBegin", "aoe", "Void Eruption", 4, 0, "cd", 1, 2) -- AoE in 4 s
  eq(ns.Update().defensive.id, 22812, "Barkskin for the hit")
  ns.OnOwnCast(22812)
  mock.cooldowns[22812] = { active = true }
  mock.now = mock.now + 1
  eq(ns.Update().defensive, nil, "Barkskin is up: covered, not Survival Instincts or Regrowth next")
  -- no defensive up, Barkskin on cooldown, no other real defensive known: Regrowth (a heal) is not a pre-hit one
  mock.now = mock.now + 10
  for i = #mock.book, 1, -1 do
    if mock.book[i].spellID == 61336 then
      table.remove(mock.book, i)
    end
  end
  ns.SpellMap.Refresh()
  dbm.DBM_TimerBegin("DBM_TimerBegin", "aoe2", "Void Eruption", 2, 0, "cd", 1, 2)
  ns.Update()
  local d = ns.Update().defensive
  eq(d == nil or d.why ~= "aoe", true, "no Regrowth at full health for an incoming AoE")
  ns.BossMods.Reset()
  mock.cooldowns[22812] = nil
end)

test("defensives: timed to when the boss's cast finishes (DBM times the cast's start)", function()
  Reset()
  DefBook()
  local dbm = FakeBossMods()
  local ns = Boot()
  mock.castTimes = { [777] = 3000 } -- a 3 s cast
  dbm.DBM_TimerBegin("DBM_TimerBegin", "aoe", "Void Eruption", 6, 0, "cd", 777, 2) -- cast starts in 6 s
  eq(math.floor(ns.BossMods.NextHit("aoe") + 0.5), 9, "damage lands in 6 + 3 s")
  eq(ns.Update().defensive, nil, "9 s from the damage: too early")
  mock.now = mock.now + 4.6
  eq(ns.Update().defensive and ns.Update().defensive.id, 22812, "4.4 s from the damage: Barkskin")
  mock.now = mock.now + 2
  eq(ns.Update().defensive and ns.Update().defensive.id, 22812, "timer ran out, boss still casting: still shown")
  mock.castTimes = nil
  ns.BossMods.Reset()
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
  local _, rel = hl:GetPoint(1)
  eq(rel ~= ActionButton3, true, "placed on screen, never anchored to Blizzard's button (taint)")
  eq(ns.Display.Keybind(id), "3", "binding from the button's commandName")
  ns.db.hud.highlight = false
  ns.Update()
  eq(hl:IsShown(), false)
end)

test("channels: slot 1 says HOLD while one runs, GO when it ends; none for channels SimC cuts short", function()
  Reset()
  local ns = Boot()
  local D, S, G = ns.Display, ns.State, ns.Engine
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  ns.Update()
  local f = D.frame
  local cfg = D.Settings()
  S.OnOwnCastStart(5221, true) -- a channel of ours (Shred stands in), 2 s by our clock
  D.RenderTiming(f, cfg)
  eq(f.hold:IsShown(), true, "HOLD while it runs")
  eq(f.hold:GetText(), "HOLD")
  mock.Advance(3)
  D.RenderTiming(f, cfg)
  eq(f.hold:IsShown(), false, "ended: the text goes (it covered the keybind)")
  eq(f.goAt ~= nil, true, "GO is the green border flash")
  -- a channel the list chains or cuts short: no HOLD
  local record = ns.Specs.current.data
  record.simc.default[#record.simc.default + 1] = { a = "shred", k = "R", p = { chain = "1" } }
  eq(G.ClipAllowed(5221, { simc = { default = { { a = "shred", p = { chain = "1" } } } } }), true)
  eq(G.ClipAllowed(1822, { simc = { default = { { a = "rake" } } } }), false)
  table.remove(record.simc.default)
  -- Bladestorm isn't a channel to the game, but nothing else can be pressed while it runs: the same HOLD
  ns.SpellMap.byID[227847] = "bladestorm"
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-bs", 227847)
  local id, left = S.Channeling()
  eq(id, 227847, "Bladestorm holds slot 1 (Arms: the bar went empty, 2026-11-10)")
  eq(left > 5, true)
  mock.Advance(7)
  eq(S.Channeling(), nil, "over after its duration")
  mock.inCombat = false
end)

test("area spells centred on you: not while the target is known to be farther than their radius", function()
  Reset()
  local ns = Boot()
  local G = ns.Engine
  ns.SpellMap.byID[106785] = "swipe_cat"
  local real = ns.Clues.DistanceBounds
  ns.Clues.DistanceBounds = function() return 30.5, math.huge end
  eq(G.TooFar(106785), true, "target beyond 30 yards: Swipe (8 yards) does nothing")
  eq(select(2, G.Castable(106785)), "range")
  ns.Clues.DistanceBounds = function() return 0, 30 end
  eq(G.TooFar(106785), false, "can't tell: allowed")
  ns.Clues.DistanceBounds = real
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
  -- Spiritwalker's Grace (or Hover, Ice Floes) cast: cast-time spells come back while it lasts
  ns.db.castWhileMoving = false
  ns.State.lastCast[79206] = GetTime()
  eq(ns.Engine.Recommend(rec, {}).main.token, "rip", "Spiritwalker's Grace: cast while moving (Elemental, 2026-11-10)")
  mock.Advance(16)
  eq(ns.Engine.Recommend(rec, {}).main.token, "shred", "after it ends: skipped again")
  mock.Fire("PLAYER_STOPPED_MOVING")
end)

test("enemy count: an enemy we fight that steps out of range a moment still counts (no 1..7 jumps on the move)", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  local rec = QRecord({ { a = "shred", k = "R" } })
  rec.spellInfo[5221] = { n = "shred", r = 5, gcd = 1 } -- a ranged spell to probe range with
  Feral(ns, rec)
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.nameplates = 3
  eq(S.CountEnemies(), 3)
  mock.inRange = setmetatable({}, { __index = function() return false end }) -- every spell: out of range
  mock.Advance(0.5)
  eq(S.CountEnemies(), 3, "out of range for half a second: still counted")
  mock.Advance(2)
  eq(S.CountEnemies(), 0, "gone for good after the grace")
  mock.inRange = nil
  mock.Fire("PLAYER_REGEN_ENABLED")
  mock.inCombat = false
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

test("settings preview: the HUD docks beside the settings window with both small icons, and goes back", function()
  Reset()
  local ns = Boot()
  local f = ns.Display.frame
  ns.db.point = { "CENTER", "CENTER", 10, -150 }
  SettingsPanel = SettingsPanel or CreateFrame("Frame", "SettingsPanel", UIParent)
  SettingsPanel:Show()
  local r = ns.Update()
  eq(f.docked, true, "docked beside the settings")
  eq(r.weave and r.weave.sample, true, "sample defensive shown")
  eq(r.trinket and r.trinket.sample, true, "sample item shown")
  SettingsPanel:Hide()
  r = ns.Update()
  eq(f.docked, false, "back in its place")
  eq(r and r.weave and r.weave.sample or nil, nil, "no samples outside the preview")
  local p1, _, _, x = f:GetPoint()
  eq(p1, "CENTER")
  eq(x, 10, "its saved position")
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

test("settings preview: every Display control shows - sample mode title, call-out and keybinds; icons re-skin", function()
  Reset()
  local ns = Boot()
  local D = ns.Display
  local f = D.Create()
  _G.SettingsPanel = setmetatable({ events = {}, scripts = {} }, getmetatable(UIParent))
  eq(D.ModeText(), "", "out of combat, not previewing: no mode")
  D.SetPreviewDock(true)
  eq(D.InPreview(), true)
  eq(D.ModeText():find(ns.L["AOE"], 1, true) ~= nil, true, "a sample mode title in the preview")
  local A = { id = 101, token = "a" }
  D.Update({ main = A, queue = { A } }, true)
  eq(f.callout:IsShown(), true, "a sample call-out")
  eq(f.slots[1].key:GetText(), "5", "a sample keybind where none is bound")
  local reskins = 0
  ns.Integrations.group = { ReSkin = function() reskins = reskins + 1 end }
  ns.db.hud = ns.db.hud or {}
  ns.db.hud.iconSize = 80
  D.Rebuild()
  eq(reskins, 1, "Masque lays its skin out at the new size")
  eq(f.slots[1].width, 80)
  ns.Integrations.group = nil
  D.SetPreviewDock(false)
  eq(D.InPreview(), false)
  _G.SettingsPanel = nil
end)

test("settings: Display quick picks set size and place, and read Custom after fine-tuning", function()
  Reset()
  local ns = Boot()
  local size, place = mock.settings.DMGASSIST_SIZEPRESET, mock.settings.DMGASSIST_PLACEPRESET
  eq(size:GetValue(), "medium", "default scale reads Medium")
  size:SetValue("large")
  eq(ns.db.hud.scale, 1.3)
  eq(size:GetValue(), "large")
  ns.db.hud.scale = 1.12
  eq(size:GetValue(), "custom", "a slider value of its own is Custom")
  size:SetValue("custom")
  eq(ns.db.hud.displayCustom, true, "Custom shows every Display option")
  eq(ns.db.hud.scale, 1.12, "and changes nothing by itself")
  eq(#ns.Options.displayCustomInits > 3, true, "the fine-tuning sections are the ones Custom shows")
  size:SetValue("small")
  eq(ns.db.hud.displayCustom, nil, "a size hides them again")
  eq(ns.db.hud.scale, 0.8)
  place:SetValue("below")
  eq(ns.db.point[3], ns.Welcome.BELOW[3])
  eq(place:GetValue(), "below")
  place:SetValue("custom")
  eq(place:GetValue(), "below", "Custom changes nothing")
end)

test("settings: sections on every page, fonts listed, reset restores defaults", function()
  Reset()
  local ns = Boot()
  local headers = 0
  local cats = mock.settingsCategories
  local mine = {}
  for i = #cats - 12, #cats do
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
  eq(table.concat(names, ","), "DMGAssist,Status & Help,Core,Combat,Display,Sounds,Integrations,Advanced,"
    .. "Spells, trinkets & potion,Flow mode & grades,Performance grade,Grade report,Missing keybinds")
  local byName = {}
  for _, c in ipairs(mine) do
    byName[c.name] = c
  end
  eq(byName["Status & Help"].parent, mine[1], "three groups under DMGAssist")
  eq(byName["Core"].parent, mine[1]) eq(byName["Flow mode & grades"].parent, mine[1])
  eq(byName["Combat"].parent, byName["Core"], "Combat is in Core")
  eq(byName["Performance grade"].parent, byName["Flow mode & grades"], "the grade is with Flow mode")
  eq(byName["Missing keybinds"].parent, byName["Status & Help"], "keybinds under Status & Help")
  eq(byName["Status & Help"].frame ~= nil, true, "Status & Help is a page with content, not an empty header")
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
    mock.Advance(1) -- separate presses
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
  -- a fight that outlasts the usual one isn't ending on cue
  ns.db.fightMode = "learned"
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Advance(10)
  eq(S.Resolve("fight_remains", {}), 15, "usual fight: 25 s, 10 s in")
  mock.Advance(20)
  eq(S.Resolve("target.time_to_die", {}), S.FIGHT_LEFT_MIN, "past the usual length: never about to end")
  local list = (ns.global or ns.db).fights.world
  list[#list + 1], list[#list + 2] = 90, 100
  eq(S.Resolve("target.time_to_die", {}), 60, "your longer fights of this kind went on to 90-100 s")
  list[#list], list[#list - 1] = nil, nil
  mock.Advance(25)
  eq(S.Resolve("expected_combat_length", {}), 25)
  ns.db.fightMode = "custom"
  eq(S.Resolve("fight_remains", {}), 65, "custom 120 s, 55 s in: as given")
  mock.inCombat = false
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

test("assistant fixated on one spell you don't cast: spells left to Blizzard follow our own clock again", function()
  Reset()
  local ns = Boot()
  local G = ns.Engine
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  G.NoteAssistant(93402)
  eq(G.AssistantHealthy(), true)
  mock.Advance(G.FIXATED + 1)
  G.NoteAssistant(93402)
  eq(G.AssistantHealthy(), false, "the same spell for longer than G.FIXATED, never cast")
  ns.State.lastCast[93402] = GetTime()
  G.NoteAssistant(93402)
  eq(G.AssistantHealthy(), true, "you cast it: it's naming the next one")
  G.NoteAssistant(194153)
  eq(G.AssistantHealthy(), true, "a new spell")
  G.acStuck = false
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
  local oldest = math.min(unpack(X.stacks[5217]))
  mock.Advance(oldest - GetTime() - X.StackLead() + 0.1) -- the oldest ends within a GCD plus reaction time
  r = X.Apply({ main = { id = 5221, token = "shred" }, queue = { { id = 5221, token = "shred" } } })
  eq(r.weave and r.weave.token, "tigers_fury", "refresh asked before the oldest stack drops")
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


test("performance grade: presses scored against slot 1, graded after a real fight, best and report saved", function()
  Reset()
  local ns = Boot()
  local Gr = ns.Grade
  ns.db.gradeChain = false -- one fight at a time here (chaining has its own test)
  local spec = Gr.SpecKey()
  Gr.Reset()
  local A, B, C = { id = 101, token = "spell_a" }, { id = 102, token = "spell_b" }, { id = 103, token = "spell_c" }
  local r = { main = A, queue = { A, B, C } }
  local isRot = ns.Engine.IsRotationSpell
  ns.Engine.IsRotationSpell = function() return true end -- 999 is a rotation spell slot 1 didn't ask for
  -- a short fight is not graded
  Gr.OnCombat(true)
  for _ = 1, 8 do
    Gr.OnPress(101, r, true)
  end
  mock.now = mock.now + 10
  Gr.OnCombat(false)
  eq(Gr.Summary(spec), nil, "10 s fight: no grade")
  -- 30 s: 8 presses of slot 1, 2 of slot 2 (half), 2 of something else
  Gr.OnCombat(true)
  for i = 1, 12 do
    Gr.OnReady(101, mock.now, A)
    Gr.Tick(true)
    mock.now = mock.now + 0.1
    Gr.Tick(true) -- 0.1 s ready and not pressed
    local id = i <= 8 and 101 or i <= 10 and 102 or 999
    Gr.OnPress(id, r, true)
    Gr.Tick(false)
    mock.now = mock.now + 2.4
  end
  Gr.OnPress(101, r, false) -- a piece of the same press: not counted
  Gr.OnCombat(false)
  local s = Gr.Summary(spec)
  eq(s ~= nil and #s.history, 1, "graded")
  local got = s.history[1]
  eq(math.floor(got.accuracy + 0.5), 79, "accuracy: (8 + 2 x 0.75) of 12")
  eq(got.reactionMs, 100, "reaction: median press after the flash")
  eq(got.abc > 95, true, "always casting: " .. got.abc)
  eq(got.topMissed, "spell_a", "the spell slot 1 asked for")
  eq(got.letter, Gr.Letter(got.score))
  eq(s.best.score, got.score, "first fight is the best")
  eq(Gr.frame and Gr.frame:IsShown(), true, "popup shown")
  Gr.OnCombat(true)
  eq(Gr.frame:IsShown(), false, "a new fight starts: the popup makes way (it stayed up in combat, 2026-11-10)")
  Gr.OnCombat(false) -- far too short to grade
  eq(Gr.frame:IsShown(), false, "a moment in combat (an evading dummy) brings nothing back")
  -- report
  local lines = Gr.Report()
  eq(type(lines) == "table" and #lines >= 3, true, "report lines")
  eq(table.concat(lines, "\n"):find("spell a", 1, true) ~= nil, true, "where to improve names the spell")
  -- turned off: nothing tracked
  ns.db.grade = false
  Gr.OnCombat(true)
  mock.now = mock.now + 60
  Gr.OnCombat(false)
  eq(#Gr.Summary(spec).history, 1, "off: no new grade")
  ns.db.grade = nil
  Gr.Reset(spec)
  eq(Gr.Summary(spec), nil, "reset")
  eq(Gr.Letter(97), "S+")
  eq(Gr.Letter(84.9), "A")
  eq(Gr.Letter(72), "B+")
  eq(Gr.Letter(49), "D")
  eq(Gr.ReactionScore(0.25), 100)
  eq(Gr.ReactionScore(1.5), 0)
  ns.Engine.IsRotationSpell = isRot
end)

test("wrong-key hint: the key next to slot 1's ('5' for '6') shows for a moment and becomes the tip", function()
  Reset()
  local ns = Boot()
  local Gr, D = ns.Grade, ns.Display
  ns.db.gradeChain = false
  local spec = Gr.SpecKey()
  Gr.Reset()
  eq(Gr.IsSlip("6", "5"), true, "one key to the left")
  eq(Gr.IsSlip("6", "7"), true, "one key to the right")
  eq(Gr.IsSlip("6", "8"), false, "two keys away: a choice, not a slip")
  eq(Gr.IsSlip("W", "Q"), true)
  eq(Gr.IsSlip("S5", "5"), true, "forgot Shift")
  eq(Gr.IsSlip("F3", "F2"), true)
  eq(Gr.IsSlip("S6", "5"), false, "another key and another modifier")
  eq(Gr.IsSlip("LT+A", "A"), false, "controller: no keyboard neighbours")
  eq(Gr.IsSlip("6", nil), false)
  local keys = { [78674] = "6", [194153] = "5" }
  local pk, kb = D.PickKeybind, D.Keybind
  D.PickKeybind = function(p) return keys[p and p.id] end
  D.Keybind = function(id) return keys[id] end
  local isRot = ns.Engine.IsRotationSpell
  ns.Engine.IsRotationSpell = function() return true end
  local SS = { id = 78674, token = "starsurge" }
  local r = { main = SS, queue = { SS } }
  Gr.OnCombat(true)
  for i = 1, 12 do
    Gr.OnPress(i <= 4 and 194153 or 78674, r, true)
    if i == 1 then
      eq(D.frame.slip:IsShown(), true, "shown under slot 1")
      eq(D.frame.slip:GetText():find("5", 1, true) ~= nil and D.frame.slip:GetText():find("6", 1, true) ~= nil, true)
    end
    mock.now = mock.now + 2.5
  end
  Gr.OnCombat(false)
  local got = Gr.Summary(spec).history[1]
  eq(got.slipWant, "6") eq(got.slipGot, "5") eq(got.slipCount, 4)
  local tip = Gr.Tip(got)
  eq(tip:find("5", 1, true) ~= nil and tip:find("4", 1, true) ~= nil and tip:find("6", 1, true) ~= nil, true, tip)
  ns.db.hud = ns.db.hud or {}
  ns.db.hud.slipHint = false
  D.frame.slip:Hide()
  D.ShowSlip("5", "6")
  eq(D.frame.slip:IsShown(), false, "switched off")
  ns.db.hud.slipHint = nil
  D.PickKeybind, D.Keybind = pk, kb
  ns.Engine.IsRotationSpell = isRot
  Gr.Reset(spec)
end)

test("game mode: one lane and a bonus row, notes reach the line when ready, streaks, stars, misses break it", function()
  Reset()
  local ns = Boot()
  local Gr, Game, D = ns.Grade, ns.Game, ns.Display
  ns.db.gradeChain = false
  Gr.Reset()
  ns.db.gameBest = nil
  eq(Game.On(), false, "classic by default")
  ns.commands.game("on")
  Game.IDLE_PAUSE, Game.lastAct = 1e9, mock.now -- playing (the idle pause has its own test)
  eq(Game.On(), true, "/dmga game on")
  local A, B, C = { id = 101, token = "a" }, { id = 102, token = "b" }, { id = 103, token = "c" }
  local res = { main = A, queue = { A, B, C }, defensive = { id = 22812, how = "decided", why = "aoe" },
    trinket = { item = 5512, id = 6262, source = "trinket" } }
  D.Update(res, true)
  eq(Game.frame:IsShown(), true, "lanes shown")
  eq(D.frame.alpha, 0, "the classic HUD runs unseen")
  D.frame.lastWait = 1.0
  Game.Render()
  local lanes = {}
  for _, n in pairs(Game.notes) do
    lanes[n.lane] = (lanes[n.lane] or 0) + 1
  end
  eq(lanes[1], 3, "the lane: the rotation")
  eq(lanes[2], 1, "one box over the hit box: the most urgent waiting action (2026-11-12)")
  eq(Game.notes["b:def"] ~= nil, true, "the defensive comes before the item")
  eq(Game.notes["b:def"].x, Game.HIT_X, "right above slot 1's box")
  eq(Game.bonusQueued, 1, "the item waits its turn (+1)")
  -- the slot 1 note heads to where it reaches the line in 1 s; at 0 s it sits on the line
  for _ = 1, 40 do
    mock.now = mock.now + 0.05
    Game.Render()
  end
  local main = Game.notes["1:101:1"]
  eq(main ~= nil, true)
  local x1 = main.x
  D.frame.lastWait = 0
  for _ = 1, 40 do
    mock.now = mock.now + 0.05
    Game.Render()
  end
  eq(math.floor(main.x + 0.5), Game.HIT_X, "on the line when ready")
  eq(x1 > main.x, true, "it slid right to left")
  -- a new global cooldown (a press elsewhere): the note pauses, it never slides back to the right
  D.frame.lastWait = 1.5
  for _ = 1, 20 do
    mock.now = mock.now + 0.05
    Game.Render()
  end
  eq(math.floor(main.x + 0.5), Game.HIT_X, "paused at the line, no bounce")
  D.frame.lastWait = 0
  -- presses: 10 right ones -> streak 10, two stars, "Great!" popped
  local isRot = ns.Engine.IsRotationSpell
  ns.Engine.IsRotationSpell = function() return true end
  local r = { main = A, queue = { A, B, C } }
  Gr.OnCombat(true)
  for _ = 1, 10 do
    D.frame.lastWait = 0
    Game.Render() -- the note reaches the line
    mock.now = mock.now + 0.1
    Gr.OnPress(101, r, true) -- 0.1 s later
    mock.now = mock.now + 1.4
  end
  eq(Game.streak, 10) eq(Game.stars, 2, "5 and 10")
  eq(Game.frame.pop:GetText(), "Great streak!")
  eq(Game.lastJudge, "perfect", "pressed as the note sat on the line")
  eq(Game.Mult(), 2, "x2 from 10 in a row")
  eq(Game.Rank()[2], "Bronze")
  eq(Game.score, 9 * 100 + 100 * 2, "Perfect = 100 x multiplier")
  -- waiting with nothing to hit never breaks the streak
  D.frame.lastWait = 0
  for _ = 1, 30 do
    mock.now = mock.now + 1
    Game.Render()
  end
  eq(Game.streak, 10, "30 s at the line: still 10")
  eq(Game.frame.flashAt ~= nil, true, "the line flashed when the note arrived")
  Gr.OnPress(102, r, true)
  eq(Game.streak, 11, "slot 2 keeps the streak (a Good)")
  eq(Game.lastJudge, "good")
  D.frame.lastWait = 0
  Game.Render()
  local mainNote = Game.mainNote
  Gr.OnPress(999, r, true)
  eq(Game.streak, 0, "a miss breaks it") eq(Game.lastJudge, "miss")
  eq(mainNote and mainNote.missAt ~= nil, true, "the note gets a red X and stays")
  Game.Render()
  eq(mainNote.xmark:IsShown(), true)
  -- a bonus grabbed (the defensive in the bonus row) adds to the streak
  local rb = { main = A, queue = { A, B, C }, weave = { id = 22812, source = "defensive", urgent = true } }
  Gr.OnPress(22812, rb, true)
  eq(Game.streak, 1, "bonus: +1") eq(Game.lastJudge, "bonus")
  Game.streak = 0
  eq(Game.Best(), 11, "best streak kept")
  -- the set runs across pulls: 10 s out of combat and a new pull carry on; 20 s ends it with the grade
  local score = Game.score
  Gr.OnCombat(false)
  mock.Advance(10)
  Gr.OnCombat(true)
  eq(Game.score, score, "next pull: same set")
  Gr.OnPress(101, r, true)
  mock.now = mock.now + 5
  Gr.OnCombat(false)
  mock.Advance(Game.SET_GAP + 1)
  eq(Game.score, 0, "set over: fresh set (graded or, with its breaks taken out, too short to grade)")
  -- timing offset: notes reach the line that much sooner
  ns.db.hud = ns.db.hud or {}
  ns.db.hud.gameOffset = 200
  Game.arrived = nil
  D.frame.lastWait = 0.15
  Game.Render()
  eq(Game.arrived ~= nil, true, "0.15 s left, 200 ms offset: on the line")
  ns.db.hud.gameOffset = nil
  ns.Engine.IsRotationSpell = isRot
  -- slips show under the hit line in game mode
  Game.frame.slip:Hide()
  D.ShowSlip("5", "6")
  eq(Game.frame.slip:IsShown(), true)
  ns.commands.game("off")
  eq(Game.On(), false)
  D.Update(res, true)
  eq(Game.frame:IsShown(), false, "classic again")
  eq(D.frame.alpha ~= 0, true)
  Gr.Reset()
end)

test("game mode: hold bars for casts and channels, flame notes for major cooldowns, power mode doubles points", function()
  Reset()
  local ns = Boot()
  local Game, D, M = ns.Game, ns.Display, ns.SpellMap
  ns.commands.game("on")
  Game.held, Game.pending = nil, nil
  for k, n in pairs(Game.notes) do
    n:Hide()
    Game.notes[k] = nil
  end
  local info = M.Info
  M.Info = function(id)
    if id == 15407 then return { n = "mind_flay", chan = true, d = 4.5, gcd = 1.5 } end
    return info(id)
  end
  local hold, kind = Game.HoldTime(15407)
  eq(kind, "channel") eq(hold > 3, true, "a 4.5 s channel (hasted)")
  local F = { id = 15407, token = "mind_flay" }
  local B = { id = 102, token = "b" }
  local CD = { id = 103, token = "dark_ascension", major = true }
  D.Update({ main = F, queue = { F, B, CD } }, true)
  D.frame.lastWait = 0
  Game.Render()
  local flay, nextNote, cdNote = Game.notes["1:15407:1"], Game.notes["1:102:1"], Game.notes["1:103:1"]
  eq(flay.bar:IsShown(), true, "the channel trails a bar")
  for _, n in pairs(Game.notes) do
    if n.bar:IsShown() then
      eq(n.x + n.bar:GetWidth() <= Game.WIDTH - 3 + 0.01, true, "a hold bar stops at the lane's edge")
    end
  end
  eq(cdNote.fire, true, "a major cooldown is a flame note")
  -- the next note sits after the channel (not just one GCD later)
  for _ = 1, 60 do
    mock.now = mock.now + 0.05
    Game.Render()
  end
  local px = (Game.WIDTH - Game.HIT_X - Game.ICON / 2 - 2) / Game.LOOK
  eq(nextNote.x >= Game.HIT_X + hold * px - 1, true, "spaced by the channel")
  -- flame hit: double, and power mode starts
  local Gr = ns.Grade
  local isRot = ns.Engine.IsRotationSpell
  ns.Engine.IsRotationSpell = function() return true end
  Gr.OnCombat(true)
  Game.score, Game.streak = 0, 0
  Game.mainNote = cdNote
  cdNote.fire = true
  Gr.OnPress(103, { main = CD, queue = { CD } }, true)
  eq(Game.score >= 100 * Game.FIRE_MULT, true, "worth double")
  eq(Game.PowerOn(), true, "power mode after a major cooldown")
  Game.Render()
  eq(Game.frame.pop:GetText(), ns.L["POWER MODE!"])
  mock.now = mock.now + Game.POWER_TIME + 1
  eq(Game.PowerOn(), false)
  ns.State.boost.lust = { untilT = mock.now + 30 }
  eq(Game.PowerOn(), true, "Bloodlust: power mode")
  ns.State.boost.lust = nil
  Gr.OnCombat(false)
  ns.Engine.IsRotationSpell = isRot
  M.Info = info
  ns.commands.game("off")
end)

test("game mode: an interrupt the game decides never flashes INTERRUPT! by itself (uninterruptible: no spell, no call)", function()
  Reset()
  local ns = Boot()
  local Game, D = ns.Game, ns.Display
  ns.commands.game("on")
  Game.held, Game.pending = nil, nil
  for k, n in pairs(Game.notes) do
    n:Hide()
    Game.notes[k] = nil
  end
  local calls = {}
  local kudos = Game.Kudos
  Game.Kudos = function(f, text, ...)
    calls[#calls + 1] = text
    return kudos(f, text, ...)
  end
  local A = { id = 101, token = "a" }
  Game.frame.alarmAt = nil
  D.Update({ main = A, queue = { A }, interrupt = { id = 47528, how = "render", notInterruptible = true } }, true)
  Game.Render()
  eq(#calls, 0, "no big call for a secret interrupt")
  eq(Game.frame.alarmAt, nil, "no red edge")
  D.Update({ main = A, queue = { A }, interrupt = { id = 47528, how = "decided" } }, true)
  for k, n in pairs(Game.notes) do
    n:Hide()
    Game.notes[k] = nil
  end
  Game.Render()
  eq(#calls, 1, "a decided interrupt still calls")
  Game.Kudos = kudos
  ns.commands.game("off")
end)

test("game mode: a cast-time spell is judged when its cast begins (no red X for a right Starfire), kudos are rare", function()
  Reset()
  local ns = Boot()
  local Game, D = ns.Game, ns.Display
  ns.commands.game("on")
  Game.held, Game.pending, Game.cast = nil, nil, nil
  for k, n in pairs(Game.notes) do
    n:Hide()
    Game.notes[k] = nil
  end
  local SF, SS = { id = 194153, token = "starfire" }, { id = 78674, token = "starsurge" }
  mock.book = { { spellID = 194153, name = "Starfire" }, { spellID = 78674, name = "Starsurge" } }
  ns.SpellMap.Refresh()
  D.Update({ main = SF, queue = { SF, SS } }, true)
  D.frame.lastWait = 0
  for _ = 1, 30 do
    mock.now = mock.now + 0.05
    Game.Render()
  end
  local isRot = ns.Engine.IsRotationSpell
  ns.Engine.IsRotationSpell = function() return true end
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  Game.streak = 0
  ns.NoteShown(SF)
  ns.OnOwnCastStart(194153) -- Starfire's bar starts: its note bursts now
  eq(Game.notes["1:194153:1"], nil, "the Starfire note burst at the start of the cast")
  -- slot 1 moves on while the bar runs
  mock.now = mock.now + 0.1
  local after = { main = SS, queue = { SS } }
  ns.last = after
  ns.NoteShown(SS)
  D.Update(after, true)
  mock.now = mock.now + 2.2
  ns.OnOwnCast(194153)
  eq(Game.lastJudge ~= "miss", true, "a right Starfire is a hit, not a red X")
  eq(Game.streak, 1)
  -- decided while Starfire showed, its bar began 0.13 s after slot 1 flipped to Eclipse (2026-11-12): a hit
  local EC = { id = 1233272, token = "eclipse" }
  ns.last = { main = SF, queue = { SF } }
  ns.NoteShown(SF)
  mock.now = mock.now + 1.5
  ns.last = { main = EC, queue = { EC } }
  ns.NoteShown(EC)
  mock.now = mock.now + 0.13
  ns.OnOwnCastStart(194153)
  mock.now = mock.now + 1.5
  ns.OnOwnCast(194153)
  eq(Game.lastJudge ~= "miss", true, "Starfire started 0.13 s after the flip: no red X")
  eq(Game.streak, 2)
  -- kudos: a big word only for moments, at most one per KUDOS_GAP
  Game.kudosAt = nil
  Game.Kudos(Game.frame, "A")
  Game.Kudos(Game.frame, "B")
  eq(Game.frame.pop:GetText(), "A", "a second word right after is held back")
  mock.inCombat = false
  mock.Fire("PLAYER_REGEN_ENABLED")
  ns.Engine.IsRotationSpell = isRot
  ns.commands.game("off")
end)

test("game mode: a boss hit's defensive scrolls in on the action track and lands when it's time; lane dots", function()
  Reset()
  DefBook()
  local dbm = FakeBossMods()
  local ns = Boot()
  local Game, D = ns.Game, ns.Display
  ns.commands.game("on")
  Game.IDLE_PAUSE, Game.lastAct = 1e9, mock.now -- playing (the idle pause has its own test)
  Game.held, Game.pending = nil, nil
  for k, n in pairs(Game.notes) do
    n:Hide()
    Game.notes[k] = nil
  end
  dbm.DBM_TimerBegin("DBM_TimerBegin", "aoe", "Void Eruption", 7, 0, "cd", 1, 2) -- AoE in 7 s
  local inc = Game.IncomingHit()
  eq(inc and inc.id, 22812, "Barkskin is the one coming")
  eq(math.floor(inc.t + 0.5), 3, "lands 4.5 s before the hit: 2.5 s from now (rounded)")
  local A = { id = 101, token = "a" }
  D.Update({ main = A, queue = { A } }, true)
  D.frame.lastWait = 0
  for _ = 1, 40 do
    mock.now = mock.now + 0.05
    Game.Render()
  end
  local def = Game.notes["b:def"]
  eq(def ~= nil, true, "in the action box")
  eq(def.x, Game.HIT_X, "in the box over slot 1, not sliding along a row (2026-11-12)")
  eq(Game.actAlpha > 0.5, true, "the action track opened")
  local dots = 0
  for _, dot in ipairs(Game.frame.dots) do
    if dot:IsShown() then
      dots = dots + 1
    end
  end
  eq(dots >= 4, true, "the lane's dots")
  ns.BossMods.Reset()
  ns.commands.game("off")
end)

test("game mode: slots 2-3 only swap when the new pick holds (no jitter); slot 1 is always the truth", function()
  Reset()
  local ns = Boot()
  local Game = ns.Game
  Game.held, Game.pending = nil, nil
  local A, B, C, X = { id = 1 }, { id = 2 }, { id = 3 }, { id = 9 }
  local q = Game.Steady({ A, B, C }, 100)
  eq(q[2].id, 2)
  q = Game.Steady({ A, X, C }, 100.1)
  eq(q[2].id, 2, "a flicker in slot 2: held")
  q = Game.Steady({ A, B, C }, 100.2)
  eq(q[2].id, 2, "and it flicked back: no swap at all")
  Game.Steady({ A, X, C }, 100.3)
  q = Game.Steady({ A, X, C }, 100.7)
  eq(q[2].id, 9, "held 0.4 s: it swaps")
  q = Game.Steady({ X, C, B }, 100.8)
  eq(q[1].id, 9, "slot 1 is never held back")
end)

test("performance grade: a trinket from the items icon counts as cooldown use, never accuracy", function()
  Reset()
  local ns = Boot()
  local Gr = ns.Grade
  ns.db.gradeChain = false -- one fight at a time here (chaining has its own test)
  Gr.Reset()
  local A = { id = 101, token = "spell_a" }
  local r = { main = A, queue = { A }, trinket = { id = 5000, item = 777 } }
  Gr.OnCombat(true)
  ns.last = r
  Gr.Tick(false)
  mock.now = mock.now + 2
  Gr.OnPress(5000, r, false) -- item use: not a press
  for _ = 1, 6 do
    Gr.OnPress(101, r, true)
    mock.now = mock.now + 4
  end
  Gr.OnCombat(false)
  local h = Gr.Summary(Gr.SpecKey()).history[1]
  eq(math.floor(h.accuracy), 100, "the item use is not a wrong press")
  eq(math.floor(h.cooldowns + 0.5), 100, "used 2 s after it showed (2 s is full marks, 10 s none)")
  ns.last = nil
  Gr.Reset()
end)


test("tanks: hidden health + aggro = being hit; Stagger 0 only means unhurt for a Brewmaster", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  local uh, uhm, ust, uts = UnitHealth, UnitHealthMax, UnitStagger, UnitThreatSituation
  UnitHealth = function() return nil end -- luacheck: ignore 121 (hidden in combat)
  UnitStagger = function() return 0 end -- luacheck: ignore 121
  UnitThreatSituation = function() return 3 end -- luacheck: ignore 121
  ns.Specs.current.key = "warrior_protection"
  eq(S.Unhurt(), false, "Protection Warrior tanking: hurt")
  UnitThreatSituation = function() return 0 end -- luacheck: ignore 121
  eq(S.Unhurt(), nil, "no aggro, health hidden: can't tell (not 'nothing to mitigate')")
  ns.Specs.current.key = "monk_brewmaster"
  eq(S.Unhurt(), true, "Brewmaster with no Stagger and no aggro: unhurt")
  ns.Specs.current.key = "mage_frost"
  UnitThreatSituation = function() return 3 end -- luacheck: ignore 121
  eq(S.Unhurt(), nil, "a DPS with aggro on a mob: no tank rule")
  UnitHealth, UnitHealthMax, UnitStagger, UnitThreatSituation = uh, uhm, ust, uts -- luacheck: ignore 121
end)


test("rogue: a finisher the game calls unusable with points read is still castable; poisons named in combat ignored", function()
  Reset()
  local ns = Boot()
  local G = ns.Engine
  Feral(ns, QRecord({ { a = "ferocious_bite" }, { a = "shred" } }))
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.power[4], mock.powerReadable[4] = 5, true
  mock.usable[22568] = { false, false } -- the game: not usable, no reason
  eq(G.Castable(22568) ~= false, true, "5 points read: the finisher stays")
  mock.power[4] = 0
  eq(G.Castable(22568), false, "no points: not castable")
  eq(ns.Buffs.IsBuffSpell(5761), true, "Numbing Poison is a buff spell")
  mock.power[4] = 5
  mock.acSpell = 5761
  G.Recommend(ns.ActiveRecord(ns.Specs.current), { useAssisted = true })
  eq(G.acNow, nil, "the assistant naming a poison is ignored")
  mock.acSpell, mock.inCombat = nil, false
end)


test("buffs in combat: Blizzard's assistant naming a missing buff puts it in slot 1", function()
  Reset()
  local book = {}
  for i, b in ipairs(FERAL_BOOK) do
    book[i] = b
  end
  book[#book + 1] = { spellID = 1126, name = "Mark of the Wild" }
  mock.book = book
  local ns = Boot()
  local G = ns.Engine
  local printed = {}
  local oldPrint = ns.U.Print
  ns.U.Print = function(fmt, ...) printed[#printed + 1] = string.format(fmt, ...) end
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.acSpell = 1126
  local r = G.Recommend(ns.ActiveRecord(ns.Specs.current), { useAssisted = true })
  ns.Buffs.Apply(r)
  eq(r.main and r.main.id ~= 1126, true, "named just now: not yet (a passing suggestion)")
  mock.Advance(ns.Buffs.ASSIST_SETTLE + 0.1)
  r = G.Recommend(ns.ActiveRecord(ns.Specs.current), { useAssisted = true })
  ns.Buffs.Apply(r)
  eq(r.main.id, 1126, "named for a second: the buff is missing, slot 1")
  eq(r.main.source, "buff")
  mock.acSpell = 5221
  r = G.Recommend(ns.ActiveRecord(ns.Specs.current), { useAssisted = true })
  ns.Buffs.Apply(r)
  eq(r.main.id ~= 1126, true, "cast (the assistant moved on): gone")
  -- left alone: chat says once what it is, and after B.IGNORED seconds it stops pushing for this fight
  mock.acSpell = 1126
  G.Recommend(ns.ActiveRecord(ns.Specs.current), { useAssisted = true })
  mock.Advance(ns.Buffs.ASSIST_SETTLE + 0.1)
  r = G.Recommend(ns.ActiveRecord(ns.Specs.current), { useAssisted = true })
  ns.Buffs.Apply(r)
  eq(r.main.id, 1126, "missing again: shown")
  eq(#printed, 1, "chat said once what it is")
  r = G.Recommend(ns.ActiveRecord(ns.Specs.current), { useAssisted = true })
  ns.Buffs.Apply(r)
  eq(#printed, 1, "once")
  mock.Advance(ns.Buffs.IGNORED + 1)
  r = G.Recommend(ns.ActiveRecord(ns.Specs.current), { useAssisted = true })
  ns.Buffs.Apply(r)
  eq(r.main.id ~= 1126, true, "ignored for 20 s: gone for the rest of the fight")
  ns.U.Print = oldPrint
  mock.acSpell, mock.inCombat = nil, false
end)

test("performance grade: a press of what slot 1 showed just before it switched counts; an unused potion doesn't", function()
  Reset()
  local ns = Boot()
  local Gr = ns.Grade
  ns.db.gradeChain = false -- one fight at a time here (chaining has its own test)
  Gr.Reset()
  local A, B = { id = 101, token = "spell_a" }, { id = 102, token = "spell_b" }
  local potion = { id = 6000, item = 999 }
  Gr.OnCombat(true)
  ns.last = { main = A, queue = { A }, trinket = potion }
  Gr.Tick(false) -- the potion shows, and is never used
  for _ = 1, 6 do
    ns.last.main = A
    Gr.Tick(false)
    mock.now = mock.now + 1
    ns.last.main = B -- slot 1 switches to B ...
    Gr.Tick(false)
    mock.now = mock.now + 0.3
    Gr.OnPress(101, { main = B, queue = { B } }, true) -- ... 0.3 s before the press of A
    mock.now = mock.now + 3
  end
  -- nothing shown, and a spell outside the rotation: neither counts
  Gr.OnPress(101, { queue = {} }, true)
  local isRot = ns.Engine.IsRotationSpell
  ns.Engine.IsRotationSpell = function() return false end
  Gr.OnPress(777, { main = B, queue = { B } }, true)
  ns.Engine.IsRotationSpell = isRot
  Gr.OnCombat(false)
  local h = Gr.Summary(Gr.SpecKey()).history[1]
  eq(math.floor(h.accuracy), 100, "pressed what slot 1 showed 0.3 s earlier: right")
  eq(h.cooldowns, nil, "an unused potion is not graded")
  ns.last = nil
  Gr.Reset()
end)


test("tank profile: keep-up while tanking, cooldowns before a tank hit, reflect for a spell at you, out of the slots", function()
  Reset()
  local ns = Boot()
  local T = ns.Tanks
  local ips, uts, uh = IsPlayerSpell, UnitThreatSituation, UnitHealth
  local known = { [2565] = true, [190456] = true, [1160] = true, [871] = true, [23920] = true, [12975] = true }
  IsPlayerSpell = function(id) return known[id] == true end -- luacheck: ignore 121
  UnitThreatSituation = function() return 3 end -- luacheck: ignore 121
  UnitHealth = function() return nil end -- luacheck: ignore 121 (hidden in combat)
  ns.Specs.current.key = "warrior_protection"
  mock.power[1], mock.powerReadable[1] = 80, true
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  eq(T.InIcon("shield_block"), true, "Shield Block lives in the defensive icon")
  eq(T.InIcon("shield_slam"), false, "Shield Slam stays in the slots")
  local p = T.Pick()
  eq(p and p.token, "shield_block", "tanking, never cast: Shield Block is due")
  eq(p.urgent, nil, "keep-up: steady, not pulsing")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 2565)
  p = T.Pick()
  eq(p and p.token, "ignore_pain", "Shield Block just cast: next keep-up")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 190456)
  mock.power[1] = 30
  eq(T.Pick(), nil, "both fresh, rage spent: nothing due")
  mock.Advance(5.2)
  p = T.Pick()
  eq(p and p.token, "shield_block", "1 s before it ends: due again")
  -- a boss mod tank hit in 2 s: the big cooldown, pulsing
  ns.BossMods.timers.t1 = { kind = "role", expires = mock.now + 2 }
  p = T.Pick()
  eq(p and p.token, "demoralizing_shout")
  eq(p.urgent, true)
  ns.BossMods.timers.t1 = nil
  ns.BossMods.timers.t2 = { kind = "targeted", expires = mock.now + 1.5 }
  p = T.Pick()
  eq(p and p.token, "spell_reflection", "a spell at you: Spell Reflection")
  ns.BossMods.timers.t2 = nil
  -- no aggro: no keep-up
  UnitThreatSituation = function() return 0 end -- luacheck: ignore 121
  eq(T.Pick(), nil, "not tanking: nothing")
  eq(T.Health(), 50, "tank low-health default")
  ns.db.tankProfile = false
  eq(T.InIcon("shield_block"), false, "switched off: SimC's list decides")
  ns.db.tankProfile = nil
  IsPlayerSpell, UnitThreatSituation, UnitHealth = ips, uts, uh -- luacheck: ignore 121
  mock.inCombat = false
end)


test("Guardian: Frenzied Regeneration with both charges full at 85% health, not at 99%; Ironfur keeps its badge", function()
  Reset()
  mock.specIndex = 3 -- Guardian
  local ns = Boot()
  local T, S = ns.Tanks, ns.State
  local ips, uts = IsPlayerSpell, UnitThreatSituation
  IsPlayerSpell = function(id) return id == 22842 end -- luacheck: ignore 121
  UnitThreatSituation = function() return 3 end -- luacheck: ignore 121
  local info = ns.SpellMap.Info(22842)
  info.chLive = 2
  mock.charges = { [22842] = { 2, 2 } }
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  eq(S.MaxCharges(22842), 2)
  eq((T.Pick() or {}).token == "frenzied_regeneration", false,
    "never the off-GCD badge (it held Ironfur back for 23 s, 2026-11-12)")
  eq(T.Health(), 85, "both charges full: shown from 85% health (the game decides from your health)")
  mock.charges[22842] = { 1, 2 }
  eq(T.Health(), T.HEALTH, "one left: back to your low-health setting")
  mock.charges = nil
  info.chLive = nil
  IsPlayerSpell, UnitThreatSituation = ips, uts -- luacheck: ignore 121
  mock.inCombat = false
  mock.specIndex = 2
end)

test("a hidden channel runs for its duration: its own 'succeeded' at the start doesn't end it", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  local rec = QRecord({ { a = "shred" } })
  rec.spells.fists = { a = { 113656 } }
  rec.spellInfo[113656] = { n = "fists", d = 4, gcd = 1, cd = 24 }
  Feral(ns, rec)
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Fire("UNIT_SPELLCAST_CHANNEL_START", "player", "guid", 113656)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 113656)
  mock.Advance(1)
  local id, left = S.CurrentCast()
  eq(id, 113656, "still channelling")
  eq(left > 2 and left < 3.5, true, "about 3 s left: " .. tostring(left))
  mock.Fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "guid", 113656)
  eq(S.CurrentCast(), nil, "the stop event ends it")
  mock.inCombat, mock.restricted = false, false
end)


test("interrupts in a dungeon with hidden cast info: drawn by the game, no secret boolean tested", function()
  Reset()
  KickBook()
  local ns = Boot()
  mock.instance, mock.restricted = true, true
  mock.inCombat = true
  mock.targetCast = { notInterruptible = false, id = 9999 }
  local r = ns.Update()
  eq(r.interrupt and r.interrupt.how, "render", "importance hidden: the game decides by alpha")
  mock.instance, mock.restricted, mock.inCombat, mock.targetCast = false, false, false, nil
end)


test("learning summary in plain words: left-to-Blizzard spells first, measured ones with their correction", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  S.learned.timing = {
    kill_command = { n = 5, mean = -1.24, spread = 0.2 },
    ["mortal_strike@aoe"] = { n = 3, mean = 0.3, spread = 0.1 },
    wildfire_bomb = { n = 6, mean = 0, spread = 2.4, unreliable = true },
    new_spell = { n = 1, mean = 0, spread = 0 },
  }
  local lines = S.LearningLines()
  eq(#lines, 3, "spells measured fewer than 3 times are left out")
  eq(lines[1]:find("wildfire bomb", 1, true) ~= nil, true, lines[1])
  eq(lines[2]:find("-1.2 s", 1, true) ~= nil, true, lines[2])
  eq(lines[3]:find("mortal strike", 1, true) ~= nil, true, lines[3])
end)


test("performance grade: any 20 s+ cooldown slot 1 shows is graded from 'press now'; pressed early is on time", function()
  Reset()
  local ns = Boot()
  local Gr = ns.Grade
  ns.db.gradeChain = false -- one fight at a time here (chaining has its own test)
  Gr.Reset()
  local len = ns.State.CooldownLength
  ns.State.CooldownLength = function(id) return id == 202770 and 60 or 0 end
  local FoE, A = { id = 202770, token = "fury_of_elune" }, { id = 101, token = "spell_a" }
  local isRot = ns.Engine.IsRotationSpell
  ns.Engine.IsRotationSpell = function() return true end
  Gr.OnCombat(true)
  ns.last = { main = FoE, queue = { FoE, A } }
  Gr.Tick(false) -- Fury of Elune appears in slot 1 while the GCD runs
  mock.now = mock.now + 0.5
  Gr.OnPress(202770, ns.last, true) -- pressed before "press now": queued, on time
  for _ = 1, 6 do
    ns.last = { main = A, queue = { A } }
    Gr.Tick(false)
    Gr.OnPress(101, ns.last, true)
    mock.now = mock.now + 4
  end
  Gr.OnCombat(false)
  local h = Gr.Summary(Gr.SpecKey()).history[1]
  eq(h.cooldowns and math.floor(h.cooldowns), 100, "Fury of Elune graded, on time")
  ns.State.CooldownLength, ns.Engine.IsRotationSpell, ns.last = len, isRot, nil
  Gr.Reset()
end)


test("the assistant's 'Waiting for Energy' placeholder is never shown and caps energy below the cheapest spender", function()
  Reset()
  local ns = Boot()
  local G = ns.Engine
  Feral(ns, QRecord({ { a = "shred" } }))
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  local upt = UnitPowerType
  UnitPowerType = function() return 3 end -- luacheck: ignore 121
  mock.acSpell = 1249752
  local r = G.Recommend(ns.ActiveRecord(ns.Specs.current), { useAssisted = true })
  eq(r.main == nil or r.main.id ~= 1249752, true, "the stopwatch never reaches a slot")
  eq(G.acNow, nil)
  local _, hi = ns.Clues.ResourceBounds(3)
  eq(hi ~= nil and hi < 40, true, "energy below Shred's 40: " .. tostring(hi))
  UnitPowerType = upt -- luacheck: ignore 121
  mock.acSpell, mock.inCombat, mock.restricted = nil, false, false
end)


test("Feral: a builder's crit point can't be told apart, so the count after a builder is 'v or v+1'", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  ns.Specs.current.key = "druid_feral"
  mock.power[4], mock.powerMax[4] = 2, 5
  S.VerifyPowers()
  Restrict()
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g1", 5221) -- Shred: +1, or +2 with Primal Fury
  mock.Fire("UNIT_POWER_UPDATE", "player", "COMBO_POINTS")
  local lo, hi = S.Bounds("combo_points")
  eq(lo, 3)
  eq(hi, 4)
end)


test("a spell the game calls usable isn't ready while our range for the hidden resource is below its cost", function()
  Reset()
  local ns = Boot()
  local G = ns.Engine
  Feral(ns, QRecord({ { a = "shred" } }))
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.usable[5221] = { true, false } -- "usable" (a free proc the game doesn't tell us about, or wrong)
  ns.Clues.SetBound(3, nil, 24, 5, "wait") -- but energy is at most 24; Shred costs 40
  local ok, why = G.Castable(5221)
  eq(ok, false)
  eq(why, "power")
  ns.State.glow[5221] = true -- a real free Shred glows
  eq(G.Castable(5221) ~= false, true, "glowing: trusted")
  ns.State.glow[5221] = nil
  mock.inCombat, mock.restricted = false, false
end)


test("a cooldown cast in combat (length hidden) is learned when the fight ends and it's readable again", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  local rec = QRecord({ { a = "shred" } })
  rec.spells.convoke_the_spirits = { a = { 391528 } }
  rec.spellInfo[391528] = { n = "convoke_the_spirits", cd = 120, gcd = 1.5 }
  Feral(ns, rec)
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Advance(1)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g", 391528)
  mock.cooldowns[391528] = { start = mock.now, duration = 60, active = true } -- talented: 60 s
  mock.Advance(1)
  eq(S.learned.cd[391528], nil, "hidden in combat")
  mock.inCombat, mock.restricted = false, false
  mock.Fire("PLAYER_REGEN_ENABLED")
  mock.Advance(0.6)
  eq(S.learned.cd[391528], 60, "learned after the fight")
  eq(math.floor(S.CooldownLength(391528) + 0.5), 60)
end)


test("the cooldown the game's tooltip shows (talents included) beats SimC's base number", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  local rec = QRecord({ { a = "shred" } })
  rec.spells.convoke_the_spirits = { a = { 391528 } }
  rec.spellInfo[391528] = { n = "convoke_the_spirits", cd = 120, gcd = 1.5 }
  Feral(ns, rec)
  local tip, mn, sec = C_TooltipInfo, _G.SPELL_RECAST_TIME_MIN, _G.SPELL_RECAST_TIME_SEC
  _G.SPELL_RECAST_TIME_MIN, _G.SPELL_RECAST_TIME_SEC = "%s min cooldown", "%s sec cooldown"
  _G.C_TooltipInfo = { GetSpellByID = function(id)
    if id == 391528 then
      return { lines = { { leftText = "Convoke the Spirits" }, { leftText = "Channeled", rightText = "1 min cooldown" } } }
    end
  end }
  S.ForgetTalentCache()
  eq(S.TooltipCooldown(391528), 60)
  eq(math.floor(S.CooldownLength(391528) + 0.5), 60, "talented: 1 min, not SimC's 120 s")
  _G.C_TooltipInfo, _G.SPELL_RECAST_TIME_MIN, _G.SPELL_RECAST_TIME_SEC = tip, mn, sec
  S.ForgetTalentCache()
end)


test("nothing affordable while Blizzard waits for energy: slot 1 shows the spell it's waiting for, not nothing", function()
  Reset()
  local ns = Boot()
  local G = ns.Engine
  local rec = QRecord({ { a = "shred" } })
  Feral(ns, rec)
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.usable[5221] = { false, true } -- Shred: not enough energy
  mock.power[3] = 10
  mock.acSpell = 1249752
  local r = G.Recommend(rec, { useAssisted = true })
  eq(r.main and r.main.token, "shred")
  eq(r.main and r.main.source, "pool", "shown as waiting")
  mock.acSpell, mock.inCombat = nil, false
end)


test("an 'affordable' floor above anything our own energy count could reach is a free proc, not energy", function()
  Reset()
  local ns = Boot()
  local C = ns.Clues
  Feral(ns, QRecord({ { a = "shred" } }))
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  C.floor[3] = { lo = 5, at = mock.now, max = 100, moved = true } -- we counted 5 energy just now
  mock.usable[5221] = { true, false } -- the game: Shred (40) is "usable" (Clearcasting: free)
  local lo = C.ResourceBounds(3)
  eq(lo ~= nil and lo < 40, true, "not 40+: " .. tostring(lo))
  mock.inCombat, mock.restricted = false, false
end)


test("performance grade: one weak part caps the total (no S+ with 88% always casting)", function()
  Reset()
  local ns = Boot()
  local Gr = ns.Grade
  ns.db.gradeChain = false -- one fight at a time here (chaining has its own test)
  Gr.Reset()
  -- the fight from the 2026-11-10 report: 40 of 41 right, 58 ms, cooldowns on time, 6.9 s idle in 61 s
  local f = { start = mock.now - 61, presses = 41, score = 40.75, reactions = { 0.058 }, idle = 6.9, cds = { 0, 0 },
    cdShown = {}, cdReady = {}, missed = {}, mit = {}, mitShown = {}, targets = 5 }
  local r = Gr.Finish(f, mock.now)
  eq(math.floor(r.abc + 0.5), 89)
  eq(r.score <= r.abc + Gr.WEAK_GAP, true, "capped at the weakest part + " .. Gr.WEAK_GAP)
  eq(r.letter ~= "S+", true, "not S+: " .. r.letter)
  Gr.Reset()
end)

test("performance grade: walking off a dummy at the end isn't idle time or an unused cooldown", function()
  Reset()
  local ns = Boot()
  local Gr = ns.Grade
  ns.db.gradeChain = false -- one fight at a time here (chaining has its own test)
  Gr.Reset()
  -- 60 s of play, then 20 s walking away while still in combat: 14 s of "idle" and a cooldown ready at the end
  local f = { start = mock.now - 80, presses = 40, score = 40, reactions = { 0.2 }, idle = 15, cds = { 0 },
    cdShown = { [204066] = mock.now - 15 }, cdReady = { [204066] = mock.now - 15 }, missed = {}, mit = {},
    mitShown = {}, targets = 1, lastPress = mock.now - 20, lastPressClock = mock.now - 20, idleAtPress = 1 }
  local r = Gr.Finish(f, mock.now)
  eq(math.floor(r.length + 0.5), 60 + Gr.TAIL, "graded to the last press + " .. Gr.TAIL .. " s")
  eq(r.idle <= 1 + Gr.TAIL, true, "the walk-off isn't idle")
  eq(r.cooldowns, 100, "a cooldown that came up after you stopped isn't 'never used'")
  Gr.Reset()
end)

test("beyond Assisted Combat: time slot 1 differed from Blizzard's pick, by kind, plus extras", function()
  Reset()
  local ns = Boot()
  local Gr, G = ns.Grade, ns.Engine
  local f = {}
  G.acNow, G.acStuck = 33917, false
  Gr.CompareTick(f, { id = 33917 }, 6) -- same spell
  G.acNow = 77758
  Gr.CompareTick(f, { id = 8921, source = "keepup" }, 2) -- Moonfire kept up
  Gr.CompareTick(f, { id = 106839, source = "interrupt" }, 1)
  Gr.CompareTick(f, { id = 213771 }, 1) -- a different core spell
  G.acNow = nil
  Gr.CompareTick(f, { id = 213771 }, 5) -- nothing named: not compared
  local v = Gr.VsShares(f.vs, 3)
  eq(math.floor(v.same + 0.5), 60)
  eq(math.floor(v.upkeep + 0.5), 20)
  eq(math.floor(v.utility + 0.5), 10)
  eq(math.floor(v.rotation + 0.5), 10)
  eq(math.floor(v.differs + 0.5), 40)
  local text = Gr.VsText(v)
  eq(text:find("40%", 1, true) ~= nil, true, text)
  eq(text:find("3 extras", 1, true) ~= nil, true, text)
  eq(Gr.VsShares({ total = 4, same = 4 }), nil, "too short to say")
end)

test("Hunter's Mark: on a boss target, before the pull and in combat, once per target", function()
  Reset()
  local ns = Boot()
  local X = ns.Essentials
  local oldSpec, oldIPS = ns.Specs.current, IsPlayerSpell
  ns.Specs.current = { key = "hunter_marksmanship", status = "ready" }
  IsPlayerSpell = function() return true end
  ns.SpellMap.byID[257284] = "hunters_mark"
  local function Main()
    local r = X.Apply({ main = { id = 5221, token = "shred" }, queue = { { id = 5221, token = "shred" } } })
    return r.main.token
  end
  mock.targetGUID = "Creature-boss-1"
  eq(Main(), "shred", "not a boss: never")
  mock.boss = true
  eq(Main(), "hunters_mark", "a boss targeted before the pull: mark it")
  X.OnOwnCast(257284)
  eq(Main(), "shred", "just cast: marked (before the aura shows)")
  mock.Advance(3)
  eq(Main(), "hunters_mark", "readable and no mark on it after all (resisted, dispelled): again")
  mock.auras.target = { { name = "Hunter's Mark", spellId = 257284, duration = 0, expirationTime = 0 } }
  eq(Main(), "shred", "the game shows the mark")
  mock.auras.target = nil
  X.OnOwnCast(257284)
  mock.Advance(3)
  -- in combat, auras hidden: our record decides, by target
  mock.inCombat = true
  mock.restricted = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Fire("UNIT_AURA", "player")
  eq(Main(), "shred", "marked")
  mock.targetGUID = "Creature-boss-2"
  eq(Main(), "hunters_mark", "another boss: mark it")
  mock.targetGUID = "Creature-boss-1"
  eq(Main(), "shred", "back on the first one, still marked")
  mock.restricted = false
  mock.Fire("PLAYER_REGEN_ENABLED")
  mock.inCombat = false
  mock.Fire("UNIT_AURA", "player")
  -- readable auras: the game's own word (another hunter's mark counts too)
  mock.targetGUID = "Creature-boss-3"
  mock.auras.target = { { name = "Hunter's Mark", spellId = 257284, duration = 0, expirationTime = 0 } }
  eq(Main(), "shred", "the target already carries a mark")
  mock.auras.target = nil
  -- restricted combat, GUIDs hidden: our cast counts until the target changes
  mock.targetGUID = nil
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  X.marked = nil
  eq(Main(), "hunters_mark", "in combat, boss unmarked")
  X.OnOwnCast(257284)
  eq(Main(), "shred", "marked by our cast")
  mock.Fire("PLAYER_TARGET_CHANGED")
  eq(Main(), "hunters_mark", "new target, can't tell: mark it")
  ns.db.huntersMark = false
  eq(Main(), "shred", "setting off")
  ns.db.huntersMark = true
  mock.boss = nil
  mock.targetLevel = -1
  eq(Main(), "hunters_mark", "a skull-level target counts as a boss")
  mock.Fire("PLAYER_REGEN_ENABLED")
  mock.inCombat = false
  ns.Specs.current, IsPlayerSpell = oldSpec, oldIPS
end)

test("healing support: in a group Discipline keeps Atonement up and Mistweaver spends Renewing Mist charges", function()
  Reset()
  local ns = Boot()
  local X, M = ns.Essentials, ns.SpellMap
  local oldSpec, oldSpellID, oldNext, oldIPS = ns.Specs.current, M.SpellID, ns.BossMods.Next, IsPlayerSpell
  ns.Specs.current = { key = "priest_discipline", status = "ready" }
  M.byID[17], M.byID[194509] = "power_word_shield", "power_word_radiance"
  IsPlayerSpell = function() return true end
  local ids = { power_word_radiance = 194509, power_word_shield = 17, renewing_mist = 115151 }
  M.SpellID = function(token) return ids[token] end
  ns.BossMods.Next = function() return nil end
  X.stacks[194509] = {}
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  local function Main()
    local r = X.Apply({ main = { id = 5221, token = "shred" }, queue = { { id = 5221, token = "shred" } } })
    return r.main.token
  end
  eq(Main(), "shred", "setting off (the default): damage list")
  ns.db.healSupport = true
  eq(Main(), "shred", "solo: nothing changes")
  mock.groupSize = 5
  eq(Main(), "power_word_shield", "in a party: Shield first (one Atonement, cheap)")
  mock.cooldowns[17] = { active = true, start = mock.now, duration = 7.5 }
  ns.State.lastCast[17] = mock.now
  eq(Main(), "power_word_radiance", "3 missing and Shield on cooldown: Radiance")
  X.OnOwnCast(194509)
  eq(Main(), "shred", "five up")
  mock.Advance(10) -- Radiance's run out; Shield is back
  mock.cooldowns[17] = nil
  eq(Main(), "power_word_shield", "Shield again")
  X.OnOwnCast(17)
  X.OnOwnCast(17)
  mock.cooldowns[17] = { active = true, start = mock.now, duration = 7.5 }
  ns.State.lastCast[17] = mock.now
  eq(Main(), "shred", "one short of 3 (default), Shield on cooldown: no Radiance for one")
  mock.cooldowns[17] = nil
  ns.State.lastCast[17] = nil
  X.OnOwnCast(17)
  eq(Main(), "shred", "3 kept up")
  ns.db.atonementKeep = 4
  eq(Main(), "power_word_shield", "the setting raises it")
  local F = ns.Defensives
  eq(F.IsDefensive({ id = 17, token = "power_word_shield", source = "keepup" }), false,
    "Atonement's Shield stays in slot 1 (it isn't moved out as a defensive)")
  eq(F.IsDefensive({ id = 17, token = "power_word_shield", source = "simc" }), true, "a list's Shield still is one")
  ns.db.atonementKeep = nil
  -- Mistweaver
  ns.Specs.current = { key = "monk_mistweaver", status = "ready" }
  eq(Main(), "renewing_mist", "a charge ready: Renewing Mist")
  ns.State.OnSpellcastSucceeded(115151)
  mock.Advance(1.6)
  eq(Main(), "renewing_mist", "two charges: the second one too")
  ns.State.OnSpellcastSucceeded(115151)
  mock.Advance(1.6)
  eq(Main(), "shred", "no charge left: the damage list")
  mock.Advance(9)
  eq(Main(), "renewing_mist", "a charge back after 9 s")
  mock.groupSize = 0
  eq(Main(), "shred", "solo: never")
  ns.db.healSupport = nil
  mock.Fire("PLAYER_REGEN_ENABLED")
  mock.inCombat = false
  ns.Specs.current, M.SpellID, ns.BossMods.Next, IsPlayerSpell = oldSpec, oldSpellID, oldNext, oldIPS
end)

test("cooldowns our data lacks are learned from the game refusing the cast (Void Volley)", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  local id = 5221 -- Shred: no cooldown in the data, standing in for Void Volley
  eq(S.CooldownLength(id), nil, "no cooldown known")
  S.lastCast[id] = GetTime()
  mock.Advance(3)
  S.OnCastFailed(id)
  S.OnUIError(nil, "Out of range.")
  eq(S.cdRefusal[id], nil, "refused for another reason: nothing learned")
  mock.Advance(0.5)
  S.OnCastFailed(id)
  S.OnUIError(nil, ERR_SPELL_COOLDOWN)
  eq(S.OwnClockReady(id), false, "'not ready yet' 3.5 s after our cast: it has a cooldown")
  mock.Advance(1.6)
  eq(S.OwnClockReady(id), true, "a little past the longest refusal: try again")
  -- the message can come first, then the failed cast
  mock.Advance(1)
  S.OnUIError(nil, ERR_SPELL_COOLDOWN)
  S.OnCastFailed(id)
  eq(math.floor(S.cdRefusal[id].bound * 10 + 0.5), 61, "the bound moves on")
  -- pressing until it goes through measures it
  mock.Advance(0.5)
  S.OnSpellcastSucceeded(id)
  eq(S.learned.cd[id], 6.5, "learned: 6.6 s, to the half second")
  eq(S.CooldownLength(id) ~= nil, true, "now our clock has it")
  mock.Fire("PLAYER_REGEN_ENABLED")
  mock.inCombat = false
end)

test("Blizzard naming a spell: learned only from this fight's own cast, less the assistant's usual earliness", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  local rec = QRecord({ { a = "tigers_fury", k = "R" } })
  rec.spellInfo[5217] = { n = "tigers_fury", cd = 12, gcd = 1.5 }
  Feral(ns, rec)
  -- cast before the pull: at the pull our clock still runs from it
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  mock.Advance(4)
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Advance(1)
  S.acNamed = nil
  S.ObserveAssistedCharge(5217) -- ours: 7 s left
  eq(S.learned.timing.tigers_fury, nil, "a clock from before the fight teaches nothing (Holy Judgment, 2026-11-10)")
  eq(S.CooldownReady(5217), true, "but Blizzard's word resyncs it: ready")
  -- cast in this fight, named 6 s early by our clock: 1.5 s of that is Blizzard naming it early
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  mock.Advance(6)
  S.acNamed = nil
  S.ObserveAssistedCharge(5217)
  eq(S.learned.timing.tigers_fury and S.learned.timing.tigers_fury.mean, -4.5, "learned: -(6 - 1.5)")
  mock.Fire("PLAYER_REGEN_ENABLED")
  mock.inCombat, mock.restricted = false, false
end)

test("timing corrections from one or two samples are dropped once (stale-clock fix, 1.6.0.170)", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  local rec = QRecord({ { a = "tigers_fury", k = "R" } })
  Feral(ns, rec)
  -- saved by an earlier version
  S.learned.timing = { judgment = { n = 1, mean = -4.5, spread = 0 }, holy_shock = { n = 7, mean = -1.2, spread = 1.2 } }
  S.learned.timingVersion = nil
  S.Bind(ns.Specs.current.key)
  eq(S.learned.timing.judgment, nil, "one sample: dropped")
  eq(S.learned.timing.holy_shock and S.learned.timing.holy_shock.n, 7, "seven: kept")
  eq(S.learned.timingVersion, 3)
  -- 1.6.0.178: a big "ready earlier" correction (the assistant still naming a spell just cast) is dropped once
  S.learned.timing = { eternity_surge = { n = 3, mean = -18, spread = 0 }, holy_shock = { n = 7, mean = -1.2, spread = 1.2 } }
  S.learned.timingVersion = 2
  S.Bind(ns.Specs.current.key)
  eq(S.learned.timing.eternity_surge, nil, "-18 s: dropped")
  eq(S.learned.timing.holy_shock and S.learned.timing.holy_shock.n, 7, "-1.2 s: kept")
end)

test("performance grade: a break (6 s+ with no spell: between packs, a cutscene) isn't idle time", function()
  Reset()
  local ns = Boot()
  local Gr = ns.Grade
  ns.db.gradeChain = false
  local spec = Gr.SpecKey()
  Gr.Reset()
  local A = { id = 101, token = "spell_a" }
  local r = { main = A, queue = { A } }
  local isRot = ns.Engine.IsRotationSpell
  ns.Engine.IsRotationSpell = function() return true end
  local function Press(n)
    for _ = 1, n do
      Gr.OnReady(101, mock.now, A)
      Gr.Tick(true)
      Gr.OnPress(101, r, true)
      Gr.Tick(false)
      mock.now = mock.now + 1.5
    end
  end
  Gr.OnCombat(true)
  Press(10)
  -- 20 s waiting with slot 1 ready and nothing pressed, still in combat (dummies)
  for _ = 1, 80 do
    Gr.Tick(true)
    mock.now = mock.now + 0.25
  end
  Press(10)
  Gr.OnCombat(false)
  local got = Gr.Summary(spec).history[1]
  eq(got.abc > 95, true, "the break isn't held against you: " .. got.abc)
  eq(math.floor(got.length + 0.5) <= 31, true, "nor counted in the fight's length: " .. got.length)
  eq(got.reactionMs ~= nil and got.reactionMs < 1000, true, "no 20 s reaction from it")
  ns.Engine.IsRotationSpell = isRot
end)

test("performance grade: quick fights chain (mob to mob), one grade after the gap or every 3 minutes", function()
  Reset()
  local ns = Boot()
  local Gr = ns.Grade
  local spec = Gr.SpecKey()
  Gr.Reset()
  local A = { id = 101, token = "spell_a" }
  local r = { main = A, queue = { A } }
  local isRot = ns.Engine.IsRotationSpell
  ns.Engine.IsRotationSpell = function() return true end
  local function Mob(seconds)
    Gr.OnCombat(true)
    for _ = 1, seconds / 1.5 do
      Gr.OnPress(101, r, true)
      mock.Advance(1.5)
    end
    Gr.OnCombat(false)
  end
  Mob(12)
  eq(Gr.Summary(spec), nil, "a 12 s mob alone isn't long enough")
  mock.Advance(4) -- run to the next one
  Mob(12)
  eq(Gr.Summary(spec), nil, "the chain goes on: nothing shown yet")
  mock.Advance(Gr.CHAIN_GAP + 0.1)
  local s = Gr.Summary(spec)
  eq(s ~= nil and #s.history, 1, "10 s out of combat: one grade for both")
  eq(s.history[1].fights, 2)
  eq(math.floor(s.history[1].length + 0.5), 24, "the run between them doesn't count")
  eq(s.history[1].abc > 95, true, "nor as idle time: " .. s.history[1].abc)
  -- a long run: graded at a fight's end once it has gone 3 minutes, without waiting
  for _ = 1, 16 do
    Mob(12)
    mock.Advance(3)
  end
  s = Gr.Summary(spec)
  eq(#s.history >= 2, true, "a long chain is graded at least every 3 minutes")
  -- off: every fight on its own, at once
  Gr.Reset()
  mock.Advance(Gr.CHAIN_GAP + 1)
  ns.db.gradeChain = false
  Mob(24)
  s = Gr.Summary(spec)
  eq(s ~= nil and #s.history, 1, "setting off: graded at the fight's end")
  ns.Engine.IsRotationSpell = isRot
end)

test("a press refused for Energy (or range, facing) never holds the spell back; one refused as not ready does", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  local rec = QRecord({ { a = "tigers_fury", k = "R" } })
  rec.spellInfo[5217] = { n = "tigers_fury", cd = 30, gcd = 1.5 }
  Feral(ns, rec)
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Advance(2)
  -- Rake a moment before the Energy is there (the failed cast first, then the game's message)
  S.OnCastFailed(1822)
  S.OnUIError(nil, "Not enough energy")
  eq(S.RefusedHold(1822), false, "not enough Energy: Rake stays in slot 1 (Feral, 2026-11-10)")
  mock.Advance(0.3)
  S.OnUIError(nil, "Out of range.") -- (the message can come first too)
  S.OnCastFailed(1822)
  eq(S.RefusedHold(1822), false, "out of range: no hold either")
  mock.Advance(1)
  S.OnCastFailed(1822)
  S.OnUIError(nil, ERR_SPELL_COOLDOWN)
  eq(S.RefusedHold(1822), true, "'not ready yet': held a moment")
  mock.Advance(3)
  S.OnCastFailed(1822) -- no message at all (quiet failure): held as before
  eq(S.RefusedHold(1822), true)
  mock.Fire("PLAYER_REGEN_ENABLED")
  mock.inCombat, mock.restricted = false, false
end)

test("a refused press is logged with the game's reason and what slot 1 showed (dimmed 'waiting' checks)", function()
  -- "I wasn't waiting on energy... I would press it anyway and it went through" (Outlaw, 2026-11-13)
  Reset()
  local logged = {}
  DMGAssistWatchdog = { Log = function(kind, data) logged[#logged + 1] = { kind, data } end } -- luacheck: ignore 111
  local ns = Boot()
  local S = ns.State
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Advance(2)
  S.OnCastFailed(1822)
  S.OnUIError(nil, "Not enough energy")
  S.OnCastFailed(1822) -- pressed again at once: one line a second per spell
  S.OnUIError(nil, "Not enough energy")
  local n, data = 0, nil
  for _, l in ipairs(logged) do
    if l[1] == "refused" then
      n, data = n + 1, l[2]
    end
  end
  eq(n, 1, "once")
  eq(tostring(data):find("Not enough energy", 1, true) ~= nil, true, "the reason: " .. tostring(data))
  mock.inCombat = false
  mock.Fire("PLAYER_REGEN_ENABLED")
  DMGAssistWatchdog = nil -- luacheck: ignore 111
end)

test("resource gains are read from the game's tooltip (talents included) out of combat", function()
  -- Starfire: our data 8 Astral Power, the tooltip "Generates 12 Astral Power" (owner, 2026-11-13)
  Reset()
  local ns = Boot()
  local rec = QRecord({ { a = "shred", k = "S" } })
  Feral(ns, rec)
  mock.spellDescriptions = mock.spellDescriptions or {}
  local old = C_Spell.GetSpellDescription
  C_Spell.GetSpellDescription = function(id)
    if id == 5221 then return "Shreds the target. Awards 2 combo points." end
    return ""
  end
  ns.State.LearnGains()
  eq(ns.SpellMap.Info(5221).gain[4], 2, "Shred: 1 in our data, 2 per the tooltip")
  C_Spell.GetSpellDescription = old
end)

test("a spell the game refuses for your weapon is held back until your gear changes", function()
  -- Subtlety without daggers: Secret Technique / Gloomblade shown and refused again and again (2026-11-13)
  Reset()
  SPELL_FAILED_EQUIPPED_ITEM_CLASS_MAINHAND = "Must have a %s equipped in the main hand" -- luacheck: ignore 111
  local ns = Boot()
  local S = ns.State
  eq(S.IsEquipError("Must have a Dagger equipped in the main hand"), true)
  eq(S.IsEquipError("Not enough energy"), false)
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  S.OnCastFailed(1822)
  S.OnUIError(nil, "Must have a Dagger equipped in the main hand")
  local ok, why = ns.Engine.Castable(1822)
  eq(ok, false)
  eq(why, "equipment")
  mock.Fire("PLAYER_EQUIPMENT_CHANGED")
  eq(S.EquipRefused(1822), false, "new gear: try again")
  mock.inCombat = false
  mock.Fire("PLAYER_REGEN_ENABLED")
  SPELL_FAILED_EQUIPPED_ITEM_CLASS_MAINHAND = nil -- luacheck: ignore 111
end)

test("slot 1 showing a spell with no key says which spell it is, once (Surging Totem, 2026-11-10)", function()
  Reset()
  local ns = Boot()
  local B = ns.Bindcheck
  local before = #mock.printed
  B.OnShown({ id = 5221, token = "shred" })
  eq(#mock.printed, before + 1, "one chat line")
  eq(tostring(mock.printed[#mock.printed]):find("slot 1", 1, true) ~= nil, true, tostring(mock.printed[#mock.printed]))
  B.OnShown({ id = 5221, token = "shred" })
  eq(#mock.printed, before + 1, "once per spell per session")
  ns.db.bindWarn = false
  B.OnShown({ id = 1822, token = "rake" })
  eq(#mock.printed, before + 1, "setting off: quiet")
end)

test("nothing castable during a cast or channel of ours: slot 1 keeps it instead of an empty bar", function()
  Reset()
  local ns = Boot()
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  local real = ns.Engine.Recommend
  ns.Engine.Recommend = function() return { queue = {} } end -- the game: nothing can be pressed while it runs
  mock.acSpell = nil
  mock.casting = { id = 5221, endsIn = 0.7 } -- Consumption stands in
  local r = ns.Update()
  ns.Engine.Recommend = real
  eq(r and r.main and r.main.id, 5221, "the cast stays in slot 1 (Blood Consumption, 2026-11-10)")
  eq(r.main.source, "channel")
  mock.casting = nil
  mock.inCombat = false
end)

test("a spell on none of your action bars is never shown: the next one takes its place, chat says which", function()
  Reset()
  local ns = Boot()
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  local r = ns.Update()
  local first, second = r.queue[1].id, r.queue[2] and r.queue[2].id
  eq(second ~= nil and second ~= first, true, "two different spells to start with")
  eq(ns.Choices.OnBars(first), true, "no bars read at all: nothing is filtered")
  -- the bars hold the second spell only
  ActionButton3 = { action = 3, commandName = "ACTIONBUTTON3", shown = true, events = {}, scripts = {} }
  setmetatable(ActionButton3, getmetatable(ns.Display.frame))
  mock.actionInfo = { [3] = { "spell", second } }
  mock.bindings = { ACTIONBUTTON3 = "3" }
  ns.Display.InvalidateKeybinds()
  local before = #mock.printed
  mock.Advance(3)
  r = ns.Update()
  eq(r.main and r.main.id ~= first, true, "the spell you can't press is skipped (Vampiric Blood, 2026-11-10)")
  eq(#mock.printed > before, true, "and chat says which one")
  ns.db.barsRequired = false
  mock.Advance(3)
  ns.Update()
  eq(ns.Choices.OnBars(first), true, "setting off: every spell counts as pressable again")
  ns.db.barsRequired = nil
  ActionButton3 = nil
  mock.inCombat = false
end)

test("a long cooldown cast a moment ago isn't offered again when our clock can't tell (Havoc Metamorphosis)", function()
  Reset()
  local ns = Boot()
  local S, G = ns.State, ns.Engine
  local rec = QRecord({ { a = "tigers_fury", k = "R" } })
  rec.spellInfo[5217] = { n = "tigers_fury", cd = 120, gcd = 1.5 }
  Feral(ns, rec)
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  eq(G.CastRecently(5217), false, "never cast")
  S.lastCastToken.tigers_fury = GetTime() -- cast under whatever ID
  mock.Advance(20)
  eq(G.CastRecently(5217), true, "20 s into a 120 s cooldown: not back")
  mock.Advance(60)
  eq(G.CastRecently(5217), false, "80 s in: could be back (talents cut cooldowns), our other clues decide")
  rec.spellInfo[5217].cd = 12
  S.lastCastToken.tigers_fury = GetTime()
  eq(G.CastRecently(5217), false, "short cooldowns: not this rule's business")
  mock.Fire("PLAYER_REGEN_ENABLED")
  mock.inCombat = false
end)

test("a spell 'applying itself' for a GCD is its cast, not the buff of that name (Devourer Eradicate)", function()
  Reset()
  local ns = Boot()
  local M, S = ns.SpellMap, ns.State
  local rec = QRecord({ { a = "tigers_fury", k = "R" } })
  rec.spellInfo[1225826] = { n = "eradicate", gcd = 1.5, ch = 1, chcd = 8, d = 1.5, ap = { { 1225826, "self" } } }
  rec.spellInfo[1239524] = { n = "eradicate", r = 25 } -- the real buff, from Void Ray's channel
  rec.spellInfo[5217] = { n = "tigers_fury", cd = 30, gcd = 1, d = 10, ap = { { 5217, "self" } } }
  Feral(ns, rec)
  eq(M.IsOwnAura("eradicate"), false, "not ours: never-seen doesn't mean down")
  eq(#S.AppliedAuras(1225826), 0, "casting Eradicate starts no buff.eradicate clock")
  eq(M.IsOwnAura("tigers_fury"), true, "a real self buff (10 s) stays ours")
  eq(#S.AppliedAuras(5217), 1)
end)

test("Devourer on 8 targets: Blizzard's Reap / Eradicate wins over the Consume filler (buff.eradicate is hidden)", function()
  Reset()
  local ns = Boot()
  local M, S = ns.SpellMap, ns.State
  local key = "demonhunter_devourer"
  local record = ns.Data.specs.midnight[key]
  local book = {} -- the spells of the class-trial character in the report
  for _, token in ipairs({ "consume", "reap", "eradicate", "void_ray", "metamorphosis", "soul_immolation",
    "voidblade", "cull", "collapsing_star" }) do
    local id = record.spells[token] and record.spells[token].a[1]
    if id then
      book[#book + 1] = { spellID = id, name = token }
    end
  end
  mock.book = book
  mock.heroTree = "annihilator"
  mock.talents = { { name = "Eradicate", spellID = 1226033, rank = 1 },
    { name = "Annihilator", spellID = record.heroTrees.annihilator[1], rank = 1 } }
  ns.Specs.current = { key = key, status = "ready", data = record, branch = "midnight", client = "Midnight" }
  M.SetData(record)
  M.Refresh()
  S.Bind(key)
  mock.power[17], mock.powerMax[17] = 40, 100 -- Fury: hidden in combat
  mock.nameplates = 8
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Advance(1)
  mock.usable[M.SpellID("void_ray")] = { false, true } -- not enough Fury
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "meta", M.SpellID("metamorphosis")) -- used earlier
  mock.cooldowns[M.SpellID("metamorphosis")] = { active = true, start = mock.now, duration = 120 }
  mock.Advance(30) -- Meta's window is over
  mock.acSpell = M.SpellID("reap")
  local r = ns.Update()
  eq(r and r.main and r.main.token, "reap", "slot 1 follows Blizzard into the Reap branch")
  mock.inCombat, mock.restricted = false, false
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

test("slots 2-3: after pretending Void Ray (100 Fury), Void Ray isn't affordable again (Fury hidden, known 100+)", function()
  Reset()
  local ns = Boot()
  local S, G, C = ns.State, ns.Engine, ns.Clues
  local rec = QRecord({ { a = "tigers_fury", k = "R" } })
  rec.spellInfo[473728] = { n = "void_ray", gcd = 1.5, cost = { [17] = 100 } }
  Feral(ns, rec)
  mock.powerMax[17] = 100
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  C.bounds[17] = { lo = 100, hi = math.huge, untilT = GetTime() + 10, source = "assisted" }
  local lo, hi = S.PowerBounds(17)
  eq(lo, 100, "now: 100") eq(hi, 100, "capped at the maximum")
  S.BeginLookahead(0)
  eq(G.BelowCostAhead(473728), false, "the first Void Ray is affordable")
  S.Apply(473728)
  local _, after = S.PowerBounds(17)
  eq(after, 0, "after spending 100 of at most 100: nothing left")
  eq(G.BelowCostAhead(473728), true, "a second Void Ray isn't next")
  S.EndLookahead()
  mock.inCombat, mock.restricted = false, false
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

test("slots 2-3: Starfall (50 Astral Power, known only '34 or more') isn't promised twice in a row", function()
  Reset()
  local ns = Boot()
  local S, G, C = ns.State, ns.Engine, ns.Clues
  local rec = QRecord({ { a = "tigers_fury", k = "R" } })
  rec.spellInfo[191034] = { n = "starfall", gcd = 1.5, cost = { [8] = 50 } }
  Feral(ns, rec)
  mock.powerMax[8] = 100
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  C.bounds[8] = { lo = 34, hi = math.huge, untilT = GetTime() + 10, source = "usable" }
  S.BeginLookahead(0)
  eq(G.BelowCostAhead(191034), false, "nothing spent yet: the game's 'usable' decides slot 1")
  S.Apply(191034)
  local lo, hi = S.PowerBounds(8)
  eq(lo, 0) eq(hi, 50)
  eq(G.BelowCostAhead(191034), true, "after one Starfall from an unknown pool, a second isn't promised")
  S.EndLookahead()
  mock.inCombat, mock.restricted = false, false
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

test("Outlaw: rtb_buffs is Roll the Bones' sets (1-4) - read when shown, 1-4 after our cast, 0 without it", function()
  Reset()
  local ns = Boot()
  local M, S = ns.SpellMap, ns.State
  local key = "rogue_outlaw"
  local record = ns.Data.specs.midnight[key]
  mock.book = { { spellID = record.spells.roll_the_bones.a[1], name = "roll_the_bones" } }
  ns.Specs.current = { key = key, status = "ready", data = record, branch = "midnight", client = "Midnight" }
  M.SetData(record)
  M.Refresh()
  S.Bind(key)
  local direct = S.DirectAura
  local shown = {}
  S.DirectAura = function(id)
    return shown[id] and { present = true, expires = GetTime() + 20, stacks = 1 } or { present = false }
  end
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  eq(S.Resolve("rtb_buffs", {}), 0, "never rolled: 0")
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "rtb", M.SpellID("roll_the_bones"))
  local lo, hi = S.Bounds("rtb_buffs")
  eq(lo, 1) eq(hi, 4)
  shown[1214935] = true -- Triple Threat
  eq(S.Resolve("rtb_buffs", {}), 3, "the set the game shows")
  shown[1214935] = nil
  mock.now = mock.now + 31
  eq(S.Resolve("rtb_buffs", {}), 0, "expired")
  S.DirectAura = direct
  mock.inCombat, mock.restricted = false, false
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

test("SimC terms now read: scorch_execute, energize_amount, apex.N, movement.distance, soul_fragments", function()
  Reset()
  local ns = Boot()
  local M, S = ns.SpellMap, ns.State
  -- Fire: Scorch execute at 30% health (or Heat Shimmer), only with the talent
  local rank = M.TalentRank
  M.TalentRank = function(t) if t == "scorch" then return 1 end return rank(t) end
  local uh, uhm = UnitHealth, UnitHealthMax
  local hp = 250
  UnitHealth = function() return hp end
  UnitHealthMax = function() return 1000 end
  eq(S.Resolve("scorch_execute.active", {}), 1, "25% health: execute")
  hp = 800
  local v = S.Resolve("scorch_execute.active", {})
  eq(v == 0 or v == ns.Expr.UNKNOWN, true, "80%: not (or unknown while Heat Shimmer can't be read)")
  M.TalentRank = function(t) if t == "scorch" then return 0 end return rank(t) end
  eq(S.Resolve("scorch_execute.active", {}), 0, "no talent: never")
  M.TalentRank = rank
  UnitHealth, UnitHealthMax = uh, uhm
  -- Balance: the line's own spell's resource
  local spellID, info = M.SpellID, M.Info
  M.SpellID = function(t) if t == "full_moon" then return 274283 end return spellID(t) end
  M.Info = function(id) if id == 274283 then return { gain = { [8] = 50 } } end return info(id) end
  eq(S.Resolve("energize_amount", { action = "full_moon" }), 50)
  M.SpellID, M.Info = spellID, info
  -- apex.N: tiers of the spec's apex talent
  M.apexRank = 2
  eq(S.Resolve("apex.1", {}), 1) eq(S.Resolve("apex.2", {}), 1) eq(S.Resolve("apex.3", {}), 0)
  M.apexRank = 0
  eq(S.Resolve("apex.3", {}), 0, "no apex talent")
  -- Warriors' charge: movement.distance is the distance to the target
  eq(S.Resolve("movement.distance", {}), S.Resolve("target.distance", {}))
  -- Demon Hunter: the Soul Fragments buff's stacks when readable (none here: 0), else a 0..cap range
  local lo, hi = S.SoulFragments(nil)
  eq(lo, 0) eq(hi == 0 or hi >= 6, true)
  eq(S.Resolve("soul_fragments.inactive", {}), 0)
end)

test("Subtlety at 7/7 combo points on 5 targets spends them (Blizzard's assistant stuck on a missing poison)", function()
  Reset()
  local ns = Boot()
  local M, S = ns.SpellMap, ns.State
  local key = "rogue_subtlety"
  local record = ns.Data.specs.midnight[key]
  local book = {}
  for _, token in ipairs({ "shuriken_storm", "backstab", "eviscerate", "black_powder", "secret_technique",
    "shadow_dance", "shadow_blades", "slice_and_dice", "rupture", "shadowstrike", "symbols_of_death" }) do
    local id = record.spells[token] and record.spells[token].a[1]
    if id then
      book[#book + 1] = { spellID = id, name = token }
    end
  end
  mock.book = book
  mock.heroTree = "trickster"
  mock.talents = {}
  ns.Specs.current = { key = key, status = "ready", data = record, branch = "midnight", client = "Midnight" }
  M.SetData(record)
  M.Refresh()
  S.Bind(key)
  mock.power[4], mock.powerMax[4] = 7, 7 -- combo points: readable in combat (the report: combo_points=ok)
  mock.powerReadable[4] = true
  mock.power[3], mock.powerMax[3] = 60, 100
  mock.nameplates = 5
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  for _, token in ipairs({ "shadow_blades", "shadow_dance", "symbols_of_death" }) do
    local id = M.SpellID(token)
    if id then
      mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cd", id)
      mock.cooldowns[id] = { active = true, start = mock.now, duration = 90 }
    end
  end
  mock.Advance(20)
  mock.usable[M.SpellID("shadowstrike")] = { false, false } -- only in Stealth / Shadow Dance
  local r = ns.Update()
  local builders = { shuriken_storm = true, backstab = true, shadowstrike = true, gloomblade = true }
  assert(r.main and not builders[r.main.token], "a finisher, not a builder: got "
    .. tostring(r.main and r.main.token))
  mock.inCombat, mock.restricted = false, false
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

test("Thistle Tea (381623) drinks itself below 30 Energy: never suggested unless you took the button choice", function()
  Reset()
  local ns = Boot()
  local M, G = ns.SpellMap, ns.Engine
  local rec = QRecord({ { a = "thistle_tea", k = "T" } })
  rec.spellInfo[381623] = { n = "thistle_tea", cd = 1, ch = 3, chcd = 60 }
  rec.spellInfo[1298826] = { n = "thistle_tea", cd = 1, ch = 3, chcd = 60 }
  rec.spells.thistle_tea = { a = { 381623, 1298826, 469779 } }
  mock.book = { { spellID = 381623, name = "Thistle Tea" } }
  mock.talents = {} -- the automatic talent isn't readable on a class-trial character
  Feral(ns, rec)
  M.Refresh()
  eq(M.IsAutomatic(381623), true)
  local castable, why = G.Castable(381623)
  eq(castable, false) eq(why, "auto")
  mock.talents = { { name = "Thistle Tea", spellID = 1298826, rank = 1 } }
  M.Refresh()
  eq(M.IsAutomatic(381623), false, "the button choice: suggested as usual")
end)

test("Blizzard still naming a spell you just cast teaches nothing and doesn't mark it ready (Eternity Surge)", function()
  Reset()
  local ns = Boot()
  local S = ns.State
  local rec = QRecord({ { a = "tigers_fury", k = "R" } })
  rec.spellInfo[5217] = { n = "tigers_fury", cd = 30, gcd = 1 }
  Feral(ns, rec)
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Advance(1)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 5217)
  mock.Advance(0.05)
  S.acNamed = nil
  S.ObserveAssistedCharge(5217) -- the assistant hasn't moved on yet
  eq(S.learned.timing.tigers_fury, nil, "nothing learned")
  eq(S.CooldownReady(5217), false, "still on its 30 s cooldown")
  mock.Advance(20)
  S.acNamed = nil
  S.ObserveAssistedCharge(5217) -- 20 s later: a real "ready early"
  eq(S.learned.timing.tigers_fury ~= nil, true, "that one is learned")
  mock.inCombat, mock.restricted = false, false
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

test("Subtlety on 5 targets waiting for Energy: the Shuriken Storm it's pooling for, not Blizzard's Gloomblade", function()
  Reset()
  local ns = Boot()
  local M, S = ns.SpellMap, ns.State
  local key = "rogue_subtlety"
  local record = ns.Data.specs.midnight[key]
  local book = {}
  for _, token in ipairs({ "shuriken_storm", "gloomblade", "eviscerate", "black_powder", "secret_technique",
    "shadow_dance", "shadow_blades", "shadowstrike" }) do
    local id = record.spells[token] and record.spells[token].a[1]
    if id then
      book[#book + 1] = { spellID = id, name = token }
    end
  end
  mock.book = book
  mock.heroTree = "trickster"
  mock.talents = {}
  ns.Specs.current = { key = key, status = "ready", data = record, branch = "midnight", client = "Midnight" }
  M.SetData(record)
  M.Refresh()
  S.Bind(key)
  mock.power[4], mock.powerMax[4], mock.powerReadable[4] = 2, 7, true
  mock.power[3], mock.powerMax[3] = 20, 100
  mock.nameplates = 5
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  for _, token in ipairs({ "shadow_blades", "shadow_dance" }) do
    local id = M.SpellID(token)
    if id then
      mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cd", id)
      mock.cooldowns[id] = { active = true, start = mock.now, duration = 90 }
    end
  end
  mock.Advance(20)
  mock.usable[M.SpellID("shuriken_storm")] = { false, true } -- not enough Energy
  mock.usable[M.SpellID("shadowstrike")] = { false, false }
  mock.acSpell = M.SpellID("gloomblade")
  local r = ns.Update()
  eq(r.main and r.main.token, "shuriken_storm", "the spell it's waiting for")
  eq(r.main and r.main.source, "pool", "shown as waiting")
  mock.acSpell, mock.inCombat, mock.restricted = nil, false, false
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

test("an icon with no keybind names its spell (never an unexplained icon)", function()
  Reset()
  local ns = Boot()
  local D = ns.Display
  local pk, gsn = D.PickKeybind, C_Spell.GetSpellName
  D.PickKeybind = function() return nil end
  C_Spell.GetSpellName = function() return "Pummel" end
  local cfg = D.Settings()
  cfg.keybind, cfg.spellNames = true, false
  local icon = D.frame.slots[1]
  D.SetIcon(icon, { id = 6552, source = "interrupt" }, cfg, true, "")
  eq(icon.noKey, true)
  eq(icon.name:GetText(), "Pummel", "its name where the key would be")
  D.PickKeybind = function() return "V" end
  D.SetIcon(icon, { id = 6552, source = "interrupt" }, cfg, true, "")
  eq(icon.noKey, nil)
  eq(icon.name:GetText(), "", "a key: no name (spell names off)")
  D.PickKeybind, C_Spell.GetSpellName = pk, gsn
end)

test("every spell on its cooldown at once: slot 1 is the one ready first, shaded, never an empty bar", function()
  -- Protection right after Thunder Clap: Shield Slam, Revenge, Demolish all cooling down emptied the HUD (2026-11-12)
  Reset()
  local ns = Boot()
  local rec = QRecord({ { a = "tigers_fury", k = "S" }, { a = "shred", k = "S" } })
  Feral(ns, rec)
  ns.Specs.current = { key = "druid_feral", status = "ready", data = rec, branch = "midnight", client = "Midnight" }
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Advance(2)
  mock.cooldowns[5217] = { active = true, start = mock.now, duration = 12 }
  mock.cooldowns[5221] = { active = true, start = mock.now, duration = 6 }
  local r = ns.Update()
  eq(r.main and r.main.token, "shred", "the one off cooldown first")
  eq(r.main and r.main.source, "soon", "shown as coming")
  eq(r.queue[2] and r.queue[2].token, "tigers_fury", "then the next")
  mock.inCombat = false
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

test("look-ahead: Blizzard's rules never bring back a spell SimC ruled out now (Outlaw's Vanish in slot 2)", function()
  -- Vanish sat in slot 2 all fight from Blizzard's "vanish if not stealthed", SimC said no (2026-11-13)
  Reset()
  local ns = Boot()
  -- Shred now (certain); a second Shred in a row is ruled out, so nothing certain is left for slot 2
  local rec = QRecord({ { a = "tigers_fury", c = "0", k = "S" }, { a = "shred", c = "!prev_gcd.1.shred", k = "S" } })
  rec.blizzard = { default = { { a = "tigers_fury", k = "R" } } }
  rec.blizzardOrder = { "default" }
  Feral(ns, rec)
  ns.Specs.current = { key = "druid_feral", status = "ready", data = rec, branch = "midnight", client = "Midnight" }
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Advance(5)
  local r = ns.Update()
  eq(r.main and r.main.token, "shred")
  for i = 2, #r.queue do
    eq(r.queue[i].token ~= "tigers_fury", true, "slot " .. i .. ": not the spell SimC ruled out")
  end
  mock.inCombat, mock.restricted = false, false
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

test("look-ahead: a spell SimC ruled out in the live decision isn't predicted by Blizzard's rules either", function()
  -- Outlaw: SimC's cooldown list (Vanish false) is called only sometimes; in a look-ahead step that skipped it,
  -- Blizzard's "vanish if not stealthed" put Vanish in slot 2 (2026-11-13)
  Reset()
  local ns = Boot()
  local rec = QRecord({
    { a = "call_action_list", p = { name = "cds" }, c = "!prev_gcd.1.shred", k = "S" },
    { a = "shred", c = "!prev_gcd.1.shred", k = "S" },
  })
  rec.simc.cds = { { a = "tigers_fury", c = "0", k = "S" } }
  rec.blizzard = { default = { { a = "tigers_fury", k = "R" } } }
  rec.blizzardOrder = { "default" }
  Feral(ns, rec)
  ns.Specs.current = { key = "druid_feral", status = "ready", data = rec, branch = "midnight", client = "Midnight" }
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Advance(5)
  local r = ns.Update()
  eq(r.main and r.main.token, "shred")
  for i = 2, #r.queue do
    eq(r.queue[i].token ~= "tigers_fury", true, "slot " .. i .. ": not the spell SimC ruled out now")
  end
  mock.inCombat, mock.restricted = false, false
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

test("look-ahead: Blizzard's rules don't predict a spell SimC casts only before the pull (Unholy's Raise Dead)", function()
  -- Raise Dead filled Unholy's slot 2 on every step; SimC casts it only in precombat (2026-11-13). Slot 1 still
  -- follows the game, so a ghoul that dies mid-fight is still named there.
  Reset()
  local ns = Boot()
  local rec = QRecord({ { a = "tigers_fury", c = "0", k = "S" }, { a = "shred", c = "!prev_gcd.1.shred", k = "S" } })
  rec.simc.precombat = { { a = "rip", k = "S" } }
  rec.blizzard = { default = { { a = "rip", k = "R" } } }
  rec.blizzardOrder = { "default" }
  Feral(ns, rec)
  ns.Specs.current = { key = "druid_feral", status = "ready", data = rec, branch = "midnight", client = "Midnight" }
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Advance(5)
  local r = ns.Update()
  eq(r.main and r.main.token, "shred")
  for i = 2, #r.queue do
    eq(r.queue[i].token ~= "rip", true, "slot " .. i .. ": not the precombat-only spell")
  end
  mock.inCombat, mock.restricted = false, false
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

test("waiting for a resource: the spell is one SimC is sure of, not an unlit proc spell (Outlaw's Pistol Shot)", function()
  -- waiting showed Pistol Shot (Opportunity, not lit), then Sinister Strike when the Energy came (2026-11-13)
  Reset()
  local ns = Boot()
  local rec = QRecord({ { a = "shred", c = "buff.clearcasting.up", k = "S" }, { a = "ferocious_bite", k = "S" } })
  Feral(ns, rec)
  ns.Specs.current = { key = "druid_feral", status = "ready", data = rec, branch = "midnight", client = "Midnight" }
  Restrict() -- auras hidden: the proc is unknown, as in combat
  mock.Advance(5)
  mock.usable[5221] = { false, true } -- Shred: not enough Energy
  mock.usable[22568] = { false, true } -- Ferocious Bite: not enough either
  local r = ns.Update()
  eq(r.main and r.main.token, "ferocious_bite", "the line it is sure of")
  eq(r.main and r.main.source, "pool")
  mock.Fire("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", 5221) -- the proc is lit: then it is the one
  r = ns.Engine.Recommend(rec, { useAssisted = true }) -- (the decision: Update holds slot 1 a moment)
  eq(r.main and r.main.token, "shred", "lit: the proc spell")
  ns.State.glow[5221] = nil
  mock.inCombat, mock.restricted = false, false
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

test("short of the resource for a spender, but a castable line came first: that line, not the spender 'waiting'", function()
  -- Unholy at 0-29 Runic Power showed Death Coil, waiting, over Festering Strike earlier in the list (2026-11-12)
  Reset()
  local ns = Boot()
  local rec = QRecord({ { a = "tigers_fury", c = "0", k = "S" }, { a = "shred", c = "mystery_value>3", k = "S" },
    { a = "ferocious_bite", k = "S" } })
  Feral(ns, rec)
  ns.Specs.current = { key = "druid_feral", status = "ready", data = rec, branch = "midnight", client = "Midnight" }
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Advance(5)
  mock.usable[22568] = { false, true } -- Ferocious Bite: not enough
  mock.acSpell = 5217 -- Blizzard's pick, ruled out by its own line
  local r = ns.Update()
  eq(r.main and r.main.token, "shred", "the castable line before it")
  mock.acSpell, mock.inCombat, mock.restricted = nil, false, false
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

test("an off-bar spell on a line that says 'not now' isn't named in chat (the other hero tree's spells)", function()
  Reset()
  local ns = Boot()
  local rec = QRecord({ { a = "tigers_fury", c = "0", k = "S" }, { a = "shred", k = "S" } })
  Feral(ns, rec)
  ns.Specs.current = { key = "druid_feral", status = "ready", data = rec, branch = "midnight", client = "Midnight" }
  ActionButton3 = { action = 3, commandName = "ACTIONBUTTON3", shown = true, events = {}, scripts = {} }
  setmetatable(ActionButton3, getmetatable(ns.Display.frame))
  mock.actionInfo = { [3] = { "spell", 5221 } } -- Shred on a bar, Tiger's Fury nowhere
  mock.bindings = { ACTIONBUTTON3 = "3" }
  ns.Display.InvalidateKeybinds()
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  local before = #mock.printed
  ns.Engine.Recommend(rec, {})
  local named = false
  for i = before + 1, #mock.printed do
    named = named or tostring(mock.printed[i]):find("action bars", 1, true) ~= nil
  end
  eq(named, false, "its line is false: nothing said")
  ActionButton3 = nil
  mock.inCombat = false
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

test("Assassination right after Fan of Knives (everything short of Energy): slot 1 waits, it doesn't go blank", function()
  Reset()
  local ns = Boot()
  local M, S = ns.SpellMap, ns.State
  local key = "rogue_assassination"
  local record = ns.Data.specs.midnight[key]
  local book = {}
  for _, token in ipairs({ "fan_of_knives", "crimson_tempest", "mutilate", "envenom", "garrote", "rupture", "shiv" }) do
    local id = record.spells[token] and record.spells[token].a[1]
    if id then
      book[#book + 1] = { spellID = id, name = token }
    end
  end
  mock.book = book
  mock.talents = {}
  ns.Specs.current = { key = key, status = "ready", data = record, branch = "midnight", client = "Midnight" }
  M.SetData(record)
  M.Refresh()
  S.Bind(key)
  mock.power[4], mock.powerMax[4], mock.powerReadable[4] = 2, 7, true
  mock.power[3], mock.powerMax[3] = 20, 100
  mock.nameplates = 4
  mock.inCombat, mock.restricted = true, true
  mock.Fire("PLAYER_REGEN_DISABLED")
  mock.Advance(20)
  for _, b in ipairs(book) do
    mock.usable[b.spellID] = { false, true } -- not enough Energy for anything
  end
  mock.usable[M.SpellID("mutilate")] = { false, false }
  mock.acSpell = M.SpellID("mutilate")
  local r = ns.Update()
  eq(r.main ~= nil and r.main.id ~= nil, true, "something in slot 1")
  eq(r.main and r.main.source, "pool", "shown as waiting for Energy")
  mock.acSpell, mock.inCombat, mock.restricted = nil, false, false
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

test("mid spec switch (spells / talents just changed) nothing is named as off your bars; after it settles it is", function()
  Reset()
  local ns = Boot()
  local C = ns.Choices
  local printed = #mock.printed
  mock.Fire("SPELLS_CHANGED")
  C.NoteOffBars(5217)
  eq(#mock.printed, printed, "quiet right after the change")
  eq(C.offBarsNoted[5217], nil, "and not marked as said")
  mock.Advance(C.QUIET + 0.5)
  C.NoteOffBars(5217)
  eq(#mock.printed, printed + 1, "named once things settle")
end)

test("interrupts: delves (scenarios) count as open world, dungeons and raids as instances", function()
  Reset()
  local ns = Boot()
  local I = ns.Interrupts
  mock.instance = "scenario"
  eq(I.InInstance(), false, "a delve: any interruptible cast, like the open world")
  mock.instance = "party"
  eq(I.InInstance(), true, "a dungeon")
  mock.instance = "raid"
  eq(I.InInstance(), true, "a raid")
  mock.instance = nil
  eq(I.InInstance(), false, "open world")
end)

test("game mode: one note in the box, real gaps between notes, a put-off next hides, the switch is clear", function()
  Reset()
  local ns = Boot()
  local Game, D = ns.Game, ns.Display
  ns.commands.game("on")
  Game.IDLE_PAUSE, Game.lastAct = 1e9, mock.now -- playing (the idle pause has its own test)
  Game.held, Game.pending, Game.cast, Game.hidden, Game.dropping = nil, nil, nil, nil, nil
  for k, n in pairs(Game.notes) do
    n:Hide()
    Game.notes[k] = nil
  end
  local A, B, M = { id = 201, token = "a" }, { id = 202, token = "b" }, { id = 8921, token = "moonfire" }
  local function Run(res, secs, wait)
    D.Update(res, true)
    for _ = 1, math.floor(secs / 0.05) do
      D.frame.lastWait = wait or 0
      mock.now = mock.now + 0.05
      Game.Render()
    end
  end
  Game.streak = 7
  Run({ main = A, queue = { A, B } }, 2)
  local a = Game.notes["1:201:1"]
  eq(math.floor(a.x + 0.5), Game.HIT_X, "A waits on the line")
  -- the engine swaps them: B is slot 1 now, A goes back - A must not stay in the box under B
  Run({ main = B, queue = { B, A } }, 0.05)
  Run({ main = B, queue = { B, A } }, 1)
  local b, a2 = Game.notes["1:202:1"], Game.notes["1:201:1"]
  eq(math.floor(b.x + 0.5), Game.HIT_X, "B on the line")
  eq(a2 ~= nil and a2.x > Game.HIT_X + Game.ICON, true, "A came back in behind B, out of the box")
  eq(Game.streak, 0, "A waited 2 s on the line with nothing in the way: a quiet miss")
  eq(Game.misses, 1)
  -- a quick swap (no time on the line) is no miss
  Game.streak = 3
  Run({ main = A, queue = { A, B } }, 0.5)
  Run({ main = B, queue = { B, A } }, 0.5)
  eq(Game.streak, 3, "under EXPIRE on the line: not a miss")
  -- two notes never touch: each stays its real time behind the one before (at least an icon and a gap apart)
  for _ = 1, 20 do
    Run({ main = A, queue = { A, B, M } }, 0.1)
    Run({ main = A, queue = { A, M, B } }, 0.1)
  end
  local xs = {}
  for key, n in pairs(Game.notes) do
    if key:sub(1, 2) == "1:" then
      xs[#xs + 1] = n.x
    end
  end
  table.sort(xs)
  eq(#xs, 3, "three lane notes")
  for i = 2, #xs do
    eq(xs[i] - xs[i - 1] >= Game.ICON + Game.GAP_MIN - 1, true, "gap " .. (xs[i] - xs[i - 1]))
  end
  -- Moonfire stays "next" press after press while slot 1 moves on: it goes out of sight, back when it's slot 1
  for k, n in pairs(Game.notes) do
    n:Hide()
    Game.notes[k] = nil
  end
  Game.hidden = nil
  for i = 1, 4 do
    local now = (i % 2 == 1) and A or B
    Run({ main = now, queue = { now, M } }, 0.5)
    Game.Consume(Game.notes["1:" .. now.id .. ":1"])
  end
  Run({ main = A, queue = { A, M } }, 0.1)
  eq(Game.notes["1:8921:1"], nil, "a put-off next is hidden")
  Run({ main = M, queue = { M, A } }, 0.5)
  eq(Game.notes["1:8921:1"] ~= nil, true, "Moonfire is back as slot 1")
  -- the switch: CLASSIC | GAME, the lit half follows the mode
  local sw = Game.frame.toggle
  eq(sw.left:GetText(), "CLASSIC") eq(sw.right:GetText(), "FLOW")
  eq(sw.goal, 1, "GAME lit")
  sw:GetScript("OnClick")(sw)
  eq(Game.On(), false, "a click switches to the classic HUD")
  sw:GetScript("OnUpdate")(sw, 0.05)
  eq(sw.goal, 0, "CLASSIC lit")
  ns.commands.flow("on")
  eq(Game.On(), true, "/dmga flow on (its name since 1.6.0.203; /dmga game still works)")
  -- press start: out of combat with nothing played yet, the lane waits for you; the first hit says LET'S GO!
  Game.EndSet()
  Game.score, Game.hits = 0, 0
  mock.inCombat = false
  Game.IDLE_PAUSE = 6
  Game.Render()
  eq(Game.frame.ready:IsShown(), true, "waiting for the first press")
  eq(Game.frame.readyFrame:GetFrameLevel() > Game.frame:GetFrameLevel(), true, "over the notes, not behind them")
  local word = Game.frame.ready:GetText()
  eq(word == "READY, PLAYER ONE?" or word == "INSERT COIN" or word == "PRESS START", true, word)
  eq(Game.frame.readySub:GetText(), "Hit your first spell to start the Flow")
  -- a buff out of combat (Mark of the Wild entering a dungeon) leaves the start screen up; a rotation spell clears
  -- it quietly; 6 s later, still out of combat, it's back
  Game.frame.pop:SetText("")
  local isRot = ns.Engine.IsRotationSpell
  ns.Engine.IsRotationSpell = function(id) return id ~= 1126 end
  ns.OnOwnCast(1126)
  Run({ main = A, queue = { A, B } }, 0.1, 0)
  eq(Game.paused, true, "a buff doesn't start the Flow")
  local isPrep = ns.Engine.IsPrepSpell
  ns.Engine.IsPrepSpell = function(id) return id == 5487 end -- Bear Form
  ns.OnOwnCast(5487)
  Run({ main = A, queue = { A, B } }, 0.1, 0)
  eq(Game.paused, true, "a shapeshift out of combat is prep: no Flow")
  ns.Engine.IsPrepSpell = isPrep
  ns.OnOwnCast(201)
  eq(Game.paused, false) eq(Game.frame.pop:GetText(), "", "out of combat: no cheer")
  ns.Engine.IsRotationSpell = isRot
  Run({ main = A, queue = { A, B } }, Game.IDLE_PAUSE + 0.5, 0)
  eq(Game.startScreen, true, "start screen again") eq(Game.frame.ready:IsShown(), true)
  -- the pull: the first spell in combat starts the Flow
  mock.inCombat = true
  ns.OnOwnCast(201)
  eq(Game.frame.pop:GetText(), "LET'S GO!")
  for _ = 1, 6 do
    mock.now = mock.now + 0.05
    Game.Render()
  end
  eq(Game.frame.ready:IsShown(), false, "the Flow is on: the box gone at once")
  eq(Game.readyAlpha, 0)
  -- a cast running: its bar runs from the landing box to the next note, which lands as the cast ends
  local cc = ns.State.CurrentCast
  local left = 1.2
  ns.State.CurrentCast = function() return 194153, left end
  for k, n in pairs(Game.notes) do
    n:Hide()
    Game.notes[k] = nil
  end
  Run({ main = B, queue = { B, A } }, 1, 0)
  local nb = Game.notes["1:202:1"]
  local px = (Game.WIDTH - Game.HIT_X - Game.ICON / 2 - 2) / Game.LOOK
  eq(math.abs(nb.x - (Game.HIT_X + left * px)) < 2, true, "the next note waits for the cast: x " .. nb.x)
  eq(Game.frame.castTrack:IsShown(), true)
  local barEnd = Game.HIT_X + Game.ICON / 2 + 6 + Game.frame.castFill:GetWidth()
  eq(math.abs(barEnd - (nb.x - Game.ICON / 2 - 2)) < 0.5, true, "the bar ends at the next note")
  local w1 = Game.frame.castFill:GetWidth()
  left = 0.4
  Run({ main = B, queue = { B, A } }, 0.5, 0)
  eq(Game.frame.castFill:GetWidth() < w1, true, "the bar shrinks as the note comes in")
  left = 0
  Run({ main = B, queue = { B, A } }, 0.5, 0)
  eq(Game.frame.castTrack:IsShown(), false, "cast over: no bar")
  eq(math.floor(nb.x + 0.5), Game.HIT_X, "the note is in the box as the cast ends")
  -- the streak of 12 lost (2026-11-11): the next note waits through a long cast, then the engine swaps it at the
  -- cast's end. Casting is not "free to press": no quiet miss.
  for k, n in pairs(Game.notes) do
    n:Hide()
    Game.notes[k] = nil
  end
  Game.streak, Game.misses = 12, 0
  left = 2.5
  Run({ main = A, queue = { A, B } }, 2.4, 0) -- the HUD's clock says ready, the bar still runs
  left = 0
  Run({ main = B, queue = { B, A } }, 0.3, 0)
  eq(Game.streak, 12, "no miss for a note that waited while you cast") eq(Game.misses, 0)
  ns.State.CurrentCast = cc
  -- no spell for IDLE_PAUSE seconds (running to the group): the lanes pause, notes stop; the next spell resumes
  Game.IDLE_PAUSE = 6
  for k, n in pairs(Game.notes) do
    n:Hide()
    Game.notes[k] = nil
  end
  ns.OnOwnCast(201)
  Run({ main = A, queue = { A, B } }, 1, 1.0)
  eq(Game.paused, false, "playing")
  Run({ main = A, queue = { A, B } }, Game.IDLE_PAUSE + 0.5, 1.0)
  eq(Game.paused, true, "paused after IDLE_PAUSE s with no spell")
  eq(Game.frame.ready:GetText(), "PAUSED")
  eq(Game.notes["1:201:1"].x, Game.HIT_X, "paused: the next press waits in the box")
  Run({ main = A, queue = { A, B } }, 0.1, 0)
  local frozen = Game.notes["1:202:1"].x
  Game.streak = 5
  Run({ main = A, queue = { A, B } }, 3, 0)
  eq(Game.notes["1:202:1"].x, frozen, "nothing slides while paused")
  eq(Game.streak, 5, "a pause never costs the streak")
  -- a note that comes in during a pause takes its place at once (it froze off the right edge, 2026-11-12)
  local M2 = { id = 202770, token = "fury_of_elune" }
  Run({ main = A, queue = { A, M2 } }, 0.5, 0)
  Run({ main = A, queue = { A, M2 } }, 0.5, 0)
  eq(Game.notes["1:202770:1"].x < Game.WIDTH, true, "not off the edge")
  Run({ main = A, queue = { A, B } }, 0.5, 0)
  ns.OnOwnCast(201)
  eq(Game.paused, false) eq(Game.frame.pop:GetText(), "Back in the Flow!")
  Run({ main = A, queue = { A, B } }, 0.5, 0)
  eq(Game.frame.ready:IsShown() == false or Game.readyAlpha < 1, true, "the PAUSED box is going")
  -- the grade sits above the lanes, not on them
  ns.db.gradePoint = nil
  ns.Grade.Render(ns.Grade.SAMPLE, false, true)
  local p1, rel, p2 = ns.Grade.frame:GetPoint()
  eq(p1, "BOTTOM") eq(rel, Game.frame) eq(p2, "TOP")
  local withSet = setmetatable({ game = { score = 1400, bestStreak = 11, perfect = 60 } }, { __index = ns.Grade.SAMPLE })
  ns.Grade.Render(withSet, false, true)
  eq(ns.Grade.frame.flow:GetText():find("Flow score 1400", 1, true) ~= nil, true, "the grade shows the set")
  -- an instant's cast event comes as the next GCD begins: judged by when its note reached the line, not by the new
  -- GCD's wait (79 of 89 hits were "Good", none Perfect, 2026-11-12)
  for k, n in pairs(Game.notes) do
    n:Hide()
    Game.notes[k] = nil
  end
  Run({ main = A, queue = { A, B } }, 1, 0.6) -- coming in
  Run({ main = A, queue = { A, B } }, 0.05, 0.08) -- last frame: 0.08 s to go
  mock.now = mock.now + 0.05
  D.frame.lastWait = 1.5 -- the queued press went off as the GCD ended: the HUD already shows the next GCD
  Game.OnJudged("hit", 201)
  eq(Game.lastJudge, "perfect", "a queued press right on the beat: Perfect, not Good")
  -- a combo: "COMBO 1/2" over the box, then COMBO! with its violet sweep and points
  local scoreBefore = Game.score
  Game.OnComboStep(1, 2)
  eq(Game.frame.comboHint:GetText(), "COMBO 1/2")
  Game.OnCombo(2)
  eq(Game.frame.pop:GetText():find("COMBO!", 1, true) ~= nil, true, "the announcement")
  eq(Game.score > scoreBefore, true, "combo points")
  eq(Game.frame.comboAt ~= nil, true, "the sweep starts")
  -- the counted keep-up (Ironfur stacks) beside the action box, as on the classic HUD
  local stackInfo = D.StackInfo
  D.StackInfo = function()
    return { id = 192081 }, 2, 3
  end
  Game.Render()
  eq(Game.frame.stackText:IsShown(), true)
  eq((Game.frame.stackText:GetText() or ""):find("2", 1, true) ~= nil, true, "2 of 3")
  D.StackInfo = stackInfo
  Game.Render()
  -- out of combat a cast that isn't a rotation spell (switching spec, a 5 s cast) doesn't wake the lanes
  local inCombat = mock.inCombat
  mock.inCombat = false
  Game.lastAct = nil
  mock.casting = { id = 200749, endsIn = 5 } -- Activating Specialization
  Game.Render()
  eq(Game.lastAct, nil, "a spec switch isn't play")
  Game.Started(200749) -- its cast going through
  eq(Game.lastAct, nil, "nor is its cast")
  eq(Game.paused, true)
  mock.casting = nil
  mock.inCombat = inCombat
  -- the foot row: streak and score on the first line, rank and best on the second (one line cut them to "...")
  eq((Game.frame.streak:GetText() or ""):find("Best", 1, true), nil, "best is on the second line")
  eq(Game.frame.streak2 ~= nil, true)
  Run({ main = A, queue = { A, B } }, 0.1, 0)
  -- a cooldown in slot 1 and what follows it: linked notes (violet line between them, COMBO over the first)
  ns.Combos.Reset()
  ns.Combos.fightPresses = ns.Combos.WARMUP -- past the warm-up
  local CD = { id = 201, token = "cd", source = "simc", major = true }
  Run({ main = CD, queue = { CD, B } }, 0.1, 0)
  eq(Game.comboPlan ~= nil, true, "the chain is planned")
  eq(Game.frame.comboLinks[1]:IsShown(), true, "the line between the linked notes")
  -- the cooldown pressed: the rest of the chain stays linked, counted from where it is
  local C2 = { id = 203, token = "c2", source = "simc" }
  Run({ main = CD, queue = { CD, B, C2 } }, 0.1, 0)
  eq(ns.Combos.OnJudged("hit", 201), "start")
  Run({ main = B, queue = { B, C2 } }, 0.1, 0)
  eq(Game.comboPlan and Game.comboPlan.done, 1, "one of four done (a major cooldown)")
  eq(Game.frame.comboLinks[1]:IsShown(), true, "slots 1-2 still linked")
  -- an interrupt: COMBO BREAKER!
  Game.OnBonus("kick")
  eq(Game.frame.pop:GetText():find("COMBO BREAKER!", 1, true) ~= nil, true)
  -- a hot streak: Flow State
  Game.flowStateUntil, Game.hotRun = nil, Game.FLOW_STATE_AT - 1
  Game.cast = nil
  Game.OnJudged("near", 201) -- a Good: the hot streak needs Perfect / Great
  eq(Game.FlowStateOn(), false)
  Game.hotRun = Game.FLOW_STATE_AT - 1
  Game.cast = { id = 201, at = mock.now, judge = "perfect" }
  Game.OnJudged("hit", 201)
  eq(Game.lastJudge, "perfect")
  eq(Game.FlowStateOn(), true, "Flow State after the hot streak")
  Game.OnJudged("miss", 201)
  eq(Game.FlowStateOn(), false, "a miss ends it")
  ns.Combos.Reset()
  -- Ironfur (the off-GCD pick) shows beside the low-health heal the game shows when you're low
  local weaveRun = { main = A, queue = { A }, defensive = { id = 22842, how = "render", threshold = 50 },
    weave = { id = 192081, source = "mitigation" } }
  Run(weaveRun, 0.2, 0)
  eq(Game.notes["b:192081"], nil, "out of combat: no keep-up pick in the action row (DEFEND before the pull)")
  ns.State.combatStart = mock.now
  Run(weaveRun, 0.2, 0)
  eq(Game.notes["b:192081"] ~= nil, true, "Ironfur in the action row")
  eq(Game.notes["b:def"] ~= nil, true, "Frenzied Regeneration too")
  ns.State.combatStart = nil
  -- the low-health defensive is always listed (the game shows it when health is low): no alarm, no DEFEND!, the
  -- action row stays quiet (it shouted DEFEND! on login, 2026-11-11)
  Game.frame.alarmAt, Game.actAlpha, Game.kudosAt = nil, 0, nil
  Game.frame.pop:SetText("")
  Run({ main = A, queue = { A }, defensive = { id = 22812, how = "render", threshold = 35 } }, 1)
  eq(Game.frame.alarmAt, nil, "no alarm") eq(Game.frame.pop:GetText(), "", "no DEFEND!")
  eq(Game.actAlpha < 0.05, true, "the action row stays quiet")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
