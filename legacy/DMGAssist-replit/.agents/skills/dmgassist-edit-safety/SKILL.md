---
name: dmgassist-edit-safety
description: Safety rules for editing DMGAssist codebase. Use BEFORE making any code changes to gen-engine.ts, Dashboard.tsx, or any file with generated Lua output. Prevents cascading breakages from edits.
---

# DMGAssist Edit Safety Rules

These rules exist because of real breakages. Every rule corresponds to a class of failure that has happened in this project. Read before editing.

## Rule 0: MANDATORY Pre-Check for ANY Spell/Class Changes

**Before modifying ANY spell, APL entry, rotation logic, or class-specific code:**
1. Read `.agents/skills/wow-midnight-class-data/SKILL.md` FIRST
2. If the spell/mechanic is not documented there, SEARCH THE WEB for its 12.0 Midnight status
3. NEVER assume spell behavior from pre-12.0 knowledge (Dragonflight, TWW, etc.)
4. If the user has told you a spell works a certain way, BELIEVE THEM and update the class data skill

This rule exists because of repeated breakages from removing spells that changed from passive to active in 12.0 (e.g., Lunar Eclipse), or adding spells that were removed (e.g., Apocalypse).

## Rule 1: Verify After Every Edit (No Batching Blind Edits)

**Never** chain multiple edits to the same file without verifying the intermediate state compiles/passes.

- After editing `gen-engine.ts`: Generate Lua and run `luac -p` before making the next edit.
- After editing any `.tsx` file: Confirm the dev server compiles without errors before making the next edit.
- After editing `gen-watchdog.ts` or `gen-settings.ts`: Generate and `luac -p`.

**Why**: A single bad edit (wrong indentation, orphan bracket, mismatched block) cascades. If you make 5 edits before checking, you have 5 possible failure points and no idea which one broke it.

## Rule 2: Lua Generation — The `end` Problem

The generated Lua has deeply nested if/else/end blocks. When removing a wrapper `if` block:

1. Count the `end` statements BEFORE the edit.
2. Identify which `end` closes the block you're removing.
3. Remove exactly that `end` — not the one above it, not the one below it.
4. Count the `end` statements AFTER the edit and confirm the delta is exactly -1 per removed block.
5. Run `luac -p` immediately.

**Why**: The most common gen-engine.ts breakage is orphan `end` statements or missing `end` statements from block removal. An orphan `end` is a syntax error. A missing `end` causes every subsequent block to nest incorrectly.

## Rule 3: Never Remove Imports/Components Without Grepping First

Before removing any import, component, function, or variable:

1. Grep the file for every reference to that symbol.
2. Confirm the count is zero (excluding the definition itself).
3. Only then remove it.

**Why**: Removing a component that's still referenced elsewhere causes a compile error. Removing an import that's still used causes a runtime crash. This happened multiple times with icon imports and helper components.

## Rule 4: String Template Edits — Watch for Lua Syntax in TypeScript

When editing TypeScript string templates that generate Lua:

- Template literals use `${expr}` — make sure you don't accidentally nest template literals.
- Lua strings inside templates use single quotes or `[[...]]` — never backticks.
- Lua comments are `--`, not `//`. Watch for accidentally inserting JS comments into Lua output.
- Lua has no `?` regex quantifier, no `goto`, no em-dashes in comments/strings.
- After ANY edit to a string template that produces Lua, regenerate and `luac -p`.

## Rule 5: Dashboard.tsx — Component Dependency Chain

The Dashboard has helper components (`ArchSection`, `ComplianceItem`, `StatCard`, `FeatureCard`, `MiniStep`, `TabButton`, `SpecsBar`, `AudienceCard`) used by tab components (`AboutTab`, `HowItWorksTab`, `HelpTab`).

Before removing or renaming ANY helper component:
1. Grep for all uses across all tab functions.
2. If moving content between tabs, ensure the helper component is still defined and accessible.
3. If a helper is only used in one tab and that tab's content is removed, remove the helper too — but grep first (Rule 3).

## Rule 6: Edit Scope — Smallest Possible Change

When the user asks for a content change (rewrite text, move a section, shorten copy):

1. Identify the exact lines that need to change.
2. Change ONLY those lines.
3. Do not refactor surrounding code, rename variables, reorganize imports, or "clean up" adjacent code unless explicitly asked.

**Why**: Scope creep is the #1 cause of cascading breakages. A "simple text rewrite" that also reorganizes component structure, renames helpers, and adjusts imports touches 10x more surface area than needed.

## Rule 7: gen-engine.ts — Bar-Only Architecture (APL Fallback REMOVED)

The APL fallback candidate injection path was removed. The engine now uses a single candidate path: the bar scanner. AC injection is also bar-gated — spells not on the action bars are skipped entirely.

Before touching anything near line 3000+:
1. Read at least 100 lines of context above and below.
2. Trace the if/else/end nesting manually.
3. Make the edit.
4. Generate + `luac -p`.

**DO NOT re-add an APL fallback path.** See Principle 4 in dmgassist-coding-principles for the rationale.

## Rule 8: Test Suite After Engine Changes

After any change to `gen-engine.ts`, `gen-watchdog.ts`, or `gen-settings.ts`:

1. Generate Lua and `luac -p` (syntax check).
2. Run `npx vitest run` (all 268+ tests).
3. Both must pass before considering the edit complete.

Do NOT skip the test suite because "it was just a small change." Small changes to the generator can break dozens of specs.

## Rule 9: Read Before Writing

Before editing any file:
1. Read the section you're about to change (at minimum 20 lines of context above and below).
2. Understand what's there before replacing it.
3. If using the edit tool, copy the exact text — don't paraphrase or approximate whitespace.

**Why**: Edits that assume file content without reading it first frequently target the wrong lines, use stale content, or miss indentation differences.

## Rule 10: One Concern Per Edit Session

If the user asks for multiple changes (e.g., "rewrite the hero text AND shorten the How It Works tab AND update the feature cards"), treat each as a separate mini-task:

1. Do concern A. Verify it compiles/works.
2. Do concern B. Verify it compiles/works.
3. Do concern C. Verify it compiles/works.

Do NOT attempt all three in a single large edit. The blast radius of a mistake in a combined edit is much larger.

## Rule 11: Tainted API Fallbacks — NEVER Return Constant CD Duration

`GetCDInfo` has multiple fallback paths when the primary CD source fails. The MOST DANGEROUS pattern is:
```lua
local probeUsable = SafeIsUsableSpell(cleanName)
if probeUsable == false then
    return false, CONSTANT_DURATION, CONSTANT_DURATION  -- WRONG!
end
```
This returns a FIXED number (e.g., 120) as the "remaining" CD every tick. It never counts down because it's recalculated from scratch. This is what made Incarnation show `cd=120.0` permanently.

**Rule:** Any fallback CD path MUST either:
1. Compute remaining time from a recorded cast time: `return false, knownDur - elapsed, knownDur`
2. Or return READY if no cast was ever recorded: `return true, 0, 0`

NEVER return a constant duration as remaining time. If there's no `_castLog` entry, the spell has NOT been used and should be considered READY.

**Also:** `IsOnEventCD` must NEVER call `C_Spell.GetSpellCharges` during combat and overwrite `bookEntry.currentCharges` with tainted API values. This destroys internal charge tracking. API charge reads are OOC-only.

**Key files:**
- `gen-helpers.ts` `GetCDInfo()`: Lines ~3062-3072 — SafeIsUsableSpell fallback (now requires castLog)
- `gen-helpers.ts` `IsOnEventCD()`: Lines ~3785-3802 — OOC-gated charge API call

## Rule 12: Spell Override System (Conditional Bar Transformations)

The addon tracks spell overrides via `_overrideBaseIds` — a map from cleanKey to the base spell ID before override resolution. This handles spells that temporarily transform on the action bar (e.g., Bestial Wrath → Wailing Arrow when a proc/talent is active).

**How it works:**
1. Out-of-combat bar scan detects overrides via `GetOverrideSpell(baseId)` and stores both the resolved override ID and the original base ID.
2. During combat, every frame re-checks `GetOverrideSpell(baseId)` to verify the override is still active.
3. If the override reverted, the check updates the spell ID to whatever is currently on the bar, or skips if the current cleanKey doesn't match.

**Known conditional override patterns across classes:**
- **Hunter BM/MM**: Bestial Wrath → Wailing Arrow (Dark Ranger hero talent, "Wailing Dead" makes BW recastable as WA)
- **Warrior Fury**: Raging Blow → Crushing Blow (during Enrage or talent-modified state)
- **Shaman Enhancement**: Stormstrike → Windstrike (during Ascendance)
- **Druid Balance**: New Moon → Half Moon → Full Moon (sequential override chain)
- **Paladin Ret**: Avenging Wrath → Crusade or Sentinel (talent replacement — usually permanent, but some talent combos interact)
- **DH Havoc**: Various abilities transform during Metamorphosis
- **All classes**: Any talent that makes ability X "recastable" as ability Y

**The fix is universal** — it doesn't hardcode any specific spells. Any spell pair discovered by `DiscoverSpellOverrides()` and mapped in `_spellAliases` automatically gets the combat-time verification through `_overrideBaseIds`.

**Key files:**
- `gen-engine.ts` lines ~1290-1380: InitSlotMap stores `_overrideBaseIds`
- `gen-engine.ts` lines ~1597-1623: Per-frame combat scan verifies override state
- `gen-helpers.ts` lines ~1027-1137: `DiscoverSpellOverrides()` builds `_spellAliases`

## Rule 12: WoW 12.0 Midnight Spell Changes — Do NOT Assume Pre-12.0 Behavior

Several spells changed fundamentally in WoW 12.0 Midnight. **NEVER** assume a spell is "passive" or "uncastable" based on pre-12.0 knowledge.

**Known 12.0 changes (CONFIRMED by user testing):**
- **Lunar Eclipse (Balance Druid, ID 1233272)**: Changed from a passive proc to a **castable spell + proc** in 12.0. It IS in the APL as a castable cooldown with `charges>=1`. Do NOT remove it. If it shows "A more powerful spell is already active," that means the buff is already active (the user already has it), NOT that the spell is uncastable. OLD ID 1239669 is NOT the correct castable button -- AC confirmed the live ID is 1233272.
- **Solar Eclipse**: Same pattern — castable in 12.0.

**RULE**: If you see an error like "A more powerful spell is already active" for a spell, that means the spell's *buff* is currently active and cannot be refreshed. The correct fix is to add a condition check (e.g., `!buff.lunar_eclipse`), NOT to remove the spell from the APL.

**FIX APPLIED**: The engine now has a self-buff check in ALL three candidate paths (bar, APL fallback, AC inject). When a spell is a **charge spell** (`CLF.Charges.IsChargeSpell`) OR a **known cooldown** (`spellIsCooldown`/`_cdMap`), AND `CLF.IsSelfBuffBlocking(cleanName)` returns true, the spell is treated as "on cooldown" with `cdRemaining` set to `CLF.SelfBuffBlockRemains()`. This also demotes AC recommendations for buff-active spells. The check is scoped to charge/CD spells only — filler spells and refreshable buffs (like Starfall) are NOT affected.

**Eclipse-aware buff check**: `CLF.IsSelfBuffBlocking(name)` uses a multi-layer detection chain because WoW 12.0 taint makes CLEU aura names unreliable. The check chain:
1. `BuffUpAlias(name)` — works when aura names aren't tainted
2. **Eclipse Grant Map** (`_EclipseActiveFromCharges`) — the PRIMARY taint-proof detection. Uses `CLF._eclipseGrantMap` which maps every eclipse-granting spell to which eclipse types it activates and for how long:
   - `"lunar eclipse"` → grants `lunar` for 15s
   - `"solar eclipse"` → grants `solar` for 15s
   - `"incarnation chosen of elune"` / `"incarnation: chosen of elune"` → grants BOTH `lunar` AND `solar` for 20s
   - `"celestial alignment"` → grants BOTH for 20s
   Checks `Charges.Resolve(spell).lastConsumeAt` for each granter — if consumed within its duration, that eclipse type is active. 100% taint-proof.
3. Eclipse cache (`InLunarEclipse()` / `InSolarEclipse()`) — fallback using `_eclipseBuffIds` + API scan

**Eclipse buff scan fix**: `_ScanPlayerBuffsForEclipse` now detects eclipse buffs by **name alone** even when spellId is tainted/secret. Previously required BOTH `nmOk AND sidOk` — now only requires `nmOk` for detection, uses `sidOk` only for ID learning.

**Charge system hardening**: `Charges.Consume()` records `lastConsumeAt` timestamp and falls back to `_knownCDDur` when `rechargeDur` is 0 (tainted API). `GetCDInfo` uses `lastConsumeAt + rechargeDur` as fallback CD estimate when `nextChargeAt` was never set.

Both functions are defined in gen-helpers.ts. **Always use `IsSelfBuffBlocking`/`SelfBuffBlockRemains`** for self-buff blocking checks — never call `BuffUpAlias` directly for this purpose.

## Rule 18: Deferred OOC Scan Architecture (MANDATORY)

All functions that read game API data that's only available/reliable out of combat MUST follow this pattern:
```lua
function CLF.MyOOCScan()
  if CLF._inCombat then
    CLF.DeferOOCScan("MyOOCScan", CLF.MyOOCScan)
    return
  end
  -- actual scan logic here
end
```

**How it works:**
- `CLF.DeferOOCScan(name, fn)` — queues a function by unique name (deduplicates automatically)
- `CLF.DrainOOCScans()` — called on `PLAYER_REGEN_ENABLED` (0.8s delay), executes all queued scans
- If the addon loads into combat, all OOC scans self-queue and run as soon as combat ends

**Functions using this pattern:**
| Function | Purpose |
|---|---|
| `SnapshotSpellBook` | Reads spell data, charges, costs from API |
| `DiscoverSpellOverrides` | Reads talent-based spell overrides (e.g., CA → Incarnation) |
| `ResolveConditionAuraIds` | Maps APL condition names to aura spell IDs |
| `RefreshSpellBookOOC` | Full spell book + stats refresh |
| `CalibrateResource` | Reads current resource values for baseline |
| `RefreshEclipseGrantMap` | Reads eclipse buff durations from tooltips |

**RULE**: Any NEW function that reads game API data OOC MUST use `DeferOOCScan`. Never silently return on `_inCombat` without queuing — that loses the scan entirely.

## Rule 13: Taint Strategy — The Three Pillars (MANDATORY READ)

The WoW 12.0 taint/secret system makes most combat APIs unreliable. Instead of building homegrown workarounds that replicate game logic (resource tracking, CD tracking), we use APIs that give DIRECT ANSWERS. This is the architecture. Every combat decision flows through these three pillars.

### Pillar 1: "Can I cast this?" → `C_Spell.IsSpellUsable(id)`

This is the SINGLE SOURCE OF TRUTH for spell castability. It checks resources, cooldowns, requirements, form, talent state — everything. The game already does the math.

- Returns clean booleans (non-secret) for the player's own spells
- When tainted: treat as `true` (optimistic — better to show a spell than hide it)
- When nil: fall back to `_usableCache` (last known clean value)
- **REPLACES**: `CheckResourceAffordable`, `UnitPower` tracking, homegrown resource math
- **WHERE USED**: `SafeIsUsableSpell()` (calls the live API), slot 1 fill, bar candidate building, fallback fills
- **GCD EXCEPTION**: During GCD, IsSpellUsable returns false for everything. During GCD, assume off-CD spells are castable.

**RULE**: Never add a new resource/affordability check. If you need to know "can the player cast X?", call `C_Spell.IsSpellUsable`. Do NOT add another layer.

### Pillar 2: "What should I cast?" → `C_AssistedCombat.GetNextCastSpell(false)`

AC is Blizzard's SimC-powered rotation engine. It handles resources, conditions, priority, and fight context. When AC recommends a spell, trust it.

- AC-recommended spells get `ac:promoted` signal and score -11500 (highest non-CD priority, beats all non-AC CDs and trinkets)
- AC-recommended spells bypass the IsSpellUsable gate (AC already verified castability)
- AC-recommended spells that are genuinely on CD (>3s remaining) get demoted (isAcRecommendedBar = false)
- Bar glow/overlay (`C_SpellActivationOverlay.IsSpellOverlayed`) confirms procs
- **RULE**: Never override an AC recommendation with a lower-priority signal. AC > APL > bar scan.

### Pillar 3: "Is this on cooldown?" → Event-Based CD Tracking

The WoW CD APIs (`GetSpellCooldown`) return tainted values in combat. We track CDs ourselves from cast events.

**CD tracking priority (highest to lowest):**
1. `_spellBook[spell].cdReadyAt` — set from SPELL_COOLDOWN_READY events (most reliable)
2. `_castLog[spell] + _knownCDDur[spell]` — cast time + learned duration (reliable)
3. `_cdMap[spell] + _castLog[spell]` — APL says it's a CD + we saw it cast → use 30s default duration
4. `_barCD[spell]` — bar-based CD cache (reliable out of combat, stale in combat)
5. `C_Spell.GetSpellCooldown` — live API (tainted in combat, clean fallback)

**RULE**: `_knownCDDur` is populated from the WoW API (when non-tainted) and must be preserved across the session. If the API never returns a clean duration, the `_cdMap` fallback (30s default) catches it. Never add a new CD check that bypasses this chain.

### Anti-Pattern: CheckResourceAffordable

`CheckResourceAffordable` was a homegrown function that called `UnitPower` to check resource levels. In WoW 12.0, `UnitPower` for primary resources (energy, mana, rage) returns tainted/secret values in combat. The resource tracker (`rt.current`) starts at 0, never gets calibrated, and reports every spell as "starved."

**This function MUST NOT be used as a gate for slot 1 fill or candidate scoring in combat.** It exists only as a weak fallback for the out-of-combat usability cache path. In combat, `C_Spell.IsSpellUsable` replaces it entirely.

### Signal Priority (Slot 1 Fill — do NOT reorder)

When filling slot 1, candidates are evaluated in this order:
1. **AC-trusted** (`isAcTrusted`): Bypass all checks. AC said cast it.
2. **IsSpellUsable**: Live API check. If clean false → reject. If tainted → accept.
3. **GCD rescue**: During GCD, IsSpellUsable returns false for all. Off-CD spells assumed castable.
4. **Live CD check**: SpellStatus + IsOnEventCD verify the spell isn't on CD.
5. **Healing/defensive filter**: Don't put heals in DPS rotation.
6. **Final gate**: Only outside GCD — clean false from IsSpellUsable rejects.

**RULE**: Do NOT insert a new check between steps. Do NOT add another affordability gate. If a spell passes steps 1-6, it goes in slot 1.

### The Six Failure Modes (prevent these)

Every code change should be evaluated against these failure modes:
1. **Starved lock**: Cost-bearing spells marked "starved" and rejected from slot 1 → only free spells show
2. **Ghost CD**: Spell appears ready (cd=0) when genuinely on cooldown → user told to re-cast
3. **Stability deadlock**: Stability threshold prevents better spells from taking slot 1 → stuck on wrong spell
4. **AC override**: A lower-priority signal overrides AC's recommendation → wrong spell in slot 1
5. **Priority inversion**: A spell with worse score takes slot 1 because better-scoring spells fail usability
6. **Rotation collapse**: Same spell holds slot 1 indefinitely because all alternatives fail checks

## Rule 14: Priority Layer Audit — Before Adding Any New Check

Before adding ANY new usability check, priority gate, or scoring modifier:

1. List every existing check the spell passes through (see Signal Priority above)
2. Identify which existing check already covers your concern
3. If no existing check covers it, add it at the CORRECT position in the chain
4. Verify your new check doesn't create a path where ALL spells get rejected (rotation collapse)
5. Test with at least 3 specs (Feral/Balance/Hunter) to confirm no regressions

**RULE**: The most common bug in this codebase is adding a new check that makes sense in isolation but conflicts with an existing layer. Always trace the FULL path a spell takes from candidate to queue.

## Rule 16: The Alias-Awareness Rule (Cross-System Consistency)

**ANY time you write code that looks up a spell by name in `_spellBook`, `_barCD`, `_castLog`, `_knownCDDur`, `_chargeState`, or any per-spell data structure, you MUST ask: "Could this spell be stored under a DIFFERENT name due to aliases?"**

The addon has a `_spellAliases` system where one spell name maps to multiple alternatives (e.g., `celestial alignment` ↔ `incarnation: chosen of elune`). Data can be stored under ANY of the aliased names depending on which path wrote it:
- `SnapshotSpellBook` stores under the DISPLAY name (what appears on the action bar)
- `RecordCast` stores under the CLEAN name (what the combat log reports)
- APL evaluation uses the APL name (what SimC calls it)

These are often THREE DIFFERENT STRINGS for the same spell.

**Checklist before writing any per-spell lookup:**
1. Does the code call `ResolveAlias()`? If not, it may miss data stored under an alias.
2. Even after `ResolveAlias()`, does the RESOLVED entry have the data you need? If not, search aliases.
3. If you're WRITING data (e.g., setting `cdReadyAt`, decrementing `currentCharges`), will readers under other alias names see that write?

**The pattern that broke Incarnation:** `GetCDInfo` resolved `celestial alignment` via alias, got a book entry, checked `maxCharges` — it was nil (charge data was under `incarnation: chosen of elune`), so it fell through to `_barCD` and reported 120s CD permanently. Charges were available the whole time, just stored under a different key.

**Prevention:** When adding charge, CD, buff, or resource logic that reads `bookEntry.someField`, always add the alias fallback pattern:
```lua
local chargeEntry = bookEntry
if chargeEntry and (not chargeEntry.maxCharges or chargeEntry.maxCharges <= 1) and CLF._spellAliases then
  local aliases = CLF._spellAliases[cleanName]
  if aliases then
    for _, alt in ipairs(aliases) do
      local altBE = CLF._spellBook[alt]
      if altBE and altBE.maxCharges and altBE.maxCharges > 1 then
        chargeEntry = altBE; break
      end
    end
  end
end
```

## Rule 17: Module Architecture — Single-Responsibility State Ownership (FROZEN)

Every shared mutable state concern has ONE authoritative module. Direct reads/writes to the underlying tables are PROHIBITED outside the owning module. Changes to any module require explicit justification and re-verification of all callers.

### Charge Module (`CLF.Charges.*`) — Owner: gen-helpers.ts §H6
**Tables owned:** `_chargeState`, `_chargeSpellIds`
| Function | Inputs | Outputs | Reads | Writes | Taint Safe |
|---|---|---|---|---|---|
| `Init(name, max, rechargeDur)` | spell name, max charges, recharge duration | void | — | `_chargeState`, `_chargeSpellIds` | Yes (OOC only) |
| `Resolve(name)` | spell name | state entry or nil | `_chargeState`, `_spellAliases` | — | Yes |
| `Get(name)` | spell name | cur, max, rechargeRemaining | `_chargeState` via Resolve | auto-advances timer | Yes |
| `Consume(name)` | spell name | void | `_chargeState` via Resolve | decrements cur, sets nextChargeAt | Yes |
| `IsChargeSpell(name)` | spell name | boolean | `_chargeState` via Resolve | — | Yes |
| `SetFromAPI(name, cur, max, start, dur)` | API values | void | `_chargeState` via Resolve | updates cur/max/nextChargeAt | Yes (OOC gate) |
| `Tick(name)` | spell name | void | `_chargeState` via Resolve | advances recharge timer | Yes |
| `Remove(name)` | spell name | void | — | `_chargeState`, `_chargeSpellIds` | Yes |

**Caller rules:**
- `SnapshotSpellBook` → calls `Init`
- `RecordCast` / `RecordCastInBook` → calls `Consume`
- `GetCDInfo` → calls `Get` (READ ONLY — never Consume)
- Bar scanner → calls `SetFromAPI` + `Tick`
- Nobody else may read `_chargeState` or `_chargeSpellIds` directly

### GCD State — Owner: gen-helpers.ts
**Tables owned:** `_gcdCache`
| Function | Role | Reads | Writes |
|---|---|---|---|
| `GetGCD()` | Live API read (61304) | WoW API | — |
| `GetGCDRaw()` | Cached read | `_gcdCache` | — |
| `MarkGCDStart()` | Sets cache on cast | `_gcdCache` | `_gcdCache` |
| `GCDRemains()` | Remaining GCD time | calls `GetGCD` | — |
| `GCDMax()` | Hasted GCD duration | `_statsSnapshot` | — |

**Caller rules:**
- HUD reads via `GetGCDRaw()` — NEVER writes `_gcdCache`
- `MarkGCDStart()` is the ONLY writer (called from RecordCast)

### Target GUID — Owner: gen-core.ts (writer), gen-helpers.ts (reader)
**Tables owned:** `_targetGUID`, `_cleuTargetGUID`
| Function | Role | Where |
|---|---|---|
| `GetCurrentTargetGUID()` | Single reader | gen-helpers.ts |
| PLAYER_TARGET_CHANGED handler | Writer for `_targetGUID` | gen-core.ts |
| `OnAuraCLEU` | Writer for `_cleuTargetGUID` | gen-helpers.ts |

**Caller rules:**
- ALL target GUID reads go through `GetCurrentTargetGUID()`
- Direct `_targetGUID` reads are allowed ONLY in gen-core.ts event handlers

### DoT State — Owner: gen-helpers.ts
**Tables owned:** `_dotCastLog`
| Function | Role |
|---|---|
| `RecordDotCast(spell)` | Writer — called from RecordCast when spell is in `_dotSpells` |
| `IsDotRefreshable(spell)` | Reader — returns whether DoT needs refresh |

**Caller rules:**
- gen-engine.ts NEVER writes to `_dotCastLog` directly
- `IsDotRefreshable` uses `GetCurrentTargetGUID()` for GUID awareness

### Cast State — Owner: gen-core.ts (writer), gen-helpers.ts/gen-hud.ts (readers)
**Tables owned:** `_castState`
| Writer | Event |
|---|---|
| UNIT_SPELLCAST_START | Sets player casting state |
| UNIT_SPELLCAST_STOP/FAILED | Clears player casting state |

**Caller rules:**
- HUD reads `_castState.player` for cast bar display — NEVER writes
- gen-engine.ts reads `_castState.target` for interrupt logic — NEVER writes

### Resource Affordability — Owner: gen-helpers.ts
**Tables consumed:** `_spellCosts`, `_resTracker`, `_spellSecondaryCosts`
| Function | Role | Inputs |
|---|---|---|
| `CheckResourceAffordable(spell, isAcRec)` | Returns false if spell costs more than current power; short-circuits to true when `isAcRec=true` | spell name/id, AC flag |
| `IsAffordableForSlot(spell, clean, isAcRec, inCombat)` | Composite: IsSpellUsable + CheckResourceAffordable + resource gate. Single call from engine. | display name, clean name, AC flag, combat flag |

**Caller rules:**
- gen-engine.ts calls ONLY `IsAffordableForSlot` — NEVER inlines resource logic
- AC-recommended spells bypass ALL resource checks (UnitPower is tainted in combat)
- Non-AC spells with `_spellCosts > 0` are gated in combat

### Eclipse Bar Detection — Owner: gen-helpers.ts
**Tables owned:** `_eclipseActiveUntil`, `_eclipseGrantMap`
| Function | Role |
|---|---|
| `DetectEclipseFromBar(cleanName, isOnCD)` | Sets `_eclipseActiveUntil.lunar`/`.solar` when an eclipse-granting spell is seen on CD |
| `IsSelfBuffBlocking(cleanName)` | Reader — checks `_eclipseActiveUntil` to block re-recommendation |

**Caller rules:**
- gen-engine.ts calls `DetectEclipseFromBar` — NEVER writes `_eclipseActiveUntil` directly
- Eclipse timers are set from bar scanner CD state (taint-free)

### Cooldown Data — Owner: gen-helpers.ts (`GetCDInfo`)
**Tables consumed (read priority order):**
1. `CLF.Charges.Get()` — charge spells (highest priority)
2. `_spellBook[].cdReadyAt` — from SPELL_COOLDOWN_READY events
3. `_castLog[] + _knownCDDur[]` — cast time + learned duration
4. `_barCD[]` — bar scanner cache
5. `C_Spell.GetSpellCooldown` — live API (tainted in combat)
6. `SafeIsUsableSpell` + `_castLog` — last resort fallback

**Caller rules:**
- Bar scanner writes `_barCD` (it IS the source for bar-discovered CDs)
- `RecordCast` writes `_castLog` and `_knownCDDur`
- SPELL_COOLDOWN_READY handler writes `_spellBook[].cdReadyAt`
- `GetCDInfo` is the ONLY reader that combines these sources

### Off-GCD Detection — Owner: gen-helpers.ts
**Tables owned:** `_offGCDSpells`
| Function | Role |
|---|---|
| `RecordOffGCD(castKey)` | Called on UNIT_SPELLCAST_SUCCEEDED. Detects if cast triggered GCD or was off-GCD. Writes `_offGCDSpells[key]`. Also calls `MarkGCDStart()`. |

**Caller rules:**
- gen-core.ts calls `RecordOffGCD` — NEVER writes `_offGCDSpells` directly
- gen-hud.ts reads `_offGCDSpells` — NEVER writes

### Stuck Penalty — Owner: gen-engine.ts (writer), gen-helpers.ts (clearer)
**Tables owned:** `_stuckPenalties`, `_stuckTopSpell`, `_stuckTopSince`
| Function | Role |
|---|---|
| `ClearStuckPenalty(castKey)` | Clears penalty for a spell after it's been cast. Called from gen-core.ts on successful cast. |

**Caller rules:**
- gen-engine.ts writes penalties (stuck detection logic — correct owner)
- gen-core.ts clears via `ClearStuckPenalty` — NEVER writes `_stuckPenalties` directly

### HUD State — Owner: gen-hud.ts (local UI state only)
**Tables owned (UI-only, never read by engine):**
- `_dragOverlay`, `_positionLocked`, `_manualShow`
- `_gcdWasActive`, `_readyFlashStart`
- `_assistedDismissed`, `_assistedWarningShown`

**Caller rules:**
- HUD NEVER writes to game state tables (`_gcdCache`, `_castState`, `_chargeState`, etc.)
- HUD reads game state through module functions only

## Quick Reference: Verification Commands

```bash
# Lua syntax check (after gen-engine.ts edits)
npx tsx -e "import { generateEngine } from './server/generators/gen-engine.ts'; import fs from 'fs'; fs.writeFileSync('/tmp/test.lua', generateEngine());" && luac -p /tmp/test.lua

# Test suite
npx vitest run

# TypeScript compile check
npx tsc --noEmit
```
