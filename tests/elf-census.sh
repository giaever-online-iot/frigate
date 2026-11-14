#!/usr/bin/env bash
# elf-census.sh - list ELF files of the wrong machine type in a dir or .snap.
# Usage: tests/elf-census.sh <dir|.snap> <aarch64|x86-64>
#   Prints, one relative path per line, each regular file whose `file -b`
#   starts with "ELF" but lacks the machine string (ARM aarch64 / x86-64).
#   Exit 1 if any are listed, 0 if none, 2 on usage or unreadable input.
set -uo pipefail
[ $# -eq 2 ] || { sed -n '2,6p' "$0" >&2; exit 2; }
case $2 in
  aarch64) want='ARM aarch64' ;;
  x86-64)  want='x86-64' ;;
  *) echo "elf-census: arch must be aarch64 or x86-64, got: $2" >&2; exit 2 ;;
esac
command -v file >/dev/null 2>&1 || { echo "elf-census: 'file' not installed" >&2; exit 2; }
T=$(mktemp -d); trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
if [ -d "$1" ]; then root=$1
elif [ -f "$1" ]; then
  command -v unsquashfs >/dev/null 2>&1 || { echo "elf-census: unsquashfs not installed" >&2; exit 2; }
  unsquashfs -n -f -d "$T/u" "$1" >/dev/null 2>&1 || { echo "elf-census: unsquashfs failed: $1" >&2; exit 2; }
  root=$T/u
else echo "elf-census: no such file or dir: $1" >&2; exit 2; fi

(cd "$root" && find . -type f -printf '%P\0') > "$T/list" 2> "$T/err"
if [ $? -ne 0 ] || [ -s "$T/err" ]; then echo "elf-census: find failed under $root:" >&2; cat "$T/err" >&2; exit 2; fi
bad=0
while IFS= read -r -d '' p; do
  [ -r "$root/$p" ] || { echo "elf-census: cannot read (unreadable): $p" >&2; exit 2; }
  d=$(file -b -- "$root/$p" 2>/dev/null) && [ -n "$d" ] || { echo "elf-census: cannot inspect (unreadable?): $p" >&2; exit 2; }
  case $d in
    *"no read permission"*|*"cannot open"*) echo "elf-census: cannot read: $p" >&2; exit 2 ;;
    "ELF"*) case $d in *"$want"*) ;; *) printf '%s\n' "$p"; bad=1 ;; esac ;;
  esac
done < <(LC_ALL=C sort -z "$T/list")
exit "$bad"
