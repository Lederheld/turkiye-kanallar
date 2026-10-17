import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var guide: ProgramGuide
    @Environment(\.scenePhase) private var scenePhase
    @State private var playingChannel: Channel?
    @State private var didResume = false

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Ana Sayfa", systemImage: "house") }
            BrowseView()
                .tabItem { Label("Kanallar", systemImage: "square.grid.2x2") }
            SearchView()
                .tabItem { Label("Ara", systemImage: "magnifyingglass") }
            SettingsView(store: store)
                .tabItem { Label("Ayarlar", systemImage: "gearshape") }
        }
        .background(AppBackground())
        .environment(\.playChannel, PlayChannelAction { playingChannel = $0 })
        .fullScreenCover(item: $playingChannel) { channel in
            PlayerScreen(channel: channel, store: store, guide: guide)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await store.reloadIfStale()
                    await guide.refreshIfNeeded(for: store.channels)
                }
            }
        }
        // Bir TV gibi: açılışta (ayara göre) en çok ya da son izlenen kanal başlar
        .onChange(of: store.channels.isEmpty, initial: true) { _, isEmpty in
            guard !isEmpty, !didResume else { return }
            didResume = true
            if let channel = store.startupChannel {
                playingChannel = channel
            }
        }
    }
}

/// Liste boşken ya da yüklenirken tüm sekmelerde aynı görünüm.
struct EmptyPlaylistView: View {
    @EnvironmentObject private var store: PlaylistStore

    var body: some View {
        Group {
            if store.isLoading {
                ProgressView("Kanallar yükleniyor…")
            } else {
                ContentUnavailableView {
                    Label("Kanal listesi yok", systemImage: "tv.slash")
                } description: {
                    Text(store.lastError ?? "Liste henüz indirilmedi. Ayarlar sekmesinden adresi kontrol edin.")
                } actions: {
                    Button("Tekrar dene") { Task { await store.reload() } }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 600)
    }
}
