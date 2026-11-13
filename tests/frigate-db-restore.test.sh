#!/usr/bin/env bash
# Hermetic test of spike/bin/lib-db-restore.sh (M9 D24 b): frigate-run's downgrade restore moves the
# DB's -wal/-shm with it. Case 1 reproduces the 2026-11-13 rehearsal corruption on the host.
# Run: bash tests/frigate-db-restore.test.sh   (exit 0 = all ok)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
FAILS=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; FAILS=$((FAILS+1)); }
expect() { local n="$1"; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
PY=$(command -v python3) || { echo "FAIL - python3 missing"; exit 1; }
# shellcheck source=SCRIPTDIR/../spike/bin/lib-db-restore.sh
. spike/bin/lib-db-restore.sh

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
restore_fails() { ! db_restore "$@" 2>/dev/null; }
none_exist() { local f; for f in "$@"; do [ -e "$f" ] && return 1; done; return 0; }
no_aside() { ! compgen -G "$1.incompatible-*" >/dev/null; }
expect "lib defines db_restore" declare -F db_restore

# mkbackup <file>: a clean rollback-mode DB, table t, 50 rows tagged 'backup' (the 0.17.2 backup).
mkbackup() { "$PY" - "$1" <<'EOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE t (tag TEXT, pad TEXT)")
con.executemany("INSERT INTO t VALUES ('backup', ?)", [("b" * 50,)] * 50)
con.commit(); con.close()
EOF
}
# mklive <file>: an unrelated WAL-mode DB with a different schema history, whose writer died
# without closing (os._exit): a multi-MB -wal and a -shm stay behind (the migrated 0.18 DB).
mklive() { "$PY" - "$1" <<'EOF'
import os, sqlite3, sys
con = sqlite3.connect(sys.argv[1], isolation_level=None)
con.execute("PRAGMA journal_mode=WAL"); con.execute("PRAGMA wal_autocheckpoint=0")
con.execute("CREATE TABLE other (a INTEGER PRIMARY KEY, b TEXT)")
con.execute("CREATE TABLE t (tag TEXT, pad TEXT)")
con.execute("BEGIN")
con.executemany("INSERT INTO other (b) VALUES (?)", [("x" * 200,)] * 20000)
con.executemany("INSERT INTO t VALUES ('live', ?)", [("l" * 50,)] * 70)
con.execute("CREATE INDEX i_other ON other (b)")
con.execute("COMMIT")
os._exit(0)
EOF
}
# state <db>: "<integrity_check> <tag>:<count>" for table t, or "error:<class>"
state() { "$PY" - "$1" <<'EOF'
import sqlite3, sys
try:
    c = sqlite3.connect(sys.argv[1])
    ic = c.execute("PRAGMA integrity_check").fetchone()[0]
    rows = c.execute("SELECT tag, COUNT(*) FROM t GROUP BY tag").fetchall()
    print(ic, " ".join("%s:%d" % r for r in rows))
except Exception as e:
    print("error:" + type(e).__name__)
EOF
}

echo "# case 1: restore over a live DB with a stale WAL (the rehearsal bug)"
D="$SB/c1"; mkdir -p "$D"; DB="$D/frigate.db"
mkbackup "$D/backup.db"; mklive "$DB"
expect "precondition: live -wal is non-empty" test -s "$DB-wal"
expect "precondition: live -shm exists"       test -e "$DB-shm"
expect "db_restore returns 0"                 db_restore "$DB" "$D/backup.db" 123
expect "no -wal left beside the restored DB"  test ! -e "$DB-wal"
expect "no -shm left beside the restored DB"  test ! -e "$DB-shm"
expect "restored DB: integrity ok, exactly the backup's rows" test "$(state "$DB")" = "ok backup:50"
expect "restored DB: the live-only table 'other' is absent" test "$("$PY" -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT COUNT(*) FROM sqlite_master WHERE name=?", ("other",)).fetchone()[0])' "$DB")" = 0
expect "live -wal preserved beside the aside copy" test -s "$DB.incompatible-123-wal"
expect "aside copy still opens with its own WAL"   test "$(state "$DB.incompatible-123")" = "ok live:70"

echo "# case 2: the copy fails -> all three files move back"
D="$SB/c2"; mkdir -p "$D"; DB="$D/frigate.db"
mklive "$DB"; W=$(stat -c %s "$DB-wal")
expect "db_restore returns 1 on a failed copy" restore_fails "$DB" "$D/missing.db" 456
expect "DB moved back"                         test -s "$DB"
expect "-wal moved back (same size)"           test "$(stat -c %s "$DB-wal" 2>/dev/null)" = "$W"
expect "-shm moved back"                       test -e "$DB-shm"
expect "no aside files left"                   no_aside "$DB"
expect "live DB intact (its own WAL replays)"  test "$(state "$DB")" = "ok live:70"

echo "# case 3: a clean DB (D24 a already ran) -> no stray sidecars"
D="$SB/c3"; mkdir -p "$D"; DB="$D/frigate.db"
mkbackup "$D/backup.db"; mkbackup "$DB"
expect "db_restore returns 0"                  db_restore "$DB" "$D/backup.db" 789
expect "no -wal/-shm created on either side"   none_exist "$DB-wal" "$DB-shm" "$DB.incompatible-789-wal" "$DB.incompatible-789-shm"
expect "aside copy kept"                       test -s "$DB.incompatible-789"

[ "$FAILS" -eq 0 ]
