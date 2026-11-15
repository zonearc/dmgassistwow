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
| 1 | PARTLY FIXED (1.6.0.311): procs are rolled at the rate top players get them (tools/wcl-procs.py, tools/proc-map.py, tools/build-procs.py -> tests/procs.lua): free spenders (Clearcasting, Starweaver), instant casts (Hot Streak, Lava Surge), button swaps (Rushing Wind Kick, Ravage), with the glow the game shows. Not yet: procs that reset a cooldown or add stacks/charges, procs tied to what you just cast (rolled by time, not by trigger) | procs all the time | lower: SimC lines behind `buff.X.react` stay unknown unless the Cooldown Manager or a glow shows the proc | Fire / Frost / Arcane Mage (Hot Streak, Brain Freeze, Clearcasting), Feral, Outlaw, Enhancement, Elemental (Lava Surge), Balance (Starweaver), Windwalker, Unholy | why-report: "condition unknown {buff...=?}"; `cdm_buff_summary` for what the Cooldown Manager read; `cost_live` lines for free casts |
| 2 | the true resources come from the same data the addon uses (costs, gains, income) | the real numbers | lower where our data is wrong: the count drifts, spenders are promised early or late | any spec with a hidden resource whose data was not measured: Guardian, Shadow, Elemental income by target count still missing | `floor_raised` / `floor_capped` (the game correcting our count), `fit_summary`, `model_at_pull_summary`; resource-replay.py on the report |
| 3 | no buffs or debuffs applied by casts; damage over time never ticks | real auras, hidden in combat (Cooldown Manager reads some) | either way: conditions on our own buffs are unknown in both, but the game's Cooldown Manager answers some | specs with buff windows (Arms Colossus Smash, Fury Enrage, Unholy diseases: `active_dots`) | why-report: "condition unknown"; `clue_summary` cdm checks |
| 4 | PARTLY FIXED: `tools/sim.py --human` presses a measured moment after the GCD (the owner's Balance fights: median 0.25 s, p90 0.48 s). Still: never moves, never swaps targets, never presses something else |  hesitation, movement, swapping, pressing before the GCD ends | lower, and "followed" in prediction_summary shows it | all | `prediction_summary` followed=..; slot1_steady |
| 5 | fixed target count, all in range, never dying | adds come and go, targets die, out of range | lower in dungeons | AoE-heavy specs | `press` lines carry tg=st/aoe; `targets` miss reason |
| 6 | Blizzard's assistant = its rules evaluated against the offline world (sees resources, not procs) | the live assistant sees everything | higher in game where the assistant's pick corroborates slot 1 | specs that lean on `assisted` | slot2_by_source assisted / simc+assisted |
| 7 | no cooldown reductions (Restless Blades), resets or extra charges from talents | real | lower where a cooldown comes back early | Outlaw, Retribution, Frost DK, Havoc | tools/wcl-spellcheck.py flags "cd"; why-report: "not castable (?)" on a spell the player then pressed |
| 8 | FIXED (1.6.0.310): swapped-in spells were buttons of their own offline (Death Sweep outside Metamorphosis), and a guess at proc-only spells blocked core spells in most specs (Eviscerate, Kill Command, Colossus Smash, Rake, Stormstrike, Metamorphosis, Blackout Kick) | the game: a button swaps only while its aura is up (Data/Overrides.lua from the game data) | - | - | the offline game now swaps buttons for the aura's duration and blocks nothing else |
| 8b | FIXED (1.6.0.310): resource maximums ignored talents (Subtlety capped at 5 combo points, talents give 7) | talents raise them (tests/max_resource.lua from the game data) | - | - | - |
| 9 | cooldowns that reset at random (Gore, Restless Blades, Sudden Death...) never reset offline | real (wcl-spellcheck: Mangle recast every 2.1 s on a 6 s cooldown) | slot 1 follows the assistant for them (volatile); slot 2 after one of them can't know a reset | Guardian, Brewmaster, Beast Mastery, Survival, Arms, Fury, Havoc, Elemental | why-report: "not castable (?)" on the spell then pressed |

## What was done ahead of time (1.6.0.305)

- Energy and Focus are counted (they had no count; hidden in and out of combat), with their measured income.
- Free / cheaper casts: the game's cost read in combat every pass; when hidden, a lit (proc) spender is free.
- Warrior Rage income from auto-attacks measured (not in the logs as gains): Fury 33/s on a boss, data had 15.
- Blizzard's rules no longer confirm an uncertain line in slot 2 (offline 31% right; in the owner's Balance fights
  the same source was right 20-46% vs 42-57% for plain SimC).
- The look-ahead keeps buffs it knows are up (Lightning Shield).

## Found by tools/wcl-spellcheck.py (1.6.0.308)

Real casts of top players (2 raid fights per spec) against our data - see docs/coverage/spell-check.md:

- never paid: Havoc Throw Glaive, Windwalker Spinning Crane Kick (Energy), Fury Execute, Protection Thunder Clap ->
  cost removed;
- free half the time or more (procs): Starsurge 65%, Shred 64%, Maul 88%, Pistol Shot 66%, Mortal Strike 51%, Arms
  Execute 67%, Void Ray 55%, Elemental Blast 53% -> the game's live cost and the proc glow cover these in game; the
  offline game never makes them free (gap 1);
- recast far sooner than our cooldown allows: see gap 9;
- read wrong by the tool, not the data: Shadow (Insanity logged in hundredths), the Warlocks and Holy Power (tenths).

Income measured from logs and now used (gap 2 shrinks): Unholy 10.7 Runic Power/s (data 1.9), Elemental 12.4
Maelstrom/s on five targets (7.8), Shadow, Guardian (from raid fights), Havoc.

A real bug found through the offline game: Windwalker's Rushing Wind Kick (exists only with its buff) was shown
whenever Chi was 2+, the game's "not usable" overruled. Fixed (36 -> 94 offline); in game it would have done the
same.

## Offline with procs (1.6.0.311)

With the procs rolled, the 30-spec average is 74.4% (79.9% without; SCEN_NOPROCS=1 to compare). That is the honest
offline number now: Fire 97 -> 77, Balance 72 -> 63, Feral 37 -> 31 (45 with the longer regeneration wait), Unholy
79 -> 55, Evoker 96 -> 70. Fury 72 -> 83 (free Executes). The owner's Balance in game: 37-45.

## Luck: one seed is one sample (owner, 2026-11-15: "so we don't create models against flat behaviours")

`tools/sim.py --seeds N` runs N different random fights (procs, timing) and prints the spread. Four seeds, one and
five targets: Fire 44-64, Balance 59-75, Feral 41-49. A change is only real when it moves the mean of several seeds by
more than that spread; judged on one seed, a model can be fitted to one lucky sequence.

## Expected in game

Offline average 80.4% (30 specs, 1.6.0.308; 78.8 in 1.6.0.305). Expect less in game, most for gap 1 (procs): the Mages, Feral, Outlaw,
Enhancement and Elemental can lose 15-30 points; resource specs measured from logs (Balance, Havoc, the Warriors,
Death Knights) should land within ~10 of offline. The report of each fight carries everything listed above; with
why-report.py every slot 2 miss has its cause.
