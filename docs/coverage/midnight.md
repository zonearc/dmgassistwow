# SimC coverage — midnight

Source: simulationcraft/simc@midnight `de11f57` (2026-11-08). Generated; do not edit.

How much of each priority list DMGAssist can evaluate in combat. *Usable* = readable, static, user mode, or
tracked by our own state model; *unknown* lines need corroboration (see docs/design/engine-priority.md).
Classes are planning estimates until confirmed by Watchdog probes.

*In game data* = how many of the list's spells exist in this game version's own spell data. Low numbers mean
the list was written for another version (SimC's forever branch currently ships the Midnight lists); put a
corrected list in `data/apl-overrides/<branch>/<spec>.simc`.

| Spec | SimC lines | usable | read-only | unknown | in game data | Blizzard lines | Blizzard usable | excluded CDs | top unknown terms |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| deathknight_blood | 54 | 100% | 35% | 0 | 11/12 | 27 | 96% | - | - |
| deathknight_frost | 65 | 97% | 12% | 2 | 13/14 | 32 | 97% | breath_of_sindragosa | target.debuff.casting.react, death_knight.first_ams_cast |
| deathknight_unholy | 47 | 74% | 17% | 12 | 11/11 | 29 | 86% | - | variable.cds_active, max_charges, target.health.pct, pet.army_ghoul.active |
| demonhunter_devourer | 92 | 95% | 32% | 5 | 16/16 | 20 | 100% | metamorphosis, the_hunt, voidblade | void_metamorphosis_base_drain_ps |
| demonhunter_havoc | 36 | 100% | 28% | 0 | 14/14 | 29 | 100% | fel_rush, felblade, metamorphosis, the_hunt, vengeful_retreat | - |
| demonhunter_vengeance | 97 | 89% | 44% | 11 | 16/16 | 23 | 100% | metamorphosis | variable.dung_cd_ok, variable.dung_meta_ok, target.debuff.casting.react, in_boss_encounter |
| druid_balance | 82 | 87% | 28% | 11 | 16/16 | 36 | 100% | celestial_alignment | energize_amount, active_dots.moonfire, eclipse.lunar, eclipse.solar |
| druid_feral | 54 | 100% | 17% | 0 | 16/16 | 30 | 100% | berserk | - |
| druid_guardian | 58 | 98% | 24% | 1 | 22/22 | 22 | 100% | berserk, convoke_the_spirits | target.cooldown.pause_action.remains |
| druid_restoration | 39 | 97% | 46% | 1 | 16/16 | 20 | 100% | - | druid.time_spend_healing |
| evoker_augmentation | 36 | 97% | 28% | 1 | 15/15 | 23 | 96% | - | evoker.shifting_buffs, evoker.allied_cds_up |
| evoker_devastation | 59 | 98% | 22% | 1 | 15/15 | 22 | 100% | - | target.debuff.casting.react |
| evoker_preservation | 5 | 100% | 60% | 0 | 4/4 | - | - | - | - |
| hunter_beast_mastery | 54 | 94% | 24% | 3 | 8/8 | 20 | 95% | - | howl_summon.ready |
| hunter_marksmanship | 75 | 97% | 32% | 2 | 12/13 | 29 | 100% | trueshot | cost |
| hunter_survival | 59 | 98% | 24% | 1 | 8/8 | 21 | 95% | takedown | howl_summon.ready |
| mage_arcane | 38 | 100% | 24% | 0 | 11/12 | 27 | 96% | arcane_surge | - |
| mage_fire | 73 | 86% | 12% | 10 | 8/9 | 26 | 92% | combustion | scorch_execute.active, hot_streak_spells_in_flight, variable.combustion_precast_time, firestarter.active |
| mage_frost | 63 | 100% | 38% | 0 | 12/13 | 25 | 96% | - | - |
| monk_brewmaster | 60 | 97% | 52% | 2 | 13/14 | 22 | 100% | - | health.max |
| monk_mistweaver | 6 | 100% | 67% | 0 | 5/5 | - | - | - | - |
| monk_windwalker | 128 | 59% | 19% | 52 | 15/16 | 34 | 62% | celestial_conduit, flying_serpent_kick, zenith | combo_strike, pet.xuen_the_white_tiger.active |
| paladin_holy | 8 | 88% | 88% | 1 | 7/7 | - | - | - | consecration.up |
| paladin_protection | 27 | 96% | 48% | 1 | 16/16 | 26 | 92% | avenging_wrath, sentinel | next_armament, holy_bulwark, consecration.up |
| paladin_retribution | 32 | 100% | 47% | 0 | 14/14 | 37 | 100% | avenging_wrath | - |
| priest_discipline | 9 | 89% | 78% | 1 | 9/9 | - | - | - | target.health.pct |
| priest_holy | 5 | 80% | 60% | 1 | 5/5 | - | - | - | target.health.pct |
| priest_shadow | 46 | 89% | 33% | 5 | 17/17 | 39 | 92% | - | target.health.pct, time_to_bloodlust, health.pct, priest.force_devour_matter |
| rogue_assassination | 41 | 100% | 15% | 0 | 15/15 | 36 | 64% | deathmark | - |
| rogue_outlaw | 38 | 92% | 45% | 3 | 17/17 | 31 | 74% | adrenaline_rush | rtb_buffs |
| rogue_subtlety | 42 | 95% | 17% | 2 | 13/13 | 31 | 58% | shadow_blades | cp_max_spend, variable.priority_rotation |
| shaman_elemental | 73 | 99% | 32% | 1 | 19/19 | 38 | 100% | ascendance | lightning_rod |
| shaman_enhancement | 101 | 94% | 29% | 6 | 18/18 | 39 | 100% | doom_winds | pet.surging_totem.active, ti_chain_lightning, pet.searing_totem.active, ti_lightning_bolt |
| shaman_restoration | 4 | 100% | 50% | 0 | 4/4 | - | - | - | - |
| warlock_affliction | 94 | 80% | 34% | 19 | 13/13 | 34 | 97% | summon_darkglare | pet.darkglare.remains, pet.darkglare.active, variable.cds_active |
| warlock_demonology | 47 | 85% | 57% | 7 | 12/12 | 22 | 95% | summon_demonic_tyrant | pet.demonic_tyrant.active |
| warlock_destruction | 61 | 74% | 33% | 16 | 15/15 | 36 | 97% | summon_infernal | variable.infernal_active, demonic_art, target.health.pct, pet.infernal.active |
| warrior_arms | 131 | 96% | 44% | 5 | 20/20 | 30 | 100% | - | variable.execute_phase, target.debuff.casting.react |
| warrior_fury | 101 | 96% | 54% | 4 | 18/18 | 32 | 100% | avatar, recklessness | variable.on_gcd_racials, target.debuff.casting.react, variable.execute_phase |
| warrior_protection | 67 | 96% | 60% | 3 | 20/20 | 30 | 100% | avatar, shield_charge | variable.execute_phase, target.health.pct |
