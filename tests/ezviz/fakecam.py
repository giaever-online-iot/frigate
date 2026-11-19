"""Loopback fake EZVIZ camera for the W-23 tests (T8): the HCNetSDK port-8000 RSA login, the built-in 10-socket
plan and a paced `$`-framed IDMX/RTP/FU H.265 stream, as seen from pyEzvizApi 2.0.0's client.

Self-contained (stdlib + pycryptodome) so it also runs as `python3.12 -I fakecam.py` with the snap's interpreter.
Library references are pyezvizapi/streaming/local/{session.py, hcnetsdk/...} at 2.0.0:
- frames: 16-byte header, u32 BE total length (header included) + three u32 BE fields
  (hcnetsdk/protocol_types/framing.py L126-155, L286-300; reader hcnetsdk/requests.py L623-648);
- login frame A / B: hcnetsdk/authentication.py L172-189 / L192-256 (prefix L334-339, username requests.py L2343-2347,
  PKCS#1 DER requests.py L706-711), client hcnetsdk/api.py L4425-4493, R2 parse hcnetsdk/discovery.py L423-445;
  NB the login prefix is 20 bytes (8 + IPv4 word + 8), not 16;
- control frames 0x63: framing.py L303-336; plan session.py L397-503; executor session.py L1019-1088 (one response per
  non-media frame), start() L1254-1337 (media socket kept), keepalives L1090-1164 (first after 5 s, then every 5 s);
- media framing: hcnetsdk/requests.py L1689-1725 (`$`, channel, u16 LE total length incl. the 4-byte header).
"""
import argparse
import hashlib
import hmac
import json
import os
import signal
import socket
import sys
import threading
import time
from pathlib import Path

from Crypto.Cipher import PKCS1_v1_5
from Crypto.PublicKey import RSA
from Crypto.Util.asn1 import DerSequence

LOGIN_FAMILY = 0x5A000000          # hcnetsdk/api.py L502
CONTROL_FAMILY = 0x63000000        # hcnetsdk/constants.py L208 (1660944384)
CMD_MEDIA, CMD_KEEPALIVE = 0x30000, 0x30006
PREFIX_LEN, USER_LEN = 20, 48      # 8+4+8: authentication.py L334-339, api.py L504-506, wire_crypto.py L157-161
SERIAL = b"TESTCAM-0001"           # made-up; R2 body[4:48] (discovery.py L441)
SSRC = b"\x55\x66\x77\x88"
MAX_RTP_PAYLOAD = 1400
TS_STEP = 3600                     # 90 kHz / 25 fps
MAX_FRAME = 1 << 20


# ---------------------------------------------------------------- the clip
def split_nals(es: bytes) -> list:
    """Annex-B -> NALs (no start codes)."""
    nals, i = [], es.find(b"\x00\x00\x01")
    while i >= 0:
        j = es.find(b"\x00\x00\x01", i + 3)
        nal = es[i + 3:len(es) if j < 0 else j].rstrip(b"\x00")
        if nal:
            nals.append(nal)
        i = j
    return nals


def access_units(nals: list) -> list:
    """NALs -> AUs: a new AU at VPS/SPS/PPS/AUD/prefix-SEI or a first-slice VCL NAL after a VCL NAL."""
    aus, cur, has_vcl = [], [], False
    for nal in nals:
        t = (nal[0] >> 1) & 0x3F
        vcl = t < 32
        first = vcl and len(nal) >= 3 and bool(nal[2] & 0x80)
        if has_vcl and (t in (32, 33, 34, 35, 39) or first):
            aus.append(cur)
            cur, has_vcl = [], False
        cur.append(nal)
        has_vcl = has_vcl or vcl
    if cur:
        aus.append(cur)
    return aus


def rtp_payloads(nal: bytes, max_payload: int = MAX_RTP_PAYLOAD) -> list:
    """One payload if the NAL fits, else RFC 7798 FUs (type 49) of at most `max_payload` bytes each."""
    if len(nal) <= max_payload:
        return [nal]
    ind = bytes([(nal[0] & 0x81) | (49 << 1), nal[1]])
    t, rest, size = (nal[0] >> 1) & 0x3F, nal[2:], max_payload - 3
    chunks = [rest[k:k + size] for k in range(0, len(rest), size)]
    return [ind + bytes([t | (0x80 if n == 0 else 0) | (0x40 if n == len(chunks) - 1 else 0)]) + c
            for n, c in enumerate(chunks)]


def descriptor_ext(stream_type: int, pt: int = 96) -> bytes:
    """An RTP header extension carrying one 0x45 stream descriptor (stream type, payload type), as
    pyezvizapi/streaming/media/rtp.py idmx_rtp_stream_descriptors reads it; padded to whole 32-bit words."""
    tlv = bytes([0x45, 2, stream_type & 0xFF, pt & 0x7F])
    tlv += b"\x00" * (-len(tlv) % 4)
    return b"\xbe\xde" + (len(tlv) // 4).to_bytes(2, "big") + tlv


# --real-shape (GA A1 diagnosis): the real camera's stream as the counters-only diagnostic saw it. Before each keyframe
# two PT-112 packets with an empty payload: TLVs 0x40, 0x45, 0x41 (body 64 bytes; the 0x45 announces hevc, stream type
# 0x24, on PT 15, which never carries a packet) and TLVs 0x42, 0x43 (body 44 bytes); the video as plain RFC 7798 HEVC on
# PT 96 (VPS, SPS, PPS, SEI, then FU bodies of 1152 bytes); one audio-like PT 104 packet per picture.
REAL_FU_PAYLOAD = 1152 - 4 - 12           # body = 4-byte prefix + 12-byte RTP header + payload
REAL_DESC_A = bytes([0x40, 18]) + bytes(18) + bytes([0x45, 2, 0x24, 15]) + bytes([0x41, 18]) + bytes(18)
REAL_DESC_B = bytes([0x42, 14]) + bytes(14) + bytes([0x43, 6]) + bytes(6)


def tlv_ext(tlvs: bytes) -> bytes:
    tlvs += b"\x00" * (-len(tlvs) % 4)
    return b"\xbe\xde" + (len(tlvs) // 4).to_bytes(2, "big") + tlvs


def media_frame(seq: int, ts: int, marker: bool, payload: bytes, ext: bytes = b"", pt: int = 96) -> bytes:
    rtp = bytes([0x90 if ext else 0x80, (0x80 if marker else 0) | pt]) + (seq & 0xFFFF).to_bytes(2, "big") \
        + (ts & 0xFFFFFFFF).to_bytes(4, "big") + SSRC + ext + payload
    idmx = len(rtp).to_bytes(4, "little") + rtp
    return b"$\x00" + (4 + len(idmx)).to_bytes(2, "little") + idmx


# ---------------------------------------------------------------- wire helpers
def frame(body: bytes = b"", field_4: int = 0, field_8: int = 0, field_12: int = 0) -> bytes:
    return b"".join(v.to_bytes(4, "big") for v in (16 + len(body), field_4, field_8, field_12)) + body


def recv_exact(sock, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return bytes(buf)


def read_frame(sock):
    hdr = recv_exact(sock, 16)
    total = int.from_bytes(hdr[:4], "big")
    if not 16 <= total <= MAX_FRAME:
        raise EOFError
    fields = [int.from_bytes(hdr[k:k + 4], "big") for k in (4, 8, 12)]
    return fields, recv_exact(sock, total - 16)


def md5_hmac(key: bytes, msg: bytes) -> bytes:
    return hmac.new(key, msg, hashlib.md5).digest()


def attempt_on_disk(path) -> bool:
    try:
        data = Path(path).read_bytes()
    except OSError:
        return False
    for line in data.split(b"\n")[:-1]:            # only newline-terminated lines are complete
        try:
            if json.loads(line).get("ev") == "attempt":
                return True
        except (ValueError, AttributeError):
            pass
    return False


# ---------------------------------------------------------------- the server
class Server:
    def __init__(self, code: str, es, *, port: int = 0, stats_path=None, reject: bool = False,
                 silent_before_challenge: bool = False, silent_after_login: bool = False, close_after_s=None,
                 stall_after_s=None, no_media: bool = False, ledger_at_accept=None, fps: float = 25.0,
                 desc_stream_type=None, real_shape: bool = False):
        self.code = code.encode()
        self.aus = access_units(split_nals(Path(es).read_bytes()))
        if not self.aus:
            raise ValueError("no NAL units in the clip")
        self.stats_path = Path(stats_path) if stats_path else None
        self.reject, self.no_media = reject, no_media
        self.silent_before_challenge, self.silent_after_login = silent_before_challenge, silent_after_login
        self.close_after_s, self.stall_after_s = close_after_s, stall_after_s
        self.ledger_at_accept, self.fps = ledger_at_accept, fps
        self.desc_stream_type = desc_stream_type      # None: no 0x45 descriptors (the legacy PT 96 route)
        self.real_shape = real_shape
        self._stats = {"connects": 0, "logins_ok": 0, "logins_rejected": 0, "keepalives": 0, "media_sessions": 0,
                       "attempt_on_disk_at_accept": []}
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._sessions = set()
        self._socks, self._threads = set(), []
        self._lsock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._lsock.bind(("127.0.0.1", port))
        self._lsock.listen(32)
        self._lsock.settimeout(0.1)
        self.port = self._lsock.getsockname()[1]
        self._write_stats()
        self._spawn(self._accept_loop)

    @property
    def stats(self) -> dict:
        with self._lock:
            return json.loads(json.dumps(self._stats))

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def close(self) -> None:
        self._stop.set()
        with self._lock:
            socks = list(self._socks)
        for s in socks:
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        for t in list(self._threads):
            if t is not threading.current_thread():
                t.join(timeout=5)
        try:
            self._lsock.close()
        except OSError:
            pass

    # -- bookkeeping
    def _spawn(self, fn, *args) -> None:
        t = threading.Thread(target=fn, args=args, daemon=True)
        with self._lock:
            if self._stop.is_set():
                return
            self._threads = [x for x in self._threads if x.is_alive()] + [t]
        t.start()

    def _event(self, key: str, attempt=None) -> None:
        with self._lock:
            self._stats[key] += 1
            if attempt is not None:
                self._stats["attempt_on_disk_at_accept"].append(attempt)
            self._write_stats_locked()

    def _write_stats(self) -> None:
        with self._lock:
            self._write_stats_locked()

    def _write_stats_locked(self) -> None:
        if self.stats_path is None:
            return
        tmp = self.stats_path.with_name(self.stats_path.name + ".tmp")
        tmp.write_text(json.dumps(self._stats))
        os.replace(tmp, self.stats_path)

    # -- connections
    def _accept_loop(self) -> None:
        while not self._stop.is_set():
            try:
                sock, _ = self._lsock.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            # C2: look at the ledger right after accept() returns, before the connection thread exists or a byte is
            # read, so an attempt written after the client connected cannot count as present at accept
            seen = attempt_on_disk(self.ledger_at_accept) if self.ledger_at_accept else None
            sock.settimeout(None)
            with self._lock:
                self._socks.add(sock)
            self._spawn(self._conn, sock, seen)

    def _conn(self, sock, seen) -> None:
        try:
            self._event("connects", attempt=seen)
            fields, body = read_frame(sock)
            if fields[0] == LOGIN_FAMILY:
                self._login(sock, body)
            elif fields[0] == CONTROL_FAMILY:
                self._control(sock, fields, body)
        except (EOFError, OSError, ValueError):
            pass
        finally:
            with self._lock:
                self._socks.discard(sock)
            try:
                sock.close()
            except OSError:
                pass

    def _hold(self, sock) -> None:
        """Say nothing; keep the connection until the client or close() ends it."""
        while not self._stop.is_set() and sock.recv(4096):
            pass

    def _login(self, sock, body_a: bytes) -> None:
        user = body_a[PREFIX_LEN:PREFIX_LEN + USER_LEN].rstrip(b"\x00")
        n_e = DerSequence().decode(body_a[PREFIX_LEN + USER_LEN:])    # PKCS#1 RSAPublicKey (requests.py L706-711)
        pub = RSA.construct((int(n_e[0]), int(n_e[1])))
        if self.silent_before_challenge:
            return self._hold(sock)
        challenge = os.urandom(32)
        while challenge[-1] == 0:                    # the client strips trailing NULs (authentication.py L222)
            challenge = os.urandom(32)
        seed = os.urandom(64)
        sock.sendall(frame(PKCS1_v1_5.new(pub).encrypt(challenge) + seed))
        _, body_b = read_frame(sock)
        digest = hashlib.sha256(user + seed + self.code).hexdigest().encode()
        p = PREFIX_LEN                               # B = prefix + user HMAC (NUL-padded to 32) + 16-byte code proof
        ok = (len(body_b) >= p + 48
              and hmac.compare_digest(body_b[p:p + 16], md5_hmac(challenge, user))
              and hmac.compare_digest(body_b[p + 32:p + 48], md5_hmac(challenge, digest)[:16]))
        if ok and not self.reject:
            sid = b"\x00\x00\x00\x00"
            while sid == b"\x00\x00\x00\x00":
                sid = os.urandom(4)
            with self._lock:
                self._sessions.add(sid)
            self._event("logins_ok")                 # counted before R2 leaves, so a caller sees it on return
            auth_seed = int.from_bytes(os.urandom(4), "big")
        else:
            sid, auth_seed = b"\x00\x00\x00\x00", 0
            self._event("logins_rejected")
        sock.sendall(frame(sid + SERIAL.ljust(44, b"\x00"), field_4=auth_seed))

    def _control(self, sock, fields, body) -> None:
        while True:
            with self._lock:
                known = body[4:8] in self._sessions
            if fields[0] != CONTROL_FAMILY or not known:
                return
            if self.silent_after_login:
                return self._hold(sock)
            if fields[2] == CMD_MEDIA:
                return self._media(sock)
            sock.sendall(frame())                    # a bare 16-byte header
            fields, body = read_frame(sock)

    def _media(self, sock) -> None:
        self._event("media_sessions")
        if not self.no_media:
            self._spawn(self._send_media, sock)
        while not self._stop.is_set():
            fields, _ = read_frame(sock)
            if fields[2] == CMD_KEEPALIVE:
                self._event("keepalives")

    def _send_media(self, sock) -> None:
        t0, seq, k = time.monotonic(), 0, 0
        try:
            while not self._stop.is_set():
                elapsed = time.monotonic() - t0
                if self.close_after_s is not None and elapsed >= self.close_after_s:
                    sock.shutdown(socket.SHUT_RDWR)
                    return
                if self.stall_after_s is not None and elapsed >= self.stall_after_s:
                    return                           # silent, socket left open
                if self.real_shape:
                    out, seq = self._real_shape_picture(k, seq)
                    sock.sendall(out)
                    k += 1
                    self._stop.wait(max(0.0, t0 + k / self.fps - time.monotonic()))
                    continue
                pkts = [p for nal in self.aus[k % len(self.aus)] for p in rtp_payloads(nal)]
                ext = descriptor_ext(self.desc_stream_type) if self.desc_stream_type is not None else b""
                out = b"".join(media_frame(seq + n, k * TS_STEP, n == len(pkts) - 1, p, ext if n == 0 else b"")
                               for n, p in enumerate(pkts))
                sock.sendall(out)
                seq, k = seq + len(pkts), k + 1
                self._stop.wait(max(0.0, t0 + k / self.fps - time.monotonic()))
        except OSError:
            pass

    def _real_shape_picture(self, k: int, seq: int):
        au = self.aus[k % len(self.aus)]
        out = b""
        if any((n[0] >> 1) & 0x3F == 32 for n in au):                    # a keyframe: the two PT-112 descriptor packets
            out += media_frame(2 * k, k * TS_STEP, False, b"", tlv_ext(REAL_DESC_A), pt=112)
            out += media_frame(2 * k + 1, k * TS_STEP, False, b"", tlv_ext(REAL_DESC_B), pt=112)
        pkts = [p for nal in au for p in rtp_payloads(nal, REAL_FU_PAYLOAD)]
        out += b"".join(media_frame(seq + n, k * TS_STEP, n == len(pkts) - 1, p) for n, p in enumerate(pkts))
        out += media_frame(k, k * 320, True, b"\xd5" * 160, pt=104)        # audio-like, 8 kHz clock
        return out, seq + len(pkts)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--code", required=True)
    ap.add_argument("--stats")
    ap.add_argument("--es", required=True)
    ap.add_argument("--reject", action="store_true")
    ap.add_argument("--silent-before-challenge", action="store_true")
    ap.add_argument("--silent-after-login", action="store_true")
    ap.add_argument("--close-after-s", type=float)
    ap.add_argument("--stall-after-s", type=float)
    ap.add_argument("--no-media", action="store_true")
    ap.add_argument("--port-file")
    ap.add_argument("--ledger-at-accept")
    ap.add_argument("--real-shape", action="store_true",
                    help="the real camera's shape: hevc announced on PT 15 by PT-112 packets, video on PT 96, audio PT 104")
    ap.add_argument("--desc-stream-type", type=lambda v: int(v, 0),
                    help="send a 0x45 descriptor (this stream type, PT 96) on each picture's first packet")
    a = ap.parse_args(argv)
    done = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: done.set())
    srv = Server(a.code, a.es, port=a.port, stats_path=a.stats, reject=a.reject,
                 silent_before_challenge=a.silent_before_challenge, silent_after_login=a.silent_after_login,
                 close_after_s=a.close_after_s, stall_after_s=a.stall_after_s, no_media=a.no_media,
                 ledger_at_accept=a.ledger_at_accept, desc_stream_type=a.desc_stream_type, real_shape=a.real_shape)
    if a.port_file:
        tmp = Path(a.port_file + ".tmp")
        tmp.write_text(f"{srv.port}\n")
        os.replace(tmp, a.port_file)
    while not done.wait(0.5):
        pass
    srv.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
