import _path
import unittest

from ezviz_source.annexb import AccessUnits, Reassembler
from fixtures import fu, hevc_nal, rtp_body

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

    def test_two_slices_one_picture(self):
        got = drain(AccessUnits(), [hevc_nal(19, 50), hevc_nal(19, 50, first_slice=False)])
        self.assertEqual(len(got), 1)
        self.assertTrue(got[0][1])


if __name__ == "__main__":
    unittest.main()
