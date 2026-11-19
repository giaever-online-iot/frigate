"""Unit tests for spike/bin/go2rtc-config-gen.py (the snap's go2rtc config bridge). Run:
python3 -m unittest discover -s tests -p 'test_*.py' -v"""
import contextlib, importlib.util, io, os, re, subprocess, sys, tempfile, unittest
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


def run_main5(baseline_text, config_text, cams, extra_files=(), extra_dirs=(), symlinks=(),
              chmod000=False, cams_dir_missing=False):
    """Run g2r.main() with the optional 5th argument: a temp cameras dir holding empty
    <name>.conf files for `cams`, plus `extra_files`, `extra_dirs` and `symlinks` (names
    of symlinks to a real file). Returns (rc, output-yaml-or-None, stderr)."""
    with tempfile.TemporaryDirectory() as d:
        base = Path(d, "go2rtc.yaml.in"); base.write_text(baseline_text)
        cfg = Path(d, "config.yml")
        if config_text is not None:
            cfg.write_text(config_text)
        out = Path(d, "go2rtc.yaml")
        cams_dir = Path(d, "cameras")
        if not cams_dir_missing:
            cams_dir.mkdir()
            for n in list(cams) + list(extra_files):
                f = cams_dir / (n if n in extra_files else n + ".conf")
                f.write_text("")
                if chmod000:
                    f.chmod(0)
            for n in extra_dirs:
                (cams_dir / n).mkdir()
            target = Path(d, "target"); target.write_text("")
            for n in symlinks:
                (cams_dir / n).symlink_to(target)
        err = io.StringIO()
        argv = ["go2rtc-config-gen.py", str(base), str(cfg), SNAP, str(out), str(cams_dir)]
        try:
            with mock.patch.object(sys, "argv", argv), contextlib.redirect_stderr(err):
                rc = g2r.main()
            data = yaml.safe_load(out.read_text()) if out.exists() else None
        finally:
            if chmod000 and cams_dir.exists():
                for f in cams_dir.iterdir():
                    f.chmod(0o600)
    return rc, data, err.getvalue()


def exec_line(name):
    return f"exec:{SNAP}/bin/ezviz-source {name} {{output}}#killsignal=15#killtimeout=5"


class TestEzvizEmission(unittest.TestCase):
    def test_stream_and_preload_per_camera(self):
        rc, out, _ = run_main5(BASELINE, None, ["cam1", "cam2"])
        self.assertEqual(rc, 0)
        self.assertEqual(out["streams"]["cam1"], exec_line("cam1"))
        self.assertEqual(out["streams"]["cam2"], exec_line("cam2"))
        self.assertEqual(out["preload"], {"cam1": "video", "cam2": "video"})

    def test_operator_cam1_dropped_redacted(self):  # N7
        cfg = 'go2rtc:\n  streams:\n    cam1: rtsp://admin:QZFAKECODEA@192.0.2.11/x\n'
        rc, out, err = run_main5(BASELINE, cfg, ["cam1"])
        self.assertEqual(rc, 0)
        self.assertEqual(out["streams"]["cam1"], exec_line("cam1"))
        self.assertIn("WARNING operator go2rtc stream cam1 replaced by the snap-owned ezviz camera", err)
        for secret in ("QZFAKECODEA", "192.0.2.11", "admin"):
            self.assertNotIn(secret, err)

    def test_operator_cam1_sub_kept(self):
        cfg = 'go2rtc:\n  streams:\n    cam1_sub: rtsp://u:QZSUB@192.0.2.12/y\n'
        rc, out, err = run_main5(BASELINE, cfg, ["cam1"])
        self.assertEqual(out["streams"]["cam1_sub"], "rtsp://u:QZSUB@192.0.2.12/y")
        self.assertEqual(out["streams"]["cam1"], exec_line("cam1"))
        self.assertNotIn("replaced", err)

    def test_only_valid_camera_files_become_streams(self):  # Review Focus 5
        extras = ["cam1.conf.m7c-new", "CAM2.conf", "x.txt", "cam3.conf.bak", ".conf",
                  "a-b.conf", "x" * 33 + ".conf"]
        rc, out, _ = run_main5(BASELINE, None, ["cam1"], extra_files=extras,
                               extra_dirs=["d.conf"], symlinks=["lnk.conf"])
        self.assertEqual(rc, 0)
        self.assertEqual(out["preload"], {"cam1": "video"})
        base_streams = yaml.safe_load(BASELINE.replace("__SNAP__", SNAP))["streams"]
        self.assertEqual(set(out["streams"]), set(base_streams) | {"cam1"})

    def test_name_length_limit(self):
        rc, out, _ = run_main5(BASELINE, None, ["a" * 32, "b" * 33])
        self.assertIn("a" * 32, out["preload"])
        self.assertNotIn("b" * 33, out["preload"])

    def test_camera_files_never_opened(self):
        with mock.patch("builtins.open", wraps=open) as m:
            rc, out, _ = run_main5(BASELINE, None, ["cam1"])
        opened = [str(c.args[0]) for c in m.call_args_list if c.args]
        self.assertEqual(rc, 0)
        self.assertFalse([p for p in opened if p.endswith("cam1.conf")], opened)
        rc, out, _ = run_main5(BASELINE, None, ["cam1", "cam2"], chmod000=True)
        self.assertEqual(rc, 0)
        self.assertEqual(set(out["preload"]), {"cam1", "cam2"})

    def test_missing_cameras_dir_is_no_cameras(self):  # fix wave 1, N1: the normal state without ezviz cameras
        rc, out, err = run_main5(BASELINE, None, [], cams_dir_missing=True)
        self.assertEqual(rc, 0)
        self.assertNotIn("preload", out)
        self.assertNotIn("WARNING", err)
        self.assertNotIn("cameras dir", err)
        self.assertNotIn("Traceback", err)

    def test_missing_cameras_dir_logs_nothing(self):  # fix wave 1, N1: ENOENT is silent
        with tempfile.TemporaryDirectory() as d:
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                names = g2r.list_camera_names(str(Path(d, "absent")))
        self.assertEqual((names, err.getvalue()), ([], ""))

    def test_other_cameras_dir_errors_still_warn(self):  # fix wave 1, N1: only ENOENT is silent
        with tempfile.TemporaryDirectory() as d:
            notdir = Path(d, "cameras")
            notdir.write_text("")
            cases = {"NotADirectoryError": (str(notdir), None),
                     "PermissionError": (d, PermissionError(13, "denied", "QZSECRETPATH"))}
            for cls, (path, exc) in cases.items():
                err = io.StringIO()
                with contextlib.redirect_stderr(err):
                    if exc is None:
                        names = g2r.list_camera_names(path)
                    else:
                        with mock.patch.object(g2r.os, "listdir", side_effect=exc):
                            names = g2r.list_camera_names(path)
                self.assertEqual((names, err.getvalue()),
                                 ([], f"go2rtc-config-gen: WARNING ezviz cameras dir unreadable ({cls}); "
                                      "no ezviz cameras emitted\n"), cls)

    def test_main_argument_counts(self):
        for argv in (["g"], ["g", "a", "b", "c"], ["g"] + ["a"] * 6):
            err = io.StringIO()
            with mock.patch.object(sys, "argv", argv), contextlib.redirect_stderr(err):
                self.assertEqual(g2r.main(), 2)
            self.assertIn("ERROR usage", err.getvalue())

    def test_no_dir_arg_is_unchanged(self):  # C3: D20 is unconditional
        old_src = subprocess.run(["git", "show", "72e03be:spike/bin/go2rtc-config-gen.py"],
                                 cwd=REPO, capture_output=True, text=True, check=True).stdout
        with tempfile.TemporaryDirectory() as d:
            old_py = Path(d, "old_gen.py"); old_py.write_text(old_src)
            base = Path(d, "go2rtc.yaml.in"); base.write_text(BASELINE)
            old_out = Path(d, "old.yaml")
            subprocess.run([sys.executable, "-B", str(old_py), str(base), str(Path(d, "nocfg")),
                            SNAP, str(old_out)], check=True, capture_output=True)
            old = yaml.safe_load(old_out.read_text())
        rc, new, _ = run_main(BASELINE, None)
        self.assertEqual(rc, 0)
        self.assertNotIn("preload", new)
        self.assertEqual(new["streams"], old["streams"])
        expected_api = dict(old["api"], local_auth=False, base_path="")
        self.assertEqual(new["api"], expected_api)

    def test_api_forced_keys(self):  # D20
        cfg = ('go2rtc:\n  api:\n    username: u\n    password: QZPASS\n    local_auth: true\n'
               '    base_path: /x\n    allow_paths: [/api/streams]\n')
        rc, out, err = run_main5(BASELINE, cfg, ["cam1"])
        self.assertEqual((out["api"]["local_auth"], out["api"]["base_path"]), (False, ""))
        self.assertIn("/api/preload", out["api"]["allow_paths"])
        self.assertIn("/api/streams", out["api"]["allow_paths"])
        for k in ("local_auth", "base_path", "allow_paths"):
            self.assertIn(f"go2rtc.api.{k} overridden", err)
        for secret in ("QZPASS", "/x", "/api/streams"):
            self.assertNotIn(secret, err)

    def test_allow_paths_already_has_preload_untouched(self):
        cfg = 'go2rtc:\n  api:\n    allow_paths: [/api/preload, /api/streams]\n'
        rc, out, err = run_main5(BASELINE, cfg, ["cam1"])
        self.assertEqual(out["api"]["allow_paths"], ["/api/preload", "/api/streams"])
        self.assertNotIn("allow_paths overridden", err)

    def test_no_override_no_warning(self):
        rc, out, err = run_main5(BASELINE, None, ["cam1"])
        self.assertNotIn("overridden", err)
        self.assertNotIn("allow_paths", out["api"])

    def test_starttimeout_constant_matches_helper(self):
        gen = (REPO / "spike/bin/go2rtc-config-gen.py").read_text()
        helper = (REPO / "spike/ezviz/ezviz_source/constants.py").read_text()
        rx = re.compile(r"^STARTTIMEOUT_S\s*=\s*(\d+)", re.M)
        g, h = rx.search(gen), rx.search(helper)
        self.assertTrue(g and h)
        self.assertEqual(g.group(1), h.group(1))
        self.assertEqual(int(g.group(1)), g2r.STARTTIMEOUT_S)


if __name__ == "__main__":
    unittest.main()
