import AppKit
import CryptoKit
import Foundation

/// A file or folder Mac care can move to the Trash.
struct CareItem: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int64
    /// Why it's listed, such as "Not opened for 5 months".
    var detail: String = ""
    var date: Date?
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

/// The parts that read the disk. They take the home folder so tests can use a fake one.
enum MacCare {
    static let ownBundleId = "id.dysklink.mac"

    // MARK: Sizes

    /// Space a file or folder takes on disk. Links aren't followed, and app bundles count as one item.
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        if values.isDirectory != true { return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let child = walker?.nextObject() as? URL {
            guard let v = try? child.resourceValues(forKeys: keys), v.isSymbolicLink != true, v.isDirectory != true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    static func children(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The newest of when it was changed and when it was last opened.
    static func lastUsed(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .contentAccessDateKey, .addedToDirectoryDateKey])
        return [values?.contentModificationDate, values?.contentAccessDate, values?.addedToDirectoryDate].compactMap { $0 }.max()
    }

    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let days = Int(now.timeIntervalSince(date) / 86_400)
        if days < 1 { return "today" }
        if days < 60 { return "\(days) days ago" }
        if days < 730 { return "\(days / 30) months ago" }
        return "\(days / 365) years ago"
    }

    /// Paths under the home folder are shown with ~, like in Terminal.
    static func shortPath(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let path = url.path
        return path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
    }

    // MARK: Trash

    /// Moves items to the Trash, where they can be put back. Finder asks for a password when one needs it.
    @MainActor
    static func trash(_ urls: [URL], done: @escaping (_ moved: [URL], _ failed: [URL]) -> Void) {
        guard !urls.isEmpty else { return done([], []) }
        NSWorkspace.shared.recycle(urls) { moved, _ in
            let gone = Array(moved.keys)
            let failed = urls.filter { url in !gone.contains { $0.standardizedFileURL == url.standardizedFileURL } && exists(url) }
            DispatchQueue.main.async { done(gone, failed) }
        }
    }
}

// MARK: - Cleaner

enum CleanGroup: String, CaseIterable, Sendable {
    case caches, logs, developer, installers, oldDownloads, large

    var title: String {
        switch self {
        case .caches: "App caches"
        case .logs: "Logs"
        case .developer: "Developer files"
        case .installers: "Installers"
        case .oldDownloads: "Old downloads"
        case .large: "Large files"
        }
    }

    var detail: String {
        switch self {
        case .caches: "Apps make these again when they need them. Quit an app before cleaning its cache."
        case .logs: "Records apps write for troubleshooting."
        case .developer: "Xcode build data, simulator caches, and Gradle and npm caches. Builds take longer the first time after."
        case .installers: "Disk images and packages in Downloads. Once an app is installed, these aren't needed."
        case .oldDownloads: "In Downloads and not opened for 3 months. Check before removing."
        case .large: "Files of 500 MB or more in your home folder. Check before removing."
        }
    }

    var icon: String {
        switch self {
        case .caches: "archivebox"
        case .logs: "doc.text"
        case .developer: "hammer"
        case .installers: "shippingbox"
        case .oldDownloads: "arrow.down.circle"
        case .large: "externaldrive"
        }
    }

    /// Safe kinds start selected. Your own files never do.
    var selectedByDefault: Bool { self == .caches || self == .logs || self == .developer }
}

enum Cleaner {
    static let minimumItem: Int64 = 512 * 1024
    static let largeFile: Int64 = 500 * 1_000_000
    static let oldAfter: TimeInterval = 90 * 86_400
    static let installerTypes: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso"]

    /// [lastUsed] is the date a file was last used; tests pass their own, since the date added can't be set.
    static func scan(home: URL, now: Date = Date(), lastUsed: (URL) -> Date? = MacCare.lastUsed,
                     progress: (String) -> Void = { _ in }) -> [CleanGroup: [CareItem]] {
        var result: [CleanGroup: [CareItem]] = [:]
        let library = home.appendingPathComponent("Library")

        progress("App caches")
        result[.caches] = sized(MacCare.children(of: library.appendingPathComponent("Caches"))
            .filter { !$0.lastPathComponent.hasPrefix(MacCare.ownBundleId) })

        progress("Logs")
        result[.logs] = sized(MacCare.children(of: library.appendingPathComponent("Logs")))

        progress("Developer files")
        let developer = [
            library.appendingPathComponent("Developer/Xcode/DerivedData"),
            library.appendingPathComponent("Developer/CoreSimulator/Caches"),
            library.appendingPathComponent("Developer/Xcode/iOS DeviceSupport"),
            home.appendingPathComponent(".gradle/caches"),
            home.appendingPathComponent(".npm/_cacache"),
        ].filter(MacCare.exists)
        result[.developer] = sized(developer, detail: { MacCare.shortPath($0, home: home) })

        progress("Downloads")
        let downloads = home.appendingPathComponent("Downloads")
        let inDownloads = MacCare.children(of: downloads).filter { !$0.lastPathComponent.hasPrefix(".") }
        let installers = inDownloads.filter { installerTypes.contains($0.pathExtension.lowercased()) }
        result[.installers] = sized(installers, minimum: 1, detail: { "Added " + MacCare.ago(lastUsed($0), now: now) })
        let old = inDownloads.filter { url in
            !installers.contains(url) && (lastUsed(url).map { now.timeIntervalSince($0) > oldAfter } ?? false)
        }
        result[.oldDownloads] = sized(old, minimum: 1, detail: { "Last used " + MacCare.ago(lastUsed($0), now: now) })

        progress("Large files")
        result[.large] = largeFiles(home: home, now: now)
        return result
    }

    private static func sized(_ urls: [URL], minimum: Int64 = minimumItem, detail: (URL) -> String = { _ in "" }) -> [CareItem] {
        urls.compactMap { url in
            let size = MacCare.size(of: url)
            return size >= minimum ? CareItem(url: url, size: size, detail: detail(url), date: MacCare.lastUsed(url)) : nil
        }
        .sorted { $0.size > $1.size }
    }

    /// Big files in the home folder, outside Library, hidden folders, and app bundles.
    static func largeFiles(home: URL, now: Date = Date(), minimum: Int64 = largeFile, limit: Int = 200) -> [CareItem] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: home, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                          errorHandler: { _, _ in true }) else { return [] }
        var found: [CareItem] = []
        while let url = walker.nextObject() as? URL {
            if walker.level == 1, ["Library", "Applications"].contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            if size >= minimum {
                let used = MacCare.lastUsed(url)
                found.append(CareItem(url: url, size: size, detail: MacCare.shortPath(url.deletingLastPathComponent(), home: home) + " · used " + MacCare.ago(used, now: now), date: used))
            }
        }
        return Array(found.sorted { $0.size > $1.size }.prefix(limit))
    }
}

// MARK: - Duplicates

struct DuplicateGroup: Identifiable, Hashable, Sendable {
    let id: String
    let size: Int64
    /// Oldest first, which is the copy kept by default.
    let files: [CareItem]
    var wasted: Int64 { size * Int64(files.count - 1) }
}

enum Duplicates {
    /// Same size, then the same first 64 KB, then the same SHA-256 of the whole file.
    static func find(in folders: [URL], minimum: Int64, limit: Int = 300_000,
                     progress: (Int) -> Void = { _ in }, cancelled: () -> Bool = { false }) -> [DuplicateGroup] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey, .creationDateKey, .fileResourceIdentifierKey]
        var bySize: [Int64: [URL]] = [:]
        var seen = Set<String>()
        var count = 0
        for folder in folders {
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                              errorHandler: { _, _ in true }) else { continue }
            while let url = walker.nextObject() as? URL {
                if cancelled() { return [] }
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, v.isSymbolicLink != true,
                      let size = v.fileSize, Int64(size) >= minimum else { continue }
                // A folder picked twice, or one inside another, must not make a file its own copy.
                if !seen.insert(url.standardizedFileURL.resolvingSymlinksInPath().path).inserted { continue }
                bySize[Int64(size), default: []].append(url)
                count += 1
                if count % 500 == 0 { progress(count) }
                if count >= limit { break }
            }
        }
        progress(count)
        var groups: [DuplicateGroup] = []
        for (size, urls) in bySize where urls.count > 1 {
            if cancelled() { return [] }
            let byHead = Dictionary(grouping: urls) { hash($0, upTo: 64 * 1024) ?? UUID().uuidString }
            for (_, sameHead) in byHead where sameHead.count > 1 {
                let byFull = Dictionary(grouping: sameHead) { (size <= 64 * 1024 ? hash($0, upTo: 64 * 1024) : hash($0)) ?? UUID().uuidString }
                for (digest, same) in byFull where same.count > 1 {
                    let items = same.map { url in
                        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                        return CareItem(url: url, size: size, detail: "", date: created)
                    }
                    .sorted { ($0.date ?? .distantFuture, $0.url.path) < ($1.date ?? .distantFuture, $1.url.path) }
                    groups.append(DuplicateGroup(id: digest, size: size, files: items))
                }
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    static func hash(_ url: URL, upTo limit: Int? = nil) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var read = 0
        while true {
            let want = limit.map { min(1 << 20, $0 - read) } ?? (1 << 20)
            if want <= 0 { break }
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            read += chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Uninstall

struct InstalledApp: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let bundleId: String
    let version: String
    var size: Int64?
    var id: String { url.path }
}

enum Uninstaller {
    static func apps(in roots: [URL]) -> [InstalledApp] {
        var found: [InstalledApp] = []
        for root in roots {
            for url in MacCare.children(of: root) {
                if url.pathExtension == "app" {
                    if let app = read(url) { found.append(app) }
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    // Some apps sit in a folder of their own inside Applications.
                    found += MacCare.children(of: url).filter { $0.pathExtension == "app" }.compactMap(read)
                }
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Apple's own apps and DyskLink itself aren't offered.
    static func read(_ url: URL) -> InstalledApp? {
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        guard let bundleId = info?["CFBundleIdentifier"] as? String, !bundleId.isEmpty,
              !bundleId.hasPrefix("com.apple."), bundleId != MacCare.ownBundleId else { return nil }
        let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let version = (info?["CFBundleShortVersionString"] as? String) ?? ""
        return InstalledApp(url: url, name: url.deletingPathExtension().lastPathComponent.isEmpty ? name : url.deletingPathExtension().lastPathComponent,
                            bundleId: bundleId, version: version)
    }

    struct Leftover: Identifiable, Hashable, Sendable {
        let item: CareItem
        /// Found by the app's ID, so it surely belongs to it. Matches by name only are left for you to tick.
        let byId: Bool
        var id: String { item.id }
    }

    /// A bundle ID that's safe to put into a Library path: letters, digits, dots and dashes, never `.` or `..`.
    /// An app saying its ID is `.` or `../..` would otherwise point at whole Library folders.
    static func isSafeBundleId(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, id.count <= 255, id != ".", !id.contains("..") else { return false }
        func plain(_ c: Unicode.Scalar) -> Bool { c.isASCII && (CharacterSet.alphanumerics.contains(c)) }
        return plain(first) && id.unicodeScalars.allSatisfy { plain($0) || $0 == "." || $0 == "-" }
    }

    /// True when `url` sits directly inside `folder`, after symlinks in its parent are followed.
    /// The leftover itself may be a symlink: moving it to the Trash moves only the link.
    static func isDirectlyInside(_ url: URL, folder: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return false }
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        return parent == folder.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Other installed copies with the same bundle ID: the ones in the list, plus any Launch Services knows of.
    static func otherCopies(of app: InstalledApp, listed: [URL]) -> [URL] {
        let own = app.url.standardizedFileURL.resolvingSymlinksInPath().path
        var seen: Set<String> = [own]
        var found: [URL] = []
        let known = isSafeBundleId(app.bundleId) ? NSWorkspace.shared.urlsForApplications(withBundleIdentifier: app.bundleId) : []
        for url in listed + known {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            // Launch Services also remembers apps already in the Trash.
            if path.contains("/.Trash/") { continue }
            if seen.insert(path).inserted, MacCare.exists(url) { found.append(url) }
        }
        return found
    }

    /// Settings, caches, and support files the app left in Library.
    static func leftovers(for app: InstalledApp, home: URL) -> [Leftover] {
        let library = home.appendingPathComponent("Library")
        let id = app.bundleId
        // Each candidate with the Library folder it must sit directly in.
        var byId: [(URL, URL)] = []
        if isSafeBundleId(id) {
            let named: [(String, String)] = [
                ("Application Support", id), ("Caches", id), ("Preferences", id + ".plist"), ("Containers", id),
                ("Saved Application State", id + ".savedState"), ("Logs", id), ("HTTPStorages", id),
                ("HTTPStorages", id + ".binarycookies"), ("WebKit", id), ("Cookies", id + ".binarycookies"), ("Application Scripts", id),
            ]
            byId = named.map { folder, name in
                let parent = library.appendingPathComponent(folder)
                return (parent.appendingPathComponent(name), parent)
            }
            func scan(_ folder: String, _ keep: (String) -> Bool) {
                let parent = library.appendingPathComponent(folder)
                byId += MacCare.children(of: parent).filter { keep($0.lastPathComponent) }.map { ($0, parent) }
            }
            scan("Preferences/ByHost") { $0.hasPrefix(id + ".") && $0.hasSuffix(".plist") }
            scan("LaunchAgents") { $0.hasPrefix(id + ".") || $0 == id + ".plist" }
            scan("Group Containers") { $0.hasSuffix("." + id) }
        }

        var byName: [(URL, URL)] = []
        let name = app.name
        if name.count >= 3, name != "..", !name.contains("/") {
            for folder in ["Application Support", "Caches", "Logs"] {
                let parent = library.appendingPathComponent(folder)
                byName += MacCare.children(of: parent)
                    .filter { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }.map { ($0, parent) }
            }
        }
        var seen = Set<String>()
        func make(_ urls: [(URL, URL)], _ isId: Bool) -> [Leftover] {
            urls.filter { url, parent in
                isDirectlyInside(url, folder: parent) && MacCare.exists(url) && seen.insert(url.standardizedFileURL.path).inserted
            }
            .map { url, _ in
                Leftover(item: CareItem(url: url, size: MacCare.size(of: url), detail: MacCare.shortPath(url.deletingLastPathComponent(), home: home)), byId: isId)
            }
        }
        return make(byId, true) + make(byName, false)
    }
}

// MARK: - Startup

struct StartupItem: Identifiable, Hashable, Sendable {
    enum Scope: String, Sendable { case user, allUsersAgent, daemon }
    let url: URL
    let label: String
    let program: String
    let scope: Scope
    let runsAtLoad: Bool
    let keepsAlive: Bool
    /// Turned off by DyskLink: the file waits in DyskLink's folder until turned back on.
    let isOff: Bool
    var id: String { url.path }

    /// The app the program belongs to, from the .app in its path.
    var appName: String? {
        program.components(separatedBy: "/").first { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
    }
}

enum Startup {
    static func disabledFolder(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/DyskLink/Disabled Launch Agents")
    }

    static func items(home: URL, system: URL = URL(fileURLWithPath: "/Library")) -> [StartupItem] {
        func read(_ folder: URL, _ scope: StartupItem.Scope, off: Bool = false) -> [StartupItem] {
            MacCare.children(of: folder).filter { $0.pathExtension == "plist" }.compactMap { parse($0, scope: scope, off: off) }
        }
        let all = read(home.appendingPathComponent("Library/LaunchAgents"), .user)
            + read(disabledFolder(home: home), .user, off: true)
            + read(system.appendingPathComponent("LaunchAgents"), .allUsersAgent)
            + read(system.appendingPathComponent("LaunchDaemons"), .daemon)
        return all.sorted { ($0.scope.rawValue, $0.label.lowercased()) < ($1.scope.rawValue, $1.label.lowercased()) }
    }

    static func parse(_ url: URL, scope: StartupItem.Scope, off: Bool) -> StartupItem? {
        guard let plist = NSDictionary(contentsOf: url) as? [String: Any] else { return nil }
        let label = (plist["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first ?? ""
        let keepAlive = (plist["KeepAlive"] as? Bool) ?? (plist["KeepAlive"] is [String: Any])
        return StartupItem(url: url, label: label, program: program, scope: scope,
                           runsAtLoad: (plist["RunAtLoad"] as? Bool) ?? false, keepsAlive: keepAlive,
                           isOff: off || (plist["Disabled"] as? Bool) == true)
    }

    /// Runs launchctl. Tests pass a stand-in.
    typealias Launchctl = ([String]) -> Int32

    static let launchctl: Launchctl = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Stops the agent and moves its file aside, so it doesn't start at the next login. Only your own agents.
    static func turnOff(_ item: StartupItem, home: URL, run: Launchctl = launchctl) throws -> URL {
        guard item.scope == .user, !item.isOff else { return item.url }
        _ = run(["bootout", "gui/\(getuid())", item.url.path])
        let folder = disabledFolder(home: home)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(item.url.lastPathComponent)
        if MacCare.exists(target) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: item.url, to: target)
        return target
    }

    /// Puts the file back and starts the agent again.
    static func turnOn(_ item: StartupItem, home: URL, run: Launchctl = launchctl) throws -> URL {
        guard item.scope == .user, item.url.deletingLastPathComponent().standardizedFileURL == disabledFolder(home: home).standardizedFileURL
        else { return item.url }
        let folder = home.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(item.url.lastPathComponent)
        if MacCare.exists(target) { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.moveItem(at: item.url, to: target)
        _ = run(["bootstrap", "gui/\(getuid())", target.path])
        return target
    }
}
