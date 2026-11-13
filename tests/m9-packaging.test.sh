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

[ "$FAILS" -eq 0 ]
