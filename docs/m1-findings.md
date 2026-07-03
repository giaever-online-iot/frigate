# M1 Findings — go2rtc, first real component

**Date:** 2026-07-03  **Snap:** frigate 0.0.1-spike (core26, strict)  **go2rtc:** v1.9.13  **ffmpeg:** n8.1.1 (labeled "8.0" in snap; sourced from Frigate MASTER HEAD)

| # | Question | Verdict | Evidence |
|---|----------|---------|----------|
| M1-1 | go2rtc v1.9.13 runs strict-confined as a snap daemon? | YES — first try, 0 new denial arms; network+network-bind cover ports 1984/8554/8555 | spike/results/go2rtc-streams.json (`snap services frigate.go2rtc` active), spike/results/denials.txt (10 total, 0 unexpected) |
| M1-2 | Consumer-side readiness gate works, measured? | YES — waited_ms=600–606 ms across runs; includes ~600 ms python3.11 startup floor for two timing calls (two poll iterations each spawning python3.11); gate proves provider ANSWERED (`/api/streams` returned 200), distinct from systemd start-order; consumer-side pattern confirmed for M3/M4 reuse | spike/results/spike-results/ordering-svc-a.json (waited_ms=606 final run; task-3 run=600), spike/bin/lib-wait.sh (overhead comment) |
| M1-3 | go2rtc spawns ffmpeg (exec:) under strict confinement? | YES — exec producer active; ffmpeg path `/snap/frigate/x1/usr/lib/ffmpeg/8.0/bin/ffmpeg` appears in go2rtc stream state under key `producers[0]` | spike/results/go2rtc-producer.json |
| M1-4 | RTSP restream consumable end-to-end? | YES — H.264 High profile, 1280×720, 15 fps consumed by the snap's own ffprobe (frigate.ffprobe, n8.1.1 tree) via `rtsp://127.0.0.1:8554/test` | spike/results/rtsp-probe.json (codec_name=h264, profile=High, width=1280, height=720, r_frame_rate=15/1) |
| M1-5 | WebRTC ports + WHEP under strict confinement? | SDP-answer branch — HTTP 201 with full SDP (ICE ufrag/pwd + DTLS fingerprint + H264/90000 sendonly) to the canned WHEP offer; TCP 8555 LISTEN + UDP 8555 UNCONN bound across all interfaces; 0 new denials. Manual browser media-flow / LAN-ICE check NOT performed — automated SDP proof supersedes for confinement purposes; media-flow and LAN-ICE check pending operator | spike/results/whep-status.txt (201), spike/results/whep-response.txt (full SDP) |
| M1-6 | mDNS multicast under network+network-bind alone? | YES — multicast group join (224.0.0.251:5353) OK, PTR query sent, 16 responses (prior run observed 5) from 5 unique senders = 4 external LAN responders (192.168.254.1, .126, .154, .246) + 1 self (192.168.254.16, host avahi) — true LAN multicast reach, not self-echo; within 3 s, 0 AppArmor denials; avahi-observe and network-control are NOT required | spike/results/spike-results/mdns.json (status=complete, multicast_join.ok=true, responses=16, unique_senders=5) |

## Decisions unlocked for M2+

- **Readiness pattern confirmed:** `wait_for_url <url> <timeout_s>` in `lib-wait.sh` is the M1 consumer-side gate pattern. Reuse verbatim in M3 (Frigate core waits for go2rtc) and M4 (detector waits for Frigate core). `waited_ms` in the ordering JSON proves the provider answered before the consumer continued. A `waited_ms` of −1 indicates a 60 s timeout (gate failed).

- **avahi-observe NOT needed for ONVIF/mDNS discovery:** Raw mDNS multicast (224.0.0.251:5353, UDP) works under `network` + `network-bind` alone. For ONVIF camera discovery via mDNS/WS-Discovery, the production Frigate snap needs no additional interface waiver. If avahi-daemon D-Bus registration is chosen instead of raw sockets in a future milestone, `avahi-observe` would be needed for that path only.

- **No new denial arms added in M1:** go2rtc, the exec: ffmpeg subprocess, and the mDNS probe all operated within the existing denial filter. The M1 snapcraft.yaml adds `network` + `network-bind` for go2rtc; nothing beyond that.

- **ffmpeg version matrix — M2 decision required:** The snap stages the NickM-27 FFmpeg-Builds 8.x autobuild (ffmpeg `n8.1.1-9-g58d4114d36-20260602` — that string is FFmpeg's own git-describe, not a Frigate commit), matching what Frigate master's `DEFAULT_FFMPEG_VERSION=8.0` resolves to; the v0.17.2 tag instead pins only 5.0/7.0. M2 must decide: track the tag-exact matrix (5.0/7.0) or follow master-style (n8.1.x). Current build is master-style; if tag-exact is required, a rebuild and snapcraft.yaml pin update are needed.

- **Config template pattern for M3:** go2rtc is started via `go2rtc-run`, a shell wrapper that substitutes `__SNAP__` with `$SNAP` before writing the config and exec'ing go2rtc. The same `__SNAP__` / `__SNAP_DATA__` substitution pattern is appropriate for `create_config.py` in M3 where Frigate's `config.yml` will need runtime snap path injection.

## Extra findings

- **Strict confinement denies loopback socket without `network` plug:** During M1 Task 3 development, `svc-a`'s `wait_for_url` (using `urllib.request.urlopen`) was denied at every poll attempt with the kernel journal line: `apparmor="DENIED" operation="create" class="net" info="failed af match" ... comm="python3.11" family="inet" sock_type="stream" protocol=6 requested="create" denied="create"`. This denial fires even for 127.0.0.1 connections. Any snap app that talks to a localhost service requires `plugs: [network]`.

- **`date +%s%3N` returns nanoseconds on core26 base:** The `%3N` width-truncation modifier is unsupported in the core26 base system's date binary; it returns a 19-digit nanosecond value instead of a 13-digit millisecond value. All snap-internal scripts must avoid `date +%s%3N` and prefer `python3.11 -c "import time; print(int(time.monotonic() * 1000))"` for millisecond timing. lib-wait.sh documents this.

- **Python3.11 startup cost is ~300 ms per invocation:** `wait_for_url` spawns python3.11 twice (t0 and t1 timing calls). Each invocation adds ~300 ms, so the minimum recorded `waited_ms` is ~600 ms even when the provider answers on the first poll. Subtract ~600 ms when calibrating true network wait. For sub-ms measurement in M3/M4, use a single persistent python process or curl-based timing.

## Deviations from expectations

- `date +%s%3N` nanosecond behavior was not anticipated in the M1 plan; worked around using snap-internal python3.11 monotonic timing.
- `plugs: [network]` on `svc-a` was not in the brief; required for loopback `wait_for_url` (journal-verified denial, appended in fixer commit 2fe5d17).
- jqr shell function is not available in subshells (`sh -c`); brief's assertion template adapted to inline `jq -r` with the pre-expanded `$RESULTS` path.
- ffmpeg n8.1.1 tagged as "8.0" in the snap — sourced from Frigate MASTER HEAD, not the v0.17.2 release tag. The discrepancy is adjudicated and recorded in the M1 ledger entry; M2 decision required.

## Harness status (final run 2026-07-03)

ALL PASS except 3 coral checks (Coral USB device physically absent; M0-verified finding C2 unaffected). All M1-specific checks (M1-1 through M1-6) pass. 0 unexpected AppArmor denials (10 total, all pre-catalogued from M0).

## Raw evidence

- `spike/results/m1-final-run.txt` — Final M1 harness run (2026-07-03, `--skip-install`): all M1 checks PASS, 3 coral FAIL (device absent)
- `spike/results/go2rtc-streams.json` — go2rtc `/api/streams` response: stream `test` with exec producer listed
- `spike/results/go2rtc-producer.json` — go2rtc `/api/streams?src=test` response: `producers[0].url` confirms confined ffmpeg exec path
- `spike/results/rtsp-probe.json` — ffprobe JSON output: H.264 High, 1280×720, 15 fps
- `spike/results/whep-status.txt` — WHEP HTTP status code: 201
- `spike/results/whep-response.txt` — WHEP SDP answer body: ICE credentials, DTLS fingerprint, H264/90000 sendonly
- `spike/results/spike-results/mdns.json` — mDNS probe result: join ok, responses 16 (prior run observed 5), 5 unique senders = 4 external LAN responders (192.168.254.1, .126, .154, .246) + 1 self (192.168.254.16, host avahi) — true LAN multicast reach, not self-echo, 0 denials
- `spike/results/spike-results/ordering-svc-a.json` — svc-a ordering record: waited_ms=606 (final run)
