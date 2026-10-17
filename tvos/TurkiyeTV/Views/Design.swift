import SwiftUI

/// Uygulamanın ortak görsel dili: koyu zemin, ikondaki kırmızı-pembe ışık, cam yüzeyler.
enum Theme {
    static let accent = Color(red: 1.0, green: 0.18, blue: 0.33)
    static let accentWarm = Color(red: 1.0, green: 0.55, blue: 0.24)
    static let accentCool = Color(red: 0.69, green: 0.16, blue: 0.9)
    static let accentGradient = LinearGradient(colors: [accentWarm, accent, accentCool],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
    static let cardSize = CGSize(width: 320, height: 180)
    static let cornerRadius: CGFloat = 36
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.08, green: 0.08, blue: 0.1), .black],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.accent.opacity(0.22), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 1300)
            RadialGradient(colors: [Theme.accentCool.opacity(0.12), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 1100)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// tvOS 26'da Liquid Glass, öncesinde buzlu cam.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = Theme.cornerRadius) -> some View {
        if #available(tvOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.white)
                .frame(width: 10, height: 10)
            Text("CANLI")
                .font(.caption2.weight(.heavy))
                .tracking(1.5)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Theme.accent, in: Capsule())
    }
}

struct NumberBadge: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
    }
}

/// Bir kanalı tam ekran oynatıcıda açar; kök görünüm sağlar.
struct PlayChannelAction {
    let action: (Channel) -> Void

    func callAsFunction(_ channel: Channel) {
        action(channel)
    }
}

private struct PlayChannelKey: EnvironmentKey {
    static let defaultValue = PlayChannelAction { _ in }
}

extension EnvironmentValues {
    var playChannel: PlayChannelAction {
        get { self[PlayChannelKey.self] }
        set { self[PlayChannelKey.self] = newValue }
    }
}
