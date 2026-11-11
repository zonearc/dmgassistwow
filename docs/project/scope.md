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

## Game mode (decided 2026-11-11)
- A second display style, switched any time (drum button on the HUD, /dmga game, keybind, minimap menu, Settings >
  Display; asked as the 4th welcome question, Classic suggested). Classic stays the default.
- Three lanes scrolling right to left into a hit line on the left: top = damage rotation (an interrupt drops in
  gold-edged), middle = defensives / heals / tank mitigation, bottom = trinkets, potions, items.
- A note reaches the line exactly when the spell can be pressed (the classic press-now clock); slots 2-3 follow,
  spaced by GCD / cast time. The classic HUD keeps running unseen (its clock, the grade's ready moments, the action
  bar highlight).
- Judged by the performance grade's own press scoring: slot 1 = Perfect / Great / Good by distance from the line,
  slot 2-3 = Good, anything else = Miss. Only a wrong spell breaks the streak; waiting (nothing to hit, moving,
  a mechanic) never does.
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
