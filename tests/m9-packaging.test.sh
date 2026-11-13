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

[ "$FAILS" -eq 0 ]
