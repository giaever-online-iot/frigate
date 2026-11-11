# M8 Findings — Solid: lean artifact, nvr-safe gate, /logs tee-parity, semantic search

**Date:** 2026-11-11  **Snap:** `frigate` 0.17.2 (core26, strict, amd64)  **Frigate:** v0.17.2  **Milestone HEAD:** `a39bfb0` (main; PR #4 merge, 2026-07-15T23:10Z)  **Store state:** `latest/edge` = **rev 5** (991 MB, 2026-07-15), `latest/beta` = **rev 3** (1.14 GB, 2026-07-11; **not promoted** in M8), visibility **private** `[LIVE: snap info frigate; snap list frigate --all, 2026-11-11]`

M8 made the shipped snap leaner and more complete, and gave the production NVR a gate mode that does not mutate it. The lean artifact went from **1,140,936,704 B** (M7 remote artifact) to **990,572,544 B** (Store rev 4, the parity-gated artifact), **−150,364,160 B (−13.2 %)**. Semantic search works (R4). The M0 `svc-a/b/c` daemons are gone. `/logs` shows real frigate and go2rtc output. The hot-add `KeyError` is confirmed to be an upstream bug. The **gate half** of the exit criterion is MET: the Launchpad-built rev 4 passed the full VM gate (**145 PASS / 0 FAIL / 18 SKIP / 2 RETIRED, 564 denials / 0 unexpected**). The **field-soak half is OPEN**. No soak T0, no window and no window-end result was ever recorded. The August window's journal has been rotated away. Today the cameras are unreachable from the host, so "detections flowing on both cameras" cannot be measured (§Soak record). The verdict for item 10 below is **PROPOSED**; the user decides it.

**Evidence classes.** Every number below names its source. Each source was opened while writing this document.

- **`[TRANSCRIPT]`**: grep-verified against an on-disk gate transcript. Counts are **recounted** from the transcript (`grep -c '^PASS'`, `'^FAIL'`, `'^SKIP'`, `'^RETIRED'`), not copied from a report.
- **`[REPORT]`**: a figure quoted in a task/fix report (`.superpowers/sdd/m8/*.md`) or the controller ledger (`.superpowers/sdd/progress.md`). Those gate runs have no transcript on disk, so their counts could **not** be recounted.
- **`[STORE/CI]`**: `git`, `gh run list`, `gh pr list` run while writing this document.
- **`[LIVE]`**: read-only commands on the production host, 2026-11-11 (`snap info`, `systemctl show`, `journalctl`, loopback API GETs, `ls`). Nothing was restarted, written or reconfigured.

---

## Verdict table

Spec §4 verification items 1–10 (`docs/superpowers/specs/2026-07-12-m8-solid-design.md`), plus the §1 exit criterion.

| # | Criterion (spec §4) | Verdict | Evidence |
|---|---|---|---|
| 1 | **R4:** semantic search on → sqlite-vec loads, no `enable_load_extension` error; backup/restore proofs re-run green | **MET** | Remote rev-4 gate: `PASS: import sqlite_vec`, `vec0 … vec_version=v0.1.3 (loaded from /usr/local/lib/vec0)`, `PASS: m8: semantic search up (no sqlite-vec load error)` `[TRANSCRIPT: m8-gate-remote.txt]`. `embeddings maintainer started` was **SKIP** on the remote gate (60 s bound, network-gated first-enable model download) and **PASS** on the local T6 full gate `[REPORT: task-6-report.md §5a]`. Staged python `enable_load_extension(True): OK` `[REPORT: task-2-report.md]`. Backup proofs re-ran green on the rebuilt sqlite: `PASS: rollback: pre-refresh backup created` + 6× `PASS: backup-select: …` (chose the 0.17.2 backup, never 99.0.0 / 0.16.0) `[TRANSCRIPT: m8-gate-remote.txt]` |
| 2 | **Size:** final size + per-lead breakdown; floor retuned; review-tools pass, zero warnings | **MET** | Breakdown in §Size record. Floor `943,718,400 → 840,957,952` (802 MiB = 85 % of lean) `[REPORT: task-6-report.md §2; final-fix-report.md §3]`; `PASS: m8: snap size floor (>=802 MiB…)` at `size=990572544` `[TRANSCRIPT: m8-gate-remote.txt]`. `frigate_0.17.2_amd64.snap: pass`, rc=0, no warnings, on the **local** clean artifact `519e240c…` `[REPORT: final-fix-report.md §7c]`. review-tools was **not** run by us on the Store-built rev 4/5 files |
| 3 | **tflite swap** if the import-graph proof passes; otherwise the recorded finding is the deliverable | **MET (proof failed → finding recorded)** | tensorflow-cpu **KEEP**: upstream ships it on x86_64, and the classification-training path imports full tf+keras with no tflite fallback. Verdicts are quoted in §Import-graph verdicts `[REPORT: task-3-4-verdicts.md]` |
| 4 | **svc trim:** exactly the four services + diagnostics; no svc-a/b/c payload in prime; app-list parity | **MET** | Remote gate: 3× `PASS: m8: app census …` (no `svc-*` in `bin/`, exactly 5 daemon apps = 4 services + `logrotate` oneshot, no `go2rtc-gen.py`) `[TRANSCRIPT: m8-gate-remote.txt]`. The same 3 PASS on the **production host running Store rev 5** `[TRANSCRIPT: host nvr-safe 2026-11-11]`. That host check had been a version-skew SKIP on rev 3 `[REPORT: final-fix-report.md §7b]`. `snap info` lists services certsync/frigate/go2rtc/nginx + logrotate (oneshot) `[LIVE]`. The census asserts the daemon count; it does not parse the README |
| 5 | **NVR-safe gate** green on the production host; config.yml + DB before/after prove zero mutation; zero restarts | **MET (with deviation: no DB checksum, D1)** | Harmlessness triple `PASS: nvr-safe: config.yml untouched` / `TLS cert untouched` / `no service restarted` in every host run: T1 run 4 (83/0, ALL PASS), T6 (53/0/24, ALL PASS), final-fix (52/0/26, ALL PASS) `[REPORT: task-1-report.md; task-6-report.md §5b; final-fix-report.md §7b]`, and 2026-11-11 `[TRANSCRIPT: host nvr-safe 2026-11-11]`. The 2026-11-11 banner is **`SPIKE SMOKE: FAILURES`**. Its one FAIL is the item-6 go2rtc `/logs` assertion (a harness false-fail, §Finding F1), not a harmlessness line |
| 6 | **`/logs` tee-parity:** live frigate + go2rtc content; forced non-zero child exit still triggers restart | **MET (VM) / host assertion false-fail (F1)** | Remote rev-4 gate: `/logs frigate tab has real content` PASS, `/logs go2rtc tab has real content` PASS, `go2rtc relaunched after kill -9 (… 2s)` PASS, `MainPID 45944 -> 47009 after SIGKILL` `[TRANSCRIPT: m8-gate-remote.txt]`. Host 2026-11-11: frigate tab PASS, journald passthrough PASS, go2rtc tab **FAIL**. The tab serves real go2rtc output (HTTP 200, 67,458 lines); the assertion's banner grep finds nothing in a log flooded with camera-dial warnings `[LIVE]` (F1) |
| 7 | **Upstream #4** reproduced on upstream Docker v0.17.2 (or ruled packaging); draft under `docs/upstream/` | **MET** | `Status: UPSTREAM-CONFIRMED` on `ghcr.io/blakeblackshear/frigate:0.17.2`. Root cause: single-camera ZeroMQ `SUBSCRIBE` prefix narrowing drops the hot-add topic `[tracked: docs/upstream/2026-07-12-recordingmaintainer-hotadd-keyerror.md]`. Filing upstream is a **user action**. Whether it has been filed was not checked |
| 8 | **Denial policy:** 0 unexpected; new arms narrow + journal-quoted | **MET** | Remote rev-4 gate `== denials: 564 total, 0 unexpected ==` (`m8-gate-remote-denials.txt` = 564 lines, 564 `apparmor="DENIED"`) `[TRANSCRIPT]`. Host 2026-11-11 `73 total, 0 unexpected` `[TRANSCRIPT]`. New/re-added arms: bash `CAP_DAC_OVERRIDE` (T7), matplotlib font scan (T6), joblib sem/lscpu (T7), daemon lscpu `/sys/kernel/cpu_byteorder` (T10), each pinned with a journal quote `[REPORT: task-6/7-report.md; progress.md L259]` |
| 9 | **VM money re-run:** clean VM installs lean rev from `latest/edge` (authed), README-only path → authed UI over TLS, detector alive, all historical money lines green | **PARTIAL** | Met: the Store-built artifact (rev 4, pulled via an authed in-VM refresh to `latest/edge/PR4`) passed the full gate. `PASS: auth: authed GET https://…:8971/api/version → 200 (M5 MONEY LINE)` `[TRANSCRIPT: m8-gate-remote.txt; REPORT: progress.md L258]`. **Not met:** the ov and coral detector money lines **SKIP (no capability)** in the VM (no Intel render node, no Coral). Livecam MONEY TEST SKIP (no livecam). No README-literal walk-through was re-run (the M7 T8 pattern). Detector-alive on hardware is not evidenced post-M8 (see §Soak: the host's `inference_speed=10.0ms` is the never-ran sentinel) |
| 10 | **Field-soak (the exit):** host Store-tracked, 3–7 days on the lean rev; nvr-safe + journald sweep at window end: zero crash-loops, zero unexpected errors, detections on both cameras | **OPEN (PROPOSED, user decides)** | See §Soak record. Recorded: no T0, no window, no window-end. Retained: rev 5 on the host since refresh 2026-08-09; NRestarts=0 since the 2026-11-06 boot; 0 err-priority lines, but 2,499,616 Frigate-level `ERROR` lines in the retained journal (from 2026-10-22), all camera-path, which a priority filter cannot see (L10). **Missing:** detections. Both cameras report `camera_fps 0.0` today and the events API returns 0 events |

**Spec §1 exit criterion.** (1) Full gate green on the lean artifact in a clean LXD VM: **MET** (rev 4, attempt 4, ALL PASS). (2a) Lean revision reaches `latest/edge` through CI: **MET** (rev 5; runs below). (2b) Production NVR migrates to track it: **PARTIAL**. Rev 5 is installed, but the host tracks `latest/edge/PR3`, not `latest/edge`. (2c) 3–7 day soak: **OPEN**.

**Tally:** items 1–8 MET (5 with a recorded deviation, 6 with a host-side harness false-fail); item 9 PARTIAL; item 10 OPEN, with a proposed verdict for the user.

---

## Size record (per lead, before/after bytes)

Compressed `.snap` bytes (`stat -c %s`) unless marked uncompressed. The chain is reconciled to the byte: 1,140,236,288 + 57,344 − 112,185,344 − 32,329,728 − 5,898,240 − 12,288 = **989,868,032**.

| Step | Before (B) | After (B) | Δ (B) | Source |
|---|---:|---:|---:|---|
| M7 baseline, **remote** artifact (Launchpad, `f9a17a7`) | — | 1,140,936,704 | — | `[REPORT: m7-findings.md row 12; progress.md L211]` |
| M7 baseline, **local** build (start of the M8 chain) | — | 1,140,236,288 | — | `[REPORT: task-2-report.md]` |
| A1 R4: python `--enable-loadable-sqlite-extensions` + `vec0.so` | 1,140,236,288 | 1,140,293,632 | **+57,344** | `[REPORT: task-2-report.md]` |
| A2 ffmpeg 8.0 tree dropped (uncompressed −408,881,424) | 1,140,293,632 | 1,028,108,288 | **−112,185,344** | `[REPORT: task-3-4-verdicts.md]` |
| A3 svc-a/b/c retired (yaml only; payload lingered, see L1) | 1,028,108,288 | 1,028,108,288 | 0 | `[REPORT: task-5-report.md §4]` |
| C1 `/logs` tee-parity | 1,028,108,288 | 1,028,108,288 | 0 | `[REPORT: task-7-report.md]` |
| A2 prime batch 1: stdlib `test` 120,070,752 + `libpython3.11.a` 46,045,686 + headers 890,786 + doc 328,247 + man 1,004,414 (uncompressed) | 1,028,108,288 | 995,778,560 | **−32,329,728** | `[REPORT: task-6-report.md §1]` |
| A2 prime batch 2: pip 14,384,513 + setuptools 6,013,517 + `_distutils_hack` 17,657 + `.pth` 151 (uncompressed) | 995,778,560 | 989,880,320 | **−5,898,240** | `[REPORT: task-6-report.md §1]` |
| Final-review fix: `snapcraft clean wrappers probes` (stale svc/gen payload out) | 989,880,320 | 989,868,032 | **−12,288** | `[REPORT: final-fix-report.md §1]` |
| Launchpad rev 4 (cold build of `eb512bf`; the parity-gated artifact) | 989,868,032 (local) | **990,572,544** | +704,512 (build variance) | `[TRANSCRIPT: m8-gate-remote.txt]`; sha256 `864158f71205fda3fe66e9537d6e0dca337c93a63aff398565f27e84741e1873` |
| Store rev 5 (`bbfb13c`; now `latest/edge`, on the host) | — | **990,580,736** | +8,192 vs rev 4 | `[LIVE: ls -l /var/lib/snapd/snaps/frigate_5.snap]`, snapd's on-disk copy. Its sha256 was **not** measured (root-only file) |

**Net:** 1,140,936,704 → 990,572,544 = **−150,364,160 B (−13.2 %)** remote-to-remote. For comparison, snapd's on-disk Store rev 3 is 1,140,965,376 B against rev 5 at 990,580,736 B (−150,384,640 B) `[LIVE: ls -l /var/lib/snapd/snaps]`. The spec's 600–850 MB estimate was not reached. Under the upstream-parity rule, tensorflow-cpu, both opencv stacks and ffmpeg 5.0/7.0 stay. Floor retune `943,718,400 → 840,957,952 B` (`floor_to_MiB(0.85 × lean)`), unchanged by the 12,288 B clean-up `[REPORT: final-fix-report.md §3]`.

**Rev 5 vs rev 4 inputs.** `git diff --stat eb512bf bbfb13c` touches only `.gitignore` and `tests/spike-smoke.sh`, and neither is a part `source:` in `snap/snapcraft.yaml` (part sources: `spike/{wheels-src,probes,bin,config,models-prebuilt,media-samples}`, the python tarball, upstream frigate git) `[STORE/CI: git diff; grep source: snap/snapcraft.yaml]`. So rev 5 is a rebuild of rev 4's inputs. The parity gate itself ran on rev 4, not rev 5. `git diff bbfb13c a39bfb0` is empty: `main`'s tree equals rev 5's source `[STORE/CI]`.

---

## Import-graph verdicts (verbatim, `.superpowers/sdd/m8/task-3-4-verdicts.md` summary table)

| Item | Verdict | Strongest single evidence | Size effect |
|---|---|---|---|
| tensorflow-cpu | **KEEP** | upstream requirements-wheels.txt:17 ships `tensorflow-cpu==2.19.*` on x86_64 (parity rule = KEEP); independently classification.py:168 training path needs full tf+keras, no tflite fallback, reachable via embeddings/__init__.py:292 | none (KEEP) |
| opencv-python-headless | **KEEP** (upstream-report candidate) | upstream requirements-wheels.txt:41-42 ships both; but shipped `cv2.abi3.so`=79,270,025 B ⇒ **contrib wins**, so headless is ~65.5 MB inert dead weight (opencv_python_headless.libs) | ~65.5 MB recoverable **only** if we ever deviate from upstream (we don't this milestone) |
| opencv-contrib-python | **KEEP** | `cv2.face.createFacemarkLBF()` at face/model.py:46 is contrib-only and used; upstream requirements-wheels.txt:42 ships it | none (KEEP) |
| ffmpeg 5.0 | **KEEP** | upstream install_deps.sh:50-53 + Dockerfile:260 `INCLUDED…:5.0` (amd64) | none (KEEP) — 220.8 MB stays |
| ffmpeg 7.0 | **KEEP** | upstream Dockerfile:259 `DEFAULT_FFMPEG_VERSION="7.0"` (amd64 default) | none (KEEP) — 256.2 MB stays |
| ffmpeg 8.0 | **DROP** | upstream v0.17.2 ships **no 8.x ffmpeg** (grep of docker/ empty); OUR addition (commit 7a94207); only caller = synthetic go2rtc test: stream | **−408.9 MB** uncompressed (5 edits listed) |
| bonus sweep | **no drops** | requirements-core.txt ⊆ upstream requirements-wheels.txt (set-diff ∅); validate-deps adds are all upstream/import-graph-forced | none |

Of 12 `import tensorflow` hits in `frigate/`, 8 are the dormant `except` branch of a `try: tflite_runtime` guard. The 4 in `util/classification.py:168-171` are the reachable training path (class b → KEEP). None is unreachable (class c) `[REPORT: task-3-4-verdicts.md §A]`. Commits verified: `7a94207` (M1 "stage ffmpeg 8.0"), `cba2969` (M2 wheel set, origin of the opencv pin), `5f8c3a0` (8.0 drop) `[STORE/CI: git show]`.

---

## Tee-parity crash proof

Mechanism: `exec <daemon> > >(exec tee -a <sink>) 2>&1` in `#!/bin/bash` wrappers. The daemon stays the unit's MainPID, so exit codes reach snapd untouched. go2rtc writes to `$SNAP_DATA/go2rtc-logs/current`, symlinked from `/dev/shm/logs/go2rtc/current`, because AppArmor denies go2rtc writing to `/dev/shm/logs` (`operation="mknod" … profile="snap.frigate.go2rtc"`) `[REPORT: task-7-report.md]`. Proof on the Store-built rev 4 `[TRANSCRIPT: m8-gate-remote.txt]`, verbatim:

```
PASS: m8: /logs frigate tab has real content (process-sub tee wrote daemon stdout)
PASS: m8: /logs go2rtc tab has real content (tee -> $SNAP_DATA symlink)
PASS: m8: journald still receives frigate lines (tee passthrough)
PASS: m8: go2rtc relaunched after kill -9 (on-failure survived process-sub tee, 2s)
PASS: m8: journald shows go2rtc kill+restart (exit-code propagation)
  m8 finding: go2rtc MainPID 45944 -> 47009 after SIGKILL (2s; on-failure relaunch proves the process-sub tee did not intercept the daemon's exit)
```

Rotation: seeded sinks of 11,536,030 B (frigate) and 11,534,611 B (go2rtc) each rotated to `.1` and were truncated by `copytruncate`, with the daemons still healthy `[REPORT: task-7-report.md]`.

---

## Gate record

| Run | Artifact | Result | Source |
|---|---|---|---|
| T6 VM full gate (purge+install) | local lean `27915270…` (989,880,320) | ALL PASS 141/0/18, 2 RETIRED, 525/0 | `[REPORT: task-6-report.md §5a]` |
| Final-fix VM full gate | local clean `519e240c…` (989,868,032) | ALL PASS 146/0/17, 557/0 | `[REPORT: final-fix-report.md §7a]` |
| Remote-parity attempt 1 | rev 4 | **poisoned**: VM root disk (8.7G) hit 100 %, ENOSPC truncated config.yml to 0 bytes | `[REPORT: progress.md L258]` |
| Remote-parity attempt 2 | rev 4 | **poisoned**: self-heal tested `-e`, not `-s`; the 0-byte config sailed through, `validate-config` rc=1 cascade | `[REPORT: progress.md L258]` |
| Remote-parity attempt 3 | rev 4 | 145/1/17: sole FAIL = 1 unexpected denial in 509 (daemon `lscpu` read of `/sys/kernel/cpu_byteorder`) | `[REPORT: progress.md L259]` |
| **Remote-parity attempt 4** (harness `76e3191`) | **rev 4** `864158f7…` (990,572,544) | **ALL PASS — 145 PASS / 0 FAIL / 18 SKIP / 2 RETIRED; 564 denials / 0 unexpected** (recounted) | `[TRANSCRIPT: m8-gate-remote.txt + -denials.txt]` |
| Host `--nvr-safe`, 2026-11-11 (harness `76e3191`) | installed Store **rev 5** | **FAILURES — 56 PASS / 1 FAIL / 23 SKIP / 2 RETIRED; 73 denials / 0 unexpected** (recounted); harmlessness triple PASS | `[TRANSCRIPT: host nvr-safe 2026-11-11]` |

The 18 SKIPs on attempt 4 break down as: 9 `SKIP (no capability)` (render node ×5 incl. auto-detect ×2, Coral ×3, embeddings ×1); 5 coral-phase (no Coral USB); 3 livecam MONEY TEST (no livecam provisioned); 1 npu retired `[TRANSCRIPT]`. The task reports' own count tables were **not** reused. The ledger flags T6 report §8 as imprecise.

---

## Soak record (spec §4 item 10) — what the evidence supports

**Planned protocol** (plan Task 10 steps 4–5). User runs a pre-flight backup and then `snap refresh frigate --channel=latest/edge --amend`. T0 = an nvr-safe ALL PASS + a journal MARK. Optional daily sweeps. Window end (3–7 days) = nvr-safe ALL PASS + zero crash-loops + zero unexpected journal errors + detections flowing on both cameras.

**Recorded:** nothing. The ledger's last M8 line ends at `NEXT: merge evidence presented → user merges → release-on-merge → user pre-flight backup + refresh --amend → soak T0` `[REPORT: progress.md L259]`. No T0, window length, daily sweep or window-end record exists in the repo, the ledger or the M8 report folder.

**Retained facts** `[LIVE, 2026-11-11 unless noted]`:

| Fact | Value | Source |
|---|---|---|
| Rev 5 provenance | `PR Build Snap` run 29375883189 on `bbfb13c` (2026-07-14T23:21Z → 2026-07-15T01:14Z, success); promoted to `latest/edge` by `Release on merge` run 29457744580 (2026-07-15T23:10:38Z → 23:11:23Z, success) | `[STORE/CI: gh run list]` |
| Installed on host | rev 5 (`private`); rev 3 retained `disabled` | `snap list frigate --all` |
| Tracking / refresh | `tracking: latest/edge/PR3`, `refresh-date: 2026-08-09` | `snap info frigate` |
| Services | go2rtc / frigate / nginx / certsync `active (running)`, **NRestarts=0** each, all started 2026-11-06 04:39:58 CET (boot 04:39:17) | `systemctl show`; `uptime -s` |
| Retained journal | begins **2026-10-22 11:47:32 CEST** (4 boots retained: 10-22, 10-29 ×2, 11-06) | `journalctl --list-boots` |
| Err-priority lines | **0** for `snap.frigate.*` since 2026-08-09, i.e. 0 in the retained 2026-10-22 → 2026-11-11 span. **This sweep is blind to Frigate's own errors:** Frigate writes its `ERROR` log level to stdout, which journald stores at info priority. Application-level `ERROR` lines **are** present in the retained journal; the first one retained is `watchdog.cam1 ERROR : Ffmpeg process crashed unexpectedly for cam1` (2026-10-22 18:10) | `journalctl -p err -u 'snap.frigate.*' --since 2026-08-09`; `journalctl -u 'snap.frigate.*' \| head -2` |
| App-level `ERROR` lines | **2,499,616** in the retained journal (2026-10-22 →), **all** from 7 camera-path loggers: `frigate.video` 423,918; `ffmpeg.cam1.detect` 415,143; `ffmpeg.cam1.audio_record` 415,140; `ffmpeg.cam2.detect` 415,139; `ffmpeg.cam2.audio_record` 415,136; `watchdog.cam1` 207,571; `watchdog.cam2` 207,569. **No `ERROR` from any other logger** (detector, recording, API, embeddings). Camera capture failed continuously from the first retained `ERROR` (2026-10-22 18:10; the journal starts 11:47, and the ~6 h before that have none) to today. This is consistent with unreachable cameras: go2rtc dial errors are what is observed today (G2). The cause for the earlier span is not established. The host was not capturing from the cameras in that span | `journalctl -u snap.frigate.frigate.service --since 2026-08-09 -o cat -g '  ERROR  '` → per-logger `uniq -c` (counts only) |
| Cameras now | both cameras `camera_fps 0.0`, `process_fps 0`, `detection_fps 0` | loopback `GET :5001/stats` |
| Detector now | `ov inference_speed=10.0 ms`. **This is the never-ran sentinel** (M6 D2: the moving average initialises to 0.01 s), so it is **not** evidence of inference | host nvr-safe transcript L61; `docs/m6-findings.md` D2 |
| Events | **0** events returned by `GET :5001/events?limit=100000` (any time range; retention-dependent) | loopback API |
| Recordings | `media/frigate/recordings/` holds a single `2026-07-10` day directory; parent mtime **2026-07-26**. Whether recording is enabled in the operator config was **not** checked (the config was not opened) | `ls -ld` |
| go2rtc log | `/logs/go2rtc` HTTP 200, 67,458 lines (9,238,160 B), **all** `WRN [rtsp]` camera-dial errors | loopback `GET :5001/logs/go2rtc` (counts only; contents not copied) |

**Gaps, stated plainly.**
- **(G1)** The 2026-08-09 → 2026-10-22 window, the first ~10 weeks on rev 5, cannot be re-read: that journal is gone.
- **(G2)** No detections are evidenced at any point after M8 shipped. Today: 0 fps on both cameras, 0 events, the sentinel inference speed, and go2rtc dials failing. Why the cameras are unreachable from the host was not established; the host is a laptop, and the condition is the same class as M7's livecam-offline SKIPs.
- **(G3)** The plan's migration command did not take effect as written: tracking is still `latest/edge/PR3`. How a PR3-tracking host received rev 5 on 2026-08-09 was **not verified**. A plausible but unconfirmed explanation is Store branch expiry falling back to `latest/edge`.
- **(G4)** NRestarts=0 shows no service crash-loops **only since 2026-11-06**. The 0 err-priority result is **not** evidence of "zero unexpected errors": Frigate-level `ERROR` lines (ffmpeg/camera watchdog) exist in the retained journal, and a priority filter cannot see them (L10). All 2,499,616 come from the camera-path loggers, which is consistent with the unreachable cameras; no other subsystem logged an `ERROR`. Their content was not read line by line.

**Proposed verdict for item 10 (PROPOSED: user decides):**

> **OPEN.** The soak as specified was not recorded. Retained evidence shows rev 5 running on the production host since 2026-08-09, with no service restarts since the 2026-11-06 boot. The retained journal (2026-10-22 →) holds 2,499,616 Frigate-level `ERROR` lines, all from camera ffmpeg/watchdog/video loggers and none from any other subsystem. Camera capture failed continuously from the first retained `ERROR` (2026-10-22 18:10) to today, which is consistent with unreachable cameras; the cause for the earlier span is not established. "Detections flowing on both cameras" is unevidenced for the entire post-M8 period, and the cameras are unreachable from the host today. M8 closes on the gate half of its exit criterion. The soak is re-run as a fresh, recorded window (T0 nvr-safe + journal MARK → window-end sweep) once the cameras are reachable and the host tracks `latest/edge`.

Alternatives the user may prefer instead: **(b)** "PARTIAL: no service crash-loops since 2026-11-06; errors and detections not evidenced"; **(c)** waive the soak and close M8 on the gate alone. That would be a change to the spec's exit bar and should be recorded as such. Calling item 10 MET is not supported by any evidence found.

---

## Findings

- **F1: go2rtc `/logs` assertion is a false-fail on a long-running, flooded log.** The check is `curl … /logs/go2rtc | grep -qiE 'go2rtc|\[api\]|listen'` (`tests/spike-smoke.sh` L1571–1572). On the host, the tab returns HTTP 200 with 9,238,160 B in 0.49 s (so this is no `--max-time 5` truncation), but **0** lines match. Every one of the 67,458 lines is a `WRN [rtsp]` dial error, and the startup banner has rotated out of the served window `[LIVE]`. The product works; the assertion is fragile. A harness-only fix is a separate item and the user's call (M-next).
- **F2: go2rtc WebRTC UDP boot-order race.** go2rtc binds its fixed-port UDP candidate sockets per interface address **at process start only**. After a cold boot, before the network is up, it holds zero UDP sockets for its lifetime. TCP mux and STUN still work `[REPORT: task-1-report.md fix round §2]`. Re-observed on 2026-11-11: `8555/udp NOT bound` `[TRANSCRIPT: host nvr-safe]`. Backlog: order go2rtc after network-online.
- **F3: go2rtc WRN lines can embed camera RTSP userinfo.** This was observed in the journal during T1 triage; it is upstream logging behaviour, and the harness scrubber does not cover the journal `[REPORT: task-1-report.md]`. Since C1, go2rtc stdout is also tee'd to `$SNAP_DATA/go2rtc-logs/current` and served on the UI `/logs` tab. That is the same exposure class as journald inside the snap's private areas, but it is now visible to a logged-in UI user `[REPORT: task-7-report.md §Secret discipline]`. On 2026-11-11 the served body had **0** matches for a URL-with-userinfo pattern (count only) `[LIVE]`. Which UI role can read `/logs` was not checked.
- **F4: bash `CAP_DAC_OVERRIDE` advisory denials.** The `sh → bash` switch for process substitution makes bash probe `capable(CAP_DAC_OVERRIDE)`. AppArmor denies it, so confinement holds, and file ops succeed via normal DAC. Pinned arms were added `[REPORT: task-7-report.md]`.
- **F5: opencv headless dead weight (upstream-report candidate).** Upstream ships both cv2 stacks; contrib wins the pip unpack race, which leaves ~65.5 MB of inert headless `.libs`. It is also order-fragile upstream `[REPORT: task-3-4-verdicts.md §B]`.
- **F6: semantic search first enable downloads models.** Jina CLIP v1 + facenet + paddleocr go into `$SNAP_DATA/config/model_cache`, and the download needs network. The README carries the caveat (`README.md` §Semantic search) `[REPORT: task-2-report.md; final-fix-report.md §4]`.
- **F7: `SNAP_FILE` stale-artifact footgun (fixed).** The rollback reinstall could silently install an older `.snap` left in the checkout. It is fixed by pinning the artifact sha at gate start and refusing a swapped build `[REPORT: task-7-report.md; task-6-report.md §4]`.
- **F8: captured ≠ produced.** Denial capture is timing-dependent. Arms retired in T5 for lack of a quote were re-added in T6/T7 once quoted `[REPORT: task-5/6/7-report.md]`.

---

## Security / credential record

*No credential value, camera address or stream URL appears in this document. It describes mechanisms only.*

- **Repo made public (USER) to unblock CI.** PR #4's build failed 5× with `CredentialsFileError`. Root cause: the Store/Launchpad secrets had been moved to **org level**, and GitHub free-plan orgs do not deliver org secrets to **private** repos; the variable expands empty with no error. The user made the repo public; close/reopen of PR #4 then built green `[REPORT: progress.md L258]`.
- **Untracked `snapcraft.login` found in the now-public working tree.** The user was told to relocate it. `*.login` was gitignored in `bbfb13c` `[REPORT: progress.md L259]`. `git log --all -- '*.login'` returns nothing, so it was never committed `[STORE/CI]`.
- **Pre-push secret sweep:** 0/0/0 `[REPORT: progress.md L257]`. The remote gate's zero-creds check passed: `PASS: evidence: no URL credentials … anywhere in evidence files` `[TRANSCRIPT: m8-gate-remote.txt]`.
- **Private-snap harvest window.** `snap download` cannot fetch a private snap, and the Launchpad librarian file is deleted at CI end. Rev 4 was harvested with an in-VM `snap login` → refresh → copy → `snap logout` (<1 min window) `[REPORT: progress.md L258]`.

---

## Deviations

| # | Deviation | Reason | Reference |
|---|---|---|---|
| D1 | **nvr-safe harmlessness proof = config sha + cert sha + zero restarts, no DB checksum** (spec §4 item 5 named the DB) | A live NVR writes its DB continuously, so a DB checksum can never hold. The gate's only DB access is a read-only `SELECT` | `[REPORT: task-1-report.md Deviation 1]` |
| D2 | nvr-safe SKIPs the auth-login money triple | The bootstrap credential is journal-logged only on the first boot after a purge; nvr-safe never purges. The unauthenticated-401 check still runs | `[REPORT: task-1-report.md Deviation 2]` |
| D3 | nvr-safe made fixture-aware (testclip vod/gpu) and webrtc-UDP SKIP-with-finding | Operator configs lack the harness fixtures; UDP state depends on boot order (F2) | `[REPORT: task-1-report.md fix round]` |
| D4 | Full gate made **hardware-aware** (`SKIP (no capability)` per missing render node / Coral / listener) | ALL PASS was unreachable in a bare VM (T5 showed 10 environmental FAILs). Guards assert on capable hardware: 0 capability-SKIPs on the host | `[REPORT: task-6-report.md §3]` |
| D5 | R4 mechanism = `/usr/local/lib` layout bind + wheel's `vec0.so`, not a pip-only install | Frigate loads a **hardcoded** `/usr/local/lib/vec0`. Upstream builds the same v0.1.3 from source. No Frigate patch | `[REPORT: task-2-report.md]` |
| D6 | go2rtc tee sink in `$SNAP_DATA` + symlink, not `/dev/shm/logs` | AppArmor denies go2rtc writes to `/dev/shm/logs` (the plan's fallback branch) | `[REPORT: task-7-report.md]` |
| D7 | `pkg_resources` kept; `_distutils_hack` + `.pth` removed with setuptools | tensorboard imports `pkg_resources`; removing the shim keeps `import distutils` working (import-proven) | `[REPORT: task-6-report.md §1]` |
| D8 | WHEP capture `--max-time 5 → 10` | go2rtc answers WHEP only after ICE gathering. Measured in the VM: `000` after 5.01 s at 5 s, `201` + SDP at 5.069 s at 20 s | `[REPORT: task-6-report.md §8]` |
| D9 | **Parity gate on rev 4; rev 5 shipped** | A harness-only push re-triggered the PR build; rev 5's inputs equal rev 4's (§Size record) | `[STORE/CI: git diff eb512bf bbfb13c]` |
| D10 | **Production migration not executed as planned**: host tracks `latest/edge/PR3` | Not recorded why. Rev 5 arrived on 2026-08-09 regardless (G3) | `[LIVE: snap info]` |
| D11 | **Soak not recorded** | See §Soak record | — |
| D12 | **Report-path clobber incident**: M8's first reports overwrote untracked M7 evidence `.superpowers/sdd/task-{1,8,9}-report.md` | The controller reused M7 naming. From T2 on, reports live in `.superpowers/sdd/m8/`. Consequence: the `[REPORT]` citations to those three files in `docs/m7-findings.md` now point at lost or replaced files | `[REPORT: progress.md L234]` |
| D13 | VM full gates ran detached-in-VM + polled (T5/T6), not one foreground call | Purge-gate poll loops exceed the 600 s tool wall | `[REPORT: task-5/6-report.md Deviations]` |

---

## Lessons

- **L1: Dump parts do not propagate deletions without `snapcraft clean`.** The retired `svc-a/b/c` wrappers sat in prime and were certified into a gated artifact's size+sha. The T5 census checked only `snap.yaml`. Fix: clean the part, plus an app-census assertion on `bin/` (final review Critical) `[REPORT: final-fix-report.md §1–2; progress.md L256]`.
- **L2: Existence is not content.** Self-heal and stash paths tested `-e`. A 0-byte config passed through a purge cycle and poisoned attempt 2. Now `-s` everywhere, plus a 0-byte fail-fast tripwire (`76e3191`) `[REPORT: progress.md L258–259]`.
- **L3: Size the gate VM's disk for the artifact.** 8.7G filled up mid-gate; it was grown to 19G `[REPORT: progress.md L258]`.
- **L4: Free-plan org secrets do not reach private repos**, and the failure mode is silent (an empty expansion) `[REPORT: progress.md L258]`.
- **L5: Namespace evidence per milestone** (D12).
- **L6: `inference_speed == 10.0` is a sentinel, not a reading** (M6 D2). It is re-observed on the host today and must not be cited as detector health.
- **L7: Banner greps do not survive long-running services** (F1). Assert on what is stable (HTTP 200 + non-empty), not on startup text.
- **L8: A PR `paths:` filter matches the whole PR's files.** A harness-only push therefore rebuilt the snap (rev 5) `[REPORT: progress.md L259]`.
- **L10: `journalctl -p err` cannot see Frigate's errors.** Frigate logs `ERROR` to stdout, which journald stores at info priority. The plan's soak sweep (`journalctl --since <T0> -p err -u 'snap.frigate.*'`) would report 0 while Frigate logs camera-watchdog errors. A soak sweep must grep the Frigate log level (`-g '  ERROR  '`) or read `/logs`, not filter by priority `[LIVE: journalctl, 2026-11-11]`.
- **L9: Audit-line field order matters for allowlist regexes.** File-open lines put `name=` before `comm=`, so the first lscpu arm draft matched nothing `[REPORT: progress.md L259]`.

---

## M-next / backlog

| Item | Notes / origin |
|---|---|
| **Soak, re-run and recorded** | Needs cameras reachable from the host. T0 nvr-safe + journal MARK, window end per plan Task 10 step 5, **with the error sweep fixed per L10** (grep Frigate's `ERROR` level, not `-p err`). Closes item 10 if the user rules OPEN |
| **Host tracking → `latest/edge`** (USER) | `snap refresh frigate --channel=latest/edge` (D10/G3) |
| **M7c — arm64** (next milestone) | On the lean base. Reassess the arch guard against the R3 vendor guard (carried from M7) |
| **Harness: F1 go2rtc `/logs` assertion** | Harness-only. Assert HTTP 200 + non-empty instead of a banner grep. Own item, user's call |
| **go2rtc after network-online** (F2) | Boot-robust WebRTC UDP candidates |
| **RTSP userinfo in go2rtc logs** (F3) | Credential-hardening lane; possible upstream report; check which UI role reads `/logs` |
| **Upstream #4: file the issue** (USER) | Draft is paste-ready (`docs/upstream/…hotadd-keyerror.md`) |
| **Upstream report: opencv headless dead weight** (F5) | ~65.5 MB, order-fragile |
| **Store-side user actions** | Beta promote, visibility flip + anonymous re-check, declaration submissions. Spec §1 gates these on the soak. M7's open rotations (Store login credential re-export, camera credential rotation) were not checked here |
| Harness minors (deferred) | Optional nvr-safe NOTE when a parked stash exists (T1); census placement re-check post-install-cycle (ledger L257); regenerate stale `spike/results/expanded-snapcraft.yaml` 8.0 block |
| CI: `paths:` filter (L8) | Avoid snap rebuilds on harness-only PR pushes |
| Per-version Store tracks | Carried from M7 |

---

## Review trail

- **Per-task reviews:** T1 Approved after a fix round and a re-review (self-heal blocks gated); T2 Approved; T3+4 Approved-with-fixes (3 citation fixes); T5 Approved; T6 Approved ×2 (WHEP decoupling); T7 Approved; T8 Approved (UPSTREAM-CONFIRMED); T9 clean after 1 Critical (invented date claim reworded) `[REPORT: progress.md L230–254]`.
- **Final whole-branch review** (fable): **With fixes**. CRITICAL: stale svc-a/b/c payload in prime + missing app-census assertion. IMPORTANT: README `/logs` paragraph false; issue-draft exec lines not paste-runnable. Fix wave `eb512bf`; re-verdict READY TO MERGE `[REPORT: progress.md L256–257; final-fix-report.md]`.
- **Commits on main** (`git log e5ed16b..a39bfb0`, verified): `53fdea5` `08706ab` `f6ffdbf` `5a53432` `8f96a90` `85ecbc0` `22ef14f` `1ba110f` `5f8c3a0` `2bdd8e5` `56a79c4` `c995263` `7c148be` `eb512bf` `76e3191` `bbfb13c`; merge `a39bfb0`. PR #4 merged 2026-07-15T23:10:35Z `[STORE/CI: git log; gh pr list]`.

---

## Evidence index

`spike/results/` and `.superpowers/` are git-ignored and local-only. None of the files below except the tracked ones is in the repo.

| File | Class | Content |
|---|---|---|
| `spike/results/m8-gate-remote.txt` | TRANSCRIPT | Remote-parity attempt 4 on Store rev 4 (990,572,544 B, sha `864158f7…`): ALL PASS 145/0/18, 2 RETIRED; 564/0 |
| `spike/results/m8-gate-remote-denials.txt` | TRANSCRIPT | 564 denial lines for that run |
| host `nvr-safe-2026-11-11.txt` (session scratchpad, not committed) | TRANSCRIPT | Host nvr-safe on rev 5: FAILURES 56/1/23, 2 RETIRED; 73/0; harmlessness triple PASS |
| `.superpowers/sdd/m8/task-1-report.md` | REPORT | nvr-safe mode, stash guards, UDP triage, D1/D2/D3 |
| `.superpowers/sdd/m8/task-2-report.md` | REPORT | R4 discovery + mechanism + unsquashfs proof |
| `.superpowers/sdd/m8/task-3-4-verdicts.md` | REPORT | Import-graph + ffmpeg verdicts; 8.0 drop |
| `.superpowers/sdd/m8/task-5-report.md` | REPORT | svc retirement, imports-probe, census |
| `.superpowers/sdd/m8/task-6-report.md` | REPORT | Prime pruning, floor, hardware-aware gate, trifecta |
| `.superpowers/sdd/m8/task-7-report.md` | REPORT | Tee-parity, crash proof, rotation, dac_override |
| `.superpowers/sdd/m8/final-fix-report.md` | REPORT | Clean rebuild, census assertion, trifecta |
| `.superpowers/sdd/progress.md` (M8 section, L227–259) | REPORT | Ledger: verdicts, incidents, CI saga, gate attempts |
| `docs/upstream/2026-07-12-recordingmaintainer-hotadd-keyerror.md` | tracked | Upstream #4 issue draft |
| `docs/superpowers/specs/2026-07-12-m8-solid-design.md` / `plans/2026-07-12-m8-solid.md` | tracked | M8 spec + plan |
