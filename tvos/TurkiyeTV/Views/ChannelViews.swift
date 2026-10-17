import SwiftUI

struct ChannelLogo: View {
    let channel: Channel

    var body: some View {
        ZStack {
            Color(white: 0.9)
            if let logoURL = channel.logoURL {
                AsyncImage(url: logoURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(20)
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
            .foregroundStyle(Color(white: 0.35))
    }
}

struct ChannelCard: View {
    @EnvironmentObject private var store: PlaylistStore
    let channel: Channel
    let onSelect: (Channel) -> Void

    var body: some View {
        let isFavorite = store.isFavorite(channel)
        Button { onSelect(channel) } label: {
            VStack(spacing: 0) {
                ChannelLogo(channel: channel)
                    .frame(height: 160)
                HStack(spacing: 8) {
                    Text(channel.name)
                        .font(.callout)
                        .lineLimit(1)
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .buttonStyle(.card)
        .contextMenu {
            Button { store.toggleFavorite(channel) } label: {
                Label(isFavorite ? "Favorilerden çıkar" : "Favorilere ekle",
                      systemImage: isFavorite ? "star.slash" : "star")
            }
        }
    }
}

struct ChannelSection: View {
    let title: String
    let channels: [Channel]
    let onSelect: (Channel) -> Void

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 360), spacing: 48)]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title)
                .font(.title3.bold())
            LazyVGrid(columns: columns, spacing: 56) {
                ForEach(channels) { channel in
                    ChannelCard(channel: channel, onSelect: onSelect)
                }
            }
        }
    }
}
