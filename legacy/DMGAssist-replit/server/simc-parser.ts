/**
 * @module simc-parser
 *
 * SimulationCraft (SimC) Action Priority List (APL) Parser & Fetcher
 *
 * This module fetches raw SimC profile files from the official SimulationCraft
 * GitHub repository, parses their textual APL syntax, and translates them into
 * structured {@link AplEntry} objects consumed by the addon generator.
 *
 * ### SimC APL Format Overview
 *
 * SimC profiles define rotation priorities using a line-based DSL:
 *
 * ```
 * actions=auto_attack
 * actions+=/raging_blow,if=buff.enrage.up
 * actions+=/call_action_list,name=aoe,if=active_enemies>=3
 * actions.aoe=whirlwind
 * actions.aoe+=/bladestorm,if=buff.enrage.up
 * ```
 *
 * Key syntax elements:
 * - `actions=` / `actions+=` — append to the "default" action list
 * - `actions.<listName>=` / `actions.<listName>+=` — append to a named sub-list
 * - `call_action_list,name=<listName>` — invoke a named sub-list (returns after)
 * - `run_action_list,name=<listName>` — invoke and stop (does not return)
 * - `,if=<condition>` — SimC condition expression (e.g. `buff.enrage.up&cooldown.recklessness.remains<3`)
 *
 * ### Translation Pipeline
 *
 * 1. **Tier Discovery** — {@link discoverAvailableTiers} probes GitHub for the
 *    latest expansion branch + raid tier that has published profiles.
 * 2. **Fetch** — {@link fetchSimcApl} downloads the `.simc` profile for a
 *    given spec (e.g. `warrior-fury` → `Warrior_Fury`).
 * 3. **Parse** — {@link parseSimcProfile} tokenizes lines into action lists,
 *    resolves `call_action_list` / `run_action_list` references, and flattens
 *    the graph into a single ordered list of {@link ParsedAction} objects.
 * 4. **Build** — {@link buildAplEntries} converts parsed actions into
 *    {@link AplEntry} records with formatted spell names, icons, interrupt /
 *    defensive flags, and ST/AoE mode detection.
 * 5. **Cache** — Results are cached in-memory with a 1-hour TTL to avoid
 *    hammering GitHub on repeated requests.
 */

import type { AplEntry } from "@shared/schema";
import { SPELL_ID_MAP } from "./spell-ids";
import { randomUUID } from "crypto";

/** Base URL for raw file access on the SimulationCraft GitHub repository. */
const GITHUB_RAW = "https://raw.githubusercontent.com/simulationcraft/simc";

/**
 * Expansion branches to probe when discovering available profile tiers.
 *
 * Each entry represents a WoW expansion branch in the SimC repository.
 * - `branch` — Git branch name (e.g. `"midnight"`, `"thewarwithin"`)
 * - `prefix` — Short tier prefix used in profile folder names (e.g. `"MID"`, `"TWW"`)
 * - `maxSeason` — Upper bound season number to start probing from (descends to 1)
 *
 * Ordered newest-first so the latest expansion is checked first.
 */
const BRANCH_TIERS: { branch: string; prefix: string; maxSeason: number }[] = [
  { branch: "midnight", prefix: "MID", maxSeason: 5 },
  { branch: "thewarwithin", prefix: "TWW", maxSeason: 5 },
];

/**
 * Maps internal spec identifiers (e.g. `"warrior-fury"`) to the SimC profile
 * filename component (e.g. `"Warrior_Fury"`).
 *
 * The full URL is assembled as:
 * `{GITHUB_RAW}/{branch}/profiles/{tier}/{tier}_{fileName}.simc`
 *
 * @example
 * SPEC_FILE_MAP["dk-frost"] // "Death_Knight_Frost"
 */
const SPEC_FILE_MAP: Record<string, string> = {
  "dk-blood": "Death_Knight_Blood",
  "dk-frost": "Death_Knight_Frost",
  "dk-unholy": "Death_Knight_Unholy",
  "dh-havoc": "Demon_Hunter_Havoc",
  "dh-vengeance": "Demon_Hunter_Vengeance",
  "druid-balance": "Druid_Balance",
  "druid-feral": "Druid_Feral",
  "druid-guardian": "Druid_Guardian",
  "druid-resto": "Druid_Restoration",
  "evoker-dev": "Evoker_Devastation",
  "evoker-aug": "Evoker_Augmentation",
  "evoker-pres": "Evoker_Preservation",
  "hunter-bm": "Hunter_Beast_Mastery",
  "hunter-mm": "Hunter_Marksmanship",
  "hunter-surv": "Hunter_Survival",
  "mage-arcane": "Mage_Arcane",
  "mage-fire": "Mage_Fire",
  "mage-frost": "Mage_Frost",
  "monk-ww": "Monk_Windwalker",
  "monk-mw": "Monk_Mistweaver",
  "monk-brew": "Monk_Brewmaster",
  "paladin-ret": "Paladin_Retribution",
  "paladin-prot": "Paladin_Protection",
  "paladin-holy": "Paladin_Holy",
  "priest-shadow": "Priest_Shadow",
  "priest-disc": "Priest_Discipline",
  "priest-holy": "Priest_Holy",
  "rogue-ass": "Rogue_Assassination",
  "rogue-out": "Rogue_Outlaw",
  "rogue-sub": "Rogue_Subtlety",
  "shaman-ele": "Shaman_Elemental",
  "shaman-enh": "Shaman_Enhancement",
  "shaman-resto": "Shaman_Restoration",
  "warlock-aff": "Warlock_Affliction",
  "warlock-demo": "Warlock_Demonology",
  "warlock-dest": "Warlock_Destruction",
  "warrior-arms": "Warrior_Arms",
  "warrior-fury": "Warrior_Fury",
  "warrior-prot": "Warrior_Protection",
};

/**
 * SimC actions that should be silently skipped during parsing.
 *
 * These are non-combat utility actions (consumables, stat snapshots, resource
 * pooling), racial abilities (which vary per character), or meta-actions
 * (variables, sequences) that have no direct in-game spell equivalent.
 */
const RACIAL_ABILITIES = new Set([
  "lights_judgment", "bag_of_tricks", "berserking", "blood_fury",
  "fireblood", "ancestral_call", "arcane_torrent", "shadowmeld",
  "war_stomp", "stoneform", "rocket_barrage", "haymaker",
]);

const SKIP_ACTIONS = new Set([
  "snapshot_stats", "auto_attack", "auto_shot", "potion", "flask",
  "food", "augmentation", "use_items",
  "invoke_external_buff", "wait", "pool_resource", "sequence",
  "temporary_enchant",
]);

/**
 * Spell names recognized as interrupt abilities.
 *
 * When an APL entry uses one of these spells, its {@link AplEntry.isInterrupt}
 * flag is set to `true`, allowing the addon engine to handle interrupt logic
 * separately (e.g. only suggest when a target is casting an interruptible spell).
 */
const INTERRUPT_SPELLS = new Set([
  "pummel", "kick", "counterspell", "wind_shear", "skull_bash",
  "mind_freeze", "rebuke", "disrupt", "solar_beam", "silencing_shot",
  "muzzle", "spear_hand_strike", "counter_shot",
]);


const AOE_SPELLS = new Set([
  "volley", "multi_shot", "explosive_shot", "barrage", "rain_of_death",
  "whirlwind", "bladestorm", "ravager", "thunderous_roar", "thunder_clap", "shockwave", "cleave", "odyn_s_fury",
  "rain_of_fire", "seed_of_corruption", "soul_rot", "vile_taint", "implosion", "felstorm", "bilescourge_bombers",
  "blizzard", "frozen_orb", "comet_storm", "arcane_explosion", "arcane_barrage", "meteor", "flamestrike", "living_bomb", "dragon_s_breath",
  "starfall", "stellar_flare", "fury_of_elune", "sunfire", "thrash", "swipe", "primal_wrath", "brutal_slash",
  "divine_storm", "consecration", "wake_of_ashes", "final_reckoning", "eye_of_tyr", "shield_of_the_righteous", "hammer_of_the_righteous",
  "fan_of_knives", "crimson_tempest", "shuriken_storm", "black_powder", "blade_flurry", "killing_spree",
  "chain_lightning", "earthquake", "lava_beam", "crash_lightning", "sundering", "chain_heal", "chain_harvest", "primordial_wave",
  "mind_sear", "shadow_crash", "psychic_link", "void_crash", "halo", "divine_star", "holy_nova",
  "keg_smash", "spinning_crane_kick", "breath_of_fire", "rushing_jade_wind", "chi_burst", "chi_wave",
  "death_and_decay", "epidemic", "soul_reaper", "howling_blast", "remorseless_winter", "abomination_limb",
  "multi_shot", "butchery", "bomb", "wildfire_bomb", "steel_trap",
  "havoc", "eye_beam", "blade_dance", "death_sweep", "glaive_tempest", "fel_barrage", "sigil_of_flame",
  "breath_of_eons", "eternity_surge", "deep_breath", "pyre", "shattering_star",
]);

const NON_OFFENSIVE_SPELLS = new Set([
  "regrowth", "healing_touch", "rejuvenation", "wild_growth", "swiftmend",
  "lifebloom", "tranquility", "nourish", "efflorescence", "cenarion_ward",
  "ironbark", "barkskin", "survival_instincts", "frenzied_regeneration",
  "flash_heal", "greater_heal", "heal", "prayer_of_healing", "prayer_of_mending",
  "renew", "circle_of_healing", "divine_hymn", "power_word_shield", "pain_suppression",
  "power_word_barrier", "rapture", "spirit_shell", "fade", "dispersion",
  "healing_surge", "healing_wave", "chain_heal", "riptide", "healing_rain",
  "healing_stream_totem", "healing_tide_totem", "spirit_link_totem", "astral_shift",
  "flash_of_light", "holy_light", "light_of_dawn", "beacon_of_light",
  "lay_on_hands", "divine_shield", "blessing_of_protection", "ardent_defender",
  "guardian_of_ancient_kings",
  "vivify", "enveloping_mist", "renewing_mist", "essence_font", "revival",
  "life_cocoon", "soothing_mist", "fortifying_brew", "celestial_brew",
  "diffuse_magic", "dampen_harm",
  "ironfur", "shield_block", "shield_of_the_righteous", "demon_spikes",
  "bone_shield", "ignore_pain", "shield_wall", "last_stand",
  "vampiric_blood", "icebound_fortitude", "anti_magic_shell",
  "fiery_brand", "metamorphosis",
  "die_by_the_sword", "enraged_regeneration",
  "aspect_of_the_turtle", "exhilaration",
  "cloak_of_shadows", "evasion",
  "ice_block",
  "remove_corruption", "natures_cure", "nature_s_cure",
  "rebirth", "mass_resurrection",
]);

function isCooldownList(listName: string): boolean {
  const lower = listName.toLowerCase();
  return lower === "cooldowns" || lower === "cds" || lower.startsWith("cd_")
    || lower.startsWith("cooldowns_") || lower === "ogcd"
    || lower.includes("_cds") || lower.includes("_cooldowns");
}

const MAJOR_COOLDOWN_SPELLS = new Set([
  "trueshot", "rapid_fire", "volley",
  "combustion", "icy_veins", "arcane_surge", "evocation",
  "avenging_wrath", "crusade", "wake_of_ashes", "final_reckoning",
  "summon_infernal", "summon_darkglare", "dark_soul_instability", "dark_soul_misery",
  "doom_winds", "feral_spirit", "ascendance", "stormkeeper",
  "recklessness", "avatar", "thunderous_roar", "ravager", "bladestorm", "champions_spear",
  "vendetta", "deathmark", "shadow_dance", "shadow_blades", "adrenaline_rush", "killing_spree",
  "pillar_of_frost", "empower_rune_weapon", "breath_of_sindragosa", "abomination_limb",
  "celestial_alignment", "incarnation_chosen_of_elune", "incarnation_king_of_the_jungle", "convoke_the_spirits", "berserk", "berserk_cat", "fury_of_elune", "new_moon", "half_moon", "full_moon", "wild_mushroom",
  "coordinated_assault", "fury_of_the_eagle", "spearhead",
  "power_infusion", "void_eruption", "dark_ascension", "mindbender", "shadowfiend",
  "call_of_the_wild", "bestial_wrath",
  "black_arrow",
  "bloodlust", "heroism", "time_warp",
  "metamorphosis", "the_hunt", "essence_break", "eye_beam", "fel_barrage",
  "sunfire_demise", "fury_of_the_sun_king",
  "dragons_breath", "shifting_power",
  "invoke_xuen_the_white_tiger", "storm_earth_and_fire", "weapons_of_order",
  "deathborne", "soul_reaper",
]);

const STATE_SPELLS = new Set([
  "moonkin_form", "cat_form", "bear_form", "travel_form",
  "battle_stance", "defensive_stance", "berserker_stance",
  "shadowform", "lightning_shield", "stealth", "prowl",
  "windfury_weapon", "flametongue_weapon", "apply_poison",
  "shield_of_vengeance", "summon_pet", "grimoire_of_sacrifice",
  "mark_of_the_wild", "arcane_intellect", "power_word_fortitude",
  "battle_shout", "blessing_of_the_bronze",
]);

const PRECOMBAT_SKIP_ACTIONS = new Set([
  "snapshot_stats", "variable", "potion", "flask", "food",
  "augmentation", "use_item", "use_items", "invoke_external_buff",
  "temporary_enchant", "wait", "sequence",
]);

export function generatePrecombatCondition(spell: string): string {
  if (spell.endsWith("_form")) {
    const formName = spell.replace("_form", "");
    return `!form.${formName}`;
  }
  if (spell.endsWith("_stance")) {
    const stanceName = spell.replace("_stance", "");
    return `!form.${stanceName}`;
  }
  if (spell === "stealth" || spell === "prowl") {
    return "!stealthed.all";
  }
  if (spell === "summon_pet") {
    return "!pet.main";
  }
  return `!buff.${spell}.up`;
}

const CLASS_GROUP_BUFFS: Record<string, { spell: string; buff: string }> = {
  druid:   { spell: "Mark of the Wild",      buff: "mark_of_the_wild" },
  mage:    { spell: "Arcane Intellect",       buff: "arcane_intellect" },
  priest:  { spell: "Power Word: Fortitude",  buff: "power_word_fortitude" },
  warrior: { spell: "Battle Shout",           buff: "battle_shout" },
  evoker:  { spell: "Blessing of the Bronze", buff: "blessing_of_the_bronze" },
};

function getClassFromSpecId(specId: string): string {
  const prefix = specId.split("-")[0];
  const map: Record<string, string> = {
    dk: "dk", dh: "dh", druid: "druid", evoker: "evoker",
    hunter: "hunter", mage: "mage", monk: "monk", paladin: "paladin",
    priest: "priest", rogue: "rogue", shaman: "shaman",
    warlock: "warlock", warrior: "warrior",
  };
  return map[prefix] || prefix;
}

export function injectGroupBuff(specId: string, entries: AplEntry[]): AplEntry[] {
  const classKey = getClassFromSpecId(specId);
  const groupBuff = CLASS_GROUP_BUFFS[classKey];
  if (!groupBuff) return entries;

  const alreadyHas = entries.some(e =>
    e.spellName.toLowerCase().replace(/[^a-z]/g, "") ===
    groupBuff.spell.toLowerCase().replace(/[^a-z]/g, "")
  );
  if (alreadyHas) return entries;

  const buffEntry: AplEntry = {
    id: randomUUID(),
    specId,
    spellName: groupBuff.spell,
    spellIcon: "",
    priority: -110,
    condition: `!buff.${groupBuff.buff}.up`,
    mode: "Both",
    isInterrupt: false,
    isOffensive: false,
    keybind: "",
    enabled: true,
    isPrecombat: true,
    precombatType: "state",
  };

  return [buffEntry, ...entries];
}

/**
 * Result of fetching and parsing a SimC APL for a single spec.
 *
 * @property entries - Ordered list of APL entries ready for storage / addon generation
 * @property source  - Human-readable source label (e.g. `"SimC TWW3"`)
 * @property tier    - Tier identifier (e.g. `"TWW3"`)
 * @property branch  - Git branch the profile was fetched from (e.g. `"thewarwithin"`)
 */
export interface SimcVariable {
  name: string;
  value: string;
  op: string;
  condition?: string;
  valueElse?: string;
  default?: string;
}

export interface SimcFetchResult {
  entries: AplEntry[];
  variables: SimcVariable[];
  source: string;
  tier: string;
  branch: string;
}

/**
 * In-memory cache for fetched SimC APL results, keyed by spec ID.
 * Each entry stores the parsed data and the timestamp it was fetched.
 */
const fetchCache = new Map<string, { data: SimcFetchResult; timestamp: number }>();

/** Cache time-to-live: 1 hour in milliseconds. */
const CACHE_TTL = 60 * 60 * 1000;

/**
 * Represents a discovered SimC profile tier on GitHub.
 *
 * @property branch  - Git branch name (e.g. `"thewarwithin"`)
 * @property tier    - Full tier identifier (e.g. `"TWW3"`)
 * @property prefix  - Short prefix (e.g. `"TWW"`)
 * @property season  - Season number within the expansion (e.g. `3`)
 */
interface DiscoveredTier {
  branch: string;
  tier: string;
  prefix: string;
  season: number;
}

/** Cached list of discovered tiers from the most recent discovery probe. */
let discoveredTiers: DiscoveredTier[] = [];

/** Timestamp of the last successful tier discovery. */
let lastDiscovery = 0;

/** Discovery results are cached for 30 minutes before re-probing. */
const DISCOVERY_TTL = 30 * 60 * 1000;

/**
 * Fetches raw text content from a URL with an abort-controller timeout.
 *
 * Returns `null` on any failure (network error, non-2xx status, timeout)
 * rather than throwing, making it safe for speculative probing.
 *
 * @param url       - The URL to fetch
 * @param timeoutMs - Maximum time to wait before aborting (default: 8000ms)
 * @returns The response body as a string, or `null` on failure
 */
async function fetchRaw(url: string, timeoutMs = 8000): Promise<string | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(url, { signal: controller.signal });
    if (!res.ok) return null;
    return await res.text();
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Probes the SimC GitHub repository to discover which expansion tiers have
 * published profiles.
 *
 * The algorithm iterates {@link BRANCH_TIERS} (newest expansion first) and
 * for each branch, counts down from `maxSeason` to 1. For each candidate
 * tier it tests a small set of well-known spec profiles. The first tier
 * that returns a valid profile (containing `"actions"`) is recorded as
 * available for that branch.
 *
 * Results are cached for {@link DISCOVERY_TTL} (30 minutes) to avoid
 * excessive GitHub requests.
 *
 * @returns Array of discovered tiers, ordered by branch priority (newest first)
 *
 * @example
 * const tiers = await discoverAvailableTiers();
 * // [{ branch: "midnight", tier: "MID1", prefix: "MID", season: 1 }]
 */
export async function discoverAvailableTiers(): Promise<DiscoveredTier[]> {
  const now = Date.now();
  if (discoveredTiers.length > 0 && now - lastDiscovery < DISCOVERY_TTL) {
    return discoveredTiers;
  }

  const testSpecs = ["Death_Knight_Unholy", "Warrior_Fury", "Rogue_Subtlety"];
  const found: DiscoveredTier[] = [];

  for (const { branch, prefix, maxSeason } of BRANCH_TIERS) {
    let branchFound = false;
    for (let season = maxSeason; season >= 1 && !branchFound; season--) {
      const tier = `${prefix}${season}`;
      for (const testSpec of testSpecs) {
        const url = `${GITHUB_RAW}/${branch}/profiles/${tier}/${tier}_${testSpec}.simc`;
        const result = await fetchRaw(url, 5000);
        if (result && result.includes("actions")) {
          found.push({ branch, tier, prefix, season });
          branchFound = true;
          break;
        }
      }
    }
  }

  if (found.length > 0) {
    discoveredTiers = found;
    lastDiscovery = now;
  }

  return found;
}

/**
 * Returns the most recently discovered tier, or `null` if no discovery has
 * been performed yet.
 *
 * @returns The first (highest-priority) discovered tier, or `null`
 */
export function getLatestDiscoveredTier(): DiscoveredTier | null {
  return discoveredTiers[0] || null;
}

/**
 * Converts a SimC snake_case spell name into a human-readable Title Case name,
 * with manual corrections for possessive apostrophes that SimC strips.
 *
 * @param simcName - Snake_case spell identifier from a SimC profile
 * @returns Formatted display name
 *
 * @example
 * formatSpellName("raging_blow")    // "Raging Blow"
 * formatSpellName("odyns_fury")     // "Odyn's Fury"
 * formatSpellName("deaths_caress")  // "Death's Caress"
 */
function formatSpellName(simcName: string): string {
  return simcName
    .split("_")
    .map(w => w.charAt(0).toUpperCase() + w.slice(1))
    .join(" ")
    .replace("Odyns Fury", "Odyn's Fury")
    .replace("Deaths Caress", "Death's Caress")
    .replace("Deaths Due", "Death's Due")
    .replace("Reapers Mark", "Reaper's Mark");
}

/**
 * Derives a conventional WoW spell icon texture name from a SimC spell name.
 *
 * Prefixes with `"spell_"` and strips any non-alphanumeric/underscore characters.
 * This produces a best-guess icon key; the actual icon resolution happens
 * client-side via the WoW API.
 *
 * @param simcName - Snake_case spell identifier
 * @returns Icon texture key (e.g. `"spell_raging_blow"`)
 *
 * @example
 * simcNameToIcon("raging_blow")  // "spell_raging_blow"
 * simcNameToIcon("odyn's_fury")  // "spell_odyns_fury"
 */
function simcNameToIcon(simcName: string): string {
  return "spell_" + simcName.toLowerCase().replace(/[^a-z0-9_]/g, "");
}

/**
 * Determines whether a parsed action should be classified as Single-Target,
 * AoE, or Both, based on heuristics from the action list name and the
 * SimC condition expression.
 *
 * Detection logic (in priority order):
 * 1. If the list name contains `"aoe"`, `"cleave"`, or `"multitarget"` → AoE
 * 2. If the list name contains `"single"`, `"st_"`, or equals `"st"` → ST
 * 3. If the condition references `spell_targets` or `active_enemies` with a
 *    threshold ≥ 2 → AoE
 * 4. Otherwise → Both
 *
 * @param condition - The raw SimC condition string (may be empty)
 * @param listName  - The name of the action list this action belongs to
 * @returns `"ST"`, `"AoE"`, or `"Both"`
 *
 * @example
 * detectMode("", "aoe")                                  // "AoE"
 * detectMode("", "st")                                   // "ST"
 * detectMode("active_enemies>=3", "default")             // "AoE"
 * detectMode("buff.enrage.up", "default")                // "Both"
 */
function detectMode(condition: string, listName: string, spell?: string): "ST" | "AoE" | "Both" {
  if (spell && AOE_SPELLS.has(spell)) {
    return "AoE";
  }
  if (listName.includes("aoe") || listName.includes("cleave") || listName.includes("multitarget")) {
    return "AoE";
  }
  if (listName.includes("single") || listName.includes("st_") || listName === "st") {
    return "ST";
  }
  if (condition.includes("spell_targets") || condition.includes("active_enemies")) {
    const match = condition.match(/active_enemies>=?(\d+)|spell_targets\.\w+>=?(\d+)/);
    if (match) {
      const threshold = parseInt(match[1] || match[2]);
      if (threshold >= 2) return "AoE";
    }
  }
  return "Both";
}

/**
 * A single parsed action extracted from a SimC profile line.
 *
 * @property spell     - The SimC spell identifier (e.g. `"raging_blow"`)
 * @property condition - The raw `if=` condition string, or empty if unconditional
 * @property listName  - The action list this action belongs to (e.g. `"default"`, `"aoe"`)
 */
interface ParsedAction {
  spell: string;
  condition: string;
  listName: string;
  isPrecombat: boolean;
  precombatType: "state" | "opener" | null;
}

/**
 * A reference to another action list via `call_action_list` or `run_action_list`.
 *
 * @property type      - `"call"` returns to the caller after the sub-list;
 *                        `"run"` replaces the current list (no return)
 * @property name      - The target action list name
 * @property condition - The raw `if=` condition for when to invoke the sub-list
 */
interface CallRef {
  type: "call" | "run";
  name: string;
  condition: string;
}

/**
 * Parses a raw SimC profile text into a flat, ordered array of {@link ParsedAction}s.
 *
 * ### Parsing Steps
 *
 * 1. **Line scanning** — Each line starting with `actions` is matched against
 *    regex patterns to extract the list name (default or named), the spell
 *    identifier, and any `if=` condition.
 *
 * 2. **Action list grouping** — Actions are grouped into named lists stored
 *    in a `Map<string, (ParsedAction | CallRef)[]>`. `call_action_list` and
 *    `run_action_list` are stored as {@link CallRef} entries instead of
 *    {@link ParsedAction}s.
 *
 * 3. **Filtering** — Actions in {@link SKIP_ACTIONS} are silently dropped.
 *    The `precombat` list is also skipped (pre-pull actions aren't relevant
 *    to the in-combat HUD). `use_item` is normalized to include the item
 *    name or slot (e.g. `"use_item:trinket1"`).
 *
 * 4. **Resolution** — Starting from the `"default"` list, sub-list references
 *    are recursively resolved (with cycle detection via a `visited` set) to
 *    produce a single flat sequence. Any unreferenced lists are appended
 *    afterward to avoid losing actions.
 *
 * @param rawText - The full text content of a `.simc` profile file
 * @returns Ordered array of parsed actions ready for {@link buildAplEntries}
 *
 * @example
 * const actions = parseSimcProfile(`
 *   actions=auto_attack
 *   actions+=/raging_blow,if=buff.enrage.up
 *   actions+=/call_action_list,name=aoe,if=active_enemies>=3
 *   actions.aoe=whirlwind
 * `);
 * // [
 * //   { spell: "raging_blow", condition: "buff.enrage.up", listName: "default" },
 * //   { spell: "whirlwind", condition: "", listName: "aoe" }
 * // ]
 */
function parseSimcProfile(rawText: string): { actions: ParsedAction[]; variables: SimcVariable[] } {
  const lines = rawText.split("\n");
  const actionLists = new Map<string, (ParsedAction | CallRef)[]>();
  const variables: SimcVariable[] = [];

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("actions")) continue;

    let listName = "default";
    let rest = "";

    const assignMatch = trimmed.match(/^actions\.(\w+)\+?=\/?(.*)/);
    const defaultMatch = trimmed.match(/^actions\+?=\/?(.*)/);

    if (assignMatch) {
      listName = assignMatch[1];
      rest = assignMatch[2];
    } else if (defaultMatch) {
      rest = defaultMatch[1];
    } else {
      continue;
    }

    if (!rest) continue;

    const isPrecombatList = listName === "precombat";

    const parts = rest.split(",");
    const spell = parts[0].trim();
    if (!spell) continue;

    let condition = "";
    for (const part of parts.slice(1)) {
      const kv = part.trim();
      if (kv.startsWith("if=")) {
        condition = kv.substring(3);
        break;
      }
    }

    if (spell === "variable") {
      let varName = "";
      let varValue = "";
      let varOp = "set";
      let varCondition = "";
      let varValueElse = "";
      let varDefault = "";
      for (const part of parts.slice(1)) {
        const kv = part.trim();
        if (kv.startsWith("name=")) varName = kv.substring(5);
        else if (kv.startsWith("value_else=")) varValueElse = kv.substring(11);
        else if (kv.startsWith("value=")) varValue = kv.substring(6);
        else if (kv.startsWith("op=")) varOp = kv.substring(3);
        else if (kv.startsWith("condition=")) varCondition = kv.substring(10);
        else if (kv.startsWith("default=")) varDefault = kv.substring(8);
      }
      if (varName) {
        if (varOp === "reset") {
          variables.push({ name: varName, value: varDefault || "0", op: varOp, default: varDefault });
        } else if (varValue) {
          variables.push({
            name: varName,
            value: varValue,
            op: varOp,
            ...(varCondition ? { condition: varCondition } : {}),
            ...(varValueElse ? { valueElse: varValueElse } : {}),
            ...(varDefault ? { default: varDefault } : {}),
          });
        }
      }
      continue;
    }

    if (isPrecombatList) {
      if (PRECOMBAT_SKIP_ACTIONS.has(spell)) continue;
      if (spell === "call_action_list" || spell === "run_action_list") continue;

      const isState = STATE_SPELLS.has(spell);
      const precombatCondition = isState ? generatePrecombatCondition(spell) : condition;

      if (!actionLists.has(listName)) actionLists.set(listName, []);
      actionLists.get(listName)!.push({
        spell,
        condition: precombatCondition,
        listName,
        isPrecombat: true,
        precombatType: isState ? "state" : "opener",
      });
      continue;
    }

    if (spell === "call_action_list" || spell === "run_action_list") {
      let refName = "";
      for (const part of parts.slice(1)) {
        const kv = part.trim();
        if (kv.startsWith("name=")) {
          refName = kv.substring(5);
          break;
        }
      }
      if (refName) {
        if (!actionLists.has(listName)) actionLists.set(listName, []);
        actionLists.get(listName)!.push({
          type: spell === "run_action_list" ? "run" : "call",
          name: refName,
          condition,
        });
      }
      continue;
    }

    if (SKIP_ACTIONS.has(spell)) continue;

    if (spell === "use_item") {
      let slot = "";
      let itemName = "";
      for (const part of parts.slice(1)) {
        const kv = part.trim();
        if (kv.startsWith("slot=")) slot = kv.substring(5);
        if (kv.startsWith("name=")) itemName = kv.substring(5);
      }
      const trinketSpell = itemName
        ? `use_item:${itemName}`
        : slot
        ? `use_item:${slot}`
        : "use_item:trinket1";
      if (!actionLists.has(listName)) actionLists.set(listName, []);
      actionLists.get(listName)!.push({ spell: trinketSpell, condition, listName, isPrecombat: false, precombatType: null });
      continue;
    }

    if (!actionLists.has(listName)) actionLists.set(listName, []);
    actionLists.get(listName)!.push({ spell, condition, listName, isPrecombat: false, precombatType: null });
  }

  const precombatActions: ParsedAction[] = [];
  const precombatItems = actionLists.get("precombat");
  if (precombatItems) {
    for (const item of precombatItems) {
      if (!("type" in item)) {
        precombatActions.push(item);
      }
    }
  }

  const resolved: ParsedAction[] = [];
  const visited = new Set<string>();
  visited.add("precombat");

  function resolveList(name: string) {
    if (visited.has(name)) return;
    visited.add(name);

    const items = actionLists.get(name);
    if (!items) return;

    for (const item of items) {
      if ("type" in item) {
        resolveList(item.name);
      } else {
        resolved.push(item);
      }
    }
  }

  resolveList("default");

  for (const [name] of actionLists) {
    if (!visited.has(name)) {
      resolveList(name);
    }
  }

  return { actions: [...precombatActions, ...resolved], variables };
}

/**
 * Converts an array of {@link ParsedAction}s into finalized {@link AplEntry}
 * records ready for storage and addon generation.
 *
 * For each action:
 * - Deduplicates by `spell|condition` key to avoid redundant entries
 * - Assigns sequential priority numbers (1-based)
 * - Formats the spell name for display ({@link formatSpellName})
 * - Derives an icon key ({@link simcNameToIcon}); trinkets get a generic icon
 * - Flags interrupt / defensive / minor-defensive / offensive classification
 * - Detects ST / AoE / Both mode ({@link detectMode})
 *
 * @param specId  - The internal spec identifier (e.g. `"warrior-fury"`)
 * @param actions - Ordered array of parsed actions from {@link parseSimcProfile}
 * @returns Array of {@link AplEntry} objects with unique UUIDs and sequential priorities
 *
 * @example
 * const entries = buildAplEntries("warrior-fury", [
 *   { spell: "raging_blow", condition: "buff.enrage.up", listName: "default" }
 * ]);
 * // [{
 * //   id: "...",
 * //   specId: "warrior-fury",
 * //   spellName: "Raging Blow",
 * //   spellIcon: "spell_raging_blow",
 * //   priority: 1,
 * //   condition: "buff.enrage.up",
 * //   mode: "Both",
 * //   isInterrupt: false,
 * //   isOffensive: true,
 * //   keybind: "",
 * //   enabled: true
 * // }]
 */
function buildAplEntries(specId: string, actions: ParsedAction[]): AplEntry[] {
  const seenKeys = new Set<string>();
  const entries: AplEntry[] = [];
  let priority = 1;
  let precombatStatePriority = -100;
  let precombatOpenerPriority = -50;

  for (const action of actions) {
    const key = `${action.spell}|${action.condition}`;
    if (seenKeys.has(key)) continue;
    seenKeys.add(key);

    const isTrinket = action.spell.startsWith("use_item:");
    const rawName = isTrinket ? action.spell.substring(9) : action.spell;
    const spellName = isTrinket
      ? `[Trinket] ${formatSpellName(rawName)}`
      : formatSpellName(action.spell);
    const isInterrupt = INTERRUPT_SPELLS.has(action.spell);
    const isCooldown = isCooldownList(action.listName) || MAJOR_COOLDOWN_SPELLS.has(action.spell);
    const mode = detectMode(action.condition, action.listName, action.spell);

    let entryPriority: number;
    if (action.isPrecombat && action.precombatType === "state") {
      entryPriority = precombatStatePriority++;
    } else if (action.isPrecombat && action.precombatType === "opener") {
      entryPriority = precombatOpenerPriority++;
    } else {
      entryPriority = priority++;
    }

    const spellId = isTrinket ? undefined : SPELL_ID_MAP[action.spell];

    entries.push({
      id: randomUUID(),
      specId,
      spellName,
      spellIcon: isTrinket ? "INV_Misc_Trinket" : simcNameToIcon(action.spell),
      priority: entryPriority,
      condition: action.condition,
      mode,
      isInterrupt,
      isCooldown,
      isOffensive: !isInterrupt && !NON_OFFENSIVE_SPELLS.has(action.spell),
      keybind: "",
      enabled: true,
      isPrecombat: action.isPrecombat,
      precombatType: action.precombatType,
      ...(spellId ? { spellId } : {}),
    });
  }

  return entries;
}


/**
 * Fetches and parses the SimC APL for a given spec, returning structured
 * {@link AplEntry} data.
 *
 * This is the main entry point for the parser module. It:
 * 1. Checks the in-memory cache (1-hour TTL)
 * 2. Looks up the SimC filename via {@link SPEC_FILE_MAP}
 * 3. Discovers available tiers via {@link discoverAvailableTiers}
 * 4. Iterates tiers from newest to oldest, fetching and parsing profiles
 * 5. Caches and returns the first successful result
 *
 * Falls back to hardcoded tier guesses (`MID1`, `TWW3`) if tier discovery
 * yields no results.
 *
 * @param specId - Internal spec identifier (e.g. `"warrior-fury"`, `"dk-frost"`)
 * @returns Parsed APL result with entries, source label, tier, and branch;
 *          or `null` if no profile could be found or parsed
 *
 * @example
 * const result = await fetchSimcApl("warrior-fury");
 * if (result) {
 *   console.log(result.source);  // "SimC TWW3"
 *   console.log(result.entries); // AplEntry[]
 * }
 */
export async function fetchSimcApl(specId: string): Promise<SimcFetchResult | null> {
  const cached = fetchCache.get(specId);
  if (cached && Date.now() - cached.timestamp < CACHE_TTL) {
    return cached.data;
  }

  const fileName = SPEC_FILE_MAP[specId];
  if (!fileName) return null;

  const tiers = await discoverAvailableTiers();
  const searchTiers = tiers.length > 0
    ? tiers
    : [
        { branch: "midnight", tier: "MID1", prefix: "MID", season: 1 },
        { branch: "thewarwithin", tier: "TWW3", prefix: "TWW", season: 3 },
      ];

  for (const { branch, prefix, season } of searchTiers) {
    for (let s = season; s >= 1; s--) {
      const tryTier = `${prefix}${s}`;
      const url = `${GITHUB_RAW}/${branch}/profiles/${tryTier}/${tryTier}_${fileName}.simc`;
      const raw = await fetchRaw(url);
      if (raw && raw.includes("actions")) {
        const parsed = parseSimcProfile(raw);
        const rawEntries = buildAplEntries(specId, parsed.actions);
        const entries = injectGroupBuff(specId, rawEntries);

        if (entries.length > 0) {
          const result: SimcFetchResult = {
            entries,
            variables: parsed.variables,
            source: `SimC ${tryTier}`,
            tier: tryTier,
            branch,
          };
          fetchCache.set(specId, { data: result, timestamp: Date.now() });
          return result;
        }
      }
    }
  }

  return null;
}

/**
 * Clears all cached data: fetched APL results, discovered tiers, and the
 * discovery timestamp. Forces fresh fetches on next access.
 *
 * Typically called when an admin triggers a manual re-sync or when the
 * sync engine begins a new cycle.
 */
export function clearSimcCache() {
  fetchCache.clear();
  discoveredTiers = [];
  lastDiscovery = 0;
}

/**
 * Returns diagnostic information about the current cache state.
 *
 * Useful for admin dashboards to inspect how many specs are cached
 * and which tiers have been discovered.
 *
 * @returns Object with `cached` (number of cached spec results) and
 *          `tiers` (array of discovered tier metadata)
 */
export function getSimcCacheStats() {
  return {
    cached: fetchCache.size,
    tiers: discoveredTiers,
  };
}
