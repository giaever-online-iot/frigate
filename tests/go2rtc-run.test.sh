#!/usr/bin/env bash
# bin/go2rtc-run against a stub $SNAP tree (no real snap, no real go2rtc): the generator gets the
# cameras dir as its 5th argument, ezviz-rearm starts before go2rtc, its output lands in the go2rtc
# log, and go2rtc is exec'd (same PID as the script). W-23 T14 (D19).
# Run: bash tests/go2rtc-run.test.sh   (exit 0 = all checks ok)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
RUN=${GO2RTC_RUN:-$PWD/spike/bin/go2rtc-run}
fail=0; T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }

S=$T/snap; D=$T/data
mkdir -p "$S/usr/bin" "$S/bin" "$S/config" "$S/usr/local/go2rtc/bin" "$D/config"
cat > "$S/usr/bin/python3.11" <<'STUB'
#!/bin/sh
printf '%s\n' "$#" "$@" > "$SNAP_DATA/gen.argv"
STUB
cat > "$S/bin/ezviz-rearm" <<'STUB'
#!/bin/sh
echo "rearm-started" > "$SNAP_DATA/rearm.marker"
echo "REARM-LINE"
STUB
cat > "$S/usr/local/go2rtc/bin/go2rtc" <<'STUB'
#!/bin/sh
echo "$$" > "$SNAP_DATA/go2rtc.pid"
# rearm is a background child: give it up to 2 s to have run (never, if it is started after this exec)
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -f "$SNAP_DATA/rearm.marker" ] && break; sleep 0.1; done
if [ -f "$SNAP_DATA/rearm.marker" ]; then echo yes > "$SNAP_DATA/rearm-before-go2rtc"; fi
echo "GO2RTC-LINE"
STUB
chmod +x "$S/usr/bin/python3.11" "$S/bin/ezviz-rearm" "$S/usr/local/go2rtc/bin/go2rtc"
: > "$S/bin/go2rtc-config-gen.py"

SNAP=$S SNAP_DATA=$D bash -c 'echo "$$" > "$SNAP_DATA/script.pid"; exec "$0"' "$RUN" > "$T/out" 2>&1
check "go2rtc-run exits 0" 0 $?
sleep 0.5  # the tee processes drain asynchronously

check "generator got script + 5 args" 6 "$(sed -n 1p "$D/gen.argv")"
check "generator 5th arg is the cameras dir" "$D/ezviz/cameras" "$(sed -n 7p "$D/gen.argv")"
check "generator 4th arg unchanged" "$D/go2rtc.yaml" "$(sed -n 6p "$D/gen.argv")"
check "ezviz-rearm started before go2rtc exec" yes "$(cat "$D/rearm-before-go2rtc" 2>/dev/null || echo no)"
check "rearm output in go2rtc-logs/current" 1 "$(grep -c '^REARM-LINE$' "$D/go2rtc-logs/current")"
check "go2rtc output in go2rtc-logs/current" 1 "$(grep -c '^GO2RTC-LINE$' "$D/go2rtc-logs/current")"
check "go2rtc is exec'd (same PID as the script)" "$(cat "$D/script.pid")" "$(cat "$D/go2rtc.pid")"
exit "$fail"
