#!/usr/bin/env bash
# M7c hub: run one command on the hub, or copy one file to it, through an EXISTING ssh master only.
# It never opens a new connection (a new one needs a key touch, and D14 says no worker connects):
#   -F /dev/null            no user or system ssh config (no ProxyJump, ControlMaster or host alias side effects);
#   -S $M7C_HUB_SOCK         the operator's master socket; -o ControlMaster=no: never become a master;
#   -o ProxyCommand=/bin/false  if the master is gone, ssh's fallback "connect" runs /bin/false and fails at once;
#   -o BatchMode=yes         never prompt.
# The socket and the target come from the environment only; neither belongs in the repo, tests or docs.
# Usage: M7C_HUB_SOCK=<socket> M7C_HUB_TARGET=<target> tests/hub/ssh-exec.sh check
#        ... ssh-exec.sh exec "<sh -c string>"     run as root (sudo -n sh -c); prints its output, returns its rc
#        ... ssh-exec.sh put <local file> <hub path> copy (root, 0600, via a .m7c-part + mv) and check sha256 on the hub
#        ... ssh-exec.sh sha <hub path> <sha256>   check a hub file's sha256
# Exit: the remote rc for exec; 0/1 for put and sha; 2 usage; 3 the master is gone (LOUD); 124 timeout.
# Env: M7C_HUB_TIMEOUT (seconds per call, default 600). Test hook: M7C_SSH (the ssh binary).
set -uo pipefail
SSH="${M7C_SSH:-ssh}"
usage() { echo "usage: ssh-exec.sh check | exec <cmd> | put <local> <hub path> | sha <hub path> <sha256>" >&2; exit 2; }
[ -n "${M7C_HUB_SOCK:-}" ] || { echo "ssh-exec: set M7C_HUB_SOCK (the existing master's control socket)" >&2; exit 2; }
[ -n "${M7C_HUB_TARGET:-}" ] || { echo "ssh-exec: set M7C_HUB_TARGET (the target the master was opened for)" >&2; exit 2; }
TO="${M7C_HUB_TIMEOUT:-600}"
case "$TO" in ''|*[!0-9]*) echo "ssh-exec: M7C_HUB_TIMEOUT must be whole seconds, got '$TO'" >&2; exit 2 ;; esac
OPTS=(-F /dev/null -S "$M7C_HUB_SOCK" -o ControlMaster=no -o ProxyCommand=/bin/false -o BatchMode=yes)

gone() { echo "ssh-exec: MASTER GONE: no live ssh master at \$M7C_HUB_SOCK; NOT opening a new connection (exit 3)" >&2; exit 3; }
# </dev/null: the check must never eat the stdin meant for the session (put, or a config piped to exec).
master_ok() { "$SSH" "${OPTS[@]}" -O check "$M7C_HUB_TARGET" >/dev/null 2>&1 </dev/null; }
# sq STR: STR as one POSIX single-quoted word (safe for any remote login shell, not only bash).
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# run CMD: CMD as root on the hub through the master; stdin passes through. rc 255 + no master => exit 3.
run() {
  local rc
  timeout "$TO" "$SSH" "${OPTS[@]}" "$M7C_HUB_TARGET" "sudo -n sh -c $(sq "$1")"; rc=$?
  if [ "$rc" = 124 ]; then echo "ssh-exec: TIMEOUT after ${TO}s" >&2; return 124; fi
  if [ "$rc" = 255 ] && ! master_ok; then gone; fi
  return "$rc"
}
hubpath_ok() { case "$1" in /*) ;; *) return 1 ;; esac; case "$1" in *[!A-Za-z0-9./_-]*|*..*) return 1 ;; esac; }
sha_ok() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
remote_sha() {   # remote_sha PATH WANT: 0 iff the hub file's sha256 is WANT; prints what the hub computed
  local out got
  out=$(run "sha256sum $(sq "$1")") || { echo "ssh-exec: sha256sum of $1 failed on the hub: $out" >&2; return 1; }
  got=$(awk 'NR == 1 { print $1 }' <<<"$out")
  echo "hub sha256 $got $1"
  [ "$got" = "$2" ] || { echo "ssh-exec: SHA MISMATCH for $1: hub $got, want $2" >&2; return 1; }
}

cmd="${1:-}"; [ $# -ge 1 ] && shift
master_ok || gone
case "$cmd" in
  check) [ $# -eq 0 ] || usage; echo "ssh-exec: master alive" ;;
  exec)  [ $# -eq 1 ] || usage; run "$1"; exit $? ;;
  sha)   [ $# -eq 2 ] || usage; hubpath_ok "$1" || usage; sha_ok "$2" || usage; remote_sha "$1" "$2" ;;
  put)
    [ $# -eq 2 ] || usage; L="$1"; P="$2"
    if [ ! -f "$L" ] || [ ! -r "$L" ]; then echo "ssh-exec: put: $L is not a readable file" >&2; exit 2; fi
    hubpath_ok "$P" || { echo "ssh-exec: put: hub path must be absolute, [A-Za-z0-9./_-], no '..': $P" >&2; exit 2; }
    want=$(sha256sum "$L" | awk '{ print $1 }')
    run "umask 077 && mkdir -p $(sq "${P%/*}") && cat > $(sq "$P.m7c-part") && mv -f $(sq "$P.m7c-part") $(sq "$P")" < "$L" \
      || { echo "ssh-exec: put: copy to $P failed" >&2; exit 1; }
    if remote_sha "$P" "$want"; then echo "PUT OK $P sha256 $want"
    else run "rm -f $(sq "$P")" >/dev/null 2>&1; echo "ssh-exec: put: removed the mismatched $P" >&2; exit 1; fi ;;
  *) usage ;;
esac
