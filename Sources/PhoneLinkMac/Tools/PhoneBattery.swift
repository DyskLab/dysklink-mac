import Foundation
import Observation

/// Decides when the phone's battery deserves a warning. Each warning shows once, then again only after
/// the battery has moved well away from it, so a phone that hovers at the limit doesn't nag.
struct PhoneBatteryAlerts {
    enum Alert: Equatable {
        case low(Int)
        case full
    }

    static let limitChoices = [10, 15, 20, 30]
    /// How far back from the limit the battery must recover before the low warning can come again.
    private static let lowGap = 5
    private static let fullBelow = 95

    private var lowSent = Set<String>()
    private var fullSent = Set<String>()

    /// Unknown battery or charging state gives no warning, rather than a wrong one.
    mutating func update(peer: String, percent: Int?, isCharging: Bool?, limit: Int) -> Alert? {
        guard let percent, let isCharging else { return nil }
        if isCharging || percent > limit + Self.lowGap { lowSent.remove(peer) }
        if !isCharging || percent < Self.fullBelow { fullSent.remove(peer) }
        if !isCharging, percent <= limit, lowSent.insert(peer).inserted { return .low(percent) }
        if isCharging, percent >= 100, fullSent.insert(peer).inserted { return .full }
        return nil
    }

    mutating func forget(_ peer: String) {
        lowSent.remove(peer)
        fullSent.remove(peer)
    }
}

/// Warns in the notch when the connected phone is low or fully charged.
@MainActor
@Observable
final class PhoneBatteryWatcher {
    var isOn: Bool {
        didSet { defaults.set(isOn, forKey: "phoneBattery.on") }
    }
    var limit: Int {
        didSet { defaults.set(limit, forKey: "phoneBattery.limit") }
    }
    var sendsNotification: Bool {
        didSet { defaults.set(sendsNotification, forKey: "phoneBattery.notify") }
    }

    /// Called with the short text for the notch.
    @ObservationIgnored var onAlert: ((String) -> Void)?
    @ObservationIgnored private var alerts = PhoneBatteryAlerts()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let notifier = MacNotifier()
    @ObservationIgnored private var isInert: Bool

    init(isInert: Bool = false) {
        self.isInert = isInert
        isOn = defaults.object(forKey: "phoneBattery.on") as? Bool ?? true
        let stored = defaults.object(forKey: "phoneBattery.limit") as? Int ?? 20
        limit = PhoneBatteryAlerts.limitChoices.contains(stored) ? stored : 20
        sendsNotification = defaults.bool(forKey: "phoneBattery.notify")
    }

    func handle(peer: String, name: String, percent: Int?, isCharging: Bool?) {
        guard isOn,
              let alert = alerts.update(peer: peer, percent: percent, isCharging: isCharging, limit: limit)
        else { return }
        let short = name.count > 12 ? String(name.prefix(11)) + "…" : name
        switch alert {
        case .low(let value):
            onAlert?("\(short) · \(value)% low")
            send("Phone battery is low", "\(name) is at \(value)%.")
        case .full:
            onAlert?("\(short) · fully charged")
            send("Phone is fully charged", "\(name) is at 100%. You can unplug it.")
        }
    }

    private func send(_ title: String, _ body: String) {
        guard sendsNotification, !isInert else { return }
        notifier.show(id: "phone-battery", title: title, subtitle: nil, body: body)
    }

    func forget(_ peer: String) {
        alerts.forget(peer)
    }
}
