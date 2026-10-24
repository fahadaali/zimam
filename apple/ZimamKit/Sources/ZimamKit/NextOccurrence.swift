import Foundation

/// The next occurrence of a recurring task once it is completed, the same on the phone (`Store`)
/// and the watch, which builds it from the API instead of a local store.
public enum NextOccurrence {
    /// The copy due on the rule's next day after the task's (and not before `today`), or nil when
    /// the series ends. A repeating span (a weekly two-day trip) keeps its length.
    public static func task(after task: TaskRecord, today: String, timeZone: TimeZone, now: Milliseconds = .now) -> TaskRecord? {
        guard let text = task.recurrence, let rule = Recurrence(rrule: text) else { return nil }
        let base = task.dueDate ?? today
        guard let next = rule.nextOccurrence(after: base, notBefore: today, timeZone: timeZone) else { return nil }
        var record = task
        record.id = UUID()
        record.status = .todo
        record.completedAt = nil
        record.dueDate = next.day
        record.startDate = DaySpan(startDate: task.startDate, dueDate: task.dueDate)?.ending(on: next.day).startDate
        record.recurrence = next.rule.rrule
        record.createdAt = nil
        record.updatedAt = now
        return record
    }

    /// Whether `other` already is the occurrence of `task` due `day`: open, with the same title,
    /// parent and project. Completing, reopening and completing again then adds it once.
    public static func isSame(_ other: TaskRecord, as task: TaskRecord, on day: String) -> Bool {
        other.id != task.id && other.status != .done && other.dueDate == day
            && other.title == task.title && other.parentId == task.parentId && other.projectId == task.projectId
    }

    /// The task's reminders for its next occurrence, moved to `taskId`: times (alone or with a
    /// place) move by as many days as the task did, and a place with a time races again. One whose
    /// time cannot be read is left out.
    public static func reminders(_ reminders: [ReminderRecord], movedTo taskId: UUID, from fromDay: String, to toDay: String,
                                 timeZone: TimeZone, now: Milliseconds = .now) -> [ReminderRecord] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let shift = DayMath.days(from: fromDay, to: toDay) ?? 0
        func moved(_ at: String) -> String? {
            guard let date = ReminderPlanner.date(fromISO: at),
                  let moved = calendar.date(byAdding: .day, value: shift, to: date) else { return nil }
            return ReminderPlanner.isoString(from: moved, timeZone: timeZone)
        }
        return reminders.compactMap { reminder in
            var record = reminder
            record.id = UUID()
            record.taskId = taskId
            record.createdAt = nil
            record.updatedAt = now
            if record.kind == .time {
                guard let at = record.at, let shifted = moved(at) else { return nil }
                record.at = shifted
            } else if record.kind == .location, let at = record.at {
                guard let shifted = moved(at) else { return nil }
                record.at = shifted
                record.firedAt = nil
            }
            return record
        }
    }
}
