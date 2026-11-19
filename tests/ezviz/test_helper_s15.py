"""S15: the ledger and the latch row against T-END, with real helper runs (W-23 T11).

Spec §9.2 S15, T-END E6/E11/E17 (§4.3), J2, K1, K3, the torn-line rules of §4.3, D21. Between runs of one camera
the harness moves every record 2 h into the past (fixtures.shift_ledger), so the budget allows the next run.
"""
import _path  # noqa: F401
import re
import time
import unittest

import fixtures
from fixtures import Helper, HelperCase, evs, rec
from ezviz_source import policy

H = 3600.0


def p2_end(t: float) -> list:
    return [rec(t, "attempt"), rec(t + 1, "login_ok"), rec(t + 2, "start_timeout", 2.0)]


def next_in(stderr: str) -> int:
    m = re.search(r"ezviz-source cam1: budget_wait next allowed \+(\d+)s", stderr)
    assert m, stderr
    return int(m.group(1))


class HelperS15(HelperCase):
    def latched_next(self, prev: Helper) -> Helper:
        """Run the next helper against a live fake: it must refuse `latched` without a connect."""
        fixtures.shift_ledger(self.tmp, 2 * H)
        nxt = Helper(self.tmp, "cam1", [])
        nxt.wait_exit(10)
        self.assertEqual(nxt.rc, 75, nxt.stderr)
        self.assertIn("ezviz-source cam1: latched", nxt.stderr)
        self.assertEqual(nxt.stats()["connects"], 0)
        self.assertEqual(evs(nxt.ledger())[-1], "latch")
        self.assertTrue((nxt.state / "cam1.latch").exists())
        return nxt

    def test_published_written_at_publish_point_and_resets_row(self):  # E6
        now = time.time()
        fixtures.seed_ledger(self.tmp, p2_end(now - 5 * H) + p2_end(now - 4 * H))
        h = Helper(self.tmp, "cam1", [])
        pub = h.wait_ev("published", 30)
        login_ok = next(r for r in h.new() if r["ev"] == "login_ok")
        self.assertGreaterEqual(pub["t"] - login_ok["t"], 5.0)           # first IDR + 5 s (D22)
        h.term()
        h.wait_exit(10)
        self.assertEqual(evs(h.new()), ["attempt", "login_ok", "published", "stop"])
        later = time.time() + 2 * H
        self.assertEqual(policy.decide(h.ledger(), later, latch_file=False).cls, "ok")
        one_more = p2_end(later - 60)
        self.assertNotEqual(policy.decide(h.ledger() + one_more, later, latch_file=False).cls, "latched")   # row 1
        seeded = h.ledger()[:h.base]
        self.assertEqual(policy.decide(seeded + one_more, later, latch_file=False).cls, "latched")  # control: row 3

    def test_J2_start_timeout_net_fail_start_timeout_start_timeout_latches(self):  # J2
        ends = []
        for kind in ("start_timeout", "net_fail", "start_timeout", "start_timeout"):
            if ends:
                fixtures.shift_ledger(self.tmp, 2 * H)
            if kind == "net_fail":
                h = Helper(self.tmp, "cam1", None)                       # a closed port: E3
            else:
                h = Helper(self.tmp, "cam1", ["--no-media"])
                h.wait_ev("login_ok", 30)
                time.sleep(0.5)
                h.term()                                                 # E7
            h.wait_exit(30)
            ends.append(evs(h.new())[-1])
            self.assertNotIn("latch", evs(h.ledger()))
        self.assertEqual(ends, ["start_timeout", "net_fail", "start_timeout", "start_timeout"])
        self.latched_next(h)

    def test_K3_three_session_end_before_publish_latch(self):          # K3
        for i in range(3):
            if i:
                fixtures.shift_ledger(self.tmp, 2 * H)
            h = Helper(self.tmp, "cam1", ["--close-after-s", "2"])
            h.wait_exit(30)
            self.assertEqual(h.rc, 75)
            self.assertEqual(evs(h.new()), ["attempt", "login_ok", "session_end"])
        self.latched_next(h)

    def test_unknown_end_P2_rung_P3_fixed(self):                        # E11, E17
        # A rung end 30 min ago puts the ladder at k=1, so the next rung waits 300 s, while E17 waits a fixed 60 s.
        got = {}
        for phase, ev, args in (("P2", "login_ok", ["--no-media"]), ("P3", "published", [])):
            tmp = self.tmp / phase
            now = time.time()
            fixtures.seed_ledger(tmp, [rec(now - 1800, "attempt"), rec(now - 1799, "net_fail", 1.0)])
            h = Helper(tmp, "cam1", args)
            h.wait_ev(ev, 30)
            h.kill()                                                     # SIGKILL: no end record
            h.wait_exit(10)
            self.assertEqual(h.rc, -9)
            nxt = Helper(tmp, "cam1", None)
            nxt.wait_exit(10)
            self.assertEqual(nxt.rc, 75)
            recs = nxt.ledger()
            self.assertEqual(recs[-1]["ev"], "unknown_end")
            self.assertTrue(recs[-1].get("syn"))
            got[phase] = next_in(nxt.stderr)
        self.assertTrue(240 <= got["P2"] <= 300, got)                    # rung: climbed to the 2nd rung (300 s)
        self.assertTrue(0 < got["P3"] <= 60, got)                        # fixed 60 s, no climb

    def test_K1_sigterm_inside_ledger_write_leaves_complete_record(self):  # K1
        h = Helper(self.tmp, "cam1", [], hooks="pause_cs:published")
        h.wait_ev("login_ok", 30)
        h.wait_half_written(30)
        h.term()
        h.wait_exit(10)
        self.assertEqual(h.rc, 0)
        self.assertEqual(evs(h.ledger()), ["attempt", "login_ok", "published", "stop"])
        self.assertTrue(h.ledger_path.read_bytes().endswith(b"\n"))

    def test_torn_last_line_then_next_decision_and_new_line(self):     # §4.3 torn last line, D21
        now = time.time()
        fixtures.seed_ledger(self.tmp, [rec(now - 2 * H, "attempt"), rec(now - 2 * H + 1, "login_ok"),
                                        rec(now - 2 * H + 7, "published")], torn=b'{"t":')
        h = Helper(self.tmp, "cam1", None)
        h.wait_exit(10)
        self.assertEqual(h.rc, 75)                                       # E17: fixed 60 s from the synthetic record
        self.assertIn("ezviz-source cam1: budget_wait", h.stderr)
        raw = h.ledger_path.read_bytes()
        self.assertTrue(raw.endswith(b"\n"))
        self.assertNotIn(b'{"t":{', raw)
        lines = raw.split(b"\n")[:-1]
        self.assertEqual(len(lines), 4)
        recs = h.ledger()
        self.assertEqual(evs(recs), ["attempt", "login_ok", "published", "unknown_end"])
        self.assertTrue(recs[-1].get("syn"))

    def test_torn_login_ok_falls_back_to_P1(self):                      # §4.3: a torn record leaves the earlier phase
        now = time.time()
        fixtures.seed_ledger(self.tmp, p2_end(now - 5 * H) + p2_end(now - 4 * H) + [rec(now - 2 * H, "attempt")],
                             torn=b'{"t":%.3f,"ev":"login_ok"' % (now - 2 * H + 1))
        h = Helper(self.tmp, "cam1", None)                               # no helper of that session is alive
        h.wait_exit(10)
        self.assertEqual(h.rc, 75)
        self.assertIn("ezviz-source cam1: budget_wait", h.stderr)        # not latched: the session is P1, no +1
        recs = h.ledger()
        self.assertEqual(evs(recs)[-2:], ["attempt", "net_fail"])
        self.assertTrue(recs[-1].get("syn"))
        self.assertNotIn("latch", evs(recs))


if __name__ == "__main__":
    unittest.main()
