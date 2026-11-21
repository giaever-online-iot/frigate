#!/usr/bin/env bash
# Fake hub for tests/hub/watch.test.sh (the stub ssh's $STUB_RESPONDER). Answers watch.sh's read-only sample
# command with one key=value set per call; sample i (1-based) takes the i-th word of each knob, the last word
# repeating. Knobs: W_MEM (MemAvailable kB), W_SWAP (swap used kB), W_PSI (some avg60), W_LOAD (1-min),
# W_FRNR (frigate NRestarts), W_FREE (free kB on the data fs), W_HALOAD (HA LoadState), W_HAACT (ActiveState),
# W_HAPID (MainPID), W_HANR (HA NRestarts), W_HTTP (first HTTP line, '-' = no answer), W_HTTPMS, W_TCP (nc -z rc),
# W_CTR (docker inspect "Running RestartCount StartedAt", '_' for spaces, '-' = no such container),
# W_UV (the kernel transport's undervoltage count since the start, or 'unreadable'),
# W_BROKEN (1 = garbage instead of a sample). `snap stop --disable frigate` is logged to $STUB_ST/stops.
set -u
st="${STUB_ST:?}"
eval "set -- $1"
[ "$1 $2 $3 $4" = "sudo -n sh -c" ] || { echo "responder: not a sudo -n sh -c call: $*" >&2; exit 99; }
cmd=$5; printf '%s\n' "$cmd" >> "$st/cmds"
case "$cmd" in
  'echo m7c-watch-sample'*)
    i=$(( $(cat "$st/i" 2>/dev/null || echo 0) + 1 )); echo "$i" > "$st/i"
    pick() { local -a a; read -r -a a <<<"$1"; local k=$((i - 1)); [ "$k" -ge "${#a[@]}" ] && k=$((${#a[@]} - 1)); printf '%s' "${a[$k]}"; }
    if [ "$(pick "${W_BROKEN:-0}")" = 1 ]; then echo "m7c-watch-sample"; echo "garbage"; exit 0; fi
    http=$(pick "${W_HTTP:-HTTP/1.0_200_OK}"); [ "$http" = - ] && http=""
    ctr=$(pick "${W_CTR:-true_0_2026-11-14T10:27:54Z}"); [ "$ctr" = - ] && ctr=""
    cat <<EOF
m7c-watch-sample
memavail_kb=$(pick "${W_MEM:-12000000}")
swap_used_kb=$(pick "${W_SWAP:-0}")
psi_some_avg60=$(pick "${W_PSI:-0.00}")
load1=$(pick "${W_LOAD:-0.40}")
fr_nrestarts=$(pick "${W_FRNR:-0}")
free_kb=$(pick "${W_FREE:-200000000}")
ha_LoadState=$(pick "${W_HALOAD:-loaded}")
ha_ActiveState=$(pick "${W_HAACT:-active}")
ha_MainPID=$(pick "${W_HAPID:-4321}")
ha_NRestarts=$(pick "${W_HANR:-0}")
ha_tcp_rc=$(pick "${W_TCP:-0}")
ha_ctr=${ctr//_/ }
ha_http=${http//_/ }
ha_http_ms=$(pick "${W_HTTPMS:-40}")
kuv=$(pick "${W_UV:-0}")
end=1
EOF
    ;;
  'snap stop --disable frigate') echo stopped >> "$st/stops"; echo "Stopped." ;;
  *) echo "responder: unexpected command: $cmd" >&2; exit 98 ;;
esac
