#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1; fail=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
mkdir -p "$T/root/usr/bin"; cp /bin/true "$T/root/usr/bin/true"; printf '#!/bin/sh\n' > "$T/root/usr/bin/script"
bash tests/elf-census.sh "$T/root" x86-64 >/dev/null;  check "host ELF passes as x86-64" 0 $?
out=$(bash tests/elf-census.sh "$T/root" aarch64);      check "host ELF fails as aarch64" 1 $?
check "offender listed, script ignored" "usr/bin/true" "$out"
exit "$fail"
