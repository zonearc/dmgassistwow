# Prior art: Hekili and MaxDps

Reference copies (not committed — MaxDps is "All Rights Reserved", Hekili ships no license file) live in the
git-ignored `.libraries/reference/`. Keep the original zips locally; re-upload them to a session when needed.

| Package | Version | Interface | sha256 |
|---|---|---|---|
| MaxDps | v11.3.81 | 120105 | `6ace9a8b4ac5b0bc71d905255a986db9fc6adc3f46686111f5bd260b5562f5f3` |
| MaxDps_Druid | v11.2.18 | 120105 | `6f20172dc9ee9185fe3b8d766fd600cabeb65b10f2d40986ec769b8bf76cfbb3` |
| MaxDps_Paladin | v11.2.21 | 120105 | `5c2febb5eda6d69a83212d1d9d746c05e6eafbd181c8736acf50e19e7877fdad` |
| Hekili | v11.2.5-1.0.0 (last release, The War Within) | 110205 | `ed8e186def65d0ca7eb8ee7f77ea1cd8d9250a94edd05a5a5fe164f6003ede1b` |

## MaxDps (works on Midnight and Forever today)

- **Midnight default path is Blizzard's recommendation.** `Core.lua` (~line 809): when no custom rotation is
  enabled, `self.Spell = C_AssistedCombat.GetNextCastSpell(false)`, filtered through its own usability check,
  plus a handful of hand patches (Unholy DK Blightfall swap; Holy Paladin → Shield of the Righteous at 5 Holy Power).
  It also sets the `assistedCombatIconUpdateRate` CVar out of combat. So on Mainline it is mostly a re-skin of
  Assisted Combat — as suspected.
- **Forever detection:** `WOW_PROJECT_ID == WOW_PROJECT_CAMELOT` (Mainline: `WOW_PROJECT_MAINLINE`).
- **Per-game-type file loading in the TOC:** `File.lua [AllowLoadGameType standard]`,
  `File.lua [ExcludeLoadGameType standard, mists, cata, wrath, tbc, vanilla]`. "standard" = Mainline retail.
  MaxDps loads its `SecretHelper.lua` on Forever by *excluding* every other type, so it doesn't need to know
  Forever's own game-type name. We can use the same trick to ship one addon with Forever-only and
  Mainline-only engine files.
- **Combat log is gated off** on Retail and Forever (`Helper.lua`: `if not IsRetailWow() and not IsForeverWow()`);
  the swing timer that needs CLEU loads only on vanilla.
- Calls `issecretvalue(v)` from addon code throughout — circumstantial evidence it works on secrets from tainted
  code (our probe's `secretSelfTest` will confirm).
- Since Assisted Combat is disabled on Forever, MaxDps on Forever must be running its own class-module
  rotations — worth comparing against our probe data once we have it.

## Hekili (TWW, no longer works) — the scope we're inspired by

What made it great, and whether each piece survives the 12.x rules:

| Hekili feature | How it worked | 12.x / Forever status |
|---|---|---|
| SimC APL-driven priorities | Per-spec APL text compiled to Lua | Still possible as data. Conditions on target debuffs / enemy counts / primary power are mostly unreadable now. |
| **Virtual state machine** | `state.reset()` snapshots real game state; `state.advance(t)` simulates forward, running each ability's handler (cost, cooldown start, buff applied) to predict the next N casts | **The core idea we keep.** `reset` is what's blinded; `advance` is pure modelling and still works if we seed it from readable inputs + our own tracking. |
| Multiple displays | Primary, AOE, Cooldowns, Interrupts, Defensives (`Core.lua` ~1551) with toggles | Fine — pure UI. |
| N-step lookahead queue with timing | Predicts 3–4 casts ahead from the simulated state | Possible with self-tracked cooldowns/resources; accuracy depends on resync. |
| Target counting | Nameplates + combat log | Combat log gone; nameplate counting limited by secret unit info. Needs a fallback (manual ST/AoE toggle like the old DMGAssist "mode"). |
| Snapshots (debug) | Dump the full decision state for a recommendation | Our Watchdog plays this role; extend it to log engine decisions via `DMGAssistWatchdog.Log`. |
| Keybind display, toggles, pause | UI conveniences | Fine. |

## What this means for the DMGAssist engine

A Hekili-style simulator whose `reset` is rebuilt from what's still readable:

1. **Observed truths (resync points):** `IsSpellUsable` (incl. `insufficientPower`), cooldown `isActive` /
   `isOnGCD`, proc glows, own casts (`UNIT_SPELLCAST_SUCCEEDED`), secondary resources, whitelisted auras.
2. **Self-tracked state:** cooldown timers started from our own casts with known durations (adjusted by haste where
   applicable), charge counters, buff windows we caused, resource models for primary power.
3. **Correction:** whenever an observed truth disagrees with the model (e.g. model says on cooldown but
   `isActive == false`), snap the model to the truth and log the drift to the Watchdog. Drift logs tell us which
   models need fixing — that's the feedback loop the old project lacked.
4. `advance()` then simulates forward from that state to produce the queue.
