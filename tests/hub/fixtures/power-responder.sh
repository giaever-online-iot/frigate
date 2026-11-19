#!/usr/bin/env bash
# Fake hub for tests/hub/power-check.test.sh (the stub ssh's $STUB_RESPONDER). Every remote command is logged to
# $STUB_ST/cmds. Knobs: PC_KRC (journalctl rc, default 0), PC_COVER (1 = the journal reaches back, default 1),
# PC_UV (undervoltage lines, default 0), PC_BOOTS (boots in the window, default 0), PC_GARBLE=1 (unparsable answer).
set -u
st="${STUB_ST:?}"
eval "set -- $1"
[ "$1 $2 $3 $4" = "sudo -n sh -c" ] || { echo "responder: not a sudo -n sh -c call: $*" >&2; exit 99; }
printf '%s\n' "$5" >> "$st/cmds"
[ "${PC_GARBLE:-0}" = 1 ] && { echo "journalctl: command not found"; exit 0; }
printf 'krc=%s\ncover=%s\nuv=%s\nboots=%s\n' "${PC_KRC:-0}" "${PC_COVER:-1}" "${PC_UV:-0}" "${PC_BOOTS:-0}"
