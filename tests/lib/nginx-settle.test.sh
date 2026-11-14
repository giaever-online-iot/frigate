#!/usr/bin/env bash
# nginx_settle (tests/lib/nginx-settle.sh) against PATH stubs: each poll's systemctl/openssl answers come from
# per-poll sequences, and the fake sleep advances the poll index, so no real wait and no real unit is touched.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1; fail=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
mkdir -p "$T/bin"
# at <seq> : the word of the sequence for the current poll (the last word repeats)
cat > "$T/bin/stub-at" <<'S'
#!/bin/bash
n=$(cat "$ST/n"); set -- $1; i=$n; [ "$i" -ge $# ] && i=$(( $# - 1 )); shift "$i"; echo "$1"
S
cat > "$T/bin/systemctl" <<'S'
#!/bin/bash
echo "systemctl $*" >> "$ST/log"
case "$*" in
  "show -p MainPID --value snap.frigate.nginx.service") stub-at "$PIDS" ;;
  "is-active snap.frigate.nginx.service") a=$(stub-at "$ACTIVE"); echo "$a"; [ "$a" = active ] ;;
  *) exit 1 ;;
esac
S
cat > "$T/bin/openssl" <<'S'
#!/bin/bash
echo "openssl $*" >> "$ST/log"
[ "$*" = "s_client -connect 127.0.0.1:8971" ] || exit 1
[ "$(stub-at "$TLS")" = 1 ] && { echo "Server certificate"; echo "-----BEGIN CERTIFICATE-----"; exit 0; }; exit 1
S
printf '#!/bin/bash\necho $(( $(cat "$ST/n") + 1 )) > "$ST/n"\n' > "$T/bin/sleep"
chmod +x "$T/bin/"*
# run NAME OLDPID PIDS ACTIVE TLS [POLLS]: rc, stdout and the final poll index
run() {
  local n=$1; mkdir -p "$T/$n"; echo 0 > "$T/$n/n"; : > "$T/$n/log"
  OUT=$(env -i PATH="$T/bin:/usr/bin:/bin" ST="$T/$n" PIDS="$3" ACTIVE="$4" TLS="$5" SNAP_NAME=frigate \
        bash -c ". tests/lib/nginx-settle.sh; nginx_settle $2 ${6:-}" 2>"$T/$n/err"); RC=$?; N=$(cat "$T/$n/n")
}
# 1. The recorded failed run (gate run 1, 03:20:38): the old nginx (100) still serves when the call starts, the
#    hook's restart gives a new MainPID (200) that is active but does not serve TLS yet (nginx-run is between its
#    cert check and nginx's cert load: the race window), then TLS comes up. Deleting is safe only at poll 3.
run race 100 "100 200 200 200" "active" "1 0 0 1"
check "race: settles (rc 0)" 0 "$RC"
check "race: prints the new MainPID" 200 "$OUT"
check "race: not before the new nginx serves TLS (poll 3)" 3 "$N"
# 2. The hook restart never shows: bounded, rc 1, exactly POLLS polls.
run never 100 "100" "active" "1" 5
check "never restarted: rc 1" 1 "$RC"
check "never restarted: bounded at 5 polls" 5 "$N"
# 3. New PID and TLS, but the unit is not active yet: wait for active.
run activating 100 "200" "activating activating active" "1"
check "activating: rc 0" 0 "$RC"
check "activating: waits for active (poll 2)" 2 "$N"
# 4. MainPID 0 (unit between stop and start) is not a new nginx.
run stopped 100 "0 0 300" "active" "1"
check "MainPID 0 is not accepted (poll 2)" 2 "$N"
check "MainPID 0: then the real new pid" 300 "$OUT"
# 5. The default bound is 20 polls.
run default 100 "100" "active" "1"
check "default bound 20 polls" 20 "$N"
# 6. Junk arguments are refused up front.
run junk abc "200" "active" "1"
check "non-numeric old pid: rc 2" 2 "$RC"
check "non-numeric old pid: no poll" 0 "$N"
exit "$fail"
