import _path
import fcntl
import json
import os
import re
import signal
import statistics
import time
import unittest

from fixtures import CANARIES, GOOD, Tree, gate_proc, run_gate

NOW = time.time()


def rec(dt, ev, **kw):
    return json.dumps(dict({"t": NOW + dt, "ev": ev, "dur": None}, **kw)) + "\n"


class TestGate(unittest.TestCase):
    def evs(self, tree):
        return [json.loads(x)["ev"] for x in tree.ledger().read_text().splitlines()]

    def test_busy_when_session_lock_held(self):
        t = Tree()
        t.state.mkdir(parents=True, mode=0o700)
        fd = os.open(t.state / "cam1.session", os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        rc, _, err, _ = run_gate(t)
        os.close(fd)
        self.assertEqual((rc, err.strip()), (75, "ezviz-source cam1: busy"))
        self.assertFalse(t.ledger().exists())

    def test_missing_camera_file_is_config_78_no_ledger_write(self):        # G3
        t = Tree(camfile=None)
        rc, _, err, _ = run_gate(t)
        self.assertEqual((rc, err.strip()), (78, "ezviz-source cam1: config"))
        self.assertFalse(t.ledger().exists())

    def test_malformed_camera_file_is_config_78_no_ledger_write(self):
        t = Tree(camfile=GOOD + "extra=1\n")
        rc, _, _, _ = run_gate(t)
        self.assertEqual(rc, 78)
        self.assertFalse(t.ledger().exists())

    def test_attempt_on_disk_before_return(self):                            # F3 (the connect half: Task 11)
        t = Tree()
        rc, out, _, _ = run_gate(t)
        self.assertEqual((rc, out.strip(), self.evs(t)), (0, "ADMITTED", ["attempt"]))

    def test_budget_wait_refusal_under_150_ms_and_no_pyezvizapi(self):     # N5
        t = Tree()
        t.seed([rec(-300, "attempt"), rec(-299, "net_fail"), rec(-200, "attempt"), rec(-199, "net_fail"),
                rec(-100, "attempt"), rec(-99, "net_fail")])
        secs = []
        for _ in range(5):
            rc, _, err, s = run_gate(t, pyflags=("-X", "importtime"))
            secs.append(s)
            self.assertEqual(rc, 75)
            self.assertIn("ezviz-source cam1: budget_wait", err)
            self.assertNotIn("pyezvizapi", err)
            self.assertNotIn("ezviz_source.camera", err)
        self.assertLess(statistics.median(secs), 0.150)

    def test_latched_refusal(self):
        t = Tree()
        t.state.mkdir(parents=True, mode=0o700)
        (t.state / "cam1.latch").touch()
        rc, _, err, _ = run_gate(t)
        self.assertEqual((rc, err.strip()), (75, "ezviz-source cam1: latched"))

    def test_row_full_writes_latch_file_and_record_once(self):              # P9
        t = Tree()
        lines = []
        for dt in (-30000, -20000, -10000):
            lines += [rec(dt, "attempt"), rec(dt + 2, "login_ok"), rec(dt + 9, "start_timeout")]
        t.seed(lines)
        for _ in range(2):
            self.assertEqual(run_gate(t)[0], 75)
        self.assertTrue((t.state / "cam1.latch").exists())
        self.assertEqual(self.evs(t).count("latch"), 1)

    def test_latch_write_failure_is_ledger_io(self):                        # review fix 1
        t = Tree()
        lines = []
        for dt in (-30000, -20000, -10000):
            lines += [rec(dt, "attempt"), rec(dt + 2, "login_ok"), rec(dt + 9, "start_timeout")]
        t.seed(lines)
        os.symlink("nowhere", t.state / "cam1.latch")
        rc, out, err, _ = run_gate(t)
        self.assertEqual((rc, out, err.strip()), (75, "", "ezviz-source cam1: ledger_io"))

    def test_synthetic_written_once_across_refusals(self):                  # H3
        t = Tree()
        t.seed([rec(-30, "attempt")])
        ns = []
        for _ in range(2):
            rc, _, err, _ = run_gate(t)
            self.assertEqual(rc, 75)
            ns.append(int(re.search(r"next allowed \+(\d+)s", err).group(1)))
            time.sleep(1)
        self.assertLessEqual(ns[1], ns[0])                                  # H3: spacing does not move later
        self.assertEqual(self.evs(t), ["attempt", "net_fail"])

    def test_ledger_damaged_refuses_without_contact(self):                  # Review Focus 2, P8
        t = Tree()
        t.seed([rec(-9000, "attempt"), "garbage\n", rec(-8000, "stop")])
        rc, _, err, _ = run_gate(t)
        self.assertEqual((rc, err.strip()), (75, "ezviz-source cam1: ledger_damaged"))

    def test_attempt_write_failure_means_no_contact(self):                  # Review Focus 3
        t = Tree()
        rc, out, err, _ = run_gate(t, EZVIZ_TEST_HOOKS="enospc_append")
        self.assertEqual((rc, out, err.strip()), (75, "", "ezviz-source cam1: ledger_io"))
        self.assertNotIn("attempt", t.ledger().read_text() if t.ledger().exists() else "")

    def test_ten_concurrent_helpers_on_fresh_state(self):                   # Review Focus 4
        t = Tree()
        ps = [gate_proc(t, 2.0) for _ in range(10)]
        res = [p.communicate(timeout=30) + (p.returncode,) for p in ps]
        self.assertEqual(sum(1 for o, e, rc in res if o.strip() == "ADMITTED"), 1)
        self.assertEqual(sum(1 for o, e, rc in res if rc == 75 and e.strip() == "ezviz-source cam1: busy"), 9)
        self.assertEqual(t.state.stat().st_mode & 0o777, 0o700)
        for f in t.state.iterdir():
            self.assertEqual(f.stat().st_mode & 0o777, 0o600, f.name)

    def test_sigterm_mid_attempt_record_completes_the_record(self):         # R2-N5, K1
        from ezviz_source import ledger as ledger_mod
        t = Tree()
        p = gate_proc(t, EZVIZ_TEST_HOOKS="pause_cs:attempt")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if t.ledger().exists():
                b = t.ledger().read_bytes()
                if b and not b.endswith(b"\n"):
                    break
            time.sleep(0.02)
        else:
            p.kill()
            self.fail("half-written attempt line never appeared")
        p.send_signal(signal.SIGTERM)
        out, _ = p.communicate(timeout=10)
        events = [r["ev"] for r in ledger_mod.parse(t.ledger().read_bytes())]
        self.assertEqual(events, ["attempt"])
        self.assertEqual((p.returncode, out), (0, ""))

    def test_lines_carry_no_camera_value(self):
        t = Tree()
        rc, out, err, _ = run_gate(t)
        self.assertEqual((rc, out), (0, "ADMITTED\n"))
        t.seed([rec(-100, "attempt"), rec(-99, "auth_fail")])
        rc2, out2, err2, _ = run_gate(t)
        self.assertEqual((rc2, err2.strip()), (75, "ezviz-source cam1: latched"))
        for c in CANARIES:
            for s in (out, err, out2, err2, t.ledger().read_text()):
                self.assertNotIn(c, s)


if __name__ == "__main__":
    unittest.main()
