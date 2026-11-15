#!/usr/bin/env bash
# nginx_settle for tests/spike-smoke.sh (M7c, the amd64 gate run-1 cert-profile FAILs). Sourced, not executed.
#
# `snap set/unset` returns once the configure hook's `snapctl restart frigate.nginx frigate.certsync`
# (snap/hooks/configure) has STARTED the new nginx-run, but nginx-run still needs a moment to check for the
# certs, render listen.conf and exec nginx, which then loads the certs. A cert deletion inside that window
# makes nginx die with "[emerg] cannot load certificate" (journal 2026-11-14 03:20:38, gate run 1), and the
# auto-restart plus the harness's own restart then hit systemd's start limit. A new MainPID alone does not
# close the window (that run's new PID existed 0.37 s before the emerg); a TLS handshake on :8971 does,
# because nginx then holds the certs in memory and deleting the files is safe.
#
# nginx_settle OLD_MAINPID [POLLS]: poll (1 s each, scaled by the harness's sleep wrapper when sourced
# there) until snap.$SNAP_NAME.nginx.service is active with a MainPID that is neither 0 nor OLD_MAINPID and
# 127.0.0.1:8971 completes a TLS handshake. Prints the new MainPID and returns 0; returns 1 after POLLS polls
# (default 20); returns 2 on a non-numeric argument.
nginx_settle() {
  local old=${1:-} polls=${2:-20} u="snap.${SNAP_NAME:-frigate}.nginx.service" i pid to=5
  case "$old" in ''|*[!0-9]*) echo "nginx_settle: old MainPID must be a number, got '$old'" >&2; return 2 ;; esac
  case "$polls" in ''|*[!0-9]*) echo "nginx_settle: polls must be a number, got '$polls'" >&2; return 2 ;; esac
  command -v scaled >/dev/null 2>&1 && to=$(scaled 5)
  for ((i = 0; i < polls; i++)); do
    pid=$(systemctl show -p MainPID --value "$u" 2>/dev/null)
    if [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != "$old" ] && systemctl is-active "$u" >/dev/null 2>&1 \
       && timeout "$to" openssl s_client -connect 127.0.0.1:8971 </dev/null 2>/dev/null | grep -q 'BEGIN CERTIFICATE'; then
      echo "$pid"; return 0
    fi
    sleep 1
  done
  return 1
}
