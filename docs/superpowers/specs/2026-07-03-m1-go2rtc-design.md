# M1 Design Spec — go2rtc: first real component of the Frigate snap

**Date:** 2026-07-03
**Status:** Approved design, pre-implementation
**Parent spec:** [`2026-07-02-frigate-snap-design.md`](2026-07-02-frigate-snap-design.md) (§4-M1)
**Evidence base:** [`docs/spike-findings.md`](../../spike-findings.md) (M0)

## 1. Goal

Replace the first piece of scaffolding with production reality: the real **go2rtc v1.9.13** binary (the version Frigate v0.17.2 pins) running as a strict-confined snap daemon, streaming a **synthetic camera** end-to-end over RTSP, with the **consumer-side readiness pattern** established and the two M0-deferred verifications (**WebRTC UDP/ICE**, **mDNS multicast**) answered with evidence.

## 2. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Home | Evolve `spike/` in place; rename at ship time (M7) | Preserves harness, sudoers path, LXD part caches, always-green loop |
| Daemon topology | go2rtc at the **head** of the existing chain: `go2rtc → svc-a → svc-b → svc-c` | Readiness proven against a real provider; all M0 probes stay as regression daemons; option C (replace svc-a) churns the probe registry for no gain |
| Readiness | **Consumer-side wait helper** (`wait_for_url`) | Readiness-at-start is one-shot; the consumer must tolerate a vanishing provider at runtime anyway (upstream Frigate retries); notify shim = mini-init with unit-level failure modes; upstream fidelity |
| Test stream | **Stage ffmpeg "8.0"** (NickM-27 static gpl) in M1 | Self-contained snap; proves go2rtc can spawn ffmpeg subprocesses under strict confinement — an M2/M3 prerequisite verified early |
| Scope | **WebRTC + mDNS both in M1** | go2rtc is the natural home for both deferred questions |

## 3. Components

### 3.1 New snapcraft parts
- **`go2rtc`**: upstream release binary `v1.9.13` (`go2rtc_linux_amd64`), downloaded at build with **sha256 pin** (M0 convention: `sha256sum -c` after fetch), staged at `usr/local/go2rtc/bin/go2rtc` (upstream layout).
- **`ffmpeg`**: NickM-27/FFmpeg-Builds static gpl tarball for the tree upstream labels "8.0", **sha256-pinned**, staged at `usr/lib/ffmpeg/8.0/bin/{ffmpeg,ffprobe}` (upstream layout — M2 adds the 7.0/5.0 trees).
- **`go2rtc-config`**: template `go2rtc.yaml.in` (dump part) — M1 uses a static hand-written config; Frigate's `create_config.py` generation arrives with the Python app in M3.

### 3.2 Daemon: `go2rtc`
`daemon: simple`, `restart-condition: on-failure`, `plugs: [network, network-bind]`. Wrapper `bin/go2rtc-run`:
1. renders `$SNAP/go2rtc.yaml.in` → `$SNAP_DATA/go2rtc.yaml` (substituting `$SNAP` paths),
2. `exec`s the binary with `-config $SNAP_DATA/go2rtc.yaml`.

Config content:
- `streams: test:` an `exec:` source running the staged ffmpeg (absolute path) with `-re -f lavfi -i testsrc2=size=1280x720:rate=15` → `libx264` (present in gpl static builds) → RTSP push via go2rtc's `{output}` placeholder.
- `rtsp: listen :8554`, `api: listen :1984`, `webrtc: listen :8555` (TCP+UDP).

### 3.3 Readiness helper
`bin/lib-wait.sh` defining `wait_for_url <url> <timeout_s>` (curl poll loop, 0.5 s interval, returns non-zero on timeout). `bin/svc-a` sources it and blocks on `http://127.0.0.1:1984/api/streams` before running probes; the measured **`waited_ms` is recorded** in `ordering-svc-a.json` (readiness as evidence). `after:` chain updated: svc-a `after: [go2rtc]`.

### 3.4 mDNS probe
New command app `frigate.mdns-probe` (`plugs: [network, network-bind]`) running `probe_mdns.py`: join multicast group `224.0.0.251:5353`, send an mDNS PTR query (e.g. `_services._dns-sd._udp.local`), collect responses for ~3 s, write `mdns.json` (`{"status", "multicast_join": {ok}, "query_sent": {ok}, "responses": <n>, ...}`). Answers the deferred question: does plain `network`/`network-bind` permit multicast, or is `avahi-observe`/`network-control` required? Denials captured under the exact-allowlist policy (new arms only if expected-and-documented, narrow, labeled).

## 4. Verification (harness additions, above the denial-scan marker)

1. `go2rtc` service active; `curl :1984/api/streams` lists the `test` stream.
2. Ordering extended: `go2rtc ≤ svc-a ≤ svc-b ≤ svc-c`; `waited_ms` present in svc-a's JSON.
3. **RTSP end-to-end:** a dedicated command app `frigate.ffprobe` (thin alias to the staged binary) probes `rtsp://127.0.0.1:8554/test` and must report `h264` + `1280x720` — conclusive consumption of the restream, no host ffmpeg needed.
4. **Subprocess evidence:** `/api/streams` producer state shows the exec source active (go2rtc successfully spawned the confined ffmpeg) — primary; the harness additionally records the snap's process list from the go2rtc JSON if exposed.
5. **WebRTC:** `ss -ulpn`/`-tlpn` show 8555 bound (UDP and TCP); WHEP endpoint (`POST /api/webrtc?src=test`) returns an SDP answer. Browser playback (`http://localhost:1984` link view) is a **documented manual check** — from a second LAN device if available; else this machine only, labeled partial ICE evidence.
6. **mDNS:** `mdns.json` conclusive either way (responses received under `network` alone, or the exact denial captured).
7. All M0 assertions remain green (regression).

## 5. Deliverables & exit criteria

- Evolved spike snap, harness **ALL PASS** including new sections, zero unexpected denials.
- **`docs/m1-findings.md`**: per-question verdicts (readiness wait measured; RTSP end-to-end; confined subprocess; WebRTC port/WHEP + manual-check result; mDNS answer incl. whether `avahi-observe` is needed) with evidence citations, M0-findings style. M0's doc stays a closed record.
- Any config/`snapcraft.yaml` patterns worth carrying to M2+ noted in the findings (e.g. sha256-pin convention applied to all binary fetches).

## 6. Out of scope (M1)

Frigate Python app, `create_config.py`-generated go2rtc config, HomeKit/`go2rtc_homekit.yml`, the 7.0/5.0 ffmpeg trees, VAAPI-accelerated encode of the test stream (software x264 is deliberate — GPU decode/encode composition lands with real cameras in M3), nginx proxying of go2rtc (M4), Store/auto-connect concerns (M7).

## 7. Risks

1. **NickM-27 asset naming/URL drift** for the "8.0" tree — discover exact asset at plan time, pin URL+sha256 (M0 Task-9 pattern).
2. **go2rtc `exec:` + `{output}` template specifics** — config syntax verified against go2rtc v1.9.13 docs during implementation; a failing exec source is captured evidence, not a silent skip (stream state via `/api/streams`).
3. **mDNS may need an interface we haven't plugged** — that's the finding, either way; `network-control` (super-privileged-ish) would be a notable cost to record for the ONVIF-discovery feature decision in M3+.
4. **WebRTC ICE with only localhost testing** — partial evidence acceptable, must be labeled (risk ages to M4/M7 where remote access matters).
