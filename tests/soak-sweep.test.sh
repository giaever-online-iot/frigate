#!/usr/bin/env bash
# Unit tests for tests/soak-sweep.sh (W-3 part 2). Hermetic: PATH-shadowed curl, journalctl and
# systemctl stubs serve canned fixtures; never touches the live host or its journal.
# Run: bash tests/soak-sweep.test.sh   (exit 0 = every case as expected)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SWEEP="$HERE/soak-sweep.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export STUB_DIR="$T/fx"

# curl stub: routes by URL path to $STUB_DIR/{stats,events}.json (status ${STATS_CODE,EVENTS_CODE}:-200);
# a missing fixture file = connection refused (no body, http_code 000). Records each URL.
cat >"$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""; w=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) w="$2"; shift 2 ;;
    -H|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "$url" >>"$STUB_DIR/curl.urls"
case "$url" in
  */stats*)  f="$STUB_DIR/stats.json";  code="${STATS_CODE:-200}" ;;
  */events*) f="$STUB_DIR/events.json"; code="${EVENTS_CODE:-200}" ;;
  *) f=/nonexistent; code=404 ;;
esac
[ -f "$f" ] || code=000
body=/dev/null; [ -f "$f" ] && body="$f"
if [ -n "$out" ]; then cat "$body" >"$out"; else cat "$body"; fi
[ -n "$w" ] && printf '%s' "${w//%\{http_code\}/$code}"
[ "$code" = 000 ] && exit 7
exit 0
STUB
# journalctl stub: serves $STUB_DIR/journal; -g PATTERN filters it like journalctl's PCRE grep
# (ERE is enough for the patterns used); -n N returns the first N lines. Records its argv.
cat >"$T/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/journalctl.args"
g=""; n=""
while [ $# -gt 0 ]; do
  case "$1" in
    -g) g="$2"; shift 2 ;;
    -n) n="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -f "$STUB_DIR/journal" ] || exit 0
if [ -n "$g" ]; then grep -E -- "$g" "$STUB_DIR/journal" || true
elif [ -n "$n" ]; then head -n "$n" "$STUB_DIR/journal"
else cat "$STUB_DIR/journal"; fi
STUB
# systemctl stub: `systemctl show UNIT ...` prints $STUB_DIR/units/UNIT (key=value lines).
cat >"$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = show ] || exit 1
f="$STUB_DIR/units/$2"
if [ -f "$f" ]; then cat "$f"; else printf 'LoadState=not-found\nActiveState=inactive\nNRestarts=0\n'; fi
STUB
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

# --- fixture builders -------------------------------------------------------------------------
unit() { printf 'LoadState=loaded\nActiveState=%s\nSubState=%s\nNRestarts=%s\n' "$2" "$3" "$4" \
  >"$STUB_DIR/units/snap.frigate.$1.service"; }
green_fixtures() {
  rm -rf "$STUB_DIR"; mkdir -p "$STUB_DIR/units"
  for s in go2rtc frigate nginx certsync; do unit "$s" active running 0; done
  cat >"$STUB_DIR/stats.json" <<'EOF'
{"cameras": {"cam1": {"camera_fps": 5.0, "process_fps": 5.0, "detection_fps": 1.2, "skipped_fps": 0.0},
             "cam2": {"camera_fps": 4.9, "process_fps": 4.9, "detection_fps": 0.0, "skipped_fps": 0.0}},
 "detectors": {"ov": {"inference_speed": 7.53, "detection_start": 0.0, "pid": 1234}},
 "service": {"uptime": 3600, "version": "0.17.2"}}
EOF
  cat >"$STUB_DIR/events.json" <<'EOF'
[{"id": "1", "label": "person", "camera": "cam1"}, {"id": "2", "label": "person", "camera": "cam1"},
 {"id": "3", "label": "person", "camera": "cam2"}, {"id": "4", "label": "car", "camera": "cam2"}]
EOF
  cat >"$STUB_DIR/journal" <<'EOF'
[2026-11-11 03:00:00] frigate.app                    INFO    : Starting Frigate (0.17.2)
[2026-11-11 03:00:01] frigate.app                    INFO    : Capture process started for cam1
EOF
}

FAILS=0
OUT=""; RC=0
run() { : >"$STUB_DIR/curl.urls"; : >"$STUB_DIR/journalctl.args"; OUT=$(bash "$SWEEP" "$@" 2>&1); RC=$?; }
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; FAILS=$((FAILS+1)); printf '%s\n' "$OUT" | sed 's/^/       | /'; }
want_rc()   { if [ "$RC" -eq "$2" ]; then ok "$1: exit $RC"; else bad "$1: wanted exit $2, got $RC"; fi; }
want_line() { if printf '%s\n' "$OUT" | grep -qE -- "$2"; then ok "$1"; else bad "$1: no line matching /$2/"; fi; }
want_no()   { if printf '%s\n' "$OUT" | grep -qE -- "$2"; then bad "$1: forbidden /$2/ present"; else ok "$1"; fi; }

# 1. everything green -------------------------------------------------------------------------
green_fixtures; run --since -1h
want_rc   "all green" 0
want_line "all green: verdict line"           '^SOAK SWEEP: GREEN'
want_line "all green: cam1 fps reported"      '^GREEN +camera cam1: camera_fps=5(\.0)? detection_fps=1\.2'
want_line "all green: detector proven"        '^GREEN +detector ov: inference_speed=7\.53'
want_line "all green: events per camera"      '^INFO +events cam1: person=2 car=0'
want_line "all green: events cam2"            '^INFO +events cam2: person=1 car=1'
want_line "all green: zero ERROR lines"       '^GREEN +frigate ERROR lines: 0'
for s in go2rtc frigate nginx certsync; do
  want_line "all green: service $s"           "^GREEN +service $s: active, NRestarts=0"
done

# 2. a camera at 0 fps ------------------------------------------------------------------------
green_fixtures
jq '.cameras.cam2.camera_fps = 0.0 | .cameras.cam2.process_fps = 0' "$STUB_DIR/stats.json" >"$T/s" && mv "$T/s" "$STUB_DIR/stats.json"
run --since -1h
want_rc   "cam2 0 fps" 1
want_line "cam2 0 fps: camera named RED"      '^RED +camera cam2: camera_fps=0(\.0)?'
want_line "cam2 0 fps: cam1 still GREEN"      '^GREEN +camera cam1:'
want_line "cam2 0 fps: verdict"               '^SOAK SWEEP: RED'

# 3. never-ran sentinel: inference_speed exactly 10.0 => NOT PROVEN (RED, exit 1) ------------------
green_fixtures
jq '.detectors.ov.inference_speed = 10.0' "$STUB_DIR/stats.json" >"$T/s" && mv "$T/s" "$STUB_DIR/stats.json"
run --since -1h
want_rc   "inference 10.0 sentinel" 1
want_line "inference 10.0: NOT PROVEN"        '^RED +detector ov: inference_speed=10(\.0)? .*NOT PROVEN'
# ...and 10.01 is a real measurement, not the sentinel
green_fixtures
jq '.detectors.ov.inference_speed = 10.01' "$STUB_DIR/stats.json" >"$T/s" && mv "$T/s" "$STUB_DIR/stats.json"
run --since -1h
want_rc   "inference 10.01 is real" 0

# 4. service inactive / restarted -------------------------------------------------------------
green_fixtures; unit nginx failed failed 0; run --since -1h
want_rc   "nginx inactive" 1
want_line "nginx inactive: named"             '^RED +service nginx: failed'
green_fixtures; unit frigate active running 2; run --since -1h
want_rc   "frigate NRestarts=2" 1
want_line "frigate NRestarts=2: named"        '^RED +service frigate: active, NRestarts=2'
green_fixtures; rm "$STUB_DIR/units/snap.frigate.certsync.service"; run --since -1h
want_rc   "certsync unit missing" 1
want_line "certsync missing: named"           '^RED +service certsync:'

# 5. Frigate ERROR lines counted by logger, via -g; messages never printed -----------------------
green_fixtures
cat >>"$STUB_DIR/journal" <<'EOF'
[2026-11-11 03:10:00] ffmpeg.cam1.detect             ERROR   : rtsp://user:s3cretpw@192.0.2.10:554/stream1: Connection refused
[2026-11-11 03:10:10] ffmpeg.cam1.detect             ERROR   : rtsp://user:s3cretpw@192.0.2.10:554/stream1: Connection refused
[2026-11-11 03:10:20] ffmpeg.cam1.detect             ERROR   : rtsp://user:s3cretpw@192.0.2.10:554/stream1: Connection refused
[2026-11-11 03:10:30] frigate.video                  ERROR   : cam1: Unable to read frames from ffmpeg process.
[2026-11-11 03:10:31] frigate.data_processing.real_time.face_long ERROR   : one-space logger longer than 30 columns
[2026-11-11 03:10:40] frigate.app                    INFO    : message that quotes "ERROR   : not a real error"
[2026-11-11 03:10:41] frigate.app                    INFO    : [rtsp @ 0x55d0] relay ERROR : bracketed relay, not a logger
EOF
run --since -1h
want_rc   "ERROR lines present" 1
want_line "ERROR lines: total 5"              '^RED +frigate ERROR lines: 5'
want_line "ERROR lines: by logger (3)"        '^ +3 +ffmpeg\.cam1\.detect$'
want_line "ERROR lines: by logger (1)"        '^ +1 +frigate\.video$'
want_line "ERROR lines: long logger counted"  '^ +1 +frigate\.data_processing\.real_time\.face_long$'
want_no   "ERROR lines: INFO quoting ERROR not counted" '^ +[0-9]+ +frigate\.app$'
want_no   "ERROR lines: bracket inside message not a logger" '^ +[0-9]+ +relay$'
if grep -qE -- '(^| )-g ' "$STUB_DIR/journalctl.args"; then ok "journalctl called with -g"; else bad "journalctl not called with -g"; fi
if grep -qE -- '-u snap\.frigate\.frigate\.service' "$STUB_DIR/journalctl.args"; then ok "journalctl scoped to frigate unit"; else bad "journalctl not scoped to the frigate unit"; fi
want_no   "no credential leak (password)"     's3cretpw'
want_no   "no camera URL leak"                'rtsp://|192\.0\.2\.10'
want_no   "no message text leak"              'Connection refused|Unable to read'

# 6. /stats unreachable / not JSON / no cameras / no detectors --------------------------------------
green_fixtures; rm "$STUB_DIR/stats.json"; run --since -1h
want_rc   "stats unreachable" 1
want_line "stats unreachable: RED"            '^RED +stats: '
green_fixtures; export STATS_CODE=500; run --since -1h; unset STATS_CODE
want_rc   "stats HTTP 500" 1
green_fixtures; printf '<html>oops</html>' >"$STUB_DIR/stats.json"; run --since -1h
want_rc   "stats not JSON" 1
green_fixtures; printf '{"cameras": {}, "detectors": {"ov": {"inference_speed": 7.5}}}' >"$STUB_DIR/stats.json"; run --since -1h
want_rc   "stats no cameras" 1
want_line "stats no cameras: RED"             '^RED +cameras: none'
green_fixtures; jq 'del(.detectors)' "$STUB_DIR/stats.json" >"$T/s" && mv "$T/s" "$STUB_DIR/stats.json"; run --since -1h
want_rc   "stats no detectors" 1

# 7. journal unreadable (no frigate line ever) — cannot prove zero errors ---------------------------
green_fixtures; rm "$STUB_DIR/journal"; run --since -1h
want_rc   "journal unreadable" 1
want_line "journal unreadable: RED"           '^RED +frigate ERROR lines: journal unreadable'

# 8. events: window start passed as after=<epoch>; the same instant goes to journalctl -------------
green_fixtures; NOW=$(date +%s); run --since -1h
AFTER=$(grep -oE 'after=[0-9]+' "$STUB_DIR/curl.urls" | head -1 | cut -d= -f2)
if [ -n "$AFTER" ] && [ $((NOW - 3600 - AFTER)) -le 5 ] && [ $((AFTER - (NOW - 3600))) -le 5 ]; then
  ok "events after= is now-1h (±5s)"; else bad "events after='$AFTER', want ~$((NOW-3600))"; fi
if grep -qE -- "--since @$AFTER" "$STUB_DIR/journalctl.args"; then ok "journalctl --since uses the same @epoch"; else bad "journalctl --since not @$AFTER"; fi
green_fixtures; rm "$STUB_DIR/events.json"; run --since -1h
want_rc   "events unreachable" 1
want_line "events unreachable: RED"           '^RED +events: '
green_fixtures; printf '[]' >"$STUB_DIR/events.json"; run --since -1h
want_rc   "zero events is informational" 0
want_line "zero events: INFO"                 '^INFO +events: 0 person/car events in window'

# 9. argument handling ------------------------------------------------------------------------
green_fixtures; run --since 'not a time at all'
want_rc   "bad --since" 2
run --bogus
want_rc   "unknown flag" 2
NOW=$(date +%s); run --since -90m
want_rc   "--since -90m accepted" 0
AFTER=$(grep -oE 'after=[0-9]+' "$STUB_DIR/curl.urls" | head -1 | cut -d= -f2)
if [ -n "$AFTER" ] && [ $((NOW - 5400 - AFTER)) -le 5 ] && [ $((AFTER - (NOW - 5400))) -le 5 ]; then
  ok "-90m resolves to now-5400s (±5s)"; else bad "-90m resolved to after='$AFTER', want ~$((NOW-5400))"; fi
run --since '2026-11-11 03:00'
want_rc   "--since absolute date accepted" 0
run
want_rc   "default window" 0
want_line "default window is -24h"            '^soak-sweep: window since -24h '

echo "soak-sweep: $FAILS unexpected result(s)"
[ "$FAILS" -eq 0 ]
