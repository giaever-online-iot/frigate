import _path
import unittest

from ezviz_source.policy import decide, phase_of_open_session

T0 = 1_800_000_000.0


def R(t, ev, **kw):
    return dict({"t": T0 + t, "ev": ev, "dur": None}, **kw)


def P2(t, end_ev, end_after=9):
    """A session that logged in at t+2 and ended (end_ev) before publishing."""
    return [R(t, "attempt"), R(t + 2, "login_ok"), R(t + end_after, end_ev)]


def P3(t, end_ev, end_at):
    """A session published at t+9 that ended (end_ev) at t+end_at."""
    return [R(t, "attempt"), R(t + 2, "login_ok"), R(t + 9, "published"), R(t + end_at, end_ev)]


def P1(t):
    return [R(t, "attempt"), R(t + 1, "net_fail")]


def at(recs, t, latch_file=False):
    return decide(recs, T0 + t, latch_file=latch_file)


class TestTEnd(unittest.TestCase):
    def test_E1_empty_ledger_allows(self):
        d = at([], 0)
        self.assertEqual((d.allow, d.cls, d.synthetic, d.attempts_in_window), (True, "ok", None, 0))

    def test_E2_auth_fail_latches(self):
        d = at([R(0, "attempt"), R(1, "auth_fail")], 7200)
        self.assertEqual((d.allow, d.cls, d.latch_now), (False, "latched", True))

    def test_E2_latch_file_present_means_no_second_latch_record(self):
        d = at([R(0, "attempt"), R(1, "auth_fail")], 7200, latch_file=True)
        self.assertEqual((d.cls, d.latch_now), ("latched", False))

    def test_E3_net_fail_is_rung_60(self):
        d = at([R(0, "attempt"), R(5, "net_fail")], 30)
        self.assertEqual(d.next_allowed, T0 + 65)

    def test_E5_open_P1_gets_synthetic_net_fail_once(self):          # D21, H3
        recs = [R(0, "attempt")]
        d = at(recs, 100)
        self.assertEqual((d.synthetic["ev"], d.synthetic["syn"], d.synthetic["t"]), ("net_fail", True, T0 + 100))
        self.assertEqual(d.next_allowed, T0 + 160)
        d2 = at(recs + [d.synthetic], 130)                             # a refused decision 30 s later
        self.assertIsNone(d2.synthetic)
        self.assertEqual(d2.next_allowed, d.next_allowed)

    def test_E6_published_resets_row(self):
        recs = P2(0, "start_timeout") + P2(1000, "start_timeout") + P3(2000, "stop", 100) + P2(3000, "start_timeout")
        self.assertEqual(at(recs, 9000).cls, "ok")

    def test_E7_E8_E9_E10_each_add_one(self):                           # K3
        for ev in ("start_timeout", "session_end", "output_end", "protocol_fail"):
            recs = P2(0, ev) + P2(7200, ev) + P2(14400, ev)
            self.assertEqual(at(recs, 30000).cls, "latched", ev)

    def test_two_P2_ends_do_not_latch(self):
        self.assertEqual(at(P2(0, "session_end") + P2(7200, "session_end"), 30000).cls, "ok")

    def test_E11_open_P2_gets_unknown_end_and_adds_to_row(self):
        recs = P2(0, "start_timeout") + P2(7200, "start_timeout") + [R(14400, "attempt"), R(14402, "login_ok")]
        d = at(recs, 14500)
        self.assertEqual((d.synthetic["ev"], d.cls, d.latch_now), ("unknown_end", "latched", True))

    def test_E13_stop_after_published_has_no_wait_but_spacing(self):
        recs = P3(0, "stop", 20)
        self.assertEqual(at(recs, 30).next_allowed, T0 + 60)
        self.assertTrue(at(recs, 60).allow)

    def test_E14_session_end_after_published_is_rung(self):
        self.assertEqual(at(P3(0, "session_end", 100), 120).next_allowed, T0 + 160)

    def test_E17_open_P3_waits_fixed_60_and_does_not_climb(self):
        recs = [R(0, "attempt"), R(2, "login_ok"), R(9, "published")]
        d = at(recs, 500)
        self.assertEqual((d.synthetic["ev"], d.next_allowed), ("unknown_end", T0 + 560))
        recs2 = recs + [d.synthetic, R(600, "attempt"), R(602, "login_ok"), R(609, "published")]
        d2 = at(recs2, 900)
        self.assertEqual((d2.synthetic["ev"], d2.next_allowed), ("unknown_end", T0 + 960))

    def test_phase_of_open_session(self):
        self.assertEqual(phase_of_open_session([R(0, "attempt")]), "P1")
        self.assertEqual(phase_of_open_session([R(0, "attempt"), R(1, "login_ok")]), "P2")
        self.assertEqual(phase_of_open_session(P3(0, "stop", 20)[:3]), "P3")
        self.assertIsNone(phase_of_open_session(P3(0, "stop", 20)))


class TestBudget(unittest.TestCase):
    def test_fourth_attempt_in_60_min_refused(self):
        recs = P3(0, "stop", 60) + P3(70, "stop", 60) + P3(140, "stop", 60)
        d = at(recs, 300)
        self.assertEqual((d.allow, d.cls, d.next_allowed, d.attempts_in_window), (False, "budget_wait", T0 + 3600, 3))
        self.assertTrue(at(recs, 3600).allow)

    def test_attempt_within_60_s_refused(self):
        recs = P3(0, "stop", 20)
        d = at(recs, 59)
        self.assertEqual((d.allow, d.next_allowed), (False, T0 + 60))
        self.assertTrue(at(recs, 60).allow)

    def test_cap_counts_attempt_records_only(self):
        recs = [R(0, "attempt"), R(100, "net_fail", syn=True), R(200, "attempt"), R(205, "net_fail"), R(206, "latch")]
        self.assertEqual(at(recs, 300).attempts_in_window, 2)

    def test_ladder_climbs_60_300_900_then_window(self):
        recs, got = [], []
        for t in (0, 61, 362, 3600):                                   # each attempt at its allowed time
            recs += [R(t, "attempt"), R(t + 1, "net_fail")]
            got.append(at(recs, t + 2).next_allowed - T0)
        self.assertEqual(got, [61, 362, 3600, 3661])                   # rung 3 (900 s) is inside the cap here

    def test_third_rung_waits_900(self):                               # older attempts: the cap does not bind
        self.assertEqual(at(P1(0) + P1(3000) + P1(3400), 3402).next_allowed, T0 + 3401 + 900)

    def test_ladder_resets_after_60_min_published(self):              # D4: resets TO 60 s (SF1)
        recs = P1(0) + P1(61) + P3(362, "session_end", 9 + 3600)     # published 3600 s, then dropped
        self.assertEqual(at(recs, 3980).next_allowed, T0 + 362 + 3609 + 60)

    def test_ladder_resets_after_60_min_idle(self):                   # SF1(c)
        recs = P1(0) + P1(61) + P1(362) + P1(362 + 3600)               # k=3, then an attempt 3600 s later
        self.assertEqual(at(recs, 3970).next_allowed, T0 + 3963 + 60)

    def test_ladder_back_to_60_s_at_decision_time_after_idle_hour(self):
        recs = P1(0) + P1(61) + P3(362, "session_end", 3138)          # k=3: wait until 3500 + 900
        self.assertEqual(at(recs, 3961).next_allowed, T0 + 4400)       # 3599 s since the last attempt
        self.assertTrue(at(recs, 3962).allow)                          # 3600 s: rung back to 60 s, long past

    def test_future_dated_attempt_counts_in_window_and_spacing(self):  # Review Focus 1
        d = at([R(600, "attempt"), R(605, "net_fail")], 0)
        self.assertEqual((d.allow, d.attempts_in_window), (False, 1))
        self.assertGreaterEqual(d.next_allowed, T0 + 660)

    def test_latch_file_alone_latches(self):
        self.assertEqual(at([], 0, latch_file=True).cls, "latched")

    def test_unlatch_resets_row_and_ladder_not_cap(self):             # P6
        recs = P2(0, "start_timeout") + P2(600, "start_timeout") + P2(1200, "start_timeout")
        self.assertEqual(at(recs, 1400).cls, "latched")
        d = at(recs + [R(1209, "latch"), R(1300, "unlatch")], 1400)
        self.assertEqual((d.cls, d.next_allowed), ("budget_wait", T0 + 3600))

    def test_auth_fail_before_unlatch_no_longer_latches(self):
        recs = [R(0, "attempt"), R(1, "auth_fail"), R(1, "latch"), R(4000, "unlatch")]
        self.assertTrue(at(recs, 4100).allow)

    def test_J2_start_timeout_net_fail_start_timeout_start_timeout_latches(self):
        recs = P2(0, "start_timeout") + P1(7200) + P2(14400, "start_timeout") + P2(21600, "start_timeout")
        self.assertEqual(at(recs, 30000).cls, "latched")


if __name__ == "__main__":
    unittest.main()
