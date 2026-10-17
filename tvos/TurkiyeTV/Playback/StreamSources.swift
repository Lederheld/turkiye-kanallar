import Foundation

/// Bir kanal için sırayla denenecek yayın adresleri; en güvenilir olan önce.
/// Biri açılmaz ya da takılırsa oynatıcı sıradakine geçer.
enum StreamSources {
    struct Source: Equatable {
        let url: URL
        let headers: [String: String]
        let label: String
    }

    static func candidates(for channel: Channel) async -> [Source] {
        var sources: [Source] = []
        if let signed = SignedStream.byChannelName[channel.name], let url = await signed.resolve() {
            sources.append(Source(url: url, headers: [:], label: "resmi imzalı link"))
        }
        let playlistHeaders = headers(for: channel)
        sources.append(Source(url: channel.streamURL, headers: playlistHeaders, label: "liste"))
        if let master = adaptiveMaster(of: channel.streamURL) {
            sources.append(Source(url: master, headers: playlistHeaders, label: "ana playlist"))
        }
        return sources.reduce(into: []) { unique, source in
            if !unique.contains(where: { $0.url == source.url }) { unique.append(source) }
        }
    }

    /// Açılışta imzalı linkleri önceden al: kanal açılırken token beklenmesin.
    static func prefetchSignedLinks() async {
        for signed in SignedStream.byChannelName.values {
            _ = await signed.resolve()
        }
    }

    /// Bir sonraki denemede imzalı linkler yeniden alınsın.
    static func invalidateSignedLinks() async {
        for signed in SignedStream.byChannelName.values {
            await signed.invalidate()
        }
    }

    /// Playlist'teki #EXTVLCOPT header'ları (User-Agent / Referer).
    private static func headers(for channel: Channel) -> [String: String] {
        var headers: [String: String] = [:]
        if let userAgent = channel.userAgent { headers["User-Agent"] = userAgent }
        if let referrer = channel.referrer { headers["Referer"] = referrer }
        return headers
    }

    /// Tek kaliteli link (…/atv/atv_1080p.m3u8) yerine yanındaki ana playlist (…/atv/atv.m3u8):
    /// oynatıcı takılan kaliteden diğerine geçebilir.
    private static func adaptiveMaster(of url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.path
        guard let range = path.range(of: #"_\d{3,4}p\.m3u8$"#, options: .regularExpression) else { return nil }
        components.path = path.replacingCharacters(in: range, with: ".m3u8")
        return components.url
    }
}

/// Kanalın kendi sitesindeki token servisinden alınan, süreli ve IP'ye bağlı link.
/// Apple TV'nin kendisi istediği için CI'da alınan linklerin IP sorunu olmaz.
actor SignedStream {
    static let byChannelName: [String: SignedStream] = [
        // ATV: listedeki turknet CDN'i isteklerin çoğunda zaman aşımına uğruyor; sitenin kendi CDN'i sağlam
        "ATV": SignedStream(
            tokenService: "https://securevideotoken.tmgrup.com.tr/webtv/secure",
            streamURL: "https://trkvz.daioncdn.net/atv/atv.m3u8?ce=3&app=d1ce2d40-5256-4550-b02e-e73c185a314e",
            referrer: "https://www.atv.com.tr/"
        ),
    ]

    private struct Response: Decodable {
        let success: Bool
        let url: String?

        enum CodingKeys: String, CodingKey {
            case success = "Success"
            case url = "Url"
        }
    }

    private let tokenService: String
    private let streamURL: String
    private let referrer: String
    private var cached: (url: URL, validUntil: Date)?

    private static let requestTimeout: TimeInterval = 8
    /// Linkin `e` (bitiş) parametresinden bu kadar önce yenilenir.
    private static let renewalMargin: TimeInterval = 10 * 60
    private static let fallbackLifetime: TimeInterval = 30 * 60

    init(tokenService: String, streamURL: String, referrer: String) {
        self.tokenService = tokenService
        self.streamURL = streamURL
        self.referrer = referrer
    }

    func invalidate() {
        cached = nil
    }

    func resolve() async -> URL? {
        if let cached, cached.validUntil > Date() { return cached.url }
        guard var components = URLComponents(string: tokenService) else { return nil }
        components.queryItems = [URLQueryItem(name: "url", value: streamURL)]
        guard let requestURL = components.url else { return nil }
        var request = URLRequest(url: requestURL, timeoutInterval: Self.requestTimeout)
        request.setValue(referrer, forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              response.success, let url = response.url.flatMap(URL.init(string:)) else { return nil }
        cached = (url, Self.validUntil(of: url))
        return url
    }

    private static func validUntil(of url: URL) -> Date {
        let expiry = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "e" }?.value.flatMap(TimeInterval.init)
        return expiry.map { Date(timeIntervalSince1970: $0 - renewalMargin) } ?? Date().addingTimeInterval(fallbackLifetime)
    }
}
