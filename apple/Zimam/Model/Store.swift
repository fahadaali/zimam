import Foundation
import SwiftData
import ZimamKit

/// Every local edit goes through here: it marks the record for sync, asks the
/// sync engine to send it soon, and lets the notification scheduler refresh.
@MainActor
struct Store {
    let context: ModelContext
    let sync: SyncEngine

    // MARK: Tasks

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

    /// Adds a subtask under `parent`, in the same project.
    @discardableResult
    func addSubtask(to parent: TaskItem, title: String) -> TaskItem? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let record = TaskRecord(projectId: parent.projectId, sectionId: parent.sectionId, parentId: parent.id, title: trimmed)
        let task = TaskItem(record, dirty: true)
        context.insert(task)
        commit()
        return task
    }

    /// Applies an edit to a task's fields and marks it for sync.
    func update(_ task: TaskItem, _ change: (TaskItem) -> Void) {
        change(task)
        touch(task)
    }

    /// Moves a task to another project, or to the inbox with nil. Its subtasks
    /// follow, as they do on the server, which also sends them to other devices.
    func move(_ task: TaskItem, toProject projectId: UUID?) {
        guard task.projectId != projectId else { return }
        let all = (try? context.fetch(FetchDescriptor<TaskItem>())) ?? []
        var queue = [task.id]
        while let id = queue.popLast() {
            for child in all where child.parentId == id {
                child.projectId = projectId
                child.sectionId = nil
                queue.append(child.id)
            }
        }
        task.projectId = projectId
        task.sectionId = nil
        touch(task)
    }

    /// Completes or reopens a task. Completing a recurring task adds its next
    /// occurrence as a new task; the completed one stays done.
    func toggleDone(_ task: TaskItem) {
        let completing = !task.isDone
        task.status = completing ? .done : .todo
        task.completedAt = completing ? Milliseconds.now : nil
        task.updatedAt = nextUpdatedAt(after: task.updatedAt)
        task.isDirty = true
        if completing { addNextOccurrence(of: task) }
        commit()
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

    // MARK: Reminders

    @discardableResult
    func addTimeReminder(to taskId: UUID, at date: Date) -> ReminderItem {
        let record = ReminderRecord(taskId: taskId, kind: .time, at: ReminderPlanner.isoString(from: date))
        let reminder = ReminderItem(record, dirty: true)
        context.insert(reminder)
        commit()
        return reminder
    }

    @discardableResult
    func addPrayerReminder(to taskId: UUID, prayer: Prayer, offsetMinutes: Int) -> ReminderItem {
        let record = ReminderRecord(taskId: taskId, kind: .prayer, prayer: prayer, offsetMinutes: offsetMinutes)
        let reminder = ReminderItem(record, dirty: true)
        context.insert(reminder)
        commit()
        return reminder
    }

    func deleteReminder(_ reminder: ReminderItem) {
        reminder.pendingDelete = true
        touch(reminder)
    }

    // MARK: Projects

    @discardableResult
    func addProject(name: String) -> ProjectItem {
        let project = ProjectItem(ProjectRecord(name: name.trimmingCharacters(in: .whitespacesAndNewlines)), dirty: true)
        context.insert(project)
        commit()
        return project
    }

    // MARK: Saving

    func touch(_ item: some SyncedItem) {
        item.updatedAt = nextUpdatedAt(after: item.updatedAt)
        item.isDirty = true
        commit()
    }

    private func commit() {
        try? context.save()
        sync.scheduleSync()
        sync.noteLocalChange()
    }

    // MARK: Recurrence

    /// Inserts the next occurrence of a recurring task, unless it already exists
    /// (completing, reopening and completing again adds it once).
    private func addNextOccurrence(of task: TaskItem) {
        guard let text = task.recurrence, let rule = Recurrence(rrule: text) else { return }
        let days = DualDateFormatter()
        let today = days.dayString(from: Date())
        let base = task.dueDate ?? today
        guard let next = rule.nextOccurrence(after: base, notBefore: today, timeZone: days.timeZone) else { return }

        let all = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.pendingDelete }))) ?? []
        for other in all {
            guard other.id != task.id, !other.isDone, other.dueDate == next.day else { continue }
            if other.title == task.title && other.parentId == task.parentId && other.projectId == task.projectId { return }
        }

        var record = task.record
        record.id = UUID()
        record.status = .todo
        record.completedAt = nil
        record.dueDate = next.day
        record.recurrence = next.rule.rrule
        record.createdAt = nil
        record.updatedAt = Milliseconds.now
        let copy = TaskItem(record, dirty: true)
        context.insert(copy)
        copyReminders(from: task.id, to: copy.id, fromDay: base, toDay: next.day, days: days)
    }

    /// Gives the next occurrence the same reminders; time reminders move by as many days as the task did.
    private func copyReminders(from taskId: UUID, to newTaskId: UUID, fromDay: String, toDay: String, days: DualDateFormatter) {
        let reminders = (try? context.fetch(FetchDescriptor<ReminderItem>(predicate: #Predicate { $0.taskId == taskId }))) ?? []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = days.timeZone
        var shift = 0
        if let from = days.date(fromDay: fromDay), let to = days.date(fromDay: toDay) {
            shift = calendar.dateComponents([.day], from: from, to: to).day ?? 0
        }
        for reminder in reminders where !reminder.pendingDelete {
            var record = reminder.record
            record.id = UUID()
            record.taskId = newTaskId
            record.createdAt = nil
            record.updatedAt = Milliseconds.now
            if record.kind == .time {
                guard let at = record.at, let date = ReminderPlanner.date(fromISO: at),
                      let moved = calendar.date(byAdding: .day, value: shift, to: date) else { continue }
                record.at = ReminderPlanner.isoString(from: moved)
            }
            context.insert(ReminderItem(record, dirty: true))
        }
    }
}
