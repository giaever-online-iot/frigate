import _path
import errno
import fcntl
import os
import threading
import time
import unittest
from unittest import mock

from fixtures import tmpdir
from ezviz_source import ledger
from ezviz_source.ledger import Ledger, LedgerDamaged, LedgerIOError, parse

A = b'{"t":1,"ev":"attempt","dur":null}\n'


class TestLedger(unittest.TestCase):
    def setUp(self):
        self.d = tmpdir(self)
        self.p = self.d / "cam1.ledger"

    def evs(self):
        return [r["ev"] for r in parse(self.p.read_bytes())]

    def test_roundtrip(self):
        with Ledger(self.p) as L:
            L.append({"t": 1.0, "ev": "attempt", "dur": None})
            L.append({"t": 2.0, "ev": "login_ok", "dur": None})
            self.assertEqual([r["ev"] for r in L.records()], ["attempt", "login_ok"])

    def test_torn_last_line_no_newline_is_skipped(self):
        self.assertEqual([r["ev"] for r in parse(A + b'{"t":2,"ev":"pub')], ["attempt"])

    def test_torn_last_line_bad_json_with_newline_is_skipped(self):
        self.assertEqual([r["ev"] for r in parse(A + b'{"t":2,"ev":\n')], ["attempt"])

    def test_torn_login_ok_leaves_session_in_P1(self):
        self.assertEqual(parse(A + b'{"t":2,"ev":"login_o'), [{"t": 1, "ev": "attempt", "dur": None}])

    def test_next_append_starts_on_a_new_line(self):
        self.p.write_bytes(A + b'{"t":2,"ev":"lo')
        with Ledger(self.p) as L:
            L.append({"t": 3, "ev": "net_fail", "dur": 2, "syn": True})
        self.assertEqual(self.p.read_bytes().count(b"\n"), 2)
        self.assertEqual(self.evs(), ["attempt", "net_fail"])

    def test_newline_terminated_torn_last_line_is_dropped_before_append(self):    # C7
        self.p.write_bytes(A + b'{"t":2,"ev":\n')
        with Ledger(self.p) as L:
            L.append({"t": 3, "ev": "net_fail", "dur": 2, "syn": True})
            self.assertEqual([r["ev"] for r in L.records()], ["attempt", "net_fail"])
        self.assertEqual(self.evs(), ["attempt", "net_fail"])

    def test_append_never_erases_mid_file_damage(self):    # C7, P8
        self.p.write_bytes(A + b"bad\n" + b'{"t":2,"ev')
        with Ledger(self.p) as L:
            L.append({"t": 3, "ev": "net_fail", "dur": 2, "syn": True})
            with self.assertRaises(LedgerDamaged):
                L.records()

    def test_mid_file_damage_is_reported(self):
        with self.assertRaises(LedgerDamaged):
            parse(A + b"garbage\n" + b'{"t":3,"ev":"stop","dur":2}\n')

    def test_non_numeric_t_mid_file_is_damage(self):
        with self.assertRaises(LedgerDamaged):
            parse(b'{"t":"x","ev":"attempt"}\n' + A)

    def test_file_mode_0600_and_append_fsyncs_file_and_dir(self):
        with mock.patch.object(ledger.os, "fsync", wraps=os.fsync) as fs:
            with Ledger(self.p) as L:
                L.append({"t": 1.0, "ev": "attempt", "dur": None})
            self.assertEqual(fs.call_count, 2)
        self.assertEqual(self.p.stat().st_mode & 0o777, 0o600)

    def test_append_oserror_becomes_ledgerioerror(self):
        with Ledger(self.p) as L:
            with mock.patch.object(ledger.os, "write", side_effect=OSError(errno.ENOSPC, "full")):
                with self.assertRaises(LedgerIOError):
                    L.append({"t": 1.0, "ev": "attempt", "dur": None})

    def test_trim_keeps_last_7_days_and_keep_from(self):
        now, day = 2_000_000_000.0, 86400
        self.p.write_bytes(b"".join(b'{"t":%d,"ev":"stop","dur":null}\n' % (now - n * day) for n in (9, 8, 6)))
        with Ledger(self.p) as L:
            L.trim(now, keep_from=now - 8 * day)
        self.assertEqual([r["t"] for r in parse(self.p.read_bytes())], [now - 8 * day, now - 6 * day])
        with Ledger(self.p) as L:
            L.trim(now, keep_from=now)
        self.assertEqual([r["t"] for r in parse(self.p.read_bytes())], [now - 6 * day])

    def test_lock_excludes_second_holder(self):
        with Ledger(self.p):
            fd = os.open(self.p, os.O_RDWR)
            try:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                os.close(fd)

    def test_waiter_on_a_trimmed_file_appends_to_the_new_file(self):    # SF12
        now = 2_000_000_000.0
        self.p.write_bytes(b'{"t":%d,"ev":"stop","dur":null}\n' % (now - 9 * 86400) + A)
        done = threading.Event()

        def unlatcher():
            with Ledger(self.p) as L:                 # blocks until the trimmer releases
                L.append({"t": now, "ev": "unlatch", "dur": None})
            done.set()
        with Ledger(self.p) as L:
            th = threading.Thread(target=unlatcher)
            th.start()
            time.sleep(0.3)
            self.assertFalse(done.is_set())
            L.trim(now, keep_from=now)                 # replaces the file: the waiter holds the old inode
        th.join(5)
        self.assertEqual(self.evs(), ["unlatch"])

    def test_symlinked_ledger_refused(self):
        os.symlink(self.d / "elsewhere", self.p)
        with self.assertRaises(LedgerIOError):
            with Ledger(self.p):
                pass


if __name__ == "__main__":
    unittest.main()
