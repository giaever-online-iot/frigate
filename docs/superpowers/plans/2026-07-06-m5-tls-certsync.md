# M5 TLS + certsync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `https://localhost:8971` serves Frigate with a self-signed default cert and REAL auth (401 → login → 200); `:5000` becomes loopback-only; the certsync daemon reloads nginx on cert change (spec: `docs/superpowers/specs/2026-07-06-m5-tls-certsync-design.md`).

**Architecture:** Evolve `spike/` in place. nginx-run gains upstream's pre-start cert block (mkdir letsencrypt dirs + self-signed if absent); the conf tree gains `listen.conf` (127.0.0.1:5000 + 8971 ssl, Mozilla-modern TLSv1.3 block carried from upstream's `listen.gotmpl` rendered form); new 4th daemon `certsync` (60 s fingerprint-compare loop, `nginx -s reload` on drift); spike config flips `auth: enabled: true`.

**Tech Stack:** snapcraft 9 / core26 / strict; openssl CLI (stage-packages); upstream refs: `docker/main/rootfs/usr/local/nginx/templates/listen.gotmpl`, `.../s6-rc.d/certsync/run`, `.../s6-rc.d/nginx/run` in the reference clone.

## Global Constraints

- All M3/M4-plan constraints stand: FOREGROUND-ONLY builds (`cd spike && snapcraft pack`, single Bash call, timeout 600000, re-invoke on timeout — never background); SINGLE BUILDER (concurrent packs share one LXD and kill each other); harness assertions above the denial-scan marker; narrow FINDING-labeled arms only for observed+documented denials (journal line quoted); preserve ALL M0–M4 state; livecam gate protocol (scene-dependent SKIP = green; pipeline fault = FAIL); coral FAIL → rerun whole harness once.
- Route/shape discipline: verify every URL, status code, and credential surface against the LIVE system before wiring an assertion (esp. login endpoint + internal-port anonymity mechanism).
- Secrets: the bootstrapped admin password is evidence-sensitive — never commit it, never echo it into committed files; harness reads it at run time from the discovered surface. Camera-URL rules unchanged.
- Review hygiene: `git ls-files .superpowers/ spike/results/` MUST be empty at every review (M4 merge-gate lesson).
- Findings deliverable: `docs/m5-findings.md`. Prior findings docs are closed records.

## File Structure

```
spike/
  snap/snapcraft.yaml          # + app: certsync; nginx part gains stage-packages: [openssl]
  bin/nginx-run                # + pre-start: letsencrypt dirs + self-signed generation
  bin/certsync-run             # NEW: upstream loop in POSIX sh
  config/nginx/nginx.conf.in   # listen directives → include listen.conf
  config/nginx/listen.conf     # NEW: 127.0.0.1:5000 + 8971 ssl + Mozilla-modern TLS block + ACME location
  config/frigate-config.yml    # auth: enabled: true (replaces false)
tests/spike-smoke.sh           # + M5 money checks
docs/m5-findings.md            # NEW (Task 5)
```

## Task 1 — Discovery: auth bootstrap + internal-port anonymity + login shape (no build)

- [ ] On the INSTALLED snap (M4 build), flip auth live: edit the RENDERED `$SNAP_DATA/config/config.yml` (`auth: enabled: true`... note frigate-run re-renders at restart — for discovery only, restart frigate then re-edit, or temporarily point CONFIG_FILE; document your method) and restart `snap restart frigate.frigate`. This is throwaway discovery state — the committed template changes in Task 4.
- [ ] Discover and QUOTE (journalctl/curl evidence in the report): (a) where the first-boot admin credential surfaces at v0.17.2 (log line? `/api/profile`? a reset command? — check `frigate/api/auth.py` + `frigate/util/user.py` in the reference clone FIRST, then verify live); (b) the login endpoint shape (path — upstream nginx `auth_location.conf` names `/api/login`; payload `{"user":..,"password":..}`?; response cookie name e.g. `frigate_token` — verify all live with curl against :5001); (c) HOW Frigate distinguishes the anonymous internal port from the authed external port (candidates: nginx sends `X-Server-Port`/`X-Forwarded-Port` via proxy headers and `frigate/api/auth.py` compares against config ports — read the source, verify live: same request via :5000 → 202, via :8971-simulated headers → 401).
- [ ] Restore the live system to M4 state (re-render by restarting frigate; verify `/auth` → 202 again). Report: all three shapes with verbatim evidence; NO commits (discovery is report-only).

## Task 2 — nginx TLS: listen.conf, self-signed generation, openssl, loopback :5000

- [ ] `spike/config/nginx/listen.conf` (static file, no tokens needed — `/etc/letsencrypt/*` paths are layout-mapped, ACME root literal):

```nginx
# Internal port: loopback ONLY (deliberate divergence from upstream's all-interfaces
# container bind - a host snap must not expose anonymous admin to the LAN; spec §2)
listen 127.0.0.1:5000;

# External: TLS, protected by real auth (upstream listen.gotmpl rendered form, ipv6 dropped)
listen 8971 ssl;
ssl_certificate /etc/letsencrypt/live/frigate/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/frigate/privkey.pem;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;
ssl_protocols TLSv1.3;
ssl_prefer_server_ciphers off;
add_header Strict-Transport-Security "max-age=63072000" always;
```

- [ ] `nginx.conf.in`: replace the current `listen 5000;` directive(s) with `include __SNAP_DATA__/nginx/conf/listen.conf;` (absolute path, same convention as the other includes; listen.conf is copied to the rendered conf dir by nginx-run's existing render loop — it carries no tokens itself). The ACME `location /.well-known/acme-challenge/ { default_type "text/plain"; root /etc/letsencrypt/www; }` CANNOT live in listen.conf if that file is included at listen-directive position — put it directly in nginx.conf.in's server block (upstream's gotmpl renders both into the same server context; `nginx -t` at verify proves placement; record the outcome).
- [ ] `bin/nginx-run` pre-start block (before conf render), per upstream `s6-rc.d/nginx/run`:

```sh
mkdir -p /etc/letsencrypt/www /etc/letsencrypt/live/frigate
if [ ! -f /etc/letsencrypt/live/frigate/privkey.pem ] || [ ! -f /etc/letsencrypt/live/frigate/fullchain.pem ]; then
    echo "nginx-run: no TLS certificate found - generating self-signed default"
    "$SNAP/usr/bin/openssl" req -new -newkey rsa:4096 -days 365 -nodes -x509 \
        -subj "/O=FRIGATE DEFAULT CERT/CN=*" \
        -keyout /etc/letsencrypt/live/frigate/privkey.pem \
        -out /etc/letsencrypt/live/frigate/fullchain.pem 2>/dev/null
fi
```

- [ ] snapcraft.yaml nginx part: `stage-packages: [openssl]` (verify staged binary path — `usr/bin/openssl` — and adjust the wrappers to it).
- [ ] Rebuild (FOREGROUND) + install + verify: `nginx -t` clean in journal; `curl -sk https://127.0.0.1:8971/` → 200 (auth still disabled — Task 4 flips it); `ss -tlnp | grep 5000` shows `127.0.0.1:5000` only; cert subject: `openssl s_client -connect 127.0.0.1:8971 </dev/null | openssl x509 -subject -noout` contains `FRIGATE DEFAULT CERT`. Commit.

## Task 3 — certsync daemon

- [ ] `spike/bin/certsync-run` (POSIX sh, upstream `s6-rc.d/certsync/run` translated; loop must survive reload — never `exec` the reload):

```sh
#!/bin/sh
# M5: upstream's certsync daemon - reload nginx when the on-disk cert changes.
set -u
LEFILE=/etc/letsencrypt/live/frigate/fullchain.pem
PORT=8971
echo "certsync-run: starting (watching $LEFILE vs :$PORT, 60s interval)"
while :; do
    # Upstream parity: with TLS disabled certsync idles forever. Our rendered config is the
    # settings source (spike posture keeps tls enabled; branch exists, unexercised by harness).
    if grep -A1 '^tls:' "$SNAP_DATA/config/config.yml" 2>/dev/null | grep -q 'enabled: false'; then
        sleep 9999; continue
    fi
    if [ ! -e "$LEFILE" ]; then
        echo "certsync-run: ERROR TLS certificate does not exist: $LEFILE"
        sleep 60; continue
    fi
    LEPRINT=$("$SNAP/usr/bin/openssl" x509 -in "$LEFILE" -fingerprint -noout 2>&1 || echo failed)
    LIVEPRINT=$(echo | "$SNAP/usr/bin/openssl" s_client -showcerts -connect 127.0.0.1:$PORT 2>/dev/null \
        | "$SNAP/usr/bin/openssl" x509 -fingerprint -noout 2>&1 || echo failed)
    if [ "$LEPRINT" != failed ] && [ "$LIVEPRINT" != failed ] && [ "$LEPRINT" != "$LIVEPRINT" ]; then
        echo "certsync-run: cert drift detected - reloading nginx"
        "$SNAP/usr/local/nginx/sbin/nginx" -p "$SNAP_DATA/nginx" -c "$SNAP_DATA/nginx/conf/nginx.conf" -s reload \
            || echo "certsync-run: ERROR nginx reload failed"
    fi
    sleep 60
done
```

- [ ] snapcraft.yaml app: `certsync: {command: bin/certsync-run, daemon: simple, restart-condition: on-failure, after: [nginx], plugs: [network]}`.
- [ ] Rebuild + install + verify: service active; journald shows the starting line; MONEY: generate a NEW self-signed pair over the live one (same openssl req line, via `sudo snap run --shell frigate.certsync -c ...` or a root shell into $SNAP_DATA path on host), then within ≤90 s `openssl s_client` serves the NEW fingerprint and journald has `cert drift detected - reloading nginx`. If AppArmor denies the same-snap reload signal: fall back per spec Risk 2 (`snapctl restart frigate.nginx` needs no plugs from a daemon context — verify) and record the decision + journal line. Commit.

## Task 4 — auth flip + M5 money checks + full gate

- [ ] `spike/config/frigate-config.yml`: `auth: enabled: true` AND `tls: enabled: true` (spec §2 — explicit even though true is Frigate's default; certsync's disabled-branch grep reads this block). Both outside the LIVECAM markers so both render branches keep them. Rebuild + install.
- [ ] Harness (above the denial marker; use Task 1's discovered shapes — exact paths/fields from its report):
  - `https: GET :8971/ → 200 + Frigate marker` (`curl -sk`), cert subject contains `FRIGATE DEFAULT CERT`.
  - `auth: :8971 API unauthenticated → 401` (curl -sk -o /dev/null -w %{http_code} on a protected API path).
  - `auth: login → cookie → 200` — POST the discovered login endpoint with the bootstrapped admin credential (obtained via Task 1's surface AT RUN TIME; never echoed to evidence), then the same protected path with the session cookie → 200. THE M5 MONEY LINE.
  - `net: :5000 loopback-only` — `ss -tln` shows `127.0.0.1:5000`, no `0.0.0.0:5000`/`[::]:5000`; `:8971` listening non-loopback.
  - `certsync: cert swap → new fingerprint ≤90 s` — automate Task 3's manual proof: swap cert, poll s_client fingerprint (bounded loop 100 s), assert changed + journald reload line.
  - Retarget any M4 check that hits :5000 semantics changed by auth-on (the anonymous internal port must still answer 202/200 per upstream semantics — Task 1 evidence governs; if internal-port anonymity does NOT hold on :5000, escalate to controller before weakening any assertion).
- [ ] Full gate `sudo ./tests/spike-smoke.sh` (protocols in force) → `SPIKE SMOKE: ALL PASS`, 0 unexpected denials; tee `spike/results/m5-final-run.txt`. New denial candidates (openssl s_client loopback, nginx reload signal) get narrow labeled arms only if observed. Commit.

## Task 5 — findings + wrap

- [ ] `docs/m5-findings.md` (M0–M4 style): verdict table (8971 TLS+cert-subject, 401/login/200, :5000 loopback, certsync reload proof, gate + denial delta); the three Task-1 discovery records with verbatim evidence; deviations (loopback divergence, ACME location placement decision, signal-vs-snapctl decision if taken); M6/M7 unlock notes (Coral detector next; snap-set ports/TLS + logrotate + literal-safe renderer at M7); raw evidence index (local-only). EVERY number verified against the file it cites (grep before you write — M3/M4 lesson).
- [ ] `docs/patches.md`: no changes expected (no new patches); verify and state so in the report.
- [ ] Commit docs only. Controller handles ledger/memory.
