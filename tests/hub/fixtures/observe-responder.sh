#!/usr/bin/env bash
# Fake hub for tests/hub/observe.test.sh (the stub ssh's $STUB_RESPONDER). $1 = "sudo -n sh -c '<cmd>'". The
# command runs FOR REAL under /bin/sh with fixtures/observe-stub first on PATH (systemctl, sleep, date, nc, snap),
# so observe.sh's own sample script is what is tested; M7C_OBSERVE_ROOT points it at a fake /proc, /sys and
# /dev/shm tree. Every <cmd> is appended to $STUB_ST/cmds. stdin passes through (the /stats python script).
set -u
st="${STUB_ST:?}"; fx=$(cd "$(dirname "$0")" && pwd)
eval "set -- $1"
[ "$1 $2 $3 $4" = "sudo -n sh -c" ] || { echo "responder: not a sudo -n sh -c call: $*" >&2; exit 99; }
cmd=$5; printf '%s\n' "$cmd" >> "$st/cmds"
PATH="$fx/observe-stub:$PATH" exec sh -c "$cmd"
