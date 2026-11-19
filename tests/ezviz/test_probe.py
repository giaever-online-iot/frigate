"""Item A's long-session probe (W-23 T12, plan P15, C18) against the loopback fake camera. No real camera.

probe.py <state-dir> <camdir> <name> <minutes> <form> <count> <ffmpeg>; its ledger lives in
<state-dir>/ezviz/state (C18). A 0.5-minute run is the "1-minute run" of the brief.
"""
import _path  # noqa: F401
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

import fixtures
from ezviz_source import policy
from fixtures import CANARIES, CODE, LOOPBACK, SERIAL, evs, rec

HERE = Path(__file__).resolve().parent
PROBE = HERE / "probe.py"
SNAP_FILE = Path(os.environ.get("M7C_AMD64_SNAP") or Path.home() / ".cache/frigate-m7c-evidence/amd64/frigate_0.18.2_amd64.snap")
LINE = re.compile(
    r"^probe cam1: end=(?P<end>\w+) login_ok=(?P<login_ok>\d+) published=(?P<published>[01]) "
    r"session_s=(?P<session_s>[\d.]+) first_irap_s=(?P<first_irap_s>[\d.]+) render_s=(?P<render_s>[\d.]+) "
    r"keepalive_sent=(?P<keepalive_sent>\d+) keepalive_failed=(?P<keepalive_failed>\d+) "
    r"frames=(?P<frames>\d+) decode_errors=(?P<decode_errors>\d+) rtp_ts_monotonic=(?P<mono>[\d.]+) "
    r"rtp_ts_step_mode=(?P<mode>\d+) rtp_ts_step_p99_dev=(?P<dev>\d+) pts_seen=(?P<pts>\[[\d, ]*\])$")

_TOOLS = {}


def real_ffmpeg() -> str:
    """$W23_REAL_FFMPEG, else the 8.0 ffmpeg unsquashed from the local amd64 snap file, else PATH, else skip."""
    if "ff" in _TOOLS:
        return _TOOLS["ff"]
    env = os.environ.get("W23_REAL_FFMPEG")
    if env and os.access(env, os.X_OK):
        _TOOLS["ff"], _TOOLS["src"] = env, "W23_REAL_FFMPEG"
    elif SNAP_FILE.is_file() and shutil.which("unsquashfs"):
        d = tempfile.mkdtemp(prefix="w23-probe-ff-")
        unittest.addModuleCleanup(shutil.rmtree, d, True)
        subprocess.run(["unsquashfs", "-q", "-n", "-d", d + "/r", str(SNAP_FILE), "usr/lib/ffmpeg/8.0/bin/ffmpeg"],
                       capture_output=True, timeout=600)
        ff = d + "/r/usr/lib/ffmpeg/8.0/bin/ffmpeg"
        if os.access(ff, os.X_OK):
            _TOOLS["ff"], _TOOLS["src"] = ff, "snap file 8.0"
    if "ff" not in _TOOLS and shutil.which("ffmpeg"):
        _TOOLS["ff"], _TOOLS["src"] = shutil.which("ffmpeg"), "PATH"
    if "ff" not in _TOOLS:
        raise unittest.SkipTest("no real ffmpeg: set W23_REAL_FFMPEG, provide the amd64 snap file, or install ffmpeg")
    ver = subprocess.run([_TOOLS["ff"], "-version"], capture_output=True, text=True).stdout.splitlines()[:1]
    sys.stderr.write("probe tests: ffmpeg from %s: %s\n" % (_TOOLS["src"], ver))
    return _TOOLS["ff"]


class ProbeCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="w23-probe-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.cams = self.tmp / "cams"
        self.cams.mkdir(mode=0o700)
        self.fake = None
        self.addCleanup(self._stop_fake)

    def _stop_fake(self):
        if self.fake is not None:
            try:
                os.killpg(self.fake.pid, 15)
                self.fake.wait(5)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                pass
            try:
                os.killpg(self.fake.pid, 9)
            except ProcessLookupError:
                pass

    def start_fake(self, ffmpeg: str, *args, clip=None) -> int:
        clip = clip or fixtures.make_es(ffmpeg, self.tmp / "clip.h265", 4)
        self.stats = self.tmp / "fake.stats.json"
        port_file = self.tmp / "fake.port"
        self.fake = subprocess.Popen(
            [_path.isolated_python(), "-I", str(HERE / "fakecam.py"), "--code", CODE, "--es", str(clip), "--stats",
             str(self.stats), "--port-file", str(port_file), *args],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        end = time.monotonic() + 15
        while not port_file.exists():
            self.assertLess(time.monotonic(), end, "fake camera did not start")
            time.sleep(0.02)
        port = int(port_file.read_text())
        f = self.cams / "cam1.conf"
        f.write_text(f"host={LOOPBACK}\nport={port}\nserial={SERIAL}\nlogin={CODE}\n")
        f.chmod(0o600)
        return port

    def probe_cmd(self, ffmpeg: str, minutes="0.5", name="cam1", count="300", diag=False):
        return [_path.isolated_python(), "-I", "-B", str(PROBE), *(["--diag"] if diag else []), str(self.tmp / "common"),
                str(self.cams), name, minutes, "extend", count, ffmpeg]

    def probe(self, ffmpeg: str, minutes="0.5", name="cam1", count="300", diag=False):
        env = _path.child_env()
        for k in ("SNAP", "SNAP_DATA", "SNAP_COMMON"):
            env.pop(k, None)                      # the probe sets its own (C18)
        (self.tmp / "tmp").mkdir(exist_ok=True)
        env["TMPDIR"] = str(self.tmp / "tmp")     # so a leftover hash dir is this run's, and visible
        p = subprocess.run(self.probe_cmd(ffmpeg, minutes, name, count, diag), env=env, stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=180)
        return p

    def ledger(self):
        return fixtures.read_ledger(self.tmp)


class Probe(ProbeCase):
    def test_probe_against_fakecam_prints_one_line_no_marker(self):
        ff = real_ffmpeg()
        self.start_fake(ff)
        p = self.probe(ff)
        self.assertEqual(p.returncode, 0, p.stderr)
        lines = p.stdout.splitlines()
        self.assertEqual(len(lines), 1, p.stdout)
        m = LINE.match(lines[0])
        self.assertIsNotNone(m, lines[0])
        self.assertEqual(m["end"], "stop")
        self.assertEqual(m["login_ok"], "1")
        self.assertGreaterEqual(int(m["frames"]), 600, lines[0])
        self.assertEqual(m["published"], "1")
        self.assertEqual(m["decode_errors"], "0")
        self.assertEqual(m["pts"], "[96]")
        self.assertGreaterEqual(float(m["session_s"]), 29.0)
        self.assertLess(float(m["session_s"]), 0.5 * 60 + 15)                         # the deadline is the deadline
        self.assertEqual(evs(self.ledger()), ["attempt", "login_ok", "published", "stop"])   # D22; D4 applies across runs
        self.assertEqual(self.fake.poll(), None)
        for where, data in (("stdout", p.stdout), ("stderr", p.stderr),
                            ("ledger", (self.tmp / "common/ezviz/state/cam1.ledger").read_text())):
            for marker in (*CANARIES, LOOPBACK, SERIAL, CODE):
                self.assertNotIn(marker, data, f"{marker} in {where}")
        self.assertEqual(list((self.tmp / "tmp").iterdir()), [])    # the hash file is gone

    def test_probe_respects_budget(self):
        ff = real_ffmpeg()
        self.start_fake(ff)
        now = time.time()
        fixtures.seed_ledger(self.tmp, [rec(now - 3000 + 100 * i, "attempt") if i % 2 == 0 else
                                        rec(now - 3000 + 100 * i, "net_fail", 1.0) for i in range(6)])
        before = (self.tmp / "common/ezviz/state/cam1.ledger").read_text()
        t0 = time.monotonic()
        p = self.probe(ff)
        self.assertIn("probe cam1: end=budget_wait", p.stdout, p.stderr)
        self.assertEqual(p.returncode, 75)
        self.assertLess(time.monotonic() - t0, 10)
        self.assertEqual(json.loads(self.stats.read_text())["connects"], 0)
        self.assertEqual((self.tmp / "common/ezviz/state/cam1.ledger").read_text(), before)   # a refusal writes nothing

    def test_rtp_ts_stats(self):
        ff = real_ffmpeg()
        self.start_fake(ff)                                 # fakecam's TS_STEP is a constant 3600 per picture
        p = self.probe(ff)
        m = LINE.match(p.stdout.strip())
        self.assertIsNotNone(m, p.stdout + p.stderr)
        self.assertEqual(m["mode"], "3600")
        self.assertEqual(float(m["mono"]), 1.0)
        self.assertEqual(m["dev"], "0")

    def test_three_clean_probe_runs_do_not_latch(self):                 # I2a: published makes a clean stop a P3 end
        ff = real_ffmpeg()
        self.start_fake(ff)
        for _ in range(3):
            p = self.probe(ff, "0.2")
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertIn("end=stop", p.stdout)
            self.assertIn("published=1", p.stdout)
            fixtures.shift_ledger(self.tmp, 120)                           # past the 60 s spacing
        recs = self.ledger()
        self.assertEqual(evs(recs), ["attempt", "login_ok", "published", "stop"] * 3)
        d = policy.decide(recs, time.time(), latch_file=False)
        self.assertNotEqual(d.cls, "latched")                              # three P2 ends would latch (row 3)
        self.assertFalse(d.latch_now)

    def test_pre_admit_checks_cost_no_attempt(self):                     # M1
        ff = real_ffmpeg()
        self.start_fake(ff)
        p = self.probe(ff, count="1")                                      # build_plan needs >= 6
        self.assertEqual(p.returncode, 64, p.stdout + p.stderr)
        p = self.probe(str(self.tmp / "no-such-ffmpeg"))
        self.assertEqual(p.returncode, 78, p.stdout + p.stderr)
        self.assertFalse((self.tmp / "common/ezviz/state/cam1.ledger").exists())
        self.assertEqual(json.loads(self.stats.read_text())["connects"], 0)

    def test_b2_descriptor_camera_publishes(self):
        # GA A1 diagnosis, H1: a camera that announces its video as 0x45 stream type 0xB2 on PT 96 (hevc in the
        # library's table) must publish like the plain fake; before the fix every packet was dropped (frames=0)
        ff = real_ffmpeg()
        self.start_fake(ff, "--desc-stream-type", "0xb2")
        p = self.probe(ff, "0.2")
        m = LINE.match(p.stdout.strip())
        self.assertIsNotNone(m, p.stdout + p.stderr)
        self.assertEqual((m["end"], m["published"], m["decode_errors"]), ("stop", "1", "0"), p.stdout)
        self.assertGreaterEqual(int(m["frames"]), 200, p.stdout)

    def test_h264_descriptor_camera_is_not_hevc(self):                  # the control: 0x1B owns PT 96, no video
        ff = real_ffmpeg()
        self.start_fake(ff, "--desc-stream-type", "0x1b")
        p = self.probe(ff, "0.2")
        m = LINE.match(p.stdout.strip())
        self.assertIsNotNone(m, p.stdout + p.stderr)
        self.assertEqual((m["login_ok"], m["published"], m["frames"]), ("1", "0", "0"), p.stdout)

    def diag_of(self, p):
        """--diag: the ONE line is the default line, then ` diag=` and compact JSON (no spaces)."""
        lines = p.stdout.splitlines()
        self.assertEqual(len(lines), 1, p.stdout + p.stderr)
        head, sep, js = lines[0].partition(" diag=")
        self.assertEqual(sep, " diag=", lines[0])
        m = LINE.match(head)
        self.assertIsNotNone(m, head)
        self.assertNotIn(" ", js)
        for marker in (*CANARIES, LOOPBACK, SERIAL, CODE):
            self.assertNotIn(marker, p.stdout + p.stderr)
        return m, json.loads(js)

    def test_diag_counters_on_the_plain_fake(self):                     # GA A1 diagnosis: the output shape
        ff = real_ffmpeg()
        self.start_fake(ff)
        p = self.probe(ff, "0.2", diag=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        m, d = self.diag_of(p)
        self.assertEqual((m["end"], m["published"]), ("stop", "1"))
        self.assertEqual(sorted(d), ["au", "desc", "drop", "first", "multi", "nal", "per_min", "pkts", "pt", "route_pt",
                                     "rtp_rej"])
        self.assertGreater(d["pkts"], 200)
        self.assertEqual(sum(d["per_min"]), d["pkts"])
        self.assertEqual(len(d["per_min"]), 1)                          # 0.2 minutes: the first minute only
        self.assertEqual(d["pt"], {"96": d["pkts"]})
        self.assertEqual((d["desc"], d["route_pt"], d["rtp_rej"], d["multi"]), ({}, {}, {}, 0))
        self.assertLessEqual(set(d["drop"]), {"frame", "rtp", "param", "route", "evidence", "direct", "short",
                                              "plausible", "fu_gap", "fu_cap", "fu_part", "held"})
        self.assertGreater(d["drop"].get("fu_part", 0), 0)               # the fake fragments its IDR pictures
        self.assertEqual(sum(v for k, v in d["drop"].items() if k != "fu_part"), 0, d["drop"])
        self.assertTrue({"32", "33", "34", "1"} <= set(d["nal"]), d["nal"])
        idrs = d["nal"].get("19", 0) + d["nal"].get("20", 0)               # x265's clip: IDR_N_LP (20), then CRA (21)
        self.assertGreater(idrs, 0, d["nal"])
        self.assertGreater(d["au"]["n"], 100)
        self.assertIn(d["au"]["idr"], (idrs - 1, idrs))                    # the last AU may still be pending at the stop
        self.assertEqual(d["au"]["vcl"].get("21", 0) + d["au"]["vcl"].get("20", 0) + d["au"]["vcl"].get("19", 0),
                         d["au"]["idr"] + d["au"]["vcl"].get("21", 0))
        self.assertEqual(sum(d["au"]["vcl"].values()), d["au"]["n"])
        self.assertEqual(len(d["first"]), 20)
        for e in d["first"]:
            self.assertEqual(len(e), 5, e)
            ln, hs, pt, tlvs, b2 = e
            self.assertIsInstance(ln, int)
            self.assertEqual((hs, pt, tlvs), (12, 96, []))
            self.assertRegex(b2, r"^[0-9a-f]{4}$")
        self.assertEqual(d["first"][0][4], "4001")                        # VPS (type 32), layer 0, TID 1

    def test_diag_names_the_route_drop(self):                            # 0x1B owns PT 96: every video packet at route
        ff = real_ffmpeg()
        self.start_fake(ff, "--desc-stream-type", "0x1b")
        p = self.probe(ff, "0.2", diag=True)
        m, d = self.diag_of(p)
        self.assertEqual((m["published"], m["frames"]), ("0", "0"))
        self.assertEqual(d["desc"], {"96": 0x1B})
        self.assertEqual(d["drop"], {"route": d["pkts"]})
        self.assertEqual(d["route_pt"], {"96": d["pkts"]})
        self.assertEqual((d["nal"], d["au"]), ({}, {"n": 0, "idr": 0, "vcl": {}}))
        self.assertEqual(d["first"][0][3], [0x45])                        # the descriptor rides on a picture's first packet

    def test_real_shape_camera_publishes(self):
        # GA A1 diagnosis round 2: the real camera announces hevc on PT 15 (never used) and sends it on PT 96. The
        # library promotes PT 96 (payloads.py:1125-1157); before the fix every packet was dropped at route (frames=0)
        ff = real_ffmpeg()
        self.start_fake(ff, "--real-shape")
        p = self.probe(ff, "0.2", diag=True)
        m, d = self.diag_of(p)
        self.assertEqual(d["desc"], {"15": 0x24})
        self.assertEqual(set(d["pt"]), {"96", "104", "112"})
        self.assertEqual(d["first"][0][:4], [64, 12, 112, [0x40, 0x45, 0x41]])
        self.assertEqual(d["first"][1][:4], [44, 12, 112, [0x42, 0x43]])
        self.assertEqual([e[4] for e in d["first"][2:5]], ["4001", "4201", "4401"])
        self.assertEqual(set(d["route_pt"]), {"104", "112"}, d["route_pt"])     # PT 96 is never dropped at route
        self.assertEqual((m["end"], m["published"], m["decode_errors"]), ("stop", "1", "0"), p.stdout)
        self.assertGreaterEqual(int(m["frames"]), 200, p.stdout)

    def test_non_idr_start_is_not_fed_until_the_first_idr(self):        # the IDR gate
        import fakecam
        ff = real_ffmpeg()
        full = fixtures.make_es(ff, self.tmp / "full.h265", 4)
        aus = fakecam.access_units(fakecam.split_nals(full.read_bytes()))
        lead = 12                                                          # 12 P pictures (0.48 s at 25 fps) first
        clip = [n for au in aus[1:1 + lead] + aus[:50] for n in au]
        (self.tmp / "lead.h265").write_bytes(b"".join(b"\x00\x00\x00\x01" + n for n in clip))
        self.start_fake(ff, clip=self.tmp / "lead.h265")
        p = self.probe(ff, "0.2")
        m = LINE.match(p.stdout.strip())
        self.assertIsNotNone(m, p.stdout + p.stderr)
        self.assertGreaterEqual(float(m["first_irap_s"]), 0.4, p.stdout)  # not at the first picture
        self.assertEqual(m["published"], "1")

    def test_sigterm_after_published_is_a_stop(self):                    # signals.install(): a SIGTERM is E13, rc 0
        ff = real_ffmpeg()
        self.start_fake(ff)
        env = _path.child_env()
        for k in ("SNAP", "SNAP_DATA", "SNAP_COMMON"):
            env.pop(k, None)
        (self.tmp / "tmp").mkdir(exist_ok=True)
        env["TMPDIR"] = str(self.tmp / "tmp")
        p = subprocess.Popen(self.probe_cmd(ff, "5"), env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, start_new_session=True)
        self.addCleanup(lambda: p.poll() is None and p.kill())
        end = time.monotonic() + 60
        while "published" not in evs(self.ledger()):
            self.assertLess(time.monotonic(), end, "never published")
            if p.poll() is not None:
                self.fail("probe ended before it published: " + p.communicate()[0])
            time.sleep(0.1)
        p.terminate()
        out, err = p.communicate(timeout=20)
        self.assertEqual(p.returncode, 0, out + err)
        self.assertEqual(evs(self.ledger()), ["attempt", "login_ok", "published", "stop"])
        self.assertEqual(list((self.tmp / "tmp").iterdir()), [])           # the Terminating path removes the hash dir too


class DiagUnit(unittest.TestCase):
    """The counters without a camera or ffmpeg: per-minute bins (minutes=3 gives 3), the 20-packet sample, frames
    that never reach RTP."""

    def setUp(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("w23_probe", PROBE)
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)
        from ezviz_source import annexb
        self.annexb = annexb

    def run_diag(self, bodies_at):
        d, r = self.mod.Diag(self.annexb), self.annexb.Reassembler()
        for t, body in bodies_at:
            d.packet(t, body, r, r.push(body))
        return d.result(r)

    def test_per_minute_bins_for_a_three_minute_run(self):
        body = fixtures.rtp_body(104, 1, 0, b"\x01\x02\x03\x04\x05")
        res = self.run_diag([(t, body) for t in (0.0, 59.9, 60.0, 61.0, 125.0, 179.9)])
        self.assertEqual(res["per_min"], [2, 2, 2])
        self.assertEqual(res["pkts"], 6)
        self.assertEqual((res["pt"], res["drop"], res["route_pt"]), ({"104": 6}, {"route": 6}, {"104": 6}))

    def test_per_minute_bins_stop_at_five(self):
        body = fixtures.rtp_body(104, 1, 0, b"\x01\x02\x03\x04\x05")
        res = self.run_diag([(t * 30.0, body) for t in range(20)])   # 0 .. 570 s
        self.assertEqual(res["per_min"], [2, 2, 2, 2, 2])
        self.assertEqual(res["pkts"], 20)

    def test_first_twenty_and_non_rtp_frames(self):
        legacy = b"\xfa" + bytes([0x80, 96, 0, 1, 0, 0, 0, 0]) + b"\x55\x66\x77\x88" + b"\x40\x01\x0c"
        lbody = len(legacy).to_bytes(4, "little") + legacy
        agg = fixtures.rtp_body(96, 1, 0, b"\x40\x01\x0c\x01") + fixtures.rtp_body(96, 2, 0, b"\x42\x01\x01\x01")
        res = self.run_diag([(0.0, lbody)] * 15 + [(1.0, b"\x00\x01\x02")] * 5 + [(2.0, agg)] * 3)
        self.assertEqual(len(res["first"]), 20)
        self.assertEqual(res["first"][0], [len(lbody), 13, None, [], "4001"])   # header size 13, no RTP, payload 40 01
        self.assertEqual(res["first"][19], [3, None, None, [], ""])
        self.assertEqual(res["rtp_rej"], {"13:fa": 15})
        self.assertEqual(res["multi"], 3)                                        # two sentinels in one body
        self.assertEqual(res["drop"], {"rtp": 15, "frame": 8})


class ProbeCheckout(ProbeCase):
    """Fix wave 1, S4: the probe refuses an ezviz_source that is not its own checkout's, before the gate and any
    contact. No ffmpeg is needed: the refusal comes before the ffmpeg check."""

    def test_foreign_ezviz_source_exits_2_with_no_connect(self):
        plant = self.tmp / "plant"                 # a full, working copy elsewhere: without the guard it would run
        shutil.copytree(_path.PKG / "ezviz_source", plant / "ezviz_source",
                        ignore=shutil.ignore_patterns("__pycache__"))
        srv = socket.socket()
        self.addCleanup(srv.close)
        srv.bind((LOOPBACK, 0))
        srv.listen(8)
        srv.settimeout(0.2)
        connects, stop = [], threading.Event()

        def accept():
            while not stop.is_set():
                try:
                    c, _ = srv.accept()
                except (socket.timeout, OSError):
                    continue
                connects.append(1)
                c.close()
        th = threading.Thread(target=accept, daemon=True)
        th.start()
        f = self.cams / "cam1.conf"
        f.write_text(f"host={LOOPBACK}\nport={srv.getsockname()[1]}\nserial={SERIAL}\nlogin={CODE}\n")
        f.chmod(0o600)
        env = _path.child_env()
        for k in ("SNAP", "SNAP_DATA", "SNAP_COMMON"):
            env.pop(k, None)
        env["PYTHONPATH"] = str(plant)             # ahead of the venv's .pth: the planted package is found first
        cmd = [sys.executable, "-B", str(PROBE), str(self.tmp / "common"), str(self.cams), "cam1", "0.5", "extend",
               "300", "/bin/true"]
        p = subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
        stop.set()
        th.join(5)
        self.assertEqual((p.returncode, p.stdout, p.stderr), (2, "", "probe cam1: wrong_checkout\n"))
        self.assertEqual(connects, [])
        self.assertFalse((self.tmp / "common/ezviz/state/cam1.ledger").exists())   # the gate was never called


if __name__ == "__main__":
    unittest.main()
