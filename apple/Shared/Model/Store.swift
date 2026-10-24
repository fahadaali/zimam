import Foundation
import os
import SwiftData
import ZimamKit

/// What `Store` needs from the sync engine. The app passes its `SyncEngine`; the widget
/// extension has none, so its edits stay marked dirty and the app sends them on its next sync.
@MainActor
protocol SyncScheduling: AnyObject {
    /// Syncs soon, folding a burst of edits into one request.
    func scheduleSync()
    /// Tells listeners (notifications, widgets) that a local edit was saved.
    func noteLocalChange()
}

/// Every local edit goes through here: it marks the record for sync, asks the
/// sync engine to send it soon, and lets the notification scheduler and the widgets refresh.
@MainActor
struct Store {
    let context: ModelContext
    let sync: (any SyncScheduling)?

    private static let logger = Logger(subsystem: "app.zimam.ios", category: "store")

    init(context: ModelContext, sync: (any SyncScheduling)?) {
        self.context = context
        self.sync = sync
    }

    // MARK: Tasks

    /// `notes`, `dueTime` and `tags` come from the assistant's suggestion; a time is kept
    /// only for a dated task that is not tied to a prayer, as the server does. `startDate` makes
    /// a dated task span days; it is kept only before the due day, as the server requires.
    /// The title and notes are cut to the server's limits (`ServerText`), so the task syncs.
    @discardableResult
    func addTask(title: String, projectId: UUID? = nil, dueDate: String? = nil, duePrayer: Prayer? = nil,
                 duePrayerOffset: Int? = nil, priority: TaskPriority = .none,
                 notes: String? = nil, dueTime: String? = nil, tags: [String] = [], startDate: String? = nil) -> TaskItem {
        let trimmedNotes = notes.map { ServerText.clip($0.trimmingCharacters(in: .whitespacesAndNewlines), to: ServerText.maxNotes) }
        let record = TaskRecord(projectId: projectId, title: Self.taskTitle(title),
                                notes: trimmedNotes?.isEmpty == false ? trimmedNotes : nil,
                                priority: priority, tags: tags, dueDate: dueDate,
                                startDate: DaySpan(startDate: startDate, dueDate: dueDate)?.startDate,
                                dueTime: dueDate != nil && duePrayer == nil ? dueTime : nil, duePrayer: duePrayer,
                                duePrayerOffset: duePrayer == nil ? nil : duePrayerOffset)
        let task = TaskItem(record, dirty: true)
        context.insert(task)
        commit()
        return task
    }

    /// Adds a subtask under `parent`, in the same project.
    @discardableResult
    func addSubtask(to parent: TaskItem, title: String) -> TaskItem? {
        let trimmed = Self.taskTitle(title)
        guard !trimmed.isEmpty else { return nil }
        let record = TaskRecord(projectId: parent.projectId, sectionId: parent.sectionId, parentId: parent.id, title: trimmed)
        let task = TaskItem(record, dirty: true)
        context.insert(task)
        commit()
        return task
    }

    /// A title as typed, trimmed and cut to the server's limit.
    static func taskTitle(_ title: String) -> String {
        ServerText.clip(title.trimmingCharacters(in: .whitespacesAndNewlines), to: ServerText.maxTitle)
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
        reassign(task, toProject: projectId)
        touch(task)
    }

    /// `move(_:toProject:)` without saving, for a move that changes more before its one save.
    func reassign(_ task: TaskItem, toProject projectId: UUID?) {
        let children = Dictionary(grouping: (try? context.fetch(FetchDescriptor<TaskItem>())) ?? [], by: \.parentId)
        var queue = [task.id]
        while let id = queue.popLast() {
            for child in children[id] ?? [] {
                child.projectId = projectId
                child.sectionId = nil
                queue.append(child.id)
            }
        }
        task.projectId = projectId
        task.sectionId = nil
        // The assignee may not be a member of the new project; the server rejects that.
        task.assigneeId = nil
    }

    /// Moves a task to another day ("2026-10-15"), from the calendar's drag and drop or «نقل إلى…».
    /// Its time or prayer anchor stays: a task «بعد العصر» is after Asr on the new day too.
    /// A task that spans days keeps its length: its start day moves by as many days.
    func reschedule(_ task: TaskItem, toDay day: String) {
        guard task.dueDate != day else { return }
        let start = task.span?.ending(on: day).startDate
        update(task) { item in
            item.dueDate = day
            item.startDate = start
        }
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

    /// Deletes a task, its subtasks and their reminders; the server does the same for other
    /// devices. What the server already has goes with the task's deletion and is not sent on its
    /// own; what it has not seen yet (still dirty: never sent, or an edit not sent) is sent as its
    /// own deletion, so nothing is left behind here or sent later as an edit.
    func delete(_ task: TaskItem) {
        let children = Dictionary(grouping: (try? context.fetch(FetchDescriptor<TaskItem>())) ?? [], by: \.parentId)
        var tree: Set<UUID> = [task.id]
        var queue = [task.id]
        while let id = queue.popLast() {
            for child in children[id] ?? [] where !child.pendingDelete {
                child.pendingDelete = true
                tree.insert(child.id)
                queue.append(child.id)
            }
        }
        for reminder in (try? context.fetch(FetchDescriptor<ReminderItem>())) ?? [] where tree.contains(reminder.taskId) && !reminder.pendingDelete {
            reminder.pendingDelete = true
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

    /// A reminder `offsetMinutes` from the task's own time (negative is before): it moves with
    /// the task's day, clock time or prayer (`ReminderPlanner`).
    @discardableResult
    func addRelativeReminder(to taskId: UUID, offsetMinutes: Int) -> ReminderItem {
        let record = ReminderRecord(taskId: taskId, kind: .relative, offsetMinutes: offsetMinutes)
        let reminder = ReminderItem(record, dirty: true)
        context.insert(reminder)
        commit()
        return reminder
    }

    /// A reminder on arriving at or leaving a place. The place fires on iPhone and iPad only
    /// (`NotificationScheduler`, `PlaceMonitor`). With `at` it fires once, at whichever comes
    /// first; the server pushes that time if no device took it back (`markFired`).
    @discardableResult
    func addLocationReminder(to taskId: UUID, place: ReminderRecord.Location, at date: Date? = nil) -> ReminderItem {
        let record = ReminderRecord(taskId: taskId, kind: .location, at: date.map { ReminderPlanner.isoString(from: $0) },
                                    location: place)
        let reminder = ReminderItem(record, dirty: true)
        context.insert(reminder)
        commit()
        return reminder
    }

    /// The place came first: the reminder's time is taken back, here and, once this syncs,
    /// on the user's other devices and on the server.
    func markFired(_ reminder: ReminderItem, at date: Date = Date()) {
        guard reminder.firedAt == nil else { return }
        reminder.firedAt = Milliseconds(date.timeIntervalSince1970 * 1000)
        touch(reminder)
    }

    func deleteReminder(_ reminder: ReminderItem) {
        reminder.pendingDelete = true
        touch(reminder)
    }

    // MARK: Places

    /// Saves a place to «أماكني». The name is trimmed; callers check it is not empty.
    @discardableResult
    func addPlace(name: String, latitude: Double, longitude: Double, radius: Double) -> PlaceItem {
        let record = PlaceRecord(name: Self.placeName(name), latitude: latitude, longitude: longitude,
                                 radius: Self.placeRadius(radius))
        let place = PlaceItem(record, dirty: true)
        context.insert(place)
        commit()
        return place
    }

    /// Renames, moves or resizes a place. Its reminders follow here at once; the server rewrites
    /// their copies too, so other devices and older apps follow on their next pull.
    func updatePlace(_ place: PlaceItem, name: String, latitude: Double, longitude: Double, radius: Double) {
        place.name = Self.placeName(name)
        place.latitude = latitude
        place.longitude = longitude
        place.radius = Self.placeRadius(radius)
        let copy = place.record
        for reminder in reminders(at: place.id) {
            guard var location = reminder.record.location else { continue }
            location.latitude = copy.latitude
            location.longitude = copy.longitude
            location.radius = copy.radius
            location.name = copy.name
            reminder.locationJSON = try? JSONEncoder().encode(location)
        }
        touch(place)
    }

    /// Deletes a place. Its reminders stay where it was, no longer linked to it.
    func deletePlace(_ place: PlaceItem) {
        for reminder in reminders(at: place.id) {
            guard var location = reminder.record.location else { continue }
            location.placeId = nil
            reminder.locationJSON = try? JSONEncoder().encode(location)
        }
        place.pendingDelete = true
        touch(place)
    }

    /// Location reminders that use the place (not deleted).
    func reminders(at placeId: UUID) -> [ReminderItem] {
        let kind = ReminderRecord.Kind.location.rawValue
        let all = (try? context.fetch(FetchDescriptor<ReminderItem>(
            predicate: #Predicate { $0.kindRaw == kind && !$0.pendingDelete }))) ?? []
        return all.filter { $0.record.location?.placeId == placeId }
    }

    private static func placeName(_ name: String) -> String {
        ServerText.clip(name.trimmingCharacters(in: .whitespacesAndNewlines), to: ServerText.maxName)
    }

    private static func placeRadius(_ radius: Double) -> Double {
        min(max(radius, LocationReminderPlanner.serverRadiusRange.lowerBound), LocationReminderPlanner.serverRadiusRange.upperBound)
    }

    // MARK: Projects

    @discardableResult
    func addProject(name: String) -> ProjectItem {
        let trimmed = ServerText.clip(name.trimmingCharacters(in: .whitespacesAndNewlines), to: ServerText.maxName)
        let project = ProjectItem(ProjectRecord(name: trimmed), dirty: true)
        context.insert(project)
        commit()
        return project
    }

    /// «إعادة التسمية»: owners and editors (the server checks the role).
    func rename(_ project: ProjectItem, to name: String) {
        let trimmed = ServerText.clip(name.trimmingCharacters(in: .whitespacesAndNewlines), to: ServerText.maxName)
        guard !trimmed.isEmpty, trimmed != project.name else { return }
        project.name = trimmed
        touch(project)
    }

    /// «أرشفة المشروع» and «استرجاع المشروع»: the project leaves the lists; its tasks keep their days.
    func setArchived(_ project: ProjectItem, _ archived: Bool) {
        guard (project.archivedAt != nil) != archived else { return }
        project.archivedAt = archived ? Milliseconds.now : nil
        touch(project)
    }

    /// «حذف المشروع», the owner's: its tasks, sections and their reminders go with it, hidden here
    /// at once. What the server already has goes with the project's deletion, for every member,
    /// and is not sent on its own; what it has not seen yet (still dirty, such as a task moved
    /// into the project offline) is sent as its own deletion.
    func delete(_ project: ProjectItem) {
        let id = project.id
        let tasks = ((try? context.fetch(FetchDescriptor<TaskItem>())) ?? []).filter { $0.projectId == id && !$0.pendingDelete }
        let taskIds = Set(tasks.map(\.id))
        for task in tasks {
            task.pendingDelete = true
        }
        for section in (try? context.fetch(FetchDescriptor<SectionItem>())) ?? [] where section.projectId == id && !section.pendingDelete {
            section.pendingDelete = true
        }
        for reminder in (try? context.fetch(FetchDescriptor<ReminderItem>())) ?? [] where taskIds.contains(reminder.taskId) && !reminder.pendingDelete {
            reminder.pendingDelete = true
        }
        project.pendingDelete = true
        touch(project)
    }

    // MARK: Saving

    func touch(_ item: some SyncedItem) {
        item.updatedAt = nextUpdatedAt(after: item.updatedAt)
        item.isDirty = true
        commit()
    }

    /// Saves and tells the sync engine. Internal so `Store+Board` can save a batch of edits once.
    func commit() {
        do {
            try context.save()
        } catch {
            // The context keeps the unsaved edit; the next save that succeeds writes it.
            Self.logger.error("Saving a local edit failed: \(error.localizedDescription)")
        }
        if let sync {
            // The app's listener reschedules notifications and reloads the widgets.
            sync.scheduleSync()
            sync.noteLocalChange()
        } else {
            ZimamShared.reloadTaskWidgets()
        }
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
        // A repeating span (a weekly two-day trip) keeps its length.
        record.startDate = task.span?.ending(on: next.day).startDate
        record.recurrence = next.rule.rrule
        record.createdAt = nil
        record.updatedAt = Milliseconds.now
        let copy = TaskItem(record, dirty: true)
        context.insert(copy)
        copyReminders(from: task.id, to: copy.id, fromDay: base, toDay: next.day, days: days)
    }

    /// Gives the next occurrence the same reminders; times (alone or with a place) move by as many
    /// days as the task did.
    private func copyReminders(from taskId: UUID, to newTaskId: UUID, fromDay: String, toDay: String, days: DualDateFormatter) {
        let reminders = (try? context.fetch(FetchDescriptor<ReminderItem>(predicate: #Predicate { $0.taskId == taskId }))) ?? []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = days.timeZone
        let shift = DayMath.days(from: fromDay, to: toDay) ?? 0
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
            } else if record.kind == .location, let at = record.at {
                // A place with a time: the time moves with the task, and the race starts again.
                guard let date = ReminderPlanner.date(fromISO: at),
                      let moved = calendar.date(byAdding: .day, value: shift, to: date) else { continue }
                record.at = ReminderPlanner.isoString(from: moved)
                record.firedAt = nil
            }
            context.insert(ReminderItem(record, dirty: true))
        }
    }
}
