import AppKit
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Observation

/// Whether the Mac should be kept from sleeping. Only on the charger: on battery it sleeps as usual.
enum ReachableDecision {
    static func wantsAssertion(enabled: Bool, onCharger: Bool) -> Bool { enabled && onCharger }
}

/// Holds the power assertion. The self-test and the snapshots use `PretendSleepAssertion`, so they never make a real one.
@MainActor
protocol SleepAssertionHolder: AnyObject {
    var isHeld: Bool { get }
    /// False when macOS refused it.
    func hold() -> Bool
    func release()
}

/// `PreventSystemSleep` lets the display sleep and only works on AC power, which is exactly this mode.
/// macOS ignores it on battery, and it doesn't stop sleep when the lid closes (unless the Mac is in clamshell mode).
@MainActor
final class SystemSleepAssertion: SleepAssertionHolder {
    static let name = "DyskLink Stay Reachable"
    private var id: IOPMAssertionID = 0
    var isHeld: Bool { id != 0 }

    func hold() -> Bool {
        guard id == 0 else { return true }
        var new: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), Self.name as CFString, &new
        )
        guard result == kIOReturnSuccess else { return false }
        id = new
        return true
    }

    func release() {
        guard id != 0 else { return }
        IOPMAssertionRelease(id)
        id = 0
    }
}

@MainActor
final class PretendSleepAssertion: SleepAssertionHolder {
    private(set) var isHeld = false
    var refuses = false
    func hold() -> Bool {
        if refuses { return false }
        isHeld = true
        return true
    }
    func release() { isHeld = false }
}

/// "Stay reachable while charging": on the charger the Mac doesn't sleep, so phones and PCs stay connected.
/// Separate from Keep Awake; each holds its own assertion, and the charge control's sleep handling still runs on lid close.
@MainActor
@Observable
final class StayReachable {
    static let defaultsKey = "tool.stayReachable"

    enum Status: Equatable { case off, active, waiting, refused }

    var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            if !isInert { UserDefaults.standard.set(isOn, forKey: Self.defaultsKey) }
            apply()
        }
    }
    private(set) var status: Status = .off
    private(set) var onCharger = false
    /// "Wake for network access" on power, from `pmset -g custom`. Nil until read, or on Macs that don't list it.
    private(set) var wakeForNetwork: Bool?

    var isActive: Bool { status == .active }

    @ObservationIgnored private let isInert: Bool
    @ObservationIgnored private let holder: SleepAssertionHolder
    @ObservationIgnored private let readCharger: () -> Bool
    @ObservationIgnored private var started = false
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private var activeObserver: Any?

    init(isInert: Bool = false, holder: SleepAssertionHolder? = nil, onCharger: (() -> Bool)? = nil) {
        self.isInert = isInert
        self.holder = holder ?? (isInert ? PretendSleepAssertion() : SystemSleepAssertion())
        readCharger = onCharger ?? { !PowerStatus.current().isOnBattery }
        isOn = isInert ? false : UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }

    var holdsAssertion: Bool { holder.isHeld }

    func start() {
        guard !started else { return }
        started = true
        apply()
    }

    /// When DyskLink quits the assertion goes with it anyway; this lets it go at once.
    func stop() {
        started = false
        unwatch()
        holder.release()
        status = .off
    }

    /// Checks the charger again and takes or lets go of the assertion.
    func evaluate() {
        onCharger = readCharger()
        guard ReachableDecision.wantsAssertion(enabled: isOn && (started || isInert), onCharger: onCharger) else {
            holder.release()
            status = isOn ? .waiting : .off
            return
        }
        status = holder.hold() ? .active : .refused
    }

    /// For the snapshots only.
    func preview(wakeForNetwork: Bool?) { if isInert { self.wakeForNetwork = wakeForNetwork } }

    private func apply() {
        if isOn && started { watch(); refreshWake() } else { unwatch() }
        evaluate()
    }

    func refreshWake() {
        guard !isInert else { return }
        Task.detached(priority: .utility) {
            let value = LocalDevice.runQuietly("/usr/bin/pmset", ["-g", "custom"]).flatMap(LocalDevice.parseWake)
            await MainActor.run { [weak self] in self?.wakeForNetwork = value }
        }
    }

    private func watch() {
        guard !isInert, powerSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let reachable = Unmanaged<StayReachable>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { reachable.evaluate() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }
        // Coming back from System Settings, the wake setting may have changed.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWake() }
        }
    }

    private func unwatch() {
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        powerSource = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
    }
}
