# M7c Findings: arm64 port, Part 2 (census, emulated battery, Pi hub trial)

**Date:** 2026-11-14, hub results added 2026-11-15  **Snap:** `frigate` 0.18.2 (core26, strict), arm64 and amd64  **PR:** #9, branch `feat/m7c-arm64`, CI-built at head `9a2e833` (later commits on the branch touch only `tests/**` and `docs/**`)  **Spec:** `docs/superpowers/specs/2026-11-13-m7c-arm64-design.md`  **Plan:** `docs/superpowers/plans/2026-11-13-m7c-arm64.md`, Part 2 (T14, T15), both on branch `spec/m7c-arm64-research`.

**Status in one paragraph.** T14 is complete. The arm64 artifact is clean of foreign ELF (V2), its wheel set is the amd64 set with arm64 tags and one justified name difference (V3b), and the amd64 non-regression census against the released revision is fully explained (V1). The arm64 size floor is set from the first real artifact. T15 ran in an emulated Cortex-A76 VM on the local Launchpad arm64 file. It was **stopped by the maintainer's decision** after about 7 hours, because emulation ran about 19× slower than real hardware and tied up the laptop. Before the stop, V5 (bytes, install, layout), V6, V18, V7, V9 and the V9 mutation **PASSED**. V10, V11, V-OV, V-restore, V17 and the V8 full harness were **NOT RUN in the VM**. They are not claimed here. Verification moved to the hub. **On the Pi hub** (Raspberry Pi 5, aarch64, Ubuntu Core, snapd 2.78) the exact arm64 file installs, starts, runs the synthetic camera stand-in stably for 7 h 40 min (run 3, the longest of three runs) and loads the Coral. Real-camera and long-run behaviour are **NOT PROVEN**: the cameras refuse RTSP, and no run reached 24 h (section "Results on the Pi hub"). This is not a production verdict on the arm64 file.

**Evidence classes.**

- **`[EVIDENCE: name]`**: a file under the laptop's `~/.cache/frigate-m7c-evidence/part2/` (not committed). Numbers were copied from those files.
- **`[REPORT: …]`**: another worker's or the orchestrator's report on the W-7 card. Not recounted here.
- **`[VERIFIED: …]`**: a command run while writing this document.
- **`[HUB: name]`**: a file under the laptop's `~/.cache/frigate-m7c-evidence/hub/` (not committed). These are the orchestrator's copies of what the hub's probe, observe and watcher runs printed, with no private data. Numbers were copied from those files.
- **`[LIVE]`**: none on a production host. The hub runs the maintainer's Home Assistant, but the Frigate trial on it used only the synthetic stand-in.

---

## Inputs

All three files were downloaded by the orchestrator from Launchpad's public file URLs and the Store. Each was hashed before use and never modified; unsquashed copies were used for the censuses `[EVIDENCE: *.input.sha256.txt, input-sizes.txt]`.

| Input | Bytes | sha256 |
|---|---|---|
| arm64, PR #9 Launchpad build | 916,746,240 | `26db6fb77d2214c030bfb9da0b533edb0935cd49d376b010347a607e9b6200f4` |
| amd64, PR #9 (Store rev 8, `latest/edge/PR9`) | 1,109,827,584 | `6c908822da0a173dd8914888edf197a5217c7e876a1fe4fbe846e1606824098e` |
| amd64, released rev 7 (V1 baseline) | 1,109,823,488 | `1de3f45f5816de0116e1fac7fb2078571e55dc0a87d5ae1a1de657dcf6b2d5ed` |

The snap is **private** on the Store. `snap download` answers "snap not found" even with the laptop's login, and the VM has no Store login and must not get one. The battery therefore ran on the local arm64 file, installed with `snap install --dangerous` after an in-guest sha256 match (file mode, below).

---

## Verdict table

| # | What | Verdict | Evidence |
|---|---|---|---|
| V1 | amd64 non-regression: rev 7 vs PR #9 amd64 (`tests/snap-census.sh`) | **PASS: every difference explained** (census rc=1; reasons below) | `[EVIDENCE: v1-census-rev7-vs-pr9.txt, v1-verdict.txt, v1-normalized.txt]` |
| V2 | arm64 ELF census: no non-aarch64 ELF (`tests/elf-census.sh`) | **PASS** (rc=0, 0 lines) | `[EVIDENCE: v2-elf-census-arm64.txt]`. Mutation: a planted x86-64 `/bin/true` as `usr/bin/planted-x86` is listed, rc=1 `[EVIDENCE: v2-elf-census-mutation.txt]` |
| V3b | 0.18 wheel census, arm64 vs amd64 (`tests/wheel-census.sh`, new in T14) | **PASS** (both rc=0; 174 census lines each; one name difference, justified) | `[EVIDENCE: v3b-wheels-arm64.tsv, v3b-wheels-amd64.tsv, v3b-name-version.diff]`; rc re-checked `[VERIFIED: wheel-census.sh on both unsquashed trees, rc 0 and 0]` |
| Size floor | `ARM64_SIZE_FLOOR` from the first real artifact | **SET**: 779,091,968 B (743 MiB = floor(0.85 × 916,746,240) to a whole MiB) | `tests/lib/harness-arch.sh`, test `tests/lib/harness-arch.test.sh` (commit `c37fd63`) |
| V5 | install from the exact bytes, plugs, services, `/version`, layout (D7) | **PASS** (file mode) | battery lines below `[EVIDENCE: battery.txt, battery/v5-*.txt]` |
| V5 F11 | Store auto-connect | **NOT PROVEN**: not exercised (private snap, no Store in the VM) | `INFO` line below |
| V6 | 18 imports incl. sqlite_vec, 8.0 HEVC decoders, ffprobe | **PASS** | `[EVIDENCE: battery/v6-imports.json]` |
| V18 | EdgeTPU delegate from the daemon environment, no stick | **PASS**: dlopen ok from the aarch64 path; the error is the no-device one | `[EVIDENCE: battery/v18-coral.json, battery/v18.txt]` |
| V7 | CPU detection pipeline on an H.265 clip, `hwaccel_args: ""` | **PASS**: camera_fps 5.2 and 4.9; no `-hwaccel` in the detect cmdlines; 0 error/exited journal lines | `[EVIDENCE: battery/v7-*.txt, battery/v7-stats.json]` |
| V9 | shm bound (D13a): 2 cameras × 50 frames of 640×360 | **PASS**: 50 frames per camera of 345,600 B; `du -sb` 35,183,600 within +10 MiB of 34,560,000 | `[EVIDENCE: battery/v9.txt, battery/v9-sizes.txt]` |
| V9 mut | `shm-max-frames=10` | **PASS**: 10 frame files per camera, back to 50 when removed | `[EVIDENCE: battery/v9-mutation.txt, battery/v9-shm-*.txt]` |
| V10 | memory after 30 min steady state | **NOT RUN in the VM** (stopped during its wait). Measured on the hub instead: row V10 (hub) | `[EVIDENCE: b-stop-record.txt]` |
| V11 | quota rehearsal below the V10 peak, swap enabled | **NOT RUN in the VM** | ditto |
| V-OV | the D10 openvino guard at start | **NOT RUN in the VM** | ditto. The stopped-state check passed on the hub: row V-OV (hub) |
| V-restore | fixture config back, frigate active | **NOT RUN in the VM** | ditto |
| V17 | hold, revert, remove, purge, F10 residue | **NOT RUN in the VM**. The refresh-under-hold and `snap download` parts could not have run anyway (private snap, no Store in the VM) | ditto |
| V8 | full `spike-smoke.sh` harness in the VM (denials, arm64-only arms) | **NOT RUN** (step C cancelled) | ditto |
| V5 (hub) | exact bytes, version, plugs, D7 layout on the Pi | **PASS** | `[HUB: probe-20261114T140443/results.txt, snap-sha256.txt, snap-list.txt, connections.txt, layout.txt]` |
| V6 (hub) | 18 imports incl. sqlite_vec, 4 HEVC decoders, ffprobe | **PASS** | `[HUB: probe-20261114T140443/results.txt, hevc.txt, ffprobe.txt]` |
| V18 (hub) | EdgeTPU with the Coral USB present: dlopen, `load_delegate`, one inference | **PASS** | `[HUB: probe-20261114T140443/coral-json.txt, dlopen-json.txt, usb-before.txt, usb-after.txt]` |
| V-OV (hub) | the D10 guard functions in the snap's shell on arm64, stopped | **PASS, stopped-state only**. The start-time behaviour is NOT PROVEN | `[HUB: probe-20261114T140443/v-ov-stopped.txt]` |
| V7 (hub, stand-in) | CPU decode of H.265 into the detect pipeline, `hwaccel_args: ""`, Coral detector | **PASS for the stand-in**: camera_fps 5 or 5.1 against detect fps 5, skipped_fps 0, in all 9 snapshots. The Coral ran no detections (detection_fps 0) | `[HUB: observe-*/results.txt, run2/observe-*/results.txt, run3/observe-*/results.txt]` |
| V9 (hub, stand-in) | shm bound (D13a) with a 1920x1080 and a 640x360 detect stream | **PASS**: 50 frame files per camera, `/dev/shm/snap.frigate` 173,422,202 to 173,427,663 B | ditto |
| V10 (hub, stand-in) | memory in steady state | **MEASURED, no verdict**: anon 1,008 to 1,090 MiB (1,057 to 1,090 over run 3's last 7 h 07 min), shmem 172 to 198 MiB; page cache fills the 4 GB group to its cap without a restart | ditto, and section "Results on the Pi hub" |
| V11, V17, V8, F11 (hub) | quota squeeze, hold/revert/purge, the full harness, Store auto-connect | **NOT RUN on the hub** (dropped for the hub, or impossible with a private snap) | section "Verification moved to the hub" |

### Battery lines as printed (file mode, SPIKE_TIME_SCALE=20)

`[EVIDENCE: battery.txt]`, verbatim:

```
PASS: V5 bytes: the guest copy of /mnt/out/dl/frigate_0.18.2_arm64.snap has sha256 26db6fb77d2214c030bfb9da0b533edb0935cd49d376b010347a607e9b6200f4
INFO: V5 F11 Store auto-connect: not exercised: private snap, no Store in the VM (--dangerous install; auto-connected: shm-private of raw-usb hardware-observe mount-observe shm-private)
PASS: V5 install: 4 plugs connected; go2rtc/frigate/nginx/certsync active, logrotate enabled+timer; /version=0.18.2-cfa08c5
PASS: V5 layout: /etc/OpenCL/vendors and intel-opencl each list exactly .keep (D7)
PASS: V6 runtime: 18 imports ok (sqlite_vec incl.); hevc decoders=4; ffprobe version n8.1.1-9-g58d4114d36-20260602 Copyright (c) 2007-2026 the FFmpeg developers
PASS: V18 edgetpu: dlopen ok from /snap/frigate/x1/usr/lib/aarch64-linux-gnu/libedgetpu.so.1; delegate error is the no-device one (Failed to load delegate): ValueError: Failed to load delegate from /snap/frigate/x1/usr/lib/aarch64-linux-gnu/libedgetpu.so.1
INFO: V9 stale frame segments before v7: 50
PASS: V7 h265: clip is hevc; camera_fps a,b=5.2,4.9; no -hwaccel in the detect cmdlines; 0 m7c error/exited journal lines
PASS: V9 shm: 50 frames/camera of 345600 B; du -sb=35183600 within +10MiB of 34560000
INFO: V9 stale frame segments before mutation: 100
INFO: V9 stale frame segments before restore: 20
PASS: V9 mutation: shm-max-frames=10 -> 10 frame files/camera; removed -> 50 again
battery.sh: cleanup: shm-max-frames=absent quota=absent
```

The run was stopped by SIGTERM at 12:57:23 CET during V10's scaled 1800 s wait (rc 143). Its cleanup trap confirmed `shm-max-frames=absent quota=absent`, and the guest then showed "No quota groups defined". The guard file shows that the qemu process was the same for the whole run and that the host did not suspend (CLOCK_BOOTTIME − CLOCK_MONOTONIC gap unchanged at 0 s) `[EVIDENCE: battery-guard.txt, b-stop-record.txt, b-stop-guest-state.txt]`. Only shm-private was auto-connected by the `--dangerous` install. The other three plugs were connected by hand, as D12 plans for the hub.

---

## V1 in detail: why the census exits 1 and why that is fine

`tests/snap-census.sh rev7 PR9 v1-expected.txt` reports 6 ADDED, 6 REMOVED, 9 CHANGED and 186 INFO CHANGED, with rc=1. All 195 CHANGED paths were classified by `v1-classify.py` `[EVIDENCE: v1-verdict.txt, v1-normalized.txt]`:

| Class | Paths | Meaning |
|---|---|---|
| PATH | 61 | only the per-build directory `/build/snapcraft-frigate-<hash>/` differs (shebangs, `.pc`, `_sysconfigdata`, Makefile) |
| PATH+BUILDID | 51 | ELF, equal once `.note.gnu.build-id` is removed and the path normalized |
| PATH+BUILDID+DEBUG | 28 | ELF, also equal after `--strip-debug` (path-dependent DWARF offsets); code and data equal |
| PATH+BUILDID+DEBUG+TIME | 1 | `libpython3.11.so.1.0`, which also carries a `__TIME__` build stamp |
| RECORD-NOISE | 42 | dist-info RECORD lines that only hash files of the classes above |
| CONTENT | 12 | reviewed by hand, below |

The 12 CONTENT paths:

- **7 expected launcher and probe files** (`bin/frigate-run`, `bin/imports-probe`, `bin/lib-wait.sh`, `bin/validate-config`, `probes/probe_common.py`, `probes/probe_coral.py`, `probes/probe_runtime.py`): the M7c source changes `[EVIDENCE: v1-expected.txt]`.
- **`snap/snapcraft.yaml`** equals git `9a2e833` (PR #9) and `8225143` (rev 7) respectively: the M7c source diff itself. It shows here, and did not in Part 1's V1, because a local `snapcraft pack` ships no `snap/snapcraft.yaml` or `snap/manifest.yaml`.
- **`snap/manifest.yaml`**: build-info only (start time, the same yaml diff, the build-dir hash). The 55 pinned stage debs are identical.
- **`meta/snap.yaml`**: the arm64 experimental paragraph in the description.
- **fastapi-cli 0.0.33 → 0.0.34** (`fastapi_cli/__init__.py`, `fastapi_cli/config.py`, and the 6 ADDED plus 6 REMOVED dist-info files). This is a floating transitive dependency: fastapi 0.116.2 requires `fastapi-cli[standard-no-fastapi-cloud-cli]>=0.0.8`, and the snap does not pin it, so every rebuild takes the newest. The new version imports `tomllib` without a `tomli` fallback, which is stdlib on Python 3.11. Frigate serves with uvicorn and never runs the fastapi CLI, so no runtime path changes. **Not an M7c change** (CI finding C3).

The T8 artifact checks also hold on PR #9 amd64: `libpython3.11.a` 0 entries, `intel-opencl` 1 entry and no `.keep`, `libedgetpu.so.1*` 2 entries. The size is +4,096 B (+0.0004 %) `[EVIDENCE: v1-verdict.txt]`.

## V3b in detail

The arm64 and amd64 censuses (174 lines each) have the same names and versions except one line: amd64 ships `tensorflow_cpu 2.19.1`, arm64 ships `tensorflow 2.19.1`. This is the expected difference: on aarch64 the snap ships the full `tensorflow` 2.19.1 wheel in place of `tensorflow-cpu` (research §1.3, as cited in spec §7.2), and V6 imported it on arm64 `[EVIDENCE: v3b-name-version.diff, battery/v6-imports.json]`. Every platform-specific arm64 tag is `aarch64`.

INFO: `tensorboard-data-server 0.7.2` is `py3-none-any` on arm64 and `py3-none-manylinux_2_31_x86_64` on amd64. On arm64 it resolved to the pure wheel without the bundled server binary. Frigate does not use TensorBoard.

---

## Emulation speed (the reason for the stop)

- **Step A measurement** (inside the suite lock, VM idle): the scale benchmark took `vm_ms=1966` in the guest against `host_ms=103` on the laptop. That is **19.1×**. `SPIKE_TIME_SCALE = ceil(vm/host)` = 20, the clamp maximum `[EVIDENCE: t15-a-boot.txt, t15-scale.txt]`. T11 had measured `vm_ms=1671` for the same benchmark `[REPORT: Part 1]`.
- **The VM:** qemu TCG, `-cpu cortex-a76` (D22), 4 vCPUs, 8 GB, 4096-byte pages, CPU part 0xd0b, snapd 2.78. Boot took 149 s `[EVIDENCE: t15-a-boot.txt]`.
- **Consequence:** the battery is about 1 hour of real-hardware waits, which becomes about 22 hours at ×20. The V8 harness was estimated at 6 to 12 hours after that.
- **Host load:** during the 7-hour run the laptop's 1-minute load averaged 5.25 (min 3.23, max 9.60) over 49 five-minute samples on 14 cores `[EVIDENCE: load-log.txt]`. Other jobs waited for the shared suite lock for hours.
- **Thin clamp margin:** the clamp left little headroom: 20 against a measured 19.1. The battery's own margins were large (V5's services came up about 3 minutes after connect, against a 12,000 s budget), so this did not threaten the battery. The V8 harness has tighter scaled bounds (follow-up F2) and would have been more sensitive.
- **The decision:** the maintainer decided at 12:56 CET to stop the VM run and verify on the hub instead.

---

## The D13b memory cap: no number yet, and caveats

D13b sets the hub's quota from V10: 1.5 × the V10 peak, rounded up to 0.5 GB, floor 2 GB. **V10 did not run in the VM, and the hub's stand-in measurement is not a basis for the number either (below), so this document does not set it.** The hub's quota group was set from the spec's H3 value (4 GB) and stays there.

Caveats for whoever computes it from a hub measurement:

- **The battery's V10 is narrower than the spec.** It reads `MemoryPeak` of `snap.frigate.frigate.service` only, while spec §9 V10 asks for `MemoryPeak` per `snap.frigate.*` unit. A cap for the whole group should sum the units (or read the quota group's own current memory) and use `anon + shmem` for the unreclaimable part (§7.2). `MemoryCurrent` includes reclaimable page cache from recording writes.
- **The workload differs.** The VM fixture ran the CPU detector on two 640×360 test cameras. The hub was meant to run the Coral with real cameras, so a VM number would not have carried over unchanged anyway.
- **What the hub showed** (stand-in, section "Results on the Pi hub"): in run 2 the group's `MemoryPeak` reached 3,814 MiB, and in run 3 3,815 MiB, against a `MemoryMax` of 3,815 MiB, which is the 4 GB cap itself, while anon stayed at 1,008 to 1,090 MiB and shmem at 172 to 198 MiB `[HUB: observe-*/results.txt, run2/observe-*/results.txt, run3/observe-*/results.txt]`. The rest was page cache from recording writes, which the kernel reclaims at the cap. So the rule must use **anon + shmem**, not raw `MemoryPeak`: a cap computed from `MemoryPeak` would only reproduce whatever cap was set.
- **Why the stand-in is not the basis.** The largest sampled anon + shmem is 1,271 MiB (run 3 at 7 h 40 min), 46 MiB above the largest of runs 1 and 2 (1,225 MiB). The rule applied to it would still give the 2 GB floor, but only just: 1.5 × 1,271 MiB is 1,907 MiB, about 2.0 GB. That is **not adopted**: the samples are nine point readings (cgroup v2 records no anon peak), anon was still rising when run 3 ended (below), the stand-in had no detection load (detection_fps 0), and no run lasted 24 h. The measurement shows only that nothing in 7 h 40 min came near an OOM under a 4 GB cap.

---

## CI and harness findings (none of them is an M7c functional failure)

- **C1: the arm64 artifact never reached the Store from CI.** In CI run 43520710606 Launchpad built both arches, but the arm64 download inside CI was cut off (IncompleteRead). Retries 2 and 3 asked for a different build id, because snapcraft derives the id from an md5 over the project directory and the amd64 `.snap` fetched by attempt 1 changed that directory. So only amd64 was uploaded (Store rev 8). The fix is committed on its own branch (`fix/remote-build-fetch-recover`, `bea5564`) and goes in its own PR after PR #9 `[REPORT: W-7 card, follow-ups F6 and F7]`.
- **C2: every push to the PR branch starts a full rebuild.** For `pull_request` events, the workflow's `paths` filter is evaluated on the whole PR diff, not on the pushed commits. So a push that touches only `tests/**` also starts "PR Build Snap" (about 4.5 h of Launchpad), which would replace the gated revision on `latest/edge/PR9`. The rule adopted: push to the PR branch once, right before the merge, and cancel any rebuild started by mistake `[REPORT: orchestrator]`.
- **C3: fastapi-cli is unpinned** (V1 above, follow-up F5). Pin it, or accept the drift.
- **C4: amd64 gate run 1 had a harness race in the cert-profile block, now fixed.** The configure hook's `snapctl restart` returns before nginx has loaded the new certificates, and the harness then deleted them and restarted nginx several times inside systemd's 5-starts-per-10-s window. Two fixes, both tests only:
  - `16c091c`: `tests/lib/nginx-settle.sh` waits for a new MainPID, an active unit and a TLS handshake on :8971 before the delete (12 tests, 4 mutations caught).
  - `09667c7`: `systemctl reset-failed` before each of the harness's own nginx restarts.

  A separate worker validated it: 0 failures in 9 trials against 1 in 5 for the old order. The amd64 gate then passed `[REPORT: W-7 card, report 34; orchestrator]`.
- **C5: the battery gained a file mode** (`battery.sh --file <guest path> <sha256>`, commit `8821841`), because the snap is private. V5 copies the file to the guest disk, hashes the copy and installs it `--dangerous` only on a match. The Store-only parts (F11, V17 refresh-under-hold and `snap download`) print INFO "not exercised". A stub-driven test covers both modes (36 checks).
- **C6: VM tooling.**
  - `vm.sh down` reports "stopped" about 5 s before qemu exits. qemu removes its pidfile before exiting, and `alive()` reads the pidfile. This is harmless for a single shutdown and is worth fixing before the VM is used again. It is related to follow-up F3 (pidfile trust).
  - `flock` must use `-o`, so that a daemonized qemu does not inherit the lock fd (follow-up F4). The T15 runs used `flock -o`.

---

## Verification moved to the hub (maintainer's decision, 2026-11-14)

The maintainer stopped the emulated run ("Run it on the Pi"). The hub replaces the VM as the arm64 verification. The full battery is **not** run on the hub: the trial steps (spec §8 H4 to H6, the Coral) replace the synthetic V7, V9 and V10 natively. They were planned with the real cameras; because the cameras refuse RTSP, they ran on the synthetic stand-in (next section). V11 as written (a quota below the peak, to provoke OOM or swap on the NVMe it shares with Home Assistant), V-OV at start, and V17 are dropped for the hub. Every hub step needs the maintainer's go (D14). No worker connects to the hub.

Tooling prepared for it (tests only, run by the orchestrator through its existing ssh master):

- `tests/hub/ssh-exec.sh`: runs one command, or copies one file, through the existing master only. It uses `-F /dev/null`, `ControlMaster=no`, `ProxyCommand=/bin/false` and `BatchMode=yes`, so a lost master exits 3 and never opens a new connection.
- `tests/hub/probe.sh`: one-shot stopped-state checks after H3. They are the version and installed bytes, the plugs, the D7 layout, V6 (the tensorflow import under `nice -n 19`) and V18 with the Coral present (the delegate must load and infer).
  It also runs **V-OV (stopped)**. The shipped `lib-wait.sh` D10 guard functions run in the snap's own shell on the real arch, with `snapctl get detector` stubbed to `ov`. **This is a stopped-state guard check only: the start-time behaviour of an openvino config on arm64 is NOT PROVEN.**
- `tests/hub/make-config.sh`: builds the D21 hub `config.yml` from the rendered H4 config plus the two cameras. The edits are:
  - go2rtc main and sub streams;
  - detect on the sub stream at its native size and 5 fps, record on the main stream;
  - the testclip camera removed, MQTT off, `hwaccel_args: ""`, `continuous.days: 1`, and alerts and detections retained for 1 day;
  - go2rtc RTSP and WebRTC bound to loopback, because the restream has no login (W-16).

  It writes the file over the master by stdin and validates it without starting the NVR. Camera logins never appear on a command line, in output, or on disk.
- `tests/hub/watch.sh`: the read-only §8 stop-rule watcher. It is detect-only by default; `--act` stops frigate.

**Results:** section "Results on the Pi hub" below.

**Still NOT PROVEN, after the hub runs as well:** Store auto-connect (F11) and refresh-under-hold on arm64; the D13b number; V11's swap-or-OOM behaviour; V17 and the F10 purge residue on arm64; the full V8 denial harness on arm64 (the hub's denials were only read, not tested arm by arm); and the start-time D10 behaviour.

## Synthetic H.265 stand-in for the Pi trial (W-7 Q7, answer 1)

At the first H5 start both cameras refused RTSP (connection refused on port 554), so the maintainer chose synthetic H.265 streams as the camera stand-in. The purpose is native decode CPU, the memory peak and shm numbers on the Pi under load (spec §7.2, §7.3), with the hub's Coral doing the inference. The tooling (tests/** only, laptop side):

- `tests/hub/make-clips.sh` makes two clips on the laptop with libx265 from the snap's own ffmpeg 8.0 tree, extracted from the sha-checked local amd64 file. The clips are:
  - `main-1080p25.mp4`: 1920x1080, 25 fps, ~1.6 Mbit/s, matching the cameras' main stream as measured;
  - `sub-360p15.mp4`: 640x360, 15 fps, ~256 kbit/s. This is spec §7.3's first row and the V7 precedent; the bitrate is an ESTIMATE.

  The picture is static bars, a moving box (`--motion`, % of the frame) and light temporal noise. The encoding is a closed GOP with an IDR every 2 s, no B-frames, tag hvc1, and a duration in whole GOPs, so the loop seam is an IDR. Every clip is checked before it is moved into place. With tag hvc1 the MP4 muxer keeps VPS/SPS/PPS in hvcC only; over RTSP they travel in the SDP.
- `tests/hub/make-config.sh` with `M7C_SOURCE=clip` reads nothing in the private env dir. Its cameras are go2rtc `exec:` sources that loop the clips with the snap's ffmpeg and `-c copy`, so nothing is re-encoded on the hub:
  - cam1 is the 1080p25 clip on ONE input with roles detect+record. It is detected at its native size, the worst case.
  - cam2 records the 1080p25 clip and detects the 360p15 clip.

  The fallback lever, if decode cannot keep up, is detect at 1280x720 (spec §7.3 row 3).
- `tests/hub/serve.test.sh` runs that path end to end on laptop loopback: the snap's generator, the snap's go2rtc 1.9.14 and decoding consumers.
- `tests/hub/observe.sh` is the read-only one-shot measurement at ~30 min and ~24 h. It covers slice and unit memory and CPU, cpu.stat throttling, per-process %CPU, the go2rtc exec ffmpegs and their restarts, shm, Frigate's /stats, the Coral, and host pressure.

**Finding (fixed before the hub): go2rtc 1.9.14 collides on identical exec source lines.** cam1 and cam2 loop the same clip. With byte-identical exec lines and both consumers starting at once (as Frigate's start does), one consumer got RTSP `DESCRIBE 404`, and go2rtc ran 2 exec ffmpegs instead of 3. This happened in 3 of 3 rounds on the laptop; with distinct lines it was 0 of 5. Each line now carries `-metadata title=m7c-<stream>`, which only names the SDP session. make-config tests that the lines are distinct, and serve.test catches the reverse mutation.

**Loopback evidence** (amd64 binaries, unconfined): three simultaneous 10 s decoding consumers on 4 s clips, each crossing at least two loop seams:
- cam1: 250 frames at 1920x1080;
- cam2: 250 frames at 1920x1080;
- cam2_sub: 150 frames at 640x360.

On all three, pts were strictly increasing and there were 0 decode error lines, 3 exec ffmpegs and 0 go2rtc ERR lines.

Since then shown on the hub: validate-config accepted the exec lines `[REPORT: orchestrator]`, and under the hub's confinement go2rtc ran all three exec ffmpegs, reading the clips, for up to 27,608 s (run 3) without a restart `[HUB: observe-2h/results.txt, run3/observe-6h/results.txt]`. The first hub observe failed both cameras only because observe.sh compared camera_fps with the clips' native 25 and 15 fps. Frigate's camera_fps is the detect rate (5), so the check now uses the detect fps (commit `77d4169`) `[HUB: observe-start-first-wrong-fps-expectation/results.txt]`.

**NOT PROVEN by the stand-in:**
- the real cameras' RTSP (they refuse it today), logins, reconnects, packet loss and timestamp jumps;
- real keyframe intervals, VBR and I-frame bitrate spikes, and night/IR scene changes;
- the cameras' real sub-stream size and fps (unknown, so cam2 is an assumption);
- object load: there are no people or cars in the picture, so the Coral, the tracker and the review work see little.

The synthetic motion is constant, which is pessimistic for motion detection and optimistic for object detection.

## Results on the Pi hub (Raspberry Pi 5, aarch64, Ubuntu Core, snapd 2.78)

**In one line:** the exact arm64 file installs, starts, runs the stand-in stably for 7 h 40 min (run 3, the longest of three runs) and loads the Coral on aarch64. Real-camera and long-run (24 h) behaviour, the Coral under real detection load and a graceful stop are not proven. Every hub step ran on the maintainer's go and was run by the orchestrator; no worker connected to the hub (D14). Times are CET. MB and GB in the observe and watcher lines are 2^20 and 2^30 bytes (MiB and GiB); quota sizes set with `snap set-quota` are decimal (4 GB = 4,000,000,000 B, which the slice shows as `MemoryMax` 3,815 MiB).

### Install and stopped-state probe (H1 to H4)

- **The file.** The PR #9 Launchpad arm64 file (sha256 `26db6fb77d2214c030bfb9da0b533edb0935cd49d376b010347a607e9b6200f4`) was copied over the hub's SSH connection and installed with `snap install --dangerous`. The hub holds it as revision `x1` with publisher `-` and the note `held`, and the installed file hashes to the same sha256 `[HUB: probe-20261114T140443/snap-list.txt, snap-sha256.txt]`. A `--dangerous` install carries no Store assertions, so a Store refresh, `snap revert` to a Store revision and Store auto-connect do not apply to it.
- **The quota group** `frigate-mem` holds only frigate, with memory 4.00 GB and CPU 2 × 100 % `[HUB: h5-idle-20261114T140829.txt]`. The slice shows it as `MemoryMax` 3,815 MiB and `CPUQuotaPerSecUSec=2s`, i.e. at most 2 of the 4 cores `[HUB: observe-*/results.txt]`.
- **The probe** (`tests/hub/probe.sh`, Frigate stopped) printed 7 PASS lines and 0 FAIL `[HUB: probe-20261114T140443/results.txt]`:
  - V5 version (0.18.2, frigate and go2rtc stopped), V5 bytes, V5 plugs (raw-usb, hardware-observe, mount-observe and shm-private connected) and V5 layout (D7: `/etc/OpenCL/vendors` and `intel-opencl` each list exactly `.keep`);
  - V6: 18 imports including sqlite_vec, 4 HEVC decoders, ffprobe `n8.1.1-9-g58d4114d36-20260602`;
  - V18 with the Coral present: dlopen of the aarch64 `libedgetpu.so.1`, `load_delegate` ok and one inference ok. The Coral's USB id changed from `1a6e:089a` to `18d1:9302` at the first load, which is the normal re-enumeration;
  - V-OV (stopped): on arm64, `detector=ov` renders the cpu detector with the D10 WARN, and an openvino config is recognised. This is a stopped-state guard check only.

  The imports probe also printed joblib's `[Errno 13] Permission denied. joblib will operate in serial mode` warning `[HUB: probe-20261114T140443/imports-probe.txt]`. It did not fail any import. Whether amd64 prints the same was not checked here.
- **Network exposure.** At the first start only port 8971 (nginx, TLS) listened on a non-loopback address. go2rtc's RTSP and WebRTC listeners are bound to loopback by make-config, and its API to loopback by the generator `[REPORT: orchestrator, W-7 decision 4]`.
- **First start, real-camera config (H5).** Frigate ran 2 min 50 s with both cameras refusing RTSP and was then stopped `[HUB: journal-excerpts.txt]`. The quota group used 966 MB (snap's figure), with slice `MemoryCurrent` 965,820,416 B, `MemoryPeak` 980,598,784 B and `/dev/shm/snap.frigate` 139,102,669 B. The host showed load 0.44 and swap 0 `[HUB: h5-idle-20261114T140829.txt]`. Without camera input, this is an idle footprint, not a workload number.

### The workload: the synthetic stand-in, and what it does not exercise

The cameras refuse RTSP (connection refused on port 554 for all four stream URLs) `[REPORT: orchestrator]`, so **no real-camera run exists**. All three runs used the stand-in from the previous section:

- two looped H.265 clips, 180 s each, played into go2rtc by exec ffmpeg sources;
- cam1 detects and records the 1080p25 clip;
- cam2 records the 1080p25 clip and detects a 640x360, 15 fps clip;
- detect fps 5, MQTT off, `hwaccel_args: ""`, the Coral as the detector.

What it does **not** exercise:

- **The Coral is barely used.** detection_fps was 0 in every snapshot, because the picture has no objects to detect. The detector's `inference_speed` of 10 ms is **not a measurement**: it is the value Frigate gives the counter at start (`Value("d", 0.01)` in `frigate/object_detection/base.py` of the shipped tree), and no detection ever updated it.
- **No real camera behaviour:** no reconnects, no real keyframe intervals or bitrate spikes, no audio, no night or IR changes.
- **No motion or object load beyond the clip's moving box:** no tracking, review items or snapshots of real objects.

### Run 1: 14 Nov, about 15:19 to 16:58 (1 h 39 min)

- **Timeline.** The watcher started at 15:18:54 and its last sample was at 16:58:53, after the stop `[HUB: watch-act-final-before-reboot.log]`. That file is byte-identical to `watch-20261114T151854.log`. Run 1 was stopped before a planned laptop reboot `[REPORT: W-7 decision 5]`.
- **Snapshots.** observe.sh ran three times, at Frigate uptimes of 192 s, 1,898 s and 5,884 s (3 min, 32 min and 1 h 38 min). Each printed 7 PASS lines and 0 FAIL `[HUB: observe-start, observe-30min, observe-2h]`. The very first observe at 3 min printed 2 FAIL lines; the two-line fix is described in the previous section.
- **Stability.** The same three exec ffmpeg PIDs ran through all three snapshots, 5,882 s at the last one. NRestarts was 0 for all four units `[HUB: observe-2h/results.txt]`.
- **Watcher** (stop rules, act mode, 199 samples at 30 s): 0 TRIP lines. Frigate's NRestarts stayed 0, and the Home Assistant unit kept the same MainPID with 0 restarts. Its container stayed running with RestartCount 0 `[HUB: watch-act-final-before-reboot.log]`.

### Run 2: 14 Nov, 19:08 to the hub reset at 22:12:47 (3 h 05 min)

- **Timeline.** The watcher started at 19:08:00 and logged its last sample at 22:12:49 (laptop clock). At 22:13:48 it logged `MASTER GONE ... the watcher is BLIND and cannot stop frigate (exit 3)` `[HUB: run2/watch-act-run2-19h08-to-22h13.log]`. That exit is the designed behaviour when the SSH master disappears.
- **The reset.** The hub's journal for that boot ends at 22:12:47 (21:12:47 UTC) `[HUB: journal-excerpts.txt]`, mid-stream, with no shutdown sequence, no panic and no under-voltage line. It was the maintainer's own reboot, not a fault `[REPORT: orchestrator, W-7 decision 11]`.
- **Snapshots.** observe.sh ran at Frigate uptimes of 282 s and 1,973 s (5 min and 33 min), 7 PASS and 0 FAIL each `[HUB: run2/observe-start, run2/observe-30min]`. The exec ffmpegs kept the same PIDs, 1,972 s at the second snapshot.
- **After the reset.** Frigate started by itself at boot; the reason is under finding b below. One snapshot at uptime 221 s (about 4 min) printed 7 PASS and 0 FAIL, with NRestarts frigate=1 and the others 0 `[HUB: run2/observe-after-reset/results.txt]`.
- **A second reboot.** The maintainer rebooted the hub a second time at about 22:22: that boot's journal ends at 21:22:07 UTC `[HUB: journal-excerpts.txt]`. Frigate had already been stopped at 22:18 (journal) and disabled `[REPORT: orchestrator]`, so this did not affect the run. The next boot, today's, began at about 22:23 CET on 14 Nov `[REPORT: orchestrator]`.
- **Watcher** (367 samples at 30 s): 0 TRIP lines, Frigate NRestarts 0 until the reset, and the Home Assistant unit and container untouched `[HUB: run2/watch-act-run2-19h08-to-22h13.log]`.

### Run 3: 15 Nov, about 11:49 to the planned stop at 19:29:35 (7 h 40 min)

- **Timeline.** Frigate's start, the first of that boot, worked at once (finding b), and the run ended with the planned stop, issued at 19:29:35 `[HUB: run3/stop-journal-excerpt.txt]`. The last snapshot saw a Frigate uptime of 27,606 s (7 h 40 min) `[HUB: run3/observe-6h/results.txt]`; its directory is named `observe-6h`, but that name is only a label. The watcher ran from 11:48:45 to 19:30:08 (laptop clock) `[HUB: run3/watch-act-run3.log]`.
- **Snapshots.** observe.sh ran at Frigate uptimes of 463 s, 1,974 s and 27,606 s (8 min, 33 min and 7 h 40 min), 7 PASS and 0 FAIL each `[HUB: run3/observe-start, run3/observe-30min, run3/observe-6h]`. Their numbers are in the table below.
- **Stability.** NRestarts was 0 for all four units at every snapshot. The same three exec ffmpeg PIDs ran throughout, 27,608 s at the last snapshot (`none restarted since --prev`) `[HUB: run3/observe-6h/results.txt]`.
- **Memory.** anon went from 1,049 MiB (8 min) to 1,057 MiB (33 min) to 1,090 MiB (7 h 40 min): 33 MiB over the last 25,632 s, about 5 MiB per hour. These are three point readings, so they do not show whether anon levels off; **anon is not shown flat, and a 24 h run is needed for that**. shmem was 174, 180 and 181 MiB and `file` 969, 1,564 and 2,564 MiB. At the end, anon + shmem was 1,271 MiB, 46 MiB above the largest reading of runs 1 and 2 (1,225 MiB). The slice stood at the cap: `MemoryCurrent` 3,798 MiB, `MemoryPeak` 3,815 MiB, `MemoryMax` 3,815 MiB `[HUB: run3/observe-*/results.txt]`.
- **CPU.** Over the 25,632 s between the 33-min and the last snapshot, the slice averaged 0.88 cores (frigate 0.83, go2rtc 0.05). The 2-core quota throttled 3,778 of 256,324 periods (1.5 %), 460 s in total `[HUB: run3/observe-6h/results.txt, "cpu since --prev"]`.
- **shm.** `/dev/shm/snap.frigate` was 173,422,213 B (165 MiB) with 50 frame files per camera in all three snapshots.
- **Watcher** (act mode, 915 samples at 30 s, 913 of them while Frigate ran, i.e. up to 19:29:08) `[HUB: run3/watch-act-run3.log]`; the figures below were recomputed from the log while writing this `[VERIFIED: recomputed from run3/watch-act-run3.log]`:
  - **0 TRIP lines.** Frigate's NRestarts stayed 0. The Home Assistant unit kept the same MainPID with 0 restarts (NRestarts 1 from before the run, unchanged), and its container stayed running with RestartCount 0.
  - **MemAvailable** 13,046 to 14,451 MiB.
  - **Swap** was 0 until 13:15, rose to 16 to 17 MiB by 13:50 and then slowly to 23 MiB (18:43), its maximum. After the stop it fell to 9 MiB and then 0.
  - **Disk free** went from 199 to 190 GiB (1 GiB resolution, not monotonic), about 1.2 GiB per hour.
  - **Home Assistant** answered HTTP 200 in 11 to 53 ms in 912 of the 913 samples. The exception is one sample at 13:02:58, where the TCP connect to its port failed (`tcp=1`) and no status line came (`http=none`, 19 ms); the samples 30 s before and after were HTTP 200. The cause was a requested Home Assistant restart, not Frigate: a restart service call with no user context at 13:02:28, after which Home Assistant stopped at once, listened again at 13:03:07 and was fully up at 13:03:20; Home Assistant's own recorder and logs showed nothing pointing to Frigate `[REPORT: Home Assistant orchestrator]` (a peer's reading of those logs, not checked here). The watcher's Home Assistant counters (unit MainPID and NRestarts, container StartedAt and RestartCount) cannot see such a restart, because the container image's own supervisor restarts the process in place, inside the same container, so they stayed unchanged and only the failed probe showed it. The watcher's rule needs 3 failed probes in a row, so it did not trip. Runs 1 and 2 had no such sample.
  - **Load.** The 1-minute load averaged 1.24 (max 5.96). 9 of the 913 samples were above 3.5, the load rule's threshold: 12:06 (3.55), 14:00 (4.40), 14:01 (3.54), 15:00 (5.96), 15:01 (4.11), 18:00 (3.61), 19:00 (4.88 and 3.89) and 19:21 (3.62). They came in bursts of 1 or 2 samples, 7 of the 9 within the first two minutes of an hour. The rule needs load above 3.5 for 10 minutes, so none came near a trip. At the 3.0 level used for runs 1 and 2, with consecutive samples grouped into one burst and a burst's length counted from its first to its last sample (the counting used for runs 1 and 2), run 3 had 24 bursts: 12 of a single sample (length 0), 6 of 0.5 minutes, 5 of 1.0 and 1 of 1.5. Most were shorter than in runs 1 and 2 (1.0 to 3.0 minutes, counted the same way): 18 of the 24 were 0.5 minutes or less, and none was longer than 1.5. Several again came about 16.6 minutes apart. **The cause of the load bursts is not identified.**
- **The stop** at 19:29:35 was SIGKILLed after the 30 s timeout, like every earlier stop of a running Frigate (finding a), and left `/dev/shm/snap.frigate` behind (finding d) `[HUB: run3/stop-journal-excerpt.txt]`.

Later runs get their own subsection after this one.

### Numbers

Per snapshot, from observe.sh (cores and %CPU over its 10 s window; 100 % = one core) `[HUB: observe-*/results.txt, run2/observe-*/results.txt, run3/observe-*/results.txt]`:

| Snapshot (Frigate uptime) | slice MemoryCurrent / Peak MiB | anon MiB | shmem MiB | file MiB | slice cores | cam1 detect ffmpeg | cam2_sub detect ffmpeg | throttled periods | Home Assistant |
|---|---|---|---|---|---|---|---|---|---|
| run 1, 192 s | 1,329 / 1,351 | 1,008 | 172 | 280 | 0.89 | 52.7 % | 5.8 % | 0 of 101 | 15 ms |
| run 1, 1,898 s | 2,033 / 2,049 | 1,016 | 185 | 953 | 0.89 | 51.9 % | 5.7 % | 1 of 101 | 13 ms |
| run 1, 5,884 s | 3,653 / 3,673 | 1,027 | 198 | 2,511 | 0.90 | 53.1 % | 6.0 % | 0 of 102 | 12 ms |
| run 2, 282 s | 3,736 / 3,750 | 1,018 | 176 | 2,604 | 0.94 | 52.1 % | 8.1 % | 0 of 101 | 12 ms |
| run 2, 1,973 s | 3,244 / 3,814 | 1,024 | 188 | 2,114 | 0.94 | 52.4 % | 8.2 % | 0 of 101 | 16 ms |
| after reset, 221 s | 2,011 / 2,027 | 1,044 | 172 | 909 | 0.69 | 42.6 % | 4.7 % | 1 of 101 | 24 ms |
| run 3, 463 s | 2,074 / 2,092 | 1,049 | 174 | 969 | 0.87 | 52.3 % | 5.8 % | 1 of 101 | 13 ms |
| run 3, 1,974 s | 2,696 / 2,715 | 1,057 | 180 | 1,564 | 0.88 | 53.4 % | 5.8 % | 0 of 102 | 17 ms |
| run 3, 27,606 s | 3,798 / 3,815 | 1,090 | 181 | 2,564 | 0.85 | 51.3 % | 5.6 % | 0 of 102 | 12 ms |

- **Memory.**
  - The unreclaimable part (anon + shmem) stayed between 1,180 and 1,225 MiB in every snapshot of runs 1 and 2. In run 3 it was 1,223, 1,237 and 1,271 MiB, with anon still rising at the end (Run 3 above).
  - Page cache (`file`) grew from recording writes. It took the slice from 2,033 to 3,653 MiB between the 30-min and the 1 h 38 min snapshots of run 1 `[HUB: observe-2h/results.txt, "memory since --prev"]`.
  - In run 2, `MemoryPeak` reached 3,814 MiB against `MemoryMax` 3,815 MiB, i.e. the cap, and `MemoryCurrent` was back at 3,244 MiB: the kernel reclaimed cache at the cap. No unit restarted.
  - The page cache charged to the quota group survived the stop between the runs: run 2 began at 3,736 MiB for the slice while the frigate unit itself held 1,273 MiB.
  - What this means for D13b is in the D13b section above.
- **CPU.**
  - Over the 3,985 s between run 1's second and third snapshots, the slice averaged 0.90 cores (frigate 0.86, go2rtc 0.04). The 2-core quota throttled 449 of 39,852 periods (1.1 %), 42.9 s in total `[HUB: observe-2h/results.txt, "cpu since --prev"]`.
  - Decoding the 1920x1080 25 fps clip at its native size (cam1's detect ffmpeg, CPU decode) took 51.9 to 53.1 % of one core in steady state; the 640x360 15 fps clip took 5.7 to 8.2 %.
  - The after-reset snapshot is lower (42.6 % and 4.7 %). Its cause was not investigated; it came 4 minutes after a cold boot.
  - Run 2 has no long-window average, because no observe in run 2 was taken with `--prev`. Run 3's, over 25,632 s, was 0.88 cores with 1.5 % of periods throttled (Run 3 above).
- **Cameras.**
  - camera_fps was 5 or 5.1 against detect fps 5 on both cameras in all nine snapshots, with skipped_fps 0, so the decode kept up with real time.
  - The 3 exec ffmpegs ran 5,882 s in run 1 and 27,608 s in run 3 without a restart.
- **shm.** `/dev/shm/snap.frigate` was 173,422,202 to 173,427,663 B (165 MiB), with 50 frame files per camera in every snapshot.
- **Host** (the watcher's 30 s samples, runs 1 and 2; run 3's are in its subsection) `[HUB: watch-act-final-before-reboot.log, run2/watch-act-run2-19h08-to-22h13.log]`:
  - **MemAvailable** never below 13,016 MiB.
  - **Swap** 0 in run 1. In run 2 it rose from 0 to 1 MiB at 20:55 and to 17 MiB by the last sample at 22:12:49. The after-reset snapshot shows 0.
  - **Disk free** on the data filesystem went from 206 to 203 GiB in run 1 and from 203 to 199 GiB in run 2 (1 GiB resolution). That fits two recordings of the ~1.6 Mbit/s clip, about 1.3 GiB per hour.
  - **Home Assistant** answered HTTP 200 in every sample, in 11 to 40 ms in run 1 and 11 to 37 ms in run 2.
- **Load bursts.** The 1-minute load averaged 1.45 (run 1) and 1.47 (run 2), with bursts at or above 3.0 that peaked at 4.76 (run 1) and 5.48 (run 2). Each burst lasted 1.0 to 3.0 minutes, counted from its first to its last sample at or above 3.0 (add 30 s to count each sample as 30 s). In run 2 they came every 16.2 to 17.2 minutes; in run 1 every 15.7 to 17.7 minutes, plus one extra 3.21 peak at 16:03. No burst came near the watcher's load stop rule (load above 3.5 for 10 minutes).
  - **Cause unknown.** The interval does not match the 180 s clip loop. The load average is host-wide (Home Assistant included), and nothing here attributes the bursts to a process.

### New findings

- **a. A stop is not graceful: 4 of 4 stops of a running Frigate were killed.** The journal shows three such stops on 14 Nov, at 14:08:37, 16:57:59 and 22:18:39 (13:08:37, 15:57:59 and 21:18:39 UTC as the journal stamps them) `[HUB: journal-excerpts.txt]`. They were the end of the 2 min 50 s first start (H5), the end of run 1, and the stop after the post-reset snapshot. The fourth was the end of run 3, issued at 19:29:35 on 15 Nov; `snap stop` returned after 31.2 s, and `systemctl show` then gave `Result=timeout`, `ExecMainStatus=9` and `NRestarts=0` `[HUB: run3/stop-journal-excerpt.txt]`. That excerpt has no journal timestamps.
  - Each hit `State 'stop-sigterm' timed out. Killing` 30 s after `Stopping`. systemd sent SIGKILL to two python3.11 processes, and the unit `Failed with result 'timeout'`, staying failed until the next start.
  - One more stop, a 2 s start and stop at 13:09 (12:09 UTC), ended cleanly with `db=absent result=nodb`. It is not evidence against: nothing had started yet.
  - **The D24 WAL fix held after each SIGKILL on arm64.** The post-stop `frigate-db-quiesce` hook ran all four times:
    - `db=188416 wal_before=8272 wal_after=absent shm_after=absent result=ok`;
    - `db=5337088 wal_before=4202432 wal_after=absent shm_after=absent result=ok`;
    - `db=15282176 wal_before=2266032 wal_after=absent shm_after=absent result=ok`;
    - `db=34435072 wal_before=5957552 wal_after=absent shm_after=absent result=ok` (run 3: a 5.96 MB WAL checkpointed and removed) `[HUB: run3/stop-journal-excerpt.txt]`.
  - Whether amd64 stops the same way was **not checked**.
- **b. Cold boot after a hub reset: the first start failed on the Coral delegate.** The frigate unit was enabled, so Frigate started by itself at boot.
  - At 22:14:14 (21:14:14 UTC) the first start raised `ValueError: Failed to load delegate from libedgetpu.so.1.0` `[HUB: journal-excerpts.txt]`.
  - The post-stop hook ran on that exit too (`db=15077376 wal_before=absent ... result=ok`). At 22:14:36 systemd logged `Scheduled restart job, restart counter is at 1` and started the unit again `[HUB: journal-excerpts.txt]`.
  - The second start was healthy: 7 PASS, NRestarts frigate=1 `[HUB: run2/observe-after-reset/results.txt]`.
  - **The likely cause, not proven: a race between the first delegate load and the Coral's re-enumeration.** The kernel's Coral USB lines (usb 3-1) `[HUB: journal-excerpts.txt]` show the following:
    - **After every boot**, the Coral re-enumerates at the first load: resets, `USB disconnect`, then `new ... device number 3`.
    - **On the normal boots** this took about 2 s and the first load worked: 14:05:04 to 14:05:06 during the probe (13:05 UTC, the boot before the reset), and 11:49:21 to 11:49:23 today (10:49 UTC), when Frigate's first start worked first time.
    - **On the cold boot after the reset**, the first start's detector attempts came at 22:14:12 and 22:14:14 (frigate.detecto `net_admin` capability lines and Coral resets at the same seconds). The start failed at 22:14:14. The disconnect and `device number 3` came only at 22:14:49, during the second start.
  - If that is the cause, a boot-time wait for the Coral (or a retry of the first delegate load) would avoid the failed first start. That is a snap change and is not made here.
- **c. The hub has no RTC.** Right after a boot, journal timestamps are stale until time sync steps the clock `[HUB: journal-excerpts.txt]`:
  - every boot's first entry carries the same stamp, 2026-11-04 20:01:48 UTC;
  - every boot's first kernel lines, before time sync, are stamped `1970-01-01T00:00:2x`;
  - the first Frigate start after the reset is stamped 21:12:31 UTC, 16 s before the previous boot's last entry (21:12:47 UTC).

  The first start's real time is therefore later than its stamp. The restart at 21:14:36 UTC agrees with the laptop clock: the after-reset snapshot at about 22:18 CET saw an uptime of 221 s. This is cosmetic, but it matters when reading a journal across a reset.
- **d. Leftovers after a stop.** `/dev/shm/snap.frigate` stays after Frigate stops: after the run-3 stop it still held `166M` as `du -h` prints it (du rounds 165.4 MiB up), "the same leftover as after the earlier stops" `[HUB: run3/stop-journal-excerpt.txt]`. That it stays until the snap is removed (H9) is `[REPORT: orchestrator]`.
- **e. AppArmor denials on the hub: every daemon-profile denial matches the amd64 allowlist; two imports-probe capability lines have no arm.** The orchestrator applied the harness's own allowlist to the hub's journal `[HUB: journal-excerpts.txt]`. The allowlist is the regex of the `UNEXPECTED=` grep at `tests/spike-smoke.sh` line 2090, extracted verbatim from the tree of `758e992`, with sha256 `335df6b66a49b6032d5147e87477a640ae7ac389e53ae75edcc5d00072701b06` as a file with its trailing newline. It was run with `grep -cvE -f` over every `apparmor="DENIED"` kernel line on a `snap.frigate*` profile, over all boots since 14 Nov. The sha256 of that regex, extracted from `758e992`, was recomputed while writing this, as were the two non-matching lines and four matching lines rebuilt from the excerpt `[VERIFIED: sha256 equal; grep -cvE -f on the rebuilt lines]`.
  - **Lines checked:** 11,885 at about 12:05 CET on 15 Nov, with run 3 about 15 minutes in. The class counts below are from an earlier pull of 11,752 lines, so they differ slightly from the 11,885.
  - **Not matching: exactly 2 lines.** Both are on the imports-probe profile at 13:04:58 UTC on 14 Nov, during the stopped-state probe, with comm `python3.11`: capname `dac_read_search`, and capname `dac_override`.
    - `dac_read_search` appears nowhere in `tests/spike-smoke.sh` `[VERIFIED: grep -c dac_read_search tests/spike-smoke.sh = 0]`.
    - The `dac_override` arms are pinned to comm `frigate-run` and `go2rtc-run`. Frigate's own three `dac_override` lines are comm `frigate-run` and match.
    - Whether amd64's imports-probe prints these two lines is **not checked**.
  - **No line from the frigate, nginx, go2rtc, coral-probe or validate-config profiles falls outside the allowlist.**
  - **The classes, from the 11,752-line pull:**
    - **ptrace:** 9,673 (comm `frigate.recordi` 9,164, `python3.11` 509).
    - **open:** 2,058. These are `/proc/PID/cmdline` 2,041 on the frigate profile; `/proc/sys/vm/nr_hugepages` 7 (frigate 6, validate-config 1); `cpu.max` 9 (frigate 8 on `snap.frigate\x2dmem.slice`, validate-config 1 on `system.slice`); and `/usr/share/fonts/` 1 (imports-probe).
    - **exec:** `/usr/bin/lscpu` 2 (imports-probe).
    - **mknod:** 1, imports-probe `/dev/shm/sem.*` at 13:04:59 UTC.
    - **capable:** 18, by profile:
      - frigate: net_admin 8, all comm `frigate.detecto`; dac_override 3, all comm `frigate-run`;
      - coral-probe: net_admin 3;
      - imports-probe: the two lines above;
      - nginx: setgid 2.

  None of the denials caused a failure. recording_manager's ptrace denials are the loudest. This is the harness's regex applied to the hub's journal, not a V8 harness run.
- **f. The first observe's fps expectation was wrong, and is fixed** in `77d4169` (previous section).

### NOT PROVEN on the hub, with the reason

- **A 24-hour soak.** The longest run is run 3, 7 h 40 min, stopped as planned. anon was still rising when it ended (1,057 to 1,090 MiB over its last 7 h 07 min), so a steady state is not shown.
- **Real cameras:** they refuse RTSP.
- **The Coral under real detection load:** the stand-in produced no detections.
- **V11** (a deliberate OOM or swap squeeze): run on no host. It was dropped for the hub because the hub shares its disk with Home Assistant.
- **V-OV start-time behaviour:** only the stopped-state guard check ran.
- **V17** refresh-under-hold and `snap download`, and **F11** Store auto-connect: the snap is private on the Store, and the hub has no Store account.
- **A Store-installed (asserted) arm64 revision:** the same reason. The hub runs the `--dangerous` install `x1`.
- **A graceful stop:** 4 of 4 stops of a running Frigate were SIGKILLed after the 30 s timeout (finding a).
- **The amd64 stop path** (finding a): not compared.
- **The two imports-probe capability denials on amd64** (finding e): whether amd64 prints them was not checked. The hub's lines were checked against the harness allowlist, but no V8 harness ran on arm64.

## Open at the time of writing

- The 24-hour soak (or a decision that the 7 h 40 min stand-in run suffices for an "experimental" arm64 label). It would also show whether anon levels off.
- A real-camera run, once the cameras serve RTSP.
- The D13b number. It needs anon + shmem under real detection load, over a run long enough to show whether anon levels off.
- Finding a: 4 of 4 stops of a running Frigate were killed after the 30 s SIGTERM timeout on arm64. Is that also so on amd64, and should the stop timeout or Frigate's shutdown change?
- Finding d: decide whether a stop should remove `/dev/shm/snap.frigate` (165 MiB stays behind).
- Finding b: confirm the cause (Coral not ready after a power loss) and then decide on a boot-time wait for the Coral. That is a snap change; it was not made here.
- Finding e: two imports-probe capability lines (`dac_read_search`, and `dac_override` with comm `python3.11`) have no allowlist arm. Check whether amd64's imports-probe prints them too, then add arms or explain them.
- C1 (the arm64 Store upload) and follow-ups F1 to F7 on the W-7 card.
