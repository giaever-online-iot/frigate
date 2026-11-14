#!/usr/bin/env bash
# Fixture-driven unit tests for snap-release.sh. No network.
set -uo pipefail  # no -e: keep all tests running even if earlier ones fail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SR="$HERE/snap-release.sh"
INFO="$HERE/fixtures/snap-info.txt"
fail=0

check() { # desc expected actual
  if [ "$2" = "$3" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
    fail=1
  fi
}

check "version-to-track v-prefixed" "v11.19" "$("$SR" version-to-track v11.19.1)"
check "version-to-track bare"       "v11.19" "$("$SR" version-to-track 11.19.1)"
check "version-to-track x.0"        "v12.0"  "$("$SR" version-to-track v12.0.0)"
check "version-to-track empty"      ""       "$("$SR" version-to-track "")"

check "major v-prefixed" "12" "$("$SR" major v12.0.0)"
check "major bare"       "11" "$("$SR" major 11.19.1)"
check "major empty"      ""   "$("$SR" major "")"

check "channel-version candidate" "v11.19.1" "$("$SR" channel-version latest/candidate <"$INFO")"
check "channel-version stable"    "v11.14.0" "$("$SR" channel-version latest/stable <"$INFO")"
check "channel-version caret"     ""         "$("$SR" channel-version latest/beta <"$INFO")"
check "channel-version branch"    "v11.19.2" "$("$SR" channel-version v11.19/edge/42 <"$INFO")"
check "channel-version absent"    ""         "$("$SR" channel-version v99.9/stable <"$INFO")"

check "branch-has-revisions yes" "yes" "$("$SR" branch-has-revisions v11.19 42 <"$INFO")"
check "branch-has-revisions no"  "no"  "$("$SR" branch-has-revisions v11.19 99 <"$INFO")"

check "needs-stable-bump major"      "yes" "$("$SR" needs-stable-bump v12.0.0 v11.20.3)"
check "needs-stable-bump minor"      "no"  "$("$SR" needs-stable-bump v11.20.0 v11.19.1)"
check "needs-stable-bump empty-cand" "no"  "$("$SR" needs-stable-bump v11.19.1 "")"
check "needs-stable-bump empty-new"  "no"  "$("$SR" needs-stable-bump "" v11.19.1)"

check "is-at-least equal"        "yes" "$("$SR" is-at-least v11.19.1 v11.19.1)"
check "is-at-least greater"      "yes" "$("$SR" is-at-least v11.20.0 v11.19.9)"
check "is-at-least lesser"       "no"  "$("$SR" is-at-least v11.5.0 v11.19.0)"
check "is-at-least empty-floor"  "yes" "$("$SR" is-at-least v11.0.0 "")"
check "is-at-least minor-numeric" "yes" "$("$SR" is-at-least v11.20.0 v11.9.0)"

FX="$HERE/fixtures/snapcraft-revisions.txt"
check "current PR9 arm64 -> 14 (13 is historic)"  "14" "$("$SR" revisions-in latest/edge/PR9 arm64 < "$FX" | tr '\n' ' ' | sed 's/ $//')"
check "current PR9 amd64 -> 12"                   "12" "$("$SR" revisions-in latest/edge/PR9 amd64 < "$FX" | tr '\n' ' ' | sed 's/ $//')"
check "current edge amd64 -> 6 (7 rolled back)"   "6"  "$("$SR" revisions-in latest/edge amd64 < "$FX" | tr '\n' ' ' | sed 's/ $//')"
check "current beta amd64 -> 6"                   "6"  "$("$SR" revisions-in latest/beta amd64 < "$FX")"
check "edge arm64 -> none"                        ""   "$("$SR" revisions-in latest/edge arm64 < "$FX")"
check "arch-of 14 -> arm64"                       "arm64" "$("$SR" arch-of 14 < "$FX")"
check "arch-of 7 -> amd64"                        "amd64" "$("$SR" arch-of 7 < "$FX")"
"$SR" arch-of 99 < "$FX" >/dev/null 2>&1;         check "arch-of unknown -> exit 1" "1" "$?"
check "in-list amd64 amd64"                       "yes" "$("$SR" in-list amd64 amd64)"
check "in-list arm64 amd64"                       "no"  "$("$SR" in-list arm64 amd64)"
check "in-list arm64 amd64,arm64"                 "yes" "$("$SR" in-list arm64 amd64,arm64)"
check "in-list arm amd64,arm64"                   "no"  "$("$SR" in-list arm amd64,arm64)"

# Live capture (T13 Step 4): `snapcraft revisions frigate` after the M9 merge (Store rev 7).
# Real format: comma lists WITHOUT spaces, and every channel carries historic (unstarred) entries.
LX="$HERE/fixtures/snapcraft-revisions.live.txt"
check "live: current edge amd64 -> 7 (1,2,3,5,6 historic)" "7" "$("$SR" revisions-in latest/edge amd64 < "$LX" | tr '\n' ' ' | sed 's/ $//')"
check "live: current PR8 amd64 -> 7"                 "7" "$("$SR" revisions-in latest/edge/PR8 amd64 < "$LX" | tr '\n' ' ' | sed 's/ $//')"
check "live: current PR4 amd64 -> 5 (4 historic)"    "5" "$("$SR" revisions-in latest/edge/PR4 amd64 < "$LX" | tr '\n' ' ' | sed 's/ $//')"
check "live: current beta amd64 -> 3"                "3" "$("$SR" revisions-in latest/beta amd64 < "$LX" | tr '\n' ' ' | sed 's/ $//')"
check "live: edge arm64 -> none"                     ""  "$("$SR" revisions-in latest/edge arm64 < "$LX")"
check "live: arch-of 7 -> amd64"                     "amd64" "$("$SR" arch-of 7 < "$LX")"
"$SR" arch-of 8 < "$LX" >/dev/null 2>&1;             check "live: arch-of 8 (not uploaded) -> exit 1" "1" "$?"

exit "$fail"
