#!/usr/bin/env bash
set +x +o xtrace   # first: no trace of any value, even under `bash -x` or an inherited SHELLOPTS
# Item A's long-session probe, from the maintainer's laptop (W-23 T12, plan P15, SF11). TEST TOOLING: never in the snap.
#
#   probe-run.sh <cam1|cam2|both> <minutes> <extend|repeat>    one long session per camera (a real camera login!)
#   probe-run.sh --status                                      the probe's own ledger state; no key file, no camera
#
# Inputs are make-config's: M7C_ENV_DIR (default ~/.local/state/m7c-hub) with cameras.pairs, env and the key file it
# names; read by the shared read_cameras (tests/hub/lib-cameras.sh). The camera files go into a mktemp -d directory
# (0700, files 0600) written with printf (a builtin: no argv, no environment) and removed by an EXIT trap.
# probe.py runs with the venv python and the 8.0 ffmpeg unsquashed from the local amd64 snap file (as
# tests/hub/serve.test.sh does; heavy: run under `flock -w 3600 /tmp/claude-1000/chim-suites.lock`).
# State: $M7C_ENV_DIR/w23-probe-state (0700, never deleted); probe.py puts the ledger in <state>/ezviz/state, the
# helper's layout (C18), so the D4 budget applies across probe runs. Knobs for tests: PROBE_PYTHON, PROBE_FFMPEG,
# PROBE_COUNT (keepalive count, default 4320), PROBE_STATUS_NOW (a fixed epoch for --status).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
say() { :; }                                         # read_cameras narrates on stdout; the probe prints only its own lines
die() { echo "probe-run: error E$1: $2" >&2; exit "$1"; }
usage() { die 2 "usage: probe-run.sh <cam1|cam2|both> <minutes> <extend|repeat> | --status"; }
ENVD="${M7C_ENV_DIR:-$HOME/.local/state/m7c-hub}"; STATE="$ENVD/w23-probe-state"

if [ "${1:-}" = "--status" ]; then
  [ $# -eq 1 ] || usage
  now="${PROBE_STATUS_NOW:-$(date +%s)}"
  for cam in cam1 cam2; do
    led="$STATE/ezviz/state/$cam.ledger"; last=""
    [ -r "$led" ] && last=$(sed -n 's/^{"t":\([0-9]*\)\(\.[0-9]*\)\{0,1\},"ev":"attempt".*/\1/p' "$led" | tail -n 1)
    latched=0; [ -e "$STATE/ezviz/state/$cam.latch" ] && latched=1
    if [ -n "$last" ]; then
      echo "probe-state $cam: last_attempt=$(date -u -d "@$last" +%Y-%m-%dT%H:%M:%SZ) age_s=$(( now - last )) latched=$latched"
    else
      echo "probe-state $cam: last_attempt=none age_s=- latched=$latched"
    fi
  done
  exit 0
fi

[ $# -eq 3 ] || usage
WHICH=$1; MINUTES=$2; FORM=$3
case "$WHICH" in cam1|cam2|both) ;; *) usage ;; esac
[[ "$MINUTES" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [ "${MINUTES//[0.]/}" != "" ] || usage
case "$FORM" in extend|repeat) ;; *) usage ;; esac

IDS=(); IPS=(); PW=()
# shellcheck source=tests/hub/lib-cameras.sh
. "$HERE/../hub/lib-cameras.sh"
read_cameras

umask 077
TMPD=$(mktemp -d) || die 2 "no temp directory"
trap 'rm -rf "$TMPD"' EXIT
CAMD="$TMPD/cams"; mkdir "$CAMD"; chmod 700 "$CAMD"
for i in 0 1; do
  printf 'host=%s\nport=8000\nserial=%s\nlogin=%s\n' "${IPS[$i]}" "${IDS[$i]}" "${PW[$i]}" > "$CAMD/cam$((i + 1)).conf"
  chmod 600 "$CAMD/cam$((i + 1)).conf"
done
mkdir -p "$STATE"; chmod 700 "$STATE"

if [ -n "${PROBE_PYTHON:-}" ]; then PY=$PROBE_PYTHON; else PY=$(bash "$HERE/venv.sh") || die 2 "the venv could not be built"; fi
if [ -n "${PROBE_FFMPEG:-}" ]; then FF=$PROBE_FFMPEG; else
  SNAP_FILE="${M7C_AMD64_SNAP:-$HOME/.cache/frigate-m7c-evidence/amd64/frigate_0.18.2_amd64.snap}"
  command -v unsquashfs >/dev/null && [ -r "$SNAP_FILE" ] || die 2 "need unsquashfs and the local amd64 frigate file"
  unsquashfs -q -n -d "$TMPD/r" "$SNAP_FILE" usr/lib/ffmpeg/8.0/bin/ffmpeg >/dev/null 2>&1
  FF=$TMPD/r/usr/lib/ffmpeg/8.0/bin/ffmpeg
  [ -x "$FF" ] || die 2 "ffmpeg 8.0 could not be extracted"
fi

names=(cam1 cam2); [ "$WHICH" = both ] || names=("$WHICH")
pids=(); rc=0
for n in "${names[@]}"; do
  "$PY" -I -B "$HERE/probe.py" "$STATE" "$CAMD" "$n" "$MINUTES" "$FORM" "${PROBE_COUNT:-4320}" "$FF" &
  pids+=("$!")
done
for p in "${pids[@]}"; do wait "$p" || { r=$?; [ "$rc" != 0 ] || rc=$r; }; done
exit "$rc"
