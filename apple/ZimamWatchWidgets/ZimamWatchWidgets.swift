import SwiftUI
import WidgetKit
import ZimamKit

@main
struct ZimamWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        WatchGlanceWidget()
        WatchPrayerWidget()
    }
}

/// The next prayer's countdown, and for half an hour after the adhan the time since it, computed
/// on the watch from the place the iPhone sent (`WatchPrayerStore`). The views are the iPhone
/// Lock Screen's (Glance/PrayerGlanceViews.swift).
struct WatchPrayerWidget: Widget {
    static let kind = "app.zimam.watch.prayer"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: WatchPrayerProvider()) { entry in
            PrayerAccessoryView(entry: entry)
        }
        .configurationDisplayName("الصلاة القادمة")
        .description("المتبقي على الصلاة القادمة، وما مضى على الأذان.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct WatchPrayerProvider: TimelineProvider {
    func placeholder(in context: Context) -> PrayerEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (PrayerEntry) -> Void) {
        let place = WatchPrayerStore.read()
        completion(context.isPreview && place == nil ? .placeholder : PrayerEntry(date: Date(), place: place))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PrayerEntry>) -> Void) {
        completion(PrayerEntry.timeline(place: WatchPrayerStore.read()))
    }
}

/// The watch complications: the next task and today's count, in every accessory family.
/// The views are the iPhone Lock Screen's (Glance/GlanceViews.swift).
struct WatchGlanceWidget: Widget {
    static let kind = "app.zimam.watch.next"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: WatchGlanceProvider()) { entry in
            GlanceView(entry: entry)
        }
        .configurationDisplayName("التالي")
        .description("المهمة التالية وعدد مهام اليوم.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

/// Reads the snapshot the watch app saved in the watch's App Group (ZimamWatch/WatchGlance.swift).
/// The app reloads the timelines whenever it saves a new one; this adds an entry at each time
/// the next task changes today and a new timeline at midnight, when the day moves on.
struct WatchGlanceProvider: TimelineProvider {
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

    private static func load(now: Date) -> GlanceSnapshot {
        let today = DualDateFormatter().dayString(from: now)
        guard let saved = GlanceStore.read() else { return .signedOut(day: today) }
        return saved.reading(on: today)
    }
}
