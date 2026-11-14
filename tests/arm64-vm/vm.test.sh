#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")" || exit 1; fail=0; D=$(mktemp -d); SLP=""; BYS=""
cleanup() { rm -rf "$D"; local p; for p in $SLP $BYS; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
M7C_VM_DIR='' ./vm.sh status >/dev/null 2>&1;               check "M7C_VM_DIR required" 2 $?
sleep 300 & SLP=$!; sleep 300 & BYS=$!; echo "$SLP" > "$D/qemu.pid"
out=$(M7C_VM_DIR="$D" ./vm.sh up 2>&1);                   check "up refuses a live pid" 1 $?
grep -q "already running (pid $SLP)" <<<"$out";           check "names the pid" 0 $?
M7C_VM_DIR="$D" VM_DOWN_WAIT=1 ./vm.sh down >/dev/null 2>&1; check "down exit 0" 0 $?
kill -0 "$SLP" 2>/dev/null;                               check "down killed the recorded pid" 1 $?
kill -0 "$BYS" 2>/dev/null;                               check "down left a bystander alive" 0 $?
test -e "$D/qemu.pid";                                    check "pidfile removed" 1 $?
echo 999999 > "$D/qemu.pid"
M7C_VM_DIR="$D" VM_DRY_RUN=1 ./vm.sh up >"$D/cmd" 2>&1;   check "stale pidfile cleaned, dry run ok" 0 $?
grep -q -- '-cpu cortex-a76' "$D/cmd";                    check "D22 cpu model" 0 $?
grep -q -- '-accel tcg,thread=multi' "$D/cmd";            check "MTTCG" 0 $?
grep -q -- '-cpu max' "$D/cmd";                           check "never -cpu max" 1 $?
grep -q 'org.qemu.guest_agent.0' "$D/cmd";                check "guest agent channel" 0 $?
grep -qE 'hostfwd|-nic user.*22' "$D/cmd";                check "no port forward" 1 $?
grep -qE '^IMG_SERIAL="[0-9]{8}(\.[0-9]+)?"$' ./vm.sh;    check "IMG_SERIAL pinned to a dated serial" 0 $?
# wait: a guest agent that accepts but never replies must end at the loop deadline, not hang (T11 S5)
rm -f "$D/qemu.pid" "$D/qga.sock"; sleep 300 & WP=$!; echo "$WP" > "$D/qemu.pid"; BYS="$BYS $WP"
python3 -I -c 'import socket,sys,time
s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.listen(5);time.sleep(120)' "$D/qga.sock" & FAKE=$!; BYS="$BYS $FAKE"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$D/qga.sock" ] && break; command sleep 0.2; done
t0=$(date +%s); out=$(M7C_VM_DIR="$D" VM_WAIT_S=3 timeout 60 ./vm.sh wait 2>&1); rc=$?; el=$(( $(date +%s) - t0 ))
check "wait exits 1 when the agent never answers" 1 $rc
grep -q "guest agent never answered" <<<"$out";           check "wait says guest agent never answered" 0 $?
[ "$el" -lt 40 ];                                         check "wait bounded (${el}s)" 0 $?
exit "$fail"
