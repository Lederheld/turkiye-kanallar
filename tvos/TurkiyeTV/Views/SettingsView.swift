import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    @State private var draftURL = ""

    var body: some View {
        Form {
            Section {
                TextField("https://gist.githubusercontent.com/…/raw/turkiye-kanallar.m3u", text: $draftURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Kaydet ve yenile") {
                    Task {
                        await store.setCustomPlaylistURL(draftURL)
                        if store.lastError == nil { dismiss() }
                    }
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

            Section("Durum") {
                LabeledContent("Kanal sayısı", value: "\(store.channels.count)")
                LabeledContent("Son güncelleme", value: store.lastUpdated?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                if let error = store.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear { draftURL = store.customPlaylistURL }
    }
}
