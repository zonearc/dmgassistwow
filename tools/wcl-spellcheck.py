#!/usr/bin/env python3
"""What each spell really does in top players' fights, against our spec data - every spec at once.

The misunderstandings that cost the most so far were all visible in real casts: spenders often free or cut (Balance's
Starfall), cooldowns cut by spending (Outlaw's Restless Blades: Adrenaline Rush back after 60 s, data 180), extra
charges from talents. Per spec, from Warcraft Logs' top raid fights (the casts with the player's resource):

  - cooldown: the shortest and the typical time between two casts of a spell, against our data's cooldown and
    charges. Cast again sooner than the data allows -> a reduction or a charge we don't know (flag "cd");
  - cost: the average cost paid and how often it was free, against our data's cost (flags "cost", "free");
  - unknown: spells cast often that our data doesn't have at all (flag "missing").

Writes data/spell-check.json and docs/coverage/spell-check.md. Only spell IDs and numbers are kept.
The API token is the session's saved credential for www.warcraftlogs.com (injected by the proxy).

Usage: python3 tools/wcl-spellcheck.py [--specs a,b] [--fights 3]
"""
import argparse
import collections
import importlib.util
import json
import os
import re
import statistics

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")


def load(name, file):
    s = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m


W = load("wclres", "wcl-resources.py")
CD = load("wclcd", "wcl-castdelta.py")
OUT = os.path.join(ROOT, "data", "spell-check.json")
DOC = os.path.join(ROOT, "docs", "coverage", "spell-check.md")
DATA = os.path.join(ROOT, "addons", "DMGAssist", "Data", "midnight")
TENTHS = {1, 6, 7, 8}  # resources Warcraft Logs logs in tenths (Rage, Runic Power, Soul Shards, Astral Power)


def unit(power, mx):
    """how many logged units make one point: Insanity in hundredths (max logged 10000+), Rage / Runic Power /
    Astral Power in tenths (1000+), Soul Shards / Holy Power / combo-type points in tenths (max 5 logged as 50)"""
    if mx >= 5000:
        return 100
    if (power in TENTHS and mx > 100) or mx >= 1000 or (power in SMALL and mx >= 20):
        return 10
    return 1


SMALL = {4, 7, 9, 12, 16, 19}  # resources with a maximum of 5-10


def data_spells(spec):
    t = open(os.path.join(DATA, spec + ".lua"), encoding="utf-8").read()
    i = t.find("spellInfo")
    out = {}
    for m in re.finditer(r"\[(\d+)\] = \{(.*?)\n    \}", t[i:], re.S):
        body = m.group(2)
        row = {}
        n = re.search(r'n = "(\w+)"', body)
        row["n"] = n.group(1) if n else None
        for k in ("cd", "ch", "chcd", "gcd", "ct"):
            v = re.search(r"\n      %s = ([\d.]+)," % k, body)
            if v:
                row[k] = float(v.group(1))
        c = re.search(r"\n      cost = \{([^}]*)\}", body)
        if c:
            row["cost"] = {int(a): float(b) for a, b in re.findall(r"\[(\d+)\] = ([\d.]+)", c.group(1))}
        out[int(m.group(1))] = row
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--specs", default=",".join(sorted(CD.POWER)))
    ap.add_argument("--fights", type=int, default=3)
    a = ap.parse_args()
    out = json.load(open(OUT)) if os.path.exists(OUT) else {}
    for spec in a.specs.split(","):
        power = CD.POWER.get(spec)
        ours = data_spells(spec)
        times = collections.defaultdict(list)  # id -> per fight list of times
        paid = collections.defaultdict(list)
        try:
            fights = W.top_fights(spec, 53, 4, a.fights)
        except RuntimeError as err:
            print("== %s: %s" % (spec, err))
            continue
        nf = 0
        for code, fight, name in fights:
            try:
                casts = CD.fight_rows(code, fight, name, power) if power is not None else None
            except RuntimeError as err:
                print("   %s" % err)
                continue
            if not casts:
                continue
            nf += 1
            per = collections.defaultdict(list)
            for t, sid, amt, cost, mx in casts:
                per[sid].append(t)
                scale = unit(power, mx)
                paid[sid].append(cost / scale)
            for sid, ts in per.items():
                times[sid].append(ts)
        rows = []
        for sid, lists in times.items():
            n = sum(len(x) for x in lists)
            if n < 6:
                continue
            gaps = [b - a for ts in lists for a, b in zip(ts, ts[1:])]
            d = ours.get(sid, {})
            flags = []
            cd = d.get("chcd") or d.get("cd") or 0
            ch = int(d.get("ch") or 1)
            g_min = min(gaps) if gaps else None
            g_med = statistics.median(gaps) if gaps else None
            # cast again sooner than the data's cooldown allows (with its charges: two casts in a row are fine,
            # but then the typical gap can't be under the cooldown)
            if cd >= 6 and gaps:
                if ch <= 1 and g_min < 0.85 * cd:
                    flags.append("cd")
                elif ch > 1 and g_med < 0.85 * cd / ch:
                    flags.append("cd")
            costs = paid.get(sid, [])
            dc = (d.get("cost") or {}).get(power, 0) if power is not None else 0
            avg = sum(costs) / len(costs) if costs else 0
            free = sum(1 for c in costs if c == 0) / len(costs) if costs and dc else 0
            if dc and avg and abs(avg - dc) >= max(1, 0.1 * dc):
                flags.append("cost")
            if dc and free >= 0.1:
                flags.append("free")
            if sid not in ours:
                flags.append("missing")
            rows.append({"id": sid, "token": d.get("n"), "casts": n, "gapMin": g_min and round(g_min, 1),
                         "gapMed": g_med and round(g_med, 1), "cd": cd, "charges": ch, "paid": round(avg, 1),
                         "cost": dc, "free": round(free, 2), "flags": flags})
        rows.sort(key=lambda r: -r["casts"])
        out[spec] = {"fights": nf, "spells": rows}
        json.dump(out, open(OUT, "w"), indent=1, sort_keys=True)
        print("== %s: %d fights" % (spec, nf))
        for r in rows:
            if r["flags"]:
                print("   %-28s %4d casts  gap min %-5s med %-5s cd %-5g x%d  paid %-5g cost %-4g free %3d%%  %s" % (
                    r["token"] or r["id"], r["casts"], r["gapMin"], r["gapMed"], r["cd"], r["charges"], r["paid"],
                    r["cost"], 100 * r["free"], "/".join(r["flags"])))
    write_doc(out)


def write_doc(out):
    lines = ["# Spell check: top players' casts vs our data", "",
             "Generated by tools/wcl-spellcheck.py. Flags: cd = cast again sooner than our cooldown/charges allow "
             "(a reduction or charge we don't model); cost = average paid differs from our cost; free = free 10%+ "
             "of the time; missing = cast often, not in our data.", ""]
    for spec in sorted(out):
        flagged = [r for r in out[spec]["spells"] if r["flags"]]
        lines.append("## %s (%d fights, %d flagged)" % (spec, out[spec]["fights"], len(flagged)))
        lines.append("")
        if flagged:
            lines.append("| spell | casts | gap min | gap median | cd | charges | paid | cost | free | flags |")
            lines.append("|---|---|---|---|---|---|---|---|---|---|")
            for r in flagged:
                lines.append("| %s | %d | %s | %s | %g | %d | %g | %g | %d%% | %s |" % (
                    r["token"] or r["id"], r["casts"], r["gapMin"], r["gapMed"], r["cd"], r["charges"], r["paid"],
                    r["cost"], 100 * r["free"], " ".join(r["flags"])))
            lines.append("")
    os.makedirs(os.path.dirname(DOC), exist_ok=True)
    open(DOC, "w").write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
