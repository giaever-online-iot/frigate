#!/usr/bin/env bash
# M0 spike smoke harness. Run as root: sudo tests/spike-smoke.sh [--skip-install | --nvr-safe | --provision-livecam]
set -uo pipefail
cd "$(dirname "$0")/.."
SNAP_NAME=frigate
# M7 Task 4: project root is now the snapcraft project (snap/snapcraft.yaml at root);
# `snapcraft pack` at root produces ./frigate_*.snap. Root-first, but tolerate old
# spike/frigate_*.snap artifacts and Task 1's remote-built spike/frigate-remote_amd64.snap
# (frigate*_*.snap matches both frigate_<ver>_<arch>.snap and frigate-remote_<arch>.snap).
# M8 Task 6 (T7 footgun fix): resolve the artifact identity ONCE, up front, and PIN it (path + sha256)
# for the whole gate — the rollback-reinstall step reuses THIS exact pinned file, never a fresh `ls -t`
# that could silently swap in a stale build mid-gate (the Task 7 VM incident: a stale pre-M8 artifact
# left in the checkout got installed by the rollback step). Ambiguity is FATAL: two DIFFERING repo-root
# frigate*_*.snap artifacts mean a stale .snap was left behind — fail loudly so nothing picks the wrong
# one. spike/frigate*_*.snap (frigate_0.0.1-spike, frigate-remote — M7 evidence) is the documented
# FALLBACK only when the repo root has none; it is NOT part of the ambiguity set.
ROOT_SNAPS=$(ls -1 frigate*_*.snap 2>/dev/null)
if [ "$(printf '%s\n' "$ROOT_SNAPS" | grep -c .)" -gt 1 ]; then
  if [ "$(for f in $ROOT_SNAPS; do sha256sum "$f"; done | awk '{print $1}' | sort -u | wc -l)" -gt 1 ]; then
    echo "ERROR: ambiguous artifact set — clean stale .snap files (repo root has multiple DIFFERING frigate*_*.snap):"
    printf '%s\n' "$ROOT_SNAPS" | sed 's/^/  /'
    exit 1
  fi
fi
SNAP_FILE=$(ls -t frigate*_*.snap spike/frigate*_*.snap 2>/dev/null | head -1)
SNAP_FILE_SHA=""
if [ -n "$SNAP_FILE" ]; then
  SNAP_FILE_SHA=$(sha256sum "$SNAP_FILE" 2>/dev/null | awk '{print $1}')
  echo "ARTIFACT: pinned $SNAP_FILE (sha256=$SNAP_FILE_SHA) — rollback reinstall reuses this exact file"
fi
# --nvr-safe: read-only mode for production hosts (M8 B1). Runs ONLY observation
# assertions (status, curls, journal, sha256) and proves its own harmlessness.
# Everything that installs, purges, restarts, sets, forges, or overwrites is skipped
# with an explicit "SKIP (nvr-safe):" line. Mutually exclusive with other modes.
# FUTURE EDITORS: any NEW mutating phase (install/purge/remove/set/unset/forge/overwrite/
# restart/cert-swap) MUST be gated `if [ "${NVR_SAFE:-0}" -eq 0 ]; then <phase>; else
# echo "SKIP (nvr-safe): <phase>"; fi` — otherwise it runs against the live production NVR.
NVR_SAFE=0
[ "${1:-}" = "--nvr-safe" ] && NVR_SAFE=1
# Harmlessness baseline (M8 B1): sha of config.yml + TLS cert + service start-timestamps
# captured BEFORE any gate runs; re-checked at end-of-run (Step 4) to prove --nvr-safe
# mutated nothing. DB checksum is deliberately NOT captured — a live NVR's DB is written
# continuously by frigate itself, so it can never hold (see task report finding).
if [ "$NVR_SAFE" -eq 1 ]; then
  NVRSAFE_CFG="/var/snap/$SNAP_NAME/current/config/config.yml"
  NVRSAFE_CFG_SHA_PRE=$(sha256sum "$NVRSAFE_CFG" 2>/dev/null | awk '{print $1}')
  NVRSAFE_CERT_SHA_PRE=$(sha256sum "/var/snap/$SNAP_NAME/current/letsencrypt/live/frigate/fullchain.pem" 2>/dev/null | awk '{print $1}')
  NVRSAFE_STAMPS_PRE=$(for s in go2rtc frigate nginx certsync; do
    systemctl show "snap.$SNAP_NAME.$s.service" -p ActiveEnterTimestamp --value; done)
fi
RESULTS=/var/snap/$SNAP_NAME/common/spike-results
EVIDENCE=spike/results
FAIL=0
# M6: backup path of the pre-Coral (OpenVINO default) rendered config; empty unless the Coral
# phase is mid-swap. Initialized here so the EXIT trap's restore hook can reference it safely.
CORAL_CFG_BAK=""
# PR#3: operator config.yml protection. OPERATOR_CFG_STASH holds a root-0600 copy of the operator's
# config.yml across the purge/reinstall cycle (mirrors LIVECAM_STASH) — the purge regenerates config
# from the template and would otherwise DESTROY the operator's hand-added cameras. OPERATOR_CFG_SHA
# records its sha256 for the end-of-run survival check (proves it returned byte-identical, contents
# never printed). BRIDGE_CFG_BAK is the bridge test's own backup while it injects the bridgeproof
# stream. All three declared here so the EXIT trap's restore hooks can reference them safely.
OPERATOR_CFG_STASH=""
OPERATOR_CFG_SHA=""
BRIDGE_CFG_BAK=""
# M8 (R4): the semantic-search proof's own backup while it injects semantic_search.enabled into
# the operator config; the EXIT trap restores from it if the proof dies mid-flight.
M8_SEM_CFG_BAK=""
mkdir -p "$EVIDENCE"
# Evidence dir is created by the root harness but must stay writable by the invoking user
# (agents capture run transcripts here). chown to SUDO_USER when run via sudo.
[ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER" "$EVIDENCE" 2>/dev/null || true

pass_() { echo "PASS: $1"; }
fail_() { echo "FAIL: $1"; FAIL=1; }
# Note: check() always returns 0; failures accumulate in $FAIL. Do not use in && chains or if-conditions.
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass_ "$d"; else fail_ "$d"; fi; }
jqr()   { jq -r "$2" "$RESULTS/$1.json" 2>/dev/null; }
# M8 Task 6: hardware/env capability probe for the HARDWARE-AWARE full gate. Each hardware- or
# environment-dependent assertion runs UNTOUCHED when its capability is present (host full gates lose
# NO coverage) and SKIPs with an explicit reason NAMING the missing capability when absent (headless
# VM: no iGPU/TPU/renderD/livecam). Mirrors the existing lsusb-Coral-phase guard; never a blanket
# "is this a VM" gate. GPU/vaapi/openvino/auto-detect-ov guards key off a real Intel/AMD render node.
render_node_present() {  # Intel(0x8086)/AMD(0x1002) DRM render node under /sys/class/drm
  for _v in /sys/class/drm/renderD*/device/vendor; do
    [ -r "$_v" ] && grep -qiE '0x8086|0x1002' "$_v" 2>/dev/null && return 0
  done
  return 1
}
if render_node_present; then RENDER_NODE=yes; else RENDER_NODE=no; fi
RENDER_NODE_REASON="no Intel(0x8086)/AMD(0x1002) render node under /sys/class/drm/renderD* (headless VM: virtio-gpu)"
# PR#3 review (credential hygiene, layer 2 of 2): go2rtc /api/streams and frigate /stats emit
# source URLs verbatim — an operator's REAL camera credentials leaked into evidence JSON. Layer 1
# minimizes at capture (names-only streams list, del(.cpu_usages) on /stats, producer url strip);
# this layer redacts ALL URL userinfo (user:pass@) across $EVIDENCE regardless of which writer
# produced it. Called at end-of-run AND from the EXIT trap so aborted runs are covered. -I skips
# binaries; the fixed-string $LIVECAM_URL scrub at end-of-run is kept as defense in depth.
scrub_evidence() {
  grep -rlEI '(rtsps?|rtmp|https?)://[^@/[:space:]]+@' "$EVIDENCE" 2>/dev/null | while IFS= read -r f; do
    sed -i -E 's#(rtsps?|rtmp|https?)://[^@/[:space:]]+@#\1://REDACTED@#g' "$f"
  done
}

command -v jq >/dev/null || { echo "jq required: sudo apt install -y jq"; exit 1; }

# m7: snap size floor — silent prime-gutting tripwire (controller addition, 2026-07-08). SNAP_FILE
# was resolved+pinned above; a chosen artifact under the floor means the prime was gutted (a mid-
# write artifact read, or a silent pack failure) — catch it HERE, before anything installs it. The
# earlier check() helpers are needed, so this rides just below their definition rather than at the
# resolution line. Guarded on a non-empty SNAP_FILE (a bare --skip-install with no local artifact
# leaves it empty; the size floor simply does not apply in that case).
# M8 Task 6: retuned after the prime-prune size pass (was 943718400 = 900 MiB; lean artifact =
# 989880320 bytes). New floor = 85% of the lean artifact, floored to a whole MiB = 802 MiB =
# 840957952 bytes — still comfortably catches a gutted prime while tracking the leaner artifact.
if [ -n "$SNAP_FILE" ]; then
  SNAP_SZ=$(stat -c %s "$SNAP_FILE" 2>/dev/null || echo 0)
  check "m8: snap size floor (>=802 MiB, prime not gutted)" sh -c "[ '$SNAP_SZ' -ge 840957952 ]"
  echo "  m8 finding: chosen snap=$SNAP_FILE size=${SNAP_SZ} bytes (floor 840957952 = 802 MiB; was 943718400)"
fi

# Operator provisioning for the live camera (see spike/config/frigate-config.yml LIVECAM block).
# URL arrives on STDIN (never argv - visible in ps) and is written root-owned 0600:
#   printf '%s' 'rtsp://user:pass@host:554/path' | sudo tests/spike-smoke.sh --provision-livecam
# NOTE (M6 final review): --skip-install runs never re-render config.yml (render-once semantics —
# frigate-run only renders on first start). A livecam provisioned AFTER config.yml was first
# rendered needs a full run (no --skip-install) — or delete config.yml and restart frigate —
# before the live-camera money test is armed.
if [ "${1:-}" = "--provision-livecam" ]; then
  mkdir -p "/var/snap/$SNAP_NAME/common"
  umask 077
  head -1 > "/var/snap/$SNAP_NAME/common/livecam-url"
  chown root:root "/var/snap/$SNAP_NAME/common/livecam-url"
  chmod 600 "/var/snap/$SNAP_NAME/common/livecam-url"
  echo "livecam-url provisioned (root 0600); next harness run arms the live-camera money test"
  exit 0
fi

# Self-healing: if a prior aborted run couldn't restore the livecam secret (snap was gone at
# EXIT trap time), it was moved to a deterministic stash path. Recover it now if the snap is
# installed and the credential is missing — no content echoed, just the path.
# M8 T1 review (Important): NVR_SAFE-gated — a read-only run has no business self-healing
# (install+rm host mutations, and this path sits outside the harmlessness proof's baseline).
if [ "$NVR_SAFE" -eq 0 ] && \
   [ -f "/var/tmp/frigate-livecam-url.stash" ] && \
   [ ! -f "/var/snap/$SNAP_NAME/common/livecam-url" ] && \
   [ -d "/var/snap/$SNAP_NAME/common" ]; then
  echo "RECOVER: restoring livecam secret from /var/tmp/frigate-livecam-url.stash"
  install -m 0600 -o root -g root /var/tmp/frigate-livecam-url.stash \
    "/var/snap/$SNAP_NAME/common/livecam-url" && rm -f /var/tmp/frigate-livecam-url.stash
fi

# PR#3 self-healing (narrow path): if a prior run aborted with the snap absent, the EXIT trap
# parked the operator's config.yml at a deterministic path. Recover it here ONLY when config.yml
# is genuinely missing (covers --skip-install runs, which never reach the install step). This
# guard deliberately does NOT overwrite an existing config.yml — at top-of-run an existing file
# may be newer operator work. The AUTHORITATIVE recovery is the post-install restore step, where
# the /var/tmp stash wins over the fresh template render (review fix; see the install section).
# rm only after the copy verifiably landed. Never echo contents.
# M8 T1 review (Important): NVR_SAFE-gated — a read-only run has no business self-healing.
if [ "$NVR_SAFE" -eq 0 ] && \
   [ -f "/var/tmp/frigate-operator-config.stash" ] && \
   [ ! -f "/var/snap/$SNAP_NAME/current/config/config.yml" ] && \
   [ -d "/var/snap/$SNAP_NAME/current/config" ]; then
  echo "RECOVER: restoring operator config.yml from /var/tmp/frigate-operator-config.stash"
  install -m 0600 -o root -g root /var/tmp/frigate-operator-config.stash \
    "/var/snap/$SNAP_NAME/current/config/config.yml" && \
    cmp -s /var/tmp/frigate-operator-config.stash "/var/snap/$SNAP_NAME/current/config/config.yml" && \
    rm -f /var/tmp/frigate-operator-config.stash
fi

MARK=$(date '+%Y-%m-%d %H:%M:%S')
# Capture expanded snapcraft yaml (gpu extension evidence); project root is the snapcraft
# project since M7 Task 4 (snap/snapcraft.yaml), so this runs directly from repo root.
ABS_EVIDENCE="$(pwd)/$EVIDENCE"
snapcraft expand-extensions > "$ABS_EVIDENCE/expanded-snapcraft.yaml" 2>/dev/null || true

# Live camera secret ($SNAP_COMMON/livecam-url, provisioned once by the operator) must survive
# the purge/reinstall cycle: stash before remove, restore after install. Never echo its content.
# M4 Task 0 hardening: EXIT trap — on mid-run abort the root-0600 copy must not persist in /tmp.
LIVECAM_STASH=""
# EXIT trap: restore-or-preserve semantics — never destroy the operator's secret.
# If the stash exists and the target is gone: restore when snap is present, or move to a
# deterministic root-0600 path when snap is absent. Idempotent with the explicit restore below.
# M6 final review: hoisted above the --skip-install branch (along with LIVECAM_STASH="" above)
# so EVERY run registers this trap — --skip-install runs previously had no EXIT handler at all.
trap '
  if [ -n "${LIVECAM_STASH:-}" ] && [ -f "${LIVECAM_STASH}" ]; then
    if [ ! -f "/var/snap/$SNAP_NAME/common/livecam-url" ]; then
      if [ -d "/var/snap/$SNAP_NAME/common" ]; then
        install -m 0600 -o root -g root "$LIVECAM_STASH" "/var/snap/$SNAP_NAME/common/livecam-url" && rm -f "$LIVECAM_STASH"
      else
        # oldest-wins: run 2'\''s stash may be a template render; the parked file is the real livecam secret (PR#3 review, M8 B2)
        if [ -e /var/tmp/frigate-livecam-url.stash ]; then
          echo "STASH: /var/tmp/frigate-livecam-url.stash already exists (older run'\''s secret — oldest wins, NOT overwritten)."
          echo "STASH: this run'\''s copy left at $LIVECAM_STASH — reconcile manually, then delete both."
        else
          mv "$LIVECAM_STASH" /var/tmp/frigate-livecam-url.stash && \
            echo "STASH: livecam secret preserved at /var/tmp/frigate-livecam-url.stash (snap absent; recover with: sudo tests/spike-smoke.sh or --provision-livecam)"
        fi
      fi
    else
      rm -f "$LIVECAM_STASH"
    fi
  fi
  # M6: if the Coral phase died mid-swap, put the OpenVINO default back (idempotent —
  # CORAL_CFG_BAK is empty unless the phase is mid-flight).
  if [ -n "${CORAL_CFG_BAK:-}" ] && [ -f "${CORAL_CFG_BAK:-}" ]; then
    cp -p "$CORAL_CFG_BAK" "/var/snap/$SNAP_NAME/current/config/config.yml" 2>/dev/null || true
    rm -f "$CORAL_CFG_BAK"
    snap restart $SNAP_NAME.frigate 2>/dev/null || true
  fi
  # PR#3: if the bridge test died mid-flight, restore the operator config it was mutating (it was
  # carrying the injected bridgeproof test stream) and cycle the whole snap so go2rtc regenerates.
  # Review fix: rm the backup only after the copy succeeded (never destroy the last good copy).
  if [ -n "${BRIDGE_CFG_BAK:-}" ] && [ -f "${BRIDGE_CFG_BAK:-}" ]; then
    if cp -p "$BRIDGE_CFG_BAK" "/var/snap/$SNAP_NAME/current/config/config.yml" 2>/dev/null; then
      rm -f "$BRIDGE_CFG_BAK"
    fi
    snap restart $SNAP_NAME 2>/dev/null || true
  fi
  # M8 (R4): if the semantic-search proof died mid-flight, restore the operator config it was
  # mutating (semantic_search.enabled injected) and restart frigate. Same rm-after-copy discipline.
  if [ -n "${M8_SEM_CFG_BAK:-}" ] && [ -f "${M8_SEM_CFG_BAK:-}" ]; then
    if cp -p "$M8_SEM_CFG_BAK" "/var/snap/$SNAP_NAME/current/config/config.yml" 2>/dev/null; then
      rm -f "$M8_SEM_CFG_BAK"
    fi
    snap restart $SNAP_NAME.frigate 2>/dev/null || true
  fi
  # PR#3: operator config safety net — if the run aborted after the purge but before the explicit
  # restore, put the stashed config.yml back so the gate never leaves the operator config-less.
  # Review fix: rm the stash only after the restore copy VERIFIABLY landed (install && cmp);
  # otherwise park it at the deterministic /var/tmp path — the next full run restores it at the
  # install-restore step, where it WINS over any template render (see that block).
  if [ -n "${OPERATOR_CFG_STASH:-}" ] && [ -f "${OPERATOR_CFG_STASH:-}" ]; then
    if [ -d "/var/snap/$SNAP_NAME/current/config" ] && \
       install -m 0600 -o root -g root "$OPERATOR_CFG_STASH" "/var/snap/$SNAP_NAME/current/config/config.yml" 2>/dev/null && \
       cmp -s "$OPERATOR_CFG_STASH" "/var/snap/$SNAP_NAME/current/config/config.yml"; then
      rm -f "$OPERATOR_CFG_STASH"
      snap restart $SNAP_NAME 2>/dev/null || true
    else
      # oldest-wins: run 2'\''s stash may be a template render; the parked file is the real operator config (PR#3 review, M8 B2)
      if [ -e /var/tmp/frigate-operator-config.stash ]; then
        echo "STASH: /var/tmp/frigate-operator-config.stash already exists (older run'\''s config — oldest wins, NOT overwritten)."
        echo "STASH: this run'\''s copy left at $OPERATOR_CFG_STASH — reconcile manually, then delete both."
      else
        mv "$OPERATOR_CFG_STASH" /var/tmp/frigate-operator-config.stash 2>/dev/null && \
          echo "STASH: operator config.yml preserved at /var/tmp/frigate-operator-config.stash (next full harness run restores it — it wins over any template render)"
      fi
    fi
  fi
  # PR#3 review: scrub evidence on EVERY exit path (aborted runs included) — see scrub_evidence.
  scrub_evidence
' EXIT

if [ "${1:-}" != "--skip-install" ] && [ "$NVR_SAFE" -eq 0 ]; then
  [ -n "$SNAP_FILE" ] || { echo "ERROR: no ${SNAP_NAME}_*.snap file found - build first (snapcraft pack)"; exit 1; }
  if [ -f "/var/snap/$SNAP_NAME/common/livecam-url" ]; then
    LIVECAM_STASH=$(mktemp)
    cp -p "/var/snap/$SNAP_NAME/common/livecam-url" "$LIVECAM_STASH"
  fi
  # PR#3: stash the operator's config.yml (their hand-added cameras) across the purge/reinstall
  # cycle — the purge regenerates config from the template and would otherwise DESTROY it. Root
  # 0600 discipline (may embed a camera secret); sha256 recorded for the survival check. Protects
  # ANY operator config from gate runs, not just this host's.
  if [ -f "/var/snap/$SNAP_NAME/current/config/config.yml" ]; then
    OPERATOR_CFG_STASH=$(mktemp)
    cp -p "/var/snap/$SNAP_NAME/current/config/config.yml" "$OPERATOR_CFG_STASH"
    OPERATOR_CFG_SHA=$(sha256sum "$OPERATOR_CFG_STASH" | awk '{print $1}')
    echo "PR#3: operator config.yml stashed before purge (sha256=$OPERATOR_CFG_SHA; content never printed)"
  fi
  snap remove --purge "$SNAP_NAME" 2>/dev/null || true
  # FINDING (M4 Task 4): the snap's PRIVATE /tmp (/tmp/snap-private-tmp/snap.frigate/tmp) is HOST
  # state — it survives snap remove --purge (cleared only at boot). Stale recording-cache segments
  # (<camera>@<ts>.mp4) for a camera no longer in the rendered config (livecam@* left from an armed
  # run after livecam-url deprovision) crash Frigate's recording maintainer EVERY 5s cycle:
  # move_files() does self.config.cameras[camera] (plain dict) -> KeyError 'livecam' aborts the
  # whole move loop, so NO camera's segments reach disk/DB (recordings + vod checks fail).
  # Upstream bug (cache leftovers for a config-removed camera); snap-specific persistence.
  # Journal: [2026-07-06 02:50] frigate.record.maintainer ERROR 'livecam' (every cycle).
  # Clean the leaked cache in the purge window to restore the clean-slate invariant.
  # M7: frigate-run should clear stale-camera cache segments at start — an operator deprovisioning
  # livecam-url otherwise wedges ALL recording until host reboot.
  rm -rf "/tmp/snap-private-tmp/snap.$SNAP_NAME/tmp/cache" 2>/dev/null || true
  # Install mesa-2604 content provider BEFORE frigate so gpu-2604 plug is live when daemons start.
  # This ensures libGL.so.1 (removed from snap prime by gpu/cleanup) is available via content mount.
  snap install mesa-2604 2>/dev/null || true
  snap install --dangerous "$SNAP_FILE" || { fail_ "snap install"; exit 1; }
  snap connect $SNAP_NAME:gpu-2604 mesa-2604:gpu-2604 2>/dev/null || true
  # mount-observe: not auto-connected for --dangerous installs; required by frigate daemon so
  # psutil.disk_partitions() can read /proc/<pid>/mounts for /dev/shm fs-type detection.
  snap connect $SNAP_NAME:mount-observe 2>/dev/null || true
  # Restore the livecam secret (0600), then delete the rendered config and restart frigate so
  # frigate-run regenerates it with the LIVECAM block armed (daemons started at install without
  # the file). M6: frigate-run renders at FIRST start only — operator owns config.yml once it
  # exists; delete-to-regenerate is the re-render protocol.
  if [ -n "$LIVECAM_STASH" ]; then
    install -m 0600 -o root -g root "$LIVECAM_STASH" "/var/snap/$SNAP_NAME/common/livecam-url"
    rm -f "$LIVECAM_STASH"
    rm -f "/var/snap/$SNAP_NAME/current/config/config.yml"
    snap restart $SNAP_NAME.frigate 2>/dev/null || true
  fi
  # PR#3: restore the operator's config.yml OVER any template/livecam render — the operator owns
  # config.yml and the gate must not destroy their cameras. Authoritative last-writer; whole-snap
  # restart so go2rtc regenerates its config from the restored config.yml (the bridge under test).
  # Review fixes: (a) rm the stash only after the copy VERIFIABLY landed (install && cmp);
  # (b) a /var/tmp/frigate-operator-config.stash parked by an ABORTED PRIOR run is restored HERE
  # and WINS over both the template render and this run's stash — an abort between purge and
  # install means any config.yml this run stashed was itself a fresh TEMPLATE, while /var/tmp
  # holds the real operator config (the old top-of-run [ ! -f config.yml ] guard never fired
  # once a reinstall re-rendered the template, parking the config forever).
  OPERATOR_CFG_RESTORED=""
  if [ -n "$OPERATOR_CFG_STASH" ] && [ -f "$OPERATOR_CFG_STASH" ]; then
    if install -m 0600 -o root -g root "$OPERATOR_CFG_STASH" "/var/snap/$SNAP_NAME/current/config/config.yml" && \
       cmp -s "$OPERATOR_CFG_STASH" "/var/snap/$SNAP_NAME/current/config/config.yml"; then
      rm -f "$OPERATOR_CFG_STASH"; OPERATOR_CFG_STASH=""
      OPERATOR_CFG_RESTORED=yes
    else
      echo "PR#3: WARNING operator config restore copy failed — stash retained (EXIT trap will retry or park it)"
    fi
  fi
  if [ -f /var/tmp/frigate-operator-config.stash ]; then
    if install -m 0600 -o root -g root /var/tmp/frigate-operator-config.stash "/var/snap/$SNAP_NAME/current/config/config.yml" && \
       cmp -s /var/tmp/frigate-operator-config.stash "/var/snap/$SNAP_NAME/current/config/config.yml"; then
      rm -f /var/tmp/frigate-operator-config.stash
      # This run's stash (if any) held the post-abort template — superseded; drop it.
      [ -n "$OPERATOR_CFG_STASH" ] && rm -f "$OPERATOR_CFG_STASH" && OPERATOR_CFG_STASH=""
      # Re-anchor the end-of-run survival sha to the RECOVERED config (the true operator config).
      OPERATOR_CFG_SHA=$(sha256sum "/var/snap/$SNAP_NAME/current/config/config.yml" | awk '{print $1}')
      OPERATOR_CFG_RESTORED=yes
      echo "PR#3: RECOVERED operator config.yml from /var/tmp stash (aborted prior run; wins over template; sha256=$OPERATOR_CFG_SHA)"
    else
      echo "PR#3: WARNING /var/tmp operator-config recovery copy failed — stash left in place"
    fi
  fi
  if [ -n "$OPERATOR_CFG_RESTORED" ]; then
    snap restart $SNAP_NAME 2>/dev/null || true
    echo "PR#3: operator config.yml restored after reinstall (hand-added cameras preserved)"
  fi
  pass_ "snap install --dangerous ($SNAP_FILE)"
  sleep 30  # let daemons start and probes write; frigate needs extra time for Python imports (~12s) + startup
fi

# RETIRED (M8 Task 5): the M0 svc-a/b/c ordering-spike daemons are removed from the snap; their
# probe payload is re-homed to the frigate.imports-probe CLI diagnostic (run below). The real
# 4-daemon start chain (go2rtc -> frigate -> nginx -> certsync) is asserted by the service-active
# checks further down (go2rtc L442, frigate L543, nginx L557, certsync L1176).
echo "RETIRED (M8): M0 svc ordering spike — real-daemon chain asserted via services-active checks"

# --- M8 Task 5: re-homed imports/shm/layout/runtime/edgetpu probe (full-gate class) ---
# The retired svc-a/b/c daemons wrote these JSONs at daemon start; a single CLI run now does.
# The run execs Python inside the snap (imports tensorflow/openvino/cv2, dlopens edgetpu, creates a
# psm_ shm to reproduce the M0 denial) — exec-inside-snap, so nvr-safe SKIPs the run AND the reads.
if [ "$NVR_SAFE" -eq 0 ]; then
# M8 Task 6: run from a snap-readable cwd (/). imports-probe imports norfair→matplotlib, whose
# cold-import config lookup opendir()s the process CWD; under a full gate the CWD is the harness
# checkout root (owned by the invoking user, NOT readable by the strict snap), producing a benign but
# capture-flappy AppArmor denial (name="<checkout>/" — captured this VM gate as the sole unexpected
# denial). Running from / makes that probe read the base root (readable) so the denial cannot arise,
# portably for ANY checkout path. imports-probe writes its JSON to absolute $SNAP_COMMON paths, so cwd
# is irrelevant to its output (verified in-VM: imports.json still "complete"). The cwd-independent
# matplotlib font scan (/usr/share/fonts) is re-allowlisted in the denial scan below.
( cd / && snap run $SNAP_NAME.imports-probe >/dev/null 2>&1 ) || true
check "shm probe complete" test "$(jqr shm '.status')" = "complete"
check "shm probe has both sub-results" test "$(jqr shm '.default_name.ok, .snap_prefixed.ok' | wc -l)" = "2"
echo "  shm finding: default(psm_*) ok=$(jqr shm '.default_name.ok') err=$(jqr shm '.default_name.error // "-"')"
echo "  shm finding: snap-prefixed ok=$(jqr shm '.snap_prefixed.ok') err=$(jqr shm '.snap_prefixed.error // "-"')"

TOK=$(jqr layout '.writes."/etc/letsencrypt/probe.txt".token')
[ -n "$TOK" ] || fail_ "layout: token missing from layout.json (write failed?) - downstream token greps would be vacuous"
check "layout probe complete" test "$(jqr layout '.status')" = "complete"
# FINDING: layout /config is rejected at snap pack time ("defines a new top-level directory").
echo "  layout finding: /config NOT in snap layout (pack-time rejection); runtime probe: ok=$(jqr layout '.writes."/config/probe.txt".ok // "N/A"') err=$(jqr layout '.writes."/config/probe.txt".error // "-"')"
check "layout: /etc/letsencrypt -> SNAP_DATA" grep -q "$TOK" /var/snap/$SNAP_NAME/current/letsencrypt/probe.txt
# Fix 1 (M4 Task 4): frigate-run now clears /tmp/cache at startup — a live filesystem grep
# would always fail. Check layout.json instead: the probe captures the write result at probe
# time (before frigate-run starts), so the evidence outlives the cache clear.
check "private /tmp/cache (staging): layout probe write ok" sh -c "jq -e '.writes.\"/tmp/cache/probe.txt\".ok == true' \"$RESULTS/layout.json\""

check "daemons run on python 3.11" test "$(jqr runtime '.version_major_minor')" = "3.11"

# M8: the probe now runs SYNCHRONOUSLY via `snap run` just above (blocks until svc.py exits), so
# imports.json/edgetpu-dlopen.json are already complete on return. The poll below is a cheap
# defensive guard (normally breaks on the first iteration; deadline 120s under extreme host load).
for i in $(seq 1 24); do
  [ "$(jqr imports '.status')" = "complete" ] && [ "$(jqr edgetpu-dlopen '.status')" = "complete" ] && break
  sleep 5
done
check "imports probe complete" test "$(jqr imports '.status')" = "complete"
# sqlite_vec (M8 Task 2): loadable-extension load from /usr/local/lib/vec0 + vec_version() — same
# hardcoded path Frigate's semantic search uses; the probe records vec_version in imports.json.
for MOD in numpy cv2 onnxruntime tflite_runtime tensorflow openvino fastapi uvicorn starlette peewee pydantic scipy norfair zmq cryptography ruamel.yaml paho.mqtt.client sqlite_vec; do
  check "import $MOD" sh -c "jq -e '.imports.\"$MOD\".ok == true' \"$RESULTS/imports.json\""
done
echo "  sqlite-vec finding: vec0 loadable extension vec_version=$(jqr imports '.imports.sqlite_vec.version // "-"') (loaded from /usr/local/lib/vec0)"

# FINDING (Task 6): /media/frigate layout REJECTED at snap pack time (same "defines a new top-level
# directory" error as /config). snapd does not treat /media as a valid layout base even though the
# directory exists in the base filesystem. Implication for M3: recordings cannot use a /media/frigate
# layout; Frigate's recordings path must be configured directly to a $SNAP_COMMON sub-path.
echo "  layout finding: /media/frigate NOT in snap layout (pack-time rejection: 'defines a new top-level directory /media')"
printf '# RECORDED FINDING (Task 6): snapcraft pack-time rejection, replayed by the harness - NOT live command output\nCannot pack snap: error: cannot validate snap "frigate": layout "/media/frigate" defines a new top-level directory "/media"\n' \
  > "$EVIDENCE/media-layout-pack-error.txt"

check "edgetpu dlopen probe complete" test "$(jqr edgetpu-dlopen '.status')" = "complete"
echo "  edgetpu finding: dlopen ok=$(jqr edgetpu-dlopen '.dlopen.ok') err=$(jqr edgetpu-dlopen '.dlopen.error // "-"')"
else
  echo "SKIP (nvr-safe): imports-probe run + shm/layout/runtime/imports/edgetpu reads (exec-inside-snap)"
fi

if [ "$NVR_SAFE" -eq 0 ]; then
# Ensure mesa-2604 is installed and connected (idempotent; also handles --skip-install path)
snap install mesa-2604 2>/dev/null || true
snap connect $SNAP_NAME:gpu-2604 mesa-2604:gpu-2604 2>/dev/null || true
# mount-observe: connect idempotently (not auto-connected for --dangerous installs)
snap connect $SNAP_NAME:mount-observe 2>/dev/null || true
snap connections $SNAP_NAME > "$EVIDENCE/connections.txt"
snap run $SNAP_NAME.gpu-probe || true
check "gpu probe complete" test "$(jqr gpu '.status')" = "complete"
# M8 Task 6 hardware-aware guard: OpenVINO only enumerates a "GPU" device when a real Intel/AMD
# render node is present. On capable hardware the assertion runs untouched; headless VM SKIPs.
if [ "$RENDER_NODE" = yes ]; then
  check "openvino sees GPU" grep -q '"GPU"' "$RESULTS/gpu.json"
else
  echo "SKIP (no capability): openvino sees GPU — $RENDER_NODE_REASON"
fi
check "vainfo produced output" test -s /var/snap/$SNAP_NAME/common/spike-results/vainfo.txt
cp /var/snap/$SNAP_NAME/common/spike-results/vainfo.txt "$EVIDENCE/" 2>/dev/null || true
else
  echo "SKIP (nvr-safe): mesa install + connects + gpu-probe run"
fi

if [ "$NVR_SAFE" -eq 0 ]; then
# --- Coral USB section ---
# Once the Coral firmware is uploaded, the device stays in initialized state (18d1:9302) until
# physically replugged. On re-runs, before==18d1 is the expected steady state — the 1a6e->18d1
# transition only occurs on the very first probe after a replug. A live transition is auto-archived
# to coral-reenum-transition.txt by the block below (1) whenever a replugged device is probed.
snap connect $SNAP_NAME:raw-usb 2>/dev/null || true
snap connect $SNAP_NAME:hardware-observe 2>/dev/null || true
# Warm-up: long-idle initialized Corals fail their first delegate touch (M2 finding) - absorb it.
snap run frigate.coral-probe >/dev/null 2>&1 || true
sleep 2
lsusb | grep -Ei '1a6e|18d1' > "$EVIDENCE/coral-usb-before.txt" || true
snap run $SNAP_NAME.coral-probe || true
sleep 3
lsusb | grep -Ei '1a6e|18d1' > "$EVIDENCE/coral-usb-after.txt" || true
# Archive the one-shot firmware re-enumeration transition whenever it occurs (append, never truncate).
if grep -q 1a6e "$EVIDENCE/coral-usb-before.txt" 2>/dev/null && grep -q 18d1 "$EVIDENCE/coral-usb-after.txt" 2>/dev/null; then
  { echo "# LIVE TRANSITION CAPTURED $(date '+%Y-%m-%d %H:%M:%S')"; cat "$EVIDENCE/coral-usb-before.txt"; cat "$EVIDENCE/coral-usb-after.txt"; echo; } \
    >> "$EVIDENCE/coral-reenum-transition.txt"
fi
# Replay the first-run transition as a RECORDED finding so the evidence is never clobbered by steady-state runs.
printf '# RECORDED FINDING (Task 11): first-run transition, replayed by the harness - NOT live capture\nBus 003 Device 076: ID 1a6e:089a Global Unichip Corp.\nBus 003 Device 077: ID 18d1:9302 Google Inc.\n' \
  > "$EVIDENCE/coral-reenum-firstrun.txt"
check "coral probe complete" test "$(jqr coral '.status')" = "complete"
# M8 Task 6 hardware-aware guard: the delegate/inference/device asserts need a real Coral USB TPU.
# Mirrors the coral-PHASE lsusb gate below; on a host WITH the stick the asserts run untouched, a
# headless VM (no TPU passthrough) SKIPs each with the missing-capability reason. ("coral probe
# complete" stays unconditional — the probe writes status=complete even when the delegate fails.)
if lsusb 2>/dev/null | grep -qEi '1a6e:089a|18d1:9302'; then
  check "coral delegate loaded (firmware upload)" test "$(jqr coral '.load_delegate.ok')" = "true"
  check "coral inference ran" test "$(jqr coral '.inference.ok')" = "true"
  check "coral: device in initialized state (18d1) after probe" grep -q 18d1 "$EVIDENCE/coral-usb-after.txt"
else
  echo "SKIP (no capability): coral delegate loaded (firmware upload) — no Coral USB TPU (1a6e:089a/18d1:9302 absent from lsusb)"
  echo "SKIP (no capability): coral inference ran — no Coral USB TPU (1a6e:089a/18d1:9302 absent from lsusb)"
  echo "SKIP (no capability): coral: device in initialized state (18d1) after probe — no Coral USB TPU (1a6e:089a/18d1:9302 absent from lsusb)"
fi
else
  echo "SKIP (nvr-safe): coral-probe firmware runs + connects"
fi

if [ "$NVR_SAFE" -eq 0 ]; then
# --- NPU custom-device section ---
# FINDING (M7 final review): the NPU custom-device substrate (M0-C) is RETIRED from the SHIPPED
# artifact — the npu-dev slot, the npu plug, and the npu-probe app were dropped from snapcraft.yaml
# before the first Store upload (a functionless super-privileged custom-device slot risks a
# manual-review hold; NPU is documented not-yet-supported, out of M7 scope). The probe stays
# DORMANT in the repo (spike/bin/npu-probe + spike/probes/probe_npu.py) — re-add with the NPU
# milestone. Robust app-existence gate: grep the built snap's meta/snap.yaml apps for npu-probe
# (the wrapper binary is still dumped into bin/ by the wrappers part, so a file-existence probe
# would false-positive; the generated meta/snap.yaml is the authoritative app list).
if grep -q '^  npu-probe:' "/snap/$SNAP_NAME/current/meta/snap.yaml" 2>/dev/null; then
  snap connect $SNAP_NAME:npu $SNAP_NAME:npu-dev 2> "$EVIDENCE/npu-connect.txt" || true
  snap run $SNAP_NAME.npu-probe 2>> "$EVIDENCE/npu-connect.txt" || true
  check "npu probe produced evidence" sh -c "test -s $RESULTS/npu.json -o -s $EVIDENCE/npu-connect.txt"
  echo "  npu finding: open=$(jqr npu '.open_accel0.ok // "no-json"') connect-err=$(head -c120 "$EVIDENCE/npu-connect.txt" 2>/dev/null)"
else
  echo "SKIP: npu probe retired from shipped snap (M7 final review; custom-device dropped pre-Store)"
fi
else
  echo "SKIP (nvr-safe): npu custom-device probe block (dormant)"
fi

# --- M2: ffmpeg matrix (Task 1) --- ffprobe app follows the tag-default 7.0 tree
check "ffprobe app runs tag-default 7.0" sh -c "snap run frigate.ffprobe -version 2>/dev/null | head -1 | grep -q '^ffprobe version n7'"
# static builds run directly from the mounted squashfs (no confinement needed for -version)
# 8.0 dropped (M8 A2): upstream v0.17.2 amd64 ships only 7.0+5.0 — enumeration mirrors the verdict set
for V in 5.0 7.0; do
  check "ffmpeg tree $V present+runs" sh -c "/snap/frigate/current/usr/lib/ffmpeg/$V/bin/ffprobe -version | head -1 | grep -q '^ffprobe version'"
done

# --- M2: frigate source + carried patch (Task 2) ---
check "frigate source staged" test -f /snap/frigate/current/opt/frigate/frigate/const.py
check "carried patch applied (env-driven paths)" grep -q 'FRIGATE_CONFIG_DIR' /snap/frigate/current/opt/frigate/frigate/const.py
check "migrations staged" test -d /snap/frigate/current/opt/frigate/migrations

# --- M1: go2rtc daemon (Task 2) ---
check "go2rtc service active" sh -c "snap services frigate.go2rtc | grep -q ' active'"
# PR#3 review: NAMES-ONLY capture — /api/streams emits producer URLs verbatim (operator camera
# credentials included); the assertions only need stream NAMES, so minimize at capture (layer 1;
# layer 2 is the generalized scrub_evidence redaction at end-of-run + trap).
curl -sf --max-time 5 http://127.0.0.1:1984/api/streams 2>/dev/null | jq 'keys' > "$EVIDENCE/go2rtc-streams.json" 2>/dev/null || true
check "go2rtc API lists test stream" sh -c "jq -e 'index(\"test\")' \"$EVIDENCE/go2rtc-streams.json\""

# --- M1: readiness gate evidence (Task 3) ---
# RETIRED (M8 Task 5): the M0 svc-a readiness-gate spike (wait_for_url -> waited_ms) is retired with
# its daemon. The real daemons carry readiness gating in their own run wrappers — nginx-run/
# frigate-run/certsync-run call wait_for_url (lib-wait.sh) before exec'ing their service.
echo "RETIRED (M8): M0 svc-a readiness spike (waited_ms) — real daemons gate via wait_for_url in their run wrappers"

# --- M1: RTSP end-to-end (Task 4) ---
# ffprobe is BOTH the verifier and the first consumer: it triggers go2rtc's
# exec: source, which spawns the staged ffmpeg INSIDE confinement.
timeout 30 snap run frigate.ffprobe -v error -print_format json -show_streams \
  -rtsp_transport tcp "rtsp://127.0.0.1:8554/test" > "$EVIDENCE/rtsp-probe.json" 2>/dev/null || true
check "rtsp: stream is h264" sh -c "jq -e '.streams[0].codec_name == \"h264\"' \"$EVIDENCE/rtsp-probe.json\""
check "rtsp: 1280x720" sh -c "jq -e '.streams[0].width == 1280 and .streams[0].height == 720' \"$EVIDENCE/rtsp-probe.json\""
# Confined subprocess evidence: the exec producer must appear in go2rtc's stream state.
# PR#3 review: producer .url fields stripped at capture (source URLs; the assertion only needs
# producer PRESENCE). The test stream's url is a credential-free exec line, but minimize anyway.
curl -sf --max-time 5 "http://127.0.0.1:1984/api/streams?src=test" 2>/dev/null | jq 'del(.producers[]?.url)' > "$EVIDENCE/go2rtc-producer.json" 2>/dev/null || true
check "go2rtc exec producer active (confined ffmpeg spawned)" sh -c "jq -e '.producers[0]' \"$EVIDENCE/go2rtc-producer.json\""
echo "  subprocess finding: exec producer state captured in go2rtc-producer.json"

# --- M1: WebRTC (Task 5) ---
check "webrtc: 8555/tcp bound" sh -c "ss -tlnp | grep -q ':8555'"
# M8 T1 fix round, outcome (c) — environmental, TCP healthy: go2rtc (1.9.13) binds its fixed-port
# UDP candidate sockets PER INTERFACE-ADDRESS at process start only; when the go2rtc daemon starts
# at boot before the network is up (observed: boot 21:01:03, webrtc listen 21:01:30.9, wifi still
# authenticating 21:01:33), zero UDP sockets exist for the process lifetime. The TCP mux is a
# wildcard bind (address-independent) and WHEP still returns SDP answers (checked below). The
# generated go2rtc.yaml is NOT at fault (same spec binds UDP when started with network up — every
# full-gate restart). nvr-safe must not fail on this boot-order race: assert TCP (above) and
# record the UDP state as a finding. Full gate asserts UDP as before.
if [ "$NVR_SAFE" -eq 1 ]; then
  if ss -ulnp | grep -q ':8555'; then
    echo "  webrtc finding (nvr-safe): 8555/udp bound (go2rtc started with network up)"
  else
    echo "  webrtc finding (nvr-safe): 8555/udp NOT bound — go2rtc started before network-online (boot-order race; per-interface UDP candidate sockets bind at start only); TCP mux healthy"
  fi
  echo "SKIP (nvr-safe): webrtc: 8555/udp bound — TCP asserted; UDP state recorded as finding (boot-order dependent)"
else
  check "webrtc: 8555/udp bound" sh -c "ss -ulnp | grep -q ':8555'"
fi
# WHEP: POST a minimal recvonly offer; a 2xx + SDP answer is full automated proof.
# A non-2xx HTTP response still proves the endpoint is alive (record; manual browser
# check below is then the SDP-level evidence). Connection-refused fails the check.
WHEP_OFFER='v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\nc=IN IP4 0.0.0.0\r\na=mid:0\r\na=recvonly\r\na=rtpmap:96 H264/90000\r\na=ice-ufrag:spike\r\na=ice-pwd:spikespikespikespikespike\r\na=fingerprint:sha-256 00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF\r\na=setup:actpass\r\n'
# --max-time 10 (was 5), MEASURED (T6 review fix): go2rtc answers WHEP only after ICE gathering
# completes; with the stun:8555 candidate behind NAT (m8-gate VM) the gathering timer runs its full
# ~5 s and the 201+SDP answer lands at ~5.07 s — a 5 s curl deadline loses that race by ~70 ms EVERY
# time (3/3 runs: 000 @ 5.01 s; the same request at max-time 20: 201 @ 5.069 s). 10 s decouples the
# capture from go2rtc's own gathering timer; hosts answering <5 s are unaffected; a dead endpoint
# still fails fast (connection refused returns immediately) and a hung one fails at 10 s.
printf "%b" "$WHEP_OFFER" | curl -s --max-time 10 -X POST -H 'Content-Type: application/sdp' \
  --data-binary @- -o "$EVIDENCE/whep-response.txt" -w '%{http_code}' \
  "http://127.0.0.1:1984/api/webrtc?src=test" > "$EVIDENCE/whep-status.txt" 2>/dev/null || true
# M8 Task 6 review fix (Important): capability probe DECOUPLED from the assertion. The first guard
# used the assertion's own outcome (an HTTP status was returned) as the capability signal, so on
# capable hardware a genuine WHEP regression (000) would have downgraded FAIL→SKIP. Capability is now
# the assertion-independent ss signal the "webrtc: 8555/tcp bound" check above reads (second identical
# ss call): go2rtc's webrtc listener not bound → SKIP with reason; bound → the ORIGINAL hard assertion
# runs unchanged (a 000/no-response FAILS). go2rtc fully down is caught by the bound-check itself.
if ss -tlnp | grep -q ':8555'; then
  check "webrtc: WHEP endpoint alive (HTTP response)" sh -c "grep -qE '^[1-5][0-9][0-9]$' \"$EVIDENCE/whep-status.txt\""
else
  echo "SKIP (no capability): webrtc: WHEP endpoint alive (HTTP response) — go2rtc webrtc listener not bound (no capability)"
fi
if grep -q '^2' "$EVIDENCE/whep-status.txt" && grep -q '^v=0' "$EVIDENCE/whep-response.txt"; then
  pass_ "webrtc: WHEP returned SDP answer (automated full proof)"
else
  echo "  webrtc finding: WHEP status=$(cat "$EVIDENCE/whep-status.txt") - SDP answer not automated; manual browser check required (see docs/m1-findings.md)"
fi

# --- M1: mDNS multicast (Task 6) ---
if [ "$NVR_SAFE" -eq 0 ]; then
snap run frigate.mdns-probe || true
check "mdns probe complete" test "$(jqr mdns '.status')" = "complete"
echo "  mdns finding: join=$(jqr mdns '.multicast_join.ok') sent=$(jqr mdns '.query_sent.ok') responses=$(jqr mdns '.responses')"
else
  echo "SKIP (nvr-safe): mdns-probe transient exerciser"
fi

if [ "$NVR_SAFE" -eq 0 ]; then
# --- M2: VAAPI hardware decode (Task 4) ---
# -hwaccel_output_format vaapi FORBIDS silent software fallback: rc=0 proves the hw path.
# M8 Task 6 hardware-aware guard: VAAPI hw decode needs a real Intel/AMD render node (the probe
# still RUNS so evidence documents the no-GPU state, but the rc=0 assertion only fires on capable HW).
if [ "$RENDER_NODE" = yes ]; then
  check "vaapi: hw decode of synthetic stream (rc=0, no sw fallback)" snap run frigate.vaapi-probe
else
  snap run frigate.vaapi-probe >/dev/null 2>&1 || true   # run anyway to capture the no-GPU evidence
  echo "SKIP (no capability): vaapi: hw decode of synthetic stream (rc=0, no sw fallback) — $RENDER_NODE_REASON"
fi
cp /var/snap/frigate/common/spike-results/vaapi-decode.txt "$EVIDENCE/" 2>/dev/null || true
check "vaapi: evidence captured" test -s "$EVIDENCE/vaapi-decode.txt"
echo "  vaapi finding: $(grep -m1 -iE 'vaapi|hwaccel' "$EVIDENCE/vaapi-decode.txt" 2>/dev/null || echo 'see vaapi-decode.txt')"

# --- M2: frigate config validation (Task 5 - THE M2 EXIT CRITERION) ---
# shm-private (shared-memory, private:true): python mp named semaphores need a writable
# /dev/shm — glibc sem_open creates random sem.XXXXXX tempfiles no AppArmor rule can match.
snap connect frigate:shm-private 2>/dev/null || true
snap run frigate.validate-config > "$EVIDENCE/validate-config.txt" 2>&1
VC_RC=$?
check "frigate validate-config exits 0" test "$VC_RC" = "0"
check "validate-config evidence captured" test -s "$EVIDENCE/validate-config.txt"
echo "  validate finding: rc=$VC_RC $(tail -1 "$EVIDENCE/validate-config.txt" 2>/dev/null)"
else
  echo "SKIP (nvr-safe): vaapi-probe + shm-private connect + validate-config run"
fi

# --- M3: detector models staged (Task 1) ---
check "openvino model staged" sh -c "ls /snap/frigate/current/opt/frigate/models/openvino/*.xml"
check "cpu tflite fallback staged" sh -c "ls /snap/frigate/current/opt/frigate/models/cpu/*.tflite"
check "coco labelmap staged" test -s /snap/frigate/current/opt/frigate/models/labelmap.txt
check "openvino 91-class labelmap staged" test -s /snap/frigate/current/opt/frigate/models/openvino/coco_91cl_bkgr.txt

# --- M3: real-object test clip + stream (Task 2) ---
check "test clip staged" test -s /snap/frigate/current/media-samples/testclip.mp4
check "go2rtc has testclip stream" sh -c "jq -e 'index(\"testclip\")' \"$EVIDENCE/go2rtc-streams.json\""

# --- M3: frigate daemon (Task 3 - THE MILESTONE) ---
check "frigate service active" sh -c "snap services frigate.frigate | grep -q ' active'"
# Wait up to 90s for API (OV model GPU compilation can take 30-60s at first inference;
# boot failures land in journalctl; the service active check above confirms it started).
# NOTE: v0.17.2 routes /version at the root (no /api/ prefix); upstream changed the API
# structure vs older Frigate versions where /api/version was the path.
for _i in $(seq 1 18); do
  curl -sf --max-time 5 http://127.0.0.1:5001/version > "$EVIDENCE/frigate-version.txt" 2>/dev/null && break
  sleep 5
done
check "frigate API answers" test -s "$EVIDENCE/frigate-version.txt"
check "db at split path" test -f /var/snap/frigate/common/db/frigate.db
check "sidecar written" sh -c "grep -qE '^0\.17\.2' /var/snap/frigate/common/db/.last-writer"

# --- M4: nginx reverse-proxy (Task 2) ---
check "nginx service active" sh -c "snap services frigate.nginx | grep -q ' active'"
# Verify: /api/version via nginx (:5000) returns same body as direct :5001/version.
# Route: nginx strips /api prefix, proxies to frigate_api (:5001) via rewrite ^/api(/.*)$ $1.
# M5: auth.enabled=true; :5000 internal port stays anonymous via nginx X-Server-Port:5000 short-circuit.
# nginx /api/version includes auth_request.conf; via :5000 nginx injects X-Server-Port:5000 → auth() 202.
# Retry loop (2-3 iterations, sleep 2): closes the systemd-active-vs-bound window where the
# nginx unit is reported active but the worker socket is not yet accepting connections.
NGINX_VER=""
for _nginx_i in 1 2 3; do
    NGINX_VER=$(curl -sf --max-time 5 http://127.0.0.1:5000/api/version 2>/dev/null)
    [ -n "$NGINX_VER" ] && break
    sleep 2
done
FRIGATE_VER=$(curl -sf --max-time 5 -H "Remote-User: admin" -H "Remote-Role: admin" http://127.0.0.1:5001/version 2>/dev/null)
[ -n "$NGINX_VER" ] || fail_ "nginx proxies /api/version == :5001/version (no auth headers) — NGINX_VER empty (nginx not responding)"
check "nginx proxies /api/version == :5001/version (no auth headers)" test "$NGINX_VER" = "$FRIGATE_VER"
echo "  nginx finding: /api/version=$NGINX_VER (== :5001/version; no auth headers required)"
# M5: :5000 internal-port anonymity — nginx auth_request sends X-Server-Port:5000 → auth() 202.
# Direct :5001/auth without X-Server-Port returns 401 with auth=true (not tested here by design).
# Verify anonymity via protected path: :5000/api/version → 200 proves no-JWT anonymous accept.
HTTP_ANON_STATUS=$(curl -so /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:5000/api/version 2>/dev/null)
check "frigate: :5000 internal-port anonymous (X-Server-Port:5000 → 202; auth=true)" test "$HTTP_ANON_STATUS" = "200"
echo "  nginx finding: :5000 anonymous status=$HTTP_ANON_STATUS (X-Server-Port==5000 short-circuit; no JWT needed on internal port)"
echo "  nginx finding: error_log/access_log → files in \$SNAP_DATA/nginx/logs/ (deviation: /dev/stderr not openable in systemd snap unit — journal socket, not pipe; ENXIO on open); M7: configure logrotate for \$SNAP_DATA/nginx/logs/{error,access}.log; no journald capture while stderr is a socket fd"

# --- M4: web UI + vod + go2rtc proxy gate (Task 4) ---
# 1. Web UI root: GET :5000/ → 200 + "Frigate" marker
#    nginx serves the built React app from /opt/frigate/web (snap layout bind); / → index.html.
WUI_STATUS=""
for _wui_i in 1 2 3; do
    WUI_STATUS=$(curl -so /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:5000/ 2>/dev/null)
    [ "$WUI_STATUS" = "200" ] && break
    sleep 2
done
check "webui: GET :5000/ → 200" test "$WUI_STATUS" = "200"
curl -sf --max-time 5 http://127.0.0.1:5000/ > "$EVIDENCE/webui-root.html" 2>/dev/null || true
check "webui: root body contains Frigate marker" grep -q 'Frigate' "$EVIDENCE/webui-root.html"
# 2. Hashed JS asset: 200 + application/javascript MIME (1y cache confirms /assets/ location active).
#    Asset URL discovered dynamically from the live snap's index.html at runtime.
ASSET_PATH=$(grep -o 'assets/index-[^"]*\.js' /snap/frigate/current/opt/frigate/web/index.html 2>/dev/null | head -1)
if [ -n "$ASSET_PATH" ]; then
    ASSET_STATUS=$(curl -sI -o "$EVIDENCE/asset-headers.txt" -w '%{http_code}' \
        --max-time 5 "http://127.0.0.1:5000/${ASSET_PATH}" 2>/dev/null)
    check "webui: hashed JS asset ($ASSET_PATH) → 200" test "$ASSET_STATUS" = "200"
    check "webui: hashed JS asset MIME is application/javascript" \
        grep -qi 'application/javascript' "$EVIDENCE/asset-headers.txt"
    echo "  webui finding: $ASSET_PATH → HTTP $ASSET_STATUS application/javascript (1y public cache, /assets/ location)"
else
    fail_ "webui: hashed JS asset — no assets/index-*.js in snap index.html"
    echo "  webui finding: no index-*.js found in snap index.html (unexpected — check snap prime)"
fi
# 3. GET :5000/api/version → 200 without auth headers (nginx auth_request + auth.enabled=false).
#    /auth returns 202 + remote-user:viewer/remote-role:viewer; these are forwarded to Frigate.
APIVER_STATUS=$(curl -so /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:5000/api/version 2>/dev/null)
check "webui: GET :5000/api/version → 200 (no auth headers)" test "$APIVER_STATUS" = "200"
echo "  webui finding: /api/version HTTP $APIVER_STATUS without auth headers (/auth 202 viewer headers forwarded)"
# M8 T1 fix round: fixture probe for nvr-safe — testclip is a HARNESS fixture camera (template
# config); an operator-configured production host may run only real cameras. Probe the live
# camera set via /stats, piped straight to jq (never persisted: /stats can embed camera cmdlines).
# Default stays "yes" (assert) — if the API is unreachable the earlier "frigate API answers"
# check has already failed the run, so nothing is masked. Full gate always asserts (template
# config always carries testclip). Used by the vod check below and the gpu money check.
TESTCLIP_FIXTURE=yes
if [ "$NVR_SAFE" -eq 1 ]; then
  curl -sf --max-time 5 -H "Remote-User: admin" -H "Remote-Role: admin" \
    http://127.0.0.1:5001/stats 2>/dev/null | jq -e '.cameras | has("testclip")' >/dev/null 2>&1 || TESTCLIP_FIXTURE=""
fi
# 4. vod manifest check
# URL shape (verified from Frigate source frigate/api/media.py line 853 + nginx-vod-module config):
#   GET :5000/vod/{camera}/start/{start_ts}/end/{end_ts}/index.m3u8
# nginx-vod-module (mapped mode, vod_upstream_location /api) makes internal subrequest to
#   /api/vod/{camera}/start/{ts}/end/{ts} → nginx /api/vod/ location proxies to
#   Frigate at /vod/{camera}/start/{ts}/end/{ts} → returns JSON clip mapping →
#   nginx-vod-module builds HLS manifest with #EXTM3U header.
# Dynamic timestamps: poll the live recordings API for testclip (continuous recording enabled).
# UPSTREAM BUG (v0.17.2, found by this check's first gate run): /{camera}/recordings default
# after/before are datetime.now() evaluated at IMPORT time (Python default-arg trap,
# frigate/api/media.py:632-633). 'before' freezes at daemon boot and the filter is
# start_time <= before, so every segment recorded AFTER boot is invisible to the bare route —
# the poll saw [] for 90s while the DB held rows. Explicit after/before params (recomputed each
# iteration) bypass the frozen defaults. M7/upstream: report; UI is immune (always sends params).
if [ "$NVR_SAFE" -eq 1 ] && [ "$TESTCLIP_FIXTURE" != "yes" ]; then
  echo "SKIP (nvr-safe): vod: GET :5000/vod/testclip/start/../end/../index.m3u8 → 200 + #EXTM3U — testclip fixture not in operator config"
else
VOD_START=""
VOD_END=""
for _vod_i in $(seq 1 18); do
    VOD_NOW=$(date +%s)
    VOD_REC=$(curl -sf --max-time 5 \
        "http://127.0.0.1:5000/api/testclip/recordings?after=$((VOD_NOW-3600))&before=$((VOD_NOW+60))" 2>/dev/null)
    if echo "$VOD_REC" | jq -e 'length > 0' >/dev/null 2>&1; then
        VOD_START=$(echo "$VOD_REC" | jq -r '.[0].start_time')
        VOD_END=$(echo "$VOD_REC" | jq -r '.[-1].end_time')
        break
    fi
    sleep 5
done
if [ -n "$VOD_START" ] && [ -n "$VOD_END" ]; then
    curl -sf --max-time 10 \
        "http://127.0.0.1:5000/vod/testclip/start/${VOD_START}/end/${VOD_END}/index.m3u8" \
        > "$EVIDENCE/vod-manifest.txt" 2>/dev/null || true
    check "vod: GET :5000/vod/testclip/start/../end/../index.m3u8 → 200 + #EXTM3U" \
        grep -q '#EXTM3U' "$EVIDENCE/vod-manifest.txt"
    echo "  vod finding: shape=testclip/start/${VOD_START}/end/${VOD_END}/index.m3u8 segments=$(grep -c '^#EXTINF' "$EVIDENCE/vod-manifest.txt" 2>/dev/null || echo 0)"
else
    fail_ "vod: GET :5000/vod/testclip/start/../end/../index.m3u8 → 200 + #EXTM3U"
    echo "  vod finding: FAIL — no recordings in DB after 90s poll; check recording maintainer logs"
fi
fi
# 5. go2rtc proxy check: GET :5000/live/webrtc/webrtc.html → 200
# Nginx /live/webrtc/webrtc.html proxies to go2rtc :1984/webrtc.html (plain HTTP GET, no WebSocket).
# Chosen as the simplest HTTP-answerable go2rtc proxy path (vs /live/mse/api/ws WebSocket upgrade
# and /api/go2rtc/webrtc POST-only). Proves the go2rtc upstream is reachable via nginx.
GO2RTC_PROXY_STATUS=$(curl -so /dev/null -w '%{http_code}' --max-time 5 \
    http://127.0.0.1:5000/live/webrtc/webrtc.html 2>/dev/null)
check "go2rtc proxy: GET :5000/live/webrtc/webrtc.html → 200" test "$GO2RTC_PROXY_STATUS" = "200"
echo "  go2rtc proxy finding: nginx /live/webrtc/webrtc.html → go2rtc :1984/webrtc.html; HTTP $GO2RTC_PROXY_STATUS"

# --- M3: money test (Task 5) ---
# Routes verified against live daemon (v0.17.2): /events and /stats (NO /api/ prefix).
# Auth: allow_any_authenticated() checks Remote-User header; global admin_checker checks
# Remote-Role. Both headers needed for non-exempt paths; /events and /stats are in
# EXEMPT_PATHS so only Remote-User is strictly required, but we send both for safety.
# Event JSON shape: [{id, label, data:{score, top_score, ...}, camera, ...}]
# Stats JSON shape: {detectors:{ov:{inference_speed, detection_start, pid}}, cameras:{...}}
# DB table name: event (verified via sqlite_master on the live DB).
# LIVE-CAMERA GATE (re-armed 2026-07-05): the detection money test runs against the live
# camera (natural quiet intervals => stock calibration exits normally). The looping testclip
# can NEVER produce detections on stock code (constant motion keeps calibration engaged;
# motion.enabled=false is a v0.17.2 ValidationError; behavior patches rejected by ruling —
# see docs/patches.md "Rejected patch"). Gate protocol (coral-style): no secret file or
# unreachable stream => explicit SKIP with reason, suite stays green.
LIVECAM_FILE=/var/snap/$SNAP_NAME/common/livecam-url
LIVECAM=""
LIVECAM_URL=""
LIVECAM_SKIP_REASON="no livecam provisioned ($LIVECAM_FILE absent)"
if [ -f "$LIVECAM_FILE" ]; then
  LIVECAM_URL=$(head -1 "$LIVECAM_FILE" | tr -d '[:space:]')
  # Reachability: bash /dev/tcp port probe. M4 Task 0 hardening: host/port parsed IN-shell and
  # passed via ENV (root-only /proc/<pid>/environ), never argv — the previous ffprobe probe held
  # the full URL (credentials included) in /proc/<pid>/cmdline for up to 20 s. Port-open is a
  # weaker signal than an RTSP handshake but leak-free; a dead stream behind an open port then
  # surfaces as a real MONEY TEST failure, the correct signal for that condition.
  LC_HP="${LIVECAM_URL#*://}"; LC_HP="${LC_HP#*@}"; LC_HP="${LC_HP%%/*}"
  LC_HOST="${LC_HP%%:*}"; LC_PORT="${LC_HP##*:}"
  [ "$LC_PORT" = "$LC_HOST" ] && LC_PORT=554   # no explicit port -> rtsp default
  if [ -n "$LC_HOST" ] && LC_H="$LC_HOST" LC_P="$LC_PORT" timeout 5 bash -c 'exec 3<>"/dev/tcp/$LC_H/$LC_P"' 2>/dev/null; then
    LIVECAM=yes
  else
    LIVECAM_SKIP_REASON="livecam-url present but camera port unreachable at harness start"
  fi
fi
CACHE_PEAK=0
if [ "$LIVECAM" = "yes" ]; then
  # Detection poll: up to ~90s (first boot includes OpenVINO GPU model compile + stock
  # motion calibration needs a quiet interval). Scoped to the livecam camera.
  DETECTED=""
  for i in $(seq 1 18); do
    curl -sf --max-time 5 -H "Remote-User: admin" -H "Remote-Role: admin" \
      "http://127.0.0.1:5001/events?cameras=livecam&labels=person&limit=5" \
      > "$EVIDENCE/frigate-events.json" 2>/dev/null || true
    if jq -e 'length > 0' "$EVIDENCE/frigate-events.json" >/dev/null 2>&1; then DETECTED=yes; fi
    C=$(du -sk /tmp/snap-private-tmp/snap.frigate/tmp/cache 2>/dev/null | awk '{print $1}')
    [ -n "$C" ] && [ "$C" -gt "$CACHE_PEAK" ] && CACHE_PEAK=$C
    [ -n "$DETECTED" ] && [ "$i" -gt 6 ] && break   # keep sampling a bit even after first hit
    sleep 5
  done
  # Pipeline liveness FIRST — a dead stream/detector is a packaging regression and must FAIL
  # regardless of scene content. Zero person events on a LIVE pipeline is scene-content
  # (nobody in frame), not a packaging fault: SKIP, not FAIL (test-the-packaging directive).
  # PR#3 review: del(.cpu_usages) at every /stats capture — that map's per-pid cmdline values
  # carry the camera ffmpeg command lines VERBATIM (rtsp URLs with credentials); no assertion
  # reads cpu_usages (.cameras.*/.detectors.* only). Same treatment at all 4 /stats captures.
  curl -sf --max-time 5 -H "Remote-User: admin" -H "Remote-Role: admin" \
    http://127.0.0.1:5001/stats 2>/dev/null | jq 'del(.cpu_usages)' > "$EVIDENCE/livecam-stats.json" 2>/dev/null || true
  check "livecam: camera pipeline alive (ffmpeg_pid > 0)" sh -c "jq -e '.cameras.livecam.ffmpeg_pid > 0' \"$EVIDENCE/livecam-stats.json\""
  PIPE_ALIVE=""
  jq -e '.cameras.livecam.ffmpeg_pid > 0' "$EVIDENCE/livecam-stats.json" >/dev/null 2>&1 && PIPE_ALIVE=yes
  if [ "$DETECTED" = "yes" ]; then
    check "MONEY TEST: real objects detected on live camera (events API)" test "$DETECTED" = "yes"
    check "detection: label is person with score" sh -c "jq -e '.[0].label == \"person\" and .[0].data.score > 0.4' \"$EVIDENCE/frigate-events.json\""
    # DB corroboration (also proves the split path is live). Table name: event.
    sqlite3 /var/snap/frigate/common/db/frigate.db "SELECT id,label,camera FROM event WHERE camera='livecam' LIMIT 5;" > "$EVIDENCE/db-events.txt" 2>/dev/null || \
      python3 -c "import sqlite3; c=sqlite3.connect('/var/snap/frigate/common/db/frigate.db'); [print(r[0],r[1],r[2]) for r in c.execute(\"SELECT id,label,camera FROM event WHERE camera='livecam' LIMIT 5\")]" > "$EVIDENCE/db-events.txt" 2>/dev/null || true
    check "detection: corroborated in split db" test -s "$EVIDENCE/db-events.txt"
  elif [ "$PIPE_ALIVE" = "yes" ]; then
    SCENE_SKIP="livecam armed, pipeline alive, no person event in window (scene-dependent: needs a subject in frame; detection proven on this camera 2026-07-05, commit 484edff)"
    echo "SKIP: MONEY TEST: real objects detected on live camera (events API) — $SCENE_SKIP"
    echo "SKIP: detection: label is person with score — $SCENE_SKIP"
    echo "SKIP: detection: corroborated in split db — $SCENE_SKIP"
  else
    fail_ "MONEY TEST: real objects detected on live camera (events API) — armed but pipeline dead (ffmpeg_pid not > 0): packaging regression, not scene content"
    fail_ "detection: label is person with score — pipeline dead"
    fail_ "detection: corroborated in split db — pipeline dead"
  fi
else
  for i in $(seq 1 6); do
    curl -sf --max-time 5 -H "Remote-User: admin" -H "Remote-Role: admin" \
      "http://127.0.0.1:5001/events?labels=person,car&limit=5" \
      > "$EVIDENCE/frigate-events.json" 2>/dev/null || true
    C=$(du -sk /tmp/snap-private-tmp/snap.frigate/tmp/cache 2>/dev/null | awk '{print $1}')
    [ -n "$C" ] && [ "$C" -gt "$CACHE_PEAK" ] && CACHE_PEAK=$C
    sleep 5
  done
  echo "SKIP: MONEY TEST: real objects detected (events API) — $LIVECAM_SKIP_REASON"
  echo "SKIP: detection: labels are person/car with scores — $LIVECAM_SKIP_REASON"
  echo "SKIP: detection: corroborated in split db — $LIVECAM_SKIP_REASON"
fi
echo "$CACHE_PEAK KiB peak" > "$EVIDENCE/cache-peak.txt"
# GPU evidence via frigate's own stats (route: /stats, not /api/stats)
curl -sf --max-time 5 -H "Remote-User: admin" -H "Remote-Role: admin" \
  http://127.0.0.1:5001/stats 2>/dev/null | jq 'del(.cpu_usages)' > "$EVIDENCE/frigate-stats.json" 2>/dev/null || true
# M8 T1 fix round: the pipeline half of this check reads the testclip fixture camera — fixture-
# aware in nvr-safe (see TESTCLIP_FIXTURE probe at the vod check); full gate asserts as always.
if [ "$NVR_SAFE" -eq 1 ] && [ "$TESTCLIP_FIXTURE" != "yes" ]; then
  echo "SKIP (nvr-safe): gpu: openvino detector reporting + camera pipeline alive — testclip fixture not in operator config"
elif [ "$RENDER_NODE" = yes ]; then
  # M8 Task 6 hardware-aware guard: with no render node, auto-detect selects the cpu detector, so
  # there is no .detectors.ov to report — SKIP. On capable hardware the ov assertion runs untouched.
  check "gpu: openvino detector reporting + camera pipeline alive" sh -c "jq -e '.detectors.ov.inference_speed != null and .cameras.testclip.ffmpeg_pid > 0' \"$EVIDENCE/frigate-stats.json\""
else
  echo "SKIP (no capability): gpu: openvino detector reporting + camera pipeline alive — $RENDER_NODE_REASON (auto-detect selects cpu; no ov detector exists to report)"
fi
echo "  gpu finding: ov inference_speed=$(jq -r '.detectors.ov.inference_speed' "$EVIDENCE/frigate-stats.json" 2>/dev/null)ms"
# Recordings on disk
check "recordings: files under SNAP_COMMON" sh -c "find /var/snap/frigate/common/media/frigate/recordings -name '*.mp4' 2>/dev/null | head -1 | grep -q mp4"

# --- M5: TLS + auth + certsync (Task 4 — THE MILESTONE MONEY CHECKS) ---

# Money check 1: HTTPS web UI — GET :8971/ → 200 + Frigate marker + cert subject
# nginx /: no auth_request (static assets exempt); serves web UI on TLS without JWT.
TLS_WUI_STATUS=""
for _tls_i in 1 2 3; do
    TLS_WUI_STATUS=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://127.0.0.1:8971/ 2>/dev/null)
    [ "$TLS_WUI_STATUS" = "200" ] && break
    sleep 2
done
check "https: GET :8971/ → 200" test "$TLS_WUI_STATUS" = "200"
curl -sk --max-time 5 https://127.0.0.1:8971/ > "$EVIDENCE/https-root.html" 2>/dev/null || true
check "https: root body contains Frigate marker" grep -q 'Frigate' "$EVIDENCE/https-root.html"
CERT_SUBJ=$(echo "" | openssl s_client -connect 127.0.0.1:8971 2>/dev/null | openssl x509 -subject -noout 2>/dev/null || echo "")
echo "$CERT_SUBJ" > "$EVIDENCE/cert-subj.txt"
check "https: cert subject contains FRIGATE DEFAULT CERT" grep -q 'FRIGATE DEFAULT CERT' "$EVIDENCE/cert-subj.txt"
echo "  tls finding: cert subject=$(cat "$EVIDENCE/cert-subj.txt")"

# Money check 2: auth gate — unauthenticated :8971 API → 401
# nginx /api/version includes auth_request.conf; X-Server-Port:8971 ≠ 5000 → JWT validation → 401.
AUTH_401=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://127.0.0.1:8971/api/version 2>/dev/null)
check "auth: :8971 API unauthenticated → 401" test "$AUTH_401" = "401"
echo "  auth finding: :8971 unauthenticated /api/version=$AUTH_401 (401 = JWT gate via X-Server-Port:8971)"

# Money check 3: login → cookie → 200 (THE M5 MONEY LINE)
# Bootstrap admin password: logged once on first start after snap remove --purge (empty DB).
# DISCIPLINE: capture to shell var only; never echo, never write to evidence files.
ADMIN_PW=$(journalctl -u snap.frigate.frigate --since "$MARK" 2>/dev/null \
    | grep -oP '(?<=\*\*\*    Password: )[0-9a-f]{32}(?=   \*\*\*)' | tail -1)
if [ -n "$ADMIN_PW" ]; then
    # POST to /api/login via HTTPS — proves full external TLS chain (-k = self-signed cert accepted)
    # Payload field: "user" not "username" (Task 1 verified shape, frigate/api/defs/request/app_body.py)
    LOGIN_STATUS=$(curl -sk --max-time 10 \
        -c /tmp/m5-gate-cookie.jar \
        -D /tmp/m5-gate-headers.txt \
        -H 'Content-Type: application/json' \
        -d "{\"user\":\"admin\",\"password\":\"$ADMIN_PW\"}" \
        -o /dev/null -w '%{http_code}' \
        https://127.0.0.1:8971/api/login 2>/dev/null)
    LOGIN_COOKIE=$(grep -i 'set-cookie' /tmp/m5-gate-headers.txt 2>/dev/null | grep -o 'frigate_token' | head -1 || echo "")
    check "auth: POST https://127.0.0.1:8971/api/login → 200" test "$LOGIN_STATUS" = "200"
    check "auth: login → frigate_token cookie set" test "$LOGIN_COOKIE" = "frigate_token"
    # Authenticated GET via HTTPS using the session cookie (THE M5 MONEY LINE)
    AUTHED_STATUS=$(curl -sk --max-time 5 \
        -b /tmp/m5-gate-cookie.jar \
        -o /dev/null -w '%{http_code}' \
        https://127.0.0.1:8971/api/version 2>/dev/null)
    check "auth: authed GET https://127.0.0.1:8971/api/version → 200 (M5 MONEY LINE)" test "$AUTHED_STATUS" = "200"
    echo "  auth finding: login=$LOGIN_STATUS cookie=frigate_token authed_get=$AUTHED_STATUS — JWT gate proven end-to-end"
    # Discard derived credentials (JWT in cookie jar + response headers — not the password)
    rm -f /tmp/m5-gate-cookie.jar /tmp/m5-gate-headers.txt
elif [ "$NVR_SAFE" -eq 1 ]; then
    # M8 B1: the bootstrap password is journal-logged ONLY on first boot after a purge (empty DB);
    # nvr-safe never purges, so it can NEVER appear since $MARK on an established install — a FAIL
    # here would be a deterministic false alarm, not a health signal. The login proof above stays
    # armed whenever a password IS found; the 401-unauthenticated gate check still ran unconditionally.
    echo "SKIP (nvr-safe): auth login money check (bootstrap password only logged on first boot after purge; unavailable by design without an install cycle)"
elif [ "${1:-}" = "--skip-install" ]; then
    # M8 Task 6 capability guard (extends the nvr-safe password-availability shape to the no-password
    # --skip-install case): --skip-install performs no purge/install cycle, so the first-boot bootstrap
    # password is never logged since $MARK — a FAIL here would be a deterministic false alarm, not a
    # health signal. The full purge gate still hard-asserts the login money line (password IS logged
    # there); the 401-unauthenticated gate check above ran unconditionally in every mode.
    echo "SKIP (--skip-install): auth: POST https://127.0.0.1:8971/api/login → 200 — bootstrap password only logged on first boot after a purge; no install/purge cycle this run"
    echo "SKIP (--skip-install): auth: login → frigate_token cookie set — bootstrap password unavailable without an install cycle"
    echo "SKIP (--skip-install): auth: authed GET https://127.0.0.1:8971/api/version → 200 (M5 MONEY LINE) — bootstrap password unavailable without an install cycle"
else
    fail_ "auth: POST https://127.0.0.1:8971/api/login → 200 (bootstrap password not in journal)"
    fail_ "auth: login → frigate_token cookie set"
    fail_ "auth: authed GET https://127.0.0.1:8971/api/version → 200 (M5 MONEY LINE)"
    echo "  auth finding: bootstrap password not found in journal — full gate (snap remove --purge) required"
fi

# Money check 4: port binding — :5000 and :5001 loopback-only; :8971 non-loopback
# :5001 loopback-only seals X-Server-Port spoofing surface (cannot forge port=5000 from off-host).
check "net: :5000 loopback-only (127.0.0.1:5000 bound)" sh -c "ss -tln | grep -q '127\.0\.0\.1:5000'"
check "net: :5000 NOT all-interfaces" sh -c "! ss -tln | grep -qE '0\.0\.0\.0:5000|\[\:\:\]:5000'"
check "net: :5001 loopback-only (127.0.0.1:5001 bound)" sh -c "ss -tln | grep -q '127\.0\.0\.1:5001'"
check "net: :5001 NOT all-interfaces (X-Server-Port spoofing surface sealed)" sh -c "! ss -tln | grep -qE '0\.0\.0\.0:5001|\[\:\:\]:5001'"
check "net: :8971 non-loopback (0.0.0.0:8971 bound)" sh -c "ss -tln | grep -q '0\.0\.0\.0:8971'"
# go2rtc control API/UI: loopback-only (controller ruling, final-review wave).
# Browsers reach go2rtc via nginx /live/* proxy; no anonymous LAN exposure.
check "net: :1984 loopback-only (127.0.0.1:1984 bound)" sh -c "ss -tln | grep -q '127\.0\.0\.1:1984'"
check "net: :1984 NOT all-interfaces (go2rtc control API/UI sealed)" sh -c "! ss -tln | grep -qE '0\.0\.0\.0:1984|\[\:\:\]:1984'"
ss -tln > "$EVIDENCE/ss-tln.txt" 2>/dev/null || true
echo "  net finding: $(grep -E ':5000|:5001|:8971|:1984' "$EVIDENCE/ss-tln.txt" 2>/dev/null | sed 's/  */ /g' | tr '\n' '|')"

if [ "$NVR_SAFE" -eq 0 ]; then
# Money check 5: certsync — automated cert-swap proof (Task 3 manual → automated)
# Swap the cert on disk; poll openssl s_client fingerprint; assert changed ≤90 s + journal reload line.
OLD_FP=$(echo "" | openssl s_client -connect 127.0.0.1:8971 2>/dev/null | openssl x509 -fingerprint -noout 2>/dev/null || echo "failed")
# Generate a new cert (RSA-2048 for speed in harness; different key → different fingerprint).
# -days 7: partial-re-run expiry cliff — -days 1 cert expires within the gate if anything
# stalls; 7 days gives a safe window without polluting the live cert store.
openssl req -new -newkey rsa:2048 -days 7 -nodes -x509 \
    -subj "/O=FRIGATE TEST CERT/CN=certsync-harness" \
    -keyout /tmp/m5-cs-key.pem \
    -out /tmp/m5-cs-cert.pem 2>/dev/null
CERT_DIR=/var/snap/$SNAP_NAME/current/letsencrypt/live/frigate
if [ -d "$CERT_DIR" ]; then
    cp /tmp/m5-cs-cert.pem "$CERT_DIR/fullchain.pem"
    cp /tmp/m5-cs-key.pem "$CERT_DIR/privkey.pem"
    SWAP_TS=$(date +%s)
    rm -f /tmp/m5-cs-key.pem /tmp/m5-cs-cert.pem
    # Poll up to 100 s (certsync interval = 60 s + nginx reload latency; assertion bound = 90 s)
    NEW_FP=""
    ELAPSED_CS=999
    for _cs_i in $(seq 1 20); do
        LIVE_FP=$(echo "" | openssl s_client -connect 127.0.0.1:8971 2>/dev/null | openssl x509 -fingerprint -noout 2>/dev/null || echo "failed")
        if [ "$LIVE_FP" != "failed" ] && [ "$LIVE_FP" != "$OLD_FP" ]; then
            NEW_FP="$LIVE_FP"
            ELAPSED_CS=$(( $(date +%s) - SWAP_TS ))
            break
        fi
        sleep 5
    done
    check "certsync: new fingerprint served after cert swap" test -n "$NEW_FP"
    check "certsync: cert swap → reload ≤90 s (elapsed=${ELAPSED_CS}s)" sh -c "[ $ELAPSED_CS -le 90 ]"
    RELOAD_LINE=$(journalctl -u snap.frigate.certsync --since "$MARK" 2>/dev/null | grep 'cert drift detected' | tail -1 || echo "")
    check "certsync: nginx reload logged in journal" test -n "$RELOAD_LINE"
    echo "  certsync finding: old_fp=$OLD_FP"
    echo "  certsync finding: new_fp=${NEW_FP:-not-changed} elapsed=${ELAPSED_CS}s"
    echo "  certsync finding: reload='${RELOAD_LINE:-not-found}'"
else
    fail_ "certsync: new fingerprint served after cert swap (cert dir not found: $CERT_DIR)"
    fail_ "certsync: cert swap → reload ≤90 s"
    fail_ "certsync: nginx reload logged in journal"
    echo "  certsync finding: ERROR — cert dir not found at $CERT_DIR"
    rm -f /tmp/m5-cs-key.pem /tmp/m5-cs-cert.pem
fi
else
  echo "SKIP (nvr-safe): certsync live cert swap"
fi

if [ "$NVR_SAFE" -eq 0 ]; then
# --- M3: rollback machinery (Task 4) ---
# Proof 1: refresh fires the pre-refresh hook -> backup exists.
# M8 Task 6 (T7 footgun): reuse the PINNED artifact and refuse to reinstall if the file changed
# identity since gate start (a stale build swapped in) — never silently install a different snap.
SNAP_FILE_SHA_NOW=$(sha256sum "$SNAP_FILE" 2>/dev/null | awk '{print $1}')
if [ -n "$SNAP_FILE_SHA" ] && [ "$SNAP_FILE_SHA_NOW" != "$SNAP_FILE_SHA" ]; then
  fail_ "rollback: pinned artifact identity changed mid-gate ($SNAP_FILE: $SNAP_FILE_SHA -> $SNAP_FILE_SHA_NOW) — refusing to reinstall a swapped build"
else
  snap install --dangerous "$SNAP_FILE" >/dev/null 2>&1 || fail_ "rollback: reinstall-refresh failed"
fi
sleep 25   # services restart; frigate re-gates on go2rtc
check "rollback: pre-refresh backup created" sh -c "ls /var/snap/frigate/common/db/backups/frigate-pre-*.db"
check "rollback: hook logged" sh -c "grep -q 'pre-refresh: backed up' /var/snap/frigate/common/db/backups/hook.log"
# Proof 2: forged newer sidecar -> restore path fires on restart.
echo "99.0.0 x999" > /var/snap/frigate/common/db/.last-writer
snap restart frigate.frigate
sleep 20
check "rollback: downgrade detected + restored" sh -c "journalctl --since \"$MARK\" | grep -q 'frigate-run: restored'"
check "rollback: incompatible db preserved" sh -c "ls /var/snap/frigate/common/db/frigate.db.incompatible-*"
check "rollback: frigate healthy after restore" sh -c "snap services frigate.frigate | grep -q ' active'"
else
  echo "SKIP (nvr-safe): rollback reinstall + sidecar forge + restart"
fi

if [ "$NVR_SAFE" -eq 0 ]; then
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
  # FINDING (M6 final review): a leftover backup from an aborted phase holds the GOOD
  # config (config.yml may still be coral) - never clobber it; the transform below reads
  # the backup, so a preserved backup also self-heals the aborted state.
  [ -f "$CORAL_CFG_BAK" ] || cp -p "$CORAL_CFG" "$CORAL_CFG_BAK"
  # Render the coral config by transforming the RENDERED file (preserves the livecam block +
  # credential; template block order is detectors: -> model: -> cameras:, so the replace region
  # is [^detectors:, ^cameras:) ). Never echo config contents (credential embedded).
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
  # TPU init markers land seconds AFTER /version answers (API and detector init in parallel;
  # gate run 3 evidence: 'TPU found' logged at +2 s, one-shot capture raced past it) — poll
  # the journal bounded (≤60 s), never sample once.
  TPU_FOUND=""
  for i in $(seq 1 12); do
    journalctl -u snap.frigate.frigate --since "$MARK_CORAL" 2>/dev/null | grep -q 'TPU found' && { TPU_FOUND=yes; break; }
    sleep 5
  done
  # M0 re-enumeration protocol: one bounded rerun if the TPU regressed to 1a6e
  # (delegate load uploads firmware; a mid-phase replug would need it again).
  if [ -z "$TPU_FOUND" ]; then
    if lsusb 2>/dev/null | grep -qi '1a6e:089a'; then
      snap run $SNAP_NAME.coral-probe >/dev/null 2>&1 || true
      snap restart $SNAP_NAME.frigate
      for i in $(seq 1 24); do
        sleep 5
        curl -sf --max-time 5 http://127.0.0.1:5001/version >/dev/null 2>&1 && { CORAL_UP=yes; break; }
      done
      for i in $(seq 1 12); do
        journalctl -u snap.frigate.frigate --since "$MARK_CORAL" 2>/dev/null | grep -q 'TPU found' && { TPU_FOUND=yes; break; }
        sleep 5
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
  # -> stats x1000) until real inferences move the average. CORRECTED M6 finding (gate run 3):
  # the looping testclip NEVER feeds the object detector on stock code — constant motion keeps
  # motion calibration engaged (improved_motion.py: calibration exits only when motion <5% and
  # contours <4) and only motion regions are sent to the detector; testclip detection_fps stays
  # 0.0 and inference_speed stays 10.0 on BOTH ov and coral. Inference drift therefore REQUIRES
  # the live camera (same dependency as the detection MONEY test, M3 re-ruling): livecam armed
  # -> hard-assert drift (120 s poll); livecam down -> hard-assert detector liveness on the TPU
  # config and SKIP drift (no frame source can reach any detector — environment, not packaging).
  if [ "$LIVECAM" = "yes" ]; then
    CORAL_SPEED=""
    for i in $(seq 1 24); do
      curl -sf --max-time 5 -H "Remote-User: admin" -H "Remote-Role: admin" \
        http://127.0.0.1:5001/stats 2>/dev/null | jq 'del(.cpu_usages)' > "$EVIDENCE/coral-phase-stats.json" 2>/dev/null || true
      if jq -e '.detectors.coral.pid > 0 and .detectors.coral.inference_speed != 10.0 and .detectors.coral.inference_speed > 0 and .detectors.coral.inference_speed < 100' \
          "$EVIDENCE/coral-phase-stats.json" >/dev/null 2>&1; then
        CORAL_SPEED=$(jq -r '.detectors.coral.inference_speed' "$EVIDENCE/coral-phase-stats.json")
        break
      fi
      sleep 5
    done
    check "coral phase MONEY: coral detector alive + inference_speed moved off 10.0 init default" test -n "$CORAL_SPEED"
    echo "  coral finding: inference_speed=${CORAL_SPEED:-none}ms (init default 10.0 exactly; drift = real TPU inferences)"
  else
    curl -sf --max-time 5 -H "Remote-User: admin" -H "Remote-Role: admin" \
      http://127.0.0.1:5001/stats 2>/dev/null | jq 'del(.cpu_usages)' > "$EVIDENCE/coral-phase-stats.json" 2>/dev/null || true
    check "coral phase: coral detector process alive on TPU config (pid > 0 in /stats)" \
      jq -e '.detectors.coral.pid > 0' "$EVIDENCE/coral-phase-stats.json"
    echo "SKIP: coral phase MONEY: inference_speed drift — $LIVECAM_SKIP_REASON; testclip cannot feed the detector (M3 calibration finding), so no inference source exists"
    echo "  coral finding: inference_speed=$(jq -r '.detectors.coral.inference_speed // "none"' "$EVIDENCE/coral-phase-stats.json" 2>/dev/null)ms (10.0 = init default; drift unprovable without livecam)"
  fi
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
      http://127.0.0.1:5001/stats 2>/dev/null | jq 'del(.cpu_usages)' > "$EVIDENCE/coral-phase-stats2.json" 2>/dev/null || true
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
  check "coral phase: frigate healthy after restore" sh -c "snap services frigate.frigate | grep -q ' active'"
else
  echo "SKIP: coral phase: API back up on coral config — no Coral USB attached (1a6e/18d1 absent)"
  echo "SKIP: coral phase: journal markers — no Coral USB attached"
  echo "SKIP: coral phase MONEY: inference_speed drift — no Coral USB attached"
  echo "SKIP: coral phase: person event — no Coral USB attached"
  echo "SKIP: coral phase: OpenVINO default restored — no Coral USB attached"
fi
else
  echo "SKIP (nvr-safe): Coral detector phase (config rewrite + restarts)"
fi

if [ "$NVR_SAFE" -eq 0 ]; then
# --- M7: snap-set surface + hardening (Task 5 — the M7 assertions) ---
# Guarded on the M7 config surface: the configure hook is a Task-2 addition, so its presence in
# the mounted snap distinguishes an M7 build from Task 1's remote artifact (built from kickoff
# HEAD, pre-Tasks-2-4). No surface → every M7 assertion emits an explicit SKIP (coral-style) so
# gate #2 (remote-artifact parity) stays green. `snap get ports.https` is a weaker OR probe (it
# only succeeds once the key is set), kept for completeness; the hook-file test is authoritative.
M7_CERT_DIR=/var/snap/$SNAP_NAME/current/letsencrypt/live/frigate
M7_CFG=/var/snap/$SNAP_NAME/current/config/config.yml
if [ -f "/snap/$SNAP_NAME/current/meta/hooks/configure" ] || snap get $SNAP_NAME ports.https >/dev/null 2>&1; then

  # (8) RENDER-ONCE GUARD — runs BEFORE anything that could regenerate config.yml. Setting the
  # `detector` key must NOT re-render config.yml (render-once; detector applies at the NEXT render
  # only, and the configure hook never touches config.yml or restarts frigate). sha256 (not cat —
  # config.yml carries the livecam credential) before/after must be byte-identical.
  M7_SHA_BEFORE=$(sha256sum "$M7_CFG" 2>/dev/null | awk '{print $1}')
  snap set $SNAP_NAME detector=cpu 2>/dev/null || fail_ "render-once: snap set detector=cpu (valid value) should succeed"
  sleep 3   # let the configure hook run (restarts nginx+certsync, deliberately NOT frigate)
  M7_SHA_AFTER=$(sha256sum "$M7_CFG" 2>/dev/null | awk '{print $1}')
  check "render-once: config.yml sha unchanged after snap set detector=cpu" sh -c "[ -n '$M7_SHA_BEFORE' ] && [ '$M7_SHA_BEFORE' = '$M7_SHA_AFTER' ]"
  snap unset $SNAP_NAME detector 2>/dev/null || true   # restore auto-detect (pristine)
  echo "  render-once finding: sha_before=${M7_SHA_BEFORE:0:12} sha_after=${M7_SHA_AFTER:0:12} (detector key is render-time-only; config.yml frozen)"

  # (9) FRESH-RENDER AUTO-DETECT — the config.yml rendered by the top-of-harness purge/reinstall
  # cycle (detector unset → auto-detect; this host has /dev/dri/renderD*) must have selected ov.
  # Non-secret grep only (count of a literal marker; never cat the credential-bearing file).
  # grep -c prints its count (even 0) AND exits 1 on zero matches, so a `|| echo 0` fallback would
  # append a spurious second line — capture the count directly and default only the file-missing case.
  M7_OV=$(grep -c 'type: openvino' "$M7_CFG" 2>/dev/null); M7_OV=${M7_OV:-0}
  M7_CPU=$(grep -c 'type: cpu' "$M7_CFG" 2>/dev/null); M7_CPU=${M7_CPU:-0}
  M7_CORAL=$(grep -c 'type: edgetpu' "$M7_CFG" 2>/dev/null); M7_CORAL=${M7_CORAL:-0}
  # M8 Task 6 hardware-aware guard: auto-detect selects ov ONLY when a real Intel/AMD render node is
  # present (the R3/M7 vendor guard); a headless VM (virtio-gpu) correctly renders type:cpu instead,
  # so these two ov-specific asserts SKIP there. On capable hardware they run untouched.
  if [ "$RENDER_NODE" = yes ]; then
    check "auto-detect: fresh render selected ov (renderD* present → type: openvino)" sh -c "[ '$M7_OV' -ge 1 ]"
    check "auto-detect: the other two detector blocks were stripped (exactly one rendered)" sh -c "[ '$M7_CPU' -eq 0 ] && [ '$M7_CORAL' -eq 0 ]"
  else
    echo "SKIP (no capability): auto-detect: fresh render selected ov (renderD* present → type: openvino) — $RENDER_NODE_REASON (auto-detect correctly selected cpu: type:openvino=$M7_OV type:cpu=$M7_CPU type:edgetpu=$M7_CORAL)"
    echo "SKIP (no capability): auto-detect: the other two detector blocks were stripped (exactly one rendered) — $RENDER_NODE_REASON"
  fi
  echo "  auto-detect finding: type:openvino=$M7_OV type:cpu=$M7_CPU type:edgetpu=$M7_CORAL (render-node present=$RENDER_NODE → $([ "$RENDER_NODE" = yes ] && echo ov || echo cpu); non-selected marker regions deleted at render)"

  # (6) LITERAL-SAFE RENDERER — the shipped renderer is a python str.replace (frigate-run), so a
  # URL with sed-hostile bytes (| & \) must survive byte-exact. Proof on SCRATCH paths with a TEST
  # url (never the real $SNAP_COMMON/livecam-url); the metacharacters are why the old sed renderer
  # was retired (M4 finding). str.replace is interpreter-independent, so a plain python3 is faithful.
  M7_SCRATCH=$(mktemp -d)
  M7_TESTURL='rtsp://user:p|a&b\c@camera.example:554/Streaming/Channels/101'
  printf '%s\n' "$M7_TESTURL" > "$M7_SCRATCH/url"
  printf 'cameras:\n  x:\n    ffmpeg:\n      inputs:\n        - path: __LIVECAM_URL__\n' > "$M7_SCRATCH/tmpl.yml"
  python3 - "$M7_SCRATCH/tmpl.yml" "$M7_SCRATCH/url" <<'EOF' 2>/dev/null || true
import sys
cfg = open(sys.argv[1]).read()
url = open(sys.argv[2]).read().strip()
open(sys.argv[1], "w").write(cfg.replace("__LIVECAM_URL__", url))
EOF
  check "renderer: literal-safe — |&\\ URL rendered byte-exact (scratch)" grep -qF "$M7_TESTURL" "$M7_SCRATCH/tmpl.yml"
  check "renderer: token fully substituted (no __LIVECAM_URL__ remains)" sh -c "! grep -q '__LIVECAM_URL__' '$M7_SCRATCH/tmpl.yml'"
  echo "  renderer finding: |&\\ URL byte-exact via python str.replace (sed metacharacter hazard retired, M4→M7)"
  rm -rf "$M7_SCRATCH"

  # (7) INVALID KEY REJECTION — the configure hook validates every key and exits non-zero on a bad
  # value, so `snap set` fails and snapd rolls the transaction back (value never committed, daemons
  # never restarted). `! snap set …` under check(): reject succeeds → 0 → PASS; a bad value slipping
  # through → snap set 0 → ! → 1 → FAIL. Daemon-state-untouched proven by nginx staying active.
  check "reject: ports.https=99999 (out of range) → snap set fails" sh -c "! snap set $SNAP_NAME ports.https=99999 2>/dev/null"
  check "reject: ports.https=abc (non-integer) → snap set fails" sh -c "! snap set $SNAP_NAME ports.https=abc 2>/dev/null"
  check "reject: tls.enabled=maybe → snap set fails" sh -c "! snap set $SNAP_NAME tls.enabled=maybe 2>/dev/null"
  check "reject: tls.cert-profile=rsa-1024 → snap set fails" sh -c "! snap set $SNAP_NAME tls.cert-profile=rsa-1024 2>/dev/null"
  check "reject: certsync.interval=5 (below min 10) → snap set fails" sh -c "! snap set $SNAP_NAME certsync.interval=5 2>/dev/null"
  check "reject: detector=gpu (not ov|coral|cpu) → snap set fails" sh -c "! snap set $SNAP_NAME detector=gpu 2>/dev/null"
  # Reserved-port rejection (M7 final review, CRITICAL — auth): ports.https=5000 would render the
  # external LAN listener on Frigate's internal auth-bypass port (X-Server-Port==5000 => anonymous
  # admin). The hook rejects the whole reserved set; assert both the failure AND that the surfaced
  # error mentions "reserved" (snapd surfaces the configure hook's stderr on a failed snap set).
  check "reject: ports.https=5000 (reserved — would bypass auth) → snap set fails, error mentions reserved" sh -c "snap set $SNAP_NAME ports.https=5000 2>&1 | grep -qi reserved"
  check "reject: daemon state untouched — nginx still active after rejected sets" sh -c "snap services $SNAP_NAME.nginx | grep -q ' active'"
  check "reject: bad value never committed — ports.https != 99999" sh -c "[ \"\$(snap get $SNAP_NAME ports.https 2>/dev/null)\" != 99999 ]"
  echo "  reject finding: 7 invalid snap-set values rolled back by the configure hook (incl. reserved ports.https=5000); nginx uninterrupted"

  # (1) PORT REBIND — snap set ports.https=9443 → configure hook restarts nginx → TLS on :9443;
  # reset (unset → default 8971) → original :8971 checks re-assert.
  snap set $SNAP_NAME ports.https=9443 2>/dev/null || fail_ "ports.https=9443: snap set (valid) should succeed"
  M7_9443=""
  for _i in $(seq 1 12); do ss -tln | grep -q '0\.0\.0\.0:9443' && { M7_9443=bound; break; }; sleep 2; done
  check "ports.https=9443: nginx TLS bound on 0.0.0.0:9443 (ss)" test "$M7_9443" = bound
  M7_C9443=""
  for _i in $(seq 1 6); do
    S=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://127.0.0.1:9443/ 2>/dev/null)
    [ "$S" = 200 ] && { M7_C9443=200; break; }; sleep 2
  done
  check "ports.https=9443: curl -k https://127.0.0.1:9443/ → 200" test "$M7_C9443" = 200
  snap unset $SNAP_NAME ports.https 2>/dev/null || true   # reset → default 8971 re-renders
  M7_8971=""
  for _i in $(seq 1 12); do ss -tln | grep -q '0\.0\.0\.0:8971' && { M7_8971=bound; break; }; sleep 2; done
  check "ports.https reset: nginx TLS bound back on 0.0.0.0:8971 (ss)" test "$M7_8971" = bound
  check "ports.https reset: 9443 no longer bound" sh -c "! ss -tln | grep -q '0\.0\.0\.0:9443'"
  M7_C8971=""
  for _i in $(seq 1 6); do
    S=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://127.0.0.1:8971/ 2>/dev/null)
    [ "$S" = 200 ] && { M7_C8971=200; break; }; sleep 2
  done
  check "ports.https reset: curl -k https://127.0.0.1:8971/ → 200 (original re-asserted)" test "$M7_C8971" = 200
  echo "  ports finding: 9443 bound=$M7_9443 curl=$M7_C9443 → reset 8971 bound=$M7_8971 curl=$M7_C8971"

  # (3) CERTSYNC INTERVAL — snap set certsync.interval=15 → cert-swap reload observed ≤45 s (vs the
  # old 90 s bound at interval=60). Same swap machinery as the M5 money check, tighter deadline.
  snap set $SNAP_NAME certsync.interval=15 2>/dev/null || fail_ "certsync.interval=15: snap set (valid) should succeed"
  for _i in 1 2 3 4 5 6; do snap services $SNAP_NAME.certsync | grep -q ' active' && break; sleep 2; done
  sleep 3   # certsync cold-start pid gate (nginx.pid already present → passes fast)
  M7_CS_OLD=$(echo "" | openssl s_client -connect 127.0.0.1:8971 2>/dev/null | openssl x509 -fingerprint -noout 2>/dev/null || echo failed)
  openssl req -new -newkey rsa:2048 -days 7 -nodes -x509 \
      -subj "/O=FRIGATE TEST CERT/CN=certsync-i15" \
      -keyout /tmp/m7-cs15-key.pem -out /tmp/m7-cs15-cert.pem 2>/dev/null
  if [ -d "$M7_CERT_DIR" ]; then
    cp /tmp/m7-cs15-cert.pem "$M7_CERT_DIR/fullchain.pem"
    cp /tmp/m7-cs15-key.pem  "$M7_CERT_DIR/privkey.pem"
    M7_CS_SWAP=$(date +%s)
    rm -f /tmp/m7-cs15-key.pem /tmp/m7-cs15-cert.pem
    M7_CS_NEW=""; M7_CS_EL=999
    for _i in $(seq 1 12); do   # 12×4 s = 48 s ceiling; assertion bound 45 s (interval 15 + reload)
      LFP=$(echo "" | openssl s_client -connect 127.0.0.1:8971 2>/dev/null | openssl x509 -fingerprint -noout 2>/dev/null || echo failed)
      if [ "$LFP" != failed ] && [ "$LFP" != "$M7_CS_OLD" ]; then M7_CS_NEW="$LFP"; M7_CS_EL=$(( $(date +%s) - M7_CS_SWAP )); break; fi
      sleep 4
    done
    check "certsync.interval=15: new fingerprint served after cert swap" test -n "$M7_CS_NEW"
    check "certsync.interval=15: cert swap → reload ≤45 s (elapsed=${M7_CS_EL}s)" sh -c "[ $M7_CS_EL -le 45 ]"
    echo "  certsync15 finding: elapsed=${M7_CS_EL}s at interval=15 (was bounded 90 s at interval=60)"
  else
    fail_ "certsync.interval=15: new fingerprint served after cert swap (cert dir absent: $M7_CERT_DIR)"
    fail_ "certsync.interval=15: cert swap → reload ≤45 s"
    rm -f /tmp/m7-cs15-key.pem /tmp/m7-cs15-cert.pem
  fi
  snap unset $SNAP_NAME certsync.interval 2>/dev/null || true   # reset → 60 s default

  # (2) CERT PROFILE — snap set tls.cert-profile=ecdsa-p256 → DELETE the cert files → restart nginx
  # (regeneration only fires when no cert is on disk) → served leaf is EC / P-256. Then reset
  # (unset → rsa-4096 default) → delete → restart → RSA-4096 regenerates. Runs LAST of the TLS items
  # so the block ends on the clean RSA-4096 default. Gen-time comparison measured directly on scratch
  # (restart-to-served latency also folds in nginx boot, so it is not a clean gen figure).
  M7_ECT=$(mktemp -d)
  M7_T0=$(date +%s.%N); openssl req -new -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 -days 7 -subj "/O=T/CN=x" -keyout "$M7_ECT/e.key" -out "$M7_ECT/e.crt" 2>/dev/null; M7_T1=$(date +%s.%N)
  M7_T2=$(date +%s.%N); openssl req -new -newkey rsa:4096 -days 7 -nodes -x509 -subj "/O=T/CN=x" -keyout "$M7_ECT/r.key" -out "$M7_ECT/r.crt" 2>/dev/null; M7_T3=$(date +%s.%N)
  M7_ECGEN=$(awk -v a="$M7_T0" -v b="$M7_T1" 'BEGIN{printf "%.2f", b-a}')
  M7_RSGEN=$(awk -v a="$M7_T2" -v b="$M7_T3" 'BEGIN{printf "%.2f", b-a}')
  rm -rf "$M7_ECT"
  snap set $SNAP_NAME tls.cert-profile=ecdsa-p256 2>/dev/null || fail_ "tls.cert-profile=ecdsa-p256: snap set (valid) should succeed"
  if [ -d "$M7_CERT_DIR" ]; then
    rm -f "$M7_CERT_DIR/privkey.pem" "$M7_CERT_DIR/fullchain.pem"
    snap restart $SNAP_NAME.nginx 2>/dev/null || true
    M7_EC_SERVED=""
    for _i in $(seq 1 12); do
      echo "" | openssl s_client -connect 127.0.0.1:8971 2>/dev/null | openssl x509 -text -noout 2>/dev/null > "$EVIDENCE/m7-ecdsa-cert.txt" || true
      grep -q 'id-ecPublicKey' "$EVIDENCE/m7-ecdsa-cert.txt" && { M7_EC_SERVED=yes; break; }
      sleep 3
    done
    check "cert-profile ecdsa-p256: served leaf is EC (id-ecPublicKey)" test "$M7_EC_SERVED" = yes
    check "cert-profile ecdsa-p256: served leaf curve is P-256" grep -q 'NIST CURVE: P-256' "$EVIDENCE/m7-ecdsa-cert.txt"
    # reset to the RSA-4096 default and force regeneration the same way
    snap unset $SNAP_NAME tls.cert-profile 2>/dev/null || true
    rm -f "$M7_CERT_DIR/privkey.pem" "$M7_CERT_DIR/fullchain.pem"
    snap restart $SNAP_NAME.nginx 2>/dev/null || true
    M7_RS_SERVED=""
    for _i in $(seq 1 12); do
      echo "" | openssl s_client -connect 127.0.0.1:8971 2>/dev/null | openssl x509 -text -noout 2>/dev/null > "$EVIDENCE/m7-rsa-cert.txt" || true
      grep -q 'rsaEncryption' "$EVIDENCE/m7-rsa-cert.txt" && { M7_RS_SERVED=yes; break; }
      sleep 3
    done
    check "cert-profile reset: RSA-4096 default regenerated (rsaEncryption served)" test "$M7_RS_SERVED" = yes
    check "cert-profile reset: served RSA key is 4096-bit" grep -q 'Public-Key: (4096 bit)' "$EVIDENCE/m7-rsa-cert.txt"
    echo "  cert-profile finding: ecdsa-p256 served=$M7_EC_SERVED (P-256), rsa-4096 restored=$M7_RS_SERVED; gen-time ecdsa=${M7_ECGEN}s vs rsa-4096=${M7_RSGEN}s (scratch openssl)"
  else
    snap unset $SNAP_NAME tls.cert-profile 2>/dev/null || true
    fail_ "cert-profile ecdsa-p256: served leaf is EC (cert dir absent: $M7_CERT_DIR)"
    fail_ "cert-profile reset: RSA-4096 default regenerated"
  fi

  # (4) VERSIONED-BACKUP RESTORE SELECTION — forge three stamped backups and a newer-than-code
  # sidecar; frigate-run's downgrade-restore must pick the newest backup whose version ≤ current
  # (0.17.2), skipping the too-new 99.0.0 and the older 0.16.0. A fresh mark isolates this restore
  # from the earlier rollback-machinery restore already in the journal since $MARK.
  M7_BKDIR=/var/snap/$SNAP_NAME/common/db/backups
  M7_DB=/var/snap/$SNAP_NAME/common/db/frigate.db
  if [ -f "$M7_DB" ] && [ -d "$M7_BKDIR" ]; then
    cp "$M7_DB" "$M7_BKDIR/frigate-pre-0.16.0-r1.db"
    cp "$M7_DB" "$M7_BKDIR/frigate-pre-0.17.2-r2.db"
    cp "$M7_DB" "$M7_BKDIR/frigate-pre-99.0.0-r3.db"
    echo "99.0.0 x999" > /var/snap/$SNAP_NAME/common/db/.last-writer   # newer-than-code → downgrade path
    M7_MARK4=$(date '+%Y-%m-%d %H:%M:%S')
    snap restart $SNAP_NAME.frigate 2>/dev/null || true
    sleep 20
    journalctl -u snap.$SNAP_NAME.frigate --since "$M7_MARK4" 2>/dev/null | grep 'frigate-run: restored' | tail -1 > "$EVIDENCE/m7-backup-restore.txt" || true
    check "backup-select: restore fired on forged newer sidecar" test -s "$EVIDENCE/m7-backup-restore.txt"
    check "backup-select: chose a 0.17.2 backup (newest ≤ current)" grep -q 'frigate-pre-0\.17\.2-r' "$EVIDENCE/m7-backup-restore.txt"
    check "backup-select: never chose the too-new 99.0.0 backup" sh -c "! grep -q 'frigate-pre-99\.0\.0' '$EVIDENCE/m7-backup-restore.txt'"
    check "backup-select: never chose the older 0.16.0 backup" sh -c "! grep -q 'frigate-pre-0\.16\.0' '$EVIDENCE/m7-backup-restore.txt'"
    check "backup-select: too-new 99.0.0 backup left intact (copy-not-consume)" test -f "$M7_BKDIR/frigate-pre-99.0.0-r3.db"
    check "backup-select: frigate healthy after restore" sh -c "snap services $SNAP_NAME.frigate | grep -q ' active'"
    echo "  backup-select finding: $(sed 's/.*frigate-run: //' "$EVIDENCE/m7-backup-restore.txt" 2>/dev/null) (0.17.2 chosen; 99.0.0 skipped as newer-schema; 0.16.0 skipped as older)"
    rm -f "$M7_BKDIR/frigate-pre-0.16.0-r1.db" "$M7_BKDIR/frigate-pre-0.17.2-r2.db" "$M7_BKDIR/frigate-pre-99.0.0-r3.db"
  else
    fail_ "backup-select: restore fired on forged newer sidecar (db or backups dir absent)"
  fi

  # (5) LOGROTATE — seed a >10 MB log matching the conf glob, run the oneshot manually, observe the
  # size-triggered rotation (copytruncate: .1 created, original truncated). Dedicated harness log so
  # nginx's own live logs are untouched.
  M7_NLOG=/var/snap/$SNAP_NAME/current/nginx/logs
  mkdir -p "$M7_NLOG"
  M7_ROT="$M7_NLOG/harness-rotate.log"
  dd if=/dev/zero bs=1M count=11 2>/dev/null | tr '\0' 'x' > "$M7_ROT"   # 11 MiB, non-empty (> size 10M)
  snap run $SNAP_NAME.logrotate 2>/dev/null || true
  sleep 2
  check "logrotate: >10 MB log rotated (harness-rotate.log.1 created)" test -f "$M7_ROT.1"
  check "logrotate: original truncated after copytruncate (< 10 MB)" sh -c "[ \"\$(stat -c %s '$M7_ROT' 2>/dev/null || echo 99999999)\" -lt 10485760 ]"
  echo "  logrotate finding: rotated .1 size=$(stat -c %s "$M7_ROT.1" 2>/dev/null || echo NA) orig-now=$(stat -c %s "$M7_ROT" 2>/dev/null || echo NA) bytes (size 10M trigger, copytruncate, rotate 3)"
  rm -f "$M7_ROT" "$M7_ROT".*

else
  echo "SKIP: m7 render-once guard (detector snap-set) — no M7 config surface (configure hook absent; pre-M7 remote artifact)"
  echo "SKIP: m7 auto-detect fresh render (ov) — no M7 config surface"
  echo "SKIP: m7 literal-safe renderer (|&\\ byte-exact) — no M7 config surface"
  echo "SKIP: m7 invalid-key rejection (snap set non-zero) — no M7 config surface"
  echo "SKIP: m7 ports.https=9443 live rebind + reset — no M7 config surface"
  echo "SKIP: m7 certsync.interval=15 fast reload (≤45 s) — no M7 config surface"
  echo "SKIP: m7 tls.cert-profile ecdsa-p256 / rsa-4096 — no M7 config surface"
  echo "SKIP: m7 versioned-backup restore selection (0.17.2 over 99.0.0) — no M7 config surface"
  echo "SKIP: m7 logrotate >10 MB rotation — no M7 config surface"
fi
else
  echo "SKIP (nvr-safe): M7 snap-set block (set/unset/cert-regen/backup-forge/logrotate seed)"
fi

if [ "$NVR_SAFE" -eq 0 ]; then
# ===================== go2rtc config bridge + integration (PR#3) =============================
# Proves: (1) the operator's config.yml go2rtc: section reaches go2rtc (the config bridge);
# (2) the control API stays loopback-sealed after the merge (M5 seal); (3) frigate ITSELF can
# reach go2rtc; (4) the Web-UI /logs API no longer 500s; (5) the Web-UI Restart endpoint brings
# frigate back (restart-condition: always). Stream bodies are piped to grep, never persisted
# (they may carry the operator's camera credentials).
BRIDGE_CFG="/var/snap/$SNAP_NAME/current/config/config.yml"
BRIDGE_PY="/snap/$SNAP_NAME/current/usr/bin/python3.11"
if [ -f "$BRIDGE_CFG" ] && [ -x "$BRIDGE_PY" ]; then
  # Backup (trap-guarded via BRIDGE_CFG_BAK) then inject a defined-but-idle stream INTO the
  # operator's go2rtc.streams using the snap's yaml-aware python — preserves their cameras, never
  # prints config contents, writes 0600 (mode preserved by open('w') on the pre-0600 file).
  BRIDGE_CFG_BAK=$(mktemp); cp -p "$BRIDGE_CFG" "$BRIDGE_CFG_BAK"
  "$BRIDGE_PY" - "$BRIDGE_CFG" <<'PYEOF'
import os, sys, yaml
p = sys.argv[1]
with open(p) as f:
    cfg = yaml.safe_load(f) or {}
if not isinstance(cfg, dict):
    cfg = {}
g = cfg.get("go2rtc")
if not isinstance(g, dict):
    g = {}
s = g.get("streams")
if not isinstance(s, dict):
    s = {}
s["bridgeproof"] = "exec:true"   # defined-but-idle: appears in /api/streams, runs nothing
g["streams"] = s
cfg["go2rtc"] = g
os.umask(0o077)
with open(p, "w") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False)
PYEOF
  snap restart $SNAP_NAME 2>/dev/null || true
  # Bounded wait for frigate API (implies go2rtc :1984 is up — frigate starts after go2rtc).
  _b=0; while [ "$_b" -lt 120 ]; do curl -sf --max-time 3 http://127.0.0.1:5001/version >/dev/null 2>&1 && break; sleep 3; _b=$((_b+3)); done
  echo "  bridge finding: frigate API answered ${_b}s after whole-snap restart (bridgeproof injected)"
  # (1) the injected stream reached go2rtc's runtime config:
  if curl -sf --max-time 5 http://127.0.0.1:1984/api/streams 2>/dev/null | grep -q bridgeproof; then
    pass_ "bridge: config.yml go2rtc: section reaches go2rtc (bridgeproof stream present)"
  else
    fail_ "bridge: config.yml go2rtc: section reaches go2rtc (bridgeproof stream present)"
  fi
  # (2) M5 seal MUST still hold after merging the operator section (api.listen forced loopback):
  check "bridge: :1984 STILL loopback-only after config merge (M5 seal intact)" \
    sh -c "ss -tln | grep -q '127\.0\.0\.1:1984' && ! ss -tln | grep -qE '0\.0\.0\.0:1984|\[\:\:\]:1984'"
  # (3) frigate ITSELF reaches go2rtc — its /go2rtc/streams proxy (client target is hardcoded
  # http://127.0.0.1:1984/api/streams, camera.py) returns 200 AND lists bridgeproof. Chosen over
  # asserting absence of the "Failed to fetch streams" log line: this exercises the exact client
  # path AND confirms the bridge stream is what frigate sees (the stronger proof).
  BRIDGE_F2G=$(curl -s -o /dev/null -w '%{http_code}' -H 'Remote-User: admin' --max-time 5 http://127.0.0.1:5001/go2rtc/streams 2>/dev/null)
  check "bridge: frigate reaches go2rtc (/go2rtc/streams HTTP 200)" test "$BRIDGE_F2G" = "200"
  if curl -s -H 'Remote-User: admin' --max-time 5 http://127.0.0.1:5001/go2rtc/streams 2>/dev/null | grep -q bridgeproof; then
    pass_ "bridge: frigate sees bridgeproof via its own go2rtc client"
  else
    fail_ "bridge: frigate sees bridgeproof via its own go2rtc client"
  fi
  echo "  bridge finding: frigate->go2rtc /go2rtc/streams http=$BRIDGE_F2G (client target 127.0.0.1:1984)"
  # Restore the operator's pristine config (byte-exact) and re-cycle so go2rtc drops bridgeproof.
  # Review fix: rm the backup only after the restore copy succeeded (trap retries otherwise).
  if cp -p "$BRIDGE_CFG_BAK" "$BRIDGE_CFG"; then rm -f "$BRIDGE_CFG_BAK"; BRIDGE_CFG_BAK=""; fi
  snap restart $SNAP_NAME 2>/dev/null || true
  _b=0; while [ "$_b" -lt 120 ]; do curl -sf --max-time 3 http://127.0.0.1:5001/version >/dev/null 2>&1 && break; sleep 3; _b=$((_b+3)); done
  check "bridge: frigate healthy again after config restore (:5001/version, ${_b}s)" \
    sh -c "curl -sf --max-time 5 http://127.0.0.1:5001/version >/dev/null 2>&1"
else
  echo "SKIP: bridge: config bridge proof — no operator config.yml or snap python (fresh/absent install)"
fi
else
  echo "SKIP (nvr-safe): go2rtc bridge injection + whole-snap restarts"
fi

# (4) Fix 3 — the Web-UI /logs API no longer 500s. It reads /dev/shm/logs/<svc>/current;
# frigate-run creates them (nginx/current -> real error.log; M8: frigate/current is the tee sink,
# go2rtc/current a symlink to $SNAP_DATA/go2rtc-logs/current — both carry real daemon stdout).
# Route is /logs/{service} with NO /api prefix on the internal :5001 (M3 route discipline);
# allow_any_authenticated() needs a Remote-User header. A 500 here is the undefined.length crash.
BRIDGE_LOGS=$(curl -s -o /dev/null -w '%{http_code}' -H 'Remote-User: admin' --max-time 5 http://127.0.0.1:5001/logs/nginx 2>/dev/null)
check "logs: /logs/nginx returns 200 (UI /logs page no longer crashes)" test "$BRIDGE_LOGS" = "200"
echo "  logs finding: GET :5001/logs/nginx http=$BRIDGE_LOGS (was 500 pre-fix; s6-log paths satisfied)"

# M8 Task 7: /logs full tee-parity. frigate-run and go2rtc-run now tee each daemon's stdout+stderr
# into /dev/shm/logs/{frigate,go2rtc}/current (go2rtc via a $SNAP_DATA symlink — no shm-private plug)
# using bash process substitution, so the previously-empty frigate/go2rtc tabs carry real output.
# Same curl shape as the nginx check (Remote-User on :5001); bodies piped to grep -q ONLY — never
# persisted to $EVIDENCE (daemon stdout can echo camera/producer URLs with credentials).
# M8 Task 6 capability guard (version-skew, mirrors the other hardware-aware guards): these
# tee-content checks assert real daemon stdout landed in the /logs sinks — which requires the
# INSTALLED snap to carry the M8 Task 7 tee-parity wrappers. On a production host still running a
# PRE-tee revision the sinks are empty placeholders, so probe the installed frigate-run for the tee
# line (host-readable): has tee → assert as written; predates tee → SKIP (refresh pending). The full
# gate always runs the fresh artifact (tee present → asserts); only a not-yet-refreshed host SKIPs.
if grep -q 'tee -a /dev/shm/logs/frigate/current' "/snap/$SNAP_NAME/current/bin/frigate-run" 2>/dev/null; then
  check "m8: /logs frigate tab has real content (process-sub tee wrote daemon stdout)" sh -c \
    "curl -s -H 'Remote-User: admin' --max-time 5 http://127.0.0.1:5001/logs/frigate 2>/dev/null | grep -q 'frigate'"
  check "m8: /logs go2rtc tab has real content (tee -> \$SNAP_DATA symlink)" sh -c \
    "curl -s -H 'Remote-User: admin' --max-time 5 http://127.0.0.1:5001/logs/go2rtc 2>/dev/null | grep -qiE 'go2rtc|\[api\]|listen'"
else
  echo "SKIP (version-skew): /logs frigate content — installed snap predates tee-parity (refresh pending)"
  echo "SKIP (version-skew): /logs go2rtc content — installed snap predates tee-parity (refresh pending)"
fi
# Passthrough: the tee's own stdout inherits the journal socket, so journald must STILL receive
# frigate lines after the change. grep -q . (non-empty) only — no journal excerpt persisted.
check "m8: journald still receives frigate lines (tee passthrough)" sh -c \
  "journalctl -u snap.$SNAP_NAME.frigate.service --since \"$MARK\" | grep -q ."

# M8 Task 7 — go2rtc crash-propagation proof (FULL-GATE ONLY: kills the go2rtc daemon, which
# --nvr-safe must never do to the production NVR). The tee is a bash PROCESS SUBSTITUTION, not a
# `daemon | tee` pipe, so the go2rtc binary stays the unit's MainPID: a kill -9 is seen by systemd
# as a unit failure and the on-failure restart-condition relaunches it. A pipe would make tee/the
# shell the MainPID and swallow the daemon's exit — so this proves exit-code/signal propagation
# survived the tee. journalctl grepped with -q ONLY (no excerpt persisted).
if [ "${NVR_SAFE:-0}" -eq 0 ]; then
  M8_G2_MARK="$(date '+%Y-%m-%d %H:%M:%S')"
  M8_G2_PID=$(systemctl show snap.$SNAP_NAME.go2rtc.service -p MainPID --value 2>/dev/null)
  if [ -n "$M8_G2_PID" ] && [ "$M8_G2_PID" != "0" ]; then
    kill -9 "$M8_G2_PID" 2>/dev/null || true
    _b=0; M8_G2_UP=""; M8_G2_NEWPID=""
    while [ "$_b" -lt 30 ]; do
      if systemctl is-active snap.$SNAP_NAME.go2rtc.service >/dev/null 2>&1; then
        M8_G2_NEWPID=$(systemctl show snap.$SNAP_NAME.go2rtc.service -p MainPID --value 2>/dev/null)
        [ -n "$M8_G2_NEWPID" ] && [ "$M8_G2_NEWPID" != "0" ] && [ "$M8_G2_NEWPID" != "$M8_G2_PID" ] && { M8_G2_UP=yes; break; }
      fi
      sleep 2; _b=$((_b+2))
    done
    check "m8: go2rtc relaunched after kill -9 (on-failure survived process-sub tee, ${_b}s)" \
      test "$M8_G2_UP" = yes
    check "m8: journald shows go2rtc kill+restart (exit-code propagation)" sh -c \
      "journalctl -u snap.$SNAP_NAME.go2rtc.service --since \"$M8_G2_MARK\" | grep -qiE 'killed|status=9|signal|scheduled restart|main process exited'"
    echo "  m8 finding: go2rtc MainPID $M8_G2_PID -> ${M8_G2_NEWPID:-none} after SIGKILL (${_b}s; on-failure relaunch proves the process-sub tee did not intercept the daemon's exit)"
  else
    fail_ "m8: go2rtc MainPID resolvable for crash-propagation proof"
  fi
else
  echo "SKIP (nvr-safe): m8 go2rtc crash-propagation kill -9 (would kill the production go2rtc)"
fi

if [ "$NVR_SAFE" -eq 0 ]; then
# (5) Fix 4 — the Web-UI Restart button. restart_frigate() SIGINTs frigate (clean exit, pid1 is
# not s6-svscan); restart-condition: always brings it back. POST /restart (require_role admin ->
# Remote-Role header) on :5001, then bound-wait for recovery. Placed AFTER the bridge proof so it
# never disturbs the bridge's own state.
curl -s -o /dev/null -X POST -H 'Remote-User: admin' -H 'Remote-Role: admin' --max-time 5 http://127.0.0.1:5001/restart 2>/dev/null || true
echo "  restart finding: POST :5001/restart issued (frigate self-SIGINT; awaiting always-restart)"
_b=0; while [ "$_b" -lt 120 ]; do
  if snap services $SNAP_NAME.frigate 2>/dev/null | grep -q ' active' && curl -sf --max-time 3 http://127.0.0.1:5001/version >/dev/null 2>&1; then break; fi
  sleep 3; _b=$((_b+3))
done
check "restart: frigate.frigate active again after UI restart (restart-condition: always)" \
  sh -c "snap services $SNAP_NAME.frigate | grep -q ' active'"
check "restart: frigate API answers again after UI restart (:5001/version)" \
  sh -c "curl -sf --max-time 5 http://127.0.0.1:5001/version >/dev/null 2>&1"
echo "  restart finding: recovery after ${_b}s (clean-exit self-restart proven; on-failure would stay DOWN)"
else
  echo "SKIP (nvr-safe): UI-restart POST /restart"
fi

# ===================== M8: semantic search (R4 — sqlite-vec loadable extension) =============
# Proves the R4 fix: with --enable-loadable-sqlite-extensions in the python build and vec0.so
# staged at /usr/local/lib (layout-resolved), enabling semantic_search lets frigate load the
# sqlite-vec extension via frigate/db/sqlitevecq.py's hardcoded conn.load_extension('/usr/local/lib/vec0')
# WITHOUT the R4 signature ("enable_load_extension" AttributeError / "no such module: vec"). DESTRUCTIVE
# (config mutation + frigate restart) — gated out of --nvr-safe. Mirrors the bridge block:
# backup config -> inject semantic_search.enabled -> restart frigate -> assert -> restore -> restart.
# Journal is grepped with -q ONLY (no excerpts persisted — frigate logs may echo config values).
if [ "$NVR_SAFE" -eq 0 ]; then
M8_SEM_CFG="/var/snap/$SNAP_NAME/current/config/config.yml"
M8_SEM_PY="/snap/$SNAP_NAME/current/usr/bin/python3.11"
if [ -f "$M8_SEM_CFG" ] && [ -x "$M8_SEM_PY" ]; then
  # Backup (trap-guarded via M8_SEM_CFG_BAK) then merge semantic_search.enabled: true into the
  # operator's config, preserving their cameras/keys — yaml-aware, never prints config, writes 0600.
  M8_SEM_CFG_BAK=$(mktemp); cp -p "$M8_SEM_CFG" "$M8_SEM_CFG_BAK"
  "$M8_SEM_PY" - "$M8_SEM_CFG" <<'PYEOF'
import os, sys, yaml
p = sys.argv[1]
with open(p) as f:
    cfg = yaml.safe_load(f) or {}
if not isinstance(cfg, dict):
    cfg = {}
ss = cfg.get("semantic_search")
if not isinstance(ss, dict):
    ss = {}
ss["enabled"] = True
cfg["semantic_search"] = ss
os.umask(0o077)
with open(p, "w") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False)
PYEOF
  # Mark the journal window at the restart instant so the vec-load grep only sees this enablement.
  M8_SEM_MARK="$(date '+%Y-%m-%d %H:%M:%S')"
  snap restart $SNAP_NAME.frigate 2>/dev/null || true
  # Bounded wait for frigate API. The sqlite-vec extension loads at DB-connect during app init
  # (app.py: load_vec_extension=semantic_search.enabled), BEFORE the API answers — so a healthy
  # :5001/version implies the extension loaded (a missing-flag build would crash-loop here instead).
  _b=0; while [ "$_b" -lt 120 ]; do curl -sf --max-time 3 http://127.0.0.1:5001/version >/dev/null 2>&1 && break; sleep 3; _b=$((_b+3)); done
  echo "  m8 finding: frigate API answered ${_b}s after restart with semantic_search enabled"
  # (1) R4 DEFECT SIGNATURE (load-bearing): NO sqlite-vec extension-load error in the window.
  #     Independent of the first-enable Jina/CLIP model download (that runs later, in the embeddings
  #     maintainer) — the vec load is at DB connect. grep -q ONLY; no journal excerpt persisted.
  check "m8: semantic search up (no sqlite-vec load error)" sh -c \
    "! journalctl -u snap.$SNAP_NAME.frigate.service --since \"$M8_SEM_MARK\" | grep -qiE 'enable_load_extension|sqlite.*extension.*(error|not authorized)|no such module: vec'"
  # (2) The embeddings maintainer came up (semantic_search runtime started). M8 Task 6 env-aware
  #     guard (per the Task 2 reviewer deferral): the load-error-ABSENCE assertion above stays HARD
  #     (that is the R4 signature). The embeddings-STARTED line, however, is gated on the first-enable
  #     Jina/CLIP model download, which is network-gated and needs a detector — in a headless/offline
  #     VM it may not complete within the bound. So poll for it up to ~60s; PASS if observed, else SKIP
  #     with the model-download reason (never a FAIL on a network/model-gated environment).
  M8_EMB=""
  for _e in $(seq 1 12); do
    journalctl -u snap.$SNAP_NAME.frigate.service --since "$M8_SEM_MARK" 2>/dev/null | grep -qiE 'embeddings' && { M8_EMB=yes; break; }
    sleep 5
  done
  if [ "$M8_EMB" = yes ]; then
    pass_ "m8: embeddings maintainer started"
  else
    echo "SKIP (no capability): m8: embeddings maintainer started — embeddings line not observed within ~60s bound; first-enable Jina/CLIP model download is network-gated (and detector-dependent) and may not have completed in this environment (R4 vec-load signature above stays hard-asserted)"
  fi
  echo "  m8 finding: R4 fix exercised — vec0 loaded via conn.load_extension('/usr/local/lib/vec0'); first enable downloads Jina CLIP v1 models to \$SNAP_DATA/config/model_cache (network-gated, sizes not asserted)"
  # Restore the operator's pristine config (byte-exact) and restart so semantic_search drops.
  if cp -p "$M8_SEM_CFG_BAK" "$M8_SEM_CFG"; then rm -f "$M8_SEM_CFG_BAK"; M8_SEM_CFG_BAK=""; fi
  snap restart $SNAP_NAME.frigate 2>/dev/null || true
  _b=0; while [ "$_b" -lt 120 ]; do curl -sf --max-time 3 http://127.0.0.1:5001/version >/dev/null 2>&1 && break; sleep 3; _b=$((_b+3)); done
  check "m8: frigate healthy again after semantic_search restore (:5001/version, ${_b}s)" \
    sh -c "curl -sf --max-time 5 http://127.0.0.1:5001/version >/dev/null 2>&1"
else
  echo "SKIP: m8 semantic search — no operator config.yml or snap python (fresh/absent install)"
fi
else
  echo "SKIP (nvr-safe): m8 semantic search (config mutation + restart)"
fi

# Operator config survived the whole gate byte-identical (purge stash + bridge mutate/restore).
if [ -n "$OPERATOR_CFG_SHA" ]; then
  BRIDGE_NOW_SHA=$(sha256sum "/var/snap/$SNAP_NAME/current/config/config.yml" 2>/dev/null | awk '{print $1}')
  check "operator-config: config.yml byte-identical after the gate (sha256 match)" test "$BRIDGE_NOW_SHA" = "$OPERATOR_CFG_SHA"
  echo "  operator-config finding: pre=$OPERATOR_CFG_SHA post=$BRIDGE_NOW_SHA (content never printed)"
else
  echo "SKIP: operator-config: survival sha check — no operator config.yml stashed (fresh host)"
fi

# --- AppArmor denial scan (keep last) ---
journalctl -k --since "$MARK" | grep -E "apparmor=\"DENIED\".*snap\.$SNAP_NAME" \
  > "$EVIDENCE/denials.txt" || true
# Known expected denials (FINDINGS, not bugs) — enumerated EXACTLY; any new denial pattern must
# fail the run and be triaged before being added here:
#   psm_        - imports-probe: unnamespaced POSIX shm denial (M0 Task 3 finding; re-homed M8 Task 5)
#   name="/config/ - layout probe: /config not in layout (Task 5 finding)
#   operation="create".*class="net".*comm="python3 - tensorflow/openvino python3 socket creation
#                 at import time (inet/inet6, telemetry). comm-bound + profile-agnostic; the
#                 imports-probe app now holds the 'network' plug so its own imports run clean —
#                 arm retained for any other python3 net-create denial.
#   nr_hugepages - openvino reads /proc/sys/vm/nr_hugepages (hugepage check)
#   mountinfo    - openvino reads /proc/<pid>/mountinfo
#   ca-certificates|host\.conf|stub-resolv|name="/etc/hosts" - network libs read DNS/TLS config
# FINDING (M6 §3.4.6 pre-adjudicated, now observed): frigate.frigate in-daemon edgetpu detector
#   (comm="frigate.detecto") CAP_NET_ADMIN denial — the SAME benign libedgetpu USB-init netlink
#   probe already allowlisted for the standalone coral-probe app (coral-probe.*capname="net_admin"
#   arm above), but emitted by the daemon's own edgetpu detector subprocess instead of the probe.
#   M6 spec §3.4.6 named this exact candidate ahead of time, to be added ONLY if observed; it
#   surfaces timing-dependently when a service restart catches the Coral stick in its pre-firmware
#   (1a6e) state. Non-blocking: same mechanism as the coral-probe sibling arm.
#   Arm (PINNED profile+comm+capname): frigate\.frigate.*comm="frigate\.detecto".*capname="net_admin"
# Evidence (journal 2026-07-10 03:45:53): apparmor="DENIED" operation="capable" class="cap" profile="snap.frigate.frigate" pid=2565495 comm="frigate.detecto" capability=12  capname="net_admin"
UNEXPECTED=$(grep -cvE 'psm_|name="/config/|operation="create".*class="net".*comm="python3|nr_hugepages|mountinfo|name="/proc/[^"]*/mounts"|ca-certificates|host\.conf|stub-resolv|name="/etc/hosts"|gpu-probe.*capname="sys_admin"|gpu-probe.*capname="perfmon"|name="[^"]*hugepages[/"]|name="/sys/devices/system/node/online"|name="/sys/bus/dax/|coral-probe.*capname="net_admin"|frigate\.frigate.*comm="frigate\.detecto".*capname="net_admin"|npu-probe.*capname="sys_admin"|gpu-probe.*name="/sys/devices/virtual/dmi/id/product_|vaapi-probe.*capname="sys_admin"|vaapi-probe.*capname="perfmon"|validate-config.*name="/sys/fs/cgroup/[^"]*cpu\.max"|frigate\.frigate.*name="/sys/fs/cgroup/[^"]*cpu\.max"|frigate\.frigate.*name="/sys/fs/cgroup/cgroup\.controllers"|operation="ptrace".*profile="snap\.frigate\.frigate".*comm="frigate\.recordi"|operation="ptrace".*profile="snap\.frigate\.frigate".*comm="python3\.11"|frigate\.frigate.*name="/proc/[^"]*/cmdline"|frigate\.frigate.*capname="sys_admin"|frigate\.frigate.*capname="perfmon"|frigate\.frigate.*name="/sys/devices/virtual/dmi/id/product_|frigate\.frigate.*comm="frigate\.recordi".*capname="sys_ptrace"|nginx.*capname="setgid"|nginx.*capname="setuid"|comm="frigate-run".*capname="dac_override"|comm="go2rtc-run".*capname="dac_override"|imports-probe.*name="/dev/shm/sem\.|imports-probe.*name="/usr/bin/lscpu"|imports-probe.*name="[^"]*share/fonts' "$EVIDENCE/denials.txt" || true)
echo "== denials: $(wc -l < "$EVIDENCE/denials.txt") total, $UNEXPECTED unexpected =="
# FINDING (Task 8): tensorflow/openvino imports trigger network-related denials (inet/inet6 socket
# creation, DNS resolution files, TLS CA certs, hugepages, mountinfo). Production snap will need:
# 'network' interface + AppArmor rules for /proc/sys/vm/nr_hugepages, /proc/*/mountinfo.
echo "  wheels finding: network/system denials from tensorflow+openvino imports (see denials.txt)"
# FINDING (Task 10): gpu-probe additional expected denials:
#   capname="sys_admin"  - vainfo needs CAP_SYS_ADMIN to query DRM GPU capabilities
#   capname="perfmon"    - vainfo needs CAP_PERFMON for performance counters
#   name="*/mounts"      - OpenVINO GPU plugin reads /proc/pid/mounts (short form, cf. mountinfo)
#   hugepages/ dirs      - OpenVINO GPU plugin checks hugepages sysfs dirs (not just nr_hugepages)
#   node/online          - OpenVINO GPU plugin reads NUMA topology
#   bus/dax              - OpenVINO GPU plugin checks DAX (persistent-memory) devices
#   dmi/id/product_name  - OpenVINO reads system model (observed 2026-07-03 run; probing varies run-to-run)
echo "  gpu-probe finding: vainfo cap denials (sys_admin, perfmon) + OpenVINO GPU sysfs probes (hugepages dirs, NUMA, DAX)"
# FINDING (Task 11): coral-probe additional expected denial:
#   coral-probe.*capname="net_admin" - libedgetpu firmware upload attempts CAP_NET_ADMIN during USB
#                 re-enumeration (1a6e:089a -> 18d1:9302); denied but firmware upload + inference succeed.
#                 Production snap does NOT need net_admin — this is a benign libedgetpu USB init probe.
echo "  coral-probe finding: CAP_NET_ADMIN denial during firmware upload (libedgetpu USB init probe; benign - delegate + inference succeed)"
# FINDING (Task 12): npu-probe additional expected denial:
#   npu-probe.*capname="sys_admin" - intel_vpu/accel driver checks CAP_SYS_ADMIN at open() on
#                 /dev/accel/accel0; denied by AppArmor but open() still SUCCEEDS (cap check
#                 is advisory for this driver path). Branch (d): open OK confirmed. Same mechanism
#                 applies to Coral-PCIe /dev/apex_0 via custom-device slot.
# NOTE (M7 final review): the npu-probe app is RETIRED from the shipped snap (custom-device dropped
# pre-Store; see the NPU section above). The `npu-probe.*capname="sys_admin"` allowlist arm above is
# RETAINED but now DORMANT — it references the probe only inside the denials.txt regex, so it is
# harmless (never matches when the probe does not run). The finding below is a HISTORICAL record of
# the last live run; the probe no longer executes in the shipped artifact.
echo "  npu-probe finding: probe RETIRED from shipped snap (M7 final review; custom-device dropped pre-Store) — allowlist arm retained but dormant; historically the CAP_SYS_ADMIN-at-accel-open denial was advisory/non-blocking (open OK)"
# FINDING (Task 4): vaapi-probe additional expected denials:
#   vaapi-probe.*capname="sys_admin" - ffmpeg VAAPI init queries DRM GPU capabilities (CAP_SYS_ADMIN);
#                 denied but hw decode succeeds — rc=0 confirmed; same mechanism as vainfo in gpu-probe.
#   vaapi-probe.*capname="perfmon"   - ffmpeg VAAPI queries performance counters (CAP_PERFMON);
#                 denied but non-blocking. Production snap does NOT need these caps for VAAPI decode.
echo "  vaapi-probe finding: CAP_SYS_ADMIN + CAP_PERFMON denials at VAAPI DRM init (advisory, non-blocking) — hw decode rc=0 confirmed"
# RE-ADDED ARM (M8 Task 6): matplotlib cold-import filesystem scan by imports-probe — matplotlib
#   (transitive dep norfair→filterpy) enumerates /usr/share/fonts (+ /usr/local/share/fonts) at first
#   import (operation="open" on a strict snap without a desktop interface → EACCES, matplotlib falls back
#   to bundled fonts — benign). Task 5 RETIRED this arm for lack of a captured journal QUOTE; per its own
#   escape hatch ("re-add WITH a real quote if captured"), the Task 6 VM gate + a deliberate cold-cache
#   reproduction CAPTURED it, so the arm is RESTORED, PINNED to imports-probe + share/fonts. Its SIBLING —
#   the same cold import opendir()ing the process CWD (name="<checkout>/") — was the sole unexpected denial
#   in the first Task 6 gate; that one is eliminated at SOURCE by running imports-probe from / (see the
#   imports-probe run above), so no CWD-path arm is added (a checkout-path arm would be non-portable).
# Evidence (VM cold-cache repro, 2026-07-13): apparmor="DENIED" operation="open" class="file" profile="snap.frigate.imports-probe" name="/usr/share/fonts/" comm="python3.11" requested_mask="r" denied_mask="r"
echo "  wheels finding: matplotlib font-scan arm RE-ADDED (M8 Task 6; captured with a journal quote in the VM gate + cold-cache repro) — pinned to imports-probe + share/fonts; the CWD-read sibling is eliminated at source (imports-probe now runs from /), not allowlisted"
# FINDING (Task 5): validate-config / Task-5 wheel additions — remaining benign patterns:
#   RE-ADDED ARMS (M8 Task 7 gate): the svc-c-era joblib denials — /dev/shm/sem.XXXXXX (glibc sem_open at
#                 the tensorflow/keras import → "joblib will operate in serial mode") and /usr/bin/lscpu
#                 (joblib/loky physical-core detection). Task 5 re-pointed them to imports-probe then DELETED
#                 the arms for lack of a captured journal QUOTE (0 imports-probe denials that VM run). The
#                 Task 7 --skip-install gate DID capture both (imports-probe ran in the wheels section and
#                 the kernel-audit window caught them this time — capture is timing-dependent, cf. the
#                 font-scan gap above). Per the authors' own "re-add WITH a journal quote if captured"
#                 instruction + policy L1484-1485, they are RESTORED here, PINNED to imports-probe + name.
#                 Benign: sem_open/lscpu are import-time joblib probes; imports-probe still runs (diagnostic
#                 exits rc-clean). Unrelated to the M8 Task 7 /logs tee change. validate-config stays immune
#                 anyway (shm-private private /dev/shm). Arms: imports-probe.*name="/dev/shm/sem\. and
#                 imports-probe.*name="/usr/bin/lscpu".
# Evidence (journal 2026-07-12, Task 7 gate): apparmor="DENIED" operation="mknod" class="file" profile="snap.frigate.imports-probe" name="/dev/shm/sem.NmSNLV" comm="python3.11" requested_mask="c" denied_mask="c" fsuid=0 ouid=0
# Evidence (journal 2026-07-12, Task 7 gate): apparmor="DENIED" operation="exec" class="file" profile="snap.frigate.imports-probe" name="/usr/bin/lscpu" comm="python3.11" requested_mask="x" denied_mask="x" fsuid=0 ouid=0
#   validate-config.*cpu\.max    - the full frigate.app import chain reads its own cgroup
#                 /sys/fs/cgroup/.../cpu.max + parent slice (cgroup v2 CPU quota probing; fires in
#                 both the main and forkserver-preload interpreters). EACCES tolerated - validation
#                 rc=0 in the same run. Not reproducible from any single library import in isolation
#                 (numpy/cv2/ort/tf/openvino/sherpa/transformers/pandas/librosa each tested clean).
#   product_(name|version)       - gpu-probe DMI arm widened: OpenVINO reads product_version next
#                 to product_name (2026-07-04 run; same OpenVINO system-info probing, varies run-to-run).
echo "  validate finding: joblib sem/lscpu arms RE-ADDED (M8 Task 7 gate captured both with journal quotes; benign import-time probes, unrelated to /logs tee) + frigate chain cgroup cpu.max reads (validate-config) — benign, non-blocking"
# FINDING (Task 3): frigate daemon cgroup reads — multiple cgroup v2 paths read by the daemon
#   and its subprocesses (comm="python3.11" main process, comm="frigate.detecto" OpenVINO detector,
#   etc.). Two patterns observed:
#   (a) frigate.frigate.*name="/sys/fs/cgroup/.../cpu.max" — CPU quota check per-slice (same as
#       validate-config Task 5 finding); main python3.11 and forkserver preload read their own slice.
#   (b) frigate.frigate.*name="/sys/fs/cgroup/cgroup.controllers" — top-level cgroup v2 controller
#       list read by the OpenVINO detector subprocess (comm="frigate.detecto") at inference init;
#       checks which controllers (cpu, memory, io) are available. EACCES tolerated, inference succeeds.
#   Both arms are profile+name-bound; benign; API and detector boot correctly despite denials.
echo "  frigate finding: frigate.frigate cgroup reads (cpu.max per-slice + top-level cgroup.controllers) — benign, EACCES tolerated, API + detector up"
# FINDING (Task 3): frigate.frigate ptrace + /proc/<pid>/cmdline denials — psutil.process_iter()
#   in the recording subprocess (comm="frigate.recordi") scans ALL processes to find spawned ffmpeg
#   instances. Ptrace denied against every process peer: unconfined system processes AND other snap
#   profiles (snap.frigate.go2rtc, snap.frigate.imports-probe, snap.frigate.coral-probe,
#   snap.snapcraft.snapcraft etc. — whatever else runs on the host during the capture window).
#   Same root cause as the unconfined case; psutil.process_iter() sends a ptrace read to every PID.
#   Benign: recording degrades gracefully; ffmpeg is tracked via its own subprocess handle.
#   mount-observe plug grants /proc/<pid>/mounts (disk_partitions()), but NOT ptrace for any peer.
#   Arm (PINNED to recording subprocess only): operation="ptrace".*profile="snap.frigate.frigate".*comm="frigate.recordi"
#   — ptrace denials from other frigate subprocesses now fail the scan (expected: unconfined process enumeration is
#   specific to recording subprocess). Production snap: add process-control interface only if ffmpeg subprocess tracking is needed.
echo "  frigate finding: recording process ptrace+cmdline denials (psutil.process_iter scans all PIDs — unconfined + any snap peer on host) — benign, non-blocking"
# FINDING (Task 4 fix round): frigate.frigate main-process ptrace — same psutil mechanism as the
#   recording subprocess, but emitted by the MAIN daemon process (comm="python3.11") during startup
#   (observed once, 2026-07-05 run, peer="unconfined"). Frigate's stats/util code runs psutil scans
#   in the main process too. Arm pinned to operation+profile+comm: comm="python3\.11".
#   Benign: read-only process introspection denied; daemon boots and API answers in the same run.
# Evidence (journal 2026-07-05 16:47:51): apparmor="DENIED" operation="ptrace" class="ptrace" profile="snap.frigate.frigate" pid=1895566 comm="python3.11" requested_mask="read" denied_mask="read" peer="unconfined"
# Mechanism: psutil /proc scan from the main process's stats path (read-mask on unconfined peers).
echo "  frigate finding: main-process (python3.11) psutil ptrace denial at startup — same mechanism as recordi arm, benign, non-blocking (Task 4 fix round)"
# FINDING (M3 final gate): frigate.recordi CAP_SYS_PTRACE capability denial — the capability-check
#   variant of the recordi psutil scan above. Reading certain /proc/<pid> files of other-domain
#   processes triggers the kernel's capable(CAP_SYS_PTRACE) check (class="cap") instead of / in
#   addition to the AppArmor ptrace class; which path fires varies run-to-run with what psutil
#   touches during the capture window (observed once, during the rollback restart phase).
#   Benign: same graceful degradation as the ptrace-class arm; recordings PASS in the same run.
#   Arm (PINNED profile+comm+capname): frigate\.frigate.*comm="frigate\.recordi".*capname="sys_ptrace"
# Evidence (journal 2026-07-05 20:50:04): apparmor="DENIED" operation="capable" class="cap" profile="snap.frigate.frigate" pid=2388672 comm="frigate.recordi" capability=19  capname="sys_ptrace"
echo "  frigate finding: recordi CAP_SYS_PTRACE capability denial — capability-check variant of the psutil scan arm, benign, non-blocking (M3 final gate)"
# NOTE (Task 4 fix round): the two DMI allowlist arms previously ended in product_\" (a literal
#   trailing quote) which can NEVER match the audited paths (product_name\", product_version\", ...)
#   — the arms were dead regexes and earlier runs passed only when the DMI probes didn't fire in the
#   capture window (probing varies run-to-run, as documented above). Trailing quote removed so the
#   arms match product_name/version/serial/uuid as the findings always intended.
# FINDING (Task 4): frigate.frigate OpenVINO detector (comm="frigate.detecto") GPU cap + DMI probes —
#   same mechanism as gpu-probe and vaapi-probe, emitted by the OpenVINO GPU plugin initialised inside
#   the detector forkserver. Three patterns:
#   frigate.frigate.*capname="sys_admin"           - OpenVINO GPU plugin DRM cap check (non-blocking)
#   frigate.frigate.*capname="perfmon"             - OpenVINO GPU plugin perf counter probe (non-blocking)
#   frigate.frigate.*name=".../dmi/id/product_*"  - OpenVINO reads system model (name/version/serial/uuid) for GPU selection
#   All EACCES-tolerant; detector boots and inference runs correctly despite denials.
echo "  frigate finding: frigate.detecto OpenVINO GPU cap (sys_admin, perfmon) + DMI id probes — same mechanism as gpu-probe, benign, non-blocking (Task 4 finding)"
# FINDING (M4 Task 2): nginx worker processes CAP_SETGID denial — nginx calls setgid() as part
#   of its worker process privilege setup, even when `user root;` is set in nginx.conf. With
#   `user root;`, the setgid call is to gid 0 (a no-op), but AppArmor denies CAP_SETGID before
#   the call completes. Non-blocking: nginx worker processes start and serve requests correctly.
#   One denial fires per worker process at startup (worker_processes auto; => one per CPU core).
#   Arm (profile+capname): nginx.*capname="setgid" — matches snap.frigate.nginx comm=nginx.
#   Production snap: add `setgid` to the nginx app's capability grants if worker user!=root.
# Evidence (journal 2026-07-06 01:47:46): apparmor="DENIED" operation="capable" class="cap" profile="snap.frigate.nginx" pid=2810997 comm="nginx" capability=6  capname="setgid"
echo "  nginx finding: nginx worker CAP_SETGID denial at startup (worker privilege setup; benign, non-blocking, one per CPU core) — nginx active and serving (M4 Task 2)"
# FINDING (M4 Task 4): nginx CAP_SETUID denial — the setuid() sibling of the CAP_SETGID arm above,
#   from the same worker-process privilege setup (ngx_spawn_process -> initgroups/setuid path).
#   With `user root;` the call is a uid-0 no-op, but AppArmor denies the capability check itself.
#   Fires less often than setgid (observed once, cache-manager process spawn window); benign,
#   non-blocking — nginx serves throughout the same run. Arm (profile+capname): nginx.*capname="setuid".
# Evidence (journal 2026-07-06 02:54:22): apparmor="DENIED" operation="capable" class="cap" profile="snap.frigate.nginx" pid=2909768 comm="nginx" capability=7  capname="setuid"
echo "  nginx finding: nginx CAP_SETUID denial (setuid sibling of the setgid arm, worker/cache-manager privilege setup; benign, non-blocking) — M4 Task 4"
# FINDING (M8 Task 7): frigate-run / go2rtc-run CAP_DAC_OVERRIDE capability denials — NEW with the
#   sh -> bash shebang switch that the /logs tee-parity needed (process substitution is a bash
#   feature). bash's builtin file-redirection path (the tee-sink truncation `: > current`, the
#   go2rtc-symlink/mkdir, and the process-substitution setup on the daemon exec) issues a
#   capable(CAP_DAC_OVERRIDE) probe during path resolution that dash never made — so gate runs on
#   the pre-M8 (sh) wrapper showed zero of these. AppArmor DENIES the capability: this is the SECURE
#   outcome — the wrapper is NOT granted DAC bypass. Every file op still SUCCEEDS via normal root DAC
#   (proven every run: /dev/shm/logs/frigate/current + $SNAP_DATA/go2rtc-logs/current carry real
#   daemon output, /logs tabs populate, logrotate copytruncate works, all daemons stay active across
#   restarts/reinstalls). Advisory / non-blocking — same benign class as the nginx setgid/setuid and
#   frigate sys_admin/perfmon capability arms above; surfaces only in the restart/reinstall-heavy gate
#   phases, not on a plain single-service restart. Arms (PINNED comm+capname):
#   comm="frigate-run".*capname="dac_override" and comm="go2rtc-run".*capname="dac_override".
# Evidence (journal 2026-07-12 22:20:51): apparmor="DENIED" operation="capable" class="cap" profile="snap.frigate.frigate" comm="frigate-run" capability=1  capname="dac_override"
# Evidence (journal 2026-07-12 22:23:24): apparmor="DENIED" operation="capable" class="cap" profile="snap.frigate.go2rtc" comm="go2rtc-run" capability=1  capname="dac_override"
echo "  m8 finding: frigate-run/go2rtc-run CAP_DAC_OVERRIDE denials — advisory bash-redirection capability probe (sh->bash for tee-parity), denied = confinement holds, file ops succeed via root DAC, non-blocking"
if [ "$UNEXPECTED" -eq 0 ]; then pass_ "no unexpected AppArmor denials"; else fail_ "unexpected denials"; cat "$EVIDENCE/denials.txt"; fi

cp -r "$RESULTS" "$EVIDENCE/" 2>/dev/null || true

# PR#3 review: generalized credential redaction FIRST — covers every writer above (operator
# camera creds from go2rtc /api/streams, /stats cmdlines, config-derived captures) regardless of
# source. Then the livecam fixed-string scrub (defense in depth: catches token-in-path URLs with
# no userinfo), then BOTH absence assertions (0 hits required across all of $EVIDENCE).
scrub_evidence
if [ -n "${LIVECAM_URL:-}" ]; then
  grep -rlF "$LIVECAM_URL" "$EVIDENCE" 2>/dev/null | while IFS= read -r f; do
    sed -i "s|$LIVECAM_URL|LIVECAM-URL-REDACTED|g" "$f"
  done
  check "livecam: no stream URL/credentials in evidence files" sh -c "! grep -rqF \"$LIVECAM_URL\" \"$EVIDENCE\""
fi
# Assertion uses the user:PASS@ credential shape — the scrubber's own '://REDACTED@' marker has
# no colon, so redacted evidence passes while any unredacted credential fails the run.
check "evidence: no URL credentials (user:pass@) anywhere in evidence files" \
  sh -c "! grep -rqEI '(rtsps?|rtmp|https?)://[^@/[:space:]]+:[^@/[:space:]]+@' \"$EVIDENCE\""

# Harmlessness proof (M8 B1): re-hash config.yml + TLS cert + service start-timestamps and
# assert byte/timestamp identity with the pre-gate baseline — the whole point of --nvr-safe.
# NOTE (deliberate deviation from spec wording): the spec said "config.yml/DB checksums
# identical"; a live NVR's DB is written continuously by frigate itself, so a DB checksum can
# never hold. The honest proof is config-sha + cert-sha + zero service restarts + the gate's
# only DB access being the existing read-only sqlite3 SELECT (money test).
if [ "$NVR_SAFE" -eq 1 ]; then
  NVRSAFE_CFG_SHA_POST=$(sha256sum "$NVRSAFE_CFG" 2>/dev/null | awk '{print $1}')
  NVRSAFE_CERT_SHA_POST=$(sha256sum "/var/snap/$SNAP_NAME/current/letsencrypt/live/frigate/fullchain.pem" 2>/dev/null | awk '{print $1}')
  NVRSAFE_STAMPS_POST=$(for s in go2rtc frigate nginx certsync; do
    systemctl show "snap.$SNAP_NAME.$s.service" -p ActiveEnterTimestamp --value; done)
  check "nvr-safe: config.yml untouched by gate" sh -c "[ '$NVRSAFE_CFG_SHA_PRE' = '$NVRSAFE_CFG_SHA_POST' ]"
  check "nvr-safe: TLS cert untouched by gate" sh -c "[ '$NVRSAFE_CERT_SHA_PRE' = '$NVRSAFE_CERT_SHA_POST' ]"
  check "nvr-safe: no service restarted by gate" sh -c "[ '$NVRSAFE_STAMPS_PRE' = '$NVRSAFE_STAMPS_POST' ]"
fi

echo
[ "$FAIL" -eq 0 ] && echo "SPIKE SMOKE: ALL PASS" || echo "SPIKE SMOKE: FAILURES"
exit "$FAIL"
