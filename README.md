# Frigate (snap)

[Frigate](https://frigate.video) is a network video recorder with real-time,
local AI object detection for your security cameras — no cloud, no
subscription. This package installs Frigate as a native
[snap](https://snapcraft.io): no Docker, no container runtime, no manual
dependency wrangling. It runs under strict confinement, so every path it can
touch on your system is explicit and auditable.

Under the hood the snap runs four cooperating services — `go2rtc` (camera
stream restreaming), `frigate` (the NVR core and detection engine), `nginx`
(the HTTPS web UI and API proxy), and `certsync` (keeps nginx in sync with
your TLS certificate) — plus a handful of one-shot diagnostic commands for
checking hardware access.

## Install

```
sudo snap install frigate --channel=latest/edge
```

The snap currently ships to the `edge` channel while it works through Snap
Store review. Once it has been verified on a clean machine it will be
promoted to `beta` — if a `beta` channel is available when you read this,
prefer it:

```
sudo snap install frigate --channel=latest/beta
```

## Connect interfaces

Strict confinement means the snap only gets access to hardware you
explicitly grant. A few interfaces can't be auto-connected yet (the Snap
Store auto-connect requests are filed but not yet approved — see
`docs/store/auto-connect-requests.md`), so connect them by hand after
install:

```
sudo snap connect frigate:raw-usb
sudo snap connect frigate:hardware-observe
sudo snap connect frigate:shm-private snapd:shared-memory
sudo snap connect frigate:mount-observe
```

- `raw-usb` + `hardware-observe` — only needed if you use a **Coral USB
  Accelerator**. Skip these if you're using the default OpenVINO detector or
  CPU fallback.
- `shm-private` and `mount-observe` — needed by the `frigate` daemon itself
  (private shared-memory frame buffers, and sizing them correctly). Connect
  these regardless of which detector you use.

Now restart so the daemons pick up the new permissions — they start at
install time, *before* you run these connects, so `frigate` crash-loops (its
boot-time `mount-observe` check fails) until you restart once, a step that
becomes unnecessary once the Store auto-connect requests are approved:

```
sudo snap restart frigate
```

Your Intel/AMD GPU is wired up automatically via the `gpu` content
interface — no manual connect needed there. This relies on the snap's
default content-provider being auto-connected by snapd at install time; if
GPU detection doesn't come up, confirm the `gpu` plug is actually connected
with `snap connections frigate` before troubleshooting further.

Check what's connected at any time with:

```
snap connections frigate
```

## First start

On first start, `nginx` generates a self-signed TLS certificate if one
doesn't already exist. With the default RSA-4096 profile this takes about
24 seconds — the web UI won't answer until it's done, and this only happens
once. Give the snap a minute after install before you point a browser at it.

## First login

Open `https://<host>:8971` in a browser (your own self-signed cert, so
expect a certificate warning the first time — that's expected, not an
error).

Frigate creates an admin account and logs its password to the journal
**once**, the first time it starts with no existing users. Retrieve it with:

```
sudo snap logs -n=all frigate.frigate | grep -A2 Password
```

You're looking for a line shaped like this (the value shown here is a
placeholder, not a real password):

```
[2026-07-08 00:08:01] frigate.app                    INFO    : ***    Password: ################################   ***
```

The password is 32 lowercase hex characters. Log in with username `admin`
and that password, then change it right away from the Frigate UI — a new
admin password is only ever logged when the user table is empty, so if you
lose track of it later there's no supported way to have Frigate print it
again short of resetting its database.

## Camera setup

Frigate's configuration lives at:

```
/var/snap/frigate/current/config/config.yml
```

This file is generated once, the first time Frigate starts. After that,
**it's yours** — edit it to add your cameras, and restart Frigate to apply
your changes:

```
sudo snap restart frigate
```

Restart the **whole snap** (`frigate`), not just `frigate.frigate`: the
internal `go2rtc` regenerates its own config from your `config.yml` at
start, so a camera change needs both services cycled — the whole-snap
restart covers it.

Snap refreshes never touch an existing `config.yml`; a new snap revision's
template updates only apply to a config that doesn't exist yet. (The one
exception is Frigate itself: 0.18 migrates the file on its first boot — see
"Upgrading to 0.18" below.) If you want
to discard your edits and start over from the shipped defaults, delete the
file and restart:

```
sudo rm /var/snap/frigate/current/config/config.yml
sudo snap restart frigate
```

### Adding a camera (go2rtc restream)

The recommended pattern is Frigate's standard one: declare each camera's
streams once under a top-level `go2rtc:` block, then point the camera's
ffmpeg inputs at the snap's internal `go2rtc` over loopback RTSP
(`rtsp://127.0.0.1:8554/<stream>`). go2rtc pulls the camera once and
restreams it, so Frigate's record and detect roles share a single
connection to the camera. A worked example with a main (record) and a sub
(detect) stream:

```yaml
go2rtc:
  streams:
    front_door:
      - rtsp://USER:PASSWORD@192.168.1.10:554/stream1
    front_door_sub:
      - rtsp://USER:PASSWORD@192.168.1.10:554/stream2

cameras:
  front_door:
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:8554/front_door
          roles:
            - record
        - path: rtsp://127.0.0.1:8554/front_door_sub
          roles:
            - detect
    detect:
      enabled: true
      fps: 5
```

Detection runs inference on every frame of the detect stream, and most
cameras deliver it at their native 20–30 fps — left unset, that's pure
wasted inference. `fps: 5` above caps the detect stream at Frigate's
recommended detection rate. Recordings are unaffected: the `record` role
keeps decoding the full stream at its native rate regardless.

Then apply with `sudo snap restart frigate` (whole snap — see above). The
snap reads your `go2rtc:` block straight out of `config.yml`, exactly as
upstream Frigate does, so streams referenced as `rtsp://127.0.0.1:8554/...`
resolve instead of returning RTSP 404s.

### Built-in demo camera

A fresh install ships with a built-in demo camera named `testclip` — a
short pedestrian clip that loops forever — so a brand-new install shows a
working pipeline (live view, object detection, recordings) the moment it
comes up, before you've added any real cameras. It's handy for a first
look, but it isn't free: it continuously decodes and re-encodes video, so
it costs CPU, and it records to disk (bounded — 1 day of retention).

When you start adding real cameras, remove it. In `config.yml`, delete the
whole `testclip:` block under `cameras:` (from the `testclip:` line through
its `objects:` list), then restart the snap:

```
sudo snap restart frigate
```

The clip itself is streamed by the snap's internal `go2rtc` on demand:
once no camera references it, that stream stops on its own, so there's
nothing else to clean up.

Two things worth knowing before you rely on this setup long-term:

- **The self-signed certificate expires after 365 days** and nothing
  renews it automatically. When it does, or whenever you want a fresh one,
  delete the certificate files and restart nginx to regenerate:
  `/etc/letsencrypt/live/frigate/{privkey,fullchain}.pem` inside the snap's
  view of the filesystem (reachable as
  `/var/snap/frigate/current/letsencrypt/live/frigate/`).
- **If you disable TLS** (`snap set frigate tls.enabled=false`, see below),
  be aware that any browser that has already loaded the UI over HTTPS will
  have cached an HSTS policy (`max-age` two years) telling it to *always*
  use HTTPS for this host — it will refuse to fall back to plain HTTP on
  its own. You'll need to clear that browser's HSTS state for the host (or
  use a different browser) to reach the plain-HTTP UI. Also note that
  Frigate's own `config.yml` has an independent `auth.cookie_secure`
  setting (defaults to `true`, matching TLS-on) — that key is
  operator-owned like the rest of `config.yml` and isn't touched by
  `snap set`; if you turn TLS off, set `cookie_secure: false` there too or
  the login cookie won't be sent over plain HTTP.

### Semantic search

Frigate can index past events for natural-language search using an
embeddings model. Enable it by adding a `semantic_search:` block to
`config.yml`:

```yaml
semantic_search:
  enabled: true
```

then restart the whole snap (`sudo snap restart frigate` — see above). The
first time you enable it, Frigate downloads its embedding models (Jina
CLIP v1, plus the face and OCR models) — the download
needs internet access and can take several minutes depending on your
connection. Once it finishes, Frigate indexes your existing events in the
background. The models land in
`/var/snap/frigate/current/config/model_cache`, alongside your config, and
persist across snap refreshes — the download happens once, not on every
update.

If Frigate logs a `sqlite-vec` load error after you enable this, your
installed snap build predates sqlite extension support — refresh to the
latest revision (`sudo snap refresh frigate`) and restart.

## Configuration (`snap set`)

The snap exposes a small set of configuration keys via `snap set`/`snap
get`:

| Key | Default | Range / values | Notes |
|---|---|---|---|
| `ports.https` | `8971` | `1024`–`65535` | The port nginx serves the HTTPS UI/API on. |
| `tls.enabled` | `true` | `true` \| `false` | `false` serves plain HTTP on `ports.https` instead of TLS. See the HSTS caveat above before flipping this off. |
| `tls.cert-profile` | `rsa-4096` | `rsa-4096` \| `ecdsa-p256` | Self-signed certificate type generated on first start (when no cert exists yet). `ecdsa-p256` generates much faster than the RSA-4096 default. |
| `certsync.interval` | `60` | `10`–`3600` (seconds) | How often the `certsync` daemon checks for a changed TLS certificate on disk and reloads nginx. |
| `detector` | unset (auto) | `ov` \| `coral` \| `cpu` | Which object detector Frigate is configured to use. **Applied at config render time only** — the first time Frigate starts, or after you delete `config.yml` and restart (see "Camera setup" above). Setting this on an already-configured install has no effect until you regenerate the config. |

Example:

```
sudo snap set frigate ports.https=9443
sudo snap set frigate tls.cert-profile=ecdsa-p256
```

When `detector` is left unset, the snap auto-detects at config render time:
if an Intel or AMD GPU render node is present, it configures the OpenVINO
(`ov`) detector; otherwise it falls back to `cpu`. Set `detector=coral`
explicitly (and delete/regenerate `config.yml`) to use a Coral USB
Accelerator instead — see the accelerator matrix below for the full setup
procedure.

## Upgrading to 0.18

Snap version 0.18.2 ships Frigate 0.18.2. The migration is one-way, so
read this before you refresh a working install.

- **The first boot under 0.18 rewrites `config.yml`.** Frigate's own
  migrator brings the file to `version: 0.18-0` and keeps the previous copy
  as `backup_config.yaml` next to it. The snap itself still never rewrites
  your config. The rewrite may also re-flow the file's formatting, not only
  change `version`. Edits made under 0.18 are **lost on `snap revert`**: a
  revert goes back to the 0.17 `config.yml`, which 0.17 can read, and not to
  your newer file.
- **ffmpeg 8 is now the default.** The snap ships ffmpeg 5.0, 7.0 and 8.0
  and Frigate uses 8.0 unless you say otherwise. go2rtc streams that use
  `#hardware` transcoding need one of these workarounds in `config.yml`:

  ```yaml
  go2rtc:
    ffmpeg:
      global: "-vaapi_device /dev/dri/renderD128"
  ```

  or switch to the 7.0 tree:

  ```yaml
  ffmpeg:
    path: "7.0"
  ```

  `ffmpeg.path` is Frigate's own setting, so it moves Frigate's camera
  pipelines (detect and record) to 7.0 too, not only go2rtc. Export
  thumbnails still use the 8.0 tree, whose path Frigate hardcodes. An explicit
  `go2rtc.ffmpeg.bin` always wins over `ffmpeg.path` for go2rtc.
- **`exec:`, `echo:` and `expr:` go2rtc streams.** Upstream 0.18 drops these
  stream sources unless `GO2RTC_ALLOW_ARBITRARY_EXEC` is set, because the web
  UI can now edit the go2rtc section. Frigate 0.18.2's own API already rejects
  *new* sources of these types when a config or stream is saved from the UI,
  so the gap that remains is a hand-edited `config.yml`. This snap does **not**
  filter them there yet; the filter is planned but not part of this revision.
  Do not rely on it, and avoid `exec:` sources you did not write yourself.
- **Intel GPU stats need a recent kernel.** Upstream's requirement is Linux
  5.19 or newer with the `i915` driver (6.5 or newer on 12th-gen and newer
  Intel GPUs), or any kernel with the `xe` driver, on a Broadwell (5th-gen) or
  newer GPU. With VAAPI or QSV camera hwaccel, Frigate 0.18 reads
  `/proc/*/fdinfo` on every stats poll to find GPU usage. Under this snap's
  strict confinement that scan is **unproven**: it has not run on Intel
  hardware yet, so whether it works or only produces AppArmor denials is not
  known. To turn the scan off, set this in `config.yml`:

  ```yaml
  telemetry:
    stats:
      intel_gpu_stats: false
  ```
- **Toggles persist in `.runtime_state.json`.** Settings you change in the UI
  or over MQTT are stored in
  `/var/snap/frigate/current/config/.runtime_state.json`. A full reset to the
  shipped defaults means deleting that file **and** `config.yml`, then
  restarting:

  ```
  sudo rm /var/snap/frigate/current/config/config.yml \
          /var/snap/frigate/current/config/.runtime_state.json \
          /var/snap/frigate/current/config/.runtime_state.json.lock
  sudo snap restart frigate
  ```
- **`networking.listen.*` is ignored.** Ports come from the snap options
  (`ports.https`, see above), not from Frigate's config.
- **Reverting to 0.17.** The database part of this list is spec-derived
  (D11/D12). The revert rehearsal (#2, phase C) confirmed it on the local
  candidate: green, integrity check ok, 0.17.2 restored its backup and served
  its data (see `docs/m9-findings.md`).
  - `sudo snap revert frigate` works only while the 0.17 revision is still
    on the system. Check with `snap list --all frigate`. snapd keeps 2
    revisions by default on classic systems (3 on Ubuntu Core; the
    `refresh.retain` system option), so on classic the next refresh after
    the move to 0.18 removes the 0.17 revision.
  - On the first 0.17 start after the revert, the snap restores the database
    from the backup taken before the refresh. Events, review items and
    exports created under 0.18 disappear from the UI.
  - The 0.18 database is kept, not deleted, as
    `/var/snap/frigate/common/db/frigate.db.incompatible-<timestamp>`.
  - Recording files written under 0.18 stay on disk with no database rows,
    so 0.17's retention never deletes them. Remove them by hand, or set
    0.17's `record.sync_recordings: true`, which deletes recording files
    that have no database entry (it gives up if more than half of the files
    would go).
- **Reverting safely.** On every stop (including the stop a `snap revert` or refresh performs) the 0.18 snap checkpoints its database and leaves `frigate.db` without `-wal`/`-shm` files, so the older revision's restore cannot be corrupted by a stale write-ahead log. That stop hook does not finish on power loss during the revert, or if it runs out of time; and if another process still holds the database it gives up with `result=busy` and leaves the write-ahead log in place. To revert deliberately, run `sudo snap stop frigate.frigate` first, check that `journalctl -u snap.frigate.frigate.service -n 20` shows `frigate-db-quiesce: … result=ok` (only `result=ok` is safe; `busy`, `timeout` or `error:…` are not), then `sudo snap revert frigate`.

## Diagnostics

The snap ships a few one-shot commands for checking hardware access
directly, useful when troubleshooting a detector or accelerator:

- `frigate.gpu-probe` — lists GPU devices OpenVINO can see, plus a VAAPI
  info dump.
- `frigate.coral-probe` — loads the Coral USB Accelerator delegate and runs
  a test inference.
- `frigate.vaapi-probe` — proves hardware video decode works end to end.
- `frigate.mdns-probe` — checks mDNS multicast reachability.
- `frigate.validate-config` — validates `config.yml` the same way Frigate
  itself does at startup, without starting the full daemon.
- `frigate.imports-probe` — checks that every bundled Python module (numpy,
  OpenVINO, TensorFlow, the sqlite-vec search extension, …) imports cleanly
  and re-checks shared-memory behaviour under confinement. Handy when a
  detector fails to start and you want to rule out a broken dependency.

Run any of them directly, e.g. `sudo snap run frigate.gpu-probe`.

The web UI's **Logs** page shows live output on all three tabs — nginx from its
error log, and Frigate and go2rtc from the snap's log tee. The authoritative
logs are always available from the host:

```
sudo snap logs -f frigate.frigate
sudo snap logs -f frigate.go2rtc
sudo journalctl -u snap.frigate.frigate
```

## Accelerators

For the full accelerator support matrix (CPU, Intel/AMD GPU, Coral USB,
Coral PCIe/M.2, NVIDIA), Coral USB setup steps, and the CPU fallback
procedure, see [`docs/accelerator-support.md`](docs/accelerator-support.md).

Two things worth calling out here:

- **Intel NPU is not yet supported** as a detector — tracked for a future
  release.
- **arm64 is planned** but not available yet; this snap currently ships for
  `amd64` only.

## Known upstream issues

- **`/config` shows go2rtc credentials to logged-in users.** At Frigate
  v0.18.2 the `/config` endpoint redacts `user:pass` in go2rtc stream URLs,
  but not the username and password of the `go2rtc.rtsp`, `go2rtc.api` and
  `go2rtc.mqtt` sections. Any logged-in user can read them. Upstream fixed
  this on its development branch only, so v0.18.2 is affected (checked: the
  fix, `_redact_go2rtc_credentials`, is absent from the v0.18.2 tag). This
  snap carries no Frigate behaviour patches and does not fix it. Do not reuse
  those credentials anywhere else, and give accounts only to people you would
  trust with them.
- **Advisories that are still open in Frigate 0.18.2** (no patched version
  listed upstream):
  - GHSA-w3c4: server-side request forgery through web push, because the
    check at registration time does not match what is resolved or redirected
    at send time.
  - GHSA-4xp7: a go2rtc RTSP panic on a negative `Content-Length`. The
    affected code is identical in the go2rtc version the snap shipped before
    (1.9.13), so the upgrade adds no exposure here. It needs an attacker-
    controlled RTSP source URL.
  - GHSA-74x4: camera access-control bypass through the nginx static
    locations (recordings of cameras a user may not see). It lists all
    versions as affected. This snap mirrors upstream's nginx layout.

  How much these matter on a single-admin install has not been assessed.

## Getting help

Source, issue tracker, and build instructions:
<https://github.com/giaever-online-iot/frigate>
