# M0 De-risking Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the smallest strict-confined core26 snap that empirically answers the architectural unknowns from the design spec (`docs/superpowers/specs/2026-07-02-frigate-snap-design.md` §4-M0): /dev/shm behavior, layouts, daemon ordering, Python-3.11-on-core26, wheel/deb ABI, and GPU/Coral/NPU device reachability — findings recorded in `docs/spike-findings.md`.

**Architecture:** A throwaway probe snap named `frigate` lives in `spike/` (its own snapcraft project, separate from the illustrative `snap/snapcraft.yaml` at repo root). Three stub daemons (`svc-a → svc-b → svc-c`, chained with `after:`) run platform probes at startup then idle; device probes are command apps run on demand after interface connection. All probes write JSON evidence to `$SNAP_COMMON/spike-results/`; a host-side harness `tests/spike-smoke.sh` installs the snap, runs assertions, and scans for AppArmor denials.

**Tech Stack:** snapcraft 9.0 (LXD backend), snapd 2.75.2, base core26, Python 3.11.9 (built from source), Frigate v0.17.2 pinned wheels, libedgetpu (feranick bookworm .deb), mesa-2604 via the `gpu` extension.

## Global Constraints

- Snap name: `frigate`; version: `0.0.1-spike`; `base: core26`; `confinement: strict`; `grade: devel`; `platforms: amd64` only.
- Build: `cd spike && snapcraft pack` → artifact `spike/frigate_0.0.1-spike_amd64.snap`. If a part definition changes, run `snapcraft clean <part>` first.
- Install: `sudo snap install --dangerous spike/frigate_0.0.1-spike_amd64.snap`.
- Smoke: `sudo tests/spike-smoke.sh` (full cycle: remove, install, assert) or `sudo tests/spike-smoke.sh --skip-install` (assert against installed snap).
- Probes must NEVER crash their daemon: every probe body is wrapped by the runner's try/except. Probe JSON always includes `"status"` (`"complete"` or `"crashed"`).
- Result semantics: a smoke PASS means *conclusive evidence was produced*, not that the hypothesis held. Expected AppArmor denials (the `psm_*` shm test) are allowlisted in the denial scan; any other denial fails the run.
- A probe outcome that contradicts expectations is a FINDING, not a bug — record it, don't "fix" it.
- Upstream references pinned to Frigate tag `v0.17.2`.
- Evidence dir `spike/results/` and `spike/*.snap` are git-ignored; probe/harness code is committed.
- This host has the test hardware: Intel Meteor Lake iGPU (`/dev/dri/renderD128`), Intel NPU (`/dev/accel/accel0`), Coral USB (`1a6e:089a`, Bus 003). Do not skip device tasks.
- Task 12 (NPU) is timeboxed: if it exceeds ~2 hours, record `"deferred"` findings and move on.

## File Structure

```
spike/
  snap/snapcraft.yaml       # the spike snap (grows task by task)
  probes/
    probe_common.py         # write_result() helper (Task 2)
    svc.py                  # stub daemon runner + PROBES registry (Task 3)
    probe_platform.py       # shm_probe, layout_probe (Tasks 4-6)
    probe_runtime.py        # runtime_probe, imports_probe, edgetpu_dlopen_probe (Tasks 7-9)
    probe_gpu.py            # GPU/OpenVINO probe (Task 10)
    probe_coral.py          # Coral delegate/inference probe (Task 11)
    probe_npu.py            # NPU custom-device probe (Task 12)
    requirements-spike.txt  # pins copied verbatim from upstream (Task 8)
  bin/
    svc-a, svc-b, svc-c     # daemon wrappers
    gpu-probe, coral-probe, npu-probe   # app wrappers
  .gitignore
tests/spike-smoke.sh        # host-side harness (grows task by task)
docs/spike-findings.md      # Task 13 deliverable
```

---

### Task 1: Spike scaffold — minimal strict core26 snap

**Files:**
- Create: `spike/snap/snapcraft.yaml`, `spike/bin/svc-a`, `spike/probes/.gitkeep`, `spike/.gitignore`

**Interfaces:**
- Produces: an installable snap `frigate` with one active daemon `frigate.svc-a`; the `runtime` part staging `python3`; wrapper pattern `exec "$SNAP/usr/bin/python3" "$SNAP/probes/<script>" <args>`.

- [ ] **Step 1: Create the spike project files**

`spike/.gitignore`:
```
results/
*.snap
```

`spike/snap/snapcraft.yaml`:
```yaml
name: frigate
version: '0.0.1-spike'
summary: Frigate snap M0 de-risking spike (throwaway probes, not Frigate)
description: |
  Probe snap that answers the strict-confinement unknowns for the real
  Frigate snap. See docs/superpowers/specs/2026-07-02-frigate-snap-design.md.
base: core26
grade: devel
confinement: strict

platforms:
  amd64:

apps:
  svc-a:
    command: bin/svc-a
    daemon: simple
    restart-condition: never

parts:
  runtime:
    plugin: nil
    stage-packages: [python3]
  probes:
    plugin: dump
    source: probes
    organize:
      '*': probes/
  wrappers:
    plugin: dump
    source: bin
    organize:
      '*': bin/
```

`spike/bin/svc-a` (placeholder until Task 3 wires the runner):
```sh
#!/bin/sh
mkdir -p "$SNAP_COMMON/spike-results"
echo "scaffold-alive" > "$SNAP_COMMON/spike-results/scaffold.txt"
exec sleep infinity
```

- [ ] **Step 2: Make wrappers executable, create probes placeholder**

```bash
chmod +x spike/bin/svc-a
touch spike/probes/.gitkeep
```

- [ ] **Step 3: Build the snap (first build downloads the core26 LXD image — slow once)**

```bash
cd spike && snapcraft pack
```
If snapcraft reports LXD is not set up: `sudo lxd init --auto`, then retry.
Expected: `Packed frigate_0.0.1-spike_amd64.snap`

- [ ] **Step 4: Install and verify the daemon runs strict-confined**

```bash
sudo snap install --dangerous spike/frigate_0.0.1-spike_amd64.snap
snap services frigate
sudo cat /var/snap/frigate/common/spike-results/scaffold.txt
```
Expected: `frigate.svc-a  enabled  active`; file contains `scaffold-alive`.

- [ ] **Step 5: Commit**

```bash
git add spike/ && git commit -m "spike(M0): scaffold strict core26 snap with one stub daemon"
```

---

### Task 2: Probe results plumbing + smoke harness skeleton

**Files:**
- Create: `spike/probes/probe_common.py`, `tests/spike-smoke.sh`

**Interfaces:**
- Produces: `write_result(name: str, data: dict) -> None` — atomically writes `$SNAP_COMMON/spike-results/<name>.json`. Harness helpers used by ALL later tasks: `pass_`/`fail_`/`check <desc> <cmd...>`; `jqr <result-name> <jq-expr>` reads `/var/snap/frigate/common/spike-results/<result-name>.json`. Assertions are inserted above the `# --- AppArmor denial scan` marker.

- [ ] **Step 1: Write `spike/probes/probe_common.py`**

```python
"""Shared helper: atomic JSON result writer for spike probes."""
import json
import os
import pathlib

RESULTS_DIR = pathlib.Path(os.environ.get("SNAP_COMMON", "/tmp")) / "spike-results"


def write_result(name: str, data: dict) -> None:
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    tmp = RESULTS_DIR / f".{name}.tmp"
    tmp.write_text(json.dumps(data, indent=2, default=str))
    tmp.rename(RESULTS_DIR / f"{name}.json")
```

- [ ] **Step 2: Write `tests/spike-smoke.sh`**

```bash
#!/usr/bin/env bash
# M0 spike smoke harness. Run as root: sudo tests/spike-smoke.sh [--skip-install]
set -uo pipefail
cd "$(dirname "$0")/.."
SNAP_NAME=frigate
SNAP_FILE=$(ls -t spike/${SNAP_NAME}_*.snap 2>/dev/null | head -1)
RESULTS=/var/snap/$SNAP_NAME/common/spike-results
EVIDENCE=spike/results
FAIL=0
mkdir -p "$EVIDENCE"

pass_() { echo "PASS: $1"; }
fail_() { echo "FAIL: $1"; FAIL=1; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass_ "$d"; else fail_ "$d"; fi; }
jqr()   { jq -r "$2" "$RESULTS/$1.json" 2>/dev/null; }

command -v jq >/dev/null || { echo "jq required: sudo apt install -y jq"; exit 1; }

MARK=$(date '+%Y-%m-%d %H:%M:%S')
if [ "${1:-}" != "--skip-install" ]; then
  snap remove --purge $SNAP_NAME 2>/dev/null || true
  snap install --dangerous "$SNAP_FILE" || { fail_ "snap install"; exit 1; }
  pass_ "snap install --dangerous ($SNAP_FILE)"
  sleep 8   # let daemons start and probes write
fi

check "svc-a active" sh -c "snap services $SNAP_NAME.svc-a | grep -q ' active'"

# --- task assertions inserted below this line ---

# --- AppArmor denial scan (keep last) ---
journalctl -k --since "$MARK" | grep -E "apparmor=\"DENIED\".*snap\.$SNAP_NAME" \
  > "$EVIDENCE/denials.txt" || true
UNEXPECTED=$(grep -cvE 'psm_' "$EVIDENCE/denials.txt" || true)
echo "== denials: $(wc -l < "$EVIDENCE/denials.txt") total, $UNEXPECTED unexpected =="
if [ "$UNEXPECTED" -eq 0 ]; then pass_ "no unexpected AppArmor denials"; else fail_ "unexpected denials"; cat "$EVIDENCE/denials.txt"; fi

cp -r "$RESULTS" "$EVIDENCE/" 2>/dev/null || true
echo
[ "$FAIL" -eq 0 ] && echo "SPIKE SMOKE: ALL PASS" || echo "SPIKE SMOKE: FAILURES"
exit "$FAIL"
```

- [ ] **Step 3: Make executable and run against the installed scaffold**

```bash
chmod +x tests/spike-smoke.sh
sudo tests/spike-smoke.sh
```
Expected: `PASS: snap install`, `PASS: svc-a active`, `PASS: no unexpected AppArmor denials`, `SPIKE SMOKE: ALL PASS`.

- [ ] **Step 4: Commit**

```bash
git add spike/probes/probe_common.py tests/spike-smoke.sh
git commit -m "spike(M0): result plumbing and smoke harness skeleton"
```

---

### Task 3: Probe A3 — daemon ordering chain (svc-a → svc-b → svc-c)

**Files:**
- Create: `spike/probes/svc.py`, `spike/bin/svc-b`, `spike/bin/svc-c`
- Modify: `spike/bin/svc-a`, `spike/snap/snapcraft.yaml`, `tests/spike-smoke.sh`

**Interfaces:**
- Consumes: `write_result` from Task 2.
- Produces: `svc.py <service-name>` — records `ordering-<service-name>.json` with `start_monotonic`, runs probes registered in `PROBES: dict[str, list[tuple[str, callable]]]`, then idles. Tasks 4–9 register probes by editing the `PROBES` dict and imports in `svc.py`.

- [ ] **Step 1: Add failing smoke assertions first** (insert above the denial-scan marker):

```bash
check "svc-b active" sh -c "snap services $SNAP_NAME.svc-b | grep -q ' active'"
check "svc-c active" sh -c "snap services $SNAP_NAME.svc-c | grep -q ' active'"
TA=$(jqr ordering-svc-a '.start_monotonic'); TB=$(jqr ordering-svc-b '.start_monotonic'); TC=$(jqr ordering-svc-c '.start_monotonic')
check "ordering: svc-a < svc-b < svc-c" awk -v a="$TA" -v b="$TB" -v c="$TC" 'BEGIN{exit !(a<b && b<c)}'
```

Run: `sudo tests/spike-smoke.sh --skip-install` — Expected: the three new checks FAIL (services don't exist yet).

- [ ] **Step 2: Write `spike/probes/svc.py`**

```python
#!/usr/bin/env python3
"""Spike stub daemon: records start time, runs its probes, then idles."""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probe_common import write_result

PROBES = {}  # service-name -> [(result_name, probe_fn)] — filled by later tasks


def main() -> None:
    name = sys.argv[1]
    write_result(f"ordering-{name}", {
        "service": name,
        "start_monotonic": time.clock_gettime(time.CLOCK_MONOTONIC),
    })
    for result_name, fn in PROBES.get(name, []):
        try:
            write_result(result_name, fn())
        except Exception as e:  # a probe must never kill the daemon
            write_result(result_name, {"status": "crashed",
                                       "error": f"{type(e).__name__}: {e}"})
    while True:
        time.sleep(60)


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Rewrite the three wrappers** (all three files identical except the final argument):

`spike/bin/svc-a`:
```sh
#!/bin/sh
exec "$SNAP/usr/bin/python3" "$SNAP/probes/svc.py" svc-a
```
`spike/bin/svc-b`: same with `svc-b`. `spike/bin/svc-c`: same with `svc-c`. Then `chmod +x spike/bin/svc-*`.

- [ ] **Step 4: Add the chained apps to `snapcraft.yaml`** (replace the `apps:` block):

```yaml
apps:
  svc-a:
    command: bin/svc-a
    daemon: simple
    restart-condition: never
  svc-b:
    command: bin/svc-b
    daemon: simple
    restart-condition: never
    after: [svc-a]
  svc-c:
    command: bin/svc-c
    daemon: simple
    restart-condition: never
    after: [svc-b]
```

- [ ] **Step 5: Rebuild, reinstall, run smoke to green**

```bash
cd spike && snapcraft pack && cd ..
sudo tests/spike-smoke.sh
```
Expected: all checks PASS including `ordering: svc-a < svc-b < svc-c`.
FINDING to note for M1+: `after:` orders *unit start* only — simple daemons give no readiness gating; the real stack needs readiness handling (record in Task 13).

- [ ] **Step 6: Commit**

```bash
git add spike/ tests/spike-smoke.sh
git commit -m "spike(M0): probe A3 - three chained daemons prove after: ordering"
```

---

### Task 4: Probe A1 — /dev/shm psm_* vs snap-prefixed names

**Files:**
- Create: `spike/probes/probe_platform.py`
- Modify: `spike/probes/svc.py` (register probe), `tests/spike-smoke.sh`

**Interfaces:**
- Consumes: `PROBES` registry from Task 3.
- Produces: `shm_probe() -> dict` in `probe_platform.py`; result `shm.json` with keys `default_name` and `snap_prefixed`, each `{"ok": bool, ...}`.

- [ ] **Step 1: Add smoke assertions (evidence-completeness, not hypothesis)** above the marker:

```bash
check "shm probe complete" test "$(jqr shm '.status')" = "complete"
check "shm probe has both sub-results" test "$(jqr shm '.default_name.ok, .snap_prefixed.ok' | wc -l)" = "2"
echo "  shm finding: default(psm_*) ok=$(jqr shm '.default_name.ok') err=$(jqr shm '.default_name.error // "-"')"
echo "  shm finding: snap-prefixed ok=$(jqr shm '.snap_prefixed.ok') err=$(jqr shm '.snap_prefixed.error // "-"')"
```

Run: `sudo tests/spike-smoke.sh --skip-install` — Expected: both new checks FAIL (`shm.json` missing).

- [ ] **Step 2: Write `spike/probes/probe_platform.py`**

```python
"""Platform probes: shared memory and layout behavior under strict confinement."""
import os


def shm_probe() -> dict:
    from multiprocessing import shared_memory
    out = {"status": "complete"}
    inst = os.environ.get("SNAP_INSTANCE_NAME", "frigate")

    # Sub-test 1: CPython default name (/dev/shm/psm_*) — Frigate's current behavior.
    try:
        m = shared_memory.SharedMemory(create=True, size=1024 * 1024)
        out["default_name"] = {"ok": True, "name": m.name}
        m.close()
        m.unlink()
    except Exception as e:
        out["default_name"] = {"ok": False, "error": f"{type(e).__name__}: {e}"}

    # Sub-test 2: snapd-conformant name (/dev/shm/snap.<instance>.*) — the candidate fix.
    try:
        m = shared_memory.SharedMemory(create=True, size=1024 * 1024,
                                       name=f"snap.{inst}.spike-probe")
        out["snap_prefixed"] = {"ok": True, "name": m.name}
        m.close()
        m.unlink()
    except Exception as e:
        out["snap_prefixed"] = {"ok": False, "error": f"{type(e).__name__}: {e}"}

    return out
```

- [ ] **Step 3: Register in `svc.py`** — replace the `PROBES = {}` line with:

```python
import probe_platform

PROBES = {
    "svc-a": [("shm", probe_platform.shm_probe)],
}
```

- [ ] **Step 4: Rebuild, reinstall, run smoke**

```bash
cd spike && snapcraft pack && cd ..
sudo tests/spike-smoke.sh
```
Expected: `shm probe complete` PASS. Expected finding (per research): `default_name.ok=false` with a PermissionError, a matching `psm_` AppArmor denial in the (allowlisted) denial log, and `snap_prefixed.ok=true`. **If `default_name.ok=true`, that is a major positive finding (snapd/core26 relaxed the rule) — record it verbatim; do not treat as failure.**

- [ ] **Step 5: Commit**

```bash
git add spike/probes/ tests/spike-smoke.sh
git commit -m "spike(M0): probe A1 - /dev/shm psm_ vs snap-prefixed naming under AppArmor"
```

---

### Task 5: Probe A2 (safe set) — layouts for /config and /etc/letsencrypt

**Files:**
- Modify: `spike/snap/snapcraft.yaml` (add `layout:`), `spike/probes/probe_platform.py` (add `layout_probe`), `spike/probes/svc.py`, `tests/spike-smoke.sh`

**Interfaces:**
- Produces: `layout_probe() -> dict`; result `layout.json` with `writes: {<abs-path>: {"ok": bool, "token": str}}`. Task 6 extends `LAYOUT_TEST_PATHS`.

- [ ] **Step 1: Add smoke assertions** above the marker:

```bash
TOK=$(jqr layout '.writes."/config/probe.txt".token')
check "layout probe complete" test "$(jqr layout '.status')" = "complete"
check "layout: /config -> SNAP_DATA" grep -q "$TOK" /var/snap/$SNAP_NAME/current/config/probe.txt
check "layout: /etc/letsencrypt -> SNAP_DATA" grep -q "$TOK" /var/snap/$SNAP_NAME/current/letsencrypt/probe.txt
check "private /tmp/cache holds token" sh -c "grep -rq '$TOK' /tmp/snap-private-tmp/snap.$SNAP_NAME/tmp/cache/ 2>/dev/null"
```

Run: `sudo tests/spike-smoke.sh --skip-install` — Expected: new checks FAIL.

- [ ] **Step 2: Add layouts to `snapcraft.yaml`** (top level, after `confinement:`):

```yaml
layout:
  /config:
    bind: $SNAP_DATA/config
  /etc/letsencrypt:
    bind: $SNAP_DATA/letsencrypt
```

- [ ] **Step 3: Add `layout_probe` to `probe_platform.py`**

```python
import time

LAYOUT_TEST_PATHS = [
    "/config/probe.txt",
    "/etc/letsencrypt/probe.txt",
    "/tmp/cache/probe.txt",
]


def layout_probe() -> dict:
    out = {"status": "complete", "writes": {}}
    token = f"spike-{int(time.time())}"
    for path in LAYOUT_TEST_PATHS:
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(token)
            out["writes"][path] = {"ok": True, "token": token,
                                   "realpath": os.path.realpath(path)}
        except Exception as e:
            out["writes"][path] = {"ok": False, "error": f"{type(e).__name__}: {e}"}
    return out
```

- [ ] **Step 4: Register on svc-b in `svc.py`**:

```python
PROBES = {
    "svc-a": [("shm", probe_platform.shm_probe)],
    "svc-b": [("layout", probe_platform.layout_probe)],
}
```

- [ ] **Step 5: Rebuild, reinstall, smoke to green; commit**

```bash
cd spike && snapcraft pack && cd .. && sudo tests/spike-smoke.sh
git add spike/ tests/spike-smoke.sh
git commit -m "spike(M0): probe A2 - safe layouts (/config, /etc/letsencrypt) + private /tmp"
```

---

### Task 6: Probe A2 (risky) — /media/frigate layout

snapd documentation suggests layouts under `/media` may be forbidden. This task finds out. **Both outcomes are findings.**

**Files:**
- Modify: `spike/snap/snapcraft.yaml`, `spike/probes/probe_platform.py`, `tests/spike-smoke.sh` (branch-dependent)

- [ ] **Step 1: Add the layout stanza** under `layout:`:

```yaml
  /media/frigate:
    bind: $SNAP_COMMON/media/frigate
```

And append to `LAYOUT_TEST_PATHS` in `probe_platform.py`: `"/media/frigate/probe.txt",`

- [ ] **Step 2: Rebuild and attempt install — capture the outcome verbatim**

```bash
cd spike && snapcraft pack && cd ..
sudo snap install --dangerous spike/frigate_0.0.1-spike_amd64.snap 2>&1 | tee spike/results/media-layout-install.txt
```

- [ ] **Step 3 (Branch A — install succeeded):** add smoke assertion above the marker and run to green:

```bash
check "layout: /media/frigate -> SNAP_COMMON" sh -c "grep -q \"\$(jqr layout '.writes.\"/media/frigate/probe.txt\".token')\" /var/snap/$SNAP_NAME/common/media/frigate/probe.txt"
```

- [ ] **Step 3 (Branch B — install rejected):** the error text in `spike/results/media-layout-install.txt` is the finding. Revert the yaml stanza and the `LAYOUT_TEST_PATHS` entry, rebuild, reinstall, confirm smoke green again. Implication to record in Task 13: recordings dir cannot be layout-remapped from `/media/frigate`; M3 must patch Frigate's `BASE_DIR` (or set it via config) to a `$SNAP_COMMON` path directly.

- [ ] **Step 4: Run full smoke, then commit (either branch)**

```bash
sudo tests/spike-smoke.sh
git add spike/ tests/spike-smoke.sh
git commit -m "spike(M0): probe A2 - /media/frigate layout outcome recorded"
```

---

### Task 7: Probe B1 — Python 3.11 built on the core26 toolchain

**Files:**
- Modify: `spike/snap/snapcraft.yaml` (add `python311` part), `spike/bin/svc-{a,b,c}` (switch interpreter), `spike/probes/probe_runtime.py` (create), `spike/probes/svc.py`, `tests/spike-smoke.sh`

**Interfaces:**
- Produces: interpreter at `$SNAP/usr/bin/python3.11` with pip; `runtime_probe() -> dict` → `runtime.json` with `version_major_minor: "3.11"`. All later probe apps use `python3.11`.

- [ ] **Step 1: Add smoke assertion** above the marker:

```bash
check "daemons run on python 3.11" test "$(jqr runtime '.version_major_minor')" = "3.11"
```
Run `sudo tests/spike-smoke.sh --skip-install` — Expected: FAIL.

- [ ] **Step 2: Add the `python311` part** to `parts:` (build takes ~10-20 min; **compiler errors here are themselves the B1 finding** — capture them verbatim to `spike/results/python311-build-error.txt` before attempting fixes):

```yaml
  python311:
    plugin: nil
    source: https://www.python.org/ftp/python/3.11.9/Python-3.11.9.tgz
    build-packages:
      - build-essential
      - pkg-config
      - libssl-dev
      - zlib1g-dev
      - libffi-dev
      - libsqlite3-dev
      - libbz2-dev
      - liblzma-dev
      - libreadline-dev
      - uuid-dev
    override-build: |
      ./configure --prefix=/usr --enable-shared --with-ensurepip=install \
        LDFLAGS="-Wl,-rpath,/snap/frigate/current/usr/lib"
      make -j"$(nproc)"
      make install DESTDIR="$CRAFT_PART_INSTALL"
```

- [ ] **Step 3: Create `spike/probes/probe_runtime.py`**

```python
"""Runtime probes: interpreter identity, wheel imports, native-lib loading."""
import sys


def runtime_probe() -> dict:
    return {
        "status": "complete",
        "version_major_minor": f"{sys.version_info[0]}.{sys.version_info[1]}",
        "version_full": sys.version,
        "executable": sys.executable,
    }
```

- [ ] **Step 4: Register on svc-c and switch wrappers**

In `svc.py`:
```python
import probe_platform
import probe_runtime

PROBES = {
    "svc-a": [("shm", probe_platform.shm_probe)],
    "svc-b": [("layout", probe_platform.layout_probe)],
    "svc-c": [("runtime", probe_runtime.runtime_probe)],
}
```
In each `spike/bin/svc-*`, change the interpreter path (example svc-a; same edit in all three):
```sh
#!/bin/sh
exec "$SNAP/usr/bin/python3.11" "$SNAP/probes/svc.py" svc-a
```

- [ ] **Step 5: Rebuild, reinstall, full smoke to green (re-validates A1/A2 on 3.11); commit**

```bash
cd spike && snapcraft pack && cd .. && sudo tests/spike-smoke.sh
git add spike/ tests/spike-smoke.sh
git commit -m "spike(M0): probe B1 - Python 3.11.9 builds on core26; daemons switched to it"
```

---

### Task 8: Probe B2 — Frigate's pinned wheels import on core26

**Files:**
- Create: `spike/probes/requirements-spike.txt`
- Modify: `spike/snap/snapcraft.yaml` (add `spike-wheels` part), `spike/probes/probe_runtime.py`, `spike/probes/svc.py`, `tests/spike-smoke.sh`

**Interfaces:**
- Produces: site-packages at `$SNAP/usr/lib/python3.11/site-packages` (native to the built interpreter — no PYTHONPATH needed); `imports_probe() -> dict` → `imports.json` with per-module `{"ok": bool, "version": str}` for numpy, cv2, onnxruntime, tflite_runtime, tensorflow, openvino.

- [ ] **Step 1: Add smoke assertions** above the marker:

```bash
for MOD in numpy cv2 onnxruntime tflite_runtime tensorflow openvino; do
  check "import $MOD" test "$(jqr imports ".imports.$MOD.ok")" = "true"
done
```
Run `--skip-install`: Expected FAIL ×6.

- [ ] **Step 2: Extract the exact upstream pins.** Clone upstream (scratchpad, shallow) and copy the matching requirement lines **verbatim** into `spike/probes/requirements-spike.txt`:

```bash
SCRATCH=/tmp/claude-1000/-home-joachimmgg-Development-giaever-online-iot-frigate/0dd7cb9e-369c-4a10-9fed-1ecbe74c6a05/scratchpad
git clone --depth 1 --branch v0.17.2 https://github.com/blakeblackshear/frigate "$SCRATCH/frigate-v0172" 2>/dev/null || true
grep -E '^(numpy|opencv-python-headless|opencv-contrib-python|onnxruntime|tensorflow|tflite|openvino)' \
  "$SCRATCH/frigate-v0172/docker/main/requirements-wheels.txt"
```
Copy the output lines into `spike/probes/requirements-spike.txt` exactly as printed (keep any environment markers and direct-URL wheel references, e.g. the custom `tflite_runtime` cp311 wheel URL). This file must contain real pins — no placeholders.

- [ ] **Step 3: Add the `spike-wheels` part**

```yaml
  spike-wheels:
    plugin: nil
    after: [python311]
    source: probes
    override-build: |
      export LD_LIBRARY_PATH="$CRAFT_STAGE/usr/lib:${LD_LIBRARY_PATH:-}"
      "$CRAFT_STAGE/usr/bin/python3.11" -m pip install --no-cache-dir \
        --root "$CRAFT_PART_INSTALL" --prefix /usr \
        -r requirements-spike.txt
```

- [ ] **Step 4: Add `imports_probe` to `probe_runtime.py` and register it**

```python
def imports_probe() -> dict:
    out = {"status": "complete", "imports": {}}
    for mod in ("numpy", "cv2", "onnxruntime", "tflite_runtime",
                "tensorflow", "openvino"):
        try:
            m = __import__(mod)
            out["imports"][mod] = {"ok": True,
                                   "version": getattr(m, "__version__", "?")}
        except Exception as e:
            out["imports"][mod] = {"ok": False,
                                   "error": f"{type(e).__name__}: {e}"}
    return out
```
In `svc.py`, extend svc-c:
```python
    "svc-c": [("runtime", probe_runtime.runtime_probe),
              ("imports", probe_runtime.imports_probe)],
```

- [ ] **Step 5: Rebuild (`snapcraft clean spike-wheels` if re-running), reinstall, smoke to green; commit**

```bash
cd spike && snapcraft pack && cd .. && sudo tests/spike-smoke.sh
git add spike/ tests/spike-smoke.sh
git commit -m "spike(M0): probe B2 - upstream-pinned cp311 wheels import on core26"
```
Any import failure: record the exact error in the JSON — that is the finding (likely candidates: glibc symbol, missing shared lib → note which).

---

### Task 9: Probe B3 — bookworm libedgetpu loads on core26

**Files:**
- Modify: `spike/snap/snapcraft.yaml` (add `libedgetpu` part), `spike/probes/probe_runtime.py`, `spike/probes/svc.py`, `tests/spike-smoke.sh`

**Interfaces:**
- Produces: `$SNAP/usr/lib/x86_64-linux-gnu/libedgetpu.so.1` + staged `libusb-1.0-0`; `edgetpu_dlopen_probe() -> dict` → `edgetpu-dlopen.json` `{"dlopen": {"ok": bool}}`. Task 11 reuses the staged library.

- [ ] **Step 1: Add smoke assertion** above the marker (evidence-completeness):

```bash
check "edgetpu dlopen probe complete" test "$(jqr edgetpu-dlopen '.status')" = "complete"
echo "  edgetpu finding: dlopen ok=$(jqr edgetpu-dlopen '.dlopen.ok') err=$(jqr edgetpu-dlopen '.dlopen.error // "-"')"
```

- [ ] **Step 2: Discover and pin the .deb URL.** List the release assets, pick the `libedgetpu1-max` **bookworm amd64** asset for version `16.0TF2.17.1-1` (the version Frigate v0.17.2's Dockerfile installs):

```bash
curl -s https://api.github.com/repos/feranick/libedgetpu/releases?per_page=10 \
  | jq -r '.[].assets[].browser_download_url' | grep -i 'max.*bookworm.*amd64'
```
Paste the chosen URL into the part below, replacing `<PASTE-DEB-URL>` — the yaml committed at the end of this task must contain the real URL.

- [ ] **Step 3: Add the `libedgetpu` part**

```yaml
  libedgetpu:
    plugin: nil
    build-packages: [wget]
    stage-packages: [libusb-1.0-0]
    override-build: |
      wget -O /tmp/libedgetpu.deb "<PASTE-DEB-URL>"
      dpkg-deb -x /tmp/libedgetpu.deb "$CRAFT_PART_INSTALL"
```

- [ ] **Step 4: Add the probe and register on svc-c**

In `probe_runtime.py`:
```python
import ctypes
import os


def edgetpu_dlopen_probe() -> dict:
    out = {"status": "complete"}
    lib = os.path.join(os.environ.get("SNAP", ""),
                       "usr/lib/x86_64-linux-gnu/libedgetpu.so.1")
    out["lib_path"] = lib
    out["lib_exists"] = os.path.exists(lib)
    try:
        ctypes.CDLL(lib)
        out["dlopen"] = {"ok": True}
    except OSError as e:
        out["dlopen"] = {"ok": False, "error": str(e)}
    return out
```
In `svc.py`, extend svc-c:
```python
    "svc-c": [("runtime", probe_runtime.runtime_probe),
              ("imports", probe_runtime.imports_probe),
              ("edgetpu-dlopen", probe_runtime.edgetpu_dlopen_probe)],
```

- [ ] **Step 5: Rebuild, reinstall, smoke; commit**

```bash
cd spike && snapcraft pack && cd .. && sudo tests/spike-smoke.sh
git add spike/ tests/spike-smoke.sh
git commit -m "spike(M0): probe B3 - bookworm libedgetpu dlopen outcome on core26"
```

---

### Task 10: Probe C1 — GPU via the gpu extension (vainfo + OpenVINO)

**Files:**
- Create: `spike/probes/probe_gpu.py`, `spike/bin/gpu-probe`
- Modify: `spike/snap/snapcraft.yaml` (app + `va-tools` part), `tests/spike-smoke.sh`

**Interfaces:**
- Consumes: `openvino` wheel (Task 8), `write_result` (Task 2).
- Produces: command app `frigate.gpu-probe`; results `gpu.json` (`openvino_devices: [...]`, `render_node_access`) and `spike/results/vainfo.txt`; `spike/results/expanded-snapcraft.yaml` documenting what the extension injects.

- [ ] **Step 1: Add smoke section** above the marker:

```bash
snap install mesa-2604 2>/dev/null || true
snap connect $SNAP_NAME:gpu-2604 mesa-2604:gpu-2604 2>/dev/null || true
snap connections $SNAP_NAME > "$EVIDENCE/connections.txt"
snap run $SNAP_NAME.gpu-probe || true
check "gpu probe complete" test "$(jqr gpu '.status')" = "complete"
check "openvino sees GPU" sh -c "jqr gpu '.openvino_devices[]' | grep -q GPU"
check "vainfo produced output" test -s /var/snap/$SNAP_NAME/common/spike-results/vainfo.txt
cp /var/snap/$SNAP_NAME/common/spike-results/vainfo.txt "$EVIDENCE/" 2>/dev/null || true
```
Run `--skip-install`: Expected FAIL (app missing).

- [ ] **Step 2: Add the app and `va-tools` part to `snapcraft.yaml`**

```yaml
  gpu-probe:
    command: bin/gpu-probe
    extensions: [gpu]
    plugs: [opengl]
```
(under `parts:`)
```yaml
  va-tools:
    plugin: nil
    stage-packages: [vainfo]
```

- [ ] **Step 3: Capture what the extension actually injects**

```bash
cd spike && snapcraft expand-extensions > results/expanded-snapcraft.yaml; cd ..
grep -A5 'gpu-2604\|graphics' spike/results/expanded-snapcraft.yaml
```
Verify the plug name the extension adds (expected `gpu-2604`, default-provider `mesa-2604`). If it differs, adjust the two `snap connect`/assertion lines in the smoke section to the real name — the expanded yaml is authoritative.

- [ ] **Step 4: Write `spike/bin/gpu-probe` and `spike/probes/probe_gpu.py`**

`spike/bin/gpu-probe` (then `chmod +x`):
```sh
#!/bin/sh
mkdir -p "$SNAP_COMMON/spike-results"
vainfo --display drm --device /dev/dri/renderD128 \
  > "$SNAP_COMMON/spike-results/vainfo.txt" 2>&1
exec "$SNAP/usr/bin/python3.11" "$SNAP/probes/probe_gpu.py"
```

`spike/probes/probe_gpu.py`:
```python
#!/usr/bin/env python3
"""C1: which GPU devices does a strict snap reach (OpenVINO + render nodes)?"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probe_common import write_result

out = {"status": "complete", "render_node_access": {}}
try:
    from openvino import Core
    out["openvino_devices"] = Core().available_devices
except Exception as e:
    out["openvino_devices"] = []
    out["openvino_error"] = f"{type(e).__name__}: {e}"

for node in ("/dev/dri/renderD128", "/dev/dri/card1"):
    try:
        fd = os.open(node, os.O_RDWR)
        os.close(fd)
        out["render_node_access"][node] = "ok"
    except OSError as e:
        out["render_node_access"][node] = f"errno={e.errno} {e.strerror}"

write_result("gpu", out)
```

- [ ] **Step 5: Rebuild, reinstall, smoke; commit**

```bash
cd spike && snapcraft pack && cd .. && sudo tests/spike-smoke.sh
git add spike/ tests/spike-smoke.sh
git commit -m "spike(M0): probe C1 - gpu extension wiring, vainfo + OpenVINO GPU enumeration"
```
Expected on this host: `vainfo.txt` lists the iHD driver/Meteor Lake profiles; `openvino_devices` contains `CPU` and `GPU`. Record deviations verbatim (e.g. missing `LIBVA_DRIVERS_PATH` → that's the "not turn-key" finding).

---

### Task 11: Probe C2 — Coral USB under raw-usb, incl. firmware re-enumeration

**Files:**
- Create: `spike/probes/probe_coral.py`, `spike/bin/coral-probe`
- Modify: `spike/snap/snapcraft.yaml` (app + `coral-model` part), `tests/spike-smoke.sh`

**Interfaces:**
- Consumes: `libedgetpu.so.1` + `libusb-1.0-0` (Task 9), `tflite_runtime` + `numpy` (Task 8).
- Produces: command app `frigate.coral-probe`; result `coral.json` (`load_delegate`, `inference`); host evidence `coral-usb-before.txt`/`coral-usb-after.txt`.

- [ ] **Step 1: Add smoke section** above the marker:

```bash
snap connect $SNAP_NAME:raw-usb 2>/dev/null || true
lsusb | grep -Ei '1a6e|18d1' > "$EVIDENCE/coral-usb-before.txt" || true
snap run $SNAP_NAME.coral-probe || true
sleep 3
lsusb | grep -Ei '1a6e|18d1' > "$EVIDENCE/coral-usb-after.txt" || true
check "coral probe complete" test "$(jqr coral '.status')" = "complete"
check "coral delegate loaded (firmware upload)" test "$(jqr coral '.load_delegate.ok')" = "true"
check "coral inference ran" test "$(jqr coral '.inference.ok')" = "true"
check "coral re-enumerated as Google (18d1)" grep -q 18d1 "$EVIDENCE/coral-usb-after.txt"
```
Note: `snap run` here executes as root (the harness runs under sudo) — required, since the device node is root-writable and `raw-usb` does not bypass file permissions.

- [ ] **Step 2: Add the app and test-model part**

```yaml
  coral-probe:
    command: bin/coral-probe
    plugs: [raw-usb, hardware-observe]
```
```yaml
  coral-model:
    plugin: nil
    build-packages: [wget]
    override-build: |
      mkdir -p "$CRAFT_PART_INSTALL/models"
      wget -O "$CRAFT_PART_INSTALL/models/edgetpu-test.tflite" \
        https://github.com/google-coral/test_data/raw/master/mobilenet_v2_1.0_224_inat_bird_quant_edgetpu.tflite
```

- [ ] **Step 3: Write the wrapper and probe**

`spike/bin/coral-probe` (then `chmod +x`):
```sh
#!/bin/sh
exec "$SNAP/usr/bin/python3.11" "$SNAP/probes/probe_coral.py"
```

`spike/probes/probe_coral.py`:
```python
#!/usr/bin/env python3
"""C2: Coral USB under raw-usb — delegate load triggers firmware upload and
re-enumeration (1a6e:089a -> 18d1:9302); inference proves the reborn node is usable."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probe_common import write_result

out = {"status": "complete"}
snap = os.environ.get("SNAP", "")
lib = os.path.join(snap, "usr/lib/x86_64-linux-gnu/libedgetpu.so.1")
model = os.path.join(snap, "models/edgetpu-test.tflite")

try:
    import tflite_runtime.interpreter as tflite
    delegate = tflite.load_delegate(lib)
    out["load_delegate"] = {"ok": True}
except Exception as e:
    out["load_delegate"] = {"ok": False, "error": f"{type(e).__name__}: {e}"}
    write_result("coral", out)
    sys.exit(0)

try:
    import numpy as np
    interp = tflite.Interpreter(model_path=model,
                                experimental_delegates=[delegate])
    interp.allocate_tensors()
    detail = interp.get_input_details()[0]
    interp.set_tensor(detail["index"],
                      np.zeros(detail["shape"], dtype=detail["dtype"]))
    interp.invoke()
    out["inference"] = {"ok": True}
except Exception as e:
    out["inference"] = {"ok": False, "error": f"{type(e).__name__}: {e}"}

write_result("coral", out)
```

- [ ] **Step 4: Rebuild, reinstall, smoke; commit**

```bash
cd spike && snapcraft pack && cd .. && sudo tests/spike-smoke.sh
git add spike/ tests/spike-smoke.sh
git commit -m "spike(M0): probe C2 - Coral USB delegate load + re-enumeration under raw-usb"
```
A `load_delegate` failure with `Failed to load delegate` / libusb open error is the negative finding — capture `coral.json` + the denial log; do not debug beyond confirming the error is access-related.

---

### Task 12: Probe C3 — NPU via custom-device (TIMEBOXED: ~2h, then defer)

**Files:**
- Create: `spike/probes/probe_npu.py`, `spike/bin/npu-probe`
- Modify: `spike/snap/snapcraft.yaml` (slot + plug + app), `tests/spike-smoke.sh`

**Interfaces:**
- Produces: result `npu.json` (`open_accel0: {"ok": bool}`) or a recorded install/connect refusal — all three failure shapes are valid findings.

- [ ] **Step 1: Add the custom-device slot, plug, and app to `snapcraft.yaml`**

Top level (after `plugs:`-less spike this is new):
```yaml
slots:
  npu-dev:
    interface: custom-device
    custom-device: intel-npu
    devices:
      - /dev/accel/accel0

plugs:
  npu:
    interface: custom-device
    custom-device: intel-npu
```
App:
```yaml
  npu-probe:
    command: bin/npu-probe
    plugs: [npu]
```

- [ ] **Step 2: Write wrapper and probe**

`spike/bin/npu-probe` (then `chmod +x`):
```sh
#!/bin/sh
exec "$SNAP/usr/bin/python3.11" "$SNAP/probes/probe_npu.py"
```

`spike/probes/probe_npu.py`:
```python
#!/usr/bin/env python3
"""C3: can a strict snap on classic Ubuntu reach /dev/accel/accel0 via a
self-provided custom-device slot? Device-node access only (driver stack out of scope)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probe_common import write_result

out = {"status": "complete"}
try:
    fd = os.open("/dev/accel/accel0", os.O_RDWR)
    os.close(fd)
    out["open_accel0"] = {"ok": True}
except OSError as e:
    out["open_accel0"] = {"ok": False, "errno": e.errno, "error": e.strerror}
write_result("npu", out)
```

- [ ] **Step 3: Add smoke section** above the marker:

```bash
snap connect $SNAP_NAME:npu $SNAP_NAME:npu-dev 2> "$EVIDENCE/npu-connect.txt" || true
snap run $SNAP_NAME.npu-probe 2>> "$EVIDENCE/npu-connect.txt" || true
check "npu probe produced evidence" sh -c "test -s $RESULTS/npu.json -o -s $EVIDENCE/npu-connect.txt"
echo "  npu finding: open=$(jqr npu '.open_accel0.ok // "no-json"') connect-err=$(head -c120 "$EVIDENCE/npu-connect.txt" 2>/dev/null)"
```

- [ ] **Step 4: Rebuild, attempt install + connect, record whichever branch occurs**

```bash
cd spike && snapcraft pack && cd ..
sudo tests/spike-smoke.sh 2>&1 | tee spike/results/npu-run.txt
```
Branches (each a finding): (a) install rejected (super-privileged slot refused on --dangerous) → record stderr, remove slot/plug/app, rebuild, confirm smoke green; (b) install OK but connect refused → record; (c) connect OK but open denied → record errno; (d) open OK → custom-device works on classic Ubuntu (major positive finding, unblocks Coral-PCIe path).
**Timebox: if not conclusively in one branch within ~2 hours, record `deferred` and revert to the last green state.**

- [ ] **Step 5: Commit**

```bash
git add spike/ tests/spike-smoke.sh
git commit -m "spike(M0): probe C3 - custom-device /dev/accel experiment outcome"
```

---

### Task 13: Findings document + wrap-up

**Files:**
- Create: `docs/spike-findings.md`
- Modify: none (evidence read from `spike/results/` and `/var/snap/frigate/common/spike-results/`)

- [ ] **Step 1: Run the full harness one final time on a clean install**

```bash
sudo tests/spike-smoke.sh 2>&1 | tee spike/results/final-run.txt
```
Expected: ALL PASS (with branch-dependent Task 6/12 assertions as committed).

- [ ] **Step 2: Write `docs/spike-findings.md`** using this structure, populated from the JSON evidence — every verdict must cite its evidence file. No section may be left empty; write "not tested: <reason>" where applicable.

```markdown
# M0 Spike Findings — Frigate snap de-risking

**Date:** <run date>  **Host:** Ubuntu 24.04, snapd 2.75.2, snapcraft 9.0, core26 rev <snap info core26>

| # | Question | Verdict | Evidence |
|---|----------|---------|----------|
| A1 | psm_* shm denied? snap.* prefix works? | <yes/no> | spike/results/spike-results/shm.json, denials.txt |
| A2 | /config + /etc/letsencrypt layouts work? | <yes/no> | layout.json |
| A2b | /media/frigate layout allowed? | <yes/no> | media-layout-install.txt |
| A3 | after: ordering holds? readiness gap noted | <yes/no> | ordering-*.json |
| B1 | Python 3.11.9 builds on core26 toolchain? | <yes/no> | build log / python311-build-error.txt |
| B2 | upstream cp311 wheels import? | <n/6 ok> | imports.json |
| B3 | bookworm libedgetpu dlopens? | <yes/no> | edgetpu-dlopen.json |
| C1 | vainfo + OpenVINO see the iGPU? | <yes/no> | vainfo.txt, gpu.json |
| C2 | Coral delegate+inference under raw-usb, re-enum survives? | <yes/no> | coral.json, coral-usb-*.txt |
| C3 | custom-device reaches /dev/accel on classic? | <branch a-d> | npu-connect.txt, npu.json |

## Decisions unlocked
- **core26 GO/NO-GO:** <based on B1+B2+B3>
- **shm fix shape for M3:** <patch source name-prefix / shim / upstream> — based on A1
- **recordings dir strategy:** <layout vs BASE_DIR patch> — based on A2b
- **device interface matrix for the real snapcraft.yaml:** <from C1-C3>
- **readiness handling for M1+ daemons:** <from A3>

## Raw evidence
<one line per file in spike/results/>

## Deviations from expectations
<anything that contradicted docs/snap-feasibility.md — these feed corrections back into that doc>
```

- [ ] **Step 3: Commit and close M0**

```bash
git add docs/spike-findings.md
git commit -m "spike(M0): findings - core26/shm/layout/device verdicts for M1+ planning"
```

---

## Self-Review (run after writing, fixed inline)

1. **Spec coverage:** A1 shm (Task 4), A2 layouts (5, 6), A3 ordering (3), B1 py3.11 (7), B2 wheels (8), B3 libedgetpu (9), C1 GPU (10), C2 Coral (11), C3 NPU timeboxed (12), findings doc exit criterion (13). Spec's "avahi-observe verified in spike" is NOT covered — deliberately deferred to M1 where go2rtc gives it a real workload (recorded as an open item for the findings doc).
2. **Placeholder scan:** one intentional `<PASTE-DEB-URL>` in Task 9 with an explicit discovery step and the instruction that the committed yaml must contain the real URL; findings template placeholders are the deliverable's fill-in points, not plan gaps.
3. **Type consistency:** `write_result(name, data)` used identically in Tasks 2–12; `PROBES` registry shape `{svc: [(result_name, fn)]}` consistent across 3, 4, 5, 7, 8, 9; result names (`shm`, `layout`, `ordering-svc-*`, `runtime`, `imports`, `edgetpu-dlopen`, `gpu`, `coral`, `npu`) match between probes and `jqr` calls.
