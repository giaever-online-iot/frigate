#!/usr/bin/env bash
# Fake hub for tests/hub/observe.test.sh (the stub ssh's $STUB_RESPONDER). $1 = "sudo -n sh -c '<cmd>'". The
# command runs FOR REAL under /bin/sh with fixtures/observe-stub first on PATH (systemctl, sleep, date, nc, snap),
# so observe.sh's own sample script is what is tested; M7C_OBSERVE_ROOT points it at a fake /proc, /sys and
# /dev/shm tree. Every <cmd> is appended to $STUB_ST/cmds. stdin passes through (the /stats python script).
# O_HELPERS="<pid>:<cam> ...": before the sample runs, adds ezviz-source helper processes to the go2rtc unit (parent
# go2rtc's MainPID 2001, fixed start time) whose args are `python3.12 -I -B -m ezviz_source.main <cam> rtsp://...`.
set -u
st="${STUB_ST:?}"; fx=$(cd "$(dirname "$0")" && pwd)
eval "set -- $1"
[ "$1 $2 $3 $4" = "sudo -n sh -c" ] || { echo "responder: not a sudo -n sh -c call: $*" >&2; exit 99; }
cmd=$5; printf '%s\n' "$cmd" >> "$st/cmds"
if [ -n "${O_HELPERS:-}" ] && [ "${cmd%%$'\n'*}" = "echo m7c-observe-sample" ]; then
  r="${OBS_TREE:?}/root"; procs="$r/sys/fs/cgroup/snap.frigate\x2dmem.slice/snap.frigate.go2rtc.service/cgroup.procs"
  for h in $O_HELPERS; do
    pid=${h%%:*}; cam=${h#*:}; mkdir -p "$r/proc/$pid"; echo "$pid" >> "$procs"
    printf '%s (python3.12) S 2001 0 0 0 0 0 0 0 0 0 20 0 0 0 20 0 1 0 450000 0 0\n' "$pid" > "$r/proc/$pid/stat"
    echo python3.12 > "$r/proc/$pid/comm"
    printf '%s\0' python3.12 -I -B -m ezviz_source.main "$cam" rtsp://127.0.0.1:8554/x > "$r/proc/$pid/cmdline"
  done
fi
PATH="$fx/observe-stub:$PATH" exec sh -c "$cmd"
