import Foundation
import IOKit

/// What the battery reports, read without admin rights.
struct BatteryReading: Equatable {
    var percent: Int
    var cycles: Int
    /// The number of cycles the battery is designed for, such as 1000.
    var designCycles: Int?
    var designMah: Int?
    /// How much a full charge holds now.
    var fullMah: Int?
    var voltageMv: Int
    /// Positive while charging, negative on battery.
    var amperageMa: Int
    var isCharging: Bool
    var isPluggedIn: Bool
    var isFull: Bool
    var adapterWatts: Int?
    /// Minutes, when the Mac has an estimate.
    var minutesToFull: Int?
    var minutesToEmpty: Int?
    var temperatureC: Double?
    /// "Maximum Capacity" from System Information, such as 97.
    var appleMaxCapacity: Int?
    /// "Good", "Service Recommended", and so on.
    var condition: String?

    /// Full charge against the design, the battery's own number.
    var measuredHealth: Int? {
        guard let designMah, let fullMah, designMah > 0 else { return nil }
        return min(100, Int((Double(fullMah) / Double(designMah) * 100).rounded()))
    }

    /// Apple's figure when known, since that's what System Settings shows.
    var health: Int? { appleMaxCapacity ?? measuredHealth }

    var watts: Double { Double(voltageMv) * Double(amperageMa) / 1_000_000 }

    var status: String {
        if isCharging { return adapterWatts.map { "Charging with a \($0) W adapter" } ?? "Charging" }
        if isPluggedIn { return isFull ? "Full, on power" : "On power, not charging" }
        return "On battery"
    }
}

enum BatteryHealth {
    /// Reads AppleSmartBattery, plus the temperature from the SMC. Nil on a Mac without a battery.
    static func read() -> BatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any],
              var reading = parse(dictionary) else { return nil }
        reading.temperatureC = SMC.batteryTemperature()
        return reading
    }

    static func parse(_ d: [String: Any]) -> BatteryReading? {
        guard d["BatteryInstalled"] as? Bool ?? true, let percent = d["CurrentCapacity"] as? Int else { return nil }
        let data = d["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? { d[key] as? Int ?? data[key] as? Int }
        // A number of 65535 means "no estimate".
        func minutes(_ key: String) -> Int? { int(key).flatMap { $0 > 0 && $0 < 65535 ? $0 : nil } }
        let adapter = d["AdapterDetails"] as? [String: Any]
        var temperature: Double?
        if let raw = int("Temperature"), raw > 0 { temperature = Double(raw) / 100 }
        return BatteryReading(
            percent: percent,
            cycles: int("CycleCount") ?? 0,
            designCycles: int("DesignCycleCount9C"),
            designMah: int("DesignCapacity"),
            fullMah: int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") ?? int("FullChargeCapacity"),
            voltageMv: int("Voltage") ?? 0,
            amperageMa: int("InstantAmperage") ?? int("Amperage") ?? 0,
            isCharging: d["IsCharging"] as? Bool ?? false,
            isPluggedIn: d["ExternalConnected"] as? Bool ?? false,
            isFull: d["FullyCharged"] as? Bool ?? false,
            adapterWatts: (adapter?["Watts"] as? Int).flatMap { $0 > 0 ? $0 : nil },
            minutesToFull: minutes("AvgTimeToFull"),
            minutesToEmpty: minutes("AvgTimeToEmpty"),
            temperatureC: temperature
        )
    }

    /// "Maximum Capacity" and the condition from System Information. Slow, so it runs off the main thread.
    static func appleHealth() -> (maxCapacity: Int?, condition: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPPowerDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (nil, nil) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseAppleHealth(data)
    }

    static func parseAppleHealth(_ data: Data) -> (maxCapacity: Int?, condition: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]],
              let health = items.lazy.compactMap({ $0["sppower_battery_health_info"] as? [String: Any] }).first
        else { return (nil, nil) }
        let capacity = (health["sppower_battery_health_maximum_capacity"] as? String)
            .flatMap { Int($0.filter(\.isNumber)) }
        return (capacity, health["sppower_battery_health"] as? String)
    }
}

/// Reads a few keys from the System Management Controller, which any user may do.
enum SMC {
    private struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    /// Padded by hand to 12 bytes like the C struct, because Swift would place the next field in its padding.
    private struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var attributes: UInt8 = 0; var padding: (UInt8, UInt8, UInt8) = (0, 0, 0) }
    private struct Param {
        var key: UInt32 = 0
        var version = Version()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private static func fourCC(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    /// The warmest of the battery's sensors, in °C.
    static func batteryTemperature() -> Double? {
        let values = ["TB0T", "TB1T", "TB2T"].compactMap(read).filter { $0 > 0 && $0 < 90 }
        return values.max()
    }

    static func read(_ key: String) -> Double? {
        guard MemoryLayout<Param>.size == 80, MemoryLayout<Param>.offset(of: \Param.data8) == 42 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connection) }

        var input = Param()
        input.key = fourCC(key)
        input.data8 = 9 // Key info.
        guard let info = call(connection, &input), info.result == 0 else { return nil }
        input.keyInfo.dataSize = info.keyInfo.dataSize
        input.data8 = 5 // Read.
        guard var output = call(connection, &input), output.result == 0 else { return nil }
        let bytes = withUnsafeBytes(of: &output.bytes) { Array($0.prefix(Int(info.keyInfo.dataSize))) }
        switch info.keyInfo.dataType {
        case fourCC("sp78") where bytes.count >= 2:
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case fourCC("flt ") where bytes.count >= 4:
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
        default:
            return nil
        }
    }

    private static func call(_ connection: io_connect_t, _ input: inout Param) -> Param? {
        var output = Param()
        var size = MemoryLayout<Param>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<Param>.stride, &output, &size)
        return result == KERN_SUCCESS ? output : nil
    }
}

/// One health point a day, so slow changes show over months.
struct BatteryDay: Codable, Equatable {
    var day: String
    var health: Int
    var fullMah: Int?
    var cycles: Int
}

enum BatteryHistory {
    static func file(in directory: URL) -> URL { directory.appendingPathComponent("battery-history.json") }

    static func load(from directory: URL) -> [BatteryDay] {
        (try? JSONDecoder().decode([BatteryDay].self, from: Data(contentsOf: file(in: directory)))) ?? []
    }

    /// Adds today's point, or updates it. Keeps two years.
    static func adding(_ reading: BatteryReading, to days: [BatteryDay], now: Date = Date()) -> [BatteryDay] {
        guard let health = reading.health else { return days }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = BatteryDay(day: formatter.string(from: now), health: health, fullMah: reading.fullMah, cycles: reading.cycles)
        var result = days.filter { $0.day != today.day }
        result.append(today)
        result.sort { $0.day < $1.day }
        return Array(result.suffix(730))
    }

    static func save(_ days: [BatteryDay], to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(days) { try? data.write(to: file(in: directory), options: .atomic) }
    }
}
