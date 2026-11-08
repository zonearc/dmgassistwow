#!/usr/bin/env python3
"""Parse wowsims/gamedata spell cards (WoW Forever client data) into the same per-spell facts as simc_spells.py.

A card (spells/<class>/<spec>.txt, separated by "======="):

    1079 Rip (Rank 1)
    school    physical
    duration  12 s
    gcd       1 s
    cost      30 energy
    cost      1 combo points
    range     5 yd
    attrs     refund on miss, periodic can crit
    effect 1  4 physical damage every 2 s to the enemy (6 ticks)
              E_APPLY_AURA A_PERIODIC_DAMAGE base=4 period=2000ms perResource=5.5 target=[6,0]
    https://www.wowhead.com/forever/spell=1079

Output per spell id: name, token (SimC style, rank stripped), rank, passive, hidden, duration, cooldown, gcd,
castTime, stacks, range, cost {powerType: n} (+ costMax for combo point finishers: 1..5), gain (E_ENERGIZE to self,
misc = power type), aura "self"/"enemy" (E_APPLY_AURA target [1] / [6]).
"""
import os
import re

from simc_spells import token as simc_token

HEADER = re.compile(r"^(\d+) (.+)$")
FIELD = re.compile(r"^([a-z][a-z ]*?)\s{2,}(.*)$")
SECONDS = re.compile(r"(-?[\d.]+) s\b")
RANK = re.compile(r"\(Rank (\d+)\)")
POWER_NAMES = {"mana": 0, "rage": 1, "focus": 2, "energy": 3, "combo points": 4, "combo point": 4}
COMBO_MAX = 5


def _num(s):
    v = float(s)
    return int(v) if v.is_integer() else v


def clean_name(name):
    """'Bash (Rank 1)' -> 'Bash'; 'Aquatic Form (Shapeshift)' -> 'Aquatic Form'; '... (Passive)' -> '...'."""
    return re.sub(r"(\s*\([^)]*\))+\s*$", "", name).strip()


def parse_cards(text):
    spells = {}
    for card in text.split("======="):
        lines = [ln.rstrip() for ln in card.strip("\n").splitlines()]
        if not lines:
            continue
        m = HEADER.match(lines[0].strip())
        if not m:
            continue
        sid, raw_name = int(m.group(1)), m.group(2)
        rank = RANK.search(raw_name)
        name = clean_name(raw_name)
        s = {"id": sid, "name": name, "token": simc_token(name), "rank": int(rank.group(1)) if rank else 0,
             "passive": "(Passive)" in raw_name, "hidden": False}
        applies_self = applies_enemy = False
        gains = {}
        for ln in lines[1:]:
            if ln.startswith(" "):
                body = ln.strip()
                if body.startswith("E_APPLY_AURA"):
                    t = re.search(r"target=\[(\d+)", body)
                    if t and t.group(1) == "1":
                        applies_self = True
                    elif t and t.group(1) == "6":
                        applies_enemy = True
                elif body.startswith("E_ENERGIZE"):
                    b, misc = re.search(r"base=(-?[\d.]+)", body), re.search(r"misc=(\d+)", body)
                    t = re.search(r"target=\[(\d+)", body)
                    if b and misc and (not t or t.group(1) == "1"):
                        pt = int(misc.group(1))
                        gains[pt] = gains.get(pt, 0) + _num(b.group(1))
                continue
            f = FIELD.match(ln)
            if not f:
                continue
            key, val = f.group(1), f.group(2).strip()
            if key == "duration":
                sec = SECONDS.search(val)
                if sec:
                    s["duration"] = _num(sec.group(1))
            elif key == "cooldown":
                sec = SECONDS.search(val)
                if sec:
                    s["cooldown"] = max(s.get("cooldown", 0), _num(sec.group(1)))
            elif key == "gcd":
                sec = SECONDS.search(val)
                if sec:
                    s["gcd"] = _num(sec.group(1))
            elif key == "cast":
                sec = SECONDS.search(val)
                if sec and float(sec.group(1)) > 0:
                    s["castTime"] = _num(sec.group(1))
            elif key == "stack":
                st = re.search(r"up to (\d+)", val)
                if st:
                    s["stacks"] = int(st.group(1))
            elif key == "range":
                r = re.search(r"([\d.]+) yd", val)
                if r:
                    s["range"] = _num(r.group(1))
            elif key == "cost":
                c = re.match(r"([\d.]+) ([a-z ]+)$", val)  # "% of base mana" costs are skipped
                if c and c.group(2) in POWER_NAMES:
                    pt = POWER_NAMES[c.group(2)]
                    s.setdefault("cost", {})[pt] = _num(c.group(1))
                    if pt == 4:  # finishers: "1 combo points" means 1..5
                        s.setdefault("costMax", {})[4] = COMBO_MAX
            elif key == "attrs":
                if "passive" in val:
                    s["passive"] = True
        if applies_self:
            s["aura"] = "self"
        elif applies_enemy:
            s["aura"] = "enemy"
        gains = {k: v for k, v in gains.items() if v}
        if gains:
            s["gain"] = gains
        spells[sid] = s
    return spells


def parse_class(gamedata_root, cls):
    """All cards of one class (every spec file, pets, other), keyed by spell id."""
    spells = {}
    folder = os.path.join(gamedata_root, "spells", cls)
    if not os.path.isdir(folder):
        return spells
    for name in sorted(os.listdir(folder)):
        if name.endswith(".txt"):
            spells.update(parse_cards(open(os.path.join(folder, name), encoding="utf-8").read()))
    return spells
