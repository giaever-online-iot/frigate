"""Item A's long-session probe (W-23 T12, plan P15, controller ruling C18). TEST TOOLING: never part of the snap.

    probe.py [--diag] [--helper] <state-dir> <camdir> <name> <minutes> <form> <count> <ffmpeg>

--helper (round 9): the PRODUCTION path instead of the probe's own reader. The real helper (`python -I -B -m
ezviz_source.main <name> rtsp://127.0.0.1:1/<name>`, as go2rtc's exec runs it; its own gate and ledger, in <state-dir>)
with $SNAP a private tree whose usr/lib/ffmpeg/8.0/bin/ffmpeg is a consumer: `<ffmpeg> -f mpegts -i pipe:0` into
framemd5 (packets, 90 kHz PTS, and decoded frames), so it reads exactly what the helper's ffmpeg child would. After
<minutes> the helper gets SIGTERM by PID (E13); a SIGTERM to the probe is passed on. <form> and <count> are not used
(the helper's constants apply). One line: `probe-helper <name>: rc= records= published= published_s= frames=
decode_errors= pts_step_mode_ms= pts_p99_dev_ms= child_f= stderr_lines= stderr_words=` (class words only).

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

rtp_ts_*: per-picture RTP timestamps (packets of one picture share a timestamp), from annexb's own RTP parser, of the
VIDEO only: packets whose payload type the reassembler routes as HEVC right after their push (GA run 2: the audio-like
PT 104 and the descriptor PT 112 have their own timestamp bases and made these numbers meaningless).
step = (ts - previous ts) mod 2**32; monotonic = fraction of steps in (0, 2**31); mode = the most common step;
p99_dev = 99th percentile of |step - mode|.

--diag (GA A1 diagnosis; counters only): the same ONE line, followed by ` diag=` and compact JSON (no spaces):
  pkts      packet bodies the library handed over;          per_min  bodies per minute, the first 5 minutes only
  pt        RTP-parsed bodies per payload type;              drop     Reassembler.drop counts (annexb: frame, rtp, param,
  route_pt  route drops per payload type                              route, evidence, direct, short, plausible, fu_gap,
  rtp_rej   "<header size>:<lead byte>" of frames _rtp_of             fu_cap; fu_part = an FU fragment held, held = a
                                                                      PT-96 body awaiting the promotion: no loss yet)
            refused (legacy, non-RTP IDMX records);          multi    bodies with more than one IDMX sentinel (aggregates)
  desc      the 0x45 map, payload type -> stream type;       nal      NAL types out of the reassembler
  au        access units: n, idr, vcl = first VCL NAL type per AU
  first     the first 20 bodies: [length, header size, payload type, TLV ids in the RTP extension, first 2 payload
            bytes as hex] (None where that stage was not reached)
No payload beyond 2 bytes per packet for 20 packets, no video, nothing that names a camera.
"""
import importlib.util
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from collections import Counter
from pathlib import Path

EXIT_USAGE = 64


def _own_checkout(name: str) -> None:
    """Fix wave 1, S4: the ezviz_source this probe imports must be its own checkout's (spike/ezviz next to this
    tests/ directory), not whichever checkout a shared venv's .pth or a PYTHONPATH names. find_spec locates the
    package without running any of its code. Checked before the gate and any camera contact; the line carries no path."""
    own = Path(__file__).resolve().parents[2] / "spike" / "ezviz" / "ezviz_source"
    try:
        spec = importlib.util.find_spec("ezviz_source")
    except (ImportError, ValueError):
        spec = None
    origin = spec.origin if spec is not None else None
    if not origin or Path(origin).resolve().parent != own:
        sys.stderr.write(f"probe {name}: wrong_checkout\n")
        sys.stderr.flush()
        os._exit(2)


def child_import_error(python: str) -> str:
    """S3 for the --helper child: a `python -I` child ignores PYTHONPATH and imports ezviz_source through the venv's
    .pth, which can name another checkout; this checks, without the camera, that `python -I` imports THIS checkout's
    package (as _own_checkout requires of the probe). "" when it does, else a `wrong_checkout` text (no path)."""
    own = Path(__file__).resolve().parents[2] / "spike" / "ezviz" / "ezviz_source"
    try:
        out = subprocess.run([python, "-I", "-B", "-c", "import ezviz_source; print(ezviz_source.__file__)"],
                             capture_output=True, text=True, timeout=60).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        out = ""
    return "" if out and Path(out).resolve().parent == own else "wrong_checkout"


def _usage():
    sys.stderr.write("probe: usage: probe.py [--diag] [--helper] <state-dir> <camdir> <name> <minutes> <form> <count> "
                     "<ffmpeg>\n")
    os._exit(EXIT_USAGE)


class _Ended(Exception):
    def __init__(self, ev):
        super().__init__(ev)
        self.ev = ev


class Diag:
    """The --diag counters. packet() is called once per body with the seconds since the session start, the
    Reassembler (after its push) and the NALs that push returned; result() gives the JSON object."""

    def __init__(self, annexb):
        self.ax = annexb
        self.pkts, self.multi = 0, 0
        self.per_min = [0] * 5
        self.pt, self.drop, self.route_pt, self.rtp_rej, self.nal = Counter(), Counter(), Counter(), Counter(), Counter()
        self.first = []
        self.aus = annexb.AccessUnits()
        self.au_n, self.au_idr, self.au_vcl = 0, 0, Counter()

    @staticmethod
    def _tlv_ids(ext: bytes) -> list:
        ids, o = [], 0
        while o + 2 <= len(ext):
            end = o + ext[o + 1] + 2
            if end > len(ext):
                break
            ids.append(ext[o])
            o = end
        return ids

    def packet(self, t: float, body: bytes, reasm, nals: list) -> None:
        ax = self.ax
        self.pkts += 1
        if 0 <= t < 300:
            self.per_min[int(t // 60)] += 1
        if body.count(ax.SENTINEL) > 1:
            self.multi += 1
        got = ax._frame_of(body)
        hs = pt = None
        tlvs, b2 = [], ""
        if got is not None:
            frame, hs = got
            pkt = ax._rtp_of(frame)
            if pkt is None:
                self.rtp_rej[f"{hs}:{frame[0]:02x}"] += 1
                b2 = frame[hs:hs + 2].hex()
            else:
                pt, tlvs, b2 = pkt.pt, self._tlv_ids(pkt.ext), pkt.payload[:2].hex()
                self.pt[str(pt)] += 1
        if reasm.drop is not None:
            self.drop[reasm.drop] += 1
            if reasm.drop == "route" and pt is not None:
                self.route_pt[str(pt)] += 1
        if len(self.first) < 20:
            self.first.append([len(body), hs, pt, tlvs, b2])
        for nal in nals:
            self.nal[str(ax._nal_type(nal[4:]))] += 1
            for au, idr in self.aus.push(nal):
                self._au(au, idr)

    def _au(self, au: bytes, idr: bool) -> None:
        self.au_n += 1
        self.au_idr += idr
        for n in au.split(self.ax.START):
            if n and self.ax._nal_type(n) < 32:
                self.au_vcl[str(self.ax._nal_type(n))] += 1
                break

    def result(self, reasm) -> dict:
        for au, idr in self.aus.flush():
            self._au(au, idr)
        last = max((i for i, v in enumerate(self.per_min) if v), default=-1)
        return {"pkts": self.pkts, "per_min": self.per_min[:last + 1], "pt": dict(self.pt), "drop": dict(self.drop),
                "route_pt": dict(self.route_pt), "rtp_rej": dict(self.rtp_rej), "multi": self.multi,
                "desc": {str(k): v for k, v in sorted(reasm.descriptors().items())} if reasm else {},
                "nal": dict(self.nal), "au": {"n": self.au_n, "idr": self.au_idr, "vcl": dict(self.au_vcl)},
                "first": self.first}


def ts_stats(tss: list):
    steps = [(b - a) & 0xFFFFFFFF for a, b in zip(tss, tss[1:])]
    if not steps:
        return 0.0, 0, 0
    mono = sum(1 for s in steps if 0 < s < 1 << 31) / len(steps)
    mode = Counter(steps).most_common(1)[0][0]
    devs = sorted(abs(s - mode) for s in steps)
    return mono, mode, devs[max(0, -(-99 * len(devs) // 100) - 1)]


def main(argv: list) -> int:
    flags = []
    while argv and argv[0] in ("--diag", "--helper") and argv[0] not in flags:
        flags.append(argv[0])
        argv = argv[1:]
    diag, helper = "--diag" in flags, "--helper" in flags
    if len(argv) != 7:
        _usage()
    state_dir, camdir, name, minutes, form, count, ffmpeg = argv
    try:
        minutes_f, count_i = float(minutes), int(count)
    except ValueError:
        _usage()
    if not re.fullmatch(r"[a-z0-9_]{1,32}", name) or minutes_f <= 0 or form not in ("extend", "repeat"):
        _usage()
    _own_checkout(name)                                              # S4: before the gate, the ledger, any contact
    work = Path(tempfile.mkdtemp(prefix="w23-probe-hash"))          # 0700: hashes, ffmpeg stderr, the camdir link
    (work / "data" / "ezviz").mkdir(parents=True)
    (work / "data" / "ezviz" / "cameras").symlink_to(Path(camdir).resolve())
    os.environ["SNAP_COMMON"] = str(Path(state_dir).resolve())      # C18: before any ezviz_source import
    os.environ["SNAP_DATA"] = str(work / "data")
    os.environ["SNAP"] = str(work / "unused")
    try:
        if helper:
            return _run_helper(name, minutes_f, ffmpeg, work)
        return _run(name, minutes_f, form, count_i, ffmpeg, work, diag)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def _run_helper(name, minutes, ffmpeg, work) -> int:
    from ezviz_source import ledger, paths
    if not (os.path.isfile(ffmpeg) and os.access(ffmpeg, os.X_OK)):
        sys.stderr.write(f"probe {name}: config: ffmpeg is not an executable file\n")
        return 78
    py = sys.executable
    if child_import_error(py):                                      # before the gate, the ledger, any contact
        sys.stderr.write(f"probe {name}: wrong_checkout\n")
        return 2
    q = shlex.quote
    bindir = work / "snap" / "usr" / "lib" / "ffmpeg" / "8.0" / "bin"
    bindir.mkdir(parents=True)
    (bindir / "ffmpeg").write_text(                                # the helper's child: record -f, then consume
        f"#!/bin/sh\nprintf '%s\\n' \"$@\" > {q(str(work / 'child.argv'))}\n"
        f"exec {q(ffmpeg)} -hide_banner -v error -f mpegts -i pipe:0 -map 0:v -c copy -f framemd5 "
        f"{q(str(work / 'pk'))} -map 0:v -f framemd5 {q(str(work / 'fr'))} 2> {q(str(work / 'ff.err'))}\n")
    (bindir / "ffmpeg").chmod(0o700)
    os.environ["SNAP"] = str(work / "snap")
    lp = paths.state_dir() / f"{name}.ledger"
    read = (lambda: ledger.parse(lp.read_bytes()) if lp.exists() else [])
    base = len(read())
    with open(work / "helper.err", "wb") as err:
        p = subprocess.Popen([py, "-I", "-B", "-m", "ezviz_source.main", name, f"rtsp://127.0.0.1:1/{name}"],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=err, close_fds=True)
    for sig in (signal.SIGTERM, signal.SIGINT):                     # a stop of the probe stops the helper (E13)
        signal.signal(sig, lambda *_: os.kill(p.pid, signal.SIGTERM))
    try:
        rc = p.wait(minutes * 60)                                   # a refusal or a session end returns early
    except subprocess.TimeoutExpired:
        os.kill(p.pid, signal.SIGTERM)                              # by PID only
        try:
            rc = p.wait(30)
        except subprocess.TimeoutExpired:
            p.kill()
            rc = p.wait()
    recs = read()[base:]
    ev = [r["ev"] for r in recs]
    t = {r["ev"]: r["t"] for r in recs}
    pub_s = f"{t['published'] - t['attempt']:.3f}" if "published" in t and "attempt" in t else "-"
    rows = lambda f: [ln for ln in f.read_text(errors="replace").splitlines() if ln and not ln.startswith("#")] \
        if f.exists() else []
    tb = next((ln.split(":", 1)[1].strip() for ln in (work / "pk").read_text().splitlines()
               if ln.startswith("#tb 0:")), "1/90000") if (work / "pk").exists() else "1/90000"
    ms = 1000 * int(tb.split("/")[0]) / int(tb.split("/")[1])
    pts = [int(r.split(",")[2]) for r in rows(work / "pk")]
    steps = [(b - a) * ms for a, b in zip(pts, pts[1:])]
    mode = Counter(round(x, 3) for x in steps).most_common(1)[0][0] if steps else 0.0
    devs = sorted(abs(x - 40.0) for x in steps)
    p99 = devs[max(0, -(-99 * len(devs) // 100) - 1)] if devs else 0.0
    argv = (work / "child.argv").read_text().splitlines() if (work / "child.argv").exists() else []
    child_f = argv[argv.index("-i") - 1] if "-i" in argv and argv.index("-i") >= 1 else "-"
    lines = (work / "helper.err").read_text(errors="replace").splitlines()
    words = [m.group(1) if (m := re.match(rf"ezviz-source {name}: ([a-z_]+)", ln)) else "other" for ln in lines]
    derr = len([ln for ln in rows(work / "ff.err")])
    print(f"probe-helper {name}: rc={rc} records={','.join(ev)} published={int('published' in ev)} published_s={pub_s} "
          f"frames={len(rows(work / 'fr'))} decode_errors={derr} pts_step_mode_ms={mode:.3f} pts_p99_dev_ms={p99:.3f} "
          f"child_f={child_f if re.fullmatch(r'[a-z0-9]+', child_f) else '-'} stderr_lines={len(lines)} "
          f"stderr_words={','.join(words)}", flush=True)
    return 0 if rc == 0 else 75


def _run(name, minutes, form, count, ffmpeg, work, diag=False) -> int:
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
    dg = Diag(annexb) if diag else None
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
                nals = reasm.push(body)
                # video only: the PT the reassembler routes as HEVC after this push (the promoted PT 96 included)
                if pkt is not None and reasm._is_hevc_route(pkt.pt) and (not tss or tss[-1] != pkt.ts):
                    tss.append(pkt.ts)
                now = time.monotonic()
                if dg is not None:
                    dg.packet(now - t_start, body, reasm, nals)
                for nal in nals:
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
          f"pts_seen={sorted(reasm.pts_seen()) if reasm else []}"
          + (" diag=" + json.dumps(dg.result(reasm), separators=(",", ":")) if dg is not None else ""), flush=True)
    return code


if __name__ == "__main__":
    rc = main(sys.argv[1:])
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(rc)
