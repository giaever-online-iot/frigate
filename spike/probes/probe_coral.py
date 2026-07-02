#!/usr/bin/env python3
"""C2: Coral USB under raw-usb — delegate load triggers firmware upload and
re-enumeration (1a6e:089a -> 18d1:9302); inference proves the reborn node is usable."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probe_common import write_result

out = {"status": "complete"}
snap = os.environ.get("SNAP", "")
lib = os.path.join(snap, "usr/lib/x86_64-linux-gnu/libedgetpu.so.1")
model = os.path.join(snap, "models/edgetpu-test.tflite")

try:
    import tflite_runtime.interpreter as tflite
    delegate = tflite.load_delegate(lib)
    out["load_delegate"] = {"ok": True}
except Exception as e:
    out["load_delegate"] = {"ok": False, "error": f"{type(e).__name__}: {e}"}
    write_result("coral", out)
    sys.exit(0)

try:
    import numpy as np
    interp = tflite.Interpreter(model_path=model,
                                experimental_delegates=[delegate])
    interp.allocate_tensors()
    detail = interp.get_input_details()[0]
    interp.set_tensor(detail["index"],
                      np.zeros(detail["shape"], dtype=detail["dtype"]))
    interp.invoke()
    out["inference"] = {"ok": True}
except Exception as e:
    out["inference"] = {"ok": False, "error": f"{type(e).__name__}: {e}"}

write_result("coral", out)
