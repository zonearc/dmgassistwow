#!/usr/bin/env python3
"""Score every spec offline and compare with the last saved run - the harness for patches and code changes (owner,
2026-11-16: "as new patches come in, if we could feed Warcraft logs and patch notes to it we could model out
changes and verify the addon adjusts to it well, we catch the impacts of things").

Per spec: slot 2 right (tools/sim.py: one and five targets, --seeds N, the human player) and the rotation match
against real players (tools/rotation-check.py). Writes data/sim-scores.json (the run before is kept as
data/sim-scores.prev.json) and prints the specs that moved by more than the spread of their seeds.

Usage: python3 tools/score.py [--seeds 3] [--specs a,b] [--jobs 7] [--no-save]
"""
import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
OUT = os.path.join(ROOT, "data", "sim-scores.json")
PREV = os.path.join(ROOT, "data", "sim-scores.prev.json")


def all_specs():
    return sorted(f[:-5] for f in os.listdir(os.path.join(ROOT, "data", "reference")) if f.endswith(".json"))


def one(spec, seeds):
    out = subprocess.run([sys.executable, os.path.join(HERE, "sim.py"), spec, "--targets", "1,1,1,5,5,5", "--fight",
                          "120", "--seeds", str(seeds), "--human"], cwd=ROOT, capture_output=True, text=True).stdout
    runs = re.search(r"seeds \d+: mean ([\d.]+), lowest ([\d.]+), highest ([\d.]+)", out)
    vals = [float(x) for x in re.findall(r"right ([\d.]+)", out)]
    rot = subprocess.run([sys.executable, os.path.join(HERE, "rotation-check.py"), spec], cwd=ROOT,
                         capture_output=True, text=True).stdout
    m = re.search(r"match ([\d.]+)\s+(.*)$", rot, re.M)
    row = {"slot2": round(sum(vals) / len(vals), 1) if vals else None}
    if runs:
        row.update(low=float(runs.group(2)), high=float(runs.group(3)))
    if m:
        row.update(match=float(m.group(1)), off=m.group(2).strip())
    return spec, row


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seeds", type=int, default=3)
    ap.add_argument("--specs")
    ap.add_argument("--jobs", type=int, default=7)
    ap.add_argument("--no-save", action="store_true")
    a = ap.parse_args()
    specs = a.specs.split(",") if a.specs else all_specs()
    prev = json.load(open(OUT)) if os.path.exists(OUT) else {}
    rows = {}
    with concurrent.futures.ThreadPoolExecutor(a.jobs) as ex:
        for spec, row in ex.map(lambda s: one(s, a.seeds), specs):
            rows[spec] = row
    old = prev.get("specs", {})
    print("%-24s %7s %7s  %6s  %s" % ("spec", "slot2", "was", "match", "moved / most off in the rotation"))
    for spec in sorted(rows, key=lambda s: rows[s].get("slot2") or 0):
        r, o = rows[spec], old.get(spec, {})
        spread = max(2.0, (r.get("high", 0) - r.get("low", 0)) / 2)
        moved = ""
        if o.get("slot2") is not None and r.get("slot2") is not None and abs(r["slot2"] - o["slot2"]) > spread:
            moved = "%+.1f " % (r["slot2"] - o["slot2"])
        print("%-24s %7s %7s  %6s  %s%s" % (spec, r.get("slot2"), o.get("slot2", "-"), r.get("match", "-"), moved,
                                           r.get("off", "")))
    vals = [r["slot2"] for r in rows.values() if r.get("slot2") is not None]
    ms = [r["match"] for r in rows.values() if r.get("match") is not None]
    avg = sum(vals) / len(vals) if vals else 0
    print("AVERAGE slot2 %.1f (was %s), rotation match %.2f" % (avg, prev.get("average", "-"),
                                                              sum(ms) / len(ms) if ms else 0))
    if not a.no_save and not a.specs:
        if os.path.exists(OUT):
            shutil.copy(OUT, PREV)
        json.dump({"average": round(avg, 1), "seeds": a.seeds, "specs": rows}, open(OUT, "w"), indent=1,
                  sort_keys=True)


if __name__ == "__main__":
    main()
