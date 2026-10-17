import AVFoundation
import SwiftUI

@main
struct TurkiyeTVApp: App {
    @StateObject private var store = PlaylistStore()

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .task { await store.reload() }
        }
    }
}
