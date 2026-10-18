import SwiftUI

/// Program kartı: yayındaysa tıklayınca kanal açılır, değilse hatırlatıcı kurulur/kaldırılır.
struct ProgramCard: View {
    @EnvironmentObject private var reminders: ReminderStore
    @Environment(\.playChannel) private var playChannel
    let item: ScheduledProgram
    private let width = Theme.cardSize.width

    var body: some View {
        TimelineView(.everyMinute) { context in
            let isLive = item.program.contains(context.date)
            let isSet = reminders.isSet(item.channel, item.program)
            VStack(alignment: .leading, spacing: 18) {
                Button {
                    if isLive {
                        playChannel(item.channel)
                    } else {
                        reminders.toggle(item.channel, item.program)
                    }
                } label: {
                    ChannelLogo(channel: item.channel)
                        .frame(width: width, height: width * 9 / 16)
                        .overlay(alignment: .bottomLeading) {
                            if isLive {
                                LiveBadge().padding(12)
                            } else {
                                Text(ProgramText.clock(item.program.start))
                                    .font(.callout.weight(.bold).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(.black.opacity(0.65), in: Capsule())
                                    .padding(12)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if isSet {
                                Image(systemName: "bell.fill")
                                    .font(.callout)
                                    .foregroundStyle(.white)
                                    .padding(10)
                                    .background(Theme.accent, in: Circle())
                                    .padding(10)
                            }
                        }
                }
                .buttonStyle(.card)
                .contextMenu {
                    if !isLive {
                        Button { reminders.toggle(item.channel, item.program) } label: {
                            Label(isSet ? "Hatırlatmayı kaldır" : "Hatırlat",
                                  systemImage: isSet ? "bell.slash" : "bell")
                        }
                    }
                    Button { playChannel(item.channel) } label: {
                        Label("\(item.channel.name) kanalını aç", systemImage: "play.fill")
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.program.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(caption(isLive: isLive))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: width, alignment: .leading)
            }
        }
    }

    private func caption(isLive: Bool) -> String {
        let day = isLive || Calendar.current.isDateInToday(item.program.start) ? "" : "Yarın "
        return "\(day)\(item.channel.name) · \(ProgramText.timeRange(item.program))"
    }
}

struct ProgramShelf: View {
    let title: String
    let symbol: String
    let items: [ScheduledProgram]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 48) {
                    ForEach(items) { item in
                        ProgramCard(item: item)
                    }
                }
                .padding(.vertical, 36)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

/// Oynatıcıda, hatırlatılan program başka kanalda başlarken sağ altta çıkan kart.
/// "Geç" ve "Kalsın" düğmeleri AVKit'in ekran düğmeleri olarak (contextualActions) gösterilir.
struct ReminderPrompt: View {
    let reminder: Reminder
    let channel: Channel

    var body: some View {
        HStack(spacing: 24) {
            ChannelLogo(channel: channel, padding: 14)
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    Label(reminder.start > context.date ? "Birazdan başlıyor" : "Başladı", systemImage: "bell.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
                Text(reminder.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(channel.name) · \(ProgramText.clock(reminder.start))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
        .padding(28)
        .glassSurface(cornerRadius: 28)
    }
}
