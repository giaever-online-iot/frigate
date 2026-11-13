#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1; fail=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
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
exit "$fail"
