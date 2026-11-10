# DMGAssist task list

The working list for DMGAssist. Kept current with every change: a task is added when it's agreed, moved to Done
when it ships (with the version), and anything waiting on in-game testing says so. Scope and decisions:
[scope.md](scope.md).

Last updated: 1.6.0.157 (2026-11-10).

## Launch: Wednesday 2026-11-11 (owner: zonearc)

- [ ] Make `foundation` the default branch on GitHub
- [ ] Retire the old AutoHotkey updater
- [ ] Make the repository private
- [ ] CurseForge: release type Beta, screenshots, project public
- [ ] Paste docs/curseforge-description.md into the CurseForge description if it doesn't sync by itself

## Open: build

- [ ] Forever: confirm the WoWSims rank mapping (data imports for 34 specs; mapping not verified)

## Proposed (waiting on a decision)

- (none)

## Open: needs in-game testing (built, not yet seen in game)

- [ ] Action bar highlight in magenta on Blizzard bars and Bartender; grade window opacity / size / bar / parts
- [ ] Taint: none logged since the Edit Mode fix (1.6.0.139); keep watching the Watchdog's error list
- [ ] Feral: no stopwatch; Rake not shown before energy is there; Ferocious Bite at 5 combo points
- [ ] Channelled and empowered spells (Windwalker, Havoc, Shadow, Devastation): slot 1 waits for the channel to end
- [ ] Tank profiles on each tank spec (Protection Warrior first): keep-up timing, boss-mod cooldowns, Mitigation grade
- [ ] New grade popup look and place; small icons left of slot 1; preview panel
- [ ] Rogue: Outlaw finishers shown at 5+ combo points; Balance: Starfall on 3+ targets; slot 1 calmer while spamming
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
- [ ] Boss mods in a real dungeon or raid (DBM test hook works); interrupts in a dungeon (smart mode)
- [ ] Buff reminders on other classes; specs not tried yet; LFR; WoW Forever; a clean install

## Done (recent)

- 1.6.0.161: "Beyond Assisted Combat" on the grade and the grade's history page: the share of the fight slot 1
  showed something other than Blizzard's assistant, split into cooldowns (SimC timing), rotation (SimC's priority),
  upkeep (DoTs, buffs, forms) and utility (interrupts, defensives, gap closers), plus extras pressed that Blizzard
  never shows (off-GCD badge, trinkets, defensive icon). Not a damage claim. Setting to hide it; all languages

- 1.6.0.160: grade: the fight is graded up to the last rotation press + 3 s (walking off a dummy while still in
  combat counted as idle and an "unused" Lunar Beam: a C for a clean Guardian fight); the report's grade line lists
  the reaction and cooldown delays (count: 25th/median/75th ms) to check the reaction number

- 1.6.0.159: DoT time left: a clue that a DoT is up (Blizzard's assistant not asking for it) no longer hides our
  own clock's time left, so "remains<2" / refreshable lines decide again (Balance Sunfire was cast once a fight)

- 1.6.0.158: Balance: a spell the assistant has named for 6 s+ without being cast no longer locks out the spells
  left to Blizzard (Fury of Elune sat ready while it named Sunfire); fight_remains / time_to_die never drop under
  10 s while a fight goes on, and a fight longer than the usual one uses your longer fights of that kind (32 s into
  a dummy pull Sunfire / Moonfire stopped refreshing: "time_to_die>5" read false); a skip is judged by what slot 1
  showed when you pressed (a press landing 50 ms after a change, or a Starfire started before it, is no skip) and a
  hold lapses after 20 s (Eclipse was held for a whole fight); Eclipse is blocked during Incarnation as Lunar /
  Solar Eclipse too (slot 1 flipped Eclipse / Starfall every second). Guardian: Ironfur's next stack is asked a GCD
  plus reaction time before the oldest ends. Grade: capped at the weakest part + 6. Watchdog: the grade line lands
  in the fight it grades

- 1.6.0.157: cooldowns from the game's own tooltip out of combat ("1 min cooldown", any language, talents
  included) ahead of SimC's base number, and every cooldown cast in a fight learned when it ends (Convoke the
  Spirits: 120 s in SimC's data, 1 min talented, never shown again). Nothing affordable while Blizzard waits for
  energy: slot 1 shows the spell it's waiting for, shaded, instead of an empty HUD. An "affordable" energy floor
  above anything our own count could reach is a free proc (Clearcasting), not energy. Action bar highlight: a
  DMGAssist magenta outline (Blizzard bars, Bartender, Dominos, ElvUI). Grade window: background opacity, size,
  grade bar and parts on/off (the box re-flows); all languages

- 1.6.0.156: settings open again from the minimap, the gear and /dmga: the Watchdog shows no taint since the Edit
  Mode fix (1.6.0.139) - the errors pasted were BugSack's history from 2026-11-09, so 1.6.0.153's change was
  undone. Feral: a spell the game calls usable isn't ready while our energy range is below its cost (Rake shown
  ~1 s early with energy 0-24), unless it glows or the assistant names it. Balance: Fury of Elune left to
  Blizzard's assistant. Grade box: 14 px margin all round. Icon: no rim of its own (the button's ring frames it),
  letter centred

- 1.6.0.155: DMGAssist's own icon: a gold "D" on a dark crimson disc with a gold rim (like Masque's "M"), on the
  minimap button and in the addon list (Media/DMGAssist.tga, drawn by tools/make_icon.py); replaces the fist

- 1.6.0.154: settings preview: the dark panel is fitted to everything the HUD shows (slots, small icons, title row,
  bars) after every change, with the label wrapping inside it; the docked HUD stays on screen

- 1.6.0.153: taint: DMGAssist no longer opens the game's Settings window itself (Settings.OpenToCategory ran
  Blizzard's panel manager in our code; the character frame, party frames, action bars and the game menu then ran
  tainted). Minimap / gear / /dmga say where the settings are. Feral: energy regeneration in combat from the last
  rate the game showed (not our haste estimate); Blizzard's "Waiting for Energy" placeholder (the stopwatch) is
  never shown and tells us energy is below the cheapest spender (caps our floor, beats free-proc "affordable"
  answers); other placeholders are logged (assistant_placeholder) to learn what else exists. Combo points after a
  builder whose crit adds a point (Feral Primal Fury, Assassination Seal Fate) are "v or v+1": the game's own
  curve then shows the finisher or the builder

- 1.6.0.152: grade pauses while you move (dodging boss damage): reaction, cooldown and mitigation delays are timed
  on a clock that stops while moving, and moving is never idle time (out of range wasn't either, since 1.6.0.150)

- 1.6.0.151: grade Cooldowns now counts every 20 s+ cooldown slot 1 shows (Fury of Elune wasn't "major" and was
  ignored), timed from its "press now"; pressed early (queued) or from slots 2-3 is on time. The grade reaches the
  report: the Watchdog keeps a fight's session open 2 s for end-of-fight results. Popup taller, letter higher,
  more room around the score, tip inside the box; 30 tips in pools per weak part, picked at random; tip can be
  switched off (Performance grade > Show a tip under the grade); all languages

- 1.6.0.150: the grade only judges what we showed: presses with nothing in slot 1, of spells outside the
  rotation (movement, utility, a defensive or tank button pressed early, racials), and with an interrupt in slot 1
  (judged against the rotation behind it) are neutral; slot 1 switches tracked every frame (a press of what slot 1
  showed 0.6 s before counts, also mid-GCD); idle time only while slot 1's spell is in range and usable; a major
  cooldown shown under 2 s before slot 1 moved on isn't graded. The grade log lists right / slots 2-3 / wrong /
  neutral presses. Grade letter in the game's damage-number font (Skurri on English clients), 80 pt, thick
  outline, pops in with an overshoot

- 1.6.0.149: swept the code for hidden (secret) values tested directly: weapon imbue reminders and a diagnostics
  probe read them safely now

- 1.6.0.148: interrupts reviewed for 12.x: in dungeons/raids ("smart") the importance check tested a secret
  boolean with Lua's "or" (would have errored on every enemy cast in an instance, never seen in the open world);
  target cast names are no longer compared while secret. Learning summary in plain words on the Grade report page
  ("Kill Command: measured 5 times, our clock corrected by -1.2 s, now within 0.2 s"; spells left to Blizzard)

- 1.6.0.147: pre-checked every spec for what Rogue, tanks, Balance and Arms showed. "Blizzard decides" spells no
  longer freeze when the assistant is stuck naming something outside its rotation (Outlaw: Between the Eyes, Roll
  the Bones, Blade Flurry, Adrenaline Rush, Killing Spree, Blade Rush were blocked a whole fight by a missing
  poison). Finishers trusted on every hidden spender resource (Holy Power, Soul Shards, Chi, Runic Power...), not
  only combo points. Proc-reset cooldowns left to Blizzard from the first fight: Protection Shield Slam, Guardian
  Mangle, Elemental Lava Burst, Enhancement Stormstrike, Shadow Mind Blast, Subtlety Shadow Dance, Havoc Eye Beam,
  Devastation Fire Breath / Eternity Surge, Beast Mastery Bestial Wrath. Hidden channels (Fists of Fury, Eye Beam,
  Mind Flay) and empowered casts timed from their duration instead of 0 s

- 1.6.0.146: tank profiles (Tanks.lua) for all six tank specs: slots 1-3 damage only, mitigation in the red icon -
  keep-up when due while tanking (Shield Block, Ignore Pain, Demon Spikes, Shield of the Righteous, Purifying /
  Celestial Brew; Ironfur stays with Essentials), cooldowns before boss-mod tank hits / AoE, Spell Reflection /
  Anti-Magic Shell / Diffuse Magic for spells at you, emergencies at the tank threshold (50% default, per spec,
  Combat > Tanks). Grade: Mitigation part for tanks (pressed within 1 s full, 5 s none)

- 1.6.0.145: grade popup redesigned: big letter that lands and settles, a D..S+ gradient bar with a sliding marker,
  the four parts as a grid (value over name, coloured), tip below; it sits just above the icons' saved place (no
  longer following the docked preview). Settings rows renamed (Sample grade / Default place / This spec's history).
  Small icons moved outside slot 1 by default (left of it, top and bottom, 40%); the settings preview has a dark
  panel. Spell names under icons already exist (Display > Spell names under icons)

- 1.6.0.144: Balance: Starfall shown on AoE (Blizzard naming Starfall no longer "confirms" the uncertain Starsurge
  line above it). Slot 1: one free change per press, further changes wait 0.5 s (no more flip-flops right after a
  cast). Grade rebalanced: letters S+ S A+ A B+ B C D (B+ from 72), slots 2-3 = 0.75, a press of what slot 1 showed
  0.6 s earlier counts, 0.25 s free per "press now", reaction full at 0.25 s, cooldowns full within 2 s, unused
  potions/trinkets not graded; the grade is logged in reports

- 1.6.0.143: Rogue: finishers (Dispatch, Between the Eyes) were "not castable" for whole fights while 7 combo points
  were read (the game called them unusable with no reason): trusted the points. Blizzard's assistant naming a poison
  or imbue in combat (Numbing Poison, a whole fight) is ignored

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
