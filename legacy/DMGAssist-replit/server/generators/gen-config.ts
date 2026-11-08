/**
 * @module generators/gen-config
 * @description
 * Generates **Config.lua** — per-spec default configuration, APL data tables, and spec detection.
 *
 * Produces: `Config.lua` in the addon ZIP
 *
 * Key subsystems:
 * - **CLF_DefaultConfig** — Baked-in defaults generated from admin dashboard settings
 * - **APL priority tables** — Ordered spell lists with compiled condition expressions
 * - **Variable compilation** — SimC `variable.*` operations compiled to Lua closures
 * - **Spec lookup** — Maps GetSpecializationInfo() to class/spec string keys
 *
 * @taint-solution Variable conditions are pre-compiled via conditionToLua() and
 * wrapped in safeLuaCondition() so all runtime evaluation uses detainted values.
 */

import type { Spec, AplEntry } from "@shared/schema";
import { ADDON_NAME, ADDON_VERSION, WOW_INTERFACE, escapeLuaStr, safeLuaCondition, generateSpecLookupEntries, type AddonData, type AllSpecsData } from "./shared";
import { conditionToLua } from "./transpiler";

function extractAuraNames(conditions: string[]): string[] {
  const names = new Set<string>();
  const patterns = [
    /\bbuff\.(\w+)\.\w+/g,
    /\bdebuff\.(\w+)\.\w+/g,
    /\bdot\.(\w+)\.\w+/g,
  ];
  const skipNames = new Set([
    "ca_inc", "eclipse_solar", "eclipse_lunar",
    "celestial_alignment", "incarnation",
  ]);
  for (const cond of conditions) {
    for (const pat of patterns) {
      pat.lastIndex = 0;
      let m: RegExpExecArray | null;
      while ((m = pat.exec(cond)) !== null) {
        const raw = m[1];
        if (!skipNames.has(raw)) {
          names.add(raw);
        }
      }
    }
  }
  return Array.from(names).sort();
}

function emitAuraNamesLua(conditions: string[], indent: string): string {
  const names = extractAuraNames(conditions);
  if (names.length === 0) return `${indent}_conditionAuraNames = {},`;
  const entries = names.map(n => `${indent}  "${escapeLuaStr(n)}",`).join("\n");
  return `${indent}_conditionAuraNames = {\n${entries}\n${indent}},`;
}

const RESOURCE_TO_POWER_TYPE: Record<string, number> = {
  "Mana": 0, "Rage": 1, "Focus": 2, "Energy": 3,
  "Combo Points": 4, "Runic Power": 6, "Soul Shards": 7,
  "Astral Power": 8, "Holy Power": 9, "Maelstrom": 11,
  "Chi": 12, "Insanity": 13, "Fury": 17, "Pain": 18,
  "Essence": 19,
};

const SECONDARY_POWER_TYPE: Record<string, number> = {
  "druid-feral": 4,
  "rogue-ass": 4,
  "rogue-out": 4,
  "rogue-sub": 4,
};

const KNOWN_RESOURCE_GAINS: Record<string, Record<string, number>> = {
  "Astral Power": {
    "wrath": 6, "starfire": 8, "moonfire": 2, "sunfire": 2,
    "stellar flare": 8, "new moon": 10, "half moon": 20, "full moon": 40,
    "fury of elune": 5, "wild mushroom": 20, "force of nature": 20,
  },
  "Rage": {
    "shield slam": 15, "thunder clap": 5, "devastate": 5,
    "bloodthirst": 8, "raging blow": 12, "whirlwind": 3,
    "charge": 20, "shield charge": 20,
    "marauder's rush": 10, "execute": 20,
  },
  "Runic Power": {
    "obliterate": 15, "howling blast": 10, "heart strike": 5,
    "festering strike": 10, "scourge strike": 10,
  },
  "Maelstrom": {
    "lightning bolt": 6, "chain lightning": 4, "lava burst": 10,
    "flame shock": 6, "frost shock": 6,
  },
  "Holy Power": {
    "crusader strike": 1, "judgment": 1, "blade of justice": 2,
    "hammer of wrath": 1, "wake of ashes": 3, "divine toll": 1,
  },
  "Chi": {
    "tiger palm": 2, "expel harm": 1, "chi burst": 1,
  },
  "Insanity": {
    "mind blast": 7, "shadow word: death": 15,
    "mind flay": 2, "mind spike": 4, "void bolt": 9,
    "vampiric touch": 5, "shadow word: pain": 3,
  },
  "Fury": {
    "demon's bite": 20, "immolation aura": 8, "felblade": 40,
  },
  "Soul Shards": {
    "drain soul": 1,
  },
  "Focus": {
    "steady shot": 10, "barbed shot": 20,
  },
  "Combo Points": {
    "mutilate": 2, "sinister strike": 1, "backstab": 1,
    "ambush": 2, "garrote": 1, "ghostly strike": 1,
    "shuriken storm": 1, "shadow strike": 2,
    "echoing reprimand": 2, "gloomblade": 1,
  },
  "Pain": {
    "fracture": 25, "shear": 10, "immolation aura": 5,
  },
};

function generateGainsLua(resource: string, indent: string = "  "): string {
  const gains = KNOWN_RESOURCE_GAINS[resource];
  if (!gains || Object.keys(gains).length === 0) return `${indent}knownResourceGains = {},`;
  const entries = Object.entries(gains)
    .map(([spell, gain]) => `${indent}  ["${spell}"] = ${gain},`)
    .join("\n");
  return `${indent}knownResourceGains = {\n${entries}\n${indent}},`;
}

function compileVarMap(variables: import("../simc-parser").SimcVariable[]): Map<string, string> {
  const seen = new Map<string, string>();
  if (!variables || variables.length === 0) return seen;

  for (const v of variables) {
    const compiledExpr = safeLuaCondition(conditionToLua(v.value));

    if (v.op === "setif") {
      const condExpr = v.condition ? safeLuaCondition(conditionToLua(v.condition)) : "true";
      const elseExpr = v.valueElse ? safeLuaCondition(conditionToLua(v.valueElse)) : (seen.get(v.name) || "0");
      seen.set(v.name, `(function() if ${condExpr} then return ${compiledExpr} else return ${elseExpr} end end)()`);
    } else if (v.op === "set" || !seen.has(v.name)) {
      seen.set(v.name, compiledExpr);
    } else if (v.op === "add") {
      const prev = seen.get(v.name)!;
      seen.set(v.name, `(${prev}) + (${compiledExpr})`);
    } else if (v.op === "sub") {
      const prev = seen.get(v.name)!;
      seen.set(v.name, `(${prev}) - (${compiledExpr})`);
    } else if (v.op === "min") {
      const prev = seen.get(v.name)!;
      seen.set(v.name, `math.min((${prev}), (${compiledExpr}))`);
    } else if (v.op === "max") {
      const prev = seen.get(v.name)!;
      seen.set(v.name, `math.max((${prev}), (${compiledExpr}))`);
    } else if (v.op === "reset") {
      const defaultExpr = v.default ? safeLuaCondition(conditionToLua(v.default)) : "0";
      seen.set(v.name, defaultExpr);
    }
  }
  return seen;
}

function varEntryLua(name: string, expr: string, indent: string): string {
  return `${indent}["${escapeLuaStr(name)}"] = function()\n${indent}  local v = ${expr}\n${indent}  if type(v) == "boolean" then return v and 1 or 0 end\n${indent}  return v or 0\n${indent}end`;
}

function compileVariablesToLua(variables: import("../simc-parser").SimcVariable[]): string {
  const seen = compileVarMap(variables);
  if (seen.size === 0) return "";
  const fns: string[] = [];
  for (const [name, expr] of seen) {
    fns.push(varEntryLua(name, expr, "  "));
  }
  return `CLF._varFns = {\n${fns.join(",\n")}\n}\n`;
}

function compileVariablesToLuaTable(variables: import("../simc-parser").SimcVariable[], indent: string): string {
  const seen = compileVarMap(variables);
  if (seen.size === 0) return "";
  const fns: string[] = [];
  for (const [name, expr] of seen) {
    fns.push(varEntryLua(name, expr, indent));
  }
  return `${indent.slice(6)}_varFns = {\n${fns.join(",\n")}\n${indent.slice(6)}},`;
}

export function generateConfig(data: AddonData): string {
  const { spec, aplEntries, hudConfig, alerts, variables, aplBranch, aplTier } = data;

  const aplLua = aplEntries
    .filter(e => e.enabled)
    .sort((a, b) => a.priority - b.priority)
    .map(e => {
      const rawCondLua = safeLuaCondition(conditionToLua(e.condition));
      const condLua = escapeLuaStr(rawCondLua);
      return `    {
      spellName = "${escapeLuaStr(e.spellName)}",
      spellIcon = "${escapeLuaStr(e.spellIcon)}",
      spellId = ${e.spellId || "nil"},
      priority = ${e.priority},
      mode = "${e.mode}",
      isInterrupt = ${e.isInterrupt},
      isCooldown = ${!!e.isCooldown},
      isOffensive = ${e.isOffensive},
      isPrecombat = ${!!e.isPrecombat},
      precombatType = ${e.precombatType ? `"${e.precombatType}"` : "nil"},
      keybind = "${escapeLuaStr(e.keybind)}",
      conditionFn = function() return ${rawCondLua} end,
      conditionSrc = "return ${condLua}",
      conditionText = "${escapeLuaStr(e.condition)}",
    }`;
    })
    .join(",\n");

  const alertsLua = alerts
    .filter(a => a.enabled)
    .map(a => `    {
      alertName = "${escapeLuaStr(a.alertName)}",
      source = "${a.source}",
      spellId = "${escapeLuaStr(a.spellId)}",
      interruptSpell = "${escapeLuaStr(a.interruptSpell)}",
      priority = "${a.priority}",
    }`)
    .join(",\n");

  return `-- Generated by DMGAssist Web Companion
-- Spec: ${spec.specName} ${spec.className}
-- Generated: ${new Date().toISOString()}

CLF_DefaultConfig = {
  spec = {
    id = "${escapeLuaStr(spec.id)}",
    className = "${escapeLuaStr(spec.className)}",
    specName = "${escapeLuaStr(spec.specName)}",
    role = "${spec.role}",
    resource = "${escapeLuaStr(spec.resource)}",
    powerTypeId = ${RESOURCE_TO_POWER_TYPE[spec.resource] ?? "nil"},
    secondaryPowerTypeId = ${SECONDARY_POWER_TYPE[spec.id] ?? "nil"},
    classColor = "${spec.classColor}",
    aplBranch = "${aplBranch || "fallback"}",
    aplTier = "${aplTier || "unknown"}",
  },

${generateGainsLua(spec.resource, "  ")}

  hud = {
    scale = ${hudConfig.scale},
    opacity = ${hudConfig.opacity},
    positionX = ${hudConfig.positionX},
    positionY = ${hudConfig.positionY},
    iconSize = ${hudConfig.iconSize},
    predIconSize = ${hudConfig.predIconSize ?? 34},
    queueSlots = ${hudConfig.queueSlots},
    showKeybind = ${hudConfig.showKeybind},
    keybindFontSize = ${hudConfig.keybindFontSize},
    keybindPosition = "${hudConfig.keybindPosition}",
    showSpellName = ${hudConfig.showSpellName},
    spellNameFontSize = ${hudConfig.spellNameFontSize},
    showCondition = ${hudConfig.showCondition},
    showResourceBar = ${hudConfig.showResourceBar},
    showHeader = ${hudConfig.showHeader ?? true},
    resourceCapThreshold = ${hudConfig.resourceCapThreshold},
    aoeThreshold = ${hudConfig.aoeThreshold},
    defaultModeDungeon = "${hudConfig.defaultModeDungeon ?? "AoE"}",
    defaultModeRaid = "${hudConfig.defaultModeRaid ?? "AoE"}",
    defaultModeDelve = "${hudConfig.defaultModeDelve ?? "AoE"}",
    defaultModeWorld = "${hudConfig.defaultModeWorld ?? "AoE"}",
    smartModeSwitch = ${hudConfig.smartModeSwitch ?? true},
    showPrediction = ${hudConfig.showPrediction},
    predictionOpacity = ${hudConfig.predictionOpacity},
    queueOpacity = ${hudConfig.queueOpacity ?? hudConfig.predictionOpacity ?? 0.6},
    framePadding = ${hudConfig.framePadding},
    iconSpacing = ${hudConfig.iconSpacing},
    minFrameWidth = ${hudConfig.minFrameWidth ?? 220},
    lockPosition = ${hudConfig.lockPosition},
    debugMode = ${hudConfig.debugMode},
    showCooldownText = ${hudConfig.showCooldownText},
    cooldownStyle = "${hudConfig.cooldownStyle ?? 'sweep'}",
    gcdIndicator = "${hudConfig.gcdIndicator ?? 'both'}",
    cdTextPosition = "${hudConfig.cdTextPosition ?? 'CENTER'}",
    cdTextSize = ${hudConfig.cdTextSize ?? 14},
    cdTextColor = "${hudConfig.cdTextColor ?? 'orange'}",
    cdTextOffsetX = ${hudConfig.cdTextOffsetX ?? 0},
    cdTextOffsetY = ${hudConfig.cdTextOffsetY ?? 0},
    showGcdSpark = ${hudConfig.showGcdSpark},
    outOfCombatMode = ${hudConfig.outOfCombatMode},
    hideOutOfCombat = false,
    interruptSound = ${hudConfig.interruptSound},
    interruptSoundId = ${hudConfig.interruptSoundId ?? 8959},
    stSwitchSound = ${hudConfig.stSwitchSound ?? true},
    stSwitchSoundId = ${hudConfig.stSwitchSoundId ?? 3175},
    aoeSwitchSound = ${hudConfig.aoeSwitchSound ?? true},
    aoeSwitchSoundId = ${hudConfig.aoeSwitchSoundId ?? 8458},
    keybindBarPriority = {${(hudConfig.keybindBarPriority || ["Main Action Bar", "Bottom Left", "Bottom Right", "Right Bar 1", "Right Bar 2"]).map(b => `"${escapeLuaStr(b)}"`).join(", ")}},
    keybindOverrides = {${Object.entries(hudConfig.keybindOverrides || {}).map(([spell, kb]) => `["${escapeLuaStr(spell)}"] = "${escapeLuaStr(kb)}"`).join(", ")}},
    formAwareness = ${hudConfig.formAwareness ?? true},
    combatRole = "${hudConfig.combatRole ?? "auto"}",
    showDefensives = ${hudConfig.showDefensives ?? false},
    showSelfHeals = ${hudConfig.showSelfHeals ?? false},
    consumablesEnabled = ${hudConfig.consumablesEnabled ?? true},
    flaskEnabled = ${hudConfig.flaskEnabled ?? true},
    foodEnabled = ${hudConfig.foodEnabled ?? true},
    weaponEnhEnabled = ${hudConfig.weaponEnhEnabled ?? true},
    augmentRuneEnabled = ${hudConfig.augmentRuneEnabled ?? true},
  },

  apl = {
${aplLua}
  },

  interrupts = {
${alertsLua}
  },

${emitAuraNamesLua(aplEntries.filter(e => e.enabled).map(e => e.condition), "  ")}
}

${compileVariablesToLua(variables || [])}`;
}

export function generateAllSpecsConfig(allData: AllSpecsData): string {
  const specEntries = allData.specs.map(data => {
    const { spec, aplEntries, hudConfig, alerts, variables, aplBranch, aplTier } = data;

    const aplLua = aplEntries
      .filter(e => e.enabled)
      .sort((a, b) => a.priority - b.priority)
      .map(e => {
        const rawCondLua = safeLuaCondition(conditionToLua(e.condition));
        const condLua = escapeLuaStr(rawCondLua);
        return `      {
        spellName = "${escapeLuaStr(e.spellName)}",
        spellIcon = "${escapeLuaStr(e.spellIcon)}",
        spellId = ${e.spellId || "nil"},
        priority = ${e.priority},
        mode = "${e.mode}",
        isInterrupt = ${e.isInterrupt},
        isCooldown = ${!!e.isCooldown},
        isOffensive = ${e.isOffensive},
          isPrecombat = ${!!e.isPrecombat},
        precombatType = ${e.precombatType ? `"${e.precombatType}"` : "nil"},
        keybind = "${escapeLuaStr(e.keybind)}",
        conditionFn = function() return ${rawCondLua} end,
        conditionSrc = "return ${condLua}",
        conditionText = "${escapeLuaStr(e.condition)}",
      }`;
      })
      .join(",\n");

    const alertsLua = alerts
      .filter(a => a.enabled)
      .map(a => `      {
        alertName = "${escapeLuaStr(a.alertName)}",
        source = "${a.source}",
        spellId = "${escapeLuaStr(a.spellId)}",
        interruptSpell = "${escapeLuaStr(a.interruptSpell)}",
        priority = "${a.priority}",
      }`)
      .join(",\n");

    const varFnsLua = compileVariablesToLuaTable(variables || [], "      ");

    return `  ["${escapeLuaStr(spec.id)}"] = {
    spec = {
      id = "${escapeLuaStr(spec.id)}",
      className = "${escapeLuaStr(spec.className)}",
      specName = "${escapeLuaStr(spec.specName)}",
      role = "${spec.role}",
      resource = "${escapeLuaStr(spec.resource)}",
      powerTypeId = ${RESOURCE_TO_POWER_TYPE[spec.resource] ?? "nil"},
      secondaryPowerTypeId = ${SECONDARY_POWER_TYPE[spec.id] ?? "nil"},
      classColor = "${spec.classColor}",
      aplBranch = "${aplBranch || "fallback"}",
      aplTier = "${aplTier || "unknown"}",
    },
${generateGainsLua(spec.resource, "    ")}
    hud = {
      scale = ${hudConfig.scale},
      opacity = ${hudConfig.opacity},
      positionX = ${hudConfig.positionX},
      positionY = ${hudConfig.positionY},
      iconSize = ${hudConfig.iconSize},
      predIconSize = ${hudConfig.predIconSize ?? 34},
      queueSlots = ${hudConfig.queueSlots},
      showKeybind = ${hudConfig.showKeybind},
      keybindFontSize = ${hudConfig.keybindFontSize},
      keybindPosition = "${hudConfig.keybindPosition}",
      showSpellName = ${hudConfig.showSpellName},
      spellNameFontSize = ${hudConfig.spellNameFontSize},
      showCondition = ${hudConfig.showCondition},
      showResourceBar = ${hudConfig.showResourceBar},
      showHeader = ${hudConfig.showHeader ?? true},
      resourceCapThreshold = ${hudConfig.resourceCapThreshold},
      aoeThreshold = ${hudConfig.aoeThreshold},
      defaultModeDungeon = "${hudConfig.defaultModeDungeon ?? "AoE"}",
      defaultModeRaid = "${hudConfig.defaultModeRaid ?? "AoE"}",
      defaultModeDelve = "${hudConfig.defaultModeDelve ?? "AoE"}",
      defaultModeWorld = "${hudConfig.defaultModeWorld ?? "AoE"}",
      showPrediction = ${hudConfig.showPrediction},
      predictionOpacity = ${hudConfig.predictionOpacity},
      queueOpacity = ${hudConfig.queueOpacity ?? hudConfig.predictionOpacity ?? 0.6},
      framePadding = ${hudConfig.framePadding},
      iconSpacing = ${hudConfig.iconSpacing},
      minFrameWidth = ${hudConfig.minFrameWidth ?? 220},
      lockPosition = ${hudConfig.lockPosition},
      debugMode = ${hudConfig.debugMode},
      showCooldownText = ${hudConfig.showCooldownText},
      cooldownStyle = "${hudConfig.cooldownStyle ?? 'sweep'}",
    gcdIndicator = "${hudConfig.gcdIndicator ?? 'both'}",
      cdTextPosition = "${hudConfig.cdTextPosition ?? 'CENTER'}",
      cdTextSize = ${hudConfig.cdTextSize ?? 14},
      cdTextColor = "${hudConfig.cdTextColor ?? 'orange'}",
      cdTextOffsetX = ${hudConfig.cdTextOffsetX ?? 0},
      cdTextOffsetY = ${hudConfig.cdTextOffsetY ?? 0},
      showGcdSpark = ${hudConfig.showGcdSpark},
      outOfCombatMode = ${hudConfig.outOfCombatMode},
      interruptSound = ${hudConfig.interruptSound},
      interruptSoundId = ${hudConfig.interruptSoundId ?? 8959},
      stSwitchSound = ${hudConfig.stSwitchSound ?? true},
      stSwitchSoundId = ${hudConfig.stSwitchSoundId ?? 3175},
      aoeSwitchSound = ${hudConfig.aoeSwitchSound ?? true},
      aoeSwitchSoundId = ${hudConfig.aoeSwitchSoundId ?? 8458},
      keybindBarPriority = {${(hudConfig.keybindBarPriority || ["Main Action Bar", "Bottom Left", "Bottom Right", "Right Bar 1", "Right Bar 2"]).map(b => `"${escapeLuaStr(b)}"`).join(", ")}},
      keybindOverrides = {${Object.entries(hudConfig.keybindOverrides || {}).map(([spell, kb]) => `["${escapeLuaStr(spell)}"] = "${escapeLuaStr(kb)}"`).join(", ")}},
      formAwareness = ${hudConfig.formAwareness ?? true},
      combatRole = "${hudConfig.combatRole ?? "auto"}",
      showDefensives = ${hudConfig.showDefensives ?? false},
      showSelfHeals = ${hudConfig.showSelfHeals ?? false},
      consumablesEnabled = ${hudConfig.consumablesEnabled ?? true},
      flaskEnabled = ${hudConfig.flaskEnabled ?? true},
      foodEnabled = ${hudConfig.foodEnabled ?? true},
      weaponEnhEnabled = ${hudConfig.weaponEnhEnabled ?? true},
      augmentRuneEnabled = ${hudConfig.augmentRuneEnabled ?? true},
    },
    apl = {
${aplLua}
    },
    interrupts = {
${alertsLua}
    },
${emitAuraNamesLua(aplEntries.filter(e => e.enabled).map(e => e.condition), "    ")}
${varFnsLua}
  }`;
  });

  return `-- Generated by DMGAssist Web Companion
-- All specs configuration (${allData.specs.length} specs)
-- Generated: ${new Date().toISOString()}

CLF_AllSpecs = {
${specEntries.join(",\n\n")}
}

-- Spec detection lookup: maps WoW className+specIndex to our specId
-- className is always the English class token (locale-independent)
-- specIndex is the fixed 1-based spec order per class (also locale-independent)
CLF_SpecLookup = {
${generateSpecLookupEntries(allData)}
}

-- Auto-detect function called from Core.lua
function CLF_DetectSpec()
  local _, rawClassName = UnitClass("player")
  local className = CLF.DetaintStr(rawClassName)
  if not className then return nil end
  local specIndex = CLF.Detaint(GetSpecialization())
  if not specIndex then return nil end
  local key = className .. "-" .. specIndex
  local specId = CLF_SpecLookup[key]
  if specId and CLF_AllSpecs[specId] then
    return CLF_AllSpecs[specId], specId
  end
  return nil
end

-- Initialize: pick the right spec config
CLF_DefaultConfig = nil
`;
}
