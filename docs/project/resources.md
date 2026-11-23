# Resources: catalogue, models, accuracy

Every resource a spell spends or builds, how DMGAssist knows it in combat (WoW 12.x hides most of them), and how
close the addon's count is to the truth. Started 2026-11-21 after Restoration's Sunfire looked unaffordable with
261,000 mana: mana had no count, and no healer or caster had a mana cost in the data.

`tests/test_resources.py` fails the build when a resource used by any spell has no model, or when a spec that
spends mana has no mana costs in its data.

## Catalogue

| Power type | Resource | Specs | In combat | Model |
|---|---|---|---|---|
| 0 | Mana | casters, healers, Ret/Prot, Enhancement | hidden | counted (2026-11-21): full after a rest, each cast's cost (data `mpct` x base mana, or the live cost; spells outside our data by the cost the game states), the game's stated regeneration else the spec's measured share |
| 1 | Rage | Warriors, Guardian | hidden | counted: costs, gains, measured passive income (auto-attacks) |
| 2 | Focus | Hunters | hidden | counted: regeneration (game rate, haste), costs, gains, passive income |
| 3 | Energy | Rogues, Feral, Brewmaster, Windwalker | hidden | counted: as Focus; Adrenaline Rush style regeneration auras (data `rgp`) |
| 4 | Combo Points | Rogues, Feral | readable | read |
| 5 | Runes | Death Knights | not reported | counted (2026-11-21): three recharging at once, 10 s each with haste |
| 6 | Runic Power | Death Knights | hidden | counted |
| 7 | Soul Shards | Warlocks | readable | read |
| 8 | Astral Power | Balance, Restoration | hidden | counted |
| 9 | Holy Power | Paladins | readable | read |
| 11 | Maelstrom | Elemental | hidden | counted |
| 12 | Chi | Monks | readable | read |
| 13 | Insanity | Shadow | hidden | counted |
| 16 | Arcane Charges | Arcane | readable | read |
| 17 | Fury | Demon Hunters | hidden | counted |
| 19 | Essence | Evokers | readable | read, with regeneration |

Not power types, tracked as auras/stacks: Maelstrom Weapon, Soul Fragments, Icicles.

Every count is corrected in play by the game's answers: "usable" means at least that spell's cost (with the costs
the game states this moment, a spell made free by a proc proves nothing), "not enough" means below it.

## The truth: Warcraft Logs

Warcraft Logs records, with every cast, the caster's resources at that moment (amount, maximum, cost) for every
resource type, mana included. `tools/wcl-truth.py` saves top players' fights per spec (`data/resource-truth/`:
spell IDs, times, amounts only), `tools/count-error.lua` replays them through the addon and measures the count
against the truth, and `tools/build-income-truth.py` measures each spec's passive income from them
(`Data/IncomeTruth.lua`).

Units: Warcraft Logs stores Rage, Runic Power, Astral Power and Soul Shards in tenths, Insanity in hundredths.

## Accuracy (2026-11-21, ours minus truth, mean over every cast of 3 top fights per spec)

| Spec | Resource | Before | After | Notes |
|---|---|---|---|---|
| Outlaw | Energy (250) | -139 | -1 | Adrenaline Rush regeneration, measured income |
| Arms | Rage (130) | -96 | -40 | the game's "usable" no longer dismissed as a proc |
| Feral | Energy (120) | -59 | -11 | |
| Balance | Astral Power | -42 | -5 | |
| Restoration (Druid) | Astral Power | -37 | +4 | |
| Beast Mastery | Focus | -33 | -2 | |
| Marksmanship | Focus | -62 | -17 | |
| Brewmaster | Energy | -44 | -7 | |
| Protection (Warrior) | Rage | -40 | 0 | |
| Shadow | Insanity | (wrong units) | -8 | |
| Fury | Rage | -34 | -12 | measured income held back (see below) |
| Restoration (Druid) | Mana (273,000) | no count | -2,000 | |
| Holy Priest / Resto Shaman | Mana | no count | ~0 | |

Still off: Assassination +77 Energy and Survival +22 Focus (counted too high), Unholy +19 Runic Power, Vengeance
-33 Fury, Blood -27 Runic Power; mana for Arcane (Arcane Surge spends it all), Augmentation and Protection Paladin.

## Measured passive income held back

With the measured income the graded simulator's slot 2 got worse for Fury (80 -> 50%), Blood (86 -> 72%), Frost DK
(74 -> 67%), Guardian (88 -> 86%) and Survival's simple fights (92 -> 72%); they keep the data's figure until the
cause is found (`tools/build-income-truth.py` HOLD). The owner found Fury fine in game.

## Buffer

Slot 1 never offers a spender as ready unless the game itself says it is usable now, so a buffer can't prevent a
refused press there; it only acts on predictions (slot 1's next, slots 2-3). While the counts ran low, a fixed buffer
(3-8%) would have held spenders and DoTs back further. Now that most counts are close to unbiased, the buffer should
be each resource's measured spread (`count-error.lua` p10 / p90), per spec, and only where refused presses show up
in play. The optional "predictable spending" margin stays off by default.

## Keeping upkeep up (2026-11-23)

Owner: "how do we ensure ... it can spend the critical spells and not starve ... and leaves some out, such as the
sunfire example?"

- Priority and pooling come from the lists (DoT refreshes above fillers, `pool_resource` lines): honest counts are
  what make them work.
- Upkeep guarantee (Engine `G.UpkeepTrusted`): a spell the list keeps up - its line checks its own DoT, a DoT record
  of its name, no real cooldown - that the game calls usable now is never priced out by our estimate in the
  look-ahead, as long as nothing pretended since has spent from its resources. Mana's cheap-spell rule covers the
  Restoration case itself (a pretend Starfire spends mana).
- Targeted reserve: built and measured, not shipped. Holding a spender for a DoT refresh due within two GCDs made
  things worse offline: Feral's Rip uptime 78 -> 73%, Assassination's slot 2 on one target 98 -> 86%, Feral's real
  fight 6/53 -> 4/53 presses - holding a spender delays the build-and-spend cycle that pays for the refresh.
- The gate: the graded simulator's world keeps DoTs on the target; per spec and target count it measures DoT uptime
  and dropped upkeep (seconds a minute a DoT was down, its spell castable, and in neither slot 1 nor 2), held to
  `tests/upkeep_baseline.json` (uptime may lose 5 points, dropped may gain 3 s/min).

Found by the gate, open: Destruction casts Shadowburn 58 times in two minutes offline (no Incinerate, Chaos Bolt or
Immolate/Wither); Unholy's Dread Plague never up; Feral's Rip 71% on one target; Guardian's Moonfire never (its
in-combat line needs talents the reference build lacks - likely intended). Restoration (where Sunfire was dropped)
and the other healers have no graded reference build, so the gate can't see them yet.
