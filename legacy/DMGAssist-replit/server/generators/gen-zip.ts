/**
 * @module generators/gen-zip
 * @description
 * ZIP archive packagers that assemble all generated Lua files into distributable addon packages.
 *
 * Produces: Complete `.zip` files ready for CurseForge upload or direct download
 *
 * Two entry points:
 * - {@link generateAllSpecsAddonZip} — Full addon with all specs (used by sync engine)
 * - {@link generateAddonZip} — Single-spec addon (used for testing/preview)
 *
 * Both call every gen-*.ts generator, collect the output, and pack into a ZIP
 * with the correct directory structure (`DMGAssist/`).
 */

import archiver from "archiver";
import type { PassThrough } from "stream";
import fs from "fs";
import path from "path";
import { ADDON_NAME, ADDON_VERSION, type AddonData, type AllSpecsData } from "./shared";


import { generateToc, generateBindingNames, generateBindingsXml, generateAllSpecsToc } from "./gen-toc";
import { generateLocales } from "./gen-locales";
import { generateLibStub } from "./gen-lib";
import { generateConfig, generateAllSpecsConfig } from "./gen-config";
import { generateHelpers } from "./gen-helpers";
import { generateEngine } from "./gen-engine";
import { generateHud } from "./gen-hud";
import { generateCore } from "./gen-core";
import { generateSettingsPanel } from "./gen-settings";
import { generateWatchdogLua } from "./gen-watchdog";

export function generateAllSpecsAddonZip(allData: AllSpecsData, onProgress?: (current: number, total: number, specName: string) => void): archiver.Archiver {
  const archive = archiver("zip", { zlib: { level: 9 } });

  archive.on("warning", (err: any) => {
    if (err.code !== "ENOENT") throw err;
  });

  const dir = ADDON_NAME;
  const firstSpec = allData.specs[0];

  archive.append(generateAllSpecsToc(allData), { name: `${dir}/${ADDON_NAME}.toc` });
  archive.append(generateBindingNames(), { name: `${dir}/BindingNames.lua` });
  archive.append(generateBindingsXml(), { name: `${dir}/Bindings.xml` });
  archive.append(generateLibStub(), { name: `${dir}/Libs/LibStub.lua` });
  archive.append(generateLocales(), { name: `${dir}/Locales.lua` });

  if (onProgress) onProgress(0, allData.specs.length, "Building config...");
  archive.append(generateAllSpecsConfig(allData), { name: `${dir}/Config.lua` });

  archive.append(generateHelpers(firstSpec), { name: `${dir}/Helpers.lua` });
  archive.append(generateEngine(firstSpec), { name: `${dir}/Engine.lua` });
  archive.append(generateHud(firstSpec), { name: `${dir}/HUD.lua` });
  archive.append(generateSettingsPanel(), { name: `${dir}/Settings.lua` });
  archive.append(generateCore(firstSpec), { name: `${dir}/Core.lua` });
  archive.append(generateWatchdogLua(), { name: `${dir}/Watchdog.lua` });

  const specList = allData.specs.map(d => `- ${d.spec.specName} ${d.spec.className} (${d.spec.role})`).join("\n");

  archive.append(`# DMGAssist v${ADDON_VERSION}

SimC-powered rotation HUD for WoW Midnight 12.0. Three signal sources (Assisted Highlights + proc glows + spell readiness) ranked by SimC priority into a Guitar Hero-style spell queue.

---

## Quick Start

1. Extract ZIP → \`Interface/AddOns/DMGAssist/\`
2. Log in → addon auto-detects your spec
3. HUD appears center-screen — drag to reposition, press keybinds shown

**Diagnostic Logging (built-in):** Enable via Options → Issues tab → "Enable Diagnostic Logging" checkbox. When enabled, captures combat events, queue snapshots, and system health data. Use \`/dmgawd\` to open the Event Viewer. Use "Select All" to copy the full log for sharing.

---

## Minimap Icon

| Action | Result |
|--------|--------|
| **Left-click** | Toggle HUD on/off |
| **Right-click** | Options dropdown (mode, lock, OOC hide, reset) |
| **Drag** | Move icon around minimap |

---

## HUD Controls

| Element | Action |
|---------|--------|
| **Unlocked HUD** | Left-drag to move HUD |
| **Unlocked HUD** right-click | Lock position |
| **Gear icon** (top-right) | Open full Options panel |

---

## Slash Commands

\`/dmga\` or \`/dmgassist\` — show help

### Core
| Command | What it does |
|---------|-------------|
| \`/dmga options\` | Open Options panel |
| \`/dmga show\` | Show HUD |
| \`/dmga hide\` | Hide HUD |
| \`/dmga toggle\` | Toggle HUD |
| \`/dmga lock\` | Lock position |
| \`/dmga unlock\` | Unlock position |
| \`/dmga ooc\` | Toggle auto-hide out of combat |

### Mode
| Command | What it does |
|---------|-------------|
| \`/dmga mode\` | Cycle ST → AoE → Auto |
| \`/dmga mode st\` | Force Single Target |
| \`/dmga mode aoe\` | Force AoE |
| \`/dmga mode auto\` | Auto-detect via nameplates |

### Diagnostics
| Command | What it does |
|---------|-------------|
| \`/dmga status\` | Current spec, mode, icon size, toggles |
| \`/dmga spells\` | Which APL spells are known vs filtered |
| \`/dmga trinkets\` | Equipped trinkets + cooldown status |
| \`/dmga glows\` | Check glow/overlay CVar health |
| \`/dmga fixglows\` | Auto-fix overlay CVars |
| \`/dmga debug\` | Toggle debug logging |
| \`/dmga debug verbose\` | Full condition evaluation logging |
| \`/dmga debug off\` | Disable debug |
| \`/dmga reset\` | Factory reset (reloads UI) |

---

## Options Panel

Open via: gear icon on HUD, right-click minimap → Open Options, or \`/dmga options\`

**General** — icon sizes (primary + next), queue slots, scale, opacity, padding/spacing, frame lock, OOC mode, header visibility

**Display** — keybind text (font size, position, color), spell names, cooldown text, GCD spark, resource bar + cap threshold, condition text, prediction icons + opacity

**Combat** — AoE threshold, interrupt sound, form awareness, trinket tracking

**Sounds** — configurable sound alerts for interrupts, ST/AoE mode switches

**Buffs** — consumable buff alerts (flask, food, weapon enhancement, augment rune)

**Issues** — live diagnostic: spec detection, APL status, glow health, runtime errors, condition errors. Auto-Fix Glows button.

---

## Supported Specs (${allData.specs.length})
${specList}

Generated: ${new Date().toISOString()}
`, { name: `${dir}/README.md` });

  return archive;
}

export function generateAddonZip(data: AddonData): archiver.Archiver {
  const archive = archiver("zip", { zlib: { level: 9 } });

  archive.on("warning", (err: any) => {
    if (err.code !== "ENOENT") throw err;
  });

  const dir = ADDON_NAME;

  archive.append(generateToc(data), { name: `${dir}/${ADDON_NAME}.toc` });
  archive.append(generateBindingNames(), { name: `${dir}/BindingNames.lua` });
  archive.append(generateBindingsXml(), { name: `${dir}/Bindings.xml` });
  archive.append(generateLibStub(), { name: `${dir}/Libs/LibStub.lua` });
  archive.append(generateLocales(), { name: `${dir}/Locales.lua` });
  archive.append(generateConfig(data), { name: `${dir}/Config.lua` });
  archive.append(generateHelpers(data), { name: `${dir}/Helpers.lua` });
  archive.append(generateEngine(data), { name: `${dir}/Engine.lua` });
  archive.append(generateHud(data), { name: `${dir}/HUD.lua` });
  archive.append(generateSettingsPanel(), { name: `${dir}/Settings.lua` });
  archive.append(generateCore(data), { name: `${dir}/Core.lua` });
  archive.append(generateWatchdogLua(), { name: `${dir}/Watchdog.lua` });

  archive.append(`# DMGAssist v${ADDON_VERSION}

SimC-powered rotation HUD for WoW Midnight 12.0. Three signal sources (Assisted Highlights + proc glows + spell readiness) ranked by SimC priority into a Guitar Hero-style spell queue.

---

## Quick Start

1. Extract ZIP → \`Interface/AddOns/DMGAssist/\`
2. Log in → addon auto-detects your spec
3. HUD appears center-screen — drag to reposition, press keybinds shown

---

## Minimap Icon

| Action | Result |
|--------|--------|
| **Left-click** | Toggle HUD on/off |
| **Right-click** | Options dropdown (mode, lock, OOC hide, reset) |
| **Drag** | Move icon around minimap |

---

## HUD Controls

| Element | Action |
|---------|--------|
| **Unlocked HUD** | Left-drag to move HUD |
| **Unlocked HUD** right-click | Lock position |
| **Gear icon** (top-right) | Open full Options panel |

---

## Slash Commands

\`/dmga\` or \`/dmgassist\` — show help

### Core
| Command | What it does |
|---------|-------------|
| \`/dmga options\` | Open Options panel |
| \`/dmga show\` | Show HUD |
| \`/dmga hide\` | Hide HUD |
| \`/dmga toggle\` | Toggle HUD |
| \`/dmga lock\` | Lock position |
| \`/dmga unlock\` | Unlock position |
| \`/dmga ooc\` | Toggle auto-hide out of combat |

### Mode
| Command | What it does |
|---------|-------------|
| \`/dmga mode\` | Cycle ST → AoE → Auto |
| \`/dmga mode st\` | Force Single Target |
| \`/dmga mode aoe\` | Force AoE |
| \`/dmga mode auto\` | Auto-detect via nameplates |

### Diagnostics
| Command | What it does |
|---------|-------------|
| \`/dmga status\` | Current spec, mode, icon size, toggles |
| \`/dmga spells\` | Which APL spells are known vs filtered |
| \`/dmga trinkets\` | Equipped trinkets + cooldown status |
| \`/dmga glows\` | Check glow/overlay CVar health |
| \`/dmga fixglows\` | Auto-fix overlay CVars |
| \`/dmga debug\` | Toggle debug logging |
| \`/dmga debug verbose\` | Full condition evaluation logging |
| \`/dmga debug off\` | Disable debug |
| \`/dmga reset\` | Factory reset (reloads UI) |

---

## Options Panel

Open via: gear icon on HUD, right-click minimap → Open Options, or \`/dmga options\`

**General** — icon sizes (primary + next), queue slots, scale, opacity, padding/spacing, frame lock, OOC mode, header visibility

**Display** — keybind text (font size, position, color), spell names, cooldown text, GCD spark, resource bar + cap threshold, condition text, prediction icons + opacity

**Combat** — AoE threshold, interrupt sound, form awareness, trinket tracking

**Sounds** — configurable sound alerts for interrupts, ST/AoE mode switches

**Buffs** — consumable buff alerts (flask, food, weapon enhancement, augment rune)

**Issues** — live diagnostic: spec detection, APL status, glow health, runtime errors, condition errors. Auto-Fix Glows button.

---

## Spec: ${data.spec.specName} ${data.spec.className}
- Role: ${data.spec.role}
- Resource: ${data.spec.resource}
- Rotation spells ranked: ${data.aplEntries.filter(e => e.enabled && !e.isInterrupt).length}
- Interrupt rules: ${data.alerts.filter(a => a.enabled).length}

Generated: ${new Date().toISOString()}
`, { name: `${dir}/README.md` });

  return archive;
}
