import SwiftUI

enum Theme {
    static let logo = Color(hex: 0x2B3A57)
    static let ink = Color(hex: 0x090D13)
    static let panel = Color(hex: 0x121822)
    static let panelRaised = Color(hex: 0x1A2230)
    static let stroke = Color.white.opacity(0.08)
    static let textPrimary = Color(hex: 0xF2F5F9)
    static let textSecondary = Color(hex: 0x98A3B3)
    static let textFaint = Color(hex: 0x667081)
    static let mint = Color(hex: 0x5EF2C2)
    static let violet = Color(hex: 0x8B7BFF)
    static let amber = Color(hex: 0xFFC35C)
    static let coral = Color(hex: 0xFF6F7D)

    static let accentGradient = LinearGradient(
        colors: [mint, Color(hex: 0x4CC9F0), violet],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static func batteryColor(_ percent: Int) -> Color {
        if percent <= 15 { return coral }
        if percent <= 35 { return amber }
        return mint
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

struct AuroraBackground: View {
    var body: some View {
        ZStack {
            Theme.ink
            Circle().fill(Theme.violet.opacity(0.22)).frame(width: 520, height: 520)
                .blur(radius: 130).offset(x: 300, y: -260)
            Circle().fill(Theme.mint.opacity(0.13)).frame(width: 460, height: 460)
                .blur(radius: 130).offset(x: -260, y: 280)
        }
        .clipped()
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.stroke))
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.8), radius: 4)
            Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .bold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 20).padding(.vertical, 11)
            .background(Theme.accentGradient, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.textPrimary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 20).padding(.vertical, 11)
            .background(Theme.panelRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytesPerSecond) + "/s"
    }
}
