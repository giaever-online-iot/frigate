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

## A (item A, the long-session probe): pending gate GA

Task 21 has not run. It needs the probe lines from GA (runs A1/A1b, A2, A3), which only the orchestrator and the
maintainer can take. Until then the constants are the plan's defaults: `KEEPALIVE_FORM="extend"`,
`KEEPALIVE_COUNT=4320` (not yet capped by a measured render time), `STARTTIMEOUT_S=30` and
`TIMESTAMP_MODE="wallclock"`.

## Gates (Task 22 steps 4–6): pending, orchestrator

The two-arch CI build logs (`ezviz-py import proof ok`), the artifact sizes (`tests/w23-size.sh`, delta ≤ 35 MB), the
`unsquashfs -l` checks and the amd64 gate VM and arm64 TCG VM proofs are recorded here by the orchestrator.
