#!/usr/bin/env bash
# Fake hub for tests/hub/ezviz-ledger.test.sh: runs the remote command for real with /var/snap/frigate/common mapped
# to $STUB_ST/common. Every remote command is logged to $STUB_ST/cmds.
set -u
st="${STUB_ST:?}"
eval "set -- $1"
[ "$1 $2 $3 $4" = "sudo -n sh -c" ] || { echo "responder: not a sudo -n sh -c call: $*" >&2; exit 99; }
printf '%s\n' "$5" >> "$st/cmds"
sh -c "${5//\/var\/snap\/frigate\/common/$st/common}"
