"""Test-only HTTP fault proxy between ezviz-rearm and go2rtc's API (W-23 T15, spec S2 rev 4 H1, rev 5 nit 1).

    faultproxy.py --listen PORT --upstream PORT [--fail-next-get N] [--hold-put-s S] --log FILE [--port-file F]

Loopback only, stdlib only. Forwards every request to 127.0.0.1:<upstream> and relays the answer, except:
- the next N GET requests are answered 503 at once and never forwarded (a failed GET, H1a);
- every PUT is held S seconds before it is forwarded (a PUT that stays open, H1b).
The client's own timeout is never touched: the re-arm keeps its production 75 s.

The log gets one JSON line when a request arrives ("in") and one when its answer leaves ("out"), each with the
wall-clock time t, a request number n, the method and the path (only camera names reach it), so a test can see
whether a second request arrived while an earlier one was still open.
"""
import argparse
import http.client
import http.server
import json
import os
import socketserver
import sys
import threading
import time
from pathlib import Path


class Proxy(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, listen: int, upstream: int, fail_next_get: int, hold_put_s: float, log: Path):
        self.upstream, self.fail_left, self.hold_put_s = upstream, fail_next_get, hold_put_s
        self.log_path, self.lock, self.n = log, threading.Lock(), 0
        super().__init__(("127.0.0.1", listen), Handler)

    def record(self, **fields) -> None:
        fields["t"] = round(time.time(), 3)
        with self.lock:
            with open(self.log_path, "a") as f:
                f.write(json.dumps(fields, sort_keys=True) + "\n")
                f.flush()

    def next_n(self) -> int:
        with self.lock:
            self.n += 1
            return self.n

    def take_failure(self) -> bool:
        with self.lock:
            if self.fail_left > 0:
                self.fail_left -= 1
                return True
            return False


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args) -> None:       # no stderr noise; the JSON log is the record
        pass

    def _answer(self, n: int, status: int, body: bytes, ctype: str = "text/plain") -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True
        self.server.record(ev="out", n=n, method=self.command, path=self.path, status=status)

    def _handle(self) -> None:
        srv = self.server
        n = srv.next_n()
        srv.record(ev="in", n=n, method=self.command, path=self.path)
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        if self.command == "GET" and srv.take_failure():
            return self._answer(n, 503, b"faultproxy: injected failure\n")
        if self.command == "PUT" and srv.hold_put_s > 0:
            srv.record(ev="hold", n=n, method=self.command, path=self.path, s=srv.hold_put_s)
            time.sleep(srv.hold_put_s)
        try:
            conn = http.client.HTTPConnection("127.0.0.1", srv.upstream, timeout=300)
            hdrs = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "connection")}
            conn.request(self.command, self.path, body=body, headers=hdrs)
            r = conn.getresponse()
            data = r.read()
            status, ctype = r.status, r.getheader("Content-Type", "text/plain")
            conn.close()
        except OSError as e:
            return self._answer(n, 502, ("faultproxy: upstream %s\n" % type(e).__name__).encode())
        self._answer(n, status, data, ctype)

    do_GET = do_PUT = do_POST = do_DELETE = _handle


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--listen", type=int, required=True)
    ap.add_argument("--upstream", type=int, required=True)
    ap.add_argument("--fail-next-get", type=int, default=0)
    ap.add_argument("--hold-put-s", type=float, default=0.0)
    ap.add_argument("--log", required=True)
    ap.add_argument("--port-file")
    a = ap.parse_args(argv)
    srv = Proxy(a.listen, a.upstream, a.fail_next_get, a.hold_put_s, Path(a.log))
    if a.port_file:
        tmp = Path(a.port_file + ".tmp")
        tmp.write_text("%d\n" % srv.server_address[1])
        os.replace(tmp, a.port_file)
    try:
        srv.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    socketserver.TCPServer.allow_reuse_address = True
    sys.exit(main())
