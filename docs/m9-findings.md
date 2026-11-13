# M9 Findings — Frigate 0.17.2 → 0.18.2 upgrade (final, pre-Launchpad)

**Date:** 2026-11-13  **Snap:** `frigate` (core26, strict, amd64)  **Frigate:** v0.18.2 (latest release, 2026-10-15; re-checked 2026-11-13, nothing newer)  **Branch:** `feat/m9-frigate-0.18`, **local only** (this branch, and only this branch: not pushed, no PR, no Store upload, no Launchpad build)  **Base:** PR #6 head `7a1c663` (`fix/harness-logs-and-soak-sweep`). PR #6, W-11 and W-16 are **not merged** into `main` (`a39bfb0`).

M9 moves the snap from Frigate 0.17.2 to 0.18.2 with one carried Frigate patch (`0001-env-driven-paths`, context-only rebase), upstream-parity pins (ffmpeg trees 5.0/7.0/8.0 with 8.0 default, go2rtc v1.9.14, python-multipart 0.0.26, openvino 2025.4, sqlite-vec 0.1.9, degirum removed), the nginx mirror updates, a new gate section and an upgrade/revert/re-refresh rehearsal script.

**Status in one paragraph.** Everything below that is marked evidence was produced on a **local candidate** (`snapcraft pack`, not the Launchpad artifact) in the `m8-gate` LXD VM. The final local candidate is **pack-5** (1,106,505,728 B, sha256 `bf6d736783447f176bcbf22b5f14f1cd921df1a606e5beee289ed2f54a8805e9`). It passes the final gate (run 6): **184 PASS / 0 FAIL / 21 SKIP, 610 denials / 0 unexpected**. The upgrade, revert, re-refresh, real-thumbnail, backup-retention and retention-deletion rehearsal (#2) ran on it: **86 PASS / 1 FAIL**, the one FAIL being the semantic-search reindex, ruled a non-gating finding that reproduced in 3 of 3 runs (an upstream defect candidate for the maintainer). Phases C, D, E, F and G (revert, re-refresh, D21 retention, no-backup finding, D24 WAL quiesce) are all green. Rehearsal #1 had been red (a stale WAL replayed onto the restored backup); that was fixed in M9 (D24) and is proven in the VM below. **Detection is not proven in the VM** (a known M3 calibration effect; first real proof is on the hub). The Launchpad build, the final gate on its artifact and the size-floor retune have **not happened** (they need credentials that builders do not hold). The OpenVINO GPU path, VAAPI decode, Coral and the fdinfo denial rate are **not proven** by anything here (see "Not proven by the gate VM").

**Evidence classes** (as in M8).

- **`[TRANSCRIPT: name]`**: an on-disk gate transcript under `spike/results/` (gitignored; cited by filename). Counts were taken from those files.
- **`[REPORT: name]`**: the build controller's ledger or a task report under `.superpowers/sdd/2026-11-13-frigate-0.18-upgrade/` (also not committed). Not recounted.
- **`[VERIFIED: …]`**: a command run while writing this document.
- **`[LIVE]`**: none. Nothing here ran on a production host or on the hub.

---

## Labelled deviation: the baseline is Store rev 4, not rev 5

**baseline = rev 4; relevant files identical to main a39bfb0 which is rev 5's source.**

The spec's upgrade rehearsal starts from Store rev 5 (the 0.17.2 snap on `latest/edge`). Rev 5 is private: `snap download frigate --revision=5` and `--channel=latest/edge` both answer "snap not found" without a Store login, and no login was attempted `[REPORT: progress.md, "Rev-5 artifact"]`. The local file `frigate-remote-m8_amd64.snap` (990,572,544 B) is Store rev 4: it was proven against the Store's snap-revision assertion by sha3-384, and its sha256 is `864158f71205fda3fe66e9537d6e0dca337c93a63aff398565f27e84741e1873` (the same value `docs/m8-findings.md` records for rev 4; that file is not on this branch, it lives on branch `docs/m8-findings`, worktree `../frigate-wt-m8-findings`). Rev 5 is a rebuild of rev 4's inputs (`git diff eb512bf bbfb13c` touches only `.gitignore` and `tests/spike-smoke.sh`, per `docs/m8-findings.md` on that branch), and the files that matter for rollback (`meta/hooks/pre-refresh`, `bin/frigate-run`, `bin/go2rtc-run`, `bin/go2rtc-config-gen.py`, `bin/validate-config`) are byte-identical between rev 4 and `main` `a39bfb0` `[REPORT: progress.md]`. The orchestrator accepted this deviation (2026-11-13 02:42). The final gate on the real rev 5 is not done.

---

## Verdict table

Spec §5 items 1–11 (+7a, 7b), `docs/superpowers/specs/2026-11-13-frigate-0.18-upgrade-design.md`. Final candidate = local `snapcraft pack` (pack-5) at `7d6667d`, sha256 `bf6d736783447f176bcbf22b5f14f1cd921df1a606e5beee289ed2f54a8805e9`, **not the Launchpad artifact**. Evidence: gate run 6 (harness `8e9185d`) and rehearsal #2 (script `7d6667d`, baseline Store rev 4, see the deviation above). Earlier packs are listed under Builds.

| # | Criterion (spec §5) | Verdict | Evidence |
|---|---|---|---|
| 1 | Full `spike-smoke.sh` on the Launchpad artifact: 0 FAIL; denials 0 unexpected, new fdinfo arms classified, rate reported | **PARTIAL** (local candidate, not the Launchpad artifact) | **Final, gate run 6** (pack-5, harness `8e9185d`, 08:17 to 08:45): `PASS 184 / FAIL 0 / SKIP 21`, `== denials: 610 total, 0 unexpected ==`, `SPIKE SMOKE: ALL PASS`, rc=0; UI restart MainPID 111230 to 112590, recovery 12 s `[TRANSCRIPT: m9-green-6-candidate.txt; REPORT: progress.md]`. Earlier runs: run 5 (pack-5, harness `7d6667d`) 182/1/21 with 538 denials, 0 unexpected, its one FAIL the pre-existing M8 UI-restart race (plan-defect table), fixed in `8e9185d` `[TRANSCRIPT: m9-green-5-candidate.txt]`; run 3 (pack-3, harness `15a8dae`) 161/0/20, 534 denials `[REPORT: progress.md]`; run 2 (pack-2) 160/0/21, 531 denials `[TRANSCRIPT: m9-green-2-candidate.txt]`; run 1 159/1/21, 514 denials, stale `^0.17.2` literal `[TRANSCRIPT: m9-green-1-candidate.txt]`. The D24 hook added no denial (run 5: 538 total, 0 unexpected). No fdinfo denials could occur (no render node), so no fdinfo arm was added and no rate exists. The Launchpad artifact is **PENDING** the hand-off |
| 2 | Upgrade rehearsal from rev 5 (0.17.2): seeded state, refresh, `frigate-pre-0.17.2-r<rev>.db`, migrations 033/034/035, API still lists seeded data, `config.yml` at `0.18-0`, `backup_config.yaml` equal and 0600, `validate-config` 0 | **MET** (local candidate pack-5; baseline Store rev 4) | Rehearsal #2: `PASS 86 / FAIL 1`, the one FAIL being the reindex finding, not this item `[TRANSCRIPT: m9-rehearsal-final-2.txt; REPORT: progress.md]`. Phase A (3 manual events seeded, export on 0.17.2, recordings, retention row) all PASS. Phase B all PASS except reindex: pre-refresh 0.17.2 backup, hook.log, `backup.db` pre-033, migrations 033/034/035, `exportcase` table and columns, `config.yml` at `0.18-0`, `backup_config.yaml` sha equal and mode 0600, `validate-config`, seeded events by id in the DB and the API, recordings and export listed. Phase D re-ran the migration (below, item 4). **Events are seeded through Frigate's own manual-event API** (`POST /events/testclip/person/create`, admin; v0.17.2 `api/event.py:1738`, v0.18.2 `:1751`), not from detections, because the test clip never triggers a detection in the VM (item 5; orchestrator ruling V1). The mutation run (candidate without migration 033) failed exactly `migration 033_create_export_case_table applied` and `exportcase table` in B, so the check bites `[TRANSCRIPT: m9-mut033-rehearsal.txt; REPORT: progress.md]` |
| 3 | Revert rehearsal: `DOWNGRADE detected`, stamped backup restored, `config.yml` is the 0.17-0 file, 0.17.2 starts, detects and records | **MET with the orchestrator's ruling** (rehearsal #1 red, fixed by D24; rehearsal #2 phase C green) | **"Detects" was replaced by the orchestrator's ruling (V1): 0.17.2 serves the API, captures, records and lists the seeded events by id. Detection itself stays NOT PROVEN in the VM** (item 5). Rehearsal #2 phase C: the candidate's stop quiesced the DB; 0.17.2 serves the API; `DOWNGRADE detected`; the 0.17.2 backup was restored; the restored DB has no 0.18 migration; `integrity_check` `ok` (a 391,432 B WAL existed before the revert, in the FINDING taken while 0.18 still ran); `config.yml` is the pre-refresh 0.17-0 file; 0.17.2 captures `testclip`, writes recordings and lists the seeded events by id. Detection events since the revert: 0 (not provable in the VM). snapd ran no pre-refresh hook on revert (hook.log 1 to 1) `[TRANSCRIPT: m9-rehearsal-final-2.txt; REPORT: progress.md]`. Rehearsal #1 had failed here (see "Revert DB integrity"). The README's revert statement is now confirmed by this run. The gate's own rollback block (a different, M7-style check) passes: `PASS: rollback: downgrade detected + restored` `[TRANSCRIPT: m9-green-6-candidate.txt]` |
| 4 | Re-refresh: migration runs again cleanly from the restored state | **MET** (local candidate) | Rehearsal #2 phase D: 0.18.2 running again; the migration re-ran (fresh `backup.db`); `config.yml` at `0.18-0`; `backup_config.yaml` equal to the pre-refresh copy; migrations 033-035 and `exportcase` present; seeded events by id in the DB and the API `[TRANSCRIPT: m9-rehearsal-final-2.txt; REPORT: progress.md]`. In rehearsal #1 D was red only as a cascade of C |
| 5 | Detection: OpenVINO GPU and CPU, Coral when present; speed against M3/M6 | **NOT PROVEN** (hardware, and no detection in the VM at all) | **Detection is NOT PROVEN in the VM, on any detector.** The looping test clip never triggers motion or detection there: on the candidate the `cpu` detector reports `inference_speed` 10.0 (the never-ran sentinel) and `testclip` reports `detection_fps` 0.0 at `camera_fps` 5.0; no VM run has ever shown a testclip detection `[REPORT: progress.md, MUT033 run 2]`. **Root cause (motion follow-up, 45-minute box, finding only):** motion IS detected on `testclip` (the `latest.jpg` overlay shows large red motion boxes) but no regions are produced, so the `cpu` detector is never called. This is the known M3 calibration finding (`docs/m3-findings.md:64`): `ImprovedMotionDetector` calibration exits only when `pct_motion` < 5% and there are 4 or fewer boxes, and the constantly busy 15 s looped street clip never satisfies that, so it calibrates forever; v0.18.2 `motion/improved_motion.py:192-199` is unchanged. The clip itself is not at fault (1920x1080, 25 fps, 15 s, 375 frames; a frame at 4 s shows about 10 pedestrians and a cyclist). M3's calibration patch was withdrawn (no behaviour patches), so detection in the VM is unprovable by construction `[REPORT: progress.md]`. **The first real detection proof of 0.18 is on the hub with cameras and the Coral (W-7/W-2).** Also in the VM: `SKIP (no capability): gpu: openvino detector reporting … no Intel(0x8086)/AMD(0x1002) render node`, `SKIP (no capability): coral inference ran — no Coral USB TPU`, livecam MONEY lines SKIP `[TRANSCRIPT: m9-green-6-candidate.txt]`. The D7 CPU-only probe is in "Not proven by the gate VM". |
| 6 | ffmpeg 8 pipelines; hardcoded `/usr/lib/ffmpeg/8.0/bin/ffmpeg` (deterministic in-sandbox webp; real export thumbnail in rehearsal); mutation: scratch build without the 8.0 tree makes the check FAIL | **PARTIAL** | Deterministic part met on the candidate: `PASS: m9: 8.0 ffmpeg resolves in the frigate sandbox and encodes webp`, `PASS: ffmpeg tree 5.0/7.0/8.0 present+runs` `[TRANSCRIPT: m9-green-2-candidate.txt]`. Red run on rev 4 FAILs the same checks (no 8.0 tree) `[TRANSCRIPT: m9-red-on-rev4.txt]`, which is a red, not the spec's scratch-build mutation; that scratch-build mutation was **not run**. **Real export thumbnail, met in rehearsal #2 (phase B):** `PASS: B: export thumbnail (.webp via /usr/lib/ffmpeg/8.0) exists and is non-empty`, `PASS: B: export thumbnail is a WebP file`, `PASS: B: nginx serves the export thumbnail as image/webp (:5000 /clips/export/)` `[TRANSCRIPT: m9-rehearsal-final-2.txt]`. Gate run 6 repeats the deterministic checks `[TRANSCRIPT: m9-green-6-candidate.txt]`. Stays PARTIAL only because the spec's scratch-build mutation was not run |
| 7 | Semantic search: vec0 0.1.9 loads on every start; reindex succeeds on a DB with vec tables written by 0.1.3 | **PARTIAL** (vec0 MET; reindex FINDING, 3 of 3 runs) | **Rehearsal exit 0 does not prove the reindex part:** its completion is a `FINDING` line (network-gated model download), not a check, so it needs the findings file read by hand (see "Semantic-search reindex after upgrade" below). `PASS: m9: vec0 loaded` at 8 Frigate starts on the candidate (recounted from the transcript: 8 `PASS` lines; the ledger said 9 but lists the same 8): fresh install, rollback reinstall-refresh, rollback proof 2, backup-select, bridge injection, bridge restore, semantic search, semantic restore `[TRANSCRIPT: m9-green-2-candidate.txt; REPORT: progress.md]`. **MUT-vec0 run (the spec's mutation, as a repack of pack-3 minus `usr/local/lib/vec0.so`; harness `15a8dae`):** `PASS 149 / FAIL 10`; all 8 `m9: vec0 loaded (…)` assertions FAIL through the error-line branch (23 `Unable to load the sqlite-vec extension` lines and 59 control lines in the journal, so not a journal-empty false red), plus `import sqlite_vec` and `m8: semantic search up`. The every-start assertion is therefore seen to fail `[TRANSCRIPT: m9-mutvec0.txt; REPORT: progress.md]`. Positive control `frigate-run: go2rtc gate waited_ms=` is now required in the same journal window. Gate run 6 shows `vec0 loaded` PASS `[TRANSCRIPT: m9-green-6-candidate.txt]`. **Reindex on a 0.1.3-written DB FAILED in 3 of 3 runs: a FINDING, non-gating (orchestrator ruling), see "Semantic-search reindex after upgrade"**; the rehearsal counts it as its one FAIL, so rehearsal exit is non-zero for this check alone. The vec0 half is met; the reindex half is an open finding, hence PARTIAL |
| 7a | Backups (D21): after two consecutive 0.18 refreshes a `frigate-pre-0.17.2-*` backup remains and a revert restores it; finding: 0.17.2 booted on a 0.18-migrated DB | **MET** (local candidate) | Rehearsal #2 phase E: the candidate's stop quiesced on both refreshes; the 0.17.2 backup survives two 0.18 refreshes; at most 3 backups remain; the revert restored the 0.17.2 backup; `integrity_check` ok; 0.17.2 running. Phase F (finding, no backup): `snap revert` rc=0 and 0.17.2 came up on the 0.18-migrated DB (`/events` OK, new recordings, `integrity_check` ok) `[TRANSCRIPT: m9-rehearsal-final-2.txt; REPORT: progress.md]`. Also unit-tested hermetically (`tests/pre-refresh.test.sh`, `19820e7`) |
| 7b | `go2rtc.ffmpeg.bin` follows `ffmpeg.path` (D22); `LIBAVFORMAT_VERSION_MAJOR` equals the 8.0 tree's major (D23) | **MET** (local candidate) | `PASS: m9: go2rtc ffmpeg.bin follows ffmpeg.path 7.0 (D22)`, `PASS: m9: go2rtc ffmpeg.bin back on the 8.0 default`, `PASS: m9: LIBAVFORMAT_VERSION_MAJOR=62 in the frigate env (D23)` `[TRANSCRIPT: m9-green-2-candidate.txt]`. 62 matches the real 8.0 binary: `libavformat    62. 12.102` `[REPORT: progress.md, R6 build check]` |
| 8 | Retention: a segment older than the configured retention is deleted within one maintenance cycle (#24182) | **MET** (local candidate) | Rehearsal #2 phase B: the expired retention row and its file were deleted by 0.18 (`PASS: B: retention deleted the expired row`, `PASS: B: retention deleted the expired file`; phase A pins `continuous.days = 1`, and Frigate is kept stopped while seeding so 0.17.2 does not eat the expired row first) `[TRANSCRIPT: m9-rehearsal-final-2.txt; REPORT: progress.md]` |
| 9 | nginx: `nginx -t`; no "uninitialized variable" warning; `/api/logout` answers; `.webp` served as `image/webp` | **MET** (local candidate; gate `.webp` glob still SKIP, met via the rehearsal) | Met on the candidate: `PASS: m9: nginx -t on the rendered conf`, `PASS: m9: no uninitialized go2rtc_stream_proxy warning after an authed request`, `PASS: m9: /api/logout reachable without auth (… HTTP 303)`. Mutations bite: dropping the warn-off gives warn count 1; dropping the `/api/logout` location gives 401; restart re-renders back to warn 0 / 303 `[TRANSCRIPT: m9-green-2-candidate.txt; m9-nginx-mutation.txt]`. **`.webp` mime was SKIP in the gate** (`no clips/*.webp yet`). That glob could never match Frigate's own thumbnails, which land in `clips/export/<id>.webp` (`record/export.py:585` @ v0.18.2). Rehearsal #2 phase B closes it: `PASS: B: nginx serves the export thumbnail as image/webp (:5000 /clips/export/)` `[TRANSCRIPT: m9-rehearsal-final-2.txt]` |
| 10 | W-16 and W-11 acceptance re-run after the go2rtc bump, if landed | **NOT APPLICABLE (not landed)** | Neither is merged; nothing was run. T11 (S5 exec filter) is skipped for the same reason (see Follow-ups) |
| 11 | Size reported against 990,572,544 B (expected about +112 MB); floor retuned | **PARTIAL** (local candidate, not the Launchpad artifact) | Local candidate pack-5 1,106,505,728 B, +115,933,184 B vs rev 4's 990,572,544 B (see Builds). The floor retune from the Launchpad artifact is **PENDING** |

**Tally (2026-11-13, after rehearsal #2 and gate run 6):** MET 7 (2, 3 with the ruling, 4, 7a, 7b, 8, 9); PARTIAL 4 (1 and 11: local candidate only; 6: scratch-build mutation not run; 7: reindex finding); NOT PROVEN 1 (5); NOT APPLICABLE 1 (10); PENDING 0 beyond the Launchpad artifact, the final gate on it and the size-floor retune. The spec's exit criterion (items 1–11 PASS on the Launchpad artifact, plus the maintainer's go for `latest/edge`) is **not met yet**.

---

## Not proven by the gate VM

The gate VM (`m8-gate`) has no GPU render node and no Coral. In plain words, these are **not proven** by anything in this document:

- **The OpenVINO GPU detector path.** The VM's `gpu: openvino detector reporting` check is a capability SKIP, and auto-detect renders the `cpu` detector there.
- **VAAPI hardware decode** on the 8.0 default tree, including the go2rtc `#hardware` workaround in the README.
- **The D16 fdinfo denial rate.** The `/proc/<pid>/fdinfo` scan runs only with VAAPI or QSV camera hwaccel and `telemetry.stats.intel_gpu_stats` true. The gate's fdinfo block is `SKIP (capability): m9 fdinfo scan — needs a VAAPI render node`, so no denial was observed, no arm was added (the plan forbids speculative ones), and the audit-log volume question stays open. It needs Intel hardware, which is the hub or a laptop with an iGPU `[REPORT: progress.md, T9 Step 6]`.
- **Coral.** No TPU was attached (`SKIP (no capability): coral inference ran`). Upstream issue #24882 (Coral `detection_fps` stuck at 0 on 0.18.2) has no watch item run.
- **D7, old IR on openvino 2025.4: CPU-only probe done.** The prebuilt MO-converted IR is kept (D7). `[REPORT: progress.md; TRANSCRIPT: m9-probe-ov-cpu.txt, m9-probe-motion-ov.txt]`
  - **(a) Direct**, the snap's python with openvino 2025.4.1, outside confinement: the shipped IR `ssdlite_mobilenet_v2` loads and infers on CPU; input `[1,300,300,3]` u8, output `(1,1,100,7)`, median 17.22 ms over 10 runs.
  - **(b) In Frigate**: `detector=ov` renders `device: GPU`, and compiling fails in the VM (no GPU; expected). **Finding: M8's note that `ov` auto-selects CPU in a VM does not hold for this render path.** With `device: CPU` set explicitly, the log shows `Loading OpenVINO model /opt/frigate/models/openvino/ssdlite_mobilenet_v2.xml on device CPU`, the process stays alive and the traceback count is 0. In-Frigate inference was not exercised (no regions are produced, see item 5). The auto detector was restored afterwards and the API came back up.
  - This proves loading on **CPU only**. The GPU path, VAAPI decode and the D16 fdinfo rate are **NOT proven**, and the GPU plugin is the reason upstream changed its converter.

---

## Revert DB integrity (rehearsal phases C, E, F)

`frigate-run`'s downgrade restore moved `frigate.db` aside and copied the backup in, but left `frigate.db-wal` and `frigate.db-shm` where they were (0.17.2: `spike/bin/frigate-run:138-139` at `a39bfb0`; 0.18 before the fix: `:141-142` at `15a8dae`). The rehearsal records, as a `FINDING` before each revert, whether `-wal`/`-shm` exist and their size, and after the revert asserts `PRAGMA integrity_check` = `ok` on the restored DB (gating in C and E; a finding in F, where nothing is restored).

**Decision rule (orchestrator ruling V3).** If `integrity_check` passes after every revert, the WAL hazard stays a follow-up (Follow-ups, item 11). If it fails, or the restored data is inconsistent, it is fixed in M9, then re-pack and re-gate.

**Rehearsal #1 (2026-11-13, `rc=1`): C, D, E and F red** `[TRANSCRIPT: m9-rehearsal-final-1.txt; REPORT: progress.md]`. A and B pass (B's one FAIL is the reindex finding, below).

| Phase | `-wal` / `-shm` before the revert (FINDING) | `integrity_check` after the revert | Outcome |
|---|---|---|---|
| C (revert, stamped backup restored) | `frigate.db-wal=4124152 B; frigate.db-shm=32768 B` | not reached: `FAIL: API up after revert (C revert)` | **RED**. Journal: 05:00:59 UTC the 0.17.2 `frigate-run` logs `DOWNGRADE detected` and restores `frigate-pre-0.17.2-rx1.db`; 05:01:06 `sqlite3.DatabaseError: database disk image is malformed`, then a crash loop |
| D (re-refresh to the candidate) | n/a | n/a | **RED** (cascade): `FAIL: API up after install (D re-refresh)` |
| E (revert after two 0.18 refreshes, D21) | n/a | not reached | **RED** (cascade): `FAIL: API up after install (E refresh 1)` |
| F (revert with no backup, finding only) | `absent; absent` | `error: DatabaseError: database disk image is malformed` (finding) | **RED** (cascade): the DB was already damaged in C; `FAIL: F: candidate healthy after the finding phase` |
| **Decision (I4)** | | | **`integrity_check` FAILED → fixed in M9** |

**Root cause (proven).** SQLite opens `<db>-wal` by name, whatever the main file's header says. After `mv frigate.db …incompatible-TS; cp BACKUP frigate.db` the 0.18 WAL frames sit beside a different file, and SQLite replays them onto it. Host reproduction: the restored file came back with the live DB's tables and rows instead of the backup's `[REPORT: progress.md; scratchpad walrepro/walrepro.py]`. In the VM the frames land on a different 0.17.2 file, hence `malformed`. Upstream's own s6 `prepare` script moves `-shm`/`-wal` together with `frigate.db` when it relocates the DB (`docker/main/rootfs/etc/s6-overlay/s6-rc.d/prepare/run:52-57` @ v0.18.2).

**Constraint.** A `snap revert` boots the OLD revision's `frigate-run`, which is frozen in the Store. No `frigate-run` change can fix a revert to 0.17.2. The 0.18 snap has to leave no WAL behind when its `frigate` service stops (snapd stops the outgoing revision's services before it switches revisions).

**Fix (spec D24; plan Task 6b and the Task 10 D24 addendum).**

1. **(a) Clean stop.** `spike/bin/frigate-db-quiesce` is the `frigate` app's `post-stop-command`. snapd renders it as systemd `ExecStopPost=` of the revision being stopped (snapd `wrappers/internal/service_unit_gen.go:180-182`), so it runs after stop, restart, refresh, revert and a crash (VM proof below). The snapcraft reference says: "The command to run after the service is stopped. Requires the daemon key to be specified for the app." With the snap's python it runs `PRAGMA wal_checkpoint(TRUNCATE)` and then `PRAGMA journal_mode=DELETE`. It logs exactly one line, `frigate-db-quiesce: db=<B> wal_before=<B|absent> wal_after=<B|absent> shm_after=<B|absent> result=<ok|busy|busy=0,mode=…|timeout|error:<Class>>` (or `db=absent result=nodb`; `busy`: another connection still held the DB after sqlite's 10 s busy timeout, so the DELETE switch is skipped and the WAL stays), and never any DB content. It always exits 0. Frigate turns WAL back on at its next open (peewee `SqliteQueueDatabase`). No new plugs.
   - **Bound: 20 s plus a 3 s kill grace**, inside snapd's default 30 s stop timeout (`timeout.DefaultTimeout`; the app sets no `stop-timeout`, and systemd arms `ExecStopPost=` with `TimeoutStopSec`). **Deviation from the plan text:** the plan wrapped python in coreutils `timeout -k 3 "$T"`. That binary is not in snapd's AppArmor template (`interfaces/apparmor/template.go`, master, fetched 2026-11-13: `sleep`, `stat`, `mv` and `cp` are listed, `timeout` is not), and M7 saw `timeout: Permission denied` in this snap's confined pre-refresh hook (`docs/m7-findings.md:124`). Under confinement the plan's form would fail to exec, and the quiesce would never run. The same bound is therefore enforced inside python: a watchdog thread at T (sqlite3 releases the GIL while it waits on a lock), and `SIGALRM` at `SIG_DFL` at T+3 s, which the kernel delivers even if python is wedged. `tests/m9-packaging.test.sh` pins T+K ≤ 25 s, no `stop-timeout`, and no coreutils `timeout` in the script.
2. **(b) WAL-aware restore** (for downgrades from a later 0.18.x or 0.19; it cannot help the revert to 0.17.2). `frigate-run` restores through `db_restore` (`spike/bin/lib-db-restore.sh`). It moves `frigate.db`, `-wal` and `-shm` aside together as `frigate.db.incompatible-<ts>{,-wal,-shm}`, so the preserved copy still opens, and moves all three back if the copy fails. The log keeps the `frigate-run: restored $BACKUP` prefix that the gate and the rehearsal grep.
3. **Tests** (hermetic, real sqlite through the host `python3`, run by CI's `tests/*.test.sh` loop):
   - `tests/frigate-db-quiesce.test.sh`: stale WAL from a killed writer, no DB, a non-DB file, a held lock (bounded, `result=timeout`), and the revert path (quiesce, then 0.17.2's frozen `mv`/`cp`, gives the backup's content). The header journal-mode bytes 18-19 are read raw: `2 2` before, `1 1` after.
   - `tests/frigate-db-restore.test.sh`: restore over a live DB with a stale WAL must give **exactly the backup's content**, not just `integrity_check` = ok.
   - `tests/m9-packaging.test.sh` (section "S2 D24 clean stop").
   - VM side: `tests/spike-smoke.sh` block "m9: WAL quiesce on every stop path" (`snap stop`, `snap restart`, a reinstall-refresh, and `kill -9` of `MainPID`), and `tests/m9-rehearsal.sh` C/E/F quiesce checks plus phase G.
4. **Mutations** (hermetic, `[REPORT: walfix-report.md]`). The shipped Store rev 4/5 restore shape (sidecars not moved) makes the restore test FAIL with the restored DB reading **`ok live:70` against the backup's `ok backup:50`**: `integrity_check` passes, the content is the live DB's. That is why the test asserts content. Dropping `journal_mode=DELETE` FAILs on the header bytes only; SQLite removes the WAL on a clean last close anyway. Removing both bounds FAILs `bounded` (10 s). `exit "$rc"` FAILs both `exit 0` checks. Removing the `post-stop-command` line FAILs the static check, and on a stub harness it FAILs every `quiesce ran` check of the gate block.

**Labelled finding: the SHIPPED Store revisions carry the same latent bug.** Store rev 4 and rev 5 (0.17.2; `frigate-run` restore at `a39bfb0` `:136-145`, with no `post-stop-command`) move only `frigate.db` on a downgrade restore and leave a quiesce-free stop. Any downgrade *across a WAL* under those revisions can replay a stale WAL onto the restored backup: a revert from a later revision to rev 4/5, or a forged or real newer `.last-writer`, while a non-empty `-wal` exists. That is the same mechanism as above (whole-branch review, Important 4). The 0.18 snap's stop hook protects the move *off* 0.18. It cannot fix code already in the Store. Nothing here republishes rev 4/5. Whether to rebuild 0.17.2 with D24 is the maintainer's decision.

**Scope check (other WAL databases).** At v0.18.2 every Frigate database handle (`app.py:192` migrations, `app.py:260` main, `record/record.py:29`, `record/cleanup.py:60`, `embeddings/maintainer.py:127`) opens `config.database.path`, which the snap's template sets to `__SNAP_COMMON__/db/frigate.db` (`spike/config/frigate-config.yml:21`). The vec0 tables live inside that same file. The only other `.db` file is upstream's pre-migration `backup.db` (`app.py:199-203`, `shutil.copyfile`). It is never opened in WAL mode, and the snap's backup/restore path does not swap it. So `frigate.db` is the only file in scope. (Upstream also truncates an oversized WAL at runtime, `record/cleanup.py:57-62`; that is not a stop-time guarantee.)

**Decision rule outcome (I4/V3): `integrity_check` FAILED in rehearsal #1 → fixed in M9 (D24) → passes in rehearsal #2.**

**VM proofs on pack-5** (`bf6d7367…`, hook from `7d6667d`):

1. **Gate run 5** (harness `7d6667d`; `PASS 182 / FAIL 1 / SKIP 21`, 538 denials, 0 unexpected): the D24 block "m9: WAL quiesce on every stop path" passes entirely under confinement. The quiesce ran on `snap stop`, `snap restart`, a refresh and a `kill -9` of `MainPID` (crash), each before the next start; the header bytes 18-19 read `1 1` after the stop and `2 2` after every start (Frigate re-enables WAL itself); the hook added no new denial `[TRANSCRIPT: m9-green-5-candidate.txt; REPORT: progress.md]`. Its single FAIL was the UI-restart race (plan-defect table), unrelated to the hook.
2. **MUT-POSTSTOP** (pack-5 minus the `post-stop-command` line; `PASS 173 / FAIL 10`, 614 denials, 0 unexpected): every D24 assertion FAILs, namely `quiesce ran` on snap stop, snap restart, refresh and crash, `quiesce ran BEFORE the next frigate start` on restart, refresh and crash, **`no frigate.db-wal after snap stop`, `no frigate.db-shm after snap stop` and `header 18/19 = 1,1 (DELETE) after snap stop (got 2,2)`**. So **Frigate itself leaves the WAL behind on a plain stop**; the bug condition is confirmed and the hook is what removes it `[TRANSCRIPT: m9-mutpoststop.txt]`.
3. **Rehearsal #2** (`PASS 86 / FAIL 1`, the FAIL being the reindex finding): **C, D, E, F and G all green** `[TRANSCRIPT: m9-rehearsal-final-2.txt]`.
   - C: the candidate's stop quiesced the DB; the restore left `integrity_check` `ok` (a 391,432 B WAL had existed before the revert).
   - D: re-refresh to 0.18.2 clean.
   - E (D21): quiesce on both refreshes, revert restored the 0.17.2 backup, `integrity_check` ok.
   - F (finding): the no-backup branch came up on the 0.18-migrated DB, `integrity_check` ok.
   - G (D24): stop leaves no `-wal`/`-shm`, header `1 1`, `integrity_check` ok; restart and crash give `result=ok`; WAL re-enabled by Frigate (`2 2`).
   - Note: `systemctl kill -s KILL` printed `Failed to send signal SIGKILL to auxiliary processes: Invalid argument`. It is benign; the crash path passed.
4. **Bound check on the busy path** (hermetic, `7d6667d`): with an EXCLUSIVE lock held, the pre-fix hook gave `error:OperationalError` after 10,135 ms; the fixed one gives `result=busy`, exit 0, 10,160 ms. Removing all three bounds runs past the budget (capped at 40,135 ms); removing only the busy timeout leaves the watchdog holding at 20,068 ms with `result=timeout` `[REPORT: progress.md]`. Only `result=ok` is safe: a `busy` result leaves the WAL (documented).

The `-wal` FINDING lines of the rehearsal are taken while the candidate still runs (C: 391,432 B; E and F: 0 B), so they are not the WAL at restore time; `integrity_check` is the deciding signal.

## Semantic-search reindex after upgrade (spec §5 item 7)

**Status: FINDING, reproduced in 3 of 3 runs. Not gating** (orchestrator ruling, 04:27). **Upstream defect candidate, for the maintainer to decide on; no Frigate patch was made.** Rehearsal exit is non-zero for this check alone (`FAIL: B: reindex logged no sqlite/vec error`), because the script counts it as a FAIL.

| Run | Evidence | Status |
|---|---|---|
| MUT033 run 2 (mutation run, not the real rehearsal) | `frigate.embeddings` ERROR `Unable to reindex tracked object embeddings`, raised in `drop_embeddings_tables` (`db/sqlitevecq.py:122` @ v0.18.2) as `peewee.OperationalError: SQL logic error`, on a DB whose vec tables vec0 0.1.3 wrote (no `_info` shadow table) `[REPORT: progress.md]` | observed |
| Reproduction outside Frigate | Not reproduced: on the host (vec0 0.1.3 creates the tables, then 0.1.9 with the stub + `DROP`) and on a copy of the VM's DB with the snap's python and the candidate's `vec0.so`, both succeed `[REPORT: progress.md; scratchpad/vecrepro]`. The in-process cause is unknown | not reproduced |
| Upstream workaround | Upstream #24407's `_restore_vec_info_table` stub is present at v0.18.2 (`db/sqlitevecq.py:103`, called from `drop_embeddings_tables` at `:121`) | present |
| Rehearsal #1 (final-1, pack-3) | Reproduced on the real candidate. `PUT /reindex` accepted and started, then `B: reindex logged no sqlite/vec error` FAIL. After the failure the DB has `vec_descriptions_info` (the stub `_restore_vec_info_table` created) but `vec_descriptions` was **not** dropped; `vec_thumbnails` has no stub, so the loop stopped at the first table. Phase-A layout: `vec_thumbnails` written by vec0 0.1.3, `_info` = 0 (legacy pre-0.1.6) `[REPORT: progress.md; TRANSCRIPT: m9-rehearsal-final-1.txt]` | reproduced |
| Rehearsal #2 (final-2, pack-5) | Same FAIL `B: reindex logged no sqlite/vec error`; reindex accepted and started; completion line not seen within 600 s (model download is network-gated, a FINDING line) `[TRANSCRIPT: m9-rehearsal-final-2.txt]` | reproduced |
| Outside Frigate | Not reproduced in 4 variants (fresh connection; vtab opened before the stub; WAL; explicit transaction). Time box hit. Untested lead: which sqliteq connection (writer or reader) has vec0 loaded when the `DROP` runs `[REPORT: progress.md]` | not reproduced |

So the count is **3 of 3 runs** (MUT033 run 2, rehearsal #1, rehearsal #2). Impact: after an upgrade from 0.17.2, semantic-search reindex of existing embeddings errors in `drop_embeddings_tables`. New embeddings are not assessed here.

---

## Builds

**R6 build check** (controller, `snapcraft build spike-wheels validate-deps ffmpeg go2rtc` at `0f5e405`, 02:40→02:50): `rc=0`. sha256 verified for ffmpeg-5, ffmpeg-7, ffmpeg-8 and go2rtc; no "R4 ERROR"; `vec0.so` installed to `usr/local/lib` (159,816 B). Installed: openvino-2025.4.1, python-multipart-0.0.26, sqlite-vec-0.1.9; no degirum. In the build instance: ffprobe n5.1-2, n7.0.2-18 and n8.1.1-9-g58d4114d36; the 8.0 `ffmpeg` prints `libavformat    62. 12.102`; go2rtc 1.9.14 (`b5948cf`) `[REPORT: progress.md; build-t3t4.log]`.

**First pack failed** at part `nginx`: `wget` of the kaltura vod module tag returned 404 (see W-19). **Second pack (PACK-2) at `ecf63dd`** succeeded (03:16→03:24) `[REPORT: progress.md]`:

| Item | Value |
|---|---|
| File | `frigate_0.18.2_amd64.snap`, **local candidate, not the Launchpad artifact** |
| Size | **1,106,501,632 B** |
| sha256 | `b05bdf1da8470ee160b91e4bb123f1db25bc508bcf0cb0398dd9f527a3dafedd` (also the `ARTIFACT:` line of `[TRANSCRIPT: m9-green-2-candidate.txt]`) |
| Contents checked | squashfs OK; ffmpeg 5.0, 7.0 and 8.0 trees; `vec0.so`; `go2rtc`; the 0001 patch applied; `version.py` stamp `0.18.2-cfa08c5`; no `__pycache__` in `bin/` |
| vs Store rev 4 (990,572,544 B) | **+115,929,088 B** |
| vs the spec's expectation (about +112 MB; the 8.0 tree alone measured +112,185,344 B in M8) | 3,743,744 B above the 8.0-tree figure. The remainder is the wheel and go2rtc bumps |
| Gate floor in the harness today | 840,957,952 B (802 MiB), `PASS` at this size |
| Floor retune | **PENDING (Launchpad artifact)**. Brief: `floor_to_MiB(0.85 × size)` from the Launchpad artifact, with the arithmetic in the comment |

**Candidates, pack-2 to pack-5** (all local `snapcraft pack`, none is the Launchpad artifact) `[REPORT: progress.md]`:

| Pack | Commit | Size (B) | sha256 | Why |
|---|---|---|---|---|
| pack-2 | `ecf63dd` | 1,106,501,632 | `b05bdf1da8470ee160b91e4bb123f1db25bc508bcf0cb0398dd9f527a3dafedd` | First good pack after the W-19 nginx source fix (pack-1 failed at 404); gate runs 1 and 2, red run partner |
| pack-3 | `eac2436` | 1,106,505,728 | `a77e014afd3b011aa416c9157f73f3facbcff4f1f9d15e6822768e123674fa67` | Re-packed because the fix wave edited shipped files (comments and docstrings only: `snap/snapcraft.yaml`, `spike/config/frigate-config.yml`, `spike/bin/go2rtc-config-gen.py`); gate run 3 and rehearsal #1 |
| pack-4 | `4a4763f` | 1,106,505,728 | `02c9baa1a06d8d6f9ca73fbc26209d633a7dd2c7109ffaf4755d9fe2e863a111` | D24: new `spike/bin/frigate-db-quiesce`, `spike/bin/lib-db-restore.sh`, `post-stop-command`. Superseded before any VM run by the D24 review |
| pack-5 | `7d6667d` | 1,106,505,728 | `bf6d736783447f176bcbf22b5f14f1cd921df1a606e5beee289ed2f54a8805e9` | D24 review fixes in the shipped quiesce and restore (busy result, local variables). **Final local candidate**: gate runs 5 and 6, MUT-POSTSTOP, rehearsal #2 |

Mutants (not deliverables): MUT033 (candidate minus migration `033_create_export_case_table.py`, 1,074,929,664 B); MUTVEC0 (pack-3 minus `usr/local/lib/vec0.so`, sha256 prefix `dc2e3eae…`, 1,074,929,664 B); MUT-POSTSTOP (pack-5 minus the `post-stop-command` line, sha256 prefix `913acf17…`). Mutants of the same size are explained by mksquashfs deduplication (`vec0.so` also sits in site-packages); the file listings and hashes were checked. Pack-5 vs rev 4: +115,933,184 B. Hand-off artifact checks on pack-5 were all positive, with `post-stop-command` present in `meta/snap.yaml` and no `stop-timeout`.

---

## W-19: the nginx module sources were dead

The first pack failed because `github.com/kaltura/nginx-vod-module` and `github.com/kaltura/nginx-secure-token-module` return **404** (`gh api` on both: HTTP 404). Upstream Frigate v0.17.2 and v0.18.2 `docker/main/build_nginx.sh` pin the same two kaltura tags (vod 1.31, secure-token 1.5), so upstream's own image build is affected too `[REPORT: w19-report.md]`.

Fix: branch `fix/nginx-module-sources` @ **`95c7233`** (full `95c72330daf5d941473ead27caf872c7ff6cc245`, off `main` `a39bfb0`, pushed by the orchestrator as PR #7; opening or merging it is the maintainer's), **cherry-picked onto M9 as `ecf63dd`**. Content stays kaltura 1.31 and 1.5, file for file. Both replacements are pinned by sha256 and proven tree-identical against Software Heritage (SWH), which archived the original repos:

| Module | SWH proof chain | Replacement (fork, license) | sha256 of the archive | Git tree |
|---|---|---|---|---|
| nginx-vod-module 1.31 | tag release `4bce0c8a…` → revision `6c305a78b7ab6e4312279bea5c45741bb54a713b` → directory `f2ba251df1ddf2b62bce55bea68e79e5974a032d` | `dio-az/nginx-vod-module` @ `6c305a78…` (AGPL-3.0; also the fork upstream's dev branch uses) | `a57069a31fa6cb0b045746f53d0fcd48f1bb409727d4cfbe2197cd8bfaca06a2` (original pin was `ace04201…`) | `f2ba251d…` equals SWH; `diff -r` against the cached original is identical |
| nginx-secure-token-module 1.5 | tag release `18aca97ebfe9b50218cf7db636b25893f9abcfba` → revision `18b97a82878e09fef24fe4f6a446eed01dbe28d7` → directory `c8206fdc990124b82aa69410d02a1e410e514854` | `webtor-io/nginx-secure-token-module` @ `18b97a82…` (AGPL-3.0; self-described unchanged-history mirror, created 2026-11-12) | `c3691a5af6f1dfdc0ca5ff87c1947e65108762f89792d7288a07d386dc702cec` (original pin was `9809b779…`) | `c8206fdc…` equals SWH; identical to the cached original |

The controller re-verified the secure-token chain itself `[REPORT: progress.md]`. A drop-in fallback exists: `jotair/nginx-secure-token-module` serves the same commit with the same sha256. The three vod patches apply to the fork's tree. Test: `tests/nginx-sources.test.sh` goes from 6 FAIL (before) to all ok (after), and its mutations bite `[REPORT: w19-report.md]`. A liveness scan of every other fetched URL (wheel lists, tests, workflows) found none dead; one dead prose link remains in `spike/config/nginx/nginx.conf.in` (not fetched).

**Risk, stated plainly: fork longevity.** Both replacements are single-maintainer copies with no declared fork relationship (the parent is gone), and the secure-token mirror is a day old. The sha256 pin makes a changed or bad copy fail closed, but a future 404 is possible. Longer-term options are to vendor both archives (AGPL-3.0, redistributable with source) or host them under the project organisation. GitHub archive determinism is a second, smaller risk: the pins are on GitHub-generated archives, so a change in GitHub's archive output changes the sha even when the tree does not. The SWH directory ids in the `snapcraft.yaml` comments let anyone re-prove the content.

---

## Plan defects found while building

The plan owner adds these to the plan's errata. This document only records them.

| # | Defect | Where (plan) | Effect | Fix commit | How found |
|---|---|---|---|---|---|
| 1 | `upstream_dir` sets `trap 'rm -rf …' EXIT` inside `$(upstream_dir)`, so the subshell's exit deletes the clone at once and `_UP` never reaches the parent | Task 1 (`tests/m9-packaging.test.sh`) | Hidden when `M9_UPSTREAM_DIR` is set; breaks CI, where it is not | `6604475` | Task 1 code review |
| 2 | `part()` matched the first 2-space `  <name>:` key, which for `go2rtc` is the `apps:` entry (`snapcraft.yaml:81`), not the part (`:315`) | Task 4 (helper from Task 1) | The go2rtc assertions could never pass | `0f5e405` (scoped to top-level `parts:`) | Task 4 implementer, while running the failing test |
| 3 | The `backup-select` `-r2` anchor | Task 9 | False FAIL after the rollback block's real `-rx1` backup (`sort -V` picks `rx1`) | `4a6b798` (asserts the running version only) | Task 9 review; confirmed in the red run |
| 4 | The authed `/api/logout` probe | Task 9 (expected to FAIL on 0.17.2) | Passes on 0.17.2 (HTTP 303): an authed probe reaches Frigate's own route via `/api/`, so it proved nothing about the nginx location | `f0a6a11` (unauthenticated probe) | Red run on rev 4 `[TRANSCRIPT: m9-red-on-rev4.txt]` |
| 5 | `sidecar written` asserts the literal `^0.17.2` | Task 9 (existing check, line `:752` at the time) | FAIL on 0.18.2 (the sidecar says `0.18.2 x2`) | `3392e06` | Green run 1 `[TRANSCRIPT: m9-green-1-candidate.txt]` |
| 6 | Artifact check `grep -qx "version: '0.18.2'"` expects a quoted version | Task 12 Step 2 | `snapcraft` writes `version: 0.18.2` unquoted in `meta/snap.yaml`, so the check false-fails. Corrected in the hand-off below | none in code (plan text only) | Artifact checks on the local candidate |
| 7 | `snap refresh --retain=2`: the default retains two revisions | Task 10 | Refreshing to 0.18 can delete the baseline revision, so every later revert breaks | `d6ac31b` (sets `refresh.retain=10`, restored by an EXIT trap) | Task 10 implementer |
| 8 | An already-expired retention row is eaten by 0.17.2 before 0.18 runs | Task 10 (item 8) | Item 8 would pass vacuously | `d6ac31b` (Frigate is kept stopped while seeding into the refresh) | Task 10 implementer |
| 9 | The rehearsal's `wait_api` until-loop returned the status of its last body command (`[ t -ge 300 ] && return 1`, false = 1) | Task 10 | False FAIL `API up after install` whenever at least one poll was needed, so the run aborted at phase A | `7512d3d` (explicit `return 0` after the loop) | First MUT033 mutation run |
| 10 | The Launchpad hand-off's artifact checks used `unsquashfs -c`, which squashfs-tools 4.6.1 does not have: it prints usage and returns 1, so `version OK` and `0001 patch applied` silently never printed | Task 12 (hand-off) | The checks could never pass and printed nothing on failure | final-review fix wave (`-cat`, and every check prints a negative line) | Whole-branch review |
| 11 | D24's plan text wraps python in coreutils `timeout -k 3 "$T"` | Task 6b (D24) | `timeout` is not in snapd's AppArmor template (M7 precedent, `docs/m7-findings.md:124`), so the form would fail to exec under confinement and the quiesce would never run | `3ab066c` (bound enforced inside python: 20 s watchdog plus `SIGALRM` at T+3 s; `tests/m9-packaging.test.sh` pins it; deviation accepted by the orchestrator with proofs) | D24 implementer; confirmed by the D24 review |
| 12 | The UI-restart check in the M8 harness breaks its wait loop at 0 s because the old process still answers `/version` | Pre-existing M8 harness (`tests/spike-smoke.sh`), exposed by D24 | The post-stop hook lengthens the restart window, so gate run 5 FAILed `restart: frigate API answers again after UI restart` | `8e9185d` (waits for a new `MainPID` and `/version`; new check `MainPID changed`; stub proof old FAIL, new PASS) | Gate run 5 `[TRANSCRIPT: m9-green-5-candidate.txt]` |
| N9 | **Controller's own error, reverted.** The fix wave added explicit `INT`/`TERM` traps to the rehearsal to restore `refresh.retain`; the premise (that the EXIT trap does not run on SIGTERM) was wrong | Task 10 fix wave | An explicit TERM trap defers cleanup until the foreground child exits (up to 600 s in bash); the original EXIT trap already ran at once (measured 1007 ms vs 20007 ms) | `15a8dae` (traps dropped, run-once guard kept). Why `refresh.retain` stayed 10 after MUT033 run 2 is unexplained | Scoped re-review of the fix wave |

Defects 9 and 10 are listed above; the orchestrator owns the plan errata and these rows are only the record.

---

## Incident: `rm -f *` in the worktree root (D24 implementer)

During the D24 work a broken nested heredoc in generated shell ran `rm -f *` in the worktree root `[REPORT: progress.md]`. Controller verification: `git status` clean, no tracked file missing (`LICENSE` and `README.md` were restored from git), `.superpowers/` (the ledger) and `spike/results/` intact, because directories and dotfiles are not matched by `*`. **The only loss was the untracked pack-3 output `frigate_0.18.2_amd64.snap`; a byte-identical copy was kept in the scratchpad (`cand/frigate_0.18.2_amd64-eac2436.snap`).** The orchestrator accepted the verification (06:53) and set guardrails for every subagent from then on:

- no `rm` with globs: explicit paths only, variables checked non-empty, `set -u`;
- no nested heredocs in generated shell (use the editor tool);
- absolute paths for deletes;
- after every subagent run, `git status --short` and `git ls-files -d` must be clean/empty, and the final report states it.

The controller also avoids `rm` inside `bash -c` in the VM (the safety check blocked it twice, nothing ran). Later D24 work (`7d6667d`) and the `8e9185d` fix were verified under these guardrails (status clean, `ls-files -d` empty).

---

## Follow-ups

1. **T11 / S5, the bridge exec filter (D13), is pending and waits for W-16.** It touches the same generator and template. Until it ships, this snap does **not** filter `exec:`/`echo:`/`expr:` go2rtc streams, while upstream 0.18 does. The README says so.
2. **D16 measurement on Intel hardware:** run the gate with `preset-vaapi` on a machine with a render node, classify any new `/proc` denials with journal quotes and report the rate.
3. **Hub soak (D15):** the field soak waits for the hub (W-7) and reachable cameras. Not an M9 exit criterion. #24882 (Coral `detection_fps` 0) gets a watch item there.
4. **W-17 is open (D18).** At v0.18.2 `/config` shows go2rtc `rtsp`/`api`/`mqtt` credentials to logged-in users. Re-checked 2026-11-13: `grep -c _redact_go2rtc_credentials frigate/api/app.py` on the v0.18.2 tag is **0**. Upstream's redaction landed on `dev` only (#24719). Recorded in the README under "Known upstream issues".
5. **Residual advisories on 0.18.2:** GHSA-w3c4 (webpush SSRF), GHSA-4xp7 (go2rtc RTSP negative `Content-Length` panic; the same code is in go2rtc 1.9.13) and GHSA-74x4 (camera ACL bypass via nginx static locations; the snap mirrors upstream's layout). Exploitability on this snap is not assessed.
6. **pip wheels are not hash-pinned** (`spike/wheels-src/requirements-core.txt` has no `--require-hashes`), noticed in passing by the W-19 worker. A separate supply-chain gap.
7. **Fork longevity** for the two nginx module sources (W-19 section).
8. **Not run, from the spec:** the scratch-build mutation for item 6 (no 8.0 tree). Item 7's `vec0.so` mutation was run (MUT-vec0).
9. **D7, OpenVINO IR:** the CPU-only load of the old IR on openvino 2025.4 is proven (see "Not proven by the gate VM"). Still open: measure upstream's newly converted IR (`build_ov_model.py`, openvino ≥ 2026.2) against our MO-converted IR (inference speed, GPU plugin behaviour) on hardware with a GPU, as D7 promises. Also decide what `detector=ov` should render for GPU-less hosts, since it renders `device: GPU`.
10. **Test-clip detection:** ~~time-boxed follow-up~~ **done, finding only**: the M3 calibration effect (`docs/m3-findings.md:64`; v0.18.2 `improved_motion.py:192-199`), see item 5. Open: first real detection proof on the hub.
11. **`frigate-run` restore and the WAL:** ~~follow-up~~ **fixed in M9 (D24), proven in the VM** (gate run 5, MUT-POSTSTOP, rehearsal #2; see "Revert DB integrity"). Open: the shipped Store rev 4/5 carry the same latent bug (labelled finding there).
12. **Semantic-search reindex failure after upgrade:** upstream defect candidate, reproduced 3 of 3 runs; for the maintainer to decide on (see that section).

---

## Hand-off: Launchpad build and final gate (PENDING, for the orchestrator)

Builders never run this: it needs the maintainer's Launchpad login and uploads the tree to Launchpad (public build logs). No push, credentials or Store upload were used.

0. **D2 re-check, before the final gate:** look for a newer 0.18.x release. A newer one means re-running S1's patch check and the gate on it.

   ```bash
   gh api repos/blakeblackshear/frigate/releases --jq '.[] | select(.prerelease | not) | .tag_name' | grep -E '^v0\.18\.' | sort -V | tail -1
   ```

   Expected today: `v0.18.2`.
1. Branch head sha: the head of `feat/m9-frigate-0.18` when handed off (this document's commit).
2. From a **full** (non-shallow) clone at that sha:

   ```bash
   MAX_ATTEMPTS=3 .github/scripts/remote-build.sh amd64
   ```

   The alternative is to open the PR and let `pr-build-snap.yml` run it.
3. Artifact checks on the returned `frigate_0.18.2_amd64.snap` (read-only, no install; paste the output into the report). Two corrections from the plan: snapcraft writes `version` unquoted in `meta/snap.yaml`, so the plan's quoted-literal grep would false-fail (defect 6); and squashfs-tools 4.6.1 has `-cat`, not `-c` (defect 10). Every check prints a negative line when it fails, so silence never reads as success.

   ```bash
   F=frigate_0.18.2_amd64.snap
   sha256sum "$F"; stat -c %s "$F"
   unsquashfs -s "$F" >/dev/null && echo "squashfs OK" || echo "squashfs BROKEN"
   unsquashfs -cat "$F" meta/snap.yaml | grep -xE "version: '?0\.18\.2'?" >/dev/null && echo "version OK" || echo "version MISMATCH"
   L=$(unsquashfs -l "$F")
   for p in usr/lib/ffmpeg/5.0/bin/ffmpeg usr/lib/ffmpeg/7.0/bin/ffmpeg usr/lib/ffmpeg/8.0/bin/ffmpeg usr/local/lib/vec0.so usr/local/go2rtc/bin/go2rtc; do
     grep -qx "squashfs-root/$p" <<< "$L" && echo "has $p" || echo "MISSING $p"
   done
   unsquashfs -cat "$F" opt/frigate/frigate/const.py | grep -F 'FRIGATE_CONFIG_DIR' >/dev/null && echo "0001 patch applied" || echo "0001 patch MISSING"
   unsquashfs -cat "$F" opt/frigate/frigate/version.py | grep -E '^VERSION = "0\.18\.2-[0-9a-f]+"$' >/dev/null && echo "version.py stamp OK" || echo "version.py stamp MISMATCH"
   ```

   On the earlier local candidate pack-2 (`b05bdf1d…`) this block printed `squashfs OK`, `version OK`, five `has` lines, `0001 patch applied` and `version.py stamp OK` `[VERIFIED: 2026-11-13, final-review fix wave]`.
4. Then, in the gate VM against the Launchpad artifact, both under the suite lock: the harness, then `tests/m9-rehearsal.sh`. Expected: 0 FAIL, denials 0 unexpected, rehearsal exit 0.
   D24 adds one artifact check: `unsquashfs -cat "$F" meta/snap.yaml | grep -q 'post-stop-command: bin/frigate-db-quiesce' && echo "D24 hook OK" || echo "D24 hook MISSING"`. The harness's "m9: WAL quiesce on every stop path" block and rehearsal phase G must pass, and C/E/F must each show the candidate's `frigate-db-quiesce: … result=ok`. Mutation (controller, VM, once): the candidate repacked without the `post-stop-command` line must FAIL the harness block's `quiesce ran` checks (procedure in the block's comment).
   - **Labelled finding (D24): the shipped Store revisions rev 4/5 (0.17.2) carry the same latent WAL bug** for any downgrade across a WAL (sidecars not moved, no stop hook; review Important 4). See "Revert DB integrity". The 0.18 hook protects only the move off 0.18. A 0.17.2 rebuild with D24 is the maintainer's call.
5. Size floor in `tests/spike-smoke.sh`: `floor_to_MiB(0.85 × size)` of the Launchpad artifact, arithmetic in the comment (M8 style), then `bash tests/m9-packaging.test.sh`.

### PENDING sections (to be filled in; no values exist yet)

- **Launchpad artifact** (sha256, size, artifact checks): PENDING.
- **Final gate on the Launchpad artifact:** PENDING.
- **Size-floor retune:** PENDING.

Everything else is resolved above: the rehearsal results (items 2, 3, 4, 6, 7a, 8, 9), the D24 proofs and the D7 CPU-only probe. The reindex failure is a finding, and rehearsal exit is non-zero because of it alone.
