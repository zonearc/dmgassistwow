# Per-spec scorecard

Written by `python3 tools/scorecard.py` from the two gates' baselines (build 9011d56).

- **Sim slot 2**: slot 2 was the next press, simulated fights (1 target / 5 targets / live play: bars, hidden
  flags, cooldowns from the last pull, a late player who strays, range).
- **Shown ready on cd**: slot 1 shown ready while its cooldown ran (simulated, single target).
- **Real**: recorded fights (tests/fights): slot 1 / slot 2 replayed the same as shown in game, slot 2 against
  the presses that came, slot 1 uncastable count. Blank: no recorded fight for that spec yet.
- Target for now: slot 2 at 70%+ (owner, 2026-11-17). Below it: **bold**.

| spec | sim slot 2 st / aoe / live | shown ready on cd | real fights | real slot 1 / 2 same | real slot 2 vs presses | uncastable |
|---|---|---|---|---|---|---|
| deathknight_blood | 79% / 79% / 78% | 4% | 1 | 75% / 71% | **25%** | 18 |
| deathknight_frost | **42%** / **27%** / **68%** | 0% | 1 | 23% / 14% | - | 0 |
| deathknight_unholy | 96% / **38%** / 72% | 0% | 1 | 55% / 70% | **20%** | 0 |
| demonhunter_devourer | **12%** / **12%** / **10%** | 0% | 1 | 43% / 53% | **9%** | 126 |
| demonhunter_havoc | **62%** / **62%** / **65%** | 0% | 1 | 68% / 67% | **8%** | 21 |
| demonhunter_vengeance | 88% / 88% / 94% | 12% | 1 | 70% / 51% | **0%** | 0 |
| druid_balance | 73% / **67%** / **55%** | 0% | 2 | 77% / 61% | 78% | 0 |
| druid_feral | **66%** / 82% / **65%** | 0% |  |  |  |  |
| druid_guardian | **63%** / **56%** / 87% | 0% |  |  |  |  |
| druid_restoration | 83% / 100% / 94% | 0% |  |  |  |  |
| evoker_augmentation | 85% / 88% / 95% | 0% | 2 | 54% / 40% | **19%** | 48 |
| evoker_devastation | **58%** / 92% / 95% | 0% | 1 | 52% / 44% | - | 81 |
| evoker_preservation | **12%** / **12%** / **28%** | 0% |  |  |  |  |
| hunter_beast_mastery | 100% / 100% / 100% | 0% | 2 | 56% / 31% | **8%** | 0 |
| hunter_marksmanship | **29%** / **67%** / **67%** | 2% | 2 | 49% / 59% | **25%** | 0 |
| hunter_survival | 92% / 96% / 94% | 0% | 1 | 74% / 41% | - | 0 |
| mage_arcane | **54%** / 88% / 89% | 0% | 1 | 88% / 86% | **58%** | 0 |
| mage_fire | **54%** / **64%** / 88% | 0% | 2 | 42% / 32% | **38%** | 0 |
| mage_frost | 100% / 100% / 94% | 0% | 1 | 42% / 35% | **12%** | 0 |
| monk_brewmaster | **58%** / 100% / 100% | 0% | 1 | 42% / 22% | - | 0 |
| monk_mistweaver | **38%** / **0%** / **6%** | 0% |  |  |  |  |
| monk_windwalker | **39%** / **8%** / **35%** | 19% | 1 | 43% / 13% | - | 0 |
| paladin_holy | 100% / 95% / 94% | 37% |  |  |  |  |
| paladin_protection | 100% / 100% / 100% | 13% | 1 | 92% / 85% | - | 0 |
| paladin_retribution | **56%** / 96% / 95% | 0% |  |  |  |  |
| priest_discipline | 100% / 100% / 100% | 8% | 1 | 54% / 63% | 81% | 0 |
| priest_holy | 88% / 88% / 100% | 0% | 1 | 50% / 33% | - | 0 |
| priest_shadow | 100% / 83% / 100% | 4% | 2 | 53% / 52% | **18%** | 0 |
| rogue_assassination | **17%** / 70% / 79% | 0% |  |  |  |  |
| rogue_outlaw | **63%** / **67%** / 95% | 0% |  |  |  |  |
| rogue_subtlety | 70% / **63%** / 100% | 0% | 2 | 30% / 6% | - | 0 |
| shaman_elemental | **50%** / **70%** / 83% | 0% | 1 | 33% / 10% | - | 0 |
| shaman_enhancement | **67%** / 72% / 72% | 5% | 1 | 26% / 20% | - | 0 |
| shaman_restoration | 94% / 100% / 100% | 1% |  |  |  |  |
| warlock_affliction | 100% / 100% / 100% | 0% |  |  |  |  |
| warlock_demonology | **47%** / 100% / 100% | 0% |  |  |  |  |
| warlock_destruction | 90% / 95% / 87% | 0% |  |  |  |  |
| warrior_arms | 79% / 72% / 72% | 0% | 2 | 49% / 21% | - | 206 |
| warrior_fury | **54%** / 88% / 78% | 0% | 1 | 82% / 83% | **3%** | 0 |
| warrior_protection | **12%** / **8%** / **0%** | 0% | 1 | 94% / 86% | - | 50 |

24 of 40 specs have a simulated slot 2 under 70% in at least one fight.
