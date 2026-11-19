# W-23 Hub Real Cameras Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Feed the hub's Frigate from both real cameras with image encryption still ON. A snap-owned helper, `ezviz-source`, turns each camera's clear port-8000 LAN Live View stream into a loopback RTSP publish. go2rtc keeps it open (preload, re-armed) under a hard login budget. The hub is then switched over, soaked for 24 h and put into production.

**Architecture:** The helper runs as a go2rtc `exec:` child under its own CPython 3.12 inside the frigate snap (OD1/R1). Before any camera contact it passes a stdlib-only gate: session lock → camera file → ledger decision (T-END and D4) → an `attempt` record fsynced to disk. It then logs in with the pinned pyEzvizApi 2.0.0, reassembles IDMX/FU into Annex-B H.265 with no decrypt step, and pipes it to the bundled ffmpeg 8.0, which publishes `-c copy -an -f rtsp {output}`. The go2rtc config generator emits the stream and its `preload`, and forces the API settings the re-arm loop needs. A small disk-guard timer app, an `ezviz-check` app, a configure-hook unlatch, `make-config.sh` `ezviz` mode and the hub tools complete it.

**Tech Stack:** Python 3.12.16 (python-build-standalone 20261110) with pyEzvizApi 2.0.0 and its 13 hash-locked wheels; go2rtc 1.9.14; ffmpeg 8.0 (n8.1.1 tree); POSIX sh (snap wrappers, hooks); bash (tests, hub tools); snapcraft on core26; unittest; yq v4 (laptop).

**Spec:** `docs/superpowers/specs/2026-11-16-hub-real-cameras-design.md` at `8f539284c8e3d39bfb80085cc7628c65eb731812`. It was approved by the maintainer on 19 Nov 2026 with OD1 = R1 (separate Python 3.12, about +28 MB), OD2 = 3 days, OD3 = file install as `x2`, held and stopped, and OD4 = video only. Read the spec first. Every task cites the D-numbers, T-END rows (E1–E17) and S-steps it implements. **Where this plan and the spec disagree, the spec wins, except for the plan decisions P1–P15 below, each of which says why.**

---

**Revision:** fix wave 1 after the independent plan review of `4b659ae` (approve with changes: SF1–SF13, nits N1–N12). Each change is marked *(SFn)* or *(Nn)* where it lands.

**Real code, and where it stops** *(SF13)*. This is a departure from the maintainer's "real code in every step", stated here so that it can be waived or required at plan approval:
- **Full code and literal tests** are given for the lockout core and the hub checks:
  - `constants`, `paths`, `camfile`, `ledger`, `policy`, `signals`, `gate`, `main` (end paths), `unlatch`, `check`;
  - `disk-guard` and the configure hook;
  - `power-check.sh`, `ezviz-ledger.sh` and `coverage.sh`.

  All of this code ran on the laptop on 19 Nov; `main.py` ran against stand-in camera and output modules. The tests went green, and every named mutation went red except the one equivalent mutation noted in Task 4.
- **Signatures, exact interfaces and literal or named tests, but no bodies**, are given for the protocol and plumbing modules: `annexb`, `camera`, `output`, `fakecam`, `rearm`, the generator change, make-config's `ezviz` mode and the packaging. Their bodies follow pyEzvizApi 2.0.0 and go2rtc 1.9.14 code that cannot be run here without a camera or a build.

## Global Constraints

- **No worker touches the hub, a camera or the key file** (spec D14, D15). Part B steps run only on the maintainer's direct go for that step, by the orchestrator through `tests/hub/ssh-exec.sh` or by the maintainer from a command card.
- **No camera or host address, hostname, credential, serial, label code or the maintainer's name or pronouns** may appear in any file, commit message or test fixture. Tests use TEST-NET-1 addresses (`192.0.2.0/24`), made-up ids (`TESTCAM-0001`) and canary codes, as in `tests/hub/make-config.test.sh`.
- **Login budget, per camera:** at most **3 `attempt` records in any rolling 3600 s**, and at least **60 s** between two attempts. The backoff ladder is **60 s → 300 s → 900 s → until the window allows**. It resets after a session published for ≥ 3600 s, after 3600 s with no attempt, or on an unlatch (P6). An `auth_fail` latches at once, and **3** consecutive latch-row entries latch (spec D4, T-END).
- **Exit codes of `ezviz-source`:** `0` on a SIGTERM end, `75` temporary (busy, budget_wait, latched, ledger_damaged, ledger_io, net_fail, session_end, output_end, protocol_fail), `77` auth_fail, `78` config, `64` usage (spec §4.1, §4.2).
- **Exec line, verbatim:** `exec:<SNAP>/bin/ezviz-source <name> {output}#killsignal=15#killtimeout=5`. `#starttimeout=<n>` is appended only if Task 21 sets `STARTTIMEOUT_S` ≠ 30 (D8, D17, §4.1).
- **Preload entry:** `preload: {<name>: "video"}` (D2, D8).
- **Re-arm:** first round 30 s after start, then every 30 s; one request in flight; client timeout `2 × STARTTIMEOUT_S + 15` (75 s at 30 s); a failed GET skips the round (D19).
- **Stop path:** the first SIGTERM sets `SIGALRM` to `SIG_DFL`, calls `alarm(4)` and raises `Terminating(BaseException)`. Later SIGTERMs only mark pending (L1). Exit is via `os._exit(0)` after the fsync (D17).
- **Publish point:** the first complete IRAP access unit has been written to ffmpeg, and ffmpeg has stayed alive for **5 s** after it (D22).
- **Library socket timeout 10.0 s** (stall > 10 s = `session_end`, §4.2). Library logger `pyezvizapi` gets a `NullHandler` and `propagate = False` (§4.5).
- **Helper output:** only `ezviz-source <name>: <class> [attempt n/3 in window] [next allowed +Ns]`. Unexpected exceptions print only `type(e).__name__` (§4.5).
- **Paths:** camera files `$SNAP_DATA/ezviz/cameras/<name>.conf` (root 0600, dir 0700). State `$SNAP_COMMON/ezviz/state/` (0700): `<name>.ledger`, `<name>.session`, `<name>.latch`, `<name>.unlatch-seen` (0600) (D7, D18, §4.3).
- **Camera names** match `^[a-z0-9_]{1,32}$`. make-config writes `cam1` and `cam2`.
- **Retention:** soak `continuous.days 1`, alerts and detections 1. Production 3 (OD2), set through `M7C_RETAIN_DAYS` (D12, F5).
- **Disk guard:** floor default **20 GiB**, `snap set frigate disk-floor-gib=N` (integer 1–10000), every 10 min (`timer: "00:00-24:00/144"`). Below the floor it runs `snapctl stop --disable frigate.frigate` and logs one line (D13).
- **Pins:** python-build-standalone `20261110`, CPython `3.12.16`, `install_only_stripped`. aarch64 sha256 `b6a41defec4975d94b4ff1950236e7383e5c02ba40ea48c9ec33c66087a35aab`; x86_64 sha256 `6a9e62dad033790aef722dbd370e0ce76ce17b73627ba3ae679f537049350b39`. pyezvizapi wheel sha256 `ed7c309a1af18e0cdc3665a87d7a1c30c21581ba80a25115d748f76ed2f349f8`. The 13-package lock is `docs/superpowers/plans/ezviz-t10/requirements.txt` at `d5260d4`, byte for byte. Verified 19 Nov: it hashes every PyPI file of every pin, aarch64 included.
- **The W-20 lock:** `spike/ezviz/requirements.txt` sha256 `b3282719e5c607e53f5de0943244075708bc2948ec6b4aa130050ce033ab4921` *(SF5)*.
- **Undervoltage check:** `tests/hub/power-check.sh` reads `journalctl _TRANSPORT=kernel --since @<epoch>`, which covers all boots, and never `journalctl -k`. An unreadable journal is INCONCLUSIVE (exit 4), never 0 *(SF10)*.
- **Heavy suites** (anything that extracts the amd64 snap file, starts go2rtc, runs the fake camera for more than 60 s, or boots a VM) run under `flock -w 3600 /tmp/claude-1000/chim-suites.lock`.
- **Shell scripts** pass `shellcheck --severity=warning -x`, as the lint job requires (`.github/workflows/lint-test.yml`).

## Review Focus

These are inputs the spec implies but does not test, most likely first. Each one has its test in the owning task.

1. **The Pi's wall clock jumps at boot** (no RTC battery; NTP corrects minutes later). A ledger record dated in the future must count as inside the 3600 s window and the spacing, so a clock that went backwards can never allow a 4th login. Expected: refusal until real time passes the record. *Test: Task 4 `test_future_dated_attempt_counts_in_window_and_spacing`.* A clock that is **behind** at boot is not covered by any test; see "cannot verify offline" *(N9)*.
2. **A damaged line in the middle of the ledger** (a hand edit, or a filesystem fault). Skipping it could drop an `attempt` and allow an extra login. Expected: refusal with class `ledger_damaged`, no camera contact, exit 75, until an operator moves the file away (P8). *Test: Task 3 `test_mid_file_damage_is_reported`, Task 6 `test_ledger_damaged_refuses_without_contact`.*
3. **The disk is full or read-only when the `attempt` record is written** (hub item 8: after undervoltage the storage stopped accepting writes). Expected: class `ledger_io`, exit 75, and **no `connect()`**, because the attempt is not on disk. *Test: Task 6 `test_attempt_write_failure_means_no_contact`.*
4. **Several helpers start on a fresh hub at once** (no state dir yet: go2rtc's preload plus Frigate's consumer). Expected: the dir is created 0700 and the files 0600, exactly one helper passes the gate, and the rest exit 75 `busy`. *Test: Task 6 `test_ten_concurrent_helpers_on_fresh_state`.*
5. **Odd camera-file names in `$SNAP_DATA/ezviz/cameras/`** (a `cam1.conf.m7c-new` left by an interrupted make-config, `CAM1.conf`, `../x.conf`, a directory). Expected: the generator and the re-arm use only `^[a-z0-9_]{1,32}\.conf$` regular files, and a leftover temp file never becomes a second stream or a second login. *Test: Task 13 `test_only_valid_camera_files_become_streams`, Task 14 `test_names_ignore_odd_files`.*

---

## Plan decisions (binding for the implementer; spec citations in brackets)

- **P1. The library call path.** The helper builds `HcNetSdkLanEndpoint(serial=…, host=…, command_port=port)` and calls the public `open_hcnetsdk_command_port_generated_multi_socket_stream(endpoint, plan, password=login, username="admin", timeout=10.0, socket_factory=factory)` (pyEzvizApi 2.0.0 `streaming/local/session.py` L1728-1753). *Why:* the spike's private `_open_hcnetsdk_command_port_clip_stream` makes exactly this one call for a generated plan plus a password (`cloud/operations/capture.py` L1035-1038), so the protocol path is the one W-20 proved. The public call needs no `EzvizClient` and so no `requests` session [D6(a)].
- **P2. Where `login_ok` is written.** The helper passes its own `socket_factory`. The library opens connection 1 (the login) through it, closes it after a successful login, and then opens connection 2 (the first plan step) through it (`session.py` L1536-1559). On the factory's **second** call, and only if `stream.login_session` is set, the helper's main thread writes `login_ok` inside the critical section, spawns ffmpeg (P4) and then connects. *Why:* `start()` logs in and runs the plan in one call, so there is no other hook between them. At this point there is only one thread (the keepalive thread starts later, L1317), so `preexec_fn` is safe. This also meets the nit that ffmpeg is spawned only after `login_ok` [D22, T-END P1/P2].
- **P3. Classification of library errors** (`camera.classify(exc, logged_in) -> str`):
  - before `login_ok`: `PyEzvizError` whose `str()` equals `"HCNetSDK command-port login failed"` → `auth_fail` (E2). Everything else → `net_fail` (E3). That includes `OSError` (refused, timeout, reset), `DeviceException`, `EzvizLocalSdkStreamClosed`, `ValueError` ("Ciphertext too large") and other `PyEzvizError`.
  - after `login_ok`: walk `__cause__`/`__context__`. Any `DeviceException`, `EzvizLocalSdkStreamClosed` or `OSError` → `session_end` (E8/E14). Anything else → `protocol_fail` (E10/E16).

  *Why:* these are the 2.0.0 exception sites (`discovery.py` L432-436, `requests.py` L2356-2365, `session.py` L1046-1083, L1435-1444). The W-20 run 1 produced exactly that `auth_fail` message. A lockout reads the same as a wrong code, and latching it is correct [E2, D4]. The same message is also raised when the camera's second login reply has a body shorter than 4 bytes (`discovery.py` L431-436), so a busy or max-viewers reply latches too. That is conservative. Read an S12 latch with this in mind *(N12)*.
- **P4. ffmpeg arguments and the timestamp form** *(SF8: now as spec §4.4 says)*. The wallclock form is built first:
  - argv `[FFMPEG, "-hide_banner", "-loglevel", "error", "-use_wallclock_as_timestamps", "1", "-f", "hevc", "-i", "pipe:0", "-c", "copy", "-an", "-f", "rtsp", "-rtsp_transport", "tcp", OUTPUT]`;
  - stdout and stderr go to `DEVNULL`;
  - the environment is exactly `{"PATH": "/usr/bin:/bin", "LD_LIBRARY_PATH": $EZVIZ_CHILD_LD_LIBRARY_PATH}`, which the wrapper sets (Task 10, N4);
  - `prctl(PR_SET_PDEATHSIG, SIGTERM)` in `preexec_fn`.

  The spec rule decides the form: **(a)**, RTP timestamps into MPEG-TS, **if item A shows usable RTP timestamps** (`rtp_ts_monotonic ≥ 0.999` and `rtp_ts_step_p99_dev ≤ 360`, i.e. 10 % of 3600 at 90 kHz, on every probe run); **(b)**, wallclock, otherwise. Task 21 applies it and builds `mpegts.py` in the (a) case. There is no added "and (b) showed a defect" condition [§4.4 L285]. The probe and S2 also record the consumer's pts-step p99 deviation from 40 ms as evidence of wallclock jitter.
- **P5. Keepalive extension is a parameter, not a guess.** The plan is `dataclasses.replace(base, steps=…)` with the media step's `keepalive_templates` replaced by `KEEPALIVE_COUNT` templates `HcNetSdkCommandPortControlTemplate(command_id=0x30006, addend_delta=d)`. The form is `"extend"` (`d = 10 + 6*i`) or `"repeat"` (the first six as built, then `d = 40` repeated). Item A chooses the form; Task 21 sets `KEEPALIVE_FORM` and `KEEPALIVE_COUNT`. The count must cover ≥ 6 h (4320 at 5 s) so that a 24 h soak needs ≤ 4 planned re-logins per camera, under S8's ≤ 12 per 24 h. The library renders every frame up front in pure Python (`session.py` L307-315), so Task 9 measures the render time and Task 21 caps the count so that rendering takes ≤ 3 s on the hub [§4.4, §2.2 item 4].
- **P6. An unlatch resets the latch row and the ladder.** The configure hook appends an `unlatch` record, and the policy counts the row and the ladder only after the last `unlatch`. *Why:* the spec says an operator clears a latch on purpose (§4.2) but not what happens to the row. If the row stayed at 3, the next decision would latch again at once and the unlatch would do nothing. The cap and the spacing still count every `attempt`, so an unlatch never buys an extra login inside the hour. The unlatch also clears a latch held only in the ledger, with no latch file (N3). Its record cannot be lost to a concurrent trim, because the ledger lock re-checks the inode (SF12, Task 3).
- **P7. Ladder rung 4 and above** waits until the third-most-recent `attempt` + 3600 s. *Why (N1):* this is exactly the D4 cap, written out so that the 4th rung has an explicit rule. With 3 or more attempts in the window it equals the cap. With fewer, it lies in the past, and only the spacing applies. That is spec D4's "until the 3-per-hour window allows another", and it adds nothing beyond the cap.
- **P8. A damaged non-last ledger line refuses** with class `ledger_damaged` (exit 75, no contact) until an operator moves the file away (`sudo mv <ledger> <ledger>.damaged`; the next decision starts empty, and the latch file still applies). *Why:* the spec covers only a torn **last** line (§4.3). Skipping a damaged middle line could drop an `attempt`. The latch file stays independent of the ledger, so moving the ledger never clears a latch (Review Focus 2). **Operator rule (N2):**
  - move the ledger only when its newest record is 3600 s or more old: first `X exec 'tail -n 2 /var/snap/frigate/common/ezviz/state/<name>.ledger; date +%s'`;
  - otherwise the move forgets the last hour's attempts (up to 3 more logins that hour) and the latch row.

  `ezviz-check` prints `ledger_damaged` and `ezviz-ledger.sh` prints `ledger <name>: damaged`, so the state is visible.
- **P9. The latch file is the truth; the ledger is the evidence.** A decision is latched if `<name>.latch` exists **or** an `auth_fail` or a full row lies after the last `unlatch`. When the policy finds a full row and no `latch` record after the last `unlatch`, the gate creates the latch file and appends `latch` once. The helper itself writes `auth_fail`, the latch file and `latch` in one critical section (E2). *Why:* §4.2 says the hook "removes the latch file", and trimming the ledger (§4.3) must never lose a latch.
- **P10. make-config `ezviz` mode also requires `frigate.go2rtc` inactive, and the clip and cameras modes refuse (new exit 10) while camera files exist on the hub.** *Why:* the generator emits camera streams from the camera files whatever `config.yml` says (D8). A rollback to clip mode with camera files left behind would keep logging in to the cameras. A camera file written while go2rtc runs is picked up only by the re-arm, which PUTs a name with no stream (500, no contact) until go2rtc restarts. **This changes the order of spec §9.3's first rollback row:** remove `/var/snap/frigate/current/ezviz` first, then run clip-mode make-config. Recorded here and in the report, not changed in the spec.
- **P11. Detect size.** make-config leaves `detect.width`/`height` unset, so Frigate 0.18.2 probes the stream at start, as the clip mode already does. S5 records `frigate.ffprobe` output for each camera as the setup measurement. The probe reads go2rtc's restream, which is already running because of the preload: 0 logins [D9].
- **P12. Undervoltage is a stop rule during the hub steps.** `watch.sh` trips on a new `Undervoltage detected` kernel line (in `--act` mode: `snap stop --disable frigate`), and `tests/hub/power-check.sh` gives S5 and S8 their read-only verdict. *Why:* the hub logged undervoltage on 17 and 18 Nov, and on 18 Nov storage writes stopped after it (card W-23 item 8). Frigate's load (2 cores, the Coral, the NVMe) adds current draw, and a stopped Frigate costs nothing but recording. *(SF10)*:
  - both tools read the kernel transport across **all** boots since a recorded epoch (`journalctl _TRANSPORT=kernel --since @<epoch>`), because `journalctl -k` implies `-b`, the current boot only, and would miss an undervoltage that rebooted the hub (card item 8);
  - power-check also counts boots in the window: an unplanned boot is a FAIL;
  - an unreadable journal is INCONCLUSIVE, never 0.
- **P13. The optional E7 discriminator is NOT built.** It would change T-END's latch-row rule, which is in the approved spec. It is recorded as a follow-up for the maintainer: a go2rtc crash loop that SIGTERMs three starts in a row before publish would latch a valid camera.
- **P15. One budget per camera across the laptop and the hub** *(SF11)*. The laptop probe's ledger (`$M7C_ENV_DIR/w23-probe-state`) and the hub's ledger are separate files, so the D4 budget is kept between them by time:
  - no hub start (S5 and every later start while GA runs are still possible) until **3600 s or more** after the last `attempt` in each camera's probe ledger;
  - the probe ledger must have no latch;
  - **no probe run while any hub helper runs**.

  `probe-run.sh --status` prints, per camera, the last attempt (UTC), its age in seconds and the latch state. It makes no camera contact (Task 12).
- **P14. Install source for `x2`.** This is the arm64 file CI builds for the commit the maintainer merges to `main` (the default sequence: merge, deploy, then acceptance). Its sha256 is recorded at Task 22 [OD3, D11].

## File structure

| Path | Responsibility |
|---|---|
| `spike/ezviz/requirements.txt` | the 13-wheel hash lock, byte-identical to `d5260d4:docs/superpowers/plans/ezviz-t10/requirements.txt` |
| `spike/ezviz/ezviz_source/__init__.py` | empty |
| `spike/ezviz/ezviz_source/constants.py` | every number the spec pins: budget, ladder, timeouts, `STARTTIMEOUT_S`, `KEEPALIVE_*`, `TIMESTAMP_MODE`, exit codes, name regex |
| `spike/ezviz/ezviz_source/paths.py` | `$SNAP`, `$SNAP_DATA`, `$SNAP_COMMON` → camera dir, state dir, ffmpeg path |
| `spike/ezviz/ezviz_source/camfile.py` | read and validate a camera file (stdlib) |
| `spike/ezviz/ezviz_source/ledger.py` | ledger I/O: parse with the torn-line rule, locked append with fsync, trim (stdlib) |
| `spike/ezviz/ezviz_source/policy.py` | T-END and D4 as pure functions: sessions, phases, synthetic record, latch row, ladder, cap, spacing → `Decision` |
| `spike/ezviz/ezviz_source/signals.py` | `Terminating`, the SIGTERM handler (L1), the critical section, the alarm, test hooks |
| `spike/ezviz/ezviz_source/gate.py` | the pre-contact gate (D3, D18, D21, G3, N5): locks, camera file, decision, `attempt`; output lines |
| `spike/ezviz/ezviz_source/annexb.py` | streaming IDMX/RTP/FU → Annex-B H.265 reassembler and access-unit splitter (D6c) |
| `spike/ezviz/ezviz_source/camera.py` | the **only** module that imports pyezvizapi: plan builder (P5), session (P1, P2), `classify` (P3), logging silenced |
| `spike/ezviz/ezviz_source/output.py` | the ffmpeg child (P4), the publish point (D22), the ffmpeg-exit signal |
| `spike/ezviz/ezviz_source/main.py` | the helper: phases P0–P3, T-END end records, exit codes |
| `spike/ezviz/ezviz_source/rearm.py` | the D19 loop, plus `--list` (names only) for hub checks |
| `spike/ezviz/ezviz_source/check.py` | `frigate.ezviz-check <name>` (N9) |
| `spike/ezviz/ezviz_source/unlatch.py` | the configure hook's unlatch (§4.2, P6) |
| `spike/bin/ezviz-source`, `ezviz-rearm`, `ezviz-check` | sh wrappers: run the module on `$SNAP/opt/ezviz-py/bin/python3.12 -I -B` |
| `spike/bin/disk-guard` | D13 oneshot (sh) |
| `spike/bin/go2rtc-run` | modify: start `ezviz-rearm` in the background through the same tee; pass the cameras dir to the generator |
| `spike/bin/go2rtc-config-gen.py` | modify: optional 5th argument, the cameras dir; D8 emission; D20 forced API keys |
| `snap/hooks/configure` | modify: validate `disk-floor-gib`; run the unlatch |
| `snap/snapcraft.yaml` | modify: part `ezviz-py`; apps `ezviz-check`, `disk-guard` |
| `tests/ezviz/venv.sh` | builds the laptop/CI venv from the lock and adds `ezviz_source.pth` |
| `tests/ezviz/_path.py`, `tests/ezviz/fixtures.py` | test helpers (temp `SNAP*` trees, fake ffmpeg, canary camera files) |
| `tests/ezviz/fakecam.py` | loopback fake camera: real HCNetSDK login and the 10-step plan, `$`-framed IDMX/RTP/FU HEVC |
| `tests/ezviz/fakeffmpeg.py` | stand-in for ffmpeg in S14/S15 (reads stdin, knobs for exit and stall) |
| `tests/ezviz/test_*.py` | unit and process tests (S1, S14, S15) |
| `tests/ezviz/serve-ezviz.test.sh` | S2 end to end with go2rtc 1.9.14 and ffmpeg 8.0 from the local amd64 snap file |
| `tests/ezviz/faultproxy.py` | S2's HTTP fault proxy (H1) |
| `tests/ezviz/probe.py`, `tests/ezviz/probe-run.sh` | item A's long-session probe and its card runner |
| `tests/hub/lib-cameras.sh` | `read_cameras` moved out of make-config (shared with probe-run) |
| `tests/hub/make-config.sh`, `.test.sh`, `fixtures/make-config-responder.sh` | modify: `ezviz` mode, `M7C_RETAIN_DAYS`, P10 |
| `tests/hub/ezviz-ledger.sh` (+ `.test.sh`) | reads both ledgers through the master and prints counts (S5, S8, S10, S11) |
| `tests/hub/power-check.sh` (+ `.test.sh`) | counts `Undervoltage detected` kernel lines since a time (P12) |
| `tests/hub/fixtures/{power,ledger,coverage}-responder.sh` | fake hubs for the three new hub-tool tests |
| `tests/hub/coverage.sh` (+ `.test.sh`) | per-camera recording coverage of a window from Frigate's recordings API, numbers only (S8) |
| `tests/hub/watch.sh`, `observe.sh` (+ tests) | modify: undervoltage trip; `--helpers N` |
| `tests/disk-guard.test.sh`, `tests/configure-ezviz.test.sh` (a throwaway venv, no wheels), `tests/w23-packaging.test.sh`, `tests/w23-size.sh` | hermetic tests of the app, the hook, the packaging and the size |
| `.github/workflows/lint-test.yml` | modify: build the venv and run `tests/ezviz` |
| `docs/w23-findings.md` | item A results, gate results, hub evidence (Tasks 21, 22, Part B) |

---

## Part A — laptop work (workers; no hub, no camera, no key file)

**Setup (before Task 1):** create the worktree `git worktree add ../frigate-wt-w23 -b feat/hub-real-cameras origin/main`. This project has no database, so no test database is needed; every test uses `mktemp -d` trees. Baselines measured on 19 Nov on `origin/main` `9000f91`, in a git checkout:

| Suite | Result |
|---|---|
| `tests/hub/make-config.test.sh` | 157 ok |
| `python3 -m unittest tests.test_go2rtc_config_gen` | 8 tests |
| `tests/hub/watch.test.sh` | 90 ok |
| `tests/hub/observe.test.sh` | 83 ok (70 + 13 git-mode checks, which need a real checkout) |

Every task ends with these suites still green plus its own suite.

**Review checkpoints:**
- one fresh reviewer per task (subagent-driven);
- extra checkpoints after Task 6 (the gate: every lockout property), after Task 11 (S14/S15 complete), after Task 15 (S2) and after Task 20 (packaging);
- Task 12 → **item A gate GA** (Part B0) can run in parallel with Tasks 13–20;
- Task 21 waits for GA.

### Task 1: Runtime pin, dev venv, package skeleton and constants

**Files:**
- Create: `spike/ezviz/requirements.txt` (`git show d5260d4:docs/superpowers/plans/ezviz-t10/requirements.txt > spike/ezviz/requirements.txt`; sha256 `b3282719e5c607e53f5de0943244075708bc2948ec6b4aa130050ce033ab4921`)
- Create: `spike/ezviz/ezviz_source/__init__.py` (empty), `constants.py`, `paths.py`
- Create: `tests/ezviz/venv.sh`, `tests/ezviz/_path.py`
- Test: `tests/ezviz/test_runtime.py`

**Interfaces:**
- Produces: `bash tests/ezviz/venv.sh` prints the venv's python path (`$PY` in every later command). The default location is `$HOME/.cache/frigate-w23/venv`; set `W23_VENV` to one path per worktree.
- Produces: `constants.py` and `paths.py` exactly as below. Every later task imports them.

- [ ] **Step 1: Write the failing test** (`tests/ezviz/test_runtime.py`). The lock is pinned by its sha256 as a literal, because `d5260d4` is on no remote branch and CI checks out shallow; `git show d5260d4` there exits 128 (verified in a depth-1 clone of `main`, plan SF5).

```python
import _path
import hashlib
import importlib.metadata as md
import os
import unittest
from unittest import mock

from ezviz_source import constants as C
from ezviz_source import paths

# sha256 of d5260d4:docs/superpowers/plans/ezviz-t10/requirements.txt (the W-20 lock). A literal, because d5260d4
# is on no remote branch and CI checks out shallow (plan SF5).
LOCK_SHA256 = "b3282719e5c607e53f5de0943244075708bc2948ec6b4aa130050ce033ab4921"


class TestRuntime(unittest.TestCase):
    def test_lock_is_the_w20_lock(self):
        got = hashlib.sha256((_path.REPO / "spike/ezviz/requirements.txt").read_bytes()).hexdigest()
        self.assertEqual(got, LOCK_SHA256)

    def test_pinned_wheel_hash_in_lock(self):
        self.assertIn("ed7c309a1af18e0cdc3665a87d7a1c30c21581ba80a25115d748f76ed2f349f8",
                      (_path.REPO / "spike/ezviz/requirements.txt").read_text())

    def test_pyezvizapi_200_installed(self):
        self.assertEqual(md.version("pyezvizapi"), "2.0.0")

    def test_budget_constants(self):
        self.assertEqual((C.CAP_ATTEMPTS, C.WINDOW_S, C.SPACING_S, C.LADDER_S, C.LATCH_ROW), (3, 3600, 60, (60, 300, 900), 3))

    def test_exit_codes(self):
        self.assertEqual((C.EXIT_STOP, C.EXIT_TEMP, C.EXIT_AUTH, C.EXIT_CONFIG, C.EXIT_USAGE), (0, 75, 77, 78, 64))

    def test_paths_from_env(self):
        with mock.patch.dict(os.environ, {"SNAP": "/s", "SNAP_DATA": "/d", "SNAP_COMMON": "/c"}):
            self.assertEqual(str(paths.camera_dir()), "/d/ezviz/cameras")
            self.assertEqual(str(paths.state_dir()), "/c/ezviz/state")
            self.assertEqual(paths.ffmpeg(), "/s/usr/lib/ffmpeg/8.0/bin/ffmpeg")


if __name__ == "__main__":
    unittest.main()
```
`tests/ezviz/_path.py`:
```python
"""Puts spike/ezviz first on sys.path for the tests; PKG is also exported to child processes."""
import os
import sys
import unittest.mock  # noqa: F401  (tests use unittest.mock.patch)
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PKG = REPO / "spike" / "ezviz"
sys.path.insert(0, str(PKG))
sys.dont_write_bytecode = True


def child_env(**extra) -> dict:
    env = {k: v for k, v in os.environ.items() if not k.startswith("EZVIZ_TEST")}
    env["PYTHONPATH"] = str(PKG)
    env.update(extra)
    return env
```

- [ ] **Step 2: Run it and see it fail**

Run: `PY=$(bash tests/ezviz/venv.sh) && "$PY" -m unittest discover -s tests/ezviz -p 'test_runtime.py' -v`
Expected: FAIL (`venv.sh` or `ezviz_source` is missing).

- [ ] **Step 3: Implement**

`tests/ezviz/venv.sh`:
```bash
#!/usr/bin/env bash
# Builds the laptop/CI venv for the ezviz helper tests from the W-23 hash lock (spike/ezviz/requirements.txt) and
# prints its python path. Idempotent: rebuilds when the lock's sha256 changes. The .pth makes `ezviz_source`
# importable under `python -I` (site-packages .pth files are still read in isolated mode). One venv per worktree:
# set W23_VENV to a worktree-specific path when two worktrees test at once (the .pth names one checkout).
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd); LOCK="$REPO/spike/ezviz/requirements.txt"
V="${W23_VENV:-$HOME/.cache/frigate-w23/venv}"; WANT=$(sha256sum "$LOCK" | cut -d' ' -f1)
if [ "$(cat "$V/lock.sha256" 2>/dev/null || true)" != "$WANT" ]; then
  rm -rf "$V"; python3.12 -m venv "$V"
  "$V/bin/python" -m pip install -q --no-cache-dir --require-hashes --only-binary=:all: --no-deps -r "$LOCK" >&2
  echo "$WANT" > "$V/lock.sha256"
fi
SP=$("$V/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
echo "$REPO/spike/ezviz" > "$SP/ezviz_source.pth"
echo "$V/bin/python"
```
`spike/ezviz/ezviz_source/constants.py`:
```python
"""Every number the W-23 spec pins (D4, D17, D19, D22, §4.1, §4.3). Stdlib only."""
CAP_ATTEMPTS = 3
WINDOW_S = 3600
SPACING_S = 60
LADDER_S = (60, 300, 900)
LADDER_RESET_PUBLISHED_S = 3600
LADDER_RESET_IDLE_S = 3600
FIXED_WAIT_S = 60
LATCH_ROW = 3
SOCKET_TIMEOUT_S = 10.0
PUBLISH_HOLD_S = 5.0
FFMPEG_EXIT_GRACE_S = 1.0
ALARM_S = 4
STARTTIMEOUT_S = 30            # Task 21 may set 45
KEEPALIVE_FORM = "extend"      # Task 21: "extend" | "repeat"
KEEPALIVE_COUNT = 4320         # Task 21: >= 4320, render <= 3 s on the hub
TIMESTAMP_MODE = "wallclock"   # Task 21: "wallclock" | "rtp"
TRIM_KEEP_S = 7 * 86400
EXIT_STOP, EXIT_TEMP, EXIT_AUTH, EXIT_CONFIG, EXIT_USAGE = 0, 75, 77, 78, 64
NAME_RE = r"^[a-z0-9_]{1,32}$"
END_EVENTS = frozenset({"auth_fail", "net_fail", "session_end", "output_end", "stop",
                        "start_timeout", "unknown_end", "protocol_fail"})
```
`spike/ezviz/ezviz_source/paths.py`:
```python
"""Snap paths (spec D7). Each raises KeyError if its variable is unset."""
import os
from pathlib import Path


def camera_dir() -> Path:
    return Path(os.environ["SNAP_DATA"]) / "ezviz" / "cameras"


def state_dir() -> Path:
    return Path(os.environ["SNAP_COMMON"]) / "ezviz" / "state"


def ffmpeg() -> str:
    return os.environ["SNAP"] + "/usr/lib/ffmpeg/8.0/bin/ffmpeg"
```

- [ ] **Step 4: Run it and see it pass** (the same command). Expected: 6 tests OK. Run on 19 Nov in a scratch venv built by this `venv.sh`: OK, and `test_lock_is_the_w20_lock` FAILED once a byte was appended to the lock.
- [ ] **Step 5: Commit** `feat(ezviz): helper runtime lock, dev venv and constants (W-23 T1)`

### Task 2: Camera file and the test fixtures

**Files:** Create `spike/ezviz/ezviz_source/camfile.py`, `tests/ezviz/fixtures.py`. Test `tests/ezviz/test_camfile.py`.

**Interfaces:**
- Produces: `camfile.Camera` (frozen; `repr` is `Camera(<name>)` only), `camfile.CameraFileError` with `.cls` in `{missing, owner, mode, shape}`, and `camfile.load(name, directory) -> Camera`. The file must be regular (no symlink), owned by the effective uid (root in production), mode exactly 0600, and hold exactly the keys `host` (IPv4 literal), `port` (1–65535), `serial` and `login`.
- Produces: `fixtures.Tree` (a temp `$SNAP_DATA`/`$SNAP_COMMON` with a canary camera file), `fixtures.GOOD`, `fixtures.CANARIES`, and the gate runner used from Task 6.

- [ ] **Step 1: Write the failing tests** (`tests/ezviz/test_camfile.py`) and the fixtures:

```python
import _path
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from fixtures import GOOD
from ezviz_source import camfile
from ezviz_source.camfile import CameraFileError, load


def mk(text, mode=0o600):
    d = Path(tempfile.mkdtemp())
    f = d / "cam1.conf"
    f.write_text(text)
    f.chmod(mode)
    return d


class TestCamfile(unittest.TestCase):
    def cls(self, d):
        with self.assertRaises(CameraFileError) as cm:
            load("cam1", d)
        return cm.exception.cls

    def test_good(self):
        c = load("cam1", mk(GOOD))
        self.assertEqual((c.host, c.port, c.serial, c.login), ("192.0.2.11", 8000, "TESTCAM-0001", "QZCNRA"))

    def test_repr_has_no_value(self):
        self.assertEqual(repr(load("cam1", mk(GOOD))), "Camera(cam1)")

    def test_missing(self):
        self.assertEqual(self.cls(Path(tempfile.mkdtemp())), "missing")

    def test_mode_644(self):
        self.assertEqual(self.cls(mk(GOOD, mode=0o644)), "mode")

    def test_owner(self):
        with mock.patch.object(camfile.os, "geteuid", return_value=os.getuid() + 1):
            self.assertEqual(self.cls(mk(GOOD)), "owner")

    def test_symlink_refused(self):
        d = mk(GOOD)
        (d / "cam1.conf").rename(d / "real.conf")
        os.symlink(d / "real.conf", d / "cam1.conf")
        self.assertEqual(self.cls(d), "missing")

    def test_unknown_key(self):
        self.assertEqual(self.cls(mk(GOOD + "x=1\n")), "shape")

    def test_duplicate_key(self):
        self.assertEqual(self.cls(mk(GOOD + "port=8001\n")), "shape")

    def test_missing_key(self):
        self.assertEqual(self.cls(mk(GOOD.replace("serial=TESTCAM-0001\n", ""))), "shape")

    def test_hostname_refused(self):
        self.assertEqual(self.cls(mk(GOOD.replace("192.0.2.11", "cam.local"))), "shape")

    def test_octet_300(self):
        self.assertEqual(self.cls(mk(GOOD.replace(".11", ".300"))), "shape")

    def test_port_range(self):
        self.assertEqual(self.cls(mk(GOOD.replace("8000", "65536"))), "shape")

    def test_login_shape(self):
        self.assertEqual(self.cls(mk(GOOD.replace("QZCNRA", "QZ CN"))), "shape")

    def test_error_text_is_class_only(self):
        with self.assertRaises(CameraFileError) as cm:
            load("cam1", mk(GOOD.replace("QZCNRA", "QZ!!")))
        self.assertEqual((str(cm.exception), cm.exception.args), ("shape", ("shape",)))

    def test_comment_and_crlf(self):
        self.assertEqual(load("cam1", mk("# x\r\n" + GOOD.replace("\n", "\r\n"))).port, 8000)


if __name__ == "__main__":
    unittest.main()
```
```python
"""Shared test fixtures: temp SNAP trees, canary camera files, the gate runner."""
import _path
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

GOOD = "host=192.0.2.11\nport=8000\nserial=TESTCAM-0001\nlogin=QZCNRA\n"
CANARIES = ("192.0.2.11", "TESTCAM-0001", "QZCNRA")


class Tree:
    """A fake $SNAP_DATA / $SNAP_COMMON with a camera file for cam1."""

    def __init__(self, camfile: str = GOOD, mode: int = 0o600):
        self.root = Path(tempfile.mkdtemp())
        self.data, self.common = self.root / "data", self.root / "common"
        self.cams = self.data / "ezviz" / "cameras"
        self.state = self.common / "ezviz" / "state"
        self.cams.mkdir(parents=True)
        if camfile is not None:
            f = self.cams / "cam1.conf"
            f.write_text(camfile)
            f.chmod(mode)

    def env(self, **extra) -> dict:
        return _path.child_env(SNAP=str(self.root / "snap"), SNAP_DATA=str(self.data),
                               SNAP_COMMON=str(self.common), **extra)

    def ledger(self) -> Path:
        return self.state / "cam1.ledger"

    def seed(self, lines: list) -> None:
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.ledger().write_text("".join(lines))
        self.ledger().chmod(0o600)


GATE = """
import sys, time
from ezviz_source import gate, signals
signals.install()
try:
    a = gate.admit(sys.argv[1])
except gate.Refused as r:
    gate.say(sys.argv[1], r.cls, next_in=r.next_in); sys.exit(r.code)
except signals.Terminating:
    sys.exit(0)
print("ADMITTED", flush=True)
time.sleep(float(sys.argv[2]))
"""


def gate_proc(tree: Tree, hold_s: float = 0.0, *, pyflags=(), **env) -> subprocess.Popen:
    return subprocess.Popen([sys.executable, *pyflags, "-c", GATE, "cam1", str(hold_s)], env=tree.env(**env),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def run_gate(tree: Tree, hold_s: float = 0.0, *, pyflags=(), **env):
    t0 = time.monotonic()
    p = gate_proc(tree, hold_s, pyflags=pyflags, **env)
    out, err = p.communicate(timeout=30)
    return p.returncode, out, err, time.monotonic() - t0
```

- [ ] **Step 2: Run and see it fail.** `"$PY" -m unittest discover -s tests/ezviz -p 'test_camfile.py' -v` → ImportError.
- [ ] **Step 3: Implement** `spike/ezviz/ezviz_source/camfile.py`:

```python
"""Camera file reader (spec D7, §6.1, G3). Stdlib only. Never prints or embeds a value in an error."""
import os
import re
import stat
from dataclasses import dataclass
from pathlib import Path

_KEYS = {"host", "port", "serial", "login"}
_OCTET = r"(0|[1-9][0-9]{0,2})"
_IPV4 = re.compile(rf"^{_OCTET}\.{_OCTET}\.{_OCTET}\.{_OCTET}$")
_SERIAL = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
_LOGIN = re.compile(r"^[A-Za-z0-9]{4,32}$")


class CameraFileError(Exception):
    def __init__(self, cls: str):
        super().__init__(cls)
        self.cls = cls


@dataclass(frozen=True, repr=False)
class Camera:
    name: str
    host: str
    port: int
    serial: str
    login: str

    def __repr__(self) -> str:
        return f"Camera({self.name})"


def load(name: str, directory: Path) -> Camera:
    try:
        fd = os.open(Path(directory) / f"{name}.conf", os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        raise CameraFileError("missing") from None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise CameraFileError("missing")
        if st.st_uid != os.geteuid():
            raise CameraFileError("owner")
        if stat.S_IMODE(st.st_mode) != 0o600:
            raise CameraFileError("mode")
        raw = os.read(fd, 4096)
    finally:
        os.close(fd)
    vals = {}
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError:
        raise CameraFileError("shape") from None
    for line in text.replace("\r\n", "\n").split("\n"):
        if not line.strip() or line.startswith("#"):
            continue
        k, sep, v = line.partition("=")
        if not sep or k not in _KEYS or k in vals:
            raise CameraFileError("shape")
        vals[k] = v
    if set(vals) != _KEYS:
        raise CameraFileError("shape")
    m = _IPV4.match(vals["host"])
    if not m or any(int(o) > 255 for o in m.groups()):
        raise CameraFileError("shape")
    if not vals["port"].isdigit() or not 1 <= int(vals["port"]) <= 65535:
        raise CameraFileError("shape")
    if not _SERIAL.match(vals["serial"]) or not _LOGIN.match(vals["login"]):
        raise CameraFileError("shape")
    return Camera(name, vals["host"], int(vals["port"]), vals["serial"], vals["login"])
```

- [ ] **Step 4: Run and see it pass.** Expected: 15 tests OK (run on 19 Nov with the code above: 15 OK).
- [ ] **Step 5: Commit** `feat(ezviz): camera file reader and validator (W-23 T2)`

### Task 3: Ledger I/O

**Files:** Create `spike/ezviz/ezviz_source/ledger.py`. Test `tests/ezviz/test_ledger.py`.

**Interfaces:**
- Consumes: `signals.hook`, `signals.hook_active` (Task 5). To keep TDD order, write Task 5's `signals.py` first or stub those two functions as no-ops here; Task 5 replaces the stub.
- Produces: `ledger.parse(bytes) -> list[dict]`, `ledger.LedgerDamaged`, `ledger.LedgerIOError`, `ledger.Ledger(path)` (a context manager holding flock on the ledger file) with `.records()`, `.append(rec)` and `.trim(now, keep_from)`, and `ledger._fsync_dir(path)`.
- **The lock and trim (SF12).** `trim()` replaces the file, so a process that waited in `flock` on the old inode would append to an unlinked file. `__enter__` therefore re-checks after `flock` that the inode it holds is the one the path names now, and retries if not. `trim()` must be the last operation under a lock.

- [ ] **Step 1: Write the failing tests** (`tests/ezviz/test_ledger.py`):

```python
import _path
import errno
import fcntl
import os
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from ezviz_source import ledger
from ezviz_source.ledger import Ledger, LedgerDamaged, LedgerIOError, parse

A = b'{"t":1,"ev":"attempt","dur":null}\n'


class TestLedger(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.p = self.d / "cam1.ledger"

    def evs(self):
        return [r["ev"] for r in parse(self.p.read_bytes())]

    def test_roundtrip(self):
        with Ledger(self.p) as L:
            L.append({"t": 1.0, "ev": "attempt", "dur": None})
            L.append({"t": 2.0, "ev": "login_ok", "dur": None})
            self.assertEqual([r["ev"] for r in L.records()], ["attempt", "login_ok"])

    def test_torn_last_line_no_newline_is_skipped(self):
        self.assertEqual([r["ev"] for r in parse(A + b'{"t":2,"ev":"pub')], ["attempt"])

    def test_torn_last_line_bad_json_with_newline_is_skipped(self):
        self.assertEqual([r["ev"] for r in parse(A + b'{"t":2,"ev":\n')], ["attempt"])

    def test_torn_login_ok_leaves_session_in_P1(self):
        self.assertEqual(parse(A + b'{"t":2,"ev":"login_o'), [{"t": 1, "ev": "attempt", "dur": None}])

    def test_next_append_starts_on_a_new_line(self):
        self.p.write_bytes(A + b'{"t":2,"ev":"lo')
        with Ledger(self.p) as L:
            L.append({"t": 3, "ev": "net_fail", "dur": 2, "syn": True})
        self.assertEqual(self.p.read_bytes().count(b"\n"), 2)
        self.assertEqual(self.evs(), ["attempt", "net_fail"])

    def test_mid_file_damage_is_reported(self):
        with self.assertRaises(LedgerDamaged):
            parse(A + b"garbage\n" + b'{"t":3,"ev":"stop","dur":2}\n')

    def test_non_numeric_t_mid_file_is_damage(self):
        with self.assertRaises(LedgerDamaged):
            parse(b'{"t":"x","ev":"attempt"}\n' + A)

    def test_file_mode_0600_and_append_fsyncs_file_and_dir(self):
        with mock.patch.object(ledger.os, "fsync", wraps=os.fsync) as fs:
            with Ledger(self.p) as L:
                L.append({"t": 1.0, "ev": "attempt", "dur": None})
            self.assertEqual(fs.call_count, 2)
        self.assertEqual(self.p.stat().st_mode & 0o777, 0o600)

    def test_append_oserror_becomes_ledgerioerror(self):
        with Ledger(self.p) as L:
            with mock.patch.object(ledger.os, "write", side_effect=OSError(errno.ENOSPC, "full")):
                with self.assertRaises(LedgerIOError):
                    L.append({"t": 1.0, "ev": "attempt", "dur": None})

    def test_trim_keeps_last_7_days_and_keep_from(self):
        now, day = 2_000_000_000.0, 86400
        self.p.write_bytes(b"".join(b'{"t":%d,"ev":"stop","dur":null}\n' % (now - n * day) for n in (9, 8, 6)))
        with Ledger(self.p) as L:
            L.trim(now, keep_from=now - 8 * day)
        self.assertEqual([r["t"] for r in parse(self.p.read_bytes())], [now - 8 * day, now - 6 * day])
        with Ledger(self.p) as L:
            L.trim(now, keep_from=now)
        self.assertEqual([r["t"] for r in parse(self.p.read_bytes())], [now - 6 * day])

    def test_lock_excludes_second_holder(self):
        with Ledger(self.p):
            fd = os.open(self.p, os.O_RDWR)
            try:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                os.close(fd)

    def test_waiter_on_a_trimmed_file_appends_to_the_new_file(self):    # SF12
        now = 2_000_000_000.0
        self.p.write_bytes(b'{"t":%d,"ev":"stop","dur":null}\n' % (now - 9 * 86400) + A)
        done = threading.Event()

        def unlatcher():
            with Ledger(self.p) as L:                 # blocks until the trimmer releases
                L.append({"t": now, "ev": "unlatch", "dur": None})
            done.set()
        with Ledger(self.p) as L:
            th = threading.Thread(target=unlatcher)
            th.start()
            time.sleep(0.3)
            self.assertFalse(done.is_set())
            L.trim(now, keep_from=now)                 # replaces the file: the waiter holds the old inode
        th.join(5)
        self.assertEqual(self.evs(), ["unlatch"])

    def test_symlinked_ledger_refused(self):
        os.symlink(self.d / "elsewhere", self.p)
        with self.assertRaises(LedgerIOError):
            with Ledger(self.p):
                pass


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run and see it fail.** `"$PY" -m unittest discover -s tests/ezviz -p 'test_ledger.py' -v`
- [ ] **Step 3: Implement** `spike/ezviz/ezviz_source/ledger.py`:

```python
"""The per-camera ledger (spec §4.3, D18, D21; plan P8, SF12). Stdlib only.

One JSON object per line: {"t": epoch, "ev": str, "dur": float|None} plus "syn": true on synthetic records.
A torn LAST line is skipped; any other bad line raises LedgerDamaged (P8). The ledger lock is flock on the
ledger file itself (D18); because trim() replaces the file, a locker re-checks after flock that it holds the
inode the path names now, and retries if not (SF12). trim() must be the last operation under a lock.
"""
import fcntl
import json
import os
from pathlib import Path

from . import constants as C
from . import signals


class LedgerDamaged(Exception):
    pass


class LedgerIOError(Exception):
    pass


def _valid(rec) -> bool:
    t = rec.get("t") if isinstance(rec, dict) else None
    return (isinstance(t, (int, float)) and not isinstance(t, bool)
            and isinstance(rec.get("ev"), str))


def parse(data: bytes) -> list:
    lines = data.split(b"\n")
    tail = lines.pop()                       # bytes after the last newline: a torn line if not empty
    out = []
    for i, line in enumerate(lines):
        try:
            rec = json.loads(line)
        except ValueError:
            rec = None
        if not _valid(rec):
            if i == len(lines) - 1 and tail == b"":
                continue                     # the last line, newline-terminated but bad: torn
            raise LedgerDamaged()
        out.append(rec)
    return out                               # a non-empty tail has no newline: torn, skipped


def _fsync_dir(d: Path) -> None:
    fd = os.open(d, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


class Ledger:
    """Context manager: holds flock(LOCK_EX) on the ledger file for its whole body."""

    def __init__(self, path):
        self.path = Path(path)
        self._fd = None

    def __enter__(self):
        try:
            while True:
                fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
                fcntl.flock(fd, fcntl.LOCK_EX)
                held = os.fstat(fd)
                try:
                    now = os.stat(self.path, follow_symlinks=False)
                except FileNotFoundError:
                    now = None
                if now is not None and (held.st_ino, held.st_dev) == (now.st_ino, now.st_dev):
                    self._fd = fd
                    return self
                os.close(fd)                 # trim() replaced the file while we waited: lock the new one
        except OSError as e:
            raise LedgerIOError(type(e).__name__) from None

    def __exit__(self, *exc):
        if self._fd is not None:
            os.close(self._fd)
            self._fd = None
        return False

    def _read(self) -> bytes:
        os.lseek(self._fd, 0, os.SEEK_SET)
        chunks = []
        while True:
            b = os.read(self._fd, 65536)
            if not b:
                return b"".join(chunks)
            chunks.append(b)

    def records(self) -> list:
        try:
            return parse(self._read())
        except OSError as e:
            raise LedgerIOError(type(e).__name__) from None

    def append(self, rec: dict) -> None:
        line = (json.dumps(rec, separators=(",", ":")) + "\n").encode()
        try:
            signals.hook("enospc_append")
            data = self._read()
            if data and not data.endswith(b"\n"):
                os.ftruncate(self._fd, data.rfind(b"\n") + 1)   # never join a new record to a torn one
            os.lseek(self._fd, 0, os.SEEK_END)
            if signals.hook_active("pause_cs:" + rec["ev"]):    # K1 test: a SIGTERM lands mid-record
                half = len(line) // 2
                os.write(self._fd, line[:half])
                signals.hook("pause_cs:" + rec["ev"])
                line = line[half:]
            if os.write(self._fd, line) != len(line):
                raise OSError("short write")
            os.fsync(self._fd)
            _fsync_dir(self.path.parent)
        except OSError as e:
            raise LedgerIOError(type(e).__name__) from None

    def trim(self, now: float, keep_from: float) -> None:
        recs = self.records()
        keep = [r for r in recs if r["t"] >= now - C.TRIM_KEEP_S or r["t"] >= keep_from]
        if len(keep) == len(recs):
            return
        tmp = self.path.with_name(self.path.name + ".tmp")
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
            try:
                os.write(fd, b"".join((json.dumps(r, separators=(",", ":")) + "\n").encode() for r in keep))
                os.fsync(fd)
            finally:
                os.close(fd)
            os.replace(tmp, self.path)
            _fsync_dir(self.path.parent)
        except OSError as e:
            raise LedgerIOError(type(e).__name__) from None
```

- [ ] **Step 4: Run and see it pass.** Expected: 13 tests OK (run on 19 Nov: 13 OK).
- [ ] **Step 5: Mutation tests.** Each one, applied alone to the code above, made its test FAIL on 19 Nov:

| Mutation | Fails |
|---|---|
| a torn last line raises instead of being skipped | `test_torn_last_line_bad_json_with_newline_is_skipped` |
| no truncate to the last newline before an append | `test_next_append_starts_on_a_new_line` |
| no inode re-check after `flock` (SF12) | `test_waiter_on_a_trimmed_file_appends_to_the_new_file` |

- [ ] **Step 6: Commit** `feat(ezviz): ledger with torn-line rule, fsynced appends, trim-safe lock (W-23 T3)`

### Task 4: Policy — T-END and the D4 budget as pure functions

**Files:** Create `spike/ezviz/ezviz_source/policy.py`. Test `tests/ezviz/test_policy.py`.

**Interfaces:**
- Produces: `policy.Decision` (`allow`, `cls`, `next_allowed`, `attempts_in_window`, `synthetic`, `latch_now`), `policy.decide(records, now, *, latch_file) -> Decision` and `policy.phase_of_open_session(records)`.
- **The ladder (SF1).** A reset sets k to 0 **before** the session's own end is counted, so the first rung after any reset waits 60 s: D4's "resets **to** 60 s". The resets are an attempt 3600 s or more after the previous one, a session published for 3600 s or more, and the last `unlatch`. At decision time, 3600 s or more since the last attempt caps k at 1.
- **One branch has no test, on purpose.** The "published ≥ 3600 s" reset can never change a decision on its own: publishing follows the attempt, so such a session's attempt is ≥ 3600 s old, and the idle rules already apply. The mutation that deletes this branch is **equivalent** and survives every test; this was run on 19 Nov. The branch is kept so that the code reads like D4.

- [ ] **Step 1: Write the failing tests** (`tests/ezviz/test_policy.py`). All timestamps are literal offsets from `T0`, and each comment names the T-END row or D4 clause:

```python
import _path
import unittest

from ezviz_source.policy import decide, phase_of_open_session

T0 = 1_800_000_000.0


def R(t, ev, **kw):
    return dict({"t": T0 + t, "ev": ev, "dur": None}, **kw)


def P2(t, end_ev, end_after=9):
    """A session that logged in at t+2 and ended (end_ev) before publishing."""
    return [R(t, "attempt"), R(t + 2, "login_ok"), R(t + end_after, end_ev)]


def P3(t, end_ev, end_at):
    """A session published at t+9 that ended (end_ev) at t+end_at."""
    return [R(t, "attempt"), R(t + 2, "login_ok"), R(t + 9, "published"), R(t + end_at, end_ev)]


def P1(t):
    return [R(t, "attempt"), R(t + 1, "net_fail")]


def at(recs, t, latch_file=False):
    return decide(recs, T0 + t, latch_file=latch_file)


class TestTEnd(unittest.TestCase):
    def test_E1_empty_ledger_allows(self):
        d = at([], 0)
        self.assertEqual((d.allow, d.cls, d.synthetic, d.attempts_in_window), (True, "ok", None, 0))

    def test_E2_auth_fail_latches(self):
        d = at([R(0, "attempt"), R(1, "auth_fail")], 7200)
        self.assertEqual((d.allow, d.cls, d.latch_now), (False, "latched", True))

    def test_E2_latch_file_present_means_no_second_latch_record(self):
        d = at([R(0, "attempt"), R(1, "auth_fail")], 7200, latch_file=True)
        self.assertEqual((d.cls, d.latch_now), ("latched", False))

    def test_E3_net_fail_is_rung_60(self):
        d = at([R(0, "attempt"), R(5, "net_fail")], 30)
        self.assertEqual(d.next_allowed, T0 + 65)

    def test_E5_open_P1_gets_synthetic_net_fail_once(self):          # D21, H3
        recs = [R(0, "attempt")]
        d = at(recs, 100)
        self.assertEqual((d.synthetic["ev"], d.synthetic["syn"], d.synthetic["t"]), ("net_fail", True, T0 + 100))
        self.assertEqual(d.next_allowed, T0 + 160)
        d2 = at(recs + [d.synthetic], 130)                             # a refused decision 30 s later
        self.assertIsNone(d2.synthetic)
        self.assertEqual(d2.next_allowed, d.next_allowed)

    def test_E6_published_resets_row(self):
        recs = P2(0, "start_timeout") + P2(1000, "start_timeout") + P3(2000, "stop", 100) + P2(3000, "start_timeout")
        self.assertEqual(at(recs, 9000).cls, "ok")

    def test_E7_E8_E9_E10_each_add_one(self):                           # K3
        for ev in ("start_timeout", "session_end", "output_end", "protocol_fail"):
            recs = P2(0, ev) + P2(7200, ev) + P2(14400, ev)
            self.assertEqual(at(recs, 30000).cls, "latched", ev)

    def test_two_P2_ends_do_not_latch(self):
        self.assertEqual(at(P2(0, "session_end") + P2(7200, "session_end"), 30000).cls, "ok")

    def test_E11_open_P2_gets_unknown_end_and_adds_to_row(self):
        recs = P2(0, "start_timeout") + P2(7200, "start_timeout") + [R(14400, "attempt"), R(14402, "login_ok")]
        d = at(recs, 14500)
        self.assertEqual((d.synthetic["ev"], d.cls, d.latch_now), ("unknown_end", "latched", True))

    def test_E13_stop_after_published_has_no_wait_but_spacing(self):
        recs = P3(0, "stop", 20)
        self.assertEqual(at(recs, 30).next_allowed, T0 + 60)
        self.assertTrue(at(recs, 60).allow)

    def test_E14_session_end_after_published_is_rung(self):
        self.assertEqual(at(P3(0, "session_end", 100), 120).next_allowed, T0 + 160)

    def test_E17_open_P3_waits_fixed_60_and_does_not_climb(self):
        recs = [R(0, "attempt"), R(2, "login_ok"), R(9, "published")]
        d = at(recs, 500)
        self.assertEqual((d.synthetic["ev"], d.next_allowed), ("unknown_end", T0 + 560))
        recs2 = recs + [d.synthetic, R(600, "attempt"), R(602, "login_ok"), R(609, "published")]
        d2 = at(recs2, 900)
        self.assertEqual((d2.synthetic["ev"], d2.next_allowed), ("unknown_end", T0 + 960))

    def test_phase_of_open_session(self):
        self.assertEqual(phase_of_open_session([R(0, "attempt")]), "P1")
        self.assertEqual(phase_of_open_session([R(0, "attempt"), R(1, "login_ok")]), "P2")
        self.assertEqual(phase_of_open_session(P3(0, "stop", 20)[:3]), "P3")
        self.assertIsNone(phase_of_open_session(P3(0, "stop", 20)))


class TestBudget(unittest.TestCase):
    def test_fourth_attempt_in_60_min_refused(self):
        recs = P3(0, "stop", 60) + P3(70, "stop", 60) + P3(140, "stop", 60)
        d = at(recs, 300)
        self.assertEqual((d.allow, d.cls, d.next_allowed, d.attempts_in_window), (False, "budget_wait", T0 + 3600, 3))
        self.assertTrue(at(recs, 3600).allow)

    def test_attempt_within_60_s_refused(self):
        recs = P3(0, "stop", 20)
        d = at(recs, 59)
        self.assertEqual((d.allow, d.next_allowed), (False, T0 + 60))
        self.assertTrue(at(recs, 60).allow)

    def test_cap_counts_attempt_records_only(self):
        recs = [R(0, "attempt"), R(100, "net_fail", syn=True), R(200, "attempt"), R(205, "net_fail"), R(206, "latch")]
        self.assertEqual(at(recs, 300).attempts_in_window, 2)

    def test_ladder_climbs_60_300_900_then_window(self):
        recs, got = [], []
        for t in (0, 61, 362, 3600):                                   # each attempt at its allowed time
            recs += [R(t, "attempt"), R(t + 1, "net_fail")]
            got.append(at(recs, t + 2).next_allowed - T0)
        self.assertEqual(got, [61, 362, 3600, 3661])                   # rung 3 (900 s) is inside the cap here

    def test_third_rung_waits_900(self):                               # older attempts: the cap does not bind
        self.assertEqual(at(P1(0) + P1(3000) + P1(3400), 3402).next_allowed, T0 + 3401 + 900)

    def test_ladder_resets_after_60_min_published(self):              # D4: resets TO 60 s (SF1)
        recs = P1(0) + P1(61) + P3(362, "session_end", 9 + 3600)     # published 3600 s, then dropped
        self.assertEqual(at(recs, 3980).next_allowed, T0 + 362 + 3609 + 60)

    def test_ladder_resets_after_60_min_idle(self):                   # SF1(c)
        recs = P1(0) + P1(61) + P1(362) + P1(362 + 3600)               # k=3, then an attempt 3600 s later
        self.assertEqual(at(recs, 3970).next_allowed, T0 + 3963 + 60)

    def test_ladder_back_to_60_s_at_decision_time_after_idle_hour(self):
        recs = P1(0) + P1(61) + P3(362, "session_end", 3138)          # k=3: wait until 3500 + 900
        self.assertEqual(at(recs, 3961).next_allowed, T0 + 4400)       # 3599 s since the last attempt
        self.assertTrue(at(recs, 3962).allow)                          # 3600 s: rung back to 60 s, long past

    def test_future_dated_attempt_counts_in_window_and_spacing(self):  # Review Focus 1
        d = at([R(600, "attempt"), R(605, "net_fail")], 0)
        self.assertEqual((d.allow, d.attempts_in_window), (False, 1))
        self.assertGreaterEqual(d.next_allowed, T0 + 660)

    def test_latch_file_alone_latches(self):
        self.assertEqual(at([], 0, latch_file=True).cls, "latched")

    def test_unlatch_resets_row_and_ladder_not_cap(self):             # P6
        recs = P2(0, "start_timeout") + P2(600, "start_timeout") + P2(1200, "start_timeout")
        self.assertEqual(at(recs, 1400).cls, "latched")
        d = at(recs + [R(1209, "latch"), R(1300, "unlatch")], 1400)
        self.assertEqual((d.cls, d.next_allowed), ("budget_wait", T0 + 3600))

    def test_auth_fail_before_unlatch_no_longer_latches(self):
        recs = [R(0, "attempt"), R(1, "auth_fail"), R(1, "latch"), R(4000, "unlatch")]
        self.assertTrue(at(recs, 4100).allow)

    def test_J2_start_timeout_net_fail_start_timeout_start_timeout_latches(self):
        recs = P2(0, "start_timeout") + P1(7200) + P2(14400, "start_timeout") + P2(21600, "start_timeout")
        self.assertEqual(at(recs, 30000).cls, "latched")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run and see them fail.** `"$PY" -m unittest discover -s tests/ezviz -p 'test_policy.py' -v`
- [ ] **Step 3: Implement** `spike/ezviz/ezviz_source/policy.py`:

```python
"""T-END (spec §4.3) and the D4 login budget as pure functions. Stdlib only.

A session starts at an "attempt" record; its login_ok, published and first end record belong to it.
Phase: P1 no login_ok, P2 login_ok but no published, P3 published. The latch row and the ladder count
only what lies after the last "unlatch" record (plan P6); the cap and the spacing count every "attempt"
record and nothing else (rev 5 nit 2), future-dated ones included (Review Focus 1).
"""
from dataclasses import dataclass

from . import constants as C


@dataclass(frozen=True)
class Decision:
    allow: bool
    cls: str                  # "ok" | "budget_wait" | "latched"
    next_allowed: float       # == now when allow
    attempts_in_window: int
    synthetic: object         # dict to append BEFORE acting (D21), or None
    latch_now: bool           # latched by auth_fail or a full row, and no "latch" record since the last unlatch


def _split(records: list) -> list:
    sessions, cur = [], None
    for r in records:
        ev = r["ev"]
        if ev == "attempt":
            cur = {"a": r["t"], "login_ok": None, "published": None, "end": None}
            sessions.append(cur)
        elif cur is not None and cur["end"] is None:
            if ev == "login_ok" and cur["login_ok"] is None:
                cur["login_ok"] = r["t"]
            elif ev == "published" and cur["published"] is None:
                cur["published"] = r["t"]
            elif ev in C.END_EVENTS:
                cur["end"] = r
    return sessions


def _phase(s: dict) -> str:
    if s["login_ok"] is None:
        return "P1"
    return "P2" if s["published"] is None else "P3"


def phase_of_open_session(records: list):
    s = _split(records)
    return _phase(s[-1]) if s and s[-1]["end"] is None else None


def _effect(s: dict) -> str:
    """T-END ladder column for an ended session: auth | rung | fixed | none."""
    ev, ph = s["end"]["ev"], _phase(s)
    if ev == "auth_fail":
        return "auth"                                  # E2
    if ph in ("P1", "P2"):
        return "rung"                                  # E3-E5, E7-E11
    if ev == "stop":
        return "none"                                  # E13
    if ev == "unknown_end":
        return "fixed"                                 # E17
    return "rung"                                      # E14-E16


def decide(records: list, now: float, *, latch_file: bool) -> Decision:
    recs = list(records)
    synthetic = None
    every = _split(recs)
    if every and every[-1]["end"] is None:             # D21: class the dead open session once, t = now
        synthetic = {"t": now, "ev": "net_fail" if _phase(every[-1]) == "P1" else "unknown_end",
                     "dur": None, "syn": True}
        recs.append(synthetic)
        every[-1]["end"] = synthetic
    attempts = sorted(s["a"] for s in every)

    cut = max((i for i, r in enumerate(recs) if r["ev"] == "unlatch"), default=-1)
    tail = recs[cut + 1:]
    sess = _split(tail)

    row, auth = 0, False
    for s in sess:
        if s["published"] is not None:
            row = 0                                     # E6
        elif s["end"] is not None and _phase(s) == "P2":
            row += 1                                    # E7-E11
        if s["end"] is not None and s["end"]["ev"] == "auth_fail":
            auth = True                                 # E2
    latched = latch_file or auth or row >= C.LATCH_ROW
    latch_now = latched and not latch_file and not any(r["ev"] == "latch" for r in tail)

    # Ladder (D4): a reset puts k back to 0 BEFORE the session's own end is counted, so the next rung
    # after a reset waits LADDER_S[0] = 60 s ("resets TO 60 s", SF1).
    k, prev_a = 0, None
    for s in sess:
        if prev_a is not None and s["a"] - prev_a >= C.LADDER_RESET_IDLE_S:
            k = 0
        prev_a = s["a"]
        if s["published"] is not None and s["end"]["t"] - s["published"] >= C.LADDER_RESET_PUBLISHED_S:
            k = 0
        if _effect(s) == "rung":
            k += 1

    wait_end = 0.0
    if sess:
        last = sess[-1]
        eff, e = _effect(last), last["end"]["t"]
        if eff == "rung":
            if attempts and now - attempts[-1] >= C.LADDER_RESET_IDLE_S:
                k = min(k, 1)                           # 60 min with no attempt: back to the 60 s rung
            if k <= len(C.LADDER_S):
                wait_end = e + C.LADDER_S[k - 1]
            elif len(attempts) >= C.CAP_ATTEMPTS:      # rung 4+: until the window allows (P7)
                wait_end = attempts[-C.CAP_ATTEMPTS] + C.WINDOW_S
        elif eff == "fixed":
            wait_end = e + C.FIXED_WAIT_S

    window = [a for a in attempts if a > now - C.WINDOW_S]
    spacing = attempts[-1] + C.SPACING_S if attempts else 0.0
    cap = attempts[-C.CAP_ATTEMPTS] + C.WINDOW_S if len(window) >= C.CAP_ATTEMPTS else 0.0
    next_allowed = max(now, spacing, cap, wait_end)
    allow = not latched and next_allowed <= now
    cls = "latched" if latched else ("ok" if allow else "budget_wait")
    return Decision(allow, cls, next_allowed, len(window), synthetic, latch_now)
```

- [ ] **Step 4: Run and see them pass.** Expected: 26 tests OK (run on 19 Nov: 26 OK).
- [ ] **Step 5: Mutation tests** (the spec's S1 and S15 named mutations, plus the safety properties). Each one, applied alone, made its test FAIL on 19 Nov:

| Mutation | Fails |
|---|---|
| **the 4b659ae algorithm (SF1):** reset after counting, idle reset to k=0 | `test_ladder_resets_after_60_min_published`, `test_ladder_back_to_60_s_at_decision_time_after_idle_hour` |
| re-classify each time (synthetic records ignored as ends) (H3) | `test_E5_open_P1_gets_synthetic_net_fail_once` |
| `net_fail` resets the row (J2) | `test_J2_…` |
| only `start_timeout` and `protocol_fail` count in the row (K3) | `test_E7_E8_E9_E10_each_add_one` |
| the cap counts every record | `test_cap_counts_attempt_records_only` |
| the window excludes `t > now` | `test_future_dated_attempt_counts_in_window_and_spacing` |
| E17 climbs the ladder | `test_E17_open_P3_waits_fixed_60_and_does_not_climb` |
| the cap allows 4 (`>` for `>=`) | `test_fourth_attempt_in_60_min_refused` |
| no 60 s spacing | `test_attempt_within_60_s_refused`, `test_E13_…` |
| `auth_fail` does not latch | `test_E2_auth_fail_latches` |
| no unlatch cut (P6) | `test_unlatch_resets_row_and_ladder_not_cap` |

- [ ] **Step 6: Commit** `feat(ezviz): T-END and login budget policy with named mutations (W-23 T4)`

### Task 5: Signals — the once-only SIGTERM handler, the critical section, the alarm

**Files:** Create `spike/ezviz/ezviz_source/signals.py`. Test `tests/ezviz/test_signals.py` (each case runs a small child script).

**Interfaces:**
- Produces: `Terminating(BaseException)`, `install()`, `critical()`, `mark_ended()`, `sigterm_seen()`, `wait_for_sigterm(seconds)`, `hook_active(name)` and `hook(name)`.
- The test hooks are inert unless `EZVIZ_TEST_HOOKS` names them; the go2rtc unit never sets it:
  - `pause_gate` sleeps 2 s before the decision;
  - `pause_cs:<ev>` splits the `<ev>` append and sleeps 2 s in the middle;
  - `pause_close` sleeps 1 s in the SIGTERM close path (SF4);
  - `stall_close` sleeps 60 s there;
  - `enospc_append` raises `OSError(ENOSPC)` in `Ledger.append`.

- [ ] **Step 1: Write the failing tests** (`tests/ezviz/test_signals.py`). The harness reads the child's "ready" with raw `os.read`, because `communicate(timeout=…)` reads the raw fd and would lose anything a buffered `readline` had taken:

```python
import _path
import os
import signal
import subprocess
import sys
import textwrap
import time
import unittest

PRE = "import os, signal, socket, sys, time\nfrom ezviz_source import signals\nsignals.install()\n"


def run(body, *, kills=(), env_extra=None, timeout=15):
    """Run PRE+body in a child; kills = [(delay_s, signum), ...] sent from here. Returns (rc, out, secs)."""
    p = subprocess.Popen([sys.executable, "-c", PRE + textwrap.dedent(body)], stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, env=_path.child_env(**(env_extra or {})), bufsize=0)
    t0 = time.monotonic()
    got = b""
    while len(got) < 6:                                  # raw reads: communicate(timeout) bypasses any buffer
        got += os.read(p.stdout.fileno(), 6 - len(got))
    assert got == b"ready\n", got
    for delay, sig in kills:
        time.sleep(max(0.0, t0 + delay - time.monotonic()))
        try:
            p.send_signal(sig)
        except ProcessLookupError:
            pass
    out, _ = p.communicate(timeout=timeout)
    return p.returncode, out.decode(), time.monotonic() - t0


class TestSignals(unittest.TestCase):
    def test_first_sigterm_raises_terminating_in_blocking_recv(self):        # J1
        rc, out, secs = run("""
            a, b = socket.socketpair(); a.settimeout(30); print("ready", flush=True)
            try:
                a.recv(1)
            except signals.Terminating:
                print("terminating", flush=True); os._exit(0)
        """, kills=[(0.2, signal.SIGTERM)])
        self.assertEqual((rc, out.strip()), (0, "terminating"))
        self.assertLess(secs, 1.5)

    def test_second_sigterm_does_not_raise(self):                              # L1
        rc, out, _ = run("""
            print("ready", flush=True)
            try:
                time.sleep(10)
            except signals.Terminating:
                try:
                    time.sleep(1.0)
                    print("no second raise", flush=True)
                except signals.Terminating:
                    print("raised twice", flush=True)
                os._exit(0)
        """, kills=[(0.2, signal.SIGTERM), (0.25, signal.SIGTERM)])
        self.assertEqual((rc, out.strip()), (0, "no second raise"))

    def test_second_sigterm_does_not_rearm(self):                              # L1, SF4
        rc, out, secs = run("""
            print("ready", flush=True)
            try:
                time.sleep(10)
            except signals.Terminating:
                time.sleep(30)
        """, kills=[(0.0, signal.SIGTERM), (2.0, signal.SIGTERM)], timeout=20)
        self.assertEqual(rc, -signal.SIGALRM)
        self.assertLess(abs(secs - 4.0), 0.5)

    def test_sigterm_inside_critical_is_pending_until_exit(self):             # K1
        rc, out, _ = run("""
            print("ready", flush=True)
            try:
                with signals.critical():
                    for i in range(3):
                        time.sleep(0.3); print("line", i, flush=True)
                print("after", flush=True)
            except signals.Terminating:
                print("terminating", flush=True); os._exit(0)
        """, kills=[(0.1, signal.SIGTERM)])
        self.assertEqual(out.split("\n")[:4], ["line 0", "line 1", "line 2", "terminating"])

    def test_mark_ended_suppresses_the_raise(self):                            # SF3
        rc, out, _ = run("""
            print("ready", flush=True)
            with signals.critical():
                signals.mark_ended(); time.sleep(0.5)
            print("ended cleanly", flush=True); os._exit(75)
        """, kills=[(0.1, signal.SIGTERM)])
        self.assertEqual((rc, out.strip()), (75, "ended cleanly"))

    def test_alarm_kills_a_stalled_process_with_sigalrm(self):                # H5a
        rc, _, secs = run("""
            print("ready", flush=True)
            try:
                time.sleep(10)
            except signals.Terminating:
                signals.hook("stall_close")
        """, kills=[(0.2, signal.SIGTERM)], env_extra={"EZVIZ_TEST_HOOKS": "stall_close"}, timeout=20)
        self.assertEqual(rc, -signal.SIGALRM)
        self.assertLess(secs, 5.0)

    def test_alarm_is_default_action_not_python_handler(self):
        rc, out, _ = run("""
            print("ready", flush=True)
            try:
                time.sleep(10)
            except signals.Terminating:
                print(signal.getsignal(signal.SIGALRM) == signal.SIG_DFL, flush=True); os._exit(0)
        """, kills=[(0.2, signal.SIGTERM)])
        self.assertEqual(out.strip(), "True")

    def test_hooks_inactive_without_env(self):
        rc, out, secs = run("""
            print("ready", flush=True); signals.hook("stall_close"); print("returned", flush=True)
        """)
        self.assertEqual((rc, out.strip()), (0, "returned"))
        self.assertLess(secs, 2)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run and see them fail.** `"$PY" -m unittest discover -s tests/ezviz -p 'test_signals.py' -v`
- [ ] **Step 3: Implement** `spike/ezviz/ezviz_source/signals.py`:

```python
"""SIGTERM handling for ezviz-source (spec D17; card L1; spec K1). Stdlib only.

The first SIGTERM sets SIGALRM to SIG_DFL, arms alarm(ALARM_S) and raises Terminating (a BaseException,
so the library's `except Exception` cannot swallow it). Every later SIGTERM only returns (L1): it never
re-arms and never raises. Inside critical() the first SIGTERM is held pending and raised when the
outermost section exits (K1). After mark_ended() nothing raises any more (plan SF3).
"""
import errno
import os
import signal
import time
from contextlib import contextmanager

from . import constants as C


class Terminating(BaseException):
    pass


class _State:
    seen = False      # a SIGTERM has arrived
    raised = False    # Terminating has been raised once
    depth = 0         # critical() nesting
    ended = False     # an end record is being or has been written


_st = _State()


def _on_sigterm(signum, frame):
    if _st.seen:                    # L1: later SIGTERMs only mark pending; no re-arm, no raise
        return
    _st.seen = True
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.alarm(C.ALARM_S)         # the kernel ends the process even inside a C call (H5a)
    if _st.depth == 0 and not _st.ended:
        _st.raised = True
        raise Terminating()         # J1a: ends the interrupted blocking call at once


def install() -> None:
    signal.signal(signal.SIGTERM, _on_sigterm)


@contextmanager
def critical():
    _st.depth += 1
    try:
        yield
    finally:
        _st.depth -= 1
        if _st.depth == 0 and _st.seen and not _st.raised and not _st.ended:
            _st.raised = True
            raise Terminating()


def mark_ended() -> None:
    _st.ended = True


def sigterm_seen() -> bool:
    return _st.seen


def wait_for_sigterm(seconds: float) -> None:
    """Sleep up to `seconds`; the first SIGTERM raises Terminating through the handler."""
    end = time.monotonic() + seconds
    while True:
        left = end - time.monotonic()
        if left <= 0:
            return
        time.sleep(left)


def _hooks() -> list:
    return [h for h in os.environ.get("EZVIZ_TEST_HOOKS", "").split(",") if h]


def hook_active(name: str) -> bool:
    return name in _hooks()


def hook(name: str) -> None:
    """Test hooks; inert unless EZVIZ_TEST_HOOKS names them (the go2rtc unit never sets it)."""
    if not hook_active(name):
        return
    if name == "enospc_append":
        raise OSError(errno.ENOSPC, "test hook")
    if name == "stall_close":
        time.sleep(60)
    elif name == "pause_close":
        time.sleep(1.0)
    elif name.startswith("pause"):
        time.sleep(2.0)
```

- [ ] **Step 4: Run and see them pass.** Expected: 8 tests OK, under 30 s (run on 19 Nov: 8 OK).
- [ ] **Step 5: Mutation tests.** Each one, applied alone, made its test FAIL on 19 Nov:

| Mutation | Fails |
|---|---|
| raise on every SIGTERM (L1) | `test_second_sigterm_does_not_raise` |
| re-arm the alarm on every SIGTERM (L1, SF4) | `test_second_sigterm_does_not_rearm` (death at ~6 s, not 4 s) |
| a flag-only handler (J1) | `test_first_sigterm_raises_terminating_in_blocking_recv` |
| raise inside `critical()` (K1) | `test_sigterm_inside_critical_is_pending_until_exit` |
| `mark_ended()` ignored (SF3) | `test_mark_ended_suppresses_the_raise` |
| the alarm with a Python handler (H5a) | `test_alarm_kills_a_stalled_process_with_sigalrm` |

- [ ] **Step 6: Commit** `feat(ezviz): once-only SIGTERM handler, ledger critical section, 4 s alarm (W-23 T5, L1)`

### Task 6: The pre-contact gate

**Files:** Create `spike/ezviz/ezviz_source/gate.py`. Test `tests/ezviz/test_gate.py`.

**Interfaces:**
- Consumes: `camfile`, `ledger`, `policy`, `signals`, `paths`, `constants`.
- Produces: `gate.admit(name, now=time.time, on_attempt=None) -> Admitted`, `gate.Refused` (`.cls`, `.code`, `.next_in`), `gate.say(name, cls, *, attempt=None, next_in=None)` and `gate.write_latch(state, name)`.
- `on_attempt(t, ledger_path)` is called **inside** the critical section, right after the `attempt` record (SF2). A SIGTERM held pending there is then classed P1 (E4), not P0.
- The gate imports nothing outside the stdlib (N5).

- [ ] **Step 1: Write the failing tests** (`tests/ezviz/test_gate.py`). They run the gate in a child process through `fixtures.run_gate` (Task 2):

```python
import _path
import fcntl
import json
import os
import statistics
import time
import unittest

from fixtures import CANARIES, GOOD, Tree, gate_proc, run_gate

NOW = time.time()


def rec(dt, ev, **kw):
    return json.dumps(dict({"t": NOW + dt, "ev": ev, "dur": None}, **kw)) + "\n"


class TestGate(unittest.TestCase):
    def evs(self, tree):
        return [json.loads(x)["ev"] for x in tree.ledger().read_text().splitlines()]

    def test_busy_when_session_lock_held(self):
        t = Tree()
        t.state.mkdir(parents=True, mode=0o700)
        fd = os.open(t.state / "cam1.session", os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        rc, _, err, _ = run_gate(t)
        os.close(fd)
        self.assertEqual((rc, err.strip()), (75, "ezviz-source cam1: busy"))
        self.assertFalse(t.ledger().exists())

    def test_missing_camera_file_is_config_78_no_ledger_write(self):        # G3
        t = Tree(camfile=None)
        rc, _, err, _ = run_gate(t)
        self.assertEqual((rc, err.strip()), (78, "ezviz-source cam1: config"))
        self.assertFalse(t.ledger().exists())

    def test_malformed_camera_file_is_config_78_no_ledger_write(self):
        t = Tree(camfile=GOOD + "extra=1\n")
        rc, _, _, _ = run_gate(t)
        self.assertEqual(rc, 78)
        self.assertFalse(t.ledger().exists())

    def test_attempt_on_disk_before_return(self):                            # F3 (the connect half: Task 11)
        t = Tree()
        rc, out, _, _ = run_gate(t)
        self.assertEqual((rc, out.strip(), self.evs(t)), (0, "ADMITTED", ["attempt"]))

    def test_budget_wait_refusal_under_150_ms_and_no_pyezvizapi(self):     # N5
        t = Tree()
        t.seed([rec(-300, "attempt"), rec(-299, "net_fail"), rec(-200, "attempt"), rec(-199, "net_fail"),
                rec(-100, "attempt"), rec(-99, "net_fail")])
        secs = []
        for _ in range(5):
            rc, _, err, s = run_gate(t, pyflags=("-X", "importtime"))
            secs.append(s)
            self.assertEqual(rc, 75)
            self.assertIn("ezviz-source cam1: budget_wait", err)
            self.assertNotIn("pyezvizapi", err)
            self.assertNotIn("ezviz_source.camera", err)
        self.assertLess(statistics.median(secs), 0.150)

    def test_latched_refusal(self):
        t = Tree()
        t.state.mkdir(parents=True, mode=0o700)
        (t.state / "cam1.latch").touch()
        rc, _, err, _ = run_gate(t)
        self.assertEqual((rc, err.strip()), (75, "ezviz-source cam1: latched"))

    def test_row_full_writes_latch_file_and_record_once(self):              # P9
        t = Tree()
        lines = []
        for dt in (-30000, -20000, -10000):
            lines += [rec(dt, "attempt"), rec(dt + 2, "login_ok"), rec(dt + 9, "start_timeout")]
        t.seed(lines)
        for _ in range(2):
            self.assertEqual(run_gate(t)[0], 75)
        self.assertTrue((t.state / "cam1.latch").exists())
        self.assertEqual(self.evs(t).count("latch"), 1)

    def test_synthetic_written_once_across_refusals(self):                  # H3
        t = Tree()
        t.seed([rec(-30, "attempt")])
        for _ in range(2):
            self.assertEqual(run_gate(t)[0], 75)
            time.sleep(1)
        self.assertEqual(self.evs(t), ["attempt", "net_fail"])

    def test_ledger_damaged_refuses_without_contact(self):                  # Review Focus 2, P8
        t = Tree()
        t.seed([rec(-9000, "attempt"), "garbage\n", rec(-8000, "stop")])
        rc, _, err, _ = run_gate(t)
        self.assertEqual((rc, err.strip()), (75, "ezviz-source cam1: ledger_damaged"))

    def test_attempt_write_failure_means_no_contact(self):                  # Review Focus 3
        t = Tree()
        rc, out, err, _ = run_gate(t, EZVIZ_TEST_HOOKS="enospc_append")
        self.assertEqual((rc, out, err.strip()), (75, "", "ezviz-source cam1: ledger_io"))
        self.assertNotIn("attempt", t.ledger().read_text() if t.ledger().exists() else "")

    def test_ten_concurrent_helpers_on_fresh_state(self):                   # Review Focus 4
        t = Tree()
        ps = [gate_proc(t, 2.0) for _ in range(10)]
        res = [p.communicate(timeout=30) + (p.returncode,) for p in ps]
        self.assertEqual(sum(1 for o, e, rc in res if o.strip() == "ADMITTED"), 1)
        self.assertEqual(sum(1 for o, e, rc in res if rc == 75 and e.strip() == "ezviz-source cam1: busy"), 9)
        self.assertEqual(t.state.stat().st_mode & 0o777, 0o700)
        for f in t.state.iterdir():
            self.assertEqual(f.stat().st_mode & 0o777, 0o600, f.name)

    def test_lines_carry_no_camera_value(self):
        t = Tree()
        rc, out, err, _ = run_gate(t)
        t.seed([rec(-100, "attempt"), rec(-99, "auth_fail")])
        rc2, out2, err2, _ = run_gate(t)
        for c in CANARIES:
            for s in (out, err, out2, err2, t.ledger().read_text()):
                self.assertNotIn(c, s)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run and see them fail.** `"$PY" -m unittest discover -s tests/ezviz -p 'test_gate.py' -v`
- [ ] **Step 3: Implement** `spike/ezviz/ezviz_source/gate.py`:

```python
"""The pre-contact gate (spec §4.1, D3, D18, D21, G3, N5). Stdlib only: never import pyezvizapi here.

Order: umask and state dir; session lock (busy); camera file (config, no ledger touched); under the
ledger lock: decide, then in one critical section the synthetic record, the latch, and the refusal or
the "attempt" record (fsynced before any connect, F3).
"""
import fcntl
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from . import camfile, ledger, paths, policy, signals
from . import constants as C


@dataclass
class Admitted:
    cam: camfile.Camera
    ledger_path: Path
    session_fd: int
    attempt_t: float
    attempts_in_window: int


class Refused(Exception):
    def __init__(self, cls: str, code: int, next_in=None):
        super().__init__(cls)
        self.cls, self.code, self.next_in = cls, code, next_in


def say(name: str, cls: str, *, attempt=None, next_in=None) -> None:
    line = f"ezviz-source {name}: {cls}"
    if attempt is not None:
        line += f" attempt {attempt}/{C.CAP_ATTEMPTS} in window"
    if next_in is not None:
        line += f" next allowed +{int(next_in)}s"
    sys.stderr.write(line + "\n")
    sys.stderr.flush()


def write_latch(state: Path, name: str) -> None:
    fd = os.open(state / f"{name}.latch", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    ledger._fsync_dir(state)


def _row_start(recs: list) -> float:
    """t of the last published or unlatch record (where the current latch row starts), else -inf."""
    return max((r["t"] for r in recs if r["ev"] in ("published", "unlatch")), default=float("-inf"))


def admit(name: str, now=time.time, on_attempt=None) -> Admitted:
    os.umask(0o077)
    state = paths.state_dir()
    try:
        state.mkdir(mode=0o700, parents=True, exist_ok=True)
        sfd = os.open(state / f"{name}.session", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    except OSError:
        raise Refused("ledger_io", C.EXIT_TEMP) from None
    try:
        fcntl.flock(sfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(sfd)
        raise Refused("busy", C.EXIT_TEMP) from None
    try:
        cam = camfile.load(name, paths.camera_dir())
    except camfile.CameraFileError:
        raise Refused("config", C.EXIT_CONFIG) from None
    signals.hook("pause_gate")
    lp = state / f"{name}.ledger"
    try:
        with ledger.Ledger(lp) as L:
            recs = L.records()
            t = now()
            d = policy.decide(recs, t, latch_file=(state / f"{name}.latch").exists())
            with signals.critical():
                if d.synthetic is not None:
                    L.append(d.synthetic)
                if d.latch_now:
                    write_latch(state, name)
                    L.append({"t": t, "ev": "latch", "dur": None})
                if not d.allow:
                    raise Refused(d.cls, C.EXIT_TEMP, None if d.cls == "latched" else d.next_allowed - t)
                L.append({"t": t, "ev": "attempt", "dur": None})
                if on_attempt is not None:
                    on_attempt(t, lp)                  # the caller's phase becomes P1 inside the section
            recs = L.records()
            if recs and recs[0]["t"] < t - C.TRIM_KEEP_S - 3600:
                L.trim(t, min(t - C.WINDOW_S, _row_start(recs)))   # last operation under the lock
    except ledger.LedgerDamaged:
        raise Refused("ledger_damaged", C.EXIT_TEMP) from None
    except ledger.LedgerIOError:
        raise Refused("ledger_io", C.EXIT_TEMP) from None
    return Admitted(cam, lp, sfd, t, d.attempts_in_window + 1)
```

- [ ] **Step 4: Run and see them pass.** Expected: 12 tests OK (run on 19 Nov: 12 OK).
- [ ] **Step 5: Mutation tests.** Each one, applied alone, made its test FAIL on 19 Nov:

| Mutation | Fails |
|---|---|
| drop the session lock (F4) | `test_busy_when_session_lock_held`, `test_ten_concurrent_helpers_on_fresh_state` |
| read the camera file after the decision (G3) | `test_missing_camera_file_is_config_78_no_ledger_write` |
| a heavy import in the gate (a stand-in `camera.py` that sleeps 0.3 s) (N5) | `test_budget_wait_refusal_under_150_ms_and_no_pyezvizapi` |

- [ ] **Step 6: Commit** `feat(ezviz): pre-contact gate: session lock, camera file, ledger decision, attempt (W-23 T6)`

**Checkpoint A1:** a reviewer re-reads Tasks 2–6 against spec D3, D4, D18, D21, §4.1 and §4.3, and re-runs every mutation in the tables of Tasks 3–6.

### Task 7: Streaming Annex-B reassembler

**Files:** Create `spike/ezviz/ezviz_source/annexb.py`. Test `tests/ezviz/test_annexb.py`.

**Interfaces:**
- Produces:
  ```python
  class Reassembler:
      def push(self, body: bytes) -> list[bytes]      # one library packet body -> zero or more Annex-B NAL units (each starting b"\0\0\0\1")
      def pts_seen(self) -> set[int]                 # RTP payload types seen (audio presence for item A; OD4 drops non-video)
  class AccessUnits:
      def push(self, nal: bytes) -> list[tuple[bytes, bool]]   # complete AUs as (annexb_bytes, is_irap); an AU ends when the next NAL starts a new picture
  ```
- **The logic replicates pyEzvizApi 2.0.0's HEVC branch with no decrypt step.** Implement it from these places in the 2.0.0 wheel (paths under `pyezvizapi/`):
  - length-prefix unwrap: `payloads.py` L568-586, L474-537;
  - the IDMX header at offset 8 or 9 (12 or 13 bytes): `packets.py` L225-249, L139-159;
  - RTP parse, CSRCs, extension and padding: `media/rtp.py` L422-472;
  - strip the `24 00` trailer: `packets.py` L329-342;
  - route on `0x45` descriptors, else PT 96: `payloads.py` L1117-1171, `rtp.py` L221-256;
  - skip `40 00 00 02 80 06` (NAL at offset 12): `packets.py` L297-300;
  - skip bodies starting `00 01`/`00 02`: `packets.py` L290-294;
  - FU (type 49) with the EZVIZ headerless quirk and the ts/seq continuity rule: `payloads.py` L1263-1304, `packets.py` L204-222;
  - the NAL plausibility check: `packets.py` L352-359.

  State is kept across `push` calls (the library's version is not incremental: `payloads.py` L752-895).
- **AU boundary:** a new AU starts at a VPS/SPS/PPS/AUD/prefix-SEI (types 32–35, 39) that follows a VCL NAL, or at a VCL NAL (0–31) whose `first_slice_segment_in_pic_flag` (the MSB of byte 2) is 1 and that follows a VCL NAL. `is_irap` means some VCL NAL in the AU has a type in 16–23.

- [ ] **Step 1: Write the failing tests** with synthetic packets. `tests/ezviz/fixtures.py` gains `rtp_body(pt, seq, ts, payload, marker=False, header13=False) -> bytes` (4-byte LE length + IDMX/RTP v2 header with SSRC `55 66 77 88` + payload, as `t10_offline_harness.py` L256-274 at `d5260d4`) and `fu(nal, size) -> list[bytes]` (FU type 49 fragments).

```python
def test_single_nal_passthrough(self): push(rtp_body(96,1,0,VPS)) == [b"\0\0\0\1"+VPS]
def test_fu_reassembly(self): an 5000-byte IDR NAL split into 4 FUs, seq 10..13 same ts -> one NAL equal to the original
def test_fu_seq_gap_drops_the_nal(self): seq 10, 12 -> no output for that NAL; next good NAL still emitted
def test_fu_ts_change_drops(self): ...
def test_headerless_fu_continuation(self): EZVIZ quirk: continuation without FU header, ended by RTP marker
def test_header13_variant(self): first byte 0x0D, RTP at offset 1
def test_trailer_24_00_stripped(self): header13 without extension, body ends with b"\x24\x00\x00\x08..." -> NAL without it
def test_non_video_pt_ignored(self): PT 104 -> []; pts_seen() == {104} after it too
def test_access_units_split_and_irap(self): VPS,SPS,PPS,IDR(first_slice=1),TRAIL(first_slice=1) -> 2 AUs, irap flags [True, False]
def test_two_slices_one_picture(self): IDR first_slice=1 then IDR first_slice=0 -> one AU (W-20 R2: two slices per frame)
```

- [ ] **Step 2: Run and see them fail.** `"$PY" -m unittest discover -s tests/ezviz -p 'test_annexb.py' -v`
- [ ] **Step 3: Implement `Reassembler` and `AccessUnits`.**
- [ ] **Step 4: Run and see them pass** (10 tests). The byte-for-byte check against the library runs in Task 9, once the fake camera exists.
- [ ] **Step 5: Commit** `feat(ezviz): streaming IDMX/FU to Annex-B reassembler, no decrypt (W-23 T7)`.

### Task 8: The fake camera (test infrastructure; spec item B's largest part, N10)

**Files:** Create `tests/ezviz/fakecam.py`. Test `tests/ezviz/test_fakecam.py`.

**Interfaces:**
- Produces the CLI `"$PY" tests/ezviz/fakecam.py --port 0 --code QZCNRA --stats FILE --es CLIP.h265 [--reject] [--silent-before-challenge] [--silent-after-login] [--close-after-s N] [--stall-after-s N] [--no-media] [--port-file FILE]`. It listens on 127.0.0.1, writes the bound port to `--port-file`, runs one thread per connection, and rewrites `--stats` atomically after every event as `{"connects": n, "logins_ok": n, "logins_rejected": n, "keepalives": n, "media_sessions": n}`.
- Produces `fakecam.Server(...)` with the same knobs in-process, plus `.stats` and `.close()`.
- **The wire protocol it implements**, from the pyEzvizApi 2.0.0 client side:
  - every frame has a 16-byte header: u32 BE `total_length` (header included) and three u32 fields, then the body (`framing.py` L126-155, L286-300);
  - connection 1:
    - it reads frame A: `field_4=0x5A000000`; body = a 16-byte prefix, `admin` NUL-padded to 48 bytes, then the client's 1024-bit PKCS#1 DER public key;
    - it answers R1: body = `PKCS1_v1_5(client_pub).encrypt(challenge)`, where `challenge` is 32 random bytes not ending in `\0`, followed by a 64-byte `password_seed`;
    - it reads frame B and checks the 16 bytes after the 16-byte prefix and the 32-byte user HMAC against `HMAC-MD5(key=challenge, msg=sha256(b"admin" + seed + code).hexdigest().encode())[:16]` (`authentication.py` L192-256);
    - it answers R2: `field_4` = a random auth seed; body = a 4-byte non-zero session id, or `00000000` with `--reject`;
  - connections 2–11:
    - it reads one `0x63` control frame;
    - for command 0x30000 it sends no reply and starts the media loop;
    - for every other command it replies with a bare 16-byte header;
  - media:
    - it loops the Annex-B file paced at 25 fps;
    - each NAL becomes one RTP packet if it is ≤ 1400 bytes, else FU-A type 49 fragments; PT 96, ts += 3600 per AU, the marker bit on an AU's last packet;
    - each packet is wrapped as `b"$" + bytes([0]) + u16 LE total + u32 LE len + 12-byte RTP (SSRC 55667788) + payload` (`requests.py` L1689-1725);
    - it reads and counts the 32-byte 0x30006 keepalives.
- Produces the clip: `tests/ezviz/fixtures.py: make_es(ffmpeg: str, out: Path, seconds=4)` runs `ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=25 -t 4 -c:v libx265 -x265-params keyint=50:min-keyint=50:bframes=0:repeat-headers=1 -f hevc out`. Unit tests that cannot extract ffmpeg use `fixtures.SYNTH_ES`: a tiny made-up Annex-B stream of VPS, SPS, PPS, IDR and TRAIL with dummy payloads. It is valid for the reassembler, not decodable.

- [ ] **Step 1: Write the failing tests** (they drive the **real library client** against the fake):

```python
def test_login_ok_counts_one_and_11_connects(self):  open the library stream (camera.py does not exist yet: call
    open_hcnetsdk_command_port_generated_multi_socket_stream directly with the built-in plan), read 10 packets -> stats logins_ok 1, connects 11
def test_reject_raises_login_failed(self): --reject -> PyEzvizError("HCNetSDK command-port login failed"); logins_rejected 1, connects 1
def test_wrong_code_is_rejected(self): client password "QZWRNG" -> login failed
def test_media_packets_reassemble(self): 50 packets through annexb.Reassembler -> NAL types include 32,33,34,19
def test_keepalives_counted(self): read for 11 s -> stats keepalives >= 2
```

- [ ] **Step 2: Run and see them fail.** `"$PY" -m unittest discover -s tests/ezviz -p 'test_fakecam.py' -v`
- [ ] **Step 3: Implement `fakecam.py`** (pycryptodome is in the venv). About 250 lines.
- [ ] **Step 4: Run and see them pass** (5 tests, < 30 s).
- [ ] **Step 5: Commit** `test(ezviz): loopback fake camera with the real HCNetSDK login and plan (W-23 T8)`.

**Fallback (spec item B):** if the RSA login half does not pass `test_login_ok_counts_one_and_11_connects` within one fix round, switch to boundary injection: `camera.CameraSession(..., _open=fake_open)` returns an object with `iter_packets()` and `login_session`. Record in `docs/w23-findings.md` that the login exchange is then proven only by W-20's runs, item A and S5.

### Task 9: The library boundary

**Files:** Create `spike/ezviz/ezviz_source/camera.py`. Test `tests/ezviz/test_camera.py`.

**Interfaces:**
- Consumes: `camfile.Camera`, `constants`, `annexb` (tests only), `fakecam` (tests).
- Produces:
  ```python
  def silence_library_logging() -> None          # NullHandler on "pyezvizapi", propagate False (N8)
  def build_plan(form: str, count: int)           # P5; raises ValueError for another form or count < 6
  class CameraSession:
      def __init__(self, cam: Camera, *, plan, timeout: float, on_login_ok: Callable[[], None]): ...
      def __enter__(self) -> "CameraSession"     # opens (P1); calls on_login_ok once from the factory's 2nd call when login_session is set (P2)
      def packets(self) -> Iterator[bytes]       # packet.body of iter_packets(), unbounded
      def keepalive_failed(self) -> bool         # any keepalive_events entry with sent False (E8/E14); the helper calls it once a second (N5): the property copies the whole tuple
      def __exit__(...)                          # stream.close(); idempotent (Task 11's finish() calls it again); never raises
      def __exit__(...)                          # stream.close(); never raises
      logged_in: bool
  def classify(exc: BaseException, *, logged_in: bool) -> str   # P3
  def render_seconds(plan) -> float                              # time to render every keepalive frame once (P5 measurement)
  ```
- **`camera` is the only module that imports `pyezvizapi`**, and it does so at module import time.

- [ ] **Step 1: Write the failing tests**

```python
def test_build_plan_extend_deltas(self): ka = media step keepalive_templates of build_plan("extend", 8) -> [10,16,22,28,34,40,46,52]
def test_build_plan_repeat_deltas(self): build_plan("repeat", 8) -> [10,16,22,28,34,40,40,40]
def test_other_steps_untouched(self): every non-media step equal to the built-in plan's
def test_login_ok_hook_fires_once_after_login(self): fakecam; hook records the fake's logins_ok at call time == 1 and connects == 1
def test_login_ok_hook_not_called_on_reject(self): --reject -> classify(...) == "auth_fail", hook never called
def test_classify_connect_refused_is_net_fail(self): closed port -> "net_fail"
def test_classify_challenge_timeout_is_net_fail(self): --silent-before-challenge, timeout 1.0 -> DeviceException -> "net_fail"
def test_classify_after_login_close_is_session_end(self): --close-after-s 2 -> "session_end"
def test_classify_after_login_stall_is_session_end(self): --stall-after-s 2, timeout 1.0 -> "session_end"
def test_classify_protocol_error_after_login(self): classify(PyEzvizError("interleaved frame length is invalid"), logged_in=True) == "protocol_fail"
def test_reassembler_matches_library_byte_for_byte(self):   # differential: our streaming reassembler vs the library's batch path
    collect 300 bodies from the fake; ours = b"".join(nal for b in bodies for nal in R.push(b))
    lib = session._decrypt_idmx_local_packets_to_annexb_with_codec(bodies, b"\0"*16, nalu_header_size=0) with session._decrypt_hevc_nal_prefix patched to identity (as t10_offline_harness.py L130-138)
    self.assertEqual(ours, lib[0])
def test_library_logging_silenced(self): after silence_library_logging(), logging.getLogger("pyezvizapi.client").warning("x") prints nothing to stderr
def test_render_seconds_measured(self): r = render_seconds(build_plan("extend", 4320)); print(f"evidence - render 4320 keepalives: {r:.2f}s"); self.assertLess(r, 30)
```

- [ ] **Step 2: Run and see them fail.** `"$PY" -m unittest discover -s tests/ezviz -p 'test_camera.py' -v`
- [ ] **Step 3: Implement** (P1, P2, P3, P5).
- [ ] **Step 4: Run and see them pass** (13 tests). Record the printed render time in the commit message (laptop, amd64).
- [ ] **Step 5: Mutation:** classify by string only before login (drop the `logged_in` branch). `test_classify_after_login_*` must fail. Revert.
- [ ] **Step 6: Commit** `feat(ezviz): library boundary: plan builder, login_ok hook, error classes (W-23 T9)`.

### Task 10: The ffmpeg child and the publish point

**Files:** Create `spike/ezviz/ezviz_source/output.py` and `tests/ezviz/fakeffmpeg.py`. Test `tests/ezviz/test_output.py`.

**Interfaces:**
- Produces:
  ```python
  class FfmpegExited(Exception): pass
  class Output:
      def __init__(self, ffmpeg: str, url: str, *, mode: str = TIMESTAMP_MODE, now=time.monotonic): ...   # spawns at once (P4)
      def write_au(self, au: bytes, is_irap: bool) -> None   # raises FfmpegExited on EPIPE or exited child; drops AUs until the first IRAP
      def published_due(self) -> bool                         # True once: first IRAP written and child alive PUBLISH_HOLD_S later
      def close(self) -> None                                  # close stdin, SIGTERM, wait 2 s, SIGKILL; never raises
      pid: int
  def child_argv(ffmpeg: str, url: str, mode: str) -> list[str]
  def child_env() -> dict[str, str]
  ```
- `fakeffmpeg.py` reads stdin into `/dev/null`. Its knobs come from env vars set by the tests: `FAKEFF_EXIT_AFTER_S`, `FAKEFF_IGNORE_TERM`. It writes its argv and env as JSON to `$FAKEFF_DUMP`.

- [ ] **Step 1: Write the failing tests**

```python
def test_argv_wallclock(self): child_argv("/f", "rtsp://127.0.0.1:8554/x", "wallclock") == ["/f","-hide_banner","-loglevel","error","-use_wallclock_as_timestamps","1","-f","hevc","-i","pipe:0","-c","copy","-an","-f","rtsp","-rtsp_transport","tcp","rtsp://127.0.0.1:8554/x"]
def test_env_is_path_and_ld_library_path_only(self): with EZVIZ_CHILD_LD_LIBRARY_PATH=/l and a canary var -> child_env() == {"PATH": "/usr/bin:/bin", "LD_LIBRARY_PATH": "/l"}
def test_child_gets_pdeathsig(self): spawn fakeffmpeg via Output from a parent subprocess; SIGKILL the parent -> the child is gone within 2 s
def test_no_publish_before_irap(self): write 10 non-IRAP AUs, wait 6 s -> published_due() False
def test_publish_after_5s_alive(self): IRAP at t; fake clock t+4.9 -> False; t+5.0 -> True; then False forever (once)
def test_exited_child_raises(self): FAKEFF_EXIT_AFTER_S=0.5 -> write_au after 1 s raises FfmpegExited
```

- [ ] **Step 2: Run and see them fail.** `"$PY" -m unittest discover -s tests/ezviz -p 'test_output.py' -v`
- [ ] **Step 3: Implement** (`subprocess.Popen(..., stdin=PIPE, stdout=DEVNULL, stderr=DEVNULL, env=child_env(), preexec_fn=_pdeathsig, close_fds=True)`; `_pdeathsig` calls `ctypes.CDLL(None).prctl(1, signal.SIGTERM)`).
- [ ] **Step 4: Run and see them pass** (6 tests).
- **The wrapper** `spike/bin/ezviz-source` (N4; Task 20's static test greps it):
  ```sh
  #!/bin/sh
  # go2rtc exec child (W-23 D2, D8): ezviz-source <name> <rtsp output>. Runs on the helper's own Python 3.12 (OD1/R1).
  # Python gets no LD_LIBRARY_PATH and no PYTHON* variable (-I); the saved value reaches only the ffmpeg child (D7, P4).
  EZVIZ_CHILD_LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}; export EZVIZ_CHILD_LD_LIBRARY_PATH
  unset LD_LIBRARY_PATH LD_PRELOAD
  exec "$SNAP/opt/ezviz-py/bin/python3.12" -I -B -m ezviz_source.main "$@"
  ```
- [ ] **Step 5: Mutation (no orphan session):** drop the `preexec_fn`. `test_child_gets_pdeathsig` must fail (an orphan ffmpeg outlives the helper). Pass the full environment: `test_env_is_path_and_ld_library_path_only` must fail. Revert both.
- [ ] **Step 6: Commit** `feat(ezviz): ffmpeg child with scrubbed env, pdeathsig and the 5 s publish point (W-23 T10)`.

### Task 11: The helper — phases, end records and exit (S1 rest, S14, S15)

**Files:** Create `spike/ezviz/ezviz_source/main.py`. Tests `tests/ezviz/test_helper_s1.py`, `test_helper_s14.py`, `test_helper_s15.py`, and `fixtures.Helper` (a process harness).

**Interfaces:**
- Consumes everything above. `CameraSession.__exit__` must be idempotent: `finish()` calls it again.
- Produces `main(argv)`, run as `python -I -B -m ezviz_source.main <name> <rtsp-url>`. A bad name or URL exits 64 with no record.
- **The order is binding, and it is in the code below:**
  - each phase switch (P1 in `on_attempt`, P2 after `login_ok`, P3 after `published`) happens **inside** the critical section that wrote its record (SF2);
  - exactly one end record is written, by `end()`;
  - `end()` sets `mark_ended()` first and always leaves through `finally: os._exit(code)` (SF3);
  - `finish()` turns a first SIGTERM that lands during the close into the phase's SIGTERM record.
- `fixtures.Helper(tmp, name, fake_args)` builds `SNAP`/`SNAP_DATA`/`SNAP_COMMON` trees:
  - `$SNAP/usr/lib/ffmpeg/8.0/bin/ffmpeg` is `fakeffmpeg.py`, or the real one with `real_ffmpeg=True`;
  - it starts the fake camera, writes the canary camera file and runs the helper in its own session (`setsid`);
  - it offers `.ledger()`, `.wait_ev(ev, timeout)`, `.term()`, `.kill_ffmpeg()`, `.rc` and `.elapsed`;
  - `.ledger()` and `.wait_ev` read with `ledger.parse`, which skips a torn last line. A plain `json.loads` per line crashes while a `pause_cs` hook holds a half-written record; seen on 19 Nov.

- [ ] **Step 1: Write the failing tests.** The names say the spec clause. Signals are sent on ledger events, never after a fixed sleep.

```python
# test_helper_s1.py
def test_attempt_record_on_disk_before_fake_sees_connect(self):     # F3: the fake's accept hook reads the ledger; it already holds "attempt"
def test_second_helper_while_first_holds_session_is_busy_one_login(self):  # F4: fake logins_ok == 1
def test_auth_fail_latches_and_next_helper_opens_no_socket(self):  # E2: rc 77, ledger ends auth_fail, latch; next helper rc 75 "latched"; fake connects unchanged
def test_net_fail_counts_as_attempt(self):                          # closed port -> net_fail; the next decision has attempts_in_window == 1
def test_no_marker_leaks_anywhere(self):                            # §4.5, N8: drive auth_fail, net_fail, session_end, output_end, stop;
    # 192.0.2.11 / TESTCAM-0001 / QZCNRA absent from stdout, stderr, the ledger, /proc/<helper>/cmdline, /proc/<ffmpeg>/environ (read while running)
# test_helper_s14.py
def test_sigterm_P0_writes_nothing(self):          # EZVIZ_TEST_HOOKS=pause_gate, SIGTERM in the pause -> rc 0, no ledger record
def test_sigterm_P1_is_net_fail_no_row(self):      # fake --silent-before-challenge, SIGTERM 1 s after "attempt" -> net_fail; row unchanged (K2)
def test_sigterm_P2_is_start_timeout_with_row(self):  # fake --no-media, SIGTERM 2 s after "login_ok" -> start_timeout
def test_sigterm_P3_is_stop_exit_0_within_5s(self):   # after "published": SIGTERM -> stop, rc 0, elapsed < 5 s (nit 4)
def test_J1_sigterm_within_1s_of_login_ok_silent_camera(self):  # fake --silent-after-login, library timeout 10 s (>= 6 s):
    # SIGTERM 0.5 s after "login_ok" -> start_timeout written by THIS helper (no "syn" record), rc 0, < 5 s
def test_J3_kill_ffmpeg_then_sigterm_200ms_is_stop(self):  # after "published": SIGKILL ffmpeg; +0.2 s SIGTERM -> stop
def test_process_group_sigterm_is_stop_20_of_20(self):     # 20 runs: after "published", kill -TERM -<pgid> -> stop in 20/20 (H5b)
def test_L1_two_sigterms_50ms_apart_after_published(self): # EZVIZ_TEST_HOOKS=pause_close (SF4): SIGTERM, +50 ms SIGTERM -> stop, rc 0, < 5 s, no "Traceback"
def test_SF2_sigterm_held_in_login_ok_write_is_start_timeout(self):  # pause_cs:login_ok, SIGTERM in the pause -> login_ok complete, then start_timeout by THIS helper
def test_SF3_sigterm_in_session_end_write_one_record(self):  # fake --close-after-s 1 (before publish), pause_cs:session_end, SIGTERM in the pause
    # -> exactly one end record (session_end), rc 75, no "Traceback" on stderr
def test_stall_hook_ends_by_sigalrm_within_5s(self):   # stall_close, after "published": SIGTERM -> rc == -SIGALRM, < 5 s; next decision writes syn unknown_end (E17)
# test_helper_s15.py
def test_published_written_at_publish_point_and_resets_row(self):  # two P2 ends seeded, then a published session -> the next decide() has row 0 (E6)
def test_J2_start_timeout_net_fail_start_timeout_start_timeout_latches(self):  # four real helper runs, ledger timestamps seeded 2 h apart -> latched
def test_K3_three_session_end_before_publish_latch(self):  # fake --close-after-s 2, three runs -> latched
def test_unknown_end_P2_rung_P3_fixed(self):    # SIGKILL the helper in P2 -> next decision syn unknown_end, rung 60 s; in P3 -> fixed 60 s
def test_K1_sigterm_inside_ledger_write_leaves_complete_record(self):  # pause_cs:published, SIGTERM in the pause -> published complete + stop
def test_torn_last_line_then_next_decision_and_new_line(self):  # append b'{"t":' (torn), run a helper -> classed by T-END; no joined line
def test_torn_login_ok_falls_back_to_P1(self):  # attempt + torn login_ok, no helper alive -> syn net_fail, no row entry
```

Each test uses `fixtures.Helper` and asserts the exact ledger event list. For example, the SF3 test is:
```python
    def test_SF3_sigterm_in_session_end_write_one_record(self):
        h = fixtures.Helper(self.tmp, "cam1", ["--close-after-s", "1"], hooks="pause_cs:session_end")
        h.wait_ev("login_ok", 10); h.wait_half_written(10); h.term()
        h.wait_exit(10)
        self.assertEqual([r["ev"] for r in h.ledger()], ["attempt", "login_ok", "session_end"])
        self.assertEqual(h.rc, 75); self.assertNotIn("Traceback", h.stderr)
```
`wait_half_written` polls until the ledger's last line has no trailing newline.

- [ ] **Step 2: Run and see them fail.** `flock -w 3600 /tmp/claude-1000/chim-suites.lock "$PY" -m unittest discover -s tests/ezviz -p 'test_helper_s*.py' -v`
- [ ] **Step 3: Implement** `spike/ezviz/ezviz_source/main.py`:

```python
"""ezviz-source <name> <rtsp output>: the go2rtc exec helper (spec §4, T-END in §4.3).

Phases: P0 until the "attempt" record, P1 until "login_ok", P2 until "published", P3 after it. The phase is
switched INSIDE the critical section that wrote its record (SF2), so a SIGTERM held pending by that section
is classed by the new phase. Exactly one end record is written per session, by end(); after mark_ended()
nothing can raise (SF3), and the process leaves through os._exit (D17).
"""
import os
import re
import sys
import time

from . import annexb, gate, ledger, output, paths, signals
from . import constants as C

SIG_EV = {"P1": "net_fail", "P2": "start_timeout", "P3": "stop"}      # T-END E4, E7, E13


class _SessionEnd(Exception):
    pass


class Helper:
    def __init__(self, name: str, url: str):
        self.name, self.url = name, url
        self.phase, self.attempt_t, self.lp = "P0", None, None
        self.cam, self.sess, self.out = None, None, None

    # --- records -----------------------------------------------------------------------------------------
    def _append(self, ev: str, *, dur=None) -> None:
        with ledger.Ledger(self.lp) as L:
            L.append({"t": time.time(), "ev": ev, "dur": dur})

    def on_attempt(self, t: float, lp) -> None:          # called by gate.admit inside its critical section
        self.phase, self.attempt_t, self.lp = "P1", t, lp

    def on_login_ok(self) -> None:                        # P2: the factory's 2nd call (plan P2)
        with signals.critical():
            self._append("login_ok")
            self.phase = "P2"                             # SF2: before the section can raise
        gate.say(self.name, "login_ok")
        self.out = output.Output(paths.ffmpeg(), self.url)   # ffmpeg only after login_ok (nit)

    def _published(self) -> None:
        with signals.critical():
            self._append("published")
            self.phase = "P3"                             # SF2
        gate.say(self.name, "published")

    # --- the session -------------------------------------------------------------------------------------
    def run(self):
        """Returns (ev, code) for a non-signal end; a SIGTERM raises Terminating out of here."""
        camera = None
        try:
            from . import camera                          # pyezvizapi is imported only now (N5)
            camera.silence_library_logging()
            plan = camera.build_plan(C.KEEPALIVE_FORM, C.KEEPALIVE_COUNT)
            self.sess = camera.CameraSession(self.cam, plan=plan, timeout=C.SOCKET_TIMEOUT_S,
                                             on_login_ok=self.on_login_ok)
            reasm, aus, last_ka = annexb.Reassembler(), annexb.AccessUnits(), 0.0
            with self.sess:
                for body in self.sess.packets():
                    for nal in reasm.push(body):
                        for au, irap in aus.push(nal):
                            self.out.write_au(au, irap)
                    if self.phase == "P2" and self.out.published_due():
                        self._published()
                    now = time.monotonic()
                    if now - last_ka >= 1.0:                 # N5: once a second, not per packet
                        last_ka = now
                        if self.sess.keepalive_failed():
                            raise _SessionEnd()
            raise _SessionEnd()                              # the packet iterator ended
        except output.FfmpegExited:
            signals.wait_for_sigterm(C.FFMPEG_EXIT_GRACE_S)  # a SIGTERM in this second decides (H5b)
            return "output_end", C.EXIT_TEMP
        except _SessionEnd:
            return "session_end", C.EXIT_TEMP
        except Exception as e:                               # noqa: BLE001 - classified; only its class name is printed
            sys.stderr.write(f"ezviz-source {self.name}: exception {type(e).__name__}\n")
            if camera is None:                               # the import itself failed: no camera contact
                return ("net_fail" if self.phase == "P1" else "protocol_fail"), C.EXIT_TEMP
            cls = camera.classify(e, logged_in=self.phase != "P1")       # P3: E2/E3 before, E8/E10/E14/E16 after
            return cls, (C.EXIT_AUTH if cls == "auth_fail" else C.EXIT_TEMP)

    # --- the end -----------------------------------------------------------------------------------------
    def _close(self) -> None:
        signals.hook("pause_close")                          # L1 test: widen the window for a 2nd SIGTERM
        signals.hook("stall_close")                          # H5a test: a close that never returns
        try:
            if self.sess is not None:
                self.sess.__exit__(None, None, None)         # idempotent; closes the camera sockets first (D17)
        except Exception:                                    # noqa: BLE001
            pass
        try:
            if self.out is not None:
                self.out.close()
        except Exception:                                    # noqa: BLE001
            pass

    def end(self, ev: str, code: int):
        """Write the one end record (T-END), then leave. Never returns; nothing raises after mark_ended()."""
        try:
            with signals.critical():
                signals.mark_ended()
                t = time.time()
                with ledger.Ledger(self.lp) as L:
                    L.append({"t": t, "ev": ev, "dur": round(t - self.attempt_t, 3)})
                    if ev == "auth_fail":                    # E2: the latch, in the same section (P9)
                        gate.write_latch(paths.state_dir(), self.name)
                        L.append({"t": t, "ev": "latch", "dur": None})
            gate.say(self.name, ev)
        finally:
            os._exit(code)

    def finish(self, ev: str, code: int):
        try:
            try:
                self._close()
            except signals.Terminating:                      # the first SIGTERM arrived during the close
                ev, code = SIG_EV[self.phase], C.EXIT_STOP
            self.end(ev, code)
        except signals.Terminating:                          # ...or between the close and end()'s section
            self.end(SIG_EV[self.phase], C.EXIT_STOP)


def main(argv: list) -> None:
    if len(argv) != 2 or not re.fullmatch(C.NAME_RE, argv[0]) or not argv[1].startswith("rtsp://127.0.0.1:"):
        sys.stderr.write("ezviz-source: usage: ezviz-source <name> <rtsp://127.0.0.1:...>\n")
        os._exit(C.EXIT_USAGE)
    h = Helper(*argv)
    signals.install()
    try:
        adm = gate.admit(h.name, on_attempt=h.on_attempt)
        h.cam = adm.cam
        gate.say(h.name, "attempt", attempt=adm.attempts_in_window)
        ev, code = h.run()
    except gate.Refused as r:
        gate.say(h.name, r.cls, next_in=r.next_in)
        os._exit(r.code)
    except signals.Terminating:
        if h.phase == "P0":
            os._exit(C.EXIT_STOP)                            # E1: nothing written
        ev, code = SIG_EV[h.phase], C.EXIT_STOP
    h.finish(ev, code)


if __name__ == "__main__":
    main(sys.argv[1:])
```

**Pre-checked on 19 Nov:** this exact `main.py` ran with stand-in `camera`, `output` and `annexb` modules (a scripted session, no network). 8 of 8 end-path cases passed, twice:
- P1 SIGTERM → `net_fail`;
- P2 SIGTERM → `start_timeout`;
- P3 SIGTERM → `stop` in 0.1 s;
- SF2 at `login_ok` → `start_timeout`;
- SF2 at `published` → `stop`;
- SF3 → one `session_end`, rc 75, no traceback;
- L1 with `pause_close` → `stop`, rc 0, 1.1 s;
- `stall_close` → rc −14 (SIGALRM) in 4.1 s.

The real tests above replace that harness.

- [ ] **Step 4: Run and see them pass** (5 + 11 + 7 = 23 tests; expect about 4 min, mostly the 20-run test).
- [ ] **Step 5: Mutation tests** (the spec's S14/S15 named mutations; each must fail its test, then revert):

| Mutation | Fails |
|---|---|
| a flag-only SIGTERM handler | `test_J1_…` (the alarm ends it and the next helper writes `unknown_end`) |
| no 1 s wait after an ffmpeg exit | `test_J3_…` (`output_end`) |
| no alarm | `test_stall_hook_…` (hangs past 5 s; the test's own 10 s timeout fails it) |
| **L1, helper level:** raise on every SIGTERM **and** `finish()` without its `except signals.Terminating` | `test_L1_…` (rc 1, a traceback, no end record; seen on 19 Nov). Raise-on-every-SIGTERM alone is killed in Task 5: `finish()` is a second, independent guard, so at helper level only both together fail |
| phase switched after the critical section (SF2) | `test_SF2_…` (`net_fail` after a written `login_ok`; seen on 19 Nov) |
| **SF3:** neither `mark_ended()` nor `finally: os._exit` in `end()` | `test_SF3_…` (a second record, `start_timeout`; seen on 19 Nov). Either guard alone keeps the test green |
| raise inside the critical section | `test_K1_…` |
| write `attempt` after `connect` (move the append into `on_login_ok`) | `test_attempt_record_on_disk_before_fake_sees_connect` |
| drop the session lock | `test_second_helper_…` (2 logins) |
| print the host in the `net_fail` line | `test_no_marker_leaks_anywhere` |

- [ ] **Step 6: Commit** `feat(ezviz): ezviz-source helper: phases P0-P3, T-END records, os._exit (W-23 T11; S1, S14, S15)`

**Checkpoint A2:** the reviewer runs the whole `tests/ezviz` suite and every mutation in Tasks 3–11, then reads `main.py` against T-END row by row.

### Task 12: Item A's long-session probe (tooling only; no camera contact by any worker)

**Files:**
- Create: `tests/ezviz/probe.py`, `tests/ezviz/probe-run.sh`, `tests/hub/lib-cameras.sh`
- Modify: `tests/hub/make-config.sh` (source the lib; no behaviour change)
- Test: `tests/ezviz/test_probe.py`, `tests/ezviz/probe-run.test.sh`

**Interfaces:**
- `tests/hub/lib-cameras.sh` holds make-config's `read_cameras` function verbatim (lines 68-103 of `make-config.sh` at `origin/main` `9000f91`, the nested `private` and `ipv4` helpers included): it sets `IDS`, `IPS` and `PW`, and dies with make-config's codes and words. make-config sources it. **All 157 make-config checks stay green unchanged.**
- `probe.py <state-dir> <camdir> <name> <minutes> <form> <count> <ffmpeg>`:
  - the same gate as the helper, with state in `<state-dir>`, so the D4 budget applies to probe runs across runs;
  - one `CameraSession` with `build_plan(form, count)` and the reassembler;
  - AUs go into `ffmpeg -v error -f hevc -i pipe:0 -f framemd5 <tmp>/hashes`, which keeps only hashes, never an image;
  - after `<minutes>` it closes cleanly (`stop`).
  - It prints one line: `probe <name>: end=<class> login_ok=<n> published=<0|1> session_s=<s> first_irap_s=<s> render_s=<s> keepalive_sent=<n> keepalive_failed=<n> frames=<n> decode_errors=<n> rtp_ts_monotonic=<frac> rtp_ts_step_mode=<n> rtp_ts_step_p99_dev=<n> pts_seen=<sorted list>`.
  - It deletes the hash file. No host, serial or login is printed.
- `probe-run.sh <cam1|cam2|both> <minutes> <extend|repeat>`:
  - sources `lib-cameras.sh` (the same `M7C_ENV_DIR` inputs and key-file path as make-config);
  - writes the camera files into a `mktemp -d` dir (0700, files 0600) from shell variables via `printf` (a builtin, so no argv);
  - runs `probe.py` with the venv python and the 8.0 ffmpeg extracted from the local amd64 snap file (as `tests/hub/serve.test.sh` does);
  - keeps state in `$M7C_ENV_DIR/w23-probe-state` (0700, never deleted);
  - `probe-run.sh --status` (P15, SF11) reads only that state dir and prints `probe-state <cam>: last_attempt=<iso> age_s=<n> latched=<0|1>` per camera. It reads no key file and makes no camera contact. The test: a seeded state gives the exact lines, and the env dir's key file at mode 000 does not matter;
  - removes the temp dir in an `EXIT` trap.

- [ ] **Step 1: Write the failing tests**

```python
def test_probe_against_fakecam_prints_one_line_no_marker(self): 1-minute run vs fakecam (--minutes 0.5) -> line matches the format; end=stop; login_ok=1; frames >= 600; no canary
def test_probe_respects_budget(self): seed 3 attempts -> "probe cam1: end=budget_wait" and fake connects 0
def test_rtp_ts_stats(self): fakecam ts step 3600 -> rtp_ts_step_mode=3600, monotonic=1.0
```
```bash
# probe-run.test.sh: synthetic env dir (canaries, as make-config.test.sh mkenv), a stub probe.py that dumps its argv and the camera files;
# checks: the camera files are 0600 in a 0700 dir and gone after exit; no canary in argv/env/output; "both" starts two probes; bad arg -> exit 2.
```

- [ ] **Step 2: Run and see them fail**, then **Step 3: implement**, then **Step 4: run and see them pass.** Commands: `"$PY" -m unittest discover -s tests/ezviz -p 'test_probe.py' -v`, `bash tests/ezviz/probe-run.test.sh`, `bash tests/hub/make-config.test.sh` (157 ok).
- [ ] **Step 5: Commit** `test(ezviz): item A long-session probe and its card runner; read_cameras shared (W-23 T12)`.

→ **Gate GA (Part B0) may start now**, in parallel with Tasks 13–20.

### Task 13: Generator — camera streams, preload, forced API keys (D8, D20)

**Files:**
- Modify: `spike/bin/go2rtc-config-gen.py` (docstring model steps 6–7, `main()`)
- Test: `tests/test_go2rtc_config_gen.py` (new class `TestEzvizEmission`; the existing 8 tests unchanged)

**Interfaces:**
- Produces the CLI `go2rtc-config-gen.py <baseline.in> <config.yml> <SNAP> <output.yaml> [<ezviz cameras dir>]`.
- After step 4 of the existing model:
  - **6. Cameras (D8).** List the regular files matching `^[a-z0-9_]{1,32}\.conf$` in the cameras dir, by name only and never opened. For each name: if `streams` has the name, drop it and log `WARNING operator go2rtc stream <name> replaced by the snap-owned ezviz camera`. Set `streams[name] = f"exec:{snap}/bin/ezviz-source {name} {{output}}#killsignal=15#killtimeout=5"`, plus `#starttimeout={n}` if `STARTTIMEOUT_S` ≠ 30, then `preload[name] = "video"`.
  - **7. API (D20).** Always set `api.local_auth = False` and `api.base_path = ""`. If `api.allow_paths` is a list without `/api/preload`, append it. Each change of an operator value logs `WARNING operator go2rtc.api.<key> overridden (…)` with no value.
- `STARTTIMEOUT_S = 30` is a constant in the generator. A test asserts it equals `ezviz_source.constants.STARTTIMEOUT_S` by reading both files as text (the generator runs on python3.11 and cannot import the package).

- [ ] **Step 1: Write the failing tests**

```python
def run_main5(baseline, config, cams: list[str] | None, extra_files=()) -> (rc, out, err)   # 5th arg = a temp cameras dir with empty files cams + extra_files
class TestEzvizEmission(unittest.TestCase):
    def test_stream_and_preload_per_camera(self):
        rc, out, _ = run_main5(BASELINE, None, ["cam1", "cam2"])
        self.assertEqual(out["streams"]["cam1"], f"exec:{SNAP}/bin/ezviz-source cam1 {{output}}#killsignal=15#killtimeout=5")
        self.assertEqual(out["preload"], {"cam1": "video", "cam2": "video"})
    def test_operator_cam1_dropped_redacted(self):   # N7
        rc, out, err = run_main5(BASELINE, 'go2rtc:\n  streams:\n    cam1: rtsp://admin:QZCNRA@192.0.2.11/x\n', ["cam1"])
        self.assertTrue(out["streams"]["cam1"].startswith("exec:")); self.assertIn("go2rtc stream cam1 replaced", err)
        self.assertNotIn("QZCNRA", err); self.assertNotIn("192.0.2.11", err)
    def test_operator_cam1_sub_kept(self): an operator "cam1_sub" stays as given
    def test_only_valid_camera_files_become_streams(self):   # Review Focus 5
        extra = ["cam1.conf.m7c-new", "CAM2.conf", "x.txt"]; and a directory "d.conf"
        -> streams contain cam1 only (from cam1.conf) and nothing from the extras
    def test_camera_files_never_opened(self): cam files chmod 000 -> still emitted (listing only)
    def test_no_dir_arg_is_unchanged(self): 4-arg call == the old output, no preload key
    def test_api_forced_keys(self):   # D20
        cfg = 'go2rtc:\n  api:\n    username: u\n    password: QZPASS\n    local_auth: true\n    base_path: /x\n    allow_paths: [/api/streams]\n'
        rc, out, err = run_main5(BASELINE, cfg, ["cam1"])
        self.assertEqual((out["api"]["local_auth"], out["api"]["base_path"]), (False, ""))
        self.assertIn("/api/preload", out["api"]["allow_paths"]); self.assertNotIn("QZPASS", err)
        for k in ("local_auth", "base_path", "allow_paths"): self.assertIn(f"go2rtc.api.{k} overridden", err)
    def test_no_override_no_warning(self): baseline only -> no "overridden" line
    def test_starttimeout_constant_matches_helper(self): regex both files -> equal
```

- [ ] **Step 2: Run and see them fail.** `python3 -m unittest tests.test_go2rtc_config_gen -v` (system python3.12 with PyYAML, as CI does).
- [ ] **Step 3: Implement** steps 6 and 7 and update the docstring's MODEL list.
- [ ] **Step 4: Run and see them pass** (8 + 9 = 17 tests). Also `bash tests/hub/make-config.test.sh` (157 ok; its generator cross-check uses the 4-argument form).
- [ ] **Step 5: Mutation:** emit the streams **before** the operator merge. `test_operator_cam1_dropped_redacted` must fail. Revert.
- [ ] **Step 6: Commit** `feat(go2rtc-config): snap-owned ezviz streams with preload; forced API keys for the re-arm (W-23 T13; D8, D20)`.

### Task 14: The preload re-arm loop and `go2rtc-run` (D19)

**Files:**
- Create: `spike/ezviz/ezviz_source/rearm.py`, `spike/bin/ezviz-rearm`
- Modify: `spike/bin/go2rtc-run`
- Test: `tests/ezviz/test_rearm.py`, `tests/go2rtc-run.test.sh`

**Interfaces:**
- Produces in `rearm.py`:
  ```python
  def names(camera_dir: Path) -> list[str]        # same filter as the generator (Review Focus 5)
  class Api:
      def __init__(self, base: str = "http://127.0.0.1:1984", *, timeout: float = 2 * STARTTIMEOUT_S + 15): ...
      def get(self) -> set[str] | None             # None on any error, timeout or non-200; sets .refused on 401/403/404
      def put(self, name: str) -> bool             # PUT /api/preload?src=<name>&video; True on 200
  def run_round(api: Api, wanted: list[str], state: dict[str, str], log: Callable[[str], None]) -> None
  def main(argv: list[str]) -> int                 # loop: --first-delay 30 --period 30 (defaults); --list: one GET, prints "preload: cam1,cam2" | "preload: unreachable" | "preload: api_refused"
  ```
- `run_round`:
  - `got = api.get()`; on `None` return, sending nothing. On `api.refused`, log `ezviz-rearm: api_refused` once per state change.
  - For each name in `wanted` not in `got`: `ok = api.put(name)` (sequential, so at most one request is ever in flight); log `ezviz-rearm <name>: armed` or `… refused` only when the name's state changes.
  - For names in `got`: state `armed` (log on change).
- The base URL comes from `EZVIZ_REARM_API` (default above), so S2's fault proxy can sit in between. It is not a secret.
- `spike/bin/ezviz-rearm`: `exec "$SNAP/opt/ezviz-py/bin/python3.12" -I -B -m ezviz_source.rearm "$@"`.
- `go2rtc-run`:
  - pass `"$SNAP_DATA/ezviz/cameras"` as the generator's 5th argument;
  - after `: > "$SNAP_DATA/go2rtc-logs/current"`, start `"$SNAP/bin/ezviz-rearm" > >(exec tee -a "$SNAP_DATA/go2rtc-logs/current") 2>&1 &`;
  - then the unchanged `exec` of go2rtc (spike `go2rtc-run:32-33`, nit N4).

- [ ] **Step 1: Write the failing tests** (a stdlib `ThreadingHTTPServer` fake API records every request with its start and end times):

```python
def test_get_failure_skips_round_no_put(self): fake GET -> 500 -> no PUT; same for a GET that sleeps past a 1 s test timeout (Api(timeout=1) only in THIS unit test)
def test_put_only_names_not_listed(self): GET {"cam1": {...}} with wanted [cam1, cam2] -> exactly one PUT, src=cam2&video
def test_put_query_is_src_and_video(self): path "/api/preload?src=cam2&video"
def test_one_request_in_flight(self): PUT handler sleeps 2 s, two names missing -> requests never overlap (max concurrency 1)
def test_logs_on_state_change_only(self): three rounds, same state -> one "armed" line per name
def test_api_refused_logged(self): GET 401 -> "ezviz-rearm: api_refused", no PUT
def test_default_timeout_is_75(self): Api().timeout == 75
def test_names_ignore_odd_files(self): Review Focus 5 (same set as Task 13)
def test_list_mode_prints_names_only(self): --list -> "preload: cam1,cam2"
```
```bash
# tests/go2rtc-run.test.sh: stub $SNAP tree (python3.11 stub records argv; ezviz-rearm stub writes a marker line; go2rtc stub prints and exits)
# checks: generator got 5 args with $SNAP_DATA/ezviz/cameras last; ezviz-rearm started before go2rtc exec; its line lands in go2rtc-logs/current; go2rtc is exec'd (same PID as the script).
```

- [ ] **Step 2: Run and see them fail.** `"$PY" -m unittest discover -s tests/ezviz -p 'test_rearm.py' -v`; `bash tests/go2rtc-run.test.sh`
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and see them pass** (9 tests; the shell test about 5 checks).
- [ ] **Step 5: Mutations:** treat a failed GET as "nothing listed" → `test_get_failure_…` must fail; PUT names in threads → `test_one_request_in_flight` must fail.
- [ ] **Step 6: Commit** `feat(ezviz): preload re-arm loop in the go2rtc unit (W-23 T14; D19)`.

### Task 15: S2 end to end on the laptop (go2rtc 1.9.14, ffmpeg 8.0, fake camera)

**Files:** Create `tests/ezviz/serve-ezviz.test.sh` and `tests/ezviz/faultproxy.py`.

**Interfaces:**
- Consumes: the local amd64 file `~/.cache/frigate-m7c-evidence/amd64/frigate_0.18.2_amd64.snap` and its sha (as `tests/hub/serve.test.sh`); it SKIPs without them. Also the venv, `fakecam.py`, the generator, `go2rtc-run`'s rearm line, and `make_es`.
- The fake `$SNAP` tree holds:
  - `bin/ezviz-source` and `bin/ezviz-rearm`, the real wrappers;
  - `opt/ezviz-py`, a symlink to the venv dir, so `bin/python3.12` and `ezviz_source.pth` resolve;
  - `usr/lib/ffmpeg/8.0/bin/ffmpeg`, extracted.
- `faultproxy.py --listen PORT --upstream PORT --fail-next-get N --hold-put-s S --log FILE` is a stdlib HTTP forwarder that logs every request with its timestamps.
- go2rtc runs in its own process group under `timeout` (as `serve.test.sh`), with test ports for RTSP, WebRTC and the API (rewritten after generation, as there). `SNAP`, `SNAP_DATA` and `SNAP_COMMON` are exported for go2rtc so they reach its exec children.

- [ ] **Step 1: Write the test** (each check is one `check` line; the S2 clause is in its name):

| # | Check (S2 clause) |
|---|---|
| 1 | `cam1`: an ffmpeg consumer decodes ≥ 250 frames in 10 s, with 0 decode errors |
| 2 | kill -9 go2rtc and restart it: the fake sees exactly 1 new login once the budget allows and 0 during the `budget_wait` (ledger: `stop` from Pdeathsig, then refusals print `budget_wait`) |
| 3 | `preload`: remove and re-add the only consumer → 0 new logins (F2) |
| 4 | a go2rtc stop (SIGTERM to go2rtc) → the helper's ledger ends `stop`, i.e. a SIGTERM, not a SIGKILL (F1) |
| 5 | an operator `cam1` in `config.yml` is dropped with the redacted warning; 1 helper, 1 login (N7) |
| 6 | re-arm (G1): start while `cam1` is in `budget_wait` (seed 3 attempts, the oldest at now − 3600 + 90) → the start-time preload fails; `GET /api/preload` lists `cam1` within 90 + 30 + 30 s; consumer remove/re-add → 0 new logins |
| 6m | the mutation of 6: start go2rtc without the rearm line → the re-add costs a login (the check must FAIL under the mutation; run with `W23_MUTATE=no_rearm` and expect the inverted verdict, as `serve.test.sh` does for its reverse mutation) |
| 7 | a clean go2rtc restart after a 70 s published session → exactly 1 new login, and `login_ok` within 10 s of the restart (no 60 s gap, E13) |
| 8a | fault proxy, production timeouts: one failed GET while `cam1`'s preload is registered and no other consumer exists → no PUT that round; 0 `stop` records; 0 extra logins (H1a) |
| 8b | fault proxy holds one PUT open 40 s → no second request reaches the proxy until it answers (H1b) |
| 9 | API override config (`username`/`password`, `local_auth: true`, `allow_paths` without `/api/preload`, `base_path: /x`) → still re-arms; one redacted warning per overridden key (H2) |
| 9m | the mutation of 9: `W23_MUTATE=no_api_override` (the generator skips D20's overrides) → `ezviz-rearm: api_refused` and no re-arm; the check must FAIL under the mutation (inverted verdict) *(N7)* |
| 10 | both cameras (two fake instances) at once: `cam1` and `cam2` each ≥ 250 frames in 10 s, 1 login each |

- [ ] **Step 2: Run and see it fail** (before Tasks 13–14 are merged into the worktree it cannot pass; if they already are, run it with `W23_MUTATE=no_rearm` and see check 6 fail).
  Run: `flock -w 3600 /tmp/claude-1000/chim-suites.lock bash tests/ezviz/serve-ezviz.test.sh`
- [ ] **Step 3: Fix what the test finds** in Tasks 9–14's code; there is no new production code here.
- [ ] **Step 4: Run and see it pass.** Expect about 10 min. Record `ok` counts and the frame counts in `docs/w23-findings.md` §S2.
- [ ] **Step 5: Commit** `test(ezviz): S2 end to end with go2rtc 1.9.14 and the fake camera (W-23 T15)`.

**Checkpoint A3:** a reviewer re-runs S2 and reads its evidence lines.

### Task 16: Configure hook (unlatch, disk floor) and the disk guard app (D13, §4.2)

**Files:**
- Create: `spike/ezviz/ezviz_source/unlatch.py`, `spike/bin/disk-guard`
- Modify: `snap/hooks/configure` (two blocks before `# Apply live:`)
- Test: `tests/ezviz/test_unlatch.py`, `tests/disk-guard.test.sh`, `tests/configure-ezviz.test.sh`

**Interfaces:**
- `unlatch.run(cfg) -> int`: `cfg` is the `ezviz` map from `snapctl get -d ezviz`. For each valid name whose `unlatch` is an integer and differs from `<name>.unlatch-seen`, inside the ledger lock:
  - if the camera is latched (the latch file, **or the ledger alone**, N3), remove the file if present and append `unlatch`;
  - write the seen-file (0600);
  - print `configure: ezviz <name> unlatched` or `… not latched`.
- *Why the seen-file:* the hook runs on **every** `snap set`, so a later `snap set frigate disk-floor-gib=…` must not clear a new latch with the old value.
- The configure hook validates `disk-floor-gib` (an integer 1–10000) and runs the unlatch.
- `disk-guard` (POSIX sh, timer app):
  - below the floor (default 20 GiB) and with `frigate.frigate` active → `snapctl stop --disable frigate.frigate` and one line;
  - when the free space cannot be read → exit 1, and nothing is stopped.

- [ ] **Step 1: Write the failing tests:**

```python
import _path
import json
import os
import time
import unittest
from unittest import mock

from fixtures import Tree
from ezviz_source import policy, unlatch

NOW = time.time()


def rec(dt, ev):
    return json.dumps({"t": NOW + dt, "ev": ev, "dur": None}) + "\n"


def row_full():
    out = []
    for dt in (-30000, -20000, -10000):
        out += [rec(dt, "attempt"), rec(dt + 2, "login_ok"), rec(dt + 9, "session_end")]
    return out


class TestUnlatch(unittest.TestCase):
    def setUp(self):
        self.t = Tree()
        self.env = mock.patch.dict(os.environ, {"SNAP_DATA": str(self.t.data), "SNAP_COMMON": str(self.t.common)})
        self.env.start()
        self.t.seed(row_full())
        (self.t.state / "cam1.latch").touch()

    def tearDown(self):
        self.env.stop()

    def evs(self):
        return [json.loads(x)["ev"] for x in self.t.ledger().read_text().splitlines()]

    def run_unlatch(self, cfg):
        with mock.patch("sys.stdout.write") as w:
            unlatch.run(cfg)
        return "".join(c.args[0] for c in w.call_args_list)

    def test_unlatch_removes_latch_appends_record_and_seen(self):
        out = self.run_unlatch({"cam1": {"unlatch": 1794000000}})
        self.assertEqual(out, "configure: ezviz cam1 unlatched\n")
        self.assertFalse((self.t.state / "cam1.latch").exists())
        self.assertEqual(self.evs()[-1], "unlatch")
        self.assertEqual((self.t.state / "cam1.unlatch-seen").read_text(), "1794000000\n")

    def test_same_value_twice_unlatches_once(self):
        self.run_unlatch({"cam1": {"unlatch": 1794000000}})
        self.assertEqual(self.run_unlatch({"cam1": {"unlatch": 1794000000}}), "")
        self.assertEqual(self.evs().count("unlatch"), 1)

    def test_later_set_of_other_key_does_not_unlatch_new_latch(self):
        self.run_unlatch({"cam1": {"unlatch": 1794000000}})
        (self.t.state / "cam1.latch").touch()                       # latched again later
        self.run_unlatch({"cam1": {"unlatch": 1794000000}})          # configure runs for another key
        self.assertTrue((self.t.state / "cam1.latch").exists())

    def test_ledger_only_latch_is_cleared(self):                     # N3
        (self.t.state / "cam1.latch").unlink()
        self.assertEqual(self.run_unlatch({"cam1": {"unlatch": 1}}), "configure: ezviz cam1 unlatched\n")
        self.assertEqual(policy.decide([json.loads(x) for x in self.t.ledger().read_text().splitlines()],
                                       time.time() + 7200, latch_file=False).cls, "ok")

    def test_not_latched_prints_and_records_seen(self):
        (self.t.state / "cam1.latch").unlink()
        self.t.seed([rec(-100, "attempt"), rec(-90, "net_fail")])
        self.assertEqual(self.run_unlatch({"cam1": {"unlatch": 5}}), "configure: ezviz cam1 not latched\n")
        self.assertTrue((self.t.state / "cam1.unlatch-seen").exists())

    def test_bad_value_ignored(self):
        self.assertEqual(self.run_unlatch({"cam1": {"unlatch": "x"}}), "configure: ezviz cam1 ignored (not an integer)\n")
        self.assertTrue((self.t.state / "cam1.latch").exists())

    def test_policy_after_unlatch_allows_when_budget_does(self):    # P6
        self.run_unlatch({"cam1": {"unlatch": 7}})
        recs = [json.loads(x) for x in self.t.ledger().read_text().splitlines()]
        self.assertTrue(policy.decide(recs, time.time() + 1, latch_file=False).allow)


if __name__ == "__main__":
    unittest.main()
```
```bash
#!/usr/bin/env bash
# Hermetic test of spike/bin/disk-guard (W-23 D13): stub snapctl and df on PATH. Run: bash tests/disk-guard.test.sh [sh|dash]
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SHELL_UNDER_TEST="${1:-sh}"; FAILS=0; SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; FAILS=$((FAILS+1)); fi; }
# case NAME FREE_GIB FLOOR(or "") FRIGATE_STATE [DF_FAILS]
case_() {
  local free=$2 floor=$3 state=$4 dffail=${5:-0} d="$SB/$1"; mkdir -p "$d/bin"
  cat > "$d/bin/snapctl" <<EOF
#!/bin/sh
echo "\$*" >> "$d/calls"
case "\$1 \$2" in
  "get disk-floor-gib") [ -n "$floor" ] && echo "$floor"; exit 0 ;;
  "services frigate.frigate") printf 'Service          Startup  Current  Notes\nfrigate.frigate  enabled  %s  -\n' "$state" ;;
esac
EOF
  cat > "$d/bin/df" <<EOF
#!/bin/sh
[ "$dffail" = 1 ] && exit 1
printf 'Filesystem 1-blocks Used Available Capacity Mounted on\n/dev/x 1 1 %s 50%% /\n' "\$(( $free * 1073741824 ))"
EOF
  chmod +x "$d/bin/snapctl" "$d/bin/df"; : > "$d/calls"
  env PATH="$d/bin:$PATH" SNAP_COMMON="$d/common" "$SHELL_UNDER_TEST" spike/bin/disk-guard > "$d/out" 2>&1; echo $? > "$d/rc"
}
stops() { grep -c '^stop --disable frigate.frigate$' "$SB/$1/calls"; }
case_ a 19 "" active;  check "19 GiB, floor default 20, active: stop once" 1 "$(stops a)"
check "19 GiB: one line naming 19 and 20" "disk-guard: free 19 GiB below floor 20 GiB: stopped and disabled frigate.frigate" "$(cat "$SB/a/out")"
case_ b 21 "" active;  check "21 GiB: no stop" 0 "$(stops b)"; check "21 GiB: no line" "" "$(cat "$SB/b/out")"
case_ c 25 30 active;  check "25 GiB, floor 30: stop" 1 "$(stops c)"
case_ d 10 "" inactive; check "10 GiB, frigate inactive: no stop" 0 "$(stops d)"; check "inactive: no line" "" "$(cat "$SB/d/out")"
case_ e 10 "" active 1; check "df fails: exit 1" 1 "$(cat "$SB/e/rc")"; check "df fails: no stop" 0 "$(stops e)"
check "df fails: says so" "disk-guard: cannot read free space" "$(cat "$SB/e/out")"
case_ f 10 abc active; check "floor abc: exit 1, no stop" "1 0" "$(cat "$SB/f/rc") $(stops f)"
[ "$FAILS" = 0 ] && echo "disk-guard.test: all ok" || echo "disk-guard.test: FAILURES"
exit "$FAILS"
```
```bash
#!/usr/bin/env bash
# Hermetic test of the W-23 additions to snap/hooks/configure: disk-floor-gib validation and the ezviz unlatch.
# Stub snapctl on PATH; $SNAP/opt/ezviz-py is a throwaway venv (no pip, no wheels) whose .pth points at spike/ezviz,
# so the hook's `python3.12 -I -B -m ezviz_source.unlatch` runs the real module. Run: bash tests/configure-ezviz.test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD; FAILS=0; SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; FAILS=$((FAILS+1)); fi; }
python3 -m venv --without-pip "$SB/venv" >/dev/null || { echo "SKIP - configure-ezviz.test: python3 -m venv unavailable"; exit 0; }
[ -x "$SB/venv/bin/python3.12" ] || ln -s "$(readlink -f "$SB/venv/bin/python3")" "$SB/venv/bin/python3.12"
"$SB/venv/bin/python3" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])' | { read -r sp; echo "$REPO/spike/ezviz" > "$sp/ezviz_source.pth"; }
mkdir -p "$SB/bin"
cat > "$SB/bin/snapctl" <<'EOF'
#!/bin/sh
echo "$*" >> "$CFG_LOG"
case "$*" in
  "get -d ezviz") printf '%s\n' "${CFG_EZVIZ:-{\}}" ;;
  "get disk-floor-gib") [ -n "${CFG_FLOOR:-}" ] && echo "$CFG_FLOOR"; exit 0 ;;
  "get ports.https") [ -n "${CFG_PORTS:-}" ] && echo "$CFG_PORTS"; exit 0 ;;
  get\ *) exit 0 ;;
esac
EOF
chmod +x "$SB/bin/snapctl"
run() {  # run NAME [env...]: one hook run with a fresh $SNAP/$SNAP_COMMON
  local n=$1; shift; local c="$SB/$n"; mkdir -p "$c/snap/opt" "$c/common/ezviz/state" "$c/data"
  ln -s "$SB/venv" "$c/snap/opt/ezviz-py"; : > "$c/log"; [ -n "${PRE:-}" ] && eval "$PRE"
  env PATH="$SB/bin:$PATH" SNAP="$c/snap" SNAP_COMMON="$c/common" SNAP_DATA="$c/data" CFG_LOG="$c/log" "$@" \
    sh snap/hooks/configure > "$c/out" 2>&1; echo $? > "$c/rc"
}
rc() { cat "$SB/$1/rc"; }; out() { cat "$SB/$1/out"; }
run f1 CFG_FLOOR=abc;   check "disk-floor-gib=abc: exit 1" 1 "$(rc f1)"; check "says integer 1-10000" 1 "$(out f1 | grep -c 'disk-floor-gib must be an integer 1-10000')"
run f2 CFG_FLOOR=0;     check "disk-floor-gib=0: exit 1" 1 "$(rc f2)"
run f3 CFG_FLOOR=10001; check "disk-floor-gib=10001: exit 1" 1 "$(rc f3)"
run f4 CFG_FLOOR=20;    check "disk-floor-gib=20: exit 0" 0 "$(rc f4)"
run f5;                 check "unset: exit 0" 0 "$(rc f5)"
# shellcheck disable=SC2016  # expanded by eval inside run()
PRE='printf "{\"t\":1,\"ev\":\"attempt\",\"dur\":null}\n{\"t\":2,\"ev\":\"auth_fail\",\"dur\":null}\n{\"t\":2,\"ev\":\"latch\",\"dur\":null}\n" > "$c/common/ezviz/state/cam1.ledger"; : > "$c/common/ezviz/state/cam1.latch"' \
  run u1 CFG_EZVIZ='{"ezviz":{"cam1":{"unlatch":1794000000}}}'
check "unlatch: exit 0" 0 "$(rc u1)"; check "unlatch: says so" "configure: ezviz cam1 unlatched" "$(out u1)"
check "unlatch: latch file gone" 0 "$(find "$SB/u1/common/ezviz/state" -name cam1.latch | wc -l)"
check "unlatch: record appended" unlatch "$(tail -n 1 "$SB/u1/common/ezviz/state/cam1.ledger" | sed 's/.*"ev":"\([a-z_]*\)".*/\1/')"
check "unlatch: nginx and certsync still restarted" 1 "$(grep -c '^restart frigate.nginx frigate.certsync$' "$SB/u1/log")"
PRE='rm -rf "$c/common/ezviz"' run u2 CFG_EZVIZ='{"ezviz":{"cam1":{"unlatch":5}}}'
check "no state dir: exit 0, silent" "0 " "$(rc u2) $(out u2)"
run p1 CFG_PORTS=5000; check "existing checks unaffected: ports.https=5000 still refused" 1 "$(rc p1)"
[ "$FAILS" = 0 ] && echo "configure-ezviz.test: all ok" || echo "configure-ezviz.test: FAILURES"
exit "$FAILS"
```

- [ ] **Step 2: Run and see them fail:** `"$PY" -m unittest discover -s tests/ezviz -p 'test_unlatch.py' -v`; `bash tests/disk-guard.test.sh`; `bash tests/configure-ezviz.test.sh`
- [ ] **Step 3: Implement.** `spike/ezviz/ezviz_source/unlatch.py`:

```python
"""The configure hook's unlatch (spec §4.2; plan P6, P9, N3). Stdlib only.

`sudo snap set frigate ezviz.<name>.unlatch=$(date +%s)` -> for every valid name whose value is an integer
and differs from <name>.unlatch-seen: under the ledger lock, if the camera is latched (the latch file, or
the ledger by itself), remove the file and append "unlatch". The seen-file stops a later, unrelated
`snap set` from unlatching a NEW latch with the same old value.
"""
import json
import os
import re
import subprocess
import sys
import time

from . import constants as C
from . import ledger, paths, policy


def _snapctl_get() -> dict:
    out = subprocess.run(["snapctl", "get", "-d", "ezviz"], capture_output=True, text=True)
    if out.returncode != 0:
        return {}
    try:
        return (json.loads(out.stdout) or {}).get("ezviz") or {}
    except ValueError:
        return {}


def _say(msg: str) -> None:
    sys.stdout.write("configure: ezviz " + msg + "\n")


def run(cfg: dict, now=time.time) -> int:
    state = paths.state_dir()
    if not state.is_dir():
        return 0
    for name in sorted(cfg):
        val = (cfg.get(name) or {}).get("unlatch") if isinstance(cfg.get(name), dict) else None
        if val is None or not re.fullmatch(C.NAME_RE, name):
            continue
        if isinstance(val, bool) or not isinstance(val, int):
            _say(f"{name} ignored (not an integer)")
            continue
        seen = state / f"{name}.unlatch-seen"
        try:
            if seen.read_text().strip() == str(val):
                continue
        except FileNotFoundError:
            pass
        latch = state / f"{name}.latch"
        with ledger.Ledger(state / f"{name}.ledger") as L:
            latched = latch.exists() or policy.decide(L.records(), now(), latch_file=False).cls == "latched"
            if latched:
                if latch.exists():
                    latch.unlink()
                    ledger._fsync_dir(state)
                L.append({"t": now(), "ev": "unlatch", "dur": None})
        fd = os.open(seen, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, f"{val}\n".encode())
            os.fsync(fd)
        finally:
            os.close(fd)
        _say(f"{name} unlatched" if latched else f"{name} not latched")
    return 0


def main() -> int:
    os.umask(0o077)
    try:
        return run(_snapctl_get())
    except (ledger.LedgerDamaged, ledger.LedgerIOError) as e:
        _say(f"unlatch failed ({type(e).__name__})")
        return 1


if __name__ == "__main__":
    sys.exit(main())
```
`spike/bin/disk-guard`:
```sh
#!/bin/sh
# W-23 D13: the hub-side disk floor guard. A oneshot timer app (every 10 min). Below the floor
# (snap set frigate disk-floor-gib=N, default 20) it stops AND disables frigate.frigate once and logs one line.
# It never stops anything when it cannot read the free space. No plugs: statvfs of $SNAP_COMMON and snapctl only.
F=$(snapctl get disk-floor-gib 2>/dev/null) || F=""
[ -n "$F" ] || F=20
case "$F" in *[!0-9]*) echo "disk-guard: disk-floor-gib is not an integer; nothing done"; exit 1 ;; esac
free=$(df -P -B1 "$SNAP_COMMON/media/frigate" 2>/dev/null | awk 'NR == 2 { print $4 }')
case "$free" in ''|*[!0-9]*) echo "disk-guard: cannot read free space"; exit 1 ;; esac
floor=$((F * 1073741824))
[ "$free" -lt "$floor" ] || exit 0
snapctl services frigate.frigate 2>/dev/null | awk '$1 == "frigate.frigate" { print $3 }' | grep -qx active || exit 0
snapctl stop --disable frigate.frigate
echo "disk-guard: free $((free / 1073741824)) GiB below floor $F GiB: stopped and disabled frigate.frigate"
```
`snap/hooks/configure`, inserted before `# Apply live: nginx …`:
```sh
# W-23 D13: the disk guard's floor in GiB (default 20 when unset).
G=$(snapctl get disk-floor-gib) || G=""
[ -z "$G" ] || { case "$G" in *[!0-9]*) fail "disk-floor-gib must be an integer 1-10000";; esac
                 [ "$G" -ge 1 ] && [ "$G" -le 10000 ] || fail "disk-floor-gib must be an integer 1-10000"; }

# W-23 §4.2 / plan P6: clear a camera's latch on purpose: snap set frigate ezviz.<name>.unlatch=$(date +%s).
# It acts once per new value (a seen-file), so a later, unrelated snap set never clears a new latch.
"$SNAP/opt/ezviz-py/bin/python3.12" -I -B -m ezviz_source.unlatch || fail "ezviz unlatch failed"
```

- [ ] **Step 4: Run and see them pass.** Run on 19 Nov with this code:
  - `test_unlatch`: 7 OK;
  - `disk-guard.test.sh`: 11 ok, under both `sh` and `dash`;
  - `configure-ezviz.test.sh`: 13 ok;
  - shellcheck clean.

  `bash tests/pre-refresh.test.sh` must stay green.
- [ ] **Step 5: Mutations.** Each made its test FAIL on 19 Nov:
  - no seen-file check → `test_later_set_of_other_key_does_not_unlatch_new_latch`;
  - only the latch file (N3) → `test_ledger_only_latch_is_cleared`;
  - the unlatch line dropped from the hook → `configure-ezviz.test.sh` ("unlatch: says so", "latch file gone", "record appended");
  - stopping without the active check → `disk-guard.test.sh` (4 checks).
- [ ] **Step 6: Commit** `feat: disk guard timer app and configure-hook unlatch (W-23 T16; D13, §4.2, P6)`

### Task 17: `frigate.ezviz-check` (N9)

**Files:** Create `spike/ezviz/ezviz_source/check.py` and `spike/bin/ezviz-check`. Test `tests/ezviz/test_check.py`.

**Interfaces:**
- `check.main(argv) -> int` prints exactly one line, `ezviz-check <name>: ok` or `ezviz-check <name>: <cls>`, where `cls` is one of `missing|owner|mode|shape` (from `camfile`), `statedir`, `ledger_damaged` (P8, N2) or `latched`.
- Exit 0 on `ok`, 1 otherwise, 2 for a bad name.
- It contacts no camera and imports no pyezvizapi.
- `spike/bin/ezviz-check` is `#!/bin/sh` + `exec "$SNAP/opt/ezviz-py/bin/python3.12" -I -B -m ezviz_source.check "$@"`.

- [ ] **Step 1: Write the failing tests:**

```python
import _path
import json
import os
import subprocess
import sys
import time
import unittest

from fixtures import CANARIES, GOOD, Tree

NOW = time.time()


def rec(dt, ev):
    return json.dumps({"t": NOW + dt, "ev": ev, "dur": None}) + "\n"


class TestCheck(unittest.TestCase):
    def run_check(self, t, name="cam1"):
        p = subprocess.run([sys.executable, "-c", "import sys; from ezviz_source import check; "
                            "print(sorted(m for m in sys.modules if 'pyezvizapi' in m) or '', file=sys.stderr); "
                            "sys.exit(check.main(sys.argv[1:]))", name],
                           env=t.env(), capture_output=True, text=True)
        return p.returncode, p.stdout.strip(), p.stderr.strip()

    def ready(self, camfile=GOOD, mode=0o600):
        t = Tree(camfile=camfile, mode=mode)
        t.state.mkdir(parents=True, mode=0o700)
        return t

    def test_ok(self):
        self.assertEqual(self.run_check(self.ready()), (0, "ezviz-check cam1: ok", ""))

    def test_missing(self):
        self.assertEqual(self.run_check(self.ready(camfile=None))[:2], (1, "ezviz-check cam1: missing"))

    def test_mode(self):
        self.assertEqual(self.run_check(self.ready(mode=0o644))[:2], (1, "ezviz-check cam1: mode"))

    def test_shape(self):
        self.assertEqual(self.run_check(self.ready(camfile=GOOD.replace("8000", "x")))[:2], (1, "ezviz-check cam1: shape"))

    def test_statedir(self):
        t = Tree()
        self.assertEqual(self.run_check(t)[:2], (1, "ezviz-check cam1: statedir"))
        t.state.mkdir(parents=True, mode=0o755)
        os.chmod(t.state, 0o755)
        self.assertEqual(self.run_check(t)[:2], (1, "ezviz-check cam1: statedir"))

    def test_latched_and_damaged(self):
        t = self.ready()
        (t.state / "cam1.latch").touch()
        self.assertEqual(self.run_check(t)[:2], (1, "ezviz-check cam1: latched"))
        (t.state / "cam1.latch").unlink()
        t.ledger().write_text(rec(-10, "attempt") + "garbage\n" + rec(-5, "stop"))
        self.assertEqual(self.run_check(t)[:2], (1, "ezviz-check cam1: ledger_damaged"))

    def test_bad_name_is_usage(self):
        self.assertEqual(self.run_check(self.ready(), name="../x")[0], 2)

    def test_no_canary_and_no_pyezvizapi(self):
        rc, out, err = self.run_check(self.ready(camfile=GOOD.replace("8000", "x")))
        for c in CANARIES:
            self.assertNotIn(c, out + err)
        self.assertEqual(err, "")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Steps 2–4:** run (`"$PY" -m unittest discover -s tests/ezviz -p 'test_check.py' -v`) → fail → implement → pass. Expected: 8 OK (run on 19 Nov: 8 OK). `spike/ezviz/ezviz_source/check.py`:

```python
"""frigate.ezviz-check <name> (spec §6.1, N9; plan N2). Contacts no camera; prints one fixed-form line."""
import re
import stat
import sys
import time

from . import camfile, ledger, paths, policy
from . import constants as C


def check(name: str) -> str:
    try:
        camfile.load(name, paths.camera_dir())
    except camfile.CameraFileError as e:
        return e.cls
    state = paths.state_dir()
    try:
        st = state.lstat()
    except FileNotFoundError:
        return "statedir"
    if not stat.S_ISDIR(st.st_mode) or stat.S_IMODE(st.st_mode) != 0o700:
        return "statedir"
    lp = state / f"{name}.ledger"
    try:
        recs = ledger.parse(lp.read_bytes()) if lp.exists() else []
    except ledger.LedgerDamaged:
        return "ledger_damaged"
    latch = (state / f"{name}.latch").exists()
    if policy.decide(recs, time.time(), latch_file=latch).cls == "latched":
        return "latched"
    return "ok"


def main(argv: list) -> int:
    if len(argv) != 1 or not re.fullmatch(C.NAME_RE, argv[0]):
        sys.stderr.write("usage: ezviz-check <name>\n")
        return 2
    cls = check(argv[0])
    print(f"ezviz-check {argv[0]}: {cls}")
    return 0 if cls == "ok" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 5: Commit** `feat(ezviz): ezviz-check app (W-23 T17; N9)`

### Task 18: make-config `ezviz` mode and parameterised retention (§6, F5, P10)

**Files:**
- Modify: `tests/hub/make-config.sh`, `tests/hub/make-config.test.sh`, `tests/hub/fixtures/make-config-responder.sh`

**Interfaces:**
- `M7C_SOURCE=ezviz`:
  - reads cameras as the camera mode does (`read_cameras`);
  - requires `frigate.frigate` **and** `frigate.go2rtc` inactive (exit 4, P10);
  - builds `config.yml` per spec §6.3: cam1 and cam2 each have one input `rtsp://127.0.0.1:8554/<cam>`, `preset-rtsp-restream`, roles `[detect, record]`, detect `{enabled: true, fps: 5}`, no width/height (P11), and **no `go2rtc.streams`** (only the rtsp/webrtc listens);
  - writes the two camera files.
- Camera files:
  - first `mkdir -p` + `chown root:root` + `chmod 0700` on `/var/snap/frigate/current/ezviz`, `…/ezviz/cameras`, `/var/snap/frigate/common/ezviz` and `…/ezviz/state` (state is **never emptied**);
  - then for each camera: content `# written by tests/hub/make-config.sh (M7C_SOURCE=ezviz); root 0600; never print\nhost=<ip>\nport=8000\nserial=<id>\nlogin=<code>\n`, sent on stdin to `cat > <f>.m7c-new && chown root:root && chmod 0600 && sha256sum`, the sha compared, then `mv` into place;
  - then `snap run frigate.ezviz-check cam1` and `cam2` → each must print `ok` (else exit 11, "camera files written but ezviz-check failed").
- `M7C_RETAIN_DAYS` (default 1; integer 1–30, else exit 2) sets `record.continuous.days`, `record.alerts.retain.days` and `record.detections.retain.days` in **every** mode. The self-check compares all three with it.
- The self-check in ezviz mode:
  - `(.go2rtc.streams // {}) | keys | length == 0`;
  - no `://…@` anywhere (the existing clip check, now also ezviz);
  - cameras `cam1,cam2`, each with one input `detect,record`.
- P10: in `cameras` and `clip` mode, if `ls /var/snap/frigate/current/ezviz/cameras/*.conf` finds files → exit 10 "ezviz camera files present on the hub; remove /var/snap/frigate/current/ezviz first (rollback step)". Nothing is written.
- Output in ezviz mode, ≤ 12 lines:
  - `built: 2 cameras (ezviz), 0 go2rtc streams, …, continuous.days <N>, alerts/detections retain.days <N>, …`
  - `camera files: 2 written (root, 0600, sha256 matched)`
  - `ezviz-check cam1: ok`
  - `ezviz-check cam2: ok`
  - then validate-config and `ok`.
- Responder: map `/var/snap/frigate/current/ezviz` to `$STUB_ST/ezviz` and `/var/snap/frigate/common/ezviz` to `$STUB_ST/common-ezviz`; fake `snap run frigate.ezviz-check camN`, which prints `ezviz-check camN: ok` iff `$st/ezviz/cameras/camN.conf` exists with mode 600 (knob `MC_CHECK=0` → `mode`); add `frigate.go2rtc` active via `MC_G2R_ACTIVE=1`.

- [ ] **Step 1: Write the failing checks** in `make-config.test.sh`:

```bash
# --- M7C_SOURCE=ezviz ---
run e1 M7C_SOURCE=ezviz --
check "ezviz: exit 0" 0 "$(rc e1)"; check "ezviz: last line ok" "make-config: ok" "$(tail -n 1 "$(O e1)")"; noleak e1
check "ezviz: no go2rtc streams" 0 "$(y e1 '(.go2rtc.streams // {}) | keys | length')"
check "ezviz: cam1 one input detect+record" "rtsp://127.0.0.1:8554/cam1 detect,record" "$(y e1 '[.cameras.cam1.ffmpeg.inputs[] | .path + " " + (.roles | join(","))] | join(";")')"
check "ezviz: no URL with a login" 0 "$(grep -c '://[^ ]*@' "$(HC e1)")"
check "ezviz: cam1.conf mode 600" 600 "$(stat -c %a "$T/e1/st/ezviz/cameras/cam1.conf")"
check "ezviz: cam1.conf content" "host=$IP1 port=8000 serial=$ID1 login=$CA" "$(grep -v '^#' "$T/e1/st/ezviz/cameras/cam1.conf" | tr '\n' ' ' | sed 's/ $//')"
check "ezviz: cam2.conf is the second pair" "host=$IP2" "$(grep '^host=' "$T/e1/st/ezviz/cameras/cam2.conf")"
check "ezviz: state dir 700, created" 700 "$(stat -c %a "$T/e1/st/common-ezviz/state")"
has   "ezviz: says 2 camera files written" "camera files: 2 written (root, 0600, sha256 matched)" "$(O e1)"
has   "ezviz: ezviz-check ok for both" "ezviz-check cam2: ok" "$(O e1)"
has   "ezviz: camera files go on stdin only" "cat > /var/snap/frigate/current/ezviz/cameras/cam1.conf.m7c-new" "$T/e1/st/cmds"
hasnt "ezviz: no code in any remote command" "$CA" "$T/e1/st/cmds"
PRE='mkdir -p "$T/$n/st/common-ezviz/state"; echo keep > "$T/$n/st/common-ezviz/state/cam1.ledger"' run e2 M7C_SOURCE=ezviz --
check "ezviz: an existing ledger is kept" keep "$(cat "$T/e2/st/common-ezviz/state/cam1.ledger")"
run e3 M7C_SOURCE=ezviz MC_G2R_ACTIVE=1 --; check "ezviz: go2rtc active: exit 4" 4 "$(rc e3)"; hasnt "ezviz: go2rtc active: nothing written" "m7c-new" "$T/e3/st/cmds"
run e4 M7C_SOURCE=ezviz MC_CHECK=0 --;    check "ezviz: ezviz-check fails: exit 11" 11 "$(rc e4)"
run e5 M7C_SOURCE=ezviz M7C_RETAIN_DAYS=3 --; check "retain 3 applied to all three" "3 3 3" "$(y e5 '[.record.continuous.days, .record.alerts.retain.days, .record.detections.retain.days] | map(tostring) | join(" ")')"
run e6 M7C_RETAIN_DAYS=0 --;  check "retain 0: exit 2" 2 "$(rc e6)"; run e7 M7C_RETAIN_DAYS=x --; check "retain x: exit 2" 2 "$(rc e7)"
PRE='mkdir -p "$T/$n/st/ezviz/cameras"; : > "$T/$n/st/ezviz/cameras/cam1.conf"' run e8 M7C_SOURCE=clip "$(CX e8)" "$(CF e8)" --
check "clip with camera files present: exit 10" 10 "$(rc e8)"; hasnt "exit 10: nothing written" "m7c-new" "$T/e8/st/cmds"
BASHX="bash -x" run e9 M7C_SOURCE=ezviz --; check "ezviz: bash -x: exit 0" 0 "$(rc e9)"; noleak e9
# generator cross-check: the snap's generator with the camera dir -> streams cam1,cam2 (exec) + test,testclip; preload both
```

- [ ] **Step 2: Run and see them fail.** `bash tests/hub/make-config.test.sh` → the new checks FAIL; the 157 old ones are still ok.
- [ ] **Step 3: Implement** in make-config and the responder.
- [ ] **Step 4: Run and see them pass** (157 + about 26 ok; record the exact count).
- [ ] **Step 5: Mutation:** send a camera file's content inside the remote command instead of on stdin → `ezviz: no code in any remote command` must fail. Revert.
- [ ] **Step 6: Commit** `feat(hub): make-config ezviz mode, camera files, parameterised retention (W-23 T18; §6, F5, P10)`.

### Task 19: Hub tools — ledger counts, the power check, coverage, the watcher trip, observe `--helpers`

**Files:**
- Create: `tests/hub/ezviz-ledger.sh`, `tests/hub/ezviz-ledger.test.sh`, `tests/hub/fixtures/ledger-responder.sh`
- Create: `tests/hub/power-check.sh`, `tests/hub/power-check.test.sh`, `tests/hub/fixtures/power-responder.sh`
- Create: `tests/hub/coverage.sh`, `tests/hub/coverage.test.sh`, `tests/hub/fixtures/coverage-responder.sh`
- Modify: `tests/hub/watch.sh`, `watch.test.sh`, `fixtures/watch-responder.sh`, `observe.sh`, `observe.test.sh`, `fixtures/observe-responder.sh`

**Interfaces:**
- **`power-check.sh --since <epoch> [--allow-boots N]`** (SF10):
  - reads `journalctl _TRANSPORT=kernel --since @<epoch>`, which covers **all boots** in the window. `journalctl -k` implies `-b` and would miss an undervoltage that rebooted the hub;
  - counts `Undervoltage detected` lines and boots (kernel `Linux version` lines);
  - proves that the journal reaches back to `<epoch>`;
  - exit 0 PASS, 1 FAIL (undervoltage, or more boots than allowed), 2 usage, 3 master gone, **4 INCONCLUSIVE** (unreadable, or the journal does not cover the window; never reported as 0).
- **`ezviz-ledger.sh [--since <epoch>]`**: per camera it prints `ledger <name>: attempts=… login_ok=… published=… ends=… latched=… max_attempts_any_60min=… attempts_since=… login_ok_since=… last=<ev>@<iso>`, or `ledger <name>: damaged` (N2). Exit 1 when a camera is latched or damaged, or holds > 3 attempts in a rolling hour.
- **`coverage.sh --since <epoch> [--hours 24]`**:
  - prints `coverage <cam>: <pct> %` from Frigate's recordings list, read through the snap's own python as `observe.sh` reads `/stats`;
  - exit 1 below 99 % or when unreadable;
  - the route `GET /api/<camera>/recordings?after=&before=` (`start_time`/`end_time`) is to be confirmed in v0.18.2 `frigate/api/media.py`; if it differs, change only `REMOTE_PY`.
- **`watch.sh`**: the sample gains `kuv=<n>`, the kernel transport's undervoltage count since the watcher's start epoch, all boots (the same source as power-check), or `kuv=unreadable`. A growing count is `TRIP undervoltage`; `--act` stops frigate (P12). `unreadable` is an INFO line, never 0 and never BLIND. The sample's remote part:
  ```sh
  k=$(journalctl _TRANSPORT=kernel --since @$START --no-pager -q -o cat 2>/dev/null) && echo "kuv=$(printf '%s\n' "$k" | grep -c 'Undervoltage detected')" || echo kuv=unreadable
  ```
- **`observe.sh --helpers N`** (default 0):
  - counts processes in the go2rtc unit whose args contain `-m ezviz_source.main`, labelled `h` with their camera name (the argument after the module);
  - PASS when the count equals N and none has restarted since `--prev`;
  - never prints a whole command line.

- [ ] **Step 1: Write the failing tests.** These three were run on 19 Nov against the code in Step 3:

```bash
#!/usr/bin/env bash
# tests/hub/power-check.sh against a fake hub (ssh-exec.sh -> fixtures/stub/ssh -> fixtures/power-responder.sh).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1; fail=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
FX=$PWD/tests/hub/fixtures; E=1794000000
run() {  # run NAME [env...] -- args
  local n=$1; shift; local -a e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  mkdir -p "$T/$n/st"; : > "$T/$n/st/log"; : > "$T/$n/st/cmds"; [ -n "${PRE:-}" ] && eval "$PRE"
  env STUB_ST="$T/$n/st" STUB_RESPONDER="$FX/power-responder.sh" M7C_SSH="$FX/stub/ssh" M7C_HUB_SOCK=/run/test/m7c.sock \
    M7C_HUB_TARGET=hub-test "${e[@]}" timeout 30 bash tests/hub/power-check.sh "$@" > "$T/$n.out" 2>&1; echo $? > "$T/$n.rc"
}
rc() { cat "$T/$1.rc"; }; O() { cat "$T/$1.out"; }
run p0 -- --since $E;            check "clean: exit 0" 0 "$(rc p0)"; check "clean: PASS last" "power-check: PASS" "$(O p0 | tail -n 1)"
check "clean: names the window and counts" "power-check: since 2026-11-06T21:20:00Z: undervoltage lines 0, boots 0 (allowed 0)" "$(O p0 | head -n 1)"
check "reads the kernel transport across boots (no -k, no -b)" "1 0" "$(grep -c '_TRANSPORT=kernel --since @1794000000' "$T/p0/st/cmds") $(grep -cE 'journalctl (-k|-b|--dmesg)' "$T/p0/st/cmds")"
run p1 PC_UV=2 -- --since $E;    check "undervoltage (any boot in the window): exit 1" 1 "$(rc p1)"; check "says 2" 1 "$(O p1 | grep -c 'undervoltage lines 2')"
run p2 PC_KRC=1 -- --since $E;   check "journalctl fails: INCONCLUSIVE exit 4, never 0" 4 "$(rc p2)"
run p3 PC_COVER=0 -- --since $E; check "journal does not reach back: exit 4" 4 "$(rc p3)"
run p4 PC_GARBLE=1 -- --since $E; check "unparsable answer: exit 4" 4 "$(rc p4)"
run p5 PC_BOOTS=1 -- --since $E; check "an unplanned boot in the window: exit 1" 1 "$(rc p5)"
run p6 PC_BOOTS=1 -- --since $E --allow-boots 1; check "a planned boot (S11): exit 0" 0 "$(rc p6)"
PRE='touch "$T/$n/st/gone"' run p7 -- --since $E; check "master gone: exit 3" 3 "$(rc p7)"
run p8 -- --since 12x;           check "bad --since: exit 2" 2 "$(rc p8)"; check "usage sends nothing" 0 "$(wc -l < "$T/p8/st/cmds")"
[ "$fail" = 0 ] && echo "power-check.test: all ok" || echo "power-check.test: FAILURES"
exit "$fail"
```
```bash
#!/usr/bin/env bash
# shellcheck disable=SC2016  # PRE strings are single-quoted on purpose: run() evals them with its own $T and $n
# tests/hub/ezviz-ledger.sh against a fake hub: the stub ssh runs the remote command with /var/snap/frigate/common
# mapped to $STUB_ST/common (fixtures/ledger-responder.sh). Fixture ledgers only; no camera value exists anywhere.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1; fail=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
FX=$PWD/tests/hub/fixtures; E=1794000000
L() { printf '{"t":%s,"ev":"%s","dur":null}\n' "$(( E + $1 ))" "$2"; }   # L <offset s> <ev>
run() {  # run NAME -- args; PRE seeds $T/$n/st/common/ezviz/state
  local n=$1; shift; [ "$1" = -- ] && shift
  mkdir -p "$T/$n/st/common/ezviz/state"; : > "$T/$n/st/log"; : > "$T/$n/st/cmds"; [ -n "${PRE:-}" ] && eval "$PRE"
  env STUB_ST="$T/$n/st" STUB_RESPONDER="$FX/ledger-responder.sh" M7C_SSH="$FX/stub/ssh" M7C_HUB_SOCK=/run/test/m7c.sock \
    M7C_HUB_TARGET=hub-test timeout 30 bash tests/hub/ezviz-ledger.sh "$@" > "$T/$n.out" 2>&1; echo $? > "$T/$n.rc"
}
rc() { cat "$T/$1.rc"; }; O() { cat "$T/$1.out"; }; S='$T/$n/st/common/ezviz/state'
PRE="{ L 0 attempt; L 2 login_ok; L 9 published; L 3000 stop; L 3010 attempt; L 3012 login_ok; L 3020 published; } > $S/cam1.ledger; { L 0 attempt; L 1 net_fail; L 100 attempt; L 102 login_ok; L 110 published; } > $S/cam2.ledger" run a -- --since $((E + 3005))
check "two healthy ledgers: exit 0" 0 "$(rc a)"
check "cam1 line" "ledger cam1: attempts=2 login_ok=2 published=2 ends=stop:1 latched=0 max_attempts_any_60min=2 attempts_since=1 login_ok_since=1 last=published@2026-11-06T22:10:20Z" "$(O a | head -n 1)"
check "cam2 line" "ledger cam2: attempts=2 login_ok=1 published=1 ends=net_fail:1 latched=0 max_attempts_any_60min=2 attempts_since=0 login_ok_since=0 last=published@2026-11-06T21:21:50Z" "$(O a | tail -n 1)"
PRE="{ L 0 attempt; L 1 net_fail; L 61 attempt; L 62 net_fail; L 400 attempt; L 401 net_fail; L 3599 attempt; } > $S/cam1.ledger" run b --
check "4 attempts inside one rolling hour: exit 1" 1 "$(rc b)"; check "says 4" 1 "$(O b | grep -c 'max_attempts_any_60min=4')"
PRE="{ L 0 attempt; L 1 auth_fail; L 1 latch; } > $S/cam1.ledger; : > $S/cam1.latch" run c --
check "latched: exit 1" 1 "$(rc c)"; check "latched=1" 1 "$(O c | grep -c 'ledger cam1: .*latched=1')"
PRE="{ L 0 attempt; echo garbage; L 9 stop; } > $S/cam1.ledger" run d --
check "damaged middle line: exit 1, says damaged" "1 ledger cam1: damaged" "$(rc d) $(O d | head -n 1)"
PRE="{ L 0 attempt; L 2 login_ok; printf '{\"t\":'; } > $S/cam1.ledger" run e --
check "torn last line ignored: exit 0" 0 "$(rc e)"; check "torn: last is login_ok" 1 "$(O e | grep -c 'last=login_ok@')"
PRE='touch "$T/$n/st/gone"' run f --; check "master gone: exit 3" 3 "$(rc f)"
run g -- --since x; check "bad --since: exit 2" 2 "$(rc g)"
[ "$fail" = 0 ] && echo "ezviz-ledger.test: all ok" || echo "ezviz-ledger.test: FAILURES"
exit "$fail"
```
```bash
#!/usr/bin/env bash
# shellcheck disable=SC2016  # PRE strings are single-quoted on purpose: run() evals them with its own $T and $n
# tests/hub/coverage.sh against a fake hub (fixtures/coverage-responder.sh answers fixture JSON; no Frigate).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1; fail=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
FX=$PWD/tests/hub/fixtures; E=1794000000; D=86400
seg() { printf '[%s,%s]' "$((E + $1))" "$((E + $2))"; }
ans() { printf '{"cam":"cam1","segments":[%s]}\n{"cam":"cam2","segments":[%s]}\n' "$1" "$2"; }
run() {  # run NAME -- args; ANS is the fixture answer
  local n=$1; shift; [ "$1" = -- ] && shift
  mkdir -p "$T/$n/st"; : > "$T/$n/st/log"; : > "$T/$n/st/cmds"; printf '%s' "${ANS:-}" > "$T/$n/st/answer"; [ -n "${PRE:-}" ] && eval "$PRE"
  env STUB_ST="$T/$n/st" STUB_RESPONDER="$FX/coverage-responder.sh" M7C_SSH="$FX/stub/ssh" M7C_HUB_SOCK=/run/test/m7c.sock \
    M7C_HUB_TARGET=hub-test timeout 30 bash tests/hub/coverage.sh "$@" > "$T/$n.out" 2>&1; echo $? > "$T/$n.rc"
}
rc() { cat "$T/$1.rc"; }; O() { cat "$T/$1.out"; }
ANS=$(ans "$(seg 0 43000),$(seg 43000 $((D - 360)))" "$(seg -100 $((D + 100)))") run a -- --since $E
check "23.9 of 24 h and full: exit 0" 0 "$(rc a)"; check "cam1 99.6 %" "coverage cam1: 99.6 %" "$(O a | head -n 1)"; check "cam2 clipped to 100.0 %" "coverage cam2: 100.0 %" "$(O a | tail -n 1)"
ANS=$(ans "$(seg 0 40000),$(seg 41800 $D)" "$(seg 0 $D)") run b -- --since $E
check "a 30 min gap: exit 1" 1 "$(rc b)"; check "cam1 97.9 %" "coverage cam1: 97.9 %" "$(O b | head -n 1)"
ANS=$(ans "$(seg 0 50000),$(seg 10000 60000),$(seg 59000 $D)" "$(seg 0 $D)") run c -- --since $E
check "overlaps are not double-counted" "coverage cam1: 100.0 %" "$(O c | head -n 1)"
ANS='{"cam":"cam1","error":"URLError"}' run d -- --since $E
check "unreadable API and a missing camera: exit 1" 1 "$(rc d)"; check "both unreadable" 2 "$(O d | grep -c ': unreadable')"
ANS=$(ans "$(seg 0 $D)" "$(seg 0 $D)") run e -- --since $E
check "only numbers printed" 0 "$(O e | grep -cvE '^coverage cam[12]: [0-9.]+ %$')"
check "the hub gets the snap's python on stdin, no camera value" 1 "$(grep -c 'api/%s/recordings?after=1794000000&before=1794086400' "$T/e/st/stdin")"
PRE='touch "$T/$n/st/gone"' run f -- --since $E; check "master gone: exit 3" 3 "$(rc f)"
run g -- --since $E --hours 0; check "--hours 0: exit 2" 2 "$(rc g)"
[ "$fail" = 0 ] && echo "coverage.test: all ok" || echo "coverage.test: FAILURES"
exit "$fail"
```
The three responders:
```bash
#!/usr/bin/env bash
# Fake hub for tests/hub/power-check.test.sh (the stub ssh's $STUB_RESPONDER). Every remote command is logged to
# $STUB_ST/cmds. Knobs: PC_KRC (journalctl rc, default 0), PC_COVER (1 = the journal reaches back, default 1),
# PC_UV (undervoltage lines, default 0), PC_BOOTS (boots in the window, default 0), PC_GARBLE=1 (unparsable answer).
set -u
st="${STUB_ST:?}"
eval "set -- $1"
[ "$1 $2 $3 $4" = "sudo -n sh -c" ] || { echo "responder: not a sudo -n sh -c call: $*" >&2; exit 99; }
printf '%s\n' "$5" >> "$st/cmds"
[ "${PC_GARBLE:-0}" = 1 ] && { echo "journalctl: command not found"; exit 0; }
printf 'krc=%s\ncover=%s\nuv=%s\nboots=%s\n' "${PC_KRC:-0}" "${PC_COVER:-1}" "${PC_UV:-0}" "${PC_BOOTS:-0}"
```
```bash
#!/usr/bin/env bash
# Fake hub for tests/hub/ezviz-ledger.test.sh: runs the remote command for real with /var/snap/frigate/common mapped
# to $STUB_ST/common. Every remote command is logged to $STUB_ST/cmds.
set -u
st="${STUB_ST:?}"
eval "set -- $1"
[ "$1 $2 $3 $4" = "sudo -n sh -c" ] || { echo "responder: not a sudo -n sh -c call: $*" >&2; exit 99; }
printf '%s\n' "$5" >> "$st/cmds"
sh -c "${5//\/var\/snap\/frigate\/common/$st/common}"
```
```bash
#!/usr/bin/env bash
# Fake hub for tests/hub/coverage.test.sh. Logs every remote command and its stdin (the python sent to the snap's
# shell) to $STUB_ST; answers with $STUB_ST/answer (fixture JSON lines) when the command is the snap-shell call.
set -u
st="${STUB_ST:?}"
eval "set -- $1"
[ "$1 $2 $3 $4" = "sudo -n sh -c" ] || { echo "responder: not a sudo -n sh -c call: $*" >&2; exit 99; }
printf '%s\n' "$5" >> "$st/cmds"; cat > "$st/stdin"
case "$5" in 'snap run --shell frigate.frigate -c '*) cat "$st/answer" ;; *) echo "unexpected command"; exit 1 ;; esac
```
`watch.test.sh` additions. `fixtures/watch-responder.sh` gains the knob `W_UV`, printed as `kuv=$(pick "${W_UV:-0}")`:
```bash
run uv1 W_UV="0 0 1" -- "${B[@]}" --samples 3
check "undervoltage +1: exit 1" 1 "$(rc uv1)"; has "undervoltage: TRIP line" "TRIP: undervoltage" "$(O uv1)"
run uv2 W_UV="0 1" -- "${B[@]}" --samples 2 --act; check "undervoltage --act: frigate stopped once" 1 "$(stops uv2)"
run uv3 W_UV="unreadable" -- "${B[@]}" --samples 3
check "kuv unreadable: exit 0, no TRIP" 0 "$(rc uv3)"; has "kuv unreadable: INFO line" "INFO: kernel journal unreadable" "$(O uv3)"
has "the sample reads the kernel transport across boots" "journalctl _TRANSPORT=kernel --since @" "$(C uv3)"
hasnt "never journalctl -k" "journalctl -k" "$(C uv3)"
```
`observe.test.sh` additions. `fixtures/observe-responder.sh` gains `O_HELPERS="<pid>:<cam> …"` fake processes whose args are `python3.12 -I -B -m ezviz_source.main <cam> rtsp://127.0.0.1:8554/x`:
```bash
run oh1 O_HELPERS="501:cam1 502:cam2" -- --execs 0 --helpers 2
check "--helpers 2: exit 0" 0 "$(rc oh1)"; has "helpers PASS names both" "PASS go2rtc helpers: 2 (cam1 cam2)" "$(O oh1)"
hasnt "no exec verdict with --execs 0" "go2rtc exec:" "$(O oh1)"
PRE='cp -r "$T/oh1/out" "$T/$n/prev"' run oh2 O_HELPERS="501:cam1 777:cam2" -- --execs 0 --helpers 2 --prev "$T/oh2/prev"
check "a helper restarted since --prev: exit 1" 1 "$(rc oh2)"
hasnt "never a whole command line" "rtsp://127.0.0.1:8554/x" "$(O oh2)"
```

- [ ] **Step 2: Run and see them fail.** `for t in power-check ezviz-ledger coverage watch observe; do bash tests/hub/$t.test.sh; done`
- [ ] **Step 3: Implement.** `tests/hub/power-check.sh`:

```bash
#!/usr/bin/env bash
# W-23 P12 / SF10: read-only check that the hub kernel logged no "Undervoltage detected" line since a time.
# It reads journald's KERNEL transport across ALL boots since the time (`journalctl -k` would imply -b, the
# current boot only, and miss an undervoltage that crashed or rebooted the hub, as on 18 Nov). It also
# counts boots in the window ("Linux version" kernel lines) and proves the journal reaches back to the time.
# One command on the hub through tests/hub/ssh-exec.sh (the operator's existing master only).
# Usage: M7C_HUB_SOCK=<socket> M7C_HUB_TARGET=<target> tests/hub/power-check.sh --since <epoch> [--allow-boots N]
# Exit: 0 PASS (0 undervoltage, boots <= N); 1 FAIL; 2 usage; 3 the master is gone; 4 INCONCLUSIVE (the journal
# cannot be read or does not cover the window: never reported as 0).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); EXEC="$HERE/ssh-exec.sh"
usage() { echo "usage: power-check.sh --since <epoch> [--allow-boots N]" >&2; exit 2; }
SINCE=""; ALLOW=0
while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ $# -ge 2 ] || usage; SINCE=$2; shift 2 ;;
    --allow-boots) [ $# -ge 2 ] || usage; ALLOW=$2; shift 2 ;;
    *) usage ;;
  esac
done
case "$SINCE" in ''|*[!0-9]*) usage ;; esac
case "$ALLOW" in ''|*[!0-9]*) usage ;; esac
ISO=$(date -u -d "@$SINCE" +%Y-%m-%dT%H:%M:%SZ)
# shellcheck disable=SC2016  # expanded on the hub, not here
REMOTE='k=$(journalctl _TRANSPORT=kernel --since @'"$SINCE"' --no-pager -q -o cat 2>/dev/null); krc=$?
c=$(journalctl --until @'"$SINCE"' -r -n 1 --no-pager -q -o short-unix 2>/dev/null | wc -l)
printf "krc=%s\ncover=%s\nuv=%s\nboots=%s\n" "$krc" "$c" "$(printf "%s\n" "$k" | grep -c "Undervoltage detected")" "$(printf "%s\n" "$k" | grep -c "Linux version")"'
out=$("$EXEC" exec "$REMOTE" 2>&1 </dev/null); rc=$?
[ "$rc" = 3 ] && { echo "power-check: MASTER GONE; nothing was read" >&2; exit 3; }
get() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -n 1; }
krc=$(get krc); cover=$(get cover); uv=$(get uv); boots=$(get boots)
for v in "$krc" "$cover" "$uv" "$boots"; do case "$v" in ''|*[!0-9]*) rc=99 ;; esac; done
if [ "$rc" != 0 ] || [ "$krc" != 0 ] || [ "$cover" != 1 ]; then
  echo "power-check: INCONCLUSIVE: the kernel journal since $ISO cannot be read or does not reach back that far"; exit 4
fi
echo "power-check: since $ISO: undervoltage lines $uv, boots $boots (allowed $ALLOW)"
if [ "$uv" != 0 ] || [ "$boots" -gt "$ALLOW" ]; then echo "power-check: FAIL"; exit 1; fi
echo "power-check: PASS"
```
`tests/hub/ezviz-ledger.sh`:
```bash
#!/usr/bin/env bash
# W-23: read both cameras' ledgers on the hub (one read-only command through tests/hub/ssh-exec.sh) and print
# counts only. The ledgers hold no host, serial or login (spec §4.3); this prints event names, counts and times.
# Usage: M7C_HUB_SOCK=<socket> M7C_HUB_TARGET=<target> tests/hub/ezviz-ledger.sh [--since <epoch>]
# Exit: 0 ok; 1 a camera is latched, its ledger is damaged, or a rolling 60 min holds > 3 attempts;
#       2 usage; 3 the master is gone.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); EXEC="$HERE/ssh-exec.sh"
usage() { echo "usage: ezviz-ledger.sh [--since <epoch>]" >&2; exit 2; }
SINCE=0
while [ $# -gt 0 ]; do
  case "$1" in --since) [ $# -ge 2 ] || usage; SINCE=$2; shift 2 ;; *) usage ;; esac
done
case "$SINCE" in ''|*[!0-9]*) usage ;; esac
ST=/var/snap/frigate/common/ezviz/state
out=$("$EXEC" exec "for n in cam1 cam2; do echo \"== \$n\"; cat $ST/\$n.ledger 2>/dev/null; [ -e $ST/\$n.latch ] && echo '== latchfile'; done; echo '== end'" 2>&1 </dev/null); rc=$?
[ "$rc" = 3 ] && { echo "ezviz-ledger: MASTER GONE; nothing was read" >&2; exit 3; }
[ "$rc" = 0 ] || { echo "ezviz-ledger: the hub command failed (rc $rc)"; exit 1; }
read -r -d '' PY <<'EOF'
import collections, datetime, json, os, sys
since, cams, cur, bad = float(sys.argv[1]), {}, None, 0
ENDS = {"auth_fail", "net_fail", "session_end", "output_end", "stop", "start_timeout", "unknown_end", "protocol_fail"}
for line in os.environ["LEDGERS"].split("\n"):
    if line.startswith("== "):
        tag = line[3:]
        if tag == "latchfile":
            cams[cur]["latch"] = True
        elif tag != "end":
            cur = tag
            cams[cur] = {"raw": [], "latch": False}
    elif cur is not None and line:
        cams[cur]["raw"].append(line)
for name, c in cams.items():
    recs, damaged = [], False
    for i, line in enumerate(c["raw"]):
        try:
            r = json.loads(line)
            float(r["t"]), str(r["ev"])
            recs.append(r)
        except (ValueError, KeyError, TypeError):
            damaged = damaged or i != len(c["raw"]) - 1      # a torn LAST line is skipped (spec 4.3)
    if damaged:
        print(f"ledger {name}: damaged")
        bad = 1
        continue
    att = sorted(r["t"] for r in recs if r["ev"] == "attempt")
    mx = max((sum(1 for b in att if a <= b < a + 3600) for a in att), default=0)
    n = lambda ev, t0=float("-inf"): sum(1 for r in recs if r["ev"] == ev and r["t"] >= t0)
    ends = collections.Counter(r["ev"] for r in recs if r["ev"] in ENDS)
    latched = c["latch"] or bool(recs and recs[-1]["ev"] == "latch")
    last = "none"
    if recs:
        ts = datetime.datetime.fromtimestamp(recs[-1]["t"], datetime.timezone.utc)
        last = recs[-1]["ev"] + "@" + ts.strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"ledger {name}: attempts={len(att)} login_ok={n('login_ok')} published={n('published')} "
          f"ends={','.join(f'{k}:{v}' for k, v in sorted(ends.items())) or '-'} latched={int(latched)} "
          f"max_attempts_any_60min={mx} attempts_since={n('attempt', since)} login_ok_since={n('login_ok', since)} last={last}")
    bad = bad or latched or mx > 3
sys.exit(1 if bad else 0)
EOF
LEDGERS=$out python3 -I -c "$PY" "$SINCE"
```
`tests/hub/coverage.sh`:
```bash
#!/usr/bin/env bash
# W-23 S8: per-camera recording coverage of a window, numbers only. One command on the hub through
# tests/hub/ssh-exec.sh: the snap's own python (the hub has no python3, curl or jq) reads Frigate's recordings
# list on its internal API, as observe.sh reads /stats, and prints only [start, end] pairs per camera.
# ROUTE: GET /api/<camera>/recordings?after=<s>&before=<e> with start_time/end_time per segment. Confirm it in
# v0.18.2 frigate/api/media.py while implementing; if it differs, change REMOTE_PY only (the test pins the shape).
# Usage: M7C_HUB_SOCK=<socket> M7C_HUB_TARGET=<target> tests/hub/coverage.sh --since <epoch> [--hours 24]
# Exit: 0 every camera >= 99 %; 1 otherwise or unreadable; 2 usage; 3 the master is gone.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); EXEC="$HERE/ssh-exec.sh"
usage() { echo "usage: coverage.sh --since <epoch> [--hours H]" >&2; exit 2; }
SINCE=""; H=24
while [ $# -gt 0 ]; do
  case "$1" in --since) [ $# -ge 2 ] || usage; SINCE=$2; shift 2 ;; --hours) [ $# -ge 2 ] || usage; H=$2; shift 2 ;; *) usage ;; esac
done
case "$SINCE" in ''|*[!0-9]*) usage ;; esac
case "$H" in ''|*[!0-9]*|0) usage ;; esac
END=$((SINCE + H * 3600))
read -r -d '' REMOTE_PY <<EOF
import json, urllib.request
for cam in ("cam1", "cam2"):
    req = urllib.request.Request("http://127.0.0.1:5001/api/%s/recordings?after=$SINCE&before=$END" % cam,
                                 headers={"Remote-User": "admin", "Remote-Role": "admin"})
    try:
        segs = [[float(s["start_time"]), float(s["end_time"])] for s in json.load(urllib.request.urlopen(req, timeout=30))]
        print(json.dumps({"cam": cam, "segments": segs}))
    except Exception as e:
        print(json.dumps({"cam": cam, "error": type(e).__name__}))
EOF
# shellcheck disable=SC2016  # $SNAP is expanded inside the snap's shell on the hub
out=$(printf '%s\n' "$REMOTE_PY" | "$EXEC" exec 'snap run --shell frigate.frigate -c "\"\$SNAP/usr/bin/python3.11\" -I -"' 2>&1); rc=$?
[ "$rc" = 3 ] && { echo "coverage: MASTER GONE; nothing was read" >&2; exit 3; }
read -r -d '' PY <<'EOF'
import json, os, sys
s, e = float(sys.argv[1]), float(sys.argv[2]); bad = 0; seen = set()
for line in os.environ["OUT"].splitlines():
    try:
        d = json.loads(line)
    except ValueError:
        continue
    cam = d.get("cam")
    if cam not in ("cam1", "cam2"):
        continue
    seen.add(cam)
    if "segments" not in d:
        print(f"coverage {cam}: unreadable"); bad = 1; continue
    covered, cur_s, cur_e = 0.0, None, None
    for a, b in sorted((max(a, s), min(b, e)) for a, b in d["segments"] if b > s and a < e):
        if cur_e is None or a > cur_e:
            covered += (cur_e - cur_s) if cur_e is not None else 0.0
            cur_s, cur_e = a, b
        else:
            cur_e = max(cur_e, b)
    covered += (cur_e - cur_s) if cur_e is not None else 0.0
    pct = 100.0 * covered / (e - s)
    print(f"coverage {cam}: {pct:.1f} %")
    bad = bad or pct < 99.0
for cam in sorted({"cam1", "cam2"} - seen):
    print(f"coverage {cam}: unreadable"); bad = 1
sys.exit(1 if bad else 0)
EOF
OUT=$out python3 -I -c "$PY" "$SINCE" "$END"
```
`watch.sh` and `observe.sh` are implemented to the interfaces above, in their existing style.

- [ ] **Step 4: Run and see them pass.** Run on 19 Nov:
  - `power-check.test.sh`: 14 ok;
  - `ezviz-ledger.test.sh`: 12 ok;
  - `coverage.test.sh`: 12 ok;
  - shellcheck clean.

  The 90 watch and 83 observe checks must stay ok, plus 6 new each.
- [ ] **Step 5: Mutations.** These made `power-check.test.sh` FAIL on 19 Nov:
  - `journalctl -k` for the kernel transport (SF10) → "reads the kernel transport across boots";
  - an unreadable journal counted as 0 → the three INCONCLUSIVE checks.
- [ ] **Step 6: Commit** `feat(hub): ledger counts, undervoltage check across boots and trip, coverage, observe --helpers (W-23 T19; P12, SF10)`

### Task 20: Snap packaging and its static and size tests (OD1/R1, §5)

**Files:**
- Modify: `snap/snapcraft.yaml`
- Create: `tests/w23-packaging.test.sh`, `tests/w23-size.sh`

**Interfaces:** the new part and apps (the exact text, which the static test greps):

```yaml
  ezviz-check:
    command: bin/ezviz-check
  disk-guard:
    command: bin/disk-guard
    daemon: oneshot
    timer: "00:00-24:00/144"
```
```yaml
  ezviz-py:
    plugin: nil
    source: spike/ezviz
    build-packages: [wget]
    override-build: |
      # W-23 OD1/R1: a separate CPython 3.12 used ONLY by the ezviz helper (pyezvizapi needs >= 3.12; Frigate stays on 3.11).
      case "$CRAFT_ARCH_BUILD_FOR" in
        amd64) A=x86_64;  S=6a9e62dad033790aef722dbd370e0ce76ce17b73627ba3ae679f537049350b39 ;;
        arm64) A=aarch64; S=b6a41defec4975d94b4ff1950236e7383e5c02ba40ea48c9ec33c66087a35aab ;;
        *) echo "ezviz-py: unsupported arch $CRAFT_ARCH_BUILD_FOR" >&2; exit 1 ;;
      esac
      wget -O "$CRAFT_PART_BUILD/py.tgz" "https://github.com/astral-sh/python-build-standalone/releases/download/20261110/cpython-3.12.16%2B20261110-$A-unknown-linux-gnu-install_only_stripped.tar.gz"
      echo "$S  $CRAFT_PART_BUILD/py.tgz" | sha256sum -c -
      D="$CRAFT_PART_INSTALL/opt/ezviz-py"; mkdir -p "$D"
      tar -xzf "$CRAFT_PART_BUILD/py.tgz" -C "$D" --strip-components=1
      # SF7: NOT env -i here: pip must keep the Launchpad builder's http_proxy/https_proxy/no_proxy (as spike-wheels does).
      env -u LD_LIBRARY_PATH -u PYTHONPATH -u PYTHONHOME "$D/bin/python3.12" -I -m pip install --no-cache-dir --no-compile \
        --require-hashes --only-binary=:all: --no-deps -r "$CRAFT_PART_SRC/requirements.txt"
      SP="$D/lib/python3.12/site-packages"
      cp -r "$CRAFT_PART_SRC/ezviz_source" "$SP/"
      env -i PATH=/usr/bin:/bin "$D/bin/python3.12" -I -m pip uninstall -y pip
      # Prune (each verified by the import proof below): Tk/Tcl, idle, turtle, ensurepip, headers, docs, the shared libpython
      # (bin/python3.12 links libpython statically; nothing embeds it).
      rm -rf "$D"/include "$D"/share "$D"/lib/pkgconfig "$D"/lib/tcl9* "$D"/lib/tk9* "$D"/lib/itcl* "$D"/lib/thread* \
             "$D"/lib/libtcl9* "$D"/lib/python3.12/config-3.12-* \
             "$D"/lib/python3.12/idlelib "$D"/lib/python3.12/tkinter "$D"/lib/python3.12/turtledemo \
             "$D"/lib/python3.12/ensurepip "$D"/lib/python3.12/lib-dynload/_tkinter*
      # N11: drop the shared libpython only if bin/python3.12 does not need it (it links it statically: verified for
      # x86_64 on 19 Nov; the import proof below fails the build if the guess is wrong on a builder).
      readelf -d "$D/bin/python3.12" | grep -q 'NEEDED.*libpython' || rm -f "$D"/lib/libpython3*
      env -i PATH=/usr/bin:/bin "$D/bin/python3.12" -I -m compileall -q -j0 "$D/lib/python3.12"
      # Import proof on the build arch (§10 rows 8 and 16): everything the helper, rearm, check and unlatch import.
      env -i PATH=/usr/bin:/bin "$D/bin/python3.12" -I -B -c 'import ezviz_source.main, ezviz_source.camera, ezviz_source.rearm, ezviz_source.check, ezviz_source.unlatch, pyezvizapi.streaming.local.session, Crypto.PublicKey.RSA, cryptography.hazmat.primitives.ciphers; print("ezviz-py import proof ok")'
```
**SF6 checked and not applied, with evidence (19 Nov).** The stripped tarballs, `install_only_stripped` 20261110 for aarch64 and x86_64, contain **no** `lib/python3.12/test` and no `badsyntax`/`bad_coding` file (`tar -tzf … | grep`: 0 hits; the agent's unpacked count agrees). On x86_64, the exact steps above (pip install of the 13 locked wheels, pip uninstall, prune, libpython removed) followed by `compileall -q -j0` exit **0**, and the import proof prints `ezviz-py import proof ok`; 96,581,785 B unpacked. The spec's "after removing tests" (spec L301) was written for a tree measured differently. The rm list therefore stays as it is; adding `test` would remove nothing.

`tests/w23-size.sh <base.snap> <new.snap>` prints `size: base=<B> new=<B> delta=<B>` and exits 1 if the delta is > 35,000,000 B. The spec's estimate is about +28 MB; the 35 MB limit leaves 25 % headroom.

- [ ] **Step 1: Write the failing static test** (`tests/w23-packaging.test.sh`, `t` style as in `tests/m9-packaging.test.sh`):
  - both pbs sha256 strings and the `20261110` / `3.12.16` names are present;
  - `requirements.txt` has the sha256 literal `b3282719e5c607e53f5de0943244075708bc2948ec6b4aa130050ce033ab4921` (`d5260d4` is on no remote and CI checks out shallow, so this test never calls `git show`; SF5);
  - apps `ezviz-check` (no `plugs:` key) and `disk-guard` (`daemon: oneshot`, `timer: "00:00-24:00/144"`, no plugs) exist;
  - the `go2rtc` app is unchanged (`plugs: [network, network-bind]`, no `stop-mode`: D17 relies on the default `KillMode=control-group`);
  - the import-proof line names `pyezvizapi.streaming.local.session`;
  - the pip install line does **not** start with `env -i` (SF7), and the libpython removal is guarded by `readelf` (N11);
  - `spike/bin/ezviz-source` execs `opt/ezviz-py/bin/python3.12 -I -B -m ezviz_source.main` and unsets `LD_LIBRARY_PATH`;
  - no `ezviz` path under `prime:` excludes;
  - `python3.11` is not referenced by any `spike/bin/ezviz-*` wrapper.
- [ ] **Step 2: Run and see it fail.** `bash tests/w23-packaging.test.sh`
- [ ] **Step 3: Implement** the yaml and the wrappers' final form.
- [ ] **Step 4: Run and see it pass** (about 12 checks). Also run `bash tests/m9-packaging.test.sh` (unchanged verdicts) and `shellcheck --severity=warning -x spike/bin/* snap/hooks/*`.
- [ ] **Step 5: A local pack is optional** (CI builds both arches in Task 22). If one is run: `snapcraft pack --build-for=amd64` under `flock`; then `tests/w23-size.sh` against the main-branch amd64 file; record the numbers.
- [ ] **Step 6: Commit** `feat(snap): ezviz-py part (CPython 3.12.16 + hash-locked wheels), ezviz-check and disk-guard apps (W-23 T20)`.

**Checkpoint A4:** a reviewer reads the yaml diff against spec §5 R1 and D13, and runs `tests/w23-packaging.test.sh`.

### Task 21: Item A results into the code (after gate GA)

**Files:**
- Modify: `spike/ezviz/ezviz_source/constants.py`, `spike/bin/go2rtc-config-gen.py` (`STARTTIMEOUT_S` only if it changes)
- Create: `docs/w23-findings.md` §A (the probe lines, verbatim, no values)
- Conditional: `spike/ezviz/ezviz_source/mpegts.py` + `tests/ezviz/test_mpegts.py`

**Interfaces / rules (from GA's probe lines):**
- `KEEPALIVE_FORM` = the form whose 60-minute run had `keepalive_failed=0` and `session_s >= 3540` on both cameras.
- `KEEPALIVE_COUNT` = max(4320, ⌈the survived session length ÷ 5 s⌉), capped so that `render_s × (count ÷ the probe's count) × 4 ≤ 3 s`. The × 4 is the assumed Pi/laptop CPU ratio [ESTIMATE]; S5 measures `published.t − attempt.t` on the hub.
- `STARTTIMEOUT_S` = 30 if every probe's `first_irap_s + render ≤ 20 s`, else 45 (§4.1).
- `TIMESTAMP_MODE` = `"rtp"` **if every probe shows `rtp_ts_monotonic ≥ 0.999` and `rtp_ts_step_p99_dev ≤ 360`** (10 % of 3600 at 90 kHz), else `"wallclock"`. That is the spec's rule [§4.4 L285], with no extra condition *(SF8)*. In the `"rtp"` case:
  - implement `mpegts.py`: PAT/PMT/PES with PTS = RTP ts;
  - `child_argv(…, "rtp")` uses `-f mpegts -i pipe:0`;
  - tests: PES PTS equals the ts, continuity counters wrap, and ffprobe (from the snap file) reads monotonic pts;
  - S2 check 1 re-runs with it.

  In both cases, record the consumer's pts-step p99 deviation from 40 ms (framemd5) under the chosen form in `docs/w23-findings.md` as the jitter evidence.
- **If no form held a session past about 30 s:** stop here and report to the maintainer (spec §9.1 A). Do not build further; the path is unusable under D4.

- [ ] **Step 1: Failing test:** `test_constants_match_findings` reads `docs/w23-findings.md`'s `chosen:` line (`chosen: form=<f> count=<n> starttimeout=<s> timestamps=<m>`) and asserts `constants.py` equals it.
- [ ] **Step 2: Run and see it fail**, **Step 3: set the constants** (and the conditional muxer with its tests if needed), **Step 4: run the whole `tests/ezviz` suite and S2 and see them pass.**
- [ ] **Step 5: Commit** `feat(ezviz): keepalive form/count, start timeout and timestamp mode from item A (W-23 T21)`.

### Task 22: CI, the artifacts and the local VM proofs

**Files:**
- Modify: `.github/workflows/lint-test.yml`
- Append to: `docs/w23-findings.md`

- [ ] **Step 1: CI step** (after "Run tests/*.test.sh and tests/test_*.py"):

```yaml
      - name: ezviz helper tests (venv from the hash lock)
        run: |
          PY=$(bash tests/ezviz/venv.sh)
          "$PY" -m unittest discover -s tests/ezviz -p 'test_*.py' -v
```
The `tests/*/*.test.sh` loop already picks up `tests/ezviz/*.test.sh` and the new `tests/hub/*.test.sh`. **What SKIPs in CI, and why** *(N6)*:
- `serve-ezviz.test.sh`: there is no local amd64 snap file, so no go2rtc or ffmpeg 8.0;
- `make_es` and every test that needs a real ffmpeg with libx265 or a decoder: Task 8's `test_media_packets_reassemble` uses `fixtures.SYNTH_ES` instead, and Task 12's `frames >= 600` assertion SKIPs with "no ffmpeg";
- `configure-ezviz.test.sh` SKIPs only if `python3 -m venv` is missing.

Expected in CI: every unit test in Tasks 1–7, 9 (with the fake camera), 10 (fake ffmpeg), 11, 13, 14, 16, 17 and 19 runs. The implementer records the exact `Ran N tests … (skipped=M)` line of the first green CI run in `docs/w23-findings.md`.

**§10 row 25, the evidence** *(N10)*, also to be copied into `docs/w23-findings.md`:
- research on 19 Nov fetched go2rtc tag v1.9.14 (source tarball) and all 43 modules in its `go.mod` (zips from proxy.golang.org at the pinned versions), and grepped them for `LockOSThread`;
- 0 hits in go2rtc;
- in the modules, only a symbol table (`x/tools` `internal/stdlib/manifest.go`), test files (`x/sys` `unix/syscall_linux_test.go`) and Windows-only code (`x/sys/windows`);
- in the Go stdlib at go1.25.6, the only Linux use is `runtime/signal_unix.go` `ensureSigM`, a goroutine that never exits;
- go2rtc builds with `CGO_ENABLED=0` (`scripts/build.sh` L28).

So no goroutine exits holding a locked thread, and `Pdeathsig` cannot fire early. This was read, not run, and the Go version of the release binary is inferred from `build.yml` (the binaries are UPX-packed).

- [ ] **Step 2: Whole-branch review** (user sequence 6): one fresh reviewer on the full diff, one fix wave, then a scoped re-review.
- [ ] **Step 3: Merge `origin/main` into `feat/hub-real-cameras`** (user sequence 7). Resolve by adapting this branch's code only, then re-run every suite above.
- [ ] **Step 4: Push and open the PR — the orchestrator only, on the maintainer's go.** The PR build (`pr-build-snap.yml`) builds amd64 and arm64 on Launchpad. Each arch's build log must contain `ezviz-py import proof ok`; that is §10 row 16 and the arm64 half of row 8 for imports.
- [ ] **Step 5: Artifact checks** on the laptop (orchestrator):
  - the sha256 of both files;
  - `tests/w23-size.sh` against the current main amd64 and arm64 files: delta ≤ 35 MB;
  - `unsquashfs -l` shows `opt/ezviz-py/bin/python3.12` and no `opt/ezviz-py/lib/libpython3`.
- [ ] **Step 6: Local VM proofs** (laptop VMs only; no hub). Under flock, by the orchestrator or a worker the controller names:
  - **amd64 LXD gate VM** (`m8-gate`; see the gate-VM lessons: `snap wait system seed.loaded` first, no frigate installed before the run). Install the **main** amd64 file as `x1` (`--dangerous`), then the PR file (`x2`). Then:
    - (a) `systemctl show -p KillMode,KillSignal snap.frigate.go2rtc` → `KillMode=control-group`, `KillSignal=15` (§10 row 24);
    - (b) start a fake camera in the VM. Run it with the snap's own interpreter, which has pycryptodome: `sudo /snap/frigate/current/opt/ezviz-py/bin/python3.12 -I /mnt/repo/tests/ezviz/fakecam.py --port 18000 …`. Write a camera file pointing at `127.0.0.1:18000` as root 0600, then `snap start frigate.go2rtc` → within 60 s the ledger has `login_ok` and `published`, and `snap run --shell frigate.go2rtc -c '"$SNAP/bin/ezviz-rearm" --list'` prints `preload: cam1`. This is the confined S2 subset (§10 rows 18, 19 under AppArmor). Then `snap stop frigate.go2rtc` → the ledger ends `stop`.
    - (c) `snap set frigate disk-floor-gib=100000` → expect the hook to refuse it (> 10000). Then `disk-floor-gib=<free GiB + 10>`, `snap start frigate`, and within 10 min `frigate.frigate` is inactive and disabled, with the guard line in `journalctl -u snap.frigate.disk-guard` (§10 row 14, `snapctl stop` from an app).
    - (d) `snap revert frigate --revision x1` → revision x1 is current and its services start as before (§10 row 15). Then remove the snap.
  - **arm64 TCG VM** (`tests/arm64-vm/battery.sh --file <arm64 file> <sha256>`, `SPIKE_TIME_SCALE` as the README says): plus the (b) subset in the guest. This gives aarch64 runtime and confinement (§10 row 8). It is slow; if it does not finish within the session budget, record it as not run and rely on S5.
  - Record every result with the commands' output lines in `docs/w23-findings.md` §gates.
- [ ] **Step 7: Commit** `ci(ezviz): run the helper suite; findings: artifact sizes and VM proofs (W-23 T22)`.

The maintainer merges the PR (user sequence 7). The arm64 file CI builds for the merge commit is `x2` (P14); its sha256 goes on the card.

---

## Part B — the item A gate and the hub steps (orchestrator and maintainer only)

Shared conventions:
- `X` stands for `M7C_HUB_SOCK=<socket> M7C_HUB_TARGET=<target> tests/hub/ssh-exec.sh`, the operator's existing master only. The socket and target are never written down.
- **Every step needs the maintainer's direct go for that step**, given on the card at the time, and a working hub login at that time (card item 7).
- **"Card"** means the orchestrator offers the command with `offer_command` and the maintainer taps Run. The key file is read only inside make-config or probe-run (D15).
- **Stop rules, always on during S5–S13:**
  1. a watcher TRIP (act mode stops frigate itself);
  2. any `auth_fail` or `latched=1` in `ezviz-ledger.sh` → **report at once; no stop** (spec §9.3: "A latch is not a stop"). The latched camera stays dark and the other keeps recording; the running step's verdict is FAIL, and only the maintainer clears the latch *(SF9)*;
  3. `max_attempts_any_60min > 3` → `X exec 'snap stop --disable frigate'`, then report (it should be impossible; it means a bug);
  4. any new `Undervoltage detected` line (P12; watcher TRIP, or power-check exit 1) → `X exec 'snap stop --disable frigate'`, and tell the maintainer at once. Power-check exit 4 (INCONCLUSIVE) is reported at once and the step does not pass;
  5. the watcher going BLIND → tell the maintainer at once (Frigate keeps running under the quota and the D13 guard, spec §9.3).
- Rollback is per spec §9.3, with P10's order for the stand-in: `X exec 'rm -rf /var/snap/frigate/current/ezviz'`, then clip-mode make-config.

### B0. Gate GA — item A, the long-session probe (laptop to the cameras; each run is the maintainer's card)

| Run | Card command | Stop rule / pass |
|---|---|---|
| A1 | `bash /<repo>/tests/ezviz/probe-run.sh cam1 63 extend` | 1 login. Pass: `end=stop session_s>=3780 keepalive_failed=0`. If it ends before 120 s with `session_end` → A1b next hour |
| A1b (only if A1 failed) | `bash /<repo>/tests/ezviz/probe-run.sh cam1 63 repeat` | as A1. If it also fails → **STOP: report to the maintainer** (spec §9.1 A) |
| A2 | `… probe-run.sh cam2 63 <form>` | as A1 |
| A3 | `… probe-run.sh both 63 <form>` | both lines pass, 1 login each |

The probe enforces the budget itself, with persistent state under `$M7C_ENV_DIR/w23-probe-state`. **That budget is separate from the hub's ledger (P15, SF11):** before B2 and before every hub start while GA runs can still happen, `bash tests/ezviz/probe-run.sh --status` must show `age_s ≥ 3600` and `latched=0` for both cameras, and no probe runs while the hub helpers run. Results (the probe lines only) go to `docs/w23-findings.md` §A, and then Task 21 runs.

### B1. Before the hub steps

| Step | Who | Command | Pass / stop |
|---|---|---|---|
| H-power | maintainer + orchestrator | the maintainer reports the PSU/cable check (card item 8); then `tests/hub/power-check.sh --since <epoch of the check, recorded>` | `power-check: PASS` (0 undervoltage, 0 boots in the window); exit 1 → stop and report; exit 4 (INCONCLUSIVE) → report, nothing starts |
| H-probe | orchestrator | `bash tests/ezviz/probe-run.sh --status` (P15) | both cameras `age_s ≥ 3600`, `latched=0` |
| H-clear | orchestrator (go) | `X exec 'snap services frigate; du -sh /var/snap/frigate/common/media/frigate/recordings; ls /var/snap/frigate/common/media/frigate/recordings'`, then `X exec 'rm -rf /var/snap/frigate/common/media/frigate/recordings/2026-11-14 /var/snap/frigate/common/media/frigate/recordings/2026-11-15'` (only the stand-in trial dates the listing shows; frigate stopped) | about 15 GB freed (card item 6). Frigate's DB may keep rows for the removed files until its own retention expires them [UNVERIFIED]; S6 checks that the UI lists recordings without errors |

### B2. S3 — install `x2`

| # | Command | Expected |
|---|---|---|
| 1 | laptop: `sha256sum <arm64 file>` equals the CI artifact's (P14) | equal |
| 2 | `X put <arm64 file> /var/tmp/frigate-w23-x2.snap` | put ok (ssh-exec checks the sha on the hub) |
| 3 | `X exec 'snap install --dangerous /var/tmp/frigate-w23-x2.snap && snap refresh --hold frigate'` | `x2` installed |
| 4 | `X exec 'snap list --all frigate; snap connections frigate; snap quota frigate-mem; snap services frigate; systemctl show -p KillMode,KillSignal snap.frigate.go2rtc; systemctl list-timers snap.frigate.disk-guard.timer --no-pager'` | `x2` current, `x1` listed; raw-usb, hardware-observe, mount-observe and shm-private connected; 4 GB and 2 × 100 %; frigate and go2rtc inactive and disabled; `KillMode=control-group`, `KillSignal=15` (if not: STOP, re-check D17 before S5); the guard timer listed |
| 5 | `tests/hub/probe.sh --sha <sha>` (frigate stopped) | its PASS lines as for `x1` (M7C-F H1–H4) |

### B3. S4 — the config switch (the maintainer's card)

The card command: `M7C_SOURCE=ezviz bash /<repo>/tests/hub/make-config.sh`, run in the session that holds the ssh master, with `M7C_HUB_SOCK` and `M7C_HUB_TARGET` already in that shell's environment, as for the M7c make-config runs. The card text names neither value.
Pass: `make-config: ok`, `camera files: 2 written (root, 0600, sha256 matched)`, `ezviz-check cam1: ok`, `ezviz-check cam2: ok`, `validate-config rc=0 valid`. Any other exit: stop and report the exit code and words.

### B4. S5 — the first start (and S7 starts here)

| # | Command | Expected within 5 min |
|---|---|---|
| 0 | start the watcher: `tests/hub/watch.sh --swap-baseline-mb <H0> --act --log <evidence>/watch-s5.log` (background) | sampling |
| 1 | `X exec 'snap start frigate'` (not `--enable`); note the epoch `T5` | — |
| 2 | `tests/hub/observe.sh --out <ev>/s5 --execs 0 --helpers 2 --fps cam1=5,cam2=5` | the 4 units active; both cameras `camera_fps` ≈ 5, `skipped_fps` 0; 2 helpers |
| 3 | `tests/hub/ezviz-ledger.sh --since T5` | per camera `login_ok_since=1`, `attempts_since=1`, `ends=` empty, `latched=0` |
| 4 | `X exec 'snap run --shell frigate.go2rtc -c "\$SNAP/bin/ezviz-rearm --list"'` | `preload: cam1,cam2` |
| 5 | `X exec 'snap run frigate.ffprobe -v error -rtsp_transport tcp -select_streams v:0 -show_entries stream=codec_name,width,height -of csv=p=0 rtsp://127.0.0.1:8554/cam1'` (and `cam2`) | `hevc,<w>,<h>`, recorded per camera (P11); the ledger still shows 1 `login_ok` each (0 logins for the probe) |
| 6 | `tests/hub/power-check.sh --since T5` (T5 recorded at step 1; all boots since then) | `power-check: PASS`; exit 4 means the step does not pass |
| 7 | from the ledger: `published.t − attempt.t` per camera | recorded (Task 21's start budget on the real Pi) |

### B5. S6 and S7 — the maintainer's eyes; the Coral

- **S6:** the maintainer opens the UI: live view of both cameras shows the right scenes, and one recorded clip per camera from the last hour plays. The maintainer passes S6 on the card.
- **S7:** `observe.sh` snapshots during the soak. Pass: at least one with `detection_fps > 0` **and** `inference_speed` ≠ 10 ms. The maintainer confirms one real detection in Review.

### B6. S8 — the 24-hour soak

| # | When | Command | Expected |
|---|---|---|---|
| 1 | T5 + 30 min, + 6 h, + 24 h | `observe.sh --prev <previous> --execs 0 --helpers 2` | PASS; anon + shmem recorded |
| 2 | ≥ T5 + 2 h, **separate go** | `X exec 'snap restart frigate.go2rtc'`, then `ezviz-ledger.sh --since <restart>` and the `--list` command | per camera exactly **1** new `login_ok`, preceded by `stop`; `preload: cam1,cam2` within 2 min |
| 3 | after 2, **separate go** | `X exec 'snap restart frigate.frigate'` | **0** new `login_ok` on both ledgers |
| 4 | T5 + 24 h | `ezviz-ledger.sh --since T5`; `power-check.sh --since T5`; the watcher log | per camera `max_attempts_any_60min ≤ 3` and `attempts_since ≤ 12` *(N8)*; `power-check: PASS` (0 undervoltage, 0 boots since T5); 0 TRIP; `NRestarts` 0 for frigate and go2rtc (manual restarts excluded); HA 200 in ≥ 99 % of samples with no 3 failures in a row; undervoltage 0 |
| 5 | T5 + 24 h | `tests/hub/coverage.sh --since T5 --hours 24` (Task 19) | `coverage cam1: ≥ 99 %`, `coverage cam2: ≥ 99 %` |

### B7. S9 to S13

| Step | Command (each on its own go) | Pass |
|---|---|---|
| S9 | `X exec 'df -P -B1G /var/snap/frigate/common/media/frigate'` → free F; `X exec 'snap set frigate disk-floor-gib=<F+10>'`; wait ≤ 10 min; `X exec 'snap services frigate.frigate; journalctl -u snap.frigate.disk-guard -n 3 --no-pager'`; `X exec 'snap set frigate disk-floor-gib=20'`; restart `X exec 'snap start frigate'` | frigate inactive and disabled with one guard line; floor back to 20 |
| S10 | `X exec 'snap stop frigate'`; then within 10 s `X exec 'pgrep -fc ezviz_source.main \|\| true'`; `ezviz-ledger.sh`; `X exec 'journalctl -u snap.frigate.frigate -n 20 --no-pager \| grep -c "result=ok"'` | 0 helpers; each ledger `last=stop`; `result=ok` present; the maintainer plays the last segment («yours»). A Frigate SIGKILL after 30 s is recorded, not failed |
| S11 | `X exec 'snap start --enable frigate'`; **the maintainer reboots the hub**; then within 5 min of boot: observe (`--helpers 2`), `ezviz-ledger.sh --since <boot>`, `--list` | all services active; both cameras at fps; frigate `NRestarts` ≤ 1; 1 `login_ok` each; `preload: cam1,cam2`; `tests/hub/power-check.sh --since <epoch before the reboot> --allow-boots 1` → PASS |
| S12 | the maintainer opens LAN Live View on one camera for 1 min; the orchestrator runs observe before and after, and `ezviz-ledger.sh` | recorded: does the app play; does Frigate continue. Pass unless a helper latched |
| S13 | `X exec 'snap stop frigate'`; the maintainer's card `M7C_SOURCE=ezviz M7C_RETAIN_DAYS=3 … make-config.sh`; `X exec 'snap start --enable frigate'`; `X exec 'snap get frigate disk-floor-gib \|\| echo default-20'` | make-config ok with `continuous.days 3`; services active; guard floor 20 |

---

## What this plan cannot verify offline

- Whether the cameras keep a session past 30 s with either keepalive form, and how the HCNetSDK addend continues (item A, GA).
- Whether the cameras' RTP clock is 90 kHz and steady, whether they send TRAIL_N bodies (`00 01`), which the library and our reassembler skip, and whether audio is present on port 8000 (item A).
- The fake camera's fidelity: its login side is built from the library's own client, so S2 proves our code against a protocol model, not the cameras (§10 row 21).
- The keepalive render time on the Pi (laptop measurement × an assumed 4, checked at S5).
- `snapctl stop --disable` from an app, `snap revert` between two `--dangerous` revisions, and `KillMode` under frigate's real unit. These are proved on the amd64 gate VM, not on the hub, until S3 and S9.
- aarch64 runtime under confinement, unless the TCG VM run finishes (otherwise S5 is the first proof).
- Frigate's DB rows for the deleted stand-in recordings (H-clear).
- Anything about the hub's power supply.
- A wall clock that is **behind** at boot (no RTC battery after a power loss, before NTP syncs): attempts are stamped in the past and leave the window early once NTP corrects the clock. No test covers it. The cap would then allow up to 3 more logins inside the real hour once. Follow-up for the maintainer *(N9)*.
- `coverage.sh`'s Frigate route (`/api/<camera>/recordings`, `start_time`/`end_time`) is read from the plan, not from v0.18.2 source; it must be confirmed in Task 19.
- The helper's real end paths against the library: `main.py` ran on 19 Nov against stand-in camera and output modules only.
- The Launchpad proxy behaviour behind SF7 (taken from the existing spike-wheels part, not run).

---

## Self-review (done while writing)

- **Spec coverage:**

  | Spec item | Task(s) |
  |---|---|
  | D1–D3 | 6, 9, 11 |
  | D4 | 4 |
  | D5 | 1, 20 |
  | D6 | 7, 9, 11 |
  | D7 | 2, 18 |
  | D8 | 13 |
  | D9 | P11, S5 |
  | D10 | P4 `-an`, annexb drops non-video |
  | D11 | P14, S3 |
  | D12 | 18 |
  | D13 | 16 |
  | D14, D15 | Part B |
  | D16 | nothing touches a camera setting |
  | D17 | 5, 11, 15 |
  | D18 | 6 |
  | D19 | 14, 15 |
  | D20 | 13, 15 |
  | D21 | 4, 6 |
  | D22 | 10, 11 |
  | T-END E1–E17 | 4, 11 |
  | §4.5 | 6, 9, 11 |
  | S1 | 4, 6, 11 |
  | S2 | 15 |
  | S14 | 5, 11 |
  | S15 | 3, 11 |
  | S3–S13 | Part B |
  | L1 | 5, 11 |
  | torn line / torn `login_ok` | 3, 11 |
  | undervoltage | 19, B |
  | §10 rows 14, 15, 16, 24 | 22 |
  | §10 row 25 | settled by source; evidence in Task 22 (N10) |
  | SF1–SF13, N1–N12 | marked where they land; SF6 checked and not applied (Task 20, with evidence) |
- **Type consistency:** `admit` → `Admitted`; `decide` → `Decision`; `classify` → `str`; `Output.write_au(bytes, bool)`; the `Reassembler.push` and `AccessUnits.push` names are used the same way in Tasks 7, 9, 11 and 12.
- **Proportion and code** *(SF13)*: full code for the lockout core and the hub checks, all of it run on 19 Nov (95 unit tests OK, 4 shell suites ok, 26 + 6 mutations red, 1 equivalent mutation explained). The protocol and plumbing modules get signatures and tests only; the header states this departure for the maintainer.
