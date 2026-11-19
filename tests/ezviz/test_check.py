import _path
import json
import os
import subprocess
import sys
import time
import unittest

from fixtures import CANARIES, GOOD, Tree

NOW = time.time()


def rec(dt, ev):
    return json.dumps({"t": NOW + dt, "ev": ev, "dur": None}) + "\n"


class TestCheck(unittest.TestCase):
    def run_check(self, t, name="cam1"):
        p = subprocess.run([sys.executable, "-c", "import sys; from ezviz_source import check; "
                            "print(sorted(m for m in sys.modules if 'pyezvizapi' in m) or '', file=sys.stderr); "
                            "sys.exit(check.main(sys.argv[1:]))", name],
                           env=t.env(), capture_output=True, text=True)
        return p.returncode, p.stdout.strip(), p.stderr.strip()

    def ready(self, camfile=GOOD, mode=0o600):
        t = Tree(camfile=camfile, mode=mode)
        t.state.mkdir(parents=True, mode=0o700)
        return t

    def test_ok(self):
        self.assertEqual(self.run_check(self.ready()), (0, "ezviz-check cam1: ok", ""))

    def test_missing(self):
        self.assertEqual(self.run_check(self.ready(camfile=None))[:2], (1, "ezviz-check cam1: missing"))

    def test_mode(self):
        self.assertEqual(self.run_check(self.ready(mode=0o644))[:2], (1, "ezviz-check cam1: mode"))

    def test_shape(self):
        self.assertEqual(self.run_check(self.ready(camfile=GOOD.replace("8000", "x")))[:2], (1, "ezviz-check cam1: shape"))

    def test_statedir(self):
        t = Tree()
        self.assertEqual(self.run_check(t)[:2], (1, "ezviz-check cam1: statedir"))
        t.state.mkdir(parents=True, mode=0o755)
        os.chmod(t.state, 0o755)
        self.assertEqual(self.run_check(t)[:2], (1, "ezviz-check cam1: statedir"))

    def test_latched_and_damaged(self):
        t = self.ready()
        (t.state / "cam1.latch").touch()
        self.assertEqual(self.run_check(t)[:2], (1, "ezviz-check cam1: latched"))
        (t.state / "cam1.latch").unlink()
        t.ledger().write_text(rec(-10, "attempt") + "garbage\n" + rec(-5, "stop"))
        self.assertEqual(self.run_check(t)[:2], (1, "ezviz-check cam1: ledger_damaged"))

    def test_bad_name_is_usage(self):
        self.assertEqual(self.run_check(self.ready(), name="../x")[0], 2)

    def test_no_canary_and_no_pyezvizapi(self):
        rc, out, err = self.run_check(self.ready(camfile=GOOD.replace("8000", "x")))
        for c in CANARIES:
            self.assertNotIn(c, out + err)
        self.assertEqual(err, "")

    def test_unreadable_ledger_is_statedir(self):
        if os.geteuid() == 0:
            self.skipTest("root ignores file modes")
        t = self.ready()
        t.ledger().write_text(rec(-10, "attempt"))
        t.ledger().chmod(0o000)
        self.assertEqual(self.run_check(t), (1, "ezviz-check cam1: statedir", ""))

    def test_unreadable_camfile_dir_is_missing_without_traceback(self):
        if os.geteuid() == 0:
            self.skipTest("root ignores file modes")
        t = self.ready()
        os.chmod(t.cams, 0o000)
        try:
            self.assertEqual(self.run_check(t), (1, "ezviz-check cam1: missing", ""))
        finally:
            os.chmod(t.cams, 0o700)

    def test_no_library_import(self):
        t = self.ready()
        p = subprocess.run([sys.executable, "-I", "-B", "-X", "importtime", "-m", "ezviz_source.check", "cam1"],
                           env=t.env(), capture_output=True, text=True, timeout=30)
        self.assertEqual((p.returncode, p.stdout.strip()), (0, "ezviz-check cam1: ok"), p.stderr[-1500:])
        self.assertIn("ezviz_source.ledger", p.stderr)          # control: importtime lines are there
        self.assertNotIn("pyezvizapi", p.stderr)
        self.assertNotIn("ezviz_source.camera", p.stderr)


if __name__ == "__main__":
    unittest.main()
