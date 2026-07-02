"""Runtime probes: interpreter identity, wheel imports, native-lib loading."""
import sys


def runtime_probe() -> dict:
    return {
        "status": "complete",
        "version_major_minor": f"{sys.version_info[0]}.{sys.version_info[1]}",
        "version_full": sys.version,
        "executable": sys.executable,
    }


def imports_probe() -> dict:
    out = {"status": "complete", "imports": {}}
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
