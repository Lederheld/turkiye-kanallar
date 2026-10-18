import CryptoKit
import Foundation

/// iPhone ↔ Apple TV kumanda protokolü: ev ağında Bonjour ile bulunur, TCP üzerinden satır başına bir JSON.
/// Her istek, iki cihazın yalnızca iCloud üzerinden paylaştığı rastgele bir anahtarla imzalanır; aynı ağdaki
/// başka biri kanal değiştiremez. Zaman damgası eski isteklerin tekrar gönderilmesini engeller.
enum RemoteProtocol {
    static let serviceType = "_canlitv._tcp"
    /// iCloud anahtar-değer deposundaki ortak anahtar (Apple TV üretir).
    static let keyName = "remoteKey"
    static let maximumClockSkew: TimeInterval = 120

    static func signature(for request: RemoteRequest, key: String) -> String {
        let message = "\(request.command.rawValue)|\(request.channel ?? "")|\(request.offset ?? 0)|\(Int(request.timestamp))"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(key.utf8)))
        return Data(mac).base64EncodedString()
    }

    static func isValid(_ request: RemoteRequest, key: String, now: Date = Date()) -> Bool {
        guard abs(now.timeIntervalSince1970 - request.timestamp) <= maximumClockSkew else { return false }
        let expected = signature(for: request, key: key)
        // sabit süreli karşılaştırma
        guard expected.utf8.count == request.signature.utf8.count else { return false }
        return zip(expected.utf8, request.signature.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

struct RemoteRequest: Codable {
    enum Command: String, Codable {
        case state, play, zap
    }

    var command: Command
    var channel: String?
    var offset: Int?
    var timestamp: TimeInterval
    var signature = ""

    static func signed(_ command: Command, channel: String? = nil, offset: Int? = nil, key: String) -> RemoteRequest {
        var request = RemoteRequest(command: command, channel: channel, offset: offset,
                                    timestamp: Date().timeIntervalSince1970.rounded(.down))
        request.signature = RemoteProtocol.signature(for: request, key: key)
        return request
    }
}

struct RemoteResponse: Codable {
    var ok: Bool
    /// Apple TV'de şu an oynayan kanal (oynatıcı kapalıysa nil).
    var channel: String?
    var error: String?
}
