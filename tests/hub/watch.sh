#!/usr/bin/env bash
# M7c hub stop-rule watcher (spec §8), on the laptop. Every interval it runs ONE read-only command on the hub
# through tests/hub/ssh-exec.sh (the operator's existing ssh master only) and logs one line. It trips on:
#   MemAvailable < 2 GB;  memory PSI `some avg60` > 10 for 5 min;  1-min load > 3.5 for 10 min;
#   snap.frigate.frigate NRestarts grows by more than 3 in 10 min;  free space on the data fs < 20 GB;
#   swap used > the H0 baseline + 1 GB;  Home Assistant restarts: its snap unit (MainPID change, NRestarts
#   growth, not active) or its docker container (Running false, RestartCount up, StartedAt changed);
#   Home Assistant slow: no HTTP status line within 5 s in 3 consecutive samples. The slow check is a HEURISTIC
#   (no curl on the hub): `printf 'GET / HTTP/1.0\r\n\r\n' | nc -w 5 127.0.0.1 <port> | head -n 1`, timed;
#   any `HTTP/1.x NNN` status line counts as an answer. A plain `nc -z` TCP result is logged, not tripped on.
# Default: DETECT ONLY (prints TRIP lines, exit 1). --act also runs `snap stop --disable frigate` (sudo -n).
# Usage: M7C_HUB_SOCK=<socket> M7C_HUB_TARGET=<target> tests/hub/watch.sh --swap-baseline-mb <MB from H0 free -m>
#          [--act] [--interval 30] [--samples N] [--data-path /var/snap] [--ha-port 8123]
#          [--ha-unit snap.home-assistant.daemon.service] [--ha-container homeassistant] [--log FILE]
# Exit: 0 after --samples with no trip; 1 TRIP; 2 usage, or (first sample) the HA unit is not loaded or the HA
# container cannot be inspected (a wrong name would watch nothing); 3 the ssh master is gone (LOUD); 4 BLIND: two samples in a row failed or were unparsable.
# Test hooks: M7C_WATCH_CLOCK (prints epoch seconds), M7C_WATCH_SLEEP (the sleep command).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); EXEC="$HERE/ssh-exec.sh"
usage() { echo "usage: watch.sh --swap-baseline-mb MB [--act] [--interval S] [--samples N] [--data-path P] [--ha-port N] [--ha-unit U] [--ha-container C] [--log F]" >&2; exit 2; }
BASE_MB=""; ACT=0; IV=30; NS=0; DATA=/var/snap; PORT=8123; HAU=snap.home-assistant.daemon.service; HAC=homeassistant; LOG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --swap-baseline-mb) [ $# -ge 2 ] || usage; BASE_MB=$2; shift 2 ;;
    --act) ACT=1; shift ;;
    --interval) [ $# -ge 2 ] || usage; IV=$2; shift 2 ;;
    --samples) [ $# -ge 2 ] || usage; NS=$2; shift 2 ;;
    --data-path) [ $# -ge 2 ] || usage; DATA=$2; shift 2 ;;
    --ha-port) [ $# -ge 2 ] || usage; PORT=$2; shift 2 ;;
    --ha-unit) [ $# -ge 2 ] || usage; HAU=$2; shift 2 ;;
    --ha-container) [ $# -ge 2 ] || usage; HAC=$2; shift 2 ;;
    --log) [ $# -ge 2 ] || usage; LOG=$2; shift 2 ;;
    *) usage ;;
  esac
done
uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; }
uint "$BASE_MB" || usage
{ uint "$IV" && [ "$IV" -ge 1 ]; } || usage
uint "$NS" || usage
{ uint "$PORT" && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; } || usage
[[ "$DATA" =~ ^/[A-Za-z0-9/._-]*$ ]] || usage
[[ "$HAU" =~ ^[A-Za-z0-9@._-]+\.service$ ]] || usage
[[ "$HAC" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || usage
LOG="${LOG:-$HOME/.cache/frigate-m7c-evidence/hub/watch-$(date +%Y%m%dT%H%M%S).log}"
mkdir -p "$(dirname "$LOG")" || exit 2
SLEEP="${M7C_WATCH_SLEEP:-sleep}"
now() { if [ -n "${M7C_WATCH_CLOCK:-}" ]; then "$M7C_WATCH_CLOCK"; else date +%s; fi; }
gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'; }
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
loud() { printf '%s\n' "$*" | tee -a "$LOG" >&2; }

# The one read-only sample (POSIX sh on the hub; no curl, jq or python there).
SAMPLE="echo m7c-watch-sample
awk '/^MemAvailable:/ { print \"memavail_kb=\" \$2 } /^SwapTotal:/ { t = \$2 } /^SwapFree:/ { f = \$2 } END { print \"swap_used_kb=\" (t - f) }' /proc/meminfo
awk '\$1 == \"some\" { for (i = 2; i <= NF; i++) if (\$i ~ /^avg60=/) { sub(/^avg60=/, \"\", \$i); print \"psi_some_avg60=\" \$i } }' /proc/pressure/memory
awk '{ print \"load1=\" \$1 }' /proc/loadavg
echo \"fr_nrestarts=\$(systemctl show -p NRestarts --value snap.frigate.frigate.service)\"
df -Pk $DATA | awk 'NR == 2 { print \"free_kb=\" \$4 }'
systemctl show -p LoadState -p ActiveState -p MainPID -p NRestarts $HAU | sed 's/^/ha_/'
nc -z -w 5 127.0.0.1 $PORT >/dev/null 2>&1; echo \"ha_tcp_rc=\$?\"
echo \"ha_ctr=\$(docker inspect -f '{{.State.Running}} {{.RestartCount}} {{.State.StartedAt}}' $HAC 2>/dev/null)\"
t0=\$(date +%s%N); r=\$(printf 'GET / HTTP/1.0\\r\\n\\r\\n' | timeout 10 nc -w 5 127.0.0.1 $PORT 2>/dev/null | head -n 1 | tr -d '\\r'); t1=\$(date +%s%N)
echo \"ha_http=\$r\"; echo \"ha_http_ms=\$(( (t1 - t0) / 1000000 ))\"
echo end=1"
KEYS="memavail_kb swap_used_kb psi_some_avg60 load1 fr_nrestarts free_kb ha_LoadState ha_ActiveState ha_MainPID ha_NRestarts ha_tcp_rc ha_ctr ha_http_ms end"

"$EXEC" check >/dev/null 2>&1 </dev/null || { loud "watch: MASTER GONE: no live ssh master; not watching (exit 3)"; exit 3; }
log "watch: start $(date -Is); mode $([ "$ACT" = 1 ] && echo ACT || echo DETECT-ONLY); interval ${IV}s; swap baseline ${BASE_MB} MB; HA unit $HAU container $HAC port $PORT; data fs $DATA"

declare -A V; bad=0; i=0; psi_since=""; load_since=""; ha_bad=0; ha_pid0=""; ha_nr0=""; ctr_rc0=""; ctr_st0=""
NRT=(); NRV=()
while :; do
  i=$((i + 1)); t=$(now)
  out=$("$EXEC" exec "$SAMPLE" 2>&1 </dev/null); rc=$?
  if [ "$rc" = 3 ]; then loud "watch: MASTER GONE at $(date -Is): the watcher is BLIND and cannot stop frigate (exit 3)"; exit 3; fi
  V=(); while IFS='=' read -r k v; do [ -n "$k" ] && V[$k]=$v; done < <(printf '%s\n' "$out")
  ok=1; [ "$rc" = 0 ] || ok=0
  for k in $KEYS; do [ -n "${V[$k]+x}" ] || ok=0; done
  for k in memavail_kb swap_used_kb fr_nrestarts free_kb ha_NRestarts ha_tcp_rc ha_http_ms; do uint "${V[$k]:-}" || ok=0; done
  [[ "${V[psi_some_avg60]:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ "${V[load1]:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ok=0
  if [ "$ok" = 0 ]; then
    bad=$((bad + 1)); loud "watch: WARN: unparsable sample $i (rc $rc), $bad in a row"
    if [ "$bad" -ge 2 ]; then loud "watch: BLIND: $bad samples in a row failed; stopping the watcher (exit 4)"; exit 4; fi
  else
    bad=0
    if [ "${V[ha_LoadState]}" != loaded ]; then loud "watch: $HAU has LoadState=${V[ha_LoadState]}: wrong --ha-unit? (exit 2)"; exit 2; fi
    read -r ctr_run ctr_rc ctr_st <<<"${V[ha_ctr]}"
    if [ -z "$ctr_st0" ]; then
      if [ -z "${ctr_st:-}" ] || ! uint "${ctr_rc:-}"; then loud "watch: cannot inspect docker container $HAC: wrong --ha-container? (exit 2)"; exit 2; fi
      ctr_rc0=$ctr_rc; ctr_st0=$ctr_st
      log "watch: baseline: HA container $HAC Running=$ctr_run RestartCount=$ctr_rc0 StartedAt=$ctr_st0; HA unit MainPID=${V[ha_MainPID]} NRestarts=${V[ha_NRestarts]}"
    fi
    code=$(awk '{ print $2 }' <<<"${V[ha_http]:-}")
    log "$(date -Is) mem_avail=$(( V[memavail_kb] / 1024 ))MB psi60=${V[psi_some_avg60]} load1=${V[load1]} fr_nrestarts=${V[fr_nrestarts]} free=$(( V[free_kb] / 1048576 ))GB swap_used=$(( V[swap_used_kb] / 1024 ))MB(base $BASE_MB) ha=${V[ha_ActiveState]} pid=${V[ha_MainPID]} nr=${V[ha_NRestarts]} ctr=${ctr_run:-?}/${ctr_rc:-?} tcp=${V[ha_tcp_rc]} http=${code:-none} ${V[ha_http_ms]}ms"
    TRIPS=()
    [ "${V[memavail_kb]}" -lt 2097152 ] && TRIPS+=("MemAvailable $(( V[memavail_kb] / 1024 )) MB < 2048 MB")
    if gt "${V[psi_some_avg60]}" 10; then psi_since=${psi_since:-$t}; [ $((t - psi_since)) -ge 300 ] && TRIPS+=("memory PSI some avg60 > 10 for $((t - psi_since)) s")
    else psi_since=""; fi
    if gt "${V[load1]}" 3.5; then load_since=${load_since:-$t}; [ $((t - load_since)) -ge 600 ] && TRIPS+=("load average > 3.5 for $((t - load_since)) s")
    else load_since=""; fi
    NRT+=("$t"); NRV+=("${V[fr_nrestarts]}"); nmin=""
    for j in "${!NRT[@]}"; do
      if [ "${NRT[$j]}" -lt $((t - 600)) ]; then unset 'NRT[j]' 'NRV[j]'; continue; fi
      { [ -z "$nmin" ] || [ "${NRV[$j]}" -lt "$nmin" ]; } && nmin=${NRV[$j]}
    done
    NRT=("${NRT[@]}"); NRV=("${NRV[@]}")
    [ $(( V[fr_nrestarts] - nmin )) -gt 3 ] && TRIPS+=("snap.frigate.frigate NRestarts grew by $(( V[fr_nrestarts] - nmin )) in 600 s")
    [ "${V[free_kb]}" -lt 20971520 ] && TRIPS+=("free space on $DATA is $(( V[free_kb] / 1048576 )) GB < 20 GB")
    [ "${V[swap_used_kb]}" -gt $(( (BASE_MB + 1024) * 1024 )) ] && TRIPS+=("swap used $(( V[swap_used_kb] / 1024 )) MB > baseline $BASE_MB MB + 1024 MB")
    [ "${V[ha_ActiveState]}" = active ] || TRIPS+=("Home Assistant ActiveState=${V[ha_ActiveState]}")
    if [ -z "$ha_pid0" ]; then ha_pid0=${V[ha_MainPID]}; ha_nr0=${V[ha_NRestarts]}; fi
    [ "${V[ha_MainPID]}" != "$ha_pid0" ] && TRIPS+=("Home Assistant restarted (MainPID $ha_pid0 -> ${V[ha_MainPID]})")
    [ "${V[ha_NRestarts]}" -gt "$ha_nr0" ] && TRIPS+=("Home Assistant NRestarts grew from $ha_nr0 to ${V[ha_NRestarts]}")
    [ "${ctr_run:-}" = true ] || TRIPS+=("Home Assistant container $HAC Running=${ctr_run:-unknown}")
    uint "${ctr_rc:-}" && [ "$ctr_rc" -gt "$ctr_rc0" ] && TRIPS+=("Home Assistant container RestartCount rose from $ctr_rc0 to $ctr_rc")
    [ "${ctr_st:-}" = "$ctr_st0" ] || TRIPS+=("Home Assistant container restarted (StartedAt $ctr_st0 -> ${ctr_st:-unknown})")
    hok=1; [ "${V[ha_http_ms]}" -le 5000 ] || hok=0
    [[ "${V[ha_http]:-}" =~ ^HTTP/1\.[01]\ [0-9]{3} ]] || hok=0
    if [ "$hok" = 1 ]; then ha_bad=0; else ha_bad=$((ha_bad + 1)); fi
    [ "$ha_bad" -ge 3 ] && TRIPS+=("Home Assistant gave no HTTP status line within 5 s in $ha_bad samples (last: '${V[ha_http]:-}' ${V[ha_http_ms]}ms; tcp=${V[ha_tcp_rc]})")
    if [ "${#TRIPS[@]}" -gt 0 ]; then
      for m in "${TRIPS[@]}"; do loud "TRIP: $m"; done
      if [ "$ACT" = 1 ]; then
        sout=$("$EXEC" exec 'snap stop --disable frigate' 2>&1 </dev/null); src=$?
        if [ "$src" = 3 ]; then loud "watch: TRIP but could NOT stop frigate: MASTER GONE; stop it at the hub: sudo snap stop --disable frigate (exit 3)"; exit 3; fi
        loud "ACT: sudo -n snap stop --disable frigate rc=$src ($(printf '%s' "$sout" | tr '\n' ' ' | cut -c1-120))"
      else loud "watch: DETECT ONLY: frigate NOT stopped; to stop it: sudo snap stop --disable frigate"; fi
      exit 1
    fi
  fi
  if [ "$NS" -gt 0 ] && [ "$i" -ge "$NS" ]; then log "watch: $i samples, no trip; end $(date -Is)"; exit 0; fi
  "$SLEEP" "$IV"
done
