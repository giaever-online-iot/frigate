# Packaging Frigate NVR as a native Ubuntu snap — Feasibility & Confinement Report

**Date:** 2026-06-30
**Scope:** Native snapcraft packaging of [Frigate NVR](https://github.com/blakeblackshear/frigate) — **not** a Docker-in-snap wrapper and **not** running Frigate's official container image. Target: **strict confinement**, falling back to **classic** only where strict is provably impossible.
**Ground truth:** Frigate `master` @ `ea131e1` (≈ v0.17.x), Debian 12 (bookworm) base, Python 3.11.

> **Updated 2026-07-03 with M0 spike results** ([`docs/spike-findings.md`](spike-findings.md) — empirical, on-hardware verification of this report's claims on **core26**/snapd 2.75.2). Corrections are marked "**M0:**" inline. Headline changes: the layout strategy for `/config`+`/media/frigate` is **impossible** (→ `const.py` patch required), while `custom-device` for NPU/Coral-PCIe **works** on classic Ubuntu (blocker downgraded to Store-approval-only).

---

## 1. Verdict

A **strict-confined native snap of Frigate is feasible for a defined feature subset** and has strong precedent, but it is a **full repackaging effort, not a wrapper** — Frigate ships only as a Docker image, supervises four daemons with s6-overlay, compiles its own nginx, and hardcodes all of its state paths.

| Feature path | Strict-confined? | Mechanism |
|---|---|---|
| CPU detection (tflite) | ✅ Yes | no devices needed |
| OpenVINO on Intel iGPU | ✅ **M0-verified** | `opengl` + `gpu` extension (mesa-2604) — **plus** intel-opencl-icd staging + OpenCL layouts + runtime `LD_LIBRARY_PATH` (recipe in spike findings; not turn-key) |
| Intel/AMD VAAPI decode | ✅ **M0-verified** | `gpu` extension (mesa-2604): iHD 26.1.2, AV1/HEVC10/VP9 on Meteor Lake |
| Coral **USB** | ✅ **M0-verified** | `raw-usb` as root (manual-connect); live firmware re-enumeration survives confinement |
| Raspberry Pi V4L2 decode | ✅ Yes | `camera` interface (`/dev/video*`) |
| Recordings to external disk | ⚠️ Yes, with caveats | `removable-media` (manual-connect, `/media` `/mnt` only) |
| Networking (RTSP/MQTT/WebUI) | ✅ Yes | `network` + `network-bind` (auto-connect) |
| Coral **PCIe/M.2** (`/dev/apex_0`) | ⚠️ **M0-downgraded** | `custom-device` self-slot **works on classic Ubuntu** (proven via NPU, same mechanism); super-privileged → Store approval needed only for *distribution* |
| Intel **NPU** (`/dev/accel`) | ⚠️ **M0-downgraded** | `custom-device` self-slot verified: connect OK, `open(/dev/accel/accel0)` OK |
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
| `/opt/frigate` | app code + built web UI (read-only) | `$SNAP/opt/frigate` (layout bind — `/opt` exists in base, expected valid; untested in M0) |
| `/config` | config.yml, `frigate.db`, model cache, secrets | **M0: layout IMPOSSIBLE** (pack-time rejection: *"defines a new top-level directory /config"*) → patch `const.py` to env-driven path → `$SNAP_DATA/config` |
| `/media/frigate` | recordings, clips, exports (large) | **M0: layout IMPOSSIBLE** (same rejection class for `/media`) → patch `const.py` → `$SNAP_COMMON/media/frigate` |
| `/tmp/cache` | recording segment cache, birdseye pipe, ZMQ IPC sockets | snap's **private `/tmp`** — **M0-verified**, works as-is |
| `/dev/shm` | raw decoded frames, logs, go2rtc.yaml | see §4 — **M0: prefix patch required & proven** |
| `/usr/local/nginx`, `/usr/local/go2rtc`, `/usr/lib/ffmpeg` | bundled binaries | `$SNAP/...` (layout bind — `/usr` base-rooted, valid) |
| `/etc/letsencrypt` | TLS certs (writable at runtime) | `$SNAP_DATA/letsencrypt` (layout bind — **M0-verified working**) |

**Strategy (corrected by M0):** snap **layouts cannot create new top-level directories** — snapd's pack-time validator rejects any layout whose target root is absent from the base filesystem (deterministic error: `layout "<path>" defines a new top-level directory "<dir>"`). The original claim here that layouts could mint `/config` and `/media/frigate` was **wrong**. Layouts remain valid only for base-rooted paths (`/etc/*`, `/usr/*`, `/opt/*`…). Consequence: **patching `frigate/const.py` to env-driven base paths is the required strategy** (not a fallback) for `/config` and `/media/frigate` — it pairs naturally with the mandatory shm-prefix patch (§4.1) in a single small carried patch.

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

**GPU extension (M0-verified on core26):** the snapcraft-9 `gpu` extension adds a `gpu-2604` *content* plug (default-provider `mesa-2604`) plus a command-chain wrapper, delivering Mesa + OpenGL/Vulkan **and VA-API** from the provider snap. **M0 confirmed VAAPI is turn-key** (iHD 26.1.2 enumerated with full Meteor Lake profiles) **but OpenVINO-GPU is not**: it additionally requires `intel-opencl-icd` + `libigdgmm12` + `ocl-icd-libopencl1` staged, `/etc/OpenCL` + `intel-opencl` layouts, and runtime `LD_LIBRARY_PATH` including the mesa-2604 mount (the extension's cleanup strips `libGL.so.1` from the snap) — each element counterfactual-proven necessary. Full recipe in the spike findings.

---

## 4. Strict-confinement blockers (the limitations you asked about)

### 4.1 `/dev/shm` shared memory — **needs an upstream patch** ✅ M0-VERIFIED
Frigate stores raw decoded frames via Python `multiprocessing.shared_memory` (`SharedMemoryFrameManager`). CPython creates these at `/dev/shm/psm_<random>`. **M0 confirmed on real snapd/AppArmor:** `psm_*` creation is denied (`mknod` AppArmor denial, `PermissionError`), while a **`snap.<instance>.*`-prefixed segment is allowed** — the fix shape is a **source patch of the SHM name prefix** and its viability is proven (spike probe A1). Layouts cannot address this (AppArmor rule, not a path issue); an `LD_PRELOAD` shim is unnecessary given how small the prefix patch is.

Remaining for M3: Frigate needs a **large `/dev/shm`** (formula: `(W×H×1.5×20+270480)/1048576` MB per camera + 40 MB logs; 128 MB ≈ two 720p cams). The spike validated small-segment creation only; sizing behavior under many-camera load is still to be measured when the real frame pipeline lands.

### 4.2 Coral USB — works ✅ M0-VERIFIED end-to-end
`raw-usb` grants the AppArmor/udev access to `/dev/bus/usb/NNN/NNN`, and snapd's wildcard usb udev tags cover **hotplug** re-enumeration — **M0 proved this live**: delegate load, firmware upload, the `1a6e:089a → 18d1:9302` re-enumeration (new device number mid-session), and inference all succeeded strict-confined. `raw-usb` does *not* supersede classic file permissions — the snap must run **as root** (snap daemons do by default) or rely on the libedgetpu `plugdev` udev rule. Manual-connect; auto-connect needs a Store grant. One benign, labeled `CAP_NET_ADMIN` denial during libedgetpu USB init.

### 4.3 Coral PCIe `/dev/apex_0` & Intel NPU `/dev/accel` — **downgraded: mechanism works** ⚠️ M0-VERIFIED
**No built-in snapd interface** exists for these nodes; the strict path is the **super-privileged `custom-device`** interface. **M0 (probe C3) proved the mechanism works on classic Ubuntu**: a snap can declare its own `custom-device` slot (`devices: [/dev/accel/accel0]`), install with `--dangerous`, self-connect, and open the device under strict confinement — no gadget snap needed. The blocker is therefore **only Store approval for distribution** (super-privileged slots need a snap-declaration to ship via the Store). An advisory `CAP_SYS_ADMIN` denial fires once per device init and does not block the open. Non-root daemon access would need udev tagging/render-group membership (snap daemons run as root, so moot for the current design).

### 4.4 NVIDIA CUDA/TensorRT/NVDEC — **hard blocker**
The Mesa passthrough (`mesa-coreXX`) only forwards **host NVIDIA GL/Vulkan userspace** installed as Debian packages — **not** CUDA/TensorRT/NVDEC, which Frigate's TensorRT detector and NVDEC decode require. snapd's own NVIDIA support is documented as *"fragile and complex"*; the driver is never bundled. NVIDIA acceleration is therefore **not achievable under strict confinement** and is the strongest candidate for a separate **classic** snap (or staying on Docker).

### 4.5 WebRTC UDP 8555
go2rtc's WebRTC uses UDP + ICE/STUN. `network-bind` permits binding fixed ports, but NAT traversal/ephemeral ranges can be fragile under confinement — **prototype and verify** (open item). RTSP restream (8554/TCP) is fine.

### 4.6 Runs everything as root + writes system dirs
Frigate, nginx (`user root;`), and go2rtc all run as root and write `/usr/local/nginx/conf`, `/etc/letsencrypt`. Snap daemons are root by default (helps), but those writable paths must be relocated under `$SNAP_DATA`/`$SNAP_COMMON` via layouts, and nginx's startup config-rewrite (sed + tempio) needs a writable nginx prefix.

### 4.7 Recordings to arbitrary disks
`removable-media` covers **only** `/media`, `/run/media`, `/mnt` — **not** `/srv` or `/data` (those need `system-files`, even harder to get approved). Because Frigate hardcodes `RECORD_DIR=/media/frigate/recordings` (**M0: routed to `$SNAP_COMMON` via the `const.py` env patch — a layout is impossible for `/media`**, §2.3), pointing recordings at an external disk requires the user to bind-mount/symlink that disk under `$SNAP_COMMON/media/frigate` — a documented limitation, not a clean config toggle.

### 4.8 Python 3.11 vs base ✅ M0-VERIFIED
Frigate pins **Python 3.11** and downloads prebuilt wheels tagged `cp311`. core22 ships 3.10, core24 ships 3.12, **core26 ships 3.14 (M0)**. Rebuilding tensorflow/onnxruntime/opencv wheels for a different ABI is impractical, so the snap must **build/stage Python 3.11**. **M0 proved this works on core26:** 3.11.9 compiles clean on GCC 15.2.0 (~1m22s; note `g++` is absent from the build env — add to `build-packages` if any part compiles C++), and all 6 upstream cp311 wheels import under strict confinement. This is a build-complexity cost, not a confinement blocker.

---

## 5. Precedent (verified)

- **MotionEye snap** ([snapcraft.io/motioneye](https://snapcraft.io/motioneye), [ogra1/motioneye-snap](https://github.com/ogra1/motioneye-snap)) — proves a **native, parts-built, strict-confined camera/ffmpeg NVR snap** that bundles all binaries (no Docker image) and uses manual-connect `camera`/`removable-media`. Caveat: single-daemon, legacy Python 2.7 — far simpler than Frigate.
- **Nextcloud snap** ([nextcloud-snap](https://github.com/nextcloud-snap/nextcloud-snap)) — proves a **strict multi-daemon server stack** (Apache/MySQL/PHP-FPM/Redis) in one snap, each service a `daemon: simple`, **all built from upstream source**, external storage via `removable-media`. This is the direct architectural template for Frigate's go2rtc + ffmpeg + nginx + python + sqlite orchestration.

---

## 6. Open questions — M0 spike status

1. **`/dev/shm`** — ✅ **ANSWERED (M0-A1):** yes, patching Frigate's SHM name prefix is required and proven viable. Large-shm sizing under real load remains an M3 measurement.
2. **Layouts** — ✅ **ANSWERED (M0-A2):** NO for `/config` and `/media/frigate` (pack-time rejections — `const.py` patch required); YES for base-rooted paths (`/etc/letsencrypt` verified); `/tmp/cache` works in the private tmp with no layout.
3. **WebRTC/UDP + ONVIF/mDNS** — ⏳ **still open**, deliberately deferred to M1 where go2rtc provides a real workload.
4. **Coral PCIe/NPU** — ✅ **ANSWERED (M0-C3):** `custom-device` self-slot works on classic Ubuntu without a gadget snap (`--dangerous` install + manual connect); Store approval is needed only to distribute. No udev/device-cgroup workaround needed.

Full evidence: [`docs/spike-findings.md`](spike-findings.md).

---

## 7. Sources

Verified primary sources (24 fetched, 25 claims, all confirmed 3-0 adversarially):
- Frigate: [repo](https://github.com/blakeblackshear/frigate), [installation](https://docs.frigate.video/frigate/installation/), [advanced](https://docs.frigate.video/configuration/advanced/)
- snapd interfaces: [reference](https://snapcraft.io/docs/reference/interfaces/), [raw-usb](https://snapcraft.io/docs/reference/interfaces/raw-usb-interface/), [removable-media](https://snapcraft.io/docs/reference/interfaces/removable-media-interface/), [custom-device](https://snapcraft.io/docs/reference/interfaces/custom-device-interface/), [auto-connection](https://snapcraft.io/docs/explanation/interfaces/interface-auto-connection/), [super-privileged](https://snapcraft.io/docs/explanation/interfaces/super-privileged-interfaces/)
- [GPU extension](https://documentation.ubuntu.com/snapcraft/stable/reference/extensions/gpu-extension/), [gpu-snap](https://github.com/canonical/gpu-snap)
- Precedent: [motioneye](https://snapcraft.io/motioneye), [motioneye-snap](https://github.com/ogra1/motioneye-snap), [nextcloud-snap](https://github.com/nextcloud-snap/nextcloud-snap), [services-and-daemons](https://snapcraft.io/docs/services-and-daemons/)
- [Frigate NVR snap-request (2023)](https://forum.snapcraft.io/t/frigate-nvr/35456)
