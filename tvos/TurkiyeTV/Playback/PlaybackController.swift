import AVFoundation

/// Tek bir AVPlayer'ı yönetir. Her kanal için birkaç kaynak sırayla denenir (bkz. StreamSources):
/// biri açılmaz ya da takılırsa sıradakine geçilir; hepsi biterse liste yenilenip bir tur daha denenir.
@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var channel: Channel
    @Published private(set) var errorMessage: String?
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

    let player = AVPlayer()

    private let store: PlaylistStore
    private var statusObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var retriedAfterFailure = false
    private var startTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var sources: [StreamSources.Source] = []
    private var sourceIndex = 0
    /// Bu kadar süre görüntü gelmezse (açılışta ya da yayın ortasında) sıradaki kaynağa geçilir.
    private static let stallLimit: TimeInterval = 10
    private static let healthCheckInterval: TimeInterval = 2
    private var timeObserver: Any?
    /// Oynatıcının canlı uçtan en az ne kadar geride oynadığı; "canlı" bu konumdur.
    private var liveLatency: TimeInterval?
    /// Kanala henüz yazılmamış izleme süresi; ara ara ve kanal değişince kaydedilir.
    private var unsavedWatchTime: TimeInterval = 0
    private static let watchTimeSaveInterval: TimeInterval = 30
    private var scrubTask: Task<Void, Never>?
    /// Kaydırarak sarma: başladığı konum ve en son istenen atlama (her küçük harekette atlanmaz).
    private var swipeStart: TimeInterval?
    private var lastSwipeSeek: (target: TimeInterval, at: Date)?
    private static let swipeSeekMinimumDistance: TimeInterval = 20
    private static let swipeSeekMinimumInterval: TimeInterval = 0.2
    /// Basılı tuttukça büyüyen adımlar; listenin sonundan sonra yarım saat yarım saat artar.
    private static let scrubSteps: [TimeInterval] = [5, 10, 20, 30, 45, 60].map { $0 * 60 }
    private static let scrubStepInterval: Duration = .milliseconds(800)

    init(channel: Channel, store: PlaylistStore) {
        self.channel = channel
        self.store = store
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1),
                                                      queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
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
        rewindWindow = 0
        behindLive = 0
        liveLatency = nil
        startFreshPlayback(forceReload: false)
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

    func beginSwipeSeek() {
        guard canRewind else { return }
        swipeStart = player.currentTime().seconds
        lastSwipeSeek = nil
    }

    /// `fraction`: yüzey genişliğine göre kaydırma (sola negatif). Doğrusal değil: kısa kaydırma birkaç
    /// dakika (0,1 → ~5 dk), yarım kaydırma ~50 dk, tam kaydırma ~2,5 saat. Parmak hareket ettikçe
    /// görüntü atlar; çok sık atlamamak için en az 20 sn fark ve 0,2 sn ara beklenir.
    func updateSwipeSeek(fraction: Double) {
        guard let swipeStart else { return }
        let target = swipeStart + Self.swipeDistance(fraction)
        if let last = lastSwipeSeek,
           abs(last.target - target) < Self.swipeSeekMinimumDistance
            || Date().timeIntervalSince(last.at) < Self.swipeSeekMinimumInterval { return }
        lastSwipeSeek = (target, Date())
        seek { _, _ in target }
    }

    func endSwipeSeek() {
        if let lastSwipeSeek {
            seek { _, _ in lastSwipeSeek.target }
        }
        swipeStart = nil
        lastSwipeSeek = nil
    }

    private static func swipeDistance(_ fraction: Double) -> TimeInterval {
        let magnitude = min(abs(fraction), 1)
        let minutes = 40 * magnitude * (1 + 3 * magnitude)
        return (fraction < 0 ? -minutes : minutes) * 60
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
    private func tick() {
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
        scrubTask?.cancel()
        saveWatchTime()
        startTask?.cancel()
        healthTask?.cancel()
        clearObservers()
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
                await store.reloadIfStale()
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
        let itemID = ObjectIdentifier(item)

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
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

        player.replaceCurrentItem(with: item)
        player.play()
        watchHealth(of: itemID)
    }

    /// Oynatıcı "bekliyor" durumunda takılı kalırsa (açılmayan ya da donan yayın) sıradaki kaynağa geçer.
    /// Kullanıcının duraklatması sayılmaz.
    private func watchHealth(of itemID: ObjectIdentifier) {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            var stalled: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.healthCheckInterval))
                guard let self, !Task.isCancelled, self.isCurrentItem(itemID) else { return }
                if self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                    stalled += Self.healthCheckInterval
                } else {
                    stalled = 0
                }
                if stalled >= Self.stallLimit {
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

    private static func makeAsset(for source: StreamSources.Source) -> AVURLAsset {
        let options: [String: Any] = source.headers.isEmpty ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": source.headers]
        return AVURLAsset(url: source.url, options: options)
    }

    private static func metadata(for channel: Channel) -> [AVMetadataItem] {
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = channel.name as NSString
        title.extendedLanguageTag = "und"
        return [title]
    }
}
