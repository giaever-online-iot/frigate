import _path
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from ezviz_source import rearm
from ezviz_source.rearm import Api, names, run_round


class Fake:
    """Loopback fake go2rtc API. Records (method, path, start, end) for every request."""

    def __init__(self, get_status=200, get_body=b"{}", get_sleep=0.0, put_status=200, put_sleep=0.0):
        self.get_status, self.get_body, self.get_sleep = get_status, get_body, get_sleep
        self.put_status, self.put_sleep = put_status, put_sleep
        self.reqs = []
        fake = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _do(self):
                t0 = time.monotonic()
                if self.command == "GET":
                    time.sleep(fake.get_sleep)
                    status, body = fake.get_status, fake.get_body
                else:
                    time.sleep(fake.put_sleep)
                    status, body = fake.put_status, b"{}"
                fake.reqs.append((self.command, self.path, t0, time.monotonic()))
                self.send_response(status)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except OSError:
                    pass

            do_GET = do_PUT = _do

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.srv.daemon_threads = True
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()

    def puts(self):
        return [r for r in self.reqs if r[0] == "PUT"]


class RearmBase(unittest.TestCase):
    def fake(self, **kw):
        f = Fake(**kw)
        self.addCleanup(f.close)
        return f


class TestRound(RearmBase):
    def test_get_failure_skips_round_no_put(self):
        f = self.fake(get_status=500)
        run_round(Api(f.base), ["cam1", "cam2"], {}, lambda s: None)
        self.assertEqual([r[0] for r in f.reqs], ["GET"])
        f2 = self.fake(get_sleep=3.0)
        t0 = time.monotonic()
        run_round(Api(f2.base, timeout=1), ["cam1"], {}, lambda s: None)
        self.assertLess(time.monotonic() - t0, 2.5)
        time.sleep(3.2)  # let the slow handler finish recording
        self.assertEqual([r[0] for r in f2.reqs], ["GET"])

    def test_non_json_or_non_object_get_is_failed_get(self):
        for body in (b"<html>", b"[1, 2]", b'"cam1"', b"null"):
            f = self.fake(get_body=body)
            api = Api(f.base)
            self.assertIsNone(api.get(), body)
            run_round(api, ["cam1"], {}, lambda s: None)
            self.assertEqual(f.puts(), [], body)

    def test_put_only_names_not_listed(self):
        f = self.fake(get_body=json.dumps({"cam1": {"sources": []}}).encode())
        run_round(Api(f.base), ["cam1", "cam2"], {}, lambda s: None)
        self.assertEqual(len(f.puts()), 1)
        self.assertIn("src=cam2", f.puts()[0][1])

    def test_put_query_is_src_and_video(self):
        f = self.fake()
        run_round(Api(f.base), ["cam2"], {}, lambda s: None)
        self.assertEqual(f.puts()[0][1], "/api/preload?src=cam2&video")

    def test_one_request_in_flight(self):
        f = self.fake(put_sleep=1.0)
        run_round(Api(f.base), ["cam1", "cam2"], {}, lambda s: None)
        rs = sorted(f.reqs, key=lambda r: r[2])
        self.assertEqual(len(f.puts()), 2)
        for a, b in zip(rs, rs[1:]):
            self.assertLessEqual(a[3], b[2], "requests overlapped: %r" % (rs,))

    def test_logs_on_state_change_only(self):
        f = self.fake()
        api, state, lines = Api(f.base), {}, []
        for _ in range(3):
            run_round(api, ["cam1", "cam2"], state, lines.append)
            f.get_body = json.dumps({"cam1": {}, "cam2": {}}).encode()
        self.assertEqual(sorted(lines), ["ezviz-rearm cam1: armed", "ezviz-rearm cam2: armed"])

    def test_refused_put_logged_once(self):
        f = self.fake(put_status=500)
        api, state, lines = Api(f.base), {}, []
        for _ in range(3):
            run_round(api, ["cam1"], state, lines.append)
        self.assertEqual(lines, ["ezviz-rearm cam1: refused"])

    def test_api_refused_logged_then_recovery(self):
        f = self.fake(get_status=401)
        api, state, lines = Api(f.base), {}, []
        run_round(api, ["cam1"], state, lines.append)
        run_round(api, ["cam1"], state, lines.append)
        self.assertEqual(lines, ["ezviz-rearm: api_refused"])
        self.assertEqual(f.puts(), [])
        self.assertTrue(api.refused)
        for code in (403, 404):
            f.get_status = code
            self.assertIsNone(api.get())
            self.assertTrue(api.refused)
        f.get_status = 200
        run_round(api, ["cam1"], state, lines.append)
        self.assertEqual(lines, ["ezviz-rearm: api_refused", "ezviz-rearm: api_recovered",
                                 "ezviz-rearm cam1: armed"])
        self.assertFalse(api.refused)

    def test_empty_wanted_sends_nothing(self):
        f = self.fake()
        run_round(Api(f.base), [], {}, lambda s: None)
        self.assertEqual(f.reqs, [])

    def test_no_secret_logged(self):
        f = self.fake(get_status=401, get_body=b"CANARYBODY")
        lines = []
        run_round(Api(f.base), ["cam1"], {}, lines.append)
        self.assertNotIn("CANARYBODY", "".join(lines))
        # unreachable API: no exception text, nothing logged
        lines = []
        run_round(Api("http://127.0.0.1:1"), ["cam1"], {}, lines.append)
        self.assertEqual(lines, [])

    def test_env_proxies_are_ignored(self):
        f = self.fake(get_body=json.dumps({"cam1": {}}).encode())
        dead = "http://127.0.0.1:1"
        with unittest.mock.patch.dict(os.environ, {"http_proxy": dead, "HTTP_PROXY": dead}):
            api = Api(f.base)
            self.assertEqual(api.get(), {"cam1"})
            self.assertTrue(api.put("cam2"))
        self.assertEqual(len(f.puts()), 1)

    def test_default_timeout_is_75(self):
        self.assertEqual(Api().timeout, 75)

    def test_put_rejects_bad_name(self):
        f = self.fake()
        self.assertFalse(Api(f.base).put("a&b"))
        self.assertEqual(f.reqs, [])


class TestNames(unittest.TestCase):
    def test_names_ignore_odd_files(self):
        with tempfile.TemporaryDirectory() as d:
            c = Path(d, "cameras")
            c.mkdir()
            for n in ["cam1.conf", "cam2.conf", "cam1.conf.m7c-new", "CAM2.conf", "x.txt",
                      "cam3.conf.bak", ".conf", "a-b.conf", "x" * 33 + ".conf"]:
                (c / n).write_text("")
            (c / "d.conf").mkdir()
            tgt = Path(d, "target")
            tgt.write_text("")
            (c / "lnk.conf").symlink_to(tgt)
            self.assertEqual(sorted(names(c)), ["cam1", "cam2"])

    def test_missing_dir_is_empty(self):
        self.assertEqual(names(Path("/nonexistent-w23-dir")), [])

    def test_name_length_limit(self):
        with tempfile.TemporaryDirectory() as d:
            for n in ("a" * 32, "b" * 33):
                Path(d, n + ".conf").write_text("")
            self.assertEqual(names(Path(d)), ["a" * 32])

    def test_files_never_opened(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d, "cam1.conf")
            p.write_text("")
            p.chmod(0)
            try:
                self.assertEqual(names(Path(d)), ["cam1"])
            finally:
                p.chmod(0o600)


class TestMain(RearmBase):
    def run_main(self, argv, env_extra=None):
        env = _path.child_env(**(env_extra or {}))
        return subprocess.Popen([_path.isolated_python(), "-I", "-B", "-m", "ezviz_source.rearm"] + argv,
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def test_list_mode_prints_names_only(self):
        f = self.fake(get_body=json.dumps({"cam2": {"u": "CANARY"}, "cam1": {}}).encode())
        p = self.run_main(["--list"], {"EZVIZ_REARM_API": f.base})
        out, err = p.communicate(timeout=20)
        self.assertEqual(out.strip(), "preload: cam1,cam2")
        self.assertNotIn("CANARY", out + err)

    def test_list_mode_unreachable_and_refused(self):
        p = self.run_main(["--list"], {"EZVIZ_REARM_API": "http://127.0.0.1:1"})
        self.assertEqual(p.communicate(timeout=20)[0].strip(), "preload: unreachable")
        f = self.fake(get_status=403)
        p = self.run_main(["--list"], {"EZVIZ_REARM_API": f.base})
        self.assertEqual(p.communicate(timeout=20)[0].strip(), "preload: api_refused")

    def test_loop_arms_and_sigterm_exits_zero(self):
        f = self.fake()
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "cameras").mkdir()
            (Path(d) / "cameras" / "cam1.conf").write_text("")
            p = self.run_main(["--first-delay", "0", "--period", "0.2", "--cameras",
                               str(Path(d) / "cameras")], {"EZVIZ_REARM_API": f.base})
            for _ in range(100):
                if f.puts():
                    break
                time.sleep(0.1)
            # a camera added later is armed on a later round
            (Path(d) / "cameras" / "cam2.conf").write_text("")
            for _ in range(100):
                if any("src=cam2" in r[1] for r in f.puts()):
                    break
                time.sleep(0.1)
            p.send_signal(signal.SIGTERM)
            out, err = p.communicate(timeout=10)
        self.assertEqual(p.returncode, 0)
        self.assertNotIn("Traceback", err)
        self.assertIn("ezviz-rearm cam1: armed", out)
        self.assertTrue(any("src=cam2" in r[1] for r in f.puts()))


if __name__ == "__main__":
    unittest.main()
