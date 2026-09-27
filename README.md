# Türkiye TV kanalları playlist'i

Resmi ve ücretsiz Türk TV yayınlarından M3U listesi üretir ve secret bir gist'e yükler.

- Otomatik güncelleme: `.github/workflows/update-playlist.yml` (her gün 06:30 ve 18:30 TR)
- Elle çalıştırma: `python build_playlist.py --publish`
- Kanal bazında son durum: workflow çıktısındaki `rapor` artifact'ı

Gerekli secret'lar: `GIST_TOKEN` (yalnızca gist yetkili token), `GIST_ID`.

## Süreli linkli kanallar
- DMAX, TLC, Beyaz TV: `refresh_tokens.py` (workflow: `refresh-tokens.yml`) linkleri gist'te tazeler.
  GitHub'ın kendi zamanlayıcısı güvenilir tetiklemediği için cron-job.org 30 dk'da bir
  `workflow_dispatch` çağırır (yalnızca bu repoda Actions: Read and write yetkili fine-grained token).
- CNN Türk: token IP'ye bağlı; `live_resolver.py` Türkiye'deki bir Mac'te çalışırken açılır.
