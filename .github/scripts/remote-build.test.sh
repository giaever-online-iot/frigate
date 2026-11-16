#!/usr/bin/env bash
# Stub-driven unit tests for remote-build.sh. No network: fake `snapcraft`,
# `unsquashfs` and `date` on PATH.
#
# The snapcraft stub models what snapcraft 9.2.1 does (W-24 spec §3, D10):
# - the build id is craft_application's _compute_hash: md5 over the
#   concatenated md5 hex digests of every file in the project dir, sorted by
#   path, .git included; file names do not enter it, only contents (tree_id below);
# - `--recover` fails with the text CI got on PR 10 ("Could not find repository
#   at path ~<owner>/+git/snapcraft-frigate-<id>"), because snapcraft looks the
#   repository up without the project it created it under;
# - before fetching, it prints build-state lines on STDERR, where snapcraft's
#   emit.progress puts them in verbose mode (craft_cli messages.py:645-648), the last
#   one listing every arch that built ("Building: amd64; Succeeded: arm64", then
#   "Succeeded: amd64, arm64"); a genuine build failure shows as "Stopped: amd64";
# - `--launchpad-timeout=<s>`: an attempt that would take longer prints one last
#   state line (stderr), "Timed out waiting for build." (stdout: emit.message,
#   messages.py:553), fetches nothing and exits 75;
# - an early exit 75: a Launchpad call that times out while snapcraft monitors the
#   build ends the attempt the same way (craft_application commands/remote.py catches every TimeoutError),
#   long before the deadline, after its last state line and with nothing fetched;
# - a file in the project dir that is neither the tracked snapcraft.yaml nor an
#   ignored frigate_*.snap would be auto-committed and pushed: the stub records it
#   in $work/stray and fails.
# Every call appends "n|id|build-for|recover|launchpad-timeout" to $work/calls.
# `date +%s` reads a fake clock; each snapcraft call advances it by STUB_COST
# seconds (default 60), and each `date +%s` by STUB_DATE_TICK (default 0).
# `sleep` records its argument in $work/sleeps and returns at once.
set -uo pipefail  # no -e: keep all tests running even if one fails

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RB="${RB:-$HERE/remote-build.sh}"   # RB=<mutant> runs the suite against a mutated copy
fail=0
check() { # desc expected actual
  if [ "$2" = "$3" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
    fail=1
  fi
}

# snapcraft's build id hash of directory $1 (the stub computes the same in its cwd)
tree_id() { (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r md5sum | awk '{printf "%s", $1}' | md5sum | cut -c1-32); }

# Build a throwaway workspace; $1 = mode -> echoes workdir.
# mode=cut:         PR 10's case. Launchpad builds every requested arch. On call 1 the
#                   download of the FIRST requested arch is cut (truncated file, exit 1),
#                   the others arrive whole; later calls fetch everything whole.
# mode=alwayscut:   like cut, but the first requested arch's download is cut on EVERY call.
# mode=cutthenfail: call 1 as cut; every later call fails before any state line.
# mode=authfail:    snapcraft fails before any build starts (no state line, no file).
# mode=buildfail:   amd64 fails to BUILD on Launchpad (Stopped); the others build and
#                   arrive whole; snapcraft exits 0 (_monitor_and_complete returns 0).
# mode=early75:     call 1 ends as PR 10's second run did: state lines (Pending, then
#                   Building), "Timed out waiting for build." and exit 75 after STUB_COST
#                   seconds, before the deadline, nothing fetched; later calls build and
#                   fetch everything whole.
# mode=early75stopped: as early75, but call 1's last state line reports the FIRST
#                   requested arch Stopped (a build failure) and the others Building.
# mode=alwaysearly75: every call ends as early75's call 1 does.
# mode=cutthen75:   call 1 as cut (the first requested arch cut, the others whole); call 2
#                   ends as early75's call 1 does; later calls fetch everything whole.
# Layout: $work/bin (stubs), $work/calls + $work/n + $work/clock (+ stray, sleeps) (stub
# state), $work/proj (the project dir: one tracked file and a .git dir, as a checkout has).
setup() {
  local mode="$1" work bin
  work="$(mktemp -d)"; bin="$work/bin"; mkdir -p "$bin" "$work/proj/.git"
  echo 'name: frigate' > "$work/proj/snapcraft.yaml"
  echo 'ref: refs/heads/main' > "$work/proj/.git/HEAD"
  echo 1000000 > "$work/clock"
  cat > "$bin/unsquashfs" <<'EOF'
#!/usr/bin/env bash
# stub: `unsquashfs -l <file>` succeeds unless the file is marked CORRUPT
f=""; for f; do :; done
grep -q CORRUPT "$f" 2>/dev/null && exit 1
exit 0
EOF
  cat > "$bin/date" <<EOF
#!/usr/bin/env bash
# stub: \`date +%s\` reads the fake clock (then ticks it); anything else is the real date
if [ "\${1:-}" = "+%s" ]; then
  c="\$(cat "$work/clock")"; echo "\$c"; echo \$(( c + \${STUB_DATE_TICK:-0} )) > "$work/clock"
else exec /bin/date "\$@"; fi
EOF
  cat > "$bin/sleep" <<EOF
#!/usr/bin/env bash
# stub: record the delay, do not wait
echo "\$*" >> "$work/sleeps"
EOF
  cat > "$bin/snapcraft" <<EOF
#!/usr/bin/env bash
n=0; [ -f "$work/n" ] && n="\$(cat "$work/n")"; n=\$((n+1)); echo "\$n" > "$work/n"
[ "\$n" -gt 10 ] && { echo "stub: runaway, call \$n" >&2; exit 1; }
recover=0; bf=""; to=""
for a in "\$@"; do
  case "\$a" in
    --recover) recover=1 ;;
    --build-for=*) bf="\${a#--build-for=}" ;;
    --launchpad-timeout=*) to="\${a#--launchpad-timeout=}" ;;
  esac
done
id="\$(find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r md5sum | awk '{printf "%s", \$1}' | md5sum | cut -c1-32)"
echo "\$n|\$id|\$bf|\$recover|\$to" >> "$work/calls"
stray="\$(find . -path ./.git -prune -o -type f ! -name snapcraft.yaml ! -name 'frigate_*.snap' -print)"
if [ -n "\$stray" ]; then
  echo "call \$n: \$stray" >> "$work/stray"
  echo "stub: these files would be committed and pushed: \$stray" >&2; exit 1
fi
cost="\${STUB_COST:-60}"
if [ "\$recover" -eq 1 ]; then
  echo "Recovering build snapcraft-frigate-\$id"
  echo "Could not find repository at path ~owner/+git/snapcraft-frigate-\$id" >&2; exit 1
fi
if [ "$mode" = authfail ] || { [ "$mode" = cutthenfail ] && [ "\$n" -gt 1 ]; }; then
  echo "Craft error: authorization failed" >&2; exit 1
fi
IFS=',' read -ra req <<< "\$bf"
first="\${req[0]}"
if [ -n "\$to" ] && [ "\$to" -gt 0 ] && [ "\$cost" -gt "\$to" ]; then
  echo \$(( \$(cat "$work/clock") + to )) > "$work/clock"
  echo "Succeeded: \$first" >&2
  echo "Timed out waiting for build."
  echo "To resume, run 'snapcraft remote-build --recover'"
  exit 75
fi
early=0
case "$mode" in
  early75|early75stopped) [ "\$n" -eq 1 ] && early=1 ;;
  alwaysearly75) early=1 ;;
  cutthen75) [ "\$n" -eq 2 ] && early=1 ;;
esac
if [ "\$early" -eq 1 ]; then
  echo \$(( \$(cat "$work/clock") + cost )) > "$work/clock"
  echo "Pending: \$(echo "\$bf" | sed 's/,/, /g')" >&2
  rest="\$(IFS=,; echo "\${req[*]:1}" | sed 's/,/, /g')"
  if [ "$mode" = early75stopped ]; then
    echo "Stopped: \$first\${rest:+; Building: \$rest}" >&2
  else
    echo "Building: \$(echo "\$bf" | sed 's/,/, /g')" >&2
  fi
  echo "Timed out waiting for build."
  echo "To resume, run 'snapcraft remote-build --recover'"
  exit 75
fi
echo \$(( \$(cat "$work/clock") + cost )) > "$work/clock"
if [ "$mode" = buildfail ]; then
  ok=(); for a in "\${req[@]}"; do [ "\$a" = amd64 ] || ok+=("\$a"); done
  echo "Stopped: amd64; Succeeded: \$(IFS=,; echo "\${ok[*]}" | sed 's/,/, /g')" >&2
  for a in "\${ok[@]}"; do printf 'OK' > "frigate_0.18.2_\${a}.snap"; done
  exit 0
fi
if [ "\${#req[@]}" -gt 1 ]; then
  echo "Building: \$first; Succeeded: \$(IFS=,; echo "\${req[*]:1}" | sed 's/,/, /g')" >&2
fi
echo "Succeeded: \$(echo "\$bf" | sed 's/,/, /g')" >&2
echo "Fetching build artifacts..." >&2
for a in "\${req[@]}"; do printf 'OK' > "frigate_0.18.2_\${a}.snap"; done
if [ "$mode" = alwayscut ] || [ "\$n" -eq 1 ]; then
  printf 'CORRUPT' > "frigate_0.18.2_\${first}.snap"
  echo "snapcraft internal error: ChunkedEncodingError(ProtocolError('Connection broken: IncompleteRead(578594 bytes read, 1109240798 more expected)'))" >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$bin/unsquashfs" "$bin/date" "$bin/sleep" "$bin/snapcraft"
  echo "$work"
}

run() { # $1 = work, $2 = archs, then env assignments -> stdout+stderr of the script
  local work="$1" archs="$2"; shift 2
  ( cd "$work/proj" && env PATH="$work/bin:$PATH" MAX_ATTEMPTS=3 RETRY_DELAY=0 TMPDIR="$work" "$@" timeout 120 bash "$RB" "$archs" ) 2>&1
}
snaps_line() { printf '%s\n' "$1" | grep -oE 'snaps=[0-9]+' | tail -1; }
calls()      { [ -f "$1/calls" ] && wc -l < "$1/calls" | tr -d ' ' || echo 0; }
field()      { sed -n "${2}p" "$1/calls" | cut -d'|' -f"$3"; }   # work, call n, field
on_disk()    { (cd "$1/proj" && ls -1 ./*.snap 2>/dev/null | sed 's|^\./||' | tr '\n' ' ' | sed 's/ $//'); }
corrupt()    { grep -l CORRUPT "$1"/proj/*.snap 2>/dev/null | wc -l | tr -d ' '; }
strays()     { [ -f "$1/stray" ] && wc -l < "$1/stray" | tr -d ' ' || echo 0; }
warned()     { printf '%s\n' "$1" | grep -c -- "^::warning::$2"; }       # output, warning prefix
min_timeout() { cut -d'|' -f5 "$1/calls" | sort -n | head -1; }

# --- PR 10's case: amd64 download cut, arm64 whole -> one NEW build of amd64 only ---
work="$(setup cut)"
clean_id="$(tree_id "$work/proj")"
out="$(run "$work" amd64,arm64 STUB_COST=1726 BUILD_BUDGET=18000)"
check "cut: reports 2 valid snaps"              "snaps=2" "$(snaps_line "$out")"
check "cut: 2 snapcraft calls"                  "2"       "$(calls "$work")"
check "cut: no call uses --recover"             "0 0"     "$(field "$work" 1 4) $(field "$work" 2 4)"
check "cut: call 1 builds both archs"           "amd64,arm64" "$(field "$work" 1 3)"
check "cut: call 1 id is the clean tree's (no marker)" "$clean_id" "$(field "$work" 1 2)"
check "cut: call 2 rebuilds only amd64"         "amd64"   "$(field "$work" 2 3)"
check "cut: call 2 has a new build id"          "differ"  "$( [ "$(field "$work" 1 2)" != "$(field "$work" 2 2)" ] && echo differ || echo same )"
check "cut: both snaps on disk"                 "frigate_0.18.2_amd64.snap frigate_0.18.2_arm64.snap" "$(on_disk "$work")"
check "cut: no corrupt file remains"            "0"       "$(corrupt "$work")"
check "cut: call 1 timeout is the whole budget" "18000"   "$(field "$work" 1 5)"
check "cut: call 2 timeout is what is left"     "16274"   "$(field "$work" 2 5)"
check "cut: no stray file in the project dir at any call" "0" "$(strays "$work")"
check "cut: attempt marker removed at exit"     "absent"  "$( [ -e "$work/proj/.git/remote-build-attempt" ] && echo present || echo absent )"
check "cut: no temp files left behind"          "0"       "$(find "$work" -maxdepth 1 -name 'remote-build-*' | wc -l | tr -d ' ')"
rm -rf "$work"

# --- one arch, its download cut: nothing valid is fetched, so the tree is as it was
#     and only the attempt marker can give call 2 a new build id ---
work="$(setup cut)"
out="$(run "$work" amd64)"
check "single cut: reports 1 valid snap"        "snaps=1" "$(snaps_line "$out")"
check "single cut: 2 snapcraft calls"           "2"       "$(calls "$work")"
check "single cut: call 2 has a new build id"   "differ"  "$( [ "$(field "$work" 1 2)" != "$(field "$work" 2 2)" ] && echo differ || echo same )"
rm -rf "$work"

# --- the cut repeats: bounded at MAX_ATTEMPTS, each attempt a new id, exit 0 ---
work="$(setup alwayscut)"
out="$(run "$work" amd64,arm64)"
rc=$?
check "alwayscut: exactly 3 snapcraft calls"    "3"       "$(calls "$work")"
check "alwayscut: reports 1 valid snap"         "snaps=1" "$(snaps_line "$out")"
check "alwayscut: exit 0 (tolerant)"            "0"       "$rc"
check "alwayscut: 3 distinct build ids"         "3"       "$(cut -d'|' -f2 "$work/calls" | sort -u | wc -l | tr -d ' ')"
check "alwayscut: retries rebuild only amd64"   "amd64 amd64" "$(field "$work" 2 3) $(field "$work" 3 3)"
check "alwayscut: only the valid arm64 kept"    "frigate_0.18.2_arm64.snap" "$(on_disk "$work")"
check "alwayscut: no stray file at any call"    "0"       "$(strays "$work")"
rm -rf "$work"

# --- a retry that fails before printing any state: attempt 1's "Succeeded" line must
#     not be read again (the output is parsed per attempt) ---
work="$(setup cutthenfail)"
out="$(run "$work" amd64,arm64)"
check "cutthenfail: exactly 2 snapcraft calls"  "2"       "$(calls "$work")"
check "cutthenfail: keeps the valid arm64"      "snaps=1" "$(snaps_line "$out")"
check "cutthenfail: says attempt 2 built nothing" "1"     "$(warned "$out" 'not rebuilding amd64: Launchpad did not report it Succeeded in attempt 2')"
rm -rf "$work"

# --- a genuine BUILD failure is not rebuilt: keep what built, one call, exit 0 ---
work="$(setup buildfail)"
out="$(run "$work" amd64,arm64,armhf)"
rc=$?
check "buildfail: 1 snapcraft call"             "1"       "$(calls "$work")"
check "buildfail: reports 2 valid snaps"        "snaps=2" "$(snaps_line "$out")"
check "buildfail: exit 0 (tolerant)"            "0"       "$rc"
check "buildfail: says why it does not rebuild" "1"       "$(warned "$out" 'not rebuilding amd64: Launchpad did not report it Succeeded')"
rm -rf "$work"

# --- snapcraft fails before building (auth, network): one call, nothing to rebuild ---
work="$(setup authfail)"
out="$(run "$work" amd64,arm64)"
check "authfail: 1 snapcraft call"              "1"       "$(calls "$work")"
check "authfail: reports 0 valid snaps"         "snaps=0" "$(snaps_line "$out")"
check "authfail: says why it does not rebuild"  "1"       "$(warned "$out" 'not rebuilding amd64,arm64: Launchpad did not report it Succeeded')"
rm -rf "$work"

# --- PR 9's timing: an attempt of 15022 s leaves no room for a second in 18000 s ---
work="$(setup cut)"
out="$(run "$work" amd64,arm64 STUB_COST=15022 BUILD_BUDGET=18000)"
check "budget: 1 snapcraft call"                "1"       "$(calls "$work")"
check "budget: keeps the valid arm64"           "snaps=1" "$(snaps_line "$out")"
check "budget: says why it does not rebuild"    "1"       "$(warned "$out" 'not rebuilding amd64: attempt 1 took 15022s')"
rm -rf "$work"

# --- the timeout is hit: snapcraft prints one more "Succeeded: amd64", fetches nothing,
#     exits 75; the budget is used up, so nothing is rebuilt ---
work="$(setup cut)"
out="$(run "$work" amd64,arm64 STUB_COST=20000 BUILD_BUDGET=18000)"
check "timeout: 1 snapcraft call"               "1"       "$(calls "$work")"
check "timeout: call 1 got the whole budget"    "18000"   "$(field "$work" 1 5)"
check "timeout: nothing fetched"                "snaps=0" "$(snaps_line "$out")"
check "timeout: says why it does not rebuild"   "1"       "$(warned "$out" 'not rebuilding amd64,arm64: attempt 1 took 18000s')"
check "timeout: says it was the deadline"       "1"       "$(warned "$out" 'attempt 1: snapcraft exited 75 after 18000s of its 18000s --launchpad-timeout: the deadline, or a timeout too close to it to tell')"
rm -rf "$work"

# --- PR 10's second run: snapcraft exits 75 ("Timed out waiting for build.") 869 s into
#     the attempt (782 s after it set its 18000 s timeout), both archs still Building,
#     nothing fetched. Not the deadline, so a NEW build of every missing arch, with a new
#     build id ---
work="$(setup early75)"
out="$(run "$work" amd64,arm64 STUB_COST=869 BUILD_BUDGET=18000)"
check "early75: 2 snapcraft calls"              "2"       "$(calls "$work")"
check "early75: call 2 rebuilds every missing arch" "amd64,arm64" "$(field "$work" 2 3)"
check "early75: call 2 has a new build id"      "differ"  "$( [ "$(calls "$work")" -ge 2 ] && [ "$(field "$work" 1 2)" != "$(field "$work" 2 2)" ] && echo differ || echo same )"
check "early75: call 2 timeout is what is left" "17131"   "$(field "$work" 2 5)"
check "early75: reports 2 valid snaps"          "snaps=2" "$(snaps_line "$out")"
check "early75: says it was not the deadline"   "1"       "$(warned "$out" 'attempt 1: snapcraft exited 75 after 869s of its 18000s --launchpad-timeout: a Launchpad call timed out, not the deadline')"
rm -rf "$work"

# --- an early exit 75 with the first arch already Stopped (a build failure): only the
#     other arch is rebuilt ---
work="$(setup early75stopped)"
out="$(run "$work" amd64,arm64 STUB_COST=869)"
check "early75stopped: 2 snapcraft calls"       "2"       "$(calls "$work")"
check "early75stopped: call 2 rebuilds only arm64" "arm64" "$(field "$work" 2 3)"
check "early75stopped: reports 1 valid snap"    "snaps=1" "$(snaps_line "$out")"
rm -rf "$work"

# --- the only arch Stopped, then exit 75: nothing to rebuild ---
work="$(setup early75stopped)"
out="$(run "$work" amd64 STUB_COST=869)"
check "early75 all stopped: 1 snapcraft call"   "1"       "$(calls "$work")"
check "early75 all stopped: says it was Stopped" "1"      "$(warned "$out" 'not rebuilding amd64: Launchpad reported it Stopped in attempt 1')"
rm -rf "$work"

# --- an early exit 75 on every attempt: bounded at MAX_ATTEMPTS, each a new id, exit 0 ---
work="$(setup alwaysearly75)"
out="$(run "$work" amd64,arm64 STUB_COST=869)"
rc=$?
check "alwaysearly75: exactly 3 snapcraft calls" "3"      "$(calls "$work")"
check "alwaysearly75: 3 distinct build ids"     "3"       "$(cut -d'|' -f2 "$work/calls" | sort -u | wc -l | tr -d ' ')"
check "alwaysearly75: snaps=0, exit 0"          "snaps=0 0" "$(snaps_line "$out") $rc"
check "alwaysearly75: says what is still missing" "1"     "$(warned "$out" 'still missing amd64,arm64 after 3 attempts')"
rm -rf "$work"

# --- a cut download (arm64 arrives whole), then an early exit 75: the next build is of
#     amd64 only; the valid arm64 is neither rebuilt nor fetched again (D2) ---
work="$(setup cutthen75)"
out="$(run "$work" amd64,arm64 STUB_COST=869)"
check "cutthen75: 3 snapcraft calls"            "3"       "$(calls "$work")"
check "cutthen75: call 2 rebuilds only amd64"   "amd64"   "$(field "$work" 2 3)"
check "cutthen75: call 3 rebuilds only amd64"   "amd64"   "$(field "$work" 3 3)"
check "cutthen75: reports 2 valid snaps"        "snaps=2" "$(snaps_line "$out")"
rm -rf "$work"

# --- an early exit 75 that took too long to fit a second attempt in the budget ---
work="$(setup early75)"
out="$(run "$work" amd64,arm64 STUB_COST=10000 BUILD_BUDGET=18000)"
check "early75 late: 1 snapcraft call"          "1"       "$(calls "$work")"
check "early75 late: says why it does not rebuild" "1"    "$(warned "$out" 'not rebuilding amd64,arm64: attempt 1 took 10000s')"
rm -rf "$work"

# --- the budget runs out between attempts (every clock read costs 1 s here): never
#     start an attempt with less than 1 s, which snapcraft would read as no timeout ---
work="$(setup cut)"
out="$(run "$work" amd64,arm64 STUB_COST=0 STUB_DATE_TICK=1 BUILD_BUDGET=4)"
check "no budget left: 1 snapcraft call"        "1"       "$(calls "$work")"
check "no budget left: no timeout below 1"      "yes"     "$( [ "$(min_timeout "$work")" -ge 1 ] 2>/dev/null && echo yes || echo "no ($(min_timeout "$work"))" )"
check "no budget left: says so"                 "1"       "$(warned "$out" 'not starting attempt 2: the 4s budget is used up')"
rm -rf "$work"

# --- input guard: values that are not integers in range get a warning and the default ---
for bad in 0 -100 5h; do
  work="$(setup cut)"
  out="$(run "$work" amd64,arm64 BUILD_BUDGET="$bad")"
  check "BUILD_BUDGET=$bad: warns"               "1"       "$(warned "$out" "BUILD_BUDGET='$bad' is not an integer >= 1; using 18000")"
  check "BUILD_BUDGET=$bad: call 1 gets 18000"   "18000"   "$(field "$work" 1 5)"
  check "BUILD_BUDGET=$bad: still completes"     "snaps=2" "$(snaps_line "$out")"
  rm -rf "$work"
done
work="$(setup cut)"
out="$(run "$work" amd64,arm64 RETRY_DELAY=x)"
rc=$?
check "RETRY_DELAY=x: warns"                    "1"       "$(warned "$out" "RETRY_DELAY='x' is not an integer >= 0; using 15")"
check "RETRY_DELAY=x: waits the default 15 s"   "15"      "$(cat "$work/sleeps" 2>/dev/null)"
check "RETRY_DELAY=x: completes, exit 0"        "snaps=2 0" "$(snaps_line "$out") $rc"
rm -rf "$work"
work="$(setup alwayscut)"
out="$(run "$work" amd64,arm64 MAX_ATTEMPTS=x)"
check "MAX_ATTEMPTS=x: warns and uses 3"        "1 3"     "$(warned "$out" "MAX_ATTEMPTS='x' is not an integer >= 1; using 3") $(calls "$work")"
rm -rf "$work"

# --- a marker left by an earlier run is removed before attempt 1, so attempt 1's id is
#     the plain tree's id ---
work="$(setup cut)"
clean_id="$(tree_id "$work/proj")"
echo 2 > "$work/proj/.git/remote-build-attempt"
run "$work" amd64 >/dev/null
check "stale marker: attempt 1 id is the clean tree's" "$clean_id" "$(field "$work" 1 2)"
rm -rf "$work"

# --- GITHUB_OUTPUT receives the count ---
work="$(setup cut)"; gho="$work/gho"
run "$work" amd64,arm64 GITHUB_OUTPUT="$gho" >/dev/null
check "writes snaps= to GITHUB_OUTPUT"          "snaps=2" "$(grep -oE 'snaps=[0-9]+' "$gho" | tail -1)"
rm -rf "$work"

[ "$fail" -eq 0 ] && echo "All remote-build tests passed." || echo "Some remote-build tests FAILED."
exit "$fail"
