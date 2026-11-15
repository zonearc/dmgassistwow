#!/usr/bin/env python3
"""Fold data/resource-gains.json into the shipped spec data in place, for chosen specs, without a full SimC import
(the local SimC copy can lag the one the shipped data was built from). Same rules as simc_import.apply_measured:
a spell's measured gain per cast replaces the data's (whole points), passive income per second becomes passiveGain.

Usage: python3 tools/fold-measured.py deathknight_blood demonhunter_havoc ...
"""
import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
DATA = os.path.join(ROOT, "addons", "DMGAssist", "Data", "midnight")
M = json.load(open(os.path.join(ROOT, "data", "resource-gains.json")))["midnight"]


def fmt_num(v):
    return ("%.3f" % v).rstrip("0").rstrip(".") if isinstance(v, float) else str(v)


def table(d):
    return "{ " + ", ".join("[%d] = %s" % (k, fmt_num(d[k])) for k in sorted(d)) + " }"


def fold(spec):
    path = os.path.join(DATA, spec + ".lua")
    lines = open(path, encoding="utf-8").read().split("\n")
    m = M.get(spec) or {}
    changes = []
    start = next(i for i, l in enumerate(lines) if l == "  spellInfo = {")
    for sid, gains in sorted(m.get("gains", {}).items()):
        head = "    [%s] = {" % sid
        try:
            i = lines.index(head, start)
        except ValueError:
            continue
        j = i + 1
        while lines[j] != "    },":
            j += 1
        gi = next((k for k in range(i + 1, j) if lines[k].startswith("      gain = ")), None)
        cur = {}
        if gi is not None:
            cur = {int(a): float(b) for a, b in re.findall(r"\[(\d+)\] = ([\d.]+)", lines[gi])}
        new = dict(cur)
        for pt, v in gains.items():
            v = int(round(v))
            if v > 0:
                new[int(pt)] = v
        new = {k: (int(v) if float(v).is_integer() else v) for k, v in new.items()}
        if new == {k: (int(v) if float(v).is_integer() else v) for k, v in cur.items()}:
            continue
        name = next((re.search(r'"(\w+)"', lines[k]).group(1) for k in range(i, j) if lines[k].startswith("      n = ")),
                    sid)
        changes.append("%s %s -> %s" % (name, table(cur) if cur else "-", table(new)))
        text = "      gain = %s," % table(new)
        if gi is not None:
            lines[gi] = text
        else:
            k = i + 1
            while k < j and re.match(r"      (\w+) =", lines[k]) and re.match(r"      (\w+) =", lines[k]).group(1) < "gain":
                # skip whole nested blocks
                if lines[k].rstrip().endswith("{"):
                    while lines[k] != "      },":
                        k += 1
                k += 1
            lines.insert(k, text)
    passive = {int(pt): v for pt, v in m.get("passive", {}).items() if v and v > 0}
    if passive:
        text = "  passiveGain = %s," % table(passive)
        pi = next((k for k, l in enumerate(lines) if l.startswith("  passiveGain = ")), None)
        if pi is not None:
            if lines[pi] != text:
                changes.append("passiveGain %s" % text.strip())
                lines[pi] = text
        else:
            k = next(k for k, l in enumerate(lines) if re.match(r"  (\w+) = ", l) and re.match(r"  (\w+) = ", l).group(1)
                     > "passiveGain")
            lines.insert(k, text)
            changes.append("passiveGain (new) %s" % text.strip())
    open(path, "w", encoding="utf-8").write("\n".join(lines))
    return changes


if __name__ == "__main__":
    for spec in sys.argv[1:]:
        for c in fold(spec):
            print("%-24s %s" % (spec, c))
