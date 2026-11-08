import { type AplEntry } from "@shared/schema";
import { randomUUID } from "crypto";

function e(
  specId: string,
  priority: number,
  spellName: string,
  spellId: number,
  condition: string,
  mode: "ST" | "AoE" | "Both",
  opts: { isCooldown?: boolean; isInterrupt?: boolean; isOffensive?: boolean; isPrecombat?: boolean; precombatType?: "state" | "opener" | null } = {}
): AplEntry {
  return {
    id: randomUUID(),
    specId,
    priority,
    spellName,
    spellIcon: "",
    spellId,
    condition,
    mode,
    isInterrupt: opts.isInterrupt ?? false,
    isOffensive: opts.isOffensive ?? false,
    isCooldown: opts.isCooldown ?? false,
    enabled: true,
    keybind: "",
    isPrecombat: opts.isPrecombat ?? false,
    precombatType: opts.precombatType ?? null,
  };
}

const DRUID_BALANCE: AplEntry[] = [
  e("druid-balance", 1, "Solar Beam", 78675, "", "Both", { isInterrupt: true }),
  e("druid-balance", 2, "Moonkin Form", 24858, "!form.moonkin", "Both", { isPrecombat: true, precombatType: "state" }),
  e("druid-balance", 3, "Sunfire", 164815, "", "Both"),
  e("druid-balance", 4, "Moonfire", 164812, "", "Both"),
  e("druid-balance", 5, "Convoke the Spirits", 391528, "", "Both", { isCooldown: true, isOffensive: true }),
  e("druid-balance", 6, "Lunar Eclipse", 1233272, "charges>=1&!buff.eclipse_lunar.up", "Both", { isCooldown: true }),
  e("druid-balance", 8, "Fury of Elune", 202770, "", "Both", { isCooldown: true }),
  e("druid-balance", 9, "Incarnation: Chosen of Elune", 102560, "", "Both", { isCooldown: true, isOffensive: true }),
  e("druid-balance", 10, "Celestial Alignment", 194223, "", "Both", { isCooldown: true, isOffensive: true }),
  e("druid-balance", 12, "Starfall", 191034, "", "AoE"),
  e("druid-balance", 13, "Starsurge", 78674, "", "ST"),
  e("druid-balance", 15, "New Moon", 274281, "", "Both", { isCooldown: true }),
  e("druid-balance", 16, "Half Moon", 274282, "", "Both", { isCooldown: true }),
  e("druid-balance", 17, "Full Moon", 274283, "", "Both", { isCooldown: true }),
  e("druid-balance", 20, "Force of Nature", 205636, "", "Both", { isCooldown: true }),
  e("druid-balance", 25, "Wild Mushroom", 88747, "", "AoE", { isCooldown: true }),
  e("druid-balance", 59, "Wrath", 190984, "!buff.eclipse_lunar.up", "ST"),
  e("druid-balance", 60, "Starfire", 194153, "", "Both"),
  e("druid-balance", 63, "Wrath", 5176, "!buff.eclipse_lunar.up", "ST"),
];

const ROGUE_ASS: AplEntry[] = [
  e("rogue-ass", 1, "Kick", 1766, "", "Both", { isInterrupt: true }),
  e("rogue-ass", 5, "Garrote", 703, "", "Both", { isCooldown: true }),
  e("rogue-ass", 10, "Rupture", 1943, "combo_points>=5", "Both"),
  e("rogue-ass", 15, "Deathmark", 360194, "", "Both", { isCooldown: true, isOffensive: true }),
  e("rogue-ass", 20, "Kingsbane", 385627, "", "Both", { isCooldown: true, isOffensive: true }),
  e("rogue-ass", 25, "Vanish", 1856, "", "Both", { isCooldown: true }),
  e("rogue-ass", 30, "Envenom", 32645, "combo_points>=5", "Both"),
  e("rogue-ass", 33, "Thistle Tea", 381623, "", "Both", { isCooldown: true }),
  e("rogue-ass", 35, "Shiv", 5938, "", "Both", { isCooldown: true }),
  e("rogue-ass", 40, "Crimson Tempest", 121411, "", "AoE"),
  e("rogue-ass", 42, "Ambush", 8676, "buff.blindside.up|buff.stealth.up", "Both"),
  e("rogue-ass", 45, "Mutilate", 1329, "", "ST"),
  e("rogue-ass", 46, "Fan of Knives", 51723, "", "AoE"),
];

const EVOKER_AUG: AplEntry[] = [
  e("evoker-aug", 1, "Quell", 351338, "", "Both", { isInterrupt: true }),
  e("evoker-aug", 5, "Ebon Might", 395152, "buff.ebon_might.remains<=4", "Both", { isCooldown: true, isOffensive: true }),
  e("evoker-aug", 10, "Breath of Eons", 403631, "", "Both", { isCooldown: true, isOffensive: true }),
  e("evoker-aug", 12, "Deep Breath", 357210, "", "Both", { isCooldown: true, isOffensive: true }),
  e("evoker-aug", 15, "Prescience", 409311, "", "Both", { isCooldown: true }),
  e("evoker-aug", 20, "Tip the Scales", 370553, "", "Both", { isCooldown: true }),
  e("evoker-aug", 25, "Fire Breath", 382266, "", "Both", { isCooldown: true }),
  e("evoker-aug", 26, "Upheaval", 396286, "", "Both", { isCooldown: true }),
  e("evoker-aug", 30, "Time Skip", 404977, "", "Both", { isCooldown: true }),
  e("evoker-aug", 35, "Eruption", 395160, "", "Both"),
  e("evoker-aug", 40, "Blistering Scales", 360827, "", "Both", { isCooldown: true }),
  e("evoker-aug", 45, "Azure Strike", 362969, "", "Both"),
  e("evoker-aug", 50, "Living Flame", 361469, "", "Both"),
];

const DK_BLOOD: AplEntry[] = [
  e("dk-blood", 1, "Mind Freeze", 47528, "", "Both", { isInterrupt: true }),
  e("dk-blood", 5, "Dancing Rune Weapon", 49028, "", "Both", { isCooldown: true, isOffensive: true }),
  e("dk-blood", 10, "Death and Decay", 43265, "", "Both", { isCooldown: true }),
  e("dk-blood", 15, "Blood Boil", 50842, "", "Both"),
  e("dk-blood", 20, "Consumption", 274156, "", "Both", { isCooldown: true }),
  e("dk-blood", 25, "Death Strike", 49998, "", "Both"),
  e("dk-blood", 30, "Marrowrend", 195182, "buff.bone_shield.stack<8", "Both"),
  e("dk-blood", 35, "Heart Strike", 206930, "", "ST"),
  e("dk-blood", 36, "Heart Strike", 206930, "", "AoE"),
  e("dk-blood", 40, "Raise Dead", 46585, "", "Both", { isCooldown: true }),
  e("dk-blood", 45, "Death's Caress", 195292, "", "Both"),
];

const DH_VENGEANCE: AplEntry[] = [
  e("dh-vengeance", 1, "Disrupt", 183752, "", "Both", { isInterrupt: true }),
  e("dh-vengeance", 5, "Fiery Brand", 204021, "", "Both", { isCooldown: true }),
  e("dh-vengeance", 8, "Sigil of Spite", 390163, "", "Both", { isCooldown: true }),
  e("dh-vengeance", 10, "Fel Devastation", 212084, "", "Both", { isCooldown: true, isOffensive: true }),
  e("dh-vengeance", 12, "Soul Carver", 207407, "", "Both", { isCooldown: true }),
  e("dh-vengeance", 15, "Immolation Aura", 258920, "", "Both", { isCooldown: true }),
  e("dh-vengeance", 20, "Spirit Bomb", 247454, "soul_fragments>=4", "AoE"),
  e("dh-vengeance", 25, "Fracture", 263642, "", "Both"),
  e("dh-vengeance", 30, "Soul Cleave", 228477, "", "Both"),
  e("dh-vengeance", 35, "Felblade", 232893, "", "Both", { isCooldown: true }),
  e("dh-vengeance", 40, "Sigil of Flame", 204596, "", "Both", { isCooldown: true }),
  e("dh-vengeance", 45, "Throw Glaive", 204157, "", "Both"),
];

const DRUID_GUARDIAN: AplEntry[] = [
  e("druid-guardian", 1, "Skull Bash", 106839, "", "Both", { isInterrupt: true }),
  e("druid-guardian", 2, "Bear Form", 5487, "!form.bear", "Both", { isPrecombat: true, precombatType: "state" }),
  e("druid-guardian", 5, "Incarnation: Guardian of Ursoc", 102558, "", "Both", { isCooldown: true, isOffensive: true }),
  e("druid-guardian", 8, "Rage of the Sleeper", 200851, "", "Both", { isCooldown: true }),
  e("druid-guardian", 10, "Moonfire", 164812, "", "Both"),
  e("druid-guardian", 15, "Thrash", 77758, "", "Both"),
  e("druid-guardian", 20, "Mangle", 33917, "", "Both"),
  e("druid-guardian", 25, "Ironfur", 192081, "", "Both"),
  e("druid-guardian", 30, "Maul", 6807, "", "Both"),
  e("druid-guardian", 35, "Swipe", 213771, "", "AoE"),
];

const MONK_BREW: AplEntry[] = [
  e("monk-brew", 1, "Spear Hand Strike", 116705, "", "Both", { isInterrupt: true }),
  e("monk-brew", 5, "Touch of Death", 322109, "", "Both", { isCooldown: true, isOffensive: true }),
  e("monk-brew", 8, "Invoke Niuzao, the Black Ox", 132578, "", "Both", { isCooldown: true, isOffensive: true }),
  e("monk-brew", 10, "Exploding Keg", 325153, "", "Both", { isCooldown: true }),
  e("monk-brew", 15, "Keg Smash", 121253, "", "Both", { isCooldown: true }),
  e("monk-brew", 20, "Blackout Kick", 205523, "", "Both"),
  e("monk-brew", 25, "Breath of Fire", 115181, "", "Both", { isCooldown: true }),
  e("monk-brew", 30, "Rushing Jade Wind", 116847, "", "Both", { isCooldown: true }),
  e("monk-brew", 35, "Chi Burst", 123986, "", "Both", { isCooldown: true }),
  e("monk-brew", 40, "Spinning Crane Kick", 322729, "", "AoE"),
  e("monk-brew", 45, "Tiger Palm", 100780, "", "Both"),
];

const PALADIN_PROT: AplEntry[] = [
  e("paladin-prot", 1, "Rebuke", 96231, "", "Both", { isInterrupt: true }),
  e("paladin-prot", 5, "Avenging Wrath", 31884, "", "Both", { isCooldown: true, isOffensive: true }),
  e("paladin-prot", 8, "Divine Toll", 375576, "", "Both", { isCooldown: true, isOffensive: true }),
  e("paladin-prot", 10, "Hammer of Light", 427453, "", "Both", { isCooldown: true }),
  e("paladin-prot", 15, "Shield of the Righteous", 53600, "", "Both"),
  e("paladin-prot", 20, "Avenger's Shield", 31935, "", "Both"),
  e("paladin-prot", 25, "Judgment", 275779, "", "Both"),
  e("paladin-prot", 28, "Hammer of Wrath", 24275, "", "Both", { isCooldown: true }),
  e("paladin-prot", 30, "Consecration", 26573, "", "Both"),
  e("paladin-prot", 35, "Blessed Hammer", 204019, "", "Both"),
  e("paladin-prot", 36, "Hammer of the Righteous", 53595, "", "Both"),
  e("paladin-prot", 40, "Word of Glory", 85673, "", "Both"),
];

const WARRIOR_PROT: AplEntry[] = [
  e("warrior-prot", 1, "Pummel", 6552, "", "Both", { isInterrupt: true }),
  e("warrior-prot", 5, "Avatar", 107574, "", "Both", { isCooldown: true, isOffensive: true }),
  e("warrior-prot", 8, "Ravager", 228920, "", "Both", { isCooldown: true, isOffensive: true }),
  e("warrior-prot", 10, "Champion's Spear", 376079, "", "Both", { isCooldown: true }),
  e("warrior-prot", 15, "Shield Block", 2565, "", "Both", { isCooldown: true }),
  e("warrior-prot", 18, "Shield Charge", 385952, "", "Both", { isCooldown: true }),
  e("warrior-prot", 20, "Thunder Clap", 6343, "", "Both"),
  e("warrior-prot", 25, "Shield Slam", 23922, "", "Both"),
  e("warrior-prot", 28, "Execute", 163201, "", "Both"),
  e("warrior-prot", 30, "Revenge", 6572, "", "Both"),
  e("warrior-prot", 35, "Devastate", 20243, "", "Both"),
];

const DRUID_RESTO: AplEntry[] = [
  e("druid-resto", 1, "Solar Beam", 78675, "", "Both", { isInterrupt: true }),
  e("druid-resto", 5, "Efflorescence", 145205, "", "Both"),
  e("druid-resto", 8, "Tranquility", 740, "", "Both", { isCooldown: true, isOffensive: true }),
  e("druid-resto", 10, "Convoke the Spirits", 391528, "", "Both", { isCooldown: true, isOffensive: true }),
  e("druid-resto", 12, "Incarnation: Tree of Life", 33891, "", "Both", { isCooldown: true, isOffensive: true }),
  e("druid-resto", 15, "Wild Growth", 48438, "", "Both", { isCooldown: true }),
  e("druid-resto", 18, "Swiftmend", 18562, "", "Both", { isCooldown: true }),
  e("druid-resto", 20, "Lifebloom", 33763, "", "Both"),
  e("druid-resto", 25, "Rejuvenation", 774, "", "Both"),
  e("druid-resto", 30, "Regrowth", 8936, "", "Both"),
  e("druid-resto", 35, "Sunfire", 164815, "", "Both"),
  e("druid-resto", 40, "Wrath", 5176, "", "Both"),
];

const EVOKER_PRES: AplEntry[] = [
  e("evoker-pres", 1, "Quell", 351338, "", "Both", { isInterrupt: true }),
  e("evoker-pres", 5, "Rewind", 363534, "", "Both", { isCooldown: true, isOffensive: true }),
  e("evoker-pres", 8, "Dream Flight", 359816, "", "Both", { isCooldown: true, isOffensive: true }),
  e("evoker-pres", 10, "Stasis", 370537, "", "Both", { isCooldown: true }),
  e("evoker-pres", 12, "Temporal Anomaly", 373861, "", "Both", { isCooldown: true }),
  e("evoker-pres", 15, "Dream Breath", 355936, "", "Both", { isCooldown: true }),
  e("evoker-pres", 18, "Spiritbloom", 367226, "", "Both", { isCooldown: true }),
  e("evoker-pres", 20, "Reversion", 366155, "", "Both"),
  e("evoker-pres", 25, "Echo", 364343, "", "Both"),
  e("evoker-pres", 28, "Emerald Blossom", 355913, "", "Both"),
  e("evoker-pres", 30, "Living Flame", 361469, "", "Both"),
  e("evoker-pres", 35, "Fire Breath", 382266, "", "Both", { isCooldown: true }),
  e("evoker-pres", 40, "Azure Strike", 362969, "", "Both"),
];

const MONK_MW: AplEntry[] = [
  e("monk-mw", 1, "Spear Hand Strike", 116705, "", "Both", { isInterrupt: true }),
  e("monk-mw", 5, "Invoke Chi-Ji, the Red Crane", 325197, "", "Both", { isCooldown: true, isOffensive: true }),
  e("monk-mw", 8, "Revival", 115310, "", "Both", { isCooldown: true, isOffensive: true }),
  e("monk-mw", 10, "Life Cocoon", 116849, "", "Both", { isCooldown: true }),
  e("monk-mw", 15, "Renewing Mist", 115151, "", "Both", { isCooldown: true }),
  e("monk-mw", 18, "Sheilun's Gift", 399491, "", "Both", { isCooldown: true }),
  e("monk-mw", 20, "Enveloping Mist", 124682, "", "Both"),
  e("monk-mw", 25, "Vivify", 116670, "", "Both"),
  e("monk-mw", 30, "Soothing Mist", 115175, "", "Both"),
  e("monk-mw", 35, "Rising Sun Kick", 107428, "", "Both", { isCooldown: true }),
  e("monk-mw", 40, "Tiger Palm", 100780, "", "Both"),
];

const PALADIN_HOLY: AplEntry[] = [
  e("paladin-holy", 1, "Rebuke", 96231, "", "Both", { isInterrupt: true }),
  e("paladin-holy", 5, "Avenging Wrath", 31884, "", "Both", { isCooldown: true, isOffensive: true }),
  e("paladin-holy", 8, "Divine Toll", 375576, "", "Both", { isCooldown: true, isOffensive: true }),
  e("paladin-holy", 10, "Daybreak", 414170, "", "Both", { isCooldown: true }),
  e("paladin-holy", 12, "Hammer of Light", 427453, "", "Both", { isCooldown: true }),
  e("paladin-holy", 15, "Holy Shock", 20473, "", "Both", { isCooldown: true }),
  e("paladin-holy", 18, "Light of Dawn", 85222, "", "AoE"),
  e("paladin-holy", 20, "Word of Glory", 85673, "", "Both"),
  e("paladin-holy", 25, "Holy Light", 82326, "", "Both"),
  e("paladin-holy", 28, "Flash of Light", 19750, "", "Both"),
  e("paladin-holy", 30, "Judgment", 275773, "", "Both"),
  e("paladin-holy", 35, "Shield of the Righteous", 53600, "", "Both"),
  e("paladin-holy", 40, "Crusader Strike", 35395, "", "Both"),
];

const PRIEST_DISC: AplEntry[] = [
  e("priest-disc", 1, "Silence", 15487, "", "Both", { isInterrupt: true }),
  e("priest-disc", 5, "Evangelism", 246287, "", "Both", { isCooldown: true, isOffensive: true }),
  e("priest-disc", 8, "Rapture", 47536, "", "Both", { isCooldown: true, isOffensive: true }),
  e("priest-disc", 10, "Power Word: Barrier", 62618, "", "Both", { isCooldown: true }),
  e("priest-disc", 12, "Power Word: Radiance", 194509, "", "Both", { isCooldown: true }),
  e("priest-disc", 15, "Penance", 47540, "", "Both", { isCooldown: true }),
  e("priest-disc", 18, "Schism", 214621, "", "Both", { isCooldown: true }),
  e("priest-disc", 20, "Power Word: Shield", 17, "", "Both"),
  e("priest-disc", 25, "Shadow Word: Pain", 589, "", "Both"),
  e("priest-disc", 28, "Purge the Wicked", 204197, "", "Both"),
  e("priest-disc", 30, "Mind Blast", 8092, "", "Both", { isCooldown: true }),
  e("priest-disc", 35, "Smite", 585, "", "Both"),
  e("priest-disc", 40, "Shadow Word: Death", 32379, "", "Both"),
];

const PRIEST_HOLY: AplEntry[] = [
  e("priest-holy", 1, "Silence", 15487, "", "Both", { isInterrupt: true }),
  e("priest-holy", 5, "Divine Hymn", 64843, "", "Both", { isCooldown: true, isOffensive: true }),
  e("priest-holy", 8, "Apotheosis", 200183, "", "Both", { isCooldown: true, isOffensive: true }),
  e("priest-holy", 10, "Halo", 120517, "", "Both", { isCooldown: true }),
  e("priest-holy", 12, "Holy Word: Salvation", 265202, "", "Both", { isCooldown: true }),
  e("priest-holy", 15, "Holy Word: Sanctify", 34861, "", "Both", { isCooldown: true }),
  e("priest-holy", 18, "Holy Word: Serenity", 2050, "", "Both", { isCooldown: true }),
  e("priest-holy", 20, "Prayer of Mending", 33076, "", "Both", { isCooldown: true }),
  e("priest-holy", 25, "Circle of Healing", 204883, "", "Both", { isCooldown: true }),
  e("priest-holy", 28, "Renew", 139, "", "Both"),
  e("priest-holy", 30, "Flash Heal", 2061, "", "Both"),
  e("priest-holy", 35, "Holy Fire", 14914, "", "Both"),
  e("priest-holy", 40, "Smite", 585, "", "Both"),
  e("priest-holy", 45, "Holy Nova", 132157, "", "AoE"),
];

const SHAMAN_RESTO: AplEntry[] = [
  e("shaman-resto", 1, "Wind Shear", 57994, "", "Both", { isInterrupt: true }),
  e("shaman-resto", 2, "Water Shield", 52127, "!buff.water_shield.up", "Both", { isPrecombat: true, precombatType: "state" }),
  e("shaman-resto", 5, "Spirit Link Totem", 98008, "", "Both", { isCooldown: true, isOffensive: true }),
  e("shaman-resto", 8, "Healing Tide Totem", 108280, "", "Both", { isCooldown: true, isOffensive: true }),
  e("shaman-resto", 10, "Ascendance", 114052, "", "Both", { isCooldown: true, isOffensive: true }),
  e("shaman-resto", 12, "Unleash Life", 73685, "", "Both", { isCooldown: true }),
  e("shaman-resto", 15, "Healing Rain", 73920, "", "Both"),
  e("shaman-resto", 18, "Riptide", 61295, "", "Both", { isCooldown: true }),
  e("shaman-resto", 20, "Earth Shield", 974, "", "Both"),
  e("shaman-resto", 22, "Healing Stream Totem", 5394, "", "Both", { isCooldown: true }),
  e("shaman-resto", 25, "Healing Wave", 77472, "", "Both"),
  e("shaman-resto", 28, "Healing Surge", 8004, "", "Both"),
  e("shaman-resto", 30, "Chain Heal", 1064, "", "Both"),
  e("shaman-resto", 35, "Flame Shock", 188389, "", "Both"),
  e("shaman-resto", 40, "Lightning Bolt", 188196, "", "Both"),
];

export const COMMUNITY_APLS: Record<string, AplEntry[]> = {
  "druid-balance": DRUID_BALANCE,
  "rogue-ass": ROGUE_ASS,
  "evoker-aug": EVOKER_AUG,
  "dk-blood": DK_BLOOD,
  "dh-vengeance": DH_VENGEANCE,
  "druid-guardian": DRUID_GUARDIAN,
  "monk-brew": MONK_BREW,
  "paladin-prot": PALADIN_PROT,
  "warrior-prot": WARRIOR_PROT,
  "druid-resto": DRUID_RESTO,
  "evoker-pres": EVOKER_PRES,
  "monk-mw": MONK_MW,
  "paladin-holy": PALADIN_HOLY,
  "priest-disc": PRIEST_DISC,
  "priest-holy": PRIEST_HOLY,
  "shaman-resto": SHAMAN_RESTO,
};

export function getCommunityApl(specId: string): AplEntry[] | null {
  return COMMUNITY_APLS[specId] ?? null;
}
