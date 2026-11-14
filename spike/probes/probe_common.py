"""Shared helper: atomic JSON result writer for spike probes."""
import json
import os
import pathlib
import platform

# Evaluated at import time; SNAP_COMMON is set by snapd before Python starts.
RESULTS_DIR = pathlib.Path(os.environ.get("SNAP_COMMON", "/tmp")) / "spike-results"


def write_result(name: str, data: dict) -> None:
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    tmp = RESULTS_DIR / f".{name}.tmp"
    tmp.write_text(json.dumps(data, indent=2, default=str), encoding="utf-8")
    tmp.rename(RESULTS_DIR / f"{name}.json")


def arch_triplet() -> str:
    m = platform.machine()
    if m == "x86_64":
        return "x86_64-linux-gnu"
    if m == "aarch64":
        return "aarch64-linux-gnu"
    raise RuntimeError(f"unsupported machine: {m}")


def edgetpu_lib() -> str:
    return os.path.join(os.environ.get("SNAP", ""), "usr/lib", arch_triplet(), "libedgetpu.so.1")
