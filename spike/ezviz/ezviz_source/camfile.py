"""Camera file reader (spec D7, §6.1, G3). Stdlib only. Never prints or embeds a value in an error."""
import os
import re
import stat
from dataclasses import dataclass
from pathlib import Path

_KEYS = {"host", "port", "serial", "login"}
_OCTET = r"(0|[1-9][0-9]{0,2})"
_IPV4 = re.compile(rf"^{_OCTET}\.{_OCTET}\.{_OCTET}\.{_OCTET}$")
_SERIAL = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
_LOGIN = re.compile(r"^[A-Za-z0-9]{4,32}$")


class CameraFileError(Exception):
    def __init__(self, cls: str):
        super().__init__(cls)
        self.cls = cls


@dataclass(frozen=True, repr=False)
class Camera:
    name: str
    host: str
    port: int
    serial: str
    login: str

    def __repr__(self) -> str:
        return f"Camera({self.name})"


_MAX = 4096                                    # bytes; a longer camera file is refused as shape


def load(name: str, directory: Path) -> Camera:
    """The caller validates `name` against constants.NAME_RE first (main, check; gate via main and the probe)."""
    try:
        # O_NONBLOCK: a FIFO at the path must not block the open waiting for a writer (it is refused below)
        fd = os.open(Path(directory) / f"{name}.conf", os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    except OSError:
        raise CameraFileError("missing") from None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise CameraFileError("missing")
        if st.st_uid != os.geteuid():
            raise CameraFileError("owner")
        if stat.S_IMODE(st.st_mode) != 0o600:
            raise CameraFileError("mode")
        raw = os.read(fd, _MAX + 1)
    except OSError:
        # fstat or read failed on a file that opened: as unusable as one that cannot be opened -> missing
        raise CameraFileError("missing") from None
    finally:
        os.close(fd)
    if len(raw) > _MAX:
        raise CameraFileError("shape")
    vals = {}
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError:
        raise CameraFileError("shape") from None
    for line in text.replace("\r\n", "\n").split("\n"):
        if not line.strip() or line.startswith("#"):
            continue
        k, sep, v = line.partition("=")
        if not sep or k not in _KEYS or k in vals:
            raise CameraFileError("shape")
        vals[k] = v
    if set(vals) != _KEYS:
        raise CameraFileError("shape")
    m = _IPV4.match(vals["host"])
    if not m or any(int(o) > 255 for o in m.groups()):
        raise CameraFileError("shape")
    if not vals["port"].isdigit() or not 1 <= int(vals["port"]) <= 65535:
        raise CameraFileError("shape")
    if not _SERIAL.match(vals["serial"]) or not _LOGIN.match(vals["login"]):
        raise CameraFileError("shape")
    return Camera(name, vals["host"], int(vals["port"]), vals["serial"], vals["login"])
