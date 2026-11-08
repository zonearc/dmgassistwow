---
name: dmgassist-coding-principles
description: MANDATORY coding principles for DMGAssist Lua generator. Read BEFORE writing ANY code in gen-engine.ts, gen-helpers.ts, gen-core.ts, or gen-hud.ts. Violations of these principles have caused every major regression in this project.
---

# DMGAssist Coding Principles

These principles are MANDATORY. They exist because every violation has caused real, painful regressions. Read this skill BEFORE writing any generator code.

## Principle 1: Functions Over Inline Logic — THE CARDINAL RULE

**Every piece of logic that could be reused, tested, or reasoned about independently MUST be a named function in gen-helpers.ts.**

gen-engine.ts is the tick loop — it calls functions, it does NOT contain logic. If you find yourself writing more than 2-3 lines of conditional logic inside gen-engine.ts, STOP. Extract it into a function in gen-helpers.ts first, then call that function from the engine.

### Why This Matters

- **gen-engine.ts is fragile**: It generates deeply nested Lua with if/else/end blocks. Every inline addition increases nesting, surface area for `end` mismatches, and makes future edits exponentially harder.
- **Inline logic is hard to maintain**: The engine has one candidate path (bar scanner) plus AC injection. Inline logic is harder to test, debug, and modify than a named function.
- **Functions are the firewall**: A function in gen-helpers.ts survives engine restructures. It has one definition, one set of inputs/outputs, and one place to fix bugs.

### The Test

Before writing code in gen-engine.ts, ask: "Could this be a function call instead?" If yes — and it almost always is — write the function first.

### Examples

**WRONG — inline resource check in engine tick loop:**
```lua
local affordable = CLF.IsSpellUsable and CLF.IsSpellUsable(spell) or false
if not affordable and _gcdActive then affordable = true end
if affordable then
  local resOk = CLF.CheckResourceAffordable(spell)
  if resOk == false then affordable = false end
end
if not isAcRec and affordable and inCombat then
  local cost = CLF._spellCosts and CLF._spellCosts[clean]
  if cost and cost > 0 then affordable = false end
end
```

**RIGHT — single function call:**
```lua
local affordable = CLF.IsAffordableForSlot(spell, clean, isAcRec, inCombat)
```

**WRONG — inline eclipse detection in engine:**
```lua
if inCombat and onCD and CLF._eclipseGrantMap and CLF._eclipseGrantMap[clean] then
  local grants = CLF._eclipseGrantMap[clean]
  if not CLF._eclipseActiveUntil then CLF._eclipseActiveUntil = {} end
  -- ... 15 more lines
end
```

**RIGHT — single function call:**
```lua
if inCombat then CLF.DetectEclipseFromBar(clean, onCD) end
```

## Principle 2: gen-engine.ts Is a Caller, Not an Implementor

gen-engine.ts should read like a sequence of function calls with minimal glue. Its job is:
1. Iterate over bar slots / APL entries
2. Gather raw inputs (bar CD state, spell name, signal)
3. Call helper functions to compute derived state
4. Score and rank candidates
5. Assign to HUD slots

It should NOT:
- Contain domain logic (resource checks, eclipse detection, buff blocking, charge tracking)
- Directly read/write shared state tables (use module functions from gen-helpers.ts)
- Have conditional blocks longer than ~5 lines (extract to a function)

## Principle 3: One Owner Per Table

Every shared state table (`_chargeState`, `_eclipseActiveUntil`, `_resTracker`, `_spellCosts`, etc.) has exactly ONE module that writes to it. Other files call functions to read or trigger updates.

See the Module API Reference in `dmgassist-edit-safety/SKILL.md` Rule 17 for the complete ownership map.

**Before writing to ANY `CLF._` table from gen-engine.ts, STOP.** Find or create the owning function in gen-helpers.ts.

## Principle 4: Bar-Only Architecture (APL Fallback REMOVED)

The engine uses a SINGLE candidate evaluation path: the **bar scanner path**, which iterates action bar results. If a spell is not on the player's action bars, it is NOT recommended.

The APL fallback path was removed because:
1. Spells not on the bar can't be easily cast by the player anyway
2. The fallback path introduced spells we couldn't properly validate for affordability (no `IsUsableAction(slotID)` without a slot)
3. It created a parallel code path that required duplicating every piece of evaluation logic

**AC injection** still exists but is also bar-gated: if AC recommends a spell and it's already a bar candidate, it gets promoted. If AC recommends a spell NOT on the bars, it is skipped.

**DO NOT re-add an APL fallback path.** If a spell matters, the player should put it on their bars.

## Principle 5: AC Recommendation Is the Highest Authority

When Assisted Combat (AC) recommends a spell (`isAcRecommendedBar` or `isAcRecFallback` is true):
- Skip resource affordability checks (UnitPower is tainted in combat, reads as 0)
- Skip cost-gating (the spell may have a cost but AC knows the player can afford it)
- Still respect hard CD blocks (spell genuinely on cooldown > 3s)

This is implemented in `CLF.IsAffordableForSlot()`. NEVER add inline resource checks that bypass this function.

### Scoring Hierarchy (ScoreCandidate — DO NOT INVERT)

| Tier | Score | What |
|------|-------|------|
| -12000 + basePrio | AC-recommended CD spells (highest) |
| -11500 + basePrio | AC-recommended non-CD spells (SIGNAL_ANTS) |
| -11000 + basePrio | Non-AC minor CDs (knownDur < 15s) |
| -11000 + trinketPrio | Ready trinkets |
| -10800 + basePrio | Non-AC major CDs (knownDur >= 15s) |
| -10000 + basePrio | AC-assisted non-CD (SIGNAL_ASSISTED) |
| -5000 + basePrio | Proc spells (SIGNAL_PROC) |
| -7000 + basePrio | SimC-data fillers (mode match) |

**RULE**: AC non-CD score (-11500) MUST be lower (better) than all non-AC CD/trinket tiers. This prevents non-AC cooldowns and trinkets from outscoring AC-recommended spells, which caused the rapid slot 1 flashing bug.

## Principle 6: Taint-Proof by Default

In WoW 12.0, ALL of the following are tainted in combat:
- `CombatLogGetCurrentEventInfo` (spell names, spell IDs)
- `UnitPower` (resource values)
- `C_Spell.GetSpellCooldown` (CD data)
- `C_Spell.GetSpellCharges` (charge data — partially)
- Buff/aura names from CLEU events

Any new feature that reads these APIs MUST have a taint-free fallback path. The primary taint-free sources are:
- Action bar visual state (button textures, CD sweeps via `GetActionCooldown`)
- `_eclipseActiveUntil` (set by bar scanner via `DetectEclipseFromBar`)
- `Charges.Get()` with time-based regeneration
- AC recommendations (`_acNextCastId`)

## Principle 7: Small Functions With Clear Contracts

Every helper function should:
1. Have a clear name that describes what it does
2. Take explicit inputs (not read globals implicitly when possible)
3. Return a clear output
4. Handle nil/missing inputs gracefully (nil guards at the top)
5. Log when `CLF.debugEnabled` is true

Bad: `DoStuff()` that reads 5 globals and sets 3 tables
Good: `IsAffordableForSlot(spellName, cleanName, isAcRecommended, inCombat) → boolean`

## Principle 8: New Features = New Functions FIRST

When implementing a new feature:
1. Write the function(s) in gen-helpers.ts FIRST
2. Verify they compile with `luac -p`
3. THEN add the one-line call(s) in gen-engine.ts
4. Verify again
5. Run the full test suite

NEVER start by editing gen-engine.ts inline and "plan to extract later." The extraction never happens, and the inline code accumulates.

## Principle 9: Audit After Multi-Day Sprints

After any sprint of 3+ changes, audit gen-engine.ts for:
- Inline logic blocks > 5 lines that should be functions
- Duplicated logic between bar scanner and APL paths
- Direct writes to `CLF._` tables that bypass module functions
- Resource/affordability checks that don't go through `IsAffordableForSlot`
- Eclipse/buff checks that don't go through helper functions

If found, extract to functions BEFORE moving on to new features.

## Quick Reference: Current Function API

| Engine Need | Function to Call | Defined In |
|---|---|---|
| Is spell affordable? | `CLF.IsAffordableForSlot(spell, clean, isAcRec, inCombat)` | gen-helpers.ts |
| Resource check (low-level) | `CLF.CheckResourceAffordable(spell, isAcRec)` | gen-helpers.ts |
| Eclipse from bar CD | `CLF.DetectEclipseFromBar(clean, isOnCD)` | gen-helpers.ts |
| Is self-buff blocking? | `CLF.IsSelfBuffBlocking(clean)` | gen-helpers.ts |
| Self-buff remaining | `CLF.SelfBuffBlockRemains(clean)` | gen-helpers.ts |
| Charge spell check | `CLF.Charges.IsChargeSpell(clean)` | gen-helpers.ts |
| Get charge state | `CLF.Charges.Get(spell)` | gen-helpers.ts |
| Consume charge | `CLF.Charges.Consume(clean)` | gen-helpers.ts |
| CD info waterfall | `CLF.GetCDInfo(clean)` | gen-helpers.ts |
| Record a cast | `CLF.RecordCast(spell, spellId)` | gen-helpers.ts |
| Record off-GCD cast | `CLF.RecordOffGCD(castKey)` | gen-helpers.ts |
| Clear stuck penalty | `CLF.ClearStuckPenalty(castKey)` | gen-helpers.ts |
| GCD remaining | `CLF.GCDRemains()` | gen-helpers.ts |
| Score a candidate | `ScoreCandidate(spell, signal, mode, isCDReady)` | gen-engine.ts (local) |

**If what you need isn't in this table, CREATE a new function before using it in the engine.**

## Principle 10: Universal Candidate Validation Gate — THE CHECKLIST

**Every spell candidate MUST pass through a standardized validation checklist at TWO points: scoring time (PRE) and slot assignment time (POST). No check may be skipped, no path may bypass the gate.**

### Why This Exists

Every major bug in DMGAssist traces to a validation check that existed in one code path but was missing from another: Starfall showing when unaffordable, Starsurge leaking into AoE, eclipse spells ignoring active buffs, spenders appearing when AC recommends generators. The fix is architectural: ONE function, EVERY path, EVERY time.

### The 6-Gate PRE-Check (Scoring Time) — `CLF.ValidateCandidate`

Called from the bar scanner path (the only candidate path). Returns all derived state for scoring.

| Gate | What It Checks | Returns |
|------|---------------|---------|
| Gate 1: CD Normalization | Non-CD spells with APL data ignore bar/event CD reports | `onCooldown`, `cdRemaining`, `cdTotal` |
| Gate 2: Eclipse Detection | Taint-proof eclipse tracking side effect | (side effect only) |
| Gate 3: Charge + Buff Blocking | Self-buff active on charge/CD spell → treat as on CD | `isChargeSpell`, `buffBlocked` |
| Gate 4: AC Validation | Demote AC recommendation if genuinely on long CD (>3s) | `isAcRecommended` |
| Gate 5: Affordability | Resource check with AC bypass, taint handling, cost gate | `affordable` |
| Gate 6: Derived State | Starved / GCD-wait / effective-CD computation | `resourceStarved`, `gcdOnlyWait`, `effectiveCD` |

**Usage (both paths must look like this):**
```lua
local vc = CLF.ValidateCandidate(spellName, cleanName, {
  cdRemaining = cdRemaining or 0,
  cdTotal = cdTotalVal or 0,
  eventCDActive = onEventCD,
  eventCDRemaining = eventCDRem,
  isCooldownSpell = spellIsCooldown,
  isAcRecommended = isAcRec,
  inCombat = inCombat,
  barUsable = actuallyUsable,
  hasAPLData = hasAPLData,
  gcdActive = _gcdActive,
})
```

### The 7-Check POST-Check (Slot Assignment) — `CLF.IsSlotReady`

Called at slot 1 fill AND stability lock validation. Rechecks everything with LIVE data.

| Check | What It Verifies |
|-------|-----------------|
| 1. Starved Signal | Starved spells cannot fill slot 1 (unless AC-trusted) |
| 2. Resource Affordability | CheckResourceAffordable recheck (unless AC-trusted) |
| 3. Trinket CD | Live trinket cooldown verification |
| 4. Live Castability | IsSpellUsable with GCD rescue (unless AC-trusted) |
| 5. Live CD Recheck | SpellStatus confirms not on CD |
| 6. Event CD Recheck | IsOnEventCD confirms not on event CD |
| 7. Self-Buff Blocking | IsSelfBuffBlocking recheck at fill time |

**Usage:**
```lua
local ready, reason = CLF.IsSlotReady(candidate, slotIdx, inCombat, gcdActive)
if not ready then
  -- skip: reason tells you which check failed
end
```

### Rules

1. **NEVER add inline validation logic to gen-engine.ts.** If a new check is needed, add it to `ValidateCandidate` (PRE) or `IsSlotReady` (POST).
2. **NEVER bypass the gate for a specific spell or class.** The gate handles AC trust, charges, buffs — use those mechanisms.
3. **When adding a new gate**, add it to BOTH functions. PRE catches it at scoring, POST catches it at fill.
4. **Test with 3+ specs** after any gate change to confirm no regressions.
5. **The gate functions are in gen-helpers.ts** — they are the single source of truth for "can this spell be recommended?"

### Updated Function API

| Engine Need | Function to Call | Defined In |
|---|---|---|
| **Full candidate validation (PRE)** | `CLF.ValidateCandidate(spell, clean, opts)` | gen-helpers.ts |
| **Slot readiness check (POST)** | `CLF.IsSlotReady(candidate, slotIdx, inCombat, gcdActive)` | gen-helpers.ts |
| Is spell affordable? | `CLF.IsAffordableForSlot(spell, clean, isAcRec, inCombat, barUsable)` | gen-helpers.ts |
| Resource check (low-level) | `CLF.CheckResourceAffordable(spell)` | gen-helpers.ts |
| Eclipse from bar CD | `CLF.DetectEclipseFromBar(clean, isOnCD)` | gen-helpers.ts |
| Is self-buff blocking? | `CLF.IsSelfBuffBlocking(clean)` | gen-helpers.ts |
| Self-buff remaining | `CLF.SelfBuffBlockRemains(clean)` | gen-helpers.ts |
| Charge spell check | `CLF.Charges.IsChargeSpell(clean)` | gen-helpers.ts |
| Get charge state | `CLF.Charges.Get(spell)` | gen-helpers.ts |
| Consume charge | `CLF.Charges.Consume(clean)` | gen-helpers.ts |
| CD info waterfall | `CLF.GetCDInfo(clean)` | gen-helpers.ts |
| Record a cast | `CLF.RecordCast(spell, spellId)` | gen-helpers.ts |
| Record off-GCD cast | `CLF.RecordOffGCD(castKey)` | gen-helpers.ts |
| Clear stuck penalty | `CLF.ClearStuckPenalty(castKey)` | gen-helpers.ts |
| GCD remaining | `CLF.GCDRemains()` | gen-helpers.ts |
| Score a candidate | `ScoreCandidate(spell, signal, mode, isCDReady)` | gen-engine.ts (local) |
| **Secondary resource** | `CLF.SecondaryPower()` | gen-helpers.ts |
| **Secondary resource max** | `CLF.SecondaryPowerMax()` | gen-helpers.ts |
| **Movement duration** | `CLF.MoveDuration()` | gen-helpers.ts |
| **Standing duration** | `CLF.StandingDuration()` | gen-helpers.ts |
| **Current form/stance** | `CLF.GetForm()` | gen-helpers.ts |
| **Player health %** | `CLF.PlayerHealthPct()` | gen-helpers.ts |
| **Target health %** | `CLF.TargetHealthPct()` | gen-helpers.ts |

## Principle 12: Affordability — The IsUsableAction Truth Hierarchy (CRITICAL)

**This principle documents a design decision that was flip-flopped THREE TIMES. Read before touching affordability.**

### The Problem

In WoW 12.0 combat, both `UnitPower` and `C_Spell.IsSpellUsable` return tainted/secret values. This means:
1. `_resTracker.current` stays at 0 (UnitPower is secret → SafeNum returns 0)
2. `C_Spell.IsSpellUsable` returns a secret value → code optimistically treats as `true`
3. Spells appear castable when the player has NO resources

### Failed Approaches (DO NOT REPEAT)

**Attempt 1 — No gate:** Trusted `C_Spell.IsSpellUsable` blindly. Result: spells shown with 0 resources because tainted=true.

**Attempt 2 — Hard combat gate:** Rejected ALL cost-bearing spells not AC-recommended in combat. Result: spells rejected even when the player HAD resources, because `barUsable=true` (from tainted API) was overridden by `CheckResourceAffordable` (which reads broken `_resTracker`).

**Attempt 3 — Trust barUsable:** Removed the gate, trusted `barUsable`. Result: same as Attempt 1 because `barUsable` came from the same tainted `C_Spell.IsSpellUsable`.

### The Correct Architecture (CURRENT)

The fix uses the **bar scanner as the single source of truth**:

**Bar scanner path (has slotID) — the ONLY candidate path:**
- Calls `IsUsableAction(slotID)` — the WoW ACTION BAR API that controls whether the icon is greyed out
- This is the ground truth the player SEES. If the bar shows grey, the player can't cast it. Period.
- `barUsable` from this path is RELIABLE — it reflects actual bar rendering state
- When `barUsable=true` → trust it, spell is affordable
- When `barUsable=false` and spell has cost → reject (genuinely unaffordable)
- When `barUsable=false` and no cost → check charges, then GCD rescue
- Spells NOT on the action bars are never recommended (no APL fallback path)

### Rules

1. **NEVER add a blanket cost gate** that rejects all cost-bearing non-AC spells. This caused the Starved Lock.
2. **NEVER blindly trust `C_Spell.IsSpellUsable`** for affordability — it returns tainted values. Use `IsUsableAction(slotID)` for bar-path spells.
3. **`IsUsableAction(slotID)`** is the ONLY reliable combat affordability source.
4. **DO NOT re-add an APL fallback candidate path.** If a spell is not on the bar, it is not recommended. See Principle 4.
5. **AC-recommended spells** bypass resource checks entirely (AC already verified castability). Exception: if bar shows grey AND spell has cost → reject even AC recommendations. AC injection also requires bar presence.

### Key Code Locations

- `IsAffordableForSlot()` — gen-helpers.ts: The affordability decision function
- `IsUsableAction(slotID)` call — gen-engine.ts bar scanner: Reads bar ground truth
- `SafeIsUsableSpell()` — gen-helpers.ts: Wraps `C_Spell.IsSpellUsable` with taint handling (TAINTED=optimistic)
- `CheckResourceAffordable()` — gen-helpers.ts: Internal resource tracker check (UNRELIABLE in combat)

## Principle 11: Diagnostic Logging — EVERY Decision Is Traceable

**Every validation gate, slot assignment, and scoring modifier MUST log its inputs and result when `CLF.debugEnabled` is true.**

### Log Categories

| Category | What It Logs | Where |
|----------|-------------|-------|
| `VALIDATE` | ValidateCandidate gate results (G1-G8) | gen-helpers.ts |
| `SLOTCHK` | IsSlotReady check results (pass/reject with reason) | gen-helpers.ts |
| `TICK` | Per-tick decision summary + slot 1 transitions | gen-engine.ts |
| `AURA` | Buff/debuff applied/removed/dose events | gen-helpers.ts |
| `CHARGE` | Charge init/consume/tick/API-set | gen-helpers.ts |
| `RESOURCE` | Affordability decisions | gen-helpers.ts |
| `CAST` | Off-GCD detection | gen-helpers.ts |
| `STUCK` | Stuck penalty clear | gen-helpers.ts |
| `ECLIPSE` | Eclipse buff detection | gen-helpers.ts |
| `SYSTEM` | Spell book, stats, overrides | gen-helpers.ts |

### Rules

1. **All logging is gated behind `CLF.debugEnabled`** — zero performance cost in production.
2. **Log WHY, not just WHAT** — include the gate number, the input values, and the decision.
3. **Rejection logs include the reason** — `REJECT: starved signal`, `REJECT: live cd=3.2`.
4. **Success logs confirm trust level** — `PASS (ac=true)`.
5. **`_auraLog` ring buffer** — last 50 aura events stored in `CLF._auraLog` for diagnostic dump.
6. **Tick summary** — every debug tick logs a 1-line `DECISION:` summary of all slot assignments.
7. **Slot transitions** — `SLOT1-CHANGE:` logged whenever the primary spell changes.

### ValidateCandidate Returns (8-Gate)

The PRE validation now returns two additional scoring modifiers:

| Field | Type | Description |
|-------|------|-------------|
| `movePenalty` | number | +5000 for cast-time spells while moving (0 when standing or AC-recommended) |
| `executePenalty` | number | +20000 above 35% HP for execute spells, -3000 below 20% HP (0 for non-execute spells) |

These are applied additively to the candidate score in BOTH engine paths (bar scanner and APL fallback).

### Snapshot State (`CLF._snap`)

The per-tick snapshot now includes:

| Field | Type | Source |
|-------|------|--------|
| `healthPct` | number | UnitHealth("player") |
| `targetHealthPct` | number | UnitHealth("target"), taint-safe, defaults 100 |
| `power` | number | _resTracker.current |
| `powerMax` | number | _resTracker.max |
| `secondaryPower` | number | UnitPower("player", secondaryPowerType) |
| `secondaryPowerMax` | number | UnitPowerMax("player", secondaryPowerType) |
| `moving` | boolean | GetUnitSpeed("player") > 0, taint-safe |
| `moveDuration` | number | seconds since player started moving |
| `standingDuration` | number | seconds since player stopped moving |
| `form` | number | GetShapeshiftForm(), taint-safe |
| `hasTarget` | boolean | UnitExists("target"), taint-safe |
| `petAlive` | boolean | UnitExists("pet") and not UnitIsDead("pet") |
| `gcdRemaining` | number | GCD time remaining |
| `gcdMax` | number | Hasted GCD duration |
