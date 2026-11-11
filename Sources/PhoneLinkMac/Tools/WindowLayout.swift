import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Observation

/// Where a window goes, as a fraction of the screen's usable area.
enum WindowSpot: String, CaseIterable, Identifiable, Codable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize, center

    var id: String { rawValue }

    var label: String {
        switch self {
        case .leftHalf: return "Left half"
        case .rightHalf: return "Right half"
        case .topHalf: return "Top half"
        case .bottomHalf: return "Bottom half"
        case .leftThird: return "Left third"
        case .centerThird: return "Center third"
        case .rightThird: return "Right third"
        case .leftTwoThirds: return "Left two thirds"
        case .rightTwoThirds: return "Right two thirds"
        case .topLeft: return "Top left quarter"
        case .topRight: return "Top right quarter"
        case .bottomLeft: return "Bottom left quarter"
        case .bottomRight: return "Bottom right quarter"
        case .maximize: return "Fill the screen"
        case .center: return "Center"
        }
    }

    /// Control + Option and a key, like Rectangle's defaults.
    var key: (code: UInt32, name: String) {
        switch self {
        case .leftHalf: return (UInt32(kVK_LeftArrow), "←")
        case .rightHalf: return (UInt32(kVK_RightArrow), "→")
        case .topHalf: return (UInt32(kVK_UpArrow), "↑")
        case .bottomHalf: return (UInt32(kVK_DownArrow), "↓")
        case .leftThird: return (UInt32(kVK_ANSI_D), "D")
        case .centerThird: return (UInt32(kVK_ANSI_F), "F")
        case .rightThird: return (UInt32(kVK_ANSI_G), "G")
        case .leftTwoThirds: return (UInt32(kVK_ANSI_E), "E")
        case .rightTwoThirds: return (UInt32(kVK_ANSI_T), "T")
        case .topLeft: return (UInt32(kVK_ANSI_U), "U")
        case .topRight: return (UInt32(kVK_ANSI_I), "I")
        case .bottomLeft: return (UInt32(kVK_ANSI_J), "J")
        case .bottomRight: return (UInt32(kVK_ANSI_K), "K")
        case .maximize: return (UInt32(kVK_Return), "Return")
        case .center: return (UInt32(kVK_ANSI_C), "C")
        }
    }

    /// The rectangle inside `area`, in the same top-left coordinates the Accessibility API uses.
    func frame(in area: CGRect, current: CGSize) -> CGRect {
        let w = area.width, h = area.height, x = area.minX, y = area.minY
        func rect(_ fx: CGFloat, _ fy: CGFloat, _ fw: CGFloat, _ fh: CGFloat) -> CGRect {
            CGRect(x: x + w * fx, y: y + h * fy, width: w * fw, height: h * fh).integral
        }
        switch self {
        case .leftHalf: return rect(0, 0, 0.5, 1)
        case .rightHalf: return rect(0.5, 0, 0.5, 1)
        case .topHalf: return rect(0, 0, 1, 0.5)
        case .bottomHalf: return rect(0, 0.5, 1, 0.5)
        case .leftThird: return rect(0, 0, 1.0 / 3, 1)
        case .centerThird: return rect(1.0 / 3, 0, 1.0 / 3, 1)
        case .rightThird: return rect(2.0 / 3, 0, 1.0 / 3, 1)
        case .leftTwoThirds: return rect(0, 0, 2.0 / 3, 1)
        case .rightTwoThirds: return rect(1.0 / 3, 0, 2.0 / 3, 1)
        case .topLeft: return rect(0, 0, 0.5, 0.5)
        case .topRight: return rect(0.5, 0, 0.5, 0.5)
        case .bottomLeft: return rect(0, 0.5, 0.5, 0.5)
        case .bottomRight: return rect(0.5, 0.5, 0.5, 0.5)
        case .maximize: return area.integral
        case .center:
            let size = CGSize(width: min(current.width, w), height: min(current.height, h))
            return CGRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                          width: size.width.rounded(), height: size.height.rounded())
        }
    }

    /// Rows and columns for `count` windows: as square as possible, wider than tall.
    static func grid(count: Int, in area: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        let columns = Int(Double(count).squareRoot().rounded(.up))
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        return (0..<count).map { index in
            let row = index / columns
            // The last row spreads its windows across the full width.
            let inRow = row == rows - 1 ? count - row * columns : columns
            let column = index % columns
            let width = area.width / CGFloat(inRow)
            let height = area.height / CGFloat(rows)
            return CGRect(x: area.minX + width * CGFloat(column), y: area.minY + height * CGFloat(row),
                          width: width, height: height).integral
        }
    }
}

/// One window's place in a saved layout.
struct SavedWindow: Codable, Equatable {
    var bundleID: String
    var title: String
    var frame: CGRect
}

struct SavedLayout: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var windows: [SavedWindow]
}

/// Moves and resizes the front window with shortcuts, and saves and restores whole layouts.
/// Needs Accessibility, which the other window tools already use.
@MainActor
@Observable
final class WindowLayout {
    private(set) var layouts: [SavedLayout] = []
    private(set) var shortcutProblem: String?
    var draftName = ""

    @ObservationIgnored private let file: URL
    /// Called after layouts are added, renamed, or deleted.
    @ObservationIgnored var onChange: (() -> Void)?

    static let commandPrefix = "layout:"

    /// Each layout as a command the phone can run, for example from a Stream Deck button.
    var commands: [CommandItem] {
        layouts.map { CommandItem(id: Self.commandPrefix + $0.id.uuidString, name: "Restore layout: \($0.name)") }
    }

    /// Restores the layout a command names. Nil when it isn't a layout command.
    func runCommand(_ id: String) -> String? {
        guard id.hasPrefix(Self.commandPrefix) else { return nil }
        guard let layout = layouts.first(where: { Self.commandPrefix + $0.id.uuidString == id }) else { return "That layout was deleted." }
        restore(layout)
        return "Restored \(layout.name)."
    }
    @ObservationIgnored private var isOn = false
    private static let firstHotKey: UInt32 = 100
    private static let modifiers = UInt32(controlKey | optionKey)

    init(directory: URL) {
        file = directory.appendingPathComponent("window-layouts.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([SavedLayout].self, from: data) {
            layouts = saved
        }
    }

    func start() {
        guard !isOn else { return }
        isOn = true
        var failed: [String] = []
        for (index, spot) in WindowSpot.allCases.enumerated() {
            if !HotKeys.register(id: Self.firstHotKey + UInt32(index), keyCode: spot.key.code, modifiers: Self.modifiers, action: { [weak self] in
                self?.move(to: spot)
            }) { failed.append(spot.key.name) }
        }
        let withCommand = UInt32(controlKey | optionKey | cmdKey), withShift = UInt32(controlKey | optionKey | shiftKey)
        let extra: [(id: UInt32, key: UInt32, modifiers: UInt32, name: String, action: () -> Void)] = [
            (50, UInt32(kVK_RightArrow), withCommand, "Command + →", { [weak self] in self?.moveToNextScreen(step: 1) }),
            (51, UInt32(kVK_LeftArrow), withCommand, "Command + ←", { [weak self] in self?.moveToNextScreen(step: -1) }),
            (52, UInt32(kVK_ANSI_G), withShift, "Shift + G", { [weak self] in self?.arrangeGrid() }),
        ]
        for item in extra where !HotKeys.register(id: Self.firstHotKey + item.id, keyCode: item.key, modifiers: item.modifiers, action: item.action) {
            failed.append(item.name)
        }
        shortcutProblem = failed.isEmpty ? nil : "Another app already uses Control + Option + \(failed.joined(separator: ", ")), so those don't work here."
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        for index in 0..<WindowSpot.allCases.count { HotKeys.remove(id: Self.firstHotKey + UInt32(index)) }
        for offset in [50, 51, 52] as [UInt32] { HotKeys.remove(id: Self.firstHotKey + offset) }
        shortcutProblem = nil
    }

    // MARK: Moving

    func move(to spot: WindowSpot) {
        guard let window = Self.frontWindow(), let current = Self.frame(of: window) else { return NSSound.beep() }
        let screen = Self.screen(containing: current)
        Self.set(window, frame: spot.frame(in: Self.usableArea(of: screen), current: current.size))
    }

    func moveToNextScreen(step: Int) {
        let screens = NSScreen.screens
        guard screens.count > 1, let window = Self.frontWindow(), let current = Self.frame(of: window) else { return }
        let from = Self.screen(containing: current)
        let index = screens.firstIndex(of: from) ?? 0
        let target = screens[(index + step + screens.count) % screens.count]
        let fromArea = Self.usableArea(of: from), toArea = Self.usableArea(of: target)
        // Keeps the same place and share of the screen on the other display.
        let fx = (current.minX - fromArea.minX) / fromArea.width, fy = (current.minY - fromArea.minY) / fromArea.height
        let fw = min(current.width / fromArea.width, 1), fh = min(current.height / fromArea.height, 1)
        Self.set(window, frame: CGRect(x: toArea.minX + fx * toArea.width, y: toArea.minY + fy * toArea.height,
                                       width: fw * toArea.width, height: fh * toArea.height).integral)
    }

    /// Puts every visible window on the front window's screen into a grid.
    func arrangeGrid() {
        let front = Self.frontWindow().flatMap(Self.frame(of:))
        let screen = front.map(Self.screen(containing:)) ?? NSScreen.main ?? NSScreen.screens[0]
        let area = Self.usableArea(of: screen)
        let windows = Self.visibleWindows().filter { item in
            guard let frame = Self.frame(of: item.element) else { return false }
            return Self.screen(containing: frame) == screen
        }
        for (window, frame) in zip(windows, WindowSpot.grid(count: windows.count, in: area)) {
            Self.set(window.element, frame: frame)
        }
    }

    // MARK: Saved layouts

    func saveCurrent() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let windows = Self.visibleWindows().compactMap { item -> SavedWindow? in
            guard let frame = Self.frame(of: item.element) else { return nil }
            return SavedWindow(bundleID: item.bundleID, title: item.title, frame: frame)
        }
        guard !windows.isEmpty else { return }
        layouts.append(SavedLayout(name: name.isEmpty ? "Layout \(layouts.count + 1)" : String(name.prefix(40)), windows: windows))
        draftName = ""
        save()
    }

    /// Each saved window goes back to its place. A window is matched by app and title, then by app alone.
    func restore(_ layout: SavedLayout) {
        var open = Self.visibleWindows()
        for saved in layout.windows {
            let index = open.firstIndex { $0.bundleID == saved.bundleID && $0.title == saved.title }
                ?? open.firstIndex { $0.bundleID == saved.bundleID }
            guard let index else { continue }
            Self.set(open.remove(at: index).element, frame: saved.frame)
        }
    }

    func delete(_ layout: SavedLayout) {
        layouts.removeAll { $0.id == layout.id }
        save()
    }

    private func save() {
        onChange?()
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(layouts) { try? data.write(to: file, options: .atomic) }
    }

    // MARK: Accessibility

    private struct OpenWindow {
        let element: AXUIElement
        let bundleID: String
        let title: String
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func frontWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        return attribute(element, kAXFocusedWindowAttribute) ?? attribute(element, kAXMainWindowAttribute)
    }

    /// Standard windows of regular apps that aren't minimized, front to back as macOS lists apps.
    private static func visibleWindows() -> [OpenWindow] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isHidden }.flatMap { app -> [OpenWindow] in
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.25)
            let windows: [AXUIElement] = attribute(element, kAXWindowsAttribute) ?? []
            return windows.compactMap { window in
                guard (attribute(window, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole as String,
                      (attribute(window, kAXMinimizedAttribute) as Bool?) != true else { return nil }
                return OpenWindow(element: window, bundleID: app.bundleIdentifier ?? "", title: attribute(window, kAXTitleAttribute) ?? "")
            }
        }
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = attribute(window, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(window, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(positionValue, .cgPoint, &position)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    /// Size, then position, then size again, because some apps limit the size to what fits where the window is.
    private static func set(_ window: AXUIElement, frame: CGRect) {
        var origin = frame.origin, size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let length = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, length)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, length)
    }

    /// The Accessibility API puts the origin at the top left of the main screen, and AppKit at the bottom left.
    private static func flipped(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func usableArea(of screen: NSScreen) -> CGRect { flipped(screen.visibleFrame) }

    private static func screen(containing frame: CGRect) -> NSScreen {
        let screens = NSScreen.screens
        return screens.max { flipped($0.frame).intersection(frame).area < flipped($1.frame).intersection(frame).area }
            ?? NSScreen.main ?? screens[0]
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
