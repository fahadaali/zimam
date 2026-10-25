import Foundation
import WidgetKit
import ZimamKit

/// Feeds the watch complications (ZimamWatchWidgets). The complications cannot call the API
/// (the session token is the watch app's), so the app writes what they show to the watch's
/// App Group after each refresh, completion and addition, and asks WidgetKit to redraw.
enum WatchGlance {
    /// Today's open tasks from the API's order (overdue first, then by time), the count still
    /// open and the count done today. A prayer task gets its prayer's time from the place the
    /// iPhone sent (`WatchPrayerStore`), as on the Lock Screen; before one arrives it shows its
    /// phrase («بعد العصر بـ٢٠ د») alone.
    static func publish(tasks: [TaskRecord], doneCount: Int, isSignedIn: Bool, calendar: CalendarKind) {
        let today = DualDateFormatter().dayString(from: Date())
        let snapshot: GlanceSnapshot
        if isSignedIn {
            let locale = ZimamLocale.current
            let open = tasks.filter { $0.parentId == nil && $0.status != .done }
            let schedule = WatchPrayerStore.read()?.schedule
            let noon = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
            let items = open.map { task in
                let isOverdue = (task.dueDate ?? today) < today
                var time: Date?
                if !isOverdue {
                    if let prayer = task.duePrayer {
                        time = schedule?.time(of: prayer, on: noon, offsetMinutes: task.duePrayerOffset ?? 0)
                    } else {
                        time = GlanceSnapshot.time(task.dueTime, onDay: today)
                    }
                }
                return GlanceSnapshot.Item(
                    id: task.id,
                    title: task.title,
                    prayerText: task.duePrayer.map { PrayerPhrase.text($0, offsetMinutes: task.duePrayerOffset, locale: locale) },
                    time: time,
                    isOverdue: isOverdue
                )
            }
            snapshot = GlanceSnapshot(isSignedIn: true, calendar: calendar.rawValue, day: today,
                                      openCount: open.count, doneCount: doneCount, items: GlanceSnapshot.kept(items))
        } else {
            snapshot = .signedOut(day: today)
        }
        if GlanceStore.write(snapshot) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
