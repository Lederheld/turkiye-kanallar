#!/usr/bin/env python3
"""Süreli linkli kanalların taze linklerini resmi sitelerden alıp secret bir gist'e yazar.

CI'da (ABD) alınan linklerin Türkiye'de açılıp açılmadığını ve ömrünü ölçmek için.
Linkler loglara yazılmaz (public repo).
"""

from __future__ import annotations

import json
import os
import sys
import time

from build_playlist import run_gh
from live_resolver import RESOLVED_CHANNELS, capture_master_playlist, read_expiry_timestamp

TOKENS_FILE_NAME = "tokens.json"
TOKEN_GIST_ID_ENV = "TOKEN_GIST_ID"


def main() -> int:
    from playwright.sync_api import sync_playwright

    captured: dict[str, dict] = {}
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        for channel in RESOLVED_CHANNELS:
            url = capture_master_playlist(browser, channel)
            expiry = read_expiry_timestamp(url) if url else None
            captured[channel.slug] = {"url": url, "captured_at": int(time.time()), "expiry": expiry}
            print(f"{channel.display_name}: {'alındı' if url else 'alınamadı'}", flush=True)
        browser.close()

    payload = {"files": {TOKENS_FILE_NAME: {"content": json.dumps(captured, indent=2)}}}
    run_gh(["api", "-X", "PATCH", f"gists/{os.environ[TOKEN_GIST_ID_ENV]}", "--input", "-", "--jq", ".id"],
           json.dumps(payload))
    print("gist güncellendi")
    return 0


if __name__ == "__main__":
    sys.exit(main())
