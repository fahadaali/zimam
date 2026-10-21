import SwiftData
import SwiftUI
import ZimamKit

// MARK: Subtasks

struct TaskSubtasksSection: View {
    let task: TaskItem
    let subtasks: [TaskItem]
    let store: Store

    @State private var newTitle = ""

    private var trimmed: String { newTitle.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Section("المهام الفرعية") {
            ForEach(subtasks) { subtask in
                TaskSubtaskRow(task: subtask, store: store)
            }
            HStack(spacing: ZimamSpacing.space2) {
                TextField(hint: "مهمة فرعية جديدة", text: $newTitle)
                    .labelsHidden()
                    .onSubmit(add)
                Button("إضافة", action: add)
                    .buttonStyle(.zimamQuiet)
                    .disabled(trimmed.isEmpty)
            }
            // The separator under the field runs from the row's start, not from the button's text.
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            // The assistant proposes steps; nothing is added before «إضافة».
            SubtaskBreakdown(task: task, store: store)
        }
    }

    private func add() {
        guard !trimmed.isEmpty else { return }
        store.addSubtask(to: task, title: trimmed)
        newTitle = ""
    }
}

private struct TaskSubtaskRow: View {
    let task: TaskItem
    let store: Store

    var body: some View {
        NavigationLink(value: TaskRoute(id: task.id)) {
            HStack(spacing: ZimamSpacing.space2) {
                CompletionCircle(isDone: task.isDone, font: ZimamType.headline, action: toggleDone)

                Text(task.title)
                    .font(ZimamType.body)
                    .foregroundStyle(task.isDone ? ZimamColor.inkFaint : ZimamColor.ink)
                    .strikethrough(task.isDone)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func toggleDone() {
        withAnimation(.zimamComplete) { store.toggleDone(task) }
    }
}
