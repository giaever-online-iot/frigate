# M7 Findings — Ship: on the Store at edge = beta = rev 3, configurable, hardened

**Date:** 2026-07-11  **Snap:** `frigate` 0.17.2 (core26, strict, amd64)  **Frigate:** v0.17.2  **Milestone HEAD:** `78ab8c7` (main; PR #3 merge)  **Store state:** `latest/edge` = **rev 3**, `latest/beta` = **rev 3**, visibility **private** (user choice, now verified)

M7 shipped the snap. It reached the Snap Store through the zwave-js-ui-pattern CI (Launchpad `remote-build` → PR channels → auto-promote on merge), carrying the full pragmatic `snap set` surface and the M3–M6 hardening backlog, a productized root `snap/snapcraft.yaml`, a README golden path, and three post-ship fix PRs driven by real field usage. The parent-spec money line — a clean machine installing from the Store and following **only** the README — is proven for an authenticated publisher install (rev 1, `PASS_WITH_FINDINGS`); the *anonymous* variant is deliberately unproven only because the user is keeping Store visibility private until verified (R1), now that it is verified the flip + anonymous re-check is a trivial user step.

**Provenance discipline (adapted — recorded as a deviation).** The plan's Task 9 called for a fresh authoritative local gate. That gate's `snap remove --purge` cycle is now destructive to the host NVR, which has become the user's **production** system (live cameras, events, recordings). So no fresh gate was run and **every number below names its evidence class:**

- **`[TRANSCRIPT]`** — grep-verified against the on-disk transcripts (`spike/results/m7-*.txt`); authoritative for their own run.
- **`[REPORT]`** — a gate banner quoted verbatim in a task/fix report, attributed to that report.
- **`[STORE/CI]`** — live command output run while writing this document (`snapcraft status frigate`, `gh`, `git`).
- **`[FIELD]`** — conversation-era, controller-run API outputs against the live Store rev 3 (class c-adjacent).

The most recent full **local** gate is the PR #3 review-fix round: **154 PASS / 0 FAIL / 6 SKIP, 564 denials / 0 unexpected** `[REPORT: fix-pr3-report.md Addendum 2]`, on tree-identical content to merged `main`.

---

## Verdict table

Parent-spec §4-M7 (clean-machine Store install / detection / documented connects) + spec §3.7 verification items 1–10 + the ship/CI criteria.

| # | Criterion (parent §4-M7 / spec §3.7) | Verdict | Evidence |
|---|---|---|---|
| Money | Clean machine installs from the Store following **only** the README → authed UI over TLS, detector alive, no crash-loop | **MET (authed) / DEFERRED (anonymous)** | Authed VM verify `PASS_WITH_FINDINGS`: rev 1 install 214 s, `snap whoami → joachim@giaever.online`, connects+TLS-auth+snap-set all PASS `[TRANSCRIPT: m7-vm-verify-authed.txt]`. Anonymous variant FAILs at Assert 1 (`error: snap "frigate" not found`; control `hello-world` installs fine) because the snap is **private** — not a defect, a visibility choice (R1) `[TRANSCRIPT: m7-vm-verify.txt]` |
| 1 | `snap set ports.https=<alt>` → TLS serves on the new port; reset restores | **MET** | `9443 bound=bound curl=200 → reset 8971 bound=bound curl=200` `[TRANSCRIPT: m7-gate2-remote.txt]`; live round-trip incl. HTTP/2 `[REPORT: task-2-report.md]` |
| 2 | `tls.cert-profile=ecdsa-p256` served (default stays rsa-4096) | **MET** | Served leaf `id-ecPublicKey … NIST CURVE: P-256` (`ASN1 OID: prime256v1`) `[TRANSCRIPT: m7-ecdsa-cert.txt]`; RSA default `rsaEncryption (4096 bit)` `[TRANSCRIPT: m7-rsa-cert.txt]`. **Gen time: ecdsa ≈ 0.01 s vs rsa-4096 ≈ 0.74–1.23 s** (~75–120×) `[REPORT: task-5-report.md]` |
| 3 | `certsync.interval` honored | **MET** | interval=15 → cert-swap reload observed **16–17 s** (bound ≤ 45 s; interval-60 M5 bound was 90 s) `[REPORT: task-5-report.md]`; reload journal line present `[TRANSCRIPT: m7-gate2-remote.txt]` |
| 4 | Version-stamped backup; newest **compatible** restore | **MET** | Restore picks `frigate-pre-0.17.2-rx1.db`, never `99.0.0`/`0.16.0`; incompatible db preserved `[TRANSCRIPT: m7-backup-restore.txt]` + `[REPORT: task-5-report.md item 4]` |
| 5 | logrotate oneshot rotates a seeded log | **MET** | rotated `.1` = 11 534 336 B, original truncated (copytruncate) `[REPORT: task-5-report.md; task-3-report.md PROOF 2]` |
| 6 | Literal-safe URL renderer (`\|&\`), no argv exposure | **MET** | `\|&\`-bearing TEST url byte-exact via python `str.replace`; retired `sed -f` fails on same url as expected `[REPORT: task-3-report.md PROOF 3; task-5-report.md item 6]` |
| 7 | Detector auto-detect at first render | **MET (hardened post-verify)** | Fresh render → `type:openvino=1 cpu=0 edgetpu=0` `[TRANSCRIPT: m7-gate2-remote.txt]`. **Vendor guard added** after VM verify caught auto-detect crashing the NVR on a virtio-gpu render node (R3): select `ov` only for vendor `0x8086`/`0x1002`, else `cpu` `[REPORT: fix-pr2-report.md Fix 1; unit A/B/C/D]` |
| 8 | Render-once guard: `snap set detector=…` never rewrites `config.yml` | **MET** | `config.yml` sha256 identical before/after `snap set detector=cpu` `[REPORT: task-5-report.md item 8]`; config byte-identical across every `snap set` `[REPORT: task-2-report.md]` |
| 9 | Reserved-port rejection (the 5000-auth guard) | **MET** | `ports.https=5000 … → snap set fails, error mentions reserved` `[TRANSCRIPT: m7-gate2-remote.txt; m7-vm-verify-authed.txt]`. Set `{5000,5001,1984,8554,8555}` rejected — `5000` re-opens M5's `X-Server-Port==5000` anonymous-admin short-circuit LAN-wide; the others wedge nginx bind-collisions `[REPORT: final-fix-report.md Fix 1]` |
| 10 | Invalid `snap set` values rejected; daemon state untouched | **MET** | 7 invalid values each exit non-zero via the configure hook; nginx stays active, bad value never committed `[REPORT: task-5-report.md item 7; final-fix-report.md]` |
| 11 | Denial policy unchanged: 0 unexpected; new arms narrow + journal-quoted | **MET** | Gate #1 503/0 `[REPORT: task-5]`; final-review gate 483/0 `[REPORT: final-fix-report.md]`; gate #2 488/0 `[TRANSCRIPT: m7-gate2-remote.txt]`; PR #3 gate 564/0 `[REPORT: fix-pr3-report.md]`. logrotate + ~20 configure-hook invocations produced **zero** unexpected denials — no new arms needed |
| 12 | Snap-size-floor tripwire (>900 MB, prime not gutted) | **MET** | `chosen snap … size=1140936704 bytes (floor 943718400)` PASS `[TRANSCRIPT: m7-gate2-remote.txt]`; controller-added after Task 4's 361 MB mid-write false alarm |
| 13 | Remote-build viability de-risked (fail → fix → success) | **MET** | Attempt 1 FAILED on the exact GCC-15 nginx-core error we independently found+fixed (build 3210946; 6 h 17 m) `[REPORT: task-1-report.md]`; retry (3211091) **Successfully built** from `f9a17a7`, 1 140 936 704 B, sha `ef92f10d…` `[REPORT: task-1b-report.md]` |
| 14 | Gate #2 — Launchpad remote-artifact parity | **MET (exceeded)** | **150 PASS / 0 FAIL / 1 SKIP, 488/0 denials** on the remote artifact, camera online → every historical money line PASSED in one run (M3 ov 7.43 ms, M5 authed TLS 200, M6 coral drift 9.39 ms + person event) `[TRANSCRIPT: m7-gate2-remote.txt]`. Sole SKIP = the deliberate npu retirement |
| 15 | Productized root `snap/snapcraft.yaml` + Store metadata | **MET** | `git mv` to root, all `source:` re-rooted, `grade: stable`, `license: MIT` (verified from upstream v0.17.2 LICENSE), title/summary/description/links seeded `[REPORT: task-4-report.md]`; review-tools `frigate_0.17.2_amd64.snap: pass` exit 0, zero warnings `[REPORT: final-fix-report.md]` |
| 16 | CI end-to-end: PR → Launchpad build → merge → auto-promote → beta | **MET** | PR #3: Lint&test 22 s → PR Build Snap 2 h 15 m 36 s → Release on merge 1 m 0 s (auto-promote → edge rev 3); `Promote to beta` `workflow_dispatch` success 46 s → beta rev 3 (first run) `[STORE/CI: gh run list]` |
| 17 | Shipping record: edge → beta, declarations filed during milestone | **MET (ship) / OPEN (declarations = user)** | `latest/edge` = rev 3, `latest/beta` = rev 3, PR channels PR1/2/3 = rev 1/2/3 `[STORE/CI: snapcraft status frigate]`. Declaration-request drafts staged (`docs/store/auto-connect-requests.md`); submission is a user action |

**Tally: 16 fully MET; 1 MET-with-open-user-action (declarations); the money line MET authed + DEFERRED anonymous (user visibility flip).** Zero criteria failed on any packaging ground.

---

## Ship record

Three Store revisions, each reaching `latest/edge`, plus the beta promotion.

| Rev | Content | Path to edge | Merged |
|---|---|---|---|
| **1** | The M7 build at final-review state (`f9a17a7`): full snap-set surface + hardening + productized yaml + npu dropped + reserved-port guard | **Manual bootstrap** — PR #1 built it via CI, but `release-on-merge`'s auto-promote died on the first-release gap (`no snap found`; §Discovery b); user promoted `latest/edge/PR1 → latest/edge` by hand | PR #1 `2026-07-10T00:03Z` (`b84bc32`) |
| **2** | Vendor-guarded detector auto-detect (R3) + README restart-after-connect (R2) + CI first-release tolerance | **First auto-promote** — `release-on-merge` SUCCEEDED (57 s), full pipeline proven zero-manual | PR #2 `2026-07-10T10:59Z` (`3b2559c`) |
| **3** | go2rtc config bridge (`create_config` parity) + `/logs` lean fix + restart-condition-always + README worked example + evidence credential scrubber | **Auto-promote** — `release-on-merge` SUCCESS (1 m 0 s) | PR #3 `2026-07-11T01:23Z` (`78ab8c7`) |
| **beta** | = rev 3 | **`promote-beta` `workflow_dispatch`, first run** (46 s, `2026-07-11T15:24Z`) `[STORE/CI]` | — |

PR merge times `[STORE/CI: gh pr list]`. Rev/channel map `[STORE/CI: snapcraft status frigate]`. The CI shakedown (PR #1) also proved `block-fork-prs` (a `pull_request_target` no-checkout `GITHUB_TOKEN`-only job) and the lint workflow; path-filters keep `lint-test` off doc-only changes.

---

## Discovery / findings records

### (a) Launchpad operational trilogy — three builds, three different failure modes

CI on this snap is Launchpad `remote-build`, and every one of the three real builds behaved differently. The pattern for CI: **tolerate all three** (retry helper + generous timeout margins + API-poll fallback).

1. **GCC-15 cold-cache failure (our bug, not Launchpad's).** Attempt 1 (build 3210946) FAILED deterministically in the `nginx` part: `-Werror=unterminated-string-initialization` on nginx 1.27.4's non-NUL-terminated string initializers under GCC 15.2.0 `[REPORT: task-1-report.md, verbatim log lines 6615–6671]`. Local LXD passed only because the nginx part was **cached** from a pre-15.2 snapshot; Launchpad always builds cold. The identical failure surfaced independently in Task 4's cold root build. Fix: `-Wno-error=unterminated-string-initialization` cc-opt (downgrades error→warning, diagnostic stays visible). Total wall-clock **6 h 17 m** (queue 5 h 31 m 51 s, on-builder 22 m 38 s).
2. **~24 h queue anomaly.** The retry (3211091) queued **7 h 41 m 18 s** vs the first attempt's 5 h 32 m (amd64 virt pool backlog ~81 356 jobs, snap score 2510) `[REPORT: task-1b-report.md]`. Remote-build is an **async release-channel publisher, not a PR-speed gate**.
3. **"pending: amd64" wedge.** PR #1's first CI build request was accepted but never dispatched (stuck `pending`) → workflow failed; the user re-ran and attempt 2 dispatched `[ledger progress.md]`.

Three companion tooling findings, all recorded for CI hardening: **`--recover` is broken in snapcraft 9.0.1** (reproduced 4×: `resume_builds()` looks the repo up in the owner-only namespace while `start_builds()` created it in the project namespace) → CI must monitor via the Launchpad API, not reattach; **launchpadlibrarian sends `Accept-Ranges: none`** so an interrupted artifact download has no range-resume — retry from byte 0 in one process; **remote-build hard-requires the invocation dir be a git repo** (attempt 1 needed a throwaway nested `git init` in `spike/`; the retry from repo root with root-level `snapcraft.yaml` worked first try).

### (b) Store first-release gaps

- **Unauthenticated `snap info` is blind to a never-released snap.** `release-on-merge`'s promote step queried the public channel map and got `no snap found`, so rev 1's auto-promote died — the snap was registered and released to edge, but that release is visible only to the authenticated publisher until a **first public release** exists. Fixed in PR #2: the info fetch is wrapped `if INFO="$(snap info …)"; then … else "first release: … promoting unconditionally"` `[REPORT: fix-pr2-report.md Fix 3]`. Rev 1 was hand-promoted as the bootstrap.
- **Visibility-private blocks anonymous install (README R1).** With the snap private, an anonymous clean machine gets `error: snap "frigate" not found` on the README's very first command, and the anonymous Store API returns `No snap named frigate found in series 16`; the same VM installs `hello-world` fine (control) `[TRANSCRIPT: m7-vm-verify.txt]`. The user chose to keep the snap private until verified — so the verify was re-run **authed** (VM snapd logged into the publisher account). The anonymous money line stays honestly unproven until the user flips visibility public and re-checks (trivial).

### (c) Field-defect table — six defects caught by real usage, all fixed

| # | Defect | Root cause | Fix | Evidence |
|---|---|---|---|---|
| **R3** | Auto-detect picked `ov` on a virtio-gpu render node → OpenVINO `Context was not initialized` → Frigate watchdog **clean-exits the whole NVR** (no `on-failure` relaunch) | Naive "renderD* present ⇒ ov" test; virtio-gpu/BMC-graphics/unsupported-GPU hosts have a render node OpenVINO can't drive (CRITICAL-class; affects VMs and BMC-graphics servers **on amd64 today**, same class as the predicted Mali/M7c case) | Vendor guard: read `/sys/class/drm/*/device/vendor`, select `ov` only for Intel `0x8086` / AMD `0x1002`, else `cpu` | `[TRANSCRIPT: m7-vm-verify-authed.txt R3]`; `[REPORT: fix-pr2-report.md, unit A→ov B/C/D→cpu]` (PR #2) |
| **R2** | README-literal install comes up **broken**: daemons auto-start before the manual `snap connect`s, `frigate` crash-loops on the boot-time `mount-observe` denial, `:5001` down, no admin password logged | Daemons start pre-connect; README never said to restart after connecting | README: "restart frigate after connecting interfaces" step (moot once auto-connect declarations approve) | `[TRANSCRIPT: m7-vm-verify-authed.txt R2]`; `[REPORT: fix-pr2-report.md Fix 2]` (PR #2) |
| — | **go2rtc `go2rtc:` section of `config.yml` ignored** → camera RTSP 404 (`test_2_2`) | Snap rendered a static `go2rtc.yaml` template every start (M1 relic); upstream *generates* go2rtc config **from** `config.yml` via `create_config.py` — the documented camera pattern + UI-wizard output | New `go2rtc-config-gen.py`: deep-merges the operator `go2rtc:` over the baseline, streams UNION, **`api.listen` FORCED to `127.0.0.1:1984`** (M5 loopback ruling — a deliberate divergence from upstream's configurable bind), `0600`, contents never printed; 18/18 fixture proofs | `[REPORT: fix-pr3-report.md Fix 1]` (PR #3) |
| — | **`/logs` UI toast `undefined.length`** | Logs API reads fixed `/dev/shm/logs/{frigate,go2rtc,nginx}/current` paths absent in the snap (logs go to journald) → 500 | **Lean** fix: `frigate-run` creates them after the shm-clear (`nginx/current`→symlink to the real error.log; others empty placeholders; nginx can't write `/dev/shm`, only `shm-private` apps can — verified). **Full stdout tee deferred (M-next):** POSIX sh has no `pipefail`, so `daemon \| tee` would break crash-exit propagation for the `on-failure` go2rtc service | `[REPORT: fix-pr3-report.md Fix 3]` (PR #3) |
| — | **UI restart button left frigate DOWN 3.5 min** | `restart_frigate()` sends `SIGINT` = clean exit; snap `on-failure` never relaunches a clean exit | frigate app → `restart-condition: always` (s6 any-exit parity); gate proves `POST /restart` → active in ~15 s | `[REPORT: fix-pr3-report.md Fix 4]` (PR #3) |
| — | **frigate → go2rtc `Failed to fetch streams`** | Transient (UI-restart saga); client target is hardcoded `http://127.0.0.1:1984/api/streams` = exactly where the snap binds go2rtc | Structural (no code change); harness now asserts the `/go2rtc/streams` proxy returns 200 + lists the bridge stream | `[REPORT: fix-pr3-report.md Fix 5]` (PR #3) |

### (d) Upstream-report candidate #4 — hot-add RecordingMaintainer `KeyError`

Field-observed on Store rev 3: a UI-wizard **hot-add** of a camera leaves `RecordingMaintainer`'s config snapshot stale → `KeyError('<cam>')` every ~17 s (`"Error occurred when attempting to maintain recording cache"` + the bare camera name; `maintainer.py` `self.config.cameras[camera]` ×6 sites; `object_/audio_recordings_info` are `defaultdict`s, exonerated). Recordings go unmanaged for the new camera **until a frigate restart** (verified: 0 errors post-restart, pipeline healthy). Upstream-report candidate #4 — **caveat: confirm via Docker repro** (`CameraConfigUpdateSubscriber [add,record]` should cover it and didn't). Practical guidance: restart after wizard-adding cameras; the UI restart button now works (PR #3). Also field-observed: the wizard sets `detect.enabled=false` on added cameras (so `detection_fps 0.0` is by config, not scene), and `_1`/`_2` role/stream mapping (main vs sub) should be user-verified (M3 guidance: detect=sub, record=main). `[ledger progress.md 2026-07-11 rev-3 item]`

### (e) Known-benign — multiprocessing leaked-semaphore warning

A journald `UserWarning` from CPython `multiprocessing.resource_tracker` (`"1 leaked semaphore objects to clean up at shutdown"`, `resource_tracker.py:254`, snap-staged python 3.11) appears ~once per restart. **Upstream Frigate/Python pattern, not packaging** — Frigate's mp machinery leaves a named semaphore unreleased on shutdown paths (especially the abrupt `/api/restart` exit); the tracker unlinks it and warns. Identical warning appears for upstream Docker users. Snap interaction already accounted for: semaphores live in private `/dev/shm`, and `frigate-run`'s start-time SHM clear deliberately **preserves** `psm_*`/`sem.*` (python-managed). Cosmetic. `[ledger progress.md known-benign item]`

---

## Security / credential record

*No credential value, camera IP, or stream URL appears in this document or the repo — mechanisms and incident descriptions only.*

- **Reserved-port auth guard.** The configure hook rejects `ports.https ∈ {5000,5001,1984,8554,8555}`. `5000` is the load-bearing one: nginx's auth subrequest short-circuits `X-Server-Port==5000` to anonymous (M5's internal-port design), so a `listen 5000 ssl` in the external server block would expose the admin UI unauthenticated LAN-wide; the other four collide with internal service binds and wedge nginx `[REPORT: final-fix-report.md Fix 1]`.
- **NPU custom-device dropped pre-Store.** The final review found the `npu-dev` slot / `npu` plug / `npu-probe` app shipping a super-privileged custom-device interface with **zero function** (NPU userspace out of scope). Dropped from the shipped snap (probe stays dormant in the repo; harness npu assertions conditionalized). `review-tools.snap-review frigate_0.17.2_amd64.snap: pass`, exit 0, **zero warnings** — dropping the slot is what cleared the manual-review risk `[REPORT: final-fix-report.md Fix 2 + verbatim review-tools output]`.
- **Evidence-credential incident (PR #3 review, CRITICAL).** A go2rtc `/api/streams` evidence capture wrote **operator camera credentials (both cameras)** to a gitignored harness evidence file; the scrubber only covered `$LIVECAM_URL`. Proximate cause: the new config-stash kept the cameras live through the gate. Vectors confirmed: `<stream>.producers[].url` and the `cpu_usages.<pid>.cmdline` ffmpeg command lines in `/stats`. Remediation: controller **deleted** the file + 4 more `/stats`-family credential-bearing files (sweep clean); a **two-layer scrubber** landed — Layer 1 capture-minimization (`jq 'keys'` names-only, `del(.producers[].url)`, `del(.cpu_usages)` on all five `/stats` captures) + Layer 2 a generalized `scrub_evidence()` redacting all `rtsp/rtsps/rtmp/http(s)` userinfo → `://REDACTED@` at end-of-run **and** from the EXIT trap; plus a **zero-creds gate assertion** (any `user:pass@` in evidence fails the run). Post-fix sweeps: **zero hits** `[REPORT: fix-pr3-report.md Addendum 2]`.
- **Full-history hygiene sweep, pre-push.** Before the public push (T8 Step 1): `git log --all --diff-filter=A` for `superpowers|spike/results` and a `git log -p` secret sweep for the camera host/creds patterns → **0 hits**; the three early-milestone force-added blobs (`m3-final-run.txt`, `task-5-report`, `task-10-report`) individually scanned 0 hits — untidy but SAFE, no filter-repo needed `[ledger progress.md T8 Step 1]`.
- **Store-credential transit incident.** The user `cat`'ed `login.auth` (Store macaroon, acls `package_access/push/release`, expires 2027-07-08) into the conversation, and the file sat untracked/un-ignored in the now-public working tree. Flagged immediately; remediation: value set as the `SNAPCRAFT_STORE_CREDENTIALS` repo secret via `gh`, file `rm`'d (tree clean), `.gitignore` hardened (`*.auth`, `*creds*.txt`) `[ledger progress.md]`.
- **Open rotation recommendations (user):** re-export the Store macaroon, and rotate **both** camera passwords (the second transited a reviewer report on local disk during PR #3). Logged as open hardening items.

**Repo hygiene, verified now:** `git ls-files .superpowers/ spike/results/` prints **nothing** (0 tracked) `[STORE/CI]`.

---

## Deviations

| Deviation | Reason | Reference |
|---|---|---|
| **No fresh authoritative local gate** (plan Task 9 Step 1) — this doc's numbers carry explicit evidence classes instead | The host NVR is now the user's production system; the gate's `snap remove --purge` cycle is destructive to live cameras/events/recordings. Controller-adjudicated | This document's provenance-discipline preamble |
| **Final whole-branch review ran BEFORE the ship + this findings task** | Plan's ship-order: the push goes public, so the review had to pass first. Consolidated fix wave (`344dd81`+`60218fd`+`f9a17a7`) landed pre-push | Review trail below; plan §Execution ordering |
| **PR-flow field fixes as post-"final-review" waves** — three PRs each with its own review + re-verdict, after M7 was "closed" | Real field usage on the shipped snap surfaced defects the local gate could never see (virtio-gpu auto-detect, go2rtc bridge, `/logs`) | §Discovery (b)/(c); PRs #1/#2/#3 |
| **Remote artifact carried the FULL M7 surface** (plan expected gate #2's M7 block to SKIP on a pre-M7 kickoff artifact) | Task 1's kickoff build FAILED; the retry (Task 1b) built from `f9a17a7` (post-final-review), so `M7_SURFACE` was true and the whole M7 block ran — a **stronger** parity result (150 PASS incl. M7) than planned | `[TRANSCRIPT: m7-gate2-remote.txt]`; `[REPORT: task-5-report.md §Gate #2]` |
| **NPU custom-device dropped from the shipped snap** (spec listed NPU as "documented not-yet-supported", not "remove the interface") | Final review: super-privileged slot with zero function = a manual-review liability; aligns with the user's NPU-out-of-scope ruling | §Security; `[REPORT: final-fix-report.md Fix 2]` |
| **`timeout 300` moved inside python** (plan step wrote `timeout 300 python3.11 …`) | The confined `pre-refresh` AppArmor profile **denies the base `/usr/bin/timeout`** — only `$SNAP/usr/bin/*` execs. Deadline enforced via a `sqlite3.Connection.backup` progress callback; still fail-closed | `[REPORT: task-3-report.md Finding A]` |
| **Backup retention switched from `sort -V` to mtime** (plan step wrote `sort -V`) | Plan defect: under `sort -V` a stamped name (`…-0.17.2-…`) sorts **below** a legacy name (`…-x…`), so with ≥2 legacy files the retention would delete every new stamped backup and legacy would never age out — silently defeating the feature | `[REPORT: task-3-report.md Finding B / sub-finding]` |
| **Minor deferred:** `mv -n` trap guard (double-abort + manual-reinstall edge, harness-only) | Non-blocking; deferred to the next harness PR | §M-next; `[REPORT: fix-pr3-report.md Addendum 2]` |

---

## Field validation record

On **Store rev 3** the user ran two **real production cameras** through the go2rtc bridge (the `go2rtc:` block of `config.yml`, PR #3's fix). Controller-run API outputs `[FIELD]`: OpenVINO `inference_speed` **6.86 ms**, **10 person events / 10 min** (top score **0.977**), **0 journal errors**. This is the ov detector path on the shipped Store artifact with the operator's own cameras — the strongest possible end-to-end signal (money line on production hardware). Class c-adjacent: the camera configuration is the user's, the API queries were controller-run `[ledger progress.md 2026-07-11 rev-3 field validation]`.

---

## M-next / backlog

| Item | Notes / origin |
|---|---|
| **M7c — arm64** | `platforms:arm64` + per-arch ffmpeg pins, ~58 aarch64 wheels (tensorflow/openvino variants — big unknown), per-arch GPU stack, libedgetpu/go2rtc arm64. **Auto-detect arch guard** (renderD* on ARM/Mali → would select ov → crash-loop) was the original M7c must-fix — **partially superseded by the R3 vendor guard** (`0x8086`/`0x1002` only); reassess whether the arch guard is still needed |
| **Snap size reduction** (~1.14 GB) | Leads: **three ffmpeg trees** (8.0/7.0/5.0 — audit which are used), **tensorflow-cpu vs tflite-runtime** (M2 module-level-import constraint — needs import-graph proof, no patching), OpenVINO wheel size, prime pruning (docs/locale/headers) + squashfs settings. **Interaction:** the >900 MB size-floor tripwire must be re-tuned when reduction lands. Candidate: fold into M7c (per-arch part audit overlaps) |
| **`/logs` full stdout tee-parity** | Deferred from PR #3 Fix 3 — POSIX sh has no `pipefail`; a `daemon \| tee` would break crash-exit propagation for the `on-failure` go2rtc service. Placeholders satisfy the API today; `snap logs`/journalctl authoritative |
| **NVR-safe gate mode** | A non-purging harness variant for production hosts — **new item from the no-fresh-gate deviation** |
| **Remove `svc-a/b/c` spike daemons** | The shipped snap still carries 3 M0 ordering-spike daemons (`apps:` in `snapcraft.yaml`); README documents four services, snap ships seven (R5). No place in a Store artifact; known M-next trim `[TRANSCRIPT: m7-vm-verify-authed.txt R5]` |
| **Per-version Store tracks + `set-default-track`** | Track helper math ships dormant with unit tests; needs Store approval requests |
| **`mv -n` trap guard** | Harness-only Minor deferred from PR #3 |
| **User actions (Store-side)** | Flip visibility public + re-run anonymous Assert 1 (R1); submit the `docs/store/auto-connect-requests.md` declaration posts; re-export the Store macaroon; rotate both camera passwords |
| **detect-fps guidance** | cam2 observed at 24 fps — worth README guidance |
| R4 semantic search | sqlite built without `enable_load_extension` → sqlite-vec unavailable; NVR otherwise runs (low priority) `[TRANSCRIPT: m7-vm-verify-authed.txt R4]` |

---

## Review trail

- **Per-task reviews (Tasks 1–7) — all Approved, 0 Critical / 0 Important each.** Task 2 (snap-set surface), Task 3 (hardening — reviewer independently re-derived the `sort -V` retention bug via filevercmp digit-vs-letter), Task 4 (productize — 1 Important cc-opt-comment-honesty fix, `ee97dc0`: the new nginx-core flag is a downstream deviation, not upstream-precedent), Task 5 (double gate — 145=112+33 reconciled), Task 6 (CI — every workflow diffed vs zwave source, fork-PR secret safety verified), Task 7 (docs — password line live-verified + masked). Task 1 report-only (no review gate).
- **Final whole-branch review** (Fable, `5d2b9a9..ee97dc0`): **"With fixes"** — **2 Critical**: (1) `ports.https=5000` re-opens the anonymous-admin path → reserved-set guard + harness assertion; (2) npu custom-device ships super-privileged with zero function → dropped pre-Store + `review-tools` pass. Plus Importants (Launchpad creds absent from the user checklist; README testclip/GPU hedge). Fix wave landed at `344dd81`+`60218fd`+`f9a17a7`, gate **483/0** `[REPORT: final-fix-report.md]`.
- **Post-ship PR reviews.** PR #2 (vendor guard + README + CI tolerance): merged after unit A/B/C/D proof; a pre-existing orthogonal Coral `net_admin` gate FAIL was resolved with the M6-pre-adjudicated allowlist arm (`1df4fe5`), gate then ALL PASS 484/0. **PR #3 pre-merge review** (opus) — the standout: **CRITICAL credential-leak finding** (operator creds in gitignored evidence, §Security) + IMPORTANT cross-run recovery guard defeated by template re-render; both resolved (`83d45ce`), final gate **154/0/6, 564/0, config byte-identical, zero user:pass@ hits**.

---

## Evidence index

**Provenance note:** `spike/results/` and `.superpowers/` are git-ignored. `git ls-files .superpowers/ spike/results/` returns empty `[STORE/CI]` — every file below is local-only, not tracked. The three PR fix reports and the seven task reports are the `[REPORT]` sources; the six `m7-*` transcripts are the `[TRANSCRIPT]` sources.

| File | Class | Content |
|---|---|---|
| `spike/results/m7-gate2-remote.txt` | TRANSCRIPT | Gate #2 on the **Launchpad remote artifact** (1 140 936 704 B): **SPIKE SMOKE: ALL PASS, 150 PASS / 0 FAIL / 1 SKIP, 488/0 denials**; every historical money line PASS (ov 7.43 ms, authed TLS 200, coral drift 9.39 ms + person event); full M7 surface (ports rebind, reserved-5000, auto-detect ov); sole SKIP = npu retirement |
| `spike/results/m7-vm-verify.txt` | TRANSCRIPT | **Anonymous** clean-machine verify — FAIL at Assert 1 (`snap "frigate" not found`); `hello-world` control installs; anonymous API `No snap named frigate found in series 16` (R1) |
| `spike/results/m7-vm-verify-authed.txt` | TRANSCRIPT | **Authed** re-run — `PASS_WITH_FINDINGS`: rev 1 private, install 214 s, `whoami joachim@giaever.online`, connects/TLS-auth/snap-set/reserved-5000 PASS, ~1290–1310 denials all benign; R2/R3/R4/R5/R6 findings |
| `spike/results/m7-ecdsa-cert.txt` | TRANSCRIPT | Served ECDSA leaf: `id-ecPublicKey`, `NIST CURVE: P-256`, `prime256v1`, 365 d, `O=FRIGATE DEFAULT CERT` |
| `spike/results/m7-rsa-cert.txt` | TRANSCRIPT | Served RSA default: `rsaEncryption (4096 bit)`, `sha256WithRSAEncryption` |
| `spike/results/m7-backup-restore.txt` | TRANSCRIPT | `frigate-run: restored … frigate-pre-0.17.2-rx1.db (incompatible db preserved …)` |
| `.superpowers/sdd/task-1-report.md` / `task-1b-report.md` | REPORT | Remote-build FAIL (GCC-15, 6 h 17 m) → RETRY SUCCESS (7 h 41 m queue, 30 m 36 s build, sha `ef92f10d…`); `--recover` broken, librarian no-range-resume, git-repo requirement |
| `.superpowers/sdd/task-2..7-report.md` | REPORT | snap-set surface; hardening (timeout-in-hook, retention bug); productize (MIT, cc-opt honesty); double gate (**145/0/5, 503/0**, measured cert/certsync/backup/logrotate values); CI; README+store drafts |
| `.superpowers/sdd/task-8-vm-report.md` | REPORT | Clean-machine verify write-up: R1–R6, timings, benign-denial families |
| `.superpowers/sdd/final-fix-report.md` | REPORT | Final-review fix wave (**483/0**, reserved-port, npu drop, review-tools `pass`) |
| `.superpowers/sdd/fix-pr2-report.md` / `fix-pr3-report.md` | REPORT | Post-ship PR #2 (vendor guard, **484/0**) and PR #3 (go2rtc bridge / `/logs` / restart / **154/0/6, 564/0**, credential-scrubber) |
| `docs/store/auto-connect-requests.md` | tracked | Declaration-request drafts (user submits) |
| `README.md` | tracked | Golden path: install, manual connects + restart step, first login, camera setup via `config.yml` + go2rtc worked example, `snap set` reference, diagnostics apps |
| `docs/superpowers/specs/2026-07-08-m7-ship-design.md` / `plans/2026-07-08-m7-ship.md` | tracked | M7 spec + plan |

**Live facts** `[STORE/CI]`: `snapcraft status frigate` → `latest/edge` rev 3, `latest/beta` rev 3, PR1/2/3 = rev 1/2/3, no candidate/stable. `gh` → PRs #1/#2/#3 merged 2026-07-10 00:03 / 2026-07-10 10:59 / 2026-07-11 01:23 Z; `Promote to beta` `workflow_dispatch` success (46 s, first run) 2026-07-11 15:24 Z.
