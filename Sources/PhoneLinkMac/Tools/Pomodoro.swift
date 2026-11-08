import Foundation

/// How long each part of a Pomodoro cycle lasts, chosen in Advanced.
struct PomodoroSettings: Codable, Equatable {
    var focusMinutes = 25
    var shortBreakMinutes = 5
    var longBreakMinutes = 15
    var sessions = 4

    static let focusChoices = [15, 20, 25, 30, 45, 50, 60]
    static let shortBreakChoices = [3, 5, 10, 15]
    static let longBreakChoices = [10, 15, 20, 30]
    static let sessionChoices = [2, 3, 4, 5, 6]

    /// Values outside the lists, from an edited preferences file, fall back to the defaults.
    var checked: PomodoroSettings {
        let standard = PomodoroSettings()
        return PomodoroSettings(
            focusMinutes: Self.focusChoices.contains(focusMinutes) ? focusMinutes : standard.focusMinutes,
            shortBreakMinutes: Self.shortBreakChoices.contains(shortBreakMinutes) ? shortBreakMinutes : standard.shortBreakMinutes,
            longBreakMinutes: Self.longBreakChoices.contains(longBreakMinutes) ? longBreakMinutes : standard.longBreakMinutes,
            sessions: Self.sessionChoices.contains(sessions) ? sessions : standard.sessions
        )
    }

    func length(_ phase: Pomodoro.Phase) -> TimeInterval {
        switch phase {
        case .focus: return TimeInterval(focusMinutes * 60)
        case .shortBreak: return TimeInterval(shortBreakMinutes * 60)
        case .longBreak: return TimeInterval(longBreakMinutes * 60)
        }
    }

    /// Every step of one cycle in order.
    var steps: [(phase: Pomodoro.Phase, session: Int)] {
        (1...sessions).flatMap { session -> [(phase: Pomodoro.Phase, session: Int)] in
            session < sessions ? [(.focus, session), (.shortBreak, session)] : [(.focus, session), (.longBreak, session)]
        }
    }

    var cycleLength: TimeInterval { steps.reduce(0) { $0 + length($1.phase) } }
}

/// Focus rounds with short breaks between them, then one long break.
/// The cycle runs on by itself until the long break ends or it is reset.
struct Pomodoro: Equatable {
    enum Phase: Equatable {
        case focus, shortBreak, longBreak
    }

    let settings: PomodoroSettings
    private(set) var phase = Phase.focus
    private(set) var session = 1
    private(set) var endsAt: Date?
    private(set) var pausedRemaining: TimeInterval?

    init(settings: PomodoroSettings = PomodoroSettings()) {
        self.settings = settings
    }

    var isRunning: Bool { endsAt != nil }
    /// False only before the first start or after a reset.
    var isStarted: Bool { self != Pomodoro(settings: settings) }
    var length: TimeInterval { settings.length(phase) }
    var sessions: Int { settings.sessions }
    var steps: [(phase: Phase, session: Int)] { settings.steps }

    var stepIndex: Int {
        steps.firstIndex { $0.phase == phase && $0.session == session } ?? 0
    }

    func remaining(at now: Date) -> TimeInterval {
        if let endsAt { return max(0, endsAt.timeIntervalSince(now)) }
        return pausedRemaining ?? length
    }

    /// From 0 at the start of this step to 1 at its end.
    func progress(at now: Date) -> Double {
        min(max(1 - remaining(at: now) / length, 0), 1)
    }

    /// Time left in this step plus every step after it.
    func remainingInCycle(at now: Date) -> TimeInterval {
        steps.dropFirst(stepIndex + 1).reduce(remaining(at: now)) { $0 + settings.length($1.phase) }
    }

    mutating func start(at now: Date) {
        guard !isRunning else { return }
        endsAt = now.addingTimeInterval(remaining(at: now))
        pausedRemaining = nil
    }

    mutating func pause(at now: Date) {
        guard isRunning else { return }
        pausedRemaining = remaining(at: now)
        endsAt = nil
    }

    mutating func reset() {
        self = Pomodoro(settings: settings)
    }

    /// Moves on when the current step has ended and returns the step that finished.
    /// Each step starts when the last one ended, so a Mac that slept catches up correctly.
    mutating func advance(at now: Date) -> Phase? {
        guard let endsAt, now >= endsAt else { return nil }
        let finished = phase
        switch phase {
        case .focus:
            phase = session < sessions ? .shortBreak : .longBreak
        case .shortBreak:
            phase = .focus
            session += 1
        case .longBreak:
            reset()
            return finished
        }
        self.endsAt = endsAt.addingTimeInterval(length)
        return finished
    }
}
