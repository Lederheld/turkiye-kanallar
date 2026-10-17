import SwiftUI

/// Tüm kanallar, kategori başlıklarıyla ızgarada.
struct BrowseView: View {
    @EnvironmentObject private var store: PlaylistStore

    var body: some View {
        ScrollView {
            if store.channels.isEmpty {
                EmptyPlaylistView()
            } else {
                LazyVStack(alignment: .leading, spacing: 64) {
                    ForEach(store.categorySections, id: \.category) { section in
                        VStack(alignment: .leading, spacing: 32) {
                            HStack(spacing: 14) {
                                Label(section.category.title, systemImage: section.category.symbol)
                                    .font(.title3.weight(.semibold))
                                Text("\(section.channels.count)")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ChannelGrid(channels: section.channels)
                        }
                        .focusSection()
                    }
                }
                .padding(.vertical, 40)
            }
        }
    }
}

/// Ada ya da kanal numarasına göre arama.
struct SearchView: View {
    @EnvironmentObject private var store: PlaylistStore
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                let results = store.search(query)
                Group {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        ContentUnavailableView("Kanal ara", systemImage: "magnifyingglass",
                                               description: Text("Kanal adını ya da numarasını yazın."))
                    } else if results.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        ChannelGrid(channels: results)
                            .padding(.vertical, 40)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 400)
            }
            .searchable(text: $query, prompt: "Kanal adı ya da numarası")
        }
    }
}
