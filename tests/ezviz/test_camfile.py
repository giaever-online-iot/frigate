import _path
import errno
import os
import threading
import unittest
from unittest import mock

from fixtures import GOOD, tmpdir
from ezviz_source import camfile
from ezviz_source.camfile import CameraFileError, load


def mk(text, mode=0o600):
    d = tmpdir()
    f = d / "cam1.conf"
    f.write_text(text)
    f.chmod(mode)
    return d


class TestCamfile(unittest.TestCase):
    def cls(self, d):
        with self.assertRaises(CameraFileError) as cm:
            load("cam1", d)
        return cm.exception.cls

    def test_good(self):
        c = load("cam1", mk(GOOD))
        self.assertEqual((c.host, c.port, c.serial, c.login), ("192.0.2.11", 8000, "TESTCAM-0001", "QZCNRA"))

    def test_repr_has_no_value(self):
        self.assertEqual(repr(load("cam1", mk(GOOD))), "Camera(cam1)")

    def test_missing(self):
        self.assertEqual(self.cls(tmpdir(self)), "missing")

    def test_mode_644(self):
        self.assertEqual(self.cls(mk(GOOD, mode=0o644)), "mode")

    def test_owner(self):
        with mock.patch.object(camfile.os, "geteuid", return_value=os.getuid() + 1):
            self.assertEqual(self.cls(mk(GOOD)), "owner")

    def test_symlink_refused(self):
        d = mk(GOOD)
        (d / "cam1.conf").rename(d / "real.conf")
        os.symlink(d / "real.conf", d / "cam1.conf")
        self.assertEqual(self.cls(d), "missing")

    def test_unknown_key(self):
        self.assertEqual(self.cls(mk(GOOD + "x=1\n")), "shape")

    def test_duplicate_key(self):
        self.assertEqual(self.cls(mk(GOOD + "port=8001\n")), "shape")

    def test_missing_key(self):
        self.assertEqual(self.cls(mk(GOOD.replace("serial=TESTCAM-0001\n", ""))), "shape")

    def test_hostname_refused(self):
        self.assertEqual(self.cls(mk(GOOD.replace("192.0.2.11", "cam.local"))), "shape")

    def test_octet_300(self):
        self.assertEqual(self.cls(mk(GOOD.replace(".11", ".300"))), "shape")

    def test_port_range(self):
        self.assertEqual(self.cls(mk(GOOD.replace("8000", "65536"))), "shape")

    def test_login_shape(self):
        self.assertEqual(self.cls(mk(GOOD.replace("QZCNRA", "QZ CN"))), "shape")

    def test_error_text_is_class_only(self):
        with self.assertRaises(CameraFileError) as cm:
            load("cam1", mk(GOOD.replace("QZCNRA", "QZ!!")))
        self.assertEqual((str(cm.exception), cm.exception.args), ("shape", ("shape",)))

    def test_comment_and_crlf(self):
        self.assertEqual(load("cam1", mk("# x\r\n" + GOOD.replace("\n", "\r\n"))).port, 8000)

    # ---- W-23 final wave (spec D7; T2/T6 parking) ----
    def test_fifo_does_not_hang(self):
        """A FIFO at the camera-file path: open must not block for a writer; it is not a regular file -> missing."""
        d = tmpdir(self)
        os.mkfifo(d / "cam1.conf", 0o600)
        got = []

        def go():
            try:
                load("cam1", d)
                got.append("loaded")
            except CameraFileError as e:
                got.append(e.cls)
        t = threading.Thread(target=go, daemon=True)
        t.start()
        t.join(2.0)
        if t.is_alive():                                   # unblock the reader so the test itself never hangs
            os.close(os.open(d / "cam1.conf", os.O_WRONLY | os.O_NONBLOCK))
            t.join(2.0)
            self.fail("load() blocked on a FIFO for 2 s")
        self.assertEqual(got, ["missing"])

    @staticmethod
    def padded(size):
        """GOOD plus one comment line, `size` bytes in all; the first 4096 bytes alone are also a valid file."""
        return GOOD + "#" + "x" * (size - len(GOOD) - 2) + "\n"

    def test_4097_bytes_is_shape(self):
        text = self.padded(4097)
        self.assertEqual(len(text), 4097)
        self.assertEqual(self.cls(mk(text)), "shape")

    def test_4096_bytes_loads(self):
        text = self.padded(4096)
        self.assertEqual(len(text), 4096)
        self.assertEqual(load("cam1", mk(text)).port, 8000)

    def test_read_error_is_a_class_not_a_traceback(self):
        d = mk(GOOD)
        with mock.patch.object(camfile.os, "read", side_effect=OSError(errno.EIO, "test")):
            self.assertEqual(self.cls(d), "missing")

    def test_fstat_error_is_a_class_not_a_traceback(self):
        d = mk(GOOD)
        with mock.patch.object(camfile.os, "fstat", side_effect=OSError(errno.EIO, "test")):
            self.assertEqual(self.cls(d), "missing")


if __name__ == "__main__":
    unittest.main()
