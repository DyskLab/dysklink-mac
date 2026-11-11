import SwiftUI

extension NotchView {
    var todoPage: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            TodoPanel(todos: model.todos, now: context.date, scrolls: scrolls)
        }
    }
}

struct TodoPanel: View {
    let todos: TodoModel
    let now: Date
    var scrolls = true

    private static let green = Color(hex: 0x62D17A)

    var body: some View {
        let tasks = todos.visible(now)
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(todos.doneToday(now))/\(todos.totalToday(now))")
                    .font(.system(size: 40, weight: .bold).monospacedDigit()).foregroundStyle(Color.white)
                Text("Tasks done today").font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.55))
                HStack(spacing: 8) {
                    pill("plus.circle.fill", "Add") { TodoQuickAdd.show(todos) }
                    pill(todos.isEditing ? "checkmark" : "pencil", todos.isEditing ? "Done" : "Edit") {
                        todos.isEditing.toggle()
                    }
                    .opacity(tasks.isEmpty ? 0.4 : 1)
                    .disabled(tasks.isEmpty)
                }
            }
            .frame(width: 190, alignment: .leading)
            if tasks.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "checklist").font(.system(size: 22)).foregroundStyle(Color.white.opacity(0.7))
                    Text("No tasks yet").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.white)
                    Text("Press Add to write one").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                OptionalScroll(enabled: scrolls) {
                    VStack(spacing: 6) {
                        ForEach(tasks) { task in taskRow(task) }
                    }
                }
            }
        }
    }

    private func pill(_ icon: String, _ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(text).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func taskRow(_ task: TodoItem) -> some View {
        HStack(spacing: 10) {
            Button { todos.toggle(task.id) } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).foregroundStyle(task.isDone ? Self.green : Color.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(task.isDone ? "Mark as not done" : "Mark as done")
            Text(task.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                .strikethrough(task.isDone)
                .foregroundStyle(task.isDone ? Color.white.opacity(0.6) : Color.white)
            Spacer(minLength: 0)
            if todos.isEditing {
                Button { TodoQuickAdd.show(todos, renaming: task) } label: {
                    Image(systemName: "pencil.circle.fill").font(.system(size: 17)).foregroundStyle(Color.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("Rename")
                Button { todos.delete(task.id) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(Color(hex: 0xFF6F7D))
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(task.isDone ? Color(hex: 0x1B2E1F) : Color.white.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
