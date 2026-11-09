# Contributing to DMGAssist

A rotation-helper HUD for World of Warcraft, targeting **WoW Forever** (Mainline client, "Camelot" game type,
build 1.60.x, interface 16001) and **Midnight** (12.1.x, interface 120105). Plus `DMGAssist_Watchdog`, a standalone
diagnostics addon.

## Layout

| Path | What |
|---|---|
| `addons/<AddonName>/` | Shipped addons, plain Lua 5.1. One folder = one addon = one zip. |
| `addons/DMGAssist/Data/` | Generated data tables (never edit by hand; `tools/simc_import.py`). |
| `tests/` | `wow_mock.lua` (a fake client whose secret values error like the real ones) and `test_*.lua` / `test_*.py`. |
| `tools/` | Importers (`simc_import.py`, `simc_spells.py`, `gamedata_spells.py`, `wowsims_apl.py`), `send-logs.py`, `decode-export.py`, `api_snapshot.lua`. |
| `scripts/` | `check.sh` (everything CI runs), `package.sh` (zips into `dist/`), `fetch-*.sh` (sources into `.libraries/`). |
| `docs/project/` | `tasks.md` (the working task list, kept current with every change) and `scope.md` (what's in and out, decisions). |
| `docs/reference/api-findings.md` | **Verified** facts about the game API. Read before touching game APIs; update when you learn something. |
| `docs/design/` | How the engine decides (`engine-priority.md`) and what's next (`gap-analysis.md`). |
| `docs/findings/` | Dated write-ups of in-game evidence (Watchdog logs) and audits. |
| `legacy/` | The previous generator project and its last shipped build (1.5.0.282). Reference only; never edit, never ship. |

## How DMGAssist is put together (load order = TOC order)

| Module | Local name | Job |
|---|---|---|
| `Core/Util.lua` | `U` | Secret-safe helpers every module uses: `U.Get` (call an API, nil if secret/failed), `U.Read`, `U.IsSecret`, `U.Safe`, `U.Call`, `U.Log`, `U.Print`. |
| `Core/Locales.lua` | `L` | Player-facing text in 9 languages; keys are the English text. |
| `Core/Client.lua`, `Core/Data.lua`, `Core/Specs.lua` | `C`, `D`, `S` | Which game, which data, which spec (re-detected on every spec/talent event). |
| `Core/Expr.lua` | `E` | Priority-list conditions: parser and three-valued evaluator (true / false / UNKNOWN) with value ranges. |
| `Core/SpellMap.lua` | `M` | List names ↔ the player's spell IDs and talents (by ID, any language; highest rank known). |
| `Core/State.lua` | `S` | Everything about "now" (and a predicted moment ahead): resources, cooldowns, auras, timers we run ourselves. |
| `Core/Clues.lua` | `C` | Facts inferred from what the game still shows in combat, each graded against the truth. |
| `Core/BossMods.lua`, `Core/Interrupts.lua`, `Core/Defensives.lua`, `Core/Sounds.lua` | `B`, `I`, `F`, `S` | Boss-mod timers, interrupt and defensive advice, audio alerts. |
| `Core/Diagnostics.lua` | `G` | Readability and range logging for the Watchdog. |
| `Core/Engine.lua` | `G` | Walks the priority list and builds the queue. |
| `Core/Display.lua`, `Core/Options.lua` | `D`, `O` | The HUD and the settings panel. |
| `Core/Minimap.lua` | `MM` | Minimap button and the addon compartment entry. |
| `Core/Main.lua` | — | Events, the update loop, slash commands, key bindings. |

Conventions:
- Each file starts with a comment saying what it does and which game APIs it relies on (with where they were verified).
- One module table per file, kept in `ns` (`ns.State`, …) and aliased to a short local at the top of the file.
- Public functions are `Module.PascalCase`; locals are `camelCase`; constants `UPPER_CASE`.
- Every game call goes through `U.Get` / `U.Call`, never a bare call whose result is compared.

## Non-negotiables

1. **Run `./scripts/check.sh` before every commit.** It must pass: `luac -p` on every file, luacheck clean, all tests
   green (including the fuzz test over every spec on both clients).
2. **Never guess an API.** Check Blizzard's UI source (`scripts/fetch-ui-source.sh` →
   `.libraries/wow-ui-source/{forever,live}`), especially `Blizzard_APIDocumentationGenerated`. If only in-game
   evidence can settle it, say so and add it to the Watchdog probe.
3. **Secret values.** Any game API return goes through `U.Get` / `U.Read` / `U.IsSecret` before comparison,
   truthiness test, arithmetic, concatenation, `#`, indexing, table-key use, `tostring`/`tonumber`. A secret `false`
   is non-nil.
4. **Lua 5.1 traps:** no `goto`/`//`/bitwise operators; `local function` before use; no `...` in nested closures;
   `x and y or z` is wrong when `y` can be `false` — write an explicit `if`.
5. **Never register `COMBAT_LOG_EVENT_UNFILTERED`.** No `loadstring` in shipped code. No protected calls.
6. **Forever has Assisted Combat switched off.** The engine must stand on readable inputs (see api-findings §2).
7. Generated code emits **data tables only**; logic lives in hand-written Lua with tests.
8. Every new behaviour gets a test in `tests/`; every secret-sensitive path gets a restricted-mode test
   (`mock.restricted = true`).

## Sources and credits

- Midnight priority lists and spell data: [SimulationCraft](https://github.com/simulationcraft/simc) (GPL-3.0; we
  import its generated lists as data).
- Forever rotations and spell data: [WoWSims](https://wowsims.com/forever) —
  [wowsims/forever](https://github.com/wowsims/forever) and [wowsims/gamedata](https://github.com/wowsims/gamedata)
  (MIT). Credited in the addon wherever a WoWSims list is used.
- Lua 5.1 reference: <https://www.lua.org/manual/5.1/>.

## Getting evidence from the game

See [TESTING.md](TESTING.md): play with the Watchdog installed, `/dmgw`, copy the report (decode it with
`tools/decode-export.py`), or `tools/send-logs.py` for the saved files. Write conclusions into `docs/findings/YYYY-MM-DD-<topic>.md` and
fold confirmed facts into api-findings.
