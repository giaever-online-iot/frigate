# Carried patches (downstream deviations from upstream Frigate)

| Patch | Introduced | Purpose | Rebase notes |
|---|---|---|---|
| `spike/patches/0001-env-driven-paths.patch` | M2 (v0.17.2) | Make `frigate/const.py` base paths env-overridable (`FRIGATE_CONFIG_DIR`/`FRIGATE_BASE_DIR`/`FRIGATE_CACHE_DIR`; defaults unchanged ⇒ upstream no-op). Required because snapd layouts cannot target `/config` (root-level) or `/media/*` (denied allow-list entry) — see docs/m2-findings.md. | Re-diff against each new tag; constants may move/rename. Upstreaming candidate: yes — a small, defaults-preserving env override is upstreamable; consider a PR after M3 proves it in production shape. |
The shm-prefix patch once planned for M3 was never needed: resolved in M2 via the shared-memory (private: true) interface — see docs/m2-findings.md strategic finding (b).

## Rejected patch: motion calibration exit (M3, removed by user ruling 2026-07-05)

A patch forcing `ImprovedMotionDetector` calibration exit after 60 frames was briefly carried
(and a config alternative trialed) to make the detection money test green with the looping
pedestrian test clip. Both routes are recorded here so they are not re-litigated:

- **Why anything was needed at all**: stock calibration exits only when `pct_motion < 5%` and
  `len(motion_boxes) <= 4`. The looping clip has constant motion in every frame, so
  `calibrating` stays `True` forever, motion boxes never become detection regions, and
  `detection_fps` stays 0. Real cameras have natural quiet intervals; the official Docker
  image needs no equivalent patch because it targets real cameras.
- **Config route (`motion.enabled: false`) is a dead end**: v0.17.2 hard-rejects it with a
  pydantic ValidationError when `detect.enabled: true` on the same camera ("object detection
  requires motion detection"). Frigate refuses to start.
- **v0.17.2 has no config knob** for max calibration duration.
- **Ruling**: no downstream behavior patches; run stock Frigate code. The detection money test
  was briefly postponed pending live cameras, then **re-armed and GREEN on stock code**
  (2026-07-05 evening, live indoor camera: person score 0.729, inference 7.08 ms iGPU) —
  validating that the blocker was the synthetic clip, never the stock code. The harness gates
  the live checks on `$SNAP_COMMON/livecam-url` being provisioned + the stream answering
  ffprobe at harness start; unprovisioned/unreachable => explicit SKIP, suite stays green
  (tests/spike-smoke.sh).
- The trial patch proved the rest of the pipeline end-to-end on 2026-07-05: 5 person events
  (scores 0.78–0.97), inference_speed=5.82 ms (iGPU OpenVINO), ffmpeg_pid nonzero,
  detection_fps=43.4, recordings on disk, 0 unexpected denials — evidence preserved in
  `.superpowers/sdd/task-5-report.md` (Fix rounds 1–2). The detection pipeline itself is not
  in doubt; only the synthetic clip's inability to exit stock calibration is.

## Upstream-recipe build patches (nginx/vod)

These patches are applied to `nginx-vod-module 1.31` during the nginx snap part build (M4
Task 1). They are NOT downstream divergences from Frigate — they are carried verbatim from
Frigate's own Docker build recipe (`docker/main/build_nginx.sh` @ v0.17.2), expressed as
committed patch files for determinism (upstream uses inline `sed` and a heredoc `patch`).

| Patch file | Source in upstream recipe | Purpose |
|---|---|---|
| `spike/patches/nginx/0001-vod-max-clips-1080.patch` | `sed -i 's/MAX_CLIPS (128)/MAX_CLIPS (1080)/g' vod/media_set.h` in `build_nginx.sh` | Raise the per-playlist clip cap from 128 to 1080 to support longer HLS recordings. |
| `spike/patches/nginx/0002-vod-rbsp-trailing-bits.patch` | heredoc `patch -p1` in `build_nginx.sh` (references kaltura/nginx-vod-module#4572) | Return `TRUE` early in `avc_hevc_parser_rbsp_trailing_bits` to tolerate non-conforming RBSP trailing bits in H.264/H.265 streams (Frigate issue #4572). |
| `spike/patches/nginx/0003-vod-gcc15-exit-process-prototype.patch` | **OUR portability patch — not in upstream recipe** | Fix `ngx_http_vod_exit_process` K&R empty-param declaration and definition: GCC 15 (core26) makes the mismatch with the struct's `void (*)(ngx_cycle_t *)` slot a hard error. Trip-wire: patch will fail to apply if upstream vod ever fixes the prototype, surfacing the redundancy immediately at build time — drop when that happens. |

Rebase: re-apply against the nginx-vod-module version pinned in snapcraft.yaml; upstream
Frigate's `build_nginx.sh` is the authority — check it on each Frigate tag bump.
Patch 0003 is OUR portability fix (not from upstream recipe); drop it if/when upstream
nginx-vod-module fixes the prototype itself.
