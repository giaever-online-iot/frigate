#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1; fail=0; unset SPIKE_TIME_SCALE HARNESS_ARCH
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
L=tests/lib/harness-arch.sh
check "HOST_ARCH honours HARNESS_ARCH"   arm64 "$(HARNESS_ARCH=arm64 bash -c ". $L; echo \$HOST_ARCH")"
check "artifact_glob arm64"              "frigate*_arm64.snap" "$(bash -c ". $L; artifact_glob arm64")"
F=$(bash -c ". $L; size_floor_for_arch amd64")
check "amd64 floor is a positive MiB multiple" 0 "$( [ -n "$F" ] && [ "$F" -gt 0 ] && [ $((F % 1048576)) -eq 0 ]; echo $?)"
check "amd64 floor equals AMD64_SIZE_FLOOR"    "$F" "$(bash -c ". $L; echo \$AMD64_SIZE_FLOOR")"
G=$(bash -c ". $L; size_floor_for_arch arm64")
check "arm64 floor is a positive MiB multiple" 0 "$( [ -n "$G" ] && [ "$G" -gt 0 ] && [ $((G % 1048576)) -eq 0 ]; echo $?)"
check "arm64 floor equals ARM64_SIZE_FLOOR"    "$G" "$(bash -c ". $L; echo \$ARM64_SIZE_FLOOR")"
check "arm64 floor = floor(0.85 x 916746240 B) to MiB (T14)" 779091968 "$G"
bash -c ". $L; size_floor_for_arch riscv64" >/dev/null 2>&1; check "unknown arch -> exit 1" 1 $?
check "scaled default x1"                30    "$(bash -c ". $L; scaled 30")"
check "scaled x6"                        180   "$(SPIKE_TIME_SCALE=6 bash -c ". $L; scaled 30")"
check "scaled decimal x6"                3     "$(SPIKE_TIME_SCALE=6 bash -c ". $L; scaled 0.5")"
SPIKE_TIME_SCALE=0  bash -c ". $L; scaled 30" >/dev/null 2>&1; check "scale 0 rejected"    1 $?
SPIKE_TIME_SCALE=21 bash -c ". $L; scaled 30" >/dev/null 2>&1; check "scale 21 rejected"   1 $?
SPIKE_TIME_SCALE=x  bash -c ". $L; scaled 30" >/dev/null 2>&1; check "scale junk rejected" 1 $?
s=$(SPIKE_TIME_SCALE=3 bash -c ". $L; a=\$(date +%s%N); sleep 0.1; b=\$(date +%s%N); echo \$(( (b-a)/1000000 ))")
check "sleep wrapper scales (0.1s x3 >= 290ms)" 0 "$([ "$s" -ge 290 ]; echo $?)"
exit "$fail"
