# DMGAssist: rotation helper for Midnight and WoW Forever

**DMGAssist shows the next three spells to press, in priority order, and flashes the moment to press them.**
The priorities come from SimulationCraft, the same simulator theorycrafters use to work out the best rotation
for every spec. DMGAssist is built from scratch for Midnight's new addon rules: it reads only what the game
allows, never presses anything for you, and tells you honestly when it is unsure.

**Source, issues and nightly builds:** https://github.com/zonearc/dmgassistwow

> **Early access.** DMGAssist is young and improving quickly, with fixes almost every day.
> If something looks wrong, please report it (see *Reporting a problem* below): every report is read.

---

## What it helps with

- **Three slots, in priority order.** Slot 1 is what to press when your global cooldown ends; slots 2 and 3 are
  what comes next, so you can plan ahead. That's the whole HUD: Blizzard's Cooldown Manager already covers
  cooldown readiness.
- **The right thing first.** Interrupts, then defensives, then your rotation. Major cooldowns are part of the
  rotation where SimulationCraft uses them, or switched off entirely if you prefer to time them yourself.
- **A press-now flash, timed to your GCD and casts.** It lights 50 ms before you can press (adjustable), so you
  stop clipping and stop waiting.
- **Steady, not jumpy.** In the last half second before your next press, slot 1 is held; a late change moves into
  slot 2 instead of swapping under your cursor.
- **Single target or AoE, by itself.** It counts the enemies you are fighting from their nameplates, within your
  range, and switches at your spec's own AoE point. A colour-coded title shows `ST` or `AOE` and the count in
  combat. One key cycles Auto, Single and AoE.
- **It follows your choices.** Skip the spell in slot 1 three times and it is held for the rest of the fight (saving a
  cooldown for the next pack); cast it yourself and it comes back. Optionally, keep major cooldowns for bosses and
  big pulls only.
- **Tank and melee essentials.** Guardian Druids keep Ironfur stacks (3 by default) and Moonfire up. Melee specs
  out of range get their charge or leap first: Wild Charge, Charge, Shadowstep, Harpoon, Feral Lunge, Death Grip.
- **On-use trinkets.** Every equipped on-use trinket is shown when it is ready, alongside your cooldowns (and
  when SimC's list says to use it). Switch off any trinket you'd rather press yourself; the choice follows the
  trinket through gear and spec swaps.
- **Healers too.** SimC publishes no rotation for most healing specs, so DMGAssist ships its own damage lists
  for Discipline, Holy Priest, Holy Paladin, Mistweaver, Restoration Shaman and Preservation (learned from the
  current class guides) for your damage between heals (SimC's own list takes over if it ever publishes one). Restoration
  Druid uses SimC's list, cat weaving included. Healing itself stays your call.
- **Discipline Atonement.** Atonements counted from your casts on slot 1's corner, and a ramp (Radiance, then
  Shield) before the big hits your boss mod warns about, until enough are up.
- **Your choice of spells.** Settings > DMGAssist > Spells & trinkets lists every spell your spec can be shown
  and every equipped on-use trinket. Untick one and it is never shown; the next spell takes its place. Tick
  "First when ready" and that spell goes to slot 1 whenever it can be cast. Kept per spec (trinkets per item),
  so updates and gear swaps keep your choices.
- **Missing keybinds check.** Lists every spell and trinket it can recommend that has no key binding, with
  icons (Settings > DMGAssist > Missing keybinds, or `/dmga unbound`), so you find out before the pull.
- **Plays well with your setup.** DBM, BigWigs and LittleWigs timers (or Blizzard's encounter timeline) for adds,
  AoE and tank hits; keybinds shown on the icons from Blizzard's bars, Bartender and macros; sounds for
  interrupts, defensives and cooldowns.
- **Any client language.** Spells are matched by ID; messages are translated into 9 languages.

## How it uses SimulationCraft

SimulationCraft (SimC) publishes a priority list (an "APL") for every spec: an ordered list of lines like
*"use Rip if it isn't on the target"* or *"use Starfall if 3 or more enemies"*. These lists are tuned by the
class theorycrafters for each patch.

- DMGAssist imports the Midnight lists, plus SimC's spell data (cooldowns, durations, costs, procs), into the
  addon. A weekly job pulls SimC's updates, so lists follow the current patch.
- In combat it walks your spec's list top to bottom and shows the first lines that are true and castable, in
  order. It honours SimC's details: line cooldowns, variables, sub-lists, charges, and AoE target counts.
- **WoW Forever** uses the rotations from [WoWSims](https://wowsims.com/forever) the same way.
- Where SimC simulates damage but a real player needs more (tanks staying alive and holding threat, melee
  getting to the target), DMGAssist adds a few essentials on top. They are listed above, and each can be
  switched off.

## The honest part: how Midnight changed addons

In Midnight (12.x), Blizzard hides many combat values from addons: your own procs and buffs, many resources
(Astral Power, Rage, Insanity, ...), enemy health, and details of enemy casts. Older rotation addons read all of
that freely; in Midnight they can't, and neither can DMGAssist. What DMGAssist does instead:

- **Tracks what it can infer from your own play:** cooldowns, DoTs and buffs you apply, stacks, charges, and a
  floor for resources you build, all from your casts.
- **Works with limits** when a value is hidden: "this buff is 0 or 1", "a timer is never negative", "Astral
  Power is at least 40". Many lines can still be decided.
- **Asks Blizzard's Assisted Combat** (which can see the hidden state) to confirm lines it can't decide, and uses
  Blizzard's own rotation rules where the assistant is silent.
- **Lets the game choose** when the answer depends on one hidden number (4 or 5 combo points, for example): both
  icons are drawn, and the game shows the right one without the addon ever reading the value.

### What it won't do, compared with older rotation addons

- **It won't press anything for you.** No automation of any kind; you press every button.
- **It won't be perfect on every GCD.** When the deciding information is hidden and nothing can confirm it,
  DMGAssist picks the safest certain line. It may be a beat behind an addon from before Midnight that could read
  everything.
- **No extra panels.** No cooldown timeline, buff tracker or proc display: three slots, in order. Use Blizzard's
  Cooldown Manager alongside it.
- **No combat-log tricks.** It doesn't read the combat log or use protected functions, so it doesn't cause
  "action blocked" errors or taint your UI.
- **No custom rotation editor (yet).** You get SimC's list for your spec, plus the options in Settings.
- **Healers:** healing specs have no SimC damage list worth using, so support for them is limited.

## Getting started

1. Install **DMGAssist**, and **DMGAssist_Watchdog** if you want to report problems (recommended while it's in
   early access).
2. Log in. The icons appear in combat, or out of combat with an enemy targeted. Drag them where you like.
3. Optional: bind a key to **Switch target mode** under *Options → Keybindings → AddOns → DMGAssist*.

- **Minimap button:** left-click shows or hides the HUD, drag moves the button, right-click opens a menu
  (settings, Report an issue, quick toggles).
- **Settings:** *Options → AddOns → DMGAssist*. The **Status** page shows the version, the spec and rotation
  detected, the target mode, boss mods and keybinds found, and where to report problems.
- **Commands:** `/dmga` (status), `/dmga config`, `/dmga burst` (major cooldowns on/off), `/dmga mode`
  (Auto / Single / AoE), `/dmga why` (where each pick came from).

## Reporting a problem

The fastest way to get something fixed:

1. Have **DMGAssist_Watchdog** installed ("DMGAssist - Report an Issue"). It records what DMGAssist saw and
   decided; there is nothing to set up.
2. Right after the problem happens, type **`/dmga report`** in game (or right-click the minimap button →
   *Report an issue*).
3. **Step 1** in the window: say **what went wrong and what you expected** (for example: *"Balance, single
   target, it never suggested Incarnation"*) and what you were doing.
4. **Step 2:** press **Ctrl+C**. Your words and the report are copied together.
5. **Step 3:** open the link shown in the window, paste with **Ctrl+V**, and press Create.

You'll get a reply on the issue, usually with a fix in the next nightly build for you to try.

**Tips for a useful report:**
- One problem per issue.
- Fight for at least 20 to 30 seconds before taking the report, so it holds a full picture.
- If it's about one fight, take the report right after that fight: it keeps the most recent ones.
- Lua errors from other addons (shown in BugSack) are fine to include; we'll tell you if one isn't ours.

**What's in a report:** your class and spec, DMGAssist's settings, what it decided and why (for recent
fights), timing and readability information, and Lua errors. Your account name is removed; no chat or
character inventory is included.

**Ideas** are welcome too: **New issue → Feature request**. Please don't post reports in CurseForge
comments: they can't be tracked or answered properly there.

## Supported

| | |
|---|---|
| **Midnight** (12.1.x) | Every spec with a SimulationCraft priority list (all DPS and tank specs) |
| **WoW Forever** | Specs with a WoWSims rotation |
| **Languages** | Messages and key bindings in English, Español, Deutsch, Français, Português, Русский, 简体中文, 繁體中文, 한국어; settings pages in English for now. |

## Credits

- Priority lists and spell data: [SimulationCraft](https://github.com/simulationcraft/simc).
- WoW Forever rotations and game data: [WoWSims](https://wowsims.com/forever) (MIT).

DMGAssist is open source (MIT): https://github.com/zonearc/dmgassistwow
