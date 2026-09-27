#!/usr/bin/env python3
"""Türk TV kanalları için yalnızca resmi/ücretsiz kaynaklardan M3U listesi üretir.

Akış:
  1. iptv-org ve Free-TV listelerinden aday URL'leri topla.
  2. Host beyaz listesi (Kural 1) ve süreli-token kontrolü (Kural 3) ile filtrele.
  3. Adayı kalmayan / hiçbiri çalışmayan kanallar için resmi sitenin canlı yayın
     sayfasını Playwright ile açıp .m3u8 isteklerini yakala.
  4. ffprobe ile video+ses doğrula; seçilenleri ikinci kez test et.
  5. turkiye-kanallar.m3u + rapor.md yaz; --publish ile secret gist'e yükle.

Token yenileme / DRM / giriş aşma YAPILMAZ. Süreli linkler listeye girmez.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import ipaddress
import os
import json
import re
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import parse_qsl, urlencode, urljoin, urlparse

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
PROJECT_DIR = Path(__file__).resolve().parent
OUTPUT_PLAYLIST_NAME = "turkiye-kanallar.m3u"
OUTPUT_PLAYLIST_PATH = PROJECT_DIR / OUTPUT_PLAYLIST_NAME
OUTPUT_REPORT_PATH = PROJECT_DIR / "rapor.md"
GIST_ID_STATE_PATH = PROJECT_DIR / ".gist_id"
# Public repo'da Actions logları herkese açık: gist id/URL'si CI'da asla yazdırılmaz
RUNNING_IN_CI = os.environ.get("GITHUB_ACTIONS") == "true"
GIST_DESCRIPTION = "Türkiye TV kanalları (resmi ücretsiz kaynaklar)"

IPTV_ORG_TR_M3U_URL = "https://raw.githubusercontent.com/iptv-org/iptv/master/streams/tr.m3u"
FREE_TV_TURKEY_MD_URL = "https://raw.githubusercontent.com/Free-TV/IPTV/master/lists/turkey.md"
IPTV_ORG_CHANNELS_API_URL = "https://iptv-org.github.io/api/channels.json"
IPTV_ORG_LOGOS_API_URL = "https://iptv-org.github.io/api/logos.json"

HTTP_FETCH_TIMEOUT_SECONDS = 30
FFPROBE_NETWORK_TIMEOUT_MICROSECONDS = 15_000_000
FFPROBE_PROCESS_TIMEOUT_SECONDS = 40
FFPROBE_ANALYZE_DURATION_MICROSECONDS = 5_000_000
PARALLEL_PROBE_WORKERS = 8
RECHECK_DELAY_SECONDS = 20

BROWSER_CHANNEL = "chrome"  # sistemdeki Google Chrome; yoksa Playwright Chromium'a düşer
BROWSER_PAGE_LOAD_TIMEOUT_MS = 45_000
BROWSER_PLAYER_READY_WAIT_SECONDS = 5
BROWSER_CLICK_TIMEOUT_MS = 2_000
BROWSER_CAPTURE_WAIT_SECONDS = 25
BROWSER_VIEWPORT = {"width": 1280, "height": 800}
BROWSER_PLAYER_AREA_CLICK_POSITION = (640, 350)
BROWSER_USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
)
PLAY_BUTTON_SELECTORS = [
    ".vjs-big-play-button",
    ".jw-display-icon-container",
    ".plyr__control--overlaid",
    "button[aria-label*='Play' i]",
    "button[aria-label*='Oynat' i]",
    "[class*='play-button']",
    "[class*='playButton']",
    "video",
]

SOURCE_PRIORITY_FREE_TV = 0
SOURCE_PRIORITY_OFFICIAL_PAGE = 1
SOURCE_PRIORITY_IPTV_ORG = 2
TRT_OWN_DOMAIN_SUFFIX = "medya.trt.com.tr"
DEFAULT_RESOLUTION_HEIGHT = 0

# Kural 1: yayıncıların kullandığı bilinen CDN'ler (+ her kanalın kendi domainleri)
TRUSTED_CDN_SUFFIXES = (
    "medya.trt.com.tr",
    "live.trt.com.tr",
    "daioncdn.net",
    "ercdn.net",
    "mncdn.com",
    "blutv.com",
    "mediatriple.net",
)
SUSPICIOUS_TLDS = (".lol", ".top", ".xyz", ".live", ".click", ".icu", ".cfd", ".sbs")
BLOCKED_HOST_SUFFIXES = (
    "ensonhaber.com",          # başka kanalların yayınını yeniden yayınlayan haber sitesi
    "githubusercontent.com",   # kişisel GitHub restream'leri
    "github.io",
    "onrender.com",
    "smartplaytv.in",
    "cinerama.uz",
    "freeott.top",
    "siteyaptim.live",
)
# Kural 3: süreli token / imza parametreleri
EXPIRING_TOKEN_PARAM_NAMES = {
    "token", "tkn", "expires", "expire", "expiry", "exp", "e", "st",
    "signature", "sig", "hash", "hmac", "md5", "hdnts", "hdntl", "hdnea",
    "policy", "key-pair-id", "wmsauthsign", "auth", "auth_key", "secure",
    "validfrom", "validto", "sid", "session", "sessionid", "jwt",
}
# Reklam hedefleme kimlikleri (auth değil); kullanıcıya özel oldukları için URL'den çıkarılır
AD_TRACKING_PARAM_NAMES = {"ppid", "gdpr", "gdpr_consent", "us_privacy", "cust_params", "correlator", "paln"}
AD_TRACKING_PARAM_PREFIXES = ("dfp_", "ads_", "ad_", "utm_")
HLS_VOD_END_MARKER = "#EXT-X-ENDLIST"
HLS_VARIANT_MARKER = "#EXT-X-STREAM-INF"
# İmzalı linklerde son kullanma zamanı taşıyan parametreler (unix zaman damgası)
EXPIRY_TIMESTAMP_PARAM_NAMES = {"e", "ex", "exp", "expires", "expiry", "expire"}
# Sayfa kaynağında gömülü m3u8 linkleri (JSON içinde \/ kaçışlı olabilir)
EMBEDDED_M3U8_PATTERN = re.compile(r"https?:(?:\\?/){2}[^\s\"'<>]+?\.m3u8[^\s\"'<>]*")
INCLUDE_GROUP_TITLE = False   # kategorisiz düz liste
EXPIRING_TOKEN_PATH_PATTERN = re.compile(r"(token|hdnts|exp=|expires|signature)", re.IGNORECASE)
RESOLUTION_PATTERN = re.compile(r"\((\d{3,4})p\)")
NOT_24_7_MARKER = "[Not 24/7]"

GROUP_NATIONAL = "Ulusal"
GROUP_NEWS = "Haber"
GROUP_SPORTS = "Spor"
GROUP_KIDS = "Çocuk"
GROUP_DOCUMENTARY = "Belgesel & Kültür"
GROUP_MUSIC = "Müzik"


@dataclass
class ChannelSpec:
    display_name: str
    group_title: str
    tvg_id: str                                   # iptv-org kanal id'si (feed eki olmadan)
    owned_domains: tuple[str, ...] = ()           # kanalın/grubun kendi domainleri
    official_live_pages: tuple[str, ...] = ()     # Playwright ile açılacak resmi sayfalar
    free_tv_names: tuple[str, ...] = ()           # Free-TV tablosundaki ad
    known_official_urls: tuple[str, ...] = ()     # resmi siteden daha önce yakalanmış sabit linkler


CHANNEL_SPECS: list[ChannelSpec] = [
    # Ulusal
    ChannelSpec("TRT 1", GROUP_NATIONAL, "TRT1.tr", ("trt.com.tr", "trt1.com.tr"), ("https://www.trt1.com.tr/canli-yayin",), ("TRT 1",)),
    ChannelSpec("ATV", GROUP_NATIONAL, "ATV.tr", ("atv.com.tr",), ("https://www.atv.com.tr/canli-yayin",)),
    ChannelSpec("Kanal D", GROUP_NATIONAL, "KanalD.tr", ("kanald.com.tr",), ("https://www.kanald.com.tr/canli-yayin",)),
    ChannelSpec("Show TV", GROUP_NATIONAL, "ShowTV.tr", ("showtv.com.tr",), ("https://www.showtv.com.tr/canli-yayin",)),
    ChannelSpec("Star TV", GROUP_NATIONAL, "StarTV.tr", ("startv.com.tr",), ("https://www.startv.com.tr/canli-yayin",),
                known_official_urls=("https://dogus.daioncdn.net/startv/startv.m3u8?ce=3&app=a20ac41e-bdc3-4aa1-934d-26b484480ac9",)),
    ChannelSpec("NOW", GROUP_NATIONAL, "NOWTV.tr", ("nowtv.com.tr",), ("https://www.nowtv.com.tr/canli-yayin",)),
    ChannelSpec("TV8", GROUP_NATIONAL, "TV8.tr", ("tv8.com.tr",), ("https://www.tv8.com.tr/canli-yayin",)),
    ChannelSpec("Kanal 7", GROUP_NATIONAL, "Kanal7.tr", ("kanal7.com",), ("https://www.kanal7.com/canli-izle",)),
    ChannelSpec("Beyaz TV", GROUP_NATIONAL, "BeyazTV.tr", ("beyaztv.com.tr",), ("https://beyaztv.com.tr/canli-yayin",)),
    ChannelSpec("360", GROUP_NATIONAL, "360.tr", ("tv360.com.tr",), ("https://www.tv360.com.tr/canli-yayin",)),
    ChannelSpec("Teve2", GROUP_NATIONAL, "", ("teve2.com.tr",), ("https://www.teve2.com.tr/canli-yayin",)),
    ChannelSpec("a2", GROUP_NATIONAL, "A2TV.tr", ("atv.com.tr", "a2tv.com.tr"), ("https://www.atv.com.tr/a2tv/canli-yayin",)),
    ChannelSpec("TV8,5", GROUP_NATIONAL, "TV85.tr", ("tv8bucuk.com",), ("https://www.tv8bucuk.com/tv8-5-canli-yayin",),
                known_official_urls=("https://tv8.daioncdn.net/tv8bucuk/tv8bucuk.m3u8?app=tv8bucuk_web&ce=3",)),
    ChannelSpec("TRT 2", GROUP_NATIONAL, "TRT2.tr", ("trt.com.tr", "trt2.com.tr"), ("https://www.trt2.com.tr/canli-yayin",), ("TRT 2 Ⓖ",)),
    # Haber
    ChannelSpec("TRT Haber", GROUP_NEWS, "TRTHaber.tr", ("trt.com.tr", "trthaber.com"), ("https://www.trthaber.com/canli-yayin-izle.html",), ("TRT Haber",)),
    ChannelSpec("NTV", GROUP_NEWS, "NTV.tr", ("ntv.com.tr",), ("https://www.ntv.com.tr/canli-yayin/ntv",)),
    ChannelSpec("CNN Türk", GROUP_NEWS, "CNNTurk.tr", ("cnnturk.com",), ("https://www.cnnturk.com/canli-yayin",)),
    ChannelSpec("Habertürk", GROUP_NEWS, "HaberturkTV.tr", ("haberturk.com",), ("https://tv.haberturk.com/canli-yayin", "https://www.haberturk.com/canliyayin")),
    ChannelSpec("Halk TV", GROUP_NEWS, "HalkTV.tr", ("halktv.com.tr",), ("https://halktv.com.tr/canli-yayin",)),
    ChannelSpec("Sözcü TV", GROUP_NEWS, "SozcuTV.tr", ("szctv.com.tr", "sozcu.com.tr"), ("https://www.szctv.com.tr/canli-yayin-izle", "https://www.sozcu.com.tr/canli-yayin")),
    ChannelSpec("A Haber", GROUP_NEWS, "AHaber.tr", ("ahaber.com.tr",), ("https://www.ahaber.com.tr/canli-yayin",)),
    ChannelSpec("Haber Global", GROUP_NEWS, "HaberGlobal.tr", ("haberglobal.com.tr", "haberglobal.com"), ("https://haberglobal.com.tr/canli-yayin",)),
    ChannelSpec("TGRT Haber", GROUP_NEWS, "TGRTHaber.tr", ("tgrthaber.com", "tgrthaber.com.tr"), ("https://www.tgrthaber.com/canli-yayin",)),
    ChannelSpec("TV100", GROUP_NEWS, "TV100.tr", ("tv100.com",), ("https://www.tv100.com/canli-yayin",)),
    ChannelSpec("24 TV", GROUP_NEWS, "24TV.tr", ("yirmidort.tv",), ("https://www.yirmidort.tv/canli-tv",)),
    ChannelSpec("TVNET", GROUP_NEWS, "TVNET.tr", ("tvnet.com.tr",), ("https://www.tvnet.com.tr/canli-yayin",)),
    ChannelSpec("Bloomberg HT", GROUP_NEWS, "BloombergHT.tr", ("bloomberght.com",), ("https://www.bloomberght.com/tv",)),
    ChannelSpec("Ekotürk", GROUP_NEWS, "Ekoturk.tr", ("ekoturk.com",), ("https://www.ekoturk.com/canli-yayin",)),
    ChannelSpec("CNBC-e", GROUP_NEWS, "CNBCe.tr", ("cnbce.com",), ("https://www.cnbce.com/canli-yayin",)),
    ChannelSpec("GZT", GROUP_NEWS, "GZT.tr", ("gzt.com",), ("https://www.gzt.com/canli-yayin",)),
    ChannelSpec("TRT World", GROUP_NEWS, "TRTWorld.tr", ("trt.com.tr", "trtworld.com"), ("https://www.trtworld.com/live",), ("TRT World",)),
    # Spor
    ChannelSpec("TRT Spor", GROUP_SPORTS, "TRTSpor.tr", ("trt.com.tr", "trtspor.com.tr"), ("https://www.trtspor.com.tr/canli-yayin-izle/trt-spor",), ("TRT Spor Ⓖ",)),
    ChannelSpec("TRT Spor Yıldız", GROUP_SPORTS, "TRTSporYildiz.tr", ("trt.com.tr", "trtspor.com.tr"), ("https://www.trtspor.com.tr/canli-yayin-izle/trt-spor-yildiz",), ("TRT Spor 2 Ⓖ",)),
    ChannelSpec("A Spor", GROUP_SPORTS, "ASpor.tr", ("aspor.com.tr",), ("https://www.aspor.com.tr/canli-yayin",)),
    ChannelSpec("beIN Sports Haber", GROUP_SPORTS, "beINSportsHaber.tr", ("beinsports.com.tr",), ("https://beinsports.com.tr/canli-yayin",)),
    ChannelSpec("FB TV", GROUP_SPORTS, "FBTV.tr", ("fenerbahce.org", "fbtv.com.tr"), ("https://www.fenerbahce.org/fbtv",)),
    # Çocuk
    ChannelSpec("TRT Çocuk", GROUP_KIDS, "TRTCocuk.tr", ("trt.com.tr", "trtcocuk.net.tr"), ("https://www.trtcocuk.net.tr/canli-yayin",), ("TRT Çocuk",)),
    ChannelSpec("Minika Çocuk", GROUP_KIDS, "MinikaCocuk.tr", ("minikacocuk.com.tr",), ("https://www.minikacocuk.com.tr/canli-yayin",)),
    ChannelSpec("Minika Go", GROUP_KIDS, "MinikaGo.tr", ("minikago.com.tr",), ("https://www.minikago.com.tr/canli-yayin",)),
    # Belgesel & Kültür
    ChannelSpec("TRT Belgesel", GROUP_DOCUMENTARY, "TRTBelgesel.tr", ("trt.com.tr", "trtbelgesel.com.tr"), ("https://www.trtbelgesel.com.tr/canli-yayin",), ("TRT Belgesel",)),
    ChannelSpec("TRT Avaz", GROUP_DOCUMENTARY, "TRTAvaz.tr", ("trt.com.tr", "trtavaz.com.tr"), ("https://www.trtavaz.com.tr/canli-yayin",), ("TRT Avaz",)),
    ChannelSpec("TRT Türk", GROUP_DOCUMENTARY, "TRTTurk.tr", ("trt.com.tr", "trtturk.com.tr"), ("https://www.trtturk.com.tr/canli-yayin",), ("TRT Türk",)),
    ChannelSpec("TLC", GROUP_DOCUMENTARY, "TLC.tr", ("tlctv.com.tr",), ("https://www.tlctv.com.tr/canli-izle",)),
    ChannelSpec("DMAX", GROUP_DOCUMENTARY, "DMAX.tr", ("dmax.com.tr",), ("https://www.dmax.com.tr/canli-izle",)),
    # Müzik
    ChannelSpec("TRT Müzik", GROUP_MUSIC, "TRTMuzik.tr", ("trt.com.tr", "trtmuzik.net.tr"), ("https://www.trtmuzik.net.tr/canli-yayin",), ("TRT Müzik",)),
    ChannelSpec("Kral Pop TV", GROUP_MUSIC, "KralPopTV.tr", ("kralmuzik.com.tr",), ("https://www.kralmuzik.com.tr/tv/kral-pop-tv",)),
    ChannelSpec("Power Türk TV", GROUP_MUSIC, "PowerTurkTV.tr", ("powerapp.com.tr",), ("https://www.powerapp.com.tr/powerturk/",)),
    ChannelSpec("Number1 TV", GROUP_MUSIC, "Number1TV.tr", ("numberone.com.tr",), ("https://www.numberone.com.tr/canli-yayin",)),
]

GEO_BLOCK_ERROR_MARKER = "403"
# Gözetimsiz çalışmada: kanal sayısı öncekinin bu oranının altına düşerse gist güncellenmez
PUBLISH_MIN_RETAINED_RATIO = 0.7
STATUS_ADDED = "eklendi"
STATUS_EXPIRING = "süreli"
STATUS_NO_OFFICIAL_SOURCE = "resmi kaynak yok"
STATUS_NOT_WORKING = "çalışmıyor"


# ---------------------------------------------------------------------------
# Veri yapıları
# ---------------------------------------------------------------------------
@dataclass
class StreamCandidate:
    url: str
    source_label: str
    source_priority: int
    resolution_height: int = DEFAULT_RESOLUTION_HEIGHT
    is_not_24_7: bool = False
    user_agent: str | None = None
    referrer: str | None = None
    had_session_params: bool = False   # reklam/oturum parametreleri soyuldu mu
    has_stale_signature: bool = False  # süresi geçmiş ama denetlenmeyen imza

    @property
    def host(self) -> str:
        return (urlparse(self.url).hostname or "").lower()

    def ranking_key(self) -> tuple:
        is_trt_own_domain = self.host.endswith(TRT_OWN_DOMAIN_SUFFIX)
        return (self.source_priority, not is_trt_own_domain, -self.resolution_height, self.is_not_24_7)


@dataclass
class ChannelResult:
    spec: ChannelSpec
    status: str = STATUS_NO_OFFICIAL_SOURCE
    chosen: StreamCandidate | None = None
    expiring_urls: list[str] = field(default_factory=list)
    rejected_notes: list[str] = field(default_factory=list)
    tvg_logo: str = ""


# ---------------------------------------------------------------------------
# Yardımcılar
# ---------------------------------------------------------------------------
def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def fetch_text(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": BROWSER_USER_AGENT})
    with urllib.request.urlopen(request, timeout=HTTP_FETCH_TIMEOUT_SECONDS) as response:
        return response.read().decode("utf-8", errors="replace")


def host_matches(host: str, suffixes) -> bool:
    return any(host == suffix or host.endswith("." + suffix) for suffix in suffixes)


def host_rejection_reason(host: str, spec: ChannelSpec, captured_on_official_page: bool) -> str | None:
    """Kural 1. None dönerse host kabul edilir."""
    if not host:
        return "host yok"
    try:
        ipaddress.ip_address(host)
        return "çıplak IP"
    except ValueError:
        pass
    if host.endswith(SUSPICIOUS_TLDS):
        return "şüpheli TLD"
    if host_matches(host, BLOCKED_HOST_SUFFIXES):
        return "yasaklı restream kaynağı"
    if host_matches(host, TRUSTED_CDN_SUFFIXES) or host_matches(host, spec.owned_domains):
        return None
    if captured_on_official_page:
        return None  # yayıncının kendi oynatıcısının kullandığı CDN
    return "beyaz listede değil"


def is_expiring_url(url: str) -> bool:
    parsed = urlparse(url)
    query_names = {name.lower() for name, _ in parse_qsl(parsed.query, keep_blank_values=True)}
    if query_names & EXPIRING_TOKEN_PARAM_NAMES:
        return True
    return bool(EXPIRING_TOKEN_PATH_PATTERN.search(parsed.path))


def has_stale_expiry(url: str) -> bool:
    """Son kullanma zamanı zaten geçmişse True. Böyle bir link hâlâ çalışıyorsa
    sunucu süreyi denetlemiyor demektir → fiilen kalıcı."""
    now = time.time()
    for name, value in parse_qsl(urlparse(url).query, keep_blank_values=True):
        if name.lower() in EXPIRY_TIMESTAMP_PARAM_NAMES and value.isdigit() and int(value) < now:
            return True
    return False


def strip_ad_tracking_params(url: str) -> str:
    parsed = urlparse(url)
    kept_params = [
        (name, value) for name, value in parse_qsl(parsed.query, keep_blank_values=True)
        if name.lower() not in AD_TRACKING_PARAM_NAMES and not name.lower().startswith(AD_TRACKING_PARAM_PREFIXES)
    ]
    return parsed._replace(query=urlencode(kept_params)).geturl()


def normalize_tvg_id(raw_tvg_id: str) -> str:
    return raw_tvg_id.split("@", 1)[0]


# ---------------------------------------------------------------------------
# Aday toplama
# ---------------------------------------------------------------------------
def parse_iptv_org_m3u(m3u_text: str) -> dict[str, list[StreamCandidate]]:
    candidates_by_tvg_id: dict[str, list[StreamCandidate]] = {}
    pending_info_line: str | None = None
    pending_user_agent: str | None = None
    pending_referrer: str | None = None
    for raw_line in m3u_text.splitlines():
        line = raw_line.strip()
        if line.startswith("#EXTINF"):
            pending_info_line, pending_user_agent, pending_referrer = line, None, None
        elif line.startswith("#EXTVLCOPT:http-user-agent="):
            pending_user_agent = line.split("=", 1)[1]
        elif line.startswith("#EXTVLCOPT:http-referrer="):
            pending_referrer = line.split("=", 1)[1]
        elif line and not line.startswith("#") and pending_info_line:
            tvg_id_match = re.search(r'tvg-id="([^"]*)"', pending_info_line)
            tvg_id = normalize_tvg_id(tvg_id_match.group(1)) if tvg_id_match else ""
            title = pending_info_line.rsplit(",", 1)[-1]
            resolution_match = RESOLUTION_PATTERN.search(title)
            candidates_by_tvg_id.setdefault(tvg_id, []).append(StreamCandidate(
                url=line,
                source_label="iptv-org",
                source_priority=SOURCE_PRIORITY_IPTV_ORG,
                resolution_height=int(resolution_match.group(1)) if resolution_match else DEFAULT_RESOLUTION_HEIGHT,
                is_not_24_7=NOT_24_7_MARKER in title,
                user_agent=pending_user_agent,
                referrer=pending_referrer,
            ))
            pending_info_line = None
    return candidates_by_tvg_id


def parse_free_tv_markdown(markdown_text: str) -> dict[str, str]:
    url_by_channel_name: dict[str, str] = {}
    row_pattern = re.compile(r"^\|\s*\d+\s*\|\s*(.+?)\s*\|\s*\[>\]\((\S+?)\)")
    for line in markdown_text.splitlines():
        row_match = row_pattern.match(line)
        if row_match:
            url_by_channel_name[row_match.group(1).strip()] = row_match.group(2)
    return url_by_channel_name


def collect_list_candidates(spec: ChannelSpec, iptv_org_candidates, free_tv_urls) -> list[StreamCandidate]:
    candidates = [
        StreamCandidate(url=free_tv_urls[name], source_label="Free-TV", source_priority=SOURCE_PRIORITY_FREE_TV)
        for name in spec.free_tv_names if name in free_tv_urls
    ]
    candidates += [
        StreamCandidate(url=url, source_label="resmi site", source_priority=SOURCE_PRIORITY_OFFICIAL_PAGE)
        for url in spec.known_official_urls
    ]
    if spec.tvg_id:
        candidates.extend(iptv_org_candidates.get(spec.tvg_id, []))
    return candidates


# ---------------------------------------------------------------------------
# Resmi sayfadan yakalama (Playwright)
# ---------------------------------------------------------------------------
def capture_m3u8_from_official_pages(specs: list[ChannelSpec]) -> dict[str, list[StreamCandidate]]:
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        log("! playwright yüklü değil, resmi sayfa taraması atlandı")
        return {}

    captured_by_channel: dict[str, list[StreamCandidate]] = {}
    with sync_playwright() as playwright:
        try:
            browser = playwright.chromium.launch(channel=BROWSER_CHANNEL, headless=True)
        except Exception:
            browser = playwright.chromium.launch(headless=True)
        for spec in specs:
            captured_urls: list[str] = []
            for page_url in spec.official_live_pages:
                page_host = (urlparse(page_url).hostname or "").lower()
                if not host_matches(page_host, spec.owned_domains):
                    log(f"  ! {spec.display_name}: {page_host} kanalın domaini değil, atlandı")
                    continue
                log(f"  → {spec.display_name}: {page_url}")
                context = browser.new_context(user_agent=BROWSER_USER_AGENT, locale="tr-TR", viewport=BROWSER_VIEWPORT)
                page = context.new_page()
                page.on("request", lambda request: captured_urls.append(request.url)
                        if ".m3u8" in request.url.lower() else None)
                try:
                    page.goto(page_url, timeout=BROWSER_PAGE_LOAD_TIMEOUT_MS, wait_until="domcontentloaded")
                    page.wait_for_timeout(BROWSER_PLAYER_READY_WAIT_SECONDS * 1000)
                    click_play_buttons(page)
                    page.wait_for_timeout(BROWSER_CAPTURE_WAIT_SECONDS * 1000)
                    captured_urls.extend(find_embedded_m3u8_urls(page))
                except Exception as error:
                    log(f"    sayfa hatası: {type(error).__name__}")
                finally:
                    context.close()
                if captured_urls:
                    break
            stripped_by_url = {strip_ad_tracking_params(url): url for url in captured_urls}
            captured_by_channel[spec.display_name] = [
                StreamCandidate(url=stripped_url, source_label="resmi site", source_priority=SOURCE_PRIORITY_OFFICIAL_PAGE,
                                user_agent=BROWSER_USER_AGENT, referrer=spec.official_live_pages[0],
                                had_session_params=stripped_url != original_url)
                for stripped_url, original_url in stripped_by_url.items()
            ]
            unique_urls = list(stripped_by_url)
            log(f"    {len(unique_urls)} m3u8 yakalandı")
        browser.close()
    return captured_by_channel


def find_embedded_m3u8_urls(page) -> list[str]:
    embedded_urls: list[str] = []
    for frame in page.frames:
        try:
            frame_html = frame.content()
        except Exception:
            continue
        embedded_urls += [match.replace("\\/", "/").replace("&amp;", "&")
                          for match in EMBEDDED_M3U8_PATTERN.findall(frame_html)]
    return embedded_urls


def click_play_buttons(page) -> None:
    for frame in page.frames:
        for selector in PLAY_BUTTON_SELECTORS:
            try:
                element = frame.query_selector(selector)
                if element and element.is_visible():
                    element.click(timeout=BROWSER_CLICK_TIMEOUT_MS, force=True)
            except Exception:
                continue
    try:
        page.mouse.click(*BROWSER_PLAYER_AREA_CLICK_POSITION)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# ffprobe doğrulama
# ---------------------------------------------------------------------------
def probe_stream(candidate: StreamCandidate, send_headers: bool) -> tuple[bool, int, str]:
    command = [
        "ffprobe", "-v", "error",
        "-rw_timeout", str(FFPROBE_NETWORK_TIMEOUT_MICROSECONDS),
        "-analyzeduration", str(FFPROBE_ANALYZE_DURATION_MICROSECONDS),
        "-show_entries", "stream=codec_type,height", "-of", "json",
    ]
    if send_headers and candidate.user_agent:
        command += ["-user_agent", candidate.user_agent]
    if send_headers and candidate.referrer:
        command += ["-headers", f"Referer: {candidate.referrer}\r\n"]
    command.append(candidate.url)
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=FFPROBE_PROCESS_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        return False, 0, "timeout"
    try:
        streams = json.loads(completed.stdout or "{}").get("streams", [])
    except json.JSONDecodeError:
        streams = []
    codec_types = {stream.get("codec_type") for stream in streams}
    max_height = max((stream.get("height") or 0 for stream in streams), default=0)
    if {"video", "audio"} <= codec_types:
        return True, max_height, "ok"
    error_line = (completed.stderr.strip().splitlines() or ["video/ses yok"])[-1]
    return False, 0, error_line[:120]


def fetch_playlist_text(url: str, candidate: StreamCandidate) -> str:
    headers = {"User-Agent": candidate.user_agent or BROWSER_USER_AGENT}
    if candidate.referrer:
        headers["Referer"] = candidate.referrer
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=HTTP_FETCH_TIMEOUT_SECONDS) as response:
        return response.read().decode("utf-8", errors="replace")


def is_live_playlist(candidate: StreamCandidate) -> bool:
    """VOD (ör. reklam/klip) playlist'leri #EXT-X-ENDLIST içerir; canlı yayınlar içermez."""
    try:
        playlist_text = fetch_playlist_text(candidate.url, candidate)
        if HLS_VARIANT_MARKER in playlist_text:
            lines = playlist_text.splitlines()
            variant_index = next(i for i, line in enumerate(lines) if line.startswith(HLS_VARIANT_MARKER))
            variant_uri = next(line.strip() for line in lines[variant_index + 1:] if line.strip() and not line.startswith("#"))
            playlist_text = fetch_playlist_text(urljoin(candidate.url, variant_uri), candidate)
    except Exception:
        return True  # playlist okunamadıysa karar ffprobe'a kalsın
    return HLS_VOD_END_MARKER not in playlist_text


def verify_candidate(candidate: StreamCandidate) -> tuple[bool, str]:
    """Önce başlıksız dene; olmazsa (varsa) user-agent/referrer ile dene. Sonra canlılık kontrolü."""
    works, height, detail = probe_stream(candidate, send_headers=False)
    needs_headers = False
    if not works and (candidate.user_agent or candidate.referrer):
        works, height, detail = probe_stream(candidate, send_headers=True)
        needs_headers = works
    if works and not needs_headers and candidate.source_priority == SOURCE_PRIORITY_OFFICIAL_PAGE:
        candidate.user_agent = candidate.referrer = None  # tarayıcı başlıkları gerekmiyor
    if works and not is_live_playlist(candidate):
        return False, "canlı değil (VOD/reklam)"
    if works and height:
        candidate.resolution_height = height
    return works, detail


# ---------------------------------------------------------------------------
# Kanal çözümleme
# ---------------------------------------------------------------------------
def screen_candidates(spec: ChannelSpec, candidates: list[StreamCandidate], result: ChannelResult) -> list[StreamCandidate]:
    accepted: list[StreamCandidate] = []
    seen_urls: set[str] = set()
    for candidate in candidates:
        if candidate.url in seen_urls:
            continue
        seen_urls.add(candidate.url)
        captured_on_official_page = candidate.source_priority == SOURCE_PRIORITY_OFFICIAL_PAGE
        rejection = host_rejection_reason(candidate.host, spec, captured_on_official_page)
        if rejection:
            result.rejected_notes.append(f"{candidate.host}: {rejection}")
            continue
        if is_expiring_url(candidate.url):
            if not has_stale_expiry(candidate.url):
                result.expiring_urls.append(candidate.url)
                continue
            candidate.has_stale_signature = True
        accepted.append(candidate)
    return sorted(accepted, key=StreamCandidate.ranking_key)


def verify_in_parallel(candidates: list[StreamCandidate]) -> dict[str, tuple[bool, str]]:
    with concurrent.futures.ThreadPoolExecutor(max_workers=PARALLEL_PROBE_WORKERS) as executor:
        outcomes = executor.map(verify_candidate, candidates)
        return {candidate.url: outcome for candidate, outcome in zip(candidates, outcomes)}


def resolve_channels(results: list[ChannelResult], candidates_by_channel: dict[str, list[StreamCandidate]]) -> None:
    screened_by_channel = {
        result.spec.display_name: screen_candidates(result.spec, candidates_by_channel.get(result.spec.display_name, []), result)
        for result in results if result.chosen is None
    }
    all_candidates = [candidate for screened in screened_by_channel.values() for candidate in screened]
    log(f"ffprobe ile {len(all_candidates)} aday test ediliyor…")
    outcomes = verify_in_parallel(all_candidates)
    for result in results:
        screened = screened_by_channel.get(result.spec.display_name)
        if screened is None:
            continue
        working = [candidate for candidate in screened if outcomes[candidate.url][0]]
        if working:
            result.chosen = sorted(working, key=StreamCandidate.ranking_key)[0]
            result.status = STATUS_ADDED
        elif any(candidate.had_session_params for candidate in screened):
            # oturum parametresi olmadan açılmıyor → fiilen süreli erişim kontrolü
            result.status = STATUS_EXPIRING
            result.expiring_urls += [candidate.url for candidate in screened if candidate.had_session_params]
        elif screened:
            result.status = STATUS_NOT_WORKING
            result.rejected_notes += [f"{c.host}: {outcomes[c.url][1]}" for c in screened]
        elif result.expiring_urls:
            result.status = STATUS_EXPIRING
        else:
            result.status = STATUS_NO_OFFICIAL_SOURCE


def recheck_chosen(results: list[ChannelResult]) -> None:
    chosen_results = [result for result in results if result.chosen]
    log(f"{RECHECK_DELAY_SECONDS} sn sonra seçilen {len(chosen_results)} link tekrar test ediliyor…")
    time.sleep(RECHECK_DELAY_SECONDS)
    outcomes = verify_in_parallel([result.chosen for result in chosen_results])
    for result in chosen_results:
        works, detail = outcomes[result.chosen.url]
        if not works:
            result.rejected_notes.append(f"{result.chosen.host}: ikinci testte başarısız ({detail})")
            result.chosen = None
            result.status = STATUS_NOT_WORKING


def load_previous_gist_entries(gist_id: str) -> dict[str, str]:
    """Önceki gist'teki kanal adı → URL eşlemesi."""
    content = run_gh(["api", f"gists/{gist_id}", "--jq", f'.files["{OUTPUT_PLAYLIST_NAME}"].content'])
    url_by_name: dict[str, str] = {}
    current_name: str | None = None
    for line in content.splitlines():
        if line.startswith("#EXTINF"):
            name_match = re.search(r'tvg-name="([^"]*)"', line)  # "TV8,5" gibi virgüllü adlar için
            current_name = name_match.group(1) if name_match else line.rsplit(",", 1)[-1].strip()
        elif line and not line.startswith("#") and current_name:
            url_by_name[current_name] = line.strip()
            current_name = None
    return url_by_name


def keep_geo_blocked_channels(results: list[ChannelResult], gist_id: str) -> None:
    """Yurt dışındaki CI'da 403 (geo) veren ama önceki listede olan kanalları koru."""
    previous_urls = load_previous_gist_entries(gist_id)
    for result in results:
        previous_url = previous_urls.get(result.spec.display_name)
        if result.chosen or not previous_url or is_expiring_url(previous_url):
            continue
        previous_candidate = StreamCandidate(url=previous_url, source_label="önceki liste (geo)",
                                             source_priority=SOURCE_PRIORITY_IPTV_ORG)
        if host_rejection_reason(previous_candidate.host, result.spec, captured_on_official_page=False):
            continue
        works, detail = verify_candidate(previous_candidate)
        if works or GEO_BLOCK_ERROR_MARKER in detail:
            result.chosen, result.status = previous_candidate, STATUS_ADDED
            log(f"  geo koruması: {result.spec.display_name} tutuldu ({detail})")


# ---------------------------------------------------------------------------
# Logo ve çıktı
# ---------------------------------------------------------------------------
def pick_logo_urls(logos: list[dict]) -> dict[str, str]:
    best_logo_by_channel: dict[str, dict] = {}
    for logo in logos:
        channel_id = logo.get("channel")
        current_best = best_logo_by_channel.get(channel_id)
        candidate_key = (logo.get("feed") is None, logo.get("format") == "PNG", logo.get("width") or 0)
        if current_best is None or candidate_key > current_best["key"]:
            best_logo_by_channel[channel_id] = {"key": candidate_key, "url": logo.get("url", "")}
    return {channel_id: entry["url"] for channel_id, entry in best_logo_by_channel.items()}


def write_playlist(results: list[ChannelResult]) -> None:
    lines = ["#EXTM3U"]
    for result in results:
        if not result.chosen:
            continue
        spec = result.spec
        group_attribute = f' group-title="{spec.group_title}"' if INCLUDE_GROUP_TITLE else ""
        lines.append(
            f'#EXTINF:-1 tvg-id="{spec.tvg_id}" tvg-name="{spec.display_name}" '
            f'tvg-logo="{result.tvg_logo}"{group_attribute},{spec.display_name}'
        )
        if result.chosen.user_agent:
            lines.append(f"#EXTVLCOPT:http-user-agent={result.chosen.user_agent}")
        if result.chosen.referrer:
            lines.append(f"#EXTVLCOPT:http-referrer={result.chosen.referrer}")
        lines.append(result.chosen.url)
    OUTPUT_PLAYLIST_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_report(results: list[ChannelResult], raw_url: str | None) -> None:
    lines = [f"# Rapor ({time.strftime('%Y-%m-%d %H:%M')})", "", "| Kanal | Durum | Host | Kaynak |", "|---|---|---|---|"]
    for result in results:
        host = result.chosen.host if result.chosen else "—"
        source = result.chosen.source_label if result.chosen else "—"
        if result.chosen and result.chosen.has_stale_signature:
            source += " (sabit imza, süre denetlenmiyor)"
        lines.append(f"| {result.spec.display_name} | {result.status} | {host} | {source} |")
    lines += ["", "## Süreli (token'lı) linkler — listeye ALINMADI", ""]
    for result in results:
        for url in result.expiring_urls:
            parsed = urlparse(url)
            param_names = ", ".join(name for name, _ in parse_qsl(parsed.query, keep_blank_values=True)) or "yol içinde"
            lines.append(f"- **{result.spec.display_name}**: `{parsed.hostname}{parsed.path}` — parametreler: {param_names}")
    lines += ["", "## Elenen adaylar", ""]
    for result in results:
        if result.rejected_notes and result.status != STATUS_ADDED:
            lines.append(f"- **{result.spec.display_name}**: " + "; ".join(dict.fromkeys(result.rejected_notes)))
    if raw_url and not RUNNING_IN_CI:
        lines += ["", f"Gist raw URL: {raw_url}"]
    OUTPUT_REPORT_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# Gist
# ---------------------------------------------------------------------------
def run_gh(arguments: list[str], stdin_text: str | None = None) -> str:
    completed = subprocess.run(["gh", *arguments], input=stdin_text, capture_output=True, text=True)
    if completed.returncode != 0:
        # komut satırı gist id içerdiği için hatada yalnızca gh'nin mesajı gösterilir
        raise RuntimeError(f"gh {arguments[0]} başarısız: {completed.stderr.strip()[-200:]}")
    return completed.stdout.strip()


def publish_gist(explicit_gist_id: str | None) -> str:
    """`gh gist create/edit` .m3u'yu ikili dosya sandığı için doğrudan GitHub API kullanılır."""
    gist_id = explicit_gist_id or (GIST_ID_STATE_PATH.read_text().strip() if GIST_ID_STATE_PATH.exists() else "")
    payload = {
        "description": GIST_DESCRIPTION,
        "files": {OUTPUT_PLAYLIST_NAME: {"content": OUTPUT_PLAYLIST_PATH.read_text(encoding="utf-8")}},
    }
    if gist_id:
        run_gh(["api", "-X", "PATCH", f"gists/{gist_id}", "--input", "-", "--jq", ".id"], json.dumps(payload))
        log("Gist güncellendi" if RUNNING_IN_CI else f"Gist güncellendi: {gist_id}")
    else:
        payload["public"] = False
        gist_id = run_gh(["api", "-X", "POST", "gists", "--input", "-", "--jq", ".id"], json.dumps(payload))
        log("Secret gist oluşturuldu" if RUNNING_IN_CI else f"Secret gist oluşturuldu: {gist_id}")
    GIST_ID_STATE_PATH.write_text(gist_id + "\n")
    username = run_gh(["api", "user", "--jq", ".login"])
    return f"https://gist.githubusercontent.com/{username}/{gist_id}/raw/{OUTPUT_PLAYLIST_NAME}"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--publish", action="store_true", help="secret gist oluştur / güncelle")
    parser.add_argument("--gist-id", help="güncellenecek gist id (varsayılan: .gist_id dosyası)")
    parser.add_argument("--no-browser", action="store_true", help="resmi sayfa taramasını (Playwright) atla")
    parser.add_argument("--keep-geo-blocked", action="store_true",
                        help="403 veren kanalı önceki gist'te varsa tut (yurt dışı CI için)")
    parser.add_argument("--no-recheck", action="store_true", help="ikinci doğrulama turunu atla")
    arguments = parser.parse_args()

    log("Kaynaklar indiriliyor…")
    iptv_org_candidates = parse_iptv_org_m3u(fetch_text(IPTV_ORG_TR_M3U_URL))
    free_tv_urls = parse_free_tv_markdown(fetch_text(FREE_TV_TURKEY_MD_URL))
    logo_by_channel = pick_logo_urls(json.loads(fetch_text(IPTV_ORG_LOGOS_API_URL)))
    known_channel_ids = {channel["id"] for channel in json.loads(fetch_text(IPTV_ORG_CHANNELS_API_URL))}

    results = [ChannelResult(spec=spec) for spec in CHANNEL_SPECS]
    for result in results:
        if result.spec.tvg_id and result.spec.tvg_id not in known_channel_ids:
            log(f"! {result.spec.tvg_id} iptv-org'da yok")
        result.tvg_logo = logo_by_channel.get(result.spec.tvg_id, "")

    list_candidates = {
        result.spec.display_name: collect_list_candidates(result.spec, iptv_org_candidates, free_tv_urls)
        for result in results
    }
    resolve_channels(results, list_candidates)

    missing_specs = [result.spec for result in results if result.chosen is None]
    if missing_specs and not arguments.no_browser:
        log(f"Resmi sitelerden {len(missing_specs)} kanal taranıyor…")
        captured = capture_m3u8_from_official_pages(missing_specs)
        missing_results = [result for result in results if result.chosen is None]
        status_before_capture = {result.spec.display_name: result.status for result in missing_results}
        resolve_channels(missing_results, captured)
        for result in missing_results:  # sayfada hiçbir şey bulunamadıysa önceki (liste) durumunu koru
            if result.chosen is None and not captured.get(result.spec.display_name):
                result.status = status_before_capture[result.spec.display_name]

    if not arguments.no_recheck:
        recheck_chosen(results)

    stored_gist_id = arguments.gist_id or (GIST_ID_STATE_PATH.read_text().strip() if GIST_ID_STATE_PATH.exists() else "")
    if arguments.keep_geo_blocked and stored_gist_id:
        keep_geo_blocked_channels(results, stored_gist_id)

    write_playlist(results)
    added_count = sum(result.status == STATUS_ADDED for result in results)
    raw_url = None
    if arguments.publish:
        previous_count = len(load_previous_gist_entries(stored_gist_id)) if stored_gist_id else 0
        if added_count < previous_count * PUBLISH_MIN_RETAINED_RATIO:
            log(f"! {added_count} kanal bulundu (önceki: {previous_count}); ağ sorunu olabilir, gist güncellenmedi")
        else:
            raw_url = publish_gist(arguments.gist_id)
    write_report(results, raw_url)

    log(f"\n{added_count}/{len(results)} kanal eklendi → {OUTPUT_PLAYLIST_PATH.name}, rapor → {OUTPUT_REPORT_PATH.name}")
    if raw_url and not RUNNING_IN_CI:
        print(raw_url)
    return 0


if __name__ == "__main__":
    sys.exit(main())
