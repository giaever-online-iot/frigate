#!/usr/bin/env bash
# Static test for the nginx part's third-party source downloads in snap/snapcraft.yaml (W-19).
# The kaltura nginx-vod-module and nginx-secure-token-module GitHub repos return 404 (removed
# ~Nov 2026); the part now fetches tree-identical copies from public forks, pinned by commit and
# sha256 (provenance: Software Heritage, recorded in the comments above each download).
# Hermetic: reads the yaml only, no network.
# Run: bash tests/nginx-sources.test.sh [path/to/snapcraft.yaml]   (exit 0 = all checks pass)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
YAML="${1:-$HERE/../snap/snapcraft.yaml}"

# Proven values (SWH revision == fork commit; tree == SWH directory; sha256 of the fork archive).
VOD_URL="https://github.com/dio-az/nginx-vod-module/archive/6c305a78b7ab6e4312279bea5c45741bb54a713b.tar.gz"
VOD_SHA="a57069a31fa6cb0b045746f53d0fcd48f1bb409727d4cfbe2197cd8bfaca06a2"
ST_URL="https://github.com/webtor-io/nginx-secure-token-module/archive/18b97a82878e09fef24fe4f6a446eed01dbe28d7.tar.gz"
ST_SHA="c3691a5af6f1dfdc0ca5ff87c1947e65108762f89792d7288a07d386dc702cec"

FAILS=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILS=$((FAILS+1)); }

if [ ! -s "$YAML" ]; then
  fail "snapcraft.yaml missing or empty: $YAML"
  echo "1 check(s) failed"; exit 1
fi

# The nginx part (under top-level "parts:", not the "nginx" app under "apps:"): from "  nginx:"
# up to the next line at part indent (2 spaces, non-comment) or the next top-level key.
PART="$(awk '/^parts:/{inp=1; next} inp && /^[^ #]/{exit}
             inp && /^  nginx:[[:space:]]*$/{p=1; print; next}
             p && (/^  [^ #]/ || /^[^ #]/){exit} p{print}' "$YAML")"
if [ -n "$PART" ]; then ok "nginx part found"; else fail "nginx part not found in $YAML"; fi

# 1. The dead kaltura repos must not be referenced anywhere in the yaml.
for dead in github.com/kaltura/nginx-vod-module github.com/kaltura/nginx-secure-token-module; do
  if grep -qF "$dead" "$YAML"; then fail "snapcraft.yaml still references $dead (repo is 404)"
  else ok "no reference to $dead"; fi
done

# 2. Each module's wget is the exact fork commit-archive URL.
# check_wget <file> <url>
check_wget() {
  local want="      wget -nv -O $1 \"$2\""
  if grep -qxF -- "$want" <<<"$PART"; then ok "$1 fetched from $2"
  else fail "$1: expected exact line: $want"; fi
}
check_wget vod.tar.gz "$VOD_URL"
check_wget secure-token.tar.gz "$ST_URL"

# 3. Every wget -nv -O <file> in the part is followed (next line) by a 64-hex sha256sum -c of the same file.
n_wget=0
while IFS= read -r ln; do
  case "$ln" in
    *"wget -nv -O "*) ;;
    *) continue ;;
  esac
  n_wget=$((n_wget+1))
  f="$(sed -E 's/.*wget -nv -O ([^ ]+) .*/\1/' <<<"$ln")"
  next="$(grep -A1 -xF -- "$ln" <<<"$PART" | sed -n 2p)"
  if [[ "$next" =~ ^[[:space:]]*echo\ \"[0-9a-f]{64}\ \ ([^\"]+)\"\ \|\ sha256sum\ -c\ -[[:space:]]*$ ]] \
     && [ "${BASH_REMATCH[1]}" = "$f" ]; then
    ok "$f is sha256-verified on the next line"
  else
    fail "$f: line after wget is not 'echo \"<64 hex>  $f\" | sha256sum -c -' (got: ${next:-<none>})"
  fi
done <<<"$PART"
if [ "$n_wget" -ge 5 ]; then ok "$n_wget wget downloads in the nginx part"
else fail "expected >= 5 wget downloads in the nginx part, found $n_wget"; fi

# 4. The two new pins are the exact proven values.
# check_sha <file> <sha>
check_sha() {
  local want="      echo \"$2  $1\" | sha256sum -c -"
  if grep -qxF -- "$want" <<<"$PART"; then ok "$1 pinned to $2"
  else fail "$1: expected exact pin line: $want"; fi
}
check_sha vod.tar.gz "$VOD_SHA"
check_sha secure-token.tar.gz "$ST_SHA"

# 5. The fork archives' top dir is <repo>-<commit>, not <repo>-<tag>: extraction must strip it.
for pair in vod.tar.gz:nginx-vod-module secure-token.tar.gz:nginx-secure-token-module; do
  f="${pair%%:*}"; d="${pair##*:}"
  want="      mkdir -p $d && tar -zxf $f -C $d --strip-components=1"
  if grep -qxF -- "$want" <<<"$PART"; then ok "$f extracted into $d with --strip-components=1"
  else fail "$f: expected exact line: $want"; fi
done

# 6. The override-build body parses as bash.
BODY="$(awk '/^    override-build: \|[[:space:]]*$/{p=1; next} p && match($0, /[^ ]/) && RSTART <= 6 {exit} p{print}' <<<"$PART")"
if [ -z "$BODY" ]; then fail "nginx override-build body not found"
elif bash -n <<<"$BODY" 2>/dev/null; then ok "nginx override-build body passes bash -n"
else fail "nginx override-build body fails bash -n"; fi

if [ "$FAILS" -eq 0 ]; then echo "all checks passed"; exit 0; fi
echo "$FAILS check(s) failed"; exit 1
