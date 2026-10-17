import AVKit
import SwiftUI

/// Tam ekran oynatıcı. Kumandada aşağı kaydırınca açılan panelde "Kanallar" sekmesi var.
struct PlayerScreen: View {
    @ObservedObject var store: PlaylistStore
    @StateObject private var playback: PlaybackController
    @Environment(\.dismiss) private var dismiss

    init(channel: Channel, store: PlaylistStore) {
        self.store = store
        _playback = StateObject(wrappedValue: PlaybackController(channel: channel, store: store))
    }

    var body: some View {
        PlayerViewControllerRepresentable(playback: playback, store: store)
            .ignoresSafeArea()
            .overlay {
                if let message = playback.errorMessage {
                    errorOverlay(message)
                }
            }
            .onAppear { playback.retry() }
            .onDisappear { playback.stop() }
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 32) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.yellow)
            Text(message)
                .font(.title3)
                .multilineTextAlignment(.center)
            HStack(spacing: 40) {
                Button("Tekrar dene") { playback.retry() }
                Button("Kanallara dön") { dismiss() }
            }
        }
        .padding(60)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32))
    }
}

private struct PlayerViewControllerRepresentable: UIViewControllerRepresentable {
    let playback: PlaybackController
    let store: PlaylistStore

    private static let channelPanelHeight: CGFloat = 320

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = playback.player

        let channelPanel = UIHostingController(rootView: ChannelStripView(store: store, playback: playback))
        channelPanel.title = "Kanallar"
        channelPanel.preferredContentSize = CGSize(width: 0, height: Self.channelPanelHeight)
        controller.customInfoViewControllers = [channelPanel]
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}

/// Oynatıcı içindeki kanal şeridi: önce favoriler, sonra diğerleri.
private struct ChannelStripView: View {
    @ObservedObject var store: PlaylistStore
    @ObservedObject var playback: PlaybackController

    private var orderedChannels: [Channel] {
        let favorites = store.favoriteChannels
        let favoriteNames = Set(favorites.map(\.name))
        return favorites + store.channels.filter { !favoriteNames.contains($0.name) }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 40) {
                ForEach(orderedChannels) { channel in
                    Button { playback.play(channel) } label: {
                        VStack(spacing: 0) {
                            ChannelLogo(channel: channel)
                                .frame(width: 240, height: 120)
                            Text(channel.name)
                                .font(.caption)
                                .lineLimit(1)
                                .padding(10)
                        }
                        .frame(width: 240)
                    }
                    .buttonStyle(.card)
                    .overlay(alignment: .topTrailing) {
                        if channel.name == playback.channel.name {
                            Image(systemName: "play.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.white, .red)
                                .padding(8)
                        }
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 30)
        }
        .scrollClipDisabled()
    }
}
