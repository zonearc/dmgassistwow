#!/usr/bin/env python3
"""Slot 2 accuracy for every spec in the graded simulator (tools/sim.py: the reference talents, the resource world,
Blizzard's real order, procs), in parallel. The number to move offline before going back to the game (owner,
2026-11-18: "get the baseline to 70% before we move back to the game engine").

    python3 tools/sim-all.py                       # 1 and 5 targets, 120 s, a late player, 2 seeds
    python3 tools/sim-all.py --specs monk_ --json /tmp/x.json
"""
import argparse, concurrent.futures, glob, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")


def run(spec, a):
    cmd = [sys.executable, os.path.join(HERE, "sim.py"), spec, "--targets", a.targets, "--fight", str(a.fight),
           "--seeds", str(a.seeds)]
    if not a.exact:
        cmd.append("--human")
    out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=3600).stdout
    per = {}
    for m in re.finditer(r"^\S+  (\d+) targets  slot 2 right ([\d.]+)%", out, re.M):
        per.setdefault(m.group(1), []).append(float(m.group(2)))
    return spec, {t: sum(v) / len(v) for t, v in per.items()}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--specs", default="")
    ap.add_argument("--targets", default="1,5")
    ap.add_argument("--fight", type=int, default=120)
    ap.add_argument("--seeds", type=int, default=2)
    ap.add_argument("--exact", action="store_true", help="a player who presses slot 1 the moment it is ready")
    ap.add_argument("--json")
    ap.add_argument("--bar", type=float, default=70.0)
    a = ap.parse_args()
    specs = sorted(os.path.basename(p)[:-5] for p in glob.glob(os.path.join(ROOT, "data", "reference", "*.json")))
    specs = [s for s in specs if a.specs in s]
    with concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as ex:
        res = dict(ex.map(lambda s: run(s, a), specs))
    ts = a.targets.split(",")
    print("%-28s %s   mean" % ("spec", "  ".join("%5st" % t for t in ts)))
    below, allv = [], []
    for s in specs:
        v = [res[s].get(t) for t in ts]
        got = [x for x in v if x is not None]
        mean = sum(got) / len(got) if got else 0
        allv.append(mean)
        flag = " <" if mean < a.bar else ""
        print("%-28s %s  %5.1f%s" % (s, "  ".join("%5.1f " % x if x is not None else "    - " for x in v), mean, flag))
        if mean < a.bar:
            below.append(s)
    print("\n%d specs, average %.1f%%; under %.0f%%: %d (%s)" % (len(specs), sum(allv) / max(1, len(allv)), a.bar,
                                                               len(below), ", ".join(below)))
    if a.json:
        json.dump(res, open(a.json, "w"), indent=1, sort_keys=True)


if __name__ == "__main__":
    main()
