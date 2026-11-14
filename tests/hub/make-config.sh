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
# go2rtc listeners: the snap's baseline (config/go2rtc.yaml.in) binds RTSP :8554 and WebRTC :8555 on every address,
#   and its RTSP restream has no login (W-16), so the cameras would be on the hub's LAN. go2rtc-config-gen.py
#   deep-merges this config's `go2rtc:` block over the baseline (only api.listen is forced), so the block sets
#   rtsp.listen M7C_GO2RTC_RTSP_LISTEN (default 127.0.0.1:8554) and webrtc.listen M7C_GO2RTC_WEBRTC_LISTEN (default
#   127.0.0.1:8555); an empty value leaves the baseline's LAN bind. Frigate's own ffmpeg reads rtsp://127.0.0.1:8554.
#   With WebRTC on loopback a LAN browser's live view cannot use WebRTC and uses MSE through nginx instead.
#
# Secret hygiene: umask 077; xtrace off; the codes and addresses live only in shell variables and travel only on
# stdin (to yq for the final self-check, to the hub for the write), never on a command line or in a child's
# environment; no file on the laptop; output is counts, rc and "ok" or an error code. The hub copy is written to
# config.yml.m7c-new (root 0600), its sha256 compared here, then moved into place. Before the first write the
# rendered config is kept as config.yml.pre-h4 (root 0600); a re-run builds from that pristine copy again.
# Restore: sudo -n cp -p <config dir>/config.yml.pre-h4 <config dir>/config.yml
# Exit: 0 ok; 2 inputs or usage; 3 the ssh master is gone; 4 frigate.frigate is running; 5 the source is not the
# rendered H4 config (or the built config failed its own check); 6 key file codes; 7 the hub write failed;
# 8 validate-config says invalid.
set -uo pipefail
umask 077
unset BASH_XTRACEFD
HERE=$(cd "$(dirname "$0")" && pwd); EXEC="$HERE/ssh-exec.sh"
C=/var/snap/frigate/current/config
say() { echo "make-config: $*"; }
die() { echo "make-config: error E$1: $2" >&2; exit "$1"; }
[ $# -eq 0 ] || die 2 "usage: make-config.sh (no arguments; inputs come from M7C_ENV_DIR)"
command -v yq >/dev/null || die 2 "yq is required on the laptop"

# --- inputs ----------------------------------------------------------------------------------------
ENVD="${M7C_ENV_DIR:-$HOME/.local/state/m7c-hub}"; PAIRS="$ENVD/cameras.pairs"; ENVF="$ENVD/env"
private() { [ -f "$1" ] && [ -r "$1" ] && [ $(( 0$(stat -c %a "$1") & 077 )) = 0 ]; }
private "$PAIRS" || die 2 "cameras.pairs in M7C_ENV_DIR is missing, unreadable, or not private (must be 0600)"
private "$ENVF"  || die 2 "env in M7C_ENV_DIR is missing, unreadable, or not private (must be 0600)"
KEYFILE=$(sed -n 's/^M7C_KEYFILE=//p' "$ENVF" | tail -n 1 | tr -d '\r'); KEYFILE=${KEYFILE#[\"\']}; KEYFILE=${KEYFILE%[\"\']}
# shellcheck disable=SC2088  # a literal "~/" prefix in the env file is expanded here on purpose
case "$KEYFILE" in '~/'*) KEYFILE="$HOME/${KEYFILE#\~/}" ;; esac
[ -n "$KEYFILE" ] || die 2 "env has no M7C_KEYFILE= line"
if [ ! -f "$KEYFILE" ] || [ ! -r "$KEYFILE" ]; then die 2 "the key file named by M7C_KEYFILE is missing or unreadable"; fi
MAIN="${M7C_RTSP_MAIN:-/Streaming/Channels/101}"; SUB="${M7C_RTSP_SUB:-/Streaming/Channels/102}"
RL="${M7C_GO2RTC_RTSP_LISTEN-127.0.0.1:8554}"; WL="${M7C_GO2RTC_WEBRTC_LISTEN-127.0.0.1:8555}"
for l in "$RL" "$WL"; do [ -z "$l" ] || [[ "$l" =~ ^[0-9.]*:[0-9]{1,5}$ ]] || die 2 "M7C_GO2RTC_RTSP_LISTEN/M7C_GO2RTC_WEBRTC_LISTEN must be like 127.0.0.1:8554, :8554 or empty"; done
for p in "$MAIN" "$SUB"; do [[ "$p" =~ ^/[A-Za-z0-9/_.=-]*$ ]] || die 2 "M7C_RTSP_MAIN/M7C_RTSP_SUB must be a path like /Streaming/Channels/101"; done
ipv4() {   # pattern match only: no here-string (bash may back one with a temp file)
  local o; [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do [[ "$o" =~ ^(0|[1-9][0-9]*)$ ]] || return 1; [ "$o" -le 255 ] || return 1; done
}
IDS=(); IPS=()
while read -r id ip extra; do
  case "$id" in ''|'#'*) continue ;; esac
  [ -z "${extra:-}" ] || die 2 "cameras.pairs line $(( ${#IDS[@]} + 1 )): want '<camera id> <ipv4>'"
  [[ "$id" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || die 2 "cameras.pairs line $(( ${#IDS[@]} + 1 )): the camera id has an unexpected shape"
  ipv4 "${ip:-}" || die 2 "cameras.pairs line $(( ${#IDS[@]} + 1 )): not an IPv4 address"
  IDS+=("$id"); IPS+=("$ip")
done < <(tr -d '\r' < "$PAIRS")
[ "${#IDS[@]}" = 2 ] || die 2 "cameras.pairs must list exactly 2 cameras, found ${#IDS[@]}"
[ "${IDS[0]}" != "${IDS[1]}" ] || die 2 "cameras.pairs lists the same camera twice"
say "2 cameras in cameras.pairs"

# Codes: one "<id> <code>" line per entry of the one mapping we use, straight from yq into this loop (a pipe).
PW=("" ""); found=0
while read -r k v; do
  for i in 0 1; do if [ "$k" = "${IDS[$i]}" ] && [ -z "${PW[$i]}" ]; then PW[i]=$v; found=$((found + 1)); fi; done
done < <(tr -d '\r' < "$KEYFILE" | yq -r '.["original QR Code keys"] | to_entries | .[] | .key + " " + .value' - 2>/dev/null)
[ "$found" = 2 ] || die 6 "$found of 2 camera codes found in the key file"
for i in 0 1; do [[ "${PW[$i]}" =~ ^[A-Za-z0-9]{4,32}$ ]] || die 6 "the code for cam$((i + 1)) has an unexpected shape"; done
say "2 of 2 camera codes found"

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
hub SRC "if [ -f $C/config.yml.pre-h4 ]; then cat $C/config.yml.pre-h4; else cat $C/config.yml; fi" \
  || die 5 "cannot read the rendered config on the hub"
shape=$(printf '%s\n' "$SRC" | yq -r '[(.cameras | keys | join(",")), (has("go2rtc") | tostring), (.detectors | keys | join(","))] | join(" ")' - 2>/dev/null)
[ "$shape" = "testclip false coral" ] || die 5 "the source is not the rendered H4 config (want cameras=testclip, no go2rtc, detector coral)"

# --- build ------------------------------------------------------------------------------------------
BASE=$(printf '%s\n' "$SRC" | yq '
  ... comments = "" |
  del(.cameras.testclip) |
  .mqtt.enabled = false |
  .ffmpeg.hwaccel_args = "" |
  .record.enabled = true | .record.continuous.days = 1 |
  .cameras.cam1 = {"ffmpeg": {"inputs": [
      {"path": "rtsp://127.0.0.1:8554/cam1", "input_args": "preset-rtsp-restream", "roles": ["record"]},
      {"path": "rtsp://127.0.0.1:8554/cam1_sub", "input_args": "preset-rtsp-restream", "roles": ["detect"]}]},
    "detect": {"enabled": true, "fps": 5}} |
  .cameras.cam2 = {"ffmpeg": {"inputs": [
      {"path": "rtsp://127.0.0.1:8554/cam2", "input_args": "preset-rtsp-restream", "roles": ["record"]},
      {"path": "rtsp://127.0.0.1:8554/cam2_sub", "input_args": "preset-rtsp-restream", "roles": ["detect"]}]},
    "detect": {"enabled": true, "fps": 5}}' - 2>/dev/null) || die 5 "yq could not transform the source"
LST=""; [ -n "$RL" ] && LST+=$'  rtsp:\n    listen: "'"$RL"$'"\n'; [ -n "$WL" ] && LST+=$'  webrtc:\n    listen: "'"$WL"$'"\n'
printf -v G2 'go2rtc:\n%s  streams:\n    cam1:\n      - "rtsp://admin:%s@%s%s"\n    cam1_sub:\n      - "rtsp://admin:%s@%s%s"\n    cam2:\n      - "rtsp://admin:%s@%s%s"\n    cam2_sub:\n      - "rtsp://admin:%s@%s%s"\n' \
  "$LST" "${PW[0]}" "${IPS[0]}" "$MAIN" "${PW[0]}" "${IPS[0]}" "$SUB" "${PW[1]}" "${IPS[1]}" "$MAIN" "${PW[1]}" "${IPS[1]}" "$SUB"
printf -v CFG '%s\n%s\n%s' "# M7c hub config (spec D21), written by tests/hub/make-config.sh; the rendered copy is config.yml.pre-h4." "$BASE" "$G2"
got=$(printf '%s' "$CFG" | yq -r '[(.cameras | keys | join(",")), (.go2rtc.streams | keys | length), (.ffmpeg.hwaccel_args == ""), .mqtt.enabled, .record.continuous.days, (.detectors | has("coral")), (.go2rtc.rtsp.listen // ""), (.go2rtc.webrtc.listen // "")] | map(tostring) | join(" ")' - 2>/dev/null)
tc=$(printf '%s' "$CFG" | grep -c testclip)
if [ "$got" != "cam1,cam2 4 true false 1 true $RL $WL" ] || [ "$tc" != 0 ]; then die 5 "the built config failed its own check"; fi
say "built: 2 cameras, 4 go2rtc streams, testclip 0, hwaccel_args empty, mqtt off, continuous.days 1, detector coral, go2rtc rtsp ${RL:-baseline :8554} webrtc ${WL:-baseline :8555}"

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

# --- validate (does not start the NVR) --------------------------------------------------------------
hub VOUT 'snap run frigate.validate-config'; vrc=$?
if [ "$vrc" = 0 ]; then say "validate-config rc=0 valid"; say ok; exit 0; fi
say "validate-config rc=$vrc invalid; its error lines, masked:"
n=0
while IFS= read -r line; do
  case "$line" in *[Pp][Aa][Ss][Ss][Ww]*) continue ;; esac
  for i in 0 1; do line=${line//"${PW[$i]}"/<cam$((i + 1))-code>}; line=${line//"${IPS[$i]}"/<cam$((i + 1))-ip>}; done
  line=$(printf '%s\n' "$line" | sed -E 's#://[^@/[:space:]]+@#://<redacted>@#g')
  printf '  %s\n' "$line"; n=$((n + 1)); [ "$n" -ge 20 ] && break
done < <(printf '%s\n' "$VOUT" | grep -iE 'error|invalid|fail|exception|cameras' )
die 8 "validate-config says invalid; restore with: sudo -n cp -p $C/config.yml.pre-h4 $C/config.yml"
