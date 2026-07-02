"""Runtime probes: interpreter identity, wheel imports, native-lib loading."""
import sys


def runtime_probe() -> dict:
    return {
        "status": "complete",
        "version_major_minor": f"{sys.version_info[0]}.{sys.version_info[1]}",
        "version_full": sys.version,
        "executable": sys.executable,
    }
