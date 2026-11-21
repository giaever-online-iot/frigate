import _path
import hashlib
import importlib.metadata as md
import os
import re
import unittest
from unittest import mock

from ezviz_source import constants as C
from ezviz_source import paths

# sha256 of d5260d4:docs/superpowers/plans/ezviz-t10/requirements.txt (the W-20 lock). A literal, because d5260d4
# is on no remote branch and CI checks out shallow (plan SF5).
LOCK_SHA256 = "b3282719e5c607e53f5de0943244075708bc2948ec6b4aa130050ce033ab4921"


class TestRuntime(unittest.TestCase):
    def test_lock_is_the_w20_lock(self):
        got = hashlib.sha256((_path.REPO / "spike/ezviz/requirements.txt").read_bytes()).hexdigest()
        self.assertEqual(got, LOCK_SHA256)

    def test_pinned_wheel_hash_in_lock(self):
        self.assertIn("ed7c309a1af18e0cdc3665a87d7a1c30c21581ba80a25115d748f76ed2f349f8",
                      (_path.REPO / "spike/ezviz/requirements.txt").read_text())

    def test_pyezvizapi_200_installed(self):
        self.assertEqual(md.version("pyezvizapi"), "2.0.0")

    def test_budget_constants(self):
        self.assertEqual((C.CAP_ATTEMPTS, C.WINDOW_S, C.SPACING_S, C.LADDER_S, C.LATCH_ROW), (3, 3600, 60, (60, 300, 900), 3))

    def test_exit_codes(self):
        self.assertEqual((C.EXIT_STOP, C.EXIT_TEMP, C.EXIT_AUTH, C.EXIT_CONFIG, C.EXIT_USAGE), (0, 75, 77, 78, 64))

    def test_constants_match_findings(self):
        """Task 21 Step 1: constants.py equals the `chosen:` line in docs/w23-findings.md section A, which the plan's
        rules derive from gate GA's probe lines (recorded there as results)."""
        doc = (_path.REPO / "docs/w23-findings.md").read_text()
        got = re.findall(r"^chosen: form=(\w+) count=(\d+) starttimeout=(\d+) timestamps=(\w+)$", doc, re.M)
        self.assertEqual(len(got), 1, "exactly one chosen: line in docs/w23-findings.md")
        form, count, start, ts = got[0]
        self.assertEqual((C.KEEPALIVE_FORM, C.KEEPALIVE_COUNT, C.STARTTIMEOUT_S, C.TIMESTAMP_MODE),
                         (form, int(count), int(start), ts))
        src = (_path.PKG / "ezviz_source/constants.py").read_text()
        for name in ("KEEPALIVE_FORM", "KEEPALIVE_COUNT", "STARTTIMEOUT_S", "TIMESTAMP_MODE"):
            line = [ln for ln in src.splitlines() if ln.startswith(name + " = ")]
            self.assertEqual(len(line), 1, name)
            self.assertNotIn("PROVISIONAL", line[0], name)             # settled by gate GA (Task 21)
            self.assertIn("gate GA", line[0], name)

    def test_paths_from_env(self):
        with mock.patch.dict(os.environ, {"SNAP": "/s", "SNAP_DATA": "/d", "SNAP_COMMON": "/c"}):
            self.assertEqual(str(paths.camera_dir()), "/d/ezviz/cameras")
            self.assertEqual(str(paths.state_dir()), "/c/ezviz/state")
            self.assertEqual(paths.ffmpeg(), "/s/usr/lib/ffmpeg/8.0/bin/ffmpeg")


if __name__ == "__main__":
    unittest.main()
