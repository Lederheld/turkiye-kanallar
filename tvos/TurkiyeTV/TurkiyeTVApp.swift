import AVFoundation
import SwiftUI

@main
struct TurkiyeTVApp: App {
    @StateObject private var store = PlaylistStore()

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        // Kanal logoları her açılışta yeniden inmesin
        URLCache.shared = URLCache(memoryCapacity: 32 << 20, diskCapacity: 128 << 20)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .task { await store.reload() }
        }
    }
}
