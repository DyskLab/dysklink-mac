import AppKit
import Foundation

/// More about what's playing than the players announce: Music's song position and album art, Spotify's album art,
/// and a YouTube video's position, length, channel, and thumbnail in Safari and Chrome-based browsers.
/// It asks the apps through AppleScript, so macOS asks once per app for Automation permission. Off by default.
/// An app is only asked while it's already running, so nothing gets launched.
enum PlayerDetails {
    static let music = "com.apple.Music"
    static let spotify = "com.spotify.client"
    static let safari = "com.apple.Safari"
    /// Chrome-based browsers that understand `execute … javascript`.
    static let chromium = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]

    /// Images only come from the players' own image servers.
    static let imageHosts = ["i.scdn.co", "mosaic.scdn.co", "image-cdn-ak.spotifycdn.com", "image-cdn-fa.spotifycdn.com", "i.ytimg.com"]

    /// AppleScript isn't safe to run from several threads at once, so everything goes through one queue.
    static let queue = DispatchQueue(label: "dysklink.player-details", qos: .utility)

    enum Failure: Error, Equatable {
        case notAllowed(app: String)
        case browserScriptsOff(app: String)
        case other

        var message: String? {
            switch self {
            case .notAllowed(let app): "Allow DyskLink to control \(app) in System Settings › Privacy & Security › Automation."
            case .browserScriptsOff(let app) where app == "Safari":
                "In Safari, turn on Develop › Developer Settings › Allow JavaScript from Apple Events (show the Develop menu in Safari › Settings › Advanced)."
            case .browserScriptsOff(let app): "In \(app), turn on View › Developer › Allow JavaScript from Apple Events."
            case .other: nil
            }
        }
    }

    struct Song: Equatable {
        var position: TimeInterval?
        var duration: TimeInterval?
    }

    struct Video: Equatable {
        var position: TimeInterval
        var duration: TimeInterval?
        var isPlaying: Bool
        var channel: String?
        var id: String?

        var thumbnail: URL? { id.flatMap { $0.isEmpty ? nil : URL(string: "https://i.ytimg.com/vi/\($0)/mqdefault.jpg") } }
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func appName(_ bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
    }

    /// Runs a script. Call on `queue`.
    static func run(_ source: String, app bundleID: String) -> Result<NSAppleEventDescriptor, Failure> {
        guard let script = NSAppleScript(source: source) else { return .failure(.other) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard let error else { return .success(result) }
        let number = error[NSAppleScript.errorNumber] as? Int ?? 0
        let message = error[NSAppleScript.errorMessage] as? String ?? ""
        if number == -1743 { return .failure(.notAllowed(app: appName(bundleID))) }
        if message.localizedCaseInsensitiveContains("JavaScript") { return .failure(.browserScriptsOff(app: appName(bundleID))) }
        return .failure(.other)
    }

    // MARK: Music and Spotify

    static func musicSong() -> Result<Song, Failure>? {
        guard isRunning(music) else { return nil }
        // Numbers come back as a list, so the Mac's decimal comma never gets in the way.
        let source = """
        tell application id "\(music)"
            if player state is stopped then return {}
            return {player position, duration of current track}
        end tell
        """
        return run(source, app: music).map { list in
            guard list.numberOfItems >= 2 else { return Song() }
            return Song(position: list.atIndex(1)?.doubleValue, duration: list.atIndex(2)?.doubleValue)
        }
    }

    static func musicArtwork() -> Data? {
        guard isRunning(music) else { return nil }
        let source = """
        tell application id "\(music)"
            if player state is stopped then return missing value
            if (count of artworks of current track) is 0 then return missing value
            return raw data of artwork 1 of current track
        end tell
        """
        guard case .success(let result) = run(source, app: music) else { return nil }
        let data = result.data
        return data.isEmpty ? nil : data
    }

    static func spotifyArtwork() -> URL? {
        guard isRunning(spotify) else { return nil }
        guard case .success(let result) = run("tell application id \"\(spotify)\" to return artwork url of current track", app: spotify),
              let text = result.stringValue, let url = URL(string: text), isAllowedImage(url) else { return nil }
        return url
    }

    // MARK: YouTube in a browser

    /// Reads the video in the front tab. Single quotes only, so it fits inside an AppleScript string.
    static let videoScript = """
    (function(){var v=document.querySelector('video');if(!v||!/youtube\\.com$/.test(location.hostname))return '';\
    var c=document.querySelector('ytd-watch-metadata #owner #channel-name a, #owner #channel-name a, ytmusic-player-bar .byline a');\
    var id=new URLSearchParams(location.search).get('v')||'';\
    return JSON.stringify({t:v.currentTime,d:isFinite(v.duration)?v.duration:null,p:!v.paused,c:c?c.textContent.trim():'',i:id});})()
    """

    static func video(in bundleID: String) -> Result<Video, Failure>? {
        guard isRunning(bundleID) else { return nil }
        let js = videoScript.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source: String
        if bundleID == safari {
            source = "tell application id \"\(safari)\" to do JavaScript \"\(js)\" in current tab of front window"
        } else if chromium.contains(bundleID) {
            source = "tell application id \"\(bundleID)\" to execute active tab of front window javascript \"\(js)\""
        } else {
            return nil
        }
        switch run(source, app: bundleID) {
        case .success(let result):
            guard let video = parseVideo(result.stringValue ?? "") else { return .failure(.other) }
            return .success(video)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    static func parseVideo(_ json: String) -> Video? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let position = (object["t"] as? NSNumber)?.doubleValue else { return nil }
        let channel = (object["c"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let id = (object["i"] as? String).flatMap { $0.range(of: #"^[A-Za-z0-9_-]{6,20}$"#, options: .regularExpression) != nil ? $0 : nil }
        return Video(position: position, duration: (object["d"] as? NSNumber)?.doubleValue,
                     isPlaying: object["p"] as? Bool ?? true, channel: channel, id: id)
    }

    // MARK: Images

    static func isAllowedImage(_ url: URL) -> Bool {
        url.scheme == "https" && imageHosts.contains(url.host ?? "")
    }

    static func image(from url: URL) async -> NSImage? {
        guard isAllowedImage(url), let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 4_000_000 else { return nil }
        return NSImage(data: data)
    }
}
