import SwiftUI

struct BatteryRing: View {
    let percent: Int?
    let charging: Bool
    var size: CGFloat = 148

    var body: some View {
        let color = percent.map(Theme.batteryColor) ?? Theme.textFaint
        ZStack {
            Circle().stroke(Color.white.opacity(0.07), lineWidth: size * 0.075)
            Circle()
                .trim(from: 0, to: CGFloat(percent ?? 0) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.45), radius: 10)
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(percent.map(String.init) ?? "-")
                        .font(.system(size: size * 0.27, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    if percent != nil {
                        Text("%").font(.system(size: size * 0.11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                HStack(spacing: 4) {
                    if charging { Image(systemName: "bolt.fill").foregroundStyle(color) }
                    // A small ring has no room for the word.
                    if size >= 100 {
                        Text(charging ? "Charging" : "Battery")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .font(.system(size: 11.5, weight: .medium))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Radar animation for the waiting-for-device state.
struct RadarView: View {
    var animated = true

    private static let duration = 2.7

    var body: some View {
        ZStack {
            if animated {
                TimelineView(.animation) { timeline in
                    rings(time: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                rings(time: 1.1)
            }
            Circle().fill(Theme.accentGradient).frame(width: 66, height: 66)
                .shadow(color: Theme.mint.opacity(0.5), radius: 22)
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(Theme.ink)
        }
        .frame(width: 230, height: 230)
    }

    private func rings(time: TimeInterval) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                let offset = Double(index) * Self.duration / 3
                let progress = (time + offset).truncatingRemainder(dividingBy: Self.duration) / Self.duration
                Circle()
                    .strokeBorder(Theme.mint.opacity(0.55 * (1 - progress)), lineWidth: 1.5)
                    .scaleEffect(0.25 + 0.75 * progress)
            }
        }
    }
}

struct StorageBar: View {
    let free: Int64
    let total: Int64

    var body: some View {
        let used = max(0, Double(total - free) / Double(max(total, 1)))
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(Theme.accentGradient).frame(width: max(6, proxy.size.width * used))
            }
        }
        .frame(height: 7)
    }
}

struct InfoTile: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.mint)
                    .frame(width: 34, height: 34)
                    .background(Theme.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                Text(value).font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary).lineLimit(2)
            }
        }
    }
}

struct LogoMark: View {
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24).fill(Theme.logo)
            LogoGlyph().fill(Color.white).frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

/// A text field that fits the dark theme, instead of the light system field.
struct DyskField: View {
    var icon: String?
    let placeholder: String
    @Binding var text: String
    var monospaced = false
    var multiline = false
    var clearable = true
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: multiline ? .bottom : .center, spacing: 8) {
            if let icon {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(focused ? Theme.mint : Theme.textFaint)
                    .padding(.bottom, multiline ? 2 : 0)
            }
            Group {
                if multiline {
                    TextField("", text: $text, prompt: prompt, axis: .vertical).lineLimit(1...6)
                } else {
                    TextField("", text: $text, prompt: prompt)
                }
            }
            .textFieldStyle(.plain)
            .font(monospaced ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
            .foregroundStyle(Theme.textPrimary)
            .tint(Theme.mint)
            .focused($focused)
            .onSubmit(onSubmit)
            if clearable, !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain).help("Clear")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.ink.opacity(0.65), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(focused ? Theme.mint.opacity(0.55) : Theme.stroke, lineWidth: focused ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .animation(.easeOut(duration: 0.12), value: focused)
    }

    private var prompt: Text { Text(placeholder).foregroundStyle(Theme.textFaint) }
}

/// A round avatar with initials, colored by the name so the same person keeps the same color.
struct Avatar: View {
    let name: String
    var size: CGFloat = 34

    private static let colors = [Theme.mint, Theme.violet, Theme.amber, Theme.coral, Color(hex: 0x5CB8FF), Color(hex: 0xFF9F5C)]

    var body: some View {
        let color = Self.colors[abs(name.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % Self.colors.count]
        Text(PhoneSearch.initials(name))
            .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: Circle())
    }
}

/// A small uppercase heading above a group of cards.
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .bold)).tracking(1.2).foregroundStyle(Theme.textFaint)
            .padding(.top, 6).padding(.leading, 2)
    }
}

/// A small icon button, for actions inside rows.
struct IconButton: View {
    let icon: String
    let help: String
    var tint: Color = Theme.textSecondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Theme.panelRaised, in: Circle())
                .overlay(Circle().strokeBorder(Theme.stroke))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension View {
    /// The dark field look for a TextField that DyskField can't wrap, such as a number field.
    func dyskFieldLook(compact: Bool = false) -> some View {
        self.textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, compact ? 8 : 12).padding(.vertical, compact ? 5 : 9)
            .background(Theme.ink.opacity(0.65), in: RoundedRectangle(cornerRadius: compact ? 8 : 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: compact ? 8 : 11, style: .continuous).strokeBorder(Theme.stroke))
    }
}
