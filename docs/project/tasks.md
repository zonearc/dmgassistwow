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

- 1.6.0.336 (Subtlety fights 520-522): slot 2 68% (30-60 s 80%). Six presses refused "Not enough energy", each while
  slot 1 waited for Energy with no sign of how long. Slot 1's timing cue now counts a resource wait too: dimmed, an
  estimate counting down (our lower bound and the cost, halved, at the regeneration rate), ready the moment the game
  says usable, no early flash. The spending margin applied to slot 1 too (BelowCost), against the plan (slots 2-3
  only): 670 holds in 67 s on a lower bound that ran ~15 Energy low - removed from slot 1.

- 1.6.0.335: the cooldown event (15 a second, ~25 ms of every second in game) asked all 44 cooldown spells; the event
  names the spell that changed (3,412 of 3,421 in fight 518), so only that one is checked, or none. Cast inference
  from cooldown edges only while the game hides cast IDs (with readable casts a late edge inferred a false cast).
  Replays of 488 / 492 / 496 / 518 identical. Fight 518 (Balance, back-to-back pull): slot 2 70%, first 30 s 15/16.
  Owner, 2026-11-17: 70% is the bar for now - next: every class, the open issues, the shadow features on, release.

- 1.6.0.334: fight 509 (0 Celestial Alignment charges at the pull) still said "ready": the pre-pull charge reading
  was kept by spell ID and asked by the other one of the pair - now by charge group. Fight 508 (cooldown ready): slot 2
  0/7 in the opener, the live learner overriding SimC's sequence - the learner stays out of openers. Fury of Elune
  shown red (out of range) and cast anyway: a spell cast within a second of a red tint is not tinted again
  (range_wrong). Low power mode (owner: "should likely force classic, turn logging on its lowest, slow down some
  checks"): the Classic display, no decision traces, plus the earlier rate cuts. Marksmanship fights 510 / 512: slot 2
  57% / 35%, followed 59-63%.

- 1.6.0.333: fight 503 began with both Celestial Alignment charges spent before we watched (the game read 0 at the
  pull, hidden after); our count, with no cast of ours, said 2 - "ready", and the opener waited 46 s until the
  safety cap. Charges and the next recharge are now read before the pull and counted forward while hidden
  (S.chargesBeforeFight); the test fails without it. FPS on Standard (fight 506): 48 with it, 53-55 enabled but idle
  (~2.6 ms a frame; Hekili's own notes estimate ~5% in combat). Learner back LIVE on fresh scores (61% vs SimC 51%,
  n=126). Fight 506 slot 2 59%: 0-30s 11/20, 30-60s 11/15, 60-120s 20/36; misses Starfall/Starfire on hidden Astral
  Power (resource 8, state 19).

- 1.6.0.332: /dmga fpsprobe flashed Flow mode nonstop (owner, 2026-11-17: "would give someone with epilepsy a
  seizure"). The probe hid the window every frame and every decision (10 a second) showed it again; its test ran no
  decisions, so it passed. Now Flow's and the HUD's updates leave a window the probe hid hidden (ns.probeHide), a
  step changes only what differs, more than 2 visibility changes of a window within a second stops the probe and
  restores everything, the probe stops when the fight ends, and /dmga fpsprobe again stops it. The test runs real
  decisions during the probe and records every Show/Hide; it fails with the 1.6.0.331 code. Rule from this: any
  change that shows or hides something gets a test that drives the real updates and counts visibility changes.

- 1.6.0.331 (fights 492-496 on 1.6.0.330, base FPS 52-56 without DMGAssist; 44 with it, 49 low power, 53 window
  hidden): the cast event recounted every nameplate ~23 times (~2,000 game calls per cast) - the count is now kept
  for one event's handling (S.inEvent), as is Calibrate's profile key (219 asks in 14 casts); offline the cast event
  went 2,079 -> 141 calls, combat end 898 -> 117. Same-frame dedupe of the cooldown / usable scans was tried and
  dropped (two events in one frame can carry a real change; 7 tests). Fight 496 began with Celestial Alignment 49 s
  away, cast before we watched: hidden in combat, so the opener didn't pause - the time left is now read before the
  pull and counted down (S.busyBeforeFight). The learner went live on Balance at 58% vs 47%, compared while the stuck
  opener left SimC nothing; after the fix it was right 1/11, 0/3, 0/2 - its scores against SimC restart
  (L.VS_VERSION 2; what it learned stays). Tried and dropped: an opener step hidden only now (fight 492: Starfire
  behind Ascendant Fires after Eclipse) taken as the next step in the look-ahead - no change against real presses in
  five fights. /dmga fpsprobe (each part hidden in turn, the game's FPS per step, fps_probe line); Low power mode and
  Flow smoothness in Settings; a one-time tip after a fight under 45 FPS; help lines.

- 1.6.0.330: the first-minute instability was SimC's opener. Balance's opener is "run_action_list,name=opener,
  if=variable.opener", exclusive, and ends only when Celestial Alignment is up; SimC's fights start with it ready,
  ours don't. Fight 488 began with it 63 s away: the opener ran 64 s, slot 2 had no SimC answer (Blizzard's list,
  rules, guesses) and was right 12/37 when followed, 42/68 after. All recorded fights: 36% during the opener, 65%
  after; after it, SimC's slot 2 71%, the learner's 50%. Any list run on a plain variable is now a phase: paused
  while a major cooldown in it is > 5 s from ready (the regular list plays; the ramp resumes with the cooldown - on
  one target SimC casts Celestial Alignment only inside the opener, so ending it for good lost it, caught by the
  gate), ended when you press something else twice while it shows its cooldown, or after 45 s inside it (15 s cut
  the single-target ramp short and lost every cooldown in the simulator). It stays exclusive while it runs (letting
  the rest fill in mid-ramp spent Astral Power on Starfall). Replay 488: slot 2 vs real presses 44.7% -> 52.5%; 489
  (cooldown ready) unchanged. Baseline re-recorded for Balance aoe/group/lvl: in the simulator those fights start with
  Celestial Alignment down (it was cast in the fight before), and the stuck opener's repeated spell scored slot 2
  76/88/100%; now 67/80/79%. The simulator's player follows slot 1, so a stuck loop predicts itself; the real fight
  says otherwise - the in-game test decides. prediction_summary now has slot2_by_time (0-30/30-60/60-120/120+ s),
  slot2_by_phase and worst= (a stretch 20+ points below the rest). FPS (fight 489: 240 ms of every second = 77 -> 56
  FPS): the cooldown event handler asked every spell in the book ~15 times a second (25 ms/s), now only spells with
  a cooldown; /dmga lowpower (5 decisions a second, skipped when no event touched anything, at least every 0.5 s;
  Flow at 15; no recording). GetSpellInfo moved to the haste piece (its cast time changes with procs: 20 misses).

- 1.6.0.329: signals (Core/Signals.lua), shadow mode. Every game question belongs to a piece (resources, cooldowns,
  usable, auras, casting, haste, units, range, spellbook, overrides); a game event marks its pieces stale. Shadow
  mode still asks everything and counts where a kept answer would have been wrong (`signals` / `signal_miss` lines,
  /dmga signals). Fight 488 replayed: 3,746 cooldown misses at first -> 4, all from the replay (answers recorded per
  pass reach an event's handler a pass late; the replay now re-signals at the next pass). Rules found: an answer
  within 0.1 s of its signal isn't kept (a pass right after UNIT_SPELLCAST_START still read no cast); a readable
  cooldown expires when it ends (the GCD ends with no event); a hidden one at the GCD's end (max 0.25 s); a cast at
  its end time; haste re-asked at the pull (it turns hidden). Simulator realism: SPELL_UPDATE_USABLE / _COOLDOWN /
  _CHARGES / _ICON and UNIT_POWER_FREQUENT fired when the world changes them; the GCD readable (as in game); the
  scenario says the spec it plays (a spec re-check switched every druid to Feral). Shadow costs ~15% of a pass
  offline; live would skip ~230 of ~365 game calls a pass (units alone 510k of 540k asks). Unmapped calls left as
  always-asked: GetActionInfo, GetBindingKey, the assistant, CVars. Flow mode and the HUD timing draw at
  /dmga fps (default 30), the grade's clock 10 times a second. Next: in-game shadow pass, then live per clean piece.

- 1.6.0.328: the real Incarnation bug was charges - both entries are 1 charge / 180 s, in separate charge groups, so
  the Incarnation cast never spent Celestial Alignment's charge (the 1.6.0.327 cooldown fix didn't reach charged
  spells; its test passed without the fix). Pairs with the same charges and a recharge >= 60 s now share one group;
  the new test fails without it. The first version merged short pairs too and the all-specs gate caught Enhancement
  (shown ready on cooldown 13% -> 36%). /dmga margin on|off for in-game testing; spend_margin line per fight. Name
  under an icon on one line (Moonkin Form wrapped onto the streak). Simulator gaps behind this bug: fresh cooldowns
  every fight, no button/override pairs, no refused presses - next: the recorded spellbook and back-to-back pulls.

- 2026-11-16 fifth upload (fights 478-483, 1.6.0.326): Celestial Alignment still offered as ready after Incarnation
  was cast (481) and refused over and over (482-483). Cast as Incarnation 102560 (no cooldown in our data), the clock
  of Celestial Alignment 194223 (which has it) never started; the refusal hold used 102560's missing cooldown too.
  Both now take the cooldown from either of the pair, and the hold covers both. Replayed 481-483: slot 1 steady for
  the first 6 s (was a flip every ~0.5 s). Cost (Standard 478, 102 s): passes 85 ms/s, Flow drawing 48, HUD 14,
  events ~15; Enhanced adds recording ~48 (was 62). Open: text crowding under the Flow box (needs a close-up).

- 2026-11-16 fourth upload (fights 474-477, 1.6.0.325): "Standard" still recorded (an old /dmga record on set
  recordInputs; the dropdown didn't clear it) - Logging alone decides now. Cost line, fight 475 (81 s): passes 109
  ms/s (~12 ms each in game vs 3.5 offline), recording 62, Flow drawing 58 (1.2 ms a frame), events 41 (peaks 36),
  HUD 16 - ~29% of the CPU. Recording: question ids cached (no text built per answer); events timed per name. Early
  slot 1 swaps: Celestial Alignment refused at the pull (our clock said ready), held 0.5-3 s, back as a major four
  times in 5 s - a long cooldown refused now waits until the assistant names it or its cooldown (max 60 s) passes.
  Next: Flow drawing and the passes' game calls (per name in the next cost line).

- Core platform item (owner, 2026-11-16: "a dynamic system is almost necessary ... ensure this is a core part of the
  platform"): hidden-resource income learned by context (spell x target count x key buffs) from every proof the game
  gives, its spread kept per spec/loadout across logins, and a spending margin from that spread. Step 1 shipped off by
  default: Calibrate.NoteError (both directions) -> Calibrate.Margin, Engine.HoldForMargin in slot 1 and the look-ahead
  (DMGAssistDB.spendMargin; sim: SCEN_MARGIN=1). Measured: Balance 1 target 72.4 -> 72.4, 5 targets 46.6 -> 46.3 - no
  gain while the offline world's income is the addon's own model. Next: (2) the offline world's income from recordings
  and Warcraft Logs, with its real spread; (3) income per context + margin from its spread, judged per spec on slot 2
  and DPS.

- 2026-11-16 third upload (SavedVariables file, fight 469 on 1.6.0.323, 7 dummies, 269 s): slot 2 judged at the
  wrong moment for cast-time spells (a Starfire's press is its cast end, when slot 1 has moved on: the logged "slot 2"
  was the next spell's). Measured when each cast began: 54.5% (466, before) -> 60.4% (469). Diagnostics/Learner now get
  the slots from the cast's start; the replay counts presses the same way, and loads the learner/calibration memory
  once the loadout is known (it went into an "unknown loadout" store). Replay vs shown: slot 1 75%, slot 2 85%; replay
  slot 2 vs real presses 74.5% (47). FPS 76 -> 49 in game: offline the work is ~45 ms/s, the game reported ~235 -
  a "cost" line per fight now says where it goes (passes, events, per-frame handlers, recording). Candidates
  memoized (12% of a pass). Remaining slot 2 miss: after a Starfire, Starfall predicted and Starfire came (20) - the
  hidden Astral Power estimate.

- 2026-11-16 second recorded fight (Balance, 9 dummies, 316 s): FPS 59 -> 36 with DMGAssist. The grade's per-frame tick
  recounted all 40 nameplates (~330 game calls a frame, ~20 000 a second): per-frame code uses State.TargetsCached;
  answers that can't change within a pass are asked once per pass (U.passCache); a test runs the frame handlers with
  40 nameplates against a budget (the offline tests never ran OnUpdate, so they never saw it). Slot 2 (SimC's forecast
  right 44%): the look-ahead charged Starfall 45 after the first pretend cast while the game stated 34 all fight (a
  talent), so Starfire stayed in slot 2 - a cut held 3 s now applies to every pretend cast. Recording: costs (lists
  of tables) were written as "?"; cap 8000 -> 40000 lines (held 167 of 316 s); recordings kept for the newest 5 fights;
  the press log has shown2 (what slot 2 really showed). Upload the SavedVariables file instead of copying parts
  (tools/decode-export.py reads it). Next: replay this fight with the costs recorded; the offline world takes Astral
  Power income from the addon's own data, so an income the addon has wrong can't show offline (measure income from
  IsSpellUsable flips in recordings, feed it to tests/procs income).

- 2026-11-16 first recorded fight (Balance, dummies): Logging Standard/Enhanced switch on the main settings page (each
  fight recorded and numbered by itself); the recording now starts with the addon's state at the pull (replay of the
  first recording was 11% faithful without it); answers stored as table shapes (~10x smaller); each report part
  carries a length/checksum and END, and the report is decoded again in game before it's shown (the first report
  arrived one character short with no way to tell which part); a slot 2 / 3 press now ends the Flow streak like any
  other wrong key ("sometimes it ends the streak, sometimes not"). Next: replay the next Enhanced fights.

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

- Blood Death Knight: a Bone Shield count beside slot 1 (like Ironfur's). Method / Icy Veins: keep it above 5
  stacks with Marrowrend; SimC's list asks for Marrowrend under 6 and already shows it. Bone Shield charges are
  spent by hits taken, so they can't be counted from casts like Ironfur; needs the game's own aura count (hidden
  in combat in 12.x: check whether a hidden count can still be drawn as text).
- Blood reports (2026-11-12): 646 of ~1300 picks were the gap closer (away from the dummy for ~70 s); Lichborne
  offered at low health after Icebound Fortitude was spent (general defensives list, last resort): fine.

- Regression guard across specs (owner, 2026-11-12: "downstream it broke something on another class and spec"):
  a per-spec golden snapshot in check.sh (queue picks in scripted fights + each spec's resolved defensives) so a
  change that alters any other spec's output fails until its new output is reviewed and accepted.
- WoW Forever: never logged in yet. Mitigation profiles are Midnight only (Forever falls back to the old class
  list); Forever needs its own data/mitigation/forever/ once its spell data dump is checked.
- Racials: SimC lists carry the damage racials (Berserking, Blood Fury, Fireblood, Ancestral Call, Arcane Torrent,
  Light's Judgment, Bag of Tricks); shown only for that race and when on your bars. Confirm on a race that has one.

## Reference model and offline grader (owner, 2026-11-14) - IN PROGRESS
Principle: the owner presses what DMGAssist shows, so his presses can't be the reference ("that assumes the
source material is correct"). Build an independent reference per spec and grade DMGAssist against it, offline,
for every spec, before asking for more in-game logs.
- Evidence so far: Balance with the owner's exact talents (SimC talents= his loadout string, 6 targets, 100 fights)
  casts Sunfire 0.4/min; DMGAssist had him at 3.7/min (9x). Outlaw (SimC reference talents): DMGAssist ~40% fewer
  finishers (Dispatch 10.0 vs 16.2/min, Between the Eyes 5.1 vs 9.4), Adrenaline Rush ~0.1 vs ~1.9/min.
  Top players' next-press pairs predicted the owner's presses worse (Balance 28-39%, Outlaw 15-37%) - expected
  now: his presses are DMGAssist's output, not the reference.
- 1. Reference per spec (data/reference/<spec>.json), ~10 top players per spec (raid single target and Mythic+
  AoE apart, grouped by talent build) + SimC with the same talents and target counts: casts/min per spell,
  openers (first casts), pairs / triples, what is cast inside burst windows (Bloodlust, major cooldowns), seconds
  from ready to use for cooldowns, resource at each spender (pooling), DoT refresh timing, out-of-combat drain
  (tools/wcl-ooc.py), gains / passive income (tools/wcl-resources.py). Players vs SimC gives the realistic margin
  ("top players reach ~95% of SimC").
- 2. Offline grader: the scenario harness gets a real world model (resources from gains / costs / passive /
  regen, cooldowns, DoTs with durations, target counts), runs DMGAssist for every spec at 1 / 3 / 5+ targets and
  produces the same statistics; scored against the reference, biggest deviations listed with the APL line that
  chose the spell. Runs in check.sh: a report first, then a baseline that must not get worse.
- 3. In game: the same statistics from each report against the reference (owner's build via anchor_summary).
- 4. Learner priors: reference openers / pairs for the first minutes, the owner's own data after.
- Also open from this round: out-of-combat model into the addon (replaces 1.6.0.273's "Astral Power full after
  5 s": top players' Astral Power drains ~2.7/s, fastest ~5/s, settles ~20 with the pre-cast); Sunfire 9x;
  welcome page + store description on self-learning; racials checked in SimC (no passive regen racials; haste
  racials and Arcane Torrent only).

## Two paths for accuracy (owner, 2026-11-14): with and without the Cooldown Manager

"Make sure the availability of it increases our accuracy, but continue to improve accuracy without it as well in
case someone refuses to turn it on. Both are valid."
- [ ] Measure the gain: each fight's prediction_summary says whether Cooldown Manager facts were used (and how
  many); reports compare slot 1 steady / slot 2 right with and without.
- [ ] Offline grader runs every spec twice: procs visible (as with the Cooldown Manager tracking the key buffs)
  and procs hidden (as without); both scores are tracked, neither may regress.
- [ ] Without it: keep improving the hidden-proc model (proc rates from top players' logs, Blizzard's assistant
  and glows as signals, "?" in slot 2 for a coin flip) - the default path for everyone who leaves it off.

## Proposed (waiting on a decision)
- Prediction plan (owner, 2026-11-13), in order: (1) measurement (1.6.0.252); (2) slot 1 commitment (built 1.6.0.253): keep the
  shown spell until pressed while its SimC line still holds, switching only for situations (interrupt, defensive)
  or a line that turns false: UX over the last bit of optimisation; (3) learning (shadow mode built 1.6.0.255), slots 2-3 only (never slot 1, so
  it cannot cost damage): per spec + talent loadout, damage rotation only (no defensives, trinkets, potions,
  interrupts, tank mitigation); patterns = last 1-2 presses + readable state (combo points, lit buttons, target
  count) -> next press; used once >= 20 samples and >= 90% confident and beating SimC's forecast there; kept across
  sessions (SavedVariables), recent fights weigh more, a pattern whose accuracy drops is dropped and relearned
  (hotfixes, talent changes); a "?" on slot 2 for true coin flips.
- Shared prediction baseline (optional, owner 2026-11-13; build only if it shows benefit): opt-in upload of
  learned patterns by a companion (tools/send-logs.py reads SavedVariables), combined per spec + talent build into
  a reference file shipped with each release, so a new install starts from what everyone learned. Worth it only if
  local learning works and the combined patterns predict better than one player's own. Score boards: dropped
  (self-reported scores can be faked; a key inside the addon can't stop that, its code is readable by anyone).

- Patch watch + release channels (owner, 2026-11-12):
  - Every other Tuesday (patch day): pull the new game data (SimC SpellDataDump / class modules, already fetched
    by the nightly; Wago DB2 tables as a second structured source) and the hotfix notes (Blizzard news JSON,
    Wowhead RSS, Warcraft Wiki), diff spells / costs / cooldowns / defensives against the last run, write an
    impact report per spec, fix what needs fixing, release an alpha.
  - Channels on GitHub + CurseForge: alpha after a patch for X days, beta for a week once issue reports settle,
    then release when reports stop.
  - Issues: fix substantive ones that come with a valid log within 72 h; never guess at reports without a log;
    never add feature requests without the owner's approval; a weekly feature-request list for review.
  - Expansions: v1.x = Midnight, v2.x = the next expansion (beta access, a build per beta update); one addon that
    detects the client, or separate lines.
  - Needs: network access to blizzard.com / wowhead.com / wago.tools (blocked in this session), CurseForge
    release-type support in the release workflow, decisions on X days and on one addon vs separate lines.

## Open: needs in-game testing (built, not yet seen in game)

- [ ] Cooldown Manager (1.6.0.281): Starweaver's Warp / Weft (not talented) no longer suggested; flips per icon.
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

- Input recording and replay (owner, 2026-11-16: "design ahead of time to make it easy and robust what I can export
  from the game so you have literally everything you need"; "as new patches come in ... model out changes").
  * Core/Record.lua (`/dmga record on`): each fight, every answer the game gave (through U.Call / U.Get), only when it
    changes, every event the addon handled, and a header (version, spec, client build, haste, the talent loadout
    string, the spellbook with swapped buttons, the talents as read, the settings). Kept per fight in the Watchdog
    (DMGAssistWatchdog.Record, beside the decision log) and exported with it. UI objects (frames) aren't recorded.
  * tests/replay.lua + tools/replay.py: a recorded fight decided again by the current code - "same as shown" (92% on
    an offline Feral fight, 81% Balance: the learner's memory and the addon's timers aren't recorded yet) and slot 2
    against the presses really made.
  * tools/calibrate.py: the owner's timing, presses that weren't slot 1, proc glow rates, against the offline game's
    numbers. tools/score.py: every spec's slot 2 and rotation match, saved and compared with the run before (the
    harness for patches). docs/project/tester-design.md: the whole loop; docs/project/test-plan.md: the session.
  * `/dmga mark <name>`: a named mark (and in the recording), to tell the tests apart.
- 1.6.0.318+: Toward 80% - and the score found to be partly fake (owner, 2026-11-16: "Try to get it to 80").
  * tools/rotation-check.py: the offline cast mix per spec against top players' (Warcraft Logs). Slot 2's accuracy
    alone rewarded predictable wrong rotations: Protection Warrior "99%" was Champion's Leap 91% of its casts (an
    effect, not a button: the offline spellbook took names with no cast entry - fixed), Blood "57%" was Marrowrend
    spam with no Heart Strike. Average match 0.42; worst: Protection / Retribution Paladin, Demonology, Elemental
    (their secondary-resource spenders hardly cast offline) - the next work.
  * The assistant's pick says a buff is up, not how many stacks: reading it as 1 stack kept Marrowrend in slot 1.
  * Data/CastAuras.lua (Warcraft Logs): a buff a cast always brings (Marrowrend -> Bone Shield, which the spell
    data doesn't link): its clock starts on the cast; stacks stay unknown; "ours" (down when never applied) only when
    nothing else brings it (Clearcasting also procs at random).
  * Offline the world keeps buffs (casts' auras, the logs' links with stacks per cast, procs) and its assistant reads
    them: with no buffs offline, Blood's assistant asked for Marrowrend forever.
  * Learner: per situation, the learner takes slot 2 where it has been right more often than SimC's forecast (2+
    presses ahead, 6+ compared, 60%+ the same way).
  * Scoring run (30 specs x 3 seeds, human): 70.5% - lower, honest; rotation match is now reported beside it.
- 1.6.0.317: Procs work like the game's, the player is human, and glows tell the addon which proc is up (owner,
  2026-11-16: "make the procs work like the ones in game where me casting x spell makes clearcasting proc ... same
  with resets ... occasionally press the wrong spell").
  * tools/wcl-triggers.py: per spec, each buff application put on the cast just before it -> chance per cast (Rip /
    Ferocious Bite -> Predatory Swiftness 92-99%, Shred -> Clearcasting 27%, Swipe -> Gore 26%) plus a background
    rate (auto-attacks); resets: the buff seen before a spell's early casts more than before on-time ones, or acting
    on it in the game data. Offline, every cast rolls its procs; a reset proc ends the cooldown.
  * Procs the rotation lists check now light the spells they act on (game data, data/aura-affects.json), offline and
    in Data/ProcGlows.lua for the addon: a lit button says the proc is up; once a proc was seen lit this session, a
    dark button says it's down (not before: not every proc glows in game). Feral 42 -> 55, Arcane 56 -> 62, Unholy
    57 -> 62, Assassination 54 -> 58 offline; the drops elsewhere are the offline game's new procs (Affliction's
    Shard Instability 85 -> 64, Fire 71 -> 62), the same with the addon change off.
  * --human: the owner's measured delay after the GCD and 10% presses of something else (slot 2 40%, the same spell
    28%, other 32%, as in his fights). Scoring run now: 30 specs x 3 seeds x human: 71.5 -> 71.3 (harder world).
- 1.6.0.311: Random procs in the offline game (owner: "Warcraft logs can show us how often they generally happen ...
  determine procs exist, execute at random and push the results down again and then have to fix it up").
  * tools/wcl-procs.py: every buff on top players in raid fights, applications per minute (data/proc-rates.json);
    tools/proc-map.py: auras that make spells free or instant, from the game data (data/proc-map.json);
    tools/build-procs.py: per spec, the ones acting on its spells and not cast by you -> tests/procs.lua (57 procs,
    26 specs).
  * Offline, each is rolled every tick at its measured rate (fixed seed): while up the spells glow (the game's signal
    the addon reads), cost nothing / cast instantly / the button swaps; a cast uses it up. Average 79.9 -> 74.4.
  * Slot 2 waits up to 2 s of Energy / Focus regeneration for a spender (was 1 s): Feral 31 -> 45, Windwalker 88 ->
    81, average +0.3.
- 1.6.0.310: The offline game made honest (owner: "fix it in sims so we are forced to fix it before it goes in game").
  * Button swaps from the game data (tools/override-map.py -> Data/Overrides.lua): Metamorphosis turns Blade Dance
    into Death Sweep for 20 s, Ascendance Stormstrike into Windstrike... Offline, a swapped-in spell is castable only
    while its aura is up, and its cast puts the button on cooldown. In the addon: the proc-only check (Rushing Wind
    Kick) now uses this list instead of a guess, and a swapped-in spell's cast starts its button's cooldown clock
    (Windstrike -> Stormstrike, Death Sweep -> Blade Dance).
  * The offline guess at proc-only spells had blocked core spells in most specs for every graded fight (Eviscerate,
    Backstab, Kill Command, Barbed Shot, Colossus Smash, Whirlwind, Rake, Stormstrike, Crash Lightning, Blackout Kick,
    Metamorphosis, Eye Beam...): removed. Brewmaster 55 -> 95, Enhancement 76 -> 82, Arms 44 -> 51; Havoc 72 -> 66
    and Feral 50 -> 37 are now honest numbers to fix.
  * The offline spellbook takes each name's own button (Havoc's Metamorphosis list starts with Vengeance's ID; Berserk's
    with another spell's), and resource maximums follow talents (tools/max-resource-map.py: Subtlety 7 combo points).
  * Scenario baseline updated: Havoc slot 2 and leveling numbers, Fury spells pressed (Crushing Blow / Bloodbath only in
    Recklessness now), Windwalker flips, small "shown ready on cooldown" rises from hasted vs unhasted charge clocks.
- 1.6.0.308: Real-fight checks of every spec's spells, and the offline average past 80% (78.8 -> 80.4).
  * Windwalker: a spell that only exists while a buff of its own name is up (Rushing Wind Kick) had the game's
    "not usable" overruled whenever Chi was 2+ (the hidden-points override, proven only for Rogue combo points):
    it sat in slot 1 for whole offline fights. Now the game's answer stands for such spells unless they spend combo
    points. Windwalker 36 -> 94 offline. Hammer of Light, Void Volley and the like are covered by the same rule.
  * Spells top players never pay for (tools/wcl-spellcheck.py, 2 raid fights each, 0 of every cast): Havoc's Throw
    Glaive (data 25 Fury), Windwalker's Spinning Crane Kick (40 Energy), Fury's Execute (20 Rage), Protection's
    Thunder Clap (20 Rage). The cost is removed (resource-gains.json "free", applied by the import and
    tools/fold-measured.py). Windwalker AoE 50 -> 67 before the fix above.
  * Cooldowns that reset or come back far sooner than any fixed cooldown (median recast under 60% of ours, beyond
    what timing learning may correct): Havoc Death Sweep, Elemental Blast, Arms Mortal Strike, Fury Raging Blow /
    Crushing Blow now start "Blizzard decides" (volatile), as Mangle did. No offline effect (the offline game has
    no resets); in game slot 1 follows the assistant for them.
  * Measured income now in Data/ResourceTargets.lua for Unholy (10.7 Runic Power/s; data 1.9 - Unholy 61 -> 81
    offline), Elemental (12.4 Maelstrom/s on 5), Shadow (Insanity was read 100x too high: logged in hundredths),
    Guardian (tanks from raid fights: Rage from being hit), Havoc.
  * Offline artifacts found and left (they don't happen in game): Havoc AoE (the offline game calls Death Sweep
    castable outside Metamorphosis), Subtlety single target (the offline player builds at 5 combo points).
- 1.6.0.305: Toward 80% slot 2 offline, every spec (owner: "average across all classes ... 80% min", then "how
  consistent are the offline tests with the game"). Offline average (30 specs, 3 x 1 + 3 x 5 targets): 72.7 -> 78.8.
  * Energy and Focus had no count at all (hidden in and out of combat; only "the dearest spender you can afford"):
    now counted from full, with their measured passive income (excluded before). Subtlety 61 -> 89-95, Beast
    Mastery 76 -> 89, Windwalker AoE 60 -> 77-96 offline. The game's answers win over a count that contradicts them.
  * Regenerating spenders a second of regeneration away are what slot 2 offers (you wait for them).
  * Blizzard's rules no longer confirm an uncertain SimC line in slots 2-3 (offline right 31%; the owner's Balance
    fights 20-46% vs 42-57% plain SimC). Not in leveling mode. Offline +4: Guardian, Affliction, Elemental,
    Destruction, Retribution, Balance, Shadow.
  * Warrior Rage: auto-attack Rage is not logged as gains, so tools/wcl-income.py measures total income from each
    cast's logged amount and cost: Fury 33/s on a boss (data 15.5), Protection 15 (11.7), Arms 10.7 on one target
    falling to 7.7 on five (no target scaling, as the owner's notes said). tools/build-resource-targets.py now builds
    Data/ResourceTargets.lua from both measurements (known-bad ones left out).
  * tools/wcl-spellcheck.py: per spec, real time between casts vs our cooldown/charges, cost paid / free share vs
    our cost (the Restless Blades / free Starfall kind of misunderstanding) - to run when the API allows.
  * Offline world: the spellbook takes each name's castable entry (Arms single target was a fake 100%: with the real
    IDs 32%); a slot 1 the game won't cast for 2 s is skipped like a player would; per-second power trace
    (SCEN_POWER=pt).
  * docs/project/sim-vs-game.md: the known differences between offline and the game, what each costs in game, how
    a report shows it, what was done ahead of time.
  Still low offline: Windwalker 36 (an ID mismatch shows proc-only Rushing Wind Kick forever - offline only), Arms
  44, Feral 50, Brewmaster 52, Assassination 55, Unholy 61. API-throttled, still to measure: Havoc / Guardian /
  Protection / Shadow / Elemental income by targets, wcl-spellcheck for every spec.
- 1.6.0.300: Cross-spec pass after Balance (owner: "use warcraftlogs to find similar issues for the other specs").
  Found with the offline fights (tools/sim.py, all 30 specs with a reference, 3 single-target then 3 five-target
  fights in a row) and Warcraft Logs:
  * Six specs had no measured resource income at all: Death Knight x3, Demon Hunter x3 (wcl-resources.py had only
    their out-of-combat drain). Havoc's Fury comes ~30/s with no cast (Demon Blades): our count had 0, so Havoc waited
    for Fury forever (offline slot 2 0%). Measured and folded into the spec data (new tools/fold-measured.py: the
    measured numbers only, the local SimC copy lags the shipped data). Havoc 0% -> 82%, Frost DK 54 -> 74, Unholy 41
    -> 53, Blood 58 -> 65 (offline, average of the six fights).
  * The look-ahead dropped every buff fact it hadn't timed itself (game reads, Cooldown Manager, clues): slot 2 said
    Lightning Shield (up all fight) in 35 of 66 Elemental presses. Now an aura up with a known end stays up until
    then, one with no known end stays up if it lasts 30 s+ (State.AuraState). Elemental single target 33 -> 51.
  * The in-play fit (1.6.0.297) had a double count: fitted after combat, when the data's passive income reads 0, it
    learned the whole income again (offline Devourer 92% -> 43% by the third fight). Each fight's timeline now keeps
    the income our count took during it; the look-ahead adds only the fit's part beyond the data's income; the
    search tries the rate before per-spell extras, prices each point of extra, weighs overshoot 3x; and a fit is
    used only once fitted on earlier fights it cuts the latest fight's stray by 15%+. Fit on vs off over all 30 specs:
    neutral to positive (72.6 vs 72.7 average; Balance 8 targets 37.8 -> 69.4 -> 79.6 over three fights).
  * Resource income by target count (tools/wcl-targets.py, Dummy Dome) for more specs - the 5-target fights came back
    empty because the player was picked from the whole report, not the fight (friendlyPlayers now). Blood's Runic
    Power with nothing cast: 1.5/s on 1 target, 4.6/s on 5.
  * Offline world fixes (tests only): Destruction's Chaos Bolt was treated as proc-only (a 6 s effect shares its
    name) - cast-time spells are never proc-gated; Soul Shards income from the casts' logged amounts
    (tools/wcl-castdelta.py: resources not logged as gain events, Soul Shards and Essence - cost paid per cast and
    how often free, against our data; its per-cast gains are unreliable where casts come at a steady pace).
  Offline average over the 30 specs: 68.5% -> 72.7% (part of it is the offline world fixed, not the addon).
  Income by target count now also for Blood, Frost DK, Devourer, Vengeance, Fury warrior (Data/ResourceTargets.lua;
  Arms left out - 0.12/s on 5 targets vs 0.70 on 1 isn't believable; Havoc, Guardian, Protection warrior, Shadow,
  Elemental: the Warcraft Logs API throttled the run, to measure again). Fury warrior offline 55 -> 74.
  Still weak offline: Unholy AoE (dread_plague.active_dots unknown), Arms AoE (Rage bounds straddle the cost),
  Windwalker, Fury, Brewmaster, Retribution ~50-57%.
- 1.6.0.299: Offline fights that measure slot 2 like the game (owner: "improve the offline testing system so you can do
  more without me"). tools/sim.py <spec> --targets 8,8,8 --fight 180 [--log file] runs the graded scenario mode
  (reference talents, hidden resources, the game's affordability answers following a true resource world whose
  income by target count comes from Data/ResourceTargets.lua; past the measured counts it grows by the last step,
  SCEN_FLAT=1 keeps it flat) and prints slot 2's accuracy per fight; fights run in order in one session, so the
  in-play fit learned in one is used in the next. --log writes the fights as a decoded report (the addon's own lines
  + casts): why-report.py, prediction-report.py and resource-replay.py read it like a real one.
  First results, Balance at 8 targets, three fights in a row: slot 2 37.8% -> 68.4% -> 79.6% (flat income past 3
  targets: 37.4 -> 63.7 -> 67.0); one target after those: 59.4 -> 72.9. The first fight matches the owner's
  in-game 37-45%. The remaining misses (why-report on the log): Starfire not reached - a Starfall line above won.
- 1.6.0.298: Resource income by number of targets, from Warcraft Logs (owner: "can't we guesstimate the astral power
  generation ... I thought all the combat logs at warcraft logs would help us"). New tools/wcl-targets.py reads
  Dummy Dome (target-dummy fights with 1, 2, 3, 5 targets; no rankings there, so recent reports are searched for the
  spec's player by icon). Balance: Starfire gives exactly 12 a cast at every target count; what grows is Shooting
  Stars (procs from damage over time): Astral Power with nothing cast ~1.7/s on 1 target, 3.1 on 2, 5.3 on 3; Starfall
  paid ~40 a cast on average (free / cut ones included). Written to Data/ResourceTargets.lua; State.PassiveGain uses
  it for your target count (the flat raid average, 5.1, counted 3x too much on a single target: Starsurge promised
  early). More targets than measured: the most measured, the in-play fit adds the rest - and that fit is now kept per
  target count (1, 2-3, 4+), so one made on 8 dummies isn't used on a boss. The 5-target fights came back empty
  (to look at).
- 1.6.0.297: Astral Power, from the first why traces (owner's 1.6.0.296 fight 459, 216 s AoE: slot 2 45%, n=127).
  tools/why-report.py grouped the 78 slot 2 misses: 31 "Starfall: not castable (power)" - every one with our
  Astral Power at 12-30 when the game had just allowed Starfall; 21 Starfire lines false (APL detail, same cause
  underneath: with Elune's Chosen the AoE list casts Starfall whenever it is affordable, so slot 2 is the count).
  The count fell 30-45 short with nothing cast between (three Starfalls in 2.5 s, no builder). Causes:
  (1) every Starfall charged 45, free / cut ones too (procs, Incarnation). Now the game's cost is read in combat
  every pass (State.ReadLiveCosts; secret: the usual cost) - a free spell neither spends from the count nor proves
  it (the game "allowing" a free Starfall was taken as proof of 45); in the look-ahead only the first pretend cast
  gets the cut. Cost unreadable and the spell lit by its proc (the border; it often goes a moment before the cast
  event): free (Clues.OnOwnCast). cost_live lines log every cost that differs from the usual one.
  (2) what builds Astral Power beyond our data: offline, new tools/resource-replay.py replays a fight's casts, proc
  borders and the game's answers and scores resource models. Fits agree over four fights: on 8 targets Starfire
  builds ~16-22 (data 12, from raid logs), Fury of Elune ~20-40 and Incarnation ~20 (data 0), ~3/s more by the
  second. A model fitted on one half of fight 459 cut the other half's error 321 -> 87 and 384 -> 166. In game,
  Calibrate section 3 now keeps each fight's timeline (casts with what our count did, every answer the game gave -
  not only the corrections) and, at the fight's end, replays the last 3 fights to fit an extra per spell and a gain
  a second (coordinate search; 0.25 s at 3 x 1200 events). The count and the look-ahead use 75% of it once 20
  answers back it; fit_summary / model_at_pull show it. resource-replay.py --learn runs the same fit on recorded
  fights, fight by fight. Older hidden extras (learned with free spells charged) are reset (store version 2).
- 1.6.0.296: Blind spots of the same kind as 1.6.0.295's: values learned between fights now show. Each fight logs
  model_at_pull_summary (every spell's cost and gain as the look-ahead uses them: live / data cost, tooltip /
  measured gain, calibrated extra; Cooldown Manager on / off / ignored), so two fights' starting numbers can be
  compared; gains_learned names the spell and old > new. Caps that cut a fight's evidence short raised:
  steady_release 40 -> 400, floor_raised 10 -> 100.
- 1.6.0.295: Why traces + two Astral Power causes found in fight 455. (1) Owner: "log the WHY, not THAT". Until
  now only slot 1's decision was traced, at most 40 per fight, and slot 2's look-ahead decision never: every slot 2
  miss had to be guessed at. Now every change of slot 1 or slot 2 in combat logs decision_trace (slot 1) and
  ahead_trace (slots 2 and 3: the pretend casts, the clock, each power's change and bounds), each line with
  castable / why, the power behind a "power" refusal (cost, now, ahead) and the values its condition read; logged
  as changes from the previous trace, split in parts under 2000 characters; 400 per fight (/dmga why n|all|off).
  Reports may now be up to 8 parts. New tools/why-report.py: each slot 2 miss as one case (what slot 2 showed,
  what was pressed, the trace showing then, the winning line and every line of the pressed spell), then the misses
  grouped by reason. floor_capped logs once per new cap (was 93-135 identical lines a fight).
  (2) Fight 452 -> 455: after Starfire, slot 2 said Starfall 10 times (8 right) in 452 and Starfire 33 times (23
  wrong) in 455. The look-ahead's Starfire gain went 22 -> 17: the tooltip was re-read after 452 (gains_learned
  n=1, 17 -> 12) and the calibration's extra (+5, measured on top of 17) stayed. The extra is now kept as what a
  cast really built (data's gain at the time + extra), so a changed tooltip doesn't move it. Starfall's look-ahead
  cost was 34 in one fight and 45 in the next: live costs are read after each fight, buffs included; now the
  highest cost since the last spell / talent change is used.
- 1.6.0.294: Owner's 1.6.0.293 fight 455 (270 s AoE, every slot 1 pressed): slot 2 37% (n=149), slot 1 steady 63%
  (63 changes in 148 windows), cdm 360 checks / 30 wrong (8%, was 13.6%). Top misses are a phase flip in the
  Starfire / Starfall alternation: slot 2 Starfall, pressed Starfire x33 and the reverse x33. Owner's question: was
  slot 2 better before the Cooldown Manager? History says yes: Balance slot 2 57% (1.6.0.26x), 47% (1.6.0.287,
  first fight with the Cooldown Manager trusted), then 36% / 36% / 49% / 37% (288, 291, 292, 293). Other changes
  landed in the same window (Astral Power bounds + calibration, oracle learning, look-ahead affordability), so the
  Cooldown Manager is not proven to be the cause. New `/dmga cdm ignore | use`: fights without its readings on the
  same version; `prediction_summary` ends with `cdm=used|ignored|off|dropped`, so the two modes are compared
  directly. Next: one fight each way, then cut whichever change costs accuracy.
- 1.6.0.293: Two fixes from the owner's 1.6.0.292 fight 452 (slot 2 49%, slot 1 steady 93%, 23 state misses, mostly
  "predicted Starfire, cast Starfall"). (1) Slot 2 never offered a spender the player could not afford NOW, even
  after the pretend builder in slot 1 paid for it: the look-ahead returned "starfall castable=false(power)". New
  G.AffordableAhead: affordable in the look-ahead when the current power (or, hidden, the low bound - or the middle of
  the bounds after a pretend builder) plus the pretend gain covers the cost. (2) Cooldown Manager reads graded 13.6%
  wrong (36 of 264), close to the 20% cut-off: the generic Eclipse icon was compared with the readable buffs by
  its own name "eclipse", while the buffs are eclipse_lunar / eclipse_solar. Grading now counts the buff as up under
  any of the icon's names or aliases (M.Candidates). Tests for both.
- 1.6.0.292: Root cause of Balance "Starfall > Starfall" found with 1.6.0.291's la= trace (owner's 283 s fight, slot 2
  36%, n=163; the report came whole in 4 parts). At those presses slot 2's step started from Astral Power 66-76
  AFTER a pretend Starfall (cost 34 live), i.e. "100" before it, while the real value was ~40-60 (3-26 after the
  cast). Source: the assistant oracle (Clues.ObserveAssisted) learned the FIRST Blizzard line for the named spell as
  true - Balance has Starfall "active_enemies>3&astral_power>=90" and later plain "active_enemies>3", so every
  Starfall the assistant showed became "Astral Power 90+". Never graded: AP is hidden all fight (assisted 0 checks).
  Now a spell's line is learned as true only when it is the only one of its lines that could hold. Affects every
  spec whose assistant list names a spell more than once. Test on real Balance data (fails without the fix: 90).
  Scenario baseline updated: Arms st slot-2 25% -> 75%, Havoc / Feral / Outlaw better; leveling Arms (one spell)
  leaves slot 3 blank instead of guessing a third Rage spender; Enhancement with no target: slot 1 empty 66% -> 83%.
- 1.6.0.290: Watchdog reports in parts (owner, 2026-11-14: "are we at capacity ... cutting critical data?"). Yes: one
  paste holds ~30,000 characters, and long fights lost their start (the 254 s fight: 531 of 1,281 events; 167 s: 368).
  Now a report too big for one paste comes as up to 4 parts ("DMGWP 1/3 ..."), a Next part button in the window,
  and tools/decode-export.py joins them (the player's words between parts are skipped). End-of-fight summaries are
  always stored even when a fight is full; the test-build cap per fight is 4,000 events (was 1,500).
  Note (owner): multi-player capture never came from Watchdog (only your own character); a raid's combat log file
  (/combatlog, advanced logging) has everyone - upload it, or Warcraft Logs.
- 1.6.0.289: Balance "Starfall > Starfall" (32 misses in the owner's 254 s 9-dummy fight) investigated. The slot-2
  guard (G.BelowCostAhead: after a pretend spend from a hidden pool, only promise a spender the low end affords) is
  right: the real Balance data with Astral Power 60-100 gives Starfall then Starfire (new test). The live fight
  alternates the other way (after Starfall: Starfall; after Starfire: Starfire), so the range the look-ahead starts
  from must swing between passes; the report only had the range at each press. state_trace now carries la= (slot 2's
  step: per spender weighed, pt:lo-hi/spent) for the next fight. Seen on the way: before Eclipse has been cast, slot 2
  can come up empty after Starfall (to look at).
- 1.6.0.288: First full measured fight with the Cooldown Manager trusted (owner, 1.6.0.287, Balance 254 s):
  cdm 604 checks / 32 wrong (5%) / 101k facts, yet slot 2 36% (n=144; was 47%), slot 1 steady 83%. Found: two
  icons for one buff (Eclipse (Lunar) / (Solar) both read as "eclipse", and an icon + bar) were applied one by one,
  the last read winning - "Eclipse up" flipped ~10 times a second (cdm_buff_summary flips 0.1+,0.2-,...). Now one
  answer per buff per pass: up when any of its icons is. Misses still to work: resource 34 (starfall>starfire x32 -
  slot 2 expects Starfall, slot 1 then shows Starfire: the look-ahead's Astral Power), state 51.
  Watchdog export: when the 30,000-character report can't hold every fight it now keeps real fights (15 s+, or
  running) before short pulls - the owner's previous report held only a 5 s pull made right after a long fight.
- 1.6.0.287: Cooldown Manager switched itself off in the owner's first measured fight (1.6.0.286, Balance, 167 s,
  Hidden until combat): clue_summary cdm=24 checks / 6 wrong / OFF - right after the viewer appears at the pull its
  icons still hold the stale "not active" from while hidden, and those reads were graded against the still-readable
  auras. Slot 2 47% (n=88), the same as without it (misses: resource 18 - starfall>starfire x16, the Astral Power
  ceiling; state 22). Now a viewer's icons are neither used nor graded for 1.5 s after it appears (CDM.SETTLE).
- 1.6.0.286: Setup step 4 (owner, 2026-11-14: "that's the key for the instructions"): only Tracked Buffs matters,
  icons are enough; Tracked Bars and the Essential / Utility cooldowns aren't needed (cooldowns come from the game
  directly) - leave them empty or hidden, each buff in one place only.
- 1.6.0.285: "Hidden until combat" works (owner's test, 2026-11-14: viewer shown=T in combat, act=T/F live,
  Eclipse flipping) - out of combat auras are readable anyway, and the tracked list (which key buffs to add) reads
  from its icons even while hidden. Settings and the tip now judge "Hidden" by the last fight only (remembered per
  character), not by the viewer being hidden out of combat; step 3 says "Always, or Hidden until combat".
- 1.6.0.284: Cooldown Manager coaching (owner, 2026-11-14: "coach people that DMGAssist is more accurate with the
  Cooldown Manager enabled ... give them instructions"). Settings > Integrations, until it's set up: "Off. DMGAssist
  is more accurate with it on" and 3 steps (enable it in Options > Gameplay Enhancements; in its Cooldown Settings,
  Buffs tab, drag only the buffs marked "add it" to Tracked Buffs; keep Visibility on Always, lower opacity to 50% at
  most - Hidden stops it working). One chat tip per profile when it's off or hidden (never repeated). Tests start
  with no Cooldown Manager unless a test sets one up.
- 1.6.0.283: Cooldown Manager set to Hidden is NOT readable (owner's test, 1.6.0.281, 2026-11-14): with the
  buff icons' Visibility on Hidden (viewer shown=F, alpha 0.50) every buff read act=F / sh=F all fight, no flips,
  Eclipse included (it read T while visible) - the game stops updating a hidden viewer. Those stale "not active"
  reads were believed: cdm wrong 90 -> 222. Now a hidden viewer is never used, and Settings say "set to Hidden ...
  set Visibility to Always (opacity can go down to 50%)". The clean-screen option is the 50% opacity minimum, not
  Hidden. Also: cdm_viewer logs every hide / show / fade; cdm_buff_summary starts with viewers[...shownN/hiddenN]
  and is written every 60 s in long fights ("so_far"), so a report taken mid-fight has it.
- 1.6.0.281: Cooldown Manager proved valuable (owner's 1.6.0.280 Balance run, Silvermoon dummies, auras hidden:
  aura_scan nil, restricted=2). In combat every tracked buff icon read plainly: isActive and shown T/F, 0 hidden
  (cdm_buff_summary sh/act/a ok234/S0); clue_summary cdm=78654 checks / 90 wrong (99.9% right against readable
  auras) and 2184 buff facts given in combat that nothing else could give. (1.6.0.277's "isActive nil in combat"
  was an icon not tracked / no buff.) Opacity can't go below 50% in game (owner), so no 0% test needed.
  Fixes: a key buff the Cooldown Manager offers only greyed out (talent not taken: Starweaver's Warp / Weft) is no
  longer suggested - the game's catalog asked with and without unlearned talents; "can't track it" buffs are no
  longer listed (counted in cdm_setup); flips kept per icon (the same buff as an icon and a bar interleaved).
- 1.6.0.280: Cooldown Manager support (owner, 2026-11-14: "see on addon load if it's enabled ... automatically
  start tracking ... see what it's not tracking and let them know in settings ... only track what's important").
  New Core/CDM.lua:
  - Detected at login, on a spec / talent change and when its option is switched (CVar cooldownViewerEnabled,
    CVAR_UPDATE). When it's on, its tracked buffs are read automatically; when it's off, nothing is read.
  - Key buffs per spec: the buffs SimC's and Blizzard's lists check that you don't cast yourself and that no one else
    gives (procs and talent effects: Fire's Hot Streak / Heating Up / Pyroclasm, Outlaw's Opportunity / Audacity,
    Fury's Enrage / Sudden Death), most checked first, at most 6, talents not taken left out.
  - Settings > Integrations > "Blizzard's Cooldown Manager": on or off (how to turn it on), then each key buff as
    tracked / "add it to Tracked Buffs" / "can't track it" (when the game's catalog doesn't offer it), and how many
    other tracked buffs DMGAssist doesn't need (clutter). Same in /dmga cdm and the "Key buffs in chat" button; a
    status line; one chat line per spec and session when it's on.
  - In combat, where isActive is hidden, an icon's "shown" stands for its buff once it has proved right out of combat
    (graded against readable auras: 10+ checks, 2+ while the buff was up, <=10% wrong), source cdm_shown.
  - Logs for the next pass: cdm_setup (on/off, tracked buffs, key buffs and where each stands, the catalog's counts
    per category, the viewer's opacity) and cdm_buff_summary per fight (per buff: shown / isActive / alpha read
    plainly or hidden, and every moment the icon appeared or went away, to check against the combat log).
    cdm_probe_trace is now one line per viewer (the single line ran past 2000 characters before the buffs).
  - Translations: the new lines plus 8 earlier ones that were only in the built locale files (a rebuild would have
    dropped them) are now in tools/i18n.
- 1.6.0.277: Cooldown Manager probe (owner enabled tracked buffs/bars for all procs, 2026-11-14): item.isActive
  still reads nil in combat. cdm_probe_trace, 3 a fight (4 s, 12 s in, after combat): per viewer (Essential,
  Utility, BuffIcon, BuffBar) and icon: shown, visible, alpha, isActive, texture, cooldown times, cooldown shown,
  bar value, stack text - each a value, S (secret) or - (nil). Widget methods only (taint). Next: whatever reads
  plainly becomes a clue (procs seen). The owner's 1.6.0.276 run: Astral Power counted (pull at 46 after a short
  break), floor raised 4x in fight, Flow notes 76 px apart.
- 1.6.0.276: Reference + offline grader (first version) and three bugs it found.
  - tools/simc-reference.py -> data/reference/<spec>.json for 30 specs: SimC profile talents (SimC's own decoder,
    debug output; hero tree), or a top player's talents from Warcraft Logs (combatant info -> class/spec/hero
    talent entry IDs) where SimC's own MID1 profile no longer loads (Hunter, Mage, Paladin, Warrior, Havoc,
    Elemental); 20 seeded fights at 1 and 5 targets: casts/min, opener, pairs. Not yet: Marksmanship and Survival
    (SimC's own lists/data disagree), healers / Augmentation (no SimC profile).
  - tests/test_scenarios.lua SCEN_GRADE: the reference's talents (IsPlayerSpell + talent tree mock), a resource
    world (costs, gains, regen, passive income; hidden in combat; IsSpellUsable from the true value), Blizzard's
    assistant emulated from its own list against the true state, out-of-combat spells and proc-gated spells
    unusable. tools/grade.py: spell-mix overlap per spec at 1 / 5 targets + pace -> docs/coverage/grade.md.
  - Bug 1 (all specs): the assistant clue read SimC's added "cooldowns" list as Blizzard's rules; every pick
    "proved" e.g. Outlaw's Adrenaline Rush buff up all fight (never shown again - the owner's report). Clues now
    read only assisted_combat.
  - Bug 2: Calibrate's readable-resource audit took "before" at the cast event (already including the gain) and
    learned Sinister Strike gives 0 combo points; now "before" is the previous update pass, and a positive gain
    is never learned down to 0.
  - Grader state: Balance 71/65%, Shadow 56/47, Elemental 45/57, Assassination 40/50, Arcane 49/41; many low
    scores are the world's simplicity (auto-attack rage, refunds, procs) and data gaps (cooldowns missing for
    Comet Storm, Ravager, Champion's Leap). Next: world fidelity per resource, cooldown data gaps, then the
    engine deviations it shows.
- 1.6.0.275: Out-of-combat model replaces 1.6.0.273's "Astral Power full after 5 s" (top players' logs: it drains
  ~2.9/s, fastest ~7/s, settles ~18). tools/wcl-ooc.py (first and last cast of consecutive fights, boss and trash
  pulls, top players; rate-limit aware) -> data/resource-gains.json "ooc" -> record.oocPower {rate, fast, rest}.
  Clues.NoteFightEnd keeps our count at the end of a fight; SeedFloors starts the next pull from it minus the
  fastest drain over the break (0 at the first pull after login or with nothing measured; a resource that builds
  out of combat keeps it). Welcome: an explainer page before the four questions (rotation coach that learns as
  you play; crowd-tuned numbers; tanks, interrupts, defensives, buffs), in all 9 languages. README and CurseForge
  description lead with self-learning and crowd-tuned numbers.
- 1.6.0.274: Casts that lengthen running auras. Balance (owner's talents, SimC 6 targets): Sunfire 0.4/min vs
  DMGAssist 3.7/min - Aetherial Kindling (327541): "Casting Starfall extends the duration of active Moonfires and
  Sunfires by 3 sec, up to 28 sec" (sc_druid.cpp starfall_t::execute adjust_duration). The importer now reads
  "extends the duration of" wordings (tools/simc_spells.py aura_links -> record.auraLinks: source, aura, seconds,
  requires, cap, per combo point): Balance Starfall -> Moonfire/Sunfire, Frost DK Frostwyrm's Fury -> Pillar of
  Frost, Fury Raging Blow -> Recklessness, Feral / Subtlety finishers per point. State.ExtendAuras applies them to
  the live clocks and the look-ahead's. Wordings through talent switches ($?s...) are left out (review later:
  Shadow Void Bolt, Affliction, Demonology, Disc Penance).
- 1.6.0.273: Warcraft Logs (owner's paid month; access token saved as the environment's credential).
  tools/wcl-resources.py: per spec, the top heroic player on each boss of The Venomous Abyss (6 fights), their
  resource events (every gain with its ability) and casts -> data/resource-gains.json: per-cast gains of spells
  you cast, passive income per second (procs, ticking spells, talents). ~1200 of 9000 points/hour for all specs.
  Found: Balance Starfire 12 (data 8), Moonfire 8 (6), Shooting Stars ~2.8 AP/s and ~5 AP/s passive in all;
  Outlaw ~6.2 Energy/s from procs (Combat Potency). simc_import folds it in (gains; record.passiveGain).
  Addon: State.PassiveGain / RegenRate add passive income in combat (look-ahead in full; our count at
  Clues.PASSIVE_SHARE 0.6, still a lower bound); not for combo points etc. Balance check on 1.6.0.272:
  Astral Power, Energy, Rage read "secret, never ok" all session even out of combat - the count never started.
  Now hidden built resources (not Energy / Focus) get a count at each pull (Clues.SeedFloors): Astral Power full
  after 5 s out of combat (owner: "always starts at 100 out of combat and refreshes within seconds"), others 0;
  the game's "not affordable" brings it down (Calibrate.Snap -> CapFloor). Measured passive Energy / Focus held
  back: part of it is finisher refunds (Subtlety Relentless Strikes ~14/s), and adding it regressed Subtlety
  slot 2 and Survival leveling cooldowns in the every-spec check; the reader needs to tell refunds apart first. Back-to-back
  notes: the lane keeps them at least an icon + GAP_MIN apart; at the owner's scale 8 px was ~3 px on screen,
  so they looked touching; GAP_MIN 20.
- 1.6.0.272: Balance check on 1.6.0.271: Astral Power still not counted (floors_at_pull had no 8; Rage and Energy
  missing too) although readability shows it readable out of combat. floors_at_pull now says, per resource, how
  it read last ("ok" / "secret") and when it last read as a number. Back-to-back notes not caught: lane_close
  only looked at time; now also logged when drawn closer than an icon + gap (`lane_close_trace`: whole lane,
  paused, main). Calibration ignores resources a spell doesn't touch (Balance logged combo point changes of 0).
  Warcraft Logs: client credentials saved, the token call works; the data API on the same host gets the saved
  login instead of the bearer token (404). Needs the access token saved as a bearer credential instead (owner
  declined for now).
- 1.6.0.271: Balance check on 1.6.0.270 (dummies, exported mid-fight). Working: anchor_summary, state_trace (20
  presses), tooltip gains (gains_learned n=3). Found: Astral Power was never counted (no floor in any Balance fight,
  no floor_check ever): resources were read only while the HUD showed, and "show with a target" hid it out of
  combat. Now read every update and at the pull; `floors_at_pull` logs what we count from. Flow: a note pushed
  right by the one before jumps there instead of gliding (the glide could let two notes touch for a moment);
  the "two spells back to back" case wasn't reproduced in tests - mark it (mark key) if it shows again.
- 1.6.0.270: Extended log (owner, 2026-11-14), `/dmga extended` (on / off, kept; off by default): one `state_trace`
  line per press in combat with what the game showed then: slots 1-3 with sources, Blizzard's pick, targets, GCD
  left, lit spells, usable / short-of-resource spells, cooldowns left, resources, our hidden-resource estimates.
  For replaying fights offline through a new build and lining them up with the combat log (anchor_summary).
- 1.6.0.269: Reports line up with the game's combat log (owner, 2026-11-14: "so you can use outputs across
  both"). Each fight logs `anchor_summary` (GetTime and wall clock at the same moment, player GUID as the log names
  you, spec, addon version, talent loadout string) so the C lines match SPELL_CAST_SUCCESS in WoWCombatLog.txt;
  `corrections_summary` at each fight end: everything learned for the spec + loadout (readable resource changes,
  hidden extras per cast, cooldown timing corrections, regeneration seen) to fold back into the shipped data.
  Next (owner Todoist, Nov 14): owner records a combat log (Advanced Combat Logging, /combatlog, Balance then
  Outlaw, raid / M+ best: everyone in range); then the offline log reader (names stripped): per spec and talent
  build, real gains / costs, regen, procs per cast, cooldown cuts, against our data; and a corrections -> data
  patch tool. Warcraft Logs dropped (API reads only your own uploads).
- 1.6.0.268: Resource calibration and miss reasons (owner, 2026-11-14: "#1 and #2"). SimC test first: 600
  simulated fights (MID1 Balance / Outlaw profiles, 1 and 5 targets) as a next-press table scored on the owner's
  real fights: Balance 28-35%, Outlaw 35-38%, below the owner's own history (35-41%, 47-54%) and SimC live (57%
  Balance): the sim's talents and play differ (it casts Starsurge as often as Starfall; almost no Lunar Eclipse).
  No-go; Warcraft Logs not for rotations, possibly for checking resource numbers per spec. Built instead:
  Core/Calibrate.lua. Readable resources (combo points, holy power, chi...): the per-cast change seen in play
  (>= 6 samples, one value >= 70%) replaces the data (`gain_fixed`). Hidden ones (Astral Power, Insanity, Fury,
  Maelstrom, Runic Power, Rage): when the game's affordability answer proves more than our count, the count is
  raised at once (`floor_raised`); the gap is shared between the spells that built it and, after 15 casts and
  >= 1 per cast, added to each pretend cast in the look-ahead (the count itself stays a proven lower bound). Kept
  per spec + talent loadout (DMGAssistDB.calibrate), older fights x0.97. `calibration_summary` per fight.
  `prediction_summary` now has `miss_why` (targets / proc / cooldown / resource / guess / state) and each top miss
  carries its main reason. Still to confirm in game: Balance slot 2 (57% before), whether the tooltip reader's
  Starfire 12 shows in `gains_learned`.
- 1.6.0.266: History check (owner: "why can't two weeks of logs help?"): next-press-from-cast-order models trained
  on earlier fights, scored on later ones: Balance 35-41% (32 fights; SimC slot 2 57%), Outlaw 54%, Survival 56%,
  Fury/Elemental/Feral 41-44%. Cast order alone lacks the state (resources, procs, cooldowns); pooled logs mix
  ST/AoE, talents and versions - not used as a seed. What works: the learner's confident guesses (18/22, 19/22 on
  Outlaw). Now a situation seen >= 8 times going one way >= 85%, and 15 points above SimC's measured accuracy for
  the spec (after 20 compared presses), takes slot 2 at once; not for healers. 1.6.0.266 was pushed with a failing
  check (Survival / Holy Priest simulated slot 2 regressed; my command didn't stop on the failed check) - fixed in
  1.6.0.267 with these guards.
- 1.6.0.265: Faster testing (owner, 2026-11-14: "feels like we'll do this 300 more times"). Mark key (Key Bindings >
  DMGAssist "Mark this moment", or /dmga mark): logs `mark` (slots with sources and readyAt, the Flow lane as drawn:
  spell, time, x, hold; GCD left; resources) plus a full decision snapshot. `lane_close`: two Flow notes drawn under
  0.5 s apart, with both spells, times, GCD and hold (15 a fight). `resource_audit` per fight: each spell's data
  gain/cost against the readable resource's real change 0.5 s after the cast. tools/prediction-report.py prints them.
- 1.6.0.264: Balance report (83 s AoE, exported mid-fight). Slot 2 (SimC look-ahead) 29/51 = 57%; 13 of 22 misses
  predicted a repeat of slot 1 (Starfall>Starfall, Starfire>Starfire) while play alternated: Astral Power is hidden
  and our data has Starfire's base 8 (Lunar Eclipse and talents raise it). Learner: specs without a combo-point-like
  resource now key on the spender's resource in steps of 20 (Astral Power, Maelstrom, Insanity, Fury, Runic Power).
  Resource gains are now read from the game's tooltips out of combat (S.LearnGains: "Generates 12 Astral Power"
  where our data had Starfire's base 8; talents included). Open (owner): Flow lane shows two notes touching, then the second lands on slot 1 and is swapped - spacing is
  ~130 px per GCD, so the cause isn't visible in the log; screenshot requested.
- 1.6.0.263: Report on 1.6.0.261 (not 262: the energy-estimate fix wasn't in it). Outlaw fight = the 262 report.
  Subtlety fight (82 s, no daggers): "waiting for energy" 22 of 56 picks, real (the game said no power; Shuriken Storm
  on 5 targets at 0-39 Energy). Secret Technique x3, Gloomblade x2 refused "Must have a Dagger equipped in the main
  hand" and kept being shown: now a spell refused for the weapon is held back until PLAYER_EQUIPMENT_CHANGED
  (S.equipRefused, Castable "equipment", log equip_refused). Subtlety learner (shadow) 27/29 vs SimC 9/29.
- 1.6.0.262: Outlaw run on 1.6.0.261 (138 s). Adrenaline Rush ready at 64 s, slot 3 until 119 s: its line
  (Improved Adrenaline Rush, effective_combo_points<=2) was never certain live - Supercharger's hidden charges add up
  to 3, so 1-2 combo points read "1..5". Fix (all specs): a major cooldown whose line can't be decided is taken once
  ready G.MAJOR_PATIENCE (5) s. Blue at 50+ Energy: G.BelowCost overruled the game's "usable" with our estimate
  (regeneration it can't see, Adrenaline Rush's); now only when clearly short (10+ below). Learner live: running
  51% vs SimC 38% (505 presses); this fight next press 52/104 vs 32/104.
- 1.6.0.261: Outlaw run on 1.6.0.260 (163 s). Restless Blades works: Adrenaline Rush ready again at 60 s (was 180).
  It then sat in slots 2-3 until 131 s: Improved Adrenaline Rush's line wants combo points <= 2, true only right after
  a finisher, and the steady hold kept the held Sinister Strike in slot 1 for that one press. Fix: a major cooldown
  SimC wants now takes slot 1 at once (G.Steady, released "major"). Learner went LIVE on its own (running 52% vs
  SimC 40% over 413 presses); this fight next press 66/121 vs 39/121; in slot 2 learned 18/39. Slot 1 steady 99%.
- 1.6.0.260: Outlaw run on 1.6.0.259. prepull_casts showed Adrenaline Rush cast at the instant of the pull (combo
  points 7 at 0.09 s: Improved Adrenaline Rush); out of combat slot 1 is Adrenaline Rush (SimC's opener), so it was
  the first key pressed. The real bug: Restless Blades (79096) wasn't modelled - "finishing moves reduce the
  remaining cooldown of many Rogue skills by 1 sec per combo point spent" (Adrenaline Rush, Between the Eyes, Blade
  Flurry, Blade Rush, Grappling Hook, Keep it Rolling, Killing Spree, Roll the Bones, Sprint). Our clock kept 180 s,
  so Adrenaline Rush never came back in a fight. Added to data/spell-links.json (rogue, branch midnight; the importer
  now honours "branch"); test guards the Outlaw data. Vanish in slots 2-3: Blizzard's "vanish if not stealthed"
  rule in look-ahead steps that skip SimC's cds sub-list; now a spell SimC ruled out in the live decision isn't
  predicted by Blizzard's rules either. Slot 1 steady 95%; learner 58/103 vs SimC 46/103 (running 50 vs 44).
- 1.6.0.259: Adrenaline Rush never recommended in combat (owner: never cast; /reload, idle, pull). The game's
  restricted-combat readout said "180 s left" from the pull, and it read ready the moment combat ended (fight 410:
  shown at 142 s, which a real cast at the pull couldn't be). Fix: out of combat, once a second, which cooldown
  spells read ready (S.SnapshotReady); in combat such a spell stays ready until we see it cast (by ID or name).
  My earlier "cast before the pull" reading was wrong.
- 1.6.0.258: Outlaw run on 1.6.0.257 (167 s). Slot 1 steady 94% (8 changes in 108). Prediction over the last three
  fights (replay, learner carried over): slot 2 42%, learner 51%, 65% where the full situation was known; in game
  learner 57/112 vs SimC 53/112, running lead 3 points (live needs 10). Adrenaline Rush: majors_at_pull read
  "not ready, 180 s left" with nothing on cooldown before the pull (screenshot); never cast in the fight. Our clock,
  links and charges ruled out; most likely cast as the opener just before combat (out of combat slot 1 shows it,
  SimC opens with it; 3 min cooldown > 2.5 min dummy fights). Not provable from the log: now logged:
  prepull_casts (own casts in the 10 s before the pull) and the game's raw cooldown readout per major at the pull.
  Other cooldowns used on time (Blade Rush 61-63 s gaps on 60 s, Blade Flurry and Roll the Bones on cooldown).
  Energy: 8 presses refused "Not enough energy" during the blue waits: the waits were real.
- 1.6.0.257: Outlaw run on 1.6.0.256 (142 s). Learner shadow: 41/95 vs SimC 37/95 on the same presses; confident
  guesses 18/22 (82%); replay: full situation 59%, cp+lit 57%. "Slot 1 steady 76%" was mostly a measuring error:
  23 of 29 changes were the next cast starting from the spell queue (the spell that left slot 1 was cast 0.02-0.2
  s later); all 29 steady_release lines were "settle". Real steady ~94%. Fixed: a change counts only if the spell
  that left slot 1 isn't cast within 0.3 s. Adrenaline Rush: not castable from 0.1 s into the fight (our clock /
  the game: on cooldown), shown at once when combat ended: most likely used before the pull; not provable from the
  log (traces stop at 40), so majors are now logged per fight: majors_at_pull, major (ready/not), major_shown
  (slot). Roll the Bones: used on cooldown (45 s; 2, 48, 94 s). Energy starvation clustered at 97-104 s with
  Thistle Tea twice: the stretch without Adrenaline Rush.
- 1.6.0.256: Outlaw run on 1.6.0.255. Learner (shadow) beat slot 2 in its first fight: 27/58 vs 17/58 on the same
  presses. Replay of the press lines (tools/prediction-report.py) picked the key order spell+secondary
  resource+lit buttons > last two presses > spell (52% cold start, 55% with slot 2 as fallback, vs slot 2 38%;
  74% where the full situation had >= 3 samples). Built: that order, MIN_N 3; auto-promotion per spec + loadout:
  live in slot 2 once it leads SimC's forecast by >= 10 points over >= 100 presses (decayed), back to shadow under
  3 points; live, SimC's forecast moves to slot 3 and slot 1 is never touched. Scored always against SimC's own
  forecast (result.simcNext). Regression found: slot 1 steady 77% (24 changes), mostly lit Pistol Shot ->
  Dispatch ~1 s after a press when the combo points update (finish condition becomes true) with no hold in the
  log; cause not visible, so `steady_release` now logs why slot 1 let go (lock_max, settle, refused, nobar,
  uncastable+why, debounce/simc_ruled_out).
- 1.6.0.255: Prediction learner in shadow mode (Core/Learner.lua). At every damage-rotation press it learns which
  spell came next in that situation (last two presses, secondary resource, lit buttons, ST/AoE; coarser fallbacks
  while a situation is new), guesses the next press silently, and scores itself against slot 2 on the same presses
  (`learner_summary`). One `press` line per press for offline study: tools/prediction-report.py replays them
  through several learner designs (last1, last2, full, backoff, hybrid). Kept per spec + talent loadout in
  DMGAssistDB.learner, older fights weigh less (x0.97 per fight). Defensives, trinkets, potions, interrupts and
  precombat spells are left out. Goes live (slot 2 only) once it clearly beats slot 2.
- 1.6.0.253: Outlaw run on 1.6.0.252: slot 2 right 44% (simc 18/32, simc+glow 4/5, rules? 3/15, guess 1/7), slot 1
  steady 86% (target 95%), slot 3 56%, last-press baseline 48%. (1) Look-ahead never guesses a hidden-proc spell
  back in: the "behind a hidden proc" mark is set before a glow confirms the line (a lit Pistol Shot, once pressed
  in the look-ahead, came back as a guess), and Blizzard's uncertain rules (rules?) respect it too. After Sinister
  Strike the next press was Sinister Strike 10/21, Pistol Shot 4/21. (2) Steady slot 1 (default): keeps the shown
  spell until pressed while SimC's line for it isn't false; a moment short of the resource waits up to 2 s
  (G.POWER_WAIT) instead of jumping to whatever is castable (most of the 9 changes, about 1 s after a press).
  "Fast" keeps the old behaviour; interrupts and defensives still take slot 1 at once.
- 1.6.0.252: Prediction measurement, round 2 (owner targets: slot 1 steady 95% between presses, slot 2 right
  80-85%, slot 3 secondary; Flow and Classic alike). `prediction_summary` adds slot1_steady (changes between
  presses; interrupts/defensives/trinkets/potions/buffs counted apart as situational), slot 3, slot 2 by where the
  guess came from (simc / rules / guess...), a last-press baseline, and how many presses followed slot 1. Volley
  casts (Fan the Hammer) count as one press. Fix: "waiting for a resource" shows a line SimC is sure of or a lit
  button, never an unlit proc spell (8 of 19 slot 1 changes in the Outlaw run were waiting Pistol Shot -> the real
  pick when Energy came).
- 1.6.0.251: Outlaw dummy report. (1) Slot 1 "waiting for a resource" no longer fades to half strength in either
  display: full strength with Blizzard's blue "not enough" tint (it read as a broken, see-through icon). In the log
  every dimmed stretch ended within 0.04 s of the press going through, but Energy is hidden in combat, so (2) each
  press the game refuses is now logged with its reason and what slot 1 showed (`refused`), to tell "really short"
  from "we were wrong". (3) Look-ahead: pressing a lit proc spell spends its glow, so slot 2 no longer predicts
  Pistol Shot again after a lit Pistol Shot (right 4 of 20 times). Prediction in that run: 44% over 84 presses.
- 1.6.0.250: Prediction measurement. Every fight's summary now logs `prediction_summary` (how often slot 2 at a
  press was the next spell pressed, and the most common misses: "shown > pressed xN"); the scenario test records
  each spec's rate and fails on a drop of more than 10 points. Look-ahead no longer predicts spells SimC casts only
  before the pull (Unholy's Raise Dead sat in slot 2 every step; Enhancement's imbues). Slot 1 still names them
  when the game does (a dead ghoul). Finding: the simulated rate is low for specs whose slot 1 comes from the
  simulator's stand-in for Blizzard's assistant (it always names the first ready spell), so real numbers come
  from in-game reports. No pattern learning built: waiting for in-game data that shows a repeatable miss.
- 1.6.0.249: Look-ahead (slots 2-3, every spec): Blizzard's written rules no longer bring in a spell SimC's own
  lines rule out in the same step (Outlaw's Vanish, which SimC uses only with Hidden Opportunity, sat in slot 2
  from Blizzard's "vanish if not stealthed" and never reached slot 1). Major cooldowns keep their path (the
  assistant never names them).

- 1.6.0.248: Each interrupt alert logs the target cast's whole length (when readable) and how long the alert stayed
  up (interrupt_gone), to tell a boss's sub-second cast from us hiding it early (owner, 2026-11-13: "popping for
  less than a second"). The 1.6.0.247 log showed 6 alerts about 12 s apart, none skipped: each ended with the cast.

- 1.6.0.247: The interrupt summary counts the target's casts and the ones it couldn't be interrupted on (a boss
  with no interrupt shown: did it cast at all?). Reviewed 2026-11-13: Protection Warrior defensives as built
  (Shield Block keep-up, Ignore Pain, Impending Victory, owner: "feels GOOD"); Unholy's two Death and Decays in a
  row follow SimC (Cycle of Death on 3+ targets while Putrefy isn't at max charges; no full-charges rule
  outside adds).

- 1.6.0.246: Look-ahead: a line hidden behind a proc (Outlaw's Pistol Shot on Opportunity) is never guessed into
  slots 2-3 unless its button is lit; it was marked only when Blizzard's assistant had a pick, and Outlaw often has
  none, so the row rewrote itself all fight. Combos: the first of a fight comes 15 s after the pull (was 45 s);
  the linked lines burn (flickering fire core with a rising flame glow), linked notes burn, and a finished combo
  sweeps the lane in fire. Rogue combos were already running (3-step ones logged).

- 1.6.0.242: Mitigation map: every spec's survival profile from data/mitigation/ (40 specs), checked against the
  game's spell data by tools/mitigation.py (removed spells, passives, other specs' talents, game-flagged
  defensives left out all fail the build); Tanks.lua and Defensives.lua read it. Defensives are found by spell ID
  (Evasion, Death Pact... were never found before) and are per spec (Blood's Death Strike stays in the rotation).
  Protection: right after Thunder Clap, with every spell on cooldown, slot 1 shows the one ready first (shaded)
  instead of an empty bar. An icon with no keybind shows its spell's name.

- 1.6.0.241: Unholy: short of Runic Power, slot 1 no longer shows Death Coil "waiting" while a castable line
  comes before it in the list (Festering Strike / Scourge Strike at 0-29 Runic Power). Interrupts: a press
  already on its way when the interrupt appears (first 2 s) no longer counts as skipping it (Blood: Mind Freeze
  shown for 0.8 s, then hidden by a Death Strike). Flow: an interrupt the game decides no longer flashes
  "INTERRUPT!" and the red edge on its own (the icon is hidden on a cast that can't be interrupted, so the call
  showed with no spell). Not seeing DEFEND before the pull on DK confirms 1.6.0.226.

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
