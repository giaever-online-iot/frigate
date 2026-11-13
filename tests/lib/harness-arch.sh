#!/usr/bin/env bash
# Per-arch harness expectations and a TCG time scale for tests/spike-smoke.sh (M7c T7, spec D18).
# Sourced, not executed.
HOST_ARCH="${HARNESS_ARCH:-$(dpkg --print-architecture)}"

# Artifact glob for an arch: frigate_<ver>_<arch>.snap and frigate-remote_<arch>.snap.
artifact_glob() { echo "frigate*_$1.snap"; }

# Size floors in bytes. amd64 is the M8 harness literal (802 MiB); arm64 is recorded in M7c T14.
AMD64_SIZE_FLOOR=840957952
ARM64_SIZE_FLOOR=""

# Prints the floor for an arch (empty = none recorded yet). Unknown arch: return 1.
size_floor_for_arch() {
  case "$1" in
    amd64) echo "$AMD64_SIZE_FLOOR" ;;
    arm64) echo "$ARM64_SIZE_FLOOR" ;;
    *) echo "harness-arch: unsupported arch $1" >&2; return 1 ;;
  esac
}

# scaled <number>: number x SPIKE_TIME_SCALE (integer 1..20, default 1); decimals allowed.
scaled() {
  local f="${SPIKE_TIME_SCALE:-1}"
  case "$f" in ''|*[!0-9]*) echo "harness-arch: SPIKE_TIME_SCALE must be an integer 1..20, got '$f'" >&2; return 1 ;; esac
  if [ "$f" -lt 1 ] || [ "$f" -gt 20 ]; then
    echo "harness-arch: SPIKE_TIME_SCALE must be an integer 1..20, got '$f'" >&2; return 1
  fi
  awk -v n="$1" -v f="$f" 'BEGIN { printf "%.10g\n", n * f }'
}

# Scales every harness sleep exactly once (seq bounds are untouched, so no scale^2).
sleep() { command sleep "$(scaled "$1")"; }
