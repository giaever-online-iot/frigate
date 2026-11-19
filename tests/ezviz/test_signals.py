import _path
import os
import signal
import subprocess
import sys
import textwrap
import threading
import time
import unittest
from unittest import mock

PRE = "import os, signal, socket, sys, time\nfrom ezviz_source import signals\nsignals.install()\n"


def run(body, *, kills=(), env_extra=None, timeout=15):
    """Run PRE+body in a child; kills = [(delay_s, signum), ...] sent from here. Returns (rc, out, secs)."""
    p = subprocess.Popen([sys.executable, "-c", PRE + textwrap.dedent(body)], stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, env=_path.child_env(**(env_extra or {})), bufsize=0)
    try:
        got = b""
        while len(got) < 6:                              # raw reads: communicate(timeout) bypasses any buffer
            chunk = os.read(p.stdout.fileno(), 6 - len(got))
            if not chunk:                                # EOF: the child died before "ready"
                break
            got += chunk
        t0 = time.monotonic()                            # after "ready": the kill delays count from here
        if got != b"ready\n":
            raise AssertionError(f"child did not print ready: {got!r}")
        for delay, sig in kills:
            time.sleep(max(0.0, t0 + delay - time.monotonic()))
            try:
                p.send_signal(sig)
            except ProcessLookupError:
                pass
        out, _ = p.communicate(timeout=timeout)
    except BaseException:                                # a failing test leaves no child behind
        p.kill()
        p.communicate()
        raise
    return p.returncode, out.decode(), time.monotonic() - t0


class TestSignals(unittest.TestCase):
    def test_first_sigterm_raises_terminating_in_blocking_recv(self):        # J1
        rc, out, secs = run("""
            a, b = socket.socketpair(); a.settimeout(30); print("ready", flush=True)
            try:
                a.recv(1)
            except signals.Terminating:
                print("terminating", flush=True); os._exit(0)
        """, kills=[(0.2, signal.SIGTERM)])
        self.assertEqual((rc, out.strip()), (0, "terminating"))
        self.assertLess(secs, 1.5)

    def test_second_sigterm_does_not_raise(self):                              # L1
        rc, out, _ = run("""
            print("ready", flush=True)
            try:
                time.sleep(10)
            except signals.Terminating:
                try:
                    time.sleep(1.0)
                    print("no second raise", flush=True)
                except signals.Terminating:
                    print("raised twice", flush=True)
                os._exit(0)
        """, kills=[(0.2, signal.SIGTERM), (0.25, signal.SIGTERM)])
        self.assertEqual((rc, out.strip()), (0, "no second raise"))

    def test_second_sigterm_does_not_rearm(self):                              # L1, SF4
        rc, out, secs = run("""
            print("ready", flush=True)
            try:
                time.sleep(10)
            except signals.Terminating:
                time.sleep(30)
        """, kills=[(0.0, signal.SIGTERM), (2.0, signal.SIGTERM)], timeout=20)
        self.assertEqual(rc, -signal.SIGALRM)
        self.assertLess(abs(secs - 4.0), 0.5)

    def test_sigterm_inside_critical_is_pending_until_exit(self):             # K1
        rc, out, _ = run("""
            print("ready", flush=True)
            try:
                with signals.critical():
                    for i in range(3):
                        time.sleep(0.3); print("line", i, flush=True)
                print("after", flush=True)
            except signals.Terminating:
                print("terminating", flush=True); os._exit(0)
        """, kills=[(0.1, signal.SIGTERM)])
        self.assertEqual(out.split("\n")[:4], ["line 0", "line 1", "line 2", "terminating"])

    def test_mark_ended_suppresses_the_raise(self):                            # SF3
        rc, out, _ = run("""
            print("ready", flush=True)
            with signals.critical():
                signals.mark_ended(); time.sleep(0.5)
            print("ended cleanly", flush=True); os._exit(75)
        """, kills=[(0.1, signal.SIGTERM)])
        self.assertEqual((rc, out.strip()), (75, "ended cleanly"))

    def test_alarm_kills_a_stalled_process_with_sigalrm(self):                # H5a
        rc, _, secs = run("""
            print("ready", flush=True)
            try:
                time.sleep(10)
            except signals.Terminating:
                signals.hook("stall_close")
        """, kills=[(0.2, signal.SIGTERM)], env_extra={"EZVIZ_TEST_HOOKS": "stall_close"}, timeout=20)
        self.assertEqual(rc, -signal.SIGALRM)
        self.assertLess(secs, 5.0)

    def test_alarm_is_default_action_not_python_handler(self):
        rc, out, _ = run("""
            print("ready", flush=True)
            try:
                time.sleep(10)
            except signals.Terminating:
                print(signal.getsignal(signal.SIGALRM) == signal.SIG_DFL, flush=True); os._exit(0)
        """, kills=[(0.2, signal.SIGTERM)])
        self.assertEqual(out.strip(), "True")

    def test_mark_ended_outside_critical_then_sigterm_does_not_raise(self):   # SF3 (W-23 final wave)
        rc, out, _ = run("""
            signals.mark_ended(); print("ready", flush=True)
            try:
                time.sleep(0.6)
                print("no raise", flush=True); os._exit(75)
            except signals.Terminating:
                print("raised", flush=True); os._exit(0)
        """, kills=[(0.1, signal.SIGTERM)])
        self.assertEqual((rc, out.strip()), (75, "no raise"))

    def test_nested_critical_holds_sigterm_until_the_outer_exit(self):       # K1 (W-23 final wave)
        rc, out, _ = run("""
            print("ready", flush=True)
            try:
                with signals.critical():
                    with signals.critical():
                        time.sleep(0.3); print("inner done", flush=True)
                    print("between", flush=True)
                    time.sleep(0.3); print("outer done", flush=True)
                print("after", flush=True)
            except signals.Terminating:
                print("terminating", flush=True)
                try:
                    with signals.critical():
                        pass
                    time.sleep(0.3); print("once", flush=True)
                except signals.Terminating:
                    print("twice", flush=True)
                os._exit(0)
        """, kills=[(0.1, signal.SIGTERM)])
        self.assertEqual((rc, out.split()), (0, ["inner", "done", "between", "outer", "done", "terminating", "once"]))

    def test_harness_fails_fast_when_the_child_dies_before_ready(self):     # harness robustness (W-23 final wave)
        box = []

        def go():
            try:
                run("os._exit(3)")
                box.append("returned")
            except AssertionError as e:
                box.append(str(e))
        t = threading.Thread(target=go, daemon=True)
        t.start()
        t.join(5.0)
        self.assertFalse(t.is_alive(), "run() spins on EOF before ready")
        self.assertEqual(box, ["child did not print ready: b''"])

    def test_harness_kills_the_child_on_timeout(self):                       # harness robustness (W-23 final wave)
        procs, real = [], subprocess.Popen

        def spy(*a, **k):
            procs.append(real(*a, **k))
            return procs[-1]
        try:
            with mock.patch.object(subprocess, "Popen", side_effect=spy):
                with self.assertRaises(subprocess.TimeoutExpired):
                    run("""
                        print("ready", flush=True); time.sleep(30)
                    """, timeout=0.5)
            self.assertEqual(len(procs), 1)
            self.assertIsNotNone(procs[0].poll(), "child still running after TimeoutExpired")
        finally:
            for p in procs:                              # this test's own cleanup, whatever run() did
                if p.poll() is None:
                    p.kill()
                    p.wait()

    def test_hooks_inactive_without_env(self):
        rc, out, secs = run("""
            print("ready", flush=True); signals.hook("stall_close"); print("returned", flush=True)
        """)
        self.assertEqual((rc, out.strip()), (0, "returned"))
        self.assertLess(secs, 2)


if __name__ == "__main__":
    unittest.main()
