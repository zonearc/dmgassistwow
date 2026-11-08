# Rotation and data sources for WoW Forever (researched 2026-11-08)

## Finding
WoW Forever ("WoW Classic Forever", build 1.60.1.70862, interface 16001) is a **classic-era** game on the modern
client: 9 classes (no DK/DH/Monk/Evoker), ranked spells (Prowl 9913 = rank 3, Ferocious Bite 22829 = rank 4),
three talent trees per class exposed through `C_Traits` (Blizzard's Camelot UI calls `GetSpecialization()` the
"primary talent tree").

SimC's `forever` branch has Forever game data but **no Forever rotations**: its default lists are the Midnight
lists (18 of 34 byte-identical). Measured: only a fraction of their spells exist in Forever's data.

## Better sources (all MIT, github.com/wowsims — attribution required: "a user visible link back")
| Repo | What | Use for DMGAssist |
|---|---|---|
| `wowsims/forever` | The Forever DPS simulator, updated daily. 12 rotation lists (`ui/specs/<class>/<spec>/apls/*.apl.json`): Druid feral cat (adaptive), feral bear, balance; Warrior arms, fury, protection; Mage arcane, arcane-fire-fill, deep fire, frostfire bolt, frost; Rogue. Hunter/Paladin/Priest/Shaman/Warlock pages exist but have no lists yet. | **Forever rotations.** Spell IDs match Forever's data almost completely (Arms 33/33, Fury 31/32, Feral 20/21, Balance 7/7, Mage 9–13 of 9–13, Rogue 23/29) vs Midnight's data 1–8 per list. |
| `wowsims/gamedata` | Every Forever class spell and item, per class and spec, re-exported from the client every 30 minutes (each build and hotfix is a merged PR). Current: 1.60.1.70862. | **Forever spell data** (costs, cooldowns, durations, ranks), newer than SimC's forever dump (beta 70425). |
| `wowsims/exporter` | The WoWSims Exporter addon; supports 16001. `Flavors/Forever/Talents.lua` reads Forever talents via `C_Traits` (TraitDefinition IDs per tree), listens to `TRAIT_CONFIG_UPDATED` and `ACTIVE_COMBAT_CONFIG_CHANGED`. | Reference for reading a Forever character (talents, spec by points per tree). |
| `wowsims/sod`, `wowsims/classic` | Season of Discovery / Classic Era sims (older; 88% / 77% of their spell IDs exist in Forever's data). | Fallback lists for specs `forever` doesn't cover yet. |

WoWSims list format: JSON (`TypeAPL`) — `prepullActions`, `priorityList` of `{action: {condition, castSpell|...}}`,
conditions as a tree (`and/or/not`, `cmp{op,lhs,rhs}`, `auraIsActive`, `auraRemainingTime`, `auraNumStacks`,
`auraShouldRefresh`, `currentComboPoints`, `currentEnergy`, `currentRage`, `currentManaPercent`, `spellIsReady`,
`spellTimeToReady`, `spellIsKnown`, `talentIsKnown`, `isExecutePhase`, `numberTargets`, `unitDistance`,
`variableRef` + named `groups`, ...). Most map 1:1 onto our SimC-style terms; sim-only ones (item swaps, `move`,
swing timers) become UNKNOWN or are skipped.

## Plan (not built yet; awaiting go-ahead)
1. `tools/wowsims_import.py`: convert `wowsims/forever` lists into our record format (`simc` lists with expression
   strings), spell IDs straight from the lists; rank-aware matching (a list's max-rank ID -> the highest rank the
   player knows, by spell family from the game data).
2. Forever spell data from `wowsims/gamedata` instead of SimC's forever dump.
3. Fallbacks per spec: wowsims/sod list -> SimC list -> Blizzard rules; record which source each spec uses.
4. Weekly (or on-change) automation PR like the SimC sync; visible credit/link to WoWSims in the addon and README.

## Not reachable from this environment
wowsims.github.io, www.wowsims.com/classic and www.raidbots.com are outside this session's network allow-list;
researched through the GitHub repositories above instead. Raidbots runs SimulationCraft (the source we already
import for Midnight) and has no public API for priority lists.
