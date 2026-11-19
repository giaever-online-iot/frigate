#!/usr/bin/env bash
# shellcheck disable=SC2016  # PRE strings are single-quoted on purpose: run() evals them with its own $T and $n
# tests/hub/coverage.sh against a fake hub (fixtures/coverage-responder.sh answers fixture JSON; no Frigate).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1; fail=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
FX=$PWD/tests/hub/fixtures; E=1794000000; D=86400
seg() { printf '[%s,%s]' "$((E + $1))" "$((E + $2))"; }
ans() { printf '{"cam":"cam1","segments":[%s]}\n{"cam":"cam2","segments":[%s]}\n' "$1" "$2"; }
run() {  # run NAME -- args; ANS is the fixture answer
  local n=$1; shift; [ "$1" = -- ] && shift
  mkdir -p "$T/$n/st"; : > "$T/$n/st/log"; : > "$T/$n/st/cmds"; printf '%s' "${ANS:-}" > "$T/$n/st/answer"; [ -n "${PRE:-}" ] && eval "$PRE"
  env STUB_ST="$T/$n/st" STUB_RESPONDER="$FX/coverage-responder.sh" M7C_SSH="$FX/stub/ssh" M7C_HUB_SOCK=/run/test/m7c.sock \
    M7C_HUB_TARGET=hub-test timeout 30 bash tests/hub/coverage.sh "$@" > "$T/$n.out" 2>&1; echo $? > "$T/$n.rc"
}
rc() { cat "$T/$1.rc"; }; O() { cat "$T/$1.out"; }
ANS=$(ans "$(seg 0 43000),$(seg 43000 $((D - 360)))" "$(seg -100 $((D + 100)))") run a -- --since $E
check "23.9 of 24 h and full: exit 0" 0 "$(rc a)"; check "cam1 99.6 %" "coverage cam1: 99.6 %" "$(O a | head -n 1)"; check "cam2 clipped to 100.0 %" "coverage cam2: 100.0 %" "$(O a | tail -n 1)"
ANS=$(ans "$(seg 0 40000),$(seg 41800 $D)" "$(seg 0 $D)") run b -- --since $E
check "a 30 min gap: exit 1" 1 "$(rc b)"; check "cam1 97.9 %" "coverage cam1: 97.9 %" "$(O b | head -n 1)"
ANS=$(ans "$(seg 0 50000),$(seg 10000 60000),$(seg 59000 $D)" "$(seg 0 $D)") run c -- --since $E
check "overlaps are not double-counted" "coverage cam1: 100.0 %" "$(O c | head -n 1)"
ANS='{"cam":"cam1","error":"URLError"}' run d -- --since $E
check "unreadable API and a missing camera: exit 1" 1 "$(rc d)"; check "both unreadable" 2 "$(O d | grep -c ': unreadable')"
ANS=$(ans "$(seg 0 $D)" "$(seg 0 $D)") run e -- --since $E
check "only numbers printed" 0 "$(O e | grep -cvE '^coverage cam[12]: [0-9.]+ %$')"
# The route on Frigate's internal :5001 has no /api prefix: v0.18.2 frigate/api/record.py L226
# `@router.get("/{camera_name}/recordings")`, routers included without a prefix (fastapi_app.py L151), uvicorn with
# no root_path (app.py L621-640); tests/m9-rehearsal.sh calls :5001/<camera>/recordings the same way.
check "the hub gets the snap's python on stdin, no camera value" 1 "$(grep -c '127.0.0.1:5001/%s/recordings?after=1794000000&before=1794086400' "$T/e/st/stdin")"
check "the route on :5001 has no nginx /api prefix" 0 "$(grep -c '5001/api/' "$T/e/st/stdin")"
PRE='touch "$T/$n/st/gone"' run f -- --since $E; check "master gone: exit 3" 3 "$(rc f)"
run g -- --since $E --hours 0; check "--hours 0: exit 2" 2 "$(rc g)"
[ "$fail" = 0 ] && echo "coverage.test: all ok" || echo "coverage.test: FAILURES"
exit "$fail"
