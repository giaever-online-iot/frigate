#!/usr/bin/env bash
# tests/ezviz/probe-run.sh with SYNTHETIC inputs only (W-23 T12): a synthetic env dir (TEST-NET addresses, made-up ids,
# canary codes, as tests/hub/make-config.test.sh's mkenv) and a STUB probe.py that records its argv, its environment
# and the camera files it was given. The real probe is never started, no camera is contacted, the real M7C_ENV_DIR
# and the real key file are never read.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1; fail=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 [want $2 got $3]"; fail=1; fi; }
CA=QZCNRA; CB=QZCNRB; NC=QZNEVERREAD; IP1=192.0.2.11; IP2=192.0.2.12; ID1=TESTCAM-0001; ID2=TESTCAM-0002
CANARIES=("$CA" "$CB" "$NC" "$IP1" "$IP2" "$ID1" "$ID2" "192.0.2.")

# A copy of the tree the script needs, so the stub probe.py sits where the real one does.
TREE=$T/tree; mkdir -p "$TREE/tests/ezviz" "$TREE/tests/hub"
cp tests/ezviz/probe-run.sh "$TREE/tests/ezviz/"; cp tests/hub/lib-cameras.sh "$TREE/tests/hub/"
mkdir -p "$TREE/spike/ezviz"; cp -r spike/ezviz/ezviz_source "$TREE/spike/ezviz/"; rm -rf "$TREE/spike/ezviz/ezviz_source/__pycache__"
cat > "$TREE/tests/ezviz/probe.py" <<'PYEOF'
import os, stat, sys, time
out, n = os.environ["STUB_OUT"], sys.argv[3]
with open(out + "/log", "a") as f:
    f.write("start " + n + "\n")
open(out + "/pid." + n, "w").write(str(os.getpid()))
open(out + "/argv." + n, "w").write("\n".join(sys.argv[1:]) + "\n")
open(out + "/env." + n, "wb").write(open("/proc/self/environ", "rb").read())
camdir = sys.argv[2]
open(out + "/camdir." + n, "w").write(camdir + "\n")
with open(out + "/files." + n, "w") as f:
    f.write("dir %o\n" % stat.S_IMODE(os.stat(camdir).st_mode))
    for name in sorted(os.listdir(camdir)):
        f.write("file %s %o\n" % (name, stat.S_IMODE(os.stat(camdir + "/" + name).st_mode)))
        f.write(open(camdir + "/" + name).read())
time.sleep(float(os.environ.get("STUB_SLEEP", "0.5")))
with open(out + "/log", "a") as f:
    f.write("end " + n + "\n")
print("probe %s: end=stop login_ok=1" % n)
sys.exit(int(os.environ.get("STUB_RC", "0")))
PYEOF
PR=$TREE/tests/ezviz/probe-run.sh

mkenv() {  # synthetic env dir: pairs + env 0600, a CRLF key file
  local d=$1; mkdir -p "$d"
  printf '%s %s\r\n%s %s\r\n' "$ID1" "$IP1" "$ID2" "$IP2" > "$d/cameras.pairs"
  printf 'M7C_KEYFILE=%s\n' "$d/keys.yaml" > "$d/env"
  printf 'new:\r\n  common: %s\r\noriginal QR Code keys:\r\n  %s: %s\r\n  %s: %s\r\n' "$NC" "$ID1" "$CA" "$ID2" "$CB" > "$d/keys.yaml"
  chmod 600 "$d/cameras.pairs" "$d/env" "$d/keys.yaml"
}
run() {  # run NAME [env...] -- args
  local n=$1; shift; local -a e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  mkdir -p "$T/$n/out" "$T/$n/tmp"; [ -d "$T/$n/envd" ] || mkenv "$T/$n/envd"
  env TMPDIR="$T/$n/tmp" XDG_RUNTIME_DIR="$T/$n/tmp" PROBE_TEST=1 STUB_OUT="$T/$n/out" M7C_ENV_DIR="$T/$n/envd" PROBE_PYTHON=python3 PROBE_FFMPEG=/bin/true \
    PROBE_COUNT=100 "${e[@]}" timeout 60 bash "$PR" "$@" > "$T/$n.out" 2> "$T/$n.err"; echo $? > "$T/$n.rc"
}
rc() { cat "$T/$1.rc"; }
noleak() {  # noleak NAME: no canary or TEST-NET mark in the output, the stub's argv or the stub's environment
  local n=$1 c f
  for c in "${CANARIES[@]}"; do
    for f in "$T/$n.out" "$T/$n.err" "$T"/"$n"/out/argv.* "$T"/"$n"/out/env.*; do
      [ -e "$f" ] || continue
      if grep -aqF -- "$c" "$f"; then check "$n: no '$c' in ${f##*/}" absent present; return; fi
    done
  done
  check "$n: no canary, host or serial in output, argv or env" 0 0
}

# --- both: two probes, camera files, cleanup ---
run b1 -- both 0.5 extend
check "both: exit 0" 0 "$(rc b1)"
check "both: one probe line each" "probe cam1: end=stop login_ok=1,probe cam2: end=stop login_ok=1" "$(sort "$T/b1.out" | paste -sd,)"
check "both: two probes run at once" "start,start,end,end" "$(cut -d' ' -f1 "$T/b1/out/log" | paste -sd,)"
check "both: cam1 probe got name cam1" cam1 "$(sed -n 3p "$T/b1/out/argv.cam1")"
check "both: argv is state, camdir, name, minutes, form, count, ffmpeg" "0.5 extend 100 /bin/true" "$(sed -n '4,7p' "$T/b1/out/argv.cam1" | paste -sd' ')"
check "state dir is \$M7C_ENV_DIR/w23-probe-state" "$T/b1/envd/w23-probe-state" "$(sed -n 1p "$T/b1/out/argv.cam1")"
check "state dir mode 0700" 700 "$(stat -c %a "$T/b1/envd/w23-probe-state")"
check "camera dir 0700 as the probe saw it" "dir 700" "$(sed -n 1p "$T/b1/out/files.cam1")"
check "camera files 0600 (both)" "file cam1.conf 600,file cam2.conf 600" "$(grep -h '^file ' "$T/b1/out/files.cam1" | paste -sd,)"
check "camera file content is host/port/serial/login (the stub saw the real thing)" \
  "host=$IP1 port=8000 serial=$ID1 login=$CA host=$IP2 port=8000 serial=$ID2 login=$CB" \
  "$(grep -hv '^\(dir\|file\) ' "$T/b1/out/files.cam1" | paste -sd' ')"
check "camera dir gone after exit" 0 "$([ -e "$(cat "$T/b1/out/camdir.cam1")" ] && echo 1 || echo 0)"
check "nothing left in TMPDIR after exit" 0 "$(find "$T/b1/tmp" -mindepth 1 | wc -l)"
noleak b1

# --- one camera, the probe's exit code passes through, cleanup still happens ---
run s1 STUB_RC=75 -- cam2 1 repeat
check "single: exit code of the probe (75)" 75 "$(rc s1)"
check "single: only cam2 started" "start" "$(cut -d' ' -f1 "$T/s1/out/log" | head -n 1)"
check "single: exactly one probe" 1 "$(ls "$T"/s1/out/argv.* | wc -l)"
check "single: form passed" "1 repeat" "$(sed -n '4,5p' "$T/s1/out/argv.cam2" | paste -sd' ')"
check "single: camera dir gone after a non-zero exit" 0 "$([ -e "$(cat "$T/s1/out/camdir.cam2")" ] && echo 1 || echo 0)"
noleak s1

# --- a signal ends the probes too (I1) and the trap still cleans up: TERM -> 143, INT -> 130, HUP -> 129 ---
for sg in TERM:143 INT:130 HUP:129; do
  name=${sg%%:*}; want=${sg##*:}; k=k_$name
  mkdir -p "$T/$k/out" "$T/$k/tmp"; mkenv "$T/$k/envd"
  env TMPDIR="$T/$k/tmp" XDG_RUNTIME_DIR="$T/$k/tmp" STUB_SLEEP=60 STUB_OUT="$T/$k/out" M7C_ENV_DIR="$T/$k/envd" \
    PROBE_PYTHON=python3 PROBE_FFMPEG=/bin/true python3 -c 'import os, signal, sys   # an async child starts with SIGINT ignored, which bash cannot trap
signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp("bash", ["bash"] + sys.argv[1:])' "$PR" both 1 extend > /dev/null 2>&1 &
  kp=$!; for _ in $(seq 100); do [ -s "$T/$k/out/pid.cam2" ] && [ -s "$T/$k/out/pid.cam1" ] && break; sleep 0.05; done
  kill -"$name" "$kp"; wait "$kp" 2> /dev/null; r=$?
  check "$name: exit $want" "$want" "$r"
  check "$name: both probes are gone" "0 0" "$(for n in cam1 cam2; do kill -0 "$(cat "$T/$k/out/pid.$n")" 2>/dev/null && echo -n 1 || echo -n 0; [ $n = cam1 ] && echo -n ' '; done)"
  check "$name: camera dir gone" 0 "$([ -e "$(cat "$T/$k/out/camdir.cam1")" ] && echo 1 || echo 0)"
  check "$name: nothing left in the temp dir" 0 "$(find "$T/$k/tmp" -mindepth 1 | wc -l)"
done

# --- the camera files go under XDG_RUNTIME_DIR when it is set (M3) ---
check "camera dir was under XDG_RUNTIME_DIR" "$T/b1/tmp" "$(dirname "$(dirname "$(cat "$T/b1/out/camdir.cam1")")")"

# --- usage: exit 2, nothing read, nothing run ---
for a in "" "cam3 1 extend" "cam1 0 extend" "cam1 abc extend" "cam1 1 sideways" "cam1 1" "--status x" "both -1 extend"; do
  # shellcheck disable=SC2086  # the case's words are the arguments
  run bad -- $a; check "bad args '$a': exit 2" 2 "$(rc bad)"
  check "bad args '$a': no probe started" 0 "$(ls "$T"/bad/out/argv.* 2>/dev/null | wc -l)"
done

# --- the env dir's own errors keep make-config's exit code and words ---
mkenv "$T/e1/envd"; chmod 644 "$T/e1/envd/cameras.pairs"; run e1 -- cam1 1 extend
check "pairs file 0644: exit 2" 2 "$(rc e1)"; check "says 0600" 1 "$(grep -c 'must be 0600' "$T/e1.err")"
check "no probe after an env error" 0 "$(ls "$T"/e1/out/argv.* 2>/dev/null | wc -l)"
mkenv "$T/k2/envd"; printf 'original QR Code keys:\r\n  %s: %s\r\n' "$ID1" "$CA" > "$T/k2/envd/keys.yaml"
run k2 -- cam1 1 extend
check "a code missing: exit 6" 6 "$(rc k2)"; check "says 1 of 2" 1 "$(grep -c '1 of 2 camera codes found' "$T/k2.err")"; noleak k2

# --- --status: reads only the state dir ---
mkenv "$T/t1/envd"; S=$T/t1/envd/w23-probe-state/ezviz/state; mkdir -p "$S"
printf '{"t":1699990000.25,"ev":"attempt","dur":null}\n{"t":1699990010,"ev":"net_fail","dur":10}\n{"t":1700000100.5,"ev":"attempt","dur":null}\n{"t":1700000110,"ev":"login_ok","dur":null}\n' > "$S/cam1.ledger"
printf '{"t":1699999000,"ev":"attempt","dur":null}\n{"t":1699999001,"ev":"auth_fail","dur":1}\n{"t":1699999001,"ev":"latch","dur":null}\n' > "$S/cam2.ledger"; : > "$S/cam2.latch"
chmod 000 "$T/t1/envd/keys.yaml" "$T/t1/envd/env" "$T/t1/envd/cameras.pairs"        # a key file at mode 000 must not matter
run t1 PROBE_STATUS_NOW=1700000160 -- --status
check "status: exit 0 (key file at mode 000)" 0 "$(rc t1)"
check "status: cam1 line" "probe-state cam1: last_attempt=2023-11-14T22:15:00Z age_s=60 latched=0" "$(sed -n 1p "$T/t1.out")"
check "status: cam2 line (latched)" "probe-state cam2: last_attempt=2023-11-14T21:56:40Z age_s=1160 latched=1" "$(sed -n 2p "$T/t1.out")"
check "status: exactly two lines" 2 "$(wc -l < "$T/t1.out")"
check "status: no probe, no camera dir" 0 "$(ls "$T"/t1/out/argv.* 2>/dev/null | wc -l)"
check "status: nothing in TMPDIR" 0 "$(find "$T/t1/tmp" -mindepth 1 | wc -l)"
noleak t1
run t3 M7C_ENV_DIR="$T/t1/envd" PROBE_STATUS_NOW=1700000160 PROBE_TEST= -- --status
check "status: PROBE_STATUS_NOW is ignored without PROBE_TEST=1" 1 "$([ "$(sed -n 1p "$T/t3.out" | sed 's/.*age_s=\([0-9]*\).*/\1/')" -gt 1000000 ] && echo 1 || echo 0)"
chmod 600 "$T/t1/envd/keys.yaml" "$T/t1/envd/env" "$T/t1/envd/cameras.pairs"
# I2b: three P2 ends and no latch file are a latch for the gate, so the status says so
S4=$T/t4/envd/w23-probe-state/ezviz/state; mkdir -p "$S4"; mkenv "$T/t4/envd"
for t in 1700000000 1700000100 1700000200; do printf '{"t":%s,"ev":"attempt","dur":null}\n{"t":%s,"ev":"login_ok","dur":null}\n{"t":%s,"ev":"start_timeout","dur":5}\n' "$t" "$((t + 1))" "$((t + 5))"; done > "$S4/cam1.ledger"
run t4 PROBE_STATUS_NOW=1700000300 -- --status
check "status: 3 P2 ends, no latch file: latched=1" "probe-state cam1: last_attempt=2023-11-14T22:16:40Z age_s=100 latched=1" "$(sed -n 1p "$T/t4.out")"
check "status: no latch file was created" 0 "$([ -e "$S4/cam1.latch" ] && echo 1 || echo 0)"
run t2 -- --status
check "status with no state: exit 0" 0 "$(rc t2)"
check "status with no state: none lines" "probe-state cam1: last_attempt=none age_s=- latched=0,probe-state cam2: last_attempt=none age_s=- latched=0" "$(paste -sd, "$T/t2.out")"
check "status creates nothing" 0 "$([ -e "$T/t2/envd/w23-probe-state" ] && echo 1 || echo 0)"

[ "$fail" = 0 ] && echo "probe-run.test: all ok" || { echo "probe-run.test: FAILURES"; exit 1; }
