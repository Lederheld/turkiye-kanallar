import SwiftUI

struct RemoteRootView: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var remote: RemoteClient
    @ObservedObject private var intents = IntentRouter.shared

    var body: some View {
        TabView {
            ChannelsTab()
                .tabItem { Label("Kanallar", systemImage: "tv") }
            TonightTab()
                .tabItem { Label("Bu Akşam", systemImage: "sparkles.tv") }
            RemindersTab()
                .tabItem { Label("Hatırlatmalar", systemImage: "bell") }
        }
        // Siri ("Canlı TV'de ATV'yi aç") ve bildirimler: kanal Apple TV'de açılır
        .onChange(of: intents.requestedChannelName, initial: true) { _, _ in openRequested() }
        .onChange(of: store.channels.isEmpty) { _, _ in openRequested() }
    }

    private func openRequested() {
        guard let name = intents.requestedChannelName, let channel = store.channel(named: name) else { return }
        intents.requestedChannelName = nil
        Task { await remote.play(channel) }
    }
}

// MARK: - Kanallar

private struct ChannelsTab: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var guide: ProgramGuide
    @EnvironmentObject private var remote: RemoteClient

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NowOnTVCard()
                }
                Section("Kanallar") {
                    ForEach(store.ordered(store.channels)) { channel in
                        ChannelRow(channel: channel)
                    }
                }
            }
            .navigationTitle("Canlı TV")
            .navigationDestination(for: String.self) { name in
                if let channel = store.channel(named: name) { ChannelGuideView(channel: channel) }
            }
            .refreshable {
                await remote.refresh()
                await store.reload()
            }
            .overlay {
                if store.channels.isEmpty {
                    ContentUnavailableView(store.isLoading ? "Kanallar yükleniyor…" : "Kanal listesi yok",
                                           systemImage: "tv.slash", description: Text(store.lastError ?? ""))
                }
            }
        }
    }
}

/// Apple TV'nin durumu ve önceki/sonraki kanal.
private struct NowOnTVCard: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var guide: ProgramGuide
    @EnvironmentObject private var remote: RemoteClient

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch remote.status {
            case .ready(let tvName):
                Label(tvName, systemImage: "appletv.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let name = remote.nowPlaying, let channel = store.channel(named: name) {
                    HStack(spacing: 14) {
                        LogoView(channel: channel)
                            .frame(width: 80, height: 45)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(channel.name).font(.headline)
                            if let program = guide.program(for: channel) {
                                Text("\(program.title) · \(ProgramText.timeRange(program))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                } else {
                    Text("Apple TV'de şu an kanal açık değil. Aşağıdan bir kanala dokun.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button { Task { await remote.zap(-1) } } label: {
                        Label("Önceki", systemImage: "chevron.down").frame(maxWidth: .infinity)
                    }
                    Button { Task { await remote.zap(1) } } label: {
                        Label("Sonraki", systemImage: "chevron.up").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
            case .searching:
                Label("Apple TV aranıyor…", systemImage: "antenna.radiowaves.left.and.right")
            case .unreachable:
                Label("Apple TV bulunamadı", systemImage: "appletv")
                Text("Apple TV'de Canlı TV açık olmalı ve iPhone aynı Wi-Fi ağında olmalı.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .noKey:
                Label("Eşleşme bekleniyor", systemImage: "icloud")
                Text("Apple TV'de Canlı TV'yi bir kez açın; iki cihaz iCloud üzerinden otomatik eşleşir.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .unauthorized:
                Label("Apple TV bu iPhone'u tanımadı", systemImage: "lock")
                Text("Apple TV'deki profil ile bu iPhone aynı Apple hesabında olmalı.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct ChannelRow: View {
    @EnvironmentObject private var guide: ProgramGuide
    @EnvironmentObject private var remote: RemoteClient
    let channel: Channel

    var body: some View {
        HStack(spacing: 14) {
            Button {
                Task { await remote.play(channel) }
            } label: {
                HStack(spacing: 14) {
                    LogoView(channel: channel)
                        .frame(width: 64, height: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(channel.name).font(.body.weight(.semibold))
                            if remote.nowPlaying == channel.name {
                                Text("TV'DE")
                                    .font(.caption2.weight(.heavy))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.accent, in: Capsule())
                                    .foregroundStyle(.white)
                            }
                        }
                        ProgramProgress(program: guide.program(for: channel))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            NavigationLink(value: channel.name) {
                EmptyView()
            }
            .frame(width: 20)
        }
    }
}

private struct ProgramProgress: View {
    let program: TVProgram?

    var body: some View {
        TimelineView(.everyMinute) { context in
            if let program {
                VStack(alignment: .leading, spacing: 4) {
                    Text(program.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ProgressView(value: min(max(context.date.timeIntervalSince(program.start)
                                                / max(program.end.timeIntervalSince(program.start), 1), 0), 1))
                }
            } else {
                Text(" ").font(.subheadline)
            }
        }
    }
}

struct LogoView: View {
    let channel: Channel
    @ObservedObject private var cache = LogoCache.shared

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white)
            if let url = channel.logoURL, let image = cache.image(for: url) {
                Image(uiImage: image).resizable().scaledToFit().padding(5)
            } else {
                Text(channel.initials).font(.caption.bold()).foregroundStyle(.gray)
            }
        }
        .onAppear { if let url = channel.logoURL { cache.load(url) } }
    }
}

// MARK: - Kanal akışı

private struct ChannelGuideView: View {
    @EnvironmentObject private var guide: ProgramGuide
    @EnvironmentObject private var remote: RemoteClient
    let channel: Channel

    var body: some View {
        List {
            Section {
                Button {
                    Task { await remote.play(channel) }
                } label: {
                    Label("Apple TV'de aç", systemImage: "appletv.fill")
                }
            }
            Section("Yayın akışı") {
                let upcoming = guide.programs(for: channel).filter { $0.end > Date() }
                if upcoming.isEmpty {
                    Text("Akış yok").foregroundStyle(.secondary)
                }
                ForEach(upcoming, id: \.self) { program in
                    ProgramReminderRow(item: ScheduledProgram(channel: channel, program: program), showsChannel: false)
                }
            }
        }
        .navigationTitle(channel.name)
    }
}

/// Program satırı; ilerideki programlarda zil ile hatırlatıcı kurulur, yayındakine dokununca TV'de açılır.
private struct ProgramReminderRow: View {
    @EnvironmentObject private var reminders: ReminderStore
    @EnvironmentObject private var remote: RemoteClient
    let item: ScheduledProgram
    var showsChannel = true

    var body: some View {
        let isLive = item.program.contains(Date())
        let isSet = reminders.isSet(item.channel, item.program)
        HStack(spacing: 12) {
            if showsChannel {
                LogoView(channel: item.channel).frame(width: 56, height: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.program.title).font(.body.weight(.medium)).lineLimit(2)
                Text(subtitle(isLive: isLive))
                    .font(.footnote)
                    .foregroundStyle(isLive ? Theme.accent : .secondary)
            }
            Spacer(minLength: 0)
            if isLive {
                Button {
                    Task { await remote.play(item.channel) }
                } label: {
                    Image(systemName: "play.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
            } else {
                Button {
                    reminders.toggle(item.channel, item.program)
                } label: {
                    Image(systemName: isSet ? "bell.fill" : "bell").font(.title3)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isSet ? "Hatırlatmayı kaldır" : "Hatırlat")
            }
        }
    }

    private func subtitle(isLive: Bool) -> String {
        let channel = showsChannel ? "\(item.channel.name) · " : ""
        let day = Calendar.current.isDateInToday(item.program.start) ? "" : "Yarın "
        return isLive ? "\(channel)Şimdi · \(ProgramText.timeRange(item.program))"
            : "\(channel)\(day)\(ProgramText.timeRange(item.program))"
    }
}

// MARK: - Bu Akşam ve hatırlatmalar

private struct TonightTab: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var guide: ProgramGuide

    var body: some View {
        NavigationStack {
            let items = Tonight.programs(store: store, guide: guide)
            List(items) { item in
                ProgramReminderRow(item: item)
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("Bu akşam için akış yok", systemImage: "sparkles.tv")
                }
            }
            .navigationTitle("Bu Akşam")
        }
    }
}

private struct RemindersTab: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var reminders: ReminderStore

    var body: some View {
        NavigationStack {
            let items = reminders.reminders.compactMap { reminder -> ScheduledProgram? in
                store.channel(named: reminder.channelName).map {
                    ScheduledProgram(channel: $0, program: TVProgram(title: reminder.title, start: reminder.start,
                                                                     end: reminder.end))
                }
            }
            List(items) { item in
                ProgramReminderRow(item: item)
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("Hatırlatma yok", systemImage: "bell",
                                           description: Text("Bu Akşam'dan ya da bir kanalın akışından zile dokun. "
                                                             + "Apple TV'de kurulanlar da burada görünür."))
                }
            }
            .navigationTitle("Hatırlatmalar")
        }
    }
}
