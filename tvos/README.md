# Türkiye TV — Apple TV uygulaması

Gist'teki `turkiye-kanallar.m3u` listesini Apple TV'de oynatan kişisel tvOS uygulaması (SwiftUI + AVPlayer).

- **Ana Sayfa:** son izlenen kanalla büyük kart, Favoriler, Son İzlenenler ve kategori rafları
  (Ulusal, Haber, Ekonomi, Spor, Çocuk, Belgesel ve Yaşam, Müzik). Kategori kanal adından çıkarılır
- **Kanallar:** tüm kanallar numaralı ızgarada. **Ara:** ada ya da kanal numarasına göre arama
- Uzun basışla favorilere ekleme
- Bir TV gibi açılışta en çok izlenen kanal başlar (Ayarlar'dan son kanal ya da ana sayfa seçilebilir)
- Oynatırken: kanal değişince kanal bilgisi görünür; çubukta önceki/sonraki/son kanal ve favori
  düğmeleri; TV kumandasındaki (CEC) kanal +/- tuşları kanal değiştirir; aşağı kaydırınca
  izlenen kanaldan başlayan **Kanallar** şeridi
- **Geri sarma:** yayının sunucuda tuttuğu süre kadar (TRT 1'de yaklaşık 24 saat, çoğu özel kanalda
  birkaç dakika). Oynarken dokunmatik yüzeyde sola/sağa kaydırınca hedef, AVKit'in tek zaman çubuğunun
  üstünde saat ve programla gösterilir; bırakınca oraya atlanır, art arda kaydırmalar toplanır (hızı
  Ayarlar'dan). Çubuk program sınırlarında bölümlere ayrılır. Sol/sağ basılı tutunca görüntü hızlanarak
  sarılır (5, 10, 20, 30, 45 dk, 1 sa…). Çubukta yalnızca iki menü: **Zaman Tüneli** (Canlıya dön,
  Programın başına, 10 dk geri/ileri, program başlangıçları) ve **Kanal** (önceki/sonraki/son kanal,
  favori). Geri kalındığında sağ üstte "Canlının … gerisinde" rozeti. Uygulama kendisi kayıt yapmaz
- **Yayın akışı:** epgshare01 ve open-epg'den (XMLTV) 6 saatte bir indirilir, dün önbellekte tutulur.
  Kartlarda ve kanal bilgisinde o an yayındaki program; sararken hedefteki program; Zaman Tüneli menüsünde
  programların başlangıçları; oynatma çubuğunda **Baştan izle**. Canlının gerisindeyken sağ üstteki
  rozet birkaç saniye sonra küçük bir baloncuğa dönüşür
- **Anında kanal geçişi:** Kanallar şeridinde bir kanalın üzerinde 0,6 sn durunca o kanal gizli ikinci
  bir oynatıcıda sessizce açılır; seçilince bu oynatıcı ekrana alınır (simülatörde 0,1 sn; normalde
  0,3-0,8 sn). Odak başka kanala geçince ya da şerit kapanınca durdurulur
- **Uyku zamanlayıcısı:** Kanal menüsünde 30/60/90 dk ya da program bitince; bitmeden 1 dk önce
  ekranda "30 dk daha" düğmesi, süre dolunca yayın durur ve ana ekrana dönülür
- **Hatırlatıcı:** Kanal menüsündeki "Hatırlat" listesinden ya da ana sayfadaki program kartlarından kurulur.
  Program başlamadan 1 dk önce oynatıcıda kart ve "Geç" düğmesi çıkar (kanal arkada hazırlanır, anında açılır);
  ana ekrandaysan uyarı penceresi. Uygulama kapalıyken açılırsa yayındaki hatırlatılan kanal açılır
- **Bu Akşam rafı:** ana sayfada 19:45–21:00 arası başlayan uzun yapımlar (dizi, film, maç); yayındaysa
  tıklayınca açılır, değilse hatırlatıcı kurar. Kurulu hatırlatmalar ayrıca "Hatırlatmalar" rafında
- **Rehber:** solda kanallar, sağda yarım saat öncesinden 12 saat sonrasına program ızgarası; satırlar birlikte
  kayar, şimdiki an kırmızı çizgi. Yayındaki programa basınca kanal açılır, ilerideki programa basınca hatırlatıcı
- **Hız:** kanal, liste tazelenmesini beklemeden eldeki linkle açılır (liste arka planda yenilenir);
  logolar ve ATV'nin imzalı linki açılışta önceden alınır, logolar bellekte tutulur
- **Kendini toparlayan oynatma:** her kanal için birkaç kaynak sırayla denenir (resmi imzalı link →
  listedeki link → tek kaliteli linkin ana playlist'i). Yayın açılışta 6 sn içinde başlamazsa ya da sonradan 10 sn donarsa sıradakine
  geçilir; hepsi biterse liste yenilenip bir tur daha denenir. ATV, listedeki sorunlu CDN yerine
  atv.com.tr'nin token servisinden Apple TV'nin kendisi için alınan linkle oynar
- **Kişiselleştirme:** izleme süresi kanal başına tutulur (iki haftada yarıya iner); en çok izlenen
  kategoriler ve kanallar öne gelir, ana sayfada **En Çok İzlediklerin** rafı. Ayarlar'dan kapatılabilir
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
