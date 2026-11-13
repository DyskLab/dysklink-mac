import SwiftUI

struct BatteryRing: View {
    let percent: Int?
    let charging: Bool
    var size: CGFloat = 148

    var body: some View {
        let color = percent.map(Theme.batteryColor) ?? Theme.textFaint
        ZStack {
            Circle().stroke(Theme.contrast.opacity(0.07), lineWidth: size * 0.075)
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
                .foregroundStyle(Theme.onAccent)
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
                Capsule().fill(Theme.contrast.opacity(0.08))
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
        .background(Theme.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
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

    private static let colors = [Theme.mint, Theme.violet, Theme.amber, Theme.coral, Theme.sky, Color(dark: 0xFF9F5C, light: 0xD9661A)]

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
            .background(Theme.background.opacity(0.65), in: RoundedRectangle(cornerRadius: compact ? 8 : 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: compact ? 8 : 11, style: .continuous).strokeBorder(Theme.stroke))
    }
}

/// One tab or filter in a row of pills: solid mint with dark text when selected, a raised pill otherwise.
/// Advanced, device tabs, Mac care, and File history all use it so a selected tab looks the same everywhere.
struct TabPill: View {
    var icon: String?
    let title: String
    let isSelected: Bool
    /// False on a narrow window, where only the icon shows (the selected pill keeps its title).
    var showsTitle = true
    var count: Int?
    /// A count that wants attention, such as unread notifications, stays solid mint when not selected.
    var highlightsCount = false
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                if showsTitle || isSelected || icon == nil {
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                if let count, count > 0 || !highlightsCount {
                    Text("\(count)").font(.system(size: 10.5, weight: .bold)).monospacedDigit()
                        .foregroundStyle(countText)
                        .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
                        .background(countFill, in: Capsule())
                }
            }
            .fixedSize()
            .foregroundStyle(isSelected ? Theme.onAccent : Theme.textPrimary)
            .padding(.horizontal, 11).frame(height: 30)
            .background(isSelected ? Theme.mint : Theme.panelRaised, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help ?? title)
    }

    private var countFill: Color {
        if isSelected { return Theme.onAccent.opacity(0.22) }
        return highlightsCount ? Theme.mint : Theme.mint.opacity(0.18)
    }

    private var countText: Color {
        if isSelected { return Theme.onAccent }
        return highlightsCount ? Theme.onAccent : Theme.textPrimary
    }
}

/// Numbers and dates in the reader's locale, so decimals and dates read the same everywhere in the app.
enum LocalFormat {
    /// A decimal with a fixed number of digits after the separator, such as "36,4" or "36.4".
    static func decimal(_ value: Double, digits: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }

    static func watts(_ value: Double, digits: Int = 2) -> String { "\(decimal(value, digits: digits)) W" }

    static func celsius(_ value: Double) -> String { "\(decimal(value)) °C" }

    /// An hour of today for a chart axis: "9 AM" or "09".
    static func hour(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    /// An hour of today for a picker: "9:00 AM" or "09:00".
    static func clock(hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    private static let dayParser: DateFormatter = {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        return parser
    }()

    /// A saved "yyyy-MM-dd" day shown as a short date in the reader's locale.
    static func day(_ text: String) -> String {
        dayParser.date(from: text)?.formatted(date: .abbreviated, time: .omitted) ?? text
    }
}

/// System Settings pages that a hint sends people to when macOS blocks something DyskLink needs.
enum SystemPane {
    static let accessibility = "com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
    static let screenRecording = "com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
    static let automation = "com.apple.settings.PrivacySecurity.extension?Privacy_Automation"
    static let fullDiskAccess = "com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    static let localNetwork = "com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork"
    static let firewall = "com.apple.Network-Settings.extension?Firewall"
    static let wifi = "com.apple.wifi-settings-extension"
    static var notifications: String {
        "com.apple.Notifications-Settings.extension" + (Bundle.main.bundleIdentifier.map { "?id=\($0)" } ?? "")
    }

    @MainActor
    static func open(_ pane: String) {
        if let url = LauncherSettings.url(pane) { NSWorkspace.shared.open(url) }
    }
}

/// A short amber line saying what macOS is blocking, with a button that goes where it's fixed.
struct HintRow: View {
    let text: String
    var button = "Open Settings"
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.amberText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(button, action: action).buttonStyle(SecondaryButtonStyle())
        }
    }
}
