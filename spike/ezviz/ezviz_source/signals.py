"""SIGTERM handling for ezviz-source (spec D17; card L1; spec K1). Stdlib only.

The first SIGTERM sets SIGALRM to SIG_DFL, arms alarm(ALARM_S) and raises Terminating (a BaseException,
so the library's `except Exception` cannot swallow it). Every later SIGTERM only returns (L1): it never
re-arms and never raises. Inside critical() the first SIGTERM is held pending and raised when the
outermost section exits (K1). After mark_ended() nothing raises any more (plan SF3).
"""
import errno
import os
import signal
import time
from contextlib import contextmanager

from . import constants as C


class Terminating(BaseException):
    pass


class _State:
    seen = False      # a SIGTERM has arrived
    raised = False    # Terminating has been raised once
    depth = 0         # critical() nesting
    ended = False     # an end record is being or has been written


_st = _State()


def _on_sigterm(signum, frame):
    if _st.seen:                    # L1: later SIGTERMs only mark pending; no re-arm, no raise
        return
    _st.seen = True
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.alarm(C.ALARM_S)         # the kernel ends the process even inside a C call (H5a)
    if _st.depth == 0 and not _st.ended:
        _st.raised = True
        raise Terminating()         # J1a: ends the interrupted blocking call at once


def install() -> None:
    signal.signal(signal.SIGTERM, _on_sigterm)


@contextmanager
def critical():
    _st.depth += 1
    try:
        yield
    finally:
        _st.depth -= 1
        if _st.depth == 0 and _st.seen and not _st.raised and not _st.ended:
            _st.raised = True
            raise Terminating()


def mark_ended() -> None:
    _st.ended = True


def sigterm_seen() -> bool:
    return _st.seen


def wait_for_sigterm(seconds: float) -> None:
    """Sleep up to `seconds`; the first SIGTERM raises Terminating through the handler."""
    end = time.monotonic() + seconds
    while True:
        left = end - time.monotonic()
        if left <= 0:
            return
        time.sleep(left)


def _hooks() -> list:
    return [h for h in os.environ.get("EZVIZ_TEST_HOOKS", "").split(",") if h]


def hook_active(name: str) -> bool:
    return name in _hooks()


def hook(name: str) -> None:
    """Test hooks; inert unless EZVIZ_TEST_HOOKS names them (the go2rtc unit never sets it)."""
    if not hook_active(name):
        return
    if name == "enospc_append":
        raise OSError(errno.ENOSPC, "test hook")
    if name == "stall_close":
        time.sleep(60)
    elif name == "pause_close":
        time.sleep(1.0)
    elif name.startswith("pause"):
        time.sleep(2.0)
