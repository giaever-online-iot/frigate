#!/usr/bin/env bash
# snap-census.sh - file-by-file comparison of two snaps (or unpacked dirs).
# Usage: tests/snap-census.sh <old.snap|dir> <new.snap|dir> [expected-changed-file]
#   Prints sorted "ADDED <path>", "REMOVED <path>" and "CHANGED <path>" lines
#   (sha256 differs; *.pyc ignored). CHANGED paths outside bin/, probes/,
#   config/, snap/ and meta/hooks/ are printed with an "INFO " prefix.
#   Exit 1 on any ADDED/REMOVED, or on a CHANGED path under those prefixes
#   that is not listed (one path per line) in the optional expected file.
set -uo pipefail
[ $# -ge 2 ] && [ $# -le 3 ] || { sed -n '2,8p' "$0" >&2; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export LC_ALL=C

prep() { # prep <input> <n> -> echoes root dir
  if [ -d "$1" ]; then printf '%s' "$1"; return 0; fi
  [ -f "$1" ] || { echo "snap-census: no such file or dir: $1" >&2; return 1; }
  unsquashfs -n -f -d "$T/u$2" "$1" >/dev/null 2>&1 || { echo "snap-census: unsquashfs failed: $1" >&2; return 1; }
  printf '%s' "$T/u$2"
}
A=$(prep "$1" 1) || exit 2
B=$(prep "$2" 2) || exit 2
EXP=${3:-}
[ -z "$EXP" ] || [ -f "$EXP" ] || { echo "snap-census: no such expected file: $EXP" >&2; exit 2; }

list() { (cd "$1" && find . -type f ! -name '*.pyc' -printf '%P\0' | sort -z); }
list "$A" > "$T/la"; list "$B" > "$T/lb"

rc=0
{
  comm -z -13 "$T/la" "$T/lb" | while IFS= read -r -d '' p; do printf 'ADDED %s\n' "$p"; done
  comm -z -23 "$T/la" "$T/lb" | while IFS= read -r -d '' p; do printf 'REMOVED %s\n' "$p"; done
  comm -z -12 "$T/la" "$T/lb" | while IFS= read -r -d '' p; do
    if [ "$(sha256sum < "$A/$p")" != "$(sha256sum < "$B/$p")" ]; then
      case $p in
        bin/*|probes/*|config/*|snap/*|meta/hooks/*)
          if [ -n "$EXP" ] && grep -qxF -- "$p" "$EXP"; then printf 'CHANGED %s\n' "$p"
          else printf 'CHANGED! %s\n' "$p"; fi ;;
        *) printf 'INFO CHANGED %s\n' "$p" ;;
      esac
    fi
  done
} | sort > "$T/out"

# CHANGED! marks an unexpected change: fail, but print as CHANGED.
grep -q -e '^ADDED ' -e '^REMOVED ' -e '^CHANGED! ' "$T/out" && rc=1
sed 's/^CHANGED! /CHANGED /' "$T/out" | sort
exit "$rc"
