#!/usr/bin/env bash
# Fake hub for tests/hub/make-config.test.sh (the stub ssh's $STUB_RESPONDER). $1 = "sudo -n sh -c '<cmd>'".
# File commands run for real with /var/snap/frigate/current/config mapped to $STUB_ST/hubcfg (chown is a
# no-op stub); `snap services frigate` and `snap run frigate.validate-config` are faked. Every <cmd> is
# appended to $STUB_ST/cmds. Knobs: MC_ACTIVE=1 (frigate.frigate active), MC_VALID=0 (validate fails and
# echoes the camera URL with its login, as a careless error message would), MC_G2R_ACTIVE=1 (frigate.go2rtc
# active), MC_CHECK=0 (frigate.ezviz-check reports "mode"). /var/snap/frigate/current/ezviz -> $STUB_ST/ezviz and
# /var/snap/frigate/common/ezviz -> $STUB_ST/common-ezviz.
set -u
st="${STUB_ST:?}"; fx=$(cd "$(dirname "$0")" && pwd)
eval "set -- $1"
[ "$1 $2 $3 $4" = "sudo -n sh -c" ] || { echo "responder: not a sudo -n sh -c call: $*" >&2; exit 99; }
cmd=$5; printf '%s\n' "$cmd" >> "$st/cmds"
case "$cmd" in
  'snap services frigate')
    a=inactive; [ "${MC_ACTIVE:-0}" = 1 ] && a=active
    g=inactive; [ "${MC_G2R_ACTIVE:-0}" = 1 ] && g=active
    printf 'Service            Startup   Current   Notes\nfrigate.certsync   disabled  active    -\nfrigate.frigate    disabled  %s  -\nfrigate.go2rtc     disabled  %s  -\nfrigate.nginx      disabled  active    -\n' "$a" "$g" ;;
  'snap run frigate.validate-config')
    if [ "${MC_VALID:-1}" = 1 ]; then echo "*************************************************************"; echo "*** Your config file is valid. ***"; exit 0; fi
    u=$(yq -r '.go2rtc.streams.cam1[0]' - < "$st/hubcfg/config.yml")
    echo "Error parsing config: cameras.cam1: stream $u is not reachable"
    echo "password for admin rejected"
    exit 1 ;;
  'snap run frigate.ezviz-check cam'[12])
    n=${cmd##* }; f=$st/ezviz/cameras/$n.conf
    if [ "${MC_CHECK:-1}" = 1 ] && [ -f "$f" ] && [ "$(stat -c %a "$f")" = 600 ]; then echo "ezviz-check $n: ok"; exit 0; fi
    echo "ezviz-check $n: mode"; exit 1 ;;
  *) c=${cmd//\/var\/snap\/frigate\/current\/config/$st/hubcfg}
     c=${c//\/var\/snap\/frigate\/current\/ezviz/$st/ezviz}; c=${c//\/var\/snap\/frigate\/common\/ezviz/$st/common-ezviz}
     PATH="$fx/stub/bin:$PATH" sh -c "$c" ;;
esac
