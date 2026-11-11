import Foundation

/// Stops a device from guessing the six-digit code. Wrong codes count per device across prompts, so asking again
/// doesn't start over. After `Pairing.maxAttempts` wrong codes that device waits 60 s, then twice as long each time,
/// up to an hour. Many wrong codes from any devices close pairing for everyone for a while.
struct PairingGuard {
    enum Decision: Equatable {
        case allowed
        /// Dropped without an answer, such as a request repeated too quickly.
        case ignored
        /// Refused, with the reason for the other device.
        case refused(String)
    }

    static let firstCooldown: TimeInterval = 60
    static let maxCooldown: TimeInterval = 3600
    /// Wrong codes from all devices together within `globalWindow` that close pairing for `globalCooldown`.
    static let globalLimit = 15
    static let globalWindow: TimeInterval = 600
    static let globalCooldown: TimeInterval = 600
    /// A device's requests closer together than this are dropped.
    static let requestInterval: TimeInterval = 2

    private struct PeerState {
        var wrong = 0
        var lockouts = 0
        var until: Date?
        var lastRequest: Date?
    }

    private var peers: [String: PeerState] = [:]
    private var recentWrong: [Date] = []
    private(set) var globalUntil: Date?

    /// The cooldown after the given number of lockouts: 60 s, 120 s, 240 s, ..., at most an hour.
    static func cooldown(lockouts: Int) -> TimeInterval {
        guard lockouts > 0 else { return 0 }
        return min(maxCooldown, firstCooldown * pow(2, Double(min(lockouts - 1, 20))))
    }

    /// Whether a new `pair.request` from this device may open a prompt.
    mutating func admit(_ id: String, now: Date = Date()) -> Decision {
        if let until = globalUntil, now < until { return .refused(Self.waitText(until.timeIntervalSince(now))) }
        var state = peers[id] ?? PeerState()
        defer { peers[id] = state }
        if let until = state.until, now < until { return .refused(Self.waitText(until.timeIntervalSince(now))) }
        if let last = state.lastRequest, now.timeIntervalSince(last) < Self.requestInterval { return .ignored }
        state.lastRequest = now
        return .allowed
    }

    /// Counts a wrong code. True when this device, or every device, now has to wait.
    mutating func wrongCode(_ id: String, now: Date = Date()) -> Bool {
        recentWrong = recentWrong.filter { now.timeIntervalSince($0) < Self.globalWindow } + [now]
        var locked = false
        if recentWrong.count >= Self.globalLimit {
            globalUntil = now.addingTimeInterval(Self.globalCooldown)
            recentWrong = []
            locked = true
        }
        var state = peers[id] ?? PeerState()
        state.wrong += 1
        if state.wrong >= Pairing.maxAttempts {
            state.wrong = 0
            state.lockouts += 1
            state.until = now.addingTimeInterval(Self.cooldown(lockouts: state.lockouts))
            locked = true
        }
        peers[id] = state
        return locked
    }

    /// The right code was typed, so this device starts clean.
    mutating func succeeded(_ id: String) {
        peers[id] = nil
    }

    /// How long this device still has to wait, or nil.
    func waiting(_ id: String, now: Date = Date()) -> TimeInterval? {
        let ends = [globalUntil, peers[id]?.until].compactMap { $0 }.filter { $0 > now }
        return ends.max().map { $0.timeIntervalSince(now) }
    }

    static func waitText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes <= 1 ? "Too many wrong codes. Try again in a minute."
            : "Too many wrong codes. Try again in \(minutes) minutes."
    }
}

/// Whether a device is a phone or a computer, which decides what it may send. Once paired, the pairing record
/// decides, not what the device says in `hello`.
enum PeerClass {
    static func isComputer(_ platform: String) -> Bool { PhoneLinkProtocol.computers.contains(platform) }

    /// The platform used for permissions: the record's once paired, otherwise what hello said.
    static func platform(record: String?, hello: String?) -> String { record ?? hello ?? "" }

    /// False when a paired device's hello claims another kind of device, or another computer platform, which
    /// would give it other permissions. Phones may report a different phone platform.
    static func helloMatches(record: String, hello: String) -> Bool {
        if isComputer(record) || isComputer(hello) { return record == hello }
        return true
    }
}
