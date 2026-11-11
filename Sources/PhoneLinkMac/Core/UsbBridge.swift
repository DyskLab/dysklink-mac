import Foundation

/// Connects phones over a USB cable. With USB debugging on, `adb reverse` gives the phone a port on 127.0.0.1 that
/// leads to this Mac, and the phone uses it instead of Wi-Fi while the cable is in.
@MainActor
@Observable
final class UsbBridge {
    struct Device: Equatable, Sendable {
        var serial: String
        /// "device" when ready, "unauthorized" before the phone allows this Mac, or "offline".
        var state: String
        var model: String
    }

    static let downloadURL = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!

    var enabled = UserDefaults.standard.object(forKey: "usb.enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "usb.enabled")
            if enabled { poll() } else { devices = []; forwarded = [] }
        }
    }
    private(set) var adbPath: String?
    private(set) var devices: [Device] = []
    private(set) var downloading = false
    private(set) var downloadError: String?

    @ObservationIgnored private var port: UInt16 = PhoneLinkProtocol.port
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var busy = false
    /// Serials that already have the reverse port.
    @ObservationIgnored private var forwarded: Set<String> = []
    @ObservationIgnored private var lastListCheck = Date.distantPast
    /// When adb last listed a phone. Polling is quick shortly after, and slow when no phone has been seen.
    @ObservationIgnored private var lastDeviceSeen = Date.distantPast
    static let fastInterval: TimeInterval = 4
    static let slowInterval: TimeInterval = 30
    /// How long after the last phone was seen polling stays quick.
    static let recentWindow: TimeInterval = 120

    /// Quick while a phone is plugged in or was a moment ago; otherwise every 30 seconds.
    nonisolated static func interval(sinceDevice: TimeInterval) -> TimeInterval {
        sinceDevice < recentWindow ? fastInterval : slowInterval
    }

    static var downloadedAdb: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DyskLink/platform-tools/adb")
    }

    static func findAdb(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        var candidates: [String] = []
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = environment[key] { candidates.append("\(root)/platform-tools/adb") }
        }
        candidates += [
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb", "/usr/local/bin/adb",
            downloadedAdb.path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Reads `adb devices -l`.
    nonisolated static func parseDevices(_ output: String) -> [Device] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2, !line.hasPrefix("List of"), !line.hasPrefix("*") else { return nil }
            let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? ""
            return Device(serial: parts[0], state: parts[1], model: model)
        }
    }

    /// True when `adb reverse --list` already has the port leading to this Mac's port.
    nonisolated static func hasReverse(_ output: String, port: UInt16) -> Bool {
        output.split(separator: "\n").contains { $0.contains("tcp:\(PhoneLinkProtocol.usbPort) tcp:\(port)") }
    }

    func start(port: UInt16) {
        self.port = port
        adbPath = Self.findAdb()
        guard timer == nil else { return }
        poll()
    }

    /// One timer at a time, set again after each check, with some slack so macOS can group wakeups.
    private func scheduleNext() {
        timer?.invalidate()
        let interval = Self.interval(sinceDevice: Date().timeIntervalSince(lastDeviceSeen))
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var readyDevices: [Device] { devices.filter { $0.state == "device" } }
    var waitingDevices: [Device] { devices.filter { $0.state == "unauthorized" } }

    private func poll() {
        guard !busy else { return }
        guard enabled, let adb = adbPath ?? Self.findAdb() else {
            // Without adb, or turned off, it's checked again slowly; turning it on polls right away.
            if enabled { scheduleNext() } else { timer?.invalidate(); timer = nil }
            return
        }
        adbPath = adb
        busy = true
        let port = port
        let known = forwarded
        let recheck = Date().timeIntervalSince(lastListCheck) > 20
        if recheck { lastListCheck = Date() }
        Task.detached {
            let list = Self.run(adb, ["devices", "-l"]) ?? ""
            let found = Self.parseDevices(list)
            var nowForwarded: Set<String> = []
            for device in found where device.state == "device" {
                // The forward is lost when the adb server restarts, so it's checked now and then.
                if known.contains(device.serial), !recheck {
                    nowForwarded.insert(device.serial)
                    continue
                }
                let current = Self.run(adb, ["-s", device.serial, "reverse", "--list"]) ?? ""
                if Self.hasReverse(current, port: port)
                    || Self.run(adb, ["-s", device.serial, "reverse", "tcp:\(PhoneLinkProtocol.usbPort)", "tcp:\(port)"]) != nil {
                    nowForwarded.insert(device.serial)
                }
            }
            let forwardedNow = nowForwarded
            await MainActor.run {
                if self.enabled {
                    for serial in forwardedNow.subtracting(known) { TestEnv.log("USB_FORWARD \(serial)") }
                    // Set only when it changed, so views showing devices don't redraw on every check.
                    if self.devices != found { self.devices = found }
                    if self.forwarded != forwardedNow { self.forwarded = forwardedNow }
                    if !found.isEmpty { self.lastDeviceSeen = Date() }
                }
                self.busy = false
                if self.enabled { self.scheduleNext() }
            }
        }
    }

    /// Fetches Google's platform tools into Application Support, for Macs without Android Studio.
    func downloadAdb() {
        guard !downloading else { return }
        downloading = true
        downloadError = nil
        Task {
            do {
                let (file, response) = try await URLSession.shared.download(from: Self.downloadURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let folder = Self.downloadedAdb.deletingLastPathComponent().deletingLastPathComponent()
                try? FileManager.default.removeItem(at: folder.appendingPathComponent("platform-tools"))
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                // This task is on the main actor, and unpacking takes seconds, so ditto runs on a background thread.
                let unpacked = await Task.detached(priority: .userInitiated) {
                    ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", file.path, folder.path], timeout: nil)
                }.value
                guard unpacked?.status == 0, FileManager.default.isExecutableFile(atPath: Self.downloadedAdb.path) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                adbPath = Self.downloadedAdb.path
                poll()
            } catch {
                downloadError = "Couldn't download the tools: \(error.localizedDescription)"
            }
            downloading = false
        }
    }

    /// Output, or nil when adb failed.
    nonisolated static func run(_ path: String, _ arguments: [String]) -> String? {
        // Errors are read too, so a chatty adb can't fill that pipe and stall. Starting adb's server can take a while.
        guard let result = ProcessRunner.run(path, arguments, timeout: 30, errorOutput: .capture) else { return nil }
        return result.succeeded ? result.text : nil
    }
}
