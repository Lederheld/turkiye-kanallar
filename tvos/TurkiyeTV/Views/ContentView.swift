import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: PlaylistStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var playingChannel: Channel?
    @State private var showingSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 56) {
                header
                if store.channels.isEmpty {
                    emptyState
                } else {
                    if !store.favoriteChannels.isEmpty {
                        ChannelSection(title: "Favoriler", channels: store.favoriteChannels, onSelect: play)
                    }
                    ForEach(store.sections) { section in
                        ChannelSection(title: section.title, channels: section.channels, onSelect: play)
                    }
                }
            }
            .padding(.vertical, 20)
        }
        .fullScreenCover(item: $playingChannel) { channel in
            PlayerScreen(channel: channel, store: store)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(store: store)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.reloadIfStale() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 32) {
            Text("Türkiye TV")
                .font(.largeTitle.bold())
            Spacer()
            if store.isLoading {
                ProgressView()
            }
            Button {
                Task { await store.reload() }
            } label: {
                Label("Yenile", systemImage: "arrow.clockwise")
            }
            Button {
                showingSettings = true
            } label: {
                Label("Ayarlar", systemImage: "gearshape")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.isLoading {
            ProgressView("Kanallar yükleniyor…")
                .frame(maxWidth: .infinity, minHeight: 400)
        } else {
            ContentUnavailableView {
                Label("Kanal listesi yok", systemImage: "tv.slash")
            } description: {
                Text(store.lastError ?? "Liste henüz indirilmedi.")
            } actions: {
                Button("Ayarlar") { showingSettings = true }
            }
            .frame(maxWidth: .infinity, minHeight: 400)
        }
    }

    private func play(_ channel: Channel) {
        playingChannel = channel
    }
}
