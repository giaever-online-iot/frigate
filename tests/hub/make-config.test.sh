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
CANARIES=("$CA" "$CB" "$NC" "$IP1" "$IP2" "$ID1" "$ID2")

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

# --- M7C_SOURCE=clip: the synthetic H.265 stand-in (W-7 Q7). No camera login is read: the env dir's files are
# mode 000 with canaries in them, so any read of cameras.pairs, env or the key file fails the run. ---
# CLIPS: put both clips and an executable stand-in for the snap's ffmpeg into the fake hub's state.
CLIPS='mkdir -p "$T/$n/st/clips"; printf main > "$T/$n/st/clips/main-1080p25.mp4"; printf sub > "$T/$n/st/clips/sub-360p15.mp4"; printf "#!/bin/sh\n" > "$T/$n/st/ffmpeg"; chmod +x "$T/$n/st/ffmpeg"'
LOCK='chmod 000 "$T/$n/envd/cameras.pairs" "$T/$n/envd/env" "$T/$n/envd/keys.yaml"'
CX() { echo "M7C_CLIP_DIR=$T/$1/st/clips"; }; CF() { echo "M7C_CLIP_FFMPEG=$T/$1/st/ffmpeg"; }
run c0 M7C_SOURCE=bogus --;                             check "clip: M7C_SOURCE=bogus: exit 2" 2 "$(rc c0)"
PRE="$CLIPS; $LOCK" run c1 M7C_SOURCE=clip "$(CX c1)" "$(CF c1)" --
check "clip: exit 0 with the env dir unreadable" 0 "$(rc c1)"; check "clip: last line is ok" "make-config: ok" "$(tail -n 1 "$(O c1)")"
has   "clip: says no camera login is read" "make-config: clip mode: no camera login is read" "$(O c1)"
noleak c1
hasnt "clip: no local command names the env dir" "$T/c1/envd" "$T/c1/argv"
check "clip: cameras are cam1,cam2" "cam1,cam2" "$(y c1 '.cameras | keys | join(",")')"
check "clip: 3 go2rtc streams" "cam1,cam2,cam2_sub" "$(y c1 '.go2rtc.streams | keys | join(",")')"
E="exec:$T/c1/st/ffmpeg -hide_banner -loglevel warning -re -stream_loop -1 -i $T/c1/st/clips"
check "clip: cam1 = the 1080p25 clip, copied to RTSP" "$E/main-1080p25.mp4 -c copy -an -metadata title=m7c-cam1 -f rtsp {output}" "$(y c1 '.go2rtc.streams.cam1[0]')"
check "clip: cam2 = the 1080p25 clip" "$E/main-1080p25.mp4 -c copy -an -metadata title=m7c-cam2 -f rtsp {output}" "$(y c1 '.go2rtc.streams.cam2[0]')"
check "clip: cam2_sub = the 360p15 clip" "$E/sub-360p15.mp4 -c copy -an -metadata title=m7c-cam2_sub -f rtsp {output}" "$(y c1 '.go2rtc.streams.cam2_sub[0]')"
# go2rtc 1.9.14 keys an exec source by its line: two identical lines started at once collide (one consumer gets
# DESCRIBE 404; seen 3 of 3 rounds on the laptop), so cam1 and cam2 (same clip) must differ in a harmless way.
check "clip: the 3 exec lines are pairwise distinct" 3 "$(y c1 '[.go2rtc.streams[][0]] | unique | length')"
check "clip: cam1 has one input, detect+record at native size (worst case)" "rtsp://127.0.0.1:8554/cam1 detect,record" "$(y c1 '[.cameras.cam1.ffmpeg.inputs[] | .path + " " + (.roles | join(","))] | join(";")')"
check "clip: cam2 records cam2, detects cam2_sub" "rtsp://127.0.0.1:8554/cam2 record;rtsp://127.0.0.1:8554/cam2_sub detect" "$(y c1 '[.cameras.cam2.ffmpeg.inputs[] | .path + " " + (.roles | join(","))] | join(";")')"
check "clip: inputs use the restream preset" "preset-rtsp-restream" "$(y c1 '[.cameras[].ffmpeg.inputs[].input_args] | unique | join(",")')"
check "clip: detect fps 5, size auto" "5 null null 5 null null" "$(y c1 '[.cameras.cam1.detect, .cameras.cam2.detect] | map([.fps, .width, .height] | map(tostring) | join(" ")) | join(" ")')"
check "clip: D21 edits kept (mqtt, hwaccel, days, detector, loopback binds)" '[false,"",1,1,1,true,"edgetpu","127.0.0.1:8554","127.0.0.1:8555"]' \
  "$(yq -o=json -I=0 '[.mqtt.enabled, .ffmpeg.hwaccel_args, .record.continuous.days, .record.alerts.retain.days, .record.detections.retain.days, .record.enabled, .detectors.coral.type, .go2rtc.rtsp.listen, .go2rtc.webrtc.listen]' - < "$(HC c1)")"
check "clip: no testclip" 0 "$(grep -c testclip "$(HC c1)")"
check "clip: no camera URL with a login" 0 "$(grep -c 'rtsp://[^ ]*@' "$(HC c1)")"
check "clip: mode 0600, backup is the rendered config" "600 $(sha256sum < "$FX/rendered-config.coral.yml")" "$(stat -c %a "$(HC c1)") $(sha256sum < "$T/c1/st/hubcfg/config.yml.pre-h4")"
has   "clip: prints the hub's sha256 of the main clip" "make-config: clip main-1080p25.mp4 sha256 $(printf main | sha256sum | cut -d' ' -f1)" "$(O c1)"
has   "clip: prints the hub's sha256 of the sub clip" "make-config: clip sub-360p15.mp4 sha256 $(printf sub | sha256sum | cut -d' ' -f1)" "$(O c1)"
has   "clip: built line says 3 streams from clips" "built: 2 cameras (clip), 3 go2rtc streams" "$(O c1)"
if python3 -c 'import yaml' 2>/dev/null; then
  mkdir -p "$T/genc"; python3 -I spike/bin/go2rtc-config-gen.py spike/config/go2rtc.yaml.in "$(HC c1)" /snap/frigate/x1 "$T/genc/go2rtc.yaml" 2> "$T/genc/err"
  check "clip generator: streams merged" "cam1,cam2,cam2_sub,test,testclip" "$(yq -r '.streams | keys | join(",")' - < "$T/genc/go2rtc.yaml")"
  check "clip generator: the exec line survives verbatim ({output} intact)" "$(y c1 '.go2rtc.streams.cam2_sub[0]')" "$(yq -r '.streams.cam2_sub[0]' - < "$T/genc/go2rtc.yaml")"
  check "clip generator: rtsp.listen stays loopback" "127.0.0.1:8554" "$(yq -r '.rtsp.listen' - < "$T/genc/go2rtc.yaml")"
else echo "SKIP - clip generator cross-check (no PyYAML on this host)"; fi
PRE="$LOCK" run c2 M7C_SOURCE=clip --
check "clip: clips missing on the hub: exit 9" 9 "$(rc c2)"; has "clip: names the missing clip" "main-1080p25.mp4 is missing or empty" "$(O c2)"
has   "clip: the default clip dir is the snap's common dir" "for f in main-1080p25.mp4 sub-360p15.mp4; do if [ -s /var/snap/frigate/common/m7c-clips/\$f ]" "$T/c2/st/cmds"
has   "clip: the default ffmpeg is the snap's 8.0 tree" "/snap/frigate/current/usr/lib/ffmpeg/8.0/bin/ffmpeg" "$T/c2/st/cmds"
hasnt "clip: missing clips: nothing written" "m7c-new" "$T/c2/st/cmds"; hasnt "clip: missing clips: no backup" "pre-h4.m7c-part" "$T/c2/st/cmds"
PRE="$CLIPS; $LOCK; : > \"\$T/\$n/st/clips/sub-360p15.mp4\"" run c3 M7C_SOURCE=clip "$(CX c3)" "$(CF c3)" --
check "clip: an empty sub clip: exit 9" 9 "$(rc c3)"; has "clip: names the empty clip" "sub-360p15.mp4 is missing or empty" "$(O c3)"
PRE="$CLIPS; $LOCK; chmod -x \"\$T/\$n/st/ffmpeg\"" run c4 M7C_SOURCE=clip "$(CX c4)" "$(CF c4)" --
check "clip: the hub ffmpeg not executable: exit 9" 9 "$(rc c4)"; has "clip: says so" "is not executable on the hub" "$(O c4)"
run c5 M7C_SOURCE=clip M7C_CLIP_DIR='/var/snap/frigate/common/../x' --; check "clip: a '..' clip dir: exit 2" 2 "$(rc c5)"
run c6 M7C_SOURCE=clip M7C_CLIP_FFMPEG='ffmpeg' --;                     check "clip: a relative ffmpeg: exit 2" 2 "$(rc c6)"
check "clip: input errors send no hub command" 0 "$(cat "$T"/c0/st/cmds "$T"/c5/st/cmds "$T"/c6/st/cmds | wc -l)"
PRE="$CLIPS; $LOCK" run c7 M7C_SOURCE=clip MC_ACTIVE=1 "$(CX c7)" "$(CF c7)" --
check "clip: frigate.frigate active: exit 4" 4 "$(rc c7)"; hasnt "clip: frigate running: nothing written" "m7c-new" "$T/c7/st/cmds"
PRE="$CLIPS; rm -rf \"\$T/\$n/envd\"; mkdir -p \"\$T/\$n/envd\"" run c8 M7C_SOURCE=clip "$(CX c8)" "$(CF c8)" --
check "clip: an empty env dir is fine" 0 "$(rc c8)"
PRE="$CLIPS; $LOCK" run c9 M7C_SOURCE=clip MC_VALID=0 "$(CX c9)" "$(CF c9)" --
check "clip: invalid: exit 8" 8 "$(rc c9)"; has "clip: invalid: verdict" "make-config: validate-config rc=1 invalid" "$(O c9)"; noleak c9
PRE="$CLIPS; $LOCK" BASHX="bash -x" run c10 M7C_SOURCE=clip "$(CX c10)" "$(CF c10)" --; check "clip: bash -x: exit 0" 0 "$(rc c10)"; noleak c10

# --- M7C_SOURCE=ezviz (W-23 T18; §6, F5, P10, C19): no go2rtc streams, camera files on stdin only, retention ---
run e1 M7C_SOURCE=ezviz --
check "ezviz: exit 0" 0 "$(rc e1)"; check "ezviz: last line ok" "make-config: ok" "$(tail -n 1 "$(O e1)")"; noleak e1
check "ezviz: no go2rtc streams" 0 "$(y e1 '(.go2rtc.streams // {}) | keys | length')"
check "ezviz: cameras are cam1,cam2" "cam1,cam2" "$(y e1 '.cameras | keys | join(",")')"
check "ezviz: cam1 one input detect+record" "rtsp://127.0.0.1:8554/cam1 detect,record" "$(y e1 '[.cameras.cam1.ffmpeg.inputs[] | .path + " " + (.roles | join(","))] | join(";")')"
check "ezviz: cam2 one input detect+record" "rtsp://127.0.0.1:8554/cam2 detect,record" "$(y e1 '[.cameras.cam2.ffmpeg.inputs[] | .path + " " + (.roles | join(","))] | join(";")')"
check "ezviz: restream preset, fps 5, no width/height (P11)" "preset-rtsp-restream 5 null null" "$(y e1 '[.cameras.cam1.ffmpeg.inputs[0].input_args, .cameras.cam1.detect.fps, .cameras.cam1.detect.width, .cameras.cam1.detect.height] | map(tostring) | join(" ")')"
check "ezviz: loopback binds kept" "127.0.0.1:8554 127.0.0.1:8555" "$(y e1 '.go2rtc.rtsp.listen + " " + .go2rtc.webrtc.listen')"
check "ezviz: no URL with a login" 0 "$(grep -c '://[^ ]*@' "$(HC e1)")"
check "ezviz: cam1.conf mode 600" 600 "$(stat -c %a "$T/e1/st/ezviz/cameras/cam1.conf")"
check "ezviz: cam1.conf content" "host=$IP1 port=8000 serial=$ID1 login=$CA" "$(grep -v '^#' "$T/e1/st/ezviz/cameras/cam1.conf" | tr '\n' ' ' | sed 's/ $//')"
check "ezviz: cam2.conf is the second pair" "host=$IP2 port=8000 serial=$ID2 login=$CB" "$(grep -v '^#' "$T/e1/st/ezviz/cameras/cam2.conf" | tr '\n' ' ' | sed 's/ $//')"
check "ezviz: camera dir 700" 700 "$(stat -c %a "$T/e1/st/ezviz/cameras")"
check "ezviz: state dir 700, created" 700 "$(stat -c %a "$T/e1/st/common-ezviz/state")"
check "ezviz: no .m7c-new left" 0 "$(find "$T/e1/st/ezviz" -name '*.m7c-new' | wc -l)"
has   "ezviz: says 2 camera files written" "camera files: 2 written (root, 0600, sha256 matched)" "$(O e1)"
has   "ezviz: ezviz-check ok for cam1" "ezviz-check cam1: ok" "$(O e1)"
has   "ezviz: ezviz-check ok for cam2" "ezviz-check cam2: ok" "$(O e1)"
has   "ezviz: built line says 0 streams, days 1" "built: 2 cameras (ezviz), 0 go2rtc streams" "$(O e1)"
check "ezviz: at most 12 output lines" 1 "$([ "$(wc -l < "$(O e1)")" -le 12 ] && echo 1 || echo 0)"
has   "ezviz: cam1 file on stdin only, under umask 077" "umask 077 && cat > /var/snap/frigate/current/ezviz/cameras/cam1.conf.m7c-new" "$T/e1/st/cmds"
has   "ezviz: cam2 file on stdin only, under umask 077" "umask 077 && cat > /var/snap/frigate/current/ezviz/cameras/cam2.conf.m7c-new" "$T/e1/st/cmds"
hasnt "ezviz: no code in any remote command" "$CA" "$T/e1/st/cmds"
hasnt "ezviz: no camera serial in any remote command" "$ID1" "$T/e1/st/cmds"
hasnt "ezviz: no camera address in any remote command" "$IP1" "$T/e1/st/cmds"
hasnt "ezviz: no camera serial in the output" "$ID1" "$(O e1)"
hasnt "ezviz: no camera serial in the ssh argv" "$ID2" "$T/e1/st/log"
# the file must parse with the helper's own reader (camfile.load), as the venv python, in the test sandbox.
# venv.sh's own default is per checkout (W-23 fix wave 1, S3); a fixed venv name here would retarget its .pth.
if PYV=$(bash tests/ezviz/venv.sh 2>/dev/null) && [ -x "$PYV" ]; then
  check "ezviz: cam1.conf parses with camfile.load" "ok $IP1 8000 $ID1 $CA" "$("$PYV" -I -c 'import sys; from ezviz_source import camfile; c = camfile.load("cam1", sys.argv[1]); print("ok", c.host, c.port, c.serial, c.login)' "$T/e1/st/ezviz/cameras" 2>&1)"
  check "ezviz: cam2.conf parses with camfile.load" "ok $IP2 8000 $ID2 $CB" "$("$PYV" -I -c 'import sys; from ezviz_source import camfile; c = camfile.load("cam2", sys.argv[1]); print("ok", c.host, c.port, c.serial, c.login)' "$T/e1/st/ezviz/cameras" 2>&1)"
else check "ezviz: the venv python for the camfile.load check is available" present absent; fi
# the snap's generator with 5 arguments: cam1, cam2 become exec streams and are preloaded
if python3 -c 'import yaml' 2>/dev/null; then
  mkdir -p "$T/gene/cams"; : > "$T/gene/cams/cam1.conf"; : > "$T/gene/cams/cam2.conf"
  python3 -I spike/bin/go2rtc-config-gen.py spike/config/go2rtc.yaml.in "$(HC e1)" /snap/frigate/x1 "$T/gene/go2rtc.yaml" "$T/gene/cams" 2> "$T/gene/err"
  check "ezviz generator: streams cam1,cam2 + the 2 baseline ones" "cam1,cam2,test,testclip" "$(yq -r '.streams | keys | join(",")' - < "$T/gene/go2rtc.yaml")"
  check "ezviz generator: cam1 and cam2 are exec lines" "true,true" "$(yq -r '[.streams.cam1, .streams.cam2] | map(test("^exec:")) | join(",")' - < "$T/gene/go2rtc.yaml")"
  check "ezviz generator: preload holds cam1 and cam2" "cam1,cam2" "$(yq -r '.preload | keys | join(",")' - < "$T/gene/go2rtc.yaml")"
  check "ezviz generator: rtsp.listen stays loopback" "127.0.0.1:8554" "$(yq -r '.rtsp.listen' - < "$T/gene/go2rtc.yaml")"
else echo "SKIP - ezviz generator cross-check (no PyYAML on this host)"; fi
PRE='mkdir -p "$T/$n/st/common-ezviz/state"; echo keep > "$T/$n/st/common-ezviz/state/cam1.ledger"' run e2 M7C_SOURCE=ezviz --
check "ezviz: an existing ledger is kept" keep "$(cat "$T/e2/st/common-ezviz/state/cam1.ledger")"
run e3 M7C_SOURCE=ezviz MC_G2R_ACTIVE=1 --; check "ezviz: go2rtc active: exit 4" 4 "$(rc e3)"; hasnt "ezviz: go2rtc active: nothing written" "m7c-new" "$T/e3/st/cmds"
check "ezviz: go2rtc active: no camera dirs made" 0 "$(find "$T/e3/st" -maxdepth 1 -name '*ezviz*' | wc -l)"
run e4 M7C_SOURCE=ezviz MC_CHECK=0 --;    check "ezviz: ezviz-check fails: exit 11" 11 "$(rc e4)"; has "ezviz: check fails: says files were written" "camera files written but ezviz-check failed" "$(O e4)"; noleak e4
has   "ezviz: check fails: shows the helper's class" "failed for cam1 (rc 1): mode" "$(O e4)"
has   "ezviz: check fails: says what is left" "config.yml is already the ezviz config; re-run with M7C_SOURCE=ezviz, or roll back: remove /var/snap/frigate/current/ezviz, then restore config.yml.pre-h4 (/var/snap/frigate/current/config/config.yml.pre-h4)" "$(O e4)"
run e14 M7C_SOURCE=ezviz MC_CAM_CORRUPT=cam2 --
check "ezviz: cam2 damaged in transit: exit 7" 7 "$(rc e14)"
check "ezviz: cam2 damaged: no .m7c-new left" 0 "$(find "$T/e14/st/ezviz" -name '*.m7c-new' | wc -l)"
check "ezviz: cam2 damaged: cam2.conf absent" absent "$([ -e "$T/e14/st/ezviz/cameras/cam2.conf" ] && echo present || echo absent)"
check "ezviz: cam2 damaged: cam1.conf was written" present "$([ -e "$T/e14/st/ezviz/cameras/cam1.conf" ] && echo present || echo absent)"
has   "ezviz: cam2 damaged: names the camera" "camera file cam2 did not arrive intact" "$(O e14)"
has   "ezviz: cam2 damaged: says what is left" "config.yml is already the ezviz config; re-run with M7C_SOURCE=ezviz, or roll back: remove /var/snap/frigate/current/ezviz, then restore config.yml.pre-h4 (/var/snap/frigate/current/config/config.yml.pre-h4)" "$(O e14)"
noleak e14
run e15 MC_P10=garble --;  check "P10: a garbled answer fails closed: exit 10" 10 "$(rc e15)"; hasnt "P10 garbled: nothing written" "m7c-new" "$T/e15/st/cmds"; has "P10 garbled: says it could not tell" "could not tell whether ezviz camera files are present" "$(O e15)"
run e16 MC_P10=fail --;    check "P10: a failing probe fails closed: exit 10" 10 "$(rc e16)"; hasnt "P10 failed: nothing written" "m7c-new" "$T/e16/st/cmds"
run e5 M7C_SOURCE=ezviz M7C_RETAIN_DAYS=3 --; check "retain 3 applied to all three (ezviz)" "3 3 3" "$(y e5 '[.record.continuous.days, .record.alerts.retain.days, .record.detections.retain.days] | map(tostring) | join(" ")')"
has   "retain 3: built line says so" "continuous.days 3, alerts/detections retain.days 3" "$(O e5)"
run e6 M7C_RETAIN_DAYS=0 --;  check "retain 0: exit 2" 2 "$(rc e6)"; run e7 M7C_RETAIN_DAYS=x --; check "retain x: exit 2" 2 "$(rc e7)"
run e10 M7C_RETAIN_DAYS=31 --; check "retain 31: exit 2" 2 "$(rc e10)"
check "retain errors send no hub command" 0 "$(cat "$T/e6/st/cmds" "$T/e7/st/cmds" "$T/e10/st/cmds" | wc -l)"
run e11 M7C_RETAIN_DAYS=30 --; check "retain 30 (cameras mode): applied to all three" "30 30 30" "$(y e11 '[.record.continuous.days, .record.alerts.retain.days, .record.detections.retain.days] | map(tostring) | join(" ")')"
has   "retain 30 (cameras mode): built line says so" "continuous.days 30, alerts/detections retain.days 30" "$(O e11)"
PRE="$CLIPS; $LOCK" run e12 M7C_SOURCE=clip M7C_RETAIN_DAYS=2 "$(CX e12)" "$(CF e12)" --
check "retain 2 (clip mode): applied to all three" "2 2 2" "$(y e12 '[.record.continuous.days, .record.alerts.retain.days, .record.detections.retain.days] | map(tostring) | join(" ")')"
PRE='mkdir -p "$T/$n/st/ezviz/cameras"; : > "$T/$n/st/ezviz/cameras/cam1.conf"' run e8 M7C_SOURCE=clip "$(CX e8)" "$(CF e8)" --
check "clip with camera files present: exit 10" 10 "$(rc e8)"; hasnt "exit 10: nothing written" "m7c-new" "$T/e8/st/cmds"; has "exit 10: names the rollback step" "remove /var/snap/frigate/current/ezviz first" "$(O e8)"
PRE='mkdir -p "$T/$n/st/ezviz/cameras"; : > "$T/$n/st/ezviz/cameras/cam2.conf"' run e13 --
check "cameras mode with camera files present: exit 10" 10 "$(rc e13)"; hasnt "cameras mode exit 10: nothing written" "m7c-new" "$T/e13/st/cmds"
BASHX="bash -x" run e9 M7C_SOURCE=ezviz --; check "ezviz: bash -x: exit 0" 0 "$(rc e9)"; noleak e9
hasnt "ezviz: bash -x: no code in the trace" "$CA" "$(O e9)"

[ "$fail" = 0 ] && echo "make-config.test: all ok" || echo "make-config.test: FAILURES"
exit "$fail"
