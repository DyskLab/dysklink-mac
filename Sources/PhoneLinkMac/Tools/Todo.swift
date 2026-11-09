import AppKit
import Observation
import SwiftUI

struct TodoItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var createdAt: Date
    var doneAt: Date?

    var isDone: Bool { doneAt != nil }
}

/// The list and its rules, without saving or screens, so they can be tested on their own.
struct TodoList: Equatable {
    static let maxTitle = 80
    static let maxItems = 50

    var items: [TodoItem] = []

    /// Returns false when the text is empty or the list is full.
    @discardableResult
    mutating func add(_ text: String, at now: Date) -> Bool {
        let title = String(text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? "").prefix(Self.maxTitle)
        guard !title.isEmpty, items.count < Self.maxItems else { return false }
        items.append(TodoItem(title: String(title), createdAt: now))
        return true
    }

    mutating func toggle(_ id: UUID, at now: Date) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].doneAt = items[index].isDone ? nil : now
    }

    mutating func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    mutating func clearDone() {
        items.removeAll(where: \.isDone)
    }

    /// Tasks finished on an earlier day are dropped, so the list starts each day with what is still open.
    mutating func dropOld(now: Date, calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: now)
        items.removeAll { ($0.doneAt ?? .distantFuture) < start }
    }

    /// Open tasks in the order they were added, then what was finished today, newest first.
    func visible(now: Date, calendar: Calendar = .current) -> [TodoItem] {
        let open = items.filter { !$0.isDone }
        let done = items.filter { $0.isDone && calendar.isDate($0.doneAt!, inSameDayAs: now) }
            .sorted { $0.doneAt! > $1.doneAt! }
        return open + done
    }

    func doneToday(now: Date, calendar: Calendar = .current) -> Int {
        items.filter { $0.doneAt.map { calendar.isDate($0, inSameDayAs: now) } == true }.count
    }

    /// What is still open plus what was finished today.
    func totalToday(now: Date, calendar: Calendar = .current) -> Int {
        items.filter { !$0.isDone }.count + doneToday(now: now, calendar: calendar)
    }
}

@MainActor
@Observable
final class TodoModel {
    private(set) var list = TodoList()
    /// Shows a remove button on each task.
    var isEditing = false
    /// The text typed into the add box in Advanced.
    var draft = ""

    @ObservationIgnored private let file: URL
    @ObservationIgnored private let persists: Bool

    init(directory: URL, persists: Bool = true) {
        file = directory.appendingPathComponent("notch-todos.json")
        self.persists = persists
        if persists, let data = try? Data(contentsOf: file),
           let items = try? JSONDecoder().decode([TodoItem].self, from: data) {
            list.items = items
        }
        list.dropOld(now: Date())
    }

    func visible(_ now: Date) -> [TodoItem] { list.visible(now: now) }
    func doneToday(_ now: Date) -> Int { list.doneToday(now: now) }
    func totalToday(_ now: Date) -> Int { list.totalToday(now: now) }

    @discardableResult
    func add(_ text: String) -> Bool {
        let added = list.add(text, at: Date())
        if added { save() }
        return added
    }

    func addDraft() {
        if add(draft) { draft = "" }
    }

    func toggle(_ id: UUID) {
        list.toggle(id, at: Date())
        save()
    }

    func delete(_ id: UUID) {
        list.delete(id)
        if list.items.isEmpty { isEditing = false }
        save()
    }

    func clearDone() {
        list.clearDone()
        save()
    }

    private func save() {
        guard persists else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(list.items), (try? data.write(to: file, options: .atomic)) != nil
        else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    #if DEBUG
    func loadForSnapshot(_ titles: [(String, Bool)], now: Date) {
        list = TodoList()
        for (title, done) in titles {
            list.add(title, at: now)
            if done, let id = list.items.last?.id { list.toggle(id, at: now) }
        }
    }
    #endif
}

// MARK: Quick add

@MainActor
@Observable
final class TodoQuickAddState {
    var text = ""
}

private final class TodoKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A small box for typing a task. The notch itself can't take typing, because it never becomes the key window.
@MainActor
enum TodoQuickAdd {
    private static var panel: NSPanel?
    private static var keyMonitor: Any?
    private static var resignObserver: NSObjectProtocol?
    private static let state = TodoQuickAddState()

    static func show(_ todos: TodoModel) {
        guard panel == nil else { return }
        state.text = ""
        let size = NSSize(width: 440, height: 74)
        let panel = TodoKeyPanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above the notch panel, which sits just over the menu bar, so the box is never covered by it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 5)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: TodoQuickAddView(state: state))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            // Below the open notch, which reaches about 260 points down from the top of the screen.
            let top = min(area.maxY - 40, (screen?.frame.maxY ?? area.maxY) - 290)
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: max(area.minY, top - size.height)))
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event, todos) ? nil : event }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { _ in
            MainActor.assumeIsolated { close() }
        }
    }

    static func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private static func handle(_ event: NSEvent, _ todos: TodoModel) -> Bool {
        switch Int(event.keyCode) {
        case 53:
            close()
        case 36, 76:
            if todos.add(state.text) { close() } else if state.text.trimmingCharacters(in: .whitespaces).isEmpty { close() }
        case 51:
            if !state.text.isEmpty { state.text.removeLast() }
        default:
            if event.modifierFlags.contains(.command) {
                if event.charactersIgnoringModifiers == "v", let pasted = NSPasteboard.general.string(forType: .string) {
                    state.text = String((state.text + (pasted.components(separatedBy: .newlines).first ?? "")).prefix(TodoList.maxTitle))
                }
            } else if !event.modifierFlags.contains(.control), let typed = event.characters,
                      let first = typed.unicodeScalars.first, first.value >= 32, first.value != 127,
                      state.text.count < TodoList.maxTitle {
                state.text += typed
            }
        }
        return true
    }
}

struct TodoQuickAddView: View {
    let state: TodoQuickAddState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill").font(.system(size: 18)).foregroundStyle(Color(hex: 0x62D17A))
                Text(state.text.isEmpty ? "New task" : state.text + "▏")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(state.text.isEmpty ? Color.white.opacity(0.4) : Color.white)
                    .lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
            }
            Text("Return to add · Esc to cancel").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.45))
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(width: 440, height: 74, alignment: .leading)
        .background(Color.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .preferredColorScheme(.dark)
    }
}
