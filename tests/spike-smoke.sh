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
if [ "${1:-}" != "--skip-install" ]; then
  [ -n "$SNAP_FILE" ] || { echo "ERROR: no spike/${SNAP_NAME}_*.snap file found - build first (cd spike && snapcraft pack)"; exit 1; }
  snap remove --purge "$SNAP_NAME" 2>/dev/null || true
  snap install --dangerous "$SNAP_FILE" || { fail_ "snap install"; exit 1; }
  pass_ "snap install --dangerous ($SNAP_FILE)"
  sleep 20  # let daemons start and probes write (tensorflow import needs up to 15s on startup)
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

# --- AppArmor denial scan (keep last) ---
journalctl -k --since "$MARK" | grep -E "apparmor=\"DENIED\".*snap\.$SNAP_NAME" \
  > "$EVIDENCE/denials.txt" || true
# Known expected denials (FINDINGS, not bugs):
#   psm_        - svc-a: unnamespaced POSIX shm (Task 3 finding)
#   name="/config/ - layout probe: /config not in layout (Task 5 finding)
#   class="net" - svc-c: tensorflow/openvino attempt network ops (inet/inet6 sockets, telemetry)
#                 → needs 'network' interface in production snap
#   nr_hugepages - openvino reads /proc/sys/vm/nr_hugepages (hugepage check)
#   mountinfo    - openvino reads /proc/<pid>/mountinfo
#   ca-certificates|host\.conf|stub-resolv|name="/etc/hosts" - network libs read DNS/TLS config
UNEXPECTED=$(grep -cvE 'psm_|name="/config/|class="net"|nr_hugepages|mountinfo|ca-certificates|host\.conf|stub-resolv|name="/etc/hosts"' "$EVIDENCE/denials.txt" || true)
echo "== denials: $(wc -l < "$EVIDENCE/denials.txt") total, $UNEXPECTED unexpected =="
# FINDING (Task 8): tensorflow/openvino imports trigger network-related denials (inet/inet6 socket
# creation, DNS resolution files, TLS CA certs, hugepages, mountinfo). Production snap will need:
# 'network' interface + AppArmor rules for /proc/sys/vm/nr_hugepages, /proc/*/mountinfo.
echo "  wheels finding: network/system denials from tensorflow+openvino imports (see denials.txt)"
if [ "$UNEXPECTED" -eq 0 ]; then pass_ "no unexpected AppArmor denials"; else fail_ "unexpected denials"; cat "$EVIDENCE/denials.txt"; fi

cp -r "$RESULTS" "$EVIDENCE/" 2>/dev/null || true
echo
[ "$FAIL" -eq 0 ] && echo "SPIKE SMOKE: ALL PASS" || echo "SPIKE SMOKE: FAILURES"
exit "$FAIL"
