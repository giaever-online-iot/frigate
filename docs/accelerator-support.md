# Accelerator support

Frigate needs a hardware object detector to find people, cars, and other
objects in your camera streams. This snap ships an OpenVINO detector by
default, which runs on your Intel or AMD integrated GPU, and also supports
the Coral USB Accelerator as an alternative detector. Which accelerators
work, and how well, depends on your hardware and on strict confinement's
rules about what a snap is allowed to touch on your system. This page is
the support matrix: what works out of the box, what needs manual setup,
and what isn't supported at all.

## Support matrix

| Accelerator | Status | Notes |
|---|---|---|
| CPU | Works out of the box | No setup required. Slow — fine for trying Frigate out, but not recommended for more than one camera. |
| Intel/AMD iGPU (OpenVINO / VAAPI) | Supported — shipped default | Uses the GPU content interface, which is wired up automatically when you install from the Snap Store. No manual `snap connect` needed. |
| Coral USB | Supported | Needs two manual connects and a config change. See "Coral USB setup" below. |
| Coral PCIe / M.2 (`/dev/apex_0`) | Not supported | Strict confinement has no interface for this device class. There is no way to grant a strictly-confined snap access to `/dev/apex_0` today. |
| Intel NPU | Not yet supported | Tracked for a future release. |
| NVIDIA GPU | Not supported | See "NVIDIA" below. |

## Coral USB setup

The Coral USB Accelerator needs two interfaces connected by hand — the
Snap Store cannot auto-connect these for you:

```
sudo snap connect frigate:raw-usb
sudo snap connect frigate:hardware-observe
```

Next, switch Frigate's detector configuration from OpenVINO to Coral. Open
`/var/snap/frigate/current/config/config.yml` and replace the `detectors:`
and `model:` blocks with:

```yaml
detectors:
  coral:
    type: edgetpu
    device: usb
model:
  path: /opt/frigate/models/edgetpu/edgetpu_model.tflite
  labelmap_path: /opt/frigate/models/labelmap.txt
  width: 320
  height: 320
  input_tensor: nhwc
  input_pixel_format: rgb
  model_type: ssd
```

Then restart Frigate to pick up the change:

```
sudo snap restart frigate.frigate
```

The first time the Coral stick is used, it uploads firmware and
re-enumerates on the USB bus (its device ID changes from `1a6e:089a` to
`18d1:9302`). If the detector fails to start on this very first boot,
restart once more — it will come up normally after that.

## One detector type at a time

Frigate applies a single global model configuration to every object
detector you configure. This means you cannot mix detector types with
different model geometries — for example, running Coral and OpenVINO at
the same time — because they need different model files and input shapes,
and Frigate only has one slot for that configuration. Pick one detector
type for object detection. This doesn't affect other enrichments (such as
semantic search or audio detection), which are independent of the object
detector.

## NVIDIA

This snap does not support NVIDIA GPUs for detection or hardware video
decoding. Strict confinement can ship and reach open-source, Mesa-based
GPU drivers (which is how the Intel/AMD iGPU support above works), but it
cannot ship or reach NVIDIA's proprietary userspace — the CUDA and
TensorRT stacks, and NVDEC decoding, are tightly coupled to a matching
host driver in a way that doesn't fit the strict-confinement model.

If you have an NVIDIA GPU, use upstream Frigate's Docker image instead,
which supports NVIDIA acceleration directly. A classic-confinement
variant of this snap may be evaluated in the future to close this gap.

## Verification note

For the evidence behind these results — the specific tests run, hardware
used, and log output collected while proving out each accelerator — see
`docs/m6-findings.md`.
