#!/usr/bin/env bash
# W-23 S8: per-camera recording coverage of a window, numbers only. One command on the hub through
# tests/hub/ssh-exec.sh: the snap's own python (the hub has no python3, curl or jq) reads Frigate's recordings
# list on its internal API, as observe.sh reads /stats, and prints only [start, end] pairs per camera.
# ROUTE (confirmed in the v0.18.2 source inside the snap): GET /<camera>/recordings?after=<s>&before=<e> on :5001,
# start_time/end_time per segment: frigate/api/record.py L226-254 (`@router.get("/{camera_name}/recordings")`,
# `after`/`before` floats; it returns segments with end_time >= after and start_time <= before). There is no /api
# prefix on :5001: fastapi_app.py L151 includes record.router without one and app.py L621-640 runs uvicorn on
# 127.0.0.1:5001 with no root_path (the plan's /api/<camera>/... is the nginx path). The laptop clips to the window.
# Usage: M7C_HUB_SOCK=<socket> M7C_HUB_TARGET=<target> tests/hub/coverage.sh --since <epoch> [--hours 24]
# Exit: 0 every camera >= 99 %; 1 otherwise or unreadable; 2 usage; 3 the master is gone.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); EXEC="$HERE/ssh-exec.sh"
usage() { echo "usage: coverage.sh --since <epoch> [--hours H]" >&2; exit 2; }
SINCE=""; H=24
while [ $# -gt 0 ]; do
  case "$1" in --since) [ $# -ge 2 ] || usage; SINCE=$2; shift 2 ;; --hours) [ $# -ge 2 ] || usage; H=$2; shift 2 ;; *) usage ;; esac
done
case "$SINCE" in ''|*[!0-9]*) usage ;; esac
case "$H" in ''|*[!0-9]*|0) usage ;; esac
END=$((SINCE + H * 3600))
read -r -d '' REMOTE_PY <<EOF
import json, urllib.request
for cam in ("cam1", "cam2"):
    req = urllib.request.Request("http://127.0.0.1:5001/%s/recordings?after=$SINCE&before=$END" % cam,
                                 headers={"Remote-User": "admin", "Remote-Role": "admin"})
    try:
        segs = [[float(s["start_time"]), float(s["end_time"])] for s in json.load(urllib.request.urlopen(req, timeout=30))]
        print(json.dumps({"cam": cam, "segments": segs}))
    except Exception as e:
        print(json.dumps({"cam": cam, "error": type(e).__name__}))
EOF
# shellcheck disable=SC2016  # $SNAP is expanded inside the snap's shell on the hub
out=$(printf '%s\n' "$REMOTE_PY" | "$EXEC" exec 'snap run --shell frigate.frigate -c "\"\$SNAP/usr/bin/python3.11\" -I -"' 2>&1); rc=$?
[ "$rc" = 3 ] && { echo "coverage: MASTER GONE; nothing was read" >&2; exit 3; }
read -r -d '' PY <<'EOF'
import json, os, sys
s, e = float(sys.argv[1]), float(sys.argv[2]); bad = 0; seen = set()
for line in os.environ["OUT"].splitlines():
    try:
        d = json.loads(line)
    except ValueError:
        continue
    cam = d.get("cam")
    if cam not in ("cam1", "cam2"):
        continue
    seen.add(cam)
    if "segments" not in d:
        print(f"coverage {cam}: unreadable"); bad = 1; continue
    covered, cur_s, cur_e = 0.0, None, None
    for a, b in sorted((max(a, s), min(b, e)) for a, b in d["segments"] if b > s and a < e):
        if cur_e is None or a > cur_e:
            covered += (cur_e - cur_s) if cur_e is not None else 0.0
            cur_s, cur_e = a, b
        else:
            cur_e = max(cur_e, b)
    covered += (cur_e - cur_s) if cur_e is not None else 0.0
    pct = 100.0 * covered / (e - s)
    print(f"coverage {cam}: {pct:.1f} %")
    bad = bad or pct < 99.0
for cam in sorted({"cam1", "cam2"} - seen):
    print(f"coverage {cam}: unreadable"); bad = 1
sys.exit(1 if bad else 0)
EOF
OUT=$out python3 -I -c "$PY" "$SINCE" "$END"
