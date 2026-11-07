import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import Observation

enum AwakeDecision: Equatable {
    case hold
    case pause
    case stop(String)

    static func decide(now: Date, endsAt: Date?, power: PowerStatus, onlyOnPower: Bool, stopBelow: Int,
                       idleSeconds: Double = 0, idleLimitMinutes: Int = 0) -> AwakeDecision {
        if let endsAt, now >= endsAt { return .stop("Time is up.") }
        if idleLimitMinutes > 0, idleSeconds >= Double(idleLimitMinutes * 60) {
            return .stop("Stopped after \(idleLimitMinutes) minutes with no activity.")
        }
        if stopBelow > 0, power.isOnBattery, let percent = power.percent, percent < stopBelow {
            return .stop("Stopped because the battery fell below \(stopBelow)%.")
        }
        return onlyOnPower && power.isOnBattery ? .pause : .hold
    }
}

/// Holds a macOS power assertion, so nothing in the system's own settings changes
/// and the normal behavior returns as soon as it ends or the app quits.
@MainActor
@Observable
final class KeepAwake {
    static let durations: [(minutes: Int, label: String)] = [
        (15, "15 minutes"), (30, "30 minutes"), (60, "1 hour"), (120, "2 hours"),
        (300, "5 hours"), (480, "8 hours"), (0, "Until I stop it"), (customChoice, "Custom time"),
    ]
    static let idleChoices: [(minutes: Int, label: String)] = [
        (0, "Off"), (5, "5 minutes"), (10, "10 minutes"), (15, "15 minutes"), (30, "30 minutes"), (60, "1 hour"),
        (customChoice, "Custom time"),
    ]
    static let customChoice = -1
    static let longestMinutes = 7 * 24 * 60
    static let batteryLimits = [0, 10, 20, 30, 50]
    static let assertionName = "DyskLink Keep Awake"

    var minutes: Int { didSet { defaults.set(minutes, forKey: "keepAwake.minutes") } }
    var customHours: Int { didSet { defaults.set(customHours, forKey: "keepAwake.customHours") } }
    var customMinutes: Int { didSet { defaults.set(customMinutes, forKey: "keepAwake.customMinutes") } }
    var idleChoice: Int { didSet { defaults.set(idleChoice, forKey: "keepAwake.idle"); evaluate() } }
    var customIdleMinutes: Int { didSet { defaults.set(customIdleMinutes, forKey: "keepAwake.customIdle"); evaluate() } }
    var keepsDisplayOn: Bool {
        didSet {
            defaults.set(keepsDisplayOn, forKey: "keepAwake.display")
            release()
            evaluate()
        }
    }
    var onlyOnPower: Bool {
        didSet { defaults.set(onlyOnPower, forKey: "keepAwake.onlyOnPower"); evaluate() }
    }
    var stopBelow: Int {
        didSet { defaults.set(stopBelow, forKey: "keepAwake.stopBelow"); evaluate() }
    }
    private(set) var isActive = false
    private(set) var isPaused = false
    private(set) var endsAt: Date?
    private(set) var note: String?
    private(set) var now = Date()
    private(set) var idleSecondsNow = 0.0

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var assertion: IOPMAssertionID = 0

    init() {
        let stored = UserDefaults.standard
        minutes = stored.object(forKey: "keepAwake.minutes") as? Int ?? 60
        customHours = stored.object(forKey: "keepAwake.customHours") as? Int ?? 1
        customMinutes = stored.object(forKey: "keepAwake.customMinutes") as? Int ?? 30
        idleChoice = stored.object(forKey: "keepAwake.idle") as? Int ?? 0
        customIdleMinutes = stored.object(forKey: "keepAwake.customIdle") as? Int ?? 20
        keepsDisplayOn = stored.object(forKey: "keepAwake.display") as? Bool ?? true
        onlyOnPower = stored.bool(forKey: "keepAwake.onlyOnPower")
        stopBelow = stored.object(forKey: "keepAwake.stopBelow") as? Int ?? 20
    }

    var holdsAssertion: Bool { assertion != 0 }

    /// The chosen length in minutes, where 0 means no limit.
    var sessionMinutes: Int {
        minutes == Self.customChoice ? min(max(customHours, 0) * 60 + max(customMinutes, 0), Self.longestMinutes) : minutes
    }

    var canStart: Bool { minutes != Self.customChoice || sessionMinutes > 0 }

    var idleLimitMinutes: Int {
        idleChoice == Self.customChoice ? max(customIdleMinutes, 0) : idleChoice
    }

    /// Seconds since the last keyboard, mouse, or trackpad input. Playing video doesn't count as input.
    private static var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    var idleText: String? {
        let limit = idleLimitMinutes
        guard limit > 0 else { return nil }
        let left = max(0, limit * 60 - Int(idleSecondsNow))
        return "Ends after \(limit) min with no activity. No activity now: \(Int(idleSecondsNow) / 60) min, \(left / 60) min left."
    }

    var remainingText: String {
        guard let endsAt else { return "Until you stop it" }
        let seconds = max(0, Int(endsAt.timeIntervalSince(now)))
        let time = seconds >= 3600
            ? String(format: "%d h %02d min", seconds / 3600, seconds % 3600 / 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        return time + " left"
    }

    func start() {
        isActive = true
        note = nil
        let length = sessionMinutes
        endsAt = length > 0 ? Date().addingTimeInterval(TimeInterval(length * 60)) : nil
        if timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        evaluate()
    }

    func stop(note: String? = nil) {
        timer?.invalidate()
        timer = nil
        release()
        isActive = false
        isPaused = false
        endsAt = nil
        self.note = note
    }

    private func evaluate() {
        guard isActive else { return }
        now = Date()
        idleSecondsNow = Self.idleSeconds
        let decision = AwakeDecision.decide(
            now: now, endsAt: endsAt, power: PowerStatus.current(), onlyOnPower: onlyOnPower, stopBelow: stopBelow,
            idleSeconds: idleSecondsNow, idleLimitMinutes: idleLimitMinutes
        )
        switch decision {
        case .hold:
            isPaused = false
            hold()
        case .pause:
            isPaused = true
            release()
        case .stop(let reason):
            stop(note: reason)
        }
    }

    private func hold() {
        guard assertion == 0 else { return }
        let type = keepsDisplayOn ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), Self.assertionName as CFString, &id
        )
        if result == kIOReturnSuccess {
            assertion = id
        } else {
            stop(note: "macOS refused the request.")
        }
    }

    private func release() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }
}
