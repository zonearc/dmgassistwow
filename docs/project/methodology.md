# How changes are made and checked (lessons of 2026-11-17/18)

The spec walk of 2026-11-18 found regressions in specs that had played better before (Outlaw, Assassination,
Enhancement), plus problems no check could see. Why, and the rules that follow.

## What went wrong
- Shared core rules were changed from one or two specs' evidence. Energy waits, slot 1 steadiness, opener phases,
  the learner and the wait display were tuned on Balance and Subtlety; Outlaw's Energy dips after every press, and
  the same rules made its slot 1 swap and its cue cycle.
- The gate measured the wrong thing. The simulated player always presses slot 1, so a stuck loop predicts itself
  (Balance's stuck opener scored 100%). A 10-point tolerance let drift through, and baselines were re-recorded
  with "the in-game test decides" - then only one spec was tested in game.
- The simulator can't see whole classes of bugs: no action bars (Hammer of Wrath), every fight starts fresh
  (Nature's Swiftness, Celestial Alignment cast before the pull), hidden fields don't match the game, no range or
  movement (Holy Nova), no visuals (probe flashing, sweep cycling, Flow's stalled note).
- Replays don't match what was shown for many specs (Subtlety 6%, Enhancement 44%), so fixes for them couldn't be
  checked offline.
- Many small releases (1.6.0.330-348 in two days), each tested on one spec.
- Whole-fight averages hid where it failed (the opener was 36%, the rest 65%).

## Rules now
1. A change to a shared rule (resources, slot 1 / slot 2 steadiness, phases, timing, display) is checked against
   recorded fights of every resource type before release: Energy, Rage, Runes / Runic Power, Focus, Mana, Astral
   Power / Maelstrom / Insanity, Holy Power / Chi / Combo Points. No recording for a type: say so in the release.
2. Every fix gets a test that fails without it (checked by removing the fix).
3. Anything that shows, hides or animates gets a test that drives the real updates and counts visual changes.
4. The simulator's numbers are a floor, not proof: a drop is investigated; a re-recorded baseline needs a reason and
   an in-game check of that spec.
5. Every upload is audited for all specs in it, not only what was reported (tools in the scratchpad audit: slot 2
   by time and phase, steadiness, refused presses, cast mix vs SimC, movement spells), and findings go into
   tasks.md as a checklist.
6. Rules are data-driven and named by mechanism, never by class (a button turned into another spell; a cooldown
   running at the pull; a spell only on another spell's button).
7. Releases are batched: fixes for one upload go out together, with the specs to re-test named.

## Still to build (tracked in tasks.md)
- Every Enhanced fight becomes a permanent replay test with invariants (no uncastable spell in slot 1 unless
  pooling, no movement spells, no spell not on the bars, no flicker, per-spec slot 2 not more than 3 points down).
  First: replay fidelity for every spec.
- Simulator realism: recorded bars and keys, pre-pull cooldowns and back-to-back pulls, secrecy learned from
  recordings, a player who skips / delays / presses other buttons, target range.
- A per-spec scorecard per release (slot 2, steadiness, refused presses, cast mix vs SimC), from the simulator and
  from real fights.

## Built (2026-11-18)

- `python3 tools/replay-suite.py` (in check.sh): every fight in tests/fights replayed; fails when a fight's slot 1 /
  slot 2 agreement drops more than 3 points or an invariant count rises. New uploads join the corpus with
  `python3 tools/fight-corpus.py`, then `--update` with the reason in the commit.
- Simulated fight "real" for every spec (bars, hidden active flag, cooldowns from the last pull, a late player who
  strays, range drop-outs); every spec's fights start at the same clock, so a single-spec run and the full run agree.
- `python3 tools/scorecard.py` writes docs/project/scorecard.md: run it with every release batch and read the bold
  cells first.
