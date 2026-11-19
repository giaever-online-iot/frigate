"""The loopback fake camera (W-23 T8), driven by the real pyEzvizApi 2.0.0 client and its built-in plan."""
import _path
import json
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

import fakecam
import fixtures
from ezviz_source.annexb import Reassembler
from pyezvizapi.exceptions import PyEzvizError
from pyezvizapi.streaming.local.hcnetsdk.protocol_types.endpoints import HcNetSdkLanEndpoint
from pyezvizapi.streaming.local.session import (
    hcnetsdk_command_port_native_lan_live_view_plan,
    open_hcnetsdk_command_port_generated_multi_socket_stream,
)

CODE, WRONG = "QZCNRA", "QZWRNG"
FAKECAM = Path(__file__).resolve().parent / "fakecam.py"


def wait_for(pred, timeout=3.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(0.02)
    return pred()


def open_stream(port: int, password: str = CODE):
    ep = HcNetSdkLanEndpoint(serial="TESTCAM-0001", host="127.0.0.1", command_port=port)
    return open_hcnetsdk_command_port_generated_multi_socket_stream(
        ep, hcnetsdk_command_port_native_lan_live_view_plan(), password=password, username="admin", timeout=5.0)


class FakeCamTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.es = self.tmp / "clip.h265"
        self.es.write_bytes(fixtures.SYNTH_ES)

    def server(self, **kw) -> "fakecam.Server":
        s = fakecam.Server(code=CODE, es=self.es, port=0, **kw)
        self.addCleanup(s.close)
        return s

    def test_login_ok_counts_one_and_11_connects(self):
        s = self.server()
        with open_stream(s.port) as st:
            got = list(st.iter_packets(max_packets=10))
        self.assertEqual(len(got), 10)
        self.assertEqual(s.stats["logins_ok"], 1)
        self.assertEqual(s.stats["connects"], 11)
        self.assertEqual(s.stats["logins_rejected"], 0)
        self.assertEqual(s.stats["media_sessions"], 1)

    def test_reject_raises_login_failed(self):
        # Through the CLI, as Tasks 11/15 run it: -I proves it needs nothing beyond stdlib + pycryptodome.
        stats, portf = self.tmp / "stats.json", self.tmp / "port"
        p = subprocess.Popen([_path.isolated_python(), "-I", str(FAKECAM), "--port", "0", "--code", CODE, "--stats", str(stats),
                              "--es", str(self.es), "--reject", "--port-file", str(portf)],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: p.poll() is None and p.kill())
        self.assertTrue(wait_for(lambda: portf.exists() and portf.read_text().strip().isdigit(), 5.0))
        with self.assertRaisesRegex(PyEzvizError, "HCNetSDK command-port login failed"):
            with open_stream(int(portf.read_text())) as st:
                list(st.iter_packets(max_packets=1))
        s = json.loads(stats.read_text())
        self.assertEqual(sorted(s), sorted(["connects", "logins_ok", "logins_rejected", "keepalives",
                                            "media_sessions", "attempt_on_disk_at_accept"]))
        self.assertEqual((s["logins_rejected"], s["connects"], s["logins_ok"]), (1, 1, 0))
        p.send_signal(signal.SIGTERM)
        out, err = p.communicate(timeout=5)
        self.assertEqual(p.returncode, 0, err)

    def test_wrong_code_is_rejected(self):
        s = self.server()
        with self.assertRaisesRegex(PyEzvizError, "HCNetSDK command-port login failed"):
            with open_stream(s.port, WRONG) as st:
                list(st.iter_packets(max_packets=1))
        self.assertEqual((s.stats["logins_rejected"], s.stats["logins_ok"], s.stats["connects"]), (1, 0, 1))

    def test_media_packets_reassemble(self):
        s = self.server()
        r, types = Reassembler(), set()
        with open_stream(s.port) as st:
            for pkt in st.iter_packets(max_packets=50):
                for nal in r.push(pkt.body):
                    types.add((nal[4] >> 1) & 0x3F)
        self.assertTrue({32, 33, 34, 19, 1} <= types, types)

    def test_keepalives_counted(self):
        s = self.server()
        with open_stream(s.port) as st:
            n = sum(1 for _ in st.iter_packets(duration_seconds=13.0))   # keepalives at ~5 s and ~10 s; margin for CI
        self.assertGreater(n, 200)                    # 25 fps for 11 s, paced
        self.assertTrue(wait_for(lambda: s.stats["keepalives"] >= 2), s.stats)

    def test_ledger_at_accept_records_attempt_presence(self):
        ledger = self.tmp / "cam1.ledger"
        ledger.write_text('{"t":1,"ev":"attempt","dur":null}\n{"t":2,"ev":"login_o')
        partial = self.tmp / "partial.ledger"
        partial.write_text('{"t":1,"ev":"attempt","dur":null}')     # no newline: not a complete line
        for path, want in ((ledger, [True]), (self.tmp / "missing.ledger", [False]), (partial, [False])):
            s = self.server(ledger_at_accept=path)
            with socket.create_connection(("127.0.0.1", s.port), timeout=2):
                self.assertTrue(wait_for(lambda: s.stats["connects"] == 1), s.stats)
            self.assertEqual(s.stats["attempt_on_disk_at_accept"], want, path.name)
            s.close()


if __name__ == "__main__":
    unittest.main()
