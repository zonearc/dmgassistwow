import { COMMUNITY_APLS } from "./community-apls";
import { getSpecSpells, simulatePriority, type SpellState, type SimResult } from "./priority-simulator";

export interface ScenarioResult {
  scenarioName: string;
  description: string;
  combatMode: "ST" | "AoE";
  results: SimResult[];
  anomalies: Anomaly[];
  topQueue: string[];
  passed: boolean;
}

export interface Anomaly {
  severity: "error" | "warning" | "info";
  rule: string;
  message: string;
  spellName?: string;
  details?: string;
}

export interface TimelineEntry {
  time: number;
  castSpell: string;
  slot1: string;
  slot2: string;
  slot3: string;
  scores: Record<string, number>;
  cdStates: Record<string, number>;
  acState?: string;
  resources?: { primary: number; secondary?: number; primaryType: string; secondaryType?: string };
  resourceBlocked?: string;
}

export interface TimelineAnomaly extends Anomaly {
  time?: number;
}

export interface TimelineResult {
  scenarioName: string;
  description: string;
  combatMode: "ST" | "AoE";
  duration: number;
  timeline: TimelineEntry[];
  castHistory: Record<string, number[]>;
  anomalies: TimelineAnomaly[];
  spellStats: SpellStat[];
  passed: boolean;
}

export interface SpellStat {
  spellName: string;
  totalCasts: number;
  timesInSlot1: number;
  firstSlot1Time: number | null;
  avgGapBetweenCasts: number | null;
  longestDrought: number;
  isCD: boolean;
  cdDuration: number;
  mode: string;
  priority: number;
}

export interface SpecValidation {
  specId: string;
  specLabel: string;
  spellCount: number;
  cdCount: number;
  scenarios: ScenarioResult[];
  timelineResults: TimelineResult[];
  totalAnomalies: number;
  errors: number;
  warnings: number;
  passed: boolean;
}

export interface BatchResult {
  timestamp: string;
  duration: number;
  totalSpecs: number;
  passedSpecs: number;
  failedSpecs: number;
  totalAnomalies: number;
  totalErrors: number;
  specs: SpecValidation[];
}

const SPEC_LABELS: Record<string, string> = {
  "druid-balance": "Balance Druid",
  "rogue-ass": "Assassination Rogue",
  "evoker-aug": "Augmentation Evoker",
  "dk-blood": "Blood Death Knight",
  "dh-vengeance": "Vengeance Demon Hunter",
  "druid-guardian": "Guardian Druid",
  "monk-brew": "Brewmaster Monk",
  "paladin-prot": "Protection Paladin",
  "warrior-prot": "Protection Warrior",
  "druid-resto": "Restoration Druid",
  "evoker-pres": "Preservation Evoker",
  "monk-mw": "Mistweaver Monk",
  "paladin-holy": "Holy Paladin",
  "priest-disc": "Discipline Priest",
  "priest-holy": "Holy Priest",
  "shaman-resto": "Restoration Shaman",
};

const KNOWN_CD_DURATIONS: Record<string, number> = {
  "convoke the spirits": 120,
  "celestial alignment": 180,
  "incarnation chosen of elune": 180,
  "incarnation: chosen of elune": 180,
  "fury of elune": 60,
  "force of nature": 60,
  "new moon": 20,
  "half moon": 20,
  "full moon": 20,
  "lunar eclipse": 15,
  "wild mushroom": 30,
  "starfall": 20,
  "deathmark": 120,
  "kingsbane": 45,
  "garrote": 15,
  "indiscriminate carnage": 45,
  "thistle tea": 60,
  "vanish": 120,
  "shiv": 25,
  "breath of eons": 120,
  "deep breath": 120,
  "ebon might": 30,
  "time skip": 180,
  "prescience": 12,
  "blistering scales": 30,
  "tip the scales": 120,
  "spatial paradox": 120,
  "upheaval": 40,
  "eruption": 0,
  "fire breath": 30,
  "living flame": 0,
  "dancing rune weapon": 120,
  "vampiric blood": 90,
  "icebound fortitude": 180,
  "bonestorm": 60,
  "blood boil": 8,
  "marrowrend": 0,
  "deaths caress": 0,
  "death's caress": 0,
  "heart strike": 0,
  "death strike": 0,
  "death and decay": 30,
  "consumption": 45,
  "raise dead": 120,
  "metamorphosis": 180,
  "fiery brand": 60,
  "fel devastation": 60,
  "sigil of flame": 30,
  "sigil of spite": 60,
  "soul carver": 60,
  "felblade": 15,
  "the hunt": 90,
  "elysian decree": 60,
  "immolation aura": 30,
  "soul cleave": 0,
  "fracture": 0,
  "spirit bomb": 0,
  "throw glaive": 0,
  "incarnation guardian of ursoc": 180,
  "incarnation: guardian of ursoc": 180,
  "rage of the sleeper": 90,
  "berserk": 180,
  "barkskin": 60,
  "ironfur": 0,
  "mangle": 6,
  "thrash": 6,
  "swipe": 0,
  "maul": 0,
  "moonfire": 0,
  "touch of death": 180,
  "keg smash": 8,
  "breath of fire": 15,
  "exploding keg": 60,
  "purifying brew": 20,
  "invoke niuzao the black ox": 180,
  "invoke niuzao, the black ox": 180,
  "weapons of order": 120,
  "bonedust brew": 60,
  "blackout kick": 0,
  "tiger palm": 0,
  "spinning crane kick": 0,
  "rushing jade wind": 6,
  "chi burst": 30,
  "celestial brew": 60,
  "avengers shield": 15,
  "avenger's shield": 15,
  "ardent defender": 120,
  "guardian of ancient kings": 300,
  "sentinel": 150,
  "eye of tyr": 60,
  "hammer of light": 30,
  "judgment": 12,
  "hammer of the righteous": 6,
  "blessed hammer": 6,
  "shield of the righteous": 0,
  "word of glory": 0,
  "consecration": 9,
  "holy shield": 0,
  "shield slam": 9,
  "thunder clap": 6,
  "shield charge": 45,
  "champions spear": 90,
  "champion's spear": 90,
  "shield wall": 210,
  "last stand": 180,
  "avatar": 90,
  "ravager": 90,
  "shield block": 16,
  "thunderous roar": 90,
  "execute": 0,
  "revenge": 0,
  "devastate": 0,
  "ignore pain": 0,
  "spell reflection": 25,
  "incarnation tree of life": 180,
  "incarnation: tree of life": 180,
  "efflorescence": 0,
  "swiftmend": 15,
  "wild growth": 10,
  "lifebloom": 0,
  "rejuvenation": 0,
  "regrowth": 0,
  "wrath": 0,
  "tranquility": 180,
  "flourish": 90,
  "ironbark": 90,
  "natures swiftness": 60,
  "nature's swiftness": 60,
  "rewind": 240,
  "reversion": 9,
  "dream breath": 30,
  "spiritbloom": 30,
  "temporal anomaly": 15,
  "echo": 0,
  "emerald blossom": 0,
  "azure strike": 0,
  "verdant embrace": 24,
  "stasis": 90,
  "dream flight": 120,
  "life cocoon": 120,
  "enveloping mist": 0,
  "renewing mist": 9,
  "rising sun kick": 12,
  "thunder focus tea": 30,
  "revival": 180,
  "invoke yulon the jade serpent": 180,
  "invoke yu'lon, the jade serpent": 180,
  "invoke chi-ji the red crane": 180,
  "invoke chi-ji, the red crane": 180,
  "sheiluns gift": 12,
  "sheilun's gift": 12,
  "vivify": 0,
  "holy light": 0,
  "flash of light": 0,
  "holy shock": 7.5,
  "light of dawn": 0,
  "hammer of wrath": 7.5,
  "beacon of light": 0,
  "avenging wrath": 120,
  "divine toll": 60,
  "holy prism": 20,
  "lights hammer": 60,
  "light's hammer": 60,
  "daybreak": 60,
  "lay on hands": 600,
  "halo": 40,
  "holy fire": 10,
  "holy nova": 0,
  "power word shield": 7.5,
  "power word: shield": 7.5,
  "penance": 9,
  "shadow word death": 20,
  "shadow word: death": 20,
  "mind blast": 24,
  "schism": 24,
  "rapture": 90,
  "power word: barrier": 180,
  "pain suppression": 120,
  "evangelism": 90,
  "power word: radiance": 20,
  "purge the wicked": 0,
  "shadow word: pain": 0,
  "smite": 0,
  "renew": 0,
  "prayer of mending": 12,
  "circle of healing": 15,
  "divine hymn": 180,
  "holy word: serenity": 60,
  "holy word: sanctify": 60,
  "holy word: salvation": 360,
  "holy word: chastise": 60,
  "guardian spirit": 180,
  "apotheosis": 120,
  "surge of light": 0,
  "flash heal": 0,
  "heal": 0,
  "prayer of healing": 0,
  "riptide": 6,
  "healing rain": 10,
  "healing wave": 0,
  "healing surge": 0,
  "chain heal": 0,
  "healing stream totem": 30,
  "healing tide totem": 180,
  "spirit link totem": 180,
  "ascendance": 180,
  "primordial wave": 45,
  "earthen wall totem": 60,
  "cloudburst totem": 30,
  "unleash life": 15,
  "earth shield": 0,
  "water shield": 0,
  "flame shock": 6,
  "lava burst": 8,
  "lightning bolt": 0,
  "sunfire": 0,
};

function getSpellCDDuration(spellName: string, isCooldown: boolean): number {
  const clean = spellName.toLowerCase().replace(/'/g, "").replace(/:/g, "").replace(/_/g, " ").trim();
  const dur = KNOWN_CD_DURATIONS[clean];
  if (dur !== undefined) return dur;
  if (isCooldown) return 30;
  return 0;
}

function cloneSpells(spells: SpellState[]): SpellState[] {
  return spells.map(s => ({ ...s }));
}

interface ResourceConfig {
  primary: { type: string; max: number; regen: number };
  secondary?: { type: string; max: number };
}

const SPEC_RESOURCES: Record<string, ResourceConfig> = {
  "rogue-ass":       { primary: { type: "Energy",      max: 100, regen: 13  }, secondary: { type: "Combo Points", max: 7 } },
  "dk-blood":        { primary: { type: "Runic Power", max: 100, regen: 0   }, secondary: { type: "Runes",        max: 6 } },
  "dh-vengeance":    { primary: { type: "Fury",        max: 120, regen: 0   } },
  "druid-balance":   { primary: { type: "Astral Power", max: 100, regen: 0  } },
  "druid-guardian":  { primary: { type: "Rage",        max: 100, regen: 0   } },
  "druid-resto":     { primary: { type: "Mana",        max: 50000, regen: 400 } },
  "monk-brew":       { primary: { type: "Energy",      max: 100, regen: 13  } },
  "monk-mw":         { primary: { type: "Mana",        max: 50000, regen: 400 } },
  "paladin-prot":    { primary: { type: "Mana",        max: 50000, regen: 400 }, secondary: { type: "Holy Power", max: 5 } },
  "paladin-holy":    { primary: { type: "Mana",        max: 50000, regen: 400 }, secondary: { type: "Holy Power", max: 5 } },
  "warrior-prot":    { primary: { type: "Rage",        max: 100, regen: 0   } },
  "priest-disc":     { primary: { type: "Mana",        max: 50000, regen: 400 } },
  "priest-holy":     { primary: { type: "Mana",        max: 50000, regen: 400 } },
  "shaman-resto":    { primary: { type: "Mana",        max: 50000, regen: 400 } },
  "evoker-aug":      { primary: { type: "Mana",        max: 50000, regen: 400 }, secondary: { type: "Essence", max: 5 } },
  "evoker-pres":     { primary: { type: "Mana",        max: 50000, regen: 400 }, secondary: { type: "Essence", max: 5 } },
};

interface SpellCost {
  primary?: number;
  secondaryCost?: number;
  secondaryGain?: number;
  primaryGain?: number;
}

const SPELL_COSTS: Record<string, SpellCost> = {
  "mutilate":           { primary: 50, secondaryGain: 2 },
  "ambush":             { primary: 50, secondaryGain: 2 },
  "fan of knives":      { primary: 35, secondaryGain: 1 },
  "garrote":            { primary: 45, secondaryGain: 1 },
  "envenom":            { primary: 35, secondaryCost: 4 },
  "rupture":            { primary: 25, secondaryCost: 4 },
  "crimson tempest":    { primary: 35, secondaryCost: 4 },
  "shiv":               { primary: 20 },
  "thistle tea":        { primaryGain: 50 },
  "heart strike":       { secondaryGain: 1, primaryGain: 15 },
  "marrowrend":         { secondaryGain: 3, primaryGain: 20 },
  "deaths caress":      { secondaryGain: 1, primaryGain: 10 },
  "death's caress":     { secondaryGain: 1, primaryGain: 10 },
  "blood boil":         { primaryGain: 10 },
  "death strike":       { primary: 40 },
  "bonestorm":          { primary: 10 },
  "dancing rune weapon": {},
  "vampiric blood":     {},
  "soul cleave":        { primary: 30 },
  "fracture":           { primaryGain: 25 },
  "spirit bomb":        { primary: 40 },
  "throw glaive":       {},
  "immolation aura":    { primaryGain: 20 },
  "sigil of flame":     { primaryGain: 10 },
  "the hunt":           { primaryGain: 30 },
  "fel devastation":    { primary: 50 },
  "wrath":              { primaryGain: 8 },
  "starfire":           { primaryGain: 10 },
  "lunar eclipse":      { primaryGain: 8 },
  "starsurge":          { primary: 40 },
  "starfall":           { primary: 50 },
  "moonfire":           { primaryGain: 2 },
  "sunfire":            { primaryGain: 2 },
  "mangle":             { primaryGain: 10 },
  "thrash":             { primaryGain: 5 },
  "swipe":              { primaryGain: 5 },
  "maul":               { primary: 40 },
  "ironfur":            { primary: 40 },
  "keg smash":          { primary: 40 },
  "breath of fire":     { primary: 20 },
  "blackout kick":      { primary: 15 },
  "tiger palm":         { primary: 25 },
  "spinning crane kick": { primary: 25 },
  "celestial brew":     {},
  "purifying brew":     {},
  "judgment":           { secondaryGain: 1 },
  "hammer of the righteous": { secondaryGain: 1 },
  "blessed hammer":     { secondaryGain: 1 },
  "avengers shield":    { secondaryGain: 1 },
  "avenger's shield":   { secondaryGain: 1 },
  "holy shock":         { secondaryGain: 1 },
  "crusader strike":    { secondaryGain: 1 },
  "hammer of wrath":    { secondaryGain: 1 },
  "shield of the righteous": { secondaryCost: 3 },
  "word of glory":      { secondaryCost: 3 },
  "light of dawn":      { secondaryCost: 3 },
  "shield slam":        { primaryGain: 15 },
  "thunder clap":       { primaryGain: 5 },
  "revenge":            { primary: 20 },
  "devastate":          { primaryGain: 5 },
  "ignore pain":        { primary: 40 },
  "shield charge":      { primaryGain: 20 },
  "avatar":             {},
  "ravager":            {},
  "eruption":           { secondaryCost: 1 },
  "upheaval":           { secondaryCost: 1 },
  "fire breath":        { secondaryCost: 1 },
  "living flame":       {},
  "prescience":         {},
  "ebon might":         {},
  "breath of eons":     {},
  "blistering scales":  {},
  "azure strike":       {},
  "emerald blossom":    { secondaryCost: 1 },
  "spiritbloom":        { secondaryCost: 1 },
  "dream breath":       { secondaryCost: 1 },
  "verdant embrace":    {},
  "echo":               {},
  "reversion":          {},
  "smite":              {},
  "penance":            {},
  "power word shield":  {},
  "power word: shield": {},
  "purge the wicked":   {},
  "shadow word: pain":  {},
  "mind blast":         {},
  "shadow word death":  {},
  "shadow word: death": {},
  "power word: radiance": {},
  "flash heal":         {},
  "heal":               {},
  "prayer of mending":  {},
  "circle of healing":  {},
  "renew":              {},
  "prayer of healing":  {},
  "holy light":         {},
  "flash of light":     {},
  "riptide":            {},
  "healing wave":       {},
  "healing surge":      {},
  "chain heal":         {},
  "flame shock":        {},
  "lava burst":         {},
  "lightning bolt":     {},
  "unleash life":       {},
  "earth shield":       {},
};

const MAINTENANCE_BUFF_DURATIONS: Record<string, number> = {
  "rupture": 16,
  "garrote": 15,
  "moonfire": 18,
  "sunfire": 18,
  "stellar flare": 20,
  "flame shock": 18,
  "shadow word pain": 16,
  "shadow word: pain": 16,
  "purge the wicked": 16,
  "vampiric touch": 21,
  "consecration": 12,
  "efflorescence": 30,
  "lifebloom": 15,
  "earth shield": 600,
  "bone shield": 30,
  "rejuvenation": 12,
  "renew": 15,
  "riptide": 18,
  "shield of the righteous": 4.5,
  "ironfur": 7,
  "death and decay": 10,
  "demon spikes": 6,
};

function getMaintenanceDuration(spellName: string): number {
  const clean = spellName.toLowerCase().replace(/'/g, "").replace(/:/g, "").replace(/_/g, " ").trim();
  return MAINTENANCE_BUFF_DURATIONS[clean] || 0;
}

function getSpellCost(spellName: string): SpellCost {
  const clean = spellName.toLowerCase().replace(/'/g, "").replace(/:/g, "").replace(/_/g, " ").trim();
  return SPELL_COSTS[clean] || {};
}

interface ResourceState {
  primary: number;
  secondary: number;
}

function simulateResources(
  specId: string,
  spellName: string,
  res: ResourceState,
  cfg: ResourceConfig,
): { canCast: boolean; reason: string } {
  const cost = getSpellCost(spellName);
  if (cost.primary && cost.primary > res.primary) {
    return { canCast: false, reason: `needs ${cost.primary} ${cfg.primary.type} (have ${Math.floor(res.primary)})` };
  }
  if (cost.secondaryCost && cfg.secondary && cost.secondaryCost > res.secondary) {
    return { canCast: false, reason: `needs ${cost.secondaryCost} ${cfg.secondary.type} (have ${res.secondary})` };
  }
  return { canCast: true, reason: "" };
}

function applyResourceEffect(spellName: string, res: ResourceState, cfg: ResourceConfig): void {
  const cost = getSpellCost(spellName);
  if (cost.primary) res.primary = Math.max(0, res.primary - cost.primary);
  if (cost.primaryGain) res.primary = Math.min(cfg.primary.max, res.primary + cost.primaryGain);
  if (cost.secondaryCost && cfg.secondary) res.secondary = Math.max(0, res.secondary - cost.secondaryCost);
  if (cost.secondaryGain && cfg.secondary) res.secondary = Math.min(cfg.secondary.max, res.secondary + cost.secondaryGain);
}

function regenResources(res: ResourceState, cfg: ResourceConfig, dt: number): void {
  if (cfg.primary.regen > 0) {
    res.primary = Math.min(cfg.primary.max, res.primary + cfg.primary.regen * dt);
  }
  if (cfg.primary.type === "Rage" || cfg.primary.type === "Fury") {
    res.primary = Math.min(cfg.primary.max, res.primary + 3 * dt);
  }
  if (cfg.secondary && cfg.secondary.type === "Runes") {
    if (res.secondary < cfg.secondary.max) {
      res.secondary = Math.min(cfg.secondary.max, res.secondary + dt / 10 * 2);
    }
  }
  if (cfg.secondary && cfg.secondary.type === "Essence") {
    if (res.secondary < cfg.secondary.max) {
      res.secondary = Math.min(cfg.secondary.max, res.secondary + dt / 9);
    }
  }
}

const GCD = 1.5;
const COMBAT_DURATION = 300;

interface CombatSpell {
  spellName: string;
  priority: number;
  mode: "ST" | "AoE" | "Both";
  isCooldown: boolean;
  cdDuration: number;
  cdReadyAt: number;
  lastCastTime: number;
  castCount: number;
  slot1Count: number;
  firstSlot1Time: number | null;
  isOffensive: boolean;
}

function runTimelineSim(
  specId: string,
  combatMode: "ST" | "AoE",
  baseSpells: SpellState[],
  acConfig?: { spellName: string; signal: "ants" | "assisted"; startTime: number; endTime: number },
): { timeline: TimelineEntry[]; combatSpells: CombatSpell[]; resourceSkips: ResourceSkip[] } {
  const combatSpells: CombatSpell[] = [];
  const seen = new Set<string>();

  for (const s of baseSpells) {
    const cn = s.spellName.toLowerCase();
    if (seen.has(cn)) continue;
    seen.add(cn);
    const realCD = getSpellCDDuration(s.spellName, s.isCooldown);
    combatSpells.push({
      spellName: s.spellName,
      priority: s.priority,
      mode: s.mode,
      isCooldown: s.isCooldown || realCD >= 8,
      cdDuration: realCD,
      cdReadyAt: 0,
      lastCastTime: -999,
      castCount: 0,
      slot1Count: 0,
      firstSlot1Time: null,
      isOffensive: s.isOffensive,
    });
  }

  const resCfg = SPEC_RESOURCES[specId];
  const res: ResourceState = resCfg
    ? { primary: resCfg.primary.max, secondary: resCfg.secondary ? Math.floor(resCfg.secondary.max / 2) : 0 }
    : { primary: 0, secondary: 0 };
  const resourceSkips: ResourceSkip[] = [];
  const maintenanceAppliedAt: Record<string, number> = {};

  const timeline: TimelineEntry[] = [];

  for (let t = 0; t < COMBAT_DURATION; t += GCD) {
    if (resCfg) regenResources(res, resCfg, GCD);

    const frameSpells: SpellState[] = combatSpells.map(cs => {
      const onCD = cs.cdDuration > 0 && t < cs.cdReadyAt;
      const cdRemaining = onCD ? cs.cdReadyAt - t : 0;

      let isAnts = false;
      let isAcRecommended = false;
      if (acConfig && t >= acConfig.startTime && t < acConfig.endTime) {
        if (cs.spellName.toLowerCase() === acConfig.spellName.toLowerCase()) {
          if (acConfig.signal === "ants") isAnts = true;
          else isAcRecommended = true;
        }
      }

      const maintDur = getMaintenanceDuration(cs.spellName);
      let maintActive = false;
      if (maintDur > 0) {
        const maintKey = cs.spellName.toLowerCase().replace(/'/g, "").replace(/:/g, "").replace(/_/g, " ").trim();
        const lastApplied = maintenanceAppliedAt[maintKey];
        if (lastApplied !== undefined) {
          const pandemic = Math.min(maintDur * 0.3, 6);
          const elapsed = t - lastApplied;
          if (elapsed < maintDur - pandemic) {
            maintActive = true;
          }
        }
      }

      return {
        spellName: cs.spellName,
        spellId: 0,
        priority: cs.priority,
        mode: cs.mode,
        isCooldown: cs.isCooldown,
        isOffensive: cs.isOffensive,
        isInterrupt: false,
        cdReady: !onCD,
        cdRemaining,
        cdDuration: cs.cdDuration,
        isUsable: !onCD && !maintActive,
        isAcRecommended,
        isAnts,
        isProc: false,
        conditionMet: !maintActive,
      };
    });

    const results = simulatePriority(specId, combatMode, frameSpells);
    const usable = results.filter(r => r.score < 9000);

    let castSpell = "(none)";
    let blockedSpell: string | undefined;
    let blockedReason: string | undefined;
    if (resCfg) {
      for (const r of usable) {
        if (r.modeMismatch) continue;
        const check = simulateResources(specId, r.spellName, res, resCfg);
        if (check.canCast) {
          castSpell = r.spellName;
          break;
        } else {
          if (!blockedSpell) {
            blockedSpell = r.spellName;
            blockedReason = check.reason;
          }
        }
      }
    } else {
      const modeFiltered = usable.filter(r => !r.modeMismatch);
      castSpell = modeFiltered[0]?.spellName || usable[0]?.spellName || "(none)";
    }

    const slot1 = usable[0]?.spellName || "(none)";
    const slot2 = usable[1]?.spellName || "(none)";
    const slot3 = usable[2]?.spellName || "(none)";

    const scores: Record<string, number> = {};
    const cdStatesBeforeCast: Record<string, number> = {};
    for (const r of results) {
      scores[r.spellName] = r.score;
    }
    for (const c of combatSpells) {
      if (c.cdDuration > 0) {
        cdStatesBeforeCast[c.spellName] = Math.max(0, c.cdReadyAt - t);
      }
    }

    for (let i = 0; i < combatSpells.length; i++) {
      if (combatSpells[i].spellName === slot1) {
        combatSpells[i].slot1Count++;
        if (combatSpells[i].firstSlot1Time === null) {
          combatSpells[i].firstSlot1Time = t;
        }
      }
    }

    if (blockedSpell && castSpell !== blockedSpell) {
      resourceSkips.push({ time: t, spellName: blockedSpell, reason: blockedReason || "", castInstead: castSpell });
    }

    const cs = combatSpells.find(c => c.spellName === castSpell);
    if (cs) {
      cs.castCount++;
      cs.lastCastTime = t;
      if (cs.cdDuration > 0) {
        cs.cdReadyAt = t + cs.cdDuration;
      }
      const maintDur = getMaintenanceDuration(cs.spellName);
      if (maintDur > 0) {
        const maintKey = cs.spellName.toLowerCase().replace(/'/g, "").replace(/:/g, "").replace(/_/g, " ").trim();
        maintenanceAppliedAt[maintKey] = t;
      }
    }

    if (resCfg && castSpell !== "(none)") {
      applyResourceEffect(castSpell, res, resCfg);
    }

    const resSnapshot = resCfg ? {
      primary: Math.floor(res.primary),
      primaryType: resCfg.primary.type,
      ...(resCfg.secondary ? { secondary: res.secondary, secondaryType: resCfg.secondary.type } : {}),
    } : undefined;

    timeline.push({
      time: Math.round(t * 10) / 10,
      castSpell,
      slot1,
      slot2,
      slot3,
      scores,
      cdStates: cdStatesBeforeCast,
      acState: acConfig && t >= acConfig.startTime && t < acConfig.endTime
        ? `${acConfig.signal}:${acConfig.spellName}` : undefined,
      resources: resSnapshot,
      resourceBlocked: blockedSpell && castSpell !== blockedSpell ? `${blockedSpell}: ${blockedReason}` : undefined,
    });
  }

  return { timeline, combatSpells, resourceSkips };
}

interface ResourceSkip {
  time: number;
  spellName: string;
  reason: string;
  castInstead: string;
}

const MAINTENANCE_SPELLS = new Set([
  "moonfire", "sunfire", "flame shock", "rupture", "garrote",
  "rejuvenation", "lifebloom", "renew", "earth shield", "beacon of light",
  "purge the wicked", "shadow word: pain", "efflorescence", "echo",
  "enveloping mist", "renewing mist", "riptide", "reversion",
  "ironfur", "consecration", "immolation aura", "bone shield",
  "shield of the righteous", "ignore pain", "thunder clap",
]);

function isMaintenance(name: string): boolean {
  return MAINTENANCE_SPELLS.has(name.toLowerCase());
}

function analyzeTimeline(
  combatSpells: CombatSpell[],
  timeline: TimelineEntry[],
  combatMode: "ST" | "AoE",
  scenarioName: string,
  resourceSkips?: ResourceSkip[],
): TimelineAnomaly[] {
  const anomalies: TimelineAnomaly[] = [];
  const relevantSpells = combatSpells.filter(cs => cs.mode === "Both" || cs.mode === combatMode);

  // ── R1: SPELL_NEVER_CAST ──
  const castSpellNames = new Set(relevantSpells.filter(cs => cs.castCount > 0).map(cs => cs.spellName.toLowerCase()));
  for (const cs of relevantSpells) {
    if (cs.castCount === 0 && !cs.isCooldown) {
      const hasHigherPrioSameMode = relevantSpells.some(other =>
        other.castCount > 0 && other.priority < cs.priority && !other.isCooldown &&
        (other.mode === cs.mode || other.mode === "Both" || cs.mode === "Both")
      );
      const isLowPrio = cs.priority >= 50;
      const sev = (hasHigherPrioSameMode || isLowPrio) ? "warning" : "error";
      anomalies.push({
        severity: sev,
        rule: "SPELL_NEVER_CAST",
        message: `"${cs.spellName}" (P${cs.priority}, ${cs.mode}) was NEVER cast in ${COMBAT_DURATION}s of combat`,
        spellName: cs.spellName,
        details: `priority=${cs.priority}, mode=${cs.mode}, combatMode=${combatMode}${hasHigherPrioSameMode ? ", outcompeted by higher-prio spell" : ""}`,
      });
    }
  }

  // ── R2: SPELL_NEVER_SLOT1 ──
  for (const cs of relevantSpells) {
    if (cs.slot1Count === 0) {
      const hasHigherPrioSameMode = relevantSpells.some(other =>
        other.slot1Count > 0 && other.priority < cs.priority &&
        (other.mode === cs.mode || other.mode === "Both" || cs.mode === "Both")
      );
      const isLowPrio = cs.priority >= 50;
      let sev: "error" | "warning" | "info" = cs.isCooldown && cs.cdDuration > COMBAT_DURATION ? "info" : cs.isCooldown ? "warning" : "error";
      if (sev === "error" && (hasHigherPrioSameMode || isLowPrio)) sev = "warning";
      anomalies.push({
        severity: sev,
        rule: "SPELL_NEVER_SLOT1",
        message: `"${cs.spellName}" (P${cs.priority}) NEVER reached slot 1 in ${COMBAT_DURATION}s`,
        spellName: cs.spellName,
        details: `isCD=${cs.isCooldown}, cdDuration=${cs.cdDuration}s, casts=${cs.castCount}`,
      });
    }
  }

  // ── R3: CD_IN_QUEUE_WHILE_ON_CD ──
  for (let i = 0; i < timeline.length; i++) {
    const entry = timeline[i];
    const top3 = [entry.slot1, entry.slot2, entry.slot3];
    for (const spellName of top3) {
      if (spellName === "(none)") continue;
      const cdRem = entry.cdStates[spellName];
      if (cdRem !== undefined && cdRem > 1.5) {
        anomalies.push({
          severity: "error",
          rule: "CD_IN_QUEUE_WHILE_ON_CD",
          message: `"${spellName}" in top 3 at t=${entry.time}s but still on CD (${cdRem.toFixed(1)}s remaining)`,
          spellName,
          time: entry.time,
          details: `cdRemaining=${cdRem.toFixed(1)}s`,
        });
      }
    }
  }

  // ── R4: WRONG_MODE_CAST ──
  for (const cs of combatSpells) {
    if (cs.mode === "Both" || cs.mode === combatMode) continue;
    if (cs.castCount > 0) {
      anomalies.push({
        severity: "error",
        rule: "WRONG_MODE_CAST",
        message: `"${cs.spellName}" (${cs.mode}) was cast ${cs.castCount} times in ${combatMode} combat`,
        spellName: cs.spellName,
        details: `spellMode=${cs.mode}, combatMode=${combatMode}, casts=${cs.castCount}`,
      });
    }
  }

  // ── R5: DELAYED_CD_PROMOTION ──
  for (const cs of relevantSpells) {
    if (!cs.isCooldown || cs.cdDuration < 8) continue;

    let lastCDStart = -1;
    for (let i = 0; i < timeline.length; i++) {
      const entry = timeline[i];
      const cdRem = entry.cdStates[cs.spellName];
      if (cdRem !== undefined && cdRem > 0) {
        if (lastCDStart < 0) lastCDStart = i;
      } else if (lastCDStart >= 0) {
        const cdEndTime = entry.time;
        let promotionDelay = -1;
        for (let j = i; j < timeline.length; j++) {
          if (timeline[j].slot1 === cs.spellName) {
            promotionDelay = timeline[j].time - cdEndTime;
            break;
          }
          const nextCdRem = timeline[j].cdStates[cs.spellName];
          if (nextCdRem !== undefined && nextCdRem > 0) break;
        }
        if (promotionDelay > 15) {
          anomalies.push({
            severity: promotionDelay > 25 ? "error" : "warning",
            rule: "DELAYED_CD_PROMOTION",
            message: `"${cs.spellName}" came off CD at t=${cdEndTime.toFixed(1)}s but didn't reach slot 1 for ${promotionDelay.toFixed(1)}s`,
            spellName: cs.spellName,
            time: cdEndTime,
            details: `cdDuration=${cs.cdDuration}s, delay=${promotionDelay.toFixed(1)}s`,
          });
        }
        lastCDStart = -1;
      }
    }
  }

  // ── R6: MONOTONIC_ROTATION ──
  const castCounts: Record<string, number> = {};
  for (const entry of timeline) {
    castCounts[entry.castSpell] = (castCounts[entry.castSpell] || 0) + 1;
  }
  const totalGCDs = timeline.length;
  for (const [spellName, count] of Object.entries(castCounts)) {
    const cs = combatSpells.find(c => c.spellName === spellName);
    if (!cs || cs.isCooldown) continue;
    const pct = (count / totalGCDs) * 100;
    if (pct > 60) {
      anomalies.push({
        severity: pct > 80 ? "error" : "warning",
        rule: "MONOTONIC_ROTATION",
        message: `"${spellName}" cast ${pct.toFixed(0)}% of GCDs (${count}/${totalGCDs}) -- rotation is stuck on this spell`,
        spellName,
        details: `castPct=${pct.toFixed(1)}%, count=${count}`,
      });
    }
  }

  // ── R7: LONG_DROUGHT ──
  for (const cs of relevantSpells) {
    if (cs.castCount <= 1 || cs.isCooldown) continue;

    const castTimes: number[] = [];
    for (const entry of timeline) {
      if (entry.castSpell === cs.spellName) castTimes.push(entry.time);
    }

    if (castTimes.length >= 2) {
      let maxGap = 0;
      for (let i = 1; i < castTimes.length; i++) {
        const gap = castTimes[i] - castTimes[i - 1];
        if (gap > maxGap) maxGap = gap;
      }
      const droughtThreshold = cs.priority <= 15 ? 15 : cs.priority <= 30 ? 20 : 30;
      if (maxGap > droughtThreshold) {
        anomalies.push({
          severity: maxGap > 30 ? "error" : "warning",
          rule: "LONG_DROUGHT",
          message: `"${cs.spellName}" (P${cs.priority}) had a ${maxGap.toFixed(1)}s gap between casts`,
          spellName: cs.spellName,
          details: `totalCasts=${cs.castCount}, longestGap=${maxGap.toFixed(1)}s, threshold=${droughtThreshold}s`,
        });
      }
    }
  }

  // ── R8: PRIORITY_INVERSION ──
  const fillerSpells = relevantSpells.filter(cs => !cs.isCooldown && cs.castCount > 0);
  const neverCastFillers = relevantSpells.filter(cs => !cs.isCooldown && cs.castCount === 0);
  for (const starved of neverCastFillers) {
    for (const caster of fillerSpells) {
      if (caster.priority > starved.priority && caster.castCount >= 3) {
        anomalies.push({
          severity: "error",
          rule: "PRIORITY_INVERSION",
          message: `P${caster.priority} "${caster.spellName}" (${caster.castCount} casts) completely overshadows P${starved.priority} "${starved.spellName}" (0 casts)`,
          spellName: starved.spellName,
          details: `winner=P${caster.priority}/${caster.spellName}/${caster.mode}, loser=P${starved.priority}/${starved.spellName}/${starved.mode}`,
        });
      }
    }
  }

  // ── R9: MAINTENANCE_SPELL_STARVED ──
  for (const cs of relevantSpells) {
    if (!isMaintenance(cs.spellName)) continue;
    if (cs.castCount === 0) {
      anomalies.push({
        severity: "error",
        rule: "MAINTENANCE_SPELL_STARVED",
        message: `Maintenance spell "${cs.spellName}" (P${cs.priority}) was NEVER cast -- DoT/HoT/buff will drop off`,
        spellName: cs.spellName,
        details: `priority=${cs.priority}, mode=${cs.mode}`,
      });
    } else {
      const castTimes: number[] = [];
      for (const entry of timeline) {
        if (entry.castSpell === cs.spellName) castTimes.push(entry.time);
      }
      if (castTimes.length >= 2) {
        let maxGap = 0;
        for (let i = 1; i < castTimes.length; i++) {
          const gap = castTimes[i] - castTimes[i - 1];
          if (gap > maxGap) maxGap = gap;
        }
        if (maxGap > 25) {
          anomalies.push({
            severity: "warning",
            rule: "MAINTENANCE_SPELL_STARVED",
            message: `Maintenance spell "${cs.spellName}" (P${cs.priority}) had a ${maxGap.toFixed(1)}s gap -- DoT/HoT/buff likely fell off`,
            spellName: cs.spellName,
            details: `totalCasts=${cs.castCount}, longestGap=${maxGap.toFixed(1)}s`,
          });
        }
      }
    }
  }

  // ── R10: QUEUE_STAGNATION ──
  let stagnationStart = 0;
  let lastQueue = "";
  for (let i = 0; i < timeline.length; i++) {
    const q = `${timeline[i].slot1}|${timeline[i].slot2}|${timeline[i].slot3}`;
    if (q !== lastQueue) {
      const stagDuration = (i - stagnationStart) * GCD;
      if (stagDuration >= 15 && lastQueue) {
        const parts = lastQueue.split("|");
        anomalies.push({
          severity: stagDuration >= 25 ? "error" : "warning",
          rule: "QUEUE_STAGNATION",
          message: `Queue stuck on [${parts.join(" > ")}] for ${stagDuration.toFixed(1)}s (t=${(stagnationStart * GCD).toFixed(1)}-${(i * GCD).toFixed(1)}s)`,
          time: stagnationStart * GCD,
          details: `duration=${stagDuration.toFixed(1)}s, queue=${lastQueue}`,
        });
      }
      stagnationStart = i;
      lastQueue = q;
    }
  }
  const finalStag = (timeline.length - stagnationStart) * GCD;
  if (finalStag >= 15 && lastQueue) {
    const parts = lastQueue.split("|");
    anomalies.push({
      severity: finalStag >= 25 ? "error" : "warning",
      rule: "QUEUE_STAGNATION",
      message: `Queue stuck on [${parts.join(" > ")}] for ${finalStag.toFixed(1)}s until end of combat`,
      time: stagnationStart * GCD,
      details: `duration=${finalStag.toFixed(1)}s, queue=${lastQueue}`,
    });
  }

  // ── R11: AC_RECOMMENDATION_IGNORED (for AC scenarios only) ──
  if (scenarioName.includes("ac_")) {
    const acEntries = timeline.filter(e => e.acState);
    if (acEntries.length > 0) {
      const acSpell = acEntries[0].acState?.split(":").slice(1).join(":") || "";
      const acCastDuringWindow = acEntries.some(e => e.castSpell === acSpell);
      const acSlot1DuringWindow = acEntries.some(e => e.slot1 === acSpell);
      if (!acSlot1DuringWindow) {
        anomalies.push({
          severity: "error",
          rule: "AC_RECOMMENDATION_IGNORED",
          message: `AC recommended "${acSpell}" but it NEVER reached slot 1 during the AC window (${acEntries.length * GCD}s)`,
          spellName: acSpell,
          details: `acWindowGCDs=${acEntries.length}, wasCast=${acCastDuringWindow}`,
        });
      } else if (!acCastDuringWindow) {
        anomalies.push({
          severity: "warning",
          rule: "AC_RECOMMENDATION_IGNORED",
          message: `AC recommended "${acSpell}" -- reached slot 1 but was never the actual cast during the AC window`,
          spellName: acSpell,
          details: `acWindowGCDs=${acEntries.length}`,
        });
      }
    }
  }

  // ── R12: FILLER_DOMINANCE ──
  const modeFillers = relevantSpells.filter(cs => !cs.isCooldown);
  const totalFillerCasts = modeFillers.reduce((sum, cs) => sum + cs.castCount, 0);
  if (totalFillerCasts > 5 && modeFillers.length >= 3) {
    for (const cs of modeFillers) {
      const pct = (cs.castCount / totalFillerCasts) * 100;
      const starvingBetterFillers = modeFillers.filter(o => o.priority < cs.priority && o.castCount === 0);
      if (pct > 60 && starvingBetterFillers.length > 0) {
        const names = starvingBetterFillers.map(o => `${o.spellName}(P${o.priority})`).join(", ");
        anomalies.push({
          severity: "error",
          rule: "FILLER_DOMINANCE",
          message: `"${cs.spellName}" (P${cs.priority}) consumed ${pct.toFixed(0)}% of filler GCDs while higher-priority fillers got ZERO: ${names}`,
          spellName: cs.spellName,
          details: `dominantCasts=${cs.castCount}, totalFillerCasts=${totalFillerCasts}, starved=${names}`,
        });
      }
    }
  }

  // ── R13: CD_WASTED ──
  for (const cs of relevantSpells) {
    if (!cs.isCooldown || cs.cdDuration < 8 || cs.cdDuration > COMBAT_DURATION) continue;
    const expectedCasts = Math.floor(COMBAT_DURATION / cs.cdDuration) + 1;
    const minReasonable = Math.max(1, Math.floor(expectedCasts * 0.4));
    if (cs.castCount < minReasonable && cs.castCount < expectedCasts) {
      anomalies.push({
        severity: cs.castCount === 0 ? "error" : "warning",
        rule: "CD_WASTED",
        message: `"${cs.spellName}" (${cs.cdDuration}s CD) only cast ${cs.castCount} time(s) in ${COMBAT_DURATION}s -- expected ~${expectedCasts} uses`,
        spellName: cs.spellName,
        details: `cdDuration=${cs.cdDuration}s, actualCasts=${cs.castCount}, expectedCasts=${expectedCasts}`,
      });
    }
  }

  // ── R14: RESOURCE_STARVED ──
  if (resourceSkips && resourceSkips.length > 0) {
    const skipsBySpell: Record<string, ResourceSkip[]> = {};
    for (const skip of resourceSkips) {
      if (!skipsBySpell[skip.spellName]) skipsBySpell[skip.spellName] = [];
      skipsBySpell[skip.spellName].push(skip);
    }
    for (const [spellName, skips] of Object.entries(skipsBySpell)) {
      const totalGCDs = timeline.length;
      const skipPct = (skips.length / totalGCDs) * 100;
      if (skips.length >= 3) {
        const firstSkip = skips[0];
        const cs = combatSpells.find(c => c.spellName === spellName);
        anomalies.push({
          severity: skipPct > 20 ? "error" : "warning",
          rule: "RESOURCE_STARVED",
          message: `"${spellName}" was top-priority but blocked ${skips.length} times (${skipPct.toFixed(0)}% of GCDs) due to insufficient resources: ${firstSkip.reason}`,
          spellName,
          time: firstSkip.time,
          details: `skipCount=${skips.length}, totalGCDs=${totalGCDs}, skipPct=${skipPct.toFixed(1)}%, firstBlock=t${firstSkip.time}s, priority=P${cs?.priority || "?"}`,
        });
      }
    }
  }

  // ── R15: BUILDER_SPENDER_IMBALANCE ──
  if (resourceSkips && resourceSkips.length > 0) {
    const blockedEntries = timeline.filter(e => e.resourceBlocked);
    const totalCasts = timeline.length;
    const blockRate = (blockedEntries.length / totalCasts) * 100;
    if (blockRate > 30) {
      anomalies.push({
        severity: "error",
        rule: "BUILDER_SPENDER_IMBALANCE",
        message: `${blockRate.toFixed(0)}% of GCDs had the top-priority spell blocked by resources -- rotation is resource-starved overall`,
        details: `blockedGCDs=${blockedEntries.length}, totalGCDs=${totalCasts}`,
      });
    }
  }

  // ── Dedup: only keep first occurrence per spell for repeating rules ──
  const deduped: TimelineAnomaly[] = [];
  const seenKeys = new Set<string>();
  for (const a of anomalies) {
    const key = `${a.rule}:${a.spellName || ""}`;
    if (a.rule === "CD_IN_QUEUE_WHILE_ON_CD" || a.rule === "QUEUE_STAGNATION" || a.rule === "DELAYED_CD_PROMOTION") {
      if (seenKeys.has(key)) continue;
    }
    seenKeys.add(key);
    deduped.push(a);
  }

  return deduped;
}

function buildTimelineScenarios(baseSpells: SpellState[]): {
  name: string;
  description: string;
  combatMode: "ST" | "AoE";
  acConfig?: { spellName: string; signal: "ants" | "assisted"; startTime: number; endTime: number };
}[] {
  const scenarios: ReturnType<typeof buildTimelineScenarios> = [];

  scenarios.push({
    name: "sustained_st_5min",
    description: "5min sustained Single Target combat -- full CD cycling",
    combatMode: "ST",
  });

  scenarios.push({
    name: "sustained_aoe_5min",
    description: "5min sustained AoE combat -- full CD cycling",
    combatMode: "AoE",
  });

  const cds = baseSpells.filter(s => s.isCooldown && getSpellCDDuration(s.spellName, true) >= 15);
  if (cds.length > 0) {
    const firstCD = cds[0];
    scenarios.push({
      name: "ac_ants_cd_mid_combat",
      description: `AC ANTS on CD "${firstCD.spellName}" from t=20-30s`,
      combatMode: "ST",
      acConfig: { spellName: firstCD.spellName, signal: "ants", startTime: 20, endTime: 30 },
    });
  }

  const fillers = baseSpells.filter(s => !s.isCooldown);
  if (fillers.length > 0) {
    const lowestFiller = [...fillers].sort((a, b) => b.priority - a.priority)[0];
    scenarios.push({
      name: "ac_assisted_low_filler",
      description: `AC ASSISTED on lowest-prio filler "${lowestFiller.spellName}" from t=10-25s`,
      combatMode: "ST",
      acConfig: { spellName: lowestFiller.spellName, signal: "assisted", startTime: 10, endTime: 25 },
    });

    const highestFiller = [...fillers].sort((a, b) => a.priority - b.priority)[0];
    if (highestFiller && highestFiller.spellName !== lowestFiller.spellName) {
      scenarios.push({
        name: "ac_ants_high_filler",
        description: `AC ANTS on top-prio filler "${highestFiller.spellName}" from t=15-30s`,
        combatMode: "ST",
        acConfig: { spellName: highestFiller.spellName, signal: "ants", startTime: 15, endTime: 30 },
      });
    }
  }

  const maintSpells = fillers.filter(s => isMaintenance(s.spellName));
  if (maintSpells.length > 0) {
    scenarios.push({
      name: "maintenance_check_st",
      description: `Maintenance spell uptime check (ST) -- ${maintSpells.map(s => s.spellName).join(", ")}`,
      combatMode: "ST",
    });
  }

  return scenarios;
}

function detectAnomalies(results: SimResult[], combatMode: "ST" | "AoE", scenarioName: string): Anomaly[] {
  const anomalies: Anomaly[] = [];
  const readySpells = results.filter(r => r.score < 9000 && !r.modeMismatch);
  const top3 = readySpells.slice(0, 3);

  for (const r of top3) {
    if (r.modeMismatch) {
      anomalies.push({
        severity: "error",
        rule: "MODE_MISMATCH_IN_QUEUE",
        message: `${r.spellName} is mode-mismatched (${r.mode} in ${combatMode}) but ranked #${top3.indexOf(r) + 1}`,
        spellName: r.spellName,
      });
    }
    if (r.score >= 9000) {
      anomalies.push({
        severity: "error",
        rule: "ON_CD_IN_QUEUE",
        message: `${r.spellName} is on CD/unavailable but ranked in top 3`,
        spellName: r.spellName,
      });
    }
  }

  const readyCDs = readySpells.filter(r => r.isCD);
  const readyFillers = readySpells.filter(r => !r.isCD && r.signal !== "ANTS" && r.signal !== "ASSISTED");
  for (const filler of readyFillers) {
    for (const cd of readyCDs) {
      if (filler.score < cd.score && cd.signal !== "NONE") {
        anomalies.push({
          severity: "warning",
          rule: "FILLER_BEATS_CD",
          message: `Filler "${filler.spellName}" (${filler.score}) outranks CD "${cd.spellName}" (${cd.score})`,
          spellName: filler.spellName,
          details: `filler_score=${filler.score} cd_score=${cd.score}`,
        });
      }
    }
  }

  const acSpells = results.filter(r => r.signal === "ANTS" || r.signal === "ASSISTED");
  for (const ac of acSpells) {
    const rank = readySpells.indexOf(ac);
    if (rank >= 3) {
      anomalies.push({
        severity: "warning",
        rule: "AC_NOT_IN_QUEUE",
        message: `AC-recommended "${ac.spellName}" (${ac.signal}) ranked #${rank + 1}, not in top 3`,
        spellName: ac.spellName,
      });
    }
  }

  const uniqueScores = new Set(readySpells.map(r => r.score));
  if (readySpells.length > 3 && uniqueScores.size <= 2) {
    anomalies.push({
      severity: "warning",
      rule: "FLAT_SCORING",
      message: `Only ${uniqueScores.size} distinct scores across ${readySpells.length} spells — poor differentiation`,
    });
  }

  return anomalies;
}

function buildSnapshotScenarios(baseSpells: SpellState[]): { name: string; description: string; combatMode: "ST" | "AoE"; spells: SpellState[] }[] {
  const scenarios: ReturnType<typeof buildSnapshotScenarios> = [];

  const cdSpells = baseSpells.filter(s => s.isCooldown);
  const fillerSpells = baseSpells.filter(s => !s.isCooldown);

  if (cdSpells.length > 0 && fillerSpells.length > 0) {
    const mixedSpells = cloneSpells(baseSpells);
    let cdIdx = 0;
    for (const s of mixedSpells) {
      if (s.isCooldown) {
        if (cdIdx % 2 === 0) {
          s.cdReady = false;
          s.cdRemaining = 15 + cdIdx * 5;
          s.isUsable = false;
        }
        cdIdx++;
      }
    }
    scenarios.push({
      name: "mixed_cds",
      description: "Alternating CDs on/off cooldown",
      combatMode: "ST",
      spells: mixedSpells,
    });
  }

  {
    const allOnCD = cloneSpells(baseSpells);
    for (const s of allOnCD) {
      if (s.isCooldown) {
        s.cdReady = false;
        s.cdRemaining = 20;
        s.isUsable = false;
      }
    }
    scenarios.push({
      name: "all_cds_down",
      description: "All CDs on cooldown, only fillers available",
      combatMode: "ST",
      spells: allOnCD,
    });
  }

  return scenarios;
}

export function validateSpec(specId: string): SpecValidation {
  const spells = getSpecSpells(specId);
  if (!spells.length) {
    return {
      specId,
      specLabel: SPEC_LABELS[specId] || specId,
      spellCount: 0,
      cdCount: 0,
      scenarios: [],
      timelineResults: [],
      totalAnomalies: 0,
      errors: 0,
      warnings: 0,
      passed: false,
    };
  }

  const cdCount = spells.filter(s => s.isCooldown).length;
  let totalAnomalies = 0;
  let errors = 0;
  let warnings = 0;

  const snapshotScenarios = buildSnapshotScenarios(spells);
  const scenarioResults: ScenarioResult[] = [];

  for (const scenario of snapshotScenarios) {
    const results = simulatePriority(specId, scenario.combatMode, scenario.spells);
    const anomalies = detectAnomalies(results, scenario.combatMode, scenario.name);
    const readySpells = results.filter(r => r.score < 9000 && !r.modeMismatch);
    const topQueue = readySpells.slice(0, 3).map(r => r.spellName);
    const scenarioErrors = anomalies.filter(a => a.severity === "error").length;
    const scenarioWarnings = anomalies.filter(a => a.severity === "warning").length;
    totalAnomalies += anomalies.length;
    errors += scenarioErrors;
    warnings += scenarioWarnings;

    scenarioResults.push({
      scenarioName: scenario.name,
      description: scenario.description,
      combatMode: scenario.combatMode,
      results,
      anomalies,
      topQueue,
      passed: scenarioErrors === 0,
    });
  }

  const timelineScenarios = buildTimelineScenarios(spells);
  const timelineResults: TimelineResult[] = [];

  for (const ts of timelineScenarios) {
    const { timeline, combatSpells, resourceSkips } = runTimelineSim(specId, ts.combatMode, spells, ts.acConfig);
    const tAnomalies = analyzeTimeline(combatSpells, timeline, ts.combatMode, ts.name, resourceSkips);

    const spellStats: SpellStat[] = combatSpells.map(cs => {
      const castTimes: number[] = [];
      let longestDrought = 0;
      for (const entry of timeline) {
        if (entry.castSpell === cs.spellName) castTimes.push(entry.time);
      }
      if (castTimes.length >= 2) {
        for (let i = 1; i < castTimes.length; i++) {
          const gap = castTimes[i] - castTimes[i - 1];
          if (gap > longestDrought) longestDrought = gap;
        }
      }
      const avgGap = castTimes.length >= 2
        ? (castTimes[castTimes.length - 1] - castTimes[0]) / (castTimes.length - 1)
        : null;

      return {
        spellName: cs.spellName,
        totalCasts: cs.castCount,
        timesInSlot1: cs.slot1Count,
        firstSlot1Time: cs.firstSlot1Time,
        avgGapBetweenCasts: avgGap ? Math.round(avgGap * 10) / 10 : null,
        longestDrought: Math.round(longestDrought * 10) / 10,
        isCD: cs.isCooldown,
        cdDuration: cs.cdDuration,
        mode: cs.mode,
        priority: cs.priority,
      };
    });

    const tErrors = tAnomalies.filter(a => a.severity === "error").length;
    const tWarnings = tAnomalies.filter(a => a.severity === "warning").length;
    totalAnomalies += tAnomalies.length;
    errors += tErrors;
    warnings += tWarnings;

    timelineResults.push({
      scenarioName: ts.name,
      description: ts.description,
      combatMode: ts.combatMode,
      duration: COMBAT_DURATION,
      timeline,
      castHistory: (() => {
        const h: Record<string, number[]> = {};
        for (const entry of timeline) {
          if (!h[entry.castSpell]) h[entry.castSpell] = [];
          h[entry.castSpell].push(entry.time);
        }
        return h;
      })(),
      anomalies: tAnomalies,
      spellStats,
      passed: tErrors === 0,
    });
  }

  return {
    specId,
    specLabel: SPEC_LABELS[specId] || specId,
    spellCount: spells.length,
    cdCount,
    scenarios: scenarioResults,
    timelineResults,
    totalAnomalies,
    errors,
    warnings,
    passed: errors === 0,
  };
}

export function validateAllSpecs(): BatchResult {
  const start = Date.now();
  const specIds = Object.keys(COMMUNITY_APLS);
  const specs: SpecValidation[] = [];
  let totalAnomalies = 0;
  let totalErrors = 0;

  for (const specId of specIds) {
    const result = validateSpec(specId);
    specs.push(result);
    totalAnomalies += result.totalAnomalies;
    totalErrors += result.errors;
  }

  return {
    timestamp: new Date().toISOString(),
    duration: Date.now() - start,
    totalSpecs: specIds.length,
    passedSpecs: specs.filter(s => s.passed).length,
    failedSpecs: specs.filter(s => !s.passed).length,
    totalAnomalies,
    totalErrors,
    specs,
  };
}

export interface LogScenario {
  name: string;
  specId: string;
  combatMode: "ST" | "AoE";
  acSpellName?: string;
  acSignal?: "ants" | "assisted";
  cdsOnCooldown?: string[];
  description: string;
}

export function simulateFromLogScenario(scenario: LogScenario): ScenarioResult {
  const spells = getSpecSpells(scenario.specId);
  if (!spells.length) {
    return {
      scenarioName: scenario.name,
      description: scenario.description,
      combatMode: scenario.combatMode,
      results: [],
      anomalies: [{ severity: "error", rule: "NO_SPELLS", message: `No spells found for ${scenario.specId}` }],
      topQueue: [],
      passed: false,
    };
  }

  const modified = cloneSpells(spells);

  if (scenario.acSpellName) {
    const cn = scenario.acSpellName.toLowerCase().replace(/_/g, " ").replace(/:/g, "");
    const target = modified.find(s => s.spellName.toLowerCase().replace(/_/g, " ").replace(/:/g, "") === cn);
    if (target) {
      if (scenario.acSignal === "ants") {
        target.isAnts = true;
      } else {
        target.isAcRecommended = true;
      }
    }
  }

  if (scenario.cdsOnCooldown) {
    for (const cdName of scenario.cdsOnCooldown) {
      const cn = cdName.toLowerCase().replace(/_/g, " ").replace(/:/g, "");
      const target = modified.find(s => s.spellName.toLowerCase().replace(/_/g, " ").replace(/:/g, "") === cn);
      if (target) {
        target.cdReady = false;
        target.cdRemaining = 15;
        target.isUsable = false;
      }
    }
  }

  const results = simulatePriority(scenario.specId, scenario.combatMode, modified);
  const anomalies = detectAnomalies(results, scenario.combatMode, scenario.name);
  const readySpells = results.filter(r => r.score < 9000 && !r.modeMismatch);

  return {
    scenarioName: scenario.name,
    description: scenario.description,
    combatMode: scenario.combatMode,
    results,
    anomalies,
    topQueue: readySpells.slice(0, 3).map(r => r.spellName),
    passed: anomalies.filter(a => a.severity === "error").length === 0,
  };
}

const SPEC_NAME_MAP: Record<string, string> = {
  "balance druid": "druid-balance",
  "guardian druid": "druid-guardian",
  "feral druid": "druid-feral",
  "restoration druid": "druid-resto",
  "assassination rogue": "rogue-ass",
  "outlaw rogue": "rogue-out",
  "subtlety rogue": "rogue-sub",
  "augmentation evoker": "evoker-aug",
  "preservation evoker": "evoker-pres",
  "devastation evoker": "evoker-dev",
  "blood death knight": "dk-blood",
  "unholy death knight": "dk-unholy",
  "frost death knight": "dk-frost",
  "vengeance demon hunter": "dh-vengeance",
  "havoc demon hunter": "dh-havoc",
  "brewmaster monk": "monk-brew",
  "windwalker monk": "monk-ww",
  "mistweaver monk": "monk-mw",
  "protection paladin": "paladin-prot",
  "holy paladin": "paladin-holy",
  "retribution paladin": "paladin-ret",
  "protection warrior": "warrior-prot",
  "arms warrior": "warrior-arms",
  "fury warrior": "warrior-fury",
  "discipline priest": "priest-disc",
  "holy priest": "priest-holy",
  "shadow priest": "priest-shadow",
  "restoration shaman": "shaman-resto",
  "enhancement shaman": "shaman-enh",
  "elemental shaman": "shaman-ele",
  "beast mastery hunter": "hunter-bm",
  "marksmanship hunter": "hunter-mm",
  "survival hunter": "hunter-surv",
  "arcane mage": "mage-arcane",
  "fire mage": "mage-fire",
  "frost mage": "mage-frost",
  "affliction warlock": "warlock-aff",
  "demonology warlock": "warlock-demo",
  "destruction warlock": "warlock-dest",
};

function normalizeSpellName(name: string): string {
  return name.trim().toLowerCase().replace(/[_:'\u2019]/g, "").replace(/\s+/g, " ");
}

function parseSpecFromLine(line: string): string | null {
  const specChangeMatch = line.match(/\[SPEC_CHANGE\].*?[-\u2014]{1,2}\s*now:\s*(.+)/i) ||
                          line.match(/Watchdog monitoring active\s*[-\u2014]{1,2}\s*(.+)/i);
  if (specChangeMatch) {
    const rawSpecName = specChangeMatch[1].trim().toLowerCase();
    return SPEC_NAME_MAP[rawSpecName] || rawSpecName.replace(/\s+/g, "-");
  }
  const oldSpecMatch = line.match(/\[EvaluateAPL\]\s+spec=(\S+)/i) || line.match(/spec[=:]\s*"?(\w+-\w+)"?/i);
  if (oldSpecMatch) return oldSpecMatch[1];
  return null;
}

function parseModeFromLine(line: string): "ST" | "AoE" | null {
  const modeMatch = line.match(/combatMode\s*=\s*"?(ST|AoE)"?/i) ||
                    line.match(/mode\s*=\s*(ST|AoE)/i) ||
                    line.match(/\|\s*(ST|AoE)\s*\(/i);
  return modeMatch ? (modeMatch[1] as "ST" | "AoE") : null;
}

export function parseLogForScenarios(logText: string): LogScenario[] {
  const scenarios: LogScenario[] = [];
  const lines = logText.split("\n");

  let currentSpec = "";
  let currentMode: "ST" | "AoE" = "ST";

  for (const line of lines) {
    const detectedSpec = parseSpecFromLine(line);
    if (detectedSpec) currentSpec = detectedSpec;

    const detectedMode = parseModeFromLine(line);
    if (detectedMode) currentMode = detectedMode;

    const acRecMatch = line.match(/\[AC_REC\]\s+(.+?)\s*\(id=\d+\)/);
    const oldAcMatch = line.match(/AC-?(?:NEXT|REC|CAST).*?:\s*(.+?)(?:\s*\(|$)/i) ||
                       line.match(/ANTS:\s*(.+?)(?:\s*\(|$)/i) ||
                       line.match(/ASSISTED:\s*(.+?)(?:\s*\(|$)/i);

    const acMatch = acRecMatch || oldAcMatch;

    if (acMatch && currentSpec) {
      const spellName = acMatch[1].trim();
      const isAnts = line.toUpperCase().includes("ANTS");
      const signal = isAnts ? "ants" as const : "assisted" as const;

      scenarios.push({
        name: `log_${scenarios.length + 1}_${signal}_${spellName.replace(/\s+/g, "_").toLowerCase()}`,
        specId: currentSpec,
        combatMode: currentMode,
        acSpellName: spellName,
        acSignal: signal,
        description: `Log replay: AC ${signal} on "${spellName}" (${currentSpec}, ${currentMode})`,
      });
    }
  }

  return scenarios;
}

export interface LogDiscrepancy {
  timestamp: string;
  issue: string;
  inGame: string;
  simExpected: string;
  severity: "error" | "warning" | "info";
}

export interface LogReplayResult {
  specId: string;
  combatMode: string;
  totalCasts: number;
  totalACRecs: number;
  discrepancies: LogDiscrepancy[];
  castBreakdown: Record<string, number>;
  simCastBreakdown: Record<string, number>;
  queueEvents: Array<{
    timestamp: string;
    slot1: string;
    slot2: string;
    reason: string;
    acSpell: string;
    simTopSpell: string;
    simScore: number;
    match: boolean;
  }>;
}

export function replayLogVsSim(logText: string, specIdOverride?: string): LogReplayResult {
  const lines = logText.split("\n");
  let specId = specIdOverride || "";
  let combatMode: "ST" | "AoE" = "ST";
  const discrepancies: LogDiscrepancy[] = [];
  const castBreakdown: Record<string, number> = {};
  const queueEvents: LogReplayResult["queueEvents"] = [];

  for (const line of lines) {
    const detectedSpec = parseSpecFromLine(line);
    if (detectedSpec && !specIdOverride) specId = detectedSpec;

    const detectedMode = parseModeFromLine(line);
    if (detectedMode) combatMode = detectedMode;

    const ts = line.match(/^(\d{2}:\d{2}:\d{2})/)?.[1] || "";

    const queueMatch = line.match(/\[QUEUE\]\s+(.+?)\s+>\s+(.+?)\s+\[([^\]]*)\]\s*\|\s*AC=(.+)/);
    if (queueMatch && specId) {
      const [, slot1, slot2, reason, acLabel] = queueMatch;

      const spells = getSpecSpells(specId);
      if (spells.length > 0) {
        const modified = cloneSpells(spells);
        const acNorm = normalizeSpellName(acLabel);
        const target = modified.find(s => normalizeSpellName(s.spellName) === acNorm);
        if (target) target.isAcRecommended = true;

        const results = simulatePriority(specId, combatMode, modified);
        const topSim = results[0];

        const simTopName = topSim?.spellName || "(none)";
        const simScore = topSim?.score ?? 9999;
        const match = normalizeSpellName(simTopName) === normalizeSpellName(slot1);

        queueEvents.push({
          timestamp: ts,
          slot1: slot1.trim(),
          slot2: slot2.trim(),
          reason: reason.trim(),
          acSpell: acLabel.trim(),
          simTopSpell: simTopName,
          simScore,
          match,
        });

        if (!match) {
          discrepancies.push({
            timestamp: ts,
            issue: `Queue shows "${slot1.trim()}" but sim says "${simTopName}"`,
            inGame: `${slot1.trim()} [${reason.trim()}]`,
            simExpected: `${simTopName} (score=${simScore})`,
            severity: reason.trim() === "" ? "error" : "warning",
          });
        }
      }
    }

    const castMatch = line.match(/\[CAST\]\s+(.+?)(?:\s*\(|$)/);
    if (castMatch) {
      const spell = castMatch[1].trim();
      castBreakdown[spell] = (castBreakdown[spell] || 0) + 1;
    }
  }

  const simResult = specId ? validateSpec(specId) : null;
  const simCastBreakdown: Record<string, number> = {};
  if (simResult) {
    const modeTimeline = simResult.timelineResults?.find(t => t.combatMode === combatMode);
    if (modeTimeline?.timeline) {
      for (const tick of modeTimeline.timeline) {
        if (tick.castSpell && tick.castSpell !== "(none)") {
          simCastBreakdown[tick.castSpell] = (simCastBreakdown[tick.castSpell] || 0) + 1;
        }
      }
    }
  }

  return {
    specId,
    combatMode,
    totalCasts: Object.values(castBreakdown).reduce((a, b) => a + b, 0),
    totalACRecs: lines.filter(l => l.includes("[AC_REC]")).length,
    discrepancies,
    castBreakdown,
    simCastBreakdown,
    queueEvents,
  };
}
