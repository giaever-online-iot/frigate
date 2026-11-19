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
