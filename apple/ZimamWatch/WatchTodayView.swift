import SwiftUI
import ZimamKit

/// The watch shows today only: the dual date, today's open tasks (tap to complete),
/// and a field to add a task by dictation or typing.
struct WatchTodayView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var newTitle = ""

    init() {}

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !model.isSignedIn {
                        WatchNote(text: "افتح زمام على الآيفون وسجّل الدخول، ثم عُد إلى هنا.")
                    } else if model.tasks.isEmpty && !model.isLoading {
                        WatchNote(text: "لا مهام اليوم. يومك لك.")
                    }
                    ForEach(model.tasks, id: \.id) { task in
                        WatchTaskRow(title: task.title, isDone: model.finishing.contains(task.id)) {
                            Task { await model.complete(task) }
                        }
                    }
                } header: {
                    Text(model.formatter.dual(Date()))
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                        .textCase(nil)
                }

                if model.isSignedIn {
                    Section {
                        TextField("إضافة مهمة", text: $newTitle)
                            .font(ZimamType.body)
                            .onSubmit(add)
                    }
                }

                if let error = model.errorMessage {
                    Section {
                        WatchNote(text: error)
                    }
                }
            }
            .navigationTitle("اليوم")
        }
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
    }

    private func add() {
        let title = newTitle
        newTitle = ""
        Task { await model.add(title: title) }
    }
}

/// The simplified task row: the completion circle and the title, no notes or chips.
/// The whole row is the button, so the target is large on a small screen.
private struct WatchTaskRow: View {
    let title: String
    let isDone: Bool
    let onComplete: () -> Void

    var body: some View {
        Button(action: onComplete) {
            HStack(spacing: ZimamSpacing.space2) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(ZimamType.title)
                    .foregroundStyle(isDone ? ZimamColor.brand : ZimamColor.lineStrong)
                    .accessibilityHidden(true)
                Text(title)
                    .font(ZimamType.body)
                    .foregroundStyle(isDone ? ZimamColor.inkFaint : ZimamColor.ink)
                    .strikethrough(isDone)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: ZimamSpacing.space11)
            .animation(.default, value: isDone)
        }
        .disabled(isDone)
        .accessibilityLabel(label)
    }

    private var label: String {
        isDone ? "\(title)، منجزة" : "إنجاز \(title)"
    }
}

/// One quiet sentence in the list.
private struct WatchNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(ZimamType.callout)
            .foregroundStyle(ZimamColor.inkMuted)
    }
}
