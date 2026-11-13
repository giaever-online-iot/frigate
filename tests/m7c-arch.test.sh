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


# --- T2 detector (V4 matrix) ---
mkroot() { local r="$TMP/root-$1"; rm -rf "$r"; mkdir -p "$r/dev/dri"
  if [ "$1" != none ]; then : > "$r/dev/dri/renderD128"; mkdir -p "$r/sys/class/drm/renderD128/device"; echo "$1" > "$r/sys/class/drm/renderD128/device/vendor"; fi
  echo "$r"; }
render() { local root; root=$(mkroot "$2")
  ( if [ "$1" = unset ]; then unset SNAP_ARCH; else SNAP_ARCH="$1"; fi
    DETECTOR_SYSFS_ROOT="$root"; FAKE_DET="$3"
    snapctl() { [ "$1 $2" = "get detector" ] && [ "$FAKE_DET" != unset ] && printf '%s' "$FAKE_DET"; return 0; }
    . "$LIBWAIT"; s=$(detector_sed 2>"$TMP/err")
    sed -e "$s" spike/config/frigate-config.yml | awk '/^detectors:/{getline; gsub(/[ :]/,""); print; exit}' ); }
WARN='frigate-run: WARN detector=ov is not available on arm64 (no OpenVINO GPU plugin); rendering the cpu detector'
while read -r a v d want w; do
  [ -z "$a" ] && continue
  t "T2: $a/$v/detector=$d -> $want" test "$(render "$a" "$v" "$d")" = "$want"
  if [ "$w" = y ]; then t "T2: $a/$v/$d warns" grep -qxF "$WARN" "$TMP/err"
  else t "T2: $a/$v/$d no warn" test ! -s "$TMP/err"; fi
done <<'EOF'
amd64 none   unset cpu   n
amd64 0x8086 unset ov    n
amd64 0x1002 unset ov    n
amd64 0x1af4 unset cpu   n
amd64 none   ov    ov    n
amd64 0x8086 ov    ov    n
amd64 0x1002 ov    ov    n
amd64 0x1af4 ov    ov    n
amd64 none   cpu   cpu   n
amd64 0x8086 cpu   cpu   n
amd64 0x1002 cpu   cpu   n
amd64 0x1af4 cpu   cpu   n
amd64 none   coral coral n
amd64 0x8086 coral coral n
amd64 0x1002 coral coral n
amd64 0x1af4 coral coral n
amd64 0x8086 bogus ov    n
arm64 none   unset cpu   n
arm64 0x8086 unset cpu   n
arm64 0x1002 unset cpu   n
arm64 0x1af4 unset cpu   n
arm64 none   ov    cpu   y
arm64 0x8086 ov    cpu   y
arm64 0x1002 ov    cpu   y
arm64 0x1af4 ov    cpu   y
arm64 none   cpu   cpu   n
arm64 0x8086 cpu   cpu   n
arm64 0x1002 cpu   cpu   n
arm64 0x1af4 cpu   cpu   n
arm64 none   coral coral n
arm64 0x8086 coral coral n
arm64 0x1002 coral coral n
arm64 0x1af4 coral coral n
arm64 0x8086 bogus cpu   y
unset 0x8086 unset ov    n
unset none   unset cpu   n
EOF
t "T2: _arch_has_ov is a one-line definition" test "$(grep -c '^_arch_has_ov() { \[ "\${SNAP_ARCH:-amd64}" = amd64 \]; }$' "$LIBWAIT")" = 1

# --- T2 config_uses_openvino ---
cuo() { printf '%b' "$1" > "$TMP/cfg.yml"; ( . "$LIBWAIT"; config_uses_openvino "$TMP/cfg.yml" ); }
t "T2: openvino block detected"          cuo 'detectors:\n  ov:\n    type: openvino\n    device: GPU\n'
t "T2: openvino with comment detected"   cuo 'detectors:\n  ov:\n    type: openvino  # gpu\n'
t "T2: cpu block not flagged"            sh -c "! ( printf 'detectors:\n  cpu:\n    type: cpu\n' > '$TMP/c2.yml'; . '$LIBWAIT'; config_uses_openvino '$TMP/c2.yml' )"
t "T2: commented-out openvino ignored"   sh -c "! ( printf 'detectors:\n  cpu:\n    type: cpu\n#    type: openvino\n' > '$TMP/c3.yml'; . '$LIBWAIT'; config_uses_openvino '$TMP/c3.yml' )"
t "T2: missing file is not flagged"      sh -c "! ( . '$LIBWAIT'; config_uses_openvino '$TMP/nope.yml' )"

# --- T3 wiring ---
t "T3: x86_64-linux-gnu literal only in the two triplet helpers" sh -c "[ -z \"\$(grep -rln --exclude-dir=__pycache__ 'x86_64-linux-gnu' spike/bin spike/probes | grep -vxE 'spike/bin/lib-wait.sh|spike/probes/probe_common.py')\" ]"
t "T3: imports-probe sources lib-wait.sh"   grep -q '^\. "\$SNAP/bin/lib-wait.sh"' spike/bin/imports-probe
t "T3: wrappers resolve the triplet alone"  sh -c "grep -q '^_TRIPLET=\$(arch_triplet)\$' spike/bin/imports-probe && grep -q '^_TRIPLET=\$(arch_triplet)\$' spike/bin/validate-config"
t "T3: frigate-run sets SHM_MAX_FRAMES"     sh -c "grep -qx 'SHM_MAX_FRAMES=\$(shm_max_frames)' spike/bin/frigate-run && grep -qx 'export SHM_MAX_FRAMES' spike/bin/frigate-run"
t "T3: frigate-run logs the D10 ERROR line" grep -qF 'frigate-run: ERROR config.yml uses the openvino detector, which cannot run on arm64; set it to cpu or coral (or delete config.yml to re-render)' spike/bin/frigate-run
t "T3: stale ~50% RAM shm note gone"        sh -c "! grep -q 'default sizing (~50% RAM)' $Y"

[ "$FAILS" -eq 0 ]
