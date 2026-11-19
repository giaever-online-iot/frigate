#!/usr/bin/env bash
# Fake hub for tests/hub/coverage.test.sh. Logs every remote command and its stdin (the python sent to the snap's
# shell) to $STUB_ST; answers with $STUB_ST/answer (fixture JSON lines) when the command is the snap-shell call.
set -u
st="${STUB_ST:?}"
eval "set -- $1"
[ "$1 $2 $3 $4" = "sudo -n sh -c" ] || { echo "responder: not a sudo -n sh -c call: $*" >&2; exit 99; }
printf '%s\n' "$5" >> "$st/cmds"; cat > "$st/stdin"
case "$5" in 'snap run --shell frigate.frigate -c '*) cat "$st/answer" ;; *) echo "unexpected command"; exit 1 ;; esac
