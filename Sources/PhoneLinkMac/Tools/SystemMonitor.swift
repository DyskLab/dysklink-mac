import Darwin
import Foundation
import IOKit.ps
import Observation

struct PowerStatus: Equatable {
    var percent: Int?
    var isCharging = false
    var isOnBattery = false

    static func current() -> PowerStatus {
        var status = PowerStatus()
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return status }
        for source in list {
            guard let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let now = details[kIOPSCurrentCapacityKey] as? Int,
                  let max = details[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            status.percent = now * 100 / max
            status.isCharging = details[kIOPSIsChargingKey] as? Bool ?? false
            status.isOnBattery = details[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
        }
        return status
    }
}

struct SystemSample: Equatable {
    var cpu = 0.0
    var memoryUsed: Int64 = 0
    var memoryTotal: Int64 = 0
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    var downloadRate: Int64 = 0
    var uploadRate: Int64 = 0
    var power = PowerStatus()
}

struct ProcessUsage: Identifiable, Equatable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    let cpu: Double
    let memory: Int64
}

/// Samples the system every two seconds, but only while the Advanced page is on screen.
@MainActor
@Observable
final class SystemMonitor {
    private(set) var sample = SystemSample()
    private(set) var cpuHistory: [Double] = []
    private(set) var processes: [ProcessUsage] = []
    @ObservationIgnored var isOnScreen: () -> Bool = { true }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTicks: (busy: UInt64, total: UInt64)?
    @ObservationIgnored private var lastNetwork: (received: UInt64, sent: UInt64, time: Date)?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var isReadingProcesses = false

    private static let historyLength = 60

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOnScreen() else { return }
                self.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastTicks = nil
        lastNetwork = nil
        cpuHistory = []
        processes = []
        sample = SystemSample()
    }

    func refresh() {
        var next = SystemSample()
        next.cpu = readCPU()
        (next.memoryUsed, next.memoryTotal) = Self.readMemory()
        (next.diskFree, next.diskTotal) = Self.readDisk()
        (next.downloadRate, next.uploadRate) = readNetwork()
        next.power = PowerStatus.current()
        sample = next
        cpuHistory.append(next.cpu)
        if cpuHistory.count > Self.historyLength { cpuHistory.removeFirst() }
        if tickCount % 2 == 0 { refreshProcesses() }
        tickCount += 1
    }

    private func refreshProcesses() {
        guard !isReadingProcesses else { return }
        isReadingProcesses = true
        Task.detached(priority: .utility) {
            let rows = Self.readProcesses()
            await MainActor.run {
                self.isReadingProcesses = false
                if self.timer != nil { self.processes = rows }
            }
        }
    }

    private func readCPU() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let busy = UInt64(info.cpu_ticks.0) + UInt64(info.cpu_ticks.1) + UInt64(info.cpu_ticks.3)
        let total = busy + UInt64(info.cpu_ticks.2)
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total, busy >= last.busy else { return 0 }
        return Double(busy - last.busy) / Double(total - last.total)
    }

    private static func readMemory() -> (used: Int64, total: Int64) {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }
        // The same sum Activity Monitor shows as Memory Used: app, wired, and compressed.
        let apps = Int64(info.internal_page_count) - Int64(info.purgeable_count)
        let pages = apps + Int64(info.wire_count) + Int64(info.compressor_page_count)
        return (pages * Int64(getpagesize()), total)
    }

    private static func readDisk() -> (free: Int64, total: Int64) {
        let values = try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        )
        return (values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeTotalCapacity ?? 0))
    }

    private func readNetwork() -> (down: Int64, up: Int64) {
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return (0, 0) }
        defer { freeifaddrs(head) }
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: entry.pointee.ifa_name).hasPrefix("en"),
                  let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self)
            else { continue }
            received += UInt64(data.pointee.ifi_ibytes)
            sent += UInt64(data.pointee.ifi_obytes)
        }
        let now = Date()
        defer { lastNetwork = (received, sent, now) }
        guard let last = lastNetwork else { return (0, 0) }
        let seconds = max(now.timeIntervalSince(last.time), 0.1)
        // These 32-bit counters wrap around, so a drop counts as no traffic.
        let down = received >= last.received ? Double(received - last.received) / seconds : 0
        let up = sent >= last.sent ? Double(sent - last.sent) / seconds : 0
        return (Int64(down), Int64(up))
    }

    nonisolated private static func readProcesses() -> [ProcessUsage] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aceo", "pid=,pcpu=,rss=,comm=", "-r"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseProcesses(String(decoding: data, as: UTF8.self), limit: 6)
    }

    nonisolated static func parseProcesses(_ output: String, limit: Int) -> [ProcessUsage] {
        var rows: [ProcessUsage] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard parts.count == 4, let pid = Int32(parts[0]),
                  let cpu = Double(parts[1].replacingOccurrences(of: ",", with: ".")),
                  let kilobytes = Int64(parts[2])
            else { continue }
            rows.append(ProcessUsage(pid: pid, name: String(parts[3]), cpu: cpu, memory: kilobytes * 1024))
            if rows.count == limit { break }
        }
        return rows
    }
}
