"""ezviz-source <name> <rtsp output>: the go2rtc exec helper (spec §4, T-END in §4.3).

Phases: P0 until the "attempt" record, P1 until "login_ok", P2 until "published", P3 after it. The phase is
switched INSIDE the critical section that wrote its record (SF2), so a SIGTERM held pending by that section
is classed by the new phase. Exactly one end record is written per session, by end(); after mark_ended()
nothing can raise (SF3), and the process leaves through os._exit (D17).
"""
import os
import re
import signal
import sys
import time

from . import annexb, gate, ledger, output, paths, signals
from . import constants as C

SIG_EV = {"P1": "net_fail", "P2": "start_timeout", "P3": "stop"}      # T-END E4, E7, E13


class _SessionEnd(Exception):
    pass


class Helper:
    def __init__(self, name: str, url: str):
        self.name, self.url = name, url
        self.phase, self.attempt_t, self.lp = "P0", None, None
        self.cam, self.sess, self.out = None, None, None

    # --- records -----------------------------------------------------------------------------------------
    def _append(self, ev: str, *, dur=None) -> None:
        with ledger.Ledger(self.lp) as L:
            L.append({"t": time.time(), "ev": ev, "dur": dur})

    def on_attempt(self, t: float, lp) -> None:          # called by gate.admit inside its critical section
        self.phase, self.attempt_t, self.lp = "P1", t, lp

    def on_login_ok(self) -> None:                        # P2: the factory's 2nd call (plan P2)
        with signals.critical():
            self._append("login_ok")
            self.phase = "P2"                             # SF2: before the section can raise
        gate.say(self.name, "login_ok")
        try:
            self.out = output.Output(paths.ffmpeg(), self.url)   # ffmpeg only after login_ok (nit)
        except OSError:
            raise output.FfmpegExited()                   # ruling: a spawn failure is output_end, not session_end

    def _published(self) -> None:
        with signals.critical():
            self._append("published")
            self.phase = "P3"                             # SF2
        gate.say(self.name, "published")

    # --- the session -------------------------------------------------------------------------------------
    def run(self):
        """Returns (ev, code) for a non-signal end; a SIGTERM raises Terminating out of here."""
        camera = None
        try:
            from . import camera                          # pyezvizapi is imported only now (N5)
            camera.silence_library_logging()
            plan = camera.build_plan(C.KEEPALIVE_FORM, C.KEEPALIVE_COUNT)
            self.sess = camera.CameraSession(self.cam, plan=plan, timeout=C.SOCKET_TIMEOUT_S,
                                             on_login_ok=self.on_login_ok)
            reasm, aus, last_ka = annexb.Reassembler(), annexb.AccessUnits(), 0.0
            with self.sess:
                for body in self.sess.packets():
                    for nal in reasm.push(body):
                        for au, idr in aus.push(nal):        # C16: (au_bytes, is_idr)
                            self.out.write_au(au, idr)
                    if self.phase == "P2" and self.out.published_due():
                        self._published()
                    now = time.monotonic()
                    if now - last_ka >= 1.0:                 # N5: once a second, not per packet
                        last_ka = now
                        if self.sess.keepalive_failed():     # a method; sampled before __exit__
                            raise _SessionEnd()
            raise _SessionEnd()                              # the packet iterator ended
        except output.FfmpegExited:
            signals.wait_for_sigterm(C.FFMPEG_EXIT_GRACE_S)  # a SIGTERM in this second decides (H5b)
            return "output_end", C.EXIT_TEMP
        except _SessionEnd:
            return "session_end", C.EXIT_TEMP
        except Exception as e:                               # noqa: BLE001 - classified; only its class name is printed
            sys.stderr.write(f"ezviz-source {self.name}: exception {type(e).__name__}\n")
            if camera is None:                               # the import itself failed: no camera contact
                return ("net_fail" if self.phase == "P1" else "protocol_fail"), C.EXIT_TEMP
            cls = camera.classify(e, logged_in=self.phase != "P1")       # P3: E2/E3 before, E8/E10/E14/E16 after
            return cls, (C.EXIT_AUTH if cls == "auth_fail" else C.EXIT_TEMP)

    # --- the end -----------------------------------------------------------------------------------------
    def _close(self) -> None:
        """The camera session only (R2-N3): ffmpeg is closed by end(), after the record (D17 order)."""
        signals.hook("pause_close")                          # L1 test: widen the window for a 2nd SIGTERM
        signals.hook("stall_close")                          # H5a test: a close that never returns
        try:
            if self.sess is not None:
                self.sess.__exit__(None, None, None)         # idempotent; closes the camera sockets first (D17)
        except Exception:                                    # noqa: BLE001
            pass

    def end(self, ev: str, code: int):
        """Write the one end record (T-END), then leave. Never returns; nothing raises after mark_ended()."""
        try:
            while True:
                try:
                    signals.hook("pause_end")                # R2-N9 test: a SIGTERM before the section
                    with signals.critical():
                        signals.mark_ended()
                        t = time.time()
                        with ledger.Ledger(self.lp) as L:
                            L.append({"t": t, "ev": ev, "dur": round(t - self.attempt_t, 3)})
                            if ev == "auth_fail":            # E2: the latch, in the same section (P9)
                                gate.write_latch(paths.state_dir(), self.name)
                                L.append({"t": t, "ev": "latch", "dur": None})
                    break
                except signals.Terminating:                  # R2-N9: raised at most once (L1), before the section
                    ev, code = SIG_EV[self.phase], C.EXIT_STOP
            gate.say(self.name, ev)
            if self.out is not None:                         # R2-N3: ffmpeg after the record, inside the alarm budget
                rem = signal.getitimer(signal.ITIMER_REAL)[0]    # alarm(4) and ITIMER_REAL share the timer
                wait = 2.0 if rem == 0 else min(2.0, max(0.0, rem - 0.5))
                try:
                    self.out.close(wait=wait)
                except Exception:                            # noqa: BLE001
                    pass
        finally:
            os._exit(code)                                   # ffmpeg also dies by pdeathsig here

    def finish(self, ev: str, code: int):
        try:
            try:
                self._close()
            except signals.Terminating:                      # the first SIGTERM arrived during the close
                ev, code = SIG_EV[self.phase], C.EXIT_STOP
            self.end(ev, code)
        except signals.Terminating:                          # ...or between the close and end()'s section
            self.end(SIG_EV[self.phase], C.EXIT_STOP)


def main(argv: list) -> None:
    if len(argv) != 2 or not re.fullmatch(C.NAME_RE, argv[0]) or not argv[1].startswith("rtsp://127.0.0.1:"):
        sys.stderr.write("ezviz-source: usage: ezviz-source <name> <rtsp://127.0.0.1:...>\n")
        os._exit(C.EXIT_USAGE)
    if "SNAP" not in os.environ or not os.access(paths.ffmpeg(), os.X_OK):   # R2-N4: no lock, no ledger, no contact
        gate.say(argv[0], "config")
        os._exit(C.EXIT_CONFIG)
    h = Helper(*argv)
    signals.install()
    try:
        adm = gate.admit(h.name, on_attempt=h.on_attempt)
        h.cam = adm.cam
        gate.say(h.name, "attempt", attempt=adm.attempts_in_window)
        ev, code = h.run()
    except gate.Refused as r:
        gate.say(h.name, r.cls, next_in=r.next_in)
        os._exit(r.code)
    except signals.Terminating:
        if h.phase == "P0":
            os._exit(C.EXIT_STOP)                            # E1: nothing written
        ev, code = SIG_EV[h.phase], C.EXIT_STOP
    h.finish(ev, code)


if __name__ == "__main__":
    main(sys.argv[1:])
