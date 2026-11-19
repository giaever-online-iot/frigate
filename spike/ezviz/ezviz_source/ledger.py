"""The per-camera ledger (spec §4.3, D18, D21; plan P8, SF12). Stdlib only.

One JSON object per line: {"t": epoch, "ev": str, "dur": float|None} plus "syn": true on synthetic records.
A torn LAST line is skipped; any other bad line raises LedgerDamaged (P8). The ledger lock is flock on the
ledger file itself (D18); because trim() replaces the file, a locker re-checks after flock that it holds the
inode the path names now, and retries if not (SF12). trim() must be the last operation under a lock.
"""
import fcntl
import json
import os
from pathlib import Path

from . import constants as C
from . import signals


class LedgerDamaged(Exception):
    pass


class LedgerIOError(Exception):
    pass


def _valid(rec) -> bool:
    t = rec.get("t") if isinstance(rec, dict) else None
    return (isinstance(t, (int, float)) and not isinstance(t, bool)
            and isinstance(rec.get("ev"), str))


def parse(data: bytes) -> list:
    lines = data.split(b"\n")
    tail = lines.pop()                       # bytes after the last newline: a torn line if not empty
    out = []
    for i, line in enumerate(lines):
        try:
            rec = json.loads(line)
        except ValueError:
            rec = None
        if not _valid(rec):
            if i == len(lines) - 1 and tail == b"":
                continue                     # the last line, newline-terminated but bad: torn
            raise LedgerDamaged()
        out.append(rec)
    return out                               # a non-empty tail has no newline: torn, skipped


def _accepted_end(data: bytes) -> int:
    """Offset just past the last line parse() would accept: a torn last line is cut whether or not it ends in a newline (C7)."""
    end = data.rfind(b"\n") + 1             # drops a non-empty tail without newline
    if end:
        start = data.rfind(b"\n", 0, end - 1) + 1
        try:
            rec = json.loads(data[start:end])
        except ValueError:
            rec = None
        if not _valid(rec):
            return start                     # newline-terminated but bad: torn too
    return end


def _fsync_dir(d: Path) -> None:
    fd = os.open(d, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


class Ledger:
    """Context manager: holds flock(LOCK_EX) on the ledger file for its whole body."""

    def __init__(self, path):
        self.path = Path(path)
        self._fd = None

    def __enter__(self):
        try:
            while True:
                fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
                fcntl.flock(fd, fcntl.LOCK_EX)
                held = os.fstat(fd)
                try:
                    now = os.stat(self.path, follow_symlinks=False)
                except FileNotFoundError:
                    now = None
                if now is not None and (held.st_ino, held.st_dev) == (now.st_ino, now.st_dev):
                    self._fd = fd
                    return self
                os.close(fd)                 # trim() replaced the file while we waited: lock the new one
        except OSError as e:
            raise LedgerIOError(type(e).__name__) from None

    def __exit__(self, *exc):
        if self._fd is not None:
            os.close(self._fd)
            self._fd = None
        return False

    def _read(self) -> bytes:
        os.lseek(self._fd, 0, os.SEEK_SET)
        chunks = []
        while True:
            b = os.read(self._fd, 65536)
            if not b:
                return b"".join(chunks)
            chunks.append(b)

    def records(self) -> list:
        try:
            return parse(self._read())
        except OSError as e:
            raise LedgerIOError(type(e).__name__) from None

    def append(self, rec: dict) -> None:
        line = (json.dumps(rec, separators=(",", ":")) + "\n").encode()
        try:
            signals.hook("enospc_append")
            data = self._read()
            end = _accepted_end(data)
            if end != len(data):
                os.ftruncate(self._fd, end)  # never join a new record to a torn one, nor bury it mid-file (C7)
            os.lseek(self._fd, 0, os.SEEK_END)
            if signals.hook_active("pause_cs:" + rec["ev"]):    # K1 test: a SIGTERM lands mid-record
                half = len(line) // 2
                os.write(self._fd, line[:half])
                signals.hook("pause_cs:" + rec["ev"])
                line = line[half:]
            if os.write(self._fd, line) != len(line):
                raise OSError("short write")
            os.fsync(self._fd)
            _fsync_dir(self.path.parent)
        except OSError as e:
            raise LedgerIOError(type(e).__name__) from None

    def trim(self, now: float, keep_from: float) -> None:
        recs = self.records()
        keep = [r for r in recs if r["t"] >= now - C.TRIM_KEEP_S or r["t"] >= keep_from]
        if len(keep) == len(recs):
            return
        tmp = self.path.with_name(self.path.name + ".tmp")
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
            try:
                os.write(fd, b"".join((json.dumps(r, separators=(",", ":")) + "\n").encode() for r in keep))
                os.fsync(fd)
            finally:
                os.close(fd)
            os.replace(tmp, self.path)
            _fsync_dir(self.path.parent)
        except OSError as e:
            raise LedgerIOError(type(e).__name__) from None
