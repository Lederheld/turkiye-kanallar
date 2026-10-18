import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var guide: ProgramGuide
    @EnvironmentObject private var reminders: ReminderStore

    /// Ana sayfa: en üstte tüm kanallar tek satırda, en çok izlenen başta; sonra Bu Akşam, sonra kategoriler.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if store.channels.isEmpty {
                    EmptyPlaylistView()
                } else {
                    ChannelShelf(title: "Kanallar", symbol: "chart.bar.fill", channels: store.ordered(store.channels))
                    let tonight = Tonight.programs(store: store, guide: guide)
                    if !tonight.isEmpty {
                        ProgramShelf(title: "Bu Akşam", symbol: "sparkles.tv", items: tonight)
                    }
                    // yarınki maç gibi Bu Akşam'da görünmeyen hatırlatmalar (yalnızca kurulmuşsa)
                    let upcoming = remindedPrograms(excluding: Set(tonight.map(\.id)))
                    if !upcoming.isEmpty {
                        ProgramShelf(title: "Hatırlatmalar", symbol: "bell.fill", items: upcoming)
                    }
                    ForEach(store.categorySections, id: \.category) { section in
                        ChannelShelf(title: section.category.title, symbol: section.category.symbol,
                                     channels: section.channels)
                    }
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 80)
        }
    }

    /// "Bu Akşam"da görünmeyen hatırlatmalar (ör. yarınki maç).
    private func remindedPrograms(excluding shown: Set<String>) -> [ScheduledProgram] {
        reminders.reminders.compactMap { reminder in
            guard let channel = store.channel(named: reminder.channelName) else { return nil }
            let item = ScheduledProgram(channel: channel,
                                        program: TVProgram(title: reminder.title, start: reminder.start, end: reminder.end))
            return shown.contains(item.id) ? nil : item
        }
    }
}
