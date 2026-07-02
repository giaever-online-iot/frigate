#!/usr/bin/env python3
"""C1: which GPU devices does a strict snap reach (OpenVINO + render nodes)?"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probe_common import write_result

out = {"status": "complete", "render_node_access": {}}
try:
    from openvino import Core
    out["openvino_devices"] = Core().available_devices
except Exception as e:
    out["openvino_devices"] = []
    out["openvino_error"] = f"{type(e).__name__}: {e}"

for node in ("/dev/dri/renderD128", "/dev/dri/card1"):
    try:
        fd = os.open(node, os.O_RDWR)
        os.close(fd)
        out["render_node_access"][node] = "ok"
    except OSError as e:
        out["render_node_access"][node] = f"errno={e.errno} {e.strerror}"

write_result("gpu", out)
