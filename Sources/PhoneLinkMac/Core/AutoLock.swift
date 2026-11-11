import AppKit
import CoreGraphics

/// Locks the Mac when the chosen phone has been gone for a while.
/// "Gone" means its connection closed and didn't come back, so Wi-Fi blips within the delay don't lock.
enum AutoLock {
    static let delays = [30, 60, 120, 300]
    static let defaultDelay = 60

    /// Whether to lock when the wait ends.
    static func shouldLock(phoneConnected: Bool, screenLocked: Bool, macOnline: Bool) -> Bool {
        // When the Mac itself has no network, every phone looks gone, so that doesn't count.
        !phoneConnected && !screenLocked && macOnline
    }

    static var isScreenLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    static func label(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) sec" : seconds == 60 ? "1 min" : "\(seconds / 60) min"
    }
}
