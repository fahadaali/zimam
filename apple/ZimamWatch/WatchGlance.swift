import Foundation
import WidgetKit
import ZimamKit

/// Feeds the watch complications (ZimamWatchWidgets). The complications cannot call the API
/// (the session token is the watch app's), so the app writes what they show to the watch's
/// App Group after each refresh, completion and addition, and asks WidgetKit to redraw.
enum WatchGlance {
    /// Today's open tasks from the API's order (overdue first, then by time), the count still
    /// open and the count done today. The watch has no place for prayer times, so a prayer
    /// task shows its phrase («بعد العصر بـ٢٠ د») without a clock time.
    static func publish(tasks: [TaskRecord], doneCount: Int, isSignedIn: Bool, calendar: CalendarKind) {
        let today = DualDateFormatter().dayString(from: Date())
        let snapshot: GlanceSnapshot
        if isSignedIn {
            let locale = ZimamLocale.current
            let open = tasks.filter { $0.parentId == nil && $0.status != .done }
            let items = open.prefix(GlanceSnapshot.maxItems).map { task in
                let isOverdue = (task.dueDate ?? today) < today
                return GlanceSnapshot.Item(
                    id: task.id,
                    title: task.title,
                    prayerText: task.duePrayer.map { PrayerPhrase.text($0, offsetMinutes: task.duePrayerOffset, locale: locale) },
                    time: isOverdue || task.duePrayer != nil ? nil : GlanceSnapshot.time(task.dueTime, onDay: today),
                    isOverdue: isOverdue
                )
            }
            snapshot = GlanceSnapshot(isSignedIn: true, calendar: calendar.rawValue, day: today,
                                      openCount: open.count, doneCount: doneCount, items: Array(items))
        } else {
            snapshot = .signedOut(day: today)
        }
        if GlanceStore.write(snapshot) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
