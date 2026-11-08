# Testing DMGAssist (test builds)

Test builds have **testing mode on**: the Watchdog turns on the game's taint log at login, records the full launch
state (client, every addon and version, CVars, restrictions, load order), keeps more events per fight, and DMGAssist
stores a decision snapshot a few seconds into every fight. Nothing to type.

## Each session
1. Install `DMGAssist` and `DMGAssist_Watchdog` (zips from the latest CI run or release).
2. Log in. You'll see one line: *"Test build: logging is on ..."*.
3. Play: target dummies, dungeons, anything. Switch specs freely.
   - Optional while playing: `/dmga why` (what and why), `/dmga snapshot` (store a full trace right now).
4. `/reload` (or log out) — that's when the game writes the log files.
5. On your PC: `python tools/send-logs.py --note "Feral, dummies, felt slow on Rip"`
   (or keep `python tools/send-logs.py --watch` running and every `/reload` is sent automatically).

## What gets recorded
- Launch: client and build, game type, locale, screen and UI scale, every installed addon (version, loaded,
  enabled), relevant CVars, restriction states, DMGAssist key bindings, load order and loading-screen timings;
  DMGAssist's own state (spec, data version, spells matched, how much of the list you can cast, boss mods found,
  keybinds read, interrupt/defensive spell, every setting).
- Combat: casts, glows, restriction changes, every pick change (with queue and mode), readability of every input
  (readable → hidden → back), value ranges, clue grades, interrupts/defensives shown/used/skipped, our own failed
  calls, one decision snapshot per fight.
- Errors: Lua errors, blocked/forbidden actions (plus `Logs/taint.log`), warnings.

## Switches
- `/dmgw testing off` — normal logging only (restores your taint log setting). `/dmgw testing on` to go back.
- `/dmgw launch` — record the launch snapshot again.
- `/dmgw taint full` — very verbose taint log, only if asked for.

## Before a release
Set `ns.TESTING = false` (addons/DMGAssist/Core/Util.lua) and `testingMode = false`
(addons/DMGAssist_Watchdog/Store.lua). The release workflow refuses a release tag while they are on
(pre-release tags such as `v0.2.0-beta1` may keep them).
