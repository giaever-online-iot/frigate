# W-23 Findings: the hub's Frigate on the real cameras (helper build)

Evidence from the W-23 build, in the order the acceptance steps of the spec
(`docs/superpowers/specs/2026-11-16-hub-real-cameras-design.md` §9.2) produce it. Every address below is a
loopback address (127.0.0.x); every camera id and login code is a made-up test canary.

## S2 (laptop, fake camera)

**Test:** `tests/ezviz/serve-ezviz.test.sh` (W-23 T15), run under `flock -w 3600 /tmp/claude-1000/chim-suites.lock`
on 2026-11-19.
- **After the review fix round: 53 ok, 0 FAIL** (192 s of scenarios, 3 min 17 s wall time). That is 52 checks plus
  the check-count guard. This round added checks 11 and 11m and the lead-in assertions.
- **Before it:** two consecutive runs gave 43 ok / 0 FAIL.
- **The first run** (before the frame-count fix described below) gave 41 ok / 2 FAIL (checks 1 and 10).

**Identities.**
- Snap file: the local amd64 `frigate_0.18.2_amd64.snap`, sha256
  `6c908822da0a173dd8914888edf197a5217c7e876a1fe4fbe846e1606824098e`, matching its recorded sha256.
- go2rtc from that file: `go2rtc version 1.9.14 (b5948cf) linux/amd64`.
- ffmpeg from that file (directory `usr/lib/ffmpeg/8.0/`): `ffmpeg version n8.1.1-9-g58d4114d36-20260602`. The
  directory is named 8.0, but the binary reports 8.1.1. T12 found the same thing.
- Helper runtime: the W-23 venv (CPython 3.12 with the hash-locked wheels), linked in as `$SNAP/opt/ezviz-py`.
- Fake camera: `tests/ezviz/fakecam.py` on 127.0.0.1 at a random port. The camera file accepts any port, so the
  two cameras of check 10 are two fake instances on two ports of 127.0.0.1. A second loopback address was not
  needed. The clip is `fixtures.make_es` (4 s, 1080p25 H.265, an IDR every 2 s).

**Counts (run of record).**

| Check | Result | Evidence |
|---|---|---|
| 1 | ok | cam1 **251 frames** in 10 s, 0 decode errors after the first decoded frame (66 join errors before it, see below); 1 login (fix-round run: 251 frames, lead-in 0.72 s, first frame a keyframe) |
| 2 | ok | kill -9 go2rtc: ledger `stop` (Pdeathsig, under 0.1 s); restart: 2 `budget_wait` refusals, 0 camera contacts, then exactly 1 login, 79.9 s after the previous attempt |
| 3 | ok | consumer removed and re-added: logins 2 → 2, ledger records 7 → 7, same helper pid |
| 4 | ok | Pdeathsig on a go2rtc SIGTERM (F1 via PR_SET_PDEATHSIG): the ledger ends `stop` (a SIGKILL would write none), and the helper is gone under 0.2 s later |
| 5 | ok | the operator `cam1` was dropped with 1 redacted warning; 0 canary hits; 1 helper, 1 login |
| 6 | ok | the start-time preload fails in `budget_wait`; `GET /api/preload` lists cam1 at **+91.7 s** (limit 150 s); remove/re-add: 0 new logins |
| 6m | ok | without the re-arm line, check 6's verdict is FAIL (never listed); the consumer remove/re-add costs 1 login |
| 7 | ok | clean restart after a **70.0 s** published session: exactly 1 new login, `login_ok` **2.1 s** after the SIGTERM |
| 8a | ok | GETs at +30.1 s (503, injected) and +60.1 s (200); 0 PUT, 0 `stop`, 1 login in total |
| 8b | ok | PUT held 41.6 s, then 200; 0 requests while it was open; the next request came 30.0 s after the answer; 1 login |
| 9 | ok | 1 warning each for local_auth, base_path and allow_paths; 0 value canaries in the logs; re-armed (listed, `armed`); 1 attempt |
| 9m | ok | without step 7 of the generator, check 9's verdict is FAIL; `ezviz-rearm: api_refused`, 0 `armed`, 0 attempts |
| 10 | ok | cam1 **250** and cam2 **251 frames** in 10 s, 0 errors after sync; 1 login each; 2 helpers (fix-round run: 250/250, lead-in 1.44/0.92 s, both on a keyframe) |
| 11 | ok | go2rtc's own producer close (`DELETE /api/preload?src=cam1` drops the only consumer, HTTP 200): `#killsignal=15` makes the helper write `stop` (P3), gone under 0.2 s; the next decision writes no `unknown_end` |
| 11m | ok | with `#killsignal=15#killtimeout=5` cut from the generator copy, check 11's verdict is FAIL: no own end record (last `published`), and the next decision writes a synthetic `unknown_end` |

**Logins seen by the fake cameras:** scenario A (checks 1, 2, 3, 4, 5, 7): 3 in total, one per go2rtc start
(1 → 2 at the restart of check 2, unchanged by check 3, 2 → 3 at the restart of check 7). Scenarios 6, 8a, 8b, 9:
1 each. 6m: 1, made by the consumer. 9m: 0. Scenario 10: 1 per camera.

**Timings.** Check 6 listed cam1 at +91.7 s (the cap opened at +90 s, and the re-arm round at about +90 s armed
it). Check 7: `login_ok` 2.1 s after the SIGTERM, or 1.9 s after go2rtc-run restarted. Across all three runs both
times agreed within 0.1 s (check 6: 91.6, 91.7 and 91.7 s; check 7: 2.1 s each time).

**Re-arm timing used:** production values everywhere. The first round is at 30 s, then every 30 s, with a 75 s
client timeout. `--first-delay` and `--period` were never passed. The fault proxy fails a GET with an immediate 503,
and it holds a PUT for 40 s before forwarding it.

**Finding S2-1: a consumer joining a preloaded stream starts mid-GOP. The test's frame measurement was changed;
the stream itself is fine.** go2rtc 1.9.14 keeps no GOP cache. A consumer that attaches to the running producer
gets the packets from the moment it joins. Its HEVC decoder rejects the frames before the first IDR ("Could not find
ref with POC …", "Error constructing the frame RPS"). With `-t 10`, that left 222 to 232 frames and 38 to 58 error
lines (first run, checks 1 and 10).
- The clip decodes cleanly on its own: 100 frames, 0 errors.
- From the first decoded frame on, the stream had 0 errors at a full 25 fps.

**The S2-1 ruling (T15 review).** Checks 1 and 10 decode 13 s with `showinfo` and count frames and errors from the
first decoded frame:
- (a) 0 decoder error lines after the first decoded frame. The join errors before it are reported as evidence and
  not asserted.
- (b) The lead-in is bounded and asserted. The first decoded frame's pts, relative to the consumer's start, must be
  at most the fake's GOP (2 s) plus 1 s. That frame (`n:0`) must be a keyframe (`iskey:1`).
- (c) The window is pts-based: the frames whose pts lie in the 10 s after the first decoded frame. ≥ 250 is required.

**Jitter (a flake risk, no spec change now).** The pts come from the publisher's wallclock: the helper's ffmpeg runs
with `-use_wallclock_as_timestamps 1`, and the frames are paced by the fake. The jitter is about 0.5 ms. A
25 fps stream gives exactly 250 frames in a 10 s window, so the window can in principle count 249 with no frame
dropped. The runs so far counted 250 or 251.

The same join happens to Frigate's own ffmpeg on every restart of a preloaded stream (D2). It costs up to one GOP of
frames and is not a login. tests/hub/serve.test.sh never saw it, because there every consumer started its own
producer at an IDR.

**Part B note.** Real Frigate consumers will log start-of-stream decode errors for up to one camera GOP each time
they (re)connect to a preloaded camera stream. Expect those lines at S5 and in the soak. They are not a stream fault.

**Test-only deviations** (inside the fake `$SNAP` and config.yml only):
- the private go2rtc-run has one added line that moves the API from `127.0.0.1:1984` to a free loopback port after
  generation. The test asserts this diff;
- config.yml puts RTSP and WebRTC on free loopback ports, and sets `webrtc.candidates: []` (no STUN lookup) and
  `srtp.listen: ""`;
- `EZVIZ_REARM_API` points the loop at the test API port, or at the fault proxy;
- `$SNAP/usr/bin/python3.11` runs the system python3 with PyYAML.

**Not proven by S2:**
- the AppArmor profile: everything here is unconfined;
- the arm64 binaries;
- the real camera's login and stream, beyond what the fake models (spec §10 item 21);
- Frigate itself as the consumer: the consumers are ffmpeg RTSP clients.

## Part B notes (the hub steps)

These come from the plan; nothing here was run on the hub.

**A clock behind at boot: a known open risk (plan, "What this plan cannot verify offline", N9).** The hub has no RTC
battery, so after a cold boot its wall clock can be behind until NTP syncs. The helper's budget (the 3-per-3600 s cap
and the 60 s spacing) counts `attempt` records by their own `t` stamps. The plan says: "A wall clock that is
**behind** at boot (no RTC battery after a power loss, before NTP syncs): attempts are stamped in the past and leave
the window early once NTP corrects the clock. No test covers it. The cap would then allow up to 3 more logins inside
the real hour once. Follow-up for the maintainer *(N9)*." A clock that is **ahead** is covered: a future-dated record
counts inside the window and the spacing (Task 4 `test_future_dated_attempt_counts_in_window_and_spacing`).
- **What to look for at S11** (the cold boot): a jump in the ledger `t` values at boot. That is, records written
  after the boot that are dated earlier than the last record before the reboot, or a forward jump between two
  consecutive records soon after the boot (the moment NTP set the clock). Read the records themselves, for example
  with P8's `X exec 'tail -n 2 /var/snap/frigate/common/ezviz/state/<name>.ledger; date +%s'`, and compare the
  helpers' logins at boot with the real hour.
- **Mitigation chosen by the plan:** none, a follow-up for the maintainer.

**`ledger_damaged` (plan P8).** A damaged ledger line that is not the last one refuses with class `ledger_damaged`
(exit 75, no camera contact) until an operator moves the file away (`sudo mv <ledger> <ledger>.damaged`; the next
decision starts empty, and the latch file still applies). `ezviz-check` prints `ledger_damaged` and `ezviz-ledger.sh`
prints `ledger <name>: damaged`, so the state is visible.
- **The operator rule:** move a damaged ledger only when its newest record is 3600 s or more old. Check first with
  `X exec 'tail -n 2 /var/snap/frigate/common/ezviz/state/<name>.ledger; date +%s'`. Otherwise the move forgets the
  last hour's attempts (up to 3 more logins that hour) and the latch row.

## CI (Task 22)

`.github/workflows/lint-test.yml` runs the W-23 work in two places:
- the existing `tests/*.test.sh tests/*/*.test.sh` loop, which now also picks up `tests/ezviz/*.test.sh` and the new
  `tests/hub/*.test.sh`, plus `tests/go2rtc-run.test.sh`, `tests/disk-guard.test.sh`, `tests/configure-ezviz.test.sh`
  and `tests/w23-packaging.test.sh`;
- a new step, "ezviz helper tests (venv from the hash lock)", which runs
  `python -m unittest discover -s tests/ezviz` on the venv that `tests/ezviz/venv.sh` builds from
  `spike/ezviz/requirements.txt`. The repo-wide `discover -s tests` does not reach `tests/ezviz`, which is not a package.

Also changed in the workflow:
- the shellcheck step's targets now include `tests/hub/*.sh` and `tests/ezviz/*.sh`, with the same flags. All 70 files
  passed locally on 19 Nov.
- the test step installs `python3.12-venv` if `ensurepip` is missing, because `make-config.test.sh` and the helper suite
  both build the hash-locked venv.

**What SKIPs in CI, and why:**
- `tests/ezviz/serve-ezviz.test.sh` (S2): there is no local amd64 snap file on the runner, so there is no go2rtc or
  ffmpeg 8.0. It prints a `SKIP` line and exits 0. S2's evidence is the laptop run above.
- `test_probe.py`'s fake-camera runs need a real ffmpeg (`W23_REAL_FFMPEG`, the snap file or `ffmpeg` on PATH). They
  SKIP with a reason when none is found.
- `configure-ezviz.test.sh` SKIPs only if `python3 -m venv` is unavailable.

**First green CI run:** the orchestrator records its `Ran N tests … (skipped=M)` line here after the push. The local
equivalent is in "Suite counts" below.

**First CI run of PR #11 (head ca3164e): red at its first step, shellcheck.**
- The runner is `ubuntu-latest` = ubuntu-26.04 (the job log says `Image: ubuntu-26.04`). Its image has shellcheck
  0.11.0-2 preinstalled; the apt step only reports it as already the newest version. 0.11 flags SC2319 (`$?` read right
  after a `[ ]` test), which the laptop's shellcheck 0.9.0 does not know.
- Every local shellcheck result in this document before 19 Nov evening, including the "70 files passed" line above,
  came from 0.9.0. They are not evidence for the runner.
- The two findings:
  - `tests/hub/ezviz-ledger.test.sh:54`, new on this branch;
  - `tests/hub/ssh-exec.test.sh:73`. This file is unchanged from origin/main, but main's CI never linted it: main's
    shellcheck targets are `spike/bin/* snap/hooks/* tests/*.sh`, and its run of 16 Nov on the same image was green.
    This branch's wider target list (C24, adding `tests/hub/*.sh` and `tests/ezviz/*.sh`) lints it, and the runner's
    shellcheck 0.11 flags it.
- Both became `"$([ -e f ] && echo 0 || echo 1)"`, with the same expected value (de3ec8c and 05b9499). The suites give
  the same counts before and after (26 ok and 43 ok).
- Because step 1 failed, none of the later steps ran in that CI run.

**Run shellcheck with the runner's version.** 0.11.x, for example `shellcheck-py==0.11.0.1` (it prints
`version: 0.11.0`) in a private venv such as `~/.cache/frigate-w23/shellcheck011`. Put only the `shellcheck` binary on
PATH, through a directory holding just a symlink. The venv's `bin/` also holds a `python3`, which would shadow the
system one and its `python3-yaml`: in a first replay this turned `discover -s tests` red and skipped the make-config
cross-checks.

**Local replay of the whole workflow** (19 Nov, on this laptop's Ubuntu 24.04 noble userland, NOT the runner's 26.04):
- Setup: a fresh clone at 88f7ccf, an empty HOME (no `~/.cache`, so no snap file and no venvs), TMPDIR unset, the
  system python3/python3.12 3.12.3 with `python3-yaml`, and shellcheck 0.11.0.
- Step 1, shellcheck over 70 targets with the lint-test flags: rc 0 (rc 1 at 66fb66c, the two findings above).
- Step 2, `.github/scripts` shellcheck: rc 0.
- Step 3, `.github/scripts` unit tests: all six pass.
- Step 4, the `tests/*.test.sh tests/*/*.test.sh` loop: all 32 files rc 0, 0 FAIL. Then `discover -s tests` 27 OK and
  `discover -s tests/arm64-vm` 10 OK.
  - Three suites SKIP, as on the runner, for lack of the local amd64 snap file: `serve-ezviz`, `hub/serve` and
    `hub/make-clips`.
- Step 5, the ezviz helper tests on the venv that `tests/ezviz/venv.sh` built from the hash lock (pip from the index,
  in the empty HOME): `Ran 259 tests`, `OK (skipped=13)`.
  - All 13 skips are `test_probe.py`'s fake-camera runs: "no real ffmpeg". They include the end-to-end regression
    tests for this branch's reader fixes (`test_real_shape_camera_publishes`, `test_b2_descriptor_camera_publishes`,
    `test_rtp_ts_stats_are_video_only`).
  - Fixed in fe1dfe8. The workflow now installs Ubuntu's `ffmpeg` before this step and fails the step unless
    unittest's final verdict is a plain `OK`, so `OK (skipped=N)` is red. The step gets `timeout-minutes: 30`. The guard
    was tightened in 58b4b93 (below).
  - Replay of that step's `run:` block, taken verbatim from the YAML and run under `bash -e`, on a fresh clone with an
    empty HOME. The ffmpeg was Ubuntu noble's archive package `7:6.1.1-3ubuntu5`, unpacked without root from
    `apt-get download`; that is noble's, not the runner's (resolute has `7:8.0.1-3ubuntu2`). Result: `Ran 259 tests`,
    `OK`, 0 skipped, step rc 0, 586 s wall time including the venv build.
  - Mutant, the same replay with ffmpeg hidden: unittest says `OK (skipped=13)`, and the step fails with rc 1 and
    `::error::ezviz helper tests: verdict 'OK (skipped=13)', want a plain OK`.


**The runner is ubuntu-26.04, not noble (round 6).**
- Sources:
  - the PR #11 job log (`Image: ubuntu-26.04`);
  - the image's software list (`actions/runner-images`, `images/ubuntu/Ubuntu2604-Readme.md`: 26.04.1 LTS). That
    published list is for image 20261111.196.1, which is the 16 Nov run's image. PR #11's run used image
    20261111.82.6 (Ubuntu 26.04.1), whose software-list link returns 404. The re-review found that the published .196
    and .202 lists agree on every tool the workflow uses;
  - packages.ubuntu.com for resolute.
- What this means for each tool the workflow uses:
  - `shellcheck`: 0.11.0-2, preinstalled, and in the archive.
  - `python3-yaml`: not preinstalled; the archive has 6.0.3-1build1, for the system Python 3.14.4.
  - `ffmpeg`: not preinstalled; the archive has 7:8.0.1-3ubuntu2.
  - `python3.12` and `python3.12-venv`: NOT in resolute (the archive search gives no results), so the old
    `apt-get install python3.12-venv` fallback could never work. 3.12.16 is only in the image's tool cache.
  - The test scripts' other tools are in the image: jq, yq 4.54.3, curl, wget, openssl, sqlite3, binutils (readelf),
    file, netcat, and coreutils/util-linux (timeout, sha256sum, setsid, flock).
  - squashfs-tools and qemu are not in the image. The tests that would use them skip or stub without the snap file.
- Fix in 58b4b93:
  - `actions/setup-python@v7` (the latest release is v7.1.0) with `python-version: '3.12'` and
    `update-environment: false`, then a step that links only `python3.12` into a directory on `$GITHUB_PATH`. That keeps
    `python3` the system 3.14 with its `python3-yaml`.
  - The test step fails with an `::error::` line if python3.12 with ensurepip is missing.
  - The helper step's guard now captures unittest's rc, and needs rc 0 with unittest's own summary as the last two
    non-empty lines: `Ran N tests in Xs`, then a plain `OK`. Every red path prints an `::error::` line.
  - A 16-case harness, running the step verbatim under `bash -e`: only the two genuine passes are green. Against the
    round-5 guard, 9 cases were wrong; one of them was a late writer's `OK` that turned a skip green.
  - Accepted as is: a leaked child that writes a complete fake `Ran N tests in Xs` and `OK` after a skipped run still
    passes the guard. Only a check of unittest's result object, rather than its text, would beat that.
- Replay closer to the runner, still on the noble kernel and libc:
  - Setup: a PATH made only of a symlink farm. It has the system binaries minus what 26.04 lacks (squashfs-tools, qemu)
    and minus every python and ffmpeg. `python3` is a CPython 3.14.7 venv with PyYAML 6.0.3, standing in for the system
    3.14 with `python3-yaml`. python3.12 is `/usr/bin/python3.12`, linked by the workflow's own step, standing in for
    setup-python's 3.12.16. ffmpeg is 8.1.1 (the snap's build; resolute's 8.0.1 cannot run on noble). Plus shellcheck
    0.11 and yq.
  - Every `run:` step of the YAML, verbatim under `bash -e`, on a fresh clone at 58b4b93 with an empty HOME. Results:
    - the shellcheck steps, the `.github/scripts` tests and the python3.12 link step: rc 0;
    - the test loop: rc 0 in 149 s, with `discover -s tests` 27 OK and arm64-vm 10 OK under Python 3.14;
    - the ezviz helper step: rc 0 in 603 s, `Ran 259 tests`, `OK`, 0 skipped.
  - A first replay without yq failed `m7c-arch.test.sh`. That was my farm's error: the image has yq.
- NOT verified here: the real 26.04 userland (glibc, resolute's ffmpeg 8.0.1, the system Python 3.14.4 itself), the
  setup-python action, and the tool-cache 3.12.16. There was no container runtime without root on the laptop (no docker
  or podman; LXD needs root). The first green CI run is the evidence for the runner.

## Known pre-existing flake: `tests/hub/serve.test.sh` (clip mode)

The whole-branch review saw `tests/hub/serve.test.sh` fail once in two runs on 5d46c3d: cam1 had 212 frames and 78
decode errors. Fix wave 1 (N8) ran it on 19 Nov, one run at a time under the suite lock. Each run alternated between
the branch head and a scratch copy of origin/main 9000f91 (`git archive`), so both sides saw the same machine state.

| Tree | Runs | Failed |
|---|---|---|
| origin/main 9000f91, unchanged | 32 | 3 |
| branch head | 24 | 6 |
| main with the branch's generator | 8 | 3 |
| main with the branch's generator, D20 `base_path` only | 8 | 3 |
| main with the branch's generator, D20 `local_auth` only | 8 | 4 |
| main with the branch's generator minus both D20 keys (output byte-identical to main's) | 8 | 2 |

- **Signature:** the same in every failure, on both sides. One camera stream (cam1 or cam2; once both) decodes too
  few frames in 10 s and logs 74–88 decoder error lines, while the other streams are clean. This is the mid-GOP join
  signature of S2-1, seen here in clip mode.
- **What the test hands go2rtc:** this test never runs `go2rtc-run`, so the re-arm loop is not involved. It calls the
  generator in its 4-argument form. In that form W-23 changes only the D20 keys `api.local_auth: false` and
  `api.base_path: ''`.
- **Conclusion:** the flake is pre-existing. Unchanged main failed 3 of 32 runs with the same signature, and so did
  the control whose output is byte-identical to main's. Failures clustered in time: all 21 failures came in rounds 1–4
  (main's three in round 4), and the last balanced round (main and head alternating, 10 runs each) failed 0 of 20.
- **What the numbers do not settle:** in these runs the trees that write the D20 keys failed more often (16 of 48)
  than the trees whose output equals main's (5 of 40). The clustering and the unbalanced ordering of the early rounds
  make that comparison weak, and no mechanism was found. Both keys are default values that the re-arm needs (D20).
- **What was done:** main's test was not changed. The flake is recorded here, with these numbers, for a follow-up.

## Suite counts

These are the counts of the fix wave 1 final run: one run on 19 Nov of tree aac7821, under the suite lock, with
`W23_VENV` naming a private venv that `tests/ezviz/venv.sh` built from the hash lock. The later commit 68a0080 changes
only the plan document, which no test reads.

| Suite | Result |
|---|---|
| `"$PY" -m unittest discover -s tests/ezviz -p 'test_*.py'` | `Ran 240 tests`, `OK`, 0 skipped (the local amd64 snap file was present, so `test_probe` ran) |
| `python3 -m unittest tests.test_go2rtc_config_gen` (system python3) | `Ran 23 tests`, `OK` |
| `python3 -m unittest discover -s tests -p 'test_*.py'` (as CI) | `Ran 27 tests`, `OK` |
| `bash tests/hub/make-config.test.sh` | 233 ok, 0 FAIL |
| `bash tests/hub/watch.test.sh` / `observe.test.sh` | 98 ok / 101 ok, 0 FAIL |
| `bash tests/hub/power-check.test.sh` / `ezviz-ledger.test.sh` / `coverage.test.sh` | 16 / 26 / 18 ok, 0 FAIL |
| `bash tests/ezviz/probe-run.test.sh` | 71 ok, 0 FAIL (stub python and ffmpeg) |
| `bash tests/ezviz/serve-ezviz.test.sh` (S2) | 53 ok, 0 FAIL |
| `bash tests/w23-packaging.test.sh` / `go2rtc-run.test.sh` / `configure-ezviz.test.sh` | 25 / 8 / 13 ok, 0 FAIL |
| `bash tests/disk-guard.test.sh sh` and `dash` | 21 ok each, 0 FAIL |
| `bash tests/hub/serve.test.sh` (pre-existing clip test) | 20 ok, 4 FAIL in this run: the known pre-existing flake in the section above (cam1 74 and cam2 76 decoder error lines) |
| every other `tests/*.test.sh`, `tests/*/*.test.sh` and `.github/scripts/*.test.sh` | rc 0, 0 FAIL |
| shellcheck with the lint-test.yml flags and targets | 70 files clean; `.github/scripts` clean |

**A stale baseline.** Earlier reports and briefs give `make-config.test.sh` as 157 ok. That number is stale; the
real count is 233 ok, as in the row above.

## §10 row 25: go2rtc and `Pdeathsig` (research, read and not run)

`PR_SET_PDEATHSIG` fires when the parent THREAD exits. A Go program can therefore kill its children early if a
goroutine that locked its OS thread exits while holding it. Research on 19 Nov:
- go2rtc tag v1.9.14 (the source tarball) and all 43 modules in its `go.mod`, at the pinned versions from
  proxy.golang.org, were grepped for `LockOSThread`;
- go2rtc itself has 0 hits;
- the modules have hits only in a symbol table (`x/tools` `internal/stdlib/manifest.go`), in test files (`x/sys`
  `unix/syscall_linux_test.go`) and in Windows-only code (`x/sys/windows`);
- in the Go stdlib at go1.25.6, the only Linux use is `runtime/signal_unix.go` `ensureSigM`, a goroutine that never
  exits;
- go2rtc builds with `CGO_ENABLED=0` (`scripts/build.sh` L28).

So no goroutine exits holding a locked thread, and `Pdeathsig` cannot fire early. The Go version of the release binary
is inferred from `build.yml`, because the binaries are UPX-packed. S2 checks 2 and 4 show that the `Pdeathsig` SIGTERM
arrives when go2rtc exits; they do not prove it never arrives earlier.

## A (item A, the long-session probe): gate GA passed; Task 21 set the constants

### The 63-minute runs: RESULTS

Real probe lines (counters only), from a frozen checkout of 66fb66c, whose helper code is the head's (re-review 3),
form `extend`, count 4320 (probe-run.sh's default), 19 Nov:
- **A1, cam1 alone:** `end=stop login_ok=1 published=1 session_s=3780.319 first_irap_s=0.913 render_s=0.235
  keepalive_sent=755 keepalive_failed=0 frames=94278 decode_errors=84 rtp_ts_monotonic=1.0000 rtp_ts_step_mode=3600
  rtp_ts_step_p99_dev=2`.
- **Both cameras at once, cam1:** `end=stop login_ok=1 published=1 session_s=3780.254 first_irap_s=0.776
  render_s=0.248 keepalive_sent=755 keepalive_failed=0 frames=94482 decode_errors=0 rtp_ts_monotonic=1.0000
  rtp_ts_step_mode=3600 rtp_ts_step_p99_dev=2`.
- **Both cameras at once, cam2:** `end=stop login_ok=1 published=1 session_s=3780.224 first_irap_s=1.451
  render_s=0.223 keepalive_sent=755 keepalive_failed=0 frames=94465 decode_errors=0 rtp_ts_monotonic=1.0000
  rtp_ts_step_mode=3600 rtp_ts_step_p99_dev=0`.
- From the `diag` counters: IDRs (type 19) 943 (A1 cam1), 951 (cam1) and 1891 (cam2) in 3780 s, so one IDR about every
  4.0 s on cam1 and every 2.0 s on cam2.
- **A1's 84 decode errors: unexplained, and not reproduced.** The later cam1 run had 0. A1 is also the only run with
  `drop.frame = 1` (one packet body that did not parse). A lost body inside a GOP would break the pictures that refer
  to it until the next IDR (about 100 at 25 fps), which fits 84 error lines. That is a hypothesis, not a result.

**The plan's rules (Task 21), applied to these lines:**
- `KEEPALIVE_FORM`: the form whose long run had `keepalive_failed=0` and `session_s >= 3540` on both cameras:
  **extend** (3780 s, 755 keepalives, 0 failed, on cam1 and cam2).
- `KEEPALIVE_COUNT` = max(4320, ⌈3780.319 ÷ 5⌉ = 757) = **4320**. The cap: worst render 0.248 s × (4320 ÷ 4320) × 4 =
  0.99 s ≤ 3 s. The × 4 Pi/laptop ratio stays an ESTIMATE until S5 measures `published.t − attempt.t` on the hub.
- `STARTTIMEOUT_S`: the worst `first_irap_s + render_s` is 1.451 + 0.223 = 1.674 s ≤ 20 s, so **30**.
  go2rtc-config-gen.py's copy stays 30.
- `TIMESTAMP_MODE`: every probe has `rtp_ts_monotonic` 1.0000 ≥ 0.999 and `rtp_ts_step_p99_dev` ≤ 2 ≤ 360, so
  **"rtp"**. That needs the conditional muxer, `mpegts.py`.

chosen: form=extend count=4320 starttimeout=30 timestamps=rtp

**The "rtp" mode (`mpegts.py`, `output.py`).**
- Each access unit goes to the ffmpeg child as MPEG-TS (`-f mpegts -i pipe:0`). Its PES PTS is the RTP timestamp of
  the picture's first VCL NAL, at 90 kHz. Video only (OD4); the audio PT 104 stays unused.
- **The 32-bit wrap.** The RTP ts is 32 bit, with a random base, and wraps within 13.25 h. `RtpClock` unwraps it into
  one monotonic counter, so a wrap in the middle of a session gives no backwards PTS. The PES carries the counter
  modulo 2**33, MPEG-TS's own wrap, which the demuxer handles.
- **A timestamp jump.** Rule: a step of 1 to 900000 ticks (10 s, `SOCKET_TIMEOUT_S`) is taken as it is. Anything else
  is a re-base with continuity: no step, a step back, or a jump forward past 10 s (a camera that restarted its
  timestamp base mid-session). The counter advances by the last good step, and later steps count from the new base. So
  no PTS ever goes back or repeats, nothing raises, and the cadence stays regular.
- **Tests:** the muxer tests (`tests/ezviz/test_mpegts.py`) cover a session that crosses the 32-bit wrap, one that
  starts just below it, a backward step, a zero step and a 10**9-tick jump, plus a 20,000-step random fuzz that never
  goes back. Real ffmpeg reads strictly monotonic PTS, equal to the unwrapped ts, across a 32-bit wrap, and decodes the
  clip with 0 errors. The plan says "ffprobe reads monotonic pts"; the test reads them with ffmpeg's framemd5 output
  instead, which uses the same libavformat MPEG-TS demuxer.
- **S2 check 1 re-run in rtp mode** (19 Nov, the local amd64 snap's go2rtc 1.9.14 and ffmpeg, fake camera; the
  binary reports n8.1.1, and 8.0 is only its directory name `usr/lib/ffmpeg/8.0`):
  `serve-ezviz.test.sh` 53 ok, 0 FAIL. Check 1 decoded 251 frames in 10 s with 0 errors after a 0.000 s lead-in.
- **Jitter evidence** (the plan asks for the consumer's pts-step p99 deviation from 40 ms under the chosen form): S2's
  check-1 consumer saw 326 pts steps, with a p99 |step − 40 ms| of 0.000 ms. That is the fake camera, whose RTP steps
  are exactly 3600, so it shows only that the helper, ffmpeg and go2rtc pass the camera's timestamps through
  unchanged. On the real cameras the probes measured `rtp_ts_step_p99_dev` ≤ 2 ticks (0.02 ms) at the source. A
  consumer-side measurement on the real cameras needs a hub run (S6/S8); it was not taken here.

### The production path on the real cameras (round 9 tool): RESULT

The Task 21 review asked (P1) for one run of the real helper on real camera bytes before S5, because the muxer and
the `push_ts` path had only seen the fake camera. The run: `PROBE_HELPER=1 probe-run.sh <cam> 3 extend` (probe.py
`--helper`), from a frozen checkout at fc721cc, on 19 Nov 2026 at 23:30 UTC. The maintainer ran it from a card. It
ran 3 minutes, both cameras at once, one login each. The two lines, counters only, verbatim:

    probe-helper cam1: rc=0 records=attempt,login_ok,published,stop published=1 published_s=6.769 frames=4454 decode_errors=0 pts_step_mode_ms=40.000 pts_p99_dev_ms=0.111 child_f=mpegts stderr_lines=4 stderr_words=attempt,login_ok,published,stop
    probe-helper cam2: rc=0 records=attempt,login_ok,published,stop published=1 published_s=7.430 frames=4440 decode_errors=0 pts_step_mode_ms=40.000 pts_p99_dev_ms=0.000 child_f=mpegts stderr_lines=4 stderr_words=attempt,login_ok,published,stop

**What it shows:**
- The production helper (`python -I -m ezviz_source.main`, its own gate and ledger, the GA constants) ran on each real
  camera.
- It wrote MPEG-TS (`child_f=mpegts`) stamped with the cameras' RTP timestamps, and the consumer (the snap's ffmpeg)
  decoded it cleanly: 0 decode errors, about 4450 frames in 3 minutes, 25 fps.
- The PTS step is 40 ms (mode), with a p99 deviation of 0.111 ms and 0.000 ms.
- Both sessions ended as a clean `stop` (E13) after `published`.

**What it does not show:**
- It ran on the laptop, not on the hub: not arm64 and not the Pi's CPU.
- It ran 3 minutes, not a 24 h session. The RTP clock wraps every 13.25 h, so the wrap was almost certainly not
  crossed on the cameras; only the synthetic tests cross it.
- No go2rtc and no Frigate were in front of it.
- `published_s` is the time from the attempt record to `published`: login, the time to the first IDR, plus the 5 s
  hold (D22). It is not a decode latency.

### Review of Task 21 and round 9; round 10

- **Verdicts** (reviewer slot 12): Task 21, d6476bc..78c0a1f: **approve** at 78c0a1f. Round 9, 78c0a1f..fc721cc
  (probe `--helper`): **approve_with_changes** at fc721cc.
- **Round 10 closed the round 9 changes, tests, probe tool and docs only** (`git diff fc721cc -- spike/ snap/ .github/`
  is empty). The commits are 99595ab, 87c6a73, ed8fd9d, 86c91f5, 2e6b596 and the docs commit that adds this section:
  - R1: a process test stops the probe with SIGTERM mid-run. The result is `stop`, rc 0, the one line, and no helper
    left.
  - R2: a late SIGTERM after the helper has ended is a no-op (`p.send_signal`) instead of `os.kill` on a reaped PID.
  - R3: the counters come from a pure function, `counters()`, tested on crafted outputs. A process test with a
    corrupted picture must show `decode_errors` > 0.
  - N1: asserts on the PCR base (= the PTS), the PCR reserved bits and the PES flags. mpegts.py is unchanged.
  - N4 and N6: two pre-existing load flakes made robust in the tests (`test_exited_child_raises`, and the
    `budget_wait` refusal timing). The refusal takes 0.04-0.06 s idle, inside S1's 150 ms, but under load (10 CPU
    burners, load 16 on 14 threads) even the best of 5 runs took 0.20 s. The test therefore bounds the best run at
    0.5 s, which still fails a refusal that sleeps 1 s, and keeps its per-run check that no pyezvizapi or camera
    module is imported. The test no longer asserts the 150 ms itself; the idle figure above is the evidence for it.
- **Known follow-ups, not changed** (production code; the real cameras ran fc721cc):
  - N2: `RtpClock` learns any good step as "the" step. After a stall of up to 10 s, a re-base advances by that gap
    instead of by one picture. This is harmless: the PTS stays monotonic.
  - N3: `RtpClock.rebases` is counted but never surfaced, so a camera that restarts its timestamp base on the hub would
    not be visible.

### A1 and the diagnostic run: RESULT (the cause is H2, fixed in d06e99c)

**Real runs on cam1** (one login each; counters only):
- **A1** (19 Nov, form extend, 63 min, frozen 5d46c3d): `end=start_timeout login_ok=1 published=0 session_s=3780.095
  first_irap_s=0.000 keepalive_sent=755 keepalive_failed=0 frames=0 decode_errors=3 rtp_ts_step_mode=3600
  pts_seen=[96, 104, 112]`.
- **The diagnostic** (19 Nov, 17:34 UTC, 3 minutes, `PROBE_DIAG=1`, frozen f78b183): `end=start_timeout login_ok=1
  published=0 session_s=180.036 keepalive_sent=35 keepalive_failed=0 frames=0 decode_errors=3`.
  - `pkts` 11115 and `per_min` [3679, 3714, 3721, 1]: steady.
  - `pt` {96: 8180, 104: 2800, 112: 135}.
  - `drop` {route: 11115}: every packet was dropped at the route stage.
  - `rtp_rej` {} and `multi` 0. `nal` {} and `au` 0.
  - `desc` {15: 36}: the 0x45 TLV announces hevc (stream type 0x24) on PT 15. PT 15 never carries a packet.
  - The first bodies are two PT-112 packets with an empty payload: 64 bytes with TLV ids [0x40, 0x45, 0x41], and 44
    bytes with [0x42, 0x43]. Then PT 96 as plain RFC 7798 HEVC: VPS `4001`, SPS `4201`, PPS `4401`, SEI `4e01`, then
    FU `6201` bodies of 1152 bytes.

**Cause (H2, established offline in the library source).**
- pyEzvizApi 2.0.0 reads the 0x45 TLV the way annexb does: stream type = byte 2, payload type = byte 3 & 0x7F
  (`streaming/media/rtp.py:526-536`). So `{15: 0x24}` is the library's map too.
- The library then adds PT 96 to the hevc routes (`streaming/local/payloads.py:1125-1157`) when all of these hold: video
  descriptors exist, 96 is unassigned (1130), no packet on an announced video PT is seen (1141-1143), there are no
  H.264 routes, and PT 96 shows at least 2 HEVC evidence frames: the wrapper, a layer-0 VPS/SPS/PPS, or an FU
  (1147-1150, 1155-1157).
- The decrypt loop then treats PT 96 as authoritative hevc (772, 808-822, 866). The clear path
  (`_idmx_local_packets_to_hevc_annexb`) uses the same routes.
- annexb had listed this as an accepted difference. With hevc = {15}, PT 96 failed the route check.

Offline checks on bodies of the real shape:
- library routes hevc {15, 96}, 6 NALs; annexb 0;
- with one PT-15 packet added, the library routes {15} only and drops PT 96 too.

H1 (0xB2) was a real gap in annexb's table, but it was not the cause: 0xB2 never appears. That fix stays.

**Fix (d06e99c).**
- annexb ports the promotion progressively. PT 96 joins the hevc routes at its second evidence frame. It leaves them for
  good once an announced video PT carries a packet.
- PT-96 bodies wait in a bounded hold (`HOLD_MAX` 64) until the decision, then come out in order, so the leading VPS is
  kept.
- The fake camera's `--real-shape` variant reproduces the diagnostic field for field: the two PT-112 packets of 64 and
  44 bytes, `desc` {15: 0x24}, FU bodies of 1152 bytes, and PT 104 audio.
  - Red: `end=start_timeout login_ok=1 published=0 frames=0 decode_errors=3 pts_seen=[96, 104, 112]`,
    `drop {route: 7614}`.
  - Green: `end=stop published=1 frames=298 decode_errors=0`, route drops only on 104 and 112, 1 body held and
    replayed.
- On 2552 real-shape bodies (100 pictures), annexb and the library's decrypt path give byte-identical Annex-B.
- Seven mutants fail: the threshold, the announced-PT stop, the H.264 guard, the 96-assigned guard, the hold replay,
  the old route rule and an unbounded hold.
- Not yet proven on the real camera: that needs a new real run.

**Suites at d06e99c** (19 Nov, a private `W23_VENV`, heavy suites one at a time under the suite lock):
- `tests/ezviz` unittest: `Ran 256 tests`, `OK`, 0 skipped (251 before, plus 4 annexb tests and 1 probe test);
- `serve-ezviz.test.sh` (S2): 53 ok, 0 FAIL;
- `probe-run.test.sh`: 76 ok, 0 FAIL;
- CI python: `discover -s tests` 27 OK and `tests.test_go2rtc_config_gen` 23 OK.

No shell file changed in this round.

### GA run 2 on the real camera: RESULT (video; the reader fix confirmed)

**The run** (cam1, one login, 3 minutes, `PROBE_DIAG=1`, frozen 3a54aa1, 19 Nov 18:04 UTC; counters only):
`end=stop login_ok=1 published=1 session_s=180.195 first_irap_s=0.628 keepalive_sent=35 keepalive_failed=0
frames=4487 decode_errors=0`.
- `pkts` 11152; `pt` {96: 8210, 104: 2806, 112: 136}.
- `drop` {route: 2942, held: 1, fu_part: 3542}. The route drops are exactly the PT 104 and PT 112 bodies. One body
  waited for the PT-96 promotion and came out in order.
- `desc` {15: 0x24}; `nal` {32: 45, 33: 45, 34: 45, 39: 45, 19: 45, 1: 4443}; `au` n 4488, idr 45.

**What it shows.**
- 4487 frames in 180.2 s is 24.9 fps, with 0 decode errors.
- The first IDR came 0.628 s after the session start. The publish point (first IDR + `PUBLISH_HOLD_S` 5 s) is about
  5.6 s in.
- 45 IDRs (type 19) in 180 s: one about every 4 s.
- The fake camera's `--real-shape` and the real camera now agree.

**What it settles.**
- The reader fix (d06e99c, the PT-96 promotion) works on the real camera.
- The 30 s `STARTTIMEOUT_S` looks safe: publish came at about 5.6 s.

**What it does NOT settle.**
- The long session: wait for the 63-minute run.
- `KEEPALIVE_FORM` and `KEEPALIVE_COUNT`: 35 keepalives over 3 minutes say nothing about the long-session limit.
- `TIMESTAMP_MODE`. This run's `rtp_ts_monotonic=0.6187 rtp_ts_step_mode=3600 rtp_ts_step_p99_dev=2784805578` mixed
  the audio-like PT 104 and the descriptor PT 112, which have their own timestamp bases, into the video's list. From
  ccd7812 the probe takes timestamps from the HEVC video route only. On the real-shape fake that gives 1.0000 / 3600 /
  0, against 0.5008 / 3600 / 4294944016 before.

All four constants (`KEEPALIVE_FORM`, `KEEPALIVE_COUNT`, `STARTTIMEOUT_S`, `TIMESTAMP_MODE`) stayed provisional until
Task 21; the 63-minute runs at the start of this section settle them.

**Suites at ccd7812** (19 Nov, a private `W23_VENV`, heavy suites one at a time under the suite lock):
- `tests/ezviz` unittest: `Ran 257 tests`, `OK`, 0 skipped (256 before, plus 1);
- `serve-ezviz.test.sh` (S2): 53 ok, 0 FAIL;
- `probe-run.test.sh`: 76 ok, 0 FAIL;
- CI python: `discover -s tests` 27 OK and `tests.test_go2rtc_config_gen` 23 OK.

### A1 gave no video: why the helper might drop it (HYPOTHESES, not results)

The ranking below was written before the diagnostic run. The run settled it: H2. The table is kept as the record.

**The fact.** GA run A1 (cam1, form extend, 63 min, from the frozen 5d46c3d) printed `end=start_timeout login_ok=1
published=0 session_s=3780.095 first_irap_s=0.000 keepalive_sent=755 keepalive_failed=0 frames=0 decode_errors=3
rtp_ts_step_mode=3600 pts_seen=[96, 104, 112]`. Login and keepalives held for the whole hour, packets parsed as RTP on
three payload types, and no IDR access unit ever reached ffmpeg. The W-20 T10 captures of 13 Nov fed the same packet
bodies (the same generated multi-socket stream and `packet.body`) through the library's own
`_decrypt_idmx_local_packets_to_annexb_with_codec` with an identity decrypt, and decoded 250 clean frames per camera.
So the camera sends clear H.265 that the library's path accepts. What follows is a comparison of `annexb.py` with that
path in pyEzvizApi 2.0.0, read in a private venv. It is offline reasoning plus synthetic checks. It is not a result
from the camera.

**How each was checked.** "Proven offline" means that the same synthetic bodies went through both the library path (with
an identity decrypt, as T10 ran it) and `annexb.Reassembler`, and that the library gave 5 NALs where annexb gave 0. The
scratch checks were not committed. H1 is also reproduced end to end by a fake-camera variant, and it is fixed.

| # | Place (annexb vs library) | Can it drop ALL video? | Fits A1's line? | Rank |
|---|---|---|---|---|
| H1 | **0x45 stream type.** annexb knew only 0x24 as HEVC. The library (`rtp.py` `_IDMX_RTP_STREAM_TYPES`) maps **0x24 and 0xB2** to hevc. A 0xB2 descriptor on PT 96 made PT 96 a "foreign-owned" route, and every video packet was dropped at the route check. | **Yes, proven offline**: library 5 NALs, annexb 0. The fake-camera variant `--desc-stream-type 0xb2` reproduces A1's line field for field: `end=start_timeout login_ok=1 published=0 first_irap_s=0.000 frames=0 decode_errors=3 rtp_ts_step_mode=3600`. **Fixed in 92fe4ff.** | Yes | 1 |
| H5 | **Legacy (non-RTP) IDMX records.** These are frames with a 13-byte header whose lead byte is not 0x0D (for example 0xFA), so there is no RTP at offset 0 or 1. annexb drops them at `_rtp_of`. The library reads PT, seq, ts and marker from header bytes 1–8 (`payloads.py` `_idmx_local_frame_transport_fields`) and uses `frame[13:]` as the body. This difference is NOT in annexb's accepted-differences list. | Yes, proven offline (library 5, annexb 0), if the video arrives as such records | Yes. `pts_seen` would then come from the other, RTP-shaped records. | 2 |
| H4 | **Aggregate bodies.** One body can hold several IDMX frames (consecutive seq) or a nested `00 10` record. annexb's `_frame_of` takes only a body whose 4-byte prefix covers exactly the rest, so it drops the whole aggregate. The library splits it (`_iter_idmx_local_frames`). This is in the accepted-differences list. | Yes, proven offline (library 5, annexb 0), if the video arrives aggregated | Partly. Step mode 3600 says some 25 fps RTP was parsed singly, but that could be a non-video PT. | 3 |
| H3 | **Keyframe type.** The probe and the helper publish at the first **IDR** (types 19/20, C16). If the camera's keyframes are CRA (21) or BLA, annexb emits NALs and AUs but no AU is ever `is_idr`, so nothing is fed. The library does not care about this. This is a publish-rule mismatch, not a reassembler one. The fake's own x265 clip shows that encoders do this: IDR_N_LP (20) first, then CRA (21). | Yes, for the probe and the helper | Yes | 4 |
| H2 | **PT 96 evidence promotion.** Descriptors announce HEVC on a PT X that is never seen, while video flows on an unassigned PT 96. The library promotes 96 after at least 2 HEVC-evidence frames. annexb does not (accepted difference). | Yes, proven offline (library 5, annexb 0) | Only if X is outside {96, 104, 112}. If X were 104 or 112, the library would not promote either, and T10 would have failed too. | 5 |
| — | **Evidence gate** (`_evidence_frame`, no descriptors): video waits for a layer-0 VPS/SPS/PPS, an FU or the wrapper. | No. A 1080p IDR does not fit one packet, so an FU comes within one GOP. | No | low |
| — | **`00 01` / `00 02` parameter carriers**: skipped, as in the library. A TRAIL_N slice (type 0, TID 1) also starts `00 01` and is skipped in both. | No (it corrupts, it does not starve) | No | low |
| — | **Header sizes 12/13, the 0x0D shim, the length prefix**: the same as the library for single frames (a 0x0D-shim body decodes in both). | No | — | low |
| — | **The wrapper `40 00 00 02 80 06`**: NAL at offset 12, as in the decrypt path. | No | — | low |
| — | **The `24 00` trailer strip**: annexb strips only HEVC-direct bodies. The library also strips H.264-looking bodies, which are not HEVC video anyway. | No | — | low |
| — | **The headerless FU quirk, `_direct_frame`, `_plausible`, the FU continuity rule**: the same logic as the library. | No | — | low |
| — | **Progressive route map** (the library uses the final map) and the **FU/AU caps** (8 MiB / 16 MiB) | No (transient, or not reached at these bitrates) | — | low |

**What the 3-minute `--diag` run tells apart** (`PROBE_DIAG=1 tests/ezviz/probe-run.sh cam1 3 extend`, one login; the
line's `diag=` JSON is described in `tests/ezviz/probe.py`):
- H1: `desc` maps the video PT to 178 (0xB2). With 92fe4ff the run should then publish (`frames` > 0).
- H5: `drop.rtp` > 0 and `rtp_rej` such as `{"13:fa": n}` with a large n.
- H4: `multi` > 0 and `drop.frame` > 0.
- H3: `nal` contains 21, and `au.idr` is 0.
- H2: `desc` announces 0x24 or 0xB2 on a PT that is missing from `pt`, and `drop.route` covers PT 96 (`route_pt`).
- None of these: the `first` sample (length, header size, PT, TLV ids, 2 payload bytes for 20 bodies) is the next lead.

**Suites after the diagnosis wave** (tree c0332f9, 19 Nov, a private `W23_VENV`, heavy suites one at a time under the
suite lock): `tests/ezviz` unittest `Ran 251 tests`, `OK`, 0 skipped (240 before, plus 11 new);
`probe-run.test.sh` 76 ok, 0 FAIL (71 before, plus 5 new); `serve-ezviz.test.sh` (S2) 53 ok, 0 FAIL; CI python
`discover -s tests` 27 OK and `tests.test_go2rtc_config_gen` 23 OK; shellcheck at the lint-test flags is clean on
`probe-run.sh` and its test. The other suites in the table above were not re-run: this wave does not touch them.

## Gates (Task 22 steps 4–6): pending, orchestrator

The two-arch CI build logs (`ezviz-py import proof ok`), the artifact sizes (`tests/w23-size.sh`, delta ≤ 35 MB), the
`unsquashfs -l` checks and the amd64 gate VM and arm64 TCG VM proofs are recorded here by the orchestrator.
