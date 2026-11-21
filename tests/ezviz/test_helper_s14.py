"""S14: SIGTERM in each phase writes the T-END record, the exit is fast, the deadline holds (W-23 T11).

Spec §9.2 S14, T-END E1/E4/E7/E13 (§4.3), D17 (J1, J3, H5a, H5b, K1, L1), plan SF2/SF3; carry-overs R2-N3, R2-N9.
Signals go out on ledger events (or the session lock, the only event in P0), never after a bare sleep.
"""
import _path  # noqa: F401
import signal
import sys
import time
import unittest
from pathlib import Path

import fixtures
from fixtures import Helper, HelperCase, evs, rec
from ezviz_source import policy

H = 3600.0


def two_p2_ends(now: float) -> list:
    """A latch row of 2 (E7 twice), long enough ago that the ladder and the window allow the next attempt."""
    return [rec(now - 5 * H, "attempt"), rec(now - 5 * H + 1, "login_ok"), rec(now - 5 * H + 2, "start_timeout", 2.0),
            rec(now - 4 * H, "attempt"), rec(now - 4 * H + 1, "login_ok"), rec(now - 4 * H + 2, "start_timeout", 2.0)]


def p2_end(t: float) -> list:
    return [rec(t, "attempt"), rec(t + 1, "login_ok"), rec(t + 2, "start_timeout", 2.0)]


class HelperS14(HelperCase):
    def assertNoSyn(self, recs):
        self.assertFalse([r for r in recs if r.get("syn")], recs)

    def test_sigterm_P0_writes_nothing(self):                           # E1
        h = Helper(self.tmp, "cam1", [], hooks="pause_gate")
        h.wait_locked(15)                                                # in the gate, before any record
        h.term()
        h.wait_exit(10)
        self.assertEqual(h.rc, 0)
        self.assertEqual(h.ledger(), [])
        self.assertEqual(h.stats()["connects"], 0)
        self.assertNotIn("Traceback", h.stderr)

    def test_sigterm_P1_is_net_fail_no_row(self):                       # E4, K2
        now = time.time()
        fixtures.seed_ledger(self.tmp, two_p2_ends(now))
        h = Helper(self.tmp, "cam1", ["--silent-before-challenge"])
        h.wait_ev("attempt", 30)
        h.wait_stats(lambda s: s["connects"] >= 1, 30)                   # the login exchange is under way
        h.term()
        h.wait_exit(10)
        self.assertEqual(h.rc, 0)
        self.assertEqual(evs(h.new()), ["attempt", "net_fail"])
        self.assertEqual(h.stats()["logins_ok"], 0)
        recs, later = h.ledger(), time.time() + 2 * H
        self.assertEqual(policy.decide(recs, later, latch_file=False).cls, "ok")        # row still 2: no +1 ...
        self.assertEqual(policy.decide(recs + p2_end(later - 60), later, latch_file=False).cls,
                         "latched")                                                     # ... and no reset

    def test_sigterm_P2_is_start_timeout_with_row(self):                # E7
        now = time.time()
        fixtures.seed_ledger(self.tmp, two_p2_ends(now))
        h = Helper(self.tmp, "cam1", ["--no-media"])
        h.wait_ev("login_ok", 30)
        time.sleep(2.0)                                                  # the brief: SIGTERM 2 s after login_ok
        h.term()
        h.wait_exit(10)
        self.assertEqual(h.rc, 0)
        self.assertEqual(evs(h.new()), ["attempt", "login_ok", "start_timeout"])
        self.assertEqual(policy.decide(h.ledger(), time.time() + 2 * H, latch_file=False).cls, "latched")  # row 3

    def test_sigterm_P3_is_stop_exit_0_within_5s(self):                 # E13, nit 4
        h = Helper(self.tmp, "cam1", [])
        h.wait_ev("published", 30)
        h.term()
        h.wait_exit(10)
        self.assertEqual(h.rc, 0)
        self.assertLess(h.elapsed, 5.0)
        recs = h.ledger()
        self.assertEqual(evs(recs), ["attempt", "login_ok", "published", "stop"])
        self.assertNoSyn(recs)
        a = recs[0]["t"]
        d = policy.decide(recs, recs[-1]["t"] + 1, latch_file=False)
        self.assertEqual((d.cls, d.next_allowed), ("budget_wait", a + 60))   # the spacing only: no ladder wait
        self.assertTrue(policy.decide(recs, a + 60, latch_file=False).allow)

    def test_J1_sigterm_within_1s_of_login_ok_silent_camera(self):      # J1, nit 3
        h = Helper(self.tmp, "cam1", ["--silent-after-login"])
        h.wait_ev("login_ok", 30)
        time.sleep(0.5)                                                  # the brief: 0.5 s after login_ok
        h.term()
        h.wait_exit(10)
        self.assertEqual(h.rc, 0)
        self.assertLess(h.elapsed, 5.0)
        recs = h.ledger()
        self.assertEqual(evs(recs), ["attempt", "login_ok", "start_timeout"])
        self.assertNoSyn(recs)

    def test_J3_kill_ffmpeg_then_sigterm_200ms_is_stop(self):           # J3, nit 2, H5b
        h = Helper(self.tmp, "cam1", [])
        h.wait_ev("published", 30)
        h.kill_ffmpeg()
        time.sleep(0.2)                                                  # the spec: SIGTERM 200 ms later
        h.term()
        h.wait_exit(10)
        self.assertEqual(h.rc, 0)
        self.assertEqual(evs(h.ledger()), ["attempt", "login_ok", "published", "stop"])

    def test_process_group_sigterm_is_stop_20_of_20(self):              # H5b, an extra check
        results = []
        for i in range(20):
            h = Helper(self.tmp / f"run{i:02d}", "cam1", [])
            h.wait_ev("published", 30)
            h.term_group()                                               # helper and ffmpeg at the same moment
            h.wait_exit(10)
            results.append((h.rc, evs(h.ledger())[-1], round(h.elapsed, 2)))
            h.close()
        print(f"evidence - process-group SIGTERM: {results}", file=sys.stderr)
        self.assertEqual([r[:2] for r in results], [(0, "stop")] * 20)
        self.assertLess(max(r[2] for r in results), 5.0)

    def test_L1_two_sigterms_50ms_apart_after_published(self):          # L1, SF4
        h = Helper(self.tmp, "cam1", [], hooks="pause_close")
        h.wait_ev("published", 30)
        h.term()
        time.sleep(0.05)
        h.term()
        h.wait_exit(10)
        self.assertEqual(h.rc, 0)
        self.assertLess(h.elapsed, 5.0)
        self.assertEqual(evs(h.ledger()), ["attempt", "login_ok", "published", "stop"])
        self.assertNotIn("Traceback", h.stderr)

    def test_SF2_sigterm_held_in_login_ok_write_is_start_timeout(self):  # SF2, K1
        h = Helper(self.tmp, "cam1", [], hooks="pause_cs:login_ok")
        h.wait_ev("attempt", 30)
        h.wait_half_written(30)
        h.term()
        h.wait_exit(10)
        self.assertEqual(h.rc, 0)
        recs = h.ledger()
        self.assertEqual(evs(recs), ["attempt", "login_ok", "start_timeout"])
        self.assertNoSyn(recs)

    def test_SF3_sigterm_in_session_end_write_one_record(self):         # SF3
        h = fixtures.Helper(self.tmp, "cam1", ["--close-after-s", "1"], hooks="pause_cs:session_end")
        h.wait_ev("login_ok", 10)
        h.wait_half_written(10)
        h.term()
        h.wait_exit(10)
        self.assertEqual([r["ev"] for r in h.ledger()], ["attempt", "login_ok", "session_end"])
        self.assertEqual(h.rc, 75)
        self.assertNotIn("Traceback", h.stderr)

    def test_stall_hook_ends_by_sigalrm_within_5s(self):                # H5a, E17
        h = Helper(self.tmp, "cam1", [], hooks="stall_close")
        h.wait_ev("published", 30)
        h.term()
        h.wait_exit(10)
        self.assertEqual(h.rc, -signal.SIGALRM)
        self.assertLess(h.elapsed, 5.0)
        self.assertEqual(evs(h.ledger()), ["attempt", "login_ok", "published"])
        nxt = Helper(self.tmp, "cam1", None)                             # the next decision
        nxt.wait_exit(10)
        self.assertEqual(nxt.rc, 75)
        self.assertIn("ezviz-source cam1: budget_wait", nxt.stderr)
        recs = nxt.ledger()
        self.assertEqual(evs(recs), ["attempt", "login_ok", "published", "unknown_end"])
        self.assertTrue(recs[-1].get("syn"))

    def test_R2N3_ffmpeg_ignoring_term_does_not_delay_the_stop_record(self):  # R2-N3, D17 order
        # The record must not wait for ffmpeg: closing ffmpeg first (2 s, it ignores SIGTERM) would put it >= 2 s late.
        h = Helper(self.tmp, "cam1", [], ffmpeg_knobs={"ignore_term": 1})
        h.wait_ev("published", 30)
        ff = h.ffmpeg_pid()
        t_term = time.time()
        h.term()
        h.wait_exit(10)
        self.assertEqual(h.rc, 0)
        self.assertLess(h.elapsed, 5.0)
        recs = h.ledger()
        self.assertEqual(evs(recs), ["attempt", "login_ok", "published", "stop"])
        self.assertNoSyn(recs)
        lag = recs[-1]["t"] - t_term
        print(f"evidence - R2-N3 stop record {lag * 1000:.0f} ms after SIGTERM, exit {h.elapsed:.2f} s", file=sys.stderr)
        self.assertLess(lag, 1.0)
        end = time.monotonic() + 3
        while Path(f"/proc/{ff}").exists() and time.monotonic() < end:
            time.sleep(0.02)
        self.assertFalse(Path(f"/proc/{ff}").exists(), "ffmpeg outlived the helper")

    def test_auth_fail_keeps_precedence_over_a_later_sigterm(self):     # ruling: E2 wins over E4 once classified
        h = Helper(self.tmp, "cam1", ["--reject"], hooks="pause_end")
        h.wait_stderr("exception", 30)            # run() has classified auth_fail; end() now pauses before its section
        h.term()
        h.wait_exit(10)
        self.assertEqual(h.rc, 77)
        self.assertEqual(evs(h.ledger()), ["attempt", "auth_fail", "latch"])
        self.assertTrue((h.state / "cam1.latch").exists())
        self.assertNotIn("Traceback", h.stderr)

    def test_sigterm_in_close_reclassifies_session_end_as_start_timeout(self):  # finish(): E7 over E8
        h = Helper(self.tmp, "cam1", ["--close-after-s", "1"], hooks="pause_close")
        h.wait_ev("login_ok", 30)
        h.wait_stderr("exception", 30)            # run() returned session_end; finish() now pauses in _close()
        h.term()
        h.wait_exit(10)
        self.assertEqual(h.rc, 0)
        recs = h.ledger()
        self.assertEqual(evs(recs), ["attempt", "login_ok", "start_timeout"])
        self.assertNoSyn(recs)
        self.assertNotIn("Traceback", h.stderr)

    def test_R2N9_sigterm_before_end_section_writes_the_phase_record(self):  # R2-N9
        h = Helper(self.tmp, "cam1", ["--close-after-s", "1"], hooks="pause_end")
        h.wait_ev("login_ok", 30)
        h.wait_stderr("exception", 30)            # run() classified the camera close; end() now pauses before its section
        h.term()
        h.wait_exit(10)
        self.assertEqual(h.rc, 0)
        recs = h.ledger()
        self.assertEqual(evs(recs), ["attempt", "login_ok", "start_timeout"])
        self.assertNoSyn(recs)
        self.assertNotIn("Traceback", h.stderr)


if __name__ == "__main__":
    unittest.main()
