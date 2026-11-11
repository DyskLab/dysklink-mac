import Foundation

/// Which parts the DyskLink menu bar menu shows, and in what order. Set in Advanced.
@MainActor
@Observable
final class MenuBarLayout {
    enum Section: String, CaseIterable, Identifiable {
        case devices, batteryLimit, batteryStatus, powerFlow, energyApps, batteryLevel, batteryDetails, powerUse, displays, awake, layouts, clipboard, findPhone, sendFile, lock, pomodoro, weather, note, login
        var id: String { rawValue }

        var label: String {
            switch self {
            case .devices: "Devices and battery"
            case .batteryLimit: "Charge limit and Top Up"
            case .batteryStatus: "What's going on (charging)"
            case .powerFlow: "Where the power goes"
            case .energyApps: "Apps using energy"
            case .batteryLevel: "Battery level chart"
            case .batteryDetails: "Battery details"
            case .powerUse: "Power consumption chart"
            case .displays: "Brightness and volume"
            case .awake: "Keep Awake"
            case .layouts: "Window layouts"
            case .clipboard: "Recent copies"
            case .findPhone: "Ring phone"
            case .sendFile: "Send a file to the phone"
            case .lock: "Lock screen"
            case .pomodoro: "Pomodoro"
            case .weather: "Weather"
            case .note: "Quick note"
            case .login: "Open at login"
            }
        }

        var icon: String {
            switch self {
            case .devices: "iphone.gen3"
            case .batteryLimit: "battery.75percent"
            case .batteryStatus: "questionmark.bubble"
            case .powerFlow: "arrow.triangle.branch"
            case .energyApps: "flame"
            case .batteryLevel: "chart.xyaxis.line"
            case .batteryDetails: "list.bullet.rectangle"
            case .powerUse: "bolt"
            case .displays: "sun.max"
            case .awake: "cup.and.saucer"
            case .layouts: "rectangle.split.3x1"
            case .clipboard: "doc.on.clipboard"
            case .findPhone: "bell.and.waves.left.and.right"
            case .sendFile: "paperplane"
            case .lock: "lock"
            case .pomodoro: "timer"
            case .weather: "cloud.sun"
            case .note: "note.text"
            case .login: "power"
            }
        }

        /// Some parts only show when their tool is on or has something to show.
        var needs: String? {
            switch self {
            case .batteryLimit, .batteryStatus, .powerFlow, .energyApps, .batteryLevel, .batteryDetails, .powerUse: "Shows on Macs with a battery"
            case .displays: "Needs Brightness and Volume"
            case .awake: "Needs Keep Awake"
            case .layouts: "Needs a saved Window Layout"
            case .clipboard: "Needs Clipboard History"
            case .findPhone, .sendFile: "Shows when a phone is connected"
            case .weather: "Needs a city in Notch › Weather"
            default: nil
            }
        }
    }

    /// The menu as it was before it could be changed.
    static let defaultShown: [Section] = [.devices, .displays, .awake, .layouts, .login]

    private(set) var order: [Section]
    private(set) var shown: Set<Section>
    /// The row a drag is over in Advanced › Menu bar.
    var dropTarget: Section?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = (defaults.stringArray(forKey: "menubar.order") ?? []).compactMap(Section.init(rawValue:))
        // Parts added in later versions go at the end.
        order = saved + Section.allCases.filter { !saved.contains($0) }
        shown = defaults.stringArray(forKey: "menubar.shown").map { Set($0.compactMap(Section.init(rawValue:))) }
            ?? Set(Self.defaultShown)
    }

    var visible: [Section] { order.filter(shown.contains) }

    func isShown(_ section: Section) -> Bool { shown.contains(section) }

    func setShown(_ section: Section, _ on: Bool) {
        if on { shown.insert(section) } else { shown.remove(section) }
        save()
    }

    /// Moves a part up (-1) or down (+1).
    func move(_ section: Section, by step: Int) {
        guard let index = order.firstIndex(of: section) else { return }
        let target = index + step
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        save()
    }

    /// Puts a dragged part where another one is, pushing that one down (or up, when dragged from above).
    func place(_ section: Section, at target: Section) {
        guard section != target, let from = order.firstIndex(of: section), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(section, at: to)
        save()
    }

    func reset() {
        order = Section.allCases
        shown = Set(Self.defaultShown)
        save()
    }

    private func save() {
        defaults.set(order.map(\.rawValue), forKey: "menubar.order")
        defaults.set(shown.map(\.rawValue).sorted(), forKey: "menubar.shown")
    }
}
