"""Unit tests for tools/simc_import.py.  Run: python3 -m unittest tests/test_simc_import.py"""
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import simc_import as si  # noqa: E402

APL = """
# Executed before combat begins.
actions.precombat=snapshot_stats
actions.precombat+=/cat_form,if=buff.cat_form.down
actions=auto_attack,if=!buff.prowl.up
actions+=/variable,name=big,value=combo_points>=4&cooldown.berserk.ready
actions+=/call_action_list,name=cds
# This is for Blizzard automation and is not included in the game's Assisted Combat system.
actions+=/berserk
actions+=/rip,if=!dot.rip.ticking&combo_points=5
actions+=/ferocious_bite,if=variable.big
actions+=/shred,if=fight_remains>10&target.health.pct<35
actions.cds=tigers_fury,if=energy.deficit>=60|(combo_points>?3)<=2
"""


class ParserTests(unittest.TestCase):
    def parse(self, s):
        return si.Parser(s).parse()

    def test_precedence_and_binds_tighter_than_or(self):
        self.assertEqual(self.parse("a|b&c")[1], "|")

    def test_comparison_binds_tighter_than_and(self):
        node = self.parse("x>=3&!y")
        self.assertEqual(node[1], "&")
        self.assertEqual(node[2][1], ">=")

    def test_dotted_identifiers_with_digits(self):
        ids = si.identifiers(self.parse("trinket.1.has_use_buff&prev_gcd.2.rake"), [])
        self.assertEqual(ids, ["trinket.1.has_use_buff", "prev_gcd.2.rake"])

    def test_max_min_and_functions(self):
        ids = si.identifiers(self.parse("floor(cooldown.x.remains>?gcd.max)+1<?2"), [])
        self.assertEqual(ids, ["cooldown.x.remains", "gcd.max"])

    def test_double_operators_normalised(self):
        self.assertEqual(self.parse("a&&b")[1], "&&")

    def test_garbage_raises(self):
        with self.assertRaises(si.ParseError):
            self.parse("a&(b")


class AplTests(unittest.TestCase):
    def setUp(self):
        self.apl = si.parse_apl(APL)
        self.errors = []
        si.analyse(self.apl, self.errors, "test")

    def test_lists_and_order(self):
        self.assertEqual(self.apl["order"], ["precombat", "default", "cds"])
        self.assertEqual(self.apl["lists"]["default"][2]["params"]["name"], "cds")

    def test_excluded_marker(self):
        berserk = self.apl["lists"]["default"][3]
        self.assertEqual(berserk["action"], "berserk")
        self.assertTrue(berserk.get("excluded"))
        self.assertFalse(self.apl["lists"]["default"][4].get("excluded"))

    def test_classes(self):
        by_action = {e["action"]: e["class"] for e in self.apl["lists"]["default"]}
        self.assertEqual(by_action["rip"], "T")             # dot tracked by us
        self.assertEqual(by_action["ferocious_bite"], "R")  # variable resolves to readable terms
        self.assertEqual(by_action["shred"], "U")           # target.health.pct unknown dominates
        self.assertEqual(self.apl["lists"]["cds"][0]["class"], "T")  # energy is modelled
        self.assertEqual(self.errors, [])

    def test_lua_emit_is_valid_lua(self):
        rec = {"key": "x", "simc": si.lists_for_lua(self.apl), "quote": 'a "q" \\ b'}
        with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as fh:
            fh.write("local t = " + si.lua(rec) + "\nreturn t\n")
            path = fh.name
        try:
            subprocess.check_call(["luac5.1", "-p", path])
        finally:
            os.remove(path)


if __name__ == "__main__":
    unittest.main()
