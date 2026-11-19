"""The conditional MPEG-TS muxer for TIMESTAMP_MODE "rtp" (W-23 T21): PAT/PMT/PES, PTS = the RTP timestamp, unwrapped
past the 32-bit wrap, re-based with continuity on a jump. The parser below is the test's own, not the muxer's."""
import _path  # noqa: F401
import random
import subprocess
import unittest
from pathlib import Path

import fixtures
from ezviz_source import mpegts
from ezviz_source.mpegts import RtpClock, TsMuxer

SC = b"\x00\x00\x00\x01"
AUD = SC + b"\x46\x01\x50"
STEP = 3600
WRAP = 1 << 32


def au(nal_type: int, size: int) -> bytes:
    return SC + bytes([nal_type << 1, 1, 0x80]) + bytes([0x5A]) * size


IDR, TRAIL = (lambda n: au(19, n)), (lambda n: au(1, n))


def packets(ts: bytes):
    assert len(ts) % 188 == 0, len(ts)
    for i in range(0, len(ts), 188):
        p = ts[i:i + 188]
        assert p[0] == 0x47, i
        pusi, pid, afc, cc = bool(p[1] & 0x40), ((p[1] & 0x1F) << 8) | p[2], (p[3] >> 4) & 3, p[3] & 15
        off, af = 4, b""
        if afc & 2:
            af = p[5:5 + p[4]]
            off = 5 + p[4]
        yield {"pusi": pusi, "pid": pid, "cc": cc, "af": af, "payload": p[off:] if afc & 1 else b"",
               "has_payload": bool(afc & 1)}


def section(pkt) -> bytes:
    pl = pkt["payload"]
    body = pl[1 + pl[0]:]
    return body[:3 + (((body[1] & 0x0F) << 8) | body[2])]


def pes_list(ts: bytes, pid=mpegts.VIDEO_PID):
    out, cur = [], None
    for p in packets(ts):
        if p["pid"] != pid:
            continue
        if p["pusi"]:
            cur = {"data": bytearray(p["payload"]), "af": p["af"]}
            out.append(cur)
        else:
            cur["data"] += p["payload"]
    res = []
    for e in out:
        d = bytes(e["data"])
        assert d[:4] == b"\x00\x00\x01\xE0", d[:4]
        assert d[7] & 0xC0 == 0x80                                  # PTS only (no DTS: no reordering on these cameras)
        b = d[9:14]
        pts = ((b[0] >> 1) & 7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1
        assert b[0] >> 4 == 2 and b[0] & 1 and b[2] & 1 and b[4] & 1  # '0010' prefix and the three marker bits
        res.append({"pts": pts, "es": d[9 + d[8]:], "af": e["af"]})
    return res


class Crc(unittest.TestCase):
    def test_crc32_mpeg2_check_value(self):
        self.assertEqual(mpegts.crc32_mpeg2(b"123456789"), 0x0376E6E7)   # CRC-32/MPEG-2's catalogued check value


class Muxer(unittest.TestCase):
    def test_tables_first_and_valid(self):
        ts = TsMuxer().mux(IDR(400), 1000, True)
        ps = list(packets(ts))
        self.assertEqual([ps[0]["pid"], ps[1]["pid"]], [0, mpegts.PMT_PID])
        pat, pmt = section(ps[0]), section(ps[1])
        for sec in (pat, pmt):
            self.assertEqual(mpegts.crc32_mpeg2(sec), 0)                 # CRC over section + CRC is 0
        self.assertEqual((pat[0], ((pat[10] & 0x1F) << 8) | pat[11]), (0x00, mpegts.PMT_PID))
        self.assertEqual(pmt[0], 0x02)
        self.assertEqual(((pmt[8] & 0x1F) << 8) | pmt[9], mpegts.VIDEO_PID)   # PCR PID
        self.assertEqual((pmt[12], ((pmt[13] & 0x1F) << 8) | pmt[14]), (0x24, mpegts.VIDEO_PID))   # HEVC stream type

    def test_pes_pts_equals_the_rtp_ts_and_es_is_the_access_unit(self):
        m, clock, base = TsMuxer(), RtpClock(), 1234567
        aus = [IDR(5000)] + [TRAIL(700 + 37 * k) for k in range(9)]
        ts = b"".join(m.mux(a, clock.pts(base + k * STEP), k == 0) for k, a in enumerate(aus))
        got = pes_list(ts)
        self.assertEqual([g["pts"] for g in got], [base + k * STEP for k in range(10)])
        self.assertEqual([g["es"] for g in got], [AUD + a for a in aus])
        with_aud = AUD + TRAIL(50)
        self.assertEqual(pes_list(TsMuxer().mux(with_aud, 5, True))[0]["es"], with_aud)   # no second AUD

    def test_tables_and_random_access_on_every_idr_only(self):
        m = TsMuxer()
        for k, idr in enumerate((True, False, False, True, False)):
            ps = list(packets(m.mux(IDR(300) if idr else TRAIL(300), k * STEP, idr)))
            self.assertEqual(ps[0]["pid"] == 0 and ps[1]["pid"] == mpegts.PMT_PID, idr, k)
            first = [p for p in ps if p["pid"] == mpegts.VIDEO_PID][0]
            self.assertEqual(bool(first["af"] and first["af"][0] & 0x40), idr, k)   # random_access_indicator
            self.assertTrue(first["af"][0] & 0x10, k)                               # a PCR on every PES

    def test_continuity_counters_wrap_per_pid(self):
        m = TsMuxer()
        ts = b"".join(m.mux(IDR(20000) if k % 3 == 0 else TRAIL(3000), k * STEP, k % 3 == 0) for k in range(9))
        by_pid = {}
        for p in packets(ts):
            if p["has_payload"]:
                by_pid.setdefault(p["pid"], []).append(p["cc"])
        video = by_pid[mpegts.VIDEO_PID]
        self.assertGreater(len(video), 40)                                          # wraps at least twice
        self.assertEqual(video, [k % 16 for k in range(len(video))])
        self.assertEqual(by_pid[0], list(range(3)))
        self.assertEqual(by_pid[mpegts.PMT_PID], list(range(3)))

    def test_pts_field_is_modulo_2_33(self):
        got = pes_list(TsMuxer().mux(IDR(10), (1 << 33) + 77, True))
        self.assertEqual(got[0]["pts"], 77)

    def test_pts_field_round_trips_all_33_bits(self):
        for pts in (0, 1, (1 << 29) + 3, (1 << 30) + 5, (1 << 32) - 1, 1 << 32, (1 << 32) + 3600, (1 << 33) - 1,
                    0x1_2345_6789):
            self.assertEqual(pes_list(TsMuxer().mux(IDR(10), pts, True))[0]["pts"], pts, hex(pts))

    def test_every_size_packs_into_188_byte_packets(self):
        for n in range(0, 600):
            for idr in (True, False):
                ts = TsMuxer().mux(TRAIL(n), 9, idr)
                self.assertEqual(len(ts) % 188, 0, n)
                self.assertEqual(pes_list(ts)[0]["es"], AUD + TRAIL(n), n)


class Clock(unittest.TestCase):
    def test_a_session_crossing_the_32_bit_wrap_stays_monotonic(self):
        c, base = RtpClock(), WRAP - 5 * STEP
        got = [c.pts((base + k * STEP) % WRAP) for k in range(12)]
        self.assertEqual(got, [base + k * STEP for k in range(12)])                # past 2**32, no step back
        self.assertEqual(c.rebases, 0)

    def test_a_session_starting_just_below_the_wrap(self):
        c = RtpClock()
        got = [c.pts((WRAP - 1 + k * STEP) % WRAP) for k in range(4)]
        self.assertEqual(got, [WRAP - 1 + k * STEP for k in range(4)])
        self.assertEqual(c.rebases, 0)

    def test_a_jump_rebases_with_continuity(self):
        c = RtpClock()
        seq = [1000, 4600, 8200,                    # normal, step 3600
               500,                                 # backward: the camera restarted its base
               4100,                                # normal from the new base
               4100,                                # no step at all
               4100 + 2 * STEP,                     # a normal larger step (a lost picture), kept
               (4100 + 2 * STEP + 10 ** 9) % WRAP]  # forward by about 3 h: a new base
        got = [c.pts(t) for t in seq]
        self.assertEqual(got, [1000, 4600, 8200, 11800, 15400, 19000, 26200, 33400])
        self.assertEqual(c.rebases, 3)

    def test_any_input_never_goes_back(self):
        rnd, c, last = random.Random(23), RtpClock(), None
        t = rnd.randrange(WRAP)
        for _ in range(20000):
            r = rnd.random()
            t = rnd.randrange(WRAP) if r < 0.01 else (t + (0 if r < 0.02 else rnd.choice((STEP, STEP, 2 * STEP)))) % WRAP
            p = c.pts(t)
            self.assertTrue(last is None or p > last)
            last = p


class RealDemuxer(unittest.TestCase):
    """ffmpeg's mpegts demuxer (the one ffprobe and the helper's ffmpeg child use) reads what the muxer wrote: strictly
    monotonic PTS that equal the unwrapped RTP ts across a 32-bit wrap, and the clip decodes with 0 errors."""

    def test_real_ffmpeg_reads_monotonic_pts_across_the_wrap(self):
        from test_probe import real_ffmpeg
        import fakecam
        ff = real_ffmpeg()
        tmp = fixtures.tmpdir(self)
        clip = fixtures.make_es(ff, tmp / "clip.h265", 4)
        aus = fakecam.access_units(fakecam.split_nals(clip.read_bytes()))
        m, c, base = TsMuxer(), RtpClock(), WRAP - 40 * STEP                      # wraps at the 41st picture
        data = b"".join(m.mux(b"".join(SC + n for n in a), c.pts((base + k * STEP) % WRAP),
                              any((n[0] >> 1) & 0x3F in (19, 20) for n in a)) for k, a in enumerate(aus))
        (tmp / "out.ts").write_bytes(data)
        pk = subprocess.run([ff, "-hide_banner", "-v", "error", "-copyts", "-i", str(tmp / "out.ts"), "-map", "0:v",
                             "-c", "copy", "-f", "framemd5", "-"], capture_output=True, text=True, timeout=120)
        self.assertEqual(pk.stderr, "")
        pts = [int(ln.split(",")[2]) for ln in pk.stdout.splitlines() if ln and not ln.startswith("#")]
        self.assertEqual(len(pts), len(aus))
        self.assertEqual(pts, [base + k * STEP for k in range(len(aus))])
        dec = subprocess.run([ff, "-hide_banner", "-v", "error", "-i", str(tmp / "out.ts"), "-map", "0:v",
                              "-f", "framemd5", "-"], capture_output=True, text=True, timeout=120)
        self.assertEqual(dec.stderr, "")
        self.assertEqual(len([ln for ln in dec.stdout.splitlines() if ln and not ln.startswith("#")]), len(aus))


if __name__ == "__main__":
    unittest.main()
