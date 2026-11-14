#!/usr/bin/env bash
# snap-census.sh - file-by-file comparison of two snaps (or unpacked dirs).
# Usage: tests/snap-census.sh <old.snap|dir> <new.snap|dir> [expected-changed-file]
#   Prints sorted "ADDED <path>", "REMOVED <path>" and "CHANGED <path>" lines
#   (sha256 differs; *.pyc ignored). Symlinks are listed too: one present on a
#   single side is ADDED/REMOVED, a changed readlink target (or file<->symlink
#   type change) is CHANGED. CHANGED paths outside bin/, probes/,
#   config/, snap/ and meta/hooks/ are printed with an "INFO " prefix.
#   Exit 1 on any ADDED/REMOVED, or on a CHANGED path under those prefixes
#   that is not listed (one path per line) in the optional expected file.
#   Fails closed: exit 2 if any file cannot be hashed or any find reports an
#   error (unreadable file/dir), naming the path; never silently drops a path.
set -uo pipefail
[ $# -ge 2 ] && [ $# -le 3 ] || { sed -n '2,12p' "$0" >&2; exit 2; }
T=$(mktemp -d); trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
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

list() { # list <root> <outfile>; fails closed on any find error
  (cd "$1" && find . \( -type f -o -type l \) ! -name '*.pyc' -printf '%P\0') > "$2.raw" 2> "$2.err"
  if [ $? -ne 0 ] || [ -s "$2.err" ]; then
    echo "snap-census: find failed under $1:" >&2; cat "$2.err" >&2; exit 2
  fi
  sort -z "$2.raw" > "$2"
}
list "$A" "$T/la"; list "$B" "$T/lb"

# sig <root> <path> -> "L:<target>" for symlinks, "F:<sha256>" for files; exit 2 on failure
sig() {
  local f=$1/$2 h
  if [ -L "$f" ]; then
    h=$(readlink -- "$f") || { echo "snap-census: cannot readlink: $f" >&2; exit 2; }
    printf 'L:%s' "$h"
  else
    h=$(sha256sum -- "$f" 2>/dev/null) && [ -n "$h" ] || { echo "snap-census: cannot hash (unreadable?): $f" >&2; exit 2; }
    printf 'F:%s' "${h%% *}"
  fi
}

{
  while IFS= read -r -d '' p; do printf 'ADDED %s\n' "$p"; done < <(comm -z -13 "$T/la" "$T/lb")
  while IFS= read -r -d '' p; do printf 'REMOVED %s\n' "$p"; done < <(comm -z -23 "$T/la" "$T/lb")
  comm -z -12 "$T/la" "$T/lb" > "$T/common"
  while IFS= read -r -d '' p; do
    sa=$(sig "$A" "$p") || exit 2
    sb=$(sig "$B" "$p") || exit 2
    if [ "$sa" != "$sb" ]; then
      case $p in
        bin/*|probes/*|config/*|snap/*|meta/hooks/*)
          if [ -n "$EXP" ] && grep -qxF -- "$p" "$EXP"; then printf 'CHANGED %s\n' "$p"
          else printf 'CHANGED! %s\n' "$p"; fi ;;
        *) printf 'INFO CHANGED %s\n' "$p" ;;
      esac
    fi
  done < "$T/common"
} > "$T/out0"
st=$?
[ "$st" -eq 0 ] || exit "$st"
sort "$T/out0" > "$T/out"

rc=0
# CHANGED! marks an unexpected change: fail, but print as CHANGED.
grep -q -e '^ADDED ' -e '^REMOVED ' -e '^CHANGED! ' "$T/out" && rc=1
sed 's/^CHANGED! /CHANGED /' "$T/out" | sort
exit "$rc"
