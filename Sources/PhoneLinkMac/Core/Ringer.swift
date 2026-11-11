import AppKit
import Foundation
import Observation

/// Plays a loud sound so a phone can find this Mac. It stops by itself after 30 seconds.
@MainActor
final class MacRinger {
    static let duration: TimeInterval = 30
    private(set) var isRinging = false
    /// Called when the sound ends, so the phone that asked can show that it stopped.
    var onStopped: (() -> Void)?
    private var timer: Timer?
    private var started = Date.distantPast
    private var alert: NSAlert?

    func start(from name: String) {
        guard !TestEnv.isDryRun else { return TestEnv.log("RING start") }
        started = Date()
        guard !isRinging else { return }
        isRinging = true
        play()
        let timer = Timer(timeInterval: 1.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Date().timeIntervalSince(self.started) > Self.duration { self.stop() } else { self.play() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        showAlert(name)
    }

    func stop() {
        if TestEnv.isDryRun { TestEnv.log("RING stop") }
        timer?.invalidate()
        timer = nil
        guard isRinging else { return }
        isRinging = false
        onStopped?()
        if let window = alert?.window, window.isVisible { NSApp.abortModal(); window.orderOut(nil) }
        alert = nil
    }

    private func play() {
        (NSSound(named: "Sosumi") ?? NSSound(named: "Glass"))?.play()
    }

    private func showAlert(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "\(name) is looking for this Mac"
        alert.informativeText = "Press Stop to end the sound."
        alert.addButton(withTitle: "Stop")
        self.alert = alert
        NSApp.activate(ignoringOtherApps: true)
        alert.runFloating { [weak self] in self?.stop() }
    }
}

private extension NSAlert {
    /// The app may have no window, so the alert floats on its own and closes when Stop is pressed.
    func runFloating(_ done: @escaping @MainActor () -> Void) {
        window.level = .floating
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                _ = self.runModal()
                done()
            }
        }
    }
}

/// Pauses whatever plays on the Mac when the phone rings, and plays it again when the call ends.
/// It only resumes what it paused itself.
@MainActor
@Observable
final class CallMusicPauser {
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "calls.pausesMusic") }
    }
    @ObservationIgnored private var pausedForCall = false

    init() {
        isEnabled = UserDefaults.standard.object(forKey: "calls.pausesMusic") as? Bool ?? true
    }

    /// Sounds that aren't music, like FaceTime ringing on the Mac too, or DyskLink's own notification.
    private static let ignored: Set<String> = [
        "com.apple.FaceTime", "com.apple.TelephonyUtilities", "com.apple.UserNotificationCenter",
        "com.apple.notificationcenterui", "id.dysklink.mac", "id.phonelink.mac",
    ]

    func handle(_ state: String) {
        switch state {
        case "ringing", "outgoing":
            guard isEnabled, !pausedForCall else { return }
            let playing = BrowserMedia.audibleApps().subtracting(Self.ignored)
            guard !playing.isEmpty else { return }
            pausedForCall = true
            DeviceInput.media("play_pause")
        case "ended", "missed":
            guard pausedForCall else { return }
            pausedForCall = false
            // A moment for the phone's audio to let go before the Mac plays again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { DeviceInput.media("play_pause") }
        default:
            break
        }
    }
}

/// Fixed actions a paired phone can ask for. Nothing here runs a command chosen by the phone.
enum MacActions {
    /// Locks the screen the same way Control + Command + Q does.
    static func lockScreen() {
        if TestEnv.isDryRun { return TestEnv.log("LOCK") }
        typealias Lock = @convention(c) () -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            // Without the private call, sleeping the display locks it when a password is required after sleep.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            try? process.run()
            return
        }
        _ = unsafeBitCast(symbol, to: Lock.self)()
    }
}
