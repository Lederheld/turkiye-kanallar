import AVFoundation
import SwiftUI

@main
struct TurkiyeTVApp: App {
    @StateObject private var store = PlaylistStore()
    @StateObject private var guide = ProgramGuide()

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        // Kanal logoları her açılışta yeniden inmesin
        URLCache.shared = URLCache(memoryCapacity: 32 << 20, diskCapacity: 128 << 20)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(guide)
                .preferredColorScheme(.dark)
                .task {
                    // İmzalı linkler (ATV) hemen: kanal açılırken token beklenmesin
                    async let signed: Void = StreamSources.prefetchSignedLinks()
                    await store.reload()
                    // Açılışta bir kanal oynuyorsa logolar ve yayın akışı birkaç saniye sonra iner;
                    // ilk görüntü için bant genişliği yayına kalsın
                    if store.startupChannel != nil {
                        try? await Task.sleep(for: .seconds(4))
                    }
                    await LogoCache.shared.prefetch(store.channels.compactMap(\.logoURL))
                    _ = await signed
                    await guide.refreshIfNeeded(for: store.channels, summaryURL: store.epgSummaryURL)
                    // Açık kaldıkça liste ve akış kendiliğinden tazelenir; elle "Yenile" gerekmez
                    while !Task.isCancelled {
                        try? await Task.sleep(for: PlaylistStore.autoRefreshInterval)
                        await store.reloadIfStale()
                        await guide.refreshIfNeeded(for: store.channels, summaryURL: store.epgSummaryURL)
                    }
                }
        }
    }
}
