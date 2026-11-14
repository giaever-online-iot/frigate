#!/usr/bin/env bash
# tests/hub/make-clips.sh on the laptop: short clips (6 s), the tool extraction from the local amd64 frigate file
# (into a temp HOME), and the clip checker against deliberately wrong clips. Needs the local amd64 file (else SKIP).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1; fail=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
has()   { grep -qF -- "$2" "$3"; check "$1" 0 $?; }
M=$PWD/tests/hub/make-clips.sh; EV="$HOME/.cache/frigate-m7c-evidence"
SNAP_FILE="${M7C_AMD64_SNAP:-$EV/amd64/frigate_0.18.2_amd64.snap}"; SHA_FILE="${M7C_AMD64_SHA:-$EV/amd64.sha256}"
if [ ! -r "$SNAP_FILE" ] || [ ! -r "$SHA_FILE" ]; then echo "SKIP - make-clips.test: no local amd64 frigate file ($SNAP_FILE)"; exit 0; fi
run() {  # run NAME [env...] -- args
  local n=$1; shift; local -a e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  env HOME="$T/home" "${e[@]}" timeout 300 bash "$M" "$@" > "$T/$n.out" 2>&1; echo $? > "$T/$n.rc"
}
rc() { cat "$T/$1.rc"; }; O() { echo "$T/$1.out"; }
X=(M7C_AMD64_SNAP="$SNAP_FILE" M7C_AMD64_SHA="$SHA_FILE")

# --- usage ---
run u1 -- --seconds 1;   check "--seconds 1: exit 2" 2 "$(rc u1)"
run u2 -- --motion 0;    check "--motion 0: exit 2" 2 "$(rc u2)"
run u3 -- --only both;   check "--only both: exit 2" 2 "$(rc u3)"
run u4 -- --check "$T/none.mp4" 640x360 15 256; check "--check of a missing file: exit 2" 2 "$(rc u4)"

# --- tools: a wrong sha256 for the amd64 file is refused, nothing extracted ---
printf '%064d  amd64/x.snap\n' 0 > "$T/bad.sha256"
run t0 M7C_AMD64_SNAP="$SNAP_FILE" M7C_AMD64_SHA="$T/bad.sha256" -- --seconds 2 --out "$T/c0"
check "wrong amd64 sha256: exit 2" 2 "$(rc t0)"; has "says sha256 mismatch" "want 0000" "$(O t0)"
check "wrong amd64 sha256: no tools extracted" 0 "$(find "$T/home" -name ffmpeg 2>/dev/null | wc -l)"

# --- happy: extraction, both clips, 7 s rounds down to 6 s (whole GOPs) ---
run h1 "${X[@]}" -- --seconds 7 --out "$T/c1"
check "happy: exit 0" 0 "$(rc h1)"; has "happy: extracted from the sha-checked file" "extracted the snap's ffmpeg 8.0 tree" "$(O h1)"
FF="$T/home/.cache/frigate-m7c-evidence/hub/tools/ffmpeg-8.0/ffmpeg"; FP="${FF%/ffmpeg}/ffprobe"
check "tools extracted to the evidence tools dir" 1 "$([ -x "$FF" ] && [ -x "$FP" ] && echo 1 || echo 0)"
for c in main-1080p25:1920x1080:25 sub-360p15:640x360:15; do
  n=${c%%:*}; f="$T/c1/$n.mp4"
  check "$n: file in place" 1 "$([ -s "$f" ] && echo 1 || echo 0)"
  has   "$n: sha256 line matches the file" "$n.mp4 $(stat -c %s "$f") B sha256 $(sha256sum "$f" | awk '{ print $1 }')" "$(O h1)"
  check "$n: 6 s (rounded to whole GOPs)" 6.000000 "$("$FP" -v error -show_entries format=duration -of csv=p=0 "$f")"
  check "$n: size and rate" "$(echo "${c#*:}" | tr : ' ')" "$("$FP" -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of csv=p=0 "$f" | awk -F, '{ sub("/1", "", $3); print $1 "x" $2, $3 }')"
done
check "happy: 2 PASS lines" 2 "$(grep -c '^PASS: ' "$(O h1)")"
check "happy: no part file left" 0 "$(find "$T/c1" -name '*m7c-part*' | wc -l)"
has   "happy: 3 IDR keyframes in 6 s" "3 IDR keyframes every 2.0 s, closed GOP" "$(O h1)"
X2=(M7C_FFMPEG="$FF" M7C_FFPROBE="$FP")
run h2 "${X2[@]}" -- --seconds 4 --only sub --motion 4 --out "$T/c2"
check "--only sub: exit 0" 0 "$(rc h2)"; check "--only sub: only the sub clip" "sub-360p15.mp4" "$(ls "$T/c2")"
run k0 "${X2[@]}" -- --check "$T/c1/main-1080p25.mp4" 1920x1080 25 1600; check "--check of a good clip: exit 0" 0 "$(rc k0)"

# --- the checker rejects camera-unlike clips ---
bad() {  # bad NAME WANT-SUBSTRING [ffmpeg output options...]: a 6 s 640x360@15 clip, checked as the sub clip
  local n=$1 want=$2; shift 2
  "$FF" -hide_banner -loglevel error -nostdin -y -f lavfi -i "testsrc2=s=640x360:r=15,noise=alls=10:allf=t" -t 6 "$@" "$T/$n.mp4" 2>"$T/$n.gen" \
    || { check "$n: generated" 0 1; return; }
  run "$n" "${X2[@]}" -- --check "$T/$n.mp4" 640x360 15 256
  check "$n: exit 1" 1 "$(rc "$n")"; has "$n: names the problem" "$want" "$(O "$n")"
}
G=(-c:v libx265 -preset ultrafast -pix_fmt yuv420p -b:v 256k)
P="keyint=30:min-keyint=30:scenecut=0:open-gop=0:bframes=0:vbv-maxrate=256:vbv-bufsize=512:log-level=error"
bad k1 "tag 'hev1', want hvc1"            "${G[@]}" -tag:v hev1 -x265-params "$P" -an
bad k2 "keyframes not every 2.0 s"        "${G[@]}" -tag:v hvc1 -x265-params "${P/keyint=30:min-keyint=30/keyint=45:min-keyint=45}" -an
bad k3 "open-GOP/leading NAL types"       "${G[@]}" -tag:v hvc1 -x265-params "${P/open-gop=0:bframes=0/open-gop=1:bframes=4}" -an
bad k4 "codec 'h264', want hevc"          -c:v libx264 -preset ultrafast -pix_fmt yuv420p -b:v 256k -g 30 -an
bad k5 "bitrate"                          "${G[@]}" -tag:v hvc1 -x265-params "${P//256/2000}" -b:v 2000k -an
bad k6 "has audio"                        -f lavfi -i "sine=f=440" -t 6 -map 0:v -map 1:a -c:a aac "${G[@]}" -tag:v hvc1 -x265-params "$P"
bad k7 "pix_fmt 'yuv420p10le'"            -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -b:v 256k -tag:v hvc1 -x265-params "$P" -an
run k8 "${X2[@]}" -- --check "$T/c1/sub-360p15.mp4" 704x576 25 256
check "wrong size and rate: exit 1" 1 "$(rc k8)"; has "names the size" "size 640x360, want 704x576" "$(O k8)"; has "names the rate" "rate '15/1', want 25/1" "$(O k8)"

# --- a clip that fails its check is never moved into place ---
# shellcheck disable=SC2016  # the wrapper's own $a and $@, expanded when it runs
printf '#!/bin/sh\nfor a; do shift; [ "$a" = hvc1 ] && a=hev1; set -- "$@" "$a"; done\nexec %s "$@"\n' "$FF" > "$T/ff-hev1"; chmod +x "$T/ff-hev1"
run f1 M7C_FFMPEG="$T/ff-hev1" M7C_FFPROBE="$FP" -- --seconds 2 --only sub --out "$T/c3"
check "a failing clip: exit 1" 1 "$(rc f1)"; has "says not moved into place" "not moved into place" "$(O f1)"
check "a failing clip: nothing in the out dir" 0 "$(find "$T/c3" -mindepth 1 | wc -l)"

[ "$fail" = 0 ] && echo "make-clips.test: all ok" || echo "make-clips.test: FAILURES"
exit "$fail"
