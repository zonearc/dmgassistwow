---
name: wow-taint-model
description: WoW 12.0 Midnight taint and secret value rules for Lua addon code generation. Use when writing, reviewing, or auditing generated Lua code for WoW addons to prevent taint errors and ADDON_ACTION_BLOCKED crashes.
---

# WoW 12.0 Addon Code Rules & Audit Model

This skill covers ALL WoW client rule systems that can cause addon failures — not just taint. Each section has scannable violation patterns used by the automated audit scanner.

**MANDATORY**: Before writing or modifying ANY Lua code for a WoW addon, read and internalize ALL rules in this file. Every rule exists because of a real crash encountered in production.

**Authority**: Rules derived from official Blizzard posts on WoWUIDev Discord (Alpha 1–Beta 9, September 2025–February 2026) and warcraft.wiki.gg documentation on Patch 12.0.0/API changes and Secret Values.

---

## Rule System 0: Hard-Won Lessons (CRITICAL — read first)

These rules were discovered through real production crashes. They override any assumptions or patterns from older WoW versions.

### 0.1: REMOVED APIs — Never Use Without Guard

These APIs are **completely removed** in WoW 12.0 Midnight. Calling them crashes immediately with "attempt to call global 'X' (a nil value)":

| Removed API | Replacement |
|-------------|-------------|
| `UnitBuff(unit, i)` | `C_UnitAuras.GetBuffDataByIndex(unit, i)` |
| `UnitDebuff(unit, i)` | `C_UnitAuras.GetDebuffDataByIndex(unit, i)` |
| `GetSpellInfo(id)` | `C_Spell.GetSpellInfo(id)` / `C_Spell.GetSpellName(id)` |
| `GetSpellCooldown(id)` | `C_Spell.GetSpellCooldown(id)` |
| `GetSpellTexture(id)` | `C_Spell.GetSpellTexture(id)` |
| `IsSpellKnown(id)` | `C_SpellBook.IsSpellKnown(id)` |
| `IsUsableSpell(name)` | `C_Spell.IsSpellUsable(name)` |
| `AuraUtil.FindAuraByName(name, unit, filter)` | Removed or unreliable — use manual scan |
| `GetShapeshiftFormInfo(index)` | Removed — use hardcoded `FORM_INDEX_MAP` per class + buff-based detection fallback |
| `secretunwrap()` | Removed from global table (was an exploit) |

**RULE**: NEVER use a removed API bare. Always wrap with `if APIName then ... end` or use the modern replacement directly.

### 0.1b: STILL-AVAILABLE APIs — Do NOT Remove These

These APIs are **confirmed still working** in WoW 12.0 via external research and testing. They were previously incorrectly flagged as removed. Do NOT replace them with buff-scan workarounds:

| API | Status | Notes |
|-----|--------|-------|
| `GetShapeshiftForm()` | **Still works** in 12.0 | Returns form index (1=bear, 2=cat, etc.). Guard with `if GetShapeshiftForm then`. Always `Detaint()` the return. |
| `InCombatLockdown()` | **Still works** in 12.0 | Returns combat state. **MUST** wrap in `DetaintBool()` — bare `if InCombatLockdown() then` is blocked on secret values. |

**RULE**: When external research or testing contradicts this skill file, UPDATE THIS SKILL FILE IMMEDIATELY. Do not create code workarounds for APIs that aren't actually removed.

### 0.1c: APIs That Require Secret-Safe Wrapping

These APIs return values that may be secret. Using them bare in `if` checks is BLOCKED.
**CRITICAL**: `DetaintBool()` returns `false` for ALL secret values, which loses data.
When you need the **truthiness** of a secret boolean (not just taint safety), use the
`issecretvalue` check first to infer the value from its existence:

```lua
-- Pattern: Secret-aware boolean check (for data APIs, NOT UI operations)
local rawVal = UnitExists("target")
if rawVal ~= nil then
  if issecretvalue and issecretvalue(rawVal) then
    -- Secret non-nil return = real data exists; treat as true
    hasTarget = true
  else
    hasTarget = rawVal and true or false
  end
end
```

For numeric APIs like `UnitReaction()`, you CANNOT compare secret numbers (`val <= 4` CRASHES).
Instead, treat non-nil secret returns as "has a value" and infer from context:
- `UnitReaction` returns secret non-nil for any unit with a reaction → count as hostile for nameplates
- `UnitCanAttack` returns secret non-nil → treat as "can attack"

| API | Old (lossy) | New (secret-aware) |
|-----|-------------|-------------------|
| `InCombatLockdown()` | `DetaintBool(...)` | Still OK — only used for UI gating |
| `UnitExists(unit)` | `DetaintBool(...)` | `issecretvalue` check → true |
| `UnitCanAttack(a, b)` | `DetaintBool(...)` | `issecretvalue` check → true |
| `UnitIsDead(unit)` | `DetaintBool(...)` | `issecretvalue` check → assume alive |
| `UnitReaction(a, b)` | `Detaint(...)` → nil | `issecretvalue` check → infer hostile |

### 0.2: Aura (Buff/Debuff) Detection — The Correct Pattern

This is the ONLY correct way to scan for auras in WoW 12.0:

```lua
-- Priority 0: C_UnitAuras.GetPlayerAuraBySpellID(spellId) — direct lookup, player buffs only
-- Priority 1: C_UnitAuras.GetBuffDataByIndex / GetDebuffDataByIndex — specific aliases (preferred)
-- Priority 2: C_UnitAuras.GetAuraDataByIndex(unit, i, filter) — generic fallback
-- Priority 3: AuraUtil.ForEachAura (with detaint-outside-callback pattern)
-- NEVER: UnitBuff() / UnitDebuff() / UnitAura() — ALL removed in 12.0
-- NEVER: AuraUtil.FindAuraByName() — case-sensitive, unreliable
-- BEST PRACTICE: Match by spellId FIRST (numbers are easy to detaint), then fall back to name
-- CRITICAL: Do NOT break on nil aura.name — hidden/system auras can have nil names.
--           Only break on pcall failure or 3+ consecutive nil auras (end of list).

local function FindAura(unit, searchName, filter)
  local cleanName = NormalizeName(searchName)  -- underscore → space
  local lowerClean = string.lower(cleanName)

  -- Method 0: Direct spell ID lookup for player buffs (fastest, most reliable)
  -- C_UnitAuras.GetPlayerAuraBySpellID bypasses index iteration entirely.
  if unit == "player" and filter ~= "HARMFUL" and spellIdForSearch
     and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
    local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellIdForSearch)
    if ok and type(aura) == "table" then
      return DetaintStr(aura.name) or cleanName,
             Detaint(aura.applications) or 0,
             Detaint(aura.expirationTime) or 0
    end
  end

  -- Method 1: Index-based aura scan (C_UnitAuras)
  -- Prefer GetBuffDataByIndex/GetDebuffDataByIndex, fall back to GetAuraDataByIndex.
  -- CRITICAL: aura.name may be a SECRET string in WoW 12.0.
  -- Use DetaintStr to get a clean string FIRST. If secret, returns nil → skip name match.
  -- Player buff names are NOT secret, so DetaintStr passes them through normally.
  -- Target aura names ARE secret → DetaintStr returns nil → rely on spellId match instead.
  -- CRITICAL: Do NOT break on nil aura.name — hidden auras have nil names but valid
  -- auras may follow. Only break on pcall failure or 3+ consecutive nil/non-table returns.
  if C_UnitAuras then
    local hasSpecific = (filter == "HARMFUL")
      and C_UnitAuras.GetDebuffDataByIndex
      or  C_UnitAuras.GetBuffDataByIndex
    local useGeneric = C_UnitAuras.GetAuraDataByIndex
    if hasSpecific or useGeneric then
      local nilRun = 0
      for i = 1, 40 do
        local ok, aura
        if hasSpecific then
          ok, aura = pcall(hasSpecific, unit, i)
        else
          ok, aura = pcall(useGeneric, unit, i, filter)
        end
        if not ok then break end
        if type(aura) ~= "table" then
          nilRun = nilRun + 1
          if nilRun > 2 then break end
        else
          nilRun = 0
          if type(aura.name) ~= "nil" then
            -- SpellId match first (works regardless of secret state)
            local auraSpellId = Detaint(aura.spellId)
            if spellIdForSearch and auraSpellId and auraSpellId == spellIdForSearch then
              return DetaintStr(aura.name) or cleanName,
                     Detaint(aura.applications) or 0,
                     Detaint(aura.expirationTime) or 0
            end

            -- Name match: DetaintStr first, then normal string ops on clean string
            local nameStr = DetaintStr(aura.name)
            if nameStr then
              local lowerName = string.lower(nameStr)
              if string.find(lowerName, lowerClean, 1, true) then
                return nameStr,
                       Detaint(aura.applications) or 0,
                       Detaint(aura.expirationTime) or 0
              end
            end
          end
        end
      end
      return nil, 0, 0
    end
  end

  -- Method 2: AuraUtil.ForEachAura (fallback)
  -- CRITICAL: Collect data inside callback, match OUTSIDE callback
  if AuraUtil and AuraUtil.ForEachAura then
    local collected = {}
    local count = 0
    AuraUtil.ForEachAura(unit, filter, nil, function(aura)
      count = count + 1
      local nameStr = DetaintStr(aura.name)
      collected[count] = {
        n = nameStr or "",
        c = Detaint(aura.applications) or 0,
        e = Detaint(aura.expirationTime) or 0,
        id = Detaint(aura.spellId),
      }
    end, true)
    for i = 1, count do
      local entry = collected[i]
      if spellIdForSearch and entry.id and entry.id == spellIdForSearch then
        return entry.n ~= "" and entry.n or cleanName, entry.c, entry.e
      end
      if entry.n ~= "" then
        if string.find(string.lower(entry.n), lowerClean, 1, true) then
          return entry.n, entry.c, entry.e
        end
      end
    end
    return nil, 0, 0
  end

  return nil, 0, 0
end
```

**KEY RULES for aura detection:**
1. **NEVER use `UnitBuff()` / `UnitDebuff()`** — removed in 12.0
2. **NEVER use `AuraUtil.FindAuraByName()`** — case-sensitive exact match, fails for normalized names
3. **ALWAYS use `string.lower()` / `string.find()` as function calls** (e.g., `string.lower(s)`), NOT method calls (e.g., `s:lower()`). Method calls index the string object, which crashes on secret strings.
4. **Use `issecretvalue(val)` to check** before operating on any value from a WoW API. If secret, return nil/default. If not secret, normal operations are safe. See §0.3b.
5. **Inside `AuraUtil.ForEachAura` callbacks**: Use pcall+string.format to safely extract values. Store for matching OUTSIDE the callback. The callback runs in Blizzard's execution context.
6. **Always use `pcall` around `C_UnitAuras` calls** — they can fail if the unit doesn't exist
7. **Single aura queries by spell ID/name are RESTRICTED** when aura access is secret (in combat/encounters/M+/PvP). Use index-based iteration instead.

### 0.3: String Method Calls vs Function Calls

**CRITICAL DISTINCTION** that causes crashes:

```lua
-- CRASHES on secret/tainted strings:
local lower = someString:lower()      -- indexes string object → crash
local found = someString:find("x")    -- indexes string object → crash
local clean = someString:gsub("_"," ") -- indexes string object → crash

-- SAFE — uses string library functions directly:
local lower = string.lower(someString)
local found = string.find(someString, "x", 1, true)
local clean = string.gsub(someString, "_", " ")
```

**RULE**: When operating on ANY string that came from a WoW API, ALWAYS use `string.lower()`, `string.find()`, `string.gsub()` etc. as function calls. NEVER use the `:method()` syntax.

### 0.3b: WoW 12.0 Secret Values — Complete Rules

**Source**: https://warcraft.wiki.gg/wiki/Secret_Values
**Source**: Official Blizzard posts on WoWUIDev Discord (Alpha 1 through Beta 9)

WoW 12.0 introduces "Secret Values" — opaque values returned by combat APIs that restrict addon logic. The system provides Blizzard granular control over what combat information addons can process.

**ALLOWED on secret values (tainted code):**
- `type(val)` — returns the real type ("string", "number", etc.), NOT secret
- `issecretvalue(val)` — returns true if the value is secret, NOT secret itself
- `canaccessvalue(val)` — returns true if calling function can operate on secrets
- Store in variables, upvalues, table values (NOT as keys)
- Pass to Lua functions (NOT C functions unless explicitly marked `SecretArguments`)
- Concatenation (`..`) of secret strings/numbers — result inherits secret state
- `string.format()`, `string.join()`, `string.concat()` — result inherits secret state
- Pass to whitelisted widget APIs (`StatusBar:SetValue()`, `FontString:SetText()`, `SetRotation()`)
- `AbbreviateNumbers()`, `AbbreviateLargeNumbers()` — result inherits secret state
- `WrapTextInColorCode()` — works with secret strings
- Equality comparison of two values of **different types** — returns non-secret `false`
- Equality comparison of two `nil` values — returns non-secret `true`

**BLOCKED on secret values (immediate Lua error):**
- **`if val then` — BLOCKED!** Boolean tests on secrets crash immediately. This includes ALL truthiness checks.
- `tonumber(val)` — C function, needs `SecretArguments` markup to accept secrets
- `tostring(val)` — blocked on ALL secret values
- Arithmetic: `val + 1`, `val * 2`
- Comparisons: `val == otherVal` (same-type), `val < 5`, `val > 0`
- Boolean tests: `if val then`, `val and x`, `val or x`, `not val`
- Length: `#val`
- Table keys: `tbl[val] = 1` — crashes AND irrevocably poisons the table
- Indexed access: `val["field"]`, `val.foo`, `val:method()`
- Calling as function: `val()`
- Method syntax string ops: `val:lower()`, `val:find("x")` — crashes

**String library functions on secrets (result inherits secret state):**
- `string.lower(val)` — function syntax works, returns SECRET string
- `string.find(val, pattern, 1, true)` — function syntax works, returns SECRET number or nil
- `string.format("%s", val)` — works, returns SECRET string
- `val .. ""` — concatenation works, returns SECRET string
- **WARNING**: The RESULTS of these operations are ALSO secret! You CANNOT do `if result then` on them!

**The correct Detaint pattern — return nil/false for ALL secrets:**
```lua
local function Detaint(val)
  if type(val) == "nil" then return nil end
  if issecretvalue and issecretvalue(val) then return nil end
  return tonumber(val)
end
local function DetaintStr(val)
  if type(val) == "nil" then return nil end
  if issecretvalue and issecretvalue(val) then return nil end
  if type(val) == "string" then return val end
  local ok, s = pcall(tostring, val)
  if ok then return s end
  return nil
end
local function DetaintBool(val)
  if type(val) == "nil" then return false end
  if issecretvalue and issecretvalue(val) then return false end
  if val then return true else return false end
end
```

**CRITICAL LESSON (A7-CORRECTED): Always return nil for secret values.**
Secret values CANNOT be inspected in tainted code. `pcall(tonumber, secretVal)` is dangerous
because even if it succeeds, the result is STILL secret — and `if ok and num then` performs a
boolean test on the secret result, which CRASHES. The only safe pattern: check `issecretvalue`,
return nil immediately, and let downstream code use fallback defaults.

**CRITICAL LESSON (A8-CORRECTED): Do NOT use pcall(string.lower/find) on secret strings.**
While `string.lower(secretStr)` technically works, the result is a SECRET string. Then
`string.find(secretStr, pattern)` returns a SECRET number. You CANNOT do `if foundPos then`
on a secret number — that's a boolean test which CRASHES. Instead, use `DetaintStr()` first:
if the value is secret, DetaintStr returns nil and you skip name matching. If it's NOT secret,
you get a clean string and can do normal string.lower/string.find operations safely.

**CRITICAL LESSON (A9): Player data is generally NOT secret.**
Player-targeted APIs (UnitHealth("player"), UnitPower("player"), GetShapeshiftForm(),
C_UnitAuras.GetBuffDataByIndex("player", i)) typically return NON-secret values.
Only enemy/target data in combat is secret. So the `issecretvalue → return nil` pattern
works correctly: player data passes through to normal operations, target data safely returns nil.

**Why the safe approach works for rotation addons:**
- Rotation addons primarily need PLAYER state (buffs, cooldowns, resources, form)
- Player state is NOT secret → Detaint functions pass values through normally
- Target data IS secret → Detaint returns nil → use safe defaults (assume target exists, etc.)
- WeakAuras and Hekili discontinued because they needed to INSPECT enemy state for logic

### 0.3c: Which APIs Return Secrets — Definitive List

Based on all Blizzard announcements through Beta 9 (February 2026):

**NOT secret (safe to use directly for player):**
- `GetSpecialization()`, `GetHaste()`, `GetTime()`, `InCombatLockdown()`
- `C_Spell.GetSpellTexture()`, `C_Spell.GetSpellName()`
- `UnitHealthMax("player")` — NOT secret for player units (Alpha 6+)
- `UnitPowerMax("player", type)` — NOT secret for player units (Alpha 6+)
- Player secondary resources via `UnitPower()`: Combo Points, Runes, Soul Shards, Holy Power, Chi, Arcane Charges, Essence (Beta 3+)
- `UnitStagger("player")` — NOT secret for player (Beta 3+)
- `GetComboPoints()`, `GetUnitChargedPowerPoints()` — NOT secret (Beta 4+)
- Player's own spellcasts (even in combat) — NOT secret (Alpha 6+)
- Player's own channeled/empowered casts — NOT secret (Beta 4+)
- `UnitIsUnit()` with target/focus/mouseover/softenemy/softinteract/softfriend — NOT secret (Beta 3+)
- AuraInstanceIDs — NOT secret (Alpha 6+, but NOT unique across units since Beta 6)
- Aura vectors from `GetUnitAuras` / `UNIT_AURA` event — NOT secret (but contents may be) (Alpha 6+)

**CONTEXTUALLY secret (secret during combat/encounters/M+/PvP):**
- Player's PRIMARY power (mana, energy, rage, fury, etc.) — secret when restricted
- `UnitHealth("player")` — secret when restricted
- Player cooldown data — secret when restricted
- Player aura data — secret when restricted (single aura queries by spell ID/name are BLOCKED when secret)
- `UnitHealth(otherUnit)` — secret for non-player units when restricted
- `UnitPower(otherUnit)` — secret for non-player units when restricted

**ALWAYS secret in instances:**
- Enemy/boss unit names, GUIDs, IDs — secret in instances (not based on combat state)
- Chat messages — secret while in M+/PvP/encounters
- Combat Log Events — removed entirely from addon access

**Restriction triggers (from `C_RestrictedActions` / `Enum.AddOnRestrictionType`):**
- Combat (PLAYER_REGEN_DISABLED)
- Instance Encounter (boss fight in progress)
- ChallengeMode (M+ keystone run active)
- PvPMatch (rated PvP match in progress)
- Map (being inside an instance)

### 0.4: Lua `local function` Hoisting

Lua does NOT hoist `local function` declarations. A `local function` only exists after its definition line. If function A calls function B, B must be defined BEFORE A in the file.

```lua
-- CRASHES: NormalizeName doesn't exist yet when ResolveSpellIcon is defined
function CLF.ResolveSpellIcon(name)
  local clean = NormalizeName(name)  -- ERROR: NormalizeName is nil
end

local function NormalizeName(raw)
  return raw:gsub("_", " ")
end

-- CORRECT: NormalizeName defined first
local function NormalizeName(raw)
  return string.gsub(raw, "_", " ")
end

function CLF.ResolveSpellIcon(name)
  local clean = NormalizeName(name)  -- OK
end
```

**RULE**: Before adding any `local function`, verify ALL callers appear AFTER it in the generated Lua output. If the function is called during initialization (not just at runtime), it MUST be defined before any initialization code that uses it.

### 0.5: SavedVariables Merge — Never Blindly Trust Saved Data

WoW's SavedVariables persist across addon updates. If the addon's config structure changes, stale saved data can override fresh defaults.

**IMPORTANT (Beta 1+):** SavedVariables are no longer allowed to contain secrets. Secrets in saved variables are replaced with nil on save.

```lua
-- BAD: Overwrites fresh config with stale saved data
if CLF_Config then
  config = CLF_Config  -- stale APL, missing new fields
end

-- GOOD: Merge saved settings into fresh config
if CLF_Config then
  -- Always use fresh APL/spec data from the addon
  config.apl = freshConfig.apl
  config.interrupts = freshConfig.interrupts
  config.spec = freshConfig.spec
  -- Only preserve user-customizable HUD settings
  for k, v in pairs(CLF_Config) do
    if k ~= "apl" and k ~= "interrupts" and k ~= "spec" then
      if config[k] == nil then
        config[k] = v
      end
    end
  end
end
```

### 0.6: Frame Lifecycle — Destroy Before Recreate

If `CreateHUD()` or similar can be called multiple times (e.g., after settings change), existing frames MUST be destroyed first. Otherwise duplicate frames stack up.

```lua
-- GOOD: Clean up before recreating
function CreateHUD()
  if CLF._hudFrame then
    CLF._hudFrame:Hide()
    CLF._hudFrame:SetParent(nil)
    CLF._hudFrame:ClearAllPoints()
  end
  -- ... create new frames
end
```

### 0.7: SpellHighlight Signal Differentiation

WoW's `C_SpellHighlight.GetHighlightType(spellID)` returns different values:
- `0` = no highlight
- `1` = static yellow border (standard assisted highlight)
- `≥2` = spinning/marching ants border (higher priority proc/suggestion)

**RULE**: Differentiate these in the signal system. Ants (≥2) should score higher than regular yellow border (1).

### 0.8: New WoW 12.0 Systems

**Duration Objects (Beta 4+):**
- New first-class Lua type for representing time spans
- Created via `C_DurationUtil.CreateDuration()`
- Configured via `:SetTimeSpan()`, `:SetTimeFromStart()`, `:SetTimeFromEnd()`
- Query via `:GetElapsedDuration()`, `:GetRemainingDuration()`, etc.
- Can be passed to `Cooldown:SetCooldownFromDurationObject()` and `StatusBar:SetTimerDuration()`
- Old APIs like `C_Spell.GetSpellCooldownRemaining` have been REMOVED — use Duration Objects

**C_Secrets namespace (Beta 4+):**
- `C_Secrets.ShouldUnitSpellCastBeSecret(unit)` — check if spellcast would be secret
- `C_Secrets.GetSpellAuraSecrecy(spellID)` — returns SecrecyLevel enum
- `C_Secrets.GetSpellCooldownSecrecy(spellID)` — returns SecrecyLevel enum
- `C_Secrets.GetPowerTypeSecrecy(powerType)` — returns SecrecyLevel enum

**C_RestrictedActions namespace (Beta 4+):**
- Query restriction states (Combat, Encounter, ChallengeMode, PvPMatch, Map)
- `ADDON_RESTRICTION_STATE_CHANGED` event when states change

**Boss Warning APIs (Beta 8+):**
- `C_EncounterEvents` namespace for static encounter event info
- `C_EncounterEvents.SetEventColor()`, `C_EncounterEvents.SetEventSound()`

**New Aura Filters (Beta 8+):**
- `CROWD_CONTROL`, `BIG_DEFENSIVE`, `RAID_PLAYER_DISPELLABLE`, `RAID_IN_COMBAT`

**Interface version:** TOC must use `120001` for 12.0.1 (Midnight launch). Addons without `120000` or higher WILL NOT LOAD.

---

## Rule System 1: Taint & Secret Values (CRASH severity)

### Core Concepts

WoW's security model has two layers:

1. **Taint propagation** — All addon code starts "tainted". Reading tainted data taints the execution path. If taint reaches a protected function call, `ADDON_ACTION_BLOCKED` fires.

2. **Secret values** (new in 12.0) — Certain WoW API returns are "secret". Tainted code faces strict restrictions on what it can do with secrets. Violations cause immediate Lua errors.

### Key Distinction: Tainted vs Secret
- **Tainted**: Value came from addon code. Taints execution path. Does NOT restrict value operations.
- **Secret**: Value is hidden by client. Operations on value itself are restricted.
- SavedVariables are tainted but NOT secret — comparisons are fine.

| Operation | Plain | Tainted | Secret |
|-----------|-------|---------|--------|
| `==` compare (same type) | OK | OK | CRASH |
| `==` compare (different types) | OK | OK | Returns non-secret `false` |
| `if x then` (boolean test) | OK | OK | **CRASH** |
| `x + 1` (arithmetic) | OK | OK | CRASH |
| `t[x] = v` (as key) | OK | OK | CRASH + poisons table |
| `x .. y` (concatenate) | OK | OK | OK (result is secret) |
| `tonumber(x)` | OK | OK | CRASH |
| `tostring(x)` | OK | OK | CRASH |
| `string.format("%s",x)` | OK | OK | OK (result inherits secret) |
| `type(x)` | OK | OK | OK (result is NOT secret) |
| `issecretvalue(x)` | OK | OK | OK (result is NOT secret) |
| `x:method()` | OK | OK | CRASH (indexes secret) |
| `string.method(x)` | OK | OK | OK (function call, not index) |
| Store in var | OK | OK | OK |
| `#x` (length) | OK | OK | CRASH |
| `x["key"]` (index) | OK | OK | CRASH |

### Taint Violation Patterns

**P1 — Direct comparison with secret API return**
```lua
-- BAD: if UnitName("target") == "Ragnaros" then
-- GOOD: if DetaintStr(UnitName("target")) == "Ragnaros" then
```

**P2 — Boolean test on secret API return**
```lua
-- BAD: if UnitExists("target") then  -- CRASHES on secret booleans
-- BAD: if UnitHealth("target") then  -- CRASHES on secret numbers
-- GOOD: if DetaintBool(UnitExists("target")) then  -- Safe: checks issecretvalue first
-- GOOD: if Detaint(UnitHealth("target")) then  -- Safe: returns nil for secrets
-- NOTE: `if val then` is BLOCKED on ALL secret values in tainted code!
```

**P3 — Arithmetic on secret API return**
```lua
-- BAD: local pct = UnitHealth("target") / UnitHealthMax("target") * 100
-- GOOD: local pct = Detaint(UnitHealth("target")) / Detaint(UnitHealthMax("target")) * 100
```

**P3b — Stored taint propagation (CRITICAL — real crash)**
A secret value stored in a table field (e.g., `rt.current = UnitPower(...)`) taints ALL subsequent
arithmetic on that field. The initial store does NOT crash — the crash happens later when any
code does `rt.current >= cost`, `mathMin(rt.max, rt.current + x)`, or similar comparisons.
This is extremely dangerous because the crash site is far from the taint source.

```lua
-- BAD: "OOC only" guard does NOT prevent taint storage
function OnUnitPowerFrequent()
  if inCombat then return end  -- UNIT_POWER_FREQUENT fires BEFORE _inCombat flips!
  local rawPow = UnitPower("player", pt)
  if type(rawPow) == "number" then  -- type() returns "number" for secret numbers!
    rt.current = rawPow            -- stores secret → ALL future math on rt.current CRASHES
  end
end

-- GOOD: Always use SafeNum before storing ANY API return into persistent state
function OnUnitPowerFrequent()
  if inCombat then return end
  local rawPow = UnitPower("player", pt)
  local cleanPow = SafeNum(rawPow, nil)  -- returns nil for secret values
  if cleanPow then
    rt.current = cleanPow
  end
end
```

**RULES for stored taint:**
1. `type(secretValue) == "number"` returns TRUE — type() is NOT a taint guard
2. Event handlers (UNIT_POWER_FREQUENT, UNIT_HEALTH) can fire BEFORE _inCombat flag changes
3. ANY field that participates in arithmetic MUST be guarded with SafeNum before read AND write
4. Use EnsureCleanRT() at the top of functions that do arithmetic on stored resource values
5. "OOC only" is NOT sufficient — always check issecretvalue regardless of combat state

**P4 — Secret value as table key**
```lua
-- BAD: cache[UnitName("target")] = true  -- CRASHES + poisons table
-- GOOD: cache[DetaintStr(UnitName("target"))] = true
```

**P5 — Missing local Detaint aliases**
Every `.lua` file that calls `Detaint`/`DetaintStr`/`DetaintBool` must define them locally (via `local function` or `local X = CLF.X`).

**P6 — `tostring(val)` / `tonumber(val)` on secret values**
```lua
-- BAD: tonumber(secretVal)          (CRASH)
-- BAD: tostring(secretVal)          (CRASH)
-- GOOD: Use issecretvalue() check first, then tonumber/tostring on non-secret values
-- GOOD: string.format("%s", val)    (OK, but result inherits secret state)
```

**P7 — Calling protected functions**
Never call `C_UI.Reload()`, `ReloadUI()`, `CastSpellByName()`, `TargetUnit()`, etc.

**P8 — Method syntax on API-returned strings**
```lua
-- BAD: DetaintStr(val):lower()     — may still crash in certain execution contexts
-- BAD: DetaintStr(val):find("x")   — same issue
-- GOOD: string.lower(DetaintStr(val))
-- GOOD: string.find(DetaintStr(val), "x", 1, true)
```

**P9 — Detaint inside Blizzard callback contexts**
```lua
-- BAD: Inside AuraUtil.ForEachAura callback, operating on aura fields directly
-- GOOD: Collect values inside callback (with pcall protection), match outside:
AuraUtil.ForEachAura(unit, filter, nil, function(aura)
  local nameOk, nameStr = pcall(string.format, "%s", aura.name or "")
  collected[i] = { n = nameOk and nameStr or "" }
end)
-- Now match outside callback context:
for i = 1, count do
  if string.find(string.lower(collected[i].n), search, 1, true) then ...
end
```

**P10 — `select()` with secret index**
```lua
-- BAD: select(classIndex, GetClassInfo())  -- if classIndex is secret
-- GOOD: select(Detaint(classIndex), GetClassInfo())
```

---

## Rule System 2: Combat Lockdown (FUNCTIONAL severity)

During combat (`InCombatLockdown() == true`), many frame operations are restricted:

### Forbidden during combat:
- `CreateFrame()` for protected frame types (SecureActionButton, etc.)
- `frame:SetAttribute()` on secure frames
- `frame:RegisterForClicks()` on secure frames
- Moving/reparenting secure frames

### Allowed during combat:
- `frame:Show()` / `frame:Hide()` on non-secure frames
- `frame:SetPoint()` on non-secure frames
- `texture:SetTexture()`, `fontstring:SetText()`
- Creating non-secure frames (though discouraged for performance)

### Violation Patterns

**L1 — CreateFrame in combat-called functions**
EvaluateAPL, UpdateHUD, RefreshSnapshot, and OnUpdate callbacks must NEVER call `CreateFrame()`. All frames must be pre-created at ADDON_LOADED time.

**L2 — SetAttribute during combat**
```lua
-- BAD (if called during combat):
button:SetAttribute("type", "spell")
-- GOOD: Set attributes in PLAYER_REGEN_ENABLED or ADDON_LOADED
```

**L3 — Missing InCombatLockdown() guard**
Any code that modifies secure frame attributes must check `InCombatLockdown()` first.

---

## Rule System 3: Memory & Performance (PERF severity)

WoW's Lua runs with garbage collection that can cause frame hitches. Critical for code called at 20Hz.

### Violation Patterns

**M1 — Table allocation in hot path**
```lua
-- BAD (called 20x/sec):
function CLF.EvaluateAPL()
  local results = {}  -- allocates new table every tick
end

-- GOOD: Reuse tables with wipe()
local results = {}
function CLF.EvaluateAPL()
  wipe(results)
end
```
Note: Some small table allocations are acceptable if the tables are short-lived and small.

**M2 — String concatenation in hot path**
```lua
-- ACCEPTABLE (small, infrequent):
local key = class .. "-" .. spec

-- BAD (per-frame, complex):
local msg = "Player " .. name .. " at " .. hp .. "% health"
-- BETTER: Use string.format or avoid building the string
```

**M3 — Missing OnUpdate throttle**
```lua
-- BAD:
frame:SetScript("OnUpdate", function(self, dt)
  heavyComputation()  -- runs 60+ times per second!
end)

-- GOOD:
local elapsed = 0
frame:SetScript("OnUpdate", function(self, dt)
  elapsed = elapsed + dt
  if elapsed < 0.05 then return end  -- 20Hz max
  elapsed = 0
  heavyComputation()
end)
```

**M4 — Tooltip without cleanup**
```lua
-- BAD: Leaks tooltip data
GameTooltip:SetOwner(frame, "ANCHOR_TOP")
GameTooltip:SetSpellByID(spellId)

-- GOOD: Always hide after scanning
GameTooltip:SetOwner(frame, "ANCHOR_TOP")
GameTooltip:SetSpellByID(spellId)
-- reads tooltip lines...
GameTooltip:Hide()
```

**M5 — Uncached global lookups in hot path**
```lua
-- BAD (global lookup every call):
function doThing()
  local t = GetTime()
end

-- GOOD (cached at file scope):
local GetTime = GetTime
function doThing()
  local t = GetTime()
end
```

---

## Rule System 4: API Compatibility (COMPAT severity)

WoW 12.0 (Midnight) deprecated many APIs. Code must handle both new and legacy.

### Violation Patterns

**A1 — Bare deprecated API without fallback**
```lua
-- BAD: Only works on old clients
local name = GetSpellInfo(spellId)

-- GOOD: Modern API with fallback
local name
if C_Spell and C_Spell.GetSpellName then
  name = C_Spell.GetSpellName(spellId)
elseif GetSpellInfo then
  name = GetSpellInfo(spellId)
end
```

**Deprecated → Modern mapping:**
| Legacy API | Modern API (12.0) | Notes |
|-----------|-------------------|-------|
| `GetSpellInfo()` | `C_Spell.GetSpellInfo()` / `C_Spell.GetSpellName()` | |
| `GetSpellCooldown()` | `C_Spell.GetSpellCooldown()` | |
| `GetSpellTexture()` | `C_Spell.GetSpellTexture()` | |
| `IsSpellKnown()` | `C_SpellBook.IsSpellKnown()` | |
| `IsUsableSpell()` | `C_Spell.IsSpellUsable()` | |
| `UnitBuff()` | `C_UnitAuras.GetBuffDataByIndex()` | **REMOVED** in 12.0 |
| `UnitDebuff()` | `C_UnitAuras.GetDebuffDataByIndex()` | **REMOVED** in 12.0 |
| `UnitAura()` | `C_UnitAuras.GetBuffDataByIndex()` / `GetDebuffDataByIndex()` | **REMOVED** in 12.0 |
| `GetSpellLink()` | `C_Spell.GetSpellLink()` | |
| `AuraUtil.FindAuraByName()` | Manual scan with `GetBuffDataByIndex` | Case-sensitive, unreliable |
| `C_Spell.GetSpellCooldownRemaining()` | Duration Objects | **REMOVED** in PTR 1 |
| `C_UnitAuras.GetAuraDurationRemaining()` | Duration Objects | **REMOVED** in PTR 1 |
| `PlaySoundFile(path)` | `PlaySound(soundKitId, channel)` | File paths broken in 12.0 |
| `SetOverrideBindingClick()` | `OnUpdate`+`IsKeyDown()` polling | **PROTECTED** in 12.0 |
| `SetPropagateKeyboardInput()` | Avoid entirely | **PROTECTED** on secure frames |

**A2 — Wrong interface version in TOC**
The TOC `## Interface:` must be `120001` for Midnight launch (12.0.1). Addons without `120000` or higher will NOT load at all (no player override).

**A3 — Using removed globals**
Some globals were removed entirely, not just deprecated. Always check with `if FunctionName then` before calling.

**A4 — PlaySoundFile with file paths**
`PlaySoundFile("Sound\\Interface\\RaidWarning.ogg", "Master")` is broken in WoW 12.0. All sound playback must use numeric Sound Kit IDs:
```lua
-- BAD: File paths broken in 12.0
PlaySoundFile("Sound\\Interface\\RaidWarning.ogg", "Master")

-- GOOD: Use Sound Kit IDs with PlaySound()
PlaySound(8959, "Master")  -- 8959 = Raid Warning
```

Common Sound Kit IDs:
| Sound | Kit ID |
|-------|--------|
| Raid Warning | 8959 |
| Ready Check | 8960 |
| PVP Flag Taken | 8174 |
| Alarm Clock Warning 3 | 12867 |
| Raid Boss Emote Warning | 37666 |
| GM Chat Warning | 12889 |
| Map Ping | 3175 |
| Coin | 120 |

**A5 — Protected binding/keyboard APIs**
These APIs are **PROTECTED** in WoW 12.0 — calling them from addon code causes ADDON_ACTION_BLOCKED:
```lua
-- BAD: Protected, will crash
SetOverrideBindingClick(frame, true, "J", "MyButton")
SetPropagateKeyboardInput(false)

-- GOOD: Poll key state in OnUpdate
frame:SetScript("OnUpdate", function(f)
  if IsKeyDown("J") and not f._keyDown then
    f._keyDown = true
    -- handle key press
  elseif not IsKeyDown("J") then
    f._keyDown = false
  end
end)
```

**A6 — UnitAura() is removed alongside UnitBuff()/UnitDebuff()**
`UnitAura(unit, index, filter)` was the generic form of `UnitBuff`/`UnitDebuff`. ALL THREE are removed in 12.0. Use the `C_UnitAuras` API instead:
```lua
-- BAD: All removed in 12.0
local name, icon, count = UnitAura("player", i, "HELPFUL")
local name, icon, count = UnitBuff("player", i)
local name, icon, count = UnitDebuff("target", i)

-- GOOD: Modern C_UnitAuras API
if C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
  for i = 1, 40 do
    local ok, aura = pcall(C_UnitAuras.GetBuffDataByIndex, "player", i)
    if not ok or type(aura) ~= "table" then break end
    if type(aura.name) == "nil" then break end
    if issecretvalue and issecretvalue(aura.name) then
      -- skip secret aura
    else
      local name = DetaintStr(aura.name)
      local duration = Detaint(aura.duration)
      local expiry = Detaint(aura.expirationTime)
      -- process aura...
    end
  end
end
```

---

## Rule System 5: Event Handler Correctness (LOGIC severity)

### Violation Patterns

**E1 — Registering non-existent events**
WoW silently ignores `RegisterEvent()` for non-existent event names — but the handler never fires. Check event names against the wiki.

**E2 — Missing PLAYER_ENTERING_WORLD handler**
Many state-dependent systems need re-initialization on zone changes / instance transitions. If the addon tracks combat state, buffs, or target info, it should handle this event.

**E3 — Not unregistering events when disabled**
If the addon can be toggled off, events should be unregistered to prevent unnecessary processing:
```lua
frame:UnregisterEvent("UNIT_HEALTH")
```

**E4 — UNIT_HEALTH without unit filter**
```lua
-- WASTEFUL: fires for ALL units
frame:RegisterEvent("UNIT_HEALTH")

-- BETTER: Only fires for units we care about
frame:RegisterUnitEvent("UNIT_HEALTH", "player")
frame:RegisterUnitEvent("UNIT_HEALTH", "target")
```

---

## Rule System 6: Global Namespace Hygiene (QUALITY severity)

### Violation Patterns

**G1 — Unnecessary global variables**
Addons should minimize globals. Use the addon table (`CLF`) for all shared state. Acceptable globals: `SLASH_*`, `StaticPopupDialogs.*`, `CLF_*` (SavedVariables).

**G2 — Overwriting Blizzard globals**
Never reassign Blizzard globals like `FONT_COLOR_CODE_CLOSE`, `GameTooltip`, `UIParent`, etc.

**G3 — Missing local declarations**
Lua variables without `local` become globals, causing namespace pollution and potential conflicts with other addons.

---

## Rule System 7: Error Handling (RESILIENCE severity)

### Violation Patterns

**R1 — Missing pcall/xpcall around risky operations**
API calls that can fail (tooltip scanning, spell info lookups) should be wrapped:
```lua
local ok, result = pcall(function()
  return C_Spell.GetSpellInfo(spellId)
end)
if ok then -- use result
```

**R2 — Error handler that can itself error**
Error handlers passed to xpcall must be bulletproof — never index into potentially-nil tables.

**R3 — No degraded mode recovery**
If the addon hits repeated errors, it should degrade gracefully rather than spamming errors at 20Hz. Use an error counter with a threshold.

---

## Quick Reference Checklist

Before submitting ANY Lua code change, verify:

- [ ] No bare `UnitBuff()` / `UnitDebuff()` calls (use `C_UnitAuras.GetBuffDataByIndex` / `GetDebuffDataByIndex`)
- [ ] No `AuraUtil.FindAuraByName()` (use manual scan with case-insensitive matching)
- [ ] No `:method()` calls on strings from WoW APIs (use `string.method(str)` function syntax)
- [ ] All WoW API returns detainted before comparison/arithmetic
- [ ] `issecretvalue()` used as the primary secret check, NOT string.format-based approach
- [ ] All `local function` definitions appear BEFORE their callers in the file
- [ ] No string operations inside `AuraUtil.ForEachAura` callbacks (collect, then match outside)
- [ ] All `pcall` around `C_UnitAuras` / `C_Spell` calls that might fail
- [ ] `type(val) == "nil"` used for nil checks on potentially secret values (or `if val then` which is safe since Alpha 6)
- [ ] SavedVariables merge preserves fresh APL/spec data, only imports user settings
- [ ] HUD recreation destroys existing frames first
- [ ] TOC interface version is `120001`
- [ ] No `tonumber()` or `tostring()` called directly on potentially secret values

---

## Running the Full Audit

The automated scanner at `reference/audit-scanner.ts` checks rules P1-P10 (taint/secret values). Run it with:
```
npx tsx .agents/skills/wow-taint-model/reference/audit-scanner.ts
```

For manual review of other rule categories, use the analysis commands documented in this skill to scan for L1-L3, M1-M5, A1-A3, E1-E4, G1-G3, and R1-R3 patterns.

---

## Hard-Won Lessons Log — NEVER REGRESS ON THESE

This section records corrections and discoveries made through external research, real testing, or production crashes. Each entry documents what we believed, what was actually true, and what the fix was. **Before any code change, check this log for relevant entries.**

### L01: GetShapeshiftForm() is NOT removed (2026-03-13)
- **Wrong assumption**: SKILL.md Section 0.1 listed `GetShapeshiftForm()` as removed.
- **Reality**: External Blizzard API research confirmed `GetShapeshiftForm()` still works in 12.0. Only `GetShapeshiftFormInfo(index)` was removed.
- **Fix**: Removed `GetShapeshiftForm()` from the "Removed APIs" table. Added to "Still-Available APIs" (Section 0.1b). Removed all `GetShapeshiftFormInfo` code from `CurrentForm()`, using only `GetShapeshiftForm()` → `FORM_INDEX_MAP` → `FindAura` buff scan.
- **Rule**: Do NOT replace `GetShapeshiftForm()` with buff-only detection. The 2-tier chain (index map + buff scan) is correct.

### L02: InCombatLockdown() must be DetaintBool-wrapped (2026-03-13)
- **Wrong pattern**: Used bare `if not InCombatLockdown() then` across 6 call sites.
- **Reality**: `InCombatLockdown()` return may be tainted. Bare boolean checks on tainted values are BLOCKED → ADDON_ACTION_BLOCKED.
- **Fix**: Wrapped all 6 sites with `DetaintBool(InCombatLockdown())`.
- **Rule**: Every WoW API return used in an `if` condition must go through `Detaint()`/`DetaintBool()`/`DetaintStr()` first. No exceptions.

### L03: loadstring() causes permanent taint (2026-03)
- **Wrong pattern**: APL conditions were compiled at runtime via `loadstring(conditionSrc)`.
- **Reality**: `loadstring()` in WoW 12.0 returns tainted functions. Any value they return is secret. This caused Starfire to be "stuck" for 30 minutes — the condition was always tainted nil.
- **Fix**: Emit conditions as inline `conditionFn = function() return ... end` in the config Lua file. Compiled by Lua parser at file-load time, not by loadstring at runtime. Zero taint.
- **Rule**: NEVER use `loadstring()` in production addon code. Inline all generated functions.

### L04: arcane_charges resource token was missing (2026-03-13)
- **Gap**: SimC APL for Arcane Mage uses `arcane_charges` token. Our `conditionToLua()` had no mapping for it, causing it to pass through as a bare Lua global (undefined = nil = always false).
- **Fix**: Added `arcane_charges` → `CLF.Power()` mapping in the resource token section.
- **Rule**: When adding a new class/spec, audit ALL resource tokens used in its SimC APL against our mapping list. Missing tokens silently break conditions.

### L05: External research trumps assumptions (ongoing)
- **Pattern**: Multiple times we've had our skill file contradict what Blizzard actually shipped. The skill file was written from early beta notes; Blizzard changed things before launch.
- **Rule**: When external sources (wowpedia, warcraft.wiki.gg, addon community) conflict with this skill file, **update this skill file** to match reality. Add a new L-entry documenting the correction. Never silently work around a skill file entry that's wrong.

### L06: Fixes must be generic, not class-specific (design principle)
- **Pattern**: When a bug manifests in one class (e.g., Druid Starfire stuck), the temptation is to add a druid-specific fix.
- **Rule**: Always find the root cause and fix it generically. The Starfire stuck bug was a loadstring taint issue affecting ALL classes. The defensive OOC bug was a missing combat gate affecting ALL classes. Never add `if className == "DRUID" then` workarounds.

### L07: String method syntax (:lower, :find, :gsub) is forbidden on API strings (design rule)
- **Wrong pattern**: `auraName:lower()` — method syntax on a secret string throws.
- **Reality**: In WoW 12.0, calling methods on secret values throws. Function syntax (`string.lower(val)`) also throws on secrets, but we detaint FIRST.
- **Rule**: Always `DetaintStr()` first, THEN `string.lower()` / `string.find()` on the clean result. Never use method syntax (`:lower()`, `:find()`, `:gsub()`) anywhere in generated Lua — always use function syntax (`string.lower()`, `string.find()`, `string.gsub()`).

### L08: Duration Object struct returns (WoW 12.0 API change)
- **Old pattern**: `C_Spell.GetSpellCooldownRemaining()` returned a single number.
- **Reality**: That API was REMOVED. `C_Spell.GetSpellCooldown()` returns a struct `{ startTime, duration, isEnabled }`. Must access fields.
- **Rule**: Always access `.startTime`, `.duration`, `.isEnabled` on the return value. Never assume a flat number return from cooldown APIs.

### L09: Watchdog addon — separate Lua environment for crash resilience (2026-03-13)
- **Problem**: DMGAssist's built-in diagnostics (`/dmga snapshot`, `/dmga selftest`) die with the addon if it crashes or enters degraded mode.
- **Solution**: DMGAssist_Watchdog is a separate addon in its own folder. Separate Lua environment = immune to taint/crashes in the main addon. Uses `OptionalDeps: DMGAssist` (not Dependencies) so it loads even if DMGAssist fails.
- **Resilience pattern**: Every read of `_G.CLF` or its fields goes through `SafeRead(func, fallback)` (pcall wrapper) and `SafeReadField(tbl, key, fallback)`. OnUpdate poll and event handler are both pcall-wrapped. Watchdog's own errors become `WD_ERROR` log entries, never crashes.
- **Rule**: Watchdog code must NEVER call any CLF method directly. Always `SafeRead(function() return clf.SomeMethod() end, fallbackValue)`. Never use `:method()` syntax on any value read from CLF.
- **Main addon hooks**: `CLF._heartbeat` (incremented every tick), `CLF.PushWDEvent(type, data)` (ring buffer of 60 engine events). Watchdog reads these passively.

### L10: Varargs `...` cannot propagate into nested closures (Lua scoping rule, 2026-03-13)
- **Problem**: `wdFrame:SetScript("OnEvent", function(self, event, arg1, ...) pcall(function() select(1, ...) end) end)` produces `cannot use '...' outside a vararg function`.
- **Fix**: Capture extra args as named parameters: `function(self, event, arg1, arg2)` instead of `function(self, event, arg1, ...)`.
- **Rule**: Never use `...` inside a nested `function()` closure. Always capture varargs into named locals before entering pcall/closures.

### L11: CLF_DefaultConfig nil bug — SavedVariables bypass (all-specs build, 2026-03-13)
- **Problem**: In all-specs builds, Config.lua sets `CLF_DefaultConfig = nil`. If user has SavedVariables (`CLF_Config` from previous session), `OnAddonLoaded` skips ALL fallback paths because `CLF_Config` already exists. CLF_DefaultConfig stays nil forever. The PLAYER_ENTERING_WORLD handler also skips setting it if the saved spec matches the detected one.
- **Fix**: Three changes: (1) Always `CLF_DefaultConfig = CLF_DefaultConfig or CLF_Config` at end of OnAddonLoaded. (2) PEW handler sets `CLF_DefaultConfig = detected` BEFORE the spec-match check, not inside it. (3) OnAddonLoaded refreshes `CLF_Config.apl` from `CLF_AllSpecs` when SavedVariables provide a stale config.
- **Rule**: Any code path that sets CLF_Config must also ensure CLF_DefaultConfig is set. Never leave CLF_DefaultConfig nil in the all-specs build.

### L12: Watchdog backslash escaping — entire addon fails to load (2026-03-13)
- **Problem**: Watchdog.lua texture paths used `\\` in TypeScript template strings, producing single `\` in Lua output (`"Interface\Minimap\..."`). Lua parses `\M`, `\I` etc. as invalid escape sequences → syntax error → **entire Watchdog.lua fails to load**, no minimap icon, no monitoring.
- **Fix**: Use `\\\\` in template strings so Lua output has `\\` (double backslash), which Lua interprets as a literal backslash. Same pattern already used correctly in HUD.lua and other generated files.
- **Rule**: In TypeScript template strings that emit Lua code, WoW texture paths must use `\\\\` to produce `\\` in the Lua output. Always validate generated Watchdog.lua with `luac -p` or `loadfile()`.

### L13: conditionToLua regex ordering — trinket/cooldown/operator conflicts (2026-03-13)
- **Problem**: Live SimC profiles contain trinket cooldown conditions (`trinket.2.cooldown.remains`), double operators (`&&`), double modulo (`%%`), apex talent nodes (`apex.3`), and complex `<?`/`>?` operators with parenthesized operands. The `conditionToLua` function had regex ordering bugs where: (1) Bare `cooldown.X` catch-all matched `cooldown.remains` inside `trinket.2.cooldown.remains`, producing `0("remains")`. (2) `&&` became `and  and`. (3) `%%` was not Lua-valid. (4) `apex.3` caused Lua 5.1 to parse `.3` as a number literal. (5) `<?`/`>?` regexes with `[()]` in character class captured parentheses incorrectly.
- **Fix**: Five changes: (1) Move trinket handlers BEFORE cooldown handlers. (2) Normalize `&&`→`&` and `||`→`|` before `&`→`and`. (3) Normalize `%%`→`%`. (4) Add `apex.\d+` handler (→ `false`). (5) Use `[\w.]+` (no parens) for `>?`/`<?` regex and fall back to dropping `?` for complex operands.
- **Rule**: In `conditionToLua`, compound tokens (trinket.X.cooldown.Y) MUST be handled before their generic sub-tokens (cooldown.X). Always test with LIVE SimC data, not just seed data. Run Lua syntax validation on the generated output with live data.

### L14: SimC variable definitions must be parsed and compiled — not skipped (2026-03-13)
- **Problem**: `"variable"` was in `SKIP_ACTIONS` (simc-parser.ts), so all SimC `variable,name=X,value=EXPR` definitions were discarded. `CLF.GetVar("X")` always returned 0. For Balance Druid, 53/88 APL conditions reference `variable.X`, all evaluated to false → queue stuck on filler. Additionally, `variable.X` was always wrapped with `~= 0` (boolean), producing `(CLF.GetVar("X") ~= 0)<=7` — comparing boolean to number, which errors in Lua 5.1.
- **Fix**: Three changes: (1) Parse variable definitions in `parseSimcProfile`, extracting `name`, `value`, `op` fields into `SimcVariable[]`. (2) Compile variables to Lua functions via `compileVariablesToLua`/`CLF._varFns`, called by `CLF.GetVar`. (3) Two-pass `variable.X` replacement in `conditionToLua`: pass 1 replaces numeric context (followed by `<>=!+-*/%`) with raw `CLF.GetVar("X")`, pass 2 wraps remaining boolean context with `(CLF.GetVar("X") ~= 0)`.
- **Rule**: SimC variables are NOT skip-actions — they define computed expressions used by ~60% of APL conditions. The `variable.X` replacement must distinguish numeric vs boolean context. In Lua 5.1, `0` is truthy (unlike SimC where it's falsy), so boolean-context variables MUST use `~= 0`.

### L15: All Safe* WoW API wrapper functions MUST normalize spell names (2026-03-13)
- **Problem**: `SafeGetSpellCooldown`, `SafeIsUsableSpell`, `SafeGetSpellCharges`, and `SafeIsSpellInRange` passed spell identifiers directly to WoW APIs without calling `NormalizeName()`. When `conditionToLua` converts `cooldown.avenging_wrath.ready` → `CLF.CooldownReady("avenging_wrath")`, the snake_case token was sent to `C_Spell.GetSpellCooldown("avenging_wrath")` which fails (WoW expects "Avenging Wrath" or a spell ID). The API returns nil → `GetCDInfo` defaults to ready=true → the cooldown spell is always recommended → queue permanently stuck on first spell.
- **Fix**: Add `NormalizeName()` calls at the top of all four `Safe*` functions. For string identifiers, convert underscores to spaces. For numeric spell IDs, pass through unchanged. Also moved `NormalizeName` definition above the `Safe*` functions so Lua can resolve the forward reference.
- **Rule**: Every function that passes a spell/buff/debuff name to any WoW C_Spell/C_UnitAuras API MUST normalize the name first. Functions like `FindAura`, `SpellCastTime`, `IsSpellKnown` already did this — the `Safe*` functions were the only ones missing it.

### L16: Cooldowns are SECRET during combat — use GetActionCooldown as primary source (2026-03-13)
- **Problem**: Per §0.3c, "Player cooldown data — secret when restricted." During combat, `C_Spell.GetSpellCooldown()` returns secret values. `Detaint()` correctly returns nil for secrets (per A7-CORRECTED). This means `nil or 0` → `cd=0` → every spell appears "ready" → queue permanently stuck because spells on cooldown still show as available.
- **Evidence**: Watchdog showed 343K taint hits on `C_Spell.GetSpellCooldown`, ALL spells showing `cd=0` even after being cast. Avenging Wrath (2min CD) perpetually at queue position #1.
- **Fix**: Dual-source cooldown system: (1) In `ScanActionBars`, use `GetActionCooldown(slotID)` (action bar API, NOT secret — the player's cooldown sweeps must always be visible) instead of `C_Spell.GetSpellCooldown`. (2) Populate `CLF._barCD[spellName]` cache from action bar data. (3) `GetCDInfo` tries C_Spell first, then falls back to `CLF._barCD` when C_Spell returns 0/0 (secret → nil → defaults). The `> 1.5` threshold filters out GCD-only cooldowns.
- **Rule**: NEVER rely solely on `C_Spell.GetSpellCooldown` for rotation logic. Player cooldown data is secret during combat. `GetActionCooldown(slotID)` is the only reliable source because it drives the player's own UI cooldown display. Always maintain a dual-source pattern with action-bar fallback.
