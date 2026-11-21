"""The ffmpeg child and the publish point (W-23 P4, D22): scrubbed env, pdeathsig, first-IDR + 5 s.

TIMESTAMP_MODE (spec §4.4, set by Task 21 from gate GA): "rtp" muxes each access unit into MPEG-TS whose PTS is the
camera's RTP timestamp (mpegts.py: unwrapped, re-based on a jump) and ffmpeg reads `-f mpegts`; "wallclock" pipes raw
HEVC and lets ffmpeg stamp by arrival time."""
import ctypes
import os
import signal
import subprocess
import time

from . import mpegts
from .constants import PUBLISH_HOLD_S, TIMESTAMP_MODE


class FfmpegExited(Exception):
    pass


def child_argv(ffmpeg: str, url: str, mode: str) -> list:
    if mode == "rtp":
        src = ["-f", "mpegts", "-i", "pipe:0"]
    elif mode == "wallclock":
        src = ["-use_wallclock_as_timestamps", "1", "-f", "hevc", "-i", "pipe:0"]
    else:
        raise ValueError("unsupported timestamp mode: %s" % mode)
    return [ffmpeg, "-hide_banner", "-loglevel", "error", *src, "-c", "copy", "-an", "-f", "rtsp",
            "-rtsp_transport", "tcp", url]


def child_env() -> dict:
    return {"PATH": "/usr/bin:/bin", "LD_LIBRARY_PATH": os.environ.get("EZVIZ_CHILD_LD_LIBRARY_PATH", "")}


_libc = ctypes.CDLL(None, use_errno=True)  # loaded once, never dlopen after fork
_prctl = _libc.prctl


def _make_pdeathsig(ppid: int):
    def _pdeathsig() -> None:
        if _prctl(1, int(signal.SIGTERM), 0, 0, 0) != 0:  # PR_SET_PDEATHSIG
            os._exit(127)
        if os.getppid() != ppid:  # parent died before the prctl took effect
            os._exit(1)
    return _pdeathsig


class Output:
    """Owns the ffmpeg child. PR_SET_PDEATHSIG fires when the FORKING THREAD exits, so construct Output on the
    main thread (P2: the login_ok hook runs on the main thread before the keepalive thread starts)."""

    def __init__(self, ffmpeg: str, url: str, *, mode: str = TIMESTAMP_MODE, now=time.monotonic):
        self._now = now
        self._first_idr = None
        self._reported = False
        argv = child_argv(ffmpeg, url, mode)                 # an unsupported mode raises before any spawn
        self._clock, self._mux = (mpegts.RtpClock(), mpegts.TsMuxer()) if mode == "rtp" else (None, None)
        self._proc = subprocess.Popen(argv, stdin=subprocess.PIPE,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                      env=child_env(), preexec_fn=_make_pdeathsig(os.getpid()), close_fds=True, bufsize=0)
        self.pid = self._proc.pid

    def write_au(self, au: bytes, is_idr: bool, ts=None) -> None:
        """`ts`: the access unit's RTP timestamp, required in "rtp" mode (the clock starts at the first IDR
        written)."""
        if self._mux is not None and ts is None:
            raise ValueError("TIMESTAMP_MODE rtp needs the access unit's RTP timestamp")
        if self._proc.poll() is not None:
            raise FfmpegExited("ffmpeg exited with %s" % self._proc.returncode)
        first = self._first_idr is None
        if first and not is_idr:
            return
        if self._mux is not None:
            au = self._mux.mux(au, self._clock.pts(ts), is_idr)
        view = memoryview(au)
        try:
            while len(view):
                n = self._proc.stdin.write(view)
                if not n:
                    raise FfmpegExited("ffmpeg stdin accepted no bytes")
                view = view[n:]
        except (BrokenPipeError, ValueError, OSError) as e:
            raise FfmpegExited("ffmpeg stdin closed") from e
        if first:
            self._first_idr = self._now()

    def published_due(self) -> bool:
        if self._reported or self._first_idr is None:
            return False
        if self._now() - self._first_idr < PUBLISH_HOLD_S or self._proc.poll() is not None:
            return False
        self._reported = True
        return True

    def close(self, wait: float = 2.0) -> None:
        """Close stdin, SIGTERM, wait up to `wait` s, then SIGKILL and reap. Never raises; idempotent."""
        try:
            try:
                self._proc.stdin.close()
            except Exception:
                pass
            if self._proc.poll() is None:
                self._proc.terminate()
                try:
                    self._proc.wait(max(wait, 0.0))
                except subprocess.TimeoutExpired:
                    self._proc.kill()
                    self._proc.wait()
        except Exception:
            pass
