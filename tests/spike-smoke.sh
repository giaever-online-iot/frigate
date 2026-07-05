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
# Evidence dir is created by the root harness but must stay writable by the invoking user
# (agents capture run transcripts here). chown to SUDO_USER when run via sudo.
[ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER" "$EVIDENCE" 2>/dev/null || true

pass_() { echo "PASS: $1"; }
fail_() { echo "FAIL: $1"; FAIL=1; }
# Note: check() always returns 0; failures accumulate in $FAIL. Do not use in && chains or if-conditions.
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass_ "$d"; else fail_ "$d"; fi; }
jqr()   { jq -r "$2" "$RESULTS/$1.json" 2>/dev/null; }

command -v jq >/dev/null || { echo "jq required: sudo apt install -y jq"; exit 1; }

# Operator provisioning for the live camera (see spike/config/frigate-config.yml LIVECAM block).
# URL arrives on STDIN (never argv - visible in ps) and is written root-owned 0600:
#   printf '%s' 'rtsp://user:pass@host:554/path' | sudo tests/spike-smoke.sh --provision-livecam
if [ "${1:-}" = "--provision-livecam" ]; then
  mkdir -p "/var/snap/$SNAP_NAME/common"
  umask 077
  head -1 > "/var/snap/$SNAP_NAME/common/livecam-url"
  chown root:root "/var/snap/$SNAP_NAME/common/livecam-url"
  chmod 600 "/var/snap/$SNAP_NAME/common/livecam-url"
  echo "livecam-url provisioned (root 0600); next harness run arms the live-camera money test"
  exit 0
fi

MARK=$(date '+%Y-%m-%d %H:%M:%S')
# Capture expanded snapcraft yaml (gpu extension evidence); use abs path since subshell cd's into spike/
ABS_EVIDENCE="$(pwd)/$EVIDENCE"
(cd spike && snapcraft expand-extensions > "$ABS_EVIDENCE/expanded-snapcraft.yaml" 2>/dev/null) || true

if [ "${1:-}" != "--skip-install" ]; then
  [ -n "$SNAP_FILE" ] || { echo "ERROR: no spike/${SNAP_NAME}_*.snap file found - build first (cd spike && snapcraft pack)"; exit 1; }
  # Live camera secret ($SNAP_COMMON/livecam-url, provisioned once by the operator) must survive
  # the purge/reinstall cycle: stash before remove, restore after install. Never echo its content.
  # M4 Task 0 hardening: EXIT trap — on mid-run abort the root-0600 copy must not persist in /tmp.
  LIVECAM_STASH=""
  trap '[ -n "${LIVECAM_STASH:-}" ] && rm -f "$LIVECAM_STASH"' EXIT
  if [ -f "/var/snap/$SNAP_NAME/common/livecam-url" ]; then
    LIVECAM_STASH=$(mktemp)
    cp -p "/var/snap/$SNAP_NAME/common/livecam-url" "$LIVECAM_STASH"
  fi
  snap remove --purge "$SNAP_NAME" 2>/dev/null || true
  # Install mesa-2604 content provider BEFORE frigate so gpu-2604 plug is live when daemons start.
  # This ensures libGL.so.1 (removed from snap prime by gpu/cleanup) is available via content mount.
  snap install mesa-2604 2>/dev/null || true
  snap install --dangerous "$SNAP_FILE" || { fail_ "snap install"; exit 1; }
  snap connect $SNAP_NAME:gpu-2604 mesa-2604:gpu-2604 2>/dev/null || true
  # mount-observe: not auto-connected for --dangerous installs; required by frigate daemon so
  # psutil.disk_partitions() can read /proc/<pid>/mounts for /dev/shm fs-type detection.
  snap connect $SNAP_NAME:mount-observe 2>/dev/null || true
  # Restore the livecam secret (0600) and restart frigate so frigate-run re-renders the
  # config with the LIVECAM block armed (daemons started at install without the file).
  if [ -n "$LIVECAM_STASH" ]; then
    install -m 0600 -o root -g root "$LIVECAM_STASH" "/var/snap/$SNAP_NAME/common/livecam-url"
    rm -f "$LIVECAM_STASH"
    snap restart $SNAP_NAME.frigate 2>/dev/null || true
  fi
  pass_ "snap install --dangerous ($SNAP_FILE)"
  sleep 30  # let daemons start and probes write; frigate needs extra time for Python imports (~12s) + startup
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

# The imports probe (tensorflow+openvino imports, ~30-75s under load) can outlive the fixed
# post-install sleep: probe completion observed at +73s under host load (2026-07-05, two
# consecutive runs) while earlier same-day runs completed within 30s. Poll to the probe's
# actual completion instead of racing a fixed sleep (deadline 120s; edgetpu-dlopen is
# written by the same probe sequence right after imports.json).
for i in $(seq 1 24); do
  [ "$(jqr imports '.status')" = "complete" ] && [ "$(jqr edgetpu-dlopen '.status')" = "complete" ] && break
  sleep 5
done
check "imports probe complete" test "$(jqr imports '.status')" = "complete"
for MOD in numpy cv2 onnxruntime tflite_runtime tensorflow openvino fastapi uvicorn starlette peewee pydantic scipy norfair zmq cryptography ruamel.yaml paho.mqtt.client; do
  check "import $MOD" sh -c "jq -e '.imports.\"$MOD\".ok == true' \"$RESULTS/imports.json\""
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
# mount-observe: connect idempotently (not auto-connected for --dangerous installs)
snap connect $SNAP_NAME:mount-observe 2>/dev/null || true
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
check "coral delegate loaded (firmware upload)" test "$(jqr coral '.load_delegate.ok')" = "true"
check "coral inference ran" test "$(jqr coral '.inference.ok')" = "true"
check "coral: device in initialized state (18d1) after probe" grep -q 18d1 "$EVIDENCE/coral-usb-after.txt"

# --- NPU custom-device section ---
snap connect $SNAP_NAME:npu $SNAP_NAME:npu-dev 2> "$EVIDENCE/npu-connect.txt" || true
snap run $SNAP_NAME.npu-probe 2>> "$EVIDENCE/npu-connect.txt" || true
check "npu probe produced evidence" sh -c "test -s $RESULTS/npu.json -o -s $EVIDENCE/npu-connect.txt"
echo "  npu finding: open=$(jqr npu '.open_accel0.ok // "no-json"') connect-err=$(head -c120 "$EVIDENCE/npu-connect.txt" 2>/dev/null)"

# --- M2: ffmpeg matrix (Task 1) --- ffprobe app follows the tag-default 7.0 tree
check "ffprobe app runs tag-default 7.0" sh -c "snap run frigate.ffprobe -version 2>/dev/null | head -1 | grep -q '^ffprobe version n7'"
# static builds run directly from the mounted squashfs (no confinement needed for -version)
for V in 5.0 7.0 8.0; do
  check "ffmpeg tree $V present+runs" sh -c "/snap/frigate/current/usr/lib/ffmpeg/$V/bin/ffprobe -version | head -1 | grep -q '^ffprobe version'"
done

# --- M2: frigate source + carried patch (Task 2) ---
check "frigate source staged" test -f /snap/frigate/current/opt/frigate/frigate/const.py
check "carried patch applied (env-driven paths)" grep -q 'FRIGATE_CONFIG_DIR' /snap/frigate/current/opt/frigate/frigate/const.py
check "migrations staged" test -d /snap/frigate/current/opt/frigate/migrations

# --- M1: go2rtc daemon (Task 2) ---
check "go2rtc service active" sh -c "snap services frigate.go2rtc | grep -q ' active'"
curl -sf --max-time 5 http://127.0.0.1:1984/api/streams > "$EVIDENCE/go2rtc-streams.json" 2>/dev/null || true
check "go2rtc API lists test stream" sh -c "jq -e '.test' \"$EVIDENCE/go2rtc-streams.json\""

# --- M1: readiness gate evidence (Task 3) ---
# Note: jqr is a shell function not available in subshells; inline jq with the expanded $RESULTS path.
check "readiness: svc-a waited_ms recorded (>=0)" sh -c "WMS=\$(jq -r '.waited_ms // -2' \"$RESULTS/ordering-svc-a.json\" 2>/dev/null); [ -n \"\$WMS\" ] && [ \"\$WMS\" -ge 0 ]"
echo "  readiness finding: svc-a waited_ms=$(jqr ordering-svc-a '.waited_ms')"

# --- M1: RTSP end-to-end (Task 4) ---
# ffprobe is BOTH the verifier and the first consumer: it triggers go2rtc's
# exec: source, which spawns the staged ffmpeg INSIDE confinement.
timeout 30 snap run frigate.ffprobe -v error -print_format json -show_streams \
  -rtsp_transport tcp "rtsp://127.0.0.1:8554/test" > "$EVIDENCE/rtsp-probe.json" 2>/dev/null || true
check "rtsp: stream is h264" sh -c "jq -e '.streams[0].codec_name == \"h264\"' \"$EVIDENCE/rtsp-probe.json\""
check "rtsp: 1280x720" sh -c "jq -e '.streams[0].width == 1280 and .streams[0].height == 720' \"$EVIDENCE/rtsp-probe.json\""
# Confined subprocess evidence: the exec producer must appear in go2rtc's stream state.
curl -sf --max-time 5 "http://127.0.0.1:1984/api/streams?src=test" > "$EVIDENCE/go2rtc-producer.json" 2>/dev/null || true
check "go2rtc exec producer active (confined ffmpeg spawned)" sh -c "jq -e '.producers[0]' \"$EVIDENCE/go2rtc-producer.json\""
echo "  subprocess finding: exec producer state captured in go2rtc-producer.json"

# --- M1: WebRTC (Task 5) ---
check "webrtc: 8555/tcp bound" sh -c "ss -tlnp | grep -q ':8555'"
check "webrtc: 8555/udp bound" sh -c "ss -ulnp | grep -q ':8555'"
# WHEP: POST a minimal recvonly offer; a 2xx + SDP answer is full automated proof.
# A non-2xx HTTP response still proves the endpoint is alive (record; manual browser
# check below is then the SDP-level evidence). Connection-refused fails the check.
WHEP_OFFER='v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\nc=IN IP4 0.0.0.0\r\na=mid:0\r\na=recvonly\r\na=rtpmap:96 H264/90000\r\na=ice-ufrag:spike\r\na=ice-pwd:spikespikespikespikespike\r\na=fingerprint:sha-256 00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF\r\na=setup:actpass\r\n'
printf "%b" "$WHEP_OFFER" | curl -s --max-time 5 -X POST -H 'Content-Type: application/sdp' \
  --data-binary @- -o "$EVIDENCE/whep-response.txt" -w '%{http_code}' \
  "http://127.0.0.1:1984/api/webrtc?src=test" > "$EVIDENCE/whep-status.txt" 2>/dev/null || true
check "webrtc: WHEP endpoint alive (HTTP response)" sh -c "grep -qE '^[1-5][0-9][0-9]$' \"$EVIDENCE/whep-status.txt\""
if grep -q '^2' "$EVIDENCE/whep-status.txt" && grep -q '^v=0' "$EVIDENCE/whep-response.txt"; then
  pass_ "webrtc: WHEP returned SDP answer (automated full proof)"
else
  echo "  webrtc finding: WHEP status=$(cat "$EVIDENCE/whep-status.txt") - SDP answer not automated; manual browser check required (see docs/m1-findings.md)"
fi

# --- M1: mDNS multicast (Task 6) ---
snap run frigate.mdns-probe || true
check "mdns probe complete" test "$(jqr mdns '.status')" = "complete"
echo "  mdns finding: join=$(jqr mdns '.multicast_join.ok') sent=$(jqr mdns '.query_sent.ok') responses=$(jqr mdns '.responses')"

# --- M2: VAAPI hardware decode (Task 4) ---
# -hwaccel_output_format vaapi FORBIDS silent software fallback: rc=0 proves the hw path.
check "vaapi: hw decode of synthetic stream (rc=0, no sw fallback)" snap run frigate.vaapi-probe
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

# --- M3: detector models staged (Task 1) ---
check "openvino model staged" sh -c "ls /snap/frigate/current/opt/frigate/models/openvino/*.xml"
check "cpu tflite fallback staged" sh -c "ls /snap/frigate/current/opt/frigate/models/cpu/*.tflite"
check "coco labelmap staged" test -s /snap/frigate/current/opt/frigate/models/labelmap.txt
check "openvino 91-class labelmap staged" test -s /snap/frigate/current/opt/frigate/models/openvino/coco_91cl_bkgr.txt

# --- M3: real-object test clip + stream (Task 2) ---
check "test clip staged" test -s /snap/frigate/current/media-samples/testclip.mp4
check "go2rtc has testclip stream" sh -c "jq -e '.testclip' \"$EVIDENCE/go2rtc-streams.json\""

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
# No auth headers sent — auth.enabled=false in config makes /auth return 202 Accepted for any request.
NGINX_VER=$(curl -sf --max-time 5 http://127.0.0.1:5000/api/version 2>/dev/null)
FRIGATE_VER=$(curl -sf --max-time 5 -H "Remote-User: admin" -H "Remote-Role: admin" http://127.0.0.1:5001/version 2>/dev/null)
check "nginx proxies /api/version == :5001/version (no auth headers)" test "$NGINX_VER" = "$FRIGATE_VER"
echo "  nginx finding: /api/version=$NGINX_VER (== :5001/version; no auth headers required)"
# /auth endpoint: 202 Accepted confirms auth.enabled=false anonymous-accept path
AUTH_STATUS=$(curl -so /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:5001/auth 2>/dev/null)
check "nginx: /auth returns 202 (anonymous accept with auth.enabled=false)" test "$AUTH_STATUS" = "202"
echo "  nginx finding: /auth status=$AUTH_STATUS (202 Accepted = anonymous auth path confirmed)"
echo "  nginx finding: error_log/access_log → files in \$SNAP_DATA/nginx/logs/ (deviation: /dev/stderr not openable in systemd snap unit — journal socket, not pipe; ENXIO on open)"

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
  check "MONEY TEST: real objects detected on live camera (events API)" test "$DETECTED" = "yes"
  check "detection: label is person with score" sh -c "jq -e '.[0].label == \"person\" and .[0].data.score > 0.4' \"$EVIDENCE/frigate-events.json\""
  # DB corroboration (also proves the split path is live). Table name: event.
  sqlite3 /var/snap/frigate/common/db/frigate.db "SELECT id,label,camera FROM event WHERE camera='livecam' LIMIT 5;" > "$EVIDENCE/db-events.txt" 2>/dev/null || \
    python3 -c "import sqlite3; c=sqlite3.connect('/var/snap/frigate/common/db/frigate.db'); [print(r[0],r[1],r[2]) for r in c.execute(\"SELECT id,label,camera FROM event WHERE camera='livecam' LIMIT 5\")]" > "$EVIDENCE/db-events.txt" 2>/dev/null || true
  check "detection: corroborated in split db" test -s "$EVIDENCE/db-events.txt"
  check "livecam: camera pipeline alive (ffmpeg_pid > 0)" sh -c "curl -sf --max-time 5 -H 'Remote-User: admin' -H 'Remote-Role: admin' http://127.0.0.1:5001/stats | jq -e '.cameras.livecam.ffmpeg_pid > 0'"
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
  http://127.0.0.1:5001/stats > "$EVIDENCE/frigate-stats.json" 2>/dev/null || true
check "gpu: openvino detector reporting + camera pipeline alive" sh -c "jq -e '.detectors.ov.inference_speed != null and .cameras.testclip.ffmpeg_pid > 0' \"$EVIDENCE/frigate-stats.json\""
echo "  gpu finding: ov inference_speed=$(jq -r '.detectors.ov.inference_speed' "$EVIDENCE/frigate-stats.json" 2>/dev/null)ms"
# Recordings on disk
check "recordings: files under SNAP_COMMON" sh -c "find /var/snap/frigate/common/media/frigate/recordings -name '*.mp4' 2>/dev/null | head -1 | grep -q mp4"

# --- M3: rollback machinery (Task 4) ---
# Proof 1: refresh fires the pre-refresh hook -> backup exists.
snap install --dangerous "$SNAP_FILE" >/dev/null 2>&1 || fail_ "rollback: reinstall-refresh failed"
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
UNEXPECTED=$(grep -cvE 'psm_|name="/config/|operation="create".*class="net".*comm="python3|nr_hugepages|mountinfo|name="/proc/[^"]*/mounts"|ca-certificates|host\.conf|stub-resolv|name="/etc/hosts"|gpu-probe.*capname="sys_admin"|gpu-probe.*capname="perfmon"|name="[^"]*hugepages[/"]|name="/sys/devices/system/node/online"|name="/sys/bus/dax/|coral-probe.*capname="net_admin"|npu-probe.*capname="sys_admin"|gpu-probe.*name="/sys/devices/virtual/dmi/id/product_|svc-c.*name="/usr(/local)?/share/fonts/|vaapi-probe.*capname="sys_admin"|vaapi-probe.*capname="perfmon"|svc-c.*name="/dev/shm/sem\.|svc-c.*name="/usr/bin/lscpu"|validate-config.*name="/sys/fs/cgroup/[^"]*cpu\.max"|frigate\.frigate.*name="/sys/fs/cgroup/[^"]*cpu\.max"|frigate\.frigate.*name="/sys/fs/cgroup/cgroup\.controllers"|operation="ptrace".*profile="snap\.frigate\.frigate".*comm="frigate\.recordi"|operation="ptrace".*profile="snap\.frigate\.frigate".*comm="python3\.11"|frigate\.frigate.*name="/proc/[^"]*/cmdline"|frigate\.frigate.*capname="sys_admin"|frigate\.frigate.*capname="perfmon"|frigate\.frigate.*name="/sys/devices/virtual/dmi/id/product_|frigate\.frigate.*comm="frigate\.recordi".*capname="sys_ptrace"|nginx.*capname="setgid"' "$EVIDENCE/denials.txt" || true)
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
# NOTE: this denial fires once per NPU device init (observed 2026-07-02 06:41 run, journal-verified); it may be absent from later runs' capture windows.
echo "  npu-probe finding: CAP_SYS_ADMIN denial at accel open (advisory, non-blocking) — branch (d) open OK, custom-device works on classic Ubuntu"
# FINDING (Task 4): vaapi-probe additional expected denials:
#   vaapi-probe.*capname="sys_admin" - ffmpeg VAAPI init queries DRM GPU capabilities (CAP_SYS_ADMIN);
#                 denied but hw decode succeeds — rc=0 confirmed; same mechanism as vainfo in gpu-probe.
#   vaapi-probe.*capname="perfmon"   - ffmpeg VAAPI queries performance counters (CAP_PERFMON);
#                 denied but non-blocking. Production snap does NOT need these caps for VAAPI decode.
echo "  vaapi-probe finding: CAP_SYS_ADMIN + CAP_PERFMON denials at VAAPI DRM init (advisory, non-blocking) — hw decode rc=0 confirmed"
# FINDING (Task 3): matplotlib font-scan denials — matplotlib (transitive dep of norfair→filterpy)
#   enumerates system font directories at import time. Profile: snap.frigate.svc-c (imports probe).
#   Denied paths: /usr/share/fonts/ and /usr/local/share/fonts/ (comm="python3.11", operation="open").
#   Arm is profile+name-bound: svc-c.*name="/usr(/local)?/share/fonts/ — matches both observed paths.
#   Non-blocking: norfair import succeeds; matplotlib works without font access.
#   Production snap: add AppArmor font-dir read rules OR exclude matplotlib from site-packages.
echo "  wheels finding: matplotlib font-dir scan denials (/usr/share/fonts/, /usr/local/share/fonts/) — benign, non-blocking (Task 3 finding)"
# FINDING (Task 5): validate-config / Task-5 wheel additions — three new benign patterns:
#   svc-c.*name="/dev/shm/sem\.  - joblib (new transitive dep: librosa->scikit-learn), imported
#                 during the tensorflow/keras import in the imports probe, creates a TEST semaphore
#                 at import (glibc sem_open mknods random /dev/shm/sem.XXXXXX). Denied -> joblib
#                 warns "[Errno 13] ... joblib will operate in serial mode" and falls back; all
#                 import checks PASS. (validate-config app is immune: shm-private private /dev/shm.)
#   svc-c.*name="/usr/bin/lscpu" - joblib/loky physical-core detection execs lscpu in the same
#                 import window; denied, graceful core-count fallback, non-blocking.
#   validate-config.*cpu\.max    - the full frigate.app import chain reads its own cgroup
#                 /sys/fs/cgroup/.../cpu.max + parent slice (cgroup v2 CPU quota probing; fires in
#                 both the main and forkserver-preload interpreters). EACCES tolerated - validation
#                 rc=0 in the same run. Not reproducible from any single library import in isolation
#                 (numpy/cv2/ort/tf/openvino/sherpa/transformers/pandas/librosa each tested clean).
#   product_(name|version)       - gpu-probe DMI arm widened: OpenVINO reads product_version next
#                 to product_name (2026-07-04 run; same OpenVINO system-info probing, varies run-to-run).
echo "  validate finding: joblib sem/lscpu import probes (svc-c, serial-mode fallback) + frigate chain cgroup cpu.max reads (validate-config) — benign, non-blocking (Task 5 finding)"
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
#   profiles (snap.frigate.go2rtc, snap.frigate.svc-a/b/c, snap.frigate.coral-probe,
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
if [ "$UNEXPECTED" -eq 0 ]; then pass_ "no unexpected AppArmor denials"; else fail_ "unexpected denials"; cat "$EVIDENCE/denials.txt"; fi

cp -r "$RESULTS" "$EVIDENCE/" 2>/dev/null || true

# Livecam secret hygiene: scrub the URL (credentials embedded) from ALL evidence files, then
# assert absence. Fixed-string grep/sed; runs last so every evidence writer above is covered.
if [ -n "${LIVECAM_URL:-}" ]; then
  grep -rlF "$LIVECAM_URL" "$EVIDENCE" 2>/dev/null | while IFS= read -r f; do
    sed -i "s|$LIVECAM_URL|LIVECAM-URL-REDACTED|g" "$f"
  done
  check "livecam: no stream URL/credentials in evidence files" sh -c "! grep -rqF \"$LIVECAM_URL\" \"$EVIDENCE\""
fi

echo
[ "$FAIL" -eq 0 ] && echo "SPIKE SMOKE: ALL PASS" || echo "SPIKE SMOKE: FAILURES"
exit "$FAIL"
