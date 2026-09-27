#!/usr/bin/env python3
"""Süreli (ama IP'ye bağlı olmayan) resmi linkleri gist'te günceller.

DMAX, TLC ve Beyaz TV'nin resmi siteleri kısa ömürlü linkler veriyor; bu linkler
alındıkları IP'ye bağlı değil. GitHub Actions bu script'i düzenli çalıştırır:
taze linkleri alır ve gist'te yalnızca bu kanalların satırlarını değiştirir.
Linkler ve gist id'si loglara yazılmaz (public repo).
"""

from __future__ import annotations

import argparse
import json
import re
import sys

from build_playlist import (
    CHANNEL_SPECS,
    CI_REFRESHED_CHANNELS,
    GIST_ID_STATE_PATH,
    IPTV_ORG_LOGOS_API_URL,
    OUTPUT_PLAYLIST_NAME,
    fetch_text,
    log,
    pick_logo_urls,
    run_gh,
)
from live_resolver import RESOLVED_CHANNELS, capture_master_playlist, link_responds

PLAYLIST_HEADER = "#EXTM3U"
MAX_CAPTURE_ATTEMPTS = 2   # oynatıcı ilk denemede başlamayabiliyor
TVG_NAME_PATTERN = re.compile(r'tvg-name="([^"]*)"')


def capture_fresh_urls() -> dict[str, str]:
    from playwright.sync_api import sync_playwright

    fresh_url_by_name: dict[str, str] = {}
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        for channel in RESOLVED_CHANNELS:
            if channel.display_name not in CI_REFRESHED_CHANNELS:
                continue
            url = None
            for _ in range(MAX_CAPTURE_ATTEMPTS):
                url = capture_master_playlist(browser, channel)
                if url and link_responds(url):
                    break
                url = None
            if url:
                fresh_url_by_name[channel.display_name] = url
                log(f"{channel.display_name}: taze link alındı")
            else:
                log(f"{channel.display_name}: link alınamadı, gist'teki eski satır korunuyor")
        browser.close()
    return fresh_url_by_name


def parse_playlist_entries(playlist_text: str) -> dict[str, list[str]]:
    """tvg-name → [#EXTINF, (#EXTVLCOPT...), url] satırları."""
    entries: dict[str, list[str]] = {}
    current_name: str | None = None
    for line in playlist_text.splitlines():
        if line.startswith("#EXTINF"):
            name_match = TVG_NAME_PATTERN.search(line)
            current_name = name_match.group(1) if name_match else line.rsplit(",", 1)[-1]
            entries[current_name] = [line]
        elif current_name and line.strip():
            entries[current_name].append(line)
    return entries


def build_entry_lines(channel_name: str, url: str, existing_lines: list[str] | None, logo_by_channel: dict[str, str]) -> list[str]:
    if existing_lines:
        return [*existing_lines[:-1], url]  # #EXTINF satırını koru, yalnızca linki değiştir
    spec = next(spec for spec in CHANNEL_SPECS if spec.display_name == channel_name)
    info_line = (f'#EXTINF:-1 tvg-id="{spec.tvg_id}" tvg-name="{spec.display_name}" '
                 f'tvg-logo="{logo_by_channel.get(spec.tvg_id, "")}",{spec.display_name}')
    return [info_line, url]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--gist-id", help="güncellenecek gist id (varsayılan: .gist_id dosyası)")
    arguments = parser.parse_args()
    gist_id = arguments.gist_id or GIST_ID_STATE_PATH.read_text().strip()

    fresh_url_by_name = capture_fresh_urls()
    if not fresh_url_by_name:
        log("Hiç taze link alınamadı, gist değiştirilmedi")
        return 1

    current_text = run_gh(["api", f"gists/{gist_id}", "--jq", f'.files["{OUTPUT_PLAYLIST_NAME}"].content'])
    entries = parse_playlist_entries(current_text)
    needs_logos = any(name not in entries for name in fresh_url_by_name)
    logo_by_channel = pick_logo_urls(json.loads(fetch_text(IPTV_ORG_LOGOS_API_URL))) if needs_logos else {}
    for channel_name, url in fresh_url_by_name.items():
        entries[channel_name] = build_entry_lines(channel_name, url, entries.get(channel_name), logo_by_channel)

    ordered_names = [spec.display_name for spec in CHANNEL_SPECS if spec.display_name in entries]
    ordered_names += [name for name in entries if name not in ordered_names]  # listede olmayanlar sona
    new_text = "\n".join([PLAYLIST_HEADER, *(line for name in ordered_names for line in entries[name])]) + "\n"

    payload = {"files": {OUTPUT_PLAYLIST_NAME: {"content": new_text}}}
    run_gh(["api", "-X", "PATCH", f"gists/{gist_id}", "--input", "-", "--jq", ".id"], json.dumps(payload))
    log(f"Gist'te {len(fresh_url_by_name)} kanalın linki güncellendi")
    return 0


if __name__ == "__main__":
    sys.exit(main())
