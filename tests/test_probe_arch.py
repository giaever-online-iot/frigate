import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "spike", "probes"))
import probe_common  # noqa: E402


class ArchTriplet(unittest.TestCase):
    def test_x86_64(self):
        with mock.patch("platform.machine", return_value="x86_64"):
            self.assertEqual(probe_common.arch_triplet(), "x86_64-linux-gnu")

    def test_aarch64(self):
        with mock.patch("platform.machine", return_value="aarch64"):
            self.assertEqual(probe_common.arch_triplet(), "aarch64-linux-gnu")

    def test_unknown_fails_loud(self):
        with mock.patch("platform.machine", return_value="riscv64"):
            with self.assertRaisesRegex(RuntimeError, "unsupported machine: riscv64"):
                probe_common.arch_triplet()

    def test_edgetpu_lib_arm64(self):
        with mock.patch("platform.machine", return_value="aarch64"), \
             mock.patch.dict(os.environ, {"SNAP": "/snap/frigate/x1"}):
            self.assertEqual(probe_common.edgetpu_lib(),
                             "/snap/frigate/x1/usr/lib/aarch64-linux-gnu/libedgetpu.so.1")


if __name__ == "__main__":
    unittest.main()
