#!/usr/bin/env bash
# Unit tests for tests/lib-go2rtc-logs.sh (W-3 part 1: the /logs go2rtc false-fail).
# Hermetic: a PATH-shadowed `curl` stub serves canned bodies; never touches the live host.
# Run: bash tests/lib-go2rtc-logs.test.sh   (exit 0 = all cases as expected)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib-go2rtc-logs.sh
. "$HERE/lib-go2rtc-logs.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# curl stub: body from $STUB_BODY (a file), status from $STUB_CODE. Honours -o FILE and -w FMT
# (only %{http_code}); every other flag/arg is ignored. Mirrors real curl -s semantics closely
# enough for the predicate: body to -o target (or stdout), the -w text to stdout after it.
cat >"$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""; w=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) w="$2"; shift 2 ;;
    -H|--max-time) shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "$out" ]; then cat "$STUB_BODY" >"$out"; else cat "$STUB_BODY"; fi
[ -n "$w" ] && printf '%s' "${w//%\{http_code\}/$STUB_CODE}"
exit 0
STUB
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH"

FAILS=0
# expect <PASS|FAIL> <name> <http_code> <body-file>
expect() {
  local want="$1" name="$2"; export STUB_CODE="$3" STUB_BODY="$4"
  local got=FAIL
  # shellcheck disable=SC2119 # default URL is intended; the stub ignores it
  go2rtc_logs_has_content && got=PASS
  if [ "$got" = "$want" ]; then echo "ok   - $name (predicate $got)"
  else echo "FAIL - $name: wanted $want, predicate said $got"; FAILS=$((FAILS+1)); fi
}

# Fixtures: the exact shape Frigate's /logs/go2rtc returns — JSON {totalLines, lines[]}, each line
# prefixed by process_logs() with "<datetime.now()>  " (go2rtc's own lines have no double space).
TS='2026-11-11 04:34:25.140613'
: >"$T/empty"
printf '%s' '{"success": false, "message": "Could not find log file"}' >"$T/err500"
printf '%s' '{"totalLines": 0, "lines": []}' >"$T/nolines"
# A 200 error-ish body that happens to contain the old grep's words but no go2rtc line shape.
printf '%s' '{"success": false, "message": "go2rtc log not ready"}' >"$T/err200words"
# Long-running host: banner rotated out, bounded log flooded with WRN [rtsp] dial errors
# (the 2026-11-11 --nvr-safe false-fail). Messages are synthetic — no URLs.
{
  printf '{"totalLines": 200, "lines": ['
  for i in $(seq 1 200); do
    [ "$i" -gt 1 ] && printf ','
    printf '"%s  04:%02d:%02d.%03d WRN [rtsp] error=\\"synthetic dial error\\" stream=cam%d"' \
      "$TS" $((i/60)) $((i%60)) "$i" $((i%2+1))
  done
  printf ']}'
} >"$T/flooded"
# Host-sized flood (M8 F1: 67,458 lines / 9.2 MB). Under `set -o pipefail` an early-exiting
# `grep -q` SIGPIPEs the upstream writer (exit 141) — the pipeline must still count as a match.
{
  printf '{"totalLines": 70000, "lines": ['
  awk -v ts="$TS" 'BEGIN { for (i = 1; i <= 70000; i++) {
    if (i > 1) printf ",";
    printf "\"%s  04:%02d:%02d.%03d WRN [rtsp] error=\\\"synthetic dial error %0100d\\\" stream=cam%d\"", ts, int(i/60)%60, i%60, i%1000, i, i%2+1 } }'
  printf ']}'
} >"$T/hostflood"
# Fresh install: startup banner lines present.
cat >"$T/banner" <<EOF
{"totalLines": 4, "lines": [
"$TS  04:28:14.914 INF go2rtc platform=linux/amd64 revision=dfe4755 version=1.9.13",
"$TS  04:28:14.915 INF config path=/var/snap/frigate/common/go2rtc.yaml",
"$TS  04:28:14.916 INF [api] listen addr=127.0.0.1:1984",
"$TS  04:28:14.917 INF [rtsp] listen addr=:8554"]}
EOF
# 200 + lines, but nothing in go2rtc's line shape (e.g. a wrong file served as the tab).
cat >"$T/wrongshape" <<EOF
{"totalLines": 2, "lines": ["$TS  127.0.0.1 - - GET /api/stats 200", "$TS  hello world"]}
EOF

# 200 + go2rtc-shaped text that is NOT the /logs JSON envelope (route/shape changed: the UI tab
# parses {lines: [...]} and would render nothing) — must FAIL, not grep raw text.
printf '04:28:14.916 INF [api] listen addr=127.0.0.1:1984\n' >"$T/plaintext"

expect FAIL "empty body"                              200 "$T/empty"
expect FAIL "HTTP 500 + JSON error body"              500 "$T/err500"
expect FAIL "HTTP 200 + zero lines"                   200 "$T/nolines"
expect FAIL "HTTP 200 + error JSON naming go2rtc"     200 "$T/err200words"
expect FAIL "HTTP 200 + non-go2rtc line shape"        200 "$T/wrongshape"
expect FAIL "HTTP 500 even with go2rtc-shaped body"   500 "$T/banner"
expect FAIL "HTTP 200 + plain text, not JSON lines"   200 "$T/plaintext"
expect PASS "flooded WRN [rtsp] (banner rotated out)" 200 "$T/flooded"
expect PASS "host-sized flood, 70k lines (pipefail+SIGPIPE)" 200 "$T/hostflood"
expect PASS "startup banner lines (fresh install)"    200 "$T/banner"

echo "lib-go2rtc-logs: $FAILS unexpected result(s)"
[ "$FAILS" -eq 0 ]
