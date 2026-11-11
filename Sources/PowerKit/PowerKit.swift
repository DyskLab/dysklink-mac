// Battery and charger access shared by the app (reading) and the root helper (switching the charger input).
import Foundation
import IOKit

// MARK: SMC access. The layout matches the kernel's SMCParamStruct (80 bytes).

struct KeyDataVer { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
struct PLimitData { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
public struct KeyInfo { public var dataSize: UInt32 = 0, dataType: UInt32 = 0, attributes: UInt8 = 0, pad1: UInt8 = 0, pad2: UInt8 = 0, pad3: UInt8 = 0 }
struct SMCParam {
    var key: UInt32 = 0
    var vers = KeyDataVer()
    var pLimit = PLimitData()
    var info = KeyInfo()
    var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
        = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

public enum SMC {
    static let readKey: UInt8 = 5, writeKey: UInt8 = 6, keyInfo: UInt8 = 9
    nonisolated(unsafe) static var connection: io_connect_t = 0

    public static func open() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        defer { IOObjectRelease(service) }
        return service != 0 && IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS
    }

    public static func code(_ key: String) -> UInt32 { key.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private static func call(_ input: inout SMCParam) -> (kern: kern_return_t, out: SMCParam) {
        var output = SMCParam()
        var size = MemoryLayout<SMCParam>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParam>.stride, &output, &size)
        return (result, output)
    }

    public static func info(_ key: String) -> KeyInfo? {
        var input = SMCParam()
        input.key = code(key)
        input.data8 = keyInfo
        let (kern, out) = call(&input)
        return kern == KERN_SUCCESS && out.result == 0 ? out.info : nil
    }

    public static func read(_ key: String) -> [UInt8]? {
        guard let info = info(key) else { return nil }
        var input = SMCParam()
        input.key = code(key)
        input.info.dataSize = info.dataSize
        input.data8 = readKey
        let (kern, out) = call(&input)
        guard kern == KERN_SUCCESS, out.result == 0 else { return nil }
        return withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(info.dataSize))) }
    }

    /// Returns a description of what went wrong, or nil when the write was accepted.
    public static func write(_ key: String, _ bytes: [UInt8]) -> String? {
        guard let info = info(key) else { return "key \(key) is missing" }
        guard Int(info.dataSize) == bytes.count else { return "key \(key) takes \(info.dataSize) bytes" }
        var input = SMCParam()
        input.key = code(key)
        input.info.dataSize = info.dataSize
        input.data8 = writeKey
        withUnsafeMutableBytes(of: &input.bytes) { raw in for (i, b) in bytes.enumerated() { raw[i] = b } }
        let (kern, out) = call(&input)
        if kern != KERN_SUCCESS { return String(format: "kernel refused (0x%x)%@", kern, getuid() == 0 ? "" : ", needs root") }
        if out.result != 0 { return "SMC refused (result \(out.result))" }
        return nil
    }

    public static func float(_ key: String) -> Float? {
        guard let bytes = read(key), bytes.count == 4 else { return nil }
        return bytes.withUnsafeBytes { $0.load(as: Float.self) }
    }
}

// MARK: Battery state, from the battery driver.

public struct Battery {
    public var percent = 0
    public var onAC = false
    public var charging = false
    public var amperage = 0   // mA, negative while discharging
    public var temperature: Float?

    public static func now() -> Battery {
        var state = Battery()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        defer { IOObjectRelease(service) }
        func value(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
        state.percent = value("CurrentCapacity") as? Int ?? 0
        state.onAC = value("ExternalConnected") as? Bool ?? false
        state.charging = value("IsCharging") as? Bool ?? false
        state.amperage = value("InstantAmperage") as? Int ?? value("Amperage") as? Int ?? 0
        state.temperature = SMC.float("TB0T")
        return state
    }

    public init() {}

    public var json: String {
        let temp = temperature.map { String(format: "%.1f", $0) } ?? "null"
        return "{\"percent\":\(percent),\"onAC\":\(onAC),\"charging\":\(charging),\"amperage\":\(amperage),\"temperature\":\(temp)}"
    }
}

/// The charger input switch (SMC key CHIE). Off makes the Mac run on battery with the charger still plugged in.
public enum Adapter {
    public static let on: UInt8 = 0x00, off: UInt8 = 0x08

    public static var isOff: Bool? { SMC.read("CHIE").map { $0.first == off } }
    public static var isAvailable: Bool { SMC.info("CHIE") != nil }

    public static func set(enabled: Bool) -> String? { SMC.write("CHIE", [enabled ? on : off]) }
}
