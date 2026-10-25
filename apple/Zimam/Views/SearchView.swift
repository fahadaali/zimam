import SwiftData
import SwiftUI
import ZimamKit

/// Searches titles, notes and tags, ignoring diacritics and letter forms (see ArabicSearch).
/// ⌘F and the sidebar's «بحث» put the cursor in the search field (`focusPending`); choosing the
/// tab or the sidebar row alone does not, so the iPhone keyboard doesn't open on every visit.
struct SearchView: View {
    @Environment(\.taskSelection) private var taskSelection
    @Query(filter: #Predicate<TaskItem> { !$0.pendingDelete }, sort: [SortDescriptor(\TaskItem.updatedAt, order: .reverse)])
    private var tasks: [TaskItem]
    @Query(filter: #Predicate<ProjectItem> { !$0.pendingDelete }) private var projects: [ProjectItem]
    @State private var query = ""
    @State private var foldCache = SearchFoldCache()
    @FocusState private var searchFocused: Bool
    /// Set by an explicit search command; cleared once the field has focus.
    @Binding private var focusPending: Bool

    init(focusPending: Binding<Bool> = .constant(false)) {
        _focusPending = focusPending
    }

    /// The query is folded once; each task's text is folded once until it changes.
    private var results: [TaskItem] {
        let words = ArabicSearch.fold(query).split(separator: " ")
        guard !words.isEmpty else { return [] }
        return tasks.filter { task in
            let text = foldCache.text(for: task)
            return words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        let names = projectNames(projects)
        // Once per render, not once per use.
        let results = self.results
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
        .searchFocused($searchFocused)
        .onChange(of: focusPending, initial: true) { _, pending in
            guard pending else { return }
            focusPending = false
            // A turn later, so the toolbar's field is there to take the focus.
            Task { @MainActor in searchFocused = true }
        }
    }
}

/// Each task's folded title, notes and tags, kept while that text stays the same. Not observed:
/// filling it while the view renders redraws nothing.
final class SearchFoldCache {
    private var entries: [UUID: (source: String, folded: String)] = [:]

    func text(for task: TaskItem) -> String {
        let source = "\(task.title) \(task.notes ?? "") \(task.tags.joined(separator: " "))"
        if let entry = entries[task.id], entry.source == source { return entry.folded }
        let folded = ArabicSearch.fold(source)
        entries[task.id] = (source, folded)
        return folded
    }
}
