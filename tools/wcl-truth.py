#!/usr/bin/env python3
"""Resource truth from Warcraft Logs (owner, 2026-11-21: "bring more reality in to this for tightening it up").

Warcraft Logs records, with every cast, the caster's resources at that moment ("classResources": amount, max,
type, cost) - for every resource type: Mana, Energy, Rage, Focus, Runes, Runic Power, Astral Power, Combo Points...
For each spec this saves a few top-ranked fights as a timeline of casts with the true values, so
tools/count-error.lua can replay the addon's own counting against them and measure how far off it is.

Writes data/resource-truth/<spec>.json: [{ "seconds": fight length, "max": {pt: max},
  "casts": [[t, spellID, {pt: amount before the cast}, {pt: cost}], ...] }, ...]
Only spell IDs, times and amounts are kept: no player, guild or report names.

The API token is the session's saved credential for www.warcraftlogs.com (injected by the proxy); nothing here
reads or stores a key.

Usage: python3 tools/wcl-truth.py [--specs rogue_outlaw,druid_balance] [--fights 3] [--zone 53] [--difficulty 4]
"""
import argparse
import glob
import importlib.util
import json
import os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "data", "resource-truth")
DATA = os.path.join(ROOT, "addons", "DMGAssist", "Data", "midnight")

_spec = importlib.util.spec_from_file_location("wcl", os.path.join(os.path.dirname(__file__), "wcl-resources.py"))
wcl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(wcl)


def fight_truth(code, fight, name):
    d = wcl.query("query($c:String!,$f:[Int]){reportData{report(code:$c){fights(fightIDs:$f){startTime endTime}"
                  " masterData{actors(type:\"Player\"){id name}}}}}", {"c": code, "f": [fight]})
    rep = d["reportData"]["report"]
    f = rep["fights"][0]
    ids = [a["id"] for a in rep["masterData"]["actors"] if a["name"] == name]
    if not ids:
        return None
    ev = wcl.events(code, fight, ids[0], "Casts", f["startTime"], f["endTime"], resources=True)
    casts, mx = [], {}
    for e in ev:
        if e.get("type") != "cast" or not e.get("classResources"):
            continue
        have, cost = {}, {}
        for r in e["classResources"]:
            pt = r.get("type")
            if pt is None:
                continue
            have[str(pt)] = r.get("amount", 0)
            mx[str(pt)] = r.get("max", 0)
            if r.get("cost"):
                cost[str(pt)] = r["cost"]
        casts.append([round((e["timestamp"] - f["startTime"]) / 1000.0, 3), e["abilityGameID"], have, cost])
    return {"seconds": (f["endTime"] - f["startTime"]) / 1000.0, "max": mx, "casts": casts}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--specs", default="")
    ap.add_argument("--fights", type=int, default=3)
    ap.add_argument("--zone", type=int, default=53)
    ap.add_argument("--difficulty", type=int, default=4)
    a = ap.parse_args()
    specs = [s for s in a.specs.split(",") if s] or sorted(
        os.path.basename(p)[:-4] for p in glob.glob(os.path.join(DATA, "*_*.lua")))
    os.makedirs(OUT, exist_ok=True)
    for spec in specs:
        out = []
        for code, fight, name in wcl.top_fights(spec, a.zone, a.difficulty, a.fights):
            t = fight_truth(code, fight, name)
            if t and t["casts"]:
                out.append(t)
        with open(os.path.join(OUT, spec + ".json"), "w", encoding="utf-8") as f:
            json.dump(out, f, separators=(",", ":"))
        print(spec, len(out), "fights", sum(len(x["casts"]) for x in out), "casts")


if __name__ == "__main__":
    main()
