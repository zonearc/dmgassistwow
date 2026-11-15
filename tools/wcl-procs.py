#!/usr/bin/env python3
"""How often each buff of a spec comes up in real fights - the procs the offline game has to roll (owner, 2026-11-15:
"the Warcraft logs can show us how often they generally happen and build a simulator that tried to emulate it").

Per spec, from Warcraft Logs' top raid fights: every buff on the player (Buffs table), its applications per minute
and the share of the fight it was up. Writes data/proc-rates.json { spec: { auraID: { perMin, uptime, fights } } }.
Only spell IDs and numbers are kept: no player, guild or report names.
The API token is the session's saved credential for www.warcraftlogs.com (injected by the proxy).

Usage: python3 tools/wcl-procs.py [--specs a,b] [--fights 3]
"""
import argparse
import collections
import importlib.util
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
_s = importlib.util.spec_from_file_location("wclres", os.path.join(HERE, "wcl-resources.py"))
W = importlib.util.module_from_spec(_s)
_s.loader.exec_module(W)
_c = importlib.util.spec_from_file_location("wclcd", os.path.join(HERE, "wcl-castdelta.py"))
CD = importlib.util.module_from_spec(_c)
_c.loader.exec_module(CD)
OUT = os.path.join(HERE, "..", "data", "proc-rates.json")
SPECS = sorted(set(CD.POWER) | {"mage_fire", "mage_frost", "shaman_enhancement", "druid_feral", "priest_shadow"})


def fight_buffs(code, fight, name):
    d = W.query("query($c:String!,$f:[Int]){reportData{report(code:$c){fights(fightIDs:$f){startTime endTime}"
                " masterData{actors(type:\"Player\"){id name}}}}}", {"c": code, "f": [fight]})
    rep = d["reportData"]["report"]
    f = rep["fights"][0]
    ids = [a["id"] for a in rep["masterData"]["actors"] if a["name"] == name]
    if not ids:
        return None, 0
    t = W.query("query($c:String!,$f:[Int],$s:Int,$st:Float,$en:Float){reportData{report(code:$c){"
                "table(dataType:Buffs,fightIDs:$f,sourceID:$s,startTime:$st,endTime:$en)}}}",
                {"c": code, "f": [fight], "s": ids[0], "st": f["startTime"], "en": f["endTime"]})
    tab = t["reportData"]["report"]["table"]
    data = tab.get("data", tab) if isinstance(tab, dict) else {}
    secs = (f["endTime"] - f["startTime"]) / 1000.0
    return data.get("auras") or [], secs


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--specs", default=",".join(SPECS))
    ap.add_argument("--fights", type=int, default=3)
    a = ap.parse_args()
    out = json.load(open(OUT)) if os.path.exists(OUT) else {}
    for spec in a.specs.split(","):
        uses, up, n = collections.Counter(), collections.Counter(), collections.Counter()
        total = 0.0
        try:
            fights = W.top_fights(spec, 53, 4, a.fights)
        except RuntimeError as err:
            print("== %s: %s" % (spec, err))
            continue
        for code, fight, name in fights:
            try:
                auras, secs = fight_buffs(code, fight, name)
            except RuntimeError as err:
                print("   %s" % err)
                continue
            if not auras or secs <= 0:
                continue
            total += secs
            for x in auras:
                g = x.get("guid")
                if not g:
                    continue
                uses[g] += x.get("totalUses", 0) or 0
                up[g] += (x.get("totalUptime", 0) or 0) / 1000.0
                n[g] += 1
        if total <= 0:
            print("== %s: no fights" % spec)
            continue
        rows = {str(g): {"perMin": round(60.0 * uses[g] / total, 2), "uptime": round(up[g] / total, 3),
                         "fights": n[g]} for g in uses}
        out[spec] = {"seconds": round(total), "auras": rows}
        json.dump(out, open(OUT, "w"), indent=1, sort_keys=True)
        print("== %s: %d auras over %.0f s" % (spec, len(rows), total))
    json.dump(out, open(OUT, "w"), indent=1, sort_keys=True)


if __name__ == "__main__":
    main()
