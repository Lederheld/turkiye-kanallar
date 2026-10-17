import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: PlaylistStore
    @State private var draftURL = ""

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            VStack(spacing: 28) {
                Image(systemName: "tv")
                    .font(.system(size: 120, weight: .light))
                    .foregroundStyle(Theme.accentGradient)
                Text("\(store.channels.count) kanal")
                    .font(.title2.weight(.semibold))
                Text(updatedText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 480)
            .padding(.vertical, 60)
            .glassSurface()

            Form {
                Section("Oynatma") {
                    Toggle("Açılışta son kanalı oynat", isOn: $store.resumesLastChannel)
                    Button("Son izlenenleri temizle", role: .destructive) { store.clearRecents() }
                        .disabled(store.recentNames.isEmpty)
                }

                Section {
                    Button {
                        Task { await store.reload() }
                    } label: {
                        HStack {
                            Text("Listeyi şimdi yenile")
                            Spacer()
                            if store.isLoading { ProgressView() }
                        }
                    }
                    if let error = store.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                } header: {
                    Text("Kanal listesi")
                } footer: {
                    Text("Liste uygulama açıldığında ve 10 dakikadan eskiyse kendiliğinden yenilenir.")
                }

                Section {
                    TextField("https://gist.githubusercontent.com/…/raw/turkiye-kanallar.m3u", text: $draftURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Kaydet ve yenile") {
                        Task { await store.setCustomPlaylistURL(draftURL) }
                    }
                    if !PlaylistStore.bundledPlaylistURL.isEmpty && !store.customPlaylistURL.isEmpty {
                        Button("Derlemedeki adrese dön") {
                            draftURL = ""
                            Task { await store.setCustomPlaylistURL("") }
                        }
                    }
                } header: {
                    Text("Playlist adresi")
                } footer: {
                    Text(PlaylistStore.bundledPlaylistURL.isEmpty
                         ? "Gist'in raw adresini girin. iPhone'daki klavyeyle de yazabilirsiniz."
                         : "Boş bırakılırsa derleme sırasında verilen adres kullanılır.")
                }
            }
        }
        .padding(.top, 40)
        .onAppear { draftURL = store.customPlaylistURL }
    }

    private var updatedText: String {
        guard let date = store.lastUpdated else { return "Henüz güncellenmedi" }
        return "Son güncelleme\n" + date.formatted(date: .abbreviated, time: .shortened)
    }
}
