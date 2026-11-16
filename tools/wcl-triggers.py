#!/usr/bin/env python3
"""What makes each proc happen, and what each proc resets - from top players' real fights (owner, 2026-11-16: "make
the procs work like the ones in game where me casting x spell makes clearcasting proc ... same with resets").

Per spec, from Warcraft Logs' top raid fights (the player's casts and the buffs they applied):

  - procs: each application of a buff is put on the cast just before it (within WINDOW s). Per cast spell: the chance
    one cast brings the buff (Shred -> Clearcasting). What no cast explains (auto-attacks, damage over time) is a
    background rate per second;
  - resets: a spell cast again sooner than SHARE of its cooldown (our data) - which buff came up between the two
    casts? A buff found before most of those early casts resets the spell (Gore -> Mangle).

Writes data/proc-triggers.json { spec: { procs: { aura: { bg, by: { castID: chance }, n } }, resets: { aura: [ids] } } }.
Only spell IDs and numbers are kept: no player, guild or report names.
The API token is the session's saved credential for www.warcraftlogs.com (injected by the proxy).
Usage: python3 tools/wcl-triggers.py [--specs a,b] [--fights 3]
"""
import argparse
import collections
import importlib.util
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")


def load(name, file):
    s = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m


W = load("wclres", "wcl-resources.py")
OUT = os.path.join(ROOT, "data", "proc-triggers.json")
DATA = os.path.join(ROOT, "addons", "DMGAssist", "Data", "midnight")
WINDOW = 0.35   # s from a cast to the buff it brought (same server batch, usually the same timestamp)
SHARE = 0.7     # cast again before 70% of the data's cooldown: early
APPLY = ("applybuff", "refreshbuff", "applybuffstack")


def data_cd(spec):
    t = open(os.path.join(DATA, spec + ".lua"), encoding="utf-8").read()
    i = t.find("spellInfo = {")
    out = {}
    for sid, body in re.findall(r"\n    \[(\d+)\] = \{(.*?)\n    \},", t[i:], re.S):
        cd = re.search(r"\n      (?:chcd|cd) = ([\d.]+),", body)
        ch = re.search(r"\n      ch = (\d+),", body)
        if cd and float(cd.group(1)) >= 4:
            out[int(sid)] = (float(cd.group(1)), int(ch.group(1)) if ch else 1)
    return out


def fight(code, fid, name):
    d = W.query("query($c:String!,$f:[Int]){reportData{report(code:$c){fights(fightIDs:$f){startTime endTime}"
                " masterData{actors(type:\"Player\"){id name}}}}}", {"c": code, "f": [fid]})
    rep = d["reportData"]["report"]
    f = rep["fights"][0]
    ids = [a["id"] for a in rep["masterData"]["actors"] if a["name"] == name]
    if not ids:
        return None
    me = ids[0]
    casts = [(e["timestamp"] / 1000.0, e["abilityGameID"])
             for e in W.events(code, fid, me, "Casts", f["startTime"], f["endTime"]) if e.get("type") == "cast"]
    buffs = [(e["timestamp"] / 1000.0, e["abilityGameID"])
             for e in W.events(code, fid, me, "Buffs", f["startTime"], f["endTime"])
             if e.get("type") in APPLY and e.get("targetID") == me]
    return casts, buffs, (f["endTime"] - f["startTime"]) / 1000.0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--specs", required=True)
    ap.add_argument("--fights", type=int, default=3)
    a = ap.parse_args()
    out = json.load(open(OUT)) if os.path.exists(OUT) else {}
    for spec in a.specs.split(","):
        if not os.path.exists(os.path.join(DATA, spec + ".lua")):
            continue
        cds = data_cd(spec)
        ncast = collections.Counter()
        by = collections.defaultdict(collections.Counter)  # aura -> cast id -> applications after it
        bg = collections.Counter()
        early, ontime = collections.Counter(), collections.Counter()
        before = collections.defaultdict(collections.Counter)  # spell -> aura seen before its early casts
        before_ok = collections.defaultdict(collections.Counter)  # ... before its on-time casts
        secs = 0.0
        try:
            fights = W.top_fights(spec, 53, 4, a.fights)
        except RuntimeError as err:
            print("== %s: %s" % (spec, err))
            continue
        for code, fid, name in fights:
            try:
                got = fight(code, fid, name)
            except RuntimeError as err:
                print("   %s" % err)
                continue
            if not got:
                continue
            casts, buffs, s = got
            secs += s
            castIDs = {c[1] for c in casts}
            for _, cid in casts:
                ncast[cid] += 1
            j = 0
            for t, aura in buffs:
                if aura in castIDs:
                    continue  # a buff you cast yourself
                while j + 1 < len(casts) and casts[j + 1][0] <= t:
                    j += 1
                if casts and casts[j][0] <= t and t - casts[j][0] <= WINDOW:
                    by[aura][casts[j][1]] += 1
                else:
                    bg[aura] += 1
            last = {}
            for t, cid in casts:
                if cid in cds and cid in last:
                    cd, ch = cds[cid]
                    if ch <= 1:
                        # the buffs that came up between the two casts (within the cooldown's span)
                        lo = max(last[cid], t - SHARE * cd)
                        seen = {aura for bt, aura in buffs if lo < bt <= t and aura not in castIDs}
                        if t - last[cid] < SHARE * cd:
                            early[cid] += 1
                            for aura in seen:
                                before[cid][aura] += 1
                        else:
                            ontime[cid] += 1
                            for aura in seen:
                                before_ok[cid][aura] += 1
                last[cid] = t
        if secs <= 0:
            print("== %s: no fights" % spec)
            continue
        procs = {}
        for aura in set(by) | set(bg):
            chances = {str(c): round(n / ncast[c], 3) for c, n in by[aura].items() if ncast[c] >= 5 and n >= 3}
            total = sum(by[aura].values()) + bg[aura]
            if total < 4:
                continue
            procs[str(aura)] = {"bg": round(bg[aura] / secs, 4), "by": chances, "n": total}
        resets = collections.defaultdict(list)
        for cid, n in early.items():
            if n < 5:
                continue
            # before most early casts, and clearly more often than before on-time ones (Clearcasting is up so often
            # it comes before nearly every cast: it "explained" Feral Frenzy's early casts without resetting it)
            for aura, k in before[cid].most_common(3):
                ok_share = before_ok[cid][aura] / ontime[cid] if ontime[cid] else 0
                if k >= 0.6 * n and k / n >= 2 * ok_share:
                    resets[str(aura)].append(cid)
                    break
        # the candidates, for tools/build-procs.py to weigh with the game data (an aura that acts on the spell)
        cand = {}
        for cid, n in early.items():
            if n >= 5:
                cand[str(cid)] = {str(aura): [round(k / n, 2), round(before_ok[cid][aura] / ontime[cid], 2)
                                              if ontime[cid] else 0] for aura, k in before[cid].most_common(5)}
        out[spec] = {"seconds": round(secs), "procs": procs, "resets": dict(resets), "candidates": cand,
                     "early": {str(c): n for c, n in early.items() if n >= 5}}
        json.dump(out, open(OUT, "w"), indent=1, sort_keys=True)
        print("== %s: %d procs, resets %s" % (spec, len(procs), dict(resets)))
    json.dump(out, open(OUT, "w"), indent=1, sort_keys=True)


if __name__ == "__main__":
    main()
