#!/usr/bin/env bash
# M7c hub probe (NOT the battery): run once after §8 H3 on the installed snap, with frigate STOPPED.
# Runs on the laptop; every hub step goes through tests/hub/ssh-exec.sh (the operator's existing ssh master only).
# Checks: V5 version (+ the installed .snap's sha256 with --sha), V5 plugs, V5 layout (D7), V6 runtime (the
# tensorflow import under nice -n 19), V18 on the hub (Coral present: the delegate must load and infer), and
# V-OV (stopped): the D10 guard functions of the shipped lib-wait.sh run in the snap's own shell on the real arch,
# with `snapctl get detector` stubbed to "ov" (no snap set, no config change, no configure hook). This is a
# stopped-state guard check only: the start-time behaviour of an openvino config on arm64 is NOT PROVEN by it.
# It starts no daemon, changes no config, and writes only the probes' own $SNAP_COMMON/spike-results/*.json.
# The hub has no jq or curl: JSON is read back with cat and parsed here.
# Precondition: frigate.frigate and frigate.go2rtc stopped (nginx/certsync may run: the configure hook starts them).
# Usage: M7C_HUB_SOCK=<socket> M7C_HUB_TARGET=<target> tests/hub/probe.sh [--sha <sha256>] [--out <dir>]
# Prints PASS/FAIL/INFO lines in the battery's style; evidence in <dir> (default
# ~/.cache/frigate-m7c-evidence/hub/probe-<time>). Every saved or printed line drops password lines and URL
# credentials. Exit: 0 all PASS, 1 any FAIL, 2 usage, 3 the ssh master is gone (LOUD, nothing further runs).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
EXEC="$HERE/ssh-exec.sh"
usage() { echo "usage: probe.sh [--sha <sha256 of the proven .snap, 64 lowercase hex>] [--out <evidence dir>]" >&2; exit 2; }
WANT_SHA=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sha) [ $# -ge 2 ] || usage; WANT_SHA=$2; [[ "$WANT_SHA" =~ ^[0-9a-f]{64}$ ]] || usage; shift 2 ;;
    --out) [ $# -ge 2 ] || usage; OUT=$2; shift 2 ;;
    *) usage ;;
  esac
done
command -v jq >/dev/null || { echo "probe: jq is required on the laptop" >&2; exit 2; }
OUT="${OUT:-$HOME/.cache/frigate-m7c-evidence/hub/probe-$(date +%Y%m%dT%H%M%S)}"
mkdir -p "$OUT" || exit 2; RESULTS="$OUT/results.txt"; : > "$RESULTS"
R=/var/snap/frigate/common/spike-results
FAILS=0
# scrub: drop any password line; mask URL credentials (the harness scrub_evidence class).
scrub() { grep -viE 'passw(or)?d' | sed -E 's#(rtsps?|rtmp|https?)://[^@/[:space:]]+@#\1://<redacted>@#g'; }
say()  { printf '%s\n' "$*" | scrub | tee -a "$RESULTS"; }
pass() { say "PASS: $*"; }
fail() { say "FAIL: $*"; FAILS=$((FAILS + 1)); }
info() { say "INFO: $*"; }
one_line() { tr '\n' ' ' | sed 's/  */ /g; s/ $//' | cut -c1-240; }
# g NAME CMD: run CMD on the hub; scrubbed stdout+stderr to $OUT/NAME.txt; returns the remote rc.
# Never called in a subshell, so a lost master (ssh-exec exit 3) ends the whole probe here.
g() {
  local rc
  "$EXEC" exec "$2" > "$OUT/$1.raw" 2>&1 </dev/null; rc=$?   # never forward the caller's stdin
  scrub < "$OUT/$1.raw" > "$OUT/$1.txt"; rm -f "$OUT/$1.raw"
  if [ "$rc" = 3 ]; then
    cat "$OUT/$1.txt" >&2
    echo "probe: MASTER GONE during '$1': stopping here, no further hub command, no verdict (exit 3)" >&2; exit 3
  fi
  return "$rc"
}
F() { cat "$OUT/$1.txt"; }

"$EXEC" check > "$OUT/master.txt" 2>&1 || { cat "$OUT/master.txt" >&2; echo "probe: MASTER GONE: nothing run (exit 3)" >&2; exit 3; }

# --- precondition: installed and every frigate service stopped -----------------------------------
if ! g snap-list 'snap list frigate'; then fail "precondition: frigate is not installed ($(F snap-list | one_line))"; exit 1; fi
ROW=$(awk '$1 == "Name" && $3 == "Rev" { h = 1; next } h && $1 == "frigate" { print; exit }' "$OUT/snap-list.txt")
VER=$(awk '{ print $2 }' <<<"$ROW"); REV=$(awk '{ print $3 }' <<<"$ROW")
g services 'snap services frigate' || true
# frigate.frigate and frigate.go2rtc must be stopped. nginx and certsync may be active: the configure hook starts
# them on every `snap set` (H4), and they serve nothing without the API; reported as INFO.
ACTIVE=$(awk '($1 == "frigate.frigate" || $1 == "frigate.go2rtc") && $3 == "active" { printf "%s ", $1 }' "$OUT/services.txt" | sed 's/ $//')
if [ -n "$ACTIVE" ]; then fail "precondition: frigate.frigate and frigate.go2rtc must be stopped; active: $ACTIVE (nothing probed)"; exit 1; fi
OTHER=$(awk '$1 ~ /^frigate\./ && $1 != "frigate.frigate" && $1 != "frigate.go2rtc" && $3 == "active" { printf "%s ", $1 }' "$OUT/services.txt" | sed 's/ $//')
[ -n "$OTHER" ] && info "precondition: also active (allowed, the configure hook starts them): $OTHER"
if [ -z "$VER" ] || [ -z "$REV" ]; then fail "precondition: cannot read the frigate row of snap list ($(F snap-list | one_line))"; exit 1; fi

# --- V5 version, bytes, plugs ---------------------------------------------------------------------
pass "V5 version: frigate $VER r$REV installed; frigate.frigate and frigate.go2rtc stopped"
if [ -z "$WANT_SHA" ]; then info "V5 bytes: not checked (no --sha given)"
else
  case "$REV" in *[!A-Za-z0-9]*) fail "V5 bytes: odd revision '$REV'" ;; *)
    SF="/var/lib/snapd/snaps/frigate_$REV.snap"
    g snap-sha256 "sha256sum $SF" || true
    got=$(awk -v f="$SF" '$2 == f { print $1 }' "$OUT/snap-sha256.txt" | tail -n 1)
    if [ "$got" = "$WANT_SHA" ]; then pass "V5 bytes: $SF has sha256 $WANT_SHA"
    else fail "V5 bytes: $SF has sha256 ${got:-unknown}, want $WANT_SHA"; fi ;;
  esac
fi
g connections 'snap connections frigate' || true
notcon=""
for p in raw-usb hardware-observe mount-observe shm-private; do
  s=$(awk -v p="frigate:$p" '$2 == p { print $3; exit }' "$OUT/connections.txt")
  { [ -n "$s" ] && [ "$s" != - ]; } || notcon="$notcon $p"
done
if [ -z "$notcon" ]; then pass "V5 plugs: raw-usb hardware-observe mount-observe shm-private connected"
else fail "V5 plugs: not connected:$notcon"; fi

# --- V5 layout (D7) -------------------------------------------------------------------------------
g layout "snap run --shell frigate.frigate -c 'ls -A /etc/OpenCL/vendors /usr/lib/x86_64-linux-gnu/intel-opencl'" || true
want=$(printf '%s\n' '/etc/OpenCL/vendors:' '.keep' '' '/usr/lib/x86_64-linux-gnu/intel-opencl:' '.keep')
if [ "$(F layout)" = "$want" ]; then pass "V5 layout: /etc/OpenCL/vendors and intel-opencl each list exactly .keep (D7)"
else fail "V5 layout: want each dir to list exactly .keep, got: $(F layout | one_line)"; fi

# --- V6 runtime -----------------------------------------------------------------------------------
why=""
g imports-probe "rm -f $R/imports.json $R/edgetpu-dlopen.json && nice -n 19 snap run frigate.imports-probe" \
  || why="$why imports-probe exited non-zero;"
g imports-json "cat $R/imports.json" || why="$why no fresh imports.json;"
imp=$(jq -c '.imports' "$OUT/imports-json.txt" 2>/dev/null)
if [ -z "$imp" ] || [ "$imp" = null ]; then why="$why imports.json unreadable;"
elif ! jq -e 'type == "object" and length > 0 and has("sqlite_vec") and all(.[]; .ok == true)' <<<"$imp" >/dev/null 2>&1; then
  why="$why imports not all ok ($(jq -r 'to_entries[] | select(.value.ok != true) | .key' <<<"$imp" 2>/dev/null | one_line));"
fi
g hevc '/snap/frigate/current/usr/lib/ffmpeg/8.0/bin/ffmpeg -hide_banner -decoders | grep -cw hevc' || true
n=$(tail -n 1 "$OUT/hevc.txt"); case "$n" in ''|*[!0-9]*|0) why="$why 8.0 ffmpeg hevc decoders=${n:-none};" ;; esac
g ffprobe 'snap run frigate.ffprobe -version | sed -n 1p' || true
line=$(head -n 1 "$OUT/ffprobe.txt"); case "$line" in "ffprobe version n8"*) ;; *) why="$why ffprobe line '${line}';" ;; esac
if [ -z "$why" ]; then pass "V6 runtime: $(jq -r 'length' <<<"$imp") imports ok (sqlite_vec incl.); hevc decoders=$n; $line"
else fail "V6 runtime:$why"; fi

# --- V18 on the hub: the Coral is present, so the delegate must load and run one inference --------
# shellcheck disable=SC2016  # expands on the hub, not here
USB='for d in /sys/bus/usb/devices/*; do [ -r "$d/idVendor" ] && [ -r "$d/idProduct" ] && printf "%s:%s\n" "$(cat "$d/idVendor")" "$(cat "$d/idProduct")"; done | grep -E "^(1a6e:089a|18d1:9302)$"; true'
why=""
g usb-before "$USB" || true; before=$(one_line < "$OUT/usb-before.txt")
[ -n "$before" ] || why="$why no Coral USB id (1a6e:089a or 18d1:9302) before the probe;"
if [ -z "$why" ]; then
  g coral-probe "rm -f $R/coral.json && snap run frigate.coral-probe" || why="$why coral-probe exited non-zero;"
  g coral-json "cat $R/coral.json" || why="$why no fresh coral.json;"
  g dlopen-json "cat $R/edgetpu-dlopen.json" || why="$why no edgetpu-dlopen.json (written by V6's imports-probe);"
  g usb-after "$USB" || true; after=$(one_line < "$OUT/usb-after.txt")
  info "V18 Coral USB id before: ${before}; after: ${after:-none} (1a6e:089a -> 18d1:9302 after the first load is normal)"
  dl_ok=$(jq -r '.dlopen.ok' "$OUT/dlopen-json.txt" 2>/dev/null); path=$(jq -r '.lib_path // ""' "$OUT/dlopen-json.txt" 2>/dev/null)
  ld_ok=$(jq -r '.load_delegate.ok' "$OUT/coral-json.txt" 2>/dev/null); ld_err=$(jq -r '.load_delegate.error // ""' "$OUT/coral-json.txt" 2>/dev/null | one_line)
  in_ok=$(jq -r '.inference.ok' "$OUT/coral-json.txt" 2>/dev/null); in_err=$(jq -r '.inference.error // ""' "$OUT/coral-json.txt" 2>/dev/null | one_line)
  [ "$dl_ok" = true ] || why="$why dlopen.ok=${dl_ok:-missing};"
  case "$path" in *aarch64-linux-gnu*) ;; *) why="$why lib_path '${path}' is not aarch64-linux-gnu;" ;; esac
  if [ "$ld_ok" != true ]; then why="$why load_delegate failed: ${ld_err:-no error recorded};"
  elif [ "$in_ok" != true ]; then why="$why inference failed: ${in_err:-no error recorded};"; fi
fi
if [ -z "$why" ]; then pass "V18 edgetpu (hub, Coral present): dlopen ok from $path; load_delegate ok; inference ok"
else fail "V18 edgetpu (hub, Coral present):$why"; fi

# --- V-OV (stopped): D10 guard functions, read-only, in the snap's shell on the real arch ----------
# The inner script has no single quote, so it sits in one single-quoted -c argument on the hub.
D10_WARN='frigate-run: WARN detector=ov is not available on arm64 (no OpenVINO GPU plugin); rendering the cpu detector'
# shellcheck disable=SC2016  # expands in the snap's shell on the hub, not here
D10='snapctl() { [ "$1 $2" = "get detector" ] && echo ov; }; . "$SNAP/bin/lib-wait.sh"; echo "SNAP_ARCH=$SNAP_ARCH"; echo "cpu_block=$(detector_sed | grep -c "DETECTOR-CPU-BEGIN/d")"; if _arch_has_ov; then echo arch=has-ov; else echo arch=no-ov; fi; printf "detectors:\n  ov:\n    type: openvino\n" > /tmp/m7c-d10.yml; if config_uses_openvino /tmp/m7c-d10.yml; then echo ovcfg=uses-ov; else echo ovcfg=no; fi; rm -f /tmp/m7c-d10.yml'
why=""
g v-ov-stopped "snap run --shell frigate.validate-config -c '$D10' 2>&1" || why="$why snap run --shell exited non-zero ($(F v-ov-stopped | one_line));"
grep -qx 'SNAP_ARCH=arm64' "$OUT/v-ov-stopped.txt" || why="$why SNAP_ARCH is not arm64;"
grep -qxF -- "$D10_WARN" "$OUT/v-ov-stopped.txt" || why="$why no D10 render WARN line;"
grep -qx 'cpu_block=1' "$OUT/v-ov-stopped.txt" || why="$why detector=ov did not render the cpu block;"
grep -qx 'arch=no-ov' "$OUT/v-ov-stopped.txt" || why="$why _arch_has_ov is not false;"
grep -qx 'ovcfg=uses-ov' "$OUT/v-ov-stopped.txt" || why="$why config_uses_openvino did not recognise an openvino config;"
if [ -z "$why" ]; then pass "V-OV (stopped): on arm64 detector=ov renders the cpu detector with the D10 WARN; _arch_has_ov false; an openvino config is recognised (stopped-state guard check only; the start-time behaviour of an openvino config on arm64 is NOT PROVEN)"
else fail "V-OV (stopped):$why"; fi

echo "probe: $(grep -c '^PASS' "$RESULTS") PASS, $FAILS FAIL, $(grep -c '^INFO' "$RESULTS") INFO (evidence: $OUT)"
[ "$FAILS" = 0 ]
