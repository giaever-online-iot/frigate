#!/usr/bin/env bash
# Static test of the opt-in snap artifact step in pr-build-snap.yml (W-23).
# No network, no snapcraft: it parses the workflow with yq.
#
# Why: the repo is public and a GitHub build artifact of a public repo can be
# downloaded by any logged-in GitHub user, while the snap's Store listing is
# private. So the built snaps may only become an artifact when a PR carries the
# label `snap-artifact`, for one day, and no other step may upload them.
#
# Rules:
#   A1  exactly one step uses actions/upload-artifact, at the repo's major tag,
#       after the step `release` and before "Sticky PR comment"
#   A2  its `if` is exactly the AND of: the build-output guard, the pull_request
#       event, and the label gate (no `||`, no other clause such as always())
#   A3  retention-days is 1
#   A4  continue-on-error is true
#   A5  if-no-files-found is error
#   A6  no other upload-artifact step anywhere in the file
#   A7  the path is the release step's own snaps (${SNAP_NAME}*.snap, SNAP_NAME frigate)
#
# Usage: artifact-step.test.sh [workflow.yml]   (default: ../workflows/pr-build-snap.yml)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="${1:-$HERE/../workflows/pr-build-snap.yml}"
JOB='.jobs["build-and-release"]'
fail=0
check() { # desc expected actual
  if [ "$2" = "$3" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
    fail=1
  fi
}

command -v yq >/dev/null 2>&1 || { echo "FAIL - yq is not on PATH"; exit 1; }
[ -f "$WF" ] || { echo "FAIL - no workflow file at $WF"; exit 1; }
# On stdin: a strictly confined yq (the snap) cannot open files under /tmp.
y() { yq "$1" - <"$WF"; }
# A file yq cannot parse must not turn into a vacuous red or green below.
[ "$(y '.jobs | type' 2>&1)" = "!!map" ] || { echo "FAIL - yq cannot parse $WF as a workflow"; exit 1; }

# A6 first: every step of every job, so a second step in another job counts too.
n_upload="$(y '[.jobs[].steps[] | select((.uses // "") | test("^actions/upload-artifact@"))] | length')"
check "A6 exactly one upload-artifact step in the file" "1" "$n_upload"

idx_art="$(y "$JOB.steps | to_entries | map(select((.value.uses // \"\") | test(\"^actions/upload-artifact@\"))) | .[0].key // \"none\"")"
idx_rel="$(y "$JOB.steps | to_entries | map(select(.value.id == \"release\")) | .[0].key // \"none\"")"
idx_sticky="$(y "$JOB.steps | to_entries | map(select(.value.name == \"Sticky PR comment\")) | .[0].key // \"none\"")"
check "A1 the release step exists" "yes" "$([ "$idx_rel" != none ] && echo yes || echo no)"
check "A1 the sticky-comment step exists" "yes" "$([ "$idx_sticky" != none ] && echo yes || echo no)"
check "A1 the artifact step exists in build-and-release" "yes" "$([ "$idx_art" != none ] && echo yes || echo no)"
if [ "$idx_art" = none ] || [ "$idx_rel" = none ] || [ "$idx_sticky" = none ]; then
  echo "Some artifact-step tests FAILED."
  exit 1
fi
S="$JOB.steps[$idx_art]"

check "A1 uses actions/upload-artifact@v7" "actions/upload-artifact@v7" "$(y "$S.uses")"
check "A1 after the release step" "yes" "$([ "$idx_art" -gt "$idx_rel" ] && echo yes || echo no)"
check "A1 before the sticky comment" "yes" "$([ "$idx_art" -lt "$idx_sticky" ] && echo yes || echo no)"

# A2: strip ${{ }}, split on &&, trim, sort; the clause set must be exactly these three.
cond="$(y "$S.if // \"\"")"
check "A2 the if has no ||" "0" "$(grep -c '||' <<<"$cond")"
clauses="$(sed -e 's/^[[:space:]]*\${{//' -e 's/}}[[:space:]]*$//' <<<"$cond" \
  | awk -v RS='&&' '{ gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 != "") print }' | LC_ALL=C sort)"
want="$(printf '%s\n' \
  "steps.build.outputs.snaps != '0'" \
  "github.event_name == 'pull_request'" \
  "contains(github.event.pull_request.labels.*.name, 'snap-artifact')" | LC_ALL=C sort)"
check "A2 the if is build guard && pull_request && label snap-artifact" "$want" "$clauses"

check "A3 retention-days is 1" "1" "$(y "$S.with[\"retention-days\"] // \"unset\"")"
check "A4 continue-on-error is true" "true" "$(y "${S}[\"continue-on-error\"] // \"unset\"")"
check "A5 if-no-files-found is error" "error" "$(y "$S.with[\"if-no-files-found\"] // \"unset\"")"
# shellcheck disable=SC2016  # the ${{ }} expression is literal YAML text, not a shell expansion
check "A7 path is the built snaps" '${{ env.SNAP_NAME }}*.snap' "$(y "$S.with.path // \"unset\"")"
check "A7 SNAP_NAME is frigate" "frigate" "$(y '.env.SNAP_NAME // "unset"')"

[ "$fail" -eq 0 ] && echo "All artifact-step tests passed." || echo "Some artifact-step tests FAILED."
exit "$fail"
