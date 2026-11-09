#!/usr/bin/env python3
"""Spell interdependencies from SimulationCraft's class modules (engine/class_modules/*.cpp).

SimC simulates every class in code, so each cooldown interaction it knows is written out explicitly, e.g.
    struct kill_command_t ... void execute() override { ...
        p()->cooldowns.wildfire_bomb->adjust( -p()->talents.wildfire_infusion->effectN( 1 ).time_value() );
That is the complete, tested list (SimC is checked against the live game every patch); spell descriptions are a
second, weaker source. From each call we take:
    source  - the action the code belongs to (struct <name>_t), when it happens in execute() (once per cast) or
              impact() (once per target hit; capped when the code caps it)
    target  - cooldowns.<name>
    amount  - <talent>->effectN( k ).time_value() read from the spell data dump, or "reset"
    requires- the talent (spell ID) that the line depends on
Calls that depend on chance (rng, roll, crits, procs), on hidden state (buff checks other than the talent itself),
on ticks, or on amounts computed elsewhere are skipped: the runtime's safety nets cover those.
"""
import os
import re

CALL = re.compile(r"cooldowns\.(\w+)->(adjust|reset)\s*\(")
STRUCT = re.compile(r"^\s*struct\s+(\w+?)_t\b")
METHOD = re.compile(r"^\s*(?:void|double|bool)\s+(\w+)\s*\(")
TALENT_AMOUNT = re.compile(r"-\s*(?:p\(\)->)?(?:talents|spec|tier_set)\.(\w+)->effectN\(\s*(\d+)\s*\)\.time_value\(\)\s*\)\s*;")
TIER = re.compile(r"^(\w+?)_s(\d+)_(\w+?)_(\d)pc$")  # mid_s2_mm_4pc
SEASON_VERSION = {"mid": "12.%d"}
TALENT_ANY = re.compile(r"(?:p\(\)->)?talents\.(\w+)")
UNSURE = re.compile(r"rng\(\)|roll\(|accumulated_rng|crit|->trigger\(\)\s*\)|\bbugs\b|->check\(\)|->up\(\)|"
                    r"target_data|td\(|health_percentage|is_ptr|\bstate\b|->stack\(\)")


def _token_for_struct(name):
    return re.sub(r"_(?:sv|bm|mm|base|damage|tick|impact|attack|spell|missile|driver|cast|main)$", "", name)


HELPER_STRUCT = re.compile(r"state|data|buff|dot|event|cb|callback|proc|helper|td|actor", re.I)


def _condition(lines, i):
    """The if() that directly controls line i (same line, or the line above it / above its opening brace)."""
    if re.search(r"\bif\s*\(", lines[i]):
        return lines[i]
    k = i - 1
    while k >= 0 and lines[k].strip() in ("", "{"):
        k -= 1
    if k >= 0 and re.match(r"\s*(?:else\s+)?if\s*\(", lines[k]):
        cond = lines[k]
        # a multi-line if(): take the lines until the closing parenthesis
        m = k
        while cond.count("(") > cond.count(")") and m + 1 < i:
            m += 1
            cond += " " + lines[m].strip()
        return cond
    return ""


def scan_file(text):
    """Yields one dict per cooldowns.<x>->adjust/reset call, with its enclosing action struct and method."""
    lines = text.splitlines()
    stack = []  # (struct name, brace depth at its opening)
    depth = 0
    method = None
    for i, line in enumerate(lines):
        code = re.sub(r'"[^"]*"', '""', line.split("//")[0])
        m = STRUCT.match(code)
        if m:
            stack.append((m.group(1), depth))
        m = METHOD.match(code)
        if m:
            method = m.group(1)
        for c in CALL.finditer(code):
            stmt = code
            j = i
            while not stmt.rstrip().endswith(";") and j + 1 < len(lines) and j - i < 4:
                j += 1
                stmt += " " + lines[j].strip()
            amt = TALENT_AMOUNT.search(stmt)
            if not amt:
                # "auto reduction = -p()->tier_set.x->effectN( 2 ).time_value();" a line or two above
                var = re.search(r"->adjust\(\s*(\w+)\s*\)", stmt)
                if var:
                    for k in range(max(0, i - 4), i):
                        mv = re.search(r"\b" + var.group(1) + r"\s*=\s*-\s*(?:p\(\)->)?(?:talents|spec|tier_set)\.(\w+)->effectN\(\s*(\d+)\s*\)\.time_value\(\)", lines[k])
                        if mv:
                            amt = mv
            owner = None
            for name, _ in reversed(stack):
                if not HELPER_STRUCT.search(name):
                    owner = name
                    break
            yield {
                "struct": owner, "method": method, "target": c.group(1), "kind": c.group(2), "stmt": stmt.strip(),
                "talent": amt.group(1) if amt else None, "effect": int(amt.group(2)) if amt else None,
                "context": _condition(lines, i), "around": "\n".join(lines[max(0, i - 3):i]), "line": i + 1,
            }
        depth += code.count("{") - code.count("}")
        while stack and depth <= stack[-1][1] and "}" in code:
            stack.pop()


def _ticks(by_token, action):
    """How many times a periodic effect ticks per cast: its duration / its period (both scale with haste)."""
    for s in by_token.get(action, []):
        d = s.get("duration")
        for e in s.get("effects_raw", []):
            m = re.search(r"every ([\d.]+) seconds?", e["text"] + e["detail"])
            if d and m and float(m.group(1)) > 0:
                return int(round(d / float(m.group(1))))
    return None


def _talent_seconds(spells_by_token, talent, effect):
    """The talent's effect value in seconds. Several spells share a talent's name (the button, a hidden passive):
    take the one whose effect is a time in milliseconds (Lethal Calibration: 2000 in 1262409, not 15 in 1262408)."""
    best = None
    for s in spells_by_token.get(talent, []):
        for e in s.get("effects_raw", []):
            if e["n"] == effect:
                v = re.search(r"Base Value: (-?[\d.]+)", e["detail"])
                if v:
                    val = abs(float(v.group(1)))
                    if val >= 100 and val % 50 == 0:
                        return s["id"], round(val / 1000.0, 3)
                    if val and best is None:
                        best = (s["id"], round(val, 3))
    return best or (None, None)


def links(module_dir, cls, spells):
    """[(source, target, seconds|"reset", requires_id, 0[, per_target_cap])], [review lines]."""
    files = {
        "deathknight": ["sc_death_knight.cpp"], "demonhunter": ["sc_demon_hunter.cpp"], "druid": ["sc_druid.cpp"],
        "evoker": ["sc_evoker.cpp"], "hunter": ["sc_hunter.cpp"], "mage": ["sc_mage.cpp"],
        "monk": ["monk/sc_monk.cpp"], "paladin": ["paladin/sc_paladin.cpp", "paladin/sc_paladin_holy.cpp",
        "paladin/sc_paladin_protection.cpp", "paladin/sc_paladin_retribution.cpp"],
        "priest": ["priest/sc_priest.cpp", "priest/sc_priest_discipline.cpp", "priest/sc_priest_holy.cpp",
        "priest/sc_priest_shadow.cpp"], "rogue": ["sc_rogue.cpp"], "shaman": ["sc_shaman.cpp"],
        "warlock": ["warlock/sc_warlock.cpp", "warlock/sc_warlock_actions.cpp"], "warrior": ["sc_warrior.cpp"],
    }.get(cls, [])
    by_token = {}
    for s in spells.values():
        by_token.setdefault(s["token"], []).append(s)
    # Set bonuses: SimC's "mid_s2_mm_4pc" is the game's "Hunter Marksmanship 12.1 Class Set 4pc"
    for name in set(re.findall(r"tier_set\.(\w+)", " ".join(
            open(os.path.join(module_dir, f), encoding="utf-8", errors="replace").read()
            for f in files if os.path.exists(os.path.join(module_dir, f))))):
        m = TIER.match(name)
        if not m or m.group(1) not in SEASON_VERSION:
            continue
        version = SEASON_VERSION[m.group(1)] % (int(m.group(2)) - 1)
        abbr, pieces = m.group(3), m.group(4)
        for sp in spells.values():
            nm = sp["name"]
            if (" %s Class Set %spc" % (version, pieces)) in nm:
                spec_part = nm.split(" %s " % version)[0].split(" ", 1)[-1]
                initials = "".join(w[0] for w in spec_part.split()).lower()
                if initials == abbr or spec_part.lower().startswith(abbr[0]) and len(abbr) <= 2 and abbr[0] == abbr[-1]:
                    by_token.setdefault(name, []).append(sp)
    out, review = [], []
    for f in files:
        path = os.path.join(module_dir, f)
        if not os.path.exists(path):
            continue
        for c in scan_file(open(path, encoding="utf-8", errors="replace").read()):
            where = "%s:%d" % (f, c["line"])
            if not c["struct"]:
                continue
            source = _token_for_struct(c["struct"])
            ticks = 1
            if c["method"] in ("tick", "last_tick"):
                ticks = _ticks(by_token, source) if c["method"] == "tick" else 1
                if not ticks:
                    review.append("%s %s -> %s in tick(): tick count unknown" % (where, source, c["target"]))
                    continue
            elif c["method"] not in ("execute", "impact"):
                review.append("%s %s -> %s in %s(): not once per cast" % (where, source, c["target"], c["method"]))
                continue
            if UNSURE.search(c["context"] + c["stmt"]):
                review.append("%s %s -> %s: conditional or chance-based" % (where, source, c["target"]))
                continue
            req_tal = c["talent"]
            if not req_tal:
                talents = TALENT_ANY.findall(c["context"] + c["stmt"])
                req_tal = talents[0] if talents else None
            req = 0
            if req_tal:
                req_spells = [s for s in by_token.get(req_tal, []) if s.get("talent") or s["passive"]]
                req = req_spells[0]["id"] if req_spells else 0
            if c["kind"] == "reset":
                out.append((source, c["target"], "reset", req, 0))
                continue
            if not c["talent"]:
                review.append("%s %s -> %s: amount computed elsewhere" % (where, source, c["target"]))
                continue
            sid, seconds = _talent_seconds(by_token, c["talent"], c["effect"])
            if not seconds or seconds > 120:
                review.append("%s %s -> %s: amount not found in spell data" % (where, source, c["target"]))
                continue
            row = (source, c["target"], round(seconds * ticks, 3), sid or req, 0)
            if c["method"] == "impact":
                cap = re.search(r"chain_target\s*<\s*.*?effectN\(\s*(\d+)\s*\)\.base_value\(\)", c["context"])
                n = None
                if cap:
                    for s in by_token.get(c["talent"], []):
                        for e in s.get("effects_raw", []):
                            if e["n"] == int(cap.group(1)):
                                v = re.search(r"Base Value: (-?[\d.]+)", e["detail"])
                                n = float(v.group(1)) if v else None
                row = row + (round(seconds * (n or 5), 3),)  # per target hit, capped
            out.append(row)
    return out, review
