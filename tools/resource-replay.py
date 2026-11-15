#!/usr/bin/env python3
"""Replay a fight's hidden resource offline and score resource models against the game's own proofs.

Usage: python3 tools/resource-replay.py decoded.json [--fight ID] [--power 8] [--fit] [--show N]

A Watchdog report holds, per fight: every cast of ours (C lines, spell ID), every proc border shown / hidden (G+ /
G-), and every time the game proved our count wrong: floor_raised (it allowed a spender: at least `now`) and
floor_capped (it refused one: at most `now`). That is enough to replay the count without the game: start at the
pull, apply each cast's gain / cost under a model, and check the count against each proof.

A model is: gain per spell, cost per spell, whether a spender cast while lit by its proc is free, and a passive gain
per second. The score is how far the replayed count is from the proofs (short = below a proven minimum, over = above
a proven maximum). --fit searches gains / passive rate / free-when-lit for the best score, so a resource model change
can be tried on recorded fights before anyone plays again (owner, 2026-11-15: "improve the offline testing system so
you can do more without me").

Note: a proof is only as good as the addon's reading of it. A proof from a spender that was free at that moment
(a proc the addon didn't see) says nothing about the resource; the replay lists proofs that no model explains so they
can be looked at one by one.
"""
import itertools
import json
import sys

# Balance's spells (Midnight IDs): what the shipped data says, for the baseline model
BALANCE = {
    "gain": {194153: 12, 190984: 8, 8921: 8, 93402: 6, 202770: 0},  # starfire, wrath, moonfire, sunfire, fury
    "cost": {191034: 45, 78674: 36},  # starfall, starsurge
    "names": {194153: "starfire", 190984: "wrath", 8921: "moonfire", 93402: "sunfire", 202770: "fury_of_elune",
              191034: "starfall", 78674: "starsurge", 102560: "incarnation", 1233272: "eclipse"},
}


def parse_args(argv):
    a = {"file": None, "fight": None, "power": 8, "fit": False, "show": 0}
    i = 1
    while i < len(argv):
        x = argv[i]
        if x == "--fight":
            a["fight"] = argv[i + 1]
            i += 1
        elif x == "--power":
            a["power"] = int(argv[i + 1])
            i += 1
        elif x == "--learn":
            pass
        elif x == "--fit":
            a["fit"] = True
        elif x == "--show":
            a["show"] = int(argv[i + 1])
            i += 1
        else:
            a["file"] = x
        i += 1
    return a


def fields(data):
    if isinstance(data, dict):
        return data
    return dict(x.split("=", 1) for x in str(data).split() if "=" in x)


def timeline(session, power):
    """casts [(t, id, lit)], proofs [(t, kind, value)]"""
    lit, gone = set(), {}
    casts, proofs = [], []
    for e in session["events"]:
        t, k = e[0], e[1]
        if k == "G+":
            lit.add(e[2])
        elif k == "G-":
            lit.discard(e[2])
            gone[e[2]] = t
        elif k == "C":
            sid = e[2]
            was_lit = sid in lit or (sid in gone and t - gone[sid] <= 0.5)
            casts.append((t, sid, was_lit))
        elif k == "D" and e[2] in ("floor_raised", "floor_capped"):
            f = fields(e[3])
            if int(f.get("power", -1)) != power:
                continue
            proofs.append((t, "min" if e[2] == "floor_raised" else "max", float(f["now"]), float(f.get("was", 0))))
    return casts, proofs


def replay(casts, proofs, model, start=0.0, cap=100.0, detail=False):
    """Score a model: sum of distances to the proofs. The count follows the proofs as the addon does (raised to a
    proven minimum, lowered to a proven maximum) so one early error doesn't spoil every later check."""
    events = [(t, 0, c) for c in casts for t in [c[0]]] + [(p[0], 1, p) for p in proofs]
    events.sort(key=lambda x: (x[0], x[1]))
    v, last_t = start, 0.0
    short = over = 0.0
    misses = []
    for t, kind, item in events:
        v = min(cap, v + model["passive"] * (t - last_t))
        last_t = t
        if kind == 0:
            _, sid, lit = item
            v = min(cap, v + model["gain"].get(sid, 0))
            cost = model["cost"].get(sid, 0)
            if lit and model["free_when_lit"]:
                cost = 0
            v = max(0.0, v - cost)
        else:
            _, how, value, was = item
            if how == "min" and v < value:
                short += value - v
                misses.append((t, "short", value - v, v, value))
                v = value
            elif how == "max" and v > value:
                over += v - value
                misses.append((t, "over", v - value, v, value))
                v = value
    return short, over, misses


# --- The addon's in-game fit (Calibrate.lua section 3), emulated: same timelines, same search, same share --------
FIT_MIN, FIT_FIGHTS, FIT_SEEN, FIT_SHARE, FIT_MAX = 20, 3, 3, 0.75, 60
FIT_SWEEPS, FIT_STEP, FIT_RATE_STEP, FIT_RATE_MAX = 2, 2, 0.5, 10
PASSIVE_DATA = 5.133 * 0.6  # Balance's passiveGain from the raid logs, at Clues.PASSIVE_SHARE


def as_timeline(casts, proofs, base):
    """casts -> (t, id, d) with d what our count did (gain - cost charged; free when lit); proofs -> (t, lo, hi)"""
    tc = []
    for t, sid, lit in casts:
        cost = 0 if (lit and sid in base["cost"]) else base["cost"].get(sid, 0)
        tc.append((t, sid, base["gain"].get(sid, 0) - cost))
    tp = [(t, v, -1) if how == "min" else (t, 0, v) for t, how, v, _ in proofs]
    return {"casts": tc, "proofs": tp}


def stray(tl, extra, rate, base_rate, cap=100.0):
    ev = sorted([(c[0], 0, c) for c in tl["casts"]] + [(p[0], 1, p) for p in tl["proofs"]],
                key=lambda x: (x[0], x[1]))
    v = last = err = 0.0
    for t, kind, item in ev:
        v += (base_rate + rate) * (t - last)
        last = t
        if kind == 0:
            v += item[2] + extra.get(item[1], 0)
        else:
            if v < item[1]:
                err, v = err + item[1] - v, item[1]
            elif item[2] >= 0 and v > item[2]:
                err, v = err + v - item[2], item[2]
        v = min(cap, max(0.0, v))
    return err


def fit_timelines(tls, old):
    seen = {}
    for tl in tls:
        for c in tl["casts"]:
            seen[c[1]] = seen.get(c[1], 0) + 1
    ids = sorted(i for i, n in seen.items() if n >= FIT_SEEN)
    extra = {i: (old["w"].get(i, 0) if old else 0) for i in ids}
    rate = old["rate"] if old else 0.0

    def score():
        return sum(stray(tl, extra, rate, PASSIVE_DATA) for tl in tls)
    best = score()
    for _ in range(FIT_SWEEPS):
        for i in ids:
            keep = extra[i]
            for x in range(0, FIT_MAX + 1, FIT_STEP):
                extra[i] = x
                e = score()
                if e < best:
                    best, keep = e, x
            extra[i] = keep
        keep = rate
        r = 0.0
        while r <= FIT_RATE_MAX:
            rate = r
            e = score()
            if e < best:
                best, keep = e, r
            r += FIT_RATE_STEP
        rate = keep
    return {"n": sum(len(tl["proofs"]) for tl in tls), "w": {i: x for i, x in extra.items() if x > 0},
            "rate": rate, "stray": best}


def used(fit):
    """the model as the addon uses it: K.FIT_SHARE of the fit, whole points"""
    if not fit or fit["n"] < FIT_MIN:
        return {}, 0.0
    return ({i: min(FIT_MAX, int(x * FIT_SHARE)) for i, x in fit["w"].items()}, fit["rate"] * FIT_SHARE)


def main():
    a = parse_args(sys.argv)
    if not a["file"]:
        print(__doc__)
        sys.exit(1)
    d = json.load(open(a["file"]))
    sessions = d.get("sessions", [])
    if a["fight"]:
        sessions = [s for s in sessions if str(s.get("id")) == a["fight"]]
    base = {"gain": dict(BALANCE["gain"]), "cost": dict(BALANCE["cost"]), "free_when_lit": False, "passive": 0.0}
    if "--learn" in sys.argv:
        # fights in order, as in game: each counted with what the earlier ones taught (at the addon's share), then
        # added to the last FIT_FIGHTS timelines and fitted again
        tls, fit = [], None
        names = BALANCE["names"]
        for s in sessions:
            casts, proofs = timeline(s, a["power"])
            if not proofs:
                continue
            tl = as_timeline(casts, proofs, base)
            before = stray(tl, {}, 0.0, PASSIVE_DATA)
            ex, rate = used(fit)
            withfit = stray(tl, ex, rate, PASSIVE_DATA)
            tls = (tls + [tl])[-FIT_FIGHTS:]
            fit = fit_timelines(tls, fit)
            learned = " ".join("%s%+d" % (names.get(k, k), x) for k, x in sorted(fit["w"].items(), key=str))
            print("== fight %s: stray from the game's answers - shipped %5.0f | with the fit from earlier fights "
                  "%5.0f\n   fitted now (%d answers): %s rate +%.1f/s (stray %.0f)" % (
                      s.get("id"), before, withfit, fit["n"], learned, fit["rate"], fit["stray"]))
        return
    for s in sessions:
        casts, proofs = timeline(s, a["power"])
        if not proofs:
            continue
        lit_casts = sum(1 for c in casts if c[2] and c[1] in BALANCE["cost"])
        print("== fight %s: %d casts (%d spenders cast while lit), %d proofs" % (s.get("id"), len(casts), lit_casts,
                                                                                 len(proofs)))
        sh, ov, misses = replay(casts, proofs, base)
        print("   shipped model:        short %6.0f  over %6.0f  (%d proofs missed)" % (sh, ov, len(misses)))
        m2 = dict(base, free_when_lit=True)
        sh2, ov2, mi2 = replay(casts, proofs, m2)
        print("   + free when lit:      short %6.0f  over %6.0f  (%d proofs missed)" % (sh2, ov2, len(mi2)))
        if a["fit"]:
            best = None
            for sf, mf, fury, inc, passive, free in itertools.product(range(8, 27, 2), (4, 6, 8, 10),
                                                                     (0, 20, 40), (0, 20, 40), (0, 1, 2, 3, 4, 5, 6),
                                                                     (False, True)):
                m = {"gain": {194153: sf, 190984: 8, 8921: mf, 93402: mf, 202770: fury, 102560: inc},
                     "cost": dict(BALANCE["cost"]), "free_when_lit": free, "passive": passive}
                sh3, ov3, mi3 = replay(casts, proofs, m)
                score = sh3 + ov3
                if best is None or score < best[0]:
                    best = (score, m, sh3, ov3, len(mi3))
            score, m, sh3, ov3, n3 = best
            print("   best fit:             short %6.0f  over %6.0f  (%d proofs missed)" % (sh3, ov3, n3))
            print("     starfire %+d  moonfire/sunfire %+d  fury of elune %+d  incarnation %+d  passive %.0f/s  "
                  "free when lit: %s" % (m["gain"][194153], m["gain"][8921], m["gain"][202770], m["gain"][102560],
                                         m["passive"], m["free_when_lit"]))
            misses = replay(casts, proofs, m)[2]
        for t, how, dist, v, value in misses[:a["show"]]:
            near = [BALANCE["names"].get(c[1], c[1]) + ("*" if c[2] else "") for c in casts if t - 4 <= c[0] <= t]
            print("     %.2f %s by %.0f (count %.0f, proof %.0f) after: %s" % (t, how, dist, v, value, " ".join(near)))


if __name__ == "__main__":
    main()
