import AppKit
import ApplicationServices
import CoreAudio

/// Finds YouTube playing in a browser from its window titles, which need only Accessibility.
/// A browser's window title is its open tab's title, so a YouTube tab is found while it is the open tab.
/// Whether it plays comes from Core Audio, which tells which apps are sending sound right now.
enum BrowserMedia {
    static let browsers = [
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "app.zen-browser.zen",
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    struct Window: Equatable {
        let bundleID: String
        let appName: String
        let title: String
    }

    struct Video: Equatable {
        let title: String
        let artist: String?
        let isMusic: Bool
    }

    /// Reads "Song - YouTube", with or without the browser's name after it, and "Song • Artist - YouTube Music".
    static func video(fromWindowTitle raw: String) -> Video? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        // YouTube puts a count of new notifications in front, like "(3) Song - YouTube".
        if let match = text.range(of: #"^\(\d+\+?\) "#, options: .regularExpression) { text.removeSubrange(match) }
        for (suffix, isMusic) in [(" - YouTube Music", true), (" - YouTube", false)] {
            guard let range = text.range(of: suffix, options: .backwards) else { continue }
            let rest = text[range.upperBound...]
            // Only the browser's own name may follow, as in "Song - YouTube — Mozilla Firefox".
            guard rest.isEmpty || rest.hasPrefix(" — ") || rest.hasPrefix(" - ") else { continue }
            let name = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            let parts = name.components(separatedBy: " • ")
            if isMusic, parts.count >= 2 {
                return Video(title: parts[0], artist: parts[1], isMusic: true)
            }
            return Video(title: name, artist: nil, isMusic: isMusic)
        }
        return nil
    }

    /// Chrome-based browsers play through helpers named after them. Safari plays through WebKit.
    static func isAudible(_ bundleID: String, in audible: Set<String>) -> Bool {
        audible.contains { id in
            id == bundleID || id.hasPrefix(bundleID + ".")
                || (bundleID == "com.apple.Safari" && id.hasPrefix("com.apple.WebKit."))
        }
    }

    /// A browser that is sending sound comes first, so the video that plays wins over one left paused.
    static func choose(_ windows: [Window], audible: Set<String>, at now: Date = Date()) -> NowPlaying? {
        let found = windows.compactMap { window in video(fromWindowTitle: window.title).map { (window, $0) } }
        guard let (window, video) = found.first(where: { isAudible($0.0.bundleID, in: audible) }) ?? found.first
        else { return nil }
        let place = (video.isMusic ? "YouTube Music" : "YouTube") + " in " + window.appName
        return NowPlaying(title: video.title, artist: video.artist.map { "\($0) · \(place)" } ?? place,
                          isPlaying: isAudible(window.bundleID, in: audible), positionDate: now)
    }

    /// Reads every running browser's window titles. Slow apps are given a quarter second.
    static func current() -> NowPlaying? {
        guard AXIsProcessTrusted() else { return nil }
        let running = NSWorkspace.shared.runningApplications.filter { app in
            app.bundleIdentifier.map(browsers.contains) == true
        }
        guard !running.isEmpty else { return nil }
        var windows: [Window] = []
        for app in running {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.25)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let list = value as? [AXUIElement] else { continue }
            for window in list {
                var title: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
                      let text = title as? String, !text.isEmpty else { continue }
                windows.append(Window(bundleID: app.bundleIdentifier ?? "", appName: app.localizedName ?? "browser", title: text))
            }
        }
        return choose(windows, audible: audibleApps())
    }

    /// Bundle IDs of the apps sending sound now. No permission is needed to ask.
    static func audibleApps() -> Set<String> {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        var result = Set<String>()
        for object in objects {
            var outputAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                                           mScope: kAudioObjectPropertyScopeGlobal,
                                                           mElement: kAudioObjectPropertyElementMain)
            var isRunning: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(object, &outputAddress, 0, nil, &runningSize, &isRunning) == noErr,
                  isRunning != 0 else { continue }
            var idAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(object, &idAddress, 0, nil, &nameSize, &name) == noErr,
                  let id = name?.takeRetainedValue() as String? else { continue }
            result.insert(id)
        }
        return result
    }
}
