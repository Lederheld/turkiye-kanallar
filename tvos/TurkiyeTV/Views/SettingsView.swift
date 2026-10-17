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
                    Picker("Açılışta", selection: $store.startupBehavior) {
                        ForEach(StartupBehavior.allCases) { behavior in
                            Text(behavior.title).tag(behavior)
                        }
                    }
                }

                Section {
                    Toggle("Kanalları izleme süreme göre sırala", isOn: $store.sortsByWatchTime)
                    Button("İzleme geçmişini sıfırla", role: .destructive) { store.clearWatchHistory() }
                        .disabled(store.recentNames.isEmpty && store.watchHistory.isEmpty)
                } header: {
                    Text("Kişiselleştirme")
                } footer: {
                    Text("En çok izlediğin kategoriler ve kanallar öne gelir; son iki haftanın izlemesi daha ağır basar. Kanal numaraları değişmez.")
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
                    Text("Liste açılışta ve uygulama açık kaldıkça 10 dakikada bir kendiliğinden yenilenir; yeni kanallar ve linkler elle güncellemeden gelir.")
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
