# M6 Design Spec — Coral-as-detector: the TPU joins the pool

**Date:** 2026-07-07
**Status:** Approved design, pre-implementation
**Parent spec:** [`2026-07-02-frigate-snap-design.md`](2026-07-02-frigate-snap-design.md) (§4-M6)
**Evidence base:** [`docs/spike-findings.md`](../../spike-findings.md) (M0-C: Coral USB delegate load + inference under raw-usb, 1a6e→18d1 re-enumeration protocol), [`docs/m3-findings.md`](../../m3-findings.md) (OpenVINO detection proven, model-provisioning discipline), [`docs/m5-findings.md`](../../m5-findings.md) (current harness/gate shape)

## 1. Goal

The snap runs Frigate with the **Coral USB TPU as a real detector alongside OpenVINO** in the detector pool, proven end-to-end on the attached stick (Bus 003, `1a6e:089a`). A user-facing accelerator doc records the support matrix, the manual `snap connect` lines, and the NVIDIA-classic decision. Verify criterion from the parent spec: detection runs on the Coral; snap connections documented per accelerator.

## 2. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| M6 scope | **Coral + NVIDIA doc** (USER); NPU productization → M7 backlog | Coral is the milestone; NVIDIA is documentation-only (strict-impossible per M0); NPU userspace is sizeable with no user demand yet |
| Detector arrangement | **Coral ALONGSIDE OpenVINO** (USER) — both in the pool | Proves the multi-detector story mixed-hardware users will hit; keeps the proven iGPU path as a control |
| Attribution method | **Stats-based (Approach A)**: per-detector `inference_speed` from `/api/stats` + EdgeTPU init log | Tests the shipping config; no test-only config states. The B-style Coral-only attribution phase is escalation-only, gated on a discovery check (§3.4) and USER sign-off |
| Frigate code | Stock `EdgeTpuTfl`, zero new patches | Standing no-patching ruling; only 0001-env-paths remains |

## 3. Components

### 3.1 Model staging (`spike/snap/snapcraft.yaml`, `detector-models` part)
- `ssdlite_mobiledet_coco_qat_postprocess_edgetpu.tflite` fetched from google-coral/test_data at the **same immutable commit `c21de44`** already used for the CPU fallback, sha256-pinned, installed to `/opt/frigate/models/edgetpu/edgetpu_model.tflite`. It is the EdgeTPU compilation of the same network as the staged CPU fallback, so the existing COCO labelmap at `/opt/frigate/models/labelmap.txt` pairs with it.
- `coral-model` part (bird-classifier probe model): URL re-pinned from mutable `master` to the same immutable commit; existing sha256 check unchanged (content must be identical — the pin is provenance hygiene, retiring the M7 note).

### 3.2 frigate daemon plugs
- `raw-usb` + `hardware-observe` added to the frigate app's plugs (M0 `coral-probe` precedent: `plugs: [raw-usb, hardware-observe]` — libusb needs both to enumerate and open the TPU). Both manual-connect; the accelerator doc carries the `snap connect` lines. Any residual denial gets a narrow labeled arm with the journal line quoted.

### 3.3 Config (`spike/config/frigate-config.yml`)
- `coral: {type: edgetpu, device: usb}` added beside `ov`, with a **detector-level model block**: `path: /opt/frigate/models/edgetpu/edgetpu_model.tflite`, 320×320, `input_tensor: nhwc`, `labelmap_path: /opt/frigate/models/labelmap.txt`. The global model block stays OpenVINO's (it is IR-specific: `.xml`, BGR, 300×300).
- **Plan-time discovery** (M3/M5 discipline): verify v0.17.2's per-detector model semantics against source — does `detectors.<name>.model` fully override or field-merge with the global block? Route the config through whatever the source proves; evidence quoted in findings.

### 3.4 Money-test verification (harness, above the denial marker; ALL M0–M5 assertions preserved)
1. `/api/stats` reports **both** detectors; each has `inference_speed` populated and plausible (Coral single-digit-to-low-tens ms; OpenVINO baseline ~7 ms known from M3/M4).
2. journald shows the EdgeTpuTfl initialization line (exact marker discovered at plan time from v0.17.2 source — the live daemon runs no edgetpu detector yet — and confirmed against the live daemon during implementation).
3. Existing detection-event machinery (testclip + conditional livecam with scene-dependent SKIP semantics) keeps proving the pool end-to-end.
4. Coral warm-up/rerun protocol wraps the gate (M0-proven: first open can fail while `1a6e:089a` re-enumerates as `18d1:9302` post-firmware-load; probe + rerun before FAIL verdicts).
5. **Discovery check** (Approach-A caveat): confirm from v0.17.2 source that `inference_speed` populates only from that detector's completed inferences. If it can populate without them, escalate to the B-style Coral-only attribution phase — only with USER sign-off.
6. Denial policy unchanged: 0 unexpected required; expected candidates — none new beyond possible raw-usb/`/sys` USB-enumeration arms on the frigate profile (coral-probe's arms exist; the daemon's would be new labels, journal-quoted).

### 3.5 Docs
- **`docs/accelerator-support.md`** (user-facing): support matrix — CPU / OpenVINO iGPU (VAAPI) / Coral USB under strict, each with its interface list and manual `snap connect` lines; Coral PCIe (`/dev/apex_0`) unsupported under strict (no interface, M0 finding); NVIDIA section: why the proprietary userspace cannot ride strict confinement → point at upstream's Docker image or a future classic variant. Seed for the M7 Store listing.
- **`docs/m6-findings.md`** in the M0–M5 style: verdict table, discovery records (per-detector model semantics, `inference_speed` semantics, init log marker), deviations, M7 decisions unlocked, raw evidence index (local-only; `git ls-files .superpowers/ spike/results/` empty — standing checklist item).

## 4. Out of scope (M6)

NPU userspace productization (M7 backlog); snap-set configurability of detectors/models (M7); Coral PCIe support; any NVIDIA implementation; MQTT/HomeAssistant; multi-Coral (`device: usb:0/usb:1`) arrangements.

## 5. Risks

1. **Boot-order vs re-enumeration** — the daemon may start while the TPU is still `1a6e:089a` (pre-firmware); `EdgeTpuTfl` raises, the detector process dies, `restart-condition: on-failure` retries. The warm-up probe runs pre-gate so steady-state is what's asserted; observed behavior recorded in findings.
2. **Per-detector model semantics** — if v0.17.2 field-merges instead of overriding, OpenVINO-specific fields (e.g. `input_pixel_format: bgr`) could leak into the Coral's model config. Discovery before wiring; the config block follows the source's proven semantics.
3. **Pool starvation of one detector** — two detectors sharing the frame queue can make one detector's stats update slowly under light load; assertion windows stay generous (M5 certsync-timing precedent), and the testclip runs continuously so the queue flows.
4. **udev tagging on connect** — `raw-usb` grants access via udev tagging at connect time; a stick plugged before the connect must still be visible. M0's probe path already proved this on this machine; re-verified implicitly by the gate.
