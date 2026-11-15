#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1; fail=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
SP="$T/root/usr/lib/python3.11/site-packages"
di() { mkdir -p "$SP/$1-$2.dist-info"; printf 'Name: %s\nVersion: %s\n' "$1" "$2" > "$SP/$1-$2.dist-info/METADATA"; printf 'Tag: %s\n' "$3" > "$SP/$1-$2.dist-info/WHEEL"; }
di a 1.0 py3-none-any; di b 2.0 cp311-cp311-manylinux_2_17_aarch64; di n 0.10.9 cp311-cp311-linux_aarch64; di c 3.0 cp311-cp311-manylinux_2_17_x86_64
out=$(bash tests/wheel-census.sh "$T/root" arm64);  check "x86 wheel in arm64 root: exit 1" 1 $?
grep -q '^c	3.0	' <<<"$out";                         check "offender c listed" 0 $?
rm -rf "$SP/c-3.0.dist-info"
out=$(bash tests/wheel-census.sh "$T/root" arm64);  check "clean arm64 root: exit 0" 0 $?
check "three rows" 3 "$(wc -l <<<"$out")"
bash tests/wheel-census.sh "$T/root" amd64 >/dev/null; check "aarch64 wheels in amd64 root: exit 1" 1 $?
bash tests/wheel-census.sh "$T/empty" arm64 >/dev/null 2>&1; check "no site-packages: exit 2" 2 $?
di m 1.0 cp311-cp311-manylinux_2_17_aarch64; printf 'Tag: cp311-cp311-manylinux2014_x86_64\n' >> "$SP/m-1.0.dist-info/WHEEL"
out=$(bash tests/wheel-census.sh "$T/root" arm64); check "second tag x86: exit 1" 1 $?
grep -q '^m	1.0	cp311-cp311-manylinux_2_17_aarch64,cp311-cp311-manylinux2014_x86_64$' <<<"$out"; check "tags comma-joined" 0 $?
rm "$SP/m-1.0.dist-info/WHEEL"
bash tests/wheel-census.sh "$T/root" arm64 >/dev/null 2>&1; check "missing WHEEL: exit 2" 2 $?
exit "$fail"
