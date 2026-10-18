import SwiftUI

/// Yayın akışı ızgarası: solda kanallar, sağda saat ekseninde programlar (yarım saat öncesinden 12 saat sonrasına).
/// Tüm satırlar tek bir yatay kaydırmanın içinde: sağa gidildikçe saatler birlikte kayar, satırlar hizalı kalır.
/// Yayındaki programa basınca kanal açılır, ilerideki programa basınca hatırlatıcı kurulur/kaldırılır.
struct GuideView: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var guide: ProgramGuide
    /// Izgaranın başladığı an (bir önceki yarım saat); sekme her açıldığında güncellenir.
    @State private var origin = GuideView.currentOrigin()
    @Namespace private var focusNamespace
    /// Izgaranın görünen sol kenarı (dakika, 15 dk adımlarla): solda başlamış uzun programların adı
    /// görünür alanın başına kayar, kutu boş görünmez.
    @State private var visibleStartMinute = 0

    static let pointsPerMinute: CGFloat = 8
    static let rowHeight: CGFloat = 104
    static let rowSpacing: CGFloat = 14
    static let channelColumnWidth: CGFloat = 250
    static let span: TimeInterval = 12.5 * 3600

    var body: some View {
        if store.channels.isEmpty {
            EmptyPlaylistView()
        } else {
            let channels = store.ordered(store.channels)
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(spacing: Self.rowSpacing) {
                        Color.clear.frame(height: 50 + 12)  // saat başlığının hizası
                        ForEach(channels) { channel in
                            GuideChannelCell(channel: channel)
                        }
                    }
                    .frame(width: Self.channelColumnWidth)

                    ScrollView(.horizontal, showsIndicators: false) {
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                                TimeHeader(origin: origin)
                                ForEach(channels) { channel in
                                    GuideRow(channel: channel, programs: guide.programs(for: channel), origin: origin,
                                             visibleStart: origin.addingTimeInterval(TimeInterval(visibleStartMinute) * 60),
                                             defaultFocus: channel.id == channels.first?.id ? focusNamespace : nil)
                                }
                            }
                            NowLine(origin: origin)
                        }
                        // odaklanan hücre büyüyünce kırpılmasın; sola kayan hücreler kanal sütununun altına girmesin
                        .padding(.vertical, 12)
                        .padding(.horizontal, 12)
                        .padding(.trailing, 68)
                        .focusScope(focusNamespace)
                    }
                    .modifier(VisibleStartTracker(minute: $visibleStartMinute))
                }
                .padding(.vertical, 30)
            }
            .onAppear { origin = Self.currentOrigin() }
        }
    }

    /// Görünen sol kenarı izler (tvOS 18+); 15 dk'lık adımlarla güncellenir, her karede tüm ızgara yeniden çizilmez.
    private struct VisibleStartTracker: ViewModifier {
        @Binding var minute: Int

        func body(content: Content) -> some View {
            if #available(tvOS 18.0, *) {
                content.onScrollGeometryChange(for: Int.self) { geometry in
                    // içerikteki 12 pt kenar boşluğu düşülür
                    // yukarı yuvarlanır: yazı görünen kenarın biraz sağında başlar, kesilmez
                    let minutes = max(0, geometry.contentOffset.x - 12) / GuideView.pointsPerMinute
                    return Int((minutes / 15).rounded(.up)) * 15
                } action: { _, value in
                    minute = value
                }
            } else {
                content
            }
        }
    }

    static func currentOrigin(now: Date = Date()) -> Date {
        let step: TimeInterval = 30 * 60
        return Date(timeIntervalSince1970: (now.timeIntervalSince1970 / step).rounded(.down) * step)
    }

    static func x(for date: Date, origin: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(origin) / 60) * pointsPerMinute
    }

    static var totalWidth: CGFloat {
        CGFloat(span / 60) * pointsPerMinute
    }
}

private struct GuideChannelCell: View {
    @EnvironmentObject private var store: PlaylistStore
    let channel: Channel

    var body: some View {
        HStack(spacing: 14) {
            ChannelLogo(channel: channel, padding: 10)
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                if let number = store.number(of: channel) {
                    Text("\(number)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(channel.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .frame(height: GuideView.rowHeight)
    }
}

private struct TimeHeader: View {
    let origin: Date

    var body: some View {
        let slots = Int(GuideView.span / 1800)
        ZStack(alignment: .topLeading) {
            ForEach(0..<slots, id: \.self) { index in
                let date = origin.addingTimeInterval(TimeInterval(index) * 1800)
                Text(ProgramText.clock(date))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .offset(x: GuideView.x(for: date, origin: origin))
            }
        }
        .frame(width: GuideView.totalWidth, height: 50, alignment: .topLeading)
    }
}

/// Şu anı gösteren dikey çizgi.
private struct NowLine: View {
    let origin: Date

    var body: some View {
        TimelineView(.everyMinute) { context in
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
                .offset(x: GuideView.x(for: context.date, origin: origin) - 2)
        }
        .allowsHitTesting(false)
    }
}

private struct GuideRow: View {
    @EnvironmentObject private var reminders: ReminderStore
    @Environment(\.playChannel) private var playChannel
    let channel: Channel
    let programs: [TVProgram]
    let origin: Date
    let visibleStart: Date
    /// İlk satırda: sekme açılınca odak yayındaki programa gelir.
    let defaultFocus: Namespace.ID?

    var body: some View {
        let end = origin.addingTimeInterval(GuideView.span)
        let visible = programs.filter { $0.end > origin && $0.start < end }
        ZStack(alignment: .topLeading) {
            if visible.isEmpty {
                GuideCell(title: "Yayın akışı yok", subtitle: nil, isLive: true, isReminded: false) {
                    playChannel(channel)
                }
                .frame(width: GuideView.x(for: Date().addingTimeInterval(3 * 3600), origin: origin))
            }
            ForEach(visible, id: \.self) { program in
                let start = max(program.start, origin)
                // başı görünmüyorsa yazı görünen kenardan başlar (programın sonuna sığdığı sürece)
                let textInset = max(0, min(GuideView.x(for: visibleStart, origin: origin) - GuideView.x(for: start, origin: origin),
                                           GuideView.x(for: min(program.end, end), origin: origin)
                                               - GuideView.x(for: start, origin: origin) - 260))
                let finish = min(program.end, end)
                let width = max(GuideView.x(for: finish, origin: origin) - GuideView.x(for: start, origin: origin) - 8, 36)
                TimelineView(.everyMinute) { context in
                    let isLive = program.contains(context.date)
                    let isPast = program.end <= context.date
                    GuideCell(title: program.title, subtitle: ProgramText.timeRange(program),
                              isLive: isLive, isReminded: reminders.isSet(channel, program), textInset: textInset,
                              isPast: isPast) {
                        if isLive || isPast {
                            playChannel(channel)
                        } else {
                            reminders.toggle(channel, program)
                        }
                    }
                    .modifier(DefaultFocus(namespace: isLive ? defaultFocus : nil))
                    .contextMenu {
                        if !isLive && !isPast {
                            let isSet = reminders.isSet(channel, program)
                            Button { reminders.toggle(channel, program) } label: {
                                Label(isSet ? "Hatırlatmayı kaldır" : "Hatırlat", systemImage: isSet ? "bell.slash" : "bell")
                            }
                        }
                        Button { playChannel(channel) } label: {
                            Label("\(channel.name) kanalını aç", systemImage: "play.fill")
                        }
                    }
                }
                .frame(width: width)
                .offset(x: GuideView.x(for: start, origin: origin))
            }
        }
        .frame(width: GuideView.totalWidth, height: GuideView.rowHeight, alignment: .topLeading)
    }
}

private struct DefaultFocus: ViewModifier {
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.prefersDefaultFocus(true, in: namespace)
        } else {
            content
        }
    }
}

private struct GuideCell: View {
    let title: String
    let subtitle: String?
    let isLive: Bool
    let isReminded: Bool
    var textInset: CGFloat = 0
    var isPast = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            EmptyView()
        }
        .buttonStyle(GuideCellStyle(title: title, subtitle: subtitle, isLive: isLive, isReminded: isReminded,
                                    isPast: isPast, textInset: textInset))
    }
}

private struct GuideCellStyle: ButtonStyle {
    let title: String
    let subtitle: String?
    let isLive: Bool
    let isReminded: Bool
    let isPast: Bool
    let textInset: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        CellBody(style: self, isPressed: configuration.isPressed)
    }

    private struct CellBody: View {
        let style: GuideCellStyle
        let isPressed: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if style.isReminded {
                        Image(systemName: "bell.fill")
                            .font(.caption2)
                            .foregroundStyle(isFocused ? .black : Theme.accent)
                    }
                    Text(style.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                if let subtitle = style.subtitle {
                    Text(subtitle)
                        .font(.caption2.monospacedDigit())
                        .lineLimit(1)
                        .opacity(0.7)
                }
            }
            .foregroundStyle(isFocused ? .black : .primary)
            .padding(.horizontal, 16)
            .padding(.leading, style.textInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(background)
            }
            .overlay(alignment: .leading) {
                if style.isLive && !isFocused {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.accent)
                        .frame(width: 4)
                        .padding(.vertical, 14)
                }
            }
            .opacity(style.isPast && !isFocused ? 0.55 : 1)
            .scaleEffect(isFocused ? (isPressed ? 1.0 : 1.06) : 1)
            .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 16, y: 8)
            .zIndex(isFocused ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: isFocused)
        }

        private var background: Color {
            if isFocused { return .white }
            return style.isLive ? Color.white.opacity(0.16) : Color.white.opacity(0.07)
        }
    }
}
