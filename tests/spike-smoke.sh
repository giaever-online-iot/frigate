#!/usr/bin/env bash
# M0 spike smoke harness. Run as root: sudo tests/spike-smoke.sh [--skip-install]
set -uo pipefail
cd "$(dirname "$0")/.."
SNAP_NAME=frigate
SNAP_FILE=$(ls -t spike/${SNAP_NAME}_*.snap 2>/dev/null | head -1)
RESULTS=/var/snap/$SNAP_NAME/common/spike-results
EVIDENCE=spike/results
FAIL=0
mkdir -p "$EVIDENCE"

pass_() { echo "PASS: $1"; }
fail_() { echo "FAIL: $1"; FAIL=1; }
# Note: check() always returns 0; failures accumulate in $FAIL. Do not use in && chains or if-conditions.
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass_ "$d"; else fail_ "$d"; fi; }
jqr()   { jq -r "$2" "$RESULTS/$1.json" 2>/dev/null; }

command -v jq >/dev/null || { echo "jq required: sudo apt install -y jq"; exit 1; }

MARK=$(date '+%Y-%m-%d %H:%M:%S')
# Capture expanded snapcraft yaml (gpu extension evidence); use abs path since subshell cd's into spike/
ABS_EVIDENCE="$(pwd)/$EVIDENCE"
(cd spike && snapcraft expand-extensions > "$ABS_EVIDENCE/expanded-snapcraft.yaml" 2>/dev/null) || true

if [ "${1:-}" != "--skip-install" ]; then
  [ -n "$SNAP_FILE" ] || { echo "ERROR: no spike/${SNAP_NAME}_*.snap file found - build first (cd spike && snapcraft pack)"; exit 1; }
  snap remove --purge "$SNAP_NAME" 2>/dev/null || true
  # Install mesa-2604 content provider BEFORE frigate so gpu-2604 plug is live when daemons start.
  # This ensures libGL.so.1 (removed from snap prime by gpu/cleanup) is available via content mount.
  snap install mesa-2604 2>/dev/null || true
  snap install --dangerous "$SNAP_FILE" || { fail_ "snap install"; exit 1; }
  snap connect $SNAP_NAME:gpu-2604 mesa-2604:gpu-2604 2>/dev/null || true
  pass_ "snap install --dangerous ($SNAP_FILE)"
  sleep 20  # let daemons start and probes write (tensorflow import needs ~12s observed, up to 15s allowed)
fi

check "svc-a active" sh -c "snap services $SNAP_NAME.svc-a | grep -q ' active'"

# --- task assertions inserted below this line ---
check "svc-b active" sh -c "snap services $SNAP_NAME.svc-b | grep -q ' active'"
check "svc-c active" sh -c "snap services $SNAP_NAME.svc-c | grep -q ' active'"
TA=$(jqr ordering-svc-a '.start_monotonic'); TB=$(jqr ordering-svc-b '.start_monotonic'); TC=$(jqr ordering-svc-c '.start_monotonic')
# starttime has 10ms (jiffy) resolution: sub-jiffy starts tie. Ties allowed; inversions still fail.
check "ordering: svc-a <= svc-b <= svc-c (jiffy resolution, ties allowed)" awk -v a="$TA" -v b="$TB" -v c="$TC" 'BEGIN{exit !(a<=b && b<=c)}'

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
check "private /tmp/cache holds token" sh -c "grep -rq '$TOK' /tmp/snap-private-tmp/snap.$SNAP_NAME/tmp/cache/ 2>/dev/null"

check "daemons run on python 3.11" test "$(jqr runtime '.version_major_minor')" = "3.11"

check "imports probe complete" test "$(jqr imports '.status')" = "complete"
for MOD in numpy cv2 onnxruntime tflite_runtime tensorflow openvino; do
  check "import $MOD" test "$(jqr imports ".imports.$MOD.ok")" = "true"
done

# FINDING (Task 6): /media/frigate layout REJECTED at snap pack time (same "defines a new top-level
# directory" error as /config). snapd does not treat /media as a valid layout base even though the
# directory exists in the base filesystem. Implication for M3: recordings cannot use a /media/frigate
# layout; Frigate's recordings path must be configured directly to a $SNAP_COMMON sub-path.
echo "  layout finding: /media/frigate NOT in snap layout (pack-time rejection: 'defines a new top-level directory /media')"
printf '# RECORDED FINDING (Task 6): snapcraft pack-time rejection, replayed by the harness - NOT live command output\nCannot pack snap: error: cannot validate snap "frigate": layout "/media/frigate" defines a new top-level directory "/media"\n' \
  > "$EVIDENCE/media-layout-pack-error.txt"

check "edgetpu dlopen probe complete" test "$(jqr edgetpu-dlopen '.status')" = "complete"
echo "  edgetpu finding: dlopen ok=$(jqr edgetpu-dlopen '.dlopen.ok') err=$(jqr edgetpu-dlopen '.dlopen.error // "-"')"

# Ensure mesa-2604 is installed and connected (idempotent; also handles --skip-install path)
snap install mesa-2604 2>/dev/null || true
snap connect $SNAP_NAME:gpu-2604 mesa-2604:gpu-2604 2>/dev/null || true
snap connections $SNAP_NAME > "$EVIDENCE/connections.txt"
snap run $SNAP_NAME.gpu-probe || true
check "gpu probe complete" test "$(jqr gpu '.status')" = "complete"
check "openvino sees GPU" grep -q '"GPU"' "$RESULTS/gpu.json"
check "vainfo produced output" test -s /var/snap/$SNAP_NAME/common/spike-results/vainfo.txt
cp /var/snap/$SNAP_NAME/common/spike-results/vainfo.txt "$EVIDENCE/" 2>/dev/null || true

# --- Coral USB section ---
# Once the Coral firmware is uploaded, the device stays in initialized state (18d1:9302) until
# physically replugged. On re-runs, before==18d1 is the expected steady state — the 1a6e->18d1
# transition only occurs on the very first probe after a replug. A live transition is auto-archived
# to coral-reenum-transition.txt by the block below (1) whenever a replugged device is probed.
snap connect $SNAP_NAME:raw-usb 2>/dev/null || true
snap connect $SNAP_NAME:hardware-observe 2>/dev/null || true
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
check "coral delegate loaded (firmware upload)" test "$(jqr coral '.load_delegate.ok')" = "true"
check "coral inference ran" test "$(jqr coral '.inference.ok')" = "true"
check "coral: device in initialized state (18d1) after probe" grep -q 18d1 "$EVIDENCE/coral-usb-after.txt"

# --- NPU custom-device section ---
snap connect $SNAP_NAME:npu $SNAP_NAME:npu-dev 2> "$EVIDENCE/npu-connect.txt" || true
snap run $SNAP_NAME.npu-probe 2>> "$EVIDENCE/npu-connect.txt" || true
check "npu probe produced evidence" sh -c "test -s $RESULTS/npu.json -o -s $EVIDENCE/npu-connect.txt"
echo "  npu finding: open=$(jqr npu '.open_accel0.ok // "no-json"') connect-err=$(head -c120 "$EVIDENCE/npu-connect.txt" 2>/dev/null)"

# --- AppArmor denial scan (keep last) ---
journalctl -k --since "$MARK" | grep -E "apparmor=\"DENIED\".*snap\.$SNAP_NAME" \
  > "$EVIDENCE/denials.txt" || true
# Known expected denials (FINDINGS, not bugs) — enumerated EXACTLY; any new denial pattern must
# fail the run and be triaged before being added here:
#   psm_        - svc-a: unnamespaced POSIX shm (Task 3 finding)
#   name="/config/ - layout probe: /config not in layout (Task 5 finding)
#   operation="create".*class="net".*comm="python3 - svc-c: tensorflow/openvino python3 socket
#                 creation at import time (inet/inet6, telemetry) → needs 'network' interface
#   nr_hugepages - openvino reads /proc/sys/vm/nr_hugepages (hugepage check)
#   mountinfo    - openvino reads /proc/<pid>/mountinfo
#   ca-certificates|host\.conf|stub-resolv|name="/etc/hosts" - network libs read DNS/TLS config
UNEXPECTED=$(grep -cvE 'psm_|name="/config/|operation="create".*class="net".*comm="python3|nr_hugepages|mountinfo|name="/proc/[^"]*/mounts"|ca-certificates|host\.conf|stub-resolv|name="/etc/hosts"|gpu-probe.*capname="sys_admin"|gpu-probe.*capname="perfmon"|name="[^"]*hugepages[/"]|name="/sys/devices/system/node/online"|name="/sys/bus/dax/|coral-probe.*capname="net_admin"|npu-probe.*capname="sys_admin"' "$EVIDENCE/denials.txt" || true)
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
# NOTE: this denial fires once per NPU device init (observed 2026-07-02 06:41 run, journal-verified); it may be absent from later runs' capture windows.
echo "  npu-probe finding: CAP_SYS_ADMIN denial at accel open (advisory, non-blocking) — branch (d) open OK, custom-device works on classic Ubuntu"
if [ "$UNEXPECTED" -eq 0 ]; then pass_ "no unexpected AppArmor denials"; else fail_ "unexpected denials"; cat "$EVIDENCE/denials.txt"; fi

cp -r "$RESULTS" "$EVIDENCE/" 2>/dev/null || true
echo
[ "$FAIL" -eq 0 ] && echo "SPIKE SMOKE: ALL PASS" || echo "SPIKE SMOKE: FAILURES"
exit "$FAIL"
