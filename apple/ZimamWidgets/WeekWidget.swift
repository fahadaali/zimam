import AppIntents
import SwiftUI
import WidgetKit
import ZimamKit

/// «الأسبوع»: the seven days of this week (from the week start in settings) with both calendars'
/// day numbers, today ringed, and each day's tasks as chips with their time over the title; tasks
/// over several days are bars across them.
struct WeekWidget: Widget {
    static let kind = ZimamShared.WidgetKind.week

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: CalendarWidgetConfiguration.self, provider: CalendarWidgetProvider()) { entry in
            WeekWidgetView(entry: entry)
        }
        .configurationDisplayName("الأسبوع")
        .description("أيام الأسبوع ومهام كل يوم بأوقاتها.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct WeekWidgetView: View {
    let entry: CalendarWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode
    @ScaledMetric(relativeTo: .caption) private var lane = WidgetMetrics.tallLane
    /// Weekday initial, the day in a ring, the other calendar's day.
    @ScaledMetric(relativeTo: .caption) private var dayHeader = ZimamSpacing.space11 + ZimamSpacing.space3
    @ScaledMetric(relativeTo: .caption) private var ring = ZimamSpacing.space6

    var body: some View {
        let tone = WidgetTone(mode: mode)
        let snapshot = entry.snapshot
        let grid = snapshot.grid(entry.kind)
        let dates = DualDateFormatter(primary: entry.kind, locale: ZimamLocale.current)
        let week = grid.weekDays(containing: entry.date)
        let tasks = snapshot.calendarItems.compactMap(\.dated)

        VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
            if family != .systemMedium, let first = week.first, let last = week.last {
                Text(dates.rangeTitle(from: first.date, to: last.date, in: entry.kind))
                    .font(ZimamType.caption)
                    .foregroundStyle(tone.muted)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            if !snapshot.isSignedIn {
                WidgetNote(text: "سجّل الدخول في زمام لتظهر مهامك هنا.", tone: tone)
            } else {
                GeometryReader { geometry in
                    let column = geometry.size.width / 7
                    let room = geometry.size.height - dayHeader - ZimamSpacing.space1
                    let layout = WeekLanes.layout(days: week.map(\.day), tasks: tasks, lanes: max(0, Int(room / lane)))
                    VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
                        HStack(spacing: 0) {
                            ForEach(week) { day in
                                WeekColumnHead(day: day, isToday: day.day == snapshot.today, ring: ring,
                                               dates: dates, tone: tone)
                                    .frame(width: column, height: dayHeader)
                            }
                        }
                        WidgetLaneRows(layout: layout, snapshot: snapshot, columnWidth: column, laneHeight: lane,
                                       showsTime: true, tone: tone)
                        Spacer(minLength: 0)
                    }
                    .overlay {
                        WidgetDayLinks(days: week.map(\.day), columnWidth: column) { day in
                            dayLabel(day, week: week, layout: layout, dates: dates, snapshot: snapshot)
                        }
                    }
                }
            }
        }
        .zimamWidget(padding: ZimamSpacing.space3)
        .widgetURL(AppLink.calendar.url)
    }

    /// «الثلاثاء، ٢ جمادى الأولى، ١٣ أكتوبر، اليوم، ٣ مهام».
    private func dayLabel(_ day: String, week: [CalendarDay], layout: WeekLanes, dates: DualDateFormatter,
                          snapshot: WidgetSnapshot) -> String {
        guard let index = week.firstIndex(where: { $0.day == day }) else { return day }
        let date = week[index].date
        var parts = [dates.weekday(date), dates.dual(date)]
        if day == snapshot.today { parts.append("اليوم") }
        let count = layout.totalCounts.indices.contains(index) ? layout.totalCounts[index] : 0
        if count > 0 { parts.append(ArabicCount.tasks(count, locale: dates.locale)) }
        return parts.joined(separator: "، ")
    }
}

/// A day column's head: its weekday initial, its day in the grid's calendar (ringed today), and
/// its day in the other calendar.
private struct WeekColumnHead: View {
    let day: CalendarDay
    let isToday: Bool
    let ring: CGFloat
    let dates: DualDateFormatter
    let tone: WidgetTone

    var body: some View {
        VStack(spacing: 0) {
            Text(dates.weekdaySymbols([Calendar(identifier: .gregorian).component(.weekday, from: day.date)], short: true).first ?? "")
                .font(ZimamType.caption)
                .foregroundStyle(tone.muted)
            Text(dates.number(day.primaryDay))
                .font(ZimamType.caption)
                .foregroundStyle(tone.ink)
                .frame(width: ring, height: ring)
                .overlay {
                    if isToday {
                        Circle()
                            .strokeBorder(tone.ink, lineWidth: ZimamSpacing.space1 / 2)
                            .widgetAccentable()
                    }
                }
            Text(dates.number(day.secondaryDay))
                .font(ZimamType.caption)
                .foregroundStyle(tone.muted)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}
