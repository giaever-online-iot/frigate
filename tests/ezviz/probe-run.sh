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
# probe.py runs with the venv python ($W23_VENV, default ~/.cache/frigate-w23/venv-probe) and the snap's ffmpeg
# (n8.1.1, directory usr/lib/ffmpeg/8.0) unsquashed from the local amd64 snap file (as
# tests/hub/serve.test.sh does; heavy: run under `flock -w 3600 /tmp/claude-1000/chim-suites.lock`).
# State: $M7C_ENV_DIR/w23-probe-state (0700, never deleted); probe.py puts the ledger in <state>/ezviz/state, the
# helper's layout (C18), so the D4 budget applies across probe runs. Knobs for tests: PROBE_PYTHON, PROBE_FFMPEG,
# PROBE_COUNT (keepalive count, default 4320), PROBE_DIAG=1 (probe.py --diag: the counters-only diagnostic on the same
# line, GA A1 diagnosis), PROBE_HELPER=1 (probe.py --helper: the production helper against the camera, its ffmpeg child
# a framemd5 consumer of its MPEG-TS; round 9), PROBE_STATUS_NOW (a fixed epoch for --status, honoured only with
# PROBE_TEST=1). --status runs a stdlib-only python3 (PROBE_PYTHON or python3) over the state dir.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
say() { :; }                                         # read_cameras narrates on stdout; the probe prints only its own lines
die() { echo "probe-run: error E$1: $2" >&2; exit "$1"; }
usage() { die 2 "usage: probe-run.sh <cam1|cam2|both> <minutes> <extend|repeat> | --status"; }
ENVD="${M7C_ENV_DIR:-$HOME/.local/state/m7c-hub}"; STATE="$ENVD/w23-probe-state"

if [ "${1:-}" = "--status" ]; then
  [ $# -eq 1 ] || usage
  now=$(date +%s)
  [ "${PROBE_TEST:-}" = 1 ] && [ -n "${PROBE_STATUS_NOW:-}" ] && now=$PROBE_STATUS_NOW   # a fixed clock, tests only (M2)
  # latched comes from the ledger the way the gate and ezviz-ledger.sh decide it: ledger.parse + policy.decide (stdlib
  # only, so any python3 >= 3.11 will do; -P keeps the cwd off sys.path). Only the state dir is read: no key file, no camera.
  PYTHONPATH="$HERE/../../spike/ezviz" "${PROBE_PYTHON:-python3}" -P -B -c '
import sys, datetime
from pathlib import Path
from ezviz_source import ledger, policy
st, now = Path(sys.argv[1]), float(sys.argv[2])
for cam in ("cam1", "cam2"):
    try:
        recs = ledger.parse((st / (cam + ".ledger")).read_bytes())
    except OSError:
        recs = []
    att = [r["t"] for r in recs if r["ev"] == "attempt"]
    d = policy.decide(recs, now, latch_file=(st / (cam + ".latch")).exists())
    if att:
        iso = datetime.datetime.fromtimestamp(int(max(att)), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        print("probe-state %s: last_attempt=%s age_s=%d latched=%d" % (cam, iso, int(now - int(max(att))), d.cls == "latched"))
    else:
        print("probe-state %s: last_attempt=none age_s=- latched=%d" % (cam, d.cls == "latched"))
' "$STATE/ezviz/state" "$now" || die 2 "the status could not be read"
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
TMPD=$(mktemp -d -p "${XDG_RUNTIME_DIR:-/tmp}") || die 2 "no temp directory"   # M3: the logins go to a tmpfs where there is one
XD=$(mktemp -d) || die 2 "no temp directory"                                    # the big ffmpeg extraction: ordinary disk
pids=()
stop_probes() {   # I1: a signal ends the probes too (TERM: they close their sessions and write their records), then we leave
  local p
  for p in ${pids[@]+"${pids[@]}"}; do kill -TERM "$p" 2>/dev/null; done
  for p in ${pids[@]+"${pids[@]}"}; do wait "$p" 2>/dev/null; done
}
trap 'rm -rf "$TMPD" "$XD"' EXIT
trap 'stop_probes; exit 130' INT
trap 'stop_probes; exit 143' TERM
trap 'stop_probes; exit 129' HUP
CAMD="$TMPD/cams"; mkdir "$CAMD"; chmod 700 "$CAMD"
for i in 0 1; do
  printf 'host=%s\nport=8000\nserial=%s\nlogin=%s\n' "${IPS[$i]}" "${IDS[$i]}" "${PW[$i]}" > "$CAMD/cam$((i + 1)).conf"
  chmod 600 "$CAMD/cam$((i + 1)).conf"
done
mkdir -p "$STATE"; chmod 700 "$STATE"

# Fix wave 1, S4: the probe's own venv unless the caller names one. The shared default venv's .pth is retargeted by
# any checkout's test run (serve-ezviz.test.sh, venv.sh), and probe.py imports the helper lazily against a real camera.
export W23_VENV="${W23_VENV:-$HOME/.cache/frigate-w23/venv-probe}"
if [ -n "${PROBE_PYTHON:-}" ]; then PY=$PROBE_PYTHON; else PY=$(bash "$HERE/venv.sh") || die 2 "the venv could not be built"; fi
if [ -n "${PROBE_FFMPEG:-}" ]; then FF=$PROBE_FFMPEG; else
  SNAP_FILE="${M7C_AMD64_SNAP:-$HOME/.cache/frigate-m7c-evidence/amd64/frigate_0.18.2_amd64.snap}"
  command -v unsquashfs >/dev/null && [ -r "$SNAP_FILE" ] || die 2 "need unsquashfs and the local amd64 frigate file"
  unsquashfs -q -n -d "$XD/r" "$SNAP_FILE" usr/lib/ffmpeg/8.0/bin/ffmpeg >/dev/null 2>&1
  FF=$XD/r/usr/lib/ffmpeg/8.0/bin/ffmpeg
  [ -x "$FF" ] || die 2 "ffmpeg 8.0 could not be extracted"
fi

names=(cam1 cam2); [ "$WHICH" = both ] || names=("$WHICH")
DIAG=(); [ "${PROBE_DIAG:-}" = 1 ] && DIAG=(--diag)
[ "${PROBE_HELPER:-}" = 1 ] && DIAG+=(--helper)
rc=0
for n in "${names[@]}"; do
  "$PY" -I -B "$HERE/probe.py" ${DIAG[@]+"${DIAG[@]}"} "$STATE" "$CAMD" "$n" "$MINUTES" "$FORM" "${PROBE_COUNT:-4320}" "$FF" &
  pids+=("$!")
done
for p in "${pids[@]}"; do wait "$p" || { r=$?; [ "$rc" != 0 ] || rc=$r; }; done
exit "$rc"
