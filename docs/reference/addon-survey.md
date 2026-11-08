# Survey: how popular addons work under Midnight's secret values (2026-11-08)

Read for techniques only (nothing copied): WeakAuras 5.21.1, MRT 5335, Details 2026-11-07, DBM-Core 12.1.20,
Plater v663 (uploaded by the owner, unpacked outside the repo). Counts = uses of 12.x APIs in their code.

| Addon | Midnight-aware? | What it does in combat | Worth integrating? |
|---|---|---|---|
| **DBM** (99 `issecretvalue`) | yes | Reads `C_EncounterTimeline` (event state/durations), names abilities, publishes timers | **Yes — done** (`Core/BossMods.lua`, callbacks only) |
| **BigWigs / LittleWigs** | yes | Same approach | **Yes — done** |
| **Plater** (126) | yes | Nameplates drawn from secrets: health/power through **curves** (`UnitHealthPercent(unit, true, curve)`, `UnitPowerPercent(..., CurveConstants.ScaleTo100)`), `SetAlphaFromBoolean`, `EvaluateColorValueFromBoolean`, cast bars via `UnitCastingDuration` duration objects + `SetTimerDuration`, `C_Spell.IsSpellImportant` for cast colour, aura filters by instance (`IsAuraFilteredOutByInstanceID`) | No (nameplates aren't our job) — **technique adopted** |
| **Details** (224) | yes | `C_DamageMeter` (Blizzard's built-in meter — `SecretWhenInCombat`), same DF unit-frame code as Plater | No: meter data is secret in combat, adds nothing for rotation |
| **MRT** (35 + `canaccessvalue`, `secretwrap`) | yes | Raid notes, cooldown assignments; reads auras only when not secret | Maybe later: a raid leader's note could tell when Bloodlust / burst is planned. Low priority |
| **WeakAuras 5.21.1** (1) | no | Not updated for Midnight's restrictions (one `issecretvalue`) | No |

## The big lesson: render secrets, don't read them
Blizzard lets addons *display* secret values. Widgets accept them (`SetAlpha`, `SetText`, `SetValue`,
`SetVertexColor`: `SecretArguments = "AllowedWhenTainted"`, the widget then carries a secret aspect), and curves
evaluate secret inputs (`C_CurveUtil.CreateCurve`, step curves; `UnitPowerPercent`/`UnitHealthPercent` take a curve,
input 0..1). Nothing can be decided from them, but the screen can show the truth.

Adopted in DMGAssist:
- **Secret branches** (`Engine.Branch`, `Display.RenderBranch`): when the top pick hinges on one hidden resource
  ("Ferocious Bite if combo_points>=5, else Shred"), the engine evaluates the line for every value of that resource,
  builds two step curves, and stacks both icons; the game sets their alpha from the real value. Works for any
  single-resource condition (combo points, holy power, chi, shards, energy thresholds...). Setting, default on.
- **Interrupt reminder**: our interrupt (Skull Bash, Kick, ... matched by ID) appears while the target casts;
  `notInterruptible` (possibly secret) drives its alpha via `SetAlphaFromBoolean`; a red border shows
  `C_Spell.IsSpellImportant` ("lethal if not interrupted"), also via a secret boolean. Setting, default on.

Next candidates with the same technique (not built yet):
- Execute-phase branch: `UnitHealthPercent("target", true, stepCurve)` for "below 20%/35%" lines.
- Real cooldown swipes on our icons: `C_Spell.GetSpellCooldownDuration(id)` + `Cooldown:SetCooldownFromDurationObject`.
- Real buff timers / stacks for tank buffs on the HUD: `C_UnitAuras.GetAuraDuration` duration objects,
  `GetAuraApplicationDisplayCount` (secret string) into `SetText`.
