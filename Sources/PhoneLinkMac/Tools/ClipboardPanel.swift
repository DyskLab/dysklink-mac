import AppKit
import Observation
import SwiftUI

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
@Observable
final class ClipboardPanelState {
    var query = ""
    var selection = 0
}

/// A floating list that doesn't activate DyskLink, so the app being typed in stays in front
/// and can receive the paste.
@MainActor
enum ClipboardPanel {
    private static var panel: NSPanel?
    private static var keyMonitor: Any?
    private static var resignObserver: NSObjectProtocol?
    private static let state = ClipboardPanelState()

    static func toggle(_ history: ClipboardHistory) {
        if panel != nil { close() } else { show(history) }
    }

    static func show(_ history: ClipboardHistory) {
        state.query = ""
        state.selection = 0
        let size = NSSize(width: 540, height: 460)
        let panel = KeyPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ClipboardPanelView(history: history, state: state, onChoose: { choose($0, history) }))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2 + 60))
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event, history) ? nil : event }
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

    private static func handle(_ event: NSEvent, _ history: ClipboardHistory) -> Bool {
        let list = history.matches(state.query)
        let selected = list.indices.contains(state.selection) ? list[state.selection] : nil
        let command = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case 53: close()
        case 36, 76: if let selected { choose(selected, history) }
        case 126: state.selection = max(state.selection - 1, 0)
        case 125: state.selection = min(state.selection + 1, max(list.count - 1, 0))
        case 51:
            if command {
                if let selected { history.delete(selected) }
                state.selection = min(state.selection, max(list.count - 2, 0))
            } else if !state.query.isEmpty {
                state.query.removeLast()
                state.selection = 0
            }
        default:
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if command {
                if key == "p", let selected { history.togglePin(selected) }
                if key == "o", let selected, let name = selected.imageFile { readText(name, history) }
                if let digit = Int(key), (1...9).contains(digit), list.indices.contains(digit - 1) {
                    choose(list[digit - 1], history)
                }
            } else if !event.modifierFlags.contains(.control), let typed = event.characters,
                      let first = typed.unicodeScalars.first, first.value >= 32, first.value != 127 {
                state.query += typed
                state.selection = 0
            }
        }
        return true
    }

    private static func choose(_ entry: ClipEntry, _ history: ClipboardHistory) {
        history.copy(entry)
        close()
        guard DeviceInput.isTrusted else {
            return HintToast.show("Copied. Allow Accessibility to paste automatically")
        }
        // The other app needs a moment to take the keyboard back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let source = CGEventSource(stateID: .combinedSessionState)
            for isDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: isDown)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    private static func readText(_ name: String, _ history: ClipboardHistory) {
        close()
        let file = history.imageURL(name)
        Task.detached(priority: .userInitiated) {
            let text = TextRecognizer.recognize(file: file)
            await MainActor.run { TextCapture.deliver(text, to: history) }
        }
    }
}

struct ClipboardPanelView: View {
    let history: ClipboardHistory
    let state: ClipboardPanelState
    let onChoose: (ClipEntry) -> Void
    var scrolls = true

    var body: some View {
        let list = history.matches(state.query)
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textFaint)
                Text(state.query.isEmpty ? "Type to search" : state.query)
                    .foregroundStyle(state.query.isEmpty ? Theme.textFaint : Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text("\(list.count)").foregroundStyle(Theme.textFaint)
            }
            .font(.system(size: 14, weight: .medium))
            .padding(14)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            if list.isEmpty {
                Text(state.query.isEmpty ? "Nothing copied yet" : "No matches")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    OptionalScroll(enabled: scrolls) {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, entry in
                                row(entry, index: index).id(entry.id)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: state.selection) { _, selection in
                        if list.indices.contains(selection) { proxy.scrollTo(list[selection].id) }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
            }
            Rectangle().fill(Theme.stroke).frame(height: 1)
            Text("Return paste  ·  ⌘P pin  ·  ⌘⌫ delete  ·  ⌘O read image text  ·  Esc close")
                .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                .padding(10)
        }
        .frame(width: 540, height: 460)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
        .preferredColorScheme(.dark)
    }

    private func row(_ entry: ClipEntry, index: Int) -> some View {
        HStack(spacing: 10) {
            if let name = entry.imageFile {
                if let image = history.thumbnail(name) {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(width: 58, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                Text("Image").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            } else {
                Text(entry.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                    .font(.system(size: 13)).foregroundStyle(Theme.textPrimary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if entry.isPinned {
                Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(Theme.mint)
            }
            if index < 9 {
                Text("⌘\(index + 1)").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textFaint)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(index == state.selection ? Theme.panelRaised : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onChoose(entry) }
    }
}

/// A short message near the top of the screen that can't take focus or clicks.
@MainActor
enum HintToast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String) {
        hideWork?.cancel()
        panel?.orderOut(nil)
        let view = NSHostingView(rootView: Text(message)
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(Theme.panelRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke))
            .fixedSize()
            .preferredColorScheme(.dark))
        let size = view.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view
        if let area = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 40))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        let work = DispatchWorkItem { MainActor.assumeIsolated { HintToast.panel?.orderOut(nil); HintToast.panel = nil } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}
