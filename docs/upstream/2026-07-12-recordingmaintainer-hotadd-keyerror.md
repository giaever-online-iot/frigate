# RecordingMaintainer: repeating `KeyError` for a camera added via the UI without a restart

> Draft upstream issue for https://github.com/blakeblackshear/frigate
> Status: **UPSTREAM-CONFIRMED** on the official `ghcr.io/blakeblackshear/frigate:0.17.2` image.
> Paste the section below the line into a new GitHub issue.

---

### Describe the problem you are having

When a camera is added through the UI (Settings → Add camera / the camera wizard) while Frigate is
running, the recording maintainer starts logging an endless stream of errors, once per maintenance
cycle, and never records the new camera:

```
frigate.record.maintainer      ERROR   : Error occurred when attempting to maintain recording cache
frigate.record.maintainer      ERROR   : 'cam2'
```

`'cam2'` is the name of the newly added camera. The errors repeat for as long as the process keeps
running and only stop after a full Frigate restart. Recordings for the new camera are dropped for the
whole affected window.

The UI reports the add succeeded ("Config successfully updated, restart to apply"), the camera appears
in the config and starts producing recording segments in the cache, but the recording maintainer is
working from a stale in-memory config snapshot that never learns about the new camera.

This reproduces only when the maintainer started with **exactly one camera** and a **second** camera is
added at runtime (see analysis for why). It was first noticed on a snap-packaged deployment and then
reproduced on the plain official Docker image, so it does not appear to be packaging-specific.

### Version

0.17.2-3d4dd3a (official image `ghcr.io/blakeblackshear/frigate:0.17.2`,
digest `sha256:d4351369984d4a9e2a49ac59736f6490856a7ea11f7790040746d21496967010`)

### Frigate config file

Start with a single camera and recording enabled (a synthetic `go2rtc` source is used here so the
report is self-contained; a real camera reproduces it identically):

```yaml
mqtt:
  enabled: false

go2rtc:
  streams:
    cam1: "exec:/usr/lib/ffmpeg/7.0/bin/ffmpeg -hide_banner -re -f lavfi -i testsrc=size=1280x720:rate=5 -c:v libx264 -profile:v baseline -tune zerolatency -pix_fmt yuv420p -g 10 -bsf:v dump_extra -rtsp_transport tcp -f rtsp {{output}}"
    cam2: "exec:/usr/lib/ffmpeg/7.0/bin/ffmpeg -hide_banner -re -f lavfi -i testsrc=size=1280x720:rate=5 -c:v libx264 -profile:v baseline -tune zerolatency -pix_fmt yuv420p -g 10 -bsf:v dump_extra -rtsp_transport tcp -f rtsp {{output}}"

record:
  enabled: true
  retain:
    days: 1
    mode: all

detect:
  enabled: false

cameras:
  cam1:
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:8554/cam1
          roles:
            - detect
            - record
```

(To run the synthetic `exec:` sources the container needs `GO2RTC_ALLOW_ARBITRARY_EXEC=true` set in
its environment; the config above already spells out the absolute ffmpeg path
`/usr/lib/ffmpeg/7.0/bin/ffmpeg` the image ships. Neither is related to the bug — any two working
cameras reproduce it.)

### Relevant Frigate log output

Before the add, the maintainer is quiet. Immediately after `cam2` is added at runtime and begins
producing cache segments, every maintenance cycle fails:

```
[2026-07-12 19:32:51] frigate.record.maintainer      ERROR   : Error occurred when attempting to maintain recording cache
[2026-07-12 19:32:51] frigate.record.maintainer      ERROR   : 'cam2'
[2026-07-12 19:32:56] frigate.record.maintainer      ERROR   : Error occurred when attempting to maintain recording cache
[2026-07-12 19:32:56] frigate.record.maintainer      ERROR   : 'cam2'
[2026-07-12 19:33:01] frigate.record.maintainer      ERROR   : Error occurred when attempting to maintain recording cache
[2026-07-12 19:33:01] frigate.record.maintainer      ERROR   : 'cam2'
```

(The maintenance loop runs about every 5 s in this minimal setup; the interval grows with the amount of
per-cycle recording work, so busier systems see it further apart.)

The error message is `KeyError: 'cam2'`; only the key is printed because the handler in
`RecordingMaintainer.run()` does `logger.error(e)` on the caught exception.

### Steps to reproduce

1. Run 0.17.2 with the config above (one camera, `record.enabled: true`). Confirm `cam1` records
   (segments appear in the cache and under `/media/frigate/recordings`).
2. Add a second camera the way the UI does — a single `PUT /api/config/set` with an `add` update topic
   and **no restart**. This is exactly the request `web/src/components/settings/CameraEditForm.tsx`
   sends for a new camera:

   ```
   PUT /api/config/set
   Content-Type: application/json

   {
     "requires_restart": 1,
     "config_data": {
       "cameras": {
         "cam2": {
           "enabled": true,
           "ffmpeg": {
             "inputs": [
               { "path": "rtsp://127.0.0.1:8554/cam2", "roles": ["detect", "record"] }
             ]
           }
         }
       }
     },
     "update_topic": "config/cameras/cam2/add"
   }
   ```

   Response: `200 {"success": true, "message": "Config successfully updated, restart to apply"}`.
   Note that even though `requires_restart` is `1`, `/config/set` never restarts Frigate; because an
   `update_topic` is present it takes the dynamic in-process path and publishes a
   `config/cameras/cam2/add` update instead (see `frigate/api/app.py`, `config_set`).
3. Wait for `cam2` to start producing recording segments. The `frigate.record.maintainer` errors above
   begin and repeat every cycle.
4. Restart Frigate — the errors stop and `cam2` records normally.

### Analysis (pointers, not a fix)

`RecordingMaintainer` reads the camera set through `self.config.cameras[...]` at several sites in
`frigate/record/maintainer.py` (e.g. the "publish saved recording", `validate_and_move_segment`, and
detection-info paths). The `camera` key at those sites comes from the recording **cache files on disk**,
so once `cam2` writes segments the maintainer looks up `self.config.cameras['cam2']` and raises
`KeyError` because its config snapshot still only contains `cam1`.

The snapshot is supposed to be kept current by `CameraConfigUpdateSubscriber` (subscribed to the `add`
and `record` topics). The gap is in how that subscriber filters at the ZeroMQ level:

- `frigate/config/camera/updater.py`, `CameraConfigUpdateSubscriber.__init__`:

  ```python
  base_topic = "config/cameras"
  if len(self.camera_configs) == 1:
      base_topic += f"/{list(self.camera_configs.keys())[0]}"
  self.subscriber = ConfigSubscriber(base_topic, exact=False)
  ```

  When the maintainer starts with a single camera, the base topic is narrowed to
  `config/cameras/<that camera>`.

- `frigate/comms/config_updater.py`, `ConfigSubscriber.__init__` applies that string as a ZeroMQ
  prefix subscription:

  ```python
  self.socket.setsockopt_string(zmq.SUBSCRIBE, topic)
  ```

  ZeroMQ `SUBSCRIBE` is a prefix filter, so with the narrowed topic the socket only ever delivers
  messages beginning with `config/cameras/<existing camera>`.

Because the new camera's update is published on `config/cameras/cam2/add`, it does not match the
`config/cameras/cam1` prefix and is dropped at the socket. `__update_config` is never called for the
add, so `self.config.cameras` never gains `cam2`, and the maintainer keeps raising `KeyError` every
cycle until a restart rebuilds the config with both cameras (at which point `len(camera_configs)` is no
longer 1 and the topic is not narrowed).

This means the failure is specific to the **single-camera → add second camera** transition. An install
that already has two or more cameras when the maintainer starts is not affected, because the base topic
is left as `config/cameras` and the `add` is delivered.

### Expected behavior

A camera added through the UI without a restart should be recorded (or at least not throw), the same as
any pre-existing camera.

### Workaround

Restart Frigate after adding a camera through the UI. The "restart to apply" hint in the success
message is effectively required for the recording maintainer even though the config-set path itself
does not restart.
