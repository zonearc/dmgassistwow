import { describe, it, expect, beforeAll } from "vitest";
import { execSync } from "child_process";
import { writeFileSync, unlinkSync, existsSync, mkdirSync } from "fs";
import { join } from "path";
import {
  conditionToLua,
  generateToc,
  generateConfig,
  generateHelpers,
  generateEngine,
  generateHud,
  generateCore,
  generateSettingsPanel,
  generateLibStub,
  generateAllSpecsToc,
  generateAllSpecsConfig,
} from "../server/addon-generator";

const TEMP_DIR = join(process.cwd(), "tests", ".tmp-lua");

function ensureTempDir() {
  if (!existsSync(TEMP_DIR)) mkdirSync(TEMP_DIR, { recursive: true });
}

function luacParse(lua: string, filename: string): { valid: boolean; error: string } {
  ensureTempDir();
  const filePath = join(TEMP_DIR, filename);
  try {
    writeFileSync(filePath, lua, "utf-8");
    execSync(`luac -p "${filePath}" 2>&1`, { encoding: "utf-8" });
    return { valid: true, error: "" };
  } catch (err: any) {
    return { valid: false, error: err.stdout || err.stderr || err.message || String(err) };
  } finally {
    try { unlinkSync(filePath); } catch {}
  }
}

function wrapConditionAsLua(condLua: string): string {
  return `-- Stubs for all CLF functions used by conditions
local CLF = {}
function CLF.BuffUp(...) return true end
function CLF.BuffDown(...) return false end
function CLF.BuffRemains(...) return 0 end
function CLF.BuffStacks(...) return 0 end
function CLF.BuffDuration(...) return 0 end
function CLF.BuffMaxStacks(...) return 0 end
function CLF.DebuffUp(...) return true end
function CLF.DebuffDown(...) return false end
function CLF.DebuffRemains(...) return 0 end
function CLF.DebuffStacks(...) return 0 end
function CLF.DebuffPandemic(...) return true end
function CLF.CooldownReady(...) return true end
function CLF.CooldownRemains(...) return 0 end
function CLF.CooldownCharges(...) return 0 end
function CLF.CooldownDuration(...) return 0 end
function CLF.ChargesFractional(...) return 0 end
function CLF.Power(...) return 0 end
function CLF.PowerPct(...) return 0 end
function CLF.PowerDeficit(...) return 0 end
function CLF.PowerMax(...) return 100 end
function CLF.Runes(...) return 0 end
function CLF.TargetHealthPct(...) return 100 end
function CLF.FightRemains(...) return 300 end
function CLF.TargetIsCasting(...) return false end
function CLF.ActiveEnemies(...) return 1 end
function CLF.IsSpellUsable(...) return true end
function CLF.IsSpellKnown(...) return true end
function CLF.SpellCastTime(...) return 0 end
function CLF.SpellCost(...) return 0 end
function CLF.TalentEnabled(...) return true end
function CLF.GCDRemains(...) return 0 end
function CLF.GCDMax(...) return 1.5 end
function CLF.PrevGCD(...) return false end
function CLF.IsMoving(...) return false end
function CLF.IsForm(...) return false end
function CLF.IsStealthed(...) return false end
function CLF.PetAlive(...) return false end
function CLF.PetActive(...) return false end
function CLF.GetVar(...) return 0 end
function CLF.PlayerHealthPct(...) return 100 end
function CLF.ActiveDot(...) return 0 end
function CLF.TotemActive(...) return false end

local function test_condition()
  return ${condLua}
end

local result = test_condition()
`;
}

function makeSpec(overrides: Record<string, any> = {}) {
  return {
    id: "paladin-ret",
    className: "Paladin" as const,
    specName: "Retribution",
    role: "Melee DPS" as const,
    resource: "Holy Power" as const,
    classColor: "#F48CBA",
    iconSlug: "paladin-ret",
    ...overrides,
  };
}

function makeHudConfig(overrides: Record<string, any> = {}) {
  return {
    id: "hud-paladin-ret", specId: "paladin-ret",
    scale: 1, opacity: 0.9, positionX: 0, positionY: -200,
    iconSize: 48, predIconSize: 32, queueSlots: 3,
    showKeybind: true, keybindFontSize: 14, keybindPosition: "bottom-right" as const,
    showSpellName: true, spellNameFontSize: 10, showCondition: false,
    showResourceBar: true, showHeader: true, resourceCapThreshold: 80,
    aoeThreshold: 3, showPrediction: true, predictionOpacity: 0.4,
    framePadding: 12, iconSpacing: 6, lockPosition: false,
    debugMode: false, showCooldownText: true, showGcdSpark: true,
    outOfCombatMode: false, showDefensives: true,
    defensiveThreshold: 40, defensiveThresholdMinor: 60, defensiveThresholdMajor: 25,
    survivabilityMode: false, showSelfHeals: true, formAwareness: false,
    keybindBarPriority: ["Action Button", "MultiBarBottomLeft"],
    keybindOverrides: {}, interruptSound: true,
    interruptSoundId: 8959,
    potionEnabled: false, potionItemName: "",
    consumablesEnabled: true, flaskEnabled: true, flaskItemName: "",
    foodEnabled: true, foodItemName: "",
    weaponEnhEnabled: true, weaponEnhItemName: "",
    augmentRuneEnabled: true, augmentRuneItemName: "",
    ...overrides,
  };
}

function makeAplEntry(overrides: Record<string, any> = {}) {
  return {
    id: "test-apl-1", specId: "paladin-ret", priority: 5,
    spellName: "Final Verdict", spellIcon: "spell_paladin_templarsverdict",
    condition: "holy_power>=3", mode: "ST" as const,
    isInterrupt: false, isOffensive: false,
    isCooldown: false, enabled: true,
    keybind: "1", isPrecombat: false, precombatType: null as string | null,
    ...overrides,
  };
}

function makeAddonData(overrides: Record<string, any> = {}) {
  return {
    spec: makeSpec(),
    aplEntries: [
      makeAplEntry({ id: "a1", priority: 1, spellName: "Avenging Wrath", condition: "cooldown.avenging_wrath.ready", keybind: "Q", isOffensive: true, isCooldown: true }),
      makeAplEntry({ id: "a2", priority: 2, spellName: "Final Verdict", condition: "holy_power>=5|(holy_power>=3&buff.avenging_wrath.up)", keybind: "1" }),
      makeAplEntry({ id: "a3", priority: 3, spellName: "Blade of Justice", condition: "cooldown.blade_of_justice.ready&holy_power<=3", keybind: "3" }),
      makeAplEntry({ id: "a4", priority: 4, spellName: "Judgment", condition: "cooldown.judgment.ready&holy_power<5", keybind: "4" }),
      makeAplEntry({ id: "a5", priority: 5, spellName: "Crusader Strike", condition: "", keybind: "5" }),
    ],
    hudConfig: makeHudConfig(),
    alerts: [],
    ...overrides,
  };
}

describe("Real Lua Parser Validation (luac -p)", () => {
  describe("Generated file syntax", () => {
    it("LibStub.lua parses as valid Lua", () => {
      const result = luacParse(generateLibStub(), "LibStub.lua");
      expect(result.valid).toBe(true);
    });

    it("Config.lua parses as valid Lua", () => {
      const data = makeAddonData();
      const result = luacParse(generateConfig(data), "Config.lua");
      if (!result.valid) console.error("Config.lua parse error:", result.error);
      expect(result.valid).toBe(true);
    });

    it("Settings.lua parses as valid Lua", () => {
      const result = luacParse(generateSettingsPanel(), "Settings.lua");
      if (!result.valid) console.error("Settings.lua parse error:", result.error);
      expect(result.valid).toBe(true);
    });
  });

  describe("Condition transpiler produces valid Lua expressions", () => {
    const conditions = [
      { name: "empty", cond: "" },
      { name: "simple buff", cond: "buff.test.up" },
      { name: "buff down", cond: "buff.test.down" },
      { name: "buff remains", cond: "buff.test.remains>5" },
      { name: "buff stack", cond: "buff.test.stack>=3" },
      { name: "buff duration", cond: "buff.test.duration" },
      { name: "buff max_stack", cond: "buff.test.max_stack" },
      { name: "debuff up", cond: "debuff.test.up" },
      { name: "debuff remains", cond: "debuff.test.remains>3" },
      { name: "debuff stack", cond: "debuff.test.stack>=2" },
      { name: "target debuff", cond: "target.debuff.test.up" },
      { name: "cooldown ready", cond: "cooldown.test.ready" },
      { name: "cooldown remains", cond: "cooldown.test.remains<5" },
      { name: "cooldown charges", cond: "cooldown.test.charges>=2" },
      { name: "cooldown duration", cond: "cooldown.test.duration" },
      { name: "charges fractional", cond: "cooldown.test.charges_fractional>1.5" },
      { name: "dot ticking", cond: "dot.test.ticking" },
      { name: "dot refreshable", cond: "dot.test.refreshable" },
      { name: "dot remains", cond: "dot.test.remains<4" },
      { name: "holy power", cond: "holy_power>=3" },
      { name: "combo points", cond: "combo_points>=5" },
      { name: "energy", cond: "energy>40" },
      { name: "rage", cond: "rage>=30" },
      { name: "mana", cond: "mana>20" },
      { name: "runic power", cond: "runic_power>=80" },
      { name: "focus", cond: "focus>=30" },
      { name: "rune", cond: "rune>=3" },
      { name: "target health pct", cond: "target.health.pct<20" },
      { name: "target time to die", cond: "target.time_to_die>10" },
      { name: "active enemies", cond: "active_enemies>=3" },
      { name: "spell targets", cond: "spell_targets.divine_storm>=3" },
      { name: "talent enabled", cond: "talent.test.enabled" },
      { name: "talent bare", cond: "talent.test" },
      { name: "hero tree", cond: "hero_tree.lightsmith" },
      { name: "action ready", cond: "action.test.ready" },
      { name: "action usable", cond: "action.test.usable" },
      { name: "action cast time", cond: "action.test.cast_time" },
      { name: "gcd remains", cond: "gcd.remains<0.5" },
      { name: "gcd max", cond: "gcd.max" },
      { name: "fight remains", cond: "fight_remains>30" },
      { name: "prev gcd", cond: "prev_gcd.1.test" },
      { name: "moving", cond: "moving" },
      { name: "form moonkin", cond: "form.moonkin" },
      { name: "stealthed", cond: "stealthed.all" },
      { name: "pet alive", cond: "pet.alive" },
      { name: "variable", cond: "variable.hold_cds" },
      { name: "health pct", cond: "health.pct<50" },
      { name: "player health", cond: "player.health.pct<30" },
      { name: "power deficit", cond: "power.deficit>30" },
      { name: "power pct", cond: "power.pct>50" },
      { name: "power max", cond: "power.max" },
      { name: "active dot", cond: "active_dot.test>=3" },
      { name: "totem active", cond: "totem.test.active" },
      { name: "AND operator", cond: "buff.a.up&cooldown.b.ready" },
      { name: "OR operator", cond: "buff.a.up|buff.b.up" },
      { name: "NOT operator", cond: "!buff.a.up" },
      { name: "NOT EQUAL", cond: "variable.test!=0" },
      { name: "complex multi-op", cond: "buff.a.up&(buff.b.up|buff.c.up)&!cooldown.d.ready" },
      { name: "min operator", cond: "cooldown.test.remains>?30" },
      { name: "max operator", cond: "spell_targets<?1" },
      { name: "set bonus (false)", cond: "set_bonus.tier31_2pc" },
      { name: "equipped (false)", cond: "equipped.some_trinket" },
      { name: "raid event", cond: "raid_event.adds.in>30" },
      { name: "target distance", cond: "target.distance<8" },
      { name: "minutes suffix", cond: "fight_remains>2m" },
      { name: "milliseconds suffix", cond: "gcd.remains<500ms" },
    ];

    for (const { name, cond } of conditions) {
      it(`"${name}" (${cond || "(empty)"}) produces valid Lua`, () => {
        const lua = conditionToLua(cond);
        const wrapped = wrapConditionAsLua(lua);
        const result = luacParse(wrapped, `cond_${name.replace(/\s+/g, "_")}.lua`);
        if (!result.valid) {
          console.error(`Condition "${cond}" → "${lua}" failed:`, result.error);
        }
        expect(result.valid).toBe(true);
      });
    }
  });

  describe("Complex real-world conditions produce valid Lua", () => {
    const realConditions = [
      "buff.avenging_wrath.up&holy_power>=3",
      "buff.hot_streak.up&!prev_gcd.1.pyroblast&cooldown.combustion.remains>?30",
      "target.debuff.festering_wound.stack>=4&cooldown.apocalypse.ready&!buff.dark_transformation.up",
      "eclipse.in_eclipse&astral_power>=50&buff.starweaver.up",
      "chi>=3&active_enemies>=3&buff.serenity.down",
      "dot.garrote.refreshable&energy>=45&combo_points<4",
      "buff.maelstrom_weapon.stack>=5&!buff.primordial_wave.up",
      "holy_power>=5|(holy_power>=3&buff.avenging_wrath.up)",
      "cooldown.blade_of_justice.ready&holy_power<=3",
      "(target.health.pct<=20|buff.avenging_wrath.up)&holy_power<5",
      "cooldown.judgment.ready&holy_power<5&(debuff.judgment.down|debuff.judgment.remains<3)",
      "buff.bone_shield.stack<5&rune>=3",
      "runic_power>=80&buff.pillar_of_frost.up",
      "focus>=30&buff.bestial_wrath.up&pet.alive",
      "soul_shards>=3&(buff.dark_soul.up|cooldown.dark_soul.remains>30)",
      "insanity>=60&buff.voidform.up&target.time_to_die>15",
      "active_enemies>=3&cooldown.bladestorm.ready&rage>=30",
      "buff.bloodlust.up|buff.heroism.up|buff.time_warp.up",
    ];

    for (const cond of realConditions) {
      it(`"${cond}" → valid Lua`, () => {
        const lua = conditionToLua(cond);
        const wrapped = wrapConditionAsLua(lua);
        const result = luacParse(wrapped, `real_${cond.slice(0, 30).replace(/[^a-z0-9]/gi, "_")}.lua`);
        if (!result.valid) {
          console.error(`Condition: "${cond}"\nTranspiled: "${lua}"\nError: ${result.error}`);
        }
        expect(result.valid).toBe(true);
      });
    }
  });

  describe("Config with special character spell names produces valid Lua", () => {
    const specialNames = [
      "Templar's Verdict",
      "Power Word: Fortitude",
      "Invoke Chi-Ji, the Red Crane",
      "Kil'jaeden's Burning Wish",
      "Shadow Word: Death",
      "Hand of A'dal",
      "Death's Advance",
      "Nature's Vigil",
      "Warrior's Charge",
    ];

    for (const name of specialNames) {
      it(`spell "${name}" in Config.lua parses correctly`, () => {
        const data = makeAddonData({
          aplEntries: [
            makeAplEntry({ id: "sp1", spellName: name, condition: "", keybind: "1" }),
          ],
        });
        const config = generateConfig(data);
        const result = luacParse(config, `special_${name.replace(/[^a-z0-9]/gi, "_")}.lua`);
        if (!result.valid) {
          console.error(`Spell "${name}" caused parse error:`, result.error);
        }
        expect(result.valid).toBe(true);
      });
    }
  });

  describe("Edge case configs produce valid Lua", () => {
    it("empty APL entries", () => {
      const data = makeAddonData({ aplEntries: [] });
      const result = luacParse(generateConfig(data), "empty_apl.lua");
      expect(result.valid).toBe(true);
    });

    it("all entries disabled", () => {
      const data = makeAddonData({
        aplEntries: [
          makeAplEntry({ id: "d1", spellName: "X", enabled: false }),
          makeAplEntry({ id: "d2", spellName: "Y", enabled: false }),
        ],
      });
      const result = luacParse(generateConfig(data), "disabled_apl.lua");
      expect(result.valid).toBe(true);
    });

    it("50 APL entries", () => {
      const entries = Array.from({ length: 50 }, (_, i) =>
        makeAplEntry({
          id: `mass-${i}`,
          spellName: `Spell Number ${i}`,
          priority: i + 1,
          condition: i % 3 === 0 ? `buff.buff_${i}.up` : i % 3 === 1 ? `cooldown.cd_${i}.ready` : "",
          keybind: String(i % 10),
        })
      );
      const data = makeAddonData({ aplEntries: entries });
      const result = luacParse(generateConfig(data), "many_entries.lua");
      expect(result.valid).toBe(true);
    });

    it("precombat + interrupt + defensive + rotation entries combined", () => {
      const data = makeAddonData({
        aplEntries: [
          makeAplEntry({ id: "pre1", spellName: "Devotion Aura", condition: "!buff.devotion_aura.up", isPrecombat: true, precombatType: "state", priority: -110 }),
          makeAplEntry({ id: "op1", spellName: "Avenging Wrath", condition: "", isPrecombat: true, precombatType: "opener", priority: -50, isCooldown: true }),
          makeAplEntry({ id: "int1", spellName: "Rebuke", condition: "", isInterrupt: true, priority: 0 }),
          makeAplEntry({ id: "def1", spellName: "Divine Shield", condition: "health.pct<20", priority: 1 }),
          makeAplEntry({ id: "def2", spellName: "Word of Glory", condition: "health.pct<50", priority: 2 }),
          makeAplEntry({ id: "rot1", spellName: "Crusader Strike", condition: "", priority: 5 }),
          makeAplEntry({ id: "rot2", spellName: "Final Verdict", condition: "holy_power>=3", priority: 3 }),
        ],
      });
      const result = luacParse(generateConfig(data), "mixed_entry_types.lua");
      if (!result.valid) console.error("Mixed entries parse error:", result.error);
      expect(result.valid).toBe(true);
    });

    it("config with combat alerts", () => {
      const data = makeAddonData({
        alerts: [
          { id: "a1", specId: "paladin-ret", alertName: "Boss Cast", source: "DBM" as const, spellId: "12345", interruptSpell: "Rebuke", priority: "Critical" as const, enabled: true },
          { id: "a2", specId: "paladin-ret", alertName: "Big Damage", source: "BigWigs" as const, spellId: "67890", interruptSpell: "Rebuke", priority: "High" as const, enabled: true },
        ],
      });
      const result = luacParse(generateConfig(data), "with_alerts.lua");
      expect(result.valid).toBe(true);
    });
  });

  describe("Multi-spec AllSpecsConfig produces valid Lua", () => {
    it("two specs combined parse correctly", () => {
      const allData = {
        specs: [
          makeAddonData(),
          makeAddonData({
            spec: makeSpec({ id: "mage-frost", className: "Mage", specName: "Frost", classColor: "#69CCF0" }),
            aplEntries: [
              makeAplEntry({ id: "m1", specId: "mage-frost", spellName: "Frostbolt", condition: "!buff.brain_freeze.up", keybind: "1" }),
              makeAplEntry({ id: "m2", specId: "mage-frost", spellName: "Ice Lance", condition: "buff.fingers_of_frost.up|buff.brain_freeze.up", keybind: "2" }),
            ],
            hudConfig: makeHudConfig({ id: "hud-mage", specId: "mage-frost" }),
          }),
        ],
      };
      const config = generateAllSpecsConfig(allData);
      const result = luacParse(config, "all_specs_config.lua");
      if (!result.valid) console.error("AllSpecsConfig parse error:", result.error);
      expect(result.valid).toBe(true);
    });
  });
});

describe("String Escape Injection Tests", () => {
  function testEscape(desc: string, spellName: string) {
    it(`spell "${desc}" does not break Lua strings`, () => {
      const data = makeAddonData({
        aplEntries: [makeAplEntry({ id: "esc1", spellName, condition: "", keybind: "1" })],
      });
      const config = generateConfig(data);
      const result = luacParse(config, `escape_${desc.replace(/[^a-z0-9]/gi, "_")}.lua`);
      if (!result.valid) console.error(`Escape test "${desc}" failed:`, result.error);
      expect(result.valid).toBe(true);
    });
  }

  testEscape("single quote", "Death's Advance");
  testEscape("double quote", 'So-called "Heal"');
  testEscape("backslash", "Back\\slash");
  testEscape("newline literal", "Spell\nBreak");
  testEscape("tab", "Spell\tTab");
  testEscape("colon", "Power Word: Shield");
  testEscape("comma", "Invoke Chi-Ji, the Red Crane");
  testEscape("parentheses", "Spell (Rank 2)");
  testEscape("brackets", "Spell [Upgraded]");
  testEscape("curly braces", "Spell {Special}");
  testEscape("percent", "100% Damage");
  testEscape("ampersand", "Fire & Ice");
  testEscape("less than", "Damage <5");
  testEscape("greater than", "Damage >10");
  testEscape("equals", "Spell = True");
  testEscape("exclamation", "Spell!");
  testEscape("unicode dash", "Spell—Enhanced");
  testEscape("empty string", "");
  testEscape("only spaces", "   ");

  it("keybind with backslash does not break Lua", () => {
    const data = makeAddonData({
      aplEntries: [makeAplEntry({ id: "kb1", spellName: "Test", keybind: "CTRL\\1", condition: "" })],
    });
    const config = generateConfig(data);
    const result = luacParse(config, "keybind_backslash.lua");
    expect(result.valid).toBe(true);
  });

  it("keybind with double quote does not break Lua", () => {
    const data = makeAddonData({
      aplEntries: [makeAplEntry({ id: "kb2", spellName: "Test", keybind: 'KEY"X', condition: "" })],
    });
    const config = generateConfig(data);
    const result = luacParse(config, "keybind_quote.lua");
    expect(result.valid).toBe(true);
  });

  it("alert name with special characters", () => {
    const data = makeAddonData({
      alerts: [{
        id: "a1", specId: "paladin-ret",
        alertName: "Boss's \"Special\" Ability",
        source: "DBM" as const, spellId: "999",
        interruptSpell: "Rebuke", priority: "Critical" as const, enabled: true,
      }],
    });
    const config = generateConfig(data);
    const result = luacParse(config, "alert_special_chars.lua");
    expect(result.valid).toBe(true);
  });

  it("spec name with special characters in config", () => {
    const data = makeAddonData({
      spec: makeSpec({ specName: "Beast Master's", className: "Hunter" }),
    });
    const config = generateConfig(data);
    const result = luacParse(config, "spec_special_name.lua");
    expect(result.valid).toBe(true);
  });
});

describe("Deterministic Output (Snapshot Stability)", () => {
  it("same input produces identical Config.lua output", () => {
    const data = makeAddonData();
    const config1 = generateConfig(data);
    const config2 = generateConfig(data);
    const lines1 = config1.split("\n").filter(l => !l.includes("Generated:"));
    const lines2 = config2.split("\n").filter(l => !l.includes("Generated:"));
    expect(lines1).toEqual(lines2);
  });

  it("same input produces identical Helpers.lua output", () => {
    const data = makeAddonData();
    const h1 = generateHelpers(data);
    const h2 = generateHelpers(data);
    expect(h1).toBe(h2);
  });

  it("same input produces identical Engine.lua output", () => {
    const data = makeAddonData();
    const e1 = generateEngine(data);
    const e2 = generateEngine(data);
    expect(e1).toBe(e2);
  });

  it("Settings.lua is always identical (no input)", () => {
    const s1 = generateSettingsPanel();
    const s2 = generateSettingsPanel();
    expect(s1).toBe(s2);
  });
});

describe("TOC File Format Validation", () => {
  it("every ## line has correct format", () => {
    const data = makeAddonData();
    const toc = generateToc(data);
    const lines = toc.split("\n").filter(l => l.startsWith("##"));
    for (const line of lines) {
      expect(line).toMatch(/^## \w+:?\s*.+$/);
    }
  });

  it("file list contains only .lua and .xml files", () => {
    const data = makeAddonData();
    const toc = generateToc(data);
    const lines = toc.split("\n").filter(l => !l.startsWith("##") && !l.startsWith("#") && l.trim().length > 0);
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed.length > 0) {
        expect(trimmed).toMatch(/\.(lua|xml)$/);
      }
    }
  });

  it("Helpers.lua loads before Engine.lua and Core.lua", () => {
    const data = makeAddonData();
    const toc = generateToc(data);
    const fileLines = toc.split("\n").filter(l => l.trim().endsWith(".lua"));
    const helpersIdx = fileLines.findIndex(l => l.includes("Helpers.lua"));
    const engineIdx = fileLines.findIndex(l => l.includes("Engine.lua"));
    const coreIdx = fileLines.findIndex(l => l.includes("Core.lua"));
    expect(helpersIdx).toBeLessThan(engineIdx);
    expect(helpersIdx).toBeLessThan(coreIdx);
  });

  it("multi-spec TOC contains correct spec count", () => {
    const allData = {
      specs: [makeAddonData(), makeAddonData(), makeAddonData()],
    };
    const toc = generateAllSpecsToc(allData);
    expect(toc).toContain("3 specs");
  });
});
