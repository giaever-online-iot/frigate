"""Shared test fixtures: temp SNAP trees, canary camera files, the gate runner, the helper process harness."""
import _path
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from ezviz_source import ledger as _ledger

GOOD = "host=192.0.2.11\nport=8000\nserial=TESTCAM-0001\nlogin=QZCNRA\n"
CANARIES = ("192.0.2.11", "TESTCAM-0001", "QZCNRA")


class Tree:
    """A fake $SNAP_DATA / $SNAP_COMMON with a camera file for cam1."""

    def __init__(self, camfile: str = GOOD, mode: int = 0o600):
        self.root = Path(tempfile.mkdtemp())
        self.data, self.common = self.root / "data", self.root / "common"
        self.cams = self.data / "ezviz" / "cameras"
        self.state = self.common / "ezviz" / "state"
        self.cams.mkdir(parents=True)
        if camfile is not None:
            f = self.cams / "cam1.conf"
            f.write_text(camfile)
            f.chmod(mode)

    def env(self, **extra) -> dict:
        return _path.child_env(SNAP=str(self.root / "snap"), SNAP_DATA=str(self.data),
                               SNAP_COMMON=str(self.common), **extra)

    def ledger(self) -> Path:
        return self.state / "cam1.ledger"

    def seed(self, lines: list) -> None:
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.ledger().write_text("".join(lines))
        self.ledger().chmod(0o600)


GATE = """
import sys, time
from ezviz_source import gate, signals
signals.install()
try:
    a = gate.admit(sys.argv[1])
except gate.Refused as r:
    gate.say(sys.argv[1], r.cls, next_in=r.next_in); sys.exit(r.code)
except signals.Terminating:
    sys.exit(0)
print("ADMITTED", flush=True)
time.sleep(float(sys.argv[2]))
"""


def gate_proc(tree: Tree, hold_s: float = 0.0, *, pyflags=(), **env) -> subprocess.Popen:
    return subprocess.Popen([sys.executable, *pyflags, "-c", GATE, "cam1", str(hold_s)], env=tree.env(**env),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def run_gate(tree: Tree, hold_s: float = 0.0, *, pyflags=(), **env):
    t0 = time.monotonic()
    p = gate_proc(tree, hold_s, pyflags=pyflags, **env)
    out, err = p.communicate(timeout=30)
    return p.returncode, out, err, time.monotonic() - t0


# ---- synthetic IDMX/RTP bodies for the Annex-B reassembler (W-23 T7) ----
SENTINEL = b"\x55\x66\x77\x88"


def rtp_body(pt: int, seq: int, ts: int, payload: bytes, marker: bool = False, header13: bool = False) -> bytes:
    """4-byte LE length + one IDMX frame: RTP v2 header (SSRC = sentinel) + payload.

    header13 puts the 0x0D lead byte in front of the RTP header (the X80 shape).
    """
    rtp = bytes([0x80, (0x80 if marker else 0) | pt]) + (seq & 0xFFFF).to_bytes(2, "big") \
        + (ts & 0xFFFFFFFF).to_bytes(4, "big") + SENTINEL + payload
    frame = (b"\x0d" + rtp) if header13 else rtp
    return len(frame).to_bytes(4, "little") + frame


def hevc_nal(nal_type: int, size: int, first_slice: bool = True, fill: int = 0x5A) -> bytes:
    """A plausible HEVC NAL: 2-byte header (layer 0, tid 1), byte 2 MSB = first_slice_segment_in_pic_flag."""
    body = bytes([0x80 if first_slice else 0x00]) + bytes([fill]) * (size - 3)
    return bytes([nal_type << 1, 1]) + body


def fu(nal: bytes, size: int) -> list:
    """RFC 7798 fragmentation units (type 49): payloads of at most `size` NAL bytes each."""
    indicator = bytes([(nal[0] & 0x81) | (49 << 1), nal[1]])
    rest = nal[2:]
    chunks = [rest[i:i + size] for i in range(0, len(rest), size)]
    out = []
    for n, chunk in enumerate(chunks):
        hdr = ((nal[0] >> 1) & 0x3F) | (0x80 if n == 0 else 0) | (0x40 if n == len(chunks) - 1 else 0)
        out.append(indicator + bytes([hdr]) + chunk)
    return out


# ---- the fake camera's clip (W-23 T8) ----
def _annexb(*nals: bytes) -> bytes:
    return b"".join(b"\x00\x00\x00\x01" + n for n in nals)


# A tiny made-up Annex-B H.265 stream: VPS, SPS, PPS, IDR (type 19), TRAIL (type 1), dummy payloads. Two access
# units; the IDR is large enough to need FU fragments at the fake's 1400-byte limit. Valid for the reassembler,
# not decodable.
SYNTH_ES = _annexb(hevc_nal(32, 24), hevc_nal(33, 40), hevc_nal(34, 12), hevc_nal(19, 3000), hevc_nal(1, 600))


def make_es(ffmpeg: str, out: Path, seconds: int = 4) -> Path:
    """A decodable 1080p25 H.265 Annex-B clip, IDR every 2 s, parameter sets on every IDR (go2rtc/S2 tests)."""
    subprocess.run([ffmpeg, "-y", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=25", "-t", str(seconds),
                    "-c:v", "libx265", "-x265-params", "keyint=50:min-keyint=50:bframes=0:repeat-headers=1",
                    "-f", "hevc", str(out)], check=True, capture_output=True, timeout=300)
    return out


def fake_ffmpeg(tmpdir, **knobs) -> str:
    """Write an sh script that exports FAKEFF_<KNOB>=value and execs fakeffmpeg.py; returns its path (R1/C1)."""
    exports = "".join("FAKEFF_%s=%s; export FAKEFF_%s\n" % (k.upper(), v, k.upper()) for k, v in knobs.items())
    script = Path(tmpdir) / "ffmpeg"
    script.write_text("#!/bin/sh\n%sexec %s -I %s \"$@\"\n"
                      % (exports, sys.executable, Path(__file__).resolve().parent / "fakeffmpeg.py"))
    script.chmod(0o755)
    return str(script)


# ---- the helper process harness (W-23 T11, C22) ----
HERE = Path(__file__).resolve().parent
LOOPBACK, SERIAL, CODE = "127.0.0.1", "TESTCAM-0001", "QZCNRA"   # the camera file's markers (spec §4.5)


def closed_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind((LOOPBACK, 0))
    port = s.getsockname()[1]
    s.close()                                   # nothing listens: connect is refused
    return port


def state_dir(tmp) -> Path:
    return Path(tmp) / "common" / "ezviz" / "state"


def ledger_path(tmp, name: str = "cam1") -> Path:
    return state_dir(tmp) / f"{name}.ledger"


def rec(t: float, ev: str, dur=None, **kw) -> dict:
    return dict({"t": t, "ev": ev, "dur": dur}, **kw)


def _line(r: dict) -> bytes:
    return (json.dumps(r, separators=(",", ":")) + "\n").encode()


def seed_ledger(tmp, recs: list, name: str = "cam1", torn: bytes = b"") -> None:
    """Write records (and an optional torn tail with no newline) as the helper's ledger."""
    state_dir(tmp).mkdir(parents=True, exist_ok=True, mode=0o700)
    p = ledger_path(tmp, name)
    p.write_bytes(b"".join(_line(r) for r in recs) + torn)
    p.chmod(0o600)


def read_ledger(tmp, name: str = "cam1") -> list:
    """ledger.parse: a torn last line (a pause_cs hook mid-record) is skipped, never a crash."""
    try:
        return _ledger.parse(ledger_path(tmp, name).read_bytes())
    except FileNotFoundError:
        return []


def shift_ledger(tmp, seconds: float, name: str = "cam1") -> None:
    """Move every record `seconds` into the past (no helper may be running): the next run is within the budget."""
    recs = read_ledger(tmp, name)
    for r in recs:
        r["t"] -= seconds
    ledger_path(tmp, name).write_bytes(b"".join(_line(r) for r in recs))


def evs(recs: list) -> list:
    return [r["ev"] for r in recs]


class Helper:
    """One ezviz-source process (python -I -B -m ezviz_source.main) in its own session, against its own fake camera.

    Tree under tmp: snap/usr/lib/ffmpeg/8.0/bin/ffmpeg (fake_ffmpeg wrapper, or the real one), data/ezviz/cameras,
    common/ezviz/state. fake_args: a list starts fakecam.py with those knobs; None writes a camera file naming a
    closed port and starts no fake. share_fake=<Helper> reuses that helper's fake camera and camera file.
    Every process it starts is killed (whole process group) by close(); HelperCase calls close_all().
    """
    live: list = []
    _n = 0

    def __init__(self, tmp, name: str = "cam1", fake_args=(), *, hooks: str = "", real_ffmpeg: bool = False,
                 ffmpeg: bool = True, ffmpeg_knobs=None, share_fake=None, url=None, start: bool = True):
        Helper._n += 1
        self.n = Helper._n
        self.tmp, self.name = Path(tmp), name
        self.snap, self.data, self.common = self.tmp / "snap", self.tmp / "data", self.tmp / "common"
        self.cams, self.state = self.data / "ezviz" / "cameras", self.common / "ezviz" / "state"
        self.ledger_path = self.state / f"{name}.ledger"
        self.cams.mkdir(parents=True, exist_ok=True)
        bindir = self.snap / "usr" / "lib" / "ffmpeg" / "8.0" / "bin"
        bindir.mkdir(parents=True, exist_ok=True)
        ff = bindir / "ffmpeg"
        if ff.exists() or ff.is_symlink():
            ff.unlink()
        if ffmpeg:
            if real_ffmpeg:
                real = os.environ.get("W23_REAL_FFMPEG") or shutil.which("ffmpeg")
                if not real:
                    raise unittest.SkipTest("no real ffmpeg (set W23_REAL_FFMPEG)")
                ff.symlink_to(real)
            else:
                fake_ffmpeg(bindir, **(ffmpeg_knobs or {}))
        self.proc = self.fake = self.stats_path = None
        self._own_fake, self._files = False, []
        self.rc = self.t_exit = self.t_sig = None
        Helper.live.append(self)
        if share_fake is not None:
            self.fake, self.stats_path, self.cam_port = share_fake.fake, share_fake.stats_path, share_fake.cam_port
        else:
            if fake_args is None:
                self.cam_port = closed_port()
            else:
                self._start_fake(list(fake_args))
            self._write_camfile()
        self.url = url or f"rtsp://{LOOPBACK}:8554/{name}"
        extra = {"EZVIZ_TEST_HOOKS": hooks} if hooks else {}
        self.env = _path.child_env(SNAP=str(self.snap), SNAP_DATA=str(self.data), SNAP_COMMON=str(self.common),
                                   **extra)
        self.argv = [sys.executable, "-I", "-B", "-m", "ezviz_source.main", name, self.url]
        self.base = len(self.ledger())
        self.cmdline = b""
        if start:
            self.start()

    # -- setup
    def _start_fake(self, args: list) -> None:
        clip = self.tmp / "clip.h265"
        if not clip.exists():
            clip.write_bytes(SYNTH_ES)
        self.stats_path = self.tmp / f"fake-{self.n}.stats.json"
        port_file = self.tmp / f"fake-{self.n}.port"
        err = open(self.tmp / f"fake-{self.n}.err", "wb")
        self._files.append(err)
        self.fake = subprocess.Popen(
            [sys.executable, "-I", str(HERE / "fakecam.py"), "--code", CODE, "--es", str(clip),
             "--stats", str(self.stats_path), "--port-file", str(port_file),
             "--ledger-at-accept", str(self.ledger_path), *args],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=err, start_new_session=True)
        self._own_fake = True
        end = time.monotonic() + 15
        while not port_file.exists():
            if self.fake.poll() is not None or time.monotonic() > end:
                raise AssertionError("fake camera did not start: " + Path(err.name).read_text()[-2000:])
            time.sleep(0.02)
        self.cam_port = int(port_file.read_text())

    def _write_camfile(self) -> None:
        f = self.cams / f"{self.name}.conf"
        f.write_text(f"host={LOOPBACK}\nport={self.cam_port}\nserial={SERIAL}\nlogin={CODE}\n")
        f.chmod(0o600)

    def start(self) -> None:
        out = open(self.tmp / f"helper-{self.n}.out", "wb")
        err = open(self.tmp / f"helper-{self.n}.err", "wb")
        self._files += [out, err]
        self._out_path, self._err_path = Path(out.name), Path(err.name)
        self.t0 = time.monotonic()
        self.proc = subprocess.Popen(self.argv, env=self.env, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                     start_new_session=True)       # setsid: its own session and process group
        self.pid = self.pgid = self.proc.pid
        end = time.monotonic() + 5                       # argv as /proc shows it, once the exec has completed
        while time.monotonic() < end and self.proc.poll() is None:
            try:
                self.cmdline = Path(f"/proc/{self.pid}/cmdline").read_bytes()
            except OSError:
                break
            if b"ezviz_source.main" in self.cmdline:
                break
            time.sleep(0.005)

    # -- observation
    @property
    def stdout(self) -> str:
        return self._out_path.read_text(errors="replace") if self.proc else ""

    @property
    def stderr(self) -> str:
        return self._err_path.read_text(errors="replace") if self.proc else ""

    @property
    def elapsed(self) -> float:
        """Seconds from the first signal this harness sent (or the start) to the observed exit."""
        return self.t_exit - (self.t_sig if self.t_sig is not None else self.t0)

    def poll(self):
        if self.rc is None and self.proc is not None:
            rc = self.proc.poll()
            if rc is not None:
                self.rc, self.t_exit = rc, time.monotonic()
        return self.rc

    def ledger(self) -> list:
        return read_ledger(self.tmp, self.name)

    def new(self) -> list:
        """The records written since this helper was set up."""
        return self.ledger()[self.base:]

    def stats(self) -> dict:
        return json.loads(self.stats_path.read_text()) if self.stats_path else {}

    def _why(self) -> str:
        return f"ledger={self.ledger()} rc={self.poll()} stderr={self.stderr[-1500:]!r}"

    def _until(self, pred, timeout: float, what: str):
        end = time.monotonic() + timeout
        while True:
            exited = self.poll() is not None
            got = pred()
            if got:
                return got
            if exited:
                raise AssertionError(f"helper exited before {what}: {self._why()}")
            if time.monotonic() > end:
                raise AssertionError(f"no {what} within {timeout}s: {self._why()}")
            time.sleep(0.01)

    def wait_ev(self, ev: str, timeout: float) -> dict:
        return self._until(lambda: next((r for r in self.new() if r["ev"] == ev), None), timeout, f'"{ev}"')

    def wait_half_written(self, timeout: float) -> None:
        """Until the ledger's last line has no trailing newline (a pause_cs hook holds a half-written record)."""
        def half():
            try:
                b = self.ledger_path.read_bytes()
            except FileNotFoundError:
                return False
            return bool(b) and not b.endswith(b"\n")
        self._until(half, timeout, "half-written record")

    def wait_stderr(self, text: str, timeout: float) -> None:
        self._until(lambda: text in self.stderr, timeout, f"stderr {text!r}")

    def wait_stats(self, pred, timeout: float) -> None:
        self._until(lambda: pred(self.stats()), timeout, "fake camera stats")

    def wait_locked(self, timeout: float) -> None:
        """Until /proc/locks shows this helper's flock on <name>.session (no probe lock of ours, so no false busy)."""
        sess = self.state / f"{self.name}.session"

        def held():
            try:
                ino = os.stat(sess).st_ino
                lines = Path("/proc/locks").read_text().splitlines()
            except OSError:
                return False
            return any(p[1] == "FLOCK" and p[4] == str(self.pid) and p[5].endswith(f":{ino}")
                       for p in (ln.split() for ln in lines) if len(p) > 5)
        self._until(held, timeout, "session lock")

    def wait_exit(self, timeout: float) -> int:
        try:
            self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            raise AssertionError(f"helper still running after {timeout}s: {self._why()}") from None
        return self.poll()

    def ffmpeg_pid(self, timeout: float = 10.0) -> int:
        """The helper's child (the ffmpeg it spawned at login_ok), found by its parent pid."""
        def child():
            for st in Path("/proc").glob("[0-9]*/stat"):
                try:
                    fields = st.read_text().rsplit(")", 1)[1].split()
                except (OSError, IndexError):
                    continue
                if fields[1] == str(self.pid):
                    return int(st.parent.name)
            return None
        return self._until(child, timeout, "ffmpeg child")

    # -- signals
    def _mark(self) -> None:
        if self.t_sig is None:
            self.t_sig = time.monotonic()

    def term(self) -> None:
        self._mark()
        os.kill(self.pid, signal.SIGTERM)

    def term_group(self) -> None:
        self._mark()
        os.killpg(self.pgid, signal.SIGTERM)

    def kill(self) -> None:
        self._mark()
        os.kill(self.pid, signal.SIGKILL)

    def kill_ffmpeg(self) -> int:
        pid = self.ffmpeg_pid()
        os.kill(pid, signal.SIGKILL)
        return pid

    # -- teardown
    @staticmethod
    def _group_gone(pgid: int, timeout: float) -> bool:
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            try:
                os.killpg(pgid, 0)
            except ProcessLookupError:
                return True
            time.sleep(0.02)
        return False

    def close(self) -> None:
        leaks = []
        if self.proc is not None:
            try:
                os.killpg(self.pgid, signal.SIGKILL)       # the helper and its ffmpeg child
            except ProcessLookupError:
                pass
            self.proc.wait()
            self.poll()
            if not self._group_gone(self.pgid, 10):
                leaks.append(f"helper group {self.pgid}")
        if self._own_fake and self.fake is not None:
            try:
                os.killpg(self.fake.pid, signal.SIGTERM)
                self.fake.wait(5)
            except ProcessLookupError:
                pass
            except subprocess.TimeoutExpired:
                os.killpg(self.fake.pid, signal.SIGKILL)
                self.fake.wait()
            try:
                os.killpg(self.fake.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            if not self._group_gone(self.fake.pid, 10):
                leaks.append(f"fake group {self.fake.pid}")
            self._own_fake = False
        for f in self._files:
            f.close()
        self._files = []
        if leaks:
            raise AssertionError("processes left behind: " + ", ".join(leaks))

    @classmethod
    def close_all(cls) -> None:
        errors = []
        while cls.live:
            h = cls.live.pop()
            try:
                h.close()
            except Exception as e:  # noqa: BLE001 - close every helper, then report
                errors.append(e)
        if errors:
            raise errors[0]


class HelperCase(unittest.TestCase):
    """A fresh tmp tree per test; every helper, fake camera and ffmpeg is killed before the tree is removed."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="w23-helper-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.addCleanup(Helper.close_all)
