#!/usr/bin/env python3
"""Parse SimulationCraft's SpellDataDump/<class>.txt into per-spell facts DMGAssist can use.

SimC dumps every class spell from the game data, e.g.:

    Name             : Tiger's Fury (id=5217) [Spell Family (7)]
    Talent Entry     : Feral [tree=spec, row=1, col=4, max_rank=1, req_points=0]
    Duration         : 10 seconds
    Cooldown         : 30 seconds
    Resource         : 35 Energy (3) (id=143)
    #2 (id=117350)   : Energize Power (30)
                       Base Value: 50 | Scaled Value: 50 | Resource: energy | Target: Self (1)

From that we keep, per spell id: name token (SimC style), cooldown, charges, GCD, duration, cast time, max stacks,
hasted cooldown/GCD flags, resource costs and gains (by WoW power type number), and which auras it applies
(itself, or the spell it triggers) on the player or the target. That gives the addon language-independent spell IDs
and the numbers it needs to predict ahead, instead of learning them in game first.
"""
import re

# SimC resource names (as used in "Resource: x" on effect lines) -> Enum.PowerType values.
POWER = {
    "mana": 0, "rage": 1, "focus": 2, "energy": 3, "combo_points": 4, "rune": 5, "runes": 5, "runic_power": 6,
    "soul_shard": 7, "soul_shards": 7, "astral_power": 8, "lunar_power": 8, "holy_power": 9, "maelstrom": 11,
    "chi": 12, "insanity": 13, "arcane_charges": 16, "fury": 17, "pain": 18, "essence": 19,
}
# Resources whose effect values are stored x10 or x100 in game data (SimC prints raw values).
# Spell data stores some resources in smaller units: rage, runic power, soul shards, astral power in tenths,
# insanity in hundredths (Mind Blast 600 = 6 Insanity, Bloodthirst 80 = 8 Rage). Fury and Maelstrom are whole.
POWER_DIVISOR = {1: 10, 6: 10, 7: 10, 8: 10, 13: 100}

HEADER = re.compile(r"^Name\s*:\s*(.+?) \(id=(\d+)\)\s*(\[(.*)\])?")
FIELD = re.compile(r"^([A-Z][A-Za-z ]*?)\s*:\s?(.*)$")
EFFECT = re.compile(r"^#(\d+) \(id=\d+\)\s*:\s*(.*)$")
SECONDS = re.compile(r"([\d.]+) seconds")
COST = re.compile(r"^([\d.]+)(?: - ([\d.]+))?%? ([A-Za-z ]+?) \((\d+)\)")


def token(name):
    """SimC's util::tokenize: lower case, spaces to underscores, drop everything but [a-z0-9_.]."""
    t = name.strip().lower().replace(" ", "_").replace("-", "_")
    t = re.sub(r"[^a-z0-9_.]", "", t)
    t = re.sub(r"_+", "_", t)
    return t


def _num(s):
    v = float(s)
    return int(v) if v.is_integer() else v


def parse_dump(text):
    """Return {id: spell} for every spell block in a SpellDataDump file."""
    spells = {}
    cur = None
    effect = None
    for raw in text.splitlines():
        line = raw.rstrip()
        m = HEADER.match(line)
        if m:
            flags = m.group(4) or ""
            name = re.sub(r"\s*\(desc=[^)]*\)", "", m.group(1))  # "Disintegrate (desc=Blue)"
            cur = {"id": int(m.group(2)), "name": name, "token": token(name),
                   "passive": "Passive" in flags, "hidden": "Hidden" in flags, "effects": []}
            spells[cur["id"]] = cur
            effect = None
            continue
        if cur is None:
            continue
        # The description runs to the next spell, over several lines and blank lines: Wildfire Infusion's
        # "Kill Command reduces the cooldown of Wildfire Bomb" is its third line, and reading only the first missed it.
        if cur.get("_inDesc"):
            if line.strip():
                cur["desc"] += " " + line.strip()
                cur["descRefs"] = cur.get("descRefs", []) + [int(x) for x in re.findall(r"\$(\d+)d\b", line)]
            else:
                cur["desc"] += " ."  # a paragraph break ends a sentence
            continue
        if not line.strip():
            effect = None
            continue
        m = EFFECT.match(line)
        if m:
            effect = {"n": int(m.group(1)), "text": m.group(2), "detail": ""}
            cur["effects"].append(effect)
            continue
        if raw.startswith(" ") and effect is not None:
            effect["detail"] += " " + line.strip()
            continue
        m = FIELD.match(line)
        if not m:
            continue
        key, val = m.group(1).strip(), m.group(2).strip()
        effect = None
        if key == "Description":
            cur["descRefs"] = [int(x) for x in re.findall(r"\$(\d+)d\b", val)]
            cur["desc"] = val
            cur["_inDesc"] = True
        elif key == "Stance Mask":
            try:
                cur["stanceMask"] = int(val.split()[0], 16)
            except ValueError:
                pass
        elif key == "Class":
            cur["class"] = val.replace(" ", "").lower()  # "Death Knight" -> "deathknight"
        elif key == "Talent Entry":
            cur["talent"] = re.sub(r"\s*\(.*?\)", "", val.split(" [")[0]).strip()
            tree = re.search(r"tree=(\w+)", val)
            if tree:
                cur["talentTree"] = tree.group(1)
        elif key == "Duration":
            s = SECONDS.search(val)
            if s:
                cur["duration"] = _num(s.group(1))
        elif key in ("Cooldown", "Category Cooldown"):
            s = SECONDS.search(val)
            if s:
                cur["cooldown"] = max(cur.get("cooldown", 0), _num(s.group(1)))
        elif key == "Charges":
            c = re.match(r"(\d+) \(([\d.]+) seconds cooldown\)", val)
            if c:
                cur["charges"] = int(c.group(1))
                cur["chargeCooldown"] = _num(c.group(2))
        elif key == "GCD":
            s = SECONDS.search(val)
            if s:
                cur["gcd"] = _num(s.group(1))
        elif key == "Range":
            r = re.search(r"([\d.]+) yards", val)  # "5 yards", "8 - 40 yards": the max range is what matters
            nums = re.findall(r"[\d.]+", val)
            if r and nums:
                cur["range"] = _num(nums[-1])
        elif key == "Cast Time":
            s = SECONDS.search(val)
            if s:
                cur["castTime"] = _num(s.group(1))
        elif key == "Stacks":
            s = re.search(r"(\d+) maximum", val)
            if s:
                cur["stacks"] = int(s.group(1))
        elif key == "Resource" and val.startswith("-"):
            # A negative cost is a gain: rune spells give Runic Power this way ("-10 Runic Power (6)"), and
            # "w/ Unholy Death Knight" limits it to that spec. Unread, Unholy's Runic Power was counted from
            # Festering Strike alone and Death Coil waited 26 s (2026-11-12).
            c = COST.match(val[1:])
            if c and "%" not in val.split("(")[0]:
                pt, amount = int(c.group(4)), _num(c.group(1))
                w = re.search(r"\) w/ (.+?) \(id=", val)
                if w:
                    cur.setdefault("gainSpec", {}).setdefault(w.group(1), {})[pt] = amount
                else:
                    cur.setdefault("costGain", {})[pt] = amount
        elif key == "Resource":
            c = COST.match(val)
            if c and "%" not in val.split("(")[0]:
                pt = int(c.group(4))
                amount = _num(c.group(1))
                cur.setdefault("cost", {})[pt] = amount
                if c.group(2):  # "1 - 5 Combo Points": finishers spend up to the max
                    cur.setdefault("costMax", {})[pt] = _num(c.group(2))
        elif key == "Attributes":
            if "Hasted Cooldown Duration" in val:
                cur["hastedCooldown"] = True
            if "Hasted Global Cooldown" in val:
                cur["hastedGcd"] = True
            if "Is Channelled" in val:
                cur["channel"] = True  # Game mode's hold bar: a channel lasts its Duration
    _baseline_energize(spells)
    _cooldown_links(spells)
    for s in spells.values():
        s["effects_raw"] = list(s["effects"])  # kept for tools/simc_modules.py (talent amounts)
        _effects(s)
    _description_auras(spells)
    return spells


def _description_auras(spells):
    """A castable spell that applies nothing in its effects but whose description quotes another spell's
    duration ("Enter a Lunar Eclipse, empowering Starfire for $48518d") applies that aura: Lunar Eclipse
    1233272 -> Eclipse (Lunar) 48518. Only self-auras with a duration and the same name words count."""
    for s in spells.values():
        refs = s.pop("descRefs", [])
        if s["passive"] or s.get("aura") or s.get("triggers"):
            continue
        words = set(s["token"].split("_"))
        # Only the same name in other words ("Lunar Eclipse" / "Eclipse (Lunar)"): descriptions also quote
        # random or conditional buffs (Elemental Blast's three), which a cast does not always apply.
        found = [(r, "self") for r in refs
                 if r in spells and r != s["id"] and spells[r].get("duration") and spells[r].get("aura") == "self"
                 and set(spells[r]["token"].split("_")) == words]
        if found:
            s["triggers"] = found


# Spell interdependencies from the game's own spell descriptions (numbers from the spell's effects), e.g.
#   "... reducing the cooldown of Holy Shock by ${$s4/1000}.1 sec"                     cast -> flat reduction
#   "Holy Shock reduces the cooldown of Judgment by ${$m1/-1000}.1 sec" (a talent)       named source
#   "... reduces the cooldown of Adrenaline Rush by ${$s1/100}.1 sec per combo point spent" per resource spent
#   "... resets the cooldown of X" / "... grants a charge of X"                         reset / one charge
# Chance-based, crit-based and conditional ones can't be predicted and are skipped (the runtime's safety nets
# cover them). Every pull lists the links that changed and the mentions we couldn't turn into a rule (review).
NAME = r"[A-Z][A-Za-z':\- ]*?"
CD_LINK = re.compile(
    r"(?:(?P<subj>" + NAME + r") )?(?:reduces|reducing|reduce|decreases|decreasing) the (?:remaining )?"
    r"(?:cooldown|recharge time)s? (?:of|on) (?P<target>" + NAME + r") by (?:an additional )?"
    r"(?P<val>\$\{[^}]*\}(?:\.\d)?|\$[sm]\d+|\d+(?:\.\d+)?)(?: sec| seconds)")
# passive voice: "Lay on Hands' cooldown is reduced by X sec per Holy Power spent",
# "The remaining cooldown on Deathmark is reduced by X sec for every N Energy you expend"
CD_PASSIVE = re.compile(r"(?:[Tt]he (?:remaining )?cooldown (?:of|on) (?P<target>" + NAME + r")|(?P<target2>" + NAME + r")(?:'s|')"
                        r" (?:remaining )?cooldown) is reduced by (?:an additional )?"
                        r"(?P<val>\$\{[^}]*\}(?:\.\d)?|\$[sm]\d+|\d+(?:\.\d+)?)(?: sec| seconds)")
CD_RESET = re.compile(r"(?:(?P<subj>" + NAME + r") )?(?:resets|resetting|reset) the (?:remaining )?cooldown (?:of|on) "
                      r"(?P<target>" + NAME + r")(?=[ .,;]|$)")
CD_CHARGE = re.compile(r"(?:(?P<subj>" + NAME + r") )?(?:grants|granting|grant|gains|gain) (?:you )?(?:a|an additional|one|1) "
                       r"charge of (?P<target>" + NAME + r")(?=[ .,;]|$)")
SPEND_UNITS = {"combo point": 4, "holy power": 9, "rage": 1, "runic power": 6, "energy": 3, "focus": 2, "chi": 12,
               "insanity": 13, "astral power": 8, "maelstrom": 11, "fury": 17, "soul shard": 7, "essence": 19}
UNIT = r"(combo points?|holy power|rage|runic power|energy|focus|chi|insanity|astral power|maelstrom|fury|soul shards?|essence)"
PER_SPENT = re.compile(r"per " + UNIT + r" (?:you )?(?:spen[dt]|expend)|each " + UNIT + r" (?:you )?(?:spen[dt]|expend)", re.I)
EVERY_SPENT = re.compile(r"(?:every|each) (\$\{?\$?[^ ]+|\d+) " + UNIT + r" (?:you )?(?:spen[dt]|expend)", re.I)
VALUE_REF = re.compile(r"\$([sm])(\d+)(?:\s*/\s*(-?\d+))?")
CD_LINK_UNSURE = re.compile(r"chance|critical|crit\b|consuming|when you (?:are|take)|damage taken|\b(?:kills?|killing|killed) (?:an?|the|your|enemies|enemy|target)|\bdies\b|absorb|"
                            r"interrupts|dodge|parr|\$\?", re.I)
STATIC_CD = re.compile(r"reduced cooldown|cooldown (?:is )?reduced by|(?:reduces|increases) the cooldown of|"
                       r"cooldown of .* (?:is )?(?:reduced|increased)|additional charge|maximum charges|max charges|"
                       r"(?:reduces|increases) the (?:recharge|cooldown)", re.I)
CD_MENTION = re.compile(r"cooldown|recharge|charge of", re.I)


def _unit(name):
    name = name.lower().rstrip("s") if name.lower().endswith("points") or name.lower().endswith("shards") else name.lower()
    return SPEND_UNITS.get(name)


PER_TARGET = re.compile(r"for each (?:enemy|target|enemies) (?:hit|struck|damaged)", re.I)
UP_TO = re.compile(r"up to (\$\{[^}]*\}(?:\.\d)?|\$[sm]\d+|\d+(?:\.\d+)?) sec")


def _expr_value(spell, expr):
    """'${$s1/1000*$s2}' -> number, from the spell's effect base values (plain arithmetic only)."""
    body = (expr or "").strip()
    if body.startswith("${"):
        body = body[2:body.index("}")]
    def val(m):
        for e in spell["effects"]:
            if e["n"] == int(m.group(2)):
                v = re.search(r"Base Value: (-?[\d.]+)", e["detail"])
                return v.group(1) if v else "0"
        return "0"
    body = re.sub(r"\$([sm])(\d+)", val, body)
    if not re.fullmatch(r"[\d.+\-*/() ]+", body):
        return None
    try:
        v = abs(float(eval(body, {"__builtins__": {}}, {})))  # digits and operators only (checked above)
    except Exception:
        return None
    return v / 1000.0 if v >= 100 else v


def _cooldown_links(spells):
    """Sets spell["cdLinks"] = [(source_token or "*", target_token, seconds, requires_id or 0, power_type or 0)]
    on the spell whose description carries the rule. seconds: per unit spent when power_type is set; "reset"
    = the whole cooldown; "charge" = one charge back. Unhandled mentions go to spell["cdUnclear"]."""
    names = {s["name"].lower(): s for s in spells.values() if not s["passive"]}

    def spell_named(text):
        words = (text or "").strip().split()
        for i in range(len(words)):
            cand = names.get(" ".join(words[i:]).lower())
            if cand:
                return cand
        return None

    for s in spells.values():
        desc = s.get("desc") or ""
        links, unclear = [], []
        for sentence in re.split(r"(?<=[.!])\s+", desc):
            # a talent-dependent add-on ("...mana.$?a386568[...]") is not part of the base rule
            if not sentence.startswith("$?"):
                sentence = sentence.split("$?")[0]
            if not CD_MENTION.search(sentence):
                continue
            found_any = False
            unsure = CD_LINK_UNSURE.search(sentence)
            per = PER_SPENT.search(sentence)
            every = EVERY_SPENT.search(sentence)
            spend_pt, spend_div = 0, 1.0
            if per:
                spend_pt = _unit(per.group(1) or per.group(2))
            elif every:
                spend_pt = _unit(every.group(2))
                n = every.group(1)
                if n.isdigit():
                    spend_div = float(n)
                else:
                    v = _link_value(s, n, raw=True)
                    spend_div = v if v else 0
            for kind, rx in (("flat", CD_LINK), ("flat", CD_PASSIVE), ("reset", CD_RESET), ("charge", CD_CHARGE)):
                for m in rx.finditer(sentence):
                    gd = m.groupdict()
                    tname = gd.get("target") or gd.get("target2") or ""
                    if rx is CD_PASSIVE and not (per or every):
                        continue  # a permanent change: the game's own numbers include it
                    target = names.get(tname.strip().lower())
                    if not target:
                        continue
                    subj = (gd.get("subj") or "").strip()
                    source, req = s, 0
                    if subj and subj.lower() != s["name"].lower():
                        named = spell_named(subj)
                        if named:
                            source = named
                            req = s["id"] if (s["passive"] or s.get("talent")) else 0
                        elif not spend_pt:
                            continue
                    elif s["passive"] and not spend_pt:
                        found_any = True  # a passive changing a cooldown for good: the game's own numbers include it
                        continue
                    if unsure:
                        found_any = True  # deliberately not modelled (chance / crit / conditional)
                        continue
                    if kind == "flat":
                        seconds = _link_value(s, m.group("val"))
                        if not seconds or not (0 < seconds <= 120):
                            continue
                        if spend_pt:
                            if not spend_div:
                                continue
                            seconds = round(seconds / spend_div, 3)
                    else:
                        seconds = kind
                    # "... by 2.0 sec for each enemy hit, up to 10 sec" (Lethal Calibration): per target, with a cap
                    per_target = isinstance(seconds, float) or isinstance(seconds, int)
                    per_target = per_target and PER_TARGET.search(sentence) is not None
                    cap = None
                    if per_target:
                        upto = UP_TO.search(sentence)
                        cap = _expr_value(s, upto.group(1)) if upto else None
                    src = "*" if (spend_pt and (source is s and s["passive"] or not subj)) else source["token"]
                    if src != "*" and src == target["token"]:
                        continue
                    row = (src, target["token"], seconds, req if src != "*" else s["id"] if s["passive"] or s.get("talent") else 0,
                           spend_pt or 0)
                    if per_target:
                        row = row + (round(cap, 3) if cap else round(seconds * 5, 3),)  # 6th: per target hit, cap
                    links.append(row)
                    found_any = True
            if not found_any and s["passive"] and STATIC_CD.search(sentence) and not (per or every):
                found_any = True  # "X has 30% reduced cooldown": permanent, in the game's own numbers
            if not found_any and unsure:
                found_any = True  # chance / crit / conditional: not predictable, left to the runtime's safety nets
            if not found_any:
                unclear.append(sentence.strip()[:200])
        if links:
            s["cdLinks"] = links
        if unclear:
            s["cdUnclear"] = unclear


def links_for(spells, ids, extra=()):
    """The class's interdependency rules that touch this spec's spells: (links, review sentences).
    extra: hand-written rules for the class from data/spell-links.json (wording the description reader can't parse)."""
    actions = set(ids)
    names = {s["name"].lower() for s in spells.values() if s["token"] in actions and not s["passive"]}
    links, review = [], []
    for s in sorted(spells.values(), key=lambda x: x["id"]):
        for link in s.get("cdLinks", []):
            src, target = link[0], link[1]
            if target in actions and (src == "*" or src in actions):
                row = list(link)
                if row not in links:
                    links.append(row)
        for sentence in s.get("cdUnclear", []):
            if any(sentence.startswith(x.get("covers", "\0")) for x in extra if isinstance(x, dict)):
                continue  # a hand-written rule covers it
            low = sentence.lower()
            if any(n in low for n in names):
                review.append(f"{s['name']} ({s['id']}): {sentence}")
    def action_for(tok):
        # SimC's code names an action's struct a little differently at times ("bomb" for wildfire_bomb)
        if tok == "*" or tok in actions:
            return tok
        hits = [a for a in actions if a.endswith("_" + tok) or a.startswith(tok + "_")]
        return hits[0] if len(hits) == 1 else None

    seen = {(l[0], l[1]) for l in links}
    for x in extra:
        row = [x["source"], x["target"], x["seconds"], x.get("requires", 0), x.get("power", 0)] if isinstance(x, dict) else list(x)
        if isinstance(x, dict) and x.get("perTargetCap"):
            row.append(x["perTargetCap"])
        src, dst = action_for(row[0]), action_for(row[1])
        if not (src and dst):
            continue
        row[0], row[1] = src, dst
        if (src, dst) in seen:
            # the class module's version wins over the description's (it knows per-target caps and talents)
            links[:] = [l for l in links if (l[0], l[1]) != (src, dst)]
        seen.add((src, dst))
        links.append(row)
    return links, review


# "Casting Starfall extends the duration of active Moonfires and Sunfires by ${$s1}.1 sec, up to $s2 sec."
# (Aetherial Kindling): a cast that lengthens auras already running. Without it Balance was shown Sunfire 3.7 times
# a minute where SimC with the same talents casts it 0.4 (Starfall keeps it up; 2026-11-14).
EXTEND = re.compile(r"(?:^|[.!]\s*|\s)(?:Casting |Each (?:cast of |blast of )?|During [A-Z][A-Za-z' ]*? )?(?P<src>(?:Your )?[A-Z][A-Za-z':\- ]*?)"
                    r"(?: will)? extends? the (?:remaining )?duration of (?:an? )?(?:active )?(?:your )?(?P<targets>[A-Z][A-Za-z':, -]*?)"
                    r"(?: on [a-z][a-z ]*?)? by (?P<val>\$\{[^}]*\}(?:\.\d)?|\$[sm]\d+|\d+(?:\.\d+)?) sec(?:onds)?"
                    r"(?:, up to (?:a maximum of )?(?P<cap>\$\{[^}]*\}|\$s\d+|\d+(?:\.\d+)?) sec)?")
FINISHERS = re.compile(r"^(?:your )?finishing moves?$", re.I)


def _value(sp, raw):
    if not raw:
        return 0
    if raw.startswith("${"):
        return _expr_value(sp, raw.split("}")[0] + "}")
    return _link_value(sp, raw)


def aura_links(spells, ids, known=()):
    """[source token, aura token, seconds, requires spell ID (0 = none), cap seconds (0 = none)] for this spec's
    spells: casting the source lengthens the target aura while it runs, its remaining time capped at cap. Source
    "*finisher": any finishing move. Wordings that name a spell through a talent switch ($?s123[A][B]) are left out."""
    actions = set(ids)
    by_name = {}
    for sp in spells.values():
        by_name.setdefault(sp["name"].lower(), sp)

    def named(name):
        name = name.strip()
        low = name.lower()
        if low.startswith("your "):
            low = low[5:]
        return by_name.get(low) or (low.endswith("s") and by_name.get(low[:-1])) or None

    out = []
    for sp in sorted(spells.values(), key=lambda x: x["id"]):
        if "effects" not in sp and "effects_raw" not in sp:
            continue
        sp = dict(sp, effects=sp.get("effects") or sp.get("effects_raw"))
        desc = sp.get("desc") or ""
        for m in EXTEND.finditer(desc):
            if "$?" in m.group(0):
                continue
            sec = _value(sp, m.group("val"))
            cap = _value(sp, m.group("cap")) if m.group("cap") else 0
            if not sec:
                continue
            srcs = []
            for part in re.split(r"\s+and\s+|,\s*", m.group("src")):
                if FINISHERS.match(part.strip()):
                    srcs.append("*finisher")
                else:
                    hit = named(part)
                    if hit and hit["token"] in actions:
                        srcs.append(hit["token"])
            targets = [named(n) for n in re.split(r",\s*(?:and\s+)?|\s+and\s+", m.group("targets"))]
            # "... by 0.5 sec per combo point spent": seconds per point (power type 4) of a finisher
            per_point = 4 if re.match(r"\s*(?:per|for each) combo point", desc[m.end():]) else 0
            for src in srcs:
                for tgt in targets:
                    if tgt and (tgt["token"] in actions or tgt["token"] in known):
                        row = [src, tgt["token"], round(sec, 3), sp["id"] if sp["passive"] else 0, round(cap or 0, 3)]
                        if per_point:
                            row.append(per_point)
                        if row not in out and src != tgt["token"]:
                            out.append(row)
    return out


def _link_value(spell, expr, raw=False):
    if re.fullmatch(r"\d+(?:\.\d+)?", expr or ""):
        return float(expr)
    m = VALUE_REF.search(expr or "")
    if not m:
        return None
    index, div = int(m.group(2)), m.group(3)
    for e in spell["effects"]:
        if e["n"] == index:
            v = re.search(r"Base Value: (-?[\d.]+)", e["detail"])
            if not v:
                return None
            value = float(v.group(1))
            if raw:
                return abs(value)
            if div:
                value = value / float(div)
            elif abs(value) >= 100:
                value = value / 1000.0  # milliseconds
            return round(abs(value), 3)
    return None


FLAT_EFFECT = re.compile(r"Add Flat Modifier \(107\): Spell Effect (\d+)")
AFFECTED = re.compile(r"Affected Spells: (.*?)(?:\s+Family Flags|\s+Modified By|$)")


def _baseline_energize(spells):
    """A spec's built-in passive (no talent needed) can set another spell's resource gain: Balance's hidden
    "Astral Power" (197911) adds 60 (6 Astral Power) to Wrath's and Moonfire/Sunfire's energize effects, whose
    own base value is 0. Fold those into the energize effect so the gain is known. Talents are left out, so
    the gain we know never exceeds the real one."""
    for p in spells.values():
        if not p["passive"] or p.get("talent"):
            continue
        for e in p["effects"]:
            m = FLAT_EFFECT.search(e["text"])
            v = re.search(r"Base Value: (-?[\d.]+)", e["detail"])
            a = AFFECTED.search(e["detail"])
            if not (m and v and a):
                continue
            index, amount = int(m.group(1)), _num(v.group(1))
            for sid in re.findall(r"\((\d+)\)", a.group(1)):
                target = spells.get(int(sid))
                for te in (target or {}).get("effects", []):
                    if te.get("n") == index and te["text"].startswith("Energize Power"):
                        te["detail"] = re.sub(r"Base Value: (-?[\d.]+)",
                                              lambda b: "Base Value: %g" % (_num(b.group(1)) + amount),
                                              te["detail"], count=1)


def _effects(spell):
    applies_self = applies_enemy = False
    triggers = []
    gains = {}
    for e in spell.pop("effects"):
        text, detail = e["text"], e["detail"]
        target_self = "Target: Self" in detail or "Target: Caster" in detail
        target_enemy = "Enemy" in detail
        if text.startswith("Apply Aura") or text.startswith("Apply Area Aura"):
            if target_self:
                applies_self = True
            elif target_enemy:
                applies_enemy = True
        if text.startswith("Trigger Spell"):
            t = re.search(r"Trigger Spell: (\d+)", detail)
            if t:
                triggers.append((int(t.group(1)), "self" if target_self else ("enemy" if target_enemy else None)))
        if text.startswith("Energize Power"):
            r = re.search(r"Resource: ([a-z_]+)", detail)
            v = re.search(r"Base Value: (-?[\d.]+)", detail)
            if r and v and r.group(1) in POWER:
                pt = POWER[r.group(1)]
                gains[pt] = gains.get(pt, 0) + _num(v.group(1)) / POWER_DIVISOR.get(pt, 1)
    if applies_self:
        spell["aura"] = "self"
    elif applies_enemy:
        spell["aura"] = "enemy"
    if triggers:
        spell["triggers"] = triggers
    gains = {k: v for k, v in gains.items() if v}
    if gains:
        spell["gain"] = {k: (int(v) if float(v).is_integer() else v) for k, v in gains.items()}


# ---------------------------------------------------------------------------
# Choosing ids for the names a priority list uses
# ---------------------------------------------------------------------------
# SimC-only names -> game spell names (tokens) to try.
ALIASES = {
    "bs_inc": ["incarnation_avatar_of_ashamane", "berserk"],
    "ca_inc": ["incarnation_chosen_of_elune", "celestial_alignment"],
    "incarnation": ["incarnation_avatar_of_ashamane", "incarnation_chosen_of_elune", "incarnation_guardian_of_ursoc",
                    "incarnation_tree_of_life"],
    "bloodlust": ["bloodlust", "heroism", "time_warp", "primal_rage", "fury_of_the_aspects"],
}
# Aura-only aliases (actions use UNLOCKS): SimC's buff.eclipse is the Lunar or Solar Eclipse buff.
AURA_ALIASES = {
    "eclipse": ["eclipse_lunar", "eclipse_solar"],
}
# SimC actions whose name is only a passive talent in the game data; the buttons are these spells instead
# (Midnight Balance: the Eclipse talent 1239669 gives Lunar Eclipse 1233272 / Solar Eclipse 1233346).
UNLOCKS = {
    "eclipse": ["lunar_eclipse", "solar_eclipse"],
}
# SimC actions that need a talent the action's own spell doesn't carry (SimC checks it in the action's ready()):
# Feral's moonfire_cat is Lunar Inspiration's Moonfire; without the talent, the Moonfire button is the caster
# Moonfire, which leaves Cat Form.
REQUIRES = {
    "moonfire_cat": "lunar_inspiration",
}
SUFFIXES = ("_cat", "_bear", "_dot", "_debuff", "_buff", "_aoe", "_st")
# Shapeshift suffixes: SimC's moonfire_cat is the Moonfire castable in Cat Form (155625, Lunar Inspiration), not
# the caster Moonfire (8921) that shares its name and would take the player out of the form. The game data's
# "Stance Mask" says which forms a spell works in: bit (form index - 1); Cat Form is 1, Bear Form 5.
FORM_BITS = {"_cat": 0x1, "_bear": 0x10}


def form_ok(tok, s):
    """A spell that shares the base name is only a candidate for a form-suffixed action if it works in that form."""
    if s.get("class") != "druid":
        return True  # druid forms only (a hunter's howl_of_the_pack_leader_bear is a buff, not a form)
    for suf, bit in FORM_BITS.items():
        if tok.endswith(suf) and s["token"] != tok:
            return bool(s.get("stanceMask", 0) & bit)
    return True


def candidates(tok):
    out = [tok] + ALIASES.get(tok, [])
    for suf in SUFFIXES:
        if tok.endswith(suf):
            out.append(tok[: -len(suf)])
    return out


def index_by_token(spells):
    by = {}
    for s in spells.values():
        by.setdefault(s["token"], []).append(s)
    return by


def _castable_rank(s, other_specs):
    """Lower is better for an action: castable, not another spec's talent, has real data."""
    return (
        s["passive"] or s["hidden"],
        s.get("talent") in other_specs,
        not (s.get("gcd") is not None or s.get("cooldown") or s.get("cost")),
        -s.get("rank", 0),  # ranked spells (Forever): highest rank first; the addon picks the best one known
        s["id"],
    )


def _aura_rank(s):
    """Lower is better for a buff/debuff: has a duration, is not a talent passive."""
    return (s.get("duration") is None, bool(s.get("talent")) and s["passive"], -s.get("rank", 0), s["id"])


MAX_IDS = 12  # ranked spells (Forever) can have up to ~10 ranks


def _gain(s, this_spec):
    """Energize effects first; a negative cost adds what they don't cover (for this spec, when qualified)."""
    gain = dict(s.get("gain") or {})
    extra = dict(s.get("costGain") or {})
    for who, g in (s.get("gainSpec") or {}).items():
        if this_spec and who.startswith(this_spec + " "):
            extra.update(g)
    for pt, amount in extra.items():
        gain.setdefault(pt, amount)
    return gain


def select(spells, refs, other_specs=(), this_spec=None):
    """refs: {"action": set(tokens), "aura": set(tokens), "talent": set(tokens)}.
    Returns (ids_by_token, info_by_id) with only what the spec's lists reference."""
    by = index_by_token(spells)
    ids, keep = {}, set()
    refs = dict(refs)
    refs["talent"] = set(refs.get("talent", set())) | {REQUIRES[t] for t in refs.get("action", set()) if t in REQUIRES}

    def pick(tok, rank, want=lambda s: True, action=False):
        found = []
        for c in candidates(tok):
            for s in sorted(by.get(c, []), key=rank):
                if want(s) and (not action or form_ok(tok, s)) and s["id"] not in found:
                    found.append(s["id"])
        return found[:MAX_IDS]

    for tok in sorted(refs["action"]):
        f = pick(tok, lambda s: _castable_rank(s, other_specs), action=True)
        if f and all(spells[i]["passive"] for i in f):
            # Only a passive talent carries this name: the buttons are the castable spells it unlocks.
            unlocked = [i for u in UNLOCKS.get(tok, []) for i in pick(u, lambda s: _castable_rank(s, other_specs))
                        if not spells[i]["passive"]]
            if unlocked:
                f = (unlocked + f)[:MAX_IDS]
        if f:
            ids.setdefault(tok, {})["a"] = f
            keep.update(f)
            if tok in REQUIRES:
                ids[tok]["req"] = REQUIRES[tok]
    for tok in sorted(refs["aura"]):
        f = pick(tok, _aura_rank)
        for alias in AURA_ALIASES.get(tok, []):
            for i in pick(alias, _aura_rank):
                if i not in f:
                    f.append(i)
        if f:
            ids.setdefault(tok, {})["b"] = f
            keep.update(f)
    for tok in sorted(refs["talent"]):
        f = pick(tok, lambda s: (not s.get("talent"), s["id"]), lambda s: bool(s.get("talent")) or s["passive"])
        if f:
            ids.setdefault(tok, {})["t"] = f
            keep.update(f)

    # Auras applied by kept spells (directly or through triggered spells) are needed for prediction.
    for sid in list(keep):
        for tid, _ in spells[sid].get("triggers", []):
            if tid in spells and spells[tid].get("duration"):
                keep.add(tid)

    info = {}
    for sid in sorted(keep):
        s = spells[sid]
        rec = {"n": s["token"]}
        for src, dst in (("cooldown", "cd"), ("charges", "ch"), ("chargeCooldown", "chcd"), ("gcd", "gcd"),
                         ("duration", "d"), ("castTime", "ct"), ("stacks", "st")):
            if s.get(src) is not None:
                rec[dst] = s[src]
        # Range in yards for targeted spells (100+ yards = self/unlimited, useless for distance).
        if s.get("range") and 0 < s["range"] <= 60 and not s["passive"]:
            rec["r"] = s["range"]
        if s.get("hastedCooldown"):
            rec["hc"] = True
        if s.get("hastedGcd"):
            rec["hg"] = True
        if s.get("channel"):
            rec["chan"] = True
        if s.get("cost"):
            rec["cost"] = dict(sorted(s["cost"].items()))
        if s.get("costMax"):
            rec["cmax"] = dict(sorted(s["costMax"].items()))
        gain = _gain(s, this_spec)
        if gain:
            rec["gain"] = dict(sorted(gain.items()))
        applies = []
        if s.get("aura") and s.get("duration"):
            applies.append([sid, s["aura"]])
        for tid, target in s.get("triggers", []):
            t = spells.get(tid)
            if t and t.get("duration") and t.get("aura"):
                applies.append([tid, t["aura"]])
        if applies:
            rec["ap"] = applies
        if s.get("talent"):
            rec["tal"] = True
        if s["passive"]:
            rec["pas"] = True
        info[sid] = rec
    return ids, info


INTERRUPTS = {"kick", "counterspell", "pummel", "wind_shear", "mind_freeze", "skull_bash", "solar_beam", "rebuke",
              "spear_hand_strike", "disrupt", "counter_shot", "muzzle", "silence", "quell", "spell_lock", "axe_toss"}

DEFENSIVES = {"barkskin", "survival_instincts", "frenzied_regeneration", "renewal", "antimagic_shell",
              "icebound_fortitude", "vampiric_blood", "lichborne", "blur", "fiery_brand", "netherwalk", "darkness",
              "obsidian_scales", "renewing_blaze", "exhilaration", "survival_of_the_fittest", "aspect_of_the_turtle",
              "ice_barrier", "blazing_barrier", "prismatic_barrier", "mirror_image", "alter_time", "ice_block",
              "fortifying_brew", "diffuse_magic", "dampen_harm", "touch_of_karma", "divine_protection",
              "shield_of_vengeance", "ardent_defender", "guardian_of_ancient_kings", "divine_shield",
              "desperate_prayer", "dispersion", "fade", "crimson_vial", "feint", "evasion", "cloak_of_shadows",
              "astral_shift", "dark_pact", "unending_resolve", "ignore_pain", "die_by_the_sword",
              "enraged_regeneration", "shield_wall", "last_stand"}

REF_PATTERNS = {
    "aura": re.compile(r"\b(?:buff|debuff|dot|active_dot)\.([a-z0-9_]+)"),
    "action": re.compile(r"\b(?:cooldown|action|known|casting|prev_gcd\.\d+|prev|prev_off_gcd\.\d+|prev_off_gcd)"
                         r"\.([a-z0-9_]+)"),
    "talent": re.compile(r"\btalent\.([a-z0-9_]+)"),
    "hero": re.compile(r"\bhero_tree\.([a-z0-9_]+)"),
}


def references(lists_list):
    """Collect spell names referenced by APL lists (actions and expression terms)."""
    refs = {"action": set(), "aura": set(), "talent": set(), "hero": set()}
    for lists in lists_list:
        for entries in lists.values():
            for e in entries:
                refs["action"].add(e["a"])
                texts = [e.get("c") or ""] + [str(v) for v in (e.get("p") or {}).values()]
                for text in texts:
                    for kind, pat in REF_PATTERNS.items():
                        for m in pat.finditer(text):
                            refs[kind].add(m.group(1))
    # Interrupts are rarely in SimC's lists but the HUD's interrupt reminder needs their IDs (any language).
    refs["action"] |= INTERRUPTS | DEFENSIVES
    # Buffs/dots are often named after the spell that applies them: make the action ids available too.
    refs["action"] |= {t for t in refs["aura"]}
    return refs


def hero_trees(spells, refs_hero, limit=12):
    """Hero tree name token -> ids of talents in that hero tree (any of them taken = the tree is active)."""
    out = {}
    for s in sorted(spells.values(), key=lambda x: x["id"]):
        if s.get("talentTree") == "hero":
            tok = token(s["talent"])
            if tok in refs_hero:
                lst = out.setdefault(tok, [])
                if len(lst) < limit:
                    lst.append(s["id"])
    return out
