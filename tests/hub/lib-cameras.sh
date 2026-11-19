# shellcheck shell=bash
# read_cameras, shared by tests/hub/make-config.sh and tests/ezviz/probe-run.sh (W-23 T12). Moved verbatim from
# make-config.sh. The caller defines say() and die() and the arrays IDS, IPS, PW; this sets IDS, IPS, PW (and ENVD,
# PAIRS, ENVF, KEYFILE, MAIN, SUB, found) and dies with make-config's codes and words.
read_cameras() {
ENVD="${M7C_ENV_DIR:-$HOME/.local/state/m7c-hub}"; PAIRS="$ENVD/cameras.pairs"; ENVF="$ENVD/env"
private() { [ -f "$1" ] && [ -r "$1" ] && [ $(( 0$(stat -c %a "$1") & 077 )) = 0 ]; }
private "$PAIRS" || die 2 "cameras.pairs in M7C_ENV_DIR is missing, unreadable, or not private (must be 0600)"
private "$ENVF"  || die 2 "env in M7C_ENV_DIR is missing, unreadable, or not private (must be 0600)"
KEYFILE=$(sed -n 's/^M7C_KEYFILE=//p' "$ENVF" | tail -n 1 | tr -d '\r'); KEYFILE=${KEYFILE#[\"\']}; KEYFILE=${KEYFILE%[\"\']}
# shellcheck disable=SC2088  # a literal "~/" prefix in the env file is expanded here on purpose
case "$KEYFILE" in '~/'*) KEYFILE="$HOME/${KEYFILE#\~/}" ;; esac
[ -n "$KEYFILE" ] || die 2 "env has no M7C_KEYFILE= line"
if [ ! -f "$KEYFILE" ] || [ ! -r "$KEYFILE" ]; then die 2 "the key file named by M7C_KEYFILE is missing or unreadable"; fi
MAIN="${M7C_RTSP_MAIN:-/Streaming/Channels/101}"; SUB="${M7C_RTSP_SUB:-/Streaming/Channels/102}"
for p in "$MAIN" "$SUB"; do [[ "$p" =~ ^/[A-Za-z0-9/_.=-]*$ ]] || die 2 "M7C_RTSP_MAIN/M7C_RTSP_SUB must be a path like /Streaming/Channels/101"; done
ipv4() {   # pattern match only: no here-string (bash may back one with a temp file)
  local o; [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do [[ "$o" =~ ^(0|[1-9][0-9]*)$ ]] || return 1; [ "$o" -le 255 ] || return 1; done
}
while read -r id ip extra; do
  case "$id" in ''|'#'*) continue ;; esac
  [ -z "${extra:-}" ] || die 2 "cameras.pairs line $(( ${#IDS[@]} + 1 )): want '<camera id> <ipv4>'"
  [[ "$id" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || die 2 "cameras.pairs line $(( ${#IDS[@]} + 1 )): the camera id has an unexpected shape"
  ipv4 "${ip:-}" || die 2 "cameras.pairs line $(( ${#IDS[@]} + 1 )): not an IPv4 address"
  IDS+=("$id"); IPS+=("$ip")
done < <(tr -d '\r' < "$PAIRS")
[ "${#IDS[@]}" = 2 ] || die 2 "cameras.pairs must list exactly 2 cameras, found ${#IDS[@]}"
[ "${IDS[0]}" != "${IDS[1]}" ] || die 2 "cameras.pairs lists the same camera twice"
say "2 cameras in cameras.pairs"

# Codes: one "<id> <code>" line per entry of the one mapping we use, straight from yq into this loop (a pipe).
PW=("" ""); found=0
while read -r k v; do
  for i in 0 1; do if [ "$k" = "${IDS[$i]}" ] && [ -z "${PW[$i]}" ]; then PW[i]=$v; found=$((found + 1)); fi; done
done < <(tr -d '\r' < "$KEYFILE" | yq -r '.["original QR Code keys"] | to_entries | .[] | .key + " " + .value' - 2>/dev/null)
[ "$found" = 2 ] || die 6 "$found of 2 camera codes found in the key file"
for i in 0 1; do [[ "${PW[$i]}" =~ ^[A-Za-z0-9]{4,32}$ ]] || die 6 "the code for cam$((i + 1)) has an unexpected shape"; done
say "2 of 2 camera codes found"
}
