import AppKit
import SwiftUI

/// Every colour has a dark and a light value, picked from the appearance of the view drawing it,
/// so a change of Appearance redraws the app at once. The light values match the Windows and Linux app.
enum Theme {
    static let logo = Color(hex: 0x14B8A6)
    /// Always the dark ink, for the notch and the frame around phone video, which stay dark.
    static let ink = Color(hex: 0x090D13)
    /// The window background: the dark ink, or a soft grey in light mode.
    static let background = Color(dark: 0x090D13, light: 0xF3F5F8)
    /// Text and icons on a solid mint, sky, amber, or coral fill, or on the accent gradient: the dark ink in
    /// both looks, since white on the light accents is only about 3:1.
    static let onAccent = Color(dark: 0x090D13, light: 0x090D13)
    /// The device list beside the pages.
    static let sidebar = Color(dark: 0x090D13, darkAlpha: 0.42, light: 0xE8ECF1, lightAlpha: 0.75)
    static let panel = Color(dark: 0x121822, light: 0xFFFFFF)
    static let panelRaised = Color(dark: 0x1A2230, light: 0xE6EAF0)
    static let stroke = Color(dark: 0xFFFFFF, darkAlpha: 0.08, light: 0x0B1220, lightAlpha: 0.10)
    static let textPrimary = Color(dark: 0xF2F5F9, light: 0x111723)
    static let textSecondary = Color(dark: 0x98A3B3, light: 0x4F5B6C)
    /// Light value is 4.5:1 or more on the panel, raised panel, background, and sidebar.
    static let textFaint = Color(dark: 0x667081, light: 0x5F6A7B)
    static let mint = Color(dark: 0x5EF2C2, light: 0x0FA67A)
    static let sky = Color(dark: 0x4CC9F0, light: 0x1A8FC2)
    static let violet = Color(dark: 0x8B7BFF, light: 0x6A5AE0)
    static let amber = Color(dark: 0xFFC35C, light: 0xC07F00)
    static let coral = Color(dark: 0xFF6F7D, light: 0xD9434F)

    // The accents above are for fills, rings, bars, icons, and large titles, where 3:1 is enough. Text uses
    // these: the same bright value on dark, and a deeper one on light that reads at 4.5:1 or more on the panel,
    // raised panel, background, and sidebar. The Android and Windows and Linux apps use the same values.
    static let mintText = Color(dark: 0x5EF2C2, light: 0x057553)
    static let skyText = Color(dark: 0x4CC9F0, light: 0x0B6A99)
    static let violetText = Color(dark: 0x8B7BFF, light: 0x5847D6)
    static let amberText = Color(dark: 0xFFC35C, light: 0x8A5A00)
    static let coralText = Color(dark: 0xFF6F7D, light: 0xB42333)

    /// The text-safe version of an accent, for views that take one colour for both a dot and a label.
    /// Any other colour comes back as it is.
    static func text(_ color: Color) -> Color {
        switch color {
        case mint: mintText
        case sky: skyText
        case violet: violetText
        case amber: amberText
        case coral: coralText
        default: color
        }
    }

    /// The light values, for the contrast check in the self-test.
    enum LightValues {
        static let background: UInt32 = 0xF3F5F8
        static let panel: UInt32 = 0xFFFFFF
        static let panelRaised: UInt32 = 0xE6EAF0
        /// The sidebar's 0xE8ECF1 at 75% over the background.
        static let sidebar: UInt32 = 0xEBEEF3
        static let text: [(String, UInt32)] = [
            ("textPrimary", 0x111723), ("textSecondary", 0x4F5B6C), ("textFaint", 0x5F6A7B),
            ("mintText", 0x057553), ("skyText", 0x0B6A99), ("violetText", 0x5847D6),
            ("amberText", 0x8A5A00), ("coralText", 0xB42333),
        ]
        static let fills: [(String, UInt32)] = [
            ("mint", 0x0FA67A), ("sky", 0x1A8FC2), ("amber", 0xC07F00), ("coral", 0xD9434F),
        ]
        static let onAccent: UInt32 = 0x090D13
    }

    /// The WCAG 2 contrast ratio of two opaque sRGB colours.
    static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            func channel(_ value: UInt32) -> Double {
                let c = Double(value & 0xFF) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
        }
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
    /// White on dark and near-black on light: the base for faint fills, tracks and dividers
    /// that used to be `Color.white.opacity(...)`.
    static let contrast = Color(dark: 0xFFFFFF, light: 0x0B1220)
    /// A shadow that reads on both: deep on dark, soft on light.
    /// The dimmed layer behind a dialog.
    static let scrim = Color(dark: 0x000000, darkAlpha: 0.62, light: 0x0B1220, lightAlpha: 0.32)
    static let shadow = Color(dark: 0x000000, darkAlpha: 0.45, light: 0x0B1220, lightAlpha: 0.12)

    static let accentGradient = LinearGradient(
        colors: [mint, sky, violet],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static func batteryColor(_ percent: Int) -> Color {
        if percent <= 15 { return coral }
        if percent <= 35 { return amber }
        return mint
    }
}

/// System, Dark, or Light, set in Advanced > General. Dark is the default, so the app looks as it always has.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, dark, light

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "System"
        case .dark: "Dark"
        case .light: "Light"
        }
    }

    /// For `.preferredColorScheme`; nil follows macOS.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}

@MainActor
@Observable
final class AppearanceStore {
    static let shared = AppearanceStore()
    private static let key = "appearance"

    var mode: AppearanceMode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: AppearanceStore.key) ?? "") ?? .dark {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.key)
            apply()
        }
    }

    /// Snapshots draw both looks without changing the saved choice.
    var override: AppearanceMode?
    var effective: AppearanceMode { override ?? mode }

    /// Light or dark as drawn now, with System read from macOS. For views inside a window that stays dark.
    var resolvedScheme: ColorScheme {
        effective.colorScheme ?? (NSApp?.effectiveAppearance.isDark ?? true ? .dark : .light)
    }

    /// Sets the appearance of every window, the menu bar popover included. Windows that must stay dark,
    /// such as the notch, set their own.
    func apply() {
        switch effective {
        case .system: NSApp?.appearance = nil
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        }
    }
}

extension View {
    /// The appearance chosen in settings, for a window's root view.
    func dyskAppearance() -> some View { modifier(DyskAppearance()) }
}

private struct DyskAppearance: ViewModifier {
    func body(content: Content) -> some View {
        content.preferredColorScheme(AppearanceStore.shared.effective.colorScheme)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension Color {
    /// A colour with a value for dark and one for light, resolved against the drawing view's appearance.
    init(dark: UInt32, darkAlpha: CGFloat = 1, light: UInt32, lightAlpha: CGFloat = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
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
            Theme.background
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
            Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text(color))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }
}

/// Settings use a switch instead of a checkbox: the label on the left and a small mint switch on the right.
/// With `fills` off, the switch sits right after the label, for toolbars.
struct DyskSwitchStyle: ToggleStyle {
    var fills = true

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
            if fills { Spacer(minLength: 12) }
            Toggle("", isOn: configuration.$isOn)
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.mint)
        }
        .contentShape(Rectangle())
    }
}

extension ToggleStyle where Self == DyskSwitchStyle {
    static var dyskSwitch: DyskSwitchStyle { DyskSwitchStyle() }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .bold))
            .foregroundStyle(Theme.onAccent)
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
            .foregroundStyle(Theme.text(tint))
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

    /// Made once: a formatter per call showed up while the battery and transfer views redraw.
    private static let rateFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func rate(_ bytesPerSecond: Int64) -> String {
        rateFormatter.string(fromByteCount: bytesPerSecond) + "/s"
    }
}
