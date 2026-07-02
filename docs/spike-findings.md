# M0 Spike Findings — Frigate snap de-risking

**Date:** 2026-07-02  **Host:** Ubuntu 24.04, snapd 2.75.2+ubuntu24.04, snapcraft 9.0.0, core26 rev 409 (20260531)

| # | Question | Verdict | Evidence |
|---|----------|---------|----------|
| A1 | psm_* shm denied? snap.* prefix works? | psm_* DENIED; snap.frigate.* prefix ALLOWED | spike/results/spike-results/shm.json, spike/results/denials.txt |
| A2 | /config + /etc/letsencrypt layouts work? | PARTIAL — /config rejected at pack time ("new top-level dir"); /etc/letsencrypt bind OK; /tmp/cache OK via private tmp | spike/results/spike-results/layout.json |
| A2b | /media/frigate layout allowed? | NO — rejected at pack time ("defines a new top-level directory /media") | spike/results/media-layout-pack-error.txt |
| A3 | after: ordering holds? readiness gap noted | YES ordering holds (svc-a ≤ svc-b ≤ svc-c); gaps 7–20 ms; jiffy ties (10 ms resolution) observed — after: is start-order only | spike/results/spike-results/ordering-svc-{a,b,c}.json |
| B1 | Python 3.11.9 builds on core26 toolchain? | YES — GCC 15.2.0, zero errors, ~1 m 22 s; note: g++ absent from the core26 build environment — any M1+ part compiling C++ must add it to build-packages | spike/results/spike-results/runtime.json |
| B2 | upstream cp311 wheels import? | 6/6 ok; tensorflow/openvino attempt network access at import time (socket create denied under strict confinement without a network plug — denied harmlessly in the spike; the real snap must plug `network`) | spike/results/spike-results/imports.json |
| B3 | bookworm libedgetpu dlopens? | YES — dlopen ok=true, sha256-pinned .deb | spike/results/spike-results/edgetpu-dlopen.json |
| C1 | vainfo + OpenVINO see the iGPU? | YES (VAAPI: iHD 26.1.2 via mesa-2604, MTL AV1/HEVC10/VP9; OpenVINO: [CPU, GPU]) — but GPU is NOT turn-key: requires intel-opencl-icd staged + /etc/OpenCL layouts; recipe documented | spike/results/vainfo.txt, spike/results/spike-results/gpu.json |
| C2 | Coral USB delegate+inference under raw-usb, re-enum survives? | YES FULL GO — delegate+firmware upload+inference OK; live re-enum 1a6e:089a (Dev076) → 18d1:9302 (Dev077) captured on first run; CAP_NET_ADMIN denial benign | spike/results/spike-results/coral.json, spike/results/coral-reenum-firstrun.txt |
| C3 | custom-device reaches /dev/accel on classic? | Branch (d) — open OK; self-slot connect OK, open(/dev/accel/accel0) OK; advisory CAP_SYS_ADMIN denial non-blocking, fires once per NPU device initialization (journal-verified; startup-only, not an inference-time event); Store approval needed only for distribution | spike/results/npu-connect.txt, spike/results/spike-results/npu.json, spike/results/denials.txt |

## Decisions unlocked

- **core26 GO/NO-GO:** GO. Python 3.11.9 builds clean on GCC 15.2.0 (B1), all 6 upstream cp311 wheels import under strict confinement (B2), and bookworm libedgetpu dlopen succeeds (B3). No toolchain or ABI blockers found. Snap at 556 MB; tf-cpu alone is 252 MB (sizing input for M2 store submission planning).

- **Network plug required from M2 onward:** tensorflow/openvino probe the network at import; without the `network` interface these are denied (harmless for detection, but plug `network` in the real snap — it auto-connects).

- **shm fix shape for M3:** Source patch on `SharedMemoryFrameManager` — rename every `psm_*` segment to use a `snap.<instance_name>.<suffix>` prefix. AppArmor policy in strict confinement allows `snap.<app>.* mknod` in `/dev/shm/` and denies the CPython default `psm_*` pattern. The prefix patch is confirmed viable (A1 sub-test 2). Pairs with const.py path patch below.

- **recordings dir strategy:** No layout — patch `const.py` to read base paths from environment variables (env-driven overrides), routing config and recordings to `$SNAP_COMMON`. Both `/config` and `/media/frigate` are pack-time hard blocks (snapd's layout validator rejects directories not present in the base system). There is no layout workaround for either path; env-driven path overrides are the only viable strategy for M3.

- **device interface matrix for the real snapcraft.yaml:**
  - VA-API decode: `extensions: [gpu]` + `plugs: [opengl]` → mesa-2604 content mount wires iHD driver automatically.
  - OpenVINO GPU inference: same as VA-API, plus stage `intel-opencl-icd` and wire `/etc/OpenCL` + `/usr/lib/x86_64-linux-gnu/intel-opencl` layouts. Not turn-key from the gpu extension alone; requires (a) intel-opencl-icd + libigdgmm12 + ocl-icd-libopencl1 staged with /etc/OpenCL and intel-opencl layouts, AND (b) LD_LIBRARY_PATH including the mesa-2604 content mount at runtime (gpu extension's cleanup strips libGL.so.1 from the snap; counterfactual-proven).
  - Coral USB: `plugs: [raw-usb, hardware-observe]`. USB re-enumeration survives wildcard raw-usb tagging. No net_admin needed.
  - Intel NPU (`/dev/accel/accel0`) and Coral-PCIe (`/dev/apex_0`): `custom-device` self-slot (snap provides its own slot with `devices:` path list; connect self; install with `--dangerous` on classic Ubuntu). Works under strict confinement. Non-root daemon needs udev tag or render group membership (M3 follow-up).
  - avahi-observe: deliberately deferred to M1 (go2rtc workload provides realistic test conditions).

- **readiness handling for M1+ daemons:** `after:` in snapcraft.yaml guarantees start order only (~7–20 ms gaps between consecutive daemons; jiffy ties at 10 ms resolution observed). It does NOT provide readiness gating. A real multi-daemon Frigate stack (detector, go2rtc, frigate core) needs `Type=notify` daemons or oneshot-chain patterns to prevent consumers starting before providers are ready.

## Raw evidence

- `spike/results/final-run.txt` — Final harness run (2026-07-02): SPIKE SMOKE: ALL PASS, 17 total denials, 0 unexpected
- `spike/results/denials.txt` — Full AppArmor denial log from final harness run
- `spike/results/vainfo.txt` — VA-API enumeration: Intel iHD 26.1.2, AV1/HEVC10/VP9/H264 full profile set (Meteor Lake)
- `spike/results/expanded-snapcraft.yaml` — snapcraft.yaml after `expand-extensions` (gpu plug injection, command-chain, cleanup parts)
- spike/results/media-layout-pack-error.txt — RECORDED pack-time rejection of the /media/frigate layout (renamed from media-layout-install.txt after review)
- `spike/results/coral-reenum-firstrun.txt` — RECORDED: first-run USB re-enumeration 1a6e:089a → 18d1:9302 (Task 11, overwritten by later runs)
- `spike/results/coral-usb-before.txt` — Steady-state before reading: 18d1:9302 (Device 077, post-first-run)
- `spike/results/coral-usb-after.txt` — Steady-state after reading: 18d1:9302 (Device 077, post-first-run)
- `spike/results/connections.txt` — `snap connections frigate`: custom-device (npu↔npu-dev), gpu-2604, opengl, raw-usb, hardware-observe
- `spike/results/npu-connect.txt` — Empty file (self-connect exited 0 silently — branch (d) confirmed)
- `spike/results/spike-results/shm.json` — A1: default_name ok=false (psm_* denied), snap_prefixed ok=true
- `spike/results/spike-results/layout.json` — A2: /config ok=false (PermissionError), /etc/letsencrypt ok=true, /tmp/cache ok=true
- `spike/results/spike-results/ordering-svc-a.json` — A3: svc-a start_monotonic (reference)
- `spike/results/spike-results/ordering-svc-b.json` — A3: svc-b start_monotonic
- `spike/results/spike-results/ordering-svc-c.json` — A3: svc-c start_monotonic (jiffy tie with svc-b on final run)
- `spike/results/spike-results/runtime.json` — B1: Python 3.11.9 (main, 2026-07-02) [GCC 15.2.0]
- `spike/results/spike-results/imports.json` — B2: numpy 1.26.4, cv2 4.11.0, onnxruntime 1.22.1, tflite_runtime 2.17.1, tensorflow 2.19.1, openvino 2025.3.0
- `spike/results/spike-results/edgetpu-dlopen.json` — B3: libedgetpu.so.1 dlopen ok=true
- `spike/results/spike-results/gpu.json` — C1: renderD128+card1 ok, openvino_devices [CPU, GPU]
- `spike/results/spike-results/coral.json` — C2: load_delegate ok=true, inference ok=true
- `spike/results/spike-results/npu.json` — C3: open_accel0 ok=true

## Deviations from expectations

**docs/snap-feasibility.md §2.3 correction (MAJOR):** The feasibility document claimed that snap layouts can create new top-level directories. This is incorrect. The spike proved at Task 5 (`/config`) and Task 6 (`/media/frigate`) that snapd's pack-time validator rejects any layout whose target would introduce a directory not already present in the base system (core26). The rejection message is deterministic: `layout "<path>" defines a new top-level directory "<dir>"`. Only paths whose root already exists in the base (e.g., `/etc`, `/usr`, `/var`) are valid layout targets. Applying this correction to `docs/snap-feasibility.md` is deferred to the post-M0 review; this findings document records the correction as authoritative.

**A3 jiffy ties:** The brief implied `svc-a < svc-b < svc-c` (strict ordering) would always be observable. In practice, consecutive daemons started within the same 10 ms kernel jiffy tick produce equal `start_monotonic` values. The harness assertion was updated to `≤` (ties allowed) to reflect observed reality. The finding is unchanged: `after:` provides start ordering, not readiness.

**C1 OpenVINO GPU not turn-key:** The spike expected the `gpu` extension alone to provide GPU inference capability. In practice, the extension's `gpu/cleanup` step removes `libGL.so.1` from snap prime (it lives in the mesa-2604 content provider at runtime), and `intel-opencl-icd` plus `/etc/OpenCL` layout wiring are additional requirements not provided by the extension. Both adaptations are confirmed necessary and sufficient via counterfactual probes (masking each fix in turn produces the failure mode). This is a non-blocking discovery: the recipe is documented and fully incorporated in the spike snap.

**C2 coral-reenum first-run capture semantics:** The harness overwrites `coral-usb-before.txt` and `coral-usb-after.txt` on each run. Once the device has been initialized (first run), both files show the steady-state 18d1:9302 address and the 1a6e:089a → 18d1:9302 transition is no longer visible in these files. The transition is archived in `spike/results/coral-reenum-firstrun.txt` (RECORDED, Task 11) and in the Task 11 report. The C2 finding is unaffected.

**avahi-observe not tested:** Deliberately deferred — go2rtc in M1 provides a realistic mDNS workload. Recorded as an open item; not a spike coverage gap.
