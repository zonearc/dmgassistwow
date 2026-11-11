# In-game test plan (current: 1.6.0.182)

Send `/dmgw` after each item. Note anything odd with a rough time ("at ~20 s slot 1 went blank").

## 1. Classes and specs (dummies: 60 s on 1 target, 60 s on 5)
Done and looking good: Balance, DK, Mage (all), DH (Havoc, Vengeance, Devourer), Evoker (Aug), Rogue (Sub, Assassination).
- Re-check: Devastation (key 5 / Eternity Surge no longer sits in slot 2 on cooldown), Preservation (Fire Breath).
- Outlaw: known gap, Roll the Bones buffs can't be read yet; tell me if Roll the Bones / Between the Eyes timing feels off.
- Not tested yet: Warrior (all), Paladin (all), Hunter (all), Priest (all), Shaman (Resto), Monk (all, Windwalker
  just gained combo_strike), Warlock (all), Druid (Feral, Guardian, Resto), Evoker re-runs.
- Pass = slot 1 mostly matches Blizzard's highlight, finishers/spenders come at max resource, nothing on cooldown
  shown as ready, slot 1 never blank, no chat about spells you don't have.

## 2. Interrupts
- Done on Balance (worked). Do 2-3 more: rogue Kick, shaman Wind Shear, DH Disrupt, warrior Pummel.
- `/dmga test interrupt`, then open-world caster mobs. Kick when it shows; it should vanish after.

## 3. DBM / BigWigs
- Out of combat: `/dbm test` (or BigWigs options > Test), then `/dmgw`.
- Real: a heroic dungeon boss with a known interrupt or add wave.

## 4. Heroic dungeon, then LFR
- One spec you know well. `/dmgw` after each boss. Note: blank slot 1, flicker, off-bar spells, defensives at low
  health, interrupts on important casts, anything after loading screens, Lua errors.

## 5. WoW Forever
- One class: loads without errors, right spec, a basic dummy rotation, settings open. `/dmgw`.
