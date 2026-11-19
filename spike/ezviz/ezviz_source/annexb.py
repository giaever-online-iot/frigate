"""Streaming IDMX/RTP/FU to Annex-B H.265 reassembler and access-unit splitter (W-23 T7). Stdlib only.

Replicates the HEVC branch of pyEzvizApi 2.0.0 with no decrypt step, incrementally. Library references
are pyezvizapi/streaming/{local/packets.py, local/payloads.py, media/rtp.py} at 2.0.0.

Accepted differences from the library (Task 9's byte-for-byte diff must not chase these):
- no EOF flush of an active FU (the library appends it after its loop);
- the 0x45 route map is progressive, the library uses the final map over all packets;
- the PT-96 evidence promotion (payloads.py:1125-1157) is decided progressively: PT 96 joins the hevc routes once
  it has shown 2 HEVC evidence frames while no announced video PT has carried a packet, and leaves them for good
  when one does (the library then never promotes). PT-96 bodies wait in a hold of HOLD_MAX until it is decided, and
  come out in order, so the VPS before the second evidence frame is not lost (GA A1 diagnosis: the real camera
  announces hevc on PT 15 and sends it on PT 96). The hold's limits: past HOLD_MAX bodies it drops the OLDEST one
  (the library keeps all; it takes more than 63 non-evidence bodies between the first and the second evidence frame,
  and a keyframe's VPS/SPS/PPS and FU fragments are all evidence), and a later descriptor that assigns 96 to hevc
  clears a pending hold (the library's final map would output those bodies);
- an H.264-only descriptor set (no hevc route) still leaves PT 96 on the legacy HEVC route, and a descriptor that
  changes a PT's codec overwrites the earlier one (the library finds no media then); both pre-date the promotion;
- no conflicting-route checks, no rtp_payload_video_codec != "h264" check, no H.264 promotion;
- no H.264 path;
- no concatenated-frame or nested "00 10" aggregate splitting: one length-prefixed body per push;
- caps: an FU over FU_MAX_BYTES, or a pending AU over AU_MAX_BYTES / AU_MAX_NALS, is dropped;
- an AU is emitted one picture late; flush() returns the pending one at EOF.
"""
from collections import deque

START = b"\x00\x00\x00\x01"
SENTINEL = b"\x55\x66\x77\x88"          # packets.py:42
WRAPPER = b"\x40\x00\x00\x02\x80\x06"   # packets.py:297-300 (_looks_like_idmx_hevc_media_frame)
WRAPPER_NAL_OFFSET = 12                 # packets.py:54
TRAILER_PREFIX = b"\x24\x00"            # packets.py:57
DEFAULT_PT = 96                         # session.py:2635, rtp.py:221-256 (legacy fallback route)
HEVC_STREAM_TYPES = frozenset({0x24, 0xB2})   # rtp.py:88 and :103 (_IDMX_RTP_STREAM_TYPES: both are hevc)
H264_STREAM_TYPES = frozenset({0x1B, 0xB0})   # rtp.py:87 and :101
PROMOTE_EVIDENCE = 2                    # payloads.py:1156 (hevc_evidence >= 2)
HOLD_MAX = 64                           # PT-96 bodies kept while the promotion is undecided
FU = 49
FU_MAX_BYTES = 8 << 20                  # a FU that grows past this is dropped (never-ending FU)
AU_MAX_BYTES = 16 << 20                 # a pending AU past this many bytes or NALs is dropped
AU_MAX_NALS = 1024


def _nal_type(nal: bytes) -> int:
    return (nal[0] >> 1) & 0x3F if nal else 0          # packets.py:431-432


def _plausible(nal: bytes) -> bool:
    # packets.py:352-359 (_is_plausible_hevc_nal)
    return len(nal) >= 2 and not nal[0] & 0x80 and nal[1] & 0x07 != 0 and 0 <= _nal_type(nal) <= 40


def _direct_frame(body: bytes) -> bool:
    # packets.py:~273-278 (_looks_like_idmx_hevc_direct_frame)
    if len(body) < 2 or body[0] & 0x80 or body[1] & 0x07 == 0:
        return False
    t = _nal_type(body)
    return 0 <= t <= 40 or t == FU


def _evidence_frame(body: bytes) -> bool:
    # packets.py:~281-287 (_looks_like_idmx_hevc_evidence_frame): a parameter set on layer 0, or an FU
    if not _direct_frame(body):
        return False
    t = _nal_type(body)
    return body[1] & 0xF8 == 0 if t in (32, 33, 34) else t == FU


def _strip_trailer(body: bytes) -> bytes:
    # packets.py:~317-331 (_strip_idmx_command_h264_record_trailer); only the HEVC-direct guard is kept
    if len(body) <= 4 or not _direct_frame(body):
        return body
    if body[-3:-1] == TRAILER_PREFIX:
        return body[:-3]
    if body[-4:-2] == TRAILER_PREFIX:
        return body[:-4]
    return body


class _Rtp:
    __slots__ = ("payload", "pt", "seq", "ts", "marker", "ext", "has_ext")

    def __init__(self, payload, pt, seq, ts, marker, ext, has_ext):
        self.payload, self.pt, self.seq, self.ts, self.marker, self.ext = payload, pt, seq, ts, marker, ext
        self.has_ext = has_ext          # library's extension_profile is not None (X bit), even if length 0


def _parse_rtp(data: bytes):
    """media/rtp.py:422-472 (parse_rtp_packet): CSRCs, extension, padding. None where the library raises."""
    if len(data) < 12 or data[0] >> 6 != 2:
        return None
    off = 12 + (data[0] & 0x0F) * 4
    if len(data) < off:
        return None
    ext = b""
    if data[0] & 0x10:
        if len(data) < off + 4:
            return None
        start = off + 4
        off = start + int.from_bytes(data[off + 2:off + 4], "big") * 4
        if len(data) < off:
            return None
        ext = data[start:off]
    payload = data[off:]
    if data[0] & 0x20:
        if not payload or payload[-1] == 0 or payload[-1] > len(payload):
            return None
        payload = payload[:-payload[-1]]
    return _Rtp(payload, data[1] & 0x7F, int.from_bytes(data[2:4], "big"),
                int.from_bytes(data[4:8], "big"), bool(data[1] & 0x80), ext, bool(data[0] & 0x10))


def _header_size(frame: bytes):
    # packets.py:225-235 (_idmx_local_frame_header_size): sentinel at offset 8 (12 bytes) or 9 (13 bytes)
    for sentinel_off in (8, 9):
        if len(frame) >= sentinel_off + 4 and frame[sentinel_off:sentinel_off + 4] == SENTINEL:
            return sentinel_off + 4
    return None


def _header_score(frame: bytes, hs):
    # packets.py:238-249 (_idmx_local_frame_header_score)
    if hs is None or len(frame) < hs:
        return None
    if hs == 13 and frame[0] in (0x0D, 0xFA):
        return 0
    if hs == 12 and frame[0] in (0x80, 0x90, 0xA0):
        return 0
    if hs == 13 and frame[1] in (0x80, 0x90, 0xA0):
        return 1
    return None


def _frame_of(body: bytes):
    """payloads.py:568-586 (_iter_idmx_local_packet_frame): 4-byte LE length prefix, else the body is the frame."""
    frame = body
    if len(body) >= 4:
        n = int.from_bytes(body[:4], "little")
        inner = body[4:4 + n]
        if n == len(body) - 4 and _header_score(inner, _header_size(inner)) is not None:
            frame = inner
    hs = _header_size(frame)
    if _header_score(frame, hs) is None:
        return None
    return frame, hs


def _rtp_of(frame: bytes):
    """packets.py:139-159 (_idmx_local_rtp_frame): RTP at offset 0, or at offset 1 behind a 0x0D lead byte."""
    for off in (0, 1):
        if (len(frame) >= off + 12 and (off == 0 or frame[0] == 0x0D) and frame[off] >> 6 == 2
                and frame[off + 8:off + 12] == SENTINEL):
            pkt = _parse_rtp(frame[off:])
            if pkt is not None:
                return pkt
            if off == 1:
                return None            # the library raises here; a streaming reader just drops the packet
    return None


class Reassembler:
    """One library packet body -> zero or more Annex-B NALs (each starting b"\\0\\0\\0\\1"). Keeps FU state.

    After each push(), `drop` names the stage that turned it into no NAL, or None when a NAL came out (GA A1 diagnosis;
    read only by the probe's --diag counters, it changes no decision): frame (_frame_of), rtp (_rtp_of), param (an
    00 01 / 00 02 carrier), route (not an HEVC payload type), evidence (no HEVC evidence yet), direct (not a direct HEVC
    frame), short, plausible, fu_gap (a continuation that does not continue), fu_cap, fu_part (an FU fragment held for
    more: not a loss), held (a PT-96 body waiting for the promotion decision: not a loss yet).
    """

    def __init__(self):
        self._pts = set()
        self._desc = {}                # payload type -> stream type, from 0x45 descriptors (rtp.py:508-544)
        self._active = None            # [data bytearray, last_seq, ts]   (packets.py:34-39)
        self._evidence = False         # payloads.py:~830 hevc_evidence_seen
        self.drop = None               # the stage that dropped the last push (class docstring); diagnostics only
        self._adv_seen = False         # payloads.py:1141-1143: a packet on an announced video PT was seen
        self._ev96 = 0                 # payloads.py:1144-1150: HEVC evidence frames on PT 96
        self._held = deque(maxlen=HOLD_MAX)   # (media, pkt) on PT 96 while the promotion is undecided

    def pts_seen(self) -> set:
        return set(self._pts)

    def descriptors(self) -> dict:
        """The 0x45 map learnt so far: payload type -> stream type."""
        return dict(self._desc)

    def _no(self, reason: str) -> list:
        self.drop = reason
        return []

    def _learn(self, ext: bytes) -> None:
        # rtp.py:520-544: walk the header-extension TLVs for 0x45 (stream type byte 2, payload type byte 3)
        o = 0
        while o + 2 <= len(ext):
            ln = ext[o + 1]
            end = o + ln + 2
            if end > len(ext):
                break
            if ext[o] == 0x45 and ln >= 2:
                self._desc[ext[o + 3] & 0x7F] = ext[o + 2]
            o = end

    def _routes(self):
        hevc = {p for p, st in self._desc.items() if st in HEVC_STREAM_TYPES}
        h264 = {p for p, st in self._desc.items() if st in H264_STREAM_TYPES}
        return hevc, h264

    def _promotable(self, hevc, h264) -> bool:
        # payloads.py:1125-1157: video descriptors, 96 unassigned, no announced video PT seen, hevc routes only
        return bool(hevc) and not h264 and DEFAULT_PT not in self._desc and not self._adv_seen

    def _track(self, pkt: _Rtp, media: bytes) -> None:
        hevc, h264 = self._routes()
        if pkt.pt in hevc | h264:
            self._adv_seen = True                                       # payloads.py:1141-1143
            self._held.clear()
        elif pkt.pt == DEFAULT_PT and ((len(media) > WRAPPER_NAL_OFFSET and media.startswith(WRAPPER))
                                       or _evidence_frame(media)):
            self._ev96 += 1                                             # payloads.py:1147-1150

    def _is_hevc_route(self, pt: int) -> bool:
        # payloads.py:1117-1171 + rtp.py:547-562: descriptor-owned routes win, plus PT 96 once promoted; else the
        # legacy PT 96, unless a descriptor has assigned 96 to something else. Built progressively (the library uses
        # the final map).
        hevc, h264 = self._routes()
        if not hevc:
            return pt == DEFAULT_PT and pt not in self._desc
        return pt in hevc or (pt == DEFAULT_PT and self._promotable(hevc, h264) and self._ev96 >= PROMOTE_EVIDENCE)

    def push(self, body: bytes) -> list:
        self.drop = None
        got = _frame_of(body)
        if got is None:
            return self._no("frame")
        frame, hs = got
        pkt = _rtp_of(frame)
        if pkt is None:
            return self._no("rtp")
        self._pts.add(pkt.pt)
        if pkt.ext:
            self._learn(pkt.ext)
        # packets.py:174-195 (_idmx_local_frame_media_body)
        if hs == 13 and len(frame) - 13 > WRAPPER_NAL_OFFSET and frame[13:].startswith(WRAPPER):
            media = frame[13:13 + WRAPPER_NAL_OFFSET] + pkt.payload
        elif hs == 13 and not pkt.has_ext:
            media = _strip_trailer(pkt.payload)            # packets.py:329-342
        else:
            media = pkt.payload
        self._track(pkt, media)
        # packets.py:~262-265: bodies starting 00 01 / 00 02 are parameter-frame carriers, skipped (payloads.py:~802)
        if len(media) > 4 and media[:2] in (b"\x00\x01", b"\x00\x02"):
            return self._no("param")
        if not self._is_hevc_route(pkt.pt):
            if pkt.pt == DEFAULT_PT and self._promotable(*self._routes()):
                self._held.append((media, pkt))
                return self._no("held")
            return self._no("route")
        out = []
        if self._held and pkt.pt == DEFAULT_PT:
            held = list(self._held)
            self._held.clear()
            for m, k in held:
                out += self._media(m, k)
        out += self._media(media, pkt)
        if out:
            self.drop = None
        return out

    def _media(self, media: bytes, pkt: _Rtp) -> list:
        self.drop = None
        authoritative = any(st in HEVC_STREAM_TYPES for st in self._desc.values())
        if len(media) > WRAPPER_NAL_OFFSET and media.startswith(WRAPPER):    # packets.py:297-300 / payloads.py:~800
            self._evidence = True
            return self._payload(media[WRAPPER_NAL_OFFSET:], pkt)
        if not (authoritative or self._evidence or _evidence_frame(media)):
            return self._no("evidence")
        if _direct_frame(media):
            self._evidence = True                                           # payloads.py:~850-868
            return self._payload(media, pkt)
        return self._no("direct")

    def _payload(self, payload: bytes, pkt: _Rtp) -> list:
        """payloads.py:1263-1304 (_append_idmx_hevc_media_payload) without decrypt."""
        if len(payload) < 2:
            return self._no("short")
        t = (payload[0] >> 1) & 63
        if t != FU:
            return [START + payload] if _plausible(payload) else self._no("plausible")   # active FU untouched, as upstream
        if len(payload) < 3:
            return self._no("short")
        fh = payload[2]
        start, orig = bool(fh & 128), fh & 63
        if not start and not self._continues(pkt):
            self._active = None            # seq gap or ts change drops the whole NAL (packets.py:204-222)
            return self._no("fu_gap")
        header = bytes([payload[0] & 129 | orig << 1, payload[1]])
        if start:
            self._active = [bytearray(header), pkt.seq, pkt.ts]
        act = self._active
        h0 = act[0][0]
        # EZVIZ headerless quirk: a continuation may omit the FU header byte (payloads.py:1291-1295)
        has_hdr = start or orig == _nal_type(bytes(act[0][:2])) or fh in (h0, h0 | 64)
        act[0].extend(payload[3:] if has_hdr else payload[2:])
        act[1], act[2] = pkt.seq, pkt.ts
        if len(act[0]) > FU_MAX_BYTES:
            self._active = None
            return self._no("fu_cap")
        if (has_hdr and fh & 64) or (not has_hdr and pkt.marker):
            nal, self._active = bytes(act[0]), None
            return [START + nal] if _plausible(nal) else self._no("plausible")
        return self._no("fu_part")

    def _continues(self, pkt: _Rtp) -> bool:
        # packets.py:204-222 (_rtp_fragment_continues): same timestamp and seq == last + 1 (mod 2**16)
        act = self._active
        if act is None:
            return False
        if act[2] is not None and act[2] != pkt.ts:
            return False
        return act[1] is None or ((act[1] + 1) & 0xFFFF) == pkt.seq


class AccessUnits:
    """NAL stream -> complete access units as (annexb_bytes, is_idr).

    is_idr is True when some VCL NAL in the AU is IDR_W_RADL (19) or IDR_N_LP (20); a CRA or BLA is not an
    IDR (C16: the publish point is the first complete IDR access unit). An AU ends when the next NAL starts
    a new picture, so push() returns an AU one picture late; flush() returns the pending one.
    """

    def __init__(self):
        self._nals = []
        self._has_vcl = False
        self._idr = False
        self._size = 0

    def push(self, nal: bytes) -> list:
        nal = nal[4:] if nal.startswith(START) else nal      # Reassembler output carries the start code
        t = _nal_type(nal)
        vcl = t < 32
        first_slice = vcl and len(nal) >= 3 and bool(nal[2] & 0x80)
        out = []
        # new AU: VPS/SPS/PPS/AUD/prefix-SEI after a VCL NAL, or a first-slice VCL NAL after a VCL NAL
        if self._has_vcl and (t in (32, 33, 34, 35, 39) or first_slice):
            out = self.flush()
        self._nals.append(START + nal)
        self._size += len(nal) + 4
        if len(self._nals) > AU_MAX_NALS or self._size > AU_MAX_BYTES:
            self._nals, self._has_vcl, self._idr, self._size = [], False, False, 0
            return out
        if vcl:
            self._has_vcl = True
            self._idr = self._idr or t in (19, 20)
        return out

    def flush(self) -> list:
        if not self._nals:
            return []
        au = (b"".join(self._nals), self._idr)
        self._nals, self._has_vcl, self._idr, self._size = [], False, False, 0
        return [au]
