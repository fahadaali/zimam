import SwiftData
import SwiftUI
import ZimamKit

/// Open tasks due today or overdue, with the assistant's summary of the day on request.
/// A task completed here stays for a second so it can be undone.
struct TodayView: View {
    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.taskSelection) private var taskSelection
    @Query(filter: #Predicate<TaskItem> { !$0.pendingDelete }, sort: [SortDescriptor(\TaskItem.sortOrder), SortDescriptor(\TaskItem.createdAt)])
    private var tasks: [TaskItem]
    @Query(filter: #Predicate<ProjectItem> { !$0.pendingDelete }) private var projects: [ProjectItem]
    @State private var showingAdd = false
    @State private var lingering: Set<UUID> = []

    private var items: [TaskItem] {
        let today = formatter.dayString(from: Date())
        return tasks
            .filter { task in
                guard task.parentId == nil, let due = task.dueDate, due <= today else { return false }
                return !task.isDone || lingering.contains(task.id)
            }
            .sorted { ($0.dueDate ?? "", $0.dueTime ?? "") < ($1.dueDate ?? "", $1.dueTime ?? "") }
    }

    var body: some View {
        let names = projectNames(projects)
        List(selection: taskSelection) {
            Section {
                // «ملخص اليوم» from the assistant; hidden offline.
                DaySummaryRow()
                if items.isEmpty { EmptyLine(text: "لا مهام اليوم. يومك لك.") }
                ForEach(items) { task in
                    TaskListItem(task: task, projectName: task.projectId.flatMap { names[$0] }, onCompleted: linger)
                }
            } header: {
                ScreenHeader(title: "اليوم", subtitle: formatter.dual(Date()))
            }
        }
        .zimamList()
        .overlay(alignment: .bottomTrailing) { AddTaskButton { showingAdd = true } }
        .sheet(isPresented: $showingAdd) { AddTaskView(due: .today) }
        .toolbar { ToolbarItem { AccountMenu() } }
    }

    private func linger(_ id: UUID) {
        lingering.insert(id)
        Task {
            try? await Task.sleep(for: .seconds(1))
            _ = withAnimation { lingering.remove(id) }
        }
    }
}
