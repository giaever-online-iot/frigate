#!/usr/bin/env bash
# remote-build.mutate.sh — mutation check for remote-build.test.sh (W-24). Each
# mutant breaks one decision of remote-build.sh; the suite must go red on every
# one. Not a *.test.sh: run by hand (and by reviewers), not in CI.
#   bash .github/scripts/remote-build.mutate.sh      # exit 0 iff every mutant is killed
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
M="$(mktemp -d)"; trap 'rm -rf "$M"' EXIT
bad=0
mutate() { # name, perl substitution applied to a copy of remote-build.sh
  cp "$HERE/remote-build.sh" "$M/rb.sh"
  perl -0pi -e "$2" "$M/rb.sh"
  if cmp -s "$HERE/remote-build.sh" "$M/rb.sh"; then echo "NOT APPLIED - $1"; bad=1; return; fi
  if RB="$M/rb.sh" bash "$HERE/remote-build.test.sh" > "$M/out" 2>&1; then
    echo "SURVIVED    - $1"; bad=1
  else
    echo "killed      - $1 ($(grep -c '^FAIL' "$M/out") checks red)"
  fi
}
mutate "M1 re-add --recover on retries"  's/--build-for="\$build_for" \\/--build-for="\$build_for" \$([ "\$attempt" -gt 1 ] && echo --recover) \\/'
mutate "M2 same build id (no marker)"    's/^.*> "\$MARK"; fi\n//m'
mutate "M3 rebuild all archs on retry"   's/build_for="\$rebuild"/build_for="\$ARCHS"/'
mutate "M4 drop prune_corrupt"           's/^    prune_corrupt$/    : prune_corrupt/m'
mutate "M5 unbounded attempts"           's/if \[ "\$attempt" -ge "\$MAX_ATTEMPTS" \]; then/if false; then/'
mutate "M6 rebuild failed builds too"    's/rebuild="\$\(rebuild_archs "\$LOG"\)"/rebuild="\$(missing_archs)"/'
mutate "M7 drop the budget guard"        's/if \[ \$\(\(used \+ RETRY_DELAY \+ took\)\) -gt "\$BUILD_BUDGET" \]; then/if false; then/'
mutate "M8 drop --launchpad-timeout"     's/ \\\n\s*--launchpad-timeout="\$left"//'
mutate "M9 keep a stale marker"          's/^rm -f "\$MARK"\n//m'
mutate "M10 snapcraft output in ./"      's/mktemp "\$\{TMPDIR:-\/tmp\}\/remote-build-out/mktemp ".\/remote-build-out/'
mutate "M11a drop the input validation"  's/^int_or_default BUILD_BUDGET 18000 1$/BUILD_BUDGET="\$\{BUILD_BUDGET:-18000\}"/m'
mutate "M11b start with < 1 s left"      's/if \[ "\$left" -lt 1 \]; then/if false; then/'
mutate "M12 tee -a (parse old attempts)" 's/\| tee "\$LOG"/| tee -a "\$LOG"/'
mutate "M13 first state line, not last"  's/tail -n1 \| tr -d/head -n1 | tr -d/'
mutate "M14 marker on attempt 1 too"     's/if \[ "\$attempt" -gt 1 \] && \[ -d \.git \]/if [ "\$attempt" -ge 1 ] \&\& [ -d .git ]/'
mutate "M15 drop 2>&1 (stderr unread)"  's/--launchpad-timeout="\$left" 2>&1 \| tee/--launchpad-timeout="\$left" | tee/'
mutate "M16 RETRY_DELAY not validated"   's/^int_or_default RETRY_DELAY 15 0$/RETRY_DELAY="\$\{RETRY_DELAY:-15\}"/m'
mutate "M17 exit 75 handled as any exit" 's/if \[ "\$rc" -eq 75 \]; then\n        rebuild=/if false; then\n        rebuild=/'
mutate "M18 after 75, rebuild Stopped too" 's/case "\$stopped" in \*",\$a,"\*\) ;; \*\) out\+=\("\$a"\) ;; esac/out+=("\$a")/'
mutate "M19 exit code not kept (|| true)" 's/\|\| rc="\$\{PIPESTATUS\[0\]\}"/|| true/'
mutate "M20 no exit-75 diagnostic"       's/^ *echo "::warning::attempt \$\{attempt\}: snapcraft exited 75.*\n//m'
mutate "M21 deadline boundary -le"       's/if \[ "\$took" -lt "\$left" \]/if [ "\$took" -le "\$left" ]/'
mutate "M22 after 75, rebuild valid archs" 's/        have_arch "\$a" && continue\n(        case "\$stopped")/\1/'
[ "$bad" -eq 0 ] && echo "All mutants killed." || echo "Some mutants SURVIVED or did not apply."
exit "$bad"
