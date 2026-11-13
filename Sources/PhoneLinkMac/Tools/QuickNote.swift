import AppKit
import SwiftUI

/// One short note shared by the notch and the phones, for an address, a number, or a shopping list.
/// The Mac keeps it. Phones send `note.set`, and the newest text wins.
@MainActor
@Observable
final class QuickNoteModel {
    static let maxLength = 4000

    private(set) var text = ""
    private(set) var updated: Date?

    @ObservationIgnored private let file: URL
    @ObservationIgnored private let persists: Bool
    @ObservationIgnored private var saveWork: DispatchWorkItem?

    private struct Stored: Codable {
        var text: String
        var updated: Date?
    }

    init(directory: URL, persists: Bool = true) {
        file = directory.appendingPathComponent("notch-note.json")
        self.persists = persists
        if persists, let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            text = stored.text
            updated = stored.updated
        }
    }

    func set(_ value: String, at date: Date = Date()) {
        let clipped = String(value.prefix(Self.maxLength))
        guard clipped != text else { return }
        text = clipped
        updated = date
        guard persists else { return }
        // Saved a moment after typing stops, not on every key.
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Writes a save that's still waiting, for quitting.
    func flush() {
        guard let work = saveWork else { return }
        work.cancel()
        saveWork = nil
        save()
    }

    func save() {
        guard persists, let data = try? JSONEncoder().encode(Stored(text: text, updated: updated)) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

extension NotchView {
    var notePage: some View {
        NotePanel(note: model.note, scrolls: scrolls)
    }
}

struct NotePanel: View {
    let note: QuickNoteModel
    var scrolls = true

    private static let yellow = Color(hex: 0xF5C451)

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "note.text").font(.system(size: 26)).foregroundStyle(Self.yellow)
                Text(note.updated.map { "Edited " + $0.formatted(.relative(presentation: .named)) } ?? "Same on your phones")
                    .font(.system(size: 11.5)).foregroundStyle(Color.white.opacity(0.5)).lineLimit(2)
                HStack(spacing: 8) {
                    pill("pencil", "Edit") { NoteEditor.show(note) }
                    pill("doc.on.doc", "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(note.text, forType: .string)
                    }
                    .opacity(note.text.isEmpty ? 0.4 : 1).disabled(note.text.isEmpty)
                }
            }
            .frame(width: 170, alignment: .leading)
            Group {
                if note.text.isEmpty {
                    VStack(spacing: 4) {
                        Text("No note yet").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.white)
                        Text("Press Edit, or write it on the phone").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if scrolls {
                    ScrollView { noteText }
                } else {
                    // Snapshots can't draw a scroll view.
                    noteText.frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture(count: 2) { NoteEditor.show(note) }
        }
    }

    private var noteText: some View {
        Text(note.text).font(.system(size: 13.5)).foregroundStyle(Color.white.opacity(0.92))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pill(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.white)
                .padding(.horizontal, 10).frame(height: 24)
                .background(Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A small window for writing the note. The notch can't take typing, because it never becomes the key window.
@MainActor
enum NoteEditor {
    private static var window: NSWindow?

    static func show(_ note: QuickNoteModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Quick note"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: NoteEditorView(note: note) { close() })
        window.center()
        if let screen = NSScreen.main?.visibleFrame {
            window.setFrameTopLeftPoint(NSPoint(x: screen.midX - 210, y: screen.maxY - 230))
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() {
        window?.close()
        window = nil
    }
}

struct NoteEditorView: View {
    let note: QuickNoteModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: Binding(get: { note.text }, set: { note.set($0) }))
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack {
                Text("Saved as you type, and sent to your phones.").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.escape, modifiers: []).buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 16).padding(.top, 34).padding(.bottom, 14)
        .frame(minWidth: 360, minHeight: 220)
        .background(Theme.panel)
        .dyskAppearance()
    }
}
