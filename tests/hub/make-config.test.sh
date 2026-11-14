#!/usr/bin/env bash
# shellcheck disable=SC2016  # PRE strings are single-quoted on purpose: run() evals them with its own $T and $n
# tests/hub/make-config.sh against a fake hub (ssh-exec.sh -> fixtures/stub/ssh -> fixtures/make-config-responder.sh)
# with SYNTHETIC inputs only: TEST-NET addresses, made-up camera ids, canary codes. Every local command the script
# (and ssh-exec.sh) runs goes through an argv+env recording shim, so a canary on any command line or in any child
# environment is caught, as is a canary in the output, the ssh argv, the remote command strings or a stray file.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1; fail=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
has()   { grep -qF -- "$2" "$3"; check "$1" 0 $?; }
hasnt() { grep -qF -- "$2" "$3"; check "$1" 1 $?; }
M=tests/hub/make-config.sh; FX=$PWD/tests/hub/fixtures
CA=QZCNRA; CB=QZCNRB; NC=QZNEVERREAD; IP1=192.0.2.11; IP2=192.0.2.12; ID1=TESTCAM-0001; ID2=TESTCAM-0002
CANARIES=("$CA" "$CB" "$NC" "$IP1" "$IP2")

# argv+env recording shims for every external command the scripts use (resolved now, exec'd later)
SH="$T/shim"; mkdir -p "$SH"; ENV_BIN=$(type -P env)
for c in yq tr sed awk grep sha256sum cut head tail stat timeout cat mkdir env sort wc mv cp chmod rm date; do
  real=$(type -P "$c") || { echo "test setup: $c missing"; exit 1; }
  printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "$SHIM_LOG"; %s >> "$SHIM_ENV"; exec %s "$@"\n' "$c" "$ENV_BIN" "$real" > "$SH/$c"; chmod +x "$SH/$c"
done

mkenv() {  # mkenv DIR [pairs-mode]: synthetic env dir (pairs + env 0600) and a CRLF key file
  local d=$1; mkdir -p "$d"
  printf '%s %s\r\n%s %s\r\n' "$ID1" "$IP1" "$ID2" "$IP2" > "$d/cameras.pairs"
  printf 'M7C_KEYFILE=%s\n' "$d/keys.yaml" > "$d/env"
  printf 'new:\r\n  common: %s\r\noriginal QR Code keys:\r\n  %s: %s\r\n  %s: %s\r\n  TESTCAM-9999: QZOTHR\r\n' "$NC" "$ID1" "$CA" "$ID2" "$CB" > "$d/keys.yaml"
  chmod 600 "$d/cameras.pairs" "$d/env" "$d/keys.yaml"; [ -n "${2:-}" ] && chmod "$2" "$d/cameras.pairs"; return 0
}
run() {  # run NAME [env...] -- args. Fresh hub (the rendered H4 config) unless PRE says otherwise.
  local n=$1; shift; local -a e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  mkdir -p "$T/$n/st/hubcfg" "$T/$n/tmp"; : > "$T/$n/st/log"; : > "$T/$n/st/cmds"; : > "$T/$n/argv"; : > "$T/$n/envs"
  cp "$FX/rendered-config.coral.yml" "$T/$n/st/hubcfg/config.yml"; chmod 600 "$T/$n/st/hubcfg/config.yml"
  [ -d "$T/$n/envd" ] || mkenv "$T/$n/envd"
  [ -n "${PRE:-}" ] && eval "$PRE"
  # shellcheck disable=SC2086  # BASHX="bash -x" must split into a command and its flag
  env PATH="$SH:$PATH" SHIM_LOG="$T/$n/argv" SHIM_ENV="$T/$n/envs" TMPDIR="$T/$n/tmp" STUB_ST="$T/$n/st" \
    STUB_RESPONDER="$FX/make-config-responder.sh" M7C_SSH="$FX/stub/ssh" M7C_HUB_SOCK=/run/test/m7c.sock \
    M7C_HUB_TARGET=hub-test M7C_ENV_DIR="$T/$n/envd" "${e[@]}" \
    timeout 60 ${BASHX:-bash} "$M" "$@" > "$T/$n.out" 2>&1; echo $? > "$T/$n.rc"
}
rc() { cat "$T/$1.rc"; }; O() { echo "$T/$1.out"; }; HC() { echo "$T/$1/st/hubcfg/config.yml"; }
y() { yq -r "$2" - < "$(HC "$1")"; }   # stdin: the yq snap has a private /tmp
noleak() {  # noleak NAME: no canary in output, ssh argv, remote commands, local argv/env, or a stray file
  local n=$1 c where
  for c in "${CANARIES[@]}"; do
    for where in "$T/$n.out" "$T/$n/st/log" "$T/$n/st/cmds" "$T/$n/argv" "$T/$n/envs"; do
      grep -qF -- "$c" "$where" && { check "$n: no '$c' in ${where##*/}" absent present; return; }
    done
  done
  check "$n: no canary in output, ssh argv, remote commands, local argv or env" 0 0
  check "$n: no file left in TMPDIR" 0 "$(find "$T/$n/tmp" -mindepth 1 | wc -l)"
}

# --- usage and inputs (exit 2, no hub command) ---
run u1 -- extra;                                       check "an argument: exit 2" 2 "$(rc u1)"
PRE='rm -f "$T/$n/envd/cameras.pairs"' run u2 --;     check "no pairs file: exit 2" 2 "$(rc u2)"
mkenv "$T/u3/envd" 644; run u3 --;                     check "pairs file 0644: exit 2" 2 "$(rc u3)"; has "says 0600" "must be 0600" "$(O u3)"
PRE='printf "X=1\n" > "$T/$n/envd/env"' run u4 --;    check "env without M7C_KEYFILE: exit 2" 2 "$(rc u4)"
PRE='printf "%s %s\n" "$ID1" "$IP1" > "$T/$n/envd/cameras.pairs"' run u5 --; check "one camera only: exit 2" 2 "$(rc u5)"
PRE='printf "%s 192.0.2.300\n%s %s\n" "$ID1" "$ID2" "$IP2" > "$T/$n/envd/cameras.pairs"' run u6 --; check "bad IPv4: exit 2" 2 "$(rc u6)"
PRE='printf "a;b %s\n%s %s\n" "$IP1" "$ID2" "$IP2" > "$T/$n/envd/cameras.pairs"' run u7 --; check "bad camera id: exit 2" 2 "$(rc u7)"
run u8 M7C_RTSP_SUB='/x y' --;                         check "bad M7C_RTSP_SUB: exit 2" 2 "$(rc u8)"
run u9 M7C_GO2RTC_RTSP_LISTEN='0.0.0.0:85x' --;        check "bad M7C_GO2RTC_RTSP_LISTEN: exit 2" 2 "$(rc u9)"
check "input errors send no hub command" 0 "$(cat "$T"/u?/st/cmds | wc -l)"
for n in u2 u3 u4 u5 u6 u7 u8 u9; do noleak "$n"; done

# --- key file: a missing or odd code is an error that names no value ---
PRE='printf "original QR Code keys:\r\n  %s: %s\r\n" "$ID1" "$CA" > "$T/$n/envd/keys.yaml"' run k1 --
check "a code missing: exit 6" 6 "$(rc k1)"; has "says 1 of 2" "1 of 2 camera codes found" "$(O k1)"; noleak k1
PRE='printf "original QR Code keys:\r\n  %s: \"%s x\"\r\n  %s: %s\r\n" "$ID1" "$CA" "$ID2" "$CB" > "$T/$n/envd/keys.yaml"' run k2 --
check "an odd code: exit 6" 6 "$(rc k2)"; has "names the camera, not the value" "the code for cam1 has an unexpected shape" "$(O k2)"; noleak k2

# --- the hub: master, running NVR, pristine source ---
PRE='touch "$T/$n/st/gone"' run g1 --;  check "master gone: exit 3" 3 "$(rc g1)"; has "loud" "MASTER GONE" "$(O g1)"
run r1 MC_ACTIVE=1 --
check "frigate.frigate active: exit 4" 4 "$(rc r1)"; has "says frigate is running" "frigate.frigate is active" "$(O r1)"
hasnt "frigate running: nothing written" "m7c-new" "$T/r1/st/cmds"; hasnt "frigate running: no backup" "pre-h4" "$T/r1/st/cmds"; noleak r1
PRE='printf "cameras:\n  x: {}\n" > "$T/$n/st/hubcfg/config.yml"' run p1 --
check "source not the rendered H4 config: exit 5" 5 "$(rc p1)"; hasnt "not pristine: nothing written" "m7c-new" "$T/p1/st/cmds"

# --- happy path ---
run h1 --
check "happy: exit 0" 0 "$(rc h1)"
check "happy: last line is ok" "make-config: ok" "$(tail -n 1 "$(O h1)")"
has   "happy: validate rc and verdict only" "make-config: validate-config rc=0 valid" "$(O h1)"
check "happy: at most 8 output lines" 1 "$([ "$(wc -l < "$(O h1)")" -le 8 ] && echo 1 || echo 0)"
noleak h1
check "hub config mode 0600" 600 "$(stat -c %a "$(HC h1)")"
check "backup equals the rendered config" "$(sha256sum < "$FX/rendered-config.coral.yml")" "$(sha256sum < "$T/h1/st/hubcfg/config.yml.pre-h4")"
check "backup mode 0600" 600 "$(stat -c %a "$T/h1/st/hubcfg/config.yml.pre-h4")"
check "no m7c-new left" 0 "$(find "$T/h1/st/hubcfg" -name '*.m7c-new' | wc -l)"
check "no testclip anywhere (H4 grep -c)" 0 "$(grep -c testclip "$(HC h1)")"
check "cameras are cam1,cam2" "cam1,cam2" "$(y h1 '.cameras | keys | join(",")')"
check "mqtt off" false "$(y h1 '.mqtt.enabled')"
check "hwaccel_args empty" '""' "$(yq -o=json '.ffmpeg.hwaccel_args' - < "$(HC h1)")"
check "continuous.days 1" 1 "$(y h1 '.record.continuous.days')"
check "alerts retain.days 1" 1 "$(y h1 '.record.alerts.retain.days')"
check "detections retain.days 1" 1 "$(y h1 '.record.detections.retain.days')"
check "record stays enabled" true "$(y h1 '.record.enabled')"
check "detector coral kept" edgetpu "$(y h1 '.detectors.coral.type')"
check "cam1 record input = go2rtc main" "rtsp://127.0.0.1:8554/cam1 record" "$(y h1 '.cameras.cam1.ffmpeg.inputs[] | select(.roles[0] == "record") | .path + " " + (.roles | join(","))')"
check "cam1 detect input = go2rtc sub" "rtsp://127.0.0.1:8554/cam1_sub detect" "$(y h1 '.cameras.cam1.ffmpeg.inputs[] | select(.roles[0] == "detect") | .path + " " + (.roles | join(","))')"
check "inputs use the restream preset" "preset-rtsp-restream" "$(y h1 '[.cameras[].ffmpeg.inputs[].input_args] | unique | join(",")')"
check "detect fps 5, size auto (no width/height)" "5 null null" "$(y h1 '.cameras.cam2.detect | [.fps, .width, .height] | map(tostring) | join(" ")')"
check "cam1 main stream: first pair, main path" "rtsp://admin:$CA@$IP1/Streaming/Channels/101" "$(y h1 '.go2rtc.streams.cam1[0]')"
check "cam1 sub stream" "rtsp://admin:$CA@$IP1/Streaming/Channels/102" "$(y h1 '.go2rtc.streams.cam1_sub[0]')"
check "cam2 main stream: second pair" "rtsp://admin:$CB@$IP2/Streaming/Channels/101" "$(y h1 '.go2rtc.streams.cam2[0]')"
check "4 go2rtc streams" 4 "$(y h1 '.go2rtc.streams | keys | length')"
check "go2rtc RTSP bound to loopback by default" "127.0.0.1:8554" "$(y h1 '.go2rtc.rtsp.listen')"
check "go2rtc WebRTC bound to loopback by default" "127.0.0.1:8555" "$(y h1 '.go2rtc.webrtc.listen')"
# The snap's own generator (spike/bin/go2rtc-config-gen.py, run here unchanged) must keep the bind and the streams.
if python3 -c 'import yaml' 2>/dev/null; then
  mkdir -p "$T/gen"; python3 -I spike/bin/go2rtc-config-gen.py spike/config/go2rtc.yaml.in "$(HC h1)" /snap/frigate/x1 "$T/gen/go2rtc.yaml" 2> "$T/gen/err"
  check "generator: rtsp.listen stays 127.0.0.1:8554" "127.0.0.1:8554" "$(yq -r '.rtsp.listen' - < "$T/gen/go2rtc.yaml")"
  check "generator: webrtc.listen stays 127.0.0.1:8555" "127.0.0.1:8555" "$(yq -r '.webrtc.listen' - < "$T/gen/go2rtc.yaml")"
  check "generator: api.listen still forced to loopback" "127.0.0.1:1984" "$(yq -r '.api.listen' - < "$T/gen/go2rtc.yaml")"
  check "generator: the 4 camera streams merged over the 2 baseline streams" "cam1,cam1_sub,cam2,cam2_sub,test,testclip" "$(yq -r '.streams | keys | join(",")' - < "$T/gen/go2rtc.yaml")"
  check "generator: says it merged the section, prints no secret" 0 "$(grep -cF -e "$CA" -e "$IP1" "$T/gen/err")"
else echo "SKIP - generator cross-check (no PyYAML on this host)"; fi
hasnt "new.common never reaches the hub" "$NC" "$(HC h1)"
hasnt "another camera's code never reaches the hub" "QZOTHR" "$(HC h1)"
has   "the config is sent on stdin, never in the remote command" "cat > /var/snap/frigate/current/config/config.yml.m7c-new" "$T/h1/st/cmds"

# --- re-run: the pristine backup stays the source and is never overwritten ---
PRE='cp "$T/h1/st/hubcfg/config.yml" "$T/$n/st/hubcfg/config.yml"; cp "$T/h1/st/hubcfg/config.yml.pre-h4" "$T/$n/st/hubcfg/"' run h2 M7C_RTSP_SUB=/ch1/sub --
check "re-run: exit 0" 0 "$(rc h2)"
check "re-run: backup still the rendered config" "$(sha256sum < "$FX/rendered-config.coral.yml")" "$(sha256sum < "$T/h2/st/hubcfg/config.yml.pre-h4")"
check "re-run: M7C_RTSP_SUB applied" "rtsp://admin:$CA@$IP1/ch1/sub" "$(y h2 '.go2rtc.streams.cam1_sub[0]')"
has   "re-run: says the backup was kept" "backup config.yml.pre-h4: kept" "$(O h2)"; noleak h2

# --- LAN bind on request: empty keeps the baseline's, a value is used as given ---
run l1 M7C_GO2RTC_RTSP_LISTEN= M7C_GO2RTC_WEBRTC_LISTEN=:8555 --
check "listen override: exit 0" 0 "$(rc l1)"
check "empty RTSP listen: no rtsp key (baseline :8554)" null "$(y l1 '.go2rtc.rtsp')"
check "WebRTC listen as given" ":8555" "$(y l1 '.go2rtc.webrtc.listen')"; noleak l1

# --- write damaged in transit: refused, old config untouched ---
PRE='touch "$T/$n/st/corrupt"' run w1 --
check "damaged write: exit 7" 7 "$(rc w1)"
check "damaged write: config.yml unchanged" "$(sha256sum < "$FX/rendered-config.coral.yml")" "$(sha256sum < "$(HC w1)")"
check "damaged write: m7c-new removed" 0 "$(find "$T/w1/st/hubcfg" -name '*.m7c-new' | wc -l)"; noleak w1

# --- validate-config fails: rc + invalid, error lines masked ---
run v1 MC_VALID=0 --
check "invalid: exit 8" 8 "$(rc v1)"; has "invalid: verdict" "make-config: validate-config rc=1 invalid" "$(O v1)"
has   "invalid: the error line is shown, masked" "rtsp://<redacted>@<cam1-ip>/Streaming/Channels/101" "$(O v1)"
hasnt "invalid: no password line" "password for admin" "$(O v1)"; noleak v1

# --- xtrace from the caller cannot leak (bash -x) ---
BASHX="bash -x" run x1 --; check "bash -x: exit 0" 0 "$(rc x1)"; noleak x1

[ "$fail" = 0 ] && echo "make-config.test: all ok" || echo "make-config.test: FAILURES"
exit "$fail"
