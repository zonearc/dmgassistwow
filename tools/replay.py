#!/usr/bin/env python3
"""Replay recorded fights through the current addon, offline (owner, 2026-11-16: "take the exports back in and
resolve issues and update the tester").

A fight recorded in game (/dmga record on; Core/Record.lua) holds every answer the game gave DMGAssist and every
event. This feeds them back to the addon as it is now (tests/replay.lua) and prints per fight:

  same   - how often the replayed slot 1 / slot 2 match what the game showed (100% = the replay is faithful; a
           code change moves this on purpose);
  real   - slot 2 right against the press that really came next (the owner's presses: the in-game measure).

Usage:
  python3 tools/replay.py export.txt|decoded.json [--fight ID] [--picks]
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")


def load(path):
    text = open(path, encoding="utf-8").read().strip()
    if text.startswith("{"):
        return json.loads(text)
    out = subprocess.run([sys.executable, os.path.join(HERE, "decode-export.py"), path], capture_output=True,
                         text=True)
    return json.loads(out.stdout)


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def fields(text):
    return dict(x.split("=", 1) for x in str(text).split() if "=" in x)


def build_input(session):
    rec = session.get("rec") or []
    head = next((l for l in rec if l.startswith("H ")), "")
    spec = re.search(r"spec=([^;]+)", head)
    book, talent_ids, talents, settings = [], {}, {}, {}
    for l in rec:
        if l.startswith("B "):
            for item in l[2:].split(","):
                p = item.split(":")
                if len(p) >= 4 and p[0]:
                    book.append((int(p[0]), int(p[1]) if p[1].isdigit() else int(p[0]), p[2] == "p",
                                 int(p[3]) if p[3].isdigit() else None))
        elif l.startswith("TAL "):
            ids, _, toks = l[4:].partition("|")
            for item in filter(None, ids.split(",")):
                a, b = item.split(":")
                talent_ids[int(a)] = int(float(b))
            for item in filter(None, toks.split(",")):
                a, b = item.rsplit(":", 1)
                talents[a] = int(float(b))
        elif l.startswith("D "):
            for item in filter(None, l[2:].split(";")):
                k, v = item.split("=", 1)
                settings[k] = True if v == "T" else False if v == "F" else (v[1:-1] if v.startswith('"') else
                                                                             float(v) if re.match(r"^-?[\d.]+$", v)
                                                                             else v)
    shown = []
    for e in session.get("events", []):
        if len(e) > 3 and e[1] == "D" and e[2] == "pick":
            f = fields(e[3])
            shown.append((e[0], f.get("main"), f.get("next")))
    start = re.search(r"start=([\d.]+)", head)
    snap = {}
    for l in rec:
        if l.startswith("L "):
            _, name, lit = l.split(" ", 2)
            snap[name] = lit
    out = ["return {", "spec = %s," % lua_str(spec.group(1) if spec else "?"),
           "start = %s," % (start.group(1) if start else "nil"),
           "snapshot = {" + ",".join("[%s]=%s" % (lua_str(k), lua_str(v)) for k, v in snap.items()) + "},"]
    out.append("book = {" + ",".join("{%d,%d,%s,%s}" % (a, b, "true" if c else "false", d if d else "nil")
                                    for a, b, c, d in book) + "},")
    out.append("talentIDs = {" + ",".join("[%d]=%d" % kv for kv in talent_ids.items()) + "},")
    out.append("talents = {" + ",".join("[%s]=%d" % (lua_str(k), v) for k, v in talents.items()) + "},")
    sv = []
    for k, v in settings.items():
        sv.append("[%s]=%s" % (lua_str(k), ("true" if v else "false") if isinstance(v, bool) else
                               (repr(v) if isinstance(v, float) else lua_str(str(v)))))
    out.append("settings = {" + ",".join(sv) + "},")
    out.append("shown = {" + ",".join("{t=%s,main=%s,next=%s}" % (t, lua_str(m or ""), lua_str(n or ""))
                                     for t, m, n in shown) + "},")
    out.append("lines = {" + ",\n".join(lua_str(l) for l in rec if l[:2] in ("K ", "T ", "E ", "Q ")) + "},")
    out.append("}")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file")
    ap.add_argument("--fight")
    ap.add_argument("--picks", action="store_true")
    a = ap.parse_args()
    d = load(a.file)
    sessions = [s for s in d.get("sessions", []) if s.get("rec")]
    if a.fight:
        sessions = [s for s in sessions if str(s.get("id")) == a.fight]
    if not sessions:
        print("no recorded fights (turn it on in game: /dmga record on)")
        return
    for s in sessions:
        f = tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False)
        f.write(build_input(s))
        f.close()
        cmd = ["lua5.1", "tests/replay.lua", f.name] + (["--picks"] if a.picks else [])
        out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        os.unlink(f.name)
        same = re.search(r"^SAME ([\d.]+) ([\d.]+) (\d+)", out.stdout, re.M)
        real = re.search(r"^REAL ([\d.]+) (\d+)", out.stdout, re.M)
        if a.picks:
            print("\n".join(l for l in out.stdout.splitlines() if l.startswith("PICK")))
        if not same:
            print("== fight %s: replay failed\n%s" % (s.get("id"), (out.stdout + out.stderr)[-1500:]))
            continue
        print("== fight %s (%s): same as shown - slot 1 %s%%, slot 2 %s%% (%s picks) | slot 2 vs real presses %s%% "
              "(%s presses)" % (s.get("id"), s.get("name") or s.get("zone") or "", same.group(1), same.group(2),
                                same.group(3), real.group(1) if real else "?", real.group(2) if real else "?"))


if __name__ == "__main__":
    main()
