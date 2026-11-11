import AppKit
import Carbon.HIToolbox
import Observation

/// The optional tools on the Advanced page. Each one is off until the user turns it on,
/// and does no work while off.
@MainActor
@Observable
final class ToolsModel {
    let monitor = SystemMonitor()
    let awake = KeepAwake()
    let clipboard: ClipboardHistory
    let displays = DisplayControl()
    let mouse = MouseTuner()
    let previews = WindowPreviews()
    let layout: WindowLayout
    let notch: NotchController
    private(set) var shortcutProblem: String?

    enum ShortcutSlot { case history, capture }
    private(set) var recordingSlot: ShortcutSlot?
    var historyShortcut: KeyCombo {
        didSet { store(historyShortcut, "clipboard.historyShortcut"); applyClipboard() }
    }
    var captureShortcut: KeyCombo {
        didSet { store(captureShortcut, "clipboard.captureShortcut"); applyClipboard() }
    }
    @ObservationIgnored private var recordingMonitor: Any?

    /// Control + Option + 1 to 9 pastes that item of the history without opening the panel.
    var isQuickPasteOn: Bool {
        didSet { save(isQuickPasteOn, "clipboard.quickPaste"); applyClipboard() }
    }
    static let quickPasteFirstID: UInt32 = 10

    var isMonitorOn: Bool {
        didSet { save(isMonitorOn, "tool.monitor"); applyMonitor() }
    }
    var isAwakeOn: Bool {
        didSet { save(isAwakeOn, "tool.keepAwake"); if !isAwakeOn { awake.stop() } }
    }
    var isClipboardOn: Bool {
        didSet { save(isClipboardOn, "tool.clipboard"); applyClipboard() }
    }

    var isDisplaysOn: Bool {
        didSet { save(isDisplaysOn, "tool.displays"); applyDisplays() }
    }
    var isMouseOn: Bool {
        didSet { save(isMouseOn, "tool.mouse"); applyMouse() }
    }
    var isPreviewsOn: Bool {
        didSet { save(isPreviewsOn, "tool.previews"); applyPreviews() }
    }
    enum LauncherKey: String, CaseIterable, Identifiable {
        case optionSpace, controlSpace, commandSpace
        var id: String { rawValue }
        var label: String {
            switch self {
            case .optionSpace: return "Option + Space"
            case .controlSpace: return "Control + Space"
            case .commandSpace: return "Command + Space"
            }
        }
        var modifiers: UInt32 {
            switch self {
            case .optionSpace: return UInt32(optionKey)
            case .controlSpace: return UInt32(controlKey)
            case .commandSpace: return UInt32(cmdKey)
            }
        }
    }

    var isLauncherOn: Bool {
        didSet { save(isLauncherOn, "tool.launcher"); applyLauncher() }
    }
    var launcherKey: LauncherKey {
        didSet { if !isInert { UserDefaults.standard.set(launcherKey.rawValue, forKey: "launcher.key") }; applyLauncher() }
    }
    private(set) var launcherProblem: String?

    var isLayoutOn: Bool {
        didSet { save(isLayoutOn, "tool.layout"); applyLayout(); layout.onChange?() }
    }
    var isNotchOn: Bool {
        didSet { save(isNotchOn, "tool.notch"); applyNotch() }
    }

    /// Snapshots show the controls without touching the real mouse, monitors, or shortcuts.
    @ObservationIgnored private let isInert: Bool

    init(directory: URL = ToolsModel.defaultDirectory, isInert: Bool = false) {
        self.isInert = isInert
        clipboard = ClipboardHistory(directory: directory)
        notch = NotchController(directory: directory)
        layout = WindowLayout(directory: directory)
        let defaults = UserDefaults.standard
        historyShortcut = Self.loadCombo("clipboard.historyShortcut") ?? .historyDefault
        captureShortcut = Self.loadCombo("clipboard.captureShortcut") ?? .captureDefault
        isMonitorOn = defaults.bool(forKey: "tool.monitor")
        isAwakeOn = defaults.bool(forKey: "tool.keepAwake")
        isClipboardOn = defaults.bool(forKey: "tool.clipboard")
        isQuickPasteOn = defaults.bool(forKey: "clipboard.quickPaste")
        isDisplaysOn = defaults.bool(forKey: "tool.displays")
        isMouseOn = defaults.bool(forKey: "tool.mouse")
        isPreviewsOn = defaults.bool(forKey: "tool.previews")
        isNotchOn = defaults.bool(forKey: "tool.notch")
        isLayoutOn = defaults.bool(forKey: "tool.layout")
        isLauncherOn = defaults.bool(forKey: "tool.launcher")
        launcherKey = defaults.string(forKey: "launcher.key").flatMap(LauncherKey.init) ?? .optionSpace
    }

    func start() {
        applyMonitor()
        applyClipboard()
        applyDisplays()
        applyMouse()
        applyPreviews()
        applyNotch()
        applyLayout()
        applyLauncher()
    }

    private func applyLauncher() {
        guard !isInert else { return }
        HotKeys.remove(id: 3)
        launcherProblem = nil
        guard isLauncherOn else { return Launcher.close() }
        if !HotKeys.register(id: 3, keyCode: UInt32(kVK_Space), modifiers: launcherKey.modifiers, action: { Launcher.toggle() }) {
            launcherProblem = launcherKey == .commandSpace
                ? "Spotlight has Command + Space. Turn its shortcut off in System Settings > Keyboard > Keyboard Shortcuts > Spotlight, then choose this again."
                : "Another app already uses \(launcherKey.label). Choose a different one."
        }
    }

    private func applyLayout() {
        guard !isInert else { return }
        if isLayoutOn { layout.start() } else { layout.stop() }
    }

    /// Mouse settings outlive the app unless they are put back. Edits waiting to be saved are written now.
    func shutDown() {
        mouse.stop()
        guard !isInert else { return }
        clipboard.flush()
        notch.model.note.flush()
    }

    private func applyDisplays() {
        guard !isInert else { return }
        if isDisplaysOn { displays.start() } else { displays.stop() }
    }

    private func applyMouse() {
        guard !isInert else { return }
        if isMouseOn { mouse.start() } else { mouse.stop() }
    }

    private func applyPreviews() {
        guard !isInert else { return }
        if isPreviewsOn { previews.start() } else { previews.stop() }
    }

    private func applyNotch() {
        guard !isInert else { return }
        if isNotchOn { notch.start() } else { notch.stop() }
    }

    private func save(_ value: Bool, _ key: String) {
        guard !isInert else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    private func applyMonitor() {
        guard !isInert else { return }
        if isMonitorOn { monitor.start() } else { monitor.stop() }
    }

    private func applyClipboard() {
        guard !isInert else { return }
        guard isClipboardOn else {
            clipboard.stop()
            HotKeys.remove(id: 1)
            HotKeys.remove(id: 2)
            removeQuickPaste()
            ClipboardPanel.close()
            shortcutProblem = nil
            return
        }
        clipboard.start()
        let history = HotKeys.register(id: 1, keyCode: historyShortcut.keyCode, modifiers: historyShortcut.modifiers) {
            ClipboardPanel.toggle(Shared.tools.clipboard)
        }
        let capture = HotKeys.register(id: 2, keyCode: captureShortcut.keyCode, modifiers: captureShortcut.modifiers) {
            TextCapture.run(into: Shared.tools.clipboard)
        }
        shortcutProblem = history && capture ? nil : "Another app is using this shortcut. Choose a different one."
        removeQuickPaste()
        guard isQuickPasteOn else { return }
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        var taken: [String] = []
        for (index, key) in digits.enumerated() {
            let ok = HotKeys.register(id: Self.quickPasteFirstID + UInt32(index), keyCode: UInt32(key),
                                      modifiers: UInt32(controlKey | optionKey)) {
                let history = Shared.tools.clipboard
                let list = history.matches("")
                guard list.indices.contains(index) else { return NSSound.beep() }
                ClipboardPanel.paste(list[index], history)
            }
            if !ok { taken.append(String(index + 1)) }
        }
        if !taken.isEmpty {
            shortcutProblem = "Another app already uses Control + Option + \(taken.joined(separator: ", ")), so those don't paste."
        }
    }

    private func removeQuickPaste() {
        for index in 0..<9 { HotKeys.remove(id: Self.quickPasteFirstID + UInt32(index)) }
    }

    // MARK: Shortcut recording

    private static func loadCombo(_ key: String) -> KeyCombo? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
    }

    private func store(_ combo: KeyCombo, _ key: String) {
        guard !isInert else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(combo), forKey: key)
    }

    /// The window takes the next key press. The current shortcuts pause so pressing them doesn't run them.
    func startRecording(_ slot: ShortcutSlot) {
        cancelRecording()
        recordingSlot = slot
        shortcutProblem = nil
        HotKeys.remove(id: 1)
        HotKeys.remove(id: 2)
        removeQuickPaste()
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
            return nil
        }
    }

    func cancelRecording() {
        guard recordingSlot != nil else { return }
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        recordingSlot = nil
        applyClipboard()
    }

    private func record(_ event: NSEvent) {
        guard let slot = recordingSlot else { return }
        if event.keyCode == 53 { return cancelRecording() }
        let combo = KeyCombo(event: event)
        guard combo.isUsable else {
            shortcutProblem = "Include Command, Control, or Option, or use a function key."
            return
        }
        let other = slot == .history ? captureShortcut : historyShortcut
        guard combo != other else {
            shortcutProblem = "The other Clipboard History shortcut already uses \(combo.label)."
            return
        }
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        recordingSlot = nil
        if slot == .history { historyShortcut = combo } else { captureShortcut = combo }
    }

    func resetShortcuts() {
        cancelRecording()
        historyShortcut = .historyDefault
        captureShortcut = .captureDefault
    }

    nonisolated static var defaultDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["PHONELINK_DATA_DIR"] {
            return URL(fileURLWithPath: custom, isDirectory: true).appendingPathComponent("Tools", isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("DyskLink/Tools", isDirectory: true)
    }
}
