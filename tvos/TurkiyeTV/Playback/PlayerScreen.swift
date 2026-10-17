import AVKit
import SwiftUI

/// Tam ekran oynatıcı.
/// - Kanal değişince sol üstte birkaç saniye kanal bilgisi görünür.
/// - Kumandada sol/sağ basılı tutunca hızlanarak sarar (5, 10, 20, 30, 45 dk, 1 sa…); bırakınca oraya gider.
/// - Çubuk gizliyken dokunmatik yüzeyde sola/sağa kaydırınca sarar (Netflix/YouTube gibi): uzun kaydırma daha
///   uzağa gider, art arda kaydırmalar toplanır, durunca hedefe atlar. Çubuk açıkken AVKit'in kendi zaman
///   çubuğu sarması çalışır.
/// - Yayın akışı varsa banner, sarma göstergesi ve Zaman Tüneli program adlarını gösterir; "Baştan izle"
///   o an izlenen programın başına gider.
/// - Çubuktaki "Zaman Tüneli" menüsü: program başlangıçları (akış yoksa yarım saatler); tek tıkla o ana gidilir.
/// - Kanal +/- tuşları (CEC/IR kumandalar) kanal değiştirir. Ok tuşları AVKit'te kalır (aşağı: Kanallar paneli).
/// - Oynatma çubuğunda önceki/sonraki/son kanal ve favori düğmeleri var.
/// - Aşağı kaydırınca açılan panelde yalnızca "Kanallar" var: tek sekme olunca odak doğrudan kanallara iner.
/// - Yayın sunucuda geri sarılabilir süre tutuyorsa çubukta 10 dk geri/ileri ve "Canlıya dön" düğmeleri çıkar.
///   Canlıdayken de görünürler: düğmeler kaybolup gelirse odak başka düğmeye (ör. sonraki kanal) kayar.
struct PlayerScreen: View {
    @ObservedObject var store: PlaylistStore
    @ObservedObject var guide: ProgramGuide
    @StateObject private var playback: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @State private var showsBanner = false
    @State private var bannerTask: Task<Void, Never>?

    init(channel: Channel, store: PlaylistStore, guide: ProgramGuide) {
        self.store = store
        self.guide = guide
        _playback = StateObject(wrappedValue: PlaybackController(channel: channel, store: store))
    }

    var body: some View {
        PlayerViewControllerRepresentable(playback: playback, store: store, guide: guide,
                                          state: TransportState(isFavorite: store.isFavorite(playback.channel),
                                                                canRecall: playback.previousChannel != nil,
                                                                canRewind: playback.canRewind,
                                                                hasGuide: !guide.programs(for: playback.channel).isEmpty,
                                                                timeline: timelineStops))
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                if showsBanner && playback.errorMessage == nil {
                    ChannelBanner(channel: playback.channel, number: store.number(of: playback.channel),
                                  program: guide.program(for: playback.channel, at: watchedDate),
                                  rewindWindow: playback.canRewind ? playback.rewindWindow : nil)
                        .padding(.leading, 80)
                        .padding(.top, 60)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if playback.isBehindLive && playback.errorMessage == nil {
                    BehindLiveBadge(seconds: playback.behindLive)
                        .padding(.trailing, 80)
                        .padding(.top, 60)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if let offset = playback.scrubOffset {
                    ScrubTimeline(offset: offset, behindLive: playback.behindLive, window: playback.rewindWindow,
                                  programs: guide.programs(for: playback.channel))
                        .padding(.horizontal, 80)
                        .padding(.bottom, 70)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.smooth(duration: 0.2), value: playback.scrubOffset)
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

    /// Zaman Tüneli durakları, yeniden eskiye: penceredeki program başlangıçları; akış yoksa yarım saatler.
    /// Değerler yalnızca yeni program ya da yarım saat girdiğinde değişir, menü de o zaman yeniden kurulur.
    private var timelineStops: [TimelineStop] {
        guard playback.canRewind else { return [] }
        let now = Date()
        let windowStart = now.addingTimeInterval(-playback.rewindWindow)
        let programs = guide.programs(for: playback.channel).filter { $0.start >= windowStart && $0.start < now }
        if !programs.isEmpty {
            return programs.reversed().map { TimelineStop(date: $0.start, title: $0.title) }
        }
        let step: TimeInterval = 30 * 60
        var date = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / step).rounded(.down) * step)
        var stops: [TimelineStop] = []
        while date >= windowStart {
            stops.append(TimelineStop(date: date, title: nil))
            date -= step
        }
        return stops
    }

    /// Ekrandaki görüntünün yayınlandığı an (geri sarıldıysa geçmişte).
    private var watchedDate: Date {
        Date().addingTimeInterval(-playback.behindLive)
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
    let program: TVProgram?
    let rewindWindow: TimeInterval?

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
                if let program {
                    Text("\(program.title) · \(ProgramText.timeRange(program))")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    Text(channel.category.title)
                    if let rewindWindow {
                        Text("·")
                        Label("\(DurationText.short(rewindWindow)) geri sarılabilir", systemImage: "gobackward")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .padding(.trailing, 24)
        .glassSurface(cornerRadius: 32)
    }
}

/// Sararken altta, oynatıcının zaman çubuğunun yerinde çıkan zaman çizelgesi (YouTube/Netflix gibi):
/// sol ucu sunucunun tuttuğu en eski an, sağ ucu canlı. Beyaz çizgi izlenen yer, kırmızı tutamaç
/// bırakınca gidilecek yer; üstünde saat ve o saatteki program. Program başlangıçları küçük çentikler.
private struct ScrubTimeline: View {
    let offset: TimeInterval
    let behindLive: TimeInterval
    let window: TimeInterval
    let programs: [TVProgram]

    private static let bubbleWidth: CGFloat = 420

    private var targetBehind: TimeInterval { min(window, max(0, behindLive - offset)) }

    var body: some View {
        let now = Date()
        let target = now.addingTimeInterval(-targetBehind)
        let program = programs.last { $0.contains(target) }
        GeometryReader { geometry in
            let width = geometry.size.width
            let position = { (behind: TimeInterval) in width * (1 - behind / max(window, 1)) }
            let targetX = position(targetBehind)
            ZStack(alignment: .bottomLeading) {
                // hedef balonu: tutamacın üstünde, kenarlarda ekrandan taşmaz
                TargetBubble(target: target, offset: offset, isLive: targetBehind < 30, program: program)
                    .frame(width: Self.bubbleWidth, alignment: .leading)
                    .offset(x: min(max(targetX - Self.bubbleWidth / 2, 0), max(0, width - Self.bubbleWidth)), y: -44)

                // çizelge
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(.white.opacity(0.55))
                        .frame(width: position(behindLive))
                    ForEach(programs.filter { now.timeIntervalSince($0.start) < window && $0.start < now }, id: \.start) { program in
                        Rectangle()
                            .fill(.black.opacity(0.6))
                            .frame(width: 3, height: 14)
                            .offset(x: position(now.timeIntervalSince(program.start)) - 1.5)
                    }
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 30, height: 30)
                        .shadow(color: .black.opacity(0.4), radius: 6)
                        .offset(x: targetX - 15)
                }
                .frame(height: 14)
            }
            .frame(width: width, height: geometry.size.height, alignment: .bottomLeading)
        }
        .frame(height: 170)
        .animation(.interactiveSpring(duration: 0.25), value: offset)
    }

    private struct TargetBubble: View {
        let target: Date
        let offset: TimeInterval
        let isLive: Bool
        let program: TVProgram?

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(isLive ? "Canlı" : ProgramText.clock(target))
                        .font(.title2.weight(.bold).monospacedDigit())
                    Text((offset < 0 ? "−" : "+") + DurationText.short(abs(offset)))
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let program {
                    Text(program.title)
                        .font(.callout)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: 24)
        }
    }
}

/// Canlının gerisindeyken sağ üstte kalan rozet. Birkaç saniye sonra küçük, nefes alan bir
/// baloncuğa dönüşür; yeni bir sarmada yeniden açılır.
private struct BehindLiveBadge: View {
    let seconds: TimeInterval
    @State private var isExpanded = true
    @State private var collapseTask: Task<Void, Never>?

    private static let visibleDuration: Duration = .seconds(4)
    /// Oynarken fark birkaç saniye oynar, duraklatınca saniyede bir artar; bundan büyüğü bir sarmadır.
    private static let jumpThreshold: TimeInterval = 10

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 30, weight: .semibold))
                .symbolEffect(.pulse, options: .repeating, isActive: !isExpanded)
            if isExpanded {
                Text("Canlının \(DurationText.clock(seconds)) gerisinde")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .fixedSize()
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(.horizontal, isExpanded ? 24 : 18)
        .padding(.vertical, isExpanded ? 14 : 18)
        .glassSurface(cornerRadius: 40)
        .onAppear { expand() }
        .onDisappear { collapseTask?.cancel() }
        .onChange(of: seconds) { old, new in
            if abs(new - old) > Self.jumpThreshold { expand() }
        }
    }

    private func expand() {
        withAnimation(.spring(duration: 0.45, bounce: 0.25)) { isExpanded = true }
        collapseTask?.cancel()
        collapseTask = Task {
            try? await Task.sleep(for: Self.visibleDuration)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.55, bounce: 0.2)) { isExpanded = false }
        }
    }
}

enum ProgramText {
    /// 20:00 – 00:20
    static func timeRange(_ program: TVProgram) -> String {
        "\(clock(program.start)) – \(clock(program.end))"
    }

    /// 24 saat, iki haneli: 00:20
    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
}

enum DurationText {
    /// 11 sa 34 dk / 45 dk
    static func short(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        if hours == 0 { return "\(minutes) dk" }
        return minutes % 60 == 0 ? "\(hours) sa" : "\(hours) sa \(minutes % 60) dk"
    }

    /// 1:02:05 / 12:34
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let (h, m, sec) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// Oynatma çubuğundaki düğmeleri belirleyen durum; değişmedikçe düğmeler yeniden kurulmaz.
struct TransportState: Equatable {
    var isFavorite: Bool
    var canRecall: Bool
    var canRewind: Bool
    var hasGuide: Bool
    var timeline: [TimelineStop]
}

struct TimelineStop: Equatable {
    let date: Date
    let title: String?
}

private struct PlayerViewControllerRepresentable: UIViewControllerRepresentable {
    let playback: PlaybackController
    let store: PlaylistStore
    let guide: ProgramGuide
    let state: TransportState

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

        // Tek sekme: aşağı kaydırınca odak sekme başlığına değil, doğrudan kanallara iner
        controller.customInfoViewControllers = [channelPanel]

        context.coordinator.installZapGestures(on: controller.view)
        context.coordinator.installScrubGestures(on: controller.view)
        controller.delegate = context.coordinator
        updateTransportBar(controller, coordinator: context.coordinator)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        updateTransportBar(controller, coordinator: context.coordinator)
    }

    private func updateTransportBar(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        // Her saniye yeniden kurmak çubuktaki odağı kaçırır
        guard coordinator.transportState != state else { return }
        coordinator.transportState = state
        let playback = playback
        let store = store
        var items: [UIMenuElement] = []
        if !state.timeline.isEmpty {
            items.append(timelineMenu(state.timeline))
        }
        if state.canRewind && state.hasGuide {
            let guide = guide
            items.append(UIAction(title: "Baştan izle", image: UIImage(systemName: "backward.end.fill")) { _ in
                Task { @MainActor in
                    let watched = Date().addingTimeInterval(-playback.behindLive)
                    if let program = guide.program(for: playback.channel, at: watched) {
                        playback.seek(secondsBehindLive: Date().timeIntervalSince(program.start))
                    }
                }
            })
        }
        if state.canRewind {
            items.append(UIAction(title: "10 dk geri", image: UIImage(systemName: "gobackward.10")) { _ in
                Task { @MainActor in playback.skip(by: -600) }
            })
            items.append(UIAction(title: "10 dk ileri", image: UIImage(systemName: "goforward.10")) { _ in
                Task { @MainActor in playback.skip(by: 600) }
            })
            items.append(UIAction(title: "Canlıya dön", image: UIImage(systemName: "dot.radiowaves.left.and.right")) { _ in
                Task { @MainActor in playback.goLive() }
            })
        }
        items += [
            UIAction(title: "Önceki kanal", image: UIImage(systemName: "chevron.down")) { _ in
                Task { @MainActor in playback.zap(by: -1) }
            },
            UIAction(title: "Sonraki kanal", image: UIImage(systemName: "chevron.up")) { _ in
                Task { @MainActor in playback.zap(by: 1) }
            },
        ]
        if state.canRecall {
            items.append(UIAction(title: "Son kanal", image: UIImage(systemName: "arrow.uturn.backward")) { _ in
                Task { @MainActor in playback.recall() }
            })
        }
        items.append(UIAction(title: state.isFavorite ? "Favorilerden çıkar" : "Favorilere ekle",
                              image: UIImage(systemName: state.isFavorite ? "star.fill" : "star")) { _ in
            Task { @MainActor in store.toggleFavorite(playback.channel) }
        })
        controller.transportBarCustomMenuItems = items
    }

    private func timelineMenu(_ stops: [TimelineStop]) -> UIMenu {
        let playback = playback
        let calendar = Calendar.current
        let live = UIAction(title: "Canlı", image: UIImage(systemName: "dot.radiowaves.left.and.right")) { _ in
            Task { @MainActor in playback.goLive() }
        }
        let actions = stops.map { stop in
            let clock = ProgramText.clock(stop.date)
            let action = UIAction(title: stop.title.map { "\(clock)  \($0)" } ?? clock) { _ in
                Task { @MainActor in playback.seek(secondsBehindLive: Date().timeIntervalSince(stop.date)) }
            }
            if !calendar.isDateInToday(stop.date) {
                action.subtitle = "Dün"
            }
            return action
        }
        return UIMenu(title: "Zaman Tüneli", image: UIImage(systemName: "clock.arrow.circlepath"),
                      children: [live] + actions)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate, AVPlayerViewControllerDelegate {
        let playback: PlaybackController
        var transportState: TransportState?
        /// Çubuk açıkken kaydırma AVKit'indir (düğmeler arasında gezinme, zaman çubuğunda sarma).
        private var isTransportBarVisible = false
        private var swipeRecognizer: UIPanGestureRecognizer?
        private static let arrowPressTypes: Set<Int> = [UIPress.PressType.leftArrow.rawValue,
                                                         UIPress.PressType.rightArrow.rawValue]

        init(playback: PlaybackController) {
            self.playback = playback
        }

        func installScrubGestures(on view: UIView) {
            for (type, direction) in [(UIPress.PressType.leftArrow, -1), (.rightArrow, 1)] {
                let recognizer = UILongPressGestureRecognizer(target: self,
                                                              action: direction < 0 ? #selector(scrubBack) : #selector(scrubForward))
                recognizer.allowedPressTypes = [NSNumber(value: type.rawValue)]
                recognizer.minimumPressDuration = 0.4
                recognizer.delegate = self
                view.addGestureRecognizer(recognizer)
            }
            let swipe = UIPanGestureRecognizer(target: self, action: #selector(swipeScrub))
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            swipe.delegate = self
            view.addGestureRecognizer(swipe)
            swipeRecognizer = swipe
        }

        @objc private func swipeScrub(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                playback.beginSwipeScrub()
            case .changed:
                playback.updateSwipeScrub(fraction: recognizer.translation(in: view).x / max(view.bounds.width, 1))
            case .ended, .cancelled, .failed:
                playback.endSwipeScrub()
            default:
                break
            }
        }

        nonisolated func playerViewController(_ playerViewController: AVPlayerViewController,
                                              willTransitionToVisibilityOfTransportBar visible: Bool,
                                              with coordinator: AVPlayerViewControllerAnimationCoordinator) {
            MainActor.assumeIsolated { isTransportBarVisible = visible }
        }

        @objc private func scrubBack(_ recognizer: UILongPressGestureRecognizer) { scrub(-1, recognizer.state) }
        @objc private func scrubForward(_ recognizer: UILongPressGestureRecognizer) { scrub(1, recognizer.state) }

        private func scrub(_ direction: Int, _ state: UIGestureRecognizer.State) {
            switch state {
            case .began: playback.beginScrub(direction: direction)
            case .ended, .cancelled, .failed: playback.endScrub()
            default: break
            }
        }

        func installZapGestures(on view: UIView) {
            let presses: [(UIPress.PressType, Int)] = [(.pageUp, 1), (.pageDown, -1)]
            for (type, offset) in presses {
                let recognizer = UITapGestureRecognizer(target: self,
                                                        action: offset > 0 ? #selector(zapUp) : #selector(zapDown))
                recognizer.allowedPressTypes = [NSNumber(value: type.rawValue)]
                recognizer.delegate = self
                view.addGestureRecognizer(recognizer)
            }
        }

        @objc private func zapUp() { playback.zap(by: 1) }
        @objc private func zapDown() { playback.zap(by: -1) }

        /// Kaydırma yalnızca çubuk gizliyken, geri sarılabilen yayında ve yatay hareketle başlar;
        /// dikey kaydırma (aşağı: Kanallar paneli) AVKit'te kalır.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === swipeRecognizer, let pan = swipeRecognizer, let view = pan.view else { return true }
            let velocity = pan.velocity(in: view)
            return !isTransportBarVisible && playback.canRewind && abs(velocity.x) > abs(velocity.y) * 1.5
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Basılı tutma ve kaydırma bizim: AVKit'in kendi taraması aynı anda başlamasın
            !(gestureRecognizer is UILongPressGestureRecognizer) && gestureRecognizer !== swipeRecognizer
        }

        /// AVKit'in yalnızca aynı işi yapan tanıyıcıları bizimkinin sonucunu bekler: sol/sağ basılı tutma
        /// için sol/sağ tuş tanıyıcıları, kaydırma için kaydırma tanıyıcıları. Hepsini bekletmek
        /// (önceki hata) AVKit'in zaman çubuğunda kaydırarak sarmasını tamamen kilitliyordu.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard other.view !== gestureRecognizer.view else { return false }
            if gestureRecognizer is UILongPressGestureRecognizer {
                return other.allowedPressTypes.contains { Self.arrowPressTypes.contains($0.intValue) }
            }
            if gestureRecognizer === swipeRecognizer {
                return other is UIPanGestureRecognizer && !isTransportBarVisible
            }
            return false
        }
    }
}

/// Oynatıcı içindeki kanal şeridi: kanal numarası sırasında, açılınca odak izlenen kanalda olur
/// ki sağa/sola gidince komşu kanallara geçilsin.
private struct ChannelStripView: View {
    @ObservedObject var store: PlaylistStore
    @ObservedObject var playback: PlaybackController
    @FocusState private var focusedName: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // 40 küsur kanal için tembel yükleme gerekmez; odaklanacak kart hep hazır olmalı
                HStack(spacing: 40) {
                    ForEach(store.channels) { channel in
                        Button { playback.play(channel) } label: {
                            ChannelLogo(channel: channel, padding: 20)
                                .frame(width: 256, height: 144)
                                .overlay(alignment: .topLeading) {
                                    if let number = store.number(of: channel) {
                                        NumberBadge(number: number).padding(10)
                                    }
                                }
                                .overlay(alignment: .topTrailing) {
                                    if store.isFavorite(channel) {
                                        Image(systemName: "star.fill")
                                            .font(.caption)
                                            .foregroundStyle(.yellow)
                                            .padding(12)
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
                        .focused($focusedName, equals: channel.name)
                        .id(channel.name)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 40)
            }
            .scrollClipDisabled()
            .defaultFocus($focusedName, playback.channel.name)
            .onAppear { focusCurrent(proxy) }
            .onChange(of: playback.channel.name) { _, _ in focusCurrent(proxy) }
        }
    }

    private func focusCurrent(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(playback.channel.name, anchor: .center)
        focusedName = playback.channel.name
    }
}
