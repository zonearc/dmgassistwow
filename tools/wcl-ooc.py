#!/usr/bin/env python3
"""Measure what each spec's resources do out of combat, from public Warcraft Logs reports (owner, 2026-11-14:
"3 seconds out of combat between pulls vs 30 makes a huge difference").

Every cast in a log carries the player's resource values. For top players' consecutive fights in one raid night it
takes the value at their last cast of a fight, the seconds until the next pull, and the value at their first cast
of the next one, and fits per resource:

  rate   per second out of combat (negative: drains, like Astral Power and Rage; positive: refills or builds)
  rest   where it settles after a long break (median after 90 s+; includes what a pre-cast gave at the pull)

Writes "ooc" into each spec of data/resource-gains.json ({powerType: {rate, rest, n}}, in game units), which
tools/simc_import.py folds into the spec data as record.oocPower. Only numbers are kept, no names.

Usage: python3 tools/wcl-ooc.py [--specs druid_balance,...] [--reports 4] [--zone 53] [--difficulty 4]
"""
import argparse
import importlib.util
import json
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("wclres", os.path.join(HERE, "wcl-resources.py"))
W = importlib.util.module_from_spec(spec)
spec.loader.exec_module(W)

MAX_FIGHTS = 25  # consecutive fights (boss and trash pulls) read per report


def scale(pt, mx):
    """The log keeps some resources in tenths (Astral Power, Rage, Runic Power) or hundredths (Insanity)."""
    if mx >= 5000:
        return 100.0
    if mx >= 900 and pt not in (0, 3):
        return 10.0
    return 1.0


def report_rows(code, name):
    d = W.query("query($c:String!){reportData{report(code:$c){fights{id startTime endTime encounterID}"
                " masterData{actors(type:\"Player\"){id name}}}}}", {"c": code})
    rep = d["reportData"]["report"]
    ids = [a["id"] for a in rep["masterData"]["actors"] if a["name"] == name]
    if not ids:
        return []
    # (a player is often in only part of a raid night: read on until MAX_FIGHTS fights with their casts)
    fights = sorted(rep["fights"], key=lambda f: f["startTime"])  # (trash pulls too: the short breaks)
    rows, prev, used = [], None, 0
    for f in fights:
        if used >= MAX_FIGHTS:
            break
        ev = W.events(code, f["id"], ids[0], "Casts", f["startTime"], f["endTime"], resources=True)
        ev = [e for e in ev if e.get("type") == "cast" and e.get("classResources")]
        if not ev:
            prev = None
            continue
        used += 1
        if prev:
            gap = (f["startTime"] - prev[0]) / 1000.0
            for r in ev[0]["classResources"]:
                end = [x for x in prev[1]["classResources"] if x["type"] == r["type"]]
                if end and r["type"] != 0:
                    k = scale(r["type"], r.get("max", 0))
                    rows.append((r["type"], gap, end[0]["amount"] / k, r["amount"] / k, r.get("max", 0) / k))
        prev = (f["endTime"], ev[-1])
    return rows


def fit(rows):
    out = {}
    for pt in sorted({r[0] for r in rows}):
        v = [r for r in rows if r[0] == pt]
        mx = max(r[4] for r in v)
        long_ = [s for _, g, e, s, m in v if g > 90]
        # breaks short enough that it hadn't settled yet, with a clear change
        rates = sorted((s - e) / g for _, g, e, s, m in v if 2 < g < 60 and abs(s - e) > 0.05 * m and 0 < s < m)
        if len(v) < 4:
            continue
        out[str(pt)] = {"n": len(v), "max": round(mx, 1),
                        "rate": round(statistics.median(rates), 2) if len(rates) >= 3 else None,
                        # the fast end (a count must not stay above the truth: it drains at least this fast)
                        "rateFast": round(rates[0] if rates[0] < 0 else rates[-1], 2) if len(rates) >= 3 else None,
                        "rest": round(statistics.median(long_), 1) if len(long_) >= 2 else None}
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--specs")
    ap.add_argument("--reports", type=int, default=4, help="reports (players) per spec")
    ap.add_argument("--zone", type=int, default=53)
    ap.add_argument("--difficulty", type=int, default=4)
    args = ap.parse_args()
    specs = args.specs.split(",") if args.specs else sorted(
        f[:-4] for f in os.listdir(W.DATA) if f.endswith(".lua") and f != "Index.lua")
    out = json.load(open(W.OUT)) if os.path.exists(W.OUT) else {}
    branch = out.setdefault("midnight", {})
    for s in specs:
        try:
            picks = W.top_fights(s, args.zone, args.difficulty, args.reports)
            rows = []
            for code, _fight, name in picks:
                rows += report_rows(code, name)
        except Exception as e:  # one spec's trouble doesn't stop the rest
            print("%-26s skipped: %s" % (s, e), file=sys.stderr)
            continue
        f = fit(rows)
        if f:
            branch.setdefault(s, {})["ooc"] = f
            json.dump(out, open(W.OUT, "w"), indent=1, sort_keys=True)
        print("%-26s %s" % (s, f))


if __name__ == "__main__":
    main()
