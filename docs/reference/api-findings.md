# API findings that shape DMGAssist (Forever + Mainline)

Sources: Blizzard UI source (`Gethe/wow-ui-source`, branches `forever` = 1.60.1 (70862), `live` = 12.1.5 (70783), read 2026-11-08),
plus warcraft.wiki.gg pages pasted by the project owner (marked "up to date as of PTR 12.1.5 (69594)").
"Verified" = found in Blizzard's generated API docs or UI code. "Wiki-only" = needs an in-game check.

## 1. The big one: Assisted Combat is turned OFF on Forever (verified)

- `Blizzard_SettingsDefinitions_Frame/Camelot/InterfaceOverrides.lua`: `InterfaceOverrides.HasAssistedCombat()` returns `false`. Mainline returns `true`.
- `C_AssistedCombat` API still exists on the client (identical docs on both branches).
- In-game check: `/dump C_AssistedCombat.IsAvailable()` (expect `false` + a failure reason on Forever).
- Consequence: on Forever the rotation engine cannot use Blizzard's recommendation as authority. It must be our own priority engine.
- Forever does enable the Cooldown Manager (`HasCooldownViewer` = true) and the Swing Timer.

## 2. Secrecy rules are identical on Forever and Mainline (verified)

| API | Combat secrecy |
|---|---|
| `C_Spell.GetSpellCooldown` / `GetSpellCharges` / `GetActionCooldown` | `SecretWhenCooldownsRestricted` — but `SpellCooldownInfo.isActive`, `isEnabled`, `isOnGCD` are `NeverSecret` |
| `C_Spell.IsSpellUsable` → `isUsable, insufficientPower` | not secret |
| `C_ActionBar.IsUsableAction` → `isUsable, isLackingResources` | not secret |
| `C_SpellActivationOverlay.IsSpellOverlayed`, `SPELL_ACTIVATION_OVERLAY_GLOW_SHOW/HIDE` | not secret (pass plain spell IDs) |
| `C_UnitAuras.GetPlayerAuraBySpellID` | `SecretWhenUnitAuraRestricted`, `RequiresNonSecretAura` (whitelist only) |
| `C_UnitAuras.GetAuraDataByIndex` | `SecretWhenUnitAuraRestricted` |
| `UnitPower` / `UnitPowerMax` | `SecretWhenUnitPowerRestricted` (secondary resources are exempt per community reports — probe to confirm) |
| `UnitHealth` | `SecretReturns` |

| `UNIT_SPELLCAST_SUCCEEDED` (unit, castGUID, spellID) | `SecretWhenUnitSpellCastRestricted` — own-cast spell IDs may be secret in combat |
| `UNIT_AURA` | `SecretWhenAurasRestricted` |
| `UnitCastingInfo` / `UnitChannelInfo`, `UNIT_SPELLCAST_START` | `SecretWhenUnitSpellCastRestricted` (cast in progress may be hidden in combat) |
| `UnitSpellHaste`, `GetUnitSpeed` | `SecretWhenUnitStatsRestricted` |
| `UnitHealthPercent` | `SecretReturns`, `SecretWhenCurveSecret` |
| `UnitGUID`, `UnitRace` | `SecretWhenUnitIdentityRestricted` |
| `C_Traits.*`, `C_ClassTalents.GetActiveConfigID/GetActiveHeroTalentSpec`, `C_SpellBook.*` | no secrecy markers (talents/spellbook read out of combat anyway) |

Because own-cast events can be secret, the engine also infers casts from cooldown edges: a spell whose
`SpellCooldownInfo.isActive` (NeverSecret) turns true while `isOnGCD` is false was just cast (`Core/State.lua`).

Readable combat inputs for the engine: usable/affordable, on-cooldown yes/no, on-GCD, proc glows, own casts (`UNIT_SPELLCAST_SUCCEEDED` → spellID), secondary resources, whitelisted auras.

## 3. Tools the Watchdog / probe should use

**Find out exactly what's whitelisted (verified on Forever):**
- `C_Secrets.ShouldSpellCooldownBeSecret(spellID)`, `C_Secrets.ShouldSpellAuraBeSecret(spellID)`, `C_Secrets.GetSpellAuraSecrecy(spellID)`, `C_Secrets.GetSpellCooldownSecrecy(spellID)`, `C_Secrets.ShouldUnitPowerBeSecret(unit, powerType)`, `C_Secrets.ShouldCooldownsBeSecret()`, `C_Secrets.ShouldAurasBeSecret()`, `C_Secrets.HasSecretRestrictions()`.
  → The probe can loop over every spell in the spellbook and record which cooldowns/auras stay readable in combat. No guessing.
- `C_RestrictedActions.IsAddOnRestrictionActive(type)`, `GetAddOnRestrictionState(type)`, event `ADDON_RESTRICTION_STATE_CHANGED(type, state)`.

**Test restrictions without being in combat (wiki-only, 12.0.5+):**
- CVars `addonCombatRestrictionsForced`, `addonEncounterRestrictionsForced`, `addonChallengeModeRestrictionsForced`, `addonPvPMatchRestrictionsForced`, `addonMapRestrictionsForced`, `addonChatRestrictionsForced`. Set to 1 → APIs behave as if restricted.
  → Lets the probe run its full secret-value sweep standing in town. Check: `/dump C_CVar.GetCVar("addonCombatRestrictionsForced")` (nil = not on Forever).

**Capture real errors (verified):**
- `seterrorhandler` / `geterrorhandler` — chain onto the existing handler, record message + `debugstack()`.
- Events `ADDON_ACTION_BLOCKED(isTainted, function)`, `ADDON_ACTION_FORBIDDEN(isTainted, function)`, `LUA_WARNING(warningText)`.
- CVars `scriptErrors`, `taintLog` (writes `Logs/taint.log`), `taintLogObjectSecrets` (12.1.0, wiki-only).

**Export (verified on Forever):**
- `C_EncodingUtil.SerializeJSON`, `CompressString`, `EncodeBase64` (+ the Decode/Deserialize counterparts).
  → Export = JSON → compress → base64 → one copyable string. Primary path stays the SavedVariables file uploaded after `/reload`.
- Event `SAVED_VARIABLES_TOO_LARGE(addOnName)` — must cap log size and record if this ever fires.

**Performance (verified):** `C_AddOnProfiler.GetAddOnMetric(name, metric)` — log our own CPU cost per session.

## 4. Open questions the Watchdog probe answers

- Does `issecretvalue` / `canaccessvalue` work on secrets from addon code? (`secretSelfTest`; both are marked
  `SecretArguments = "AllowedWhenUntainted"`, the same marking most functions carry.)
- Is `UNIT_SPELLCAST_SUCCEEDED`'s `spellID` ever secret for the player? (Not marked `NeverSecret`; sessions record `<secret>` if so.)
- Does `C_AssistedCombat.IsAvailable()` return false on Forever, and with what reason?
- Do the `addon*RestrictionsForced` CVars exist on Forever? (`restrictions.cvars`, `/dmgw force on`)
- Which of the class's spells have secret cooldowns / auras in combat? (`spells[].cdSecret`, `auraSecret`)
- Are secondary resources readable in combat on Forever? (`powers`)
- While auras are restricted, does `C_UnitAuras.GetAuraDataByIndex` return `nil` or a table of secrets? (The engine treats
  every scan as unreadable while `C_Secrets.ShouldAurasBeSecret()` is true, so either is safe.)
- How often are own-cast spell IDs secret? DMGAssist logs `tracking` per fight to the Watchdog: `seen` / `secret` /
  `inferred` cast counts and `drift` (tracked clocks that disagreed with the game).

## 5. Lua environment notes

- WoW Lua = Lua 5.1 + taint (reference: https://www.lua.org/manual/5.1/).
- No `io`/`os` file access; persistence only via SavedVariables.
- WoW extras: `bit.*`, `wipe`, `strsplit`, `C_Timer.After/NewTicker`, `tContains`, `math.clamp`, `string.join`, `issecretvalue`, `canaccessvalue`, `canaccessallvalues`, `hasanysecretvalues`, `scrubsecretvalues`, `secretwrap`.
- Local test runtime: PUC Lua 5.1.5 + luacheck 1.2.0 (installed in the session; add to environment setup script).

## 6. Reading Blizzard's own UI is closed off (verified, live 12.1.5)

Widgets carry **secret aspects** (`Enum.SecretAspect`: Shown, Alpha, Text, VertexColor, Desaturation, BarValue,
Cooldown, …). When Blizzard code drives a frame with a secret value, `IsShown`/`IsVisible`/`GetAlpha`/`GetText`/
`GetValue`/`GetVertexColor`/`IsDesaturated` return secrets to addons (`SecretReturnsForAspect`). So scraping action
buttons, the Cooldown Manager or nameplate auras gives nothing secret APIs wouldn't.
Open question for the Watchdog probe (`cooldownManager`): the Cooldown Manager's buff items compute `isActive` in
plain Lua and store it on the frame (`Blizzard_CooldownViewer/CooldownViewer.lua`); aura instance IDs are secret there
(`CreateSecureAuraInstanceMap`). If `item.isActive` reads as a plain boolean in combat, DMGAssist uses it (graded
source "cdm"); otherwise it is ignored.
Also secret in combat: `GetSpellCastCount`, `GetSpellDisplayCount`, `GetSpellCharges` (cooldown restriction),
`GetTotemInfo` (per slot), `UnitThreatSituation`, `UnitStagger` (`Secret = true`), `GetHaste`/`GetCritChance`.
Not secret: `C_Spell.GetSpellPowerCost` (live costs; used for calibration), `C_Spell.GetOverrideSpell`,
`C_Spell.IsSpellInRange`, `UnitIsBossMob`, `UnitClassification`, `UNIT_POWER_UPDATE` payload, `UNIT_SPELL_HASTE`,
`PLAYER_TOTEM_UPDATE(slot)`, `C_EncounterTimeline.GetEventTimeRemaining`.

## 7. Showing secret values without reading them (verified, live 12.1.5 and forever 1.60.1)

Widgets accept secret values: `SetAlpha`, `SetText`, `SetValue`, `SetVertexColor` are `SecretArguments =
"AllowedWhenTainted"` (the widget then carries a secret aspect); `SetAlphaFromBoolean(value, ifTrue, ifFalse)` takes
a secret boolean. Curves evaluate secret inputs: `C_CurveUtil.CreateCurve()` (types Linear/Step/Cosine/Cubic),
`UnitPowerPercent(unit, powerType, unmodified, curve)` and `UnitHealthPercent(unit, usePredicted, curve)` take a
curve; the input is a 0..1 fraction. Results stay secret, so nothing can be decided from them, but the screen can
show the truth. DMGAssist uses this for two-spell branches (one hidden resource decides), the interrupt overlay
(secret `notInterruptible`, `C_Spell.IsSpellImportant`), and the low-health defensive.
Duration objects (`C_Spell.GetSpellCooldownDuration`, `C_UnitAuras.GetAuraDuration`) can drive cooldown swipes the
same way (not used yet).

## 8. Asking before reading auras (verified: API docs live 12.1.5 and forever 1.60.1; in game 2026-11-08)

`C_Secrets.ShouldAurasBeSecret()` ("queries for aura data will generally produce secret values") exists on both
clients. In restricted combat on Midnight, calling `C_UnitAuras.GetAuraDataByIndex` anyway raises
"Auras cannot be accessed when secret while tainted by '<addon>'" inside the call (seen in game; caught by `U.Call`).
Check `ShouldAurasBeSecret()` first and treat the auras as hidden. See
docs/findings/2026-11-08-first-midnight-session.md.

Addon compartment (Midnight): Blizzard_Minimap/Mainline/AddonCompartment.lua reads the TOC field
`AddonCompartmentFunc` and calls `_G[name](addonName, mouseButtonName)`; the icon comes from `IconTexture`.

BugGrabber (BugSack) keeps the global error handler; read its list with `BugGrabber:GetDB()` /
`BugGrabber:GetSessionId()` (unverified here against its source; every call guarded, outcome logged).
