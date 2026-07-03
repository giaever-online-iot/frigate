# M2 Design Spec — Frigate source, core wheels, ffmpeg matrix, VAAPI proof

**Date:** 2026-07-03
**Status:** Approved design, pre-implementation
**Parent spec:** [`2026-07-02-frigate-snap-design.md`](2026-07-02-frigate-snap-design.md) (§4-M2)
**Evidence base:** [`docs/spike-findings.md`](../../spike-findings.md) (M0), [`docs/m1-findings.md`](../../m1-findings.md) (M1)

## 1. Goal

Frigate's own code enters the snap: the **v0.17.2 source** staged at `/opt/frigate` with the **carried env-paths patch**, the **core wheel set** (~58 of 71), the **tag-exact ffmpeg matrix** (5.0 + 7.0 added, default 7.0, proven 8.0 kept), **VAAPI hardware decode proven** on the synthetic stream, and the milestone's money test: **`frigate.validate-config` — real Frigate code parsing a real config — exits 0** under strict confinement. Daemonizing Frigate is M3.

## 2. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Source pin | **v0.17.2 tag-exact** for everything (code, wheels, ffmpeg URLs) | Stable, reproducible; upstream point releases become clean rebase targets for the carried patch |
| ffmpeg matrix | Tag-exact **5.0 + 7.0** staged, `DEFAULT_FFMPEG_VERSION=7.0`, `INCLUDED_FFMPEG_VERSIONS=8.0:7.0:5.0`; the M1-proven 8.0 tree **kept** (go2rtc keeps using it) | Tag-faithful defaults without discarding verified work; Frigate supports side-by-side trees natively |
| const.py strategy | **Env patch starts in M2**: `0001-env-driven-paths.patch` makes `CONFIG_DIR`/`BASE_DIR`/`CACHE_DIR` (and derived paths) env-overridable with upstream defaults | Config validation exercises the patch immediately; M3 inherits it proven. Layout investigation (§6) confirmed `/media/frigate` is un-layoutable — env override is the only path |
| Wheel scope | **Core ~58**; 13 optional-AI/heavy entries deferred with the **`frigate-ai` companion content-snap** recorded as their plan-of-record (post-M7 prototype) | YAGNI; keeps snap size and build cycles sane; companion pattern already proven in our stack by mesa-2604 |

## 3. Components

### 3.1 `frigate-src` part + the carried patch
- Source: `https://github.com/blakeblackshear/frigate.git`, `source-tag: v0.17.2`.
- Stages `frigate/` (python package) and `migrations/` at `$SNAP/opt/frigate/` (upstream layout — `python3 -m frigate` runs with `cwd`/`PYTHONPATH` at `/opt/frigate` per the existing `/opt/frigate` layout bind, which the M2 layout probe confirmed valid: `/opt` is on snapd's allow-list).
- **Patch** `spike/patches/0001-env-driven-paths.patch`, applied in override-build (`patch -p1`): `frigate/const.py` base-path constants become `os.environ.get("FRIGATE_<NAME>", "<upstream default>")` — at minimum `CONFIG_DIR` (/config), `BASE_DIR` (/media/frigate), `CACHE_DIR` (/tmp/cache); constants *derived* from these (DB path, model cache, record/clips/exports dirs) must follow the env-driven base. Defaults unchanged ⇒ no-op outside the snap. Documented in `docs/patches.md` with upstream-rebase notes and an upstreaming-candidate remark.
- Snap runtime env (daemons/apps): `FRIGATE_CONFIG_DIR=$SNAP_DATA/config`, `FRIGATE_BASE_DIR=$SNAP_COMMON/media/frigate`, `FRIGATE_CACHE_DIR=/tmp/cache` (private tmp — unchanged value, explicit for clarity).

### 3.2 Core wheels
- `spike/wheels-src/requirements-core.txt`: upstream `docker/main/requirements-wheels.txt` lines **verbatim**, minus the deferred set (each exclusion listed with a `# DEFERRED(frigate-ai):` comment or in an adjacent manifest): `transformers`, `faster-whisper`, `sherpa-onnx`, `librosa`, `soundfile`, `google-genai`, `ollama`, `openai`, `degirum`, `pandas`, `memray`, `mypy`, `py3nvml` (git dep; NVIDIA-only — strict-irrelevant).
- The existing `spike-wheels` part consumes the new file (replacing `requirements-spike.txt`'s 6-entry probe set — those 6 remain within the core set).
- Import verification extends the probe suite: the existing 6 imports stay; add a curated batch (fastapi, uvicorn, peewee, paho.mqtt, pydantic, scipy, norfair, ruamel.yaml, zmq, cryptography) plus **`import frigate`** itself (with the env vars set) — the real integration signal.

### 3.3 ffmpeg matrix part changes
- Discover the exact 5.0/7.0 URLs from v0.17.2's `docker/main/install_deps.sh` (they exist — M1 Task 1 located them); sha256-pin both; stage at `usr/lib/ffmpeg/{5.0,7.0}/bin/{ffmpeg,ffprobe}`.
- Daemon/app env: `DEFAULT_FFMPEG_VERSION=7.0`, `INCLUDED_FFMPEG_VERSIONS=8.0:7.0:5.0` (Frigate's only two honored env vars pre-patch; drives `resolve_ffmpeg_path`).
- go2rtc config keeps the 8.0 exec path (unchanged, already proven).

### 3.4 VAAPI decode proof (harness)
A dedicated command app `frigate.vaapi-probe` (same plug/extension pattern as gpu-probe: `extensions: [gpu]`, `plugs: [opengl]`) executes `ffmpeg -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 -i rtsp://127.0.0.1:8554/test -frames:v 30 -f null -` with `LIBVA_DRIVERS_PATH` from the mesa-2604 mount. **Evidence:** ffmpeg stderr showing VAAPI init + hw frames decoded, captured to `spike/results/vaapi-decode.txt`. `intel_gpu_top` is explicitly out of scope (needs CAP_PERFMON — known-denied class — and the host lacks the tool); ffmpeg's own report is the accepted proof.

### 3.5 The money test — `frigate.validate-config`
- Command app running Frigate's config validation entry (exact CLI form discovered from the v0.17.2 source at plan time — `python3 -m frigate --validate-config` or the equivalent module entry) with the env vars of §3.1.
- Minimal `config.yml` staged as a template and rendered to `$SNAP_DATA/config/config.yml` on first run: `mqtt: {enabled: false}`, one camera whose stream is `rtsp://127.0.0.1:8554/test` (the M1 synthetic camera), detect enabled with the CPU detector (smallest valid config — exact schema per v0.17.2 docs at plan time).
- **Pass = exit 0 + validation-success output captured.** Import-chain surprises (e.g. `sqlite-vec`, `pysqlite3` needed at import time even for validation) are handled with the established evidence-driven-staging latitude: quote the error, stage the minimal missing piece (upstream's build script if source-built), document.

### 3.6 M2 findings doc (`docs/m2-findings.md`)
Same style as M0/M1. Must include: the **layout-rule investigation** (snapd `validate.go` allow-list `bin,etc,lib,lib64,meta,mnt,opt,root,sbin,snap,srv,usr,var,writable`; `/media` present-in-base but denied; misleading error message; 8-path empirical matrix results; consequence unchanged — env patch required); the carried-patch birth record; the deferred-wheels list + `frigate-ai` companion-snap plan-of-record; VAAPI evidence; validate-config verdict.

## 4. Verification (harness, above the denial-scan marker; all M0+M1 assertions preserved)

1. ffmpeg trees: the `frigate.ffprobe` app **retargets to the default 7.0 tree** (assert `^ffprobe version n7` — the RTSP e2e check thereby exercises the tag-default tree); the 5.0 and 8.0 trees' presence is asserted by invoking each tree's ffprobe binary directly via `snap run --shell` in the harness (version-string check per tree).
2. Core-import suite green (existing 6 + curated batch + `import frigate`).
3. `frigate.validate-config` exits 0; output captured.
4. VAAPI decode evidence file non-empty and showing hw decode.
5. Denial policy unchanged: new denials triaged narrow+labeled only if expected-and-documented (candidates: VAAPI probe device access — should be covered by existing gpu-probe arms; frigate import filesystem probes).
6. Full harness ALL PASS — **Coral is present again**: no green-except-coral latitude in M2; a coral failure is a real regression.

## 5. Out of scope (M2)

Frigate as a daemon (M3); shm-prefix patch (M3 — validation does not exercise the frame pipeline); go2rtc config generation via `create_config.py` (M3); nginx/web UI (M4); the `frigate-ai` companion snap build (post-M7; architecture recorded only); NVIDIA anything.

## 6. Risks

1. **Import-chain surprises** during `import frigate`/validation (sqlite-vec, pysqlite3, missing native libs) — mitigated by evidence-driven staging latitude; each addition documented.
2. **Patch fragility**: `const.py` structure may differ at v0.17.2 from the master-based M0 analysis — the patch is authored against the actual tag source at plan/implementation time.
3. **Wheel-set build cost**: ~52 additional wheels (mostly small/pure-Python; heavyweights already staged) — build time grows once; wheels-src isolation (M0 fix) prevents rebuild churn.
4. **fastapi extras syntax** (`fastapi[standard-no-fastapi-cloud-cli]`) and any URL-pinned lines must be carried verbatim — pip handles both; verify in build.
5. **VAAPI probe device permissions**: the ffmpeg probe app needs `opengl` (+ mesa content) like gpu-probe; reuse that app's plug/extension pattern.
