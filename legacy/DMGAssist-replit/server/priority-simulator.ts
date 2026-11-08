import { COMMUNITY_APLS } from "./community-apls";
import type { AplEntry } from "@shared/schema";

export interface SpellState {
  spellName: string;
  spellId: number;
  priority: number;
  mode: "ST" | "AoE" | "Both";
  isCooldown: boolean;
  isOffensive: boolean;
  isInterrupt: boolean;
  cdReady: boolean;
  cdRemaining: number;
  cdDuration: number;
  isUsable: boolean;
  isAcRecommended: boolean;
  isAnts: boolean;
  isProc: boolean;
  conditionMet: boolean;
}

export interface SimResult {
  spellName: string;
  score: number;
  tier: string;
  reason: string;
  signal: string;
  mode: string;
  basePrio: number;
  isCD: boolean;
  modeMismatch: boolean;
}

const SIGNAL_ANTS = 1;
const SIGNAL_PROC = 2;
const SIGNAL_ASSISTED = 3;
const SIGNAL_READY = 4;
const SIGNAL_NONE = 99;

const PRE_MIDNIGHT_OVERRIDES: Record<string, {
  priorityOverrides?: Record<string, number>;
  modeOverrides?: Record<string, string>;
  cdOverrides?: Record<string, boolean>;
}> = {
  "druid-balance": {
    modeOverrides: {
      starfall: "AoE",
      "wild mushroom": "AoE",
      starsurge: "Both",
    },
    priorityOverrides: {
      starfall: 3,
      starsurge: 4,
      starfire: 9,
    },
    cdOverrides: {
      "celestial alignment": true,
      "incarnation chosen of elune": true,
      "fury of elune": true,
      starfall: true,
    },
  },
  "rogue-ass": {
    priorityOverrides: {
      deathmark: 2,
      kingsbane: 3,
    },
    cdOverrides: {
      deathmark: true,
    },
  },
  "evoker-aug": {
    priorityOverrides: {
      "ebon might": 2,
      "breath of eons": 1,
    },
    cdOverrides: {
      "breath of eons": true,
    },
  },
};

function cleanName(name: string): string {
  return name.toLowerCase().replace(/_/g, " ").replace(/:/g, "");
}

function getTierLabel(score: number): string {
  if (score <= -11500) return "T1: CD+Assisted";
  if (score <= -10900) return "T2: CD Ready";
  if (score <= -10500) return "T2b: Major CD";
  if (score <= -10100) return "T3: AC Recommended";
  if (score <= -9500) return "T4: Assisted";
  if (score <= -6500) return "T5: Filler (match/both)";
  if (score <= -4500) return "T6: Proc";
  if (score <= -2500) return "T7: Weak Match";
  if (score < 5000) return "T8: Unknown/Generic";
  if (score < 9000) return "T9: Mode Mismatch (buried)";
  return "T10: On CD / Unavailable";
}

function getSignalName(signal: number): string {
  switch (signal) {
    case SIGNAL_ANTS: return "ANTS";
    case SIGNAL_PROC: return "PROC";
    case SIGNAL_ASSISTED: return "ASSISTED";
    case SIGNAL_READY: return "READY";
    default: return "NONE";
  }
}

export function getSpecSpells(specId: string): SpellState[] {
  const apl = COMMUNITY_APLS[specId];
  if (!apl) return [];

  return apl
    .filter(e => !e.isInterrupt && !e.isPrecombat)
    .map(e => ({
      spellName: e.spellName,
      spellId: e.spellId,
      priority: e.priority,
      mode: e.mode as "ST" | "AoE" | "Both",
      isCooldown: e.isCooldown ?? false,
      isOffensive: e.isOffensive ?? false,
      isInterrupt: e.isInterrupt ?? false,
      cdReady: true,
      cdRemaining: 0,
      cdDuration: e.isCooldown ? 30 : 0,
      isUsable: true,
      isAcRecommended: false,
      isAnts: false,
      isProc: false,
      conditionMet: true,
    }));
}

export function simulatePriority(
  specId: string,
  combatMode: "ST" | "AoE",
  spells: SpellState[],
  aplBranch: string = "community"
): SimResult[] {
  const pMap: Record<string, number> = {};
  const mMap: Record<string, string> = {};
  const cdMap: Record<string, boolean> = {};

  for (const spell of spells) {
    const cn = cleanName(spell.spellName);
    if (!pMap[cn] || spell.priority < pMap[cn]) {
      pMap[cn] = spell.priority;
    }
    if (!mMap[cn]) {
      mMap[cn] = spell.mode;
    } else if (mMap[cn] !== spell.mode) {
      mMap[cn] = "Both";
    }
    if (spell.isCooldown) {
      cdMap[cn] = true;
    }
  }

  const overrides = PRE_MIDNIGHT_OVERRIDES[specId];
  if (overrides && aplBranch !== "midnight" && aplBranch !== "community") {
    if (overrides.priorityOverrides) {
      for (const [spell, prio] of Object.entries(overrides.priorityOverrides)) {
        if (pMap[spell] !== undefined) pMap[spell] = prio;
      }
    }
    if (overrides.modeOverrides) {
      for (const [spell, m] of Object.entries(overrides.modeOverrides)) {
        if (mMap[spell] !== undefined) mMap[spell] = m;
      }
    }
    if (overrides.cdOverrides) {
      for (const [spell, val] of Object.entries(overrides.cdOverrides)) {
        cdMap[spell] = val;
      }
    }
  }

  const seen = new Set<string>();
  const results: SimResult[] = [];

  for (const spell of spells) {
    const cn = cleanName(spell.spellName);
    if (seen.has(cn)) continue;
    seen.add(cn);

    let signal = SIGNAL_NONE;
    if (spell.isAnts) signal = SIGNAL_ANTS;
    else if (spell.isProc) signal = SIGNAL_PROC;
    else if (spell.isAcRecommended) signal = SIGNAL_ASSISTED;
    else if (spell.isUsable && spell.cdReady && spell.conditionMet) signal = SIGNAL_READY;

    if (!spell.isUsable || (!spell.cdReady && !spell.isAcRecommended && !spell.isAnts && !spell.isProc)) {
      results.push({
        spellName: spell.spellName,
        score: 9000 + (spell.cdRemaining || 30),
        tier: "T10: On CD / Unavailable",
        reason: spell.cdReady ? "Not usable (resource/condition)" : `On CD (${spell.cdRemaining}s remaining)`,
        signal: "NONE",
        mode: mMap[cn] || spell.mode,
        basePrio: pMap[cn] ?? 500,
        isCD: cdMap[cn] || spell.isCooldown || (spell.cdDuration >= 8),
        modeMismatch: false,
      });
      continue;
    }

    const basePrio = pMap[cn] ?? 500;
    const spellMode = mMap[cn] || "Both";
    const modeMismatch = spellMode !== "Both" && spellMode !== combatMode;
    const isCD = spell.isCooldown || cdMap[cn] || (spell.cdDuration >= 8);
    const hasSimcData = basePrio < 500;
    const modeMatch = spellMode === combatMode;

    let score: number;
    let reason: string;

    if (isCD && signal <= SIGNAL_ASSISTED) {
      score = -12000 + basePrio;
      reason = `CD spell + AC/Ants signal (${getSignalName(signal)})`;
    } else if (signal === SIGNAL_ANTS) {
      score = -10500 + (hasSimcData ? basePrio : 100);
      reason = "AC Ants recommendation (highest AC signal)";
    } else if (signal === SIGNAL_ASSISTED) {
      score = -10000 + (hasSimcData ? basePrio : 100);
      reason = "AC Assisted highlight";
    } else if (signal === SIGNAL_PROC) {
      score = -5000 + basePrio;
      reason = "Proc active (spell overlay glow)";
    } else if (modeMismatch) {
      score = basePrio + 5000;
      reason = `Mode mismatch: spell is ${spellMode}, combat is ${combatMode}`;
    } else if (isCD && spell.cdDuration >= 15) {
      score = -10800 + basePrio;
      reason = `Major CD ready (${spell.cdDuration}s base CD, strategic)`;
    } else if (isCD) {
      score = -11000 + basePrio;
      reason = `Rotational CD ready (${spell.cdDuration}s base CD)`;
    } else if (hasSimcData) {
      let base: number;
      if (modeMatch || spellMode === "Both") {
        base = -7000;
        reason = `SimC filler, mode ${modeMatch ? `match (${spellMode}=${combatMode})` : `"Both" (universal)`}`;
      } else {
        base = -3000;
        reason = `SimC filler, weak mode match`;
      }
      score = base + basePrio;
    } else {
      score = basePrio;
      reason = "Unknown spell (not in APL)";
    }

    results.push({
      spellName: spell.spellName,
      score,
      tier: getTierLabel(score),
      reason,
      signal: getSignalName(signal),
      mode: spellMode,
      basePrio,
      isCD,
      modeMismatch,
    });
  }

  results.sort((a, b) => a.score - b.score);
  return results;
}

export function getAvailableSpecs(): string[] {
  return Object.keys(COMMUNITY_APLS);
}
