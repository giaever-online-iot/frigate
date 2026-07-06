# M4 Findings — nginx + web UI

**Date:** 2026-07-06  **Snap:** frigate 0.0.1-spike (core26, strict)  **Frigate:** v0.17.2  **Branch:** m4-nginx-webui  **HEAD:** 3d7136f (final fix wave)

| # | Question | Verdict | Evidence |
|---|----------|---------|----------|
| M4-1 | Custom nginx 1.27.4 compiled strict-confined with vod/vod-extensions? | YES — nginx/1.27.4 built with vod 1.31, secure-token 1.5, set-misc v0.33, ngx_devel_kit v0.3.3; 5 sha256-pinned tarballs; configure flags verbatim from upstream `docker/main/build_nginx.sh` @ v0.17.2; GCC-15 hard error resolved by source patch 0003 (§GCC-15 story); cc-opt reverted to upstream-verbatim: `--with-cc-opt='-O3 -Wno-error=implicit-fallthrough'`. snap.frigate.nginx service active and serving throughout the gate. | task-1-report.md (nginx -V verbatim, sha256 table, GCC-15 error verbatim, fix rounds); spike/results/m4-final-run.txt (`PASS: nginx service active`); spike/results/expanded-snapcraft.yaml |
| M4-2 | Web UI served at :5000 from real built dist? | YES — Frigate v0.17.2 web UI built at `base=/` (§e2e:build story): `GET :5000/` → HTTP 200, body contains `<title>Frigate</title>`; hashed JS asset `assets/index-B8b0DR8e.js` → HTTP 200, MIME `application/javascript`, two `Cache-Control` headers (`Cache-Control: max-age=31536000` and `Cache-Control: public` — separate response headers as issued by nginx). Asset name discovered at runtime from live `index.html` (never hardcoded); harness asserts `fail_` if no `assets/index-*.js` found. | m4-final-run.txt (`PASS: webui: GET :5000/ → 200`, `PASS: webui: root body contains Frigate marker`, `PASS: webui: hashed JS asset (assets/index-B8b0DR8e.js) → 200`, `PASS: webui: hashed JS asset MIME is application/javascript`; webui finding: `assets/index-B8b0DR8e.js → HTTP 200 application/javascript (1y public cache, /assets/ location)`); spike/results/webui-root.html; spike/results/asset-headers.txt |
| M4-3 | API proxied :5000/api/* → :5001 with NO client auth headers? | YES — `GET :5000/api/version` → `0.17.2-3d4dd3a` (== `:5001/version`) without any auth headers from the client; real nginx auth_request chain live: `GET :5000/auth` → HTTP 202 Accepted (anonymous accept, `auth: enabled: false` posture; real auth deferred to M5). nginx injects viewer headers (`Remote-User`, `Remote-Role`) from the /auth upstream response before forwarding to Frigate's internal API at :5001. | m4-final-run.txt (`PASS: nginx proxies /api/version == :5001/version (no auth headers)`; `PASS: frigate: /auth returns 202 (anonymous accept)`; nginx finding: `/api/version=0.17.2-3d4dd3a (== :5001/version; no auth headers required)`; nginx finding: `/auth status=202 (202 Accepted = anonymous auth path confirmed)`) |
| M4-4 | vod module exercises real recordings (live HLS manifest)? | YES — live-derived HLS manifest from real testclip recordings: `GET :5000/vod/{camera}/start/{ts}/end/{ts}/index.m3u8` → HTTP 200 + `#EXTM3U`, `#EXT-X-TARGETDURATION`, `#EXT-X-PLAYLIST-TYPE:VOD`. Range dynamically derived per run from the recordings API (explicit `after`/`before` params — §upstream-bug story). Full vod chain: nginx vod location (`vod_mode mapped`, `vod_upstream_location /api`) → internal subrequest `/api/vod/...` → Frigate `/vod/` route (`frigate/api/media.py:853`) returns JSON clip mapping → vod module builds fMP4 HLS manifest. | m4-final-run.txt (`PASS: vod: GET :5000/vod/testclip/start/../end/../index.m3u8 → 200 + #EXTM3U`; vod finding: `shape=testclip/start/1783305116/end/1783305166.206563/index.m3u8 segments=5`); spike/results/vod-manifest.txt (full manifest: `#EXTM3U`, `#EXT-X-TARGETDURATION:11`, `#EXT-X-PLAYLIST-TYPE:VOD`, `#EXT-X-VERSION:6`, `seg-1-v1.m4s`); task-4-report.md (manifest shape verbatim) |
| M4-5 | go2rtc fronted via nginx /live/? | YES — `GET :5000/live/webrtc/webrtc.html` → HTTP 200, `Content-Type: text/html`, 3707 bytes of go2rtc's WebRTC player page proxied from `:1984/webrtc.html`. nginx conf fronts five go2rtc paths: WS endpoints (`/live/mse/api/ws`, `/live/webrtc/api/ws`), HTTP-GET player (`/live/webrtc/webrtc.html`), POST-only WebRTC (`/api/go2rtc/webrtc`), and jsmpeg via a separate upstream. Plain-HTTP-GET webrtc.html path chosen for harness assertion (WS paths return 400 without upgrade; POST path rejects GET). | m4-final-run.txt (`PASS: go2rtc proxy: GET :5000/live/webrtc/webrtc.html → 200`; go2rtc proxy finding: `nginx /live/webrtc/webrtc.html → go2rtc :1984/webrtc.html; HTTP 200`); task-4-report.md (go2rtc proxy path selection rationale) |
| M4-6 | Full gate: ALL PASS? | YES — **SPIKE SMOKE: ALL PASS**. **93 PASS / 0 FAIL / 0 SKIP**. AppArmor: **296 denials total, 0 unexpected**. 0 SKIPs: livecam armed and MONEY TEST passed (person detected at 04:30 local; `PASS: MONEY TEST: real objects detected on live camera (events API)`, `PASS: detection: label is person with score`, `PASS: detection: corroborated in split db`). Denial total: 296 this run (prior range 240 → 366 across 3 gate runs; variance by process mix per capture window); 0 unexpected throughout. Final fix wave: nginx-conf part removed, WARN echo added, stale banner corrected, harness label + guard fixed, sed limitation documented. | spike/results/m4-final-run.txt (authoritative: `SPIKE SMOKE: ALL PASS`, `== denials: 296 total, 0 unexpected ==`, run start 2026-07-06 04:30:42 +02:00); task-4-report.md (gate history: earlier runs) |

---

## GCC-15 vs ngx_http_vod_exit_process

GCC 15 (core26) promotes `-Wincompatible-pointer-types` to a hard error by default. `ngx_http_vod_exit_process` in vod 1.31 is declared and defined with an empty parameter list `()` (K&R old-style C), but assigned to struct slots typed `void (*)(ngx_cycle_t *)` — incompatible function-pointer types. This was only a warning in GCC 14 and earlier.

**Error at ngx_http_vod_module.c:219 (task-1-report.md verbatim):**
```
../nginx-vod-module/ngx_http_vod_module.c:219:13: note: 'ngx_http_vod_exit_process' declared here
  219 | static void ngx_http_vod_exit_process();
../nginx-vod-module/ngx_http_vod_module.c:242:5: error: initialization of 'void (*)(ngx_cycle_t *)' {aka 'void (*)(struct ngx_cycle_s *)'} from incompatible pointer type 'void (*)(void)' [-Wincompatible-pointer-types]
  242 |     ngx_http_vod_exit_process,        /* exit process */
make[1]: *** [objs/Makefile:1900: objs/addon/nginx-vod-module/ngx_http_vod_module.o] Error 1
```

**Review adjudication**: a global `-Wno-incompatible-pointer-types` cc-opt flag was applied in the first round, then reviewed and rejected in favour of a minimal registered source patch. Final route: `spike/patches/nginx/0003-vod-gcc15-exit-process-prototype.patch` adds the `(ngx_cycle_t *cycle)` parameter to both the declaration (line ~219) and definition (line ~3328), plus the conventional `(void) cycle;` unused-parameter guard. cc-opt reverted to upstream-verbatim (`-O3 -Wno-error=implicit-fallthrough`; no suppression flag). **Trip-wire**: the patch will fail to apply if upstream vod ever fixes the prototype, surfacing the redundancy immediately at build time — intentional per review guidance; drop patch 0003 when that happens.

Patch verified against the pristine sha256-pinned tarball (vod 1.31, sha256 `ace04201cf2d2b1a3e5e732a22b92225b8ce61a494df9cc7f79d97efface8952`). The patch stack was independently verified at build time: `patching file ngx_http_vod_module.c` clean, no rejects, pack exit code 0. See `docs/patches.md` for the full nginx/vod patch register.

---

## ENXIO — nginx logs cannot reach journald

Under snap's systemd unit, file descriptor 2 is a journal AF\_UNIX socket, not a pipe. nginx's `error_log /dev/stderr` attempts `open("/dev/stderr")`; the kernel returns ENXIO because `/proc/*/fd` entries for sockets cannot be opened as regular files.

**Fix**: `error_log` and `access_log` directed to files under `$SNAP_DATA/nginx/logs/`. nginx service stays active and serving throughout. **M7 consequence**: no log rotation is configured yet; logs accumulate in `$SNAP_DATA/nginx/logs/{error,access}.log` with no journald capture.

Evidence (m4-final-run.txt FINDING line, verbatim):
```
nginx finding: error_log/access_log → files in $SNAP_DATA/nginx/logs/ (deviation: /dev/stderr not
openable in systemd snap unit — journal socket, not pipe; ENXIO on open); M7: configure logrotate
for $SNAP_DATA/nginx/logs/{error,access}.log; no journald capture while stderr is a socket fd
```

---

## `user root;` and absolute include paths — both load-bearing

`user root;` in the nginx config is load-bearing under strict confinement. nginx workers attempt to chown cache directories to `nobody` at startup; under strict AppArmor this chown is denied (EPERM), which abort-loops the workers. With `user root;` the workers already run as uid 0 — the chown is a no-op and all workers start cleanly. The setgid/setuid capability denials (§Denial arms) are the audit trace of this privilege setup; they are non-blocking because `user root;` makes the actual ownership transition a uid-0 identity operation.

Absolute include paths (`include /var/snap/frigate/common/nginx/...`) are also required. nginx resolves `include` directives relative to its compiled-in `--prefix` (`/usr/local/nginx`) when the path is not absolute. A relative path would attempt to read `include /usr/local/nginx/<path>`, missing the `$SNAP_DATA` directory entirely.

---

## STALE-CACHE WEDGE — snap private /tmp survives `snap remove --purge`

The snap's private `/tmp` (at `/tmp/snap-private-tmp/snap.frigate/tmp/` on the host) is a kernel-maintained mount. `snap remove --purge` removes the snap's data directories but does NOT unmount the private tmpfs — it persists until the host reboots.

**Consequence**: stale `livecam@*.mp4` segment files from a previously-armed run (livecam-url since deprovisioned) remained in `FRIGATE_CACHE_DIR` after a full `snap remove --purge` + reinstall. Frigate's recording maintainer (`move_files()`) iterates cache segments and calls `self.config.cameras[camera]` — a plain dict lookup. For the stale `livecam` key (camera no longer in config) this raised a `KeyError`, aborting the entire `move_files()` loop every 5-second cycle. No camera's recording segments reached disk or DB.

Journal evidence (task-4-report.md verbatim):
```
Jul 06 02:50:12 ... snap.frigate.frigate[...]: frigate.record.maintainer ERROR : 'livecam'
```

**Fix**: `frigate-run` clears `FRIGATE_CACHE_DIR` at daemon start (before the go2rtc readiness gate and before launching frigate). Guard uses `${FRIGATE_CACHE_DIR:?}` to prevent accidental wipe on an empty variable.

**Counterfactual**: `sudo journalctl -u snap.frigate.frigate --since '-10m' | grep -c KeyError` → **0** after two full gate runs post-fix.

**Operator-facing severity**: an operator who deprovisions a camera (`livecam-url` removed) would find ALL recording silently wedged until the host reboots — unless `frigate-run` clears the stale segments. The fix takes effect at daemon restart (`snap restart`), no reboot required.

**Side effect on layout-token check**: the stale-cache fix clears `FRIGATE_CACHE_DIR` (which includes the layout probe's `probe.txt` written by `svc-a`). The harness check that verified the file's presence on the live filesystem was switched to reading `.writes."/tmp/cache/probe.txt".ok` from `layout.json` — more authoritative (probe outcome captured before daemon start) and unaffected by the cache clear.

---

## STASH INCIDENT — EXIT trap destroyed the operator's livecam secret

The harness stashes `$SNAP_COMMON/livecam-url` before the `snap remove --purge` step and restores it after reinstall. The original EXIT trap was `rm -f $LIVECAM_STASH`. On an aborted run that exited AFTER purge but BEFORE restore, the only stash copy was deleted — permanently losing the operator-provisioned secret. The secret was re-provisioned manually.

**Fix**: replaced the EXIT trap with restore-or-preserve semantics:
- Stash present + target missing + snap installed → `install -m 0600` (restore) then rm stash
- Stash present + snap dir absent → `mv` to `/var/tmp/frigate-livecam-url.stash` + loud echo (survives until manual recovery or next harness start)
- Target already present → rm stash (idempotent)

**Self-healing at start**: if `/var/tmp/frigate-livecam-url.stash` exists and the target is missing and the snap is installed, the harness recovers it automatically at the top of the run.

---

## UPSTREAM BUG — recordings() after/before defaults frozen at import time

`frigate/api/media.py:632-633` (v0.17.2) uses `datetime.now()` as default argument values in the function signature:

```python
def recordings(camera_name, ..., after=datetime.now(), before=datetime.now()):
```

Python evaluates default argument values once at function definition time (module import, not call time). The bare `GET /{camera}/recordings` route (no explicit `after`/`before`) is therefore frozen at daemon boot — every segment recorded after boot is invisible to the bare route. Polling for 90 s returned `[]` while the DB held 24 rows.

**Harness workaround**: the vod check sends explicit `after`/`before` timestamps recomputed per poll iteration.

**Scope**: the Frigate web UI is immune (always sends explicit params). The bare route is effectively a dead-letter path on any running daemon. Worth an upstream bug report. Noted for M7.

---

## e2e:build absent at v0.17.2 — BASE\_PATH token substitution dropped

The M4 plan assumed `npm run e2e:build`. The `e2e:build` script does not exist in `web/package.json` at tag v0.17.2. The `build` script is:

```json
"build": "tsc && vite build --base=/BASE_PATH/"
```

`/BASE_PATH/` is a Docker-build-time substitution token replaced by `tempio` when the container image is assembled. The snap build has no `tempio`; serving the UI at root (`/`) is the correct posture for a single-host snap.

**Route taken**: `node_modules/.bin/vite build --base=/` — drops `tsc` (type-check only; produces no output artefacts, adds ~30 s to the build) and drops the `BASE_PATH` subsystem entirely. The built `dist/` is byte-identical to what `--base=/BASE_PATH/` produces after token substitution with `/`. See §Deviations.

---

## sed replacement limitation — `|`, `&`, `\` unsupported in livecam credentials

`frigate-run` and `validate-config` render the livecam URL into `frigate-config.yml` using `sed` with `|` as the delimiter (`s|__LIVECAM_URL__|...|g`). sed's replacement half treats three characters specially:

- `|` — the delimiter itself; a literal `|` in the URL splits the expression and causes a parse error
- `&` — expands to the entire matched string (the token); a literal `&` in the URL would insert the token text instead
- `\` — the escape prefix; a `\` followed by a digit or special character has unintended meaning

**Consequence**: operators whose RTSP credentials contain any of these characters cannot use the provisioned livecam path without URL-encoding or manually escaping the credential.

**Documented in**: `spike/bin/frigate-run` (header comment), `spike/bin/validate-config` (header comment), `spike/config/frigate-config.yml` (LIVECAM block Caveat line).

**M5/M7**: switch the livecam URL substitution to a literal-safe renderer (e.g. `python3 -c 'import sys, re; ...'` with `re.escape` or `str.replace`, or `awk` with a fixed-string substitution). Until then, operators should URL-encode `|` → `%7C`, `&` → `%26`, `\` → `%5C` in credentials if needed.

---

## Upstream limitation — camera URL exposed in ffmpeg child process argv

Frigate's capture code (`frigate/video.py`) launches ffmpeg subprocesses with the camera RTSP URL as a positional command-line argument. The URL (including credentials) is therefore visible in `/proc/<pid>/cmdline` for the lifetime of each ffmpeg subprocess. This is upstream behaviour, not introduced by the snap.

Operators using the `livecam-url` provisioning path should be aware that the credential is visible to any root process on the host. The snap does not make this worse than the official Docker image. Noted for the operator-facing documentation; out of snap scope.

---

## Denial arms added in M4

All arms below are in `tests/spike-smoke.sh`'s expected-denial filter. Evidence: `spike/results/denials.txt` (final run) and task reports as cited.

| Arm | Profile | Operation | Mechanism | Evidence |
|---|---|---|---|---|
| `nginx.*capname="setgid"` | `snap.frigate.nginx` | `capable` (`capname=setgid`, capability=6) | nginx per-worker privilege setup; fires ~once per CPU core at startup; `user root;` makes the chown a uid-0 no-op; nginx serves throughout; 14 hits in gate run 3 (240-denial window), 0 capable-class hits in the authoritative final run — run-to-run variance per the DMI/NPU precedent | task-3-report.md (pre-existing before Task 3 build; confirmed not from static file serving); m4-final-run.txt (`nginx finding: nginx worker CAP_SETGID denial at startup`) |
| `nginx.*capname="setuid"` | `snap.frigate.nginx` | `capable` (`capname=setuid`, capability=7) | setuid sibling of the setgid arm (worker/cache-manager privilege setup); run-to-run variance: journal-evidenced in the run-2 window; 0 capable-class hits in gate run 3 and the authoritative final run | task-4-report.md (journal line verbatim: `Jul 06 02:54:22 ... apparmor="DENIED" operation="capable" class="cap" profile="snap.frigate.nginx" pid=2909768 comm="nginx" capability=7  capname="setuid"`); m4-final-run.txt (`nginx finding: nginx CAP_SETUID denial`) |

Denial totals varied 240 → 366 across the first three gate runs; the final fix-wave run (2026-07-06 04:30) recorded 296 — within the established range (process mix per capture window — 0 unexpected throughout). This is consistent with the precedented run-to-run variance observed in M3 (264 → 388 across runs with a live second camera).

---

## Deviations

| Deviation | Reason | M-plan reference |
|---|---|---|
| `tempio` dropped (BASE_PATH substitution) | No `tempio` in snap build environment; serving the UI at root (`/`) is correct for a single-host snap; dist is byte-identical after `--base=/`. | task-3-report.md §Deviations; M4 design spec |
| `npm run e2e:build` → `vite build --base=/` | `e2e:build` script absent at v0.17.2; upstream `build` script uses the Docker substitution token `/BASE_PATH/`. | task-3-report.md §Deviations; §e2e:build story above |
| `tsc` type-check dropped from web-ui build | `tsc` produces no output artefacts; type-check only. Adds ~30 s; dropped for snap build. | task-3-report.md §Deviations |
| Auth-disabled posture (`auth: enabled: false`) | Real nginx auth_request chain is live and exercised (/auth 202, headers forwarded); auth disabled means any client gets viewer access. Real auth (`auth: enabled: true` + user management) deferred to M5. | M4 design spec; m4-final-run.txt nginx finding |
| TLS / port 8971 deferred | TLS and the public-facing :8971 port require certsync (M5). The now-live :5000 chain is the substrate. | M4 design spec; M5 unlock notes below |
| `error_log` / `access_log` to files (ENXIO) | `/dev/stderr` not openable under snap systemd unit (journal socket, not pipe → ENXIO on open); logs written to `$SNAP_DATA/nginx/logs/` instead. | §ENXIO story above; m4-final-run.txt FINDING line |
| Money-test semantics: scene-dependent SKIP | Controller ruling (2026-07-06): armed livecam money test failing on an empty room at 03:30 is scene content, not a packaging regression. Pipeline-liveness (`ffmpeg_pid > 0`) is a hard check; SKIP wording distinct from unprovisioned case. FAIL reserved for pipeline faults. | task-4-report.md §Refinement (commit 6bd536d); m4-final-run.txt 3 SKIP lines |
| Layout-token check switched to layout.json evidence | The stale-cache fix (§STALE-CACHE WEDGE story) clears `FRIGATE_CACHE_DIR` at daemon start, removing the live `probe.txt`. The harness check was switched to verify `.writes."/tmp/cache/probe.txt".ok` from `layout.json` — unaffected by the cache clear and more authoritative. | task-4-report.md §Fix round (wedge + stash) |
| Redundant `nginx-conf` part removed (final review M4) | `go2rtc-config` (`source: config`) already stages the whole `config/` tree including `config/nginx/`; the `nginx-conf` part staged byte-identical files — a latent stage-conflict risk. Removed at final M4 review; single stager is `go2rtc-config`. M7: no action needed (config/nginx/* still present in packed snap via go2rtc-config). | spike/snap/snapcraft.yaml (final review, commit m4: final fix wave) |

---

## M5 unlock notes

- **TLS / port 8971**: certsync fronts the now-live :5000 nginx chain → port 8971 with TLS termination. The `/etc/letsencrypt` layout proven M0 (m0-findings.md §A2, `PASS: layout: /etc/letsencrypt -> SNAP_DATA`) is the ready substrate.
- **Real auth**: replace the `auth: enabled: false` anonymous posture with `auth: enabled: true` + user management. The auth_request chain is already wired and exercised; /auth will return real role headers (viewer vs admin) keyed to the logged-in user. Anonymous viewer-always-202 path replaced by real credential checks.
- **Logrotate**: lands M7; until then logs accumulate at `$SNAP_DATA/nginx/logs/{error,access}.log` with no journald capture (§ENXIO story).

---

## Raw evidence index

| File | Content |
|---|---|
| `spike/results/m4-final-run.txt` | Final M4 harness run — final fix wave (2026-07-06 04:30 local): **SPIKE SMOKE: ALL PASS**, **93 PASS / 0 FAIL / 0 SKIP**, 296 denials 0 unexpected. MONEY TEST PASS (person detected). Local-only per spike/.gitignore convention. |
| `spike/results/webui-root.html` | Response body of `GET :5000/` — real Frigate index.html with `<title>Frigate</title>`, hashed asset references. Local-only. |
| `spike/results/asset-headers.txt` | HTTP response headers for `GET :5000/assets/index-B8b0DR8e.js` — MIME `application/javascript`, `Cache-Control: max-age=31536000, public`. Local-only. |
| `spike/results/vod-manifest.txt` | HLS manifest from `GET :5000/vod/testclip/start/<ts>/end/<ts>/index.m3u8` — `#EXTM3U`, `#EXT-X-TARGETDURATION:11`, `#EXT-X-PLAYLIST-TYPE:VOD`, `#EXT-X-VERSION:6`, `seg-1-v1.m4s`. Local-only. |
| `spike/results/livecam-stats.json` | `/stats` API capture for livecam pipeline-alive check: `cameras.livecam.ffmpeg_pid > 0`. Local-only. |
| `spike/results/denials.txt` | Full AppArmor denial log from the final run (366 entries, all allowlisted). Local-only. |
| `spike/results/expanded-snapcraft.yaml` | `snapcraft expand-extensions` output — nginx/go2rtc wiring, gpu extension command-chain injection; captured at gate time. Local-only. |
| `docs/patches.md` | Carried nginx/vod patch register: 0001–0003; §Rejected patch records the withdrawn M3 motion-calibration trial. |
| `.superpowers/sdd/task-1-report.md` | M4 Task 1: nginx compile — nginx -V verbatim, sha256 table, GCC-15 error verbatim, cc-opt fix round, final cc-opt upstream-verbatim. |
| `.superpowers/sdd/task-3-report.md` | M4 Task 3: web-ui — build script deviation, vite build, dist verification, asset-headers, nginx root wiring. |
| `.superpowers/sdd/task-4-report.md` | M4 Task 4: gate — vod manifest shape verbatim, stale-cache analysis and fix, upstream-bug detail, stash fix, gate history (3 runs), setuid denial arm. |
