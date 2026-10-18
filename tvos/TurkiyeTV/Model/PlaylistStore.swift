import Foundation

enum StartupBehavior: String, CaseIterable, Identifiable {
    case mostWatched, lastChannel, home

    var id: Self { self }

    var title: String {
        switch self {
        case .mostWatched: return "En çok izlenen kanal"
        case .lastChannel: return "Son izlenen kanal"
        case .home: return "Ana sayfa"
        }
    }
}

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

/// Gist'teki playlist'i indirir, önbelleğe alır; favorileri, son izlenenleri ve ayarları tutar.
@MainActor
final class PlaylistStore: ObservableObject {
    @Published private(set) var channels: [Channel] = [] {
        didSet { numbers = Dictionary(channels.enumerated().map { ($1.name, $0 + 1) }, uniquingKeysWith: { a, _ in a }) }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var favoriteNames: [String]
    @Published private(set) var customPlaylistURL: String
    @Published private(set) var recentNames: [String]
    /// Uygulama açılınca ne olacağı (bir TV gibi doğrudan bir kanalla açılabilir).
    @Published var startupBehavior: StartupBehavior {
        didSet { defaults.set(startupBehavior.rawValue, forKey: Keys.startupBehavior) }
    }
    /// Kategoriler ve kanallar izleme süresine göre sıralanır (kanal numaraları değişmez).
    @Published var sortsByWatchTime: Bool {
        didSet { defaults.set(sortsByWatchTime, forKey: Keys.sortsByWatchTime) }
    }
    /// Kanal adı → [izleme puanı (sn), son güncelleme (1970'ten sn)]. Puan yarılanma süresiyle eskir.
    @Published private(set) var watchHistory: [String: [Double]]

    /// Listedeki sırası (1'den başlar); kumandadan kanal değiştirirken ve kartlarda gösterilir.
    private(set) var numbers: [String: Int] = [:]
    private static let recentLimit = 12
    /// İki hafta önceki izleme bugünkünün yarısı kadar sayılır; alışkanlık değişince sıra da değişir.
    private static let watchHalfLife: TimeInterval = 14 * 24 * 3600
    /// "En Çok İzlediklerin" rafına girmek için gereken en az puan.
    private static let frequentThreshold: TimeInterval = 5 * 60

    /// DMAX/TLC/Beyaz TV linkleri 30 dk'da bir yenileniyor; bundan eski liste tazelenir.
    private static let staleInterval: TimeInterval = 10 * 60
    private static let requestTimeout: TimeInterval = 20
    /// Uygulama açıkken listenin kontrol edilme aralığı (liste eskiyse yeniden indirilir).
    static let autoRefreshInterval: Duration = .seconds(5 * 60)

    private enum Keys {
        static let favorites = "favoriteChannelNames"
        static let customURL = "customPlaylistURL"
        static let recents = "recentChannelNames"
        static let resumeLastChannel = "resumesLastChannel"  // eski ayar; yalnızca taşımak için okunur
        static let startupBehavior = "startupBehavior"
        static let sortsByWatchTime = "sortsByWatchTime"
        static let watchHistory = "watchHistory"
    }

    private let defaults = UserDefaults.standard
    private var loadTask: Task<Void, Never>?

    init() {
        favoriteNames = defaults.stringArray(forKey: Keys.favorites) ?? []
        customPlaylistURL = defaults.string(forKey: Keys.customURL) ?? ""
        recentNames = defaults.stringArray(forKey: Keys.recents) ?? []
        let legacyResume = defaults.object(forKey: Keys.resumeLastChannel) as? Bool
        startupBehavior = defaults.string(forKey: Keys.startupBehavior).flatMap(StartupBehavior.init(rawValue:))
            ?? (legacyResume == false ? .home : .mostWatched)
        sortsByWatchTime = defaults.object(forKey: Keys.sortsByWatchTime) as? Bool ?? true
        watchHistory = defaults.dictionary(forKey: Keys.watchHistory) as? [String: [Double]] ?? [:]
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

    /// Aynı gist'teki yayın akışı özeti (build_epg.py yazar).
    var epgSummaryURL: URL? {
        playlistURL?.deletingLastPathComponent().appendingPathComponent("epg.json")
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
        let existingItems = components?.queryItems ?? []
        components?.queryItems = existingItems + [cacheBuster]
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

    func number(of channel: Channel) -> Int? {
        numbers[channel.name]
    }

    /// Boş kategoriler atlanır. İzleme süresine göre sıralama açıksa en çok izlenen kategori ve
    /// kategori içinde en çok izlenen kanal öne gelir; eşitlikte sabit sıra (kanal numarası) korunur.
    var categorySections: [(category: ChannelCategory, channels: [Channel])] {
        let grouped = Dictionary(grouping: channels, by: \.category)
        let sections = ChannelCategory.allCases.compactMap { category in
            grouped[category].map { (category: category, channels: ordered($0)) }
        }
        guard sortsByWatchTime else { return sections }
        let now = Date()
        let totals = sections.map { section in section.channels.reduce(0) { $0 + watchScore(of: $1, at: now) } }
        return zip(sections, totals).enumerated()
            .sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }
            .map(\.element.0)
    }

    /// İzleme süresine göre (açıksa) sıralar; eşitlikte listedeki sıra korunur.
    func ordered(_ list: [Channel]) -> [Channel] {
        guard sortsByWatchTime else { return list }
        let now = Date()
        return list.enumerated()
            .sorted { (watchScore(of: $0.element, at: now), -$0.offset) > (watchScore(of: $1.element, at: now), -$1.offset) }
            .map(\.element)
    }

    /// Ana sayfadaki "En Çok İzlediklerin" rafı.
    var frequentChannels: [Channel] {
        let now = Date()
        return ordered(channels).filter { watchScore(of: $0, at: now) >= Self.frequentThreshold }.prefix(12).map { $0 }
    }

    /// Listede `offset` kadar ilerideki kanal; uçlarda başa/sona sarar.
    func neighbor(of channel: Channel, offset: Int) -> Channel? {
        guard !channels.isEmpty, let index = channels.firstIndex(where: { $0.name == channel.name }) else {
            return channels.first
        }
        let count = channels.count
        return channels[((index + offset) % count + count) % count]
    }

    /// Ada (Türkçe karakter ve büyük/küçük harf duyarsız) ya da kanal numarasına göre arar.
    func search(_ query: String) -> [Channel] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        if let number = Int(trimmed) {
            return channels.filter { numbers[$0.name] == number }
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return channels.filter { $0.name.range(of: trimmed, options: options, locale: Locale(identifier: "tr_TR")) != nil }
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

    // MARK: - Son izlenenler

    var recentChannels: [Channel] {
        recentNames.compactMap(channel(named:))
    }

    var lastChannel: Channel? {
        recentChannels.first
    }

    /// İzleme süresi en yüksek kanal (hiç izleme yoksa nil).
    var mostWatchedChannel: Channel? {
        let now = Date()
        return channels.max { watchScore(of: $0, at: now) < watchScore(of: $1, at: now) }
            .flatMap { watchScore(of: $0, at: now) > 0 ? $0 : nil }
    }

    /// Açılışta oynatılacak kanal; ayara göre, yoksa son izlenen.
    var startupChannel: Channel? {
        switch startupBehavior {
        case .mostWatched: return mostWatchedChannel ?? lastChannel
        case .lastChannel: return lastChannel
        case .home: return nil
        }
    }

    func recordWatched(_ channel: Channel) {
        recentNames.removeAll { $0 == channel.name }
        recentNames.insert(channel.name, at: 0)
        recentNames = Array(recentNames.prefix(Self.recentLimit))
        defaults.set(recentNames, forKey: Keys.recents)
    }

    func clearRecents() {
        recentNames = []
        defaults.removeObject(forKey: Keys.recents)
    }

    // MARK: - İzleme süresi

    func watchScore(of channel: Channel, at date: Date = Date()) -> TimeInterval {
        guard let entry = watchHistory[channel.name], entry.count == 2 else { return 0 }
        let age = date.timeIntervalSince1970 - entry[1]
        return entry[0] * pow(0.5, max(0, age) / Self.watchHalfLife)
    }

    func addWatchTime(_ seconds: TimeInterval, to channel: Channel) {
        guard seconds > 0 else { return }
        let now = Date()
        watchHistory[channel.name] = [watchScore(of: channel, at: now) + seconds, now.timeIntervalSince1970]
        defaults.set(watchHistory, forKey: Keys.watchHistory)
    }

    func clearWatchHistory() {
        watchHistory = [:]
        defaults.removeObject(forKey: Keys.watchHistory)
        clearRecents()
    }
}
