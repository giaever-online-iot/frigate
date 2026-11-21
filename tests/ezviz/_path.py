"""Puts spike/ezviz first on sys.path for the tests; PKG is also exported to child processes."""
import os
import subprocess
import sys
import unittest.mock  # noqa: F401  (tests use unittest.mock.patch)
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PKG = REPO / "spike" / "ezviz"
sys.path.insert(0, str(PKG))
sys.dont_write_bytecode = True


def child_env(**extra) -> dict:
    env = {k: v for k, v in os.environ.items() if not k.startswith("EZVIZ_TEST")}
    env["PYTHONPATH"] = str(PKG)
    env["PYTHONDONTWRITEBYTECODE"] = "1"   # N4: children that are not -I
    env.update(extra)
    return env


# Fix wave 1, S3: a `python -I` child ignores PYTHONPATH, so it imports ezviz_source from whatever checkout the venv's
# ezviz_source.pth names (the last checkout that ran venv.sh with the same W23_VENV). Every -I child launch goes
# through isolated_python(), which checks ONCE per test process that the child imports THIS checkout, and otherwise
# fails hard, so a pass can never be about another checkout's helper.
_checked = None     # None: not yet checked; "": this checkout; otherwise the failure text


def check_isolated_import(python: str) -> str:
    """'' when `python -I` imports ezviz_source from under PKG, else a message naming the expected and the actual
    checkout."""
    want = (PKG / "ezviz_source").resolve()
    head = f"expected checkout {REPO} ({want})"
    p = subprocess.run([python, "-I", "-c", "import ezviz_source; print(ezviz_source.__file__)"],
                       stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
    fix = "build this checkout's venv: unset W23_VENV or give it a path of its own, then PY=$(bash tests/ezviz/venv.sh)"
    if p.returncode != 0 or not p.stdout.strip():
        last = (p.stderr.strip().splitlines() or [""])[-1]
        return f"{python} -I cannot import ezviz_source (rc {p.returncode}: {last}); {head}; {fix} (W23_VENV)"
    got = Path(p.stdout.strip()).resolve()
    if got.parent == want:
        return ""
    actual = got.parents[3] if len(got.parents) > 3 and got.parents[1].name == "ezviz" else got.parent
    return f"{python} -I imports ezviz_source from {got}: actual checkout {actual}, {head}; {fix} (W23_VENV)"


def isolated_python() -> str:
    """sys.executable for a `-I` child, after the once-per-process checkout check. Raises AssertionError (a test
    FAIL) on a mismatch, every time it is called."""
    global _checked
    if _checked is None:
        _checked = check_isolated_import(sys.executable)
    if _checked:
        raise AssertionError("wrong checkout for the -I children: " + _checked)
    return sys.executable
