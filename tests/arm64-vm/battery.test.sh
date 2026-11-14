#!/usr/bin/env bash
# battery.sh argument modes against a stub vm.sh (no VM, no qemu). The stub runs the guest command strings on
# the host with PATH = only fixtures/stub/bin (fake snap, cp, rm, ...), so the host's real snap is unreachable.
# M7C_BATTERY_CHECKS limits the run to V5 plus the named checks, so no scaled waits run.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1; fail=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
has()   { grep -qF -- "$2" "$3"; check "$1" 0 $?; }
hasnt() { grep -qF -- "$2" "$3"; check "$1" 1 $?; }
B=tests/arm64-vm/battery.sh; STUB=tests/arm64-vm/fixtures/stub/vm.sh
SHA=26db6fb77d2214c030bfb9da0b533edb0935cd49d376b010347a607e9b6200f4
OTHER=0000000000000000000000000000000000000000000000000000000000000000
SNAPF=/mnt/out/dl/frigate_0.18.2_arm64.snap
run() {  # run NAME [env...] -- battery args: fresh stub state, rc in $T/NAME.rc, stdout+stderr in $T/NAME.out
  local n=$1; shift; local -a e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  mkdir -p "$T/$n/st" "$T/$n/vm"; : > "$T/$n/st/log"
  env STUB_ST="$T/$n/st" M7C_VM_DIR="$T/$n/vm" M7C_VM_SH="$STUB" SPIKE_TIME_SCALE=1 "${e[@]}" \
    timeout 30 bash "$B" "$@" > "$T/$n.out" 2>&1; echo $? > "$T/$n.rc"
}
rc() { cat "$T/$1.rc"; }; L() { echo "$T/$1/st/log"; }; R() { echo "$T/$1/vm/out/battery/results.txt"; }

# --- usage (exit 2, nothing runs) ---
run u0 -- ;                                   check "no args: exit 2" 2 "$(rc u0)"
run u1 -- --file "$SNAPF";                    check "--file without sha: exit 2" 2 "$(rc u1)"
run u2 -- --file dl/frigate.snap "$SHA";      check "--file relative path: exit 2" 2 "$(rc u2)"
run u3 -- --file "$SNAPF" ABC;                check "--file bad sha: exit 2" 2 "$(rc u3)"
run u4 -- --file '/mnt/out/a b.snap' "$SHA";  check "--file path with a space: exit 2" 2 "$(rc u4)"
run u5 M7C_BATTERY_CHECKS=nope -- latest/edge/pr9; check "unknown check name: exit 2" 2 "$(rc u5)"
check "usage runs no guest command" 0 "$(cat "$T"/u*/st/log | wc -l)"

# --- channel mode (unchanged behaviour) ---
run c1 STUB_INSTALL_RC=1 -- latest/edge/pr9
check "channel, install fails: exit 1" 1 "$(rc c1)"
has   "channel: installs from the channel" "snap install frigate --channel=latest/edge/pr9" "$(L c1)"
hasnt "channel: no sha256 of a file" "sha256sum" "$(L c1)"
has   "channel: V5 FAIL line" "FAIL: V5 install: snap install frigate --channel=latest/edge/pr9 failed" "$(R c1)"
has   "channel: later checks skipped" "FAIL: V17 lifecycle: skipped: install failed" "$(R c1)"
run c2 M7C_BATTERY_CHECKS=v17_lifecycle -- latest/edge/pr9
check "channel, V5+V17: exit 0" 0 "$(rc c2)"
has   "channel: V5 PASS" "PASS: V5 install: 4 plugs connected" "$(R c2)"
has   "channel: F11 auto-connect measured" "INFO: V5 auto-connected at install (F11): none" "$(R c2)"
has   "channel: V17 downloads from the Store" "snap download frigate --channel=latest/edge/pr9" "$(L c2)"
has   "channel: V17 PASS, revert to the Store rev" "PASS: V17 lifecycle: hold rc=0; explicit refresh rc=0; revert -> Store r8" "$(R c2)"

# --- file mode ---
run f1 STUB_SHA="$OTHER" -- --file "$SNAPF" "$SHA"
check "file, sha mismatch: exit 1" 1 "$(rc f1)"
hasnt "file, sha mismatch: nothing installed" "snap install" "$(L f1)"
has   "file, sha mismatch: V5 FAIL names both hashes" "FAIL: V5 install: sha256 of the guest copy of $SNAPF is $OTHER, want $SHA; not installed" "$(R f1)"
run f2 STUB_SHA="$SHA" M7C_BATTERY_CHECKS=v17_lifecycle -- --file "$SNAPF" "$SHA"
check "file, V5+V17: exit 0" 0 "$(rc f2)"
has   "file: copies the file to guest disk" "cp $SNAPF /root/m7c-snap/frigate.snap" "$(L f2)"
has   "file: hashes the copy" "sha256sum /root/m7c-snap/frigate.snap" "$(L f2)"
check "file: hash before the first install" 1 "$(grep -nE '^(sha256sum|snap install)' "$(L f2)" | head -n 1 | grep -c sha256sum)"
has   "file: installs the copy --dangerous" "snap install --dangerous /root/m7c-snap/frigate.snap" "$(L f2)"
check "file: V5 + V17 dangerous + purge cycle = 3 installs" 3 "$(grep -c '^snap install --dangerous /root/m7c-snap/frigate.snap$' "$(L f2)")"
hasnt "file: never a channel" "--channel" "$(L f2)"
hasnt "file: never snap download" "snap download" "$(L f2)"
has   "file: V5 bytes PASS" "PASS: V5 bytes: the guest copy of $SNAPF has sha256 $SHA" "$(R f2)"
has   "file: V5 PASS" "PASS: V5 install: 4 plugs connected" "$(R f2)"
has   "file: F11 not exercised" "INFO: V5 F11 Store auto-connect: not exercised: private snap, no Store in the VM" "$(R f2)"
has   "file: V17 refresh not exercised" "INFO: V17 refresh under hold: not exercised: private snap, no Store in the VM" "$(R f2)"
has   "file: V17 download not exercised" "INFO: V17 snap download: not exercised: private snap, no Store in the VM" "$(R f2)"
has   "file: V17 PASS, revert to the previous local rev" "PASS: V17 lifecycle: hold rc=0; revert -> previous rx1 (dangerous was x2)" "$(R f2)"
run f3 STUB_SHA="$SHA" STUB_REVERT_NOOP=1 M7C_BATTERY_CHECKS=v17_lifecycle -- --file "$SNAPF" "$SHA"
check "file, revert that does not move: exit 1" 1 "$(rc f3)"
has   "file: revert staying on the new rev FAILs" "after revert rx2, want the previous rx1" "$(R f3)"
exit "$fail"
