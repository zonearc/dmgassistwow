# Mitigation profiles (Midnight)

How each spec stays alive, one file per spec. `tools/mitigation.py` checks every spell here against the game's
own data (SimC SpellDataDump: names, IDs, cooldowns, durations, charges, which spec can have it) and fails if a
spell the game flags as a "Big Defensive" for that spec is neither listed nor skipped with a reason. It writes
`addons/DMGAssist/Data/Mitigation.lua`, which the addon reads; nothing about a class lives in code.

When the game changes: edit the profile, run `python3 tools/mitigation.py`, commit both. `./scripts/check.sh`
fails while the generated file is out of date or a check fails. The format is described at the top of
`tools/mitigation.py`.

Parts, and when each is shown (all in the defensive icon on slot 1, never in the damage slots):

- `keep`: tank keep-up buttons, whenever they're due while you're tanking (Shield Block, Demon Spikes...).
- `big`: a boss mod says a big hit or raid-wide damage is coming: the first ready one, in this order.
- `reflect`: a boss mod says a spell is aimed at you: the first ready one.
- `low`: at low health (the spec's `health`, or your setting): the first ready one, in this order, lightest
  first so the big ones stay for emergencies. `heal` marks heals (never ahead of a hit, only when low).
- `capped`: a heal with all charges full is offered from a higher health already (a charge isn't wasted).
- `icon`: kept out of the damage slots, shown by another rule (Guardian's Ironfur stacks).
