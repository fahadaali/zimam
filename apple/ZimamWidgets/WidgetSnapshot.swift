import Foundation
import SwiftData
import SwiftUI
import ZimamKit

/// The store as the widgets read it, once per timeline.
struct WidgetSnapshot {
    let isSignedIn: Bool
    let calendar: CalendarKind
    /// The week's first column, 1 = Sunday (as `Calendar.firstWeekday`).
    let firstWeekday: Int
    let today: String
    let tomorrow: String
    let nextMidnight: Date
    /// Open tasks: not done and not deleted, with a date or without.
    let items: [WidgetItem]

    var formatter: DualDateFormatter {
        DualDateFormatter(primary: calendar, locale: ZimamLocale.current)
    }

    func grid(_ kind: CalendarKind? = nil) -> CalendarGrid {
        CalendarGrid(kind: kind ?? calendar, firstWeekday: firstWeekday, timeZone: .current)
    }

    /// Open top-level tasks with a due day, as the calendar widgets place them.
    var calendarItems: [WidgetItem] {
        items.filter { $0.isTopLevel && $0.dueDay != nil }
    }

    func item(_ id: UUID) -> WidgetItem? {
        items.first { $0.id == id }
    }

    /// How many task times one timeline holds; a busy day asks for a new one at the last.
    private static let maxTimes = 12

    /// Today's task times still ahead: moments a widget shows something new.
    func timesAhead(of now: Date) -> [Date] {
        Set(items.compactMap { item -> Date? in
            guard item.dueDay == today, let time = item.time, time > now, time < nextMidnight else { return nil }
            return time
        }).sorted()
    }

    /// An entry now, one at each of today's task times ahead when `atTaskTimes` (at most
    /// `maxTimes`); the timeline ends at `reloadDate(now:)`. The app also reloads the widgets
    /// after every change.
    func entryDates(now: Date, atTaskTimes: Bool) -> [Date] {
        atTaskTimes ? [now] + timesAhead(of: now).prefix(Self.maxTimes) : [now]
    }

    /// When to ask for a new timeline: midnight, or the last entry when today has more task
    /// times ahead than one timeline holds.
    func reloadDate(now: Date) -> Date {
        let times = timesAhead(of: now)
        return times.count > Self.maxTimes ? times[Self.maxTimes - 1] : nextMidnight
    }

    // MARK: Reading the store

    static func load(now: Date) -> WidgetSnapshot {
        let days = DayContext(now: now)
        guard let user = SharedSettings.user() else {
            return WidgetSnapshot(isSignedIn: false, calendar: .hijri, firstWeekday: Calendar.current.firstWeekday,
                                  today: days.today, tomorrow: days.tomorrow, nextMidnight: days.nextMidnight, items: [])
        }
        let schedule = SharedSettings.prayerSchedule()
        let context = ModelContext(ZimamStore.shared)
        let all = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.pendingDelete }))) ?? []
        let items = all.filter { !$0.isDone }.map { task -> WidgetItem in
            let span = WidgetTaskSpan.span(for: task)
            let time = task.dueDate.flatMap { days.time(dueDay: $0, dueTime: task.dueTime, prayer: task.duePrayer,
                                                        offset: task.duePrayerOffset, schedule: schedule) }
            return WidgetItem(id: task.id, title: task.title, priority: task.priority, isTopLevel: task.parentId == nil,
                              startDay: span?.start, dueDay: span?.end ?? task.dueDate, prayer: task.duePrayer,
                              prayerOffset: task.duePrayerOffset, sortOrder: task.sortOrder, time: time,
                              minuteOfDay: days.minute(of: time, prayer: task.duePrayer, offset: task.duePrayerOffset))
        }
        let start = user.settings.weekStart
        return WidgetSnapshot(isSignedIn: true, calendar: user.settings.calendar,
                              firstWeekday: (0...6).contains(start) ? start + 1 : Calendar.current.firstWeekday,
                              today: days.today, tomorrow: days.tomorrow, nextMidnight: days.nextMidnight, items: items)
    }

    /// For the widget gallery and placeholders: a believable week around today.
    static func placeholder(now: Date) -> WidgetSnapshot {
        let days = DayContext(now: now)
        func item(_ title: String, _ priority: TaskPriority, in offset: Int?, until end: Int? = nil,
                  at clock: String? = nil, prayer: Prayer? = nil, after minutes: Int? = nil) -> WidgetItem {
            let due = offset.map { days.day(in: end ?? $0) }
            let start = offset.map { days.day(in: $0) }
            let time = due.flatMap { days.time(dueDay: $0, dueTime: clock, prayer: prayer, offset: minutes, schedule: nil) }
            return WidgetItem(id: UUID(), title: title, priority: priority, isTopLevel: true, startDay: start, dueDay: due,
                              prayer: prayer, prayerOffset: minutes, sortOrder: 0, time: time,
                              minuteOfDay: days.minute(of: time, prayer: prayer, offset: minutes))
        }
        let items = [
            item("تجديد الاشتراك", .high, in: -1),
            item("مراجعة العقد", .high, in: 0, at: "10:00"),
            item("الاتصال بالوالدة", .medium, in: 0, prayer: .asr, after: 20),
            item("قراءة ورد اليوم", .none, in: 0, prayer: .fajr),
            item("اجتماع الفريق", .low, in: 1, at: "09:30"),
            item("رحلة إلى جدة", .low, in: 1, until: 3),
            item("شراء هدية", .medium, in: 2, at: "18:00"),
            item("خطة الأسبوع", .high, in: 5),
            item("حجز موعد الطبيب", .none, in: 8, at: "16:00"),
            item("ترتيب المكتبة", .none, in: nil),
            item("قراءة كتاب", .medium, in: nil),
        ]
        return WidgetSnapshot(isSignedIn: true, calendar: .hijri, firstWeekday: Calendar.current.firstWeekday,
                              today: days.today, tomorrow: days.tomorrow, nextMidnight: days.nextMidnight, items: items)
    }
}

/// Today, tomorrow and midnight in the device's time zone, and task times on a day.
private struct DayContext {
    let now: Date
    let gregorian: Calendar
    let formatter = DualDateFormatter()
    let today: String
    let tomorrow: String
    let nextMidnight: Date

    init(now: Date) {
        self.now = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        gregorian = calendar
        let start = calendar.startOfDay(for: now)
        nextMidnight = calendar.date(byAdding: .day, value: 1, to: start) ?? now.addingTimeInterval(86_400)
        today = DualDateFormatter().dayString(from: now)
        tomorrow = DualDateFormatter().dayString(from: nextMidnight.addingTimeInterval(3600))
    }

    func day(in offset: Int) -> String {
        formatter.dayString(from: gregorian.date(byAdding: .day, value: offset, to: now) ?? now)
    }

    /// Its clock time on the due day, or its prayer's time there when the place is known.
    func time(dueDay: String, dueTime: String?, prayer: Prayer?, offset: Int?, schedule: PrayerSchedule?) -> Date? {
        if let prayer {
            guard let schedule, let day = formatter.date(fromDay: dueDay) else { return nil }
            return schedule.time(of: prayer, on: day.addingTimeInterval(12 * 3600), offsetMinutes: offset ?? 0)
        }
        return GlanceSnapshot.time(dueTime, onDay: dueDay)
    }

    func minute(of time: Date?, prayer: Prayer?, offset: Int?) -> Int? {
        if let time {
            let parts = gregorian.dateComponents([.hour, .minute], from: time)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        guard let prayer else { return nil }
        // Without a place: the usual time each prayer falls at, as the app's lists order by.
        return TaskTiming.usualMinute(of: prayer) + (offset ?? 0)
    }
}
