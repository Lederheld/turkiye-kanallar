import Foundation

enum PlaylistError: LocalizedError {
    case badStatus(Int)
    case noChannels

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "Sunucu \(code) hatası döndürdü."
        case .noChannels: return "Listede oynatılabilir kanal bulunamadı."
        }
    }
}

/// Gist'teki playlist'i indirir, önbelleğe alır ve favorileri tutar.
@MainActor
final class PlaylistStore: ObservableObject {
    @Published private(set) var channels: [Channel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var favoriteNames: [String]
    @Published private(set) var customPlaylistURL: String

    /// DMAX/TLC/Beyaz TV linkleri 30 dk'da bir yenileniyor; bundan eski liste tazelenir.
    private static let staleInterval: TimeInterval = 10 * 60
    private static let requestTimeout: TimeInterval = 20

    private enum Keys {
        static let favorites = "favoriteChannelNames"
        static let customURL = "customPlaylistURL"
    }

    private let defaults = UserDefaults.standard
    private var loadTask: Task<Void, Never>?

    init() {
        favoriteNames = defaults.stringArray(forKey: Keys.favorites) ?? []
        customPlaylistURL = defaults.string(forKey: Keys.customURL) ?? ""
        loadCachedPlaylist()
    }

    // MARK: - Adres

    /// Derleme sırasında Secrets.xcconfig'teki PLAYLIST_URL'den Info.plist'e gelir.
    static var bundledPlaylistURL: String {
        let value = (Bundle.main.object(forInfoDictionaryKey: "PlaylistURL") as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
        return value.contains("$(") ? "" : value
    }

    var playlistURL: URL? {
        let candidate = customPlaylistURL.isEmpty ? Self.bundledPlaylistURL : customPlaylistURL
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }

    func setCustomPlaylistURL(_ value: String) async {
        customPlaylistURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(customPlaylistURL, forKey: Keys.customURL)
        await reload()
    }

    // MARK: - Yükleme

    var isStale: Bool {
        guard let lastUpdated else { return true }
        return Date().timeIntervalSince(lastUpdated) > Self.staleInterval
    }

    func reload() async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { await performReload() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    func reloadIfStale() async {
        if isStale { await reload() }
    }

    private func performReload() async {
        guard let url = playlistURL else {
            lastError = "Playlist adresi ayarlanmamış. Ayarlar'dan gist adresini girin."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let text = try await Self.fetch(url)
            let parsed = M3UParser.parse(text)
            guard !parsed.isEmpty else { throw PlaylistError.noChannels }
            channels = parsed
            lastUpdated = Date()
            lastError = nil
            try? text.write(to: Self.cacheFileURL, atomically: true, encoding: .utf8)
        } catch {
            // Eski liste varsa ekranda kalır; yalnızca hata gösterilir
            lastError = error.localizedDescription
        }
    }

    private static func fetch(_ url: URL) async throws -> String {
        // Gist'in raw CDN önbelleğini atlamak için zaman damgası eklenir
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let cacheBuster = URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))
        components?.queryItems = (components?.queryItems ?? []) + [cacheBuster]
        let request = URLRequest(url: components?.url ?? url,
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: requestTimeout)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PlaylistError.badStatus(http.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static var cacheFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("turkiye-kanallar.m3u")
    }

    private func loadCachedPlaylist() {
        let url = Self.cacheFileURL
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        channels = M3UParser.parse(text)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        lastUpdated = attributes?[.modificationDate] as? Date
    }

    // MARK: - Kanallar

    func channel(named name: String) -> Channel? {
        channels.first { $0.name == name }
    }

    var sections: [ChannelGroup] {
        var order: [String] = []
        var channelsByGroup: [String: [Channel]] = [:]
        for channel in channels {
            let title = channel.group ?? "Tüm Kanallar"
            if channelsByGroup[title] == nil { order.append(title) }
            channelsByGroup[title, default: []].append(channel)
        }
        return order.map { ChannelGroup(title: $0, channels: channelsByGroup[$0] ?? []) }
    }

    // MARK: - Favoriler

    var favoriteChannels: [Channel] {
        favoriteNames.compactMap(channel(named:))
    }

    func isFavorite(_ channel: Channel) -> Bool {
        favoriteNames.contains(channel.name)
    }

    func toggleFavorite(_ channel: Channel) {
        if let index = favoriteNames.firstIndex(of: channel.name) {
            favoriteNames.remove(at: index)
        } else {
            favoriteNames.append(channel.name)
        }
        defaults.set(favoriteNames, forKey: Keys.favorites)
    }
}
