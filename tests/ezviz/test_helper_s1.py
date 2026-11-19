"""S1 (the rest) on the real entry point: ezviz-source as a process against the loopback fake camera (W-23 T11).

Spec §9.2 S1, §4.1, §4.5, D18, F3, F4, G3, N5, N8; carry-overs R2-N4 and C17. Signals go out on ledger (or
fake-camera) events, never after a bare sleep.
"""
import _path  # noqa: F401
import subprocess
import sys
import time
import unittest
from pathlib import Path
from unittest import mock

import fixtures
from fixtures import CANARIES, CODE, LOOPBACK, SERIAL, Helper, HelperCase, evs, rec
from ezviz_source import policy


class HelperS1(HelperCase):
    def test_attempt_record_on_disk_before_fake_sees_connect(self):     # F3 (C2: the fake reads the ledger at accept)
        h = Helper(self.tmp, "cam1", [])
        h.wait_ev("login_ok", 30)
        h.wait_stats(lambda s: s["media_sessions"] >= 1, 30)           # every plan socket has connected
        h.term()
        h.wait_exit(10)
        st = h.stats()
        seen = st["attempt_on_disk_at_accept"]
        self.assertEqual(len(seen), st["connects"])
        self.assertGreaterEqual(len(seen), 2)                            # the login socket and the plan's
        self.assertTrue(all(seen), seen)

    def test_second_helper_while_first_holds_session_is_busy_one_login(self):  # F4
        h1 = Helper(self.tmp, "cam1", [])
        h1.wait_ev("login_ok", 30)
        h2 = Helper(self.tmp, "cam1", share_fake=h1)
        h2.wait_exit(10)
        self.assertEqual(h2.rc, 75)
        self.assertIn("ezviz-source cam1: busy", h2.stderr)
        h1.term()
        h1.wait_exit(10)
        self.assertEqual(h1.stats()["logins_ok"], 1)
        self.assertEqual(evs(h1.ledger()).count("attempt"), 1)

    def test_auth_fail_latches_and_next_helper_opens_no_socket(self):  # E2
        h = Helper(self.tmp, "cam1", ["--reject"])
        h.wait_exit(30)
        self.assertEqual(h.rc, 77)
        self.assertEqual(evs(h.ledger()), ["attempt", "auth_fail", "latch"])
        self.assertTrue((h.state / "cam1.latch").exists())
        self.assertIn("ezviz-source cam1: auth_fail", h.stderr)
        connects = h.stats()["connects"]
        self.assertEqual(h.stats()["logins_rejected"], 1)
        h2 = Helper(self.tmp, "cam1", share_fake=h)
        h2.wait_exit(10)
        self.assertEqual(h2.rc, 75)
        self.assertIn("ezviz-source cam1: latched", h2.stderr)
        self.assertEqual(h2.stats()["connects"], connects)
        self.assertEqual(evs(h2.ledger()), ["attempt", "auth_fail", "latch"])

    def test_net_fail_counts_as_attempt(self):                          # E3: a closed port
        h = Helper(self.tmp, "cam1", None)
        h.wait_exit(30)
        self.assertEqual(h.rc, 75)
        self.assertIn("ezviz-source cam1: net_fail", h.stderr)
        recs = h.ledger()
        self.assertEqual(evs(recs), ["attempt", "net_fail"])
        d = policy.decide(recs, time.time(), latch_file=False)
        self.assertEqual(d.attempts_in_window, 1)
        self.assertEqual(d.cls, "budget_wait")

    def test_no_marker_leaks_anywhere(self):                            # §4.5, N8
        # The fake camera listens on loopback, so the camera file's host marker is 127.0.0.1 (the URL's host too):
        # the bare host is checked where the URL never goes (stdout, stderr, ledger, ffmpeg environ); argv is checked
        # for host:port, the serial and the login. The GOOD markers (192.0.2.11) are checked everywhere as well.
        runs = {}
        h = Helper(self.tmp / "auth", "cam1", ["--reject"])
        h.wait_exit(30)
        runs["auth_fail"] = (h, [])
        h = Helper(self.tmp / "net", "cam1", None)
        h.wait_exit(30)
        runs["net_fail"] = (h, [])
        h = Helper(self.tmp / "send", "cam1", ["--close-after-s", "1"])
        h.wait_ev("login_ok", 30)
        env = [Path(f"/proc/{h.ffmpeg_pid()}/environ").read_bytes()]
        h.wait_exit(30)
        runs["session_end"] = (h, env)
        h = Helper(self.tmp / "oend", "cam1", [], ffmpeg_knobs={"exit_after_s": 2})
        h.wait_ev("login_ok", 30)
        env = [Path(f"/proc/{h.ffmpeg_pid()}/environ").read_bytes()]
        h.wait_exit(30)
        runs["output_end"] = (h, env)
        h = Helper(self.tmp / "stop", "cam1", [])
        h.wait_ev("published", 30)
        env = [Path(f"/proc/{h.ffmpeg_pid()}/environ").read_bytes()]
        h.term()
        h.wait_exit(10)
        runs["stop"] = (h, env)

        for want, (h, environs) in runs.items():
            ends = [e for e in evs(h.ledger()) if e != "latch"]         # auth_fail is followed by its latch (E2)
            self.assertEqual(ends[-1], want, h.stderr)                   # every class was driven
            self.assertTrue(h.cmdline)
            hostport = f"{LOOPBACK}:{h.cam_port}".encode()
            sources = {"stdout": h.stdout.encode(), "stderr": h.stderr.encode(),
                       "ledger": h.ledger_path.read_bytes()}
            sources.update({f"ffmpeg environ {i}": e for i, e in enumerate(environs)})
            for where, data in sources.items():
                for marker in (*CANARIES, LOOPBACK, SERIAL, CODE):
                    self.assertNotIn(marker.encode(), data, f"{want}: {marker} in {where}")
            for marker in (*CANARIES, SERIAL, CODE):
                self.assertNotIn(marker.encode(), h.cmdline, f"{want}: {marker} in cmdline")
            self.assertNotIn(hostport, h.cmdline, f"{want}: host:port in cmdline")

    def test_missing_ffmpeg_is_config_78_no_contact(self):              # R2-N4 (+ review fix 3)
        cases = {}
        cases["missing"] = Helper(self.tmp / "missing", "cam1", [], ffmpeg=False)
        h = Helper(self.tmp / "mode0644", "cam1", [], ffmpeg=False, start=False)
        h.ffmpeg_path.write_text("#!/bin/sh\nexit 0\n")
        h.ffmpeg_path.chmod(0o644)                                       # a file, but not executable
        cases["mode0644"] = h
        h = Helper(self.tmp / "dir", "cam1", [], ffmpeg=False, start=False)
        h.ffmpeg_path.mkdir(mode=0o755)                                  # X_OK holds for a directory
        cases["dir"] = h
        h = Helper(self.tmp / "nodata", "cam1", [], start=False)
        del h.env["SNAP_DATA"]                                           # the ffmpeg is fine; the env is not
        cases["no SNAP_DATA"] = h
        for why, h in cases.items():
            if h.proc is None:
                h.start()
            h.wait_exit(10)
            self.assertEqual(h.rc, 78, f"{why}: {h.stderr}")
            self.assertIn("ezviz-source cam1: config", h.stderr, why)
            self.assertNotIn("Traceback", h.stderr, why)
            self.assertFalse(h.ledger_path.exists(), why)
            self.assertFalse((h.state / "cam1.session").exists(), why)     # no lock taken either
            self.assertEqual(h.stats()["connects"], 0, why)

    def test_budget_wait_refusal_on_main_entry_fast_and_no_library_import(self):  # C17, N5
        now = time.time()
        fixtures.seed_ledger(self.tmp, [rec(now - 10, "attempt"), rec(now - 9, "net_fail", 1.0)])
        h = Helper(self.tmp, "cam1", None, start=False)
        argv = [_path.isolated_python(), "-I", "-B", "-X", "importtime", "-m", "ezviz_source.main", "cam1",
                "rtsp://127.0.0.1:1/x"]
        times = []
        for _ in range(3):
            t0 = time.monotonic()
            p = subprocess.run(argv, env=h.env, capture_output=True, text=True, timeout=30)
            times.append(time.monotonic() - t0)
            self.assertEqual(p.returncode, 75, p.stderr[-2000:])
            self.assertIn("ezviz-source cam1: budget_wait", p.stderr)
            self.assertIn("ezviz_source.gate", p.stderr)                # control: importtime lines are there
            self.assertNotIn("pyezvizapi", p.stderr)
            self.assertNotIn("ezviz_source.camera", p.stderr)
        print(f"evidence - budget_wait on the main entry: {', '.join(f'{t * 1000:.0f}' for t in times)} ms",
              file=sys.stderr)
        self.assertLess(min(times), 0.150)

    def test_internal_error_before_contact_is_one_fixed_line_and_75(self):   # fix wave 1, N2
        # A hand-edited ledger (review N2): the first session has `published` but no end before the next `attempt`,
        # so policy.decide raises a TypeError inside gate.admit. No traceback, one fixed line, exit 75, no contact.
        now = time.time()
        seed = [rec(now - 900, "attempt"), rec(now - 899, "login_ok"), rec(now - 890, "published"),
                rec(now - 600, "attempt"), rec(now - 599, "net_fail", 1.0)]
        fixtures.seed_ledger(self.tmp, seed)
        with self.assertRaises(TypeError):                               # control: this ledger does make decide raise
            policy.decide(fixtures.read_ledger(self.tmp), now, latch_file=False)
        h = Helper(self.tmp, "cam1", [])
        h.wait_exit(15)
        self.assertEqual((h.rc, h.stderr), (75, "ezviz-source cam1: internal TypeError\n"))
        self.assertNotIn("Traceback", h.stderr)
        self.assertEqual(h.stats()["connects"], 0)
        self.assertEqual(fixtures.read_ledger(self.tmp), seed)          # nothing written: no attempt, no end


class KeepaliveFailedEndsTheSession(unittest.TestCase):
    """T11 review mutant R3: the keepalive-failure end of Helper.run(), in-process with a stand-in camera session.

    No process test reaches it (the library's keepalive reads no reply). The stand-in keeps yielding packets and
    reports a failed keepalive; were the check skipped, its packets run out with an error that classifies as
    protocol_fail, never session_end.
    """

    class Session:
        made = []

        def __init__(self, cam, *, plan, timeout, on_login_ok):
            self.served, self.sampled, self.exited = 0, 0, False
            type(self).made.append(self)

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            self.exited = True

        def packets(self):
            while self.served < 200:
                self.served += 1
                yield b""                                       # no NAL: the reassembler returns nothing
            raise RuntimeError("stand-in packets ran out")      # only reached when the keepalive check is skipped

        def keepalive_failed(self):
            self.sampled += 1
            return True

    class Out:
        def write_au(self, au, idr):
            raise AssertionError("no access unit expected")

        def published_due(self):
            return False

    def end_in(self, phase):
        from ezviz_source import camera, main
        from ezviz_source import constants as C
        self.Session.made = []
        h = main.Helper("cam1", f"rtsp://{LOOPBACK}:8554/cam1")
        h.phase, h.out = phase, self.Out()
        with mock.patch.object(camera, "CameraSession", self.Session), \
                mock.patch.object(camera, "build_plan", return_value=object()):
            got = h.run()
        (s,) = self.Session.made
        self.assertEqual(got, ("session_end", C.EXIT_TEMP))
        self.assertEqual(h.phase, phase)                         # no phase switch, so no record (P2 stays unpublished)
        self.assertEqual((s.served, s.sampled, s.exited), (1, 1, True))   # the first sample ends it; the with exits
        self.assertIs(h.sess, s)                                 # finish()'s close reaches the same session

    def test_keepalive_failure_in_p2_is_session_end(self):
        self.end_in("P2")

    def test_keepalive_failure_in_p3_is_session_end(self):
        self.end_in("P3")


if __name__ == "__main__":
    unittest.main()
