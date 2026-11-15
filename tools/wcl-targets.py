#!/usr/bin/env python3
"""Resource gains by number of targets, from Warcraft Logs' Dummy Dome (owner, 2026-11-15: "can't we guesstimate
the astral power generation ... I thought all the combat logs at warcraft logs would help us").

Dummy Dome is a zone of target-dummy fights with a fixed number of targets: Sinister Single (1), Diabolical Duo (2),
Terrible Trio (3), Fearsome Five (5). For each, the top-ranked players of a spec, one fight each: every resource
gain with the ability that caused it, and every cast. Per target count it prints, per ability:

  - a spell you cast: its gain per cast (most common amount, and the average);
  - anything else (Shooting Stars from damage over time, procs, ticking spells): income per second;

and the resource spenders' average cost actually paid per cast (free procs and cost cuts included).

Writes data/resource-targets.json: { spec: { targets: { gains, perSecond, spent } } }. The addon's in-play fit
(Calibrate section 3) starts from what the logs say for your target count and corrects for your talents.

Only spell IDs, amounts, counts and durations are kept: no player, guild or report names.
The API token is the session's saved credential for www.warcraftlogs.com (injected by the proxy).

Usage: python3 tools/wcl-targets.py [--specs druid_balance] [--fights 6]
"""
import argparse
import collections
import importlib.util
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
spec_ = importlib.util.spec_from_file_location("wclres", os.path.join(HERE, "wcl-resources.py"))
W = importlib.util.module_from_spec(spec_)
spec_.loader.exec_module(W)

ZONE = 52
TARGETS = {3591: 1, 3590: 2, 3592: 3, 3593: 5}
OUT = os.path.join(HERE, "..", "data", "resource-targets.json")
# each spec's resource hidden in combat that it builds and spends (Midnight power types)
POWER = {"druid_balance": 8, "druid_guardian": 1, "warrior_arms": 1, "warrior_fury": 1, "warrior_protection": 1,
         "deathknight_blood": 6, "deathknight_frost": 6, "deathknight_unholy": 6, "demonhunter_havoc": 17,
         "demonhunter_vengeance": 17, "demonhunter_devourer": 17, "priest_shadow": 13, "shaman_elemental": 11,
         "shaman_enhancement": 11, "hunter_beast_mastery": 2, "hunter_marksmanship": 2, "hunter_survival": 2,
         "rogue_assassination": 3, "rogue_outlaw": 3, "rogue_subtlety": 3, "druid_feral": 3, "monk_windwalker": 3,
         "monk_brewmaster": 3}


def find_fights(spec, want, pages=10):
    """Dummy Dome has no rankings: recent reports in the zone, the spec's player in each (by its icon,
    "Druid-Balance"), one fight per player and target count. -> { encounterID: [(code, fight, name)] }"""
    cls, sp = W.wcl_names(spec)
    icon = cls + "-" + sp
    found = collections.defaultdict(list)
    names = collections.defaultdict(set)
    for page in range(1, pages + 1):
        d = W.query("query($z:Int,$p:Int){reportData{reports(zoneID:$z,limit:50,page:$p){data{code "
                    "fights{id encounterID friendlyPlayers} masterData{actors(type:\"Player\"){id name icon}}}}}}",
                    {"z": ZONE, "p": page})
        reports = d["reportData"]["reports"]["data"]
        if not reports:
            break
        for rep in reports:
            players = [x for x in (rep.get("masterData") or {}).get("actors") or [] if x.get("icon") == icon]
            for pl in players[:1]:
                for f in rep.get("fights") or []:
                    enc = f.get("encounterID")
                    # (only a fight the player was in: one picked from the whole report came back empty for the
                    # 5-target dummies)
                    if pl["id"] not in (f.get("friendlyPlayers") or []):
                        continue
                    if enc in TARGETS and len(found[enc]) < want and pl["name"] not in names[enc]:
                        names[enc].add(pl["name"])
                        found[enc].append((rep["code"], f["id"], pl["name"]))
                        break
        if all(len(found[e]) >= want for e in TARGETS):
            break
    return found


def measure(fights, known, power):
    seconds = sum(f["seconds"] for f in fights)
    casts = collections.Counter()
    gains = collections.defaultdict(collections.Counter)
    totals = collections.Counter()
    spent = collections.Counter()
    for f in fights:
        casts.update(f["casts"])
        for e in f["res"]:
            if e.get("type") != "resourcechange" or e.get("resourceChangeType") != power:
                continue
            aid = e["abilityGameID"]
            gains[aid][e.get("resourceChange", 0)] += 1
            totals[aid] += e.get("resourceChange", 0)
        for c in f.get("costs", []):
            spent[c[0]] += c[1]
    per_cast, per_second = {}, {}
    for aid, t in totals.items():
        hits = sum(gains[aid].values())
        n = casts.get(aid, 0)
        if aid in known and n > 0 and hits <= 1.2 * n:
            per_cast[aid] = {"usual": gains[aid].most_common(1)[0][0], "avg": round(t / n, 1), "casts": n,
                             "token": known.get(aid)}
        elif t > 0:
            per_second[aid] = {"rate": round(t / seconds, 2), "token": known.get(aid), "hits": hits}
    paid = {aid: {"avg": round(v / casts[aid], 1), "casts": casts[aid], "token": known.get(aid)}
            for aid, v in spent.items() if casts.get(aid)}
    return {"fights": len(fights), "seconds": round(seconds, 1), "gains": per_cast, "perSecond": per_second,
            "spent": paid}


def cast_costs(code, fight, src, start, end, power):
    """what each cast actually paid: the cast events carry the class resources with their cost"""
    out = []
    for e in W.events(code, fight, src, "Casts", start, end, resources=True):
        if e.get("type") != "cast":
            continue
        for r in e.get("classResources") or []:
            if r.get("type") == power:
                out.append((e["abilityGameID"], r.get("cost", 0) or 0))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--specs", default="druid_balance")
    ap.add_argument("--fights", type=int, default=6)
    ap.add_argument("--power", type=int, default=8)
    a = ap.parse_args()
    out = json.load(open(OUT)) if os.path.exists(OUT) else {}
    for spec in a.specs.split(","):
        known = W.spell_ids(spec)
        a.power = POWER.get(spec, 8)
        result = {}
        try:
            found = find_fights(spec, a.fights)
        except RuntimeError as err:
            print("== %s: %s" % (spec, err))
            continue
        for enc, n in TARGETS.items():
            fights = []
            for code, fight, name in found.get(enc, []):
                m = W.measure_fight(code, fight, name)
                if not m:
                    continue
                d = W.query("query($c:String!,$f:[Int]){reportData{report(code:$c){fights(fightIDs:$f){startTime "
                            "endTime} masterData{actors(type:\"Player\"){id name}}}}}", {"c": code, "f": [fight]})
                rep = d["reportData"]["report"]
                f = rep["fights"][0]
                src = [x["id"] for x in rep["masterData"]["actors"] if x["name"] == name][0]
                m["costs"] = cast_costs(code, fight, src, f["startTime"], f["endTime"], a.power)
                fights.append(m)
            if not fights:
                continue
            r = measure(fights, known, a.power)
            result[str(n)] = r
            print("== %s, %d target%s: %d fights, %.0f s" % (spec, n, "" if n == 1 else "s", r["fights"],
                                                              r["seconds"]))
            for aid, g in sorted(r["gains"].items(), key=lambda x: -x[1]["casts"]):
                print("   %-22s per cast: usual %+d, average %+.1f (%d casts)" % (g["token"] or aid, g["usual"],
                                                                                  g["avg"], g["casts"]))
            for aid, g in sorted(r["perSecond"].items(), key=lambda x: -x[1]["rate"]):
                print("   %-22s per second: %+.2f" % (g["token"] or aid, g["rate"]))
            for aid, g in sorted(r["spent"].items(), key=lambda x: -x[1]["casts"]):
                if g["avg"] > 0 or g["casts"] > 5:
                    print("   %-22s paid per cast: %.1f (%d casts)" % (g["token"] or aid, g["avg"], g["casts"]))
        if result:
            out[spec] = result
            json.dump(out, open(OUT, "w"), indent=1, sort_keys=True)  # (each spec saved as it is done)
    json.dump(out, open(OUT, "w"), indent=1, sort_keys=True)
    write_lua(out, a.power)


LUA = os.path.join(HERE, "..", "addons", "DMGAssist", "Data", "ResourceTargets.lua")


def write_lua(out, power):
    """Data/ResourceTargets.lua: per spec, the income a second that comes with no cast of its own (procs from
    damage over time, ticking spells), by number of targets - State.PassiveGain uses it for your target count."""
    lines = ["-- Generated by tools/wcl-targets.py from Warcraft Logs' Dummy Dome (1, 2, 3, 5 targets). Do not edit:",
             "-- run the tool again. Per spec: power type -> targets -> income a second with no cast of its own.",
             "local _, ns = ...", "ns.Data = ns.Data or {}", "ns.Data.resourceTargets = {"]
    for spec in sorted(out):
        rows = []
        for n in sorted(out[spec], key=int):
            r = out[spec][n]
            if r.get("seconds", 0) >= 200 and r.get("perSecond"):
                rows.append("[%d] = %.2f" % (int(n), sum(v["rate"] for v in r["perSecond"].values())))
        if rows:
            lines.append("  %s = { [%d] = { %s } }," % (spec, POWER.get(spec, power), ", ".join(rows)))
    lines.append("}")
    open(LUA, "w").write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
