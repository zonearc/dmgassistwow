#!/usr/bin/env python3
"""The owner's real fights against the offline game's assumptions (owner, 2026-11-16: "take the exports back in and
resolve issues and update the tester").

From a Watchdog export (decoded or not): the delay after the GCD before the next press (instants), the share of
presses that weren't slot 1, what was pressed instead, each glow's rate per minute (procs), fight lengths, the
targets of each press. Prints them beside what tests/test_scenarios.lua assumes (HUMAN_DELAYS, WRONG, procs.lua)
so the offline game can be set from real play.

Usage: python3 tools/calibrate.py export.txt|decoded.json
"""
import collections
import importlib.util
import json
import os
import re
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")


def fields(text):
    return dict(x.split("=", 1) for x in str(text).split() if "=" in x)


def cast_times(spec):
    path = os.path.join(ROOT, "addons", "DMGAssist", "Data", "midnight", spec + ".lua")
    if not os.path.exists(path):
        return None
    text = open(path, encoding="utf-8").read()
    i = text.find("spellInfo = {")
    return {int(a) for a, body in re.findall(r"\n    \[(\d+)\] = \{(.*?)\n    \},", text[i:], re.S)
            if re.search(r"\n      ct = [1-9]", body)}


def main():
    s = importlib.util.spec_from_file_location("rp", os.path.join(HERE, "replay.py"))
    rp = importlib.util.module_from_spec(s)
    s.loader.exec_module(rp)
    d = rp.load(sys.argv[1])
    gaps, presses, other, instead, secs = [], 0, 0, collections.Counter(), 0.0
    any_rec = any(s.get("rec") for s in d.get("sessions", []))
    glows = collections.Counter()
    targets = collections.Counter()
    for sess in d.get("sessions", []):
        ev = sess.get("events", [])
        if not ev:
            continue
        secs += max(e[0] for e in ev)
        casts = [(e[0], e[2]) for e in ev if e[1] == "C"]
        # instant after instant (a cast time isn't a delay): the spec from the recording's header, else every pair
        head = next((l for l in sess.get("rec") or [] if l.startswith("H ")), "")
        spec = re.search(r"spec=([a-z_]+)", head)
        timed = cast_times(spec.group(1)) if spec else None
        for (t0, a), (t1, b) in zip(casts, casts[1:]):
            if timed is not None and (a in timed or b in timed):
                continue
            if 0.3 < t1 - t0 < 3:
                gaps.append(t1 - t0)
        pick = None
        for e in ev:
            if e[1] == "G+":
                glows[e[2]] += 1
            if e[1] != "D":
                continue
            if e[2] == "pick":
                pick = fields(e[3])
            elif e[2] == "press":
                p = fields(e[3])
                presses += 1
                targets[p.get("tg")] += 1
                if pick and p.get("s") != pick.get("main"):
                    other += 1
                    instead["slot 2" if p.get("s") == pick.get("next") else "other"] += 1
    print("fights %d, %.0f s in all, %d presses" % (len(d.get("sessions", [])), secs, presses))
    if gaps:
        q = sorted(gaps)
        p5 = q[int(0.05 * (len(q) - 1))]
        delays = [g - p5 for g in q]
        print("press after press%s: p5 %.2f s (~ the GCD), delay beyond it: median %.2f, p90 %.2f   (offline: median "
              "0.25, p90 0.48)" % ("" if any_rec else " (cast times included: no recording)", p5, statistics.median(delays), delays[int(0.9 * (len(delays) - 1))]))
    if presses:
        print("not slot 1: %.0f%% of presses (offline: 10%%); instead: %s" % (
            100 * other / presses, ", ".join("%s %d%%" % (k, 100 * v / max(1, other)) for k, v in instead.items())))
        print("targets at the press: %s" % ", ".join("%s %d" % kv for kv in targets.most_common()))
    if glows and secs:
        print("glows per minute (procs the game showed):")
        for sid, n in glows.most_common(12):
            print("   %-10s %.2f/min" % (sid, 60 * n / secs))


if __name__ == "__main__":
    main()
