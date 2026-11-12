import Foundation

/// Stops a device from guessing the six-digit code. Wrong codes count per device across prompts, so asking again
/// doesn't start over. After `Pairing.maxAttempts` wrong codes that device waits 60 s, then twice as long each time,
/// up to an hour. Many wrong codes from any devices close pairing for everyone for a while.
struct PairingGuard {
    enum Decision: Equatable {
        case allowed
        /// Dropped without an answer, such as a request repeated too quickly.
        case ignored
        /// Another device asked moments ago; this one may ask again after this many seconds.
        case deferred(TimeInterval)
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
    /// The last request any device was allowed, so new certificates can't each start a prompt at once. A pairing
    /// that worked clears it.
    private var lastAnyRequest: Date?
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
        if let last = lastAnyRequest, now.timeIntervalSince(last) < Self.requestInterval {
            return .deferred(Self.requestInterval - now.timeIntervalSince(last))
        }
        state.lastRequest = now
        lastAnyRequest = now
        prune(now: now)
        return .allowed
    }

    /// Devices with nothing to remember are forgotten, so many throwaway certificates don't pile up.
    private mutating func prune(now: Date) {
        guard peers.count > 256 else { return }
        peers = peers.filter { _, state in
            state.wrong > 0 || state.lockouts > 0 || (state.until.map { $0 > now } ?? false)
                || (state.lastRequest.map { now.timeIntervalSince($0) < Self.requestInterval } ?? false)
        }
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
        // The right code took someone at this Mac, so the next device may ask at once.
        lastAnyRequest = nil
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

/// Limits on connections that came in and aren't a paired device yet: a few per address and a few in all, and
/// each has to say hello within `helloTimeout`.
enum InboundLimits {
    static let maxUnpaired = 8
    static let maxUnpairedPerAddress = 2
    static let helloTimeout: TimeInterval = 10

    /// Whether a new connection from `address` may stay, given the addresses of unpaired connections already open.
    /// Connections over USB all come from this Mac, so they only count toward the total.
    static func admits(address: String, isLoopback: Bool, unpaired: [String]) -> Bool {
        guard unpaired.count < maxUnpaired else { return false }
        if isLoopback { return true }
        return unpaired.filter { $0 == address }.count < maxUnpairedPerAddress
    }
}

/// Where a file a device offers goes. Photos, gallery copies, and scans come only from phones (by the pairing
/// record), and a gallery copy only when this Mac asked for that item; anything else is a plain file in Downloads.
enum IncomingFileRule {
    enum Destination: Equatable {
        case photos, gallery, scan, downloads

        /// The kind kept on the incoming file, which decides what happens once it arrives.
        var kind: String? {
            switch self {
            case .photos: "photo"
            case .gallery: "gallery"
            case .scan: "scan"
            case .downloads: nil
            }
        }
    }

    static func destination(kind: String?, fromPhone: Bool, wanted: Bool) -> Destination {
        guard fromPhone else { return .downloads }
        switch kind {
        case "photo": return .photos
        case "gallery": return wanted ? .gallery : .downloads
        case "scan": return .scan
        default: return .downloads
        }
    }
}

/// While a code shows, a `pair.request` with a new nonce would need a new CPace share, which costs a hash, Elligator 2,
/// and X25519. One share stays per prompt: a new nonce gets a new one only after a counted wrong code from that device,
/// or at most once every `interval` seconds. Other new nonces are dropped.
struct PakeRenewal {
    static let interval: TimeInterval = 2

    private var madeAt: Date?
    private var wrongSince = false

    /// A share was just made for a new prompt.
    mutating func started(now: Date = Date()) {
        madeAt = now
        wrongSince = false
    }

    /// The device typed a wrong code, which PairingGuard counted.
    mutating func wrongCode() { wrongSince = true }

    /// Whether a request with a new nonce gets a new share now. True also records it.
    mutating func allowsNewShare(now: Date = Date()) -> Bool {
        let due = madeAt.map { now.timeIntervalSince($0) >= Self.interval || now < $0 } ?? true
        guard wrongSince || due else { return false }
        started(now: now)
        return true
    }
}

/// A code typed on this Mac before the other side's `pair.pake` came. It goes once the share arrives, but only while
/// that typed code still stands: a wrong-code answer or a reset drops it.
struct PendingCode {
    private(set) var code: String?

    mutating func hold(_ code: String) { self.code = code }
    mutating func clear() { code = nil }

    /// The code to send now that the share came, if this Mac's typed code is still the one waiting.
    mutating func take(localAccepted: Bool) -> String? {
        defer { code = nil }
        return localAccepted ? code : nil
    }
}
