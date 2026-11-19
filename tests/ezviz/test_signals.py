import _path
import os
import signal
import subprocess
import sys
import textwrap
import time
import unittest

PRE = "import os, signal, socket, sys, time\nfrom ezviz_source import signals\nsignals.install()\n"


def run(body, *, kills=(), env_extra=None, timeout=15):
    """Run PRE+body in a child; kills = [(delay_s, signum), ...] sent from here. Returns (rc, out, secs)."""
    p = subprocess.Popen([sys.executable, "-c", PRE + textwrap.dedent(body)], stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, env=_path.child_env(**(env_extra or {})), bufsize=0)
    t0 = time.monotonic()
    got = b""
    while len(got) < 6:                                  # raw reads: communicate(timeout) bypasses any buffer
        got += os.read(p.stdout.fileno(), 6 - len(got))
    assert got == b"ready\n", got
    for delay, sig in kills:
        time.sleep(max(0.0, t0 + delay - time.monotonic()))
        try:
            p.send_signal(sig)
        except ProcessLookupError:
            pass
    out, _ = p.communicate(timeout=timeout)
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

    def test_hooks_inactive_without_env(self):
        rc, out, secs = run("""
            print("ready", flush=True); signals.hook("stall_close"); print("returned", flush=True)
        """)
        self.assertEqual((rc, out.strip()), (0, "returned"))
        self.assertLess(secs, 2)


if __name__ == "__main__":
    unittest.main()
