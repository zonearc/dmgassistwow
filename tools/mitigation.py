#!/usr/bin/env python3
"""Build the per-spec mitigation map (how each spec stays alive) from reference profiles + game data.

Reference profiles: data/mitigation/<branch>/<spec>.txt, one per spec, written by hand from the class guides and
checked here against SimC's SpellDataDump (the game's own spell data), so they are easy to update when the game
changes and nothing about a class lives in code.

Profile format (one entry per line, '#' starts a comment):

    role     = tank | healer | dps
    model    = what keeps this spec alive, in a few words (shown in docs / Help)
    health   = 50                     the default low-health threshold, percent
    source   = where the order comes from (guides, date checked)

    keep     <token> [dur=6] [refresh=1] [stagger] [ragePool=60] [capped]
             tank keep-up button, pressed whenever it's due while tanking (Shield Block, Demon Spikes...)
    big      <token>                  before a big hit a boss mod announces: first ready in this order
    reflect  <token>                  a spell aimed at you (Spell Reflection, Anti-Magic Shell...)
    low      <token> [heal]           at low health: first ready in this order (lightest first, the big ones last)
    icon     <token>                  also kept out of the damage slots (shown in the defensive icon by other rules)
    capped   <token> health=85        a heal with all charges full: offered from this health already
    skip     <token> <reason...>      a spell the game flags as a defensive that this spec deliberately doesn't use

Options on any spell line: id=<spell id> (when the name is ambiguous), only=bear|caster (a form it needs),
heal (a heal: only when actually low, never ahead of a hit).

Checks (the build fails on any):
  * every token resolves to exactly one spell of the class in SpellDataDump (or its id= is a spell of the class),
  * the spell is available to that spec (talent tree "class", that spec's tree, or a baseline spell),
  * every spell the game flags "Big Defensive" that the spec can have is listed or skipped with a reason,
    except those flagged "External Defensive" (cast on others),
  * every spec of the branch has a profile.

Usage:
    tools/mitigation.py                 build addons/DMGAssist/Data/Mitigation.lua
    tools/mitigation.py --check         fail if the output is stale or any check fails (CI)
    tools/mitigation.py --lookup deathknight "Rune Tap" "Bone Shield"
    tools/mitigation.py --flagged deathknight     the class's Big Defensive spells
"""

import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUMP = os.path.join(ROOT, ".libraries", "simc", "midnight", "SpellDataDump")
PROFILES = os.path.join(ROOT, "data", "mitigation")
OUT = os.path.join(ROOT, "addons", "DMGAssist", "Data", "Mitigation.lua")

CLASS_FILE = {
    "deathknight": "deathknight", "demonhunter": "demonhunter", "druid": "druid", "evoker": "evoker",
    "hunter": "hunter", "mage": "mage", "monk": "monk", "paladin": "paladin", "priest": "priest",
    "rogue": "rogue", "shaman": "shaman", "warlock": "warlock", "warrior": "warrior",
}

# spec key suffix -> the talent tree name the dump uses
TREE = {
    "blood": "Blood", "frost": "Frost", "unholy": "Unholy", "devourer": "Devourer", "havoc": "Havoc",
    "vengeance": "Vengeance", "balance": "Balance", "feral": "Feral", "guardian": "Guardian",
    "restoration": "Restoration", "augmentation": "Augmentation", "devastation": "Devastation",
    "preservation": "Preservation", "beast_mastery": "Beast Mastery", "marksmanship": "Marksmanship",
    "survival": "Survival", "arcane": "Arcane", "fire": "Fire", "brewmaster": "Brewmaster",
    "mistweaver": "Mistweaver", "windwalker": "Windwalker", "holy": "Holy", "protection": "Protection",
    "retribution": "Retribution", "discipline": "Discipline", "shadow": "Shadow", "assassination": "Assassination",
    "outlaw": "Outlaw", "subtlety": "Subtlety", "elemental": "Elemental", "enhancement": "Enhancement",
    "affliction": "Affliction", "demonology": "Demonology", "destruction": "Destruction", "arms": "Arms",
    "fury": "Fury",
}

PARTS = ("keep", "big", "reflect", "low", "icon")


def token_of(name):
    """SimC's token for a spell name: lower case, apostrophes dropped, anything else to '_'."""
    name = re.sub(r"\(desc=[^)]*\)", "", name).strip()
    name = re.sub(r"[^a-z0-9 _]", "", name.lower())  # "Anti-Magic Shell" -> antimagic_shell, as SimC does
    return re.sub(r"[ _]+", "_", name).strip("_")


def parse_dump(cls):
    """Every spell block of a class file: id -> dict(name, token, talent, cd, dur, charges, flags, passive)."""
    path = os.path.join(DUMP, CLASS_FILE[cls] + ".txt")
    spells = {}
    cur = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = re.match(r"^Name\s+:\s+(.*?) \(id=(\d+)\)(.*)$", line)
            if m:
                name, sid, rest = m.group(1), int(m.group(2)), m.group(3)
                cur = {"id": sid, "name": name, "token": token_of(name), "talent": None, "cd": None, "dur": None,
                       "charges": None, "flags": set(), "passive": bool(re.search(r"[\[ ,]Passive\]", rest)),
                       "attrs": "", "raw": [], "cls": None}
                spells[sid] = cur
                continue
            if cur is None:
                continue
            cur["raw"].append(line)
            m = re.match(r"^(\w[\w ]*?)\s+:\s+(.*)$", line)
            if not m:
                if line.startswith("                 : ") and cur.get("_key") == "Attributes":
                    cur["attrs"] += " " + line.strip(" :\n")
                continue
            key, val = m.group(1), m.group(2).strip()
            cur["_key"] = key
            if key == "Class":
                cur["cls"] = val
            elif key == "Talent Entry":
                cur["talent"] = val
            elif key == "Cooldown":
                n = re.match(r"([\d.]+) seconds", val)
                cur["cd"] = float(n.group(1)) if n else None
            elif key == "Duration":
                n = re.match(r"([\d.]+) seconds", val)
                cur["dur"] = float(n.group(1)) if n else None
            elif key == "Charges":
                n = re.match(r"(\d+) \(([\d.]+) seconds cooldown\)", val)
                if n:
                    cur["charges"] = int(n.group(1))
                    cur["cd"] = max(cur["cd"] or 0, float(n.group(2)))  # the recharge is the real cooldown
            elif key == "Attributes":
                cur["attrs"] = val
    for s in spells.values():
        s.pop("_key", None)
        s["raw"] = "".join(s["raw"])
        if "Big Defensive (512)" in s["attrs"]:
            s["flags"].add("big")
        if "External Defensive (499)" in s["attrs"]:
            s["flags"].add("external")
    return spells


def available(spell, tree):
    """Can this spec have the spell? Baseline (no talent entry), the class tree, a hero tree, or its spec tree."""
    t = spell["talent"]
    if not t:
        return True
    m = re.match(r"^(.*?) \[(?:free=\(([^)]*)\), )?tree=(\w+)", t)
    if not m:
        return True
    owner, free, kind = m.group(1), m.group(2), m.group(3)
    if kind in ("class", "hero", "selection"):
        return True
    if kind == "spec":
        # another spec's talent the spec aura grants: Survival Instincts is a Feral talent, and "Guardian Druid
        # (137010)" gives it to Guardians
        return owner == tree or (spell["cls"] and ("%s %s (" % (tree, spell["cls"])) in spell["raw"])
    return True


class Error(Exception):
    pass


def parse_profile(path):
    prof = {"role": None, "model": "", "health": None, "source": "", "entries": [], "skip": {}, "capped": None}
    with open(path, encoding="utf-8") as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.split("#", 1)[0].rstrip()
            if not line.strip():
                continue
            m = re.match(r"^(\w+)\s*=\s*(.*)$", line.strip())
            if m:
                key, val = m.group(1), m.group(2).strip()
                if key == "health":
                    prof["health"] = int(val)
                elif key in ("role", "model", "source"):
                    prof[key] = val
                else:
                    raise Error("%s:%d: unknown setting %r" % (path, n, key))
                continue
            words = line.split()
            kind = words[0]
            if kind == "skip":
                if len(words) < 3:
                    raise Error("%s:%d: skip needs a reason" % (path, n))
                prof["skip"][words[1]] = " ".join(words[2:])
                continue
            if kind not in PARTS + ("capped",):
                raise Error("%s:%d: unknown line kind %r" % (path, n, kind))
            if len(words) < 2:
                raise Error("%s:%d: %s needs a spell token" % (path, n, kind))
            e = {"part": kind, "t": words[1], "line": n}
            for w in words[2:]:
                if "=" in w:
                    k, v = w.split("=", 1)
                    if k not in ("id", "dur", "refresh", "ragePool", "only", "health"):
                        raise Error("%s:%d: unknown option %r" % (path, n, k))
                    e[k] = v
                elif w in ("heal", "stagger", "capped"):
                    e[w] = True
                else:
                    raise Error("%s:%d: unknown option %r" % (path, n, w))
            if kind == "capped":
                prof["capped"] = e
            else:
                prof["entries"].append(e)
    if prof["role"] not in ("tank", "healer", "dps"):
        raise Error("%s: role must be tank, healer or dps" % path)
    if prof["health"] is None:
        raise Error("%s: health = <percent> missing" % path)
    return prof


def resolve(e, spells, by_token, tree, where):
    if "id" in e:
        sid = int(e["id"])
        s = spells.get(sid)
        if not s:
            raise Error("%s: id=%d is not a spell of this class" % (where, sid))
        return s
    cands = [s for s in by_token.get(e["t"], []) if not s["passive"]]
    if len(cands) > 1:
        usable = [s for s in cands if available(s, tree)]
        cands = usable or cands
    if len(cands) > 1:
        talented = [s for s in cands if s["talent"]]
        if len(talented) == 1:
            cands = talented
    if not cands:
        raise Error("%s: no active spell %r in the game data" % (where, e["t"]))
    if len(cands) > 1:
        raise Error("%s: %r is ambiguous (%s): add id=" % (
            where, e["t"], ", ".join(str(s["id"]) for s in cands)))
    return cands[0]


def build(branch="midnight"):
    from glob import glob
    idx = os.path.join(ROOT, "addons", "DMGAssist", "Data", branch, "Index.lua")
    with open(idx, encoding="utf-8") as fh:
        specs = re.findall(r'^\s+"(\w+_\w+)",$', fh.read(), re.M)
    errors, out, dumps = [], {}, {}
    for spec in specs:
        path = os.path.join(PROFILES, branch, spec + ".txt")
        if not os.path.exists(path):
            errors.append("%s: no profile (data/mitigation/%s/%s.txt)" % (spec, branch, spec))
            continue
        cls, sub = spec.split("_", 1)
        tree = TREE[sub]
        if cls not in dumps:
            sp = parse_dump(cls)
            bt = {}
            for s in sp.values():
                bt.setdefault(s["token"], []).append(s)
            dumps[cls] = (sp, bt)
        spells, by_token = dumps[cls]
        try:
            prof = parse_profile(path)
        except Error as ex:
            errors.append(str(ex))
            continue
        rel = os.path.relpath(path, ROOT)
        listed = set()
        parts = {p: [] for p in PARTS}
        for e in prof["entries"] + ([prof["capped"]] if prof["capped"] else []):
            where = "%s:%d" % (rel, e["line"])
            try:
                s = resolve(e, spells, by_token, tree, where)
            except Error as ex:
                errors.append(str(ex))
                continue
            if not available(s, tree):
                errors.append("%s: %s (%d) is a %s talent" % (where, s["name"], s["id"], s["talent"]))
            listed.add(s["id"])
            item = {"t": e["t"], "id": s["id"]}
            dur = e.get("dur") or s["dur"]
            if dur:
                item["dur"] = float(dur)
            if s["cd"]:
                item["cd"] = s["cd"]
            if s["charges"]:
                item["charges"] = s["charges"]
            for k in ("refresh", "ragePool"):
                if k in e:
                    item[k] = float(e[k])
            for k in ("heal", "stagger", "capped"):
                if e.get(k):
                    item[k] = True
            if "only" in e:
                item["only"] = e["only"]
            if e["part"] == "capped":
                prof["capped_out"] = {"id": s["id"], "t": e["t"], "health": int(e.get("health", 85))}
            else:
                parts[e["part"]].append(item)
        for t in prof["skip"]:
            for s in by_token.get(t, []):
                listed.add(s["id"])
        for s in spells.values():
            if "big" in s["flags"] and "external" not in s["flags"] and not s["passive"] and s["cd"] \
                    and available(s, tree) and s["id"] not in listed:
                if any(o["token"] == s["token"] and o["id"] in listed for o in by_token.get(s["token"], [])):
                    continue
                errors.append("%s: %s (%d) is flagged Big Defensive by the game: list it or 'skip %s <reason>'" % (
                    rel, s["name"], s["id"], s["token"]))
        if not parts["low"]:
            errors.append("%s: no low-health entries" % rel)
        out[spec] = {"role": prof["role"], "model": prof["model"], "health": prof["health"], "parts": parts,
                     "capped": prof.get("capped_out")}
    return specs, out, errors


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def lua_num(v):
    return str(int(v)) if float(v).is_integer() else repr(float(v))


def emit(specs, out, branch="midnight"):
    lines = ["-- Generated by tools/mitigation.py from data/mitigation/%s/*.txt and SimC's SpellDataDump." % branch,
             "-- Do not edit: change the profile and run tools/mitigation.py.",
             "local _, ns = ...", "ns.Data = ns.Data or {}", "ns.Data.mitigation = {"]
    for spec in specs:
        p = out.get(spec)
        if not p:
            continue
        lines.append("  %s = {" % spec)
        lines.append("    role = %s, health = %d," % (lua_str(p["role"]), p["health"]))
        lines.append("    model = %s," % lua_str(p["model"]))
        for part in PARTS:
            items = p["parts"][part]
            if not items:
                continue
            lines.append("    %s = {" % part)
            for it in items:
                fields = ["t = %s" % lua_str(it["t"]), "id = %d" % it["id"]]
                for k in ("dur", "cd", "charges", "refresh", "ragePool"):
                    if k in it:
                        fields.append("%s = %s" % (k, lua_num(it[k])))
                for k in ("heal", "stagger", "capped"):
                    if it.get(k):
                        fields.append("%s = true" % k)
                if "only" in it:
                    fields.append("only = %s" % lua_str(it["only"]))
                lines.append("      { %s }," % ", ".join(fields))
            lines.append("    },")
        if p["capped"]:
            c = p["capped"]
            lines.append("    capped = { t = %s, id = %d, health = %d }," % (lua_str(c["t"]), c["id"], c["health"]))
        lines.append("  },")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--lookup", nargs="+")
    ap.add_argument("--flagged")
    a = ap.parse_args()
    if a.lookup:
        cls, names = a.lookup[0], a.lookup[1:]
        spells = parse_dump(cls)
        for name in names:
            t = token_of(name)
            for s in spells.values():
                if s["token"] == t:
                    print("%-28s %7d cd=%-6s dur=%-5s ch=%-4s %s %s%s" % (
                        s["token"], s["id"], s["cd"], s["dur"], s["charges"], s["talent"] or "baseline",
                        "PASSIVE " if s["passive"] else "", ",".join(sorted(s["flags"]))))
        return 0
    if a.flagged:
        for s in sorted(parse_dump(a.flagged).values(), key=lambda s: s["name"]):
            if s["flags"]:
                print("%-28s %7d cd=%-6s dur=%-5s %s %s" % (s["token"], s["id"], s["cd"], s["dur"],
                                                          s["talent"] or "baseline", ",".join(sorted(s["flags"]))))
        return 0
    specs, out, errors = build()
    if errors:
        for e in errors:
            print("error: " + e, file=sys.stderr)
        return 1
    text = emit(specs, out)
    if a.check:
        old = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
        if old != text:
            print("error: %s is out of date: run tools/mitigation.py" % os.path.relpath(OUT, ROOT), file=sys.stderr)
            return 1
        print("mitigation map: %d specs, all checks pass" % len(out))
        return 0
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("wrote %s (%d specs)" % (os.path.relpath(OUT, ROOT), len(out)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
