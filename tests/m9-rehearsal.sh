#!/usr/bin/env bash
# M9 rehearsal (W-14 spec §5 items 2-4, 6, 7, 7a, 8): the 0.17.2 baseline -> 0.18.2 candidate ->
# revert -> re-refresh; retention across two 0.18 refreshes (D21); 0.17.2 on a migrated DB (finding).
# GATE VM ONLY. DESTRUCTIVE: purges + reinstalls the frigate snap. Test streams only (cameras down, D15).
# The baseline is any 0.17.2 .snap (Store rev 4 or rev 5; R7). The candidate may be a LOCAL unsigned
# build: everything here installs with --dangerous and nothing assumes a Store-signed artifact.
# Usage: sudo M9_GATE_VM="$(cat /etc/hostname)" [M9_BASELINE_NOTE='...'] \
#          bash tests/m9-rehearsal.sh <rev5.snap: baseline 0.17.2 .snap> <candidate.snap>
# Evidence: spike/results/m9-rehearsal/ (row counts, config sha256s, findings.txt; never config
# contents, tokens or cookies). Exit 0 iff every check passed; finding lines never fail the run.
set -uo pipefail
USAGE="usage: sudo M9_GATE_VM=\"\$(cat /etc/hostname)\" bash tests/m9-rehearsal.sh <rev5.snap: baseline 0.17.2 .snap> <candidate.snap>"
[ "$#" -eq 2 ] || { echo "$USAGE"; exit 2; }
abspath() { case $1 in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BASE017=$(abspath "$1"); CAND=$(abspath "$2")   # resolved before the cd below
# Both guards run before anything that changes the system: root first, then the gate-VM identity.
if [ "$(id -u)" -ne 0 ]; then echo "run as root"; exit 2; fi
if [ -z "${M9_GATE_VM:-}" ] || [ "$(cat /etc/hostname 2>/dev/null)" != "$M9_GATE_VM" ]; then
  echo "refusing: gate VM only (M9_GATE_VM must equal /etc/hostname)"; exit 2
fi
cd "$(dirname "$0")/.." || exit 2
{ [ -f "$BASE017" ] && [ -f "$CAND" ]; } || { echo "missing .snap file"; exit 2; }
# snap_file_is <file> <version>: the packed meta/snap.yaml carries `version: 0.17.2` UNQUOTED (the
# quoted form is accepted too); `snap info <file>` prints `version:    0.17.2 -` when unsquashfs is absent.
snap_file_is() {
  local v=${2//./\\.}
  if command -v unsquashfs >/dev/null 2>&1; then
    unsquashfs -cat "$1" meta/snap.yaml 2>/dev/null | grep -xE "version: '?${v}'?" >/dev/null
  else
    snap info "$1" 2>/dev/null | grep -E "^version:[[:space:]]+${v}([[:space:]]|\$)" >/dev/null
  fi
}
snap_file_is "$BASE017" 0.17.2 || { echo "baseline .snap is not version 0.17.2"; exit 2; }
snap_file_is "$CAND" 0.18.2 || { echo "candidate .snap is not version 0.18.2"; exit 2; }

S=frigate
CFG=/var/snap/$S/current/config/config.yml          # 'current' follows the active revision
CFGDIR=/var/snap/$S/current/config
COMMON=/var/snap/$S/common; DB=$COMMON/db/frigate.db; BK=$COMMON/db/backups
RECS=$COMMON/media/frigate/recordings
EV=spike/results/m9-rehearsal; mkdir -p "$EV"; : > "$EV/findings.txt"
FAIL=0
pass_() { echo "PASS: $1"; }; fail_() { echo "FAIL: $1"; FAIL=1; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass_ "$d"; else fail_ "$d"; fi; }
finding() { echo "FINDING: $1"; echo "$1" >> "$EV/findings.txt"; }
[ -n "${M9_BASELINE_NOTE:-}" ] && finding "baseline: $M9_BASELINE_NOTE"
mark() { date '+%Y-%m-%d %H:%M:%S'; }
H=(-H 'Remote-User: admin' -H 'Remote-Role: admin')
api()  { curl -sf --max-time 15 "${H[@]}" "http://127.0.0.1:5001$1"; }
apix() { local body=${3:-'{}'}; curl -sf --max-time 30 "${H[@]}" -H 'Content-Type: application/json' -X "$1" -d "$body" "http://127.0.0.1:5001$2"; }
wait_api() { local t=0; until api /version >/dev/null 2>&1; do sleep 3; t=$((t+3)); [ "$t" -ge "${1:-300}" ] && return 1; done; }
py() { "/snap/$S/current/usr/bin/python3.11" "$@"; }
sql() {  # sql <query> [db]: rows as a|b|c, NULL as empty
  py - "${2:-$DB}" "$1" <<'EOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
for row in con.execute(sys.argv[2]):
    print("|".join("" if v is None else str(v) for v in row))
con.commit()
EOF
}
jcount() { journalctl -u "snap.$S.frigate.service" --since "$1" 2>/dev/null; }
# Every grep in a pipeline here DRAINS its input (no -q): under pipefail, grep -q exits on the first
# match, the writer dies of SIGPIPE (141) on output larger than a pipe buffer, and a present line would
# read as absent.
jhas() { jcount "$1" | grep -F -- "$2" >/dev/null; }
jhas_re() { jcount "$1" | grep -iE -- "$2" >/dev/null; }
# jabsent <since> <control> <label> <ERE>: PASS iff <ERE> is absent from the frigate journal since <since>,
# but only once the fixed line <control> is present in the same window. Absence in an empty or unreadable
# journal would otherwise pass vacuously.
jabsent() {
  if ! jhas "$1" "$2"; then fail_ "$3: journal empty/unreadable (no '$2' since $1)"; return; fi
  if jhas_re "$1" "$4"; then fail_ "$3"; else pass_ "$3"; fi
}
# Positive control for any window that contains a frigate start: frigate-run prints this line
# unconditionally before exec'ing Frigate, in the baseline (a39bfb0 spike/bin/frigate-run:99) and in the
# candidate (spike/bin/frigate-run:102), so it is version-independent.
START_CONTROL='frigate-run: go2rtc gate waited_ms='
# 0.18.2 swallows a vec0 load failure (db/sqlitevecq.py:38-42, logger.error). 0.17.2 has no such line:
# it raises at connect (db/sqlitevecq.py:24-27), so a 0.17.2 start that reaches the API loaded vec0.
assert_vec0_loaded() { jabsent "$1" "$START_CONTROL" "vec0 loaded ($2)" 'Unable to load the sqlite-vec extension'; }
version_is() { api /version | grep "^${1//./\\.}-" >/dev/null; }
install_snap() {  # install_snap <file> <label>: install or refresh (a refresh runs pre-refresh), connect, wait, vec0
  local m; m=$(mark)
  snap install --dangerous "$1" >/dev/null || { fail_ "snap install ($2)"; return 1; }
  snap connect "$S:gpu-2604" mesa-2604:gpu-2604 2>/dev/null || true
  snap connect "$S:mount-observe" 2>/dev/null || true
  snap start "$S.frigate" >/dev/null 2>&1 || true   # phase A leaves frigate stopped into the refresh
  wait_api 300 || { fail_ "API up after install ($2)"; return 1; }
  if version_is 0.18.2; then assert_vec0_loaded "$m" "$2"; fi
}
REVERT_MARK=""; REVERT_T=0
rev_present() { snap list --all "$S" 2>/dev/null | awk -v s="$S" '$1==s{print $3}' | grep -xF -- "$1" >/dev/null; }
revert_to() {  # revert_to <revision> <label>
  local m; m=$(mark)
  rev_present "$1" || { fail_ "revision $1 still installed ($2)"; return 1; }
  REVERT_T=$(date +%s)
  snap revert "$S" --revision="$1" >/dev/null || { fail_ "snap revert to $1 ($2)"; return 1; }
  wait_api 300 || { fail_ "API up after revert ($2)"; return 1; }
  REVERT_MARK=$m
}
revert_probe() {  # revert_probe <revision> <label>: FINDING-ONLY revert for phase F; never calls fail_
  local m rc; m=$(mark); REVERT_T=$(date +%s); REVERT_MARK=$m
  if ! rev_present "$1"; then finding "$2: revision $1 no longer installed, revert not attempted"; return 1; fi
  snap revert "$S" --revision="$1" >/dev/null 2>&1; rc=$?
  finding "$2: snap revert rc=$rc"
  local up=no; if [ "$rc" -eq 0 ] && wait_api 300; then up=yes; fi
  finding "$2: API up within 300 s: $up"
  if jhas "$m" 'frigate-run: DOWNGRADE detected'; then finding "$2: 'frigate-run: DOWNGRADE detected' logged"
  else finding "$2: 'frigate-run: DOWNGRADE detected' NOT logged"; fi
  if jhas "$m" 'no backup available'; then finding "$2: downgrade path took the no-backup branch (expected)"
  else finding "$2: no-backup branch line NOT logged (see journal since $m)"; fi
  [ "$up" = yes ]
}
rev_of() { snap list "$S" | awk -v s="$S" '$1==s{print $3}'; }
snapshot() {  # snapshot <tag>: row counts + config sha (contents never printed)
  for t in event recordings export; do echo "$t=$(sql "SELECT COUNT(*) FROM $t")"; done > "$EV/$1.counts"
  echo "recordings_live=$(sql "SELECT COUNT(*) FROM recordings WHERE camera='testclip' AND id!='m9-expired'")" >> "$EV/$1.counts"
  sha256sum "$CFG" | cut -d' ' -f1 > "$EV/$1.cfgsha"
}
count_of() { sed -n "s/^$2=//p" "$EV/$1.counts"; }
sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
# shellcheck disable=SC2317 # invoked only as an argument of check (indirect); shellcheck cannot see it
yaml_true() {  # yaml_true <python expr on cfg> [file]
  py - "${2:-$CFG}" "$1" <<'EOF'
import sys, yaml
with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)
sys.exit(0 if eval(sys.argv[2], {"cfg": cfg}) else 1)
EOF
}
hook_runs() { local n; n=$(grep -c 'pre-refresh: backed up' "$BK/hook.log" 2>/dev/null) || true; echo "${n:-0}"; }
jlen() { py -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
export_row() {  # export_row <id>: "<0|1 in_progress>|<thumb_path>" of that export, or nothing
  api /exports | py -c 'import json, sys
for e in json.load(sys.stdin):
    if e["id"] == sys.argv[1]:
        print(("1" if e["in_progress"] else "0") + "|" + (e["thumb_path"] or "")); break' "$1"
}
wait_export() {  # wait_export <id> <secs>: 0 once the export row exists and is finished; prints thumb_path
  local t=0 r
  while [ "$t" -lt "$2" ]; do
    r=$(export_row "$1" 2>/dev/null)
    case $r in 0\|*) echo "${r#0|}"; return 0 ;; esac
    sleep 5; t=$((t+5))
  done
  return 1
}
testclip_capturing() { api /stats | py -c 'import json,sys; sys.exit(0 if (json.load(sys.stdin)["cameras"]["testclip"]["ffmpeg_pid"] or 0) > 0 else 1)'; }

# EXIT trap: put phase F's held backups back and restore the VM's refresh.retain.
HOLD=""; RETAIN_OLD=""; RETAIN_SET=""
restore_hold() {  # move phase F's held backups back; clears HOLD only once nothing is left to move
  [ -n "$HOLD" ] || return 0
  if [ -d "$HOLD" ]; then
    local f; for f in "$HOLD"/*; do [ -e "$f" ] || continue; mv -f -- "$f" "$BK"/ || return 1; done
    rmdir "$HOLD" 2>/dev/null || return 1
  fi
  HOLD=""
}
# shellcheck disable=SC2317 # invoked by the EXIT trap (indirect)
cleanup() {
  restore_hold || echo "WARNING: phase F backups still held in $HOLD; move them back to $BK"
  if [ -n "$RETAIN_SET" ]; then
    if [ -n "$RETAIN_OLD" ]; then snap set system refresh.retain="$RETAIN_OLD"; else snap unset system refresh.retain; fi
  fi
}
trap cleanup EXIT

# The purge would destroy the VM's livecam secret and its config.yml, which the gate (tests/spike-smoke.sh)
# treats as the operator's config. Park both in the gate's own recovery stashes. They are restored ONLY by
# the next full-install, non --nvr-safe gate run (spike-smoke.sh: the RECOVER block and the post-install
# /var/tmp operator-config restore are both NVR_SAFE-gated and install-path only), which is what the
# controller runs next. Refuse before the purge if a stash from an aborted run is already parked.
park_vm_state() {
  local lc=$COMMON/livecam-url ls_=/var/tmp/frigate-livecam-url.stash cs=/var/tmp/frigate-operator-config.stash
  if [ -f "$lc" ]; then
    [ -e "$ls_" ] && { fail_ "A: $ls_ already parked by an earlier run; reconcile it first"; return 1; }
    { install -m 0600 -o root -g root "$lc" "$ls_" && cmp -s "$lc" "$ls_"; } || { fail_ "A: park livecam-url"; return 1; }
    finding "A: livecam-url parked in $ls_ (the gate recovers it)"
  fi
  if [ -s "$CFG" ]; then
    [ -e "$cs" ] && { fail_ "A: $cs already parked by an earlier run; reconcile it first"; return 1; }
    { install -m 0600 -o root -g root "$CFG" "$cs" && cmp -s "$CFG" "$cs"; } || { fail_ "A: park config.yml"; return 1; }
    finding "A: pre-rehearsal config.yml parked in $cs (the gate restores it)"
  fi
}

phase_a_seed_on_baseline() {
  echo "== A: seed on the 0.17.2 baseline =="
  park_vm_state || return 1
  # snapd keeps 2 revisions on classic (overlord/snapstate/snap.go refreshRetain); this run installs the
  # candidate 5 times and must still be able to revert to the baseline revision.
  RETAIN_OLD=$(snap get system refresh.retain 2>/dev/null) || RETAIN_OLD=""
  snap set system refresh.retain=10 || { fail_ "A: snap set system refresh.retain=10"; return 1; }
  RETAIN_SET=1
  snap remove --purge "$S" >/dev/null 2>&1 || true
  rm -rf "/tmp/snap-private-tmp/snap.$S/tmp/cache" 2>/dev/null || true   # stale cache (gate precedent)
  snap install mesa-2604 >/dev/null 2>&1 || true
  A_T0=$(date +%s)
  install_snap "$BASE017" "A baseline fresh" || return 1
  REV_A=$(rev_of)
  check "A: running 0.17.2" version_is 0.17.2
  version_is 0.17.2 || return 1
  check "A: config.yml is 0600 (backup_config.yaml copies its mode)" test "$(stat -c %a "$CFG")" = 600
  # Review Focus 1: legacy list-form motion mask + a zone on testclip (0.17 shapes); semantic search so
  # vec0 0.1.3 writes the vec tables (item 7); continuous retention pinned to 1 day (item 8).
  py - "$CFG" <<'EOF' || { fail_ "A: config edit"; return 1; }
import sys, yaml
p = sys.argv[1]
with open(p) as f:
    cfg = yaml.safe_load(f)
cam = cfg["cameras"]["testclip"]
cam.setdefault("motion", {})["mask"] = ["0,0,100,0,100,100,0,100"]
cam["zones"] = {"m9zone": {"coordinates": "0,0,200,0,200,200,0,200"}}
cfg.setdefault("semantic_search", {})["enabled"] = True
rec = cfg.setdefault("record", {})
rec["enabled"] = True
rec.setdefault("continuous", {})["days"] = 1
if isinstance(cam.get("record"), dict) and isinstance(cam["record"].get("continuous"), dict):
    cam["record"]["continuous"].pop("days", None)
with open(p, "w") as f:  # existing file: open("w") keeps its 0600 mode
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
EOF
  snap restart "$S.frigate" >/dev/null; wait_api 300 || { fail_ "A: API after config edit"; return 1; }
  check "A: 0.17.2 up with semantic_search (vec0 0.1.3 loaded at connect)" version_is 0.17.2
  sleep 600                                  # 10 min: recordings + events on the test clip
  local now resp; now=$(date +%s)
  resp=$(apix POST "/export/testclip/start/$((now-300))/end/$((now-240))") || resp=""
  A_EXPORT_ID=$(printf '%s' "$resp" | py -c 'import json,sys; print(json.load(sys.stdin).get("export_id") or "")' 2>/dev/null) || A_EXPORT_ID=""
  check "A: export started on 0.17.2" test -n "$A_EXPORT_ID"
  check "A: export finished on 0.17.2" wait_export "$A_EXPORT_ID" 300
  check "A: events seeded" test "$(sql "SELECT COUNT(*) FROM event WHERE camera='testclip'")" -gt 0
  check "A: recordings seeded" test "$(sql "SELECT COUNT(*) FROM recordings WHERE camera='testclip'")" -gt 0
  check "A: vec_thumbnails written by vec0 0.1.3" test "$(sql "SELECT COUNT(*) FROM sqlite_master WHERE name='vec_thumbnails'")" = 1
  finding "A: vec_thumbnails_info present on 0.17.2 = $(sql "SELECT COUNT(*) FROM sqlite_master WHERE name='vec_thumbnails_info'") (0 = legacy pre-0.1.6 layout)"
  check "A: testclip retention continuous.days = 1" yaml_true 'cfg["record"]["continuous"]["days"] == 1 and "days" not in (cfg["cameras"]["testclip"].get("record") or {}).get("continuous", {})'
  # Expired continuous recording (2 days > continuous.days 1) for the retention check (item 8). Frigate
  # stays STOPPED from here into the refresh: 0.17.2's own cleanup would delete the row ~60 s after any
  # start (record/cleanup.py run(): wait(60), counter 0) and B would then prove nothing.
  snap stop "$S.frigate" >/dev/null || { fail_ "A: stop frigate"; return 1; }
  local old; old=$(( $(date +%s) - 2*86400 )); EXPIRED_F="$RECS/m9-expired/testclip/m9.mp4"
  mkdir -p "$(dirname "$EXPIRED_F")"; head -c 1024 /dev/urandom > "$EXPIRED_F"
  sql "INSERT INTO recordings (id, camera, path, start_time, end_time, duration, motion, objects, dBFS, segment_size) VALUES ('m9-expired','testclip','$EXPIRED_F',$old,$((old+10)),10,0,0,0,0)"
  check "A: expired row seeded" test "$(sql "SELECT COUNT(*) FROM recordings WHERE id='m9-expired'")" = 1
  snapshot A; A_T1=$(date +%s); HOOK_A=$(hook_runs)
}

phase_b_refresh_to_candidate() {
  echo "== B: refresh to candidate =="
  local tb; tb=$(date +%s)
  install_snap "$CAND" "B refresh" || return 1
  REV_B=$(rev_of); finding "B: candidate installed as revision $REV_B (the 0.17.2 baseline is $REV_A)"
  check "B: running 0.18.2" version_is 0.18.2
  check "B: pre-refresh wrote frigate-pre-0.17.2-r$REV_A.db" test -s "$BK/frigate-pre-0.17.2-r$REV_A.db"
  check "B: hook.log gained one 'pre-refresh: backed up' line" test "$(hook_runs)" -eq $((HOOK_A+1))
  check "B: frigate wrote backup.db during this boot" test "$(stat -c %Y "$COMMON/db/backup.db" 2>/dev/null || echo 0)" -ge "$tb"
  check "B: backup.db is the pre-migration DB (032 applied, 033 not)" test "$(sql "SELECT SUM(name='032_add_password_changed_at'), SUM(name='033_create_export_case_table') FROM migratehistory" "$COMMON/db/backup.db")" = "1|0"
  for mig in 033_create_export_case_table 034_add_export_case_to_exports 035_add_motion_heatmap; do
    check "B: migration $mig applied" test "$(sql "SELECT COUNT(*) FROM migratehistory WHERE name='$mig'")" = 1
  done
  check "B: exportcase table" test "$(sql "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='exportcase'")" = 1
  check "B: export.export_case_id column" test -n "$(sql "SELECT name FROM pragma_table_info('export') WHERE name='export_case_id'")"
  check "B: recordings.motion_heatmap column" test -n "$(sql "SELECT name FROM pragma_table_info('recordings') WHERE name='motion_heatmap'")"
  check "B: config migrated to 0.18-0" yaml_true 'str(cfg.get("version")) == "0.18-0"'
  check "B: legacy mask migrated to dict form" yaml_true 'cfg["cameras"]["testclip"]["motion"]["mask"]["motion_mask_1"]["coordinates"] == "0,0,100,0,100,100,0,100"'
  check "B: zone survived migration (dict, coordinates kept)" yaml_true 'cfg["cameras"]["testclip"]["zones"]["m9zone"]["coordinates"] == "0,0,200,0,200,200,0,200"'
  check "B: backup_config.yaml == pre-refresh config" test "$(sha_of "$CFGDIR/backup_config.yaml")" = "$(cat "$EV/A.cfgsha")"
  check "B: backup_config.yaml is 0600" test "$(stat -c %a "$CFGDIR/backup_config.yaml")" = 600
  check "B: validate-config exits 0" snap run "$S.validate-config"
  check "B: events not lost (DB)" test "$(sql 'SELECT COUNT(*) FROM event')" -ge "$(count_of A event)"
  check "B: exports not lost (DB)" test "$(sql 'SELECT COUNT(*) FROM export')" -ge "$(count_of A export)"
  check "B: API lists the pre-existing events" test "$(api "/events?limit=100000&before=$A_T1" | jlen)" -ge "$(count_of A event)"
  check "B: API lists the pre-existing recordings" test "$(api "/testclip/recordings?after=$A_T0&before=$A_T1" | jlen)" -ge "$(count_of A recordings_live)"
  check "B: API lists the pre-existing export" test -n "$(export_row "$A_EXPORT_ID")"
  # item 8: cleanup's first pass runs ~60 s after start (record/cleanup.py run(): wait(60), counter 0)
  local t=0; while [ "$t" -lt 180 ] && [ "$(sql "SELECT COUNT(*) FROM recordings WHERE id='m9-expired'")" != 0 ]; do sleep 10; t=$((t+10)); done
  check "B: retention deleted the expired row" test "$(sql "SELECT COUNT(*) FROM recordings WHERE id='m9-expired'")" = 0
  check "B: retention deleted the expired file" test ! -e "$EXPIRED_F"
  # item 7: vec0 0.1.9 drops + recreates the vec tables 0.1.3 wrote (embeddings.py _reindex)
  local rm_; rm_=$(mark)
  check "B: PUT /reindex accepted" apix PUT /reindex
  t=0; while [ "$t" -lt 600 ]; do
    jhas_re "$rm_" 'Embedded [0-9]+ thumbnails and [0-9]+ descriptions|Unable to reindex tracked object embeddings' && break
    sleep 10; t=$((t+10)); done
  check "B: reindex started" jhas "$rm_" 'Indexing tracked object embeddings'
  # no frigate start in this window: its positive control is the reindex's own start line (embeddings.py:321)
  jabsent "$rm_" 'Indexing tracked object embeddings' "B: reindex logged no sqlite/vec error" 'unable to reindex|sqlite.*error|vec0|no such module: vec'
  if jhas_re "$rm_" 'Embedded [0-9]+ thumbnails and [0-9]+ descriptions'; then pass_ "B: reindex completed"
  else finding "B: reindex completion line not seen within 600 s (the embedding model download is network-gated)"; fi
  phase_b_export_thumbnail
}

# thumb_window <preview start> <preview end> <now>: prints "<ws> <we>" = [end-120, end-60] iff that window
# lies inside the preview (ws >= start) AND ends before the current UTC hour boundary (we < floor_hour(now)).
# save_thumbnail takes the 8.0 branch only when the export starts before that boundary
# (record/export.py:593-597, datetime.now(UTC).replace(minute=0, ...)); epoch hours are UTC hours.
thumb_window() {
  local ps=${1%%.*} pe=${2%%.*} now=${3%%.*} hour ws we
  hour=$(( now / 3600 * 3600 )); ws=$(( pe - 120 )); we=$(( pe - 60 ))
  [ "$ws" -ge "$ps" ] && [ "$we" -lt "$hour" ] || return 1
  echo "$ws $we"
}
phase_b_export_thumbnail() {  # item 6: the REAL 8.0 thumbnail branch (record/export.py save_thumbnail)
  # The 8.0 branch needs an export starting before the current hour boundary inside a finalized preview
  # mp4 (Previews row). Wait (bounded, 75 min) until some testclip preview yields such a window.
  local t=0 row win=""
  while :; do
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      win=$(thumb_window "${row%%|*}" "${row#*|}" "$(date +%s)") && break
      win=""
    done < <(sql "SELECT start_time,end_time FROM previews WHERE camera='testclip' ORDER BY end_time DESC LIMIT 20")
    [ -n "$win" ] && break
    [ "$t" -ge 4500 ] && { fail_ "B: no finalized preview mp4 with a pre-hour window within 75 min (cannot exercise the 8.0 thumbnail)"; return; }
    sleep 60; t=$((t+60))
  done
  local ws=${win% *} we=${win#* } hour=$(( $(date +%s) / 3600 * 3600 ))
  if [ "$we" -ge "$hour" ]; then fail_ "B: export window [$ws,$we] is not before the hour boundary $hour (8.0 branch not provable)"; return; fi
  apix POST "/export/testclip/start/$ws/end/$we" '{}' > "$EV/B.export.json" || fail_ "B: export request"
  local id thumb=""
  id=$(py -c 'import json,sys; print(json.load(open(sys.argv[1])).get("export_id") or "")' "$EV/B.export.json" 2>/dev/null) || id=""
  [ -n "$id" ] && thumb=$(wait_export "$id" 300)
  check "B: export thumbnail (.webp via /usr/lib/ffmpeg/8.0) exists and is non-empty" test -s "$thumb"
  check "B: export thumbnail is a WebP file" test "$(head -c 12 "$thumb" 2>/dev/null | tail -c 4)" = WEBP
}

phase_c_revert() {
  echo "== C: revert to the 0.17.2 baseline =="
  local h0; h0=$(hook_runs)
  revert_to "$REV_A" "C revert" || return 1
  check "C: running 0.17.2" version_is 0.17.2
  check "C: frigate-run detected the downgrade" jhas "$REVERT_MARK" 'frigate-run: DOWNGRADE detected'
  check "C: restored the 0.17.2 backup" jhas "$REVERT_MARK" "frigate-run: restored $BK/frigate-pre-0.17.2-r$REV_A.db"
  check "C: restored DB carries no 0.18 migration" test "$(sql "SELECT COUNT(*) FROM migratehistory WHERE name GLOB '03[345]_*'")" = 0
  check "C: config.yml is the pre-refresh file (snapd per-revision data)" test "$(sha_of "$CFG")" = "$(cat "$EV/A.cfgsha")"
  check "C: config.yml is the 0.17-0 file" yaml_true 'str(cfg.get("version")) == "0.17-0"'
  local t=0; while [ "$t" -lt 600 ]; do testclip_capturing && break; sleep 15; t=$((t+15)); done
  check "C: 0.17.2 captures testclip after revert" testclip_capturing
  local n0; n0=$(sql "SELECT COUNT(*) FROM recordings WHERE camera='testclip'"); sleep 120
  check "C: 0.17.2 writes new recordings after revert" test "$(sql "SELECT COUNT(*) FROM recordings WHERE camera='testclip'")" -gt "$n0"
  t=0; while [ "$t" -lt 600 ] && [ "$(sql "SELECT COUNT(*) FROM event WHERE camera='testclip' AND start_time > $REVERT_T")" = 0 ]; do sleep 15; t=$((t+15)); done
  check "C: 0.17.2 detects on testclip after revert (new event)" test "$(sql "SELECT COUNT(*) FROM event WHERE camera='testclip' AND start_time > $REVERT_T")" -gt 0
  finding "C: hook.log 'backed up' lines across the revert: $h0 -> $(hook_runs) (unchanged = snapd ran no pre-refresh on revert)"
}

phase_d_rerefresh() {
  echo "== D: re-refresh to candidate =="
  local td; td=$(date +%s)
  install_snap "$CAND" "D re-refresh" || return 1
  check "D: running 0.18.2" version_is 0.18.2
  check "D: migration re-ran on the restored DB (fresh backup.db)" test "$(stat -c %Y "$COMMON/db/backup.db" 2>/dev/null || echo 0)" -ge "$td"
  check "D: config migrated to 0.18-0 again" yaml_true 'str(cfg.get("version")) == "0.18-0"'
  check "D: backup_config.yaml == pre-refresh config" test "$(sha_of "$CFGDIR/backup_config.yaml")" = "$(cat "$EV/A.cfgsha")"
  check "D: migrations 033-035 present" test "$(sql "SELECT COUNT(*) FROM migratehistory WHERE name IN ('033_create_export_case_table','034_add_export_case_to_exports','035_add_motion_heatmap')")" = 3
  check "D: exportcase table" test "$(sql "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='exportcase'")" = 1
}

phase_e_retention_d21() {
  echo "== E: two more 0.18 refreshes keep the 0.17.2 downgrade target (D21) =="
  install_snap "$CAND" "E refresh 1" || return 1
  install_snap "$CAND" "E refresh 2" || return 1
  check "E: a 0.17.2 backup survives two 0.18 refreshes" test -s "$BK/frigate-pre-0.17.2-r$REV_A.db"
  check "E: at most 3 backups" test "$(find "$BK" -maxdepth 1 -name 'frigate-pre-*.db' | wc -l)" -le 3
  revert_to "$REV_A" "E revert to the baseline" || return 1
  check "E: revert across the boundary restored the 0.17.2 backup" jhas "$REVERT_MARK" "frigate-run: restored $BK/frigate-pre-0.17.2-r$REV_A.db"
  check "E: running 0.17.2" version_is 0.17.2
  install_snap "$CAND" "E back to candidate" || return 1
}

phase_f_v017_on_migrated_db() {  # FINDING ONLY (D21 removes the dependency); research Addendum 6
  echo "== F: 0.17.2 directly on a 0.18-migrated DB (finding) =="
  # Everything up to the reinstall is FINDING-ONLY (spec 7a): a 0.17.2 that cannot serve on the migrated
  # DB is the thing being probed, so it never turns the run red and never skips the reinstall below.
  HOLD=$COMMON/db/m9-hold; mkdir -p "$HOLD"; mv "$BK"/frigate-pre-*.db "$HOLD"/ 2>/dev/null || true
  if revert_probe "$REV_A" "F revert, no backups"; then
    local n0; n0=$(sql "SELECT COUNT(*) FROM recordings" 2>/dev/null); sleep 300
    if api /events >/dev/null && [ "$(sql 'SELECT COUNT(*) FROM recordings' 2>/dev/null)" -gt "${n0:-0}" ]; then
      finding "F: 0.17.2 ran on the 0.18-migrated DB: /events OK, new recordings written"
    else
      finding "F: 0.17.2 on the 0.18-migrated DB did NOT run cleanly (see journal since $REVERT_MARK)"
    fi
  else
    finding "F: 0.17.2 did not come up on the 0.18-migrated DB (see journal since $REVERT_MARK)"
  fi
  # GATING from here: the VM must end on the candidate with its backups back.
  install_snap "$CAND" "F back to candidate"
  # after the install: the baseline's pre-refresh just stamped the migrated DB as 0.17.2; the held
  # genuine 0.17.2 backup replaces it. HOLD stays set (for the EXIT trap to retry) unless this succeeds.
  restore_hold || fail_ "F: put the held backups back (still in $HOLD)"
  check "F: candidate healthy after the finding phase" version_is 0.18.2
}

if phase_a_seed_on_baseline && phase_b_refresh_to_candidate; then
  phase_c_revert; phase_d_rerefresh; phase_e_retention_d21; phase_f_v017_on_migrated_db
else
  fail_ "phase A or B aborted: C-F not run"
fi
echo "== m9 rehearsal: $( [ "$FAIL" -eq 0 ] && echo ALL PASS || echo FAILURES ) =="; cat "$EV/findings.txt"
exit "$FAIL"
