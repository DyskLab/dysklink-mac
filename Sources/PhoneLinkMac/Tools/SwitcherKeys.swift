import CoreGraphics
import Foundation
import os

private let log = Logger(subsystem: "id.dysklink.mac", category: "Windows")

enum SwitcherCommand: Equatable {
    case forward, back, commit, cancel
}

/// Decides what a key press does. Keys are only looked at here, never stored or sent anywhere.
enum SwitcherKeys {
    struct Result: Equatable {
        var command: SwitcherCommand?
        var swallows: Bool

        static let pass = Result(command: nil, swallows: false)
    }

    static func result(keyCode: Int64, flags: CGEventFlags, isOpen: Bool) -> Result {
        let isTab = keyCode == 48
        if isTab, flags.contains(.maskAlternate), !flags.contains(.maskCommand), !flags.contains(.maskControl) {
            if !flags.contains(.maskShift) { return Result(command: .forward, swallows: true) }
            // Option + Shift + Tab only goes backward once the list is open. Before that it belongs to the app.
            return isOpen ? Result(command: .back, swallows: true) : .pass
        }
        guard isOpen else { return .pass }
        switch keyCode {
        case 53: return Result(command: .cancel, swallows: true)
        case 36, 76: return Result(command: .commit, swallows: true)
        case 123, 126: return Result(command: .back, swallows: true)
        case 124, 125: return Result(command: .forward, swallows: true)
        default: return Result(command: nil, swallows: true)
        }
    }

    /// Letting go of Option chooses the window, like letting go of Command in Command + Tab.
    static func releaseCommits(flags: CGEventFlags, isOpen: Bool) -> Bool {
        isOpen && !flags.contains(.maskAlternate)
    }
}

/// Catches Option + Tab before the app in front sees it. Needs Accessibility.
final class SwitcherTap: @unchecked Sendable {
    static let shared = SwitcherTap()

    private let lock = NSLock()
    private var tap: CFMachPort?
    private var loop: CFRunLoop?
    private var isOpen = false
    private var handler: (@MainActor (SwitcherCommand) -> Void)?

    /// Returns false until Accessibility allows the tap.
    func start(handler: @escaping @MainActor (SwitcherCommand) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
        if tap != nil { return true }
        // Modifier changes too, so letting go of Option is seen at once instead of polling for it.
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, _ in
                SwitcherTap.shared.handle(type, event) ? Unmanaged.passUnretained(event) : nil
            }, userInfo: nil
        ) else {
            log.error("Switcher tap wasn't allowed")
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
        thread.name = "DyskLink window switcher"
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
        handler = nil
        isOpen = false
    }

    func setOpen(_ value: Bool) {
        lock.lock()
        isOpen = value
        lock.unlock()
    }

    /// Returns false when the key was used here and shouldn't reach any app.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        lock.lock()
        let port = tap
        let open = isOpen
        let handler = handler
        lock.unlock()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return true
        }
        if type == .flagsChanged {
            // Modifier keys always reach the apps; only the release is noted.
            if SwitcherKeys.releaseCommits(flags: event.flags, isOpen: open), let handler {
                DispatchQueue.main.async { MainActor.assumeIsolated { handler(.commit) } }
            }
            return true
        }
        guard type == .keyDown else { return true }
        let result = SwitcherKeys.result(keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags, isOpen: open)
        if let command = result.command, let handler {
            DispatchQueue.main.async { MainActor.assumeIsolated { handler(command) } }
        }
        return !result.swallows
    }
}
