# Türkiye TV kanalları playlist'i

Resmi ve ücretsiz Türk TV yayınlarından M3U listesi üretir ve secret bir gist'e yükler.

- Günlük güncelleme: `.github/workflows/update-playlist.yml` (her gün 06:30 TR)
- Elle çalıştırma: `python build_playlist.py --publish`
- Kanal bazında son durum: workflow çıktısındaki `rapor` artifact'ı

Gerekli ayarlar: `secrets.GIST_TOKEN` (yalnızca gist yetkili token), `vars.GIST_ID`.
