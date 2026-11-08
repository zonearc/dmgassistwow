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
