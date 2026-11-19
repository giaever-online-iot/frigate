"""TIMESTAMP_MODE "rtp" (W-23 T21, spec §4.4 (a)): the access units go to ffmpeg as MPEG-TS whose PES PTS is the camera's
RTP timestamp (90 kHz), so recordings carry the camera's own clock. Stdlib only. Video only (OD4): one HEVC stream.

RtpClock turns the 32-bit RTP timestamps into one monotonic 90 kHz counter:
- the first timestamp is the start, so a session's PTS equal its RTP timestamps until the first 32-bit wrap;
- a step of 1 .. MAX_STEP ticks (MAX_STEP = SOCKET_TIMEOUT_S: a longer silence ends the session) is taken as it is,
  across the 32-bit wrap too (the RTP base is random, and the wrap comes within 13.25 h);
- anything else (no step, a step back, or a jump forward past MAX_STEP: the camera restarted its timestamp base) is
  a re-base with continuity: the counter advances by the last good step, and later steps count from the new base.
  So no PTS ever goes back or repeats, and a re-based session keeps a regular cadence (`rebases` counts them).
The PES carries the counter modulo 2**33, MPEG-TS's own PTS wrap, which demuxers handle.

TsMuxer writes one PES per access unit on VIDEO_PID (PTS only: the cameras do not reorder, RTP steps are constant),
with an AUD in front unless the unit starts with one, a PCR equal to the PTS on its first packet, the random access
indicator on IDRs, and PAT + PMT in front of every IDR (a consumer can start there).
"""
from .constants import SOCKET_TIMEOUT_S

RTP_HZ = 90000
MAX_STEP = int(SOCKET_TIMEOUT_S * RTP_HZ)
DEFAULT_STEP = RTP_HZ // 25                 # until the first good step: 25 fps
PMT_PID = 0x1000
VIDEO_PID = 0x0100
STREAM_TYPE_HEVC = 0x24
AUD = b"\x00\x00\x00\x01\x46\x01\x50"      # HEVC access unit delimiter (type 35), pic_type 2
_WRAP32 = 1 << 32
_MASK33 = (1 << 33) - 1


def _crc_table():
    t = []
    for i in range(256):
        c = i << 24
        for _ in range(8):
            c = ((c << 1) ^ 0x04C11DB7) if c & 0x80000000 else (c << 1)
        t.append(c & 0xFFFFFFFF)
    return t


_CRC = _crc_table()


def crc32_mpeg2(data: bytes) -> int:
    c = 0xFFFFFFFF
    for b in data:
        c = ((c << 8) & 0xFFFFFFFF) ^ _CRC[((c >> 24) ^ b) & 0xFF]
    return c


class RtpClock:
    def __init__(self):
        self._last = None
        self._ext = 0
        self._step = DEFAULT_STEP
        self.rebases = 0

    def pts(self, rtp_ts: int) -> int:
        rtp_ts &= _WRAP32 - 1
        if self._last is None:
            self._ext = rtp_ts
        else:
            d = (rtp_ts - self._last) % _WRAP32
            if 0 < d <= MAX_STEP:
                self._step = d
                self._ext += d
            else:
                self._ext += self._step
                self.rebases += 1
        self._last = rtp_ts
        return self._ext


def _section(table_id: int, ext_id: int, body: bytes) -> bytes:
    n = 5 + len(body) + 4
    head = bytes([table_id, 0xB0 | (n >> 8), n & 0xFF, ext_id >> 8, ext_id & 0xFF, 0xC1, 0x00, 0x00])
    s = head + body
    return s + crc32_mpeg2(s).to_bytes(4, "big")


PAT = _section(0x00, 1, bytes([0x00, 0x01, 0xE0 | (PMT_PID >> 8), PMT_PID & 0xFF]))
PMT = _section(0x02, 1, bytes([0xE0 | (VIDEO_PID >> 8), VIDEO_PID & 0xFF, 0xF0, 0x00,
                               STREAM_TYPE_HEVC, 0xE0 | (VIDEO_PID >> 8), VIDEO_PID & 0xFF, 0xF0, 0x00]))


def _pts_bytes(pts: int) -> bytes:
    p = pts & _MASK33
    return bytes([0x20 | ((p >> 29) & 0x0E) | 1, (p >> 22) & 0xFF, ((p >> 14) & 0xFE) | 1, (p >> 7) & 0xFF,
                  ((p << 1) & 0xFE) | 1])


def _pcr_bytes(pts: int) -> bytes:
    b = pts & _MASK33
    return bytes([(b >> 25) & 0xFF, (b >> 17) & 0xFF, (b >> 9) & 0xFF, (b >> 1) & 0xFF, ((b & 1) << 7) | 0x7E, 0x00])


def _starts_with_aud(au: bytes) -> bool:
    off = 4 if au.startswith(b"\x00\x00\x00\x01") else 3 if au.startswith(b"\x00\x00\x01") else None
    return off is not None and len(au) > off and (au[off] >> 1) & 0x3F == 35


class TsMuxer:
    def __init__(self):
        self._cc = {}

    def _head(self, pid: int, pusi: bool, afc: int) -> bytes:
        cc = self._cc.get(pid, 0)
        self._cc[pid] = (cc + 1) & 0x0F
        return bytes([0x47, (0x40 if pusi else 0) | (pid >> 8), pid & 0xFF, (afc << 4) | cc])

    def _psi(self, pid: int, sec: bytes) -> bytes:
        pl = b"\x00" + sec
        return self._head(pid, True, 1) + pl + b"\xFF" * (184 - len(pl))

    def mux(self, au: bytes, pts: int, is_idr: bool) -> bytes:
        out = bytearray()
        if is_idr:
            out += self._psi(0, PAT) + self._psi(PMT_PID, PMT)
        es = au if _starts_with_aud(au) else AUD + au
        pes = b"\x00\x00\x01\xE0\x00\x00\x84\x80\x05" + _pts_bytes(pts) + es
        pos, first = 0, True
        while pos < len(pes):
            if first:
                fields = bytes([0x10 | (0x40 if is_idr else 0)]) + _pcr_bytes(pts)   # PCR (+ random access)
            else:
                fields = b""
            room = 184 - (1 + len(fields) if fields else 0)
            rest = len(pes) - pos
            if rest >= room:
                take = room
                af = bytes([len(fields)]) + fields if fields else b""
            else:
                take = rest
                af_len = 183 - take                           # 1 length byte + af_len bytes + payload = 184
                if af_len == 0:
                    af = b"\x00"
                else:
                    body = fields if fields else b"\x00"      # an AF of length >= 1 starts with its flags byte
                    af = bytes([af_len]) + body + b"\xFF" * (af_len - len(body))
            out += self._head(VIDEO_PID, first, 3 if af else 1) + af + pes[pos:pos + take]
            pos += take
            first = False
        return bytes(out)
