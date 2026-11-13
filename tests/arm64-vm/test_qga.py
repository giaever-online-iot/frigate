import base64
import json
import os
import socket
import sys
import tempfile
import threading
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(__file__))
import qga  # noqa: E402


def fake_agent(path, exitcode, out, polls_before_exit=2, stale=None):
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(1)

    def serve():
        conn, _ = srv.accept()
        f = conn.makefile("rwb")
        polls = 0
        for line in f:
            req = json.loads(line)
            ex = req["execute"]
            if ex == "guest-sync":
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
        conn.close()
        srv.close()

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

    def test_timeout(self):
        p = os.path.join(tempfile.mkdtemp(), "qga.sock")
        fake_agent(p, 0, b"", polls_before_exit=10**6)
        with self.assertRaises(TimeoutError):
            qga.run(p, "sleep 999", 1)


if __name__ == "__main__":
    unittest.main()
