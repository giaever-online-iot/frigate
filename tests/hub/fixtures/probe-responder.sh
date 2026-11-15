#!/usr/bin/env bash
# Fake hub for tests/hub/probe.test.sh, used as the stub ssh's $STUB_RESPONDER. $1 is the remote string
# "sudo -n sh -c '<cmd>'"; <cmd> is matched against the commands probe.sh sends and answered from canned
# outputs. Every <cmd> is appended to $STUB_ST/cmds. Knobs (env):
#   P_INSTALLED=0       frigate not installed          P_ACTIVE=frigate.nginx   that service is active
#   P_REV=x1            installed revision             P_SNAPSHA=<hex>          sha256 of the installed .snap file
#   P_UNCON=raw-usb     that plug has no slot          P_IMPORT_BAD=cv2         that import fails
#   P_CORAL=ok|nodev|noinfer|absent                    P_LEAK=1                 probe output carries a password line
#   P_ARCH=amd64        the snap shell's SNAP_ARCH     P_SHELL_FAIL=1           `snap run --shell` is refused
#   P_FLIP=arch|ovcfg   one V-OV result line flipped
set -u
st="${STUB_ST:?}"
eval "set -- $1"
[ "$1 $2 $3 $4" = "sudo -n sh -c" ] || { echo "responder: not a sudo -n sh -c call: $*" >&2; exit 99; }
cmd=$5; printf '%s\n' "$cmd" >> "$st/cmds"
R=/var/snap/frigate/common/spike-results
REV=${P_REV:-x1}; CORAL=${P_CORAL:-ok}
leak() { [ "${P_LEAK:-0}" = 1 ] && { echo "frigate: admin password: hunter2-secret"; echo "cam rtsp://admin:pw123@cam.example/s1"; }; return 0; }
case "$cmd" in
  'snap list frigate')
    [ "${P_INSTALLED:-1}" = 1 ] || { echo "error: no matching snaps installed" >&2; exit 1; }
    printf 'Name     Version  Rev  Tracking  Publisher  Notes\nfrigate  0.18.2   %s   -         -          -\n' "$REV" ;;
  'snap services frigate')
    printf 'Service            Startup   Current   Notes\n'
    for s in certsync frigate go2rtc nginx; do
      c=inactive; [ "${P_ACTIVE:-}" = "frigate.$s" ] && c=active
      printf 'frigate.%-10s disabled  %-8s  -\n' "$s" "$c"
    done
    printf 'frigate.logrotate  enabled   inactive  timer-activated\n' ;;
  "sha256sum /var/lib/snapd/snaps/frigate_$REV.snap")
    echo "${P_SNAPSHA:-26db6fb77d2214c030bfb9da0b533edb0935cd49d376b010347a607e9b6200f4}  /var/lib/snapd/snaps/frigate_$REV.snap" ;;
  'snap connections frigate')
    echo 'Interface         Plug                      Slot               Notes'
    for p in hardware-observe mount-observe raw-usb shm-private; do
      s=":$p"; [ "${P_UNCON:-}" = "$p" ] && s=-
      printf '%-17s frigate:%-17s %-18s manual\n' "$p" "$p" "$s"
    done ;;
  "snap run --shell frigate.frigate -c 'ls -A /etc/OpenCL/vendors /usr/lib/x86_64-linux-gnu/intel-opencl'")
    printf '/etc/OpenCL/vendors:\n.keep\n\n/usr/lib/x86_64-linux-gnu/intel-opencl:\n.keep\n' ;;
  "rm -f $R/imports.json $R/edgetpu-dlopen.json && nice -n 19 snap run frigate.imports-probe")
    : > "$st/imports-ran"; echo "imports-probe: done"; leak ;;
  "cat $R/imports.json")
    [ -e "$st/imports-ran" ] || exit 1
    bad=${P_IMPORT_BAD:-}
    printf '{"status":"complete","imports":{'; first=1
    for m in numpy cv2 onnxruntime tflite_runtime tensorflow openvino fastapi uvicorn starlette peewee pydantic scipy norfair zmq cryptography ruamel.yaml paho.mqtt.client sqlite_vec; do
      ok=true; [ "$m" = "$bad" ] && ok=false
      [ $first = 1 ] || printf ','; first=0; printf '"%s":{"ok":%s,"version":"1"}' "$m" "$ok"
    done; printf '}}\n' ;;
  "cat $R/edgetpu-dlopen.json")
    [ -e "$st/imports-ran" ] || exit 1
    echo '{"dlopen":{"ok":true},"lib_path":"/snap/frigate/x1/usr/lib/aarch64-linux-gnu/libedgetpu.so.1"}' ;;
  '/snap/frigate/current/usr/lib/ffmpeg/8.0/bin/ffmpeg -hide_banner -decoders | grep -cw hevc') echo 4 ;;
  'snap run frigate.ffprobe -version | sed -n 1p') echo 'ffprobe version n8.1.1 Copyright (c) 2007-2026 the FFmpeg developers' ;;
  *'/sys/bus/usb/devices/'*)
    case "$CORAL" in absent) ;; *) if [ -e "$st/coral-ran" ]; then echo 18d1:9302; else echo 1a6e:089a; fi ;; esac ;;
  "rm -f $R/coral.json && snap run frigate.coral-probe")
    : > "$st/coral-ran"; leak ;;
  "cat $R/coral.json")
    [ -e "$st/coral-ran" ] || exit 1
    case "$CORAL" in
      ok)      echo '{"status":"complete","load_delegate":{"ok":true},"inference":{"ok":true}}' ;;
      noinfer) echo '{"status":"complete","load_delegate":{"ok":true},"inference":{"ok":false,"error":"RuntimeError: boom"}}' ;;
      *)       printf '%s\n' '{"status":"complete","load_delegate":{"ok":false,"error":"ValueError: Failed to load delegate from /snap/frigate/x1/usr/lib/aarch64-linux-gnu/libedgetpu.so.1\n"}}' ;;
    esac ;;
  'snap run --shell frigate.validate-config -c '*)
    # Run the inner script for real against the repo's lib-wait.sh, as the snap's shell would ($SNAP/bin).
    [ "${P_SHELL_FAIL:-0}" = 1 ] && { echo "error: unknown flag \`shell'"; exit 1; }
    eval "set -- $cmd"; fs="$st/fakesnap"; mkdir -p "$fs/bin"; cp "$(dirname "$0")/../../../spike/bin/lib-wait.sh" "$fs/bin/"
    # P_FLIP=arch|ovcfg flips one result line, as a broken guard function would, with everything else intact.
    SNAP="$fs" SNAP_ARCH="${P_ARCH:-arm64}" bash -c "$6" 2>&1 \
      | case "${P_FLIP:-}" in arch) sed 's/^arch=no-ov$/arch=has-ov/' ;; ovcfg) sed 's/^ovcfg=uses-ov$/ovcfg=no/' ;; *) cat ;; esac ;;
  *) echo "responder: unexpected command: $cmd" >&2; exit 98 ;;
esac
