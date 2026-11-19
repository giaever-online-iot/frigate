#!/usr/bin/env bash
# W-23 S2 (spec §9.2) end to end on the LAPTOP, loopback only (no hub, no camera, no network):
#   the snap's go2rtc 1.9.14 and ffmpeg (extracted from the local amd64 file) -> the snap's own go2rtc-run and
#   go2rtc-config-gen.py -> the generated exec line `ezviz-source <name> {output}#killsignal=15#killtimeout=5` with
#   its preload -> the real ezviz-source/ezviz-rearm wrappers on the W-23 venv -> tests/ezviz/fakecam.py, a fake
#   camera on 127.0.0.1 serving a decodable 1080p25 H.265 clip (fixtures.make_es).
# Checks 1-11 are the S2 clauses (F1, F2, N7, G1, E13, H1a, H1b, H2). 6m, 9m and 11m are the mutations, applied
# with sed to this test's PRIVATE copies inside the fake $SNAP (C15: no switch in shipped code); each asserts that
# the real check's own verdict is FAIL under the mutation, and that the mutation's effect is seen. The last check
# asserts the number of checks that ran, so a scenario that aborts early fails the run.
# Test-only deviations, all inside the fake $SNAP or config.yml:
#   - go2rtc-run is a private copy with ONE added line that moves the API from 127.0.0.1:1984 to a free loopback
#     port after generation (the generator forces 1984, which may be taken here); the test asserts the diff;
#   - $SNAP/usr/bin/python3.11 runs the system python3 (PyYAML), as tests/hub/serve.test.sh runs the generator;
#   - config.yml's go2rtc: section puts RTSP and WebRTC on free loopback ports, sets webrtc.candidates [] (no STUN
#     lookup) and srtp.listen "" (no :8443), so several go2rtc instances can run at once and nothing leaves loopback;
#   - EZVIZ_REARM_API points the re-arm at the test API port, or at tests/ezviz/faultproxy.py (8a, 8b).
# The re-arm runs with its production timing everywhere (first round 30 s, period 30 s, client timeout 75 s).
# Login budgets: each scenario has its own $SNAP_DATA/$SNAP_COMMON and its own fake camera; 6, 8b, 9 seed the
# ledger with 3 finished (published, stop) sessions so the cap holds the camera in budget_wait at go2rtc's start.
# Processes: every process runs in a session/process group this test created; cleanup kills those groups by PGID
# and the last check asserts that no process naming the temp dir is left. Needs: the local amd64 frigate file and
# its sha256, unsquashfs (else SKIP), python3 with PyYAML, curl, the W-23 venv (tests/ezviz/venv.sh).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
REPO=$PWD; T=$(mktemp -d); : > "$T/pgs"; : > "$T/results"
CODE=QZFAKECODEA   # the fixtures' canary login code (spec §4.5 markers), never a real one

# shellcheck disable=SC2317  # cleanup runs from the EXIT trap
cleanup() {
  local j pg
  for j in $(jobs -p); do kill "$j" 2>/dev/null; done
  for pg in $(cat "$T/pgs" 2>/dev/null); do kill -TERM -- "-$pg" 2>/dev/null; done
  for _ in $(seq 1 25); do
    left=0; for pg in $(cat "$T/pgs" 2>/dev/null); do pgrep -g "$pg" >/dev/null && left=1; done
    [ "$left" = 0 ] && break; sleep 0.2
  done
  for pg in $(cat "$T/pgs" 2>/dev/null); do kill -KILL -- "-$pg" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; echo ok >> "$T/results"; else echo "FAIL - $1 [want $2 got $3]"; echo FAIL >> "$T/results"; fi; }
skip() { echo "SKIP - serve-ezviz.test: $*"; exit 0; }
EV="$HOME/.cache/frigate-m7c-evidence"; SNAP_FILE="${M7C_AMD64_SNAP:-$EV/amd64/frigate_0.18.2_amd64.snap}"
SHA_FILE="${M7C_AMD64_SHA:-$EV/amd64.sha256}"
if [ ! -r "$SNAP_FILE" ] || [ ! -r "$SHA_FILE" ]; then skip "no local amd64 frigate file ($SNAP_FILE)"; fi
command -v unsquashfs >/dev/null || skip "no unsquashfs"
for tool in curl pgrep setsid timeout; do command -v "$tool" >/dev/null || { echo "FAIL - $tool missing"; exit 1; }; done
python3 -I -c 'import yaml' 2>/dev/null || { echo "FAIL - python3 has no PyYAML (the generator needs it)"; exit 1; }
SNAP_SHA=$(sha256sum "$SNAP_FILE" | awk '{ print $1 }')
[ "$SNAP_SHA" = "$(awk 'NR == 1 { print $1 }' "$SHA_FILE")" ] || { echo "FAIL - the amd64 file does not match its sha256"; exit 1; }
PY=$(bash tests/ezviz/venv.sh) || { echo "FAIL - tests/ezviz/venv.sh"; exit 1; }
VENV=$(dirname "$(dirname "$PY")")

# --- tools from the snap file: go2rtc and ffmpeg 8.0 --------------------------------------------------------------
X=$T/x
unsquashfs -q -n -d "$X" "$SNAP_FILE" usr/lib/ffmpeg/8.0/bin/ffmpeg usr/local/go2rtc/bin/go2rtc >/dev/null 2>&1
FF=$X/usr/lib/ffmpeg/8.0/bin/ffmpeg; G=$X/usr/local/go2rtc/bin/go2rtc
check "tools extracted from the snap file (ffmpeg 8.0 dir, go2rtc)" 1 "$([ -x "$FF" ] && [ -x "$G" ] && echo 1 || echo 0)"
GV=$("$G" -version 2>&1 | head -1); FV=$("$FF" -version 2>&1 | head -1)
echo "info - snap file sha256 $SNAP_SHA"; echo "info - go2rtc: $GV"; echo "info - ffmpeg: $FV"
check "go2rtc from the snap file is 1.9.14 [$GV]" 1 "$(case "$GV" in "go2rtc version 1.9.14 "*) echo 1;; *) echo 0;; esac)"

CLIP=$T/clip.h265
"$PY" -I -c 'import sys, pathlib; sys.path.insert(0, sys.argv[1]); import fixtures; fixtures.make_es(sys.argv[2], pathlib.Path(sys.argv[3]))' \
  "$REPO/tests/ezviz" "$FF" "$CLIP" 2> "$T/clip.err"
check "fake camera clip: 4 s 1080p25 H.265, IDR every 2 s (fixtures.make_es) [$(stat -c %s "$CLIP" 2>/dev/null) bytes]" 1 "$([ -s "$CLIP" ] && echo 1 || echo 0)"

# --- small tools ----------------------------------------------------------------------------------------------------
cat > "$T/lq.py" <<'EOF'
import json, sys, time
def recs(p):
    try:
        data = open(p, "rb").read()
    except FileNotFoundError:
        return []
    out = []
    for line in data.split(b"\n")[:-1]:          # a torn last line is not a record
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out
cmd, path, args = sys.argv[1], sys.argv[2], sys.argv[3:]
if cmd == "evs":            # evs LEDGER [SINCE]
    since = float(args[0]) if args else float("-inf")
    print(" ".join(r["ev"] for r in recs(path) if r["t"] >= since))
elif cmd == "count":        # count LEDGER EV [SINCE]
    since = float(args[1]) if len(args) > 1 else float("-inf")
    print(sum(1 for r in recs(path) if r["ev"] == args[0] and r["t"] >= since))
elif cmd == "first":        # first LEDGER EV SINCE: t of the first EV at or after SINCE
    print(next((r["t"] for r in recs(path) if r["ev"] == args[0] and r["t"] >= float(args[1])), ""))
elif cmd == "last":         # last LEDGER EV: t of the last EV
    print(next((r["t"] for r in reversed(recs(path)) if r["ev"] == args[0]), ""))
elif cmd == "lastev":
    r = recs(path); print(r[-1]["ev"] if r else "")
elif cmd == "n":
    print(len(recs(path)))
elif cmd == "seed":         # seed LEDGER OFFSET...: finished P3 sessions (attempt, login_ok, published, stop)
    now, lines = time.time(), []
    for off in args:
        a = now + float(off)
        for dt, ev, dur in ((0, "attempt", None), (2, "login_ok", None), (8, "published", None), (100, "stop", 100.0)):
            lines.append(json.dumps({"t": a + dt, "ev": ev, "dur": dur}) + "\n")
    import os
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    with open(path, "w") as f:
        f.write("".join(lines))
    os.chmod(path, 0o600)
elif cmd == "stat":         # stat STATS KEY: a fake camera counter
    try:
        print(json.load(open(path)).get(args[0], 0))
    except (OSError, ValueError):
        print(0)
elif cmd == "has":          # has - NAME < GET /api/preload body
    try:
        print(1 if args[0] in json.load(sys.stdin) else 0)
    except (ValueError, TypeError):
        print(0)
elif cmd in ("px8a", "px8b"):
    rows = recs(path)
    ins = [r for r in rows if r["ev"] == "in"]
    outs = {r["n"]: r for r in rows if r["ev"] == "out"}
    if cmd == "px8a":       # the GETs' statuses in order, and the PUT count
        gets = [str(outs[r["n"]]["status"]) if r["n"] in outs else "open" for r in ins if r["method"] == "GET"]
        print("GET:" + ",".join(gets[:2]) + " puts=%d" % sum(1 for r in ins if r["method"] == "PUT"))
    else:                   # the first PUT: status, held seconds, requests that arrived while it was open, next gap
        put = next((r for r in ins if r["method"] == "PUT"), None)
        if put is None or put["n"] not in outs:
            print("noput 0 0 none")
        else:
            o = outs[put["n"]]
            during = sum(1 for r in ins if r["n"] != put["n"] and put["t"] <= r["t"] <= o["t"])
            nxt = next((r["t"] for r in ins if r["t"] > o["t"]), None)
            print("%d %.1f %d %s" % (o["status"], o["t"] - put["t"], during,
                                     "none" if nxt is None else "%.1f" % (nxt - o["t"])))
EOF
lq() { python3 -I "$T/lq.py" "$@"; }
now() { date +%s.%N; }
sub() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", a - b }'; }
ge() { awk -v a="$1" -v b="$2" 'BEGIN { print (a != "" && a + 0 >= b + 0) ? 1 : 0 }'; }
le() { awk -v a="$1" -v b="$2" 'BEGIN { print (a != "" && a + 0 <= b + 0) ? 1 : 0 }'; }
port() { python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
wait_until() { local end=$((SECONDS + $1)); shift; while [ "$SECONDS" -lt "$end" ]; do "$@" && return 0; sleep 0.2; done; "$@"; }

# spawn PGFILE LOG CMD...: CMD becomes the leader of a new session; its PID (= its PGID) goes to PGFILE and $T/pgs.
spawn() {
  local pgf=$1 log=$2; shift 2; : > "$pgf"
  # shellcheck disable=SC2016  # $$ and $1 belong to the inner shell
  setsid bash -c 'echo $$ > "$1"; shift; exec "$@"' _ "$pgf" "$@" > "$log" 2>&1 < /dev/null &
  for _ in $(seq 1 50); do [ -s "$pgf" ] && break; sleep 0.1; done
  cat "$pgf" >> "$T/pgs"; cat "$pgf"
}
# stop_group PG: SIGTERM to the whole group, up to 10 s, then SIGKILL; prints how many processes are left.
stop_group() {
  kill -TERM -- "-$1" 2>/dev/null
  for _ in $(seq 1 50); do pgrep -g "$1" >/dev/null || break; sleep 0.2; done
  kill -KILL -- "-$1" 2>/dev/null
  for _ in $(seq 1 25); do pgrep -g "$1" >/dev/null || break; sleep 0.2; done
  pgrep -g "$1" | wc -l
}
helpers() { pgrep -g "$1" -f "ezviz_source[.]main $2 " | wc -l; }
no_helper() { [ "$(helpers "$1" "$2")" = 0 ]; }
st() { lq stat "$1/fake.$2.json" "$3"; }
ledger() { echo "$1/common/ezviz/state/$2.ledger"; }
api() { curl -s --noproxy '*' -m 5 "http://127.0.0.1:$(cat "$1/pa")/api/preload"; }
api_up() { [ "$(curl -s --noproxy '*' -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$(cat "$1/pa")/api/preload")" != 000 ]; }
listed() { [ "$(api "$1" | lq has - "$2")" = 1 ]; }
has_ev() { [ "$(lq count "$(ledger "$1" "$2")" "$3" "${4:--inf}")" -ge 1 ]; }

# mkenv ID MUTATION: a fake $SNAP, $SNAP_DATA and $SNAP_COMMON with private copies of the snap's scripts.
#   MUTATION none | no_rearm (6m: go2rtc-run without the ezviz-rearm line) | no_api_override (9m: generator step 7
#   cut) | no_killsignal (11m: the generator's exec line without #killsignal=15#killtimeout=5)
mkenv() {
  local E=$T/$1 mut=$2 s
  s=$E/snap
  mkdir -p "$s/bin" "$s/config" "$s/opt" "$s/usr/bin" "$s/usr/lib/ffmpeg/8.0/bin" "$s/usr/local/go2rtc/bin" \
    "$E/data/config" "$E/data/ezviz/cameras" "$E/common"
  chmod 700 "$E/data/ezviz/cameras"
  cp spike/bin/ezviz-source spike/bin/ezviz-rearm spike/bin/go2rtc-config-gen.py "$s/bin/"
  cp spike/config/go2rtc.yaml.in "$s/config/"
  ln -s "$VENV" "$s/opt/ezviz-py"                         # bin/python3.12 + the ezviz_source .pth
  ln -s "$FF" "$s/usr/lib/ffmpeg/8.0/bin/ffmpeg"; ln -s "$G" "$s/usr/local/go2rtc/bin/go2rtc"
  printf '#!/bin/sh\nexec python3 "$@"\n' > "$s/usr/bin/python3.11"; chmod 755 "$s/usr/bin/python3.11"
  port > "$E/pr"; port > "$E/pw"; port > "$E/pa"
  printf '%s\n' "sed -i 's/^  listen: 127[.]0[.]0[.]1:1984\$/  listen: 127.0.0.1:$(cat "$E/pa")/' \"\$SNAP_DATA/go2rtc.yaml\"  # S2 test-only: the API on a free loopback port" > "$E/insert"
  sed '/^    "\$SNAP_DATA\/ezviz\/cameras"$/r '"$E/insert" spike/bin/go2rtc-run > "$s/bin/go2rtc-run"
  if [ "$mut" = no_rearm ]; then sed -i '/^"\$SNAP\/bin\/ezviz-rearm" /d' "$s/bin/go2rtc-run"; fi
  if [ "$mut" = no_api_override ]; then
    sed -i '/^    # --- 7\. force the API settings/,/^    # --- 5\. write/{/^    # --- 5\. write/!d}' "$s/bin/go2rtc-config-gen.py"
  fi
  if [ "$mut" = no_killsignal ]; then sed -i 's/ {output}#killsignal=15#killtimeout=5" % (/ {output}" % (/' "$s/bin/go2rtc-config-gen.py"; fi
  chmod 755 "$s/bin/go2rtc-run"
  printf 'go2rtc:\n  rtsp:\n    listen: 127.0.0.1:%s\n  webrtc:\n    listen: 127.0.0.1:%s\n    candidates: []\n  srtp:\n    listen: ""\n' \
    "$(cat "$E/pr")" "$(cat "$E/pw")" > "$E/data/config/config.yml"
  chmod 600 "$E/data/config/config.yml"
  # the private copies against the real files: exactly the named lines differ
  local add del hunks
  add=$(diff spike/bin/go2rtc-run "$s/bin/go2rtc-run" | grep '^>' | sed 's/^> //')
  del=$(diff spike/bin/go2rtc-run "$s/bin/go2rtc-run" | grep '^<' | sed 's/^< //')
  local want_del=""; [ "$mut" = no_rearm ] && want_del=$(grep '^"\$SNAP/bin/ezviz-rearm" ' spike/bin/go2rtc-run)
  check "$1: private go2rtc-run differs from the real one only by the API-port line$([ "$mut" = no_rearm ] && echo ' and the removed ezviz-rearm line (6m)')" \
    "$(cat "$E/insert")|$want_del" "$add|$del"
  hunks=$(diff spike/bin/go2rtc-config-gen.py "$s/bin/go2rtc-config-gen.py" | grep -c '^[0-9]')
  add=$(diff spike/bin/go2rtc-config-gen.py "$s/bin/go2rtc-config-gen.py" | grep -c '^>')
  del=$(diff spike/bin/go2rtc-config-gen.py "$s/bin/go2rtc-config-gen.py" | grep '^<' | head -1 | sed 's/^< //')
  if [ "$mut" = no_killsignal ]; then
    local addl; addl=$(diff spike/bin/go2rtc-config-gen.py "$s/bin/go2rtc-config-gen.py" | grep '^>' | sed 's/^> //')
    check "$1: private generator = the real one with only #killsignal=15#killtimeout=5 cut from the exec line (11m)" \
      "1 1 1 1" "$hunks $add $(case "$del" in *'{output}#killsignal=15#killtimeout=5" % ('*) echo 1;; *) echo 0;; esac) $(case "$addl" in *'{output}" % ('*) echo 1;; *) echo 0;; esac)"
  elif [ "$mut" = no_api_override ]; then
    check "$1: private generator = the real one minus step 7 (D20), one deleted hunk, nothing added (9m) [$(diff spike/bin/go2rtc-config-gen.py "$s/bin/go2rtc-config-gen.py" | grep -c '^<') lines cut]" \
      "1 0 1" "$hunks $add $(case "$del" in *"# --- 7. force the API settings"*) echo 1;; *) echo 0;; esac)"
  else
    check "$1: private generator is byte-identical to the real one" "0 0" "$hunks $add"
  fi
  [ "$mut" != none ] && diff spike/bin/go2rtc-run "$s/bin/go2rtc-run" | sed 's/^/  diff go2rtc-run: /'
  [ "$mut" = no_api_override ] && diff spike/bin/go2rtc-config-gen.py "$s/bin/go2rtc-config-gen.py" | head -3 | sed 's/^/  diff generator: /'
  [ "$mut" = no_killsignal ] && diff spike/bin/go2rtc-config-gen.py "$s/bin/go2rtc-config-gen.py" | sed 's/^/  diff generator: /'
  [ "$1" = A ] && diff spike/bin/go2rtc-run "$s/bin/go2rtc-run" | sed 's/^/  diff go2rtc-run: /'
  return 0
}

# start_fake ENV CAM: one fake camera on 127.0.0.1 (a random port; camfile accepts any port), and its camera file.
start_fake() {
  local E=$1 cam=$2
  spawn "$E/pg.fake.$cam" "$E/fake.$cam.err" "$PY" -I "$REPO/tests/ezviz/fakecam.py" --code "$CODE" --es "$CLIP" \
    --stats "$E/fake.$cam.json" --port-file "$E/fake.$cam.port" --ledger-at-accept "$(ledger "$E" "$cam")" > /dev/null
  wait_until 15 test -s "$E/fake.$cam.port"
  printf 'host=127.0.0.1\nport=%s\nserial=TESTCAM-0001\nlogin=%s\n' "$(cat "$E/fake.$cam.port")" "$CODE" \
    > "$E/data/ezviz/cameras/$cam.conf"
  chmod 600 "$E/data/ezviz/cameras/$cam.conf"
}

# start_g2r ENV N API_URL: the private go2rtc-run under timeout in its own group, as the snap would start it.
start_g2r() {
  local E=$1
  spawn "$E/pg.g$2" "$E/run.$2.log" env -i PATH=/usr/bin:/bin HOME="$E" LANG=C.UTF-8 SNAP="$E/snap" \
    SNAP_DATA="$E/data" SNAP_COMMON="$E/common" EZVIZ_REARM_API="$3" timeout 900 "$E/snap/bin/go2rtc-run"
  wait_until 20 api_up "$E"
}
g2r_pid() { pgrep -g "$1" -x go2rtc; }
logs() { cat "$1"/run.*.log "$1/data/go2rtc-logs/current" 2>/dev/null; }

# consume ENV CAM SECONDS PREFIX: an RTSP consumer that decodes SECONDS of video; prints "frames errorlines".
consume() {
  local fr
  timeout $(($3 + 60)) "$FF" -hide_banner -nostdin -v error -rtsp_transport tcp -i "rtsp://127.0.0.1:$(cat "$1/pr")/$2" \
    -t "$3" -map 0:v -f framemd5 "$4.fm" 2> "$4.err"
  fr=$(grep -vc '^#' "$4.fm" 2>/dev/null); echo "${fr:-0} $(wc -l < "$4.err")"
}
# rate ENV CAM PREFIX: checks 1 and 10. go2rtc has no GOP cache, so a consumer that joins the PRELOADED stream starts
# mid-GOP and its decoder rejects the frames before the first IDR ("Could not find ref with POC"); that is the join,
# not the stream. So this consumer decodes 13 s with showinfo and prints "frames10 errors_after_sync errors_before
# lead_in key0": the frames whose pts lie in the 10 s after the first decoded frame, the decoder error lines after and
# before it, the first decoded frame's pts relative to the consumer's start (ffmpeg shifts the first packet to 0), and
# whether that frame (n:0) is a keyframe (iskey:1).
rate() {
  timeout 75 "$FF" -hide_banner -nostdin -loglevel info -rtsp_transport tcp -i "rtsp://127.0.0.1:$(cat "$1/pr")/$2" \
    -t 13 -map 0:v -vf showinfo -f null - 2> "$3.log"
  awk '/Parsed_showinfo/ && / pts_time:/ { match($0, / pts_time:[-0-9.]+/); t = substr($0, RSTART + 10, RLENGTH - 10) + 0
         if (!seen) { first = t; seen = 1; key = ($0 ~ / n: *0 / && $0 ~ / iskey:1 /) ? 1 : 0 }
         if (t < first + 10) n++; next }
       /\[hevc @/ || /rror/ { if (seen) after++; else before++ }
       END { printf "%d %d %d %.3f %d\n", n, after, before, seen ? first : 99, key }' "$3.log"
}

# ---------------------------------------------------------------- scenario A: checks 1, 5, 2, 3, 4, 7 (one camera)
scen_A() {
  local E=$T/A L S=cam1 pg t0 fr er w c y h lg a1 l0 c0 gp tk sdt tr pre natt c a2 l1 bw sp evs2 left
  mkenv A none
  printf '  streams:\n    cam1: rtsp://127.0.0.1:1/S2OPCANARY\n' >> "$E/data/config/config.yml"   # N7: operator cam1
  L=$(ledger "$E" cam1); start_fake "$E" cam1
  t0=$(now); pg=$(start_g2r "$E" 1 "http://127.0.0.1:$(cat "$E/pa")")
  wait_until 60 has_ev "$E" cam1 published
  local eb li k0
  read -r fr er eb li k0 < <(rate "$E" cam1 "$E/c1")
  check "1: cam1 decoded >= 250 frames in 10 s with 0 decode errors once synced, after a lead-in <= GOP 2 s + 1 s on a keyframe [frames=$fr errors after the first frame=$er (join errors before it=$eb) lead-in=$li s first frame key=$k0 logins=$(st "$E" $S logins_ok) published +$(sub "$(lq last "$L" published)" "$t0") s after go2rtc-run started]" \
    1 "$([ "${fr:-0}" -ge 250 ] && [ "$er" = 0 ] && [ "$(le "$li" 3)" = 1 ] && [ "$k0" = 1 ] && echo 1 || echo 0)"
  echo "evidence - 1: cam1 frames=$fr in 10 s, lead-in $li s"
  w=$(grep -c 'WARNING operator go2rtc stream cam1 replaced by the snap-owned ezviz camera' "$E/run.1.log")
  c=$( { logs "$E"; cat "$E/data/go2rtc.yaml"; } | grep -c S2OPCANARY)
  y=$(grep -c "^  cam1: exec:$E/snap/bin/ezviz-source cam1 {output}#killsignal=15#killtimeout=5\$" "$E/data/go2rtc.yaml")
  h=$(helpers "$pg" cam1); lg=$(st "$E" $S logins_ok)
  check "5 (N7): operator cam1 in config.yml dropped with a redacted warning; 1 helper, 1 login [warnings=$w canary hits in logs+yaml=$c exec-only cam1=$y helpers=$h logins=$lg]" \
    "1 0 1 1 1" "$w $c $y $h $lg"

  # 2: kill -9 go2rtc, restart
  a1=$(lq last "$L" attempt); l0=$(st "$E" $S logins_ok); c0=$(st "$E" $S connects)
  gp=$(g2r_pid "$pg"); tk=$(now); kill -KILL "$gp"
  wait_until 10 no_helper "$pg" cam1
  sdt=$(sub "$(lq last "$L" stop)" "$tk")
  left=$(stop_group "$pg")
  tr=$(now); pg=$(start_g2r "$E" 2 "http://127.0.0.1:$(cat "$E/pa")")
  pre=0; local end=$((SECONDS + 180))
  while [ "$SECONDS" -lt "$end" ]; do
    c=$(st "$E" $S connects); natt=$(lq count "$L" attempt "$tr")      # stats first, then the ledger
    [ "$natt" = 0 ] && [ "$c" != "$c0" ] && pre=$((pre + 1))
    [ "$natt" != 0 ] && [ "$(st "$E" $S logins_ok)" -gt "$l0" ] && break
    sleep 0.2
  done
  wait_until 30 has_ev "$E" cam1 published "$tr"
  a2=$(lq first "$L" attempt "$tr"); l1=$(st "$E" $S logins_ok); bw=$(logs "$E" | grep -c 'ezviz-source cam1: budget_wait')
  sp=$(sub "$a2" "$a1"); evs2=$(lq evs "$L" "$tk")
  check "2: kill -9 go2rtc -> ledger stop (Pdeathsig, +$sdt s); restart -> $bw budget_wait refusals with 0 camera contacts, then exactly 1 login, $sp s after the previous attempt [ledger since the kill: $evs2; logins $l0->$l1; old group left=$left]" \
    "stop attempt login_ok published|0|1|1|1|0" "$evs2|$pre|$((l1 - l0))|$(ge "$sp" 60)|$([ "$bw" -ge 1 ] && echo 1 || echo 0)|$left"

  # 3: remove and re-add the only consumer (a Frigate-like restart)
  local l2 n2 hp fa ea fb eb l3 n3 hp2
  l2=$(st "$E" $S logins_ok); n2=$(lq n "$L"); hp=$(pgrep -g "$pg" -f 'ezviz_source[.]main cam1 ')
  read -r fa ea < <(consume "$E" cam1 4 "$E/c3a"); sleep 1; read -r fb eb < <(consume "$E" cam1 4 "$E/c3b"); sleep 1
  l3=$(st "$E" $S logins_ok); n3=$(lq n "$L"); hp2=$(pgrep -g "$pg" -f 'ezviz_source[.]main cam1 ')
  check "3 (F2): preload kept the session: remove/re-add of the only consumer -> 0 new logins [frames $fa/$fb errors $ea/$eb; logins $l2->$l3; ledger records $n2->$n3; helper pid kept=$([ -n "$hp" ] && [ "$hp" = "$hp2" ] && echo 1 || echo 0)]" \
    "0 0 1 1" "$((l3 - l2)) $((n3 - n2)) $([ -n "$hp" ] && [ "$hp" = "$hp2" ] && echo 1 || echo 0) $([ "${fa:-0}" -gt 0 ] && [ "${fb:-0}" -gt 0 ] && echo 1 || echo 0)"

  # 4 + 7: after a >= 70 s published session, SIGTERM to go2rtc (a stop), then a clean restart
  local tp tt te last pd l4 tl dt l5 tsr
  tp=$(lq last "$L" published)
  while [ "$(ge "$(sub "$(now)" "$tp")" 70)" = 0 ]; do sleep 0.5; done
  l4=$(st "$E" $S logins_ok); gp=$(g2r_pid "$pg"); tt=$(now); kill -TERM "$gp"
  wait_until 10 no_helper "$pg" cam1; te=$(now)
  last=$(lq lastev "$L"); pd=$(sub "$(lq last "$L" stop)" "$tp")
  check "4: Pdeathsig on go2rtc SIGTERM (F1 via PR_SET_PDEATHSIG): the helper's ledger ends stop (a SIGTERM end; a SIGKILL writes none) [helper gone +$(sub "$te" "$tt") s; dur in record $(sub "$(lq last "$L" stop)" "$(lq last "$L" attempt)") s]" \
    "stop 1" "$last $(le "$(sub "$te" "$tt")" 6)"
  left=$(stop_group "$pg")
  tsr=$(now); pg=$(start_g2r "$E" 3 "http://127.0.0.1:$(cat "$E/pa")")
  wait_until 30 has_ev "$E" cam1 login_ok "$tt"
  tl=$(lq first "$L" login_ok "$tt"); dt=$(sub "$tl" "$tt")
  wait_until 30 has_ev "$E" cam1 published "$tt"; sleep 2; l5=$(st "$E" $S logins_ok)
  check "7 (E13): clean go2rtc restart after a $pd s published session -> exactly 1 new login, login_ok +$dt s after the SIGTERM (+$(sub "$tl" "$tsr") s after go2rtc-run restarted), no 60 s gap [logins $l4->$l5]" \
    "1 1 1" "$((l5 - l4)) $(le "$dt" 10) $(ge "$pd" 70)"
  echo "evidence - 7: login_ok $dt s after the stop's SIGTERM; previous session published for $pd s"
  gp=$(g2r_pid "$pg"); kill -TERM "$gp"; wait_until 10 no_helper "$pg" cam1
  left=$(stop_group "$pg"); local lf; lf=$(stop_group "$(cat "$E/pg.fake.cam1")")
  check "A: teardown -> ledger ends stop, 3 attempts and 3 fake logins in total, groups empty [ledger: $(lq evs "$L")]" \
    "stop 3 3 0 0" "$(lq lastev "$L") $(lq count "$L" attempt) $(st "$E" $S logins_ok) $left $lf"
}

# ---------------------------------------------------------------- 6 / 6m: the preload re-arm (G1)
scen_6() {
  local id=$1 mut=$2 E=$T/$1 L pg t0 sf la lo fa ea fb eb l1 rd pred info left lf
  mkenv "$id" "$mut"; L=$(ledger "$E" cam1); start_fake "$E" cam1
  lq seed "$L" -3510 -2400 -1200        # 3 attempts in the window, the oldest at now - 3600 + 90
  t0=$(now); pg=$(start_g2r "$E" 1 "http://127.0.0.1:$(cat "$E/pa")")
  wait_until 20 grep -q 'ezviz-source cam1: budget_wait' "$E/data/go2rtc-logs/current"; sleep 1
  sf=$([ "$(logs "$E" | grep -c 'ezviz-source cam1: budget_wait')" -ge 1 ] && ! listed "$E" cam1 \
    && [ "$(lq count "$L" attempt "$t0")" = 0 ] && echo 1 || echo 0)
  la=""
  while [ "$(le "$(sub "$(now)" "$t0")" 155)" = 1 ]; do
    if listed "$E" cam1; then la=$(sub "$(now)" "$t0"); break; fi
    sleep 1
  done
  lo=$(st "$E" cam1 logins_ok)
  read -r fa ea < <(consume "$E" cam1 4 "$E/c6a"); sleep 1; read -r fb eb < <(consume "$E" cam1 4 "$E/c6b"); sleep 2
  l1=$(st "$E" cam1 logins_ok); rd=$((l1 - lo))
  pred=$([ "$sf" = 1 ] && [ "$(le "$la" 150)" = 1 ] && [ "$rd" = 0 ] && echo 1 || echo 0)
  info="start-time preload failed=$sf; GET /api/preload listed cam1 at +${la:-never} s; logins when listed=$lo; consumer remove/re-add logins=$rd; frames $fa/$fb; ledger since start: $(lq evs "$L" "$t0")"
  if [ "$mut" = none ]; then
    check "6 (G1): start in budget_wait -> start-time preload fails; GET lists cam1 within 90+30+30 s; remove/re-add -> 0 new logins [$info]" 1 "$pred"
  else
    check "6m: check 6's own verdict is FAIL under no_rearm [$info]" 0 "$pred"
    check "6m: under no_rearm the consumer remove/re-add costs a login (mutation detected) [re-add logins=$rd]" 1 "$([ "$rd" -ge 1 ] && echo 1 || echo 0)"
  fi
  left=$(stop_group "$pg"); lf=$(stop_group "$(cat "$E/pg.fake.cam1")")
  check "$id: teardown, groups empty" "0 0" "$left $lf"
}

# ---------------------------------------------------------------- 8a / 8b: the fault proxy (H1), production timeouts
start_proxy() {   # ENV ARGS...: faultproxy between the re-arm and go2rtc's API
  local E=$1; shift; port > "$E/pp"
  spawn "$E/pg.proxy" "$E/proxy.err" "$PY" -I "$REPO/tests/ezviz/faultproxy.py" --listen "$(cat "$E/pp")" \
    --upstream "$(cat "$E/pa")" --log "$E/proxy.log" --port-file "$E/proxy.port" "$@" > /dev/null
  wait_until 15 test -s "$E/proxy.port"
}
gets_done() { local n; n=$(grep -c '"ev": "out", "method": "GET"' "$1/proxy.log" 2>/dev/null); [ "${n:-0}" -ge "$2" ]; }
put_done() { grep -q '"ev": "out", "method": "PUT"' "$1/proxy.log" 2>/dev/null; }
req_after_put() { [ "$(lq px8b "$1/proxy.log" | awk '{ print $4 }')" != none ]; }

scen_8a() {
  local E=$T/8a L pg t0 px stops lg ls gt left lf lp
  mkenv 8a none; L=$(ledger "$E" cam1); start_fake "$E" cam1
  start_proxy "$E" --fail-next-get 1
  t0=$(now); pg=$(start_g2r "$E" 1 "http://127.0.0.1:$(cat "$E/pp")")
  wait_until 60 has_ev "$E" cam1 published; wait_until 20 listed "$E" cam1
  wait_until 110 gets_done "$E" 2; sleep 2
  px=$(lq px8a "$E/proxy.log"); stops=$(lq count "$L" stop); lg=$(st "$E" cam1 logins_ok)
  ls=$(listed "$E" cam1 && echo 1 || echo 0)
  gt=$(python3 -I -c 'import json, sys; t0 = float(sys.argv[2]); print("/".join("+%.1f" % (r["t"] - t0) for r in map(json.loads, open(sys.argv[1])) if r["ev"] == "in"))' "$E/proxy.log" "$t0")
  check "8a (H1a): one failed GET (503) while cam1's preload is registered and no other consumer exists -> no PUT that round, 0 stop, 0 extra logins [proxy: $px; requests at $gt s; ledger: $(lq evs "$L"); logins=$lg; still listed=$ls]" \
    "GET:503,200 puts=0|0|1|1" "$px|$stops|$lg|$ls"
  left=$(stop_group "$pg"); lf=$(stop_group "$(cat "$E/pg.fake.cam1")"); lp=$(stop_group "$(cat "$E/pg.proxy")")
  check "8a: teardown, groups empty" "0 0 0" "$left $lf $lp"
}

scen_8b() {
  local E=$T/8b L pg t0 px pst lg ar left lf lp
  mkenv 8b none; L=$(ledger "$E" cam1); start_fake "$E" cam1
  lq seed "$L" -3580 -2400 -1200        # budget_wait at the start-time preload; the cap opens at +20 s
  start_proxy "$E" --hold-put-s 40
  t0=$(now); pg=$(start_g2r "$E" 1 "http://127.0.0.1:$(cat "$E/pp")")
  wait_until 150 put_done "$E"; wait_until 50 req_after_put "$E"
  px=$(lq px8b "$E/proxy.log"); read -r pst _ _ _ <<< "$px"
  lg=$(st "$E" cam1 logins_ok); ar=$(grep -c 'ezviz-rearm cam1: armed' "$E/data/go2rtc-logs/current")
  check "8b (H1b): proxy holds the PUT 40 s -> no second request reaches the proxy until it answers [status held_s during next_gap_s = $px; logins=$lg; armed lines=$ar; ledger since start: $(lq evs "$L" "$t0")]" \
    "200|1|0|1|1|1" "$pst|$(ge "$(echo "$px" | awk '{ print $2 }')" 40)|$(echo "$px" | awk '{ print $3 }')|$(ge "$(echo "$px" | awk '{ print $4 }')" 25)|$lg|$ar"
  left=$(stop_group "$pg"); lf=$(stop_group "$(cat "$E/pg.fake.cam1")"); lp=$(stop_group "$(cat "$E/pg.proxy")")
  check "8b: teardown, groups empty" "0 0 0" "$left $lf $lp"
}

# ---------------------------------------------------------------- 9 / 9m: the forced API settings (H2)
api_refused() { grep -q 'ezviz-rearm: api_refused' "$1/data/go2rtc-logs/current" 2>/dev/null; }
scen_9() {
  local id=$1 mut=$2 E=$T/$1 L pg t0 wl wb wa cn ls rf ar at pred info left lf
  mkenv "$id" "$mut"; L=$(ledger "$E" cam1); start_fake "$E" cam1
  printf '  api:\n    username: s2canaryuser\n    password: s2canarypw\n    local_auth: true\n    allow_paths:\n    - /api/streams\n    base_path: /s2canarybase\n' \
    >> "$E/data/config/config.yml"
  lq seed "$L" -3580 -2400 -1200        # the start-time preload fails, so arming needs the loop's PUT
  t0=$(now); pg=$(start_g2r "$E" 1 "http://127.0.0.1:$(cat "$E/pa")")
  if [ "$mut" = none ]; then wait_until 90 listed "$E" cam1; else wait_until 60 api_refused "$E"; sleep 3; fi
  wl=$(grep -c 'WARNING operator go2rtc.api.local_auth overridden' "$E/run.1.log")
  wb=$(grep -c 'WARNING operator go2rtc.api.base_path overridden' "$E/run.1.log")
  wa=$(grep -c 'WARNING operator go2rtc.api.allow_paths overridden' "$E/run.1.log")
  cn=$(logs "$E" | grep -c 's2canary')
  ls=$(listed "$E" cam1 && echo 1 || echo 0)
  rf=$(grep -c 'ezviz-rearm: api_refused' "$E/data/go2rtc-logs/current")
  ar=$(grep -c 'ezviz-rearm cam1: armed' "$E/data/go2rtc-logs/current")
  at=$(lq count "$L" attempt "$t0")
  pred=$([ "$wl $wb $wa $cn $ls $rf $ar" = "1 1 1 0 1 0 1" ] && echo 1 || echo 0)
  info="warnings local_auth/base_path/allow_paths=$wl/$wb/$wa; value canaries in logs=$cn; listed=$ls; api_refused lines=$rf; armed lines=$ar; attempts=$at; +$(sub "$(now)" "$t0") s"
  if [ "$mut" = none ]; then
    check "9 (H2): username/password, local_auth true, allow_paths without /api/preload, base_path -> still re-arms; one redacted warning per overridden key [$info]" 1 "$pred"
  else
    check "9m: check 9's own verdict is FAIL under no_api_override [$info]" 0 "$pred"
    check "9m: under no_api_override the loop logs ezviz-rearm: api_refused and never re-arms (mutation detected) [api_refused=$rf armed=$ar attempts=$at]" "1 0 0" "$rf $ar $at"
  fi
  left=$(stop_group "$pg"); lf=$(stop_group "$(cat "$E/pg.fake.cam1")")
  check "$id: teardown, groups empty" "0 0" "$left $lf"
}

# ---------------------------------------------------------------- 11 / 11m: go2rtc's OWN producer close (F1)
# A SIGTERM to go2rtc only ends its main (the helper then dies by Pdeathsig, checks 2 and 4). Here go2rtc itself
# closes the producer: DELETE /api/preload removes the only consumer, RemoveConsumer -> stopProducers -> the exec
# producer's cmd.Close, whose cancel is Process.Signal(15) only because the exec line carries #killsignal=15
# (Go's default cancel is SIGKILL). The next decision (our own PUT, refused by the 60 s spacing) must find no open
# session to class, i.e. append no synthetic unknown_end.
scen_11() {
  local id=$1 mut=$2 E=$T/$1 L pg t0 ph code ts tg gone ls last unk pred info left lf
  mkenv "$id" "$mut"; L=$(ledger "$E" cam1); start_fake "$E" cam1
  t0=$(now); pg=$(start_g2r "$E" 1 "http://127.0.0.1:$(cat "$E/pa")")
  wait_until 60 has_ev "$E" cam1 published; wait_until 10 listed "$E" cam1; sleep 1
  ph=$(lq lastev "$L")
  ts=$(now); code=$(curl -s --noproxy '*' -m 20 -o /dev/null -w '%{http_code}' -X DELETE "http://127.0.0.1:$(cat "$E/pa")/api/preload?src=cam1")
  wait_until 10 no_helper "$pg" cam1; tg=$(now); gone=$(sub "$tg" "$ts")
  ls=$(listed "$E" cam1 && echo 1 || echo 0); last=$(lq lastev "$L")
  curl -s --noproxy '*' -m 80 -o /dev/null -X PUT "http://127.0.0.1:$(cat "$E/pa")/api/preload?src=cam1&video"
  sleep 1; unk=$(lq count "$L" unknown_end)
  pred=$([ "$code $ls $last $unk" = "200 0 stop 0" ] && [ "$(le "$gone" 6)" = 1 ] && echo 1 || echo 0)
  info="phase before=P3 ($ph); DELETE /api/preload -> HTTP $code; helper gone +$gone s; still listed=$ls; last own record=$last; unknown_end after the next decision=$unk; logins=$(st "$E" cam1 logins_ok); ledger: $(lq evs "$L" "$t0")"
  if [ "$mut" = none ]; then
    check "11 (F1): go2rtc's own producer close (DELETE of the only consumer, the preload) sends #killsignal=15 -> helper gone within close + 5 s, ledger ends the P3 SIGTERM record stop, no synthetic unknown_end [$info]" 1 "$pred"
  else
    check "11m: check 11's own verdict is FAIL without #killsignal=15#killtimeout=5 [$info]" 0 "$pred"
    check "11m: without killsignal go2rtc SIGKILLs the helper: no own end record, the next decision writes a synthetic unknown_end (mutation detected) [last own record=$last unknown_end=$unk]" "1 1" "$([ "$last" != stop ] && echo 1 || echo 0) $([ "$unk" -ge 1 ] && echo 1 || echo 0)"
  fi
  left=$(stop_group "$pg"); lf=$(stop_group "$(cat "$E/pg.fake.cam1")")
  check "$id: teardown, groups empty" "0 0" "$left $lf"
}

# ---------------------------------------------------------------- 10: both cameras at once
scen_10() {
  local E=$T/10 pg f1 e1 f2 e2 h l1 l2 left lf1 lf2
  mkenv 10 none; start_fake "$E" cam1; start_fake "$E" cam2
  pg=$(start_g2r "$E" 1 "http://127.0.0.1:$(cat "$E/pa")")
  wait_until 60 has_ev "$E" cam1 published; wait_until 30 has_ev "$E" cam2 published
  rate "$E" cam1 "$E/c1" > "$E/c1.res" & local p1=$!
  rate "$E" cam2 "$E/c2" > "$E/c2.res" & local p2=$!
  wait "$p1" "$p2"
  local b1 b2 i1 i2 k1 k2; read -r f1 e1 b1 i1 k1 < "$E/c1.res"; read -r f2 e2 b2 i2 k2 < "$E/c2.res"
  h=$(pgrep -g "$pg" -f 'ezviz_source[.]main cam[12] ' | wc -l); l1=$(st "$E" cam1 logins_ok); l2=$(st "$E" cam2 logins_ok)
  check "10: both cameras at once (two fakes) -> cam1 and cam2 each >= 250 frames in 10 s, 0 errors once synced, lead-in <= 3 s on a keyframe, 1 login each [frames $f1/$f2 errors after sync $e1/$e2 (join errors $b1/$b2) lead-in $i1/$i2 s key $k1/$k2 logins $l1/$l2 helpers=$h]" \
    "1 1 1 2" "$([ "${f1:-0}" -ge 250 ] && [ "$e1" = 0 ] && [ "$(le "$i1" 3)" = 1 ] && [ "$k1" = 1 ] && echo 1 || echo 0) $([ "${f2:-0}" -ge 250 ] && [ "$e2" = 0 ] && [ "$(le "$i2" 3)" = 1 ] && [ "$k2" = 1 ] && echo 1 || echo 0) $([ "$l1 $l2" = "1 1" ] && echo 1 || echo 0) $h"
  echo "evidence - 10: cam1 frames=$f1 cam2 frames=$f2 in 10 s, lead-in $i1/$i2 s"
  left=$(stop_group "$pg"); lf1=$(stop_group "$(cat "$E/pg.fake.cam1")"); lf2=$(stop_group "$(cat "$E/pg.fake.cam2")")
  check "10: teardown, groups empty" "0 0 0" "$left $lf1 $lf2"
}

# ---------------------------------------------------------------- run: A beside the re-arm scenarios, then 10
TS=$SECONDS
scen_A > "$T/out.A" 2>&1 & PA_=$!
scen_6 6 none > "$T/out.6" 2>&1 & P6=$!
scen_6 6m no_rearm > "$T/out.6m" 2>&1 & P6M=$!
scen_8a > "$T/out.8a" 2>&1 & P8A=$!
scen_8b > "$T/out.8b" 2>&1 & P8B=$!
scen_9 9 none > "$T/out.9" 2>&1 & P9=$!
scen_9 9m no_api_override > "$T/out.9m" 2>&1 & P9M=$!
scen_11 11 none > "$T/out.11" 2>&1 & P11=$!
scen_11 11m no_killsignal > "$T/out.11m" 2>&1 & P11M=$!
wait "$PA_" "$P6" "$P6M" "$P8A" "$P8B" "$P9" "$P9M" "$P11" "$P11M"
scen_10 > "$T/out.10" 2>&1
for s in A 6 6m 8a 8b 9 9m 11 11m 10; do cat "$T/out.$s"; done

# --- nothing of ours is left: no process names the temp dir (every go2rtc, helper, ffmpeg, fake and proxy does) ---
for pg in $(cat "$T/pgs"); do kill -KILL -- "-$pg" 2>/dev/null; done; sleep 0.5
check "cleanup: no process left that names the test's temp dir" 0 "$(pgrep -fc -- "$T")"
# M1: every check must have run (a scenario that aborts early leaves its checks out). 52 checks before this one:
# 3 setup, A 9, 6 4, 6m 5, 8a 4, 8b 4, 9 4, 9m 5, 11 4, 11m 5, 10 4, cleanup 1.
EXPECTED=52
ran=$(($(grep -c '^ok' "$T/results") + $(grep -c '^FAIL' "$T/results")))
check "check count: all $EXPECTED checks ran [ran=$ran]" "$EXPECTED" "$ran"
oks=$(grep -c '^ok' "$T/results"); fails=$(grep -c '^FAIL' "$T/results")
echo "serve-ezviz.test: $oks ok, $fails FAIL in $((SECONDS - TS)) s of scenarios"
[ "$fails" = 0 ] && echo "serve-ezviz.test: all ok" || echo "serve-ezviz.test: FAILURES"
[ "$fails" = 0 ]
