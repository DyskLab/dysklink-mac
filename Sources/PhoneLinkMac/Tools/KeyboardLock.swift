import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Observation
import os
import SwiftUI

private let log = Logger(subsystem: "id.dysklink.mac", category: "KeyboardLock")

/// Decides what happens to a key while the keyboard is locked. Keys are only looked at here, never stored or sent.
enum KeyboardLockKeys {
    static let unlockKeyCode = Int64(kVK_ANSI_U)
    static let unlockLabel = "Control + Option + Command + U"
    /// NX_SYSDEFINED: media, volume, and brightness keys arrive as this, with subtype 8.
    static let systemDefined: UInt32 = 14
    static let auxKeysSubtype: Int16 = 8

    static func isUnlock(keyCode: Int64, flags: CGEventFlags) -> Bool {
        keyCode == unlockKeyCode && flags.contains(.maskControl) && flags.contains(.maskAlternate) && flags.contains(.maskCommand)
    }

    /// Whether an event still reaches apps while locked. Input DyskLink posts itself, for a phone or another
    /// computer controlling this Mac, always does; only this Mac's own keys are held back.
    static func passes(type: UInt32, isOwn: Bool, subtype: Int16?) -> Bool {
        if isOwn { return true }
        switch type {
        case CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue: return false
        case systemDefined: return subtype != auxKeysSubtype
        default: return true
        }
    }

    static var mask: CGEventMask {
        [CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue, systemDefined]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
    }
}

/// The tap that holds the keys back, on a thread of its own so a busy main thread never makes macOS drop it.
/// Needs Accessibility. It exists only while the keyboard is locked.
final class KeyboardLockTap: @unchecked Sendable {
    static let shared = KeyboardLockTap()
    private static let ownPid = Int64(ProcessInfo.processInfo.processIdentifier)

    private let lock = NSLock()
    private var tap: CFMachPort?
    private var loop: CFRunLoop?
    private var modifiers: CGEventFlags = []
    private var onUnlock: (@MainActor () -> Void)?

    /// Returns false when macOS doesn't allow the tap.
    func start(onUnlock: @escaping @MainActor () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        self.onUnlock = onUnlock
        if tap != nil { return true }
        modifiers = []
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: KeyboardLockKeys.mask,
            callback: { _, type, event, _ in
                KeyboardLockTap.shared.handle(type, event) ? Unmanaged.passUnretained(event) : nil
            }, userInfo: nil
        ) else {
            log.error("Keyboard lock tap wasn't allowed")
            return false
        }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let thread = Thread { [weak self] in
            self?.lock.lock()
            self?.loop = CFRunLoopGetCurrent()
            self?.lock.unlock()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "DyskLink keyboard lock"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let loop { CFRunLoopStop(loop) }
        tap = nil
        loop = nil
        onUnlock = nil
    }

    /// Returns false when the event is held back.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        lock.lock()
        let port = tap
        let onUnlock = onUnlock
        lock.unlock()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return true
        }
        guard port != nil else { return true }
        let isOwn = event.getIntegerValueField(.eventSourceUnixProcessID) == Self.ownPid
        if type == .flagsChanged, !isOwn {
            lock.lock()
            modifiers = event.flags
            lock.unlock()
        }
        if type == .keyDown, !isOwn {
            lock.lock()
            let held = modifiers
            lock.unlock()
            // The modifiers' own events are held back, so what was last seen of them counts too.
            let flags = event.flags.union(held)
            if KeyboardLockKeys.isUnlock(keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: flags), let onUnlock {
                DispatchQueue.main.async { MainActor.assumeIsolated { onUnlock() } }
                return false
            }
        }
        let subtype: Int16? = type.rawValue == KeyboardLockKeys.systemDefined ? NSEvent(cgEvent: event).map { $0.subtype.rawValue } : nil
        return KeyboardLockKeys.passes(type: type.rawValue, isOwn: isOwn, subtype: subtype)
    }
}

/// Locks this Mac's keyboard for a while, for cleaning it or with a cat or a child about. The mouse and trackpad
/// keep working, so the Unlock button is always there; the keys unlock it, the time runs out, a phone can unlock it,
/// and it unlocks when the Mac locks or sleeps. Nothing in the system changes: quitting DyskLink ends it too.
@MainActor
@Observable
final class KeyboardLock {
    static let durations: [(minutes: Int, label: String)] = [
        (1, "1 minute"), (5, "5 minutes"), (15, "15 minutes"), (30, "30 minutes"), (60, "1 hour"), (0, "Until I unlock it"),
    ]
    static let commandID = "keyboard:unlock"

    var minutes: Int { didSet { UserDefaults.standard.set(minutes, forKey: "keyboardLock.minutes") } }
    private(set) var isLocked = false
    private(set) var endsAt: Date?
    private(set) var now = Date()
    private(set) var problem: String?
    /// Told when the lock starts or ends, so phones get the Unlock command only while it's needed.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        minutes = UserDefaults.standard.object(forKey: "keyboardLock.minutes") as? Int ?? 5
    }

    var lengthLabel: String { Self.durations.first { $0.minutes == minutes }?.label ?? "5 minutes" }

    var remainingText: String {
        guard let endsAt else { return "Until you unlock it" }
        let seconds = Int(max(0, endsAt.timeIntervalSince(now)).rounded(.up))
        return String(format: "%d:%02d left", seconds / 60, seconds % 60)
    }

    func lock() {
        guard !isLocked else { return }
        guard DeviceInput.isTrusted else {
            problem = "Locking the keyboard needs Accessibility for DyskLink in Privacy & Security."
            return
        }
        guard KeyboardLockTap.shared.start(onUnlock: { [weak self] in self?.unlock() }) else {
            problem = "macOS didn't allow it. Check Accessibility for DyskLink in Privacy & Security."
            return
        }
        problem = nil
        isLocked = true
        now = Date()
        endsAt = minutes > 0 ? now.addingTimeInterval(TimeInterval(minutes * 60)) : nil
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        watchSessionEnd()
        KeyboardLockPanel.show(self)
        log.info("Keyboard locked")
        onChange?()
    }

    func unlock() {
        guard isLocked else { return }
        KeyboardLockTap.shared.stop()
        timer?.invalidate()
        timer = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        isLocked = false
        endsAt = nil
        KeyboardLockPanel.close()
        log.info("Keyboard unlocked")
        onChange?()
    }

    func toggle() { if isLocked { unlock() } else { lock() } }

    private func tick() {
        now = Date()
        if let endsAt, now >= endsAt { unlock() }
    }

    /// The keys must work for the password, so locking the screen or sleeping ends the lock.
    private func watchSessionEnd() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let end: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.unlock() }
        }
        observers = [
            (workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: end)),
            (workspace, workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: end)),
            (distributed, distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: end)),
        ]
    }

    // MARK: Phone

    /// The phone's Commands list gets "Unlock the keyboard" while it's locked.
    var commands: [CommandItem] {
        isLocked ? [CommandItem(id: Self.commandID, name: "Unlock the keyboard")] : []
    }

    func runCommand(_ id: String) -> String? {
        guard id == Self.commandID else { return nil }
        guard isLocked else { return "The keyboard isn't locked." }
        unlock()
        return "The keyboard is unlocked."
    }
}

/// A small window that stays on top while the keyboard is locked, with the time left and an Unlock button.
/// It never takes the focus.
@MainActor
enum KeyboardLockPanel {
    private static var panel: NSPanel?

    static func show(_ lock: KeyboardLock) {
        close()
        let host = NSHostingView(rootView: KeyboardLockBadge(lock: lock))
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        let mouse = NSEvent.mouseLocation
        if let area = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 80))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    static func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct KeyboardLockBadge: View {
    let lock: KeyboardLock

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard.badge.ellipsis")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.coral)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyboard locked").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    Text(lock.remainingText).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button { lock.unlock() } label: {
                    Text("Unlock")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .frame(width: 78, height: 28)
                        .background(Theme.mint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("Or press \(KeyboardLockKeys.unlockLabel). The mouse and trackpad still work.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
        .dyskAppearance()
    }
}
