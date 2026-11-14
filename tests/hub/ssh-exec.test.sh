#!/usr/bin/env bash
# shellcheck disable=SC2016  # the PRE strings are single-quoted on purpose: run() evals them with its own $T and $n
# tests/hub/ssh-exec.sh against a fake ssh (fixtures/stub/ssh): no network, no master, no hub.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1; fail=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
has()   { grep -qF -- "$2" "$3"; check "$1" 0 $?; }
hasnt() { grep -qF -- "$2" "$3"; check "$1" 1 $?; }
X=tests/hub/ssh-exec.sh; STUB=$PWD/tests/hub/fixtures/stub/ssh
run() {  # run NAME [env...] -- args: fresh stub state; rc in $T/NAME.rc, stdout in .out, stderr in .err
  local n=$1; shift; local -a e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  mkdir -p "$T/$n"; : > "$T/$n/log"
  [ -n "${PRE:-}" ] && eval "$PRE"
  env STUB_ST="$T/$n" M7C_SSH="$STUB" M7C_HUB_SOCK=/run/test/m7c.sock M7C_HUB_TARGET=hub-test "${e[@]}" \
    timeout 30 bash "$X" "$@" > "$T/$n.out" 2> "$T/$n.err" < "${IN:-/dev/null}"; echo $? > "$T/$n.rc"
}
rc() { cat "$T/$1.rc"; }; L() { echo "$T/$1/log"; }
sessions() { grep -vc $'\t-O\tcheck\t' "$(L "$1")"; }

# --- usage and environment ---
run e1 M7C_HUB_SOCK= -- check;         check "no socket env: exit 2" 2 "$(rc e1)"
run e2 M7C_HUB_TARGET= -- check;       check "no target env: exit 2" 2 "$(rc e2)"
run e3 M7C_HUB_TIMEOUT=abc -- check;   check "bad timeout: exit 2" 2 "$(rc e3)"
run e4 -- frob;                        check "unknown subcommand: exit 2" 2 "$(rc e4)"
run e5 -- exec;                        check "exec without a command: exit 2" 2 "$(rc e5)"
check "usage and env errors make no session" 0 "$(cat "$T"/e?/log | grep -vc $'\t-O\tcheck\t')"

# --- master gone: exit 3, loud, no session attempted ---
PRE='touch "$T/$n/gone"' run g1 -- exec 'echo hi'
check "master gone: exec exits 3" 3 "$(rc g1)"
has   "master gone: says so" "MASTER GONE" "$T/g1.err"
check "master gone: no session attempted" 0 "$(sessions g1)"
PRE='touch "$T/$n/gone"' run g2 -- check;   check "master gone: check exits 3" 3 "$(rc g2)"

# --- the ssh options: master only, never a new connection ---
run o1 -- exec true
check "exec true: rc 0" 0 "$(rc o1)"
for want in $'-F\t/dev/null' $'-S\t/run/test/m7c.sock' $'-o\tControlMaster=no' $'-o\tProxyCommand=/bin/false' $'-o\tBatchMode=yes'; do
  check "every call carries ${want//$'\t'/ }" "$(wc -l < "$(L o1)")" "$(grep -cF -- "$want" "$(L o1)")"
done
hasnt "never ControlMaster=auto/yes" "ControlMaster=auto" "$(L o1)"
has   "session runs as root via sudo -n sh -c" $'hub-test\tsudo -n sh -c' "$(L o1)"

# --- exec: quoting round trip and rc ---
CMD=$(cat <<'EOF'
a="it's"; b='x y'; printf '%s|%s|%s\n' "$a" "$b" "$(echo '$HOME' "\$x")"
echo "line2;semi" `echo bq` \\ end
EOF
)
run q1 -- exec "$CMD"
check "quoting: rc 0" 0 "$(rc q1)"
check "quoting: output identical to a local sh -c" "$(sh -c "$CMD")" "$(cat "$T/q1.out")"
run r1 -- exec 'exit 7';        check "exec returns the remote rc" 7 "$(rc r1)"
run r2 -- exec 'exit 255';      check "remote rc 255 with the master alive stays 255" 255 "$(rc r2)"
PRE='echo 0 > "$T/$n/die-after"' run r3 -- exec 'echo never'
check "master dies during exec: exit 3" 3 "$(rc r3)"
has   "master dies during exec: says so" "MASTER GONE" "$T/r3.err"
run t1 M7C_HUB_TIMEOUT=1 -- exec 'sleep 5'
check "timeout: exit 124" 124 "$(rc t1)"; has "timeout: says so" "TIMEOUT after 1s" "$T/t1.err"

# --- put: exact bytes, 0600, atomic, sha checked on the hub ---
printf 'payload\n with a line\n' > "$T/src.bin"; W=$(sha256sum "$T/src.bin" | awk '{print $1}')
D="$T/hub/dir/sub"
IN="$T/src.bin" run p1 -- put "$T/src.bin" "$D/f.snap"
check "put: rc 0" 0 "$(rc p1)"
check "put: bytes identical" "$W" "$(sha256sum "$D/f.snap" | awk '{print $1}')"
check "put: mode 0600" 600 "$(stat -c %a "$D/f.snap")"
check "put: no .m7c-part left" 0 "$(find "$D" -name '*.m7c-part' | wc -l)"
has   "put: PUT OK with the sha" "PUT OK $D/f.snap sha256 $W" "$T/p1.out"
PRE='touch "$T/$n/corrupt"' IN="$T/src.bin" run p2 -- put "$T/src.bin" "$D/g.snap"
check "put, damaged copy: exit 1" 1 "$(rc p2)"
has   "put, damaged copy: SHA MISMATCH" "SHA MISMATCH" "$T/p2.err"
check "put, damaged copy: the bad file is removed" 1 "$([ -e "$D/g.snap" ]; echo $?)"
run p3 -- put "$T/src.bin" relative/f;          check "put: relative hub path: exit 2" 2 "$(rc p3)"
run p4 -- put "$T/src.bin" "$T/a b";            check "put: hub path with a space: exit 2" 2 "$(rc p4)"
run p5 -- put "$T/src.bin" "$T/x/../y";         check "put: hub path with ..: exit 2" 2 "$(rc p5)"
run p6 -- put "$T/missing" "$D/h";              check "put: missing local file: exit 2" 2 "$(rc p6)"
check "put: bad paths make no session" 0 "$(cat "$T"/p[3-6]/log | grep -vc $'\t-O\tcheck\t')"

# --- sha ---
run s1 -- sha "$D/f.snap" "$W";   check "sha match: rc 0" 0 "$(rc s1)"
run s2 -- sha "$D/f.snap" "$(printf '0%.0s' $(seq 64))"; check "sha mismatch: rc 1" 1 "$(rc s2)"
run s3 -- sha "$D/f.snap" ABC;    check "sha: bad sha: exit 2" 2 "$(rc s3)"

[ "$fail" = 0 ] && echo "ssh-exec.test: all ok" || echo "ssh-exec.test: FAILURES"
exit "$fail"
