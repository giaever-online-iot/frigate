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

Your Intel/AMD GPU is wired up automatically via the `gpu` content
interface — no manual connect needed there.

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
sudo snap restart frigate.frigate
```

Snap refreshes never touch an existing `config.yml`; a new snap revision's
template updates only apply to a config that doesn't exist yet. If you want
to discard your edits and start over from the shipped defaults, delete the
file and restart:

```
sudo rm /var/snap/frigate/current/config/config.yml
sudo snap restart frigate.frigate
```

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

## Diagnostics

The snap ships a few one-shot commands for checking hardware access
directly, useful when troubleshooting a detector or accelerator:

- `frigate.gpu-probe` — lists GPU devices OpenVINO can see, plus a VAAPI
  info dump.
- `frigate.coral-probe` — loads the Coral USB Accelerator delegate and runs
  a test inference.
- `frigate.vaapi-probe` — proves hardware video decode works end to end.
- `frigate.npu-probe` — checks whether the Intel NPU device node is
  reachable (see "Accelerators" below — NPU isn't a supported detector
  yet).
- `frigate.mdns-probe` — checks mDNS multicast reachability.
- `frigate.validate-config` — validates `config.yml` the same way Frigate
  itself does at startup, without starting the full daemon.

Run any of them directly, e.g. `sudo snap run frigate.gpu-probe`.

## Accelerators

For the full accelerator support matrix (CPU, Intel/AMD GPU, Coral USB,
Coral PCIe/M.2, NVIDIA), Coral USB setup steps, and the CPU fallback
procedure, see [`docs/accelerator-support.md`](docs/accelerator-support.md).

Two things worth calling out here:

- **Intel NPU is not yet supported** as a detector — tracked for a future
  release.
- **arm64 is planned** but not available yet; this snap currently ships for
  `amd64` only.

## Getting help

Source, issue tracker, and build instructions:
<https://github.com/giaever-online-iot/frigate>
