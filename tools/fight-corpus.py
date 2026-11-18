#!/usr/bin/env python3
"""Add recorded fights to the regression library (tests/fights/), names and IDs stripped.

    python3 tools/fight-corpus.py SV.json [SV.json ...]      # decoded Watchdog files (tools/decode-export.py)

Keeps fights of 20 s or more that have a recording, the two newest per spec. Each becomes
tests/fights/<spec>-<fight>.lua.gz (the input tests/replay.lua reads). The player's name, realm and GUIDs are
replaced before anything is written (owner rule: no player names are stored).
"""
import gzip, importlib.util, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec_ = importlib.util.spec_from_file_location("rp", os.path.join(ROOT, "tools", "replay.py"))
rp = importlib.util.module_from_spec(spec_)
spec_.loader.exec_module(rp)

# questions whose answers can name the player: their recorded values are blanked
PRIVATE_Q = re.compile(r"^(UnitName|UnitFullName|GetUnitName|UnitGUID|GetRealmName|GetNormalizedRealmName|"
                       r"BNGetInfo|GetGuildInfo|UnitPVPName)\(")


def strip(session):
    rec = []
    private = set()
    for l in session.get("rec") or []:
        if l.startswith("K "):
            _, k, q = l.split(" ", 2)
            if PRIVATE_Q.match(q):
                private.add(k)
        rec.append(l)
    out = []
    for l in rec:
        if l.startswith("T ") and private:
            head, _, body = l.partition("|")
            items = []
            for item in body.split(";"):
                k, eq, v = item.partition("=")
                items.append(k + eq + ('"X"' if eq and k in private else v))
            l = head + "|" + ";".join(items)
        l = re.sub(r"Player-\d+-[0-9A-Fa-f]+", "Player-0-0", l)
        out.append(l)
    s = dict(session)
    s["rec"] = out
    s["events"] = [e for e in session.get("events", []) if not (len(e) > 2 and e[2] == "anchor_summary")] + \
        [e for e in session.get("events", []) if len(e) > 3 and e[2] == "anchor_summary" and
         not e.__setitem__(3, re.sub(r"guid=\S+", "guid=-", e[3]))]
    return s


def main():
    fights = {}
    for path in sys.argv[1:]:
        d = json.load(open(path))
        for s in d.get("sessions", []):
            rec = s.get("rec") or []
            head = next((l for l in rec if l.startswith("H ")), "")
            m = re.search(r"spec=([^;]+)", head)
            if not m or (s.get("duration") or 0) < 20 or len(rec) < 500:
                continue
            fights[(m.group(1), s["id"])] = s
    by_spec = {}
    for (spec, fid), s in sorted(fights.items()):
        by_spec.setdefault(spec, []).append((fid, s))
    os.makedirs(os.path.join(ROOT, "tests", "fights"), exist_ok=True)
    n = 0
    for spec, items in sorted(by_spec.items()):
        for fid, s in items[-2:]:
            text = rp.build_input(strip(s))
            assert not re.search(r"Player-\d+-[0-9A-Fa-f]{6,}", text), "a player GUID is left"
            name = os.path.join(ROOT, "tests", "fights", "%s-%s.lua.gz" % (spec, fid))
            with gzip.open(name, "wt") as f:
                f.write(text)
            n += 1
            print(name)
    print("%d fights" % n)


if __name__ == "__main__":
    main()
