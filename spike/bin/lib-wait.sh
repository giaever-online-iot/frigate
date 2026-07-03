# Consumer-side readiness gate (M1 pattern, reused by M3/M4 consumers).
# wait_for_url URL TIMEOUT_S -> 0 when URL answers (sets WAITED_MS), 1 on timeout.
# Note: uses python3.11 for ms timing because core26's date +%s%3N emits nanoseconds
# (19 digits) rather than milliseconds (13 digits); arithmetic would overflow.
# NOTE: WAITED_MS includes ~300ms python3.11 startup overhead per timing call (~600ms floor for two calls); subtract when calibrating true network wait.
wait_for_url() {
    _url="$1"; _timeout="$2"
    _t0=$("$SNAP/usr/bin/python3.11" -c "import time; print(int(time.monotonic() * 1000))")
    _deadline=$(( $(date +%s) + _timeout ))
    until "$SNAP/usr/bin/python3.11" -c \
        "import sys,urllib.request; urllib.request.urlopen(sys.argv[1], timeout=2)" \
        "$_url" 2>/dev/null; do
        if [ "$(date +%s)" -ge "$_deadline" ]; then
            WAITED_MS=-1
            return 1
        fi
        sleep 0.5
    done
    _t1=$("$SNAP/usr/bin/python3.11" -c "import time; print(int(time.monotonic() * 1000))")
    WAITED_MS=$(( _t1 - _t0 ))
    return 0
}
