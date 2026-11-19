"""Fix wave 1, S3: the venv is per checkout by default, and every `python -I` child of the tests imports THIS
checkout's ezviz_source. Under -I, PYTHONPATH is ignored and the venv's ezviz_source.pth decides; that .pth names the
last checkout that ran venv.sh with the same W23_VENV."""
import _path
import hashlib
import os
import re
import shutil
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

import fixtures

HERE = Path(__file__).resolve().parent


def _lock_sha() -> str:
    return hashlib.sha256((_path.REPO / "spike/ezviz/requirements.txt").read_bytes()).hexdigest()


class TestVenvDefault(unittest.TestCase):
    """venv.sh run against a pre-made venv dir (lock.sha256 matches, bin/python is a stub that prints a purelib path),
    so nothing is built and nothing is fetched. A stub python3.12 that fails stops a wrong path from building one."""

    def _run(self, home: Path, venv: Path, **env_extra):
        sp = home / "sp"
        sp.mkdir()
        (venv / "bin").mkdir(parents=True)
        (venv / "lock.sha256").write_text(_lock_sha() + "\n")
        py = venv / "bin/python"
        py.write_text(f"#!/bin/sh\necho {sp}\n")
        py.chmod(0o755)
        stub = home / "stubbin"
        stub.mkdir()
        (stub / "python3.12").write_text("#!/bin/sh\necho 'stub python3.12: no venv build in this test' >&2\nexit 1\n")
        (stub / "python3.12").chmod(0o755)
        env = {k: v for k, v in os.environ.items() if k != "W23_VENV"}
        env.update(HOME=str(home), PATH=f"{stub}:{env.get('PATH', '/usr/bin:/bin')}", **env_extra)
        p = subprocess.run(["bash", str(HERE / "venv.sh")], env=env, capture_output=True, text=True, timeout=60)
        pth = sp / "ezviz_source.pth"
        return p, py, (pth.read_text() if pth.exists() else None)

    def test_unset_w23_venv_is_per_checkout(self):
        home = fixtures.tmpdir(self)
        h = hashlib.sha256(str(_path.REPO).encode()).hexdigest()[:12]
        p, py, pth = self._run(home, home / ".cache/frigate-w23" / f"venv-{h}")
        self.assertEqual((p.returncode, p.stdout, p.stderr), (0, f"{py}\n", ""))
        self.assertEqual(pth, f"{_path.PKG}\n")

    def test_a_callers_w23_venv_is_kept(self):
        home = fixtures.tmpdir(self)
        own = home / "own"
        p, py, pth = self._run(home, own, W23_VENV=str(own))
        self.assertEqual((p.returncode, p.stdout, p.stderr), (0, f"{py}\n", ""))
        self.assertEqual(pth, f"{_path.PKG}\n")


class TestChildCheckout(unittest.TestCase):
    def test_this_python_imports_this_checkout(self):
        self.assertEqual(_path.check_isolated_import(sys.executable), "")

    def test_isolated_child_writes_no_bytecode(self):
        """N4 (fix wave 1): venv.sh's second .pth turns bytecode writing off, and `-I` (which ignores
        PYTHONDONTWRITEBYTECODE) still reads it, so no child of the tests leaves a __pycache__ in the tree."""
        p = subprocess.run([_path.isolated_python(), "-I", "-c", "import sys; print(sys.dont_write_bytecode)"],
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
        self.assertEqual((p.returncode, p.stdout.strip()), (0, "True"))

    def _scratch_venv(self) -> tuple:
        d = fixtures.tmpdir(self)
        subprocess.run([sys.executable, "-m", "venv", "--without-pip", str(d / "v")], check=True, timeout=120,
                       stdin=subprocess.DEVNULL, capture_output=True)
        vpy = d / "v/bin/python"
        sp = subprocess.run([str(vpy), "-I", "-c", "import sysconfig; print(sysconfig.get_paths()['purelib'])"],
                            check=True, capture_output=True, text=True, timeout=60).stdout.strip()
        return d, vpy, Path(sp)

    def test_a_pth_naming_another_checkout_is_named(self):
        d, vpy, sp = self._scratch_venv()
        other = d / "other/spike/ezviz"
        shutil.copytree(_path.PKG / "ezviz_source", other / "ezviz_source",
                        ignore=shutil.ignore_patterns("__pycache__"))
        (sp / "ezviz_source.pth").write_text(f"{other}\n")
        msg = _path.check_isolated_import(str(vpy))
        self.assertIn(f"expected checkout {_path.REPO}", msg)
        self.assertIn(f"actual checkout {d / 'other'}", msg)
        self.assertIn("W23_VENV", msg)

    def test_no_ezviz_source_at_all_is_named(self):
        _, vpy, _ = self._scratch_venv()
        msg = _path.check_isolated_import(str(vpy))
        self.assertIn("cannot import ezviz_source", msg)
        self.assertIn(f"expected checkout {_path.REPO}", msg)

    def test_checked_once_per_process_and_fails_hard(self):
        with mock.patch.object(_path, "_checked", None), \
                mock.patch.object(_path, "check_isolated_import", return_value="MISMATCH-TEXT") as c:
            for _ in range(3):
                with self.assertRaises(AssertionError) as cm:
                    _path.isolated_python()
                self.assertIn("MISMATCH-TEXT", str(cm.exception))
            self.assertEqual(c.call_count, 1)
        with mock.patch.object(_path, "_checked", None), \
                mock.patch.object(_path, "check_isolated_import", return_value="") as c:
            self.assertEqual((_path.isolated_python(), _path.isolated_python()), (sys.executable, sys.executable))
            self.assertEqual(c.call_count, 1)

    def test_every_isolated_child_goes_through_the_guard(self):
        """No test module launches `sys.executable -I` directly (the fake ffmpeg script included)."""
        bad = []
        for f in sorted(HERE.glob("*.py")):
            if f.name in ("_path.py", "test_checkout.py"):
                continue
            s = f.read_text()
            if (re.search(r'sys\.executable\s*,\s*(\*\w+\s*,\s*)?"-I"', s)
                    or re.search(r'exec %s -I.*\n.*sys\.executable', s)):
                bad.append(f.name)
        self.assertEqual(bad, [])
        self.assertGreaterEqual(sum(f.read_text().count("_path.isolated_python()") for f in HERE.glob("*.py")), 9)


if __name__ == "__main__":
    unittest.main()
