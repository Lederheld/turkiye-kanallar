import AVKit
import SwiftUI

/// Tam ekran oynatıcı.
/// - Kanal değişince sol üstte birkaç saniye kanal bilgisi görünür.
/// - Kumandada sol/sağ basılı tutunca görüntü hızlanarak sarılır (5, 10, 20, 30, 45 dk, 1 sa…).
/// - Tek zaman çubuğu var, AVKit'inki. Oynarken dokunmatik yüzeyde sola/sağa kaydırınca görüntü sarılır ve
///   o çubuktaki konum kayar (YouTube/Netflix gibi); duraklatılmışken AVKit'in kendi sarması çalışır.
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
    @ObservedObject var reminders: ReminderStore
    @StateObject private var playback: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @State private var showsBanner = false
    @State private var bannerTask: Task<Void, Never>?

    init(channel: Channel, store: PlaylistStore, guide: ProgramGuide, reminders: ReminderStore) {
        self.store = store
        self.guide = guide
        self.reminders = reminders
        _playback = StateObject(wrappedValue: PlaybackController(channel: channel, store: store, guide: guide))
    }

    var body: some View {
        PlayerViewControllerRepresentable(playback: playback, store: store, guide: guide, reminders: reminders,
                                          state: TransportState(isFavorite: store.isFavorite(playback.channel),
                                                                canRecall: playback.previousChannel != nil,
                                                                canRewind: playback.canRewind,
                                                                hasGuide: !guide.programs(for: playback.channel).isEmpty,
                                                                sleepEndsAt: playback.sleepEndsAt,
                                                                isSleepWarningShown: playback.isSleepWarningShown,
                                                                timeline: timelineStops,
                                                                upcoming: upcomingPrograms,
                                                                remindedIDs: Set(reminders.reminders.map(\.id)),
                                                                dueChannel: dueChannel?.name))
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                if showsBanner && playback.failure == nil {
                    ChannelBanner(channel: playback.channel, number: store.number(of: playback.channel),
                                  program: guide.program(for: playback.channel, at: watchedDate),
                                  rewindWindow: playback.canRewind ? playback.rewindWindow : nil)
                        .padding(.leading, 80)
                        .padding(.top, 60)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                // Kaydırma başladığında AVKit'in çubuğu ~1 sn sonra açılıyor; o arada aynı yerde onun yerini tutan
                // ince bir çizgi çizilir, çubuk açılınca çekilir (üst üste iki çubuk olmaz)
                if playback.canRewind && (playback.isTransportBarVisible || playback.swipeTargetBehind != nil) {
                    ProgramSegments(programs: guide.programs(for: playback.channel), window: playback.rewindWindow,
                                    highlightedAt: playback.swipeTargetBehind.map { Date().addingTimeInterval(-$0) },
                                    placeholderPlayhead: playback.isTransportBarVisible ? nil : playback.behindLive)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: playback.isTransportBarVisible)
            .overlay {
                if let target = playback.swipeTargetBehind {
                    SwipeTargetMarker(targetBehind: target, offset: playback.behindLive - target,
                                      window: playback.rewindWindow,
                                      program: guide.program(for: playback.channel, at: Date().addingTimeInterval(-target)))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if playback.isBehindLive && playback.failure == nil {
                    BehindLiveBadge(seconds: playback.behindLive)
                        .padding(.trailing, 80)
                        .padding(.top, 60)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let due = reminders.due, let channel = dueChannel {
                    ReminderPrompt(reminder: due, channel: channel)
                        .padding(.trailing, 80)
                        .padding(.bottom, 260)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.smooth, value: reminders.due)
            .overlay {
                if let failure = playback.failure {
                    errorOverlay(failure)
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
            .onChange(of: playback.channel.name) { _, name in
                showBanner()
                if reminders.due?.channelName == name { reminders.dismissDue() }
            }
            // Hatırlatılan program başlamak üzere: kanalı gizli oynatıcıda hazırla, "Geç" anında açılsın
            .onChange(of: dueChannel?.name, initial: true) { _, _ in
                if let dueChannel { playback.prepareStandby(dueChannel) }
            }
            .onChange(of: playback.sleepTimerFired) { _, fired in
                if fired { dismiss() }
            }
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

    /// Bu kanalda sıradaki programlar (Kanal menüsünden hatırlatıcı kurmak için).
    private var upcomingPrograms: [TVProgram] {
        let now = Date()
        return Array(guide.programs(for: playback.channel).filter { $0.start > now }.prefix(8))
    }

    /// Başlamak üzere olan hatırlatılmış programın kanalı (izlenen kanal değilse).
    private var dueChannel: Channel? {
        guard let due = reminders.due, due.channelName != playback.channel.name else { return nil }
        return store.channel(named: due.channelName)
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

    /// Açılamayan kanal: neden, kendiliğinden deneme sayacı ve tek tıkla geçilecek benzer kanallar.
    private func errorOverlay(_ failure: PlaybackFailure) -> some View {
        let channel = playback.channel
        return VStack(spacing: 28) {
            Image(systemName: failure.symbol)
                .font(.system(size: 72))
                .foregroundStyle(failure.kind == .offline ? .orange : .yellow)
            Text(failure.title)
                .font(.title2.weight(.bold))
            Text(failure.explanation(for: channel))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1000)
            if let retryAt = playback.autoRetryAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(retryAt.timeIntervalSince(context.date).rounded(.up)))
                    Text(seconds > 0 ? "\(seconds) sn sonra tekrar denenecek" : "Deneniyor…")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 40) {
                Button { playback.retry() } label: {
                    Label("Tekrar dene", systemImage: "arrow.clockwise")
                }
                Button { dismiss() } label: {
                    Label("Kanallara dön", systemImage: "square.grid.2x2")
                }
            }
            let suggestions = suggestedChannels(instead: channel)
            if failure.kind != .offline && !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Bunun yerine")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 32) {
                        ForEach(suggestions) { suggestion in
                            Button { playback.play(suggestion) } label: {
                                ChannelLogo(channel: suggestion, padding: 16)
                                    .frame(width: 192, height: 108)
                            }
                            .buttonStyle(.card)
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(60)
        .glassSurface()
    }

    /// Aynı kategoriden, en çok izlenenler önde; yetmezse en çok izlenen diğer kanallar.
    private func suggestedChannels(instead channel: Channel) -> [Channel] {
        let others = store.ordered(store.channels).filter { $0.name != channel.name }
        let sameCategory = others.filter { $0.category == channel.category }
        let rest = others.filter { $0.category != channel.category }
        return Array((sameCategory + rest).prefix(4))
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

/// AVKit'in zaman çubuğunun ekrandaki yeri (tvOS 26 yerleşiminden ölçüldü): genişliğin %4,6–%95,6'sı,
/// yüksekliğin %84,3'ü. Çubuğun üstüne çizilenler (program bölümleri, kaydırma hedefi) bunu kullanır.
private enum TransportBarGeometry {
    static let start: CGFloat = 0.046
    static let end: CGFloat = 0.956
    static let y: CGFloat = 0.843

    /// Canlının `behind` saniye gerisinin çubuktaki x'i; çubuk sunucunun tuttuğu pencerenin tamamıdır.
    static func x(behind: TimeInterval, window: TimeInterval, width: CGFloat) -> CGFloat {
        let fraction = 1 - min(max(behind / max(window, 1), 0), 1)
        return width * (start + (end - start) * fraction)
    }
}

/// Zaman çubuğunu programlara göre bölümlere ayırır (YouTube bölümleri gibi): program sınırlarında
/// çubukta küçük boşluklar; kaydırırken hedefin düştüğü program çubuğun üstünde vurgulanır.
private struct ProgramSegments: View {
    let programs: [TVProgram]
    let window: TimeInterval
    let highlightedAt: Date?
    /// AVKit'in çubuğu henüz açılmadıysa onun yerine çizilecek çubuğun oynatma konumu (canlının gerisi).
    let placeholderPlayhead: TimeInterval?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let now = Date()
            let windowStart = now.addingTimeInterval(-window)
            let y = size.height * TransportBarGeometry.y
            let x = { (date: Date) in
                TransportBarGeometry.x(behind: now.timeIntervalSince(date), window: window, width: size.width)
            }
            ZStack(alignment: .topLeading) {
                if let placeholderPlayhead {
                    let left = size.width * TransportBarGeometry.start
                    let right = size.width * TransportBarGeometry.end
                    let playhead = x(now.addingTimeInterval(-placeholderPlayhead))
                    Capsule().fill(.white.opacity(0.3))
                        .frame(width: right - left, height: 10)
                        .position(x: (left + right) / 2, y: y)
                    Capsule().fill(.white.opacity(0.75))
                        .frame(width: max(playhead - left, 10), height: 10)
                        .position(x: (left + playhead) / 2, y: y)
                }
                ForEach(programs.filter { $0.start > windowStart && $0.start < now }, id: \.start) { program in
                    Rectangle()
                        .fill(.black.opacity(0.85))
                        .frame(width: 5, height: 16)
                        .position(x: x(program.start), y: y)
                }
                if let highlightedAt, let program = programs.last(where: { $0.contains(highlightedAt) }) {
                    let startX = x(max(program.start, windowStart))
                    let endX = x(min(program.end, now))
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(endX - startX, 6), height: 6)
                        .position(x: (startX + endX) / 2, y: y - 14)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
    }
}

/// Kaydırırken hedefi oynatıcının kendi zaman çubuğunun üstünde gösterir (ikinci bir çubuk çizmez):
/// çubuğun hedef noktasından yukarı uzanan ince bir çizgi, çubuğun düğme sırasının üstünde saat, fark ve
/// o saatteki program.
private struct SwipeTargetMarker: View {
    let targetBehind: TimeInterval
    let offset: TimeInterval
    let window: TimeInterval
    let program: TVProgram?

    private static let bubbleWidth: CGFloat = 400
    /// Balonun alt kenarı çubuğun bu kadar üstünde: AVKit'in düğme sırasının üstü.
    private static let bubbleLift: CGFloat = 130

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let x = TransportBarGeometry.x(behind: targetBehind, window: window, width: size.width)
            let y = size.height * TransportBarGeometry.y
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 5, height: Self.bubbleLift + 16)
                    .shadow(color: .black.opacity(0.5), radius: 4)
                    .position(x: x, y: y + 8 - (Self.bubbleLift + 16) / 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(targetBehind < 30 ? "Canlı" : ProgramText.clock(Date().addingTimeInterval(-targetBehind)))
                            .font(.title2.weight(.bold).monospacedDigit())
                        if abs(offset) >= 60 {
                            Text((offset < 0 ? "−" : "+") + DurationText.short(abs(offset)))
                                .font(.callout.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let program {
                        Text(program.title)
                            .font(.callout)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .frame(width: Self.bubbleWidth, alignment: .leading)
                .glassSurface(cornerRadius: 24)
                .alignmentGuide(.leading) { _ in -min(max(x - Self.bubbleWidth / 2, 20), size.width - Self.bubbleWidth - 20) }
                .alignmentGuide(.top) { bubble in -(y - Self.bubbleLift - bubble.height) }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .animation(.interactiveSpring(duration: 0.2), value: targetBehind)
        }
        .ignoresSafeArea()
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
    var sleepEndsAt: Date?
    var isSleepWarningShown: Bool
    var timeline: [TimelineStop]
    var upcoming: [TVProgram]
    var remindedIDs: Set<String>
    /// Hatırlatılan programın başladığı kanal: ekranda "Geç" düğmesi çıkar.
    var dueChannel: String?
}

struct TimelineStop: Equatable {
    let date: Date
    let title: String?
}

private struct PlayerViewControllerRepresentable: UIViewControllerRepresentable {
    let playback: PlaybackController
    let store: PlaylistStore
    let guide: ProgramGuide
    let reminders: ReminderStore
    let state: TransportState

    private static let channelPanelHeight: CGFloat = 430

    func makeCoordinator() -> Coordinator {
        Coordinator(playback: playback)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = playback.player

        let channelPanel = UIHostingController(rootView: ChannelStripView(store: store, guide: guide, playback: playback))
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
        // Anında kanal geçişinde hazır bekleyen oynatıcı ekrana alınır
        if controller.player !== playback.player {
            controller.player = playback.player
        }
        updateTransportBar(controller, coordinator: context.coordinator)
    }

    /// Çubukta yalnızca iki menü (artı AVKit'in altyazı/ses düğmesi): Zaman Tüneli ve Kanal.
    /// Düğme sayısı yayın boyunca değişmez; değişseydi odak başka düğmeye kayardı.
    private func updateTransportBar(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        // Her saniye yeniden kurmak çubuktaki odağı kaçırır
        guard coordinator.transportState != state else { return }
        coordinator.transportState = state
        var items: [UIMenuElement] = []
        if state.canRewind {
            items.append(timelineMenu(state))
        }
        items.append(channelMenu(state))
        controller.transportBarCustomMenuItems = items
        // Ekrandaki düğmeler: hatırlatılan program başlıyorsa o kanala geç; uyku zamanlayıcısı bitmek üzereyse uzat
        let playback = playback
        let store = store
        let reminders = reminders
        var actions: [UIAction] = []
        if let dueChannel = state.dueChannel {
            // AVKit odağı sondaki düğmeye veriyor: "Geç" sonda dursun, tek tıkla geçilsin
            actions.append(UIAction(title: "Kalsın", image: UIImage(systemName: "xmark")) { _ in
                Task { @MainActor in
                    reminders.dismissDue()
                    playback.discardStandby()
                }
            })
            actions.append(UIAction(title: "Geç: \(dueChannel)", image: UIImage(systemName: "bell.fill")) { _ in
                Task { @MainActor in
                    if let channel = store.channel(named: dueChannel) { playback.play(channel) }
                    reminders.dismissDue()
                }
            })
        }
        if state.isSleepWarningShown {
            actions.append(UIAction(title: "30 dk daha", image: UIImage(systemName: "moon.zzz")) { _ in
                Task { @MainActor in playback.extendSleepTimer() }
            })
        }
        controller.contextualActions = actions
    }

    /// Zaman Tüneli: canlıya dön, programın başı, 10 dk geri/ileri; altında program başlangıçları
    /// (akış yoksa yarım saatler).
    private func timelineMenu(_ state: TransportState) -> UIMenu {
        let playback = playback
        let guide = guide
        var controls: [UIMenuElement] = [
            UIAction(title: "Canlıya dön", image: UIImage(systemName: "dot.radiowaves.left.and.right")) { _ in
                Task { @MainActor in playback.goLive() }
            },
        ]
        if state.hasGuide {
            controls.append(UIAction(title: "Programın başına", image: UIImage(systemName: "backward.end.fill")) { _ in
                Task { @MainActor in
                    let watched = Date().addingTimeInterval(-playback.behindLive)
                    if let program = guide.program(for: playback.channel, at: watched) {
                        playback.seek(secondsBehindLive: Date().timeIntervalSince(program.start))
                    }
                }
            })
        }
        controls += [
            UIAction(title: "10 dk geri", image: UIImage(systemName: "gobackward.10")) { _ in
                Task { @MainActor in playback.skip(by: -600) }
            },
            UIAction(title: "10 dk ileri", image: UIImage(systemName: "goforward.10")) { _ in
                Task { @MainActor in playback.skip(by: 600) }
            },
        ]
        let calendar = Calendar.current
        let stops: [UIMenuElement] = state.timeline.map { stop in
            let clock = ProgramText.clock(stop.date)
            let action = UIAction(title: stop.title.map { "\(clock)  \($0)" } ?? clock) { _ in
                Task { @MainActor in playback.seek(secondsBehindLive: Date().timeIntervalSince(stop.date)) }
            }
            if !calendar.isDateInToday(stop.date) {
                action.subtitle = "Dün"
            }
            return action
        }
        return UIMenu(title: "Zaman Tüneli", image: UIImage(systemName: "clock.arrow.circlepath"), children: [
            UIMenu(options: .displayInline, children: controls),
            UIMenu(title: state.hasGuide ? "Programlar" : "Saatler", options: .displayInline, children: stops),
        ])
    }

    /// Kanal: önceki/sonraki, son izlenen ve favori.
    private func channelMenu(_ state: TransportState) -> UIMenu {
        let playback = playback
        let store = store
        var actions: [UIMenuElement] = [
            UIAction(title: "Sonraki kanal", image: UIImage(systemName: "chevron.up")) { _ in
                Task { @MainActor in playback.zap(by: 1) }
            },
            UIAction(title: "Önceki kanal", image: UIImage(systemName: "chevron.down")) { _ in
                Task { @MainActor in playback.zap(by: -1) }
            },
        ]
        if state.canRecall {
            actions.append(UIAction(title: "Son izlenen kanal", image: UIImage(systemName: "arrow.uturn.backward")) { _ in
                Task { @MainActor in playback.recall() }
            })
        }
        let favorite = UIAction(title: state.isFavorite ? "Favorilerden çıkar" : "Favorilere ekle",
                                image: UIImage(systemName: state.isFavorite ? "star.fill" : "star")) { _ in
            Task { @MainActor in store.toggleFavorite(playback.channel) }
        }
        var children: [UIMenuElement] = [
            UIMenu(options: .displayInline, children: actions),
            UIMenu(options: .displayInline, children: [favorite]),
        ]
        if !state.upcoming.isEmpty {
            children.append(reminderMenu(state))
        }
        children.append(sleepMenu(state))
        return UIMenu(title: "Kanal", image: UIImage(systemName: "tv"), children: children)
    }

    /// Sıradaki programlar; seçilen program başlamadan hatırlatılır (işaretliler kurulu).
    private func reminderMenu(_ state: TransportState) -> UIMenu {
        let playback = playback
        let reminders = reminders
        let calendar = Calendar.current
        let items: [UIMenuElement] = state.upcoming.map { program in
            let action = UIAction(title: "\(ProgramText.clock(program.start))  \(program.title)") { _ in
                Task { @MainActor in reminders.toggle(playback.channel, program) }
            }
            let id = Reminder(channel: playback.channel, program: program).id
            action.state = state.remindedIDs.contains(id) ? .on : .off
            if !calendar.isDateInToday(program.start) {
                action.subtitle = "Yarın"
            }
            return action
        }
        let isAnySet = state.upcoming.contains { state.remindedIDs.contains(Reminder(channel: playback.channel, program: $0).id) }
        return UIMenu(title: "Hatırlat", image: UIImage(systemName: isAnySet ? "bell.fill" : "bell"), children: items)
    }

    /// Uyku zamanlayıcısı: süre dolunca yayın durur, ana ekrana dönülür, Apple TV kendi uykusuna geçer.
    private func sleepMenu(_ state: TransportState) -> UIMenu {
        let playback = playback
        var options: [UIMenuElement] = [30, 60, 90].map { minutes in
            UIAction(title: "\(minutes) dakika") { _ in
                Task { @MainActor in playback.setSleepTimer(.minutes(minutes)) }
            }
        }
        if state.hasGuide {
            options.append(UIAction(title: "Program bitince") { _ in
                Task { @MainActor in playback.setSleepTimer(.endOfProgram) }
            })
        }
        if let endsAt = state.sleepEndsAt {
            options.append(UIAction(title: "Kapat · \(ProgramText.clock(endsAt))", attributes: .destructive) { _ in
                Task { @MainActor in playback.cancelSleepTimer() }
            })
        }
        let title = state.sleepEndsAt.map { "Uyku zamanlayıcısı · \(ProgramText.clock($0))" } ?? "Uyku zamanlayıcısı"
        return UIMenu(title: title, image: UIImage(systemName: state.sleepEndsAt == nil ? "moon" : "moon.fill"),
                      children: options)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate, AVPlayerViewControllerDelegate {
        let playback: PlaybackController
        var transportState: TransportState?
        /// Dokunmatik yüzeydeki parmağı ilk temastan izler (UIPanGestureRecognizer ancak belirgin bir
        /// hareketten sonra başladığı için hedef geç görünüyordu). Yatay hareket eşiği geçince sarma başlar.
        private var touchTracker: UILongPressGestureRecognizer?
        private var touchStart: CGPoint?
        private var isSwiping = false
        /// Bu kadar yatay hareketten sonra sarma başlar; dikey hareket önce gelirse (aşağı: Kanallar) hiç başlamaz.
        private static let swipeStartDistance: CGFloat = 12
        private static let verticalRejectDistance: CGFloat = 20
        /// Odak oynatıcının kendisinde (çubuk gizli ya da zaman çubuğunda) mı? Çubuktaki düğmelerdeyken ya da
        /// Kanallar panelindeyken yatay kaydırma odağı gezdirir, sarmaz. AVKit bu durumu açıkça vermediği
        /// için odaklanan görünümün sınıf adına bakılır; tanınmazsa sarma devre dışı kalır (AVKit'in davranışı).
        private var focusIsOnPlayer = true
        private var focusObserver: NSObjectProtocol?
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
            let tracker = UILongPressGestureRecognizer(target: self, action: #selector(trackTouch))
            tracker.minimumPressDuration = 0
            tracker.allowableMovement = 10_000
            tracker.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            tracker.allowedPressTypes = []
            tracker.cancelsTouchesInView = false
            tracker.delegate = self
            view.addGestureRecognizer(tracker)
            touchTracker = tracker
            focusObserver = NotificationCenter.default.addObserver(
                forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
                let isPlayer = context?.nextFocusedView.map { String(describing: type(of: $0)) == "_AVFocusContainerView" }
                MainActor.assumeIsolated { self?.focusIsOnPlayer = isPlayer ?? false }
            }
        }

        deinit {
            if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        }

        nonisolated func playerViewController(_ playerViewController: AVPlayerViewController,
                                              willTransitionToVisibilityOfTransportBar visible: Bool,
                                              with coordinator: AVPlayerViewControllerAnimationCoordinator) {
            MainActor.assumeIsolated { playback.isTransportBarVisible = visible }
        }

        @objc private func trackTouch(_ recognizer: UILongPressGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let location = recognizer.location(in: view)
            switch recognizer.state {
            case .began:
                touchStart = location
                isSwiping = false
            case .changed:
                guard let start = touchStart else { return }
                let dx = location.x - start.x
                let dy = location.y - start.y
                if !isSwiping {
                    if abs(dy) > Self.verticalRejectDistance && abs(dy) > abs(dx) {
                        touchStart = nil  // dikey kaydırma: AVKit'e bırak
                        return
                    }
                    guard abs(dx) > Self.swipeStartDistance, abs(dx) > abs(dy) * 1.5,
                          focusIsOnPlayer, playback.isPlaying, playback.canRewind else { return }
                    isSwiping = true
                    playback.beginSwipeSeek()
                }
                playback.updateSwipeSeek(points: dx)
            case .ended, .cancelled, .failed:
                if isSwiping { playback.endSwipeSeek() }
                touchStart = nil
                isSwiping = false
            default:
                break
            }
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

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Dokunma izleyici AVKit'i engellemez (çubuğu o gösterir); sol/sağ basılı tutma ise bizim:
            // AVKit'in kendi yavaş taraması aynı anda başlamasın
            gestureRecognizer === touchTracker || !(gestureRecognizer is UILongPressGestureRecognizer)
        }

        /// AVKit'in yalnızca sol/sağ tuş tanıyıcıları basılı tutmanın sonucunu bekler. Hepsini bekletmek
        /// (önceki hata) AVKit'in zaman çubuğunda kaydırarak sarmasını tamamen kilitliyordu.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard other.view !== gestureRecognizer.view, gestureRecognizer !== touchTracker else { return false }
            if gestureRecognizer is UILongPressGestureRecognizer {
                return other.allowedPressTypes.contains { Self.arrowPressTypes.contains($0.intValue) }
            }
            return false
        }
    }
}

/// Kanal kartının altında o an yayındaki program: ad, ince ilerleme çubuğu ve kalan süre.
/// Dakikada bir yenilenir.
private struct NowPlayingLine: View {
    let program: TVProgram?

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 6) {
                if let program {
                    Text(program.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    let total = program.end.timeIntervalSince(program.start)
                    let elapsed = context.date.timeIntervalSince(program.start)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.2))
                            Capsule().fill(Theme.accent)
                                .frame(width: geometry.size.width * min(max(elapsed / max(total, 1), 0), 1))
                        }
                    }
                    .frame(height: 4)
                    Text(Self.remainingText(program.end.timeIntervalSince(context.date)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Program bilgisi yok")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        }
    }

    static func remainingText(_ seconds: TimeInterval) -> String {
        let minutes = max(Int((seconds / 60).rounded(.up)), 0)
        if minutes < 60 { return "Bitmesine \(minutes) dk" }
        return minutes % 60 == 0 ? "Bitmesine \(minutes / 60) sa" : "Bitmesine \(minutes / 60) sa \(minutes % 60) dk"
    }
}

/// Oynatıcı içindeki kanal şeridi: kanal numarası sırasında, açılınca odak izlenen kanalda olur
/// ki sağa/sola gidince komşu kanallara geçilsin.
private struct ChannelStripView: View {
    @ObservedObject var store: PlaylistStore
    @ObservedObject var guide: ProgramGuide
    @ObservedObject var playback: PlaybackController
    @FocusState private var focusedName: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // 40 küsur kanal için tembel yükleme gerekmez; odaklanacak kart hep hazır olmalı
                HStack(spacing: 40) {
                    ForEach(store.channels) { channel in
                        Button { playback.play(channel) } label: {
                            VStack(spacing: 0) {
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
                            NowPlayingLine(program: guide.program(for: channel))
                            }
                            .frame(width: 256)
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
            .onDisappear { playback.discardStandby() }
            .onChange(of: playback.channel.name) { _, _ in focusCurrent(proxy) }
            // Üzerinde durulan kanal gizli oynatıcıda hazırlanır; seçilince anında açılır
            .onChange(of: focusedName) { _, name in
                if let name, let channel = store.channel(named: name) {
                    playback.prepareStandby(channel)
                } else {
                    playback.discardStandby()
                }
            }
        }
    }

    private func focusCurrent(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(playback.channel.name, anchor: .center)
        focusedName = playback.channel.name
    }
}
