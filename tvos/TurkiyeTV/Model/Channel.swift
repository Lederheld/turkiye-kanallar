import Foundation

struct Channel: Identifiable, Hashable {
    let name: String
    let tvgID: String?
    let logoURL: URL?
    let group: String?
    let streamURL: URL
    let userAgent: String?
    let referrer: String?

    var id: String { name }

    /// Logo yokken kartta gösterilecek kısaltma ("TRT 1" → "T1").
    var initials: String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap(\.first).map(String.init).joined().uppercased()
    }
}

struct ChannelGroup: Identifiable {
    let title: String
    let channels: [Channel]

    var id: String { title }
}
