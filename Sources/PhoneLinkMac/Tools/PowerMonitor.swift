import Foundation
import Observation
import PowerKit

/// Where the power goes, sampled every two seconds while the battery page is open.
struct PowerSample: Equatable {
    var time = Date()
    /// From the charger into the Mac.
    var adapterWatts = 0.0
    /// Into the battery while charging (positive), out of it on battery (negative).
    var batteryWatts = 0.0
    /// Everything the Mac uses.
    var systemWatts = 0.0
    var gpuWatts: Double?

    var fromBattery: Double { max(0, -batteryWatts) }
    var intoBattery: Double { max(0, batteryWatts) }
    var restWatts: Double { max(0, systemWatts - (gpuWatts ?? 0)) }
}

struct EnergyApp: Equatable, Identifiable {
    var name: String
    /// macOS's energy impact score, as in Activity Monitor.
    var impact: Double
    var id: String { name }
}

@MainActor
@Observable
final class PowerMonitor {
    static let shared = PowerMonitor()

    private(set) var current = PowerSample()
    /// The last twenty minutes, for the power chart.
    private(set) var history: [PowerSample] = []
    private(set) var apps: [EnergyApp] = []
    /// The battery details, refreshed every ten seconds, for places that don't have Mac Care's reading.
    private(set) var battery: BatteryReading?
    /// Apps above this energy impact are worth showing.
    static let significantImpact = 10.0

    private(set) var users = 0
    /// True while something on screen shows live power, such as the open menu.
    var isLive: Bool { users > 0 }
    private var timer: Timer?
    private var tick = 0
    private let gpu = GPUEnergy()
    private(set) var previewing = false

    func begin() {
        users += 1
        guard users == 1, !previewing, !TestEnv.isDryRun else { return }
        _ = PowerKit.SMC.open()
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { PowerMonitor.shared.sample() } }
        timer?.tolerance = 0.3
    }

    func end() {
        users = max(0, users - 1)
        if users == 0 { timer?.invalidate(); timer = nil }
    }

    private func sample() {
        let battery = Battery.now()
        var next = PowerSample()
        let volts = Double(batteryVoltage()) / 1000
        next.batteryWatts = volts * Double(battery.amperage) / 1000
        next.systemWatts = Double(PowerKit.SMC.float("PSTR") ?? 0)
        // With the charger input switched off, the adapter reading is leftover noise.
        next.adapterWatts = Adapter.isOff == true ? 0 : max(0, Double(PowerKit.SMC.float("PDTR") ?? 0))
        next.gpuWatts = gpu.watts()
        current = next
        history.append(next)
        let since = Date().addingTimeInterval(-20 * 60)
        history.removeAll { $0.time < since }
        tick += 1
        if tick % 5 == 1 {
            refreshApps()
            self.battery = BatteryHealth.read()
        }
    }

    private func batteryVoltage() -> Int {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "Voltage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int ?? 0
    }

    private func refreshApps() {
        Task.detached(priority: .utility) {
            let output = (try? Shell.run("/usr/bin/top", ["-l", "2", "-s", "1", "-n", "8", "-o", "power", "-stats", "command,power"])) ?? ""
            let apps = Self.parseTop(output)
            await MainActor.run { PowerMonitor.shared.apps = apps }
        }
    }

    /// Reads the second sample of `top -stats command,power`; the first one has no energy figures yet.
    nonisolated static func parseTop(_ output: String) -> [EnergyApp] {
        let samples = output.components(separatedBy: "COMMAND")
        guard let last = samples.last, samples.count > 1 else { return [] }
        return last.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let impact = Double(parts.last!) else { return nil }
            let name = parts.dropLast().joined(separator: " ")
            return impact >= significantImpact && name != "top" && name != "kernel_task" ? EnergyApp(name: name, impact: impact) : nil
        }
    }

    /// For snapshots.
    func preview(battery: BatteryReading? = nil) {
        previewing = true
        self.battery = battery
        let now = Date()
        history = (0..<24).map { i in
            let wave = [7.2, 7.0, 7.4, 8.0, 7.6, 12.5, 8.1, 5.9, 11.8, 6.2, 7.0, 7.9, 8.4, 8.2, 7.6, 9.1, 13.8][i % 17]
            return PowerSample(time: now.addingTimeInterval(-Double(24 - i) * 50), adapterWatts: 0, batteryWatts: -wave, systemWatts: wave, gpuWatts: 1.1)
        }
        current = PowerSample(time: now, adapterWatts: 0, batteryWatts: -8.68, systemWatts: 8.68, gpuWatts: 1.06)
        apps = []
    }
}

/// GPU power from IOReport's energy counters, loaded at run time because the library has no public header.
/// macOS 27 reports CPU energy as zero, so only the GPU is shown separately.
final class GPUEnergy {
    private typealias CopyGroup = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias CreateSub = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer?, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Name = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias Value = @convention(c) (CFDictionary, Int32) -> Int64

    private var samples: CreateSamples?
    private var delta: Delta?
    private var name: Name?
    private var unit: Name?
    private var value: Value?
    private var subscription: OpaquePointer?
    private var channels: CFMutableDictionary?
    private var last: (CFDictionary, Date)?

    init() {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW),
              let copy = dlsym(lib, "IOReportCopyChannelsInGroup").map({ unsafeBitCast($0, to: CopyGroup.self) }),
              let sub = dlsym(lib, "IOReportCreateSubscription").map({ unsafeBitCast($0, to: CreateSub.self) }) else { return }
        samples = dlsym(lib, "IOReportCreateSamples").map { unsafeBitCast($0, to: CreateSamples.self) }
        delta = dlsym(lib, "IOReportCreateSamplesDelta").map { unsafeBitCast($0, to: Delta.self) }
        name = dlsym(lib, "IOReportChannelGetChannelName").map { unsafeBitCast($0, to: Name.self) }
        unit = dlsym(lib, "IOReportChannelGetUnitLabel").map { unsafeBitCast($0, to: Name.self) }
        value = dlsym(lib, "IOReportSimpleGetIntegerValue").map { unsafeBitCast($0, to: Value.self) }
        guard let group = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let mutable = CFDictionaryCreateMutableCopy(nil, 0, group) else { return }
        var subscribed: Unmanaged<CFMutableDictionary>?
        subscription = sub(nil, mutable, &subscribed, 0, nil)
        channels = subscribed?.takeRetainedValue()
    }

    func watts() -> Double? {
        guard let samples, let delta, let name, let unit, let value, let subscription, let channels,
              let now = samples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        defer { last = (now, Date()) }
        guard let (before, at) = last, let diff = delta(before, now, nil)?.takeRetainedValue(),
              let list = (diff as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return nil }
        let seconds = Date().timeIntervalSince(at)
        guard seconds > 0.2 else { return nil }
        for channel in list where name(channel as CFDictionary)?.takeUnretainedValue() as String? == "GPU Energy" {
            let raw = Double(value(channel as CFDictionary, 0))
            let scale: Double = switch unit(channel as CFDictionary)?.takeUnretainedValue() as String? {
            case "nJ": 1e-9
            case "uJ": 1e-6
            default: 1e-3
            }
            return raw * scale / seconds
        }
        return nil
    }
}
