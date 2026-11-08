/**
 * @module server/storage
 *
 * In-memory storage layer for the WoW addon management platform.
 *
 * Architecture Overview:
 * ---------------------
 * This module implements a storage interface ({@link IStorage}) backed by an
 * in-memory {@link MemStorage} class that uses ES `Map` collections for fast
 * key-based lookups. Data is seeded at startup from hard-coded constants
 * (SPECS, SEED_APL, SEED_ALERTS, SEED_HUD_CONFIGS) that
 * define the full WoW class/spec roster, default APL (Action Priority List)
 * rotations, HUD display configurations, and boss-mod combat alerts.
 *
 * Persistence:
 * - Most data lives only in memory and resets on server restart. This is
 *   intentional — the admin panel is the source of truth for APL edits, and
 *   the sync engine re-generates the addon from current state.
 * - The addon version string is the sole piece of data persisted to disk
 *   (`.addon-version` file) so that version bumps survive restarts.
 *
 * Data Flow:
 * - **APL Entries** — per-spec ordered spell priority lists consumed by the
 *   addon generator to emit Lua rotation logic.
 * - **HUD Configs** — per-spec UI layout/behavior settings (icon sizes,
 *   opacity, queue depth, etc.) embedded into the generated addon.
 * - **Combat Alerts** — boss-mod integration entries (DBM/BigWigs) that
 *   trigger interrupt or defensive spell suggestions.
 * - **Profiles** — named snapshots of a spec's HUD config + keybind
 *   overrides, allowing users to swap configurations.
 * - **Sync State** — tracks the 24-hour build-and-upload cycle: current
 *   version, run history, and whether a sync is in progress.
 */

import type { AplEntry, InsertAplEntry, HudConfig, InsertHudConfig, CombatAlert, InsertCombatAlert, Spec, Profile, InsertProfile, SyncRun, SyncState } from "@shared/schema";
import { syncKv, syncRuns } from "@shared/models/auth";
import { db } from "./db";
import { eq, desc } from "drizzle-orm";
import { randomUUID } from "crypto";
import { readFileSync, writeFileSync, existsSync } from "fs";
import { join } from "path";

/** Filesystem path where the current addon version string is persisted across restarts. */
const VERSION_FILE = join(process.cwd(), ".addon-version");

/** Fallback version used when no persisted version file exists or its content is invalid. */
const DEFAULT_VERSION = "1.3.0";

/**
 * Reads the addon version from the persisted `.addon-version` file.
 *
 * Validates the file content against a strict semver pattern (`X.Y.Z`).
 * Returns {@link DEFAULT_VERSION} if the file is missing, unreadable, or
 * contains an invalid format.
 *
 * @returns The persisted version string, or the default version.
 */
function readPersistedVersion(): string {
  try {
    if (existsSync(VERSION_FILE)) {
      const v = readFileSync(VERSION_FILE, "utf-8").trim();
      if (/^\d+\.\d+\.\d+(\.\d+)?$/.test(v)) return v;
    }
  } catch {}
  return DEFAULT_VERSION;
}

/**
 * Writes the addon version string to disk so it survives server restarts.
 *
 * Errors are logged but not thrown — a failed write is non-fatal because the
 * version can be re-set via the admin panel.
 *
 * @param version - Semver string to persist (e.g. `"1.4.0"`).
 */
function writePersistedVersion(version: string): void {
  try {
    writeFileSync(VERSION_FILE, version, "utf-8");
  } catch (err) {
    console.error("[Version] Failed to persist version:", err);
  }
}

/**
 * Complete roster of all 39 WoW class specializations.
 *
 * Each entry defines the spec's unique identifier (used as a foreign key
 * throughout the storage layer), display metadata (class name, color, icon),
 * combat role, and primary resource type. This array is the canonical source
 * for spec data — it is returned directly by {@link IStorage.getSpecs}.
 */
export const SPECS: Spec[] = [
  { id: "dk-blood", className: "Death Knight", specName: "Blood", role: "Tank", resource: "Runic Power", classColor: "#C41E3A", iconSlug: "dk-blood" },
  { id: "dk-frost", className: "Death Knight", specName: "Frost", role: "Melee DPS", resource: "Runic Power", classColor: "#C41E3A", iconSlug: "dk-frost" },
  { id: "dk-unholy", className: "Death Knight", specName: "Unholy", role: "Melee DPS", resource: "Runic Power", classColor: "#C41E3A", iconSlug: "dk-unholy" },
  { id: "dh-havoc", className: "Demon Hunter", specName: "Havoc", role: "Melee DPS", resource: "Fury", classColor: "#A330C9", iconSlug: "dh-havoc" },
  { id: "dh-vengeance", className: "Demon Hunter", specName: "Vengeance", role: "Tank", resource: "Pain", classColor: "#A330C9", iconSlug: "dh-vengeance" },
  { id: "druid-balance", className: "Druid", specName: "Balance", role: "Ranged DPS", resource: "Astral Power", classColor: "#FF7C0A", iconSlug: "druid-balance" },
  { id: "druid-feral", className: "Druid", specName: "Feral", role: "Melee DPS", resource: "Energy", classColor: "#FF7C0A", iconSlug: "druid-feral" },
  { id: "druid-guardian", className: "Druid", specName: "Guardian", role: "Tank", resource: "Rage", classColor: "#FF7C0A", iconSlug: "druid-guardian" },
  { id: "druid-resto", className: "Druid", specName: "Restoration", role: "Healer", resource: "Mana", classColor: "#FF7C0A", iconSlug: "druid-resto" },
  { id: "evoker-dev", className: "Evoker", specName: "Devastation", role: "Ranged DPS", resource: "Essence", classColor: "#33937F", iconSlug: "evoker-dev" },
  { id: "evoker-aug", className: "Evoker", specName: "Augmentation", role: "Ranged DPS", resource: "Essence", classColor: "#33937F", iconSlug: "evoker-aug" },
  { id: "evoker-pres", className: "Evoker", specName: "Preservation", role: "Healer", resource: "Mana", classColor: "#33937F", iconSlug: "evoker-pres" },
  { id: "hunter-bm", className: "Hunter", specName: "Beast Mastery", role: "Ranged DPS", resource: "Focus", classColor: "#AAD372", iconSlug: "hunter-bm" },
  { id: "hunter-mm", className: "Hunter", specName: "Marksmanship", role: "Ranged DPS", resource: "Focus", classColor: "#AAD372", iconSlug: "hunter-mm" },
  { id: "hunter-surv", className: "Hunter", specName: "Survival", role: "Melee DPS", resource: "Focus", classColor: "#AAD372", iconSlug: "hunter-surv" },
  { id: "mage-arcane", className: "Mage", specName: "Arcane", role: "Ranged DPS", resource: "Mana", classColor: "#3FC7EB", iconSlug: "mage-arcane" },
  { id: "mage-fire", className: "Mage", specName: "Fire", role: "Ranged DPS", resource: "Mana", classColor: "#3FC7EB", iconSlug: "mage-fire" },
  { id: "mage-frost", className: "Mage", specName: "Frost", role: "Ranged DPS", resource: "Mana", classColor: "#3FC7EB", iconSlug: "mage-frost" },
  { id: "monk-ww", className: "Monk", specName: "Windwalker", role: "Melee DPS", resource: "Chi", classColor: "#00FF98", iconSlug: "monk-ww" },
  { id: "monk-mw", className: "Monk", specName: "Mistweaver", role: "Healer", resource: "Mana", classColor: "#00FF98", iconSlug: "monk-mw" },
  { id: "monk-brew", className: "Monk", specName: "Brewmaster", role: "Tank", resource: "Energy", classColor: "#00FF98", iconSlug: "monk-brew" },
  { id: "paladin-ret", className: "Paladin", specName: "Retribution", role: "Melee DPS", resource: "Holy Power", classColor: "#F48CBA", iconSlug: "paladin-ret" },
  { id: "paladin-prot", className: "Paladin", specName: "Protection", role: "Tank", resource: "Holy Power", classColor: "#F48CBA", iconSlug: "paladin-prot" },
  { id: "paladin-holy", className: "Paladin", specName: "Holy", role: "Healer", resource: "Mana", classColor: "#F48CBA", iconSlug: "paladin-holy" },
  { id: "priest-shadow", className: "Priest", specName: "Shadow", role: "Ranged DPS", resource: "Mana", classColor: "#FFFFFF", iconSlug: "priest-shadow" },
  { id: "priest-disc", className: "Priest", specName: "Discipline", role: "Healer", resource: "Mana", classColor: "#FFFFFF", iconSlug: "priest-disc" },
  { id: "priest-holy", className: "Priest", specName: "Holy", role: "Healer", resource: "Mana", classColor: "#FFFFFF", iconSlug: "priest-holy" },
  { id: "rogue-ass", className: "Rogue", specName: "Assassination", role: "Melee DPS", resource: "Energy", classColor: "#FFF468", iconSlug: "rogue-ass" },
  { id: "rogue-out", className: "Rogue", specName: "Outlaw", role: "Melee DPS", resource: "Energy", classColor: "#FFF468", iconSlug: "rogue-out" },
  { id: "rogue-sub", className: "Rogue", specName: "Subtlety", role: "Melee DPS", resource: "Energy", classColor: "#FFF468", iconSlug: "rogue-sub" },
  { id: "shaman-ele", className: "Shaman", specName: "Elemental", role: "Ranged DPS", resource: "Maelstrom", classColor: "#0070DD", iconSlug: "shaman-ele" },
  { id: "shaman-enh", className: "Shaman", specName: "Enhancement", role: "Melee DPS", resource: "Maelstrom", classColor: "#0070DD", iconSlug: "shaman-enh" },
  { id: "shaman-resto", className: "Shaman", specName: "Restoration", role: "Healer", resource: "Mana", classColor: "#0070DD", iconSlug: "shaman-resto" },
  { id: "warlock-aff", className: "Warlock", specName: "Affliction", role: "Ranged DPS", resource: "Mana", classColor: "#9482C9", iconSlug: "warlock-aff" },
  { id: "warlock-demo", className: "Warlock", specName: "Demonology", role: "Ranged DPS", resource: "Soul Shards", classColor: "#9482C9", iconSlug: "warlock-demo" },
  { id: "warlock-dest", className: "Warlock", specName: "Destruction", role: "Ranged DPS", resource: "Soul Shards", classColor: "#9482C9", iconSlug: "warlock-dest" },
  { id: "warrior-arms", className: "Warrior", specName: "Arms", role: "Melee DPS", resource: "Rage", classColor: "#C69B3A", iconSlug: "warrior-arms" },
  { id: "warrior-fury", className: "Warrior", specName: "Fury", role: "Melee DPS", resource: "Rage", classColor: "#C69B3A", iconSlug: "warrior-fury" },
  { id: "warrior-prot", className: "Warrior", specName: "Protection", role: "Tank", resource: "Rage", classColor: "#C69B3A", iconSlug: "warrior-prot" },
];

/**
 * Seed data for the default Action Priority List (APL) entries.
 *
 * Contains SimulationCraft-quality rotation priorities for every supported
 * WoW specialization. Each entry specifies the spell name, icon, SimC-style
 * condition string, target mode (ST/AoE/Both), and classification flags
 * (interrupt, offensive). These are loaded into the in-memory
 * `aplEntries` map on startup by {@link MemStorage.seed}.
 */
const SEED_APL: (Omit<InsertAplEntry, "isPrecombat" | "precombatType"> & { isPrecombat?: boolean; precombatType?: "state" | "opener" | null })[] = [
  // ── Hunter BM ── TWW SimC-quality priority
  { specId: "hunter-bm", priority: -100, spellName: "Hunter's Mark", spellIcon: "ability_hunter_snipershot", condition: "!debuff.hunters_mark.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "" },
  { specId: "hunter-bm", priority: 1, spellName: "Call of the Wild", spellIcon: "ability_hunter_callofthewild", condition: "cooldown.call_of_the_wild.ready & buff.bestial_wrath.up & fight_remains > 20", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "hunter-bm", priority: 2, spellName: "Bestial Wrath", spellIcon: "ability_druid_ferociousbite", condition: "cooldown.bestial_wrath.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "hunter-bm", priority: 3, spellName: "Barbed Shot", spellIcon: "ability_hunter_barbedshot", condition: "pet.frenzy.stack < 3 | buff.frenzy.remains < gcd.max | cooldown.barbed_shot.charges_fractional >= 1.5", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "hunter-bm", priority: 4, spellName: "Kill Shot", spellIcon: "ability_hunter_assassinate", condition: "target.health.pct <= 20 | buff.hunters_prey.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "hunter-bm", priority: 4, spellName: "Black Arrow", spellIcon: "ability_theblackarrow", condition: "cooldown.black_arrow.ready & (target.health.pct >= 80 | target.health.pct <= 20 | buff.hunters_prey.up)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "hunter-bm", priority: 5, spellName: "Bloodshed", spellIcon: "ability_druid_primaltenacity", condition: "cooldown.bloodshed.ready & pet.alive & buff.bestial_wrath.up", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "hunter-bm", priority: 6, spellName: "Kill Command", spellIcon: "ability_hunter_killcommand", condition: "pet.alive & focus >= 30", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "hunter-bm", priority: 7, spellName: "Dire Beast", spellIcon: "ability_hunter_longevity", condition: "cooldown.dire_beast.ready & talent.dire_beast.enabled", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "hunter-bm", priority: 8, spellName: "Multi-Shot", spellIcon: "ability_upgrademoonglaive", condition: "active_enemies >= 3 & !buff.beast_cleave.up", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "hunter-bm", priority: 9, spellName: "Kill Command", spellIcon: "ability_hunter_killcommand", condition: "pet.alive & active_enemies >= 3 & focus >= 30", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "hunter-bm", priority: 10, spellName: "Cobra Shot", spellIcon: "ability_hunter_cobrashot", condition: "focus > 50 & (buff.bestial_wrath.up | focus > 80)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "hunter-bm", priority: 11, spellName: "Barbed Shot", spellIcon: "ability_hunter_barbedshot", condition: "cooldown.barbed_shot.charges_fractional >= 1.8", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "hunter-bm", priority: 12, spellName: "Exhilaration", spellIcon: "ability_hunter_onewithnature", condition: "player.health.pct <= 40", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "hunter-bm", priority: 13, spellName: "Counter Shot", spellIcon: "ability_hunter_glowingshot", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Havoc DH ── TWW Havoc SimC priority
  { specId: "dh-havoc", priority: 1, spellName: "Metamorphosis", spellIcon: "ability_demonhunter_metamorphasisdps", condition: "cooldown.metamorphosis.ready & fury >= 30 & (fight_remains > 25 | target.health.pct <= 35)", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "dh-havoc", priority: 2, spellName: "The Hunt", spellIcon: "ability_ardenweald_demonhunter", condition: "cooldown.the_hunt.ready", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "dh-havoc", priority: 3, spellName: "Eye Beam", spellIcon: "ability_demonhunter_eyebeam", condition: "fury >= 30 & cooldown.eye_beam.ready & (active_enemies >= 2 | talent.demonic.enabled)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "dh-havoc", priority: 4, spellName: "Essence Break", spellIcon: "ability_demonhunter_essencebreak", condition: "cooldown.essence_break.ready & fury >= 30", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "dh-havoc", priority: 5, spellName: "Death Sweep", spellIcon: "ability_demonhunter_bladedance", condition: "cooldown.blade_dance.ready & buff.metamorphosis.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "dh-havoc", priority: 6, spellName: "Blade Dance", spellIcon: "ability_demonhunter_bladedance", condition: "cooldown.blade_dance.ready & !buff.metamorphosis.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "dh-havoc", priority: 7, spellName: "Glaive Tempest", spellIcon: "inv_glaive_1h_artifactazgalor_d_01dual", condition: "cooldown.glaive_tempest.ready & active_enemies >= 2", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "dh-havoc", priority: 8, spellName: "Annihilation", spellIcon: "ability_demonhunter_chaosstrike", condition: "fury >= 40 & buff.metamorphosis.up", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "dh-havoc", priority: 9, spellName: "Chaos Strike", spellIcon: "ability_demonhunter_chaosstrike", condition: "fury >= 40 & !buff.metamorphosis.up", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "dh-havoc", priority: 10, spellName: "Fel Rush", spellIcon: "ability_demonhunter_felrush", condition: "cooldown.fel_rush.charges >= 1 & !moving & talent.momentum.enabled", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "dh-havoc", priority: 11, spellName: "Throw Glaive", spellIcon: "ability_demonhunter_throwglaive", condition: "cooldown.throw_glaive.charges >= 1 & active_enemies >= 2 & talent.furious_throws.enabled", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "6" },
  { specId: "dh-havoc", priority: 12, spellName: "Demons Bite", spellIcon: "ability_demonhunter_demonspike", condition: "fury < 80 & !talent.demon_blades.enabled", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "dh-havoc", priority: 13, spellName: "Blur", spellIcon: "ability_demonhunter_blur", condition: "player.health.pct <= 50", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "dh-havoc", priority: 14, spellName: "Disrupt", spellIcon: "ability_demonhunter_consumemagic", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Warrior Fury ── TWW Fury SimC priority
  { specId: "warrior-fury", priority: 1, spellName: "Recklessness", spellIcon: "ability_warrior_innerrage", condition: "cooldown.recklessness.ready & (fight_remains > 15 | target.health.pct <= 35)", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "warrior-fury", priority: 2, spellName: "Avatar", spellIcon: "ability_warrior_titansgrip", condition: "cooldown.avatar.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "warrior-fury", priority: 3, spellName: "Rampage", spellIcon: "ability_warrior_rampage", condition: "rage >= 80 | buff.recklessness.up | (buff.enrage.remains < 1.5 & rage >= 60)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "warrior-fury", priority: 4, spellName: "Execute", spellIcon: "inv_sword_48", condition: "(target.health.pct <= 20 | buff.sudden_death.up) & buff.enrage.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "warrior-fury", priority: 5, spellName: "Onslaught", spellIcon: "ability_warrior_devastate", condition: "cooldown.onslaught.ready & buff.enrage.up", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "warrior-fury", priority: 6, spellName: "Bloodthirst", spellIcon: "spell_nature_bloodlust", condition: "buff.enrage.down | buff.enrage.remains < gcd.max", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "warrior-fury", priority: 7, spellName: "Raging Blow", spellIcon: "ability_warrior_rampagingwave", condition: "cooldown.raging_blow.charges >= 1 & buff.enrage.up", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "warrior-fury", priority: 8, spellName: "Whirlwind", spellIcon: "ability_whirlwind", condition: "active_enemies >= 2 & buff.enrage.up", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "warrior-fury", priority: 9, spellName: "Odyn's Fury", spellIcon: "inv_sword_1h_odin_d_01", condition: "cooldown.odyns_fury.ready & buff.enrage.up & active_enemies >= 1", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "warrior-fury", priority: 10, spellName: "Bloodthirst", spellIcon: "spell_nature_bloodlust", condition: "buff.enrage.up & cooldown.bloodthirst.ready", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "warrior-fury", priority: 11, spellName: "Slam", spellIcon: "ability_warrior_decisivestrike", condition: "rage >= 20 & buff.enrage.up", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "warrior-fury", priority: 12, spellName: "Enraged Regeneration", spellIcon: "ability_warrior_focusedrage", condition: "player.health.pct <= 40 & buff.enrage.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "warrior-fury", priority: 13, spellName: "Rallying Cry", spellIcon: "ability_warrior_rallyingcry", condition: "player.health.pct <= 25", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "Z" },
  { specId: "warrior-fury", priority: 14, spellName: "Pummel", spellIcon: "ability_warrior_pummel", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Frost Mage ── TWW SimC-quality priority
  { specId: "mage-frost", priority: 1, spellName: "Icy Veins", spellIcon: "spell_frost_coldhearted", condition: "cooldown.icy_veins.ready & fight_remains > 25", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "mage-frost", priority: 2, spellName: "Frozen Orb", spellIcon: "spell_frost_frozenorb", condition: "cooldown.frozen_orb.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "mage-frost", priority: 3, spellName: "Comet Storm", spellIcon: "spell_mage_cometstorm2", condition: "cooldown.comet_storm.ready & talent.comet_storm.enabled & (prev_gcd.1.flurry | debuff.winters_chill.up)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "mage-frost", priority: 4, spellName: "Glacial Spike", spellIcon: "ability_mage_glacialspike", condition: "buff.icicles.stack >= 5 & (buff.brain_freeze.up | prev_gcd.1.glacial_spike)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "mage-frost", priority: 5, spellName: "Flurry", spellIcon: "ability_warlock_burningembersblue", condition: "buff.brain_freeze.up & (prev_gcd.1.frostbolt | prev_gcd.1.glacial_spike)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "mage-frost", priority: 6, spellName: "Ray of Frost", spellIcon: "ability_mage_rayoffrost", condition: "cooldown.ray_of_frost.ready & talent.ray_of_frost.enabled & buff.icy_veins.up & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "mage-frost", priority: 7, spellName: "Ice Lance", spellIcon: "spell_frost_frostbolt", condition: "buff.fingers_of_frost.up | debuff.winters_chill.up | (moving & !buff.brain_freeze.up)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "mage-frost", priority: 8, spellName: "Blizzard", spellIcon: "spell_frost_icestorm", condition: "active_enemies >= 3", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "mage-frost", priority: 9, spellName: "Cone of Cold", spellIcon: "spell_frost_glacier", condition: "active_enemies >= 4 & talent.freezing_rain.enabled", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "6" },
  { specId: "mage-frost", priority: 10, spellName: "Shifting Power", spellIcon: "ability_ardenweald_mage", condition: "cooldown.shifting_power.ready & !moving", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "mage-frost", priority: 11, spellName: "Frostbolt", spellIcon: "spell_frost_frostbolt02", condition: "buff.brain_freeze.down & buff.fingers_of_frost.down & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "mage-frost", priority: 12, spellName: "Ice Nova", spellIcon: "spell_mage_icenova", condition: "cooldown.ice_nova.ready & active_enemies >= 2 & talent.ice_nova.enabled", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "7" },
  { specId: "mage-frost", priority: 13, spellName: "Ice Barrier", spellIcon: "spell_ice_lament", condition: "player.health.pct <= 50 & buff.ice_barrier.down", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "mage-frost", priority: 14, spellName: "Counterspell", spellIcon: "spell_frost_iceshock", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Elemental Shaman ── TWW SimC-quality priority
  { specId: "shaman-ele", priority: 1, spellName: "Fire Elemental", spellIcon: "spell_fire_elemental_totem", condition: "cooldown.fire_elemental.ready & fight_remains > 25", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "shaman-ele", priority: 2, spellName: "Stormkeeper", spellIcon: "ability_thunderking_thunderstruck", condition: "cooldown.stormkeeper.ready & talent.stormkeeper.enabled", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "shaman-ele", priority: 3, spellName: "Flame Shock", spellIcon: "spell_fire_flameshock", condition: "debuff.flame_shock.remains < 6 | !debuff.flame_shock.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "shaman-ele", priority: 4, spellName: "Primordial Wave", spellIcon: "ability_maldraxxus_shaman", condition: "cooldown.primordial_wave.ready & talent.primordial_wave.enabled & debuff.flame_shock.up & buff.stormkeeper.down", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "shaman-ele", priority: 5, spellName: "Lava Burst", spellIcon: "spell_shaman_lavaburst", condition: "buff.lava_surge.up & debuff.flame_shock.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "shaman-ele", priority: 6, spellName: "Earthquake", spellIcon: "spell_shaman_earthquake", condition: "active_enemies >= 3 & (maelstrom >= 60 | buff.echoes_of_great_sundering.up)", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "shaman-ele", priority: 7, spellName: "Earth Shock", spellIcon: "spell_nature_earthshock", condition: "maelstrom >= 90 | (buff.stormkeeper.up & maelstrom >= 60)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "shaman-ele", priority: 8, spellName: "Lava Burst", spellIcon: "spell_shaman_lavaburst", condition: "cooldown.lava_burst.ready & debuff.flame_shock.up & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "shaman-ele", priority: 9, spellName: "Icefury", spellIcon: "spell_frost_iceshard", condition: "cooldown.icefury.ready & talent.icefury.enabled & maelstrom < 70 & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "shaman-ele", priority: 10, spellName: "Frost Shock", spellIcon: "spell_frost_frostshock", condition: "buff.icefury.up | moving", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "shaman-ele", priority: 11, spellName: "Chain Lightning", spellIcon: "spell_nature_chainlightning", condition: "active_enemies >= 3 & maelstrom < 100 & !moving", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "6" },
  { specId: "shaman-ele", priority: 12, spellName: "Lightning Bolt", spellIcon: "spell_nature_lightning", condition: "maelstrom < 100 & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "shaman-ele", priority: 13, spellName: "Astral Shift", spellIcon: "ability_shaman_astralshift", condition: "player.health.pct <= 40", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "shaman-ele", priority: 14, spellName: "Wind Shear", spellIcon: "spell_nature_cyclone", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Death Knight Blood ── TWW Blood DK priority (active mitigation, damage smoothing, resource management)
  { specId: "dk-blood", priority: 1, spellName: "Death Strike", spellIcon: "spell_deathknight_butcher2", condition: "runic_power >= 40 & (player.health.pct <= 60 | buff.dark_succor.up)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "dk-blood", priority: 2, spellName: "Marrowrend", spellIcon: "ability_deathknight_marrowrend", condition: "buff.bone_shield.stack < 5 | (buff.bone_shield.stack < 8 & buff.bone_shield.remains < 5)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "dk-blood", priority: 3, spellName: "Dancing Rune Weapon", spellIcon: "inv_sword_07", condition: "cooldown.dancing_rune_weapon.ready & (active_enemies >= 2 | player.health.pct <= 50)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "Q" },
  { specId: "dk-blood", priority: 4, spellName: "Blood Boil", spellIcon: "spell_deathknight_bloodboil", condition: "cooldown.blood_boil.charges >= 1 & (debuff.blood_plague.down | active_enemies >= 2)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "dk-blood", priority: 5, spellName: "Vampiric Blood", spellIcon: "spell_shadow_lifedrain", condition: "cooldown.vampiric_blood.ready & player.health.pct <= 50", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "dk-blood", priority: 6, spellName: "Bonestorm", spellIcon: "ability_deathknight_bonestorm", condition: "cooldown.bonestorm.ready & runic_power >= 100 & active_enemies >= 3", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "dk-blood", priority: 7, spellName: "Tombstone", spellIcon: "ability_fiegndead", condition: "cooldown.tombstone.ready & buff.bone_shield.stack >= 5 & player.health.pct <= 70", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "G" },
  { specId: "dk-blood", priority: 8, spellName: "Consumption", spellIcon: "spell_shadow_soulleech_3", condition: "cooldown.consumption.ready & active_enemies >= 1", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "dk-blood", priority: 9, spellName: "Heart Strike", spellIcon: "inv_misc_bone_orcskull_01", condition: "buff.bone_shield.stack >= 5", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "dk-blood", priority: 10, spellName: "Death and Decay", spellIcon: "spell_shadow_deathanddecay", condition: "cooldown.death_and_decay.ready & active_enemies >= 2", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "dk-blood", priority: 11, spellName: "Death Strike", spellIcon: "spell_deathknight_butcher2", condition: "runic_power >= 80", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "dk-blood", priority: 12, spellName: "Icebound Fortitude", spellIcon: "spell_deathknight_iceboundfortitude", condition: "cooldown.icebound_fortitude.ready & player.health.pct <= 30", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "Z" },
  { specId: "dk-blood", priority: 13, spellName: "Mind Freeze", spellIcon: "spell_deathknight_mindfreeze", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Death Knight Frost ── TWW Frost DK SimC priority
  { specId: "dk-frost", priority: 1, spellName: "Pillar of Frost", spellIcon: "ability_deathknight_pillaroffrost", condition: "cooldown.pillar_of_frost.ready & (fight_remains > 15 | target.health.pct <= 20)", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "dk-frost", priority: 2, spellName: "Empower Rune Weapon", spellIcon: "inv_sword_62", condition: "cooldown.empower_rune_weapon.ready & buff.pillar_of_frost.up & runic_power < 70", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "dk-frost", priority: 3, spellName: "Breath of Sindragosa", spellIcon: "spell_deathknight_breathofsindragosa", condition: "cooldown.breath_of_sindragosa.ready & runic_power >= 60 & buff.pillar_of_frost.up & talent.breath_of_sindragosa.enabled", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "dk-frost", priority: 4, spellName: "Frostwyrms Fury", spellIcon: "achievement_boss_sindragosa", condition: "cooldown.frostwyrms_fury.ready & buff.pillar_of_frost.remains < 3 & buff.pillar_of_frost.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "dk-frost", priority: 5, spellName: "Obliterate", spellIcon: "spell_deathknight_classicon", condition: "buff.killing_machine.up", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "dk-frost", priority: 6, spellName: "Howling Blast", spellIcon: "spell_frost_arcticwinds", condition: "buff.rime.up & (active_enemies >= 2 | runic_power < 60)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "dk-frost", priority: 7, spellName: "Frost Strike", spellIcon: "spell_deathknight_empowerruneblade2", condition: "runic_power >= 80 | (buff.icy_talons.stack < 3 & runic_power >= 25) | (buff.pillar_of_frost.up & runic_power >= 40)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "dk-frost", priority: 8, spellName: "Remorseless Winter", spellIcon: "ability_deathknight_remorselesswinters2", condition: "cooldown.remorseless_winter.ready & (active_enemies >= 2 | buff.pillar_of_frost.up)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "dk-frost", priority: 9, spellName: "Glacial Advance", spellIcon: "ability_hunter_glacialtrap", condition: "active_enemies >= 2 & runic_power >= 30", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "dk-frost", priority: 10, spellName: "Howling Blast", spellIcon: "spell_frost_arcticwinds", condition: "!debuff.frost_fever.up | debuff.frost_fever.remains < 3", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "dk-frost", priority: 11, spellName: "Horn of Winter", spellIcon: "inv_misc_horn_02", condition: "cooldown.horn_of_winter.ready & runic_power < 50 & talent.horn_of_winter.enabled", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "dk-frost", priority: 12, spellName: "Obliterate", spellIcon: "spell_deathknight_classicon", condition: "!buff.killing_machine.up & runic_power < 80", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "dk-frost", priority: 13, spellName: "Anti-Magic Shell", spellIcon: "spell_shadow_antimagicshell", condition: "player.health.pct <= 50 | (runic_power < 40 & buff.breath_of_sindragosa.up)", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "dk-frost", priority: 14, spellName: "Mind Freeze", spellIcon: "spell_deathknight_mindfreeze", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Death Knight Unholy ── TWW Unholy DK SimC priority
  { specId: "dk-unholy", priority: 1, spellName: "Dark Transformation", spellIcon: "achievement_boss_festergutrotface", condition: "cooldown.dark_transformation.ready & pet.alive & (fight_remains > 20 | target.health.pct <= 35)", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "dk-unholy", priority: 2, spellName: "Unholy Assault", spellIcon: "spell_shadow_unholyfrenzy", condition: "cooldown.unholy_assault.ready & debuff.festering_wound.stack >= 2", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "dk-unholy", priority: 3, spellName: "Apocalypse", spellIcon: "artifactability_unholydeathknight_apocalypse", condition: "cooldown.apocalypse.ready & debuff.festering_wound.stack >= 4 & buff.dark_transformation.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "dk-unholy", priority: 4, spellName: "Soul Reaper", spellIcon: "ability_deathknight_soulreaper", condition: "target.health.pct <= 35 & cooldown.soul_reaper.ready & debuff.festering_wound.stack >= 1", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "dk-unholy", priority: 5, spellName: "Outbreak", spellIcon: "spell_deathvortex", condition: "debuff.virulent_plague.down | debuff.virulent_plague.remains < 3", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "dk-unholy", priority: 6, spellName: "Death and Decay", spellIcon: "spell_shadow_deathanddecay", condition: "cooldown.death_and_decay.ready & (active_enemies >= 2 | talent.unholy_ground.enabled)", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "6" },
  { specId: "dk-unholy", priority: 7, spellName: "Death Coil", spellIcon: "spell_shadow_deathcoil", condition: "buff.sudden_doom.up | (runic_power >= 80 & !variable.pooling_for_gargoyle)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "dk-unholy", priority: 8, spellName: "Epidemic", spellIcon: "spell_shadow_unstableaffliction_3", condition: "active_enemies >= 3 & (buff.sudden_doom.up | runic_power >= 30)", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "dk-unholy", priority: 9, spellName: "Festering Strike", spellIcon: "spell_deathknight_festerstrike", condition: "debuff.festering_wound.stack < 4 & (cooldown.apocalypse.remains < 5 | debuff.festering_wound.stack <= 1)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "dk-unholy", priority: 10, spellName: "Scourge Strike", spellIcon: "spell_deathknight_scourgestrike", condition: "debuff.festering_wound.stack >= 1", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "dk-unholy", priority: 11, spellName: "Wound Spender", spellIcon: "spell_deathknight_scourgestrike", condition: "debuff.festering_wound.stack >= 1 & active_enemies >= 3", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "dk-unholy", priority: 12, spellName: "Death Coil", spellIcon: "spell_shadow_deathcoil", condition: "runic_power >= 40 & !buff.sudden_doom.up", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "dk-unholy", priority: 13, spellName: "Anti-Magic Shell", spellIcon: "spell_shadow_antimagicshell", condition: "player.health.pct <= 50", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "dk-unholy", priority: 14, spellName: "Mind Freeze", spellIcon: "spell_deathknight_mindfreeze", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Demon Hunter Vengeance ── TWW Vengeance priority (active mitigation, soul fragment management, threat)
  { specId: "dh-vengeance", priority: 1, spellName: "Demon Spikes", spellIcon: "ability_demonhunter_demonspikes", condition: "cooldown.demon_spikes.charges >= 1 & buff.demon_spikes.down & player.health.pct <= 80", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "E" },
  { specId: "dh-vengeance", priority: 2, spellName: "Fiery Brand", spellIcon: "ability_demonhunter_fierybrand", condition: "cooldown.fiery_brand.ready & (player.health.pct <= 55 | active_enemies >= 3)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "Q" },
  { specId: "dh-vengeance", priority: 3, spellName: "Fel Devastation", spellIcon: "ability_demonhunter_feldevastation", condition: "cooldown.fel_devastation.ready & pain >= 50", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "dh-vengeance", priority: 4, spellName: "Spirit Bomb", spellIcon: "inv_icon_shadowcouncilorb_purple", condition: "buff.frailty.stack >= 4 & pain >= 40 & active_enemies >= 2", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "dh-vengeance", priority: 5, spellName: "Soul Cleave", spellIcon: "ability_demonhunter_soulcleave", condition: "pain >= 30 & (player.health.pct <= 65 | pain >= 70)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "dh-vengeance", priority: 6, spellName: "Immolation Aura", spellIcon: "ability_demonhunter_immolation", condition: "cooldown.immolation_aura.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "dh-vengeance", priority: 7, spellName: "Sigil of Flame", spellIcon: "ability_demonhunter_sigilofinquisition", condition: "cooldown.sigil_of_flame.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "dh-vengeance", priority: 8, spellName: "Fracture", spellIcon: "ability_creature_felsunder", condition: "pain < 80 & cooldown.fracture.charges >= 1", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "dh-vengeance", priority: 9, spellName: "The Hunt", spellIcon: "ability_ardenweald_demonhunter", condition: "cooldown.the_hunt.ready & buff.demon_spikes.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "dh-vengeance", priority: 10, spellName: "Infernal Strike", spellIcon: "ability_demonhunter_infernalstrike1", condition: "cooldown.infernal_strike.charges >= 2", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "6" },
  { specId: "dh-vengeance", priority: 11, spellName: "Metamorphosis", spellIcon: "ability_demonhunter_metamorphasistank", condition: "cooldown.metamorphosis.ready & player.health.pct <= 30", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "Z" },
  { specId: "dh-vengeance", priority: 12, spellName: "Soul Cleave", spellIcon: "ability_demonhunter_soulcleave", condition: "pain >= 60", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "dh-vengeance", priority: 13, spellName: "Disrupt", spellIcon: "ability_demonhunter_consumemagic", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Druid Balance ── TWW/Midnight SimC-quality priority (moonkin/caster form primary, bear form fallback)
  // Eclipse spells are castable buttons in 12.0 (2 charges, 32s recharge). Maintain Eclipse uptime.
  { specId: "druid-balance", priority: 1, spellName: "Solar Eclipse", spellIcon: "ability_druid_eclipseorange", condition: "(form.moonkin | form.caster) & eclipse.in_none & cooldown.solar_eclipse.ready", mode: "ST", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "" },
  { specId: "druid-balance", priority: 1, spellName: "Lunar Eclipse", spellIcon: "ability_druid_eclipse", condition: "(form.moonkin | form.caster) & eclipse.in_none & cooldown.lunar_eclipse.ready", mode: "AoE", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "" },
  { specId: "druid-balance", priority: 1, spellName: "Solar Eclipse", spellIcon: "ability_druid_eclipseorange", condition: "(form.moonkin | form.caster) & eclipse.in_none & cooldown.solar_eclipse.ready & active_enemies < 3", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "" },
  { specId: "druid-balance", priority: 1, spellName: "Lunar Eclipse", spellIcon: "ability_druid_eclipse", condition: "(form.moonkin | form.caster) & eclipse.in_none & cooldown.lunar_eclipse.ready & active_enemies >= 3", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "" },
  { specId: "druid-balance", priority: 2, spellName: "Celestial Alignment", spellIcon: "spell_nature_natureguardian", condition: "(form.moonkin | form.caster) & cooldown.celestial_alignment.ready & fight_remains > 20 & (astral_power >= 50 | time < 5)", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "druid-balance", priority: 3, spellName: "Fury of Elune", spellIcon: "ability_druid_dreamstate", condition: "(form.moonkin | form.caster) & cooldown.fury_of_elune.ready & talent.fury_of_elune.enabled", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "E" },
  { specId: "druid-balance", priority: 4, spellName: "Sunfire", spellIcon: "ability_mage_firestarter", condition: "(form.moonkin | form.caster) & (debuff.sunfire.remains < 3.6 | !debuff.sunfire.up)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "druid-balance", priority: 5, spellName: "Moonfire", spellIcon: "spell_nature_starfall", condition: "(form.moonkin | form.caster) & (debuff.moonfire.remains < 4.2 | !debuff.moonfire.up)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "druid-balance", priority: 6, spellName: "Stellar Flare", spellIcon: "ability_druid_stellarflare", condition: "(form.moonkin | form.caster) & talent.stellar_flare.enabled & (debuff.stellar_flare.remains < 7.2 | !debuff.stellar_flare.up) & active_enemies <= 3 & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "druid-balance", priority: 6, spellName: "Starfall", spellIcon: "ability_druid_starfall", condition: "(form.moonkin | form.caster) & active_enemies >= 3 & (astral_power >= 50 | buff.starweavers_warp.up) & buff.starfall.remains < 2", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "druid-balance", priority: 7, spellName: "Starsurge", spellIcon: "spell_arcane_arcane03", condition: "(form.moonkin | form.caster) & astral_power >= 40 & (buff.celestial_alignment.up | astral_power >= 90 | buff.starweavers_weft.up)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "druid-balance", priority: 8, spellName: "Wild Mushroom", spellIcon: "druid_ability_wildmushroom_a", condition: "(form.moonkin | form.caster) & cooldown.wild_mushroom.ready & talent.wild_mushroom.enabled & active_enemies >= 3", mode: "AoE", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "G" },
  { specId: "druid-balance", priority: 9, spellName: "New Moon", spellIcon: "ability_druid_halfmoon", condition: "(form.moonkin | form.caster) & cooldown.new_moon.ready & talent.new_moon.enabled & astral_power <= 80", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "7" },
  { specId: "druid-balance", priority: 10, spellName: "Wrath", spellIcon: "spell_nature_wrathv2", condition: "(form.moonkin | form.caster) & buff.eclipse_solar.up & !moving", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "druid-balance", priority: 11, spellName: "Starfire", spellIcon: "spell_arcane_starfire", condition: "(form.moonkin | form.caster) & (buff.eclipse_lunar.up | active_enemies >= 3) & !moving", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "6" },
  { specId: "druid-balance", priority: 12, spellName: "Starsurge", spellIcon: "spell_arcane_arcane03", condition: "(form.moonkin | form.caster) & moving & astral_power >= 40", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "druid-balance", priority: 20, spellName: "Wrath", spellIcon: "spell_nature_wrathv2", condition: "(form.moonkin | form.caster) & !moving", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  // Balance bear form fallback — emergency survivability when shifted to bear
  { specId: "druid-balance", priority: 13, spellName: "Thrash", spellIcon: "spell_druid_thrash", condition: "form.bear & cooldown.thrash.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "" },
  { specId: "druid-balance", priority: 14, spellName: "Mangle", spellIcon: "ability_druid_mangle2", condition: "form.bear & cooldown.mangle.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "" },
  { specId: "druid-balance", priority: 15, spellName: "Ironfur", spellIcon: "ability_druid_ironfur", condition: "form.bear & rage >= 40", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "" },
  { specId: "druid-balance", priority: 16, spellName: "Frenzied Regeneration", spellIcon: "ability_bullrush", condition: "form.bear & player.health.pct <= 50 & cooldown.frenzied_regeneration.charges >= 1", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "" },
  { specId: "druid-balance", priority: 17, spellName: "Barkskin", spellIcon: "spell_nature_stoneclawtotem", condition: "player.health.pct <= 45", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "druid-balance", priority: 18, spellName: "Solar Beam", spellIcon: "ability_vehicle_sonicshockwave", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Druid Feral ── TWW Feral SimC priority (form-gated: cat form abilities)
  { specId: "druid-feral", priority: 1, spellName: "Tigers Fury", spellIcon: "ability_mount_jungletiger", condition: "form.cat & cooldown.tigers_fury.ready & (energy < 40 | buff.tigers_fury.down)", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "druid-feral", priority: 2, spellName: "Berserk", spellIcon: "ability_druid_berserk", condition: "form.cat & cooldown.berserk.ready & buff.tigers_fury.up & (fight_remains > 15 | target.health.pct <= 20)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "druid-feral", priority: 3, spellName: "Feral Frenzy", spellIcon: "ability_druid_rake", condition: "form.cat & cooldown.feral_frenzy.ready & combo_points <= 2 & buff.tigers_fury.up", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "druid-feral", priority: 4, spellName: "Primal Wrath", spellIcon: "ability_druid_primalwrath", condition: "form.cat & combo_points >= 5 & active_enemies >= 3 & debuff.rip.pandemic", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "druid-feral", priority: 5, spellName: "Rip", spellIcon: "ability_ghoulfrenzy", condition: "form.cat & combo_points >= 5 & (debuff.rip.down | debuff.rip.pandemic) & target.health.pct > 25", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "druid-feral", priority: 6, spellName: "Ferocious Bite", spellIcon: "ability_druid_ferociousbite", condition: "form.cat & combo_points >= 5 & (target.health.pct <= 25 | (energy >= 50 & debuff.rip.up))", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "druid-feral", priority: 7, spellName: "Rake", spellIcon: "ability_druid_disembowel", condition: "form.cat & (debuff.rake.down | debuff.rake.pandemic) & (buff.tigers_fury.up | buff.berserk.up | debuff.rake.down)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "druid-feral", priority: 8, spellName: "Thrash", spellIcon: "spell_druid_thrash", condition: "form.cat & (debuff.thrash.pandemic | (active_enemies >= 3 & debuff.thrash.remains < 3))", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "6" },
  { specId: "druid-feral", priority: 9, spellName: "Brutal Slash", spellIcon: "ability_druid_ravage", condition: "form.cat & (cooldown.brutal_slash.charges >= 2 | (cooldown.brutal_slash.charges >= 1 & active_enemies >= 2))", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "druid-feral", priority: 10, spellName: "Moonfire", spellIcon: "spell_nature_starfall", condition: "form.cat & talent.lunar_inspiration.enabled & (debuff.moonfire.down | debuff.moonfire.pandemic) & combo_points < 5", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "7" },
  { specId: "druid-feral", priority: 11, spellName: "Shred", spellIcon: "spell_shadow_vampiricaura", condition: "form.cat & energy >= 40 & combo_points < 5 & (buff.berserk.up | buff.tigers_fury.up | energy >= 80)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "druid-feral", priority: 12, spellName: "Shred", spellIcon: "spell_shadow_vampiricaura", condition: "form.cat & energy >= 50 & combo_points < 5", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  // Feral bear form fallback — emergency survivability
  { specId: "druid-feral", priority: 13, spellName: "Frenzied Regeneration", spellIcon: "ability_bullrush", condition: "form.bear & player.health.pct <= 50 & cooldown.frenzied_regeneration.charges >= 1", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "" },
  { specId: "druid-feral", priority: 14, spellName: "Ironfur", spellIcon: "ability_druid_ironfur", condition: "form.bear & rage >= 40", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "" },
  { specId: "druid-feral", priority: 15, spellName: "Survival Instincts", spellIcon: "ability_druid_tigersroar", condition: "player.health.pct <= 35 & cooldown.survival_instincts.charges >= 1", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "druid-feral", priority: 16, spellName: "Skull Bash", spellIcon: "inv_bone_skull_04", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Druid Guardian ── TWW Guardian priority (form-gated: bear form primary)
  { specId: "druid-guardian", priority: 1, spellName: "Ironfur", spellIcon: "ability_druid_ironfur", condition: "form.bear & rage >= 40 & (buff.ironfur.down | buff.ironfur.remains < 2)", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "4" },
  { specId: "druid-guardian", priority: 2, spellName: "Frenzied Regeneration", spellIcon: "ability_bullrush", condition: "form.bear & cooldown.frenzied_regeneration.charges >= 1 & player.health.pct <= 55 & buff.frenzied_regeneration.down", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "druid-guardian", priority: 3, spellName: "Incarnation: Guardian of Ursoc", spellIcon: "spell_druid_incarnation", condition: "form.bear & cooldown.incarnation_guardian_of_ursoc.ready & (active_enemies >= 3 | player.health.pct <= 45)", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "druid-guardian", priority: 4, spellName: "Mangle", spellIcon: "ability_druid_mangle2", condition: "form.bear & cooldown.mangle.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "druid-guardian", priority: 5, spellName: "Thrash", spellIcon: "spell_druid_thrash", condition: "form.bear & cooldown.thrash.ready & (debuff.thrash.stack < 3 | debuff.thrash.remains < 4)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "druid-guardian", priority: 6, spellName: "Moonfire", spellIcon: "spell_nature_starfall", condition: "form.bear & (debuff.moonfire.pandemic | debuff.moonfire.down)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "druid-guardian", priority: 7, spellName: "Pulverize", spellIcon: "spell_druid_malfurionstenacity", condition: "form.bear & debuff.thrash.stack >= 2 & buff.pulverize.remains < 4", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "druid-guardian", priority: 8, spellName: "Raze", spellIcon: "ability_druid_mangle", condition: "form.bear & rage >= 40 & active_enemies >= 3 & buff.ironfur.up", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "druid-guardian", priority: 9, spellName: "Maul", spellIcon: "ability_druid_maul", condition: "form.bear & rage >= 40 & buff.ironfur.up & rage >= 70", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "druid-guardian", priority: 10, spellName: "Swipe", spellIcon: "inv_misc_monsterclaw_03", condition: "form.bear & active_enemies >= 2", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "6" },
  // Guardian cat form fallback — emergency DPS when shifted to cat
  { specId: "druid-guardian", priority: 11, spellName: "Rake", spellIcon: "ability_druid_disembowel", condition: "form.cat & (debuff.rake.down | debuff.rake.pandemic)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "" },
  { specId: "druid-guardian", priority: 12, spellName: "Shred", spellIcon: "spell_shadow_vampiricaura", condition: "form.cat & energy >= 40", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "" },
  { specId: "druid-guardian", priority: 13, spellName: "Barkskin", spellIcon: "spell_nature_stoneclawtotem", condition: "cooldown.barkskin.ready & player.health.pct <= 40", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "Z" },
  { specId: "druid-guardian", priority: 14, spellName: "Ironfur", spellIcon: "ability_druid_ironfur", condition: "form.bear & rage >= 80", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "4" },
  { specId: "druid-guardian", priority: 15, spellName: "Skull Bash", spellIcon: "inv_bone_skull_04", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Druid Restoration ── TWW Resto Druid priority (caster form primary, cat form fallback for DPS)
  { specId: "druid-resto", priority: 1, spellName: "Swiftmend", spellIcon: "inv_relics_idolofrejuvenation", condition: "(form.caster | form.moonkin) & cooldown.swiftmend.ready & player.health.pct <= 50", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "E" },
  { specId: "druid-resto", priority: 2, spellName: "Ironbark", spellIcon: "spell_druid_ironbark", condition: "(form.caster | form.moonkin) & cooldown.ironbark.ready & player.health.pct <= 35", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "druid-resto", priority: 3, spellName: "Wild Growth", spellIcon: "ability_druid_flourish", condition: "(form.caster | form.moonkin) & cooldown.wild_growth.ready & mana >= 8", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "Q" },
  { specId: "druid-resto", priority: 4, spellName: "Lifebloom", spellIcon: "inv_misc_herb_felblossom", condition: "(form.caster | form.moonkin) & (buff.lifebloom.down | buff.lifebloom.remains < 4)", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "2" },
  { specId: "druid-resto", priority: 5, spellName: "Flourish", spellIcon: "spell_druid_wildburst", condition: "(form.caster | form.moonkin) & cooldown.flourish.ready & buff.wild_growth.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "R" },
  { specId: "druid-resto", priority: 6, spellName: "Efflorescence", spellIcon: "inv_misc_herb_talandrasrose", condition: "(form.caster | form.moonkin) & cooldown.efflorescence.ready", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "3" },
  { specId: "druid-resto", priority: 7, spellName: "Rejuvenation", spellIcon: "spell_nature_rejuvenation", condition: "(form.caster | form.moonkin) & mana >= 10", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "1" },
  { specId: "druid-resto", priority: 8, spellName: "Sunfire", spellIcon: "ability_mage_firestarter", condition: "(form.caster | form.moonkin) & (debuff.sunfire.pandemic | debuff.sunfire.down)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "druid-resto", priority: 9, spellName: "Moonfire", spellIcon: "spell_nature_starfall", condition: "(form.caster | form.moonkin) & (debuff.moonfire.pandemic | debuff.moonfire.down)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "druid-resto", priority: 10, spellName: "Wrath", spellIcon: "spell_nature_wrathv2", condition: "(form.caster | form.moonkin) & mana >= 30 & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "6" },
  // Resto cat form fallback — show Cat-appropriate abilities when shifted
  { specId: "druid-resto", priority: 11, spellName: "Rake", spellIcon: "ability_druid_disembowel", condition: "form.cat & (debuff.rake.down | debuff.rake.pandemic)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "" },
  { specId: "druid-resto", priority: 12, spellName: "Shred", spellIcon: "spell_shadow_vampiricaura", condition: "form.cat & energy >= 40", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "" },
  { specId: "druid-resto", priority: 13, spellName: "Ferocious Bite", spellIcon: "ability_druid_ferociousbite", condition: "form.cat & combo_points >= 4", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "" },
  // Resto bear form fallback — emergency tanking
  { specId: "druid-resto", priority: 14, spellName: "Thrash", spellIcon: "spell_druid_thrash", condition: "form.bear & cooldown.thrash.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "" },
  { specId: "druid-resto", priority: 15, spellName: "Ironfur", spellIcon: "ability_druid_ironfur", condition: "form.bear & rage >= 40", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "" },
  { specId: "druid-resto", priority: 16, spellName: "Barkskin", spellIcon: "spell_nature_stoneclawtotem", condition: "cooldown.barkskin.ready & player.health.pct <= 40", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "Z" },
  { specId: "druid-resto", priority: 17, spellName: "Innervate", spellIcon: "spell_nature_lightning", condition: "(form.caster | form.moonkin) & cooldown.innervate.ready & mana <= 40", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "G" },
  { specId: "druid-resto", priority: 18, spellName: "Solar Beam", spellIcon: "ability_vehicle_sonicshockwave", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Evoker Devastation ── TWW SimC-quality priority
  { specId: "evoker-dev", priority: 1, spellName: "Dragonrage", spellIcon: "ability_evoker_dragonrage", condition: "cooldown.dragonrage.ready & fight_remains > 18 & (essence >= 2 | buff.essence_burst.up)", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "evoker-dev", priority: 2, spellName: "Tip the Scales", spellIcon: "ability_evoker_tipthescales", condition: "cooldown.tip_the_scales.ready & buff.dragonrage.up & (cooldown.fire_breath.ready | cooldown.eternity_surge.ready)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "evoker-dev", priority: 3, spellName: "Shattering Star", spellIcon: "ability_evoker_shatteringstar", condition: "cooldown.shattering_star.ready & talent.shattering_star.enabled", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "evoker-dev", priority: 4, spellName: "Fire Breath", spellIcon: "ability_evoker_firebreath", condition: "cooldown.fire_breath.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "evoker-dev", priority: 5, spellName: "Eternity Surge", spellIcon: "ability_evoker_eternitysurge", condition: "cooldown.eternity_surge.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "evoker-dev", priority: 6, spellName: "Deep Breath", spellIcon: "ability_evoker_deepbreath", condition: "cooldown.deep_breath.ready & active_enemies >= 3 & !buff.dragonrage.up", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "evoker-dev", priority: 7, spellName: "Pyre", spellIcon: "ability_evoker_pyre", condition: "active_enemies >= 3 & (buff.essence_burst.up | essence >= 2)", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "evoker-dev", priority: 8, spellName: "Disintegrate", spellIcon: "ability_evoker_disintegrate", condition: "(buff.essence_burst.up | essence >= 3) & active_enemies < 3 & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "evoker-dev", priority: 9, spellName: "Azure Strike", spellIcon: "ability_evoker_azurestrike", condition: "active_enemies >= 2 | (moving & !buff.essence_burst.up)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "evoker-dev", priority: 10, spellName: "Living Flame", spellIcon: "ability_evoker_livingflame", condition: "(buff.burnout.up | !buff.essence_burst.up) & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "evoker-dev", priority: 11, spellName: "Verdant Embrace", spellIcon: "ability_evoker_verdantemb", condition: "talent.scarlet_adaptation.enabled & player.health.pct <= 70", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "7" },
  { specId: "evoker-dev", priority: 12, spellName: "Living Flame", spellIcon: "ability_evoker_livingflame", condition: "moving & buff.burnout.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "evoker-dev", priority: 13, spellName: "Obsidian Scales", spellIcon: "ability_evoker_obsidianscales", condition: "player.health.pct <= 40", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "evoker-dev", priority: 14, spellName: "Quell", spellIcon: "ability_evoker_quell", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Evoker Augmentation ── TWW SimC-quality priority
  { specId: "evoker-aug", priority: 1, spellName: "Ebon Might", spellIcon: "ability_evoker_ebonmight", condition: "cooldown.ebon_might.ready & (buff.ebon_might.remains < 3 | !buff.ebon_might.up)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "Q" },
  { specId: "evoker-aug", priority: 2, spellName: "Breath of Eons", spellIcon: "ability_evoker_breathofeons", condition: "cooldown.breath_of_eons.ready & buff.ebon_might.up & fight_remains > 15", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "evoker-aug", priority: 3, spellName: "Prescience", spellIcon: "ability_evoker_prescience", condition: "cooldown.prescience.charges >= 1 & (buff.ebon_might.up | cooldown.ebon_might.remains < gcd.max)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "evoker-aug", priority: 4, spellName: "Fire Breath", spellIcon: "ability_evoker_firebreath", condition: "cooldown.fire_breath.ready & buff.ebon_might.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "evoker-aug", priority: 5, spellName: "Upheaval", spellIcon: "ability_evoker_upheaval", condition: "cooldown.upheaval.ready & buff.ebon_might.up & !moving", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "evoker-aug", priority: 6, spellName: "Eruption", spellIcon: "ability_evoker_eruption", condition: "buff.ebon_might.up & essence >= 1 & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "evoker-aug", priority: 7, spellName: "Blistering Scales", spellIcon: "ability_evoker_blisteringscales", condition: "cooldown.blistering_scales.ready & talent.blistering_scales.enabled", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "evoker-aug", priority: 8, spellName: "Living Flame", spellIcon: "ability_evoker_livingflame", condition: "buff.leaping_flames.up & !moving", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "evoker-aug", priority: 9, spellName: "Azure Strike", spellIcon: "ability_evoker_azurestrike", condition: "active_enemies >= 2 | (moving & buff.ebon_might.down)", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "evoker-aug", priority: 10, spellName: "Time Skip", spellIcon: "ability_evoker_timeskip", condition: "cooldown.time_skip.ready & talent.time_skip.enabled & buff.ebon_might.down", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "evoker-aug", priority: 11, spellName: "Living Flame", spellIcon: "ability_evoker_livingflame", condition: "buff.ebon_might.down & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "evoker-aug", priority: 12, spellName: "Emerald Blossom", spellIcon: "ability_evoker_emeraldblossom", condition: "talent.emerald_blossom.enabled & player.health.pct <= 60", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "7" },
  { specId: "evoker-aug", priority: 13, spellName: "Obsidian Scales", spellIcon: "ability_evoker_obsidianscales", condition: "player.health.pct <= 40", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "evoker-aug", priority: 14, spellName: "Quell", spellIcon: "ability_evoker_quell", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Evoker Preservation ── TWW Preservation priority (triage, empowered spells, mana management, DPS weaving)
  { specId: "evoker-pres", priority: 1, spellName: "Reversion", spellIcon: "ability_evoker_reversion", condition: "cooldown.reversion.charges >= 1", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "Q" },
  { specId: "evoker-pres", priority: 2, spellName: "Dream Breath", spellIcon: "ability_evoker_dreambreath", condition: "cooldown.dream_breath.ready & !moving", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "E" },
  { specId: "evoker-pres", priority: 3, spellName: "Spiritbloom", spellIcon: "ability_evoker_spiritbloom2", condition: "cooldown.spiritbloom.ready & !moving", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "R" },
  { specId: "evoker-pres", priority: 4, spellName: "Temporal Anomaly", spellIcon: "ability_evoker_temporalanomaly", condition: "cooldown.temporal_anomaly.ready", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "1" },
  { specId: "evoker-pres", priority: 5, spellName: "Echo", spellIcon: "ability_evoker_echo", condition: "cooldown.echo.charges >= 1 & buff.essence_burst.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "2" },
  { specId: "evoker-pres", priority: 6, spellName: "Emerald Communion", spellIcon: "ability_evoker_emeraldcommunion", condition: "cooldown.emerald_communion.ready & mana <= 25 & !moving", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "G" },
  { specId: "evoker-pres", priority: 7, spellName: "Stasis", spellIcon: "ability_evoker_stasis", condition: "cooldown.stasis.ready & cooldown.dream_breath.remains < 3", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "F" },
  { specId: "evoker-pres", priority: 8, spellName: "Fire Breath", spellIcon: "ability_evoker_firebreath", condition: "cooldown.fire_breath.ready & mana >= 30 & !moving", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "evoker-pres", priority: 9, spellName: "Living Flame", spellIcon: "ability_evoker_livingflame", condition: "mana >= 35 & buff.burnout.up", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "evoker-pres", priority: 10, spellName: "Azure Strike", spellIcon: "ability_evoker_azurestrike", condition: "active_enemies >= 2 & mana >= 30", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "evoker-pres", priority: 11, spellName: "Living Flame", spellIcon: "ability_evoker_livingflame", condition: "mana >= 40 & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "evoker-pres", priority: 12, spellName: "Obsidian Scales", spellIcon: "ability_evoker_obsidianscales", condition: "cooldown.obsidian_scales.ready & player.health.pct <= 40", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "evoker-pres", priority: 13, spellName: "Quell", spellIcon: "ability_evoker_quell", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Hunter Marksmanship ── TWW SimC-quality priority
  { specId: "hunter-mm", priority: -100, spellName: "Hunter's Mark", spellIcon: "ability_hunter_snipershot", condition: "!debuff.hunters_mark.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "" },
  { specId: "hunter-mm", priority: 1, spellName: "Trueshot", spellIcon: "ability_trueshot", condition: "cooldown.trueshot.ready & fight_remains > 20 & (focus >= 50 | time < 5)", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "hunter-mm", priority: 2, spellName: "Volley", spellIcon: "ability_marksmanship", condition: "cooldown.volley.ready & talent.volley.enabled & active_enemies >= 2 & buff.trueshot.up", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "hunter-mm", priority: 3, spellName: "Kill Shot", spellIcon: "ability_hunter_assassinate", condition: "target.health.pct <= 20 | buff.deathblow.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "hunter-mm", priority: 3, spellName: "Black Arrow", spellIcon: "ability_theblackarrow", condition: "cooldown.black_arrow.ready & (target.health.pct >= 80 | target.health.pct <= 20 | buff.deathblow.up)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "hunter-mm", priority: 4, spellName: "Aimed Shot", spellIcon: "ability_hunter_aimshot", condition: "buff.precise_shots.down & (cooldown.aimed_shot.charges >= 1 | buff.trueshot.up) & focus >= 35 & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "hunter-mm", priority: 5, spellName: "Rapid Fire", spellIcon: "ability_hunter_rapidfire", condition: "cooldown.rapid_fire.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "hunter-mm", priority: 6, spellName: "Multi-Shot", spellIcon: "ability_upgrademoonglaive", condition: "active_enemies >= 3 & buff.trick_shots.down", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "hunter-mm", priority: 7, spellName: "Explosive Shot", spellIcon: "ability_hunter_explosiveshot", condition: "cooldown.explosive_shot.ready & talent.explosive_shot.enabled", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "hunter-mm", priority: 8, spellName: "Chimaera Shot", spellIcon: "ability_hunter_chimerashot2", condition: "buff.precise_shots.up & focus >= 20", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "hunter-mm", priority: 9, spellName: "Arcane Shot", spellIcon: "ability_impalingbolt", condition: "buff.precise_shots.up & focus >= 40", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "hunter-mm", priority: 10, spellName: "Aimed Shot", spellIcon: "ability_hunter_aimshot", condition: "cooldown.aimed_shot.charges_fractional >= 1.7 & focus >= 35 & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "hunter-mm", priority: 11, spellName: "Steady Shot", spellIcon: "ability_hunter_steadyshot", condition: "focus < 50 & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "hunter-mm", priority: 12, spellName: "Arcane Shot", spellIcon: "ability_impalingbolt", condition: "moving & focus >= 40", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "hunter-mm", priority: 13, spellName: "Exhilaration", spellIcon: "ability_hunter_onewithnature", condition: "player.health.pct <= 40", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "hunter-mm", priority: 14, spellName: "Counter Shot", spellIcon: "ability_hunter_glowingshot", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Hunter Survival ── TWW Survival SimC priority
  { specId: "hunter-surv", priority: 1, spellName: "Coordinated Assault", spellIcon: "ability_hunter_coordinatedassault", condition: "cooldown.coordinated_assault.ready & (fight_remains > 20 | target.health.pct <= 25)", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "hunter-surv", priority: 2, spellName: "Kill Shot", spellIcon: "ability_hunter_assassinate", condition: "target.health.pct <= 20 | buff.coordinated_assault.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "hunter-surv", priority: 3, spellName: "Wildfire Bomb", spellIcon: "inv_wildfirebomb", condition: "cooldown.wildfire_bomb.charges >= 1 & (active_enemies >= 2 | debuff.wildfire_bomb.down | cooldown.wildfire_bomb.charges >= 2)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "hunter-surv", priority: 4, spellName: "Flanking Strike", spellIcon: "ability_hunter_invigeration", condition: "cooldown.flanking_strike.ready & pet.alive & focus < 80", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "hunter-surv", priority: 5, spellName: "Kill Command", spellIcon: "ability_hunter_killcommand", condition: "pet.alive & focus >= 15 & cooldown.kill_command.charges >= 1", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "hunter-surv", priority: 6, spellName: "Fury of the Eagle", spellIcon: "ability_hunter_furyoftheeagle", condition: "cooldown.fury_of_the_eagle.ready & (active_enemies >= 2 | buff.coordinated_assault.up)", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "hunter-surv", priority: 7, spellName: "Serpent Sting", spellIcon: "ability_hunter_quickshot", condition: "(debuff.serpent_sting.down | debuff.serpent_sting.pandemic) & target.health.pct > 15", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "hunter-surv", priority: 8, spellName: "Butchery", spellIcon: "ability_butcher_cleave", condition: "cooldown.butchery.charges >= 1 & active_enemies >= 3 & talent.butchery.enabled", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "hunter-surv", priority: 9, spellName: "Raptor Strike", spellIcon: "ability_hunter_raptorstrike", condition: "focus >= 30 & (buff.coordinated_assault.up | focus >= 60 | cooldown.kill_command.remains > gcd.max)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "hunter-surv", priority: 10, spellName: "Harpoon", spellIcon: "ability_hunter_harpoon", condition: "cooldown.harpoon.ready & talent.terms_of_engagement.enabled", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "hunter-surv", priority: 11, spellName: "Raptor Strike", spellIcon: "ability_hunter_raptorstrike", condition: "focus >= 50", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "hunter-surv", priority: 12, spellName: "Wildfire Bomb", spellIcon: "inv_wildfirebomb", condition: "cooldown.wildfire_bomb.charges >= 1", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "hunter-surv", priority: 13, spellName: "Exhilaration", spellIcon: "ability_hunter_onewithnature", condition: "player.health.pct <= 40", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "hunter-surv", priority: 14, spellName: "Muzzle", spellIcon: "ability_hunter_noskill", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Mage Arcane ── TWW SimC-quality priority
  { specId: "mage-arcane", priority: 1, spellName: "Arcane Surge", spellIcon: "ability_mage_arcanesurge", condition: "cooldown.arcane_surge.ready & buff.arcane_charge.stack >= 4 & fight_remains > 15", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "mage-arcane", priority: 2, spellName: "Touch of the Magi", spellIcon: "spell_mage_touchofthemagi", condition: "cooldown.touch_of_the_magi.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "mage-arcane", priority: 3, spellName: "Evocation", spellIcon: "spell_nature_purge", condition: "cooldown.evocation.ready & mana < 15 & buff.arcane_surge.down", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "R" },
  { specId: "mage-arcane", priority: 4, spellName: "Arcane Missiles", spellIcon: "spell_nature_starfall", condition: "buff.clearcasting.up & (buff.clearcasting.stack >= 2 | buff.arcane_surge.up) & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "mage-arcane", priority: 5, spellName: "Arcane Barrage", spellIcon: "ability_mage_arcanebarrage", condition: "buff.arcane_charge.stack >= 4 & (mana < 40 | buff.arcane_surge.down)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "mage-arcane", priority: 6, spellName: "Arcane Orb", spellIcon: "spell_mage_arcaneorb", condition: "cooldown.arcane_orb.ready & talent.arcane_orb.enabled & buff.arcane_charge.stack < 3", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "mage-arcane", priority: 7, spellName: "Nether Tempest", spellIcon: "spell_mage_nethertempest", condition: "talent.nether_tempest.enabled & (debuff.nether_tempest.remains < 3.6 | !debuff.nether_tempest.up) & buff.arcane_charge.stack >= 4", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "mage-arcane", priority: 8, spellName: "Arcane Explosion", spellIcon: "spell_nature_wispsplode", condition: "active_enemies >= 3 & buff.arcane_charge.stack < 4", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "mage-arcane", priority: 9, spellName: "Arcane Blast", spellIcon: "spell_arcane_blast", condition: "mana >= 5 & buff.arcane_charge.stack < 4 & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "mage-arcane", priority: 10, spellName: "Supernova", spellIcon: "spell_mage_supernova", condition: "cooldown.supernova.ready & talent.supernova.enabled & active_enemies >= 2", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "mage-arcane", priority: 11, spellName: "Arcane Barrage", spellIcon: "ability_mage_arcanebarrage", condition: "moving & buff.arcane_charge.stack >= 3", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "mage-arcane", priority: 12, spellName: "Shifting Power", spellIcon: "ability_ardenweald_mage", condition: "cooldown.shifting_power.ready & !moving", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "7" },
  { specId: "mage-arcane", priority: 13, spellName: "Ice Barrier", spellIcon: "spell_ice_lament", condition: "player.health.pct <= 50 & buff.ice_barrier.down", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "mage-arcane", priority: 14, spellName: "Counterspell", spellIcon: "spell_frost_iceshock", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Mage Fire ── TWW SimC-quality priority
  { specId: "mage-fire", priority: 1, spellName: "Combustion", spellIcon: "spell_fire_sealoffire", condition: "cooldown.combustion.ready & fight_remains > 20 & (buff.hot_streak.up | buff.heating_up.up & cooldown.fire_blast.charges >= 1)", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "mage-fire", priority: 2, spellName: "Flamestrike", spellIcon: "spell_fire_selfdestruct", condition: "buff.hot_streak.up & active_enemies >= 3", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "mage-fire", priority: 3, spellName: "Pyroblast", spellIcon: "spell_fire_fireball02", condition: "buff.hot_streak.up & (buff.combustion.up | prev_gcd.1.fire_blast | buff.hyperthermia.up)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "mage-fire", priority: 4, spellName: "Fire Blast", spellIcon: "spell_fire_fireball", condition: "cooldown.fire_blast.charges >= 1 & buff.heating_up.up & !buff.hot_streak.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "mage-fire", priority: 5, spellName: "Phoenix Flames", spellIcon: "artifactability_firemage_phoenixbolt", condition: "cooldown.phoenix_flames.charges >= 1 & buff.heating_up.up & !buff.hot_streak.up & cooldown.fire_blast.charges < 1", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "mage-fire", priority: 6, spellName: "Meteor", spellIcon: "spell_mage_meteor", condition: "cooldown.meteor.ready & talent.meteor.enabled", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "mage-fire", priority: 7, spellName: "Scorch", spellIcon: "spell_fire_soulburn", condition: "target.health.pct <= 30 & talent.searing_touch.enabled", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "mage-fire", priority: 8, spellName: "Living Bomb", spellIcon: "ability_mage_livingbomb", condition: "cooldown.living_bomb.ready & talent.living_bomb.enabled & active_enemies >= 3", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "mage-fire", priority: 9, spellName: "Dragon's Breath", spellIcon: "inv_misc_head_dragon_01", condition: "cooldown.dragons_breath.ready & active_enemies >= 2", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "mage-fire", priority: 10, spellName: "Shifting Power", spellIcon: "ability_ardenweald_mage", condition: "cooldown.shifting_power.ready & !moving & buff.heating_up.down & buff.hot_streak.down", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "7" },
  { specId: "mage-fire", priority: 11, spellName: "Pyroblast", spellIcon: "spell_fire_fireball02", condition: "buff.hot_streak.up", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "mage-fire", priority: 12, spellName: "Fireball", spellIcon: "spell_fire_flamebolt", condition: "buff.heating_up.down & buff.hot_streak.down & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "mage-fire", priority: 13, spellName: "Scorch", spellIcon: "spell_fire_soulburn", condition: "moving", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "mage-fire", priority: 14, spellName: "Blazing Barrier", spellIcon: "ability_mage_moltenarmor", condition: "player.health.pct <= 50 & buff.blazing_barrier.down", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "mage-fire", priority: 15, spellName: "Counterspell", spellIcon: "spell_frost_iceshock", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Monk Windwalker ── TWW Windwalker SimC priority
  { specId: "monk-ww", priority: 1, spellName: "Storm, Earth, and Fire", spellIcon: "spell_nature_giftofthewild", condition: "cooldown.storm_earth_and_fire.charges >= 1 & !buff.storm_earth_and_fire.up & (fight_remains > 15 | target.health.pct <= 25)", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "monk-ww", priority: 2, spellName: "Strike of the Windlord", spellIcon: "ability_monk_strikeowindlord", condition: "cooldown.strike_of_the_windlord.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "monk-ww", priority: 3, spellName: "Whirling Dragon Punch", spellIcon: "ability_monk_hurricanestrike", condition: "cooldown.whirling_dragon_punch.ready & talent.whirling_dragon_punch.enabled", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "monk-ww", priority: 4, spellName: "Fists of Fury", spellIcon: "monk_ability_fistoffury", condition: "cooldown.fists_of_fury.ready & energy >= 25 & !prev_gcd.1.fists_of_fury", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "monk-ww", priority: 5, spellName: "Rising Sun Kick", spellIcon: "ability_monk_risingsunkick", condition: "cooldown.rising_sun_kick.ready & chi >= 2 & !prev_gcd.1.rising_sun_kick", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "monk-ww", priority: 6, spellName: "Spinning Crane Kick", spellIcon: "ability_monk_cranekick_new", condition: "chi >= 2 & active_enemies >= 3 & buff.dance_of_chi_ji.up", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "monk-ww", priority: 7, spellName: "Blackout Kick", spellIcon: "ability_monk_roundhousekick", condition: "chi >= 1 & (buff.teachings_of_the_monastery.stack >= 3 | !prev_gcd.1.blackout_kick) & cooldown.fists_of_fury.remains > 1 & cooldown.rising_sun_kick.remains > 1", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "monk-ww", priority: 8, spellName: "Spinning Crane Kick", spellIcon: "ability_monk_cranekick_new", condition: "chi >= 2 & active_enemies >= 3 & !prev_gcd.1.spinning_crane_kick", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "monk-ww", priority: 9, spellName: "Tiger Palm", spellIcon: "ability_monk_tigerpalm", condition: "energy >= 50 & chi < 4 & !prev_gcd.1.tiger_palm", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "monk-ww", priority: 10, spellName: "Expel Harm", spellIcon: "ability_monk_expelharm", condition: "chi < 3 & energy >= 15 & (player.health.pct < 85 | chi <= 1)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "monk-ww", priority: 11, spellName: "Chi Wave", spellIcon: "ability_monk_chiwave", condition: "cooldown.chi_wave.ready & talent.chi_wave.enabled", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "monk-ww", priority: 12, spellName: "Blackout Kick", spellIcon: "ability_monk_roundhousekick", condition: "chi >= 1 & !prev_gcd.1.blackout_kick", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "monk-ww", priority: 13, spellName: "Touch of Karma", spellIcon: "ability_monk_touchofkarma", condition: "player.health.pct <= 40", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "monk-ww", priority: 14, spellName: "Spear Hand Strike", spellIcon: "ability_monk_spearhand", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Monk Mistweaver ── TWW Mistweaver priority (triage, TFT usage, mana conservation, fistweaving DPS)
  { specId: "monk-mw", priority: 1, spellName: "Life Cocoon", spellIcon: "ability_monk_chicocoon", condition: "cooldown.life_cocoon.ready & player.health.pct <= 25", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "monk-mw", priority: 2, spellName: "Thunder Focus Tea", spellIcon: "ability_monk_thunderfocustea", condition: "cooldown.thunder_focus_tea.ready", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "Q" },
  { specId: "monk-mw", priority: 3, spellName: "Renewing Mist", spellIcon: "ability_monk_renewingmists", condition: "cooldown.renewing_mist.charges >= 1", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "E" },
  { specId: "monk-mw", priority: 4, spellName: "Enveloping Mist", spellIcon: "spell_monk_envelopingmist", condition: "mana >= 6 & buff.thunder_focus_tea.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "2" },
  { specId: "monk-mw", priority: 5, spellName: "Essence Font", spellIcon: "ability_monk_essencefont", condition: "cooldown.essence_font.ready & mana >= 7 & !moving", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "R" },
  { specId: "monk-mw", priority: 6, spellName: "Vivify", spellIcon: "ability_monk_vivify", condition: "mana >= 4 & buff.vivacious_vivification.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "1" },
  { specId: "monk-mw", priority: 7, spellName: "Rising Sun Kick", spellIcon: "ability_monk_risingsunkick", condition: "cooldown.rising_sun_kick.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "monk-mw", priority: 8, spellName: "Blackout Kick", spellIcon: "ability_monk_roundhousekick", condition: "buff.teachings_of_the_monastery.stack >= 3", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "monk-mw", priority: 9, spellName: "Tiger Palm", spellIcon: "ability_monk_tigerpalm", condition: "energy >= 25 & mana >= 25", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "monk-mw", priority: 10, spellName: "Sheiluns Gift", spellIcon: "inv_staff_2h_artifactshaohao_d_01", condition: "cooldown.sheiluns_gift.ready & buff.sheiluns_gift.stack >= 6", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "G" },
  { specId: "monk-mw", priority: 11, spellName: "Vivify", spellIcon: "ability_monk_vivify", condition: "mana >= 4", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "1" },
  { specId: "monk-mw", priority: 12, spellName: "Fortifying Brew", spellIcon: "ability_monk_fortifyingelixir", condition: "cooldown.fortifying_brew.ready & player.health.pct <= 30", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "Z" },
  { specId: "monk-mw", priority: 13, spellName: "Spear Hand Strike", spellIcon: "ability_monk_spearhand", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Monk Brewmaster ── TWW Brewmaster priority (stagger management, shuffle uptime, brew efficiency)
  { specId: "monk-brew", priority: 1, spellName: "Purifying Brew", spellIcon: "inv_misc_beer_06", condition: "cooldown.purifying_brew.charges >= 1 & buff.heavy_stagger.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "R" },
  { specId: "monk-brew", priority: 2, spellName: "Celestial Brew", spellIcon: "ability_monk_ironskinbrew", condition: "cooldown.celestial_brew.ready & player.health.pct <= 60 & buff.purified_chi.stack >= 3", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "G" },
  { specId: "monk-brew", priority: 3, spellName: "Keg Smash", spellIcon: "achievement_brewery_2", condition: "cooldown.keg_smash.ready & energy >= 40", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "monk-brew", priority: 4, spellName: "Blackout Kick", spellIcon: "ability_monk_roundhousekick", condition: "cooldown.blackout_kick.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "monk-brew", priority: 5, spellName: "Breath of Fire", spellIcon: "ability_monk_breathoffire", condition: "cooldown.breath_of_fire.ready & debuff.keg_smash.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "monk-brew", priority: 6, spellName: "Weapons of Order", spellIcon: "ability_bastion_monk", condition: "cooldown.weapons_of_order.ready & (active_enemies >= 3 | player.health.pct <= 50)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "Q" },
  { specId: "monk-brew", priority: 7, spellName: "Exploding Keg", spellIcon: "inv_cask_01", condition: "cooldown.exploding_keg.ready & active_enemies >= 2", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "monk-brew", priority: 8, spellName: "Rising Sun Kick", spellIcon: "ability_monk_risingsunkick", condition: "cooldown.rising_sun_kick.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "monk-brew", priority: 9, spellName: "Spinning Crane Kick", spellIcon: "ability_monk_cranekick_new", condition: "energy >= 25 & active_enemies >= 3", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "monk-brew", priority: 10, spellName: "Tiger Palm", spellIcon: "ability_monk_tigerpalm", condition: "energy >= 25 & buff.blackout_combo.up", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "6" },
  { specId: "monk-brew", priority: 11, spellName: "Purifying Brew", spellIcon: "inv_misc_beer_06", condition: "cooldown.purifying_brew.charges >= 1 & buff.moderate_stagger.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "R" },
  { specId: "monk-brew", priority: 12, spellName: "Fortifying Brew", spellIcon: "ability_monk_fortifyingelixir", condition: "cooldown.fortifying_brew.ready & player.health.pct <= 30", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "monk-brew", priority: 13, spellName: "Spear Hand Strike", spellIcon: "ability_monk_spearhand", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Paladin Retribution ── TWW Retribution SimC priority
  { specId: "paladin-ret", priority: 1, spellName: "Avenging Wrath", spellIcon: "spell_holy_avenginewrath", condition: "cooldown.avenging_wrath.ready & holy_power >= 3 & (fight_remains > 20 | target.health.pct <= 25)", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "paladin-ret", priority: 2, spellName: "Execution Sentence", spellIcon: "ability_paladin_executionsentence", condition: "cooldown.execution_sentence.ready & holy_power >= 3 & talent.execution_sentence.enabled", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "paladin-ret", priority: 3, spellName: "Wake of Ashes", spellIcon: "inv_sword_2h_artifactashbringerfire_d_03", condition: "cooldown.wake_of_ashes.ready & holy_power <= 2", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "paladin-ret", priority: 4, spellName: "Divine Storm", spellIcon: "ability_paladin_divinestorm", condition: "holy_power >= 3 & active_enemies >= 2 & buff.avenging_wrath.up", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "paladin-ret", priority: 5, spellName: "Final Verdict", spellIcon: "spell_paladin_templarsverdict", condition: "holy_power >= 5 | (holy_power >= 3 & buff.avenging_wrath.up)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "paladin-ret", priority: 5, spellName: "Templar's Verdict", spellIcon: "spell_paladin_templarsverdict", condition: "holy_power >= 5 | (holy_power >= 3 & buff.avenging_wrath.up)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "paladin-ret", priority: 6, spellName: "Hammer of Wrath", spellIcon: "spell_paladin_hammerofwrath", condition: "(target.health.pct <= 20 | buff.avenging_wrath.up) & holy_power < 5", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "paladin-ret", priority: 7, spellName: "Blade of Justice", spellIcon: "ability_paladin_bladeofjustice", condition: "cooldown.blade_of_justice.ready & holy_power <= 3", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "paladin-ret", priority: 8, spellName: "Judgment", spellIcon: "spell_holy_righteousfury", condition: "cooldown.judgment.ready & holy_power < 5 & (debuff.judgment.down | debuff.judgment.remains < 3)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "paladin-ret", priority: 9, spellName: "Divine Storm", spellIcon: "ability_paladin_divinestorm", condition: "holy_power >= 3 & active_enemies >= 3", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "paladin-ret", priority: 10, spellName: "Final Verdict", spellIcon: "spell_paladin_templarsverdict", condition: "holy_power >= 3", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "paladin-ret", priority: 10, spellName: "Templar's Verdict", spellIcon: "spell_paladin_templarsverdict", condition: "holy_power >= 3", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "paladin-ret", priority: 11, spellName: "Crusader Strike", spellIcon: "spell_holy_crusaderstrike", condition: "cooldown.crusader_strike.charges >= 1 & holy_power <= 3", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "paladin-ret", priority: 11, spellName: "Templar Strike", spellIcon: "ability_paladin_youredeliverance", condition: "cooldown.templar_strike.ready & holy_power <= 3", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "paladin-ret", priority: 12, spellName: "Consecration", spellIcon: "spell_holy_innerfire", condition: "cooldown.consecration.ready & active_enemies >= 2 & !moving", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "paladin-ret", priority: 13, spellName: "Shield of Vengeance", spellIcon: "ability_paladin_shieldofvengeance", condition: "player.health.pct <= 40", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "paladin-ret", priority: 14, spellName: "Rebuke", spellIcon: "spell_holy_rebuke", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Paladin Protection ── TWW Prot Paladin priority (SotR uptime, holy power gen, mitigation layering)
  { specId: "paladin-prot", priority: 1, spellName: "Shield of the Righteous", spellIcon: "ability_paladin_shieldofthepaladin", condition: "holy_power >= 3 & (buff.shield_of_the_righteous.down | buff.shield_of_the_righteous.remains < 2)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "paladin-prot", priority: 2, spellName: "Word of Glory", spellIcon: "inv_helmet_96", condition: "holy_power >= 3 & player.health.pct <= 45", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "E" },
  { specId: "paladin-prot", priority: 3, spellName: "Avengers Shield", spellIcon: "spell_holy_avengersshield", condition: "cooldown.avengers_shield.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "paladin-prot", priority: 4, spellName: "Judgment", spellIcon: "spell_holy_righteousfury", condition: "cooldown.judgment.ready & holy_power < 5", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "paladin-prot", priority: 5, spellName: "Hammer of Wrath", spellIcon: "spell_paladin_hammerofwrath", condition: "(target.health.pct <= 20 | buff.avenging_wrath.up) & holy_power < 5", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "paladin-prot", priority: 6, spellName: "Avenging Wrath", spellIcon: "spell_holy_avenginewrath", condition: "cooldown.avenging_wrath.ready & (active_enemies >= 3 | player.health.pct <= 50)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "Q" },
  { specId: "paladin-prot", priority: 7, spellName: "Bastion of Light", spellIcon: "inv_helmet_98", condition: "cooldown.bastion_of_light.ready & holy_power <= 1", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "paladin-prot", priority: 8, spellName: "Hammer of the Righteous", spellIcon: "ability_paladin_hammeroftherighteous", condition: "cooldown.hammer_of_the_righteous.charges >= 1 & holy_power < 5", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "paladin-prot", priority: 9, spellName: "Consecration", spellIcon: "spell_holy_innerfire", condition: "cooldown.consecration.ready & buff.consecration.down", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "paladin-prot", priority: 10, spellName: "Shield of the Righteous", spellIcon: "ability_paladin_shieldofthepaladin", condition: "holy_power >= 5", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "paladin-prot", priority: 11, spellName: "Guardian of Ancient Kings", spellIcon: "spell_holy_heroism", condition: "cooldown.guardian_of_ancient_kings.ready & player.health.pct <= 30", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "paladin-prot", priority: 12, spellName: "Ardent Defender", spellIcon: "spell_holy_ardentdefender", condition: "cooldown.ardent_defender.ready & player.health.pct <= 20", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "Z" },
  { specId: "paladin-prot", priority: 13, spellName: "Rebuke", spellIcon: "spell_holy_rebuke", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Paladin Holy ── TWW Holy Paladin priority (holy shock CD, holy power spending, Infusion of Light usage, DPS weaving)
  { specId: "paladin-holy", priority: 1, spellName: "Avenging Wrath", spellIcon: "spell_holy_avenginewrath", condition: "cooldown.avenging_wrath.ready", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "Q" },
  { specId: "paladin-holy", priority: 2, spellName: "Holy Shock", spellIcon: "spell_holy_searinglight", condition: "cooldown.holy_shock.ready", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "1" },
  { specId: "paladin-holy", priority: 3, spellName: "Word of Glory", spellIcon: "inv_helmet_96", condition: "holy_power >= 3 & player.health.pct <= 50", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "3" },
  { specId: "paladin-holy", priority: 4, spellName: "Light of Dawn", spellIcon: "spell_paladin_lightofdawn", condition: "holy_power >= 3", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "2" },
  { specId: "paladin-holy", priority: 5, spellName: "Daybreak", spellIcon: "spell_paladin_daybreak", condition: "cooldown.daybreak.ready", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "E" },
  { specId: "paladin-holy", priority: 6, spellName: "Beacon of Virtue", spellIcon: "ability_paladin_beaconofinsight", condition: "cooldown.beacon_of_virtue.ready", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "R" },
  { specId: "paladin-holy", priority: 7, spellName: "Holy Light", spellIcon: "spell_holy_holybolt", condition: "mana >= 10 & buff.infusion_of_light.up & !moving", mode: "ST", isInterrupt: false, isOffensive: false, enabled: true, keybind: "6" },
  { specId: "paladin-holy", priority: 8, spellName: "Judgment", spellIcon: "spell_holy_righteousfury", condition: "cooldown.judgment.ready & holy_power < 5", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "paladin-holy", priority: 9, spellName: "Hammer of Wrath", spellIcon: "spell_paladin_hammerofwrath", condition: "(target.health.pct <= 20 | buff.avenging_wrath.up) & holy_power < 5", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "paladin-holy", priority: 10, spellName: "Crusader Strike", spellIcon: "spell_holy_crusaderstrike", condition: "cooldown.crusader_strike.charges >= 1 & holy_power < 5 & mana >= 20", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "paladin-holy", priority: 11, spellName: "Divine Shield", spellIcon: "spell_holy_divineintervention", condition: "cooldown.divine_shield.ready & player.health.pct <= 15", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "paladin-holy", priority: 12, spellName: "Aura Mastery", spellIcon: "spell_holy_auramastery", condition: "cooldown.aura_mastery.ready & player.health.pct <= 30", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "Z" },
  { specId: "paladin-holy", priority: 13, spellName: "Rebuke", spellIcon: "spell_holy_rebuke", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Priest Shadow ── TWW SimC-quality priority
  { specId: "priest-shadow", priority: 1, spellName: "Void Eruption", spellIcon: "spell_priest_voidform", condition: "cooldown.void_eruption.ready & talent.void_eruption.enabled & insanity >= 25 & debuff.vampiric_touch.up & debuff.shadow_word_pain.up & fight_remains > 15", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "priest-shadow", priority: 2, spellName: "Dark Ascension", spellIcon: "spell_priest_darkascension", condition: "cooldown.dark_ascension.ready & talent.dark_ascension.enabled & debuff.vampiric_touch.up & debuff.shadow_word_pain.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "priest-shadow", priority: 3, spellName: "Shadowfiend", spellIcon: "spell_shadow_shadowfiend", condition: "cooldown.shadowfiend.ready & (buff.voidform.up | buff.dark_ascension.up | fight_remains < 30)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "priest-shadow", priority: 4, spellName: "Shadow Word: Death", spellIcon: "spell_shadow_demonicfortitude", condition: "target.health.pct <= 20 | (buff.deathspeaker.up & talent.deathspeaker.enabled)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "priest-shadow", priority: 5, spellName: "Devouring Plague", spellIcon: "spell_shadow_devouringplague", condition: "insanity >= 50 & (debuff.devouring_plague.remains < 3 | insanity >= 90)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "priest-shadow", priority: 6, spellName: "Shadow Word: Pain", spellIcon: "spell_shadow_shadowwordpain", condition: "debuff.shadow_word_pain.remains < 4.8 | !debuff.shadow_word_pain.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "priest-shadow", priority: 7, spellName: "Vampiric Touch", spellIcon: "spell_holy_stoicism", condition: "(debuff.vampiric_touch.remains < 6 | !debuff.vampiric_touch.up) & !moving", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "priest-shadow", priority: 8, spellName: "Mind Blast", spellIcon: "spell_shadow_unholyfrenzy", condition: "cooldown.mind_blast.charges >= 1 & (buff.voidform.up | buff.dark_ascension.up | insanity < 70)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "priest-shadow", priority: 9, spellName: "Void Bolt", spellIcon: "ability_ironmaidens_yourmageis", condition: "buff.voidform.up & cooldown.void_bolt.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "6" },
  { specId: "priest-shadow", priority: 10, spellName: "Mind Flay: Insanity", spellIcon: "spell_shadow_siphonmana", condition: "buff.mind_flay_insanity.up & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "priest-shadow", priority: 11, spellName: "Shadow Crash", spellIcon: "spell_shadow_shadowfury", condition: "cooldown.shadow_crash.ready & talent.shadow_crash.enabled & active_enemies >= 2", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "priest-shadow", priority: 12, spellName: "Mind Flay", spellIcon: "spell_shadow_siphonmana", condition: "!buff.mind_flay_insanity.up & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "priest-shadow", priority: 13, spellName: "Shadow Word: Pain", spellIcon: "spell_shadow_shadowwordpain", condition: "moving & !debuff.shadow_word_pain.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "priest-shadow", priority: 14, spellName: "Dispersion", spellIcon: "spell_shadow_dispersion", condition: "player.health.pct <= 30", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "priest-shadow", priority: 15, spellName: "Silence", spellIcon: "ability_priest_silence", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Priest Discipline ── TWW Discipline priority (atonement ramp, damage for healing, cooldown usage, mana efficiency)
  { specId: "priest-disc", priority: 1, spellName: "Pain Suppression", spellIcon: "spell_holy_painsupression", condition: "cooldown.pain_suppression.ready & player.health.pct <= 20", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "priest-disc", priority: 2, spellName: "Evangelism", spellIcon: "spell_holy_divineillumination", condition: "cooldown.evangelism.ready", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "Q" },
  { specId: "priest-disc", priority: 3, spellName: "Radiance", spellIcon: "spell_priest_power_word_radiance", condition: "cooldown.radiance.charges >= 1 & mana >= 5", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "E" },
  { specId: "priest-disc", priority: 4, spellName: "Power Word: Shield", spellIcon: "spell_holy_powerwordshield", condition: "mana >= 3 & buff.weakened_soul.down", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "1" },
  { specId: "priest-disc", priority: 5, spellName: "Schism", spellIcon: "spell_warlock_focusshadow", condition: "cooldown.schism.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "priest-disc", priority: 6, spellName: "Mind Blast", spellIcon: "spell_shadow_unholyfrenzy", condition: "cooldown.mind_blast.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "priest-disc", priority: 7, spellName: "Penance", spellIcon: "spell_holy_penance", condition: "cooldown.penance.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "priest-disc", priority: 8, spellName: "Purge the Wicked", spellIcon: "ability_priest_purgeofthewicked", condition: "debuff.purge_the_wicked.pandemic | debuff.purge_the_wicked.down", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "priest-disc", priority: 9, spellName: "Shadow Word: Death", spellIcon: "spell_shadow_demonicfortitude", condition: "target.health.pct <= 20", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "priest-disc", priority: 10, spellName: "Smite", spellIcon: "spell_holy_holysmite", condition: "mana >= 15 & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "priest-disc", priority: 11, spellName: "Power Word: Barrier", spellIcon: "spell_holy_powerwordbarrier", condition: "cooldown.power_word_barrier.ready & player.health.pct <= 35", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "Z" },
  { specId: "priest-disc", priority: 12, spellName: "Rapture", spellIcon: "spell_holy_rapture", condition: "cooldown.rapture.ready & mana >= 10", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "G" },
  { specId: "priest-disc", priority: 13, spellName: "Silence", spellIcon: "ability_priest_silence", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Priest Holy ── Midnight community rotation
  { specId: "priest-holy", priority: 1, spellName: "Divine Hymn", spellIcon: "spell_holy_divinehymn", condition: "cooldown.divine_hymn.ready", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "priest-holy", priority: 2, spellName: "Apotheosis", spellIcon: "ability_priest_youreternityfalls", condition: "cooldown.apotheosis.ready", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "E" },
  { specId: "priest-holy", priority: 3, spellName: "Holy Word: Sanctify", spellIcon: "spell_holy_divineprovidence", condition: "cooldown.holy_word_sanctify.ready", mode: "Both", isInterrupt: false, isOffensive: false, isCooldown: true, enabled: true, keybind: "1" },
  { specId: "priest-holy", priority: 4, spellName: "Holy Word: Serenity", spellIcon: "spell_holy_persuitofjustice", condition: "cooldown.holy_word_serenity.ready", mode: "Both", isInterrupt: false, isOffensive: false, isCooldown: true, enabled: true, keybind: "2" },
  { specId: "priest-holy", priority: 5, spellName: "Prayer of Mending", spellIcon: "spell_holy_prayerofmendingtga", condition: "cooldown.prayer_of_mending.ready", mode: "Both", isInterrupt: false, isOffensive: false, isCooldown: true, enabled: true, keybind: "3" },
  { specId: "priest-holy", priority: 6, spellName: "Circle of Healing", spellIcon: "spell_holy_circleofrenewal", condition: "cooldown.circle_of_healing.ready", mode: "Both", isInterrupt: false, isOffensive: false, isCooldown: true, enabled: true, keybind: "4" },
  { specId: "priest-holy", priority: 7, spellName: "Renew", spellIcon: "spell_holy_renew", condition: "", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "5" },
  { specId: "priest-holy", priority: 8, spellName: "Flash Heal", spellIcon: "spell_holy_flashheal", condition: "", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "R" },
  { specId: "priest-holy", priority: 9, spellName: "Holy Fire", spellIcon: "spell_holy_searinglight", condition: "", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "priest-holy", priority: 10, spellName: "Smite", spellIcon: "spell_holy_holysmite", condition: "", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "priest-holy", priority: 13, spellName: "Silence", spellIcon: "ability_priest_silence", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Rogue Assassination ── TWW Assassination SimC priority
  { specId: "rogue-ass", priority: 1, spellName: "Deathmark", spellIcon: "ability_rogue_deathmark", condition: "cooldown.deathmark.ready & combo_points <= 2 & debuff.rupture.up & debuff.garrote.up & (fight_remains > 20 | target.health.pct <= 20)", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "rogue-ass", priority: 2, spellName: "Kingsbane", spellIcon: "ability_rogue_kingsbane", condition: "cooldown.kingsbane.ready & debuff.rupture.up & talent.kingsbane.enabled", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "rogue-ass", priority: 3, spellName: "Shiv", spellIcon: "inv_throwingknife_04", condition: "cooldown.shiv.ready & debuff.rupture.up", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "rogue-ass", priority: 4, spellName: "Garrote", spellIcon: "ability_rogue_garrote", condition: "(debuff.garrote.down | debuff.garrote.pandemic) & combo_points < 5", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "rogue-ass", priority: 5, spellName: "Rupture", spellIcon: "ability_rogue_rupture", condition: "combo_points >= 5 & (debuff.rupture.down | debuff.rupture.pandemic) & target.health.pct > 15", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "rogue-ass", priority: 6, spellName: "Crimson Tempest", spellIcon: "ability_rogue_crimsonvial", condition: "combo_points >= 5 & active_enemies >= 3 & (debuff.crimson_tempest.down | debuff.crimson_tempest.pandemic)", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "6" },
  { specId: "rogue-ass", priority: 7, spellName: "Envenom", spellIcon: "ability_rogue_disembowel", condition: "combo_points >= 5 & debuff.rupture.up & (energy >= 50 | buff.deathmark.up)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "rogue-ass", priority: 8, spellName: "Fan of Knives", spellIcon: "ability_rogue_fanofknives", condition: "energy >= 35 & active_enemies >= 3 & combo_points < 5", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "rogue-ass", priority: 9, spellName: "Mutilate", spellIcon: "ability_rogue_shadowstrikes", condition: "energy >= 50 & combo_points < 5", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "rogue-ass", priority: 10, spellName: "Thistle Tea", spellIcon: "inv_drink_milk_05", condition: "cooldown.thistle_tea.charges >= 1 & energy < 40 & (buff.deathmark.up | cooldown.deathmark.remains < 3)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "rogue-ass", priority: 11, spellName: "Envenom", spellIcon: "ability_rogue_disembowel", condition: "combo_points >= 4 & debuff.rupture.up", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "rogue-ass", priority: 12, spellName: "Mutilate", spellIcon: "ability_rogue_shadowstrikes", condition: "energy >= 50 & combo_points < 5", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "rogue-ass", priority: 13, spellName: "Evasion", spellIcon: "spell_shadow_shadowward", condition: "player.health.pct <= 35", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "rogue-ass", priority: 14, spellName: "Kick", spellIcon: "ability_kick", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Rogue Outlaw ── TWW Outlaw SimC priority
  { specId: "rogue-out", priority: 1, spellName: "Adrenaline Rush", spellIcon: "spell_shadow_shadowworddominate", condition: "cooldown.adrenaline_rush.ready & !buff.adrenaline_rush.up & (fight_remains > 15 | target.health.pct <= 25)", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "rogue-out", priority: 2, spellName: "Roll the Bones", spellIcon: "ability_rogue_rollthebones", condition: "combo_points >= 5 & (buff.roll_the_bones.down | buff.roll_the_bones.remains < 3)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "rogue-out", priority: 3, spellName: "Blade Flurry", spellIcon: "ability_warrior_punishingblow", condition: "active_enemies >= 2 & buff.blade_flurry.down", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "rogue-out", priority: 4, spellName: "Killing Spree", spellIcon: "ability_rogue_murderspree", condition: "cooldown.killing_spree.ready & talent.killing_spree.enabled", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "rogue-out", priority: 5, spellName: "Between the Eyes", spellIcon: "inv_weapon_rifle_01", condition: "combo_points >= 5 & (buff.between_the_eyes.down | buff.between_the_eyes.remains < 4)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "rogue-out", priority: 6, spellName: "Dispatch", spellIcon: "ability_rogue_waylay", condition: "combo_points >= 5 & buff.roll_the_bones.up", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "rogue-out", priority: 7, spellName: "Ghostly Strike", spellIcon: "ability_rogue_ghostlystrike", condition: "cooldown.ghostly_strike.ready & combo_points < 5 & talent.ghostly_strike.enabled", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "rogue-out", priority: 8, spellName: "Pistol Shot", spellIcon: "inv_weapon_rifle_01", condition: "buff.opportunity.up & (combo_points < 5 | energy < 45)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "rogue-out", priority: 9, spellName: "Blade Rush", spellIcon: "ability_arakkoa_spinningblade", condition: "cooldown.blade_rush.ready & energy < 50 & !buff.adrenaline_rush.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "rogue-out", priority: 10, spellName: "Sinister Strike", spellIcon: "spell_shadow_ritualofsacrifice", condition: "energy >= 45 & combo_points < 5", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "rogue-out", priority: 11, spellName: "Dispatch", spellIcon: "ability_rogue_waylay", condition: "combo_points >= 5", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "rogue-out", priority: 12, spellName: "Sinister Strike", spellIcon: "spell_shadow_ritualofsacrifice", condition: "energy >= 50 & combo_points < 5", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "rogue-out", priority: 13, spellName: "Evasion", spellIcon: "spell_shadow_shadowward", condition: "player.health.pct <= 35", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "rogue-out", priority: 14, spellName: "Kick", spellIcon: "ability_kick", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Rogue Subtlety ── TWW Subtlety SimC priority
  { specId: "rogue-sub", priority: 1, spellName: "Symbols of Death", spellIcon: "spell_shadow_rune", condition: "cooldown.symbols_of_death.ready & (buff.shadow_dance.up | cooldown.shadow_dance.remains < 2)", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "E" },
  { specId: "rogue-sub", priority: 2, spellName: "Shadow Dance", spellIcon: "ability_rogue_shadowdance", condition: "cooldown.shadow_dance.charges >= 1 & !buff.shadow_dance.up & (fight_remains > 8 | target.health.pct <= 20)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "Q" },
  { specId: "rogue-sub", priority: 3, spellName: "Secret Technique", spellIcon: "ability_rogue_sinistercalling", condition: "cooldown.secret_technique.ready & combo_points >= 5 & buff.shadow_dance.up & talent.secret_technique.enabled", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "rogue-sub", priority: 4, spellName: "Rupture", spellIcon: "ability_rogue_rupture", condition: "combo_points >= 5 & (debuff.rupture.down | debuff.rupture.pandemic) & target.health.pct > 20", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "rogue-sub", priority: 5, spellName: "Black Powder", spellIcon: "ability_rogue_shroudofconcealment", condition: "combo_points >= 5 & active_enemies >= 3", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "rogue-sub", priority: 6, spellName: "Eviscerate", spellIcon: "ability_rogue_eviscerate", condition: "combo_points >= 5 & debuff.rupture.up & (buff.shadow_dance.up | buff.symbols_of_death.up | target.health.pct <= 20)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "rogue-sub", priority: 7, spellName: "Shuriken Tornado", spellIcon: "ability_rogue_shadowdance", condition: "cooldown.shuriken_tornado.ready & buff.shadow_dance.up & active_enemies >= 2 & talent.shuriken_tornado.enabled", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "rogue-sub", priority: 8, spellName: "Shadowstrike", spellIcon: "ability_rogue_shadowstrike", condition: "stealthed.all & combo_points < 5", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "rogue-sub", priority: 9, spellName: "Shuriken Storm", spellIcon: "ability_rogue_shurikenstorm", condition: "energy >= 35 & active_enemies >= 3 & combo_points < 5 & stealthed.all", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "6" },
  { specId: "rogue-sub", priority: 10, spellName: "Eviscerate", spellIcon: "ability_rogue_eviscerate", condition: "combo_points >= 5 & debuff.rupture.up", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "rogue-sub", priority: 11, spellName: "Backstab", spellIcon: "ability_backstab", condition: "energy >= 35 & combo_points < 5 & !stealthed.all", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "rogue-sub", priority: 12, spellName: "Shuriken Storm", spellIcon: "ability_rogue_shurikenstorm", condition: "energy >= 35 & active_enemies >= 3 & combo_points < 5", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "6" },
  { specId: "rogue-sub", priority: 13, spellName: "Evasion", spellIcon: "spell_shadow_shadowward", condition: "player.health.pct <= 35", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "rogue-sub", priority: 14, spellName: "Kick", spellIcon: "ability_kick", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Shaman Enhancement ── TWW Enhancement SimC priority
  { specId: "shaman-enh", priority: 1, spellName: "Feral Spirit", spellIcon: "spell_shaman_feralspirit", condition: "cooldown.feral_spirit.ready & (fight_remains > 15 | target.health.pct <= 25)", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "shaman-enh", priority: 2, spellName: "Doom Winds", spellIcon: "ability_ironmaidens_swirlingvortex", condition: "cooldown.doom_winds.ready & talent.doom_winds.enabled", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "shaman-enh", priority: 3, spellName: "Sundering", spellIcon: "ability_rhyolith_lavapool", condition: "cooldown.sundering.ready & (buff.doom_winds.up | active_enemies >= 3) & talent.sundering.enabled", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "shaman-enh", priority: 4, spellName: "Flame Shock", spellIcon: "spell_fire_flameshock", condition: "debuff.flame_shock.down | (debuff.flame_shock.pandemic & active_enemies <= 3)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "shaman-enh", priority: 5, spellName: "Stormstrike", spellIcon: "ability_shaman_stormstrike", condition: "cooldown.stormstrike.ready & (buff.stormbringer.up | buff.doom_winds.up)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "shaman-enh", priority: 5, spellName: "Windstrike", spellIcon: "ability_skyreach_four_wind", condition: "cooldown.windstrike.ready & (buff.stormbringer.up | buff.doom_winds.up)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "shaman-enh", priority: 6, spellName: "Lava Lash", spellIcon: "ability_shaman_lavalash", condition: "buff.hot_hand.up", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "shaman-enh", priority: 7, spellName: "Chain Lightning", spellIcon: "spell_nature_chainlightning", condition: "buff.maelstrom_weapon.stack >= 5 & active_enemies >= 3", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "shaman-enh", priority: 8, spellName: "Lightning Bolt", spellIcon: "spell_nature_lightning", condition: "buff.maelstrom_weapon.stack >= 5 & (buff.primordial_wave.up | buff.maelstrom_weapon.stack >= 8)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "6" },
  { specId: "shaman-enh", priority: 9, spellName: "Ice Strike", spellIcon: "spell_frost_frostbolt", condition: "cooldown.ice_strike.ready & talent.ice_strike.enabled", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "shaman-enh", priority: 10, spellName: "Crash Lightning", spellIcon: "spell_shaman_crashlightning", condition: "cooldown.crash_lightning.ready & (active_enemies >= 2 | buff.crash_lightning.down)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "shaman-enh", priority: 11, spellName: "Stormstrike", spellIcon: "ability_shaman_stormstrike", condition: "cooldown.stormstrike.ready", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "shaman-enh", priority: 11, spellName: "Windstrike", spellIcon: "ability_skyreach_four_wind", condition: "cooldown.windstrike.ready", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "shaman-enh", priority: 12, spellName: "Lava Lash", spellIcon: "ability_shaman_lavalash", condition: "cooldown.lava_lash.ready", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "shaman-enh", priority: 13, spellName: "Astral Shift", spellIcon: "ability_shaman_astralshift", condition: "player.health.pct <= 40", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "shaman-enh", priority: 14, spellName: "Wind Shear", spellIcon: "spell_nature_cyclone", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Shaman Restoration ── TWW Resto Shaman priority (triage, tidal waves usage, totem management, DPS weaving)
  { specId: "shaman-resto", priority: 1, spellName: "Spirit Link Totem", spellIcon: "spell_shaman_spiritlink", condition: "cooldown.spirit_link_totem.ready & player.health.pct <= 30", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "Q" },
  { specId: "shaman-resto", priority: 2, spellName: "Healing Tide Totem", spellIcon: "ability_shaman_healingtide", condition: "cooldown.healing_tide_totem.ready & player.health.pct <= 40", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "E" },
  { specId: "shaman-resto", priority: 3, spellName: "Riptide", spellIcon: "spell_nature_riptide", condition: "cooldown.riptide.charges >= 1", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "1" },
  { specId: "shaman-resto", priority: 4, spellName: "Healing Rain", spellIcon: "spell_nature_giftofthewaterspirit", condition: "cooldown.healing_rain.ready & mana >= 8", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "4" },
  { specId: "shaman-resto", priority: 5, spellName: "Healing Wave", spellIcon: "spell_nature_magicimmunity", condition: "mana >= 5 & buff.tidal_waves.up & !moving", mode: "ST", isInterrupt: false, isOffensive: false, enabled: true, keybind: "2" },
  { specId: "shaman-resto", priority: 6, spellName: "Chain Heal", spellIcon: "spell_nature_healingwavegreater", condition: "mana >= 8 & !moving", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "3" },
  { specId: "shaman-resto", priority: 7, spellName: "Cloudburst Totem", spellIcon: "ability_shaman_condensationtotem", condition: "cooldown.cloudburst_totem.ready", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "G" },
  { specId: "shaman-resto", priority: 8, spellName: "Flame Shock", spellIcon: "spell_fire_flameshock", condition: "debuff.flame_shock.pandemic | debuff.flame_shock.down", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "shaman-resto", priority: 9, spellName: "Lava Burst", spellIcon: "spell_shaman_lavaburst", condition: "(buff.lava_surge.up | cooldown.lava_burst.ready) & mana >= 25", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "6" },
  { specId: "shaman-resto", priority: 10, spellName: "Lightning Bolt", spellIcon: "spell_nature_lightning", condition: "mana >= 30 & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "shaman-resto", priority: 11, spellName: "Astral Shift", spellIcon: "ability_shaman_astralshift", condition: "cooldown.astral_shift.ready & player.health.pct <= 35", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "shaman-resto", priority: 12, spellName: "Mana Tide Totem", spellIcon: "spell_frost_summonwaterelemental", condition: "cooldown.mana_tide_totem.ready & mana <= 35", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "F" },
  { specId: "shaman-resto", priority: 13, spellName: "Wind Shear", spellIcon: "spell_nature_cyclone", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Warlock Affliction ── TWW SimC-quality priority
  { specId: "warlock-aff", priority: 1, spellName: "Summon Darkglare", spellIcon: "spell_warlock_summondemonic", condition: "cooldown.summon_darkglare.ready & debuff.agony.up & debuff.corruption.up & debuff.unstable_affliction.up & fight_remains > 20", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "warlock-aff", priority: 2, spellName: "Soul Rot", spellIcon: "ability_nightfae_warlock", condition: "cooldown.soul_rot.ready & talent.soul_rot.enabled & debuff.agony.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "warlock-aff", priority: 3, spellName: "Vile Taint", spellIcon: "spell_warlock_voidwalkermark", condition: "cooldown.vile_taint.ready & talent.vile_taint.enabled & active_enemies >= 2", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "warlock-aff", priority: 4, spellName: "Agony", spellIcon: "spell_shadow_curseofsargeras", condition: "debuff.agony.remains < 5.4 | !debuff.agony.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "warlock-aff", priority: 5, spellName: "Unstable Affliction", spellIcon: "spell_shadow_unstableaffliction_3", condition: "debuff.unstable_affliction.remains < 4.2 | !debuff.unstable_affliction.up", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "warlock-aff", priority: 6, spellName: "Corruption", spellIcon: "spell_shadow_abominationexplosion", condition: "debuff.corruption.remains < 4.2 | !debuff.corruption.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "warlock-aff", priority: 7, spellName: "Siphon Life", spellIcon: "spell_shadow_requiem", condition: "talent.siphon_life.enabled & (debuff.siphon_life.remains < 4.5 | !debuff.siphon_life.up)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "warlock-aff", priority: 8, spellName: "Malefic Rapture", spellIcon: "ability_warlock_everlastingaffliction", condition: "soul_shards >= 1 & (debuff.agony.up & debuff.corruption.up & debuff.unstable_affliction.up | soul_shards >= 4)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "warlock-aff", priority: 9, spellName: "Seed of Corruption", spellIcon: "spell_shadow_seedofdestruction", condition: "active_enemies >= 3 & soul_shards >= 1 & !debuff.corruption.up", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "6" },
  { specId: "warlock-aff", priority: 10, spellName: "Drain Soul", spellIcon: "spell_shadow_haunting", condition: "target.health.pct <= 20 & talent.drain_soul.enabled & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "warlock-aff", priority: 11, spellName: "Shadow Bolt", spellIcon: "spell_shadow_shadowbolt", condition: "debuff.agony.up & debuff.corruption.up & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "warlock-aff", priority: 12, spellName: "Agony", spellIcon: "spell_shadow_curseofsargeras", condition: "moving & !debuff.agony.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "warlock-aff", priority: 13, spellName: "Unending Resolve", spellIcon: "spell_shadow_demonictactics", condition: "player.health.pct <= 35", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "warlock-aff", priority: 14, spellName: "Spell Lock", spellIcon: "spell_shadow_mindrot", condition: "target.is_casting_interruptible & pet.alive", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Warlock Demonology ── TWW SimC-quality priority
  { specId: "warlock-demo", priority: 1, spellName: "Nether Portal", spellIcon: "inv_netherportal", condition: "cooldown.nether_portal.ready & talent.nether_portal.enabled & soul_shards >= 1 & fight_remains > 25", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "E" },
  { specId: "warlock-demo", priority: 2, spellName: "Summon Demonic Tyrant", spellIcon: "inv_summondemonictyrant", condition: "cooldown.summon_demonic_tyrant.ready & soul_shards >= 3 & (buff.nether_portal.up | !talent.nether_portal.enabled) & fight_remains > 15", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "Q" },
  { specId: "warlock-demo", priority: 3, spellName: "Grimoire: Felguard", spellIcon: "spell_shadow_summonfelguard", condition: "cooldown.grimoire_felguard.ready & talent.grimoire_felguard.enabled", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "warlock-demo", priority: 4, spellName: "Call Dreadstalkers", spellIcon: "spell_warlock_calldreadstalkers", condition: "cooldown.call_dreadstalkers.ready & soul_shards >= 2", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "warlock-demo", priority: 5, spellName: "Guillotine", spellIcon: "ability_warlock_guillotine", condition: "cooldown.guillotine.ready & talent.guillotine.enabled & pet.alive & active_enemies >= 2", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "warlock-demo", priority: 6, spellName: "Hand of Guldan", spellIcon: "ability_warlock_handofguldan", condition: "soul_shards >= 3 & !moving", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "warlock-demo", priority: 7, spellName: "Implosion", spellIcon: "spell_warlock_implosion", condition: "active_enemies >= 3 & buff.wild_imps.stack >= 6", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "warlock-demo", priority: 8, spellName: "Power Siphon", spellIcon: "spell_warlock_powersiphon", condition: "cooldown.power_siphon.ready & talent.power_siphon.enabled & buff.wild_imps.stack >= 2 & buff.demonic_core.stack < 4", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "warlock-demo", priority: 9, spellName: "Demonbolt", spellIcon: "spell_warlock_demonbolt", condition: "buff.demonic_core.up & (buff.demonic_core.stack >= 3 | prev_gcd.1.call_dreadstalkers | prev_gcd.1.hand_of_guldan)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "warlock-demo", priority: 10, spellName: "Shadow Bolt", spellIcon: "spell_shadow_shadowbolt", condition: "buff.demonic_core.down & soul_shards < 5 & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "warlock-demo", priority: 11, spellName: "Demonbolt", spellIcon: "spell_warlock_demonbolt", condition: "moving & buff.demonic_core.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "warlock-demo", priority: 12, spellName: "Soul Strike", spellIcon: "ability_warlock_soulstrike", condition: "cooldown.soul_strike.ready & talent.soul_strike.enabled & soul_shards < 5", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "6" },
  { specId: "warlock-demo", priority: 13, spellName: "Unending Resolve", spellIcon: "spell_shadow_demonictactics", condition: "player.health.pct <= 35", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "warlock-demo", priority: 14, spellName: "Axe Toss", spellIcon: "ability_warrior_punishingblow", condition: "target.is_casting_interruptible & pet.alive", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },
  { specId: "warlock-demo", priority: 15, spellName: "Spell Lock", spellIcon: "spell_shadow_mindrot", condition: "target.is_casting_interruptible & pet.alive", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "C" },

  // ── Warlock Destruction ── TWW SimC-quality priority
  { specId: "warlock-dest", priority: 1, spellName: "Summon Infernal", spellIcon: "spell_shadow_summoninfernal", condition: "cooldown.summon_infernal.ready & fight_remains > 20 & (soul_shards >= 3 | time < 5)", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "warlock-dest", priority: 2, spellName: "Havoc", spellIcon: "spell_fire_incinerate", condition: "active_enemies >= 2 & cooldown.havoc.ready & buff.havoc.down", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "G" },
  { specId: "warlock-dest", priority: 3, spellName: "Channel Demonfire", spellIcon: "spell_fire_demonfire", condition: "cooldown.channel_demonfire.ready & talent.channel_demonfire.enabled & debuff.immolate.up & !moving", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "warlock-dest", priority: 4, spellName: "Shadowburn", spellIcon: "spell_shadow_scourgebuild", condition: "target.health.pct <= 20 & soul_shards >= 1 & talent.shadowburn.enabled", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "warlock-dest", priority: 5, spellName: "Chaos Bolt", spellIcon: "ability_warlock_chaosbolt", condition: "soul_shards >= 2 & (buff.backdraft.up | buff.ritual_of_ruin.up | soul_shards >= 4) & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "warlock-dest", priority: 6, spellName: "Rain of Fire", spellIcon: "spell_shadow_rainoffire", condition: "active_enemies >= 3 & (soul_shards >= 3 | buff.ritual_of_ruin.up)", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "warlock-dest", priority: 7, spellName: "Immolate", spellIcon: "spell_fire_immolation", condition: "debuff.immolate.remains < 5.4 | !debuff.immolate.up", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "warlock-dest", priority: 8, spellName: "Conflagrate", spellIcon: "spell_fire_fireball", condition: "cooldown.conflagrate.charges >= 1 & (buff.backdraft.stack < 2 | soul_shards < 4)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "warlock-dest", priority: 9, spellName: "Dimensional Rift", spellIcon: "spell_warlock_dimensionalrift", condition: "cooldown.dimensional_rift.charges >= 1 & talent.dimensional_rift.enabled & soul_shards < 4", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "warlock-dest", priority: 10, spellName: "Incinerate", spellIcon: "spell_fire_burnout", condition: "soul_shards < 4 & !moving", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "warlock-dest", priority: 11, spellName: "Conflagrate", spellIcon: "spell_fire_fireball", condition: "moving & cooldown.conflagrate.charges >= 1", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "warlock-dest", priority: 12, spellName: "Immolate", spellIcon: "spell_fire_immolation", condition: "moving & debuff.immolate.down", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "warlock-dest", priority: 13, spellName: "Unending Resolve", spellIcon: "spell_shadow_demonictactics", condition: "player.health.pct <= 35", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "warlock-dest", priority: 14, spellName: "Spell Lock", spellIcon: "spell_shadow_mindrot", condition: "target.is_casting_interruptible & pet.alive", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Warrior Arms ── TWW Arms SimC priority
  { specId: "warrior-arms", priority: 1, spellName: "Colossus Smash", spellIcon: "ability_warrior_colossussmash", condition: "cooldown.colossus_smash.ready & (fight_remains > 15 | target.health.pct <= 20)", mode: "Both", isInterrupt: false, isOffensive: true, isCooldown: true, enabled: true, keybind: "Q" },
  { specId: "warrior-arms", priority: 2, spellName: "Avatar", spellIcon: "ability_warrior_titansgrip", condition: "cooldown.avatar.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "E" },
  { specId: "warrior-arms", priority: 3, spellName: "Execute", spellIcon: "inv_sword_48", condition: "(target.health.pct <= 20 | buff.sudden_death.up) & debuff.colossus_smash.up & rage >= 20", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "warrior-arms", priority: 4, spellName: "Mortal Strike", spellIcon: "ability_warrior_savageblow", condition: "cooldown.mortal_strike.ready", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "warrior-arms", priority: 5, spellName: "Bladestorm", spellIcon: "ability_warrior_bladestorm", condition: "cooldown.bladestorm.ready & (active_enemies >= 2 | debuff.colossus_smash.up) & talent.bladestorm.enabled", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "warrior-arms", priority: 5, spellName: "Ravager", spellIcon: "warrior_talent_icon_ravager", condition: "cooldown.ravager.ready & (active_enemies >= 2 | debuff.colossus_smash.up)", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "warrior-arms", priority: 6, spellName: "Sweeping Strikes", spellIcon: "ability_rogue_slicedice", condition: "cooldown.sweeping_strikes.ready & active_enemies >= 2 & buff.sweeping_strikes.down", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "warrior-arms", priority: 7, spellName: "Overpower", spellIcon: "ability_meleedamage", condition: "cooldown.overpower.charges >= 1 & (buff.overpower.stack < 2 | cooldown.mortal_strike.remains > gcd.max)", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "warrior-arms", priority: 8, spellName: "Execute", spellIcon: "inv_sword_48", condition: "(target.health.pct <= 35 | buff.sudden_death.up) & rage >= 20", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "warrior-arms", priority: 9, spellName: "Skullsplitter", spellIcon: "inv_skullsplitter", condition: "cooldown.skullsplitter.ready & rage < 50 & talent.skullsplitter.enabled", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "warrior-arms", priority: 10, spellName: "Whirlwind", spellIcon: "ability_whirlwind", condition: "active_enemies >= 3 & rage >= 30", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "5" },
  { specId: "warrior-arms", priority: 11, spellName: "Mortal Strike", spellIcon: "ability_warrior_savageblow", condition: "cooldown.mortal_strike.ready", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "warrior-arms", priority: 12, spellName: "Slam", spellIcon: "ability_warrior_decisivestrike", condition: "rage >= 20 & cooldown.mortal_strike.remains > gcd.max & cooldown.overpower.remains > gcd.max", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "6" },
  { specId: "warrior-arms", priority: 13, spellName: "Die by the Sword", spellIcon: "ability_warrior_challange", condition: "player.health.pct <= 35", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "warrior-arms", priority: 14, spellName: "Pummel", spellIcon: "ability_warrior_pummel", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Warrior Protection ── TWW Prot Warrior priority (Shield Block uptime, Ignore Pain management, rage efficiency, threat)
  { specId: "warrior-prot", priority: 1, spellName: "Shield Block", spellIcon: "ability_defend", condition: "cooldown.shield_block.charges >= 1 & (buff.shield_block.down | buff.shield_block.remains < 2)", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "E" },
  { specId: "warrior-prot", priority: 2, spellName: "Ignore Pain", spellIcon: "ability_warrior_renewedvigor", condition: "rage >= 35 & buff.ignore_pain.down & player.health.pct <= 75", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "5" },
  { specId: "warrior-prot", priority: 3, spellName: "Shield Slam", spellIcon: "inv_shield_05", condition: "cooldown.shield_slam.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "1" },
  { specId: "warrior-prot", priority: 4, spellName: "Thunder Clap", spellIcon: "spell_nature_thunderclap", condition: "cooldown.thunder_clap.ready", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "2" },
  { specId: "warrior-prot", priority: 5, spellName: "Avatar", spellIcon: "ability_warrior_titansgrip", condition: "cooldown.avatar.ready & (active_enemies >= 3 | player.health.pct <= 50)", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "Q" },
  { specId: "warrior-prot", priority: 6, spellName: "Demoralizing Shout", spellIcon: "ability_warrior_warcry", condition: "cooldown.demoralizing_shout.ready & active_enemies >= 2", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "G" },
  { specId: "warrior-prot", priority: 7, spellName: "Revenge", spellIcon: "ability_warrior_revenge", condition: "buff.revenge.up | rage >= 20", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "3" },
  { specId: "warrior-prot", priority: 8, spellName: "Execute", spellIcon: "inv_sword_48", condition: "(target.health.pct <= 20 | buff.sudden_death.up) & rage >= 20", mode: "Both", isInterrupt: false, isOffensive: true, enabled: true, keybind: "F" },
  { specId: "warrior-prot", priority: 9, spellName: "Ravager", spellIcon: "warrior_talent_icon_ravager", condition: "cooldown.ravager.ready & active_enemies >= 2", mode: "AoE", isInterrupt: false, isOffensive: true, enabled: true, keybind: "R" },
  { specId: "warrior-prot", priority: 10, spellName: "Devastate", spellIcon: "ability_warrior_devastate", condition: "rage < 60", mode: "ST", isInterrupt: false, isOffensive: true, enabled: true, keybind: "4" },
  { specId: "warrior-prot", priority: 11, spellName: "Ignore Pain", spellIcon: "ability_warrior_renewedvigor", condition: "rage >= 70", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "5" },
  { specId: "warrior-prot", priority: 12, spellName: "Shield Wall", spellIcon: "ability_warrior_shieldwall", condition: "cooldown.shield_wall.ready & player.health.pct <= 25", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "V" },
  { specId: "warrior-prot", priority: 13, spellName: "Last Stand", spellIcon: "spell_holy_ashestoashes", condition: "cooldown.last_stand.ready & player.health.pct <= 20", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "Z" },
  { specId: "warrior-prot", priority: 14, spellName: "Pummel", spellIcon: "ability_warrior_pummel", condition: "target.is_casting_interruptible", mode: "Both", isInterrupt: true, isOffensive: false, enabled: true, keybind: "X" },

  // ── Precombat Entries ──

  // Druid (all specs): Mark of the Wild
  { specId: "druid-balance", priority: -110, spellName: "Mark of the Wild", spellIcon: "", condition: "!buff.mark_of_the_wild.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },
  { specId: "druid-feral", priority: -110, spellName: "Mark of the Wild", spellIcon: "", condition: "!buff.mark_of_the_wild.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },
  { specId: "druid-guardian", priority: -110, spellName: "Mark of the Wild", spellIcon: "", condition: "!buff.mark_of_the_wild.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },
  { specId: "druid-resto", priority: -110, spellName: "Mark of the Wild", spellIcon: "", condition: "!buff.mark_of_the_wild.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },

  // Druid: appropriate form per spec
  { specId: "druid-balance", priority: -100, spellName: "Moonkin Form", spellIcon: "", condition: "!form.moonkin", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },
  { specId: "druid-feral", priority: -100, spellName: "Cat Form", spellIcon: "", condition: "!form.cat", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },
  { specId: "druid-feral", priority: -99, spellName: "Prowl", spellIcon: "", condition: "!stealthed.all", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },
  { specId: "druid-guardian", priority: -100, spellName: "Bear Form", spellIcon: "", condition: "!form.bear", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },

  // Warrior (all specs): Battle Shout
  { specId: "warrior-arms", priority: -110, spellName: "Battle Shout", spellIcon: "", condition: "!buff.battle_shout.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },
  { specId: "warrior-fury", priority: -110, spellName: "Battle Shout", spellIcon: "", condition: "!buff.battle_shout.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },
  { specId: "warrior-prot", priority: -110, spellName: "Battle Shout", spellIcon: "", condition: "!buff.battle_shout.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },

  // Warrior Arms: Battle Stance
  { specId: "warrior-arms", priority: -100, spellName: "Battle Stance", spellIcon: "", condition: "!form.battle", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },

  // Priest (all specs): Power Word: Fortitude
  { specId: "priest-shadow", priority: -110, spellName: "Power Word: Fortitude", spellIcon: "", condition: "!buff.power_word_fortitude.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },
  { specId: "priest-disc", priority: -110, spellName: "Power Word: Fortitude", spellIcon: "", condition: "!buff.power_word_fortitude.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },
  { specId: "priest-holy", priority: -110, spellName: "Power Word: Fortitude", spellIcon: "", condition: "!buff.power_word_fortitude.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },

  // Priest Shadow: Shadowform
  { specId: "priest-shadow", priority: -100, spellName: "Shadowform", spellIcon: "", condition: "!buff.shadowform.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },

  // Mage (all specs): Arcane Intellect
  { specId: "mage-arcane", priority: -110, spellName: "Arcane Intellect", spellIcon: "", condition: "!buff.arcane_intellect.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },
  { specId: "mage-fire", priority: -110, spellName: "Arcane Intellect", spellIcon: "", condition: "!buff.arcane_intellect.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },
  { specId: "mage-frost", priority: -110, spellName: "Arcane Intellect", spellIcon: "", condition: "!buff.arcane_intellect.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },

  // Shaman Enhancement: weapon enchants + Lightning Shield
  { specId: "shaman-enh", priority: -100, spellName: "Windfury Weapon", spellIcon: "", condition: "!buff.windfury_weapon.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },
  { specId: "shaman-enh", priority: -99, spellName: "Flametongue Weapon", spellIcon: "", condition: "!buff.flametongue_weapon.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },
  { specId: "shaman-enh", priority: -98, spellName: "Lightning Shield", spellIcon: "", condition: "!buff.lightning_shield.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },

  // Rogue (all specs): Stealth
  { specId: "rogue-ass", priority: -100, spellName: "Stealth", spellIcon: "", condition: "!stealthed.all", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },
  { specId: "rogue-out", priority: -100, spellName: "Stealth", spellIcon: "", condition: "!stealthed.all", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },
  { specId: "rogue-sub", priority: -100, spellName: "Stealth", spellIcon: "", condition: "!stealthed.all", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },

  // Evoker (all specs): Blessing of the Bronze
  { specId: "evoker-dev", priority: -110, spellName: "Blessing of the Bronze", spellIcon: "", condition: "!buff.blessing_of_the_bronze.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },
  { specId: "evoker-aug", priority: -110, spellName: "Blessing of the Bronze", spellIcon: "", condition: "!buff.blessing_of_the_bronze.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },
  { specId: "evoker-pres", priority: -110, spellName: "Blessing of the Bronze", spellIcon: "", condition: "!buff.blessing_of_the_bronze.up", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },

  // Warlock (all specs): Summon Pet
  { specId: "warlock-aff", priority: -100, spellName: "Summon Pet", spellIcon: "", condition: "!pet.main", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },
  { specId: "warlock-demo", priority: -100, spellName: "Summon Pet", spellIcon: "", condition: "!pet.main", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },
  { specId: "warlock-dest", priority: -100, spellName: "Summon Pet", spellIcon: "", condition: "!pet.main", mode: "Both", isInterrupt: false, isOffensive: false, enabled: true, keybind: "", isPrecombat: true, precombatType: "state" },
];


/**
 * Seed data for boss-mod combat alert integrations.
 *
 * Each alert ties a boss ability (by spell ID) to an interrupt or defensive
 * response, with a priority level. These are consumed by the addon generator
 * to emit Lua callbacks that listen for DBM/BigWigs timer events and flash
 * the appropriate counter-spell on the HUD.
 */
const SEED_ALERTS: InsertCombatAlert[] = [
  { specId: "hunter-bm", alertName: "Tyrannical Throw", source: "DBM", spellId: "340340", interruptSpell: "Counter Shot", priority: "Critical", enabled: true },
  { specId: "hunter-bm", alertName: "Shadow Bolt Volley", source: "BigWigs", spellId: "196546", interruptSpell: "Counter Shot", priority: "High", enabled: true },
  { specId: "dh-havoc", alertName: "Necrotic Bolt", source: "DBM", spellId: "374554", interruptSpell: "Disrupt", priority: "Critical", enabled: true },
  { specId: "dh-havoc", alertName: "Desecration", source: "BigWigs", spellId: "384640", interruptSpell: "Disrupt", priority: "High", enabled: true },
  { specId: "warrior-fury", alertName: "Shadow Word: Pain", source: "DBM", spellId: "589", interruptSpell: "Pummel", priority: "High", enabled: true },
  { specId: "mage-frost", alertName: "Pyretic Incantation", source: "DBM", spellId: "381490", interruptSpell: "Counterspell", priority: "Critical", enabled: true },
  { specId: "shaman-ele", alertName: "Chain Lightning", source: "BigWigs", spellId: "421147", interruptSpell: "Wind Shear", priority: "Critical", enabled: true },
];

/**
 * Default HUD configuration values shared by all specs.
 *
 * Specs that don't have a custom entry in {@link SEED_HUD_CONFIGS} will
 * receive these defaults when their HUD config is first created. Individual
 * fields control icon sizing, queue depth, resource bar visibility, defensive
 * thresholds, keybind display, and more. See {@link HudConfig} for field docs.
 */
export const DEFAULT_HUD: Omit<InsertHudConfig, "specId"> = {
  scale: 1.2,
  opacity: 0.95,
  positionX: 50,
  positionY: 70,
  iconSize: 48,
  predIconSize: 34,
  queueSlots: 3,
  showKeybind: true,
  keybindFontSize: 30,
  keybindPosition: "center",
  showSpellName: true,
  spellNameFontSize: 10,
  showCondition: false,
  showResourceBar: false,
  showHeader: true,
  resourceCapThreshold: 90,
  aoeThreshold: 3,
  defaultModeDungeon: "AoE",
  defaultModeRaid: "AoE",
  defaultModeDelve: "AoE",
  defaultModeWorld: "AoE",
  smartModeSwitch: true,
  showPrediction: true,
  predictionOpacity: 0.4,
  framePadding: 16,
  iconSpacing: 14,
  lockPosition: false,
  debugMode: false,
  showCooldownText: true,
  showGcdSpark: true,
  outOfCombatMode: false,
  showDefensives: false,
  defensiveThreshold: 35,
  defensiveThresholdMinor: 60,
  defensiveThresholdMajor: 30,
  survivabilityMode: false,
  showSelfHeals: false,
  formAwareness: true,
  keybindBarPriority: ["Main Action Bar", "Bottom Left", "Bottom Right", "Right Bar 1", "Right Bar 2"],
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
};

/**
 * Per-spec HUD configuration overrides applied on top of {@link DEFAULT_HUD}.
 *
 * Only specs listed here receive non-default HUD settings at startup. Other
 * specs will get a HUD config with all defaults when first accessed via
 * {@link IStorage.upsertHudConfig}.
 */
const SEED_HUD_CONFIGS: InsertHudConfig[] = [
  { ...DEFAULT_HUD, specId: "hunter-bm", queueSlots: 3, iconSize: 52 },
  { ...DEFAULT_HUD, specId: "dh-havoc", scale: 1.3, queueSlots: 3, iconSize: 52, aoeThreshold: 4, positionY: 72 },
  { ...DEFAULT_HUD, specId: "warrior-fury", scale: 1.1, queueSlots: 2, iconSize: 48, resourceCapThreshold: 85, aoeThreshold: 4 },
  { ...DEFAULT_HUD, specId: "mage-frost", showResourceBar: false, queueSlots: 3, iconSize: 48 },
  { ...DEFAULT_HUD, specId: "shaman-ele", queueSlots: 3, iconSize: 48, resourceCapThreshold: 95 },
];

/**
 * Storage interface defining all CRUD operations for the addon platform.
 *
 * All methods are async to allow future migration from in-memory storage
 * to a persistent database without changing call sites. The current
 * implementation ({@link MemStorage}) resolves immediately.
 */
export interface IStorage {
  /** Returns the full list of WoW class specializations. */
  getSpecs(): Promise<Spec[]>;

  /** Finds a single spec by its unique ID (e.g. `"hunter-bm"`). */
  getSpec(id: string): Promise<Spec | undefined>;

  /** Returns all APL entries for a spec, sorted by ascending priority. */
  getAplEntries(specId: string): Promise<AplEntry[]>;

  /** Creates a new APL entry and assigns it a UUID. */
  createAplEntry(entry: InsertAplEntry): Promise<AplEntry>;

  /** Partially updates an existing APL entry. Returns `undefined` if not found. */
  updateAplEntry(id: string, entry: Partial<InsertAplEntry>): Promise<AplEntry | undefined>;

  /** Deletes an APL entry by ID. Returns `true` if the entry existed. */
  deleteAplEntry(id: string): Promise<boolean>;

  /**
   * Reassigns priority values to APL entries based on the provided ID order.
   * The first ID in the array receives priority 1, the second priority 2, etc.
   * Only entries belonging to the given `specId` are affected.
   *
   * @returns The reordered list of APL entries for the spec.
   */
  reorderAplEntries(specId: string, orderedIds: string[]): Promise<AplEntry[]>;

  /** Returns the HUD configuration for a spec, or `undefined` if none exists. */
  getHudConfig(specId: string): Promise<HudConfig | undefined>;

  /**
   * Creates or updates the HUD configuration for a spec.
   * If a config already exists for the spec, its ID is preserved; otherwise
   * a new UUID is assigned.
   */
  upsertHudConfig(config: InsertHudConfig): Promise<HudConfig>;

  /** Returns all combat alert entries for a spec (unordered). */
  getCombatAlerts(specId: string): Promise<CombatAlert[]>;

  /** Creates a new combat alert entry and assigns it a UUID. */
  createCombatAlert(alert: InsertCombatAlert): Promise<CombatAlert>;

  /** Partially updates an existing combat alert. Returns `undefined` if not found. */
  updateCombatAlert(id: string, alert: Partial<InsertCombatAlert>): Promise<CombatAlert | undefined>;

  /** Deletes a combat alert by ID. Returns `true` if the alert existed. */
  deleteCombatAlert(id: string): Promise<boolean>;

  /** Returns all saved profiles for a spec, sorted by creation date ascending. */
  getProfiles(specId: string): Promise<Profile[]>;

  /**
   * Saves a new profile snapshot capturing the current HUD config and
   * keybind overrides. A UUID and timestamp are assigned automatically.
   */
  saveProfile(profile: InsertProfile, hudConfig: HudConfig): Promise<Profile>;

  /** Retrieves a single profile by its UUID. */
  loadProfile(id: string): Promise<Profile | undefined>;

  /** Deletes a profile by ID. Returns `true` if the profile existed. */
  deleteProfile(id: string): Promise<boolean>;

  /**
   * Returns the current sync engine state including version, running flag,
   * last sync time/status, and the most recent 20 sync run history entries.
   */
  getSyncState(): Promise<SyncState>;

  /** Appends a sync run record to history (capped at 50 entries). */
  addSyncRun(run: SyncRun): Promise<void>;

  /** Partially updates a sync run record by ID (e.g. to set completedAt/status). */
  updateSyncRun(id: string, updates: Partial<SyncRun>): Promise<void>;

  /** Sets the global "sync in progress" flag. */
  setSyncRunning(running: boolean): Promise<void>;

  /** Updates the current addon version and persists it to disk. */
  setCurrentVersion(version: string): Promise<void>;

  /** Returns the last stored content hash of SimC APL data, or null if never synced. */
  getLastDataHash(): Promise<string | null>;

  /** Stores the content hash of the most recently synced SimC APL data. */
  setLastDataHash(hash: string): Promise<void>;
}

/**
 * In-memory implementation of {@link IStorage}.
 *
 * Uses ES `Map` collections keyed by UUID for O(1) lookups on APL entries,
 * HUD configs (keyed by specId), combat alerts, and profiles. Sync history
 * is stored as a bounded array (max 50 entries).
 *
 * On construction, the maps are populated with seed data from the module-level
 * constants ({@link SEED_APL}, {@link SEED_HUD_CONFIGS},
 * {@link SEED_ALERTS}). The addon version is initialized from the persisted
 * `.addon-version` file via {@link readPersistedVersion}.
 */
export class MemStorage implements IStorage {
  /** APL entries keyed by UUID. */
  private aplEntries: Map<string, AplEntry> = new Map();

  /** HUD configs keyed by spec ID (one config per spec). */
  private hudConfigs: Map<string, HudConfig> = new Map();

  /** Combat alert entries keyed by UUID. */
  private combatAlerts: Map<string, CombatAlert> = new Map();

  /** Saved profile snapshots keyed by UUID. */
  private profiles: Map<string, Profile> = new Map();

  /** Whether a sync cycle is currently in progress (runtime-only, intentionally not persisted). */
  private syncRunning = false;

  constructor() {
    this.seed();
  }

  /**
   * Populates the in-memory maps with seed data.
   *
   * Called once from the constructor. Assigns a fresh UUID to each seed
   * record.
   */
  private seed() {
    for (const entry of SEED_APL) {
      const id = randomUUID();
      this.aplEntries.set(id, { ...entry, isPrecombat: entry.isPrecombat ?? false, precombatType: entry.precombatType ?? null, id });
    }
    for (const config of SEED_HUD_CONFIGS) {
      const id = randomUUID();
      this.hudConfigs.set(config.specId, { ...config, id });
    }
    for (const alert of SEED_ALERTS) {
      const id = randomUUID();
      this.combatAlerts.set(id, { ...alert, id });
    }
  }

  /** @inheritdoc */
  async getSpecs() { return SPECS; }

  /** @inheritdoc */
  async getSpec(id: string) { return SPECS.find(s => s.id === id); }

  /** @inheritdoc */
  async getAplEntries(specId: string): Promise<AplEntry[]> {
    return Array.from(this.aplEntries.values())
      .filter(e => e.specId === specId)
      .map(e => ({ ...e, isCooldown: e.isCooldown ?? false }))
      .sort((a, b) => a.priority - b.priority);
  }

  /** @inheritdoc */
  async createAplEntry(entry: InsertAplEntry): Promise<AplEntry> {
    const id = randomUUID();
    const aplEntry: AplEntry = { ...entry, id };
    this.aplEntries.set(id, aplEntry);
    return aplEntry;
  }

  /** @inheritdoc */
  async updateAplEntry(id: string, updates: Partial<InsertAplEntry>): Promise<AplEntry | undefined> {
    const existing = this.aplEntries.get(id);
    if (!existing) return undefined;
    const updated = { ...existing, ...updates };
    this.aplEntries.set(id, updated);
    return updated;
  }

  /** @inheritdoc */
  async deleteAplEntry(id: string): Promise<boolean> {
    return this.aplEntries.delete(id);
  }

  /** @inheritdoc */
  async reorderAplEntries(specId: string, orderedIds: string[]): Promise<AplEntry[]> {
    orderedIds.forEach((id, index) => {
      const entry = this.aplEntries.get(id);
      if (entry && entry.specId === specId) {
        this.aplEntries.set(id, { ...entry, priority: index + 1 });
      }
    });
    return this.getAplEntries(specId);
  }

  /** @inheritdoc */
  async getHudConfig(specId: string): Promise<HudConfig | undefined> {
    return this.hudConfigs.get(specId);
  }

  /** @inheritdoc */
  async upsertHudConfig(config: InsertHudConfig): Promise<HudConfig> {
    const existing = this.hudConfigs.get(config.specId);
    const id = existing?.id ?? randomUUID();
    const updated: HudConfig = { ...config, id };
    this.hudConfigs.set(config.specId, updated);
    return updated;
  }

  /** @inheritdoc */
  async getCombatAlerts(specId: string): Promise<CombatAlert[]> {
    return Array.from(this.combatAlerts.values()).filter(a => a.specId === specId);
  }

  /** @inheritdoc */
  async createCombatAlert(alert: InsertCombatAlert): Promise<CombatAlert> {
    const id = randomUUID();
    const combatAlert: CombatAlert = { ...alert, id };
    this.combatAlerts.set(id, combatAlert);
    return combatAlert;
  }

  /** @inheritdoc */
  async updateCombatAlert(id: string, updates: Partial<InsertCombatAlert>): Promise<CombatAlert | undefined> {
    const existing = this.combatAlerts.get(id);
    if (!existing) return undefined;
    const updated = { ...existing, ...updates };
    this.combatAlerts.set(id, updated);
    return updated;
  }

  /** @inheritdoc */
  async deleteCombatAlert(id: string): Promise<boolean> {
    return this.combatAlerts.delete(id);
  }

  /** @inheritdoc */
  async getProfiles(specId: string): Promise<Profile[]> {
    return Array.from(this.profiles.values())
      .filter(p => p.specId === specId)
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  }

  /**
   * @inheritdoc
   *
   * Strips the `id` and `specId` fields from the provided HUD config before
   * embedding it in the profile snapshot, since those are redundant within
   * the profile's own `specId` and `id`.
   */
  async saveProfile(input: InsertProfile, hudConfig: HudConfig): Promise<Profile> {
    const id = randomUUID();
    const { id: _hid, specId: _sid, ...hudFields } = hudConfig;
    const profile: Profile = {
      id,
      name: input.name,
      specId: input.specId,
      hudConfig: hudFields,
      keybindOverrides: input.keybindOverrides ?? {},
      createdAt: new Date().toISOString(),
    };
    this.profiles.set(id, profile);
    return profile;
  }

  /** @inheritdoc */
  async loadProfile(id: string): Promise<Profile | undefined> {
    return this.profiles.get(id);
  }

  /** @inheritdoc */
  async deleteProfile(id: string): Promise<boolean> {
    return this.profiles.delete(id);
  }

  /**
   * @inheritdoc
   *
   * Derives the sync state from the history array:
   * - `lastSyncTime` — `completedAt` of the most recent successful run.
   * - `lastSyncStatus` — status of the most recent run (ignoring "running").
   * - `lastError` — error message from the most recent failed run.
   * - `history` — the last 20 entries (most recent last).
   */
  async getSyncState(): Promise<SyncState> {
    const rows = await db.select().from(syncRuns).orderBy(desc(syncRuns.startedAt)).limit(20);
    const history: SyncRun[] = rows.map(r => ({
      id: r.id,
      startedAt: r.startedAt,
      completedAt: r.completedAt ?? null,
      status: r.status as SyncRun["status"],
      simcSpecs: r.simcSpecs,
      fallbackSpecs: r.fallbackSpecs,
      addonVersion: r.addonVersion,
      curseforgeUploaded: r.curseforgeUploaded,
      error: r.error ?? null,
      triggeredBy: r.triggeredBy as SyncRun["triggeredBy"],
    })).reverse();

    const lastSuccess = [...history].reverse().find(r => r.status === "success");
    const lastRun = history[history.length - 1];
    const lastError = [...history].reverse().find(r => r.status === "error");

    const versionRow = await db.select().from(syncKv).where(eq(syncKv.key, "currentVersion")).limit(1);
    const currentVersion = versionRow[0]?.value ?? readPersistedVersion();

    const hashRow = await db.select().from(syncKv).where(eq(syncKv.key, "lastDataHash")).limit(1);

    return {
      lastSyncTime: lastSuccess?.completedAt ?? null,
      lastSyncStatus: lastRun?.status === "running" ? null : (lastRun?.status ?? null),
      lastError: lastError?.error ?? null,
      currentVersion,
      isRunning: this.syncRunning,
      lastDataHash: hashRow[0]?.value ?? null,
      history,
    };
  }

  async addSyncRun(run: SyncRun): Promise<void> {
    await db.insert(syncRuns).values({
      id: run.id,
      startedAt: run.startedAt,
      completedAt: run.completedAt,
      status: run.status,
      simcSpecs: run.simcSpecs,
      fallbackSpecs: run.fallbackSpecs,
      addonVersion: run.addonVersion,
      curseforgeUploaded: run.curseforgeUploaded,
      error: run.error,
      triggeredBy: run.triggeredBy,
    });
  }

  async updateSyncRun(id: string, updates: Partial<SyncRun>): Promise<void> {
    const setObj: Record<string, any> = {};
    if (updates.status !== undefined) setObj.status = updates.status;
    if (updates.completedAt !== undefined) setObj.completedAt = updates.completedAt;
    if (updates.simcSpecs !== undefined) setObj.simcSpecs = updates.simcSpecs;
    if (updates.fallbackSpecs !== undefined) setObj.fallbackSpecs = updates.fallbackSpecs;
    if (updates.addonVersion !== undefined) setObj.addonVersion = updates.addonVersion;
    if (updates.curseforgeUploaded !== undefined) setObj.curseforgeUploaded = updates.curseforgeUploaded;
    if (updates.error !== undefined) setObj.error = updates.error;
    if (Object.keys(setObj).length > 0) {
      await db.update(syncRuns).set(setObj).where(eq(syncRuns.id, id));
    }
  }

  async setSyncRunning(running: boolean): Promise<void> {
    this.syncRunning = running;
  }

  async setCurrentVersion(version: string): Promise<void> {
    await db.insert(syncKv).values({ key: "currentVersion", value: version })
      .onConflictDoUpdate({ target: syncKv.key, set: { value: version } });
    writePersistedVersion(version);
  }

  async getLastDataHash(): Promise<string | null> {
    const row = await db.select().from(syncKv).where(eq(syncKv.key, "lastDataHash")).limit(1);
    return row[0]?.value ?? null;
  }

  async setLastDataHash(hash: string): Promise<void> {
    await db.insert(syncKv).values({ key: "lastDataHash", value: hash })
      .onConflictDoUpdate({ target: syncKv.key, set: { value: hash } });
  }
}

/** Singleton storage instance used throughout the application. */
export const storage = new MemStorage();
