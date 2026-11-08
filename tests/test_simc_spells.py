"""Unit tests for tools/simc_spells.py.  Run: python3 -m unittest tests/test_simc_spells.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import simc_spells as ss  # noqa: E402

DUMP = """SimulationCraft 1210-01 for World of Warcraft 12.1.5.70783 Live

Name             : Tiger's Fury (id=5217) [Spell Family (7)]
Talent Entry     : Feral [tree=spec, row=1, col=4, max_rank=1, req_points=0]
Duration         : 10 seconds
Cooldown         : 30 seconds
Attributes       : Is Ability (4), Hasted Cooldown Duration (416)
Effects          :
#1 (id=1854)     : Apply Aura (6) | Add Percent Modifier (108): Spell Direct Amount (0)
                   Base Value: 15 | Scaled Value: 15 | Target: Self (1)
#2 (id=117350)   : Energize Power (30)
                   Base Value: 50 | Scaled Value: 50 | Resource: energy | Target: Self (1)

Name             : Rake (id=1822) [Spell Family (7)]
Resource         : 35 Energy (3) (id=143)
GCD              : 1 seconds
Effects          :
#2 (id=560)      : Energize Power (30)
                   Base Value: 1 | Scaled Value: 1 | Resource: combo_points | Target: Self (1)
#3 (id=561)      : Trigger Spell (64): Rake
                   Base Value: 0 | Scaled Value: 0 | Trigger Spell: 155722 | Target: Targeted Enemy (6)

Name             : Rake (id=155722) [Spell Family (7), Hidden]
Duration         : 15 seconds
Effects          :
#1 (id=1)        : Apply Aura (6) | Periodic Damage (3): physical every 3 seconds
                   Base Value: 0 | Target: Targeted Enemy (6)

Name             : Rip (id=1079) [Spell Family (7)]
Resource         : 20 Energy (3) (id=113)
Resource         : 1 - 5 Combo Points (4) (id=10588)
GCD              : 1 seconds
Duration         : 4 seconds
Effects          :
#1 (id=390)      : Apply Aura (6) | Periodic Damage (3): physical every 2 seconds
                   Base Value: 0 | Target: Targeted Enemy (6)

Name             : Wildpower Surge (id=441691) [Spell Family (7), Passive]
Talent Entry     : Druid of the Claw (Feral, Guardian) [tree=hero, row=1, col=1, max_rank=1, req_points=0]
Effects          :

Name             : Berserk (id=106951) [Spell Family (7)]
Charges          : 2 (120 seconds cooldown)
Effects          :
"""


class DumpTests(unittest.TestCase):
    def setUp(self):
        self.spells = ss.parse_dump(DUMP)

    def test_tokens_like_simc(self):
        self.assertEqual(ss.token("Tiger's Fury"), "tigers_fury")
        self.assertEqual(ss.token("Druid of the Claw"), "druid_of_the_claw")

    def test_cooldown_duration_gain_haste(self):
        tf = self.spells[5217]
        self.assertEqual((tf["cooldown"], tf["duration"]), (30, 10))
        self.assertEqual(tf["gain"], {3: 50})
        self.assertTrue(tf["hastedCooldown"])
        self.assertEqual(tf["aura"], "self")
        self.assertEqual(tf["talent"], "Feral")

    def test_cost_and_finisher_range(self):
        rip = self.spells[1079]
        self.assertEqual(rip["cost"], {3: 20, 4: 1})
        self.assertEqual(rip["costMax"], {4: 5})
        self.assertEqual(rip["aura"], "enemy")

    def test_triggered_dot(self):
        rake = self.spells[1822]
        self.assertEqual(rake["triggers"], [(155722, "enemy")])
        self.assertEqual(rake["gain"], {4: 1})
        self.assertTrue(self.spells[155722]["hidden"])

    def test_charges_and_hero_talent(self):
        self.assertEqual((self.spells[106951]["charges"], self.spells[106951]["chargeCooldown"]), (2, 120))
        self.assertEqual(self.spells[441691]["talentTree"], "hero")
        self.assertEqual(self.spells[441691]["talent"], "Druid of the Claw")

    def test_select_keeps_referenced_spells_and_their_auras(self):
        lists = {"default": [
            {"a": "rake", "c": "!dot.rake.ticking"},
            {"a": "tigers_fury", "c": "talent.tigers_fury&hero_tree.druid_of_the_claw"},
        ]}
        refs = ss.references([lists])
        ids, info = ss.select(self.spells, refs, {"Balance", "Guardian", "Restoration"})
        self.assertEqual(ids["rake"]["a"][0], 1822, "castable Rake first")
        self.assertIn(155722, ids["rake"]["b"], "the Rake bleed is the aura")
        self.assertEqual(info[1822]["ap"], [[155722, "enemy"]])
        self.assertEqual(info[155722]["d"], 15)
        self.assertEqual(info[5217]["cd"], 30)
        self.assertTrue(info[5217]["hc"])
        self.assertEqual(ids["tigers_fury"]["t"], [5217])
        self.assertEqual(ss.hero_trees(self.spells, refs["hero"]), {"druid_of_the_claw": [441691]})

    def test_aliases_and_suffixes(self):
        self.assertIn("berserk", ss.candidates("bs_inc"))
        self.assertIn("swipe", ss.candidates("swipe_cat"))


if __name__ == "__main__":
    unittest.main()
