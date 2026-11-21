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
#   A6  no other upload-artifact `uses:` (any case) in ANY workflow file of the
#       directory; no local action (`uses: ./...`) in any workflow, since a local
#       composite action could wrap an upload; and no file under .github/actions
#       mentions upload-artifact (there is no .github/actions directory today)
#   A7  the path is the release step's own snaps (${SNAP_NAME}*.snap, SNAP_NAME frigate)
#   A8  lint-test.yml's path filters include pr-build-snap.yml, so a PR that
#       changes only that file still runs this test
#   A9  pr-build-snap runs on pull_request types opened, synchronize, reopened
#       only: with `labeled`, every label change would start a rebuild and a
#       Store release, and the docs say the workflow does not run on labeled
#
# Usage: artifact-step.test.sh [workflow.yml]   (default: ../workflows/pr-build-snap.yml)
# The other workflows are read from the directory of that file, and the actions
# from ../actions next to it, so a scratch copy of .github tests as a whole.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="${1:-$HERE/../workflows/pr-build-snap.yml}"
WFDIR="$(cd "$(dirname "$WF")" && pwd)"
ACTIONS="$WFDIR/../actions"
LINT="$WFDIR/lint-test.yml"
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
yf() { yq "$1" - <"$2"; }
y() { yf "$1" "$WF"; }
shopt -s nullglob
WFS=("$WFDIR"/*.yml "$WFDIR"/*.yaml)
# A file yq cannot parse must not turn into a vacuous red or green below.
for f in "${WFS[@]}"; do
  [ "$(yf '.jobs | type' "$f" 2>&1)" = "!!map" ] || { echo "FAIL - yq cannot parse $f as a workflow"; exit 1; }
done

# A6 first. Every `uses:` value in every workflow file (steps and jobs alike), lower-cased.
# explode(.) resolves YAML aliases and merge keys, so `uses: *ua` reads as the action it
# names. Only string values are kept: a map key `uses` under env: or with: holding a number
# or bool is not an action, and downcase would fail on it. A file yq still fails on gives a
# YQ-ERROR line, which fails the check below instead of silently dropping its uses.
all_uses="$(for f in "${WFS[@]}"; do
  yf 'explode(.) | .. | select(tag == "!!map") | select(has("uses")) | .uses | select(tag == "!!str") | downcase' "$f" \
    | sed "s|^|$(basename "$f"): |" || echo "$(basename "$f"): YQ-ERROR"
done)"
check "A6 yq read the uses of every workflow" "" "$(grep 'YQ-ERROR' <<<"$all_uses")"
check "A6 exactly one upload-artifact uses, in any case, across all workflows" \
  "$(basename "$WF"): actions/upload-artifact@v7" "$(grep 'upload-artifact' <<<"$all_uses")"
check "A6 no local action (uses: ./...) in any workflow" "" "$(grep -E '^[^:]+: \./' <<<"$all_uses")"
check "A6 no file under .github/actions mentions upload-artifact" "" \
  "$([ -d "$ACTIONS" ] && grep -rli 'upload-artifact' "$ACTIONS")"

idx_art="$(y "$JOB.steps | to_entries | map(select((.value.uses // \"\") | downcase | test(\"upload-artifact\"))) | .[0].key // \"none\"")"
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

# A8: every trigger of lint-test.yml that has a path filter lists pr-build-snap.yml.
if [ -f "$LINT" ]; then
  n_paths="$(yf '[.on[] | select(tag == "!!map") | select(has("paths"))] | length' "$LINT")"
  n_listed="$(yf '[.on[] | select(tag == "!!map") | select(has("paths")) | select(.paths | any_c(. == ".github/workflows/pr-build-snap.yml"))] | length' "$LINT")"
  check "A8 lint-test.yml has a path filter" "yes" "$([ "${n_paths:-0}" -ge 1 ] && echo yes || echo no)"
  check "A8 every lint-test path filter lists pr-build-snap.yml" "$n_paths" "$n_listed"
else
  check "A8 lint-test.yml exists next to the workflow" "yes" "no"
fi

check "A9 pull_request types are opened, reopened, synchronize (no labeled)" \
  "opened,reopened,synchronize" "$(y '.on.pull_request.types // [] | sort | join(",")')"

[ "$fail" -eq 0 ] && echo "All artifact-step tests passed." || echo "Some artifact-step tests FAILED."
exit "$fail"
