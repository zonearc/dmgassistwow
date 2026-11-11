# DMGAssist project scope

What DMGAssist is, what it isn't, and the decisions that shape it. The task list is [tasks.md](tasks.md).

## What it is

A rotation helper for WoW Midnight and WoW Forever. It shows what to press; the player presses everything.

- Priority lists: SimulationCraft (Midnight), WoWSims (Forever), imported weekly and automatically.
- Blizzard's Assisted Combat is a second opinion for what the game hides from addons.
- Cooldown timing learns from the player's own fights, account-wide per class and spec, and from reports.

## Layout (decided 2026-11-09)

Each place has one purpose:

| Place | Purpose |
|---|---|
| Slots 1-3 | The damage rotation. An interrupt takes slot 1 when an enemy casts something worth stopping. |
| Red-edged icon on slot 1 (top-left) | Staying alive, every class: defensives, self-heals, tank upkeep. Pulses when needed now. |
| Gold-edged icon on slot 1 (bottom-left) | Items: on-use trinkets and the potion the player chose. Quiet, never moves. |

Attention follows importance: only slot 1 has a moving glow.

## Performance grade (decided 2026-11-09)

After each real fight (20 s or more, at least 5 presses), a grade from S+ to D pops up in its own window above the
icons (movable in Edit Mode or while unlocked), then fades. Parts: accuracy 35% (slot 1 = full, slots 2-3 = 0.75,
what slot 1 showed 0.6 s before counts), always casting 25% (0.25 s grace), reaction 20% (0.25 s full, 1.5 s none),
cooldowns 20% (within 2 s full, 10 s none; unused items not graded). Letters S+ 96, S 91, A+ 86, A 80, B+ 72, B 64,
C 50, D: B+ reachable for most players, A takes accurate play, S is rare. Only what we showed is graded: presses
with nothing shown, outside the rotation, or with an interrupt in slot 1 are neutral; idle only while slot 1 is in
range and usable; cooldowns shown under 2 s aren't graded. The letter uses the game's damage-number font. Never DPS:
we can't know what a player should do. The score is never more than 6 points above the weakest part, so one weak
habit isn't hidden by the others (decided 2026-11-10). Graded up to the last rotation press + 3 s (walking off a
dummy isn't idle). Under the parts, "Beyond Assisted Combat": how much of the fight slot 1 differed from
Blizzard's assistant and why (cooldowns, rotation, upkeep, utility) plus extras Blizzard never shows; never a
damage claim (decided 2026-11-10). Best and last 20 fights per spec, account-wide; trend, averages and one tip
on the settings page. Can be turned off.

## Flow mode (decided 2026-11-11; first called Game mode)
- A second display style, switched any time (the CLASSIC / FLOW slider switch at the bottom right of both: under the
  classic HUD and in the lanes' foot row, /dmga flow, keybind, minimap menu, Settings; asked as the 4th welcome question, Classic suggested). Classic
  stays the default. (A 16 px drum icon was first; "too small, no one will see it", 2026-11-11.) Named "Flow
  mode" by the owner (2026-11-11; Rhythm and Tempo were the other candidates). The code keeps its first name
  (Game.lua, db.gameMode); /dmga game still works next to /dmga flow.
- One lane scrolling right to left into a hit line (the rotation, slots 1-3), notes about 1.7x the classic icon,
  and a bonus row above it where interrupts ("KICK!"), defensives / heals ("DEFEND!") and trinkets / potions
  ("POWER UP!") pop in when needed; grabbing one adds to the streak and scores a bonus. (Three lanes were tried
  first, 1.6.0.189-196: two of them sat empty most of the time.)
- Guitar Hero's ideas in WoW terms (2026-11-11): casts and channels trail a hold bar (yellow / blue) as long as
  they last, and the next note comes after it (cast time or the GCD, whichever is longer; channels flagged from
  the spell data's "Is Channelled"); major cooldowns are flame notes worth double; power mode (Bloodlust / a haste
  burst, or 15 s after a major cooldown) turns the lane electric blue and doubles every hit.
- Round 4 (2026-11-11): a framed landing spot (not just a line) with a big gold burst when a note reaches it; a
  live cast bar (dim track the cast's length, bright fill left to right); dots every 0.5 s scroll along the lane;
  the streak row sits under the lane (bigger), the big words above everything, almost the lane's height, and only
  for moments (milestones, flame hits, bonuses, power mode, every 5th Perfect in a row, at most one per 5 s);
  every press shows a small coloured word at the spot. Defensives / interrupts / items: an action track opens
  above the lane only while one waits (red, edged, "!"); a boss hit's defensive scrolls in from its timer and
  lands when it should be pressed, with a red alarm around the frame and a big "DEFEND!".
- The action row (2026-11-11, "the red row... looks terrible"): shorter than the lane (icons 34 px, 6 px clear
  of it), dark like the lane with a thin coral border that wakes up (and a "!") while something waits; the
  "KICK!"-style word sits right of its icon. The low-health defensive (always listed, shown by the game when
  health is low) never wakes it, sounds the alarm or shouts DEFEND!. Big words use a thin outline and a shadow.
- Press start (2026-11-11): out of combat before a set's first press, the lane shows an arcade headline
  (READY, PLAYER ONE? / INSERT COIN / PRESS START) and "Hit your first spell to start the Flow" on a dark gradient
  box over the lane (the waiting notes a faint hint behind it), gone in a quarter second on the first hit; the first hit pops
  LET'S GO!. The grade box gives the Flow score its own wrapped row (it ran out of the box beside the grade score).
- Presses are judged against what slot 1 showed when they were decided, and a cast's note bursts when the cast
  begins (a right Starfire showed a red X: its cast event came after slot 1 moved on).
- Notes only move left: a later target (a new global cooldown, a wrong press) pauses a note where it is. A wrong
  press shakes the note with a red X and it stays: press it now. A hit bursts the note at the line.
- One note in the box (2026-11-11): only slot 1 stands on the line. When the engine moves the waiting note back
  (slot 1 and 2 swap), it drops away and slides in again behind the new one. If it waited 1.2 s or more on the
  line with the player free to press, that's a quiet miss: the streak breaks and the set's % perfect counts it
  (no shake, the note falls away red). A quicker swap costs nothing.
- Real gaps: a note is never closer to the note before it than their time apart (and never touching), so two
  notes side by side always mean "one, then the other" (the one case a note moves right).
- A "next" the engine keeps putting off (Moonfire as slot 2 for minutes while slot 1 moves on) is hidden after
  it's passed over 3 times; it's back when it becomes slot 1 or leaves the queue.
- A note reaches the line exactly when the spell can be pressed (the classic press-now clock); slots 2-3 follow,
  spaced by GCD / cast time. The classic HUD keeps running unseen (its clock, the grade's ready moments, the action
  bar highlight).
- Judged by the performance grade's own press scoring: slot 1 = Perfect / Great / Good by distance from the line,
  slot 2-3 = Good, anything else = Miss. A wrong spell breaks the streak, and so does a note that ran out of
  time on the line (above); waiting with the note still slot 1 (nothing to hit, moving, a mechanic) never does.
- Score: Perfect 100 / Great 75 / Good 50 points x a multiplier (+1 per 10 in a row, up to x4). Ranks by streak:
  Bronze 10, Silver 25, Gold 50, Platinum 100, Diamond 200, Mythic 500. Milestones (5 ... 500) pop an escalating
  word and add a star (5 shown). Each judgement says one of 5 phrases; the higher the multiplier, the more excited
  the pool it picks from.
- A set is a run of pulls: it lasts until 20 s out of combat (chain pulls, a boss and the trash after it are one
  set; bosses wait too), then the performance grade shows with the set's score, best streak and % perfect. Best
  streak and best set score per spec saved.
- The hit box flashes once when a note reaches the line. "Game timing offset" (-200..300 ms) moves that moment
  for latency and reaction, like a rhythm game's calibration.
- Stability: slot 1 is never changed (it's the right press). Slots 2-3 only swap when the new pick holds 0.35 s.
  Making the engine itself "commit" to picks (less swapping at the cost of exactness) is not done: measure it in
  the every-spec check first.
- Purely visual; nothing is pressed for the player.

## Settings pages (decided 2026-11-11)
- DMGAssist (essentials: on/off, minimap, lock, language, setup, profiles), then three groups:
  Status & Help (Status, Missing keybinds, Help); Core (Combat, Display, Sounds, Integrations, Advanced, Spells &
  trinkets); Game mode & grades (the Game mode switch, timing offset, records; Performance grade + Grade report).

## Integrations

Supported and listed in the settings: Masque, DBM, BigWigs, LittleWigs, WeakAuras (DMGAssistAPI), Blizzard's
Edit Mode and Assisted Combat.

Not supported or advertised (decided 2026-11-09, may return if those projects want to partner): Titan Panel and
data broker launchers (removed), ElvUI, Bartender, Dominos. Keybinds are still read from their action buttons so
their users see keys on the icons.

## Rules

- Never automates input. No COMBAT_LOG_EVENT_UNFILTERED, loadstring, or protected calls.
- Every new player-facing text: a tooltip or explanation, translated into all 9 languages in the same change.
- Every settings section: a title that makes sense alone and an explanation line; every option: a tooltip
  (a test enforces it).
- ./scripts/check.sh passes before every commit.
- Every spec, every change (decided 2026-11-10): tests/test_scenarios.lua plays simulated dummy fights for all 40
  specs (one target, five targets, leveling mode) through the real pipeline with the game's restrictions on. Rules
  that must always hold: no errors, slot 1 never empty, a ready major cooldown never waits behind Blizzard's pick,
  no endless hold. And no spec may get worse than tests/scenario_baseline.lua (major cooldowns used, spells used,
  empty slots, slot 1 flips). A fix for one class that breaks another fails the build, in CI and in the weekly
  SimC sync. The baseline is updated (--update) only for an intended change, said in the commit.

## Tanks (decided 2026-11-09)

Tanks get a mitigation profile per spec alongside SimC. The three slots stay damage only; every mitigation button
goes in the red icon, picked by the profile: keep-up first, then cooldowns on incoming damage (boss-mod timers),
reactive buttons on boss-mod calls, emergencies on low health (tank default 50%, per spec, editable). The grade
adds Mitigation for tanks. Built in Core/Tanks.lua (1.6.0.146); Midnight only (WoW Forever tanks follow their lists).

## Keep-ups beyond SimC (decided 2026-11-10)

Some spells a player needs are left out of SimC's lists because SimC casts them before the pull or doesn't
simulate healing. Each is a keep-up rule in Core/Essentials.lua, with its own setting:
- Hunter's Mark on a boss target (before the pull too), once per target. Default on.
- Healing support (default off, groups only): Discipline keeps N Atonements up (Shield first, Radiance when
  several are missing and Shield can't be cast); Mistweaver spends Renewing Mist charges. Holy Paladin's part
  (Beacon of Light on the tank) is the buff reminder. Group health isn't readable in combat, so no reactive heals.
- Cooldowns our data lacks (Void Volley) are learned from the game's "not ready yet" refusals.
Spells a keep-up adds carry fallback cooldown / charge data (SpellMap.EXTRA_INFO), and the every-spec check has
a group fight (boss, party of 5, healing support) where each keep-up must be cast.

## Only what you can press (decided 2026-11-10)

DMGAssist never suggests a spell you have no button for: being on one of your action bars is a requirement,
like being off cooldown (Choices.OnBars, setting "Only spells on your bars"). The skipped spell is named in chat
once, so you can add it.
