#!/usr/bin/env bash
# arch-gate.sh — CI soft gate for the build/upload result (M7c D17).
# A missing REQUIRED arch fails the job; a missing experimental arch (arm64
# today) only warns. No snaps built at all always fails.
#
# Usage:  arch-gate.sh <required-csv> <built-count> <missing-space-list>
# Exit:   0 if every required arch was built and uploaded; otherwise 1.
# When $GITHUB_STEP_SUMMARY is set, each message is also appended there.
set -uo pipefail

required="${1:?usage: arch-gate.sh <required-csv> <built-count> <missing-space-list>}"
count="${2-}"
missing="${3-}"
rc=0

say() { # <annotation-line> <summary-text>
    printf '%s\n' "$1"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf -- '- %s\n' "$2" >> "$GITHUB_STEP_SUMMARY"; fi
}

if [ -z "$count" ] || [ "$count" = "0" ]; then
    say "::error::no snaps built" "no snaps built"
    rc=1
fi

IFS=',' read -ra req <<< "$required"
for arch in $missing; do
    is_req=0
    for r in "${req[@]}"; do [ "$r" = "$arch" ] && is_req=1; done
    if [ "$is_req" -eq 1 ]; then
        say "::error::required arch $arch missing" "required arch $arch missing"
        rc=1
    else
        say "::warning::$arch (experimental) build/upload missing: not gating" "$arch (experimental) build/upload missing: not gating"
    fi
done

exit "$rc"
