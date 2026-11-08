# DMGAssist v1.5.0.282

SimC-powered rotation HUD for WoW Midnight 12.0. Three signal sources (Assisted Highlights + proc glows + spell readiness) ranked by SimC priority into a Guitar Hero-style spell queue.

---

## Quick Start

1. Extract ZIP → `Interface/AddOns/DMGAssist/`
2. Log in → addon auto-detects your spec
3. HUD appears center-screen — drag to reposition, press keybinds shown

**Diagnostic Logging (built-in):** Enable via Options → Issues tab → "Enable Diagnostic Logging" checkbox. When enabled, captures combat events, queue snapshots, and system health data. Use `/dmgawd` to open the Event Viewer. Use "Select All" to copy the full log for sharing.

---

## Minimap Icon

| Action | Result |
|--------|--------|
| **Left-click** | Toggle HUD on/off |
| **Right-click** | Options dropdown (mode, lock, OOC hide, reset) |
| **Drag** | Move icon around minimap |

---

## HUD Controls

| Element | Action |
|---------|--------|
| **Unlocked HUD** | Left-drag to move HUD |
| **Unlocked HUD** right-click | Lock position |
| **Gear icon** (top-right) | Open full Options panel |

---

## Slash Commands

`/dmga` or `/dmgassist` — show help

### Core
| Command | What it does |
|---------|-------------|
| `/dmga options` | Open Options panel |
| `/dmga show` | Show HUD |
| `/dmga hide` | Hide HUD |
| `/dmga toggle` | Toggle HUD |
| `/dmga lock` | Lock position |
| `/dmga unlock` | Unlock position |
| `/dmga ooc` | Toggle auto-hide out of combat |

### Mode
| Command | What it does |
|---------|-------------|
| `/dmga mode` | Cycle ST → AoE → Auto |
| `/dmga mode st` | Force Single Target |
| `/dmga mode aoe` | Force AoE |
| `/dmga mode auto` | Auto-detect via nameplates |

### Diagnostics
| Command | What it does |
|---------|-------------|
| `/dmga status` | Current spec, mode, icon size, toggles |
| `/dmga spells` | Which APL spells are known vs filtered |
| `/dmga trinkets` | Equipped trinkets + cooldown status |
| `/dmga glows` | Check glow/overlay CVar health |
| `/dmga fixglows` | Auto-fix overlay CVars |
| `/dmga debug` | Toggle debug logging |
| `/dmga debug verbose` | Full condition evaluation logging |
| `/dmga debug off` | Disable debug |
| `/dmga reset` | Factory reset (reloads UI) |

---

## Options Panel

Open via: gear icon on HUD, right-click minimap → Open Options, or `/dmga options`

**General** — icon sizes (primary + next), queue slots, scale, opacity, padding/spacing, frame lock, OOC mode, header visibility

**Display** — keybind text (font size, position, color), spell names, cooldown text, GCD spark, resource bar + cap threshold, condition text, prediction icons + opacity

**Combat** — AoE threshold, interrupt sound, form awareness, trinket tracking

**Sounds** — configurable sound alerts for interrupts, ST/AoE mode switches

**Buffs** — consumable buff alerts (flask, food, weapon enhancement, augment rune)

**Issues** — live diagnostic: spec detection, APL status, glow health, runtime errors, condition errors. Auto-Fix Glows button.

---

## Supported Specs (39)
- Blood Death Knight (Tank)
- Frost Death Knight (Melee DPS)
- Unholy Death Knight (Melee DPS)
- Havoc Demon Hunter (Melee DPS)
- Vengeance Demon Hunter (Tank)
- Balance Druid (Ranged DPS)
- Feral Druid (Melee DPS)
- Guardian Druid (Tank)
- Restoration Druid (Healer)
- Devastation Evoker (Ranged DPS)
- Augmentation Evoker (Ranged DPS)
- Preservation Evoker (Healer)
- Beast Mastery Hunter (Ranged DPS)
- Marksmanship Hunter (Ranged DPS)
- Survival Hunter (Melee DPS)
- Arcane Mage (Ranged DPS)
- Fire Mage (Ranged DPS)
- Frost Mage (Ranged DPS)
- Windwalker Monk (Melee DPS)
- Mistweaver Monk (Healer)
- Brewmaster Monk (Tank)
- Retribution Paladin (Melee DPS)
- Protection Paladin (Tank)
- Holy Paladin (Healer)
- Shadow Priest (Ranged DPS)
- Discipline Priest (Healer)
- Holy Priest (Healer)
- Assassination Rogue (Melee DPS)
- Outlaw Rogue (Melee DPS)
- Subtlety Rogue (Melee DPS)
- Elemental Shaman (Ranged DPS)
- Enhancement Shaman (Melee DPS)
- Restoration Shaman (Healer)
- Affliction Warlock (Ranged DPS)
- Demonology Warlock (Ranged DPS)
- Destruction Warlock (Ranged DPS)
- Arms Warrior (Melee DPS)
- Fury Warrior (Melee DPS)
- Protection Warrior (Tank)

Generated: 2026-09-18T03:33:49.108Z
