"""Runtime probes: interpreter identity, wheel imports, native-lib loading."""
import ctypes
import os
import sys


def runtime_probe() -> dict:
    return {
        "status": "complete",
        "version_major_minor": f"{sys.version_info[0]}.{sys.version_info[1]}",
        "version_full": sys.version,
        "executable": sys.executable,
    }


def imports_probe() -> dict:
    out: dict = {"status": "complete", "imports": {}}
    for mod in ("numpy", "cv2", "onnxruntime", "tflite_runtime",
                "tensorflow", "openvino"):
        try:
            m = __import__(mod)
            out["imports"][mod] = {"ok": True,
                                   "version": getattr(m, "__version__", "?")}
        except Exception as e:
            out["imports"][mod] = {"ok": False,
                                   "error": f"{type(e).__name__}: {e}"}
    return out


def edgetpu_dlopen_probe() -> dict:
    out: dict = {"status": "complete"}
    lib = os.path.join(os.environ.get("SNAP", ""),
                       "usr/lib/x86_64-linux-gnu/libedgetpu.so.1")
    out["lib_path"] = lib
    out["lib_exists"] = os.path.exists(lib)
    try:
        ctypes.CDLL(lib)
        out["dlopen"] = {"ok": True}
    except OSError as e:
        out["dlopen"] = {"ok": False, "error": str(e)}
    return out
