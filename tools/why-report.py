#!/usr/bin/env python3
"""Every slot 2 miss as one case, with the WHY (owner, 2026-11-15).

Usage: python3 tools/why-report.py decoded.json [--fight ID] [--all] [--hits]

Reads the decision_trace / ahead_trace lines DMGAssist logs on every change of slot 1 or slot 2 (1.6.0.295+),
rebuilds each trace whole (they are logged as changes from the previous one), and pairs each press with the trace
that was showing when it was made. For each press where slot 2 named a different spell than the next press:

  - what slot 1 and slot 2 showed, and what was pressed next;
  - the look-ahead slot 2 started from (the pretend cast, the clock, each power's change and bounds);
  - the list line that won slot 2, and every line for the spell actually pressed: castable / why / power /
    condition / the values the condition read.

A summary at the end groups the misses by the reason the pressed spell was passed over.
"""
import collections
import json
import re
import sys


def parse_args(argv):
    args = {"file": None, "fight": None, "all": False, "hits": False}
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--fight":
            args["fight"] = argv[i + 1]
            i += 1
        elif a == "--all":
            args["all"] = True
        elif a == "--hits":
            args["hits"] = True
        else:
            args["file"] = a
        i += 1
    return args


def fields(text):
    return dict(x.split("=", 1) for x in str(text).split() if "=" in x)


def join_parts(events):
    """(t, kind, '#k p/n text') -> list of (t, kind, k, text) with parts joined."""
    pending, out = {}, []
    for t, kind, data in events:
        m = re.match(r"#(\d+) (\d+)/(\d+) (.*)$", str(data), re.S)
        if not m:
            out.append((t, kind, None, str(data)))
            continue
        k, p, n, text = int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4)
        key = (kind, k)
        buf = pending.setdefault(key, {"t": t, "parts": {}})
        buf["parts"][p] = text
        if len(buf["parts"]) == n:
            out.append((buf["t"], kind, k, "".join(buf["parts"][i] for i in range(1, n + 1))))
            del pending[key]
    for (kind, k), buf in pending.items():  # a part lost to the export's trimming: keep what came
        out.append((buf["t"], kind, k, "".join(buf["parts"][i] for i in sorted(buf["parts"]))))
    out.sort(key=lambda x: (x[0], x[2] or 0))
    return out


def rebuild(prev, delta):
    """'n=12; 3=text; 7=text' applied to the previous lines."""
    items = delta.split("; ") if delta else []
    n = None
    lines = list(prev or [])
    for it in items:
        m = re.match(r"n=(\d+)$", it)
        if m:
            n = int(m.group(1))
            continue
        m = re.match(r"(\d+)=(.*)$", it, re.S)
        if m:
            i = int(m.group(1))
            while len(lines) < i:
                lines.append("")
            lines[i - 1] = m.group(2)
        elif lines:
            lines[-1] += "; " + it  # a "; " inside a line
    if n is not None:
        lines = lines[:n] + [""] * max(0, n - len(lines))
    return lines


def traces(session):
    ev = [(e[0], e[2], e[3]) for e in session["events"]
          if len(e) > 3 and e[1] == "D" and e[2] in ("decision_trace", "ahead_trace")]
    last = {}
    out = []  # (t, k, slot, show_or_pick, state, lines)
    for t, kind, k, text in join_parts(ev):
        if kind == "decision_trace":
            m = re.match(r"show=(.*?) \| .*? \| lines: (.*?) \| unknown:", text, re.S)
            if not m:
                continue
            lines = rebuild(last.get(1), m.group(2))
            last[1] = lines
            out.append({"t": t, "k": k, "slot": 1, "show": m.group(1), "state": "", "lines": lines})
        else:
            m = re.match(r"slot=(\d+) pick=(\S+) \| (.*?) \| lines: (.*)$", text, re.S)
            if not m:
                continue
            slot = int(m.group(1))
            lines = rebuild(last.get(slot), m.group(4))
            last[slot] = lines
            out.append({"t": t, "k": k, "slot": slot, "show": m.group(2), "state": m.group(3), "lines": lines})
    return out


def line_spell(line):
    m = re.match(r"[^:]+:(\S+)", line)
    return m.group(1) if m else None


def reason(line):
    if "castable=false" in line:
        m = re.search(r"castable=false\((\w+)\)", line)
        return "not castable (%s)" % (m.group(1) if m else "?")
    if "cond=false" in line:
        return "condition false"
    if "cond=?" in line or "cond=UNKNOWN" in line:
        return "condition unknown"
    if "cond=true" in line:
        return "condition true but a line above won"
    for tag in ("line_cd", "ruled out", "hidden by you", "held", "before the pull", "only while moving"):
        if tag in line:
            return tag
    return "not reached / other"


def main():
    args = parse_args(sys.argv)
    if not args["file"]:
        print(__doc__)
        sys.exit(1)
    d = json.load(open(args["file"]))
    sessions = d.get("sessions", [])
    if args["fight"]:
        sessions = [s for s in sessions if str(s.get("id")) == args["fight"]]
    elif not args["all"]:
        sessions = sessions[-1:]
    groups = collections.Counter()
    for s in sessions:
        tr = traces(s)
        presses = [(e[0], fields(e[3])) for e in s["events"] if len(e) > 3 and e[1] == "D" and e[2] == "press"]
        print("== fight %s  (%d traces, %d presses)" % (s.get("id"), len(tr), len(presses)))
        if not tr:
            print("   no why traces in this fight (DMGAssist 1.6.0.295 or later logs them)")
            continue
        n_miss = 0
        for i in range(len(presses) - 1):
            t, p = presses[i]
            nxt = presses[i + 1][1].get("s")
            q2 = p.get("q2")
            hit = q2 == nxt
            if hit and not args["hits"]:
                continue
            # the slot 2 trace showing when this press was made: the last one logged at or before it
            ahead = [x for x in tr if x["slot"] == 2 and x["t"] <= t + 0.001]
            a = ahead[-1] if ahead else None
            n_miss += 0 if hit else 1
            print("\n-- %.2f  slot1=%s slot2=%s  next pressed=%s  %s" % (t, p.get("s"), q2, nxt,
                                                                        "HIT" if hit else "MISS"))
            if not a:
                print("   (no slot 2 trace before this press)")
                continue
            print("   trace #%s at %.2f (%.2fs before): %s" % (a["k"], a["t"], t - a["t"], a["state"]))
            won = [l for l in a["lines"] if line_spell(l) == a["show"] and "cond=true" in l]
            for l in won[:1]:
                print("   won:     " + l)
            mine = [l for l in a["lines"] if line_spell(l) == nxt]
            if not mine:
                print("   %s: no line for it was checked before the winner" % nxt)
                if not hit:
                    groups["%s: not reached (a line above won)" % nxt] += 1
            for l in mine[:4]:
                print("   %s: %s" % (nxt, l))
            if mine and not hit:
                groups["%s: %s" % (nxt, reason(mine[0]))] += 1
        print("\n   misses with a trace: %d" % n_miss)
    if groups:
        print("\n== why the pressed spell was passed over in slot 2")
        for k, v in groups.most_common():
            print("   %3d  %s" % (v, k))


if __name__ == "__main__":
    main()
