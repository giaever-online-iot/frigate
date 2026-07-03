# M2 Toolchain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Frigate v0.17.2 source (with the carried env-paths patch), the core wheel set, and the tag-exact ffmpeg matrix enter the snap; VAAPI hardware decode is proven; `frigate.validate-config` — real Frigate parsing a real config — exits 0 strict-confined (spec: `docs/superpowers/specs/2026-07-03-m2-toolchain-design.md`).

**Architecture:** Evolve `spike/` in place. New parts: `frigate-src` (git tag + patch) staged at `/opt/frigate` (layout-bound — `/opt` is on snapd's verified allow-list); ffmpeg part grows 5.0/7.0 trees (default 7.0, proven 8.0 kept); `spike-wheels` consumes `requirements-core.txt` (~58 entries; 13 deferred to the future `frigate-ai` companion snap). New command apps: `vaapi-probe`, `validate-config`.

**Tech Stack:** snapcraft 9 / core26 / strict; Frigate v0.17.2; NickM-27 FFmpeg-Builds (5.0/7.0 per tag, 8.0 kept); Python 3.11 + pip wheels; harness `tests/spike-smoke.sh`.

## Global Constraints

- Snap `frigate` v `0.0.1-spike`, `base: core26`, strict, amd64; build `cd spike && snapcraft pack` (Bash timeout 600000); if a part definition changes, expect that part (and spike-wheels if its source changed) to rebuild — never `snapcraft clean` the cached heavyweights without need.
- Harness: `sudo ./tests/spike-smoke.sh` / `--skip-install`; new assertions ABOVE the `# --- AppArmor denial scan (keep last) ---` marker. PASS = conclusive evidence.
- **Coral is present again: NO green-except-coral latitude in M2.** Verify `sudo lsusb | grep -Ei '1a6e|18d1'` before full runs; if the device vanished, STOP and report BLOCKED. Any coral FAIL with the device present is a real regression.
- Denial allowlist: exact labeled signatures; new arms only for expected-and-documented denials of kept components, narrow (profile/comm + specific name/capname), FINDING-labeled.
- **sha256-pin every binary fetch**; committed yaml has real URL+hash, `sha256sum -c -` between fetch and use. New fetch temp paths use `$CRAFT_PART_BUILD` (not global /tmp — M1 roll-up fix applied going forward).
- Shell-function gotcha: `jqr`/helpers invisible inside `sh -c` — inline `jq` with expanded paths there.
- Passwordless sudo ONLY for `/usr/bin/snap`, `/usr/bin/journalctl`, `/usr/bin/lsusb`, `tests/spike-smoke.sh`. Host has curl/jq/ss/timeout.
- Preserve ALL M0+M1 state: probes, apps, arms, wrappers (incl. MESA_LIB guards, lib-wait.sh), layouts, coral archival, wheels-src isolation.
- Upstream reference: scratchpad clone `/tmp/claude-1000/-home-joachimmgg-Development-giaever-online-iot-frigate/0dd7cb9e-369c-4a10-9fed-1ecbe74c6a05/scratchpad/frigate-v0172` (re-clone shallow `--branch v0.17.2` if missing).
- Evidence-driven-adaptation latitude (M0/M1 pattern): reality-forced deviations must be (a) evidence-quoted, (b) minimal, (c) documented in the task report.
- Findings deliverable: `docs/m2-findings.md`. Prior findings docs are closed records.

## File Structure

```
spike/
  snap/snapcraft.yaml         # ffmpeg part grows 5.0/7.0; + frigate-src part; + /opt/frigate layout; + vaapi-probe, validate-config apps; ffprobe app retargets 7.0
  patches/0001-env-driven-paths.patch   # NEW: the carried patch (born here)
  config/frigate-config.yml   # NEW: minimal validation config template
  bin/vaapi-probe             # NEW
  bin/validate-config         # NEW
  wheels-src/requirements-core.txt      # NEW (~58 verbatim upstream lines)
  wheels-src/DEFERRED-frigate-ai.txt    # NEW: the 13 deferred entries + rationale
  wheels-src/requirements-spike.txt     # REMOVED (superseded by requirements-core.txt)
docs/patches.md               # NEW: carried-patch register with rebase notes
docs/m2-findings.md           # Task 6 deliverable
tests/spike-smoke.sh          # new sections per task
```

---

### Task 1: Tag-exact ffmpeg matrix (5.0 + 7.0 staged, default 7.0, 8.0 kept)

**Files:**
- Modify: `spike/snap/snapcraft.yaml` (ffmpeg part override-build; ffprobe app command)
- Modify: `tests/spike-smoke.sh`

**Interfaces:**
- Produces: `$SNAP/usr/lib/ffmpeg/{5.0,7.0,8.0}/bin/{ffmpeg,ffprobe}`; `frigate.ffprobe` app now runs the **7.0** binary (Tasks 4–5 and the existing RTSP e2e check thereby exercise the tag-default tree).

- [ ] **Step 1 (RED): update + add harness assertions** (locate the existing `ffprobe (8.0 tree) runs` check; replace and extend):

```bash
# --- M2: ffmpeg matrix (Task 1) --- ffprobe app follows the tag-default 7.0 tree
check "ffprobe app runs tag-default 7.0" sh -c "snap run frigate.ffprobe -version 2>/dev/null | head -1 | grep -q '^ffprobe version n7'"
# static builds run directly from the mounted squashfs (no confinement needed for -version)
for V in 5.0 7.0 8.0; do
  check "ffmpeg tree $V present+runs" sh -c "/snap/frigate/current/usr/lib/ffmpeg/$V/bin/ffprobe -version | head -1 | grep -q '^ffprobe version'"
done
```
Run `sudo ./tests/spike-smoke.sh --skip-install` — Expected: the n7 check and the 5.0/7.0 tree checks FAIL (8.0 passes).

- [ ] **Step 2: discover the tag URLs + hashes.** v0.17.2 pins its 5.0/7.0 builds in `docker/main/install_deps.sh` (M1 Task 1 located them):

```bash
SCRATCH=/tmp/claude-1000/-home-joachimmgg-Development-giaever-online-iot-frigate/0dd7cb9e-369c-4a10-9fed-1ecbe74c6a05/scratchpad
grep -n -i -E 'ffmpeg.*(tar\.xz|FFmpeg-Builds|https)' "$SCRATCH/frigate-v0172/docker/main/install_deps.sh"
```
Take the EXACT amd64 URLs upstream uses for its "5.0" and "7.0" trees. Download each to `$SCRATCH/`, `sha256sum` them. If upstream's URL construction is arch/var-substituted, resolve it exactly as the script would for amd64 and quote the resolution in your report.

- [ ] **Step 3: extend the ffmpeg part.** In the existing `ffmpeg` part's `override-build`, keep the 8.0 block and add (real URLs/hashes — no placeholders; note `$CRAFT_PART_BUILD` per Global Constraints):

```yaml
      # --- 5.0 tree (tag-exact, v0.17.2 install_deps.sh) ---
      wget -O "$CRAFT_PART_BUILD/ffmpeg-5.tar.xz" "<URL-5.0-FROM-STEP-2>"
      echo "<SHA256-5.0>  $CRAFT_PART_BUILD/ffmpeg-5.tar.xz" | sha256sum -c -
      mkdir -p "$CRAFT_PART_BUILD/f5" && tar -xJf "$CRAFT_PART_BUILD/ffmpeg-5.tar.xz" -C "$CRAFT_PART_BUILD/f5" --strip-components=1
      install -D -m 0755 "$CRAFT_PART_BUILD/f5/bin/ffmpeg"  "$CRAFT_PART_INSTALL/usr/lib/ffmpeg/5.0/bin/ffmpeg"
      install -D -m 0755 "$CRAFT_PART_BUILD/f5/bin/ffprobe" "$CRAFT_PART_INSTALL/usr/lib/ffmpeg/5.0/bin/ffprobe"
      # --- 7.0 tree (tag-exact default) ---
      wget -O "$CRAFT_PART_BUILD/ffmpeg-7.tar.xz" "<URL-7.0-FROM-STEP-2>"
      echo "<SHA256-7.0>  $CRAFT_PART_BUILD/ffmpeg-7.tar.xz" | sha256sum -c -
      mkdir -p "$CRAFT_PART_BUILD/f7" && tar -xJf "$CRAFT_PART_BUILD/ffmpeg-7.tar.xz" -C "$CRAFT_PART_BUILD/f7" --strip-components=1
      install -D -m 0755 "$CRAFT_PART_BUILD/f7/bin/ffmpeg"  "$CRAFT_PART_INSTALL/usr/lib/ffmpeg/7.0/bin/ffmpeg"
      install -D -m 0755 "$CRAFT_PART_BUILD/f7/bin/ffprobe" "$CRAFT_PART_INSTALL/usr/lib/ffmpeg/7.0/bin/ffprobe"
```
(If the tarballs' internal layout differs per tree — e.g. no top-level dir — adjust `--strip-components` to the REAL layout and quote it in your report.)

- [ ] **Step 4: retarget the ffprobe app** in `snapcraft.yaml`:

```yaml
  ffprobe:
    command: usr/lib/ffmpeg/7.0/bin/ffprobe
    plugs: [network]
```

- [ ] **Step 5 (GREEN): rebuild (`snapcraft clean ffmpeg` first — its definition changed), reinstall, full harness ALL PASS; commit**

```bash
cd spike && snapcraft clean ffmpeg && snapcraft pack && cd .. && sudo ./tests/spike-smoke.sh
git add spike/ tests/spike-smoke.sh
git commit -m "m2: tag-exact ffmpeg 5.0+7.0 trees (sha256-pinned), ffprobe app on 7.0 default"
```
Note: the RTSP e2e check now consumes via the 7.0 ffprobe — it must stay green (h264/1280x720 assertions unchanged).

---

### Task 2: `frigate-src` part + the carried env-paths patch

**Files:**
- Create: `spike/patches/0001-env-driven-paths.patch`, `docs/patches.md`
- Modify: `spike/snap/snapcraft.yaml` (part + layout), `tests/spike-smoke.sh`

**Interfaces:**
- Produces: `$SNAP/opt/frigate/{frigate,migrations}` (v0.17.2, patched); layout `/opt/frigate → $SNAP/opt/frigate`; env contract consumed by Task 5: `FRIGATE_CONFIG_DIR`, `FRIGATE_BASE_DIR`, `FRIGATE_CACHE_DIR` override `CONFIG_DIR`/`BASE_DIR`/`CACHE_DIR` in `frigate/const.py` (upstream defaults when unset).

- [ ] **Step 1 (RED): harness assertions** above the marker:

```bash
# --- M2: frigate source + carried patch (Task 2) ---
check "frigate source staged" test -f /snap/frigate/current/opt/frigate/frigate/const.py
check "carried patch applied (env-driven paths)" grep -q 'FRIGATE_CONFIG_DIR' /snap/frigate/current/opt/frigate/frigate/const.py
check "migrations staged" test -d /snap/frigate/current/opt/frigate/migrations
```
Run `--skip-install`: Expected: all three FAIL.

- [ ] **Step 2: author the patch against the REAL tag source.** In the scratchpad clone, read `frigate/const.py` fully. Transform the three base constants to env-driven form, e.g.:

```python
CONFIG_DIR = os.environ.get("FRIGATE_CONFIG_DIR", "/config")
BASE_DIR = os.environ.get("FRIGATE_BASE_DIR", "/media/frigate")
CACHE_DIR = os.environ.get("FRIGATE_CACHE_DIR", "/tmp/cache")
```
Requirements: (a) `import os` present; (b) every DERIVED constant (`DEFAULT_DB_PATH`, `MODEL_CACHE_DIR`, `RECORD_DIR`, `CLIPS_DIR`, `EXPORT_DIR`, `BIRDSEYE_PIPE`, and any other path literal rooted in /config, /media/frigate or /tmp/cache) must be expressed in terms of these variables — patch any that are independent literals; (c) unset env ⇒ byte-identical values to upstream. Generate: `cd "$SCRATCH/frigate-v0172" && git diff > <repo>/spike/patches/0001-env-driven-paths.patch`, then `git checkout -- .` to leave the clone clean.

- [ ] **Step 3: verify the patch's no-op + override behavior** without importing the frigate package (its `__init__` may pull heavy deps) — load const.py directly:

```bash
cd "$SCRATCH/frigate-v0172" && git apply "<repo>/spike/patches/0001-env-driven-paths.patch"
PY='import importlib.util; spec=importlib.util.spec_from_file_location("c","frigate/const.py"); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); print(m.CONFIG_DIR, m.BASE_DIR, m.CACHE_DIR, m.DEFAULT_DB_PATH, m.RECORD_DIR)'
python3 -c "$PY"                                   # expect: /config /media/frigate /tmp/cache /config/frigate.db /media/frigate/recordings
FRIGATE_CONFIG_DIR=/X FRIGATE_BASE_DIR=/Y FRIGATE_CACHE_DIR=/Z python3 -c "$PY"   # expect: /X /Y /Z /X/frigate.db /Y/recordings
git checkout -- . 
```
Both outputs quoted verbatim in your report (this is the patch's TDD evidence).

- [ ] **Step 4: add the part + layout to `snapcraft.yaml`**

```yaml
  frigate-src:
    plugin: nil
    source: https://github.com/blakeblackshear/frigate.git
    source-tag: v0.17.2
    source-depth: 1
    override-build: |
      patch -p1 < "$CRAFT_PROJECT_DIR/patches/0001-env-driven-paths.patch"
      mkdir -p "$CRAFT_PART_INSTALL/opt/frigate"
      cp -r frigate migrations "$CRAFT_PART_INSTALL/opt/frigate/"
```
Layout (append to the existing `layout:` block — `/opt` is allow-listed, verified by the M2 probe matrix):

```yaml
  /opt/frigate:
    bind: $SNAP/opt/frigate
```

- [ ] **Step 5: create `docs/patches.md`**

```markdown
# Carried patches (downstream deviations from upstream Frigate)

| Patch | Introduced | Purpose | Rebase notes |
|---|---|---|---|
| `spike/patches/0001-env-driven-paths.patch` | M2 (v0.17.2) | Make `frigate/const.py` base paths env-overridable (`FRIGATE_CONFIG_DIR`/`FRIGATE_BASE_DIR`/`FRIGATE_CACHE_DIR`; defaults unchanged ⇒ upstream no-op). Required because snapd layouts cannot target `/config` (root-level) or `/media/*` (denied allow-list entry) — see docs/m2-findings.md. | Re-diff against each new tag; constants may move/rename. Upstreaming candidate: yes — a small, defaults-preserving env override is upstreamable; consider a PR after M3 proves it in production shape. |

A second patch (shm name prefix, `snap.<instance>.*`) is planned for M3 — see docs/spike-findings.md (A1).
```

- [ ] **Step 6 (GREEN): rebuild, reinstall, full harness ALL PASS; commit**

```bash
cd spike && snapcraft pack && cd .. && sudo ./tests/spike-smoke.sh
git add spike/ docs/patches.md tests/spike-smoke.sh
git commit -m "m2: frigate v0.17.2 source + carried env-paths patch, /opt/frigate layout"
```

---

### Task 3: Core wheels (~58) + curated import batch

**Files:**
- Create: `spike/wheels-src/requirements-core.txt`, `spike/wheels-src/DEFERRED-frigate-ai.txt`
- Delete: `spike/wheels-src/requirements-spike.txt` (git rm — superseded)
- Modify: `spike/snap/snapcraft.yaml` (spike-wheels `-r` filename), `spike/probes/probe_runtime.py` (module list), `tests/spike-smoke.sh`

**Interfaces:**
- Produces: full core site-packages; `imports.json` grows per-module entries for the curated batch. Task 5 depends on the core set being importable.

- [ ] **Step 1 (RED): extend the harness import loop** (locate the existing `for MOD in numpy cv2 ...` loop; extend the list):

```bash
for MOD in numpy cv2 onnxruntime tflite_runtime tensorflow openvino fastapi uvicorn starlette peewee pydantic scipy norfair zmq cryptography ruamel.yaml paho.mqtt.client; do
  check "import $MOD" sh -c "jq -e '.imports.\"$MOD\".ok == true' \"$RESULTS/imports.json\""
done
```
(Note: dotted module names as jq keys need the quoted-key form shown. The existing per-module checks are replaced by this single extended loop.) Run `--skip-install`: new modules FAIL.

- [ ] **Step 2: derive the requirement files.** Copy upstream verbatim, then split:

```bash
SCRATCH=/tmp/claude-1000/-home-joachimmgg-Development-giaever-online-iot-frigate/0dd7cb9e-369c-4a10-9fed-1ecbe74c6a05/scratchpad
cp "$SCRATCH/frigate-v0172/docker/main/requirements-wheels.txt" spike/wheels-src/requirements-core.txt
```
Move these 13 entries (their FULL verbatim lines, env markers included) OUT of requirements-core.txt and INTO `spike/wheels-src/DEFERRED-frigate-ai.txt`: `transformers`, `faster-whisper`, `sherpa-onnx`, `librosa`, `soundfile`, `google-genai`, `ollama`, `openai`, `degirum`, `pandas`, `memray`, `mypy`, and the `git+https://github.com/fbcotter/py3nvml` line. DEFERRED file header:

```
# DEFERRED to the frigate-ai companion content-snap (plan-of-record: docs/m2-findings.md).
# Optional AI/ALPR/transcription + dev/NVIDIA-only entries excluded from the core snap.
# Lines below are VERBATIM from v0.17.2 docker/main/requirements-wheels.txt.
```
Sanity: `grep -cvE '^\s*(#|$)' spike/wheels-src/requirements-core.txt` ≈ 58. `git rm spike/wheels-src/requirements-spike.txt`. Update the `spike-wheels` part: `-r requirements-spike.txt` → `-r requirements-core.txt`.

- [ ] **Step 3: extend `imports_probe`** in `spike/probes/probe_runtime.py` — replace the module tuple with:

```python
    for mod in ("numpy", "cv2", "onnxruntime", "tflite_runtime", "tensorflow",
                "openvino", "fastapi", "uvicorn", "starlette", "peewee",
                "pydantic", "scipy", "norfair", "zmq", "cryptography",
                "ruamel.yaml", "paho.mqtt.client"):
```
(`__import__("a.b")` returns the top module but executes the full path — the existing ok/version logic works; for dotted names read `__version__` via `importlib.import_module(mod)` instead of `__import__` if the existing helper misbehaves — adjust minimally and note it.)

- [ ] **Step 4 (GREEN): rebuild (spike-wheels rebuilds — ~10–20 min, network fetches ~52 new wheels), reinstall, full harness ALL PASS; commit**

```bash
cd spike && snapcraft pack && cd .. && sudo ./tests/spike-smoke.sh
git add spike/ tests/spike-smoke.sh
git commit -m "m2: core wheel set (~58) with DEFERRED frigate-ai manifest, curated import batch"
```
Report the new .snap size. Any wheel that fails to build/install: quote the exact pip error — if it needs a build tool (`g++` is absent from core26 build env — known M0 finding) or a system lib, stage the minimal addition evidence-driven and document.

---

### Task 4: `frigate.vaapi-probe` — hardware decode proof

**Files:**
- Create: `spike/bin/vaapi-probe`
- Modify: `spike/snap/snapcraft.yaml` (app), `tests/spike-smoke.sh`

**Interfaces:**
- Consumes: 7.0 tree (Task 1), live `rtsp://127.0.0.1:8554/test` (M1), mesa-2604 via the `gpu` extension.
- Produces: `$EVIDENCE/vaapi-decode.txt` (ffmpeg stderr) — Task 6 cites it.

- [ ] **Step 1 (RED): harness section** above the marker:

```bash
# --- M2: VAAPI hardware decode (Task 4) ---
# -hwaccel_output_format vaapi FORBIDS silent software fallback: rc=0 proves the hw path.
check "vaapi: hw decode of synthetic stream (rc=0, no sw fallback)" snap run frigate.vaapi-probe
cp /var/snap/frigate/common/spike-results/vaapi-decode.txt "$EVIDENCE/" 2>/dev/null || true
check "vaapi: evidence captured" test -s "$EVIDENCE/vaapi-decode.txt"
echo "  vaapi finding: $(grep -m1 -iE 'vaapi|hwaccel' "$EVIDENCE/vaapi-decode.txt" 2>/dev/null || echo 'see vaapi-decode.txt')"
```
Run `--skip-install`: FAIL (app missing).

- [ ] **Step 2: wrapper `spike/bin/vaapi-probe`** (then `chmod +x`):

```sh
#!/bin/sh
# M2: prove VAAPI hardware decode under strict confinement. -hwaccel_output_format vaapi
# makes ffmpeg FAIL (non-zero) if the hw path is unavailable - no silent software fallback.
mkdir -p "$SNAP_COMMON/spike-results"
exec "$SNAP/usr/lib/ffmpeg/7.0/bin/ffmpeg" -hide_banner \
  -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi \
  -rtsp_transport tcp -i rtsp://127.0.0.1:8554/test \
  -frames:v 30 -f null - 2> "$SNAP_COMMON/spike-results/vaapi-decode.txt"
```

- [ ] **Step 3: app stanza** (gpu-probe pattern):

```yaml
  vaapi-probe:
    command: bin/vaapi-probe
    extensions: [gpu]
    plugs: [opengl, network]
```
(`network` is required — loopback RTSP; M1 finding.)

- [ ] **Step 4 (GREEN): rebuild, reinstall, full harness ALL PASS; commit**

```bash
cd spike && snapcraft pack && cd .. && sudo ./tests/spike-smoke.sh
git add spike/ tests/spike-smoke.sh
git commit -m "m2: vaapi-probe proves hardware decode of the synthetic stream"
```
If the probe fails: the stderr in vaapi-decode.txt IS the finding — check for AppArmor denials (triage per policy) vs libva errors (evidence-driven staging latitude, e.g. missing va driver pieces; quote everything). Do not soften `-hwaccel_output_format vaapi`.

---

### Task 5: `frigate.validate-config` — the money test

**Files:**
- Create: `spike/config/frigate-config.yml`, `spike/bin/validate-config`
- Modify: `spike/snap/snapcraft.yaml` (app; the config file ships via the existing `go2rtc-config` part's `config/` dir), `tests/spike-smoke.sh`

**Interfaces:**
- Consumes: `/opt/frigate` source + env contract (Task 2), core wheels (Task 3), ffmpeg matrix env (Task 1).
- Produces: validation exit-0 + `$EVIDENCE/validate-config.txt` — the M2 exit criterion Task 6 cites.

- [ ] **Step 1: discover the validation entrypoint.** In the scratchpad clone: `grep -rn 'validate' "$SCRATCH/frigate-v0172/frigate/__main__.py" "$SCRATCH/frigate-v0172/frigate/util/config.py" | head`. v0.17.x exposes a validate mode (e.g. `python3 -m frigate --validate-config` or a dedicated module). Use exactly what the tag implements; quote the relevant source lines in your report.

- [ ] **Step 2 (RED): harness section** above the marker:

```bash
# --- M2: frigate config validation (Task 5 - THE M2 EXIT CRITERION) ---
snap run frigate.validate-config > "$EVIDENCE/validate-config.txt" 2>&1
VC_RC=$?
check "frigate validate-config exits 0" test "$VC_RC" = "0"
check "validate-config evidence captured" test -s "$EVIDENCE/validate-config.txt"
echo "  validate finding: rc=$VC_RC $(tail -1 "$EVIDENCE/validate-config.txt" 2>/dev/null)"
```
Run `--skip-install`: FAIL (app missing).

- [ ] **Step 3: minimal config template `spike/config/frigate-config.yml`** (validated empirically — schema errors are the money test doing its job; adjust to the REAL v0.17.2 schema and quote final form):

```yaml
mqtt:
  enabled: false
cameras:
  test:
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:8554/test
          roles: [detect]
    detect:
      enabled: true
      width: 1280
      height: 720
      fps: 5
```

- [ ] **Step 4: wrapper `spike/bin/validate-config`** (then `chmod +x`):

```sh
#!/bin/sh
# M2 money test: real Frigate parses a real config under strict confinement.
set -e
export FRIGATE_CONFIG_DIR="$SNAP_DATA/config"
export FRIGATE_BASE_DIR="$SNAP_COMMON/media/frigate"
export FRIGATE_CACHE_DIR="/tmp/cache"
export CONFIG_FILE="$SNAP_DATA/config/config.yml"
export DEFAULT_FFMPEG_VERSION="7.0"
export INCLUDED_FFMPEG_VERSIONS="8.0:7.0:5.0"
mkdir -p "$SNAP_DATA/config" "$SNAP_COMMON/media/frigate" /tmp/cache
[ -f "$CONFIG_FILE" ] || cp "$SNAP/config/frigate-config.yml" "$CONFIG_FILE"
cd /opt/frigate   # through the Task-2 layout: also proves the layout works end-to-end
exec "$SNAP/usr/bin/python3.11" -u -m frigate <VALIDATE-ARGS-FROM-STEP-1>
```
Replace `<VALIDATE-ARGS-FROM-STEP-1>` with the discovered form before committing — no placeholder in the commit.

- [ ] **Step 5: app stanza:**

```yaml
  validate-config:
    command: bin/validate-config
    plugs: [network]
```

- [ ] **Step 6 (GREEN): rebuild, reinstall, full harness ALL PASS; commit**

```bash
cd spike && snapcraft pack && cd .. && sudo ./tests/spike-smoke.sh
git add spike/ tests/spike-smoke.sh
git commit -m "m2: validate-config money test - real frigate parses real config strict-confined"
```
**Import-chain latitude (expected to be needed):** `import frigate`/validation may demand pieces beyond the core wheels — likely candidates: `pysqlite3` (upstream builds it: `docker/main/build_pysqlite3.sh`), the `sqlite-vec` extension (`build_sqlite_vec.sh`), missing shared libs. For each failure: quote the exact ImportError/OSError, stage the minimal piece (a new part mirroring upstream's build script, sha256/tag-pinned), document in the report. Iterate until rc=0 or a genuine blocker emerges (then BLOCKED with full evidence).

---

### Task 6: M2 findings document + final run

**Files:**
- Create: `docs/m2-findings.md`

- [ ] **Step 1: verify Coral present, then final full harness run**

```bash
sudo lsusb | grep -Ei '1a6e|18d1' || { echo "BLOCKED: coral absent"; exit 1; }
sudo ./tests/spike-smoke.sh 2>&1 | tee spike/results/m2-final-run.txt
```
Expected: `SPIKE SMOKE: ALL PASS` (no latitude).

- [ ] **Step 2: write `docs/m2-findings.md`** (M0/M1 style; every verdict cites evidence; no empty sections). Required sections:

```markdown
# M2 Findings — Frigate source, core wheels, ffmpeg matrix, VAAPI

**Date:** <run date>  **Snap:** frigate 0.0.1-spike (core26, strict), <size>  **Frigate:** v0.17.2 (patched)

| # | Question | Verdict | Evidence |
|---|----------|---------|----------|
| M2-1 | ffmpeg matrix tag-exact (5.0/7.0 + kept 8.0), default 7.0? | <> | harness tree checks, m2-final-run.txt |
| M2-2 | carried env-paths patch: upstream no-op + env override proven? | <> | task-2 report step-3 outputs |
| M2-3 | core wheels (~58) import strict-confined? | <> | imports.json |
| M2-4 | VAAPI hw decode (no sw fallback) of the synthetic stream? | <> | vaapi-decode.txt |
| M2-5 | frigate.validate-config exits 0 (real code, real config)? | <> | validate-config.txt |

## Layout-rule investigation (corrects/refines the M0 mechanism record)
<the snapd validate.go allow-list (bin,etc,lib,lib64,meta,mnt,opt,root,sbin,snap,srv,usr,var,writable);
/media present-in-core26-base yet DENIED; the misleading "new top-level" error; the 8-path empirical
matrix (snap pack, snapd 2.75.2); consequence: /media/frigate un-layoutable -> env patch (M2-2) is the
mechanism; /srv,/mnt,/opt,/var/<new> available if ever needed>

## Carried patch register
<0001-env-driven-paths born in M2; pointer to docs/patches.md; shm patch planned M3>

## Deferred wheels + frigate-ai plan-of-record
<the 13 entries; companion content-snap architecture (mesa-2604 pattern, cp311 lockstep, PYTHONPATH wiring); prototype post-M7>

## Decisions unlocked for M3
<validate entrypoint form; import-chain pieces staged (if any); env contract proven; what M3's daemon needs>

## Deviations from expectations
<anything reality forced — or "none">

## Raw evidence
<one line per new file in spike/results/>
```

- [ ] **Step 3: commit**

```bash
git add docs/m2-findings.md
git commit -m "m2: findings - source+patch/wheels/ffmpeg-matrix/vaapi/validate verdicts"
```

---

## Self-Review (run after writing, fixed inline)

1. **Spec coverage:** §3.1 source+patch (Task 2), §3.2 wheels (Task 3), §3.3 matrix (Task 1), §3.4 VAAPI (Task 4), §3.5 money test (Task 5), §3.6 findings incl. layout investigation (Task 6), §4 verifications distributed across task harness sections, §2 decisions encoded in Global Constraints + task text. No gaps.
2. **Placeholder scan:** `<URL-*>`/`<SHA256-*>`/`<VALIDATE-ARGS-FROM-STEP-1>` are explicit discovery outputs with commit-must-contain-real-values rules (established M0/M1 pattern); findings `<>` cells are the deliverable's fill-ins. Clean otherwise.
3. **Type consistency:** env names (`FRIGATE_CONFIG_DIR`/`FRIGATE_BASE_DIR`/`FRIGATE_CACHE_DIR`) identical in Tasks 2/5 and spec §3.1; tree paths `usr/lib/ffmpeg/{5.0,7.0,8.0}/bin` consistent across Tasks 1/4/5; evidence filenames (`vaapi-decode.txt`, `validate-config.txt`, `m2-final-run.txt`) match between task sections and the Task-6 template; requirements filenames consistent (`requirements-core.txt`, `DEFERRED-frigate-ai.txt`).
