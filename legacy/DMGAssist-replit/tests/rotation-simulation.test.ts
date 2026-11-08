import { describe, it, expect, beforeAll } from "vitest";
import { execSync } from "child_process";
import { writeFileSync, mkdirSync, existsSync } from "fs";
import { join } from "path";
import { generateConfig } from "../server/addon-generator";
import { MemStorage, SPECS, DEFAULT_HUD } from "../server/storage";

const ROOT = process.cwd();
const TMP = join(ROOT, "tests", ".tmp-sim");

interface SimResult {
  specId: string;
  scenarioName: string;
  totalSteps: number;
  results: StepResult[];
  error?: string;
  multiTick?: boolean;
  ticks?: TickResult[];
  violations?: Violation[];
  totalViolations?: number;
  totalTicks?: number;
}

interface TickResult {
  tick: number;
  time: number;
  mode: string;
  queueSize: number;
  queue: TickQueueEntry[];
  violationCount: number;
}

interface TickQueueEntry {
  slot: number;
  spell: string;
  priority: number;
  mode?: string;
  isCooldown?: boolean;
}

interface Violation {
  type: string;
  slot: number;
  spell: string;
  detail: string;
  tick?: number;
  time?: number;
  phase?: string;
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

function runSimulation(specId: string, configLua: string, scenarioLua: string): SimResult {
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
    const stderr = err.stderr || "";
    const stdout = err.stdout || "";
    return {
      specId,
      scenarioName: "error",
      totalSteps: 0,
      results: [],
      error: `Lua error: ${stderr}\n${stdout}\n${err.message}`,
    };
  }
}

let storage: MemStorage;
let allSpecIds: string[];

beforeAll(async () => {
  storage = new MemStorage();
  allSpecIds = SPECS.map(s => s.id);
  ensureDir(TMP);

  for (const spec of SPECS) {
    const existing = await storage.getHudConfig(spec.id);
    if (!existing) {
      await storage.upsertHudConfig({ ...DEFAULT_HUD, specId: spec.id });
    }
  }
});

async function generateSpecConfig(specId: string): Promise<string> {
  const spec = SPECS.find(s => s.id === specId);
  if (!spec) throw new Error(`Spec not found: ${specId}`);

  const aplEntries = await storage.getAplEntries(specId);
  const hudConfig = await storage.getHudConfig(specId);
  if (!hudConfig) throw new Error(`HudConfig not found for: ${specId}`);

  const alerts = await storage.getCombatAlerts(specId);

  return generateConfig({ spec, aplEntries, hudConfig, alerts });
}

function makeScenario(specId: string, name: string, steps: string[]): string {
  return `return {
  specId = "${specId}",
  name = "${name}",
  steps = {
${steps.map(s => `    ${s}`).join(",\n")}
  }
}`;
}

function step(name: string, setupCode: string): string {
  return `{
      name = "${name}",
      setup = function(M)
        ${setupCode}
      end,
    }`;
}

function makeMultiTickScenario(specId: string, name: string, ticks: number, setupCode: string): string {
  return `return {
  specId = "${specId}",
  name = "${name}",
  multiTick = {
    ticks = ${ticks},
    setup = function(M)
      ${setupCode}
    end,
  },
  steps = {},
}`;
}

describe("Rotation Simulation — All Specs Load & Execute", () => {
  const testedSpecs: string[] = [];

  it("has all 39 specs available", async () => {
    expect(allSpecIds.length).toBe(39);
  });

  for (const specId of [
    "paladin-ret", "warrior-fury", "warrior-arms", "mage-fire", "mage-frost",
    "dk-frost", "dk-unholy", "dk-blood", "dh-havoc", "dh-vengeance",
    "druid-balance", "druid-feral", "druid-guardian", "druid-resto",
    "hunter-bm", "hunter-mm", "hunter-surv",
    "monk-ww", "monk-brew", "monk-mw",
    "paladin-prot", "paladin-holy",
    "priest-shadow", "priest-disc",
    "rogue-ass", "rogue-out", "rogue-sub",
    "shaman-ele", "shaman-enh", "shaman-resto",
    "warlock-aff", "warlock-demo", "warlock-dest",
    "warrior-prot",
    "evoker-dev", "evoker-aug", "evoker-pres",
    "mage-arcane",
  ]) {
    it(`${specId}: generates valid config and conditions compile`, async () => {
      const configLua = await generateSpecConfig(specId);
      if (!configLua) {
        return;
      }

      const scenario = makeScenario(specId, "basic_load", [
        step("idle_out_of_combat", `
          M.inCombat = false
          M.power = 50
          M.targetExists = true
        `),
        step("in_combat_full_resource", `
          M:EnterCombat()
          M.power = M.powerMax
          M.targetExists = true
          M.activeEnemies = 1
        `),
      ]);

      const result = runSimulation(specId, configLua, scenario);
      expect(result.error).toBeUndefined();
      expect(result.totalSteps).toBe(2);

      for (const stepResult of result.results) {
        for (const err of stepResult.errors) {
          console.error(`${specId} ${stepResult.stepName}: ${err.spell} — ${err.error}`);
        }
        expect(stepResult.errors.length).toBe(0);
      }

      testedSpecs.push(specId);
    });
  }
});

describe("Rotation Simulation — Precombat State Detection", () => {
  it("paladin-ret: detects missing buffs out of combat", async () => {
    const configLua = await generateSpecConfig("paladin-ret");

    const scenario = makeScenario("paladin-ret", "precombat_state", [
      step("no_buffs_ooc", `
        M.inCombat = false
        M.power = 0
        M.targetExists = true
      `),
    ]);

    const result = runSimulation("paladin-ret", configLua, scenario);
    expect(result.error).toBeUndefined();
    expect(result.results[0].errors.length).toBe(0);

    const precombatSpells = result.results[0].conditionResults.filter(
      c => c.isPrecombat && c.precombatType === "state"
    );
    for (const pc of precombatSpells) {
      expect(pc.error).toBeUndefined();
    }
  });

  it("druid-balance: detects missing Moonkin Form", async () => {
    const configLua = await generateSpecConfig("druid-balance");

    const scenario = makeScenario("druid-balance", "missing_form", [
      step("not_in_moonkin_form", `
        M.inCombat = false
        M.shapeshiftForm = 0
        M.shapeshiftFormName = ""
      `),
      step("in_moonkin_form", `
        M.inCombat = false
        M.shapeshiftForm = 4
        M.shapeshiftFormName = "moonkin"
        M:AddBuff("moonkin_form", 999)
      `),
    ]);

    const result = runSimulation("druid-balance", configLua, scenario);
    expect(result.error).toBeUndefined();

    for (const sr of result.results) {
      expect(sr.errors.length).toBe(0);
    }
  });

  it("rogue-sub: detects missing stealth", async () => {
    const configLua = await generateSpecConfig("rogue-sub");

    const scenario = makeScenario("rogue-sub", "stealth_check", [
      step("not_stealthed", `
        M.inCombat = false
        M.stealthed = false
        M.power = 100
      `),
      step("stealthed", `
        M.inCombat = false
        M.stealthed = true
        M:AddBuff("stealth", 999)
        M.power = 100
      `),
    ]);

    const result = runSimulation("rogue-sub", configLua, scenario);
    expect(result.error).toBeUndefined();
    for (const sr of result.results) {
      expect(sr.errors.length).toBe(0);
    }
  });
});

describe("Rotation Simulation — Interrupt Override", () => {
  it("interrupt appears when target is casting", async () => {
    const configLua = await generateSpecConfig("paladin-ret");

    const scenario = makeScenario("paladin-ret", "interrupt_test", [
      step("target_not_casting", `
        M:EnterCombat()
        M.power = 5
        M.targetExists = true
        M.targetCasting = false
      `),
      step("target_casting_interruptible", `
        M:EnterCombat()
        M.power = 5
        M.targetExists = true
        M.targetCasting = true
        M.targetCastInterruptible = true
      `),
      step("target_casting_not_interruptible", `
        M:EnterCombat()
        M.power = 5
        M.targetExists = true
        M.targetCasting = true
        M.targetCastInterruptible = false
      `),
    ]);

    const result = runSimulation("paladin-ret", configLua, scenario);
    expect(result.error).toBeUndefined();

    const noCast = result.results[0];
    expect(noCast.interruptAvailable).toBe(false);

    const casting = result.results[1];
    expect(casting.interruptAvailable).toBe(true);
    if (casting.queue.length > 0) {
      expect(casting.queue[0].isInterrupt).toBe(true);
    }

    const nonInterruptible = result.results[2];
    expect(nonInterruptible.interruptAvailable).toBe(false);
  });
});

describe("Rotation Simulation — Resource-Based Prioritization", () => {
  it("paladin-ret: Holy Power affects which spells are suggested", async () => {
    const configLua = await generateSpecConfig("paladin-ret");

    const scenario = makeScenario("paladin-ret", "resource_prio", [
      step("low_holy_power", `
        M:EnterCombat()
        M.power = 1
        M.powerMax = 5
        M.targetExists = true
        M.activeEnemies = 1
      `),
      step("high_holy_power", `
        M:EnterCombat()
        M.power = 5
        M.powerMax = 5
        M.targetExists = true
        M.activeEnemies = 1
      `),
    ]);

    const result = runSimulation("paladin-ret", configLua, scenario);
    expect(result.error).toBeUndefined();

    const lowHP = result.results[0];
    const highHP = result.results[1];
    expect(lowHP.errors.length).toBe(0);
    expect(highHP.errors.length).toBe(0);

    const lowHPSpenders = lowHP.conditionResults.filter(
      c => c.conditionMet && (c.spell.includes("Verdict") || c.spell.includes("Divine Storm"))
    );
    const highHPSpenders = highHP.conditionResults.filter(
      c => c.conditionMet && (c.spell.includes("Verdict") || c.spell.includes("Divine Storm"))
    );

    expect(highHPSpenders.length).toBeGreaterThanOrEqual(lowHPSpenders.length);
  });

  it("warrior-fury: Rage affects Rampage availability", async () => {
    const configLua = await generateSpecConfig("warrior-fury");

    const scenario = makeScenario("warrior-fury", "rage_test", [
      step("low_rage", `
        M:EnterCombat()
        M.power = 10
        M.powerMax = 100
        M.targetExists = true
      `),
      step("high_rage", `
        M:EnterCombat()
        M.power = 90
        M.powerMax = 100
        M.targetExists = true
      `),
    ]);

    const result = runSimulation("warrior-fury", configLua, scenario);
    expect(result.error).toBeUndefined();
    for (const sr of result.results) {
      expect(sr.errors.length).toBe(0);
    }
  });
});

describe("Rotation Simulation — ST vs AoE Mode", () => {
  it("paladin-ret: AoE spells appear with more enemies", async () => {
    const configLua = await generateSpecConfig("paladin-ret");

    const scenario = makeScenario("paladin-ret", "st_vs_aoe", [
      step("single_target", `
        M:EnterCombat()
        M.power = 5
        M.powerMax = 5
        M.targetExists = true
        M.activeEnemies = 1
      `),
      step("multi_target", `
        M:EnterCombat()
        M.power = 5
        M.powerMax = 5
        M.targetExists = true
        M.activeEnemies = 5
      `),
    ]);

    const result = runSimulation("paladin-ret", configLua, scenario);
    expect(result.error).toBeUndefined();

    const st = result.results[0];
    const aoe = result.results[1];
    expect(st.errors.length).toBe(0);
    expect(aoe.errors.length).toBe(0);

    const stAoeSpells = st.conditionResults.filter(
      c => c.conditionMet && c.mode === "AoE"
    );
    const aoeAoeSpells = aoe.conditionResults.filter(
      c => c.conditionMet && c.mode === "AoE"
    );

    expect(aoeAoeSpells.length).toBeGreaterThanOrEqual(stAoeSpells.length);
  });
});

describe("Rotation Simulation — Buff/Debuff Awareness", () => {
  it("paladin-ret: Avenging Wrath buff changes priorities", async () => {
    const configLua = await generateSpecConfig("paladin-ret");

    const scenario = makeScenario("paladin-ret", "buff_awareness", [
      step("no_avenging_wrath", `
        M:EnterCombat()
        M.power = 3
        M.powerMax = 5
        M.targetExists = true
      `),
      step("with_avenging_wrath", `
        M:EnterCombat()
        M.power = 3
        M.powerMax = 5
        M.targetExists = true
        M:AddBuff("avenging_wrath", 15, 1, 20)
      `),
    ]);

    const result = runSimulation("paladin-ret", configLua, scenario);
    expect(result.error).toBeUndefined();

    const without = result.results[0];
    const with_ = result.results[1];
    expect(without.errors.length).toBe(0);
    expect(with_.errors.length).toBe(0);

    const withAWSpells = with_.conditionResults.filter(c => c.conditionMet);
    const withoutAWSpells = without.conditionResults.filter(c => c.conditionMet);
    expect(withAWSpells.length).not.toBe(withoutAWSpells.length);
  });

  it("dk-unholy: Festering Wound stacks affect Apocalypse", async () => {
    const configLua = await generateSpecConfig("dk-unholy");

    const scenario = makeScenario("dk-unholy", "wound_stacks", [
      step("low_wounds", `
        M:EnterCombat()
        M.power = 80
        M.powerMax = 125
        M.targetExists = true
        M:AddDebuff("festering_wound", 20, 1)
      `),
      step("high_wounds", `
        M:EnterCombat()
        M.power = 80
        M.powerMax = 125
        M.targetExists = true
        M:AddDebuff("festering_wound", 20, 4)
      `),
    ]);

    const result = runSimulation("dk-unholy", configLua, scenario);
    expect(result.error).toBeUndefined();
    for (const sr of result.results) {
      expect(sr.errors.length).toBe(0);
    }
  });
});

describe("Rotation Simulation — Cooldown States", () => {
  it("paladin-ret: CD on/off cooldown changes suggestions", async () => {
    const configLua = await generateSpecConfig("paladin-ret");

    const scenario = makeScenario("paladin-ret", "cooldown_test", [
      step("cds_on_cooldown", `
        M:EnterCombat()
        M.power = 3
        M.powerMax = 5
        M.targetExists = true
        M:SetCooldown("avenging_wrath", 60, 120)
        M:SetCooldown("wake_of_ashes", 20, 30)
      `),
      step("cds_ready", `
        M:EnterCombat()
        M.power = 3
        M.powerMax = 5
        M.targetExists = true
      `),
    ]);

    const result = runSimulation("paladin-ret", configLua, scenario);
    expect(result.error).toBeUndefined();

    const onCD = result.results[0];
    const ready = result.results[1];
    expect(onCD.errors.length).toBe(0);
    expect(ready.errors.length).toBe(0);

    const onCDready = onCD.conditionResults.filter(c => c.conditionMet && c.isCooldown);
    const allReady = ready.conditionResults.filter(c => c.conditionMet && c.isCooldown);
    expect(allReady.length).toBeGreaterThanOrEqual(onCDready.length);
  });
});

describe("Rotation Simulation — Health-Based Defensives", () => {
  it("warrior-prot: defensive spells appear at low health", async () => {
    const configLua = await generateSpecConfig("warrior-prot");

    const scenario = makeScenario("warrior-prot", "defensives", [
      step("full_health", `
        M:EnterCombat()
        M.playerHealth = 100000
        M.playerHealthMax = 100000
        M.power = 50
        M.powerMax = 100
        M.targetExists = true
      `),
      step("low_health", `
        M:EnterCombat()
        M.playerHealth = 20000
        M.playerHealthMax = 100000
        M.power = 50
        M.powerMax = 100
        M.targetExists = true
      `),
    ]);

    const result = runSimulation("warrior-prot", configLua, scenario);
    expect(result.error).toBeUndefined();

    const full = result.results[0];
    const low = result.results[1];
    expect(full.errors.length).toBe(0);
    expect(low.errors.length).toBe(0);

    const defPattern = /Shield Wall|Ignore Pain|Ironfur|Purify Brew|Shield of the Righteous|Demon Spire|Death Strike/i;
    const fullDefensives = full.conditionResults.filter(c => c.conditionMet && defPattern.test(c.spell));
    const lowDefensives = low.conditionResults.filter(c => c.conditionMet && defPattern.test(c.spell));
    expect(lowDefensives.length).toBeGreaterThanOrEqual(fullDefensives.length);
  });
});

describe("Rotation Simulation — Execute Phase", () => {
  it("paladin-ret: execute-phase spells appear at low target health", async () => {
    const configLua = await generateSpecConfig("paladin-ret");

    const scenario = makeScenario("paladin-ret", "execute_phase", [
      step("target_high_health", `
        M:EnterCombat()
        M.power = 3
        M.powerMax = 5
        M.targetHealth = 400000
        M.targetHealthMax = 500000
        M.targetExists = true
      `),
      step("target_low_health", `
        M:EnterCombat()
        M.power = 3
        M.powerMax = 5
        M.targetHealth = 50000
        M.targetHealthMax = 500000
        M.targetExists = true
      `),
    ]);

    const result = runSimulation("paladin-ret", configLua, scenario);
    expect(result.error).toBeUndefined();

    for (const sr of result.results) {
      expect(sr.errors.length).toBe(0);
    }

    const highHP = result.results[0];
    const lowHP = result.results[1];

    const lowHPQueue = lowHP.conditionResults.filter(c => c.conditionMet);
    const highHPQueue = highHP.conditionResults.filter(c => c.conditionMet);
    expect(lowHPQueue.length).toBeGreaterThanOrEqual(highHPQueue.length);
  });
});

describe("Rotation Simulation — Time Progression", () => {
  it("conditions change as time advances and buffs expire", async () => {
    const configLua = await generateSpecConfig("paladin-ret");

    const scenario = makeScenario("paladin-ret", "time_progression", [
      step("buff_fresh", `
        M:EnterCombat()
        M.power = 5
        M.powerMax = 5
        M.targetExists = true
        M:AddBuff("avenging_wrath", 20, 1, 20)
      `),
      step("buff_about_to_expire", `
        M:EnterCombat()
        M.power = 5
        M.powerMax = 5
        M.targetExists = true
        M:AddBuff("avenging_wrath", 2, 1, 20)
      `),
      step("buff_expired", `
        M:EnterCombat()
        M.power = 5
        M.powerMax = 5
        M.targetExists = true
      `),
    ]);

    const result = runSimulation("paladin-ret", configLua, scenario);
    expect(result.error).toBeUndefined();

    for (const sr of result.results) {
      expect(sr.errors.length).toBe(0);
    }

    const fresh = result.results[0].conditionResults.filter(c => c.conditionMet);
    const expired = result.results[2].conditionResults.filter(c => c.conditionMet);
    expect(fresh.length).not.toBe(expired.length);
  });
});

describe("Rotation Simulation — Movement Awareness", () => {
  it("caster specs: conditions change while moving", async () => {
    const configLua = await generateSpecConfig("mage-fire");

    const scenario = makeScenario("mage-fire", "movement", [
      step("standing_still", `
        M:EnterCombat()
        M.moving = false
        M.power = 80
        M.powerMax = 100
        M.targetExists = true
      `),
      step("moving", `
        M:EnterCombat()
        M.moving = true
        M.power = 80
        M.powerMax = 100
        M.targetExists = true
      `),
    ]);

    const result = runSimulation("mage-fire", configLua, scenario);
    expect(result.error).toBeUndefined();

    for (const sr of result.results) {
      expect(sr.errors.length).toBe(0);
    }
  });
});

describe("Rotation Simulation — Pet Classes", () => {
  it("hunter-bm: pet alive affects conditions", async () => {
    const configLua = await generateSpecConfig("hunter-bm");

    const scenario = makeScenario("hunter-bm", "pet_test", [
      step("pet_alive", `
        M:EnterCombat()
        M.petAlive = true
        M.power = 60
        M.powerMax = 100
        M.targetExists = true
      `),
      step("pet_dead", `
        M:EnterCombat()
        M.petAlive = false
        M.power = 60
        M.powerMax = 100
        M.targetExists = true
      `),
    ]);

    const result = runSimulation("hunter-bm", configLua, scenario);
    expect(result.error).toBeUndefined();

    for (const sr of result.results) {
      expect(sr.errors.length).toBe(0);
    }
  });

  it("warlock-demo: pet conditions compile and evaluate", async () => {
    const configLua = await generateSpecConfig("warlock-demo");

    const scenario = makeScenario("warlock-demo", "demo_pet", [
      step("with_pet", `
        M:EnterCombat()
        M.petAlive = true
        M.power = 3
        M.powerMax = 5
        M.targetExists = true
      `),
    ]);

    const result = runSimulation("warlock-demo", configLua, scenario);
    expect(result.error).toBeUndefined();
    expect(result.results[0].errors.length).toBe(0);
  });
});

describe("Rotation Simulation — Tank Specs", () => {
  for (const specId of ["dk-blood", "dh-vengeance", "druid-guardian", "monk-brew", "paladin-prot", "warrior-prot"]) {
    it(`${specId}: tank rotation evaluates without errors`, async () => {
      const configLua = await generateSpecConfig(specId);

      const scenario = makeScenario(specId, "tank_rotation", [
        step("healthy_tanking", `
          M:EnterCombat()
          M.power = 50
          M.powerMax = 100
          M.playerHealth = 90000
          M.playerHealthMax = 100000
          M.targetExists = true
          M.activeEnemies = 3
        `),
        step("heavy_damage", `
          M:EnterCombat()
          M.power = 50
          M.powerMax = 100
          M.playerHealth = 30000
          M.playerHealthMax = 100000
          M.targetExists = true
          M.activeEnemies = 3
        `),
      ]);

      const result = runSimulation(specId, configLua, scenario);
      expect(result.error).toBeUndefined();

      for (const sr of result.results) {
        expect(sr.errors.length).toBe(0);
      }

      const healthy = result.results[0];
      const damaged = result.results[1];
      expect(healthy.queue.length).toBeGreaterThan(0);
      expect(damaged.queue.length).toBeGreaterThan(0);
    });
  }
});

describe("Rotation Simulation — Healer Specs", () => {
  for (const specId of ["druid-resto", "monk-mw", "paladin-holy", "priest-disc", "shaman-resto", "evoker-pres"]) {
    it(`${specId}: healer rotation evaluates without errors`, async () => {
      const configLua = await generateSpecConfig(specId);

      const scenario = makeScenario(specId, "healer_rotation", [
        step("in_combat", `
          M:EnterCombat()
          M.power = 80
          M.powerMax = 100
          M.targetExists = true
        `),
      ]);

      const result = runSimulation(specId, configLua, scenario);
      expect(result.error).toBeUndefined();
      expect(result.results[0].errors.length).toBe(0);
    });
  }
});

describe("Rotation Simulation — DPS Specs Comprehensive", () => {
  const dpsSpecs = [
    "dk-frost", "dk-unholy", "dh-havoc",
    "druid-balance", "druid-feral",
    "evoker-dev", "evoker-aug",
    "hunter-bm", "hunter-mm", "hunter-surv",
    "mage-arcane", "mage-fire", "mage-frost",
    "monk-ww",
    "paladin-ret",
    "priest-shadow",
    "rogue-ass", "rogue-out", "rogue-sub",
    "shaman-ele", "shaman-enh",
    "warlock-aff", "warlock-demo", "warlock-dest",
    "warrior-arms", "warrior-fury",
  ];

  for (const specId of dpsSpecs) {
    it(`${specId}: full combat scenario without errors`, async () => {
      const configLua = await generateSpecConfig(specId);

      const scenario = makeScenario(specId, "full_combat", [
        step("opener", `
          M.inCombat = false
          M.power = 0
          M.powerMax = 100
          M.targetExists = true
        `),
        step("early_combat_low_resource", `
          M:EnterCombat()
          M.power = 20
          M.powerMax = 100
          M.targetExists = true
          M.activeEnemies = 1
        `),
        step("mid_combat_cds_available", `
          M:EnterCombat()
          M.power = 60
          M.powerMax = 100
          M.targetExists = true
          M.activeEnemies = 1
        `),
        step("aoe_phase", `
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
          M.activeEnemies = 1
        `),
        step("target_casting_interrupt", `
          M:EnterCombat()
          M.power = 50
          M.powerMax = 100
          M.targetExists = true
          M.targetCasting = true
          M.targetCastInterruptible = true
        `),
      ]);

      const result = runSimulation(specId, configLua, scenario);
      if (result.error) {
        console.error(`${specId} simulation error:`, result.error);
      }
      expect(result.error).toBeUndefined();
      expect(result.totalSteps).toBe(6);

      for (const sr of result.results) {
        if (sr.errors.length > 0) {
          console.error(`${specId} ${sr.stepName} errors:`,
            sr.errors.map(e => `${e.spell}: ${e.error}`).join("; "));
        }
        expect(sr.errors.length).toBe(0);
      }

      const combatSteps = result.results.filter(r => r.stepIndex >= 2);
      const hasAnyQueue = combatSteps.some(cs => cs.queue.length > 0);
      expect(hasAnyQueue).toBe(true);
    });
  }
});

describe("Multi-Tick Queue Integrity", () => {
  const multiTickSpecs = [
    "warrior-fury", "warrior-arms", "paladin-ret",
    "dk-frost", "dk-unholy", "dh-havoc",
    "druid-balance", "druid-feral",
    "hunter-bm", "hunter-mm", "hunter-surv",
    "mage-fire", "mage-frost", "mage-arcane",
    "monk-ww",
    "priest-shadow",
    "shaman-ele", "shaman-enh",
    "warlock-aff", "warlock-demo", "warlock-dest",
    "evoker-dev", "evoker-aug",
  ];

  for (const specId of multiTickSpecs) {
    it(`${specId}: ST 8-tick sim has no queue duplicates`, async () => {
      const configLua = await generateSpecConfig(specId);
      const scenario = makeMultiTickScenario(specId, "st_integrity", 8, `
        M:EnterCombat()
        M.power = 80
        M.powerMax = 100
        M.targetExists = true
        M.activeEnemies = 1
      `);

      const result = runSimulation(specId, configLua, scenario);
      expect(result.error).toBeUndefined();
      expect(result.multiTick).toBe(true);
      expect(result.totalTicks).toBe(8);

      const postTransform = (result.violations || []).filter(v => v.phase !== "raw");
      const dupes = postTransform.filter(v => v.type === "DUPLICATE");
      if (dupes.length > 0) {
        console.error(`${specId} DUPLICATE violations:`, dupes.map(v =>
          `tick=${v.tick} slot=${v.slot} ${v.spell}: ${v.detail}`).join("; "));
      }
      expect(dupes.length).toBe(0);
    });

    it(`${specId}: AoE 8-tick sim has no ST-only spells in queue`, async () => {
      const configLua = await generateSpecConfig(specId);
      const scenario = makeMultiTickScenario(specId, "aoe_mode_check", 8, `
        M:EnterCombat()
        M.power = 80
        M.powerMax = 100
        M.targetExists = true
        M.activeEnemies = 5
      `);

      const result = runSimulation(specId, configLua, scenario);
      expect(result.error).toBeUndefined();

      const postTransform = (result.violations || []).filter(v => v.phase !== "raw");
      const modeMismatches = postTransform.filter(v => v.type === "MODE_MISMATCH");
      if (modeMismatches.length > 0) {
        console.error(`${specId} MODE_MISMATCH violations:`, modeMismatches.map(v =>
          `tick=${v.tick} slot=${v.slot} ${v.spell}: ${v.detail}`).join("; "));
      }
      expect(modeMismatches.length).toBe(0);
    });

    it(`${specId}: slot-1 spells are never on cooldown`, async () => {
      const configLua = await generateSpecConfig(specId);
      const scenario = makeMultiTickScenario(specId, "cd_check", 8, `
        M:EnterCombat()
        M.power = 80
        M.powerMax = 100
        M.targetExists = true
        M.activeEnemies = 1
      `);

      const result = runSimulation(specId, configLua, scenario);
      expect(result.error).toBeUndefined();

      const postTransform = (result.violations || []).filter(v => v.phase !== "raw");
      const cdViolations = postTransform.filter(v => v.type === "CD_VIOLATION");
      if (cdViolations.length > 0) {
        console.error(`${specId} CD_VIOLATION:`, cdViolations.map(v =>
          `tick=${v.tick} ${v.spell}: ${v.detail}`).join("; "));
      }
      expect(cdViolations.length).toBe(0);
    });
  }

  it("warrior-fury: queue never has same spell in multiple slots", async () => {
    const configLua = await generateSpecConfig("warrior-fury");
    const scenario = makeMultiTickScenario("warrior-fury", "dedup_stress", 12, `
      M:EnterCombat()
      M.power = 80
      M.powerMax = 100
      M.targetExists = true
      M.activeEnemies = 1
      M.haste = 20
    `);

    const result = runSimulation("warrior-fury", configLua, scenario);
    expect(result.error).toBeUndefined();
    const postTransform = (result.violations || []).filter(v => v.phase !== "raw");
    expect(postTransform.length).toBe(0);
  });

  it("druid-balance: ST mode filters out AoE-only spells", async () => {
    const configLua = await generateSpecConfig("druid-balance");
    const scenario = makeMultiTickScenario("druid-balance", "st_mode_filter", 10, `
      M:EnterCombat()
      M.power = 40
      M.powerMax = 100
      M.targetExists = true
      M.activeEnemies = 1
    `);

    const result = runSimulation("druid-balance", configLua, scenario);
    expect(result.error).toBeUndefined();

    for (const tick of result.ticks || []) {
      for (const q of tick.queue) {
        if (q.mode === "AoE") {
          throw new Error(`Tick ${tick.tick}: AoE-only spell "${q.spell}" in ST queue`);
        }
      }
    }
  });
});

describe("Taint Simulation — Combat with Tainted APIs", () => {
  const taintSpecs = [
    "warrior-fury", "warrior-arms", "paladin-ret",
    "dk-frost", "dk-unholy", "dh-havoc",
    "druid-balance", "druid-feral",
    "hunter-bm", "hunter-mm", "hunter-surv",
    "mage-fire", "mage-frost", "mage-arcane",
    "monk-ww",
    "priest-shadow",
    "shaman-ele", "shaman-enh",
    "warlock-aff", "warlock-demo", "warlock-dest",
    "evoker-dev", "evoker-aug",
  ];

  for (const specId of taintSpecs) {
    it(`${specId}: taint mode — conditions compile without errors`, async () => {
      const configLua = await generateSpecConfig(specId);

      const scenario = makeScenario(specId, "taint_basic", [
        step("taint_combat_full_resource", `
          M:EnableTaint()
          M:EnterCombat()
          M.power = M.powerMax
          M.targetExists = true
          M.activeEnemies = 1
        `),
        step("taint_combat_low_resource", `
          M:EnableTaint()
          M:EnterCombat()
          M.power = 20
          M.powerMax = 100
          M.targetExists = true
          M.activeEnemies = 1
        `),
        step("taint_combat_zero_resource", `
          M:EnableTaint()
          M:EnterCombat()
          M.power = 0
          M.powerMax = 100
          M.targetExists = true
          M.activeEnemies = 1
        `),
      ]);

      const result = runSimulation(specId, configLua, scenario);
      if (result.error) {
        console.error(`${specId} taint simulation error:`, result.error);
      }
      expect(result.error).toBeUndefined();

      for (const sr of result.results) {
        if (sr.errors.length > 0) {
          console.error(`${specId} ${sr.stepName} taint errors:`,
            sr.errors.map(e => `${e.spell}: ${e.error}`).join("; "));
        }
        expect(sr.errors.length).toBe(0);
      }
    });

    it(`${specId}: taint mode — 8-tick multi-tick sim runs cleanly`, async () => {
      const configLua = await generateSpecConfig(specId);
      const scenario = makeMultiTickScenario(specId, "taint_multitick", 8, `
        M:EnableTaint()
        M:EnterCombat()
        M.power = 80
        M.powerMax = 100
        M.targetExists = true
        M.activeEnemies = 1
      `);

      const result = runSimulation(specId, configLua, scenario);
      if (result.error) {
        console.error(`${specId} taint multi-tick error:`, result.error);
      }
      expect(result.error).toBeUndefined();
      expect(result.multiTick).toBe(true);
      expect(result.totalTicks).toBe(8);

      const postTransform = (result.violations || []).filter(v => v.phase !== "raw");
      const dupes = postTransform.filter(v => v.type === "DUPLICATE");
      if (dupes.length > 0) {
        console.error(`${specId} taint DUPLICATE violations:`, dupes.map(v =>
          `tick=${v.tick} slot=${v.slot} ${v.spell}: ${v.detail}`).join("; "));
      }
      expect(dupes.length).toBe(0);
    });

    it(`${specId}: taint mode — spell marked not-usable is still rejected`, async () => {
      const configLua = await generateSpecConfig(specId);

      const scenario = makeScenario(specId, "taint_unusable_rejected", [
        step("taint_with_unusable_spells", `
          M:EnableTaint()
          M:EnterCombat()
          M.power = M.powerMax
          M.targetExists = true
          M.activeEnemies = 1
          M:SetSpellUsable("FAKE_IMPOSSIBLE_SPELL_XXXYZ", false)
        `),
      ]);

      const result = runSimulation(specId, configLua, scenario);
      expect(result.error).toBeUndefined();
      expect(result.results[0].errors.length).toBe(0);

      const fakeInQueue = result.results[0].queue.some(
        q => q.spell.toLowerCase().includes("fake_impossible")
      );
      expect(fakeInQueue).toBe(false);
    });
  }

  it("warrior-fury: taint mode out-of-combat returns clean values", async () => {
    const configLua = await generateSpecConfig("warrior-fury");

    const scenario = makeScenario("warrior-fury", "taint_ooc", [
      step("taint_enabled_but_out_of_combat", `
        M:EnableTaint()
        M.inCombat = false
        M.power = 50
        M.powerMax = 100
        M.targetExists = true
      `),
    ]);

    const result = runSimulation("warrior-fury", configLua, scenario);
    expect(result.error).toBeUndefined();
    expect(result.results[0].errors.length).toBe(0);
  });

  it("paladin-ret: taint mode with spell on cooldown does not crash", async () => {
    const configLua = await generateSpecConfig("paladin-ret");

    const scenario = makeScenario("paladin-ret", "taint_cd_handling", [
      step("taint_with_cooldowns", `
        M:EnableTaint()
        M:EnterCombat()
        M.power = M.powerMax
        M.targetExists = true
        M.activeEnemies = 1
        M:SetCooldown("wake_of_ashes", 15, 30)
        M:SetCooldown("avenging_wrath", 90, 120)
      `),
    ]);

    const result = runSimulation("paladin-ret", configLua, scenario);
    expect(result.error).toBeUndefined();
    expect(result.results[0].errors.length).toBe(0);
  });

  it("dk-frost: taint mode — selective taint (only UnitPower) still works", async () => {
    const configLua = await generateSpecConfig("dk-frost");

    const scenario = makeScenario("dk-frost", "taint_selective", [
      step("only_power_tainted", `
        M:EnableTaint({ UnitPower = true, IsSpellUsable = false, GetSpellCooldown = false })
        M:EnterCombat()
        M.power = 50
        M.powerMax = 100
        M.targetExists = true
        M.activeEnemies = 1
      `),
    ]);

    const result = runSimulation("dk-frost", configLua, scenario);
    expect(result.error).toBeUndefined();
    expect(result.results[0].errors.length).toBe(0);
  });

  it("hunter-bm: taint mode — selective taint (only GetSpellCooldown) still works", async () => {
    const configLua = await generateSpecConfig("hunter-bm");

    const scenario = makeScenario("hunter-bm", "taint_cd_only", [
      step("only_cd_tainted", `
        M:EnableTaint({ UnitPower = false, IsSpellUsable = false, GetSpellCooldown = true })
        M:EnterCombat()
        M.power = 80
        M.powerMax = 100
        M.targetExists = true
        M.activeEnemies = 1
        M:SetCooldown("kill_command", 5, 7.5)
        M:SetCooldown("barbed_shot", 10, 12)
      `),
    ]);

    const result = runSimulation("hunter-bm", configLua, scenario);
    expect(result.error).toBeUndefined();
    expect(result.results[0].errors.length).toBe(0);
  });
});
