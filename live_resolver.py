#!/usr/bin/env python3
"""Süreli (token'lı) resmi yayınlar için yönlendirici.

DMAX, TLC, Beyaz TV ve CNN Türk'ün resmi siteleri yalnızca kısa süre geçerli
linkler veriyor. Bu sunucu linkleri arka planda resmi sayfalardan taze alır ve
IPTV oynatıcısını 302 ile güncel linke yönlendirir:

    http://<sunucu>:8765/dmax.m3u8
"""

from __future__ import annotations

import base64
import json
import re
import sys
import threading
import time
import urllib.request
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qsl, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_playlist import (  # noqa: E402  (ortak tarayıcı ayarları tek yerde)
    BROWSER_CAPTURE_WAIT_SECONDS,
    BROWSER_CHANNEL,
    BROWSER_PAGE_LOAD_TIMEOUT_MS,
    BROWSER_PLAYER_READY_WAIT_SECONDS,
    BROWSER_USER_AGENT,
    BROWSER_VIEWPORT,
    click_play_buttons,
)

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
RESOLVER_BIND_ADDRESS = "0.0.0.0"
RESOLVER_PORT = 8765
DEFAULT_LINK_LIFETIME_SECONDS = 30 * 60      # token süresi okunamazsa
REFRESH_MARGIN_SECONDS = 10 * 60             # süre dolmadan bu kadar önce yenile
MIN_REFRESH_INTERVAL_SECONDS = 5 * 60
FAILED_CAPTURE_RETRY_SECONDS = 2 * 60
SCHEDULER_TICK_SECONDS = 30
LINK_CHECK_TIMEOUT_SECONDS = 15
HTTP_STATUS_OK = 200
HTTP_STATUS_REDIRECT = 302
HTTP_STATUS_NOT_FOUND = 404
HTTP_STATUS_NOT_READY = 503
EXPIRY_PARAM_NAMES = ("exp", "e", "ex", "expires")


@dataclass(frozen=True)
class ResolvedChannel:
    slug: str
    display_name: str
    official_page_url: str
    master_playlist_pattern: re.Pattern


RESOLVED_CHANNELS = [
    ResolvedChannel("dmax", "DMAX", "https://www.dmax.com.tr/canli-izle", re.compile(r"/dmax/dmax\.m3u8\?")),
    ResolvedChannel("tlc", "TLC", "https://www.tlctv.com.tr/canli-izle", re.compile(r"/tlc/tlc\.m3u8\?")),
    ResolvedChannel("beyaztv", "Beyaz TV", "https://beyaztv.com.tr/canli-yayin", re.compile(r"/beyaztv/beyaztv\.m3u8\?")),
    ResolvedChannel("cnnturk", "CNN Türk", "https://www.cnnturk.com/canli-yayin", re.compile(r"/cnnturknp/playlist\.m3u8\?")),
]
CHANNEL_BY_SLUG = {channel.slug: channel for channel in RESOLVED_CHANNELS}


@dataclass
class CachedLink:
    url: str
    refresh_at: float


link_cache: dict[str, CachedLink] = {}
next_attempt_at: dict[str, float] = {}
cache_lock = threading.Lock()


def log(message: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)


# ---------------------------------------------------------------------------
# Link ömrü
# ---------------------------------------------------------------------------
def read_expiry_timestamp(url: str) -> float | None:
    """JWT token'daki exp ya da e/exp parametresi; yoksa None."""
    for name, value in parse_qsl(urlparse(url).query):
        if name == "token" and value.count(".") == 2:
            try:
                payload_part = value.split(".")[1]
                payload = json.loads(base64.urlsafe_b64decode(payload_part + "=" * (-len(payload_part) % 4)))
                if isinstance(payload.get("exp"), (int, float)):
                    return float(payload["exp"])
            except ValueError:
                pass
        if name in EXPIRY_PARAM_NAMES and value.isdigit():
            return float(value)
    return None


def compute_refresh_time(url: str) -> float:
    now = time.time()
    expiry = read_expiry_timestamp(url)
    if expiry is None or expiry <= now:
        return now + DEFAULT_LINK_LIFETIME_SECONDS
    return now + max(MIN_REFRESH_INTERVAL_SECONDS, expiry - now - REFRESH_MARGIN_SECONDS)


def link_responds(url: str) -> bool:
    request = urllib.request.Request(url, headers={"User-Agent": BROWSER_USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=LINK_CHECK_TIMEOUT_SECONDS) as response:
            return b"#EXTM3U" in response.read(64)
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Resmi sayfadan yakalama (yalnızca arka plan thread'inde; Playwright thread-safe değil)
# ---------------------------------------------------------------------------
def capture_master_playlist(browser, channel: ResolvedChannel) -> str | None:
    captured_urls: list[str] = []
    context = browser.new_context(user_agent=BROWSER_USER_AGENT, locale="tr-TR", viewport=BROWSER_VIEWPORT)
    page = context.new_page()
    page.on("request", lambda request: captured_urls.append(request.url)
            if channel.master_playlist_pattern.search(request.url) else None)
    try:
        page.goto(channel.official_page_url, timeout=BROWSER_PAGE_LOAD_TIMEOUT_MS, wait_until="domcontentloaded")
        page.wait_for_timeout(BROWSER_PLAYER_READY_WAIT_SECONDS * 1000)
        click_play_buttons(page)
        deadline = time.time() + BROWSER_CAPTURE_WAIT_SECONDS
        while not captured_urls and time.time() < deadline:
            page.wait_for_timeout(1000)
    except Exception as error:
        log(f"{channel.display_name}: sayfa hatası {type(error).__name__}")
    finally:
        context.close()
    return captured_urls[-1] if captured_urls else None


def refresh_loop() -> None:
    from playwright.sync_api import sync_playwright

    with sync_playwright() as playwright:
        try:
            browser = playwright.chromium.launch(channel=BROWSER_CHANNEL, headless=True)
        except Exception:
            browser = playwright.chromium.launch(headless=True)
        while True:
            for channel in RESOLVED_CHANNELS:
                now = time.time()
                with cache_lock:
                    cached = link_cache.get(channel.slug)
                is_due = cached is None or now >= cached.refresh_at
                if not is_due or now < next_attempt_at.get(channel.slug, 0):
                    continue
                url = capture_master_playlist(browser, channel)
                if url and link_responds(url):
                    refresh_at = compute_refresh_time(url)
                    with cache_lock:
                        link_cache[channel.slug] = CachedLink(url, refresh_at)
                    log(f"{channel.display_name}: link yenilendi, sonraki {time.strftime('%H:%M', time.localtime(refresh_at))}")
                else:
                    next_attempt_at[channel.slug] = time.time() + FAILED_CAPTURE_RETRY_SECONDS
                    log(f"{channel.display_name}: link alınamadı, {FAILED_CAPTURE_RETRY_SECONDS // 60} dk sonra tekrar")
            time.sleep(SCHEDULER_TICK_SECONDS)


# ---------------------------------------------------------------------------
# HTTP sunucu
# ---------------------------------------------------------------------------
class RedirectHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 (http.server arayüzü)
        request_path = urlparse(self.path).path.strip("/")
        if request_path == "status":
            self.send_status()
            return
        slug = request_path.removesuffix(".m3u8")
        if slug not in CHANNEL_BY_SLUG:
            self.send_error(HTTP_STATUS_NOT_FOUND)
            return
        with cache_lock:
            cached = link_cache.get(slug)
        if cached is None:
            self.send_error(HTTP_STATUS_NOT_READY, "Link henüz hazır değil")
            return
        self.send_response(HTTP_STATUS_REDIRECT)
        self.send_header("Location", cached.url)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def send_status(self) -> None:
        with cache_lock:
            status = {slug: {"hazir": slug in link_cache,
                             "sonraki_yenileme": time.strftime("%H:%M", time.localtime(link_cache[slug].refresh_at))
                             if slug in link_cache else None}
                      for slug in CHANNEL_BY_SLUG}
        body = json.dumps(status, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(HTTP_STATUS_OK)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args) -> None:  # noqa: A002
        log(f"istek: {self.command} {self.path} ({self.client_address[0]})")


def main() -> int:
    threading.Thread(target=refresh_loop, daemon=True).start()
    server = ThreadingHTTPServer((RESOLVER_BIND_ADDRESS, RESOLVER_PORT), RedirectHandler)
    log(f"Yönlendirici: http://{RESOLVER_BIND_ADDRESS}:{RESOLVER_PORT}/<kanal>.m3u8 ({', '.join(CHANNEL_BY_SLUG)})")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
