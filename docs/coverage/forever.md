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
| druid_balance | 6 | 83% | 17% | 1 | 6/6 (wowsims) | 36 | 100% | celestial_alignment | casting.starfire |
| druid_feral | 14 | 36% | 0% | 9 | 10/11 (wowsims) | 30 | 100% | berserk | variable.pool_energy_for_bite, known.faerie_fire, variable.ready_to_use_elunes_light, variable.midfight_bite_is_worthwhile |
| druid_guardian | 12 | 25% | 17% | 9 | 10/11 (wowsims) | 22 | 100% | berserk, convoke_the_spirits | health.pct, variable.ready_to_use_elunes_light, variable.enrage_can_rescue_the_next_attack, variable.faerie_fire_needs_refreshing |
| druid_restoration | 39 | 97% | 46% | 1 | 13/16 | 20 | 100% | - | druid.time_spend_healing |
| evoker_augmentation | 36 | 97% | 28% | 1 | 0/15 | 23 | 96% | - | evoker.shifting_buffs, evoker.allied_cds_up |
| evoker_devastation | 59 | 98% | 22% | 1 | 0/15 | 22 | 100% | - | target.debuff.casting.react |
| hunter_beast_mastery | 52 | 96% | 25% | 2 | 3/8 | 20 | 95% | - | howl_summon.ready |
| hunter_marksmanship | 74 | 91% | 36% | 7 | 7/13 | 29 | 100% | trueshot | max_prio_damage, cost |
| hunter_survival | 56 | 98% | 27% | 1 | 2/8 | 21 | 95% | takedown | howl_summon.ready |
| mage_arcane | 8 | 75% | 50% | 2 | 6/7 (wowsims) | 27 | 96% | arcane_surge | known.spell_1259705 |
| mage_fire | 10 | 50% | 20% | 5 | 7/8 (wowsims) | 26 | 92% | combustion | known.spell_1259705, casting.pyroblast, casting.scorch, casting.arcane_blast |
| mage_frost | 14 | 93% | 29% | 1 | 7/8 (wowsims) | 25 | 96% | - | casting.frostbolt |
| monk_brewmaster | 60 | 97% | 52% | 2 | 0/14 | 22 | 100% | - | health.max |
| monk_windwalker | 128 | 59% | 19% | 52 | 0/16 | 34 | 62% | celestial_conduit, flying_serpent_kick, zenith | combo_strike, pet.xuen_the_white_tiger.active |
| paladin_protection | 36 | 81% | 31% | 7 | 6/15 | 26 | 92% | avenging_wrath, sentinel | next_armament, holy_bulwark, sacred_weapon, consecration.up |
| paladin_retribution | 32 | 100% | 47% | 0 | 5/14 | 37 | 100% | avenging_wrath | - |
| priest_shadow | 44 | 89% | 34% | 5 | 9/17 | 39 | 92% | - | target.health.pct, time_to_bloodlust, health.pct, priest.force_devour_matter |
| rogue_assassination | 28 | 54% | 21% | 13 | 19/21 (wowsims) | 36 | 64% | deathmark | variable.gnome_eureka_active_or_not_ready, known.spell_20572, variable.boot_knife_known, known.spell_1259799 |
| rogue_outlaw | 28 | 54% | 21% | 13 | 19/21 (wowsims) | 31 | 74% | adrenaline_rush | variable.gnome_eureka_active_or_not_ready, known.spell_20572, variable.boot_knife_known, known.spell_1259799 |
| rogue_subtlety | 28 | 54% | 21% | 13 | 19/21 (wowsims) | 31 | 58% | shadow_blades | variable.gnome_eureka_active_or_not_ready, known.spell_20572, variable.boot_knife_known, known.spell_1259799 |
| shaman_elemental | 71 | 99% | 32% | 1 | 9/19 | 38 | 100% | ascendance | lightning_rod |
| shaman_enhancement | 100 | 89% | 31% | 11 | 8/18 | 39 | 100% | doom_winds | pet.surging_totem.active, ti_chain_lightning, pet.searing_totem.active, ti_lightning_bolt |
| warlock_affliction | 94 | 80% | 34% | 19 | 6/13 | 34 | 97% | summon_darkglare | pet.darkglare.remains, pet.darkglare.active, variable.cds_active |
| warlock_demonology | 47 | 85% | 57% | 7 | 1/12 | 22 | 95% | summon_demonic_tyrant | pet.demonic_tyrant.active |
| warlock_destruction | 61 | 74% | 33% | 16 | 9/15 | 36 | 97% | summon_infernal | variable.infernal_active, demonic_art, target.health.pct, pet.infernal.active |
| warrior_arms | 40 | 38% | 12% | 25 | 20/25 (wowsims) | 30 | 100% | - | wowsims.actiongroupused, wowsims.multiplecdusages, target.health.pct, variable.recklessness_used |
| warrior_fury | 38 | 50% | 26% | 19 | 21/26 (wowsims) | 32 | 100% | avatar, recklessness | wowsims.multiplecdusages, target.health.pct, wowsims.actiongroupused, wowsims.targetismobtype |
| warrior_protection | 36 | 72% | 44% | 10 | 22/28 (wowsims) | 30 | 100% | avatar, shield_charge | health.pct, variable.shield_equipped, target.health.pct, known.battle_shout |
