# W-23 Hub Real Cameras Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Feed the hub's Frigate from both real cameras with image encryption still ON. A snap-owned helper, `ezviz-source`, turns each camera's clear port-8000 LAN Live View stream into a loopback RTSP publish. go2rtc keeps it open (preload, re-armed) under a hard login budget. The hub is then switched over, soaked for 24 h and put into production.

**Architecture:** The helper runs as a go2rtc `exec:` child under its own CPython 3.12 inside the frigate snap (OD1/R1). Before any camera contact it passes a stdlib-only gate: session lock → camera file → ledger decision (T-END and D4) → an `attempt` record fsynced to disk. It then logs in with the pinned pyEzvizApi 2.0.0, reassembles IDMX/FU into Annex-B H.265 with no decrypt step, and pipes it to the bundled ffmpeg 8.0, which publishes `-c copy -an -f rtsp {output}`. The go2rtc config generator emits the stream and its `preload`, and forces the API settings the re-arm loop needs. A small disk-guard timer app, an `ezviz-check` app, a configure-hook unlatch, `make-config.sh` `ezviz` mode and the hub tools complete it.

**Tech Stack:** Python 3.12.16 (python-build-standalone 20261110) with pyEzvizApi 2.0.0 and its 13 hash-locked wheels; go2rtc 1.9.14; ffmpeg 8.0 (n8.1.1 tree); POSIX sh (snap wrappers, hooks); bash (tests, hub tools); snapcraft on core26; unittest; yq v4 (laptop).

**Spec:** `docs/superpowers/specs/2026-11-16-hub-real-cameras-design.md` at `8f539284c8e3d39bfb80085cc7628c65eb731812`. It was approved by the maintainer on 19 Nov 2026 with OD1 = R1 (separate Python 3.12, about +28 MB), OD2 = 3 days, OD3 = file install as `x2`, held and stopped, and OD4 = video only. Read the spec first. Every task cites the D-numbers, T-END rows (E1–E17) and S-steps it implements. **Where this plan and the spec disagree, the spec wins, except for the plan decisions P1–P14 below, each of which says why.**

---

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
- **Heavy suites** (anything that extracts the amd64 snap file, starts go2rtc, runs the fake camera for more than 60 s, or boots a VM) run under `flock -w 3600 /tmp/claude-1000/chim-suites.lock`.
- **Shell scripts** pass `shellcheck --severity=warning -x`, as the lint job requires (`.github/workflows/lint-test.yml`).

## Review Focus

These are inputs the spec implies but does not test, most likely first. Each one has its test in the owning task.

1. **The Pi's wall clock jumps at boot** (no RTC battery; NTP corrects minutes later). A ledger record dated in the future must count as inside the 3600 s window and the spacing, so a clock that went backwards can never allow a 4th login. Expected: refusal until real time passes the record. *Test: Task 4 `test_future_dated_attempt_counts_in_window_and_spacing`.*
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

  *Why:* these are the 2.0.0 exception sites (`discovery.py` L432-436, `requests.py` L2356-2365, `session.py` L1046-1083, L1435-1444). The W-20 run 1 produced exactly that `auth_fail` message. A lockout reads the same as a wrong code, and latching it is correct [E2, D4].
- **P4. ffmpeg arguments, wallclock form:** `[FFMPEG, "-hide_banner", "-loglevel", "error", "-use_wallclock_as_timestamps", "1", "-f", "hevc", "-i", "pipe:0", "-c", "copy", "-an", "-f", "rtsp", "-rtsp_transport", "tcp", OUTPUT]`. stdout and stderr go to `DEVNULL`. The environment is exactly `{"PATH": "/usr/bin:/bin", "LD_LIBRARY_PATH": $EZVIZ_CHILD_LD_LIBRARY_PATH}`, with `prctl(PR_SET_PDEATHSIG, SIGTERM)` set in `preexec_fn`. *Why:* §4.4 (b) needs no muxer of our own. Form (a), RTP timestamps into MPEG-TS, is built in Task 21 **only if item A shows usable RTP timestamps and S2 or item A shows a defect with (b)** [§4.4: "the plan picks (a) if the packets carry usable timestamps, and otherwise (b)" — the timestamp form is chosen in Task 21 from item A's evidence, as the spec requires].
- **P5. Keepalive extension is a parameter, not a guess.** The plan is `dataclasses.replace(base, steps=…)` with the media step's `keepalive_templates` replaced by `KEEPALIVE_COUNT` templates `HcNetSdkCommandPortControlTemplate(command_id=0x30006, addend_delta=d)`. The form is `"extend"` (`d = 10 + 6*i`) or `"repeat"` (the first six as built, then `d = 40` repeated). Item A chooses the form; Task 21 sets `KEEPALIVE_FORM` and `KEEPALIVE_COUNT`. The count must cover ≥ 6 h (4320 at 5 s) so that a 24 h soak needs ≤ 4 planned re-logins per camera, under S8's ≤ 12 per 24 h. The library renders every frame up front in pure Python (`session.py` L307-315), so Task 9 measures the render time and Task 21 caps the count so that rendering takes ≤ 3 s on the hub [§4.4, §2.2 item 4].
- **P6. An unlatch resets the latch row and the ladder.** The configure hook appends an `unlatch` record, and the policy counts the row and the ladder only after the last `unlatch`. *Why:* the spec says an operator clears a latch on purpose (§4.2) but not what happens to the row. If the row stayed at 3, the next decision would latch again at once and the unlatch would do nothing. The cap and the spacing still count every `attempt`, so an unlatch never buys an extra login inside the hour.
- **P7. Ladder rung 4 and above** waits until the third-most-recent `attempt` + 3600 s, which treats the cap as full. *Why:* spec D4 says "then until the 3-per-hour window allows another". Reading it as "whatever the window allows now" would let a 4th consecutive failure retry at once whenever the earlier attempts are spread over just more than an hour. The conservative reading costs at most one hour of darkness, the cap's own price.
- **P8. A damaged non-last ledger line refuses** with class `ledger_damaged` (exit 75, no contact) until an operator moves the file away (`sudo mv <ledger> <ledger>.damaged`; the next decision starts empty, and the latch file still applies). *Why:* the spec covers only a torn **last** line (§4.3). Skipping a damaged middle line could drop an `attempt`. The latch file stays independent of the ledger, so moving the ledger never clears a latch (Review Focus 2).
- **P9. The latch file is the truth; the ledger is the evidence.** A decision is latched if `<name>.latch` exists **or** an `auth_fail` or a full row lies after the last `unlatch`. When the policy finds a full row and no `latch` record after the last `unlatch`, the gate creates the latch file and appends `latch` once. The helper itself writes `auth_fail`, the latch file and `latch` in one critical section (E2). *Why:* §4.2 says the hook "removes the latch file", and trimming the ledger (§4.3) must never lose a latch.
- **P10. make-config `ezviz` mode also requires `frigate.go2rtc` inactive, and the clip and cameras modes refuse (new exit 10) while camera files exist on the hub.** *Why:* the generator emits camera streams from the camera files whatever `config.yml` says (D8). A rollback to clip mode with camera files left behind would keep logging in to the cameras. A camera file written while go2rtc runs is picked up only by the re-arm, which PUTs a name with no stream (500, no contact) until go2rtc restarts. **This changes the order of spec §9.3's first rollback row:** remove `/var/snap/frigate/current/ezviz` first, then run clip-mode make-config. Recorded here and in the report, not changed in the spec.
- **P11. Detect size.** make-config leaves `detect.width`/`height` unset, so Frigate 0.18.2 probes the stream at start, as the clip mode already does. S5 records `frigate.ffprobe` output for each camera as the setup measurement. The probe reads go2rtc's restream, which is already running because of the preload: 0 logins [D9].
- **P12. Undervoltage is a stop rule during the hub steps.** `watch.sh` trips on a new `Undervoltage detected` kernel line (in `--act` mode: `snap stop --disable frigate`), and `tests/hub/power-check.sh` gives S5 and S8 their read-only verdict. *Why:* the hub logged undervoltage on 17 and 18 Nov, and on 18 Nov storage writes stopped after it (card W-23 item 8). Frigate's load (2 cores, the Coral, the NVMe) adds current draw, and a stopped Frigate costs nothing but recording.
- **P13. The optional E7 discriminator is NOT built.** It would change T-END's latch-row rule, which is in the approved spec. It is recorded as a follow-up for the maintainer: a go2rtc crash loop that SIGTERMs three starts in a row before publish would latch a valid camera.
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
| `tests/hub/coverage.sh` (+ `.test.sh`) | per-camera recording coverage of a window from Frigate's recordings API, numbers only (S8) |
| `tests/hub/watch.sh`, `observe.sh` (+ tests) | modify: undervoltage trip; `--helpers N` |
| `tests/disk-guard.test.sh`, `tests/configure-ezviz.test.sh`, `tests/w23-packaging.test.sh`, `tests/w23-size.sh` | hermetic tests of the app, the hook, the packaging and the size |
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
- Create: `spike/ezviz/requirements.txt` (`git show d5260d4:docs/superpowers/plans/ezviz-t10/requirements.txt > spike/ezviz/requirements.txt`)
- Create: `spike/ezviz/ezviz_source/__init__.py`, `constants.py`, `paths.py`
- Create: `tests/ezviz/venv.sh`, `tests/ezviz/_path.py`
- Test: `tests/ezviz/test_runtime.py`

**Interfaces:**
- Produces: `tests/ezviz/venv.sh` prints the venv's python path on stdout (default `${W23_VENV:-$HOME/.cache/frigate-w23/venv}`). It creates the venv with `python3.12 -m venv`, runs `pip install --require-hashes --only-binary=:all: --no-deps -r spike/ezviz/requirements.txt`, and writes `<site-packages>/ezviz_source.pth` containing the absolute `spike/ezviz` path. It is idempotent: it rebuilds if the lock's sha256 differs from `<venv>/lock.sha256`.
- Produces `constants.py`, with these exact values:
  ```python
  CAP_ATTEMPTS = 3; WINDOW_S = 3600; SPACING_S = 60
  LADDER_S = (60, 300, 900); LADDER_RESET_PUBLISHED_S = 3600; LADDER_RESET_IDLE_S = 3600
  FIXED_WAIT_S = 60; LATCH_ROW = 3
  SOCKET_TIMEOUT_S = 10.0; PUBLISH_HOLD_S = 5.0; FFMPEG_EXIT_GRACE_S = 1.0; ALARM_S = 4
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
- Produces `paths.py`: `camera_dir() -> Path` (`$SNAP_DATA/ezviz/cameras`), `state_dir() -> Path` (`$SNAP_COMMON/ezviz/state`), `ffmpeg() -> str` (`$SNAP/usr/lib/ffmpeg/8.0/bin/ffmpeg`). Each raises `KeyError` if its variable is unset.

- [ ] **Step 1: Write the failing test**

```python
# tests/ezviz/test_runtime.py
import _path, hashlib, importlib.metadata as md, subprocess, unittest
from ezviz_source import constants as C, paths

class TestRuntime(unittest.TestCase):
    def test_lock_is_the_w20_lock(self):
        want = subprocess.run(["git", "show", "d5260d4:docs/superpowers/plans/ezviz-t10/requirements.txt"],
                              capture_output=True, check=True).stdout
        self.assertEqual(open(_path.REPO / "spike/ezviz/requirements.txt", "rb").read(), want)
    def test_pinned_wheel_hash_in_lock(self):
        self.assertIn("ed7c309a1af18e0cdc3665a87d7a1c30c21581ba80a25115d748f76ed2f349f8",
                      (_path.REPO / "spike/ezviz/requirements.txt").read_text())
    def test_pyezvizapi_200_installed(self):
        self.assertEqual(md.version("pyezvizapi"), "2.0.0")
    def test_budget_constants(self):
        self.assertEqual((C.CAP_ATTEMPTS, C.WINDOW_S, C.SPACING_S, C.LADDER_S, C.LATCH_ROW),
                         (3, 3600, 60, (60, 300, 900), 3))
    def test_exit_codes(self):
        self.assertEqual((C.EXIT_STOP, C.EXIT_TEMP, C.EXIT_AUTH, C.EXIT_CONFIG), (0, 75, 77, 78))
    def test_paths_from_env(self):
        env = {"SNAP": "/s", "SNAP_DATA": "/d", "SNAP_COMMON": "/c"}
        with unittest.mock.patch.dict("os.environ", env):
            self.assertEqual(str(paths.camera_dir()), "/d/ezviz/cameras")
            self.assertEqual(str(paths.state_dir()), "/c/ezviz/state")
            self.assertEqual(paths.ffmpeg(), "/s/usr/lib/ffmpeg/8.0/bin/ffmpeg")
```
`tests/ezviz/_path.py` puts `REPO/spike/ezviz` first on `sys.path`, defines `REPO`, and imports `unittest.mock`.

- [ ] **Step 2: Run it and see it fail**

Run: `PY=$(bash tests/ezviz/venv.sh) && "$PY" -m unittest discover -s tests/ezviz -p 'test_runtime.py' -v`
Expected: FAIL (`venv.sh` or `ezviz_source` missing).

- [ ] **Step 3: Implement `venv.sh`, the lock copy, `constants.py` and `paths.py`** with the values above.

- [ ] **Step 4: Run it and see it pass** (the same command; expected: 6 tests OK).

- [ ] **Step 5: Commit**

```bash
git add spike/ezviz tests/ezviz
git commit -m "feat(ezviz): helper runtime lock, dev venv and constants (W-23 T1)"
```

### Task 2: Camera file

**Files:** Create `spike/ezviz/ezviz_source/camfile.py`. Test `tests/ezviz/test_camfile.py`.

**Interfaces:**
- Produces: `@dataclass(frozen=True, repr=False) class Camera: name: str; host: str; port: int; serial: str; login: str`. `__repr__` returns `Camera(<name>)` only (§4.5).
- Produces: `class CameraFileError(Exception)` carrying `.cls in {"missing", "owner", "mode", "shape"}`. Its `str()` is the class only.
- Produces: `load(name: str, directory: Path) -> Camera`. The file must:
  - be a regular file, not a symlink (`os.open(…, O_RDONLY | O_NOFOLLOW)`);
  - have `st_uid == os.geteuid()`, which is 0 in production;
  - have mode `0o600` exactly;
  - consist of lines `key=value`, `#` comments and blank lines, with exactly the keys `host` (an IPv4 literal; every octet `0|[1-9][0-9]{0,2}` and ≤ 255), `port` (1–65535), `serial` (`^[A-Za-z0-9_.-]{1,64}$`) and `login` (`^[A-Za-z0-9]{4,32}$`, make-config's code shape). Any duplicate or unknown key fails `shape`.

- [ ] **Step 1: Write the failing tests**

```python
class TestCamfile(unittest.TestCase):
    # mk(dir, name, text, mode=0o600) writes a file; GOOD = "host=192.0.2.11\nport=8000\nserial=TESTCAM-0001\nlogin=QZCNRA\n"
    def test_good(self):           c = load("cam1", mk(GOOD)); self.assertEqual((c.host, c.port, c.serial, c.login), ("192.0.2.11", 8000, "TESTCAM-0001", "QZCNRA"))
    def test_repr_has_no_value(self): self.assertEqual(repr(load("cam1", mk(GOOD))), "Camera(cam1)")
    def test_missing(self):        self.assertCls("missing", lambda: load("cam1", empty_dir()))
    def test_mode_644(self):       self.assertCls("mode", lambda: load("cam1", mk(GOOD, mode=0o644)))
    def test_symlink_refused(self): self.assertCls("missing", lambda: load("cam1", symlinked(GOOD)))
    def test_unknown_key(self):    self.assertCls("shape", lambda: load("cam1", mk(GOOD + "x=1\n")))
    def test_duplicate_key(self):  self.assertCls("shape", lambda: load("cam1", mk(GOOD + "port=8001\n")))
    def test_hostname_refused(self): self.assertCls("shape", lambda: load("cam1", mk(GOOD.replace("192.0.2.11", "cam.local"))))
    def test_octet_300(self):      self.assertCls("shape", lambda: load("cam1", mk(GOOD.replace(".11", ".300"))))
    def test_login_shape(self):    self.assertCls("shape", lambda: load("cam1", mk(GOOD.replace("QZCNRA", "QZ CN"))))
    def test_error_text_is_class_only(self):
        try: load("cam1", mk(GOOD.replace("QZCNRA", "QZ!!")))
        except CameraFileError as e: self.assertEqual(str(e), "shape"); self.assertNotIn("QZ", repr(e.args))
    def test_comment_and_crlf(self): self.assertEqual(load("cam1", mk("# x\r\n" + GOOD.replace("\n", "\r\n"))).port, 8000)
```
The owner check is tested by monkeypatching `os.geteuid` to return `os.getuid() + 1` (expect `owner`).

- [ ] **Step 2: Run and see it fail.** `"$PY" -m unittest discover -s tests/ezviz -p 'test_camfile.py' -v` → ImportError.
- [ ] **Step 3: Implement `load` and `Camera`** (stdlib only: `os`, `re`, `stat`).
- [ ] **Step 4: Run and see it pass** (13 tests).
- [ ] **Step 5: Commit** `feat(ezviz): camera file reader and validator (W-23 T2)`.

### Task 3: Ledger I/O

**Files:** Create `spike/ezviz/ezviz_source/ledger.py`. Test `tests/ezviz/test_ledger.py`.

**Interfaces:**
- Produces: `class LedgerDamaged(Exception)` (P8), and `class LedgerIOError(Exception)`, which wraps an `OSError` on append.
- Produces: `parse(data: bytes) -> list[dict]`, the torn-line rule (§4.3):
  - drop a last line that has no trailing `\n` or does not parse as a JSON object with a numeric `t` and a string `ev`;
  - a **non-last** bad line raises `LedgerDamaged`.
- Produces: `class Ledger`, a context manager holding `flock(LOCK_EX)` on the ledger file, opened `O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW`, mode 0600:
  - `Ledger(path: Path)`
  - `.records() -> list[dict]`
  - `.append(rec: dict) -> None`: before writing, truncate the file back to its last `\n` if it does not end in one. Then write one `json.dumps(rec, separators=(",", ":")) + "\n"`, `os.fsync(file)` and `os.fsync(dir)`. An `OSError` becomes `LedgerIOError`.
  - `.trim(now: float, keep_from: float) -> None`: keep records with `t >= now - TRIM_KEEP_S` or `t >= keep_from`. Write a temp file, fsync it, `os.replace` it over the ledger, fsync the dir.
- Record shape: `{"t": float, "ev": str, "dur": float | None}`, plus `"syn": True` only on synthetic records (§4.3).

- [ ] **Step 1: Write the failing tests**

```python
def test_roundtrip(self): append two records; self.assertEqual([r["ev"] for r in L.records()], ["attempt", "login_ok"])
def test_torn_last_line_no_newline_is_skipped(self): raw b'{"t":1,"ev":"attempt","dur":null}\n{"t":2,"ev":"pub' -> parse -> 1 record
def test_torn_last_line_bad_json_with_newline_is_skipped(self): b'...\n{"t":2,"ev":\n' -> 1 record
def test_torn_login_ok_leaves_session_in_P1(self): attempt + torn login_ok -> records == [attempt]   # nit: torn login_ok falls back to P1
def test_next_append_starts_on_a_new_line(self):
    write b'{"t":1,"ev":"attempt","dur":null}\n{"t":2,"ev":"lo'; L.append({"t": 3, "ev": "net_fail", "dur": 2, "syn": True})
    self.assertEqual(path.read_bytes().count(b"\n"), 2); self.assertEqual([r["ev"] for r in parse(path.read_bytes())], ["attempt", "net_fail"])
def test_mid_file_damage_is_reported(self): b'{"t":1,"ev":"attempt","dur":null}\ngarbage\n{"t":3,"ev":"stop","dur":2}\n' -> LedgerDamaged
def test_file_mode_0600_and_append_fsyncs_file_and_dir(self): patch os.fsync, count calls == 2 per append; stat mode 0o600
def test_append_oserror_becomes_ledgerioerror(self): patch os.write to raise OSError(errno.ENOSPC) -> LedgerIOError
def test_trim_keeps_last_7_days_and_keep_from(self): records at now-9d, now-8d, now-6d; trim(now, keep_from=now-8d) -> [now-8d, now-6d]; trim(now, keep_from=now) -> [now-6d]
def test_lock_excludes_second_holder(self): child process tries flock(LOCK_EX|LOCK_NB) while held -> BlockingIOError
def test_symlinked_ledger_refused(self): ledger path is a symlink -> LedgerIOError (O_NOFOLLOW)
```
(The implementer writes these as full unittest methods with the literal bytes shown.)

- [ ] **Step 2: Run and see it fail.** `"$PY" -m unittest discover -s tests/ezviz -p 'test_ledger.py' -v`
- [ ] **Step 3: Implement `parse`, `Ledger`, `LedgerDamaged`, `LedgerIOError`** (stdlib: `fcntl`, `json`, `os`).
- [ ] **Step 4: Run and see it pass** (11 tests).
- [ ] **Step 5: Mutation check.** Make `parse` raise on a torn last line instead of skipping it. `test_torn_last_line_*` and `test_torn_login_ok_*` must fail. Make `append` skip the truncate: `test_next_append_starts_on_a_new_line` must fail. Revert both and record the two failing runs in the commit message.
- [ ] **Step 6: Commit** `feat(ezviz): ledger with torn-line rule and fsynced appends (W-23 T3)`.

### Task 4: Policy — T-END and the D4 budget as pure functions

**Files:** Create `spike/ezviz/ezviz_source/policy.py`. Test `tests/ezviz/test_policy.py`.

**Interfaces:**
- Produces:
  ```python
  @dataclass(frozen=True)
  class Decision:
      allow: bool
      cls: str                 # "ok" | "budget_wait" | "latched"
      next_allowed: float      # == now when allow
      attempts_in_window: int  # attempts with t > now - WINDOW_S, future-dated included
      synthetic: dict | None   # D21 record to append BEFORE acting, or None
      latch_now: bool          # row full (or auth_fail) and no "latch" record since the last "unlatch"
  def phase_of_open_session(records: list[dict]) -> str | None   # "P1" | "P2" | "P3" | None
  def decide(records: list[dict], now: float, *, latch_file: bool) -> Decision
  ```
- Consumes: `constants`.

**The algorithm** (not determined by the signature, so it is given here):
```
1. Split records into sessions: each "attempt" opens one; login_ok, published and the first END_EVENTS record
   after it belong to it. "latch"/"unlatch" records are markers on the timeline.
2. D21: if the last session has no end record, synthetic = {"t": now, "ev": "net_fail" if P1 else "unknown_end",
   "dur": None, "syn": True}; continue as if it were appended.
3. Since the last "unlatch" (P6), walk ends in order:
     row:  +1 for every end of a P2 session (start_timeout, session_end, output_end, protocol_fail, unknown_end,
           and auth_fail is a latch of its own); reset to 0 at every "published" record.
     auth: any auth_fail -> latched.
   latched = latch_file or auth or row >= LATCH_ROW;  latch_now = latched and not latch_file and no "latch" after last "unlatch".
4. Ladder since the last unlatch: k = 0; for each session in order: if its attempt.t - previous attempt.t >= LADDER_RESET_IDLE_S
   -> k = 0; then by its end (phase, ev): P1 net_fail -> rung; P2 any end -> rung; P3 stop -> none; P3 unknown_end -> fixed;
   P3 other -> rung; rung -> k += 1; a P3 session with end.t - published.t >= LADDER_RESET_PUBLISHED_S -> k = 0 after it.
   If now - last_attempt.t >= LADDER_RESET_IDLE_S: k = 0.
   wait_end = for the last session's end: rung and 1 <= k <= 3 -> end.t + LADDER_S[k-1];
              rung and k >= 4 -> third-most-recent attempt.t + WINDOW_S (P7); fixed -> end.t + FIXED_WAIT_S; none -> 0.
5. spacing = last_attempt.t + SPACING_S.
   window = [a for a in attempts if a.t > now - WINDOW_S]  # includes a.t > now (Review Focus 1)
   cap = third-most-recent attempt.t + WINDOW_S if len(window) >= CAP_ATTEMPTS else 0.
   next_allowed = max(now, spacing, cap, wait_end).
6. allow = not latched and next_allowed <= now. cls = "latched" if latched else ("ok" if allow else "budget_wait").
```
Only `attempt` records count toward the cap and the spacing (rev 5 nit 2). Synthetic and end records never do.

- [ ] **Step 1: Write the failing tests.** One test per T-END row and D4 rule. `R(t, ev, syn=False)` builds a record; `T0 = 1_800_000_000.0`.

```python
class TestTEnd(unittest.TestCase):
    def test_E1_empty_ledger_allows(self): d = decide([], T0, latch_file=False); self.assertTrue(d.allow); self.assertIsNone(d.synthetic)
    def test_E2_auth_fail_latches(self): d = decide([R(T0,"attempt"), R(T0+1,"auth_fail")], T0+7200, latch_file=False); self.assertEqual((d.allow, d.cls, d.latch_now), (False, "latched", True))
    def test_E3_net_fail_is_rung_60(self): d = decide([R(T0,"attempt"), R(T0+5,"net_fail")], T0+30, latch_file=False); self.assertEqual(d.next_allowed, T0+65)
    def test_E5_open_P1_gets_synthetic_net_fail_once(self):
        recs = [R(T0,"attempt")]; d = decide(recs, T0+100, latch_file=False)
        self.assertEqual((d.synthetic["ev"], d.synthetic["syn"], d.synthetic["t"]), ("net_fail", True, T0+100))
        d2 = decide(recs + [d.synthetic], T0+130, latch_file=False)        # a refused decision 30 s later (H3)
        self.assertIsNone(d2.synthetic); self.assertEqual(d2.next_allowed, d.next_allowed)
    def test_E6_published_resets_row(self): 2 P2 ends, then a session with published+stop, then 1 P2 end -> not latched
    def test_E7_E8_E9_E10_each_add_one(self):
        for ev in ("start_timeout", "session_end", "output_end", "protocol_fail"):
            recs = []                                                # three P2 sessions ending with ev, 2 h apart
            for i in range(3): t = T0 + i*7200; recs += [R(t,"attempt"), R(t+2,"login_ok"), R(t+9, ev)]
            self.assertEqual(decide(recs, T0+30000, latch_file=False).cls, "latched", ev)
    def test_E11_open_P2_gets_unknown_end_and_adds_to_row(self): two P2 ends + open P2 session -> synthetic unknown_end, latched, latch_now
    def test_E13_stop_after_published_has_no_wait_but_spacing(self):
        recs = [R(T0,"attempt"), R(T0+3,"login_ok"), R(T0+9,"published"), R(T0+20,"stop")]
        self.assertEqual(decide(recs, T0+30, latch_file=False).next_allowed, T0+60)       # spacing only
        self.assertTrue(decide(recs, T0+61, latch_file=False).allow)
    def test_E14_session_end_after_published_is_rung(self): ... -> next_allowed == end.t + 60
    def test_E17_open_P3_waits_fixed_60_and_no_rung(self): open P3 -> synthetic unknown_end; next_allowed == now + 60; a second P3 unknown_end later still waits 60 (no climb)
class TestBudget(unittest.TestCase):
    def test_fourth_attempt_in_60_min_refused(self): 3 attempts each ending stop after publish at T0, T0+70, T0+140 -> decide at T0+300: budget_wait, next_allowed == T0+3600
    def test_attempt_within_60_s_refused(self): one stopped session at T0 -> decide at T0+59 refused, T0+60 allowed
    def test_cap_counts_attempt_records_only(self): 2 attempts + 2 synthetic net_fail + 1 latch marker -> attempts_in_window == 2
    def test_ladder_climbs_60_300_900_then_window(self): 4 consecutive P1 net_fail sessions spaced by their waits -> waits 60, 300, 900, then third-most-recent+3600 (P7)
    def test_ladder_resets_after_60_min_published(self): two P1 net_fail sessions (k=2), then a session published at t that ends session_end at t+3600 -> its wait is end.t+60 (k reset by the >= 3600 s publish, then +1)
    def test_ladder_resets_after_60_min_idle(self): rung k=3 then decide at last_attempt+3600 -> wait from rung 1 or none
    def test_future_dated_attempt_counts_in_window_and_spacing(self):   # Review Focus 1
        recs = [R(T0+600,"attempt"), R(T0+605,"net_fail")]; d = decide(recs, T0, latch_file=False)
        self.assertFalse(d.allow); self.assertEqual(d.attempts_in_window, 1); self.assertGreaterEqual(d.next_allowed, T0+660)
    def test_latch_file_alone_latches(self): self.assertEqual(decide([], T0, latch_file=True).cls, "latched")
    def test_unlatch_resets_row_and_ladder_not_cap(self):   # P6
        three P2 ends in 30 min, R(.,"latch"), R(.,"unlatch") -> not latched; but 3 attempts in window -> budget_wait until third+3600
    def test_auth_fail_before_unlatch_no_longer_latches(self): ...
    def test_J2_start_timeout_net_fail_start_timeout_start_timeout_latches(self): row counts P2 only; net_fail neither adds nor resets
```
The implementer writes every elided body with literal timestamps. The comment on each test is the T-END row or D4 clause it proves.

- [ ] **Step 2: Run and see them fail.** `"$PY" -m unittest discover -s tests/ezviz -p 'test_policy.py' -v`
- [ ] **Step 3: Implement `decide` and `phase_of_open_session`** following the algorithm above.
- [ ] **Step 4: Run and see them pass** (about 21 tests; record the exact count in the commit).
- [ ] **Step 5: Mutation tests** (spec S1, S15 named mutations). Apply each one, run the suite, see the named test fail, revert:

| Mutation | Must fail |
|---|---|
| re-classify each time: `synthetic["t"]` taken from the open session's attempt + 60 instead of written once with `now`, and step 2 also runs when a synthetic record exists | `test_E5_open_P1_gets_synthetic_net_fail_once` (the next allowed time moves) |
| `net_fail` resets the row | `test_J2_…` |
| only `start_timeout` and `protocol_fail` count in the row | `test_E7_E8_E9_E10_each_add_one` (K3) |
| the cap counts every record | `test_cap_counts_attempt_records_only` |
| the window excludes `t > now` | `test_future_dated_attempt_counts_in_window_and_spacing` |
| E17 climbs the ladder | `test_E17_…` |
| the cap allows 4 (`len(window) > CAP_ATTEMPTS`) | `test_fourth_attempt_in_60_min_refused` |
| no 60 s spacing | `test_attempt_within_60_s_refused`, `test_E13_…` |
| `auth_fail` does not latch | `test_E2_auth_fail_latches` |
| no ladder reset after a ≥ 60 min publish | `test_ladder_resets_after_60_min_published` |

- [ ] **Step 6: Commit** `feat(ezviz): T-END and login budget policy with named mutations (W-23 T4)`.

### Task 5: Signals — the once-only SIGTERM handler, the critical section, the alarm

**Files:** Create `spike/ezviz/ezviz_source/signals.py`. Test `tests/ezviz/test_signals.py` (subprocess-based: each case runs `"$PY" -c` with a small script).

**Interfaces:**
- Produces: `class Terminating(BaseException)`, `install() -> None`, `critical() -> ContextManager[None]`, `wait_for_sigterm(seconds: float) -> None` (sleeps; a SIGTERM raises `Terminating` through the handler), `sigterm_seen() -> bool`, `hook(name: str) -> None` (test hooks, active only if the comma list in `os.environ.get("EZVIZ_TEST_HOOKS")` names `name`; the go2rtc unit never sets it): `pause_gate` sleeps 2 s before the decision, `pause_cs` sleeps 2 s inside the critical section of the next ledger append, `stall_close` sleeps 60 s in the SIGTERM path's close, `enospc_append` raises `OSError(ENOSPC)` in `Ledger.append`.
- The handler, given here because the order is the L1 and K1 contract:
  ```python
  def _on_sigterm(signum, frame):
      if _st.seen:                 # L1: every later SIGTERM only marks pending; never re-arms, never raises
          return
      _st.seen = True
      signal.signal(signal.SIGALRM, signal.SIG_DFL)
      signal.alarm(ALARM_S)        # the kernel ends the process 4 s later, even inside a C call (H5a)
      if _st.depth == 0:
          _st.raised = True
          raise Terminating()      # J1a: ends the interrupted blocking call at once
      # inside critical(): pending; critical() raises on exit (K1)
  @contextmanager
  def critical():
      _st.depth += 1
      try:
          yield
      finally:
          _st.depth -= 1
          if _st.depth == 0 and _st.seen and not _st.raised:
              _st.raised = True
              raise Terminating()
  ```

- [ ] **Step 1: Write the failing tests**

```python
def test_first_sigterm_raises_terminating_in_blocking_recv(self):  # J1: a socketpair recv with timeout 30 s; SIGTERM at 0.2 s -> Terminating within 1 s
def test_second_sigterm_does_not_raise_or_rearm(self):              # L1: catch Terminating, then sleep 2 s inside the except block, SIGTERM again at +50 ms -> no second Terminating, alarm still from the first (process killed by SIGALRM at ~4 s if it keeps sleeping)
def test_sigterm_inside_critical_is_pending_until_exit(self):       # K1: critical() body writes 3 lines with 0.3 s pauses; SIGTERM at 0.1 s -> all 3 lines written, Terminating after the block
def test_alarm_kills_a_stalled_process_with_sigalrm(self):           # H5a: after Terminating, hook("stall_close") (60 s sleep) -> returncode == -signal.SIGALRM within 5 s
def test_alarm_is_default_action_not_python_handler(self):           # signal.getsignal(SIGALRM) == SIG_DFL after the first SIGTERM
def test_hooks_inactive_without_env(self):                           # hook("stall_close") returns at once
```

- [ ] **Step 2: Run and see them fail.** `"$PY" -m unittest discover -s tests/ezviz -p 'test_signals.py' -v`
- [ ] **Step 3: Implement** as given.
- [ ] **Step 4: Run and see them pass** (6 tests; each completes in < 6 s).
- [ ] **Step 5: Mutation tests:**

| Mutation | Must fail |
|---|---|
| raise on every SIGTERM (drop the `if _st.seen: return`) | `test_second_sigterm_…` |
| a flag-only handler (no raise) | `test_first_sigterm_…` |
| raise inside `critical()` | `test_sigterm_inside_critical_…` |
| `alarm` with a Python handler | `test_alarm_kills_…` |

- [ ] **Step 6: Commit** `feat(ezviz): once-only SIGTERM handler, ledger critical section, 4 s alarm (W-23 T5, L1)`.

### Task 6: The pre-contact gate

**Files:** Create `spike/ezviz/ezviz_source/gate.py`. Tests `tests/ezviz/test_gate.py` and `tests/ezviz/fixtures.py`.

**Interfaces:**
- Consumes: `camfile.load`, `ledger.Ledger`, `policy.decide`, `signals.critical`, `paths`.
- Produces:
  ```python
  @dataclass
  class Admitted:
      cam: camfile.Camera
      ledger_path: Path
      session_fd: int        # flock held until process exit (D18)
      attempt_t: float
      attempts_in_window: int
  class Refused(Exception):  # .cls in {"busy","config","budget_wait","latched","ledger_damaged","ledger_io"}, .code (75/78), .line (fixed-form)
  def admit(name: str, now: Callable[[], float] = time.time) -> Admitted
  def say(name: str, cls: str, *, attempt: int | None = None, next_in: float | None = None) -> None   # writes the §4.5 line to stderr
  ```
- Order (spec §4.1, every step in this exact order):
  1. `os.umask(0o077)`; `state_dir().mkdir(mode=0o700, parents=True, exist_ok=True)`.
  2. Open `<name>.session` (`O_RDWR|O_CREAT|O_NOFOLLOW`, 0600) and `flock(LOCK_EX|LOCK_NB)`. If held: `Refused("busy", 75)`. Nothing else is touched.
  3. `camfile.load` → `CameraFileError`: `Refused("config", 78)` with **no ledger open**.
  4. `with Ledger(...) as L:` read the records, then `decide(…, latch_file=<name>.latch exists)`. `LedgerDamaged` → `Refused("ledger_damaged", 75)`. The rest runs inside `signals.critical()`: append the synthetic record if there is one; if `latch_now`, create `<name>.latch` (0600, fsync file and dir) and append `latch`; if not allowed, `Refused("budget_wait"|"latched", 75)`; otherwise append `{"t": now, "ev": "attempt", "dur": None}`. Trim when the oldest record is older than `TRIM_KEEP_S + 3600`, with `keep_from` = the start of the current latch row and the open session. `LedgerIOError` → `Refused("ledger_io", 75)`.
  5. Return `Admitted`. **No module outside the stdlib may be imported by this point** (N5).

- [ ] **Step 1: Write the failing tests.** `fixtures.run_gate(tmp, name, hold_s=0)` runs a subprocess `"$PY" -c "from ezviz_source import gate; …"` with `SNAP_DATA`/`SNAP_COMMON` under `tmp`; it calls `admit`, prints `ADMITTED` or the refusal line, holds the session lock `hold_s` seconds and exits with the refusal's code:

```python
def test_busy_when_session_lock_held(self): hold flock in the test; run -> rc 75, line "ezviz-source cam1: busy", ledger file not created
def test_missing_camera_file_is_config_78_no_ledger_write(self): rc 78; not ledger.exists()            # G3
def test_malformed_camera_file_is_config_78_no_ledger_write(self): ...
def test_attempt_on_disk_before_return(self): ADMITTED; last ledger record ev == "attempt"                # F3 (the connect half is S1 in Task 11)
def test_budget_wait_refusal_under_150_ms_and_no_pyezvizapi(self):                                       # N5
    seed 3 attempts in the window; run with -X importtime -> rc 75; wall < 0.150 s (median of 5); "pyezvizapi" not in the importtime output
def test_latched_refusal(self): latch file present -> rc 75 "latched"
def test_row_full_writes_latch_file_and_record_once(self): three P2 ends -> latch file created, one "latch" record; second run -> still one
def test_synthetic_written_once_across_refusals(self): open P1 session; run twice 1 s apart -> exactly one syn record   # H3
def test_ledger_damaged_refuses_without_contact(self): middle garbage line -> rc 75 "ledger_damaged"                    # Review Focus 2
def test_attempt_write_failure_means_no_contact(self): EZVIZ_TEST_HOOKS=enospc_append -> rc 75 "ledger_io", no attempt record   # Review Focus 3
def test_ten_concurrent_helpers_on_fresh_state(self):                                                     # Review Focus 4
    rm state dir; start 10 at once, each holding the session for 2 s after ADMITTED -> exactly 1 ADMITTED, 9 busy; dir mode 0700; files 0600
def test_lines_carry_no_camera_value(self): the canary camera file (host 192.0.2.11, serial TESTCAM-0001, login QZCNRA) never appears in stdout/stderr/ledger
```
`Ledger.append` calls `signals.hook("enospc_append")` first (Task 5 defines the hook).

- [ ] **Step 2: Run and see them fail.** `"$PY" -m unittest discover -s tests/ezviz -p 'test_gate.py' -v`
- [ ] **Step 3: Implement `admit`, `say` and `Refused`.**
- [ ] **Step 4: Run and see them pass** (12 tests).
- [ ] **Step 5: Mutation tests:**
  - drop the session lock: `test_busy_…` and `test_ten_concurrent_…` must fail;
  - move the camera-file check after the decision: `test_missing_camera_file_…` must fail (an attempt is written);
  - import `ezviz_source.camera` at the top of gate: `test_budget_wait_refusal_…` must fail.
- [ ] **Step 6: Commit** `feat(ezviz): pre-contact gate: session lock, camera file, ledger decision, attempt (W-23 T6)`.

**Checkpoint A1:** a reviewer re-reads Tasks 3–6 against spec D3, D4, D18, D21, §4.1 and §4.3 and runs every mutation in Tasks 3–6.

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
      def keepalive_failed(self) -> bool         # any keepalive_events entry with sent False (E8/E14 "a keepalive fails")
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
- [ ] **Step 5: Mutation (no orphan session):** drop the `preexec_fn`. `test_child_gets_pdeathsig` must fail (an orphan ffmpeg outlives the helper). Pass the full environment: `test_env_is_path_and_ld_library_path_only` must fail. Revert both.
- [ ] **Step 6: Commit** `feat(ezviz): ffmpeg child with scrubbed env, pdeathsig and the 5 s publish point (W-23 T10)`.

### Task 11: The helper — phases, end records and exit (S1 rest, S14, S15)

**Files:** Create `spike/ezviz/ezviz_source/main.py`. Tests `tests/ezviz/test_helper_s1.py`, `test_helper_s14.py`, `test_helper_s15.py`, and `fixtures.Helper` (a process harness).

**Interfaces:**
- Consumes everything above.
- Produces `main(argv: list[str]) -> NoReturn`, run as `python -I -B -m ezviz_source.main <name> <rtsp-url>`. `argv` checks: the name matches `NAME_RE` and the URL starts with `rtsp://127.0.0.1:`; otherwise exit 64 with no record.
- Flow (the order is binding):
  1. `signals.install()`, then `admit()` (P0).
  2. `import camera` and `silence_library_logging()`; `phase = "P1"`.
  3. `CameraSession(on_login_ok=…)`. The callback, in `critical()`: append `login_ok`, then `Output(...)`; `phase = "P2"`.
  4. The loop runs over `packets()` → `Reassembler` → `AccessUnits` → `write_au`. Each turn checks `keepalive_failed()`, and `published_due()` → append `published` in `critical()`; `phase = "P3"`.
  5. Ends, one record each per T-END, each written in `critical()` with `dur = t - attempt_t`, then `os._exit`:
     - `Terminating` → close the camera socket (`signals.hook("stall_close")` sits here), then P1 `net_fail` / P2 `start_timeout` / P3 `stop`; exit 0;
     - `FfmpegExited` → `wait_for_sigterm(FFMPEG_EXIT_GRACE_S)`; a `Terminating` takes the row above; otherwise `output_end`; exit 75;
     - library errors → `classify`: `auth_fail` writes `auth_fail`, the latch file and `latch` (E2) and exits 77; otherwise the class record and exit 75;
     - the packet iterator ending → `session_end`, 75;
     - any other `Exception` → print `type(e).__name__` only; P1 `net_fail`, P2/P3 `protocol_fail`; exit 75.
  6. Every record write prints its §4.5 line through `gate.say`.
- `fixtures.Helper(tmp, name, fake_args)` builds `SNAP`/`SNAP_DATA`/`SNAP_COMMON` trees. `$SNAP/usr/lib/ffmpeg/8.0/bin/ffmpeg` is `fakeffmpeg.py` by default, or the real one when `real_ffmpeg=True`. It starts the fake camera, writes the canary camera file, runs the helper in its own session (`setsid`), and offers `.ledger()`, `.wait_ev(ev, timeout)`, `.term()`, `.kill_ffmpeg()`, `.rc` and `.elapsed`.

- [ ] **Step 1: Write the failing tests** (S1 remainder, S14, S15; the names say the spec clause):

```python
# test_helper_s1.py
def test_attempt_record_on_disk_before_fake_sees_connect(self):     # F3; fake writes its first-connect time, ledger attempt t < it, and the fake's accept hook asserts the ledger file already holds "attempt"
def test_second_helper_while_first_holds_session_is_busy_one_login(self):  # F4; fake logins_ok == 1
def test_auth_fail_latches_and_next_helper_opens_no_socket(self):  # E2; rc 77; next helper rc 75 "latched"; fake connects unchanged
def test_net_fail_counts_as_attempt(self):                          # closed port -> net_fail; attempts_in_window 1
def test_no_marker_leaks_anywhere(self):                            # §4.5 + N8; drive auth_fail, net_fail, session_end, output_end, stop; markers 192.0.2.11 / TESTCAM-0001 / QZCNRA
    absent from stdout, stderr, ledger, /proc/<helper>/cmdline, /proc/<ffmpeg>/environ (read while running)
# test_helper_s14.py
def test_sigterm_P0_writes_nothing(self): EZVIZ_TEST_HOOKS=pause_gate (2 s sleep before the decision) + SIGTERM -> rc 0, ledger empty
def test_sigterm_P1_is_net_fail_no_row(self): --silent-before-challenge, SIGTERM 1 s after the attempt -> net_fail, latch row unchanged (K2)
def test_sigterm_P2_is_start_timeout_with_row(self): --no-media, SIGTERM at 2 s after login_ok -> start_timeout
def test_sigterm_P3_is_stop_exit_0_within_5s(self): published, SIGTERM -> stop, rc 0, elapsed < 5 s (nit 4)
def test_J1_sigterm_within_1s_of_login_ok_silent_camera(self):  # --silent-after-login, library timeout 10 s (>= 6 s)
    SIGTERM 0.5 s after login_ok -> start_timeout written by THIS helper (ledger has no syn record), rc 0, < 5 s
def test_J3_kill_ffmpeg_then_sigterm_200ms_is_stop(self): published; SIGKILL ffmpeg; +0.2 s SIGTERM helper -> stop
def test_process_group_sigterm_is_stop_20_of_20(self): 20 runs: published, kill -TERM -pgid -> stop in 20/20 (H5b extra check)
def test_L1_two_sigterms_50ms_apart_after_published(self): -> stop record, rc 0, < 5 s
def test_stall_hook_ends_by_sigalrm_within_5s(self): EZVIZ_TEST_HOOKS=stall_close, published, SIGTERM -> rc == -SIGALRM, < 5 s; next decision writes syn unknown_end (E17)
# test_helper_s15.py
def test_published_written_at_publish_point_and_resets_row(self): two P2 ends seeded, then a published session -> row 0 (E6)
def test_J2_start_timeout_net_fail_start_timeout_start_timeout_latches(self): four real helper runs (clock via seeded ledger timestamps) -> latched
def test_K3_three_session_end_before_publish_latch(self): --close-after-s 2 three times -> latched
def test_unknown_end_P2_rung_P3_fixed(self): SIGKILL the helper in P2 -> next decision syn unknown_end, rung; in P3 -> fixed 60 s
def test_K1_sigterm_inside_ledger_write_leaves_complete_record(self): EZVIZ_TEST_HOOKS=pause_cs during "published"; SIGTERM in the pause -> published complete + stop
def test_torn_last_line_then_next_decision_and_new_line(self): append b'{"t":' (torn), run a helper -> it classifies by T-END and the file has no joined line
def test_torn_login_ok_falls_back_to_P1(self): attempt + torn login_ok, no helper alive -> syn net_fail, no row entry
```
Timing tests send signals by event, not by sleep: they wait on `Helper.wait_ev` reading the ledger.

- [ ] **Step 2: Run and see them fail.** `flock -w 3600 /tmp/claude-1000/chim-suites.lock "$PY" -m unittest discover -s tests/ezviz -p 'test_helper_s*.py' -v`
- [ ] **Step 3: Implement `main`.**
- [ ] **Step 4: Run and see them pass** (5 + 9 + 7 = 21 tests; expect about 4 min, dominated by the 20-run test).
- [ ] **Step 5: Mutation tests** (spec S14 and S15 named mutations; each must fail its test, then revert):

| Mutation | Must fail |
|---|---|
| a flag-only SIGTERM handler | `test_J1_…` (the alarm ends it and the next helper writes `unknown_end`) |
| no 1 s wait after an ffmpeg exit | `test_J3_…` (`output_end`) |
| no alarm | `test_stall_hook_…` (hangs past 5 s; the test's own 10 s timeout fails it) |
| raise on every SIGTERM | `test_L1_…` (no end record) |
| raise inside the critical section | `test_K1_…` |
| write `attempt` after `connect` (move the append into `on_login_ok`) | `test_attempt_record_on_disk_before_fake_sees_connect` |
| drop the session lock | `test_second_helper_…` (2 logins) |
| print the host in the `net_fail` line | `test_no_marker_leaks_anywhere` |

- [ ] **Step 6: Commit** `feat(ezviz): ezviz-source helper: phases P0-P3, T-END records, os._exit (W-23 T11; S1, S14, S15)`.

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
- Modify: `snap/hooks/configure`
- Test: `tests/configure-ezviz.test.sh`, `tests/disk-guard.test.sh`, `tests/ezviz/test_unlatch.py`

**Interfaces:**
- `unlatch.main() -> int`:
  - runs `snapctl get -d ezviz` (a JSON map, e.g. `{"ezviz": {"cam1": {"unlatch": 1794000000}}}`);
  - for each valid name whose `unlatch` is an integer and differs from `<name>.unlatch-seen`, inside the ledger lock: if `<name>.latch` exists, remove it (fsync the dir) and append `unlatch`, printing `configure: ezviz <name> unlatched`; else print `configure: ezviz <name> not latched`. In both cases write the value to `.unlatch-seen` (0600).
  - *Why the seen file:* the hook runs on **every** `snap set`, and a later `snap set frigate disk-floor-gib=…` must not unlatch again.
  - It is a no-op if the state dir is absent; it exits 0 on bad input and prints `configure: ezviz <name> ignored (not an integer)`.
- `configure`, two additions:
  - `F=$(snapctl get disk-floor-gib) || F=""`; `[ -z "$F" ]` or an integer 1–10000, else `fail "disk-floor-gib must be an integer 1-10000"`;
  - `"$SNAP/opt/ezviz-py/bin/python3.12" -I -B -m ezviz_source.unlatch || fail "ezviz unlatch failed"`.
- `disk-guard` (POSIX sh):
  - `F=$(snapctl get disk-floor-gib)`, default 20;
  - `free=$(df -P -B1 "$SNAP_COMMON/media/frigate" | awk 'NR==2 {print $4}')`;
  - if `free < F × 2^30` and `snapctl services frigate.frigate` shows `active` → `snapctl stop --disable frigate.frigate` and print `disk-guard: free <G> GiB below floor <F> GiB: stopped and disabled frigate.frigate`;
  - if below the floor and frigate is not active → print nothing; at or above the floor → print nothing;
  - `df` failing → print `disk-guard: cannot read free space` and exit 1, stopping nothing.

- [ ] **Step 1: Write the failing tests**

```bash
# tests/disk-guard.test.sh (stub snapctl + df on PATH; dash and sh, like pre-refresh.test.sh)
#   free 19 GiB, floor unset, active  -> stop --disable called once; one line naming 19 and 20
#   free 21 GiB                        -> no call, no line
#   free 25 GiB, floor 30              -> stop
#   free 10 GiB, frigate inactive      -> no call, no line
#   df fails                           -> exit 1, no stop
# tests/configure-ezviz.test.sh (stub snapctl; real python = the venv's, symlinked as $SNAP/opt/ezviz-py)
#   disk-floor-gib=abc -> exit 1 "must be an integer"; =0 -> exit 1; =20 -> exit 0
#   existing checks unaffected: ports.https=5000 still refused
```
```python
# tests/ezviz/test_unlatch.py
def test_unlatch_removes_latch_appends_record_and_seen(self): ...
def test_same_value_twice_unlatches_once(self): second run -> no record, no line
def test_later_set_of_other_key_does_not_unlatch_new_latch(self): new latch after first unlatch; run again with the same value -> latch stays
def test_not_latched_prints_and_records_seen(self): ...
def test_bad_value_ignored(self): "x" -> "ignored (not an integer)"
def test_policy_after_unlatch_allows_when_budget_does(self): integration with policy (P6)
```

- [ ] **Step 2: Run and see them fail.** `bash tests/disk-guard.test.sh`; `bash tests/configure-ezviz.test.sh`; `"$PY" -m unittest discover -s tests/ezviz -p 'test_unlatch.py' -v`
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and see them pass** (about 7 + 4 shell checks; 6 unit tests). Also `bash tests/pre-refresh.test.sh` stays green.
- [ ] **Step 5: Mutation:** drop the seen-file check → `test_later_set_of_other_key_…` must fail. Revert.
- [ ] **Step 6: Commit** `feat: disk guard timer app and configure-hook unlatch (W-23 T16; D13, §4.2, P6)`.

### Task 17: `frigate.ezviz-check` (N9)

**Files:** Create `spike/ezviz/ezviz_source/check.py` and `spike/bin/ezviz-check`. Test `tests/ezviz/test_check.py`.

**Interfaces:**
- `check.main(argv) -> int`:
  - `ezviz-check <name>` prints exactly one line, `ezviz-check <name>: ok` or `ezviz-check <name>: <cls>`, where `cls` is a `CameraFileError` class (`missing|owner|mode|shape`), `statedir` (the state dir is missing or its mode is not 0700) or `latched`;
  - exit 0 on `ok`, 1 otherwise, 2 for a bad name or usage;
  - it contacts no camera and imports no pyezvizapi.

- [ ] **Step 1: Failing tests**: `ok`, each class, no canary in the output, `pyezvizapi` not in `sys.modules` after `main`, and a bad name gives rc 2.
- [ ] **Steps 2–4:** run (`"$PY" -m unittest discover -s tests/ezviz -p 'test_check.py' -v`) → fail → implement → pass (8 tests).
- [ ] **Step 5: Commit** `feat(ezviz): ezviz-check app (W-23 T17; N9)`.

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

### Task 19: Hub tools — ledger counts, the power check, the watcher trip, observe `--helpers`

**Files:**
- Create: `tests/hub/ezviz-ledger.sh`, `tests/hub/ezviz-ledger.test.sh`, `tests/hub/power-check.sh`, `tests/hub/power-check.test.sh`, `tests/hub/coverage.sh`, `tests/hub/coverage.test.sh`
- Modify: `tests/hub/watch.sh`, `watch.test.sh`, `observe.sh`, `observe.test.sh`

**Interfaces:**
- `ezviz-ledger.sh [--since <epoch>] [--out DIR]`:
  - one `ssh-exec.sh exec 'for n in cam1 cam2; do echo "== $n"; cat /var/snap/frigate/common/ezviz/state/$n.ledger 2>/dev/null; ls /var/snap/frigate/common/ezviz/state/$n.latch 2>/dev/null; done'`;
  - parses locally with `python3 -I` and prints per camera: `ledger <name>: attempts=<n> login_ok=<n> published=<n> ends=<ev:n,...> latched=<0|1> max_attempts_any_60min=<n> attempts_since=<n> login_ok_since=<n> last=<ev>@<iso>`;
  - exit 0, 1 if any camera is latched or `max_attempts_any_60min > 3`, 3 if the master is gone.
- `power-check.sh --since <epoch>`:
  - runs `journalctl -k --since @<epoch> --no-pager -q 2>/dev/null | grep -c 'Undervoltage detected' || true` (falls back to `dmesg` if journalctl prints nothing and exits non-zero);
  - prints `power-check: undervoltage lines since <iso>: <n>`;
  - exit 0 if n = 0, 1 otherwise, 3 if the master is gone.
- `watch.sh` gains a sample field `uv=<count since the watcher's start>`: `TRIP undervoltage` when it grows (act mode stops frigate, P12). An unreadable field is INFO, not BLIND.
- `coverage.sh --since <epoch> --hours H`:
  - reads Frigate's recordings list per camera through the snap's own python on the hub, as `observe.sh` reads `/stats` (`snap run --shell frigate.frigate`, the script on stdin, urllib to `127.0.0.1:5001` with the Remote-User/Remote-Role headers), from `GET /api/<camera>/recordings?after=<since>&before=<since+H·3600>`. Confirm the route and its `start_time`/`end_time` fields in v0.18.2 `frigate/api/media.py` while implementing; if they differ, use the route that lists segments;
  - sums the overlap of segments with the window per camera and prints `coverage <cam>: <pct> %` (numbers only);
  - exit 0 if every camera is ≥ 99 %, 1 otherwise, 3 if the master is gone.
- `observe.sh` gains `--helpers N` (default 0):
  - counts processes in the go2rtc unit whose args contain `-m ezviz_source.main`, labelled `h` with their camera name (the argument after the module);
  - PASS when the count equals N and none has restarted since `--prev`;
  - printing rules as for execs (never a whole command line).

- [ ] **Step 1: Write the failing tests** with the existing fixture style (stub ssh responder; `M7C_OBSERVE_ROOT` fake /proc):
  - `ezviz-ledger.test.sh`: a fixture ledger with 3 attempts within 30 min → `max_attempts_any_60min=3`, exit 0; with 4 → exit 1; a latch file → `latched=1`, exit 1; a torn last line is ignored; no fixture canary in the output.
  - `power-check.test.sh`: 0 lines → exit 0; 2 lines → exit 1 and `: 2`; master gone → 3.
  - `coverage.test.sh`: fixture segments covering 23.9 of 24 h → `99.6 %`, exit 0; with a 30 min gap → exit 1; overlapping segments are not double-counted; no non-numeric field is printed.
  - `watch.test.sh`: a second sample with `uv` +1 → `TRIP undervoltage`, and `--act` calls stop.
  - `observe.test.sh`: `--helpers 2` with two fake helper processes → PASS; a changed PID with `--prev` → FAIL; `--execs 0 --helpers 2` gives no exec verdict.
- [ ] **Step 2: Run and see them fail**, **Step 3: implement**, **Step 4: run and see them pass.** Record the counts; the 90 watch and 83 observe checks stay ok.
- [ ] **Step 5: Commit** `feat(hub): ledger counts, undervoltage check and trip, observe --helpers (W-23 T19; P12)`.

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
      env -i PATH=/usr/bin:/bin "$D/bin/python3.12" -I -m pip install --no-cache-dir --no-compile \
        --require-hashes --only-binary=:all: --no-deps -r "$CRAFT_PART_SRC/requirements.txt"
      SP="$D/lib/python3.12/site-packages"
      cp -r "$CRAFT_PART_SRC/ezviz_source" "$SP/"
      env -i PATH=/usr/bin:/bin "$D/bin/python3.12" -I -m pip uninstall -y pip
      # Prune (each verified by the import proof below): Tk/Tcl, idle, turtle, ensurepip, headers, docs, the shared libpython
      # (bin/python3.12 links libpython statically; nothing embeds it).
      rm -rf "$D"/include "$D"/share "$D"/lib/pkgconfig "$D"/lib/tcl9* "$D"/lib/tk9* "$D"/lib/itcl* "$D"/lib/thread* \
             "$D"/lib/libtcl9* "$D"/lib/libpython3* "$D"/lib/python3.12/config-3.12-* \
             "$D"/lib/python3.12/idlelib "$D"/lib/python3.12/tkinter "$D"/lib/python3.12/turtledemo \
             "$D"/lib/python3.12/ensurepip "$D"/lib/python3.12/lib-dynload/_tkinter*
      env -i PATH=/usr/bin:/bin "$D/bin/python3.12" -I -m compileall -q -j0 "$D/lib/python3.12"
      # Import proof on the build arch (§10 rows 8 and 16): everything the helper, rearm, check and unlatch import.
      env -i PATH=/usr/bin:/bin "$D/bin/python3.12" -I -B -c 'import ezviz_source.main, ezviz_source.camera, ezviz_source.rearm, ezviz_source.check, ezviz_source.unlatch, pyezvizapi.streaming.local.session, Crypto.PublicKey.RSA, cryptography.hazmat.primitives.ciphers; print("ezviz-py import proof ok")'
```
`tests/w23-size.sh <base.snap> <new.snap>` prints `size: base=<B> new=<B> delta=<B>` and exits 1 if the delta is > 35,000,000 B. The spec's estimate is about +28 MB; the 35 MB limit leaves 25 % headroom.

- [ ] **Step 1: Write the failing static test** (`tests/w23-packaging.test.sh`, `t` style as in `tests/m9-packaging.test.sh`):
  - both pbs sha256 strings and the `20261110` / `3.12.16` names are present;
  - `requirements.txt` equals `d5260d4`'s;
  - apps `ezviz-check` (no `plugs:` key) and `disk-guard` (`daemon: oneshot`, `timer: "00:00-24:00/144"`, no plugs) exist;
  - the `go2rtc` app is unchanged (`plugs: [network, network-bind]`, no `stop-mode`: D17 relies on the default `KillMode=control-group`);
  - the import-proof line names `pyezvizapi.streaming.local.session`;
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
- `TIMESTAMP_MODE` = `"wallclock"`, unless every probe shows `rtp_ts_monotonic ≥ 0.999` and `rtp_ts_step_p99_dev ≤ 360` (10 % of 3600) **and** S2 check 1, or the probe's decode, showed a timestamp defect under wallclock (non-monotonic pts in the consumer's framemd5, or decode errors). Only then implement `"rtp"`: `mpegts.py` writes PAT/PMT/PES with PTS = RTP ts, and `child_argv(…, "rtp")` uses `-f mpegts -i pipe:0`. Tests: PES PTS equals the ts, continuity counters wrap, and ffprobe (from the snap file) reads monotonic pts. Otherwise record "(a) not needed: (b) adequate" with the evidence.
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
The heavy `serve-ezviz.test.sh` SKIPs in CI, because there is no local amd64 file. The `tests/*/*.test.sh` loop already picks up `tests/ezviz/*.test.sh`.

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
  2. any `auth_fail` or `latched=1` in `ezviz-ledger.sh` → `X exec 'snap stop --disable frigate'`, then report;
  3. `max_attempts_any_60min > 3` → the same stop (it should be impossible; it means a bug);
  4. any new `Undervoltage detected` line (P12) → the same stop, and tell the maintainer at once;
  5. the watcher going BLIND → tell the maintainer at once (Frigate keeps running under the quota and the D13 guard, spec §9.3).
- Rollback is per spec §9.3, with P10's order for the stand-in: `X exec 'rm -rf /var/snap/frigate/current/ezviz'`, then clip-mode make-config.

### B0. Gate GA — item A, the long-session probe (laptop to the cameras; each run is the maintainer's card)

| Run | Card command | Stop rule / pass |
|---|---|---|
| A1 | `bash /<repo>/tests/ezviz/probe-run.sh cam1 63 extend` | 1 login. Pass: `end=stop session_s>=3780 keepalive_failed=0`. If it ends before 120 s with `session_end` → A1b next hour |
| A1b (only if A1 failed) | `bash /<repo>/tests/ezviz/probe-run.sh cam1 63 repeat` | as A1. If it also fails → **STOP: report to the maintainer** (spec §9.1 A) |
| A2 | `… probe-run.sh cam2 63 <form>` | as A1 |
| A3 | `… probe-run.sh both 63 <form>` | both lines pass, 1 login each |

The probe enforces the budget itself, with persistent state under `$M7C_ENV_DIR/w23-probe-state`. Results (the probe lines only) go to `docs/w23-findings.md` §A, and then Task 21 runs.

### B1. Before the hub steps

| Step | Who | Command | Pass / stop |
|---|---|---|---|
| H-power | maintainer + orchestrator | the maintainer reports the PSU/cable check (card item 8); then `tests/hub/power-check.sh --since <epoch of the last boot>` | `undervoltage lines … : 0`; otherwise stop and report |
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
| 6 | `tests/hub/power-check.sh --since T5` | `: 0` |
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
| 4 | T5 + 24 h | `ezviz-ledger.sh --since T5`; `power-check.sh --since T5`; the watcher log | per camera `max_attempts_any_60min ≤ 3` and `login_ok_since ≤ 12`; 0 TRIP; `NRestarts` 0 for frigate and go2rtc (manual restarts excluded); HA 200 in ≥ 99 % of samples with no 3 failures in a row; undervoltage 0 |
| 5 | T5 + 24 h | `tests/hub/coverage.sh --since T5 --hours 24` (Task 19) | `coverage cam1: ≥ 99 %`, `coverage cam2: ≥ 99 %` |

### B7. S9 to S13

| Step | Command (each on its own go) | Pass |
|---|---|---|
| S9 | `X exec 'df -P -B1G /var/snap/frigate/common/media/frigate'` → free F; `X exec 'snap set frigate disk-floor-gib=<F+10>'`; wait ≤ 10 min; `X exec 'snap services frigate.frigate; journalctl -u snap.frigate.disk-guard -n 3 --no-pager'`; `X exec 'snap set frigate disk-floor-gib=20'`; restart `X exec 'snap start frigate'` | frigate inactive and disabled with one guard line; floor back to 20 |
| S10 | `X exec 'snap stop frigate'`; then within 10 s `X exec 'pgrep -fc ezviz_source.main \|\| true'`; `ezviz-ledger.sh`; `X exec 'journalctl -u snap.frigate.frigate -n 20 --no-pager \| grep -c "result=ok"'` | 0 helpers; each ledger `last=stop`; `result=ok` present; the maintainer plays the last segment («yours»). A Frigate SIGKILL after 30 s is recorded, not failed |
| S11 | `X exec 'snap start --enable frigate'`; **the maintainer reboots the hub**; then within 5 min of boot: observe (`--helpers 2`), `ezviz-ledger.sh --since <boot>`, `--list` | all services active; both cameras at fps; frigate `NRestarts` ≤ 1; 1 `login_ok` each; `preload: cam1,cam2` |
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
  | §10 row 25 | settled by source, see report |
- **Type consistency:** `admit` → `Admitted`; `decide` → `Decision`; `classify` → `str`; `Output.write_au(bytes, bool)`; the `Reassembler.push` and `AccessUnits.push` names are used the same way in Tasks 7, 9, 11 and 12.
- **Proportion:** bodies are given only for the policy algorithm and the signal handler, where order is the contract. Everything else is a signature plus tests.
