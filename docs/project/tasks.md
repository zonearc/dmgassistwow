# DMGAssist task list

The working list for DMGAssist. Kept current with every change: a task is added when it's agreed, moved to Done
when it ships (with the version), and anything waiting on in-game testing says so. Scope and decisions:
[scope.md](scope.md).

Last updated: 1.6.0.140 (2026-11-09).

## Launch: Wednesday 2026-11-11 (owner: zonearc)

- [ ] Make `foundation` the default branch on GitHub
- [ ] Retire the old AutoHotkey updater
- [ ] Make the repository private
- [ ] CurseForge: release type Beta, screenshots, project public
- [ ] Paste docs/curseforge-description.md into the CurseForge description if it doesn't sync by itself

## Open: build

- [ ] End-of-fight learning summary in plain words ("Kill Command: corrected 3 times, now within 0.2 s")
- [ ] Interrupts: review for the game's combat restrictions (12.x), like defensives were
- [ ] Forever: confirm the WoWSims rank mapping (data imports for 34 specs; mapping not verified)

## Proposed (waiting on a decision)

- [ ] Low-health threshold per role/spec: tanks 50% by default (DPS stay 35%), editable per spec; it only drives
  the big emergency buttons (Shield Wall, Last Stand); active mitigation follows SimC while tanking
- [ ] Spell Reflection and other reactive tank buttons: on a DBM/BigWigs "spell on you" or tank-hit timer only

## Open: needs in-game testing (built, not yet seen in game)

- [ ] Protection Warrior on the tank dummy: Shield Block and Ignore Pain shown while tanking (red icon / slot 1)
- [ ] Taint: open/close Edit Mode, character frame, game menu, party frames: no "tainted by DMGAssist" errors
- [ ] Performance grade: popup after a 20 s+ fight, fades in/out; drag it in Edit Mode or unlocked; Settings >
  Performance grade (test, reset position, forget) and Grade report (best, last 10, trend, where to improve)
- [ ] Arms: Overpower and Colossus Smash shown when Blizzard's assistant names them (left to Blizzard from the start)
- [ ] Masque with the real addon (installed 2026-11-09): /msq > DMGAssist group, every icon reskins
- [ ] Settings: explanation line under each section title; live preview docked beside the settings window
- [ ] Guardian: Ironfur (steady red), a defensive when low (pulsing red) and a trinket (gold) at the same time
- [ ] Slot 1 Steady / Fast feel; Wildfire Bomb waits in slot 2 instead of flipping slot 1 right before a press
- [ ] Next class (Survival signed off for now, 2026-11-09): Rogue (Outlaw) and Fury Warrior with the timing learning
- [ ] Dead pet: Revive Pet shown after the pet dies (Survival)
- [ ] Fury after /dmga relearn: Raging Blow timing (charges, reset procs) learned sanely
- [ ] Single-target dummy fights (boss numbers learned separately from 5-dummy pulls)
- [ ] Boss mods in a real dungeon or raid (DBM test hook works)
- [ ] Buff reminders on other classes; specs not tried yet; LFR; WoW Forever; a clean install

## Done (recent)

- 1.6.0.140: tanks: Shield Block, Ignore Pain and the other SimC mitigation lines were skipped as "nothing to
  mitigate" for whole fights (health hidden in combat, and Stagger, which is always 0 outside Brewmaster, was read
  as "unhurt"). Now a tank with aggro counts as being hit; hidden health without aggro is "can't tell"

- 1.6.0.139: taint fix: Edit Mode is followed with hooksecurefunc (work deferred a frame) instead of EventRegistry
  callbacks, and the welcome setup no longer opens Edit Mode itself. Both ran our code inside Blizzard's panel code:
  thousands of "secret value ... tainted by DMGAssist" errors in party frames, action bars, the character frame and
  the game menu

- 1.6.0.138: end-of-fight performance grade, S+ to D: accuracy (presses vs slot 1), always casting, reaction,
  cooldowns; its own movable popup above the icons, best and last 20 per spec, settings page with a report; all 9
  languages. Arms: Overpower (Tactician resets) and Colossus Smash (Anger Management) left to Blizzard's assistant
  from the start; a spell left to Blizzard no longer uses its learned correction

- 1.6.0.137: slot 1 follows the decision freely for 0.35 s after a press (the decision made before the game reports
  the cast still showed the pressed spell, and was held: Whirlwind pressed twice in a row)

- 1.6.0.136: pieces of one press (Raging Blow's off-hand hit) count as one cast for clocks and learning (Raging
  Blow's correction had run away to -21 s); one measurement can't push a correction past 60% of the cooldown.
  Tested in game: Fury Whirlwind every 4-5 presses, Odyn's Fury on cooldown

- 1.6.0.135: Fury: endless Whirlwind fixed (a buff seen out of combat was trusted as gone once the game hid it in
  combat); Whirlwind's 4 stacks used up by attacks; one press with several cast events counts once (Odyn's Fury
  was held as "skipped 3 times" after one Rampage and one Whirlwind)

- 1.6.0.134: dead pet: Revive Pet instead of Call Pet (pet body seen dead, or Call Pet goes through and no pet
  appears). Tested in game: potions (picker and items icon) work

- 1.6.0.133: removed the Titan Panel / data broker launcher; ElvUI, Bartender, Dominos no longer advertised
  (keybinds are still read from their buttons); this task list
- 1.6.0.132: author credit on the Status page; Integrations page lists each supported addon as linked / installed /
  not installed; /dmga addons
- 1.6.0.131: live preview beside the settings window
- 1.6.0.130: potion picker from bags, /dmga potion
- 1.6.0.129: one purpose per place (rotation slots, defensive icon, items icon); potions; clearer settings with an
  explanation per section and a tooltip per option, 9 languages; settings open safely after combat
- 1.6.0.128: slot 1 frozen while you reach for it; Steady / Fast setting
- 1.6.0.126: trinkets suggested from what each trinket does (SimC's this_trinket questions)
- 1.6.0.123-125: self-learning cooldown timing, pressing until it goes through, refused presses move slot 1 on
