import Foundation
import SwiftData
import ZimamKit

/// A task's span (its start and due days) for the calendar, «المخطط الزمني» and the task's
/// details, and its quadrant in «المصفوفة». Like every edit, these go through `Store` so they sync.
extension Store {
    // MARK: Spans

    /// Sets the days a task spans, from dragging a bar or «تغيير المدة…». A one-day span has no
    /// start day.
    func setSpan(_ task: TaskItem, _ span: DaySpan) {
        guard task.dueDate != span.dueDate || task.startDate != span.startDate else { return }
        update(task) { item in
            item.dueDate = span.dueDate
            item.startDate = span.startDate
        }
    }

    /// Sets the start day, or clears it with nil. A day after the due day (or a task with no due
    /// day) is refused with false, as the server would; the due day itself makes a one-day task.
    @discardableResult
    func setStartDate(_ task: TaskItem, _ day: String?) -> Bool {
        guard let day else {
            if task.startDate != nil { update(task) { item in item.startDate = nil } }
            return true
        }
        guard let due = task.dueDate, day <= due else { return false }
        let start: String? = day < due ? day : nil
        if start != task.startDate { update(task) { item in item.startDate = start } }
        return true
    }

    /// Sets or clears the due day. The start day stays while it is still before the new due day.
    /// A clock time needs a day, so clearing the day clears it; a prayer stays and repeats daily.
    func setDueDate(_ task: TaskItem, _ day: String?) {
        var start: String?
        if let current = task.startDate, let day, current < day { start = current }
        let time = day == nil ? nil : task.dueTime
        guard task.dueDate != day || task.startDate != start || task.dueTime != time else { return }
        update(task) { item in
            item.dueDate = day
            item.startDate = start
            item.dueTime = time
        }
    }

    // MARK: Time of day

    /// Sets when in its day the task falls: all day, a clock time, or around a prayer, which
    /// exclude each other. A clock time needs a day, so an undated task gets `today`. Going from
    /// all day to a time adds «عند الموعد», as a time the user sets is one they want to be told of.
    func setTime(_ task: TaskItem, _ mode: TaskTimeMode, today: String) {
        let current = task.timeMode
        guard current != mode else { return }
        update(task) { item in
            switch mode {
            case .allDay:
                item.dueTime = nil
                item.duePrayer = nil
                item.duePrayerOffset = nil
            case .clock(let hhmm):
                item.dueTime = hhmm
                item.duePrayer = nil
                item.duePrayerOffset = nil
                if item.dueDate == nil { item.dueDate = today }
            case .prayer(let prayer, let offset):
                item.dueTime = nil
                item.duePrayer = prayer
                item.duePrayerOffset = offset
            }
        }
        if current.isAllDay { ensureAtTimeReminder(task) }
    }

    /// Adds «عند الموعد» to a task with a time, unless it already has a reminder relative to it.
    func ensureAtTimeReminder(_ task: TaskItem) {
        guard !task.timeMode.isAllDay else { return }
        let taskId = task.id
        let relative = ReminderRecord.Kind.relative.rawValue
        let descriptor = FetchDescriptor<ReminderItem>(
            predicate: #Predicate { $0.taskId == taskId && $0.kindRaw == relative && !$0.pendingDelete })
        guard (try? context.fetchCount(descriptor)) == 0 else { return }
        addRelativeReminder(to: task.id, offsetMinutes: 0)
    }

    // MARK: The matrix

    /// Whether clearing the task's due day would lose more than the day: a time, a prayer, a
    /// repeat, a start day or a reminder (`PriorityMatrix.move`, rule 4).
    func isAnchored(_ task: TaskItem) -> Bool {
        if task.dueTime != nil || task.duePrayer != nil || task.recurrence != nil || task.startDate != nil { return true }
        let taskId = task.id
        let descriptor = FetchDescriptor<ReminderItem>(predicate: #Predicate { $0.taskId == taskId && !$0.pendingDelete })
        // If the count fails, the safe answer is yes: refusing the move keeps the reminders,
        // while moving would clear the day they depend on.
        guard let reminders = try? context.fetchCount(descriptor) else { return true }
        return reminders > 0
    }

    /// Moves a task to another quadrant by the rules in `PriorityMatrix.move`, and returns what
    /// happened so the screen can say it.
    @discardableResult
    func move(_ task: TaskItem, to quadrant: ZimamKit.PriorityQuadrant, timeZone: TimeZone) -> ZimamKit.PriorityMatrix.Move {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let result = ZimamKit.PriorityMatrix.move(priority: task.priority, dueDate: task.dueDate, isAnchored: isAnchored(task),
                                         to: quadrant, calendar: calendar)
        guard case .moved(let priority, let dueDate) = result else { return result }
        // A span moved to today keeps its length, as in the calendar.
        let start = dueDate.flatMap { day in task.span?.ending(on: day).startDate }
        update(task) { item in
            item.priority = priority
            if item.dueDate != dueDate {
                item.dueDate = dueDate
                item.startDate = start
            }
        }
        return result
    }
}
