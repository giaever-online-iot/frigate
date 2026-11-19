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
(from the factory hook), then the end record (`stop` at the clean end; the helper's class otherwise; `auth_fail`
adds its latch). It writes no `published` record. `published=1` in the output line means ONLY "the first complete
IDR access unit reached the framemd5 ffmpeg"; first_irap_s is the time from the start of the camera session to
it (0.000 when published=0).

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
    from ezviz_source import annexb, gate, ledger, output, paths, signals
    from ezviz_source import constants as C

    S = {"phase": "P0", "lp": None, "t0": None, "login_ok": 0, "published": 0, "first_irap": 0.0, "render": 0.0,
         "ka_sent": 0, "ka_failed": 0, "proc": None, "pts": set()}
    tss = []

    def on_attempt(t, lp):
        S["phase"], S["t0"], S["lp"] = "P1", t, lp

    def on_login_ok():
        with signals.critical():
            with ledger.Ledger(S["lp"]) as L:
                L.append({"t": time.time(), "ev": "login_ok", "dur": None})
            S["phase"], S["login_ok"] = "P2", 1
        try:
            S["proc"] = subprocess.Popen(
                [ffmpeg, "-hide_banner", "-v", "error", "-f", "hevc", "-i", "pipe:0", "-f", "framemd5",
                 str(work / "hashes")], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                stderr=open(work / "ffmpeg.err", "wb"), env=output.child_env(), close_fds=True, bufsize=0)
        except OSError:
            raise _Ended("output_end") from None

    signals.install()
    try:
        adm = gate.admit(name, on_attempt=on_attempt)
    except gate.Refused as r:
        print(f"probe {name}: end={r.cls}", flush=True)
        return r.code
    except signals.Terminating:
        return 0
    cam, ev, code = adm.cam, "session_end", 75
    sess = reasm = None
    if True:  # noqa: SIM108
        try:
            from ezviz_source import camera
            camera.silence_library_logging()
            plan = camera.build_plan(form, count)
            S["render"] = camera.render_seconds(plan)
            sess = camera.CameraSession(cam, plan=plan, timeout=C.SOCKET_TIMEOUT_S, on_login_ok=on_login_ok)
            reasm, aus = annexb.Reassembler(), annexb.AccessUnits()
            deadline, last_ka, t_start = time.monotonic() + minutes * 60, 0.0, time.monotonic()

            def feed(au, idr):
                if not S["published"] and not idr:
                    return
                try:
                    S["proc"].stdin.write(au)
                except (BrokenPipeError, ValueError, OSError):
                    raise _Ended("output_end") from None
                if not S["published"]:
                    S["published"], S["first_irap"] = 1, time.monotonic() - t_start

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
                    if now - last_ka >= 1.0:
                        last_ka = now
                        kes = list(sess._stream.keepalive_events)    # sampled before __exit__ drops them
                        S["ka_sent"] = sum(1 for e in kes if e.sent)
                        S["ka_failed"] = len(kes) - S["ka_sent"]
                        if sess.keepalive_failed():
                            raise _Ended("session_end")
                    if now >= deadline:
                        raise _Ended("stop")
                raise _Ended("session_end")
        except _Ended as e:
            ev, code = e.ev, (0 if e.ev == "stop" else 75)
        except signals.Terminating:
            ev, code = ("net_fail" if S["phase"] == "P1" else "stop"), (75 if S["phase"] == "P1" else 0)
        except Exception as e:                                    # noqa: BLE001 - only its class is used
            sys.stderr.write(f"probe {name}: exception {type(e).__name__}\n")
            cls = "net_fail" if S["phase"] == "P1" else "session_end"
            try:
                cls = camera.classify(e, logged_in=S["phase"] != "P1")
            except Exception:                                     # noqa: BLE001 - the import itself failed
                pass
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
