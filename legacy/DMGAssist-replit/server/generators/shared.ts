/**
 * @module generators/shared
 * @description
 * Shared types, constants, and utility functions used across all addon generator modules.
 *
 * This module provides:
 * - **AddonData / AllSpecsData** -- The data structures flowing from admin dashboard → generators
 * - **Version management** -- Addon version string (mutated by sync engine before builds)
 * - **Lua string utilities** -- Safe escaping and condition sanitization
 * - **WoW class/spec mappings** -- Blizzard's GetSpecialization() index tables
 *
 * All generator modules import from here rather than defining their own types.
 *
 * @see {@link AddonData} -- Single spec data bundle
 * @see {@link AllSpecsData} -- Multi-spec aggregate for full addon generation
 */

import type { Spec, AplEntry, HudConfig, CombatAlert } from "@shared/schema";

/* ═══════════════════════════════════════════════════════════════════════════════
 * CONSTANTS
 * ═══════════════════════════════════════════════════════════════════════════════ */

/** Addon folder name inside the ZIP -- must match the .toc filename. */
export const ADDON_NAME = "DMGAssist";

/**
 * Current addon version string (semver).
 * Mutated by {@link setAddonVersion} during sync runs when bumping the patch number.
 * Persisted to `.addon-version` on disk by the storage layer.
 */
export let ADDON_VERSION = "1.5.0";

/** WoW client interface version -- determines minimum game version compatibility. */
export const WOW_INTERFACE = "120001";

/** Update the in-memory addon version. Called by sync engine before ZIP generation. */
export function setAddonVersion(version: string): void {
  ADDON_VERSION = version;
}

/** Read the current addon version string. */
export function getAddonVersion(): string {
  return ADDON_VERSION;
}

/* ═══════════════════════════════════════════════════════════════════════════════
 * TYPE DEFINITIONS
 * ═══════════════════════════════════════════════════════════════════════════════ */

/**
 * Complete data bundle for a single WoW specialization.
 * Contains everything needed to generate that spec's addon behavior.
 */
export interface AddonData {
  /** Spec identity -- class, spec name, role, resource type, colors. */
  spec: Spec;
  /** Ordered action priority list -- the "rotation" rules from SimC. */
  aplEntries: AplEntry[];
  /** HUD layout and behavior configuration from the admin dashboard. */
  hudConfig: HudConfig;
  /** Boss mod alert overrides (DBM/BigWigs interrupt bindings). */
  alerts: CombatAlert[];
  /** SimC variable definitions compiled into Lua functions. */
  variables?: import("../simc-parser").SimcVariable[];
  /** SimC branch this APL came from (e.g. "midnight" or "thewarwithin"). */
  aplBranch?: string;
  /** SimC tier tag (e.g. "MID1" or "TWW3"). */
  aplTier?: string;
}

/**
 * Aggregate container for all specialization data.
 * Passed to {@link generateAllSpecsAddonZip} to produce the multi-spec addon.
 */
export interface AllSpecsData {
  specs: AddonData[];
}

/* ═══════════════════════════════════════════════════════════════════════════════
 * LUA STRING UTILITIES
 * ═══════════════════════════════════════════════════════════════════════════════ */

/**
 * Escapes a string for safe embedding inside Lua double-quoted string literals.
 * Handles backslashes, double quotes, and newlines.
 */
export function escapeLuaStr(s: string): string {
  return s.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n");
}

/**
 * Validates and sanitizes a transpiled Lua condition string.
 * Returns "true" (always-pass) if the condition has unbalanced parens or
 * contains a bare `end` keyword that would break Lua syntax.
 *
 * @taint-solution This prevents malformed conditions from crashing the addon
 * at load time, which would leave the player with no rotation assistance.
 */
export function safeLuaCondition(rawLua: string): string {
  if (!rawLua || rawLua.trim() === "true") return "true";
  const balanced = (s: string, open: string, close: string) => {
    let depth = 0;
    for (const c of s) {
      if (c === open) depth++;
      else if (c === close) depth--;
      if (depth < 0) return false;
    }
    return depth === 0;
  };
  if (!balanced(rawLua, "(", ")")) return "true";
  if (/\bend\b/.test(rawLua) && !/\b(and|send|blend|friend|defend|append|extend)\b/.test(rawLua.replace(/\bend\b/g, ""))) {
    return "true";
  }
  return rawLua;
}

/* ═══════════════════════════════════════════════════════════════════════════════
 * WOW CLASS / SPEC MAPPINGS
 *
 * WoW's GetSpecialization() returns a 1-based index per class. The order is
 * hard-coded by Blizzard and never changes within an expansion. We map
 * "CLASSTOKEN-specIndex" → our internal spec ID so the addon can auto-detect
 * the player's spec at login without any network call.
 * ═══════════════════════════════════════════════════════════════════════════════ */

/**
 * Canonical spec ordering per class token, matching WoW's `GetSpecialization()` indices.
 * Key = uppercase class token (no spaces), Value = ordered spec names (index 1..N).
 *
 * @example WOW_SPEC_ORDER["DRUID"][2] → "Guardian" (spec index 3 in WoW)
 */
export const WOW_SPEC_ORDER: Record<string, string[]> = {
  DEATHKNIGHT: ["Blood", "Frost", "Unholy"],
  DEMONHUNTER: ["Havoc", "Vengeance"],
  DRUID: ["Balance", "Feral", "Guardian", "Restoration"],
  EVOKER: ["Devastation", "Preservation", "Augmentation"],
  HUNTER: ["Beast Mastery", "Marksmanship", "Survival"],
  MAGE: ["Arcane", "Fire", "Frost"],
  MONK: ["Brewmaster", "Mistweaver", "Windwalker"],
  PALADIN: ["Holy", "Protection", "Retribution"],
  PRIEST: ["Discipline", "Holy", "Shadow"],
  ROGUE: ["Assassination", "Outlaw", "Subtlety"],
  SHAMAN: ["Elemental", "Enhancement", "Restoration"],
  WARLOCK: ["Affliction", "Demonology", "Destruction"],
  WARRIOR: ["Arms", "Fury", "Protection"],
};

/**
 * Generates the Lua source for `CLF_SpecLookup` -- a table mapping
 * "CLASSTOKEN-specIndex" → internal spec ID string.
 *
 * Used in Config.lua by `CLF_DetectSpec()` to identify the player's current
 * specialization from `UnitClass("player")` + `GetSpecialization()`.
 *
 * @param allData - All spec data bundles from the admin dashboard.
 * @returns Lua table entries as a formatted string (one per line, comma-separated).
 *
 * @example Output line: `["DRUID-2"] = "druid-feral"`
 */
export function generateSpecLookupEntries(allData: AllSpecsData): string {
  const entries: string[] = [];
  for (const [classToken, specOrder] of Object.entries(WOW_SPEC_ORDER)) {
    for (let i = 0; i < specOrder.length; i++) {
      const specName = specOrder[i];
      const matched = allData.specs.find(d => {
        const className = d.spec.className.replace(/\s/g, "").toUpperCase();
        return className === classToken && d.spec.specName === specName;
      });
      if (matched) {
        entries.push(`  ["${classToken}-${i + 1}"] = "${escapeLuaStr(matched.spec.id)}"`);
      }
    }
  }
  return entries.join(",\n");
}
