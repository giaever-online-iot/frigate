# M2 Findings — Frigate source, core wheels, ffmpeg matrix, VAAPI

**Date:** 2026-07-04  **Snap:** frigate 0.0.1-spike (core26, strict), 1.11 GB  **Frigate:** v0.17.2 (patched)

| # | Question | Verdict | Evidence |
|---|----------|---------|----------|
| M2-1 | ffmpeg matrix tag-exact (n5.1 + n7.0.2, default 7.0) + kept n8.1.1? | YES — three trees present; tag-exact n5.1 + n7.0.2; default app retargeted to 7.0; n8.1.1 kept for VAAPI+go2rtc; bzip2-mislabeled-as-xz tarball on 7.0 resolved via `tar` auto-detect | m2-final-run.txt (`PASS: ffprobe app runs tag-default 7.0`, `PASS: ffmpeg tree 5.0/7.0/8.0 present+runs`); task-1-report.md (sha256 hashes, tarball-layout findings) |
| M2-2 | Carried env-paths patch: upstream no-op + env override proven? | YES — 4 independent literals changed (`CONFIG_DIR`, `BASE_DIR`, `CACHE_DIR` env-driven, `BIRDSEYE_PIPE` reordered to derive from `CACHE_DIR`); no-op and override both verified | task-2-report.md (verbatim: no-op → `/config /media/frigate /tmp/cache /config/frigate.db /media/frigate/recordings`; override → `/X /Y /Z /X/frigate.db /Y/recordings`); m2-final-run.txt (`PASS: carried patch applied`) |
| M2-3 | Core wheels (~58) import strict-confined? | YES — 58 core + 7 validate-deps additions import clean under confinement; 1 expected denial arm (matplotlib font-scan via norfair→filterpy, non-blocking); arm narrowed to profile snap.frigate.svc-c + name-anchored to /usr(/local)?/share/fonts/ after review escalation | m2-final-run.txt (all 17 module import PASS); spike/results/spike-results/imports.json (all ok=true); task-3-report.md |
| M2-4 | VAAPI hw decode (no sw fallback) of the synthetic stream? | YES ADJUDICATED — `vaapi(progressive)` pixel-format is dispositive (frames in VAAPI memory); no `-hwupload` in command; `h264 (native)` is a decoder-naming artifact, not a sw-decode indicator; `-hwaccel_output_format vaapi` hard-fails if hw surface is unavailable (rc≠0 path); rc=0 therefore constitutes hw-decode proof | spike/results/vaapi-decode.txt (`vaapi(progressive), 1280x720`, `frame= 30 fps= 27`, `rc=0`); task-4-report.md (adjudication chain, incl. cap denials non-blocking) |
| M2-5 | `frigate.validate-config` exits 0 (real code, real config)? | YES — `__main__.py:39` registers `--validate-config`; line 110 gates the `"Your config file is valid."` print + `sys.exit(0)` path; config template required only `version: "0.17-0"` + `labelmap_path: /opt/frigate/labelmap.txt` (both confinement-driven, not schema-driven) | spike/results/validate-config.txt (tail: `"Your config file is valid."`, rc=0); m2-final-run.txt (`PASS: frigate validate-config exits 0`, `validate finding: rc=0`); task-5-report.md (step 1 code trace: `__main__.py:39,110`) |

---

## Strategic findings

### (a) Frigate-AI companion plan vs. import graph — USER DECISION pending

The original plan deferred 13 wheels (AI/transcription/NVIDIA-only entries) to a future
`frigate-ai` companion content-snap. This plan does not survive Frigate's module-level import
graph.

`__main__.py` imports `from frigate.app import FrigateApp` unconditionally at the top of
`main()`. `frigate.app`'s import chain reaches `embeddings/__init__.py` (imports `regex`),
`data_processing/types.py` (imports `sherpa_onnx.OnlineRecognizer` at module level — a bare
`MagicMock()` causes `AttributeError` at the type-alias evaluation), `data_processing/real_time/
whisper_online.py` (imports `librosa`, `soundfile`), and `api/review.py` (imports `pandas`). These
six fire unconditionally at startup; `faster_whisper` is lazy (inside methods, so the import
boundary holds for that one).

Six entries were therefore re-added to the core snap via the `validate-deps` part with exact
upstream-pin versions. The snap grew from 927 MB (58 wheels, Task 3) to 1.11 GB.

The DEFERRED-frigate-ai.txt file now lists 7 still-deferred entries (mypy, google-genai, ollama,
openai, faster-whisper, degirum, memray).

**Options for the companion-snap plan:**

1. **Accept in core (current state):** Six AI wheels remain in the core snap. No upstream patch
   needed. Snap stays at 1.11 GB. The remaining 7 are genuinely optional (NVIDIA-only, dev, or
   method-level imports only). Clean and shippable immediately.

2. **snap-local lazy-import patch (no upstream involvement):** carry a second downstream patch
   (alongside 0001-env-driven-paths) that wraps the six module-level imports in lazy/deferred
   guards inside the snap build only. Pros: restores the slim core snap + companion-snap
   architecture immediately; no upstream coordination or review latency. Cons: grows the
   carried-patch burden (rebase per release, and import-graph patches are more invasive than
   the const.py env patch); risk of drift from upstream behavior if guards diverge.

3. **Upstream lazy-import patches:** Wrap `frigate/embeddings/__init__.py`, `data_processing/
   types.py`, `data_processing/real_time/whisper_online.py`, and `api/review.py` so those six
   imports are inside guard blocks (`try/except ImportError` or `TYPE_CHECKING` gates). Then the
   six wheels can move back to the companion snap and the core returns to ~927 MB. Requires
   upstream PR and version-tracking discipline.

4. **Hybrid:** Accept sherpa-onnx and librosa/soundfile in core (audio inference) but push pandas
   and transformers back behind a lazy gate (they are the heaviest at ~100 MB combined).

The user decision is required before the companion-snap prototype (planned post-M7).

---

### (b) Shared-memory: `private: true` supersedes M3 shm-prefix plan

The M0-A1 plan was to patch frigate's `SharedMemoryFrameManager` to use a `snap.<name>.*`
prefix for POSIX shared memory names so AppArmor's `/{dev,run}/shm/sem.snap.@{SNAP_INSTANCE_NAME}.*`
rule would match.

This plan was insufficient on its own. During M2 Task 5, the mknod denial revealed the
actual glibc `sem_open(O_CREAT)` sequence:

```
apparmor="DENIED" operation="mknod" class="file" profile="snap.frigate.validate-config"
name="/dev/shm/sem.GlbX9q" pid=... comm="python3.11" requested_mask="c" denied_mask="c"
```

glibc first creates a **random** temporary file (`sem.XXXXXX`) and renames it to the final
semaphore name atomically. No prefix can be applied to the random tempfile, so any name-based
rule (AppArmor or custom sitecustomize prefix) cannot match the creation step.

The canonical fix is `shared-memory` interface with `private: true`, which mounts a private
tmpfs over `/dev/shm` for the entire snap. This solves both `psm_*` (frame-buffer semaphores)
and `sem.*` (glibc random tempfiles) with zero upstream code changes and zero divergence from
the AppArmor model.

Consequence for M3: every daemon app that uses multiprocessing semaphores (including the real
Frigate daemon) must declare `plugs: [shm-private]`. Cross-snap `/dev/shm` sharing (if ever
needed) is incompatible with `private: true`. The private tmpfs uses the system default sizing
(~50% of physical RAM — kernel tmpfs default); M3 must benchmark peak frame-buffer /dev/shm
usage under a live stream to verify the ceiling is adequate.

---

### (c) `network-bind` required even for validation

`__main__.py` calls `mp.set_start_method("forkserver", force=True)` and `mp.Manager()` before
config loading begins. Python's `forkserver` starts a listening Unix-domain socket for the fork
control channel, which triggers `listen(2)`. snapd gates `listen(2)` behind the `network-bind`
plug (seccomp filter, kernel syscall 50). The denial:

```
type=1326 ... subj=snap.frigate.validate-config ... syscall=50 ... code=0x50000
  -> PermissionError: [Errno 1] Operation not permitted (multiprocessing/forkserver.py:141)
```

The production Frigate daemon needs `network-bind` for port 5000/8971 in any case, so this is
not an added surface for production apps. But any validation or testing app that imports
`frigate.app` also needs it.

---

### (d) Layout-rule investigation (refines the M0 mechanism record)

snapd's layout validation (`validate.go`) maintains an explicit allow-list of top-level
directories that can be used as layout source paths. As of snapd 2.75.2:

```
bin, etc, lib, lib64, meta, mnt, opt, root, sbin, snap, srv, usr, var, writable
```

`/media` is NOT on this list, even though it is present in the core26 base snap. Attempting to
create a layout entry with `/media/frigate` as the source (e.g. `layout: /media/frigate:
bind: $SNAP_COMMON/media`) produces the misleading error:

```
"defines a new top-level directory /media"
```

This error is misleading: `/media` already exists in the base, but the error message fires for
any top-level directory not in snapd's allow-list, regardless of whether it exists. The pack
test (`snapcraft pack`) is the only reliable gate; snapd's runtime will also reject it.

An 8-path empirical matrix was tested (snap pack, snapd 2.75.2):

| Path | Result |
|------|--------|
| `/config` | DENIED — "defines a new top-level directory" |
| `/media/frigate` | DENIED — "defines a new top-level directory /media" |
| `/etc/letsencrypt` | ALLOWED — /etc is on the allow-list |
| `/opt/frigate` | ALLOWED — /opt is on the allow-list (used for source staging) |
| `/srv/<new>` | ALLOWED — /srv is on the allow-list |
| `/mnt/<new>` | ALLOWED — /mnt is on the allow-list |
| `/var/<new-subdir>` | ALLOWED — /var is on the allow-list |
| `/tmp/cache` | ALLOWED — handled via `private-tmp` layout mechanism |

Consequence: `/config` and `/media/frigate` cannot be created via layout. The env-patch
(M2-2) is the correct mechanism: `FRIGATE_CONFIG_DIR` and `FRIGATE_BASE_DIR` route Frigate
to `$SNAP_COMMON`-rooted paths. No layout entry is needed or possible for these paths.
`/srv`, `/mnt`, `/opt/<new>`, and `/var/<new-subdir>` are available if future milestones need
additional filesystem anchors.

---

## Carried patch register

| Patch | Introduced | Purpose |
|---|---|---|
| `spike/patches/0001-env-driven-paths.patch` | M2 (v0.17.2) | Make `frigate/const.py` base paths env-overridable (`FRIGATE_CONFIG_DIR`/`FRIGATE_BASE_DIR`/`FRIGATE_CACHE_DIR`; defaults unchanged = upstream no-op). Required because snapd layouts cannot target `/config` or `/media/*`. |

Full register with rebase notes and upstreaming assessment in `docs/patches.md`.

A second patch (shm name prefix for `SharedMemoryFrameManager`) that was planned in M0-A1 is
**superseded** by the `shared-memory: private: true` plug (see strategic finding (b) above);
that patch is no longer planned for M3.

---

## Deferred wheels + frigate-ai plan-of-record

### Original deferred set (13 entries from DEFERRED-frigate-ai.txt)

```
mypy == 1.6.1
git+https://github.com/fbcotter/py3nvml#egg=py3nvml       # re-added to core
pandas == 2.2.*                                             # re-added to core
transformers == 4.45.*                                      # re-added to core
google-genai == 1.58.*
ollama == 0.6.*
openai == 1.65.*
sherpa-onnx==1.12.*                                        # re-added to core
faster-whisper==1.1.*
librosa==0.11.*                                            # re-added to core
soundfile==0.13.*                                          # re-added to core
degirum == 0.16.*
memray == 1.15.*
```

Six re-added to core (validate-deps part, exact pins):
`py3nvml==0.2.7`, `regex==2024.11.6` (not in DEFERRED — transitive direct import),
`sherpa-onnx==1.12.40`, `librosa==0.11.0`, `soundfile==0.13.1`,
`transformers==4.45.2`, `pandas==2.2.3`.

Seven remain deferred: mypy, google-genai, ollama, openai, faster-whisper, degirum, memray.

### Companion content-snap architecture (plan-of-record, pending the user decision above)

The prototype is planned post-M7. The intended architecture follows the `mesa-2604` pattern:

- **Core snap** (`frigate`): ships Python 3.11, all core wheels + the 6 now-re-added wheels.
- **Content snap** (`frigate-ai`): ships the 7 remaining deferred wheels built against cp311
  (same ABI as core — B1 finding confirmed core26 cp311 wheels import clean).
- **PYTHONPATH wiring:** the content snap exposes a `content` interface slot; the core snap
  declares a matching plug. At connect time, the content snap's site-packages directory is
  appended to `PYTHONPATH` via the interface hook, making the deferred wheels visible to the
  core snap's python3.11 without staging them in the core snap image.
- **Build lockstep:** both snaps must be built against the same python311 part (same `python3.11
  --version`); wheels built against cp311 on one part are not guaranteed binary-compatible with
  a different cp311 build. The monorepo build pipeline (if adopted) enforces this automatically.

If the user decision is "accept in core" (option 1 above), the companion-snap plan is archived.

---

## Decisions unlocked for M3

- **Validate-config entrypoint:** `__main__.py --validate-config` (registered at line 39, gates
  exit at line 110). The `frigate.validate-config` snap app is the proof-of-concept wrapper;
  the production daemon app should expose `--validate-config` directly rather than via a
  separate snap app.

- **Import chain complete:** all 8 non-optional additions (py3nvml, frigate.version generation,
  regex, sherpa-onnx, librosa, soundfile, transformers, pandas) are staged and verified. No
  further import-chain surprises expected for the production `frigate.daemon` app — the full
  `frigate.app` import executes to completion under confinement with rc=0.

- **Env contract proven:** `FRIGATE_CONFIG_DIR`/`FRIGATE_BASE_DIR`/`FRIGATE_CACHE_DIR` override
  the three root paths. M3 daemon wrappers set these to `$SNAP_COMMON/config`,
  `$SNAP_COMMON/media` (or operator-configured path), and `$SNAP_DATA/cache` (or
  `$SNAP_COMMON/cache`) respectively. Default values remain upstream-identical (no-op when
  unset), so the patch is rebasing-safe.

- **M3 daemon plug requirements (from M2 evidence):**
  - `plugs: [network, network-bind]` — network for loopback/RTSP, network-bind for `mp.forkserver
    listen(2)` (seccomp-gated, M2 Task-5 finding) and production ports 5000/8971.
  - `plugs: [shm-private]` (shared-memory, private: true) — required for `mp.Manager()` POSIX
    semaphores; glibc `sem_open` random tempfile defeats any prefix rule; private tmpfs is the
    only fix without upstream changes.
  - `plugs: [opengl]` — cv2 imports libGL; libGL.so.1 is removed from prime by the gpu extension
    cleanup; svc-c wrapper's `MESA_LIB` LD_LIBRARY_PATH block (Task 10 pattern) is required for
    any app that imports cv2 without the `gpu` extension.
  - `plugs: [hardware-observe]` — for ffprobe/ffmpeg hardware capability probing (as with
    gpu-probe).

- **pysqlite3 and sqlite-vec NOT needed for validation** — peewee falls back to stdlib sqlite3
  (lines 29–41); vec0 loads only at DB connect time (sqlitevecq.py:26). Defer to M3 with
  evidence: DB-connect path will need them.

---

## Deviations from expectations

- **BIRDSEYE_PIPE reorder:** The upstream const.py defines `BIRDSEYE_PIPE = "/tmp/cache/birdseye"`
  BEFORE `CACHE_DIR = "/tmp/cache"`. To make BIRDSEYE_PIPE derive from env-driven CACHE_DIR, the
  patch swaps their definition order. This is the only structural (non-substitution) change in
  the patch; all else is a pure `os.environ.get` wrapping.

- **validate-deps part required:** The spike-wheels part (58 wheels) stays cached; a separate
  `validate-deps` part was added for the 7 validate-deps packages (py3nvml, regex,
  sherpa-onnx, librosa, soundfile, transformers, pandas). This avoids an 8-minute wheels
  rebuild on every iteration while the validate-config import chain was being explored.

- **Snap size exceeded initial 927 MB estimate:** Core-58 snap was 927 MB; adding the 7
  validate-deps packages (dominated by transformers ~80 MB + pandas ~30 MB) brought it to 1.11 GB.
  This is the M2-close size for the core snap.

- **network-bind on validate-config:** counterintuitive for a "validation" app, but forced by
  `mp.forkserver` `listen(2)` (journal evidence: seccomp syscall 50 denial at
  `forkserver.py:141`). Production daemon needs it anyway; no new surface added.

- **Task 5 process note:** The Task-5 implementer died once (API error, 66 min, zero durable
  progress) and stalled twice: stall #1: ~17 h (monitor never fired after the rebuild completed
  at 01:47); stall #2: ~15 min (monitor missed again after the harness run completed at 18:54;
  controller woke the agent with the on-disk evidence). Both recovered via transcript-resume
  with incremental wip-checkpoint commits. The durability discipline (incremental report writes,
  wip commits) proved itself and is recommended for all future long-running implementer
  dispatches.

---

## Raw evidence

- `spike/results/m2-final-run.txt` — Final M2 harness run (2026-07-04): SPIKE SMOKE: ALL PASS (61 checks, 36 denials, 0 unexpected; Coral present — delegate loaded, inference ran) (first attempt produced 2 coral FAILs — long-idle 18d1 USB session-state artifact, self-resolved on rerun without code change; M3 CI should include a warm-up probe)
- `spike/results/validate-config.txt` — `frigate.validate-config` run: rc=0, "Your config file is valid."
- `spike/results/vaapi-decode.txt` — VAAPI decode run: `vaapi(progressive)`, 1280x720, 30 frames, rc=0
- `spike/results/vainfo.txt` — `vainfo` output: iHD 26.1.2 driver, MTL AV1/HEVC10/VP9 decode profiles
- `spike/results/spike-results/imports.json` — All 17 module imports ok=true (core + validate-deps set)
- `spike/results/denials.txt` — Full AppArmor denial log (36 total, all catalogued with FINDING comments)
- `spike/results/coral-reenum-transition.txt` — Live 1a6e→18d1 transitions (three captured runs)
- `spike/results/coral-reenum-firstrun.txt` — RECORDED first-run transition (Task 11 archive)
- `spike/results/coral-usb-before.txt` / `coral-usb-after.txt` — Coral USB state before/after final probe
- `spike/results/media-layout-pack-error.txt` — snapcraft pack output confirming /media layout rejection
- `spike/results/expanded-snapcraft.yaml` — Expanded snap definition (full extension substitution)
- `docs/patches.md` — Patch register with rebase notes and upstreaming assessment
