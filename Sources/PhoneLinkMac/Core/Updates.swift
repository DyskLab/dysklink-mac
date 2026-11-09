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
    }

    static let releasesURL = URL(string: "https://api.github.com/repos/DyskLab/dysklink-mac/releases?per_page=10")!
    static let pageURL = URL(string: "https://github.com/DyskLab/dysklink-mac/releases")!
    static let interval: TimeInterval = 24 * 60 * 60

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
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                result = .success(try Self.newest(in: data, newerThan: current))
            } catch {
                result = .failure(error)
            }
            finish(result, manual: manual)
        }
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

    /// Hides this version until a newer one comes out.
    func skip() {
        guard let available else { return }
        defaults.set(available.version, forKey: "updates.skipped")
        self.available = nil
    }

    // MARK: Parsing

    /// The highest published version above `current`, counting pre-releases, since DyskLink is still in them.
    nonisolated static func newest(in data: Data, newerThan current: String) throws -> Release? {
        struct Item: Decodable {
            let tag_name: String
            let html_url: String
            let draft: Bool?
        }
        let items = try JSONDecoder().decode([Item].self, from: data)
        let candidates = items.compactMap { item -> Release? in
            guard item.draft != true, let url = URL(string: item.html_url), version(item.tag_name) != nil else { return nil }
            return Release(version: clean(item.tag_name), url: url)
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
