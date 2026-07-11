#!/usr/bin/env python3.11
# shellcheck disable=SC1071
# ^ This is PYTHON, not shell. It lives in spike/bin/ because the wrappers dump part ships
# this directory to $SNAP/bin/, but CI's lint job shellchecks spike/bin/* wholesale; the
# python shebang + directive make shellcheck skip the file (unsupported dialect, disabled)
# instead of parsing python as sh. The shebang is documentation — bin/go2rtc-run invokes
# this explicitly via the snap's python3.11, so the file needs no +x bit.
"""Generate the go2rtc config from the snap baseline layered with the operator's
config.yml `go2rtc:` section.

WHY THIS EXISTS
---------------
Upstream Frigate GENERATES go2rtc's config from config.yml
(docker/main/rootfs/usr/local/go2rtc/create_config.py). The snap previously rendered
a STATIC template and never read config.yml, so cameras added the upstream-documented
way (a `go2rtc:` block in config.yml + camera inputs via rtsp://127.0.0.1:8554/<stream>)
produced RTSP 404s — go2rtc had never heard of those streams. This generator restores
upstream parity: config.yml's `go2rtc:` section now flows through to go2rtc.

Invoked by bin/go2rtc-run on EVERY start with:
    python3.11 go2rtc-config-gen.py <baseline.in> <config.yml> <SNAP> <output.yaml>

MODEL (mirrors create_config.py's layering; divergences flagged DIVERGENCE below):
  1. Start from the snap BASELINE (config/go2rtc.yaml.in: loopback api listen,
     rtsp :8554, webrtc :8555, the test/testclip exec streams). __SNAP__ -> $SNAP.
     Upstream has no template baseline — its "baseline" is only the defaults it seeds;
     the snap additionally ships fixed listens + synthetic test streams, so those live
     in the template and the operator's section layers OVER them.
  2. Deep-merge the operator's `go2rtc:` mapping OVER the baseline (operator wins per
     key; `streams` dicts UNION so operator cameras coexist with the test streams).
  3. FORCE api.listen = 127.0.0.1:1984 afterward, regardless of operator value
     (M5 security ruling: the go2rtc control API/UI is loopback-only in this snap;
     browsers reach it via nginx's authed /live/* proxy). A redacted warning is logged
     if the operator tried to change it — the attempted value is NEVER printed.
  4. Seed upstream defaults where the operator left keys absent (api.origin="*",
     log.format="text", webrtc.candidates=[...,"stun:8555"], ffmpeg.bin).
  5. Absent config.yml / absent `go2rtc:` key -> baseline only (first boot: go2rtc
     starts before frigate ever renders config.yml).

Output is written under umask 077 (operator stream URLs may carry credentials) and its
contents are NEVER printed (config.yml embeds a camera secret on operator hosts).

DIVERGENCES from create_config.py (deliberate, documented):
  * hass.config default (/homeassistant) is NOT seeded — the snap is not the HA OS
    add-on; that path does not exist under strict confinement.
  * ffmpeg4 rtsp_args (LIBAVFORMAT_VERSION_MAJOR < 59) is NOT applied — the snap ships
    ffmpeg >= 7.0 (libavformat >= 59).
  * FRIGATE_* env-var substitution on stream URLs is NOT performed — the go2rtc app
    context carries no FRIGATE_* vars (secrets are embedded directly in config.yml under
    root 0600), and str.format() would additionally corrupt literal `{output}` in the
    baseline exec streams.
  * restricted-source (exec/echo/expr) filtering is NOT applied — the baseline itself
    ships exec streams, config.yml is operator-owned (root 0600, not a remote surface),
    and go2rtc runs strict-confined.
  * birdseye restream stream generation is NOT wired — it needs frigate module imports
    in the go2rtc context; out of scope for the config bridge.
  * A config.yml that fails to parse falls back to BASELINE-ONLY (go2rtc still starts,
    serving the test streams) with a redacted warning, rather than aborting — frigate
    surfaces the same parse error loudly to the operator. Unexpected/internal errors
    (missing baseline, unwritable output) still exit non-zero so go2rtc-run's `set -e`
    trips.
"""

import os
import sys

import yaml

# DEFAULT_FFMPEG_VERSION in bin/frigate-run; go2rtc's `ffmpeg:` source module needs an
# absolute bin under confinement (bare "ffmpeg" is not on PATH here).
DEFAULT_FFMPEG_VERSION = "7.0"

# Loopback-only control API (M5 ruling). Kept as a constant so the force + the
# override-detection compare against one source of truth.
FORCED_API_LISTEN = "127.0.0.1:1984"


def log(msg: str) -> None:
    """Redacted-safe status line to stderr (systemd journal). Never emits config data."""
    sys.stderr.write("go2rtc-config-gen: " + msg + "\n")


def deep_merge(base: dict, over: dict) -> dict:
    """Recursively merge `over` onto `base`; `over` wins per key. Nested mappings merge
    (so streams UNION); non-mapping values are replaced wholesale. Mirrors how upstream
    layers the operator section over its seeded keys."""
    out = dict(base)
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def main() -> int:
    if len(sys.argv) != 5:
        log("ERROR usage: go2rtc-config-gen.py <baseline.in> <config.yml> <SNAP> <output.yaml>")
        return 2

    baseline_path, config_path, snap, output_path = sys.argv[1:5]

    # --- 1. baseline (template) --------------------------------------------------------
    # Missing baseline is an INTERNAL error (packaging bug) -> non-zero so go2rtc-run trips.
    try:
        with open(baseline_path) as f:
            baseline_raw = f.read()
    except OSError as e:
        log("ERROR cannot read baseline %s: %s" % (baseline_path, e.__class__.__name__))
        return 1
    baseline_raw = baseline_raw.replace("__SNAP__", snap)
    try:
        cfg = yaml.safe_load(baseline_raw) or {}
    except yaml.YAMLError as e:
        log("ERROR baseline template is not valid YAML: %s" % e.__class__.__name__)
        return 1
    if not isinstance(cfg, dict):
        log("ERROR baseline template did not parse to a mapping")
        return 1

    # --- 2. operator go2rtc section (deep-merge OVER baseline) --------------------------
    operator_g2r = {}
    if os.path.exists(config_path):
        try:
            with open(config_path) as f:
                full = yaml.safe_load(f.read()) or {}
            section = full.get("go2rtc") if isinstance(full, dict) else None
            if isinstance(section, dict):
                operator_g2r = section
                log("operator go2rtc: section merged from config.yml")
            elif section is not None:
                log("WARNING config.yml go2rtc: is not a mapping; ignored (baseline only)")
            else:
                log("no go2rtc: section in config.yml; using baseline only")
        except yaml.YAMLError:
            # DIVERGENCE: fall back to baseline rather than abort. Never echo the reason
            # detail (could quote credential-bearing lines); frigate reports it loudly.
            log("WARNING config.yml failed to parse; using baseline only (fix config.yml)")
        except OSError as e:
            log("WARNING cannot read config.yml (%s); using baseline only"
                % e.__class__.__name__)
    else:
        log("config.yml absent (first boot / not yet rendered); using baseline only")

    if operator_g2r:
        cfg = deep_merge(cfg, operator_g2r)

    # --- 3. FORCE loopback api.listen (M5) ---------------------------------------------
    api = cfg.get("api")
    if not isinstance(api, dict):
        api = {}
    attempted = api.get("listen")
    if attempted is not None and attempted != FORCED_API_LISTEN:
        # Redacted: the attempted value is not printed.
        log("WARNING operator go2rtc.api.listen override ignored; forcing loopback "
            + FORCED_API_LISTEN + " (control API is loopback-only in this snap)")
    api["listen"] = FORCED_API_LISTEN
    cfg["api"] = api

    # --- 4. upstream defaults where absent ---------------------------------------------
    # CORS origin so the frigate integration / card work (upstream parity; harmless on a
    # loopback listen).
    if cfg["api"].get("origin") is None:
        cfg["api"]["origin"] = "*"

    # Readable logs (upstream sets log.format=text).
    log_cfg = cfg.get("log")
    if not isinstance(log_cfg, dict):
        log_cfg = {}
        cfg["log"] = log_cfg
    if log_cfg.get("format") is None:
        log_cfg["format"] = "text"

    # webrtc STUN candidate default so webrtc can negotiate (upstream: stun:8555, plus the
    # add-on's discovered internal candidate if present — absent in the snap context).
    webrtc = cfg.get("webrtc")
    if not isinstance(webrtc, dict):
        webrtc = {}
        cfg["webrtc"] = webrtc
    if webrtc.get("candidates") is None:
        candidates = []
        internal = os.environ.get("FRIGATE_GO2RTC_WEBRTC_CANDIDATE_INTERNAL")
        if internal:
            candidates.append(internal)
        candidates.append("stun:8555")
        webrtc["candidates"] = candidates

    # ffmpeg bin so go2rtc's `ffmpeg:` source module resolves under confinement.
    ffmpeg = cfg.get("ffmpeg")
    if not isinstance(ffmpeg, dict):
        ffmpeg = {}
        cfg["ffmpeg"] = ffmpeg
    if ffmpeg.get("bin") is None:
        ffmpeg["bin"] = "%s/usr/lib/ffmpeg/%s/bin/ffmpeg" % (snap, DEFAULT_FFMPEG_VERSION)

    # --- 5. write (umask 077; contents NEVER printed) ----------------------------------
    os.umask(0o077)
    try:
        # Write to a temp sibling then rename, so a crash mid-write can't leave go2rtc a
        # truncated config on the next read.
        tmp = output_path + ".tmp"
        with open(tmp, "w") as f:
            yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=True)
        os.replace(tmp, output_path)
    except OSError as e:
        log("ERROR cannot write %s: %s" % (output_path, e.__class__.__name__))
        return 1

    log("wrote %s (%d stream(s), api loopback-sealed)"
        % (output_path, len(cfg.get("streams") or {})))
    return 0


if __name__ == "__main__":
    sys.exit(main())
