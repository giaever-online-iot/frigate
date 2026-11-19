"""Puts spike/ezviz first on sys.path for the tests; PKG is also exported to child processes."""
import os
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
    env.update(extra)
    return env
