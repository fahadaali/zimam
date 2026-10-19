import SwiftData
import SwiftUI

/// «صندوق المهام» in the iPad and Mac sidebar: open tasks with no project, which are private
/// to their owner (the API's inbox). A task completed here stays for a second so it can be undone.
struct InboxView: View {
    @Environment(\.taskSelection) private var taskSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(filter: #Predicate<TaskItem> { !$0.pendingDelete }, sort: [SortDescriptor(\TaskItem.sortOrder), SortDescriptor(\TaskItem.createdAt)])
    private var tasks: [TaskItem]
    @State private var showingAdd = false
    @State private var lingering = Lingering()

    var body: some View {
        let items = tasks.filter { $0.projectId == nil && $0.parentId == nil && (!$0.isDone || lingering.contains($0.id)) }
        List(selection: taskSelection) {
            Section {
                if items.isEmpty { EmptyLine(text: "لا مهام بلا مشروع.") }
                ForEach(items) { TaskListItem(task: $0, onCompleted: linger) }
            } header: {
                ScreenHeader(title: "صندوق المهام", subtitle: "المهام التي لا مشروع لها.")
            }
        }
        .zimamList()
        .overlay(alignment: .bottomTrailing) { AddTaskButton { showingAdd = true } }
        .sheet(isPresented: $showingAdd) { AddTaskView() }
    }

    private func linger(_ id: UUID) {
        lingering.hold(id, animation: reduceMotion ? nil : .default)
    }
}
