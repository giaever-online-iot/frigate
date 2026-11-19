#!/usr/bin/env bash
# Fake hub for tests/hub/power-check.test.sh (the stub ssh's $STUB_RESPONDER). Every remote command is logged to
# $STUB_ST/cmds and then RUN FOR REAL under /bin/sh with fixtures/power-stub first on PATH (a fake journalctl that
# parses its argv and answers only the forms power-check.sh must send; see its header for the knobs PC_KRC, PC_COVER,
# PC_UV, PC_BOOTS, PC_GARBLE). PC_RAW=<text>: answer <text> instead of running the command (a hub whose shell
# answer cannot be parsed).
set -u
st="${STUB_ST:?}"; fx=$(cd "$(dirname "$0")" && pwd)
eval "set -- $1"
[ "$1 $2 $3 $4" = "sudo -n sh -c" ] || { echo "responder: not a sudo -n sh -c call: $*" >&2; exit 99; }
printf '%s\n' "$5" >> "$st/cmds"
[ -n "${PC_RAW:-}" ] && { printf '%s\n' "$PC_RAW"; exit 0; }
PATH="$fx/power-stub:$PATH" exec sh -c "$5"
