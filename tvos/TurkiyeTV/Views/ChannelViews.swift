import SwiftUI

struct ChannelLogo: View {
    let channel: Channel
    var padding: CGFloat = 26

    var body: some View {
        ZStack {
            LinearGradient(colors: [.white, Color(white: 0.9)], startPoint: .top, endPoint: .bottom)
            if let logoURL = channel.logoURL {
                AsyncImage(url: logoURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(padding)
                    } else {
                        initials
                    }
                }
            } else {
                initials
            }
        }
    }

    private var initials: some View {
        Text(channel.initials)
            .font(.title2.bold())
            .foregroundStyle(Color(white: 0.4))
    }
}

/// Logo kartı; altında ad ve kategori. Uzun basışla favorilere eklenir.
struct ChannelCard: View {
    @EnvironmentObject private var store: PlaylistStore
    @Environment(\.playChannel) private var playChannel
    let channel: Channel
    var width: CGFloat = Theme.cardSize.width

    var body: some View {
        let isFavorite = store.isFavorite(channel)
        VStack(alignment: .leading, spacing: 18) {
            Button { playChannel(channel) } label: {
                ChannelLogo(channel: channel)
                    .frame(width: width, height: width * 9 / 16)
                    .overlay(alignment: .topLeading) {
                        if let number = store.number(of: channel) {
                            NumberBadge(number: number).padding(12)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.callout)
                                .foregroundStyle(.yellow)
                                .padding(10)
                                .background(.black.opacity(0.55), in: Circle())
                                .padding(10)
                        }
                    }
            }
            .buttonStyle(.card)
            .contextMenu {
                Button { store.toggleFavorite(channel) } label: {
                    Label(isFavorite ? "Favorilerden çıkar" : "Favorilere ekle",
                          systemImage: isFavorite ? "star.slash" : "star")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(channel.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(channel.category.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: width, alignment: .leading)
        }
    }
}

/// Yatay kayan kanal şeridi (Apple TV uygulamasındaki raflar gibi).
struct ChannelShelf: View {
    let title: String
    let symbol: String
    let channels: [Channel]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 48) {
                    ForEach(channels) { channel in
                        ChannelCard(channel: channel)
                    }
                }
                .padding(.vertical, 36)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

/// Izgarada kanal listesi (Kanallar ve Ara sekmeleri).
struct ChannelGrid: View {
    let channels: [Channel]

    private static let cardWidth: CGFloat = 300
    private let columns = [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth), spacing: 44, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
            ForEach(channels) { channel in
                ChannelCard(channel: channel, width: Self.cardWidth)
            }
        }
    }
}
