# W-23 Spec: the hub's Frigate on the two real cameras, with image encryption kept on

**Date:** 2026-11-16
**Classification:** **bounded.** It designs one route (the cameras' clear port-8000 stream into the hub's Frigate) and splits the work into later items. It builds nothing, and it contacts no camera and no hub.
**Status:** draft, revision 2: fix wave 1 after the independent review of revision 1 (`61be7f3`, approve with changes). It fixes F1 to F5 and takes the nits N1 to N11. Each fix is marked *(rev 2, Fn)* or *(rev 2, Nn)* where it lands.
**Wish:** W-23. The maintainer's words on W-7 Q13: «Keep it installed. Why keep it stopped and not start using it?» The maintainer's answer to W-23 Q1: «Keep encryption on, take the W-20 route».
**Builds on:** the W-20 spike spec and plan on branch `spec/ezviz-encrypted-streams` at `d5260d42458c`. Those are `docs/superpowers/specs/2026-11-13-ezviz-encrypted-streams-design.md` (cited as **W20-S**) and `docs/superpowers/plans/2026-11-13-ezviz-t10-p4-test.md` (cited as **W20-P**). W20-S D11 asks for this spec.
**Also reads:** `docs/m7c-findings.md` on `origin/main` (`8b3adb6`, cited as **M7C-F**) and the M7c spec on `spec/m7c-arm64-research` at `4731a7f2ec15` (cited as **M7C-S**).

**Claim labels.**
- **[VERIFIED: how]**: checked by a command while writing this.
- **[REPORTED: where]**: another document's or card's record. It was not re-run here.
- **[RESEARCHED: source]**: read in upstream source or documentation.
- **[ESTIMATE]**: arithmetic or judgement.
- **[UNVERIFIED]**: not tested by anyone.
- **NOT PROVEN**: marks a property this design depends on that no test has shown yet. Each one is listed in §10 with the test that would prove it.

Hosts, addresses, serials, codes and logins appear only as placeholders: `<CAM1>`, `<CAM2>`, `<CAM_HOST>`, `<CAM_SERIAL>`, `<LOGIN>`, `<HUB>`.

---

## 1. The problem in one paragraph

The hub (a Raspberry Pi 5) already has Frigate 0.18.2 installed: the arm64 file, as revision `x1` from `--dangerous`, held, stopped and disabled. Its config is the synthetic stand-in. Two looped H.265 clips feed go2rtc `exec:` sources (M7C-F:188-192, 221-222; card W-7 decision 2). It cannot record the real cameras because both cameras have image encryption on and refuse RTSP on port 554 (card W-20, Details). The maintainer wants encryption kept on (W-20 Details; W-23 decision 1). The W-20 spike found a local path that keeps it on: the EZVIZ app's own *LAN Live View* protocol on TCP 8000. That path delivers **clear** H.265 (§2). What is missing is a production helper that turns that path into a stream go2rtc can serve to Frigate, and the hub steps to switch over. This spec designs both. It leaves the build to later items (§9).

## 2. What W-20 proved and what it did not

### 2.1 Proven

| Fact | Evidence |
|---|---|
| **The port-8000 login is the camera's own label code** (the sticker verification code) as user `admin`. The shared image-encryption password (`new.common` in the key file) is **not** the login. | Run 1 (CV310, shared password): `AUTH_FAIL`. Run 2 (C3W, label code): login worked [REPORTED: W20-P:13-14, 21; W20-S:16-19] |
| **Both cameras deliver clear H.265 on port 8000 while image encryption is on.** No media key and no decryption are needed. | C3W, R1 and R2: `V00` ("no decryption") decodes strictly, 0 errors, 251 frames, 1920×1080; R2, scored by the rev-4 scorer, also showed 251 distinct frame hashes (R1's rev-3 scorer counted no hashes, W20-P:30) *(rev 2, N1)*. CV310, R3: `V00` decodes strictly, 0 errors, 250 frames, 250 distinct hashes, **1920×1088 coded**. Every key/cipher variant fails [REPORTED: W20-S:20-23, 27-30; W20-P:28-41]. So the CV310's result is **not pending**: its machine checks passed in R3, in one login with its own label code. |
| **About 25 fps** on both. Keyframes every ~3 s on the C3W. **~1.6–1.7 Mbit/s** on the C3W. **~0.35 Mbit/s** on the CV310, in one 10-second capture of what looked like a quiet or dark scene. | W20-S:34-42 [REPORTED] |
| **No cloud.** Each completed capture (R1, R2, R3) made one login, opened 11 TCP connections, all to port 8000, and contacted nothing else. R4 made 1 connection to port 8000 and got no login result *(rev 2, N2)*. | W20-S:20-23 (`strace` counts) [REPORTED] |
| **The library makes one login per invocation**, with no retry and no reconnect. | W20-P:56-57 (pyEzvizApi 2.0.0 `session.py` L1525-1560, `hcnetsdk/api.py` L4425-4489) [REPORTED] |
| **Do not use the library's decrypt switch.** It decrypts every slice unconditionally, which turns the clear stream into garbage (run 2: `GARBLED`). | W20-P:21-26; W20-S:32 [REPORTED] |

### 2.2 Not proven: each item is NOT PROVEN

1. **NOT PROVEN: a meaningful picture.** The machine checks show a decodable, changing stream. Average and maximum luma were constant across every frame on both cameras (C3W YAVG 98, CV310 YAVG 81, YMAX 255), so the brightness check was **inconclusive**. No agent has looked at a frame, by rule [REPORTED: W20-S:48].
2. **NOT PROVEN: audio.** It was not captured on either camera. The app plays LAN Live View with audio [REPORTED: W20-P:49], and the library's docs say IDMX can carry AAC [REPORTED: W20-S:38].
3. **NOT PROVEN: reconnect.** Every capture was a single 10-second session. No session was ever re-opened after a drop.
4. **NOT PROVEN: a long run. W20-S:294 already flagged the bounded keepalives; this spec quantifies them** *(rev 2, N3)*. The library's built-in plan sends **exactly six** media keepalives (`0x30006`), 5 s apart, and then stops [VERIFIED: pyEzvizApi 2.0.0 wheel, sha256 `ed7c309a…f349f8` (equal to the W20-P:65 pin), `streaming/local/session.py` L488-495 (six templates, `keepalive_interval_seconds=5.0`) and L1156-1157 (the sender returns after the last frame)]. So the keepalives cover only about the first 30 s of a session. Whether the camera keeps a session open after that without more keepalives, and whether extending the keepalive pattern (its `addend_delta` steps by 6 each time: 10, 16, … 40) works, are both untested.
5. **NOT PROVEN: both cameras at once.** Each run used one camera.
6. **NOT PROVEN: the lockout limit.** The "3 authentications per camera per hour" rule is this project's own safety budget (card W-20, Rules). It is not a measured camera limit. What is known is that a lockout came after about 24 h of wrong passwords (card W-20). Hikvision-style devices are said to lock after ~5 wrong logins for 30 minutes [REPORTED: W20-P:60, third-party, UNVERIFIED for EZVIZ]. Whether **successful** logins count towards any limit is unknown.
7. **NOT PROVEN: concurrent local viewers.** R4 (C3W) timed out with no login result. One possible cause is the phone app's live view being open at the same time [REPORTED: W20-S:22, 289, UNVERIFIED]. How many local viewers each model allows is unknown.
8. **NOT PROVEN: the arm64 runtime.** The spike ran on the amd64 laptop with system Python 3.12.3 [REPORTED: W20-P:73]. Nothing of the library has run on aarch64.
9. **NOT PROVEN: timestamps.** The spike counted frames. It did not check whether the reassembled stream carries usable presentation timestamps, which recording needs (§4.4).
10. **NOT PROVEN: the plan's fit to firmware over time.** The built-in plan replays command templates traced from the app on another model (a "Husky" camera) [REPORTED: W20-P:64]. A firmware update could change them (W20-S risk 7).

## 3. Decisions

Each decision gives its reason. The `D` numbers are this spec's own; `W20-S Dn` and `M7C-S Dn` refer to the other specs.

- **D1. Route: the port-8000 LAN Live View path (W-20's P4), clear stream, no decryption, no cloud.** *Why:* it is the only path proven to carry video with encryption on (§2.1). It needs only the label code, which is already in the key file under `original QR Code keys` and is the same login that RTSP used on 12 Nov [REPORTED: W20-P:14, 50; `tests/hub/make-config.sh:10`]. It needs no cloud (P3 was rejected, W20-S D3) and changes no camera setting. The fallback, turning encryption off, was offered and declined (W-23 decision 1).

- **D2. One go2rtc stream per camera, fed by a snap-owned `exec:` helper, `ezviz-source`, and kept open by go2rtc's `preload`, so it runs as long as go2rtc runs, not only while Frigate consumes** *(rev 2, F2)*. *Why:*
  - go2rtc shares one producer among all consumers of a stream (Frigate's detect and record inputs, live view through nginx). So one stream per camera means at most **one camera login per stream start**, however many viewers there are.
  - The `exec:` + `{output}` RTSP flow is already proven under this snap's confinement (W20-S D10, citing `docs/m1-findings.md` M1-3) and on the hub (the stand-in's three exec ffmpegs ran 27,608 s, M7C-F:205, 268).
  - As go2rtc's child, the helper inherits go2rtc's `network` plug (`snap/snapcraft.yaml:86-90`), so it needs **no new plug**.
  - **Without preload, every Frigate-side drop would cost a login.** go2rtc stops a producer as soon as its last consumer is removed, with no grace period (`RemoveConsumer` → `stopProducers()` [VERIFIED: go2rtc v1.9.14 `internal/streams/stream.go` L64-77, L97-117]). Each camera has exactly one Frigate ffmpeg (roles detect+record, D9). So a Frigate restart (the UI restart button, a config save, a crash under `restart-condition: always`), a Frigate ffmpeg watchdog restart, or a stall that makes that ffmpeg exit would each kill the helper, and the reconnect would be a new login (reviewer finding F2).
  - **With preload, those events cost nothing.** go2rtc 1.9.14 reads a `preload:` map from its config and attaches a built-in probe consumer to each named stream at start (`streams.go` L18, L45-46; `preload.go` L21-50 [VERIFIED: go2rtc v1.9.14]). `frigate.frigate` and `frigate.go2rtc` are separate daemons (`snap/snapcraft.yaml:86-90, 115-143`), so the helper's session survives any Frigate restart. Only a go2rtc restart, a session drop at the camera side, or `snap stop frigate` (all services) ends it.
  - When go2rtc stops, the helper stops too, and the camera's local viewer slot is released (item 7 of §2.2). While go2rtc runs, the slot is held all the time. That is what 24/7 recording needs anyway.
  - **A second stream for the same camera is forbidden**: it would start a second helper, which means a second login and a second viewer.

- **D3. The helper owns its login budget. go2rtc's re-dials can never become logins.** go2rtc 1.9.14 re-runs a failed producer on its own schedule: every 1 s ×5, every 5 s ×5, every 10 s ×10, then once a minute [VERIFIED: go2rtc v1.9.14 `internal/streams/producer.go` L185-198]. Each re-run is a new helper process. So the budget lives in a per-camera ledger on disk (§4.3). A new helper process reads the ledger **before any camera contact**. If the budget forbids a login, it exits at once with the class `budget_wait`. go2rtc's re-dials then cost nothing on the camera side. *Why:* a restart loop that logs in on every respawn is how the earlier 24-hour lockout would come back (W20-S D13). Neither go2rtc nor systemd knows about the camera's limit. Only the helper can enforce it.

- **D4. Login budget per camera, binding:**
  - at most **3 login attempts in any rolling 60 minutes**;
  - at least **60 s** between two attempts;
  - after a session that ended without an authentication failure, the next attempt waits 60 s, then 5 min, then 15 min, then until the 3-per-hour window allows another. **The ladder resets to 60 s** after a session that lasted at least 60 minutes, or after 60 minutes with no attempt *(rev 2, N6)*: otherwise one drop a day would climb the ladder for good;
  - **any authentication failure sets a latch.** The latch stops all contact with that camera until an operator clears it on purpose;
  - **a timeout or connection error before an authentication result counts as an attempt.** It sets no latch, because no authentication result came back (the R4 lesson: W20-S:289);
  - **an attempt with no recorded outcome** (the helper was SIGKILLed, OOM-killed inside the quota group, or the hub lost power between `attempt` and the result) is classed as `net_fail` at the next decision: it counts, sets no latch, and applies the backoff *(rev 2, F3)*. This mirrors the W-20 test script, which refused to run while an earlier attempt had no recorded outcome (W20-P:96). An `attempt` followed by `login_ok` and no end record is classed as a session that ended at an unknown time: it counted already, and the backoff ladder applies.

  *Why:* 3 per hour is the W-20 rule (card W-20, Rules), kept until a measurement justifies more. The latch is W20-S D13: a wrong or stale password must never retry. The cost of the cap: after three drops in one hour, that camera stays dark for up to about an hour. With preload (D2), Frigate restarts are no longer drops, so only camera-side drops and go2rtc restarts count. A lockout cost about a day. The latch never clears by itself. §11 states this cost in plain words for the maintainer *(rev 2, N11)*.

- **D5. Runtime: a standalone CPython 3.12 inside the frigate snap, used only by the helper, running the pinned pyEzvizApi 2.0.0 that W-20 proved. Recommended; open decision OD1.** *Why, the one deciding reason:* it runs **the exact library version and the same calls** that produced W-20's clear decodes on both cameras. Every alternative re-hosts or rewrites protocol code, and each rewrite would have to be proven again against the cameras with logins, which are the scarce resource (D4). The cost and the alternatives are compared in §5.

- **D6. The helper's own code is small, and its parts are separate.** It has three parts:
  - **(a)** the login, plus the media session opened the way the spike opened it (`_hcnetsdk_command_port_endpoint` and `_open_hcnetsdk_command_port_clip_stream`, called with `host` given so that the cloud is never touched; W20-P:59);
  - **(b)** an **unbounded** packet loop with **extended keepalives** (§2.2 item 4);
  - **(c)** IDMX/FU → Annex-B reassembly with **no decrypt step**.

  Its output goes to the bundled ffmpeg 8.0 (`-c copy -an -f rtsp {output}`).

  *Why:* the library has no public continuous API. Its capture helpers refuse unbounded IDMX remuxing (`_require_bounded_idmx_capture` [VERIFIED: wheel, `streaming/local/capture.py` L358]). The clear decode in R1-R3 came from calling the private `_decrypt_idmx_local_packets_to_annexb_with_codec` with its decrypt function replaced by a no-op [VERIFIED: W20-P harness `t10_offline_harness.py` L130-138; `payloads.py` L752]. Our code must therefore own (b) and (c). Keeping them small and separate lets each be tested without a camera.

- **D7. Logins live in a root-only file per camera under `$SNAP_DATA/ezviz/`, never in `config.yml`.**
  - They travel only from that file into the helper's memory.
  - They never appear in argv, in a child's environment, in stdout or stderr, or in any log.
  - `config.yml` names only the loopback restream (§6.3).

  *Why:* go2rtc returns a source URL **unmasked** in its API (W20-S:171). This project has already leaked both cameras' credentials once through exactly that API, into an evidence file (`docs/m7-findings.md:106`). Today's RTSP pattern puts `rtsp://admin:<code>@…` in `config.yml` (`tests/hub/make-config.sh:174-175`). With the helper, no camera secret is in `config.yml`, `go2rtc.yaml`, an exec line or the go2rtc API at all. `$SNAP_DATA` (not `$SNAP_COMMON`) is used for the **camera files** because `config.yml` lives there too (`/var/snap/frigate/current/config`, `make-config.sh:54`), so snapd copies or reverts both together on a refresh or revert.

  **The ledger, the latch and the locks are different: they live in `$SNAP_COMMON/ezviz/state/`** (root 0700, files 0600) *(rev 2, F3)*. *Why:* snapd keeps one `$SNAP_DATA` per revision. A latch set under a later revision would be lost on a `snap revert` to an earlier one, whose copy predates it, and that revision's helper would then retry a known-bad login: the exact lockout path D4 exists to stop (reviewer finding F3c). `$SNAP_COMMON` is shared by all revisions, so the budget and the latch survive refresh and revert. They hold no secret.

- **D8. The go2rtc config generator emits the camera streams from the snap-owned camera files, not from the operator's `config.yml`.** For each `$SNAP_DATA/ezviz/cameras/<name>.conf`, `go2rtc-config-gen.py` adds
  - the stream `<name>: exec:$SNAP/bin/ezviz-source <name> {output}#killsignal=15#killtimeout=5` (D17, *rev 2, F1*), and
  - `preload: {<name>: "video"}` (D2, *rev 2, F2*).

  **Snap-owned camera names win** *(rev 2, N7)*. The generator deep-merges the operator's `go2rtc:` section over the baseline, with the operator winning per key and `streams` dicts unioned (`spike/bin/go2rtc-config-gen.py` docstring, model step 2). So it writes the snap-owned camera streams and preloads **after** that merge. An operator entry with the same name (a hand edit, or a 0.18 UI save of the go2rtc section) is dropped with a redacted warning that names only the stream, never its value. Without this, the camera could lose its helper or gain a second source, which would mean a second login. A generator test covers it. *Why:* this is W20-S D10. The restricted-source filter planned for operator `exec:` streams (pending, `spike/bin/go2rtc-config-gen.py:52-58`) will drop operator exec lines but keeps snap-owned baseline streams exempt. Generating the lines from snap-owned input keeps the camera streams working when that filter lands. The exec line carries only the camera name.

- **D9. Detect and record use one input per camera** (roles `detect` and `record`). Detection runs at the stream's native size, measured by `ffprobe` at setup and never assumed. *Why:* the built-in plan serves **channel 1 only**, the main stream (W20-S:85, 285). No sub-stream is available on this path. The two cameras' frame sizes differ (1920×1080 and 1920×1088 coded, W20-S:288). The fallback, if CPU decode cannot keep up, is detect at 1280×720, as in M7C-F:192.

- **D10. Video only in the first version: the helper passes no audio (`-an`). Recommended; open decision OD4.** *Why:* audio on this path is NOT PROVEN (§2.2 item 2). AAC would need its own reassembly and timestamps. Frigate's detection does not use audio. Audio can be added once the long-session probe (§9, item A) shows AAC on port 8000.

- **D11. The hub needs a new build, installed the same way as `x1` (a sha-checked file plus `--dangerous`, so it becomes `x2`), held and stopped. Recommended; open decision OD3.** *Why:* the helper, its runtime and the generator change are snap changes. A Store install needs a Store login on the hub. That is the maintainer's own step and is out of scope here (§8).

- **D12. Retention: the soak runs at `continuous.days: 1` with alerts and detections at 1 day, the stand-in's values. After acceptance the production value applies: recommended **3 days**, open decision OD2.** *Why:* the 1-day values bound the soak's disk use exactly as in the stand-in runs (`make-config.sh:161-163`). The production numbers are in §7.

- **D13. A hub-side disk floor guard is part of the helper build.** It is a small `oneshot` app on a timer, like `logrotate`. Every 10 minutes it compares the free space of the recordings filesystem with a floor (default 20 GiB, `snap set frigate disk-floor-gib=N`). Below the floor it runs `snapctl stop --disable frigate.frigate` and logs one line. *Why:*
  - The laptop watcher (`tests/hub/watch.sh`) is a soak tool. It depends on the laptop's SSH master, and it has gone blind before (M7C-F:257).
  - Frigate's own storage cleanup starts only when **less than one hour** of recording space is left [VERIFIED: Frigate v0.18.2 `frigate/storage.py` L107-118]. On a disk shared with Home Assistant, that is far too late.
  - The 20 GiB floor is the M7c stop rule's value (M7C-S §8).
  - That `snapctl stop` works from an app, not only from a hook, is [RESEARCHED: snapcraft forum threads 1908 and 13649, community answers] and must be verified at plan time (§10).

- **D14. Hub steps follow M7C-S D14 unchanged.** No worker connects to the hub. Every hub step runs on the maintainer's direct go for that step, run by the orchestrator through the existing ssh master tooling (`tests/hub/ssh-exec.sh`), or by the maintainer. Paste hygiene applies. Camera contact from the laptop (item A in §9) also needs the maintainer's go for each run. *Why:* the hub is a shared production board (Home Assistant, Z-Wave, MQTT). The cameras have a lockout history.

- **D15. The key file is never read for values by any agent session.** The hub's camera files and `config.yml` are written by the existing `tests/hub/make-config.sh`, extended with a third source mode, `M7C_SOURCE=ezviz`. **The maintainer runs it from a command card** (recommended), or the orchestrator runs it only if the maintainer explicitly allows that for the session (as in W-20 decision 2). *Why:* make-config already reads the logins by path, keeps them in shell variables, sends them only on stdin over the ssh master, and prints only counts (`make-config.sh:40-44, 95-102`). It is the reviewed path. The card keeps the values out of every agent's context.

- **D16. No change to the cameras, to Frigate's source, or to the firewall.** *Why:* these are W-20's rule, the user ruling "Frigate is not patched" (`snap/snapcraft.yaml` R4 comments) and W-18's scope (§8).

- **D17. The stop signal is set on the exec line: `#killsignal=15#killtimeout=5`. The helper is still designed to be safe under SIGKILL** *(rev 2, F1)*. *Why:*
  - **go2rtc does not send SIGTERM by default.** It builds the helper with Go's `exec.CommandContext`, and closing the producer cancels that context (`pkg/shell/command.go` L19-25, L56-59 [VERIFIED: go2rtc v1.9.14]). Go's default cancel is `Process.Kill`, i.e. SIGKILL [RESEARCHED: Go `os/exec` documentation, `Cmd.Cancel`]. Only `#killsignal=<n>` replaces it with `Process.Signal(n)`, and `#killtimeout=<s>` sets `WaitDelay` (`internal/exec/exec.go` L95-105 [VERIFIED]). After `WaitDelay`, Go kills the process anyway [RESEARCHED: Go `os/exec`, `Cmd.WaitDelay`]. `Pdeathsig=SIGTERM` (`pkg/shell/procattr_linux.go` L5-6) applies only when go2rtc itself dies.
  - **With the line set:** on SIGTERM the helper stops its packet loop and keepalives, closes the camera socket, writes `session_end` with its duration, fsyncs, and exits 0 within 5 s.
  - **If SIGKILL comes anyway** (the 5 s pass, or go2rtc is SIGKILLed, or an OOM kill): the kernel closes the camera socket, so the camera sees a dropped connection with no clean close. The ledger has `login_ok` and no end record, which D4 classes at the next decision. The session lock (D18) is released by the kernel. The helper's ffmpeg child gets EOF on stdin and also has `PR_SET_PDEATHSIG` set by the helper, so it cannot outlive it.

- **D18. Two locks per camera: a short ledger lock, and a session lock held for the whole session** *(rev 2, F4)*. *Why:* a lock held only while deciding serialises the decisions, not the sessions. An old helper still streaming or closing (after a go2rtc restart or a SIGTERM) and a new helper could both hold sessions once 60 s have passed since the old one's login, which is almost always true. That would mean a second login and a second viewer (§2.2 item 7, R4; reviewer finding F4). So:
  - the **session lock** `$SNAP_COMMON/ezviz/state/<name>.session` is taken with `flock(LOCK_EX | LOCK_NB)` **before** the budget decision, and held until the camera socket is closed. If it is held, the new helper writes nothing to the camera, writes nothing to the ledger, and exits 75 with the class `busy`. The kernel releases it on any death, SIGKILL included;
  - the **ledger lock** (`flock` on the ledger file) is held only for read-decide-write and for the trim.

## 4. The helper, `ezviz-source`

### 4.1 Shape

```
go2rtc (daemon, root, network plug)
  │  preload: {<name>: video}   ← keeps the stream open across Frigate restarts (D2)
  └─ exec: $SNAP/bin/ezviz-source <name> rtsp://127.0.0.1:8554/<md5 path>#killsignal=15#killtimeout=5
       │   (go2rtc fills {output}; SIGTERM on stop, SIGKILL after 5 s: D17)
       ├─ stdlib only until the decision (os, fcntl, json, time): pyEzvizApi is imported only after it (N5)
       ├─ takes $SNAP_COMMON/ezviz/state/<name>.session  (flock LOCK_EX|LOCK_NB; held → exit 75 "busy", D18)
       ├─ under the ledger lock: reads $SNAP_COMMON/ezviz/state/<name>.ledger and the latch; classes any
       │   attempt with no outcome as net_fail (D4)
       ├─ if the latch is set or the budget forbids an attempt → exit 75 (budget_wait / latched), no camera contact
       ├─ writes "attempt", fsyncs the file and the directory, releases the ledger lock  ← BEFORE connect() (F3)
       ├─ reads $SNAP_DATA/ezviz/cameras/<name>.conf   (host, port 8000, serial, login; 0600 root)
       ├─ one login → media session → unbounded packets + keepalives → Annex-B H.265
       │   (the session lock stays held until the camera socket is closed)
       └─ pipes into $SNAP/usr/lib/ffmpeg/8.0/bin/ffmpeg -f hevc <timestamp args> -i pipe:0 -c copy -an -f rtsp {output}
            (the child env is built from scratch: PATH and LD_LIBRARY_PATH only)
```

go2rtc 1.9.14 passes `{output}` as a loopback RTSP URL on its own port, waits up to `starttimeout` (default 30 s) for the publish, and fails the producer if the command exits first [VERIFIED: go2rtc v1.9.14 `internal/exec/exec.go` L74-82, L111-116, L199-206]. The helper's start (login plus the first keyframe) must therefore fit in 30 s. Otherwise the exec line sets `#starttimeout=45`.

**Cheap refusals** *(rev 2, N5)*. While a camera is in `budget_wait`, latched or `busy`, go2rtc's re-dial ladder (1 s ×5, 5 s ×5, 10 s ×10, then 60 s) spawns a new helper each time. Each spawn is a Python 3.12 start. So the helper reads the locks, the ledger and the latch with the standard library only, and imports pyEzvizApi and its dependencies (crypto, requests) only after the decision allows a login. A refusal then costs a few milliseconds. S1 times it.

### 4.2 Failure and reconnect behaviour

| Event | The helper does | Who restarts it | Camera contact |
|---|---|---|---|
| Another helper for this camera holds the session lock | writes nothing, exits 75 (`busy`) *(rev 2, F4)* | go2rtc re-dials | none (the other helper owns the session) |
| Login refused (authentication) | writes `auth_fail` and **sets the latch**, exits 77 | go2rtc re-dials; each new helper sees the latch and exits 75 at once | none until an operator clears the latch |
| Timeout or connection refused before an authentication result | writes `net_fail` (counts as an attempt, D4), exits 75 | go2rtc re-dials; the ledger sets the next allowed time | at the next allowed time |
| Session drops after streaming (EOF, keepalive failure, decode stall > 10 s) | writes `session_end` with its duration, exits 75 | go2rtc re-dials; the backoff 60 s → 5 min → 15 min → window applies | at the next allowed time |
| ffmpeg child exits | closes the camera socket, writes `output_end`, exits 75 | go2rtc | as above |
| Frigate restarts, or Frigate's ffmpeg for the camera restarts | nothing: the preload consumer keeps the producer and the session alive *(rev 2, F2)* | — | none; **0 new logins** |
| go2rtc stops the producer (go2rtc stop or restart, `snap stop frigate`) | SIGTERM (from `#killsignal=15`, D17): stops the loop, closes the camera socket, writes `session_end`, fsyncs, exits 0 within 5 s *(rev 2, F1)* | none, or go2rtc's own restart | none |
| SIGKILL (the 5 s passed, go2rtc SIGKILLed, OOM kill, power loss) | nothing: the kernel closes the socket and releases the session lock; the ffmpeg child dies by `PR_SET_PDEATHSIG` *(rev 2, F1)* | go2rtc, when it runs | the next helper classes the open record (D4) and applies the backoff |
| Protocol error after login (e.g. a firmware change broke the templates) | writes `protocol_fail`; 3 in a row set the latch | go2rtc | none after the latch |

go2rtc itself is `restart-condition: on-failure` (`snap/snapcraft.yaml:86-90`). If go2rtc restarts, a new helper starts, but the session lock and the ledger still decide whether it may log in. A go2rtc restart therefore costs one login per camera; a Frigate restart costs none.

**Clearing a latch** is a deliberate operator act: `sudo snap set frigate ezviz.<name>.unlatch=$(date +%s)`. The configure hook removes the latch file and logs that it did. Nobody should clear a latch before knowing why the login failed (a wrong or changed code, or a camera reset). In that case the next step is the maintainer's.

### 4.3 The ledger

`$SNAP_COMMON/ezviz/state/<name>.ledger` (*rev 2, F3*: moved from `$SNAP_DATA`, see D7), root 0600, one JSON line per event: `{"t": <epoch>, "ev": "attempt|login_ok|auth_fail|net_fail|session_end|protocol_fail|latch|unlatch", "dur": <s>}`. It holds no host, serial or login. It is the evidence source for acceptance: logins are counted from the ledger, never from logs that might carry addresses.

- **Write order** *(rev 2, F3)*: the `attempt` record is appended and fsynced (the file, then its directory) **before** the first `connect()` to the camera. Every outcome record is fsynced as it is written. So no login can happen that the ledger does not know about, whatever kills the helper.
- **Records with no outcome** are classed at the next decision as D4 says.
- **Trimming** to the last 7 days rewrites the file as a temp file, fsyncs it, and renames it over the ledger, all under the ledger lock.
- **Locks** are as D18 says: the session lock for the whole session, the ledger lock only for read-decide-write and the trim. Two helper processes for one camera can never both hold a session.

### 4.4 Timestamps and keepalives (open technical points, settled by item A)

- **Keepalives.** The helper must keep the session alive past the built-in plan's six keepalives (§2.2 item 4). It can extend the observed `addend_delta` pattern (+6 per keepalive) every 5 s, or re-send the last keepalive template. It does this without patching the library *(rev 2, reviewer suggestion with N8)*: it passes a custom generated plan whose `keepalive_templates` tuple is longer. The library renders each template's addend as `session_id + addend_delta` modulo 2^32 (`streaming/local/hcnetsdk/protocol_types/framing.py` L388-400 [VERIFIED: wheel]), and the sender runs through the tuple at the interval (`session.py` L1104-1162). So a plan with, for example, 720 templates covers one hour; the helper re-opens nothing within that hour, and after it the probe (item A) shows whether the camera needs more. Which form the cameras accept is decided by the long-session probe (item A, §9). If neither works, the helper has to re-open the session about every 30 s. Every re-open is a login and is limited by D4, which would make the path unusable. **That is the main technical risk of this design.**
- **Timestamps.** Raw Annex-B carries no presentation timestamps. The options are:
  - (a) carry the RTP/IDMX timestamps from the packets into MPEG-TS (`-f mpegts -i pipe:0`);
  - (b) let ffmpeg stamp by wall clock (`-use_wallclock_as_timestamps 1`);
  - (c) assume a fixed rate (`-r 25`), which is not acceptable because of VBR and real frame-rate jitter.

  The plan picks (a) if the packets carry usable timestamps, and otherwise (b). Item A records which.

### 4.5 Logging without logins

- The helper's stderr reaches go2rtc. go2rtc keeps the first 512 bytes for its error message and logs every line at debug level [VERIFIED: go2rtc v1.9.14 `internal/exec/exec.go` L85-88, L224-247]. From there it lands in the journal, in `$SNAP_DATA/go2rtc-logs/current` and in Frigate's `/logs` page (`spike/bin/go2rtc-run:21-33`).
- So the helper prints only fixed-form lines: `ezviz-source <name>: <class> [attempt n/3 in window] [next allowed +Ns]`. They hold no host, serial, login or exception text.
- Unexpected exceptions print only the exception's **class name**, as the spike's wrapper did (W20-P `t10_capture_raw.py` L66-96).
- **The library's own logging is silenced** *(rev 2, N8)*: the helper installs a `NullHandler` on the `pyezvizapi` logger and sets `propagate = False`. Without a handler, Python's `logging.lastResort` prints library WARNINGs to stderr, which would carry library text, possibly with addresses, into go2rtc's log.
- go2rtc logs the exec `args` at debug level (`exec.go` L147, L187). They contain only the camera name and the `{output}` URL.
- **A test** feeds the helper a camera file with marker values for the host, serial and login, drives every failure class against a fake camera on loopback, and asserts that none of the markers appears in stdout, stderr, the ledger, argv (`/proc/<pid>/cmdline`) or the ffmpeg child's environment (`/proc/<pid>/environ`). Its mutation (print the host in one class) must fail it.

## 5. Runtime options compared (OD1)

| | **R1. Standalone CPython 3.12 in the frigate snap (recommended)** | R2. Vendor and backport a subset to the snap's Python 3.11 | R3. A separate small snap on base core24 | R4. A compiled helper (e.g. Go) |
|---|---|---|---|---|
| **What runs** | pyEzvizApi **2.0.0 as pinned and proven** (wheel sha256 equal to W20-P:65), plus our ~300-line helper | A fork of the needed modules, with 3.12 syntax removed, under the snap's `python3.11` | pyEzvizApi 2.0.0 on core24's own `python3.12`, plus a helper daemon that publishes RTSP into frigate's go2rtc | A from-scratch client: the HCNetSDK login (RSA challenge), the app plan's commands, keepalives, IDMX reassembly |
| **Size added** | **+20.1 MB compressed / +70.6 MB unpacked** for the interpreter *(rev 2, N4: one unit, MB)*, measured: python-build-standalone `cpython-3.12.16+20261110-aarch64-…-install_only_stripped` is 81.2 MB unpacked, 70.6 MB after removing tests, tk, ensurepip and headers, and 20,054,016 B as an xz squashfs [VERIFIED: in the scratchpad, `mksquashfs -comp xz`; the pruned tree was not import-tested]. The 13 hash-locked wheels are about 9.3 MB as aarch64 wheels [VERIFIED: PyPI JSON sizes] (≈ 8 MB more in the snap [ESTIMATE]). Total ≈ **+28 MB** on a 916.7 MB arm64 file, ≈ +3 % [ESTIMATE] | ≈ +1–3 MB: the code plus pycryptodome (2.5 MB wheel) and xmltodict; cryptography, requests and paho-mqtt already ship (`spike/wheels-src/requirements-core.txt:11, 20, 29`) [ESTIMATE] | 0 in frigate. The new snap is ≈ 10–15 MB, because core24 ships `/usr/bin/python3.12` [VERIFIED: core24 rev 2124 on the laptop]. **core26, the frigate snap's base, ships no interpreter** [VERIFIED: core26 rev 750, `find`: stdlib and docs only] | ≈ 5–10 MB static binary [ESTIMATE] |
| **New protocol code** | ≈ none: the packet loop, keepalive extension and reassembly only (D6) | **Large.** The static import closure of the two entry modules is 46 modules and 34,149 lines, even without package `__init__` side effects [VERIFIED: an AST closure over the 2.0.0 wheel]. Only a part of it is needed, but which part has to be found and kept up | ≈ none (as R1), plus an RTSP publisher | **All of it**, re-derived from pyEzvizApi's Apache-2.0 source (a derivative, so it needs a NOTICE) |
| **Proof needed against the cameras** | item A only (long session), which every option needs | item A, plus re-proving the backported login and plan | item A, plus the cross-snap publish | item A, plus the login, the plan and the reassembly from zero: **the most logins** |
| **Confinement / plugs** | none new: a go2rtc child (D2) | none new | a new snap with `network` (camera) and loopback RTSP to frigate's go2rtc, which today has no login on its RTSP (W-16) | none new (go2rtc child) |
| **Who restarts it** | go2rtc (D2), with the ledger gating logins (D3) | same | its own systemd unit (`restart-delay`); it runs whether or not Frigate consumes. That holds a camera viewer slot all the time, which R1 with preload (D2) does too while go2rtc runs, so this is not a difference *(rev 2, F2)* | go2rtc |
| **Upkeep** | pins: the interpreter tarball (sha256, both arches), 13 wheels (hashes). The library uses private calls, so any version bump is re-verified against the cameras | a fork to maintain; upstream fixes must be ported by hand | a second private Store snap, a second install on the hub, two release trains | a protocol stack of our own |
| **Isolation from Frigate's Python** | full: its own prefix under `$SNAP/opt/ezviz-py/`, never on Frigate's `sys.path` | **shares Frigate's interpreter** (packages go in a separate `--target` dir, but the interpreter is shared) | full | full |

Also considered and rejected:
- **Moving the snap's Python to 3.12.** Upstream Frigate 0.18.2 is built and tested on Python 3.11. Moving it would change Frigate's own runtime. That is out of scope and against D16.
- **The vendor's closed HCNetSDK.** It cannot be redistributed (W20-S D4).

**Why R1:** R1 runs only what W-20 proved and adds the smallest amount of new protocol code, at a measured 20.1 MB interpreter cost. R2 saves about 25 MB but turns the project into the maintainer of a 34k-line protocol fork. R3 saves frigate's size but adds a second Store snap, a second install on the hub and an RTSP publish into a go2rtc that has no RTSP login (W-16). R4 costs the most camera logins to prove.

## 6. Credentials and the hub config

### 6.1 Where each login comes from

- **Source:** the key file, `.["original QR Code keys"]["<CAM_SERIAL>"]`, the camera's label code (W20-P:14, 50; `make-config.sh:10, 95-102`). `new.common` is **not** used (D1).
- **Camera list:** `M7C_ENV_DIR/cameras.pairs` (`<camera id> <ipv4>`, two lines, 0600), as today (`make-config.sh:7-9, 84-93`). The camera id is the serial, which is also the key file's key (W20-P:16).
- **Writer:** `make-config.sh` with `M7C_SOURCE=ezviz` (D15), run by the maintainer from a card. On the hub it writes:
  - `/var/snap/frigate/current/ezviz/` root:root **0700**;
  - `…/ezviz/cameras/cam1.conf` and `cam2.conf`, root:root **0600**;
  - `/var/snap/frigate/common/ezviz/state/` (`$SNAP_COMMON`) root:root **0700**, created if absent and **never emptied** by make-config *(rev 2, F3)*;
  - `config.yml` (root 0600), as today, via `config.yml.m7c-new` and a sha256 compare (`make-config.sh:185-199`).

  Each file goes over stdin through the existing master. The sha256 of each is compared before the move into place. No value is printed.
- **Camera file shape** (placeholders):
  ```
  # written by tests/hub/make-config.sh (M7C_SOURCE=ezviz); root 0600; never print
  host=<CAM_HOST>
  port=8000
  serial=<CAM_SERIAL>
  login=<LOGIN>
  ```
- make-config's existing `validate-config` step runs after the write, and so does a new **snap app `frigate.ezviz-check <name>`** *(rev 2, N9)*. `ezviz-source` itself is a `$SNAP/bin` file that only go2rtc runs, so the check needs its own app. It needs no plug: it runs as root under confinement and reads `$SNAP_DATA` and `$SNAP_COMMON`. It verifies the camera file's shape, owner and mode and the state directory's mode, prints only fixed-form lines (`ezviz-check <name>: ok` or `ezviz-check <name>: <class>`), never a value, and **contacts no camera**.

### 6.2 What the camera order means

`cam1` and `cam2` follow the order of `cameras.pairs` (`make-config.sh:7-8`). The spec does not say which model is which. The frame-size probe (D9) runs per camera.

### 6.3 `config.yml` in `ezviz` mode (placeholders only)

It is the stand-in's D21 shape (`make-config.sh:157-163`) with the camera block changed. It contains **no `go2rtc.streams` entries for the cameras** (D8) and **no secret**:

```yaml
# M7c hub config, written by tests/hub/make-config.sh (M7C_SOURCE=ezviz); the rendered copy is config.yml.pre-h4.
mqtt: {enabled: false}
ffmpeg: {hwaccel_args: ""}
detectors: {coral: {type: edgetpu, device: usb}}       # unchanged from the rendered H4 config
record:
  enabled: true
  continuous: {days: 1}                                # soak value; production per OD2
  alerts: {retain: {days: 1}}
  detections: {retain: {days: 1}}
cameras:
  cam1:
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:8554/cam1
          input_args: preset-rtsp-restream
          roles: [detect, record]
    detect: {enabled: true, fps: 5}                    # width/height from the ffprobe at setup (D9)
  cam2:
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:8554/cam2
          input_args: preset-rtsp-restream
          roles: [detect, record]
    detect: {enabled: true, fps: 5}
go2rtc:
  rtsp: {listen: "127.0.0.1:8554"}                     # loopback, as today (W-16)
  webrtc: {listen: "127.0.0.1:8555"}
```

make-config's self-check (`make-config.sh:179-182`) hard-codes the retention values `1 1 1` today. Item B parameterises them (for example `M7C_RETAIN_DAYS`, default 1) so that S13 can set the OD2 value through the same reviewed path *(rev 2, F5)*. The self-check also gains these assertions:
- `go2rtc.streams` has no `cam1` or `cam2`;
- no URL with a login appears anywhere in the file (the clip mode's existing check);
- both camera files exist on the hub with mode 600 and owner root.

## 7. Disk, retention, CPU and Home Assistant

**Rates:**
- **Measured, stand-in:** two 1.6 Mbit/s recordings used about 1.2–1.3 GiB per hour (M7C-F:276, 317).
- **Measured, real cameras (10 s each):** about 1.6–1.7 Mbit/s (C3W) and 0.35 Mbit/s (CV310) (W20-S:34-42).

| Case | Mbit/s, both | GiB per hour | GiB per day |
|---|---|---|---|
| Expected (measured scenes) | ≈ 2.0 | ≈ 0.85 | ≈ 20 |
| Planning worst case (both at the C3W's 1.7) | 3.4 | ≈ 1.43 | ≈ 34 |

[ESTIMATE: 3.4e6/8 × 3600 B = 1.53 GB = 1.43 GiB per hour.] Night IR, motion and VBR spikes are NOT PROVEN (M7C-F:207-211). The soak measures the real rate.

**Free space:** 190 GiB on the hub's data filesystem at the end of run 3 (M7C-F:276). The disk is shared with Home Assistant.

| Retention (continuous; alerts and detections the same) | Worst-case use | Left of 190 GiB |
|---|---|---|
| 1 day (soak) | ≈ 34 GiB | ≈ 156 GiB |
| **3 days (recommended production, OD2)** | ≈ 103 GiB | ≈ 87 GiB |
| 7 days | ≈ 240 GiB | **does not fit** |

**Stop rules, disk:**
- **During the soak:** the laptop watcher in act mode, unchanged. It trips on free space < 20 GB, MemAvailable < 2 GB, memory PSI, load > 3.5 for 10 min, NRestarts +3 in 10 min, swap +1 GB, or Home Assistant slow or restarted (`tests/hub/watch.sh:3-14`).
- **Always, from the helper build on:** the hub-side guard of D13 (floor 20 GiB, `snapctl stop --disable frigate.frigate`).
- **Last line:** Frigate's own one-hour cleanup (`storage.py` L107-118).

**CPU (Home Assistant keeps its cores):**
- The quota group `frigate-mem` stays at 4 GB of memory and 2 × 100 % CPU (M7C-F:222). go2rtc and the helpers are inside it, because the group holds the whole snap.
- On the stand-in, decoding one 1080p25 H.265 stream for detect cost 51.9–53.1 % of a core (M7C-F:307), and the slice averaged 0.85–0.94 cores with one 1080p and one 360p detect (M7C-F:287-297).
- Here **both** cameras detect at 1080p (D9). Estimate: ≈ 1.4 cores for the slice, plus the two helpers (a Python packet loop each, ≈ 0.05–0.1 core [ESTIMATE]). This is under the 2-core cap, but throttling will rise above the stand-in's 1.5 % [ESTIMATE].
- The detect-at-1280×720 lever (D9) is the first fallback. Raising the cap is the maintainer's call.

**Memory:**
- The stand-in's anon + shmem was 1,180–1,271 MiB (M7C-F:300).
- A second 1080p detect adds about 150 MiB of frame buffers (50 frames × 1920 × 1080 × 1.5 B ≈ 156 MB) [ESTIMATE].
- Each helper's Python is ≈ 40–60 MB RSS [ESTIMATE].
- Expected total ≈ 1.5 GiB, under the 4 GB cap. NOT PROVEN until the soak.

## 8. Out of scope

- **The hub firewall** (W-18). nginx 8971 stays on the LAN as today; go2rtc stays on loopback (M7C-F:230).
- **Moving the hub to a Store install.** That needs a `snap login` on the hub with the maintainer's account, which is the maintainer's own step (W-23 Details 5). OD3 only chooses how *this* build reaches the hub.
- **Frigate's stop timeout and graceful shutdown** (M7C-F finding a: 4 of 4 stops were SIGKILLed after 30 s; finding d: the `/dev/shm` leftover), and the cold-boot Coral race (finding b). This spec only records how they show up in acceptance (§9).
- **Anything that changes a camera's settings**: encryption, RTSP switch, firmware, auto-update (D16, W20-S D5).
- **The general `exec:` source filter** (W-14 D13 / W-16). D8 only keeps the helper streams compatible with it. go2rtc 1.9.14 also offers `exec.allow_paths` [VERIFIED: `exec.go` L29-38, L90-93]; adopting it belongs to that work.
- **MQTT and the Home Assistant integration** (W-15). MQTT stays off as in D21.
- **Audio** (D10, OD4).
- **The amd64 laptop**: this route serves the hub. The helper ships in both arches' builds because the snap is one recipe. Running it on amd64 is not a goal here.

## 9. Later items, in order, and acceptance

### 9.1 The split

| Order | Item (proposed) | Kind | Where | Gate to the next |
|---|---|---|---|---|
| **A** | **Long-session probe**: one login per camera per run, a 60-minute session with extended keepalives, timestamps recorded, audio presence recorded, both cameras at once in the last run. W-20's off-snap tooling (laptop, Python 3.12 venv, hash-locked), extended | spike | laptop, the cameras; each run on the maintainer's go | the session survives 60 min on both cameras with ≤ 1 login each; one keepalive form and one timestamp form are chosen. **If no keepalive form holds a session past ~30 s, stop here and come back to the maintainer** (D4 makes the path unusable) |
| **B** | **Helper build**: the runtime part (R1 or the OD1 choice), `ezviz-source` (login, loop, keepalive, reassembly, ledger, locks, latch), generator emission with preload and kill signal (D8), the disk guard (D13), the `ezviz-check` app, make-config `ezviz` mode with parameterised retention (F5), unlatch in the configure hook, tests with mutations, a new arm64 and amd64 build. **The fake camera for S2 is likely its largest single task** *(rev 2, N10)*: it must do the HCNetSDK key exchange and RSA challenge login, accept the plan's command frames and stream `$`-framed IDMX/FU HEVC synthesised from an encoded test clip, because no real capture exists (W20-P:36). **Fallback** if the login half costs too much: inject at the library boundary (stub the login client, feed synthesised packets to the packet iterator). That leaves the login exchange proven only by W-20's real runs and item A | bounded build, own plan | laptop worktree, CI, Launchpad | S1–S2 pass; the arm64 artifact's sha256 is recorded |
| **C** | **Hub switch**: install `x2` (OD3), hold, check plugs and the quota group; write the config and camera files (card); start; first checks | deploy | **hub**, every step on the maintainer's go (D14) | S3–S7 pass |
| **D** | **Soak and production**: 24 h under the watcher, the guard test, the stop, the cold boot, then retention to the OD2 value and `--enable` | acceptance | **hub** | S8–S13 pass; the maintainer accepts |

Rollback is available at every hub step (§9.3).

### 9.2 Acceptance steps

"HUB" means the step runs on the hub, so it needs the maintainer's go for that step and is run by the orchestrator or the maintainer, never by a worker. **«yours»** means only the maintainer can pass it. Those steps need eyes on a picture: no agent opens a camera frame, because that would send an image of the maintainer's home to a model API (W20-S risk 9).

| Step | What passes | Who | HUB | Needs the maintainer's go |
|---|---|---|---|---|
| **S1** | Helper tests pass on the laptop: the ledger refuses a 4th attempt in 60 min and an attempt within 60 s; the backoff ladder resets after a ≥ 60-min session (N6); `auth_fail` latches and a new process exits 75 with no socket opened; `net_fail` counts as an attempt; an `attempt` with no outcome is classed `net_fail` (F3); the `attempt` record is on disk before the fake camera sees a connect (F3); a second helper while the first holds a session exits 75 `busy` and the fake camera sees one login (F4); SIGTERM gives `session_end` and exit 0 within 5 s (F1); a protocol failure three times in a row latches; a `budget_wait` refusal takes < 150 ms and imports no pyEzvizApi module (N5); the marker-leak test of §4.5 passes, library logging included (N8). **Each of these fails under its mutation** (for example: drop the session lock → two logins; write `attempt` after connect → the test sees a connect with no record) | worker | no | no |
| **S2** | On the laptop, against a **fake camera on loopback** (no real camera): go2rtc 1.9.14 with the generated exec line serves `cam1`; a decoding consumer gets ≥ 250 frames in 10 s; when go2rtc is killed and restarted, the fake camera sees exactly one new login per allowed attempt and zero during `budget_wait`; with the generated `preload`, removing and re-adding the only consumer (a Frigate-like restart) causes **0** new logins (F2); a go2rtc stop sends the helper SIGTERM, not SIGKILL (F1); an operator `cam1` entry in `config.yml` is dropped by the generator with a redacted warning (N7) | worker | no | no |
| **S3** | `x2` installed from the file whose sha256 matches the CI artifact; held; 4 plugs connected; `frigate-mem` unchanged (4 GB, 2 × 100 %); frigate stopped and disabled; the `x1` revision still listed for revert | orchestrator | **yes** | **yes** |
| **S4** | `make-config.sh` in `ezviz` mode, run from the maintainer's card: it prints `ok`, `validate-config rc=0`, both camera files at mode 600, and `frigate.ezviz-check` passes for both (N9); its output holds no login (make-config's own checks) | **maintainer** (card) | **yes** | **yes** (the maintainer runs it) |
| **S5** | Start: `sudo snap start frigate` (**not** `--enable` yet). Within 5 min: 4 daemons active; both cameras `camera_fps` ≈ 5 and `skipped_fps` 0; each camera's ledger shows **exactly 1** `login_ok` and 0 failures | orchestrator | **yes** | **yes** |
| **S6** «yours» | The maintainer opens Frigate's UI. **Live view** of both cameras shows the right scenes, and one **recorded clip** from each camera from the last hour **plays**. This settles §2.2 item 1 | **maintainer** | yes (a browser) | the maintainer's own step |
| **S7** | The Coral under real load: within the soak, at least one snapshot with `detection_fps` > 0 **and** `inference_speed` changed from its start value of 10 ms (M7C-F:244). The maintainer confirms at least one real detection in Review («yours» part) | orchestrator + maintainer | **yes** | **yes** |
| **S8** | **24-hour soak**, watcher in act mode: 0 TRIP lines; `NRestarts` 0 for frigate and go2rtc; Home Assistant HTTP 200 in ≥ 99 % of samples with no 3-in-a-row failure; per camera ≤ 3 logins in every rolling hour and ≤ 12 logins in 24 h; recordings cover ≥ 99 % of the 24 h per camera (Frigate's recordings summary, numeric fields only); anon + shmem recorded at 30 min, 6 h and 24 h; **one Frigate-only restart** during the soak (`sudo snap restart frigate.frigate`) adds **0** `login_ok` to either ledger (F2) | orchestrator | **yes** | **yes** (start, and the restart) |
| **S9** | The disk guard on the real hub: `snap set frigate disk-floor-gib=<free + 10>` → frigate is stopped and disabled within 10 min with one guard line; the floor is reset to 20; restart on the maintainer's go | orchestrator | **yes** | **yes** |
| **S10** | The stop: `sudo snap stop frigate`. Both `ezviz-source` processes are gone within 10 s (no orphan session), and each ledger ends with `session_end` (the SIGTERM path, F1); the db-quiesce hook prints `result=ok`; the last segment of each camera plays («yours»). A SIGKILL of Frigate after 30 s is **recorded, not failed**: known finding a, out of scope | orchestrator + maintainer | **yes** | **yes** |
| **S11** | The cold boot: `sudo snap start --enable frigate`, then **the maintainer reboots the hub** (it restarts Home Assistant too). Within 5 min of boot: all services active, both cameras at fps; frigate `NRestarts` ≤ 1 (finding b may self-heal once); each camera 1 `login_ok` | maintainer (reboot) + orchestrator (checks) | **yes** | **yes** |
| **S12** | The phone app while Frigate records: the maintainer opens LAN Live View on one camera for 1 minute. Recorded: does the app play, and does Frigate's stream for that camera continue? Either outcome is accepted and recorded; a helper latch is a **fail** | maintainer + orchestrator | **yes** | **yes** |
| **S13** | Production: retention set to the OD2 value through make-config's parameterised retention (frigate stopped first, as make-config requires); start `--enable`; the D13 guard active at floor 20. make-config reads the key file in `ezviz` mode, so under D15 the maintainer runs it from a card *(rev 2, F5)*; the stop and start around it run on the maintainer's go | **maintainer** (card) + orchestrator (stop/start) | **yes** | **yes** (the maintainer runs it) |

### 9.3 The start/stop rule and rollback for the hub Frigate

**Today:** installed `x1`, held, stopped, disabled (card W-7 decisions 2 and 13).

- **Start:** only on the maintainer's direct go.
  - From S5 to S10: `sudo snap start frigate`. It is not enabled, so a hub reboot during the soak leaves it down. That is safe: the watcher would be blind too (M7C-F:257).
  - From S11 on: `sudo snap start --enable frigate`. This is the production state, started at boot.
- **Stop:** `sudo snap stop --disable frigate`. It is run by:
  - the watcher in act mode on any trip;
  - the D13 guard (from the helper build on);
  - the orchestrator on the maintainer's go;
  - or the maintainer at any time.

  If the watcher goes blind during the soak, the orchestrator says so to the maintainer at once. Frigate keeps running under the quota and the D13 guard.
- **A latch is not a stop.** A latched camera goes dark in Frigate. Frigate keeps running for the other camera. The latch is reported to the maintainer, who decides whether to clear it (§4.2).
- **make-config refuses to write while frigate is running** (`make-config.sh:119-121`). So every config change is: stop, write, start.

| Rollback to | Commands (HUB, the maintainer's go) |
|---|---|
| **The stand-in** (no cameras) | stop; `M7C_SOURCE=clip tests/hub/make-config.sh` (it rebuilds from `config.yml.pre-h4`; the clips are still in `/var/snap/frigate/common/m7c-clips`, `make-config.sh:33-38`); `sudo rm -rf /var/snap/frigate/current/ezviz` (the camera files, i.e. the logins). The ledger and latch in `/var/snap/frigate/common/ezviz/state` are **kept on purpose** *(rev 2, F3)*: they hold no secret, and a later switch back must not forget a latch or the last hour's attempts. To forget them deliberately: `sudo rm -rf /var/snap/frigate/common/ezviz`, only on the maintainer's go and only when no latch is set; start only on a go |
| **The rendered H4 config** | stop; `sudo cp -p /var/snap/frigate/current/config/config.yml.pre-h4 /var/snap/frigate/current/config/config.yml` (`make-config.sh:45`) |
| **Revision `x1`** | stop; `sudo snap revert frigate --revision x1` [UNVERIFIED for two local revisions; the plan checks it]; the camera files stay with `x2`'s data, and the ledger and latch in `$SNAP_COMMON` stay for any later revision (F3) |
| **Nothing at all** | stop, and leave it disabled (today's state) |

## 10. NOT PROVEN, and what would prove each

| # | NOT PROVEN | What proves it | Item |
|---|---|---|---|
| 1 | A meaningful picture (constant luma in W-20) | S6: the maintainer sees live view and plays clips | C |
| 2 | Audio on port 8000 | Item A records whether AAC is present; OD4 | A |
| 3 | Reconnect after a drop | S2 (fake camera) for the logic; S8's ledger, with `session_end` followed by a `login_ok`, on the real cameras | B, D |
| 4 | A session past the six built-in keepalives (~30 s) | Item A: 60 min per camera with extended keepalives | **A (the deciding risk)** |
| 5 | Both cameras at once | Item A's last run; S5 and S8 | A, C, D |
| 6 | The camera's real lockout limit, and whether successful logins count | Not tested on purpose: provoking a lockout is not acceptable. D4 keeps us under the W-20 budget. S8's counts show the real login rate | — |
| 7 | Concurrent local viewers (phone app plus Frigate) | S12 | D |
| 8 | pyEzvizApi and the helper on aarch64 | S2 on an arm64 build (or the hub's S5) | B, C |
| 9 | Usable timestamps from the reassembled stream | Item A chooses (a) or (b) in §4.4; S8's recording coverage | A, D |
| 10 | The plan's command templates surviving firmware updates | Not provable ahead of time. The `protocol_fail` latch limits the damage | — |
| 11 | CPU with two 1080p detect decodes plus the helpers, under the 2-core cap | S8: slice cores, throttled share, `camera_fps`, `skipped_fps` | D |
| 12 | Memory: anon + shmem with two 1080p detects and real objects | S8 at 30 min, 6 h and 24 h; feeds M7C-S D13b | D |
| 13 | The disk rate of the real scenes (night, motion) | S8: free space over 24 h | D |
| 14 | `snapctl stop --disable` from a snap app (D13) | A plan-time test in a VM or on the laptop install, before S9 | B |
| 15 | `snap revert` between two `--dangerous` revisions | A plan-time test on the laptop | B |
| 16 | The pruned standalone interpreter imports everything the helper needs | the helper build's artifact import check (as M8's import proof) | B |
| 17 | The helper's start (login plus the first keyframe) within go2rtc's 30 s `starttimeout` | Item A measures the time to the first keyframe; S5 | A, C |
| 18 | A preloaded stream survives a Frigate-only restart with 0 logins (read from go2rtc source, not run) *(rev 2, F2)* | S2 on the laptop; S8's Frigate-only restart on the hub | B, D |
| 19 | `#killsignal=15#killtimeout=5` gives the helper SIGTERM and 5 s (read from go2rtc source, not run) *(rev 2, F1)* | S1/S2 on the laptop; S10's `session_end` records | B, D |
| 20 | A longer custom `keepalive_templates` tuple is accepted by the cameras | Item A | A |
| 21 | The fake camera is faithful enough that S2 proves the real login path *(rev 2, N10)* | Not fully provable: the fake's login half is built from the library's own code. Item A and S5 are the real proof | B, C |

## 11. Open decisions for the maintainer (pick one; recommended first)

**What keeping encryption on costs in daily use** *(rev 2, N11; not a new decision, the W-20 rule)*: each camera may log in at most 3 times an hour. If a camera's connection drops 3 times in one hour, that camera stays dark for up to about an hour. Frigate restarts no longer count as drops (D2). If a camera's code is wrong or changed, or the camera was reset, that camera stays dark until the maintainer clears its block with `sudo snap set frigate ezviz.<name>.unlatch=$(date +%s)`. This is the price of never risking another day-long lockout.

- **OD1. How the helper gets the newer Python that the camera library needs.**
  1. **A separate Python 3.12 inside the snap, used only by the helper, running the exact library version W-20 proved. About +28 MB on the ~917 MB arm64 file *(recommended)*.**
  2. Copy the needed parts of the library into the snap and rewrite them for its Python 3.11 (+~3 MB, but a large fork to maintain).
  3. A second, separate small snap for the camera bridge (no growth of the frigate snap, but a second private Store snap to install and update).
  4. Write our own client in Go (smallest runtime, but the most camera logins to prove it).
- **OD2. How long the hub keeps recordings after the soak.**
  1. **3 days of continuous recording, with alerts and detections also kept for 3 days: at most about 103 GiB of the 190 GiB free *(recommended)*.**
  2. Keep 1 day (as in the soak, at most about 34 GiB).
  3. 2 days (at most about 69 GiB).
- **OD3. How the new build reaches the hub.**
  1. **Copied as a file and installed like today's copy (`--dangerous`, becomes `x2`), held and stopped *(recommended: no Store login needed on the hub)*.**
  2. The maintainer first does a `snap login` on the hub, then the build is installed from the Store (moves the hub to Store updates; the maintainer's step, its own item).
- **OD4. Audio.**
  1. **Video only for now; add audio later if the probe finds it on this path *(recommended)*.**
  2. Include audio in the first build (needs the probe to show AAC first, and more helper code).

## 12. What I could not verify

- Anything on the hub or the cameras. I contacted neither (D14 and the brief).
- The aarch64 base snaps. The core24 and core26 interpreter checks ran on the laptop's **amd64** bases (core24 rev 2124, core26 rev 750).
- That the pruned standalone interpreter imports the helper's dependency set. Only its size was measured.
- The squashfs size of the 13 wheels. It is estimated from their compressed wheel sizes.
- The packet format of `iter_packets()` over a long session, and whether the packets carry RTP timestamps. I read code; no capture exists, because the raw W-20 files were deleted by design (W20-P:36; W20-S:21).
- That `snapctl stop --disable` works from an app context (forum answers only).
- The size of the alerts and detections retention when the scene is busy. The 3-day figures assume they never exceed continuous retention.
- *(rev 2)* go2rtc's preload and kill-signal behaviour was read in its v1.9.14 source, not run. S1, S2, S8 and S10 run it.
- *(rev 2)* Whether a fake camera can do the RSA login well enough for S2 (N10).

## Sources

- **This repo** on `origin/main` `8b3adb6`: `docs/m7c-findings.md`; `tests/hub/make-config.sh`, `tests/hub/watch.sh`; `spike/bin/go2rtc-config-gen.py`, `spike/bin/go2rtc-run`; `snap/snapcraft.yaml`; `spike/wheels-src/requirements-core.txt`.
- **Branch `spec/ezviz-encrypted-streams` `d5260d4`:** the W-20 spec and plan, and `docs/superpowers/plans/ezviz-t10/*`.
- **Branch `spec/m7c-arm64-research` `4731a7f`:** the M7c spec (D14, D21, §8).
- **Cards:** W-7 (Q13, decisions 2 and 13), W-20 (Details, decisions 1-4), W-23 (Q1, and the slot 2 review of `61be7f3`: F1 to F5, N1 to N11).
- **Upstream code:** pyEzvizApi 2.0.0 wheel (PyPI, sha256 as pinned in W20-P:65); go2rtc v1.9.14 `internal/exec/exec.go`, `internal/streams/producer.go`, `stream.go`, `streams.go`, `preload.go`, `pkg/shell/command.go` and `pkg/shell/procattr_linux.go`; pyEzvizApi `streaming/local/hcnetsdk/protocol_types/framing.py`; Go `os/exec` documentation (`Cmd.Cancel`, `Cmd.WaitDelay`); Frigate v0.18.2 `frigate/storage.py`.
- **python-build-standalone** release 20261110 (GitHub release API sizes, one tarball measured).
- **PyPI JSON** for the wheel sizes.
- **snapcraft forum** threads 1908 and 13649 (`snapctl` service control from apps).
