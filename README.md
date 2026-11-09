# DMGAssist

**A rotation helper for World of Warcraft: Midnight (12.x) and WoW Forever.**
DMGAssist shows the next three spells to press, in priority order, and flashes the moment to press them.
It is built for 12.x's "secret values" rules from the ground up: no combat-log scraping, no protected calls,
nothing automated. You press every button.

> **Early access.** DMGAssist is under active development, with frequent updates on CurseForge.
> If something looks wrong, [tell us](#reporting-a-problem): reports are read and worked through every night.

---

## What it does

- **Three slots, in priority order.** Slot 1 is what to press when your global cooldown ends; slots 2 and 3 come
  next. Nothing else to watch: Blizzard's Cooldown Manager already covers readiness.
- **Real priority lists.** Midnight uses [SimulationCraft](https://github.com/simulationcraft/simc)'s priority
  lists for every spec; WoW Forever uses [WoWSims](https://wowsims.com/forever). Both refresh weekly.
- **What matters most comes first:** interrupts, then defensives, then the rotation. Major cooldowns are ordinary
  lines in the rotation, or switched off entirely.
- **Timed to your GCD and casts.** A flash 50 ms before you can press (adjustable). Slot 1 is held steady in the
  last half second, so it doesn't flicker as the decision settles.
- **Single target / AoE, automatically.** Enemies in combat are counted from nameplates (range-aware;
  training dummies are recognised). A colour-coded title row shows `ST` / `AOE` and the count in combat.
- **It learns your play.** Skip the slot-1 spell three times and it is held until combat ends; cast it yourself and it
  comes back. Optionally, keep major cooldowns for bosses and big pulls.
- **Tank and melee essentials.** Guardian keeps Ironfur stacks (default 3) and Moonfire up. Melee specs out of
  range get their charge or leap first (Wild Charge, Charge, Shadowstep, Harpoon, Feral Lunge, Death Grip).
- **On-use trinkets.** Every equipped on-use trinket is shown when it is ready, alongside your cooldowns (and
  when SimC's list says to use it). Switch off any trinket you'd rather press yourself; the choice follows the
  trinket through gear and spec swaps.
- **Healers too.** SimC publishes no rotation for most healing specs, so DMGAssist ships its own damage lists
  for Discipline, Holy Priest, Holy Paladin, Mistweaver, Restoration Shaman and Preservation (learned from the
  current class guides) for your damage between heals (SimC's own list takes over if it ever publishes one). Restoration
  Druid uses SimC's list, cat weaving included. Healing itself stays your call.
- **Discipline Atonement.** Atonements counted from your casts on slot 1's corner, and a ramp (Radiance, then
  Shield) before the big hits your boss mod warns about, until enough are up.
- **Buff reminders.** Out of combat, a missing buff goes in slot 1 before the pull: raid buffs (Arcane
  Intellect, Fortitude, Mark of the Wild, Battle Shout, Blessing of the Bronze, Skyfury) on you or anyone in
  range, Lightning / Water Shield, shaman weapon imbues, rogue poisons, and Earth Shield or Beacon of Light on your
  tank. Also when one runs out within 5 minutes. Each can be hidden; Combat > Buff reminders turns it off.
- **Your choice of spells.** Settings > DMGAssist > Spells & trinkets lists every spell your spec can be shown
  and every equipped on-use trinket. Untick one and it is never shown; the next spell takes its place. Tick
  "First when ready" and that spell goes to slot 1 whenever it can be cast. Kept per spec (trinkets per item),
  so updates and gear swaps keep your choices.
- **Missing keybinds check.** Lists every spell and trinket it can recommend that has no key binding, with
  icons (Settings > DMGAssist > Missing keybinds, or `/dmga unbound`), so you find out before the pull.
- **Works with what you have.** DBM, BigWigs and LittleWigs timers (or Blizzard's encounter timeline) for adds,
  AoE and tank hits; keybinds read from Blizzard's bars, Bartender and macros; Blizzard's Assisted Combat as a
  second opinion where the game hides information.
- **Learns your real cooldowns.** Talents, gear, set bonuses and haste change cooldowns in ways the game doesn't
  always let addons see. DMGAssist knows the interactions SimulationCraft simulates (Kill Command taking time off
  Wildfire Bomb, Crusader Strike off Judgment, and so on, imported weekly), then checks its timing against the game
  every fight: a steady difference is corrected, and a spell whose timing jumps around is left to Blizzard's
  Assisted Combat until the two agree again. What it learns is saved for your whole account and improves as you
  play; Settings > DMGAssist > Learned timing (or `/dmga relearn`) starts it over.
- **Leveling and alts, automatically.** A new character's starter spec, and any character below max level that
  knows only a few of the spells the priority list expects, follow Blizzard's Assisted Combat, which is built for
  exactly that. It switches to the SimC list by itself as you learn more. Learn a spell with no key and you get one
  chat line (not when the game already put it on a keyed button); unspent talent points after a level-up too.
- **Per spec.** Switch DMGAssist off for one spec only (an alt's healing spec you play without it): minimap menu,
  Spells & trinkets page, or `/dmga spec off`.
- **Range and resource colors.** Like the action bars: an icon turns red when the target is out of range, and slot 1
  turns blue when you are short of resource.
- **Three questions to start.** Where the HUD goes, how big, when it shows, each with a suggested answer.
  Once per settings profile, so alts sharing one are asked once (`/dmga welcome` to redo it).
- **Fits your UI.** Blizzard's Edit Mode places it with everything else; Masque skins its icons like your bars;
  a Titan Panel / ElvUI data-text launcher; controller players see their buttons (`LT+A`, Xbox or PlayStation
  names); WeakAuras and UI packs can read every recommendation through `DMGAssistAPI` (see below).
- **Your language.** English, Deutsch, Español, Français, Italiano, Português, Русский, 한국어, 简体中文 and 繁體中文,
  following the game's language or picked in the settings. Spells are matched by ID, so any client works.

## Install

Install DMGAssist from **[CurseForge](https://www.curseforge.com/wow/addons/dmgassist)**: the CurseForge app installs
it and keeps it up to date by itself. That is the only download. (The CurseForge page also has the zip for a manual
install: unzip it into `World of Warcraft/_retail_/Interface/AddOns/`.) The package holds DMGAssist and its
*Report an Issue* tool, which shows under DMGAssist in the game's AddOns list.

## Using it

The icons appear in combat, or out of combat with an enemy targeted. Drag them where you like
(`/dmga lock` to unlock and lock), or move them in Blizzard's Edit Mode.

| Where | What |
|---|---|
| **Minimap button** | Left-click: show/hide · drag: move · right-click: settings, Report an issue, quick toggles |
| **Settings** | Options → AddOns → **DMGAssist**: Status, Combat, Display, Sounds, Integrations, Advanced |
| **Key bindings** | Options → Keybindings → AddOns → DMGAssist: switch target mode (Auto / Single / AoE), major cooldowns on/off, show/hide |

The **Status** page shows the version, the spec and rotation detected, the target mode, boss mods and keybinds found,
and where to report problems.

### Slash commands

| Command | |
|---|---|
| `/dmga` | status: client, spec, data version, spells matched |
| `/dmga config` | open the settings |
| `/dmga on` · `off` | show or hide |
| `/dmga burst` | major cooldowns on/off |
| `/dmga mode st` · `aoe` | target mode; `/dmga mode` alone cycles Auto → Single → AoE |
| `/dmga auto on` · `off` | count targets from nameplates |
| `/dmga targets 4` | AoE switch point (default: your spec's own) |
| `/dmga fight 180` | assumed fight length (default: learned from your fights) |
| `/dmga queue 1`–`3` | how many spells to show |
| `/dmga lock` | lock / unlock the icons |
| `/dmga why` | the queue, where each pick came from, and list spells you don't have |
| `/dmga report` | report an issue or give feedback (also `/dmga issue`, `/dmga feedback`) |
| `/dmga welcome` | the three setup questions again |
| `/dmga spec on` · `off` | DMGAssist on or off for the spec you are in (also on the minimap menu) |
| `/dmga unbound` | spells it can recommend that have no key binding |
| `/dmga relearn` | forget learned cooldown timing and start learning again |
| `/dmga test interrupt` · `defensive` · `bossmods` · `assisted` | check the integrations (also Settings > Integrations) |

### For addon and UI pack authors: `DMGAssistAPI`

```lua
local rec = DMGAssistAPI.GetRecommendation()
-- nil, or { spells = { { spellID, texture, key, source, item }, ... up to 3 },
--          interrupt = {...} or nil, defensive = {...} or nil, offGCD = {...} or nil, mode = "AUTO" | "ST" | "AOE" }
local handle = DMGAssistAPI.RegisterCallback(function(rec) ... end) -- runs when the pick changes
DMGAssistAPI.UnregisterCallback(handle)
DMGAssistAPI.SetHUDHidden(true)   -- keep deciding, hide DMGAssist's own icons (draw them yourself); not saved
DMGAssistAPI.SetEnabled(true)  DMGAssistAPI.CycleMode()  DMGAssistAPI.ToggleCooldowns()  DMGAssistAPI.OpenSettings()
```

A broken callback is dropped and never breaks DMGAssist. With LibDataBroker loaded (Titan Panel, ElvUI,
ChocolateBar...) a "DMGAssist" launcher shows the target mode: left-click show/hide, right-click settings,
middle-click target mode.

## Reporting a problem

Install **DMGAssist_Watchdog** ("DMGAssist - Report an Issue" in the AddOns list) next to DMGAssist. It records
what DMGAssist saw and decided, with no setup. Right after the problem, type `/dmga report` (or right-click the
minimap button → *Report an issue*). The window walks you through it:

1. **Step 1:** type what went wrong and what you expected, and what you were doing.
2. **Step 2:** the report is already selected: press **Ctrl+C**. Your words are copied with it.
3. **Step 3:** copy the link shown, open it in your browser, paste with **Ctrl+V** and press Create.

You'll get a reply on the issue, usually with a fix in the next CurseForge update.
Ideas are welcome too: [feature request](https://github.com/zonearc/dmgassist-issues/issues/new?template=feature_request.yml).

The report contains your spec, settings, what DMGAssist decided and why, and Lua errors. Your account name is
removed.

## Supported

| | |
|---|---|
| **Midnight** (12.1.x) | every spec with a SimulationCraft priority list |
| **WoW Forever** | specs with a WoWSims rotation |
| **Languages** | everything (settings, messages, report window): English, Deutsch, Español, Français, Italiano, Português, Русский, 한국어, 简体中文, 繁體中文. Follows the game's language; Settings > DMGAssist > Language picks another (Chinese and Korean need that game client's fonts). |

## How it works (short)

The game hides many combat values from addons in 12.x (your own resources and procs, enemy health, cast details).
DMGAssist evaluates the priority list with what it can read, tracks what it can infer from your own casts
(cooldowns, DoTs, stacks, charges, resource floors), works with ranges where a value is hidden, and uses
Blizzard's Assisted Combat to confirm lines it can't decide. Where only the game knows (e.g. 4 or 5 combo points),
it lets the game choose which icon is visible without ever reading the value.
Cooldowns come from the game where it shows them and from SimulationCraft's class code (which spell shortens which)
where it doesn't; every fight, the timing is measured against Blizzard's own pick and against when you actually
cast, and corrected (both ways) from what it learns. Spells it can't time reliably are left to Blizzard.
Design notes: [docs/design](docs/design) · verified API facts: [docs/reference/api-findings.md](docs/reference/api-findings.md).

## Development

```
./scripts/fetch-ui-source.sh   # Blizzard UI source (Forever + live) into .libraries/
./scripts/check.sh             # luac, luacheck, all tests; required before every commit
./scripts/package.sh           # zips into dist/
python3 tools/simc_import.py --simc .libraries/simc   # regenerate addons/DMGAssist/Data
python3 tools/decode-export.py report.txt             # read a Watchdog report
```

Needs Lua 5.1 and `luacheck`. Rules and architecture: [CONTRIBUTING.md](CONTRIBUTING.md) · in-game testing:
[TESTING.md](TESTING.md).

**Automation:** every push runs the checks and builds a nightly test package (for testers). Weekly jobs pull new
SimulationCraft data and watch Blizzard's API documentation, each opening a pull request when something changed.
A weekly job (or `[release]` in a commit message) uploads the current build to CurseForge; there are no GitHub releases. Issues are triaged nightly following
[docs/process/issue-triage.md](docs/process/issue-triage.md).

## Credits

- Priority lists and spell data: [SimulationCraft](https://github.com/simulationcraft/simc).
- WoW Forever rotations and game data: [WoWSims](https://wowsims.com/forever)
  ([wowsims/forever](https://github.com/wowsims/forever), [wowsims/gamedata](https://github.com/wowsims/gamedata), MIT).

## License

© 2026 zonearc, **all rights reserved** ([LICENSE](LICENSE)). You may download DMGAssist from
[CurseForge](https://www.curseforge.com/wow/addons/dmgassist) and play with it, and read the code here to report problems;
please don't re-upload or redistribute it. The SimulationCraft data (GPL-3.0) and WoWSims data (MIT) it includes keep
their own licences: see [NOTICE.md](NOTICE.md).
