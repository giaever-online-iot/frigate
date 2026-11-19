"""Item A's long-session probe (W-23 T12, plan P15, controller ruling C18). TEST TOOLING: never part of the snap.

    probe.py <state-dir> <camdir> <name> <minutes> <form> <count> <ffmpeg>

One login to the camera named <name>, one CameraSession on build_plan(<form>, <count>), the access units into
`ffmpeg -v error -f hevc -i pipe:0 -f framemd5 <tmp>/hashes` (hashes only, never an image; the hash dir is deleted),
a clean close (`stop`) after <minutes>. It prints ONE line, never a host, serial or login.

State layout (C18). gate.admit has no state-dir parameter and reads paths.state_dir()/camera_dir() from the
environment, so this script sets, in its own os.environ BEFORE it imports or calls the gate:
    SNAP_COMMON = <state-dir>                 -> paths.state_dir()  = <state-dir>/ezviz/state
    SNAP_DATA   = <tmp>/data                  -> paths.camera_dir() = <tmp>/data/ezviz/cameras, a symlink to <camdir>
                                                 (the smallest mapping that fits any <camdir> name)
so `<state-dir>/ezviz/state/<name>.{ledger,session,latch}` are the helper's files and the D4 budget (3 attempts per
3600 s, 60 s apart, the latch) applies to probe runs across runs. `probe-run.sh --status` reads that same place.

Ledger: the probe writes what the helper writes for a session it ends itself: `attempt` (by the gate), `login_ok`
(from the factory hook), `published` (D22: the first complete IDR access unit reached the framemd5 ffmpeg AND that
ffmpeg is still alive C.PUBLISH_HOLD_S = 5 s later; output.Output's published_due() rule, mirrored here because
Output owns an rtsp-publishing ffmpeg argv and a hevc framemd5 one does not fit it), then the end record. Without
`published` every clean probe stop would be a P2 end (a rung and a latch-row entry) and the third would latch the
camera. Ends follow the helper's SIG_EV: a clean end or SIGTERM/SIGINT in P3 is `stop`, in P2 `start_timeout`, in
P1 `net_fail`; `auth_fail` adds its latch. `published=1` in the output line means the record was written;
first_irap_s is the time from the start of the camera session to the first IDR AU written (0.000 when no IDR AU was written).

rtp_ts_*: per-picture RTP timestamps (packets of one picture share a timestamp), from annexb's own RTP parser.
step = (ts - previous ts) mod 2**32; monotonic = fraction of steps in (0, 2**31); mode = the most common step;
p99_dev = 99th percentile of |step - mode|.
"""
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from collections import Counter
from pathlib import Path

EXIT_USAGE = 64


def _usage():
    sys.stderr.write("probe: usage: probe.py <state-dir> <camdir> <name> <minutes> <form> <count> <ffmpeg>\n")
    os._exit(EXIT_USAGE)


class _Ended(Exception):
    def __init__(self, ev):
        super().__init__(ev)
        self.ev = ev


def ts_stats(tss: list):
    steps = [(b - a) & 0xFFFFFFFF for a, b in zip(tss, tss[1:])]
    if not steps:
        return 0.0, 0, 0
    mono = sum(1 for s in steps if 0 < s < 1 << 31) / len(steps)
    mode = Counter(steps).most_common(1)[0][0]
    devs = sorted(abs(s - mode) for s in steps)
    return mono, mode, devs[max(0, -(-99 * len(devs) // 100) - 1)]


def main(argv: list) -> int:
    if len(argv) != 7:
        _usage()
    state_dir, camdir, name, minutes, form, count, ffmpeg = argv
    try:
        minutes_f, count_i = float(minutes), int(count)
    except ValueError:
        _usage()
    if not re.fullmatch(r"[a-z0-9_]{1,32}", name) or minutes_f <= 0 or form not in ("extend", "repeat"):
        _usage()
    work = Path(tempfile.mkdtemp(prefix="w23-probe-hash"))          # 0700: hashes, ffmpeg stderr, the camdir link
    (work / "data" / "ezviz").mkdir(parents=True)
    (work / "data" / "ezviz" / "cameras").symlink_to(Path(camdir).resolve())
    os.environ["SNAP_COMMON"] = str(Path(state_dir).resolve())      # C18: before any ezviz_source import
    os.environ["SNAP_DATA"] = str(work / "data")
    os.environ["SNAP"] = str(work / "unused")
    try:
        return _run(name, minutes_f, form, count_i, ffmpeg, work)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def _run(name, minutes, form, count, ffmpeg, work) -> int:
    from ezviz_source import annexb, camera, gate, ledger, output, paths, signals
    from ezviz_source import constants as C

    # M1: everything that can be wrong without a camera is checked BEFORE gate.admit, so a bad ffmpeg path or
    # keepalive count costs no attempt (as the helper's R2-N4 check does). No ledger write on these exits.
    if not (os.path.isfile(ffmpeg) and os.access(ffmpeg, os.X_OK)):
        sys.stderr.write(f"probe {name}: config: ffmpeg is not an executable file\n")
        return 78
    try:
        plan = camera.build_plan(form, count)
        render = camera.render_seconds(plan)
    except ValueError:
        _usage()

    S = {"phase": "P0", "lp": None, "t0": None, "login_ok": 0, "published": 0, "first_irap": 0.0, "render": render,
         "ka_sent": 0, "ka_failed": 0, "proc": None, "first_idr": None}
    tss = []
    SIG_EV = {"P1": "net_fail", "P2": "start_timeout", "P3": "stop"}      # the helper's T-END E4, E7, E13

    def on_attempt(t, lp):
        S["phase"], S["t0"], S["lp"] = "P1", t, lp

    def on_login_ok():
        with signals.critical():
            with ledger.Ledger(S["lp"]) as L:
                L.append({"t": time.time(), "ev": "login_ok", "dur": None})
            S["phase"], S["login_ok"] = "P2", 1
        errf = open(work / "ffmpeg.err", "wb")
        try:
            S["proc"] = subprocess.Popen(
                [ffmpeg, "-hide_banner", "-v", "error", "-f", "hevc", "-i", "pipe:0", "-f", "framemd5",
                 str(work / "hashes")], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=errf,
                env=output.child_env(), close_fds=True, bufsize=0)
        except OSError:
            raise _Ended("output_end") from None
        finally:
            errf.close()

    def published_due(now):
        return (S["phase"] == "P2" and S["first_idr"] is not None and now - S["first_idr"] >= C.PUBLISH_HOLD_S
                and S["proc"].poll() is None)

    signals.install()
    signal.signal(signal.SIGINT, signal.getsignal(signal.SIGTERM))    # Ctrl-C in a direct run ends like a SIGTERM
    try:
        adm = gate.admit(name, on_attempt=on_attempt)
    except gate.Refused as r:
        print(f"probe {name}: end={r.cls}", flush=True)
        return r.code
    except signals.Terminating:
        return 0
    cam, ev, code = adm.cam, "session_end", 75
    sess = reasm = None
    try:
        sess = camera.CameraSession(cam, plan=plan, timeout=C.SOCKET_TIMEOUT_S, on_login_ok=on_login_ok)
        reasm, aus = annexb.Reassembler(), annexb.AccessUnits()
        deadline, last_ka, t_start = time.monotonic() + minutes * 60, 0.0, time.monotonic()

        def feed(au, idr):
            if S["first_idr"] is None and not idr:
                return
            try:
                S["proc"].stdin.write(au)
            except (BrokenPipeError, ValueError, OSError):
                raise _Ended("output_end") from None
            if S["first_idr"] is None:
                S["first_idr"] = time.monotonic()
                S["first_irap"] = S["first_idr"] - t_start

        with sess:
            for body in sess.packets():
                got = annexb._frame_of(body)                       # the reassembler's own RTP parser
                pkt = annexb._rtp_of(got[0]) if got else None
                if pkt is not None and (not tss or tss[-1] != pkt.ts):
                    tss.append(pkt.ts)
                for nal in reasm.push(body):
                    for au, idr in aus.push(nal):
                        feed(au, idr)
                now = time.monotonic()
                if published_due(now):
                    with signals.critical():
                        with ledger.Ledger(S["lp"]) as L:
                            L.append({"t": time.time(), "ev": "published", "dur": None})
                        S["phase"], S["published"] = "P3", 1
                if now - last_ka >= 1.0:
                    last_ka = now
                    kes = list(sess._stream.keepalive_events)    # sampled before __exit__ drops them
                    S["ka_sent"] = sum(1 for e in kes if e.sent)
                    S["ka_failed"] = len(kes) - S["ka_sent"]
                    if sess.keepalive_failed():
                        raise _Ended("session_end")
                if now >= deadline:
                    raise _Ended(SIG_EV[S["phase"]] if S["phase"] != "P1" else "net_fail")
            raise _Ended("session_end")
    except _Ended as e:
        ev, code = e.ev, (0 if e.ev == "stop" else 75)
    except signals.Terminating:
        ev = SIG_EV[S["phase"]]
        code = 0 if ev == "stop" else 75
    except Exception as e:                                    # noqa: BLE001 - only its class is used
        sys.stderr.write(f"probe {name}: exception {type(e).__name__}\n")
        cls = camera.classify(e, logged_in=S["phase"] != "P1")
        ev, code = cls, (C.EXIT_AUTH if cls == "auth_fail" else 75)
    try:
        if sess is not None:
            sess.__exit__(None, None, None)
        p = S["proc"]
        if p is not None:
            try:
                p.stdin.close()
            except OSError:
                pass
            try:
                p.wait(2.0 if signals.sigterm_seen() else 30.0)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
    except signals.Terminating:
        pass
    with signals.critical():
        signals.mark_ended()
        t = time.time()
        with ledger.Ledger(S["lp"]) as L:
            L.append({"t": t, "ev": ev, "dur": round(t - S["t0"], 3)})
            if ev == "auth_fail":
                gate.write_latch(paths.state_dir(), name)
                L.append({"t": t, "ev": "latch", "dur": None})
    hashes = work / "hashes"
    frames = 0
    if hashes.exists():
        frames = sum(1 for ln in hashes.read_text(errors="replace").splitlines() if ln and not ln.startswith("#"))
    errfile = work / "ffmpeg.err"
    derr = len([ln for ln in errfile.read_text(errors="replace").splitlines() if ln.strip()]) if errfile.exists() else 0
    mono, mode, dev = ts_stats(tss)
    t_end = time.time()
    print(f"probe {name}: end={ev} login_ok={S['login_ok']} published={S['published']} "
          f"session_s={t_end - S['t0']:.3f} first_irap_s={S['first_irap']:.3f} render_s={S['render']:.3f} "
          f"keepalive_sent={S['ka_sent']} keepalive_failed={S['ka_failed']} frames={frames} decode_errors={derr} "
          f"rtp_ts_monotonic={mono:.4f} rtp_ts_step_mode={mode} rtp_ts_step_p99_dev={dev} "
          f"pts_seen={sorted(reasm.pts_seen()) if reasm else []}", flush=True)
    return code


if __name__ == "__main__":
    rc = main(sys.argv[1:])
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(rc)
