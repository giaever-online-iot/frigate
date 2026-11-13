#!/usr/bin/env bash
# Unit tests for release-arch.sh. No network: a stub `snapcraft` on PATH serves the fixture for
# `revisions`, records every call, and refuses `release` when STUB_FAIL_RELEASE is set.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; RA="${RA:-$HERE/release-arch.sh}"; fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"; else printf 'FAIL - %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
STUB=$(mktemp -d); trap 'rm -rf "$STUB"' EXIT
cat > "$STUB/snapcraft" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$1" in
  revisions) cat "$STUB_FIXTURE" ;;
  release)   if [ -n "${STUB_FAIL_RELEASE:-}" ]; then echo "stub: release refused" >&2; exit 3; fi ;;
  *)         echo "stub: unexpected: $*" >&2; exit 99 ;;
esac
EOS
chmod +x "$STUB/snapcraft"
run() { : > "$STUB/log"
  PATH="$STUB:$PATH" STUB_LOG="$STUB/log" STUB_FIXTURE="$HERE/fixtures/${FIXTURE:-snapcraft-revisions.txt}" SNAP_NAME=frigate \
    "$RA" "$@" > "$STUB/out" 2>&1; }
releases() { grep '^release ' "$STUB/log" | tr '\n' ';'; }

# Merge path, amd64-only allowlist: exactly the current amd64 PR9 revision, the same one
# `snapcraft promote --from-channel latest/edge/PR9` would have moved for amd64.
run latest/edge/PR9 latest/edge amd64;          check "merge amd64-only: exit 0" 0 $?
check "merge amd64-only: releases 12 only"      "release frigate 12 latest/edge;" "$(releases)"
check "merge: revisions fetched once"           1 "$(grep -c '^revisions frigate$' "$STUB/log")"
run latest/edge/PR9 latest/edge amd64,arm64;    check "both archs: exit 0" 0 $?
check "both archs: 12 then 14 (13 historic)"    "release frigate 12 latest/edge;release frigate 14 latest/edge;" "$(releases)"
# Beta path: arm64 allowlisted but no current edge revision -> skipped with a message; amd64 current is 6 (7 rolled back).
run latest/edge latest/beta amd64,arm64;        check "beta: exit 0" 0 $?
check "beta: releases only amd64 6"             "release frigate 6 latest/beta;" "$(releases)"
check "beta: arm64 skipped with message"        1 "$(grep -c '^no current arm64 revision in latest/edge; skipping arm64$' "$STUB/out")"
# A failing `snapcraft release` must fail the script.
STUB_FAIL_RELEASE=1 run latest/edge/PR9 latest/edge amd64; rc=$?
check "failing release: non-zero exit"          1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
# --revision path (promote-beta's manual input).
run --revision 14 latest/beta amd64;            rc=$?
check "revision arm64 vs amd64 list: exit 1"    1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "revision refused: no release call"       "" "$(releases)"
check "revision refused: error names arch"      1 "$(grep -c '^::error::revision 14 is arm64, not in amd64$' "$STUB/out")"
run --revision 6 latest/beta amd64;             check "revision amd64 allowed: exit 0" 0 $?
check "revision amd64 released"                 "release frigate 6 latest/beta;" "$(releases)"
run --revision 99 latest/beta amd64;            rc=$?
check "unknown revision: exit 1, no release"    "1:" "$([ "$rc" -ne 0 ] && echo 1 || echo 0):$(releases)"
# Zero-release: nothing released must FAIL, not skip silently.
ERR='::error::no current revision for'
FIXTURE=snapcraft-revisions-arm64only.txt run latest/edge/PR9 latest/edge amd64; rc=$?
check "zero-release arm64-only PR: exit 1, no release" "1:" "$([ "$rc" -ne 0 ] && echo 1 || echo 0):$(releases)"
check "zero-release arm64-only PR: error line" 1 "$(grep -c "^$ERR amd64 in latest/edge/PR9: nothing released\$" "$STUB/out")"
FIXTURE=snapcraft-revisions-empty.txt run latest/edge/PR9 latest/edge amd64; rc=$?
check "zero-release empty list: exit 1, no release" "1:" "$([ "$rc" -ne 0 ] && echo 1 || echo 0):$(releases)"
run latest/edge latest/beta arm64; rc=$?
check "zero-release beta arm64: exit 1, no release" "1:" "$([ "$rc" -ne 0 ] && echo 1 || echo 0):$(releases)"
check "zero-release beta arm64: error line" 1 "$(grep -c "^$ERR arm64 in latest/edge: nothing released\$" "$STUB/out")"
[ "$fail" -eq 0 ] && echo "All release-arch tests passed." || echo "Some release-arch tests FAILED."
exit "$fail"
