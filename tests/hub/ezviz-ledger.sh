#!/usr/bin/env bash
# W-23: read both cameras' ledgers on the hub (one read-only command through tests/hub/ssh-exec.sh) and print
# counts only. The ledgers hold no host, serial or login (spec §4.3); this prints event names, counts and times.
# The hub only fetches the bytes (R2-N6): per camera `== <cam>`, the ledger, one `echo` (so a torn last line can
# never run into the next header, C5), `== latchfile` when the latch file exists; `== end` last. The LAPTOP parses
# each camera's bytes with the repo's own ezviz_source.ledger.parse (spike/ezviz; stdlib only) and decides
# `latched` with policy.decide(records, now, latch_file=...), so the torn-line rule and the T-END latch row are the
# helper's own code, never a second parser here.
# Usage: M7C_HUB_SOCK=<socket> M7C_HUB_TARGET=<target> tests/hub/ezviz-ledger.sh [--since <epoch>]
# Exit: 0 ok; 1 a camera is latched, its ledger is damaged, a rolling 60 min holds > 3 attempts, or the hub's
#       answer is incomplete; 2 usage; 3 the master is gone.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); EXEC="$HERE/ssh-exec.sh"; PKG="$HERE/../../spike/ezviz"
usage() { echo "usage: ezviz-ledger.sh [--since <epoch>]" >&2; exit 2; }
SINCE=0
while [ $# -gt 0 ]; do
  case "$1" in --since) [ $# -ge 2 ] || usage; SINCE=$2; shift 2 ;; *) usage ;; esac
done
case "$SINCE" in ''|*[!0-9]*) usage ;; esac
[ -r "$PKG/ezviz_source/ledger.py" ] && [ -r "$PKG/ezviz_source/policy.py" ] \
  || { echo "ezviz-ledger: $PKG/ezviz_source is missing (run from a checkout)" >&2; exit 2; }
ST=/var/snap/frigate/common/ezviz/state
TMP=$(mktemp -d) || exit 2; trap 'rm -rf "$TMP"' EXIT
# The hub's bytes go to a file, untouched (a shell variable would drop NUL bytes and trailing newlines); ssh's
# own stderr is kept apart so it can never be read as a ledger line.
"$EXEC" exec "for n in cam1 cam2; do echo \"== \$n\"; cat $ST/\$n.ledger 2>/dev/null; echo; [ -e $ST/\$n.latch ] && echo '== latchfile'; done; echo '== end'" \
  > "$TMP/out" 2> "$TMP/err" </dev/null; rc=$?
[ "$rc" = 3 ] && { echo "ezviz-ledger: MASTER GONE; nothing was read" >&2; exit 3; }
[ "$rc" = 0 ] || { echo "ezviz-ledger: the hub command failed (rc $rc)"; exit 1; }
# python3 -I (isolated: no PYTHONPATH, no user site, no script or current directory on sys.path) plus one explicit
# sys.path entry, the repo's spike/ezviz; -B writes no __pycache__ into the checkout.
read -r -d '' PY <<'EOF'
import collections, datetime, re, sys, time
sys.path.insert(0, sys.argv[1])
from ezviz_source import constants as C
from ezviz_source.ledger import LedgerDamaged, parse
from ezviz_source.policy import decide
since = float(sys.argv[2])
with open(sys.argv[3], "rb") as f:
    data = f.read()
# The answer must be exactly: "== cam1\n" BYTES "\n" ["== latchfile\n"] "== cam2\n" BYTES "\n" ["== latchfile\n"] "== end\n".
# A ledger line that itself starts with "== cam..." breaks that shape and is reported as malformed, never parsed.
marks = list(re.finditer(rb"^== (cam1|cam2|latchfile|end)\n", data, re.M))
tags = [m.group(1).decode() for m in marks]
bodies = [data[m.end():(marks[i + 1].start() if i + 1 < len(marks) else len(data))] for i, m in enumerate(marks)]
ok = (bool(marks) and marks[0].start() == 0 and re.fullmatch(r"cam1 (latchfile )?cam2 (latchfile )?end", " ".join(tags)) is not None
      and all(b.endswith(b"\n") if t.startswith("cam") else b == b"" for t, b in zip(tags, bodies)))
if not ok:
    print("ezviz-ledger: the hub's answer is incomplete or malformed; no counts")
    sys.exit(1)
cams, order = {}, []
for t, b in zip(tags, bodies):
    if t == "latchfile":
        cams[order[-1]]["latch"] = True
    elif t != "end":
        cams[t] = {"bytes": b[:-1], "latch": False}         # strip exactly the one "\n" the remote echo added
        order.append(t)
now, bad = time.time(), 0
for name in order:
    c = cams[name]
    try:
        recs = parse(c["bytes"])          # the helper's own reader: a torn LAST line is skipped (spec 4.3)
    except LedgerDamaged:
        print(f"ledger {name}: damaged")
        bad = 1
        continue
    latched = decide(recs, now, latch_file=c["latch"]).cls == "latched"   # T-END latch row, auth_fail, latch file
    att = sorted(r["t"] for r in recs if r["ev"] == "attempt")
    mx = max((sum(1 for b in att if a <= b < a + 3600) for a in att), default=0)
    n = lambda ev, t0=float("-inf"): sum(1 for r in recs if r["ev"] == ev and r["t"] >= t0)
    ends = collections.Counter(r["ev"] for r in recs if r["ev"] in C.END_EVENTS)
    last = "none"
    if recs:
        ts = datetime.datetime.fromtimestamp(recs[-1]["t"], datetime.timezone.utc)
        last = recs[-1]["ev"] + "@" + ts.strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"ledger {name}: attempts={len(att)} login_ok={n('login_ok')} published={n('published')} "
          f"ends={','.join(f'{k}:{v}' for k, v in sorted(ends.items())) or '-'} latched={int(latched)} "
          f"max_attempts_any_60min={mx} attempts_since={n('attempt', since)} login_ok_since={n('login_ok', since)} last={last}")
    bad = bad or latched or mx > 3
sys.exit(1 if bad else 0)
EOF
python3 -I -B -c "$PY" "$PKG" "$SINCE" "$TMP/out"
