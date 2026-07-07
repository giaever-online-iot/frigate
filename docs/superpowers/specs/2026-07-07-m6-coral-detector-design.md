# M6 Design Spec — Coral-as-detector: the TPU proven, OpenVINO stays the default

**Date:** 2026-07-07 (amended same day: single-model-geometry discovery, USER re-ruling — see §2)
**Status:** Approved design, pre-implementation
**Parent spec:** [`2026-07-02-frigate-snap-design.md`](2026-07-02-frigate-snap-design.md) (§4-M6)
**Evidence base:** [`docs/spike-findings.md`](../../spike-findings.md) (M0-C: Coral USB delegate load + inference under raw-usb, 1a6e→18d1 re-enumeration protocol), [`docs/m3-findings.md`](../../m3-findings.md) (OpenVINO detection proven; testclip-cannot-event finding), [`docs/m5-findings.md`](../../m5-findings.md) (current harness/gate shape)

## 1. Goal

The snap runs Frigate with the **Coral USB TPU proven end-to-end as an object detector** on the attached stick (Bus 003, `1a6e:089a`), via a dedicated **Coral gate phase**; the shipped default config keeps OpenVINO. A user-facing accelerator doc records the support matrix, the manual `snap connect` lines, the one-detector-geometry constraint, and the NVIDIA-classic decision. Verify criterion from the parent spec: detection runs on the Coral; snap connections documented per accelerator.

## 2. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| M6 scope | **Coral + NVIDIA doc** (USER); NPU productization → M7 backlog | Coral is the milestone; NVIDIA is documentation-only (strict-impossible per M0); NPU userspace is sizeable with no user demand yet |
| Detector arrangement | **OpenVINO shipped default + Coral gate phase** (USER re-ruling, replacing the original "Coral alongside OpenVINO") | Discovery falsified "alongside": v0.17.2 `frigate/config/config.py` discards per-detector `model:` blocks ("users should not set model themselves"; `detector_config.model = None`) and only `model_path` overrides the single global model block — **one model geometry for all object detectors**. Our OpenVINO IR (300×300 BGR, 91-class labelmap) and the EdgeTPU tflite (320×320 RGB, 90-class labelmap) are incompatible on every axis; a coral detector beside `ov` inherits OpenVINO geometry and crashes. A Coral *default* would crash-loop for users without the stick, so OpenVINO ships and the gate proves Coral via a temporary config phase |
| Attribution | **Phase-based**: during the Coral phase the pool is coral-only, so every stat and event is the TPU's | Stronger than the original stats-only plan; forced (and gifted) by the same upstream constraint |
| Frigate code | Stock `EdgeTpuTfl`, zero new patches | Standing no-patching ruling; only 0001-env-paths remains |

## 3. Components

### 3.1 Model staging (`spike/snap/snapcraft.yaml`)
- `detector-models` part: `ssdlite_mobiledet_coco_qat_postprocess_edgetpu.tflite` fetched from google-coral/test_data at the **same immutable commit `c21de44`** as the CPU fallback (it is the EdgeTPU compilation of that same network), sha256 `4a2be2bbb614e576d56dcb914fa52752bf0f13411512710d355d97faa1b35641`, installed to `/opt/frigate/models/edgetpu/edgetpu_model.tflite`. The existing COCO labelmap at `/opt/frigate/models/labelmap.txt` pairs with it.
- `coral-model` part (bird-classifier probe model): URL re-pinned from mutable `master` to immutable commit `104342d2d3480b3e66203073dac24f4e2dbb4c41` — the commit whose blob matches the **already-pinned** sha256 (`5b468dfe…`); content at `c21de44` differs (`0400fbd9…`), so the original "same commit" wording was amended. Retires the M7 mutable-URL note.

### 3.2 frigate daemon plugs
- `raw-usb` + `hardware-observe` added to the frigate app's plugs (M0 `coral-probe` precedent: `plugs: [raw-usb, hardware-observe]` — libusb needs both to enumerate and open the TPU). Both manual-connect; the harness already connects both at snap level, and the accelerator doc carries the `snap connect` lines. Any residual denial gets a narrow labeled arm with the journal line quoted.

### 3.3 Config
- **Shipped template unchanged**: `ov` + the global OpenVINO model block stay exactly as M3 left them.
- The **Coral phase renders its config at gate time** by transforming the already-rendered `$SNAP_DATA/config/config.yml` (anchor: replace the `detectors:`…`model:` region, template-bounded by the following top-level `cameras:` key) into `coral: {type: edgetpu, device: usb}` + the EdgeTPU global model block (path/labelmap above; 320×320, `nhwc`, `rgb`, `ssd`). Transforming the rendered file preserves the livecam block — and its credential — without re-rendering; config contents are never written to evidence.

### 3.4 Money-test verification (harness; ALL M0–M5 assertions preserved)
The Coral phase runs after the M3 rollback proofs and before the denial scan (its denials are captured), gated coral-style: stick absent → explicit SKIPs, suite stays green. Sequence: back up config → transform → `snap restart frigate.frigate` → assert → restore → restart → re-assert steady state. Restore is trap-guaranteed (M4 stash-restore precedent).
1. journald (frigate unit, phase-marked): `Attempting to load TPU as usb` then `TPU found` — the v0.17.2 `EdgeTpuTfl.__init__` logger.info markers (source-quoted; failure branch logs `No EdgeTPU was detected`).
2. `/stats` on `:5001`: `detectors.coral.pid > 0` and `inference_speed` **moved off the init default** — v0.17.2 initializes `avg_inference_speed = Value("d", 0.01)` → stats report exactly `10.0` until real inferences update the moving average (source-quoted), so the assertion is `!= 10.0`, `> 0`, `< 100` (plausibility band).
3. Detection event on the Coral: livecam machinery with the standing scene-dependent SKIP semantics (armed + pipeline-alive + no event = SKIP; pipeline fault = FAIL). The testclip cannot produce events on stock code (M3 finding) but its constant frame flow is what drives `inference_speed` off the default.
4. One bounded warm-up rerun: if `TPU found` is absent and `lsusb` shows the device back in `1a6e` state, run `coral-probe` + restart once before verdicts (M0 re-enumeration protocol; the harness's early warm-up normally leaves the stick in `18d1`).
5. Restore proof: after the phase, `ov` reports in `/stats` again and the daemon is healthy.
6. Denial policy unchanged: 0 unexpected required; expected candidate — `frigate.frigate` `capname="net_admin"` (libusb netlink hotplug monitor, mirroring the existing `coral-probe` arm); added ONLY if observed, journal-quoted.

### 3.5 Docs
- **`docs/accelerator-support.md`** (user-facing): support matrix — CPU / OpenVINO iGPU (VAAPI) / Coral USB under strict, each with its interface list and manual `snap connect` lines; the **one-model-geometry constraint** (one object-detector type at a time; how to switch the config to the Coral, using the staged EdgeTPU model paths); Coral PCIe (`/dev/apex_0`) unsupported under strict (no interface, M0 finding); NVIDIA section: why the proprietary userspace cannot ride strict confinement → point at upstream's Docker image or a future classic variant. Seed for the M7 Store listing.
- **`docs/m6-findings.md`** in the M0–M5 style: verdict table, discovery records (single-geometry `config.py` quote, `inference_speed` 10.0-default quote, TPU log markers, bird-pin content mismatch), deviations (the §2 re-ruling), M7 decisions unlocked, raw evidence index (local-only; `git ls-files .superpowers/ spike/results/` empty — standing checklist item).

## 4. Out of scope (M6)

NPU userspace productization (M7 backlog); snap-set configurability of detectors/models (M7); Coral PCIe support; any NVIDIA implementation; MQTT/HomeAssistant; multi-Coral (`device: usb:0/usb:1`) arrangements; literal-safe config renderer (M7, recorded M4).

## 5. Risks

1. **Phase restore failure** — a crash mid-phase must not leave the snap wedged on a coral config the user's hardware may not support tomorrow. Restore runs from a root-owned backup inside `$SNAP_DATA/config/` and is wired into the harness EXIT trap (idempotent), the M4 stash-restore lesson.
2. **Boot-order vs re-enumeration** — the daemon may load the delegate while the TPU is `1a6e:089a` (pre-firmware); `EdgeTpuTfl` raises, the detector process dies, `restart-condition: on-failure` retries; §3.4.4's bounded rerun handles the residue. Observed behavior recorded in findings.
3. **`inference_speed` near the default** — a real Coral averages ~8–10 ms, adjacent to the 10.0 init value; the `!= 10.0` exact-match plus the `TPU found` marker plus `pid > 0` together make a false PASS require the moving average to sit at exactly 10.00 ms, which real timing jitter (hundredths precision) does not do. Findings record the observed value.
4. **udev tagging on connect** — `raw-usb` grants access via udev tagging at connect time; a stick plugged before the connect must still be visible. M0's probe path already proved this on this machine; re-verified implicitly by the gate.
