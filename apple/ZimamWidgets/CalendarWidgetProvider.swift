import AppIntents
import Foundation
import WidgetKit
import ZimamKit

/// The month and week widgets' setting: which calendar lays out the grid.
struct CalendarWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "التقويم"
    static let description = IntentDescription("اختر التقويم الذي تُرتَّب به الأيام.")

    @Parameter(title: "التقويم", default: .automatic)
    var calendar: WidgetCalendarChoice

    init() {}
}

struct CalendarWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    /// The calendar the grid is laid out in.
    let kind: CalendarKind
}

/// An entry now and at each of today's task times (a time gone turns late in the week widget),
/// and a new timeline at midnight, when today moves.
struct CalendarWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CalendarWidgetEntry {
        let now = Date()
        return CalendarWidgetEntry(date: now, snapshot: .placeholder(now: now), kind: .hijri)
    }

    func snapshot(for configuration: CalendarWidgetConfiguration, in context: Context) async -> CalendarWidgetEntry {
        let now = Date()
        let snapshot = context.isPreview ? WidgetSnapshot.placeholder(now: now) : WidgetSnapshot.load(now: now)
        return CalendarWidgetEntry(date: now, snapshot: snapshot, kind: configuration.calendar.kind(default: snapshot.calendar))
    }

    func timeline(for configuration: CalendarWidgetConfiguration, in context: Context) async -> Timeline<CalendarWidgetEntry> {
        let now = Date()
        let snapshot = WidgetSnapshot.load(now: now)
        let kind = configuration.calendar.kind(default: snapshot.calendar)
        let entries = snapshot.entryDates(now: now, atTaskTimes: true).map {
            CalendarWidgetEntry(date: $0, snapshot: snapshot, kind: kind)
        }
        return Timeline(entries: entries, policy: .after(snapshot.nextMidnight))
    }
}
