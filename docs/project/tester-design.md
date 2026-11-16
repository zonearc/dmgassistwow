# The tester: design

Owner, 2026-11-16: "This tester has a lot of value later. As new patches come in, if we could feed Warcraft logs and
patch notes to it we could model out changes and verify the addon adjusts to it well, we catch the impacts of
things." And: "We also want to learn from the addon and to define the tester."

## Three sources of truth, one loop

```
        game data (SimC: APLs, SpellDataDump)          real play (Warcraft Logs: top players)
                    |                                              |
        tools/simc_import.py, override-map.py,        wcl-procs / wcl-triggers / wcl-income /
        max-resource-map.py, proc-map.py              wcl-spellcheck / wcl-castdelta
                    \                                              /
                     +---- data/*.json --> tools/build-*.py -------+
                                   |
                     addon data (Data/*.lua)  +  offline world (tests/procs.lua, max_resource.lua ...)
                                   |
             tests/test_scenarios.lua (the offline game)  --  tools/sim.py, score.py, rotation-check.py
                                   |
                         the owner's fights (Watchdog export with the input recording)
                                   |
             tools/replay.py (the fight again, any code)  --  calibrate.py (the offline game's assumptions)
```

- **Game data** says what spells do (costs, gains, cooldowns, swaps, procs' effects, resource caps).
- **Warcraft Logs** says what really happens (income, how often procs come and from which casts, resets, what top
  players cast, costs actually paid).
- **The owner's fights** say what the game shows the addon (secrets, glows, the assistant) and how a person plays.

Each is used to check the others: rotation-check (offline vs real casts), spell-check (data vs real casts),
replay (offline code vs a recorded game), calibrate (offline player vs the owner).

## A new patch

`tools/patch-check.sh` runs, in order:

1. the SimC import (the weekly job does this already) and the game-data maps (overrides, max resources, procs);
2. the Warcraft Logs measurements for every spec (procs, triggers, income, spell check) - top fights of the new patch;
3. the tables built from them (`build-procs.py`, `build-resource-targets.py`, `fold-measured.py`);
4. `tools/score.py`: every spec's slot 2 and rotation match, compared with the run before the patch.

What moved, and why, is then visible spec by spec: a spec whose rotation match dropped means the offline game or the
data no longer fits real play (a changed talent, a new proc); a spec whose slot 2 dropped while its match held means
the addon's logic needs the change. Patch notes go in as a list of changed spells/talents (`--focus` in the future:
which specs to look at first); the measurements already show the effect of a change, not only the text of it.

The owner's recorded fights from before the patch replay against the new code too (tools/replay.py): the "same as
shown" number says how much the decisions changed on real fights.

## Known limits (2026-11-16)

- Replay faithfulness: 92% (Feral), 81% (Balance) on recorded offline fights. Not recorded yet: the learner's memory
  (starts empty in a replay), timers inside the addon (C_Timer), a few direct reads (UnitAffectingCombat).
- Offline: no movement, targets don't die, the player only presses slot 1 (defensives in the defensive icon are
  never pressed: Ironfur, Shield of the Righteous), procs per cast from the logs but resets only where the logs prove
  them (not Guardian's Gore: haste hides it).
- rotation-check needs real casts: the Mages and Enhancement have none yet (tools/wcl-spellcheck.py for them).
