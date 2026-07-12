"""Runtime probes: interpreter identity, wheel imports, native-lib loading."""
import ctypes
import importlib
import importlib.metadata
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
    for mod in ("numpy", "cv2", "onnxruntime", "tflite_runtime", "tensorflow",
                "openvino", "fastapi", "uvicorn", "starlette", "peewee",
                "pydantic", "scipy", "norfair", "zmq", "cryptography",
                "ruamel.yaml", "paho.mqtt.client"):
        try:
            # importlib.import_module handles dotted names correctly
            # (ruamel.yaml, paho.mqtt.client) returning the named submodule.
            m = importlib.import_module(mod)
            _ver = getattr(m, "__version__", "?")
            if _ver == "?":
                try:
                    _ver = importlib.metadata.version(
                        mod.split(".")[0].replace("_", "-"))
                except Exception:
                    pass
            out["imports"][mod] = {"ok": True, "version": _ver}
        except Exception as e:
            out["imports"][mod] = {"ok": False,
                                   "error": f"{type(e).__name__}: {e}"}

    # M8 (Task 2): sqlite-vec loadable extension. Frigate's semantic search loads vec0 from the
    # HARDCODED absolute path /usr/local/lib/vec0 (frigate/db/sqlitevecq.py — NOT patched); the
    # /usr/local/lib -> $SNAP/usr/local/lib layout makes that path resolve inside the snap. Python
    # is built --enable-loadable-sqlite-extensions. Record vec_version so the harness can report it.
    import sqlite3
    try:
        conn = sqlite3.connect(":memory:")
        conn.enable_load_extension(True)
        conn.load_extension("/usr/local/lib/vec0")
        vec_version = conn.execute("select vec_version()").fetchone()[0]
        conn.close()
        out["imports"]["sqlite_vec"] = {"ok": True, "version": vec_version}
    except Exception as e:
        out["imports"]["sqlite_vec"] = {"ok": False,
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
