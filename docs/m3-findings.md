# M3 Findings — Frigate daemon, detection, rollback

**Date:** 2026-07-05  **Snap:** frigate 0.0.1-spike (core26, strict)  **Frigate:** v0.17.2-3d4dd3a (patched)  **Branch:** m3-frigate-daemon

| # | Question | Verdict | Evidence |
|---|----------|---------|----------|
| M3-1 | Frigate daemon boots strict-confined, API answers? | YES — `snap.frigate.frigate` service active; `GET /version` (127.0.0.1:5001) answered with `"0.17.2-3d4dd3a"`; split DB live at `$SNAP_COMMON/db/frigate.db`; sidecar `.last-writer` written at service start. Note: v0.17.2 serves `/version`, `/events`, `/stats` WITHOUT an `/api/` prefix (404 otherwise). Curl requires `-H "Remote-User: admin" -H "Remote-Role: admin"` headers; nginx normally injects these in production. | spike/results/frigate-version.txt (`0.17.2-3d4dd3a`); m3-final-run.txt (`PASS: frigate service active`, `PASS: frigate API answers`, `PASS: db at split path`, `PASS: sidecar written`); task-3-report.md |
| M3-2 | Real object detection on iGPU (OpenVINO), inference speed? | YES — 5 person events detected on the `testclip` stream (top_scores **0.947–0.984**, final run, spike/results/frigate-events.json; earlier Task-5 fix-round run observed a wider 0.78–0.97 spread, prior-run observation, file since overwritten); `detectors.ov.inference_speed` = **5.86 ms** (final run — both spike/results/frigate-stats.json and m3-final-run.txt agree; 5.74 ms noted in an intermediate run, stats file since overwritten); `detection_fps` = **38.7** (final run, spike/results/frigate-stats.json 2026-07-05 19:11:28; earlier Task-5 fix-round run observed 43.4 — run-to-run variance on a looping clip); `ffmpeg_pid` nonzero (pipeline-alive assertion confirmed). | spike/results/frigate-events.json (5 events, all camera=testclip label=person; final-run top_scores 0.947–0.984); spike/results/frigate-stats.json (`inference_speed`:5.86 ms, `detection_fps`:38.7, `ffmpeg_pid` > 0 — all final run 2026-07-05 19:11:28); m3-final-run.txt (`PASS: MONEY TEST`, `gpu finding: ov inference_speed=5.86ms`) |
| M3-3 | Detection events corroborated in split DB? | YES — 5 person events in the `event` table of `$SNAP_COMMON/db/frigate.db`, IDs matching the API response. | spike/results/db-events.txt (5 rows: id timestamp label camera); m3-final-run.txt (`PASS: detection: corroborated in split db`) |
| M3-4 | Recordings written to disk under SNAP_COMMON? | YES — `.mp4` segments present under `$SNAP_COMMON/media/frigate/recordings/` during live run; harness asserts file presence. | m3-final-run.txt (`PASS: recordings: files under SNAP_COMMON`) |
| M3-5 | Rollback machinery — both proofs green? | YES — same-version proofs; cross-version compat not exercised, see §Rollback scope below. Note: hook stdout only reaches journald within the hook's execution scope — `hook.log` exists precisely because journald retention for hook scopes is not a durable audit trail; the file is the durable record, journald is transient. | m3-final-run.txt (`PASS: rollback: pre-refresh backup created`, `PASS: rollback: hook logged`, `PASS: rollback: downgrade detected + restored`, `PASS: rollback: incompatible db preserved`, `PASS: rollback: frigate healthy after restore`); task-4-report.md (verbatim journal lines) |
| M3-6 | Cache peak and multi-camera headroom? | Two measurements of Frigate cache-dir usage (FRIGATE_CACHE_DIR — frame/segment staging cache; recording segments staged here before move to disk) at `/tmp/snap-private-tmp/snap.frigate/tmp/cache`, single camera: **8596 KiB** (final run, spike/results/cache-peak.txt 2026-07-05 19:11:28) and **10576 KiB** (Task-5 fix-round run, task-5-report.md §Cache). Run-to-run variance is expected: segment-staging timing varies with when the sampler catches the cache between segment moves. The spec's multi-camera headroom math applies to this staging cache; per-camera frame memory sits in `/dev/shm` (private tmpfs, sized to 50% of physical RAM by kernel default). Note: OpenVINO's model/kernel cache lives under the config dir (`model_cache`), which was NOT what was measured here. | spike/results/cache-peak.txt (`8596 KiB peak`, final run); task-5-report.md §Cache (`10576 KiB`, Task-5 fix-round run); m2-findings.md §(b) (shared-memory private: true; /dev/shm sizing) |

---

## Rollback scope (M3-5)

**Proven**
- Pre-refresh hook fires on `snap refresh` and writes a consistent sqlite backup to `$SNAP_COMMON/db/backups/frigate-pre-x1.db`; `hook.log` line appended.
- Downgrade detection via forged sidecar: `sort -V` comparison verified across 4 version-pair scenarios.
- Restore path executes with its guards and frigate boots healthy after a same-version restore (Proof 2 restored a backup created by the same 0.17.2 code).

**Not exercised**
- Restoring an older-schema DB into newer code (cross-version schema compatibility). The backup restored in Proof 2 was created by the same 0.17.2 code, so schema compatibility was never at stake.

**Known limitations (schema-blind, revision-keyed selection/retention)**
- `snap install --dangerous <older>.snap` fires pre-refresh on the NEWER revision first, so the newest backup may carry a newer schema — restoring it into the older code would reinstate an incompatible DB.
- Keep-newest-2 retention can prune the only older-schema backup after two schema-advancing refreshes.
- A failed restore under `restart: on-failure` means crash-loop (availability loss; no data loss — the DB is preserved as `.incompatible-<ts>`).

The PRIMARY documented scenario (`snap revert`) is unaffected: revert does not fire pre-refresh on the reverted-to revision.

---

## THE BLOCKER STORY (end-to-end assertion is the only gate that catches this)

Tasks 1–4 all returned green states. The full pipeline — go2rtc serving RTSP, frigate daemon active, API answering, detector process running — was declared operational after Task 3. Yet detection NEVER fired during those tasks. The money test in Task 5 surfaced the failure immediately.

**Root cause:** Frigate's source code (`frigate/video.py:91`) hardcodes the ffmpeg binary path as `/usr/lib/ffmpeg/<version>/bin/ffmpeg`. Inside the snap's mount namespace, `/usr` is provided by the core26 base snap (`/dev/loop18`), which does NOT contain `/usr/lib/ffmpeg`. The snap's own ffmpeg trees sit at `$SNAP/usr/lib/ffmpeg/…`. Without a layout entry binding `$SNAP/usr/lib/ffmpeg` into `/usr/lib/ffmpeg`, every `subprocess.Popen` call in the capture process raised `FileNotFoundError: [Errno 2] No such file or directory: '/usr/lib/ffmpeg/7.0/bin/ffmpeg'`.

Evidence from journal:
```
frigate.frigate[1916660]: FileNotFoundError: [Errno 2] No such file or directory: '/usr/lib/ffmpeg/7.0/bin/ffmpeg'
frigate.frigate[1916660]: File "/opt/frigate/frigate/video.py", line 91, in start_or_restart_ffmpeg
```

The result: `ffmpeg_pid=0`, `camera_fps=0`, `detection_fps=0` in all Task 1–4 runs. go2rtc was unaffected because its go2rtc-run wrapper uses `$SNAP`-absolute paths.

**Fix:** One layout line added to `spike/snap/snapcraft.yaml`:
```yaml
layout:
  /usr/lib/ffmpeg:
    bind: $SNAP/usr/lib/ffmpeg
```

After rebuild (commit 3f79937) the ffmpeg path resolved, `ffmpeg_pid` became nonzero, and the money test went GREEN on the first post-fix run.

**Lesson:** Only an end-to-end assertion (frames processed, objects detected, events in DB) can catch this class of failure. Unit-level assertions on service activity, API liveness, and detector process existence all pass while the pipeline is silently broken. The harness architecture (money test checks both `inference_speed != null` AND `ffmpeg_pid > 0`) now codifies this lesson.

---

## THE PATCH ADJUDICATION (neutral record)

The looping test clip (`testclip.mp4`, pedestrian street, constant motion) exposed a secondary blocker after the ffmpeg layout fix: Frigate's `ImprovedMotionDetector` calibration exit condition (`pct_motion < 5%` AND `len(motion_boxes) <= 4`) is NEVER satisfied with a clip that has uninterrupted motion from frame 1. Every frame has constant motion, so `pct_motion` stays well above 5% indefinitely, `calibrating` remains `True`, and no motion boxes are added to detection regions. Result: `detection_fps` = 0 even with ffmpeg running.

**Config route attempted first (USER adjudication):** `motion: enabled: false` on the test camera was the obvious fix. Frigate v0.17.2's pydantic validator hard-rejects this combination:

```
Value error, Camera testclip has motion detection disabled and object detection enabled
but object detection requires motion detection. [type=value_error, ...]
```

Frigate refuses to start. The config route is not viable.

**Registered fallback — patch 0002:** `spike/patches/0002-motion-calibration-exit.patch` forces `ImprovedMotionDetector` calibration exit after `frame_counter >= 60` (12 s at 5 fps). Applied via `patch -p1` in the snapcraft build.

Production impact: **no-op** for any camera that ever sees a quiet interval (calibration exits via `pct_motion < 5%` first, typically within seconds). Only a camera with unbroken constant motion from the very first frame would be affected, and then only experiences earlier exit (after 12 s instead of never). The `lightning_threshold` guard (80% motion) still protects against scene-change storms.

The snap now carries **two** downstream patches. The `docs/patches.md` register table is the authoritative record. Patch 0002 is an upstreaming candidate as a configurable option (`motion.calibration_max_frames` field on `MotionConfig`), not as a hard-coded value.

---

## Denial arms added in M3

All arms below are in `tests/spike-smoke.sh`'s expected-denial filter. Evidence: `spike/results/denials.txt` (final run) and task reports as cited.

| Arm | Profile | Operation | Mechanism | Evidence |
|---|---|---|---|---|
| `mount-observe` plug denial-forced | `snap.frigate.frigate` | `open` on `/proc/<pid>/mounts` (psutil `process_iter`) | `mount-observe` interface denied by confinement; psutil falls back gracefully; service continues | task-3-report.md; denials.txt (open /proc/self/mounts) |
| `cgroup reads` | `snap.frigate.frigate` | `open` on `/sys/fs/cgroup/…/cpu.max` and `/sys/fs/cgroup/cgroup.controllers` | Frigate reads cgroup CPU limits at startup; EACCES tolerated, no runtime impact | task-3-report.md; denials.txt (`cgroup.controllers`, `cpu.max` per-slice) |
| `ptrace frigate.recordi` | `snap.frigate.frigate` | `ptrace read` + `open /proc/<pid>/cmdline`, `peer=unconfined` | `psutil.process_iter()` in the recording manager scans all PIDs on the host; unconfined processes are an out-of-profile peer — denied, non-blocking | task-3-report.md (reviewer fix: comm="frigate\.recordi" pinned); denials.txt lines 14–15, 17–18 |
| `ptrace python3.11` (main process) | `snap.frigate.frigate` | `ptrace read`, `peer=unconfined` | Same psutil mechanism from the main Frigate process at startup (read-mask on unconfined peers) | task-4-report.md Fix round 2; journal 2026-07-05 16:47:51 verbatim: `apparmor="DENIED" operation="ptrace" class="ptrace" profile="snap.frigate.frigate" pid=1895566 comm="python3.11" requested_mask="read" denied_mask="read" peer="unconfined"` |
| Dead DMI arms repaired | `snap.frigate.gpu-probe`, `snap.frigate.frigate` | `open /sys/devices/virtual/dmi/id/product_*` | Two arms had trailing `"` and could never match actual paths (`product_name`, `product_version`, etc.). Trailing quote removed in task-4 fix wave (dfed0c4); arms now match the OpenVINO GPU plugin's DMI probes | task-4-report.md Fix round 1; denials.txt (product_name/version/serial/uuid) |

---

## Model provisioning mechanism

### What upstream does

From `docker/main/Dockerfile` v0.17.2:

- **OpenVINO conversion** (`ov-converter` stage): downloads the TensorFlow `ssdlite_mobilenet_v2_coco_2018_05_09.tar.gz` tarball and runs `build_ov_model.py` (uses `openvino.tools.mo.convert_model` with `compress_to_fp16=True`). Produces `ssdlite_mobilenet_v2.xml` + `.bin` (FP16 IR format).
- **CPU TFLite** (`models` stage): `wget` the `ssdlite_mobiledet_coco_qat_postprocess.tflite` from the `google-coral/test_data` `release-frogfish` tag.
- **Labelmaps**: `labelmap.txt` copied from source; `coco_91cl_bkgr.txt` fetched from open_model_zoo and patched (`sed -i 's/truck/car/g'`).
- The `models` stage places files at image root; `COPY --from=models /rootfs/ /` installs them.

### What we mirror (prebuilt route)

`openvino.tools.mo` was removed in openvino 2024.0 (replaced by `ovc`). The snap stages openvino 2025.3.0; `mo.convert_model` is absent. Build-time conversion is therefore impractical without reverting to an older openvino.

**Route taken:** prebuilt IR binaries committed directly to `spike/models-prebuilt/` alongside the other staged assets. The `models-prebuilt/README.md` documents the conversion procedure (using a Docker image that pins the older openvino converter), SHA-256 hashes, and a heredoc that is mechanically reproducible with `<<EOF` (no `<<'EOF'` quoting that would kill variable expansion).

The `test-clip` snap part verifies the SHA-256 of the committed MP4 at build time (`override-build`), following the same pin/verify pattern.

---

## Test-clip provenance

| Field | Value |
|---|---|
| Source URL | `https://upload.wikimedia.org/wikipedia/commons/a/ae/Video_Codec_Test_pedestrian_area_1080p25.y4m.webm` |
| Wikimedia Commons page | `https://commons.wikimedia.org/wiki/File:Video_Codec_Test_pedestrian_area_1080p25.y4m.webm` |
| License | Creative Commons CC0 1.0 Universal Public Domain Dedication |
| Recorded | 2013-02-19, Munich Neuhauser Strasse pedestrian zone |
| Original uploader | Taurus Media Technik via Xiph.org Video Codec Test Suite |
| Source WebM SHA-256 | `bfadaa62cccb42db875d50bb842aa0964fbf72040432e4097c1df59e043e0c26` |
| Committed MP4 (spike/media-samples/testclip.mp4) | h264 / 1920×1080 / 15 s / 7.0 MB; SHA-256 `38df1538cd58333a55111579367b6150df62c2ae521969dd1c1bb5631a45c887` |
| Adaptation | `ffmpeg -c:v libx264 -preset veryfast -crf 23 -an -movflags +faststart` (CDN-429 mitigation: file committed in-repo) |

Content: daytime pedestrian scene, multiple persons in frame throughout, well-suited for SSDLite person detection (subjects fill a meaningful fraction of 1920×1080 throughout the 15-second loop).

---

## Decisions unlocked for M4

- **nginx fronts :5001/:5002/:8082 + go2rtc :1984.** Frigate's API at :5001 requires `Remote-User` and `Remote-Role` headers on every non-exempt request. In production, nginx injects these from the upstream auth provider. The M3 spike harness emulates this with explicit curl headers (`-H "Remote-User: admin" -H "Remote-Role: admin"`). M4 must wire nginx to the internal Frigate socket and configure header injection; the emulation pattern is the reference.

- **Auth-header discovery teaches the proxy design.** `/events` and `/stats` are `EXEMPT_PATHS` (only `Remote-User` required); all other paths require `Remote-Role: admin`. nginx's proxy_set_header directives must cover both; the header-injection source of truth is Frigate's `auth.py` `allow_any_authenticated()` and `require_admin_by_default()` decorators.

- **Readiness pattern reuse.** The `lib-wait.sh` `wait_for_url` pattern (M1) was reused in M3: `frigate-run` polls `http://127.0.0.1:1984/api/streams` before exec'ing frigate, ensuring go2rtc is up before the daemon tries to consume RTSP. M4 can reuse the same pattern to gate the nginx config-write step on Frigate's `/version` endpoint returning 200.

- **`/usr/lib/ffmpeg` layout now serves all consumers.** The single layout entry added in M3 (`/usr/lib/ffmpeg: bind: $SNAP/usr/lib/ffmpeg`) satisfies both Frigate's hardcoded path and any other snap app that expects ffmpeg at the system location. go2rtc was already using `$SNAP`-absolute paths and is unaffected.

- **No additional confinement plugs required by the daemon** beyond what is already declared. The denial arms added in M3 are all labeled non-blocking (mount-observe class, cgroup reads, ptrace read from psutil). M4 nginx fronting adds only `network-bind` for port 80/443 and `network` for upstream proxying; the iGPU and Coral paths are already proven.

### M7 hardening items (from final review)

- Version-stamp DB backups (`frigate-pre-<version>-<rev>.db`) and restore newest-COMPATIBLE (version <= current code), replacing schema-blind revision selection; extend harness with a true cross-version restore proof.
- `pre-refresh` runs under `set -e`: a locked/failed/slow backup fails the hook and blocks the refresh (fail-closed). Decide intent + bound for large DBs (spec Risk 6).
- Model IR provenance: committed OpenVINO blobs rest on documented-procedure trust (openvino-dev 2024.6.0 conversion); revisit reproducible conversion.
- Build hygiene: go2rtc/libedgetpu parts use `/tmp` temp paths (→ `$CRAFT_PART_BUILD`); coral test model fetched from mutable master URL (sha256-pinned).
- `frigate-run`'s MESA_LIB block is a dead no-op (wrong path, superseded by the gpu extension command-chain) — delete or fix.
- Reconcile detect width/height (1280x720) with the actual 1920x1080 testclip stream, or add an explicit go2rtc scale; fix the misleading downscale comment.
- Document the CPU tflite fallback as a commented detector block in the config template (spec §3.2 "documented config fallback").

---

## Deviations

| Deviation | Reason | M-plan reference |
|---|---|---|
| `restart: on-failure` instead of halt-on-exit | Upstream Frigate Docker container relies on the orchestrator for restarts; the snap app uses `restart: on-failure` so snapd auto-restarts on crash without operator intervention. This is the correct production semantic for a snap daemon. | Global Constraints deviation noted in progress.md M3 section |
| Two carried patches instead of one | 0002-motion-calibration-exit was added during M3 after the config route (`motion: enabled: false`) was empirically disproven by Frigate v0.17.2's pydantic validator. User adjudication approved the patch as a registered fallback after ruling the config route first. | docs/patches.md register; task-5-report.md Fix round 2 |
| shm-prefix patch abandoned | M3 plan called for patching `SharedMemoryFrameManager` with a `snap.*` prefix. M2 Task 5 found that glibc `sem_open(O_CREAT)` creates a random tempfile (`sem.XXXXXX`) before the atomic rename — no prefix can match this step. The fix is `shared-memory: private: true` (snapd interface), which mounts a private tmpfs over `/dev/shm` for the entire snap; no source patch needed. | docs/m2-findings.md §(b) |
| Task-4 fixer stall at build | Task-4 fixer stalled mid-response at the rebuild step (watchdog 600 s). Resumed with foreground-only one-step-per-call instructions. Lesson: long-running `snapcraft pack` (10–20 min) must be run with explicit foreground `Bash` calls rather than backgrounded monitor-armed sleeps. | progress.md M3 section (`Task-4 fixer STALLED…Resumed`) |
| Evidence-lifecycle lessons | Three separate cases where harness runs overwrote evidence captured in earlier runs (Task 4 hook.log, coral before/after files). All three were adjudicated by the controller against journal lines and first-run reports. The pattern: evidence files written per-run are inherently one-shot; the harness must either archive-on-capture or document which run the file represents. | progress.md M3/M2/M0 coral and hook notes |

---

## Raw evidence index

| File | Content |
|---|---|
| `spike/results/m3-final-run.txt` | Final M3 harness run (2026-07-05): ALL PASS, 272 denials, 0 unexpected (not tracked (local-only per m1/m2 convention; briefly committed in dd1da7c, untracked in 53ee754)) |
| `spike/results/frigate-events.json` | 5 person events from `/events` API: camera=testclip, top_scores 0.947–0.984 (final run; earlier fix-round run observed 0.78–0.97, file since overwritten) |
| `spike/results/frigate-stats.json` | Stats from `/stats` API: inference_speed, detection_fps, ffmpeg_pid (nonzero = pipeline alive) |
| `spike/results/frigate-version.txt` | `/version` response: `0.17.2-3d4dd3a` |
| `spike/results/db-events.txt` | 5 rows from `event` table of split SQLite DB (id, timestamp, label, camera) |
| `spike/results/cache-peak.txt` | Frigate cache-dir peak (FRIGATE_CACHE_DIR): `8596 KiB` at `/tmp/snap-private-tmp/snap.frigate/tmp/cache` |
| `spike/results/denials.txt` | Full AppArmor denial log from final run (272 entries, all allowlisted) |
| `spike/results/m2-final-run.txt` | M2 final run (reference: all 61 checks, Coral present) |
| `spike/results/m1-final-run.txt` | M1 final run (reference: all M1 checks, Coral absent) |
| `spike/results/vaapi-decode.txt` | VAAPI hw decode proof: `vaapi(progressive)`, `frame= 30 fps= 27`, `rc=0` |
| `docs/patches.md` | Carried patch register: 0001 env-driven paths + 0002 motion-calibration-exit |
