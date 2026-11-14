#!/usr/bin/env bash
# Stub-driven unit tests for remote-build.sh. No network: fake `snapcraft` and
# `unsquashfs` on PATH simulate a truncated amd64 fetch that recovers on retry.
# The stub models snapcraft 9's build id (craft_application get_build_id: an md5
# over EVERY file in the project dir): `--recover` finds the Launchpad build only
# if the tree is unchanged since attempt 1, else it fails as CI did on PR 9
# ("Could not find repository at path ~<team>/+git/snapcraft-frigate-<other hash>").
set -uo pipefail  # no -e: keep all tests running even if one fails

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RB="$HERE/remote-build.sh"
fail=0
check() { # desc expected actual
  if [ "$2" = "$3" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
    fail=1
  fi
}

# Build a throwaway workspace with stub snapcraft + unsquashfs on PATH.
# mode=flaky:   amd64 download truncated on the first fetch, intact once recovered.
# mode=partial: amd64 never produces an artifact (a genuine build failure).
# mode=lastbreak: 2 archs; attempt 1 gets amd64 and a truncated arm64 (PR 9's case); the
#                 recover gets arm64 but breaks before amd64 is rewritten, so only the
#                 copy parked from attempt 1 is left.
# Layout: $work/bin (stubs), $work/attempts + $work/hash1 (stub state), $work/proj (the
# project dir the script runs in; it holds one tracked file, as a checkout would).
setup() { # $1 = mode -> echoes workdir
  local mode="$1" work bin
  work="$(mktemp -d)"; bin="$work/bin"; mkdir -p "$bin" "$work/proj"
  echo 'name: frigate' > "$work/proj/snapcraft.yaml"
  cat > "$bin/unsquashfs" <<'EOF'
#!/usr/bin/env bash
# stub: `unsquashfs -l <file>` succeeds unless the file is marked CORRUPT
f=""; for f; do :; done
grep -q CORRUPT "$f" 2>/dev/null && exit 1
exit 0
EOF
  cat > "$bin/snapcraft" <<EOF
#!/usr/bin/env bash
state="$work/attempts"; n=0; [ -f "\$state" ] && n="\$(cat "\$state")"; n=\$((n+1)); echo "\$n" > "\$state"
recover=0; for a in "\$@"; do [ "\$a" = "--recover" ] && recover=1; done
h="\$(find . -type f | LC_ALL=C sort | xargs cat | md5sum)"
if [ "\$n" -eq 1 ]; then echo "\$h" > "$work/hash1"
elif [ "\$recover" -eq 1 ] && [ "\$h" != "\$(cat "$work/hash1")" ]; then
  echo "Could not find repository at path ~team/+git/snapcraft-frigate-other" >&2; exit 1
fi
if [ "$mode" = lastbreak ]; then
  if [ "\$recover" -eq 1 ]; then printf 'OK' > frigate_v1_arm64.snap; exit 1
  else printf 'OK' > frigate_v1_amd64.snap; printf 'CORRUPT' > frigate_v1_arm64.snap; exit 1; fi
fi
printf 'OK' > frigate_v1_arm64.snap
printf 'OK' > frigate_v1_armhf.snap
case "$mode" in
  flaky)
    if [ "\$recover" -eq 1 ]; then printf 'OK' > frigate_v1_amd64.snap
    else printf 'CORRUPT' > frigate_v1_amd64.snap; exit 1; fi ;;
  partial)
    exit 1 ;;
esac
EOF
  chmod +x "$bin/unsquashfs" "$bin/snapcraft"
  echo "$work"
}

snaps_line() { printf '%s\n' "$1" | grep -oE 'snaps=[0-9]+' | tail -1; }

# --- flaky download: retries via --recover, ends with all 3 valid, none corrupt ---
work="$(setup flaky)"
out="$( cd "$work/proj" && PATH="$work/bin:$PATH" MAX_ATTEMPTS=3 RETRY_DELAY=0 bash "$RB" amd64,arm64,armhf )"
check "flaky: reports 3 valid snaps"   "snaps=3" "$(snaps_line "$out")"
check "flaky: 3 snap files on disk"    "3"       "$(find "$work/proj" -maxdepth 1 -name '*.snap' | wc -l | tr -d ' ')"
check "flaky: no corrupt file remains" "0"       "$(grep -l CORRUPT "$work"/proj/*.snap 2>/dev/null | wc -l | tr -d ' ')"
check "flaky: retried once (2 builds)" "2"       "$(cat "$work/attempts")"
rm -rf "$work"

# --- genuine partial failure: tolerated, returns the 2 that built, exit 0 ---
work="$(setup partial)"
out="$( cd "$work/proj" && PATH="$work/bin:$PATH" MAX_ATTEMPTS=3 RETRY_DELAY=0 bash "$RB" amd64,arm64,armhf )"
check "partial: reports 2 valid snaps" "snaps=2" "$(snaps_line "$out")"
check "partial: exhausts 3 attempts"   "3"       "$(cat "$work/attempts")"
check "partial: 2 snap files on disk"  "2"       "$(find "$work/proj" -maxdepth 1 -name '*.snap' | wc -l | tr -d ' ')"
( cd "$work/proj" && PATH="$work/bin:$PATH" MAX_ATTEMPTS=3 RETRY_DELAY=0 bash "$RB" amd64,arm64,armhf ) >/dev/null 2>&1
check "partial: exit 0 (tolerant)"     "0"       "$?"
rm -rf "$work"

# --- GITHUB_OUTPUT receives the count ---
work="$(setup flaky)"; gho="$work/gho"
( cd "$work/proj" && PATH="$work/bin:$PATH" MAX_ATTEMPTS=3 RETRY_DELAY=0 GITHUB_OUTPUT="$gho" bash "$RB" amd64,arm64,armhf ) >/dev/null 2>&1
check "writes snaps= to GITHUB_OUTPUT" "snaps=3" "$(grep -oE 'snaps=[0-9]+' "$gho" | tail -1)"
rm -rf "$work"

# --- a parked snap that no later attempt re-fetches is restored (PR 9's amd64+arm64 case) ---
work="$(setup lastbreak)"
out="$( cd "$work/proj" && PATH="$work/bin:$PATH" MAX_ATTEMPTS=3 RETRY_DELAY=0 bash "$RB" amd64,arm64 )"
check "lastbreak: reports 2 valid snaps"  "snaps=2" "$(snaps_line "$out")"
check "lastbreak: recovered on attempt 2" "2"       "$(cat "$work/attempts")"
check "lastbreak: both snaps in the project dir" "frigate_v1_amd64.snap frigate_v1_arm64.snap" "$(cd "$work/proj" && ls -1 ./*.snap | sed 's|^\./||' | tr '\n' ' ' | sed 's/ $//')"
check "lastbreak: both valid"             "0"       "$(grep -l CORRUPT "$work"/proj/*.snap 2>/dev/null | wc -l | tr -d ' ')"
rm -rf "$work"

# --- the retry leaves the tracked tree as it was and keeps nothing parked ---
work="$(setup flaky)"
out="$( cd "$work/proj" && PATH="$work/bin:$PATH" MAX_ATTEMPTS=3 RETRY_DELAY=0 TMPDIR="$work" bash "$RB" amd64,arm64,armhf )"
check "flaky: parked fetched snaps before the retry" "1" "$(printf '%s\n' "$out" | grep -c '^parked 2 fetched file(s) outside the project dir')"
check "flaky: tracked file intact"     "name: frigate" "$(cat "$work/proj/snapcraft.yaml")"
check "flaky: no park dir left behind" "0"       "$(find "$work" -maxdepth 1 -name 'remote-build-park.*' | wc -l | tr -d ' ')"
rm -rf "$work"

[ "$fail" -eq 0 ] && echo "All remote-build tests passed." || echo "Some remote-build tests FAILED."
exit "$fail"
