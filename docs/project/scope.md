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
icons (movable in Edit Mode or while unlocked), then fades. Parts: accuracy 35% (slot 1 = full, slots 2-3 = half),
always casting 25%, reaction 20% (0.15 s full, 1 s none), cooldowns 20% (within 1 s full, 6 s none). Never DPS:
we can't know what a player should do. Best and last 20 fights per spec, account-wide; trend, averages and one tip
on the settings page. Can be turned off.

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

## Tanks (decided 2026-11-09)

Tanks get a mitigation profile per spec alongside SimC. The three slots stay damage only; every mitigation button
goes in the red icon, picked by the profile: keep-up first, then cooldowns on incoming damage (boss-mod timers),
reactive buttons on boss-mod calls, emergencies on low health (tank default 50%, per spec, editable). The grade
adds Mitigation for tanks.
