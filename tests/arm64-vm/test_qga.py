import base64
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

sys.dont_write_bytecode = True
# QGA_DIR lets a throwaway mutation run point the tests at a modified copy of qga.py.
QGA_DIR = os.environ.get("QGA_DIR") or os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, QGA_DIR)
import qga  # noqa: E402


def fake_agent(path, exitcode, out, polls_before_exit=2, stale=None, flood=False):
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(1)

    def serve():
        conn, _ = srv.accept()
        f = conn.makefile("rwb")
        try:
            polls = 0
            for line in f:
                req = json.loads(line)
                ex = req["execute"]
                if ex == "guest-sync":
                    if flood:
                        try:
                            while True:
                                f.write(b'{"return": {"pid": 99}}\n')
                                f.flush()
                        except OSError:
                            return
                    if stale is not None:
                        f.write((json.dumps(stale) + "\n").encode())
                    resp = {"return": req["arguments"]["id"]}
                elif ex == "guest-exec":
                    assert req["arguments"]["path"] == "/bin/sh"
                    assert req["arguments"]["arg"][0] == "-c"
                    assert req["arguments"]["capture-output"] is True
                    resp = {"return": {"pid": 7}}
                elif ex == "guest-exec-status":
                    assert req["arguments"]["pid"] == 7
                    polls += 1
                    if polls < polls_before_exit:
                        resp = {"return": {"exited": False}}
                    else:
                        resp = {"return": {"exited": True, "exitcode": exitcode,
                                           "out-data": base64.b64encode(out).decode()}}
                else:
                    resp = {"error": {"class": "CommandNotFound", "desc": ex}}
                f.write((json.dumps(resp) + "\n").encode())
                f.flush()
        finally:
            # Every exit path (incl. the flood branch's early return) closes the file, conn and srv.
            for c in (f, conn, srv):
                try:
                    c.close()
                except OSError:
                    pass

    threading.Thread(target=serve, daemon=True).start()


class QgaRun(unittest.TestCase):
    def test_exit_code_and_stdout(self):
        p = os.path.join(tempfile.mkdtemp(), "qga.sock")
        fake_agent(p, 3, b"hello\n")
        self.assertEqual(qga.run(p, "echo hello; exit 3", 10), (3, b"hello\n", b""))

    def test_stale_reply_before_sync_is_discarded(self):
        p = os.path.join(tempfile.mkdtemp(), "qga.sock")
        fake_agent(p, 0, b"ok\n", stale={"return": {"pid": 99}})
        self.assertEqual(qga.run(p, "true", 10), (0, b"ok\n", b""))

    def test_sync_flood_honours_deadline(self):
        p = os.path.join(tempfile.mkdtemp(), "qga.sock")
        fake_agent(p, 0, b"", flood=True)
        result = {}

        def target():
            try:
                qga.run(p, "true", 1)
                result["exc"] = None
            except BaseException as e:  # noqa: BLE001 - handed to the main thread
                result["exc"] = e

        # Fail-fast guard: a regressed _sync spins forever on the flood; never let it hang the suite.
        th = threading.Thread(target=target, daemon=True)
        t0 = time.monotonic()
        th.start()
        th.join(timeout=10)
        self.assertFalse(th.is_alive(), "qga.run still running after 10 s: _sync ignores the deadline")
        self.assertIsInstance(result.get("exc"), TimeoutError)
        self.assertLess(time.monotonic() - t0, 5)

    def test_non_object_reply_is_clean_error(self):
        p = os.path.join(tempfile.mkdtemp(), "qga.sock")
        fake_agent(p, 0, b"", stale=[1])
        with self.assertRaises(ValueError):
            qga.run(p, "true", 5)

    def test_timeout(self):
        p = os.path.join(tempfile.mkdtemp(), "qga.sock")
        fake_agent(p, 0, b"", polls_before_exit=10**6)
        with self.assertRaises(TimeoutError):
            qga.run(p, "sleep 999", 1)


class QgaMain(unittest.TestCase):
    """main()/argv contract: vm.sh calls `qga.py SOCK --timeout N -- "$*"`."""

    def _main(self, argv):
        with mock.patch.object(qga, "run", return_value=(0, b"", b"")) as r:
            qga.main(argv)
        return r.call_args[0]

    def test_timeout_and_command_parsed(self):
        self.assertEqual(self._main(["S", "--timeout", "7", "--", "uname", "-m"]), ("S", "uname -m", 7))

    def test_single_string_command(self):
        self.assertEqual(self._main(["S", "--timeout", "7", "--", "uname -m"]), ("S", "uname -m", 7))

    def test_default_timeout_without_flag(self):
        self.assertEqual(self._main(["S", "--", "true"]), ("S", "true", 3600))

    def test_guest_command_after_separator_is_verbatim(self):
        self.assertEqual(self._main(["S", "--timeout", "7", "--", "echo", "--timeout", "1", "--", "x"]),
                         ("S", "echo --timeout 1 -- x", 7))

    def test_end_to_end_timeout_is_honoured(self):
        d = tempfile.mkdtemp()
        p = os.path.join(d, "qga.sock")
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(p)
        srv.listen(1)  # accepts into the backlog, never replies
        self.addCleanup(srv.close)
        t0 = time.monotonic()
        r = subprocess.run([sys.executable, "-I", os.path.join(QGA_DIR, "qga.py"), p, "--timeout", "2", "--", "true"],
                           capture_output=True, text=True, timeout=15)
        self.assertEqual(r.returncode, 255, r.stderr)
        self.assertIn("exceeded", r.stderr)
        self.assertLess(time.monotonic() - t0, 6)


if __name__ == "__main__":
    unittest.main()
