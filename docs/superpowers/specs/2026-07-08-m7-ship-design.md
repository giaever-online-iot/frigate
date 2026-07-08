# M7 Design Spec — Ship: snap-set configurability, hardening backlog, Store (amd64)

**Date:** 2026-07-08
**Status:** Approved design, pre-implementation
**Parent spec:** [`2026-07-02-frigate-snap-design.md`](2026-07-02-frigate-snap-design.md) (§4-M7)
**Evidence base:** [`docs/m3-findings.md`](../../m3-findings.md)–[`docs/m6-findings.md`](../../m6-findings.md) (accumulated M7 backlog tables), the zwave-js-ui repo's CI (`.github/workflows/pr-build-snap.yml`, `release-on-merge.yml`, `.github/scripts/`) as the publishing pattern (USER direction).

## 1. Goal

The snap installs on a **clean machine from the Store following only the README** (parent verify criterion), published to `latest/edge` by CI on every merge and promoted to `latest/beta` once that verify passes. The pragmatic `snap set` surface and the M3–M6 hardening backlog land in the same milestone. arm64 (M7c) and per-version Store tracks are explicitly out.

## 2. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Milestone shape | **Config+hardening and Store ship as ONE milestone** (USER); arm64 separate later; NPU documented not-yet-supported | User ruling over the proposed 3-way split |
| `snap set` surface | **Pragmatic set** (USER): `ports.https` (8971), `tls.enabled` (true), `tls.cert-profile` (`rsa-4096` \| `ecdsa-p256`), `certsync.interval` (60), `detector` (`ov`\|`coral`\|`cpu`, render-time only) | Every knob the findings actually flagged; nothing speculative |
| Store depth | **Edge → beta, declarations filed during the milestone** (USER) | Clean-machine verify gates the beta promotion; declaration clock starts now |
| Publishing mechanism | **CI mirrors zwave-js-ui** (USER: "check the CI for the giaever-online-iot/zwave-js-ui snap"): Launchpad `snapcraft remote-build` on PRs → `latest/edge/PR<N>`, promote on merge, `SNAPCRAFT_STORE_CREDENTIALS` repo secret | User's proven publishing pattern; gives an arm64 path later for free |
| Channels | **latest-only for M7** (`latest/edge` → `latest/beta`); the track helper math ships dormant | Per-version tracks need Store approval requests; YAGNI until upstream churn demands them |
| First-boot detector default | **Auto-detect at first render**: `/dev/dri/renderD*` present → `ov`, absent → `cpu`; `snap set frigate detector=` overrides | A fixed `ov` default crash-loops GPU-less machines (incl. the verify VM); supersedes M6's fixed-`ov` render default — deliberate, documented |
| Config ownership | Unchanged from M6: render-once; the `configure` hook NEVER rewrites an existing `config.yml`; `detector` applies only at render (first boot or delete-and-regenerate) | M6 ruling stands |

## 3. Components

### 3.1 `snap set` plumbing
- Wrappers read `snapctl get <key>` with in-wrapper defaults (no install-hook default seeding): `nginx-run` renders the listen config from `ports.https` + `tls.enabled` and generates the self-signed cert per `tls.cert-profile`; `certsync-run` reads `certsync.interval` (and the served port); `frigate-run`/`validate-config` read `detector` at render time only — its unset-default IS the auto-detect (§2: `renderD*` → `ov`, else `cpu`).
- `configure` hook: validates every key (enumerated values; port 1024–65535; interval integer 10–3600; reject unknown values with a clear error via `snapctl` exit), then restarts the affected services (`snapctl restart`). Invalid values must fail the `snap set` — not wedge a daemon at next start.
- `tls.enabled=false`: nginx serves plain HTTP on `ports.https`; certsync's existing disabled-branch idles. The README carries the cookie-security caveat (`config.yml` `tls`/`cookie_secure` are Frigate-side, operator-owned).

### 3.2 Hardening backlog — IN
| Item | Shape |
|---|---|
| Version-stamped DB backups | `pre-refresh` writes `frigate-pre-<version>-<rev>.db`; `frigate-run` downgrade-restore picks the newest **compatible** backup (backup version ≤ current code, `sort -V`), replacing schema-blind newest-file selection. `pre-refresh` stays fail-closed with `timeout 300` (large-DB decision from M3 Risk 6: bounded fail-closed) and logs actionable guidance on failure |
| nginx log rotation | snapd-native **timer app**: `daemon: oneshot` + daily `timer:`, running staged `logrotate` with a copytruncate conf over `$SNAP_DATA/nginx/logs/*.log`. No fifth long-running daemon |
| Literal-safe URL renderer | `sed -f` URL substitution in `frigate-run`/`validate-config` replaced by `python3` `str.replace` reading the URL from the 0600 file — no argv exposure, `\|&\\` limitation retired |
| ECDSA option | `tls.cert-profile=ecdsa-p256` switches self-signed generation (`openssl ecparam`-based); default stays `rsa-4096` (upstream-faithful) |
| http2 | `http2 on;` added to the TLS server block (module already built) |
| Hygiene smalls | Delete dead `MESA_LIB` block in `frigate-run`; go2rtc/libedgetpu parts `/tmp` temp paths → `$CRAFT_PART_BUILD`; reconcile the detect width/height comment with the actual testclip stream; commented CPU-detector block in the config template |

### 3.3 Hardening backlog — docs-only
HSTS latent footgun; 365 d self-signed expiry + regenerate-by-deletion procedure (no auto-renewer); render-once upgrade notes (template updates in new revisions never touch an existing `config.yml`); `--skip-install` no-re-render edge (comment already landed M6).

### 3.4 Productization — one yaml
- `spike/snap/snapcraft.yaml` **moves to** `snap/snapcraft.yaml`, replacing the skeleton draft (draft-drift retires). Harness `SNAP_FILE` glob + build convention (`snapcraft pack` at repo root) update in the same task.
- Store metadata: upstream Frigate's license (verified at plan time), `grade: stable`, `platforms:` amd64 only, title/summary/description seeded from `accelerator-support.md`, `contact`/`source-code`/`website` → the GitHub repo.
- Probe apps stay as user-facing diagnostics (`frigate.coral-probe` etc., documented in README); test clip + bird model stay (harness substrate).

### 3.5 CI + Store (zwave-js-ui pattern, adapted)
- Repo pushed to the GitHub origin (`giaever-online-iot/frigate`) — explicit USER go-ahead at execution time; history verified clean of secrets/ignored artifacts (standing per-milestone checks).
- Workflows adapted from zwave-js-ui: `pr-build-snap.yml` (remote-build via Launchpad, archs from `platforms:` keys, upload to `latest/edge/PR<N>`, retry helpers), `release-on-merge.yml` **simplified to latest-only** (merge → promote PR branch → `latest/edge`), a manual `promote-beta` `workflow_dispatch`, `block-fork-prs.yml`, and a lint workflow (shellcheck over `spike/bin/*`, hooks, harness; helper unit tests).
- **De-risk first**: a straight `snapcraft remote-build` of current main BEFORE any CI wiring, and the remote-built artifact must pass the full local gate on this machine. Fallback if Launchpad can't build it (time/size): local-build + CI-upload (Approach B), recorded as a design change.
- USER actions (drafted by the milestone, executed by the user): `SNAPCRAFT_STORE_CREDENTIALS` repo secret (scoped `export-login`), declaration-request forum posts (`raw-usb`, `hardware-observe`, `shm-private`, `mount-observe` auto-connect), beta promotion trigger.

### 3.6 Docs
- `README.md`: golden path — install from Store, manual `snap connect` lines (until declarations approve), first login (journald-logged admin password), camera setup via `config.yml`, `snap set` reference table, diagnostics apps, links to `docs/accelerator-support.md`.
- Declaration-request post drafts under `docs/store/` (submitted by USER).
- `docs/m7-findings.md` in the house style closes the milestone.

### 3.7 Verification (harness above the denial marker; ALL M0–M6 assertions preserved)
1. `snap set frigate ports.https=<alt>` → restart → `ss` shows the new port serving TLS; reset to 8971 → original assertions still green.
2. `tls.cert-profile=ecdsa-p256` → regenerate → served cert is EC P-256; profile + files reset afterward.
3. `certsync.interval` honored (observable via journal cadence or a bounded swap-window assertion).
4. Version-stamped backup + newest-compatible restore proof: forge version sidecars/backups spanning newer & older versions; restore picks newest ≤ current.
5. logrotate: invoke the oneshot app manually → rotation observed on a seeded log.
6. Literal-safe renderer: render with a URL containing `|`, `&`, `\` → byte-exact in the output, no argv exposure (`/proc` spot check).
7. Detector auto-detect: on this machine (renderD* present) fresh render → `ov`; the `cpu` branch is exercised by the clean-machine verify.
8. Render-once guard: `snap set frigate detector=...` on an already-configured install → existing `config.yml` byte-unchanged (Risk 4's assertion).
9. Denial policy unchanged: 0 unexpected; new arms narrow + journal-quoted (logrotate/timer and hook candidates expected).
10. **Clean-machine verify (the money line)**: LXD VM, `snap install frigate --channel=latest/edge`, follow README ONLY → authed UI over TLS, CPU detector alive, 0 crash-loops. Executed once, recorded in findings; gates the beta promotion.

## 4. Out of scope (M7)

arm64 (`M7c`, own spec); per-version Store tracks + `set-default-track`; NPU userspace (documented not-yet-supported); ACME/auto-renewal; MQTT/HomeAssistant; model-IR reproducible conversion (documented); config.yml migration tooling.

## 5. Risks

1. **Launchpad remote-build viability** — this snap dwarfs zwave-js-ui (nginx compile, ~58 wheels, ffmpeg trees, node web-ui, 1.1 GB artifact). De-risked by the first task; fallback (local-build + CI-upload) named and acceptable.
2. **Public repo exposure** — pushing publishes history; standing hygiene checks (no secrets, no ignored artifacts) re-verified over the FULL history before push.
3. **Declaration latency** — days-to-weeks; non-blocking (README documents manual connects; beta ships without auto-connect).
4. **`configure` hook vs render-once** — the hook must never touch an existing `config.yml`; only service-level renders (nginx/certsync) react live. Enforced by review + a harness assertion (set `detector` on a configured install → `config.yml` unchanged).
5. **Auto-detect default change** — machines with broken DRI nodes could still select `ov`; the README's detector section is the escape hatch (`snap set` + regenerate).
