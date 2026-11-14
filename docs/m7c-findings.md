# M7c Findings: arm64 port, Part 2 (census, emulated battery, hand-over to the hub)

**Date:** 2026-11-14  **Snap:** `frigate` 0.18.2 (core26, strict), arm64 and amd64  **PR:** #9, branch `feat/m7c-arm64`, CI-built at head `9a2e833` (later commits on the branch touch only `tests/**` and `docs/**`)  **Spec:** `docs/superpowers/specs/2026-11-13-m7c-arm64-design.md`  **Plan:** `docs/superpowers/plans/2026-11-13-m7c-arm64.md`, Part 2 (T14, T15), both on branch `spec/m7c-arm64-research`.

**Status in one paragraph.** T14 is complete. The arm64 artifact is clean of foreign ELF (V2), its wheel set is the amd64 set with arm64 tags and one justified name difference (V3b), and the amd64 non-regression census against the released revision is fully explained (V1). The arm64 size floor is set from the first real artifact. T15 ran in an emulated Cortex-A76 VM on the local Launchpad arm64 file. It was **stopped by the maintainer's decision** after about 7 hours, because emulation ran about 19× slower than real hardware and tied up the laptop. Before the stop, V5 (bytes, install, layout), V6, V18, V7, V9 and the V9 mutation **PASSED**. V10, V11, V-OV, V-restore, V17 and the V8 full harness were **NOT RUN in the VM**. They are not claimed here. Verification moved to the hub (last section). This document holds no hub results.

**Evidence classes.**

- **`[EVIDENCE: name]`**: a file under the laptop's `~/.cache/frigate-m7c-evidence/part2/` (not committed). Numbers were copied from those files.
- **`[REPORT: …]`**: another worker's or the orchestrator's report on the W-7 card. Not recounted here.
- **`[VERIFIED: …]`**: a command run while writing this document.
- **`[LIVE]`**: none. Nothing here ran on the hub or on a production host.

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
| V10 | memory after 30 min steady state | **NOT RUN in the VM** (stopped during its wait) | `[EVIDENCE: b-stop-record.txt]` |
| V11 | quota rehearsal below the V10 peak, swap enabled | **NOT RUN in the VM** | ditto |
| V-OV | the D10 openvino guard at start | **NOT RUN in the VM** | ditto. A stopped-state check exists for the hub (last section) |
| V-restore | fixture config back, frigate active | **NOT RUN in the VM** | ditto |
| V17 | hold, revert, remove, purge, F10 residue | **NOT RUN in the VM**. The refresh-under-hold and `snap download` parts could not have run anyway (private snap, no Store in the VM) | ditto |
| V8 | full `spike-smoke.sh` harness in the VM (denials, arm64-only arms) | **NOT RUN** (step C cancelled) | ditto |

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

## The D13b memory cap: no VM number, and a caveat

D13b sets the hub's quota from V10: 1.5 × the V10 peak, rounded up to 0.5 GB, floor 2 GB. **V10 did not run in the VM, so this document cannot give that number.** The hub's quota group was set from the spec's H3 value (4 GB) instead.

Caveats for whoever computes it from a hub measurement:

- **The battery's V10 is narrower than the spec.** It reads `MemoryPeak` of `snap.frigate.frigate.service` only, while spec §9 V10 asks for `MemoryPeak` per `snap.frigate.*` unit. A cap for the whole group should sum the units (or read the quota group's own current memory) and use `anon + shmem` for the unreclaimable part (§7.2). `MemoryCurrent` includes reclaimable page cache from recording writes.
- **The workload differs.** The VM fixture ran the CPU detector on two 640×360 test cameras. The hub runs the Coral with real cameras, so a VM number would not have carried over unchanged anyway.

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

The maintainer stopped the emulated run ("Run it on the Pi"). The hub replaces the VM as the arm64 verification. The full battery is **not** run on the hub: the real trial steps (spec §8 H4 to H6, real cameras, the Coral) replace the synthetic V7, V9 and V10 natively. V11 as written (a quota below the peak, to provoke OOM or swap on the NVMe it shares with Home Assistant), V-OV at start, and V17 are dropped for the hub. Every hub step needs the maintainer's go (D14). No worker connects to the hub.

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

**Results:** none in this document. The orchestrator adds the hub results.

**Still NOT PROVEN by anything here:** Store auto-connect (F11) and refresh-under-hold on arm64; the D13b number; V11's swap-or-OOM behaviour; V17 and the F10 purge residue on arm64; arm64-only AppArmor or seccomp denial arms (V8); and the start-time D10 behaviour.
