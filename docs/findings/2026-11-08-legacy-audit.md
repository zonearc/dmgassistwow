# Legacy audit (2026-11-08)

Inputs: `legacy/DMGAssist-replit/` (generator source, last edits 2026-03-26, version file 1.5.0.282)
and `legacy/DMGAssist-1.5.0.282-shipped/` (the generated addon as uploaded to CurseForge 2026-09-17, still "Under Review").
CurseForge history: 1.5.0.273 (2026-03-30) is the last approved build (~1.0K downloads).

## F1: shipped 1.5.0.282 Config.lua does not parse — whole file fails to load

```
luac5.1: Config.lua:4469: '<name>' expected near 'false'
  conditionFn = function() return not buff.false end,
  conditionText = "!buff.eclipse.up",
```

The SimC→Lua transpiler rewrote `eclipse.up` inside `buff.eclipse.up` to `false`, producing `buff.false`.
WoW refuses to load a file with a syntax error, so every spec's APL table (all of Config.lua) is missing
at runtime. Nothing in-game makes this obvious. Lesson: every generated Lua file must pass `luac -p`
before it ships — now enforced by CI in this repo.

## F2: Core.lua registers COMBAT_LOG_EVENT_UNFILTERED (Core.lua:244)

Raises ADDON_ACTION_FORBIDDEN on 12.x / Forever. All CLEU-derived state (target GUID tracking,
SPELL_ENERGIZE resource modelling, per-GUID debuffs) is dead.

## F3: assumptions in the old rule files that the current API docs contradict

- L16 "GetActionCooldown is never secret" — it is `SecretWhenCooldownsRestricted`. Only `isActive`/`isEnabled`/`isOnGCD` are never secret.
- A9 "player data is generally not secret" — player cooldowns, auras and primary power are all contextually secret.
- 0.1c "secret non-nil → true" — a secret `false` is non-nil; this inverts results.
- The Watchdog was folded into the main addon (Watchdog.lua listed in DMGAssist.toc), losing the isolation lesson L09 called for.

## F4: lint

`luacheck` over the shipped files: 2191 warnings (mostly globals) and the F1 syntax error.
