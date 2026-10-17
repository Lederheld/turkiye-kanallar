import Foundation

/// build_playlist.py / refresh_tokens.py'nin ürettiği M3U formatını okur:
///   #EXTINF:-1 tvg-id="..." tvg-name="..." tvg-logo="..." [group-title="..."],Kanal Adı
///   #EXTVLCOPT:http-user-agent=...   (isteğe bağlı)
///   #EXTVLCOPT:http-referrer=...     (isteğe bağlı)
///   https://.../yayin.m3u8
enum M3UParser {
    private static let userAgentPrefix = "#EXTVLCOPT:http-user-agent="
    private static let referrerPrefixes = ["#EXTVLCOPT:http-referrer=", "#EXTVLCOPT:http-referer="]
    private static let groupPrefix = "#EXTGRP:"
    private static let attributePattern = try! NSRegularExpression(pattern: #"([A-Za-z0-9_-]+)="([^"]*)""#)

    static func parse(_ text: String) -> [Channel] {
        var channels: [Channel] = []
        var seenNames = Set<String>()
        var pending: PendingEntry?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXTINF") {
                pending = PendingEntry(infoLine: line)
            } else if line.hasPrefix(userAgentPrefix) {
                pending?.userAgent = nonEmpty(String(line.dropFirst(userAgentPrefix.count)))
            } else if let prefix = referrerPrefixes.first(where: { line.hasPrefix($0) }) {
                pending?.referrer = nonEmpty(String(line.dropFirst(prefix.count)))
            } else if line.hasPrefix(groupPrefix) {
                pending?.group = nonEmpty(String(line.dropFirst(groupPrefix.count)))
            } else if line.hasPrefix("#") {
                continue
            } else if let entry = pending, let url = URL(string: line) {
                pending = nil
                // Aynı ada sahip ikinci kayıt atlanır (kanal kimliği addır)
                guard seenNames.insert(entry.name).inserted else { continue }
                channels.append(entry.makeChannel(streamURL: url))
            }
        }
        return channels
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private struct PendingEntry {
        var name: String
        var attributes: [String: String]
        var group: String?
        var userAgent: String?
        var referrer: String?

        init(infoLine: String) {
            let (attributePart, title) = Self.split(infoLine)
            attributes = Self.attributes(in: attributePart)
            name = M3UParser.nonEmpty(title) ?? M3UParser.nonEmpty(attributes["tvg-name"]) ?? "Adsız kanal"
            group = M3UParser.nonEmpty(attributes["group-title"])
        }

        func makeChannel(streamURL: URL) -> Channel {
            Channel(
                name: name,
                tvgID: M3UParser.nonEmpty(attributes["tvg-id"]),
                logoURL: M3UParser.nonEmpty(attributes["tvg-logo"]).flatMap { URL(string: $0) },
                group: group,
                streamURL: streamURL,
                userAgent: userAgent,
                referrer: referrer
            )
        }

        /// Tırnak dışındaki ilk virgül öznitelikleri kanal adından ayırır.
        private static func split(_ line: String) -> (attributes: String, title: String) {
            var insideQuotes = false
            for index in line.indices {
                switch line[index] {
                case "\"":
                    insideQuotes.toggle()
                case "," where !insideQuotes:
                    return (String(line[..<index]), String(line[line.index(after: index)...]))
                default:
                    break
                }
            }
            return (line, "")
        }

        private static func attributes(in text: String) -> [String: String] {
            let range = NSRange(text.startIndex..., in: text)
            var result: [String: String] = [:]
            for match in M3UParser.attributePattern.matches(in: text, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: text),
                      let valueRange = Range(match.range(at: 2), in: text) else { continue }
                result[text[keyRange].lowercased()] = String(text[valueRange])
            }
            return result
        }
    }
}
