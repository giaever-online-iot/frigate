#!/usr/bin/env bash
# W-23 P12 / SF10: read-only check that the hub kernel logged no "Undervoltage detected" line since a time.
# It reads journald's KERNEL transport across ALL boots since the time (`journalctl -k` would imply -b, the
# current boot only, and miss an undervoltage that crashed or rebooted the hub, as on 18 Nov). It also
# counts boots in the window ("Linux version" kernel lines) and proves the journal reaches back to the time.
# One command on the hub through tests/hub/ssh-exec.sh (the operator's existing master only).
# Usage: M7C_HUB_SOCK=<socket> M7C_HUB_TARGET=<target> tests/hub/power-check.sh --since <epoch> [--allow-boots N]
# Exit: 0 PASS (0 undervoltage, boots <= N); 1 FAIL; 2 usage; 3 the master is gone; 4 INCONCLUSIVE (the journal
# cannot be read or does not cover the window: never reported as 0).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); EXEC="$HERE/ssh-exec.sh"
usage() { echo "usage: power-check.sh --since <epoch> [--allow-boots N]" >&2; exit 2; }
SINCE=""; ALLOW=0
while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ $# -ge 2 ] || usage; SINCE=$2; shift 2 ;;
    --allow-boots) [ $# -ge 2 ] || usage; ALLOW=$2; shift 2 ;;
    *) usage ;;
  esac
done
case "$SINCE" in ''|*[!0-9]*) usage ;; esac
case "$ALLOW" in ''|*[!0-9]*) usage ;; esac
ISO=$(date -u -d "@$SINCE" +%Y-%m-%dT%H:%M:%SZ)
# shellcheck disable=SC2016  # expanded on the hub, not here
REMOTE='k=$(journalctl _TRANSPORT=kernel --since @'"$SINCE"' --no-pager -q -o cat 2>/dev/null); krc=$?
c=$(journalctl --until @'"$SINCE"' -r -n 1 --no-pager -q -o short-unix 2>/dev/null | wc -l)
printf "krc=%s\ncover=%s\nuv=%s\nboots=%s\n" "$krc" "$c" "$(printf "%s\n" "$k" | grep -c "Undervoltage detected")" "$(printf "%s\n" "$k" | grep -c "Linux version")"'
out=$("$EXEC" exec "$REMOTE" 2>&1 </dev/null); rc=$?
[ "$rc" = 3 ] && { echo "power-check: MASTER GONE; nothing was read" >&2; exit 3; }
get() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -n 1; }
krc=$(get krc); cover=$(get cover); uv=$(get uv); boots=$(get boots)
for v in "$krc" "$cover" "$uv" "$boots"; do case "$v" in ''|*[!0-9]*) rc=99 ;; esac; done
if [ "$rc" != 0 ] || [ "$krc" != 0 ] || [ "$cover" != 1 ]; then
  echo "power-check: INCONCLUSIVE: the kernel journal since $ISO cannot be read or does not reach back that far"; exit 4
fi
echo "power-check: since $ISO: undervoltage lines $uv, boots $boots (allowed $ALLOW)"
if [ "$uv" != 0 ] || [ "$boots" -gt "$ALLOW" ]; then echo "power-check: FAIL"; exit 1; fi
echo "power-check: PASS"
