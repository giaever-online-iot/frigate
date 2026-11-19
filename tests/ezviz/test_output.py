"""The ffmpeg child and the publish point (W-23 T10): scrubbed env, pdeathsig, first-IDR + 5 s publish point (D22)."""
import _path
import json
import os
import signal
import subprocess
import sys
import time
import unittest
from pathlib import Path

import fixtures
from ezviz_source import output


def alive(pid):
    try:
        os.kill(pid, 0)
        with open("/proc/%d/stat" % pid) as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"  # a zombie is gone
    except (ProcessLookupError, FileNotFoundError):
        return False


def wait_gone(pid, limit):
    end = time.monotonic() + limit
    while time.monotonic() < end:
        if not alive(pid):
            return True
        time.sleep(0.05)
    return not alive(pid)


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


class OutputTest(unittest.TestCase):
    def setUp(self):
        self.tmp = str(fixtures.tmpdir(self))
        self.outs = []

    def tearDown(self):
        for o in self.outs:
            o.close(wait=0.2)

    def make(self, ffmpeg=None, **kw):
        o = output.Output(ffmpeg or fixtures.fake_ffmpeg(self.tmp), "rtsp://127.0.0.1:8554/x", **kw)
        self.outs.append(o)
        return o

    def test_argv_wallclock(self):
        self.assertEqual(output.child_argv("/f", "rtsp://127.0.0.1:8554/x", "wallclock"),
                         ["/f", "-hide_banner", "-loglevel", "error", "-use_wallclock_as_timestamps", "1",
                          "-f", "hevc", "-i", "pipe:0", "-c", "copy", "-an", "-f", "rtsp",
                          "-rtsp_transport", "tcp", "rtsp://127.0.0.1:8554/x"])

    def test_argv_rtp(self):                                           # W-23 T21: TIMESTAMP_MODE "rtp"
        self.assertEqual(output.child_argv("/f", "rtsp://127.0.0.1:8554/x", "rtp"),
                         ["/f", "-hide_banner", "-loglevel", "error", "-f", "mpegts", "-i", "pipe:0", "-c", "copy", "-an",
                          "-f", "rtsp", "-rtsp_transport", "tcp", "rtsp://127.0.0.1:8554/x"])
        with self.assertRaises(ValueError):
            output.child_argv("/f", "rtsp://127.0.0.1:8554/x", "pts")

    def capture(self, o):
        got, real = [], o._proc.stdin

        class Keep:
            def write(self, b):
                got.append(bytes(b))
                return len(b)

            def close(self):
                real.close()

        o._proc.stdin = Keep()
        return got

    def test_rtp_mode_writes_mpegts_stamped_with_the_ts(self):
        from test_mpegts import AUD, pes_list
        o = self.make(mode="rtp")
        got = self.capture(o)
        o.write_au(b"\x00\x00\x00\x01\x02\x01", False, 1)                 # before the first IDR: nothing at all
        idr, trail = b"\x00\x00\x00\x01\x26\x01\x80abc", b"\x00\x00\x00\x01\x02\x01\x80de"
        base = (1 << 32) - 3600                                             # the second picture wraps the 32-bit ts
        o.write_au(idr, True, base)
        o.write_au(trail, False, (base + 3600) % (1 << 32))
        o.write_au(trail, False, (base + 7200) % (1 << 32))
        pes = pes_list(b"".join(got))
        self.assertEqual([e["pts"] for e in pes], [base, base + 3600, base + 7200])
        self.assertEqual([e["es"] for e in pes], [AUD + idr, AUD + trail, AUD + trail])

    def test_rtp_mode_needs_the_ts(self):
        o = self.make(mode="rtp")
        got = self.capture(o)
        with self.assertRaises(ValueError):
            o.write_au(b"\x00\x00\x00\x01\x26\x01\x80", True)
        self.assertEqual(got, [])

    def test_rtp_mode_publish_point_is_unchanged(self):
        clock = Clock()
        o = self.make(now=clock, mode="rtp")
        o.write_au(b"\x00\x00\x00\x01\x02\x01\x80", False, 0)
        clock.t += 6.0
        self.assertFalse(o.published_due())
        o.write_au(b"\x00\x00\x00\x01\x26\x01\x80", True, 3600)
        clock.t += 4.9
        self.assertFalse(o.published_due())
        clock.t += 0.1
        self.assertTrue(o.published_due())

    def test_env_is_path_and_ld_library_path_only(self):
        with unittest.mock.patch.dict(os.environ, {"EZVIZ_CHILD_LD_LIBRARY_PATH": "/l", "CANARY_VAR": "x"}):
            self.assertEqual(output.child_env(), {"PATH": "/usr/bin:/bin", "LD_LIBRARY_PATH": "/l"})
            dump = Path(self.tmp) / "dump.json"
            o = self.make(fixtures.fake_ffmpeg(self.tmp, dump=dump))
            for _ in range(100):
                if dump.exists() and dump.stat().st_size:
                    break
                time.sleep(0.05)
        got = json.loads(dump.read_text())["env"]
        self.assertNotIn("CANARY_VAR", got)
        self.assertNotIn("EZVIZ_CHILD_LD_LIBRARY_PATH", got)
        self.assertEqual(got["LD_LIBRARY_PATH"], "/l")

    def test_child_gets_pdeathsig(self):
        ff = fixtures.fake_ffmpeg(self.tmp, linger=1)  # survives stdin EOF: only pdeathsig can end it
        code = ("import _path, sys, time\nfrom ezviz_source import output\n"
                "o = output.Output(sys.argv[1], 'rtsp://127.0.0.1:8554/x')\n"
                "print(o.pid, flush=True)\ntime.sleep(60)\n")
        p = subprocess.Popen([sys.executable, "-c", code, ff], stdout=subprocess.PIPE, text=True,
                             env=_path.child_env(), cwd=str(Path(__file__).resolve().parent))
        pid = int(p.stdout.readline())
        p.stdout.close()
        self.assertTrue(alive(pid))
        p.kill()
        p.wait()
        self.assertTrue(wait_gone(pid, 2.0), "orphan ffmpeg outlived the helper")

    def test_no_publish_before_idr(self):
        clock = Clock()
        o = self.make(now=clock, mode="wallclock")
        for _ in range(10):
            o.write_au(b"\x00\x00\x00\x01\x02", False)
        clock.t += 6.0
        self.assertFalse(o.published_due())

    def test_publish_after_5s_alive(self):
        clock = Clock()
        o = self.make(now=clock, mode="wallclock")
        o.write_au(b"\x00\x00\x00\x01\x26", True)
        clock.t += 4.9
        self.assertFalse(o.published_due())
        clock.t += 0.1
        self.assertTrue(o.published_due())
        clock.t += 10
        self.assertFalse(o.published_due())

    def test_short_writes_are_completed(self):
        o = self.make(mode="wallclock")
        got = []
        real = o._proc.stdin

        class Half:
            def write(self, b):
                n = max(1, len(b) // 2)
                got.append(bytes(b[:n]))
                return n

            def close(self):
                real.close()

        o._proc.stdin = Half()
        o.write_au(b"\x00\x00\x00\x01\x26abcdefgh", True)
        self.assertEqual(b"".join(got), b"\x00\x00\x00\x01\x26abcdefgh")
        self.assertGreater(len(got), 2)

    def test_exited_child_raises(self):
        o = self.make(fixtures.fake_ffmpeg(self.tmp, exit_after_s=0.5), mode="wallclock")
        time.sleep(1.0)
        with self.assertRaises(output.FfmpegExited):
            o.write_au(b"\x00\x00\x00\x01\x26", True)

    def test_close_wait_is_bounded(self):
        """R2-N3: close(wait=) bounds the SIGTERM wait, then SIGKILLs and reaps."""
        o = self.make(fixtures.fake_ffmpeg(self.tmp, ignore_term=1))
        time.sleep(0.5)
        t0 = time.monotonic()
        o.close(wait=0.3)
        self.assertLess(time.monotonic() - t0, 1.0)
        self.assertFalse(alive(o.pid))
        o.close(wait=0.3)  # idempotent


if __name__ == "__main__":
    unittest.main()
