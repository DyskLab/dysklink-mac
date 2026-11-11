import Foundation

/// Shares the notch's Todo list, water, and Pomodoro with paired phones.
/// The Mac keeps the data. A phone only asks for a change, and every phone then gets the new state.
@MainActor
enum NotchSync {
    static func state(of model: NotchModel, now: Date = Date()) -> NotchState {
        let tasks = model.todos.visible(now).map { NotchState.Task(id: $0.id.uuidString, title: $0.title, done: $0.isDone) }
        let water = NotchState.Water(totalMl: model.water.total(now), goalMl: model.water.settings.goalMl,
                                     glassMl: model.water.settings.glassMl)
        let pomodoro = model.pomodoro
        let focus = NotchState.Focus(
            phase: name(pomodoro.phase), session: pomodoro.session, sessions: pomodoro.sessions,
            running: pomodoro.isRunning, remainingMs: Int64(pomodoro.remaining(at: now) * 1000),
            lengthMs: Int64(pomodoro.length * 1000)
        )
        return NotchState(todos: tasks, water: water, focus: focus, note: model.note.text,
                          noteTime: model.note.updated.map { Int64($0.timeIntervalSince1970 * 1000) },
                          music: model.nowPlaying.map { NotchState.Music(title: $0.title, artist: $0.artist, playing: $0.isPlaying) })
    }

    /// The same as `state`, but stays put while a timer counts down, so it only changes when something real does.
    static func signature(of model: NotchModel, now: Date = Date()) -> NotchState {
        var result = state(of: model, now: now)
        if result.focus.running {
            // The end time in whole seconds, which doesn't move while the timer runs.
            result.focus.remainingMs = Int64(now.addingTimeInterval(model.pomodoro.remaining(at: now)).timeIntervalSince1970.rounded())
        }
        return result
    }

    static func apply(_ action: NotchAction, to model: NotchModel) {
        let id = action.id.flatMap(UUID.init(uuidString:))
        switch action.kind {
        case "todo.add":
            if let text = action.text { model.todos.add(text) }
        case "todo.toggle":
            if let id { model.todos.toggle(id) }
        case "todo.delete":
            if let id { model.todos.delete(id) }
        case "todo.rename":
            if let id, let text = action.text { model.todos.rename(id, to: text) }
        case "note.set":
            if let text = action.text { model.note.set(text) }
        case "water.drink":
            model.water.drink()
        case "water.undo":
            model.water.undo()
        case "focus.toggle":
            model.togglePomodoro()
        case "focus.reset":
            model.resetPomodoro()
        default:
            break
        }
    }

    private static func name(_ phase: Pomodoro.Phase) -> String {
        switch phase {
        case .focus: return "focus"
        case .shortBreak: return "shortBreak"
        case .longBreak: return "longBreak"
        }
    }
}
