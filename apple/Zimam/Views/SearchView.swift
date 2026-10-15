import SwiftData
import SwiftUI
import ZimamKit

/// Searches titles, notes and tags, ignoring diacritics and letter forms (see ArabicSearch).
struct SearchView: View {
    @Environment(\.taskSelection) private var taskSelection
    @Query(filter: #Predicate<TaskItem> { !$0.pendingDelete }, sort: [SortDescriptor(\TaskItem.updatedAt, order: .reverse)])
    private var tasks: [TaskItem]
    @Query(filter: #Predicate<ProjectItem> { !$0.pendingDelete }) private var projects: [ProjectItem]
    @State private var query = ""

    private var results: [TaskItem] {
        tasks.filter { ArabicSearch.matches("\($0.title) \($0.notes ?? "") \($0.tags.joined(separator: " "))", query: query) }
    }

    var body: some View {
        let names = projectNames(projects)
        List(selection: taskSelection) {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                EmptyLine(text: "ابحث في عناوين المهام وملاحظاتها ووسومها.")
            } else if results.isEmpty {
                EmptyLine(text: "لا نتائج.")
            } else {
                ForEach(results) { task in
                    TaskListItem(task: task, projectName: task.projectId.flatMap { names[$0] })
                }
            }
        }
        .zimamList()
        .searchable(text: $query, prompt: "ابحث في المهام")
    }
}
