import Foundation
import IOKit.ps
import Network

/// Information about this Mac, sent to the phone and shown in the UI.
enum LocalDevice {
    static var name: String { Host.current().localizedName ?? "Mac" }

    static var model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    static func hello(paired: Bool) -> Hello {
        Hello(name: name, platform: "macos", model: model,
              protocolVersion: PhoneLinkProtocol.version, paired: paired)
    }

    static func info(network: String?) -> DeviceInfo {
        let power = powerState()
        let storage = storageState()
        return DeviceInfo(
            batteryPercent: power.percent,
            isCharging: power.charging,
            network: network,
            storageFreeBytes: storage.free,
            storageTotalBytes: storage.total,
            osVersion: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            model: model
        )
    }

    /// Local IPv4 address, shown for manual connections.
    static func ipv4Addresses() -> [String] {
        var result: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  String(cString: entry.pointee.ifa_name).hasPrefix("en")
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }

    private static func powerState() -> (percent: Int?, charging: Bool?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return (nil, nil) }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            let charging = description[kIOPSIsChargingKey] as? Bool
            return (current * 100 / maximum, charging)
        }
        return (nil, nil)
    }

    private static func storageState() -> (free: Int64?, total: Int64?) {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ])
        return (values?.volumeAvailableCapacityForImportantUsage, values?.volumeTotalCapacity.map(Int64.init))
    }
}
