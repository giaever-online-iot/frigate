#!/usr/bin/env bash
# Hermetic test of the W-23 additions to snap/hooks/configure: disk-floor-gib validation and the ezviz unlatch.
# Stub snapctl on PATH; $SNAP/opt/ezviz-py is a throwaway venv (no pip, no wheels) whose .pth points at spike/ezviz,
# so the hook's `python3.12 -I -B -m ezviz_source.unlatch` runs the real module. Run: bash tests/configure-ezviz.test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD; FAILS=0; SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; FAILS=$((FAILS+1)); fi; }
python3 -m venv --without-pip "$SB/venv" >/dev/null || { echo "SKIP - configure-ezviz.test: python3 -m venv unavailable"; exit 0; }
[ -x "$SB/venv/bin/python3.12" ] || ln -s "$(readlink -f "$SB/venv/bin/python3")" "$SB/venv/bin/python3.12"
"$SB/venv/bin/python3" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])' | { read -r sp; echo "$REPO/spike/ezviz" > "$sp/ezviz_source.pth"; }
mkdir -p "$SB/bin"
cat > "$SB/bin/snapctl" <<'EOF'
#!/bin/sh
echo "$*" >> "$CFG_LOG"
case "$*" in
  "get -d ezviz") printf '%s\n' "${CFG_EZVIZ:-{\}}" ;;
  "get disk-floor-gib") [ -n "${CFG_FLOOR:-}" ] && echo "$CFG_FLOOR"; exit 0 ;;
  "get ports.https") [ -n "${CFG_PORTS:-}" ] && echo "$CFG_PORTS"; exit 0 ;;
  get\ *) exit 0 ;;
esac
EOF
chmod +x "$SB/bin/snapctl"
run() {  # run NAME [env...]: one hook run with a fresh $SNAP/$SNAP_COMMON
  local n=$1; shift; local c="$SB/$n"; mkdir -p "$c/snap/opt" "$c/common/ezviz/state" "$c/data"
  ln -s "$SB/venv" "$c/snap/opt/ezviz-py"; : > "$c/log"; [ -n "${PRE:-}" ] && eval "$PRE"
  env PATH="$SB/bin:$PATH" SNAP="$c/snap" SNAP_COMMON="$c/common" SNAP_DATA="$c/data" CFG_LOG="$c/log" "$@" \
    sh snap/hooks/configure > "$c/out" 2>&1; echo $? > "$c/rc"
}
rc() { cat "$SB/$1/rc"; }; out() { cat "$SB/$1/out"; }
run f1 CFG_FLOOR=abc;   check "disk-floor-gib=abc: exit 1" 1 "$(rc f1)"; check "says integer 1-10000" 1 "$(out f1 | grep -c 'disk-floor-gib must be an integer 1-10000')"
run f2 CFG_FLOOR=0;     check "disk-floor-gib=0: exit 1" 1 "$(rc f2)"
run f3 CFG_FLOOR=10001; check "disk-floor-gib=10001: exit 1" 1 "$(rc f3)"
run f4 CFG_FLOOR=20;    check "disk-floor-gib=20: exit 0" 0 "$(rc f4)"
run f5;                 check "unset: exit 0" 0 "$(rc f5)"
# shellcheck disable=SC2016  # expanded by eval inside run()
PRE='printf "{\"t\":1,\"ev\":\"attempt\",\"dur\":null}\n{\"t\":2,\"ev\":\"auth_fail\",\"dur\":null}\n{\"t\":2,\"ev\":\"latch\",\"dur\":null}\n" > "$c/common/ezviz/state/cam1.ledger"; : > "$c/common/ezviz/state/cam1.latch"' \
  run u1 CFG_EZVIZ='{"ezviz":{"cam1":{"unlatch":1794000000}}}'
check "unlatch: exit 0" 0 "$(rc u1)"; check "unlatch: says so" "configure: ezviz cam1 unlatched" "$(out u1)"
check "unlatch: latch file gone" 0 "$(find "$SB/u1/common/ezviz/state" -name cam1.latch | wc -l)"
check "unlatch: record appended" unlatch "$(tail -n 1 "$SB/u1/common/ezviz/state/cam1.ledger" | sed 's/.*"ev":"\([a-z_]*\)".*/\1/')"
check "unlatch: nginx and certsync still restarted" 1 "$(grep -c '^restart frigate.nginx frigate.certsync$' "$SB/u1/log")"
PRE='rm -rf "$c/common/ezviz"' run u2 CFG_EZVIZ='{"ezviz":{"cam1":{"unlatch":5}}}'
check "no state dir: exit 0, silent" "0 " "$(rc u2) $(out u2)"
run p1 CFG_PORTS=5000; check "existing checks unaffected: ports.https=5000 still refused" 1 "$(rc p1)"
[ "$FAILS" = 0 ] && echo "configure-ezviz.test: all ok" || echo "configure-ezviz.test: FAILURES"
exit "$FAILS"
