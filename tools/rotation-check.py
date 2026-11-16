#!/usr/bin/env python3
"""Does the offline rotation look like real play? Slot 2's accuracy alone rewards a predictable rotation even when it
is wrong (offline Blood pressed Marrowrend 31 times in two minutes and never Heart Strike, and slot 2 scored well:
2026-11-16). Per spec: the share of each spell in the offline casts (one target, tools/sim.py's fights) against the
share in top players' raid fights (data/spell-check.json, tools/wcl-spellcheck.py). Match = the overlap of the two
mixes (1.0 = the same), and the spells most over / under used.

Usage: python3 tools/rotation-check.py [spec ...]   (default: every spec with real casts)
"""
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")


def sim_casts(spec, fight=120):
    s = importlib.util.spec_from_file_location("grade", os.path.join(HERE, "grade.py"))
    g = importlib.util.module_from_spec(s)
    s.loader.exec_module(g)
    refs = {spec: json.load(open(os.path.join(ROOT, "data", "reference", spec + ".json")))}
    f = tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False)
    f.write(g.talents_file(refs))
    f.close()
    env = dict(os.environ, SCEN_GRADE=f.name, SCEN_FIGHT=str(fight), SCEN_TARGETS="1,1", SCEN_HUMAN="1")
    out = subprocess.run(["lua5.1", "tests/test_scenarios.lua", spec], cwd=ROOT, env=env, capture_output=True,
                         text=True).stdout
    os.unlink(f.name)
    casts = {}
    for line in re.findall(r"^GRADE .*$", out, re.M):
        for tok, n in re.findall(r"(\w+)=(\d+)", line.split(" ", 5)[-1]):
            if tok not in ("errors", "procs"):
                casts[tok] = casts.get(tok, 0) + int(n)
    return casts


def mix(d):
    total = sum(d.values()) or 1
    return {k: v / total for k, v in d.items()}


def main():
    real_all = json.load(open(os.path.join(ROOT, "data", "spell-check.json")))
    specs = sys.argv[1:] or sorted(real_all)
    rows = []
    for spec in specs:
        if not os.path.exists(os.path.join(ROOT, "data", "reference", spec + ".json")):
            continue
        real = {}
        for r in real_all.get(spec, {}).get("spells", []):
            if r.get("token"):
                real[r["token"]] = real.get(r["token"], 0) + r["casts"]
        if not real:
            continue
        sim = sim_casts(spec)
        a, b = mix(real), mix(sim)
        match = sum(min(a.get(k, 0), b.get(k, 0)) for k in set(a) | set(b))
        diff = sorted(((b.get(k, 0) - a.get(k, 0), k) for k in set(a) | set(b)), key=lambda x: -abs(x[0]))[:4]
        rows.append((match, spec, diff))
        print("%-24s match %.2f   %s" % (spec, match, "  ".join("%s %+.0f%%" % (k, 100 * d) for d, k in diff)),
              flush=True)
    if rows:
        print("AVERAGE match %.2f" % (sum(r[0] for r in rows) / len(rows)))


if __name__ == "__main__":
    main()
