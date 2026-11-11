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
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    var readyDevices: [Device] { devices.filter { $0.state == "device" } }
    var waitingDevices: [Device] { devices.filter { $0.state == "unauthorized" } }

    private func poll() {
        guard enabled, !busy, let adb = adbPath ?? Self.findAdb() else { return }
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
                    self.devices = found
                    self.forwarded = forwardedNow
                }
                self.busy = false
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
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", file.path, folder.path]
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: Self.downloadedAdb.path) else {
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
