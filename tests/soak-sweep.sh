#!/usr/bin/env bash
# Read-only soak sweep for the frigate snap on a production host (W-3; M8 lessons L7/L10).
#
# Usage: tests/soak-sweep.sh [--since TIME]      (no sudo; writes nothing but stdout)
#   TIME: relative "-<N><s|m|min|h|d>" (e.g. -1h, -90m, -3d) or anything GNU `date -d` parses
#   (e.g. "2026-11-11 03:00"). Default -24h. The window start is resolved ONCE to an epoch and the
#   same instant goes to journalctl (--since @EPOCH) and to /events (after=EPOCH).
#
# Reports, one line each, GREEN / RED / INFO:
#   (a) the four snap daemons (go2rtc, frigate, nginx, certsync): active and NRestarts=0.
#       NRestarts is systemd's counter since the unit was last started by hand — NOT windowed.
#   (b) Frigate ERROR lines in the window, counted by logger. L10: Frigate logs ERROR to stdout,
#       which journald stores at info priority, so `journalctl -p err` is blind to them; grep the
#       Frigate level instead (-g, PCRE on MESSAGE). Counts and logger names only — never message
#       text (ffmpeg errors echo camera URLs with credentials). An unreadable journal is RED: zero
#       counted lines must not pass as zero errors.
#   (c) per-camera camera_fps / detection_fps from the loopback /stats. camera_fps <= 0 is RED.
#   (d) person/car events per camera since the window start (INFO: a quiet window is legitimate).
#   (e) per-detector inference_speed. Exactly 10.0 is Frigate's initial value, i.e. the detector
#       has never measured an inference: reported RED "NOT PROVEN" (a soak that cannot show the
#       detector ran must not exit 0). Any other value is a real measurement.
# Exit: 0 all GREEN; 1 any RED; 2 usage error.
# API: Frigate's internal :5001 with the proxy auth headers the harness uses (Remote-User/Role).
set -uo pipefail

SNAP_NAME=frigate
API="http://127.0.0.1:5001"
SERVICES="go2rtc frigate nginx certsync"
FRIGATE_UNIT="snap.$SNAP_NAME.frigate.service"
EVENTS_LIMIT=10000
# Frigate's line: "[<asctime>] <logger padded to 30> <LEVEL padded to 8>: <message>". A logger
# longer than 30 columns leaves ONE space before the level, so match " ERROR +:" rather than
# "  ERROR  ". The sed below re-anchors on the line prefix, so a message that merely quotes
# "ERROR :" is never counted, and only the logger token can reach stdout.
ERR_GREP='ERROR +:'
ERR_LOGGER_SED='s/^\[[^]]*\] +([A-Za-z0-9_.-]+) +ERROR +:.*/\1/p'

usage() {
  echo "usage: $0 [--since TIME]   (TIME: -1h, -90m, -3d, or a GNU date string; default -24h)" >&2
  exit 2
}

SINCE="-24h"
while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ $# -ge 2 ] || usage; SINCE="$2"; shift 2 ;;
    --since=*) SINCE="${1#--since=}"; shift ;;
    -h|--help) usage ;;
    *) echo "soak-sweep: unknown argument: $1" >&2; usage ;;
  esac
done

NOW=$(date +%s)
if [[ $SINCE =~ ^-([0-9]+)(s|sec|m|min|h|d)$ ]]; then
  case "${BASH_REMATCH[2]}" in
    s|sec) MULT=1 ;; m|min) MULT=60 ;; h) MULT=3600 ;; d) MULT=86400 ;;
  esac
  START=$((NOW - BASH_REMATCH[1] * MULT))
else
  START=$(date -d "$SINCE" +%s 2>/dev/null) || START=""
fi
if ! [[ $START =~ ^[0-9]+$ ]] || [ "$START" -gt "$NOW" ]; then
  echo "soak-sweep: cannot use --since '$SINCE' (unparseable or in the future)" >&2
  usage
fi

REDS=0
green() { printf 'GREEN  %s\n' "$*"; }
red()   { printf 'RED    %s\n' "$*"; REDS=$((REDS + 1)); }
info()  { printf 'INFO   %s\n' "$*"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# api_get PATH OUTFILE -> echoes the HTTP status (000 when unreachable). Body stays in OUTFILE.
api_get() {
  curl -s -o "$2" -w '%{http_code}' --max-time 10 \
    -H 'Remote-User: admin' -H 'Remote-Role: admin' "$API$1" 2>/dev/null
}

echo "soak-sweep: window since $SINCE ($(date -d "@$START" '+%Y-%m-%d %H:%M:%S %Z')) to now"

# (a) services -------------------------------------------------------------------------------------
for s in $SERVICES; do
  props=$(systemctl show "snap.$SNAP_NAME.$s.service" -p LoadState -p ActiveState -p SubState -p NRestarts 2>/dev/null)
  load=$(sed -n 's/^LoadState=//p' <<<"$props")
  active=$(sed -n 's/^ActiveState=//p' <<<"$props")
  sub=$(sed -n 's/^SubState=//p' <<<"$props")
  nr=$(sed -n 's/^NRestarts=//p' <<<"$props")
  if [ "$load" != "loaded" ]; then
    red "service $s: unit ${load:-unknown}"
  elif [ "$active" = "active" ] && [ "$nr" = "0" ]; then
    green "service $s: active, NRestarts=0"
  else
    red "service $s: ${active:-unknown}, NRestarts=${nr:-?}${sub:+ (sub=$sub)}"
  fi
done

# (b) Frigate ERROR lines by logger -----------------------------------------------------------------
if [ "$(journalctl -u "$FRIGATE_UNIT" -n 1 -o cat 2>/dev/null | grep -c .)" -eq 0 ]; then
  red "frigate ERROR lines: journal unreadable or empty for $FRIGATE_UNIT (cannot prove zero errors; needs root, adm or systemd-journal)"
else
  journalctl -u "$FRIGATE_UNIT" --since "@$START" -o cat -g "$ERR_GREP" 2>/dev/null |
    sed -nE "$ERR_LOGGER_SED" | sort | uniq -c | sort -rn >"$TMP/errs"
  total=$(awk '{ s += $1 } END { print s + 0 }' "$TMP/errs")
  if [ "$total" -eq 0 ]; then
    green "frigate ERROR lines: 0 in window"
  else
    red "frigate ERROR lines: $total in window, by logger:"
    awk '{ printf "       %8d  %s\n", $1, $2 }' "$TMP/errs"
  fi
fi

# (c) cameras + (e) detectors from /stats -----------------------------------------------------------
code=$(api_get /stats "$TMP/stats")
if [ "$code" != "200" ] || ! jq -e 'type == "object"' "$TMP/stats" >/dev/null 2>&1; then
  red "stats: $API/stats unreachable or not JSON (http=${code:-000}); cameras and detectors unmeasured"
else
  jq -r '(.cameras // {}) | to_entries[] |
         [.key, (.value.camera_fps // "null" | tostring), (.value.detection_fps // "null" | tostring)] | @tsv' \
    "$TMP/stats" >"$TMP/cams"
  if [ ! -s "$TMP/cams" ]; then
    red "cameras: none in /stats"
  fi
  while IFS=$'\t' read -r cam fps dfps; do
    if awk -v v="$fps" 'BEGIN { exit !(v ~ /^[0-9.]+$/ && v + 0 > 0) }'; then
      green "camera $cam: camera_fps=$fps detection_fps=$dfps"
    else
      red "camera $cam: camera_fps=$fps detection_fps=$dfps (no frames from the camera)"
    fi
  done <"$TMP/cams"

  jq -r '(.detectors // {}) | to_entries[] |
         [.key, (.value.inference_speed // "null" | tostring), (.value.inference_speed == 10)] | @tsv' \
    "$TMP/stats" >"$TMP/dets"
  if [ ! -s "$TMP/dets" ]; then
    red "detectors: none in /stats"
  fi
  while IFS=$'\t' read -r det speed sentinel; do
    if [ "$sentinel" = "true" ]; then
      red "detector $det: inference_speed=$speed — NOT PROVEN (Frigate's never-ran sentinel: no inference measured)"
    elif awk -v v="$speed" 'BEGIN { exit !(v ~ /^[0-9.]+$/ && v + 0 > 0) }'; then
      green "detector $det: inference_speed=$speed ms"
    else
      red "detector $det: inference_speed=$speed (not a measurement)"
    fi
  done <"$TMP/dets"
fi

# (d) person/car events since the window start --------------------------------------------------------
code=$(api_get "/events?after=$START&labels=person,car&limit=$EVENTS_LIMIT" "$TMP/events")
if [ "$code" != "200" ] || ! jq -e 'type == "array"' "$TMP/events" >/dev/null 2>&1; then
  red "events: $API/events unreachable or not a JSON array (http=${code:-000})"
else
  n=$(jq 'length' "$TMP/events")
  if [ "$n" -eq 0 ]; then
    info "events: 0 person/car events in window"
  else
    jq -r 'group_by(.camera)[] |
           [.[0].camera, (map(select(.label == "person")) | length), (map(select(.label == "car")) | length)] | @tsv' \
      "$TMP/events" | while IFS=$'\t' read -r cam p c; do
        info "events $cam: person=$p car=$c"
      done
    [ "$n" -ge "$EVENTS_LIMIT" ] && info "events: capped at limit=$EVENTS_LIMIT (counts are a floor)"
  fi
fi

if [ "$REDS" -eq 0 ]; then
  echo "SOAK SWEEP: GREEN"
  exit 0
fi
echo "SOAK SWEEP: RED ($REDS red)"
exit 1
