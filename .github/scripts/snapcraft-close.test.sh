#!/usr/bin/env bash
# Lint test for every `snapcraft close` call in .github/ (workflows and scripts).
# No network, no snapcraft needed: it reads the files as text.
#
# Why: snapcraft 9.2.1's `close` takes only -h/--help and -v/--verbose. The
# release-on-merge step used to pass --yes, which fails at argument parsing
# ("unrecognized arguments: --yes"); its `|| echo "...ignoring"` fallback hid
# the failure, so merged PR<N> branch channels stayed open until they expired.
#
# Rules, per `snapcraft close` call:
#   R1  every option token is one `snapcraft close --help` lists (-h -v --help --verbose)
#   R2  an `||` fallback that keeps going must print the real exit status ($?),
#       so a failed close stays visible in the job log
# Plus: at least one call is found (a moved or renamed step must not pass vacuously).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="$(cd "$HERE/.." && pwd)"
fail=0
check() { # desc expected actual
  if [ "$2" = "$3" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
    fail=1
  fi
}

ALLOWED_OPTS=" -h --help -v --verbose "

# lint_line LINE -> prints one violation per line ("R1 <opt>" / "R2"), nothing if clean.
lint_line() {
  local line="$1" call rest tok
  rest="${line#*snapcraft close}"
  # The call itself ends at the first shell list/pipe operator.
  call="${rest%%[|;&]*}"
  # shellcheck disable=SC2086  # word splitting is the point: one token per argument
  for tok in $call; do
    case "$tok" in
      -*) case "$ALLOWED_OPTS" in *" $tok "*) ;; *) echo "R1 $tok" ;; esac ;;
    esac
  done
  case "$rest" in
    *"||"*)
      # shellcheck disable=SC2016  # literal $? is what we look for
      case "${rest#*||}" in *'$?'*) ;; *) echo "R2" ;; esac ;;
  esac
}

# --- the detector itself, on fixture lines -----------------------------------
# shellcheck disable=SC2016  # fixtures are literal shell text
{
check "fixture: old --yes line -> R1 --yes and R2" \
  "R1 --yes|R2" \
  "$(lint_line 'snapcraft close "$SNAP" "$CHAN" --yes || echo "close failed (already gone?); ignoring"' | paste -sd'|')"
check "fixture: --yes without fallback -> R1 --yes" \
  "R1 --yes" "$(lint_line 'snapcraft close "$SNAP" "$CHAN" --yes')"
check "fixture: fallback without status -> R2" \
  "R2" "$(lint_line 'snapcraft close "$SNAP" "$CHAN" || echo "ignoring"')"
check "fixture: fixed line is clean" \
  "" "$(lint_line 'snapcraft close "$SNAP" "$CHAN" || echo "::warning::close failed (exit $?); ignoring"')"
check "fixture: --verbose is allowed" \
  "" "$(lint_line 'snapcraft close -v "$SNAP" beta')"
check "fixture: operator glued to the call still ends it" \
  "" "$(lint_line 'snapcraft close "$SNAP" beta|| echo "rc=$?"')"
}

# --- the real files ----------------------------------------------------------
found=0
violations=""
while IFS= read -r hit; do
  file="${hit%%:*}"; rest="${hit#*:}"; lineno="${rest%%:*}"; text="${rest#*:}"
  # Comments may mention the command; only calls count.
  case "$(printf '%s' "$text" | sed 's/^[[:space:]]*//')" in '#'*) continue ;; esac
  found=$((found+1))
  while IFS= read -r v; do
    [ -n "$v" ] && violations+="${file#"$GH"/}:$lineno: $v"$'\n'
  done < <(lint_line "$text")
done < <(grep -rn --include='*.yml' --include='*.yaml' --include='*.sh' \
           --exclude='*.test.sh' 'snapcraft close' "$GH")

[ "$found" -ge 1 ] && check "repo: at least one snapcraft close call found" "yes" "yes" \
                   || check "repo: at least one snapcraft close call found" "yes" "no ($found)"
check "repo: every snapcraft close call passes R1/R2" "" "${violations%$'\n'}"

[ "$fail" -eq 0 ] && echo "All snapcraft-close tests passed." || echo "Some snapcraft-close tests FAILED."
exit "$fail"
