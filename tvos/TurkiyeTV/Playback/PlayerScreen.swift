import AVKit
import SwiftUI

/// Tam ekran oynatıcı.
/// - Kanal değişince sol üstte birkaç saniye kanal bilgisi görünür.
/// - Kanal +/- tuşları (CEC/IR kumandalar) ve oynatma çubuğu gizliyken yukarı/aşağı tıklama kanal değiştirir.
/// - Oynatma çubuğunda önceki/sonraki/son kanal ve favori düğmeleri var.
/// - Aşağı kaydırınca açılan panelde "Kanallar" sekmesi var.
struct PlayerScreen: View {
    @ObservedObject var store: PlaylistStore
    @StateObject private var playback: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @State private var showsBanner = false
    @State private var bannerTask: Task<Void, Never>?

    init(channel: Channel, store: PlaylistStore) {
        self.store = store
        _playback = StateObject(wrappedValue: PlaybackController(channel: channel, store: store))
    }

    var body: some View {
        PlayerViewControllerRepresentable(playback: playback, store: store,
                                          isFavorite: store.isFavorite(playback.channel),
                                          canRecall: playback.previousChannel != nil)
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                if showsBanner && playback.errorMessage == nil {
                    ChannelBanner(channel: playback.channel, number: store.number(of: playback.channel))
                        .padding(.leading, 80)
                        .padding(.top, 60)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if let message = playback.errorMessage {
                    errorOverlay(message)
                }
            }
            .onAppear {
                playback.retry()
                showBanner()
            }
            .onDisappear {
                bannerTask?.cancel()
                playback.stop()
            }
            .onChange(of: playback.channel.name) { _, _ in showBanner() }
    }

    private func showBanner() {
        bannerTask?.cancel()
        withAnimation(.smooth) { showsBanner = true }
        bannerTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { showsBanner = false }
        }
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
                Button("Sonraki kanal") { playback.zap(by: 1) }
                Button("Kanallara dön") { dismiss() }
            }
        }
        .padding(60)
        .glassSurface()
    }
}

private struct ChannelBanner: View {
    let channel: Channel
    let number: Int?

    var body: some View {
        HStack(spacing: 28) {
            ChannelLogo(channel: channel, padding: 18)
                .frame(width: 192, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    LiveBadge()
                    if let number {
                        Text("\(number)")
                            .font(.title3.weight(.bold).monospacedDigit())
                    }
                }
                Text(channel.name)
                    .font(.title2.weight(.bold))
                Text(channel.category.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .padding(.trailing, 24)
        .glassSurface(cornerRadius: 32)
    }
}

private struct PlayerViewControllerRepresentable: UIViewControllerRepresentable {
    let playback: PlaybackController
    let store: PlaylistStore
    let isFavorite: Bool
    let canRecall: Bool

    private static let channelPanelHeight: CGFloat = 340

    func makeCoordinator() -> Coordinator {
        Coordinator(playback: playback)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = playback.player

        let channelPanel = UIHostingController(rootView: ChannelStripView(store: store, playback: playback))
        channelPanel.title = "Kanallar"
        channelPanel.preferredContentSize = CGSize(width: 0, height: Self.channelPanelHeight)
        controller.customInfoViewControllers = [channelPanel]

        controller.delegate = context.coordinator
        context.coordinator.installZapGestures(on: controller.view)
        updateTransportBar(controller)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        updateTransportBar(controller)
    }

    private func updateTransportBar(_ controller: AVPlayerViewController) {
        let playback = playback
        let store = store
        var items: [UIMenuElement] = [
            UIAction(title: "Önceki kanal", image: UIImage(systemName: "chevron.down")) { _ in
                Task { @MainActor in playback.zap(by: -1) }
            },
            UIAction(title: "Sonraki kanal", image: UIImage(systemName: "chevron.up")) { _ in
                Task { @MainActor in playback.zap(by: 1) }
            },
        ]
        if canRecall {
            items.append(UIAction(title: "Son kanal", image: UIImage(systemName: "arrow.uturn.backward")) { _ in
                Task { @MainActor in playback.recall() }
            })
        }
        items.append(UIAction(title: isFavorite ? "Favorilerden çıkar" : "Favorilere ekle",
                              image: UIImage(systemName: isFavorite ? "star.fill" : "star")) { _ in
            Task { @MainActor in store.toggleFavorite(playback.channel) }
        })
        controller.transportBarCustomMenuItems = items
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate, AVPlayerViewControllerDelegate {
        let playback: PlaybackController
        /// Oynatma çubuğu açıkken ok tuşları menüde gezinmek içindir, kanal değiştirmez.
        private var isTransportBarVisible = false

        init(playback: PlaybackController) {
            self.playback = playback
        }

        func installZapGestures(on view: UIView) {
            let presses: [(UIPress.PressType, Int)] = [(.pageUp, 1), (.pageDown, -1), (.upArrow, 1), (.downArrow, -1)]
            for (type, offset) in presses {
                let recognizer = UITapGestureRecognizer(target: self,
                                                        action: offset > 0 ? #selector(zapUp(_:)) : #selector(zapDown(_:)))
                recognizer.allowedPressTypes = [NSNumber(value: type.rawValue)]
                recognizer.delegate = self
                view.addGestureRecognizer(recognizer)
            }
        }

        @objc private func zapUp(_ recognizer: UITapGestureRecognizer) { zap(1, recognizer) }
        @objc private func zapDown(_ recognizer: UITapGestureRecognizer) { zap(-1, recognizer) }

        private func zap(_ offset: Int, _ recognizer: UITapGestureRecognizer) {
            let isChannelKey = recognizer.allowedPressTypes.contains {
                [UIPress.PressType.pageUp.rawValue, UIPress.PressType.pageDown.rawValue].contains($0.intValue)
            }
            guard isChannelKey || !isTransportBarVisible else { return }
            playback.zap(by: offset)
        }

        nonisolated func playerViewController(_ playerViewController: AVPlayerViewController,
                                              willTransitionToVisibilityOfTransportBar visible: Bool,
                                              with coordinator: AVPlayerViewControllerAnimationCoordinator) {
            MainActor.assumeIsolated { isTransportBarVisible = visible }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
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
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 40) {
                    ForEach(orderedChannels) { channel in
                        Button { playback.play(channel) } label: {
                            ChannelLogo(channel: channel, padding: 20)
                                .frame(width: 256, height: 144)
                                .overlay(alignment: .topLeading) {
                                    if let number = store.number(of: channel) {
                                        NumberBadge(number: number).padding(10)
                                    }
                                }
                                .overlay(alignment: .bottom) {
                                    if channel.name == playback.channel.name {
                                        Capsule()
                                            .fill(Theme.accent)
                                            .frame(height: 6)
                                            .padding(.horizontal, 20)
                                            .padding(.bottom, 10)
                                    }
                                }
                        }
                        .buttonStyle(.card)
                        .id(channel.name)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 40)
            }
            .scrollClipDisabled()
            .onAppear { proxy.scrollTo(playback.channel.name, anchor: .center) }
        }
    }
}
