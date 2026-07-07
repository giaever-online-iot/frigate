# M6 Coral-as-detector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the Coral USB TPU end-to-end as a Frigate object detector in the strict snap via a Coral gate phase (OpenVINO stays the shipped default), and ship the user-facing accelerator doc.

**Architecture:** Stage the EdgeTPU-compiled COCO model and give the frigate daemon USB access; the harness proves the Coral in a temporary config phase (swap detectors+model → restart → assert TPU init/inference/event → restore), because upstream v0.17.2 permits only one model geometry across all object detectors. Docs record the support matrix and the NVIDIA-classic decision.

**Tech Stack:** snapcraft 9 / core26 strict; Frigate v0.17.2 (stock `EdgeTpuTfl`); libedgetpu (already staged); bash harness (`tests/spike-smoke.sh`).

**Spec:** `docs/superpowers/specs/2026-07-07-m6-coral-detector-design.md` (amended: single-geometry constraint + Coral-phase re-ruling).

## Global Constraints

- **LXD single-builder rule:** exactly ONE `snapcraft pack` may run at any time, FOREGROUND-ONLY: single Bash call, timeout 600000 ms; if it times out, re-invoke and wait again. Background builds/monitors are BANNED.
- Full gate runs are also foreground-only: `sudo tests/spike-smoke.sh` in a single call, timeout 600000 ms.
- **No Frigate behavior patches** (0001-env-paths is the only permitted patch; do not add more).
- **ALL M0–M5 harness assertions preserved**; the gate must end ALL PASS (SKIPs only for the documented conditional reasons) with **0 unexpected AppArmor denials**. A new denial gets a narrow labeled arm in the single `grep -cvE` allowlist + a FINDING comment quoting the journal line — never a broad pattern.
- **Secrets:** the livecam URL must never appear in argv, committed files, or evidence. Never write rendered `config.yml` contents (which embed the URL) into `spike/results/` or echo them; transform config via files, not command substitution that could hit `set -x`/traces.
- All fetches sha256-pinned with immutable commit URLs.
- **NEVER commit** `.superpowers/` paths, task reports, or `spike/results/`. `git ls-files .superpowers/ spike/results/` must print nothing at every review.
- sudo works passwordless ONLY for `/usr/bin/snap`, `/usr/bin/journalctl`, `/usr/bin/lsusb`, and `tests/spike-smoke.sh`. Any other sudo hangs forever — never invoke it.
- Build convention: `cd spike && snapcraft pack` → newest `spike/frigate_*.snap` (the harness auto-picks it).
- Config path at runtime: `/var/snap/frigate/current/config/config.yml`. Frigate API direct port: `http://127.0.0.1:5001` with headers `Remote-User: admin` + `Remote-Role: admin`; routes are `/stats`, `/events`, `/version` (NO `/api` prefix on :5001).
- Discovery facts (v0.17.2 source, quoted in the spec): TPU init markers `Attempting to load TPU as usb` → `TPU found` (failure: `No EdgeTPU was detected`); `avg_inference_speed` initializes to `Value("d", 0.01)` → `/stats` reports exactly `10.0` until real inferences move it; per-detector `model:` blocks are discarded (`detector_config.model = None`), only `model_path` overrides the single global model block.

---

### Task 1: Snap surface — EdgeTPU COCO model, bird-model pin, daemon USB plugs

**Files:**
- Modify: `spike/snap/snapcraft.yaml` (parts `detector-models` ~line 328 and `coral-model` ~line 194; app `frigate` plugs line)

**Interfaces:**
- Consumes: existing `detector-models` part layout (`/opt/frigate/models/...`), existing snap-level plugs `raw-usb`/`hardware-observe` (declared by `coral-probe`, already connected by the harness install section).
- Produces: staged `/opt/frigate/models/edgetpu/edgetpu_model.tflite` (sha256 `4a2be2bb…`) and a frigate daemon that can open the TPU. Task 2's coral config block depends on that exact model path.

- [ ] **Step 1: Stage the EdgeTPU COCO model in the `detector-models` part**

In `spike/snap/snapcraft.yaml`, inside the `detector-models` part's `override-build`, directly after the CPU-tflite install block (after the `install -D -m 0644 "$CRAFT_PART_BUILD/cpu_model.tflite" ...` line) and before the COCO-labelmap block, insert:

```yaml
      # --- EdgeTPU COCO detection model (M6; pinned; same c21de44 commit as the CPU sibling) ---
      # ssdlite_mobiledet_coco_qat_postprocess_edgetpu: the EdgeTPU compilation of the CPU
      # fallback model above (same network, same COCO labelmap.txt).
      wget -qO "$CRAFT_PART_BUILD/edgetpu_model.tflite" \
        "https://github.com/google-coral/test_data/raw/c21de4450f88a20ac5968628d375787745932a5a/ssdlite_mobiledet_coco_qat_postprocess_edgetpu.tflite"
      echo "4a2be2bbb614e576d56dcb914fa52752bf0f13411512710d355d97faa1b35641  $CRAFT_PART_BUILD/edgetpu_model.tflite" | sha256sum -c -
      install -D -m 0644 "$CRAFT_PART_BUILD/edgetpu_model.tflite" \
        "$CRAFT_PART_INSTALL/opt/frigate/models/edgetpu/edgetpu_model.tflite"
```

Indentation: match the surrounding `override-build` script lines (6 spaces).

- [ ] **Step 2: Pin the bird probe model URL to an immutable commit**

In the `coral-model` part, replace the wget URL line:

```yaml
        https://github.com/google-coral/test_data/raw/master/mobilenet_v2_1.0_224_inat_bird_quant_edgetpu.tflite
```

with:

```yaml
        https://github.com/google-coral/test_data/raw/104342d2d3480b3e66203073dac24f4e2dbb4c41/mobilenet_v2_1.0_224_inat_bird_quant_edgetpu.tflite
```

and add this comment line directly above the `wget` line:

```yaml
      # M6: pinned to the immutable commit whose blob matches the sha below (master content
      # 2026-07-07). NOTE: c21de44 (the detection models' commit) serves DIFFERENT content
      # for this file (0400fbd9…) — do not "unify" the commits.
```

The existing `sha256sum -c` line (`5b468dfe…`) stays byte-identical — it is the content proof.

- [ ] **Step 3: Add USB plugs to the frigate daemon app**

In the `frigate` app, extend the plugs line:

```yaml
    plugs: [network, network-bind, opengl, shm-private, mount-observe]
```

to:

```yaml
    # raw-usb + hardware-observe (M6): libusb enumerate/open of the Coral USB TPU —
    # the M0 coral-probe precedent (same two plugs). Manual-connect; harness install
    # section already connects both at snap level.
    plugs: [network, network-bind, opengl, shm-private, mount-observe, raw-usb, hardware-observe]
```

- [ ] **Step 4: Build the snap (FOREGROUND, single builder)**

Run (single Bash call, timeout 600000):
```bash
cd spike && snapcraft pack
```
Expected: ends with `Packed frigate_0.0.1-spike_amd64.snap` (warnings about interfaces are normal). On timeout: re-invoke and wait; never background.

- [ ] **Step 5: Verify the staged artifacts in the built snap**

```bash
cd /home/joachimmgg/Development/giaever-online-iot/frigate/spike
unsquashfs -cat "$(ls -t frigate_*.snap | head -1)" opt/frigate/models/edgetpu/edgetpu_model.tflite | sha256sum
unsquashfs -cat "$(ls -t frigate_*.snap | head -1)" models/edgetpu-test.tflite | sha256sum
```
Expected: `4a2be2bbb614e576d56dcb914fa52752bf0f13411512710d355d97faa1b35641` and `5b468dfe63ce4d79056bb19b953529e25df0a8d841b204c626576a1b8bd36afe` respectively (paths inside the squashfs have no leading slash; if `unsquashfs -cat` is unavailable use `unsquashfs -d /tmp/m6chk ... <paths>` then hash + `rm -rf /tmp/m6chk`).

- [ ] **Step 6: Boot-verify with the new plugs (no full gate yet — that is Task 2)**

```bash
sudo snap install --dangerous "$(ls -t spike/frigate_*.snap | head -1)"
sudo snap connect frigate:gpu-2604 mesa-2604:gpu-2604 || true
sudo snap connect frigate:mount-observe || true
sudo snap connect frigate:raw-usb || true
sudo snap connect frigate:hardware-observe || true
sudo snap connect frigate:shm-private snapd:shared-memory || true
sleep 45
snap services frigate.frigate | grep ' active'
curl -sf --max-time 5 http://127.0.0.1:5001/version
snap connections frigate | grep -E 'raw-usb|hardware-observe'
```
Expected: frigate active; a version string; both connections listed (plugged by the frigate snap). The daemon still runs the OpenVINO default — no coral config exists yet; the point is that the new plugs don't regress boot.

- [ ] **Step 7: Commit**

```bash
git add spike/snap/snapcraft.yaml
git commit -m "m6: stage EdgeTPU COCO model, pin bird probe model, add USB plugs to frigate daemon"
```

---

### Task 2: Harness Coral phase + full gate

**Files:**
- Modify: `tests/spike-smoke.sh` (insert the M6 phase between the M3 rollback block — ends with `check "rollback: frigate healthy after restore" ...` — and the `# --- AppArmor denial scan (keep last) ---` section; plus one line in the EXIT-trap area)

**Interfaces:**
- Consumes: Task 1's staged model at `/opt/frigate/models/edgetpu/edgetpu_model.tflite`; harness helpers `check`/`pass_`/`fail_` (note: `check` always returns 0 — never use it in `&&` chains or if-conditions); `$SNAP_NAME`, `$EVIDENCE`, `$MARK`; the config template's fixed block order `detectors:` → `model:` → `cameras:`.
- Produces: the M6 gate assertions the findings doc (Task 4) cites.

- [ ] **Step 1: Add the restore hook to the existing EXIT-trap machinery**

The harness has an EXIT trap for livecam-stash restore-or-preserve. Locate it (grep `trap` near the top) and add config-restore lines to it (idempotent — `CORAL_CFG_BAK` is empty unless the phase is mid-flight):

```bash
  # M6: if the Coral phase died mid-swap, put the OpenVINO default back (idempotent).
  if [ -n "${CORAL_CFG_BAK:-}" ] && [ -f "${CORAL_CFG_BAK:-}" ]; then
    cp -p "$CORAL_CFG_BAK" "/var/snap/$SNAP_NAME/current/config/config.yml" 2>/dev/null || true
    rm -f "$CORAL_CFG_BAK"
    snap restart $SNAP_NAME.frigate 2>/dev/null || true
  fi
```

Also initialize `CORAL_CFG_BAK=""` near the other globals at the top of the script (before the trap can fire).

- [ ] **Step 2: Insert the M6 Coral phase**

Insert between the rollback block and the denial scan:

```bash
# --- M6: Coral detector phase (spec §3.4) ---
# Upstream v0.17.2 supports ONE model geometry across all object detectors
# (config.py: per-detector model: is discarded — "users should not set model
# themselves"; only model_path overrides the single global model block). So the
# Coral proof is a phase: swap detectors+model to edgetpu, restart, assert,
# restore. Shipped default stays OpenVINO (USER re-ruling, spec §2).
CORAL_CFG=/var/snap/$SNAP_NAME/current/config/config.yml
if lsusb 2>/dev/null | grep -qEi '1a6e:089a|18d1:9302'; then
  MARK_CORAL=$(date '+%Y-%m-%d %H:%M:%S')
  CORAL_CFG_BAK="/var/snap/$SNAP_NAME/current/config/.config.yml.pre-coral"
  cp -p "$CORAL_CFG" "$CORAL_CFG_BAK"
  # Render the coral config by transforming the RENDERED file (preserves the
  # livecam block + credential; template block order is detectors: -> model: ->
  # cameras:, so the replace region is [^detectors:, ^cameras:) ). Never echo
  # config contents (credential embedded).
  awk '
    /^detectors:/ {skip=1
      print "detectors:"
      print "  coral:"
      print "    type: edgetpu"
      print "    device: usb"
      print "model:"
      print "  # M6 Coral phase: EdgeTPU compilation of the CPU-fallback network (c21de44)"
      print "  path: /opt/frigate/models/edgetpu/edgetpu_model.tflite"
      print "  labelmap_path: /opt/frigate/models/labelmap.txt"
      print "  width: 320"
      print "  height: 320"
      print "  input_tensor: nhwc"
      print "  input_pixel_format: rgb"
      print "  model_type: ssd"
      next}
    /^cameras:/ {skip=0}
    skip!=1 {print}
  ' "$CORAL_CFG_BAK" > "$CORAL_CFG"
  snap restart $SNAP_NAME.frigate
  CORAL_UP=""
  for i in $(seq 1 24); do
    sleep 5
    curl -sf --max-time 5 http://127.0.0.1:5001/version >/dev/null 2>&1 && { CORAL_UP=yes; break; }
  done
  # M0 re-enumeration protocol: one bounded rerun if the TPU regressed to 1a6e
  # (delegate load uploads firmware; a mid-phase replug would need it again).
  if ! journalctl -u snap.frigate.frigate --since "$MARK_CORAL" 2>/dev/null | grep -q 'TPU found'; then
    if lsusb 2>/dev/null | grep -qi '1a6e:089a'; then
      snap run $SNAP_NAME.coral-probe >/dev/null 2>&1 || true
      snap restart $SNAP_NAME.frigate
      for i in $(seq 1 24); do
        sleep 5
        curl -sf --max-time 5 http://127.0.0.1:5001/version >/dev/null 2>&1 && { CORAL_UP=yes; break; }
      done
    fi
  fi
  check "coral phase: API back up on coral config" test "$CORAL_UP" = "yes"
  journalctl -u snap.frigate.frigate --since "$MARK_CORAL" 2>/dev/null \
    | grep -E 'Attempting to load TPU|TPU found|No EdgeTPU was detected' \
    > "$EVIDENCE/coral-phase-journal.txt" || true
  check "coral phase: journal 'Attempting to load TPU as usb'" grep -q 'Attempting to load TPU as usb' "$EVIDENCE/coral-phase-journal.txt"
  check "coral phase: journal 'TPU found' (delegate loaded)" grep -q 'TPU found' "$EVIDENCE/coral-phase-journal.txt"
  # inference_speed init default is EXACTLY 10.0 (v0.17.2 base.py: Value("d", 0.01)
  # -> stats x1000) until real inferences move the average. Poll up to 120s for
  # drift; testclip's constant frame flow drives the detector even though it can
  # never create events (M3 finding).
  CORAL_SPEED=""
  for i in $(seq 1 24); do
    curl -sf --max-time 5 -H "Remote-User: admin" -H "Remote-Role: admin" \
      http://127.0.0.1:5001/stats > "$EVIDENCE/coral-phase-stats.json" 2>/dev/null || true
    if jq -e '.detectors.coral.pid > 0 and .detectors.coral.inference_speed != 10.0 and .detectors.coral.inference_speed > 0 and .detectors.coral.inference_speed < 100' \
        "$EVIDENCE/coral-phase-stats.json" >/dev/null 2>&1; then
      CORAL_SPEED=$(jq -r '.detectors.coral.inference_speed' "$EVIDENCE/coral-phase-stats.json")
      break
    fi
    sleep 5
  done
  check "coral phase MONEY: coral detector alive + inference_speed moved off 10.0 init default" test -n "$CORAL_SPEED"
  echo "  coral finding: inference_speed=${CORAL_SPEED:-none}ms (init default 10.0 exactly; drift = real TPU inferences)"
  # Detection event on the Coral — livecam machinery, standing scene-dependent
  # SKIP semantics (armed + pipeline alive + no event = scene, not packaging).
  if [ "$LIVECAM" = "yes" ]; then
    CORAL_DETECTED=""
    for i in $(seq 1 18); do
      curl -sf --max-time 5 -H "Remote-User: admin" -H "Remote-Role: admin" \
        "http://127.0.0.1:5001/events?cameras=livecam&labels=person&after=$(date -d "$MARK_CORAL" +%s)&limit=5" \
        > "$EVIDENCE/coral-phase-events.json" 2>/dev/null || true
      jq -e 'length > 0' "$EVIDENCE/coral-phase-events.json" >/dev/null 2>&1 && { CORAL_DETECTED=yes; break; }
      sleep 5
    done
    curl -sf --max-time 5 -H "Remote-User: admin" -H "Remote-Role: admin" \
      http://127.0.0.1:5001/stats > "$EVIDENCE/coral-phase-stats2.json" 2>/dev/null || true
    CORAL_PIPE=""
    jq -e '.cameras.livecam.ffmpeg_pid > 0' "$EVIDENCE/coral-phase-stats2.json" >/dev/null 2>&1 && CORAL_PIPE=yes
    if [ "$CORAL_DETECTED" = "yes" ]; then
      check "coral phase: person event detected BY THE TPU (coral-only pool)" test "$CORAL_DETECTED" = "yes"
    elif [ "$CORAL_PIPE" = "yes" ]; then
      echo "SKIP: coral phase: person event detected BY THE TPU — pipeline alive, no subject in frame (scene-dependent)"
    else
      fail_ "coral phase: person event detected BY THE TPU — pipeline dead on coral config (packaging regression)"
    fi
  else
    echo "SKIP: coral phase: person event detected BY THE TPU — $LIVECAM_SKIP_REASON"
  fi
  # Restore the OpenVINO default and prove steady state returns.
  cp -p "$CORAL_CFG_BAK" "$CORAL_CFG"
  rm -f "$CORAL_CFG_BAK"; CORAL_CFG_BAK=""
  snap restart $SNAP_NAME.frigate
  OV_BACK=""
  for i in $(seq 1 24); do
    sleep 5
    curl -sf --max-time 5 -H "Remote-User: admin" -H "Remote-Role: admin" \
      http://127.0.0.1:5001/stats 2>/dev/null | jq -e '.detectors.ov' >/dev/null 2>&1 && { OV_BACK=yes; break; }
  done
  check "coral phase: OpenVINO default restored (ov reporting in /stats)" test "$OV_BACK" = "yes"
else
  echo "SKIP: coral phase: API back up on coral config — no Coral USB attached (1a6e/18d1 absent)"
  echo "SKIP: coral phase: journal markers — no Coral USB attached"
  echo "SKIP: coral phase MONEY: inference_speed drift — no Coral USB attached"
  echo "SKIP: coral phase: person event — no Coral USB attached"
  echo "SKIP: coral phase: OpenVINO default restored — no Coral USB attached"
fi
```

Adapt the insertion to the file's real local idioms where they differ (e.g. exact trap shape, `$MARK` usage); the assertion set and ordering above are the requirement. `lsusb` is on the passwordless-sudo list but works unprivileged for listing — call it WITHOUT sudo, as the existing warm-up section does (verify and mirror).

- [ ] **Step 3: Syntax-check the harness**

```bash
bash -n tests/spike-smoke.sh
```
Expected: no output.

- [ ] **Step 4: Full gate run (FOREGROUND)**

Single Bash call, timeout 600000:
```bash
sudo tests/spike-smoke.sh 2>&1 | tail -60
```
Expected: all PASS; SKIPs only for documented conditional reasons (livecam scene, etc. — the Coral IS attached, so coral-phase hard assertions must PASS); final denial line reports `0 unexpected`. If a NEW denial appears: triage it, quote the journal line in a FINDING comment, add a narrow labeled arm to the single `grep -cvE` allowlist, and re-run the full gate.

- [ ] **Step 5: Commit**

```bash
git add tests/spike-smoke.sh
git commit -m "m6: harness Coral detector phase — config swap, TPU init proof, inference drift, restore"
```

---

### Task 3: User-facing accelerator doc

**Files:**
- Create: `docs/accelerator-support.md`

**Interfaces:**
- Consumes: spec §3.5 content list; interface facts from `spike/snap/snapcraft.yaml` and M0 findings. No code dependencies — safe to run in parallel with Tasks 1–2 (touches only this new file).
- Produces: the doc `docs/m6-findings.md` (Task 4) links to; M7 Store-listing seed.

- [ ] **Step 1: Write `docs/accelerator-support.md`**

Sections (write full prose, concise operator tone; this is user-facing, not findings-style):

1. **Title + intro**: what the snap supports for object detection acceleration; one paragraph.
2. **Support matrix** (table): CPU (works out of the box, slow — not recommended for >1 camera); Intel/AMD iGPU via OpenVINO/VAAPI (the shipped default config; needs the gpu content interface — auto-wired on install from the Store); Coral USB (supported; manual connects; config swap required); Coral PCIe/M.2 (`/dev/apex_0`) — NOT supported under strict confinement (no snapd interface exists for the apex device class); Intel NPU — not yet productized (tracked for a later release); NVIDIA — see its section.
3. **Coral USB setup**: the two manual connects:
   ```
   sudo snap connect frigate:raw-usb
   sudo snap connect frigate:hardware-observe
   ```
   then the config change — replace the `detectors:` and `model:` blocks in `/var/snap/frigate/current/config/config.yml` with:
   ```yaml
   detectors:
     coral:
       type: edgetpu
       device: usb
   model:
     path: /opt/frigate/models/edgetpu/edgetpu_model.tflite
     labelmap_path: /opt/frigate/models/labelmap.txt
     width: 320
     height: 320
     input_tensor: nhwc
     input_pixel_format: rgb
     model_type: ssd
   ```
   and `sudo snap restart frigate.frigate`. Note the first start after plugging the stick uploads firmware (the device re-enumerates from ID `1a6e:089a` to `18d1:9302`); if the detector fails on the very first boot, restart once.
4. **One detector type at a time**: Frigate v0.17.x applies a single global model configuration to all object detectors — different detector types with different model geometries (e.g. Coral + OpenVINO) cannot share the detection pool. Choose one; enrichments are unaffected.
5. **NVIDIA**: strict confinement cannot ship or reach the proprietary NVIDIA userspace the way it works for Mesa-based GPUs (host-driver/library coupling; CUDA/TensorRT stacks), so this snap does not support NVIDIA detection or NVDEC. NVIDIA users should run upstream Frigate's Docker image; a classic-confinement variant may be evaluated later.
6. **Verification note**: point at `docs/m6-findings.md` for the evidence trail (do not duplicate numbers — link only, the findings doc lands in the same milestone).

- [ ] **Step 2: Self-check**

Cross-check every interface name and path against `spike/snap/snapcraft.yaml` (plugs: `raw-usb`, `hardware-observe`, `gpu-2604` content, `shm-private`, `mount-observe`, `network`, `network-bind`) — no invented interface names; model paths byte-identical to Task 1's staged paths.

- [ ] **Step 3: Commit**

```bash
git add docs/accelerator-support.md
git commit -m "m6: accelerator support doc — matrix, Coral setup, one-detector-type constraint, NVIDIA decision"
```

---

### Task 4: Findings doc + final gate evidence

**Files:**
- Create: `docs/m6-findings.md`

**Interfaces:**
- Consumes: the FINAL full-gate transcript (run fresh in this task — the authoritative run), `$EVIDENCE/coral-phase-*.{txt,json}`, the spec's discovery quotes, Tasks 1–3 commits.
- Produces: the closed milestone record.

- [ ] **Step 1: Run the final full gate (FOREGROUND) and capture the transcript**

Single Bash call, timeout 600000:
```bash
sudo tests/spike-smoke.sh > spike/results/m6-final-run.txt 2>&1; tail -30 spike/results/m6-final-run.txt
```
Expected: ALL PASS, coral-phase hard assertions PASS, 0 unexpected denials. This transcript is the ONLY source for every number cited in the findings (provenance discipline: grep each number against this file before writing it).

- [ ] **Step 2: Write `docs/m6-findings.md`** in the M0–M5 house style:

1. **Verdict table**: coral-phase API-up, TPU markers, inference_speed value (quote the actual ms), event-or-SKIP (with reason), restore proof, PASS/FAIL/SKIP totals, denial totals (total / unexpected).
2. **Discovery records** (each with the source quote): single-geometry constraint (`config.py`: `detector_config.model = None` block); `inference_speed` 10.0 init default (`Value("d", 0.01)`); TPU log markers (`EdgeTpuTfl.__init__`); bird-model content mismatch (c21de44 = `0400fbd9…` ≠ pinned `5b468dfe…` = commit `104342d2…`).
3. **Deviations**: the §2 re-ruling (alongside → phase), with the user decision recorded.
4. **M7 unlocks/notes**: bird-model mutable-URL note RETIRED; new note — a snap-set option to select the detector (ov/coral/cpu) at install time would remove the manual config swap; NPU productization still queued.
5. **Raw evidence index**: local paths only. Verify `git ls-files .superpowers/ spike/results/` prints nothing.
6. Every number grep-verified against `spike/results/m6-final-run.txt` (the authoritative transcript).

- [ ] **Step 3: Commit**

```bash
git add docs/m6-findings.md
git commit -m "m6: findings — Coral phase proof, single-geometry discovery, deviations"
```

---

## Execution notes (controller)

- Task order: Task 1 → Task 2 → Task 4; Task 3 is file-disjoint and runs in parallel (worktree isolation) from the start. Reviews pipeline: dispatch each task's review while the next implementer runs — but NEVER two builds/gates concurrently (LXD single-builder + single snap install target).
- Tasks 1, 2 and 4 each run builds and/or gates on the HOST snap — they must serialize.
- Final whole-branch review after all tasks, against spec + this plan; one fix subagent for the complete findings list; findings doc numbers re-verified after any fix that reruns the gate.
