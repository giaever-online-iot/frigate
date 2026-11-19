"""The pre-contact gate (spec §4.1, D3, D18, D21, G3, N5). Stdlib only: never import pyezvizapi here.

Order: umask and state dir; session lock (busy); camera file (config, no ledger touched); under the
ledger lock: decide, then in one critical section the synthetic record, the latch, and the refusal or
the "attempt" record (fsynced before any connect, F3).
"""
import fcntl
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from . import camfile, ledger, paths, policy, signals
from . import constants as C


@dataclass
class Admitted:
    cam: camfile.Camera
    ledger_path: Path
    session_fd: int
    attempt_t: float
    attempts_in_window: int


class Refused(Exception):
    def __init__(self, cls: str, code: int, next_in=None):
        super().__init__(cls)
        self.cls, self.code, self.next_in = cls, code, next_in


def say(name: str, cls: str, *, attempt=None, next_in=None) -> None:
    line = f"ezviz-source {name}: {cls}"
    if attempt is not None:
        line += f" attempt {attempt}/{C.CAP_ATTEMPTS} in window"
    if next_in is not None:
        line += f" next allowed +{int(next_in)}s"
    sys.stderr.write(line + "\n")
    sys.stderr.flush()


def write_latch(state: Path, name: str) -> None:
    try:
        fd = os.open(state / f"{name}.latch", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        ledger._fsync_dir(state)
    except OSError as e:
        raise ledger.LedgerIOError(type(e).__name__) from None


def _row_start(recs: list) -> float:
    """t of the last published or unlatch record (where the current latch row starts), else -inf."""
    return max((r["t"] for r in recs if r["ev"] in ("published", "unlatch")), default=float("-inf"))


def admit(name: str, now=time.time, on_attempt=None) -> Admitted:
    os.umask(0o077)
    state = paths.state_dir()
    try:
        state.mkdir(mode=0o700, parents=True, exist_ok=True)
        sfd = os.open(state / f"{name}.session", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    except OSError:
        raise Refused("ledger_io", C.EXIT_TEMP) from None
    try:
        fcntl.flock(sfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(sfd)
        raise Refused("busy", C.EXIT_TEMP) from None
    try:
        cam = camfile.load(name, paths.camera_dir())
    except camfile.CameraFileError:
        raise Refused("config", C.EXIT_CONFIG) from None
    signals.hook("pause_gate")
    lp = state / f"{name}.ledger"
    try:
        with ledger.Ledger(lp) as L:
            recs = L.records()
            t = now()
            d = policy.decide(recs, t, latch_file=(state / f"{name}.latch").exists())
            with signals.critical():
                if d.synthetic is not None:
                    L.append(d.synthetic)
                if d.latch_now:
                    write_latch(state, name)
                    L.append({"t": t, "ev": "latch", "dur": None})
                if not d.allow:
                    raise Refused(d.cls, C.EXIT_TEMP, None if d.cls == "latched" else d.next_allowed - t)
                L.append({"t": t, "ev": "attempt", "dur": None})
                if on_attempt is not None:
                    on_attempt(t, lp)                  # the caller's phase becomes P1 inside the section
            recs = L.records()
            if recs and recs[0]["t"] < t - C.TRIM_KEEP_S - 3600:
                L.trim(t, min(t - C.WINDOW_S, _row_start(recs)))   # last operation under the lock
    except ledger.LedgerDamaged:
        raise Refused("ledger_damaged", C.EXIT_TEMP) from None
    except ledger.LedgerIOError:
        raise Refused("ledger_io", C.EXIT_TEMP) from None
    return Admitted(cam, lp, sfd, t, d.attempts_in_window + 1)
