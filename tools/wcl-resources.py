#!/usr/bin/env python3
"""Measure every spec's resource gains from public Warcraft Logs reports (owner, 2026-11-14).

For each spec: the top-ranked players on the current raid's bosses, one fight each. From each fight it reads the
player's resource events (every gain, with the ability that caused it) and casts, and adds up per ability:

  - a spell you cast: what it really gives per cast (its most common amount when it gives once per cast, the total
    divided by the casts when it ticks, like Fury of Elune);
  - anything else (Shooting Stars, procs, passive talents): income per second of fight.

Writes data/resource-gains.json, which tools/simc_import.py folds into the spec data: measured gains replace
SimC's where they differ, passive income goes into the record as passiveGain. The addon's tooltip reader and its
in-play calibration still correct the numbers for your own talents on top of this.

Only spell IDs, amounts, counts and durations are kept: no player, guild or report names.

The API token is the session's saved credential for www.warcraftlogs.com (injected by the proxy); nothing here
reads or stores a key.

Usage: python3 tools/wcl-resources.py [--specs druid_balance,rogue_outlaw] [--fights 8] [--zone 53]
       [--difficulty 4]
"""
import argparse
import collections
import datetime
import json
import os
import re
import subprocess
import time
import sys

API = "https://www.warcraftlogs.com/api/v2/client"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "data", "resource-gains.json")
DATA = os.path.join(ROOT, "addons", "DMGAssist", "Data", "midnight")

# our spec keys -> Warcraft Logs class / spec names
CLASS = {"deathknight": "DeathKnight", "demonhunter": "DemonHunter"}
SPEC = {"beast_mastery": "BeastMastery"}
# resources worth measuring (the game's power types); mana, health and the like are left out
POWERS = {1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 16, 17, 18, 19}
MIN_RATE = 0.1  # passive income below this per second is noise (a Balance druid's one bear-form Rage tick)


def query(q, variables=None, tries=6):
    body = json.dumps({"query": q, "variables": variables or {}})
    for attempt in range(tries):
        out = subprocess.run(["curl", "-sS", "--max-time", "60", API, "-H", "Content-Type: application/json",
                              "-d", body], capture_output=True, text=True).stdout
        try:
            d = json.loads(out)
            break
        except ValueError:
            # rate limited or a hiccup: wait (the hourly points come back), then again
            time.sleep(min(600, 30 * 2 ** attempt))
    else:
        raise RuntimeError("no answer from the API")
    if "errors" in d:
        raise RuntimeError(json.dumps(d["errors"])[:300])
    return d["data"]


def wcl_names(spec):
    for cls in sorted(CLASS, key=len, reverse=True) + [None]:
        if cls and spec.startswith(cls + "_"):
            return CLASS[cls], SPEC.get(spec[len(cls) + 1:], spec[len(cls) + 1:].title().replace("_", ""))
    c, _, s = spec.partition("_")
    return c.title(), SPEC.get(s, s.title().replace("_", ""))


def encounters(zone):
    d = query("query($z:Int){worldData{zone(id:$z){encounters{id name}}}}", {"z": zone})
    return [e["id"] for e in d["worldData"]["zone"]["encounters"]]


def top_fights(spec, zone, difficulty, want):
    cls, sp = wcl_names(spec)
    seen, out = set(), []
    for enc in encounters(zone):
        d = query("query($e:Int,$c:String,$s:String,$d:Int){worldData{encounter(id:$e){"
                  "characterRankings(className:$c,specName:$s,difficulty:$d)}}}",
                  {"e": enc, "c": cls, "s": sp, "d": difficulty})
        ranks = (d["worldData"]["encounter"] or {}).get("characterRankings") or {}
        for r in ranks.get("rankings", [])[:3]:
            rep = r.get("report") or {}
            key = (rep.get("code"), rep.get("fightID"))
            if rep.get("code") and key not in seen and r.get("name") not in {x[2] for x in out}:
                seen.add(key)
                out.append((rep["code"], rep["fightID"], r["name"]))
                break
        if len(out) >= want:
            break
    return out


def events(code, fight, source, kind, start, end, resources=False):
    got = []
    while start:
        d = query("query($c:String!,$f:[Int],$s:Int,$st:Float,$en:Float,$t:EventDataType,$r:Boolean){reportData{"
                  "report(code:$c){events(fightIDs:$f,sourceID:$s,dataType:$t,startTime:$st,endTime:$en,"
                  "includeResources:$r){data nextPageTimestamp}}}}",
                  {"c": code, "f": [fight], "s": source, "st": start, "en": end, "t": kind, "r": resources})
        e = d["reportData"]["report"]["events"]
        got += e["data"]
        start = e["nextPageTimestamp"]
    return got


def measure_fight(code, fight, name):
    d = query("query($c:String!,$f:[Int]){reportData{report(code:$c){fights(fightIDs:$f){startTime endTime}"
              " masterData{actors(type:\"Player\"){id name}}}}}", {"c": code, "f": [fight]})
    rep = d["reportData"]["report"]
    f = rep["fights"][0]
    ids = [a["id"] for a in rep["masterData"]["actors"] if a["name"] == name]
    if not ids:
        return None
    src = ids[0]
    res = events(code, fight, src, "Resources", f["startTime"], f["endTime"])
    casts = events(code, fight, src, "Casts", f["startTime"], f["endTime"])
    return {"seconds": (f["endTime"] - f["startTime"]) / 1000.0, "res": res,
            "casts": collections.Counter(e["abilityGameID"] for e in casts if e.get("type") == "cast")}


def spell_ids(spec):
    """Spell IDs our data knows for the spec (the ones you cast), with their tokens."""
    path = os.path.join(DATA, spec + ".lua")
    if not os.path.exists(path):
        return {}
    t = open(path, encoding="utf-8").read()
    i = t.find("spellInfo")
    out = {}
    for m in re.finditer(r"\[(\d+)\] = \{(.*?)\n    \}", t[i:], re.S):
        n = re.search(r'n = "(\w+)"', m.group(2))
        out[int(m.group(1))] = n.group(1) if n else None
    return out


def summarize(fights, known):
    seconds = sum(f["seconds"] for f in fights)
    per = collections.defaultdict(lambda: {"hits": collections.Counter(), "total": 0, "waste": 0})
    casts = collections.Counter()
    for f in fights:
        casts.update(f["casts"])
        for e in f["res"]:
            pt = e.get("resourceChangeType")
            if e.get("type") != "resourcechange" or pt not in POWERS:
                continue
            a = per[(e["abilityGameID"], pt)]
            a["hits"][e.get("resourceChange", 0)] += 1
            a["total"] += e.get("resourceChange", 0)
            a["waste"] += e.get("waste", 0) or 0
    gains, passive, detail = {}, collections.Counter(), []
    for (aid, pt), a in sorted(per.items()):
        hits = sum(a["hits"].values())
        if a["total"] <= 0:
            continue
        n = casts.get(aid, 0)
        row = {"id": aid, "pt": pt, "hits": hits, "total": a["total"], "waste": a["waste"], "casts": n,
               "token": known.get(aid)}
        if aid in known and n > 0 and hits <= 1.2 * n:
            # a spell you cast that gives once per cast: its usual amount
            gain = a["hits"].most_common(1)[0][0]
            gains.setdefault(str(aid), {})[str(pt)] = gain
            row["gain"] = gain
        else:
            # everything else, ticking spells included (Fury of Elune's 30 comes over 8 s): income per second
            passive[pt] += a["total"]
            row["perSecond"] = round(a["total"] / seconds, 3)
        detail.append(row)
    return {"fights": len(fights), "seconds": round(seconds, 1), "gains": gains,
            "passive": {str(pt): round(v / seconds, 3) for pt, v in sorted(passive.items()) if v / seconds >= MIN_RATE},
            "detail": detail}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--specs", help="comma-separated spec keys (default: every spec in Data/midnight)")
    ap.add_argument("--fights", type=int, default=8, help="fights per spec (one per player)")
    ap.add_argument("--zone", type=int, default=53, help="Warcraft Logs zone (53: The Venomous Abyss)")
    ap.add_argument("--difficulty", type=int, default=4, help="3 normal, 4 heroic, 5 mythic")
    args = ap.parse_args()
    specs = args.specs.split(",") if args.specs else sorted(
        f[:-4] for f in os.listdir(DATA) if f.endswith(".lua") and f != "Index.lua")
    out = json.load(open(OUT)) if os.path.exists(OUT) else {}
    out.setdefault("_about", "Measured from public Warcraft Logs reports by tools/wcl-resources.py: per spec, "
                   "gains per cast (gains: spellID -> powerType -> amount) and passive income per second "
                   "(passive: powerType -> per second). No player data is kept.")
    branch = out.setdefault("midnight", {})
    for spec in specs:
        try:
            picks = top_fights(spec, args.zone, args.difficulty, args.fights)
            fights = [m for m in (measure_fight(*p) for p in picks) if m]
        except Exception as e:  # one spec's trouble (no rankings, a timeout) doesn't stop the rest
            print("%-28s skipped: %s" % (spec, e), file=sys.stderr)
            continue
        if not fights:
            print("%-28s no fights" % spec)
            continue
        s = summarize(fights, spell_ids(spec))
        s["updated"] = datetime.date.today().isoformat()
        s["zone"], s["difficulty"] = args.zone, args.difficulty
        branch[spec] = s
        print("%-28s fights=%d gains=%d passive=%s" % (spec, s["fights"], len(s["gains"]), s["passive"]))
        json.dump(out, open(OUT, "w"), indent=1, sort_keys=True)


if __name__ == "__main__":
    main()
