import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: PlaylistStore

    /// Öne çıkan: son izlenen, yoksa ilk favori, yoksa listenin ilk kanalı.
    private var featured: Channel? {
        store.lastChannel ?? store.favoriteChannels.first ?? store.channels.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if let featured {
                    HeroView(channel: featured, isResume: store.lastChannel != nil)
                        .focusSection()
                    if store.sortsByWatchTime && !store.frequentChannels.isEmpty {
                        ChannelShelf(title: "En Çok İzlediklerin", symbol: "chart.bar.fill",
                                     channels: store.frequentChannels)
                    }
                    if !store.favoriteChannels.isEmpty {
                        ChannelShelf(title: "Favoriler", symbol: "star.fill", channels: store.favoriteChannels)
                    }
                    if store.recentChannels.count > 1 {
                        ChannelShelf(title: "Son İzlenenler", symbol: "clock.arrow.circlepath",
                                     channels: store.recentChannels)
                    }
                    ForEach(store.categorySections, id: \.category) { section in
                        ChannelShelf(title: section.category.title, symbol: section.category.symbol,
                                     channels: section.channels)
                    }
                } else {
                    EmptyPlaylistView()
                }
            }
            .padding(.bottom, 80)
        }
    }
}

/// Üstteki büyük kart: tek tuşla izlemeye başlama.
private struct HeroView: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var guide: ProgramGuide
    @Environment(\.playChannel) private var playChannel
    let channel: Channel
    let isResume: Bool

    var body: some View {
        let isFavorite = store.isFavorite(channel)
        HStack(alignment: .center, spacing: 64) {
            ChannelLogo(channel: channel, padding: 48)
                .frame(width: 560, height: 315)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: Theme.accent.opacity(0.35), radius: 40, y: 16)

            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    LiveBadge()
                    Text(subtitle)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(channel.name)
                    .font(.system(size: 76, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(nowPlaying ?? (isResume ? "Kaldığın kanaldan devam et" : "Canlı yayını hemen izle"))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                HStack(spacing: 28) {
                    Button { playChannel(channel) } label: {
                        Label("İzle", systemImage: "play.fill")
                            .padding(.horizontal, 24)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    Button { store.toggleFavorite(channel) } label: {
                        Label(isFavorite ? "Favorilerde" : "Favorilere ekle",
                              systemImage: isFavorite ? "star.fill" : "star")
                    }
                }
                .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .padding(48)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.accentGradient.opacity(0.18))
        }
        .glassSurface()
        .overlay(alignment: .topTrailing) {
            ClockView().padding(36)
        }
    }

    private var nowPlaying: String? {
        guard let program = guide.program(for: channel) else { return nil }
        return "Şimdi: \(program.title) · \(ProgramText.timeRange(program))"
    }

    private var subtitle: String {
        let number = store.number(of: channel).map { "\($0) · " } ?? ""
        return number + channel.category.title
    }
}

private struct ClockView: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(context.date, format: .dateTime.hour().minute())
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
