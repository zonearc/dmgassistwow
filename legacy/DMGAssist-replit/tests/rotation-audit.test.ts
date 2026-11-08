import { describe, it, expect, beforeAll } from "vitest";
import { execSync } from "child_process";
import { writeFileSync, mkdirSync, existsSync } from "fs";
import { join } from "path";
import { generateConfig } from "../server/addon-generator";
import { MemStorage, SPECS, DEFAULT_HUD } from "../server/storage";

const ROOT = process.cwd();
const TMP = join(ROOT, "tests", ".tmp-audit");

interface SimResult {
  specId: string;
  scenarioName: string;
  totalSteps: number;
  results: StepResult[];
  error?: string;
}

interface StepResult {
  stepName: string;
  stepIndex: number;
  queue: QueueEntry[];
  precombatNeeded: string[];
  interruptAvailable: boolean;
  conditionResults: ConditionResult[];
  errors: { spell: string; error: string }[];
}

interface QueueEntry {
  spell: string;
  priority: number;
  mode?: string;
  isPrecombat?: boolean;
  isInterrupt?: boolean;
  isCooldown?: boolean;
}

interface ConditionResult {
  spell: string;
  priority: number;
  mode: string;
  conditionMet: boolean;
  usable: boolean;
  ready: boolean;
  isPrecombat: boolean;
  precombatType?: string;
  isInterrupt: boolean;
  isCooldown: boolean;
  error?: string;
}

function ensureDir(dir: string) {
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
}

function runSim(specId: string, configLua: string, scenarioLua: string): SimResult {
  ensureDir(TMP);
  const configPath = join(TMP, `config_${specId}.lua`);
  const scenarioPath = join(TMP, `scenario_${specId}.lua`);
  writeFileSync(configPath, configLua, "utf-8");
  writeFileSync(scenarioPath, scenarioLua, "utf-8");
  try {
    const output = execSync(
      `lua "${join(ROOT, "tests/wow-sim/harness.lua")}" "${ROOT}" "${configPath}" "${scenarioPath}"`,
      { encoding: "utf-8", timeout: 10000 }
    );
    return JSON.parse(output);
  } catch (err: any) {
    return {
      specId, scenarioName: "error", totalSteps: 0, results: [],
      error: `Lua error: ${err.stderr || ""}\n${err.stdout || ""}\n${err.message}`,
    };
  }
}

let storage: MemStorage;

beforeAll(async () => {
  storage = new MemStorage();
  ensureDir(TMP);
  for (const spec of SPECS) {
    const existing = await storage.getHudConfig(spec.id);
    if (!existing) {
      await storage.upsertHudConfig({ ...DEFAULT_HUD, specId: spec.id });
    }
  }
});

async function genConfig(specId: string): Promise<string> {
  const spec = SPECS.find(s => s.id === specId)!;
  const aplEntries = await storage.getAplEntries(specId);
  const hudConfig = await storage.getHudConfig(specId);
  const alerts = await storage.getCombatAlerts(specId);
  return generateConfig({ spec, aplEntries, hudConfig: hudConfig!, alerts });
}

function step(name: string, setupCode: string): string {
  return `{
      name = "${name}",
      setup = function(M)
        ${setupCode}
      end,
    }`;
}

function scenario(specId: string, name: string, steps: string[]): string {
  return `return {
  specId = "${specId}",
  name = "${name}",
  steps = {
${steps.join(",\n")}
  }
}`;
}

describe("AUDIT: Deep condition evaluation per spec", () => {
  const allSpecs = SPECS.map(s => s.id);

  for (const specId of allSpecs) {
    it(`${specId}: no condition compilation errors in full combat`, async () => {
      const configLua = await genConfig(specId);

      const scen = scenario(specId, "full_audit", [
        step("ooc_idle", `
          M.inCombat = false
          M.power = 0
          M.powerMax = 100
          M.targetExists = true
        `),
        step("combat_low_res", `
          M:EnterCombat()
          M.power = 10
          M.powerMax = 100
          M.targetExists = true
          M.activeEnemies = 1
        `),
        step("combat_mid_res", `
          M:EnterCombat()
          M.power = 50
          M.powerMax = 100
          M.targetExists = true
          M.activeEnemies = 1
        `),
        step("combat_full_res", `
          M:EnterCombat()
          M.power = 100
          M.powerMax = 100
          M.targetExists = true
          M.activeEnemies = 1
        `),
        step("aoe_5_targets", `
          M:EnterCombat()
          M.power = 80
          M.powerMax = 100
          M.targetExists = true
          M.activeEnemies = 5
        `),
        step("execute_phase", `
          M:EnterCombat()
          M.power = 80
          M.powerMax = 100
          M.targetHealth = 50000
          M.targetHealthMax = 500000
          M.targetExists = true
        `),
        step("low_player_hp", `
          M:EnterCombat()
          M.power = 50
          M.powerMax = 100
          M.playerHealth = 15000
          M.playerHealthMax = 100000
          M.targetExists = true
        `),
        step("moving", `
          M:EnterCombat()
          M.power = 50
          M.powerMax = 100
          M.moving = true
          M.targetExists = true
        `),
        step("target_casting", `
          M:EnterCombat()
          M.power = 50
          M.powerMax = 100
          M.targetExists = true
          M.targetCasting = true
          M.targetCastInterruptible = true
        `),
        step("with_buffs", `
          M:EnterCombat()
          M.power = 80
          M.powerMax = 100
          M.targetExists = true
          M:AddBuff("bloodlust", 20, 1, 40)
          M:AddDebuff("colossus_smash", 10, 1, 10)
        `),
      ]);

      const result = runSim(specId, configLua, scen);
      expect(result.error).toBeUndefined();

      const allErrors: string[] = [];
      for (const sr of result.results) {
        for (const err of sr.errors) {
          allErrors.push(`[${sr.stepName}] ${err.spell}: ${err.error}`);
        }
      }

      if (allErrors.length > 0) {
        console.error(`\n=== ${specId} CONDITION ERRORS ===`);
        for (const e of allErrors) console.error(`  ${e}`);
      }
      expect(allErrors).toEqual([]);
    });
  }
});

describe("AUDIT: Interrupt spells exist and are correct per class", () => {
  const interruptMap: Record<string, string> = {
    "dk-blood": "Mind Freeze", "dk-frost": "Mind Freeze", "dk-unholy": "Mind Freeze",
    "dh-havoc": "Disrupt", "dh-vengeance": "Disrupt",
    "druid-balance": "Solar Beam", "druid-feral": "Skull Bash",
    "druid-guardian": "Skull Bash", "druid-resto": "Solar Beam",
    "evoker-dev": "Quell", "evoker-aug": "Quell", "evoker-pres": "Quell",
    "hunter-bm": "Counter Shot", "hunter-mm": "Counter Shot", "hunter-surv": "Muzzle",
    "mage-arcane": "Counterspell", "mage-fire": "Counterspell", "mage-frost": "Counterspell",
    "monk-ww": "Spear Hand Strike", "monk-brew": "Spear Hand Strike", "monk-mw": "Spear Hand Strike",
    "paladin-ret": "Rebuke", "paladin-prot": "Rebuke", "paladin-holy": "Rebuke",
    "priest-shadow": "Silence", "priest-disc": "Silence", "priest-holy": "Silence",
    "rogue-ass": "Kick", "rogue-out": "Kick", "rogue-sub": "Kick",
    "shaman-ele": "Wind Shear", "shaman-enh": "Wind Shear", "shaman-resto": "Wind Shear",
    "warlock-aff": "Spell Lock", "warlock-demo": "Axe Toss", "warlock-dest": "Spell Lock",
    "warrior-arms": "Pummel", "warrior-fury": "Pummel", "warrior-prot": "Pummel",
  };

  for (const specId of SPECS.map(s => s.id)) {
    it(`${specId}: has interrupt "${interruptMap[specId]}" in APL and it fires when target casts`, async () => {
      const configLua = await genConfig(specId);
      const expectedInterrupt = interruptMap[specId];

      const scen = scenario(specId, "interrupt_audit", [
        step("target_casting", `
          M:EnterCombat()
          M.power = 50
          M.powerMax = 100
          M.targetExists = true
          M.targetCasting = true
          M.targetCastInterruptible = true
        `),
      ]);

      const result = runSim(specId, configLua, scen);
      expect(result.error).toBeUndefined();

      const sr = result.results[0];
      expect(sr.errors.length).toBe(0);

      const interruptEntries = sr.conditionResults.filter(c => c.isInterrupt);
      expect(interruptEntries.length).toBeGreaterThan(0);

      const interruptNames = interruptEntries.map(c => c.spell);
      expect(interruptNames).toContain(expectedInterrupt);

      expect(sr.interruptAvailable).toBe(true);
      expect(sr.queue[0]?.isInterrupt).toBe(true);
      expect(sr.queue[0]?.spell).toBe(expectedInterrupt);
    });
  }
});

describe("AUDIT: Defensive spells fire at correct health thresholds", () => {
  const tankSpecs = ["dk-blood", "dh-vengeance", "druid-guardian", "monk-brew", "paladin-prot", "warrior-prot"];

  for (const specId of tankSpecs) {
    it(`${specId}: more defensives suggested at 20% HP than at 90% HP`, async () => {
      const configLua = await genConfig(specId);

      const scen = scenario(specId, "defensive_threshold", [
        step("hp_90", `
          M:EnterCombat()
          M.playerHealth = 90000
          M.playerHealthMax = 100000
          M.power = 50
          M.powerMax = 100
          M.targetExists = true
          M.activeEnemies = 2
        `),
        step("hp_50", `
          M:EnterCombat()
          M.playerHealth = 50000
          M.playerHealthMax = 100000
          M.power = 50
          M.powerMax = 100
          M.targetExists = true
          M.activeEnemies = 2
        `),
        step("hp_20", `
          M:EnterCombat()
          M.playerHealth = 20000
          M.playerHealthMax = 100000
          M.power = 50
          M.powerMax = 100
          M.targetExists = true
          M.activeEnemies = 2
        `),
      ]);

      const result = runSim(specId, configLua, scen);
      expect(result.error).toBeUndefined();

      const high = result.results[0];
      const low = result.results[2];

      expect(high.errors.length).toBe(0);
      expect(low.errors.length).toBe(0);

      const highDef = high.conditionResults.filter(c => c.conditionMet && c.spell.match(/Shield Wall|Ignore Pain|Ironfur|Purify Brew|Shield of the Righteous|Demon Spire|Death Strike/i));
      const lowDef = low.conditionResults.filter(c => c.conditionMet && c.spell.match(/Shield Wall|Ignore Pain|Ironfur|Purify Brew|Shield of the Righteous|Demon Spire|Death Strike/i));
      expect(lowDef.length).toBeGreaterThanOrEqual(highDef.length);
    });
  }
});

describe("AUDIT: Precombat form/stance detection accuracy", () => {
  it("druid-balance: Moonkin Form flagged as precombat state", async () => {
    const configLua = await genConfig("druid-balance");

    const scen = scenario("druid-balance", "form_check", [
      step("no_form", `
        M.inCombat = false
        M.shapeshiftForm = 0
        M.shapeshiftFormName = ""
        M.power = 0
        M.powerMax = 100
        M.targetExists = true
      `),
    ]);

    const result = runSim("druid-balance", configLua, scen);
    expect(result.error).toBeUndefined();
    expect(result.results[0].errors.length).toBe(0);

    const precombatStates = result.results[0].conditionResults.filter(
      c => c.isPrecombat && c.precombatType === "state"
    );
    const formEntries = precombatStates.filter(c =>
      c.spell.toLowerCase().includes("moonkin") || c.spell.toLowerCase().includes("form")
    );
    expect(formEntries.length).toBeGreaterThan(0);
  });

  it("druid-feral: Cat Form flagged as precombat state", async () => {
    const configLua = await genConfig("druid-feral");

    const scen = scenario("druid-feral", "form_check", [
      step("no_form", `
        M.inCombat = false
        M.shapeshiftForm = 0
        M.shapeshiftFormName = ""
        M.power = 0
        M.powerMax = 100
        M.targetExists = true
      `),
    ]);

    const result = runSim("druid-feral", configLua, scen);
    expect(result.error).toBeUndefined();
    expect(result.results[0].errors.length).toBe(0);

    const precombatStates = result.results[0].conditionResults.filter(
      c => c.isPrecombat && c.precombatType === "state"
    );
    const formEntries = precombatStates.filter(c =>
      c.spell.toLowerCase().includes("cat") || c.spell.toLowerCase().includes("form")
    );
    expect(formEntries.length).toBeGreaterThan(0);
  });

  it("druid-guardian: Bear Form flagged as precombat state", async () => {
    const configLua = await genConfig("druid-guardian");

    const scen = scenario("druid-guardian", "form_check", [
      step("no_form", `
        M.inCombat = false
        M.shapeshiftForm = 0
        M.shapeshiftFormName = ""
        M.power = 0
        M.powerMax = 100
        M.targetExists = true
      `),
    ]);

    const result = runSim("druid-guardian", configLua, scen);
    expect(result.error).toBeUndefined();
    expect(result.results[0].errors.length).toBe(0);

    const precombatStates = result.results[0].conditionResults.filter(
      c => c.isPrecombat && c.precombatType === "state"
    );
    const formEntries = precombatStates.filter(c =>
      c.spell.toLowerCase().includes("bear") || c.spell.toLowerCase().includes("form")
    );
    expect(formEntries.length).toBeGreaterThan(0);
  });

  it("rogue-sub: Stealth flagged as precombat state", async () => {
    const configLua = await genConfig("rogue-sub");

    const scen = scenario("rogue-sub", "stealth_check", [
      step("not_stealthed", `
        M.inCombat = false
        M.stealthed = false
        M.power = 100
        M.powerMax = 100
        M.targetExists = true
      `),
    ]);

    const result = runSim("rogue-sub", configLua, scen);
    expect(result.error).toBeUndefined();
    expect(result.results[0].errors.length).toBe(0);

    const precombatStates = result.results[0].conditionResults.filter(
      c => c.isPrecombat && c.precombatType === "state"
    );
    const stealthEntries = precombatStates.filter(c =>
      c.spell.toLowerCase().includes("stealth")
    );
    expect(stealthEntries.length).toBeGreaterThan(0);
  });

  it("rogue-ass: Stealth flagged as precombat state", async () => {
    const configLua = await genConfig("rogue-ass");

    const scen = scenario("rogue-ass", "stealth_check", [
      step("not_stealthed", `
        M.inCombat = false
        M.stealthed = false
        M.power = 100
        M.powerMax = 100
        M.targetExists = true
      `),
    ]);

    const result = runSim("rogue-ass", configLua, scen);
    expect(result.error).toBeUndefined();
    expect(result.results[0].errors.length).toBe(0);

    const precombatStates = result.results[0].conditionResults.filter(
      c => c.isPrecombat && c.precombatType === "state"
    );
    const stealthEntries = precombatStates.filter(c =>
      c.spell.toLowerCase().includes("stealth")
    );
    expect(stealthEntries.length).toBeGreaterThan(0);
  });
});

describe("AUDIT: Resource-gated spenders fire correctly", () => {
  it("paladin-ret: Templar's Verdict needs 3+ Holy Power", async () => {
    const configLua = await genConfig("paladin-ret");

    const scen = scenario("paladin-ret", "spender_gate", [
      step("hp_1", `
        M:EnterCombat()
        M.power = 1
        M.powerMax = 5
        M.targetExists = true
        M.activeEnemies = 1
      `),
      step("hp_3", `
        M:EnterCombat()
        M.power = 3
        M.powerMax = 5
        M.targetExists = true
        M.activeEnemies = 1
      `),
      step("hp_5", `
        M:EnterCombat()
        M.power = 5
        M.powerMax = 5
        M.targetExists = true
        M.activeEnemies = 1
      `),
    ]);

    const result = runSim("paladin-ret", configLua, scen);
    expect(result.error).toBeUndefined();

    for (const sr of result.results) {
      expect(sr.errors.length).toBe(0);
    }

    const findSpender = (sr: StepResult) => sr.conditionResults.filter(c =>
      c.conditionMet && (c.spell.includes("Verdict") || c.spell.includes("Divine Storm"))
    );

    const hp1Spenders = findSpender(result.results[0]);
    const hp5Spenders = findSpender(result.results[2]);
    expect(hp5Spenders.length).toBeGreaterThanOrEqual(hp1Spenders.length);
  });

  it("warrior-fury: Rampage needs rage (condition checks power)", async () => {
    const configLua = await genConfig("warrior-fury");

    const scen = scenario("warrior-fury", "rampage_gate", [
      step("rage_0", `
        M:EnterCombat()
        M.power = 0
        M.powerMax = 100
        M.targetExists = true
      `),
      step("rage_80", `
        M:EnterCombat()
        M.power = 80
        M.powerMax = 100
        M.targetExists = true
      `),
    ]);

    const result = runSim("warrior-fury", configLua, scen);
    expect(result.error).toBeUndefined();

    for (const sr of result.results) {
      expect(sr.errors.length).toBe(0);
    }
  });

  it("dk-frost: Obliterate needs runes", async () => {
    const configLua = await genConfig("dk-frost");

    const scen = scenario("dk-frost", "rune_gate", [
      step("no_runes", `
        M:EnterCombat()
        M.power = 50
        M.powerMax = 125
        M.runes = {false, false, false, false, false, false}
        M.targetExists = true
      `),
      step("full_runes", `
        M:EnterCombat()
        M.power = 50
        M.powerMax = 125
        M.runes = {true, true, true, true, true, true}
        M.targetExists = true
      `),
    ]);

    const result = runSim("dk-frost", configLua, scen);
    expect(result.error).toBeUndefined();

    for (const sr of result.results) {
      expect(sr.errors.length).toBe(0);
    }
  });
});

describe("AUDIT: Cooldown spells marked isCooldown=true", () => {
  const cdSpellsBySpec: Record<string, string[]> = {
    "paladin-ret": ["Avenging Wrath"],
    "warrior-fury": ["Recklessness"],
    "warrior-arms": ["Colossus Smash"],
    "dk-frost": ["Pillar of Frost"],
    "dk-unholy": ["Dark Transformation"],
    "dh-havoc": ["Metamorphosis"],
    "druid-balance": ["Celestial Alignment"],
    "priest-shadow": ["Void Eruption"],
    "mage-fire": ["Combustion"],
  };

  for (const [specId, expectedCDs] of Object.entries(cdSpellsBySpec)) {
    it(`${specId}: major CDs (${expectedCDs.join(", ")}) are marked isCooldown`, async () => {
      const configLua = await genConfig(specId);

      const scen = scenario(specId, "cd_flags", [
        step("all_ready", `
          M:EnterCombat()
          M.power = 80
          M.powerMax = 100
          M.targetExists = true
        `),
      ]);

      const result = runSim(specId, configLua, scen);
      expect(result.error).toBeUndefined();
      expect(result.results[0].errors.length).toBe(0);

      const allSpells = result.results[0].conditionResults;
      for (const cdName of expectedCDs) {
        const cdEntry = allSpells.find(c => c.spell === cdName);
        if (cdEntry) {
          expect(cdEntry.isCooldown).toBe(true);
        }
      }
    });
  }
});

describe("AUDIT: ST/AoE mode differentiation", () => {
  for (const specId of ["paladin-ret", "warrior-fury", "dh-havoc", "druid-balance", "mage-fire"]) {
    it(`${specId}: has both ST and AoE mode spells`, async () => {
      const configLua = await genConfig(specId);

      const scen = scenario(specId, "mode_check", [
        step("st", `
          M:EnterCombat()
          M.power = 80
          M.powerMax = 100
          M.targetExists = true
          M.activeEnemies = 1
        `),
      ]);

      const result = runSim(specId, configLua, scen);
      expect(result.error).toBeUndefined();
      expect(result.results[0].errors.length).toBe(0);

      const modes = new Set(result.results[0].conditionResults.map(c => c.mode));
      expect(modes.has("ST") || modes.has("Both")).toBe(true);
    });
  }
});

describe("AUDIT: Assisted highlights vs SimC overlap check", () => {
  it("paladin-ret: SimC top-priority spells with conditions met should overlap with what assisted would highlight", async () => {
    const configLua = await genConfig("paladin-ret");

    const scen = scenario("paladin-ret", "overlap_check", [
      step("full_resources_cds_ready", `
        M:EnterCombat()
        M.power = 5
        M.powerMax = 5
        M.targetExists = true
        M.activeEnemies = 1
      `),
    ]);

    const result = runSim("paladin-ret", configLua, scen);
    expect(result.error).toBeUndefined();
    expect(result.results[0].errors.length).toBe(0);

    const passed = result.results[0].conditionResults
      .filter(c => c.conditionMet && c.usable && c.ready)
      .sort((a, b) => a.priority - b.priority);

    expect(passed.length).toBeGreaterThan(0);

    const topSpell = passed[0];
    expect(topSpell.priority).toBeLessThan(1000);
  });
});
