# SimC coverage — forever

Source: simulationcraft/simc@forever `4dd64b4` (2026-10-16). Generated; do not edit.

How much of each priority list DMGAssist can evaluate in combat. *Usable* = readable, static, user mode, or
tracked by our own state model; *unknown* lines need corroboration (see docs/design/engine-priority.md).
Classes are planning estimates until confirmed by Watchdog probes.

*In game data* = how many of the list's spells exist in this game version's own spell data. Low numbers mean
the list was written for another version (SimC's forever branch currently ships the Midnight lists); put a
corrected list in `data/apl-overrides/<branch>/<spec>.simc`.

| Spec | SimC lines | usable | read-only | unknown | in game data | Blizzard lines | Blizzard usable | excluded CDs | top unknown terms |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| deathknight_blood | 54 | 100% | 35% | 0 | 0/12 | 27 | 96% | - | - |
| deathknight_frost | 65 | 97% | 12% | 2 | 0/14 | 32 | 97% | breath_of_sindragosa | target.debuff.casting.react, death_knight.first_ams_cast |
| deathknight_unholy | 47 | 72% | 19% | 13 | 0/11 | 29 | 86% | - | variable.cds_active, variable.spending_rp, pet.army_ghoul.active, max_charges |
| demonhunter_devourer | 133 | 90% | 26% | 13 | 0/16 | 20 | 100% | metamorphosis, the_hunt, voidblade | void_metamorphosis_base_drain_ps, variable.wont_drop_meta |
| demonhunter_havoc | 35 | 100% | 29% | 0 | 0/13 | 29 | 100% | fel_rush, felblade, metamorphosis, the_hunt, vengeful_retreat | - |
| demonhunter_vengeance | 136 | 87% | 45% | 18 | 0/17 | 23 | 100% | metamorphosis | variable.prio_slashes, variable.dung_cd_ok, variable.dung_meta_ok, in_boss_encounter |
| druid_balance | 83 | 87% | 28% | 11 | 9/16 | 36 | 100% | celestial_alignment | energize_amount, active_dots.moonfire, eclipse.lunar, eclipse.solar |
| druid_feral | 54 | 100% | 17% | 0 | 11/16 | 30 | 100% | berserk | - |
| druid_guardian | 51 | 98% | 24% | 1 | 13/22 | 22 | 100% | berserk, convoke_the_spirits | target.cooldown.pause_action.remains |
| druid_restoration | 39 | 97% | 46% | 1 | 13/16 | 20 | 100% | - | druid.time_spend_healing |
| evoker_augmentation | 36 | 97% | 28% | 1 | 0/15 | 23 | 96% | - | evoker.shifting_buffs, evoker.allied_cds_up |
| evoker_devastation | 59 | 98% | 22% | 1 | 0/15 | 22 | 100% | - | target.debuff.casting.react |
| hunter_beast_mastery | 52 | 96% | 25% | 2 | 4/8 | 20 | 95% | - | howl_summon.ready |
| hunter_marksmanship | 74 | 91% | 36% | 7 | 8/13 | 29 | 100% | trueshot | max_prio_damage, cost |
| hunter_survival | 56 | 98% | 27% | 1 | 2/8 | 21 | 95% | takedown | howl_summon.ready |
| mage_arcane | 38 | 100% | 24% | 0 | 8/12 | 27 | 96% | arcane_surge | - |
| mage_fire | 73 | 86% | 12% | 10 | 7/9 | 26 | 92% | combustion | scorch_execute.active, hot_streak_spells_in_flight, variable.combustion_precast_time, firestarter.active |
| mage_frost | 63 | 100% | 38% | 0 | 6/13 | 25 | 96% | - | - |
| monk_brewmaster | 60 | 97% | 52% | 2 | 0/14 | 22 | 100% | - | health.max |
| monk_windwalker | 128 | 59% | 19% | 52 | 0/16 | 34 | 62% | celestial_conduit, flying_serpent_kick, zenith | combo_strike, pet.xuen_the_white_tiger.active |
| paladin_protection | 36 | 81% | 31% | 7 | 6/15 | 26 | 92% | avenging_wrath, sentinel | next_armament, holy_bulwark, sacred_weapon, consecration.up |
| paladin_retribution | 32 | 100% | 47% | 0 | 5/14 | 37 | 100% | avenging_wrath | - |
| priest_shadow | 44 | 89% | 34% | 5 | 9/17 | 39 | 92% | - | target.health.pct, time_to_bloodlust, health.pct, priest.force_devour_matter |
| rogue_assassination | 41 | 100% | 15% | 0 | 12/15 | 36 | 64% | deathmark | - |
| rogue_outlaw | 38 | 92% | 45% | 3 | 11/17 | 31 | 74% | adrenaline_rush | rtb_buffs |
| rogue_subtlety | 42 | 95% | 17% | 2 | 6/13 | 31 | 58% | shadow_blades | cp_max_spend, variable.priority_rotation |
| shaman_elemental | 71 | 99% | 32% | 1 | 9/19 | 38 | 100% | ascendance | lightning_rod |
| shaman_enhancement | 100 | 89% | 31% | 11 | 8/18 | 39 | 100% | doom_winds | pet.surging_totem.active, ti_chain_lightning, pet.searing_totem.active, ti_lightning_bolt |
| warlock_affliction | 94 | 80% | 34% | 19 | 6/13 | 34 | 97% | summon_darkglare | pet.darkglare.remains, pet.darkglare.active, variable.cds_active |
| warlock_demonology | 47 | 85% | 57% | 7 | 1/12 | 22 | 95% | summon_demonic_tyrant | pet.demonic_tyrant.active |
| warlock_destruction | 61 | 74% | 33% | 16 | 9/15 | 36 | 97% | summon_infernal | variable.infernal_active, demonic_art, target.health.pct, pet.infernal.active |
| warrior_arms | 131 | 96% | 44% | 5 | 12/20 | 30 | 100% | - | variable.execute_phase, target.debuff.casting.react |
| warrior_fury | 101 | 96% | 54% | 4 | 10/18 | 32 | 100% | avatar, recklessness | variable.on_gcd_racials, target.debuff.casting.react, variable.execute_phase |
| warrior_protection | 67 | 96% | 60% | 3 | 10/20 | 30 | 100% | avatar, shield_charge | variable.execute_phase, target.health.pct |
