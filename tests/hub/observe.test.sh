#!/usr/bin/env bash
# shellcheck disable=SC2016  # PRE strings are single-quoted on purpose: run() evals them with its own $T and $n
# tests/hub/observe.sh against a fake hub: ssh-exec.sh -> fixtures/stub/ssh -> fixtures/observe-responder.sh, which
# runs observe.sh's REAL sample script under /bin/sh on a fake /proc + /sys + /dev/shm tree (M7C_OBSERVE_ROOT) with
# stub systemctl/sleep/date/nc/snap, and the REAL /stats python script against a local loopback HTTP server.
# Canary credentials sit in a process command line and in the /stats JSON: they must appear nowhere.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1; fail=0; T=$(mktemp -d); SRV=""
# shellcheck disable=SC2317  # runs from the EXIT trap
cleanup() { [ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
has()   { grep -qF -- "$2" "$3"; check "$1" 0 $?; }
hasnt() { grep -qF -- "$2" "$3"; check "$1" 1 $?; }
OB=tests/hub/observe.sh; FX=$PWD/tests/hub/fixtures; CAN=QZOBSCANARY
SL='snap.frigate\x2dmem.slice'

# --- the /stats server (loopback, random port; stopped by PID) ---
mkdir -p "$T/www"
PORT=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$T/www" > "$T/srv.log" 2>&1 & SRV=$!
for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break; sleep 0.1; done
stats() {  # stats NAME [cam1_fps] [cam1_skipped] [inference]: /stats JSON for run NAME (camera_fps = detect output, 5)
  mkdir -p "$T/www/$1"
  cat > "$T/www/$1/stats" <<EOF
{"cameras": {"cam1": {"camera_fps": ${2:-5.1}, "process_fps": 5.0, "skipped_fps": ${3:-0.0}, "detection_fps": 1.2, "pid": 1010, "capture_pid": 1011, "ffmpeg_pid": 1002, "ffmpeg_cmd": "rtsp://admin:$CAN@192.0.2.50/x"},
             "cam2": {"camera_fps": 5.0, "process_fps": 5.0, "skipped_fps": 0.0, "detection_fps": 0.4, "pid": 1012, "capture_pid": 1013, "ffmpeg_pid": 1004},
             "bad name;x": {"camera_fps": 1}},
 "detectors": {"coral": {"inference_speed": ${4:-8.5}, "pid": 1005, "detection_start": 0.0}},
 "cpu_usages": {"1002": {"cpu": "48.0", "mem": "1.2", "cmdline": "ffmpeg -i rtsp://admin:$CAN@192.0.2.50/x"}, "1005": {"cpu": "3.0", "mem": "2.0"}},
 "service": {"uptime": 1800, "version": "0.18.2", "storage": {"/dev/shm": {"total": 7972.1, "used": 140.5, "free": 7831.6}}}}
EOF
}

# --- the fake hub tree ---
pstat() {  # pstat DIR PID COMM PPID UTIME START [UTIME_B]: /proc/PID/stat (and stat.b for phase b)
  local d="$1/proc/$2"; mkdir -p "$d"
  printf '%s (%s) S %s 0 0 0 0 0 0 0 0 0 %s 0 0 0 20 0 1 0 %s 0 0\n' "$2" "$3" "$4" "$5" "$6" > "$d/stat"
  printf '%s (%s) S %s 0 0 0 0 0 0 0 0 0 %s 0 0 0 20 0 1 0 %s 0 0\n' "$2" "$3" "$4" "${7:-$5}" "$6" > "$d/stat.b"
  printf '%s\n' "$3" > "$d/comm"
}
cmdl() { printf '%s\0' "${@:3}" > "$1/proc/$2/cmdline"; }
mktree() {  # mktree TREE: the hub as the trial should look (3 exec ffmpegs, 2 cameras, Coral initialised)
  local t=$1 r=$1/root cg; mkdir -p "$t/units" "$r/proc/pressure" "$r/dev/shm/snap.frigate/logs" "$r/sys/bus/usb/devices/2-1"
  echo a > "$t/phase"; : > "$t/slept"
  cg="$r/sys/fs/cgroup/$SL"
  mkdir -p "$cg/snap.frigate.frigate.service" "$cg/snap.frigate.go2rtc.service" "$cg/snap.frigate.nginx.service" "$cg/snap.frigate.certsync.service"
  printf 'ControlGroup=/%s\nMemoryCurrent=1073741824\nMemoryPeak=1181116006\nMemoryMax=4294967296\nCPUQuotaPerSecUSec=2s\nCPUUsageNSec=100000000000\nCPUUsageNSec.b=112000000000\n' "$SL" > "$t/units/$SL"
  printf 'ActiveState=active\nMainPID=1001\nNRestarts=0\nMemoryCurrent=900000000\nMemoryPeak=950000000\nCPUUsageNSec=80000000000\nCPUUsageNSec.b=89000000000\n' > "$t/units/snap.frigate.frigate.service"
  printf 'ActiveState=active\nMainPID=2001\nNRestarts=0\nMemoryCurrent=60000000\nMemoryPeak=70000000\nCPUUsageNSec=5000000000\nCPUUsageNSec.b=5300000000\n' > "$t/units/snap.frigate.go2rtc.service"
  printf 'ActiveState=active\nMainPID=3001\nNRestarts=0\nMemoryCurrent=20000000\nMemoryPeak=25000000\nCPUUsageNSec=1000000000\n' > "$t/units/snap.frigate.nginx.service"
  printf 'ActiveState=active\nMainPID=4001\nNRestarts=0\nMemoryCurrent=3000000\nMemoryPeak=4000000\nCPUUsageNSec=100000000\n' > "$t/units/snap.frigate.certsync.service"
  printf 'usage_usec 100000000\nnr_periods 1000\nnr_throttled 10\nthrottled_usec 5000\n' > "$cg/cpu.stat"
  printf 'usage_usec 112000000\nnr_periods 1100\nnr_throttled 12\nthrottled_usec 6000\n' > "$cg/cpu.stat.b"
  printf 'anon 734003200\nfile 209715200\nkernel 1000\nshmem 146800640\n' > "$cg/memory.stat"
  printf '1001\n1002\n1003\n1004\n1005\n' > "$cg/snap.frigate.frigate.service/cgroup.procs"
  printf '2001\n2002\n2003\n2004\n' > "$cg/snap.frigate.go2rtc.service/cgroup.procs"
  printf '3001\n' > "$cg/snap.frigate.nginx.service/cgroup.procs"; printf '4001\n' > "$cg/snap.frigate.certsync.service/cgroup.procs"
  pstat "$r" 1001 python3.11 1 2000 100000 2200; cmdl "$r" 1001 python3.11 -u -m frigate
  pstat "$r" 1002 ffmpeg 1011 1000 110000 1500
  cmdl "$r" 1002 ffmpeg -i rtsp://127.0.0.1:8554/cam1 -f segment /x/%Y.mp4 -r 5 -f rawvideo -pix_fmt yuv420p pipe:
  pstat "$r" 1003 ffmpeg 1013 100 110000 105; cmdl "$r" 1003 ffmpeg -i rtsp://127.0.0.1:8554/cam2 -f segment /x/%Y.mp4
  pstat "$r" 1004 ffmpeg 1013 100 110000 130; cmdl "$r" 1004 ffmpeg -i rtsp://127.0.0.1:8554/cam2_sub -f rawvideo pipe:
  pstat "$r" 1005 frigate.detecto 1001 300 100500 330; cmdl "$r" 1005 frigate.detector:coral
  pstat "$r" 2001 go2rtc 1 500 90000 510; cmdl "$r" 2001 go2rtc -config /var/snap/frigate/x1/go2rtc.yaml
  local s p
  for s in cam1:2002:main-1080p25 cam2:2003:main-1080p25 cam2_sub:2004:sub-360p15; do
    p=$(echo "$s" | cut -d: -f2)
    pstat "$r" "$p" ffmpeg 2001 50 400000 52
    cmdl "$r" "$p" /snap/frigate/current/usr/lib/ffmpeg/8.0/bin/ffmpeg -re -stream_loop -1 -i "/var/snap/frigate/common/m7c-clips/$(echo "$s" | cut -d: -f3).mp4" -c copy -an -metadata "title=m7c-${s%%:*}" -f rtsp rtsp://127.0.0.1:8554/xyz
  done
  pstat "$r" 3001 nginx 1 10 90000; cmdl "$r" 3001 nginx -g "upstream rtsp://admin:$CAN@192.0.2.50/live"
  pstat "$r" 4001 bash 1 1 90000; cmdl "$r" 4001 bash certsync-run
  echo '5000.00 18000.00' > "$r/proc/uptime"; echo '1.20 1.10 0.90 2/300 4321' > "$r/proc/loadavg"
  printf 'MemTotal: 16000000 kB\nMemAvailable: 12000000 kB\nSwapTotal: 4194304 kB\nSwapFree: 4194304 kB\n' > "$r/proc/meminfo"
  printf 'some avg10=0.00 avg60=0.50 avg300=0.10 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$r/proc/pressure/memory"
  printf 'some avg10=1.00 avg60=2.50 avg300=1.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$r/proc/pressure/cpu"
  local i; for i in $(seq 0 49); do head -c 1000 /dev/zero > "$r/dev/shm/snap.frigate/cam1_frame$i"; head -c 500 /dev/zero > "$r/dev/shm/snap.frigate/cam2_frame$i"; done
  echo 18d1 > "$r/sys/bus/usb/devices/2-1/idVendor"; echo 9302 > "$r/sys/bus/usb/devices/2-1/idProduct"
}
run() {  # run NAME [env...] -- observe args. A fresh tree and stats for NAME unless PRE changes them.
  local n=$1; shift; local -a e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  mkdir -p "$T/$n/st"; : > "$T/$n/st/log"; : > "$T/$n/st/cmds"; mktree "$T/$n/tree"; stats "$n"
  [ -n "${PRE:-}" ] && eval "$PRE"
  env STUB_ST="$T/$n/st" STUB_RESPONDER="$FX/observe-responder.sh" M7C_SSH="$FX/stub/ssh" M7C_HUB_SOCK=/run/test/m7c.sock \
    M7C_HUB_TARGET=hub-test OBS_TREE="$T/$n/tree" M7C_OBSERVE_ROOT="$T/$n/tree/root" OBS_URL="http://127.0.0.1:$PORT/$n" "${e[@]}" \
    timeout 60 bash "$OB" --out "$T/$n/ev" "$@" > "$T/$n.out" 2>&1; echo $? > "$T/$n.rc"
}
rc() { cat "$T/$1.rc"; }; O() { echo "$T/$1.out"; }
noleak() { local n=$1; check "$n: no canary in the output, the evidence or the commands" 0 "$(grep -rlF -- "$CAN" "$T/$n.out" "$T/$n/ev" "$T/$n/st/cmds" 2>/dev/null | wc -l)"; }

# --- usage (exit 2, nothing sent) ---
run u1 -- --window 0;            check "--window 0: exit 2" 2 "$(rc u1)"
run u2 -- --fps 'cam1=x';        check "bad --fps: exit 2" 2 "$(rc u2)"
run u3 -- --prev "$T/none";      check "--prev without counters.txt: exit 2" 2 "$(rc u3)"
run u4 -- --ha-port 70000;       check "bad --ha-port: exit 2" 2 "$(rc u4)"
check "usage sends no hub command" 0 "$(cat "$T"/u?/st/cmds | wc -l)"
PRE='touch "$T/$n/st/gone"' run g1 --; check "master gone: exit 3" 3 "$(rc g1)"; has "master gone: loud" "MASTER GONE" "$(O g1)"

# --- happy ---
run h1 --
check "happy: exit 0" 0 "$(rc h1)"
has   "happy: summary" "observe: 7 PASS, 0 FAIL, 12 INFO" "$(O h1)"
has   "units PASS" "PASS: units: frigate go2rtc nginx certsync active; NRestarts frigate=0 go2rtc=0 nginx=0 certsync=0" "$(O h1)"
has   "memory INFO" "INFO: memory: slice MemoryCurrent 1024 MB, MemoryPeak 1126 MB, MemoryMax 4096 MB; memory.stat anon 700 MB, shmem 140 MB, file 200 MB" "$(O h1)"
has   "memory per unit, go2rtc included" "frigate 858/906 go2rtc 57/67 nginx 19/24 certsync 3/4" "$(O h1)"
has   "cpu over the window (CPUUsageNSec deltas)" "INFO: cpu over the 10.000 s window (cores): slice 1.20, frigate 0.90, go2rtc 0.03, nginx 0.00; quota CPUQuotaPerSecUSec=2s" "$(O h1)"
has   "throttle over the window" "INFO: throttle over the window: nr_throttled +2 of +100 periods, throttled_usec +1000" "$(O h1)"
has   "per-process %CPU: the 1080p detect+record ffmpeg first" "processes %CPU over the window (unit:comm:role:stream): frigate:ffmpeg:dr:cam1 50.0%; frigate:python3.11:-:- 20.0%" "$(O h1)"
has   "per-process %CPU: cam2_sub detect" "frigate:ffmpeg:d:cam2_sub 3.0%" "$(O h1)"
has   "exec PASS names the three streams" "PASS: go2rtc exec: 3 exec ffmpegs (" "$(O h1)"
for s in cam1 cam2 cam2_sub; do has "exec $s found with its age" "go2rtc exec ffmpeg: clip $s pid" "$(O h1)"; done
has   "exec age from the start time" "running 1000 s" "$(O h1)"
has   "shm frames cam1" "cam1=50" "$(O h1)"; has "shm frames cam2" "cam2=50" "$(O h1)"
has   "shm Frigate's own storage numbers" "used 140.5 of 7972.1" "$(O h1)"
has   "stats PASS" "PASS: stats: /stats read (Frigate uptime 1800 s)" "$(O h1)"
has   "camera cam1 PASS against detect fps 5 by default" "PASS: camera cam1: camera_fps 5.1 (detect fps 5), process_fps 5, skipped_fps 0, detection_fps 1.2; ffmpeg %CPU 48" "$(O h1)"
has   "camera cam2 PASS against detect fps 5 by default" "PASS: camera cam2: camera_fps 5 (detect fps 5)" "$(O h1)"
has   "decode headroom: each detect ffmpeg's %CPU, by stream (record-only and exec ffmpegs left out)" "INFO: decode headroom (detect ffmpeg %CPU over the window; 100 = one core; a decode slower than real time also lowers camera_fps): cam1 50.0, cam2_sub 3.0" "$(O h1)"
has   "detector PASS" "PASS: detector coral: inference_speed 8.5 ms, %CPU 3" "$(O h1)"
has   "coral usb id" "INFO: coral usb: 18d1:9302" "$(O h1)"
has   "host line" "INFO: host: load 1.20 1.10 0.90; MemAvailable 11718 MB; swap used 0 MB; PSI some avg60 memory 0.50 cpu 2.50; Home Assistant HTTP 200 in 0 ms" "$(O h1)"
has   "hygiene PASS" "PASS: hygiene: no credential-like text in what the hub sent" "$(O h1)"
hasnt "an odd camera name from /stats is dropped" "bad name" "$T/h1/ev/stats.txt"
has   "the window is 10 s by default" "10" "$T/h1/tree/slept"
check "two hub commands only: the sample and /stats" "1 1 2" "$(grep -cx 'echo m7c-observe-sample' "$T/h1/st/cmds") $(grep -c '^snap run --shell frigate.frigate -c' "$T/h1/st/cmds") $(cat "$T/h1/st/sessions")"
check "both are reads: no snap set/start/stop, no rm/cp/mv/tee/mkdir/chmod, no redirect but 2>/dev/null" 0 \
  "$(sed 's#2>/dev/null##g' "$T/h1/st/cmds" | grep -cE 'snap (set|unset|start|stop|restart)|(^|[ ;|&(])(rm|cp|mv|tee|truncate|mkdir|chmod|chown|kill) |>')"
has   "counters.txt for --prev: NRestarts" "frigate.NRestarts=0" "$T/h1/ev/counters.txt"
has   "counters.txt for --prev: exec cam2 pid and start" "exec.cam2=2003 400000" "$T/h1/ev/counters.txt"
noleak h1

# --- --prev: unchanged, then restarts ---
run p1 OBS_T0=1700001800 -- --prev "$T/h1/ev"
check "--prev unchanged: exit 0" 0 "$(rc p1)"
has   "--prev: NRestarts unchanged" "certsync=0, unchanged since --prev" "$(O p1)"
has   "--prev: no exec restarted" "none restarted since --prev" "$(O p1)"
has   "--prev: interval averages" "INFO: cpu since --prev (1800 s, average cores): slice 0.00" "$(O p1)"
PRE='sed -i "s/^NRestarts=0/NRestarts=2/" "$T/$n/tree/units/snap.frigate.frigate.service"' run p2 OBS_T0=1700001800 -- --prev "$T/h1/ev"
check "--prev, frigate restarted twice: exit 1" 1 "$(rc p2)"; has "names the unit" "FAIL: units: frigate NRestarts 0 -> 2;" "$(O p2)"
PRE='pstat "$T/$n/tree/root" 2003 ffmpeg 2001 5 470000 6' run p3 OBS_T0=1700001800 -- --prev "$T/h1/ev"
check "--prev, cam2's exec ffmpeg restarted: exit 1" 1 "$(rc p3)"; has "names the stream" "cam2 restarted since --prev (pid/start 2003 400000 -> 2003 470000)" "$(O p3)"

# --- failures ---
PRE='sed -i "s/^ActiveState=active/ActiveState=failed/" "$T/$n/tree/units/snap.frigate.go2rtc.service"' run f1 --
check "go2rtc failed: exit 1" 1 "$(rc f1)"; has "units FAIL names it" "FAIL: units: go2rtc is failed;" "$(O f1)"
PRE='stats "$n" 4.0' run f2 --;           check "cam1 at 4 of 5 fps: exit 1" 1 "$(rc f2)"; has "camera FAIL" "FAIL: camera cam1: camera_fps 4 (detect fps 5)" "$(O f2)"
PRE='stats "$n" 4.0' run f2b -- --fps cam1=4,cam2=5; check "--fps cam1=4: 4 passes" 0 "$(rc f2b)"
PRE='stats "$n" 5.0 1.5' run f3 --;      check "cam1 skipped_fps 1.5: exit 1" 1 "$(rc f3)"; has "skipped FAIL" "skipped_fps 1.5" "$(O f3)"
run f4 OBS_URL="http://127.0.0.1:1/none" --; check "/stats unreachable: exit 1" 1 "$(rc f4)"; has "stats FAIL" "FAIL: stats: /stats not readable" "$(O f4)"
PRE='stats "$n" 5.0 0.0 0' run f5 --;    check "inference_speed 0: exit 1" 1 "$(rc f5)"; has "detector FAIL" "FAIL: detector coral: inference_speed '0'" "$(O f5)"
PRE='printf "2001\n2002\n2003\n" > "$T/$n/tree/root/sys/fs/cgroup/$SL/snap.frigate.go2rtc.service/cgroup.procs"' run f6 --
check "2 exec ffmpegs: exit 1" 1 "$(rc f6)"; has "exec FAIL" "FAIL: go2rtc exec: 2 exec ffmpegs, want 3;" "$(O f6)"
run f7 OBS_LEAK="$CAN" --; check "a credential-like line from the hub: exit 1" 1 "$(rc f7)"; has "hygiene FAIL, count only" "FAIL: hygiene: 11 credential-like line(s)" "$(O f7)"; noleak f7
run f8 -- --execs 0; check "--execs 0: exit 0" 0 "$(rc f8)"; hasnt "--execs 0: no exec verdict" "go2rtc exec:" "$(O f8)"
PRE='sed -i "s#^ControlGroup=.*#ControlGroup=/nope.slice#" "$T/$n/tree/units/$SL"' run f9 --
check "slice cgroup unreadable: exit 1" 1 "$(rc f9)"; has "sample FAIL" "FAIL: sample: incomplete" "$(O f9)"
run w1 -- --window 3; check "--window 3: exit 0" 0 "$(rc w1)"; check "--window 3 is the hub sleep" 3 "$(cat "$T/w1/tree/slept")"
has "--window 3: the window is 10 s of fake clock" "over the 10.000 s window" "$(O w1)"

# --- go2rtc ezviz-source helpers (--helpers N): label h and the camera name only, never a command line (C4) ---
run oh1 O_HELPERS="501:cam1 502:cam2" -- --execs 0 --helpers 2
check "--helpers 2: exit 0" 0 "$(rc oh1)"; has "helpers PASS names both" "PASS: go2rtc helpers: 2 (cam1 cam2)" "$(O oh1)"
hasnt "no exec verdict with --execs 0" "go2rtc exec:" "$(O oh1)"
PRE='cp -r "$T/oh1/ev" "$T/$n/prev"' run oh2 O_HELPERS="501:cam1 777:cam2" -- --execs 0 --helpers 2 --prev "$T/oh2/prev"
check "a helper restarted since --prev: exit 1" 1 "$(rc oh2)"; has "names the restarted helper" "FAIL: go2rtc helpers: cam2 restarted since --prev" "$(O oh2)"
hasnt "never a whole command line" "rtsp://127.0.0.1:8554/x" "$(O oh2)"
run oh3 O_HELPERS="501:cam1" -- --execs 0 --helpers 2; check "1 helper, want 2: exit 1" 1 "$(rc oh3)"; has "says the count" "FAIL: go2rtc helpers: 1 helpers, want 2;" "$(O oh3)"
run oh4 O_HELPERS="501:cam1 502:CamX" -- --execs 0 --helpers 2; check "a helper whose camera name is not ^[a-z0-9_]{1,32}$: exit 1" 1 "$(rc oh4)"
hasnt "an invalid camera name is never printed" "CamX" "$(O oh4)"
check "helpers: no helper command line in the output or the evidence" 0 "$(grep -rlF -- 'ezviz_source.main' "$T"/oh?.out "$T"/oh?/ev | wc -l)"

# every tests/hub script runs directly (git mode 100755), as the orchestrator calls them
for f in tests/hub/*.sh; do check "$f is executable in git" 100755 "$(git ls-files -s "$f" | awk '{ print $1 }')"; done

[ "$fail" = 0 ] && echo "observe.test: all ok" || echo "observe.test: FAILURES"
exit "$fail"
