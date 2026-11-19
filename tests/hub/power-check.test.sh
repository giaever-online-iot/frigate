#!/usr/bin/env bash
# tests/hub/power-check.sh against a fake hub (ssh-exec.sh -> fixtures/stub/ssh -> fixtures/power-responder.sh).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1; fail=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
FX=$PWD/tests/hub/fixtures; E=1794000000
run() {  # run NAME [env...] -- args
  local n=$1; shift; local -a e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  mkdir -p "$T/$n/st"; : > "$T/$n/st/log"; : > "$T/$n/st/cmds"; [ -n "${PRE:-}" ] && eval "$PRE"
  env STUB_ST="$T/$n/st" STUB_RESPONDER="$FX/power-responder.sh" M7C_SSH="$FX/stub/ssh" M7C_HUB_SOCK=/run/test/m7c.sock \
    M7C_HUB_TARGET=hub-test "${e[@]}" timeout 30 bash tests/hub/power-check.sh "$@" > "$T/$n.out" 2>&1; echo $? > "$T/$n.rc"
}
rc() { cat "$T/$1.rc"; }; O() { cat "$T/$1.out"; }
run p0 -- --since $E;            check "clean: exit 0" 0 "$(rc p0)"; check "clean: PASS last" "power-check: PASS" "$(O p0 | tail -n 1)"
check "clean: names the window and counts" "power-check: since 2026-11-06T21:20:00Z: undervoltage lines 0, boots 0 (allowed 0)" "$(O p0 | head -n 1)"
check "reads the kernel transport across boots (no -k, no -b)" "1 0" "$(grep -c '_TRANSPORT=kernel --since @1794000000' "$T/p0/st/cmds") $(grep -cE 'journalctl (-k|-b|--dmesg)' "$T/p0/st/cmds")"
run p1 PC_UV=2 -- --since $E;    check "undervoltage (any boot in the window): exit 1" 1 "$(rc p1)"; check "says 2" 1 "$(O p1 | grep -c 'undervoltage lines 2')"
run p2 PC_KRC=1 -- --since $E;   check "journalctl fails: INCONCLUSIVE exit 4, never 0" 4 "$(rc p2)"
run p3 PC_COVER=0 -- --since $E; check "journal does not reach back: exit 4" 4 "$(rc p3)"
run p4 PC_GARBLE=1 -- --since $E; check "unparsable answer: exit 4" 4 "$(rc p4)"
run p5 PC_BOOTS=1 -- --since $E; check "an unplanned boot in the window: exit 1" 1 "$(rc p5)"
run p6 PC_BOOTS=1 -- --since $E --allow-boots 1; check "a planned boot (S11): exit 0" 0 "$(rc p6)"
PRE='touch "$T/$n/st/gone"' run p7 -- --since $E; check "master gone: exit 3" 3 "$(rc p7)"
run p8 -- --since 12x;           check "bad --since: exit 2" 2 "$(rc p8)"; check "usage sends nothing" 0 "$(wc -l < "$T/p8/st/cmds")"
[ "$fail" = 0 ] && echo "power-check.test: all ok" || echo "power-check.test: FAILURES"
exit "$fail"
