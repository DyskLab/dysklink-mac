import AppKit
import Foundation
import Observation

/// Looks for a newer release on GitHub. It only reads the public release list,
/// sends nothing about this Mac, and never downloads or installs anything by itself.
@MainActor
@Observable
final class UpdateChecker {
    struct Release: Equatable {
        let version: String
        let url: URL
        /// The Mac app as a zip, when the release has one.
        var zipURL: URL? = nil
    }

    static let releasesURL = URL(string: "https://api.github.com/repos/DyskLab/dysklink-mac/releases?per_page=10")!
    static let pageURL = URL(string: "https://github.com/DyskLab/dysklink-mac/releases")!
    static let interval: TimeInterval = 24 * 60 * 60
    static let phoneReleasesURL = URL(string: "https://api.github.com/repos/DyskLab/dysklink-android/releases?per_page=10")!
    static let phonePageURL = URL(string: "https://github.com/DyskLab/dysklink-android/releases/latest")!
    static let latestPageURL = URL(string: "https://github.com/DyskLab/dysklink-mac/releases/latest")!

    /// The newest full release, read from where its "latest" page redirects (…/releases/tag/v1.2.3).
    nonisolated static func latestFromPage(_ page: URL, current: String) async throws -> Release? {
        var request = URLRequest(url: page, timeoutInterval: 20)
        request.httpMethod = "HEAD"
        request.setValue("DyskLink-Mac/\(current)", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let url = response.url else { throw URLError(.badServerResponse) }
        return release(fromTagPage: url)
    }

    nonisolated static func release(fromTagPage url: URL) -> Release? {
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "tag"), index + 1 < parts.count, version(parts[index + 1]) != nil else { return nil }
        return Release(version: clean(parts[index + 1]), url: url)
    }

    var checksAutomatically: Bool {
        didSet {
            defaults.set(checksAutomatically, forKey: "updates.auto")
            schedule()
        }
    }
    /// A newer version than this one, unless it was skipped.
    private(set) var available: Release?
    private(set) var isChecking = false
    private(set) var status: String?
    /// The newest Android release, read with the same daily check, so the Mac can say when a phone is behind.
    private(set) var latestPhone: Release?

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let notifier = MacNotifier()
    @ObservationIgnored private var timer: Timer?

    init() {
        checksAutomatically = UserDefaults.standard.object(forKey: "updates.auto") as? Bool ?? true
    }

    /// Debug builds made with `swift build` have no version, so they never check.
    static var currentVersion: String? {
        #if DEBUG
        if let versionOverride { return versionOverride }
        #endif
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    #if DEBUG
    static var versionOverride: String?

    func showForSnapshot(_ release: Release) {
        available = release
    }

    /// Asks GitHub for real, as if this were `version`, and prints what it found.
    static func liveCheck(as version: String) -> String {
        var request = URLRequest(url: releasesURL, timeoutInterval: 20)
        request.setValue("DyskLink-Mac/\(version)", forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var output = "no answer"
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
                do {
                    let release = try newest(in: data, newerThan: version)
                    output = release.map { "newer: \($0.version) \($0.url)" } ?? "up to date"
                } catch { output = "parse failed: \(error)" }
            } else {
                output = "failed: \(error?.localizedDescription ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")"
            }
            done.signal()
        }.resume()
        done.wait()
        // The release page, which is used when the API says no.
        let pages = [latestPageURL, phonePageURL]
        for page in pages {
            let finished = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var line = "no answer"
            Task.detached {
                do {
                    let release = try await latestFromPage(page, current: version)
                    line = release.map { "page latest: \($0.version) newer=\(isNewer($0.version, than: version)) \($0.url)" } ?? "page: no tag"
                } catch { line = "page failed: \(error.localizedDescription)" }
                finished.signal()
            }
            finished.wait()
            output += "\n" + line
        }
        return output
    }
    #endif

    func start() {
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard checksAutomatically, Self.currentVersion != nil else { return }
        let last = defaults.object(forKey: "updates.lastCheck") as? Date ?? .distantPast
        // Waits a little after launch, then checks once a day.
        let first = max(15, Self.interval - Date().timeIntervalSince(last))
        let timer = Timer(timeInterval: first, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.check(manual: false)
                self?.schedule()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func check(manual: Bool) {
        guard !isChecking, let current = Self.currentVersion else {
            if Self.currentVersion == nil { status = "This build has no version, so it can't check." }
            return
        }
        isChecking = true
        if manual { status = nil }
        var request = URLRequest(url: Self.releasesURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DyskLink-Mac/\(current)", forHTTPHeaderField: "User-Agent")
        Task {
            let result: Result<Release?, Error>
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    result = .success(try Self.newest(in: data, newerThan: current))
                } else {
                    // GitHub allows 60 API reads an hour per network, which a house of devices can use up.
                    // The release page has no such limit and redirects to the newest release's tag.
                    let latest = try await Self.latestFromPage(Self.latestPageURL, current: current)
                    result = .success(latest.flatMap { release in
                        let zip = URL(string: "https://github.com/DyskLab/dysklink-mac/releases/download/v\(release.version)/DyskLink-mac-arm64.zip")
                        return Self.isNewer(release.version, than: current) ? Release(version: release.version, url: release.url, zipURL: zip) : nil
                    })
                }
            } catch {
                result = .failure(error)
            }
            finish(result, manual: manual)
            await checkPhone(current: current)
        }
    }

    private func checkPhone(current: String) async {
        var request = URLRequest(url: Self.phoneReleasesURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DyskLink-Mac/\(current)", forHTTPHeaderField: "User-Agent")
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let newest = try? Self.newest(in: data, newerThan: "0") {
            latestPhone = newest
        } else if let latest = try? await Self.latestFromPage(Self.phonePageURL, current: current) {
            latestPhone = latest
        }
    }

    /// True when the phone's app is older than the newest Android release, or too old to say its version.
    func isPhoneBehind(_ version: String?) -> Bool {
        guard let version else { return true }
        guard let latest = latestPhone else { return false }
        return Self.isNewer(latest.version, than: version)
    }

    func openPhoneRelease() {
        NSWorkspace.shared.open(latestPhone?.url ?? Self.phonePageURL)
    }

    private func finish(_ result: Result<Release?, Error>, manual: Bool) {
        isChecking = false
        switch result {
        case .failure:
            // A failed automatic check stays quiet and tries again tomorrow.
            if manual { status = "Couldn't reach GitHub. Try again later." }
        case .success(let release):
            defaults.set(Date(), forKey: "updates.lastCheck")
            let skipped = defaults.string(forKey: "updates.skipped")
            if let release, manual || release.version != skipped {
                available = release
                status = nil
                notifyOnce(release)
            } else {
                available = nil
                if manual { status = "DyskLink \(Self.currentVersion ?? "") is the newest version." }
            }
        }
    }

    private func notifyOnce(_ release: Release) {
        guard defaults.string(forKey: "updates.notified") != release.version else { return }
        defaults.set(release.version, forKey: "updates.notified")
        notifier.show(id: "update", title: "DyskLink \(release.version) is available",
                      subtitle: nil, body: "Open DyskLink to download it.")
    }

    func download() {
        NSWorkspace.shared.open(available?.url ?? Self.pageURL)
    }

    // MARK: Installing

    private(set) var isInstalling = false

    /// Installing in place needs the zip, an Apple Silicon Mac, and an app folder this account can write to.
    var canInstall: Bool {
        #if arch(arm64)
        guard available?.zipURL != nil else { return false }
        return FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path)
        #else
        return false
        #endif
    }

    /// Downloads the zip, checks that it is DyskLink signed by the same certificate as this copy, then swaps the
    /// app and opens the new one. Anything unexpected stops the install and leaves this copy as it is.
    func install() {
        guard let release = available, let zip = release.zipURL, !isInstalling else { return }
        isInstalling = true
        status = "Downloading \(release.version)…"
        let current = Bundle.main.bundleURL
        Task {
            let result = await Task.detached { Self.prepare(zip: zip, version: release.version, replacing: current) }.value
            switch result {
            case .success(let newApp):
                status = "Restarting…"
                Self.swap(newApp, into: current)
            case .failure(let problem):
                isInstalling = false
                status = problem.message
            }
        }
    }

    struct InstallProblem: Error {
        let message: String
    }

    nonisolated private static func prepare(zip: URL, version: String, replacing current: URL) -> Result<URL, InstallProblem> {
        let fail = { (text: String) in Result<URL, InstallProblem>.failure(InstallProblem(message: text)) }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("DyskLink-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        } catch { return fail("Couldn't make a folder for the update.") }
        let zipFile = work.appendingPathComponent("update.zip")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var downloaded = false
        URLSession.shared.downloadTask(with: zip) { location, response, _ in
            if let location, (response as? HTTPURLResponse)?.statusCode == 200 {
                downloaded = (try? FileManager.default.moveItem(at: location, to: zipFile)) != nil
            }
            done.signal()
        }.resume()
        done.wait()
        guard downloaded else { return fail("The download failed. Try again later, or use Download.") }
        guard run("/usr/bin/ditto", ["-x", "-k", zipFile.path, work.path]).status == 0 else {
            return fail("The download couldn't be opened.")
        }
        let newApp = work.appendingPathComponent("DyskLink.app")
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version
        else { return fail("The download isn't the expected DyskLink version, so it wasn't installed.") }
        // The new copy must meet this copy's signing requirement, so only the same certificate can replace it.
        let requirement = run("/usr/bin/codesign", ["-d", "-r-", current.path])
        guard requirement.status == 0,
              let line = requirement.output.components(separatedBy: .newlines).first(where: { $0.hasPrefix("designated => ") }),
              !line.contains("cdhash")
        else { return fail("This copy has no lasting signature, so updates must be installed by hand. Use Download.") }
        let designated = String(line.dropFirst("designated => ".count))
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(designated)", newApp.path]).status == 0 else {
            return fail("The download isn't signed like this copy, so it wasn't installed.")
        }
        return .success(newApp)
    }

    /// A small script waits for this app to quit, moves the old copy to the Trash, puts the new one in its place,
    /// and opens it.
    private static func swap(_ newApp: URL, into current: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        old="$HOME/.Trash/DyskLink-old-$(date +%s).app"
        mv "$1" "$old" && mv "$2" "$1" && open "$1" || { [ -d "$old" ] && [ ! -d "$1" ] && mv "$old" "$1"; open "$1"; }
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", current.path, newApp.path]
        do {
            try process.run()
        } catch {
            return
        }
        NSApp.terminate(nil)
    }

    nonisolated private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Hides this version until a newer one comes out.
    func skip() {
        guard let available else { return }
        defaults.set(available.version, forKey: "updates.skipped")
        self.available = nil
    }

    // MARK: Parsing

    /// The highest published version above `current`, counting pre-releases, since DyskLink is still in them.
    nonisolated static func newest(in data: Data, newerThan current: String) throws -> Release? {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        struct Item: Decodable {
            let tag_name: String
            let html_url: String
            let draft: Bool?
            let assets: [Asset]?
        }
        let items = try JSONDecoder().decode([Item].self, from: data)
        let candidates = items.compactMap { item -> Release? in
            guard item.draft != true, let url = URL(string: item.html_url), version(item.tag_name) != nil else { return nil }
            let zip = item.assets?.first { $0.name.hasSuffix("-mac-arm64.zip") }
            return Release(version: clean(item.tag_name), url: url, zipURL: zip.flatMap { URL(string: $0.browser_download_url) })
        }
        let newer = candidates.filter { isNewer($0.version, than: current) }
        return newer.reduce(nil) { best, release in
            best.map { isNewer(release.version, than: $0.version) ? release : $0 } ?? release
        }
    }

    nonisolated static func clean(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// "v0.1.3" becomes [0, 1, 3]. Anything after a dash, like "-beta", is ignored.
    nonisolated static func version(_ text: String) -> [Int]? {
        let core = clean(text).split(separator: "-").first.map(String.init) ?? ""
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = version(candidate), let b = version(current) else { return false }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
