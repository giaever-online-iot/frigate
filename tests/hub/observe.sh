#!/usr/bin/env bash
# M7c hub OBSERVE (W-7, spec §7.2/§7.3, V7/V9/V10 natively): a READ-ONLY, one-shot measurement of the running
# trial, run on the laptop at ~30 min and ~24 h after the start. Every hub step goes through tests/hub/ssh-exec.sh
# (the operator's existing ssh master only). It changes nothing on the hub: two commands, both reads:
#   1. one POSIX-sh sample (the hub has no curl/jq/python3): /proc, /sys/fs/cgroup and `systemctl show` only. It
#      reads the counters twice, --window seconds apart (default 10): CPUUsageNSec of the quota slice
#      (snap.frigate\x2dmem.slice) and of the four units, the slice's cpu.stat (usage, nr_periods, nr_throttled,
#      throttled_usec), and utime+stime of every process in the slice. Once: per-unit ActiveState, MainPID,
#      NRestarts, MemoryCurrent, MemoryPeak; slice MemoryCurrent/MemoryPeak/MemoryMax/CPUQuota and memory.stat
#      anon/shmem/file; /dev/shm/snap.frigate bytes and frame files per camera; the Coral USB id; load, MemAvailable,
#      swap used, PSI some avg60 (memory, cpu); the Home Assistant answer time (watch.sh's nc heuristic). A process
#      label is unit, comm, role (d = rawvideo detect output, r = segment record output, e = an `-f rtsp` exec push)
#      and ONE stream name matched by a fixed pattern (the exec line's title=m7c-<stream>, else 127.0.0.1:8554/<name>
#      or m7c-clips/<file>); a whole command line is never printed.
#   2. Frigate's /stats through the snap's own python (`snap run --shell frigate.frigate`, the script on stdin,
#      urllib to 127.0.0.1:5001 with the Remote-User/Remote-Role headers): numbers only, for known keys only.
# PASS/FAIL: the 4 units active (and NRestarts unchanged since --prev); per camera camera_fps >= 0.9 x the input's
# native fps (--fps, default cam1=25,cam2=15) and skipped_fps 0; the detector's inference_speed > 0; go2rtc runs
# --execs exec ffmpegs (default 3: cam1, cam2, cam2_sub; 0 skips) and none restarted since --prev (same PID and
# start time); /stats readable; no credential-like text in what the hub sent. Everything else is INFO, numeric.
# Evidence: <out>/sample.txt, stats.txt (scrubbed), results.txt, counters.txt (the next run's --prev).
# Usage: M7C_HUB_SOCK=<socket> M7C_HUB_TARGET=<target> tests/hub/observe.sh [--prev <evidence dir>] [--out <dir>]
#          [--window S] [--fps cam1=25,cam2=15] [--execs N] [--ha-port 8123]
# Exit: 0 all PASS; 1 any FAIL; 2 usage; 3 the ssh master is gone (LOUD). Test hook: M7C_OBSERVE_ROOT (a path
# prefix for /proc, /sys and /dev/shm on the hub; empty in real use).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); EXEC="$HERE/ssh-exec.sh"
usage() { echo "usage: observe.sh [--prev DIR] [--out DIR] [--window S] [--fps cam=N,...] [--execs N] [--ha-port N]" >&2; exit 2; }
PREV=""; OUT=""; WIN=10; FPS="cam1=25,cam2=15"; NEX=3; PORT=8123
while [ $# -gt 0 ]; do
  case "$1" in
    --prev) [ $# -ge 2 ] || usage; PREV=$2; shift 2 ;;
    --out) [ $# -ge 2 ] || usage; OUT=$2; shift 2 ;;
    --window) [ $# -ge 2 ] || usage; WIN=$2; shift 2 ;;
    --fps) [ $# -ge 2 ] || usage; FPS=$2; shift 2 ;;
    --execs) [ $# -ge 2 ] || usage; NEX=$2; shift 2 ;;
    --ha-port) [ $# -ge 2 ] || usage; PORT=$2; shift 2 ;;
    *) usage ;;
  esac
done
uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; }
{ uint "$WIN" && [ "$WIN" -ge 1 ] && [ "$WIN" -le 300 ]; } || usage
uint "$NEX" || usage
{ uint "$PORT" && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; } || usage
[[ "$FPS" =~ ^[A-Za-z0-9_-]+=[0-9]+(,[A-Za-z0-9_-]+=[0-9]+)*$ ]] || usage
if [ -n "$PREV" ] && [ ! -r "$PREV/counters.txt" ]; then echo "observe: --prev $PREV has no counters.txt" >&2; exit 2; fi
ROOT="${M7C_OBSERVE_ROOT:-}"; [ -z "$ROOT" ] || [[ "$ROOT" =~ ^/[A-Za-z0-9/._-]+$ ]] || usage
OUT="${OUT:-$HOME/.cache/frigate-m7c-evidence/hub/observe-$(date +%Y%m%dT%H%M%S)}"
mkdir -p "$OUT" || exit 2; RESULTS="$OUT/results.txt"; : > "$RESULTS"
FAILS=0
scrub() { grep -viE 'passw(or)?d' | sed -E 's#(rtsps?|rtmp|https?)://[^@/[:space:]]+@#\1://<redacted>@#g'; }
say()  { printf '%s\n' "$*" | scrub | tee -a "$RESULTS"; }
pass() { say "PASS: $*"; }
fail() { say "FAIL: $*"; FAILS=$((FAILS + 1)); }
info() { say "INFO: $*"; }
CRED=0
# g NAME CMD [STDIN-FILE]: run CMD on the hub; scrubbed output to $OUT/NAME.txt; credential-like lines counted
# before the scrub (never shown). A lost master (exit 3) ends the run here.
g() {
  local rc in=/dev/null; [ $# -ge 3 ] && in=$3
  "$EXEC" exec "$2" > "$OUT/$1.raw" 2>&1 < "$in"; rc=$?
  CRED=$(( CRED + $(grep -ciE 'passw(or)?d|://[^@/[:space:]]+@' "$OUT/$1.raw") ))
  scrub < "$OUT/$1.raw" > "$OUT/$1.txt"; rm -f "$OUT/$1.raw"
  if [ "$rc" = 3 ]; then echo "observe: MASTER GONE during '$1': stopping, no verdict (exit 3)" >&2; exit 3; fi
  return "$rc"
}
"$EXEC" check > /dev/null 2>&1 </dev/null || { echo "observe: MASTER GONE: nothing run (exit 3)" >&2; exit 3; }

# --- 1. the sample (POSIX sh on the hub; read-only) --------------------------------------------------------
read -r -d '' SAMPLE <<'EOF'
echo m7c-observe-sample
R='@R@'; SL='snap.frigate\x2dmem.slice'; U='frigate go2rtc nginx certsync'
CG=$(systemctl show -p ControlGroup --value "$SL"); D="$R/sys/fs/cgroup$CG"
if [ -n "$CG" ] && [ -r "$D/cpu.stat" ]; then echo slice_cg_ok=1; else echo slice_cg_ok=0; fi
echo "clk_tck=$(getconf CLK_TCK 2>/dev/null || echo 100)"
snapc() {
  t=$1
  echo "$t.t_ns=$(date +%s%N)"
  awk -v p="$t" '{ print p ".uptime=" $1 }' "$R/proc/uptime"
  systemctl show -p MemoryCurrent -p MemoryPeak -p CPUUsageNSec "$SL" | sed "s/^/$t.slice./"
  for n in $U; do systemctl show -p ActiveState -p MainPID -p NRestarts -p MemoryCurrent -p MemoryPeak -p CPUUsageNSec "snap.frigate.$n.service" | sed "s/^/$t.$n./"; done
  [ -r "$D/cpu.stat" ] && awk -v p="$t.cpustat." '{ print p $1 "=" $2 }' "$D/cpu.stat"
  for f in $(find "$D" -name cgroup.procs 2>/dev/null); do
    for pid in $(cat "$f"); do
      [ -r "$R/proc/$pid/stat" ] && awk -v p="$t.proc.$pid" '{ sub(/^.*\) /, ""); print p "=" ($12 + $13) " " $20 }' "$R/proc/$pid/stat"
    done
  done
}
snapc a
sleep @W@
snapc b
for f in $(find "$D" -name cgroup.procs 2>/dev/null); do
  u=$(basename "$(dirname "$f")"); u=${u#snap.frigate.}; u=${u%.service}
  for pid in $(cat "$f"); do
    [ -r "$R/proc/$pid/comm" ] || continue
    c=$(tr -d '\n' < "$R/proc/$pid/comm" | tr -c 'A-Za-z0-9._:-' '_' | cut -c1-15)
    pp=$(awk '{ sub(/^.*\) /, ""); print $2 }' "$R/proc/$pid/stat")
    a=$(tr '\0' ' ' < "$R/proc/$pid/cmdline")
    s=$(printf '%s' "$a" | grep -oE 'title=m7c-[A-Za-z0-9_]+' | head -n 1 | sed 's#.*=m7c-##')
    [ -n "$s" ] || s=$(printf '%s' "$a" | grep -oE '127\.0\.0\.1:8554/[A-Za-z0-9_]+|m7c-clips/[A-Za-z0-9._-]+' | head -n 1 | sed 's#.*/##')
    r=""; case "$a" in *rawvideo*) r="${r}d" ;; esac; case "$a" in *"-f segment"*) r="${r}r" ;; esac; case "$a" in *"-f rtsp"*) r="${r}e" ;; esac
    echo "label.$pid=$u $c ${r:--} ${s:--} $pp"
  done
done
[ -r "$D/memory.stat" ] && awk '$1 == "anon" || $1 == "shmem" || $1 == "file" { print "memstat." $1 "=" $2 }' "$D/memory.stat"
systemctl show -p MemoryMax -p CPUQuotaPerSecUSec "$SL" | sed 's/^/limit./'
echo "shm_bytes=$(du -sb "$R/dev/shm/snap.frigate" 2>/dev/null | awk '{ print $1 }')"
ls "$R/dev/shm/snap.frigate" 2>/dev/null | sed -n 's/_frame.*//p' | sort | uniq -c | awk '{ print "shm_frames." $2 "=" $1 }'
for d in "$R"/sys/bus/usb/devices/*; do [ -r "$d/idVendor" ] && [ -r "$d/idProduct" ] && echo "usb=$(cat "$d/idVendor"):$(cat "$d/idProduct")"; done | grep -E '=(1a6e:089a|18d1:9302)$'
awk '{ print "load1=" $1; print "load5=" $2; print "load15=" $3 }' "$R/proc/loadavg"
awk '/^MemAvailable:/ { print "memavail_kb=" $2 } /^SwapTotal:/ { t = $2 } /^SwapFree:/ { f = $2 } END { print "swap_used_kb=" (t - f) }' "$R/proc/meminfo"
for k in memory cpu; do awk -v k="$k" '$1 == "some" { for (i = 2; i <= NF; i++) if ($i ~ /^avg60=/) { sub(/^avg60=/, "", $i); print "psi_" k "=" $i } }' "$R/proc/pressure/$k"; done
t0=$(date +%s%N); r=$(printf 'GET / HTTP/1.0\r\n\r\n' | timeout 10 nc -w 5 127.0.0.1 @PORT@ 2>/dev/null | head -n 1 | tr -d '\r'); t1=$(date +%s%N)
echo "ha_code=$(printf '%s' "$r" | awk '{ print $2 }')"; echo "ha_ms=$(( (t1 - t0) / 1000000 ))"
echo end=1
EOF
SAMPLE=${SAMPLE//@R@/$ROOT}; SAMPLE=${SAMPLE//@W@/$WIN}; SAMPLE=${SAMPLE//@PORT@/$PORT}
g sample "$SAMPLE" || fail "sample: the hub command exited non-zero"

# --- 2. /stats through the snap's python (script on stdin; numbers only) ------------------------------------
PY="$OUT/stats.py"
cat > "$PY" <<'EOF'
import json, re, sys, urllib.request
base = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:5001"
H = {"Remote-User": "admin", "Remote-Role": "admin"}
s = None
for p in ("/stats", "/api/stats"):
    try:
        with urllib.request.urlopen(urllib.request.Request(base + p, headers=H), timeout=20) as f:
            s = json.load(f)
        break
    except Exception:
        s = None
if not isinstance(s, dict):
    print("stats_ok=0")
    sys.exit(0)
name = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
def emit(k, v):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return
    if f != f or abs(f) > 1e15:
        return
    print("%s=%s" % (k, ("%d" % f) if f.is_integer() else ("%.3f" % f).rstrip("0").rstrip(".")))
pids = set()
for c, d in sorted((s.get("cameras") or {}).items()):
    if not name.match(str(c)) or not isinstance(d, dict):
        continue
    for k in ("camera_fps", "process_fps", "skipped_fps", "detection_fps", "pid", "capture_pid", "ffmpeg_pid"):
        emit("cam.%s.%s" % (c, k), d.get(k))
    for k in ("pid", "capture_pid", "ffmpeg_pid"):
        if isinstance(d.get(k), int):
            pids.add(d[k])
for n, d in sorted((s.get("detectors") or {}).items()):
    if not name.match(str(n)) or not isinstance(d, dict):
        continue
    for k in ("inference_speed", "pid"):
        emit("det.%s.%s" % (n, k), d.get(k))
    if isinstance(d.get("pid"), int):
        pids.add(d["pid"])
cu = s.get("cpu_usages") or {}
for p in sorted(pids):
    u = cu.get(str(p))
    if isinstance(u, dict):
        emit("cpu.%d.cpu" % p, u.get("cpu"))
        emit("cpu.%d.mem" % p, u.get("mem"))
sv = s.get("service") or {}
emit("service.uptime", sv.get("uptime"))
st = (sv.get("storage") or {}).get("/dev/shm") or {}
for k in ("total", "used", "free"):
    emit("service.shm.%s" % k, st.get(k))
print("stats_ok=1")
EOF
# shellcheck disable=SC2016  # $SNAP expands in the snap's shell on the hub
g stats 'snap run --shell frigate.frigate -c '"'"'"$SNAP/usr/bin/python3.11" -I -'"'" "$PY" || true

# --- parse ---------------------------------------------------------------------------------------------------
declare -A V P
while IFS='=' read -r k v; do [[ "$k" =~ ^[A-Za-z0-9_.:-]+$ ]] && V[$k]=$v; done < <(cat "$OUT/sample.txt" "$OUT/stats.txt")
if [ -n "$PREV" ]; then while IFS='=' read -r k v; do [[ "$k" =~ ^[A-Za-z0-9_.:-]+$ ]] && P[$k]=$v; done < "$PREV/counters.txt"; fi
num() { [[ "${1:-}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }
calc() { awk "BEGIN { $1 }"; }
mb() { if num "${1:-}"; then calc "printf \"%.0f\", ${1} / 1048576"; else echo "?"; fi; }
if [ "${V[end]:-}" != 1 ] || [ "${V[slice_cg_ok]:-}" != 1 ]; then fail "sample: incomplete (end=${V[end]:-missing}, slice cgroup readable=${V[slice_cg_ok]:-missing}); no verdict on the rest"; fi
CLK=${V[clk_tck]:-100}; num "$CLK" || CLK=100
DT=0; num "${V[a.t_ns]:-}" && num "${V[b.t_ns]:-}" && DT=$(calc "printf \"%.3f\", (${V[b.t_ns]} - ${V[a.t_ns]}) / 1e9")
cores() {  # cores KEY: CPUUsageNSec delta over the window, in cores
  local a=${V[a.$1]:-} b=${V[b.$1]:-}
  if num "$a" && num "$b" && calc "exit !($DT > 0)"; then calc "printf \"%.2f\", ($b - $a) / 1e9 / $DT"; else echo "?"; fi
}
d() { local a=${V[a.$1]:-} b=${V[b.$1]:-}; if num "$a" && num "$b"; then echo $(( b - a )); else echo "?"; fi; }

# --- units ---------------------------------------------------------------------------------------------------
why=""; nr=""
for n in frigate go2rtc nginx certsync; do
  [ "${V[b.$n.ActiveState]:-}" = active ] || why="$why $n is ${V[b.$n.ActiveState]:-unknown};"
  nr="$nr $n=${V[b.$n.NRestarts]:-?}"
  if [ -n "$PREV" ] && num "${P[$n.NRestarts]:-}" && num "${V[b.$n.NRestarts]:-}" && [ "${V[b.$n.NRestarts]}" -gt "${P[$n.NRestarts]}" ]; then
    why="$why $n NRestarts ${P[$n.NRestarts]} -> ${V[b.$n.NRestarts]};"
  fi
done
if [ -z "$why" ]; then pass "units: frigate go2rtc nginx certsync active; NRestarts$nr$([ -n "$PREV" ] && echo ", unchanged since --prev")"
else fail "units:$why"; fi

# --- memory --------------------------------------------------------------------------------------------------
info "memory: slice MemoryCurrent $(mb "${V[b.slice.MemoryCurrent]:-}") MB, MemoryPeak $(mb "${V[b.slice.MemoryPeak]:-}") MB, MemoryMax $(mb "${V[limit.MemoryMax]:-}") MB; memory.stat anon $(mb "${V[memstat.anon]:-}") MB, shmem $(mb "${V[memstat.shmem]:-}") MB, file $(mb "${V[memstat.file]:-}") MB"
info "memory per unit (MemoryCurrent / MemoryPeak MB): frigate $(mb "${V[b.frigate.MemoryCurrent]:-}")/$(mb "${V[b.frigate.MemoryPeak]:-}") go2rtc $(mb "${V[b.go2rtc.MemoryCurrent]:-}")/$(mb "${V[b.go2rtc.MemoryPeak]:-}") nginx $(mb "${V[b.nginx.MemoryCurrent]:-}")/$(mb "${V[b.nginx.MemoryPeak]:-}") certsync $(mb "${V[b.certsync.MemoryCurrent]:-}")/$(mb "${V[b.certsync.MemoryPeak]:-}")"
if [ -n "$PREV" ] && num "${P[slice.MemoryCurrent]:-}" && num "${V[b.slice.MemoryCurrent]:-}"; then
  info "memory since --prev: slice MemoryCurrent $(mb "${P[slice.MemoryCurrent]}") -> $(mb "${V[b.slice.MemoryCurrent]}") MB; anon $(mb "${P[memstat.anon]:-}") -> $(mb "${V[memstat.anon]:-}") MB"
fi

# --- cpu ---------------------------------------------------------------------------------------------------
info "cpu over the ${DT} s window (cores): slice $(cores slice.CPUUsageNSec), frigate $(cores frigate.CPUUsageNSec), go2rtc $(cores go2rtc.CPUUsageNSec), nginx $(cores nginx.CPUUsageNSec); quota CPUQuotaPerSecUSec=${V[limit.CPUQuotaPerSecUSec]:-?}"
np=$(d cpustat.nr_periods); nt=$(d cpustat.nr_throttled); tu=$(d cpustat.throttled_usec)
info "throttle over the window: nr_throttled +$nt of +$np periods, throttled_usec +$tu"
if [ -n "$PREV" ] && num "${P[t_ns]:-}" && num "${V[b.t_ns]:-}"; then
  IV=$(calc "printf \"%.0f\", (${V[b.t_ns]} - ${P[t_ns]}) / 1e9")
  avg() { if num "${P[$1]:-}" && num "${V[b.$1]:-}" && [ "$IV" -gt 0 ]; then calc "printf \"%.2f\", (${V[b.$1]} - ${P[$1]}) / 1e9 / $IV"; else echo "?"; fi; }
  pd() { if num "${P[$1]:-}" && num "${V[b.$1]:-}"; then echo $(( ${V[b.$1]} - ${P[$1]} )); else echo "?"; fi; }
  info "cpu since --prev (${IV} s, average cores): slice $(avg slice.CPUUsageNSec), frigate $(avg frigate.CPUUsageNSec), go2rtc $(avg go2rtc.CPUUsageNSec); throttle nr_throttled +$(pd cpustat.nr_throttled) of +$(pd cpustat.nr_periods) periods, throttled_usec +$(pd cpustat.throttled_usec)"
fi
# per process %CPU over the window (same start time in both reads), heaviest first
PROCS=""
for k in "${!V[@]}"; do
  case "$k" in label.*) ;; *) continue ;; esac
  pid=${k#label.}; read -r a_t a_s <<<"${V[a.proc.$pid]:-}"; read -r b_t b_s <<<"${V[b.proc.$pid]:-}"
  { num "${a_t:-}" && num "${b_t:-}" && [ "${a_s:-}" = "${b_s:-}" ] && calc "exit !($DT > 0)"; } || continue
  read -r u c r s _ <<<"${V[$k]}"
  PROCS+="$(calc "printf \"%.1f\", ($b_t - $a_t) / $CLK / $DT * 100") $u:$c:$r:$s"$'\n'
done
info "processes %CPU over the window (unit:comm:role:stream): $(printf '%s' "$PROCS" | sort -rn | head -n 12 | awk '{ printf "%s %s%%; ", $2, $1 }' | sed 's/; $//')"

# --- go2rtc exec ffmpegs ---------------------------------------------------------------------------------------
GPID=${V[b.go2rtc.MainPID]:-}; EXECS=(); : > "$OUT/execs.txt"
for k in "${!V[@]}"; do
  case "$k" in label.*) ;; *) continue ;; esac
  pid=${k#label.}; read -r u c r s pp <<<"${V[$k]}"
  if [ "$u" != go2rtc ] || [ "$c" != ffmpeg ] || [ "$pp" != "$GPID" ] || [[ "$r" != *e* ]]; then continue; fi
  read -r _ st <<<"${V[b.proc.$pid]:-}"
  age="?"; num "${st:-}" && num "${V[b.uptime]:-}" && age=$(calc "printf \"%.0f\", ${V[b.uptime]} - $st / $CLK")
  EXECS+=("$s"); printf 'exec.%s=%s %s\n' "$s" "$pid" "${st:-?}" >> "$OUT/execs.txt"
  info "go2rtc exec ffmpeg: clip $s pid $pid, running ${age} s"
done
if [ "$NEX" -gt 0 ]; then
  why=""; [ "${#EXECS[@]}" = "$NEX" ] || why=" ${#EXECS[@]} exec ffmpegs, want $NEX;"
  if [ -n "$PREV" ]; then
    while IFS='=' read -r k v; do
      case "$k" in exec.*) ;; *) continue ;; esac
      nowv=$(sed -n "s/^${k//./\\.}=//p" "$OUT/execs.txt" | head -n 1)
      [ "$nowv" = "$v" ] || why="$why ${k#exec.} restarted since --prev (pid/start $v -> ${nowv:-none});"
    done < <(grep '^exec\.' "$PREV/counters.txt")
  fi
  if [ -z "$why" ]; then pass "go2rtc exec: ${#EXECS[@]} exec ffmpegs (${EXECS[*]})$([ -n "$PREV" ] && echo ", none restarted since --prev")"
  else fail "go2rtc exec:$why"; fi
fi

# --- shm ---------------------------------------------------------------------------------------------------------
fr=""; for k in "${!V[@]}"; do case "$k" in shm_frames.*) fr="$fr ${k#shm_frames.}=${V[$k]}" ;; esac; done
info "shm: /dev/shm/snap.frigate $(mb "${V[shm_bytes]:-}") MB (${V[shm_bytes]:-?} B); frame files per camera:${fr:- none}; Frigate's own /stats storage /dev/shm used ${V[service.shm.used]:-?} of ${V[service.shm.total]:-?} (as Frigate reports it, MiB)"

# --- Frigate /stats ------------------------------------------------------------------------------------------------
if [ "${V[stats_ok]:-}" != 1 ]; then fail "stats: /stats not readable through the snap's python"
else
  pass "stats: /stats read (Frigate uptime ${V[service.uptime]:-?} s)"
  IFS=',' read -r -a FA <<<"$FPS"
  for cf in "${FA[@]}"; do
    c=${cf%%=*}; want=${cf#*=}; cfps=${V[cam.$c.camera_fps]:-}; sk=${V[cam.$c.skipped_fps]:-}
    line="camera_fps ${cfps:-?} (native $want), process_fps ${V[cam.$c.process_fps]:-?}, skipped_fps ${sk:-?}, detection_fps ${V[cam.$c.detection_fps]:-?}"
    cp=${V[cam.$c.ffmpeg_pid]:-}; [ -n "$cp" ] && line="$line; ffmpeg %CPU ${V[cpu.$cp.cpu]:-?}, capture %CPU ${V[cpu.${V[cam.$c.capture_pid]:-x}.cpu]:-?}, process %CPU ${V[cpu.${V[cam.$c.pid]:-x}.cpu]:-?} (Frigate's own)"
    if num "$cfps" && num "$sk" && calc "exit !($cfps >= $want * 0.9 && $sk == 0)"; then pass "camera $c: $line"
    else fail "camera $c: $line"; fi
  done
  ok=0
  for k in "${!V[@]}"; do
    case "$k" in det.*.inference_speed) ;; *) continue ;; esac
    n=${k#det.}; n=${n%.inference_speed}; sp=${V[$k]}
    if num "$sp" && calc "exit !($sp > 0)"; then pass "detector $n: inference_speed $sp ms, %CPU ${V[cpu.${V[det.$n.pid]:-x}.cpu]:-?}"; ok=1
    else fail "detector $n: inference_speed '${sp}'"; ok=1; fi
  done
  [ "$ok" = 1 ] || fail "detector: no detector in /stats"
fi
info "coral usb: ${V[usb]:-not found} (18d1:9302 = initialised by the runtime, 1a6e:089a = not yet)"
info "host: load ${V[load1]:-?} ${V[load5]:-?} ${V[load15]:-?}; MemAvailable $(( ${V[memavail_kb]:-0} / 1024 )) MB; swap used $(( ${V[swap_used_kb]:-0} / 1024 )) MB; PSI some avg60 memory ${V[psi_memory]:-?} cpu ${V[psi_cpu]:-?}; Home Assistant HTTP ${V[ha_code]:-none} in ${V[ha_ms]:-?} ms"
if [ "$CRED" = 0 ]; then pass "hygiene: no credential-like text in what the hub sent"
else fail "hygiene: $CRED credential-like line(s) came from the hub (scrubbed in the evidence; not shown)"; fi

# --- counters for the next --prev ------------------------------------------------------------------------------
{ for k in "${!V[@]}"; do case "$k" in b.*) printf '%s=%s\n' "${k#b.}" "${V[$k]}" ;; memstat.*) printf '%s=%s\n' "$k" "${V[$k]}" ;; esac; done
  cat "$OUT/execs.txt"; } | sort > "$OUT/counters.txt"
echo "observe: $(grep -c '^PASS' "$RESULTS") PASS, $FAILS FAIL, $(grep -c '^INFO' "$RESULTS") INFO (evidence: $OUT)"
[ "$FAILS" = 0 ]
