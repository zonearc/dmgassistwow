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
    a = ap.parse_args()
    spec_ = importlib.util.spec_from_file_location("grade", os.path.join(HERE, "grade.py"))
    g = importlib.util.module_from_spec(spec_)
    spec_.loader.exec_module(g)
    refs = {a.spec: json.load(open(os.path.join(ROOT, "data", "reference", a.spec + ".json")))}
    f = tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False)
    f.write(g.talents_file(refs))
    f.close()
    env = dict(os.environ, SCEN_GRADE=f.name, SCEN_FIGHT=str(a.fight), SCEN_TARGETS=a.targets)
    if a.log:
        env["SCEN_LOG"] = os.path.abspath(a.log)
    out = subprocess.run(["lua5.1", "tests/test_scenarios.lua", a.spec], cwd=ROOT, env=env, capture_output=True,
                         text=True)
    os.unlink(f.name)
    for m in re.finditer(r"^PRED (\S+) (\d+) ([\d.]+)", out.stdout, re.M):
        print("%s  %s targets  slot 2 right %s%%" % (m.group(1), m.group(2), m.group(3)))
    if out.returncode or "PRED" not in out.stdout:
        print(out.stdout[-1500:], out.stderr[-1500:])


if __name__ == "__main__":
    main()
