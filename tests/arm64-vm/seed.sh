#!/usr/bin/env bash
# Build the cloud-init NoCloud seed ISO into $1 (the VM run dir).
set -euo pipefail
RUN=${1:?usage: seed.sh RUN_DIR}
mkdir -p "$RUN"
cat > "$RUN/meta-data" <<'META'
instance-id: m7c-arm64-1
local-hostname: m7c-arm64
META
cat > "$RUN/user-data" <<'USER'
#cloud-config
hostname: m7c-arm64
package_update: true
packages: [qemu-guest-agent, jq, ffmpeg, squashfs-tools, curl]
swap: {filename: /swap.img, size: 2147483648}
mounts:
  - [repo, /mnt/repo, 9p, "trans=virtio,version=9p2000.L,ro,nofail", "0", "0"]
  - [out, /mnt/out, 9p, "trans=virtio,version=9p2000.L,nofail", "0", "0"]
runcmd:
  - [systemctl, enable, --now, qemu-guest-agent]
  - [mount, -a]
USER
xorriso -as mkisofs -o "$RUN/seed.iso" -V cidata -J -r "$RUN/user-data" "$RUN/meta-data"
