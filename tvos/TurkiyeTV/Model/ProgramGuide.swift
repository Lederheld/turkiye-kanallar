import Compression
import Foundation

struct TVProgram: Codable, Hashable {
    let title: String
    let start: Date
    let end: Date

    func contains(_ date: Date) -> Bool {
        start <= date && date < end
    }
}

/// Yayın akışı. Önce gist'teki hazır özet (epg.json: GitHub'da 3 saatte bir kanallarımıza süzülür,
/// ~115 KB) indirilir; yoksa XMLTV kaynakları uygulamada eşlenir. Kaynaklar yalnızca bugünden ileriyi
/// verdiği için dünü geri sarabilmek adına önceki indirmeler önbellekte birleştirilir.
@MainActor
final class ProgramGuide: ObservableObject {
    /// Bizim kanal adı → saate göre sıralı programlar.
    @Published private(set) var programsByChannel: [String: [TVProgram]] = [:]

    /// Sırayla birleştirilir; bir kanal ilk kaynakta yoksa sonrakine bakılır.
    private static let sources = [
        URL(string: "https://epgshare01.online/epgshare01/epg_ripper_TR1.xml.gz")!,
        URL(string: "https://www.open-epg.com/files/turkey1.xml.gz")!,
    ]
    /// Akışta farklı adla geçen kanallar (normalize edilmiş ad → akıştaki ad).
    private static let aliases = ["now": "fox"]
    private static let refreshInterval: TimeInterval = 3 * 3600
    /// Bundan eski programlar atılır (24 saatlik geri sarma + pay).
    private static let retention: TimeInterval = 30 * 3600
    private static let requestTimeout: TimeInterval = 30

    private var lastRefresh: Date?
    private var refreshTask: Task<Void, Never>?

    init() {
        if let data = try? Data(contentsOf: Self.cacheURL),
           let cached = try? JSONDecoder().decode([String: [TVProgram]].self, from: data) {
            programsByChannel = cached
        }
    }

    // MARK: - Sorgular

    func programs(for channel: Channel) -> [TVProgram] {
        programsByChannel[channel.name] ?? []
    }

    func program(for channel: Channel, at date: Date = Date()) -> TVProgram? {
        programs(for: channel).last { $0.contains(date) }
    }

    // MARK: - İndirme

    /// `summaryURL`: gist'teki epg.json (playlist ile aynı gist).
    func refreshIfNeeded(for channels: [Channel], summaryURL: URL?) async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < Self.refreshInterval { return }
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { await refresh(for: channels, summaryURL: summaryURL) }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func refresh(for channels: [Channel], summaryURL: URL?) async {
        let names = channels.map(\.name)
        let previous = programsByChannel
        let merged = await Task.detached(priority: .utility) { () async -> [String: [TVProgram]]? in
            if let summaryURL, let summary = await Self.downloadSummary(summaryURL), !summary.isEmpty {
                return Self.merge(previous: previous, fresh: summary)
            }
            var fresh: [String: [TVProgram]] = [:]
            for source in Self.sources {
                guard let guide = await Self.download(source) else { continue }
                for (name, programs) in Self.match(names, in: guide) where fresh[name] == nil {
                    fresh[name] = programs
                }
            }
            return fresh.isEmpty ? nil : Self.merge(previous: previous, fresh: fresh)
        }.value
        guard let merged else { return }  // ağ yoksa eldeki akış kalır, sonra tekrar denenir
        lastRefresh = Date()
        programsByChannel = merged
        if let data = try? JSONEncoder().encode(merged) {
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }

    private nonisolated static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("epg.json")
    }

    /// Yeni akış önceliklidir; yenisinin başladığı saatten önceki eski programlar (dün) korunur.
    private nonisolated static func merge(previous: [String: [TVProgram]],
                                          fresh: [String: [TVProgram]]) -> [String: [TVProgram]] {
        let cutoff = Date().addingTimeInterval(-retention)
        var result: [String: [TVProgram]] = [:]
        for name in Set(previous.keys).union(fresh.keys) {
            let new = fresh[name] ?? []
            let freshStart = new.first?.start ?? .distantFuture
            let kept = (previous[name] ?? []).filter { $0.start < freshStart }
            result[name] = (kept + new).filter { $0.end > cutoff }
        }
        return result
    }

    // MARK: - Gist özeti

    private struct Summary: Decodable {
        let channels: [String: [[SummaryValue]]]
    }

    /// [başlangıç (unix sn), bitiş, "başlık"] dizisinin elemanları.
    private enum SummaryValue: Decodable {
        case number(Double)
        case text(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else {
                self = .text(try container.decode(String.self))
            }
        }
    }

    private nonisolated static func downloadSummary(_ url: URL) async -> [String: [TVProgram]]? {
        // Gist'in raw CDN önbelleğini atlamak için zaman damgası
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
        let request = URLRequest(url: components?.url ?? url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: requestTimeout)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let summary = try? JSONDecoder().decode(Summary.self, from: data) else { return nil }
        return summary.channels.mapValues { rows in
            rows.compactMap { row -> TVProgram? in
                guard row.count == 3, case .number(let start) = row[0], case .number(let end) = row[1],
                      case .text(let title) = row[2] else { return nil }
                return TVProgram(title: title, start: Date(timeIntervalSince1970: start),
                                 end: Date(timeIntervalSince1970: end))
            }
        }
    }

    // MARK: - XMLTV

    private struct ParsedGuide {
        var displayNames: [String: [String]] = [:]   // kanal id → adlar
        var programs: [String: [TVProgram]] = [:]    // kanal id → programlar
    }

    private nonisolated static func download(_ url: URL) async -> ParsedGuide? {
        let request = URLRequest(url: url, timeoutInterval: requestTimeout)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let xml = url.pathExtension == "gz" ? gunzip(data) : data else { return nil }
        let delegate = XMLTVParser()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()
        return ParsedGuide(displayNames: delegate.displayNames, programs: delegate.programs)
    }

    /// Akıştaki kanalı bizim kanal adına bağlar: "TRT.1.HD.tr" / "TRT 1 HD" → "trt1".
    private nonisolated static func match(_ names: [String], in guide: ParsedGuide) -> [String: [TVProgram]] {
        var byKey: [String: [TVProgram]] = [:]
        for (id, programs) in guide.programs where !programs.isEmpty {
            let keys = [id] + (guide.displayNames[id] ?? [])
            for key in Set(keys.map(normalize)) where (byKey[key]?.count ?? 0) < programs.count {
                byKey[key] = programs.sorted { $0.start < $1.start }
            }
        }
        var result: [String: [TVProgram]] = [:]
        for name in names {
            let key = normalize(name)
            if let programs = byKey[aliases[key] ?? key] {
                result[name] = programs
            }
        }
        return result
    }

    nonisolated static func normalize(_ name: String) -> String {
        var text = name.replacingOccurrences(of: "İ", with: "I").lowercased(with: Locale(identifier: "tr_TR"))
        text = text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
        if text.hasSuffix(".tr") { text.removeLast(3) }
        let words = text.split { !$0.isLetter && !$0.isNumber }.filter { $0 != "hd" }
        return words.joined()
    }

    /// .gz → ham DEFLATE (Compression çerçevesinin "zlib" algoritması başlıksız DEFLATE açar).
    private nonisolated static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {  // FEXTRA
            index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8
        }
        if flags & 0x08 != 0 { while index < bytes.count && bytes[index] != 0 { index += 1 }; index += 1 }  // FNAME
        if flags & 0x10 != 0 { while index < bytes.count && bytes[index] != 0 { index += 1 }; index += 1 }  // FCOMMENT
        if flags & 0x02 != 0 { index += 2 }  // FHCRC
        guard index < bytes.count - 8 else { return nil }
        let deflated = Data(bytes[index..<(bytes.count - 8)])
        return try? (deflated as NSData).decompressed(using: .zlib) as Data
    }
}

/// <channel id><display-name/></channel> ve <programme start stop channel><title/></programme>.
private final class XMLTVParser: NSObject, XMLParserDelegate {
    var displayNames: [String: [String]] = [:]
    var programs: [String: [TVProgram]] = [:]

    private var channelID: String?
    private var programme: (channel: String, start: Date, end: Date)?
    private var text = ""
    private var title: String?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        return formatter
    }()

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch element {
        case "channel":
            channelID = attributes["id"]
        case "programme":
            if let channel = attributes["channel"],
               let start = attributes["start"].flatMap(Self.dateFormatter.date(from:)),
               let end = attributes["stop"].flatMap(Self.dateFormatter.date(from:)) {
                programme = (channel, start, end)
                title = nil
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "display-name":
            if let channelID, !value.isEmpty { displayNames[channelID, default: []].append(value) }
        case "channel":
            channelID = nil
        case "title":
            if programme != nil, title == nil { title = value }
        case "programme":
            if let programme, let title, !title.isEmpty {
                programs[programme.channel, default: []]
                    .append(TVProgram(title: title, start: programme.start, end: programme.end))
            }
            programme = nil
        default:
            break
        }
    }
}
