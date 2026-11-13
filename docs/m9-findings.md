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
| 2 | Upgrade rehearsal from rev 5 (0.17.2): seeded state, refresh, `frigate-pre-0.17.2-r<rev>.db`, migrations 033/034/035, API still lists seeded data, `config.yml` at `0.18-0`, `backup_config.yaml` equal and 0600, `validate-config` 0 | **PENDING (rehearsal running)** | Script `tests/m9-rehearsal.sh` (`d6ac31b`..`cb67857`) is reviewed clean. Baseline will be rev 4 (deviation above). No result yet |
| 3 | Revert rehearsal: `DOWNGRADE detected`, stamped backup restored, `config.yml` is the 0.17-0 file, 0.17.2 starts, detects and records | **PENDING (rehearsal running)** | Not run yet. The gate's own rollback block (a different, M7-style check) passes on the candidate: `PASS: rollback: downgrade detected + restored` `[TRANSCRIPT: m9-green-2-candidate.txt]`. That is not this rehearsal. The README's revert statement is spec-derived (D11/D12, snapd per-revision $SNAP_DATA); the revert rehearsal result is PENDING and will confirm or correct it |
| 4 | Re-refresh: migration runs again cleanly from the restored state | **PENDING (rehearsal running)** | Not run yet. The README's revert statement is spec-derived (D11/D12, snapd per-revision $SNAP_DATA); the revert rehearsal result is PENDING and will confirm or correct it |
| 5 | Detection: OpenVINO GPU and CPU, Coral when present; speed against M3/M6 | **NOT PROVEN** (hardware) | In the VM: `SKIP (no capability): gpu: openvino detector reporting … no Intel(0x8086)/AMD(0x1002) render node`, `SKIP (no capability): coral inference ran — no Coral USB TPU`, livecam MONEY lines SKIP `[TRANSCRIPT: m9-green-2-candidate.txt]`. A CPU-only `detector=ov` probe (D7) is PENDING after the rehearsal and will prove loading on CPU only. See "Not proven by the gate VM" |
| 6 | ffmpeg 8 pipelines; hardcoded `/usr/lib/ffmpeg/8.0/bin/ffmpeg` (deterministic in-sandbox webp; real export thumbnail in rehearsal); mutation: scratch build without the 8.0 tree makes the check FAIL | **PARTIAL** | Deterministic part met on the candidate: `PASS: m9: 8.0 ffmpeg resolves in the frigate sandbox and encodes webp`, `PASS: ffmpeg tree 5.0/7.0/8.0 present+runs` `[TRANSCRIPT: m9-green-2-candidate.txt]`. Red run on rev 4 FAILs the same checks (no 8.0 tree) `[TRANSCRIPT: m9-red-on-rev4.txt]`, which is a red, not the spec's scratch-build mutation; that scratch-build mutation was **not run**. Real export thumbnail: **PENDING (rehearsal running)** |
| 7 | Semantic search: vec0 0.1.9 loads on every start; reindex succeeds on a DB with vec tables written by 0.1.3 | **PARTIAL** | `PASS: m9: vec0 loaded` at 8 Frigate starts on the candidate (recounted from the transcript: 8 `PASS` lines; the ledger said 9 but lists the same 8): fresh install, rollback reinstall-refresh, rollback proof 2, backup-select, bridge injection, bridge restore, semantic search, semantic restore `[TRANSCRIPT: m9-green-2-candidate.txt; REPORT: progress.md]`. Reindex on a 0.1.3-written DB: **PENDING (rehearsal running)** and its completion is network-gated (model download). The spec's mutation (remove `vec0.so` from a scratch build) was **not run** |
| 7a | Backups (D21): after two consecutive 0.18 refreshes a `frigate-pre-0.17.2-*` backup remains and a revert restores it; finding: 0.17.2 booted on a 0.18-migrated DB | **PENDING (rehearsal running)** | The retention rule is unit-tested hermetically (`tests/pre-refresh.test.sh`, `19820e7`). The rehearsal run is outstanding |
| 7b | `go2rtc.ffmpeg.bin` follows `ffmpeg.path` (D22); `LIBAVFORMAT_VERSION_MAJOR` equals the 8.0 tree's major (D23) | **MET** (local candidate) | `PASS: m9: go2rtc ffmpeg.bin follows ffmpeg.path 7.0 (D22)`, `PASS: m9: go2rtc ffmpeg.bin back on the 8.0 default`, `PASS: m9: LIBAVFORMAT_VERSION_MAJOR=62 in the frigate env (D23)` `[TRANSCRIPT: m9-green-2-candidate.txt]`. 62 matches the real 8.0 binary: `libavformat    62. 12.102` `[REPORT: progress.md, R6 build check]` |
| 8 | Retention: a segment older than the configured retention is deleted within one maintenance cycle (#24182) | **PENDING (rehearsal running)** | Rehearsal phase; the 033-migration-absent mutation run was in progress at the time of writing (2026-11-13) and has no recorded result `[REPORT: progress.md]` |
| 9 | nginx: `nginx -t`; no "uninitialized variable" warning; `/api/logout` answers; `.webp` served as `image/webp` | **PARTIAL** | Met on the candidate: `PASS: m9: nginx -t on the rendered conf`, `PASS: m9: no uninitialized go2rtc_stream_proxy warning after an authed request`, `PASS: m9: /api/logout reachable without auth (… HTTP 303)`. Mutations bite: dropping the warn-off gives warn count 1; dropping the `/api/logout` location gives 401; restart re-renders back to warn 0 / 303 `[TRANSCRIPT: m9-green-2-candidate.txt; m9-nginx-mutation.txt]`. **`.webp` mime was SKIP** (`no clips/*.webp yet`), so `image/webp` is not proven |
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

---

## Hand-off: Launchpad build and final gate (PENDING, for the orchestrator)

Builders never run this: it needs Joachim's Launchpad login and uploads the tree to Launchpad (public build logs). No push, credentials or Store upload were used.

1. Branch head sha: the head of `feat/m9-frigate-0.18` when handed off (this document's commit).
2. From a **full** (non-shallow) clone at that sha:

   ```bash
   MAX_ATTEMPTS=3 .github/scripts/remote-build.sh amd64
   ```

   The alternative is to open the PR and let `pr-build-snap.yml` run it.
3. Artifact checks on the returned `frigate_0.18.2_amd64.snap` (read-only, no install; paste the output into the report). The `version` line is **corrected** from the plan: snapcraft writes it unquoted in `meta/snap.yaml`, so the plan's quoted-literal grep would false-fail.

   ```bash
   F=frigate_0.18.2_amd64.snap
   sha256sum "$F"; stat -c %s "$F"
   unsquashfs -s "$F" >/dev/null && echo "squashfs OK"
   unsquashfs -c "$F" meta/snap.yaml | grep -qxE "version: '?0\.18\.2'?" && echo "version OK"
   for p in usr/lib/ffmpeg/5.0/bin/ffmpeg usr/lib/ffmpeg/7.0/bin/ffmpeg usr/lib/ffmpeg/8.0/bin/ffmpeg usr/local/lib/vec0.so usr/local/go2rtc/bin/go2rtc; do
     unsquashfs -l "$F" | grep -q "squashfs-root/$p\$" && echo "has $p" || echo "MISSING $p"
   done
   unsquashfs -c "$F" opt/frigate/frigate/const.py | grep -q 'FRIGATE_CONFIG_DIR' && echo "0001 patch applied"
   ```
4. Then, in the gate VM against the Launchpad artifact, both under the suite lock: the harness, then `tests/m9-rehearsal.sh`. Expected: 0 FAIL, denials 0 unexpected, rehearsal exit 0.
5. Size floor in `tests/spike-smoke.sh`: `floor_to_MiB(0.85 × size)` of the Launchpad artifact, arithmetic in the comment (M8 style), then `bash tests/m9-packaging.test.sh`.

### PENDING sections (to be filled in; no values exist yet)

- **Launchpad artifact** (sha256, size, artifact checks): PENDING.
- **Final gate on the Launchpad artifact:** PENDING.
- **Size-floor retune:** PENDING.
- **Rehearsal results** (items 2, 3, 4, 6 real thumbnail, 7 reindex, 7a, 8): PENDING (rehearsal running).
- **D7 CPU-only `detector=ov` probe:** PENDING (after the rehearsal).
