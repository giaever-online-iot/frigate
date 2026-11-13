#!/usr/bin/env bash
# M7c T12: the arm64 VM battery (spec §9 V5-V11, V17, V18; D10 Review Focus 3).
# Runs on the HOST. Every guest step goes through `vm.sh exec` (qemu-guest-agent); no SSH, no other host.
# Usage: M7C_VM_DIR=<run dir> tests/arm64-vm/battery.sh <channel>
# Prints one `PASS: Vn ...`, `FAIL: Vn ...` or `INFO: Vn ...` line per check, writes evidence to
# $M7C_VM_DIR/out/battery/ (the guest's /mnt/out/battery/) and exits 1 on any FAIL.
# Test hooks: M7C_VM_SH overrides the vm.sh path (a stub, for a dry run without a VM).
set -uo pipefail   # no -e: a failing check must not abort the later independent checks
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
. "$REPO/tests/lib/harness-arch.sh"
. "$HERE/lib-checks.sh"

CH="${1:-}"
case "$CH" in
  ''|*[!A-Za-z0-9./_-]*) echo "usage: battery.sh <channel>   (e.g. latest/edge/pr5; [A-Za-z0-9./_-] only)" >&2; exit 2 ;;
esac
[ -n "${M7C_VM_DIR:-}" ] || { echo "battery.sh: set M7C_VM_DIR (the vm.sh run dir)" >&2; exit 2; }
command -v jq >/dev/null || { echo "battery.sh: jq is required on the host" >&2; exit 2; }
scaled 1 >/dev/null || exit 2

VM="${M7C_VM_SH:-$HERE/vm.sh}"
OUT="$M7C_VM_DIR/out/battery"; GOUT=/mnt/out/battery
FIX="$HERE/fixtures/m7c-config.yml.in"; TEMPLATE="$REPO/spike/config/frigate-config.yml"
SC=/var/snap/frigate/common; R="$SC/spike-results"; CFG=/var/snap/frigate/current/config/config.yml
CLIP="$SC/m7c/h265.mp4"; SHMDIR=/dev/shm/snap.frigate; SMF="$SC/shm-max-frames"; QG=m7c-t
UNIT=snap.frigate.frigate.service
AUTH_H="-H 'Remote-User: admin' -H 'Remote-Role: admin'"
D10_ERROR='frigate-run: ERROR config.yml uses the openvino detector, which cannot run on arm64; set it to cpu or coral (or delete config.yml to re-render)'
W=640; H=360; FRAMES=50; CAMS=2
mkdir -p "$OUT"; RESULTS="$OUT/results.txt"; : > "$RESULTS"

g()  { "$VM" exec "$1"; }                                  # one /bin/sh -c string, run as root in the guest
gw() { QGA_TIMEOUT="$(scaled 60)" "$VM" exec "$1"; }        # bounded call for the V11 watch (a hung agent = down)
say()  { echo "$*"; echo "$*" >> "$RESULTS"; }
FAILS=0
pass() { say "PASS: $*"; }
fail() { say "FAIL: $*"; FAILS=$((FAILS + 1)); }
info() { say "INFO: $*"; }
is_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; }
one_line() { tr '\n' ' ' | sed 's/  */ /g; s/ $//' | cut -c1-240; }

# poll SECS INTERVAL CMD...: CMD until it succeeds, at most SECS of wall time and SECS/INTERVAL retries.
poll() {
  local secs=${1%.*} iv=$2 i=0 n end; shift 2
  n=$(( secs / iv )); end=$(( $(date +%s) + secs ))
  while :; do
    "$@" && return 0
    i=$((i + 1))
    { [ "$i" -le "$n" ] && [ "$(date +%s)" -lt "$end" ]; } || return 1
    isleep "$iv"
  done
}
# isleep N: an interruptible sleep. Bash defers a trap until a FOREGROUND child exits, so a TERM during a
# `scaled 1800` sleep would wait hours; `wait` on a background sleep returns at once and the trap runs.
SLEEP_PID=""
isleep() { command sleep "$1" & SLEEP_PID=$!; wait "$SLEEP_PID"; SLEEP_PID=""; }
wait_s() { isleep "$(scaled "$1")"; }                     # a scaled fixed wait (scaled once, never twice)

# --- configs: rendered on the host into the shared out dir, installed in the guest (0600) -----------
render() { sed "s|__SNAP_COMMON__|/var/snap/frigate/common|g" "$1" > "$2"; }
# The fixture with its DETECTOR-CPU region replaced by the template's DETECTOR-OV region (v_ov_config).
ov_variant() {
  awk -v tpl="$TEMPLATE" '
    BEGIN { while ((getline l < tpl) > 0) { if (l ~ /^# DETECTOR-OV-BEGIN/) on = 1; if (on) ov = ov l "\n"; if (l ~ /^# DETECTOR-OV-END/) on = 0 }
            close(tpl); if (ov == "") exit 3 }
    /^# DETECTOR-CPU-BEGIN/ { printf "%s", ov; skip = 1; next }
    skip && /^# DETECTOR-CPU-END/ { skip = 0; next }
    !skip { print }' "$FIX"
}
OV_OK=1
render "$FIX" "$OUT/m7c-config.yml" || { echo "battery.sh: cannot render $FIX" >&2; exit 2; }
if ov_variant > "$OUT/m7c-config-ov.yml.in" && render "$OUT/m7c-config-ov.yml.in" "$OUT/m7c-config-ov.yml" \
   && grep -Eq '^[[:space:]]+type:[[:space:]]*openvino' "$OUT/m7c-config-ov.yml" \
   && ! grep -Eq '^[[:space:]]+type:[[:space:]]*cpu' "$OUT/m7c-config-ov.yml"; then :; else OV_OK=0; fi
put_config() { g "install -m 0600 $GOUT/$1 $CFG"; }
guest_t0() { g 'date -Is' | tail -n 1; }

# --- cleanup: the V9 shm mutation and the V11 quota are ALWAYS undone ---------------------------------
SHM_ARMED=0; QUOTA_ARMED=0; CLEANED=0
cleanup() {
  [ "$CLEANED" = 1 ] && return 0; CLEANED=1
  local st
  [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
  # Bounded calls (gw): a dead guest must not hold each cleanup call for the default 3600 s qga timeout.
  st=$(gw "rm -f $SMF; if test -e $SMF; then echo shm-max-frames=present; else echo shm-max-frames=absent; fi; \
snap remove-quota $QG >/dev/null 2>&1; if snap quota $QG >/dev/null 2>&1; then echo quota=present; else echo quota=absent; fi" 2>&1)
  echo "battery.sh: cleanup: $(printf '%s' "$st" | one_line)" >&2
  if [ "$SHM_ARMED" = 1 ]; then
    gw 'snap restart frigate.frigate' >/dev/null 2>&1 || true
    grep -q '^shm-max-frames=absent$' <<<"$st" || fail "V9 cleanup: $SMF removal not confirmed ($(printf '%s' "$st" | one_line))"
  fi
  if [ "$QUOTA_ARMED" = 1 ]; then
    grep -q '^quota=absent$' <<<"$st" || fail "V11 cleanup: quota group $QG removal not confirmed ($(printf '%s' "$st" | one_line))"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Pre-run cleanup: a previous run killed mid-V9 or mid-V11 can leave shm-max-frames or the quota group behind.
pre_run_cleanup() {
  local st
  st=$(gw "if test -e $SMF; then echo shm-max-frames=leftover; rm -f $SMF; fi; \
if snap quota $QG >/dev/null 2>&1; then echo quota=leftover; snap remove-quota $QG >/dev/null 2>&1; \
if snap quota $QG >/dev/null 2>&1; then echo quota=still-present; fi; fi; echo pre-run=done" 2>&1)
  printf '%s\n' "$st" > "$OUT/pre-run-cleanup.txt"
  grep -q '^shm-max-frames=leftover$' <<<"$st" && info "V9 pre-run: removed a leftover $SMF from an earlier run"
  grep -q '^quota=leftover$' <<<"$st" && info "V11 pre-run: removed a leftover quota group $QG from an earlier run"
  grep -q '^quota=still-present$' <<<"$st" && info "V11 pre-run: quota group $QG is STILL present after remove-quota"
  grep -q '^pre-run=done$' <<<"$st" || echo "battery.sh: pre-run cleanup not confirmed: $(printf '%s' "$st" | one_line)" >&2
  return 0
}

# I1: stale frame segments. Frigate may not unlink its shm frames on stop (F10: they survive a purge), and the
# template's testclip camera (1280x720) runs before the fixture. Before each counted (re)start: stop frigate,
# record + count + delete only the *_frame* segments, start it, and say how many were stale.
shm_reset() {   # shm_reset POINT
  local n
  g 'snap stop frigate.frigate' > "$OUT/v9-reset-$1.txt" 2>&1
  g "ls -l $SHMDIR" > "$OUT/v9-shm-before-$1.txt" 2>&1
  n=$(g "ls $SHMDIR 2>/dev/null | grep -c '_frame'" 2>/dev/null | tail -n 1)
  g "rm -f $SHMDIR/*_frame*" >> "$OUT/v9-reset-$1.txt" 2>&1
  g 'snap start frigate.frigate' >> "$OUT/v9-reset-$1.txt" 2>&1
  info "V9 stale frame segments before $1: ${n:-unknown}"
}

# ======================================================================================================
# 1. v5_install
SVC=""; VER=""
services_up() {
  local s st
  SVC=$(g 'snap services frigate' 2>/dev/null) || return 1
  for s in go2rtc frigate nginx certsync; do
    st=$(awk -v n="frigate.$s" '$1 == n { print $3 }' <<<"$SVC"); [ "$st" = active ] || return 1
  done
  awk '$1 == "frigate.logrotate" && $2 == "enabled" && $0 ~ /timer/ { ok = 1 } END { exit !ok }' <<<"$SVC" || return 1
  VER=$(g "curl -sf $AUTH_H http://localhost:5001/version" 2>/dev/null) && [ -n "$VER" ]
}
plug_slot() { awk -v p="frigate:$1" '$2 == p { print $3; exit }' "$2"; }
v5_install() {
  local p auto="" notcon="" s
  if ! g "snap install frigate --channel=$CH" > "$OUT/v5-install.txt" 2>&1; then
    fail "V5 install: snap install frigate --channel=$CH failed ($(one_line < "$OUT/v5-install.txt"))"; return 1
  fi
  g 'snap connections frigate' > "$OUT/connections-at-install.txt" 2>&1
  for p in raw-usb hardware-observe mount-observe shm-private; do
    s=$(plug_slot "$p" "$OUT/connections-at-install.txt"); [ -n "$s" ] && [ "$s" != - ] && auto="$auto $p"
  done
  info "V5 auto-connected at install (F11):${auto:- none} (of raw-usb hardware-observe mount-observe shm-private)"
  g 'for p in raw-usb hardware-observe mount-observe shm-private; do snap connect frigate:$p; done; snap restart frigate' \
    > "$OUT/v5-connect.txt" 2>&1
  g 'snap connections frigate' > "$OUT/connections-after-connect.txt" 2>&1
  for p in raw-usb hardware-observe mount-observe shm-private; do
    s=$(plug_slot "$p" "$OUT/connections-after-connect.txt"); { [ -n "$s" ] && [ "$s" != - ]; } || notcon="$notcon $p"
  done
  if poll "$(scaled 600)" 10 services_up; then
    printf '%s\n' "$SVC" > "$OUT/v5-services.txt"
    if [ -z "$notcon" ]; then
      pass "V5 install: 4 plugs connected; go2rtc/frigate/nginx/certsync active, logrotate enabled+timer; /version=$VER"
    else
      fail "V5 install: services up and /version=$VER, but not connected:$notcon"
    fi
  else
    printf '%s\n' "$SVC" > "$OUT/v5-services.txt"
    fail "V5 install: not all up within $(scaled 600)s [services: $(printf '%s' "$SVC" | one_line)] [/version: ${VER:-no answer}]${notcon:+ [not connected:$notcon]}"
  fi
  return 0
}

# 2. v5_layout (D7)
v5_layout() {
  local got want
  got=$(g "snap run --shell frigate.frigate -c 'ls -A /etc/OpenCL/vendors /usr/lib/x86_64-linux-gnu/intel-opencl'" 2>&1)
  printf '%s\n' "$got" > "$OUT/v5-layout.txt"
  want=$(printf '%s\n' '/etc/OpenCL/vendors:' '.keep' '' '/usr/lib/x86_64-linux-gnu/intel-opencl:' '.keep')
  if [ "$got" = "$want" ]; then pass "V5 layout: /etc/OpenCL/vendors and intel-opencl each list exactly .keep (D7)"
  else fail "V5 layout: want each dir to list exactly .keep, got: $(printf '%s' "$got" | one_line)"; fi
}

# 3. v6_runtime
v6_runtime() {
  local imp bad n line why=""
  # Fresh results only: delete what this probe writes (incl. edgetpu-dlopen.json, read by V18) before running it.
  g "rm -f $R/imports.json $R/edgetpu-dlopen.json" > "$OUT/v6-clear.txt" 2>&1 || why="$why could not clear stale probe results;"
  g 'snap run frigate.imports-probe' > "$OUT/v6-imports-probe.txt" 2>&1 || why="$why imports-probe exited non-zero;"
  imp=$(g "R=$R; jq -c .imports \"\$R/imports.json\"" 2>/dev/null)
  printf '%s\n' "$imp" > "$OUT/v6-imports.json"
  if [ -z "$imp" ]; then why="$why no fresh imports.json;"
  elif jq -e 'type == "object" and length > 0 and has("sqlite_vec") and all(.[]; .ok == true)' <<<"$imp" >/dev/null 2>&1; then :
  else
    bad=$(jq -r 'to_entries[] | select(.value.ok != true) | .key' <<<"$imp" 2>/dev/null | one_line)
    why="$why imports not all ok (${bad:-invalid imports.json or no sqlite_vec});"
  fi
  n=$(g '/snap/frigate/current/usr/lib/ffmpeg/8.0/bin/ffmpeg -hide_banner -decoders | grep -cw hevc' 2>/dev/null | tail -n 1)
  { is_int "$n" && [ "$n" -ge 1 ]; } || why="$why 8.0 ffmpeg hevc decoders=${n:-none};"
  line=$(g 'snap run frigate.ffprobe -version | head -1' 2>/dev/null)
  case "$line" in "ffprobe version n8"*) ;; *) why="$why ffprobe line '${line}';" ;; esac
  if [ -z "$why" ]; then pass "V6 runtime: $(jq -r 'length' <<<"$imp") imports ok (sqlite_vec incl.); hevc decoders=$n; $line"
  else fail "V6 runtime:$why"; fi
}

# 4. v18_edgetpu
v18_edgetpu() {
  local dl ok path err why="" cj
  # Depends on V6: edgetpu-dlopen.json is written by frigate.imports-probe (svc.py), which V6 ran on freshly
  # cleared results; coral.json is this probe's own. probe_coral.py exits 0 even when the delegate fails to
  # load (no stick: it writes the error and sys.exit(0)), so a non-zero rc is a real failure here.
  g "rm -f $R/coral.json" > "$OUT/v18-clear.txt" 2>&1 || why="$why could not clear a stale coral.json;"
  g 'snap run frigate.coral-probe' > "$OUT/v18-coral-probe.txt" 2>&1 || why="$why coral-probe exited non-zero;"
  cj=$(g "cat $R/coral.json" 2>/dev/null); printf '%s\n' "$cj" > "$OUT/v18-coral.json"
  [ -n "$cj" ] || why="$why no fresh coral.json;"
  dl=$(g "R=$R; jq -r '.dlopen.ok, .lib_path' \"\$R/edgetpu-dlopen.json\"" 2>/dev/null)
  ok=$(sed -n 1p <<<"$dl"); path=$(sed -n 2p <<<"$dl")
  err=$(g "R=$R; jq -r '.load_delegate.error // \"\"' \"\$R/coral.json\"" 2>/dev/null)
  printf 'dlopen.ok=%s\nlib_path=%s\nload_delegate.error=%s\n' "$ok" "$path" "$err" > "$OUT/v18.txt"
  [ "$ok" = true ] || why="$why dlopen.ok=${ok:-missing};"
  case "$path" in *aarch64-linux-gnu*) ;; *) why="$why lib_path '${path}' is not aarch64-linux-gnu;" ;; esac
  if [ -z "$err" ]; then why="$why load_delegate error empty (a stick present, or the probe did not run);"
  elif is_lib_missing_error "$err"; then why="$why library missing: $err;"; fi
  if [ -z "$why" ]; then pass "V18 edgetpu: dlopen ok from $path; delegate error names no device, not a missing lib: $err"
  else fail "V18 edgetpu:$why"; fi
}

# 5. v7_h265
v7_h265() {
  local codec t0 stats c fpsok pid cmd n why=""
  g "mkdir -p $SC/m7c && ffmpeg -y -f lavfi -i testsrc2=size=640x360:rate=15 -t 30 -c:v libx265 -pix_fmt yuv420p -tag:v hvc1 $CLIP < /dev/null" \
    > "$OUT/v7-clip-gen.txt" 2>&1 || why="$why clip generation failed;"
  codec=$(g "snap run frigate.ffprobe -v error -show_entries stream=codec_name -of csv=p=0 $CLIP" 2>/dev/null)
  [ "$codec" = hevc ] || why="$why clip codec '${codec}' (want hevc);"
  put_config m7c-config.yml > "$OUT/v7-config.txt" 2>&1 || why="$why fixture config install failed;"
  t0=$(guest_t0); shm_reset v7
  wait_s 300
  stats=$(g "curl -sf $AUTH_H http://localhost:5001/stats" 2>/dev/null)
  jq 'del(.cpu_usages)' <<<"$stats" > "$OUT/v7-stats.json" 2>/dev/null || printf '%s\n' "$stats" > "$OUT/v7-stats.json"
  fpsok=$(jq -r '[.cameras.m7c_a.camera_fps, .cameras.m7c_b.camera_fps] | map(tostring) | join(",")' <<<"$stats" 2>/dev/null)
  jq -e '(.cameras.m7c_a.camera_fps > 0) and (.cameras.m7c_b.camera_fps > 0)' <<<"$stats" >/dev/null 2>&1 \
    || why="$why camera_fps a,b=${fpsok:-no stats};"
  for c in m7c_a m7c_b; do
    pid=$(jq -r ".cameras.$c.ffmpeg_pid // empty" <<<"$stats" 2>/dev/null)
    if is_int "$pid" && [ "$pid" -gt 0 ]; then
      cmd=$(g "tr '\\0' ' ' < /proc/$pid/cmdline" 2>/dev/null); printf '%s\n' "$cmd" > "$OUT/v7-cmdline-$c.txt"
      if [ -z "$cmd" ]; then why="$why $c detect ffmpeg cmdline unreadable (pid $pid);"
      else case " $cmd " in *" -hwaccel"*) why="$why $c detect ffmpeg has -hwaccel;" ;; esac; fi
    else why="$why $c ffmpeg_pid '${pid}';"; fi
  done
  g "journalctl -u snap.frigate.frigate --since \"$t0\"" > "$OUT/v7-journal.txt" 2>&1
  n=$(g "journalctl -u snap.frigate.frigate --since \"$t0\" | grep -ciE 'm7c_[ab].*(error|exited)'" 2>/dev/null | tail -n 1)
  [ "$n" = 0 ] || why="$why journal m7c error/exited lines=${n:-unknown};"
  if [ -z "$why" ]; then pass "V7 h265: clip is hevc; camera_fps a,b=$fpsok; no -hwaccel in the detect cmdlines; 0 m7c error/exited journal lines"
  else fail "V7 h265:$why"; fi
}

# 6. v9_shm (D13a)
CNT_A=""; CNT_B=""
shm_counts() {   # shm_counts POINT (evidence: battery/v9-shm-POINT.txt)
  g "ls -l $SHMDIR" > "$OUT/v9-shm-$1.txt" 2>&1
  CNT_A=$(g "ls $SHMDIR | grep -c '^m7c_a_frame'" 2>/dev/null | tail -n 1)
  CNT_B=$(g "ls $SHMDIR | grep -c '^m7c_b_frame'" 2>/dev/null | tail -n 1)
}
v9_shm() {
  local fb tot sizes badsz du why="" ma mb
  fb=$(expected_frame_bytes "$W" "$H"); tot=$(expected_frames_total "$W" "$H" "$FRAMES" "$CAMS")
  shm_counts bound
  sizes=$(g "stat -c '%n %s' $SHMDIR/m7c_*_frame*" 2>/dev/null); printf '%s\n' "$sizes" > "$OUT/v9-sizes.txt"
  badsz=$(awk -v f="$fb" 'NF >= 2 && $NF != f { n++ } END { print n + 0 }' <<<"$sizes")
  du=$(g "du -sb $SHMDIR" 2>/dev/null | awk 'NR == 1 { print $1 }')
  printf 'm7c_a=%s m7c_b=%s bad_sizes=%s du=%s expected_total=%s\n' "$CNT_A" "$CNT_B" "$badsz" "$du" "$tot" > "$OUT/v9.txt"
  [ "$CNT_A" = "$FRAMES" ] && [ "$CNT_B" = "$FRAMES" ] || why="$why frame files a,b=${CNT_A:-?},${CNT_B:-?} (want $FRAMES);"
  [ "$badsz" = 0 ] || why="$why $badsz frame files not $fb B;"
  within_mib "$du" "$tot" 10 || why="$why du -sb=${du:-?} not within [$tot, $tot+10MiB];"
  if [ -z "$why" ]; then pass "V9 shm: $FRAMES frames/camera of $fb B; du -sb=$du within +10MiB of $tot"
  else fail "V9 shm:$why"; fi
  # Mutation: SHM_MAX_FRAMES=10 via the harness hook, then restore.
  why=""
  SHM_ARMED=1
  g "echo 10 > $SMF" > "$OUT/v9-mutation.txt" 2>&1 || why="$why arming failed;"
  shm_reset mutation
  wait_s 300; shm_counts mutation; ma="$CNT_A,$CNT_B"
  [ "$CNT_A" = 10 ] && [ "$CNT_B" = 10 ] || why="$why with shm-max-frames=10 frame files a,b=$ma (want 10);"
  if g "rm -f $SMF" >> "$OUT/v9-mutation.txt" 2>&1; then SHM_ARMED=0; else why="$why restore failed;"; fi
  shm_reset restore
  wait_s 300; shm_counts restore; mb="$CNT_A,$CNT_B"
  [ "$CNT_A" = "$FRAMES" ] && [ "$CNT_B" = "$FRAMES" ] || why="$why after restore a,b=$mb (want $FRAMES);"
  if [ -z "$why" ]; then pass "V9 mutation: shm-max-frames=10 -> 10 frame files/camera; removed -> $FRAMES again"
  else fail "V9 mutation:$why"; fi
}

# 7. v10_mem
PEAK=""
v10_mem() {
  local show cur anon shmem
  wait_s 1800
  show=$(g "systemctl show -p MemoryPeak -p MemoryCurrent $UNIT" 2>/dev/null)
  PEAK=$(sed -n 's/^MemoryPeak=//p' <<<"$show"); cur=$(sed -n 's/^MemoryCurrent=//p' <<<"$show")
  g "cat /sys/fs/cgroup/system.slice/$UNIT/memory.stat" > "$OUT/v10-memory.stat" 2>/dev/null
  anon=$(cgroup_stat "$OUT/v10-memory.stat" anon 2>/dev/null); shmem=$(cgroup_stat "$OUT/v10-memory.stat" shmem 2>/dev/null)
  printf 'MemoryPeak=%s\nMemoryCurrent=%s\nanon=%s\nshmem=%s\n' "$PEAK" "$cur" "$anon" "$shmem" > "$OUT/v10.txt"
  if is_int "$PEAK" && is_int "$cur" && is_int "$anon" && is_int "$shmem"; then
    info "V10 mem after $(scaled 1800)s: MemoryPeak=$PEAK MemoryCurrent=$cur anon=$anon shmem=$shmem (battery/v10.txt)"
  else
    fail "V10 mem: want four integers, got MemoryPeak='$PEAK' MemoryCurrent='$cur' anon='$anon' shmem='$shmem'"; PEAK=""
  fi
}

# 8. v11_quota (swap enabled in the VM, as on the hub)
nrestarts() { gw "systemctl show -p NRestarts --value $UNIT" 2>/dev/null | tail -n 1; }
swap_used() { awk '$1 == "Swap:" { print $3 }'; }
frigate_active() { [ "$(g "systemctl is-active $UNIT" 2>/dev/null | tail -n 1)" = active ]; }
v11_quota() {
  local q t0 sw0 nr0 nr nrmax="" sw swmax="" oom="" snapd agent agent_down=0 snapd_down=0 i=0 n end why="" removed=0
  if ! is_int "$PEAK"; then fail "V11 quota: skipped: no V10 MemoryPeak"; return; fi
  q=$(quota_mb "$PEAK")
  g 'free -b' > "$OUT/v11-free-baseline.txt" 2>&1; sw0=$(swap_used < "$OUT/v11-free-baseline.txt")
  nr0=$(nrestarts); t0=$(guest_t0)
  QUOTA_ARMED=1
  if ! g "snap set-quota $QG --memory=$q frigate" > "$OUT/v11-set-quota.txt" 2>&1; then
    fail "V11 quota: snap set-quota $QG --memory=$q frigate failed ($(one_line < "$OUT/v11-set-quota.txt"))"; return
  fi
  : > "$OUT/v11-watch.txt"
  n=$(( $(scaled 600) / 30 )); end=$(( $(date +%s) + $(scaled 600) ))
  while [ "$i" -le "$n" ] && [ "$(date +%s)" -lt "$end" ]; do
    if gw true >/dev/null 2>&1; then agent=up; else agent=down; agent_down=$((agent_down + 1)); fi
    snapd=$(gw 'systemctl is-active snapd' 2>/dev/null | tail -n 1); [ "$snapd" = active ] || snapd_down=$((snapd_down + 1))
    nr=$(nrestarts); sw=$(gw 'free -b' 2>/dev/null | swap_used)
    oom=$(gw "journalctl -k --since \"$t0\" | grep -c 'Memory cgroup out of memory'" 2>/dev/null | tail -n 1)
    is_int "$nr" && { [ -z "$nrmax" ] || [ "$nr" -gt "$nrmax" ]; } && nrmax=$nr
    is_int "$sw" && { [ -z "$swmax" ] || [ "$sw" -gt "$swmax" ]; } && swmax=$sw
    echo "$(date -Is) agent=$agent snapd=${snapd:-?} NRestarts=${nr:-?} swap_used=${sw:-?} oom=${oom:-?}" >> "$OUT/v11-watch.txt"
    i=$((i + 1)); isleep 30
  done
  if g "snap remove-quota $QG" > "$OUT/v11-remove-quota.txt" 2>&1; then QUOTA_ARMED=0; removed=1; fi
  [ "$agent_down" = 0 ] || why="$why guest agent down in $agent_down samples;"
  [ "$snapd_down" = 0 ] || why="$why snapd not active in $snapd_down samples;"
  [ "$removed" = 1 ] || why="$why remove-quota failed ($(one_line < "$OUT/v11-remove-quota.txt"));"
  poll "$(scaled 600)" 10 frigate_active || why="$why frigate not active within $(scaled 600)s after removal;"
  if [ -z "$why" ]; then pass "V11 quota: --memory=$q for $(scaled 600)s; agent and snapd up in all $i samples; frigate active after remove-quota"
  else fail "V11 quota (--memory=$q):$why"; fi
  if is_int "$sw0" && is_int "$swmax"; then info "V11 swap growth: $(( swmax - sw0 )) B (baseline $sw0, max $swmax)"
  else info "V11 swap growth: unknown (baseline '${sw0}', max '${swmax}')"; fi
  info "V11 OOM kills ('Memory cgroup out of memory'): ${oom:-unknown}; NRestarts before=${nr0:-?} max-during=${nrmax:-?} delta=$( is_int "$nr0" && is_int "$nrmax" && echo $(( nrmax - nr0 )) || echo '?')"
}

# 9. v_ov_config (Review Focus 3, D10)
v_ov_config() {
  local t0 vc st nr ovl
  if [ "$OV_OK" != 1 ]; then fail "V-OV config (RF3): could not build the DETECTOR-OV variant of the fixture"; return; fi
  put_config m7c-config-ov.yml > "$OUT/v-ov-config.txt" 2>&1
  t0=$(guest_t0); g 'snap restart frigate.frigate' >> "$OUT/v-ov-config.txt" 2>&1
  wait_s 120
  g "journalctl -u snap.frigate.frigate --since \"$t0\"" > "$OUT/v-ov-journal.txt" 2>&1
  if grep -qF -- "$D10_ERROR" "$OUT/v-ov-journal.txt"; then pass "V-OV config (RF3): the D10 ERROR line is in the journal"
  else fail "V-OV config (RF3): the D10 ERROR line is not in the journal since $t0 (battery/v-ov-journal.txt)"; fi
  vc=$(g 'snap run frigate.validate-config; echo rc=$?' 2>&1); printf '%s\n' "$vc" > "$OUT/v-ov-validate.txt"
  info "V-OV validate-config on the openvino config: $(grep -E '^rc=' <<<"$vc" | tail -n 1) (expected rc=0: validate does not catch it)"
  st=$(g "systemctl is-active $UNIT" 2>/dev/null | tail -n 1); nr=$(nrestarts)
  grep -iE 'openvino|detector' "$OUT/v-ov-journal.txt" | grep -vF -- "$D10_ERROR" > "$OUT/v-ov-detector.txt"
  ovl=$(head -n 1 "$OUT/v-ov-detector.txt" | cut -c1-200)
  info "V-OV detector behaviour: unit=${st:-?} NRestarts=${nr:-?}; $(wc -l < "$OUT/v-ov-detector.txt") openvino/detector lines (battery/v-ov-detector.txt), first: ${ovl:-none}"
}

# 10. restore
v_restore() {
  put_config m7c-config.yml > "$OUT/v-restore.txt" 2>&1
  g 'snap restart frigate.frigate' >> "$OUT/v-restore.txt" 2>&1
  wait_s 120
  if frigate_active; then pass "V-restore: fixture config back; frigate.frigate active"
  else fail "V-restore: frigate.frigate not active $(scaled 120)s after restoring the fixture config"; fi
}

# 11. v17_lifecycle (H7 rehearsal under --hold, H9 purge, F10 shm residue)
# The frigate row of a `snap list` table (after its Name/Version/Rev header), not e.g. "frigate reverted to ...".
list_row() { awk '$1 == "Name" && $3 == "Rev" { h = 1; next } h && $1 == "frigate" { print; exit }'; }
list_rev() { list_row | awk '{ print $3 }'; }
rc_of() { sed -n 's/^rc=//p' | tail -n 1; }
v17_lifecycle() {
  local out hold_rc ref_rc rev0 rev1 revx revr notes why="" chrev
  out=$(g 'snap refresh --hold frigate; echo rc=$?; snap list frigate' 2>&1); printf '%s\n' "$out" > "$OUT/v17-hold.txt"
  hold_rc=$(rc_of <<<"$out"); rev0=$(list_rev <<<"$out")
  notes=$(list_row <<<"$out" | awk '{ print $NF }')
  info "V17 snap list Notes after --hold: '${notes}' (whether it says held is [NOT VERIFIED])"
  [ "$hold_rc" = 0 ] || why="$why hold rc=${hold_rc:-?};"
  chrev=$(g 'snap info frigate' 2>/dev/null | awk -v c="$CH:" '$1 == c { for (i = 2; i <= NF; i++) if ($i ~ /^\([0-9]+\)$/) { gsub(/[()]/, "", $i); print $i; exit } }')
  out=$(g "snap refresh frigate --channel=$CH; echo rc=\$?" 2>&1); printf '%s\n' "$out" > "$OUT/v17-refresh.txt"
  ref_rc=$(rc_of <<<"$out"); rev1=$(g 'snap list frigate' 2>/dev/null | list_rev)
  [ "$ref_rc" = 0 ] || why="$why explicit refresh rc=${ref_rc:-?};"
  if [ -n "$rev0" ] && [ "$rev0" != "$rev1" ]; then info "V17 refresh under hold moved r$rev0 -> r$rev1"
  else info "V17 refresh-under-hold not exercised (single revision) [installed r${rev0:-?}, $CH lists r${chrev:-?}]"; fi
  g "rm -rf /root/dl && mkdir -p /root/dl && snap download frigate --channel=$CH --target-directory=/root/dl" > "$OUT/v17-download.txt" 2>&1 \
    || why="$why snap download failed;"
  g 'snap install --dangerous /root/dl/frigate_*.snap' > "$OUT/v17-dangerous.txt" 2>&1 || why="$why install --dangerous failed;"
  revx=$(g 'snap list frigate' 2>/dev/null | list_rev)
  out=$(g 'snap revert frigate; snap list frigate' 2>&1); printf '%s\n' "$out" > "$OUT/v17-revert.txt"
  revr=$(list_rev <<<"$out")
  case "$revr" in ''|x*) why="$why after revert rev '${revr}' (dangerous was '${revx}');" ;;
    *) [ "$revr" = "$rev1" ] || why="$why after revert r$revr, want the Store r${rev1:-?};" ;; esac
  out=$(g "snap remove frigate; echo rc=\$?; ls -d $SHMDIR" 2>&1); printf '%s\n' "$out" > "$OUT/v17-remove.txt"
  if [ -z "$(rc_of <<<"$out")" ]; then info "V17 plain snap remove: unknown (the guest call failed)"; why="$why plain remove call failed;"
  elif grep -qx "$SHMDIR" <<<"$out"; then info "V17 plain snap remove LEFT $SHMDIR (deleted before the purge cycle)"; g "rm -rf $SHMDIR" >/dev/null 2>&1
  else info "V17 plain snap remove did not leave $SHMDIR"; fi
  out=$(g "snap install frigate --channel=$CH && snap remove --purge frigate; echo rc=\$?; ls -d $SHMDIR" 2>&1)
  printf '%s\n' "$out" > "$OUT/v17-purge.txt"
  [ "$(rc_of <<<"$out")" = 0 ] || why="$why install+purge rc=$(rc_of <<<"$out");"
  if grep -qx "$SHMDIR" <<<"$out"; then
    out=$(g "rm -rf $SHMDIR; ls -d $SHMDIR 2>/dev/null; echo end" 2>&1)
    grep -qx "$SHMDIR" <<<"$out" && why="$why $SHMDIR still present after the battery's rm;"
  else why="$why $SHMDIR absent after remove --purge (F10 expected it to survive);"; fi
  if [ -z "$why" ]; then pass "V17 lifecycle: hold rc=0; explicit refresh rc=0; revert -> Store r$revr (dangerous was $revx); $SHMDIR survived --purge (F10) and was deleted"
  else fail "V17 lifecycle:$why"; fi
}

# ======================================================================================================
mkdir -p "$OUT" && g "mkdir -p $GOUT" >/dev/null 2>&1
pre_run_cleanup
if v5_install; then
  v5_layout; v6_runtime; v18_edgetpu; v7_h265; v9_shm; v10_mem; v11_quota; v_ov_config; v_restore; v17_lifecycle
else
  for c in "V5 layout" "V6 runtime" "V18 edgetpu" "V7 h265" "V9 shm" "V9 mutation" "V10 mem" "V11 quota" \
           "V-OV config (RF3)" "V-restore" "V17 lifecycle"; do
    fail "$c: skipped: install failed"
  done
fi
cleanup; trap - EXIT
echo "battery.sh: $(grep -c '^PASS' "$RESULTS") PASS, $FAILS FAIL, $(grep -c '^INFO' "$RESULTS") INFO (evidence: $OUT)" >&2
[ "$FAILS" = 0 ]
