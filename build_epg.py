#!/usr/bin/env python3
"""Yayın akışını bizim kanallara süzüp küçük bir JSON olarak gist'e yazar (epg.json).

Kaynaklar sırayla birleştirilir; bir kanal ilk kaynakta yoksa sonrakine bakılır:
  1. epgshare01 (XMLTV)   2. open-epg (XMLTV)   3. D-Smart'ın herkese açık akış servisi
D-Smart'ta bazı kanalların verisi günlerce geride kalabildiği için yalnızca şu anı kapsayan
programlar alınır. Önceki epg.json'daki dünkü programlar korunur (24 saat geri sarma için).

Çıktı: {"generated": <unix sn>, "channels": {"TRT 1": [[başlangıç, bitiş, "başlık"], ...]}}
Uygulama (tvOS) yalnızca bu dosyayı indirir; Top Shelf eklentisi de bunu okuyabilir.
"""

from __future__ import annotations

import argparse
import gzip
import io
import json
import re
import time
import unicodedata
import urllib.request
import xml.etree.ElementTree as ElementTree
from datetime import datetime, timedelta, timezone
from pathlib import Path

from build_playlist import BROWSER_USER_AGENT, CHANNEL_SPECS, GIST_ID_STATE_PATH, RUNNING_IN_CI, log, run_gh

OUTPUT_EPG_NAME = "epg.json"
OUTPUT_EPG_PATH = Path(__file__).resolve().parent / OUTPUT_EPG_NAME
XMLTV_SOURCES = (
    "https://epgshare01.online/epgshare01/epg_ripper_TR1.xml.gz",
    "https://www.open-epg.com/files/turkey1.xml.gz",
)
DSMART_SCHEDULE_URL = "https://www.dsmart.com.tr/api/v1/public/epg/schedules?page=1&limit=200&day={day}"
HTTP_TIMEOUT_SECONDS = 60
# Geri sarma için dün, ileriye bakan özellikler (Bu akşam, hatırlatıcı) için yarın yeter
KEEP_PAST = timedelta(hours=30)
KEEP_FUTURE = timedelta(hours=36)
# Akışta farklı adla geçen kanallar: normalize edilmiş bizim ad → normalize edilmiş akış adı
ALIASES = {"now": "fox"}


def normalize(name: str) -> str:
    """"TRT.1.HD.tr" / "TRT 1 HD" / "trt 1" → "trt1"; Türkçe harfler sadeleşir ("Yıldız" → "yildiz")."""
    text = name.replace("İ", "I").replace("ı", "i").lower()
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = re.sub(r"\.tr$", "", text)
    words = [w for w in re.split(r"[^a-z0-9]+", text) if w and w != "hd"]
    return "".join(words)


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": BROWSER_USER_AGENT})
    with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
        return response.read()


def parse_xmltv_time(value: str) -> int:
    return int(datetime.strptime(value.strip(), "%Y%m%d%H%M%S %z").timestamp())


def xmltv_programs(url: str) -> dict[str, list[list]]:
    """XMLTV → normalize edilmiş kanal adı → [[başlangıç, bitiş, başlık], ...]."""
    data = fetch(url)
    if url.endswith(".gz"):
        data = gzip.GzipFile(fileobj=io.BytesIO(data)).read()
    names_by_id: dict[str, set[str]] = {}
    programs_by_id: dict[str, list[list]] = {}
    for _, element in ElementTree.iterparse(io.BytesIO(data), events=("end",)):
        if element.tag == "channel":
            channel_id = element.get("id", "")
            names = {normalize(channel_id)}
            names.update(normalize(e.text or "") for e in element.findall("display-name"))
            names_by_id[channel_id] = {n for n in names if n}
            element.clear()
        elif element.tag == "programme":
            title = (element.findtext("title") or "").strip()
            try:
                start, stop = parse_xmltv_time(element.get("start", "")), parse_xmltv_time(element.get("stop", ""))
            except ValueError:
                element.clear()
                continue
            if title and stop > start:
                programs_by_id.setdefault(element.get("channel", ""), []).append([start, stop, title])
            element.clear()
    by_name: dict[str, list[list]] = {}
    for channel_id, programs in programs_by_id.items():
        for name in names_by_id.get(channel_id, {normalize(channel_id)}):
            # aynı adla birden çok kimlik varsa (TRT.1.tr / TRT.1.HD.tr) en dolu olan kalır
            if len(programs) > len(by_name.get(name, [])):
                by_name[name] = programs
    return by_name


def dsmart_programs(now: datetime) -> dict[str, list[list]]:
    by_name: dict[str, list[list]] = {}
    for day in (now - timedelta(days=1), now, now + timedelta(days=1)):
        payload = json.loads(fetch(DSMART_SCHEDULE_URL.format(day=day.strftime("%Y-%m-%d"))))
        for channel in payload.get("data", {}).get("channels", []):
            name = normalize(channel.get("channel_name", ""))
            for program in channel.get("schedule", []):
                try:
                    start = int(datetime.fromisoformat(program["start_date"].replace("Z", "+00:00")).timestamp())
                    end = int(datetime.fromisoformat(program["end_date"].replace("Z", "+00:00")).timestamp())
                except (KeyError, ValueError):
                    continue
                title = (program.get("program_name") or "").strip()
                if title and end > start:
                    by_name.setdefault(name, []).append([start, end, title])
    return by_name


def clean(programs: list[list], window_start: int, window_end: int) -> list[list]:
    """Pencereye düşenler, başlangıca göre sıralı, tekrarsız."""
    unique = {(p[0], p[1], p[2]) for p in programs if p[1] > window_start and p[0] < window_end}
    return [list(p) for p in sorted(unique)]


def covers_now(programs: list[list], now: int) -> bool:
    return any(start <= now < end for start, end, _ in programs)


def build(previous: dict[str, list[list]]) -> dict[str, list[list]]:
    now_dt = datetime.now(timezone.utc)
    now = int(now_dt.timestamp())
    window_start, window_end = int((now_dt - KEEP_PAST).timestamp()), int((now_dt + KEEP_FUTURE).timestamp())
    names = [spec.display_name for spec in CHANNEL_SPECS]
    keys = {name: ALIASES.get(normalize(name), normalize(name)) for name in names}

    sources: list[tuple[str, dict[str, list[list]], bool]] = []
    for url in XMLTV_SOURCES:
        try:
            sources.append((url.split("/")[2], xmltv_programs(url), False))
        except Exception as error:  # bir kaynak çökerse diğerleri yine kullanılır
            log(f"{url.split('/')[2]}: alınamadı ({type(error).__name__})")
    try:
        # D-Smart'ta veri geride kalabiliyor: yalnızca şu anı kapsayan kanal alınır
        sources.append(("dsmart", dsmart_programs(now_dt), True))
    except Exception as error:
        log(f"dsmart: alınamadı ({type(error).__name__})")

    result: dict[str, list[list]] = {}
    source_by_channel: dict[str, str] = {}
    for name in names:
        for source_name, programs_by_key, require_now in sources:
            programs = clean(programs_by_key.get(keys[name], []), window_start, window_end)
            if programs and (not require_now or covers_now(programs, now)):
                result[name] = programs
                source_by_channel[name] = source_name
                break
        # önceki dosyadaki, yeni akışın başladığı andan önceki programlar korunur (dün)
        fresh_start = result[name][0][0] if name in result else window_end
        kept = [p for p in previous.get(name, []) if p[0] < fresh_start and p[1] > window_start]
        if kept or name in result:
            result[name] = clean(kept + result.get(name, []), window_start, window_end)

    missing = [name for name in names if not covers_now(result.get(name, []), now)]
    counts = {}
    for source_name in source_by_channel.values():
        counts[source_name] = counts.get(source_name, 0) + 1
    log(f"Akış: {len(names) - len(missing)}/{len(names)} kanal şu an için dolu; kaynaklar {counts}")
    if missing:
        log("Şu an için akışı olmayan: " + ", ".join(missing))
    return result


def load_previous_from_gist(gist_id: str) -> dict[str, list[list]]:
    try:
        content = run_gh(["api", f"gists/{gist_id}", "--jq", f'.files["{OUTPUT_EPG_NAME}"].content // ""'])
        return json.loads(content).get("channels", {}) if content else {}
    except (RuntimeError, ValueError):
        return {}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--publish", action="store_true", help="epg.json'u gist'e yaz")
    parser.add_argument("--gist-id", help="gist id (varsayılan: .gist_id dosyası)")
    arguments = parser.parse_args()

    gist_id = arguments.gist_id or (GIST_ID_STATE_PATH.read_text().strip() if GIST_ID_STATE_PATH.exists() else "")
    previous = load_previous_from_gist(gist_id) if gist_id else {}
    channels = build(previous)
    if not channels:
        log("Hiç akış alınamadı, dosya yazılmadı")
        return 1
    document = {"generated": int(time.time()), "channels": channels}
    text = json.dumps(document, ensure_ascii=False, separators=(",", ":"))
    OUTPUT_EPG_PATH.write_text(text, encoding="utf-8")
    log(f"{OUTPUT_EPG_NAME}: {len(text) // 1024} KB")

    if arguments.publish:
        if not gist_id:
            log("Gist id yok, yayınlanmadı")
            return 1
        payload = {"files": {OUTPUT_EPG_NAME: {"content": text}}}
        run_gh(["api", "-X", "PATCH", f"gists/{gist_id}", "--input", "-", "--jq", ".id"], json.dumps(payload))
        log("Gist'teki akış güncellendi" if RUNNING_IN_CI else f"Gist'teki akış güncellendi: {gist_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
