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

t "T3: no bytecode in shipped dirs (spike/bin, spike/probes)" sh -c "[ -z \"\$(find spike/bin spike/probes -name '__pycache__' -o -name '*.pyc')\" ]"

# --- T4 snapcraft arch-neutral parts ---
onamd_pkgs()  { yq '.parts.va-tools.stage-packages[] | select(tag == "!!map") | .["on amd64"][]' < "$Y"; }
plain_pkgs()  { yq '.parts.va-tools.stage-packages[] | select(tag == "!!str")' < "$Y"; }
export -f onamd_pkgs plain_pkgs
t "T4: python prime excludes libpython .a by glob" bash -c "part \$Y python311 | grep -qF -- '- -usr/lib/python3.11/config-3.11-*/libpython3.11.a'"
t "T4: no x86-pathed libpython exclude left"      sh -c "! grep -q 'config-3.11-x86_64-linux-gnu' $Y"
for pk in intel-opencl-icd libigdgmm12; do
  t "T4: $pk only under on amd64" bash -c "onamd_pkgs | grep -qx $pk && ! plain_pkgs | grep -qx $pk"
done
t "T4: arm64 stages OpenCL bind source"           bash -c "part \$Y va-tools | grep -qF 'etc/OpenCL/vendors/.keep'"
t "T4: arm64 stages intel-opencl bind source"     bash -c "part \$Y va-tools | grep -qF 'usr/lib/x86_64-linux-gnu/intel-opencl/.keep'"
t "T4: libedgetpu is per-arch, fails loud"        bash -c "part \$Y libedgetpu | grep -qF 'case \"\$CRAFT_ARCH_BUILD_FOR\" in' && part \$Y libedgetpu | grep -q 'libedgetpu: unsupported arch'"
t "T4: libedgetpu amd64 sha kept"                 bash -c "part \$Y libedgetpu | grep -q 63fd00989d29160fa9894e115156a9abe456e88751fc9be89d26e4696200441b"
t "T4: libedgetpu arm64 asset + sha"              bash -c "part \$Y libedgetpu | grep -q 'bookworm_arm64.deb' && part \$Y libedgetpu | grep -q eab8aa4576b4dbf738135d8094f32270b24117f77147d25cbe0f49d0144d85f2"
d5_ok() { [ "$(yq '.platforms | has("arm64")' < "$1")" = true ] || return 0
  for p in ffmpeg go2rtc libedgetpu; do part "$1" "$p" | awk '/arm64\)/{f=1} f&&/[0-9a-f]{64}/{ok=1} f&&/;;/{f=0} END{exit !ok}' || return 1; done; }
export -f d5_ok
t "T4: D5 invariant holds on the real yaml"       d5_ok "$Y"
# Built-in mutation: force platforms arm64 and strip go2rtc's arm64 row in a copy -> the guard must reject it.
yq '.platforms.arm64 = null' < "$Y" > "$TMP/mut.yaml"
awk '/^parts:/{inp=1} inp&&/^  go2rtc:$/{g=1;print;next} g&&/^  [a-z0-9-]+:$/{g=0} g&&/arm64\)/{skip=1} skip{ if (/;;/) skip=0; next } {print}' "$TMP/mut.yaml" > "$TMP/mut2.yaml"
t "T4: mutation copy really has arm64 platform"   test "$(yq '.platforms | has("arm64")' < "$TMP/mut2.yaml")" = true
t "T4: D5 guard rejects arm64 platform without a go2rtc arm64 row" sh -c "! d5_ok '$TMP/mut2.yaml'"

# --- T7 harness ---
t "T7: harness sources harness-arch.sh from the repo root"  grep -qxF '. tests/lib/harness-arch.sh' tests/spike-smoke.sh
t "T7: harness rejects a bad SPIKE_TIME_SCALE up front" sh -c "SPIKE_TIME_SCALE=0 bash tests/spike-smoke.sh --nvr-safe 2>&1 | grep -q 'SPIKE_TIME_SCALE must be'"
t "T7: artifact glob is per-arch"        sh -c "[ \$(grep -c 'artifact_glob \"\$HOST_ARCH\"' tests/spike-smoke.sh) -ge 2 ]"
t "T7: size floor via helper"            grep -q 'size_floor_for_arch "\$HOST_ARCH"' tests/spike-smoke.sh
t "T7: no size literal left in harness"  sh -c "! grep -qE '\[ .\\\$SNAP_SZ. -ge [0-9]{9}' tests/spike-smoke.sh"

# --- T9 arm64 pins (V3: spec Appendix A, verbatim) ---
NB=https://github.com/NickM-27/FFmpeg-Builds/releases/download
arow() { part "$Y" "$1" | awk '/^ +arm64\)/{f=1} f{print} f&&/;;/{exit}'; }
export -f arow
for pin in \
  "ffmpeg|$NB/autobuild-2022-07-31-12-37/ffmpeg-n5.1-2-g915ef932a3-linuxarm64-gpl-5.1.tar.xz|57ee475407bad49910ba9b946428396e30cf075ea28a7912fbe1aa2578085af0" \
  "ffmpeg|$NB/autobuild-2024-09-19-12-51/ffmpeg-n7.0.2-18-g3e6cec1286-linuxarm64-gpl-7.0.tar.xz|16c8b04e9d0ea9c769ad964c4c453fcf05121a1947237329d2e9d8a5e43e2a3c" \
  "ffmpeg|$NB/autobuild-2026-06-02-14-20/ffmpeg-n8.1.1-9-g58d4114d36-linuxarm64-gpl-8.1.tar.xz|cd91948468d0f11ce795a2cdaa0c69911bd1db313b49bb19c22512beb88cde69" \
  "go2rtc|https://github.com/AlexxIT/go2rtc/releases/download/v1.9.14/go2rtc_linux_arm64|359fabade8a7a51e81a55fe6df6b0ef81764a5e1d63179577534eaaa71904b50" \
  "libedgetpu|https://github.com/feranick/libedgetpu/releases/download/16.0TF2.17.1-1/libedgetpu1-max_16.0tf2.17.1-1.bookworm_arm64.deb|eab8aa4576b4dbf738135d8094f32270b24117f77147d25cbe0f49d0144d85f2"; do
  IFS='|' read -r p u s <<<"$pin"
  t "T9: $p arm64 row pins ${u##*/}" bash -c "arow $p | grep -qF '$u' && arow $p | grep -q '$s'"
done
t "T9: ffmpeg arm64 row extracts arm64/bin members x3" bash -c "[ \$(arow ffmpeg | grep -c 'arm64/bin/ffmpeg arm64/bin/ffprobe') -eq 3 ]"
t "T9: ffmpeg arm64 7.0 uses tar -xf (bzip2)"         bash -c "arow ffmpeg | grep -F 'ffmpeg-7.tar.xz' | grep -q 'tar -xf '"
t "T9: arm64 rows never name amd64 assets"            bash -c "! { arow ffmpeg; arow go2rtc; arow libedgetpu; } | grep -qE 'linux64-gpl|_amd64|amd64/bin'"
t "T9: amd64 rows untouched (W-14 amd64 shas present)" bash -c "part \$Y ffmpeg | grep -q 9bac85054d351cdc89c0a4f45c8ea5c44df94009aabd964b719bbadd56aedae9 && part \$Y go2rtc | grep -q 32d616af226bd731678ffde328b94cfb94e30339bfefc469cfb76323144615a6"
t "T9: no go2rtc 1.9.15 pin"                          sh -c "! grep -q 'v1.9.15' $Y"

[ "$FAILS" -eq 0 ]
