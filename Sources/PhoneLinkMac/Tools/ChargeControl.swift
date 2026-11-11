import AppKit
import Foundation
import IOKit.ps
import Observation
import PowerKit

// Charging control. macOS 27 removed the SMC keys that stop charging, so the only switch left is the charger input
// itself (CHIE): off, the Mac runs on battery with the charger plugged in. Everything here is built on that one switch,
// flipped by a tiny root helper. The helper's guard puts the charger back on if DyskLink stops or the battery is low.

struct ChargeSettings: Codable, Equatable {
    var limiter = false
    var limit = 80
    /// Sailing: once the limit is reached, the charger stays off until the battery falls this many points.
    var sailing = true
    var sail = 5
    var discharge = false
    var heat = false
    var heatLimit = 42.0

    /// Without sailing the charger comes back one point under the limit.
    var gap: Int { sailing ? sail : 1 }

    init() {}

    // Settings saved by older versions lack newer fields, so each one falls back to its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = ChargeSettings()
        limiter = try c.decodeIfPresent(Bool.self, forKey: .limiter) ?? base.limiter
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? base.limit
        sailing = try c.decodeIfPresent(Bool.self, forKey: .sailing) ?? base.sailing
        sail = try c.decodeIfPresent(Int.self, forKey: .sail) ?? base.sail
        discharge = try c.decodeIfPresent(Bool.self, forKey: .discharge) ?? base.discharge
        heat = try c.decodeIfPresent(Bool.self, forKey: .heat) ?? base.heat
        heatLimit = try c.decodeIfPresent(Double.self, forKey: .heatLimit) ?? base.heatLimit
    }

    static let limitRange = 20...100
    static let sailRange = 2...20
    static let heatRange = 35.0...50.0
}

enum CalibrationPhase: Codable, Equatable {
    case off
    case draining
    case charging
    case holding(until: Date)

    static let drainTo = 15
    static let holdFor: TimeInterval = 60 * 60
}

enum ChargeReason: String, Codable, Equatable {
    case normal, lowBattery, limit, discharge, heat, calibrationDrain, calibrationCharge, calibrationHold, topUp, held

    var adapterOn: Bool { ![.limit, .discharge, .heat, .calibrationDrain].contains(self) }

    var label: String {
        switch self {
        case .normal: "Charging normally"
        case .lowBattery: "Battery low: charging, whatever the settings"
        case .limit: "Limit reached: running on battery"
        case .discharge: "Discharge on power: running on battery"
        case .heat: "Battery too warm: charging paused"
        case .calibrationDrain: "Calibrating: running down to \(CalibrationPhase.drainTo)%"
        case .calibrationCharge: "Calibrating: charging to 100%"
        case .calibrationHold: "Calibrating: resting at 100%"
        case .topUp: "Topping up to 100%"
        case .held: "Holding at the limit on the charger"
        }
    }
}

struct ChargeDecision: Equatable {
    var reason: ChargeReason
    var calibration: CalibrationPhase
    /// False once a top-up has reached full.
    var topUp = false
}

/// Decides whether the charger should be on. Pure, so it can be tested. `previous` gives the hysteresis: a limit or
/// heat pause holds until the battery falls by the sailing gap or cools by two degrees.
enum ChargePolicy {
    static let lowBattery = 12
    static let coolDown = 2.0

    static func decide(percent: Int, charging: Bool, temperature: Double?, settings: ChargeSettings,
                       calibration: CalibrationPhase, previous: ChargeReason, now: Date, topUp: Bool = false,
                       native: Int? = nil) -> ChargeDecision {
        var phase = calibration
        // Calibration steps forward first, so the rest sees the current step.
        switch phase {
        case .off: break
        case .draining: if percent <= CalibrationPhase.drainTo { phase = .charging }
        case .charging: if percent >= 100 { phase = .holding(until: now.addingTimeInterval(CalibrationPhase.holdFor)) }
        case .holding(let until): if now >= until { phase = .off }
        }
        // A top-up fills the battery once, then the usual settings come back. Calibration takes over from it.
        let toppingUp = topUp && percent < 100 && phase == .off
        func result(_ reason: ChargeReason) -> ChargeDecision { ChargeDecision(reason: reason, calibration: phase, topUp: toppingUp) }

        if percent <= lowBattery, phase != .draining { return result(.lowBattery) }
        if percent <= CalibrationPhase.drainTo - 5 { return result(.lowBattery) }
        if settings.heat, let temperature, charging || previous == .heat {
            let limit = previous == .heat ? settings.heatLimit - coolDown : settings.heatLimit
            if temperature >= limit { return result(.heat) }
        }
        switch phase {
        case .draining: return result(.calibrationDrain)
        case .charging: return result(.calibrationCharge)
        case .holding: return result(.calibrationHold)
        case .off: break
        }
        if toppingUp { return result(.topUp) }
        // Discharge uses the battery down to the limit, then the limit takes over. Without a limit it runs on battery
        // until the battery is low.
        if settings.discharge, !settings.limiter || percent > settings.limit { return result(.discharge) }
        // macOS's own Charge Limit holds the battery there while the charger runs the Mac, which DyskLink can't do on
        // macOS 27. When it's set to this limit or lower, the charger stays on and macOS keeps the level.
        if settings.limiter, let native, native < 100, native <= settings.limit, percent >= native - 1 {
            return result(.held)
        }
        if settings.limiter {
            // Once paused, charging resumes when the battery is down by the sailing gap.
            let holding = previous == .limit ? percent > settings.limit - settings.gap : percent >= settings.limit
            if holding { return result(.limit) }
        }
        return result(.normal)
    }
}

/// The charge limit set in System Settings › Battery, from `pmset -g battlimit`.
enum NativeChargeLimit {
    static func parse(_ text: String) -> Int? {
        guard let line = text.split(separator: "\n").first(where: { $0.contains("chargeSocLimitSoc") }) else { return nil }
        return Int(line.filter(\.isNumber))
    }

    static func read() -> Int? {
        guard let output = try? Shell.run("/usr/bin/pmset", ["-g", "battlimit"]) else { return nil }
        return parse(output)
    }
}

enum Shell {
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        if process.terminationStatus != 0 { throw NSError(domain: "DyskLink", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text]) }
        return text
    }
}

/// Installs and runs the root helper. Installing puts three files in place, with one admin password prompt:
/// the helper, a sudo rule that allows only its `adapter on`, `adapter off`, and `status` commands, and a launchd job
/// that runs its guard every minute.
enum ChargeHelper {
    static let path = "/usr/local/libexec/dysklink-power"
    static let sudoers = "/etc/sudoers.d/dysklink"
    static let daemon = "/Library/LaunchDaemons/id.dysklink.power-guard.plist"
    static let label = "id.dysklink.power-guard"

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: path) && FileManager.default.fileExists(atPath: daemon)
    }

    /// The helper inside this app, copied on install.
    static var bundled: String? {
        if let url = Bundle.main.url(forAuxiliaryExecutable: "dysklink-power") { return url.path }
        let beside = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("dysklink-power").path
        return FileManager.default.isExecutableFile(atPath: beside) ? beside : nil
    }

    static func installScript(helper: String, user: String) -> String {
        let lowPower = PowerSettings.LowPower.allCases.map { "\(path) lowpower \($0.rawValue)" }.joined(separator: ", ")
        let rule = "\(user) ALL=(root) NOPASSWD: \(path) adapter on, \(path) adapter off, \(path) status, \(lowPower)"
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>\(label)</string>
        <key>ProgramArguments</key><array><string>\(path)</string><string>guard</string></array>
        <key>StartInterval</key><integer>60</integer>
        <key>RunAtLoad</key><true/>
        </dict></plist>
        """
        return """
        set -e
        mkdir -p /usr/local/libexec
        install -o root -g wheel -m 755 '\(helper)' '\(path)'
        tmp=$(mktemp)
        printf '%s\\n' '\(rule)' > "$tmp"
        /usr/sbin/visudo -cf "$tmp"
        install -o root -g wheel -m 440 "$tmp" '\(sudoers)'
        rm -f "$tmp"
        cat > '\(daemon)' <<'PLIST'
        \(plist)
        PLIST
        chown root:wheel '\(daemon)'
        chmod 644 '\(daemon)'
        launchctl bootout system/\(label) 2>/dev/null || true
        launchctl bootstrap system '\(daemon)'
        """
    }

    static let removeScript = """
    '\(path)' adapter on 2>/dev/null || true
    launchctl bootout system/\(label) 2>/dev/null || true
    rm -f '\(daemon)' '\(sudoers)' '\(path)'
    """

    /// Runs a script as root after macOS asks for an admin password.
    static func runAsAdmin(_ script: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dysklink-power-\(UUID().uuidString).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let source = "do shell script \"/bin/sh \" & quoted form of \"\(file.path)\" with administrator privileges"
        try Shell.run("/usr/bin/osascript", ["-e", source])
    }

    /// Switches the charger input through sudo, without a password thanks to the installed rule.
    static func setAdapter(on: Bool) throws {
        try Shell.run("/usr/bin/sudo", ["-n", path, "adapter", on ? "on" : "off"])
    }
}

@MainActor
@Observable
final class ChargeControl {
    static let shared = ChargeControl()

    var settings: ChargeSettings { didSet { save(); if settings != oldValue { onChange?() } } }
    /// Told when what the phone shows changes: the reason, the limit, or Top Up.
    @ObservationIgnored var onChange: (() -> Void)?

    /// What a paired phone shows, or nil when charge control can't run here.
    var phoneState: MacCharge? {
        guard available, installed else { return nil }
        return MacCharge(limit: settings.limit, status: reason.label, topUp: topUp, limiting: settings.limiter)
    }
    var calibration: CalibrationPhase { didSet { save() } }
    /// Charges to 100% once, ignoring the limit and discharge, then turns itself off.
    var topUp = UserDefaults.standard.bool(forKey: "charge.topUp") {
        didSet {
            if !previewing { UserDefaults.standard.set(topUp, forKey: "charge.topUp") }
            tick()
            if topUp != oldValue { onChange?() }
        }
    }
    /// The battery level over the last day, one point a minute, for the chart.
    private(set) var levels: [LevelPoint] = ChargeControl.loadLevels()
    /// Kept across launches, so sailing goes on where it was after DyskLink restarts.
    private(set) var reason: ChargeReason = UserDefaults.standard.string(forKey: "charge.reason").flatMap(ChargeReason.init(rawValue:)) ?? .normal {
        didSet {
            guard reason != oldValue else { return }
            if !previewing { UserDefaults.standard.set(reason.rawValue, forKey: "charge.reason") }
            onChange?()
        }
    }
    private(set) var installed = ChargeHelper.isInstalled
    private(set) var adapterOff = false
    private(set) var nativeLimit: Int?
    private(set) var error: String?
    private(set) var busy = false
    private(set) var temperature: Double?
    private(set) var available: Bool
    private(set) var lastCalibration: Date? = UserDefaults.standard.object(forKey: "charge.lastCalibration") as? Date

    private var timer: Timer?
    private var lastSwitch = Date.distantPast
    private var started = false
    private static let settingsKey = "charge.settings"
    private static let calibrationKey = "charge.calibration"
    /// macOS takes a minute or two to start charging after the charger comes back, so switches are spaced out.
    static let minSwitchInterval: TimeInterval = 90

    private init() {
        let defaults = UserDefaults.standard
        settings = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(ChargeSettings.self, from: $0) } ?? ChargeSettings()
        calibration = defaults.data(forKey: Self.calibrationKey).flatMap { try? JSONDecoder().decode(CalibrationPhase.self, from: $0) } ?? .off
        available = !TestEnv.isDryRun && PowerKit.SMC.open() && PowerKit.Adapter.isAvailable
    }

    private var previewing = false

    private func save() {
        guard !previewing else { return }
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
        defaults.set(try? JSONEncoder().encode(calibration), forKey: Self.calibrationKey)
        tick()
    }

    var anythingOn: Bool { settings.limiter || settings.discharge || settings.heat || calibration != .off || topUp }

    func start() {
        guard available, !started else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in MainActor.assumeIsolated { ChargeControl.shared.tick() } }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ChargeControl.shared.beforeSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ChargeControl.shared.tick() }
        }
        tick()
    }

    func tick() {
        guard available else { return }
        installed = ChargeHelper.isInstalled
        adapterOff = Adapter.isOff ?? false
        nativeLimit = NativeChargeLimit.read()
        let battery = Battery.now()
        temperature = battery.temperature.map(Double.init)
        let decision = ChargePolicy.decide(percent: battery.percent, charging: battery.charging, temperature: battery.temperature.map(Double.init),
                                           settings: settings, calibration: calibration, previous: reason, now: Date(), topUp: topUp,
                                           native: nativeLimit)
        if topUp, !decision.topUp { topUp = false }
        record(percent: battery.percent)
        if decision.calibration != calibration {
            if case .holding = calibration, decision.calibration == .off {
                lastCalibration = Date()
                UserDefaults.standard.set(lastCalibration, forKey: "charge.lastCalibration")
            }
            calibration = decision.calibration
        }
        reason = decision.reason
        guard installed else { return }
        // Turning the charger on is always safe, so it never waits; turning it off is spaced out.
        apply(on: decision.reason.adapterOn, urgent: decision.reason.adapterOn)
    }

    private func apply(on: Bool, urgent: Bool) {
        guard on == adapterOff else { return }
        // Turning the charger back on for safety never waits.
        if !urgent, Date().timeIntervalSince(lastSwitch) < Self.minSwitchInterval { return }
        lastSwitch = Date()
        busy = true
        Task.detached {
            let failure: String? = { do { try ChargeHelper.setAdapter(on: on); return nil } catch { return error.localizedDescription } }()
            await MainActor.run {
                let control = ChargeControl.shared
                control.busy = false
                control.error = failure
                control.adapterOff = Adapter.isOff ?? control.adapterOff
            }
        }
    }

    /// Asleep, nothing watches the battery. Near the limit, the charger goes off first so the Mac doesn't fill up overnight.
    private func beforeSleep() {
        guard installed, settings.limiter, calibration == .off, reason != .discharge else { return }
        if Battery.now().percent >= settings.limit - settings.gap, !adapterOff {
            try? ChargeHelper.setAdapter(on: false)
            reason = .limit
        }
    }

    /// When DyskLink quits, the charger always comes back.
    func shutDown() {
        guard available, installed, Adapter.isOff == true else { return }
        try? ChargeHelper.setAdapter(on: true)
    }

    func install() {
        guard let helper = ChargeHelper.bundled else { error = "The helper is missing from this copy of DyskLink."; return }
        busy = true
        error = nil
        let script = ChargeHelper.installScript(helper: helper, user: NSUserName())
        Task.detached {
            let failure: String? = { do { try ChargeHelper.runAsAdmin(script); return nil } catch { return error.localizedDescription } }()
            await MainActor.run {
                let control = ChargeControl.shared
                control.busy = false
                // Cancelling the password prompt isn't an error worth showing.
                control.error = failure.flatMap { $0.contains("-128") ? nil : $0 }
                control.tick()
            }
        }
    }

    func remove() {
        busy = true
        error = nil
        settings = ChargeSettings()
        calibration = .off
        Task.detached {
            let failure: String? = { do { try ChargeHelper.runAsAdmin(ChargeHelper.removeScript); return nil } catch { return error.localizedDescription } }()
            await MainActor.run {
                let control = ChargeControl.shared
                control.busy = false
                control.error = failure.flatMap { $0.contains("-128") ? nil : $0 }
                control.tick()
            }
        }
    }

    struct LevelPoint: Codable, Equatable {
        var time: Date
        var percent: Int
    }

    private static let levelsKey = "charge.levels"

    private static func loadLevels() -> [LevelPoint] {
        guard let data = UserDefaults.standard.data(forKey: levelsKey),
              let points = try? JSONDecoder().decode([LevelPoint].self, from: data) else { return [] }
        let since = Date().addingTimeInterval(-86_400)
        return points.filter { $0.time > since }
    }

    private func record(percent: Int) {
        guard !previewing else { return }
        let now = Date()
        if let last = levels.last, now.timeIntervalSince(last.time) < 60 { return }
        levels.append(LevelPoint(time: now, percent: percent))
        let since = now.addingTimeInterval(-86_400)
        if let first = levels.first, first.time < since { levels.removeAll { $0.time < since } }
        UserDefaults.standard.set(try? JSONEncoder().encode(levels), forKey: Self.levelsKey)
    }

    func startCalibration() { calibration = .draining }

    /// For snapshots: shows the controls as if the helper were installed.
    func preview(temperature: Double, lastCalibration: Date) {
        previewing = true
        available = true
        installed = true
        self.temperature = temperature
        self.lastCalibration = lastCalibration
        settings.limiter = true
        reason = .limit
        adapterOff = true
        let now = Date()
        // A day of sailing between 75 and 80%, with a dip in the afternoon.
        levels = (0..<480).map { i in
            let t = Double(i)
            let dip = i > 250 && i < 330 ? Int(18 * sin((t - 250) / 80 * .pi)) : 0
            return LevelPoint(time: now.addingTimeInterval(-Double(480 - i) * 180), percent: 80 - (i % 60) / 12 - dip)
        }
    }
    func cancelCalibration() { calibration = .off }

    /// A short note when the System Settings limit gets in the way of what's set here.
    /// How to stay exactly at the limit while plugged in, when that isn't set up yet.
    var holdHint: String? {
        guard settings.limiter, calibration == .off else { return nil }
        if let native = nativeLimit, native < 100, native <= settings.limit { return nil }
        if settings.limit >= 80 {
            return "To stay at exactly \(settings.limit)% while plugged in, with the charger running the Mac, set Charge Limit in System Settings › Battery to \(settings.limit)% too. DyskLink then leaves the charger on and macOS holds the level. Without it, DyskLink switches the charger off at the limit and the Mac runs on battery\(settings.sailing ? " down to \(settings.limit - settings.sail)%" : " until it's 1% lower")."
        }
        return "macOS's Charge Limit only goes down to 80%, so below that DyskLink switches the charger off at the limit and the Mac runs on battery. Turn off Sailing Mode to stay within 1% of \(settings.limit)%."
    }

    var nativeLimitNote: String? {
        guard let native = nativeLimit, native < 100 else { return nil }
        if calibration != .off { return "Calibration needs the Charge Limit in System Settings at 100%. It's at \(native)% now." }
        if settings.limiter, settings.limit > native { return "System Settings stops charging at \(native)% first. Raise it there or lower the limit here." }
        return nil
    }
}
