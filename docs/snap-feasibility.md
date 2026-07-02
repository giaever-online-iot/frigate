# Packaging Frigate NVR as a native Ubuntu snap — Feasibility & Confinement Report

**Date:** 2026-06-30
**Scope:** Native snapcraft packaging of [Frigate NVR](https://github.com/blakeblackshear/frigate) — **not** a Docker-in-snap wrapper and **not** running Frigate's official container image. Target: **strict confinement**, falling back to **classic** only where strict is provably impossible.
**Ground truth:** Frigate `master` @ `ea131e1` (≈ v0.17.x), Debian 12 (bookworm) base, Python 3.11.

---

## 1. Verdict

A **strict-confined native snap of Frigate is feasible for a defined feature subset** and has strong precedent, but it is a **full repackaging effort, not a wrapper** — Frigate ships only as a Docker image, supervises four daemons with s6-overlay, compiles its own nginx, and hardcodes all of its state paths.

| Feature path | Strict-confined? | Mechanism |
|---|---|---|
| CPU detection (tflite) | ✅ Yes | no devices needed |
| OpenVINO on Intel iGPU | ⚠️ Mostly | `/dev/dri` via `opengl` + `gpu-2404` extension |
| Intel/AMD VAAPI decode | ⚠️ Mostly | `gpu-2404` extension (Mesa content snap) |
| Coral **USB** | ⚠️ Yes, with caveats | `raw-usb` (manual-connect, **needs root + udev**) |
| Raspberry Pi V4L2 decode | ✅ Yes | `camera` interface (`/dev/video*`) |
| Recordings to external disk | ⚠️ Yes, with caveats | `removable-media` (manual-connect, `/media` `/mnt` only) |
| Networking (RTSP/MQTT/WebUI) | ✅ Yes | `network` + `network-bind` (auto-connect) |
| Coral **PCIe/M.2** (`/dev/apex_0`) | ❌ Blocker | no interface → `custom-device` (super-privileged, Store-gated) |
| Intel **NPU** (`/dev/accel`) | ❌ Blocker | same as above |
| **NVIDIA** TensorRT/CUDA/NVDEC | ❌ Blocker | Mesa passthrough carries GL/Vulkan only, not CUDA |
| Rockchip / Hailo / MemryX / Axengine | ❌ Blocker | proprietary device nodes, "privileged mode" upstream |

**Recommended product:** ship one **strict** snap covering **CPU + OpenVINO + Intel/AMD VAAPI + Coral USB + removable-media recordings**, pursue Store auto-connect declarations to spare users manual `snap connect`, and treat NVIDIA / Coral-PCIe / NPU as either `custom-device` special builds or the *only* candidates for a separate **classic** snap.

> **Prior art:** A 2023 [snap-request for "Frigate NVR"](https://forum.snapcraft.io/t/frigate-nvr/35456) exists (name registration only) — **no maintained Frigate snap exists today.** This would be a first.

---

## 2. Frigate runtime requirements → snap mapping

### 2.1 Process model (the most important fact)

Frigate runs **s6-overlay v3 as PID 1**, supervising **four long-running services** plus two oneshot init steps. s6-overlay cannot be PID 1 in a snap, so each service becomes a snap **`daemon`** (systemd unit) with explicit ordering:

```
prepare (oneshot) ─┐
log-prepare (oneshot) ─┤
                   └─► go2rtc ──► frigate ──► nginx ──► certsync
                          │
                          └─► go2rtc-healthcheck
```

| s6 service | Becomes | Notes |
|---|---|---|
| `prepare`, `log-prepare` | `configure` hook + oneshot daemon / command-chain | create dirs, migrate DB, generate self-signed cert |
| `go2rtc` | `daemon: simple` | generates `go2rtc.yaml`, restreaming/WebRTC |
| `frigate` (`python3 -m frigate`) | `daemon: simple`, `after: [go2rtc]` | the **core**; spawns ffmpeg subprocesses per camera |
| `nginx` | `daemon: simple`, `after: [frigate]` | custom-built; rewrites own config at startup |
| `certsync` | `daemon: simple`, `after: [nginx]` | Let's Encrypt reload loop |
| `go2rtc-healthcheck` | *dropped* | replaced by systemd `restart-condition` |

The Python core (`frigate`) is the orchestrator: it spawns **ffmpeg** as subprocesses (one+ per camera) and talks to **go2rtc** over `localhost:1984`. go2rtc itself also spawns ffmpeg via `exec:` streams.

### 2.2 Network ports — all unprivileged (>1024), so no privileged-port issue

| Port | Proto | Owner | Role |
|---|---|---|---|
| 8971 | TCP | nginx | external authenticated UI/API (TLS default) |
| 5000 | TCP | nginx | internal unauthenticated UI/API |
| 5001 | TCP | frigate (uvicorn) | FastAPI, bound 127.0.0.1 |
| 5002 | TCP | frigate (ws4py) | WebSocket |
| 8082 | TCP | frigate | jsmpeg live |
| 1984 | TCP | go2rtc | API (localhost) |
| 8554 | TCP | go2rtc | RTSP restream |
| 8555 | TCP+**UDP** | go2rtc | **WebRTC** (UDP — see §4) |

→ Satisfied by **`network`** (outbound: RTSP/ONVIF ingest, MQTT client) + **`network-bind`** (server ports). **Both auto-connect; no Store review needed.** MQTT needs no special interface — Frigate is an MQTT *client*, so `network` suffices (the snapd `mqtt` interface is for hosting a *broker* and is not required).

### 2.3 Filesystem & state — every path is hardcoded

`frigate/const.py` defines these as **module-level constants** (only `CONFIG_FILE` and `DEFAULT_FFMPEG_VERSION` are env-overridable):

| Path | Purpose | Snap target |
|---|---|---|
| `/opt/frigate` | app code + built web UI (read-only) | `$SNAP/opt/frigate` (layout bind) |
| `/config` | config.yml, `frigate.db`, model cache, secrets | `$SNAP_DATA/config` (layout bind) |
| `/media/frigate` | recordings, clips, exports (large) | `$SNAP_COMMON/media/frigate` (layout bind) |
| `/tmp/cache` | recording segment cache, birdseye pipe, ZMQ IPC sockets | snap's **private `/tmp`** — works as-is |
| `/dev/shm` | raw decoded frames, logs, go2rtc.yaml | see §4 — **needs care** |
| `/usr/local/nginx`, `/usr/local/go2rtc`, `/usr/lib/ffmpeg` | bundled binaries | `$SNAP/...` (layout bind) |
| `/etc/letsencrypt` | TLS certs (writable at runtime) | `$SNAP_DATA/letsencrypt` (layout bind) |

**Strategy:** use snap **`layout:`** entries to remap absolute paths into `$SNAP`/`$SNAP_DATA`/`$SNAP_COMMON`. Layouts apply to the whole snap mount namespace, so go2rtc, ffmpeg, nginx, and python **all** see the same remapped paths consistently — avoiding a fork of `const.py`. (Patching `const.py` to read env vars is the fallback if layouts prove leaky.)

**SQLite constraint:** `frigate.db` must stay on **local** storage — Frigate throws `database is locked` on NFS/SMB (POSIX advisory-locking limitation). So `/config` (→ `$SNAP_DATA`) must not be redirected to a network/removable mount.

### 2.4 Build system → snapcraft parts

Frigate's multi-stage Dockerfile maps to these parts (no stock apt packages can be reused for nginx/ffmpeg/go2rtc):

| Part | Source | Plugin |
|---|---|---|
| `go2rtc` | upstream binary `v1.9.13` | `dump` |
| `ffmpeg` | `NickM-27/FFmpeg-Builds` static gpl (5.0/7.0/**8.0**) | `dump` (or build) |
| `nginx` | **from source** 1.27.4 + `nginx-vod-module`, `secure-token`, `set-misc`, `ngx_devel_kit` (patched `MAX_CLIPS`) | `autotools`/`make` |
| `sqlite-vec` | upstream | `make` |
| `tempio`, `yq` | upstream binaries | `dump` |
| `libedgetpu` | `feranick/libedgetpu` `.deb` (bookworm) — **verify ABI on Ubuntu base** | `dump` |
| `python` | **Python 3.11** (base ships 3.10/3.12 — see §4) | `autotools` (from source) |
| `frigate-wheels` | `requirements-wheels.txt` (opencv, tflite_runtime, onnxruntime, openvino, tensorflow-cpu, peewee, paho-mqtt, fastapi…) | `python` |
| `web-ui` | `web/` React build | `npm` (node 20) |
| `models` | OpenVINO SSDLite + EdgeTPU/CPU tflite + YAMNet audio | `dump` |
| `wrappers` | local launch/setup scripts (replace s6 `run` scripts) | `dump` |

---

## 3. Interface / plug / slot reference (verified against snapd docs)

| Interface | Need | Auto-connect? | Store approval? |
|---|---|---|---|
| `network` | RTSP/ONVIF ingest, MQTT client, outbound | ✅ yes | no |
| `network-bind` | bind WebUI/go2rtc ports | ✅ yes | no |
| `opengl` | `/dev/dri` render nodes (VAAPI/OpenVINO) | ✅ yes | no |
| `camera` | `/dev/video*` (RPi V4L2, USB cams) | ❌ manual | for **auto**-connect |
| `raw-usb` | Coral USB `/dev/bus/usb` | ❌ manual | for auto-connect |
| `removable-media` | recordings to `/media`, `/run/media`, `/mnt` | ❌ manual | for auto-connect (except browser/recorder categories) |
| `hardware-observe` | enumerate devices, GPU/hw stats | ❌ manual | no (for use) |
| `mount-observe` | disk-usage stats for storage page | ❌ manual | no |
| `system-observe` | process/system stats | ❌ manual | no |
| `avahi-observe` | ONVIF/mDNS camera discovery (likely) | ❌ manual | no |
| `custom-device` | `/dev/apex_0`, `/dev/accel` (Coral-PCIe/NPU) | ❌ manual | ✅ **required (super-privileged)** |

**Auto-connection model (verified):** snapd applies built-in *base-declaration* rules, which a per-snap *snap-declaration* (Store policy) can override. So a polished Frigate snap **can request Store grants to auto-connect** `raw-usb` / `camera` / `removable-media`, sparing users the manual `snap connect`. Precedence: snap-plug > snap-slot > built-in-plug > built-in-slot.

**GPU extension:** `gpu-2404` (core24) / `gpu-2204` (core22) adds a `graphics-coreXX` *content* plug (default-provider `mesa-coreXX`) plus a command-chain wrapper, delivering Mesa + OpenGL/Vulkan **and VA-API/VDPAU** from the provider snap — the correct strict mechanism for Intel/AMD decode (not turn-key: Frigate's custom ffmpeg needs `LIBVA_DRIVERS_PATH` wiring, and Mesa version/codec mismatches are documented).

---

## 4. Strict-confinement blockers (the limitations you asked about)

### 4.1 `/dev/shm` shared memory — **needs an upstream patch** ⚠️
Frigate stores raw decoded frames via Python `multiprocessing.shared_memory` (`SharedMemoryFrameManager`). CPython creates these at `/dev/shm/psm_<random>`. **snapd's AppArmor template only permits `/dev/shm/snap.<instance>.*`** — generic `psm_*` names are **denied**. This breaks the frame pipeline under strict confinement. Resolution requires either:
- patching Frigate's SHM name prefix to `snap.<instance>.…`, or
- a `LD_PRELOAD`/shim, or
- verifying whether a snap layout can satisfy it (it cannot change AppArmor SHM rules).

Additionally, Frigate needs a **large `/dev/shm`** (formula: `(W×H×1.5×20+270480)/1048576` MB per camera + 40 MB logs; 128 MB ≈ two 720p cams). Whether snapd provisions a sufficiently large writable `/dev/shm` under confinement is an **open verification item**. *This is the single biggest strict-confinement risk and must be prototyped first.*

### 4.2 Coral USB — works, but `raw-usb` does **not** override Unix permissions
`raw-usb` grants the AppArmor/udev access to `/dev/bus/usb/NNN/NNN`, and snapd's wildcard usb udev tags cover **hotplug** re-enumeration. **But** it does *not* supersede classic file permissions — the snap must run **as root** (snap daemons do by default) or rely on the libedgetpu `plugdev` udev rule. Manual-connect; auto-connect needs a Store grant.

### 4.3 Coral PCIe `/dev/apex_0` & Intel NPU `/dev/accel` — **hard blockers**
**No built-in snapd interface** exists for these nodes. The only strict path is the **super-privileged `custom-device`** interface (explicit device-path attributes, auto-generated udev rules), which **requires Store approval** and is gadget/Ubuntu-Core-oriented — awkward for a widely-distributed classic-Ubuntu snap. Practically: ship these only via a `custom-device` declaration or a separate classic/devmode build.

### 4.4 NVIDIA CUDA/TensorRT/NVDEC — **hard blocker**
The Mesa passthrough (`mesa-coreXX`) only forwards **host NVIDIA GL/Vulkan userspace** installed as Debian packages — **not** CUDA/TensorRT/NVDEC, which Frigate's TensorRT detector and NVDEC decode require. snapd's own NVIDIA support is documented as *"fragile and complex"*; the driver is never bundled. NVIDIA acceleration is therefore **not achievable under strict confinement** and is the strongest candidate for a separate **classic** snap (or staying on Docker).

### 4.5 WebRTC UDP 8555
go2rtc's WebRTC uses UDP + ICE/STUN. `network-bind` permits binding fixed ports, but NAT traversal/ephemeral ranges can be fragile under confinement — **prototype and verify** (open item). RTSP restream (8554/TCP) is fine.

### 4.6 Runs everything as root + writes system dirs
Frigate, nginx (`user root;`), and go2rtc all run as root and write `/usr/local/nginx/conf`, `/etc/letsencrypt`. Snap daemons are root by default (helps), but those writable paths must be relocated under `$SNAP_DATA`/`$SNAP_COMMON` via layouts, and nginx's startup config-rewrite (sed + tempio) needs a writable nginx prefix.

### 4.7 Recordings to arbitrary disks
`removable-media` covers **only** `/media`, `/run/media`, `/mnt` — **not** `/srv` or `/data` (those need `system-files`, even harder to get approved). Because Frigate hardcodes `RECORD_DIR=/media/frigate/recordings` (which we layout-bind to `$SNAP_COMMON`), pointing recordings at an external disk requires the user to bind-mount/symlink that disk under `$SNAP_COMMON/media/frigate` — a documented limitation, not a clean config toggle.

### 4.8 Python 3.11 vs base
Frigate pins **Python 3.11** and downloads prebuilt wheels tagged `cp311`. core22 ships 3.10, core24 ships 3.12. Rebuilding tensorflow/onnxruntime/opencv wheels for a different ABI is impractical, so the snap must **build/stage Python 3.11** (as the Dockerfile does on bookworm). This is a build-complexity cost, not a confinement blocker.

---

## 5. Precedent (verified)

- **MotionEye snap** ([snapcraft.io/motioneye](https://snapcraft.io/motioneye), [ogra1/motioneye-snap](https://github.com/ogra1/motioneye-snap)) — proves a **native, parts-built, strict-confined camera/ffmpeg NVR snap** that bundles all binaries (no Docker image) and uses manual-connect `camera`/`removable-media`. Caveat: single-daemon, legacy Python 2.7 — far simpler than Frigate.
- **Nextcloud snap** ([nextcloud-snap](https://github.com/nextcloud-snap/nextcloud-snap)) — proves a **strict multi-daemon server stack** (Apache/MySQL/PHP-FPM/Redis) in one snap, each service a `daemon: simple`, **all built from upstream source**, external storage via `removable-media`. This is the direct architectural template for Frigate's go2rtc + ffmpeg + nginx + python + sqlite orchestration.

---

## 6. Open questions to resolve via prototype (priority order)

1. **`/dev/shm`** — does the `psm_*` AppArmor denial (§4.1) require patching Frigate, and can snapd provision a large-enough writable `/dev/shm`? *(highest risk — prototype first)*
2. **Layouts** — do they cleanly remap `/config`, `/media/frigate`, `/tmp/cache`, `/opt/frigate` for all four daemons without patching upstream?
3. **WebRTC/UDP + ONVIF/mDNS** — do they work on `network`+`network-bind` alone, or is `avahi-observe`/`network-control` needed?
4. **Coral PCIe/NPU** — is `custom-device`+Store approval truly the only strict path on classic Ubuntu, or is there a udev/device-cgroup workaround?

---

## 7. Sources

Verified primary sources (24 fetched, 25 claims, all confirmed 3-0 adversarially):
- Frigate: [repo](https://github.com/blakeblackshear/frigate), [installation](https://docs.frigate.video/frigate/installation/), [advanced](https://docs.frigate.video/configuration/advanced/)
- snapd interfaces: [reference](https://snapcraft.io/docs/reference/interfaces/), [raw-usb](https://snapcraft.io/docs/reference/interfaces/raw-usb-interface/), [removable-media](https://snapcraft.io/docs/reference/interfaces/removable-media-interface/), [custom-device](https://snapcraft.io/docs/reference/interfaces/custom-device-interface/), [auto-connection](https://snapcraft.io/docs/explanation/interfaces/interface-auto-connection/), [super-privileged](https://snapcraft.io/docs/explanation/interfaces/super-privileged-interfaces/)
- [GPU extension](https://documentation.ubuntu.com/snapcraft/stable/reference/extensions/gpu-extension/), [gpu-snap](https://github.com/canonical/gpu-snap)
- Precedent: [motioneye](https://snapcraft.io/motioneye), [motioneye-snap](https://github.com/ogra1/motioneye-snap), [nextcloud-snap](https://github.com/nextcloud-snap/nextcloud-snap), [services-and-daemons](https://snapcraft.io/docs/services-and-daemons/)
- [Frigate NVR snap-request (2023)](https://forum.snapcraft.io/t/frigate-nvr/35456)
