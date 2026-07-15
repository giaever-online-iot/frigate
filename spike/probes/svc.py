#!/usr/bin/env python3
"""M8: re-homed probe payload from the retired svc-a/b/c ordering-spike daemons (M0).

Runs the platform (shm, layout) and runtime (interpreter identity, wheel imports,
edgetpu dlopen) probes ONCE as a CLI diagnostic (`frigate.imports-probe`), writing the
same JSON result files the harness reads. The M0 daemon-ordering paths (start_monotonic,
wait_for_url readiness, idle loop) are gone — the four real daemons carry ordering now.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probe_common import write_result
import probe_platform
import probe_runtime

# Ordered payload: writes shm.json, layout.json, runtime.json, imports.json, edgetpu-dlopen.json.
PROBES = [
    ("shm", probe_platform.shm_probe),
    ("layout", probe_platform.layout_probe),
    ("runtime", probe_runtime.runtime_probe),
    ("imports", probe_runtime.imports_probe),
    ("edgetpu-dlopen", probe_runtime.edgetpu_dlopen_probe),
]


def main() -> None:
    for result_name, fn in PROBES:
        try:
            write_result(result_name, fn())
        except Exception as e:  # a failing probe must never abort the rest of the payload
            try:
                write_result(result_name, {"status": "crashed",
                                           "error": f"{type(e).__name__}: {e}"})
            except Exception:
                pass  # even the crash report must not abort the run


if __name__ == "__main__":
    main()
