"""Platform probes: shared memory and layout behavior under strict confinement."""
import os
import time


LAYOUT_TEST_PATHS = [
    "/config/probe.txt",
    "/etc/letsencrypt/probe.txt",
    "/tmp/cache/probe.txt",
]


def layout_probe() -> dict:
    out: dict = {"status": "complete", "writes": {}}
    token = f"spike-{int(time.time())}"
    for path in LAYOUT_TEST_PATHS:
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(token)
            out["writes"][path] = {"ok": True, "token": token,
                                   "realpath": os.path.realpath(path)}
        except Exception as e:
            out["writes"][path] = {"ok": False, "error": f"{type(e).__name__}: {e}"}
    return out


def shm_probe() -> dict:
    from multiprocessing import shared_memory
    out: dict = {"status": "complete"}
    inst = os.environ.get("SNAP_INSTANCE_NAME", "frigate")

    # Sub-test 1: CPython default name (/dev/shm/psm_*) — Frigate's current behavior.
    try:
        m = shared_memory.SharedMemory(create=True, size=1024 * 1024)
        out["default_name"] = {"ok": True, "name": m.name}
        m.close()
        m.unlink()
    except Exception as e:
        out["default_name"] = {"ok": False, "error": f"{type(e).__name__}: {e}"}

    # Sub-test 2: snapd-conformant name (/dev/shm/snap.<instance>.*) — the candidate fix.
    try:
        m = shared_memory.SharedMemory(create=True, size=1024 * 1024,
                                       name=f"snap.{inst}.spike-probe")
        out["snap_prefixed"] = {"ok": True, "name": m.name}
        m.close()
        m.unlink()
    except Exception as e:
        out["snap_prefixed"] = {"ok": False, "error": f"{type(e).__name__}: {e}"}

    return out
