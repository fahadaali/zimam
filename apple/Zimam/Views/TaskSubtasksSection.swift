import SwiftData
import SwiftUI
import ZimamKit

// MARK: Subtasks

struct TaskSubtasksSection: View {
    let task: TaskItem
    let subtasks: [TaskItem]
    let store: Store

    @State private var newTitle = ""
    @FocusState private var fieldFocused: Bool
    /// Set by an add from Return: iOS gives up the field's focus after Return, and that loss then
    /// brings the keyboard back for the next subtask. It holds only for a moment and for one loss,
    /// so a later tap elsewhere still leaves the field. Typing clears it.
    @State private var refocusUntil: ContinuousClock.Instant?

    private var trimmed: String { newTitle.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Section("المهام الفرعية") {
            ForEach(subtasks) { subtask in
                TaskSubtaskRow(task: subtask, store: store)
            }
            HStack(spacing: ZimamSpacing.space2) {
                TextField(hint: "مهمة فرعية جديدة", text: $newTitle)
                    .labelsHidden()
                    .focused($fieldFocused)
                    .onSubmit(submit)
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused, let until = refocusUntil {
                            refocusUntil = nil
                            if ContinuousClock.now < until { fieldFocused = true }
                        }
                    }
                    .onChange(of: newTitle) { _, title in
                        if !title.isEmpty { refocusUntil = nil }
                    }
                Button("إضافة") { add() }
                    .buttonStyle(.zimamQuiet)
                    .disabled(trimmed.isEmpty)
            }
            // The separator under the field runs from the row's start, not from the button's text.
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            // The assistant proposes steps; nothing is added before «إضافة».
            SubtaskBreakdown(task: task, store: store)
        }
    }

    /// Return adds the subtask and keeps the field for the next one; «إضافة» leaves the keyboard as it is.
    private func submit() {
        guard add() else { return }
        #if os(iOS)
        refocusUntil = ContinuousClock.now.advanced(by: .milliseconds(500))
        #endif
        fieldFocused = true
    }

    @discardableResult
    private func add() -> Bool {
        guard !trimmed.isEmpty else { return false }
        store.addSubtask(to: task, title: trimmed)
        newTitle = ""
        return true
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
