import Foundation
import SwiftData
import ZimamKit

/// Every local edit goes through here: it marks the record for sync and asks
/// the sync engine to send it soon.
@MainActor
struct Store {
    let context: ModelContext
    let sync: SyncEngine

    @discardableResult
    func addTask(title: String, projectId: UUID? = nil, dueDate: String? = nil, duePrayer: Prayer? = nil,
                 duePrayerOffset: Int? = nil, priority: TaskPriority = .none) -> TaskItem {
        let record = TaskRecord(projectId: projectId, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                priority: priority, dueDate: dueDate, duePrayer: duePrayer,
                                duePrayerOffset: duePrayer == nil ? nil : duePrayerOffset)
        let task = TaskItem(record, dirty: true)
        context.insert(task)
        commit()
        return task
    }

    func toggleDone(_ task: TaskItem) {
        let now = Milliseconds.now
        task.status = task.isDone ? .todo : .done
        task.completedAt = task.isDone ? now : nil
        touch(task)
    }

    /// Deletes a task and its subtasks; the server does the same for other devices.
    func delete(_ task: TaskItem) {
        let all = (try? context.fetch(FetchDescriptor<TaskItem>())) ?? []
        var queue = [task.id]
        while let id = queue.popLast() {
            for child in all where child.parentId == id && !child.pendingDelete {
                child.pendingDelete = true
                child.isDirty = false // the parent's deletion covers it
                queue.append(child.id)
            }
        }
        task.pendingDelete = true
        touch(task)
    }

    @discardableResult
    func addProject(name: String) -> ProjectItem {
        let project = ProjectItem(ProjectRecord(name: name.trimmingCharacters(in: .whitespacesAndNewlines)), dirty: true)
        context.insert(project)
        commit()
        return project
    }

    func touch(_ item: some SyncedItem) {
        item.updatedAt = nextUpdatedAt(after: item.updatedAt)
        item.isDirty = true
        commit()
    }

    private func commit() {
        try? context.save()
        sync.scheduleSync()
    }
}
