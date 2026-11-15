#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")" || exit 1; . ./lib-checks.sh; fail=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
check "frame 640x360"          345600   "$(expected_frame_bytes 640 360)"
check "frame 1280x720 (F10)"   1382400  "$(expected_frame_bytes 1280 720)"
check "2 cams x 50 @ 640x360"  34560000 "$(expected_frames_total 640 360 50 2)"
check "2 cams x 10 @ 640x360"  6912000  "$(expected_frames_total 640 360 10 2)"
within_mib 34560000 34560000 10; check "within: equal"            0 $?
within_mib 44000000 34560000 10; check "within: +9 MiB"           0 $?
within_mib 46000000 34560000 10; check "within: +11 MiB rejected" 1 $?
within_mib 30000000 34560000 10; check "within: below rejected"   1 $?
printf 'anon 123456\nfile 9\nshmem 777\n' > "$T/ms"
check "cgroup_stat anon"       123456 "$(cgroup_stat "$T/ms" anon)"
check "cgroup_stat shmem"      777    "$(cgroup_stat "$T/ms" shmem)"
is_lib_missing_error "OSError: libedgetpu.so.1: cannot open shared object file"; check "lib-missing detected" 0 $?
is_lib_missing_error "ValueError: Failed to load delegate from /snap/x/usr/lib/aarch64-linux-gnu/libedgetpu.so.1"; check "no-device is not lib-missing" 1 $?
check "quota 2 GiB peak -> 1228MB" "1228MB" "$(quota_mb 2147483648)"
check "quota floor 256MB"          "256MB"  "$(quota_mb 1000)"
exit "$fail"
