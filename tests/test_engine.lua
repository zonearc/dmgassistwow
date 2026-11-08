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
        { a = "berserk", k = "R" },
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
  eq(E.Test("(2>?5)=5&(2<?5)=2", r), true)
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
  eq(M.SpellID("moonfire_cat"), 8921)
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

test("major cooldown goes to the cooldown slot, burst toggle hides it", function()
  Reset()
  local ns = Boot()
  local r = ns.Engine.Recommend(Record(), {})
  eq(r.cd and r.cd.token, "berserk")
  eq(r.main.token ~= "berserk", true)
  r = ns.Engine.Recommend(Record(), { burst = false })
  eq(r.cd, nil)
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
  eq(r.cd, nil)
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

test("on Forever an UNKNOWN line can be corroborated by Blizzard's rule", function()
  Reset()
  local ns = Boot("camelot", 18)
  local rec = Record()
  rec.simc.finisher = {}
  mock.cooldowns[5221] = { active = true, start = 999, duration = 10 } -- shred on cooldown
  Restrict()
  -- rake's dot state is UNKNOWN; Blizzard's rake rule (combo_points<5) is UNKNOWN too: no corroboration.
  local r = ns.Engine.Recommend(rec, {})
  eq(r.main.token, "thrash", "falls back to Blizzard's rules")
  eq(r.main.source, "rules")
  rec.blizzard.default[2].c = "level>10"
  r = ns.Engine.Recommend(rec, {})
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
  local r = ns.Engine.Recommend(Record(), { useAssisted = true })
  -- finisher list is UNKNOWN (combo points), rake UNKNOWN, shred certain
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
  eq(ns.State.Targets(), 3)
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
  eq(n, 3)
  eq(label, "AOE")
  DMGAssist_CycleMode()
  eq(S.ActiveMode(), "auto")
  -- no nameplates (hidden or none in combat): the primary mode decides
  mock.nameplates = 0
  SlashCmdList.DMGASSIST("mode aoe")
  n, label = S.Targets()
  eq(n, 3)
  eq(label, "AOE?")
  SlashCmdList.DMGASSIST("auto off")
  n, label = S.Targets()
  eq(n, 3)
  eq(label, "AOE")
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
  local r = ns.Update()
  local f = ns.Display.frame
  eq(f.slots[1]:IsShown(), true)
  eq(f.slots[2]:IsShown(), r.queue[2] ~= nil)
  eq(type(f.header.text), "string")
  eq(f.header.text:find("ST", 1, true) ~= nil or f.header.text:find("AUTO", 1, true) ~= nil, true, f.header.text)
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

test("press-now cue lights when the GCD ends within the spell queue window; spell_haste", function()
  Reset()
  local ns = Boot()
  mock.cvars.SpellQueueWindow = "400" -- the game's default
  mock.cooldowns[61304] = { active = true, start = mock.now, duration = 1.5 }
  ns.Update()
  eq(ns.Display.frame.pressNow, false, "1.5 s left")
  mock.Advance(1.2)
  ns.Update()
  eq(ns.Display.frame.pressNow, true, "0.3 s left, inside the default 400 ms window")
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

test("settings: sections on every page, fonts listed, reset restores defaults", function()
  Reset()
  local ns = Boot()
  local headers = 0
  local cats = mock.settingsCategories
  local mine = {}
  for i = #cats - 4, #cats do
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
  eq(mine[5].parent, mine[1], "four sub-pages: Display, Alerts & Sounds, Combat, Advanced")
  local fonts = mock.settings.DMGASSIST_FONT.options()
  eq(fonts[1].value, "default")
  mock.settings.DMGASSIST_ICONSIZE:SetValue(80)
  mock.settings.DMGASSIST_INTERRUPTMODE:SetValue("off")
  ns.Options.ResetAll()
  eq(ns.db.hud.iconSize, 52)
  eq(ns.db.interruptMode, "smart")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
