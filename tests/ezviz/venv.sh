#!/usr/bin/env bash
# Builds the laptop/CI venv for the ezviz helper tests from the W-23 hash lock (spike/ezviz/requirements.txt) and
# prints its python path. Idempotent: rebuilds when the lock's sha256 changes. The .pth makes `ezviz_source`
# importable under `python -I` (site-packages .pth files are still read in isolated mode). One venv per worktree:
# set W23_VENV to a worktree-specific path when two worktrees test at once (the .pth names one checkout).
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd); LOCK="$REPO/spike/ezviz/requirements.txt"
V="${W23_VENV:-$HOME/.cache/frigate-w23/venv}"; WANT=$(sha256sum "$LOCK" | cut -d' ' -f1)
if [ "$(cat "$V/lock.sha256" 2>/dev/null || true)" != "$WANT" ]; then
  rm -rf "$V"; python3.12 -m venv "$V"
  "$V/bin/python" -m pip install -q --no-cache-dir --require-hashes --only-binary=:all: --no-deps -r "$LOCK" >&2
  echo "$WANT" > "$V/lock.sha256"
fi
SP=$("$V/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
echo "$REPO/spike/ezviz" > "$SP/ezviz_source.pth"
echo "$V/bin/python"
