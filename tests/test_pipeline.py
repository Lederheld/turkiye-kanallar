"""Pipeline'ın ağ gerektirmeyen parçaları: python -m unittest discover -s tests"""

import time
import unittest

import build_epg
import build_playlist as bp


class EpgNormalizeTests(unittest.TestCase):
    def test_matches_swift_normalize(self):
        # tvos ProgramGuide.normalize ile aynı sonuçlar (NormalizeTests)
        self.assertEqual(build_epg.normalize("TRT 1 HD"), "trt1")
        self.assertEqual(build_epg.normalize("TRT.1.HD.tr"), "trt1")
        self.assertEqual(build_epg.normalize("TRT Spor Yıldız"), "trtsporyildiz")
        self.assertEqual(build_epg.normalize("İZ TV"), "iztv")
        self.assertEqual(build_epg.normalize("TV8,5"), "tv85")


class EpgWindowTests(unittest.TestCase):
    def test_clean_filters_window_sorts_and_dedupes(self):
        programs = [[300, 400, "C"], [100, 200, "A"], [100, 200, "A"], [10, 50, "eski"], [900, 950, "uzak"]]
        self.assertEqual(build_epg.clean(programs, 60, 800), [[100, 200, "A"], [300, 400, "C"]])

    def test_covers_now(self):
        self.assertTrue(build_epg.covers_now([[100, 200, "A"]], 150))
        self.assertFalse(build_epg.covers_now([[100, 200, "A"]], 200))

    def test_build_prefers_sources_in_order_and_skips_stale_dsmart(self):
        now = int(time.time())
        name = bp.CHANNEL_SPECS[0].display_name
        key = build_epg.normalize(name)
        stale = {key: [[now - 3 * 86400, now - 3 * 86400 + 3600, "eski bölüm"]]}
        fresh = {key: [[now - 600, now + 3000, "Haber"]]}
        original = (build_epg.XMLTV_SOURCES, build_epg.xmltv_programs, build_epg.dsmart_programs)
        try:
            build_epg.XMLTV_SOURCES = ("https://a.example/1.xml",)
            build_epg.xmltv_programs = lambda url: {}
            build_epg.dsmart_programs = lambda now_dt: stale
            self.assertNotIn(name, build_epg.build({}), "şu anı kapsamayan D-Smart verisi alınmaz")
            build_epg.dsmart_programs = lambda now_dt: fresh
            self.assertEqual(build_epg.build({})[name], fresh[key])
        finally:
            build_epg.XMLTV_SOURCES, build_epg.xmltv_programs, build_epg.dsmart_programs = original


class PlaylistUrlTests(unittest.TestCase):
    def test_expiring_urls(self):
        self.assertTrue(bp.is_expiring_url("https://cdn.example/live.m3u8?token=abc&e=123"))
        self.assertTrue(bp.is_expiring_url("https://cdn.example/hdnts=exp=1/live.m3u8"))
        self.assertFalse(bp.is_expiring_url("https://cdn.example/live/playlist.m3u8"))

    def test_stale_expiry(self):
        self.assertTrue(bp.has_stale_expiry(f"https://x.example/a.m3u8?e={int(time.time()) - 60}"))
        self.assertFalse(bp.has_stale_expiry(f"https://x.example/a.m3u8?e={int(time.time()) + 3600}"))

    def test_strips_ad_tracking_only(self):
        url = "https://x.example/a.m3u8?ppid=1&dfp_x=2&utm_source=z&keep=3"
        self.assertEqual(bp.strip_ad_tracking_params(url), "https://x.example/a.m3u8?keep=3")

    def test_tvg_id_feed_suffix(self):
        self.assertEqual(bp.normalize_tvg_id("TRT1.tr@HD"), "TRT1.tr")

    def test_single_variant_pattern(self):
        match = bp.SINGLE_VARIANT_PATTERN.match("https://x.example/atv/atv_1080p.m3u8?t=1")
        self.assertEqual((match["name"], match["height"], match["query"]), ("atv", "1080", "?t=1"))


class HostRuleTests(unittest.TestCase):
    spec = bp.CHANNEL_SPECS[0]

    def test_rejects_bare_ip_and_unknown_hosts(self):
        self.assertEqual(bp.host_rejection_reason("203.0.113.5", self.spec, False), "çıplak IP")
        self.assertEqual(bp.host_rejection_reason("random-restream.example", self.spec, False), "beyaz listede değil")

    def test_accepts_owned_domain_and_official_capture(self):
        self.assertIsNone(bp.host_rejection_reason("tv-trt1.medya.trt.com.tr", self.spec, False))
        self.assertIsNone(bp.host_rejection_reason("player-cdn.example", self.spec, True))

    def test_report_masks_private_addresses(self):
        # rapor herkese açık artifact: Mac'in yerel IP'si yazılmamalı
        self.assertEqual(bp.report_host("192.168.1.20"), "yerel ağ")
        self.assertEqual(bp.report_host("10.0.0.2"), "yerel ağ")
        self.assertEqual(bp.report_host("tv8.daioncdn.net"), "tv8.daioncdn.net")


class IptvOrgParserTests(unittest.TestCase):
    def test_parses_candidates_with_headers(self):
        text = """#EXTM3U
#EXTINF:-1 tvg-id="ATV.tr@SD",ATV (720p) [Not 24/7]
#EXTVLCOPT:http-user-agent=UA
#EXTVLCOPT:http-referrer=https://www.atv.com.tr/
https://cdn.example/atv.m3u8
"""
        candidates = bp.parse_iptv_org_m3u(text)["ATV.tr"]
        self.assertEqual(len(candidates), 1)
        candidate = candidates[0]
        self.assertEqual((candidate.url, candidate.resolution_height, candidate.is_not_24_7),
                         ("https://cdn.example/atv.m3u8", 720, True))
        self.assertEqual((candidate.user_agent, candidate.referrer), ("UA", "https://www.atv.com.tr/"))


if __name__ == "__main__":
    unittest.main()
