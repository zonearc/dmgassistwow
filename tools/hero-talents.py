#!/usr/bin/env python3
"""Which hero tree each hero talent belongs to, from SimC's generated trait data: data/hero-talents.json
{"<talent spell id>": "<hero tree token>"}.

The reference builds (tools/simc-reference.py) list the hero talents of both trees a profile's talent string holds;
a character has only one. The offline game (tests/test_scenarios.lua, graded fights) keeps the reference's own tree
and drops the other's talents - a Diabolist Destruction warlock had Hellcaller's Wither offline (2026-11-18).

    python3 tools/hero-talents.py [path/to/engine/dbc/generated/trait_data.inc]
"""
import json, os, re, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SRC = os.path.join(ROOT, ".libraries", "simc", "midnight", "engine", "dbc", "generated", "trait_data.inc")
OUT = os.path.join(ROOT, "data", "hero-talents.json")


def token(name):
    return re.sub(r"[^a-z0-9_]", "", name.strip().lower().replace(" ", "_").replace("-", "_"))


def main():
    text = open(sys.argv[1] if len(sys.argv) > 1 else SRC, encoding="utf-8", errors="replace").read()
    trees = {int(i): token(n) for i, n in re.findall(r'^\s*\{\s*(\d+),\s*"([^"]+)",\s*\d+\s*\},?\s*$', text, re.M)}
    out = {}
    # { tree, class, entry, node, max, req, def, spell, replace, override, row, col, sel, "name", {spec}, {starter}, sub, type }
    row = re.compile(r'^\s*\{\s*3,\s*\d+,\s*\d+,\s*\d+,\s*\d+,\s*\d+,\s*\d+,\s*(\d+),\s*\d+,\s*\d+,\s*-?\d+,\s*-?\d+,\s*-?\d+,'
                     r'\s*"[^"]*",\s*\{[^}]*\},\s*\{[^}]*\},\s*(\d+),', re.M)
    for spell, sub in row.findall(text):
        if int(sub) in trees and int(spell) > 0:
            out[spell] = trees[int(sub)]
    json.dump(out, open(OUT, "w"), indent=1, sort_keys=True)
    open(OUT, "a").write("\n")
    print("%d hero talents in %d trees -> %s" % (len(out), len(set(out.values())), OUT))


if __name__ == "__main__":
    main()
