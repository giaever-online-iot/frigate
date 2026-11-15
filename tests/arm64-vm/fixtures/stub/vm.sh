#!/bin/bash
# Stub vm.sh for battery.test.sh: `exec CMD` runs CMD with /bin/sh on the HOST, but with PATH set to ONLY
# the fake-tools dir beside this file. Bare `snap`, `cp`, `rm`, ... resolve to the fakes, so a guest command
# can never reach the host's real snap (the battery's V5/V17 commands use no absolute tool paths). Shell
# builtins (`test -d`) would still see the host, so /dev/shm/snap.frigate is mapped to $STUB_ST/shm/snap.frigate
# in the command (the fake ls maps it back in its output). State and the call log live in $STUB_ST (required).
set -u
[ -n "${STUB_ST:-}" ] && [ -d "$STUB_ST" ] || { echo "stub vm.sh: set STUB_ST to a dir" >&2; exit 2; }
F="$(cd "$(dirname "$0")" && pwd)/bin"
case "${1:-}" in
  exec) shift; c=$*; c=${c//\/dev\/shm\/snap.frigate/$STUB_ST/shm/snap.frigate}
        exec env -i PATH="$F" STUB_ST="$STUB_ST" STUB_SHA="${STUB_SHA:-}" \
          STUB_INSTALL_RC="${STUB_INSTALL_RC:-0}" STUB_REVERT_NOOP="${STUB_REVERT_NOOP:-}" /bin/sh -c "$c" ;;
  *) echo "stub vm.sh: only exec" >&2; exit 2 ;;
esac
