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

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
