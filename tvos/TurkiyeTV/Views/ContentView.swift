import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var guide: ProgramGuide
    @EnvironmentObject private var reminders: ReminderStore
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
            PlayerScreen(channel: channel, store: store, guide: guide, reminders: reminders)
        }
        // Oynatıcı kapalıyken (ana ekranda) hatırlatma: oynatıcıdaysa orada kart olarak çıkar
        .alert(dueReminder.map { "\($0.channelName) · \(ProgramText.clock($0.start))" } ?? "",
               isPresented: Binding(get: { playingChannel == nil && dueReminder != nil },
                                    set: { if !$0 { reminders.dismissDue() } }),
               presenting: dueReminder) { reminder in
            Button("İzle") {
                playingChannel = store.channel(named: reminder.channelName)
                reminders.dismissDue()
            }
            Button("Kapat", role: .cancel) { reminders.dismissDue() }
        } message: { reminder in
            Text(reminder.start > Date() ? "\(reminder.title) birazdan başlıyor" : "\(reminder.title) başladı")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await store.reloadIfStale()
                    await guide.refreshIfNeeded(for: store.channels, summaryURL: store.epgSummaryURL)
                }
            }
        }
        // Bir TV gibi: açılışta (ayara göre) en çok ya da son izlenen kanal başlar
        .onChange(of: store.channels.isEmpty, initial: true) { _, isEmpty in
            guard !isEmpty, !didResume else { return }
            didResume = true
            // Hatırlatılan program şu an yayındaysa açılışta o kanal gelir
            if let live = reminders.live, let channel = store.channel(named: live.channelName) {
                playingChannel = channel
                reminders.dismissDue()
            } else if let channel = store.startupChannel {
                playingChannel = channel
            }
        }
    }

    private var dueReminder: Reminder? {
        reminders.due.flatMap { store.channel(named: $0.channelName) == nil ? nil : $0 }
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
