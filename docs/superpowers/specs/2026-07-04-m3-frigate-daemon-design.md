# M3 Design Spec — Frigate daemon: detection on the iGPU

**Date:** 2026-07-04
**Status:** Approved design, pre-implementation
**Parent spec:** [`2026-07-02-frigate-snap-design.md`](2026-07-02-frigate-snap-design.md) (§4-M3)
**Evidence base:** [`docs/m2-findings.md`](../../m2-findings.md) (esp. strategic findings a–d), [`docs/m1-findings.md`](../../m1-findings.md), [`docs/spike-findings.md`](../../spike-findings.md)

## 1. Goal

Frigate runs as a **strict-confined snap daemon**: boots after go2rtc, ingests the synthetic camera, **detects real objects on the Intel iGPU via OpenVINO**, writes events to its database and recordings to disk, and answers its API — the parent roadmap's ⭐ milestone. Additionally M3 builds the **DB rollback machinery** (user decision) and hardens the harness with the Coral warm-up probe.

## 2. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| frigate-ai wheels | **Option 1: accept in core** (1.11 GB) | Zero divergence/patch burden; revisit slimming at M7 with real data (m2-findings four-option analysis) |
| Detection evidence | **Bundle a real-object clip** (CC0/public-domain, sha256-pinned, license documented) | COCO detectors correctly find nothing in testsrc2; real events with labels+scores are the definitive proof |
| Cache | **Keep `/tmp/cache` (RAM-backed private tmp)** | Upstream-faithful, proven at rc=0; benchmark under live streaming and record multi-camera headroom math |
| Config/DB | **Split + rollback machinery now**: config in `$SNAP_DATA/config`; DB at `$SNAP_COMMON/db/frigate.db` via `database.path`; `pre-refresh` sqlite-backup hook + startup downgrade-restore | No GB-scale refresh copies AND a real rollback story, built and tested in M3 (user decision after the rollback trade-off analysis) |
| shm | **`shared-memory: private` plug** on the frigate daemon | M2 finding (b): supersedes the retired shm-prefix patch; makes `psm_*` and `sem.*` legal with zero upstream divergence |
| NPU inference | **Deferred** (device access proven in M0-C3; userspace staging is its own later effort) | Keeps M3 focused on the GPU money test |

## 3. Components

### 3.1 `frigate` daemon
- App: `daemon: simple`, `restart-condition: on-failure`, `after: [go2rtc]`, `extensions: [gpu]`, `plugs: [network, network-bind, opengl, shm-private]` (where `shm-private` is the snap's `shared-memory` plug with `private: true`, as proven in M2). Additional plugs only if denial-forced (triage discipline).
- Wrapper `bin/frigate-run`: sources `lib-wait.sh`, gates on go2rtc `:1984` (60 s; the measured wait is logged to stdout for journald — same readiness-evidence pattern as svc-a), exports the proven env contract (`FRIGATE_CONFIG_DIR=$SNAP_DATA/config`, `FRIGATE_BASE_DIR=$SNAP_COMMON/media/frigate`, `FRIGATE_CACHE_DIR=/tmp/cache`, `DEFAULT_FFMPEG_VERSION=7.0`, `INCLUDED_FFMPEG_VERSIONS=8.0:7.0:5.0`, `CONFIG_FILE=$SNAP_DATA/config/config.yml`), ensures dirs (incl. `$SNAP_COMMON/db`), renders the config template on first run, **writes the version sidecar** (§3.4), then `cd /opt/frigate && exec python3.11 -u -m frigate`.
- MESA_LIB `LD_LIBRARY_PATH` guard as in existing wrappers (gpu extension cleanup strips libGL).

### 3.2 Detector: OpenVINO on GPU + model staging
- Frigate config: `detectors: { ov: { type: openvino, device: GPU } }`; model = upstream's default OpenVINO SSDLite MobileNetV2.
- **Model provisioning is a plan-time discovery**: mirror exactly how v0.17.2 produces `/openvino-model` (Dockerfile `ov-converter` stage / `build_ov_model.py`) as a snap part — build-time conversion (openvino tooling in the build env) or staging of the converted artifacts, whichever upstream's mechanism dictates; sha256/tag-pinned inputs; labelmap staged.
- CPU tflite detector remains a documented config fallback. Note: the spike staged only the Coral *test* model — Frigate's default CPU detection model is NOT yet in the snap; staging it (upstream's default tflite + labelmap, pinned) is part of the model task so the fallback is real, not theoretical.

### 3.3 Real-object test clip + camera config
- Part `test-clip`: a short (≤ ~60 s) CC0/public-domain clip containing people and/or vehicles; sha256-pinned URL; `LICENSE-testclip` note staged alongside; stored at `$SNAP/media-samples/testclip.mp4`.
- go2rtc config template gains stream `testclip: exec:<ffmpeg 7.0> -re -stream_loop -1 -i __SNAP__/media-samples/testclip.mp4 -c:v libx264 ... -f rtsp {output}` (re-encode keeps go2rtc/consumer behavior uniform; exact flags at plan time). The existing `test` (testsrc2) stream and all its assertions remain.
- Frigate camera `testclip`: `rtsp://127.0.0.1:8554/testclip`, roles `[detect, record]`, detect ~5 fps at clip resolution; `record` enabled with short retention; `objects.track: [person, car]` per clip content.

### 3.4 DB split + rollback machinery
- Config: `database: { path: $SNAP_COMMON/db/frigate.db }` (rendered into the config template — the template gains a `__SNAP_COMMON__` substitution).
- **`pre-refresh` hook** (`snap/hooks/pre-refresh` in the snapcraft project): if the DB exists, take a consistent snapshot via SQLite's backup API (the staged `python3.11 -c "import sqlite3; ..."`, source+dest paths quoted) to `$SNAP_COMMON/db/backups/frigate-pre-<revision>.db`; retention: keep newest 2, delete older; log to stdout (journald captures hook output).
- **Startup downgrade-restore** in `bin/frigate-run`: a version sidecar `$SNAP_COMMON/db/.last-writer` records `<frigate-version> <snap-revision>` on every daemon start. If the sidecar's frigate-version is **newer** than the current code's version (downgrade detected — e.g. after `snap revert`), restore the newest compatible backup (log loudly, move the incompatible DB aside as `frigate.db.incompatible-<ts>`, never delete), then continue boot.
- **Harness proof of both paths**: (1) reinstall-over-install (`snap install --dangerous` on top of the installed snap = refresh → hook fires) → backup file exists; (2) forge the sidecar with a higher version → restart frigate → restore path fires (assert via log line + DB file swap evidence). Restore-path test runs BEFORE the detection assertions and leaves a clean state.

### 3.5 Money-test verification (harness, above the denial-scan marker)
1. `frigate` service active; `curl http://127.0.0.1:5001/api/version` answers (strict snaps share the host netns — host curl reaches the loopback bind).
2. **Detection**: within a bounded window (~90 s), events with expected labels appear — **primary assertion via the events API** (`/api/events?labels=person,car&limit=...`; label ∈ {person, car}, score > threshold), with a direct sqlite read of `$SNAP_COMMON/db/frigate.db` captured as corroborating evidence (also proves the split DB path is live); evidence JSON saved.
3. **GPU evidence**: `/api/stats` shows the openvino detector with plausible inference speed; captured to evidence. (`intel_gpu_top` remains out of scope — CAP_PERFMON.)
4. **Recordings**: files appear under `$SNAP_COMMON/media/frigate/recordings/<date>/...` (bounded wait; segment cadence per config).
5. **Cache benchmark note**: capture `/tmp/cache` peak usage during the run (evidence for the multi-camera headroom math in findings).
6. Rollback machinery assertions (§3.4).
7. **Coral warm-up probe**: before the coral assertions, run the delegate-load once discarding the result (tolerating the documented long-idle first-touch flake), then assert on the second run.
8. All M0/M1/M2 assertions preserved; new denials triaged narrow+labeled per policy (expected candidates: frigate's /sys reads for stats, ZMQ in private tmp — likely already covered).

### 3.6 Findings: `docs/m3-findings.md`
M0–M2 style: verdict table (daemon boot, detection-on-GPU, events, recordings, API, rollback machinery, cache benchmark), decisions unlocked for M4 (nginx fronting the now-live API/UI endpoints), deviations, raw evidence.

## 4. Out of scope (M3)

nginx/web UI (M4), TLS/certsync (M5), NPU inference userspace, audio detection (YAMNet), MQTT/HomeAssistant, semantic search runtime use (wheels present, feature unconfigured), Coral as the primary detector (remains verified via probes; detector switch is config-level), birdseye, go2rtc config generation via `create_config.py` (static template still; revisit at M4 when nginx proxies go2rtc).

## 5. Risks

1. **Model provisioning mechanics** unknown until discovery (converter tooling in build env vs prebuilt artifacts) — the one genuinely open build question.
2. **First-boot denial surprises** from the full pipeline (frame pipeline, ZMQ, stats /sys reads) — triage discipline; `shared-memory: private` should absorb the shm class entirely.
3. **OpenVINO GPU first-inference compile latency** — model_cache in `$SNAP_DATA/config/model_cache` absorbs it after first boot; the detection window (~90 s) must tolerate first-boot compile.
4. **Detection quality on a looped compressed clip** — pick a clip with clear, large subjects; threshold assertions lenient (score > ~0.5) since the goal is pipeline proof, not benchmark.
5. **Frigate exit semantics**: upstream halts the whole s6 tree when frigate dies; we intentionally use `restart-condition: on-failure` instead — divergence documented in findings (systemd semantics fit snaps better).
6. **pre-refresh hook constraints**: hooks run with the snap stopping — ensure the backup completes within snapd's hook timeout on a small dev DB; note timeout behavior for large DBs as an M7 hardening item.
