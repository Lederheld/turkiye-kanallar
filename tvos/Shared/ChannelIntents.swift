import AppIntents
import Foundation

/// Siri: "Canlı TV'de ATV'yi aç", "Canlı TV'de Show TV aç", "Canlı TV'de TRT 1 kanalını aç".
/// Apple, kısayol cümlelerinde uygulama adını şart koşuyor; ad bu yüzden kısa: "Canlı TV".
struct OpenChannelIntent: AppIntent {
    static let title: LocalizedStringResource = "Kanalı aç"
    static let description = IntentDescription("Canlı TV'de seçilen kanalı tam ekran açar.")
    static let openAppWhenRun = true

    @Parameter(title: "Kanal")
    var channel: ChannelEntity

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$channel) kanalını aç")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.requestedChannelName = channel.id
        return .result()
    }
}

struct ChannelEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Kanal"
    static let defaultQuery = ChannelQuery()

    /// Kanalın listedeki adı ("Show TV").
    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)", synonyms: Self.synonyms(for: id).map { "\($0)" })
    }

    /// Söylenişe yakın diğer adlar: "Show TV" → "Show"; "TRT 1" → "TRT bir"; "TV8,5" → "TV sekiz buçuk".
    static func synonyms(for name: String) -> [String] {
        var result: [String] = []
        if name.hasSuffix(" TV") { result.append(String(name.dropLast(3))) }
        let numbers = ["0": "sıfır", "1": "bir", "2": "iki", "3": "üç", "4": "dört", "5": "beş",
                       "6": "altı", "7": "yedi", "8": "sekiz", "9": "dokuz"]
        if name.contains(where: \.isNumber) {
            var spoken = name.replacingOccurrences(of: ",5", with: " buçuk")
            for (digit, word) in numbers { spoken = spoken.replacingOccurrences(of: digit, with: " \(word)") }
            result.append(spoken.split(separator: " ").joined(separator: " "))
        }
        return result
    }
}

struct ChannelQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ChannelEntity] {
        let names = Set(Self.channelNames)
        return identifiers.filter(names.contains).map(ChannelEntity.init(id:))
    }

    /// "atv", "show", "trt bir" gibi söylenişler de eşleşir.
    func entities(matching string: String) async throws -> [ChannelEntity] {
        let query = ProgramGuide.normalize(string)
        guard !query.isEmpty else { return [] }
        let matches = Self.channelNames.filter { name in
            ([name] + ChannelEntity.synonyms(for: name)).map(ProgramGuide.normalize).contains { $0 == query }
        }
        if !matches.isEmpty { return matches.map(ChannelEntity.init(id:)) }
        return Self.channelNames.filter { ProgramGuide.normalize($0).hasPrefix(query) }.map(ChannelEntity.init(id:))
    }

    func suggestedEntities() async throws -> [ChannelEntity] {
        Self.channelNames.map(ChannelEntity.init(id:))
    }

    /// PlaylistStore liste her yüklendiğinde yazar (Siri uygulama açılmadan da kanalları bilsin).
    static var channelNames: [String] {
        UserDefaults.standard.stringArray(forKey: IntentRouter.channelNamesKey) ?? []
    }
}

struct CanliTVShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenChannelIntent(),
            phrases: [
                // Türkçe ek, kanal adının son sesine göre değişiyor; yaygın biçimlerin hepsi
                "\(.applicationName)'de \(\.$channel) aç",
                "\(.applicationName)'de \(\.$channel)'yi aç",
                "\(.applicationName)'de \(\.$channel)'ı aç",
                "\(.applicationName)'de \(\.$channel)'i aç",
                "\(.applicationName)'de \(\.$channel)'u aç",
                "\(.applicationName)'de \(\.$channel)'ü aç",
                "\(.applicationName)'de \(\.$channel)'yu aç",
                "\(.applicationName)'de \(\.$channel)'yü aç",
                "\(.applicationName)'de \(\.$channel) kanalını aç",
                "\(.applicationName)'de \(\.$channel) izle",
                "\(.applicationName)'de \(\.$channel)'ye geç",
                "\(.applicationName)'de \(\.$channel)'a geç",
                "\(.applicationName)'de \(\.$channel)'e geç",
                "\(.applicationName) \(\.$channel)",
            ],
            shortTitle: "Kanal aç",
            systemImageName: "tv"
        )
    }
}

/// Siri'den gelen kanal isteğini arayüze iletir (ContentView açar).
@MainActor
final class IntentRouter: ObservableObject {
    static let shared = IntentRouter()
    static let channelNamesKey = "intentChannelNames"

    @Published var requestedChannelName: String?
    /// iPhone kumandasından önceki/sonraki kanal isteği (her istek yeni kimlikle, aynı yön tekrar edebilsin).
    @Published var zapRequest: ZapRequest?
    /// Apple TV'de şu an oynayan kanal; iPhone'a bildirilir.
    @Published var nowPlayingChannelName: String?

    struct ZapRequest: Equatable {
        let offset: Int
        let id = UUID()
    }

    /// Kanal listesi değişince Siri'nin tanıdığı adlar güncellenir.
    static func publishChannelNames(_ names: [String]) {
        guard UserDefaults.standard.stringArray(forKey: channelNamesKey) != names else { return }
        UserDefaults.standard.set(names, forKey: channelNamesKey)
        CanliTVShortcuts.updateAppShortcutParameters()
    }
}
