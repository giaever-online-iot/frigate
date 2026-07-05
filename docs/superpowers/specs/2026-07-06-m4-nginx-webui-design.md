# M4 Design Spec — nginx + web UI

**Date:** 2026-07-06
**Status:** Approved design, pre-implementation
**Parent spec:** [`2026-07-02-frigate-snap-design.md`](2026-07-02-frigate-snap-design.md) (§4-M4)
**Evidence base:** [`docs/m3-findings.md`](../../m3-findings.md) (live-camera money test green on stock code; M4-deferred hardening items), [`docs/m2-findings.md`](../../m2-findings.md) (layout denial for `/media/*`), upstream reference `blakeblackshear/frigate` (docker/main/build_nginx.sh + rootfs nginx conf tree, master @ ea131e1 ≈ v0.17.2)

## 1. Goal

The snap serves Frigate's **web UI on `http://localhost:5000`** through the **custom-compiled nginx** (vod/secure-token modules), proxying the API/go2rtc and exercising **recordings playback via the vod module** — the parent roadmap's M4. Additionally M4 lands the secret-handling hardening items the live-camera review gated on ("fix BEFORE M4's broader exposure").

## 2. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| nginx provenance | **Compile upstream's exact recipe** as a snap part: nginx 1.27.4 + vod 1.31 (both upstream patches: MAX_CLIPS 128→1080, rbsp-trailing-bits #4572) + secure-token 1.5 + set-misc v0.33 + ngx_devel_kit v0.3.3; upstream configure flags (`--with-file-aio --with-http_sub_module --with-http_ssl_module --with-http_v2_module --with-http_auth_request_module --with-http_realip_module --with-threads`) | Stock apt nginx unusable (no vod module — feasibility report); tag-exact + sha256-pinned sources per house rule |
| Conf templating | **sed render at daemon start** (established `__TOKEN__` pattern) replacing upstream's tempio go-templates; runtime prefix via `nginx -p $SNAP_DATA/nginx` (no new layout) | tempio is a Go binary dependency for 3 template renders — the snap already has a proven render mechanism; `/usr/local/nginx` layout unnecessary when `-p`/`-c` select paths at runtime |
| Media paths in conf | Render upstream's `root /media/frigate` → literal `$SNAP_COMMON/media/frigate` | `/media/*` layouts REJECTED at pack time (M2 finding); nginx conf is ours to render — no patch, no layout |
| Web UI build | Part building upstream `web/` (same v0.17.2 git source as frigate-src) with **node 20** (`build-snaps: [node/20/stable]`), `npm ci && npm run e2e:build` (vite, `--base=/`), staged to `/opt/frigate/web` (upstream's serve root, already reachable via the Task-2 layout) | `e2e:build` builds with base=/ so the whole BASE_PATH sub_filter/tempio subsystem is dropped (spike serves at root only; subpath support = M7 item if wanted) |
| Auth posture (M4) | `auth: { enabled: false }` in the spike config; nginx `auth_request` chain kept ACTIVE (frigate answers anonymous) so the UI path needs NO faked headers | Exercises the real nginx→frigate auth chain without TLS/password machinery (that is M5); direct-:5001 harness checks keep their `Remote-User` headers as before |
| Ports (M4) | nginx listens **5000/tcp only**; 8971 TLS deferred | Parent spec: M4 verify is `http://localhost:5000`; TLS+certsync is M5 |
| Process tree | New app `nginx`: `daemon: simple`, `restart-condition: on-failure`, `after: [frigate]`, `plugs: [network, network-bind]` | Mirrors upstream's s6 ordering (go2rtc → frigate → nginx); svc-a/b/c stubs stay (M0 ordering evidence, cheap) |

## 3. Components

### 3.1 `nginx` part (compile)
- Sources: nginx.org tarball + 4 module tarballs, all sha256-pinned; both upstream vod patches applied verbatim (committed as files under `spike/patches/nginx/` — build-tree patches, not Frigate-source patches; register NOT required per docs/patches.md scope, but README'd).
- build-packages: `build-essential, libpcre2-dev, zlib1g-dev, libssl-dev` (core26 equivalents of `build-dep nginx`; no ccache — one-shot part build).
- Install: binary + mime.types to `$CRAFT_PART_INSTALL/usr/local/nginx/...`; upstream conf tree staged as **templates** under `$SNAP/config/nginx/` with `__TOKEN__` substitutions (`__SNAP_COMMON__`, `__SNAP__`, listen port).

### 3.2 `nginx-run` wrapper + app
- Renders conf templates → `$SNAP_DATA/nginx/conf/` (umask 077), ensures `$SNAP_DATA/nginx/logs` + `/tmp/nginx-tmp` (client_body/proxy temp paths — private tmp), gates on frigate `:5001` (wait_for_url, same readiness pattern), then `exec nginx -p $SNAP_DATA/nginx -c $SNAP_DATA/nginx/conf/nginx.conf -g "daemon off;"`; error/access logs to stdout/stderr (journald).
- Conf adaptations from upstream rootfs tree: drop tempio/base_path machinery (base=/), drop 8971/TLS server block (M5), point `root`s at rendered `$SNAP_COMMON`/`$SNAP` paths, keep `/api/` proxy → `127.0.0.1:5001`, `/vod/` (aio threads, hls fmp4, `vod_upstream_location /api`), go2rtc proxy locations, `auth_request` includes.

### 3.3 Web UI part
- Same git source/tag as frigate-src (v0.17.2, depth 1); `npm ci` + `npm run e2e:build` in `web/`; `web/dist` → `$CRAFT_PART_INSTALL/opt/frigate/web`. Network during build = same trust class as pip wheels (pinned by the tag's `package-lock.json`).

### 3.4 Hardening (gated on M4 by the live-cam review)
1. Secret render argv leak: substitution via `sed -f <root-0600 script file>` (URL never in argv) in frigate-run/validate-config.
2. Harness reachability gate: replace ffprobe-with-URL-in-argv by a bash `/dev/tcp` host:port probe parsed inside the script (no URL in any argv). Note: frigate itself exposes the URL in its ffmpeg child argv — upstream behavior, recorded as a known limitation, not spike scope.
3. Render TOCTOU: `umask 077` in render blocks (config never transiently 0644).
4. Harness stash: EXIT trap cleans the livecam-url temp copy on abort.

### 3.5 Money-test verification (harness, above the denial-scan marker)
1. `nginx` service active; `GET http://127.0.0.1:5000/` → 200 with the UI's `index.html` (title/asset markers).
2. A hashed asset referenced by index.html loads with correct Content-Type (UI actually staged, not a 200 fallback).
3. **API through nginx with NO faked headers**: `GET http://127.0.0.1:5000/api/version` → 200 (proves the auth_request chain end-to-end with anonymous auth).
4. **vod module exercised**: request a recordings playback manifest (`/vod/...m3u8` for a recorded segment window, path shape per upstream API) → 200 + `#EXTM3U` (proves vod parses real mp4 under confinement; aio threads).
5. go2rtc via nginx: one representative proxy location answers.
6. All M0–M3 assertions preserved (incl. live-camera gate protocol); new nginx denials triaged narrow+labeled per policy.

### 3.6 Findings: `docs/m4-findings.md`
M0–M3 style: verdict table (UI served, auth chain, vod playback, proxy paths, denial delta), deviations (tempio dropped, base=/, auth disabled posture), decisions unlocked for M5 (TLS/certsync fronting the now-live 5000), raw evidence index.

## 4. Out of scope (M4)

TLS + port 8971 + certsync (M5), real auth/login flow (M5 alongside TLS), BASE_PATH/subpath serving (M7 item), jsmpeg/mqtt-websocket depth testing (locations proxied but only representatively asserted), Coral/NPU (M6), `snap set` config (M7).

## 5. Risks

1. **nginx build-dep parity on core26** — upstream uses Debian `build-dep nginx`; the 4 explicit -dev packages should suffice (PCRE2 since 1.25); first build tells.
2. **vod module vs snap confinement** — aio threads + open_file_cache on `$SNAP_COMMON` paths; watch for denials (file-aio is plain io, expected clean).
3. **npm ci network/build weight** — node 20 build-snap + ~1 GB node_modules in the build VM; part is cache-isolated like spike-wheels so probe edits don't retrigger it.
4. **Auth-disabled `/auth` semantics on v0.17.2** — verify the anonymous 202 path at plan execution before wiring assertions (route/status shapes verified against the live daemon, M3 lesson).
5. **UI expects endpoints the spike doesn't run** (birdseye, mqtt ws) — UI must still render; individual widget errors tolerated and documented.
