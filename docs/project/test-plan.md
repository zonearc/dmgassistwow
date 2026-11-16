# In-game test session (owner, 2026-11-16 morning)

Goal: real fights that (1) show how the addon does in game, (2) replay offline so issues can be fixed and checked
without another session, (3) set the offline game's assumptions from real play.

## Before the first pull (once)

1. Install the latest nightly (1.6.0.32x or later). `/dmga` should print the version.
2. `/dmga` -> settings main page -> Logging: **Enhanced**. Every fight then records what the game showed DMGAssist
   (Core/Record.lua), each numbered by itself, nothing to mark. Back to Standard when the testing is done. It only
   costs memory in the saved Watchdog data; nothing is sent anywhere.
3. `/dmgw` - the Watchdog window: check it says testing mode (more events kept). If not: `/dmgw testing on`.
4. Settings as you normally play. Note anything unusual (Cooldown Manager on/off, queue size) - the recording keeps
   the settings too, but a sentence helps.

## The tests (about 15 minutes; any spec, two if there is time)

No marks needed: each fight is numbered. Do the tests in this order (or say which fight was which).

| # | where | what | why |
|---|---|---|---|
| 1 | one training dummy | 2 minutes, play your normal rotation; follow slot 1 when it's right | the baseline: slot 2 against your presses |
| 2 | one training dummy | 2 minutes, press slot 1 exactly as shown (even if you'd do otherwise) | how the addon plays when followed: the offline game's assumption |
| 3 | five dummies | 2 minutes, normal play | AoE, target counting |
| 4 | a real pull (open world pack or a dungeon) | normal | movement, targets dying, adds |

If something looks wrong in a fight, `/dmga mark wrong <a few words>` at that moment.

## Export

Preferred (no copying): `/reload` (or log out) so WoW writes the file, then attach
`World of Warcraft\_retail_\WTF\Account\<ACCOUNT>\SavedVariables\DMGAssist_Watchdog.lua`. It holds the last 8 fights,
the newest 5 with their full recording, so earlier tests aren't lost when you run another.

Fallback: `/dmgw` -> Report -> copy. If it says "part 1/n", copy every part (each starts with `DMGWP i/n`); the decoder
names any part that changed in the copy.

## What happens with it (offline)

- `python3 tools/decode-export.py` -> the fights.
- `python3 tools/replay.py` -> each fight replayed through the current code: "same as shown" (is the replay
  faithful) and slot 2 against your real presses. Every fix after that is checked on your fights before release.
- `python3 tools/why-report.py` -> every slot 2 miss with its reason.
- `python3 tools/calibrate.py` -> your timing, how often you don't follow slot 1, the proc rates, against the offline
  game's numbers (tests/test_scenarios.lua HUMAN_DELAYS, WRONG, tests/procs.lua), which get updated.
- `python3 tools/rotation-check.py` / `tools/score.py` -> the offline game against real play, after the updates.

---

## Older checklist (kept from 1.6.0.190; still useful for features beyond the rotation)


Send `/dmgw` after each item. Note anything odd with a rough time ("at ~20 s slot 1 went blank").

### 1. Classes and specs (dummies: 60 s on 1 target, 60 s on 5)
Done and looking good: Balance, DK, Mage (all), DH (Havoc, Vengeance, Devourer), Evoker (Aug), Rogue (Sub, Assassination).
- Re-check: Devastation (key 5 / Eternity Surge no longer sits in slot 2 on cooldown), Preservation (Fire Breath).
- Outlaw: known gap, Roll the Bones buffs can't be read yet; tell me if Roll the Bones / Between the Eyes timing feels off.
- Not tested yet: Warrior (all), Paladin (all), Hunter (all), Priest (all), Shaman (Resto), Monk (all, Windwalker
  just gained combo_strike), Warlock (all), Druid (Feral, Guardian, Resto), Evoker re-runs.
- Pass = slot 1 mostly matches Blizzard's highlight, finishers/spenders come at max resource, nothing on cooldown
  shown as ready, slot 1 never blank, no chat about spells you don't have.

### 2. Interrupts
- Done on Balance (worked). Delves now behave like the open world (any interruptible cast). Do 2-3 more: rogue Kick, shaman Wind Shear, DH Disrupt, warrior Pummel.
- `/dmga test interrupt`, then open-world caster mobs. Kick when it shows; it should vanish after.

### 2b. Wrong-key hint (1.6.0.188)
- On a dummy, press the key next to slot 1's a few times on purpose (5 when it shows 6): "5 » 6" appears under slot
  1 for a moment. Do it 3+ times in one fight: the grade's tip names the key and the spell.

### 2c. Game mode (1.6.0.189)
- Click the CLASSIC / FLOW switch under the HUD (or /dmga flow). On a dummy: notes slide right to left and reach the line as each
- Flow mode, one note in the box: on a dummy, watch for two icons on the landing spot at once (there should never
  be). Let a note sit on the line 2 s while the HUD changes its mind: it should drop away red and the streak reset.
  Notes should never touch; a "next" that never comes up should vanish after about 3 presses.
  spell is ready; press on the line for Perfect. 5 in a row: "Nice!" and a star; a wrong spell: Miss, streak 0.
- Pull a boss-mod AoE or drop low: the defensive drops into the middle lane; a trinket into the bottom lane.
- The line's box flashes as each note arrives. Try Settings > Display > Game timing offset if Perfects feel hard.
- Chain a few pulls, then wait 20 s: the grade shows the set's score and best streak. Standing still or moving
  mid-pull never breaks the streak; only a wrong spell does.
- Tell me: too fast / slow, icons too small / big, does anything jump around, is the line easy to see.

### 2d. Settings preview (1.6.0.196)
- Open Settings > DMGAssist > Core > Display: change icon sizes (the icons themselves resize, with Masque too),
  toggle the target mode title, keybinds, boss call-outs: each shows in the preview. With Game mode on, the lanes
  show in the preview.

### 3. DBM / BigWigs
- `/dbm test`, with a dummy targeted. Over ~60 s the text above the HUD shows ADDS, AOE, TANK HIT and an
  INTERRUPT countdown; at 20 s the interrupt timer runs out and, if the dummy is casting, your interrupt takes
  slot 1 for ~3 s. Then `/dmgw` (the report lists each boss-mod timer and call). Done, works (1.6.0.184).
- Defensive timing: at "Boom!" (60 s) the defensive shows a few seconds early, sized to its duration (Barkskin 8 s
  -> 4.5 s before), so it's up when the hit lands with time to spare.
- Real: a heroic dungeon boss with a known interrupt or add wave.

### 4. Heroic dungeon, then LFR
- One spec you know well. `/dmgw` after each boss. Note: blank slot 1, flicker, off-bar spells, defensives at low
  health, interrupts on important casts, anything after loading screens, Lua errors.

### 5. WoW Forever
- One class: loads without errors, right spec, a basic dummy rotation, settings open. `/dmgw`.
