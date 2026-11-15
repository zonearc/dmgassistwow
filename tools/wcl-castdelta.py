#!/usr/bin/env python3
"""Every spec's resource, per spell, from what the game logged at each cast - compared with our data.

Balance taught (owner, 2026-11-15): the data can be wrong in ways no single fight shows - spenders often free or cut
(procs), builders building more or less than the data says, income by the second nobody modeled. Some resources
aren't logged as gain events at all (Soul Shards, Essence: tools/wcl-resources.py measured nothing for
Destruction or the Evokers). But every cast event carries the player's resource amount and the cost paid
(includeResources). So, per player and fight: between two casts the amount moves by what the first cast gained,
less what the second cast paid, plus income over the time between. Least squares over all casts gives each spell's
real gain per cast and the income a second; the costs are read directly (average paid, how often free).

Prints per spec the spells where real and data differ (gain or cost), writes data/resource-castdelta.json and
docs/coverage/resource-check.md. Only spell IDs and numbers are kept: no player, guild or report names.
The API token is the session's saved credential for www.warcraftlogs.com (injected by the proxy).

Usage: python3 tools/wcl-castdelta.py [--specs warlock_destruction,...] [--fights 4] [--zone 53]
"""
import argparse
import collections
import importlib.util
import json
import os
import re

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
_s = importlib.util.spec_from_file_location("wclres", os.path.join(HERE, "wcl-resources.py"))
W = importlib.util.module_from_spec(_s)
_s.loader.exec_module(W)
ROOT = os.path.join(HERE, "..")
OUT = os.path.join(ROOT, "data", "resource-castdelta.json")
DOC = os.path.join(ROOT, "docs", "coverage", "resource-check.md")
DATA = os.path.join(ROOT, "addons", "DMGAssist", "Data", "midnight")

# each spec's resource worth checking (Midnight power types); healers' mana and the mages' (no resource) left out
POWER = {"druid_balance": 8, "druid_guardian": 1, "druid_feral": 3, "warrior_arms": 1, "warrior_fury": 1,
         "warrior_protection": 1, "deathknight_blood": 6, "deathknight_frost": 6, "deathknight_unholy": 6,
         "demonhunter_havoc": 17, "demonhunter_vengeance": 17, "demonhunter_devourer": 17, "priest_shadow": 13,
         "shaman_elemental": 11, "hunter_beast_mastery": 2, "hunter_marksmanship": 2, "hunter_survival": 2,
         "rogue_assassination": 3, "rogue_outlaw": 3, "rogue_subtlety": 3, "monk_windwalker": 3,
         "monk_brewmaster": 3, "warlock_destruction": 7, "warlock_affliction": 7, "warlock_demonology": 7,
         "evoker_devastation": 19, "evoker_augmentation": 19, "paladin_retribution": 9, "paladin_protection": 9,
         "mage_arcane": 0}
# logged in finer units than the game shows: Soul Shards in tenths
SCALE = {7: 10}


def data_spells(spec):
    """our data: spellID -> {n, cost {pt: v}, gain {pt: v}}"""
    path = os.path.join(DATA, spec + ".lua")
    t = open(path, encoding="utf-8").read()
    i = t.find("spellInfo")
    out = {}
    for m in re.finditer(r"\[(\d+)\] = \{(.*?)\n    \}", t[i:], re.S):
        body = m.group(2)
        n = re.search(r'n = "(\w+)"', body)
        row = {"n": n.group(1) if n else None}
        for key in ("cost", "gain"):
            g = re.search(r"\n      %s = \{([^}]*)\}" % key, body)
            if g:
                row[key] = {int(a): float(b) for a, b in re.findall(r"\[(\d+)\] = ([\d.]+)", g.group(1))}
        out[int(m.group(1))] = row
    return out


def fight_rows(code, fight, name, power):
    d = W.query("query($c:String!,$f:[Int]){reportData{report(code:$c){fights(fightIDs:$f){startTime endTime}"
                " masterData{actors(type:\"Player\"){id name}}}}}", {"c": code, "f": [fight]})
    rep = d["reportData"]["report"]
    f = rep["fights"][0]
    ids = [a["id"] for a in rep["masterData"]["actors"] if a["name"] == name]
    if not ids:
        return None
    casts = []
    for e in W.events(code, fight, ids[0], "Casts", f["startTime"], f["endTime"], resources=True):
        if e.get("type") != "cast":
            continue
        r = next((r for r in e.get("classResources") or [] if r.get("type") == power), None)
        if r is None:
            continue
        casts.append((e["timestamp"] / 1000.0, e["abilityGameID"], r.get("amount", 0), r.get("cost", 0) or 0,
                      r.get("max", 0)))
    return casts


def fit(all_casts, scale):
    """rows: amount[i+1] - amount[i] = gain(spell i) - paid(i+1)... the amount logged is before the cast's cost,
    after earlier casts: delta_i = amount[i+1] - (amount[i] - cost[i]) = gain(spell i) + rate * dt (capped casts
    dropped: at the maximum, a gain is lost)."""
    rows, y, spells = [], [], set()
    for casts in all_casts:
        for a, b in zip(casts, casts[1:]):
            t0, sid, amt, cost, mx = a
            t1, _, amt1, _, _ = b
            dt = t1 - t0
            if dt <= 0 or dt > 6 or (mx and amt1 >= mx):
                continue
            rows.append((sid, dt))
            y.append((amt1 - (amt - cost)) / scale)
            spells.add(sid)
    spells = sorted(spells)
    if len(rows) < 20:
        return None
    idx = {s: i for i, s in enumerate(spells)}
    X = np.zeros((len(rows), len(spells) + 1))
    for k, (sid, dt) in enumerate(rows):
        X[k, idx[sid]] = 1
        X[k, -1] = dt
    w, *_ = np.linalg.lstsq(X, np.array(y), rcond=None)
    counts = collections.Counter(s for s, _ in rows)
    return {"rate": float(w[-1]), "gain": {s: float(w[idx[s]]) for s in spells}, "n": counts}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--specs", default=",".join(sorted(POWER)))
    ap.add_argument("--fights", type=int, default=4)
    ap.add_argument("--zone", type=int, default=53)
    ap.add_argument("--difficulty", type=int, default=4)
    a = ap.parse_args()
    out = json.load(open(OUT)) if os.path.exists(OUT) else {}
    for spec in a.specs.split(","):
        power = POWER.get(spec)
        if power is None:
            continue
        scale = SCALE.get(power, 1)
        ours = data_spells(spec)
        all_casts, paid = [], collections.defaultdict(list)
        try:
            for code, fight, name in W.top_fights(spec, a.zone, a.difficulty, a.fights):
                casts = fight_rows(code, fight, name, power)
                if casts:
                    all_casts.append(casts)
                    for _, sid, _, cost, _ in casts:
                        paid[sid].append(cost / scale)
        except RuntimeError as err:
            print("== %s: %s" % (spec, err))
            continue
        r = fit(all_casts, scale)
        if not r:
            print("== %s: too few casts" % spec)
            continue
        rows = []
        for sid, g in sorted(r["gain"].items(), key=lambda kv: -r["n"][kv[0]]):
            n = r["n"][sid]
            if n < 8:
                continue
            d = ours.get(sid, {})
            dg = (d.get("gain") or {}).get(power, 0)
            dc = (d.get("cost") or {}).get(power, 0)
            costs = paid.get(sid, [])
            avg_cost = sum(costs) / len(costs) if costs else 0
            free = sum(1 for c in costs if c == 0) / len(costs) if costs and dc else 0
            flag = []
            if abs(g - dg) >= max(1.5, 0.25 * max(dg, 1)) and (dg or g >= 1):
                flag.append("gain")
            if dc and abs(avg_cost - dc) >= max(1, 0.1 * dc):
                flag.append("cost")
            rows.append({"id": sid, "token": d.get("n"), "casts": n, "gain": round(g, 1), "dataGain": dg,
                         "paid": round(avg_cost, 1), "dataCost": dc, "free": round(free, 2), "flag": flag})
        out[spec] = {"power": power, "rate": round(r["rate"], 2), "fights": len(all_casts), "spells": rows}
        print("== %s (power %d): %d fights, income by the second %+.2f" % (spec, power, len(all_casts), r["rate"]))
        for row in rows:
            if row["flag"]:
                print("   %-26s gain %+.1f (data %+g)   paid %.1f (data %g, free %d%%)  %s" % (
                    row["token"] or row["id"], row["gain"], row["dataGain"], row["paid"], row["dataCost"],
                    100 * row["free"], "/".join(row["flag"])))
    json.dump(out, open(OUT, "w"), indent=1, sort_keys=True)
    write_doc(out)


def write_doc(out):
    lines = ["# Resource check: real fights vs our data", "",
             "Generated by tools/wcl-castdelta.py from top Warcraft Logs players' casts (resource amount and cost at "
             "each cast). Per spec: each spell's real gain per cast (least squares over the amount between casts) "
             "and average cost paid, against the spec data. Flagged rows differ by 25%+ (gain) or 10%+ (cost).", ""]
    for spec in sorted(out):
        o = out[spec]
        flagged = [r for r in o["spells"] if r["flag"]]
        lines.append("## %s - power %d, %d fights, income by the second %+.2f, %d of %d spells differ" % (
            spec, o["power"], o["fights"], o["rate"], len(flagged), len(o["spells"])))
        lines.append("")
        if flagged:
            lines.append("| spell | casts | real gain | data gain | paid | data cost | free |")
            lines.append("|---|---|---|---|---|---|---|")
            for r in flagged:
                lines.append("| %s | %d | %+.1f | %+g | %.1f | %g | %d%% |" % (
                    r["token"] or r["id"], r["casts"], r["gain"], r["dataGain"], r["paid"], r["dataCost"],
                    100 * r["free"]))
            lines.append("")
    os.makedirs(os.path.dirname(DOC), exist_ok=True)
    open(DOC, "w").write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
