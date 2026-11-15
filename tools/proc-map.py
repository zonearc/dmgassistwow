#!/usr/bin/env python3
"""Proc auras from SimC's SpellDataDump: an aura with a duration that makes spells free ("Spell Resource Cost"
-100%: Clearcasting -> Shred) or instant ("Cast Time" -100%: Hot Streak -> Pyroblast). The offline game rolls them
at the rate top players get them (tools/wcl-procs.py -> data/proc-rates.json; owner, 2026-11-15: "determine procs
exist, execute at random").

Writes data/proc-map.json: { auraID: { d: seconds, stacks: n, free: [ids], instant: [ids] } } (tools/build-procs.py
turns it into the offline game's per-spec table).
Usage: python3 tools/proc-map.py
"""
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
SRC = os.path.join(ROOT, ".libraries", "simc", "midnight", "SpellDataDump", "allspells.txt")
JSON = os.path.join(ROOT, "data", "proc-map.json")
HEAD = re.compile(r"^Name\s*:\s*.+? \(id=(\d+)\)")


def main():
    lines = open(SRC, encoding="utf-8", errors="replace").read().splitlines()
    out = {}
    sid, dur, stacks = None, 0, 1
    for i, line in enumerate(lines):
        m = HEAD.match(line)
        if m:
            sid, dur, stacks = int(m.group(1)), 0, 1
            continue
        d = re.match(r"^Duration\s*:\s*([\d.]+) seconds", line)
        if d:
            dur = float(d.group(1))
        s = re.match(r"^Max Stacks?\s*:\s*(\d+)", line)
        if s:
            stacks = int(s.group(1))
        kind = None
        if "Spell Resource Cost" in line and "Percent Modifier" in line:
            kind = "free"
        elif re.search(r"Percent Modifier.*: (Spell )?Cast Time", line):
            kind = "instant"
        if not kind or not sid or dur <= 0:
            continue
        nxt = " ".join(lines[i + 1:i + 4])
        v = re.search(r"Base Value: (-?\d+)", nxt)
        aff = re.search(r"Affected Spells: (.*?)(?:Family Flags|Modified By|#\d|$)", nxt)
        if not v or int(v.group(1)) > -100 or not aff:
            continue
        ids = [int(x) for x in re.findall(r"\((\d+)\)", aff.group(1))]
        if ids:
            row = out.setdefault(sid, {"d": dur, "stacks": stacks, "free": set(), "instant": set()})
            row[kind] |= set(ids)
    json.dump({str(a): {"d": r["d"], "stacks": r["stacks"], "free": sorted(r["free"]), "instant": sorted(r["instant"])}
               for a, r in out.items()}, open(JSON, "w"), indent=1, sort_keys=True)
    print("%d proc auras -> %s" % (len(out), JSON))


if __name__ == "__main__":
    main()
