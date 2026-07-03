#!/usr/bin/env python3
"""Spike stub daemon: records start time, runs its probes, then idles."""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probe_common import write_result
import probe_platform
import probe_runtime

PROBES: dict = {
    "svc-a": [("shm", probe_platform.shm_probe)],
    "svc-b": [("layout", probe_platform.layout_probe)],
    "svc-c": [("runtime", probe_runtime.runtime_probe),
              ("imports", probe_runtime.imports_probe),
              ("edgetpu-dlopen", probe_runtime.edgetpu_dlopen_probe)],
}


def _proc_start_monotonic() -> float:
    """Kernel-recorded process start time (CLOCK_MONOTONIC base, jiffy resolution).

    Parses /proc/self/stat safely: comm (field 2) may contain spaces or ')',
    so split after the LAST ')'. starttime is field 22 overall -> index 19
    of the post-comm remainder.
    """
    with open("/proc/self/stat") as f:
        raw = f.read()
    after_comm = raw[raw.rindex(")") + 2:]
    return int(after_comm.split()[19]) / os.sysconf("SC_CLK_TCK")


def main() -> None:
    name = sys.argv[1]
    write_result(f"ordering-{name}", {
        "status": "complete",
        "service": name,
        "start_monotonic": _proc_start_monotonic(),
        "waited_ms": int(os.environ.get("SPIKE_WAITED_MS", "-1")),
    })
    for result_name, fn in PROBES.get(name, []):
        try:
            write_result(result_name, fn())
        except Exception as e:  # a probe must never kill the daemon
            try:
                write_result(result_name, {"status": "crashed",
                                           "error": f"{type(e).__name__}: {e}"})
            except Exception:
                pass  # even the crash report must not kill the daemon
    while True:
        time.sleep(60)


if __name__ == "__main__":
    main()
