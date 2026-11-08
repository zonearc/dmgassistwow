#!/usr/bin/env python3
"""Convert WoWSims rotation lists (*.apl.json, wowsims/forever, MIT) into DMGAssist's list format.

WoWSims lists are JSON trees: {prepullActions, priorityList: [{action: {condition, castSpell|...}, hide?}],
groups: [{name, actions}], valueVariables: [{name, value}]}. We turn them into the same structure as
simc_import.parse_apl: {"lists": {name: [entry]}, "order": [...]}, entries {"action", "cond", "params"}, with
conditions written as SimC-style expressions that the in-game evaluator (Core/Expr.lua) and resolver
(Core/State.lua) already understand. Spell IDs become tokens via the game data (id -> token); the rank in the list
doesn't matter: the addon maps a token to the highest rank the player knows.

Anything that only makes sense inside a simulator (item swaps, movement, waits, swing timers) is skipped for
actions and becomes an UNKNOWN term ("wowsims.<kind>") in conditions, never a guess.
"""
import json
import re

from simc_spells import token as simc_token

OPS = {"OpLt": "<", "OpLe": "<=", "OpGt": ">", "OpGe": ">=", "OpEq": "=", "OpNe": "!="}
MATH = {"OpAdd": "+", "OpSub": "-", "OpMul": "*", "OpDiv": "%"}  # % is division in SimC syntax
SKIP_ACTIONS = {"autocastOtherCooldowns", "cancelAura", "itemSwap", "move", "waitUntil", "wait", "activateAura",
                "triggerIcd", "resetSequence", "changeTarget", "castPaladinPrimarySeal", "paladinCastWithMacro",
                "catOptimalRotationAction", "customRotation", "moveDuration", "addComboPoints"}


def name_token(name):
    t = simc_token(name or "")
    t = re.sub(r"[^a-z0-9_]", "", t.replace(".", "_"))
    return t or "unnamed"


def parse_const(val):
    """'4' -> 4, '2.5s' -> 2.5, '500ms' -> 0.5, '1.9m' -> 114, '99%' -> 99, 'true' -> 1."""
    v = str(val).strip()
    if v in ("true", "false"):
        return 1 if v == "true" else 0
    m = re.fullmatch(r"(-?[\d.]+)\s*(ms|s|m|%)?", v)
    if not m:
        return None
    n = float(m.group(1))
    if m.group(2) == "ms":
        n /= 1000
    elif m.group(2) == "m":
        n *= 60
    return int(n) if n.is_integer() else round(n, 3)


class Converter:
    def __init__(self, id_to_token):
        self.id_to_token = id_to_token
        self.unknown = {}
        self.skipped = {}
        self.spells = set()

    # -- helpers ---------------------------------------------------------------
    def spell_token(self, ref):
        if not isinstance(ref, dict):
            return None
        sid = ref.get("spellId")
        if isinstance(sid, int):
            tok = self.id_to_token.get(sid)
            if tok:
                self.spells.add(sid)
                return tok
            return f"spell_{sid}"
        return None

    def unknown_term(self, kind):
        self.unknown[kind] = self.unknown.get(kind, 0) + 1
        return f"wowsims.{name_token(kind)}"

    def unit_prefix(self, node, default="buff"):
        su = node.get("sourceUnit") or {}
        if su.get("type") in ("CurrentTarget", "Target", "PreviousTarget", "NextTarget"):
            return "debuff"
        return default

    # -- values ----------------------------------------------------------------
    def value(self, node):
        if not isinstance(node, dict) or not node:
            return self.unknown_term("empty")
        kind, body = next(iter(node.items()))
        body = body if isinstance(body, dict) else {}
        if kind == "const":
            n = parse_const(body.get("val"))
            return str(n) if n is not None else self.unknown_term("const")
        if kind in ("currentComboPoints",):
            return "combo_points"
        if kind == "currentEnergy":
            return "energy"
        if kind == "currentRage":
            return "rage"
        if kind == "currentMana":
            return "mana"
        if kind == "currentManaPercent":
            return "mana.pct"
        if kind == "currentHealthPercent":
            return "target.health.pct" if self.unit_prefix(body, "self") == "debuff" else "health.pct"
        if kind == "remainingTime":
            return "fight_remains"
        if kind == "currentTime":
            return "time"
        if kind == "numberTargets":
            return "active_enemies"
        if kind == "unitDistance":
            return "target.distance"
        if kind == "variableRef":
            return f"variable.{name_token(body.get('name'))}"
        if kind == "math":
            op = MATH.get(body.get("op"))
            if not op:
                return self.unknown_term("math")
            return f"({self.value(body.get('lhs'))}{op}{self.value(body.get('rhs'))})"
        if kind in ("min", "max"):
            vals = [self.value(v) for v in body.get("vals", [])]
            if not vals:
                return self.unknown_term(kind)
            joiner = ">?" if kind == "min" else "<?"  # SimC: "<?" is max, ">?" is min (engine/sim/expressions.cpp)
            return "(" + joiner.join(vals) + ")"
        if kind in ("auraRemainingTime", "auraNumStacks"):
            tok = self.spell_token(body.get("auraId"))
            field = "remains" if kind == "auraRemainingTime" else "stack"
            return f"{self.unit_prefix(body)}.{tok}.{field}" if tok else self.unknown_term(kind)
        if kind == "dotRemainingTime":
            tok = self.spell_token(body.get("spellId"))
            return f"dot.{tok}.remains" if tok else self.unknown_term(kind)
        if kind == "spellTimeToReady":
            tok = self.spell_token(body.get("spellId"))
            return f"cooldown.{tok}.remains" if tok else self.unknown_term(kind)
        if kind == "spellCurrentCost":
            tok = self.spell_token(body.get("spellId"))
            return f"action.{tok}.cost" if tok else self.unknown_term(kind)
        if kind == "spellCastTime":
            tok = self.spell_token(body.get("spellId"))
            return f"action.{tok}.cast_time" if tok else self.unknown_term(kind)
        if kind == "spellFullCooldown":
            tok = self.spell_token(body.get("spellId"))
            return f"cooldown.{tok}.duration" if tok else self.unknown_term(kind)
        if kind == "talentRank":
            sid = (body.get("talentId") or {}).get("spellId")
            return f"talentid.{sid}" if isinstance(sid, int) else self.unknown_term(kind)
        if kind == "maxMana":
            return "mana.max"
        if kind == "spellGcdHastedDuration":
            return "gcd.max"
        if kind == "gcdTimeToReady":
            return "gcd.remains"
        return self.cond(node)  # booleans used as numbers

    # -- conditions ------------------------------------------------------------
    def cond(self, node):
        if not isinstance(node, dict) or not node:
            return "1"
        kind, body = next(iter(node.items()))
        body = body if isinstance(body, dict) else {}
        if kind == "and":
            parts = [self.cond(v) for v in body.get("vals", [])]
            return "(" + "&".join(parts) + ")" if parts else "1"
        if kind == "or":
            parts = [self.cond(v) for v in body.get("vals", [])]
            return "(" + "|".join(parts) + ")" if parts else "0"
        if kind == "not":
            return f"!({self.cond(body.get('val'))})"
        if kind == "cmp":
            op = OPS.get(body.get("op"))
            if not op:
                return self.unknown_term("cmp")
            return f"({self.value(body.get('lhs'))}{op}{self.value(body.get('rhs'))})"
        if kind == "const":
            n = parse_const(body.get("val"))
            return str(n) if n is not None else self.unknown_term("const")
        if kind in ("auraIsActive", "auraIsInactive"):
            tok = self.spell_token(body.get("auraId"))
            if not tok:
                return self.unknown_term(kind)
            return f"{self.unit_prefix(body)}.{tok}.{'up' if kind == 'auraIsActive' else 'down'}"
        if kind == "auraIsKnown":
            tok = self.spell_token(body.get("auraId"))
            return f"known.{tok}" if tok else self.unknown_term(kind)
        if kind == "auraShouldRefresh":
            tok = self.spell_token(body.get("auraId"))
            if not tok:
                return self.unknown_term(kind)
            overlap = self.value(body.get("maxOverlap") or {"const": {"val": "0s"}})
            unit = self.unit_prefix(body, "debuff")
            return f"({unit}.{tok}.remains<={overlap})"
        if kind == "dotIsActive":
            tok = self.spell_token(body.get("spellId"))
            return f"dot.{tok}.ticking" if tok else self.unknown_term(kind)
        if kind == "spellIsReady":
            tok = self.spell_token(body.get("spellId"))
            return f"cooldown.{tok}.ready" if tok else self.unknown_term(kind)
        if kind == "spellCanCast":
            tok = self.spell_token(body.get("spellId"))
            return f"action.{tok}.ready" if tok else self.unknown_term(kind)
        if kind == "spellIsKnown":
            tok = self.spell_token(body.get("spellId"))
            return f"known.{tok}" if tok else "0"  # items / other ids: not a player spell
        if kind == "spellIsCasting":
            tok = self.spell_token(body.get("spellId"))
            return f"casting.{tok}" if tok else self.unknown_term(kind)
        if kind == "talentIsKnown":
            t = body.get("talentId") or {}
            sid, rank = t.get("spellId"), t.get("rank", 1)
            return f"(talentid.{sid}>={rank})" if isinstance(sid, int) else self.unknown_term(kind)
        if kind == "isExecutePhase":
            m = re.search(r"(\d+)", str(body.get("threshold", "")))
            return f"(target.health.pct<{m.group(1)})" if m else self.unknown_term(kind)
        if kind == "gcdIsReady":
            return "(gcd.remains=0)"
        if kind == "variableRef":
            return f"variable.{name_token(body.get('name'))}"
        # numeric-looking nodes used as truth values
        if kind in ("currentComboPoints", "currentEnergy", "currentRage", "numberTargets", "math", "min", "max"):
            return self.value(node)
        return self.unknown_term(kind)

    # -- actions ---------------------------------------------------------------
    def action(self, item):
        """One priority entry -> list entry, or None when skipped."""
        if not isinstance(item, dict) or item.get("hide"):
            return None
        act = item.get("action") if "action" in item else item
        if not isinstance(act, dict):
            return None
        cond_node = act.get("condition")
        cond = self.cond(cond_node) if cond_node else None
        for kind, body in act.items():
            if kind == "condition":
                continue
            body = body if isinstance(body, dict) else {}
            if kind in ("castSpell", "channelSpell"):
                tok = self.spell_token(body.get("spellId"))
                if not tok:
                    self.skipped["castItem"] = self.skipped.get("castItem", 0) + 1
                    return None
                return self.entry(tok, cond)
            if kind == "multidot":
                tok = self.spell_token(body.get("spellId"))
                if not tok:
                    return None
                refresh = f"(!dot.{tok}.ticking|dot.{tok}.refreshable)"
                return self.entry(tok, f"({cond})&{refresh}" if cond else refresh)
            if kind in ("strictSequence", "sequence"):
                for sub in body.get("actions", []):
                    tok = self.spell_token((sub.get("castSpell") or {}).get("spellId"))
                    if tok:
                        return self.entry(tok, cond)  # recommend the sequence's first spell
                return None
            if kind == "groupReference":
                return {"action": "call_action_list", "params": {"name": name_token(body.get("groupName"))},
                        **({"cond": cond} if cond else {})}
            self.skipped[kind] = self.skipped.get(kind, 0) + 1
            return None
        return None

    @staticmethod
    def entry(tok, cond):
        e = {"action": tok}
        if cond:
            e["cond"] = cond
        return e

    def convert(self, apl):
        lists, order = {}, []

        def add(name, entry):
            if name not in lists:
                lists[name] = []
                order.append(name)
            if entry:
                lists[name].append(entry)

        add("precombat", None)
        for v in apl.get("valueVariables", []) or []:
            add("precombat", {"action": "variable",
                              "params": {"name": name_token(v.get("name")), "value": self.value(v.get("value"))}})
        add("default", None)
        for item in apl.get("priorityList", []) or []:
            add("default", self.action(item))
        for g in apl.get("groups", []) or []:
            gname = name_token(g.get("name"))
            add(gname, None)
            for item in g.get("actions", []) or []:
                add(gname, self.action(item))
        return {"lists": lists, "order": order}


def convert_file(path, id_to_token):
    c = Converter(id_to_token)
    apl = c.convert(json.load(open(path, encoding="utf-8")))
    return apl, c
