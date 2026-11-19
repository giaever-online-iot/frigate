#!/usr/bin/env bash
# shellcheck disable=SC2016  # PRE strings are single-quoted on purpose: run() evals them with its own $T and $n
# tests/hub/watch.sh against a fake hub (ssh-exec.sh -> fixtures/stub/ssh -> fixtures/watch-responder.sh) and a
# fake clock (30 s per sample, no real sleep). No network, no master, no hub.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1; fail=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
has()   { grep -qF -- "$2" "$3"; check "$1" 0 $?; }
hasnt() { grep -qF -- "$2" "$3"; check "$1" 1 $?; }
W=tests/hub/watch.sh; FX=$PWD/tests/hub/fixtures
run() {  # run NAME [env...] -- watch args (default --swap-baseline-mb 100 --samples 30 unless given)
  local n=$1; shift; local -a e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  mkdir -p "$T/$n/st"; : > "$T/$n/st/log"; : > "$T/$n/st/cmds"
  [ -n "${PRE:-}" ] && eval "$PRE"
  env STUB_ST="$T/$n/st" STUB_RESPONDER="$FX/watch-responder.sh" M7C_SSH="$FX/stub/ssh" M7C_HUB_SOCK=/run/test/m7c.sock \
    M7C_HUB_TARGET=hub-test M7C_WATCH_CLOCK="$FX/stub/clock" M7C_WATCH_SLEEP=true "${e[@]}" \
    timeout 30 bash "$W" --log "$T/$n.log" "$@" > "$T/$n.out" 2>&1; echo $? > "$T/$n.rc"
}
rc() { cat "$T/$1.rc"; }; C() { echo "$T/$1/st/cmds"; }; O() { echo "$T/$1.out"; }
samples() { grep -c '^20[0-9-]*T.* mem_avail=' "$T/$1.log"; }
stops() { if [ -f "$T/$1/st/stops" ]; then wc -l < "$T/$1/st/stops"; else echo 0; fi; }
B=(--swap-baseline-mb 100)

# --- usage ---
run u1 -- --samples 3;                          check "no --swap-baseline-mb: exit 2" 2 "$(rc u1)"
run u2 -- "${B[@]}" --interval 0;               check "interval 0: exit 2" 2 "$(rc u2)"
run u3 -- "${B[@]}" --ha-port 8x;               check "bad --ha-port: exit 2" 2 "$(rc u3)"
run u4 -- "${B[@]}" --data-path 'a b';          check "bad --data-path: exit 2" 2 "$(rc u4)"
run u5 -- "${B[@]}" --ha-unit 'x;y';            check "bad --ha-unit: exit 2" 2 "$(rc u5)"
run u6 -- "${B[@]}" --ha-container 'a b';       check "bad --ha-container: exit 2" 2 "$(rc u6)"
check "usage sends no hub command" 0 "$(cat "$T"/u?/st/cmds | wc -l)"

# --- healthy: one line per sample, read-only, exit 0 after --samples ---
run h1 -- "${B[@]}" --samples 5
check "healthy: exit 0" 0 "$(rc h1)"; check "healthy: 5 log lines" 5 "$(samples h1)"
hasnt "healthy: no TRIP" "TRIP" "$(O h1)"
check "healthy: only the read-only sample command was sent" 5 "$(grep -c '^echo m7c-watch-sample' "$(C h1)")"
check "healthy: nothing else was sent (5 sessions in all)" 5 "$(cat "$T/h1/st/sessions")"
has   "log line carries every metric" "mem_avail=11718MB psi60=0.00 load1=0.40 fr_nrestarts=0 free=190GB swap_used=0MB(base 100) ha=active pid=4321 nr=0 ctr=true/0 tcp=0 http=200 40ms" "$T/h1.log"
has   "baseline line names the container StartedAt" "watch: baseline: HA container homeassistant Running=true RestartCount=0 StartedAt=2026-11-14T10:27:54Z" "$T/h1.log"
has   "the sample inspects the container" "docker inspect -f '{{.State.Running}} {{.RestartCount}} {{.State.StartedAt}}' homeassistant" "$(C h1)"
has   "the slow check is the plain nc probe" "printf 'GET / HTTP/1.0\\r\\n\\r\\n' | timeout 10 nc -w 5 127.0.0.1 8123" "$(C h1)"

# --- MemAvailable < 2 GB: immediate TRIP; detect only by default; --act stops frigate ---
run m1 W_MEM="9000000 9000000 2000000" -- "${B[@]}"
check "MemAvailable low: exit 1" 1 "$(rc m1)"; check "MemAvailable low: trips at sample 3" 3 "$(samples m1)"
has   "MemAvailable low: TRIP line" "TRIP: MemAvailable 1953 MB < 2048 MB" "$(O m1)"
check "detect only: no snap stop sent" 0 "$(stops m1)"
run m2 W_MEM="2097152" -- "${B[@]}" --samples 2; check "MemAvailable exactly 2 GB: no trip" 0 "$(rc m2)"
run a1 W_MEM="9000000 2000000" -- "${B[@]}" --act
check "--act: exit 1" 1 "$(rc a1)"; check "--act: snap stop --disable frigate sent once" 1 "$(stops a1)"
has   "--act: says it acted" "ACT: sudo -n snap stop --disable frigate rc=0" "$(O a1)"

# --- PSI some avg60 > 10 for 5 min (11 samples 30 s apart = 300 s) ---
run p1 W_PSI="15 15 15 15 15 15 15 15 15 15 0" -- "${B[@]}" --samples 12
check "PSI > 10 for 270 s then drops: no trip" 0 "$(rc p1)"
run p2 W_PSI="15" -- "${B[@]}"
check "PSI > 10 for 300 s: exit 1" 1 "$(rc p2)"; check "PSI trips at sample 11" 11 "$(samples p2)"
has   "PSI TRIP line" "TRIP: memory PSI some avg60 > 10 for 300 s" "$(O p2)"
run p3 W_PSI="10.00" -- "${B[@]}" --samples 15; check "PSI exactly 10: no trip" 0 "$(rc p3)"

# --- load > 3.5 for 10 min (21 samples = 600 s); a dip resets ---
run l1 W_LOAD="3.6" -- "${B[@]}" --samples 40
check "load > 3.5 for 600 s: exit 1" 1 "$(rc l1)"; check "load trips at sample 21" 21 "$(samples l1)"
has   "load TRIP line" "TRIP: load average > 3.5 for 600 s" "$(O l1)"
run l2 W_LOAD="3.6 3.6 3.6 3.6 3.6 3.6 3.6 3.6 3.6 3.6 3.6 3.6 3.6 3.6 3.6 3.0 3.6" -- "${B[@]}" --samples 30
check "load dips once: streak restarts, no trip within 30 samples" 0 "$(rc l2)"

# --- frigate NRestarts grows by more than 3 in 10 min ---
run r1 W_FRNR="0 1 2 3" -- "${B[@]}" --samples 10;       check "NRestarts +3: no trip" 0 "$(rc r1)"
run r2 W_FRNR="0 1 2 3 4" -- "${B[@]}"
check "NRestarts +4 within 10 min: exit 1" 1 "$(rc r2)"; has "NRestarts TRIP line" "TRIP: snap.frigate.frigate NRestarts grew by 4 in 600 s" "$(O r2)"
run r3 W_FRNR="0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2 2 3 3 3 3 3 3 3 3 4" -- "${B[@]}" --samples 33
check "NRestarts +4 spread over 16 min: no trip" 0 "$(rc r3)"

# --- free space < 20 GB; swap > baseline + 1 GB ---
run d1 W_FREE="20971519" -- "${B[@]}";  check "free < 20 GB: exit 1" 1 "$(rc d1)"; has "free TRIP line" "TRIP: free space on /var/snap" "$(O d1)"
run d2 W_FREE="20971520" -- "${B[@]}" --samples 2; check "free exactly 20 GB: no trip" 0 "$(rc d2)"
run w1 W_SWAP="1150976" -- "${B[@]}" --samples 2; check "swap = base + 1 GB: no trip" 0 "$(rc w1)"
run w2 W_SWAP="1152000" -- "${B[@]}"; check "swap > base + 1 GB: exit 1" 1 "$(rc w2)"
has   "swap TRIP line" "TRIP: swap used 1125 MB > baseline 100 MB + 1024 MB" "$(O w2)"

# --- Home Assistant: restart, not active, slow or no answer ---
# The HA snap unit restarting (MainPID or NRestarts) is INFO, not a trip: a snap refresh of home-assistant restarts
# the unit while the container and the frontend stay up (hub, 14 Nov: MainPID changed, container untouched).
run ha1 W_HAPID="4321 4321 5555" -- "${B[@]}" --samples 5;  check "HA unit MainPID changes: no trip" 0 "$(rc ha1)"
has   "HA MainPID change is INFO" "INFO: HA unit restarted (MainPID 4321 -> 5555), container untouched" "$(O ha1)"
hasnt "HA MainPID change: no TRIP line" "TRIP" "$(O ha1)"; check "HA MainPID change: INFO once, not per sample" 1 "$(grep -c 'INFO: HA unit restarted' "$(O ha1)")"
run ha3 W_HANR="0 1" -- "${B[@]}" --samples 4;              check "HA unit NRestarts grows: no trip" 0 "$(rc ha3)"
has   "HA NRestarts growth is INFO" "INFO: HA unit restarted (NRestarts 0 -> 1), container untouched" "$(O ha3)"
run ha10 W_HAPID="4321 5555 7777" W_HANR="0 1 2" W_HAACT="active activating active" -- "${B[@]}" --samples 6
check "HA snap refresh (2 unit restarts, one activating blip, container untouched): no trip" 0 "$(rc ha10)"
check "HA snap refresh: two INFO lines" 2 "$(grep -c 'INFO: HA unit restarted' "$(O ha10)")"
run ha11 W_HAPID="4321 5555" W_CTR="true_0_2026-11-14T10:27:54Z true_0_2026-11-14T13:01:02Z" -- "${B[@]}"
check "HA unit and container both restart: exit 1" 1 "$(rc ha11)"; has "container restart still trips" "TRIP: Home Assistant container restarted" "$(O ha11)"
hasnt "the INFO line does not claim the container is untouched" "container untouched" "$(O ha11)"
# The unit not active trips only on 2 samples in a row (a refresh blip of a few seconds is one sample).
run ha2 W_HAACT="active failed" -- "${B[@]}";   check "HA not active 2 in a row: exit 1" 1 "$(rc ha2)"; check "HA inactive trips at sample 3" 3 "$(samples ha2)"
has   "HA inactive TRIP" "TRIP: Home Assistant ActiveState=failed for 2 samples" "$(O ha2)"
run ha12 W_HAACT="active activating active deactivating active" -- "${B[@]}" --samples 6; check "HA not active once at a time: no trip" 0 "$(rc ha12)"
run ha4 W_HTTPMS="40 6000 6000 40" -- "${B[@]}" --samples 6; check "HA slow twice in a row: no trip" 0 "$(rc ha4)"
run ha5 W_HTTPMS="40 6000 6000 6000" -- "${B[@]}"; check "HA slow 3 in a row: exit 1" 1 "$(rc ha5)"; check "HA slow trips at sample 4" 4 "$(samples ha5)"
has   "HA slow TRIP" "TRIP: Home Assistant gave no HTTP status line within 5 s in 3 samples" "$(O ha5)"
run ha6 W_HTTP="HTTP/1.0_503_Service" -- "${B[@]}" --samples 5; check "HA 503 is a status line: no trip" 0 "$(rc ha6)"
run ha7 W_HTTP="-" -- "${B[@]}";                 check "HA no status line 3 in a row: exit 1" 1 "$(rc ha7)"
run ha8 W_TCP="1" -- "${B[@]}" --samples 5;      check "nc -z refused alone: logged, no trip" 0 "$(rc ha8)"
run ha9 W_HTTP="HTTP/1.1_401_Unauthorized" -- "${B[@]}" --samples 3; check "HA 401 counts as answering" 0 "$(rc ha9)"
run hc1 W_CTR="true_0_2026-11-14T10:27:54Z false_0_2026-11-14T10:27:54Z" -- "${B[@]}"; check "HA container not running: exit 1" 1 "$(rc hc1)"; has "container Running TRIP" "TRIP: Home Assistant container homeassistant Running=false" "$(O hc1)"
run hc2 W_CTR="true_0_2026-11-14T10:27:54Z true_1_2026-11-14T10:27:54Z" -- "${B[@]}"; check "HA RestartCount rises: exit 1" 1 "$(rc hc2)"; has "RestartCount TRIP" "RestartCount rose from 0 to 1" "$(O hc2)"
run hc3 W_CTR="true_0_2026-11-14T10:27:54Z true_0_2026-11-14T13:01:02Z" -- "${B[@]}"; check "HA StartedAt changes: exit 1" 1 "$(rc hc3)"; has "StartedAt TRIP" "TRIP: Home Assistant container restarted (StartedAt 2026-11-14T10:27:54Z -> 2026-11-14T13:01:02Z)" "$(O hc3)"
run hc4 W_CTR="-" -- "${B[@]}"; check "no such container at the first sample: exit 2" 2 "$(rc hc4)"; has "says it cannot inspect" "cannot inspect docker container homeassistant" "$(O hc4)"
run hc5 W_CTR="true_0_x" -- "${B[@]}" --ha-container other --samples 2; check "--ha-container is used" 0 "$(rc hc5)"; has "--ha-container in the sample" "{{.State.StartedAt}}' other" "$(C hc5)"
run hz W_HALOAD="not-found" -- "${B[@]}"
check "HA unit not loaded: exit 2 (a wrong unit must not watch silently)" 2 "$(rc hz)"; has "says the unit is not loaded" "LoadState=not-found" "$(O hz)"

# --- blind or lost: LOUD ---
PRE='touch "$T/$n/st/gone"' run g1 -- "${B[@]}"
check "master gone at start: exit 3" 3 "$(rc g1)"; has "master gone: loud" "MASTER GONE" "$(O g1)"
PRE='echo 3 > "$T/$n/st/die-after"' run g2 -- "${B[@]}"
check "master dies mid-watch: exit 3" 3 "$(rc g2)"; has "master dies: loud" "MASTER GONE" "$(O g2)"
check "master dies: 3 samples logged first" 3 "$(samples g2)"
PRE='echo 2 > "$T/$n/st/die-after"' run g3 W_MEM="9000000 1000" -- "${B[@]}" --act
check "TRIP with --act but the master is gone: exit 3" 3 "$(rc g3)"
has   "says it could NOT stop frigate" "could NOT stop frigate" "$(O g3)"
run b1 W_BROKEN="0 1 0" -- "${B[@]}" --samples 4; check "one unparsable sample: tolerated" 0 "$(rc b1)"; has "warns about it" "WARN: unparsable sample" "$(O b1)"
run b2 W_BROKEN="0 1 1" -- "${B[@]}";  check "two unparsable samples in a row: exit 4 (BLIND)" 4 "$(rc b2)"; has "says BLIND" "BLIND" "$(O b2)"
check "BLIND right after the second bad sample (2 WARN lines)" 2 "$(grep -c 'WARN: unparsable sample' "$(O b2)")"

# --- kernel undervoltage since the watcher started, all boots (P12, SF10): a growing count trips; unreadable is INFO ---
run uv1 W_UV="0 0 1" -- "${B[@]}" --samples 3
check "undervoltage +1: exit 1" 1 "$(rc uv1)"; has "undervoltage: TRIP line" "TRIP: undervoltage" "$(O uv1)"
run uv2 W_UV="0 1" -- "${B[@]}" --samples 2 --act; check "undervoltage --act: frigate stopped once" 1 "$(stops uv2)"
run uv3 W_UV="unreadable" -- "${B[@]}" --samples 3
check "kuv unreadable: exit 0, no TRIP" 0 "$(rc uv3)"; has "kuv unreadable: INFO line" "INFO: kernel journal unreadable" "$(O uv3)"
has "the sample reads the kernel transport across boots" "journalctl _TRANSPORT=kernel --since @" "$(C uv3)"
# The window starts at the watcher's own start (the fake clock's first value, 1000000), never earlier: --since @0
# would count every old undervoltage and --act would stop frigate on the first sample.
check "the sample pins the watcher's start epoch" 3 "$(grep -cF 'journalctl _TRANSPORT=kernel --since @1000000 --no-pager' "$(C uv3)")"
hasnt "never journalctl -k" "journalctl -k" "$(C uv3)"

[ "$fail" = 0 ] && echo "watch.test: all ok" || echo "watch.test: FAILURES"
exit "$fail"
