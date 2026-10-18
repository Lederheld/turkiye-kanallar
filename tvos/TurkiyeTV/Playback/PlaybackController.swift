import AVFoundation

/// Tek bir AVPlayer'ı yönetir. Her kanal için birkaç kaynak sırayla denenir (bkz. StreamSources):
/// biri açılmaz ya da takılırsa sıradakine geçilir; hepsi biterse liste yenilenip bir tur daha denenir.
@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var channel: Channel
    @Published private(set) var errorMessage: String?
    /// Uyku zamanlayıcısının biteceği an; kapalıyken nil.
    @Published private(set) var sleepEndsAt: Date?
    /// Bitmeden bir dakika önce true: ekranda "Devam et" düğmesi çıkar.
    @Published private(set) var isSleepWarningShown = false
    /// Süre dolunca true: oynatıcı kapanır, Apple TV kendi uykusuna geçer.
    @Published private(set) var sleepTimerFired = false
    /// Bir önceki izlenen kanal ("son kanal" tuşu için).
    @Published private(set) var previousChannel: Channel?
    /// Yayının sunucuda tuttuğu geri sarılabilir süre (dakikaya yuvarlanır). TRT'de saatler, çoğu kanalda birkaç dakika.
    @Published private(set) var rewindWindow: TimeInterval = 0
    /// Canlı yayının ne kadar gerisinde izleniyor (saniyeye yuvarlanır; canlıdayken 0).
    @Published private(set) var behindLive: TimeInterval = 0

    /// Geri sarma düğmelerinin gösterileceği en kısa pencere.
    static let minimumRewindWindow: TimeInterval = 120
    /// Bu kadarından az gerideyken canlıda sayılır (oynatıcı canlının birkaç segment gerisinden oynar).
    private static let liveTolerance: TimeInterval = 15

    /// Anında kanal geçişinde hazır bekleyen oynatıcıyla değiştirilir (bkz. prepareStandby).
    @Published private(set) var player = AVPlayer()

    private let store: PlaylistStore
    private let guide: ProgramGuide
    /// Kontrol Merkezi / iPhone kumandasında gösterilen bilgi en son hangi program için kuruldu.
    private var nowPlayingKey: String?
    private var statusObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var retriedAfterFailure = false
    private var startTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var sources: [StreamSources.Source] = []
    private var sourceIndex = 0
    /// Açılışta bu kadar sürede görüntü gelmezse sıradaki kaynağa geçilir; yayın ortasındaki donmalar
    /// için daha uzun beklenir (kısa ağ dalgalanmalarında kaynak değiştirmemek için).
    private static let startStallLimit: TimeInterval = 6
    private static let stallLimit: TimeInterval = 10
    private static let healthCheckInterval: TimeInterval = 2
    private var timeObserver: Any?
    /// Oynatıcının canlı uçtan en az ne kadar geride oynadığı; "canlı" bu konumdur.
    private var liveLatency: TimeInterval?
    /// Kanala henüz yazılmamış izleme süresi; ara ara ve kanal değişince kaydedilir.
    private var unsavedWatchTime: TimeInterval = 0
    private static let watchTimeSaveInterval: TimeInterval = 30
    private var scrubTask: Task<Void, Never>?
    /// Basılı tuttukça büyüyen adımlar; listenin sonundan sonra yarım saat yarım saat artar.
    private static let scrubSteps: [TimeInterval] = [5, 10, 20, 30, 45, 60].map { $0 * 60 }
    private static let scrubStepInterval: Duration = .milliseconds(800)

    init(channel: Channel, store: PlaylistStore, guide: ProgramGuide) {
        self.channel = channel
        self.store = store
        self.guide = guide
        attachTimeObserver()
    }

    private func attachTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1),
                                                      queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func play(_ channel: Channel) {
        if channel.name != self.channel.name {
            saveWatchTime()
            previousChannel = self.channel
        }
        self.channel = channel
        errorMessage = nil
        retriedAfterFailure = false
        nowPlayingKey = nil
        rewindWindow = 0
        behindLive = 0
        liveLatency = nil
        if timeObserver == nil {
            attachTimeObserver()  // stop() sonrası yeniden açılış
        }
        if let ready = standby, ready.channel.name == channel.name,
           ready.player.currentItem?.status == .readyToPlay {
            adopt(ready)
        } else {
            discardStandby()
            startFreshPlayback(forceReload: false)
        }
    }

    // MARK: - Anında kanal geçişi

    /// Kanallar şeridinde üzerinde durulan kanal, gizli ikinci bir oynatıcıda sessizce oynatılır;
    /// seçilince bu oynatıcı ekrana alınır ve görüntü beklemeden gelir. Odak başka kanala geçince ya da
    /// şerit kapanınca durdurulur (ek bant genişliği yalnızca şeritte gezinirken kullanılır).
    private struct Standby {
        let channel: Channel
        let player: AVPlayer
        let sources: [StreamSources.Source]
    }

    private var standby: Standby?
    private var standbyTask: Task<Void, Never>?
    /// Şeritte hızla gezinirken her kanalı açmamak için bekleme.
    private static let standbyDelay: Duration = .milliseconds(600)

    func prepareStandby(_ channel: Channel) {
        guard channel.name != self.channel.name else {
            discardStandby()
            return
        }
        guard standby?.channel.name != channel.name else { return }
        standbyTask?.cancel()
        standbyTask = Task {
            try? await Task.sleep(for: Self.standbyDelay)
            guard !Task.isCancelled else { return }
            let sources = await StreamSources.candidates(for: channel)
            guard !Task.isCancelled, let first = sources.first else { return }
            discardStandby()
            let item = AVPlayerItem(asset: Self.makeAsset(for: first))
            item.externalMetadata = Self.metadata(for: channel)
            let hidden = AVPlayer(playerItem: item)
            hidden.isMuted = true
            hidden.play()
            standby = Standby(channel: channel, player: hidden, sources: sources)
        }
    }

    func discardStandby() {
        standbyTask?.cancel()
        standbyTask = nil
        standby?.player.pause()
        standby?.player.replaceCurrentItem(with: nil)
        standby = nil
    }

    /// Hazır bekleyen oynatıcıyı ekrana alır; eskisi durdurulur.
    private func adopt(_ ready: Standby) {
        standbyTask?.cancel()
        standby = nil
        startTask?.cancel()
        healthTask?.cancel()
        clearObservers()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        player.pause()
        player.replaceCurrentItem(with: nil)
        player = ready.player
        player.isMuted = false
        attachTimeObserver()
        sources = ready.sources
        sourceIndex = 0
        guard let item = player.currentItem else { return }
        observe(item)
    }

    func retry() {
        play(channel)
    }

    /// Listede bir sonraki (+1) ya da önceki (-1) kanala geçer.
    func zap(by offset: Int) {
        if let next = store.neighbor(of: channel, offset: offset) {
            play(next)
        }
    }

    /// Bir önceki izlenen kanala döner.
    func recall() {
        if let previousChannel {
            play(previousChannel)
        }
    }

    // MARK: - Geri sarma

    var canRewind: Bool {
        rewindWindow >= Self.minimumRewindWindow
    }

    var isBehindLive: Bool {
        behindLive > 0
    }

    /// Sunucunun tuttuğu pencere içinde ileri/geri sarar (negatif: geri).
    func skip(by seconds: TimeInterval) {
        seek { current, _ in current + seconds }
    }

    /// Canlının `seconds` kadar gerisine gider (Zaman Tüneli). 0: canlı.
    func seek(secondsBehindLive seconds: TimeInterval) {
        seek { _, liveEdge in liveEdge - seconds }
    }

    func goLive() {
        seek(secondsBehindLive: 0)
    }

    // MARK: - Basılı tutarak sarma

    /// Kumandada sol/sağ basılı tutulunca görüntü adım adım ilerler: 5 dk, sonra 10, 20, 30, 45 dk,
    /// 1 sa, 1,5 sa… (başladığı yere göre). Ayrı bir gösterge yok: oynatıcının kendi zaman çubuğu ve
    /// "Canlının … gerisinde" rozeti konumu gösterir. Bırakınca olduğu yerde kalır.
    func beginScrub(direction: Int) {
        guard canRewind else { return }
        scrubTask?.cancel()
        let start = player.currentTime().seconds
        scrubTask = Task {
            var step = 0
            while !Task.isCancelled {
                let magnitude = step < Self.scrubSteps.count
                    ? Self.scrubSteps[step]
                    : Self.scrubSteps[Self.scrubSteps.count - 1] + Double(step - Self.scrubSteps.count + 1) * 1800
                seek { _, _ in start + Double(direction) * magnitude }
                step += 1
                try? await Task.sleep(for: Self.scrubStepInterval)
            }
        }
    }

    func endScrub() {
        scrubTask?.cancel()
        scrubTask = nil
    }

    var isPlaying: Bool {
        player.rate > 0
    }

    // MARK: - Kaydırarak sarma

    /// Kaydırırken hedef: canlının kaç saniye gerisi. Görüntü kaydırma sırasında atlamaz (cihazda her atlama
    /// zaman alıyor, kaydırırken hiçbir şey görünmüyordu); hedef zaman çubuğunun üstünde gösterilir,
    /// parmak kalkıp kısa bir süre yeni kaydırma gelmezse oraya atlanır. Art arda kaydırmalar toplanır.
    @Published private(set) var swipeTargetBehind: TimeInterval?
    /// AVKit'in oynatma çubuğu görünüyor mu (üstüne program bölümleri çizilir).
    @Published var isTransportBarVisible = false
    private var swipeStartBehind: TimeInterval = 0
    private var swipeCommitTask: Task<Void, Never>?
    private static let swipeCommitDelay: Duration = .milliseconds(700)
    private static let liveSnapDistance: TimeInterval = 60

    func beginSwipeSeek() {
        guard canRewind else { return }
        swipeCommitTask?.cancel()
        swipeStartBehind = swipeTargetBehind ?? behindLive
        swipeTargetBehind = swipeStartBehind  // hedef ilk hareketle hemen görünsün
    }

    /// `points`: dokunmatik yüzeydeki yatay kaydırma (sola negatif = geriye).
    func updateSwipeSeek(points: Double) {
        guard canRewind else { return }
        let distance = Self.swipeDistance(points) * SwipeSpeed.current.multiplier
        let target = min(max(swipeStartBehind - distance, 0), rewindWindow)
        // Sağ uca yakınsa canlıya yapışır
        swipeTargetBehind = target < max(Self.liveSnapDistance, rewindWindow * 0.015) ? 0 : target
    }

    func endSwipeSeek() {
        guard swipeTargetBehind != nil else { return }
        swipeCommitTask?.cancel()
        swipeCommitTask = Task {
            try? await Task.sleep(for: Self.swipeCommitDelay)
            guard !Task.isCancelled, let target = swipeTargetBehind else { return }
            seek(secondsBehindLive: target)
            swipeTargetBehind = nil
        }
    }

    /// Doğrusal değil: kısa kaydırma ince ayar, uzun kaydırma saatler. Siri Remote'ta yüzeyin bir ucundan
    /// diğerine kaydırma ~600 nokta: çeyrek ~6 dk, yarım ~20 dk, tam ~1 sa, art arda iki tam kaydırma ~3,5 sa.
    private static func swipeDistance(_ points: Double) -> TimeInterval {
        let surfaces = min(abs(points) / 600, 4)
        let minutes = 15 * surfaces + 45 * surfaces * surfaces
        return (points < 0 ? -minutes : minutes) * 60
    }

    /// Hedef, oynatma konumu ve canlı uçtan hesaplanır; sunucunun tuttuğu pencereye sıkıştırılır.
    private func seek(_ target: (_ current: TimeInterval, _ liveEdge: TimeInterval) -> TimeInterval) {
        guard let item = player.currentItem, let range = item.seekableTimeRanges.last?.timeRangeValue else { return }
        let liveEdge = range.end.seconds - (liveLatency ?? Self.liveOffset(of: item))
        let clamped = min(max(target(player.currentTime().seconds, liveEdge), range.start.seconds + 1), liveEdge)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in
                self?.player.play()
                self?.updateTimeline()
            }
        }
    }

    /// Saniyede bir: izleme süresini sayar, geri sarma durumunu günceller.
    // MARK: - Uyku zamanlayıcısı

    enum SleepOption {
        case minutes(Int)
        case endOfProgram
    }

    private static let sleepWarningLead: TimeInterval = 60

    func setSleepTimer(_ option: SleepOption) {
        switch option {
        case .minutes(let minutes):
            sleepEndsAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        case .endOfProgram:
            let watched = Date().addingTimeInterval(-behindLive)
            // canlının gerisindeysek program da o kadar geç biter
            sleepEndsAt = guide.program(for: channel, at: watched).map { $0.end.addingTimeInterval(behindLive) }
                ?? Date().addingTimeInterval(60 * 60)
        }
        isSleepWarningShown = false
    }

    func extendSleepTimer(minutes: Int = 30) {
        sleepEndsAt = (sleepEndsAt ?? Date()).addingTimeInterval(TimeInterval(minutes * 60))
        isSleepWarningShown = false
    }

    func cancelSleepTimer() {
        sleepEndsAt = nil
        isSleepWarningShown = false
    }

    private func checkSleepTimer() {
        guard let sleepEndsAt else { return }
        let remaining = sleepEndsAt.timeIntervalSinceNow
        if remaining <= 0 {
            self.sleepEndsAt = nil
            isSleepWarningShown = false
            player.pause()
            sleepTimerFired = true
        } else if remaining <= Self.sleepWarningLead, !isSleepWarningShown {
            isSleepWarningShown = true
        }
    }

    private func tick() {
        checkSleepTimer()
        updateNowPlayingIfNeeded()
        if player.rate > 0, player.currentItem?.status == .readyToPlay {
            unsavedWatchTime += 1
            if unsavedWatchTime >= Self.watchTimeSaveInterval { saveWatchTime() }
        }
        updateTimeline()
    }

    private func updateTimeline() {
        guard let item = player.currentItem, let range = item.seekableTimeRanges.last?.timeRangeValue,
              range.duration.isNumeric else {
            if rewindWindow != 0 { rewindWindow = 0 }
            if behindLive != 0 { behindLive = 0 }
            return
        }
        // Yayın geldikçe değişen değerler yuvarlanır ki arayüz her saniye yeniden çizilmesin
        let window = (range.duration.seconds / 60).rounded(.down) * 60
        if window != rewindWindow { rewindWindow = window }
        let distanceFromEdge = range.end.seconds - player.currentTime().seconds
        // Başlarken oynatıcı canlı uca yerleşene kadar mesafe dalgalanır; görülen en küçük değer canlıdır
        if item.status == .readyToPlay, player.rate > 0 {
            liveLatency = min(liveLatency ?? .greatestFiniteMagnitude, max(0, distanceFromEdge))
        }
        let offset = distanceFromEdge - (liveLatency ?? Self.liveOffset(of: item))
        let behind = offset > Self.liveTolerance ? offset.rounded() : 0
        if behind != behindLive { behindLive = behind }
    }

    private func saveWatchTime() {
        store.addWatchTime(unsavedWatchTime, to: channel)
        unsavedWatchTime = 0
    }

    /// Ölçüm yapılamadıysa AVFoundation'ın önerdiği canlı uç mesafesi (genelde birkaç segment).
    private static func liveOffset(of item: AVPlayerItem) -> TimeInterval {
        let offset = item.recommendedTimeOffsetFromLive.seconds
        return offset.isFinite ? offset : 0
    }

    func stop() {
        discardStandby()
        scrubTask?.cancel()
        swipeCommitTask?.cancel()
        saveWatchTime()
        startTask?.cancel()
        healthTask?.cancel()
        clearObservers()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    /// Süreli linkler eskimiş olabileceğinden oynatmadan önce gerekirse liste tazelenir.
    private func startFreshPlayback(forceReload: Bool) {
        startTask?.cancel()
        startTask = Task {
            if forceReload {
                await store.reload()
            } else {
                // Liste eskiyse arka planda tazelenir; kanal beklemeden eldeki linkle açılır.
                // Link ölmüşse hata yolu listeyi zorla yenileyip tekrar dener.
                Task { await store.reloadIfStale() }
            }
            guard !Task.isCancelled else { return }
            if let fresh = store.channel(named: channel.name) {
                channel = fresh
            }
            if forceReload {
                await StreamSources.invalidateSignedLinks()
            }
            let candidates = await StreamSources.candidates(for: channel)
            guard !Task.isCancelled else { return }
            sources = candidates
            sourceIndex = 0
            load(candidates[0])
        }
    }

    private func load(_ source: StreamSources.Source) {
        clearObservers()
        let item = AVPlayerItem(asset: Self.makeAsset(for: source))
        item.externalMetadata = Self.metadata(for: channel)
        player.replaceCurrentItem(with: item)
        player.play()
        observe(item)
    }

    /// Öğenin durumunu ve hatalarını izler; açılmayan ya da donan yayında sıradaki kaynağa geçilir.
    private func observe(_ item: AVPlayerItem) {
        let itemID = ObjectIdentifier(item)

        // .initial: hazır bekleyen oynatıcıdan gelen öğe zaten oynatılmaya hazır olabilir
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            let error = item.error
            Task { @MainActor in self?.handleStatus(status, error: error, itemID: itemID) }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in self?.handleFailure(error, itemID: itemID) }
        }
        watchHealth(of: itemID)
    }

    /// Oynatıcı "bekliyor" durumunda takılı kalırsa (açılmayan ya da donan yayın) sıradaki kaynağa geçer.
    /// Kullanıcının duraklatması sayılmaz.
    private func watchHealth(of itemID: ObjectIdentifier) {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            var stalled: TimeInterval = 0
            var hasStarted = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.healthCheckInterval))
                guard let self, !Task.isCancelled, self.isCurrentItem(itemID) else { return }
                if self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                    stalled += Self.healthCheckInterval
                } else {
                    stalled = 0
                    hasStarted = hasStarted || self.player.timeControlStatus == .playing
                }
                if stalled >= (hasStarted ? Self.stallLimit : Self.startStallLimit) {
                    self.handleFailure(nil, itemID: itemID)
                    return
                }
            }
        }
    }

    private func handleStatus(_ status: AVPlayerItem.Status, error: Error?, itemID: ObjectIdentifier) {
        switch status {
        case .readyToPlay:
            guard isCurrentItem(itemID) else { return }
            retriedAfterFailure = false
            errorMessage = nil
            store.recordWatched(channel)
        case .failed:
            handleFailure(error, itemID: itemID)
        default:
            break
        }
    }

    private func handleFailure(_ error: Error?, itemID: ObjectIdentifier) {
        guard isCurrentItem(itemID) else { return }
        clearObservers()
        healthTask?.cancel()
        if sourceIndex + 1 < sources.count {
            sourceIndex += 1
            load(sources[sourceIndex])
            return
        }
        guard !retriedAfterFailure else {
            player.pause()
            let detail = error.map { "\n\($0.localizedDescription)" } ?? ""
            errorMessage = "\(channel.name) açılamadı.\(detail)"
            return
        }
        // Tüm kaynaklar denendi; linklerin süresi dolmuş olabilir: liste ve imzalı linkler yenilenip bir tur daha
        retriedAfterFailure = true
        startFreshPlayback(forceReload: true)
    }

    private func isCurrentItem(_ itemID: ObjectIdentifier) -> Bool {
        player.currentItem.map { ObjectIdentifier($0) } == itemID
    }

    private func clearObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
        failureObserver = nil
    }

    /// Playlist'teki #EXTVLCOPT header'ları (User-Agent / Referer) yayına eklenir.
    private static func makeAsset(for source: StreamSources.Source) -> AVURLAsset {
        let options: [String: Any] = source.headers.isEmpty ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": source.headers]
        return AVURLAsset(url: source.url, options: options)
    }

    /// Oynatıcı başlığı, Kontrol Merkezi ve iPhone kumandası için: kanal adı ve o an izlenen program.
    private static func metadata(for channel: Channel, program: TVProgram? = nil) -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol) -> AVMutableMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            item.extendedLanguageTag = "und"
            return item
        }
        var items: [AVMetadataItem] = [item(.commonIdentifierTitle, channel.name as NSString)]
        // Yalnızca başlık ve alt başlık: açıklama ya da kapak görseli eklenince AVKit panele bir "Bilgi"
        // sekmesi ekliyor ve aşağı kaydırınca odak doğrudan kanallara inmiyor
        if let program {
            items.append(item(.iTunesMetadataTrackSubTitle, program.title as NSString))
        }
        return items
    }

    /// Program değiştikçe (ya da geri sarılınca) gösterilen bilgi güncellenir.
    private func updateNowPlayingIfNeeded() {
        guard let item = player.currentItem else { return }
        let program = guide.program(for: channel, at: Date().addingTimeInterval(-behindLive))
        let key = channel.name + "|" + (program?.title ?? "")
        guard key != nowPlayingKey else { return }
        nowPlayingKey = key
        item.externalMetadata = Self.metadata(for: channel, program: program)
    }
}

/// Ayarlar'dan seçilen kaydırarak sarma hızı.
enum SwipeSpeed: String, CaseIterable, Identifiable {
    case slow, normal, fast

    static let defaultsKey = "swipeSeekSpeed"

    static var current: SwipeSpeed {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(SwipeSpeed.init(rawValue:)) ?? .normal
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .slow: return "Yavaş"
        case .normal: return "Normal"
        case .fast: return "Hızlı"
        }
    }

    var multiplier: Double {
        switch self {
        case .slow: return 0.5
        case .normal: return 1
        case .fast: return 2
        }
    }
}
