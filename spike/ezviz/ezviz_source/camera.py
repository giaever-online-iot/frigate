"""The library boundary (W-23 T9, plan P1/P2/P3/P5, N8). The only module that imports pyEzvizApi.

Library references are pyezvizapi/streaming/local/... at 2.0.0:
- P1 entry: session.py L1728-1753 (open_hcnetsdk_command_port_generated_multi_socket_stream);
- P2 factory order: generated start() L1525-1578 (login socket via _login_client L1503-1514, closed by `with`
  at L1543-1552, then the plan's sockets via _new_client L1005-1017 from multi-socket start() L1254-1337);
  the keepalive thread starts only after the plan has run (_start_keepalives L1090-1164, called at L1317);
- P3 sites: login failure hcnetsdk/discovery.py L432-436; _recv_exact timeout/close hcnetsdk/requests.py
  L2350-2366; step wrapping session.py L1046-1082; media read wrapping session.py L1435-1444;
- P5: built-in plan session.py L397-503; frames rendered up front session.py L282-319 / L375-394.
"""
import dataclasses
import logging
import socket
import time
from typing import Callable, Iterator

from pyezvizapi.exceptions import DeviceException, EzvizLocalSdkStreamClosed, PyEzvizError
from pyezvizapi.streaming.local.hcnetsdk.protocol_types.endpoints import HcNetSdkLanEndpoint
from pyezvizapi.streaming.local.hcnetsdk.protocol_types.framing import HcNetSdkCommandPortControlTemplate
from pyezvizapi.streaming.local.session import (
    hcnetsdk_command_port_native_lan_live_view_plan,
    open_hcnetsdk_command_port_generated_multi_socket_stream,
)

from .camfile import Camera

LOGIN_FAILED = "HCNetSDK command-port login failed"     # hcnetsdk/discovery.py L436
KEEPALIVE_CMD = 0x30006
_BASE_DELTAS = (10, 16, 22, 28, 34, 40)                   # session.py L493


def silence_library_logging() -> None:
    """N8: nothing the library logs reaches stderr (or the journal). Idempotent."""
    lg = logging.getLogger("pyezvizapi")
    if not any(isinstance(h, logging.NullHandler) for h in lg.handlers):
        lg.addHandler(logging.NullHandler())
    lg.propagate = False


def build_plan(form: str, count: int):
    """P5: the built-in plan with the media step's keepalive list replaced by `count` 0x30006 templates."""
    if form not in ("extend", "repeat"):
        raise ValueError("keepalive form must be 'extend' or 'repeat'")
    if not isinstance(count, int) or count < len(_BASE_DELTAS):
        raise ValueError("keepalive count must be >= 6")
    if form == "extend":
        deltas = [10 + 6 * i for i in range(count)]
    else:
        deltas = list(_BASE_DELTAS) + [40] * (count - len(_BASE_DELTAS))
    kas = tuple(HcNetSdkCommandPortControlTemplate(command_id=KEEPALIVE_CMD, addend_delta=d) for d in deltas)
    base = hcnetsdk_command_port_native_lan_live_view_plan()
    steps = tuple(dataclasses.replace(s, keepalive_templates=kas) if s.media_socket else s for s in base.steps)
    return dataclasses.replace(base, steps=steps)


def render_seconds(plan) -> float:
    """Wall time of the render the library does in start() after login (every frame, keepalives included)."""
    t0 = time.perf_counter()
    plan.to_socket_plan(session_id=b"\x12\x34\x56\x78", auth_seed=0x5A5A5A5A, key=bytes(range(32)),
                        local_ip="127.0.0.1")
    return time.perf_counter() - t0


class CameraSession:
    """One login and one plan run against one camera. Not reusable."""

    def __init__(self, cam: Camera, *, plan, timeout: float, on_login_ok: Callable[[], None]):
        self.logged_in = False
        self._on_login_ok = on_login_ok
        self._factory_calls = 0
        endpoint = HcNetSdkLanEndpoint(serial=cam.serial, host=cam.host, command_port=cam.port)
        self._stream = open_hcnetsdk_command_port_generated_multi_socket_stream(
            endpoint, plan, password=cam.login, username="admin", timeout=timeout, socket_factory=self._factory)

    def _factory(self, address, timeout):
        # P2: call 1 is the login socket; call 2 is the plan's first socket, made only after login returned and
        # the login socket was closed. login_ok goes out here, on the main thread, before that connect.
        self._factory_calls += 1
        if self._factory_calls == 2 and self._stream.login_session is not None and not self.logged_in:
            self.logged_in = True
            self._on_login_ok()
        return socket.create_connection(address, timeout)

    def __enter__(self) -> "CameraSession":
        try:
            self._stream.prepare_startup()      # the RSA key, as iter_packets() would do (session.py L1593)
            self._stream.start()                # login + plan + first media (P1)
        except BaseException:
            self.__exit__(None, None, None)
            raise
        return self

    def packets(self) -> Iterator[bytes]:
        for pkt in self._stream.iter_packets():
            yield pkt.body

    def keepalive_failed(self) -> bool:
        # E8/E14. N5: the property copies the whole event tuple; once a second that is cheap.
        return any(not e.sent for e in self._stream.keepalive_events)

    def __exit__(self, *exc) -> None:
        # R2-N2: one __exit__. Idempotent (Task 11's finish() calls it again) and never raises.
        try:
            self._stream.close()
        except Exception:  # noqa: BLE001 - closing must not mask the end reason
            pass


def _chain(exc: BaseException):
    seen = set()
    while exc is not None and id(exc) not in seen:
        seen.add(id(exc))
        yield exc
        exc = exc.__cause__ or exc.__context__


def classify(exc: BaseException, *, logged_in: bool) -> str:
    """P3: map a library failure to an end event."""
    if not logged_in:
        if isinstance(exc, PyEzvizError) and str(exc) == LOGIN_FAILED:
            return "auth_fail"          # E2: a wrong code and a lockout read the same; latching is right
        return "net_fail"               # E3
    if any(isinstance(e, (DeviceException, EzvizLocalSdkStreamClosed, OSError)) for e in _chain(exc)):
        return "session_end"            # E8/E14
    return "protocol_fail"              # E10/E16
