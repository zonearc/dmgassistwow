import { describe, it, expect, beforeAll } from "vitest";
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
  generateBindingsXml,
  generateBindingNames,
} from "../server/addon-generator";

const LUA_KEYWORDS = new Set([
  "and", "break", "do", "else", "elseif", "end", "false", "for",
  "function", "goto", "if", "in", "local", "nil", "not", "or",
  "repeat", "return", "then", "true", "until", "while",
]);

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
    id: "hud-paladin-ret",
    specId: "paladin-ret",
    scale: 1,
    opacity: 0.9,
    positionX: 0,
    positionY: -200,
    iconSize: 48,
    predIconSize: 32,
    queueSlots: 3,
    showKeybind: true,
    keybindFontSize: 14,
    keybindPosition: "bottom-right" as const,
    showSpellName: true,
    spellNameFontSize: 10,
    showCondition: false,
    showResourceBar: true,
    showHeader: true,
    resourceCapThreshold: 80,
    aoeThreshold: 3,
    showPrediction: true,
    predictionOpacity: 0.4,
    framePadding: 12,
    iconSpacing: 6,
    lockPosition: false,
    debugMode: false,
    showCooldownText: true,
    showGcdSpark: true,
    outOfCombatMode: false,
    formAwareness: false,
    keybindBarPriority: ["Action Button", "MultiBarBottomLeft"],
    keybindOverrides: {},
    interruptSound: true,
    interruptSoundId: 8959,
    potionEnabled: false,
    potionItemName: "",
    consumablesEnabled: true,
    flaskEnabled: true,
    flaskItemName: "",
    foodEnabled: true,
    foodItemName: "",
    weaponEnhEnabled: true,
    weaponEnhItemName: "",
    augmentRuneEnabled: true,
    augmentRuneItemName: "",
    ...overrides,
  };
}

function makeAplEntry(overrides: Record<string, any> = {}) {
  return {
    id: "test-apl-1",
    specId: "paladin-ret",
    priority: 5,
    spellName: "Final Verdict",
    spellIcon: "spell_paladin_templarsverdict",
    condition: "holy_power>=3",
    mode: "ST" as const,
    isInterrupt: false,
    isOffensive: false,
    isCooldown: false,
    enabled: true,
    keybind: "1",
    isPrecombat: false,
    precombatType: null as string | null,
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

function countChar(s: string, ch: string): number {
  let count = 0;
  for (let i = 0; i < s.length; i++) {
    if (s[i] === ch) count++;
  }
  return count;
}

function checkLuaStringBalance(lua: string, context: string) {
  let depth = 0;
  let inString = false;
  let stringChar = "";
  let inLongString = false;
  let longStringLevel = 0;

  for (let i = 0; i < lua.length; i++) {
    const ch = lua[i];

    if (inLongString) {
      if (ch === "]") {
        let eqCount = 0;
        let j = i + 1;
        while (j < lua.length && lua[j] === "=") { eqCount++; j++; }
        if (j < lua.length && lua[j] === "]" && eqCount === longStringLevel) {
          inLongString = false;
          i = j;
        }
      }
      continue;
    }

    if (inString) {
      if (ch === "\\" && i + 1 < lua.length) {
        i++;
        continue;
      }
      if (ch === stringChar) {
        inString = false;
      }
      continue;
    }

    if (ch === "-" && i + 1 < lua.length && lua[i + 1] === "-") {
      if (i + 2 < lua.length && lua[i + 2] === "[") {
        let eqCount = 0;
        let j = i + 3;
        while (j < lua.length && lua[j] === "=") { eqCount++; j++; }
        if (j < lua.length && lua[j] === "[") {
          inLongString = true;
          longStringLevel = eqCount;
          i = j;
          continue;
        }
      }
      const eol = lua.indexOf("\n", i);
      if (eol === -1) break;
      i = eol;
      continue;
    }

    if (ch === "[") {
      let eqCount = 0;
      let j = i + 1;
      while (j < lua.length && lua[j] === "=") { eqCount++; j++; }
      if (j < lua.length && lua[j] === "[") {
        inLongString = true;
        longStringLevel = eqCount;
        i = j;
        continue;
      }
    }

    if (ch === '"' || ch === "'") {
      inString = true;
      stringChar = ch;
      continue;
    }
  }

  return { inString, inLongString };
}

function checkBalancedParens(lua: string): { parens: number; brackets: number; braces: number } {
  let parens = 0, brackets = 0, braces = 0;
  let inString = false;
  let stringChar = "";
  let inComment = false;
  let inLongString = false;

  for (let i = 0; i < lua.length; i++) {
    const ch = lua[i];

    if (ch === "\n") { inComment = false; continue; }
    if (inComment) continue;

    if (inString) {
      if (ch === "\\" && i + 1 < lua.length) { i++; continue; }
      if (ch === stringChar) inString = false;
      continue;
    }

    if (ch === "-" && i + 1 < lua.length && lua[i + 1] === "-") {
      inComment = true;
      continue;
    }

    if (ch === '"' || ch === "'") {
      inString = true;
      stringChar = ch;
      continue;
    }

    if (ch === "(") parens++;
    else if (ch === ")") parens--;
    else if (ch === "{") braces++;
    else if (ch === "}") braces--;
  }

  return { parens, brackets, braces };
}

function checkEndBalance(lua: string): { blockOpens: number; ends: number } {
  const lines = lua.split("\n");
  let blockOpens = 0;
  let ends = 0;

  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.startsWith("--")) continue;

    const blockOpenMatches = trimmed.match(/\b(function|if|for|while|repeat|do)\b/g);
    if (blockOpenMatches) {
      for (const m of blockOpenMatches) {
        if (m === "function" && trimmed.includes("end)")) continue;
        if (m === "function" && /function\s*\(/.test(trimmed) && trimmed.includes("end")) continue;
        blockOpens++;
      }
    }

    if (/\bend\b/.test(trimmed) && !trimmed.startsWith("--")) {
      const endMatches = trimmed.match(/\bend\b/g);
      if (endMatches) ends += endMatches.length;
    }
  }

  return { blockOpens, ends };
}

describe("Lua Syntax Validation — Full File Generation", () => {
  let addonData: ReturnType<typeof makeAddonData>;

  beforeAll(() => {
    addonData = makeAddonData();
  });

  describe("TOC File", () => {
    it("produces valid TOC metadata", () => {
      const toc = generateToc(addonData);
      expect(toc).toContain("## Interface:");
      expect(toc).toContain("## Title:");
      expect(toc).toContain("## Version:");
      expect(toc).toContain("## SavedVariables:");
      expect(toc).toContain("120001");
    });

    it("contains required file load order", () => {
      const toc = generateToc(addonData);
      expect(toc).toContain("Helpers.lua");
      expect(toc).toContain("Engine.lua");
      expect(toc).toContain("HUD.lua");
      expect(toc).toContain("Core.lua");
      expect(toc).toContain("Settings.lua");
      expect(toc).toContain("Config.lua");
    });

    it("does not contain empty lines at start", () => {
      const toc = generateToc(addonData);
      expect(toc.startsWith("##")).toBe(true);
    });
  });

  describe("LibStub", () => {
    it("produces non-empty output", () => {
      const libStub = generateLibStub();
      expect(libStub.length).toBeGreaterThan(50);
    });

    it("has balanced parentheses", () => {
      const libStub = generateLibStub();
      const balance = checkBalancedParens(libStub);
      expect(balance.parens).toBe(0);
      expect(balance.braces).toBe(0);
    });
  });

  describe("Config.lua", () => {
    it("produces non-empty config output", () => {
      const config = generateConfig(addonData);
      expect(config.length).toBeGreaterThan(100);
    });

    it("contains CLF_DefaultConfig table", () => {
      const config = generateConfig(addonData);
      expect(config).toContain("CLF_DefaultConfig");
    });

    it("contains all spell names from APL entries", () => {
      const config = generateConfig(addonData);
      for (const entry of addonData.aplEntries) {
        expect(config).toContain(entry.spellName);
      }
    });

    it("has balanced braces (table construction)", () => {
      const config = generateConfig(addonData);
      const balance = checkBalancedParens(config);
      expect(balance.braces).toBe(0);
    });

    it("has balanced parentheses", () => {
      const config = generateConfig(addonData);
      const balance = checkBalancedParens(config);
      expect(balance.parens).toBe(0);
    });

    it("transpiled conditions appear in config", () => {
      const config = generateConfig(addonData);
      expect(config).toContain("CLF.CooldownReady");
      expect(config).toContain("CLF.Power()");
    });
  });

  describe("Helpers.lua", () => {
    let helpers: string;

    beforeAll(() => {
      helpers = generateHelpers(addonData);
    });

    it("produces substantial output", () => {
      expect(helpers.length).toBeGreaterThan(1000);
    });

    it("contains Detaint function with issecretvalue", () => {
      expect(helpers).toContain("function Detaint(val");
      expect(helpers).toContain("issecretvalue");
    });

    it("has balanced parentheses", () => {
      const balance = checkBalancedParens(helpers);
      expect(balance.parens).toBe(0);
    });

    it("has balanced braces", () => {
      const balance = checkBalancedParens(helpers);
      expect(balance.braces).toBe(0);
    });

    it("does not have unclosed strings", () => {
      const result = checkLuaStringBalance(helpers, "Helpers.lua");
      expect(result.inString).toBe(false);
      expect(result.inLongString).toBe(false);
    });

    it("contains CLF namespace usage", () => {
      expect(helpers).toContain("CLF.");
    });

    it("contains runtime API functions", () => {
      expect(helpers).toContain("CLF.BuffUp");
      expect(helpers).toContain("CLF.DebuffUp");
      expect(helpers).toContain("CLF.CooldownReady");
      expect(helpers).toContain("CLF.Power");
    });
  });

  describe("Engine.lua", () => {
    let engine: string;

    beforeAll(() => {
      engine = generateEngine(addonData);
    });

    it("produces substantial output", () => {
      expect(engine.length).toBeGreaterThan(1000);
    });

    it("has balanced parentheses", () => {
      const balance = checkBalancedParens(engine);
      expect(balance.parens).toBe(0);
    });

    it("has balanced braces", () => {
      const balance = checkBalancedParens(engine);
      expect(balance.braces).toBe(0);
    });

    it("does not have unclosed strings", () => {
      const result = checkLuaStringBalance(engine, "Engine.lua");
      expect(result.inString).toBe(false);
      expect(result.inLongString).toBe(false);
    });

    it("contains signal constants", () => {
      expect(engine).toContain("SIGNAL_ANTS");
      expect(engine).toContain("SIGNAL_ASSISTED");
      expect(engine).toContain("SIGNAL_PROC");
    });

    it("contains EvaluateAPL function", () => {
      expect(engine).toContain("EvaluateAPL");
    });

    it("contains ScanActionBars function", () => {
      expect(engine).toContain("ScanActionBars");
    });

    it("contains Detaint function with issecretvalue", () => {
      expect(engine).toContain("function Detaint(val)");
      expect(engine).toContain("issecretvalue");
    });
  });

  describe("HUD.lua", () => {
    let hud: string;

    beforeAll(() => {
      hud = generateHud(addonData);
    });

    it("produces substantial output", () => {
      expect(hud.length).toBeGreaterThan(1000);
    });

    it("has balanced parentheses", () => {
      const balance = checkBalancedParens(hud);
      expect(balance.parens).toBe(0);
    });

    it("has balanced braces", () => {
      const balance = checkBalancedParens(hud);
      expect(balance.braces).toBe(0);
    });

    it("does not have unclosed strings", () => {
      const result = checkLuaStringBalance(hud, "HUD.lua");
      expect(result.inString).toBe(false);
      expect(result.inLongString).toBe(false);
    });

    it("contains class color from spec data", () => {
      const r = parseInt("F4", 16) / 255;
      expect(hud).toContain(r.toFixed(3).toString().substring(0, 4));
    });

    it("contains CreateFrame usage", () => {
      expect(hud).toContain("CreateFrame");
    });

    it("uses icon sizing from HUD config", () => {
      expect(hud).toContain("48");
    });
  });

  describe("Core.lua", () => {
    let core: string;

    beforeAll(() => {
      core = generateCore(addonData);
    });

    it("produces substantial output", () => {
      expect(core.length).toBeGreaterThan(1000);
    });

    it("has balanced parentheses", () => {
      const balance = checkBalancedParens(core);
      expect(balance.parens).toBe(0);
    });

    it("has balanced braces", () => {
      const balance = checkBalancedParens(core);
      expect(balance.braces).toBe(0);
    });

    it("does not have unclosed strings", () => {
      const result = checkLuaStringBalance(core, "Core.lua");
      expect(result.inString).toBe(false);
      expect(result.inLongString).toBe(false);
    });

    it("contains event registration", () => {
      expect(core).toContain("RegisterEvent");
    });

    it("contains ADDON_LOADED handler", () => {
      expect(core).toContain("ADDON_LOADED");
    });

    it("contains combat event handling", () => {
      expect(core).toContain("PLAYER_REGEN_DISABLED");
      expect(core).toContain("PLAYER_REGEN_ENABLED");
    });

    it("contains Detaint function with issecretvalue", () => {
      expect(core).toContain("function Detaint(val)");
      expect(core).toContain("issecretvalue");
    });

    it("always sets CLF_DefaultConfig at end of OnAddonLoaded", () => {
      expect(core).toContain("CLF_DefaultConfig = DeepCopyTable(CLF_Config)");
    });

    it("PEW handler sets CLF_DefaultConfig via deep copy on successful detection", () => {
      const pewBlock = core.substring(
        core.indexOf('event == "PLAYER_ENTERING_WORLD"'),
        core.indexOf("CLF.ScanEquippedTrinkets")
      );
      expect(pewBlock).toContain("CLF_DefaultConfig = DeepCopyTable(detected)");
      const defaultConfigIdx = pewBlock.indexOf("CLF_DefaultConfig = DeepCopyTable(detected)");
      const specCheckIdx = pewBlock.indexOf("CLF_Config._specId ~= specId");
      expect(defaultConfigIdx).toBeLessThan(specCheckIdx);
    });

    it("refreshes APL from CLF_AllSpecs for SavedVariables case", () => {
      expect(core).toContain('CLF_Config.spec.id ~= "unknown"');
      expect(core).toContain("local fresh = CLF_AllSpecs[CLF_Config.spec.id]");
      expect(core).toContain("CLF_Config.apl = DeepCopyTable(fresh.apl)");
    });
  });

  describe("Settings.lua", () => {
    let settings: string;

    beforeAll(() => {
      settings = generateSettingsPanel();
    });

    it("produces substantial output", () => {
      expect(settings.length).toBeGreaterThan(1000);
    });

    it("has balanced parentheses", () => {
      const balance = checkBalancedParens(settings);
      expect(balance.parens).toBe(0);
    });

    it("has balanced braces", () => {
      const balance = checkBalancedParens(settings);
      expect(balance.braces).toBe(0);
    });

    it("does not have unclosed strings", () => {
      const result = checkLuaStringBalance(settings, "Settings.lua");
      expect(result.inString).toBe(false);
      expect(result.inLongString).toBe(false);
    });

    it("contains settings panel creation", () => {
      expect(settings).toContain("CreateFrame");
    });

    it("contains Detaint function with issecretvalue", () => {
      expect(settings).toContain("function Detaint(val)");
      expect(settings).toContain("issecretvalue");
    });
  });
});

describe("Multi-Spec Generation", () => {
  it("generates valid AllSpecs TOC", () => {
    const allData = {
      specs: [
        makeAddonData(),
        makeAddonData({
          spec: makeSpec({ id: "mage-frost", className: "Mage", specName: "Frost", classColor: "#69CCF0" }),
          aplEntries: [
            makeAplEntry({ id: "m1", specId: "mage-frost", spellName: "Frostbolt", condition: "", keybind: "1" }),
          ],
          hudConfig: makeHudConfig({ id: "hud-mage-frost", specId: "mage-frost" }),
        }),
      ],
    };

    const toc = generateAllSpecsToc(allData);
    expect(toc).toContain("## Interface:");
    expect(toc).toContain("2 specs");
  });

  it("generates valid AllSpecs Config with spec lookup", () => {
    const allData = {
      specs: [
        makeAddonData(),
        makeAddonData({
          spec: makeSpec({ id: "mage-frost", className: "Mage", specName: "Frost", classColor: "#69CCF0" }),
          aplEntries: [
            makeAplEntry({ id: "m1", specId: "mage-frost", spellName: "Frostbolt", condition: "", keybind: "1" }),
          ],
          hudConfig: makeHudConfig({ id: "hud-mage-frost", specId: "mage-frost" }),
        }),
      ],
    };

    const config = generateAllSpecsConfig(allData);
    expect(config).toContain("CLF_AllSpecs");
    expect(config).toContain("CLF_SpecLookup");
    expect(config).toContain("CLF_DetectSpec");
    expect(config).toContain("paladin-ret");
    expect(config).toContain("mage-frost");

    const balance = checkBalancedParens(config);
    expect(balance.parens).toBe(0);
    expect(balance.braces).toBe(0);
  });
});

describe("String Injection Safety — Spell Names", () => {
  it("handles spell names with apostrophes (Templar's Verdict)", () => {
    const data = makeAddonData({
      aplEntries: [
        makeAplEntry({ id: "s1", spellName: "Templar's Verdict", condition: "", keybind: "1" }),
      ],
    });
    const config = generateConfig(data);
    expect(config).toBeDefined();
    const balance = checkBalancedParens(config);
    expect(balance.parens).toBe(0);
    expect(balance.braces).toBe(0);
  });

  it("handles spell names with colons (Power Word: Fortitude)", () => {
    const data = makeAddonData({
      spec: makeSpec({ id: "priest-disc", className: "Priest", specName: "Discipline", classColor: "#FFFFFF" }),
      aplEntries: [
        makeAplEntry({ id: "s1", specId: "priest-disc", spellName: "Power Word: Fortitude", condition: "", keybind: "1" }),
      ],
    });
    const config = generateConfig(data);
    expect(config).toContain("Power Word: Fortitude");
    const balance = checkBalancedParens(config);
    expect(balance.parens).toBe(0);
  });

  it("handles spell names with hyphens (Chi-Ji)", () => {
    const data = makeAddonData({
      aplEntries: [
        makeAplEntry({ id: "s1", spellName: "Invoke Chi-Ji, the Red Crane", condition: "", keybind: "1" }),
      ],
    });
    const config = generateConfig(data);
    expect(config).toBeDefined();
    const balance = checkBalancedParens(config);
    expect(balance.parens).toBe(0);
  });

  it("handles spell names with special unicode (Kil'jaeden's Burning Wish)", () => {
    const data = makeAddonData({
      aplEntries: [
        makeAplEntry({ id: "s1", spellName: "Kil'jaeden's Burning Wish", condition: "", keybind: "1" }),
      ],
    });
    const config = generateConfig(data);
    expect(config).toBeDefined();
    const result = checkLuaStringBalance(config, "Config with special chars");
    expect(result.inString).toBe(false);
  });

  it("handles empty spell names gracefully", () => {
    const data = makeAddonData({
      aplEntries: [
        makeAplEntry({ id: "s1", spellName: "", condition: "", keybind: "1" }),
      ],
    });
    const config = generateConfig(data);
    expect(config).toBeDefined();
  });

  it("handles spell names that look like Lua keywords", () => {
    const data = makeAddonData({
      aplEntries: [
        makeAplEntry({ id: "s1", spellName: "End", condition: "", keybind: "1" }),
        makeAplEntry({ id: "s2", spellName: "Return", condition: "", keybind: "2" }),
      ],
    });
    const config = generateConfig(data);
    const balance = checkBalancedParens(config);
    expect(balance.parens).toBe(0);
    expect(balance.braces).toBe(0);
  });
});

describe("Edge Cases — Empty and Minimal Data", () => {
  it("generates valid config with empty APL entries", () => {
    const data = makeAddonData({ aplEntries: [] });
    const config = generateConfig(data);
    expect(config).toBeDefined();
    expect(config.length).toBeGreaterThan(0);
    const balance = checkBalancedParens(config);
    expect(balance.parens).toBe(0);
    expect(balance.braces).toBe(0);
  });

  it("generates valid engine with empty APL entries", () => {
    const data = makeAddonData({ aplEntries: [] });
    const engine = generateEngine(data);
    expect(engine).toBeDefined();
    const balance = checkBalancedParens(engine);
    expect(balance.parens).toBe(0);
  });

  it("generates valid config with disabled entries (all filtered)", () => {
    const data = makeAddonData({
      aplEntries: [
        makeAplEntry({ id: "d1", spellName: "Disabled Spell", enabled: false }),
        makeAplEntry({ id: "d2", spellName: "Also Disabled", enabled: false }),
      ],
    });
    const config = generateConfig(data);
    expect(config).toBeDefined();
    const balance = checkBalancedParens(config);
    expect(balance.parens).toBe(0);
    expect(balance.braces).toBe(0);
  });

  it("generates valid output with single APL entry", () => {
    const data = makeAddonData({
      aplEntries: [makeAplEntry({ id: "only-one", spellName: "Frostbolt", condition: "" })],
    });
    const config = generateConfig(data);
    expect(config).toContain("Frostbolt");
    const balance = checkBalancedParens(config);
    expect(balance.parens).toBe(0);
  });

  it("generates valid config with many APL entries", () => {
    const entries = Array.from({ length: 50 }, (_, i) =>
      makeAplEntry({
        id: `mass-${i}`,
        spellName: `Spell ${i}`,
        priority: i + 1,
        condition: i % 2 === 0 ? `buff.spell_${i}.up` : "",
        keybind: String(i % 10),
      })
    );
    const data = makeAddonData({ aplEntries: entries });
    const config = generateConfig(data);
    expect(config).toContain("Spell 0");
    expect(config).toContain("Spell 49");
    const balance = checkBalancedParens(config);
    expect(balance.parens).toBe(0);
    expect(balance.braces).toBe(0);
  });
});

describe("Condition Transpiler Edge Cases", () => {
  it("handles deeply nested parenthetical groups", () => {
    const result = conditionToLua("(buff.a.up|(buff.b.up&(buff.c.up|buff.d.up)))");
    expect(result).toContain('CLF.BuffUp("a")');
    expect(result).toContain('CLF.BuffUp("d")');
    const parens = checkBalancedParens(result);
    expect(parens.parens).toBe(0);
  });

  it("handles spell names with underscores", () => {
    const result = conditionToLua("buff.ice_lance.up&debuff.winters_chill.stack>=2");
    expect(result).toContain('CLF.BuffUp("ice_lance")');
    expect(result).toContain('CLF.DebuffStacks("winters_chill")');
  });

  it("handles chained OR conditions", () => {
    const result = conditionToLua("buff.a.up|buff.b.up|buff.c.up|buff.d.up|buff.e.up");
    const ors = (result.match(/ or /g) || []).length;
    expect(ors).toBe(4);
  });

  it("handles chained AND conditions", () => {
    const result = conditionToLua("buff.a.up&buff.b.up&buff.c.up&buff.d.up");
    const ands = (result.match(/ and /g) || []).length;
    expect(ands).toBe(3);
  });

  it("handles mixed AND/OR with correct precedence", () => {
    const result = conditionToLua("buff.a.up|buff.b.up&buff.c.up");
    expect(result).toContain(" or ");
    expect(result).toContain(" and ");
  });

  it("handles double negation", () => {
    const result = conditionToLua("!!buff.a.up");
    expect(result).toBeDefined();
  });

  it("handles condition with only numeric value", () => {
    const result = conditionToLua("1");
    expect(result).toBeDefined();
  });

  it("handles comparison to 0", () => {
    const result = conditionToLua("cooldown.test.remains>0");
    expect(result).toContain('CLF.CooldownRemains("test")');
    expect(result).toContain(">0");
  });

  it("handles comparison with decimal values", () => {
    const result = conditionToLua("cooldown.test.remains<1.5");
    expect(result).toContain("<1.5");
  });

  it("handles negative comparison values", () => {
    const result = conditionToLua("variable.test>-1");
    expect(result).toContain(">-1");
  });

  it("handles action.X.executing condition", () => {
    const result = conditionToLua("action.frostbolt.executing");
    expect(result).toBeDefined();
  });

  it("handles trinket conditions gracefully", () => {
    const result = conditionToLua("trinket.1.cooldown.remains");
    expect(result).toBeDefined();
  });

  it("handles cycle_targets", () => {
    const result = conditionToLua("cycle_targets");
    expect(result).toBeDefined();
  });

  it("produces valid Lua for every condition it encounters", () => {
    const conditions = [
      "buff.test.up",
      "debuff.test.remains>5",
      "cooldown.test.ready",
      "holy_power>=3",
      "target.health.pct<20",
      "talent.test.enabled",
      "!buff.test.up&cooldown.test.ready",
      "buff.test.stack>=5|buff.other.up",
      "active_enemies>=3",
      "fight_remains>30",
      "moving",
      "gcd.remains<0.5",
      "prev_gcd.1.test",
      "variable.hold_cds",
      "pet.alive",
      "form.moonkin",
      "stealthed.all",
      "dot.test.ticking",
      "dot.test.refreshable",
      "",
    ];

    for (const cond of conditions) {
      const result = conditionToLua(cond);
      expect(result).toBeDefined();
      expect(typeof result).toBe("string");
      expect(result.length).toBeGreaterThan(0);

      const parens = checkBalancedParens(result);
      expect(parens.parens).toBe(0);
    }
  });
});

describe("Keybind String Safety", () => {
  it("handles standard letter keybinds", () => {
    const data = makeAddonData({
      aplEntries: [makeAplEntry({ id: "k1", spellName: "Test", keybind: "Q" })],
    });
    const config = generateConfig(data);
    expect(config).toContain("Q");
  });

  it("handles number keybinds", () => {
    const data = makeAddonData({
      aplEntries: [makeAplEntry({ id: "k1", spellName: "Test", keybind: "1" })],
    });
    const config = generateConfig(data);
    expect(config).toContain('"1"');
  });

  it("handles modifier keybinds (Shift+1)", () => {
    const data = makeAddonData({
      aplEntries: [makeAplEntry({ id: "k1", spellName: "Test", keybind: "Shift+1" })],
    });
    const config = generateConfig(data);
    expect(config).toBeDefined();
  });

  it("handles empty keybind", () => {
    const data = makeAddonData({
      aplEntries: [makeAplEntry({ id: "k1", spellName: "Test", keybind: "" })],
    });
    const config = generateConfig(data);
    const balance = checkBalancedParens(config);
    expect(balance.parens).toBe(0);
  });
});

describe("Class Color Validation", () => {
  const classColors: Record<string, string> = {
    "Death Knight": "#C41E3A",
    Druid: "#FF7C0A",
    Hunter: "#AAD372",
    Mage: "#69CCF0",
    Paladin: "#F48CBA",
    Priest: "#FFFFFF",
    Rogue: "#FFF468",
    Shaman: "#0070DD",
    Warlock: "#9482C9",
    Warrior: "#C69B6D",
    "Demon Hunter": "#A330C9",
    Monk: "#00FF98",
    Evoker: "#33937F",
  };

  for (const [className, color] of Object.entries(classColors)) {
    it(`generates valid HUD for ${className} color ${color}`, () => {
      const data = makeAddonData({
        spec: makeSpec({ className, classColor: color }),
      });
      const hud = generateHud(data);
      expect(hud).toBeDefined();
      expect(hud.length).toBeGreaterThan(100);

      const r = parseInt(color.slice(1, 3), 16) / 255;
      const g = parseInt(color.slice(3, 5), 16) / 255;
      const b = parseInt(color.slice(5, 7), 16) / 255;
      expect(hud).toContain(r.toFixed(3).substring(0, 4));
    });
  }
});

describe("HUD Config Extreme Values", () => {
  it("handles minimum scale", () => {
    const data = makeAddonData({ hudConfig: makeHudConfig({ scale: 0.5 }) });
    const hud = generateHud(data);
    expect(hud).toBeDefined();
    const balance = checkBalancedParens(hud);
    expect(balance.parens).toBe(0);
  });

  it("handles maximum scale", () => {
    const data = makeAddonData({ hudConfig: makeHudConfig({ scale: 3 }) });
    const hud = generateHud(data);
    expect(hud).toBeDefined();
  });

  it("handles minimum icon size", () => {
    const data = makeAddonData({ hudConfig: makeHudConfig({ iconSize: 20 }) });
    const hud = generateHud(data);
    expect(hud).toBeDefined();
  });

  it("handles maximum queue slots", () => {
    const data = makeAddonData({ hudConfig: makeHudConfig({ queueSlots: 5 }) });
    const hud = generateHud(data);
    expect(hud).toBeDefined();
  });

  it("handles all boolean toggles off", () => {
    const data = makeAddonData({
      hudConfig: makeHudConfig({
        showKeybind: false,
        showSpellName: false,
        showCondition: false,
        showResourceBar: false,
        showHeader: false,
        showPrediction: false,
        lockPosition: true,
        debugMode: false,
        showCooldownText: false,
        showGcdSpark: false,
        outOfCombatMode: true,
        formAwareness: false,
        interruptSound: false,
        potionEnabled: false,
      }),
    });
    const config = generateConfig(data);
    expect(config).toBeDefined();
    const balance = checkBalancedParens(config);
    expect(balance.parens).toBe(0);
  });
});

describe("Precombat and Interrupt APL Entries", () => {
  it("generates valid config with precombat state entries", () => {
    const data = makeAddonData({
      aplEntries: [
        makeAplEntry({
          id: "pre1",
          spellName: "Devotion Aura",
          condition: "!buff.devotion_aura.up",
          isPrecombat: true,
          precombatType: "state",
          priority: -110,
        }),
        makeAplEntry({ id: "rot1", spellName: "Crusader Strike", condition: "", priority: 5 }),
      ],
    });
    const config = generateConfig(data);
    expect(config).toContain("Devotion Aura");
    const balance = checkBalancedParens(config);
    expect(balance.parens).toBe(0);
    expect(balance.braces).toBe(0);
  });

  it("generates valid config with precombat opener entries", () => {
    const data = makeAddonData({
      aplEntries: [
        makeAplEntry({
          id: "op1",
          spellName: "Avenging Wrath",
          condition: "",
          isPrecombat: true,
          precombatType: "opener",
          priority: -50,
        }),
        makeAplEntry({ id: "rot1", spellName: "Crusader Strike", condition: "", priority: 5 }),
      ],
    });
    const config = generateConfig(data);
    expect(config).toContain("Avenging Wrath");
    const balance = checkBalancedParens(config);
    expect(balance.parens).toBe(0);
  });

  it("generates valid config with interrupt entries", () => {
    const data = makeAddonData({
      aplEntries: [
        makeAplEntry({
          id: "int1",
          spellName: "Rebuke",
          condition: "",
          isInterrupt: true,
          priority: 0,
        }),
        makeAplEntry({ id: "rot1", spellName: "Crusader Strike", condition: "", priority: 5 }),
      ],
    });
    const config = generateConfig(data);
    expect(config).toContain("Rebuke");
    const balance = checkBalancedParens(config);
    expect(balance.parens).toBe(0);
  });

  it("generates valid config with mixed offensive entries", () => {
    const data = makeAddonData({
      aplEntries: [
        makeAplEntry({
          id: "off1",
          spellName: "Divine Shield",
          condition: "health.pct<20",
          priority: 1,
        }),
        makeAplEntry({
          id: "off2",
          spellName: "Word of Glory",
          condition: "health.pct<50",
          priority: 2,
        }),
        makeAplEntry({ id: "rot1", spellName: "Crusader Strike", condition: "", priority: 5 }),
      ],
    });
    const config = generateConfig(data);
    expect(config).toContain("Divine Shield");
    expect(config).toContain("Word of Glory");
    const balance = checkBalancedParens(config);
    expect(balance.parens).toBe(0);
  });
});

describe("Combat Alert Entries", () => {
  it("generates valid config with combat alerts", () => {
    const data = makeAddonData({
      alerts: [
        {
          id: "alert1",
          specId: "paladin-ret",
          alertName: "Boss Cast",
          source: "DBM" as const,
          spellId: "12345",
          interruptSpell: "Rebuke",
          priority: "Critical" as const,
          enabled: true,
        },
      ],
    });
    const config = generateConfig(data);
    expect(config).toBeDefined();
    const balance = checkBalancedParens(config);
    expect(balance.parens).toBe(0);
    expect(balance.braces).toBe(0);
  });

  it("handles multiple alert sources", () => {
    const data = makeAddonData({
      alerts: [
        {
          id: "a1", specId: "paladin-ret", alertName: "DBM Boss",
          source: "DBM" as const, spellId: "111", interruptSpell: "Rebuke",
          priority: "Critical" as const, enabled: true,
        },
        {
          id: "a2", specId: "paladin-ret", alertName: "BW Timer",
          source: "BigWigs" as const, spellId: "222", interruptSpell: "Rebuke",
          priority: "High" as const, enabled: true,
        },
      ],
    });
    const config = generateConfig(data);
    expect(config).toBeDefined();
  });
});

describe("Cross-File Consistency", () => {
  it("all files reference same addon namespace (CLF)", () => {
    const data = makeAddonData();
    const files = [
      generateHelpers(data),
      generateEngine(data),
      generateHud(data),
      generateCore(data),
      generateSettingsPanel(),
    ];
    for (const file of files) {
      expect(file).toContain("CLF");
    }
  });

  it("all files with Detaint use the same pattern", () => {
    const data = makeAddonData();
    const files = {
      helpers: generateHelpers(data),
      engine: generateEngine(data),
      core: generateCore(data),
      settings: generateSettingsPanel(),
    };
    for (const [name, content] of Object.entries(files)) {
      if (content.includes("function Detaint")) {
        expect(content).toContain("issecretvalue");
        expect(content).toContain("tonumber(val)");
        expect(content).toContain('type(val) == "nil"');
      }
    }
  });

  it("no file uses banned tonumber() on API returns directly", () => {
    const data = makeAddonData();
    const files = [
      generateHelpers(data),
      generateEngine(data),
      generateHud(data),
      generateCore(data),
    ];
    for (const file of files) {
      const lines = file.split("\n");
      for (const line of lines) {
        if (line.trim().startsWith("--")) continue;
        if (line.includes("tonumber(") && !line.includes("Detaint") && !line.includes("function Detaint")) {
          const hasDetaintNearby = line.includes("Detaint(") || line.includes("tonumber(val)");
          if (!hasDetaintNearby) {
            const isInDetaintFunc = line.includes("return tonumber(val)");
            const isSafeContext = line.includes("tonumber(msg") || line.includes("tonumber(input") ||
                                  line.includes("tonumber(str") || line.includes("tonumber(v)") ||
                                  line.includes("tonumber(text") || line.includes("tonumber(value") ||
                                  line.includes("tonumber(num") || line.includes("tonumber(CLF");
            if (!isInDetaintFunc && !isSafeContext) {
              const apiCalls = ["UnitHealth", "UnitPower", "GetSpellCooldown", "GetTime", "UnitCastingInfo"];
              for (const api of apiCalls) {
                expect(line).not.toContain(`tonumber(${api}`);
              }
            }
          }
        }
      }
    }
  });
});

describe("WoW 12.0 API Compliance", () => {
  let allLua: string;
  let allLuaLines: string[];

  function getNonCommentLines(lua: string): string[] {
    return lua.split("\n").filter(l => !l.trim().startsWith("--"));
  }

  function countNonCommentOccurrences(pattern: string): number {
    return allLuaLines.filter(l => l.includes(pattern)).length;
  }

  function assertNoNonCommentUsage(pattern: string, description: string) {
    const matches = allLuaLines
      .map((l, i) => ({ line: l, num: i + 1 }))
      .filter(x => x.line.includes(pattern));
    if (matches.length > 0) {
      throw new Error(
        `${description}: Found "${pattern}" on ${matches.length} non-comment line(s): ` +
        matches.slice(0, 3).map(m => `L${m.num}: ${m.line.trim().substring(0, 80)}`).join("; ")
      );
    }
  }

  beforeAll(() => {
    const data = makeAddonData();
    allLua = [
      generateHelpers(data),
      generateEngine(data),
      generateHud(data),
      generateCore(data),
      generateSettingsPanel(),
    ].join("\n");
    allLuaLines = getNonCommentLines(allLua);
  });

  describe("Removed APIs (Rule 0.1, A1, A6)", () => {
    it("does not use UnitBuff()", () => {
      assertNoNonCommentUsage("UnitBuff(", "UnitBuff is removed in 12.0 — use C_UnitAuras.GetBuffDataByIndex");
    });

    it("does not use UnitDebuff()", () => {
      assertNoNonCommentUsage("UnitDebuff(", "UnitDebuff is removed in 12.0 — use C_UnitAuras.GetDebuffDataByIndex");
    });

    it("does not use UnitAura()", () => {
      assertNoNonCommentUsage("UnitAura(", "UnitAura is removed in 12.0 — use C_UnitAuras API");
    });

    it("does not use GetSpellCooldownRemaining", () => {
      assertNoNonCommentUsage("GetSpellCooldownRemaining", "GetSpellCooldownRemaining is removed — use Duration Objects");
    });

    it("does not use GetAuraDurationRemaining", () => {
      assertNoNonCommentUsage("GetAuraDurationRemaining", "GetAuraDurationRemaining is removed — use Duration Objects");
    });

    it("does not use CooldownFrame_SetTimer", () => {
      assertNoNonCommentUsage("CooldownFrame_SetTimer", "CooldownFrame_SetTimer is removed");
    });

    it("does not use AuraUtil.FindAuraByName()", () => {
      assertNoNonCommentUsage("AuraUtil.FindAuraByName(", "AuraUtil.FindAuraByName is unreliable — use manual scan");
    });

    it("does not use GetShapeshiftFormInfo (removed in 12.0)", () => {
      assertNoNonCommentUsage("GetShapeshiftFormInfo(", "GetShapeshiftFormInfo is removed in 12.0 — use FORM_INDEX_MAP + FindAura fallback");
    });

    it("wraps all InCombatLockdown() in DetaintBool", () => {
      const lines = allLua.split("\n");
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (line.trim().startsWith("--")) continue;
        const stripped = line.replace(/--.*$/, "");
        if (stripped.includes("InCombatLockdown()") && !stripped.includes("DetaintBool(InCombatLockdown()")) {
          throw new Error(`Line ${i + 1}: bare InCombatLockdown() without DetaintBool wrapper: ${line.trim()}`);
        }
      }
    });
  });

  describe("Protected APIs (Rule A5)", () => {
    it("does not use SetOverrideBindingClick", () => {
      assertNoNonCommentUsage("SetOverrideBindingClick(", "SetOverrideBindingClick is protected in 12.0 — use Bindings.xml");
    });

    it("does not use SetPropagateKeyboardInput", () => {
      assertNoNonCommentUsage("SetPropagateKeyboardInput(", "SetPropagateKeyboardInput is protected on secure frames");
    });
  });

  describe("Sound API (Rule A4)", () => {
    it("does not use PlaySoundFile (broken in 12.0)", () => {
      const playSoundFileLines = allLuaLines.filter(l => {
        const trimmed = l.trim();
        if (trimmed.startsWith("--")) return false;
        return trimmed.includes("PlaySoundFile(");
      });
      expect(playSoundFileLines.length).toBe(0);
    });

    it("uses PlaySound with numeric IDs or SoundId config variables", () => {
      const playSoundLines = allLuaLines.filter(l => l.includes("PlaySound("));
      expect(playSoundLines.length).toBeGreaterThan(0);
      for (const line of playSoundLines) {
        const match = line.match(/PlaySound\(\s*([^,)]+)/);
        if (match) {
          const arg = match[1].trim();
          const isNumericLiteral = /^[0-9]+$/.test(arg);
          const isSoundIdVar = /SoundId|soundId|sound_id/i.test(arg) || /^[a-zA-Z_]\w*$/.test(arg);
          const isAcceptable = isNumericLiteral || isSoundIdVar;
          if (!isAcceptable) {
            throw new Error(
              `PlaySound argument "${arg}" is not a numeric literal or SoundId variable: ${line.trim()}`
            );
          }
        }
      }
    });

    it("includes all sound config keys in config (no SoundFile or heal keys)", () => {
      const data = makeAddonData();
      const config = generateConfig(data);
      expect(config).toContain("interruptSoundId");
      expect(config).toContain("stSwitchSound");
      expect(config).toContain("stSwitchSoundId");
      expect(config).toContain("aoeSwitchSound");
      expect(config).toContain("aoeSwitchSoundId");
      expect(config).not.toContain("SoundFile");
      expect(config).not.toContain("healSound");
      expect(config).not.toContain("healSoundId");
    });
  });

  describe("Modern API Usage (Rule A1)", () => {
    it("uses C_Spell namespace for spell APIs", () => {
      const data = makeAddonData();
      const combined = generateEngine(data) + generateHelpers(data);
      expect(combined).toContain("C_Spell");
    });

    it("uses C_UnitAuras for aura iteration", () => {
      const data = makeAddonData();
      const helpers = generateHelpers(data);
      expect(helpers).toContain("C_UnitAuras");
    });

    it("wraps every C_UnitAuras.Get*ByIndex call with pcall", () => {
      const data = makeAddonData();
      const helpers = generateHelpers(data);
      const lines = helpers.split("\n");
      const nonCommentLines = lines.filter(l => !l.trim().startsWith("--"));

      const directCalls = nonCommentLines.filter(l =>
        (l.includes("C_UnitAuras.GetBuffDataByIndex(") || l.includes("C_UnitAuras.GetDebuffDataByIndex(")) &&
        !l.includes("pcall")
      );
      expect(directCalls).toEqual([]);

      const pcallCalls = nonCommentLines.filter(l =>
        l.includes("pcall") && l.includes("C_UnitAuras")
      );
      expect(pcallCalls.length).toBeGreaterThan(0);
    });
  });

  describe("String Safety (Rule 0.3)", () => {
    it("does not use :lower() method syntax on API-returned strings", () => {
      const dangerousPatterns = [
        /Detaint\w*\([^)]*\):lower\(\)/,
        /\.name:lower\(\)/,
        /info\.\w+:lower\(\)/,
      ];
      for (const line of allLuaLines) {
        for (const pat of dangerousPatterns) {
          expect(line).not.toMatch(pat);
        }
      }
    });

    it("does not use :find() method syntax on API-returned strings", () => {
      const dangerousPatterns = [
        /Detaint\w*\([^)]*\):find\(/,
        /\.name:find\(/,
        /info\.\w+:find\(/,
      ];
      for (const line of allLuaLines) {
        for (const pat of dangerousPatterns) {
          expect(line).not.toMatch(pat);
        }
      }
    });

    it("does not use :gsub() method syntax on API-returned strings", () => {
      const dangerousPatterns = [
        /Detaint\w*\([^)]*\):gsub\(/,
        /\.name:gsub\(/,
      ];
      for (const line of allLuaLines) {
        for (const pat of dangerousPatterns) {
          expect(line).not.toMatch(pat);
        }
      }
    });

    it("uses string.lower() function syntax", () => {
      const stringLowerCalls = allLuaLines.filter(l => l.includes("string.lower("));
      expect(stringLowerCalls.length).toBeGreaterThan(0);
    });

    it("uses string.find() function syntax", () => {
      const stringFindCalls = allLuaLines.filter(l => l.includes("string.find("));
      expect(stringFindCalls.length).toBeGreaterThan(0);
    });
  });

  describe("Lua syntax safety", () => {
    it("does not use goto statements (illegal jump into local scope in WoW Lua)", () => {
      for (const line of allLuaLines) {
        expect(line).not.toMatch(/^\s*goto\s+\w/);
        expect(line).not.toMatch(/^\s*::\w+::$/);
      }
    });
  });

  describe("Taint/Secret Safety (Rule 0.3b, P1-P10)", () => {
    it("defines Detaint function", () => {
      expect(allLua).toContain("function Detaint(");
      expect(allLua).toContain("function DetaintStr(");
      expect(allLua).toContain("function DetaintBool(");
    });

    it("uses issecretvalue() checks in Detaint functions", () => {
      expect(allLua).toContain("issecretvalue");
    });

    it("Detaint returns nil for tainted values via issecretvalue guard", () => {
      const helpers = generateHelpers(makeAddonData());
      expect(helpers).toContain("issecretvalue(val) then TaintHit(tag) return nil");
    });

    it("DetaintBool returns false for tainted boolean values", () => {
      const helpers = generateHelpers(makeAddonData());
      expect(helpers).toContain("issecretvalue(val) then TaintHit(tag) return false");
      expect(helpers).toContain("if val then return true else return false end");
    });

    it("FindAura uses DetaintStr for safe name extraction before string ops", () => {
      const helpers = generateHelpers(makeAddonData());
      expect(helpers).toContain("local nameStr = DetaintStr(rawName)");
      expect(helpers).not.toContain("pcall(string.lower, rawName)");
      expect(helpers).not.toContain("pcall(string.find, lowerName");
    });

    it("does not use tonumber() directly on WoW API returns", () => {
      const dangerousPatterns = [
        "tonumber(UnitHealth(",
        "tonumber(UnitPower(",
        "tonumber(GetSpellCooldown(",
        "tonumber(UnitCastingInfo(",
        "tonumber(C_Spell.",
      ];
      for (const pat of dangerousPatterns) {
        assertNoNonCommentUsage(pat, `Direct tonumber() on API return is unsafe — use Detaint()`);
      }
    });

    it("does not use tostring() directly on WoW API returns", () => {
      const dangerousPatterns = [
        "tostring(UnitHealth(",
        "tostring(UnitPower(",
        "tostring(C_Spell.",
      ];
      for (const pat of dangerousPatterns) {
        assertNoNonCommentUsage(pat, `Direct tostring() on API return is unsafe — blocked on secrets`);
      }
    });
  });

  describe("Event Handler Best Practices (Rule E2)", () => {
    it("uses RegisterUnitEvent for UNIT_AURA", () => {
      const coreOrHelpers = allLua;
      const hasUnitAuraReg = coreOrHelpers.includes('RegisterUnitEvent("UNIT_AURA"');
      expect(hasUnitAuraReg).toBe(true);
    });
  });

  describe("Consumable Config Fields", () => {
    it("emits all consumable config fields in single-spec config", () => {
      const data = makeAddonData();
      const config = generateConfig(data);
      const requiredFields = [
        "consumablesEnabled",
        "flaskEnabled",
        "foodEnabled",
        "weaponEnhEnabled",
        "augmentRuneEnabled",
      ];
      for (const field of requiredFields) {
        expect(config).toContain(field);
      }
      expect(config).not.toContain("potionEnabled");
      expect(config).not.toContain("potionItemName");
    });

    it("consumable buff scanning uses C_UnitAuras (not UnitAura)", () => {
      const data = makeAddonData();
      const helpers = generateHelpers(data);
      const consumableStart = helpers.indexOf("Consumable Buff Alerts");
      expect(consumableStart).toBeGreaterThan(-1);
      const consumableEnd = helpers.indexOf("function CLF.GetKeybindForSlot", consumableStart);
      const consumableSection = helpers.substring(
        consumableStart,
        consumableEnd > consumableStart ? consumableEnd : helpers.length
      );
      expect(consumableSection).toContain("C_UnitAuras");
      expect(consumableSection).not.toContain("UnitAura(");
      expect(consumableSection).not.toContain("UnitBuff(");
    });

    it("buff detection uses pattern matching for food and flask categories", () => {
      const data = makeAddonData();
      const helpers = generateHelpers(data);
      const consumableStart = helpers.indexOf("Consumable Buff Alerts");
      const consumableEnd = helpers.indexOf("function CLF.GetKeybindForSlot", consumableStart);
      const consumableSection = helpers.substring(
        consumableStart,
        consumableEnd > consumableStart ? consumableEnd : helpers.length
      );
      expect(consumableSection).toContain('"well fed"');
      expect(consumableSection).toContain('"phial"');
      expect(consumableSection).toContain('"flask"');
    });

    it("no bag scanning or item selection in helpers", () => {
      const data = makeAddonData();
      const helpers = generateHelpers(data);
      expect(helpers).not.toContain("ScanConsumableBags");
      expect(helpers).not.toContain("InitPotion");
      expect(helpers).not.toContain("CLF._potion");
    });

    it("consumable reminders update separate bar instead of queue injection", () => {
      const data = makeAddonData();
      const engine = generateEngine(data);
      expect(engine).toContain("CheckConsumableBuffs");
      expect(engine).toContain("UpdateConsumableBar");
      expect(engine).not.toContain("isConsumable = true");
      expect(engine).not.toContain("isPotion");
    });
  });

  describe("Glow Override", () => {
    it("action bar glows override CD timers as authoritative signal", () => {
      const data = makeAddonData();
      const engine = generateEngine(data);
      expect(engine).toContain("Glow override");
      expect(engine).toContain("clearing CD timer");
    });
  });

  describe("Power Taint Safety", () => {
    it("uses internal resource tracker instead of direct UnitPower calls in combat", () => {
      const data = makeAddonData();
      const helpers = generateHelpers(data);
      expect(helpers).toContain("CLF._resTracker");
      expect(helpers).toContain("CLF.OnResourceCLEU");
      expect(helpers).toContain("CLF.CalibrateResource");
    });
  });

  describe("L Table Safety", () => {
    it("uses setmetatable fallback for L in all generated files", () => {
      const data = makeAddonData();
      const helpers = generateHelpers(data);
      const engine = generateEngine(data);
      const hud = generateHud(data);
      const settings = generateSettingsPanel();
      const core = generateCore(data);
      for (const [name, content] of [
        ["helpers", helpers],
        ["engine", engine],
        ["hud", hud],
        ["settings", settings],
        ["core", core],
      ] as const) {
        expect(content).toContain(
          'setmetatable({}, {__index = function(_, k) return k end})'
        );
      }
    });
  });

  describe("Cooldown Display", () => {
    it("uses CooldownFrameTemplate for sweep animations", () => {
      const data = makeAddonData();
      const hud = generateHud(data);
      expect(hud).toContain("CooldownFrameTemplate");
    });

    it("config emits cooldownStyle field", () => {
      const data = makeAddonData();
      const config = generateConfig(data);
      expect(config).toContain("cooldownStyle");
    });
  });

  describe("Keybind Mode Cycling", () => {
    it("uses Bindings.xml instead of protected SetOverrideBindingClick", () => {
      const settingsOrCore = generateSettingsPanel() + generateCore(makeAddonData());
      expect(settingsOrCore).not.toContain("SetOverrideBindingClick");
      const bindings = generateBindingsXml();
      expect(bindings).toContain("DMGASSIST_CYCLE_MODE");
      expect(bindings).toContain("CLF.CycleMode()");
    });
  });

  describe("UnitCastingInfo/UnitChannelInfo Safety", () => {
    it("detaints UnitCastingInfo return values before arithmetic in HUD", () => {
      const data = makeAddonData();
      const hud = generateHud(data);
      const lines = hud.split("\n").filter(l => !l.trim().startsWith("--"));
      const castingLines = lines.filter(l => l.includes("UnitCastingInfo") || l.includes("UnitChannelInfo"));
      for (const line of castingLines) {
        expect(line).not.toMatch(/local castName.*=.*UnitCastingInfo/);
        expect(line).not.toMatch(/local castName.*=.*UnitChannelInfo/);
      }
      const castStartUsage = lines.filter(l => l.includes("castStart") && l.includes("-"));
      for (const line of castStartUsage) {
        expect(line).not.toMatch(/UnitCastingInfo|UnitChannelInfo/);
      }
    });

    it("uses internal cast state tracking instead of direct UnitCastingInfo", () => {
      const data = makeAddonData();
      const hud = generateHud(data);
      expect(hud).not.toContain("UnitCastingInfo(\"player\")");
      expect(hud).not.toContain("UnitChannelInfo(\"player\")");
      expect(hud).toContain("CLF._castState");
    });
  });

  describe("CLF.Msg Function", () => {
    it("defines CLF.Msg in Core.lua", () => {
      const data = makeAddonData();
      const core = generateCore(data);
      expect(core).toContain("function CLF.Msg(");
    });

    it("does not use bare Msg() in Core.lua", () => {
      const data = makeAddonData();
      const core = generateCore(data);
      const lines = core.split("\n").filter(l => !l.trim().startsWith("--"));
      const bareMsgCalls = lines.filter(l =>
        /[^.a-zA-Z_]Msg\(/.test(l) &&
        !l.includes("CLF.Msg(") &&
        !l.includes("function CLF.Msg(") &&
        !l.includes("SendMessage")
      );
      expect(bareMsgCalls).toEqual([]);
    });
  });

  describe("Inline conditionFn (no loadstring taint)", () => {
    it("emits conditionFn = function() for config entries with conditions", () => {
      const data = makeAddonData({
        aplEntries: [
          makeAplEntry({ condition: "buff.test.up&cooldown.test.ready" }),
        ],
      });
      const config = generateConfig(data);
      expect(config).toContain("conditionFn = function()");
      expect(config).toContain('CLF.BuffUp("test")');
      expect(config).toContain('CLF.CooldownReady("test")');
    });

    it("emits conditionFn = function() return true end for empty conditions", () => {
      const data = makeAddonData({
        aplEntries: [makeAplEntry({ condition: "" })],
      });
      const config = generateConfig(data);
      expect(config).toContain("conditionFn = function() return true end");
    });

    it("does NOT contain loadstring in BuildFilteredAPL rotation handler", () => {
      const data = makeAddonData();
      const engine = generateEngine(data);
      const buildSection = engine.split("function CLF.BuildFilteredAPL()")[1];
      if (buildSection) {
        const rotationSection = buildSection.split("CLF._filteredAPL = f")[0];
        const loadstringCalls = rotationSection.split("\n").filter(
          (l: string) => l.includes("loadstring(entry.conditionSrc)") && !l.trim().startsWith("--")
        );
        expect(loadstringCalls).toEqual([]);
      }
    });

    it("multi-spec config also emits inline conditionFn", () => {
      const data = makeAddonData({
        aplEntries: [
          makeAplEntry({ condition: "talent.test.enabled" }),
        ],
      });
      const allData = { specs: [data] };
      const config = generateAllSpecsConfig(allData);
      expect(config).toContain("conditionFn = function()");
      expect(config).toContain('CLF.TalentEnabled("test")');
    });
  });

  describe("Simplified combat architecture", () => {
    it("active enemies returns fixed value based on combat mode setting", () => {
      const data = makeAddonData();
      const helpers = generateHelpers(data);
      expect(helpers).toContain("function CLF.ActiveEnemies()");
      expect(helpers).toContain('CLF.combatMode == "ST"');
    });
  });

  describe("Anti-stuck mechanism", () => {
    it("has stuck detection with threshold counter", () => {
      const data = makeAddonData();
      const engine = generateEngine(data);
      expect(engine).toContain("CLF._stuckSpell");
      expect(engine).toContain("CLF._stuckCount");
      expect(engine).toContain("CLF._stuckThreshold");
      expect(engine).toContain("ANTI-STUCK");
    });
  });

  describe("Diagnostic Infrastructure", () => {
    it("has TaintHit tracking in Detaint functions", () => {
      const data = makeAddonData();
      const helpers = generateHelpers(data);
      expect(helpers).toContain("CLF._taintStats");
      expect(helpers).toContain("function CLF.TaintHit(tag)");
      expect(helpers).toContain("TaintHit(tag)");
    });

    it("has snapshot command handler", () => {
      const data = makeAddonData();
      const core = generateCore(data);
      expect(core).toContain('"snapshot"');
      expect(core).toContain("_lastSnapshot");
    });

    it("has selftest command handler", () => {
      const data = makeAddonData();
      const core = generateCore(data);
      expect(core).toContain('"selftest"');
      expect(core).toContain("SUBSYSTEM SELF-TEST");
    });

    it("has taintreset command handler", () => {
      const data = makeAddonData();
      const core = generateCore(data);
      expect(core).toContain('"taintreset"');
    });

    it("engine stores snapshot on every tick", () => {
      const data = makeAddonData();
      const engine = generateEngine(data);
      expect(engine).toContain("CLF._lastSnapshot");
      expect(engine).toContain("candidates");
    });

    it("tags critical Detaint calls with API identifiers", () => {
      const data = makeAddonData();
      const helpers = generateHelpers(data);
      expect(helpers).toContain('SafeGetSpellCooldown');
      expect(helpers).toContain('"GetShapeshiftForm"');
      expect(helpers).toContain('C_Spell.IsSpellUsable');
    });
  });

  describe("Form Detection (Moonkin/Shapeshift)", () => {
    it("does not use GetShapeshiftFormInfo (removed in 12.0)", () => {
      const data = makeAddonData();
      const helpers = generateHelpers(data);
      const lines = helpers.split("\n").filter(l => !l.trim().startsWith("--"));
      const formInfoCalls = lines.filter(l => l.includes("GetShapeshiftFormInfo("));
      expect(formInfoCalls).toEqual([]);
    });

    it("uses FORM_INDEX_MAP for form detection with FindAura fallback", () => {
      const data = makeAddonData();
      const helpers = generateHelpers(data);
      expect(helpers).toContain("FORM_INDEX_MAP");
      expect(helpers).toContain("FindAura");
      expect(helpers).toContain("GetShapeshiftForm");
    });
  });

  describe("Local function definition order safety", () => {
    it("all local functions in Engine.lua are defined before first use", () => {
      const data = makeAddonData();
      const engine = generateEngine(data);
      const lines = engine.split("\n");

      const localFuncDefs = new Map<string, number>();
      const funcCallSites = new Map<string, number>();

      for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        const defMatch = line.match(/^local\s+function\s+(\w+)\s*\(/);
        if (defMatch) {
          const name = defMatch[1];
          if (!localFuncDefs.has(name)) {
            localFuncDefs.set(name, i + 1);
          }
        }
      }

      for (const [funcName, defLine] of localFuncDefs) {
        const callPattern = new RegExp(`(?<!local\\s+function\\s+)\\b${funcName}\\s*\\(`);
        for (let i = 0; i < lines.length; i++) {
          const line = lines[i];
          if (line.trim().startsWith("--")) continue;
          if (i + 1 === defLine) continue;
          if (callPattern.test(line)) {
            if (!funcCallSites.has(funcName) || i + 1 < funcCallSites.get(funcName)!) {
              funcCallSites.set(funcName, i + 1);
            }
          }
        }
      }

      const violations: string[] = [];
      for (const [funcName, defLine] of localFuncDefs) {
        const firstCall = funcCallSites.get(funcName);
        if (firstCall && firstCall < defLine) {
          violations.push(
            `local function '${funcName}' defined at line ${defLine} but first called at line ${firstCall}`
          );
        }
      }
      expect(violations).toEqual([]);
    });

    it("all local functions in Helpers.lua are defined before first use", () => {
      const data = makeAddonData();
      const helpers = generateHelpers(data);
      const lines = helpers.split("\n");

      const localFuncDefs = new Map<string, number>();
      const funcCallSites = new Map<string, number>();

      for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        const defMatch = line.match(/^local\s+function\s+(\w+)\s*\(/);
        if (defMatch) {
          const name = defMatch[1];
          if (!localFuncDefs.has(name)) {
            localFuncDefs.set(name, i + 1);
          }
        }
      }

      for (const [funcName, defLine] of localFuncDefs) {
        const callPattern = new RegExp(`(?<!local\\s+function\\s+)\\b${funcName}\\s*\\(`);
        for (let i = 0; i < lines.length; i++) {
          const line = lines[i];
          if (line.trim().startsWith("--")) continue;
          if (i + 1 === defLine) continue;
          if (callPattern.test(line)) {
            if (!funcCallSites.has(funcName) || i + 1 < funcCallSites.get(funcName)!) {
              funcCallSites.set(funcName, i + 1);
            }
          }
        }
      }

      const violations: string[] = [];
      for (const [funcName, defLine] of localFuncDefs) {
        const firstCall = funcCallSites.get(funcName);
        if (firstCall && firstCall < defLine) {
          violations.push(
            `local function '${funcName}' defined at line ${defLine} but first called at line ${firstCall}`
          );
        }
      }
      expect(violations).toEqual([]);
    });

    it("critical helper functions in Engine.lua are globally accessible (not local)", () => {
      const data = makeAddonData();
      const engine = generateEngine(data);

      const criticalFns = [
        "SafeDetaintNum",
        "Detaint",
        "DetaintBool",
        "DetaintStr",
        "NormalizeName",
      ];

      for (const fn of criticalFns) {
        const localDef = new RegExp(`^local\\s+function\\s+${fn}\\s*\\(`, "m");
        if (localDef.test(engine)) {
          const callCount = (engine.match(new RegExp(`\\b${fn}\\s*\\(`, "g")) || []).length;
          if (callCount > 5) {
            expect.fail(
              `'${fn}' is local in Engine.lua but called ${callCount} times — should be global to avoid order-dependency bugs`
            );
          }
        }
      }
    });
  });
});
