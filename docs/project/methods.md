# How changes are made (methods we follow)

Written down so that a fix for one class doesn't quietly break another. Keep this up to date.

## 1. Shared routines first

- A behaviour that applies to more than one class goes in a shared step, never in a class-specific branch.
  Example: "a ready major cooldown never waits behind Blizzard's pick" is one function (Engine
  `G.PromoteReadyMajor`) run after every path (normal, leveling, Blizzard fallback), not three copies.
- Per-spec knowledge lives in **data tables** (`G.SKIP`, `G.NO_ESCALATE`, `G.COMBAT_UNUSABLE`,
  `G.BLOCKED_WHILE_ACTIVE`, `Tanks.PROFILES`, `Essentials.KEEPUPS`, `Buffs.LIST`), read by shared code. Adding
  a spell to a table is safe; adding an `if spec == ...` branch is the last resort.
- When a report shows one spec failing, ask which *rule* failed, then check every spec that hits that rule
  (the scenario check does this mechanically).

## 2. Every change goes through the every-spec check

- `tests/test_scenarios.lua` plays simulated dummy fights for all 40 specs (one target, five targets,
  leveling mode) through `ns.Update` with the game's restrictions on.
- **Rules** (must always hold): no errors; slot 1 never empty; a ready major cooldown never waits behind
  Blizzard's pick; no hold longer than it lasts; nothing from `G.SKIP` ever shown.
- **Baseline** (`tests/scenario_baseline.lua`): major cooldowns used, spells used, empty slots, slot 1 flips.
  Worse than the baseline fails the build.

## 2a. Speed: read once, reuse inside the decision

- A value that can't change inside one update (the enemy count, whether a spell is castable right now) is read
  once and reused: `S.BeginPass` / `S.EndPass` around `ns.Update` (enemy count), `run.castMemo` inside one
  decision. Outside a pass everything is read fresh, so a setting change applies at once.
- The check's "none" fight (nothing castable) has a speed limit: that is the worst case, where the look-ahead
  walks every step and finds nothing.
- Profile before guessing: a `debug.sethook` sampler around `tests/test_scenarios.lua <spec>`; the tests replace
  `print`, so write results to `io.stderr`.
- A filtered run (`tests/test_scenarios.lua rogue`) is for profiling and debugging only: the simulated game
  carries some state from spec to spec, so its numbers differ from the full run the baseline was taken from.

## 2b. Features outside the rotation get a fight in the check

- A new rule (keep-up, reminder, setting) gets a scenario where it must fire, not only a unit test: the unit
  test calls one module, the check runs the whole update. Discipline's Shield passed its unit test while a later
  step (Defensives) removed it from slot 1; only the group fight showed it.
- A spell the addon adds (not in the spec's data) needs cooldown and charge data of its own
  (`SpellMap.EXTRA_INFO`), or our clock calls it ready all fight in combat.
- Look at what the check's player actually pressed (`SCEN_PRESS`, `SCEN_RESULTS`) when adding a feature: "all
  rules hold" with one spell pressed 25 times is a bug the rules don't name.

## 2c. Spell behaviour from the game's own descriptions, not memory

- A rule about a kind of spell (cast while moving, channels, "not ready" vs "not enough Energy") is built from the
  game's spell descriptions in the SimC dump (`.libraries/simc/*/SpellDataDump`), searched for the wording, and
  the list kept next to the rule with the search noted. Spiritwalker's Grace was missed when the list was written
  from memory.
- Learn from the game only what it actually told us: a refusal counts as "on cooldown" only with the game's
  "not ready yet" message; a sample taken against a clock from before the fight teaches nothing.

## 3. Changing the baseline honestly

When the **simulation** changes (more realism), the numbers move for reasons that aren't the addon's:
1. Put the *old* addon code back (`git show HEAD:<file> > <file>`), keep the new simulation.
2. `lua5.1 tests/test_scenarios.lua --update` — the fair baseline.
3. Restore the new addon code and run the check: every difference now is the addon's doing.
4. For each difference: a regression → fix it; intended → say why in the commit, then `--update`.
Never `--update` just to make a failure go away.

## 4. Before a fix

- Decode the report, find the decision trace, and name the cause in one sentence before writing code.
- Check whether the cause is in shared code (then the fix helps or hurts every spec — run the check) or data.
- Add a unit test in `tests/test_engine.lua` for the exact case, named after the behaviour.

## 5. Secret values (Midnight)

- Never boolean-test or compare a value that can be secret; read it with `U.Read` / `U.Get` and treat
  `nil` as unknown. Unknown is a third state, not false.
- Never anchor our frames to Blizzard's protected frames or write fields on them (taint).

## 6. Releases

- `./scripts/check.sh` must pass (exit code checked), then commit with `[release]`, then confirm the nightly.
- Every player-facing string translated into all 9 languages in the same change.
