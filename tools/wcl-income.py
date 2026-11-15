#!/usr/bin/env python3
"""Total resource income per second from the casts' logged amounts, by number of targets (Dummy Dome).

Some income is never logged as a resource event: a Warrior's Rage from auto-attacks (tools/wcl-targets.py saw only
talent procs for Arms, under 1/s, while the spec lives on its swings). Every cast still logs the player's resource
and what the cast cost, so over a fight: income = everything paid + (last amount - first amount), per second.
Printed beside what our data would give for the same casts (gains per cast) plus its passive income, so the gap is
what the data misses. Only numbers are kept.

Usage: python3 tools/wcl-income.py --specs warrior_arms,warrior_fury [--fights 3]
"""
import argparse
import collections
import importlib.util
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, file):
    s = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m


W = load("wclres", "wcl-resources.py")
T = load("wcltargets", "wcl-targets.py")
CD = load("wclcd", "wcl-castdelta.py")
OUT = os.path.join(HERE, "..", "data", "resource-income.json")
SCALE = {1: 10, 6: 10, 8: 10, 7: 10, 17: 1, 13: 1, 11: 1}  # logged in tenths for these (Rage, Runic Power, ...)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--specs", default="warrior_arms")
    ap.add_argument("--fights", type=int, default=3)
    ap.add_argument("--raid", action="store_true", help="also raid boss fights (zone 53, heroic) as 'raid'")
    a = ap.parse_args()
    out = json.load(open(OUT)) if os.path.exists(OUT) else {}
    for spec in a.specs.split(","):
        power = CD.POWER[spec]
        ours = CD.data_spells(spec)
        passive = 0.0
        g = json.load(open(os.path.join(HERE, "..", "data", "resource-gains.json")))["midnight"].get(spec, {})
        passive = float(g.get("passive", {}).get(str(power), 0))
        found = T.find_fights(spec, a.fights)
        targets = dict(T.TARGETS)
        if a.raid:
            found["raid"] = W.top_fights(spec, 53, 4, a.fights)
            targets["raid"] = "raid"
        res = {}
        for enc, n in targets.items():
            tot_in = tot_model = secs = 0.0
            fights = 0
            for code, fight, name in found.get(enc, []):
                casts = CD.fight_rows(code, fight, name, power)
                if not casts or len(casts) < 20:
                    continue
                scale = SCALE.get(power, 1)
                # is the logged amount in tenths? (a max over 100 means so)
                if max(c[4] for c in casts) <= 100:
                    scale = 1
                paid = sum(c[3] for c in casts) / scale
                dur = casts[-1][0] - casts[0][0]
                if dur < 30:
                    continue
                income = paid + (casts[-1][2] - casts[0][2]) / scale
                model = sum((ours.get(c[1], {}).get("gain") or {}).get(power, 0) for c in casts[:-1])
                tot_in += income
                tot_model += model + passive * dur
                secs += dur
                fights += 1
            if secs:
                res[str(n)] = {"fights": fights, "seconds": round(secs), "income": round(tot_in / secs, 2),
                               "model": round(tot_model / secs, 2)}
                print("== %s %s target(s): %d fights %.0f s - real income %.2f/s, our data %.2f/s" % (
                    spec, n, fights, secs, tot_in / secs, tot_model / secs))
        out[spec] = res
        json.dump(out, open(OUT, "w"), indent=1, sort_keys=True)


if __name__ == "__main__":
    main()
