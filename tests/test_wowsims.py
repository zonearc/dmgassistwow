"""Tests for tools/gamedata_spells.py and tools/wowsims_apl.py.  Run: python3 -m unittest tests/test_wowsims.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import gamedata_spells as gd  # noqa: E402
import wowsims_apl as wa  # noqa: E402

CARDS = """1079 Rip (Rank 1)
school    physical
duration  12 s
gcd       1 s
cost      30 energy
cost      1 combo points
range     5 yd

effect 1  4 physical damage every 2 s to the enemy (6 ticks)
          E_APPLY_AURA A_PERIODIC_DAMAGE base=4 period=2000ms target=[6,0]
=======
1822 Rake (Rank 1)
duration  9 s
cost      40 energy
effect 3  restores 1 combo point to the caster
          E_ENERGIZE base=1 misc=4 target=[1,0]
=======
5217 Tiger's Fury
duration  6 s
cooldown  30 s
effect 1  a dummy aura holding 15
          E_APPLY_AURA A_DUMMY base=15 target=[1,0]
=======
5421 Aquatic Form (Passive) (Passive)
attrs     passive
"""


class GamedataTests(unittest.TestCase):
    def setUp(self):
        self.s = gd.parse_cards(CARDS)

    def test_ranks_costs_and_finishers(self):
        rip = self.s[1079]
        self.assertEqual((rip["token"], rip["rank"], rip["duration"]), ("rip", 1, 12))
        self.assertEqual(rip["cost"], {3: 30, 4: 1})
        self.assertEqual(rip["costMax"], {4: 5})
        self.assertEqual(rip["aura"], "enemy")

    def test_gains_cooldowns_and_passives(self):
        self.assertEqual(self.s[1822]["gain"], {4: 1})
        self.assertEqual((self.s[5217]["cooldown"], self.s[5217]["aura"]), (30, "self"))
        self.assertTrue(self.s[5421]["passive"])
        self.assertEqual(self.s[5421]["token"], "aquatic_form")


class ConverterTests(unittest.TestCase):
    IDS = {1079: "rip", 768: "cat_form", 9913: "prowl", 9867: "ravage", 22829: "ferocious_bite", 9907: "faerie_fire"}

    def convert(self, apl):
        c = wa.Converter(self.IDS)
        return c.convert(apl), c

    def test_conditions_become_simc_expressions(self):
        apl = {"priorityList": [
            {"action": {"condition": {"auraIsActive": {"auraId": {"spellId": 9913}}},
                        "castSpell": {"spellId": {"spellId": 9867}}}},
            {"action": {"condition": {"and": {"vals": [
                {"cmp": {"op": "OpGe", "lhs": {"currentComboPoints": {}}, "rhs": {"const": {"val": "5"}}}},
                {"not": {"val": {"auraIsActive": {"auraId": {"spellId": 1079}, "sourceUnit": {"type": "CurrentTarget"}}}}}]}},
                "castSpell": {"spellId": {"spellId": 1079}}}},
            {"hide": True, "action": {"castSpell": {"spellId": {"spellId": 22829}}}},
            {"action": {"condition": {"auraShouldRefresh": {"auraId": {"spellId": 9907},
                                                            "maxOverlap": {"const": {"val": "500ms"}}}},
                        "castSpell": {"spellId": {"spellId": 9907}}}},
            {"action": {"condition": {"isExecutePhase": {"threshold": "E20"}},
                        "groupReference": {"groupName": "Execute Phase"}}},
            {"action": {"itemSwap": {"swapSet": "Main"}}},
        ], "valueVariables": [{"name": "Rip target CP", "value": {"const": {"val": "4"}}}],
            "groups": [{"name": "Execute Phase", "actions": [
                {"action": {"condition": {"talentIsKnown": {"talentId": {"spellId": 16958, "rank": 2}}},
                            "castSpell": {"spellId": {"spellId": 22829}}}}]}]}
        out, c = self.convert(apl)
        d = out["lists"]["default"]
        self.assertEqual(d[0], {"action": "ravage", "cond": "buff.prowl.up"})
        self.assertEqual(d[1]["cond"], "((combo_points>=5)&!(debuff.rip.up))")
        self.assertEqual(len(d), 4, "hidden line and item swap are skipped")
        self.assertEqual(d[2]["cond"], "(debuff.faerie_fire.remains<=0.5)")
        self.assertEqual(d[3], {"action": "call_action_list", "params": {"name": "execute_phase"},
                                "cond": "(target.health.pct<20)"})
        self.assertEqual(out["lists"]["execute_phase"][0]["cond"], "(talentid.16958>=2)")
        self.assertEqual(out["lists"]["precombat"][0]["params"], {"name": "rip_target_cp", "value": "4"})
        self.assertEqual(c.skipped, {"itemSwap": 1})

    def test_unknown_kinds_stay_unknown(self):
        out, c = self.convert({"priorityList": [{"action": {"condition": {"autoSwingTime": {}},
                                                            "castSpell": {"spellId": {"spellId": 768}}}}]})
        self.assertEqual(out["lists"]["default"][0]["cond"], "wowsims.autoswingtime")
        self.assertEqual(c.unknown, {"autoSwingTime": 1})

    def test_constants(self):
        self.assertEqual([wa.parse_const(v) for v in ("4", "2.5s", "500ms", "1.9m", "99%", "true", "x")],
                         [4, 2.5, 0.5, 114, 99, 1, None])


if __name__ == "__main__":
    unittest.main()
