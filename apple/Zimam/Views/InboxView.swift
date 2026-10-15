import SwiftData
import SwiftUI

/// «صندوق المهام» in the iPad and Mac sidebar: open tasks with no project, which are private
/// to their owner (the API's inbox).
struct InboxView: View {
    @Environment(\.taskSelection) private var taskSelection
    @Query(filter: #Predicate<TaskItem> { !$0.pendingDelete }, sort: [SortDescriptor(\TaskItem.sortOrder), SortDescriptor(\TaskItem.createdAt)])
    private var tasks: [TaskItem]
    @State private var showingAdd = false

    var body: some View {
        let items = tasks.filter { $0.projectId == nil && $0.parentId == nil && !$0.isDone }
        List(selection: taskSelection) {
            Section {
                if items.isEmpty { EmptyLine(text: "لا مهام بلا مشروع.") }
                ForEach(items) { TaskListItem(task: $0) }
            } header: {
                ScreenHeader(title: "صندوق المهام", subtitle: "المهام التي لا مشروع لها.")
            }
        }
        .zimamList()
        .overlay(alignment: .bottomTrailing) { AddTaskButton { showingAdd = true } }
        .sheet(isPresented: $showingAdd) { AddTaskView() }
    }
}
