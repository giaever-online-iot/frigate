"""The configure hook's unlatch (spec §4.2; plan P6, P9, N3). Stdlib only.

`sudo snap set frigate ezviz.<name>.unlatch=$(date +%s)` -> for every valid name whose value is an integer
and differs from <name>.unlatch-seen: under the ledger lock, if the camera is latched (the latch file, or
the ledger by itself), remove the file and append "unlatch". The seen-file stops a later, unrelated
`snap set` from unlatching a NEW latch with the same old value.
"""
import json
import os
import re
import subprocess
import sys
import time

from . import constants as C
from . import ledger, paths, policy


def _snapctl_get() -> dict:
    out = subprocess.run(["snapctl", "get", "-d", "ezviz"], capture_output=True, text=True)
    if out.returncode != 0:
        return {}
    try:
        return (json.loads(out.stdout) or {}).get("ezviz") or {}
    except ValueError:
        return {}


def _say(msg: str) -> None:
    sys.stdout.write("configure: ezviz " + msg + "\n")


def run(cfg: dict, now=time.time) -> int:
    state = paths.state_dir()
    if not state.is_dir():
        return 0
    for name in sorted(cfg):
        val = (cfg.get(name) or {}).get("unlatch") if isinstance(cfg.get(name), dict) else None
        if val is None or not re.fullmatch(C.NAME_RE, name):
            continue
        if isinstance(val, bool) or not isinstance(val, int):
            _say(f"{name} ignored (not an integer)")
            continue
        seen = state / f"{name}.unlatch-seen"
        try:
            if seen.read_text().strip() == str(val):
                continue
        except FileNotFoundError:
            pass
        latch = state / f"{name}.latch"
        with ledger.Ledger(state / f"{name}.ledger") as L:
            latched = latch.exists() or policy.decide(L.records(), now(), latch_file=False).cls == "latched"
            if latched:
                if latch.exists():
                    latch.unlink()
                    ledger._fsync_dir(state)
                L.append({"t": now(), "ev": "unlatch", "dur": None})
        fd = os.open(seen, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, f"{val}\n".encode())
            os.fsync(fd)
        finally:
            os.close(fd)
        _say(f"{name} unlatched" if latched else f"{name} not latched")
    return 0


def main() -> int:
    os.umask(0o077)
    try:
        return run(_snapctl_get())
    except (ledger.LedgerDamaged, ledger.LedgerIOError) as e:
        _say(f"unlatch failed ({type(e).__name__})")
        return 1


if __name__ == "__main__":
    sys.exit(main())
