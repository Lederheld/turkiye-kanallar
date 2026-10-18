import Foundation
import Network

/// Kanal açılamadığında nedenin kullanıcıya anlaşılır hali.
struct PlaybackFailure: Equatable {
    enum Kind: Equatable {
        /// Apple TV'nin internet bağlantısı yok: bağlantı gelince kendiliğinden tekrar denenir.
        case offline
        /// Sunucu erişimi reddetti (403/401): çoğunlukla yurt dışı engeli ya da süresi dolmuş link.
        case forbidden
        /// Yayın adresi kaldırılmış (404/410).
        case notFound
        /// Bağlantı kuruldu ama görüntü gelmedi (zaman aşımı, donma).
        case timeout
        case other
    }

    let kind: Kind
    let detail: String?

    /// `logComment`: AVPlayerItem hata günlüğünün son kaydı (ör. "HTTP 403: Forbidden"); HLS'te HTTP kodu
    /// çoğu zaman yalnızca orada görünür.
    init(error: Error?, logComment: String? = nil, isOnline: Bool) {
        detail = error.map { $0.localizedDescription }
        if !isOnline {
            kind = .offline
        } else if let code = logComment.flatMap(Self.httpStatus) {
            kind = [401, 403].contains(code) ? .forbidden : [404, 410].contains(code) ? .notFound : Self.classify(error)
        } else {
            kind = Self.classify(error)
        }
    }

    private static func httpStatus(in comment: String) -> Int? {
        guard let range = comment.range(of: #"HTTP (\d{3})"#, options: .regularExpression) else { return nil }
        return Int(comment[range].dropFirst(5))
    }

    var symbol: String {
        switch kind {
        case .offline: "wifi.slash"
        case .forbidden: "lock.fill"
        case .notFound: "questionmark.video.fill"
        case .timeout: "hourglass"
        case .other: "exclamationmark.triangle.fill"
        }
    }

    var title: String {
        switch kind {
        case .offline: "İnternet bağlantısı yok"
        case .forbidden: "Yayın erişime kapalı"
        case .notFound: "Yayın adresi değişmiş"
        case .timeout: "Yayın yanıt vermiyor"
        case .other: "Kanal açılamadı"
        }
    }

    func explanation(for channel: Channel) -> String {
        switch kind {
        case .offline:
            "Bağlantı gelince \(channel.name) kendiliğinden açılacak."
        case .forbidden:
            "\(channel.name) yayını reddetti; link süresi dolmuş ya da kanal geçici olarak kısıtlamış olabilir. "
                + "Liste düzenli yenilendiği için birazdan düzelir."
        case .notFound:
            "\(channel.name) yayın adresini değiştirmiş. Liste bir sonraki yenilemede yeni adresi alacak."
        case .timeout:
            "\(channel.name) sunucusu şu an görüntü göndermiyor; kanal kendi tarafında sorun yaşıyor olabilir."
        case .other:
            "Tüm kaynaklar denendi."
        }
    }

    private static func classify(_ error: Error?) -> Kind {
        guard let error else { return .timeout }  // hatasız takılma: izleyici donmayı yakaladı
        var errors: [NSError] = [error as NSError]
        while let underlying = errors.last?.userInfo[NSUnderlyingErrorKey] as? NSError, errors.count < 6 {
            errors.append(underlying)
        }
        for nsError in errors {
            if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                     NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                    return nsError.code == NSURLErrorNotConnectedToInternet ? .offline : .timeout
                case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost:
                    return .timeout
                case NSURLErrorUserAuthenticationRequired, NSURLErrorNoPermissionsToReadFile:
                    return .forbidden
                default:
                    break
                }
            }
            // CoreMedia HTTP hataları: -12660 = 403, -12938 = 404, -12937 = kimlik doğrulama
            switch nsError.code {
            case -12660, -12937: return .forbidden
            case -12938: return .notFound
            default: break
            }
            let text = nsError.localizedDescription + " " + (nsError.localizedFailureReason ?? "")
            if text.contains("403") || text.contains("401") { return .forbidden }
            if text.contains("404") || text.contains("410") { return .notFound }
        }
        return .other
    }
}

/// İnternet bağlantısını izler; bağlantı gidip gelince bekleyen kanal kendiliğinden yeniden açılır.
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isOnline = true
    private let monitor = NWPathMonitor()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.update(online) }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }

    /// Bağlantı varsa hemen döner, yoksa gelene kadar bekler.
    func waitUntilOnline() async {
        guard !isOnline else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func update(_ online: Bool) {
        isOnline = online
        guard online else { return }
        let ready = waiters
        waiters.removeAll()
        ready.forEach { $0.resume() }
    }
}
