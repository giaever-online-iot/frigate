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

# M7: snap-set config reader. Snap options are unset until the operator `snap set`s them,
# so every reader supplies a default. The `|| v=""` guard is deliberate: snapctl get can
# exit non-zero on an unset (nested) key, and an unguarded `v=$(...)` would trip `set -e`
# in the wrappers that source this file. The guard collapses that to the empty-default path.
cfg_get() { v=$(snapctl get "$1" 2>/dev/null) || v=""; [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"; }

# M7: emit the sed script that renders the ONE active detector block from frigate-config.yml
# and deletes the other two. `detector` is snap-set (ov|coral|cpu); unset => auto-detect:
# a render node (/dev/dri/renderD*) present => ov (OpenVINO GPU), else cpu. RENDER-TIME ONLY —
# config.yml is render-once (operator-owned after first boot), so this fixes the detector at
# first render. The chosen block keeps its contents (markers stripped); the other two marker
# regions are range-deleted (same idiom as the LIVECAM block). Callers: frigate-run,
# validate-config (identical logic via this shared helper). Unknown values fall back to ov.
detector_sed() {
    _det=$(cfg_get detector "")
    if [ -z "$_det" ]; then
        ls /dev/dri/renderD* >/dev/null 2>&1 && _det=ov || _det=cpu
    fi
    case "$_det" in
        cpu)
            printf '%s\n' \
                '/# DETECTOR-OV-BEGIN/,/# DETECTOR-OV-END/d' \
                '/# DETECTOR-CORAL-BEGIN/,/# DETECTOR-CORAL-END/d' \
                '/# DETECTOR-CPU-BEGIN/d' \
                '/# DETECTOR-CPU-END/d' ;;
        coral)
            printf '%s\n' \
                '/# DETECTOR-OV-BEGIN/,/# DETECTOR-OV-END/d' \
                '/# DETECTOR-CPU-BEGIN/,/# DETECTOR-CPU-END/d' \
                '/# DETECTOR-CORAL-BEGIN/d' \
                '/# DETECTOR-CORAL-END/d' ;;
        *)  # ov is the default and the fallback for any unexpected value
            printf '%s\n' \
                '/# DETECTOR-CPU-BEGIN/,/# DETECTOR-CPU-END/d' \
                '/# DETECTOR-CORAL-BEGIN/,/# DETECTOR-CORAL-END/d' \
                '/# DETECTOR-OV-BEGIN/d' \
                '/# DETECTOR-OV-END/d' ;;
    esac
}
