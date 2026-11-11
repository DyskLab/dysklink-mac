import AppKit
import Foundation

/// macOS's own power settings that DyskLink can show and change: when Low Power Mode is on. Reading needs nothing;
/// changing it goes through the charge helper when its sudo rule allows it, and otherwise asks for an admin password.
/// Optimized Battery Charging has no setting apps can read or change, so it's explained with a link to System Settings.
@MainActor
@Observable
final class PowerSettings {
    static let shared = PowerSettings()

    enum LowPower: String, CaseIterable, Identifiable {
        case never, battery, adapter, always
        var id: String { rawValue }
        var label: String {
            switch self {
            case .never: "Never"
            case .battery: "On battery"
            case .adapter: "On power"
            case .always: "Always"
            }
        }
    }

    private(set) var lowPower: LowPower?
    /// Low Power Mode is running right now.
    private(set) var lowPowerActive = false
    private(set) var busy = false
    private(set) var error: String?

    static let batterySettings = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!

    /// Reads `pmset -g custom`, which lists the settings for "Battery Power" and "AC Power" separately.
    nonisolated static func parse(custom output: String) -> LowPower? {
        var section = ""
        var battery: Bool?
        var adapter: Bool?
        for line in output.components(separatedBy: .newlines) {
            if line.hasSuffix(":") && !line.hasPrefix(" ") { section = line; continue }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2, parts[0] == "lowpowermode" else { continue }
            let on = parts[1] != "0"
            if section.hasPrefix("Battery") { battery = on } else if section.hasPrefix("AC") { adapter = on }
        }
        guard battery != nil || adapter != nil else { return nil }
        switch (battery ?? false, adapter ?? false) {
        case (true, true): return .always
        case (true, false): return .battery
        case (false, true): return .adapter
        case (false, false): return .never
        }
    }

    nonisolated static func parseActive(_ output: String) -> Bool {
        output.components(separatedBy: .newlines).contains { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            return parts.count == 2 && parts[0] == "lowpowermode" && parts[1] != "0"
        }
    }

    func refresh() {
        Task.detached {
            let custom = (try? Shell.run("/usr/bin/pmset", ["-g", "custom"])) ?? ""
            let current = (try? Shell.run("/usr/bin/pmset", ["-g"])) ?? ""
            await MainActor.run {
                self.lowPower = Self.parse(custom: custom)
                self.lowPowerActive = Self.parseActive(current)
            }
        }
    }

    func setLowPower(_ mode: LowPower) {
        guard !busy, mode != lowPower else { return }
        busy = true
        error = nil
        Task.detached {
            var failure: String?
            // The helper's sudo rule allows these four commands without a password once it's installed or updated.
            if (try? Shell.run("/usr/bin/sudo", ["-n", ChargeHelper.path, "lowpower", mode.rawValue])) == nil {
                let (battery, adapter) = switch mode {
                case .never: ("0", "0")
                case .battery: ("1", "0")
                case .adapter: ("0", "1")
                case .always: ("1", "1")
                }
                do {
                    try ChargeHelper.runAsAdmin("/usr/bin/pmset -b lowpowermode \(battery) && /usr/bin/pmset -c lowpowermode \(adapter)")
                } catch {
                    failure = "Low Power Mode wasn't changed."
                }
            }
            await MainActor.run {
                self.busy = false
                self.error = failure
                self.refresh()
            }
        }
    }
}
