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

/// Opens a task from outside a `List(selection:)` (the calendar, the matrix): on the iPad and the
/// Mac it selects the task for the inspector (`\.taskSelection`), as the content column has no
/// destination to push it to; on the iPhone it pushes the details.
struct TaskOpenLink<Label: View>: View {
    let taskId: UUID
    let label: Label

    @Environment(\.taskSelection) private var taskSelection

    init(taskId: UUID, @ViewBuilder label: () -> Label) {
        self.taskId = taskId
        self.label = label()
    }

    var body: some View {
        if let taskSelection {
            Button { taskSelection.wrappedValue = TaskRoute(id: taskId) } label: { label }
        } else {
            NavigationLink(value: TaskRoute(id: taskId)) { label }
        }
    }
}

/// A task row inside a list, with completion and swipe-to-delete wired to the store. A full swipe
/// only uncovers «حذف», as on the project rows and the web, so a task and its subtasks go only on a tap.
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
    @State private var moving: ProjectMoveRequest?

    var body: some View {
        let store = Store(context: context, sync: sync)
        let selected = taskSelection?.wrappedValue?.id == task.id
        NavigationLink(value: TaskRoute(id: task.id)) {
            TaskRow(task: task, projectName: projectName, selected: selected) {
                withAnimation(.zimamComplete) {
                    store.toggleDone(task)
                    if task.isDone { onCompleted?(task.id) }
                }
            }
        }
        // Each task is its own rounded card, as in the calendar's day list; the task open in the
        // details column (iPad and Mac) stands out in brand-soft.
        .listRowInsets(EdgeInsets(top: ZimamSpacing.space2, leading: ZimamSpacing.space4 * 2,
                                  bottom: ZimamSpacing.space2, trailing: ZimamSpacing.space4 * 2))
        .listRowSeparator(.hidden)
        .listRowBackground(TaskCardBackground(selected: selected))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("حذف", systemImage: "trash", role: .destructive) { store.delete(task) }
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
                .draggable(TaskDragItem(id: task.id)) { TaskDragPreview(title: task.title) }
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

/// The card behind a task row in a list: inset from the screen's edges, with a small gap to the
/// next card. Radius and colors from the tokens (design/components/TaskRow).
private struct TaskCardBackground: View {
    let selected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: ZimamRadius.radiusLg)
            .fill(selected ? ZimamColor.brandSoft : ZimamColor.surfaceRaised)
            .padding(.horizontal, ZimamSpacing.space4)
            .padding(.vertical, ZimamSpacing.space1 / 2)
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
        }
        // Brand glass on iOS and macOS 26, the brand circle before (Components/ZimamGlass.swift).
        .zimamFloatingActionStyle()
        // ⌘N is the menu's «مهمة جديدة» (ZimamCommands), which adds where this button does.
        .accessibilityLabel("إضافة مهمة")
        .padding(ZimamSpacing.space4)
    }
}

extension View {
    /// Room under the last row for the floating add button, as Calendar, Matrix and Gantt keep.
    func roomForAddButton() -> some View {
        contentMargins(.bottom, ZimamSpacing.space11 + ZimamSpacing.space8, for: .scrollContent)
    }
}

/// A screen title in the display style, with an optional line under it.
struct ScreenHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
            // A project's or section's name can wrap: lines kept apart by the display line height.
            Text(title)
                .font(ZimamType.display)
                .lineSpacing(ZimamType.displayLineSpacing)
                .foregroundStyle(ZimamColor.ink)
            if let subtitle {
                Text(subtitle)
                    .font(ZimamType.caption)
                    .lineSpacing(ZimamType.captionLineSpacing)
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
    /// On the iPhone the bar keeps no room for a large title: each screen draws its own
    /// (`ScreenHeader`), so an empty large-title area would only push the list down.
    func zimamList() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(ZimamColor.surface)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            // The list's own top margin before the first header, on top of the bar's: gone, so the
            // screen's title sits right under the toolbar.
            .contentMargins(.top, 0, for: .scrollContent)
            #endif
    }
}

/// Project names by id, for the meta text in task rows.
func projectNames(_ projects: [ProjectItem]) -> [UUID: String] {
    Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
}
