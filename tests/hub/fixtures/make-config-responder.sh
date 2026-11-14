#!/usr/bin/env bash
# Fake hub for tests/hub/make-config.test.sh (the stub ssh's $STUB_RESPONDER). $1 = "sudo -n sh -c '<cmd>'".
# File commands run for real with /var/snap/frigate/current/config mapped to $STUB_ST/hubcfg (chown is a
# no-op stub); `snap services frigate` and `snap run frigate.validate-config` are faked. Every <cmd> is
# appended to $STUB_ST/cmds. Knobs: MC_ACTIVE=1 (frigate.frigate active), MC_VALID=0 (validate fails and
# echoes the camera URL with its login, as a careless error message would).
set -u
st="${STUB_ST:?}"; fx=$(cd "$(dirname "$0")" && pwd)
eval "set -- $1"
[ "$1 $2 $3 $4" = "sudo -n sh -c" ] || { echo "responder: not a sudo -n sh -c call: $*" >&2; exit 99; }
cmd=$5; printf '%s\n' "$cmd" >> "$st/cmds"
case "$cmd" in
  'snap services frigate')
    a=inactive; [ "${MC_ACTIVE:-0}" = 1 ] && a=active
    printf 'Service            Startup   Current   Notes\nfrigate.certsync   disabled  active    -\nfrigate.frigate    disabled  %s  -\nfrigate.go2rtc     disabled  inactive  -\nfrigate.nginx      disabled  active    -\n' "$a" ;;
  'snap run frigate.validate-config')
    if [ "${MC_VALID:-1}" = 1 ]; then echo "*************************************************************"; echo "*** Your config file is valid. ***"; exit 0; fi
    u=$(yq -r '.go2rtc.streams.cam1[0]' - < "$st/hubcfg/config.yml")
    echo "Error parsing config: cameras.cam1: stream $u is not reachable"
    echo "password for admin rejected"
    exit 1 ;;
  *) c=${cmd//\/var\/snap\/frigate\/current\/config/$st/hubcfg}
     PATH="$fx/stub/bin:$PATH" sh -c "$c" ;;
esac
