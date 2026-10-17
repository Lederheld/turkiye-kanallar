import AVFoundation

/// Tek bir AVPlayer'ı yönetir; yayın düşerse playlist'i yenileyip bir kez yeniden dener.
@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var channel: Channel
    @Published private(set) var errorMessage: String?
    /// Bir önceki izlenen kanal ("son kanal" tuşu için).
    @Published private(set) var previousChannel: Channel?

    let player = AVPlayer()

    private let store: PlaylistStore
    private var statusObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var retriedAfterFailure = false
    private var startTask: Task<Void, Never>?

    init(channel: Channel, store: PlaylistStore) {
        self.channel = channel
        self.store = store
    }

    func play(_ channel: Channel) {
        if channel.name != self.channel.name {
            previousChannel = self.channel
        }
        self.channel = channel
        errorMessage = nil
        retriedAfterFailure = false
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

    func stop() {
        startTask?.cancel()
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
            load(channel)
        }
    }

    private func load(_ channel: Channel) {
        clearObservers()
        let item = AVPlayerItem(asset: Self.makeAsset(for: channel))
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
        guard !retriedAfterFailure else {
            player.pause()
            let detail = error.map { "\n\($0.localizedDescription)" } ?? ""
            errorMessage = "\(channel.name) açılamadı.\(detail)"
            return
        }
        // Link süresi dolmuş olabilir: listeyi zorla yenileyip bir kez daha dene
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
    private static func makeAsset(for channel: Channel) -> AVURLAsset {
        var headers: [String: String] = [:]
        if let userAgent = channel.userAgent { headers["User-Agent"] = userAgent }
        if let referrer = channel.referrer { headers["Referer"] = referrer }
        let options: [String: Any] = headers.isEmpty ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        return AVURLAsset(url: channel.streamURL, options: options)
    }

    private static func metadata(for channel: Channel) -> [AVMetadataItem] {
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = channel.name as NSString
        title.extendedLanguageTag = "und"
        return [title]
    }
}
