import AppKit
import Foundation

/// The Firefox extension that tells DyskLink what YouTube plays, through native messaging.
enum BrowserExtension {
    static let hostName = "id.dysklink.browser"
    static let extensionID = "dysklink@dysklink.id"
    static let notification = Notification.Name("id.dysklink.browser-media")

    private static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    static var extensionFolder: URL { support.appendingPathComponent("DyskLink/firefox-extension") }

    /// Firefox reads host manifests here; Zen, a Firefox-based browser, in its own folder.
    static var hostFolders: [URL] {
        var folders = [support.appendingPathComponent("Mozilla/NativeMessagingHosts")]
        let zen = support.appendingPathComponent("zen")
        if FileManager.default.fileExists(atPath: zen.path) { folders.append(zen.appendingPathComponent("NativeMessagingHosts")) }
        return folders
    }

    static var hostPath: String? {
        Bundle.main.url(forAuxiliaryExecutable: "dysklink-browser-host")?.path
    }

    static func manifest(hostPath: String) -> Data {
        let object: [String: Any] = [
            "name": hostName,
            "description": "Passes what YouTube plays in Firefox to DyskLink's notch.",
            "path": hostPath,
            "type": "stdio",
            "allowed_extensions": [extensionID],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static var isInstalled: Bool {
        guard let hostPath else { return false }
        let file = hostFolders[0].appendingPathComponent("\(hostName).json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["path"] as? String == hostPath
    }

    /// Registers the host with Firefox, copies the extension next to DyskLink's data, and opens Firefox's add-on page.
    static func install() throws {
        guard let hostPath else { throw NSError(domain: "DyskLink", code: 1, userInfo: [NSLocalizedDescriptionKey: "The browser helper is missing from this copy of DyskLink."]) }
        let manager = FileManager.default
        for folder in hostFolders {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try manifest(hostPath: hostPath).write(to: folder.appendingPathComponent("\(hostName).json"), options: .atomic)
        }
        if let bundled = Bundle.main.url(forResource: "firefox-extension", withExtension: nil) {
            try? manager.removeItem(at: extensionFolder)
            try manager.createDirectory(at: extensionFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: bundled, to: extensionFolder)
            // A packed copy too, for browsers that accept unsigned add-ons.
            // Install is a button on the main thread, and nothing waits for the packed copy, so zip runs in the background.
            let folder = extensionFolder
            let xpi = folder.appendingPathComponent("dysklink-youtube.xpi")
            DispatchQueue.global(qos: .utility).async {
                _ = ProcessRunner.run("/usr/bin/zip", ["-qr", xpi.path, "manifest.json", "background.js", "content.js", "icons"],
                                      timeout: 60, directory: folder)
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([extensionFolder.appendingPathComponent("manifest.json")])
    }

    static func remove() {
        for folder in hostFolders { try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(hostName).json")) }
    }

    /// Reads one message from the extension: `{v, browser, state}`, where state is null when nothing plays.
    /// Returns nil for anything that isn't a message, and `.some(nil)` when the browser stopped playing.
    static func parse(_ json: String, at now: Date = Date()) -> NowPlaying?? {
        guard let data = json.data(using: .utf8), data.count <= 64 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["v"] as? Int == 1 else { return nil }
        let browser = String((object["browser"] as? String ?? "Firefox").prefix(40))
        guard let state = object["state"] as? [String: Any] else { return .some(nil) }
        guard let title = (state["title"] as? String).map({ String($0.prefix(200)) }), !title.isEmpty else { return .some(nil) }
        let channel = (state["channel"] as? String).map { String($0.prefix(120)) } ?? ""
        let place = ((state["music"] as? Bool) == true ? "YouTube Music" : "YouTube") + " in " + browser
        var track = NowPlaying(title: title, artist: channel.isEmpty ? place : "\(channel) · \(place)",
                               isPlaying: state["p"] as? Bool ?? false,
                               duration: (state["d"] as? NSNumber)?.doubleValue,
                               position: (state["t"] as? NSNumber)?.doubleValue,
                               positionDate: now, source: "extension:\(browser)")
        track.videoID = (state["i"] as? String).flatMap { $0.range(of: #"^[A-Za-z0-9_-]{6,20}$"#, options: .regularExpression) != nil ? $0 : nil }
        return .some(track)
    }
}
