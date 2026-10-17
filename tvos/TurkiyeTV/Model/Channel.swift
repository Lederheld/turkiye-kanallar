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


/// Playlist'te group-title olmadığından kategori kanal adından çıkarılır.
enum ChannelCategory: CaseIterable, Identifiable {
    case national, news, business, sports, kids, documentary, music, other

    var id: Self { self }

    var title: String {
        switch self {
        case .national: return "Ulusal"
        case .news: return "Haber"
        case .business: return "Ekonomi"
        case .sports: return "Spor"
        case .kids: return "Çocuk"
        case .documentary: return "Belgesel ve Yaşam"
        case .music: return "Müzik"
        case .other: return "Diğer"
        }
    }

    var symbol: String {
        switch self {
        case .national: return "tv"
        case .news: return "newspaper"
        case .business: return "chart.line.uptrend.xyaxis"
        case .sports: return "sportscourt"
        case .kids: return "balloon"
        case .documentary: return "globe.europe.africa"
        case .music: return "music.note"
        case .other: return "square.grid.2x2"
        }
    }

    private static let keywords: [(ChannelCategory, [String])] = [
        (.kids, ["çocuk", "minika", "cartoon", "disney"]),
        (.sports, ["spor", "fb tv", "gs tv", "bjk tv", "bein"]),
        (.business, ["bloomberg", "ekotürk", "cnbc"]),
        (.news, ["haber", "ntv", "cnn", "halk tv", "24 tv", "tvnet", "gzt", "world", "sözcü", "tele1"]),
        (.documentary, ["belgesel", "tlc", "dmax", "national geographic", "discovery"]),
        (.music, ["müzik", "power", "number1", "kral", "dream"]),
        (.other, ["avaz", "trt türk"]),
    ]

    static func of(_ channel: Channel) -> ChannelCategory {
        let name = channel.name.lowercased(with: Locale(identifier: "tr_TR"))
        return keywords.first { _, words in words.contains { name.contains($0) } }?.0 ?? .national
    }
}

extension Channel {
    var category: ChannelCategory { ChannelCategory.of(self) }
}
