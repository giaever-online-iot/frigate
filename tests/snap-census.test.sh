#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1; fail=0; T=$(mktemp -d); trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1"; printf '%s\n' "want: $2" "got:  $3"; fail=1; fi; }
mk() { mkdir -p "$T/$1/bin" "$T/$1/usr/lib"; echo 1 > "$T/$1/bin/same"; echo "$2" > "$T/$1/bin/chg"; echo "$3" > "$T/$1/usr/lib/libx.so"; echo "$4" > "$T/$1/m.pyc"; }
mk a 1 1 1; mk b 2 2 2
printf 'bin/chg\n' > "$T/exp"
out=$(bash tests/snap-census.sh "$T/a" "$T/b" "$T/exp"); rc=$?
check "expected change + build noise: exit 0" 0 $rc
check "lines" "CHANGED bin/chg
INFO CHANGED usr/lib/libx.so" "$out"
bash tests/snap-census.sh "$T/a" "$T/b" >/dev/null; check "unexpected bin/ change: exit 1" 1 $?
echo 1 > "$T/b/bin/new"; bash tests/snap-census.sh "$T/a" "$T/b" "$T/exp" >/dev/null; check "added path: exit 1" 1 $?
# path with a space: expected change listed in the expected file must be matched exactly
mk c 1 1 1; mk d 1 1 1
echo x > "$T/c/bin/with space"; echo y > "$T/d/bin/with space"
printf 'bin/with space\n' > "$T/exp2"
out=$(bash tests/snap-census.sh "$T/c" "$T/d" "$T/exp2"); rc=$?
check "space in path, expected: exit 0" 0 $rc
check "space in path, line" "CHANGED bin/with space" "$out"
bash tests/snap-census.sh "$T/c" "$T/d" >/dev/null; check "space in path, unexpected: exit 1" 1 $?
# (a) unreadable changed file fails closed (exit 2)
if [ "$(id -u)" = 0 ]; then echo "note - skipping mode-000 case: running as root"; else
mk e 1 1 1; mk f 2 1 1; chmod 000 "$T/f/bin/chg"
bash tests/snap-census.sh "$T/e" "$T/f" >/dev/null 2>&1; check "unreadable file: exit 2" 2 $?
chmod 644 "$T/f/bin/chg"; fi
# (b) symlink retarget under bin/
mk g 1 1 1; mk h 1 1 1; ln -s t1 "$T/g/bin/lnk"; ln -s t2 "$T/h/bin/lnk"
out=$(bash tests/snap-census.sh "$T/g" "$T/h"); rc=$?
check "symlink retarget: exit 1" 1 $rc; check "symlink retarget: line" "CHANGED bin/lnk" "$out"
# (c) symlink added under usr/lib
mk i 1 1 1; mk j 1 1 1; ln -s libx.so "$T/j/usr/lib/libx.so.1"
out=$(bash tests/snap-census.sh "$T/i" "$T/j"); rc=$?
check "symlink added: exit 1" 1 $rc; check "symlink added: line" "ADDED usr/lib/libx.so.1" "$out"
# (d) prefix anchoring
mk k 1 1 1; mk l 1 1 1
mkdir -p "$T/k/usr/share/snap" "$T/l/usr/share/snap" "$T/k/meta/hooks" "$T/l/meta/hooks"
echo 1 > "$T/k/usr/share/snap/f"; echo 2 > "$T/l/usr/share/snap/f"
out=$(bash tests/snap-census.sh "$T/k" "$T/l"); rc=$?
check "usr/share/snap/f: INFO, exit 0" 0 $rc; check "usr/share/snap/f: line" "INFO CHANGED usr/share/snap/f" "$out"
echo 1 > "$T/k/meta/hooks/h"; echo 2 > "$T/l/meta/hooks/h"
out=$(bash tests/snap-census.sh "$T/k" "$T/l"); rc=$?
check "meta/hooks/h gated: exit 1" 1 $rc
exit "$fail"
