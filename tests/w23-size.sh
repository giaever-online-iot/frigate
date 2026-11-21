#!/usr/bin/env bash
# W-23 T20: snap size delta gate. Usage: tests/w23-size.sh <base.snap> <new.snap>
# Prints "size: base=<B> new=<B> delta=<B>"; exit 1 if delta > 35,000,000 B (spec estimate ~+28 MB, 25 % headroom), 2 on usage.
set -uo pipefail
LIMIT=35000000
[ "$#" -eq 2 ] && [ -f "$1" ] && [ -f "$2" ] || { echo "usage: $0 <base.snap> <new.snap>" >&2; exit 2; }
base=$(stat -c %s "$1") || exit 2
new=$(stat -c %s "$2") || exit 2
delta=$((new - base))
echo "size: base=$base new=$new delta=$delta"
[ "$delta" -le "$LIMIT" ] || { echo "size: delta $delta exceeds limit $LIMIT" >&2; exit 1; }
