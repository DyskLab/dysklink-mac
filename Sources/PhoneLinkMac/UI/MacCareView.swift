import AppKit
import SwiftUI

/// Mac care: clean up space, find duplicate files, uninstall apps with their leftovers, and manage startup agents.
struct MacCareView: View {
    @Bindable var care: MacCareModel
    var scrolls = true
    private typealias Confirm = MacCareModel.Confirm

    var body: some View {
        VStack(spacing: 0) {
            OptionalScroll(enabled: scrolls) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    tabs
                    if let message = care.message {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint)
                            Text(message).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            IconButton(icon: "xmark", help: "Hide") { care.message = nil }
                        }
                        .padding(12)
                        .background(Theme.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    switch care.tab {
                    case .cleaner: cleaner
                    case .duplicates: duplicates
                    case .uninstall: uninstall
                    case .startup: startup
                    case .battery: batteryTab
                    }
                }
                .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 20)
            }
            footer
        }
        .alert(item: $care.confirm) { confirm in alert(for: confirm) }
        .onAppear {
            guard care.loadsOnShow else { return }
            if care.tab == .uninstall, care.apps.isEmpty { care.loadApps() }
            if care.tab == .startup { care.loadStartup() }
            if care.tab == .battery { care.startBattery() }
        }
        .onDisappear { care.stopBattery() }
        .onChange(of: care.tab) { _, tab in
            if tab == .uninstall, care.apps.isEmpty { care.loadApps() }
            if tab == .startup { care.loadStartup() }
            if tab == .battery, care.loadsOnShow { care.startBattery() } else { care.stopBattery() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mac care").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Text("Free up space and tidy this Mac. Everything removed goes to the Trash, so you can put it back.")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.bottom, 2)
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(MacCareModel.Tab.allCases, id: \.self) { tab in
                let on = care.tab == tab
                Button { care.tab = tab } label: {
                    Label(tab.title, systemImage: tab.icon)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(on ? Theme.panelRaised : Color.clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? Theme.mint.opacity(0.4) : Theme.stroke))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Footer with the selection and the Trash button

    @ViewBuilder
    private var footer: some View {
        switch care.tab {
        case .cleaner where !care.cleanSelection.isEmpty:
            bar(count: care.cleanSelection.count, bytes: care.cleanSelection.reduce(0) { $0 + $1.size }) { care.confirm = .clean }
        case .duplicates where !care.dupSelection.isEmpty:
            bar(count: care.dupSelection.count, bytes: care.dupSelection.reduce(0) { $0 + $1.size }) { care.confirm = .duplicates }
        default:
            EmptyView()
        }
    }

    private func bar(count: Int, bytes: Int64, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Format.bytes(bytes)).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(Theme.textPrimary)
                Text("\(count) item\(count == 1 ? "" : "s") selected").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button(action: action) { Label("Move to Trash", systemImage: "trash") }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 28).padding(.vertical, 12)
        .background(Theme.panel.opacity(0.95))
        .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }

    private func alert(for confirm: Confirm) -> Alert {
        switch confirm {
        case .clean:
            let items = care.cleanSelection
            return Alert(title: Text("Move \(items.count) items to the Trash?"),
                         message: Text("\(Format.bytes(items.reduce(0) { $0 + $1.size })). You can put them back from the Trash until you empty it."),
                         primaryButton: .destructive(Text("Move to Trash")) { care.cleanSelectedItems() }, secondaryButton: .cancel())
        case .duplicates:
            let items = care.dupSelection
            return Alert(title: Text("Move \(items.count) copies to the Trash?"),
                         message: Text("One copy of each file stays where it is. \(Format.bytes(items.reduce(0) { $0 + $1.size })) goes to the Trash."),
                         primaryButton: .destructive(Text("Move to Trash")) { care.removeDuplicates() }, secondaryButton: .cancel())
        case .uninstall(let app):
            let extra = care.leftovers.filter { care.leftoverSelected.contains($0.id) }.count
            return Alert(title: Text("Uninstall \(app.name)?"),
                         message: Text("The app" + (extra > 0 ? " and \(extra) of its files" : "") + " go to the Trash, \(Format.bytes(care.uninstallSize)) in all. Your Mac may ask for your password."),
                         primaryButton: .destructive(Text("Uninstall")) { care.uninstallChosen() }, secondaryButton: .cancel())
        case .startup(let item):
            return Alert(title: Text("Remove \(item.label)?"),
                         message: Text("It stops now and won't start at login. The file goes to the Trash."),
                         primaryButton: .destructive(Text("Remove")) { care.removeStartup(item) }, secondaryButton: .cancel())
        }
    }

    // MARK: Cleaner

    private var cleaner: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                HStack(spacing: 14) {
                    bigIcon("sparkles", Theme.mint)
                    VStack(alignment: .leading, spacing: 3) {
                        if care.isCleaning {
                            Text("Looking through \(care.cleanStep ?? "")…").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            Text("This takes a moment on a full disk.").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        } else if care.cleanScanned {
                            Text("\(Format.bytes(care.cleanTotal)) found").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            Text("Caches, logs, and developer files are ticked. Your own files never are.").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        } else {
                            Text("Find space to free").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            Text("Caches, logs, developer files, installers, old downloads, and big files. Nothing is removed until you choose.")
                                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if care.isCleaning { ProgressView().controlSize(.small) } else {
                        Button(care.cleanScanned ? "Scan again" : "Scan") { care.scanCleaner() }
                            .buttonStyle(care.cleanScanned ? AnyButtonStyle(SecondaryButtonStyle()) : AnyButtonStyle(PrimaryButtonStyle()))
                    }
                }
            }
            ForEach(CleanGroup.allCases, id: \.self) { group in
                if let items = care.cleanGroups[group], !items.isEmpty { CleanGroupCard(group: group, items: items, care: care) }
            }
            if care.cleanScanned && care.cleanTotal == 0 {
                Text("Nothing to clean right now.").font(.system(size: 13)).foregroundStyle(Theme.textSecondary).padding(.leading, 2)
            }
        }
    }

    // MARK: Duplicates

    private var duplicates: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        bigIcon("doc.on.doc", Theme.violet)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(care.isFindingDups ? "Checked \(care.dupChecked) files…" : "Find files saved more than once")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            Text("Files count as copies only when every byte is the same, not just the name.")
                                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button(care.isFindingDups ? "Stop" : (care.dupScanned ? "Search again" : "Search")) { care.findDuplicates() }
                            .buttonStyle(care.isFindingDups || care.dupScanned ? AnyButtonStyle(SecondaryButtonStyle()) : AnyButtonStyle(PrimaryButtonStyle()))
                            .disabled(care.dupFolders.isEmpty)
                    }
                    SectionLabel("Look in")
                    WrapLayout(spacing: 6) {
                        ForEach(MacCareModel.folderChoices, id: \.self) { name in
                            let url = care.home.appendingPathComponent(name)
                            chip(name, on: care.dupFolders.contains(url)) { care.toggleFolder(url) }
                        }
                        ForEach(care.dupFolders.filter { url in !MacCareModel.folderChoices.contains { care.home.appendingPathComponent($0) == url } }, id: \.self) { url in
                            chip(url.lastPathComponent, on: true) { care.toggleFolder(url) }
                        }
                        chip("Add folder…", on: false, icon: "plus") { care.addFolder() }
                    }
                    HStack(spacing: 6) {
                        Text("Skip files under").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        ForEach([(Int64(100_000), "100 KB"), (1_000_000, "1 MB"), (10_000_000, "10 MB")], id: \.0) { value, label in
                            chip(label, on: care.dupMinimum == value) { care.dupMinimum = value }
                        }
                    }
                }
            }
            if care.dupScanned && care.dupGroups.isEmpty {
                Text("No copies found.").font(.system(size: 13)).foregroundStyle(Theme.textSecondary).padding(.leading, 2)
            }
            if !care.dupGroups.isEmpty {
                let wasted = care.dupGroups.reduce(0) { $0 + $1.wasted }
                SectionLabel("\(care.dupGroups.count) files with copies · \(Format.bytes(wasted)) in extra copies")
            }
            ForEach(care.dupGroups.prefix(150)) { group in DuplicateCard(group: group, care: care) }
        }
    }

    // MARK: Uninstall

    @ViewBuilder
    private var uninstall: some View {
        if let app = care.chosenApp {
            AppUninstallCard(app: app, care: care) { care.confirm = .uninstall(app) }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    DyskField(icon: "magnifyingglass", placeholder: "Search apps", text: $care.appQuery)
                    chip("Name", on: !care.sortBySize) { care.sortBySize = false }
                    chip("Size", on: care.sortBySize) { care.sortBySize = true }
                }
                Text("Apps from Apple and DyskLink itself aren't listed.").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                Card(padding: 6) {
                    VStack(spacing: 0) {
                        ForEach(care.shownApps) { app in
                            AppRow(app: app) { care.choose(app) }
                            if app.id != care.shownApps.last?.id { Divider().overlay(Theme.stroke).padding(.leading, 52) }
                        }
                        if care.shownApps.isEmpty {
                            Text(care.isLoadingApps ? "Loading apps…" : "No apps match.")
                                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).padding(14)
                        }
                    }
                }
            }
        }
    }

    // MARK: Startup

    private var startup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                HStack(spacing: 14) {
                    bigIcon("person.crop.circle.badge.checkmark", Theme.mint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Login items").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text("Apps that open when you log in are set in System Settings. macOS doesn't let other apps change that list.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Open") { care.openLoginItems() }.buttonStyle(SecondaryButtonStyle())
                }
            }
            if let error = care.startupError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.coral)
            }
            let mine = care.startupItems.filter { $0.scope == .user }
            SectionLabel("Your background agents")
            Text("Small programs apps set to run in the background for your account. Turning one off stops it now and at the next login; turn it back on any time.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Card(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(mine) { item in
                        StartupRow(item: item, editable: true,
                                   onToggle: { care.setStartup(item, on: $0) },
                                   onRemove: { care.confirm = .startup(item) },
                                   onReveal: { care.reveal(item.url) })
                        if item.id != mine.last?.id { Divider().overlay(Theme.stroke).padding(.leading, 52) }
                    }
                    if mine.isEmpty {
                        Text("None.").font(.system(size: 13)).foregroundStyle(Theme.textSecondary).padding(14)
                    }
                }
            }
            let system = care.startupItems.filter { $0.scope != .user }
            if !system.isEmpty {
                SectionLabel("For all users")
                Text("Installed for every account, and some run as the system. Changing these needs an administrator, so they're shown here to check. Uninstall the app they belong to, or open its settings.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                Card(padding: 6) {
                    VStack(spacing: 0) {
                        ForEach(system) { item in
                            StartupRow(item: item, editable: false, onToggle: { _ in }, onRemove: {}, onReveal: { care.reveal(item.url) })
                            if item.id != system.last?.id { Divider().overlay(Theme.stroke).padding(.leading, 52) }
                        }
                    }
                }
            }
        }
    }

    // MARK: Small parts

    // MARK: Battery

    @ViewBuilder
    private var batteryTab: some View {
        if care.battery != nil {
            VStack(alignment: .leading, spacing: 12) {
                ChargeControlCard(control: ChargeControl.shared)
                PowerSettingsCard(power: PowerSettings.shared, nativeLimit: ChargeControl.shared.nativeLimit)
                batteryHistoryCard
            }
        } else {
            Card {
                HStack(spacing: 14) {
                    bigIcon("powerplug", Theme.textSecondary)
                    Text(care.hasBattery ? "Reading the battery…" : "This Mac has no battery.")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
            }
        }
    }

    private var batteryHistoryCard: some View {
        let days = Array(care.batteryHistory.suffix(60))
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("History").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if let first = days.first, let last = days.last, days.count > 1 {
                        Text("\(first.health)% → \(last.health)% · \(last.cycles - first.cycles) cycles")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                }
                if days.count < 2 {
                    Text("One point is saved each day DyskLink runs, so changes show up over weeks and months.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    let low = max(0, (days.map(\.health).min() ?? 0) - 3)
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(days, id: \.day) { day in
                            RoundedRectangle(cornerRadius: 2).fill(Theme.mint.opacity(0.75))
                                .frame(height: max(4, CGFloat(day.health - low) / CGFloat(max(1, 100 - low)) * 70))
                                .help("\(day.day): \(day.health)%, \(day.cycles) cycles")
                        }
                    }
                    .frame(height: 70, alignment: .bottom)
                    HStack {
                        Text(days.first?.day ?? "").font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(days.last?.day ?? "").font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).frame(width: 118, alignment: .leading)
            Text(value).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
        }
    }

    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    static func heatNote(_ celsius: Double?) -> String {
        guard let celsius else { return "Not available" }
        return celsius >= 40 ? "Warm. Charging slows down" : celsius >= 35 ? "A little warm" : "Normal"
    }

    private func bigIcon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 18, weight: .semibold)).foregroundStyle(color)
            .frame(width: 42, height: 42)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func chip(_ title: String, on: Bool, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(on ? Theme.ink : Theme.textSecondary)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(on ? Theme.mint : Theme.panelRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Color.clear : Theme.stroke))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Lets one button switch between the primary and secondary look.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

private struct Tick: View {
    let on: Bool
    var enabled = true

    var body: some View {
        Image(systemName: on ? "checkmark.square.fill" : "square")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(on ? Theme.mint : Theme.textFaint)
            .opacity(enabled ? 1 : 0.35)
    }
}

private struct CleanGroupCard: View {
    let group: CleanGroup
    let items: [CareItem]
    @Bindable var care: MacCareModel
    private var showsAll: Bool { care.expandedGroups.contains(group) }

    var body: some View {
        let total = items.reduce(0) { $0 + $1.size }
        let allOn = items.allSatisfy { care.cleanSelected.contains($0.id) }
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Button {
                        if allOn { care.cleanSelected.subtract(items.map(\.id)) } else { care.cleanSelected.formUnion(items.map(\.id)) }
                    } label: { Tick(on: allOn) }.buttonStyle(.plain).help(allOn ? "Untick all" : "Tick all")
                    Image(systemName: group.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.mint).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text(group.detail).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Format.bytes(total)).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(Theme.textPrimary)
                        Text("\(items.count) item\(items.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(showsAll ? items : Array(items.prefix(5))) { item in
                        CareRow(item: item, on: care.cleanSelected.contains(item.id),
                                toggle: { care.cleanSelected.formSymmetricDifference([item.id]) },
                                reveal: { care.reveal(item.url) })
                    }
                }
                .padding(.leading, 28)
                if items.count > 5 {
                    Button(showsAll ? "Show fewer" : "Show all \(items.count)") { care.expandedGroups.formSymmetricDifference([group]) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mint).padding(.leading, 30)
                }
            }
        }
    }
}

private struct CareRow: View {
    let item: CareItem
    let on: Bool
    var enabled = true
    var badge: String?
    var badgeColor: Color = Theme.mint
    let toggle: () -> Void
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) { Tick(on: on, enabled: enabled) }.buttonStyle(.plain)
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                    if let badge {
                        Text(badge).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 6).padding(.vertical, 1.5).background(badgeColor, in: Capsule())
                    }
                }
                if !item.detail.isEmpty {
                    Text(item.detail).font(.system(size: 11)).foregroundStyle(Theme.textFaint).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(Format.bytes(item.size)).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textSecondary)
            IconButton(icon: "magnifyingglass", help: "Show in Finder", action: reveal)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}

private struct DuplicateCard: View {
    let group: DuplicateGroup
    @Bindable var care: MacCareModel

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(group.files.first?.name ?? "").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer()
                    Text("\(group.files.count) copies · \(Format.bytes(group.size)) each")
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
                ForEach(group.files) { file in
                    let on = care.dupSelected.contains(file.id)
                    let othersKept = group.files.contains { $0.id != file.id && !care.dupSelected.contains($0.id) }
                    CareRow(item: CareItem(url: file.url, size: file.size,
                                           detail: MacCare.shortPath(file.url.deletingLastPathComponent(), home: care.home)
                                               + (file.date.map { " · created " + MacCare.ago($0) } ?? ""), date: file.date),
                            on: on, enabled: on || othersKept, badge: on ? nil : "Keep",
                            toggle: { care.toggleDuplicate(file, in: group) },
                            reveal: { care.reveal(file.url) })
                }
            }
        }
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(app.version.isEmpty ? app.bundleId : "Version \(app.version)").font(.system(size: 11)).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
            Spacer()
            Text(app.size.map(Format.bytes) ?? "…").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textSecondary)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}

private struct AppUninstallCard: View {
    let app: InstalledApp
    @Bindable var care: MacCareModel
    let onUninstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { care.choose(nil) } label: {
                Label("All apps", systemImage: "chevron.left").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 52, height: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.textPrimary)
                            Text([app.version.isEmpty ? nil : "Version \(app.version)", app.bundleId].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                            Text(MacCare.shortPath(app.url.deletingLastPathComponent(), home: care.home))
                                .font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(Format.bytes(care.uninstallSize)).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(Theme.textPrimary)
                            Text("to free").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                        }
                    }
                    if care.isRunning(app) {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
                            Text("\(app.name) is open. Quit it before uninstalling.").font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Button("Quit \(app.name)") { care.quit(app) }.buttonStyle(SecondaryButtonStyle())
                        }
                        .padding(10)
                        .background(Theme.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    HStack {
                        Spacer()
                        Button(action: onUninstall) { Label("Uninstall", systemImage: "trash") }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(care.isRunning(app))
                            .opacity(care.isRunning(app) ? 0.5 : 1)
                    }
                }
            }
            SectionLabel("Files it left in your Library")
            Text("Settings, caches, and saved data. The ticked ones carry the app's ID, so they surely belong to it. Ones that only share its name are left for you to check.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Card(padding: 10) {
                VStack(spacing: 0) {
                    ForEach(care.leftovers) { leftover in
                        CareRow(item: leftover.item, on: care.leftoverSelected.contains(leftover.id),
                                badge: leftover.byId ? nil : "Same name", badgeColor: Theme.amber,
                                toggle: { care.leftoverSelected.formSymmetricDifference([leftover.id]) },
                                reveal: { care.reveal(leftover.item.url) })
                    }
                    if care.leftovers.isEmpty {
                        Text("None found.").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                }
            }
        }
    }
}

private struct StartupRow: View {
    let item: StartupItem
    let editable: Bool
    let onToggle: (Bool) -> Void
    let onRemove: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let app = item.appName, let path = item.program.range(of: app + ".app").map({ String(item.program[..<$0.upperBound]) }) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
                } else {
                    Image(systemName: item.scope == .daemon ? "gearshape.2" : "gearshape").font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.appName ?? item.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(item.isOff ? Theme.textSecondary : Theme.textPrimary).lineLimit(1)
                    if item.scope == .daemon { tag("System") }
                    if item.keepsAlive { tag("Always running") } else if item.runsAtLoad { tag("At login") }
                }
                Text(item.appName == nil ? item.program : item.label).font(.system(size: 11)).foregroundStyle(Theme.textFaint).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            IconButton(icon: "magnifyingglass", help: "Show in Finder", action: onReveal)
            if editable {
                IconButton(icon: "trash", help: "Remove", tint: Theme.coral, action: onRemove)
                Toggle("", isOn: Binding(get: { !item.isOff }, set: onToggle)).labelsHidden().toggleStyle(.dyskSwitch).fixedSize()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6).padding(.vertical, 1.5).background(Theme.panelRaised, in: Capsule())
    }
}
