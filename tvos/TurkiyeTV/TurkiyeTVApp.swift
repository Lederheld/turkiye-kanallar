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
                    await store.reload()
                    await guide.refreshIfNeeded(for: store.channels)
                    // Açık kaldıkça liste ve akış kendiliğinden tazelenir; elle "Yenile" gerekmez
                    while !Task.isCancelled {
                        try? await Task.sleep(for: PlaylistStore.autoRefreshInterval)
                        await store.reloadIfStale()
                        await guide.refreshIfNeeded(for: store.channels)
                    }
                }
        }
    }
}
