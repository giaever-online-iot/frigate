# W-23 Findings: the hub's Frigate on the real cameras (helper build)

Evidence from the W-23 build, in the order the acceptance steps of the spec
(`docs/superpowers/specs/2026-11-16-hub-real-cameras-design.md` §9.2) produce it. Every address below is a
loopback address (127.0.0.x); every camera id and login code is a made-up test canary.

## S2 (laptop, fake camera)

**Test:** `tests/ezviz/serve-ezviz.test.sh` (W-23 T15), run under `flock -w 3600 /tmp/claude-1000/chim-suites.lock`
on 2026-11-19. **Result: 43 ok, 0 FAIL** (192 s of scenarios, 3 min 17 s wall time). Two consecutive full runs gave
the same 43 ok / 0 FAIL. The first run (before the frame-count fix described below) gave 41 ok / 2 FAIL (checks 1
and 10).

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
| 1 | ok | cam1 **251 frames** in 10 s, 0 decode errors after the first decoded frame (66 join errors before it, see below); 1 login |
| 2 | ok | kill -9 go2rtc: ledger `stop` (Pdeathsig, under 0.1 s); restart: 2 `budget_wait` refusals, 0 camera contacts, then exactly 1 login, 79.9 s after the previous attempt |
| 3 | ok | consumer removed and re-added: logins 2 → 2, ledger records 7 → 7, same helper pid |
| 4 | ok | SIGTERM to go2rtc: the ledger ends `stop` (a SIGKILL would write none), and the helper is gone under 0.2 s later |
| 5 | ok | the operator `cam1` was dropped with 1 redacted warning; 0 canary hits; 1 helper, 1 login |
| 6 | ok | the start-time preload fails in `budget_wait`; `GET /api/preload` lists cam1 at **+91.7 s** (limit 150 s); remove/re-add: 0 new logins |
| 6m | ok | without the re-arm line, check 6's verdict is FAIL (never listed); the consumer remove/re-add costs 1 login |
| 7 | ok | clean restart after a **70.0 s** published session: exactly 1 new login, `login_ok` **2.1 s** after the SIGTERM |
| 8a | ok | GETs at +30.1 s (503, injected) and +60.1 s (200); 0 PUT, 0 `stop`, 1 login in total |
| 8b | ok | PUT held 41.6 s, then 200; 0 requests while it was open; the next request came 30.0 s after the answer; 1 login |
| 9 | ok | 1 warning each for local_auth, base_path and allow_paths; 0 value canaries in the logs; re-armed (listed, `armed`); 1 attempt |
| 9m | ok | without step 7 of the generator, check 9's verdict is FAIL; `ezviz-rearm: api_refused`, 0 `armed`, 0 attempts |
| 10 | ok | cam1 **250** and cam2 **251 frames** in 10 s, 0 errors after sync; 1 login each; 2 helpers |

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

So checks 1 and 10 now decode 13 s with `showinfo`. They count the frames whose pts lie in the 10 s after the first
decoded frame, and the decoder error lines after that frame (required: 0). The join errors before it are reported as
evidence and not asserted.

The same join happens to Frigate's own ffmpeg on every restart of a preloaded stream (D2). It costs up to one GOP of
frames and is not a login. tests/hub/serve.test.sh never saw it, because there every consumer started its own
producer at an IDR.

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
