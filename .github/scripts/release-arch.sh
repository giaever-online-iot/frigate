#!/usr/bin/env bash
#
# release-arch.sh — release the CURRENT revision of each allowlisted arch (spec D16).
# Every Store release goes through here; a failed `snapcraft release` fails the job.
#
#   release-arch.sh <from-channel> <to-channel> <arches-csv>
#   release-arch.sh --revision <rev> <to-channel> <arches-csv>
#
# Env: SNAP_NAME (default frigate), SR (default: snap-release.sh next to this script).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SR="${SR:-$HERE/snap-release.sh}"
SNAP_NAME="${SNAP_NAME:-frigate}"

if [ "${1:-}" = "--revision" ]; then
  [ $# -eq 4 ] || { echo "usage: release-arch.sh --revision <rev> <to-channel> <arches-csv>" >&2; exit 2; }
  REV="$2"; TO="$3"; ARCHES="$4"
  REVS=$(snapcraft revisions "$SNAP_NAME")
  a=$("$SR" arch-of "$REV" <<<"$REVS") || { echo "::error::revision $REV not found for $SNAP_NAME" >&2; exit 1; }
  if [ "$("$SR" in-list "$a" "$ARCHES")" != "yes" ]; then
    echo "::error::revision $REV is $a, not in $ARCHES"
    exit 1
  fi
  echo ">> releasing revision $REV ($a) -> $TO"
  snapcraft release "$SNAP_NAME" "$REV" "$TO"  # must fail the job
  exit 0
fi

[ $# -eq 3 ] || { echo "usage: release-arch.sh <from-channel> <to-channel> <arches-csv>" >&2; exit 2; }
FROM="$1"; TO="$2"; ARCHES="$3"
REVS=$(snapcraft revisions "$SNAP_NAME")
IFS=',' read -ra LIST <<<"$ARCHES"
DONE=0
for a in "${LIST[@]}"; do
  r=$("$SR" revisions-in "$FROM" "$a" <<<"$REVS" | head -1)
  if [ -z "$r" ]; then
    echo "no current $a revision in $FROM; skipping $a"
    continue
  fi
  echo ">> releasing $a revision $r: $FROM -> $TO"
  snapcraft release "$SNAP_NAME" "$r" "$TO"  # must fail the job
  DONE=$((DONE + 1))
done
if [ "$DONE" -eq 0 ]; then  # zero-release guard
  echo "::error::no current revision for $ARCHES in $FROM: nothing released"
  exit 1
fi
