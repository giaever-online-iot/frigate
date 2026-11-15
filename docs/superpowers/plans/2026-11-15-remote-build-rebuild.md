# W-24 Remote-build Rebuild Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When Launchpad built an arch but its artifact download broke, `.github/scripts/remote-build.sh` starts a NEW remote build of only the missing archs. It never uses `--recover`, makes at most 3 attempts, and stays inside a 5 h budget.

**Architecture:** One bash script keeps its contract: one arg (comma-separated archs), exit 0, `snaps=<n>` on stdout and in `GITHUB_OUTPUT`. Its retry loop changes:
- each retry is a fresh `snapcraft remote-build --build-for=<missing>`;
- each retry gets its own build id from an attempt number written into `.git/remote-build-attempt`;
- the archs to rebuild come from the last `Succeeded:` state line of the attempt just finished. snapcraft's output is captured per attempt in a temp file **outside** the project dir (spec D5a);
- a budget check and `--launchpad-timeout` bound the time. No attempt starts with less than 1 s left, and the numeric inputs are validated (spec D6).

The stub-driven test models snapcraft 9.2.1 (build id hash, `--recover` failure, state lines on stderr, `--launchpad-timeout`, files it would push), plus a fake clock and a recording `sleep`. A committed mutation runner proves the test catches each decision.

**Tech Stack:** bash, shellcheck 0.9.0, GitHub Actions; snapcraft 9.2.1 (modelled by the stub, never called).

**Spec:** `docs/superpowers/specs/2026-11-15-remote-build-rebuild-design.md` (decisions D1–D11; §3 cites the snapcraft source, §6 has the timing arithmetic).

## Global Constraints

- Scope: only `.github/**`. Files: `.github/scripts/remote-build.sh`, `.github/scripts/remote-build.test.sh`, `.github/scripts/remote-build.mutate.sh` (new) and the comment above the build step in `.github/workflows/pr-build-snap.yml`. No `snap/**` change. `release-on-merge.yml` and `snapcraft-close.test.sh` stay byte-identical (spec D7).
- Defaults: `MAX_ATTEMPTS=3`, `RETRY_DELAY=15`, `BUILD_BUDGET=18000`. Marker path `.git/remote-build-attempt`; its content is the attempt number (2, 3, …). Attempt 1 writes no marker.
- Never `--recover`. Exit 0 always. `prune_corrupt` stays. `snaps=` counts the requested archs that have a valid snap, matched by the upload step's suffix match `*<arch>.snap` (spec D8).
- Input validation: `MAX_ATTEMPTS` and `BUILD_BUDGET` must be integers ≥ 1, and `RETRY_DELAY` an integer ≥ 0. Any other value gives `::warning::<NAME>='<value>' is not an integer >= <min>; using <default>` on stdout, where the Actions runner reads workflow commands. No attempt starts with `left` < 1; instead the script prints `::warning::not starting attempt <n>: the <budget>s budget is used up` (spec D6, review P3).
- snapcraft's output goes to `mktemp "${TMPDIR:-/tmp}/remote-build-out.XXXXXX"`, with `2>&1` and plain `tee` (truncated per attempt). It never goes into the project dir (spec D5a).
- Mutant numbering is the spec's §7: M1–M16, with M11 split into M11a (validation) and M11b (the `left` < 1 guard).
- No camera or host addresses, hostnames, credentials, tokens, serials, Launchpad owner or project names (write `<owner>`/`<project>`), or the maintainer's name or pronouns in any file, commit message or PR text.
- **Do not push.** A push starts a Launchpad build and a Store upload. The controller pushes, once.
- Heavy suites go under `flock -w 3600 /tmp/claude-1000/chim-suites.lock <cmd>`. The `.github/scripts` suites take seconds and need no lock.
- Never read or print a credentials file; never contact Launchpad or the Store.

## Review Focus

Conditions the spec implies that a reader could overlook. Each is pinned by a test in Task 1:

1. **A retry that fails before printing any state** (auth or network): attempt 1's `Succeeded:` line must not be read again. Expect 2 calls and `not rebuilding amd64: … in attempt 2`. Test: `cutthenfail` (mutant M12, `tee -a`).
2. **snapcraft's output written into the project dir:** it would be auto-committed into the public pushed source. Test: the stub's stray-file record, `no stray file … at any call` (mutant M10).
3. **Bad numeric input** (`BUILD_BUDGET=0`, `-100`, `5h`; `MAX_ATTEMPTS=x`): with 0 snapcraft would wait without a timeout, with a negative value it would crash, and `5h` would make no call at all. Expect a warning and the default. Tests: `BUILD_BUDGET=…` and `MAX_ATTEMPTS=x` (M11a). The budget running out between attempts is covered by `no budget left` (M11b).
4. **An attempt that hits `--launchpad-timeout`:** snapcraft prints one more `Succeeded:` line, fetches nothing and exits 75. Do not rebuild with the budget used up. Test: `timeout`.
5. **snapcraft's state lines arrive on stderr**, an intermediate one (`Building: amd64; Succeeded: arm64`) before the final one: capture stderr and parse the last line. Test: every `cut` case (mutants M13 and M15, `drop 2>&1`); the stub prints both lines on stderr, as snapcraft's verbose `emit.progress` does.

---

### Task 1: remote-build.sh rebuilds a cut download as a new build

**Files:**
- Modify (full rewrite): `.github/scripts/remote-build.test.sh`
- Modify (full rewrite): `.github/scripts/remote-build.sh`
- Create: `.github/scripts/remote-build.mutate.sh`
- Modify: `.github/workflows/pr-build-snap.yml` (the comment block directly above `- name: Remote-build all archs (retry transient fetch failures)`)

**Interfaces:**
- Consumes: nothing new. The workflow calls `.github/scripts/remote-build.sh "<archs>"` and reads `steps.build.outputs.snaps`. Both stay as they are.
- Produces:
  - `remote-build.sh <archs>`, reading env `MAX_ATTEMPTS`, `RETRY_DELAY`, `BUILD_BUDGET` and `GITHUB_OUTPUT`;
  - `remote-build.test.sh`, which honours `RB=<path>` to test a mutated copy;
  - `remote-build.mutate.sh`, which exits 0 iff every mutant is killed.

Work in the W-24 worktree (its path is in the W-24 brief), on branch `fix/remote-build-fetch-recover`. Never work in the main checkout. Before starting, check that `git status --short` is clean apart from the spec and plan commits.

- [ ] **Step 1: Write the failing test.** Replace `.github/scripts/remote-build.test.sh` entirely with:

```bash
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
check "timeout: says why it does not rebuild"   "1"       "$(warned "$out" 'not rebuilding amd64: attempt 1 took 18000s')"
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
```

- [ ] **Step 2: Run it against the current script and see it fail**

Run: `bash .github/scripts/remote-build.test.sh; echo "exit=$?"; bash .github/scripts/remote-build.test.sh | grep -c '^FAIL'`
Expected: `Some remote-build tests FAILED.`, `exit=1`, and `43` FAIL lines (`16` ok). Among them must be: `cut: no call uses --recover` (actual `0 1`), `cut: call 2 rebuilds only amd64` (actual `amd64,arm64`), `alwayscut: 3 distinct build ids` (actual `1`), `buildfail: 1 snapcraft call` (actual `3`) and `budget: 1 snapcraft call` (actual `3`). A different count means the stub or the script differs from what this plan was checked against: stop and find out why before going on.

- [ ] **Step 3: Implement.** Replace `.github/scripts/remote-build.sh` entirely with the following (spec D1–D9; the header comment carries the reasons):

```bash
#!/usr/bin/env bash
# remote-build.sh — `snapcraft remote-build` for the given archs. When Launchpad
# built an arch but the DOWNLOAD of its artifact broke, start a NEW remote build
# of just the archs still missing, within MAX_ATTEMPTS and BUILD_BUDGET.
#
# Why: the Launchpad build can SUCCEED while snapcraft's download of the artifact
# breaks mid-stream ("Connection broken: IncompleteRead"; PR 9 and PR 10, the
# first two two-arch runs). That leaves a truncated .snap on disk which would
# fail to unsquash at upload. Every fetched snap is validated and a truncated
# one is dropped, so a bad file never reaches `snapcraft upload`.
#
# Why a new build and not `--recover`: snapcraft 9.2.1 creates the Launchpad
# repository under its remote-build project (~<owner>/<project>/+git/<id>), but
# `--recover` looks it up without the project (~<owner>/+git/<id>), so recovery
# never finds it (PR 10: "Could not find repository" for the very id attempt 1
# had pushed). A new build walks the same path attempt 1 does on every run.
#
# Each attempt gets its own build id. snapcraft's id is an md5 over the CONTENTS
# of every file in the project dir, .git included (craft_application
# remote/utils.py _compute_hash), so the attempt number written to
# .git/remote-build-attempt changes it, while the source snapcraft pushes stays
# the PR's commit (nothing under .git is committed). Removed at exit.
#
# Not retried: an arch Launchpad did not report as Succeeded (a genuine build
# failure or a timeout); it is left to the caller's completeness gate, as before.
# A rebuild only starts if the previous attempt's duration still fits in
# BUILD_BUDGET, and each attempt passes --launchpad-timeout=<budget left>, so the
# job reaches its upload step inside GitHub's 6 h job limit. No attempt starts
# with less than 1 s left: snapcraft reads --launchpad-timeout=0 as "no timeout"
# and a negative value as an internal error.
#
# Usage:  remote-build.sh <comma-separated-archs>        # e.g. amd64,arm64,armhf
# Env:    MAX_ATTEMPTS (default 3), RETRY_DELAY seconds (default 15),
#         BUILD_BUDGET seconds for all attempts (default 18000 = 5 h)
#         (a value that is not an integer in range gets a ::warning:: and the default)
#         GITHUB_OUTPUT (optional) — receives "snaps=<valid-count>"
# Exit:   0 always (partial-tolerant).
set -uo pipefail

ARCHS="${1:?usage: remote-build.sh <archs>, e.g. amd64,arm64,armhf}"
# $1 = variable name, $2 = default, $3 = smallest valid value. Keeps the variable if it
# holds an integer >= $3; otherwise warns (on stdout, where the Actions runner reads
# workflow commands) and sets the default.
int_or_default() {
    local v="${!1:-$2}"
    case "$v" in
        ''|*[!0-9]*) ;;
        *) if [ "${#v}" -le 9 ] && [ "$((10#$v))" -ge "$3" ]; then printf -v "$1" '%s' "$((10#$v))"; return; fi ;;
    esac
    echo "::warning::$1='$v' is not an integer >= $3; using $2"
    printf -v "$1" '%s' "$2"
}
int_or_default MAX_ATTEMPTS 3 1
int_or_default RETRY_DELAY 15 0
int_or_default BUILD_BUDGET 18000 1

IFS=',' read -ra WANT <<< "$ARCHS"
want="${#WANT[@]}"

# 0 iff $1 is a complete, readable squashfs. `unsquashfs -l` reads the inode and
# directory tables (near the END of the archive), so a truncated download fails
# here — unlike a superblock-only check, which a tail-truncated file would pass.
snap_ok() { unsquashfs -l "$1" >/dev/null 2>&1; }

# Drop truncated/corrupt artifacts so a bad file never reaches `snapcraft upload`.
prune_corrupt() {
    local f
    for f in ./*.snap; do
        [ -e "$f" ] || continue
        if ! snap_ok "$f"; then
            echo "discarding corrupt/truncated artifact: $f"
            rm -f "$f"
        fi
    done
}

# 0 iff a snap for arch $1 is in the project dir (run after prune_corrupt). Same suffix
# match as the workflow's upload step ("${SNAP_NAME}"*"${arch}".snap).
have_arch() { local f; for f in ./*"$1".snap; do [ -e "$f" ] && return 0; done; return 1; }

valid_count() { local a n=0; for a in "${WANT[@]}"; do have_arch "$a" && n=$((n + 1)); done; echo "$n"; }

missing_archs() { local a out=(); for a in "${WANT[@]}"; do have_arch "$a" || out+=("$a"); done; (IFS=,; echo "${out[*]}"); }

# Missing archs that Launchpad reported as built in the attempt whose output is in $1:
# the last "Succeeded: amd64, arm64" state line snapcraft printed before fetching.
rebuild_archs() {
    local a out=() built
    built=",$(sed -n 's/.*Succeeded: \([^;]*\).*/\1/p' "$1" | tail -n1 | tr -d ' '),"
    for a in "${WANT[@]}"; do
        have_arch "$a" && continue
        case "$built" in *",$a,"*) out+=("$a") ;; esac
    done
    (IFS=,; echo "${out[*]}")
}

MARK=.git/remote-build-attempt
# snapcraft's output (D5 parses its state lines) must stay OUT of the project dir:
# snapcraft copies the whole dir and auto-commits every file that is not ignored,
# so a file here would be pushed to the public Launchpad repository and change the
# build id. `tee` (no -a) truncates it, so each attempt is parsed on its own.
LOG="$(mktemp "${TMPDIR:-/tmp}/remote-build-out.XXXXXX")"
rm -f "$MARK"
trap 'rm -f "$MARK" "$LOG"' EXIT
[ -d .git ] || echo "::warning::.git is not a directory; a rebuild would reuse attempt 1's build id"

start="$(date +%s)"
build_for="$ARCHS"
attempt=1
while :; do
    left=$((BUILD_BUDGET - ($(date +%s) - start)))
    if [ "$left" -lt 1 ]; then
        echo "::warning::not starting attempt ${attempt}: the ${BUILD_BUDGET}s budget is used up"
        break
    fi
    echo "::group::remote-build attempt ${attempt}/${MAX_ATTEMPTS} (${build_for}; ${left}s of budget left)"
    # A new build every time (never --recover); attempts 2+ write their number into
    # .git so snapcraft computes a new build id. `|| true`: a partial-arch failure must
    # not abort; what was fetched is validated below.
    if [ "$attempt" -gt 1 ] && [ -d .git ]; then echo "$attempt" > "$MARK"; fi
    t0="$(date +%s)"
    snapcraft remote-build -v --launchpad-accept-public-upload --build-for="$build_for" \
        --launchpad-timeout="$left" 2>&1 | tee "$LOG" || true
    t1="$(date +%s)"
    echo "::endgroup::"

    prune_corrupt
    count="$(valid_count)"
    echo "valid snaps after attempt ${attempt}: ${count}/${want}"
    [ "$count" -ge "$want" ] && break
    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        echo "::warning::still missing $(missing_archs) after ${MAX_ATTEMPTS} attempts"
        break
    fi
    rebuild="$(rebuild_archs "$LOG")"
    if [ -z "$rebuild" ]; then
        echo "::warning::not rebuilding $(missing_archs): Launchpad did not report it Succeeded in attempt ${attempt} (a build failure or timeout, not a broken download)"
        break
    fi
    took=$((t1 - t0)); used=$((t1 - start))
    if [ $((used + RETRY_DELAY + took)) -gt "$BUILD_BUDGET" ]; then
        echo "::warning::not rebuilding ${rebuild}: attempt ${attempt} took ${took}s, ${used}s of the ${BUILD_BUDGET}s budget are used"
        break
    fi
    echo "incomplete (${count}/${want}) — new remote build of ${rebuild} in ${RETRY_DELAY}s"
    sleep "$RETRY_DELAY"
    build_for="$rebuild"
    attempt=$((attempt + 1))
done

count="$(valid_count)"
ls -1 ./*.snap 2>/dev/null || echo "(no .snap files produced)"
echo "snaps=${count}"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "snaps=${count}" >> "$GITHUB_OUTPUT"
exit 0
```

- [ ] **Step 4: Run the test and see it pass**

Run: `bash .github/scripts/remote-build.test.sh; echo "exit=$?"; bash .github/scripts/remote-build.test.sh | grep -c '^ok'`
Expected: `All remote-build tests passed.`, `exit=0`, `59`.

- [ ] **Step 5: Write the mutation runner** `.github/scripts/remote-build.mutate.sh`:

```bash
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
[ "$bad" -eq 0 ] && echo "All mutants killed." || echo "Some mutants SURVIVED or did not apply."
exit "$bad"
```

- [ ] **Step 6: Run the mutation runner and see every mutant killed**

Run: `bash .github/scripts/remote-build.mutate.sh; echo "exit=$?"`
Expected: 17 `killed` lines (M1–M10, M11a, M11b, M12–M16), no `NOT APPLIED` and no `SURVIVED`, then `All mutants killed.` and `exit=0`. If you see `NOT APPLIED`, a pattern no longer matches the script text: fix the pattern, never the test. If you see `SURVIVED`, the test is missing a check: add it to the test. Both cases go back to Step 4.

- [ ] **Step 7: Rewrite the workflow comment.** In `.github/workflows/pr-build-snap.yml`, replace exactly these lines:

```yaml
      # Builds + fetches every arch, retrying when a transient network error
      # truncates the artifact DOWNLOAD (the Launchpad build itself succeeds).
      # Validates each .snap, drops truncated ones, and re-fetches via --recover
      # (no rebuild). Still tolerant of a genuine partial-arch build failure.
      # Writes steps.build.outputs.snaps=<valid-count>. See remote-build.test.sh.
      # Frigate's build (ffmpeg/go2rtc/ML runtimes) is much heavier than a
      # typical snap — this helper's retry/timeout behaviour is carried over
      # UNCHANGED from the source pattern; see remote-build.sh's header note.
```

with:

```yaml
      # Builds + fetches every arch. Validates each .snap and drops truncated ones.
      # When Launchpad built an arch but its DOWNLOAD broke (PR 9, PR 10), starts a
      # NEW remote build of just the missing archs: never --recover, which cannot
      # find snapcraft's own Launchpad repository. At most 3 attempts, inside a 5 h
      # budget (BUILD_BUDGET), so the upload below runs before the 6 h job limit.
      # A genuine build failure is not rebuilt; it stays tolerated.
      # Writes steps.build.outputs.snaps=<valid-count>. See remote-build.test.sh.
```

Leave the step's `name:`, `id: build` and `run:` lines unchanged.

- [ ] **Step 8: Run every `.github/scripts` suite and both shellcheck steps of `lint-test.yml`**

Run:
```bash
for t in .github/scripts/*.test.sh; do bash "$t" >/dev/null 2>&1; echo "$t exit=$?"; done
shellcheck --severity=warning -x .github/scripts/*.sh; echo "shellcheck(.github)=$?"
git diff --quiet HEAD -- .github/workflows/release-on-merge.yml .github/scripts/snapcraft-close.test.sh && echo "D7 untouched"
grep -n -- '--recover' .github/workflows/pr-build-snap.yml .github/scripts/remote-build.sh
```
Expected:
- all six suites report `exit=0`;
- `shellcheck(.github)=0`;
- `D7 untouched`;
- the `--recover` grep finds only the workflow comment line containing `never --recover, which cannot` and the header and comment lines in `remote-build.sh` that explain why it is not used. No command line contains it.

Also run the first shellcheck step of `lint-test.yml` exactly as that file has it. It does not cover `.github/scripts`, so it must stay as green as on ae00129.

- [ ] **Step 9: Commit**

```bash
git add .github/scripts/remote-build.sh .github/scripts/remote-build.test.sh .github/scripts/remote-build.mutate.sh .github/workflows/pr-build-snap.yml
git commit -F - <<'EOF'
fix(ci): remote-build starts a new build for an arch whose download broke, never --recover (W-24)

Corrects bea5564. Its message said the build "stays recoverable". It does not.
snapcraft 9.2.1 creates the Launchpad repository under its remote-build project
(~<owner>/<project>/+git/<id>), but --recover looks the repository up without
the project (~<owner>/+git/<id>). PR 10's run looked up the very id attempt 1
had pushed and still got "Could not find repository". The parking bea5564
added, and its tests, are removed.

When Launchpad reports an arch Succeeded but no valid snap arrived, the script
now starts a new remote build of only the missing archs, with at most
MAX_ATTEMPTS (3) attempts in total. Attempts 2 and later write their number
into .git/remote-build-attempt. That gives each attempt its own build id, while
the pushed commit stays the PR's. An arch that failed to build is not rebuilt
(D5).

D6, time:
- BUILD_BUDGET (5 h) bounds all attempts.
- Each attempt passes --launchpad-timeout=<budget left>.
- A retry starts only if the last attempt's duration still fits (PR 9's
  attempt took 4 h 10 min).
- No attempt starts with less than 1 s left: 0 would mean no timeout and a
  negative value crashes snapcraft.
- MAX_ATTEMPTS, RETRY_DELAY and BUILD_BUDGET are validated; a bad value gives
  a warning (on stdout, where the runner reads workflow commands) and the
  default.

D5a: snapcraft's output, whose last Succeeded: line picks the archs to rebuild,
is captured per attempt (2>&1, because snapcraft prints the state lines on
stderr; truncated) in a temp file outside the project
dir. snapcraft auto-commits non-ignored files there into the public pushed
source.

D8: snaps= now counts the requested archs that have a valid snap, matched by
the upload step's *<arch>.snap suffix. Before, it counted distinct .snap files.

Proven offline:
- remote-build.test.sh is red on ae00129 (43 checks) and green after
  (59). Its stub models snapcraft's build id hash, the --recover
  failure, the state lines on stderr, --launchpad-timeout and the files it
  would push.
- Each of the 17 mutants in remote-build.mutate.sh turns it red.
- All .github/scripts/*.test.sh suites and shellcheck pass.

Not proven: any rebuild against Launchpad, or that a rebuild avoids another cut
download (the idle-second-connection explanation is a hypothesis). PR 10's own
CI run is the first real test.
EOF
```

Correct the counts in the message if Step 2, 4 or 6 printed different ones, and say why.

---

### Task 2: Correct the PR #10 body (no repository change)

PR #10's body is wrong in three places (spec §8):
- it describes the parking that Task 1 removes;
- it says the `--recover` premise was checked, but `--recover` cannot find the repository at all;
- its "about 4.5 h of Launchpad" is PR #9's job time.

The PR text is not in the repository, and you do not edit the PR: the controller does, together with the one push.

**Files:**
- Create: `<your scratchpad>/pr-body-fetchfix.md`, a replacement for the controller's copy of the current body (`pr-body-fetchfix.md` in the controller's scratchpad; its path is in the W-24 brief). Section 2 below is that copy's section 2, word for word.

**Interfaces:**
- Consumes: Task 1's commit hash and the numbers its Steps 2, 4 and 6 printed.
- Produces: one file the controller pastes as PR #10's body.

- [ ] **Step 1: Write the body.** Fill in `<task-1 commit>` and adjust any count that differed in Task 1:

```markdown
## What

Two CI fixes that came out of shipping #9. Both touch only `.github/`.

### 1. `remote-build.sh`: a cut download is rebuilt as a new build (W-24)

Launchpad built both archs on #9 and on this PR. In each run, the download of one ~1 GB snap to the runner then broke with `IncompleteRead` (#9: arm64; this PR's first run: amd64). The script's retries used `snapcraft remote-build --recover`, and recovery cannot work. snapcraft 9.2.1 creates the Launchpad repository under its remote-build project, but `--recover` looks it up without the project. This PR's first run looked up the very id attempt 1 had pushed and got "Could not find repository". That run uploaded arm64 only, and its completeness gate went red.

The script now:
- drops truncated files as before;
- for each arch that Launchpad reported `Succeeded` but that has no valid snap, starts a **new** remote build of just those archs, with at most 3 attempts in total;
- gives each attempt its own build id by writing the attempt number into `.git/remote-build-attempt`. snapcraft hashes every file in the project dir, `.git` included, but nothing under `.git` is part of the commit it pushes, so the source built stays the PR's commit.

Not retried:
- an arch that failed to build (it stays tolerated, as before);
- anything once a 5 h budget would be exceeded. Every attempt passes `--launchpad-timeout=<budget left>`, a retry starts only if the previous attempt's duration still fits, and no attempt starts with less than 1 s left. That keeps the upload step inside GitHub's 6 h job limit.

Other details:
- `MAX_ATTEMPTS`, `RETRY_DELAY` and `BUILD_BUDGET` are validated; a bad value gives a warning and the default.
- snapcraft's output, whose state lines the script reads, goes to a temp file outside the project dir. snapcraft commits every non-ignored file there into the pushed source.
- `snaps=` now counts the requested archs that have a valid snap, using the upload step's `*<arch>.snap` match.

The earlier commit on this branch (bea5564) moved fetched files out of the tree so that `--recover` would find the same build. That premise was wrong, and this change removes that code.

Design and evidence (snapcraft source by file and line, CI log lines, timing arithmetic): `docs/superpowers/specs/2026-11-15-remote-build-rebuild-design.md`.

### 2. `release-on-merge.yml`: closing the merged PR channel (F8)

`snapcraft close "$SNAP" "$CHAN" --yes` has never worked: snapcraft 9.2.1's `close` takes only `-h` and `-v` and never prompts, so every merge failed at argument parsing ("unrecognized arguments: --yes"). The `|| echo "...ignoring"` fallback hid it, and the PR7, PR8 and PR9 channels stayed open until they expire. The flag is dropped. The close stays non-fatal (the promotion before it has already happened), but the fallback now prints the real exit status as a `::warning::`.

New `.github/scripts/snapcraft-close.test.sh` (picked up by the existing `.github/scripts/*.test.sh` loop in `lint-test.yml`) lints every `snapcraft close` call in `.github/`: options must be ones `snapcraft close --help` lists, a `||` fallback must print `$?`, and at least one call must exist.

## Tests run

- `remote-build.test.sh` uses a stub that models snapcraft's build id hash (md5 over every file's contents, `.git` included), the `--recover` failure text, the build state lines (on stderr, where snapcraft prints them), `--launchpad-timeout` (exit 75) and the files snapcraft would push. A fake clock drives the budget, and a stubbed `sleep` records the retry delay. The suite is red on the previous script (43 checks) and green after (59).
- `remote-build.mutate.sh` applies 17 mutants, and each turns the suite red:
  - re-add `--recover`; reuse the build id; rebuild all archs; drop the truncated-file check; unbounded attempts;
  - rebuild failed builds; drop the budget guard; drop `--launchpad-timeout`; keep a stale marker;
  - write snapcraft's output into the project dir; drop the input validation; start an attempt with no budget left;
  - parse earlier attempts' output; read the first state line instead of the last; write the marker on attempt 1;
  - stop capturing stderr (`2>&1`), where the state lines arrive; leave `RETRY_DELAY` unvalidated.
- The build id and push behaviour were also checked against snapcraft's own code, with no network:
  - a file under `.git` changes the id, and file names do not count;
  - with an ignored `.snap` and the marker in place, snapcraft's work tree commits nothing, so the pushed commit is the checkout's;
  - a non-ignored file would be committed into it.
- `snapcraft-close.test.sh`: red on the old line (`--yes` and the missing `$?`), green after. Three mutations on the real file (re-add `--yes`, drop `$?` from the message, delete the call) each turn it red.
- Every `.github/scripts/*.test.sh` and both shellcheck steps from `lint-test.yml` pass.
- Merged `main` (#9) into the branch (a11a2b6), no conflicts.

## Not verified

- No real rebuild against Launchpad. The rebuild only runs when a download is cut, which happened in both two-arch runs so far, so this PR's own CI run is the first real test.
- A rebuild is not guaranteed to avoid another cut. snapcraft opens every artifact download at once and then drains them one after another, so the second connection sits idle while the first ~1 GB file arrives. Both cuts happened under 1 MB into a file, which fits that idle connection being dropped. That explanation is NOT PROVEN. A one-arch rebuild downloads a single file over a single connection, so if the explanation holds, the retry is likely to succeed.
- If every attempt ends incomplete, the pipeline does what it does today. It uploads the valid snaps to `latest/edge/PR<N>`, and `Fail if build/upload incomplete` goes red when amd64 is missing.
- Each failed attempt leaves its repository and recipe on Launchpad. snapcraft cleans up only after a success, and that was already the case before this change.
- `snapcraft close` itself was not run against the Store. The first merge after this one will show it: the job log should have no warning and the PR channel should be closed.
- `tests/hub/serve.test.sh` (local-only, skips in CI) failed once on a loop-seam frame count and passed on re-run, on this branch and on a clean `main`. Not caused by this diff; not investigated.

## What opening this PR does

The change touches `.github/**`, so `PR Build Snap` runs on both archs and uploads to `latest/edge/PR<this number>`. Measured job times:
- this PR's first run: 43 min. Launchpad took about 25 min, then the download broke.
- #9: 4 h 29 min. Both archs spent about 3 h 44 min in Launchpad's own "Uploading" state after building in about 22 min.

A rebuild adds about 25–30 min at this PR's speed. At #9's speed the budget allows no rebuild. Merging promotes the amd64 revision to `latest/edge` as usual. arm64 stays manual (see `.github/release-archs.env`).
```

- [ ] **Step 2: Check the text against the rules**

Run: `grep -n -i -E '4\.5 h|park|recoverable|craft-remote-build|~[a-z]' <your scratchpad>/pr-body-fetchfix.md`
Expected: no output. Also confirm by reading it that the body names no person, owner, project, host or address.

- [ ] **Step 3: Hand it over.** Send the controller the file's full path and Task 1's commit hash. Nothing is committed in this task.
