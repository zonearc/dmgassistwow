#!/usr/bin/env python3
"""Replay every fight in tests/fights/ and check nothing got worse (part of scripts/check.sh).

    python3 tools/replay-suite.py            # check against tests/fights/baseline.json
    python3 tools/replay-suite.py --update   # record the current numbers (say why in the commit)

Per fight: slot 1 / slot 2 agreement with what was shown in game, slot 2 against the presses that came, and the
invariants (slot 1 never a spell the game called uncastable unless waiting by design, never a movement spell,
unexplained slot 1 changes a minute). A fight fails when slot 1 or 2 agreement or slot 2 vs presses drops more than
TOL points, or an invariant count rises. Owner, 2026-11-18: "we make changes to fix 1 thing, and then literally
break half the specs" - every recorded fight of every spec is checked on every build.
"""
import concurrent.futures, glob, gzip, json, os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIGHTS = os.path.join(ROOT, "tests", "fights")
BASE = os.path.join(FIGHTS, "baseline.json")
TOL = 3.0          # points of agreement a fight may lose
CHANGE_TOL = 2.0   # unexplained slot 1 changes a minute it may gain


def run(path):
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
        f.write(gzip.open(path, "rt").read())
        tmp = f.name
    try:
        out = subprocess.run(["lua5.1", "tests/replay.lua", tmp], cwd=ROOT, capture_output=True, text=True,
                             timeout=900).stdout
    finally:
        os.unlink(tmp)
    r = {}
    m = re.search(r"^SAME ([\d.]+) ([\d.]+) (\d+)", out, re.M)
    if m:
        r["same1"], r["same2"] = float(m.group(1)), float(m.group(2))
    m = re.search(r"^REAL ([\d.]+) (\d+)", out, re.M)
    if m:
        r["real"], r["presses"] = float(m.group(1)), int(m.group(2))
    m = re.search(r"^INV uncastable=(\d+) movement=(\d+) passes=(\d+) unexplained_per_min=([\d.]+)", out, re.M)
    if m:
        r["uncastable"], r["movement"] = int(m.group(1)), int(m.group(2))
        r["unexplained"] = float(m.group(4))
    return os.path.basename(path).replace(".lua.gz", ""), r


def main():
    update = "--update" in sys.argv
    paths = sorted(glob.glob(os.path.join(FIGHTS, "*.lua.gz")))
    with concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as ex:
        results = dict(ex.map(run, paths))
    base = json.load(open(BASE)) if os.path.exists(BASE) else {}
    fails = []
    print("%-34s %6s %6s %6s %4s %4s %5s" % ("fight", "same1", "same2", "real", "unc", "mov", "chg/m"))
    for name in sorted(results):
        r, b = results[name], base.get(name)
        print("%-34s %6.1f %6.1f %6.1f %4d %4d %5.1f" % (name, r.get("same1", 0), r.get("same2", 0),
              r.get("real", 0), r.get("uncastable", 0), r.get("movement", 0), r.get("unexplained", 0)))
        if not r:
            fails.append("%s: the replay printed nothing" % name)
            continue
        if not b or update:
            continue
        for k in ("same1", "same2"):
            if r.get(k, 0) < b.get(k, 0) - TOL:
                fails.append("%s: %s %.1f, was %.1f" % (name, k, r[k], b[k]))
        if b.get("presses", 0) >= 10 and r.get("real", 0) < b.get("real", 0) - TOL:
            fails.append("%s: slot 2 vs real presses %.1f, was %.1f" % (name, r["real"], b["real"]))
        for k in ("uncastable", "movement"):
            if r.get(k, 0) > b.get(k, 0):
                fails.append("%s: %s %d, was %d" % (name, k, r[k], b[k]))
        if r.get("unexplained", 0) > b.get("unexplained", 0) + CHANGE_TOL:
            fails.append("%s: unexplained slot 1 changes %.1f/min, was %.1f" % (name, r["unexplained"],
                                                                                 b["unexplained"]))
    if update:
        json.dump(results, open(BASE, "w"), indent=1, sort_keys=True)
        print("baseline written: %s (%d fights)" % (BASE, len(results)))
        return 0
    new = [n for n in results if n not in base]
    if new:
        print("not in the baseline yet (run with --update): " + ", ".join(new))
    if fails:
        print("FAILED:\n  " + "\n  ".join(fails))
        return 1
    print("%d fights, nothing got worse" % len(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
