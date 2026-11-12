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

- Mage: Frost good (2026-11-12). Fire: "only 1 icon to start" was everything blocked while moving.

- UI errors (2026-11-12): AssistedCombatManager.lua "attempt to call a nil value" also happens with DMGAssist
  disabled (user test, DBM + BugSack + Masque loaded): not ours. ActionButton1 had no AssistedCombatHighlightFrame
  in the locals; Blizzard's Assisted Highlight or Masque reskinning. The "tainted by DMGAssist" blocks are still
  worth a taint.log look.

- Survival: checked on dummies, good (2026-11-12). Windwalker / Brewmaster: good apart from Touch of Death.

- Combos: 19 specs have mined chains (1.6.0.231). The other 21 got none from the simulation (it has no procs and
  few resources: Balance, Unholy, Rogue builders...); adopting the sim-resources patch or mining the Watchdog's
  real casts would add them. Validate the mined ones in game (a chain that never happens is dead weight).
- Launch checklist (Launch section) waits until the owner signs off LFR and class testing (2026-11-12).

- Taint (taint.log from the user, 2026-11-11): both episodes start at 15:52:17 with Edit Mode's layout dropdown
  (Menu.lua Pick -> EditModeManagerFrame:SelectLayout) running "tainted by DMGAssist"; every bar and unit frame's
  SetClampRectInsets / SetScaleBase was then blocked, and at 16:21 the action buttons read tainted fields
  (ActionBar.lua:247 GetSpellFlyoutDirection, autoCastEnabled) and SetAttribute was blocked. The taint enters
  through Blizzard_Menu: our minimap / potion menus used MenuUtil.CreateContextMenu. 1.6.0.227 uses our own menu
  frame instead. Verify: no "tainted by DMGAssist" after using the minimap menu and switching Edit Mode layouts.

- Every-spec check realism (worked on 2026-11-11, saved, not adopted):
  - docs/project/patches/sim-charges.patch: the simulation reports charges via GetSpellCharges like the game.
    Fixed a false "Retribution shows Blade of Justice on cooldown 71%" (1-charge spells looked ready). Alone it
    shifts Holy Paladin (Shield of the Righteous fills Crusader Strike's recharge: more flips, sensible) and
    Vengeance group (Metamorphosis is pressed at 1.8 s yet "majors used 0": find why the count misses it).
  - docs/project/patches/sim-resources.patch: costs / gains / regen, Stealth unusable in combat, the stand-in
    assistant only names what's affordable, each spec pays only resources it uses. Blocked by data: rogue combo
    point gains aren't in the spell data, so combo points never build (Subtlety / Outlaw / Assassination stall);
    Mistweaver's spells carry Windwalker costs. Fury's new flips are correct (Execute when Rage allows).
- Game mode, after first in-game feedback: tune LOOK (4 s of lane), sizes, judgement windows (Perfect 0.25 s,
  Great 0.6 s); optional sounds (hit tick, streak chime, default off); an engine "commit" option measured in the
  every-spec check (fewer swaps vs. exactness).
- Balance on a dungeon boss: Sunfire shown 3 times while Wrath / Starfall were cast instead (grade "missed
  sunfire x3"); the target's DoTs are hidden in combat. Watch in LFR.

- Preservation: Fire Breath refused once (8.4 s, session 246) with no cast that fight; cause unknown, watch.
- SimC tick_time: only in interrupt_if (channel cut-off conditions), which the engine doesn't evaluate (it only
  uses interrupt_if to skip the HOLD cue). Read it if interrupt_if ever gets evaluated.
- The every-spec check can't play Devourer (Fury never changes in the simulation, so Void Ray forever). Model
  spent/gained resources per spell, or mark such rows as not meaningful.
- [ ] Forever: confirm the WoWSims rank mapping (data imports for 34 specs; mapping not verified)

- Brewmaster report (2026-11-12): 21 of 22 Flow judgements "Good", none Perfect: check note timing against
  readiness for a 1 s GCD spec (energy hidden); Blizzard's assistant named Touch of Death all fight (refused on
  the dummies) and was set aside after 20 wrong checks; no mitigation weave on dummies (nothing hits them).

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
- [ ] Fixes 1.6.0.220-227 to confirm in game (BM / MM Black Arrow confirmed 2026-11-12: never doubled, cast almost
  every time shown; Touch of Death offered only when the game lights it, both casts went through on low dummies;
  no "tainted by DMGAssist" since the 1.6.0.227 menu fix, all taint entries are from 2026-11-11): Marksmanship
  warns when no ranged weapon is equipped (the "bar disappears" report); Frenzied Regeneration only at full charges; no DEFEND
  row before the pull (DK); Death Coil in Flow only when Runic Power allows (Unholy); Arms / Fury Whirlwind and
  slot 2 steady without a hero tree; Guardian Moonfire keep-up only when it's on your bar; Flow keybinds all one
  size; welcome style cards; minimap menu + Edit Mode layout switch with no "tainted by DMGAssist"
- [ ] Flow State after 15 Perfect / Great; COMBO BREAKER! on an interrupt (combos signed off by the owner 2026-11-12)

## Done (recent)

- 1.6.0.240: Looking ahead, a spell that only exists while a button turns into it is used once (Glacial Spike
  filled slots 2-3 after its Icicles were spent; the second press cast Frostfire Bolt and was judged a miss). Flow:
  a spec switch's cast (Activating Specialization) and "can't tell" spells during the switch no longer start the
  lanes. Minimap menu: "Move the HUD" removed (unchecking Lock position is the same). Fire: Arcane Intellect
  confirmed in game (recast after cancelling, never shown while up).
- 1.6.0.237: Guardian: Frenzied Regeneration with both charges full is no longer the off-GCD pick (it held the
  badge for 23 s so Ironfur never showed, and it came at 99% health): the low-health heal now shows from 85% when
  both charges are full (the game decides from your health), else at your low-health setting. Flow shows the
  counted keep-up (Ironfur stacks, Atonement) beside the action box, as the classic HUD does.
- 1.6.0.236: A damage tick the game logs as a cast (Spinning Crane Kick's 107270) is no longer taken as a press:
  it came in the same frame as the cast and Brewmaster's Spinning Crane Kick presses were never judged.
  Flow: out of combat a cast that isn't a rotation spell (switching spec, 5 s) no longer keeps the lanes
  running: they ran on behind the grade and a spec switch started them like a press.
- 1.6.0.235: Flow foot row on two lines at the same size (streak, multiplier and score; then rank and best):
  "Gold" and "Best" were cut to "..." on one line.
- Signed off in game 2026-11-12: combos (1.6.0.234), Elemental slots 2-3, Wailing Arrow, Display Quick setup /
  Custom, settings pages, preview, text sizes, welcome.
- 1.6.0.234: Combo rules from the owner: a combo moves with the streak's judgement (a mid-press switch keeps
  both), 3 presses (4 from a major cooldown), at least 15 s apart, not in a fight's first 5 presses, and one is due
  after 45 s without (any spell in the box can start it then). Guide text updated in 9 languages.
- 1.6.0.233: Combos follow the lane: after the cooldown, each press of the spell in the box moves the combo on, for
  as many presses as were linked (BM showed Kill Command twice before Barbed Shot and the fixed chain ended after the
  first press). Flow layout: the judgement word and COMBO 1/3 sit right of the action box (they were on it); the
  action box row is 6 px taller with its icons 10 px above the lane; COMBO x3 shows only while its note is on its
  way. Signed off by the user 2026-11-12: Wailing Arrow fix, Display options only with Size Custom.
- 1.6.0.232: Wailing Arrow (and any spell that only exists while a button turns into it): not castable once the
  button is back (Trueshot / Bestial Wrath after the arrow is fired); it sat in slot 1 on E while on cooldown.
  Combos you can see: when slot 1 is a cooldown and slots 2-3 show what follows it, the lane links those
  notes (violet pulsing edges, a violet line between them, COMBO x3 over the first); the chain is what the
  rotation shows (SimC's order), the mined ones only fill in when the queue is too short (the mined Elemental chain
  never happened in real play). The game's own follow-up casts (451368 / 464059) no longer break a chain. Flow
  State: 15 Perfect / Great in a row -> 12 s teal lane, double points, a miss ends it. COMBO BREAKER! (visual, red
  sweep) when an interrupt lands. The action row is now one box over the hit box: the most urgent waiting action
  pops in (interrupt > defensive > keep-up > item, "+1" when another waits; the low-health defensive sits over it).
  Display: the fine-tuning shows only with Size = Custom. User decisions 2026-11-12: combos Flow only, Small stays
  0.8, launch checklist only after LFR and class testing are signed off.
- 1.6.0.231: Combos in Flow. A chain a spec plays after a cooldown (Pillar of Frost > Breath of Sindragosa,
  Combustion > Meteor > Scorch, Trueshot > Aimed Shot...) shows COMBO 1/3 over the box as it goes and COMBO! with
  a violet sweep and bonus points when finished; another spell or 6 s ends it quietly. Mined by
  tools/mine_combos.lua (300 s simulated fights, every spec) into Data/Combos.lua; 19 specs so far. Guide entry
  "Flow: combos" in 9 languages.
- 1.6.0.230: Look-ahead (slots 2-3): a SimC line uncertain now because of a hidden proc (buff.*), and not confirmed
  by the assistant or a glow, isn't confirmed by Blizzard's rules in later steps either. Elemental showed Lava
  Burst in slots 2 and 3 almost all the time (needs Lava Surge) while slot 1 never took it: "only the primary
  button changes". Minimap menu: Move the HUD (unlocks to drag; Edit Mode stays in Esc for taint reasons).
  User signed off 1.6.0.228 settings, preview, text sizes, Flow and welcome (2026-11-12).
- 1.6.0.228: Settings. Status & Help is one page with the live status, Report an issue and a full guide (Classic
  vs Flow, every tag, badge, bar and colour, what Flow smooths to stay fun, the grade); the empty Status and Help
  sub-pages are gone. Group pages (DMGAssist, Core, Flow mode & grades) say they hold pages (+ on the left) and
  have Open buttons for each. Display starts with Quick setup: Size (Small / Medium / Large / Custom) and Place
  (right of character / below / above the action bars / Custom); the rest is custom fine-tuning. "Spells,
  trinkets & potion" (renamed) has three headed parts: Potion, Trinkets (says when none are equipped) and Spells
  (says what the boxes do). Preview: the label's room fits its wrapped lines (it ran over the title), the
  CLASSIC / FLOW switch widens to fit its words (CLASSIC ran into FLOW), the BUFF corner tag is smaller, slot
  labels 9 -> 11, Flow streak text 15 -> 17, switch text 11 -> 12. Battle Shout report: from a 1.6.0.225
  session (fixed in 224).
- 1.6.0.227: our own right-click menu (minimap, potion picker) instead of Blizzard_Menu (taint into Edit Mode's
  layout dropdown, taint.log 2026-11-11); Flow notes re-apply the keybind size and colour when drawn (reused
  notes kept an old size: small keys next to large ones).
- 1.6.0.226: Runic Power: rune spells' negative costs are gains (importer: "-10 Runic Power", per spec with "w/
  Unholy Death Knight"), so Death Coil isn't held back for Runic Power you have. Flow says INTERRUPT! (was KICK!).
  Welcome: the style question is two cards side by side (Classic three icons / Flow lane with notes sliding in), a
  sentence each, "switch any time". Keep-up DoTs only when on the bar you see (key or visible button); pressing
  past one sets it aside (Guardian's Moonfire in Bear Form was the "wrong Ironfur icon, no key", report r158).
- 1.6.0.225: without a hero tree, SimC lists split by the hero tree's keystone talent (Arms: talent.demolish /
  talent.slayers_dominance; Fury: slayers_dominance / lightning_strikes) fall back to the first one that fits, as
  hero_tree.X splits already did. Arms ran entirely on Blizzard's simpler rules (slot 2 guesses, Battle Shout).
  Every-spec check: Fury 7 spells instead of 4, slot 3 always filled (was empty), majors used 1 instead of 2 in
  the 2-minute fight (the hero lists hold them for their windows; watch this).
- 1.6.0.224: a raid buff (Arcane Intellect) isn't guessed into slot 1 from Blizzard's list in combat (its aura is
  hidden there; Fire showed it while moving); Flow's action row stays empty before the pull (Blood: "DEFEND" out of
  combat); Flow draws "waiting for the resource" and guess notes at half strength, as the classic HUD does, and
  doesn't count them as misses (Unholy: Death Coil without the Runic Power).
- 1.6.0.222: a new spell in slot 1 flashes when ready even if the one before it was ready too (BM: "pops in
  without the flash"); Guardian uses Frenzied Regeneration while tanking whenever both charges are full (low
  health still shows it); the Watchdog shows as "DMGAssist Watchdog" in the AddOns list.
- 1.6.0.221: Black Arrow only above 80% / below 20% target health or with Deathblow (SimC 466930 effects #2/#3);
  a spell the game refuses with "Invalid target" is held for that target (Touch of Death on dummies); leveling
  mode never puts Blizzard's pick in slot 2 when it can't be used on this target. Marksmanship / Beast Mastery
  with a non-ranged weapon equipped: chat says the shots need a bow, gun or crossbow (the game marks them all
  unusable, so the display was empty). Cooldown Manager icons: no Blizzard Lua method called on them (taint).
- 1.6.0.220: Flow: the off-GCD pick (Ironfur) shows in the action row beside the low-health heal; that heal
  (always listed, shown by the game when you're low) used to hide it, so Guardian only ever saw Frenzied Regen.
- 1.6.0.219: Flow: out of combat a shapeshift / stance / pre-pull-only spell (Bear Form after a spec swap) is
  preparation and doesn't start it.
- 1.6.0.218: Flow judges a press by when its note reached the line (79 of 89 hits were "Good", none Perfect: a
  queued instant's cast event comes as the next GCD begins, and the HUD's wait then said 1.5 s).
- 1.6.0.217: grade: a break (6 s+ with no spell: between packs, a cutscene, a boss walking off) leaves the fight's
  length and its idle time is given back ("Always casting 33%" after waiting between packs); a Flow set ends even
  when it's too short to grade. Flow: a buff out of combat (Mark of the Wild) no longer starts it; notes come in
  inside the lane and fade in; the foot row's text never runs under the stars or the switch.
- 1.6.0.215: reports 2026-11-12 (Balance, dummies): Eclipse asked for during Incarnation from the pull before
  ("says to hit Q and I can't"): the blocked-while-active rule only counted casts since combat began, and dummies
  drop combat between pulls; and Celestial Alignment / Incarnation now start the Lunar and Solar Eclipse clocks
  for their duration (SimC sc_druid.cpp celestial_alignment_buff_t). A heal you cast isn't asked for again for 6 s
  (Regrowth stayed up through three casts while a golem hit). Flow: a hold bar stops at the lane's edge.
- 1.6.0.211: Flow mode: while waiting, the next press sits in the box on the left (the dark box starts right of
  it) and nothing freezes off the right edge (that icon blinked as it froze and came back: the "weird pulsing").
  1.6.0.213 puts the intended pulses back (briefly taken out in 1.6.0.211).
- 1.6.0.210: Flow mode (reports 2026-11-12): a Starfire begun right after slot 1 flipped got a red X ("it wants
  Q, I hit Q, it says I'm wrong"): a cast-time spell's press may now be decided up to 0.6 s before its bar began.
  Waiting is one rule: no spell for 6 s (none casting) = the arcade start screen out of combat, PAUSED in combat,
  notes frozen; any spell clears it (in combat with LET'S GO! / Back in the Flow!). Buffs out of combat no longer
  use up the start screen, and it comes back after every set.
- 1.6.0.208: Flow mode timing (report 2026-11-11, "lost a streak at 12... hit it right when it flashed"): a note
  that waited on the line while a Starfire was still casting counted as a quiet miss when the engine swapped it at
  the cast's end. Fixed: no quiet-miss clock while casting (the note now also waits for the cast); a press matched
  to a note that just swapped away bursts nothing; PRESS_WINDOW 0.35 -> 0.6 s (WoW's spell queue window plus a
  reaction). Every Flow judgement is now logged ("flow" in reports). The CLASSIC / FLOW switch: plain text, the
  mode you're in gold, the other grey, a thin gold line under it, the same in both modes.
- 1.6.0.207: Flow mode: pause after 6 s without a spell (next spell resumes), any spell starts the Flow and the
  press-start box goes in 0.15 s, the cast bar links the landing box to the next note, the grade box sits above
  the lanes.
- 1.6.0.205: Flow mode look (tested 2026-11-11): the action row is short, dark, coral-bordered (was a tall red
  bar over the lane); no DEFEND! on login (the low-health defensive no longer counts); big words in a thin outline
  (THICKOUTLINE looked blurry); "press start" on a dark gradient box above the notes, fading in 0.25 s; the
  CLASSIC / FLOW switch is at the bottom right in both modes.
- 1.6.0.204: Flow mode "press start" (READY, PLAYER ONE? / INSERT COIN / PRESS START until the set's first hit,
  then LET'S GO!); the grade box's Flow score line wraps inside the box instead of running out of it.
- 1.6.0.203: Game mode is now Flow mode (owner's pick): CLASSIC / FLOW switch, /dmga flow (/dmga game still
  works), settings group "Flow mode & grades", all 9 languages.

- 1.6.0.202: Game mode (report 2026-11-11, Balance on dummies): one note in the box (a note the engine moves back
  drops away and comes in again; waiting 1.2 s on the line first is a quiet miss); notes keep their real time
  apart and never touch ("5,6 right next to each other"); a "next" passed over 3 times hides (Moonfire parked
  mid-lane); a note is pooled once only (two notes could share one frame). The drum is now a CLASSIC / GAME
  slider switch above the HUD and in the lanes' foot row.

- 1.6.0.201: Game mode round 4 (docs/project/scope.md): landing spot + burst, live cast bar, lane dots, streak row
  under the lane, big but rare kudos, the action track for defensives / interrupts / items with timed boss-hit
  defensives and a red alarm. Fixed: a right cast-time spell showed a red X (judged at the cast's end); swapped notes
  overlapped the arriving one. Report decoder survives a note cut mid-character.
- 1.6.0.199: Game mode hold bars (casts yellow, channels blue, next note after them), flame notes (major cooldowns,
  x2), power mode (haste burst or a major cooldown: blue lane, x2). Spell data now flags channels ("chan", from
  SpellDataDump's "Is Channelled").
- 1.6.0.198: Game mode, round 3 (tested 2026-11-11: "the bounce is super annoying", two empty lanes, too small):
  one lane plus a bonus row (KICK! / DEFEND! / POWER UP!, grabbing one is a bonus), about 1.7x bigger, notes only
  move left (pause, never bounce), a wrong press shakes the note with a red X and it stays, a hit bursts the note and
  the next one keeps sliding.
- 1.6.0.197: SimC terms read (from sc_mage / sc_druid / sc_demon_hunter / player.cpp): scorch_execute.active
  (Scorch talent + Heat Shimmer or target <= 30%), energize_amount (the line's spell's gain), apex.N (the spec's
  tiered apex talent, from the trait tree), movement.distance (= target distance), soul_fragments[.total/.inactive]
  (Soul Fragments buff stacks or Spirit Bomb's cast count, else 0..cap). Every-spec check holds.
- 1.6.0.196: settings preview shows what each Display control does: a sample target-mode title, a sample boss
  call-out and sample keybinds while docked; Masque re-skins after size changes (the icons stayed small while
  only the box grew); Game mode's lanes take the docked HUD's place in the preview.
- 1.6.0.195: Settings regrouped (decided 2026-11-11): DMGAssist > Status & Help (Status, Missing keybinds, Help),
  Core (Combat, Display, Sounds, Integrations, Advanced, Spells & trinkets), Game mode & grades (Game mode switch,
  timing offset, records; Performance grade and its report). Builds fixed: kernel.org's Ubuntu mirror (apt checks
  Ubuntu's signatures), first nightly since 1.6.0.185 = 1.6.0.194.
- 1.6.0.191: Outlaw rtb_buffs read: Midnight's Roll the Bones is one buff rolled into 1-4 sets (One of a Kind
  1214933, Double Trouble 1214934, Triple Threat 1214935, Jackpot 1214937, sc_rogue.cpp roll_the_bones_t). Read
  when the game shows the set; else 1-4 while it's up (our cast within 30 s), 0 without it.
- 1.6.0.190: Game mode, round 2 (asked 2026-11-11): flash on the line when a note arrives; timing offset in ms
  (Settings > Display); score with a x1-x4 multiplier; ranks Bronze ... Mythic; 12 escalating streak words and 20
  judgement phrases that get more excited as the multiplier grows; sets that run across pulls until 20 s out of
  combat, then the grade shows the set's score / best streak / % perfect; waiting never breaks a streak.
- 1.6.0.189: Game mode (docs/project/scope.md "Game mode"): three lanes right to left into a hit line, notes timed to
  when each spell can be pressed, Perfect / Great / Good / Miss, streaks with stars at 5/10/25/50/100/200, best
  streak per spec, slots 2-3 held against jitter. Switch: drum button on both HUDs, /dmga game, keybind, minimap
  menu, Settings > Display, 4th welcome question. 24 new strings in 9 locales.
- 1.6.0.188: wrong-key hint. A wrong press on the key right next to the one slot 1 showed (5 for 6, Q for W, F2
  for F3), or the right key with a missing / extra Shift / Ctrl / Alt, shows "5 » 6" under slot 1 for 1.2 s
  (Display > Alerts and effects > Wrong-key hint, on by default). The fight's grade counts slips; the same slip 3+
  times becomes the tip ("you pressed 5 4 times when slot 1 showed 6 (Starsurge) - move the spell if the key is
  hard to reach"). Keyboard only (controller buttons have no neighbours). Translated in 9 locales.
- 1.6.0.187: slots 2-3 don't promise a second spender from a hidden resource after a pretend cast already spent from
  it unless the known minimum covers it (Balance AoE showed "Starfall > Starfall" from Astral Power "34 or more";
  following it ran dry). Engine 211 tests; every-spec check holds (Havoc / Survival leveling improved).
- 1.6.0.186: one defensive per hit - a defensive you cast covers the hit for its duration, no second one is asked
  for; heals (Regrowth, Word of Glory, Crimson Vial...) are only for low health, never ahead of a boss-mod hit (a
  Balance Druid at full health was shown Regrowth right after Barkskin, dungeon report). Defensives are timed to the
  boss's damage: DBM's timer counts to the cast's start, so the boss spell's cast time is added.
- 1.6.0.185: boss-mod defensives are timed from the defensive's own duration (spell data): shown at the middle of
  "time to press it" (2 s + 0.5 s) and "the hit still lands 1.5 s inside the buff", never earlier than 6 s, never
  later than the Big hit warning setting allows. Barkskin (8 s) now shows 4.5 s before a hit (was a flat 3 s).
  DBM test confirmed in game: all 7 test timers read with the right kinds, the interrupt timer becomes a call.
- 1.6.0.184: a boss-mod interrupt timer that runs out counts as the boss mod's interrupt call (some modules only
  time the cast; DBM's /dbm test does exactly that with "Important Interrupt"). Boss-mod timers, calls and DBM test
  starts are now in the /dmgw report (the first /dbm test report showed nothing to check against).
- 1.6.0.183: interrupts in delves (scenarios) work like the open world (any interruptible cast); only dungeons and
  raids use the boss-mod / Blizzard-important filter. Wind Shear never showed on Mind Flay in a delve.
- 1.6.0.182: no "not on your bars" / "no key" chat for 4 s after a spec, talent or spell-list change (switching
  Assassination -> Outlaw named Assassination spells against the new bars). In-game test plan: docs/project/test-plan.md.
- 1.6.0.181: when nothing at all can be shown, slot 1 shows the spell it's waiting for (shaded) instead of going
  blank: right after Fan of Knives every Assassination line was short of Energy and Blizzard's Mutilate sat in the
  GCD, so the bar blinked out after each press.
- 1.6.0.180: Thistle Tea 381623 is automatic unless the button choice (1298826) is known (the automatic talent
  wasn't readable on a class-trial character). "Not on your action bars" is said only when the line wants the spell
  right now; the login "N spells have no key binding" line is gone (it counted the other hero tree's and unused
  talents' spells). /dmga unbound and the settings page still list everything.
- 1.6.0.179: waiting for a resource, slot 1 shows the spell being pooled for (shaded) instead of Blizzard's pick when
  SimC's own line rules that pick out: Subtlety on 5 targets showed Gloomblade then switched to Shuriken Storm when
  the Energy came, 21 times in 3 minutes without a press.
- 1.6.0.178: Blizzard's assistant still naming a spell you released under 1.5 s ago is ignored (S.ASSISTED_STALE):
  after every Eternity Surge / Fire Breath it was read as "ready 10-28 s early", the cooldown was marked done and
  key 5 sat in slot 2 for most of its 30 s (Devastation). Saved corrections of -3 s or more are dropped once.
- 1.6.0.177: rogue finishers. SimC's cp_max_spend (the most combo points a finisher uses) and effective_combo_points
  (Supercharger as a range) are read; "talent.ancient_arts_3" (the Nth talent of a name, apex tiers) is read.
  Subtlety at 7/7 combo points showed Shuriken Storm forever, now Eviscerate. Thistle Tea with the automatic talent
  (469779) is never suggested. A missing buff/poison Blizzard asks for is explained once in chat and dropped for
  the fight after 20 s ignored. Windwalker's combo_strike (63 lines) is read from our own casts.
- 1.6.0.176: slots 2-3 spend hidden resources too: after a pretend Void Ray (100 Fury) the next isn't Void Ray
  again (the range is capped at the maximum before the spend). A major cooldown whose own line says "not now"
  isn't promoted to slot 1 from slots 2-3 (Subtlety's Shadow Blades blinked in every 4 s). Every-spec check:
  Devourer 2-3 majors and 3-4 spells (was 0-1, 1-2); Subtlety AoE and Preservation leveling slot 3 always filled.
- 1.6.0.175: Devourer DH on several targets follows Blizzard into Reap / Eradicate instead of sitting on Consume.
  A spell that "applies itself" for a GCD or less (Eradicate, Reap, Spinning Crane Kick...) is its cast, not the
  buff of that name, so buff.eradicate (Void Ray's) is unknown rather than "certainly down".
- 1.6.0.174: a long cooldown you cast a moment ago isn't offered again while our clock can't tell it's on
  cooldown (Havoc Metamorphosis flipping with Annihilation in slot 1 during Meta).
- 1.6.0.173: a spell on none of your action bars is never suggested (slot 1, slots 2-3, the defensive and
  off-GCD icons, keep-ups, buffs): the next one takes its place and chat names it once. Setting "Only spells on
  your bars" (default on); forms and setups with no readable bars are exempt. After a HOLD, GO is the instant
  green border only (no white flash fading over the icon); the keybind always draws above the flash and wipe.
  All 9 languages.

- 1.6.0.172: any cast of yours in progress keeps slot 1 when nothing else can be pressed (Blood Consumption
  emptied the bar). The no-key chat line also covers the small icons (defensive, off-GCD): Blood's Vampiric
  Blood. All 9 languages.

- 1.6.0.171: Bladestorm (and any channel) keeps slot 1 with HOLD instead of an empty bar while nothing else can
  be pressed. The early "press now" flash (latency + lead, for the game's spell queue) only applies to the global
  cooldown and casts; a spell waiting on its own cooldown flashes on time (early presses were refused).

- 1.6.0.170: Holy Judgment shown 3 s after every cast: a timing correction learned from one stale sample (our
  clock still ran from before the pull) is no longer learned (resynced only), the assistant's own earliness
  (~1.5 s, measured) isn't counted as our error, and saved corrections from fewer than 3 samples are dropped once.
  Grade popup hides when a fight starts; quick fights (under 10 s apart) chain into one grade, shown 10 s after
  the last or every 3 minutes (setting "Group quick fights", default on), so short questing fights get graded
  too. Feral: a press refused for Energy (or range, facing) no longer holds the spell back (only "not ready yet"
  does). Elemental: Spiritwalker's Grace / Hover / Spatial Paradox let cast-time spells stay while moving; an
  enemy leaving range a moment still counts 1.5 s (count no longer jumps 1..7 on the move). Slot 1 showing a
  spell with no key prints which spell it is, with its link, once (Surging Totem). Every-spec check: Blizzard's
  simulated assistant names spells up to 1.5 s early like the real one, baseline re-recorded fairly, new metric
  "shown ready while on cooldown". All 9 languages.

- 1.6.0.169: Hunter's Mark on bosses (all hunter specs, before the pull too, once per target; setting, default
  on). Healing support for groups (setting, default off): Discipline keeps Atonement up between big hits (Shield
  first, Radiance when several are missing), Mistweaver spends Renewing Mist charges. Cooldowns the data lacks
  (Void Volley) learned from the game's "not ready yet" refusals: each refusal is a lower bound, pressing until it
  goes through measures it. Fixed: since 1.6.0.168 Discipline's ramp Shield was moved out of slot 1 as a
  defensive (keep-up picks are never defensives now). Keep-up spells carry fallback cooldown / charge data
  (Renewing Mist was suggested every GCD in the check). Every-spec check: a fifth fight (boss, party of 5,
  healing support) where each keep-up must be cast. All 9 languages.

- 1.6.0.168: speed with nothing castable (BM Hunter without a gun dropped to 30 fps): each spell is checked once
  per decision instead of once per look-ahead step, and the enemy count (every nameplate) is read once per update
  instead of on every timing lookup. Worst spec 48 ms -> under 20 ms per update in the check; the whole check
  runs in under 2 minutes instead of 8. Area spells that hit only around you (Holy Nova, Arcane Explosion,
  Spinning Crane Kick, Whirlwind, ...) aren't shown when the game says the target is farther than they reach.
  HOLD on every channel you cast (Mind Flay, Volley, ...); the GO text is gone: slot 1's border flashes green
  when the channel ends, the keybind stays readable. Shadow Priest defensives: Power Word: Shield, Desperate
  Prayer, Vampiric Embrace and Dispersion come before Fade (Fade only drops threat). The every-spec check gained
  a "nothing castable" fight with a speed limit, and every spec now starts from a fresh load

- 1.6.0.167: every-spec sweep: Auto Shot and Bloodlust (and twins) never shown; anything in the "never press by
  hand" list is ignored even when Blizzard's assistant names it (interrupts come from the Interrupts module only);
  Stealth / Prowl not castable in combat while the game hides usability; leaps, steps and Evocation never forced
  in by waiting (G.NO_ESCALATE); one shared step for every path: a ready major cooldown (SimC or Blizzard's
  written rules) never waits behind Blizzard's pick (G.PromoteReadyMajor, replaces the leveling-only rule).
  Simulation made realistic: charges, no racials, a hero tree, an assistant that never names forms / buffs /
  interrupts. Baseline re-recorded against the old code first, then compared (method in docs/project/methods.md)

- 1.6.0.166: HOLD / GO on slot 1 while one of your channels runs (amber HOLD with the draining wipe, green GO
  as it ends): every channel the game reports, so no per-spell list; channels the spec's SimC list chains or
  interrupts on purpose (chain / interrupt / interrupt_if) get none. Setting "HOLD during channels"; all languages

- 1.6.0.165: every-spec check (tests/test_scenarios.lua + tests/scenario_baseline.lua, in check.sh / CI / the
  SimC sync): 40 specs x 3 simulated fights through the real pipeline; rules + per-spec baseline. Its first run
  found five more leveling-mode specs (Havoc, Arcane, Fire, Windwalker, Outlaw, and Guardian) whose ready major
  cooldown sat behind Blizzard's pick: fixed (any ready major cooldown in the list's three takes slot 1)

- 1.6.0.164: buffs in combat: when Blizzard's assistant names one of the tracked buffs (Lightning Shield, raid
  buffs, imbues) for a second, it is missing: slot 1 until cast (poisons: slot 2). Buffs are hidden from addons in
  combat; the assistant still sees them (Elemental, Lightning Shield dropped mid-fight and was never shown)

- 1.6.0.163: taint: the action bar highlight is placed at the button's screen position instead of anchored to
  Blizzard's button (Edit Mode, party frames and the bars ran "tainted by DMGAssist" again on 1.6.0.159; the
  highlight was the only new contact with Blizzard frames since 1.6.0.139). To confirm with Logs/taint.log

- 1.6.0.162: leveling mode (below max level with few of the list's spells, Blizzard's pick in slot 1): a major
  cooldown the priority list picks for certain keeps slot 1 (Summon Infernal sat in slot 2 for 40 s behind
  Blizzard's pick: its assistant never names major cooldowns), and slots emptied by taking Blizzard's pick out of
  the list are filled with what comes off cooldown soonest (slot 3 was often blank)

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
