#!/usr/bin/env bash
# Pure check helpers for the arm64 VM battery (M7c T12). Sourced, not executed. No I/O except cgroup_stat's read.

_is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; }

# expected_frame_bytes W H -> bytes of one yuv420 detect frame (W*H*3/2, F9/F10).
expected_frame_bytes() {
  _is_uint "${1:-}" && _is_uint "${2:-}" || { echo "lib-checks: expected_frame_bytes W H (integers)" >&2; return 2; }
  echo $(( $1 * $2 * 3 / 2 ))
}

# expected_frames_total W H N CAMS -> N x CAMS x W*H*3/2.
expected_frames_total() {
  _is_uint "${3:-}" && _is_uint "${4:-}" || { echo "lib-checks: expected_frames_total W H N CAMS (integers)" >&2; return 2; }
  local f; f=$(expected_frame_bytes "${1:-}" "${2:-}") || return 2
  echo $(( $3 * $4 * f ))
}

# within_mib ACTUAL EXPECTED MIB -> 0 iff EXPECTED <= ACTUAL <= EXPECTED + MIB*1048576. Non-integers fail (2).
within_mib() {
  _is_uint "${1:-}" && _is_uint "${2:-}" && _is_uint "${3:-}" || return 2
  [ "$1" -ge "$2" ] && [ "$1" -le $(( $2 + $3 * 1048576 )) ]
}

# cgroup_stat FILE KEY -> the value of KEY in memory.stat format ("key value" lines). Missing key: return 1.
cgroup_stat() {
  awk -v k="${2:?cgroup_stat FILE KEY}" '$1 == k { print $2; found = 1; exit } END { exit !found }' "${1:?cgroup_stat FILE KEY}"
}

# is_lib_missing_error STR -> 0 iff STR is a dynamic-loader "library not found" error (V18).
is_lib_missing_error() {
  case "${1:-}" in *"cannot open shared object file"*) return 0 ;; esac
  return 1
}

# quota_mb PEAK_BYTES -> max(256, PEAK_BYTES*6/10/1048576) followed by MB (V11: a cap below the V10 peak).
quota_mb() {
  _is_uint "${1:-}" || { echo "lib-checks: quota_mb PEAK_BYTES (integer)" >&2; return 2; }
  local m=$(( $1 * 6 / 10 / 1048576 ))
  [ "$m" -ge 256 ] || m=256
  echo "${m}MB"
}
