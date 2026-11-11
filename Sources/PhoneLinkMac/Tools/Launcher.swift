import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

// MARK: Calculator and units

/// Arithmetic with + - * / % ^ and brackets. It is a small parser of its own, because NSExpression can crash the
/// app on input it doesn't understand.
enum LauncherMath {
    static func evaluate(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty, cleaned.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/^%(")) != nil,
              cleaned.allSatisfy({ "0123456789.+-*/^%()".contains($0) }) else { return nil }
        var parser = Parser(chars: Array(cleaned))
        guard let value = parser.expression(), parser.index == parser.chars.count, value.isFinite else { return nil }
        return value
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 8
        formatter.minimumIntegerDigits = 1
        formatter.decimalSeparator = "."
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private struct Parser {
        let chars: [Character]
        var index = 0
        var depth = 0

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while index < chars.count, chars[index] == "+" || chars[index] == "-" {
                let op = chars[index]; index += 1
                guard let right = term() else { return nil }
                value = op == "+" ? value + right : value - right
            }
            return value
        }

        mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while index < chars.count, "*/%".contains(chars[index]) {
                let op = chars[index]; index += 1
                guard let right = power() else { return nil }
                switch op {
                case "*": value *= right
                case "/": guard right != 0 else { return nil }; value /= right
                default: guard right != 0 else { return nil }; value = value.truncatingRemainder(dividingBy: right)
                }
            }
            return value
        }

        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if index < chars.count, chars[index] == "^" {
                index += 1
                guard let exponent = power() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        mutating func unary() -> Double? {
            if index < chars.count, chars[index] == "-" { index += 1; return unary().map { -$0 } }
            if index < chars.count, chars[index] == "+" { index += 1; return unary() }
            return primary()
        }

        mutating func primary() -> Double? {
            guard index < chars.count else { return nil }
            if chars[index] == "(" {
                depth += 1
                guard depth < 50 else { return nil }
                index += 1
                let value = expression()
                guard index < chars.count, chars[index] == ")" else { return nil }
                index += 1
                depth -= 1
                return value
            }
            let start = index
            while index < chars.count, chars[index].isNumber || chars[index] == "." { index += 1 }
            return Double(String(chars[start..<index]))
        }
    }
}

/// "10 km to mi", "70 f in c", "2.5 kg ke lb".
enum LauncherUnits {
    private static let units: [String: Dimension] = [
        "mm": UnitLength.millimeters, "cm": UnitLength.centimeters, "m": UnitLength.meters, "km": UnitLength.kilometers,
        "in": UnitLength.inches, "inch": UnitLength.inches, "ft": UnitLength.feet, "yd": UnitLength.yards,
        "mi": UnitLength.miles, "mile": UnitLength.miles, "miles": UnitLength.miles,
        "mg": UnitMass.milligrams, "g": UnitMass.grams, "kg": UnitMass.kilograms, "lb": UnitMass.pounds,
        "lbs": UnitMass.pounds, "oz": UnitMass.ounces, "ton": UnitMass.metricTons,
        "c": UnitTemperature.celsius, "°c": UnitTemperature.celsius, "f": UnitTemperature.fahrenheit,
        "°f": UnitTemperature.fahrenheit, "k": UnitTemperature.kelvin,
        "ml": UnitVolume.milliliters, "l": UnitVolume.liters, "gal": UnitVolume.gallons, "cup": UnitVolume.cups,
        "kmh": UnitSpeed.kilometersPerHour, "km/h": UnitSpeed.kilometersPerHour, "mph": UnitSpeed.milesPerHour,
        "m/s": UnitSpeed.metersPerSecond,
        "b": UnitInformationStorage.bytes, "kb": UnitInformationStorage.kilobytes, "mb": UnitInformationStorage.megabytes,
        "gb": UnitInformationStorage.gigabytes, "tb": UnitInformationStorage.terabytes,
    ]

    static func convert(_ text: String) -> String? {
        let pattern = #"^\s*(-?[\d.,]+)\s*([a-z°/]+)\s+(?:to|in|ke)\s+([a-z°/]+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text), let fromRange = Range(match.range(at: 2), in: text),
              let toRange = Range(match.range(at: 3), in: text),
              let value = Double(text[numberRange].replacingOccurrences(of: ",", with: ".")),
              let from = units[text[fromRange].lowercased()], let to = units[text[toRange].lowercased()],
              type(of: from) == type(of: to)
        else { return nil }
        let result = Measurement(value: value, unit: from).converted(to: to).value
        return "\(LauncherMath.format((result * 10000).rounded() / 10000)) \(text[toRange])"
    }
}

/// How well a name fits what was typed: the start of the name, the start of a word, then anywhere.
enum LauncherScore {
    static func score(_ name: String, _ query: String) -> Int? {
        let name = name.lowercased(), query = query.lowercased()
        guard !query.isEmpty else { return nil }
        if name == query { return 100 }
        if name.hasPrefix(query) { return 80 }
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." })
        if words.contains(where: { $0.hasPrefix(query) }) { return 60 }
        // Initials, like "vsc" for Visual Studio Code.
        if query.count >= 2, String(words.compactMap(\.first)).hasPrefix(query) { return 55 }
        if name.contains(query) { return 40 }
        return nil
    }
}

/// Web searches and addresses typed in the Launcher, like Spotlight's "Search the web".
enum LauncherWeb {
    struct Engine {
        let prefix: String
        let name: String
        let url: String
    }

    static let engines: [Engine] = [
        Engine(prefix: "g", name: "Google", url: "https://www.google.com/search?q="),
        Engine(prefix: "yt", name: "YouTube", url: "https://www.youtube.com/results?search_query="),
        Engine(prefix: "w", name: "Wikipedia", url: "https://id.wikipedia.org/w/index.php?search="),
        Engine(prefix: "gh", name: "GitHub", url: "https://github.com/search?q="),
        Engine(prefix: "maps", name: "Google Maps", url: "https://www.google.com/maps/search/"),
        Engine(prefix: "ddg", name: "DuckDuckGo", url: "https://duckduckgo.com/?q="),
    ]

    /// "yt lofi" searches YouTube, anything else searches Google. A prefix only counts when words follow it.
    static func search(_ query: String) -> (name: String, terms: String, url: URL)? {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var engine = engines[0]
        var terms = text
        if let space = text.firstIndex(of: " "),
           let match = engines.first(where: { $0.prefix == text[..<space].lowercased() }) {
            let rest = text[space...].trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty {
                engine = match
                terms = rest
            }
        }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let encoded = terms.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: engine.url + encoded) else { return nil }
        return (engine.name, terms, url)
    }

    /// "github.com", "example.co.id/path", or a full http(s) link, opened directly. Anything with a space isn't an address.
    static func address(_ query: String) -> URL? {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains(" "), text.count <= 2_000 else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: text), url.host != nil else { return nil }
            return url
        }
        let host = String(lower.split(separator: "/", maxSplits: 1).first ?? "")
        let labels = host.split(separator: ".")
        guard labels.count >= 2, let last = labels.last, last.count >= 2, last.allSatisfy(\.isLetter),
              labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }),
              !fileEndings.contains(String(last)) else { return nil }
        return URL(string: "https://" + text)
    }

    /// Endings that are far more likely file names than websites.
    private static let fileEndings: Set<String> = [
        "txt", "pdf", "png", "jpg", "jpeg", "gif", "doc", "docx", "xls", "xlsx", "csv", "zip", "md", "json", "swift", "kt", "py", "js", "html", "mov", "mp4", "mp3",
    ]
}

// MARK: Prefixes

enum LauncherSearch {
    /// "f report" looks for files and folders, "d report" for folders only.
    static func scoped(_ query: String) -> (terms: String, folders: Bool)? {
        let lower = query.lowercased()
        for (prefix, folders) in [("f ", false), ("d ", true)] where lower.hasPrefix(prefix) {
            let rest = query.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : (rest, folders)
        }
        return nil
    }

    /// The words after ":" or "e ", when the query looks for emoji. Empty shows recent ones.
    static func emojiTerms(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(":") { return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if query.lowercased().hasPrefix("e ") { return String(query.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        if trimmed.lowercased() == "emoji" { return "" }
        return nil
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: Results

struct LauncherItem: Identifiable {
    enum Kind: String { case answer = "Answer", command = "DyskLink", app = "App", window = "Window", clip = "Clipboard", file = "File", folder = "Folder", web = "Web", emoji = "Emoji", setting = "Settings" }

    let id: String
    let kind: Kind
    let title: String
    var subtitle: String = ""
    var icon: NSImage?
    var symbol: String = "magnifyingglass"
    /// Drawn large in place of an icon.
    var emoji: String?
    /// More words that find it, not shown.
    var keywords = ""
    var score = 0
    let run: () -> Void
}

@MainActor
@Observable
final class LauncherState {
    var query = ""
    var selection = 0
    var items: [LauncherItem] = []
    var files: [LauncherItem] = []
    var web: [LauncherItem] = []
    var all: [LauncherItem] { items + files + web }
}

// MARK: Panel

private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A search box in the middle of the screen for apps, files, windows, copies, sums, units, and DyskLink actions.
/// Files come from the Spotlight index, so it finds what Spotlight finds.
@MainActor
enum Launcher {
    private static var panel: NSPanel?
    private static var keyMonitor: Any?
    private static var resignObserver: NSObjectProtocol?
    private static let state = LauncherState()
    private static var apps: [URL] = []
    private static var windows: [WindowItem] = []
    private static var fileQuery: NSMetadataQuery?
    private static var fileObserver: NSObjectProtocol?
    private static var fileWork: DispatchWorkItem?

    static func toggle() {
        if panel != nil { close() } else { show() }
    }

    static func show() {
        state.query = ""
        state.selection = 0
        state.files = []
        if apps.isEmpty { apps = findApps() }
        windows = DeviceInput.isTrusted ? WindowCatalog.allWindows(limit: 40) : []
        refresh()
        let size = NSSize(width: 640, height: 452)
        let panel = LauncherPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: LauncherView(state: state, onRun: run))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2 + 80))
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) ? nil : event }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { close() }
        }
    }

    static func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        stopFileSearch()
        panel?.orderOut(nil)
        panel = nil
        windows = []
    }

    private static func run(_ item: LauncherItem) {
        close()
        // The app in front needs a moment to take the keyboard back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { item.run() }
    }

    private static func handle(_ event: NSEvent) -> Bool {
        let list = state.all
        switch Int(event.keyCode) {
        case kVK_Escape: close()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if list.indices.contains(state.selection) { run(list[state.selection]) }
        case kVK_UpArrow: state.selection = max(state.selection - 1, 0)
        case kVK_DownArrow: state.selection = min(state.selection + 1, max(list.count - 1, 0))
        case kVK_Delete:
            if event.modifierFlags.contains(.command) { state.query = "" } else if !state.query.isEmpty { state.query.removeLast() }
            changed()
        default:
            if event.modifierFlags.contains(.command) {
                if event.charactersIgnoringModifiers == "v", let pasted = NSPasteboard.general.string(forType: .string) {
                    state.query += pasted.components(separatedBy: .newlines).first ?? ""
                    changed()
                }
            } else if !event.modifierFlags.contains(.control), let typed = event.characters,
                      let first = typed.unicodeScalars.first, first.value >= 32, first.value != 127, state.query.count < 200 {
                state.query += typed
                changed()
            }
        }
        return true
    }

    private static func changed() {
        state.selection = 0
        refresh()
        searchFiles()
    }

    // MARK: Building the list

    private static func refresh() {
        let query = state.query.trimmingCharacters(in: .whitespaces)
        var answers: [LauncherItem] = []
        if let value = LauncherMath.evaluate(query) {
            let text = LauncherMath.format(value)
            answers.append(LauncherItem(id: "calc", kind: .answer, title: text, subtitle: "Press Return to copy", symbol: "equal.circle.fill") {
                copy(text)
            })
        }
        if let converted = LauncherUnits.convert(query) {
            answers.append(LauncherItem(id: "unit", kind: .answer, title: converted, subtitle: "Press Return to copy", symbol: "arrow.left.arrow.right.circle.fill") {
                copy(converted.components(separatedBy: " ").first ?? converted)
            })
        }
        if let terms = LauncherSearch.emojiTerms(query) {
            state.web = []
            state.items = emojiItems(terms)
            return
        }
        state.web = webItems(query)
        guard !query.isEmpty else {
            state.items = commands().prefix(6).map { $0 }
            return
        }
        // "f report" searches only files and "d report" only folders, like narrowing Spotlight.
        if LauncherSearch.scoped(query) != nil {
            state.items = []
            return
        }
        var ranked: [LauncherItem] = []
        for var item in commands() + appItems() + windowItems() + settingItems() {
            guard let score = LauncherScore.score(item.title, query)
                    ?? (item.subtitle.isEmpty ? nil : LauncherScore.score(item.subtitle, query).map { $0 - 25 })
                    ?? keywordScore(item.keywords, query) else { continue }
            item.score = score + (item.kind == .app ? 5 : 0)
            ranked.append(item)
        }
        ranked.sort { $0.score == $1.score ? $0.title.count < $1.title.count : $0.score > $1.score }
        state.items = answers + ranked.prefix(8) + clipItems(query)
    }

    private static func emojiItems(_ query: String) -> [LauncherItem] {
        let (terms, typedTone) = LauncherEmoji.splitTone(query)
        if let typedTone { LauncherEmoji.tone = typedTone }
        let tone = LauncherEmoji.tone
        let toneHint = tone == 0 ? "" : " · tone \(tone), type kuning for plain"
        let entries: [LauncherEmoji.Entry]
        if terms.isEmpty {
            var seen = Set<String>()
            entries = (LauncherEmoji.recent + LauncherEmoji.starters).filter { seen.insert($0).inserted }.prefix(40).map(LauncherEmoji.entry(for:))
        } else {
            entries = LauncherEmoji.search(terms)
        }
        return entries.map { entry in
            let emoji = LauncherEmoji.toned(entry.emoji, tone)
            return LauncherItem(id: "emoji-\(emoji)", kind: .emoji, title: entry.name.isEmpty ? emoji : entry.name.capitalizedFirst,
                         subtitle: (DeviceInput.isTrusted ? "Return types it · ⌘ Return copies" : "Return copies it") + (emoji != entry.emoji ? toneHint : ""),
                         emoji: emoji) {
                // Recent ones are kept plain, so a later tone still applies to them.
                LauncherEmoji.used(entry.emoji)
                if DeviceInput.isTrusted && !NSEvent.modifierFlags.contains(.command) {
                    typeText(emoji)
                } else {
                    copy(emoji)
                }
            }
        }
    }

    /// Types into the app in front, like the keyboard would.
    private static func typeText(_ text: String) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            let units = Array(text.utf16)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func webItems(_ query: String) -> [LauncherItem] {
        guard !query.isEmpty, LauncherSearch.scoped(query) == nil else { return [] }
        var result: [LauncherItem] = []
        if let url = LauncherWeb.address(query) {
            result.append(LauncherItem(id: "web-open", kind: .web, title: "Open \(url.host ?? query)", subtitle: url.absoluteString, symbol: "safari.fill") {
                NSWorkspace.shared.open(url)
            })
        }
        if let search = LauncherWeb.search(query) {
            result.append(LauncherItem(id: "web-search", kind: .web, title: "Search \(search.name) for \"\(search.terms)\"", subtitle: "Opens in your browser", symbol: "globe") {
                NSWorkspace.shared.open(search.url)
            })
        }
        return result
    }

    private static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        HintToast.show("Copied \(text)")
    }

    private static func commands() -> [LauncherItem] {
        let tools = Shared.tools
        var result: [LauncherItem] = []
        if tools.isAwakeOn {
            let active = tools.awake.isActive
            result.append(LauncherItem(id: "awake", kind: .command, title: active ? "Stop Keep Awake" : "Start Keep Awake",
                                       subtitle: "Keep this Mac awake", symbol: "cup.and.saucer.fill") {
                if active { tools.awake.stop() } else if tools.awake.canStart { tools.awake.start() }
            })
        }
        let pomodoro = tools.notch.model.pomodoro
        result.append(LauncherItem(id: "pomodoro", kind: .command, title: pomodoro.isRunning ? "Pause Pomodoro" : "Start Pomodoro",
                                   subtitle: "Focus timer", symbol: "timer") { tools.notch.model.togglePomodoro() })
        if tools.isLayoutOn {
            for layout in tools.layout.layouts {
                result.append(LauncherItem(id: "layout-\(layout.id)", kind: .command, title: "Restore \(layout.name)",
                                           subtitle: "Window layout", symbol: "rectangle.split.3x1") { tools.layout.restore(layout) })
            }
            result.append(LauncherItem(id: "grid", kind: .command, title: "Arrange windows in a grid",
                                       subtitle: "Window layout", symbol: "square.grid.2x2") { tools.layout.arrangeGrid() })
        }
        if tools.isClipboardOn {
            result.append(LauncherItem(id: "clipboard", kind: .command, title: "Clipboard History",
                                       subtitle: "Everything you copied", symbol: "doc.on.clipboard") { ClipboardPanel.show(tools.clipboard) })
        }
        for phone in Shared.model.peers where phone.isPaired && phone.isConnected {
            result.append(LauncherItem(id: "send-\(phone.id)", kind: .command, title: "Send files to \(phone.name)",
                                       subtitle: "Phone", symbol: "arrow.up.doc") {
                MainWindow.show()
                Shared.model.pickFiles(for: phone.id)
            })
            result.append(LauncherItem(id: "ring-\(phone.id)", kind: .command, title: "Ring \(phone.name)",
                                       subtitle: "Find phone", symbol: "speaker.wave.3") { Shared.model.ringPhone(phone.id, true) })
        }
        result.append(LauncherItem(id: "lock", kind: .command, title: "Lock screen", subtitle: "This Mac", symbol: "lock") {
            MacActions.lockScreen()
        })
        result.append(LauncherItem(id: "open", kind: .command, title: "Open DyskLink", subtitle: "Main window", symbol: "macwindow") {
            MainWindow.show()
        })
        return result
    }

    /// System Settings pages and DyskLink's own settings.
    private static func settingItems() -> [LauncherItem] {
        LauncherSettings.all.map { entry in
            LauncherItem(id: "setting-\(entry.id)", kind: .setting, title: entry.title,
                         subtitle: entry.pane == nil ? "DyskLink" : "System Settings",
                         symbol: entry.symbol, keywords: entry.words) {
                LauncherSettings.open(entry)
            }
        }
    }

    /// A match on one of the extra words, ranked under a match on the title.
    private static func keywordScore(_ keywords: String, _ query: String) -> Int? {
        guard !keywords.isEmpty else { return nil }
        let best = keywords.split(separator: " ").compactMap { LauncherScore.score(String($0), query) }.max()
        return best.map { $0 - 30 }
    }

    private static func appItems() -> [LauncherItem] {
        apps.map { url in
            let name = url.deletingPathExtension().lastPathComponent
            return LauncherItem(id: url.path, kind: .app, title: name, subtitle: url.deletingLastPathComponent().path,
                                icon: NSWorkspace.shared.icon(forFile: url.path)) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    private static func windowItems() -> [LauncherItem] {
        windows.map { window in
            LauncherItem(id: "window-\(window.id)", kind: .window, title: window.title.isEmpty ? window.appName : window.title,
                         subtitle: window.appName, icon: window.icon) { WindowCatalog.focus(window) }
        }
    }

    private static func clipItems(_ query: String) -> [LauncherItem] {
        guard Shared.tools.isClipboardOn, query.count >= 2 else { return [] }
        let history = Shared.tools.clipboard
        return history.matches(query).filter { $0.text != nil }.prefix(3).map { entry in
            let text = entry.text ?? ""
            return LauncherItem(id: "clip-\(entry.id)", kind: .clip,
                                title: text.components(separatedBy: .newlines).first.map { String($0.prefix(80)) } ?? "",
                                subtitle: entry.date.formatted(date: .abbreviated, time: .shortened), symbol: "doc.on.clipboard") {
                history.copy(entry)
                HintToast.show("Copied")
            }
        }
    }

    /// Applications folders, one level of subfolders deep, like Utilities.
    private static func findApps() -> [URL] {
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var seen = Set<String>(), result: [URL] = []
        for root in roots {
            for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let url = URL(fileURLWithPath: root).appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    if seen.insert(name).inserted { result.append(url) }
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    for inner in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] where inner.hasSuffix(".app") {
                        if seen.insert(inner).inserted { result.append(url.appendingPathComponent(inner)) }
                    }
                }
            }
        }
        return result
    }

    // MARK: Files

    private static func searchFiles() {
        fileWork?.cancel()
        stopFileSearch()
        state.files = []
        let typed = state.query.trimmingCharacters(in: .whitespaces)
        if LauncherSearch.emojiTerms(typed) != nil { return }
        let scope = LauncherSearch.scoped(typed)
        let query = scope?.terms ?? typed
        guard query.count >= 2, LauncherMath.evaluate(query) == nil else { return }
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { startFileSearch(query, limit: scope == nil ? 6 : 20, foldersOnly: scope?.folders == true) }
        }
        fileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private static func startFileSearch(_ text: String, limit: Int, foldersOnly: Bool = false) {
        let search = NSMetadataQuery()
        search.searchScopes = [NSMetadataQueryUserHomeScope]
        // Names and the text inside documents, like Spotlight. Name matches are moved to the top below.
        search.predicate = foldersOnly
            ? NSPredicate(format: "(%K CONTAINS[cd] %@) AND (kMDItemContentType == 'public.folder')", NSMetadataItemFSNameKey, text)
            : NSPredicate(format: "(%K CONTAINS[cd] %@) OR (kMDItemTextContent CONTAINS[cd] %@)", NSMetadataItemFSNameKey, text, text)
        search.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        fileObserver = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: search, queue: .main) { _ in
            MainActor.assumeIsolated {
                search.disableUpdates()
                let paths = (0..<min(search.resultCount, 200)).compactMap { index in
                    (search.result(at: index) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String
                }
                // Already newest first. Files whose name matches come before files that only mention the words.
                let byName = paths.filter { ($0 as NSString).lastPathComponent.localizedCaseInsensitiveContains(text) }
                let byContent = paths.filter { !($0 as NSString).lastPathComponent.localizedCaseInsensitiveContains(text) }
                state.files = (byName + byContent).prefix(limit).map { path in
                    let url = URL(fileURLWithPath: path)
                    let inside = !url.lastPathComponent.localizedCaseInsensitiveContains(text)
                    let folder = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                    var isFolder: ObjCBool = false
                    FileManager.default.fileExists(atPath: path, isDirectory: &isFolder)
                    // App bundles and other packages are folders on disk but open like files.
                    let opensAsFolder = isFolder.boolValue && !NSWorkspace.shared.isFilePackage(atPath: path)
                    return LauncherItem(id: "file-\(path)", kind: opensAsFolder ? .folder : .file, title: url.lastPathComponent,
                                        subtitle: inside ? "Contains \"\(text)\" · \(folder)" : folder,
                                        icon: NSWorkspace.shared.icon(forFile: path)) {
                        if NSEvent.modifierFlags.contains(.command) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                search.stop()
            }
        }
        fileQuery = search
        search.start()
    }

    private static func stopFileSearch() {
        fileQuery?.stop()
        fileQuery = nil
        if let fileObserver { NotificationCenter.default.removeObserver(fileObserver) }
        fileObserver = nil
    }
}

struct LauncherView: View {
    let state: LauncherState
    let onRun: (LauncherItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.textSecondary)
                Text(state.query.isEmpty ? "Search apps, files, folders, or type a sum · :emoji" : state.query + "▏")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(state.query.isEmpty ? Theme.textFaint : Theme.textPrimary)
                    .lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).frame(height: 62)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            let list = state.all
            if list.isEmpty {
                Text(state.query.isEmpty ? "" : "No results").font(.system(size: 13)).foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                                row(item, selected: index == state.selection).id(index)
                                    .onTapGesture { onRun(item) }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: state.selection) { _, new in proxy.scrollTo(new) }
                }
            }
            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack {
                Text(LauncherSearch.emojiTerms(state.query) != nil ? "↑↓ to choose · Return to type · ⌘ Return to copy · Esc to close"
                     : "↑↓ to choose · Return to open · ⌘ Return to show in Finder · f files · d folders · e emoji")
                    .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 30)
        }
        .frame(width: 640, height: 452)
        .background(Theme.panel.opacity(0.97), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.stroke))
        .preferredColorScheme(.dark)
    }

    private func row(_ item: LauncherItem, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Group {
                if let emoji = item.emoji {
                    Text(emoji).font(.system(size: 22))
                } else if let icon = item.icon {
                    Image(nsImage: icon).resizable().frame(width: 26, height: 26)
                } else {
                    Image(systemName: item.symbol).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(item.kind == .answer ? Theme.mint : Theme.textSecondary)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: item.kind == .answer ? 17 : 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(item.kind.rawValue).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? Theme.panelRaised : Color.clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(selected ? Theme.mint.opacity(0.4) : Color.clear))
        .contentShape(Rectangle())
    }
}
