"""Shared helper: atomic JSON result writer for spike probes."""
import json
import os
import pathlib

# Evaluated at import time; SNAP_COMMON is set by snapd before Python starts.
RESULTS_DIR = pathlib.Path(os.environ.get("SNAP_COMMON", "/tmp")) / "spike-results"


def write_result(name: str, data: dict) -> None:
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    tmp = RESULTS_DIR / f".{name}.tmp"
    tmp.write_text(json.dumps(data, indent=2, default=str), encoding="utf-8")
    tmp.rename(RESULTS_DIR / f"{name}.json")
