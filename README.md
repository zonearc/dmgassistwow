# dmgassistwow

A WoW damage-rotation addon that works for Midnight and Forever — rebuilt for the 12.x "secret values"
rules, with **WoW Forever** as the first target and Mainline (Midnight) second.

## Status

| Piece | State |
|---|---|
| `DMGAssist_Watchdog` (diagnostics + API probe) | **v0.1.0 — ready to test in game** |
| `DMGAssist` (rotation HUD) | Not started in this repo; waits on Watchdog evidence from Forever |
| Legacy generator (2026, Replit) and last shipped build 1.5.0.282 | Archived in `legacy/` for reference |

## Install the Watchdog

1. Download `DMGAssist_Watchdog-<version>.zip` from the latest CI run (Actions → artifacts), or run `./scripts/package.sh`.
2. Unzip into `World of Warcraft/_retail_/Interface/AddOns/` (and/or the Forever install's `Interface/AddOns/`).
3. Log in. It records automatically: Lua errors (with stacks), blocked/forbidden actions, every combat as a
   session (your casts, proc glows, restriction changes), and two API probes per login (one out of combat,
   one a few seconds into your first fight).

## What to do in game (first test)

Midnight (retail) is the main test bed: the secret-value rules are identical to Forever (verified in Blizzard's
API docs), and a max-level character gives the probe a full spellbook. Forever only needs a short visit on any
character to confirm the Forever-only switches (Assisted Combat off, restriction CVars).


1. Log in, wait ~10 seconds, then `/dmgw` — check the summary shows a probe.
2. Run `/dmgw force on`, then `/dmgw probe`, then `/dmgw force off`
   (tests whether the client can fake combat restrictions — if it says the setting doesn't exist, that's an answer too).
3. Fight something for 15+ seconds (a training dummy is perfect). Do it twice.
4. `/reload`, then send `WTF/Account/<ACCOUNT>/SavedVariables/DMGAssist_Watchdog.lua`.
   No file access? `/dmgw export`, Ctrl+C, paste.

Commands: `/dmgw` · `/dmgw probe` · `/dmgw export [last]` · `/dmgw status` · `/dmgw force on|off` · `/dmgw clear`

## Development

```
./scripts/fetch-ui-source.sh   # Blizzard UI source (forever + live) into .libraries/
./scripts/check.sh             # luac -p, luacheck, tests — required before every commit
./scripts/package.sh           # zips into dist/
python3 tools/decode-export.py export.txt
```

Needs Lua 5.1 (`lua5.1`, `luac5.1`) and `luacheck`. Project rules: [CONTRIBUTING.md](CONTRIBUTING.md).
Verified API facts: [docs/reference/api-findings.md](docs/reference/api-findings.md).

## Using DMGAssist

Shows the next three spells (large icon = press this when your global cooldown ends) and, below, the next major
cooldown. Visible in combat or with an enemy targeted. The small text above says the target mode.
Letters on an icon say where a pick came from: none = SimC, `AC` = Blizzard's Assisted Combat, `B` = Blizzard's
rules evaluated by DMGAssist (Forever), `?` = best guess.

**Single target / AoE.** Set your primary mode (`/dmga mode st` or `aoe`). With auto-detect on (default),
DMGAssist counts enemies in combat from their nameplates and switches by itself (`AUTO 4`); when it can't count
(nameplates hidden), it uses your primary mode and shows `ST?` / `AOE?`. Bind a key under
Key Bindings → AddOns → DMGAssist → "Switch target mode" to cycle Auto → Single → AoE mid-fight.

| Command | |
|---|---|
| `/dmga` | status: client, spec, data version, spells matched |
| `/dmga on` / `off` | show or hide (also a key binding) |
| `/dmga burst` | major cooldowns on/off (also a key binding) |
| `/dmga mode st` / `aoe` | primary target mode; `/dmga mode` alone cycles like the key |
| `/dmga auto on` / `off` | auto-detect targets from nameplates |
| `/dmga targets 4` | targets assumed in AoE mode |
| `/dmga fight 180` | assumed fight length in seconds |
| `/dmga queue 1`–`3` | how many upcoming spells to show |
| `/dmga lock` | lock/unlock the icons (drag to move) |
| `/dmga why` | the queue, where it came from, and list spells you don't have |

Languages: English, Español, Deutsch, Français, Português, Русский, 简体中文, 繁體中文, 한국어. Spell matching uses spell
IDs, so it works on every client language; only messages are translated.

With DMGAssist_Watchdog installed, every pick change (with the queue and mode), inferred cast and per-fight tracking
summary is logged for diagnosis.

## Automation (GitHub Actions)

| Workflow | When | What |
|---|---|---|
| `ci.yml` | every push / PR | `scripts/check.sh` + build zips as an artifact |
| `simc-sync.yml` | Wednesdays 15:17 UTC, or manual | pull SimC `midnight` + `forever`, regenerate `addons/DMGAssist/Data`, run checks, open a PR |
| `api-watch.yml` | Wednesdays 16:41 UTC, or manual | re-read Blizzard's API docs for `tools/api-watchlist.txt`, open a PR if anything changed |
| `release.yml` | push a tag `vX.Y.Z` | verify versions, build, GitHub Release; CurseForge upload only if enabled |

One-time repo settings:
- Settings → Actions → General → "Allow GitHub Actions to create and approve pull requests" (for the two sync PRs).
- Secret `CF_API_TOKEN` (CurseForge API token) and variable `CURSEFORGE_PUBLISH=true` to enable uploads.
- Scheduled workflows only run from the default branch.

Release: `scripts/bump-version.sh 0.2.0`, commit, `git tag v0.2.0`, push the tag.
