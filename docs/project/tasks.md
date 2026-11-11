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

- Settings preview (asked 2026-11-11): icon size sliders resize only the gold box, not the icons; the target mode
  title and other text options show nothing in the preview, so toggling them changes nothing visible. Every
  Display control should change the matching part of the preview, with sample text where the real HUD has text.
- Game mode, after first in-game feedback: tune LOOK (4 s of lane), sizes, judgement windows (Perfect 0.25 s,
  Great 0.6 s); optional sounds (hit tick, streak chime, default off); an engine "commit" option measured in the
  every-spec check (fewer swaps vs. exactness).
- Balance on a dungeon boss: Sunfire shown 3 times while Wrath / Starfall were cast instead (grade "missed
  sunfire x3"); the target's DoTs are hidden in combat. Watch in LFR.

- Preservation: Fire Breath refused once (8.4 s, session 246) with no cast that fight; cause unknown, watch.
- SimC terms we don't read yet (tools audit, 2026-11-11): soul_fragments (Vengeance, Devourer), scorch_execute (Fire), energize_amount (Balance), movement (Warriors), tick_time, apex.N (always 0).
  Each turns its lines into guesses that only Blizzard's pick can confirm.
- The every-spec check can't play Devourer (Fury never changes in the simulation, so Void Ray forever). Model
  spent/gained resources per spell, or mark such rows as not meaningful.
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
