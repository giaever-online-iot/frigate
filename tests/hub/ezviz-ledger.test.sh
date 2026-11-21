#!/usr/bin/env bash
# shellcheck disable=SC2016  # PRE strings are single-quoted on purpose: run() evals them with its own $T and $n
# tests/hub/ezviz-ledger.sh against a fake hub: the stub ssh runs the remote command with /var/snap/frigate/common
# mapped to $STUB_ST/common (fixtures/ledger-responder.sh). Fixture ledgers only; no camera value exists anywhere.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1; fail=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
FX=$PWD/tests/hub/fixtures; E=1794000000
L() { printf '{"t":%s,"ev":"%s","dur":null}\n' "$(( E + $1 ))" "$2"; }   # L <offset s> <ev>
run() {  # run NAME -- args; PRE seeds $T/$n/st/common/ezviz/state
  local n=$1; shift; [ "$1" = -- ] && shift
  mkdir -p "$T/$n/st/common/ezviz/state"; : > "$T/$n/st/log"; : > "$T/$n/st/cmds"; [ -n "${PRE:-}" ] && eval "$PRE"
  env STUB_ST="$T/$n/st" STUB_RESPONDER="$FX/ledger-responder.sh" M7C_SSH="$FX/stub/ssh" M7C_HUB_SOCK=/run/test/m7c.sock \
    M7C_HUB_TARGET=hub-test timeout 30 bash tests/hub/ezviz-ledger.sh "$@" > "$T/$n.out" 2>&1; echo $? > "$T/$n.rc"
}
rc() { cat "$T/$1.rc"; }; O() { cat "$T/$1.out"; }; S='$T/$n/st/common/ezviz/state'
PRE="{ L 0 attempt; L 2 login_ok; L 9 published; L 3000 stop; L 3010 attempt; L 3012 login_ok; L 3020 published; } > $S/cam1.ledger; { L 0 attempt; L 1 net_fail; L 100 attempt; L 102 login_ok; L 110 published; } > $S/cam2.ledger" run a -- --since $((E + 3005))
check "two healthy ledgers: exit 0" 0 "$(rc a)"
check "cam1 line" "ledger cam1: attempts=2 login_ok=2 published=2 ends=stop:1 open=P3 latched=0 max_attempts_any_60min=2 attempts_since=1 login_ok_since=1 last=published@2026-11-06T22:10:20Z" "$(O a | head -n 1)"
check "cam2 line" "ledger cam2: attempts=2 login_ok=1 published=1 ends=net_fail:1 open=P3 latched=0 max_attempts_any_60min=2 attempts_since=0 login_ok_since=0 last=published@2026-11-06T21:21:50Z" "$(O a | tail -n 1)"
PRE="{ L 0 attempt; L 1 net_fail; L 61 attempt; L 62 net_fail; L 400 attempt; L 401 net_fail; L 3599 attempt; } > $S/cam1.ledger" run b --
check "4 attempts inside one rolling hour: exit 1" 1 "$(rc b)"; check "says 4" 1 "$(O b | grep -c 'max_attempts_any_60min=4')"
PRE="{ L 0 attempt; L 1 auth_fail; L 1 latch; } > $S/cam1.ledger; : > $S/cam1.latch" run c --
check "latched: exit 1" 1 "$(rc c)"; check "latched=1" 1 "$(O c | grep -c 'ledger cam1: .*latched=1')"
PRE="{ L 0 attempt; echo garbage; L 9 stop; } > $S/cam1.ledger" run d --
check "damaged middle line: exit 1, says damaged" "1 ledger cam1: damaged" "$(rc d) $(O d | head -n 1)"
PRE="{ L 0 attempt; L 2 login_ok; printf '{\"t\":'; } > $S/cam1.ledger" run e --
check "torn last line ignored: exit 0" 0 "$(rc e)"; check "torn: last is login_ok" 1 "$(O e | grep -c 'last=login_ok@')"
PRE='touch "$T/$n/st/gone"' run f --; check "master gone: exit 3" 3 "$(rc f)"
run g -- --since x; check "bad --since: exit 2" 2 "$(rc g)"
# --- controller rulings C5, R2-N6, C7: the remote loop only fetches bytes; the laptop parses them with the repo's
# own ezviz_source.ledger.parse and decides latched with policy.decide (no second parser) ---
# recs NAME CAM: "<records> <last ev>" summed from the printed counts (fixtures hold only counted event names)
recs() { O "$1" | awk -v c="$2:" '$1 == "ledger" && $2 == c { n = 0; last = ""
  for (i = 3; i <= NF; i++) { split($i, kv, "=")
    if (kv[1] == "attempts" || kv[1] == "login_ok" || kv[1] == "published") n += kv[2]
    if (kv[1] == "ends" && kv[2] != "-") { m = split(kv[2], e, ","); for (j = 1; j <= m; j++) { split(e[j], q, ":"); n += q[2] } }
    if (kv[1] == "last") { split(kv[2], l, "@"); last = l[1] } }
  print n, last }'; }
PRE="{ L 0 attempt; L 2 login_ok; printf '{\"t\":'; } > $S/cam1.ledger; { L 0 attempt; L 2 login_ok; L 9 published; } > $S/cam2.ledger" run t --
check "C5: torn cam1 and healthy cam2: exit 0" 0 "$(rc t)"
check "C5: cam1 parsed with the torn line dropped" 1 "$(O t | grep -c '^ledger cam1: attempts=1 login_ok=1 published=0 .*last=login_ok@2026-11-06T21:20:02Z$')"
check "C5: cam2 present and correct" "ledger cam2: attempts=1 login_ok=1 published=1 ends=- open=P3 latched=0 max_attempts_any_60min=1 attempts_since=1 login_ok_since=1 last=published@2026-11-06T21:20:09Z" "$(O t | grep '^ledger cam2:')"
PRE="{ L 0 attempt; L 2 login_ok; L 9 published; L 70 stop; L 200 attempt; L 201 net_fail; } > $S/cam1.ledger" run lc --
loc=$(python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from ezviz_source.ledger import parse
r = parse(open(sys.argv[2], "rb").read()); print(len(r), r[-1]["ev"])' spike/ezviz "$T/lc/st/common/ezviz/state/cam1.ledger")
check "a complete last line: the same records as a local ledger.parse of the file" "6 net_fail 6 net_fail" "$loc $(recs lc cam1)"
PRE="{ L 0 attempt; L 2 login_ok; printf '{\"t\":2,\"ev\":\n'; } > $S/cam1.ledger" run tn --
check "a torn last line that kept its newline (C7) is still the torn last line, not damage: exit 0" 0 "$(rc tn)"
check "C7 shape: the records before it are kept" "2 login_ok" "$(recs tn cam1)"
PRE="{ L 0 attempt; L 2 login_ok; L 5 session_end; L 100 attempt; L 102 login_ok; L 105 session_end; L 400 attempt; L 402 login_ok; L 405 session_end; } > $S/cam1.ledger" run n6 --
check "R2-N6: three P2 ends and no latch file: exit 1" 1 "$(rc n6)"
check "R2-N6: latched=1 (policy.decide, T-END latch row)" 1 "$(O n6 | grep -c '^ledger cam1: .*latched=1 ')"
check "R2-N6: the fixture has no latch file" 1 "$([ -e "$T/n6/st/common/ezviz/state/cam1.latch" ] && echo 0 || echo 1)"
PRE="{ L 0 attempt; echo '{\"t\":5}'; L 9 stop; } > $S/cam1.ledger; { L 0 attempt; L 2 login_ok; } > $S/cam2.ledger" run d2 --
check "mid-file bad record: cam1 damaged, exit 1" "1 ledger cam1: damaged" "$(rc d2) $(O d2 | head -n 1)"
check "a damaged cam1 does not hide cam2" 1 "$(O d2 | grep -c '^ledger cam2: attempts=1 login_ok=1 ')"
# m1: the open session's phase (policy.phase_of_open_session); two P2 ends + an open P2 latch at the next decision
PRE="{ L 0 attempt; L 2 login_ok; L 5 session_end; L 100 attempt; L 102 login_ok; L 105 start_timeout; L 400 attempt; L 402 login_ok; } > $S/cam1.ledger; { L 0 attempt; L 1 net_fail; } > $S/cam2.ledger" run op --
check "two P2 ends and an open P2: open=P2 latched=1, exit 1" "1 1" "$(rc op) $(O op | grep -c '^ledger cam1: .* open=P2 latched=1 ')"
check "no open session: open=-" 1 "$(O op | grep -c '^ledger cam2: .* open=- latched=0 ')"
PRE="{ L 0 attempt; echo '== cam2'; L 9 stop; } > $S/cam1.ledger" run m --
check "a ledger line that looks like a header: malformed answer, no counts, exit 1" "1 0" "$(rc m) $(O m | grep -c '^ledger ')"
[ "$fail" = 0 ] && echo "ezviz-ledger.test: all ok" || echo "ezviz-ledger.test: FAILURES"
exit "$fail"
