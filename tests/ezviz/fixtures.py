"""Shared test fixtures: temp SNAP trees, canary camera files, the gate runner."""
import _path
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

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
