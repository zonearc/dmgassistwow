# Offline fights vs the game: where they differ, and what to expect

The offline fights (`tools/sim.py`, graded scenario mode) run the real addon against a simulated game. Slot 2's
accuracy there is a target, not a promise: wherever the simulated game is simpler than WoW, the offline number is
too high. This page lists the known differences, what each one costs in game, and how a real fight's report shows
it - so a gap seen in game is diagnosed in one pass, not guessed at. Update it after every real fight.

## Calibration so far

| spec | situation | offline (same build) | in game | note |
|---|---|---|---|---|
| Balance | 8 dummies, first fight | 37.8% (1.6.0.299) | 37-45% (1.6.0.291-296, fights 449-459) | close: the offline world had no procs either way, the gap was the Astral Power count, the same in both |
| Outlaw | 1 dummy | 24-40% | 44% (1.6.0.252) | game higher: the offline world has no Opportunity / Ruthless Precision procs to read |

Only two specs measured in game. Every other number below is an estimate until a real fight is reported.

## Known differences

| # | the offline game | WoW | in game, slot 2 is... | specs most affected | how a report shows it |
|---|---|---|---|---|---|
| 1 | no random procs: no free spenders, no Clearcasting, no proc-only spells (they are never usable offline) | procs all the time | lower: SimC lines behind `buff.X.react` stay unknown unless the Cooldown Manager or a glow shows the proc | Fire / Frost / Arcane Mage (Hot Streak, Brain Freeze, Clearcasting), Feral, Outlaw, Enhancement, Elemental (Lava Surge), Balance (Starweaver), Windwalker, Unholy | why-report: "condition unknown {buff...=?}"; `cdm_buff_summary` for what the Cooldown Manager read; `cost_live` lines for free casts |
| 2 | the true resources come from the same data the addon uses (costs, gains, income) | the real numbers | lower where our data is wrong: the count drifts, spenders are promised early or late | any spec with a hidden resource whose data was not measured: Guardian, Shadow, Elemental income by target count still missing | `floor_raised` / `floor_capped` (the game correcting our count), `fit_summary`, `model_at_pull_summary`; resource-replay.py on the report |
| 3 | no buffs or debuffs applied by casts; damage over time never ticks | real auras, hidden in combat (Cooldown Manager reads some) | either way: conditions on our own buffs are unknown in both, but the game's Cooldown Manager answers some | specs with buff windows (Arms Colossus Smash, Fury Enrage, Unholy diseases: `active_dots`) | why-report: "condition unknown"; `clue_summary` cdm checks |
| 4 | a perfect player: presses slot 1 the moment it can, never moves, never swaps | hesitation, movement, swapping, pressing before the GCD ends | lower, and "followed" in prediction_summary shows it | all | `prediction_summary` followed=..; slot1_steady |
| 5 | fixed target count, all in range, never dying | adds come and go, targets die, out of range | lower in dungeons | AoE-heavy specs | `press` lines carry tg=st/aoe; `targets` miss reason |
| 6 | Blizzard's assistant = its rules evaluated against the offline world (sees resources, not procs) | the live assistant sees everything | higher in game where the assistant's pick corroborates slot 1 | specs that lean on `assisted` | slot2_by_source assisted / simc+assisted |
| 7 | no cooldown reductions (Restless Blades), resets or extra charges from talents | real | lower where a cooldown comes back early | Outlaw, Retribution, Frost DK, Havoc | tools/wcl-spellcheck.py flags "cd"; why-report: "not castable (?)" on a spell the player then pressed |
| 8 | spell IDs: the offline spellbook takes the castable entry of each name (1.6.0.305); a name the engine resolves to another ID can still show a proc-only spell forever (Windwalker's Rushing Wind Kick) | the game's spellbook | game: IsSpellUsable decides, no such stall | Windwalker offline (35%) | offline only |

## What was done ahead of time (1.6.0.305)

- Energy and Focus are counted (they had no count; hidden in and out of combat), with their measured income.
- Free / cheaper casts: the game's cost read in combat every pass; when hidden, a lit (proc) spender is free.
- Warrior Rage income from auto-attacks measured (not in the logs as gains): Fury 33/s on a boss, data had 15.
- Blizzard's rules no longer confirm an uncertain line in slot 2 (offline 31% right; in the owner's Balance fights
  the same source was right 20-46% vs 42-57% for plain SimC).
- The look-ahead keeps buffs it knows are up (Lightning Shield).

## Expected in game

Offline average 78.8% (30 specs, 1.6.0.305). Expect less in game, most for gap 1 (procs): the Mages, Feral, Outlaw,
Enhancement and Elemental can lose 15-30 points; resource specs measured from logs (Balance, Havoc, the Warriors,
Death Knights) should land within ~10 of offline. The report of each fight carries everything listed above; with
why-report.py every slot 2 miss has its cause.
