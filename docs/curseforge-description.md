# DMGAssist: your damage assistant

**DMGAssist shows the next three spells to press for the most damage, and learns as you play.**
It follows SimulationCraft's priority lists, the same ones theorycrafters use, tuned with numbers measured from
thousands of real players' fights, and flashes the moment to press. You press every button; it never plays for you.

**What you see in the first minute is not where it ends.** During every fight DMGAssist measures what the game
lets it see: how much your spells really give, when your cooldowns come back, how your resources move between
pulls. It corrects itself as you go and remembers per spec and talent build, so recommendations get sharper over a
single session and keep improving from there.

**Works on World of Warcraft: Midnight and WoW Forever.**

---

## What it does

- Shows your next three spells, in priority order
- Flashes the exact moment to press, timed to your GCD
- Self-learning: corrects resource gains, cooldown timing and your own patterns during play, kept per spec and build
- Crowd-tuned: resource gains, passive income and out-of-combat behaviour measured from thousands of real players'
  logs for every spec, refreshed as patches change things
- Switches between single target and AoE automatically
- Interrupts and defensives come first when they matter
- Major cooldowns used where SimulationCraft uses them, or held
- Every spec: DPS, tanks (mitigation timed in its own icon), and healers' damage between heals
- Leveling and alts: follows Blizzard's suggestions until you're ready
- Reminds you of missing buffs, poisons and weapon imbues
- Warns about spells on your bars with no keybind
- A grade after every fight (S+ to D): accuracy, always casting, reaction and cooldowns, with your best and a tip
- Trinkets and your chosen potion in their own icon, defensives in another: the three slots stay your rotation

## Highly customizable

- Hide any spell, or put it first when ready
- Switch any trinket off; your choices follow your gear
- Size, position, fonts, colors, sounds and labels
- Move it in Blizzard's Edit Mode with everything else
- Turn it off per spec, or keep cooldowns for bosses
- Profiles per character, or one shared by all alts
- A short welcome and four-question setup on first login

## Built on SimulationCraft

- Imports SimulationCraft's priority list for every spec, weekly
- Checks each line against what the game shows
- Blizzard's Assisted Combat confirms what the game hides
- Knows which spells shorten which, from SimulationCraft's class code: talents, set bonuses and haste
- Learns from your fights, saved for your whole account; one click starts it over
- DMGAssist's own lists cover healers SimulationCraft skips

## Works with

- **DBM, BigWigs, LittleWigs:** defensives before big hits, interrupts on call
- **Masque:** icons skinned to match your action bars
- **Controllers:** shows your controller buttons, Xbox or PlayStation
- **Blizzard's Cooldown Manager and Assisted Combat:** used, never replaced
- **Addon authors:** `DMGAssistAPI` for UI packs and custom displays

## Getting started

1. Install, log in, answer three quick questions.
2. Fight something. Press what slot 1 shows.
3. `/dmga` for settings, `/dmga help` for commands.

## Found a problem?

Type **`/dmga report`** in game: describe it, copy, paste. Reports go to
https://github.com/zonearc/dmgassist-issues and are answered there.

## Languages

English, Deutsch, Español, Français, Italiano, Português, Русский, 한국어, 简体中文, 繁體中文.

## Credits

- [SimulationCraft](https://github.com/simulationcraft/simc): priority lists and spell data (GPL-3.0)
- [WoWSims](https://wowsims.com/forever): WoW Forever rotations and game data (MIT)
- DBM, BigWigs, LittleWigs, Masque: thank you

© 2026 zonearc, all rights reserved. Please don't re-upload DMGAssist elsewhere.
