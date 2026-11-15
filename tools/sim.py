#!/usr/bin/env python3
"""Simulated fights for one spec, offline, with the real addon (tests/test_scenarios.lua's graded mode): the
reference talents, a resource world measured from logs (Data/ResourceTargets.lua), the game's restrictions on.
Prints slot 2's accuracy per fight and writes the fights' log as a decoded report, so the same tools read it as a
real one (owner, 2026-11-15: "improve the offline testing system so you can do more without me"):

  python3 tools/sim.py druid_balance --targets 8,8,8 --fight 180 --log /tmp/sim.json
  python3 tools/why-report.py /tmp/sim.json --all
  python3 tools/resource-replay.py /tmp/sim.json --fit

Fights run in order in one session, so what the addon learns in one (the in-play fit) is used in the next.
"""
import argparse
import json
import os
import re
import subprocess
import tempfile
import importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("spec")
    ap.add_argument("--targets", default="1,5")
    ap.add_argument("--fight", type=int, default=120)
    ap.add_argument("--log")
    ap.add_argument("--seeds", type=int, default=1, help="random runs (procs, timing); prints each and the spread")
    ap.add_argument("--human", action="store_true", help="the player presses a measured moment after the GCD")
    a = ap.parse_args()
    spec_ = importlib.util.spec_from_file_location("grade", os.path.join(HERE, "grade.py"))
    g = importlib.util.module_from_spec(spec_)
    spec_.loader.exec_module(g)
    refs = {a.spec: json.load(open(os.path.join(ROOT, "data", "reference", a.spec + ".json")))}
    f = tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False)
    f.write(g.talents_file(refs))
    f.close()
    env = dict(os.environ, SCEN_GRADE=f.name, SCEN_FIGHT=str(a.fight), SCEN_TARGETS=a.targets)
    if a.human:
        env["SCEN_HUMAN"] = "1"
    if a.log:
        env["SCEN_LOG"] = os.path.abspath(a.log)
    runs = []
    for k in range(a.seeds):
        if a.seeds > 1:
            env["SCEN_SEED"] = str(20261110 + 7919 * k)
        out = subprocess.run(["lua5.1", "tests/test_scenarios.lua", a.spec], cwd=ROOT, env=env, capture_output=True,
                             text=True)
        vals = []
        for m in re.finditer(r"^PRED (\S+) (\d+) ([\d.]+)", out.stdout, re.M):
            vals.append(float(m.group(3)))
            print("%s  %s targets  slot 2 right %s%%" % (m.group(1), m.group(2), m.group(3)))
        runs.append(sum(vals) / len(vals) if vals else 0)
        for line in out.stderr.splitlines():
            if line.startswith("POWER"):
                print(line)
        if out.returncode or "PRED" not in out.stdout:
            break
    os.unlink(f.name)
    if a.seeds > 1:
        print("%s  seeds %d: mean %.1f, lowest %.1f, highest %.1f" % (a.spec, len(runs), sum(runs) / len(runs),
                                                                     min(runs), max(runs)))
    if out.returncode or "PRED" not in out.stdout:
        print(out.stdout[-1500:], out.stderr[-1500:])


if __name__ == "__main__":
    main()
