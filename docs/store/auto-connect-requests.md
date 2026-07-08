# Store auto-connect request drafts

The `frigate` snap needs four interfaces that snapd does not auto-connect by
default: `raw-usb`, `hardware-observe`, `shm-private` (the private
`shared-memory` plug), and `mount-observe`. Until the Snap Store approves an
auto-connect declaration for each, users have to run `sudo snap connect
...` by hand after install (documented in the top-level `README.md`).

**These drafts are ready to post to the
[snapcraft.io forum](https://forum.snapcraft.io/) (`store-requests`
category) by the snap's publisher — the maintainer of the registered
`frigate` Snap Store account. They are not submitted automatically by
anything in this repository.** Each draft below is one interface, one
forum post. Fill in the `Snap ID` field (visible on the snap's Store
listing / `snapcraft list-registered` output once `frigate` is registered)
before posting.

---

## Request 1: `raw-usb`

**Snap name:** frigate
**Snap ID:** _(fill in — from `snapcraft list-registered` after registration)_
**Publisher:** _(fill in — the Snap Store account `frigate` is registered under)_
**Interface:** `raw-usb`
**Requested:** auto-connect on install

### What the snap is

Frigate is a network video recorder with local, real-time AI object
detection for security cameras. This snap packages it under strict
confinement (no Docker, no classic confinement) for Ubuntu/snapd systems.

### Why `raw-usb` is needed

Frigate supports the Google Coral USB Accelerator as an optional hardware
object-detection accelerator (alongside an Intel/AMD GPU detector and a CPU
fallback — the USB accelerator is opt-in, not the default). Talking to the
Coral stick requires direct access to `/dev/bus/usb/*` device nodes:
Frigate's detector process loads the EdgeTPU runtime, which uses `libusb`
to open the device, upload its firmware on first use, and run inference
transactions over USB bulk transfers. `libusb` cannot do any of this
through an intermediary — it needs `ioctl()`-level access to the raw USB
device node, which is exactly what the `raw-usb` interface grants.

One USB-specific detail worth noting for reviewers: on its very first use
after power-up, the Coral USB Accelerator re-enumerates on the bus once
its firmware upload completes — its USB device ID changes from
`1a6e:089a` (bootloader) to `18d1:9302` (initialized). `libusb`'s open
call has to survive across that re-enumeration, which `raw-usb` also
covers since it's not scoped to a single, fixed device identity.

### Auto-connect justification

The Coral USB Accelerator is a widely-used, well-known category of device
(Google's official USB ML accelerator) with no viable in-between access
mechanism — `libusb`'s USB-device access model doesn't have a narrower
snapd interface than `raw-usb` for this class of device. Users who plug in
a Coral stick and switch Frigate's detector to use it reasonably expect it
to work without an extra manual `snap connect` step, matching the
experience of other camera/NVR and ML-accelerator snaps that request the
same interface for USB accelerator hardware.

---

## Request 2: `hardware-observe`

**Snap name:** frigate
**Snap ID:** _(fill in — from `snapcraft list-registered` after registration)_
**Publisher:** _(fill in — the Snap Store account `frigate` is registered under)_
**Interface:** `hardware-observe`
**Requested:** auto-connect on install

### What the snap is

Frigate is a network video recorder with local, real-time AI object
detection for security cameras. This snap packages it under strict
confinement (no Docker, no classic confinement) for Ubuntu/snapd systems.

### Why `hardware-observe` is needed

This pairs with the `raw-usb` request above. Before `libusb` can open the
Coral USB Accelerator's raw device node, it needs to enumerate the USB bus
and read each device's descriptors (vendor/product ID, device class) from
`/sys/bus/usb/devices/` to find the accelerator in the first place —
including recognizing it after the firmware-upload re-enumeration
described above (`1a6e:089a` → `18d1:9302`). That enumeration step reads
from sysfs, which is what `hardware-observe` grants. Without it, `libusb`
cannot locate the device at all, regardless of `raw-usb` access to the
device node itself.

### Auto-connect justification

`hardware-observe` is the standard companion interface to `raw-usb` for
USB-device enumeration; requesting it alongside `raw-usb` (rather than
leaving Coral USB support half-connected) avoids a confusing user
experience where one manual connect silently isn't enough. The interface
grants read-only observation of hardware topology, not device control —
the actual device access is gated separately by `raw-usb`.

---

## Request 3: `shm-private` (`shared-memory`, private)

**Snap name:** frigate
**Snap ID:** _(fill in — from `snapcraft list-registered` after registration)_
**Publisher:** _(fill in — the Snap Store account `frigate` is registered under)_
**Interface:** `shared-memory` (plug declared `private: true`)
**Requested:** auto-connect on install

### What the snap is

Frigate is a network video recorder with local, real-time AI object
detection for security cameras. This snap packages it under strict
confinement (no Docker, no classic confinement) for Ubuntu/snapd systems.

### Why `shm-private` is needed

Frigate's camera pipeline decodes and buffers video frames through
`/dev/shm`-backed shared memory: each camera stream gets a ring of frame
buffers sized by resolution, and Frigate's Python multiprocessing layer
(used to run detection workers and inter-process camera coordination)
opens POSIX named semaphores under `/dev/shm` as well. With even a couple
of cameras at typical resolutions, this is routinely multiple gigabytes of
live shared memory — far beyond what the default snap sandbox's shared
`/dev/shm` allocation is sized for, and shared with every other snap on
the host besides. The `shared-memory` interface with `private: true` gives
the snap its own private `/dev/shm` tmpfs instead, sized independently and
isolated from other snaps' shared-memory usage — this is a correctness
requirement (Frigate's multiprocessing semaphore creation fails outright
without a writable, sufficiently large private `/dev/shm`), not a
performance tweak.

### Auto-connect justification

This interface only grants the snap a private, isolated `/dev/shm` — it
does not grant access to any other snap's or the host's shared memory
segments. Frigate is non-functional without it (camera detection workers
fail to start), so a manual connect step means the snap simply doesn't
work until the user diagnoses and runs it; that's a poor first-run
experience for what is core, non-optional functionality of an NVR, not an
optional accelerator.

---

## Request 4: `mount-observe`

**Snap name:** frigate
**Snap ID:** _(fill in — from `snapcraft list-registered` after registration)_
**Publisher:** _(fill in — the Snap Store account `frigate` is registered under)_
**Interface:** `mount-observe`
**Requested:** auto-connect on install

### What the snap is

Frigate is a network video recorder with local, real-time AI object
detection for security cameras. This snap packages it under strict
confinement (no Docker, no classic confinement) for Ubuntu/snapd systems.

### Why `mount-observe` is needed

This follows directly from the private `/dev/shm` request above. To size
its shared-memory frame buffers correctly per camera, Frigate's camera
maintainer reads mount information via Python's `psutil` library
(`psutil.disk_partitions()`), which reads `/proc/<pid>/mounts` to
determine the filesystem type and available space backing `/dev/shm`.
Without read access to mount information, this call raises a
`PermissionError` that crashes Frigate's main process before its API can
even start — this is not a degraded-mode failure, it's a startup crash.

### Auto-connect justification

`mount-observe` grants read-only visibility into mount points and
filesystem info, not write or control access to anything. Frigate needs
it purely to size an already-private, already-isolated resource
(`shm-private`, requested above) correctly; the two requests are two
halves of the same "camera frame buffers must be sized correctly to
work at all" requirement. As with `shm-private`, this is core
functionality, not an optional accelerator path, so a manual `snap
connect` step means the snap doesn't run until the user works around it.
