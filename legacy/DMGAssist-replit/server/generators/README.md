# DMGAssist Addon Generator — Architecture Guide

## Overview

The `server/generators/` directory contains the code generation engine that transforms
admin-configured spec data into a distributable World of Warcraft addon. These TypeScript
modules emit Lua source files that run inside WoW.

## Module Map

```
addon-generator.ts          ← Slim re-exporter (public API surface)
  └── generators/
      ├── shared.ts          ← Types, constants, version mgmt, Lua utilities
      ├── transpiler.ts      ← SimC APL condition → Lua transpiler
      ├── gen-toc.ts         ← .toc files, Bindings.xml, BindingNames.lua
      ├── gen-lib.ts         ← LibStub.lua shim
      ├── gen-locales.ts     ← Locales/enUS.lua string tables
      ├── gen-config.ts      ← Config.lua (defaults, APL tables, variables)
      ├── gen-helpers.ts     ← Helpers.lua (detaint, shims, snapshot, aura/CD)
      ├── gen-engine.ts      ← Engine.lua (action bar scanner, scorer, APL eval)
      ├── gen-hud.ts         ← HUD.lua (Guitar Hero spell queue UI)
      ├── gen-core.ts        ← Core.lua (event loop, combat, boss mods, init)
      ├── gen-settings.ts    ← Settings.lua (in-game options panel)
      ├── gen-watchdog.ts    ← DMGAssist_Watchdog companion addon
      └── gen-zip.ts         ← ZIP archive packagers
```

## Generated Addon Load Order

WoW loads files in the order listed in the .toc:

1. **Libs/LibStub.lua** — Library management shim
2. **Locales/enUS.lua** — Localized strings
3. **BindingNames.lua** — Keybinding display names
4. **Helpers.lua** — Detaint wrappers, API shims, snapshot cache
5. **Config.lua** — Baked-in defaults, APL priority tables
6. **Engine.lua** — Action bar scanning, multi-signal scoring
7. **HUD.lua** — Visual spell queue display
8. **Settings.lua** — Options panel UI
9. **Core.lua** — Event handler, combat loop, initialization

## Key Design Patterns

### Detaint Pattern (@taint-solution)

WoW 12.0 (Midnight) marks many API returns as "secret values". Any operation
on a secret value (comparison, concatenation, arithmetic) crashes the client.

All API returns pass through one of three detaint functions:
- `Detaint(val)` — for numbers (returns nil if secret)
- `DetaintStr(val)` — for strings (returns nil if secret)  
- `DetaintBool(val)` — for booleans (returns false if secret)

Each uses `issecretvalue()` to check before processing.

Search for `@taint-solution` tags to find all taint workaround code.

### Snapshot Cache (@secret-safe)

`CLF.RefreshSnapshot()` in Helpers.lua samples all game state once per tick
into `CLF._snap`. Downstream code reads detainted values from the snapshot,
never calling tainted APIs directly.

Search for `@secret-safe` tags to find code verified as taint-free.

### CLEU Tracking (@cleu-tracking)

Combat Log Event Unfiltered (CLEU) handlers track state changes that cannot
be polled safely (auras, casts, health changes). These fire on the
`COMBAT_LOG_EVENT_UNFILTERED` event and update internal state tables.

Search for `@cleu-tracking` tags to find CLEU-based state management.

### Variable Compilation

SimC `variable.X.op=set/add/sub/min/max/reset/setif` operations are compiled
into Lua closures at build time. The `compileVarMap()` function in gen-config.ts
processes variable chains and emits `CLF._varFns` table entries.

## Cross-File Dependencies

```
Helpers.lua
  ├── CLF._snap (snapshot cache, read by Engine + HUD + Core)
  ├── CLF.BuffUp/Down/Stacks (read by transpiled APL conditions)
  ├── CLF.CooldownReady/Remains (read by transpiled APL conditions)
  ├── CLF.Power/PowerMax (read by transpiled APL conditions)
  └── CLF.Detaint/DetaintStr/DetaintBool (used everywhere)

Config.lua
  ├── CLF_DefaultConfig (read by Core.lua on first load)
  └── CLF._specAPL[specKey] (read by Engine.lua)

Engine.lua
  ├── CLF._actionBarSlots (scanned on init, read by scorer)
  └── CLF._topSpells (output of APL evaluation, read by HUD)

HUD.lua
  └── Reads CLF._topSpells to display spell queue

Core.lua
  ├── Calls CLF.RefreshSnapshot() each tick
  ├── Calls Engine evaluation each tick during combat
  └── Routes CLEU sub-events to Helpers.lua handlers
```

## Debugging Guide

1. **Taint crash** — Search `@taint-solution` for known patterns. Check if a
   new API return needs detaint wrapping.

2. **Spell not showing** — Check Engine.lua's action bar scanner (gen-engine.ts)
   and the APL condition transpiler (transpiler.ts).

3. **Wrong priority** — Check the APL table in Config.lua (gen-config.ts) and
   the scoring weights in Engine.lua.

4. **Settings not saving** — Check SavedVariables in the .toc (gen-toc.ts) and
   the profile system in Settings.lua (gen-settings.ts).

5. **Watchdog not logging** — Check the event routing in Core.lua (gen-core.ts)
   that calls `CLF.WD_Log()`.
