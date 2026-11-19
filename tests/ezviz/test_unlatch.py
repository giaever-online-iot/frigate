import _path
import json
import os
import time
import unittest
from unittest import mock

from fixtures import Tree
from ezviz_source import policy, unlatch

NOW = time.time()


def rec(dt, ev):
    return json.dumps({"t": NOW + dt, "ev": ev, "dur": None}) + "\n"


def row_full():
    out = []
    for dt in (-30000, -20000, -10000):
        out += [rec(dt, "attempt"), rec(dt + 2, "login_ok"), rec(dt + 9, "session_end")]
    return out


class TestUnlatch(unittest.TestCase):
    def setUp(self):
        self.t = Tree()
        self.env = mock.patch.dict(os.environ, {"SNAP_DATA": str(self.t.data), "SNAP_COMMON": str(self.t.common)})
        self.env.start()
        self.t.seed(row_full())
        (self.t.state / "cam1.latch").touch()

    def tearDown(self):
        self.env.stop()

    def evs(self):
        return [json.loads(x)["ev"] for x in self.t.ledger().read_text().splitlines()]

    def run_unlatch(self, cfg):
        with mock.patch("sys.stdout.write") as w:
            unlatch.run(cfg)
        return "".join(c.args[0] for c in w.call_args_list)

    def test_unlatch_removes_latch_appends_record_and_seen(self):
        out = self.run_unlatch({"cam1": {"unlatch": 1794000000}})
        self.assertEqual(out, "configure: ezviz cam1 unlatched\n")
        self.assertFalse((self.t.state / "cam1.latch").exists())
        self.assertEqual(self.evs()[-1], "unlatch")
        self.assertEqual((self.t.state / "cam1.unlatch-seen").read_text(), "1794000000\n")

    def test_same_value_twice_unlatches_once(self):
        self.run_unlatch({"cam1": {"unlatch": 1794000000}})
        self.assertEqual(self.run_unlatch({"cam1": {"unlatch": 1794000000}}), "")
        self.assertEqual(self.evs().count("unlatch"), 1)

    def test_later_set_of_other_key_does_not_unlatch_new_latch(self):
        self.run_unlatch({"cam1": {"unlatch": 1794000000}})
        (self.t.state / "cam1.latch").touch()                       # latched again later
        self.run_unlatch({"cam1": {"unlatch": 1794000000}})          # configure runs for another key
        self.assertTrue((self.t.state / "cam1.latch").exists())

    def test_ledger_only_latch_is_cleared(self):                     # N3
        (self.t.state / "cam1.latch").unlink()
        self.assertEqual(self.run_unlatch({"cam1": {"unlatch": 1}}), "configure: ezviz cam1 unlatched\n")
        self.assertEqual(policy.decide([json.loads(x) for x in self.t.ledger().read_text().splitlines()],
                                       time.time() + 7200, latch_file=False).cls, "ok")

    def test_not_latched_prints_and_records_seen(self):
        (self.t.state / "cam1.latch").unlink()
        self.t.seed([rec(-100, "attempt"), rec(-90, "net_fail")])
        self.assertEqual(self.run_unlatch({"cam1": {"unlatch": 5}}), "configure: ezviz cam1 not latched\n")
        self.assertTrue((self.t.state / "cam1.unlatch-seen").exists())

    def test_bad_value_ignored(self):
        self.assertEqual(self.run_unlatch({"cam1": {"unlatch": "x"}}), "configure: ezviz cam1 ignored (not an integer)\n")
        self.assertTrue((self.t.state / "cam1.latch").exists())

    def test_policy_after_unlatch_allows_when_budget_does(self):    # P6
        self.run_unlatch({"cam1": {"unlatch": 7}})
        recs = [json.loads(x) for x in self.t.ledger().read_text().splitlines()]
        self.assertTrue(policy.decide(recs, time.time() + 1, latch_file=False).allow)

    def test_damaged_ledger_untouched_when_no_new_value(self):      # R2-N10 note: ledger opened only for a NEW value
        bad = b"not json at all\n" + rec(-5, "attempt").encode()
        self.t.ledger().write_bytes(bad)
        (self.t.state / "cam1.unlatch-seen").write_text("9\n")
        self.assertEqual(unlatch.run({"cam1": {"unlatch": 9}}), 0)   # seen value: ledger never opened
        self.assertEqual(unlatch.run({"cam1": {}}), 0)               # no value at all
        self.assertEqual(self.t.ledger().read_bytes(), bad)


if __name__ == "__main__":
    unittest.main()
