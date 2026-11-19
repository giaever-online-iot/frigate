#!/usr/bin/env bash
# Hermetic test of spike/bin/disk-guard (W-23 D13): stub snapctl and df on PATH. Run: bash tests/disk-guard.test.sh [sh|dash]
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SHELL_UNDER_TEST="${1:-sh}"; FAILS=0; SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; FAILS=$((FAILS+1)); fi; }
# case NAME FREE_GIB FLOOR(or "") FRIGATE_STATE [DF_FAILS] [STOP_MODE: ok|fail|noop|blind]
#   STOP_MODE ok: stop exits 0 and the state flips to inactive (R2-N10); fail: rc 1, state stays; noop: rc 0, state stays.
case_() {
  local free=$2 floor=$3 state=$4 dffail=${5:-0} stopmode=${6:-ok} d="$SB/$1"; mkdir -p "$d/bin"
  printf '%s\n' "$state" > "$d/state"
  cat > "$d/bin/snapctl" <<EOF
#!/bin/sh
echo "\$*" >> "$d/calls"
case "\$1 \$2" in
  "get disk-floor-gib") [ -n "$floor" ] && echo "$floor"; exit 0 ;;
  "services frigate.frigate") [ -f "$d/blind" ] && exit 1; printf 'Service          Startup  Current  Notes\nfrigate.frigate  enabled  %s  -\n' "\$(cat "$d/state")" ;;
  "stop --disable")
    case "$stopmode" in
      ok) echo inactive > "$d/state"; exit 0 ;;
      fail) exit 1 ;;
      noop) exit 0 ;;
      blind) echo blind > "$d/blind"; exit 0 ;;
    esac ;;
esac
EOF
  cat > "$d/bin/df" <<EOF
#!/bin/sh
echo "\$*" >> "$d/dfargs"
[ "$dffail" = 1 ] && exit 1
printf 'Filesystem 1-blocks Used Available Capacity Mounted on\n/dev/x 1 1 %s 50%% /\n' "\$(( $free * 1073741824 ))"
EOF
  chmod +x "$d/bin/snapctl" "$d/bin/df"; : > "$d/calls"; : > "$d/dfargs"
  env PATH="$d/bin:$PATH" SNAP_COMMON="$d/common" "$SHELL_UNDER_TEST" spike/bin/disk-guard > "$d/out" 2>&1; echo $? > "$d/rc"
}
stops() { grep -c '^stop --disable frigate.frigate$' "$SB/$1/calls"; }
case_ a 19 "" active;  check "19 GiB, floor default 20, active: stop once" 1 "$(stops a)"
check "19 GiB: one line naming 19 and 20" "disk-guard: free 19 GiB below floor 20 GiB: stopped and disabled frigate.frigate" "$(cat "$SB/a/out")"
check "19 GiB: exit 0" 0 "$(cat "$SB/a/rc")"
check "df reads \$SNAP_COMMON/media/frigate (C29)" "-P -B1 $SB/a/common/media/frigate" "$(cat "$SB/a/dfargs")"
case_ b 21 "" active;  check "21 GiB: no stop" 0 "$(stops b)"; check "21 GiB: no line" "" "$(cat "$SB/b/out")"
case_ c 25 30 active;  check "25 GiB, floor 30: stop" 1 "$(stops c)"
case_ d 10 "" inactive; check "10 GiB, frigate inactive: no stop" 0 "$(stops d)"; check "inactive: no line" "" "$(cat "$SB/d/out")"
case_ e 10 "" active 1; check "df fails: exit 1" 1 "$(cat "$SB/e/rc")"; check "df fails: no stop" 0 "$(stops e)"
check "df fails: says so" "disk-guard: cannot read free space" "$(cat "$SB/e/out")"
case_ f 10 abc active; check "floor abc: exit 1, no stop" "1 0" "$(cat "$SB/f/rc") $(stops f)"
# R2-N10: the stop is verified
case_ g 19 "" active 0 fail
check "stop rc 1: exit 1" 1 "$(cat "$SB/g/rc")"
check "stop rc 1: FAILED line" "disk-guard: free 19 GiB below floor 20 GiB: stop FAILED" "$(cat "$SB/g/out")"
check "stop rc 1: no 'stopped' line" 0 "$(grep -c 'stopped and disabled' "$SB/g/out")"
case_ h 19 "" active 0 noop
check "stop rc 0 but still active: exit 1" 1 "$(cat "$SB/h/rc")"
check "stop rc 0 but still active: FAILED line" "disk-guard: free 19 GiB below floor 20 GiB: stop FAILED" "$(cat "$SB/h/out")"
check "stop rc 0 but still active: no 'stopped' line" 0 "$(grep -c 'stopped and disabled' "$SB/h/out")"
case_ i 19 "" active 0 blind
check "stop rc 0 but re-read fails: exit 1" 1 "$(cat "$SB/i/rc")"
check "stop rc 0 but re-read fails: FAILED line" "disk-guard: free 19 GiB below floor 20 GiB: stop FAILED" "$(cat "$SB/i/out")"
[ "$FAILS" = 0 ] && echo "disk-guard.test: all ok" || echo "disk-guard.test: FAILURES"
exit "$FAILS"
