import Foundation
import SwiftData
import ZimamKit

/// Today's open top-level tasks, as the Today screen lists them: due today or overdue,
/// by date and time. Used by the widgets and by Siri.
enum TodayTasks {
    /// Tasks in the order every day list shows them (Today, Upcoming, the calendar's day, the Today
    /// widget): by day, all-day tasks first, then by clock or prayer time, then their own order.
    /// Prayer times are solved once per day, and only for a day with a task tied to a prayer.
    static func ordered(_ tasks: [TaskItem], schedule: PrayerSchedule?, formatter: DualDateFormatter) -> [TaskItem] {
        var timesByDay: [String: [Prayer: Date]] = [:]
        func times(on day: String?) -> [Prayer: Date]? {
            guard let schedule, let day else { return nil }
            if let known = timesByDay[day] { return known }
            let solved = formatter.date(fromDay: day).map { schedule.times(on: $0.addingTimeInterval(12 * 3600)) } ?? [:]
            timesByDay[day] = solved
            return solved
        }
        // In steps with their types spelled out: as one chain, the compiler gives up type-checking it.
        var keyed: [(task: TaskItem, minute: Int)] = []
        keyed.reserveCapacity(tasks.count)
        for task in tasks {
            let mode: TaskTimeMode = task.timeMode
            let prayerTimes: [Prayer: Date]? = mode.prayer == nil ? nil : times(on: task.dueDate)
            let minute: Int? = TaskTiming.minuteOfDay(mode, prayerTimes: prayerTimes, timeZone: formatter.timeZone)
            keyed.append((task: task, minute: minute ?? -1))
        }
        keyed.sort(by: inDayOrder)
        return keyed.map { $0.task }
    }

    /// By day, then minute of the day (all-day first, as -1), then manual order, then creation.
    private static func inDayOrder(_ a: (task: TaskItem, minute: Int), _ b: (task: TaskItem, minute: Int)) -> Bool {
        let dayA: String = a.task.dueDate ?? ""
        let dayB: String = b.task.dueDate ?? ""
        if dayA != dayB { return dayA < dayB }
        if a.minute != b.minute { return a.minute < b.minute }
        if a.task.sortOrder != b.task.sortOrder { return a.task.sortOrder < b.task.sortOrder }
        return a.task.createdAt < b.task.createdAt
    }

    /// The API's day string for today, in the device's time zone.
    static func todayString(_ now: Date = Date()) -> String {
        DualDateFormatter().dayString(from: now)
    }

    static func fetch(in context: ModelContext, today: String) -> [TaskItem] {
        let all = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.pendingDelete }))) ?? []
        let open = all.filter { task in
            guard task.parentId == nil, !task.isDone, let due = task.dueDate else { return false }
            return due <= today
        }
        return ordered(open, schedule: SharedSettings.prayerSchedule(), formatter: DualDateFormatter())
    }
}
