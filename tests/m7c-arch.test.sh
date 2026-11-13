#!/usr/bin/env bash
# M7c static + unit assertions. Run from any cwd: bash tests/m7c-arch.test.sh  (exit 0 = all ok)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
FAILS=0
t() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok   - $n"; else echo "FAIL - $n"; FAILS=$((FAILS+1)); fi; }
part() { awk -v p="  $2:" '/^parts:/{inp=1;next} /^[a-z]/{inp=0} inp&&$0==p{f=1;print;next} f&&/^  [a-z0-9-]+:$/{exit} f' "$1"; }
export -f part
LIBWAIT="${LIBWAIT:-spike/bin/lib-wait.sh}"
Y="${M7C_YAML:-snap/snapcraft.yaml}"; export Y
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- T1 arch_triplet ---
trip() { ( SNAP_ARCH="$1"; . "$LIBWAIT"; arch_triplet ); }
t "T1: amd64 -> x86_64-linux-gnu"        test "$(trip amd64)" = "x86_64-linux-gnu"
t "T1: arm64 -> aarch64-linux-gnu"       test "$(trip arm64)" = "aarch64-linux-gnu"
t "T1: armhf fails loud (rc!=0)"         sh -c "! ( SNAP_ARCH=armhf; . '$LIBWAIT'; arch_triplet )"
t "T1: empty SNAP_ARCH fails loud"       sh -c "! ( SNAP_ARCH=; . '$LIBWAIT'; arch_triplet )"
t "T1: failure names the value"          sh -c "( SNAP_ARCH=armhf; . '$LIBWAIT'; arch_triplet ) 2>&1 | grep -qF \"unsupported SNAP_ARCH 'armhf'\""
t "T1: set -e wrapper aborts on armhf"   sh -c "! SNAP_ARCH=armhf sh -ec '. \"$LIBWAIT\"; _T=\$(arch_triplet); echo reached' | grep -q reached"

# --- T1 shm_max_frames ---
smf() { mkdir -p "$TMP/c"; rm -f "$TMP/c/shm-max-frames"; [ "$1" = "<absent>" ] || printf '%b' "$1" > "$TMP/c/shm-max-frames"
        ( SNAP_COMMON="$TMP/c"; . "$LIBWAIT"; shm_max_frames ); }
for row in "<absent>|50" "10|10" "10\n|10" " 7 |7" "1|1" "200|200" "0|50" "201|50" "999|50" "-5|50" "abc|50" "|50" "1e2|50"; do
  in="${row%|*}"; want="${row##*|}"
  t "T1: shm_max_frames '$in' -> $want" test "$(smf "$in")" = "$want"
done

[ "$FAILS" -eq 0 ]
