#!/usr/bin/env bash
# tests/hub/probe.sh against a fake hub: ssh-exec.sh -> fixtures/stub/ssh -> fixtures/probe-responder.sh.
# No network, no master, no hub.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1; fail=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
has()   { grep -qF -- "$2" "$3"; check "$1" 0 $?; }
hasnt() { grep -qF -- "$2" "$3"; check "$1" 1 $?; }
P=tests/hub/probe.sh; STUB=$PWD/tests/hub/fixtures/stub/ssh; RESP=$PWD/tests/hub/fixtures/probe-responder.sh
SHA=26db6fb77d2214c030bfb9da0b533edb0935cd49d376b010347a607e9b6200f4
run() {  # run NAME [env...] -- probe args: fresh stub state; rc, combined output, evidence dir per NAME
  local n=$1; shift; local -a e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  mkdir -p "$T/$n/st"; : > "$T/$n/st/log"; : > "$T/$n/st/cmds"
  env STUB_ST="$T/$n/st" STUB_RESPONDER="$RESP" M7C_SSH="$STUB" M7C_HUB_SOCK=/run/test/m7c.sock M7C_HUB_TARGET=hub-test \
    "${e[@]}" timeout 30 bash "$P" --out "$T/$n/ev" "$@" > "$T/$n.out" 2>&1; echo $? > "$T/$n.rc"
}
rc() { cat "$T/$1.rc"; }; C() { echo "$T/$1/st/cmds"; }; RES() { echo "$T/$1/ev/results.txt"; }

# --- usage ---
run u1 -- --frob;            check "unknown option: exit 2" 2 "$(rc u1)"
run u2 -- --sha ABC;         check "bad --sha: exit 2" 2 "$(rc u2)"
check "usage sends no hub command" 0 "$(cat "$T"/u?/st/cmds | wc -l)"

# --- happy path: every check PASSes ---
run h1 -- --sha "$SHA"
check "all good: exit 0" 0 "$(rc h1)"
has   "version PASS" "PASS: V5 version: frigate 0.18.2 rx1 installed" "$(RES h1)"
has   "bytes PASS" "PASS: V5 bytes: /var/lib/snapd/snaps/frigate_x1.snap has sha256 $SHA" "$(RES h1)"
has   "plugs PASS" "PASS: V5 plugs: raw-usb hardware-observe mount-observe shm-private connected" "$(RES h1)"
has   "layout PASS" "PASS: V5 layout: /etc/OpenCL/vendors and intel-opencl each list exactly .keep (D7)" "$(RES h1)"
has   "V6 PASS" "PASS: V6 runtime: 18 imports ok (sqlite_vec incl.); hevc decoders=4; ffprobe version n8" "$(RES h1)"
has   "V18 PASS (the delegate loads and infers)" "PASS: V18 edgetpu (hub, Coral present): dlopen ok from /snap/frigate/x1/usr/lib/aarch64-linux-gnu/libedgetpu.so.1; load_delegate ok; inference ok" "$(RES h1)"
has   "V18 USB id INFO" "INFO: V18 Coral USB id before: 1a6e:089a; after: 18d1:9302" "$(RES h1)"
has   "summary line" "probe: 6 PASS, 0 FAIL" "$T/h1.out"
has   "tensorflow import runs under nice -n 19" "nice -n 19 snap run frigate.imports-probe" "$(C h1)"
hasnt "no unexpected hub command" "unexpected command" "$T/h1.out"
run h2 --
check "no --sha: exit 0" 0 "$(rc h2)"
has   "no --sha: bytes INFO not checked" "INFO: V5 bytes: not checked (no --sha given)" "$(RES h2)"

# --- precondition: installed and STOPPED, else nothing runs ---
run s1 P_ACTIVE=frigate.nginx --
check "a frigate service active: exit 1" 1 "$(rc s1)"
has   "says which service" "FAIL: precondition: frigate services must be stopped; active: frigate.nginx" "$(RES s1)"
hasnt "no probe ran" "imports-probe" "$(C s1)"; hasnt "no coral probe ran" "coral-probe" "$(C s1)"
run s2 P_INSTALLED=0 --
check "not installed: exit 1" 1 "$(rc s2)"
has   "not installed: says so" "FAIL: precondition: frigate is not installed" "$(RES s2)"
hasnt "not installed: no probe ran" "imports-probe" "$(C s2)"

# --- each check fails on its own ---
run f1 -- --sha "$(printf '0%.0s' $(seq 64))"
check "wrong bytes: exit 1" 1 "$(rc f1)"; has "wrong bytes: FAIL" "FAIL: V5 bytes: /var/lib/snapd/snaps/frigate_x1.snap has sha256 $SHA, want 0000" "$(RES f1)"
run f2 P_UNCON=raw-usb --
check "a plug unconnected: exit 1" 1 "$(rc f2)"; has "plug FAIL names it" "FAIL: V5 plugs: not connected: raw-usb" "$(RES f2)"
run f3 P_IMPORT_BAD=cv2 --
check "an import fails: exit 1" 1 "$(rc f3)"; has "V6 FAIL names it" "FAIL: V6 runtime: imports not all ok (cv2)" "$(RES f3)"
run f4 P_CORAL=nodev --
check "delegate does not load: exit 1" 1 "$(rc f4)"; has "V18 FAIL quotes the error" "FAIL: V18 edgetpu (hub, Coral present): load_delegate failed: ValueError: Failed to load delegate" "$(RES f4)"
run f5 P_CORAL=noinfer --
check "inference fails: exit 1" 1 "$(rc f5)"; has "V18 FAIL inference" "inference failed: RuntimeError: boom" "$(RES f5)"
run f6 P_CORAL=absent --
check "no Coral on the bus: exit 1" 1 "$(rc f6)"; has "V18 FAIL no Coral id" "FAIL: V18 edgetpu (hub, Coral present): no Coral USB id (1a6e:089a or 18d1:9302) before the probe" "$(RES f6)"

# --- scrub: no password line, no URL credential, in any output or evidence file ---
run k1 P_LEAK=1 --
check "leak run still passes" 0 "$(rc k1)"
check "no password in evidence or output" 0 "$(cat "$T/k1/ev"/* "$T/k1.out" | grep -ci 'hunter2\|password')"
check "no URL credential in evidence or output" 0 "$(cat "$T/k1/ev"/* "$T/k1.out" | grep -c 'pw123')"

# --- master lost: LOUD, exit 3, no further checks ---
mkdir -p "$T/m2/st"; : > "$T/m2/st/gone"; : > "$T/m2/st/cmds"
env STUB_ST="$T/m2/st" STUB_RESPONDER="$RESP" M7C_SSH="$STUB" M7C_HUB_SOCK=/run/test/m7c.sock M7C_HUB_TARGET=hub-test \
  timeout 30 bash "$P" --out "$T/m2/ev" > "$T/m2.out" 2>&1; echo $? > "$T/m2.rc"
check "master gone at start: exit 3" 3 "$(rc m2)"; has "master gone: loud" "MASTER GONE" "$T/m2.out"
mkdir -p "$T/m3/st"; echo 4 > "$T/m3/st/die-after"; : > "$T/m3/st/cmds"
env STUB_ST="$T/m3/st" STUB_RESPONDER="$RESP" M7C_SSH="$STUB" M7C_HUB_SOCK=/run/test/m7c.sock M7C_HUB_TARGET=hub-test \
  timeout 30 bash "$P" --out "$T/m3/ev" > "$T/m3.out" 2>&1; echo $? > "$T/m3.rc"
check "master dies mid-probe: exit 3" 3 "$(rc m3)"; has "master dies: loud" "MASTER GONE" "$T/m3.out"
hasnt "master dies: no PASS/FAIL summary claimed" " PASS, " "$T/m3.out"
hasnt "master dies: later probes not sent" "coral-probe" "$(C m3)"

[ "$fail" = 0 ] && echo "probe.test: all ok" || echo "probe.test: FAILURES"
exit "$fail"
