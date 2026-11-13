# M9 Findings — Frigate 0.17.2 → 0.18.2 upgrade (pre-Launchpad; rehearsal pending)

**Date:** 2026-11-13  **Snap:** `frigate` (core26, strict, amd64)  **Frigate:** v0.18.2 (latest release, 2026-10-15; re-checked 2026-11-13, nothing newer)  **Branch:** `feat/m9-frigate-0.18`, **local only** (this branch, and only this branch: not pushed, no PR, no Store upload, no Launchpad build)  **Base:** PR #6 head `7a1c663` (`fix/harness-logs-and-soak-sweep`). PR #6, W-11 and W-16 are **not merged** into `main` (`a39bfb0`).

M9 moves the snap from Frigate 0.17.2 to 0.18.2 with one carried Frigate patch (`0001-env-driven-paths`, context-only rebase), upstream-parity pins (ffmpeg trees 5.0/7.0/8.0 with 8.0 default, go2rtc v1.9.14, python-multipart 0.0.26, openvino 2025.4, sqlite-vec 0.1.9, degirum removed), the nginx mirror updates, a new gate section and an upgrade/revert/re-refresh rehearsal script.

**Status in one paragraph.** Everything below that is marked evidence was produced on a **local candidate** (`snapcraft pack`, not the Launchpad artifact) in the `m8-gate` LXD VM. That candidate passes the full gate: **160 PASS / 0 FAIL / 21 SKIP, 531 denials / 0 unexpected**. The upgrade, revert, re-refresh, real-thumbnail, reindex, backup-retention and retention-deletion rehearsal is **running and has no result yet**. The Launchpad build, the final gate on its artifact and the size-floor retune have **not happened** (they need credentials that builders do not hold). The OpenVINO GPU path, VAAPI decode, Coral and the fdinfo denial rate are **not proven** by anything here (see "Not proven by the gate VM").

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

Spec §5 items 1–11 (+7a, 7b), `docs/superpowers/specs/2026-11-13-frigate-0.18-upgrade-design.md`. Candidate = local `snapcraft pack` at `ecf63dd`, sha256 `b05bdf1da8470ee160b91e4bb123f1db25bc508bcf0cb0398dd9f527a3dafedd`, **not the Launchpad artifact**.

| # | Criterion (spec §5) | Verdict | Evidence |
|---|---|---|---|
| 1 | Full `spike-smoke.sh` on the Launchpad artifact: 0 FAIL; denials 0 unexpected, new fdinfo arms classified, rate reported | **PARTIAL** (local candidate, not the Launchpad artifact) | Run 2 (harness `3392e06`): `PASS 160 / FAIL 0 / SKIP 21`, `== denials: 531 total, 0 unexpected ==`, `SPIKE SMOKE: ALL PASS` `[TRANSCRIPT: m9-green-2-candidate.txt]`. Run 1 (harness `f0a6a11`) was 159/1/21 with 514 denials; its one FAIL was a stale `^0.17.2` literal in the `sidecar written` check, fixed in `3392e06` `[TRANSCRIPT: m9-green-1-candidate.txt; REPORT: progress.md]`. No fdinfo denials could occur (no render node), so no fdinfo arm was added and no rate exists |
| 2 | Upgrade rehearsal from rev 5 (0.17.2): seeded state, refresh, `frigate-pre-0.17.2-r<rev>.db`, migrations 033/034/035, API still lists seeded data, `config.yml` at `0.18-0`, `backup_config.yaml` equal and 0600, `validate-config` 0 | **PENDING (rehearsal running)** | Script `tests/m9-rehearsal.sh` (`d6ac31b`..`cb67857`, plus the final-review fix wave) is reviewed clean. Baseline will be rev 4 (deviation above). **Events are seeded through Frigate's own manual-event API** (`POST /events/testclip/person/create`, admin; v0.17.2 `api/event.py:1738`, v0.18.2 `:1751`), not from detections on the test streams, because the test clip never triggers a detection in the VM (item 5). Phase A records the 3 returned event ids; B, C and D check those exact ids in the `event` table and in `GET /events` (orchestrator ruling V1). MUT033 run 2 showed `A: events seeded` FAIL with 0 events under the old detection-based seeding `[REPORT: progress.md]`. No result yet |
| 3 | Revert rehearsal: `DOWNGRADE detected`, stamped backup restored, `config.yml` is the 0.17-0 file, 0.17.2 starts, detects and records | **PENDING (rehearsal #1 red: C crash-looped on a replayed WAL; fixed by D24, re-run pending; see "Revert DB integrity")** | Not run yet. **"Detects" is not provable in the VM** (item 5); per ruling V1 the rehearsal instead checks that 0.17.2 serves the API, captures (`ffmpeg_pid > 0`), writes new recording segments (gating) and lists the seeded events by id. New detection events after the revert are a `FINDING` line only. Phases C and E also assert `PRAGMA integrity_check` = `ok` on the restored DB (see "Revert DB integrity" below). The gate's own rollback block (a different, M7-style check) passes on the candidate: `PASS: rollback: downgrade detected + restored` `[TRANSCRIPT: m9-green-2-candidate.txt]`. That is not this rehearsal. The README's revert statement is spec-derived (D11/D12, snapd per-revision $SNAP_DATA); the revert rehearsal result is PENDING and will confirm or correct it |
| 4 | Re-refresh: migration runs again cleanly from the restored state | **PENDING (rehearsal running)** | Not run yet. The README's revert statement is spec-derived (D11/D12, snapd per-revision $SNAP_DATA); the revert rehearsal result is PENDING and will confirm or correct it |
| 5 | Detection: OpenVINO GPU and CPU, Coral when present; speed against M3/M6 | **NOT PROVEN** (hardware, and no detection in the VM at all) | **Detection is NOT PROVEN in the VM, on any detector.** The looping test clip never triggers motion or detection there: on the candidate the `cpu` detector reports `inference_speed` 10.0 (the never-ran sentinel) and `testclip` reports `detection_fps` 0.0 at `camera_fps` 5.0; no VM run has ever shown a testclip detection `[REPORT: progress.md, MUT033 run 2]`. A prior note in `snap/snapcraft.yaml` (frigate-src part) records the likely cause: the loop's constant motion never lets stock motion calibration exit (`motion/improved_motion.py:195-197` @ v0.18.2). The first real detection proof of 0.18 will be on the hub with cameras and the Coral (W-7/W-2). Also in the VM: `SKIP (no capability): gpu: openvino detector reporting … no Intel(0x8086)/AMD(0x1002) render node`, `SKIP (no capability): coral inference ran — no Coral USB TPU`, livecam MONEY lines SKIP `[TRANSCRIPT: m9-green-2-candidate.txt]`. A CPU-only `detector=ov` probe (D7) is PENDING after the rehearsal and will prove loading on CPU only. See "Not proven by the gate VM" |
| 6 | ffmpeg 8 pipelines; hardcoded `/usr/lib/ffmpeg/8.0/bin/ffmpeg` (deterministic in-sandbox webp; real export thumbnail in rehearsal); mutation: scratch build without the 8.0 tree makes the check FAIL | **PARTIAL** | Deterministic part met on the candidate: `PASS: m9: 8.0 ffmpeg resolves in the frigate sandbox and encodes webp`, `PASS: ffmpeg tree 5.0/7.0/8.0 present+runs` `[TRANSCRIPT: m9-green-2-candidate.txt]`. Red run on rev 4 FAILs the same checks (no 8.0 tree) `[TRANSCRIPT: m9-red-on-rev4.txt]`, which is a red, not the spec's scratch-build mutation; that scratch-build mutation was **not run**. Real export thumbnail: **PENDING (rehearsal running)** |
| 7 | Semantic search: vec0 0.1.9 loads on every start; reindex succeeds on a DB with vec tables written by 0.1.3 | **PARTIAL** | **Rehearsal exit 0 does not prove the reindex part:** its completion is a `FINDING` line (network-gated model download), not a check, so it needs the findings file read by hand (see "Semantic-search reindex after upgrade" below). `PASS: m9: vec0 loaded` at 8 Frigate starts on the candidate (recounted from the transcript: 8 `PASS` lines; the ledger said 9 but lists the same 8): fresh install, rollback reinstall-refresh, rollback proof 2, backup-select, bridge injection, bridge restore, semantic search, semantic restore `[TRANSCRIPT: m9-green-2-candidate.txt; REPORT: progress.md]`. Reindex on a 0.1.3-written DB: **PENDING (rehearsal running)** and its completion is network-gated (model download). The spec's mutation (remove `vec0.so` from a scratch build) was **not run**. Since the final-review fix wave the gate's every-start check also requires the positive control `frigate-run: go2rtc gate waited_ms=` in the same journal window and FAILs `journal empty/unreadable` without it, as the rehearsal's check already did; that change has a stub-harness proof but no VM run yet |
| 7a | Backups (D21): after two consecutive 0.18 refreshes a `frigate-pre-0.17.2-*` backup remains and a revert restores it; finding: 0.17.2 booted on a 0.18-migrated DB | **PENDING (rehearsal running)** | The retention rule is unit-tested hermetically (`tests/pre-refresh.test.sh`, `19820e7`). The rehearsal run is outstanding |
| 7b | `go2rtc.ffmpeg.bin` follows `ffmpeg.path` (D22); `LIBAVFORMAT_VERSION_MAJOR` equals the 8.0 tree's major (D23) | **MET** (local candidate) | `PASS: m9: go2rtc ffmpeg.bin follows ffmpeg.path 7.0 (D22)`, `PASS: m9: go2rtc ffmpeg.bin back on the 8.0 default`, `PASS: m9: LIBAVFORMAT_VERSION_MAJOR=62 in the frigate env (D23)` `[TRANSCRIPT: m9-green-2-candidate.txt]`. 62 matches the real 8.0 binary: `libavformat    62. 12.102` `[REPORT: progress.md, R6 build check]` |
| 8 | Retention: a segment older than the configured retention is deleted within one maintenance cycle (#24182) | **PENDING (rehearsal running)** | Rehearsal phase; the 033-migration-absent mutation run was in progress at the time of writing (2026-11-13) and has no recorded result `[REPORT: progress.md]` |
| 9 | nginx: `nginx -t`; no "uninitialized variable" warning; `/api/logout` answers; `.webp` served as `image/webp` | **PARTIAL** | Met on the candidate: `PASS: m9: nginx -t on the rendered conf`, `PASS: m9: no uninitialized go2rtc_stream_proxy warning after an authed request`, `PASS: m9: /api/logout reachable without auth (… HTTP 303)`. Mutations bite: dropping the warn-off gives warn count 1; dropping the `/api/logout` location gives 401; restart re-renders back to warn 0 / 303 `[TRANSCRIPT: m9-green-2-candidate.txt; m9-nginx-mutation.txt]`. **`.webp` mime was SKIP** (`no clips/*.webp yet`), so `image/webp` is not proven. That glob could never match Frigate's own thumbnails, which land in `clips/export/<id>.webp` (`record/export.py:585` @ v0.18.2); since the final-review fix wave the gate also looks there, and rehearsal phase B checks that nginx's internal `:5000` serves the real export thumbnail from `/clips/export/` as `image/webp`: **PENDING (rehearsal running)** |
| 10 | W-16 and W-11 acceptance re-run after the go2rtc bump, if landed | **NOT APPLICABLE (not landed)** | Neither is merged; nothing was run. T11 (S5 exec filter) is skipped for the same reason (see Follow-ups) |
| 11 | Size reported against 990,572,544 B (expected about +112 MB); floor retuned | **PARTIAL** (local candidate, not the Launchpad artifact) | Local candidate 1,106,501,632 B, +115,929,088 B vs rev 4 (see Builds). The floor retune from the Launchpad artifact is **PENDING** |

**Tally (2026-11-13, before the rehearsal result):** MET 1 (7b); PARTIAL 5 (1, 6, 7, 9, 11); NOT PROVEN 1 (5); NOT APPLICABLE 1 (10); PENDING 5 (2, 3, 4, 7a, 8). The spec's exit criterion (items 1–11 PASS on the Launchpad artifact, plus Joachim's go for `latest/edge`) is **not met yet**.

---

## Not proven by the gate VM

The gate VM (`m8-gate`) has no GPU render node and no Coral. In plain words, these are **not proven** by anything in this document:

- **The OpenVINO GPU detector path.** The VM's `gpu: openvino detector reporting` check is a capability SKIP, and auto-detect renders the `cpu` detector there.
- **VAAPI hardware decode** on the 8.0 default tree, including the go2rtc `#hardware` workaround in the README.
- **The D16 fdinfo denial rate.** The `/proc/<pid>/fdinfo` scan runs only with VAAPI or QSV camera hwaccel and `telemetry.stats.intel_gpu_stats` true. The gate's fdinfo block is `SKIP (capability): m9 fdinfo scan — needs a VAAPI render node`, so no denial was observed, no arm was added (the plan forbids speculative ones), and the audit-log volume question stays open. It needs Intel hardware, which is the hub or a laptop with an iGPU `[REPORT: progress.md, T9 Step 6]`.
- **Coral.** No TPU was attached (`SKIP (no capability): coral inference ran`). Upstream issue #24882 (Coral `detection_fps` stuck at 0 on 0.18.2) has no watch item run.
- **D7, old IR on openvino 2025.4: PENDING.** The prebuilt MO-converted IR is kept (D7). After the rehearsal, a manual CPU-only `detector=ov` probe in the VM will show whether it loads on openvino 2025.4. That would prove loading on **CPU only**. It says nothing about the GPU plugin, which is the reason upstream changed its converter.

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

1. **(a) Clean stop.** `spike/bin/frigate-db-quiesce` is the `frigate` app's `post-stop-command`. snapd renders it as systemd `ExecStopPost=` of the revision being stopped (snapd `wrappers/internal/service_unit_gen.go:180-182`), so it runs after stop, restart, refresh, revert and a crash (VM proof pending). The snapcraft reference says: "The command to run after the service is stopped. Requires the daemon key to be specified for the app." With the snap's python it runs `PRAGMA wal_checkpoint(TRUNCATE)` and then `PRAGMA journal_mode=DELETE`. It logs exactly one line, `frigate-db-quiesce: db=<B> wal_before=<B|absent> wal_after=<B|absent> shm_after=<B|absent> result=<ok|busy|busy=0,mode=…|timeout|error:<Class>>` (or `db=absent result=nodb`; `busy`: another connection still held the DB after sqlite's 10 s busy timeout, so the DELETE switch is skipped and the WAL stays), and never any DB content. It always exits 0. Frigate turns WAL back on at its next open (peewee `SqliteQueueDatabase`). No new plugs.
   - **Bound: 20 s plus a 3 s kill grace**, inside snapd's default 30 s stop timeout (`timeout.DefaultTimeout`; the app sets no `stop-timeout`, and systemd arms `ExecStopPost=` with `TimeoutStopSec`). **Deviation from the plan text:** the plan wrapped python in coreutils `timeout -k 3 "$T"`. That binary is not in snapd's AppArmor template (`interfaces/apparmor/template.go`, master, fetched 2026-11-13: `sleep`, `stat`, `mv` and `cp` are listed, `timeout` is not), and M7 saw `timeout: Permission denied` in this snap's confined pre-refresh hook (`docs/m7-findings.md:124`). Under confinement the plan's form would fail to exec, and the quiesce would never run. The same bound is therefore enforced inside python: a watchdog thread at T (sqlite3 releases the GIL while it waits on a lock), and `SIGALRM` at `SIG_DFL` at T+3 s, which the kernel delivers even if python is wedged. `tests/m9-packaging.test.sh` pins T+K ≤ 25 s, no `stop-timeout`, and no coreutils `timeout` in the script.
2. **(b) WAL-aware restore** (for downgrades from a later 0.18.x or 0.19; it cannot help the revert to 0.17.2). `frigate-run` restores through `db_restore` (`spike/bin/lib-db-restore.sh`). It moves `frigate.db`, `-wal` and `-shm` aside together as `frigate.db.incompatible-<ts>{,-wal,-shm}`, so the preserved copy still opens, and moves all three back if the copy fails. The log keeps the `frigate-run: restored $BACKUP` prefix that the gate and the rehearsal grep.
3. **Tests** (hermetic, real sqlite through the host `python3`, run by CI's `tests/*.test.sh` loop):
   - `tests/frigate-db-quiesce.test.sh`: stale WAL from a killed writer, no DB, a non-DB file, a held lock (bounded, `result=timeout`), and the revert path (quiesce, then 0.17.2's frozen `mv`/`cp`, gives the backup's content). The header journal-mode bytes 18-19 are read raw: `2 2` before, `1 1` after.
   - `tests/frigate-db-restore.test.sh`: restore over a live DB with a stale WAL must give **exactly the backup's content**, not just `integrity_check` = ok.
   - `tests/m9-packaging.test.sh` (section "S2 D24 clean stop").
   - VM side: `tests/spike-smoke.sh` block "m9: WAL quiesce on every stop path" (`snap stop`, `snap restart`, a reinstall-refresh, and `kill -9` of `MainPID`), and `tests/m9-rehearsal.sh` C/E/F quiesce checks plus phase G.
4. **Mutations** (hermetic, `[REPORT: walfix-report.md]`). The shipped Store rev 4/5 restore shape (sidecars not moved) makes the restore test FAIL with the restored DB reading **`ok live:70` against the backup's `ok backup:50`**: `integrity_check` passes, the content is the live DB's. That is why the test asserts content. Dropping `journal_mode=DELETE` FAILs on the header bytes only; SQLite removes the WAL on a clean last close anyway. Removing both bounds FAILs `bounded` (10 s). `exit "$rc"` FAILs both `exit 0` checks. Removing the `post-stop-command` line FAILs the static check, and on a stub harness it FAILs every `quiesce ran` check of the gate block.

**Labelled finding: the SHIPPED Store revisions carry the same latent bug.** Store rev 4 and rev 5 (0.17.2; `frigate-run` restore at `a39bfb0` `:136-145`, with no `post-stop-command`) move only `frigate.db` on a downgrade restore and leave a quiesce-free stop. Any downgrade *across a WAL* under those revisions can replay a stale WAL onto the restored backup: a revert from a later revision to rev 4/5, or a forged or real newer `.last-writer`, while a non-empty `-wal` exists. That is the same mechanism as above (whole-branch review, Important 4). The 0.18 snap's stop hook protects the move *off* 0.18. It cannot fix code already in the Store. Nothing here republishes rev 4/5. Whether to rebuild 0.17.2 with D24 is Joachim's decision.

**Scope check (other WAL databases).** At v0.18.2 every Frigate database handle (`app.py:192` migrations, `app.py:260` main, `record/record.py:29`, `record/cleanup.py:60`, `embeddings/maintainer.py:127`) opens `config.database.path`, which the snap's template sets to `__SNAP_COMMON__/db/frigate.db` (`spike/config/frigate-config.yml:21`). The vec0 tables live inside that same file. The only other `.db` file is upstream's pre-migration `backup.db` (`app.py:199-203`, `shutil.copyfile`). It is never opened in WAL mode, and the snap's backup/restore path does not swap it. So `frigate.db` is the only file in scope. (Upstream also truncates an oversized WAL at runtime, `record/cleanup.py:57-62`; that is not a stop-time guarantee.)

**Status: PENDING the re-run.** The fix is unit-tested and stub-tested only. It needs a re-pack, the gate (new WAL block) and rehearsal #2. C and E must show the candidate's `quiesce … result=ok` and `integrity_check` = `ok`, and G must pass. The `-wal` FINDING lines are taken while the candidate still runs, so a live `-wal` there is expected.

## Semantic-search reindex after upgrade (spec §5 item 7)

**Status: PENDING the full rehearsal. Finding, not gating** (orchestrator ruling, 04:27).

| Run | Evidence | Status |
|---|---|---|
| MUT033 run 2 (mutation run, not the real rehearsal) | `frigate.embeddings` ERROR `Unable to reindex tracked object embeddings`, raised in `drop_embeddings_tables` (`db/sqlitevecq.py:122` @ v0.18.2) as `peewee.OperationalError: SQL logic error`, on a DB whose vec tables vec0 0.1.3 wrote (no `_info` shadow table) `[REPORT: progress.md]` | observed |
| Reproduction outside Frigate | Not reproduced: on the host (vec0 0.1.3 creates the tables, then 0.1.9 with the stub + `DROP`) and on a copy of the VM's DB with the snap's python and the candidate's `vec0.so`, both succeed `[REPORT: progress.md; scratchpad/vecrepro]`. The in-process cause is unknown | not reproduced |
| Upstream workaround | Upstream #24407's `_restore_vec_info_table` stub is present at v0.18.2 (`db/sqlitevecq.py:103`, called from `drop_embeddings_tables` at `:121`) | present |
| Full rehearsal | PENDING. If it reproduces: record the traceback, the phase-A vec table layout and whether the stub ran, and treat it as an upstream defect | PENDING |

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

A second local artifact exists for the rehearsal's mutation run only: the candidate minus `opt/frigate/migrations/033_create_export_case_table.py` (1,074,929,664 B). It is not a deliverable.

---

## W-19: the nginx module sources were dead

The first pack failed because `github.com/kaltura/nginx-vod-module` and `github.com/kaltura/nginx-secure-token-module` return **404** (`gh api` on both: HTTP 404). Upstream Frigate v0.17.2 and v0.18.2 `docker/main/build_nginx.sh` pin the same two kaltura tags (vod 1.31, secure-token 1.5), so upstream's own image build is affected too `[REPORT: w19-report.md]`.

Fix: branch `fix/nginx-module-sources` @ **`95c7233`** (full `95c72330daf5d941473ead27caf872c7ff6cc245`, off `main` `a39bfb0`, pushed by the orchestrator as PR #7; opening or merging it is Joachim's), **cherry-picked onto M9 as `ecf63dd`**. Content stays kaltura 1.31 and 1.5, file for file. Both replacements are pinned by sha256 and proven tree-identical against Software Heritage (SWH), which archived the original repos:

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

---

## Follow-ups

1. **T11 / S5, the bridge exec filter (D13), is pending and waits for W-16.** It touches the same generator and template. Until it ships, this snap does **not** filter `exec:`/`echo:`/`expr:` go2rtc streams, while upstream 0.18 does. The README says so.
2. **D16 measurement on Intel hardware:** run the gate with `preset-vaapi` on a machine with a render node, classify any new `/proc` denials with journal quotes and report the rate.
3. **Hub soak (D15):** the field soak waits for the hub (W-7) and reachable cameras. Not an M9 exit criterion. #24882 (Coral `detection_fps` 0) gets a watch item there.
4. **W-17 is open (D18).** At v0.18.2 `/config` shows go2rtc `rtsp`/`api`/`mqtt` credentials to logged-in users. Re-checked 2026-11-13: `grep -c _redact_go2rtc_credentials frigate/api/app.py` on the v0.18.2 tag is **0**. Upstream's redaction landed on `dev` only (#24719). Recorded in the README under "Known upstream issues".
5. **Residual advisories on 0.18.2:** GHSA-w3c4 (webpush SSRF), GHSA-4xp7 (go2rtc RTSP negative `Content-Length` panic; the same code is in go2rtc 1.9.13) and GHSA-74x4 (camera ACL bypass via nginx static locations; the snap mirrors upstream's layout). Exploitability on this snap is not assessed.
6. **pip wheels are not hash-pinned** (`spike/wheels-src/requirements-core.txt` has no `--require-hashes`), noticed in passing by the W-19 worker. A separate supply-chain gap.
7. **Fork longevity** for the two nginx module sources (W-19 section).
8. **Not run, from the spec:** the scratch-build mutations for items 6 (no 8.0 tree) and 7 (no `vec0.so`).
9. **D7, OpenVINO IR:** measure upstream's newly converted IR (`build_ov_model.py`, openvino ≥ 2026.2) against our MO-converted IR (load, inference speed, GPU plugin behaviour), as D7 promises.
10. **Test-clip detection (time-boxed, 45 min, non-gating; finding only):** find out why the looping test clip never triggers motion or detection in the VM (`detection_fps` 0.0, `inference_speed` 10.0 sentinel), via Frigate's debug views. Starting point: the `snap/snapcraft.yaml` frigate-src note that the loop's constant motion never lets stock calibration exit.
11. **`frigate-run` restore and the WAL:** ~~follow-up~~ **fixed in M9 (D24)** (rehearsal #1 `integrity_check` failed; see "Revert DB integrity"). Re-run PENDING. Open: the shipped Store rev 4/5 carry the same latent bug (labelled finding there).

---

## Hand-off: Launchpad build and final gate (PENDING, for the orchestrator)

Builders never run this: it needs Joachim's Launchpad login and uploads the tree to Launchpad (public build logs). No push, credentials or Store upload were used.

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

   On the local candidate (`b05bdf1d…`) this block prints `squashfs OK`, `version OK`, five `has` lines, `0001 patch applied` and `version.py stamp OK` `[VERIFIED: 2026-11-13, final-review fix wave]`.
4. Then, in the gate VM against the Launchpad artifact, both under the suite lock: the harness, then `tests/m9-rehearsal.sh`. Expected: 0 FAIL, denials 0 unexpected, rehearsal exit 0.
   D24 adds one artifact check: `unsquashfs -cat "$F" meta/snap.yaml | grep -q 'post-stop-command: bin/frigate-db-quiesce' && echo "D24 hook OK" || echo "D24 hook MISSING"`. The harness's "m9: WAL quiesce on every stop path" block and rehearsal phase G must pass, and C/E/F must each show the candidate's `frigate-db-quiesce: … result=ok`. Mutation (controller, VM, once): the candidate repacked without the `post-stop-command` line must FAIL the harness block's `quiesce ran` checks (procedure in the block's comment).
   - **Labelled finding (D24): the shipped Store revisions rev 4/5 (0.17.2) carry the same latent WAL bug** for any downgrade across a WAL (sidecars not moved, no stop hook; review Important 4). See "Revert DB integrity". The 0.18 hook protects only the move off 0.18. A 0.17.2 rebuild with D24 is Joachim's call.
5. Size floor in `tests/spike-smoke.sh`: `floor_to_MiB(0.85 × size)` of the Launchpad artifact, arithmetic in the comment (M8 style), then `bash tests/m9-packaging.test.sh`.

### PENDING sections (to be filled in; no values exist yet)

- **Launchpad artifact** (sha256, size, artifact checks): PENDING.
- **Final gate on the Launchpad artifact:** PENDING.
- **Size-floor retune:** PENDING.
- **Rehearsal results** (items 2, 3, 4, 6 real thumbnail, 7 reindex, 7a, 8, 9 `.webp` mime on the real export thumbnail): PENDING (rehearsal running). Rehearsal exit 0 covers the gating checks only; the reindex completion and the revert WAL/integrity rows above are read from `findings.txt`.
- **D7 CPU-only `detector=ov` probe:** PENDING (after the rehearsal).
