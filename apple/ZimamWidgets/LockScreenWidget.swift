#if os(iOS)
import Foundation
import SwiftData
import SwiftUI
import WidgetKit
import ZimamKit

/// The Lock Screen widgets: the next task with its time or prayer (rectangular), today's open
/// count in a ring of what is done (circular), and the next task's title above the clock (inline).
/// The views are shared with the watch complications (Glance/GlanceViews.swift).
struct LockScreenWidget: Widget {
    static let kind = "app.zimam.next"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: LockScreenProvider()) { entry in
            GlanceView(entry: entry)
        }
        .configurationDisplayName("التالي")
        .description("المهمة التالية ووقتها، وعدد مهام اليوم.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

/// Reads the shared store like the Today widget: an entry now, one at each time the next task
/// changes today, and a new timeline at midnight. The app reloads it after every change.
struct LockScreenProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }
        let now = Date()
        completion(GlanceEntry(date: now, snapshot: Self.load(now: now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        let now = Date()
        let snapshot = Self.load(now: now)
        let calendar = Calendar.current
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(3600)
        let dates = [now] + snapshot.changeTimes(after: now, before: midnight)
        let entries = dates.map { GlanceEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(midnight)))
    }

    /// Today's open tasks as the Today screen lists them, with each one's time today: its own
    /// time, or its prayer's time when the place is known.
    static func load(now: Date) -> GlanceSnapshot {
        let today = TodayTasks.todayString(now)
        guard let user = SharedSettings.user() else { return .signedOut(day: today) }

        let context = ModelContext(ZimamStore.shared)
        let open = TodayTasks.fetch(in: context, today: today)
        let schedule = SharedSettings.prayerSchedule()
        let locale = ZimamLocale.current
        let noon = Calendar.current.startOfDay(for: now).addingTimeInterval(12 * 3600)

        let items = open.prefix(GlanceSnapshot.maxItems).map { task in
            let isOverdue = (task.dueDate ?? today) < today
            var time: Date?
            var prayerText: String?
            if let prayer = task.duePrayer {
                prayerText = PrayerPhrase.text(prayer, offsetMinutes: task.duePrayerOffset, locale: locale)
                if !isOverdue {
                    time = schedule?.time(of: prayer, on: noon, offsetMinutes: task.duePrayerOffset ?? 0)
                }
            } else if !isOverdue {
                time = GlanceSnapshot.time(task.dueTime, onDay: today)
            }
            return GlanceSnapshot.Item(id: task.id, title: task.title, prayerText: prayerText, time: time, isOverdue: isOverdue)
        }

        let all = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.pendingDelete }))) ?? []
        let doneCount = all.filter { $0.parentId == nil && $0.isDone && $0.dueDate == today }.count

        return GlanceSnapshot(isSignedIn: true, calendar: user.settings.calendar.rawValue, day: today,
                              openCount: open.count, doneCount: doneCount, items: Array(items))
    }
}
#endif
