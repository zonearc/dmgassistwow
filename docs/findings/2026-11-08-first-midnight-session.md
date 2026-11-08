# First in-game session: Midnight 12.1.5, Balance druid (2026-11-08)

Source: two Watchdog exports pasted into chat (build 0.1.0.1), screenshots, a BugSack error.
Character: druid, Restoration at login, then Balance; Silvermoon training dummies; DBM installed; BugSack, Pawn,
Scrap, Threat Plates.

## What happened
| Observation | Cause | Fix |
|---|---|---|
| HUD showed only Moonfire, for the whole fight | Balance's `opener` list starts with `moonfire,line_cd=999`; the engine ignored `line_cd`. A second Moonfire line has `target_if=refreshable&...&spell_targets>1`, also ignored, so it always passed. And `variable.opener` was rebuilt from the precombat list on every decision, so it could only clear while Celestial Alignment's buff was visible. | `line_cd` honoured (time since the spell's last cast this fight, look-ahead aware); a bare / `first:` `target_if` joins the condition (`min:`/`max:` still ignored: only the current target is visible); list variables live for the fight and are committed when the player casts, as SimC runs its list once per action. Hidden buffs that only our own spells apply count as down until we see the cast. |
| `GetAuraDataByIndex(): Auras cannot be accessed when secret while tainted by 'DMGAssist'` (15x, caught) | The diagnostics probe asked for an aura in restricted combat. State already checked `C_Secrets.ShouldAurasBeSecret()` first. | Probe checks it too and records the input as "secret" without calling. |
| Boss whisper / boss emote sounds silent, map ping too quiet | Played from an addon, those kits made no sound (raid warning, ready check, alarm, whisper did). | Removed; added alarm (short), queue pop, friend toast; interrupt default is now ready check; saved choices of removed sounds reset. |
| Watchdog error list empty while BugSack showed 225 errors | `!BugGrabber` loads first and keeps the global error handler; ours never got installed. | The report reads BugGrabber's list (`GetDB`, `GetSessionId`; verified against BugGrabber v12.1.0's source, which replaces `seterrorhandler` with a no-op). |
| `MainMenuBarMicroButtons.lua:425: attempt to call a nil value` (225x) | Not DMGAssist: we never touch the micro menu or tooltips. Next report will show the full error via BugGrabber. | — |
| "TP - DEBUG Auras: could not pre-allocate AuraContainer pools" in chat | Threat Plates' own debug output. | — |
| No minimap icon | The rebuild had none (the 1.5.0 build did). | Minimap button + addon compartment entry. |

## Confirmed facts
- `variable.opener` style SimC variables must persist across decisions to behave like SimC.
- `C_Secrets.ShouldAurasBeSecret()` is true in restricted combat on Midnight (the call errored otherwise).
- In combat, `UnitSpellHaste` went secret (haste readability ok → secret at restriction 2), cooldown `isActive`
  became nil after ~5 s of combat on the GCD probe.
- Assisted Combat's pick flips between a spell and nil out of combat as targets change (now not logged out of combat).
- Balance list match on this character: 9 of 17 list spells known (missing include Eclipse, Force of Nature, moons);
  Restoration has no SimC damage list worth using (8 of 17).

## Second session (build 0.1.0.3, Balance, Cleave Training Dummies)
| Observation | Cause | Fix |
|---|---|---|
| Never suggested Eclipse | SimC's `eclipse` resolved only to the passive Eclipse talent (1239669); the buttons are Lunar Eclipse 1233272 / Solar Eclipse 1233346 (the assistant's pick range reached 1233272). Every Eclipse line was skipped as "not known". | Importer: `UNLOCKS` maps a SimC action that is only a passive talent to the castable spells (eclipse → lunar_eclipse, solar_eclipse). |
| Stuck on Starfall | Starfall's lines hinge on hidden procs (Starweaver's Warp, Touch the Cosmos) and Astral Power, which is secret in combat (`astral_power=secret34`); Blizzard's rule `starfall if active_enemies>3` was true on the cleave dummies, so the uncertain line kept being confirmed. Exact cause needs a trace. | Auto "stuck" snapshot: 3 casts of other spells while the HUD shows one spell stores a full trace. Next report shows it. |
| `ADDON_ACTION_BLOCKED ... OpenSettingsPanel()` | Minimap left-click in combat; the Settings panel is protected in combat. | Opens when combat ends. |
| Assistant oracle switched itself off (`clue_disabled source=assisted wrong=7` of 20) | Its inferred facts disagreed with the truth 7 times. | Watch in the next report. |

## Third session (0.1.0.3 still installed, Balance)
| Observation | Cause | Fix |
|---|---|---|
| Starfire for 25 s, no cooldowns | The opener waits for Celestial Alignment; the engine put it in the separate cooldown icon (`cd=celestial_alignment` at 2.9 s), which went unnoticed, so the opener never ended. | No separate icon: major cooldowns are ordinary lines in the three slots (off = never shown). Interrupts, then defensives, then the rotation, all in the three slots; nothing else on the HUD. |
| Would have stuck on Wrath next | Astral Power is secret in combat; "wrath while astral_power<80" never resolved. Wrath/Moonfire/Sunfire showed no Astral Power gain in our data (the gain comes from the hidden "Astral Power" passive 197911). | Importer folds baseline passives' flat modifiers into energize effects; a floor for built resources (Astral Power, Insanity, Maelstrom, Fury, Runic Power) from our own casts, graded and self-disabling. |
| Rage gains 10x, Insanity 100x too high in data | Spell data stores those in tenths / hundredths. | POWER_DIVISOR covers rage, runic power, insanity. |
| Sunfire/Moonfire DoT clocks never started | The button and its DoT are separate spells with no link in the data. | Casting starts the same-named aura's clock (State.AppliedAuras). |
| Celestial Alignment looked ready again 1 s after use in the look-ahead | Data has cd 1 + one 180 s charge; the 1 s was used. | Cooldown = max(cd, recharge). |
| Blizzard Minimap.lua:286 `GameTooltip:Hide()` "attempt to call a nil value" (541x) | Same as the micro-button error: something broke the game tooltip. Not DMGAssist (no tooltip hooks). | Launch snapshot records the tooltip's fields and who changed them (issecurevariable). |

## Fourth session (0.1.0.8, Balance Elune's Chosen, decision traces)
- Timing: predicted vs real Starfire cast within ~50 ms (1845 vs 1766-1936 ms) once cast events drive it.
- After Lunar Eclipse the opener's Starfire line was UNKNOWN (buff.ascendant_fires is a hidden proc) and was
  taken because our evaluation of a Blizzard rule held, while Blizzard's live assistant said Fury of Elune
  (ac=202770) / Starfall (ac=191034). Fury of Elune and Celestial Alignment, later in the opener, were never
  reached. Fix: with the live assistant present only it confirms an uncertain line (Engine.Corroborated).
- buff.eclipse was always UNKNOWN: Lunar/Solar Eclipse casts had no link to the Eclipse (Lunar/Solar) buffs.
  Importer links a cast to the same-named aura its description quotes ($48518d); buff.eclipse aliases both.

## Fifth session (0.1.0.10, two reports)
- Eclipse shown while the game would not cast it (no charge left): the cooldown API reports a charge spell
  with charges as not on cooldown and IsSpellUsable ignores charges. Charges are now counted from casts
  (GetSpellCharges when readable), shared by the spells of one list entry (Lunar/Solar Eclipse).
- 100-117 s: Blizzard's assistant said Lunar Eclipse, SimC's eclipse line was certainly false. Cause: our
  expression engine had SimC's max/min operators reversed. SimC (engine/sim/expressions.cpp): "<?" is
  TOK_MAX, ">?" is TOK_MIN. eclipse_timings ("the longest of these cooldowns") was computed as the shortest.
  Affects 10 Midnight lists (Feral 10 uses, Balance, Elemental, Havoc 3 each, Destruction, Affliction,
  Devastation 2, Assassination ...) and the WoWSims converter's min/max. Fixed and tested.
- Watchdog window's X did not close it: wired explicitly.

## Sixth session (export 7, Balance Elune's Chosen)
- Incarnation: Chosen of Elune sat in slot 2 for a minute and never reached slot 1. Its line in the cooldowns
  list was castable with a true condition, but the list is entered through `variable.cds`, which was UNKNOWN:
  one term of its "longest of these < 1" is `buff.eclipse.remains-(10*(buff.bloodlust.up*buff.ascendant_stars.down))`
  (hidden procs). Uncertain lines need corroboration, and Blizzard's assistant never names major cooldowns
  (they are its excluded lines), so nothing could ever confirm it.
  Fixes (general): the expression engine keeps limits for unknown values (flags 0..1, times and counts >= 0,
  resource bounds) so such terms are decided when the limits allow; for major cooldowns Blizzard's rules confirm
  instead of the live assistant; and a key spell (cooldown >= 20 s) that SimC keeps reaching for 4 s while the
  assistant says something else comes in anyway (`simc+waited`). Fillers never escalate.
- Slot 1 switched 2-3 times a second close to the press: slot 1 is now locked for the last 0.5 s before the
  GCD / cast ends (at most 1.5 s); a different new pick goes to slot 2. Interrupts and defensives still take slot 1.
- Title row: more room above the icons, shown only in combat, no "?".
- Long setting names were cut off in the settings list: short names, the detail in tooltips.
- Saving cooldowns on trash (player request): skipping the spell in slot 1 twice holds it until combat ends
  (on by default, "Hold skipped spells"); casting it yourself releases it at once. Off-GCD presses, interrupts and
  guesses never count as skips. Optional "Use cooldowns on: Bosses and big pulls" (off by default) keeps major
  cooldowns for bosses, PvP and pulls of 5+ enemies (adjustable).

## Seventh session (Feral)
- Suggested Moonfire, which takes you out of Cat Form. SimC's `moonfire_cat` is Lunar Inspiration's cat Moonfire
  (155625); the importer also matched the caster Moonfire (8921) by name, and every druid knows that one.
  Fix (general): the importer reads each spell's Stance Mask, and a `_cat` / `_bear` action keeps only the druid
  spells that work in that form (also corrected `swipe_cat` / `swipe_bear`, which each listed the other form's Swipe).
