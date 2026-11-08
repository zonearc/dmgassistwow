"""Tests for tools/send-logs.py (no network).  Run: python3 -m unittest tests/test_send_logs.py"""
import importlib.util
import os
import tempfile
import unittest

HERE = os.path.dirname(__file__)
spec = importlib.util.spec_from_file_location("send_logs", os.path.join(HERE, "..", "tools", "send-logs.py"))
sl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sl)


class CollectTests(unittest.TestCase):
    def test_collects_and_scrubs_the_account_name(self):
        with tempfile.TemporaryDirectory() as root:
            sv = os.path.join(root, "_retail_", "WTF", "Account", "SECRETACCT", "SavedVariables")
            os.makedirs(sv)
            os.makedirs(os.path.join(root, "_retail_", "Logs"))
            with open(os.path.join(sv, "DMGAssist_Watchdog.lua"), "w") as fh:
                fh.write('x = "WTF/Account/SECRETACCT" -- readability blocked')
            with open(os.path.join(root, "_retail_", "Logs", "taint.log"), "w") as fh:
                fh.write("Interface action blocked due to an addon: DMGAssist\n")
            files, newest = sl.collect(root)
            names = sorted(n for n, _ in files)
            self.assertEqual(names, ["retail/DMGAssist_Watchdog.lua", "retail/taint.log"])
            self.assertTrue(all(b"SECRETACCT" not in d for _, d in files))
            self.assertGreater(newest, 0)
            self.assertIn("blocked 1", sl.summarize(files))


if __name__ == "__main__":
    unittest.main()
