import SwiftData
import SwiftUI

/// Where a task row leads: the task's detail screen.
struct TaskRoute: Hashable {
    let id: UUID
}

extension View {
    /// Lets any task row in this navigation stack open the task's details.
    func taskDetailDestination() -> some View {
        navigationDestination(for: TaskRoute.self) { route in
            TaskDetailView(taskId: route.id)
        }
    }
}

/// A task row inside a list, with completion and swipe-to-delete wired to the store.
/// Tapping the row opens the task's details. On the iPad and the Mac it can be dragged onto a
/// project or section in the sidebar; «نقل إلى مشروع…» (context menu and VoiceOver action)
/// does the same everywhere, and is the way on the iPhone.
struct TaskListItem: View {
    let task: TaskItem
    var projectName: String?
    var onCompleted: ((UUID) -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(SyncEngine.self) private var sync
    @Environment(\.taskSelection) private var taskSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moving: ProjectMoveRequest?

    var body: some View {
        let store = Store(context: context, sync: sync)
        let selected = taskSelection?.wrappedValue?.id == task.id
        NavigationLink(value: TaskRoute(id: task.id)) {
            TaskRow(task: task, projectName: projectName) {
                withAnimation(reduceMotion ? nil : .default) {
                    store.toggleDone(task)
                    if task.isDone { onCompleted?(task.id) }
                }
            }
        }
        // The task open in the details column (iPad and Mac) stands out in brand-soft.
        .listRowBackground(selected ? ZimamColor.brandSoft : ZimamColor.surfaceRaised)
        .swipeActions(edge: .trailing) {
            Button("حذف", role: .destructive) { store.delete(task) }
        }
        .modifier(ProjectMoveActions(task: task, moving: $moving))
    }
}

/// Dragging a top-level task to the sidebar, and «نقل إلى مشروع…» without dragging.
/// Subtasks move with their parent, so they have neither.
private struct ProjectMoveActions: ViewModifier {
    let task: TaskItem
    @Binding var moving: ProjectMoveRequest?

    @ViewBuilder
    func body(content: Content) -> some View {
        if task.parentId == nil {
            content
                .draggable(TaskDragItem(id: task.id))
                .contextMenu {
                    Button("نقل إلى مشروع…", systemImage: "folder") { moving = ProjectMoveRequest(id: task.id) }
                }
                .accessibilityAction(named: "نقل إلى مشروع…") { moving = ProjectMoveRequest(id: task.id) }
                .sheet(item: $moving) { request in
                    MoveToProjectSheet(taskId: request.id)
                }
        } else {
            content
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
