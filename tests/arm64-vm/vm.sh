#!/usr/bin/env bash
# M7c-2 emulated arm64 VM: qemu TCG, Cortex-A76 (spec D22). No SSH and no port forward: driven via qemu-guest-agent.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
[ -n "${M7C_VM_DIR:-}" ] || { echo "vm.sh: set M7C_VM_DIR to a scratch dir outside the repo" >&2; exit 2; }
RUN="$M7C_VM_DIR"; PID="$RUN/qemu.pid"; QGA="$RUN/qga.sock"
IMG_SERIAL="20261016"
IMG_BASE="https://cloud-images.ubuntu.com/resolute/$IMG_SERIAL"; IMG=resolute-server-cloudimg-arm64.img
. "$REPO/tests/lib/harness-arch.sh"
alive() { [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; }
q() { python3 -I "$HERE/qga.py" "$QGA" --timeout "${QGA_TIMEOUT:-3600}" -- "$*"; }
qemu_cmd() { printf '%s\n' qemu-system-aarch64 -M virt -cpu cortex-a76 -accel tcg,thread=multi -smp 4 -m 8192 \
  -drive "if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd" -drive "if=pflash,format=raw,file=$RUN/vars.fd" \
  -drive "if=virtio,format=qcow2,file=$RUN/disk.qcow2" -drive "if=virtio,format=raw,readonly=on,file=$RUN/seed.iso" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -virtfs "local,path=$REPO,mount_tag=repo,security_model=none,readonly=on" \
  -virtfs "local,path=$RUN/out,mount_tag=out,security_model=mapped-xattr" \
  -chardev "socket,id=qga0,path=$QGA,server=on,wait=off" -device virtio-serial \
  -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
  -qmp "unix:$RUN/qmp.sock,server=on,wait=off" -display none -serial "file:$RUN/console.log" -daemonize -pidfile "$PID"; }
case "${1:-}" in
  fetch)  mkdir -p "$RUN"; curl -fL -o "$RUN/base.img" "$IMG_BASE/$IMG"
          curl -fsL "$IMG_BASE/SHA256SUMS" | awk -v f="*$IMG" '$2==f{print $1"  '"$RUN/base.img"'"}' | sha256sum -c - ;;
  seed)   "$HERE/seed.sh" "$RUN" ;;
  up)     if alive; then echo "vm.sh: already running (pid $(cat "$PID"))" >&2; exit 1; fi
          rm -f "$PID"
          if [ -n "${VM_DRY_RUN:-}" ]; then qemu_cmd | paste -sd " "; exit 0; fi
          mkdir -p "$RUN/out"
          [ -f "$RUN/disk.qcow2" ] || qemu-img create -f qcow2 -F qcow2 -b "$RUN/base.img" "$RUN/disk.qcow2" 40G
          [ -f "$RUN/vars.fd" ] || cp /usr/share/AAVMF/AAVMF_VARS.fd "$RUN/vars.fd"
          mapfile -t c < <(qemu_cmd); "${c[@]}" ;;
  wait)   end=$(( $(date +%s) + $(scaled 1800) ))
          until QGA_TIMEOUT=10 q true >/dev/null 2>&1; do [ "$(date +%s)" -lt "$end" ] || { echo "vm.sh: guest agent never answered" >&2; exit 1; }; command sleep 5; done
          q "cloud-init status --wait" ;;
  exec)   shift; q "$*" ;;
  down)   QGA_TIMEOUT=10 q "systemctl poweroff" >/dev/null 2>&1 || true
          for _ in $(seq 1 "${VM_DOWN_WAIT:-120}"); do alive || break; command sleep 1; done
          if alive; then kill "$(cat "$PID")"; fi
          rm -f "$PID" ;;
  status) if alive; then echo "running (pid $(cat "$PID"))"; else echo stopped; fi ;;
  *)      echo "usage: vm.sh fetch|seed|up|wait|exec|down|status" >&2; exit 2 ;;
esac
