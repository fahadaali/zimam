import AppIntents
import Foundation
import SwiftData
import ZimamKit

/// A task as Siri, Shortcuts and the widgets see it.
struct TaskEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "مهمة"
    static var defaultQuery = TaskEntityQuery()

    let id: UUID
    let title: String

    init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }

    init(_ task: TaskItem) {
        id = task.id
        title = task.title
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

/// Finds tasks in the local store, by id (when an intent runs) or by words in the title
/// (when Siri or Shortcuts ask which task). Suggests today's tasks first.
struct TaskEntityQuery: EntityStringQuery {
    init() {}

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [TaskEntity] {
        let wanted = Set(identifiers)
        return allTasks()
            .filter { wanted.contains($0.id) }
            .map { TaskEntity($0) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [TaskEntity] {
        let matches = allTasks().filter { !$0.isDone && ArabicSearch.matches($0.title, query: string) }
        return Array(matches.prefix(20)).map { TaskEntity($0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [TaskEntity] {
        let context = ZimamStore.shared.mainContext
        let today = TodayTasks.fetch(in: context, today: TodayTasks.todayString())
        let tasks = today.isEmpty ? allTasks().filter { !$0.isDone && $0.parentId == nil } : today
        return Array(tasks.prefix(20)).map { TaskEntity($0) }
    }

    @MainActor
    private func allTasks() -> [TaskItem] {
        let context = ZimamStore.shared.mainContext
        return (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.pendingDelete }))) ?? []
    }
}
