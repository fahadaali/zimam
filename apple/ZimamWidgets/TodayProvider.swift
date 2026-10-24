import Foundation
import SwiftData
import WidgetKit
import ZimamKit

/// One open task as the widget shows it, read out of the store.
struct WidgetTask: Identifiable {
    let id: UUID
    let title: String
    let prayer: Prayer?
    let prayerOffset: Int?
    /// Due on an earlier day.
    let isOverdue: Bool
}

struct TodayEntry: TimelineEntry {
    let date: Date
    let isSignedIn: Bool
    let calendar: CalendarKind
    /// Today's open tasks, overdue ones first.
    let tasks: [WidgetTask]
    /// The small widget's next task, by the Lock Screen's rule (`GlanceSnapshot.next(at:)`): the
    /// soonest time still ahead today, otherwise the first in the Today order.
    let next: WidgetTask?
    /// The prayer-anchored task due next today, for the large widget's prayer chip.
    let nextPrayerTask: WidgetTask?
    /// That task's prayer time, when the place is known: the chip shows it after the phrase.
    var nextPrayerTime: Date? = nil

    static let placeholder = TodayEntry(
        date: Date(),
        isSignedIn: true,
        calendar: .hijri,
        tasks: [
            WidgetTask(id: UUID(), title: "مراجعة العقد", prayer: .asr, prayerOffset: 20, isOverdue: false),
            WidgetTask(id: UUID(), title: "الاتصال بالوالدة", prayer: nil, prayerOffset: nil, isOverdue: false),
            WidgetTask(id: UUID(), title: "شراء هدية", prayer: nil, prayerOffset: nil, isOverdue: false),
            WidgetTask(id: UUID(), title: "قراءة ورد اليوم", prayer: .fajr, prayerOffset: 0, isOverdue: false),
        ],
        next: WidgetTask(id: UUID(), title: "مراجعة العقد", prayer: .asr, prayerOffset: 20, isOverdue: false),
        nextPrayerTask: WidgetTask(id: UUID(), title: "مراجعة العقد", prayer: .asr, prayerOffset: 20, isOverdue: false)
    )
}

/// Builds the timeline from the shared store: one entry now, one at each task's time today, by
/// the clock or its prayer (so the small widget's next task and the large widget's prayer task
/// move on), and a new timeline at midnight, or at the last entry on a day with more times than
/// one timeline holds. The app reloads it after every change.
struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }
        let now = Date()
        completion(TodayData.load(now: now).entry(at: now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let now = Date()
        let data = TodayData.load(now: now)
        let times = data.upcomingTimes(after: now)
        let shown = Array(times.prefix(TodayData.maxTimes))
        let entries = ([now] + shown).map { data.entry(at: $0) }
        let reload = times.count > shown.count ? (shown.last ?? data.nextMidnight) : data.nextMidnight
        completion(Timeline(entries: entries, policy: .after(reload)))
    }
}

/// What one read of the store gives; entries for different times of the day come from it.
struct TodayData {
    let isSignedIn: Bool
    let calendar: CalendarKind
    let tasks: [WidgetTask]
    /// When each of today's prayer-anchored tasks falls, when the place is known.
    let prayerTimes: [UUID: Date]
    /// When each of today's tasks with a clock time falls.
    let clockTimes: [UUID: Date]
    let nextMidnight: Date

    /// How many times ahead one timeline holds.
    static let maxTimes = 10

    static func load(now: Date) -> TodayData {
        let today = TodayTasks.todayString(now)
        let context = ModelContext(ZimamStore.shared)
        let items = TodayTasks.fetch(in: context, today: today)
        let tasks = items.map { item in
            WidgetTask(id: item.id, title: item.title, prayer: item.duePrayer, prayerOffset: item.duePrayerOffset,
                       isOverdue: (item.dueDate ?? today) < today)
        }

        var times: [UUID: Date] = [:]
        if let schedule = SharedSettings.prayerSchedule() {
            let noon = Calendar.current.startOfDay(for: now).addingTimeInterval(12 * 3600)
            for task in tasks where !task.isOverdue {
                guard let prayer = task.prayer else { continue }
                times[task.id] = schedule.time(of: prayer, on: noon, offsetMinutes: task.prayerOffset ?? 0)
            }
        }
        var clock: [UUID: Date] = [:]
        for item in items where item.duePrayer == nil && (item.dueDate ?? today) >= today {
            if let time = GlanceSnapshot.time(item.dueTime, onDay: today) { clock[item.id] = time }
        }

        let user = SharedSettings.user()
        let calendar = Calendar.current
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(3600)
        return TodayData(isSignedIn: user != nil, calendar: user?.settings.calendar ?? .hijri, tasks: tasks,
                         prayerTimes: times, clockTimes: clock, nextMidnight: midnight)
    }

    /// Today's task times still ahead, by the clock or a prayer: each a moment the next task changes.
    func upcomingTimes(after now: Date) -> [Date] {
        Set((Array(prayerTimes.values) + clockTimes.values).filter { $0 > now && $0 < nextMidnight }).sorted()
    }

    func entry(at date: Date) -> TodayEntry {
        let prayerTask = nextPrayerTask(at: date)
        return TodayEntry(date: date, isSignedIn: isSignedIn, calendar: calendar, tasks: tasks, next: next(at: date),
                          nextPrayerTask: prayerTask, nextPrayerTime: prayerTask.flatMap { prayerTimes[$0.id] })
    }

    /// As `GlanceSnapshot.next(at:)`, ties included (the tasks are in the Today order): the
    /// soonest time still ahead, otherwise the first task.
    private func next(at date: Date) -> WidgetTask? {
        let times = prayerTimes.merging(clockTimes) { prayer, _ in prayer }
        var best: (task: WidgetTask, time: Date)?
        for task in tasks {
            guard let time = times[task.id], time > date else { continue }
            if best == nil || time < best!.time { best = (task, time) }
        }
        return best?.task ?? tasks.first
    }

    /// The prayer-anchored task due next. Without a saved place, the first by prayer order.
    private func nextPrayerTask(at date: Date) -> WidgetTask? {
        let anchored = tasks.filter { $0.prayer != nil && !$0.isOverdue }
        if prayerTimes.isEmpty {
            return anchored.min { first, second in
                order(first) < order(second)
            }
        }
        var best: WidgetTask?
        var bestTime: Date?
        for task in anchored {
            guard let time = prayerTimes[task.id], time > date else { continue }
            if bestTime == nil || time < bestTime! {
                best = task
                bestTime = time
            }
        }
        return best
    }

    private func order(_ task: WidgetTask) -> Int {
        let index = task.prayer.flatMap { Prayer.allCases.firstIndex(of: $0) } ?? 0
        return index * 1000 + (task.prayerOffset ?? 0)
    }
}
