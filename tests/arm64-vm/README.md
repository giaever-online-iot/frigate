# arm64 VM harness (M7c, spec D22)

An emulated arm64 guest: qemu TCG, `-M virt -cpu cortex-a76 -accel tcg,thread=multi` (never `-cpu max`).
Ubuntu cloud image, provisioned by a cloud-init NoCloud seed (`seed.sh`), driven through
qemu-guest-agent by `qga.py` over a local unix socket.

**No SSH and no port forward, by design.** The guest has user-mode networking for outbound
traffic only; the only control path is the guest-agent socket in the run directory.

## Commands

`M7C_VM_DIR=<scratch dir outside the repo> tests/arm64-vm/vm.sh fetch|seed|up|wait|exec|down|status`

- `fetch` downloads the pinned base image and verifies its checksum.
- `seed` builds `seed.iso` (needs `xorriso`).
- `up` starts the VM (refuses if the recorded pid is alive; a stale pidfile is cleaned).
- `wait` polls the guest agent, then `cloud-init status --wait`.
- `exec CMD` runs `sh -c CMD` in the guest and returns its exit code, stdout and stderr.
- `down` powers off via the agent, then kills only the recorded pid if it is still alive.

Guest mounts: `/mnt/repo` (the worktree, read-only 9p) and `/mnt/out` (`$M7C_VM_DIR/out`, writable 9p).

## Environment variables

| Variable | Meaning |
| --- | --- |
| `M7C_VM_DIR` | Required. Run directory (disk, vars, seed, sockets, pidfile). Exit 2 if unset. |
| `VM_DRY_RUN` | If set, `up` prints the qemu command line and exits without starting anything. |
| `VM_DOWN_WAIT` | Seconds `down` waits for a clean poweroff before killing the pid (default 120). |
| `QGA_TIMEOUT` | Per-command guest-agent timeout in seconds (default 3600). |
| `SPIKE_TIME_SCALE` | Time multiplier for waits (`scaled N` in `tests/lib/harness-arch.sh`). |

## The battery

`M7C_VM_DIR=... SPIKE_TIME_SCALE=<n> tests/arm64-vm/battery.sh <channel>` installs from a Store channel.
`... battery.sh --file <guest path> <sha256>` installs a local file instead: it copies the file (under
`/mnt/out`) to the guest's disk, hashes the copy and installs it with `snap install --dangerous` only if
the hash matches. Use file mode when the VM cannot reach the snap on the Store (a private snap; the VM
never gets a Store login). The Store-only checks (F11 auto-connect, V17 refresh under hold, V17
`snap download`) then print `INFO: ... not exercised: private snap, no Store in the VM`.

## TCG speed caveat

This is full software emulation. Expect it to run many times slower than the host and boot to take
minutes. Scale timeouts with `SPIKE_TIME_SCALE` rather than assuming native speed.

## Tests

`vm.test.sh` and `test_qga.py` need no qemu (dry run and fake pids/sockets only) and run in CI.
`battery.test.sh` drives `battery.sh` in both modes against a stub `vm.sh` (`fixtures/stub/`) that runs
the guest commands with `PATH` set only to fake tools, so the host's own `snap` is never reached.

The live smoke (fetch, boot, exec, down) is heavy and runs under the suite lock:
`flock -w 3600 /tmp/claude-1000/chim-suites.lock ...`.
