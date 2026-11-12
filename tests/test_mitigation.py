"""The mitigation map (data/mitigation -> Data/Mitigation.lua) is complete, checked against game data, and current."""
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import mitigation  # noqa: E402


# The checks read SimC's SpellDataDump (.libraries/simc, a local checkout CI doesn't have). The generated
# Data/Mitigation.lua is committed; the local ./scripts/check.sh runs these before every commit.
@unittest.skipUnless(os.path.isdir(mitigation.DUMP), "SimC SpellDataDump not checked out (.libraries/simc)")
class MitigationMap(unittest.TestCase):
    def test_generated_file_is_current_and_all_checks_pass(self):
        r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "mitigation.py"), "--check"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)

    def test_every_spec_has_a_low_health_list_and_tanks_have_big_hits(self):
        specs, out, errors = mitigation.build()
        self.assertEqual(errors, [])
        self.assertEqual(set(specs), set(out))
        for spec, p in out.items():
            self.assertTrue(p["parts"]["low"], spec)
            if p["role"] == "tank":
                self.assertTrue(p["parts"]["big"], spec)

    def test_spells_missing_from_the_game_are_refused(self):
        spells = mitigation.parse_dump("deathknight")
        by = {}
        for s in spells.values():
            by.setdefault(s["token"], []).append(s)
        with self.assertRaises(mitigation.Error):
            mitigation.resolve({"t": "rune_tap"}, spells, by, "Blood", "x")  # removed in Midnight
        s = mitigation.resolve({"t": "vampiric_blood"}, spells, by, "Unholy", "x")
        self.assertFalse(mitigation.available(s, "Unholy"), "another spec's talent")
        self.assertTrue(mitigation.available(s, "Blood"))

    def test_spec_aura_grants_another_specs_talent(self):
        spells = mitigation.parse_dump("druid")
        self.assertTrue(mitigation.available(spells[61336], "Guardian"), "Survival Instincts via Guardian Druid")
        self.assertFalse(mitigation.available(spells[61336], "Balance"))

    def test_passives_are_not_buttons(self):
        spells = mitigation.parse_dump("monk")
        self.assertTrue(spells[1243287]["passive"], "Diffuse Magic is passive in Midnight")

    def test_profile_parser_rejects_unknown_lines(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as fh:
            fh.write("role = dps\nhealth = 35\nbogus thing\n")
        try:
            with self.assertRaises(mitigation.Error):
                mitigation.parse_profile(fh.name)
        finally:
            os.unlink(fh.name)


class TocLoadsTheMap(unittest.TestCase):
    """Hand-kept data files sit outside the importer's generated block, or every regeneration drops them
    (Data/Mitigation.lua and Data/Combos.lua were missing from the 1.6.0.242 nightly)."""

    def test_hand_kept_data_is_outside_the_generated_block(self):
        toc = open(os.path.join(ROOT, "addons", "DMGAssist", "DMGAssist.toc"), encoding="utf-8").read()
        head = toc.split("# BEGIN GENERATED DATA", 1)[0]
        for name in ("Data\\Mitigation.lua", "Data\\Combos.lua"):
            self.assertIn(name, head)


if __name__ == "__main__":
    unittest.main()
