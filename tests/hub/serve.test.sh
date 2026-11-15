#!/usr/bin/env bash
# The clip-mode serving path end to end on the LAPTOP, loopback only (no hub, no network):
#   make-clips.sh (4 s clips) -> make-config.sh M7C_SOURCE=clip against the fake hub -> the snap's own
#   go2rtc-config-gen.py (unchanged) -> the snap's go2rtc binary (extracted from the local amd64 file) serving the
#   exec streams -> ffmpeg consumers pulling rtsp://127.0.0.1:<port>/{cam1,cam2,cam2_sub} for 10 s each, which
#   crosses the 4 s clip's loop seam at least twice.
# It proves the stream path (exec + `-c copy` of an hvc1 MP4 through ffmpeg's RTSP muxer, go2rtc, and a decoding
# consumer: frames, size, monotonic pts, 0 decode errors, 3 exec ffmpegs). It does NOT prove the hub's AppArmor
# profile (unconfined here) or the arm64 binaries (amd64 here; same versions).
# Test-only deviations: random loopback ports for RTSP/WebRTC (make-config's listen knobs) and for the API (the
# generator forces 127.0.0.1:1984, which may be taken on the laptop; the generated file's api.listen is rewritten).
# Processes: go2rtc runs in its own process group under `timeout`; cleanup kills that group by its PGID only and
# checks that the group is empty. Needs: the local amd64 frigate file, unsquashfs, python3 with PyYAML, yq.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1; fail=0; T=$(mktemp -d); PG=""
# shellcheck disable=SC2317  # cleanup runs from the EXIT trap
cleanup() {
  if [ -n "$PG" ]; then kill -TERM -- "-$PG" 2>/dev/null; for _ in 1 2 3 4 5 6 7 8 9 10; do ps -o pid= -g "$PG" >/dev/null 2>&1 || break; sleep 0.5; done
    kill -KILL -- "-$PG" 2>/dev/null; fi
  rm -rf "$T"
}
trap cleanup EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
EV="$HOME/.cache/frigate-m7c-evidence"; SNAP_FILE="${M7C_AMD64_SNAP:-$EV/amd64/frigate_0.18.2_amd64.snap}"
SHA_FILE="${M7C_AMD64_SHA:-$EV/amd64.sha256}"; FX=$PWD/tests/hub/fixtures
skip() { echo "SKIP - serve.test: $*"; exit 0; }
if [ ! -r "$SNAP_FILE" ] || [ ! -r "$SHA_FILE" ]; then skip "no local amd64 frigate file"; fi
command -v unsquashfs >/dev/null || skip "no unsquashfs"
python3 -c 'import yaml' 2>/dev/null || skip "no PyYAML"
[ "$(sha256sum "$SNAP_FILE" | awk '{ print $1 }')" = "$(awk 'NR == 1 { print $1 }' "$SHA_FILE")" ] || { echo "FAIL - the amd64 file does not match its sha256"; exit 1; }

# --- tools from the snap file: ffmpeg/ffprobe 8.0 and go2rtc ---
unsquashfs -q -n -d "$T/r" "$SNAP_FILE" usr/lib/ffmpeg/8.0/bin/ffmpeg usr/lib/ffmpeg/8.0/bin/ffprobe usr/local/go2rtc/bin/go2rtc >/dev/null 2>&1
FF=$T/r/usr/lib/ffmpeg/8.0/bin/ffmpeg; FP=$T/r/usr/lib/ffmpeg/8.0/bin/ffprobe; G=$T/r/usr/local/go2rtc/bin/go2rtc
check "tools extracted (ffmpeg, ffprobe, go2rtc)" 1 "$([ -x "$FF" ] && [ -x "$FP" ] && [ -x "$G" ] && echo 1 || echo 0)"

# --- clips (4 s: 2 GOPs) ---
M7C_FFMPEG=$FF M7C_FFPROBE=$FP timeout 300 bash tests/hub/make-clips.sh --seconds 4 --out "$T/clips" > "$T/clips.out" 2>&1
check "make-clips: exit 0" 0 $?

# --- config: make-config clip mode against the fake hub, then the snap's generator ---
port() { python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
PR=$(port); PW=$(port); PA=$(port)
mkdir -p "$T/st/hubcfg" "$T/envd"; : > "$T/st/log"; : > "$T/st/cmds"
cp "$FX/rendered-config.coral.yml" "$T/st/hubcfg/config.yml"; chmod 600 "$T/st/hubcfg/config.yml"
env STUB_ST="$T/st" STUB_RESPONDER="$FX/make-config-responder.sh" M7C_SSH="$FX/stub/ssh" M7C_HUB_SOCK=/run/test/m7c.sock \
  M7C_HUB_TARGET=hub-test M7C_ENV_DIR="$T/envd" M7C_SOURCE=clip M7C_CLIP_DIR="$T/clips" M7C_CLIP_FFMPEG="$FF" \
  M7C_GO2RTC_RTSP_LISTEN="127.0.0.1:$PR" M7C_GO2RTC_WEBRTC_LISTEN="127.0.0.1:$PW" \
  timeout 60 bash tests/hub/make-config.sh > "$T/mc.out" 2>&1
check "make-config clip mode: exit 0" 0 $?
python3 -I spike/bin/go2rtc-config-gen.py spike/config/go2rtc.yaml.in "$T/st/hubcfg/config.yml" /snap/frigate/x1 "$T/go2rtc.yaml" 2> "$T/gen.err"
check "generator: exit 0" 0 $?
yq ".api.listen = \"127.0.0.1:$PA\"" - < "$T/go2rtc.yaml" > "$T/go2rtc.yaml.new" && mv -f "$T/go2rtc.yaml.new" "$T/go2rtc.yaml"   # stdin: the yq snap has a private /tmp
check "test-only api.listen on a free loopback port" "127.0.0.1:$PA" "$(yq -r '.api.listen' - < "$T/go2rtc.yaml")"
check "generator output: the 3 clip streams are exec with -c copy" 3 "$(yq -r '[.streams.cam1[0], .streams.cam2[0], .streams.cam2_sub[0]] | map(select(test("^exec:.* -c copy -an -metadata title=m7c-[a-z0-9_]+ -f rtsp \\{output\\}$"))) | length' - < "$T/go2rtc.yaml")"

# --- go2rtc in its own process group, bounded by timeout ---
# The new session's leader writes its own PID (= the PGID) and then execs timeout -> go2rtc, so the PGID is right
# whether setsid forks or not.
: > "$T/pg"
# shellcheck disable=SC2016  # $$ and $1..$3 belong to the inner shell
setsid bash -c 'echo $$ > "$1"; exec timeout 180 "$2" -config "$3"' _ "$T/pg" "$G" "$T/go2rtc.yaml" > "$T/go2rtc.log" 2>&1 &
for _ in $(seq 1 40); do [ -s "$T/pg" ] && break; sleep 0.1; done; PG=$(cat "$T/pg")
up=0; for _ in $(seq 1 40); do if (exec 3<>"/dev/tcp/127.0.0.1/$PR") 2>/dev/null; then up=1; break; fi; sleep 0.25; done
check "go2rtc listens on the loopback RTSP port" 1 "$up"
check "go2rtc runs in its own process group (PGID $PG)" 1 "$([ -n "$PG" ] && [ "$(ps -o pgid= -p "$PG" | tr -d ' ')" = "$PG" ] && [ "$(ps -o pgid= -p "$$" | tr -d ' ')" != "$PG" ] && echo 1 || echo 0)"

# --- consumers: 10 s of each stream, decoded, all three at once ---
SECS=10; CONS=()
for s in cam1 cam2 cam2_sub; do
  timeout 60 "$FF" -hide_banner -nostdin -v error -rtsp_transport tcp -i "rtsp://127.0.0.1:$PR/$s" -t "$SECS" -map 0:v -f framemd5 "$T/$s.fm" 2> "$T/$s.err" &
  CONS+=($!)
done
sleep 6
# shellcheck disable=SC2009  # counted inside go2rtc's own process group (by PGID), not by name across the host
EXECS=$(ps -o args= -g "$PG" | grep -c -- '-stream_loop -1 -i ')
wait "${CONS[@]}"
check "go2rtc ran 3 exec ffmpegs while 3 consumers pulled" 3 "$EXECS"
for spec in cam1:1920x1080:25 cam2:1920x1080:25 cam2_sub:640x360:15; do
  s=${spec%%:*}; sz=$(echo "$spec" | cut -d: -f2); fps=${spec##*:}
  frames=$(grep -vc '^#' "$T/$s.fm" 2>/dev/null); frames=${frames:-0}
  min=$(( SECS * fps * 9 / 10 ))
  check "$s: decoded at least $min frames in ${SECS}s (clip = $((4 * fps)) frames, so >= 2 loop seams)" 1 "$([ "$frames" -ge "$min" ] && echo 1 || echo 0)"
  check "$s: 0 decode error lines" 0 "$(wc -l < "$T/$s.err")"
  check "$s: frame size $sz (yuv420p bytes)" 1 "$(awk -F, -v w="${sz%x*}" -v h="${sz#*x}" '!/^#/ { if ($5 + 0 != w * h * 3 / 2) bad = 1; n++ } END { print (n > 0 && !bad) ? 1 : 0 }' "$T/$s.fm")"
  check "$s: pts strictly increasing across the seams" 1 "$(awk -F, '!/^#/ { p = $3 + 0; if (n > 0 && p <= q) bad = 1; q = p; n++ } END { print (n > 0 && !bad) ? 1 : 0 }' "$T/$s.fm")"
  echo "evidence - $s: $frames frames in ${SECS}s, $sz, $(wc -l < "$T/$s.err") error lines"
  [ -s "$T/$s.err" ] && sed -n '1,5s/^/  stderr: /p' "$T/$s.err"
done
info=$(timeout 30 "$FP" -v error -rtsp_transport tcp -select_streams v:0 -show_entries stream=codec_name,width,height,r_frame_rate -of csv=p=0 "rtsp://127.0.0.1:$PR/cam1" 2>&1)
check "cam1 over RTSP: hevc 1920x1080 25 fps (ffprobe)" "hevc,1920,1080,25/1" "$info"
check "go2rtc log: 0 ERR lines" 0 "$(grep -c ' ERR ' "$T/go2rtc.log")"

# --- cleanup by PGID, then the group must be empty ---
kill -TERM -- "-$PG" 2>/dev/null; for _ in $(seq 1 20); do ps -o pid= -g "$PG" >/dev/null 2>&1 || break; sleep 0.25; done
left=$(ps -o pid= -g "$PG" | wc -l); check "cleanup: no process left in go2rtc's group" 0 "$left"
[ "$left" = 0 ] && PG=""

[ "$fail" = 0 ] && echo "serve.test: all ok" || echo "serve.test: FAILURES"
exit "$fail"
