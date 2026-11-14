#!/usr/bin/env bash
# M7c hub, synthetic camera stand-in (W-7 Q7 answer 1): make the two H.265 clips on the LAPTOP. Nothing is
# re-encoded on the hub: go2rtc serves them there with `-c copy` (tests/hub/make-config.sh, M7C_SOURCE=clip).
#   main-1080p25.mp4  1920x1080, 25 fps, ~1.6 Mbit/s: the cameras' main stream as measured (1080p, ~25 fps,
#                     ~1.6 Mbit/s). cam1 decodes it as its DETECT input (the worst case); cam2 records it.
#   sub-360p15.mp4    640x360, 15 fps, ~256 kbit/s: cam2's detect input. 640x360 at 15 fps is the first row of
#                     spec §7.3, the §7.1 shm example and the VM battery V7 clip. The real cameras' sub-stream size
#                     and bitrate are UNKNOWN; 256 kbit/s is an ESTIMATE.
# Picture: a static SMPTE HD bars background, a moving testsrc2 box (its area is --motion % of the frame; it
# travels across the whole frame on an 8 s / 11 s Lissajous path) and light temporal noise (sensor-like; it also
# lets the encoder reach the camera's bitrate). Motion is therefore constant, all the time.
# Encoding (libx265, like a camera): closed GOP, an IDR every 2 s (keyint = min-keyint = 2 x fps, scenecut off,
# open-gop off), no B-frames, VBV at the target rate, tag hvc1, yuv420p, no audio. The duration is rounded to whole
# GOPs, so the loop seam of `-stream_loop -1` lands on an IDR. Note: with tag hvc1 the MP4 muxer keeps VPS/SPS/PPS
# in hvcC only (not in-band); over RTSP they travel in the SDP (sprop-vps/sps/pps).
# Each clip is checked after encoding (see check_clip; `--check` runs only that on an existing file) and only
# then moved into place; the script prints bytes and sha256 of each. The clips live OUTSIDE the repo and are
# never committed.
# ffmpeg: M7C_FFMPEG / M7C_FFPROBE, else the snap's own 8.0 tree extracted (unsquashfs, read-only) from the local
# amd64 frigate file, sha256-checked first: a static build with libx265, unconfined (a strict-snap ffmpeg cannot
# write under ~/.cache). Tools dir: ~/.cache/frigate-m7c-evidence/hub/tools.
# Usage: make-clips.sh [--out DIR] [--seconds N] [--motion PCT] [--only main|sub]
#        make-clips.sh --check FILE WIDTHxHEIGHT FPS KBPS
# Exit: 0 ok; 1 a clip failed its check (nothing moved into place); 2 usage or tools.
set -uo pipefail
EV="$HOME/.cache/frigate-m7c-evidence"
usage() { echo "usage: make-clips.sh [--out DIR] [--seconds N] [--motion PCT] [--only main|sub] | --check FILE WxH FPS KBPS" >&2; exit 2; }
say() { echo "make-clips: $*"; }
uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; }

tools() {  # sets FF and FP
  FF="${M7C_FFMPEG:-}"; FP="${M7C_FFPROBE:-}"
  if [ -n "$FF" ] || [ -n "$FP" ]; then
    { [ -x "$FF" ] && [ -x "$FP" ]; } || { echo "make-clips: M7C_FFMPEG and M7C_FFPROBE must both be executables" >&2; exit 2; }
  else
    local snap="${M7C_AMD64_SNAP:-$EV/amd64/frigate_0.18.2_amd64.snap}" shaf="${M7C_AMD64_SHA:-$EV/amd64.sha256}"
    local td="$EV/hub/tools/ffmpeg-8.0" want got
    FF="$td/ffmpeg"; FP="$td/ffprobe"
    if [ ! -x "$FF" ] || [ ! -x "$FP" ]; then
      command -v unsquashfs >/dev/null || { echo "make-clips: unsquashfs is required (or set M7C_FFMPEG/M7C_FFPROBE)" >&2; exit 2; }
      if [ ! -r "$snap" ] || [ ! -r "$shaf" ]; then echo "make-clips: no $snap or $shaf (or set M7C_FFMPEG/M7C_FFPROBE)" >&2; exit 2; fi
      want=$(awk 'NR == 1 { print $1 }' "$shaf"); got=$(sha256sum "$snap" | awk '{ print $1 }')
      [ "$got" = "$want" ] || { echo "make-clips: $snap sha256 $got, want $want" >&2; exit 2; }
      local x; x=$(mktemp -d) || exit 2
      unsquashfs -q -n -d "$x/r" "$snap" usr/lib/ffmpeg/8.0/bin/ffmpeg usr/lib/ffmpeg/8.0/bin/ffprobe >/dev/null 2>&1 \
        || { rm -rf "$x"; echo "make-clips: unsquashfs failed" >&2; exit 2; }
      mkdir -p "$td" && mv -f "$x/r/usr/lib/ffmpeg/8.0/bin/ffmpeg" "$x/r/usr/lib/ffmpeg/8.0/bin/ffprobe" "$td/"; rm -rf "$x"
      say "extracted the snap's ffmpeg 8.0 tree from $snap (sha256 $got) to $td"
    fi
  fi
  local enc; enc=$("$FF" -hide_banner -encoders 2>/dev/null)   # no grep -q on a pipe: SIGPIPE + pipefail
  printf '%s\n' "$enc" | grep -qw libx265 || { echo "make-clips: $FF has no libx265" >&2; exit 2; }
}

# check_clip FILE WxH FPS KBPS: prints one FAIL line per problem; returns 0 iff none.
check_clip() {
  local f=$1 size=$2 fps=$3 kbps=$4 bad=0 info kt gaps nal dur bytes rate
  info=$("$FP" -v error -select_streams v:0 -show_entries stream=codec_name,codec_tag_string,width,height,r_frame_rate,pix_fmt \
    -show_entries format=duration -of default=nw=1 "$f" 2>/dev/null)
  get() { printf '%s\n' "$info" | sed -n "s/^$1=//p" | head -n 1; }
  [ "$(get codec_name)" = hevc ] || { echo "FAIL: $f codec '$(get codec_name)', want hevc"; bad=1; }
  [ "$(get codec_tag_string)" = hvc1 ] || { echo "FAIL: $f tag '$(get codec_tag_string)', want hvc1"; bad=1; }
  [ "$(get width)x$(get height)" = "$size" ] || { echo "FAIL: $f size $(get width)x$(get height), want $size"; bad=1; }
  [ "$(get r_frame_rate)" = "$fps/1" ] || { echo "FAIL: $f rate '$(get r_frame_rate)', want $fps/1"; bad=1; }
  [ "$(get pix_fmt)" = yuv420p ] || { echo "FAIL: $f pix_fmt '$(get pix_fmt)', want yuv420p"; bad=1; }
  [ -z "$("$FP" -v error -select_streams a -show_entries stream=index -of csv=p=0 "$f" 2>/dev/null)" ] || { echo "FAIL: $f has audio"; bad=1; }
  dur=$(get duration)
  # keyframes: every one exactly 2 s after the previous, the first at 0
  kt=$("$FP" -v error -select_streams v:0 -skip_frame nokey -show_entries frame=pts_time -of csv=p=0 "$f" 2>/dev/null | tr -d ',')
  gaps=$(printf '%s\n' "$kt" | awk 'NF { if (n == 0 && $1 + 0 != 0) bad = 1; if (n > 0 && ($1 - p < 1.999 || $1 - p > 2.001)) bad = 1; p = $1; n++ }
    END { if (n == 0) bad = 1; print (bad ? "bad" : "ok") " " n }')
  [ "${gaps%% *}" = ok ] || { echo "FAIL: $f keyframes not every 2.0 s from 0 ($(printf '%s' "$kt" | tr '\n' ' ' | cut -c1-120))"; bad=1; }
  # closed GOP: every random-access picture is an IDR (NAL 19/20); no CRA (21), BLA (16-18) or B/RASL/RADL leading
  nal=$("$FF" -hide_banner -v info -i "$f" -map 0:v:0 -c copy -bsf:v trace_headers -f null - 2>&1 | awk '/nal_unit_type/ { print $NF }' | sort -n | uniq -c | awk '{ printf "%s:%s ", $2, $1 }')
  case " $nal" in *" 21:"*|*" 16:"*|*" 17:"*|*" 18:"*|*" 6:"*|*" 7:"*|*" 8:"*|*" 9:"*) echo "FAIL: $f has open-GOP/leading NAL types ($nal)"; bad=1 ;; esac
  local idr; idr=$(printf '%s' "$nal" | tr ' ' '\n' | awk -F: '$1 == 19 || $1 == 20 { s += $2 } END { print s + 0 }')
  [ "$idr" = "${gaps#* }" ] || { echo "FAIL: $f has $idr IDR pictures for ${gaps#* } keyframes ($nal)"; bad=1; }
  bytes=$(stat -c %s "$f")
  rate=$(awk -v b="$bytes" -v d="$dur" 'BEGIN { if (d > 0) printf "%d", b * 8 / d / 1000; else print 0 }')
  awk -v r="$rate" -v k="$kbps" 'BEGIN { exit !(r >= k * 0.75 && r <= k * 1.25) }' \
    || { echo "FAIL: $f bitrate ${rate} kbit/s, want $kbps ±25 %"; bad=1; }
  [ "$bad" = 0 ] && echo "PASS: $f hevc hvc1 $size ${fps}fps yuv420p, ${gaps#* } IDR keyframes every 2.0 s, closed GOP, ${rate} kbit/s over ${dur} s"
  return "$bad"
}

if [ "${1:-}" = --check ]; then
  [ $# -eq 5 ] || usage
  if ! [[ "$3" =~ ^[0-9]+x[0-9]+$ ]] || ! uint "$4" || ! uint "$5" || [ ! -r "$2" ]; then usage; fi
  tools; check_clip "$2" "$3" "$4" "$5"; exit $?
fi

OUT="$EV/hub/clips"; SECS=180; MOTION=25; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || usage; OUT=$2; shift 2 ;;
    --seconds) [ $# -ge 2 ] || usage; SECS=$2; shift 2 ;;
    --motion) [ $# -ge 2 ] || usage; MOTION=$2; shift 2 ;;
    --only) [ $# -ge 2 ] || usage; ONLY=$2; shift 2 ;;
    *) usage ;;
  esac
done
{ uint "$SECS" && [ "$SECS" -ge 2 ] && [ "$SECS" -le 3600 ]; } || usage
{ uint "$MOTION" && [ "$MOTION" -ge 1 ] && [ "$MOTION" -le 100 ]; } || usage
case "$ONLY" in ''|main|sub) ;; *) usage ;; esac
SECS=$(( SECS / 2 * 2 ))   # whole 2 s GOPs: the loop seam is an IDR
tools; mkdir -p "$OUT" || exit 2

# make NAME W H FPS KBPS
make() {
  local name=$1 w=$2 h=$3 fps=$4 kbps=$5 bw bh part
  # box side = frame side x sqrt(MOTION/100), rounded down to even (yuv420p)
  bw=$(awk -v s="$w" -v m="$MOTION" 'BEGIN { v = int(s * sqrt(m / 100) / 2) * 2; print (v < 2 ? 2 : v) }')
  bh=$(awk -v s="$h" -v m="$MOTION" 'BEGIN { v = int(s * sqrt(m / 100) / 2) * 2; print (v < 2 ? 2 : v) }')
  part="$OUT/$name.m7c-part.mp4"; rm -f "$part"
  "$FF" -hide_banner -loglevel error -nostdin -y -f lavfi \
    -i "smptehdbars=s=${w}x${h}:r=${fps},format=yuv420p[bg];testsrc2=s=${bw}x${bh}:r=${fps}[box];[bg][box]overlay=x='(W-w)*(0.5+0.5*sin(2*PI*t/8))':y='(H-h)*(0.5+0.5*cos(2*PI*t/11))',noise=alls=10:allf=t" \
    -t "$SECS" -an -c:v libx265 -preset fast -pix_fmt yuv420p -tag:v hvc1 -b:v "${kbps}k" \
    -x265-params "keyint=$((2 * fps)):min-keyint=$((2 * fps)):scenecut=0:open-gop=0:bframes=0:repeat-headers=1:vbv-maxrate=${kbps}:vbv-bufsize=$((2 * kbps)):log-level=error" \
    "$part" || { rm -f "$part"; echo "FAIL: $name: ffmpeg failed"; return 1; }
  if ! check_clip "$part" "${w}x${h}" "$fps" "$kbps"; then rm -f "$part"; echo "FAIL: $name: not moved into place"; return 1; fi
  mv -f "$part" "$OUT/$name.mp4"
  say "$name.mp4 $(stat -c %s "$OUT/$name.mp4") B sha256 $(sha256sum "$OUT/$name.mp4" | awk '{ print $1 }')"
}
rc=0
[ "$ONLY" = sub ]  || make main-1080p25 1920 1080 25 1600 || rc=1
[ "$ONLY" = main ] || make sub-360p15 640 360 15 256 || rc=1
say "clips in $OUT ($SECS s each, motion box ${MOTION} % of the frame); $([ "$rc" = 0 ] && echo ok || echo FAILED)"
exit "$rc"
