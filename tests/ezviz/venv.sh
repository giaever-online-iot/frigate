#!/usr/bin/env bash
# Builds the laptop/CI venv for the ezviz helper tests from the W-23 hash lock (spike/ezviz/requirements.txt) and
# prints its python path. Idempotent: rebuilds when the lock's sha256 changes. The .pth makes `ezviz_source`
# importable under `python -I` (site-packages .pth files are still read in isolated mode). One venv per checkout:
# the .pth names one checkout, so the default is $HOME/.cache/frigate-w23/venv-<first 12 hex of the sha256 of this
# checkout's absolute path> (fix wave 1, S3: a shared default let one checkout's run retarget another's tests).
# W23_VENV, when set, wins.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd -P); LOCK="$REPO/spike/ezviz/requirements.txt"
V="${W23_VENV:-$HOME/.cache/frigate-w23/venv-$(printf '%s' "$REPO" | sha256sum | cut -c1-12)}"
WANT=$(sha256sum "$LOCK" | cut -d' ' -f1)
if [ "$(cat "$V/lock.sha256" 2>/dev/null || true)" != "$WANT" ]; then
  rm -rf "$V"; python3.12 -m venv "$V"
  "$V/bin/python" -m pip install -q --no-cache-dir --require-hashes --only-binary=:all: --no-deps -r "$LOCK" >&2
  echo "$WANT" > "$V/lock.sha256"
fi
SP=$("$V/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
echo "$REPO/spike/ezviz" > "$SP/ezviz_source.pth"
echo "$V/bin/python"
