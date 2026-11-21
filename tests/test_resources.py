"""Every resource a spell spends or builds has a model (2026-11-21: mana had none, its costs weren't even in the
data, and Restoration's Sunfire looked unaffordable with 261,000 mana).

A resource is covered when the game shows it in combat (Clues.DISCRETE: read every update) or we count it
(Clues.BUILT: a count from the pull, each cast's cost and gain, regeneration, the game's answers correcting it).
"""
import glob
import os
import re
import unittest

ROOT = os.path.join(os.path.dirname(__file__), "..")
CLUES = os.path.join(ROOT, "addons", "DMGAssist", "Core", "Clues.lua")
DATA = os.path.join(ROOT, "addons", "DMGAssist", "Data", "midnight")

# Specs whose spells cost mana (their class's primary resource, or the spec's).
MANA_SPECS = {
    "druid_balance", "druid_restoration", "evoker_augmentation", "evoker_devastation", "evoker_preservation",
    "mage_arcane", "mage_fire", "mage_frost", "monk_mistweaver", "paladin_holy", "paladin_protection",
    "paladin_retribution", "priest_discipline", "priest_holy", "priest_shadow", "shaman_elemental",
    "shaman_enhancement", "shaman_restoration", "warlock_affliction", "warlock_demonology", "warlock_destruction",
}


def table(text, name):
    m = re.search(r"^C\." + name + r" = \{([^}]*)\}", text, re.M)
    return {int(v) for v in re.findall(r"= (\d+)", m.group(1))}


def used_power_types():
    used = {}
    for path in glob.glob(os.path.join(DATA, "*_*.lua")):
        spec = os.path.basename(path)[:-4]
        with open(path, encoding="utf-8") as f:
            text = f.read()
        for kind in ("cost", "gain", "cmax"):
            for m in re.finditer(kind + r" = \{([^{}]*)\}", text):
                for pt in re.findall(r"\[(\d+)\] =", m.group(1)):
                    used.setdefault(int(pt), set()).add(spec)
        if "mpct = " in text:
            used.setdefault(0, set()).add(spec)
    return used


class ResourceCoverage(unittest.TestCase):
    def test_every_spent_or_built_resource_is_read_or_counted(self):
        with open(CLUES, encoding="utf-8") as f:
            text = f.read()
        covered = table(text, "BUILT") | table(text, "DISCRETE")
        missing = {pt: sorted(specs)[:5] for pt, specs in used_power_types().items() if pt not in covered}
        self.assertEqual(missing, {}, "power types used by spells with no model (add to Clues.BUILT or DISCRETE)")

    def test_mana_specs_have_mana_costs(self):
        no_cost = []
        for spec in sorted(MANA_SPECS):
            path = os.path.join(DATA, spec + ".lua")
            with open(path, encoding="utf-8") as f:
                text = f.read()
            if "mpct = " not in text and not re.search(r"cost = \{[^{}]*\[0\] =", text):
                no_cost.append(spec)
        self.assertEqual(no_cost, [], "specs that spend mana with no mana cost in their data")


if __name__ == "__main__":
    unittest.main()
