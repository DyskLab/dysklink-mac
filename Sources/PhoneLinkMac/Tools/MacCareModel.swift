import AppKit
import Foundation
import Observation

/// State for the Mac care page. Scans run in the background; everything removed goes to the Trash.
@MainActor
@Observable
final class MacCareModel {
    enum Tab: String, CaseIterable { case cleaner, duplicates, uninstall, startup, battery
        var title: String {
            switch self {
            case .cleaner: "Cleaner"
            case .duplicates: "Duplicates"
            case .uninstall: "Uninstall"
            case .startup: "Startup"
            case .battery: "Battery"
            }
        }
        var icon: String {
            switch self {
            case .cleaner: "sparkles"
            case .duplicates: "doc.on.doc"
            case .uninstall: "trash.square"
            case .startup: "power"
            case .battery: "battery.75percent"
            }
        }
    }

    /// A removal waiting for the user to confirm it.
    enum Confirm: Identifiable {
        case clean, duplicates, uninstall(InstalledApp), startup(StartupItem)
        var id: String {
            switch self {
            case .clean: "clean"
            case .duplicates: "dups"
            case .uninstall(let app): "app" + app.id
            case .startup(let item): "start" + item.id
            }
        }
    }

    var confirm: Confirm?
    /// Off in snapshots, so their sample lists aren't replaced by this Mac's.
    var loadsOnShow = true
    /// Cleaner groups showing every item, not just the biggest five.
    var expandedGroups: Set<CleanGroup> = []
    var tab: Tab = .cleaner
    let home: URL
    /// A short line after each removal, such as "Moved 12 items, 3.4 GB, to the Trash."
    var message: String?
    /// The last removal stopped because the Finder may not be controlled (Automation), so the message gets a button.
    var messageNeedsAutomation = false
    /// Folders macOS kept from the last scan, named for the hint that says how to allow them.
    var blockedFolders: [String] = []

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        dupFolders = Self.defaultFolders(home: home)
    }

    // MARK: Cleaner

    var cleanGroups: [CleanGroup: [CareItem]] = [:]
    var cleanSelected: Set<String> = []
    var isCleaning = false
    var cleanStep: String?
    var cleanScanned = false

    func scanCleaner() {
        guard !isCleaning else { return }
        isCleaning = true
        cleanStep = "Starting"
        let home = home
        Task.detached(priority: .userInitiated) {
            let groups = Cleaner.scan(home: home) { step in Task { @MainActor in self.cleanStep = step } }
            let blocked = MacCare.unreadable(MacCareModel.defaultFolders(home: home)).map(\.lastPathComponent)
            await MainActor.run {
                self.blockedFolders = blocked
                self.cleanGroups = groups
                self.cleanSelected = Set(groups.filter { $0.key.selectedByDefault }.flatMap { $0.value.map(\.id) })
                self.isCleaning = false
                self.cleanStep = nil
                self.cleanScanned = true
            }
        }
    }

    var cleanTotal: Int64 { cleanGroups.values.flatMap { $0 }.reduce(0) { $0 + $1.size } }
    var cleanSelection: [CareItem] { cleanGroups.values.flatMap { $0 }.filter { cleanSelected.contains($0.id) } }

    func cleanSelectedItems() {
        let items = cleanSelection
        trash(items) { moved in
            for group in CleanGroup.allCases { self.cleanGroups[group]?.removeAll { moved.contains($0.id) } }
            self.cleanSelected.subtract(moved)
        }
    }

    // MARK: Duplicates

    var dupFolders: [URL]
    var dupMinimum: Int64 = 1_000_000
    var dupGroups: [DuplicateGroup] = []
    /// Copies ticked for removal. The oldest copy in each group starts unticked.
    var dupSelected: Set<String> = []
    var isFindingDups = false
    var dupChecked = 0
    var dupScanned = false
    @ObservationIgnored private var dupTask: Task<Void, Never>?

    nonisolated static func defaultFolders(home: URL) -> [URL] {
        ["Downloads", "Documents", "Desktop"].map { home.appendingPathComponent($0) }
    }

    static let folderChoices = ["Downloads", "Documents", "Desktop", "Pictures", "Movies", "Music"]

    func toggleFolder(_ url: URL) {
        if let index = dupFolders.firstIndex(of: url) { dupFolders.remove(at: index) } else { dupFolders.append(url) }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { panel.urls.forEach { if !dupFolders.contains($0) { dupFolders.append($0) } } }
    }

    func findDuplicates() {
        if isFindingDups {
            dupTask?.cancel()
            isFindingDups = false
            return
        }
        guard !dupFolders.isEmpty else { return }
        isFindingDups = true
        dupChecked = 0
        let folders = dupFolders
        let minimum = dupMinimum
        dupTask = Task.detached(priority: .userInitiated) {
            let groups = Duplicates.find(in: folders, minimum: minimum,
                                         progress: { count in Task { @MainActor in self.dupChecked = count } },
                                         cancelled: { Task.isCancelled })
            let stopped = Task.isCancelled
            let blocked = MacCare.unreadable(folders).map(\.lastPathComponent)
            await MainActor.run {
                if !stopped {
                    self.blockedFolders = blocked
                    self.dupGroups = groups
                    self.dupSelected = Set(groups.flatMap { $0.files.dropFirst().map(\.id) })
                    self.dupScanned = true
                }
                self.isFindingDups = false
            }
        }
    }

    /// Ticking every copy in a group isn't allowed, so one is always kept.
    func toggleDuplicate(_ file: CareItem, in group: DuplicateGroup) {
        if dupSelected.contains(file.id) {
            dupSelected.remove(file.id)
        } else if group.files.filter({ $0.id != file.id }).contains(where: { !dupSelected.contains($0.id) }) {
            dupSelected.insert(file.id)
        }
    }

    var dupSelection: [CareItem] { dupGroups.flatMap(\.files).filter { dupSelected.contains($0.id) } }

    func removeDuplicates() {
        trash(dupSelection) { moved in
            self.dupGroups = self.dupGroups.compactMap { group in
                let left = group.files.filter { !moved.contains($0.id) }
                // Groups that were all clones stay at nothing to free.
                return left.count > 1 ? DuplicateGroup(id: group.id, size: group.size, files: left,
                                                       reclaimable: group.reclaimable == 0 ? 0 : nil) : nil
            }
            self.dupSelected.subtract(moved)
        }
    }

    // MARK: Uninstall

    var apps: [InstalledApp] = []
    var appQuery = ""
    var sortBySize = false
    var isLoadingApps = false
    var chosenApp: InstalledApp?
    var leftovers: [Uninstaller.Leftover] = []
    var leftoverSelected: Set<String> = []
    /// Set when another copy of the chosen app shares its bundle ID, so the ID-matched files may be that copy's too.
    var leftoverWarning: String?

    var appRoots: [URL] { [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] }

    /// Drops apps that are gone, such as ones dragged to the Trash in Finder, then lists the folders again
    /// so new ones show up too.
    func refreshApps() {
        apps.removeAll { !MacCare.exists($0.url) }
        if let chosen = chosenApp, !MacCare.exists(chosen.url) { choose(nil) }
        loadApps()
    }

    func loadApps() {
        guard !isLoadingApps else { return }
        isLoadingApps = true
        let roots = appRoots
        Task.detached(priority: .userInitiated) {
            let list = Uninstaller.apps(in: roots)
            await MainActor.run {
                let sizes = Dictionary(self.apps.compactMap { app in app.size.map { (app.id, $0) } }, uniquingKeysWith: { a, _ in a })
                self.apps = list.map { app in var app = app; app.size = sizes[app.id]; return app }
            }
            // Sizes come in as they're counted, so the list shows right away.
            for app in list {
                let size = MacCare.size(of: app.url)
                await MainActor.run {
                    if let index = self.apps.firstIndex(where: { $0.id == app.id }) { self.apps[index].size = size }
                }
            }
            await MainActor.run { self.isLoadingApps = false }
        }
    }

    var shownApps: [InstalledApp] {
        let query = appQuery.trimmingCharacters(in: .whitespaces)
        let list = query.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.bundleId.localizedCaseInsensitiveContains(query)
        }
        return sortBySize ? list.sorted { ($0.size ?? 0) > ($1.size ?? 0) } : list
    }

    func choose(_ app: InstalledApp?) {
        chosenApp = app
        leftovers = []
        leftoverSelected = []
        leftoverWarning = nil
        guard let app else { return }
        let home = home
        let listed = apps.filter { $0.bundleId == app.bundleId && $0.id != app.id }.map(\.url)
        Task.detached(priority: .userInitiated) {
            let found = Uninstaller.leftovers(for: app, home: home)
            let others = Uninstaller.otherCopies(of: app, listed: listed)
            await MainActor.run {
                guard self.chosenApp?.id == app.id else { return }
                self.leftovers = found
                if others.isEmpty {
                    self.leftoverSelected = Set(found.filter(\.byId).map(\.id))
                } else {
                    // The files carry the ID, not the copy: they may belong to the other one.
                    self.leftoverSelected = []
                    let places = others.prefix(3).map { MacCare.shortPath($0, home: home) }.joined(separator: ", ")
                    self.leftoverWarning = "Another copy of this app is installed (\(places)). It shares these files, so none are ticked. Tick only what you're sure the other copy doesn't need."
                }
            }
        }
    }

    /// Bumped when an app opens or quits, so views that ask `isRunning` draw again.
    private var runningChanges = 0
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    /// The app that was asked to quit and hasn't yet, offered a Force Quit.
    var stuckQuit: String?
    /// Set while waiting for an app to quit.
    var quitting: String?

    private func watchRunningApps() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.runningChanges += 1 }
            })
        }
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        _ = runningChanges
        watchRunningApps()
        return !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleId).isEmpty
    }

    /// Asks the app to quit, as Quit in its menu does (it may ask to save). After 6 seconds still open, Force Quit is offered.
    func quit(_ app: InstalledApp, force: Bool = false) {
        watchRunningApps()
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleId)
        guard !running.isEmpty else { runningChanges += 1; return }
        stuckQuit = nil
        quitting = app.bundleId
        for app in running { if force { app.forceTerminate() } else { app.terminate() } }
        let id = app.bundleId
        Task { @MainActor [weak self] in
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(500))
                if NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty { break }
            }
            guard let self, self.quitting == id else { return }
            self.quitting = nil
            self.runningChanges += 1
            if !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty { self.stuckQuit = id }
        }
    }

    var uninstallSize: Int64 {
        (chosenApp?.size ?? 0) + leftovers.filter { leftoverSelected.contains($0.id) }.reduce(0) { $0 + $1.item.size }
    }

    func uninstallChosen() {
        guard let app = chosenApp else { return }
        // Removed meanwhile, in Finder or by its own uninstaller.
        guard MacCare.exists(app.url) else {
            apps.removeAll { $0.id == app.id }
            choose(nil)
            message = "\(app.name) is no longer on this Mac."
            return
        }
        let items = [CareItem(url: app.url, size: app.size ?? 0)] + leftovers.map(\.item).filter { leftoverSelected.contains($0.id) }
        trash(items) { moved in
            if moved.contains(app.id) {
                self.apps.removeAll { $0.id == app.id }
                self.choose(nil)
            } else {
                self.leftovers.removeAll { moved.contains($0.id) }
            }
        }
    }

    // MARK: Startup

    var startupItems: [StartupItem] = []
    var startupError: String?
    /// Agents being turned on, off, or removed, by file name, which stays the same when the file moves. Their rows are
    /// disabled until it's done, so a second toggle can't race the first.
    private(set) var startupBusy: Set<String> = []

    func isBusy(_ item: StartupItem) -> Bool { startupBusy.contains(item.url.lastPathComponent) }

    // MARK: Battery

    var battery: BatteryReading?
    var batteryHistory: [BatteryDay] = []
    /// False on a Mac without a battery, after the first read.
    var hasBattery = true
    @ObservationIgnored private var batteryTimer: Timer?
    @ObservationIgnored private var appleHealth: (maxCapacity: Int?, condition: String?)?
    private var dataDirectory: URL { home.appendingPathComponent("Library/Application Support/DyskLink") }

    /// Reads now and every five seconds while the tab is open.
    func startBattery() {
        batteryHistory = BatteryHistory.load(from: dataDirectory)
        refreshBattery()
        batteryTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshBattery() } }
        RunLoop.main.add(timer, forMode: .common)
        batteryTimer = timer
        if appleHealth == nil {
            Task.detached(priority: .utility) {
                let health = BatteryHealth.appleHealth()
                await MainActor.run { [weak self] in
                    self?.appleHealth = health
                    self?.refreshBattery()
                }
            }
        }
    }

    func stopBattery() {
        batteryTimer?.invalidate()
        batteryTimer = nil
    }

    func refreshBattery() {
        guard var reading = BatteryHealth.read() else { hasBattery = false; battery = nil; return }
        reading.appleMaxCapacity = appleHealth?.maxCapacity
        reading.condition = appleHealth?.condition
        battery = reading
        // The daily point waits for Apple's figure, so the history uses one kind of number.
        if appleHealth != nil {
            let updated = BatteryHistory.adding(reading, to: batteryHistory)
            if updated != batteryHistory {
                batteryHistory = updated
                BatteryHistory.save(updated, to: dataDirectory)
            }
        }
    }

    func loadStartup() {
        startupItems = Startup.items(home: home)
    }

    /// launchctl waits for the agent to stop or start, so it runs off the main thread.
    func setStartup(_ item: StartupItem, on: Bool) {
        let home = home
        let key = item.url.lastPathComponent
        guard !startupBusy.contains(key) else { return }
        startupBusy.insert(key)
        Task.detached(priority: .userInitiated) {
            let failure: String?
            do {
                _ = on ? try Startup.turnOn(item, home: home) : try Startup.turnOff(item, home: home)
                failure = nil
            } catch {
                failure = "Couldn't change \(item.label): \(error.localizedDescription)"
            }
            await MainActor.run {
                self.startupBusy.remove(key)
                self.startupError = failure
                self.loadStartup()
            }
        }
    }

    func removeStartup(_ item: StartupItem) {
        let key = item.url.lastPathComponent
        guard !startupBusy.contains(key) else { return }
        startupBusy.insert(key)
        Task.detached(priority: .userInitiated) {
            if !item.isOff { _ = Startup.launchctl(["bootout", "gui/\(getuid())", item.url.path]) }
            await MainActor.run {
                self.trash([CareItem(url: item.url, size: 0)]) { _ in
                    self.startupBusy.remove(key)
                    self.loadStartup()
                }
            }
        }
    }

    func openLoginItems() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    // MARK: Shared

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    private func trash(_ items: [CareItem], done: @escaping (Set<String>) -> Void) {
        let byPath = Dictionary(items.map { ($0.url.standardizedFileURL.path, $0) }, uniquingKeysWith: { a, _ in a })
        MacCare.trash(items.map(\.url)) { moved, failed, problem in
            let movedItems = moved.compactMap { byPath[$0.standardizedFileURL.path] }
            let ids = Set(movedItems.map(\.id))
            let bytes = movedItems.reduce(0) { $0 + $1.size }
            var text = movedItems.isEmpty ? "" : "Moved \(movedItems.count) item\(movedItems.count == 1 ? "" : "s")"
                + (bytes > 0 ? ", \(Format.bytes(bytes))," : "") + " to the Trash. Empty the Trash to free the space."
            if !failed.isEmpty {
                let count = "\(failed.count) item\(failed.count == 1 ? "" : "s")"
                let why = switch problem {
                case .cancelled: "\(count) stayed, because the password was cancelled."
                case .finderNotAllowed: "\(count) couldn't be moved: allow DyskLink to control Finder in System Settings › Privacy & Security › Automation, then try again."
                default: "\(count) couldn't be moved, maybe because they're in use or protected. Quit the app, or drag it to the Trash in Finder."
                }
                text += (text.isEmpty ? "" : " ") + why
            }
            self.message = text.isEmpty ? nil : text
            self.messageNeedsAutomation = !failed.isEmpty && problem == .finderNotAllowed
            done(ids)
        }
    }
}
