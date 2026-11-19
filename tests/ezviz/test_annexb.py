import _path
import unittest

from ezviz_source import annexb
from ezviz_source.annexb import AccessUnits, Reassembler
from fixtures import SENTINEL, fu, hevc_nal, rtp_body

SC = b"\0\0\0\1"
VPS, SPS, PPS = hevc_nal(32, 24), hevc_nal(33, 40), hevc_nal(34, 12)


def drain(aus: AccessUnits, nals) -> list:
    out = []
    for n in nals:
        out += aus.push(n)
    return out + aus.flush()


class ReassemblerTests(unittest.TestCase):
    def test_single_nal_passthrough(self):
        self.assertEqual(Reassembler().push(rtp_body(96, 1, 0, VPS)), [SC + VPS])

    def test_fu_reassembly(self):
        idr = hevc_nal(19, 5000)
        frags = fu(idr, 1250)
        self.assertEqual(len(frags), 4)
        r, out = Reassembler(), []
        for i, p in enumerate(frags):
            out += r.push(rtp_body(96, 10 + i, 900, p, marker=i == 3))
        self.assertEqual(out, [SC + idr])

    def test_fu_seq_gap_drops_the_nal(self):
        r, out = Reassembler(), []
        frags = fu(hevc_nal(19, 5000), 1250)
        for seq, p in zip((10, 12, 13, 14), frags):          # 11 is missing
            out += r.push(rtp_body(96, seq, 900, p))
        self.assertEqual(out, [])
        self.assertEqual(r.push(rtp_body(96, 15, 900, SPS)), [SC + SPS])

    def test_fu_ts_change_drops(self):
        r, out = Reassembler(), []
        frags = fu(hevc_nal(19, 3000), 1200)
        out += r.push(rtp_body(96, 10, 1000, frags[0]))
        out += r.push(rtp_body(96, 11, 2000, frags[1]))      # same seq run, new timestamp
        out += r.push(rtp_body(96, 12, 2000, frags[2], marker=True))
        self.assertEqual(out, [])
        self.assertEqual(r.push(rtp_body(96, 13, 2000, SPS)), [SC + SPS])

    def test_headerless_fu_continuation(self):
        # EZVIZ quirk: continuations carry the 2-byte FU indicator but no FU header; the RTP marker ends the NAL.
        idr = hevc_nal(19, 40)
        ind = bytes([(idr[0] & 0x81) | (49 << 1), idr[1]])
        start = ind + bytes([0x80 | 19]) + idr[2:20]
        r = Reassembler()
        self.assertEqual(r.push(rtp_body(96, 5, 77, start)), [])
        self.assertEqual(r.push(rtp_body(96, 6, 77, ind + idr[20:30])), [])
        self.assertEqual(r.push(rtp_body(96, 7, 77, ind + idr[30:], marker=True)), [SC + idr])

    def test_header13_variant(self):
        self.assertEqual(Reassembler().push(rtp_body(96, 1, 0, VPS, header13=True)), [SC + VPS])

    def test_trailer_24_00_stripped(self):
        got = Reassembler().push(rtp_body(96, 1, 0, VPS + b"\x24\x00\x00\x08", header13=True))
        self.assertEqual(got, [SC + VPS])

    def test_non_video_pt_ignored(self):
        r = Reassembler()
        self.assertEqual(r.push(rtp_body(104, 1, 0, b"\x01\x02\x03\x04\x05\x06")), [])
        self.assertEqual(r.pts_seen(), {104})

    def test_runaway_fu_is_dropped_at_cap(self):
        # review 1: a valid-start FU with continuous seq/ts that never ends must not grow without bound
        with unittest.mock.patch.object(annexb, "FU_MAX_BYTES", 100):
            r, out = Reassembler(), []
            frags = fu(hevc_nal(19, 2000), 40)
            for i, p in enumerate(frags[:10]):
                out += r.push(rtp_body(96, 10 + i, 900, p))
            self.assertEqual(out, [])
            self.assertIsNone(r._active)
            self.assertEqual(r.push(rtp_body(96, 99, 901, SPS)), [SC + SPS])

    def test_zero_length_extension_keeps_trailer_rule(self):
        # review 2: X=1 with a zero-length extension still has extension_profile set (rtp.py:440-451),
        # so the 24 00 trailer is NOT stripped (packets.py:~177-181)
        body = VPS + b"\x24\x00\x00\x08"
        rtp = bytes([0x90, 96, 0, 1, 0, 0, 0, 0]) + SENTINEL + b"\0\0\0\0" + body
        frame = b"\x0d" + rtp
        got = Reassembler().push(len(frame).to_bytes(4, "little") + frame)
        self.assertEqual(got, [SC + body])

    def test_param_frame_body_skipped(self):
        # packets.py:~262-265: bodies starting 00 01 / 00 02 are skipped, even after evidence
        r = Reassembler()
        r.push(rtp_body(96, 1, 0, VPS))
        for lead in (b"\x00\x01", b"\x00\x02"):
            self.assertEqual(r.push(rtp_body(96, 2, 0, lead + hevc_nal(1, 20)[2:])), [])

    def test_wrapper_nal_at_offset_12(self):
        # packets.py:297-300 / payloads.py:~800: 40 00 00 02 80 06 wrapper, NAL at offset 12
        got = Reassembler().push(rtp_body(96, 1, 0, b"\x40\x00\x00\x02\x80\x06" + b"\0" * 6 + SPS))
        self.assertEqual(got, [SC + SPS])

    def test_descriptor_routing(self):
        # rtp.py:508-544: 0x45 TLV = stream type, payload type. A non-HEVC descriptor on 96 rejects it
        def with_desc(pt, seq, stream_type, desc_pt, payload):
            rtp = bytes([0x90, pt, 0, seq, 0, 0, 0, 0]) + SENTINEL + b"\xbe\xde\x00\x01" \
                + bytes([0x45, 2, stream_type, desc_pt]) + payload
            return len(rtp).to_bytes(4, "little") + rtp
        r = Reassembler()
        self.assertEqual(r.push(with_desc(96, 1, 0x1B, 96, VPS)), [])        # h264 owns PT 96
        r = Reassembler()
        self.assertEqual(r.push(with_desc(98, 1, 0x24, 98, VPS)), [SC + VPS])  # hevc on another PT
        self.assertEqual(r.push(rtp_body(96, 2, 0, SPS)), [])                  # 96 is no longer a route

    def test_stream_type_b2_is_hevc(self):
        # rtp.py:_IDMX_RTP_STREAM_TYPES maps BOTH 0x24 and 0xB2 to hevc (W-23 GA A1 diagnosis, hypothesis H1): a 0xB2
        # descriptor on PT 96 is an authoritative HEVC route, not a foreign owner of 96
        def with_desc(pt, seq, stream_type, desc_pt, payload):
            rtp = bytes([0x90, pt, 0, seq, 0, 0, 0, 0]) + SENTINEL + b"\xbe\xde\x00\x01" \
                + bytes([0x45, 2, stream_type, desc_pt]) + payload
            return len(rtp).to_bytes(4, "little") + rtp
        for st in (0x24, 0xB2):
            r = Reassembler()
            idr = hevc_nal(19, 30)
            self.assertEqual(r.push(with_desc(96, 1, st, 96, idr)), [SC + idr], hex(st))   # authoritative: no evidence wait
            self.assertEqual(r.push(rtp_body(96, 2, 0, SPS)), [SC + SPS], hex(st))

    def test_pt96_promotion_when_the_announced_hevc_pt_never_carries_packets(self):
        # payloads.py:1125-1157 (GA A1 diagnosis, the real camera): a 0x45 TLV announces hevc on PT 15, PT 15 never
        # carries a packet, PT 96 is unassigned and shows >= 2 HEVC evidence frames: the library adds 96 to the hevc
        # routes. The bodies before the second evidence frame wait in the hold and come out in order.
        def desc(seq, stream_type=0x24, pt=15):
            rtp = bytes([0x90, 112, 0, seq, 0, 0, 0, 0]) + SENTINEL + b"\xbe\xde\x00\x01" + bytes([0x45, 2, stream_type, pt])
            return len(rtp).to_bytes(4, "little") + rtp
        idr = hevc_nal(19, 30)
        r = Reassembler()
        self.assertEqual(r.push(desc(1)), [])
        self.assertEqual(r.descriptors(), {15: 0x24})
        self.assertEqual(r.push(rtp_body(96, 1, 0, VPS)), [])
        self.assertEqual(r.drop, "held")
        self.assertEqual(r.push(rtp_body(96, 2, 0, SPS)), [SC + VPS, SC + SPS])   # the second evidence frame decides
        self.assertIsNone(r.drop)
        self.assertEqual(r.push(rtp_body(96, 3, 0, PPS)), [SC + PPS])
        self.assertEqual(r.push(rtp_body(96, 4, 0, idr)), [SC + idr])
        self.assertEqual(r.push(rtp_body(104, 5, 0, b"\xd5" * 40)), [])            # audio stays off the route
        self.assertEqual(r.drop, "route")

    def test_no_promotion_once_the_announced_pt_carries_a_packet(self):
        # payloads.py:1141-1143: one packet on an announced video PT and the library never promotes 96
        def desc(pt_rtp, seq, stream_type=0x24, pt=15, payload=b""):
            rtp = bytes([0x90, pt_rtp, 0, seq, 0, 0, 0, 0]) + SENTINEL + b"\xbe\xde\x00\x01" \
                + bytes([0x45, 2, stream_type, pt]) + payload
            return len(rtp).to_bytes(4, "little") + rtp
        r = Reassembler()
        r.push(desc(112, 1))
        self.assertEqual(r.push(rtp_body(15, 1, 0, VPS)), [SC + VPS])              # the announced route itself
        for seq, n in enumerate((VPS, SPS, PPS, hevc_nal(19, 30)), 2):
            self.assertEqual(r.push(rtp_body(96, seq, 0, n)), [])
            self.assertEqual(r.drop, "route")
        r = Reassembler()                                                           # promoted, then PT 15 shows up
        r.push(desc(112, 1))
        r.push(rtp_body(96, 1, 0, VPS))
        self.assertEqual(r.push(rtp_body(96, 2, 0, SPS)), [SC + VPS, SC + SPS])
        r.push(rtp_body(15, 1, 0, PPS))
        self.assertEqual(r.push(rtp_body(96, 3, 0, PPS)), [])
        self.assertEqual(r.drop, "route")

    def test_no_promotion_with_h264_routes_or_96_assigned_or_one_evidence(self):
        def desc(tlvs):
            ext = b"".join(bytes([0x45, 2, st, pt]) for pt, st in tlvs)
            rtp = bytes([0x90, 112, 0, 1, 0, 0, 0, 0]) + SENTINEL + b"\xbe\xde" + (len(ext) // 4).to_bytes(2, "big") + ext
            return len(rtp).to_bytes(4, "little") + rtp
        for tlvs in ([(15, 0x24), (17, 0x1B)], [(15, 0x24), (96, 0x90)], [(15, 0x24), (17, 0xB0)]):
            r = Reassembler()
            r.push(desc(tlvs))
            out = [x for seq, n in enumerate((VPS, SPS, PPS), 1) for x in r.push(rtp_body(96, seq, 0, n))]
            self.assertEqual((out, r.drop), ([], "route"), tlvs)
        r = Reassembler()                                                           # one evidence frame: still held
        r.push(desc([(15, 0x24)]))
        self.assertEqual(r.push(rtp_body(96, 1, 0, VPS)), [])
        self.assertEqual(r.push(rtp_body(96, 2, 0, hevc_nal(1, 30))), [])
        self.assertEqual(r.drop, "held")

    def test_promotion_hold_is_bounded(self):
        def desc():
            rtp = bytes([0x90, 112, 0, 1, 0, 0, 0, 0]) + SENTINEL + b"\xbe\xde\x00\x01" + bytes([0x45, 2, 0x24, 15])
            return len(rtp).to_bytes(4, "little") + rtp
        r = Reassembler()
        r.push(desc())
        r.push(rtp_body(96, 0, 0, VPS))                                             # evidence 1, then no more
        for seq in range(1, 1000):
            r.push(rtp_body(96, seq, 0, hevc_nal(1, 30)))
        self.assertLessEqual(len(r._held), annexb.HOLD_MAX)

    def test_evidence_gate_drops_vcl_before_parameter_sets(self):
        r = Reassembler()
        self.assertEqual(r.push(rtp_body(96, 1, 0, hevc_nal(19, 30))), [])
        self.assertEqual(r.push(rtp_body(96, 2, 0, VPS)), [SC + VPS])
        idr = hevc_nal(19, 30)
        self.assertEqual(r.push(rtp_body(96, 3, 0, idr)), [SC + idr])

    def test_implausible_assembled_nal_dropped(self):
        # packets.py:352-359: an FU that reassembles to NAL type 41 (> 40) is dropped
        nal = bytes([41 << 1, 1]) + b"\x80" + b"\x5a" * 20
        r, out = Reassembler(), []
        for i, p in enumerate(fu(nal, 10)):
            out += r.push(rtp_body(96, i, 5, p))
        self.assertEqual(out, [])


class DropReasonTests(unittest.TestCase):
    """GA A1 diagnosis: Reassembler.drop names the stage that turned a push into no NAL (None when a NAL came out).
    The probe's --diag counters read it, so they count the real code path, not a copy of it."""

    def test_reasons(self):
        legacy = b"\xfa" + bytes([0x80, 96, 0, 1, 0, 0, 0, 0]) + SENTINEL + VPS     # 13-byte header, no RTP at 0/1
        aud = bytes([35 << 1, 1, 0x50])
        cases = [
            ("frame", [], b"\x00\x01\x02"),
            ("rtp", [], len(legacy).to_bytes(4, "little") + legacy),
            ("param", [VPS], rtp_body(96, 2, 0, b"\x00\x01" + hevc_nal(1, 20)[2:])),
            ("route", [], rtp_body(104, 1, 0, VPS)),
            ("evidence", [], rtp_body(96, 1, 0, hevc_nal(19, 30))),
            ("direct", [VPS], rtp_body(96, 2, 0, bytes([2, 0]) + b"\x80" * 8)),          # TID 0: not a NAL header
            ("plausible", [VPS], rtp_body(96, 2, 0, bytes([49 << 1, 1, 0xC0 | 41]) + b"\x5a" * 8)),   # FU -> type 41
            ("short", [VPS], rtp_body(96, 2, 0, bytes([49 << 1, 1]))),                 # an FU without its FU header
            ("fu_gap", [VPS], rtp_body(96, 2, 0, fu(hevc_nal(19, 300), 100)[1])),      # a continuation, no start
            ("fu_part", [VPS], rtp_body(96, 2, 0, fu(hevc_nal(19, 300), 100)[0])),     # a start: more to come
            (None, [VPS], rtp_body(96, 2, 0, aud)),
        ]
        for want, before, body in cases:
            r = Reassembler()
            for i, b in enumerate(before):
                self.assertEqual(r.push(rtp_body(96, 1, 0, b)), [SC + b])
                self.assertIsNone(r.drop)
            got = r.push(body)
            self.assertEqual((r.drop, got == []), (want, want is not None), want)

    def test_fu_cap_reason(self):
        with unittest.mock.patch.object(annexb, "FU_MAX_BYTES", 100):
            r = Reassembler()
            drops = []
            for i, p in enumerate(fu(hevc_nal(19, 2000), 40)[:10]):
                r.push(rtp_body(96, 10 + i, 900, p))
                drops.append(r.drop)
            self.assertIn("fu_cap", drops)

    def test_route_reason_after_a_b2_descriptor_on_another_pt(self):
        rtp = bytes([0x90, 98, 0, 1, 0, 0, 0, 0]) + SENTINEL + b"\xbe\xde\x00\x01" + bytes([0x45, 2, 0xB2, 98]) + VPS
        r = Reassembler()
        self.assertEqual(r.push(len(rtp).to_bytes(4, "little") + rtp), [SC + VPS])
        self.assertEqual(r.descriptors(), {98: 0xB2})
        self.assertEqual(r.push(rtp_body(96, 2, 0, SPS)), [])
        self.assertEqual(r.drop, "route")


class AccessUnitTests(unittest.TestCase):
    def test_access_units_split_and_idr(self):
        idr, trail = hevc_nal(19, 50), hevc_nal(1, 30)
        got = drain(AccessUnits(), [VPS, SPS, PPS, idr, trail])
        self.assertEqual(got, [(SC + VPS + SC + SPS + SC + PPS + SC + idr, True), (SC + trail, False)])

    def test_cra_is_not_idr(self):
        # C16: the publish point is the first IDR, not any IRAP; CRA is type 21.
        got = drain(AccessUnits(), [VPS, SPS, PPS, hevc_nal(21, 50), hevc_nal(1, 30)])
        self.assertEqual([f for _, f in got], [False, False])
        self.assertEqual(len(got), 2)

    def test_runaway_au_is_dropped_at_cap(self):
        with unittest.mock.patch.object(annexb, "AU_MAX_NALS", 3):
            aus = AccessUnits()
            out = []
            for n in (VPS, SPS, PPS, hevc_nal(39, 10)):   # no VCL, so no boundary ever
                out += aus.push(n)
            self.assertEqual(out, [])
            self.assertEqual(aus._nals, [])
            idr = hevc_nal(19, 50)
            self.assertEqual(drain(aus, [idr, hevc_nal(1, 30)]), [(SC + idr, True), (SC + hevc_nal(1, 30), False)])
        with unittest.mock.patch.object(annexb, "AU_MAX_BYTES", 100):
            aus = AccessUnits()
            self.assertEqual(aus.push(hevc_nal(39, 200)), [])
            self.assertEqual(aus._nals, [])

    def test_two_slices_one_picture(self):
        got = drain(AccessUnits(), [hevc_nal(19, 50), hevc_nal(19, 50, first_slice=False)])
        self.assertEqual(len(got), 1)
        self.assertTrue(got[0][1])


if __name__ == "__main__":
    unittest.main()
