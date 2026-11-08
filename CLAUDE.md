# DMGAssist — project rules

A rotation-helper HUD for World of Warcraft, targeting **WoW Forever first** (Mainline client, "Camelot"
game type, build 1.60.x, interface 16001) and **Mainline/Midnight** second (12.1.x, interface 120105).
Plus `DMGAssist_Watchdog`, a standalone diagnostics addon.

## Layout

- `addons/<AddonName>/` — shipped addons, plain Lua 5.1. One folder = one addon = one zip.
- `tests/` — `wow_mock.lua` (fake client with secret values that error like the real one) + `test_*.lua`.
- `docs/reference/api-findings.md` — **verified** facts about the API. Read before touching game APIs; update when you learn something.
- `docs/findings/` — dated write-ups of in-game evidence (Watchdog exports) and audits.
- `legacy/` — the 2026 Replit generator project and the last shipped build (1.5.0.282). Reference only; never edit, never ship.
- `tools/decode-export.py` — decodes Watchdog export strings.
- `scripts/check.sh` (what CI runs), `scripts/package.sh` (zips into `dist/`), `scripts/fetch-ui-source.sh`.

## Non-negotiables

1. **Run `./scripts/check.sh` before every commit.** It must pass: `luac -p` on every file, luacheck clean, all tests green.
   (The last shipped legacy build failed `luac -p` — one bad line disabled every spec. See docs/findings.)
2. **Never guess an API.** Check `.libraries/wow-ui-source/{forever,live}` (run `scripts/fetch-ui-source.sh`),
   especially `Blizzard_APIDocumentationGenerated`. Use the `wow-addon-architect` agent for research.
   If only in-game evidence can settle it, say so and add it to the Watchdog probe.
3. **Secret values.** Any game API return goes through `U.Safe` / `U.IsSecret` before comparison, truthiness
   test, arithmetic, concatenation, `#`, indexing, table-key use, `tostring`/`tonumber`. A secret `false` is non-nil.
4. **Lua 5.1 traps:** no `goto`/`//`/bitwise operators; `local function` before use; no `...` in nested closures;
   `x and y or z` is wrong when `y` can be `false` (bit us once already — write an explicit `if`).
5. **Never register `COMBAT_LOG_EVENT_UNFILTERED`.** No `loadstring` in shipped code. No protected calls.
6. **Forever has Assisted Combat switched off** (`InterfaceOverrides.HasAssistedCombat() == false`). The engine
   must stand on readable inputs: `IsSpellUsable`, cooldown `isActive`/`isOnGCD`, proc glows, own casts,
   secondary resources, whitelisted auras. See api-findings §2.
7. Generated code, if any comes back, emits **data tables only**; logic lives in hand-written Lua with tests.
8. Every new behaviour gets a test in `tests/` using the mock; every new secret-sensitive path gets a
   restricted-mode test (`mock.restricted = true`).

## Getting evidence from the game

Player installs `DMGAssist_Watchdog`, plays, types `/reload`, then runs `tools/send-logs.py` (uploads the
SavedVariables + `Logs/taint.log` to branch `watchdog-logs`, folder `logs/<stamp>/`, and opens an issue labelled
`watchdog-log`) — or uploads `WTF/Account/<ACCOUNT>/SavedVariables/DMGAssist_Watchdog.lua` / pastes `/dmgw export`.
Write conclusions into `docs/findings/YYYY-MM-DD-<topic>.md` and fold confirmed facts into api-findings.
