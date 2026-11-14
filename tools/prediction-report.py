#!/usr/bin/env python3
"""Prediction report from a decoded DMGW1 export (tools/decode-export.py output).

For each fight: the in-game summaries (prediction_summary, learner_summary), then a replay of the "press" lines
(Core/Learner.lua) through several learner designs, so the design can be tuned on real play instead of guessed:

  slot2      what slot 2 said at the press (SimC's forecast, as shown)
  last1      the spell that most often followed the last press (no other context)
  last2      ... the last two presses
  full       last two presses + secondary resource + lit buttons + single target / AoE (the in-game learner)
  backoff    the in-game learner: spell + secondary resource + lit buttons, then the last two presses, then the
             spell alone while a situation is new
  cp_lit     spell + secondary resource + lit buttons only
  hybrid     the learner when its situation is confident (>= --conf), slot 2 otherwise

Every learner is scored online: it guesses before it sees each press, then learns it, as in the game. Fights in
the export are replayed in order, so later fights benefit from earlier ones (as across sessions).

Usage: python3 tools/prediction-report.py decoded.json [--min-n 4] [--conf 0.9]
"""
import argparse
import collections
import json


def parse_kv(text):
    out = {}
    for part in str(text).split():
        if "=" in part:
            k, v = part.split("=", 1)
            out[k] = v
    return out


class Model:
    def __init__(self, keyfn, min_n):
        self.counts = collections.defaultdict(collections.Counter)
        self.keyfn = keyfn
        self.min_n = min_n

    def guess(self, ctx):
        for k in self.keyfn(ctx):
            c = self.counts.get(k)
            if c and sum(c.values()) >= self.min_n:
                tok, n = c.most_common(1)[0]
                return tok, n / sum(c.values())
        return None, 0.0

    def learn(self, ctx, nxt):
        for k in self.keyfn(ctx):
            self.counts[k][nxt] += 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("decoded")
    ap.add_argument("--min-n", type=int, default=3)
    ap.add_argument("--conf", type=float, default=0.9)
    args = ap.parse_args()
    data = json.load(open(args.decoded))

    designs = {
        "last1": lambda c: [c["s"]],
        "last2": lambda c: [c["s"] + "<" + c["prev"]],
        "full": lambda c: [c["s"] + "<" + c["prev"] + "|" + c["cp"] + "|" + c["lit"] + "|" + c["tg"]],
        # the in-game learner (Core/Learner.lua Situations)
        "backoff": lambda c: [c["s"] + "|" + c["cp"] + "|" + c["lit"], c["s"] + "<" + c["prev"], c["s"]],
        "cp_lit": lambda c: [c["s"] + "|" + c["cp"] + "|" + c["lit"]],
    }
    models = {name: Model(fn, args.min_n) for name, fn in designs.items()}
    totals = collections.defaultdict(lambda: [0, 0])
    misses = collections.Counter()

    for s in data.get("sessions", []):
        presses = []
        print("== fight %s  %s  %.0fs  %s" % (s.get("id"), s.get("when"), s.get("duration") or 0, s.get("zone")))
        for e in s.get("events", []):
            if len(e) > 3 and e[1] == "D" and e[2] in ("prediction_summary", "learner_summary", "resource_audit",
                                                         "mark", "lane_close", "gains_learned"):
                print("   %s: %s" % (e[2], e[3]))
            if len(e) > 3 and e[1] == "D" and e[2] == "press":
                kv = parse_kv(e[3])
                if "s" in kv:
                    presses.append(kv)
        if not presses:
            continue
        fight = collections.defaultdict(lambda: [0, 0])
        prev = "-"
        ctxs = []
        for kv in presses:
            ctx = {"s": kv["s"], "prev": prev, "cp": kv.get("cp", "?"), "lit": kv.get("lit", "-"),
                   "tg": kv.get("tg", "?"), "q2": kv.get("q2")}
            ctxs.append(ctx)
            prev = kv["s"]
        for ctx, nxt in zip(ctxs, ctxs[1:]):
            truth = nxt["s"]
            if ctx["q2"]:
                fight["slot2"][0] += 1
                fight["slot2"][1] += ctx["q2"] == truth
                if ctx["q2"] != truth:
                    misses["%s: slot2 %s, pressed %s" % (ctx["s"], ctx["q2"], truth)] += 1
            guess_b, conf_b = None, 0.0
            for name, m in models.items():
                g, conf = m.guess(ctx)
                if g:
                    fight[name][0] += 1
                    fight[name][1] += g == truth
                if name == "backoff":
                    guess_b, conf_b = g, conf
            if ctx["q2"]:
                hybrid = guess_b if (guess_b and conf_b >= args.conf) else ctx["q2"]
                fight["hybrid"][0] += 1
                fight["hybrid"][1] += hybrid == truth
            for m in models.values():
                m.learn(ctx, truth)
        for name in ["slot2", "last1", "last2", "full", "cp_lit", "backoff", "hybrid"]:
            n, hit = fight[name]
            totals[name][0] += n
            totals[name][1] += hit
            if n:
                print("   %-8s %3d%%  (%d/%d)" % (name, round(100 * hit / n), hit, n))

    print("== all fights (learners carry over between fights)")
    for name in ["slot2", "last1", "last2", "full", "cp_lit", "backoff", "hybrid"]:
        n, hit = totals[name]
        if n:
            print("   %-8s %3d%%  (%d/%d)" % (name, round(100 * hit / n), hit, n))
    if misses:
        print("== slot 2's most common misses")
        for k, v in misses.most_common(10):
            print("   %3d  %s" % (v, k))


if __name__ == "__main__":
    main()
