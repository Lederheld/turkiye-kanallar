import XCTest
@testable import TurkiyeTV

final class M3UParserTests: XCTestCase {
    func testParsesAttributesHeadersAndGroups() throws {
        let text = """
        #EXTM3U
        #EXTINF:-1 tvg-id="TRT1.tr" tvg-logo="https://example.com/trt1.png" group-title="Ulusal",TRT 1
        #EXTVLCOPT:http-user-agent=Mozilla/5.0
        #EXTVLCOPT:http-referrer=https://www.trt.net.tr/
        https://tv-trt1.medya.trt.com.tr/master.m3u8
        #EXTINF:-1,Halk TV, Canlı
        #EXTGRP:Haber
        https://halktv-live.daioncdn.net/halktv/halktv.m3u8
        """
        let channels = M3UParser.parse(text)
        XCTAssertEqual(channels.count, 2)
        let trt = channels[0]
        XCTAssertEqual(trt.name, "TRT 1")
        XCTAssertEqual(trt.tvgID, "TRT1.tr")
        XCTAssertEqual(trt.logoURL?.absoluteString, "https://example.com/trt1.png")
        XCTAssertEqual(trt.group, "Ulusal")
        XCTAssertEqual(trt.userAgent, "Mozilla/5.0")
        XCTAssertEqual(trt.referrer, "https://www.trt.net.tr/")
        XCTAssertEqual(channels[1].name, "Halk TV, Canlı", "adın içindeki virgül korunur")
        XCTAssertEqual(channels[1].group, "Haber")
    }

    func testIgnoresEntriesWithoutURL() {
        XCTAssertTrue(M3UParser.parse("#EXTM3U\n#EXTINF:-1,Boş\n").isEmpty)
    }

    func testCategories() {
        func category(_ name: String) -> ChannelCategory {
            Channel(name: name, tvgID: nil, logoURL: nil, group: nil, streamURL: URL(string: "https://x.tr/a.m3u8")!,
                    userAgent: nil, referrer: nil).category
        }
        XCTAssertEqual(category("TRT Haber"), .news)
        XCTAssertEqual(category("TRT Spor Yıldız"), .sports)
        XCTAssertEqual(category("Minika Çocuk"), .kids)
        XCTAssertEqual(category("Show TV"), .national)
    }
}

final class NormalizeTests: XCTestCase {
    func testTurkishAndHDVariantsCollapse() {
        XCTAssertEqual(ProgramGuide.normalize("TRT 1 HD"), "trt1")
        XCTAssertEqual(ProgramGuide.normalize("TRT.1.HD.tr"), "trt1")
        XCTAssertEqual(ProgramGuide.normalize("TRT Spor Yıldız"), "trtsporyildiz")
        XCTAssertEqual(ProgramGuide.normalize("İZ TV"), "iztv")
        XCTAssertEqual(ProgramGuide.normalize("TV8,5"), "tv85")
    }
}

final class StreamSourcesTests: XCTestCase {
    func testAdaptiveMasterFromSingleQuality() {
        let url = URL(string: "https://example.com/atv/atv_1080p.m3u8?token=abc")!
        XCTAssertEqual(StreamSources.adaptiveMaster(of: url)?.absoluteString, "https://example.com/atv/atv.m3u8?token=abc")
        XCTAssertNil(StreamSources.adaptiveMaster(of: URL(string: "https://example.com/atv/atv.m3u8")!))
    }
}

final class PlaybackFailureTests: XCTestCase {
    func testOfflineWins() {
        XCTAssertEqual(PlaybackFailure(error: nil, isOnline: false).kind, .offline)
    }

    func testStallWithoutErrorIsTimeout() {
        XCTAssertEqual(PlaybackFailure(error: nil, isOnline: true).kind, .timeout)
    }

    func testHTTPStatusFromErrorLog() {
        let error = NSError(domain: AVFoundationErrorDomainForTests, code: -11828)
        XCTAssertEqual(PlaybackFailure(error: error, logComment: "HTTP 403: Forbidden", isOnline: true).kind, .forbidden)
        XCTAssertEqual(PlaybackFailure(error: error, logComment: "HTTP 404: File Not Found", isOnline: true).kind, .notFound)
        XCTAssertEqual(PlaybackFailure(error: error, logComment: nil, isOnline: true).kind, .other)
    }

    func testURLErrorsAndUnderlyingCoreMediaCodes() {
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertEqual(PlaybackFailure(error: timeout, isOnline: true).kind, .timeout)
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(PlaybackFailure(error: offline, isOnline: true).kind, .offline)
        let wrapped = NSError(domain: AVFoundationErrorDomainForTests, code: -11800,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: "CoreMediaErrorDomain", code: -12938)])
        XCTAssertEqual(PlaybackFailure(error: wrapped, isOnline: true).kind, .notFound)
    }
}

private let AVFoundationErrorDomainForTests = "AVFoundationErrorDomain"

final class CloudSyncTests: XCTestCase {
    func testUnionKeepsLocalOrder() {
        XCTAssertEqual(CloudSync.union(["ATV", "TRT 1"], ["TRT 1", "Show TV"]), ["ATV", "TRT 1", "Show TV"])
    }

    func testHistoryKeepsNewerEntryPerChannel() {
        let local: [String: [Double]] = ["TRT 1": [100, 1_000], "ATV": [50, 3_000]]
        let cloud: [String: [Double]] = ["TRT 1": [900, 2_000], "ATV": [10, 2_500], "NOW": [5, 1]]
        let merged = CloudSync.mergeHistory(local, cloud)
        XCTAssertEqual(merged["TRT 1"], [900, 2_000])
        XCTAssertEqual(merged["ATV"], [50, 3_000])
        XCTAssertEqual(merged["NOW"], [5, 1])
    }
}

final class SiriTests: XCTestCase {
    func testSynonyms() {
        XCTAssertEqual(ChannelEntity.synonyms(for: "Show TV"), ["Show"])
        XCTAssertEqual(ChannelEntity.synonyms(for: "TRT 1"), ["TRT bir"])
        XCTAssertEqual(ChannelEntity.synonyms(for: "TV8,5"), ["TV sekiz buçuk"])
    }

    func testQueryMatchesSpokenForms() async throws {
        let key = IntentRouter.channelNamesKey
        let saved = UserDefaults.standard.stringArray(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(["TRT 1", "TRT 2", "ATV", "Show TV", "TV8,5"], forKey: key)
        let query = ChannelQuery()
        let atv = try await query.entities(matching: "atv").map(\.id)
        XCTAssertEqual(atv, ["ATV"])
        let show = try await query.entities(matching: "show").map(\.id)
        XCTAssertEqual(show, ["Show TV"])
        let trtBir = try await query.entities(matching: "TRT bir").map(\.id)
        XCTAssertEqual(trtBir, ["TRT 1"])
    }
}

final class TextTests: XCTestCase {
    func testDurations() {
        XCTAssertEqual(DurationText.short(45 * 60), "45 dk")
        XCTAssertEqual(DurationText.short(2 * 3600), "2 sa")
        XCTAssertEqual(DurationText.short(11 * 3600 + 34 * 60), "11 sa 34 dk")
        XCTAssertEqual(DurationText.clock(3725), "1:02:05")
        XCTAssertEqual(DurationText.clock(754), "12:34")
    }

    @MainActor
    func testGuideOriginIsPreviousHalfHour() {
        let date = ISO8601DateFormatter().date(from: "2026-10-18T09:47:12Z")!
        XCTAssertEqual(GuideView.currentOrigin(now: date), ISO8601DateFormatter().date(from: "2026-10-18T09:30:00Z")!)
    }
}

final class RemoteProtocolTests: XCTestCase {
    func testSignedRequestIsAcceptedOnlyWithSameKey() {
        let request = RemoteRequest.signed(.play, channel: "ATV", key: "ortak-anahtar")
        XCTAssertTrue(RemoteProtocol.isValid(request, key: "ortak-anahtar"))
        XCTAssertFalse(RemoteProtocol.isValid(request, key: "baska-anahtar"))
    }

    func testTamperedRequestIsRejected() {
        var request = RemoteRequest.signed(.play, channel: "ATV", key: "k")
        request.channel = "Show TV"
        XCTAssertFalse(RemoteProtocol.isValid(request, key: "k"))
    }

    func testOldRequestIsRejected() {
        let request = RemoteRequest.signed(.zap, offset: 1, key: "k")
        XCTAssertFalse(RemoteProtocol.isValid(request, key: "k", now: Date().addingTimeInterval(600)))
    }
}
