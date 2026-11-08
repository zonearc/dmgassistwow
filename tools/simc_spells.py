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
    _baseline_energize(spells)
    for s in spells.values():
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


def select(spells, refs, other_specs=()):
    """refs: {"action": set(tokens), "aura": set(tokens), "talent": set(tokens)}.
    Returns (ids_by_token, info_by_id) with only what the spec's lists reference."""
    by = index_by_token(spells)
    ids, keep = {}, set()

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
        if s.get("cost"):
            rec["cost"] = dict(sorted(s["cost"].items()))
        if s.get("costMax"):
            rec["cmax"] = dict(sorted(s["costMax"].items()))
        if s.get("gain"):
            rec["gain"] = dict(sorted(s["gain"].items()))
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
