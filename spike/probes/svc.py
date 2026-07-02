#!/usr/bin/env python3
"""Spike stub daemon: records start time, runs its probes, then idles."""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probe_common import write_result

PROBES = {}  # service-name -> [(result_name, probe_fn)] — filled by later tasks


def _proc_start_monotonic() -> float:
    """Return process creation time as seconds since boot (10 ms resolution).

    Uses /proc/self/stat field 22 (starttime in jiffies) which reflects when
    systemd forked this process — unaffected by Python interpreter startup
    overhead, making it reliable for cross-service ordering comparisons.
    """
    with open("/proc/self/stat") as f:
        stat = f.read().split()
    return int(stat[21]) / os.sysconf("SC_CLK_TCK")


def main() -> None:
    name = sys.argv[1]
    write_result(f"ordering-{name}", {
        "service": name,
        "start_monotonic": _proc_start_monotonic(),
    })
    for result_name, fn in PROBES.get(name, []):
        try:
            write_result(result_name, fn())
        except Exception as e:  # a probe must never kill the daemon
            write_result(result_name, {"status": "crashed",
                                       "error": f"{type(e).__name__}: {e}"})
    while True:
        time.sleep(60)


if __name__ == "__main__":
    main()
