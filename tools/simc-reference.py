#!/usr/bin/env python3
"""Build the per-spec reference DMGAssist is graded against (owner, 2026-11-14: "we can't use my logs as the
reference ... that assumes the source material is correct").

For each spec with a SimulationCraft profile (profiles/MID1): the profile's exact talents (SimC's own decoder, read
from its debug output), then N simulated fights at 1 and at 5 targets (seeded, so it repeats), and per target count:

  cpm      casts per minute of every spell the player presses (the spell tokens our spec data knows)
  opener   the first casts of a fight, most common at each position
  pairs    the most common "this, then that"
  seconds  simulated fight time behind the numbers

Writes data/reference/<spec>.json. tests/test_scenarios.lua (SCEN_GRADE=1) runs DMGAssist with the same talents and
target counts and scores it against this. Top players' numbers (Warcraft Logs) join later under "players".

Needs a built SimC (--simc-bin) and its source tree (--simc-src, for profiles and talent data); run by hand after a
SimC or patch update.

Usage: python3 tools/simc-reference.py --simc-bin simc --simc-src path/to/simc [--specs ...] [--fights 20]
"""
import argparse
import collections
import concurrent.futures
import json
import os
import re
import subprocess
import tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
DATA = os.path.join(ROOT, "addons", "DMGAssist", "Data", "midnight")
OUT = os.path.join(ROOT, "data", "reference")
CLASS = {"deathknight": "Death_Knight", "demonhunter": "Demon_Hunter"}
SKIP = {"auto_attack", "auto_attack_mh", "auto_attack_oh", "auto_shot", "potion", "food", "flask", "augmentation",
        "snapshot_stats", "use_item", "use_items", "variable", "call_action_list", "run_action_list", "pool_resource",
        "wait", "invoke_external_buff", "retarget_auto_attack"}


def profile_for(src, spec):
    cls, _, name = spec.partition("_")
    for c in CLASS:
        if spec.startswith(c + "_"):
            cls, name = c, spec[len(c) + 1:]
    title = CLASS.get(cls, cls.title()) + "_" + "_".join(p.title() for p in name.split("_"))
    path = os.path.join(src, "profiles", "MID1", "MID1_" + title + ".simc")
    return path if os.path.exists(path) else None


def tokens_for(spec):
    """The actions the spec's rotation lists press (procs and passives the log also reports are left out)."""
    t = open(os.path.join(DATA, spec + ".lua"), encoding="utf-8").read()
    return set(re.findall(r'\ba = "(\w+)"', t))


TREES = {1: "class_talents", 2: "spec_talents", 3: "hero_talents"}  # (4, the hero tree choice: SimC infers it)


def trait_table(src):
    """trait node entry ID -> (tree index, spell ID)"""
    out = {}
    path = os.path.join(src, "engine", "dbc", "generated", "trait_data.inc")
    for m in re.finditer(r"\{\s*(\d+),\s*\d+,\s*(\d+),\s*\d+,\s*\d+,\s*\d+,\s*\d+,\s*(\d+),", open(path).read()):
        out[int(m.group(2))] = (int(m.group(1)), int(m.group(3)))
    return out


def player_build(spec, entries):
    """A top player's talents (Warcraft Logs, the pull's combatant info) as SimC options, for specs whose SimC
    profile no longer loads (its talent string predates a talent tree change)."""
    import importlib.util
    s = importlib.util.spec_from_file_location("wclres", os.path.join(os.path.dirname(__file__), "wcl-resources.py"))
    W = importlib.util.module_from_spec(s)
    s.loader.exec_module(W)
    for code, fid, name in W.top_fights(spec, 53, 4, 3):
        d = W.query("query($c:String!,$f:[Int]){reportData{report(code:$c){fights(fightIDs:$f){startTime endTime}"
                    " masterData{actors(type:\"Player\"){id name}}}}}", {"c": code, "f": [fid]})
        rep = d["reportData"]["report"]
        ids = [a["id"] for a in rep["masterData"]["actors"] if a["name"] == name]
        if not ids:
            continue
        f = rep["fights"][0]
        ev = W.events(code, fid, ids[0], "CombatantInfo", f["startTime"], f["endTime"])
        tree = ev and ev[0].get("talentTree")
        if not tree:
            continue
        opts = {}
        for t in tree:
            kind = TREES.get(entries.get(t["id"], (0, 0))[0])
            if kind:
                opts.setdefault(kind, []).append("%d:%d" % (t["id"], t["rank"]))
        return ["talents="] + ["%s=%s" % (k, "/".join(v)) for k, v in sorted(opts.items())]
    return None


def run(simc, args):
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "o.txt")
        r = subprocess.run([simc] + args + ["output=" + out, "threads=1"], capture_output=True, text=True,
                           errors="ignore", timeout=600)
        text = open(out, encoding="utf-8", errors="ignore").read() if os.path.exists(out) else ""
        return text + "\n" + (r.stdout or "") + "\n" + (r.stderr or "")  # (errors go to the console)


def talents(simc, profile, entries, extra=()):
    text = run(simc, [profile] + list(extra) + ["iterations=1", "debug=1", "max_time=1"])
    if re.search(r"^Error:|is not available", text, re.M):
        return None
    got = []
    hero = re.search(r"activating sub tree (.+?) \(id=\d+\)", text)
    if hero:
        got.append({"tree": "heroTree", "name": hero.group(1), "id": 0, "rank": 1})
    for m in re.finditer(r"adding (\w+) talent (.+?) \(node=\d+ entry=(\d+) rank=(\d+)/\d+\)", text):
        if m.group(1) == "selection":
            continue
        got.append({"tree": m.group(1), "name": m.group(2), "id": entries.get(int(m.group(3)), (0, 0))[1],
                    "rank": int(m.group(4))})
    return got


def fight(simc, profile, targets, seed, known, extra=()):
    text = run(simc, [profile] + list(extra) + ["iterations=1", "log=1", "seed=%d" % seed, "desired_targets=%d" % targets,
                      "max_time=180", "vary_combat_length=0.2"])
    seq, last = [], 0.0
    # the player's own lines: names can hold an apostrophe ("Blood_San'layn"), and copies of the player (Dancing
    # Rune Weapon, images) are logged under the player's name plus a suffix: the shortest name is the player
    rows = re.findall(r"^(\d+\.\d+) Player '(.+?)' performs Action '(\w+)'", text, re.M)
    me = min((r[1] for r in rows), key=len, default=None)
    for t, who, a in rows:
        if who != me:
            continue
        t = float(t)
        if a in SKIP or a not in known:
            continue
        if seq and seq[-1][1] == a and t - seq[-1][0] < 0.6:
            continue  # one press reported in pieces
        seq.append((t, a))
        last = t
    return seq, last


def summarize(fights):
    cpm, pairs, secs = collections.Counter(), collections.Counter(), 0.0
    openers = [collections.Counter() for _ in range(8)]
    for seq, last in fights:
        secs += last
        cpm.update(a for _, a in seq)
        pairs.update("%s>%s" % (a[1], b[1]) for a, b in zip(seq, seq[1:]))
        for i, (_, a) in enumerate(seq[:8]):
            openers[i][a] += 1
    mins = secs / 60.0 or 1
    return {"cpm": {k: round(v / mins, 2) for k, v in cpm.most_common()},
            "opener": [o.most_common(1)[0][0] for o in openers if o],
            "pairs": dict(pairs.most_common(40)), "seconds": round(secs)}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--simc-bin", required=True)
    ap.add_argument("--simc-src", required=True)
    ap.add_argument("--specs")
    ap.add_argument("--fights", type=int, default=20)
    ap.add_argument("--jobs", type=int, default=4)
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    entries = trait_table(args.simc_src)
    sha = subprocess.run(["git", "-C", args.simc_src, "rev-parse", "--short", "HEAD"], capture_output=True,
                         text=True).stdout.strip()
    specs = args.specs.split(",") if args.specs else sorted(
        f[:-4] for f in os.listdir(DATA) if f.endswith(".lua") and f != "Index.lua")
    for spec in specs:
        profile = profile_for(args.simc_src, spec)
        if not profile:
            print("%-26s no SimC profile" % spec)
            continue
        known = tokens_for(spec)
        extra, build = [], "profile"
        tal = talents(args.simc_bin, profile, entries)
        if not tal:
            extra = player_build(spec, entries) or []
            tal = talents(args.simc_bin, profile, entries, extra) if extra else None
            build = "top player (Warcraft Logs)"
        if not tal:
            print("%-26s talents don't load (profile and top player)" % spec)
            continue
        ref = {"spec": spec, "source": "simc", "simc": sha, "profile": os.path.basename(profile), "build": build,
               "talentOptions": extra, "talents": tal, "targets": {}}
        with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
            for tg in (1, 5):
                fights = list(pool.map(lambda s: fight(args.simc_bin, profile, tg, s, known, extra),
                                       range(1, args.fights + 1)))
                ref["targets"][str(tg)] = summarize(fights)
        json.dump(ref, open(os.path.join(OUT, spec + ".json"), "w"), indent=1, sort_keys=True)
        top = ", ".join("%s %.1f" % kv for kv in list(ref["targets"]["1"]["cpm"].items())[:4])
        print("%-26s talents=%d  1 target: %s" % (spec, len(ref["talents"]), top))


if __name__ == "__main__":
    main()
