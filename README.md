# DMGAssist

**A rotation helper for World of Warcraft: Midnight (12.x) and WoW Forever.**
DMGAssist shows the next three spells to press, in priority order, and flashes the moment to press them.
It is built for 12.x's "secret values" rules from the ground up: no combat-log scraping, no protected calls,
nothing automated. You press every button.

> **Early access.** DMGAssist is under active development, with a nightly build after every change.
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
- **Your choice of spells.** Settings > DMGAssist > Spells & trinkets lists every spell your spec can be shown
  and every equipped on-use trinket. Untick one and it is never shown; the next spell takes its place. Tick
  "First when ready" and that spell goes to slot 1 whenever it can be cast. Kept per spec (trinkets per item),
  so updates and gear swaps keep your choices.
- **Missing keybinds check.** Lists every spell and trinket it can recommend that has no key binding, with
  icons (Settings > DMGAssist > Missing keybinds, or `/dmga unbound`), so you find out before the pull.
- **Works with what you have.** DBM, BigWigs and LittleWigs timers (or Blizzard's encounter timeline) for adds,
  AoE and tank hits; keybinds read from Blizzard's bars, Bartender and macros; Blizzard's Assisted Combat as a
  second opinion where the game hides information.
- **Every client language.** Spells are matched by ID, so any client works.

## Install

**CurseForge / Wago:** coming soon.

**Automatic updates with WowUp (recommended for testers):** install [WowUp](https://wowup.io), then
**Get Addons → Install from URL** and paste `https://github.com/zonearc/dmgassistwow`. It installs the latest weekly
release and keeps it updated. WowUp leaves the addons other managers (the CurseForge app) installed alone; just
don't update those from WowUp.

**Manual:** download `DMGAssist-<version>.zip` from the [latest release](../../releases/latest) (or `DMGAssist.zip`
from the [nightly build](../../releases/tag/nightly)) and unzip it into `World of Warcraft/_retail_/Interface/AddOns/`.
It holds DMGAssist and its Watchdog (the report tool), which shows under DMGAssist in the game's AddOns list.

**Windows, automatic (AutoHotkey):** `DMGAssist_Updater.zip` on the nightly page has a small updater that starts with
Windows and keeps DMGAssist up to date in retail and Forever. See [tools/updater](tools/updater/README.md).

## Using it

The icons appear in combat, or out of combat with an enemy targeted. Drag them where you like
(`/dmga lock` to unlock and lock).

| Where | What |
|---|---|
| **Minimap button** | Left-click: show/hide · drag: move · right-click: settings, Watchdog report, quick toggles |
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

## Reporting a problem

1. Install **DMGAssist_Watchdog** next to DMGAssist. It records what DMGAssist saw and decided, with no setup.
2. After the problem, type `/dmgw` in game. The report opens already selected: press **Ctrl+C**.
3. [Open a bug report](../../issues/new/choose), say what happened, and paste the report.

You'll get a reply on the issue, usually with a fix in the next nightly build to try.
Ideas are welcome too: **New issue → Feature request**.

The report contains your spec, settings, what DMGAssist decided and why, and Lua errors. Your account name is
removed.

## Supported

| | |
|---|---|
| **Midnight** (12.1.x) | every spec with a SimulationCraft priority list |
| **WoW Forever** | specs with a WoWSims rotation |
| **Languages** | messages and key bindings: English, Español, Deutsch, Français, Português, Русский, 简体中文, 繁體中文, 한국어. Settings pages are English for now. |

## How it works (short)

The game hides many combat values from addons in 12.x (your own resources and procs, enemy health, cast details).
DMGAssist evaluates the priority list with what it can read, tracks what it can infer from your own casts
(cooldowns, DoTs, stacks, charges, resource floors), works with ranges where a value is hidden, and uses
Blizzard's Assisted Combat to confirm lines it can't decide. Where only the game knows (e.g. 4 or 5 combo points),
it lets the game choose which icon is visible without ever reading the value.
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

**Automation:** every push runs the checks and publishes the nightly release. Weekly jobs pull new
SimulationCraft data and watch Blizzard's API documentation, each opening a pull request when something changed.
Tagging `vX.Y.Z` builds a release (and uploads to CurseForge when enabled). Issues are triaged nightly following
[docs/process/issue-triage.md](docs/process/issue-triage.md).

## Credits

- Priority lists and spell data: [SimulationCraft](https://github.com/simulationcraft/simc).
- WoW Forever rotations and game data: [WoWSims](https://wowsims.com/forever)
  ([wowsims/forever](https://github.com/wowsims/forever), [wowsims/gamedata](https://github.com/wowsims/gamedata), MIT).

## License

[MIT](LICENSE)
