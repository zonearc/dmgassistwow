/**
 * @module addon-generator
 * @description
 * **WoW Addon Code Generator — The Heart of DMGAssist**
 *
 * This module is a compile-time code generator that transforms admin-configured
 * spec data (APL priorities, HUD settings, combat alerts) into a distributable
 * World of Warcraft addon ZIP file. It does NOT run inside WoW — it produces the
 * Lua source files that do.
 *
 * ## Architecture Overview
 *
 * ```
 * ┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
 * │  Admin Dashboard │────▶│  Sync Engine      │────▶│  This Generator  │
 * │  (APL / HUD cfg) │     │  (weekly scheduler)│     │  (TS → Lua emit) │
 * └─────────────────┘     └──────────────────┘     └────────┬────────┘
 *                                                           │
 *                                                    ┌──────▼──────┐
 *                                                    │  .zip file   │
 *                                                    │  (addon pkg) │
 *                                                    └──────┬──────┘
 *                                                           │
 *                                               ┌───────────▼──────────┐
 *                                               │  CurseForge Upload   │
 *                                               │  + Direct Download   │
 *                                               └──────────────────────┘
 * ```
 *
 * ## Generated Addon File Structure
 *
 * Each ZIP contains a `DMGAssist/` folder with these files, loaded in order:
 *
 * | File           | Purpose                                                    |
 * |----------------|------------------------------------------------------------|
 * | DMGAssist.toc  | WoW table of contents — metadata, SavedVariables, load order |
 * | Libs/LibStub.lua | Minimal library stub for future lib integration           |
 * | Helpers.lua    | Detaint wrappers, API compat shims, snapshot cache, aura/CD |
 * | Config.lua     | Per-spec default config, APL data tables, spec detection   |
 * | Engine.lua     | Action bar scanner, multi-signal scorer, APL evaluator     |
 * | HUD.lua        | Guitar Hero-style spell queue UI, glow frames, drag system |
 * | Settings.lua   | In-game settings panel (sliders, checkboxes, profiles)     |
 * | Core.lua       | Event handler, combat loop, boss mod integration, init     |
 *
 * ## Module Structure
 *
 * This file re-exports from `server/generators/*`:
 * - `shared.ts`       — Types, constants, version management, Lua utilities
 * - `transpiler.ts`   — SimC APL condition → Lua transpiler
 * - `gen-toc.ts`      — TOC files, Bindings.xml, BindingNames.lua
 * - `gen-lib.ts`      — LibStub.lua
 * - `gen-locales.ts`  — Locales.lua (enUS)
 * - `gen-config.ts`   — Config.lua, variable compilation
 * - `gen-helpers.ts`  — Helpers.lua (detaint, shims, snapshot, aura/CD)
 * - `gen-engine.ts`   — Engine.lua (scanner, scorer, APL evaluator)
 * - `gen-hud.ts`      — HUD.lua (spell queue UI)
 * - `gen-core.ts`     — Core.lua (event loop, combat, boss mods, init)
 * - `gen-settings.ts` — Settings.lua (options panel)
 * - `gen-watchdog.ts` — Watchdog addon (diagnostic overlay)
 * - `gen-zip.ts`      — ZIP archive packagers
 *
 * @see {@link generateAllSpecsAddonZip} — Main entry point for full addon generation
 * @see {@link generateAddonZip} — Single-spec addon generation (for testing)
 */

export { setAddonVersion, getAddonVersion, type AllSpecsData, type AddonData } from "./generators/shared";
export { conditionToLua } from "./generators/transpiler";
export { generateToc, generateBindingNames, generateBindingsXml, generateAllSpecsToc } from "./generators/gen-toc";
export { generateLibStub } from "./generators/gen-lib";
export { generateLocales } from "./generators/gen-locales";
export { generateConfig, generateAllSpecsConfig } from "./generators/gen-config";
export { generateHelpers } from "./generators/gen-helpers";
export { generateEngine } from "./generators/gen-engine";
export { generateHud } from "./generators/gen-hud";
export { generateCore } from "./generators/gen-core";
export { generateSettingsPanel } from "./generators/gen-settings";
export { generateWatchdogLua } from "./generators/gen-watchdog";
export { generateAllSpecsAddonZip, generateAddonZip } from "./generators/gen-zip";
