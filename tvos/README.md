# Türkiye TV — Apple TV uygulaması

Gist'teki `turkiye-kanallar.m3u` listesini Apple TV'de oynatan kişisel tvOS uygulaması (SwiftUI + AVPlayer).

- Kanal ızgarası, uzun basışla favorilere ekleme (favoriler en üstte)
- Oynatırken kumandada aşağı kaydırınca **Kanallar** sekmesinden kanal değiştirme
- Playlist'teki `#EXTVLCOPT` User-Agent / Referer header'larını yayına ekler
- Liste 10 dakikadan eskiyse oynatmadan önce tazelenir. Yayın hata verirse liste yenilenip
  bir kez daha denenir (DMAX/TLC/Beyaz TV'nin süreli linkleri için)
- Son indirilen liste önbellekte tutulur, uygulama açılır açılmaz görünür

## Gerekenler
- Xcode 16 veya üstü yüklü bir Mac, tvOS 17+ Apple TV
- Apple hesabı: ücretsiz hesapla kurulan uygulama 7 günde bir yeniden yüklenmeli.
  Ücretli Developer hesabıyla (yıllık 99 $) bu süre 1 yıl olur, TestFlight da kullanılabilir.

## Kurulum
1. Ayar dosyasını oluşturun (git'e girmez):
   ```sh
   cd tvos/Config
   cp Secrets.example.xcconfig Secrets.xcconfig
   ```
   İçine gist'in raw adresini (`build_playlist.py --publish` çıktısındaki adres; `https:/$()/` yazımına dikkat),
   ekip kimliğinizi ve size özgü bir bundle id yazın.
2. `tvos/TurkiyeTV.xcodeproj`'u Xcode'da açın.
3. Apple TV'yi eşleyin: Apple TV'de *Ayarlar > Uzaktan Uygulamalar ve Aygıtlar*,
   Xcode'da *Window > Devices and Simulators*. Mac ile Apple TV aynı ağda olmalı.
4. Üstte hedef olarak Apple TV'yi seçip ▶︎ (Cmd+R).

Adres derlemeye girmediyse uygulamadaki **Ayarlar** ekranından da girilebilir
(iPhone'a gelen klavye bildirimiyle yazmak daha kolay).

## Notlar
- **CNN Türk:** Listede `live_resolver.py`'nin yerel ağ adresiyle gelir. Yalnızca o Mac açıkken
  ve Apple TV aynı ağdayken açılır.
- **Simülatör:** Xcode'daki Apple TV simülatörüyle de denenebilir. Mac yurt dışındaysa coğrafi
  kısıtlı kanallar açılmaz.
- **İkon:** 3 katmanlı paralaks ikon ve Top Shelf görselleri `tools/make_icons.py` ile üretilir.
  Tasarımı değiştirmek için script'i düzenleyip
  `python3 tvos/tools/make_icons.py tvos/TurkiyeTV/Assets.xcassets` çalıştırın.
- Uygulama yalnızca kişisel kullanım içindir. Yayın hakları bize ait olmadığından App Store'a gönderilmez.
