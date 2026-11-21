"""Preload re-arm loop for the go2rtc unit (W-23 D19, D20).

go2rtc's `preload:` keeps an ezviz stream's producer running; when go2rtc drops the preload (a
publish ended) this loop PUTs it back. The control API is loopback and unauthenticated (D20), so
nothing here is a secret, but we still never log a response body, a query string that is not a
validated camera name, or an exception message (class names only).

One request in flight, ever: the round is sequential and the client timeout is
2 * STARTTIMEOUT_S + 15 (75 s at 30 s). A failed GET skips the round: nothing is PUT.
"""
import argparse
import json
import os
import re
import signal
import stat
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable, Optional

from .constants import STARTTIMEOUT_S

DEFAULT_BASE = "http://127.0.0.1:1984"
CAMERA_FILE_RE = r"[a-z0-9_]{1,32}\.conf"
NAME_RE = r"[a-z0-9_]{1,32}"
_API = "@api"  # state key for the API itself; cannot collide with a camera name


def names(camera_dir: Path) -> list:
    """Camera names, by the same filter as go2rtc-config-gen.py: regular files `<name>.conf`.
    Never opens a file; a symlink or directory is not a camera; a missing dir means none."""
    try:
        entries = sorted(os.listdir(camera_dir))
    except OSError:
        return []
    out = []
    for entry in entries:
        if not re.fullmatch(CAMERA_FILE_RE, entry):
            continue
        try:
            st = os.lstat(os.path.join(camera_dir, entry))
        except OSError:
            continue
        if stat.S_ISREG(st.st_mode):
            out.append(entry[: -len(".conf")])
    return out


# One opener with an empty ProxyHandler and no other handler: http_proxy/HTTP_PROXY survive `python -I`,
# and the loopback API must never be sent through (or its camera names leaked to) a proxy.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class Api:
    def __init__(self, base: str = DEFAULT_BASE, *, timeout: float = 2 * STARTTIMEOUT_S + 15):
        self.base = base.rstrip("/")
        self.timeout = timeout
        self.refused = False

    def get(self) -> Optional[set]:
        """Keys of GET /api/preload, or None on any error, timeout, non-200 or non-object body."""
        self.refused = False
        try:
            req = urllib.request.Request(self.base + "/api/preload", method="GET")
            with _OPENER.open(req, timeout=self.timeout) as r:
                if r.status != 200:
                    return None
                body = json.loads(r.read())
        except urllib.error.HTTPError as e:
            self.refused = e.code in (401, 403, 404)
            return None
        except Exception:
            return None
        if not isinstance(body, dict):
            return None
        return set(body)

    def put(self, name: str) -> bool:
        if not re.fullmatch(NAME_RE, name):
            return False
        try:
            req = urllib.request.Request("%s/api/preload?src=%s&video" % (self.base, name),
                                         method="PUT")
            with _OPENER.open(req, timeout=self.timeout) as r:
                return r.status == 200
        except Exception:
            return False


def run_round(api: Api, wanted: list, state: dict, log: Callable[[str], None]) -> None:
    if not wanted:
        return  # nothing to arm: no request at all
    got = api.get()
    if got is None:
        if api.refused:
            if state.get(_API) != "refused":
                state[_API] = "refused"
                log("ezviz-rearm: api_refused")
        return
    if state.get(_API) == "refused":
        log("ezviz-rearm: api_recovered")
    state[_API] = "ok"

    def note(name, new):
        if state.get(name) != new:
            state[name] = new
            log("ezviz-rearm %s: %s" % (name, new))

    for name in wanted:
        if name in got:
            note(name, "armed")
        else:
            note(name, "armed" if api.put(name) else "refused")


def _on_term(signum, frame):
    raise SystemExit(0)


def main(argv: list) -> int:
    ap = argparse.ArgumentParser(prog="ezviz-rearm")
    ap.add_argument("--first-delay", type=float, default=30.0)
    ap.add_argument("--period", type=float, default=30.0)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--cameras", default=None)
    a = ap.parse_args(argv)
    api = Api(os.environ.get("EZVIZ_REARM_API", DEFAULT_BASE))
    if a.list:
        got = api.get()
        if got is None:
            print("preload: api_refused" if api.refused else "preload: unreachable", flush=True)
        else:
            print("preload: " + ",".join(sorted(got)), flush=True)
        return 0
    cam_dir = Path(a.cameras or os.path.join(os.environ.get("SNAP_DATA", ""), "ezviz", "cameras"))
    signal.signal(signal.SIGTERM, _on_term)
    state: dict = {}

    def log(line):
        print(line, flush=True)

    try:
        time.sleep(a.first_delay)
        while True:
            run_round(api, names(cam_dir), state, log)  # re-read every round
            time.sleep(a.period)
    except (SystemExit, KeyboardInterrupt):
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
