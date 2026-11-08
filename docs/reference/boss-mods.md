# Boss mods and Blizzard's encounter timeline (researched 2026-11-08)

Sources: the public callback APIs of Deadly Boss Mods and BigWigs (as documented in their projects), and Blizzard's
UI source (live 12.1.5). DMGAssist only listens to these callbacks; it contains no boss mod code.

## What changed in Midnight
Boss mods can't read the combat log either. Blizzard added an **encounter timeline** (`C_EncounterTimeline`, also on
Forever) and **encounter warnings**. During an encounter the timeline's *what* is secret (`GetEventInfo` and the
`ENCOUNTER_TIMELINE_EVENT_ADDED` payload are `SecretWhenEncounterEvent`: spell, name, icon, severity, role icons),
but `id`, `source`, `duration` and `maxQueueDuration` are `NeverSecret` and `GetEventTimeRemaining` has no secret
returns. BigWigs/DBM boss modules identify abilities from those durations and their order
(e.g. BigWigs `Sporefall/Rotmire.lua`: 41 s = Festering Vines, 114 s = Fungal Bloom) and publish **plain, named**
timers. That is what we consume.

## Public APIs we listen to (read-only, nothing sent)
| Mod | Register | Messages used |
|---|---|---|
| DBM | `DBM:RegisterCallback(event, fn)` | `DBM_TimerBegin(id, msg, timer, icon, simpType, spellId, colorId, modId, …)` — colorId 1 adds, 2 AoE, 3 targeted, 4 interrupt, 5 role, 6 phase, 7 important; `DBM_TimerStop(id)`, `DBM_TimerUpdate(id, elapsed, total)`, `DBM_Announce(msg, icon, type, spellId, modId, isSpecial, count)` — type `interrupt`/`defensive`/`switch`/`taunt`/`dodge`/`moveaway`/`run`/`soak`…; `DBM_SetStage`, `DBM_Pull`, `DBM_Kill`, `DBM_Wipe` |
| BigWigs | `BigWigsLoader.RegisterMessage(ownerTable, message, fn)` | `BigWigs_StartBar(module, key, text, time, icon, isApprox, maxTime)`, `BigWigs_StopBar(module, text)`, `BigWigs_StopBars`, `BigWigs_Message(module, key, text, color, icon, isEmphasized)`, `BigWigs_SetStage`, `BigWigs_OnBossEngage/Win/Wipe`; keys `adds` and `stages` are BigWigs conventions |
| Blizzard | `C_EncounterTimeline.GetEventList` + `GetEventTimeRemaining` | "next boss event in N s" when no boss mod is installed (what it is stays secret) |

## What DMGAssist does with it (`Core/BossMods.lua`, setting "Use boss mod timers", default on)
- SimC `raid_event.adds.in/exists/up/remains/count` from adds timers and switch alerts — SimC lists use these to hold
  AoE cooldowns for incoming adds instead of wasting them.
- HUD callout line: alerts first (INTERRUPT, DEFENSIVE, TAUNT, SWITCH, MOVE…), then timers ≤ 10 s (AOE 3, TANK HIT 2,
  ADDS 8, PHASE 5) with the ability's icon.
- Next: defensive / interrupt suggestions (spec defensive and interrupt spells, timed to these callouts).
