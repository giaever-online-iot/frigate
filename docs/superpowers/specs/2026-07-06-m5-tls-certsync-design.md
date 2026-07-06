# M5 Design Spec — TLS + certsync: the external port, real auth

**Date:** 2026-07-06
**Status:** Approved design, pre-implementation
**Parent spec:** [`2026-07-02-frigate-snap-design.md`](2026-07-02-frigate-snap-design.md) (§4-M5)
**Evidence base:** [`docs/m4-findings.md`](../../m4-findings.md) (nginx chain live on :5000, auth_request anonymous, M5 unlock notes), [`docs/spike-findings.md`](../../spike-findings.md) (/etc/letsencrypt layout proven M0)

## 1. Goal

The snap serves Frigate at **`https://localhost:8971`** — TLS with a self-signed default certificate, **real authentication** (401 unauthenticated, login with the bootstrapped admin works), while `:5000` becomes a **loopback-only** internal port. The **certsync daemon** (upstream's 4th daemon — completing the parent spec's 4-daemon architecture) detects certificate changes on disk and reloads nginx. Verify criterion from the parent spec: `https://localhost:8971` answers; a cert change triggers an nginx reload.

## 2. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Auth scope | **Full upstream semantics** (USER): `auth: enabled: true`; :8971 requires login (Frigate bootstraps the first admin credential); :5000 keeps the anonymous internal role | Real auth proven this milestone; upstream-faithful port semantics |
| :5000 binding | **127.0.0.1 only** (USER) | The container binds all interfaces but Docker isolates it; a host snap must not expose anonymous admin to the LAN. Deliberate, documented divergence |
| certsync mechanism | **Upstream-faithful sh loop** (60 s fingerprint compare via `openssl s_client`, `nginx -s reload` on drift, sleep-forever if TLS disabled) | Approach A; inotify/path-watch rejected as overengineering; folding into nginx-run rejected (breaks the 4-daemon mapping) |
| Cert lifecycle | Self-signed auto-generation (rsa:4096, 365 d, `CN=*`) in nginx-run pre-start if no keypair; operator-provided certs land in `$SNAP_DATA/letsencrypt/live/frigate/` (via the M0-proven `/etc/letsencrypt` layout) and certsync picks them up | Exactly upstream's model; ACME issuance is out of scope upstream too |
| TLS posture | `tls: enabled: true` fixed in the spike config | Frigate's default; the certsync disabled-branch (sleep forever) is implemented per upstream but not exercised by the harness |

## 3. Components

### 3.1 `certsync` app
- `daemon: simple`, `restart-condition: on-failure`, `after: [nginx]`, `plugs: [network]`.
- `bin/certsync-run`: upstream's loop translated to POSIX sh — every 60 s: fingerprint `$SNAP_DATA/letsencrypt/live/frigate/fullchain.pem` (path via the `/etc/letsencrypt` layout) and the cert served on `127.0.0.1:8971` (`openssl s_client`); on mismatch, invoke (NOT `exec` — the loop must survive the reload) `$SNAP/usr/local/nginx/sbin/nginx -p $SNAP_DATA/nginx -c $SNAP_DATA/nginx/conf/nginx.conf -s reload` (same prefix/conf as the nginx app ⇒ same pid file; same-snap signal permitted by the default snap template — verify empirically, arm narrowly if denied). Errors logged, loop continues (upstream tolerates missing certs with `[ERROR]` lines).

### 3.2 nginx: TLS listen + cert generation (`bin/nginx-run` + conf)
- Pre-start block per upstream: `mkdir -p` `/etc/letsencrypt/www` and `/etc/letsencrypt/live/frigate`; if `privkey.pem`/`fullchain.pem` absent → `openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 -subj "/O=FRIGATE DEFAULT CERT/CN=*"` into that dir.
- Listen config: `listen 127.0.0.1:5000;` (internal — CHANGED from M4's all-interfaces) and `listen 8971 ssl;` + upstream's `ssl_certificate`/`ssl_certificate_key` pointing at the letsencrypt live dir, with upstream's TLS parameter directives carried as-is from `listen.gotmpl`'s rendered form.
- `openssl` added to the nginx part's `stage-packages` (CLI needed at runtime by both nginx-run and certsync-run; core26 ships libssl only).

### 3.3 Real auth
- Spike config: `auth: enabled: true` (replaces M4's `enabled: false` — the nginx auth_request chain itself is unchanged and already proven).
- **Plan-time discovery** (M3 model-provisioning discipline): the v0.17.2 first-boot admin credential bootstrap (where the password surfaces — logs/API) and the login endpoint shape (path, payload, session/JWT cookie form). Route shapes verified against the LIVE daemon before wiring assertions; quoted in the findings.
- :5000 requests keep anonymous access per upstream's internal-port semantics (verify which mechanism upstream uses to distinguish the ports — listen-conf headers vs Frigate config — and mirror it; discovery item, evidence quoted).

### 3.4 Money-test verification (harness, above the denial marker; ALL M0–M4 assertions preserved)
1. `https://localhost:8971/` via `curl -k` → 200 + UI marker; served cert subject contains `FRIGATE DEFAULT CERT` (self-signed default proof).
2. Unauthenticated `:8971` API request → **401**.
3. Login with the bootstrapped admin credential → authenticated request → **200** (the real-auth money line; credential never committed — harness reads it from the discovered bootstrap surface at run time).
4. `ss` corroborates: `:5000` bound to `127.0.0.1` only; `:8971` listening.
5. **certsync proof**: generate a second self-signed cert into the live dir → within a bounded window (≤ ~90 s) `openssl s_client 127.0.0.1:8971` serves the NEW fingerprint; certsync's reload line present in journald.
6. M4's `:5000` assertions retargeted to the loopback bind (same URLs — harness already curls 127.0.0.1).
7. Denial policy unchanged: expected candidates — none new (loopback s_client under `network`; same-snap signal). Any observed denial gets a narrow labeled arm with the journal line quoted.

### 3.5 Findings: `docs/m5-findings.md`
M0–M4 style: verdict table (8971 TLS, 401/login, :5000 loopback, certsync reload proof, denial delta), the auth-bootstrap discovery record, deviations (loopback divergence, any auth quirks), M6/M7 decisions unlocked, raw evidence index (local-only; `git ls-files .superpowers/ spike/results/` empty — the M4 merge-gate lesson, now a standing checklist item).

## 4. Out of scope (M5)

ACME/Let's Encrypt issuance (operator-provided certs only); snap-set configurability of ports/TLS (M7); Coral-as-detector (M6); MQTT/HomeAssistant; user management UI beyond the bootstrapped admin; logrotate (M7, recorded in M4).

## 5. Risks

1. **Auth bootstrap quirks at v0.17.2** — where the first admin password surfaces (log line, reset command) and login API shape are unverified; discovery + evidence-driven latitude, quoted in findings.
2. **Same-snap signal for `nginx -s reload`** — expected allowed by the snap template; if AppArmor denies, the fallback is `snapctl restart frigate.nginx` (heavier but confinement-native); decision recorded with evidence.
3. **certsync timing vs harness window** — 60 s poll ⇒ bounded wait ≥ 90 s in the assertion; generous timeout, no flake.
4. **TLS handshake variance in probes** — `curl -k`/`s_client` against self-signed must not depend on hostname verification anywhere.
5. **:5000 loopback change** — any M4 assertion that implicitly assumed all-interfaces binding must be caught by the retarget sweep (harness already uses 127.0.0.1 throughout; risk is low).
