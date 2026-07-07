# M6 Findings — Coral-as-detector: the TPU proven, OpenVINO stays the default

**Date:** 2026-07-07  **Snap:** frigate 0.0.1-spike (core26, strict)  **Frigate:** v0.17.2  **Branch:** m6-coral-detector  **HEAD:** 62e8282 (final-review fix wave: trap hoist + backup-clobber guard + health check; SHM denylist / render-once comments; accelerator-doc CPU/ownership/PCIe corrections)

The Coral USB TPU (`18d1:9302`, post-firmware; `1a6e:089a` pre-firmware) is proven end-to-end as an **object detector** under the frigate daemon via a dedicated, self-restoring **Coral gate phase**. The shipped default detector stays OpenVINO. What the gate proved on the stick this run (delegate load, EdgeTPU model load, coral detect-process liveness, config swap + restore) is separated below from what could not be exercised tonight (real TPU inference and a detection event — both blocked only by the live camera being off-network, and both auto-assert on the next powered gate run with no harness change).

Authoritative run: `spike/results/m6-final-run.txt` (start `2026-07-07T21:48:16+02:00`; `SPIKE SMOKE: ALL PASS`). Every number below is grep-verified against that transcript — it is the only source for run numbers.

| # | Question | Verdict | Evidence |
|---|----------|---------|----------|
| M6-1 | Frigate loads the staged EdgeTPU model + the Coral delegate under the daemon on the swapped config? | **YES** — after the harness swaps `$SNAP_DATA/config/config.yml` to `coral: {type: edgetpu, device: usb}` + the 320×320 EdgeTPU model block and restarts, the frigate unit journals both `EdgeTpuTfl.__init__` markers: `Attempting to load TPU as usb` (21:53:26) then `TPU found` (21:53:29). The API comes back up on the coral config. This is the delegate loading `libedgetpu.so.1.0` against the physical stick, not a probe. | m6-final-run.txt (`PASS: coral phase: API back up on coral config`; `PASS: coral phase: journal 'Attempting to load TPU as usb'`; `PASS: coral phase: journal 'TPU found' (delegate loaded)`); `spike/results/coral-phase-journal.txt` (both marker lines, `frigate.frigate[459926]`, 21:53:26 → 21:53:29) |
| M6-2 | The Coral detector *process* is alive on the TPU config (coral-only pool)? | **YES** — `/stats` on `:5001` reports `detectors.coral.pid = 460323` (> 0). During the phase the detector pool is coral-only, so any stat or event in that window is the TPU's (the phase-based attribution forced and gifted by the single-geometry constraint, D1). | m6-final-run.txt (`PASS: coral phase: coral detector process alive on TPU config (pid > 0 in /stats)`); `spike/results/coral-phase-stats.json` (`.detectors.coral.pid = 460323`) |
| M6-3 | Config swap + restore round-trips cleanly; the operator's OpenVINO default comes back healthy? | **YES** — after the phase the harness restores from a root-owned backup inside `$SNAP_DATA/config/` (trap-guaranteed) and restarts; `ov` reports in `/stats` again and the unit is `active`. Restore proved sound even under failure in earlier gate runs (runs 1–3 FAILed mid-phase yet still ended with the restore PASS — inline restore + EXIT trap both fire). | m6-final-run.txt (`PASS: coral phase: OpenVINO default restored (ov reporting in /stats)`; `PASS: coral phase: frigate healthy after restore`); task-2-report.md §Final state (restore under failure) |
| M6-4 | **Actual TPU inference** proven (inference_speed drifts off the init default)? | **NOT YET — SKIP (deferred, not failed).** `inference_speed` sits at exactly `10.0` ms — the `Value("d", 0.01)` init default (D2), never updated: `detection_start = 0.0`, no inference has run. The looping testclip cannot drive the detector (D6), and the live camera is unreachable this run, so no frame source exists to produce inference. The drift MONEY check is livecam-gated: SKIP with reason, while the coral-pid liveness assertion (M6-2) hard-asserts regardless. Auto-asserts on the next gate run with the camera powered — no harness change. | m6-final-run.txt (`SKIP: coral phase MONEY: inference_speed drift — livecam-url present but camera port unreachable at harness start; testclip cannot feed the detector (M3 calibration finding)…`; `coral finding: inference_speed=10.0ms (10.0 = init default; drift unprovable without livecam)`); `spike/results/coral-phase-stats.json` (`.detectors.coral.inference_speed = 10.0`, `.detection_start = 0.0`) |
| M6-5 | A detection **event** attributable to the Coral? | **NOT YET — SKIP (deferred, not failed).** Same livecam-unreachable cause as M6-4. The testclip cannot produce events on stock code (M3 finding). SKIP with documented reason; a pipeline *fault* on coral config would have FAILed instead (it did not). Auto-asserts on the next powered gate run. | m6-final-run.txt (`SKIP: coral phase: person event detected BY THE TPU — livecam-url present but camera port unreachable at harness start`) |
| M6-6 | Full gate: ALL PASS with the documented degraded-camera SKIPs, no unexpected denials, no new policy arms? | **YES** — **SPIKE SMOKE: ALL PASS**. **112 PASS / 0 FAIL / 5 SKIP**. AppArmor: **366 total denials, 0 unexpected**. **ZERO new denial arms** across all of M6 — the existing `coral-probe … capname="net_admin"` arm already covers libedgetpu USB init. The 5 SKIPs are all the one live-camera-off-network condition: 3 × M3 livecam money (real-object detect, label/score, split-DB corroboration) + 2 × M6 coral (drift + person-event). | m6-final-run.txt (authoritative: `SPIKE SMOKE: ALL PASS`; `== denials: 366 total, 0 unexpected ==`; `PASS: no unexpected AppArmor denials`; the 5 `SKIP:` lines) |

Coral substrate carried from M0 (proven every milestone, and again this run before the phase): `PASS: coral delegate loaded (firmware upload)`, `PASS: coral inference ran`, `PASS: coral: device in initialized state (18d1) after probe`.

---

## Coral: proven vs. not-yet-proven — stated plainly

**PROVEN on the Coral this run** (hard-asserted PASS): delegate load (`TPU found`), the staged EdgeTPU model loads under the frigate daemon, the coral detect process is alive (`pid 460323 > 0`) on the swapped config, and the config swap + restore round-trip is clean (OpenVINO default restored, unit healthy). The raw M0 substrate — firmware upload + a real `coral inference ran` via `coral-probe` — also passed again this run.

**NOT YET PROVEN** (SKIP, deferred to a powered camera; harness needs no changes): actual frigate-driven TPU **inference** (the `inference_speed` drift) and a **detection event** on the Coral. Both are blocked solely by the live camera being off-network tonight (`No route to host`, controller-verified) combined with the standing fact that the looping testclip drives no detector inference (D6). On the next `sudo tests/spike-smoke.sh` with the camera powered, both checks hard-assert automatically.

Neither side is softened: the delegate and detector-process facts are real and hard-gated; the inference/event facts are honestly outstanding.

---

## Discovery records

Each carries its source quote. D1–D3 were found pre-plan (recorded in the amended spec §2 / §3); D4–D6 were surfaced during gate execution (task-2-report.md). Source line references are from the installed snap `/snap/frigate/x2/opt/frigate/frigate`.

### D1 (PRE-PLAN) — v0.17.2 single-model-geometry constraint → USER re-ruling

Frigate v0.17.2 discards any per-detector `model:` block and keeps **one global model geometry for all object detectors**; only `model_path` overrides the single model block. `frigate/config/config.py` (lines 476–491, verbatim):

```python
# users should not set model themselves
if detector_config.model:
    detector_config.model = None
...
if detector_config.model_path:
    model_config["path"] = detector_config.model_path
...
elif detector_config.type == "edgetpu":
    model_config["path"] = "/edgetpu_model.tflite"
```

Consequence: our OpenVINO IR (300×300 BGR, 91-class labelmap) and the EdgeTPU tflite (320×320 RGB, 90-class labelmap) are incompatible on every axis; a coral detector configured *beside* `ov` inherits OpenVINO geometry and crashes. A Coral *default* would crash-loop for any user without the stick. **USER re-ruling** (replacing the pre-plan "Coral alongside OpenVINO"): OpenVINO stays the shipped default; Coral is proven via a temporary gate phase. This also *gifts* phase-based attribution — during the phase the pool is coral-only, so every stat and event is the TPU's.

Source: spec §2 / §3.1; config.py:476–491 (verbatim above).

### D2 (PRE-PLAN) — `inference_speed` initializes to exactly 10.0

`/stats` reports `inference_speed` as exactly `10.0` ms until real inferences update the moving average — because the average initializes to `0.01` and stats multiply by 1000. Presence-style assertions (`inference_speed` field exists / is a number) false-pass on a detector that has never run a single inference. `frigate/object_detection/base.py:325`:

```python
self.avg_inference_speed = Value("d", 0.01)
```

`frigate/stats/util.py:298`:

```python
"inference_speed": round(detector.avg_inference_speed.value * 1000, 2),   # 0.01 * 1000 = 10.0
```

Design consequence: the money check is a **drift** assertion (`!= 10.0`, `> 0`, `< 100` plausibility band), not a presence check. This run confirmed the default is real and sticky: coral `inference_speed = 10.0`, `detection_start = 0.0` (`spike/results/coral-phase-stats.json`); the OpenVINO baseline earlier in the same run also read `ov inference_speed=10.0ms` (m6-final-run.txt `gpu finding`), for the same reason.

Source: spec §3.4.2; base.py:325 + util.py:298 (verbatim above).

### D3 (PRE-PLAN) — bird probe-model content mismatch; URL re-pinned

The `coral-model` (bird-classifier probe) was pinned to a mutable `raw/master/` URL whose blob happened to satisfy the pinned sha256 `5b468dfe…`. That content does **not** live at commit `c21de44` (where the detector model lives) — `c21de44` serves a *different* blob (`0400fbd9…`). The pinned `5b468dfe…` content lives at commit `104342d2d3480b3e66203073dac24f4e2dbb4c41`. The URL was re-pinned to that immutable commit (commits do not unify — c21de44 serves different content). This **retires the M7 mutable-URL note**. The detector model itself stays at `c21de44` (sha256 `4a2be2bb…`), verified byte-exact inside the squashfs.

Source: spec §3.1; task-1-report.md Steps 1–2 (both pins byte-exact; the c21de44/0400fbd9 warning comment landed in-tree).

### D4 (EXECUTION, gate-discovered) — frigate-run re-rendered config on every start

`spike/bin/frigate-run` rendered `config.yml` from the read-only squashfs template on **every** daemon start (a deliberate M3 interim). This clobbered the coral phase's config swap before frigate read it (gate run 1 FAILed markers + drift) — and would equally clobber any operator edit, contradicting `docs/accelerator-support.md`, which instructs editing `config.yml`. **Fix:** render-if-absent (first start only); the operator owns `config.yml` thereafter; delete-to-regenerate; the harness re-arms livecam via `rm config.yml` + restart. Landed in `ab34d76`; SHM/render-once comments finalized in `75f2791`.

Source: task-2-report.md §History + §What was implemented (frigate-run render-once guard; run-1 clobber).

### D5 (EXECUTION, gate-discovered) — stale model-geometry SHM crashes every detect process on the geometry change

Frigate sizes the per-camera detector-input SHM to the model geometry and, on `FileExistsError`, attaches **without resizing** (`app.py:355`/`361`, `UntrackedSharedMemory(..., create=False)`). In the snap's private `/dev/shm` bind the segment persists across service restarts, so the 300×300→320×320 geometry change made every camera's detect process crash `buffer is too small for requested array`. `frigate/object_detection/base.py:391–395`:

```python
self.shm = UntrackedSharedMemory(name=self.name, create=False)
self.np_shm = np.ndarray(
    (1, model_config.height, model_config.width, 3),
    dtype=np.uint8,
    buffer=self.shm.buf,
)
```

(Upstream stale-attach bug; snap-specific persistence — it would hit any operator doing the documented Coral swap.) **Fix:** a **denylist** SHM clear at `frigate-run` start — delete everything except `psm_*` (svc-a) and `sem.*` (sibling daemons). The final review inventoried the siblings exhaustively: go2rtc, nginx, and certsync write nothing to this SHM. Recorded assumption: a future `psm_*`-named geometry segment would silently escape the clear.

Source: task-2-report.md finding #1 (crash, both camera pids, journal 20:23:07); final-fix-report.md Fix 2 (denylist + sibling inventory); base.py:391–395 (verbatim above).

### D6 (EXECUTION) — the looping testclip drives NO detector inference

The M3-era assumption that "the testclip's constant frame flow drives the detector" is **false**. Across gate runs the testclip kept `detection_fps` at `0.0` and `inference_speed` pinned at the exact `10.0` init default on **both** `ov` and `coral`. Mechanism — the motion calibrator never exits under constant clip motion, and only motion regions are ever sent to the detector. `frigate/motion/improved_motion.py`:

```python
# once the motion is less than 5% and the number of contours is < 4, assume its calibrated
if pct_motion < 0.05 and len(motion_boxes) <= 4:
    self.calibrating = False
```

The looping clip's constant motion keeps `pct_motion` above 5% forever, so calibration never completes and no region reaches the detector. Consequence: inference drift (and any detection event) **requires the live camera**. The drift MONEY check is therefore livecam-gated, with the hard coral-pid liveness assertion always on.

Source: task-2-report.md finding #3; improved_motion.py calibration-exit condition (verbatim above).

---

## Deviations

| Deviation | Reason | Reference |
|---|---|---|
| Detector arrangement changed from "Coral alongside OpenVINO" to **OpenVINO shipped default + Coral gate phase** | USER re-ruling after the pre-plan single-geometry discovery (D1): "alongside" is impossible on v0.17.2 (one model geometry for all detectors), and a Coral default would crash-loop hardware-less users. Phase-based attribution is strictly stronger than the original stats-only plan. | spec §2 (locked decision + rationale); D1 above |
| Task 2 scope amended: **`spike/bin/frigate-run` + snap rebuild** (plan said harness-only) | The gate-discovered render-every-start clobber (D4) could only be fixed in `frigate-run` (render-if-absent). The proposed config-override lever was rejected in favour of render-once (matches `validate-config`, upstream user-owned-config, and the accelerator doc). Snap rebuilt once; both fixes verified inside the squashfs before gating. | task-2-report.md §History; D4 above |
| The **final whole-branch review ran BEFORE this findings task** (not after) | Deliberate sequencing so the findings numbers come from **one** post-fix authoritative gate — avoiding the M4/M5 pattern where a late fix reran the gate and forced a findings-number refresh. The consolidated fix wave (`75f2791` + `62e8282`) landed first; this task ran the single authoritative gate on top of it. | dispatch (controller sequencing); review trail below |
| **TPU-marker journal poll** replaced the plan's one-shot capture | Gate run 3 proved the `EdgeTpuTfl` markers land ~2 s AFTER `/version` answers (API init and detector init run in parallel), so a one-shot capture races and misses `TPU found`. Replaced with a bounded (≤60 s) journal poll. This run: `Attempting to load TPU as usb` 21:53:26 → `TPU found` 21:53:29 (a 3 s gap — the poll caught it). | task-2-report.md finding #2; `coral-phase-journal.txt` timestamps |
| Coral phase carried over the M0/M3/M4/M5 harness postures unchanged | ALL prior-milestone assertions preserved; the coral phase inserts between the M3 rollback proofs and the denial scan (its denials captured); stick-absent → explicit whole-phase SKIPs keep the suite green. | tests/spike-smoke.sh coral phase (lines ~660–799) |

---

## Review trail

- **Per-task reviews — all Approved.** Task 1 (snap surface): zero findings. Task 3 (accelerator doc): approved after a one-line fix scoping the single-detector constraint to "Frigate v0.17.x" (commit `b3ff7a4`). Task 2 (harness phase + frigate-run): approved, zero Critical / zero Important.
- **Final whole-branch review** (`83f8752..25dc8fa`, against spec + plan): verdict **"With fixes"** — **0 Critical, 4 Important**. The consolidated fix wave landed as **`75f2791`** (trap hoist so `--skip-install` still registers the EXIT trap; backup-clobber guard so a leftover good-config backup is never overwritten by a coral-tainted `config.yml`; a `frigate healthy after restore` health check; SHM-denylist + render-once comment accuracy) and **`62e8282`** (accelerator-doc corrections: CPU acknowledged as the no-accelerator fallback with its own config-swap section, config-ownership section, PCIe snapd-custom-device wording).
- A scoped re-verdict on that fix wave was running in parallel; this findings task does not depend on it.

Result of this task's authoritative gate on top of the fix wave: `SPIKE SMOKE: ALL PASS`, 112 PASS / 0 FAIL / 5 SKIP, 366 denials 0 unexpected — a single run, no re-run needed.

---

## M7 unlock notes

| Item | Origin |
|---|---|
| **`snap set` detector selection (`ov` / `coral` / `cpu`) at install/runtime** — would remove the manual config swap entirely (harness swaps `config.yml` by hand today) | M6 D1 single-geometry constraint; the coral phase's manual transform |
| **Render-once upgrade-notes story**: `config.yml` is rendered at FIRST start only, so template updates shipped in a **new snap revision never reach an existing install's `config.yml`** — operators must delete + regenerate to pick them up. Needs an M7 upgrade-notes / migration story. | M6 D4 render-once fix (`ab34d76`) |
| **`--skip-install` runs do not re-render `config.yml`** — a livecam provisioned after first render is not armed until a full run (or `rm config.yml` + restart). Comment landed; M7 may want an explicit re-render flag. | M6 final-review Fix 1(d) (`75f2791`) |
| **NPU userspace productization** — still queued (advisory `CAP_SYS_ADMIN` denial at accel open observed this run; custom-device works on classic Ubuntu, not strict) | spec §4 (M6 out of scope); `npu-probe finding` in m6-final-run.txt |
| `psm_*`-named detector-geometry SHM would silently escape the denylist clear (D5) — revisit if a future Frigate names detector-input segments with a `psm_` prefix | M6 D5 SHM denylist |
| Coral PCIe / M.2 (`/dev/apex_0`) under strict — needs a snapd custom-device / Store declaration | spec §3.5; accelerator doc PCIe row |
| **RETIRED this milestone:** bird-model mutable-URL note (pinned to immutable commit `104342d2…`, D3) | M5 M7-backlog item, closed by M6 Task 1 |

Carried M7 items from prior milestones (ECDSA cert option, certsync configurability, `snap set` config surface for ports/TLS/livecam, logrotate, literal-safe URL renderer, version-stamped DB backups) remain open — see docs/m5-findings.md.

---

## Raw evidence index

**Provenance note:** `spike/results/` and `.superpowers/` are git-ignored. `git ls-files .superpowers/ spike/results/` returns empty — every file below is local-only, not tracked. `spike/results/m6-final-run.txt` is the authoritative source for all run numbers; task-report prose may describe earlier gate runs.

| File | Content |
|---|---|
| `spike/results/m6-final-run.txt` | Authoritative M6 gate — start `2026-07-07T21:48:16+02:00`: **SPIKE SMOKE: ALL PASS**, **112 PASS / 0 FAIL / 5 SKIP**, **366 denials 0 unexpected**. Carries the full coral-phase block, the 5 documented livecam SKIPs, and the M0 coral substrate PASSes. Local-only. |
| `spike/results/coral-phase-journal.txt` | The two `EdgeTpuTfl.__init__` markers from the frigate unit during the phase: `Attempting to load TPU as usb` (21:53:26) → `TPU found` (21:53:29), `frigate.frigate[459926]`. Local-only. |
| `spike/results/coral-phase-stats.json` | `/stats` on the coral config: `detectors.coral.pid = 460323`, `inference_speed = 10.0` (init default), `detection_start = 0.0` (no inference ran). Local-only. |
| `spike/results/coral-usb-before.txt` / `coral-usb-after.txt` | `lsusb` device state around the probe — `Bus 002 Device 006: ID 18d1:9302 Google Inc.` (post-firmware, initialized). Local-only. |
| `spike/results/denials.txt` | Full AppArmor denial log from this run (366 total, 0 unexpected). Local-only. |
| `spike/results/frigate-stats.json` / `livecam-stats.json` | Steady-state `/stats` (OpenVINO default). Local-only. |
| `spike/results/ss-tln.txt` | `ss -tlnp` — `:5000`/`:5001`/`:1984` loopback, `:8971` all-interfaces (carried from M5). Local-only. |
| `docs/accelerator-support.md` | User-facing support matrix + Coral USB / CPU config-swap setup + one-detector-type (v0.17.x) constraint + config-ownership + NVIDIA/PCIe decisions. Tracked. |
| `docs/superpowers/specs/2026-07-07-m6-coral-detector-design.md` | Amended design spec (§2 records the single-geometry discovery + USER re-ruling; §3 the inference-speed / marker / bird-pin discoveries). Tracked. |
| `.superpowers/sdd/task-1-report.md` | Task 1: snap surface — EdgeTPU model staging, bird-model re-pin, daemon USB plugs, squashfs hash verification. |
| `.superpowers/sdd/task-2-report.md` | Task 2: harness coral phase + frigate-run render-once + SHM-clear; the 4 gate-run triage table; findings #1–#3 (SHM, marker race, testclip-no-inference). |
| `.superpowers/sdd/task-3-report.md` | Task 3: accelerator-support doc; the v0.17.x scoping review fix. |
| `.superpowers/sdd/final-fix-report.md` | Final-review fix wave (`75f2791` + `62e8282`): trap hoist, backup-clobber guard, health check, SHM/render-once comments, accelerator-doc CPU/ownership/PCIe corrections. |
| `.superpowers/sdd/task-4-report.md` | This task: authoritative gate + findings. |
