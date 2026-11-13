# shellcheck shell=bash
# M9 D24 (b): the downgrade-restore step of frigate-run, sourced so it can be tested hermetically.
# db_restore <db> <backup> <ts>: move <db> and its -wal/-shm aside as <db>.incompatible-<ts>{,-wal,-shm}
# (SQLite pairs a DB with "<name>-wal", so the preserved copy stays openable), then copy <backup> in.
# A -wal/-shm left beside the restored file would be replayed onto it (rehearsal 2026-11-13).
# Returns 0 when restored; 1 when the copy failed, after moving all three files back.
# Its variables are `local`: frigate-run's backup-pick loop uses `_bk` too (review minor 5).
db_restore() {
    local _db="$1" _bk="$2" _aside="$1.incompatible-$3" _sfx
    for _sfx in "" -wal -shm; do
        if [ -e "$_db$_sfx" ]; then mv "$_db$_sfx" "$_aside$_sfx" || true; fi
    done
    if cp "$_bk" "$_db"; then return 0; fi
    rm -f "$_db"
    for _sfx in "" -wal -shm; do
        if [ -e "$_aside$_sfx" ]; then mv "$_aside$_sfx" "$_db$_sfx" || true; fi
    done
    return 1
}
