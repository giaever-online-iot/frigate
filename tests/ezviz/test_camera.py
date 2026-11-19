"""The library boundary (W-23 T9): plan builder (P5), the login_ok hook (P1/P2), error classes (P3), logging (N8).

Driven against the in-process loopback fake (fakecam.Server) on 127.0.0.1 with the canary code; a closed port for
connect-refused. Library references are pyEzvizApi 2.0.0.
"""
import _path
import dataclasses
import itertools
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import fakecam
import fixtures
from ezviz_source import camera
from ezviz_source.annexb import Reassembler
from ezviz_source.camfile import Camera
from pyezvizapi.exceptions import DeviceException, PyEzvizError
from pyezvizapi.streaming.local import session as libsession
from pyezvizapi.streaming.local.session import hcnetsdk_command_port_native_lan_live_view_plan

CODE = "QZCNRA"


def media_step(plan):
    (step,) = [s for s in plan.steps if s.media_socket]
    return step


def closed_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()                       # nothing listens: connect is refused
    return port


class PlanTests(unittest.TestCase):
    def test_build_plan_extend_deltas(self):
        ka = media_step(camera.build_plan("extend", 8)).keepalive_templates
        self.assertEqual([t.addend_delta for t in ka], [10, 16, 22, 28, 34, 40, 46, 52])
        self.assertEqual({t.command_id for t in ka}, {0x30006})
        # and the P5 guards
        for form, count in (("other", 8), ("extend", 5), ("repeat", 0)):
            with self.assertRaises(ValueError):
                camera.build_plan(form, count)

    def test_build_plan_repeat_deltas(self):
        ka = media_step(camera.build_plan("repeat", 8)).keepalive_templates
        self.assertEqual([t.addend_delta for t in ka], [10, 16, 22, 28, 34, 40, 40, 40])
        self.assertEqual({t.command_id for t in ka}, {0x30006})

    def test_other_steps_untouched(self):
        base = hcnetsdk_command_port_native_lan_live_view_plan()
        for form in ("extend", "repeat"):
            plan = camera.build_plan(form, 4320)
            self.assertEqual(len(plan.steps), len(base.steps))
            for got, want in zip(plan.steps, base.steps):
                if want.media_socket:      # everything but the keepalive list is as built
                    self.assertEqual(dataclasses.replace(got, keepalive_templates=want.keepalive_templates), want)
                    self.assertEqual(len(got.keepalive_templates), 4320)
                else:
                    self.assertEqual(got, want)

    def test_render_seconds_measured(self):
        r = camera.render_seconds(camera.build_plan("extend", 4320))
        print(f"evidence - render 4320 keepalives: {r:.2f}s", file=sys.stderr)
        self.assertLess(r, 30)


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.es = self.tmp / "clip.h265"
        self.es.write_bytes(fixtures.SYNTH_ES)
        self.calls = []

    def server(self, **kw) -> "fakecam.Server":
        s = fakecam.Server(code=CODE, es=self.es, port=0, **kw)
        self.addCleanup(s.close)
        return s

    def session(self, port: int, *, timeout: float = 5.0, hook=None) -> "camera.CameraSession":
        cam = Camera("cam1", "127.0.0.1", port, "TESTCAM-0001", CODE)
        cs = camera.CameraSession(cam, plan=camera.build_plan("extend", 6), timeout=timeout,
                                  on_login_ok=hook or (lambda: self.calls.append("login_ok")))
        self.addCleanup(cs.__exit__, None, None, None)
        return cs

    def fail_of(self, cs) -> BaseException:
        """Open and read until the library raises; return that exception."""
        try:
            with cs:
                for _ in cs.packets():
                    pass
        except Exception as e:  # noqa: BLE001 - the test classifies whatever the library raised
            return e
        self.fail("the stream ended without an exception")

    def test_login_ok_hook_fires_once_after_login(self):
        s = self.server()
        cs = self.session(s.port, hook=lambda: self.calls.append((s.stats["logins_ok"], s.stats["connects"])))
        self.assertFalse(cs.logged_in)
        with cs:
            got = list(itertools.islice(cs.packets(), 5))
        self.assertEqual(len(got), 5)
        self.assertEqual(self.calls, [(1, 1)])      # after login, before the plan's first connection
        self.assertTrue(cs.logged_in)
        self.assertEqual(s.stats["connects"], 11)
        self.assertFalse(cs.keepalive_failed())
        cs.__exit__(None, None, None)              # idempotent (R2-N2: Task 11's finish() calls it again)

    def test_login_ok_hook_not_called_on_reject(self):
        s = self.server(reject=True)
        cs = self.session(s.port)
        e = self.fail_of(cs)
        self.assertEqual(camera.classify(e, logged_in=cs.logged_in), "auth_fail")
        self.assertFalse(cs.logged_in)
        self.assertEqual(self.calls, [])
        self.assertEqual(s.stats["logins_rejected"], 1)

    def test_classify_connect_refused_is_net_fail(self):
        cs = self.session(closed_port())
        e = self.fail_of(cs)
        self.assertIsInstance(e, OSError)
        self.assertEqual(camera.classify(e, logged_in=cs.logged_in), "net_fail")
        self.assertEqual(self.calls, [])

    def test_classify_challenge_timeout_is_net_fail(self):
        s = self.server(silent_before_challenge=True)
        cs = self.session(s.port, timeout=1.0)
        e = self.fail_of(cs)
        self.assertIsInstance(e, DeviceException)
        self.assertEqual(camera.classify(e, logged_in=cs.logged_in), "net_fail")
        self.assertEqual(self.calls, [])

    def test_classify_after_login_close_is_session_end(self):
        s = self.server(close_after_s=2)
        cs = self.session(s.port)
        e = self.fail_of(cs)
        self.assertTrue(cs.logged_in)
        self.assertEqual(self.calls, ["login_ok"])
        self.assertEqual(camera.classify(e, logged_in=cs.logged_in), "session_end")

    def test_classify_after_login_stall_is_session_end(self):
        s = self.server(stall_after_s=2)
        cs = self.session(s.port, timeout=1.0)
        e = self.fail_of(cs)
        self.assertTrue(cs.logged_in)
        self.assertEqual(camera.classify(e, logged_in=cs.logged_in), "session_end")

    def test_classify_protocol_error_after_login(self):
        self.assertEqual(camera.classify(PyEzvizError("interleaved frame length is invalid"), logged_in=True),
                         "protocol_fail")
        # the same message before login is a network-class failure, and the login message after it is not auth
        self.assertEqual(camera.classify(PyEzvizError("interleaved frame length is invalid"), logged_in=False),
                         "net_fail")
        self.assertEqual(camera.classify(PyEzvizError("HCNetSDK command-port login failed"), logged_in=True),
                         "protocol_fail")

    def test_reassembler_matches_library_byte_for_byte(self):
        # Differential: our streaming reassembler vs the library's batch path over the same 300 bodies.
        s = self.server(fps=500.0)
        cs = self.session(s.port)
        with cs:
            bodies = list(itertools.islice(cs.packets(), 300))
        self.assertEqual(len(bodies), 300)
        r = Reassembler()
        ours = b"".join(nal for b in bodies for nal in r.push(b))
        original = libsession._decrypt_hevc_nal_prefix        # as the W-20 T10 offline harness (L130-138)
        libsession._decrypt_hevc_nal_prefix = lambda nal, key: nal
        try:
            lib = libsession._decrypt_idmx_local_packets_to_annexb_with_codec(
                bodies, b"\0" * 16, nalu_header_size=0, decrypt_hevc_parameter_sets=False)
        finally:
            libsession._decrypt_hevc_nal_prefix = original
        self.assertGreater(len(ours), 10000)
        self.assertEqual(ours, lib[0])


class LoggingTests(unittest.TestCase):
    PROG = ("import logging\nfrom ezviz_source import camera\n{call}"
            "logging.getLogger('pyezvizapi.client').warning('x')\n")

    def run_child(self, call: str) -> str:
        p = subprocess.run([sys.executable, "-c", self.PROG.format(call=call)], env=_path.child_env(),
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stderr

    def test_library_logging_silenced(self):
        self.assertIn("x", self.run_child(""))      # control: unsilenced, the last-resort handler prints it
        self.assertEqual(self.run_child("camera.silence_library_logging()\n"), "")


if __name__ == "__main__":
    unittest.main()
