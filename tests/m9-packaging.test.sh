#!/usr/bin/env bash
# M9 static packaging assertions (hermetic except upstream_dir, which shallow-clones the tag).
# Run: bash tests/m9-packaging.test.sh   (exit 0 = all ok)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
FAILS=0
t() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok   - $n"; else echo "FAIL - $n"; FAILS=$((FAILS+1)); fi; }
TAG="v$(sed -n "s/^version: '\(.*\)'$/\1/p" snap/snapcraft.yaml)"
_UP=""
# Temp dir + trap live at top level so the clone survives $(upstream_dir) subshells.
if [ -z "${M9_UPSTREAM_DIR:-}" ]; then _UP=$(mktemp -d); trap 'rm -rf "$_UP"' EXIT; fi
upstream_dir() {
  if [ -n "${M9_UPSTREAM_DIR:-}" ]; then echo "$M9_UPSTREAM_DIR"; return; fi
  [ -d "$_UP/f/.git" ] || git clone -q --depth 1 --branch "$TAG" https://github.com/blakeblackshear/frigate.git "$_UP/f"
  echo "$_UP/f"
}

# --- S1 version ---
t "S1: snap version is 0.18.2"            grep -qx "version: '0.18.2'" snap/snapcraft.yaml
t "S1: both source-tags equal \$TAG"       sh -c "[ \$(grep -c 'source-tag: $TAG\$' snap/snapcraft.yaml) -eq 2 ] && ! grep -q 'source-tag: v0\.17' snap/snapcraft.yaml"
t "S1: version.py stamp uses 0.18.2"      grep -q 'VERSION = \\"0.18.2-' snap/snapcraft.yaml
t "S1: template config version 0.18-0"    grep -qx 'version: "0.18-0"' spike/config/frigate-config.yml
t "S1: web-ui deviation comment names e2e:build (D8)" grep -q 'e2e:build exists' snap/snapcraft.yaml

# --- S1 patch ---
P=spike/patches/0001-env-driven-paths.patch
t "S1: 0001 applies to \$TAG"             git -C "$(upstream_dir)" apply --check "$PWD/$P"
PLUS_WANT=$(mktemp); cat >"$PLUS_WANT" <<'EOF'
+BASE_DIR = os.environ.get("FRIGATE_BASE_DIR", "/media/frigate")
+BIRDSEYE_PIPE = f"{CACHE_DIR}/birdseye"
+CACHE_DIR = os.environ.get("FRIGATE_CACHE_DIR", "/tmp/cache")
+CONFIG_DIR = os.environ.get("FRIGATE_CONFIG_DIR", "/config")
EOF
plus_lines_match() { grep -E '^\+[A-Z_]+ = ' "$P" | sort | diff -q - "$PLUS_WANT"; }
t "S1: 0001 makes exactly the 3 substitutions (4 + lines)" plus_lines_match
t "S1: patches.md records the 0.18.2 rebase" grep -q 'rebased for v0.18.2' docs/patches.md

# --- S1 wheels ---
norm() { grep -hvE '^\s*(#|$)' "$@" | sed -E 's/\s+//g' | sort; }
UPM="$(upstream_dir)/docker/main"
VEC=$(sed -n 's/^SQLITE_VEC_VERSION="\(.*\)"/\1/p' "$UPM/build_sqlite_vec.sh")
wheels_match() {
  [ "$(diff <(norm spike/wheels-src/requirements-core.txt spike/wheels-src/DEFERRED-frigate-ai.txt) \
            <(norm "$UPM/requirements-wheels.txt") | grep '^[<>]')" = "< sqlite-vec==$VEC" ]
}
t "S1: snap wheel set == upstream wheels + sqlite-vec==\$VEC only" wheels_match
t "S1: DEFERRED header names \$TAG"        grep -q "VERBATIM from $TAG docker/main/requirements-wheels.txt" spike/wheels-src/DEFERRED-frigate-ai.txt
AXW=$(grep -oE 'https://[^ ]*axengine-[0-9.]+-py3-none-any\.whl' "$UPM/Dockerfile" | head -1)
t "S1: Dockerfile-only axengine wheel is deferred with rationale (D6)" bash -c "[ -n '$AXW' ] && grep -qF '# $AXW' spike/wheels-src/DEFERRED-frigate-ai.txt && grep -q 'axcl' spike/wheels-src/DEFERRED-frigate-ai.txt"

# --- S1 ffmpeg/go2rtc ---
# scoped to the top-level `parts:` block: `apps:` also has a `go2rtc:` key
part() { awk -v p="  $1:" '/^parts:/{inp=1;next} /^[a-z]/{inp=0} inp&&$0==p{f=1;print;next} f&&/^  [a-z0-9-]+:$/{exit} f' snap/snapcraft.yaml; }
export -f part
UPD="$(upstream_dir)/docker/main"
# shellcheck disable=SC2013 # URLs contain no whitespace; word-splitting is intended
for u in $(sed -n '/TARGETARCH}" == "amd64"/,/^fi/p' "$UPD/install_deps.sh" | grep -oE 'https://github.com/NickM-27/[^"]+linux64[^"]+\.tar\.xz'); do
  t "S1: ffmpeg part pins upstream amd64 asset ${u##*/}" bash -c "part ffmpeg | grep -qF '$u'"
done
t "S1: ffmpeg installs trees 5.0 7.0 8.0" bash -c "for v in 5.0 7.0 8.0; do part ffmpeg | grep -q \"usr/lib/ffmpeg/\$v/bin/ffprobe\" || exit 1; done"
t "S1: ffmpeg 8.0 sha pinned"             bash -c "part ffmpeg | grep -q 9bac85054d351cdc89c0a4f45c8ea5c44df94009aabd964b719bbadd56aedae9"
G2R=$(grep -oE 'go2rtc/releases/download/v[0-9.]+' "$UPD/Dockerfile" | head -1)
t "S1: go2rtc pin == upstream ($G2R)"     bash -c "part go2rtc | grep -qF '$G2R/go2rtc_linux_amd64'"
t "S1: go2rtc sha pinned"                 bash -c "part go2rtc | grep -q 32d616af226bd731678ffde328b94cfb94e30339bfefc469cfb76323144615a6"
for p in ffmpeg go2rtc; do
  t "S1: $p part is per-arch, fails loud off amd64" bash -c "part $p | grep -q 'case \"\$CRAFT_ARCH_BUILD_FOR\" in' && part $p | grep -q 'unsupported arch'"
done

# --- S2 ffmpeg default ---
for f in spike/bin/frigate-run spike/bin/validate-config; do
  t "S2: $f DEFAULT_FFMPEG_VERSION=8.0"        grep -qx 'export DEFAULT_FFMPEG_VERSION="8.0"' "$f"
  t "S2: $f INCLUDED_FFMPEG_VERSIONS=8.0:7.0:5.0" grep -qx 'export INCLUDED_FFMPEG_VERSIONS="8.0:7.0:5.0"' "$f"
done
t "S2: bridge default 8.0"                    grep -qx 'DEFAULT_FFMPEG_VERSION = "8.0"' spike/bin/go2rtc-config-gen.py
t "S2: ffprobe app runs the 8.0 tree"         grep -q 'command: usr/lib/ffmpeg/8.0/bin/ffprobe' snap/snapcraft.yaml
t "S2: no_stray_7_0_default (spike/, snap/ apps)" bash -c "! grep -rn 'ffmpeg/7\.0/bin' spike/bin spike/config | grep -v '^\s*#'"
for f in spike/bin/frigate-run spike/bin/validate-config; do
  t "S2: $f exports LIBAVFORMAT_VERSION_MAJOR from the default tree (D23)" bash -c \
    "grep -q 'ffmpeg/\$DEFAULT_FFMPEG_VERSION/bin/ffmpeg\" -version' $f && grep -qx 'export LIBAVFORMAT_VERSION_MAJOR' $f"
done
LAVF_SED='s/^libavformat[[:space:]]*\([0-9][0-9]*\)\..*/\1/p'
t "S2: libavformat parse yields the major" bash -c "[ \"\$(printf 'ffmpeg version n8.1.1\nlibavformat    62.  3.100 / 62.  3.100\n' | sed -n '$LAVF_SED' | head -1)\" = 62 ]"

# --- S2 fallback ---
t "S2: fallback_is_snap_version_pre_refresh" grep -qx 'VERSION="${VERSION:-$SNAP_VERSION}"' snap/hooks/pre-refresh
t "S2: fallback_is_snap_version_frigate_run" grep -qx 'CUR_VERSION="${CUR_VERSION:-$SNAP_VERSION}"' spike/bin/frigate-run
t "S2: no literal version fallback left"     bash -c "! grep -nE ':-[0-9]+\.[0-9]+\.[0-9]+\}' snap/hooks/pre-refresh spike/bin/frigate-run"

# --- S2 nginx ---
N=spike/config/nginx
t "S2: auth X-Original-URL is path-only"        grep -q 'proxy_set_header X-Original-URL \$request_uri;' $N/auth_location.conf
t "S2: proxy X-Original-URL is path-only"       grep -q 'proxy_set_header X-Original-URL \$request_uri;' $N/proxy.conf
t "S2: no scheme/host X-Original-URL left"      bash -c "! grep -rq 'X-Original-URL \$scheme' $N"
t "S2: auth passes X-Go2rtc-Stream-Proxy"       grep -q 'proxy_set_header X-Go2rtc-Stream-Proxy \$go2rtc_stream_proxy;' $N/auth_location.conf
t "S2: auth silences uninitialized var (#24682)" grep -q 'uninitialized_variable_warn off;' $N/auth_location.conf
t "S2: 3 go2rtc stream locations set the flag"  bash -c "[ \$(grep -c 'set \$go2rtc_stream_proxy 1;' $N/nginx.conf.in) -eq 3 ]"
for loc in '/live/mse/api/ws' '/live/webrtc/api/ws' '/api/go2rtc/webrtc'; do
  t "S2: flag set inside location $loc" bash -c "awk '/location ${loc//\//\\/} /{f=1} f&&/set \\\$go2rtc_stream_proxy 1;/{ok=1} f&&/^ *}/{exit} END{exit !ok}' $N/nginx.conf.in"
done
t "S2: /api/logout location present"            grep -q 'location /api/logout' $N/nginx.conf.in
t "S2: webp/png/jpeg mime types"                bash -c "grep -q 'image/webp webp;' $N/nginx.conf.in && grep -q 'image/png png;' $N/nginx.conf.in && grep -q 'image/jpeg jpg jpeg;' $N/nginx.conf.in"

# --- S2 ffmpeg drift: every touchpoint follows frigate-run's exports (derived once, asserted positively) ---
FR=spike/bin/frigate-run
DEF=$(sed -n 's/^export DEFAULT_FFMPEG_VERSION="\([^"]*\)"$/\1/p' "$FR")
INC=$(sed -n 's/^export INCLUDED_FFMPEG_VERSIONS="\([^"]*\)"$/\1/p' "$FR")
t "drift: frigate-run exports DEFAULT ($DEF) and INCLUDED ($INC), DEFAULT listed first" \
  bash -c "[ -n '$DEF' ] && [ -n '$INC' ] && [ '${INC%%:*}' = '$DEF' ]"
for s in test testclip; do
  t "drift: go2rtc.yaml.in $s stream execs ffmpeg/$DEF/bin" \
    grep -qF "  $s: exec:__SNAP__/usr/lib/ffmpeg/$DEF/bin/ffmpeg " spike/config/go2rtc.yaml.in
done
t "drift: vaapi-probe execs ffmpeg/$DEF/bin" grep -qF "exec \"\$SNAP/usr/lib/ffmpeg/$DEF/bin/ffmpeg\"" spike/bin/vaapi-probe
# the bridge's constants, read with ast (no import: the module needs yaml and runs at import time)
bridge_const() { python3 -c 'import ast, sys
for n in ast.parse(open(sys.argv[1]).read()).body:
    if isinstance(n, ast.Assign) and any(getattr(x, "id", "") == sys.argv[2] for x in n.targets):
        v = ast.literal_eval(n.value); print(":".join(v) if isinstance(v, tuple) else v); break' spike/bin/go2rtc-config-gen.py "$1"; }
t "drift: bridge DEFAULT_FFMPEG_VERSION == $DEF" test "$(bridge_const DEFAULT_FFMPEG_VERSION)" = "$DEF"
t "drift: bridge INCLUDED_FFMPEG_VERSIONS == $INC" test "$(bridge_const INCLUDED_FFMPEG_VERSIONS)" = "$INC"
t "drift: validate-config DEFAULT == frigate-run's" \
  test "$(sed -n 's/^export DEFAULT_FFMPEG_VERSION="\([^"]*\)"$/\1/p' spike/bin/validate-config)" = "$DEF"
t "drift: validate-config INCLUDED == frigate-run's" \
  test "$(sed -n 's/^export INCLUDED_FFMPEG_VERSIONS="\([^"]*\)"$/\1/p' spike/bin/validate-config)" = "$INC"
t "drift: ffprobe app runs the $DEF tree" grep -q "command: usr/lib/ffmpeg/$DEF/bin/ffprobe\$" snap/snapcraft.yaml
# installs_ffprobe <v>: an `install -D -m 0755 … "$CRAFT_PART_INSTALL/usr/lib/ffmpeg/<v>/bin/ffprobe"` line
installs_ffprobe() {
  part ffmpeg | grep -E '^ *install -D -m 0755 ' | grep -F "\"\$CRAFT_PART_INSTALL/usr/lib/ffmpeg/$1/bin/ffprobe\"" >/dev/null
}
IFS=: read -r -a INC_A <<< "$INC"
for v in "${INC_A[@]}"; do
  t "drift: ffmpeg part installs usr/lib/ffmpeg/$v/bin/ffprobe" installs_ffprobe "$v"
done


# --- S2 D24 clean stop ---
app() { awk -v p="  $1:" '/^apps:$/{s=1;next} /^[a-z]/{s=0} s&&$0==p{f=1;next} f&&/^  [a-z0-9-]+:$/{exit} f' snap/snapcraft.yaml; }
export -f app
t "S2: frigate app runs bin/frigate-db-quiesce as post-stop-command (D24)" bash -c "app frigate | grep -qx '    post-stop-command: bin/frigate-db-quiesce'"
t "S2: frigate app plugs unchanged by D24 (no new plugs)" bash -c "app frigate | grep -qx '    plugs: \[network, network-bind, opengl, shm-private, mount-observe, raw-usb, hardware-observe\]'"
quiesce_fits_stop_budget() {  # systemd arms ExecStopPost with TimeoutStopSec: snapd default 30 s, no stop-timeout set
  local q=spike/bin/frigate-db-quiesce T K
  T=$(sed -n 's/.*FRIGATE_DB_QUIESCE_TIMEOUT:-\([0-9][0-9]*\)}.*/\1/p' "$q" | head -1)
  # K: the hard kill grace. The bound is python-side (coreutils `timeout` is AppArmor-denied under
  # strict confinement; see the script's header), written as the literal line K=<n>.
  K=$(sed -n 's/^K=\([0-9][0-9]*\)$/\1/p' "$q" | head -1)
  [ -n "$T" ] && [ -n "$K" ] && ! app frigate | grep -q 'stop-timeout:' && [ $((T + K)) -le 25 ]
}
t "S2: quiesce timeout + kill grace <= 25 s, inside the 30 s stop-post budget (D24)" quiesce_fits_stop_budget
only_exit_0() { [ "$(sed -n 's/^[[:space:]]*\(exit\b.*\)/\1/p' spike/bin/frigate-db-quiesce | sort -u)" = 'exit 0' ]; }
t "S2: quiesce always exits 0 (D24)" only_exit_0
t "S2: quiesce never execs coreutils timeout (AppArmor-denied under strict confinement) (D24)" bash -c "! grep -qE '^[^#]*(^|[^A-Za-z_])timeout +(-k|-s|[0-9])' spike/bin/frigate-db-quiesce"
t "S2: frigate-run sources lib-db-restore.sh (D24)" grep -qx '\. "\$SNAP/bin/lib-db-restore.sh"' spike/bin/frigate-run
t "S2: frigate-run restores through db_restore (D24)" grep -q 'db_restore "\$SNAP_COMMON/db/frigate.db" "\$BACKUP"' spike/bin/frigate-run
t "S2: no bare mv of frigate.db left in frigate-run (D24)" bash -c "! grep -nE 'mv \"\\\$SNAP_COMMON/db/frigate\.db' spike/bin/frigate-run"
t "S2: spike/bin/frigate-db-quiesce is executable (shipped by the wrappers dump) (D24)" test -x spike/bin/frigate-db-quiesce
t "S2: wrappers part dumps spike/bin into bin/ (D24)" bash -c "part wrappers | grep -q 'source: spike/bin' && part wrappers | grep -qF \"'*': bin/\""

[ "$FAILS" -eq 0 ]
