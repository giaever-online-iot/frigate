#!/usr/bin/env python3
"""C3: can a strict snap on classic Ubuntu reach /dev/accel/accel0 via a
self-provided custom-device slot? Device-node access only (driver stack out of scope)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probe_common import write_result

out: dict = {"status": "complete"}
try:
    fd = os.open("/dev/accel/accel0", os.O_RDWR)
    os.close(fd)
    out["open_accel0"] = {"ok": True}
except OSError as e:
    out["open_accel0"] = {"ok": False, "errno": e.errno, "error": e.strerror}
write_result("npu", out)
