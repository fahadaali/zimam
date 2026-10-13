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
    /// The prayer-anchored task due next today, for the large widget's prayer chip.
    let nextPrayerTask: WidgetTask?

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
        nextPrayerTask: WidgetTask(id: UUID(), title: "مراجعة العقد", prayer: .asr, prayerOffset: 20, isOverdue: false)
    )
}

/// Builds the timeline from the shared store: one entry now, one at each prayer-anchored
/// task's time today (so the large widget moves to the next one), and a new timeline at
/// midnight. The app reloads it after every change.
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
        let dates = [now] + data.upcomingTimes(after: now)
        let entries = dates.map { data.entry(at: $0) }
        completion(Timeline(entries: entries, policy: .after(data.nextMidnight)))
    }
}

/// What one read of the store gives; entries for different times of the day come from it.
struct TodayData {
    let isSignedIn: Bool
    let calendar: CalendarKind
    let tasks: [WidgetTask]
    /// When each of today's prayer-anchored tasks falls, when the place is known.
    let prayerTimes: [UUID: Date]
    let nextMidnight: Date

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
            for task in tasks where !task.isOverdue {
                guard let prayer = task.prayer else { continue }
                times[task.id] = schedule.time(of: prayer, on: now, offsetMinutes: task.prayerOffset ?? 0)
            }
        }

        let user = SharedSettings.user()
        let calendar = Calendar.current
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(3600)
        return TodayData(isSignedIn: user != nil, calendar: user?.settings.calendar ?? .hijri, tasks: tasks,
                         prayerTimes: times, nextMidnight: midnight)
    }

    /// Today's prayer-anchored times still ahead, each a moment the next prayer task changes.
    func upcomingTimes(after now: Date) -> [Date] {
        let ahead = Set(prayerTimes.values.filter { $0 > now && $0 < nextMidnight })
        return Array(ahead.sorted().prefix(10))
    }

    func entry(at date: Date) -> TodayEntry {
        TodayEntry(date: date, isSignedIn: isSignedIn, calendar: calendar, tasks: tasks, nextPrayerTask: nextPrayerTask(at: date))
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
