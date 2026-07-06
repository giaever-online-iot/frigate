# M5 Findings — TLS + cert-sync

**Date:** 2026-07-07  **Snap:** frigate 0.0.1-spike (core26, strict)  **Frigate:** v0.17.2  **Branch:** m5-tls-certsync  **HEAD:** 9efbd0f → final-review wave (go2rtc :1984 loopback, certsync PID gate, cert-gen diagnostics, cert-swap -days 7)

| # | Question | Verdict | Evidence |
|---|----------|---------|----------|
| M5-1 | https://:8971 serves Frigate with self-signed default cert? | YES — `GET https://127.0.0.1:8971/` → HTTP 200, body contains `<title>Frigate</title>`. Cert subject `O = FRIGATE DEFAULT CERT, CN = *`; TLSv1.3 only; Mozilla-modern profile (`ssl_session_cache shared:MozSSL:10m`; `ssl_prefer_server_ciphers off`); HSTS (`Strict-Transport-Security: max-age=63072000`). RSA-4096 self-signed generated on first boot (~24 s) when no cert exists at `/etc/letsencrypt/live/frigate/`; idempotent guard skips generation on subsequent starts; key born 0600 under `umask 077`. | spike/results/m5-final-run.txt (`PASS: https: GET :8971/ → 200`, `PASS: https: root body contains Frigate marker`, `PASS: https: cert subject contains FRIGATE DEFAULT CERT`; `tls finding: cert subject=subject=O = FRIGATE DEFAULT CERT, CN = *`); spike/config/nginx/listen.conf (`ssl_protocols TLSv1.3`, `ssl_session_cache shared:MozSSL:10m`, `ssl_prefer_server_ciphers off`, `add_header Strict-Transport-Security "max-age=63072000" always`); spike/bin/nginx-run (`openssl req -new -newkey rsa:4096`, `-subj "/O=FRIGATE DEFAULT CERT/CN=*"`; idempotent `[ ! -f privkey.pem ] || [ ! -f fullchain.pem ]` guard; `umask 077` before cert block); task-2-report.md (24 s journal gap verbatim) |
| M5-2 | Real auth proven end-to-end over TLS? | YES — JWT gate active on :8971: `GET https://127.0.0.1:8971/api/version` (no cookie) → **401**; `POST https://127.0.0.1:8971/api/login` with payload `{"user":"admin","password":"<32-hex>"}` → **200** + `Set-Cookie: frigate_token=<HS256-JWT>; HttpOnly; Path=/; SameSite=lax; Secure`; `GET https://127.0.0.1:8971/api/version` (cookie jar) → **200** (M5 MONEY LINE). Mechanism: `X-Server-Port: 8971 ≠ 5000` — `auth()` falls through to JWT validation. Field name is `user` (not `username`) per Task-1 source discovery. `cookie_secure: true` added (not upstream default — upstream default is `False`; TLS-only external access justifies the Secure flag). | spike/results/m5-final-run.txt (`PASS: auth: :8971 API unauthenticated → 401`; `PASS: auth: POST https://127.0.0.1:8971/api/login → 200`; `PASS: auth: login → frigate_token cookie set`; `PASS: auth: authed GET https://127.0.0.1:8971/api/version → 200 (M5 MONEY LINE)`; `auth finding: login=200 cookie=frigate_token authed_get=200 — JWT gate proven end-to-end`); task-1-report.md (login shape verbatim, field name `user` confirmed from `AppPostLoginBody`); task-4-report.md (config diff: `auth: enabled: true; cookie_secure: true`) |
| M5-3 | :5000 AND :5001 loopback-only? | YES — deliberate divergence from upstream container (which binds all interfaces). `:5000` loopback-only seals the anonymous internal path; `:5001` loopback-only seals the X-Server-Port spoofing surface (an off-host client must not be able to forge `X-Server-Port: 5000` and gain anonymous admin). `:8971` binds all interfaces for TLS. Evidence verbatim from gate: `LISTEN 0 511 127.0.0.1:5000 0.0.0.0:*` / `LISTEN 0 2048 127.0.0.1:5001 0.0.0.0:*` / `LISTEN 0 511 0.0.0.0:8971 0.0.0.0:*`. | spike/results/m5-final-run.txt (`PASS: net: :5000 loopback-only (127.0.0.1:5000 bound)`; `PASS: net: :5000 NOT all-interfaces`; `PASS: net: :5001 loopback-only (127.0.0.1:5001 bound)`; `PASS: net: :5001 NOT all-interfaces (X-Server-Port spoofing surface sealed)`; `PASS: net: :8971 non-loopback (0.0.0.0:8971 bound)`; `net finding: LISTEN 0 511 127.0.0.1:5000 0.0.0.0:* |LISTEN 0 2048 127.0.0.1:5001 0.0.0.0:* |LISTEN 0 511 0.0.0.0:8971 0.0.0.0:*`); task-4-report.md (M5-3 gate checks + X-Server-Port spoofing surface rationale); spike/config/nginx/listen.conf (`listen 127.0.0.1:5000` — loopback explicit) |
| M5-4 | certsync (4th daemon) reloads nginx within bound when cert swaps? | YES — cert swap → new fingerprint served: **46 s** elapsed (gate; ≤90 s assertion). Task-3 manual proof: new fingerprint on first poll, within **≤5 s**. Journal reload line verbatim: `certsync-run: cert drift detected - reloading nginx` (2026-07-07 00:41:54). Signal route (`nginx -s reload`): SUCCEEDED with **ZERO AppArmor signal-class denials** — same-snap signal delivery is permitted by snapd's default confinement template; `snapctl restart` fallback was not needed (spec Risk 2 resolved). certsync completes the snap's 4-daemon architecture: go2rtc, frigate, nginx, and now certsync. | spike/results/m5-final-run.txt (`PASS: certsync: new fingerprint served after cert swap`; `PASS: certsync: cert swap → reload ≤90 s (elapsed=46s)`; `PASS: certsync: nginx reload logged in journal`; `certsync finding: old_fp=SHA1 Fingerprint=9D:FA:94:F7:F4:8E:26:05:C8:E0:9E:74:40:85:0E:9A:00:8C:D2:38`; `certsync finding: new_fp=SHA1 Fingerprint=51:4F:D6:0C:E2:90:E9:5C:6A:19:6C:B7:A6:7A:86:82:6E:7A:09:1A elapsed=46s`; `certsync finding: reload='Jul 07 00:41:54 GV-ThinkPad-X13-Gen-5 frigate.certsync[3879713]: certsync-run: cert drift detected - reloading nginx'`); task-3-report.md (signal vs snapctl outcome verbatim; Task-3 manual ≤5 s money proof) |
| M5-5 | Full gate: ALL PASS? | YES — **SPIKE SMOKE: ALL PASS**. **106 PASS / 0 FAIL / 3 SKIP** (livecam-url present but camera port unreachable at harness start — SKIP, not a pipeline failure). AppArmor: **320 total denials, 0 unexpected**. **ZERO new allowlist arms** added across the entire M5 milestone (Task 2: "No new policy arms needed"; Task 3: "No new allowlist arm needed"; Task 4: "No new allowlist arms added"). Final-review wave adds 2 new checks (`:1984 loopback-only`; `:1984 NOT all-interfaces`) — both PASS. Single gate run, no re-run needed. | spike/results/m5-final-run.txt (authoritative: `SPIKE SMOKE: ALL PASS`; `== denials: 320 total, 0 unexpected ==`; run start 2026-07-07T01:23:03+02:00, final-review wave); task-2-report.md, task-3-report.md, task-4-report.md (no-new-arm statements per task) |

---

## Task-1 discovery trio — auth shape before M5 enabled auth

Three mechanisms discovered by source inspection and live probe against a manually auth-enabled snap build (M4 x2 installed; config patched in private-tmp; state restored to `auth: enabled: false` via `snap start`).

### (a) Password bootstrap — first-boot admin credential surface

`frigate/app.py` `FrigateApp.init_auth()` fires once when `auth.enabled: true` and the `User` table is empty. The credential is emitted only to the Frigate process log (journald when running as a snap service):

```
[2026-07-06 23:29:19] frigate.app  INFO : ********************************************************
[2026-07-06 23:29:19] frigate.app  INFO : ***    Auth is enabled, but no users exist.          ***
[2026-07-06 23:29:19] frigate.app  INFO : ***    Created a default user:                       ***
[2026-07-06 23:29:19] frigate.app  INFO : ***    User: admin                                   ***
[2026-07-06 23:29:19] frigate.app  INFO : ***    Password: dec965542f9945cc775bf16dddd6e852   ***
[2026-07-06 23:29:19] frigate.app  INFO : ********************************************************
```

Source (v0.17.2 `frigate/app.py:init_auth()`, verbatim):

```python
password = secrets.token_hex(16)          # 32 hex chars
logger.info(f"***    Password: {password}   ***")
```

Password format: `secrets.token_hex(16)` — 32 lowercase hex characters. DB: `$SNAP_COMMON/db/frigate.db` SQLite, PBKDF2-SHA256 hash (`pbkdf2_sha256$600000$<salt>$<b64hash>`). The `***` block appears twice per run — cosmetic duplicate from multi-handler logging, not a double-insert.

Evidence: task-1-report.md §(a) (source lines verbatim; live journal output 2026-07-06 23:29:19 verbatim).

### (b) Login contract

Endpoint: `POST /api/login` via nginx (`auth_request off`; rewrites `/api/…` → `/…`; proxied to `:5001`). Payload field name is `user` — not `username`:

```json
{"user": "admin", "password": "<32-hex-token>"}
```

Success (correct credentials, live evidence from task-1 probe):
```
STATUS=200
Set-Cookie: frigate_token=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhZG1pbiIsInJvbGUiOiJhZG1pbiIsImV4cCI6MTc4MzQ1OTc2MiwiaWF0IjoxNzgzMzczMzYyfQ.fhXNqfhdSVRwA0KiH3Yk9V8YddJtSbRGJ9t-BS2p3p4; expires=Sun, 10 Jan 2083 18:58:44 GMT; HttpOnly; Path=/; SameSite=lax
```

Failure (wrong credentials):
```
STATUS=401
BODY: {"message":"Login failed"}
```

JWT algorithm: HS256 (`eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9` = `{"typ":"JWT","alg":"HS256"}`). Session length: 86400 s (24 h). The `Secure` flag is absent in the discovery-era response (M4 posture, `cookie_secure: False` default) — Task 4 adds `cookie_secure: true` for the TLS-only M5 posture.

Evidence: task-1-report.md §(b) (nginx conf block verbatim; `AppPostLoginBody` source; live STATUS=200 and STATUS=401 responses verbatim).

### (c) X-Server-Port short-circuit mechanism

`frigate/api/auth.py` `auth()` (v0.17.2 lines 548–563):

```python
if int(request.headers.get("x-server-port", default=0)) == 5000:
    success_response.headers["remote-user"] = "anonymous"
    success_response.headers["remote-role"] = "admin"
    return success_response
```

nginx `auth_location.conf` injects `X-Server-Port: $server_port` into every auth subrequest. Since nginx listens on `:5000`, `$server_port` = 5000 for all internal subrequests — `auth()` short-circuits to 202 without checking the JWT or auth.enabled flag. When M5 added `listen 8971 ssl;`, `$server_port` = 8971 for external connections — `auth()` falls through to JWT validation and returns 401 without a cookie. **No change to `auth.py` was required** — only adding the TLS `listen` directive activated the auth gate on :8971.

Live evidence from task-1 probe (with `auth: enabled: true`):
- `GET /auth` (no `X-Server-Port`) → `STATUS=401; location: /login`
- `GET /auth` (`X-Server-Port: 5000`) → `STATUS=202; remote-user: anonymous; remote-role: admin`
- `GET /auth` (`X-Server-Port: 8971`) → `STATUS=401; location: /login`

Evidence: task-1-report.md §(c) (source lines verbatim; live TEST1/TEST2/TEST3 evidence verbatim; M5 implication note).

---

## Self-signed cert generation

`nginx-run` generates the bootstrap self-signed cert if both `privkey.pem` and `fullchain.pem` are absent at `/etc/letsencrypt/live/frigate/` (the snap layout target):

```sh
"$SNAP/usr/bin/openssl" req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/O=FRIGATE DEFAULT CERT/CN=*" \
    -keyout /etc/letsencrypt/live/frigate/privkey.pem \
    -out /etc/letsencrypt/live/frigate/fullchain.pem 2>/dev/null
```

RSA-4096 key generation takes **~24 s** on first boot (task-2-report.md verbatim: "journal shows 24s gap between the 'generating self-signed default' echo and the frigate gate log"). Subsequent starts skip generation (idempotent `[ ! -f privkey.pem ] || [ ! -f fullchain.pem ]` guard). Key and cert are written with `umask 077` set (inherited from the nginx-run preamble), yielding mode 0600 for key material. The cert subject `/O=FRIGATE DEFAULT CERT/CN=*` matches upstream Frigate's self-signed bootstrap format.

Journal line (task-2-report.md verbatim):
```
Jul 06 23:48:18 GV-ThinkPad-X13-Gen-5 frigate.nginx[3801267]: nginx-run: no TLS certificate found - generating self-signed default
Jul 06 23:48:42 GV-ThinkPad-X13-Gen-5 frigate.nginx[3801267]: nginx-run: frigate gate waited_ms=22914
```

M7 note: an ECDSA P-256 cert would reduce the ~24 s first-boot latency substantially; noted for M7 certsync configurability work.

Evidence: spike/bin/nginx-run (generation block verbatim); task-2-report.md (journal lines verbatim; latency note).

---

## Certsync startup race (non-blocking, adjudicated record-only)

On a cold start, certsync's first poll fires at approximately +1 s — before nginx has written its PID file to `$SNAP_DATA/nginx/nginx.pid`. If cert drift is detected at that instant, `nginx -s reload` fails with:

```
nginx: [error] open() "/var/snap/frigate/x4/nginx/nginx.pid" failed (2: No such file or directory)
```

certsync logs `ERROR nginx reload failed` and continues the loop. The next poll (60 s later) finds the PID file present and the reload succeeds. This is a benign startup ordering artifact — certsync declares `after: [nginx]` but nginx writes its PID file asynchronously after master process fork. In the normal operating path the on-disk cert and the served cert are identical (nginx-run generated both), so no drift is detected on first poll and no reload is attempted. The race manifests only when drift exists at boot (uncommon). No new AppArmor arm is needed; self-heals within 60 s.

M7 note: a short PID-file gate at the top of `certsync-run` (before the first iteration) would eliminate the cosmetic error log on cold-start drift.

Evidence: task-3-report.md §Startup race (nginx PID file error verbatim; "benign startup ordering artifact" assessment; "No new allowlist arm needed").

---

## Harness password hygiene

The admin password is extracted from the journal via `journalctl -u snap.frigate.frigate --since "$MARK"` into a shell variable, used for the `POST /api/login` check, then discarded — never echoed or written to any evidence file. The gate's `snap remove --purge` step empties `$SNAP_COMMON/db/frigate.db`, which destroys the current admin user record. The reinstall and `init_auth()` bootstrap on the next daemon start generate a fresh `secrets.token_hex(16)` password. The Task-1 discovery-era admin (password `dec965542f9945cc775bf16dddd6e852`, created 2026-07-06 23:29:19) was destroyed by the gate's purge cycle before the M5 money checks ran.

Gate confirmation: `PASS: livecam: no stream URL/credentials in evidence files` (the same harness check that guards livecam credentials also guards auth credentials from landing in `spike/results/`).

Evidence: task-4-report.md §Money checks (journal extraction pattern; "never echoed or written to evidence files; purge cycle guarantees a fresh admin user"); spike/results/m5-final-run.txt (`PASS: livecam: no stream URL/credentials in evidence files`).

---

## Upstream cosmetic bug — `admin_first_time_login` stays `false` after fresh bootstrap

`GET /api/auth/first_time_login` returned `{"admin_first_time_login":false}` even immediately after `init_auth()` logged the admin password and set `self.config.auth.admin_first_time_login = True` in memory. Likely cause: FastAPI received a Pydantic model copy before the flag was mutated, so the mutation is invisible to the request context. The UI help-link feature (which auto-opens on first login) therefore never triggers after a fresh install. Severity: low — the credential is surfaced in the journal regardless; the web UI is fully functional. Worth an upstream bug report alongside M4's `recordings()` `datetime.now()` default-argument bug.

Evidence: task-1-report.md concern #1 (live `STATUS=200; BODY: {"admin_first_time_login":false}` after fresh `init_auth()` run); task-4-report.md concern #3 (same behaviour confirmed on M5 auth-enabled build).

---

## Operator notes

- **HSTS latent footgun**: `Strict-Transport-Security: max-age=63072000` is sent for both the self-signed default and any real certificate. Once a browser has seen the header and stored the HSTS policy, any later fallback to the self-signed cert (e.g. after a real cert expires and the files are not replaced) will hard-block the browser until the HSTS state is manually cleared — RFC 6797 behavior, not a bug, but operators should be aware. The self-signed cert itself only triggers an "untrusted CA" warning on first visit; the HSTS state is what makes subsequent self-signed access a hard error.
- **Self-signed default expires after 365 d with no renewer**: The idempotent guard in `nginx-run` only generates when *both* cert files are absent. Once generated, the self-signed cert is never rotated by the snap — it silently expires after 365 days unless the operator supplies a real Let's Encrypt cert via certsync. M7 item: add a cert-age check and auto-regeneration when the self-signed cert is within 30 days of expiry.
- **TLSv1.3-only client floor**: `ssl_protocols TLSv1.3` (Mozilla modern profile) rejects any client that does not support TLS 1.3. This is correct for 2026 deployments but may be too restrictive for embedded or legacy clients on the same LAN. Operator may relax to `TLSv1.2 TLSv1.3` and add the corresponding `ssl_ciphers` if needed.
- **http2 built but not enabled**: nginx is built with `--with-http_v2_module` but the listen directive uses `ssl` only (no `http2` parameter). HTTP/2 is a latent M7 performance improvement; enabling it requires no recompile. Note for M7.

---

## Deviations

| Deviation | Reason | M-plan reference |
|---|---|---|
| :5000 loopback-only (host snap must not expose anonymous path to LAN) | Upstream Docker container binds :5000 on all interfaces. A host snap binding :5000 all-interfaces would expose anonymous admin role to any LAN host (no JWT gate on port 5000). User ruling: loopback-only. | task-2-report.md §Verification (ss output); M5 task-5-brief.md (deliberate divergence) |
| :5001 loopback-only (X-Server-Port spoofing surface) | Upstream container: :5001 all-interfaces. If :5001 were reachable off-host, a client could POST `X-Server-Port: 5000` to `:5001/auth` directly and receive admin role without a JWT. Loopback bind seals this. | task-4-report.md (`:5001 NOT all-interfaces (X-Server-Port spoofing surface sealed)`); task-1-report.md concern #4 |
| ACME location in `nginx.conf.in` server block (not in a separate include) | nginx rejects `location` blocks inside an include file when that file is inserted at the `listen`-directive position inside a server block. The `location /.well-known/acme-challenge/` block must live directly in the server block. Confirmed clean: nginx starts with no configuration error. | task-2-report.md §ACME location placement |
| `cookie_secure: true` (not upstream default) | Upstream default is `cookie_secure: False`. With TLS-only external access (:8971), setting `Secure` ensures browsers send `frigate_token` only over HTTPS — correct for the snap's single external HTTPS port posture. | task-4-report.md (config diff verbatim; concern #1 justification) |
| certsync `sleep 9999` TLS-disabled branch | When `tls: enabled: false` is detected in the rendered config, certsync idles indefinitely (`sleep 9999; continue`) rather than exiting. Mirrors upstream's `s6-rc.d/certsync/run` idle posture (TLS disabled → certsync is a no-op but stays running). The disabled branch is unexercised by the harness; the spike posture keeps TLS enabled. | spike/bin/certsync-run (comment verbatim: "Upstream parity: with TLS disabled certsync idles forever") |
| go2rtc :1984 loopback-only (final-review addition) | Controller ruling extending the loopback principle already applied to :5000/:5001. `go2rtc.yaml.in` changed from `listen: ":1984"` to `listen: "127.0.0.1:1984"` so the go2rtc control API/UI is not an anonymous LAN surface. Browsers reach go2rtc via nginx's authed `/live/*` proxy; frigate + nginx consume it via loopback. Media ports 8554/8555 are unchanged (they must be reachable for RTSP/WebRTC peers). User may override to `":1984"` to expose the go2rtc UI directly on LAN. Harness: two new loopback assertions (`127.0.0.1:1984 bound`; `0.0.0.0:1984 NOT bound`). | spike/config/go2rtc.yaml.in (listen line + comment); tests/spike-smoke.sh (two new net checks) |

---

## M6/M7 unlock notes

**M6** — Coral-as-detector is next. Coral USB probes (firmware upload, delegate load, inference) have been green since M0 (`PASS: coral delegate loaded`, `PASS: coral inference ran`). M6 work: add EdgeTPU model staging, switch the detector config from OpenVINO to `edgetpu`, and verify detection pipeline end-to-end with the Coral delegate active.

**M7** items accumulate (not exhaustive):

| Item | Origin |
|---|---|
| `snap set` config surface (ports, TLS on/off, livecam URL) | M5 parent spec; deferred |
| logrotate for `$SNAP_DATA/nginx/logs/{error,access}.log` | M4 ENXIO story; no journald capture while stderr is a journal socket fd |
| Literal-safe livecam URL renderer (replace `sed` with `python3 str.replace` or `awk` fixed-string) | M4 `sed` limitation story (`|`, `&`, `\` special in replacement) |
| Version-stamped DB backups | M5 parent spec; deferred |
| ECDSA P-256 cert option (eliminate ~24 s RSA-4096 first-boot latency) | M5 self-signed generation story |
| certsync configurability (poll interval, ACME dir path) | M5 certsync startup race story |
| PID-file gate in `certsync-run` (suppress cold-start drift error log) | M5 certsync startup race story (implemented in M5 final-review wave as a bounded 60 s wait) |
| JWT cookie jar hygiene note: admin token transits `/tmp/m5-gate-cookie.jar` briefly during the harness gate (derived token only — password is never written to disk; jar is deleted immediately after the authed GET check) | M5 harness gate §auth |
| snap/snapcraft.yaml draft openssl stage-package gap: the top-level DRAFT yaml was missing `openssl` in the frigate part's stage-packages (openssl is required for nginx-run cert generation and certsync fingerprint compare); gap closed in M5 final-review wave | M5 final-review (docs-class; addressed) |

---

## Raw evidence index

**Provenance note**: `spike/results/` and `.superpowers/` are listed in `spike/.gitignore` and `.superpowers/.gitignore` respectively. `git ls-files spike/results/ .superpowers/` returns empty — all files below are local-only and not tracked in the repository. The transcript and evidence files are authoritative; task-report prose may describe earlier runs.

| File | Content |
|---|---|
| `spike/results/m5-final-run.txt` | Final M5 harness run — final-review wave (2026-07-07T01:23:03+02:00): **SPIKE SMOKE: ALL PASS**, **106 PASS / 0 FAIL / 3 SKIP**, 320 denials 0 unexpected. Includes :1984 loopback assertions (both PASS). Local-only. |
| `spike/results/https-root.html` | Response body of `GET https://127.0.0.1:8971/` — Frigate web UI served over TLS. Local-only. |
| `spike/results/cert-subj.txt` | Cert subject from `openssl s_client` against :8971 — `subject=O = FRIGATE DEFAULT CERT, CN = *`. Local-only. |
| `spike/results/ss-tln.txt` | `ss -tlnp` capture: `:5000` loopback, `:5001` loopback, `:1984` loopback (go2rtc), `:8971` all-interfaces. Local-only. |
| `spike/results/denials.txt` | Full AppArmor denial log from the final run. Local-only. |
| `spike/results/m4-final-run.txt` | Final M4 harness run — substrate confirmed carried forward. Local-only. |
| `spike/results/webui-root.html` | `GET :5000/` response body. Local-only. |
| `spike/results/asset-headers.txt` | HTTP response headers for the hashed JS asset. Local-only. |
| `spike/results/vod-manifest.txt` | HLS VOD manifest from the testclip path. Local-only. |
| `spike/results/livecam-stats.json` | `/stats` API capture for livecam pipeline-alive check. Local-only. |
| `spike/results/expanded-snapcraft.yaml` | `snapcraft expand-extensions` output. Local-only. |
| `docs/patches.md` | Carried patch register: 0001–0003 (nginx/vod); M5 adds no new patches — verified and stated below. |
| `.superpowers/sdd/task-1-report.md` | M5 Task 1: auth discovery — bootstrap log verbatim, login shape, X-Server-Port mechanism, live test evidence. |
| `.superpowers/sdd/task-2-report.md` | M5 Task 2: TLS plumbing — listen.conf, self-signed generation, openssl, loopback :5000. |
| `.superpowers/sdd/task-3-report.md` | M5 Task 3: certsync daemon — service wiring, manual money proof, signal route outcome, startup race. |
| `.superpowers/sdd/task-4-report.md` | M5 Task 4: auth flip + gate — config diff, money checks with quoted evidence, gate tail, denial delta. |
