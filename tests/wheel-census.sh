#!/usr/bin/env bash
# wheel-census.sh - list the Python wheels in a snap root and their tags (M7c T14, V3b).
# Usage: tests/wheel-census.sh <root> <arm64|amd64>
#   Prints <Name>\t<Version>\t<Tags> for each <root>/usr/lib/python3.11/site-packages/*.dist-info
#   (Name and Version from METADATA's header, the WHEEL Tag: lines comma-joined).
#   Exit 1 if a tag not ending in -none-any lacks the arch's machine string, 0 if none,
#   2 on usage error or unreadable input (no site-packages, no dist-info, no METADATA/WHEEL).
set -uo pipefail
[ $# -eq 2 ] || { sed -n '2,7p' "$0" >&2; exit 2; }
case $2 in
  arm64) mach=aarch64 ;;
  amd64) mach=x86_64 ;;
  *) echo "wheel-census: arch must be arm64 or amd64, got: $2" >&2; exit 2 ;;
esac
SP=$1/usr/lib/python3.11/site-packages
[ -d "$SP" ] || { echo "wheel-census: no site-packages under $1" >&2; exit 2; }
shopt -s nullglob; dis=("$SP"/*.dist-info); shopt -u nullglob
[ ${#dis[@]} -gt 0 ] || { echo "wheel-census: no *.dist-info under $SP" >&2; exit 2; }
bad=0
for d in "${dis[@]}"; do
  [ -r "$d/METADATA" ] && [ -r "$d/WHEEL" ] || { echo "wheel-census: METADATA or WHEEL missing: ${d#"$1"/}" >&2; exit 2; }
  # Header only: METADATA's body (after the first blank line) may quote "Name:" lines.
  name=$(awk '/^$/{exit} /^Name: /{sub(/^Name: /,""); sub(/\r$/,""); print; exit}' "$d/METADATA")
  ver=$(awk '/^$/{exit} /^Version: /{sub(/^Version: /,""); sub(/\r$/,""); print; exit}' "$d/METADATA")
  tags=$(sed -n 's/\r$//; s/^Tag: //p' "$d/WHEEL" | paste -sd, -)
  [ -n "$name" ] && [ -n "$ver" ] && [ -n "$tags" ] || { echo "wheel-census: no Name, Version or Tag in ${d#"$1"/}" >&2; exit 2; }
  printf '%s\t%s\t%s\n' "$name" "$ver" "$tags"
  IFS=, read -ra ts <<<"$tags"
  for t in "${ts[@]}"; do
    case $t in *-none-any) ;; *"$mach"*) ;; *) bad=1 ;; esac
  done
done
exit "$bad"
