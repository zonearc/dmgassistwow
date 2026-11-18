#!/usr/bin/env python3
"""Per-spec scorecard: the simulated fights and the recorded real fights side by side, one row per spec.

    python3 tools/scorecard.py            # writes docs/project/scorecard.md from the two baselines

Reads tests/scenario_baseline.lua (simulated: lua5.1 tests/test_scenarios.lua --update) and tests/fights/baseline.json
(recorded: python3 tools/replay-suite.py --update), so it shows exactly what the gates hold each spec to. Owner,
2026-11-18: forward progress per spec, visible per release.
"""
import json, os, re, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs", "project", "scorecard.md")
BAR = 70.0  # slot 2 target for now (owner, 2026-11-17)


def sim():
    rows = {}
    for line in open(os.path.join(ROOT, "tests", "scenario_baseline.lua")):
        m = re.match(r'\s*\["([a-z_]+)/(\w+)"\] = \{(.*)\},', line)
        if not m:
            continue
        vals = dict((k, float(v)) for k, v in re.findall(r"(\w+) = ([\d.]+)", m.group(3)))
        rows.setdefault(m.group(1), {})[m.group(2)] = vals
    return rows


def fights():
    path = os.path.join(ROOT, "tests", "fights", "baseline.json")
    out = {}
    for name, r in sorted(json.load(open(path)).items()):
        spec = name.rsplit("-", 1)[0]
        out.setdefault(spec, []).append(r)
    return out


def fmt(v, suffix="%"):
    return "-" if v is None else ("%.0f%s" % (v, suffix))


def main():
    s, f = sim(), fights()
    version = subprocess.run(["git", "describe", "--always"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    lines = [
        "# Per-spec scorecard",
        "",
        "Written by `python3 tools/scorecard.py` from the two gates' baselines (build %s)." % version,
        "",
        "- **Sim slot 2**: slot 2 was the next press, simulated fights (1 target / 5 targets / live play: bars, hidden",
        "  flags, cooldowns from the last pull, a late player who strays, range).",
        "- **Shown ready on cd**: slot 1 shown ready while its cooldown ran (simulated, single target).",
        "- **Real**: recorded fights (tests/fights): slot 1 / slot 2 replayed the same as shown in game, slot 2 against",
        "  the presses that came, slot 1 uncastable count. Blank: no recorded fight for that spec yet.",
        "- Target for now: slot 2 at %d%%+ (owner, 2026-11-17). Below it: **bold**." % BAR,
        "",
        "| spec | sim slot 2 st / aoe / live | shown ready on cd | real fights | real slot 1 / 2 same | real slot 2 vs presses | uncastable |",
        "|---|---|---|---|---|---|---|",
    ]
    below = []
    for spec in sorted(set(s) | set(f)):
        sc = s.get(spec, {})
        p = [sc.get(n, {}).get("predPct") for n in ("st", "aoe", "real")]
        ps = " / ".join(("**%s**" % fmt(v)) if v is not None and v < BAR else fmt(v) for v in p)
        oncd = sc.get("st", {}).get("onCdPct")
        rf = f.get(spec, [])
        if rf:
            avg = lambda k: sum(r.get(k, 0) for r in rf) / len(rf)
            pressed = [r for r in rf if r.get("presses", 0) >= 10]
            real = sum(r["real"] for r in pressed) / len(pressed) if pressed else None
            same = "%s / %s" % (fmt(avg("same1")), fmt(avg("same2")))
            unc = "%d" % sum(r.get("uncastable", 0) for r in rf)
        else:
            real, same, unc = None, "", ""
        rs = ("**%s**" % fmt(real)) if real is not None and real < BAR else fmt(real) if rf else ""
        lines.append("| %s | %s | %s | %s | %s | %s | %s |" % (spec, ps, fmt(oncd), len(rf) or "", same, rs, unc))
        if any(v is not None and v < BAR for v in p):
            below.append(spec)
    lines += ["", "%d of %d specs have a simulated slot 2 under %d%% in at least one fight." % (len(below), len(set(s)), BAR),
              ""]
    open(OUT, "w").write("\n".join(lines))
    print("written: %s" % OUT)


if __name__ == "__main__":
    main()
