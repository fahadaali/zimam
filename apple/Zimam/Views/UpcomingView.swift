import SwiftData
import SwiftUI
import ZimamKit

/// Open tasks after today, grouped by day. A task completed here stays for a second so it can
/// be undone.
struct UpcomingView: View {
    @Environment(\.dateFormatterZimam) private var formatter
    @Environment(\.taskSelection) private var taskSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(filter: #Predicate<TaskItem> { !$0.pendingDelete }, sort: [SortDescriptor(\TaskItem.sortOrder)])
    private var tasks: [TaskItem]
    @Query(filter: #Predicate<ProjectItem> { !$0.pendingDelete }) private var projects: [ProjectItem]
    @State private var showingAdd = false
    @State private var lingering = Lingering()

    private struct DayGroup: Identifiable {
        let day: String
        let tasks: [TaskItem]
        var id: String { day }
    }

    private var days: [DayGroup] {
        let today = formatter.dayString(from: Date())
        let upcoming = tasks.filter { (!$0.isDone || lingering.contains($0.id)) && $0.parentId == nil && ($0.dueDate ?? "") > today }
        return Dictionary(grouping: upcoming) { $0.dueDate ?? "" }
            .map { DayGroup(day: $0.key, tasks: $0.value) }
            .sorted { $0.day < $1.day }
    }

    var body: some View {
        let names = projectNames(projects)
        // Once per render, not once per use.
        let days = self.days
        List(selection: taskSelection) {
            Section {
                if days.isEmpty { EmptyLine(text: "لا مهام قادمة.") }
            } header: {
                ScreenHeader(title: "القادم")
            }
            ForEach(days) { group in
                Section {
                    ForEach(group.tasks) { task in
                        TaskListItem(task: task, projectName: task.projectId.flatMap { names[$0] }, onCompleted: linger)
                    }
                } header: {
                    Text(formatter.date(fromDay: group.day).map { formatter.label(for: $0) } ?? group.day)
                        .font(ZimamType.headline)
                        .foregroundStyle(ZimamColor.ink)
                        .textCase(nil)
                }
            }
        }
        .zimamList()
        .overlay(alignment: .bottomTrailing) { AddTaskButton { showingAdd = true } }
        .sheet(isPresented: $showingAdd) { AddTaskView(due: .tomorrow) }
    }

    private func linger(_ id: UUID) {
        lingering.hold(id, animation: reduceMotion ? nil : .default)
    }
}
