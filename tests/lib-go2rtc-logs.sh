# shellcheck shell=bash
# Sourced by tests/spike-smoke.sh (and tests/lib-go2rtc-logs.test.sh). Not executable on its own.
#
# go2rtc_logs_has_content [URL] — exit 0 iff the Frigate /logs/go2rtc tab serves real go2rtc output:
#   HTTP 200, a JSON {lines: [...]} body, and at least one line in go2rtc's own line SHAPE
#   (zerolog console: "HH:MM:SS.mmm LVL <module-or-word> ...", e.g. "04:28:14.916 WRN [rtsp] ...").
# W-3 (M8 finding F1): the previous check grepped for startup words (go2rtc|[api]|listen). On a
# long-running host the bounded log is flooded by "WRN [rtsp]" camera-dial lines and the banner has
# rotated out, so it false-FAILed a healthy tab; it also false-PASSed any error body that merely
# mentioned "go2rtc". Shape, not vocabulary: a fresh install's banner lines carry the same shape.
# The body is read from a private mktemp file and deleted — never printed or persisted
# (daemon stdout can echo camera/producer URLs with credentials).
GO2RTC_LINE_RE='(^|[[:space:]])[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)? (TRC|DBG|INF|WRN|ERR|FTL|PNC) [^[:space:]]'

go2rtc_logs_has_content() {
  local url="${1:-http://127.0.0.1:5001/logs/go2rtc}" body code rc=1
  body=$(mktemp) || return 1
  # 0.18: /logs/{service} is require_role(["admin"]) (R§5.4)
  code=$(curl -s -o "$body" -w '%{http_code}' -H 'Remote-User: admin' -H 'Remote-Role: admin' --max-time 5 "$url" 2>/dev/null)
  # grep -c, not grep -q: callers run under `set -o pipefail`, and on a host-sized body (M8 F1:
  # 67k lines / 9 MB) an early-exiting grep -q SIGPIPEs jq (141) and fails a matching pipeline.
  if [ "$code" = "200" ] &&
     [ "$(jq -r '.lines[]?' "$body" 2>/dev/null | grep -cE "$GO2RTC_LINE_RE")" -gt 0 ]; then
    rc=0
  fi
  rm -f "$body"
  return "$rc"
}
