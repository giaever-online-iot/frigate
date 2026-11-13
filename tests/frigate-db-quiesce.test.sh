#!/usr/bin/env bash
# Hermetic test of spike/bin/frigate-db-quiesce (M9 D24 a). Real sqlite (host python3), no snap.
# Run: bash tests/frigate-db-quiesce.test.sh   (exit 0 = all ok)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
FAILS=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; FAILS=$((FAILS+1)); }
expect() { local n="$1"; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
PY=$(command -v python3) || { echo "FAIL - python3 missing"; exit 1; }

SB=$(mktemp -d); HOLDER=""; HOOK_PG=""
# the EXIT trap kills only the PIDs/process group this test started, by number
trap '[ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null; [ -n "$HOOK_PG" ] && kill -9 -- "-$HOOK_PG" 2>/dev/null; [ -n "$SB" ] && rm -rf "$SB"' EXIT
mkdir -p "$SB/snap/usr/bin" "$SB/common/db"
ln -s "$PY" "$SB/snap/usr/bin/python3.11"      # the hook calls $SNAP/usr/bin/python3.11
DB="$SB/common/db/frigate.db"
MARKER="m9-secret-row-content"

# mkwal <db>: a WAL-mode DB whose writer died without closing (os._exit): -wal and -shm stay behind
# and hold every committed row (autocheckpoint off), exactly like a frigate killed mid-run.
mkwal() { "$PY" - "$1" "$MARKER" <<'EOF'
import os, sqlite3, sys
con = sqlite3.connect(sys.argv[1], isolation_level=None)
con.execute("PRAGMA journal_mode=WAL"); con.execute("PRAGMA wal_autocheckpoint=0")
con.execute("CREATE TABLE t (x TEXT)")
con.execute("BEGIN")
con.executemany("INSERT INTO t VALUES (?)", [(sys.argv[2],)] + [("r%d" % i * 20,) for i in range(2000)])
con.execute("COMMIT")
os._exit(0)
EOF
}
rows_ok() { [ "$("$PY" -c 'import sqlite3,sys; c=sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True); print(c.execute("PRAGMA integrity_check").fetchone()[0], c.execute("SELECT COUNT(*) FROM t").fetchone()[0])' "$1")" = "ok 2001" ]; }
# hdr <db>: the file-format write/read version bytes 18-19, read as raw bytes (not via sqlite):
# "1 1" = rollback journal (DELETE), "2 2" = WAL.
hdr() { "$PY" -c 'import sys; b=open(sys.argv[1],"rb").read(20); print(b[18], b[19])' "$1"; }
hdr_rollback() { [ "$(hdr "$1")" = "1 1" ]; }
run_hook() { OUT=$(SNAP="$SB/snap" SNAP_COMMON="$SB/common" "$@" bash "$REPO/spike/bin/frigate-db-quiesce" 2>&1); RC=$?; }
one_line() { [ "$(printf '%s\n' "$OUT" | wc -l)" -eq 1 ]; }
result_is() { one_line && grep -qx "frigate-db-quiesce: .* result=$1" <<<"$OUT"; }
no_content() { ! grep -qF "$MARKER" <<<"$OUT"; }

echo "# case 1: stale WAL from a killed writer"
mkwal "$DB"
expect "precondition: -wal is non-empty"      test -s "$DB-wal"
expect "precondition: header is WAL (bytes 18-19 = 2 2)" test "$(hdr "$DB")" = "2 2"
echo "#   before: header[18,19]=$(hdr "$DB") db=$(stat -c %s "$DB") -wal=$(stat -c %s "$DB-wal") -shm=$(stat -c %s "$DB-shm" 2>/dev/null || echo absent)"
run_hook env
echo "#   output: $OUT"
echo "#   after:  header[18,19]=$(hdr "$DB") -wal=$(stat -c %s "$DB-wal" 2>/dev/null || echo absent) -shm=$(stat -c %s "$DB-shm" 2>/dev/null || echo absent)"
expect "exit 0"                               test "$RC" -eq 0
expect "-wal removed"                         test ! -e "$DB-wal"
expect "-shm removed"                         test ! -e "$DB-shm"
expect "header is rollback-journal (bytes 18-19 = 1 1)" hdr_rollback "$DB"
expect "integrity ok and every WAL row checkpointed" rows_ok "$DB"
expect "exactly one log line"                 one_line
expect "log line has sizes and result=ok"     grep -qE '^frigate-db-quiesce: db=[0-9]+ wal_before=[0-9]+ wal_after=absent shm_after=absent result=ok$' <<<"$OUT"
expect "log carries no DB content"            no_content

echo "# case 2: no DB"
rm -f "$DB" "$DB-wal" "$DB-shm"
run_hook env
expect "nodb: exit 0"                         test "$RC" -eq 0
expect "nodb: one line, result=nodb"          result_is nodb
expect "nodb: no DB created"                  test ! -e "$DB"

echo "# case 3: not a database"
printf '%s\n' "$MARKER not sqlite" > "$DB"
run_hook env
expect "garbage: exit 0"                      test "$RC" -eq 0
expect "garbage: one line, result=error:<class>" result_is 'error:[A-Za-z]*'
expect "garbage: log carries no file content" no_content
rm -f "$DB" "$DB-wal" "$DB-shm"

echo "# case 4: timeout (another process holds the write lock)"
mkwal "$DB"
"$PY" - "$DB" "$SB/locked" <<'EOF' &
import sqlite3, sys, time
con = sqlite3.connect(sys.argv[1], isolation_level=None)
con.execute("BEGIN IMMEDIATE"); con.execute("INSERT INTO t VALUES ('held')")
open(sys.argv[2], "w").close()
time.sleep(60)
EOF
HOLDER=$!
for _ in $(seq 50); do [ -e "$SB/locked" ] && break; sleep 0.1; done
expect "precondition: lock holder is up"      test -e "$SB/locked"
T0=$(date +%s)
run_hook env FRIGATE_DB_QUIESCE_TIMEOUT=2
EL=$(( $(date +%s) - T0 ))
echo "#   output: $OUT (${EL}s)"
expect "timeout: exit 0"                      test "$RC" -eq 0
expect "timeout: bounded (${EL}s < 8s)"       test "$EL" -lt 8
expect "timeout: one line, result=timeout"    result_is timeout
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""
expect "timeout: DB intact after the interrupted quiesce" rows_ok "$DB"

echo "# case 5: the revert path - quiesce at the 0.18 stop, then 0.17.2's FROZEN restore shape"
# 0.17.2's frigate-run (a39bfb0 :138-139) restores with `mv frigate.db frigate.db.incompatible-TS;
# cp BACKUP frigate.db` and leaves -wal/-shm alone. After the quiesce there is nothing left to replay.
rm -f "$DB" "$DB-wal" "$DB-shm"   # case 4 leaves its DB behind
"$PY" - "$SB/backup.db" <<'EOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1]); con.execute("CREATE TABLE t (x TEXT)")
con.executemany("INSERT INTO t VALUES (?)", [("old",)] * 50); con.commit(); con.close()
EOF
mkwal "$DB"
expect "precondition: -wal is non-empty"      test -s "$DB-wal"
run_hook env
expect "revert: exit 0"                       test "$RC" -eq 0
mv "$DB" "$DB.incompatible-1" 2>/dev/null || true
cp "$SB/backup.db" "$DB"
expect "revert: restored DB is the backup (integrity ok, 50 rows)" test "$("$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute("PRAGMA integrity_check").fetchone()[0], c.execute("SELECT COUNT(*) FROM t").fetchone()[0])' "$DB")" = "ok 50"
expect "revert: the preserved 0.18 DB is whole on its own" rows_ok "$DB.incompatible-1"

# run_hook_capped <cap_s> env [VAR=…]: run_hook in its own session (setsid: pid = process-group id),
# polled; past <cap_s> s the whole group is SIGKILLed by its id, so a hook that ignores its own bound
# cannot hang this test. Sets OUT, RC, EL_NS (date +%s%N) and CAPPED (1 = had to be killed).
run_hook_capped() {
  local cap="$1" t0 out="$SB/capped.out"; shift
  t0=$(date +%s%N); CAPPED=0
  SNAP="$SB/snap" SNAP_COMMON="$SB/common" setsid "$@" bash "$REPO/spike/bin/frigate-db-quiesce" >"$out" 2>&1 &
  HOOK_PG=$!
  while kill -0 "$HOOK_PG" 2>/dev/null; do
    if [ $(( ($(date +%s%N) - t0) / 1000000000 )) -ge "$cap" ]; then
      kill -9 -- "-$HOOK_PG" 2>/dev/null; CAPPED=1; break
    fi
    sleep 0.2
  done
  wait "$HOOK_PG" 2>/dev/null; RC=$?
  EL_NS=$(( $(date +%s%N) - t0 )); HOOK_PG=""
  OUT=$(cat "$out")
}

echo "# case 6: busy - another connection holds an EXCLUSIVE transaction for longer than the budget"
# The real defaults (20 s soft + 3 s hard; sqlite busy timeout 10 s). The holder sleeps 60 s, past the
# 25 s budget the static check pins. The hook must give up cleanly (result=busy, no DELETE switch),
# exit 0 and return INSIDE the budget. The 40 s harness cap only exists for the mutation runs.
rm -f "$DB" "$DB-wal" "$DB-shm" "$SB/locked-x"
mkwal "$DB"
"$PY" - "$DB" "$SB/locked-x" <<'EOF' &
import sqlite3, sys, time
con = sqlite3.connect(sys.argv[1], isolation_level=None)
con.execute("BEGIN EXCLUSIVE"); con.execute("INSERT INTO t VALUES ('held')")
open(sys.argv[2], "w").close()
time.sleep(60)
EOF
HOLDER=$!
for _ in $(seq 50); do [ -e "$SB/locked-x" ] && break; sleep 0.1; done
expect "precondition: EXCLUSIVE holder is up" test -e "$SB/locked-x"
run_hook_capped 40 env
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""
EL_MS=$(( EL_NS / 1000000 ))
echo "#   output: $OUT (elapsed ${EL_MS} ms, capped=$CAPPED)"
expect "busy: exit 0 (not killed by the harness cap)" test "$RC" -eq 0 -a "$CAPPED" -eq 0
expect "busy: one line, result=busy"          result_is busy
expect "busy: returned within the budget (${EL_MS} ms < 25000 ms)" test "$EL_NS" -lt 25000000000
expect "busy: WAL left in place (no DELETE switch attempted)" test -s "$DB-wal"
expect "busy: DB intact"                      rows_ok "$DB"

[ "$FAILS" -eq 0 ]
