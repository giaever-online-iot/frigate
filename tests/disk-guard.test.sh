#!/usr/bin/env bash
# Hermetic test of spike/bin/disk-guard (W-23 D13): stub snapctl, stat and df on PATH. Run: bash tests/disk-guard.test.sh [sh|dash]
# The guard reads free bytes with `stat -f -c '%a %S' <dir>` (available blocks x fundamental block size). It must never
# call df: core26's df is exec-denied by the confined profile (W-23 round 15, F3), so the df stub always fails and
# records every call, and the last check asserts that no case called it.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SHELL_UNDER_TEST="${1:-sh}"; FAILS=0; SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; FAILS=$((FAILS+1)); fi; }
BS=4096   # the stub's fundamental block size; free GiB = blocks * BS / 2^30
# case NAME FREE_GIB FLOOR(or "") FRIGATE_STATE [STAT_MODE] [STOP_MODE: ok|fail|noop|blind]
#   STAT_MODE ok: prints "<blocks> 4096"; fail: rc 1, no output; garbage: "12x 4096"; zerobs: "<blocks> 0";
#   onefield: "<blocks>"; bs512: "<blocks*8> 512" (a block size other than 4096); extra: "<blocks> 4096 9".
#   The stub answers ONLY the exact argument vector -f -c '%a %S' $SNAP_COMMON/media/frigate; any other is rc 1.
#   STOP_MODE ok: stop exits 0 and the state flips to inactive (R2-N10); fail: rc 1, state stays; noop: rc 0, state stays.
case_() {
  local free=$2 floor=$3 state=$4 statmode=${5:-ok} stopmode=${6:-ok} d="$SB/$1"; mkdir -p "$d/bin"
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
  cat > "$d/bin/stat" <<EOF
#!/bin/sh
printf '[%s]' "\$@" >> "$d/statargs"; echo >> "$d/statargs"
[ "\$#" = 4 ] && [ "\$1" = -f ] && [ "\$2" = -c ] && [ "\$3" = '%a %S' ] && [ "\$4" = "$d/common/media/frigate" ] || exit 1
b=\$(( $free * 1073741824 / $BS ))
case "$statmode" in
  ok) echo "\$b $BS" ;;
  fail) exit 1 ;;
  garbage) echo "12x $BS" ;;
  zerobs) echo "\$b 0" ;;
  onefield) echo "\$b" ;;
  bs512) echo "\$(( b * 8 )) 512" ;;
  extra) echo "\$b $BS 9" ;;
esac
EOF
  cat > "$d/bin/df" <<EOF
#!/bin/sh
echo "\$*" >> "$SB/dfcalls"
exit 1
EOF
  chmod +x "$d/bin/snapctl" "$d/bin/stat" "$d/bin/df"; : > "$d/calls"; : > "$d/statargs"
  env PATH="$d/bin:$PATH" SNAP_COMMON="$d/common" "$SHELL_UNDER_TEST" spike/bin/disk-guard > "$d/out" 2>&1; echo $? > "$d/rc"
}
: > "$SB/dfcalls"
stops() { grep -c '^stop --disable frigate.frigate$' "$SB/$1/calls"; }
unreadable() {   # unreadable NAME LABEL: exit 1, the one line, no stop
  check "$2: exit 1" 1 "$(cat "$SB/$1/rc")"
  check "$2: says so" "disk-guard: cannot read free space" "$(cat "$SB/$1/out")"
  check "$2: no stop" 0 "$(stops "$1")"
}
case_ a 19 "" active;  check "19 GiB, floor default 20, active: stop once" 1 "$(stops a)"
check "19 GiB: one line naming 19 and 20" "disk-guard: free 19 GiB below floor 20 GiB: stopped and disabled frigate.frigate" "$(cat "$SB/a/out")"
check "19 GiB: exit 0" 0 "$(cat "$SB/a/rc")"
check "stat argv is exactly -f -c '%a %S' \$SNAP_COMMON/media/frigate (C29)" "[-f][-c][%a %S][$SB/a/common/media/frigate]" "$(cat "$SB/a/statargs")"
case_ b 21 "" active;  check "21 GiB: no stop" 0 "$(stops b)"; check "21 GiB: no line" "" "$(cat "$SB/b/out")"
check "21 GiB: exit 0" 0 "$(cat "$SB/b/rc")"
case_ c 25 30 active;  check "25 GiB, floor 30: stop" 1 "$(stops c)"
case_ d 10 "" inactive; check "10 GiB, frigate inactive: no stop" 0 "$(stops d)"; check "inactive: no line" "" "$(cat "$SB/d/out")"
case_ e 10 "" active fail;     unreadable e "stat fails"
case_ f 10 abc active; check "floor abc: exit 1, no stop" "1 0" "$(cat "$SB/f/rc") $(stops f)"
case_ j 10 "" active garbage;  unreadable j "stat prints garbage (12x)"
case_ k 10 "" active zerobs;   unreadable k "block size 0"
case_ l 10 "" active onefield; unreadable l "one field missing (blocks only)"
case_ m 10 "" active extra;    unreadable m "a third field"
case_ n 21 "" active bs512;    check "block size 512, 21 GiB: no stop (blocks x size)" 0 "$(stops n)"
case_ o 19 "" active bs512;    check "block size 512, 19 GiB: stop once" 1 "$(stops o)"
check "block size 512, 19 GiB: line names 19" "disk-guard: free 19 GiB below floor 20 GiB: stopped and disabled frigate.frigate" "$(cat "$SB/o/out")"
case_ p 0 "" active;           check "0 free blocks: stop once (a full disk is readable)" 1 "$(stops p)"
# R2-N10: the stop is verified
case_ g 19 "" active ok fail
check "stop rc 1: exit 1" 1 "$(cat "$SB/g/rc")"
check "stop rc 1: FAILED line" "disk-guard: free 19 GiB below floor 20 GiB: stop FAILED" "$(cat "$SB/g/out")"
check "stop rc 1: no 'stopped' line" 0 "$(grep -c 'stopped and disabled' "$SB/g/out")"
case_ h 19 "" active ok noop
check "stop rc 0 but still active: exit 1" 1 "$(cat "$SB/h/rc")"
check "stop rc 0 but still active: FAILED line" "disk-guard: free 19 GiB below floor 20 GiB: stop FAILED" "$(cat "$SB/h/out")"
check "stop rc 0 but still active: no 'stopped' line" 0 "$(grep -c 'stopped and disabled' "$SB/h/out")"
case_ i 19 "" active ok blind
check "stop rc 0 but re-read fails: exit 1" 1 "$(cat "$SB/i/rc")"
check "stop rc 0 but re-read fails: FAILED line" "disk-guard: free 19 GiB below floor 20 GiB: stop FAILED" "$(cat "$SB/i/out")"
check "df is never called, in any case (F3: exec-denied under confinement)" "" "$(cat "$SB/dfcalls")"
[ "$FAILS" = 0 ] && echo "disk-guard.test: all ok" || echo "disk-guard.test: FAILURES"
exit "$FAILS"
