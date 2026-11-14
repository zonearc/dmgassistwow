#!/usr/bin/env python3
"""Import SimulationCraft priority lists into DMGAssist data tables.

Reads, for each branch (midnight, forever):
    <simc>/<branch>/ActionPriorityLists/default/<class>_<spec>.simc          SimC APL
    <simc>/<branch>/ActionPriorityLists/assisted_combat/<class>_<spec>.simc  Blizzard's Assisted Combat rules

Writes:
    addons/DMGAssist/Data/<branch>/<class>_<spec>.lua   data only (no code), loaded per game type
    addons/DMGAssist/Data/<branch>/Index.lua            list of specs + source commit
    docs/coverage/<branch>.md                           readability report per spec
    data/coverage-<branch>.json                         same, machine readable (diffed by the weekly sync)
    --summary FILE                                      markdown summary of what changed (PR body)

Every condition is parsed with a SimC expression parser; every term is classified by how DMGAssist can know it
in combat (see docs/design/engine-priority.md). Classes are planning estimates until confirmed by Watchdog probes.

Usage: python3 tools/simc_import.py --simc .libraries/simc [--out .] [--summary path]
"""
import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import simc_spells
import simc_modules  # noqa: E402
import gamedata_spells  # noqa: E402
import wowsims_apl  # noqa: E402

# WoW Forever rotations from WoWSims (github.com/wowsims/forever, MIT): spec key -> list file under ui/specs/.
# SimC's forever branch only ships copies of the Midnight lists, so these win wherever they exist.
WOWSIMS_FOREVER = {
    "druid_feral": "druid/feralcat/apls/adaptive.apl.json",
    "druid_guardian": "druid/feralbear/apls/adaptive.apl.json",
    "druid_balance": "druid/balance/apls/default.apl.json",
    "warrior_arms": "warrior/dps/apls/arms.apl.json",
    "warrior_fury": "warrior/dps/apls/fury.apl.json",
    "warrior_protection": "warrior/protection/apls/default.apl.json",
    "mage_arcane": "mage/dps/apls/arcane.apl.json",
    "mage_fire": "mage/dps/apls/deepFire.apl.json",
    "mage_frost": "mage/dps/apls/frost.apl.json",
    "rogue_assassination": "rogue/dps/apls/default.apl.json",
    "rogue_outlaw": "rogue/dps/apls/default.apl.json",
    "rogue_subtlety": "rogue/dps/apls/default.apl.json",
}
# Records that switch to another record while a form is active (Forever Feral: cat list, bear list in Bear Form).
ALTERNATES = {("forever", "druid_feral"): {"key": "druid_guardian", "form": 5, "probe": "maul"}}
WOWSIMS_CREDIT = "WoWSims (wowsims.com/forever)"

BRANCHES = ("midnight", "forever")

# ---------------------------------------------------------------------------
# APL parsing
# ---------------------------------------------------------------------------
LINE_RE = re.compile(r"^actions(?:\.([A-Za-z0-9_]+))?(\+?=)/?(.*)$")
EXCLUDED_MARK = "not included in the game's Assisted Combat system"



REVIEW_MODULE = re.compile(r"^\S+:\d+ (\w+) -> (\w+): (.*)$")
REVIEW_DESC = re.compile(r"^.+? \((\d+)\): .*?cooldown (?:recovery rate )?(?:of|on) ([A-Z][\w' ]+?)(?= by| is|[.,]| for| increased|$)")


def volatile_targets(review, ids, info, simc):
    """Spells whose cooldown something changes in a way we can't time (chance, procs, amounts computed in code).
    Shipped as record.volatile: they start with Blizzard's assistant leading slot 1, and the runtime's learning
    takes them back once our clock agrees with the game (State.lua S.ClockUnreliable)."""
    actions = {e["action"] for n in simc["order"] for e in simc["lists"][n]}
    out = set()
    for r in review:
        m = REVIEW_MODULE.match(r)
        if m:
            if m.group(2) in actions and (m.group(1) in ids or m.group(3).startswith("proc outside")):
                out.add(m.group(2))
            continue
        m = REVIEW_DESC.match(r)
        if m and int(m.group(1)) in info:
            tok = re.sub(r"[^a-z0-9_]", "", m.group(2).strip().lower().replace(" ", "_"))
            if tok in actions:
                out.add(tok)
    return sorted(out)

def parse_apl(text):
    """Return {"lists": {name: [entry...]}, "order": [list names]}; entries keep source order."""
    lists, order = {}, []
    pending_excluded = False
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line:
            pending_excluded = False
            continue
        if line.startswith("#"):
            if EXCLUDED_MARK in line:
                pending_excluded = True
            continue
        m = LINE_RE.match(line)
        if not m:
            pending_excluded = False
            continue
        name = m.group(1) or "default"
        body = m.group(3)
        parts = body.split(",")
        action = parts[0].strip()
        params = {}
        for p in parts[1:]:
            if "=" in p:
                k, v = p.split("=", 1)
                params[k.strip()] = v.strip()
            elif p.strip():
                params[p.strip()] = "1"
        if name not in lists:
            lists[name] = []
            order.append(name)
        entry = {"action": action, "line": lineno}
        cond = params.pop("if", None)
        if cond is not None:
            entry["cond"] = cond
        if params:
            entry["params"] = params
        if pending_excluded:
            entry["excluded"] = True
        lists[name].append(entry)
        pending_excluded = False
    return {"lists": lists, "order": order}


# ---------------------------------------------------------------------------
# SimC expression parser (precedence from SimC's expression engine, low -> high)
#   |   ^   &   = != < <= > >= ~ !~   >? <?   + -   * % %%   unary ! - + @   atoms, floor() ceil()
# ---------------------------------------------------------------------------
TOKEN_RE = re.compile(r"""
    (?P<num>\d+(?:\.\d+)?)
  | (?P<id>[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*)
  | (?P<op>>\?|<\?|<=|>=|!=|!~|%%|&&|\|\||[|^&=<>~+\-*%!@()])
  | (?P<ws>\s+)
""", re.X)

BINARY = [
    ({"|", "||"}, "or"),
    ({"^"}, "xor"),
    ({"&", "&&"}, "and"),
    ({"=", "!=", "<", "<=", ">", ">=", "~", "!~"}, "cmp"),
    ({">?", "<?"}, "maxmin"),
    ({"+", "-"}, "add"),
    ({"*", "%", "%%"}, "mul"),
]


class ParseError(Exception):
    pass


def tokenize(s):
    pos, out = 0, []
    while pos < len(s):
        m = TOKEN_RE.match(s, pos)
        if not m:
            raise ParseError(f"bad character {s[pos]!r} at {pos}")
        pos = m.end()
        if m.lastgroup == "ws":
            continue
        out.append((m.lastgroup, m.group(m.lastgroup)))
    return out


class Parser:
    def __init__(self, s):
        self.toks = tokenize(s)
        self.i = 0

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else (None, None)

    def take(self):
        t = self.peek()
        self.i += 1
        return t

    def parse(self):
        node = self.binary(0)
        if self.i != len(self.toks):
            raise ParseError(f"unexpected {self.peek()[1]!r}")
        return node

    def binary(self, level):
        if level == len(BINARY):
            return self.unary()
        ops = BINARY[level][0]
        left = self.binary(level + 1)
        while True:
            kind, val = self.peek()
            if kind == "op" and val in ops:
                self.take()
                right = self.binary(level + 1)
                left = ("bin", val, left, right)
            else:
                return left

    def unary(self):
        kind, val = self.peek()
        if kind == "op" and val in ("!", "-", "+", "@"):
            self.take()
            return ("un", val, self.unary())
        return self.atom()

    def atom(self):
        kind, val = self.take()
        if kind == "num":
            return ("num", float(val))
        if kind == "id":
            if val in ("floor", "ceil") and self.peek() == ("op", "("):
                self.take()
                inner = self.binary(0)
                if self.take() != ("op", ")"):
                    raise ParseError("missing ) after function")
                return ("fn", val, inner)
            return ("id", val)
        if (kind, val) == ("op", "("):
            inner = self.binary(0)
            if self.take() != ("op", ")"):
                raise ParseError("missing )")
            return inner
        raise ParseError(f"unexpected {val!r}")


def identifiers(node, out):
    if node[0] == "id":
        out.append(node[1])
    elif node[0] in ("bin",):
        identifiers(node[2], out)
        identifiers(node[3], out)
    elif node[0] in ("un", "fn"):
        identifiers(node[2], out)
    return out


# ---------------------------------------------------------------------------
# Readability classes (worst wins): R read, S static, M mode/user toggle, T tracked by us, U unknown
# ---------------------------------------------------------------------------
RANK = {"R": 0, "S": 0, "M": 1, "T": 2, "U": 3}
SECONDARY = {"combo_points", "holy_power", "soul_shard", "soul_shards", "chi", "arcane_charges", "essence",
             "runes", "rune", "stagger", "soul_fragments"}
PRIMARY = {"energy", "rage", "focus", "mana", "runic_power", "astral_power", "lunar_power", "fury", "pain",
           "insanity", "maelstrom"}
READ_PREFIX = {"talent", "hero_tree", "gcd", "prev_gcd", "prev", "prev_off_gcd", "spec", "race", "level"}
STATIC_PREFIX = {"fight_style", "raid_event", "trinket", "equipped", "set_bonus", "main_hand", "off_hand",
                 "covenant", "bugs", "position_back", "position_front", "item", "potion", "runeforge", "apex",
                 "this_trinket", "other_trinket", "consumable", "stat"}
# Mode = decided by a user setting rather than read: target count (ST/AOE/AUTO toggle) and fight length
# ("assume a long fight" unless the player says otherwise; cooldown holding is the burst toggle's job).
MODE_PREFIX = {"active_enemies", "spell_targets", "toggle", "variable_target_count", "enemies", "fight_remains",
               "time_to_die", "expected_combat_length"}
TRACK_PREFIX = {"buff", "debuff", "dot", "active_dot", "stealthed", "action", "charges", "cooldown_react"}
UNKNOWN_PREFIX = {"health", "incoming_damage_3s",
                  "incoming_damage_5s", "pet", "time_to_bloodlust", "buff_remains"}
READ_EXACT = {"time", "combat_time", "gcd", "cast_time", "execute_time", "moving", "movement.distance",
              "target.distance", "distance", "true", "false", "in_combat"}
TRACK_EXACT = {"refreshable", "ticking", "remains", "stack", "ticks", "tick_time", "ticks_remain", "duration",
               "charges_fractional", "full_recharge_time", "recharge_time", "persistent_multiplier", "pmultiplier",
               "in_flight", "in_flight_to_target", "travel_time", "executing", "channeling"}


def classify(term, variables):
    if term.startswith("variable."):
        return variables.get(term.split(".", 1)[1], "U")
    if term in READ_EXACT:
        return "R"
    if term in TRACK_EXACT:
        return "T"
    head = term.split(".", 1)[0]
    if head in SECONDARY:
        return "R"
    if head in PRIMARY:
        return "T"
    if head == "cooldown":
        return "R" if term.endswith((".ready", ".up", ".down")) else "T"
    if head == "target":
        if term.startswith("target.distance"):
            return "R"
        if term.startswith(("target.time_to_die", "target.time_to_pct")):
            return "M"
        return "U"
    if head in READ_PREFIX:
        return "R"
    if head in STATIC_PREFIX:
        return "S"
    if head in MODE_PREFIX:
        return "M"
    if head in TRACK_PREFIX:
        return "T"
    if head in UNKNOWN_PREFIX:
        return "U"
    return "U"


def worst(classes):
    best = "R"
    for c in classes:
        if RANK[c] > RANK[best]:
            best = c
    return best


# ---------------------------------------------------------------------------
# Spec processing
# ---------------------------------------------------------------------------
def analyse(apl, errors, label):
    """Parse every condition, resolve variables, classify each line. Mutates entries in place."""
    variables = {}
    unknown_terms = Counter()
    entries = [e for name in apl["order"] for e in apl["lists"][name]]
    # Variables first (two passes so later variables can depend on earlier ones).
    for _ in range(2):
        for e in entries:
            if e["action"] != "variable":
                continue
            p = e.get("params", {})
            vname = p.get("name")
            exprs = [e.get("cond"), p.get("value"), p.get("value_else"), p.get("condition")]
            classes = []
            for x in exprs:
                if not x:
                    continue
                try:
                    classes += [classify(t, variables) for t in identifiers(Parser(x).parse(), [])]
                except ParseError:
                    classes.append("U")
            if vname:
                variables[vname] = worst(classes)
    for e in entries:
        cond = e.get("cond")
        if not cond:
            e["class"] = "R"
            continue
        try:
            terms = identifiers(Parser(cond).parse(), [])
        except ParseError as exc:
            errors.append(f"{label} line {e['line']}: {exc}: {cond}")
            e["class"] = "U"
            e["parseError"] = True
            continue
        classes = [classify(t, variables) for t in terms]
        e["class"] = worst(classes)
        for t, c in zip(terms, classes):
            if c == "U":
                unknown_terms[t] += 1
    return unknown_terms


def coverage(apl):
    counts = Counter()
    for name in apl["order"]:
        if name == "precombat":
            continue
        for e in apl["lists"][name]:
            if e["action"] in ("variable", "snapshot_stats"):
                continue
            counts[e["class"]] += 1
    total = sum(counts.values()) or 1
    return {
        "lines": sum(counts.values()),
        "read": counts["R"] + counts["S"],
        "mode": counts["M"],
        "tracked": counts["T"],
        "unknown": counts["U"],
        "usablePct": round(100 * (counts["R"] + counts["S"] + counts["M"] + counts["T"]) / total),
        "readPct": round(100 * (counts["R"] + counts["S"]) / total),
    }


# ---------------------------------------------------------------------------
# Lua emitter (data only)
# ---------------------------------------------------------------------------
LUA_KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
LUA_RESERVED = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local",
                "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"}


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def lua(v, indent=0):
    pad = "  " * indent
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, list):
        if not v:
            return "{}"
        if all(isinstance(x, (int, float, str)) and not isinstance(x, bool) for x in v) and len(v) <= 8 \
                and not any(isinstance(x, str) and len(x) > 24 for x in v):
            return "{ " + ", ".join(lua(x) for x in v) + " }"
        inner = ",\n".join(pad + "  " + lua(x, indent + 1) for x in v)
        return "{\n" + inner + ",\n" + pad + "}"
    if isinstance(v, dict):
        if not v:
            return "{}"
        if all(isinstance(k, int) for k in v) and all(isinstance(x, (int, float)) for x in v.values()):
            return "{ " + ", ".join(f"[{k}] = {lua(v[k])}" for k in sorted(v)) + " }"
        items = []
        for k in sorted(v):
            if isinstance(k, int):
                key = f"[{k}]"
            else:
                key = k if LUA_KEY.match(k) and k not in LUA_RESERVED else "[" + lua_str(k) + "]"
            items.append(f"{pad}  {key} = {lua(v[k], indent + 1)}")
        return "{\n" + ",\n".join(items) + ",\n" + pad + "}"
    raise TypeError(type(v))


def compact_entry(e):
    """Short keys keep the data small and diffs readable: a=action c=condition p=params k=class x=excluded."""
    out = {"a": e["action"], "k": e["class"]}
    if "cond" in e:
        out["c"] = e["cond"]
    if "params" in e:
        out["p"] = e["params"]
    if e.get("excluded"):
        out["x"] = True
    return out


def lists_for_lua(apl):
    return {name: [compact_entry(e) for e in apl["lists"][name]] for name in apl["order"]}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def git_info(path):
    try:
        out = subprocess.check_output(["git", "-C", path, "log", "-1", "--format=%h|%cs"], text=True).strip()
        sha, date = out.split("|")
        return sha, date
    except Exception:
        return "unknown", "unknown"


# SimC actions that are not spells (or not class spells); left out of the game-data match.
NOT_SPELLS = {"auto_attack", "snapshot_stats", "use_item", "use_items", "potion", "flask", "food", "augmentation",
              "invoke_external_buff", "pool_resource", "wait", "cancel_buff", "retarget_auto_attack", "variable",
              "call_action_list", "run_action_list", "start_moving", "stop_moving", "cancel_action",
              "wait_for_cooldown", "sequence", "strict_sequence", "swap_action_list", "berserking", "blood_fury",
              "fireblood", "ancestral_call", "arcane_torrent", "bag_of_tricks", "lights_judgment", "arcane_pulse",
              "haymaker", "rocket_barrage", "shadowmeld", "summon_pet", "retarget", "pick_up_fragment",
              "cycling_variable", "apply_poison"}


_FOREVER_IDS = {}


def forever_ids(wowsims_root):
    """Spell id -> token for every Forever class spell (all classes: lists reference buffs from other classes)."""
    if wowsims_root not in _FOREVER_IDS:
        ids = {}
        for cls in ("druid", "hunter", "mage", "paladin", "priest", "rogue", "shaman", "warlock", "warrior"):
            for sid, sp in gamedata_spells.parse_class(os.path.join(wowsims_root, "gamedata"), cls).items():
                ids[sid] = sp["token"]
        _FOREVER_IDS[wowsims_root] = ids
    return _FOREVER_IDS[wowsims_root]


# Hand-written spell interdependencies the description reader can't parse (data/spell-links.json), by class:
# { "rogue": [ { "source": "*", "target": "adrenaline_rush", "seconds": 1, "power": 4, "requires": 0,
#               "covers": "Finishing moves reduce the remaining cooldown", "why": "Restless Blades" } ] }
_extra_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "spell-links.json")
EXTRA_LINKS = json.load(open(_extra_path, encoding="utf-8")) if os.path.exists(_extra_path) else {}
EXTRA_VOLATILE = EXTRA_LINKS.pop("volatile", {}) if isinstance(EXTRA_LINKS.get("volatile"), dict) else {}
EXTRA_LINKS = {k: v for k, v in EXTRA_LINKS.items() if not k.startswith("_")}


# Resource gains measured in real fights (tools/wcl-resources.py -> data/resource-gains.json), per branch and spec:
# "gains" {spellID: {powerType: per cast}} and "passive" {powerType: per second}.
_measured_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "resource-gains.json")
MEASURED = json.load(open(_measured_path, encoding="utf-8")) if os.path.exists(_measured_path) else {}


def apply_measured(record, info, branch, spec, measured=None):
    """Fold measured gains into the spec's spell data: a spell's measured gain per cast replaces SimC's where they
    differ (whole points), and passive income per second (procs, passive talents) goes into record.passiveGain.
    Returns the changes, for the summary."""
    m = (measured if measured is not None else MEASURED).get(branch, {}).get(spec)
    if not m:
        return []
    changes = []
    for sid, gains in sorted(m.get("gains", {}).items()):
        sp = info.get(int(sid))
        if not sp:
            continue
        for pt, amount in sorted(gains.items()):
            pt, v = int(pt), int(round(amount))
            if v <= 0:
                continue
            g = sp.setdefault("gain", {})
            if g.get(pt) != v:
                changes.append("%s pt%d %s->%d" % (sp.get("n", sid), pt, g.get(pt, 0), v))
                g[pt] = v
    passive = {int(pt): v for pt, v in m.get("passive", {}).items() if v and v > 0}
    if passive:
        record["passiveGain"] = dict(sorted(passive.items()))
    # out of combat (tools/wcl-ooc.py): per second (rate: typical, fast: the quickest seen) and where it settles
    ooc = {}
    for pt, o in sorted(m.get("ooc", {}).items(), key=lambda kv: int(kv[0])):
        row = {k: o[v] for k, v in (("rate", "rate"), ("fast", "rateFast"), ("rest", "rest")) if o.get(v) is not None}
        if row:
            ooc[int(pt)] = row
    if ooc:
        record["oocPower"] = ooc
    return changes


def import_branch(simc_root, branch, out_root, errors, wowsims_root=None):
    base = os.path.join(simc_root, branch, "ActionPriorityLists")
    sha, date = git_info(os.path.join(simc_root, branch))
    data_dir = os.path.join(out_root, "addons", "DMGAssist", "Data", branch)
    os.makedirs(data_dir, exist_ok=True)
    for f in os.listdir(data_dir):
        if f.endswith(".lua"):
            os.remove(os.path.join(data_dir, f))
    specs = sorted(f[:-5] for f in os.listdir(os.path.join(base, "default")) if f.endswith(".simc"))
    # Our own lists for specs SimC publishes none for (healers: Discipline, Holy, Mistweaver, Restoration
    # Shaman, Preservation): data/apl-community/<branch>/<spec>.simc. SimC's list wins if it ever ships one.
    community_dir = os.path.join(out_root, "data", "apl-community", branch)
    community = set()
    if os.path.isdir(community_dir):
        community = {f[:-5] for f in os.listdir(community_dir) if f.endswith(".simc")} - set(specs)
        specs = sorted(set(specs) | community)
    report = {"branch": branch, "commit": sha, "date": date, "specs": {}}
    class_spells = {}
    all_spells = {}
    own_tokens = {}
    wowsims_unknown = {}
    specs_by_class = {}
    for spec in specs:
        cls, _, name = spec.partition("_")
        specs_by_class.setdefault(cls, []).append(name.replace("_", " ").title())
    for spec in specs:
        # Our own list for this client wins over SimC's (e.g. real Forever rotations while SimC's forever branch
        # still ships copies of the Midnight lists): data/apl-overrides/<branch>/<spec>.simc
        override = os.path.join(out_root, "data", "apl-overrides", branch, spec + ".simc")
        apl_path = override if os.path.exists(override) else os.path.join(base, "default", spec + ".simc")
        if spec in community:
            apl_path = os.path.join(community_dir, spec + ".simc")
        wowsims_file = None
        if branch == "forever" and wowsims_root and spec in WOWSIMS_FOREVER and not os.path.exists(override):
            candidate = os.path.join(wowsims_root, "forever", "ui", "specs", WOWSIMS_FOREVER[spec])
            if os.path.exists(candidate):
                wowsims_file = candidate
        if wowsims_file:
            simc, conv = wowsims_apl.convert_file(wowsims_file, forever_ids(wowsims_root))
            wowsims_unknown[spec] = conv.unknown
        else:
            simc = parse_apl(open(apl_path, encoding="utf-8").read())
        unknown = analyse(simc, errors, f"{branch}/default/{spec}")
        blz_path = os.path.join(base, "assisted_combat", spec + ".simc")
        blz = None
        if os.path.exists(blz_path):
            blz = parse_apl(open(blz_path, encoding="utf-8").read())
            analyse(blz, errors, f"{branch}/assisted_combat/{spec}")
        cls, _, specname = spec.partition("_")
        record = {
            "key": spec,
            "class": cls,
            "spec": specname,
            "simc": lists_for_lua(simc),
            "simcOrder": simc["order"],
        }
        if spec in community:
            # Written by DMGAssist from the class guides (see the file's header), not by SimulationCraft.
            record["community"] = True
            header = [l[1:].strip() for l in open(apl_path, encoding="utf-8").read().splitlines()[:6] if l.startswith("#")]
            record["credit"] = header[0] if header else "DMGAssist list"
        if blz:
            record["blizzard"] = lists_for_lua(blz)
            record["blizzardOrder"] = blz["order"]
            record["blizzardExcluded"] = sorted({e["action"] for n in blz["order"] for e in blz["lists"][n] if e.get("excluded")})
        if cls not in class_spells and branch not in all_spells:
            # SimC's class dumps leave out some class spells (e.g. Aimed Shot); its full dump has them.
            path = os.path.join(simc_root, branch, "SpellDataDump", "allspells.txt")
            all_spells[branch] = simc_spells.parse_dump(open(path, encoding="utf-8").read()) \
                if os.path.exists(path) else {}
        if cls not in class_spells and branch == "forever" and wowsims_root:
            # Forever's own client data (wowsims/gamedata, refreshed per hotfix) first; SimC's dump fills gaps.
            gd = gamedata_spells.parse_class(os.path.join(wowsims_root, "gamedata"), cls)
            if gd:
                class_spells[cls] = gd
                path = os.path.join(simc_root, branch, "SpellDataDump", cls + ".txt")
                if os.path.exists(path):
                    for sid, sp in simc_spells.parse_dump(open(path, encoding="utf-8").read()).items():
                        class_spells[cls].setdefault(sid, sp)
        if cls not in class_spells:
            # Spell IDs are shared across clients. A class whose dump is missing or empty on one branch
            # (forever's evoker.txt has no spells) uses another branch's dump rather than shipping no spell data.
            class_spells[cls] = {}
            for b in [branch] + [x for x in BRANCHES if x != branch]:
                path = os.path.join(simc_root, b, "SpellDataDump", cls + ".txt")
                if os.path.exists(path):
                    class_spells[cls] = simc_spells.parse_dump(open(path, encoding="utf-8").read())
                    if class_spells[cls]:
                        break
            for sid, sp in all_spells.get(branch, {}).items():
                if sp.get("class") == cls and sid not in class_spells[cls]:
                    class_spells[cls][sid] = sp
        if class_spells[cls]:
            this = specname.replace("_", " ").title()
            others = {n for n in specs_by_class[cls] if n != this}
            refs = simc_spells.references([record["simc"]] + ([record["blizzard"]] if blz else []))
            ids, info = simc_spells.select(class_spells[cls], refs, others, this)
            record["spells"] = ids
            record["spellInfo"] = info
            apply_measured(record, info, branch, spec)  # measured in real fights (data/resource-gains.json)
            record["heroTrees"] = simc_spells.hero_trees(class_spells[cls], refs["hero"])
            # Two sources, merged: SimC's class modules (the code that simulates the class: complete and tested)
            # and the game's own spell descriptions. tools/simc_modules.py, tools/simc_spells.py.
            module_dir = os.path.join(simc_root, branch, "engine", "class_modules")
            module_links, module_review = simc_modules.links(module_dir, cls, class_spells[cls])
            extra = [list(l) for l in module_links] + [x for x in EXTRA_LINKS.get(cls, [])
                                                       if not isinstance(x, dict) or x.get("branch", branch) == branch]
            links, review = simc_spells.links_for(class_spells[cls], ids, extra)
            review = review + [r for r in module_review if any(a in r for a in ids)]
            if links:
                record["cdLinks"] = links
            alinks = simc_spells.aura_links(class_spells[cls], ids, {v.get("n") for v in info.values()})
            if alinks:
                record["auraLinks"] = alinks
            record["_review"] = review
            vol = sorted(set(volatile_targets(review, ids, info, simc)) | set(EXTRA_VOLATILE.get(spec, [])))
            if vol:
                record["volatile"] = vol
        record["simcSource"] = "override" if apl_path == override else "simc"
        if wowsims_file:
            record["simcSource"] = "wowsims"
            record["credit"] = WOWSIMS_CREDIT
        if (branch, spec) in ALTERNATES:
            record["alternate"] = ALTERNATES[(branch, spec)]
        # How many of the list's spells exist in THIS game version's own data (no fallback to another branch).
        if cls not in own_tokens and branch == "forever" and wowsims_root:
            gd = gamedata_spells.parse_class(os.path.join(wowsims_root, "gamedata"), cls)
            if gd:
                own_tokens[cls] = {sp["token"] for sp in gd.values()}
        if cls not in own_tokens:
            own = {}
            for name in (cls + ".txt",):
                path = os.path.join(simc_root, branch, "SpellDataDump", name)
                if os.path.exists(path):
                    own = simc_spells.parse_dump(open(path, encoding="utf-8").read())
            for sid, sp in all_spells.get(branch, {}).items():
                if sp.get("class") == cls:
                    own[sid] = sp
            own_tokens[cls] = {sp["token"] for sp in own.values()}
        acts = sorted({e["action"] for n in simc["order"] for e in simc["lists"][n]} - NOT_SPELLS)
        found = [a for a in acts if any(c in own_tokens[cls] for c in simc_spells.candidates(a))]
        missing = [a for a in acts if a not in found]
        record["gameMatch"] = {"matched": len(found), "total": len(acts), "missing": missing[:12]}
        review = record.pop("_review", [])
        header = (f"-- Generated by tools/simc_import.py from simulationcraft/simc@{branch} {sha} ({date}). Do not edit.\n"
                  f"-- Data only. k = how DMGAssist can know the condition in combat: "
                  f"R read, S static, M mode toggle, T tracked by us, U unknown.\n"
                  f"local _, ns = ...\nns.RegisterSpecData({lua_str(branch)}, {lua_str(spec)}, {lua(record)})\n")
        with open(os.path.join(data_dir, spec + ".lua"), "w", encoding="utf-8") as fh:
            fh.write(header)
        cov = coverage(simc)
        if blz:
            cov["blizzard"] = coverage(blz)
            cov["blizzardExcluded"] = record["blizzardExcluded"]
        cov["topUnknown"] = [t for t, _ in unknown.most_common(6)]
        if "gameMatch" in record:
            cov["gameMatch"] = record["gameMatch"]
            cov["simcSource"] = record["simcSource"]
        cov["links"] = ["%s>%s:%s%s%s" % (l[0], l[1], l[2], (" per pt" + str(l[4])) if l[4] else "",
                                          (" req" + str(l[3])) if l[3] else "") for l in record.get("cdLinks", [])]
        cov["linkReview"] = review
        report["specs"][spec] = cov
    index = {"branch": branch, "commit": sha, "date": date, "specs": specs}
    with open(os.path.join(data_dir, "Index.lua"), "w", encoding="utf-8") as fh:
        fh.write(f"-- Generated by tools/simc_import.py. Do not edit.\nlocal _, ns = ...\nns.RegisterDataIndex({lua(index)})\n")
    return report, specs


def write_report(out_root, report):
    os.makedirs(os.path.join(out_root, "data"), exist_ok=True)
    with open(os.path.join(out_root, "data", f"coverage-{report['branch']}.json"), "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=1, sort_keys=True)
        fh.write("\n")
    os.makedirs(os.path.join(out_root, "docs", "coverage"), exist_ok=True)
    lines = [
        f"# SimC coverage — {report['branch']}",
        "",
        f"Source: simulationcraft/simc@{report['branch']} `{report['commit']}` ({report['date']}). Generated; do not edit.",
        "",
        "How much of each priority list DMGAssist can evaluate in combat. *Usable* = readable, static, user mode, or",
        "tracked by our own state model; *unknown* lines need corroboration (see docs/design/engine-priority.md).",
        "Classes are planning estimates until confirmed by Watchdog probes.",
        "",
        "*In game data* = how many of the list's spells exist in this game version's own spell data. Low numbers mean",
        "the list was written for another version (SimC's forever branch currently ships the Midnight lists); put a",
        "corrected list in `data/apl-overrides/<branch>/<spec>.simc`.",
        "",
        "| Spec | SimC lines | usable | read-only | unknown | in game data | Blizzard lines | Blizzard usable | excluded CDs | top unknown terms |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---|---|",
    ]
    for spec, c in sorted(report["specs"].items()):
        b = c.get("blizzard", {})
        gm = c.get("gameMatch")
        gm_text = f"{gm['matched']}/{gm['total']}" if gm else "-"
        if c.get("simcSource") in ("override", "wowsims"):
            gm_text += f" ({c['simcSource']})"
        lines.append(f"| {spec} | {c['lines']} | {c['usablePct']}% | {c['readPct']}% | {c['unknown']} | {gm_text} | "
                     f"{b.get('lines', '-')} | {str(b.get('usablePct', '-')) + '%' if b else '-'} | "
                     f"{', '.join(c.get('blizzardExcluded', [])) or '-'} | {', '.join(c['topUnknown'][:4]) or '-'} |")
    with open(os.path.join(out_root, "docs", "coverage", f"{report['branch']}.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


# Each client loads only its own data: Midnight is game type "standard"; Forever ("Camelot") is reached by
# excluding every other known type, so we never need Forever's internal type name.
TOC_GATES = {
    "midnight": "[AllowLoadGameType standard]",
    "forever": "[ExcludeLoadGameType standard, mists, cata, wrath, tbc, vanilla]",
}
TOC_BEGIN = "# BEGIN GENERATED DATA (tools/simc_import.py)"
TOC_END = "# END GENERATED DATA"


def update_toc(out_root, specs_by_branch):
    path = os.path.join(out_root, "addons", "DMGAssist", "DMGAssist.toc")
    if not os.path.exists(path):
        return
    text = open(path, encoding="utf-8").read()
    if TOC_BEGIN not in text or TOC_END not in text:
        sys.exit(f"{path} is missing the generated-data markers")
    block = [TOC_BEGIN]
    for branch in BRANCHES:
        gate = TOC_GATES[branch]
        block.append(f"Data\\{branch}\\Index.lua {gate}")
        block += [f"Data\\{branch}\\{spec}.lua {gate}" for spec in specs_by_branch[branch]]
    block.append(TOC_END)
    head, rest = text.split(TOC_BEGIN, 1)
    _, tail = rest.split(TOC_END, 1)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(head + "\n".join(block) + tail)


def summarize(old, new):
    """Markdown describing what changed between two coverage reports."""
    out = [f"### {new['branch']}: simc `{old.get('commit', 'none')}` → `{new['commit']}` ({new['date']})"]
    changed = []
    for spec in sorted(set(old.get("specs", {})) | set(new["specs"])):
        o, n = old.get("specs", {}).get(spec), new["specs"].get(spec)
        if o is None:
            changed.append(f"- **{spec}**: new spec ({n['lines']} lines, {n['usablePct']}% usable)")
        elif n is None:
            changed.append(f"- **{spec}**: removed")
        elif (o["lines"], o["usablePct"], o.get("blizzard", {}).get("lines")) != (n["lines"], n["usablePct"], n.get("blizzard", {}).get("lines")):
            changed.append(f"- **{spec}**: lines {o['lines']} → {n['lines']}, usable {o['usablePct']}% → {n['usablePct']}%"
                           f", Blizzard lines {o.get('blizzard', {}).get('lines')} → {n.get('blizzard', {}).get('lines')}")
    out += changed or ["- list contents changed, coverage figures unchanged"]
    # Spell interdependencies (from the game's spell descriptions): applied automatically; listed so a change is visible.
    links = []
    for spec in sorted(new["specs"]):
        o = set(old.get("specs", {}).get(spec, {}).get("links", []))
        n = set(new["specs"][spec].get("links", []))
        for l in sorted(n - o):
            links.append(f"- {spec}: + {l}")
        for l in sorted(o - n):
            links.append(f"- {spec}: − {l}")
    if links:
        out += ["", "#### Spell interdependencies changed (applied automatically)"] + links[:60]
    unclear = sum(len(c.get("linkReview", [])) for c in new["specs"].values())
    if unclear:
        out += ["", f"{unclear} description sentence(s) mention a cooldown or charge we can't turn into a rule; "
                    "the runtime's learning covers them (see data/coverage-*.json linkReview)."]
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--simc", default=".libraries/simc", help="directory holding <branch>/ActionPriorityLists")
    ap.add_argument("--wowsims", default=".libraries/wowsims",
                    help="directory holding forever/ and gamedata/ from scripts/fetch-wowsims.sh (optional)")
    ap.add_argument("--out", default=".", help="repository root to write into")
    ap.add_argument("--summary", help="write a markdown change summary here")
    args = ap.parse_args()

    errors, summaries, specs_by_branch = [], [], {}
    for branch in BRANCHES:
        if not os.path.isdir(os.path.join(args.simc, branch, "ActionPriorityLists")):
            sys.exit(f"missing {args.simc}/{branch}/ActionPriorityLists — run scripts/fetch-simc.sh")
        old_path = os.path.join(args.out, "data", f"coverage-{branch}.json")
        old = json.load(open(old_path)) if os.path.exists(old_path) else {}
        wowsims_root = args.wowsims if os.path.isdir(os.path.join(args.wowsims, "gamedata")) else None
        report, specs = import_branch(args.simc, branch, args.out, errors, wowsims_root)
        write_report(args.out, report)
        summaries.append(summarize(old, report))
        specs_by_branch[branch] = specs
        print(f"{branch}: {len(specs)} specs from {report['commit']} ({report['date']})")

    update_toc(args.out, specs_by_branch)
    if errors:
        print(f"\n{len(errors)} condition(s) failed to parse:", file=sys.stderr)
        for e in errors[:40]:
            print("  " + e, file=sys.stderr)
    if args.summary:
        body = ["## Weekly SimC sync", "", *summaries, "",
                f"Parse failures: {len(errors)}" + (" (see job log)" if errors else ""),
                "", "Checks (syntax, lint, tests) ran before this PR was opened. Review the per-spec diffs, then merge."]
        with open(args.summary, "w", encoding="utf-8") as fh:
            fh.write("\n".join(body) + "\n")
    # Parse failures don't block the import (the line is marked unknown) but are reported.
    return 0


if __name__ == "__main__":
    sys.exit(main())
