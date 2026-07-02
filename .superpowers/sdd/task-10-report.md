# Task 10 Report: Probe C1 — GPU via the gpu extension (vainfo + OpenVINO)

## What Was Implemented

### Files Created
- `spike/bin/gpu-probe` — command wrapper: runs vainfo → exec probe_gpu.py
- `spike/probes/probe_gpu.py` — OpenVINO Core().available_devices + render node open tests

### Files Modified
- `spike/snap/snapcraft.yaml` — added:
  - `gpu-probe` app (`extensions: [gpu]`, `plugs: [opengl]`)
  - `va-tools` part (`stage-packages: [vainfo, ocl-icd-libopencl1, intel-opencl-icd, libigdgmm12]`)
  - layouts: `/etc/OpenCL → $SNAP/etc/OpenCL`, `/usr/lib/x86_64-linux-gnu/intel-opencl → $SNAP/usr/lib/x86_64-linux-gnu/intel-opencl`
- `spike/bin/svc-a/b/c` — added `MESA_LIB=$SNAP/gpu-2604/mesa-2604/usr/lib/x86_64-linux-gnu` to `LD_LIBRARY_PATH` so cv2 finds libGL.so.1 (removed from snap prime by gpu/cleanup)
- `tests/spike-smoke.sh` — added: gpu smoke section, mesa-2604 pre-install in install block, expanded-snapcraft.yaml capture, denial allowlist additions, fixed `jqr` function-in-sh-c bug

---

## Expanded Extension Evidence

`snapcraft expand-extensions` (core26, snapcraft 9.0) for `gpu-probe: extensions: [gpu]`:

**Plug injected:**
```yaml
plugs:
  gpu-2604:
    interface: content
    target: $SNAP/gpu-2604
    default-provider: mesa-2604
```

**Command chain injected:**
```yaml
apps:
  gpu-probe:
    command-chain:
      - snap/command-chain/gpu-2604-wrapper
```

**Parts injected:**
- `gpu/wrapper` — builds `snap/command-chain/gpu-2604-wrapper` from `/snap/snapcraft/18124/share/snapcraft/extensions/gpu/command-chain` (sources mesa-2604 provider-wrapper at runtime)
- `gpu/cleanup` — clones `canonical/gpu-snap.git`; runs `gpu-2604-cleanup mesa-2604` at prime time; lists ALL user parts in `after:` (circular dep if any user part tries `after: [gpu/cleanup]`)

Plug name confirmed: `gpu-2604`; default-provider confirmed: `mesa-2604`. Harness uses these exact names.

---

## TDD Evidence

**RED** (--skip-install, before any code added):
```
error: cannot find app "gpu-probe" in "frigate"
FAIL: gpu probe complete
FAIL: openvino sees GPU
FAIL: vainfo produced output
```

**GREEN** (full harness, final snap):
```
SPIKE SMOKE: ALL PASS
```
All 24 checks pass including: `gpu probe complete`, `openvino sees GPU`, `vainfo produced output`, `no unexpected AppArmor denials`.

---

## THE FINDING — C1 Result

### gpu.json (verbatim)
```json
{
  "status": "complete",
  "render_node_access": {
    "/dev/dri/renderD128": "ok",
    "/dev/dri/card1": "ok"
  },
  "openvino_devices": [
    "CPU",
    "GPU"
  ]
}
```

### vainfo.txt key lines
```
libva info: Trying to open /snap/frigate/x1/gpu-2604/mesa-2604/usr/lib/x86_64-linux-gnu/dri/iHD_drv_video.so
libva info: Found init function __vaDriverInit_1_22
vainfo: Driver version: Intel iHD driver for Intel(R) Gen Graphics - 26.1.2 ()
vainfo: Supported profile and entrypoints
      VAProfileH264Main               :   VAEntrypointVLD / VAEntrypointEncSlice
      VAProfileHEVCMain               :   VAEntrypointVLD / VAEntrypointEncSlice
      VAProfileHEVCMain10             :   VAEntrypointVLD / VAEntrypointEncSlice
      VAProfileVP9Profile0            :   VAEntrypointVLD / VAEntrypointEncSlice
      VAProfileAV1Profile0            :   VAEntrypointVLD
      ... (full Meteor Lake profile set including AV1, HEVC 10-bit, VP9)
```
iHD driver 26.1.2 from mesa-2604 content mount — VA-API decode is fully functional.

### OpenVINO devices
`["CPU", "GPU"]` — GPU enumeration works via intel-opencl-icd + ICD layout wiring.

**C1 VERDICT: FULL GREEN** — strict snap on classic Ubuntu reaches Intel Meteor Lake iGPU for both VA-API decode (iHD driver, all profiles) and OpenVINO GPU enumeration.

---

## Non-Turn-Key Discoveries (M3 Planning Input)

1. **gpu/cleanup side effect**: The extension's `gpu/cleanup` part removes `libGL.so.1` (and other Mesa GPU libs) from the snap prime directory, relying on the content provider at runtime. Apps WITHOUT the gpu extension (like the svc daemons) need `LD_LIBRARY_PATH` pointing to the mesa-2604 content mount. Fixed in svc wrappers; M3 must wire this for all Python workers.

2. **OpenCL ICD not in mesa-2604**: `libOpenCL.so.1` and the Intel ICD (`intel-opencl-icd`) are NOT provided by mesa-2604. They must be staged in the snap + wired via `/etc/OpenCL` and `/usr/lib/x86_64-linux-gnu/intel-opencl` layouts. Added ~23MB.

3. **vainfo capabilities denied**: vainfo requests `CAP_SYS_ADMIN` and `CAP_PERFMON` from AppArmor — denied in strict confinement but non-fatal (vainfo still reports driver + profiles via DRM). Added to denial allowlist as expected.

4. **OpenVINO GPU extra sysfs probes**: The GPU plugin reads `/proc/*/mounts`, `/sys/kernel/mm/hugepages/`, `/sys/devices/system/node/online`, `/sys/bus/dax/devices/` — all denied (AppArmor), non-fatal. Added to allowlist.

5. **expand-extensions circular dep**: User parts cannot be named with `/` (rejected at pack time). Cannot create user part with `after: [gpu/cleanup]` — the extension auto-adds all user parts to `gpu/cleanup.after`.

6. **`jqr` in `sh -c` bug in brief**: The brief's check `sh -c "jqr gpu '.openvino_devices[]' | grep -q GPU"` fails because `jqr` is a bash function (invisible to `sh -c`). Fixed to `grep -q '"GPU"' "$RESULTS/gpu.json"`.

---

## New AppArmor Denials

18 total, 0 unexpected (all covered by updated allowlist):
- `gpu-probe`: `capname="sys_admin"` × 3, `capname="perfmon"` × 2 — vainfo querying DRM GPU capabilities
- `gpu-probe` + `svc-c`: OpenVINO GPU sysfs probes (hugepages/, node/online, bus/dax/, /proc/*/mounts)
- `svc-c`: same net/TLS/DNS patterns as Task 8

---

## Files Changed

| File | Change |
|------|--------|
| `spike/bin/gpu-probe` | NEW: vainfo + probe_gpu.py launcher |
| `spike/probes/probe_gpu.py` | NEW: OpenVINO + render node probe |
| `spike/snap/snapcraft.yaml` | gpu-probe app, va-tools part (vainfo+opencl), layouts |
| `spike/bin/svc-a`, `svc-b`, `svc-c` | Added mesa-2604 LD_LIBRARY_PATH for libGL.so.1 |
| `tests/spike-smoke.sh` | GPU smoke section, mesa pre-install, denial allowlist, jqr bug fix |

---

## Self-Review

**Correctness**: All prior-task work preserved (svc.py, probes, FINDING echoes, denial filter, sleep 20). New checks pass. Denial allowlist changes are exact and documented.

**Risk**: svc wrapper LD_LIBRARY_PATH change assumes mesa-2604 auto-connects at install time (confirmed: snapd auto-connects `default-provider` before daemons start). If mesa-2604 is removed/disconnected, svc wrappers gracefully skip (`[ -d "$MESA_LIB" ]` guard).

**Concern 1**: The OpenCL ICD approach is brittle — it assumes `intel-opencl-icd` works with the kernel's DRM driver. Works on this host (Meteor Lake, kernel 6.17). Different hardware may require different ICDs.

**Concern 2**: AppArmor denies CAP_SYS_ADMIN and CAP_PERFMON for vainfo. These are non-fatal for vainfo's operation (it still reports the driver), but a production snap needing hardware performance monitoring would need `hardware-observe` or `system-observe` interfaces.

**Concern 3**: OpenVINO GPU plugin's sysfs denials (hugepages, NUMA, DAX) suggest that GPU inference with OpenVINO in production will need additional AppArmor rules or interfaces beyond `opengl`.

---

## Commit

`6d607c9 spike(M0): probe C1 - gpu extension wiring, vainfo + OpenVINO GPU enumeration`

---

## Fix round 1 — counterfactual before-evidence

Reproduced post-hoc on the same installed snap by masking the fix; not a pre-fix capture.

### Fix 1 — OpenCL-ICD adaptation: GPU disappears without intel-opencl-icd

Command run:
```
sudo snap run --shell frigate.gpu-probe -c 'OCL_ICD_VENDORS=/nonexistent "$SNAP/usr/bin/python3.11" -c "from openvino import Core; print(Core().available_devices)"'
```

Exact output:
```
['CPU']
```

`OCL_ICD_VENDORS=/nonexistent` masked ICD discovery; GPU enumeration dropped to CPU-only. This confirms that staging `intel-opencl-icd` and wiring `/etc/OpenCL` + `/usr/lib/x86_64-linux-gnu/intel-opencl` layouts is the necessary and sufficient adaptation to make OpenVINO see the Intel GPU.

### Fix 2 — libGL/LD_LIBRARY_PATH adaptation: cv2 fails without mesa-2604 mount

Command run:
```
sudo snap run --shell frigate.svc-c -c 'LD_LIBRARY_PATH= "$SNAP/usr/bin/python3.11" -c "import cv2; print(cv2.__version__)"'
```

Exact output (exit 1):
```
Traceback (most recent call last):
  File "<string>", line 1, in <module>
  File "/snap/frigate/x1/usr/lib/python3.11/site-packages/cv2/__init__.py", line 181, in <module>
    bootstrap()
  File "/snap/frigate/x1/usr/lib/python3.11/site-packages/cv2/__init__.py", line 153, in bootstrap
    native_module = importlib.import_module("cv2")
                    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "/snap/frigate/x1/usr/lib/python3.11/importlib/__init__.py", line 126, in import_module
    return _bootstrap._gcd_import(name[level:], package, level)
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
ImportError: libGL.so.1: cannot open shared object file: No such file or directory
```

Clearing `LD_LIBRARY_PATH` removes the `$SNAP/gpu-2604/mesa-2604/usr/lib/x86_64-linux-gnu` entry that the `svc-c` wrapper injects, causing `libGL.so.1` (removed from snap prime by `gpu/cleanup`) to become unavailable. This confirms the `MESA_LIB` LD_LIBRARY_PATH addition to `spike/bin/svc-*` wrappers is the necessary and sufficient adaptation.

### Fix 3 — denial filter arms tightened

Three arms in the `UNEXPECTED` grep in `tests/spike-smoke.sh`:

| Arm | Before | After | Observed line in denials.txt |
|-----|--------|-------|------------------------------|
| node/online | `name="/sys/devices/system/node/online` (missing closing `"`) | `name="/sys/devices/system/node/online"` | `name="/sys/devices/system/node/online"` — MATCH |
| dax subtree | `name="/sys/bus/dax` (no trailing slash, matches any dax string) | `name="/sys/bus/dax/` (anchors to subtree) | No dax line in last run's denials.txt; tightened speculatively per review |
| mounts arm | `name="[^"]*\/mounts"` (matches any path ending in /mounts) | `name="/proc/[^"]*/mounts"` (anchored to /proc) | `name="/proc/3644805/mounts"` — MATCH |

Verified: `bash -n tests/spike-smoke.sh` silent; `sudo ./tests/spike-smoke.sh --skip-install` → `SPIKE SMOKE: ALL PASS`, 0 unexpected denials.

### Fix 4 — probe_coral.py Pyright annotation

`spike/probes/probe_coral.py`: `out = {"status": "complete"}` → `out: dict = {"status": "complete"}` (silences Pyright dict-inference widening error).

Snap rebuilt (`snapcraft pack`, parts cached); `sudo ./tests/spike-smoke.sh` (full install) → `SPIKE SMOKE: ALL PASS`, 20 denials, 0 unexpected.
