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

Needs Lua 5.1 (`lua5.1`, `luac5.1`) and `luacheck`. Project rules: [CLAUDE.md](CLAUDE.md).
Verified API facts: [docs/reference/api-findings.md](docs/reference/api-findings.md).

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
