#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; G="$HERE/arch-gate.sh"; fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"; else printf 'FAIL - %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
unset GITHUB_STEP_SUMMARY
"$G" amd64 2 "" >/dev/null 2>&1;            check "all built: exit 0"            0 $?
out=$("$G" amd64 1 "arm64" 2>&1);           rc=$?; check "arm64 missing: exit 0" 0 $rc
check "arm64 missing: warning"              1 "$(grep -c '^::warning::arm64 (experimental) build/upload missing: not gating$' <<<"$out")"
out=$("$G" amd64 1 "amd64" 2>&1);           rc=$?; check "amd64 missing: exit 1" 1 $rc
check "amd64 missing: error"                1 "$(grep -c '^::error::required arch amd64 missing$' <<<"$out")"
"$G" amd64 0 "amd64 arm64" >/dev/null 2>&1; check "both missing: exit 1"         1 $?
"$G" amd64 0 "" >/dev/null 2>&1;            check "zero built: exit 1"           1 $?
"$G" amd64 "" "" >/dev/null 2>&1;           check "empty count: exit 1"          1 $?
"$G" amd64,arm64 1 "arm64" >/dev/null 2>&1; check "arm64 required later: exit 1" 1 $?
S=$(mktemp); GITHUB_STEP_SUMMARY="$S" "$G" amd64 1 "arm64" >/dev/null 2>&1
check "summary gets the warning"            1 "$(grep -c '^- .*arm64 (experimental)' "$S")"; rm -f "$S"
[ "$fail" -eq 0 ] && echo "All arch-gate tests passed." || echo "Some arch-gate tests FAILED."
exit "$fail"
