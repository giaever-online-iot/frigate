#!/usr/bin/env bash
# One-time dev-machine setup for the M0 spike harness.
# Validates and installs the scoped NOPASSWD sudoers drop-in, then verifies it.
# Run:    sudo bash tests/sudo-setup.sh
# Undo:   sudo rm /etc/sudoers.d/frigate-spike
set -euo pipefail
cd "$(dirname "$0")/.."

visudo -c -f tests/frigate-spike.sudoers
install -m 440 -o root -g root tests/frigate-spike.sudoers /etc/sudoers.d/frigate-spike

# Verify: the invoking user can now run the allowed commands without a password.
sudo -u "${SUDO_USER:?run via sudo, not as root login}" sudo -n snap version >/dev/null
echo SUDOERS-OK
