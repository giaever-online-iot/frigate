# M4 nginx + Web UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The snap serves Frigate's web UI at `http://localhost:5000` through the custom-compiled nginx (vod/secure-token), proxying API + go2rtc, with recordings playback exercising the vod module — plus the secret-handling hardening the live-cam review gated on (spec: `docs/superpowers/specs/2026-07-06-m4-nginx-webui-design.md`).

**Architecture:** Evolve `spike/` in place. New parts: `nginx` (compile, upstream recipe, pinned), `web-ui` (node 20 vite build from the v0.17.2 tree). New app `nginx` (after: frigate) with `bin/nginx-run` rendering the conf tree (sed tokens, umask 077) and running `nginx -p $SNAP_DATA/nginx`. Spike config gains `auth: enabled: false` so the nginx auth_request chain answers anonymously (no faked headers on the UI path).

**Tech Stack:** snapcraft 9 / core26 / strict; nginx 1.27.4 + kaltura vod 1.31 (2 upstream patches) + secure-token 1.5 + set-misc v0.33 + ngx_devel_kit v0.3.3; node 20 (build-snap) + vite; harness `tests/spike-smoke.sh`.

## Global Constraints

- All M3-plan constraints stand: FOREGROUND-ONLY builds (`cd spike && snapcraft pack`, Bash timeout 600000, reattach by re-invoking); harness assertions above the denial-scan marker; sha256-pin every fetch; narrow FINDING-labeled denial arms only for observed+documented denials; preserve ALL M0–M3 state (probes, apps, arms, wrappers, layouts, livecam gate protocol).
- Livecam gate: the camera may be off/absent during runs — the 3 live checks SKIP cleanly; that is GREEN per protocol. A livecam FAIL with the camera provisioned+reachable is a real regression.
- Passwordless sudo unchanged (`snap`, `journalctl`, `lsusb`, the harness). Secret provisioning stays `--provision-livecam` (stdin).
- Upstream reference clone: `/tmp/claude-1000/-home-joachimmgg-Development-giaever-online-iot-frigate/0dd7cb9e-369c-4a10-9fed-1ecbe74c6a05/scratchpad/frigate` (master @ ea131e1; re-clone if missing). nginx recipe facts pinned from `docker/main/build_nginx.sh` + `docker/main/rootfs/usr/local/nginx/conf/`.
- Route/shape discipline (M3 lesson): verify every URL shape and status against the LIVE system before wiring an assertion (esp. `/auth` anonymous semantics and the `/vod/` manifest path shape).
- Findings deliverable: `docs/m4-findings.md`. Prior findings docs are closed records.

## File Structure

```
spike/
  snap/snapcraft.yaml            # + parts: nginx, web-ui; + app: nginx
  bin/nginx-run                  # NEW: render conf -> $SNAP_DATA/nginx, gate on :5001, exec nginx
  bin/frigate-run                # hardening: sed -f secret render, umask 077
  bin/validate-config            # same hardening
  config/nginx/                  # NEW: conf templates adapted from upstream rootfs (tokens: __SNAP__, __SNAP_COMMON__, __PORT__)
  patches/nginx/                 # NEW: the 2 upstream vod patches as committed files (MAX_CLIPS, rbsp #4572)
tests/spike-smoke.sh             # + M4 money checks; hardened livecam gate (/dev/tcp), stash EXIT trap
docs/m4-findings.md              # NEW
```

## Task 0 — Hardening (pre-exposure gate from the live-cam review)

- [ ] `frigate-run` + `validate-config`: build the livecam substitution as a root-0600 `sed -f` script file (URL out of argv); `umask 077` around all render blocks; drop the now-redundant post-hoc `chmod 600`.
- [ ] Harness: replace the ffprobe reachability probe with a bash `/dev/tcp/<host>/<port>` check — host/port parsed from the secret INSIDE the script (no URL in any argv); unreachable/unparseable ⇒ the existing SKIP path with reason.
- [ ] Harness: EXIT trap removes the livecam stash tempfile on abort.
- [ ] Record in findings: frigate's own ffmpeg child argv exposes the URL (`/proc/<pid>/cmdline`) — upstream behavior, known limitation, not spike scope.
- [ ] Verify: `--skip-install` run green (no rebuild needed yet); grep `/proc/*/cmdline` during a render to confirm no URL.

## Task 1 — nginx part (compile, pinned)

- [ ] Commit the two vod patches under `spike/patches/nginx/` (verbatim from `build_nginx.sh`: MAX_CLIPS sed → express as a patch file for determinism; rbsp-trailing-bits heredoc patch).
- [ ] Part `nginx`: `plugin: nil`; build-packages `build-essential, libpcre2-dev, zlib1g-dev, libssl-dev`; wget + sha256-check the 5 tarballs (nginx 1.27.4, vod 1.31, secure-token 1.5, set-misc v0.33, ngx_devel_kit v0.3.3 — record the hashes at first fetch); apply both vod patches; upstream configure flags verbatim; `make -j$(nproc) && make install DESTDIR=$CRAFT_PART_INSTALL`; delete `html/` + `conf/*.default` per upstream.
- [ ] Build: `snapcraft pack` foreground; expect ONLY the new parts to build (cache intact for python311/spike-wheels/frigate-src).
- [ ] Verify: `unsquashfs -cat ... usr/local/nginx/sbin/nginx` exists; `nginx -V` (via `snap run --shell` or staged binary on host) lists all four modules + configure flags.

## Task 2 — conf templates + nginx-run + app

- [ ] Adapt upstream conf tree into `spike/config/nginx/` templates: keep `nginx.conf` structure, `auth_location.conf`, `auth_request.conf`, `go2rtc_upstream.conf`, `proxy.conf`, `proxy_trusted_headers.conf`; drop tempio/base_path + TLS/8971 blocks; tokens for `__SNAP__` (web root `/opt/frigate/web` is layout-reachable — verify and prefer the layout path), `__SNAP_COMMON__` (all `/media/frigate` roots), listen `5000`; temp paths (`client_body_temp_path` etc.) under `/tmp/nginx-tmp`; pid + logs under `$SNAP_DATA/nginx/logs`, error/access log → `/dev/stdout` `/dev/stderr`.
- [ ] `bin/nginx-run`: render (umask 077) → `$SNAP_DATA/nginx/conf/`; mkdir logs + /tmp/nginx-tmp; `wait_for_url http://127.0.0.1:5001/version 60`; `exec $SNAP/usr/local/nginx/sbin/nginx -p $SNAP_DATA/nginx -c $SNAP_DATA/nginx/conf/nginx.conf -g "daemon off;"`.
- [ ] App `nginx`: `daemon: simple`, `restart-condition: on-failure`, `after: [frigate]`, `plugs: [network, network-bind]`.
- [ ] Spike config: add `auth: enabled: false` (verify against live daemon that `/auth` then answers anonymous-accept; quote the status).
- [ ] Rebuild + install; triage nginx denials (candidates: `/proc/sys` reads, aio) narrow+labeled.
- [ ] Verify: service active; `curl -s http://127.0.0.1:5000/api/version` == the :5001 answer, NO auth headers.

## Task 3 — web-ui part

- [ ] Part `web-ui`: same git source/tag v0.17.2 (`source-depth: 1`), `build-snaps: [node/20/stable]`; `cd web && npm ci && npm run e2e:build`; install `web/dist` → `$CRAFT_PART_INSTALL/opt/frigate/web`. Isolate like spike-wheels (probe edits must not retrigger).
- [ ] Rebuild + install.
- [ ] Verify: `GET :5000/` returns the built `index.html` (marker: `<title>Frigate</title>` or equivalent from the dist); one hashed JS/CSS asset → 200 with correct Content-Type.

## Task 4 — money checks (harness) + full gate

- [ ] Above the denial marker, add: nginx active; `GET :5000/` 200+marker; hashed-asset 200+MIME; `GET :5000/api/version` 200 (no headers); vod manifest check — record ≥1 segment then `GET :5000/vod/<shape discovered live>/index.m3u8` → 200 + `#EXTM3U`; one go2rtc proxy location answers.
- [ ] Full harness `sudo ./tests/spike-smoke.sh`: ALL PASS (livecam gate per protocol; coral per protocol — rerun once on coral FAIL).
- [ ] Denial section: labeled arms for every observed expected nginx denial; `0 unexpected`.

## Task 5 — findings + wrap

- [ ] `docs/m4-findings.md`: verdict table (UI, auth chain, vod, proxies, denial delta), deviations (tempio dropped, base=/, auth-disabled posture, 8971 deferred), M5 unlock notes (TLS/certsync fronting 5000→8971, real auth), evidence index.
- [ ] Update `docs/patches.md` scope note if the nginx build patches raise register questions (they are third-party build patches, not Frigate-source patches — document the boundary).
- [ ] progress ledger + memory updates; commit sequence per house style.
