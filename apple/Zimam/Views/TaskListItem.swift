import SwiftData
import SwiftUI

/// A task row inside a list, with completion and swipe-to-delete wired to the store.
struct TaskListItem: View {
    let task: TaskItem
    var projectName: String?
    var onCompleted: ((UUID) -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync

    var body: some View {
        let store = Store(context: context, sync: sync)
        TaskRow(task: task, projectName: projectName) {
            withAnimation {
                store.toggleDone(task)
                if task.isDone { onCompleted?(task.id) }
            }
        }
        .listRowBackground(ZimamColor.surfaceRaised)
        .swipeActions(edge: .trailing) {
            Button("حذف", role: .destructive) { store.delete(task) }
        }
    }
}

/// The floating add button, at the bottom trailing corner (bottom left in Arabic).
struct AddTaskButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(ZimamType.title)
                .foregroundStyle(ZimamColor.onBrand)
                .frame(width: ZimamSpacing.space11, height: ZimamSpacing.space11)
                .padding(ZimamSpacing.space1)
                .background(ZimamColor.brand, in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: .command)
        .accessibilityLabel("إضافة مهمة")
        .padding(ZimamSpacing.space4)
    }
}

/// A screen title in the display style, with an optional line under it.
struct ScreenHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
            Text(title)
                .font(ZimamType.display)
                .foregroundStyle(ZimamColor.ink)
            if let subtitle {
                Text(subtitle)
                    .font(ZimamType.caption)
                    .foregroundStyle(ZimamColor.inkMuted)
            }
        }
        .textCase(nil)
        .padding(.bottom, ZimamSpacing.space2)
    }
}

/// One quiet sentence for an empty list.
struct EmptyLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(ZimamType.callout)
            .foregroundStyle(ZimamColor.inkMuted)
            .listRowBackground(Color.clear)
    }
}

extension View {
    /// The plain list look used across Zimam: surface background, no system tint.
    func zimamList() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(ZimamColor.surface)
    }
}

/// Project names by id, for the meta text in task rows.
func projectNames(_ projects: [ProjectItem]) -> [UUID: String] {
    Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
}
