#!/usr/bin/env bash
# Hermetic test of snap/hooks/pre-refresh backup retention (M9 D21). No snap, no sqlite.
# Run: bash tests/pre-refresh.test.sh [sh|dash]   (exit 0 = all ok)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
SHELL_UNDER_TEST="${1:-sh}"
FAILS=0
ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1"; FAILS=$((FAILS+1)); }
expect_file()   { if [ -f "$2" ]; then ok "$1"; else bad "$1"; fi; }
expect_nofile() { if [ ! -e "$2" ]; then ok "$1"; else bad "$1"; fi; }
expect_count()  { local n="$1" want="$2"; shift 2; local got=0 f; for f in "$@"; do [ -e "$f" ] && got=$((got+1)); done
                  if [ "$got" -eq "$want" ]; then ok "$n"; else bad "$n (want $want, got $got)"; fi; }

# Sandbox + trap at top level (never inside a $(...) function).
SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT

# new_case <name>: fresh $SNAP/$SNAP_COMMON; sets BK.
new_case() {
  C="$SB/$1"; BK="$C/common/db/backups"
  mkdir -p "$C/snap/opt/frigate/frigate" "$C/snap/usr/bin" "$BK"
  printf 'VERSION = "0.18.2-abc"\n' > "$C/snap/opt/frigate/frigate/version.py"
  # shellcheck disable=SC2016 # stub body must stay literal
  printf '#!/bin/sh\ncat >/dev/null; cp "$2" "$3"\n' > "$C/snap/usr/bin/python3.11"
  chmod +x "$C/snap/usr/bin/python3.11"
  echo dbdata > "$C/common/db/frigate.db"
}
mk() { touch -d "$2 days ago" "$BK/$1"; }   # mk <file> <age-days>
run_hook() {
  SNAP="$C/snap" SNAP_COMMON="$C/common" SNAP_REVISION=9 SNAP_VERSION=0.18.2 \
    "$SHELL_UNDER_TEST" "$REPO/snap/hooks/pre-refresh" >/dev/null 2>&1 || bad "hook exited non-zero"
}

echo "# shell under test: $SHELL_UNDER_TEST"
echo "# case 1: downgrade target retained"
new_case c1
mk frigate-pre-0.17.2-r5.db 3; mk frigate-pre-0.18.2-r7.db 2; mk frigate-pre-0.18.2-r8.db 1
run_hook
expect_file   "new backup written"                 "$BK/frigate-pre-0.18.2-r9.db"
expect_file   "2nd-newest kept"                    "$BK/frigate-pre-0.18.2-r8.db"
expect_file   "downgrade target kept (D21)"        "$BK/frigate-pre-0.17.2-r5.db"
expect_nofile "older same-version backup pruned"   "$BK/frigate-pre-0.18.2-r7.db"
expect_count  "at most 3 backups"                  3 "$BK"/frigate-pre-*.db

echo "# case 2: no older-version backup -> today's behaviour"
new_case c2
mk frigate-pre-0.18.2-r7.db 2; mk frigate-pre-0.18.2-r8.db 1
run_hook
expect_file   "r9 kept"                            "$BK/frigate-pre-0.18.2-r9.db"
expect_file   "r8 kept"                            "$BK/frigate-pre-0.18.2-r8.db"
expect_nofile "r7 pruned"                          "$BK/frigate-pre-0.18.2-r7.db"
expect_count  "exactly 2 backups"                  2 "$BK"/frigate-pre-*.db

echo "# case 3: newer-stamped, equal-stamped and legacy files are never the downgrade pick"
new_case c3
mk frigate-pre-5.db 4; mk frigate-pre-0.19.0-r4.db 3; mk frigate-pre-0.18.2-r7.db 2; mk frigate-pre-0.18.2-r8.db 1
run_hook
expect_file   "r9 kept"                            "$BK/frigate-pre-0.18.2-r9.db"
expect_file   "r8 kept"                            "$BK/frigate-pre-0.18.2-r8.db"
expect_nofile "newer-stamped (0.19.0) pruned"      "$BK/frigate-pre-0.19.0-r4.db"
expect_nofile "equal-stamped r7 pruned"            "$BK/frigate-pre-0.18.2-r7.db"
expect_nofile "legacy unstamped pruned"            "$BK/frigate-pre-5.db"
expect_count  "exactly 2 backups"                  2 "$BK"/frigate-pre-*.db

[ "$FAILS" -eq 0 ]
