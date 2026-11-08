---
name: wow-midnight-class-data
description: WoW 12.0 Midnight class/spell changes reference. MUST READ before modifying any APL, spell list, or rotation logic. Contains confirmed spell removals, additions, and reworks per spec. Prevents breaking changes from outdated pre-12.0 knowledge.
---

# WoW 12.0 Midnight Class & Spell Reference

**MANDATORY**: Read this skill BEFORE making ANY change to:
- `server/community-apls.ts` (APL entries)
- Any spell ID, spell name, or condition in the codebase
- Any decision about whether a spell is "castable", "passive", "removed", etc.

**RULE**: NEVER assume spell behavior from pre-12.0 knowledge. If you are unsure whether a spell exists, is castable, or has changed, SEARCH THE WEB first. Do not guess.

**RULE**: If the user tells you a spell works differently than you expect, BELIEVE THEM. They are playing the live game. Update this file immediately with the corrected information.

---

## Expansion Context

- **Pre-patch**: January 21, 2026 (Patch 12.0.1)
- **Launch**: March 2, 2026 (Early Access Feb 27)
- **Season 1**: March 17, 2026
- **Level cap**: 90 (+10 talent points, Apex Talents added)
- **TOC Interface**: 120001
- **New spec**: Devourer Demon Hunter (Void-themed mid-range caster DPS)

---

## CRITICAL: Spells That Changed From Passive to Active

These spells were passive/proc-based in previous expansions but are NOW CASTABLE BUTTONS in 12.0:

| Spell | Spec | Change | Spell ID |
|-------|------|--------|----------|
| **Lunar Eclipse** | Balance Druid | Was passive proc from 2x Starfire. Now an ACTIVE BUTTON with 2 charges, 32s CD. Transforms based on last filler cast. Live AC ID: 1233272. Old beta/base ID 1239669 is NOT the castable button. | 1233272 |
| **Solar Eclipse** | Balance Druid | Same as Lunar Eclipse — now an active castable button. | (paired with Lunar) |
| **Eclipse (generic)** | Balance Druid | The button transforms: cast Wrath first → button becomes Solar Eclipse. Cast Starfire first → button becomes Lunar Eclipse. 15s duration per Eclipse. |

**NEVER remove these from APLs. They are core rotational spells.**

If you see "A more powerful spell is already active" for Eclipse spells, that means the Eclipse BUFF is currently up. The fix is to add a `!buff.X` condition, NOT to remove the spell.

---

## REMOVED SPELLS (Do NOT add these to APLs)

### Death Knight
| Removed | Spec | Replacement |
|---------|------|-------------|
| Festering Wounds (mechanic) | Unholy | Lesser Ghoul stacks (player-based) |
| Apocalypse | Unholy | Removed entirely |
| Defile | Unholy | Removed |
| Legion of Souls | Unholy | Removed |
| Rune Tap | Blood | Removed |

### Demon Hunter
| Removed | Spec | Notes |
|---------|------|-------|
| Sigil of Flame | Havoc | Now Vengeance-only |

### Druid
| Removed | Spec | Notes |
|---------|------|-------|
| Efflorescence (castable) | Restoration | Now passive, no longer a button |

### Mage
| Removed | Spec | Notes |
|---------|------|-------|
| Phoenix Flame | Fire | Removed |

### Monk
| Removed | Spec | Notes |
|---------|------|-------|
| Storm, Earth, and Fire | Windwalker | Removed (WC3 classic) |
| Jadefire Stomp | Mistweaver | Removed |

### Paladin
| Removed | Spec | Notes |
|---------|------|-------|
| Blessing of Summer (all seasonal) | Holy | All seasonal blessings removed |

### Shaman
| Removed | Spec | Notes |
|---------|------|-------|
| Feral Spirit | Enhancement | Removed (WC3 classic) |

### Warrior
| Removed | Spec | Notes |
|---------|------|-------|
| Avatar | Multiple | Removed |

### Healer Interrupts
ALL healer specs lost their interrupts EXCEPT Resto Shaman (Wind Shear, 30s CD).

---

## NEW SPELLS & REWORKS (Add to APLs if missing)

### Death Knight — Unholy (FULL REWORK)
| New/Changed | Type | Notes |
|-------------|------|-------|
| Putrefy | New ability | 15s CD, 2 charges. Sacrifices Lesser Ghoul for AoE + RP. Core rotational anchor. |
| Festering Strike | Reworked | Now applies Lesser Ghoul stacks to PLAYER (not target). 2-3 per cast, stack to 8. |
| Scourge Strike | Reworked | Consumes Lesser Ghoul stacks, summons ghouls. 30yd range baseline. Passively cleaves 4+ targets. |
| Festering Scythe | New | Free cast, no rune cost. Maintains disease tick-rate buff. |
| Dark Transformation | Redesigned | Creates "Monstrosity," extended by Death Coil/Epidemic. |
| Army of the Dead | Changed | CD reduced to 1.5 min, now primary CD. |
| Dread Plague | New | Single-target plague, applied by Outbreak. |

### Demon Hunter — Devourer (NEW SPEC)
| Ability | Notes |
|---------|-------|
| Consume | Fury generator, spawns Soul Fragments, castable while moving |
| Void Ray | Main spender (100 Fury), resets Reap CD, free in Void Meta |
| Reap / Cull | Collects Soul Fragments, triggers Voidfall stacks |
| Void Metamorphosis | Transformation from Soul Fragments, drains Fury |
| Collapsing Star | Big nuke, spammable in Void Meta |
| Eradicate | AoE ability |

### Druid — Balance (ECLIPSE REWORK)
| Changed | Notes |
|---------|-------|
| Eclipse | Now an active button (2 charges, 32s CD, 15s duration). Transforms based on last filler. |
| Lunar Eclipse | Active castable (was passive). Increases Arcane damage 15%, boosts Starfire. |
| Solar Eclipse | Active castable (was passive). Increases Nature damage 15%, boosts Wrath. |
| Eclipse Buffs | In-game tooltip shows "Eclipse (Solar)" and "Eclipse (Lunar)". CLEU buff name may be just "Eclipse" without qualifier. Buff spell IDs may differ from legacy 48517/48518. Detection uses multi-ID + name + description fallback. |
| Starfall DoT Extension | Starfall extends Moonfire/Sunfire/Stellar Flare durations via SPELL_AURA_REFRESH events. Lockout timer must preserve extended expiration. |
| Starsurge | 40 AP cost, instant, usable in both ST and AoE for empowerment |
| Mastery | Reworked — permanent damage buff, no longer DoT-conditional |

### Druid — Guardian (NEW ABILITIES)
| New | Notes |
|-----|-------|
| Memory of Ysera | Heal per Rage spent |
| Red Moon | Channel arcane damage, extended by Mangle |
| Sundering Roar | Reset Thrash CD, allow extra stacks |
| Waking Nightmare | Summon Dread Shade mirroring Thrash |

### Rogue — ALL SPECS (FULL REWORK)

#### Assassination
| Changed | Notes |
|---------|-------|
| Crimson Tempest | Reworked from finisher to GENERATOR that spreads bleeds |
| Cold Blood | Now passive (was active CD) |
| Serrated Bone Spike | REMOVED |
| Indiscriminate Carnage | REMOVED |
| Improved Shiv | REMOVED (Shiv no longer rotational) |

#### Outlaw
| Changed | Notes |
|---------|-------|
| Roll the Bones | Reworked: 4 unified buffs with layered bonuses (was 6 random) |
| Count the Odds | REMOVED |
| Crackshot | REMOVED |
| No more Vanish loops | Consistent build-spend, no stealth resets |

#### Subtlety
| Changed | Notes |
|---------|-------|
| Burst window | Shifted to 90-second cycle (was 30-second hybrid) |
| More ST focus | Reduced AoE output |

### Warrior
| Changed | Notes |
|---------|-------|
| Piercing Howl | CD increased 30s → 90s |
| Die by the Sword / Ignore Pain | Arms can only pick ONE (talent choice) |
| Avatar | REMOVED |

### Shaman — Enhancement
| Changed | Notes |
|---------|-------|
| Feral Spirit | REMOVED |

### Monk — Windwalker
| Changed | Notes |
|---------|-------|
| Storm, Earth, and Fire | REMOVED |

---

## AGENT RULES FOR SPELL DECISIONS

### Rule 1: Never Remove A Spell Without Verification
Before removing ANY spell from an APL or marking it as "uncastable":
1. Search the web for current 12.0 status
2. Check this skill file
3. If the user has confirmed it's castable, it IS castable

### Rule 2: "A more powerful spell is already active" ≠ Uncastable
This WoW error means the spell's BUFF is currently active. Fix: add a `!buff.X` condition. Do NOT remove the spell.

### Rule 3: New Spell IDs
12.0 introduced many new spell IDs (e.g., Lunar Eclipse 1239669). These are VALID modern IDs. Do not assume old IDs are "correct" — the new ones may be the active versions.

### Rule 4: When In Doubt, Research
Use web search to verify spell status before making changes. Search for:
`"WoW 12.0 Midnight [ClassName] [SpellName] rotation guide 2026"`

### Rule 5: Update This File
When you learn new information about spell changes (from user feedback or research), IMMEDIATELY update this file. This is a living document.

---

## Current APL Gaps (Known Issues)

### Specs with full reworks needing APL review:
- **Unholy DK**: Festering Wounds removed, Lesser Ghoul system, Putrefy is new core ability
- **All Rogue specs**: Complete overhaul, many abilities removed/replaced
- **Devourer DH**: Entirely new spec, needs APL from scratch
- **Balance Druid**: Eclipse is now active (partially addressed — Lunar Eclipse in APL with `!buff.lunar_eclipse` condition)

### Spells that may need removal from APLs:
- Any reference to Apocalypse (Unholy DK)
- Any reference to Festering Wounds (Unholy DK)
- Sigil of Flame on Havoc DH
- Phoenix Flame on Fire Mage
- Storm Earth and Fire on WW Monk
- Feral Spirit on Enhancement Shaman
- Avatar on Warrior specs

### Spells that may need ADDING to APLs:
- Putrefy (Unholy DK)
- Festering Scythe (Unholy DK)
- Eclipse active button (Balance Druid) — partially done
- Devourer DH full rotation (new spec)
