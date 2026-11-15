#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1; fail=0; T=$(mktemp -d); trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
mkdir -p "$T/root/usr/bin"; cp /bin/true "$T/root/usr/bin/true"; printf '#!/bin/sh\n' > "$T/root/usr/bin/script"
bash tests/elf-census.sh "$T/root" x86-64 >/dev/null;  check "host ELF passes as x86-64" 0 $?
out=$(bash tests/elf-census.sh "$T/root" aarch64);      check "host ELF fails as aarch64" 1 $?
check "offender listed, script ignored" "usr/bin/true" "$out"
# (b) shared object counts as ELF
so=$(ldd /bin/true | awk '/libc\.so/ {print $3; exit}')
mkdir -p "$T/so/lib"; cp "$so" "$T/so/lib/libhost.so"
out=$(bash tests/elf-census.sh "$T/so" aarch64);        check "host .so listed as aarch64 offender" "lib/libhost.so" "$out"
# (c) non-ELF ignored
mkdir -p "$T/txt"; printf '!<arch>\n' > "$T/txt/lib.a"; printf 'hello\n' > "$T/txt/notes.txt"
out=$(bash tests/elf-census.sh "$T/txt" aarch64);       check "ar archive and text ignored (rc 0, empty)" "0:" "$?:$out"
# (a) unreadable fails closed
if [ "$(id -u)" -eq 0 ]; then echo "skip - unreadable test (running as root)"; else
  mkdir -p "$T/unr/bin"; cp /bin/true "$T/unr/bin/true"; chmod 000 "$T/unr/bin/true"
  bash tests/elf-census.sh "$T/unr" aarch64 >/dev/null 2>&1; check "unreadable file fails closed (exit 2)" 2 $?
  bash tests/elf-census.sh "$T/unr" x86-64 >/dev/null 2>&1;  check "unreadable file fails closed, x86-64 (exit 2)" 2 $?
fi
exit "$fail"
