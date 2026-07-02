# Frigate NVR Native Snap — Design Spec

**Date:** 2026-07-02
**Status:** Approved design, pre-implementation
**Companion docs:** [`docs/snap-feasibility.md`](../../snap-feasibility.md) (verified research), [`snap/snapcraft.yaml`](../../../snap/snapcraft.yaml) (target-architecture illustration)

## 1. Goal

Package Frigate NVR (upstream `v0.17.x`, commit `ea131e1` analyzed) as a **native, strict-confined snap** — not a Docker wrapper. Hardware acceleration is first-class: OpenVINO on Intel GPU is the primary detector, VAAPI is the default decode path, and Coral USB is fully supported. CPU detection exists only as fallback configuration. NVIDIA (CUDA/TensorRT) is out of strict scope by verified impossibility and is documented as classic-confinement/Docker territory.

The snap name `frigate` is already reserved by the project owner.

## 2. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Base | `core26` | Officially recommended for new snaps (snapcraft 9.0); +2 yrs support vs core24; mesa-2604 (Mesa 26) for newest hw decode; manylinux wheel-ABI concern disproven (old-binary-on-newer-glibc). Freshness risk (stable 2026-06-10) is absorbed by the spike; fallback to core24 is a one-line change. |
| Confinement | `strict` | Feasible for the target feature set per verified research; classic only for NVIDIA (separate build, later, if ever). |
| Sequencing | De-risking spike (M0) first, then incremental stub-substitution M1→M7 | Biggest-blast-radius unknowns tested by the smallest artifacts; snap stays installable+green at every milestone. |
| `/dev/shm` fix | Spike characterizes; patch-vs-shim decided after seeing the real failure | No need to commit before evidence. |
| Detector priority | OpenVINO-GPU primary; Coral USB first-class; CPU fallback only | User requirement; test hardware available locally. |
| Build/test environment | This host: Ubuntu 24.04, snapd 2.75.2, snapcraft 9.0.0, LXD; `snap install --dangerous`; real AppArmor | Verified capable of building and running core26 strict snaps. |

## 3. Architecture

### 3.1 Process model (mirrors Frigate's s6-overlay tree)

Frigate upstream runs s6-overlay as PID 1 supervising `go2rtc → frigate → nginx → certsync` (+ 2 oneshot init steps). The snap replaces this with snapd-managed systemd daemons:

```
setup (daemon: oneshot, install-mode: enable)
  └─► go2rtc (simple) ─► frigate (simple) ─► nginx (simple) ─► certsync (simple)
                                  [after: ordering, restart-condition per service]
```

- `setup` replaces s6 `prepare`/`log-prepare`: creates `$SNAP_DATA/config`, `$SNAP_COMMON/media/frigate`, migrates DB, generates self-signed cert.
- go2rtc healthcheck loop is replaced by systemd `restart-condition: on-failure`.
- All daemons run as root (snap default) — matches upstream assumptions (nginx `user root;`, device access).

### 3.2 Path remapping (layouts)

Frigate hardcodes paths as module constants in `frigate/const.py`. Layouts remap them namespace-wide so python, go2rtc, ffmpeg, and nginx all agree:

| Hardcoded | Layout target |
|---|---|
| `/opt/frigate`, `/usr/local/nginx`, `/usr/local/go2rtc`, `/usr/lib/ffmpeg` | `$SNAP/...` (read-only) |
| `/config` (config.yml, frigate.db, model cache) | `$SNAP_DATA/config` — must stay on local disk (SQLite locking) |
| `/media/frigate` (recordings/clips/exports) | `$SNAP_COMMON/media/frigate` |
| `/etc/letsencrypt` | `$SNAP_DATA/letsencrypt` |
| `/tmp/cache` (segment cache, ZMQ IPC) | snap-private `/tmp` — no layout needed |

`/dev/shm` cannot be fixed by layout — see §5 risk 1.

### 3.3 Interfaces

| Interface | Purpose | Connect |
|---|---|---|
| `network`, `network-bind` | RTSP/ONVIF ingest, MQTT client, ports 5000/8971/8554/8555/1984 (all >1024) | auto |
| `opengl` (+ `gpu` extension → mesa-2604) | `/dev/dri/renderD128`: VAAPI decode + OpenVINO GPU detect | auto |
| `raw-usb` | Coral USB `/dev/bus/usb` incl. `1a6e:089a → 18d1:9302` re-enumeration | manual (Store auto-connect declaration at M7) |
| `camera` | `/dev/video*` (RPi V4L2, USB cams) | manual |
| `removable-media` | recordings on external disks (`/media`, `/mnt` only) | manual |
| `hardware-observe`, `mount-observe`, `system-observe` | stats pages | manual |
| `avahi-observe` | ONVIF/mDNS discovery (need verified in spike) | manual |
| `custom-device` | NPU `/dev/accel/accel0`; same mechanism Coral-PCIe would need | experimental (M0-C probe; Store-gated for distribution) |

### 3.4 Parts (from the Dockerfile analysis)

Python 3.11 built from source (Frigate pins cp311 wheels; core26's default Python is newer); go2rtc v1.9.13 binary; ffmpeg static builds (NickM-27, 8.0/7.0/5.0 trees); **custom nginx 1.27.4** with vod/secure-token/set-misc/devel-kit modules + Frigate's MAX_CLIPS patch (stock nginx unusable); sqlite-vec; libedgetpu (bookworm .deb — ABI verified in spike); Frigate wheels (`requirements-wheels.txt`); web UI (npm, node 20); models (OpenVINO SSDLite, tflite, YAMNet); wrapper scripts replacing s6 run scripts.

## 4. Milestones

Every milestone exits in the same state: `snapcraft pack` succeeds → `snap install --dangerous` succeeds → `tests/smoke.sh` (grows per milestone) passes → zero AppArmor denials (`snappy-debug` / journal).

### M0 — De-risking spike (throwaway daemons, real snap)

Smallest strict core26 snap that answers the architectural unknowns. Three probe groups:

**A. Platform** — 3 stub Python daemons with `after:` ordering:
1. shm probe: `multiprocessing.shared_memory.SharedMemory(create=True)` with default `psm_*` name (expect: AppArmor denial) and `snap.frigate.*`-prefixed name (expect: allowed). Record exact denial text and working fix shape.
2. Layout probe: each daemon writes through hardcoded `/config`, `/media/frigate`, `/tmp/cache`; verify writes land in `$SNAP_DATA`/`$SNAP_COMMON`/private tmp.
3. Ordering probe: daemons log start timestamps; verify systemd honors the chain.

**B. Toolchain** — can Frigate's stack exist on core26:
1. Python 3.11 part compiles with the core26 build-base toolchain (optimizations off for speed).
2. The four heaviest wheels install and import: `opencv-python-headless`, `onnxruntime`, `tflite_runtime`, `tensorflow-cpu`.
3. `dlopen("libedgetpu.so.1")` from the bookworm .deb succeeds against core26 glibc.

**C. Devices** — which accelerators a strict snap on classic Ubuntu actually reaches (all hardware present on this host):
1. GPU: `gpu` extension wired; `vainfo` enumerates the Meteor Lake iGPU; OpenVINO `Core().available_devices` lists GPU.
2. Coral USB: with `raw-usb` connected, libusb sees `1a6e:089a`; trigger firmware load; verify the re-enumerated `18d1:9302` node is still accessible (hotplug wildcard test).
3. NPU (research, not ship-blocking, timebox: half a day then defer to M6): `custom-device` experiment for `/dev/accel/accel0` — the spike snap declares both the `custom-device` slot (with `devices: [/dev/accel/accel0]`) and the matching plug, installed `--dangerous` and connected manually (`snap connect frigate:npu frigate:npu-dev`); does OpenVINO then list NPU?

**Exit criteria:** written yes/no/how finding per probe in `docs/spike-findings.md`. B-failures → fall back to `base: core24` (one line; A-findings carry over). A-failure on shm with no working fix shape → stop and redesign (only credible architecture-killer).

### M1 — go2rtc
Real go2rtc binary replaces stub 1. Synthetic camera introduced: ffmpeg `lavfi testsrc` (and a looped clip with people/cars) published via go2rtc RTSP.
**Verify:** `curl :1984/api/streams`; restream plays in an external player.

### M2 — Python 3.11 + wheels + ffmpeg (VAAPI default)
Full toolchain lands; ffmpeg trees staged; VAAPI is the default decode preset from day one.
**Verify:** full wheel import suite; bundled ffmpeg hw-decodes the synthetic RTSP stream (`intel_gpu_top` shows video-engine load); `python3 -m frigate` reaches config validation.

### M3 — Frigate core, detecting on the iGPU ⭐
Frigate daemon replaces stub 2; `/dev/shm` fix applied per M0 findings; models staged; config points at the synthetic camera with **OpenVINO-GPU detector** (NPU too if M0-C succeeded; CPU tflite as fallback config).
**Verify (the money test):** strict-confined Frigate boots, detects objects in the test clip on the GPU (device query in logs + GPU load), events in `frigate.db`, recordings under `$SNAP_COMMON/media/frigate`, API answers on `:5001`.

### M4 — nginx + web UI
Custom nginx build replaces stub 3; npm-built web UI staged.
**Verify:** `http://localhost:5000` — live view and recordings playback (exercises the vod module).

### M5 — TLS + certsync
Self-signed cert generation; external port 8971; certsync daemon.
**Verify:** `https://localhost:8971`; cert change triggers nginx reload.

### M6 — Remaining accelerators
Coral USB end-to-end detection (hardware attached: Bus 003, `1a6e:089a`); NPU productization if M0-C worked; NVIDIA-classic decision documented for users.
**Verify:** detection runs on the Coral; `snap connections` documented per accelerator.

### M7 — Ship
`snap set` configuration options; store upload (edge → beta); Store auto-connect declaration requests (`raw-usb`, `camera`, `removable-media`); arm64 via `platforms:`; user docs.
**Verify:** clean-machine install from the Store following only the README.

## 5. Risks

1. **`/dev/shm` AppArmor denial** (`psm_*` names) — highest risk; M0-A answers it; fix shape (source patch vs `LD_PRELOAD` shim vs upstream PR) decided on evidence.
2. **Bookworm .deb ABI on core26** (libedgetpu, Intel compute-runtime) — outside manylinux guarantee; M0-B answers it; mitigation: build libedgetpu from source.
3. **core26/mesa-2604 freshness** (weeks old) — absorbed by spike + smoke tests; fallback core24 documented.
4. **NPU `custom-device` experiment may dead-end** — timeboxed; not ship-blocking; still valuable research (same mechanism as Coral-PCIe).
5. **WebRTC UDP 8555 / mDNS discovery under confinement** — verified need at M1 (go2rtc) and spike (`avahi-observe`).
6. **Upstream drift** — Frigate releases move paths/versions; every carried patch documented in `docs/patches.md` with rebase notes.

## 6. Out of scope (this project phase)

NVIDIA/TensorRT (classic-only; possibly a later separate snap), Coral PCIe (no local hardware; same `custom-device` mechanism as NPU), Hailo/RKNN/MemryX/Synaptics/Axengine (SoC/proprietary stacks), Home Assistant add-on packaging, migration tooling from Docker installs.
