"""frigate.ezviz-check <name> (spec §6.1, N9; plan N2). Contacts no camera; prints one fixed-form line."""
import re
import stat
import sys
import time

from . import camfile, ledger, paths, policy
from . import constants as C


def check(name: str) -> str:
    try:
        camfile.load(name, paths.camera_dir())
    except camfile.CameraFileError as e:
        return e.cls
    except OSError:
        # A guard only: since the W-23 final wave camfile.load wraps its own OSErrors (open, fstat, read).
        return "missing"
    state = paths.state_dir()
    try:
        st = state.lstat()
    except FileNotFoundError:
        return "statedir"
    if not stat.S_ISDIR(st.st_mode) or stat.S_IMODE(st.st_mode) != 0o700:
        return "statedir"
    lp = state / f"{name}.ledger"
    try:
        recs = ledger.parse(lp.read_bytes()) if lp.exists() else []
    except ledger.LedgerDamaged:
        return "ledger_damaged"
    except OSError:
        return "statedir"                      # an unreadable ledger means the state dir is unusable
    latch = (state / f"{name}.latch").exists()
    if policy.decide(recs, time.time(), latch_file=latch).cls == "latched":
        return "latched"
    return "ok"


def main(argv: list) -> int:
    if len(argv) != 1 or not re.fullmatch(C.NAME_RE, argv[0]):
        sys.stderr.write("usage: ezviz-check <name>\n")
        return 2
    cls = check(argv[0])
    print(f"ezviz-check {argv[0]}: {cls}")
    return 0 if cls == "ok" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
