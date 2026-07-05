# M3 Frigate Daemon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Frigate runs as a strict-confined snap daemon detecting real objects on the Intel iGPU (OpenVINO), writing events to the split DB and recordings to disk, answering its API — plus the DB rollback machinery, proven by the harness (spec: `docs/superpowers/specs/2026-07-04-m3-frigate-daemon-design.md`).

**Architecture:** Evolve `spike/` in place. New parts: detector models (OpenVINO SSDLite via upstream's own provisioning + default CPU tflite fallback), a CC0 real-object test clip. The `frigate` daemon joins the chain after go2rtc (wait-gated), with the proven env contract, `shared-memory: private`, and the gpu extension. `database.path` splits the DB to `$SNAP_COMMON/db`; a `pre-refresh` hook + startup downgrade-restore provide rollback.

**Tech Stack:** snapcraft 9 / core26 / strict; Frigate v0.17.2 (patched, staged); OpenVINO 2025.3.0 (GPU device via mesa-2604 + OpenCL recipe); go2rtc v1.9.13; harness `tests/spike-smoke.sh`.

## Global Constraints

- Snap `frigate` v `0.0.1-spike`, `base: core26`, strict, amd64. Build: `cd spike && snapcraft pack` — **FOREGROUND ONLY** (Bash timeout 600000; if a call times out the LXD build continues — re-invoke `snapcraft pack` to reattach; NEVER use run_in_background/monitors — two M2 stalls proved them fragile).
- Harness: `sudo ./tests/spike-smoke.sh` / `--skip-install`; new assertions ABOVE the `# --- AppArmor denial scan (keep last) ---` marker; PASS = conclusive evidence; shell functions invisible in `sh -c` (inline jq with expanded paths).
- **Coral-conditional gate protocol:** `sudo lsusb | grep -Ei '1a6e|18d1'` before full runs. Present → full ALL PASS (a coral FAIL is then a real regression; the warm-up probe from Task 5 mitigates the documented long-idle flake). Absent (operator) → ALL PASS except exactly the 3 coral checks, report DONE_WITH_CONCERNS "green except coral (device unplugged by operator)".
- Denial allowlist: exact labeled signatures; new arms only for observed expected-and-documented denials of kept components, narrow (profile/comm + specific name/capname), FINDING-labeled. The frigate daemon WILL surface new denials — triage each; expect /sys stats reads and similar.
- **sha256-pin every fetch**; real URLs+hashes committed; temps under `$CRAFT_PART_BUILD`.
- Env contract (proven, M2): `FRIGATE_CONFIG_DIR=$SNAP_DATA/config`, `FRIGATE_BASE_DIR=$SNAP_COMMON/media/frigate`, `FRIGATE_CACHE_DIR=/tmp/cache`, `DEFAULT_FFMPEG_VERSION=7.0`, `INCLUDED_FFMPEG_VERSIONS=8.0:7.0:5.0`, `CONFIG_FILE=$SNAP_DATA/config/config.yml`. NEW in M3: DB at `$SNAP_COMMON/db/frigate.db` via Frigate's `database.path` config (config-level, no patch).
- The `shared-memory` plug with `private: true` already exists in the yaml (M2, named per the existing declaration — reuse it, do not redeclare).
- Passwordless sudo ONLY for `/usr/bin/snap`, `/usr/bin/journalctl`, `/usr/bin/lsusb`, `tests/spike-smoke.sh`. `snap restart`/`snap install` are sudo-snap and allowed.
- Preserve ALL M0+M1+M2 state (probes, apps, arms, wrappers, validate-config, layouts).
- Upstream reference clone: `/tmp/claude-1000/-home-joachimmgg-Development-giaever-online-iot-frigate/0dd7cb9e-369c-4a10-9fed-1ecbe74c6a05/scratchpad/frigate-v0172` (re-clone `--branch v0.17.2 --depth 1` if missing).
- Evidence-driven-adaptation latitude (established): reality-forced deviations quoted, minimal, documented.
- Findings deliverable: `docs/m3-findings.md`. Prior findings docs are closed records.

## File Structure

```
spike/
  snap/snapcraft.yaml           # + parts: detector-models, test-clip; + app: frigate; hooks auto-picked from snap/hooks/
  snap/hooks/pre-refresh        # NEW: sqlite .backup hook (executable)
  config/go2rtc.yaml.in         # MODIFIED: + testclip stream
  config/frigate-config.yml     # MODIFIED: real camera/detector/record/database config with __SNAP_COMMON__ placeholder
  bin/frigate-run               # NEW: daemon wrapper (env, wait gate, render, sidecar, downgrade-restore, exec)
  bin/validate-config           # MODIFIED: render template with the same substitutions (keep green)
  media-samples/                # via test-clip part (not committed; fetched at build)
docs/m3-findings.md             # Task 6 deliverable
docs/patches.md                 # (unchanged this milestone — no new patch; note added only if reality forces one)
tests/spike-smoke.sh            # + frigate/rollback/money-test sections + coral warm-up
```

---

### Task 1: Detector models part (OpenVINO SSDLite + CPU tflite fallback + labelmaps)

**Files:**
- Modify: `spike/snap/snapcraft.yaml` (add `detector-models` part)
- Modify: `tests/spike-smoke.sh` (staged-artifact assertions)

**Interfaces:**
- Produces: `$SNAP/opt/frigate/models/openvino/` (model.xml/model.bin or upstream's exact layout), `$SNAP/opt/frigate/models/cpu/` (default tflite), COCO labelmap at the path Frigate's config expects. Task 3's config references these exact paths.

- [ ] **Step 1: discover upstream's provisioning.** In the scratchpad clone, read how v0.17.2 produces its OpenVINO and CPU default models:

```bash
SCRATCH=/tmp/claude-1000/-home-joachimmgg-Development-giaever-online-iot-frigate/0dd7cb9e-369c-4a10-9fed-1ecbe74c6a05/scratchpad/frigate-v0172
grep -rn -i -E 'openvino-model|build_ov_model|ssdlite|cpu_model|\.tflite' "$SCRATCH/docker/main/Dockerfile" "$SCRATCH/docker/main/" | grep -v Binary | head -20
cat "$SCRATCH/docker/main/build_ov_model.py" 2>/dev/null
```
Identify: (a) the exact source artifacts (URLs) and conversion steps for the OpenVINO model, (b) the default CPU tflite model URL, (c) labelmap sources and the paths the final image places them at (grep the Dockerfile's COPY/RUN lines for `/openvino-model`, `/cpu_model`, labelmap). Quote everything in your report.

- [ ] **Step 2 (RED): staged-artifact assertions** above the denial-scan marker (adjust filenames to the REAL upstream layout discovered in Step 1 — the paths asserted here are the contract Task 3 consumes; state the final paths in your report):

```bash
# --- M3: detector models staged (Task 1) ---
check "openvino model staged" sh -c "ls /snap/frigate/current/opt/frigate/models/openvino/*.xml"
check "cpu tflite fallback staged" sh -c "ls /snap/frigate/current/opt/frigate/models/cpu/*.tflite"
check "coco labelmap staged" test -s /snap/frigate/current/opt/frigate/models/labelmap.txt
```
Run `--skip-install`: Expected FAIL ×3.

- [ ] **Step 3: add the `detector-models` part** mirroring upstream's mechanism. If upstream CONVERTS at build time (build_ov_model.py with openvino tooling): replicate with a part that `build-packages` a python3+pip venv OR reuses the staged wheels via `after: [python311, spike-wheels]` and runs the script against pinned source-model URLs (sha256 each downloaded artifact). If upstream downloads prebuilt artifacts: wget + sha256 + install. Either way: temps in `$CRAFT_PART_BUILD`, real hashes committed, and the conversion script (if used) copied from the clone into `spike/models-src/` so the build is self-contained. Show the full part in your commit; document which mechanism upstream used.

- [ ] **Step 4 (GREEN): rebuild, reinstall, full harness (coral-conditional protocol); commit**

```bash
cd spike && snapcraft pack && cd .. && sudo ./tests/spike-smoke.sh
git add spike/ tests/spike-smoke.sh
git commit -m "m3: detector models staged (openvino ssdlite + cpu tflite fallback, pinned)"
```

---

### Task 2: CC0 real-object test clip + go2rtc `testclip` stream

**Files:**
- Modify: `spike/snap/snapcraft.yaml` (add `test-clip` part), `spike/config/go2rtc.yaml.in` (add stream), `tests/spike-smoke.sh`
- Create: `spike/LICENSE-testclip` (license provenance note, committed)

**Interfaces:**
- Produces: `$SNAP/media-samples/testclip.mp4` (people and/or vehicles clearly visible, ≤ ~60 s); go2rtc stream `testclip` at `rtsp://127.0.0.1:8554/testclip`. Task 3's camera consumes this URL. The existing `test` (testsrc2) stream and ALL its assertions remain untouched.

- [ ] **Step 1: find and pin the clip.** Requirements: CC0/public-domain license explicitly stated on the source page; contains people and/or cars large enough for SSDLite (subjects fill a meaningful fraction of the frame); ≤ ~60 s; h264/mp4 preferred. Starting points: Wikimedia Commons (search "pedestrian crossing" / "street traffic" filtered to CC0/PD video), archive.org public-domain street footage. Download to the scratchpad, `sha256sum`, verify content with the SNAP's ffprobe (`/snap/frigate/current/usr/lib/ffmpeg/7.0/bin/ffprobe -v error -show_streams <file>` — host-runnable static binary). Record: URL, license page URL, license name, duration, resolution, what objects appear. Write `spike/LICENSE-testclip` with all of it.

- [ ] **Step 2 (RED): assertions** above the marker:

```bash
# --- M3: real-object test clip + stream (Task 2) ---
check "test clip staged" test -s /snap/frigate/current/media-samples/testclip.mp4
curl -sf --max-time 5 http://127.0.0.1:1984/api/streams > "$EVIDENCE/go2rtc-streams.json" 2>/dev/null || true
check "go2rtc has testclip stream" sh -c "jq -e '.testclip' \"$EVIDENCE/go2rtc-streams.json\""
```
(Note: the go2rtc-streams.json capture line already exists from M1 — reuse it rather than duplicating; only the `.testclip` check is new. Adjust to the file's current shape.) Run `--skip-install`: Expected FAIL ×2.

- [ ] **Step 3: the part + the stream.**

```yaml
  test-clip:
    plugin: nil
    build-packages: [wget]
    override-build: |
      wget -O "$CRAFT_PART_BUILD/testclip.mp4" "<URL-FROM-STEP-1>"
      echo "<SHA256-FROM-STEP-1>  $CRAFT_PART_BUILD/testclip.mp4" | sha256sum -c -
      install -D -m 0644 "$CRAFT_PART_BUILD/testclip.mp4" "$CRAFT_PART_INSTALL/media-samples/testclip.mp4"
```

In `spike/config/go2rtc.yaml.in`, under `streams:` add (7.0 = tag-default tree; `-stream_loop -1` loops forever; re-encode keeps consumer behavior uniform with the proven `test` stream):

```yaml
  testclip: exec:__SNAP__/usr/lib/ffmpeg/7.0/bin/ffmpeg -re -stream_loop -1 -i __SNAP__/media-samples/testclip.mp4 -c:v libx264 -preset veryfast -tune zerolatency -g 30 -an -f rtsp {output}
```

- [ ] **Step 4 (GREEN): rebuild, reinstall, full harness; verify the stream actually plays** (one focused check: `timeout 30 snap run frigate.ffprobe -v error -show_streams -rtsp_transport tcp rtsp://127.0.0.1:8554/testclip | head -5` shows h264); commit

```bash
git add spike/ tests/spike-smoke.sh
git commit -m "m3: CC0 real-object test clip (pinned, licensed) + go2rtc testclip stream"
```

---

### Task 3: The `frigate` daemon — boots strict-confined, API answers

**Files:**
- Create: `spike/bin/frigate-run`
- Modify: `spike/config/frigate-config.yml` (real config), `spike/bin/validate-config` (same render), `spike/snap/snapcraft.yaml` (app), `tests/spike-smoke.sh`

**Interfaces:**
- Consumes: models paths (Task 1), `rtsp://127.0.0.1:8554/testclip` (Task 2), env contract + `wait_for_url` (M1/M2), `shared-memory` private plug (M2 — reuse the existing plug name from the yaml).
- Produces: daemon `frigate.frigate` with API on `127.0.0.1:5001`; DB at `$SNAP_COMMON/db/frigate.db`; sidecar `$SNAP_COMMON/db/.last-writer` (`<frigate-version> <snap-revision>`, written every start — Task 4's restore reads it). Config rendered fresh EVERY start from the template (generated-config phase; snap-set configurability is M7).

- [ ] **Step 1 (RED): assertions** above the marker:

```bash
# --- M3: frigate daemon (Task 3 - THE MILESTONE) ---
check "frigate service active" sh -c "snap services frigate.frigate | grep -q ' active'"
curl -sf --max-time 5 http://127.0.0.1:5001/api/version > "$EVIDENCE/frigate-version.txt" 2>/dev/null || true
check "frigate API answers" test -s "$EVIDENCE/frigate-version.txt"
check "db at split path" test -f /var/snap/frigate/common/db/frigate.db
check "sidecar written" sh -c "grep -qE '^0\.17\.2' /var/snap/frigate/common/db/.last-writer"
```
Run `--skip-install`: Expected FAIL ×4.

- [ ] **Step 2: extend `spike/config/frigate-config.yml`** to the real M3 config (keep every M2-proven key; validator complaints drive final shape — quote deltas):

```yaml
mqtt:
  enabled: false
database:
  path: __SNAP_COMMON__/db/frigate.db
detectors:
  ov:
    type: openvino
    device: GPU
model:
  # paths per Task 1's staged layout — use the REAL discovered paths:
  path: /opt/frigate/models/openvino/<model-file-per-task-1>
  labelmap_path: /opt/frigate/models/labelmap.txt
  # width/height/input params per upstream's openvino defaults (discovery: frigate docs/config for ssdlite)
cameras:
  testclip:
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:8554/testclip
          roles: [detect, record]
    detect:
      enabled: true
      width: <clip-width>
      height: <clip-height>
      fps: 5
    objects:
      track: [person, car]
record:
  enabled: true
  retain:
    days: 1
version: "0.17-0"
```
(Replace the `<...>` values with Task 1/2 real values BEFORE committing — no placeholders in the commit. If the v0.17.2 schema rejects any key, the validator output is your guide; quote it.)

- [ ] **Step 3: create `spike/bin/frigate-run`** (then `chmod +x`):

```sh
#!/bin/sh
# M3: the Frigate daemon under strict confinement.
set -e
. "$SNAP/bin/lib-wait.sh"

export FRIGATE_CONFIG_DIR="$SNAP_DATA/config"
export FRIGATE_BASE_DIR="$SNAP_COMMON/media/frigate"
export FRIGATE_CACHE_DIR="/tmp/cache"
export CONFIG_FILE="$SNAP_DATA/config/config.yml"
export DEFAULT_FFMPEG_VERSION="7.0"
export INCLUDED_FFMPEG_VERSIONS="8.0:7.0:5.0"

mkdir -p "$SNAP_DATA/config" "$SNAP_COMMON/media/frigate" "$SNAP_COMMON/db" /tmp/cache

# MESA content mount (gpu extension cleanup strips libGL from the snap)
MESA_LIB="$SNAP/gpu-2604/usr/lib/x86_64-linux-gnu"
if [ -d "$MESA_LIB" ]; then export LD_LIBRARY_PATH="$MESA_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"; fi

# Render config fresh每 start (generated-config phase; snap-set configurability lands at M7)
sed -e "s|__SNAP_COMMON__|$SNAP_COMMON|g" -e "s|__SNAP__|$SNAP|g" \
    "$SNAP/config/frigate-config.yml" > "$CONFIG_FILE"

# Readiness gate on go2rtc (provider-answered, not just unit-started)
wait_for_url "http://127.0.0.1:1984/api/streams" 60 || true
echo "frigate-run: go2rtc gate waited_ms=${WAITED_MS:--1}"

# Downgrade-restore check happens BEFORE the sidecar write (Task 4 adds the restore block here)
CUR_VERSION=$(sed -n 's/^VERSION *= *"\([^"+-]*\).*/\1/p' "$SNAP/opt/frigate/frigate/version.py" | head -1)
printf '%s %s\n' "${CUR_VERSION:-0.17.2}" "$SNAP_REVISION" > "$SNAP_COMMON/db/.last-writer"

cd /opt/frigate
exec "$SNAP/usr/bin/python3.11" -u -m frigate
```
(NOTE: fix the accidental non-ASCII in the comment above when writing the file — comments must be plain ASCII: "Render config fresh EVERY start".)

- [ ] **Step 4: the app stanza** (reuse the EXISTING shared-memory plug name — read the yaml first; shown here as `shm-private` per M2's declaration):

```yaml
  frigate:
    command: bin/frigate-run
    daemon: simple
    restart-condition: on-failure
    after: [go2rtc]
    extensions: [gpu]
    plugs: [network, network-bind, opengl, shm-private]
```

- [ ] **Step 5: keep `validate-config` green.** Its wrapper copies the template raw; the template now contains `__SNAP_COMMON__`. Update `spike/bin/validate-config`'s copy line to the same sed render used by frigate-run (both `__SNAP_COMMON__` and `__SNAP__`). Its assertions must stay green.

- [ ] **Step 6 (GREEN): rebuild, reinstall, iterate.** First boot WILL likely surface denials (frame pipeline, stats /sys reads, detector init). For each: exact journal line → narrow labeled arm ONLY if expected-and-documented for the daemon, else fix the actual cause. OpenVINO GPU first-inference compiles the model (~tens of seconds) — the API/active checks tolerate this; boot failures land in `snap logs frigate.frigate` (accessible via `sudo journalctl`). Iterate to the Task-1..3 assertions green + full harness per the coral protocol. This is the task where the latitude gets real use — document every adaptation.

- [ ] **Step 7: Commit**

```bash
git add spike/ tests/spike-smoke.sh
git commit -m "m3: frigate daemon boots strict-confined - api answers, split db live"
```

---

### Task 4: DB rollback machinery (pre-refresh hook + downgrade-restore + harness proofs)

**Files:**
- Create: `spike/snap/hooks/pre-refresh` (executable)
- Modify: `spike/bin/frigate-run` (restore block), `tests/spike-smoke.sh`

**Interfaces:**
- Consumes: DB at `$SNAP_COMMON/db/frigate.db`, sidecar `.last-writer` (Task 3).
- Produces: backups at `$SNAP_COMMON/db/backups/frigate-pre-<revision>.db` (keep newest 2); restore-on-downgrade with the incompatible DB preserved as `frigate.db.incompatible-<ts>`; log lines `pre-refresh: backed up ...` and `frigate-run: DOWNGRADE detected ... restored ...` (the harness greps for these).

- [ ] **Step 1: create `spike/snap/hooks/pre-refresh`** (then `chmod +x`; snapcraft packages `snap/hooks/*` automatically):

```sh
#!/bin/sh
# Consistent DB snapshot before every refresh (sqlite backup API - the daemon may be mid-write).
set -e
DB="$SNAP_COMMON/db/frigate.db"
if [ ! -f "$DB" ]; then echo "pre-refresh: no db, nothing to back up"; exit 0; fi
mkdir -p "$SNAP_COMMON/db/backups"
DEST="$SNAP_COMMON/db/backups/frigate-pre-${SNAP_REVISION}.db"
"$SNAP/usr/bin/python3.11" - "$DB" "$DEST" <<'EOF'
import sqlite3, sys
src = sqlite3.connect(sys.argv[1])
dst = sqlite3.connect(sys.argv[2])
with dst:
    src.backup(dst)
dst.close(); src.close()
EOF
echo "pre-refresh: backed up $DB -> $DEST"
# retention: keep newest 2
ls -1t "$SNAP_COMMON/db/backups"/frigate-pre-*.db 2>/dev/null | tail -n +3 | xargs -r rm -f
```

- [ ] **Step 2: the restore block in `spike/bin/frigate-run`** — insert BETWEEN the wait-gate and the sidecar write (the sidecar write must remain AFTER restore so a restored start records the current version):

```sh
# Downgrade-restore: if the DB was last written by a NEWER frigate than this code,
# a migration may have advanced the schema - restore the newest backup instead.
SIDECAR="$SNAP_COMMON/db/.last-writer"
CUR_VERSION=$(sed -n 's/^VERSION *= *"\([^"+-]*\).*/\1/p' "$SNAP/opt/frigate/frigate/version.py" | head -1)
CUR_VERSION="${CUR_VERSION:-0.17.2}"
if [ -f "$SIDECAR" ]; then
    LAST_VERSION=$(awk '{print $1}' "$SIDECAR")
    NEWEST=$(printf '%s\n%s\n' "$LAST_VERSION" "$CUR_VERSION" | sort -V | tail -1)
    if [ "$NEWEST" = "$LAST_VERSION" ] && [ "$LAST_VERSION" != "$CUR_VERSION" ]; then
        echo "frigate-run: DOWNGRADE detected (db last written by $LAST_VERSION, code is $CUR_VERSION)"
        BACKUP=$(ls -1t "$SNAP_COMMON/db/backups"/frigate-pre-*.db 2>/dev/null | head -1)
        if [ -n "$BACKUP" ]; then
            TS=$(date +%s)
            mv "$SNAP_COMMON/db/frigate.db" "$SNAP_COMMON/db/frigate.db.incompatible-$TS" 2>/dev/null || true
            cp "$BACKUP" "$SNAP_COMMON/db/frigate.db"
            echo "frigate-run: restored $BACKUP (incompatible db preserved as frigate.db.incompatible-$TS)"
        else
            echo "frigate-run: WARNING no backup available - proceeding with the newer-schema db"
        fi
    fi
fi
```
(Move the existing `CUR_VERSION=` + sidecar-write lines so `CUR_VERSION` is computed once, above this block; sidecar write stays after it.)

- [ ] **Step 3 (RED then GREEN): harness proofs** above the denial-scan marker, placed AFTER the money-test section (Task 5 will sit between — leave a clear `# --- M3: rollback machinery (Task 4) ---` section; order within the file: frigate daemon checks, money-test checks, rollback checks):

```bash
# --- M3: rollback machinery (Task 4) ---
# Proof 1: refresh fires the pre-refresh hook -> backup exists.
snap install --dangerous "$SNAP_FILE" >/dev/null 2>&1 || fail_ "rollback: reinstall-refresh failed"
sleep 25   # services restart; frigate re-gates on go2rtc
check "rollback: pre-refresh backup created" sh -c "ls /var/snap/frigate/common/db/backups/frigate-pre-*.db"
check "rollback: hook logged" sh -c "journalctl --since \"$MARK\" | grep -q 'pre-refresh: backed up'"
# Proof 2: forged newer sidecar -> restore path fires on restart.
echo "99.0.0 x999" > /var/snap/frigate/common/db/.last-writer
snap restart frigate.frigate
sleep 20
check "rollback: downgrade detected + restored" sh -c "journalctl --since \"$MARK\" | grep -q 'frigate-run: restored'"
check "rollback: incompatible db preserved" sh -c "ls /var/snap/frigate/common/db/frigate.db.incompatible-*"
check "rollback: frigate healthy after restore" sh -c "snap services frigate.frigate | grep -q ' active'"
```
RED: run `--skip-install` before implementing (hook absent → proofs fail). GREEN: rebuild, full harness. Note: the reinstall-refresh restarts every daemon mid-harness — this section MUST come after all assertions that depend on first-boot state, hence its position after Task 5's section (add yours below the money-test marker comment even though Task 5 lands later; leave the section comments in order: Task 3 / Task 5 placeholder comment / Task 4).

- [ ] **Step 4: Commit**

```bash
git add spike/ tests/spike-smoke.sh
git commit -m "m3: db rollback machinery - pre-refresh sqlite backup + downgrade restore, harness-proven"
```

---

### Task 5: Money-test harness (detection, GPU stats, recordings, cache peak, coral warm-up)

**Files:**
- Modify: `tests/spike-smoke.sh` only

**Interfaces:**
- Consumes: everything live (frigate detecting on the looped clip).
- Produces: `$EVIDENCE/frigate-events.json`, `$EVIDENCE/frigate-stats.json`, `$EVIDENCE/db-events.txt`, `$EVIDENCE/cache-peak.txt` — Task 6 cites all four.

- [ ] **Step 1: the section** — insert between the Task-3 and Task-4 sections (`# --- M3: money test (Task 5) ---`):

```bash
# --- M3: money test (Task 5) ---
# Detection: poll the events API up to ~90s (first boot includes OpenVINO GPU model compile).
DETECTED=""
CACHE_PEAK=0
for i in $(seq 1 18); do
  curl -sf --max-time 5 "http://127.0.0.1:5001/api/events?labels=person,car&limit=5" \
    > "$EVIDENCE/frigate-events.json" 2>/dev/null || true
  if jq -e 'length > 0' "$EVIDENCE/frigate-events.json" >/dev/null 2>&1; then DETECTED=yes; fi
  # cache peak sampling (RAM-backed private tmp) - evidence for multi-camera headroom math
  C=$(du -sk /tmp/snap-private-tmp/snap.frigate/tmp/cache 2>/dev/null | awk '{print $1}')
  [ -n "$C" ] && [ "$C" -gt "$CACHE_PEAK" ] && CACHE_PEAK=$C
  [ -n "$DETECTED" ] && [ "$i" -gt 6 ] && break   # keep sampling a bit even after first hit
  sleep 5
done
echo "$CACHE_PEAK KiB peak" > "$EVIDENCE/cache-peak.txt"
check "MONEY TEST: real objects detected (events API)" test "$DETECTED" = "yes"
check "detection: labels are person/car with scores" sh -c "jq -e '.[0].label as \$l | ([\"person\",\"car\"] | index(\$l)) != null and .[0].data.score > 0.4' \"$EVIDENCE/frigate-events.json\""
# DB corroboration (also proves the split path is live)
sqlite3 /var/snap/frigate/common/db/frigate.db 'SELECT id,label,camera FROM event LIMIT 5;' > "$EVIDENCE/db-events.txt" 2>/dev/null || \
  python3 -c "import sqlite3,sys; c=sqlite3.connect('/var/snap/frigate/common/db/frigate.db'); print(*c.execute('SELECT id,label,camera FROM event LIMIT 5'),sep='\n')" > "$EVIDENCE/db-events.txt" 2>/dev/null || true
check "detection: corroborated in split db" test -s "$EVIDENCE/db-events.txt"
# GPU evidence via frigate's own stats
curl -sf --max-time 5 http://127.0.0.1:5001/api/stats > "$EVIDENCE/frigate-stats.json" 2>/dev/null || true
check "gpu: openvino detector reporting in stats" sh -c "jq -e '.detectors.ov.inference_speed != null' \"$EVIDENCE/frigate-stats.json\""
echo "  gpu finding: ov inference_speed=$(jq -r '.detectors.ov.inference_speed' "$EVIDENCE/frigate-stats.json" 2>/dev/null)ms"
# Recordings on disk
check "recordings: files under SNAP_COMMON" sh -c "find /var/snap/frigate/common/media/frigate/recordings -name '*.mp4' 2>/dev/null | head -1 | grep -q mp4"
```
(Host `sqlite3` may be absent — the python3 fallback line covers it; host python3 exists. Table name `event` per Frigate's peewee models — verify against the actual schema via `.tables`/sqlite_master and adjust with the real name quoted in your report if it differs.)

- [ ] **Step 2: coral warm-up probe.** In the existing coral section, BEFORE `coral-usb-before.txt` capture, add:

```bash
# Warm-up: long-idle initialized Corals fail their first delegate touch (M2 finding) - absorb it.
snap run frigate.coral-probe >/dev/null 2>&1 || true
sleep 2
```

- [ ] **Step 3 (RED→GREEN):** `--skip-install` first (money-test checks fail until timing/paths verified against the live system — if the daemon has been running since Task 3, they may pass immediately: record that as GREEN). Then one full harness cycle. Iterate on the jq paths against the REAL events/stats JSON shapes (quote the real shapes in your report; adjusting paths to evidence shape is fine, weakening assertions is not).

- [ ] **Step 4: Commit**

```bash
git add tests/spike-smoke.sh
git commit -m "m3: money-test harness - detection/gpu/recordings/cache evidence + coral warm-up"
```

---

### Task 6: M3 findings document + final run

**Files:**
- Create: `docs/m3-findings.md`

- [ ] **Step 1: final full harness** (coral-conditional protocol):

```bash
sudo lsusb | grep -Ei '1a6e|18d1' && CORAL=present || CORAL=absent
sudo ./tests/spike-smoke.sh 2>&1 | tee /tmp/m3f.txt && cp /tmp/m3f.txt spike/results/m3-final-run.txt
```

- [ ] **Step 2: write `docs/m3-findings.md`** (established style; verdicts cite evidence; no empty sections). Required sections: verdict table (daemon boot+API, detection-on-GPU with inference speed, events in split DB, recordings, rollback machinery both proofs, cache peak); denial arms added in M3 (each with its evidence); model provisioning mechanism record (what upstream does, what we mirror); test-clip provenance (license); decisions unlocked for M4 (nginx fronts :5001/:5002/:8082 + go2rtc :1984; readiness pattern reuse; anything the daemon's behavior teaches about proxying); deviations (incl. the intentional restart-condition divergence from upstream's halt-on-exit semantics); raw evidence index.

- [ ] **Step 3: Commit**

```bash
git add docs/m3-findings.md
git commit -m "m3: findings - daemon/detection/rollback verdicts"
```

---

## Self-Review (run after writing, fixed inline)

1. **Spec coverage:** §3.1 daemon (Task 3), §3.2 models (Task 1), §3.3 clip+camera (Tasks 2–3), §3.4 rollback (Task 4), §3.5 money test items 1–8 (Tasks 3/5/4/5/5/4/5/global), §3.6 findings (Task 6). Risk 5's divergence note lands in Task 6's deviations. No gaps.
2. **Placeholder scan:** `<URL-/SHA256-FROM-STEP-1>`, `<model-file-per-task-1>`, `<clip-width/height>` are explicit cross-task discovery outputs with commit-must-contain-real-values rules; findings `<>` cells are deliverable fill-ins. One deliberate in-plan correction note (the non-ASCII comment in Task 3's wrapper heredoc) instructs the implementer to write plain ASCII. Clean otherwise.
3. **Type consistency:** paths (`$SNAP_COMMON/db/frigate.db`, `.last-writer`, `backups/frigate-pre-<rev>.db`, `frigate.db.incompatible-<ts>`) and log-line strings (`pre-refresh: backed up`, `frigate-run: restored`) match between Tasks 3, 4 and the harness greps; stream name `testclip` consistent across Tasks 2, 3, 5; evidence filenames consistent with Task 6's list; env contract identical to the Global Constraints block.
