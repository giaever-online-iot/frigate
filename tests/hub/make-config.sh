#!/usr/bin/env bash
set +x +o xtrace   # first: no trace of any value, even under `bash -x` or an inherited SHELLOPTS
# M7c §8 H4 part 2 (spec D21): build the hub's config.yml from the rendered H4 config plus the maintainer's two
# cameras, write it to the hub over the operator's EXISTING ssh master (tests/hub/ssh-exec.sh), and run
# frigate.validate-config there. It starts nothing: frigate's first real start is H5, a separate go.
#
# Inputs (private, never in the repo): M7C_ENV_DIR (default ~/.local/state/m7c-hub) holds
#   cameras.pairs  one line per camera, "<camera id> <ipv4>"; exactly two; order = cam1, cam2   (0600)
#   env            M7C_KEYFILE=<path of the key file>                                         (0600)
# The key file is YAML (CRLF allowed). Login user `admin`; password = .["original QR Code keys"]["<camera id>"].
# Nothing else in the key file is used.
# Stream paths: main (record) M7C_RTSP_MAIN, default /Streaming/Channels/101; sub (detect) M7C_RTSP_SUB, default
#   /Streaming/Channels/102. These defaults are UNVERIFIED for these camera models. A missing sub stream makes
#   Frigate log errors; the logins are correct, so it does not lock the camera out.
# Detect: the sub stream at its native size (Frigate auto-detects it, as the template's livecam block does),
#   fps 5 (the template's value). Record: the main stream. Cameras reach Frigate via go2rtc at
#   rtsp://127.0.0.1:8554/<stream> (the snap's go2rtc-config-gen.py convention: a `go2rtc:` block in config.yml).
# D21 edits: the testclip camera removed, mqtt.enabled false, ffmpeg.hwaccel_args "", record.continuous.days 1.
# Also record.alerts.retain.days 1 and record.detections.retain.days 1 (0.18.2 frigate/config/camera/record.py:
#   ReviewRetainConfig.days, default 10): bounds the trial's disk use on the shared NVMe, not only continuous.
# go2rtc listeners: the snap's baseline (config/go2rtc.yaml.in) binds RTSP :8554 and WebRTC :8555 on every address,
#   and its RTSP restream has no login (W-16), so the cameras would be on the hub's LAN. go2rtc-config-gen.py
#   deep-merges this config's `go2rtc:` block over the baseline (only api.listen is forced), so the block sets
#   rtsp.listen M7C_GO2RTC_RTSP_LISTEN (default 127.0.0.1:8554) and webrtc.listen M7C_GO2RTC_WEBRTC_LISTEN (default
#   127.0.0.1:8555); an empty value leaves the baseline's LAN bind. Frigate's own ffmpeg reads rtsp://127.0.0.1:8554.
#   With WebRTC on loopback a LAN browser's live view cannot use WebRTC and uses MSE through nginx instead.
#
# M7C_SOURCE=clip (W-7 Q7 answer 1, the synthetic H.265 stand-in for cameras that refuse RTSP): NOTHING in
#   M7C_ENV_DIR is read (no cameras.pairs, no env, no key file, no camera login at all). The cameras are go2rtc
#   exec sources that loop the clips from tests/hub/make-clips.sh with the snap's own ffmpeg and `-c copy` (no
#   re-encode on the hub): `exec:<ffmpeg> -hide_banner -loglevel warning -re -stream_loop -1 -i <clip> -c copy -an
#   -metadata title=m7c-<stream> -f rtsp {output}`. The title only makes the lines distinct: go2rtc 1.9.14 keys an
#   exec source by its line, and cam1 and cam2 loop the same clip (identical lines collide: DESCRIBE 404). Clips in M7C_CLIP_DIR (default /var/snap/frigate/common/m7c-clips, readable by the snap's
#   apps): main-1080p25.mp4 (1080p25) and sub-360p15.mp4 (360p15). ffmpeg: M7C_CLIP_FFMPEG (default
#   /snap/frigate/current/usr/lib/ffmpeg/8.0/bin/ffmpeg; config.yml gets no __SNAP__ replacement, only the
#   baseline does). Streams: cam1 = main (ONE input, roles detect+record: detect decodes 1080p25 at its native
#   size, the worst case), cam2 = main (record) + cam2_sub = sub (detect). Before the build the hub must have
#   both clips non-empty and the ffmpeg executable (else exit 9); their hub sha256 are printed. Every other D21
#   edit, the binds, the backup, the sha compare and validate-config are the same as in the camera mode.
# Secret hygiene: umask 077; xtrace off; the codes and addresses live only in shell variables and travel only on
# stdin (to yq for the final self-check, to the hub for the write), never on a command line or in a child's
# environment; no file on the laptop; output is counts, rc and "ok" or an error code. The hub copy is written to
# config.yml.m7c-new (root 0600), its sha256 compared here, then moved into place. Before the first write the
# rendered config is kept as config.yml.pre-h4 (root 0600); a re-run builds from that pristine copy again.
# Restore: sudo -n cp -p <config dir>/config.yml.pre-h4 <config dir>/config.yml
# Exit: 0 ok; 2 inputs or usage; 3 the ssh master is gone; 4 frigate.frigate is running; 5 the source is not the
# rendered H4 config (or the built config failed its own check); 6 key file codes; 7 the hub write failed;
# 8 validate-config says invalid; 9 (clip mode) a clip is missing or empty on the hub, or its ffmpeg is not
# executable there; 10 (cameras/clip mode) ezviz camera files are on the hub (P10); 11 (ezviz mode) the camera files
# were written but frigate.ezviz-check failed. ezviz mode (W-23 T18, spec §6): needs frigate.frigate and frigate.go2rtc
# inactive; builds config.yml with no go2rtc streams (cam1/cam2 are loopback inputs fed by ezviz-source) and writes
# the two camera files (host, port 8000, serial, login) on stdin only. M7C_RETAIN_DAYS (1-30, default 1) applies in
# every mode.
set -uo pipefail
umask 077
unset BASH_XTRACEFD
HERE=$(cd "$(dirname "$0")" && pwd); EXEC="$HERE/ssh-exec.sh"
C=/var/snap/frigate/current/config
say() { echo "make-config: $*"; }
die() { echo "make-config: error E$1: $2" >&2; exit "$1"; }
[ $# -eq 0 ] || die 2 "usage: make-config.sh (no arguments; inputs come from M7C_ENV_DIR)"
command -v yq >/dev/null || die 2 "yq is required on the laptop"
SOURCE="${M7C_SOURCE:-cameras}"
case "$SOURCE" in cameras|clip|ezviz) ;; *) die 2 "M7C_SOURCE must be cameras (default), clip or ezviz" ;; esac
# M7C_RETAIN_DAYS (W-23 F5): record.continuous.days and the alerts/detections retain.days, in every mode. Default 1.
RD="${M7C_RETAIN_DAYS:-1}"
{ [[ "$RD" =~ ^[1-9][0-9]?$ ]] && [ "$RD" -le 30 ]; } || die 2 "M7C_RETAIN_DAYS must be a whole number of days, 1 to 30"
RL="${M7C_GO2RTC_RTSP_LISTEN-127.0.0.1:8554}"; WL="${M7C_GO2RTC_WEBRTC_LISTEN-127.0.0.1:8555}"
for l in "$RL" "$WL"; do [ -z "$l" ] || [[ "$l" =~ ^[0-9.]*:[0-9]{1,5}$ ]] || die 2 "M7C_GO2RTC_RTSP_LISTEN/M7C_GO2RTC_WEBRTC_LISTEN must be like 127.0.0.1:8554, :8554 or empty"; done
IDS=(); IPS=(); PW=()
CLIPD="${M7C_CLIP_DIR:-/var/snap/frigate/common/m7c-clips}"; CFF="${M7C_CLIP_FFMPEG:-/snap/frigate/current/usr/lib/ffmpeg/8.0/bin/ffmpeg}"
CLIP_MAIN=main-1080p25.mp4; CLIP_SUB=sub-360p15.mp4

# --- inputs (camera mode only: clip mode reads nothing in M7C_ENV_DIR) ---------------------------------
# shellcheck source=tests/hub/lib-cameras.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-cameras.sh"   # read_cameras (shared with tests/ezviz/probe-run.sh)
if [ "$SOURCE" != clip ]; then read_cameras
else
  for p in "$CLIPD" "$CFF"; do
    if ! [[ "$p" =~ ^/[A-Za-z0-9/_.-]+$ ]] || [[ "$p" == *..* ]]; then die 2 "M7C_CLIP_DIR/M7C_CLIP_FFMPEG must be absolute paths of [A-Za-z0-9/_.-], no '..'"; fi
  done
  say "clip mode: no camera login is read"
fi

# --- hub: master, stopped NVR, pristine source -------------------------------------------------------
hub() {  # hub VAR CMD: run CMD on the hub, its output into VAR; a lost master ends everything here
  local out rc; out=$("$EXEC" exec "$2" 2>&1 </dev/null); rc=$?   # </dev/null: only the write sends stdin
  [ "$rc" = 3 ] && die 3 "MASTER GONE (no live ssh master); nothing more was done on the hub"
  printf -v "$1" '%s' "$out"; return "$rc"
}
"$EXEC" check >/dev/null 2>&1 </dev/null || die 3 "MASTER GONE (no live ssh master); nothing was done on the hub"
hub SVC 'snap services frigate' || die 4 "cannot read snap services frigate"
st=$(printf '%s\n' "$SVC" | awk '$1 == "frigate.frigate" { print $3 }')
[ "$st" = inactive ] || die 4 "frigate.frigate is ${st:-unknown}, not inactive: the config must not change under a running NVR"
say "frigate.frigate is inactive"
if [ "$SOURCE" = ezviz ]; then   # the helper runs under go2rtc: a running go2rtc would hold the cameras' login budget
  g2=$(printf '%s\n' "$SVC" | awk '$1 == "frigate.go2rtc" { print $3 }')
  [ "$g2" = inactive ] || die 4 "frigate.go2rtc is ${g2:-unknown}, not inactive: stop it before the cameras change to ezviz"
fi
hub SRC "if [ -f $C/config.yml.pre-h4 ]; then cat $C/config.yml.pre-h4; else cat $C/config.yml; fi" \
  || die 5 "cannot read the rendered config on the hub"
shape=$(printf '%s\n' "$SRC" | yq -r '[(.cameras | keys | join(",")), (has("go2rtc") | tostring), (.detectors | keys | join(","))] | join(" ")' - 2>/dev/null)
[ "$shape" = "testclip false coral" ] || die 5 "the source is not the rendered H4 config (want cameras=testclip, no go2rtc, detector coral)"
# P10 (C19: before the clip block): in cameras and clip mode, camera files on the hub mean ezviz is installed.
if [ "$SOURCE" != ezviz ] && hub _ 'ls /var/snap/frigate/current/ezviz/cameras/*.conf >/dev/null 2>&1'; then
  die 10 "ezviz camera files present on the hub; remove /var/snap/frigate/current/ezviz first (rollback step)"
fi
if [ "$SOURCE" = clip ]; then
  hub CL "for f in $CLIP_MAIN $CLIP_SUB; do if [ -s $CLIPD/\$f ]; then sha256sum $CLIPD/\$f; else echo \"missing \$f\"; fi; done; if [ -x $CFF ]; then echo ffmpeg-ok; else echo ffmpeg-missing; fi" \
    || die 9 "cannot check the clips on the hub"
  for f in "$CLIP_MAIN" "$CLIP_SUB"; do
    h=$(printf '%s\n' "$CL" | awk -v p="$CLIPD/$f" '$2 == p && $1 ~ /^[0-9a-f]{64}$/ { print $1 }')
    [ -n "$h" ] || die 9 "$CLIPD/$f is missing or empty on the hub; put it there first (tests/hub/ssh-exec.sh put)"
    say "clip $f sha256 $h"
  done
  printf '%s\n' "$CL" | grep -qx ffmpeg-ok || die 9 "$CFF is not executable on the hub"
fi

# --- build ------------------------------------------------------------------------------------------
if [ "$SOURCE" = clip ]; then
  CAMS='.cameras.cam1 = {"ffmpeg": {"inputs": [
      {"path": "rtsp://127.0.0.1:8554/cam1", "input_args": "preset-rtsp-restream", "roles": ["detect", "record"]}]},
    "detect": {"enabled": true, "fps": 5}} |
  .cameras.cam2 = {"ffmpeg": {"inputs": [
      {"path": "rtsp://127.0.0.1:8554/cam2", "input_args": "preset-rtsp-restream", "roles": ["record"]},
      {"path": "rtsp://127.0.0.1:8554/cam2_sub", "input_args": "preset-rtsp-restream", "roles": ["detect"]}]},
    "detect": {"enabled": true, "fps": 5}}'
elif [ "$SOURCE" = ezviz ]; then   # §6.3, P11: one loopback input per camera, detect+record, native size
  CAMS='.cameras.cam1 = {"ffmpeg": {"inputs": [
      {"path": "rtsp://127.0.0.1:8554/cam1", "input_args": "preset-rtsp-restream", "roles": ["detect", "record"]}]},
    "detect": {"enabled": true, "fps": 5}} |
  .cameras.cam2 = {"ffmpeg": {"inputs": [
      {"path": "rtsp://127.0.0.1:8554/cam2", "input_args": "preset-rtsp-restream", "roles": ["detect", "record"]}]},
    "detect": {"enabled": true, "fps": 5}}'
else
  CAMS='.cameras.cam1 = {"ffmpeg": {"inputs": [
      {"path": "rtsp://127.0.0.1:8554/cam1", "input_args": "preset-rtsp-restream", "roles": ["record"]},
      {"path": "rtsp://127.0.0.1:8554/cam1_sub", "input_args": "preset-rtsp-restream", "roles": ["detect"]}]},
    "detect": {"enabled": true, "fps": 5}} |
  .cameras.cam2 = {"ffmpeg": {"inputs": [
      {"path": "rtsp://127.0.0.1:8554/cam2", "input_args": "preset-rtsp-restream", "roles": ["record"]},
      {"path": "rtsp://127.0.0.1:8554/cam2_sub", "input_args": "preset-rtsp-restream", "roles": ["detect"]}]},
    "detect": {"enabled": true, "fps": 5}}'
fi
BASE=$(printf '%s\n' "$SRC" | yq '
  ... comments = "" |
  del(.cameras.testclip) |
  .mqtt.enabled = false |
  .ffmpeg.hwaccel_args = "" |
  .record.enabled = true | .record.continuous.days = '"$RD"' |
  .record.alerts.retain.days = '"$RD"' | .record.detections.retain.days = '"$RD"' |
  '"$CAMS" - 2>/dev/null) || die 5 "yq could not transform the source"
LST=""; [ -n "$RL" ] && LST+=$'  rtsp:\n    listen: "'"$RL"$'"\n'; [ -n "$WL" ] && LST+=$'  webrtc:\n    listen: "'"$WL"$'"\n'
if [ "$SOURCE" = clip ]; then
  # -metadata title=m7c-<stream> (only the SDP session name) makes the three lines distinct: go2rtc 1.9.14 keys an
  # exec source by its line, and two identical lines started at once collide (one consumer gets DESCRIBE 404).
  X="exec:$CFF -hide_banner -loglevel warning -re -stream_loop -1 -i $CLIPD"; Y="-c copy -an -metadata title=m7c-"; Z="-f rtsp {output}"
  printf -v G2 'go2rtc:\n%s  streams:\n    cam1:\n      - "%s/%s %scam1 %s"\n    cam2:\n      - "%s/%s %scam2 %s"\n    cam2_sub:\n      - "%s/%s %scam2_sub %s"\n' \
    "$LST" "$X" "$CLIP_MAIN" "$Y" "$Z" "$X" "$CLIP_MAIN" "$Y" "$Z" "$X" "$CLIP_SUB" "$Y" "$Z"
  NS=3; KIND=" (clip)"
elif [ "$SOURCE" = ezviz ]; then
  G2=""; [ -n "$LST" ] && printf -v G2 'go2rtc:\n%s' "$LST"   # listens only: no streams (the helper is go2rtc's source)
  NS=0; KIND=" (ezviz)"
else
  printf -v G2 'go2rtc:\n%s  streams:\n    cam1:\n      - "rtsp://admin:%s@%s%s"\n    cam1_sub:\n      - "rtsp://admin:%s@%s%s"\n    cam2:\n      - "rtsp://admin:%s@%s%s"\n    cam2_sub:\n      - "rtsp://admin:%s@%s%s"\n' \
    "$LST" "${PW[0]}" "${IPS[0]}" "$MAIN" "${PW[0]}" "${IPS[0]}" "$SUB" "${PW[1]}" "${IPS[1]}" "$MAIN" "${PW[1]}" "${IPS[1]}" "$SUB"
  NS=4; KIND=""
fi
printf -v CFG '%s\n%s\n%s' "# M7c hub config (spec D21), written by tests/hub/make-config.sh; the rendered copy is config.yml.pre-h4." "$BASE" "$G2"
got=$(printf '%s' "$CFG" | yq -r '[(.cameras | keys | join(",")), ((.go2rtc.streams // {}) | keys | length), (.ffmpeg.hwaccel_args == ""), .mqtt.enabled, .record.continuous.days, .record.alerts.retain.days, .record.detections.retain.days, (.detectors | has("coral")), (.go2rtc.rtsp.listen // ""), (.go2rtc.webrtc.listen // "")] | map(tostring) | join(" ")' - 2>/dev/null)
tc=$(printf '%s' "$CFG" | grep -c testclip)
if [ "$got" != "cam1,cam2 $NS true false $RD $RD $RD true $RL $WL" ] || [ "$tc" != 0 ]; then die 5 "the built config failed its own check"; fi
if [ "$SOURCE" != cameras ] && printf '%s' "$CFG" | grep -q '://[^ "]*@'; then die 5 "the built $SOURCE config has a URL with a login"; fi
if [ "$SOURCE" = ezviz ]; then
  ci=$(printf '%s' "$CFG" | yq -r '[.cameras.cam1.ffmpeg.inputs, .cameras.cam2.ffmpeg.inputs] | map((length | tostring) + ":" + (.[0].roles | join(","))) | join(" ")' - 2>/dev/null)
  [ "$ci" = "1:detect,record 1:detect,record" ] || die 5 "the built ezviz config failed its own check (inputs)"
fi
say "built: 2 cameras$KIND, $NS go2rtc streams, testclip 0, hwaccel_args empty, mqtt off, continuous.days $RD, alerts/detections retain.days $RD, detector coral, go2rtc rtsp ${RL:-baseline :8554} webrtc ${WL:-baseline :8555}"

# --- write: backup once, new file, sha compare, move ----------------------------------------------------
hub BK "if [ -f $C/config.yml.pre-h4 ]; then echo kept; else cp $C/config.yml $C/config.yml.pre-h4.m7c-part && chown root:root $C/config.yml.pre-h4.m7c-part && chmod 0600 $C/config.yml.pre-h4.m7c-part && mv -f $C/config.yml.pre-h4.m7c-part $C/config.yml.pre-h4 && echo created; fi" \
  || die 7 "could not create config.yml.pre-h4 on the hub; nothing written"
case "$BK" in kept|created) say "backup config.yml.pre-h4: $BK" ;; *) die 7 "unexpected answer while creating config.yml.pre-h4; nothing written" ;; esac
WANT=$(printf '%s' "$CFG" | sha256sum | cut -d' ' -f1)
NEW=$(printf '%s' "$CFG" | "$EXEC" exec "umask 077 && cat > $C/config.yml.m7c-new && chown root:root $C/config.yml.m7c-new && chmod 0600 $C/config.yml.m7c-new && sha256sum $C/config.yml.m7c-new" 2>&1)
wrc=$?; [ "$wrc" = 3 ] && die 3 "MASTER GONE during the write; config.yml.m7c-new may be left on the hub, config.yml is unchanged"
GOT=$(printf '%s\n' "$NEW" | awk 'NR == 1 { print $1 }')
if [ "$wrc" != 0 ] || [ "$GOT" != "$WANT" ]; then
  hub _ "rm -f $C/config.yml.m7c-new" || true
  die 7 "the hub copy did not arrive intact (rc $wrc); removed it, config.yml is unchanged"
fi
hub MODE "mv -f $C/config.yml.m7c-new $C/config.yml && stat -c %a $C/config.yml" || die 7 "could not move the new config into place"
[ "$MODE" = 600 ] || die 7 "config.yml has mode $MODE, want 600"
say "written: config.yml (root, 0600, sha256 matched)"

# --- ezviz: camera files (secrets on stdin only), then the app's own check --------------------------------
if [ "$SOURCE" = ezviz ]; then
  CD=/var/snap/frigate/current/ezviz; SD=/var/snap/frigate/common/ezviz   # the state dir is created, never emptied
  hub _ "umask 077 && mkdir -p $CD/cameras $SD/state && chown root:root $CD $CD/cameras $SD $SD/state && chmod 0700 $CD $CD/cameras $SD $SD/state" \
    || die 7 "could not create the ezviz directories on the hub"
  for i in 0 1; do
    f=$CD/cameras/cam$((i + 1)).conf
    printf -v CONF '%s\nhost=%s\nport=8000\nserial=%s\nlogin=%s\n' "# written by tests/hub/make-config.sh (M7C_SOURCE=ezviz); root 0600; never print" "${IPS[$i]}" "${IDS[$i]}" "${PW[$i]}"
    WANT=$(printf '%s' "$CONF" | sha256sum | cut -d' ' -f1)
    NEW=$(printf '%s' "$CONF" | "$EXEC" exec "umask 077 && cat > $f.m7c-new && chown root:root $f.m7c-new && chmod 0600 $f.m7c-new && sha256sum $f.m7c-new" 2>&1)
    wrc=$?; [ "$wrc" = 3 ] && die 3 "MASTER GONE during a camera file write; a .m7c-new file may be left under $CD/cameras"
    GOT=$(printf '%s\n' "$NEW" | awk 'NR == 1 { print $1 }')
    if [ "$wrc" != 0 ] || [ "$GOT" != "$WANT" ]; then
      hub _ "rm -f $f.m7c-new" || true
      die 7 "camera file cam$((i + 1)) did not arrive intact (rc $wrc); removed it"
    fi
    hub _ "mv -f $f.m7c-new $f" || die 7 "could not move camera file cam$((i + 1)) into place"
  done
  CONF=""
  say "camera files: 2 written (root, 0600, sha256 matched)"
  for c in cam1 cam2; do
    hub CK "snap run frigate.ezviz-check $c"; krc=$?
    [ "$krc" = 0 ] && [ "$CK" = "ezviz-check $c: ok" ] || die 11 "camera files written but ezviz-check failed for $c (rc $krc)"
    say "ezviz-check $c: ok"
  done
fi

# --- validate (does not start the NVR) --------------------------------------------------------------
hub VOUT 'snap run frigate.validate-config'; vrc=$?
if [ "$vrc" = 0 ]; then say "validate-config rc=0 valid"; say ok; exit 0; fi
say "validate-config rc=$vrc invalid; its error lines, masked:"
n=0
while IFS= read -r line; do
  case "$line" in *[Pp][Aa][Ss][Ss][Ww]*) continue ;; esac
  for i in "${!PW[@]}"; do line=${line//"${PW[$i]}"/<cam$((i + 1))-code>}; line=${line//"${IPS[$i]}"/<cam$((i + 1))-ip>}; done
  line=$(printf '%s\n' "$line" | sed -E 's#://[^@/[:space:]]+@#://<redacted>@#g')
  printf '  %s\n' "$line"; n=$((n + 1)); [ "$n" -ge 20 ] && break
done < <(printf '%s\n' "$VOUT" | grep -iE 'error|invalid|fail|exception|cameras' )
die 8 "validate-config says invalid; restore with: sudo -n cp -p $C/config.yml.pre-h4 $C/config.yml"
