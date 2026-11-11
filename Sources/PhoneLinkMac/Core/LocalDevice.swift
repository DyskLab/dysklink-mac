import Foundation
import IOKit
import IOKit.network
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
              protocolVersion: PhoneLinkProtocol.version, paired: paired,
              appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
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
            model: model,
            wakeMacs: wake?.macs,
            wakeBroadcast: wake?.broadcast,
            wakeEnabled: wakeForNetwork
        )
    }

    /// The hardware address and broadcast address of the first en interface with IPv4, which is the one phones reach.
    static var wake: (macs: [String], broadcast: String)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var links: [String: String] = [:]
        var networks: [(name: String, broadcast: String)] = []
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            let flags = Int32(entry.pointee.ifa_flags)
            guard name.hasPrefix("en"), flags & IFF_UP != 0, let address = entry.pointee.ifa_addr else { continue }
            if address.pointee.sa_family == UInt8(AF_LINK) {
                address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link in
                    let length = Int(link.pointee.sdl_alen)
                    guard length == 6 else { return }
                    let bytes = withUnsafeBytes(of: link.pointee.sdl_data) { raw in
                        Array(raw[Int(link.pointee.sdl_nlen)..<Int(link.pointee.sdl_nlen) + length])
                    }
                    links[name] = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                }
            } else if address.pointee.sa_family == UInt8(AF_INET), let mask = entry.pointee.ifa_netmask {
                let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                var broadcast = in_addr(s_addr: ip | ~netmask)
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &broadcast, &text, socklen_t(text.count))
                networks.append((name, String(cString: text)))
            }
        }
        for network in networks.sorted(by: { $0.name < $1.name }) {
            // Apps may only see 02:00:00:00:00:00 for the address in use, so the card's own address is sent too.
            let macs = [etherAddress(network.name), links[network.name], hardwareAddress(network.name)]
                .compactMap { $0 }.filter { $0 != "02:00:00:00:00:00" }
            let unique = macs.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            if !unique.isEmpty { return (unique, network.broadcast) }
        }
        return nil
    }

    /// The address burned into the network card, from IOKit.
    static func hardwareAddress(_ interface: String) -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, interface))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var parent: io_object_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        guard let data = IORegistryEntryCreateCFProperty(parent, "IOMACAddress" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data, data.count == 6 else { return nil }
        return data.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    private static var etherCache: [String: (mac: String?, at: Date)] = [:]
    private static let etherLock = NSLock()

    /// The address the router sees, which is the private Wi-Fi address when that's on. Cached for a minute.
    static func etherAddress(_ interface: String) -> String? {
        etherLock.lock()
        defer { etherLock.unlock() }
        if let cached = etherCache[interface], Date().timeIntervalSince(cached.at) < 60 { return cached.mac }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = [interface]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let mac = parseEther(output)
        etherCache[interface] = (mac, Date())
        return mac
    }

    static func parseEther(_ ifconfig: String) -> String? {
        for line in ifconfig.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.first == "ether", parts.count > 1, parts[1].split(separator: ":").count == 6 { return parts[1].lowercased() }
        }
        return nil
    }

    /// "Wake for network access" on power adapter from `pmset -g custom`, read once since it rarely changes.
    /// Wake-on-LAN only works on power, so the battery setting doesn't matter.
    static let wakeForNetwork: Bool? = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "custom"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return parseWake(output)
    }()

    static func parseWake(_ pmset: String) -> Bool? {
        // With sections, only AC Power counts. Without them (desktop Macs), the single list does.
        let hasSections = pmset.contains("Power:")
        var inAC = !hasSections
        for line in pmset.split(separator: "\n") {
            if line.hasSuffix("Power:") { inAC = line.hasPrefix("AC"); continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if inAC, parts.first == "womp", parts.count > 1 { return parts[1] == "1" }
        }
        return nil
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
