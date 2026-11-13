"""Unit tests for spike/bin/go2rtc-config-gen.py (the snap's go2rtc config bridge). Run:
python3 -m unittest discover -s tests -p 'test_*.py' -v"""
import contextlib, importlib.util, io, os, sys, tempfile, unittest
from pathlib import Path
from unittest import mock

import yaml

REPO = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("g2r", REPO / "spike/bin/go2rtc-config-gen.py")
g2r = importlib.util.module_from_spec(_spec)
sys.dont_write_bytecode = True  # spike/bin is dumped verbatim into the snap by the wrappers part; no .pyc there
_spec.loader.exec_module(g2r)
BASELINE = (REPO / "spike/config/go2rtc.yaml.in").read_text()
SNAP = "/snap/frigate/x1"


def run_main(baseline_text, config_text):
    """Run g2r.main() on temp files exactly as go2rtc-run does (4 positional args).
    config_text=None means config.yml is absent. Returns (rc, output-yaml-or-None, stderr)."""
    with tempfile.TemporaryDirectory() as d:
        base = Path(d, "go2rtc.yaml.in"); base.write_text(baseline_text)
        cfg = Path(d, "config.yml")
        if config_text is not None:
            cfg.write_text(config_text)
        out = Path(d, "go2rtc.yaml")
        err = io.StringIO()
        argv = ["go2rtc-config-gen.py", str(base), str(cfg), SNAP, str(out)]
        with mock.patch.object(sys, "argv", argv), contextlib.redirect_stderr(err):
            rc = g2r.main()
        data = yaml.safe_load(out.read_text()) if out.exists() else None
    return rc, data, err.getvalue()


class TestResolveFfmpegPath(unittest.TestCase):
    def test_default(self):
        self.assertEqual(g2r.resolve_ffmpeg_path("default", "ffmpeg", SNAP), f"{SNAP}/usr/lib/ffmpeg/8.0/bin/ffmpeg")

    def test_alias_7(self):
        self.assertEqual(g2r.resolve_ffmpeg_path("7.0", "ffmpeg", SNAP), f"{SNAP}/usr/lib/ffmpeg/7.0/bin/ffmpeg")

    def test_unknown_alias_falls_back(self):
        self.assertEqual(g2r.resolve_ffmpeg_path("6.0", "ffmpeg", SNAP), f"{SNAP}/usr/lib/ffmpeg/8.0/bin/ffmpeg")

    def test_absolute(self):
        self.assertEqual(g2r.resolve_ffmpeg_path("/opt/ff", "ffprobe", SNAP), "/opt/ff/bin/ffprobe")

    def test_main_default_without_config(self):
        rc, out, _ = run_main(BASELINE, None)
        self.assertEqual(rc, 0)
        self.assertEqual(out["ffmpeg"]["bin"], f"{SNAP}/usr/lib/ffmpeg/8.0/bin/ffmpeg")

    def test_main_honours_top_level_ffmpeg_path(self):
        rc, out, _ = run_main(BASELINE, 'ffmpeg:\n  path: "7.0"\n')
        self.assertEqual(rc, 0)
        self.assertEqual(out["ffmpeg"]["bin"], f"{SNAP}/usr/lib/ffmpeg/7.0/bin/ffmpeg")

    def test_operator_go2rtc_ffmpeg_bin_wins(self):
        rc, out, _ = run_main(BASELINE, 'ffmpeg:\n  path: "7.0"\ngo2rtc:\n  ffmpeg:\n    bin: /x/ffmpeg\n')
        self.assertEqual(rc, 0)
        self.assertEqual(out["ffmpeg"]["bin"], "/x/ffmpeg")

    def test_unparseable_config_uses_default(self):
        rc, out, err = run_main(BASELINE, "ffmpeg: [unclosed\n")
        self.assertEqual(rc, 0)
        self.assertEqual(out["ffmpeg"]["bin"], f"{SNAP}/usr/lib/ffmpeg/8.0/bin/ffmpeg")
        self.assertIn("failed to parse", err)


if __name__ == "__main__":
    unittest.main()
