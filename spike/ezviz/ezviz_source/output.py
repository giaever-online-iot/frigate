"""The ffmpeg child and the publish point (W-23 P4, D22): scrubbed env, pdeathsig, first-IDR + 5 s."""
import ctypes
import os
import signal
import subprocess
import time

from .constants import PUBLISH_HOLD_S, TIMESTAMP_MODE


class FfmpegExited(Exception):
    pass


def child_argv(ffmpeg: str, url: str, mode: str) -> list:
    if mode != "wallclock":
        raise ValueError("unsupported timestamp mode: %s" % mode)
    return [ffmpeg, "-hide_banner", "-loglevel", "error", "-use_wallclock_as_timestamps", "1",
            "-f", "hevc", "-i", "pipe:0", "-c", "copy", "-an", "-f", "rtsp", "-rtsp_transport", "tcp", url]


def child_env() -> dict:
    return {"PATH": "/usr/bin:/bin", "LD_LIBRARY_PATH": os.environ.get("EZVIZ_CHILD_LD_LIBRARY_PATH", "")}


def _pdeathsig() -> None:
    ctypes.CDLL(None).prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG


class Output:
    def __init__(self, ffmpeg: str, url: str, *, mode: str = TIMESTAMP_MODE, now=time.monotonic):
        self._now = now
        self._first_idr = None
        self._reported = False
        self._proc = subprocess.Popen(child_argv(ffmpeg, url, mode), stdin=subprocess.PIPE,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                      env=child_env(), preexec_fn=_pdeathsig, close_fds=True, bufsize=0)
        self.pid = self._proc.pid

    def write_au(self, au: bytes, is_idr: bool) -> None:
        if self._proc.poll() is not None:
            raise FfmpegExited("ffmpeg exited with %s" % self._proc.returncode)
        if self._first_idr is None:
            if not is_idr:
                return
            self._first_idr = self._now()
        try:
            self._proc.stdin.write(au)
        except (BrokenPipeError, ValueError, OSError) as e:
            raise FfmpegExited("ffmpeg stdin closed") from e

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
