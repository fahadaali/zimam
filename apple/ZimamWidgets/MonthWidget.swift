import AppIntents
import SwiftUI
import WidgetKit
import ZimamKit

/// «الشهر»: the month grid with each day's tasks as chips, tasks over several days as bars across
/// their days, «+n» for what does not fit, today highlighted, and both calendars' day numbers.
/// The month is in the user's primary calendar unless the widget is set to the other one.
struct MonthWidget: Widget {
    static let kind = "app.zimam.month"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: CalendarWidgetConfiguration.self, provider: CalendarWidgetProvider()) { entry in
            MonthWidgetView(entry: entry)
        }
        .configurationDisplayName("الشهر")
        .description("مهام الشهر في شبكته، بالهجري والميلادي.")
        .supportedFamilies([.systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}

struct MonthWidgetView: View {
    let entry: CalendarWidgetEntry
    @Environment(\.widgetRenderingMode) private var mode
    @ScaledMetric(relativeTo: .caption) private var lane = WidgetMetrics.lane
    @ScaledMetric(relativeTo: .caption) private var numbersRow = WidgetMetrics.lane

    var body: some View {
        let tone = WidgetTone(mode: mode)
        let snapshot = entry.snapshot
        let grid = snapshot.grid(entry.kind)
        let dates = DualDateFormatter(primary: entry.kind, locale: ZimamLocale.current)
        let days = grid.monthDays(containing: entry.date)
        let title = dates.monthTitleParts(entry.date, in: entry.kind)
        let tasks = snapshot.calendarItems.compactMap(\.dated)

        VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
            HStack(alignment: .firstTextBaseline, spacing: ZimamSpacing.space2) {
                Text(title.primary)
                    .font(ZimamType.headline)
                    .foregroundStyle(tone.ink)
                    .lineLimit(1)
                    .widgetAccentable()
                    .accessibilityAddTraits(.isHeader)
                Text(title.other)
                    .font(ZimamType.caption)
                    .foregroundStyle(tone.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if snapshot.isSignedIn {
                    WidgetCountBadge(count: openCount(tasks, days: days), tone: tone, locale: dates.locale)
                }
            }
            if !snapshot.isSignedIn {
                Text("سجّل الدخول في زمام لتظهر مهامك هنا.")
                    .font(ZimamType.caption)
                    .foregroundStyle(tone.muted)
                    .lineLimit(1)
            }
            WeekdayHeader(grid: grid, dates: dates, tone: tone)

            GeometryReader { geometry in
                MonthGridBody(days: days, tasks: tasks, size: geometry.size, numbersRow: numbersRow, lane: lane,
                              snapshot: snapshot, dates: dates, tone: tone)
            }
        }
        .zimamWidget(padding: ZimamSpacing.space3)
        .widgetURL(AppLink.calendar.url)
    }

    /// Open tasks on the month's own days, a task over several days counted once.
    private func openCount(_ tasks: [DatedTask], days: [CalendarDay]) -> Int {
        let inMonth = days.filter(\.isInPeriod)
        guard let first = inMonth.first?.day, let last = inMonth.last?.day else { return 0 }
        return tasks.filter { $0.startDay <= last && $0.endDay >= first }.count
    }
}

/// The month's weeks, each as tall as the space allows, with as many lanes of chips as fit under
/// the day numbers.
private struct MonthGridBody: View {
    let days: [CalendarDay]
    let tasks: [DatedTask]
    let size: CGSize
    let numbersRow: CGFloat
    let lane: CGFloat
    let snapshot: WidgetSnapshot
    let dates: DualDateFormatter
    let tone: WidgetTone

    var body: some View {
        let weeks = max(days.count / 7, 1)
        let rowHeight = size.height / CGFloat(weeks)
        let column = size.width / 7
        let lanes = max(0, Int((rowHeight - numbersRow - WidgetMetrics.gap) / lane))
        let rows = WeekLanes.layout(weeksOf: days.map(\.day), tasks: tasks, lanes: lanes)
        VStack(spacing: 0) {
            // Each week is known by its days, so a new day or month redraws only what moved.
            ForEach(Array(rows.enumerated()), id: \.element.days) { index, layout in
                MonthWeekRow(cells: Array(days[(index * 7)..<min(index * 7 + 7, days.count)]), layout: layout,
                             column: column, numbersRow: numbersRow, lane: lane, snapshot: snapshot,
                             dates: dates, tone: tone)
                    .frame(height: rowHeight)
            }
        }
    }
}

/// One week of the month: the day numbers, the lanes of chips under them, and a link over each day.
private struct MonthWeekRow: View {
    let cells: [CalendarDay]
    let layout: WeekLanes
    let column: CGFloat
    let numbersRow: CGFloat
    let lane: CGFloat
    let snapshot: WidgetSnapshot
    let dates: DualDateFormatter
    let tone: WidgetTone

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(cells) { cell in
                    MonthDayNumbers(day: cell, isToday: cell.day == snapshot.today, dates: dates, tone: tone)
                        .frame(width: column, height: numbersRow)
                }
            }
            WidgetLaneRows(layout: layout, snapshot: snapshot, columnWidth: column, laneHeight: lane,
                           showsTime: false, tone: tone)
            Spacer(minLength: 0)
        }
        .overlay {
            WidgetDayLinks(days: cells.map(\.day), columnWidth: column) { day in
                dayLabel(day)
            }
        }
    }

    /// «الثلاثاء، ٢ جمادى الأولى، ١٣ أكتوبر، اليوم، ٣ مهام».
    private func dayLabel(_ day: String) -> String {
        guard let index = cells.firstIndex(where: { $0.day == day }) else { return day }
        let date = cells[index].date
        var parts = [dates.weekday(date), dates.dual(date)]
        if day == snapshot.today { parts.append("اليوم") }
        let count = layout.totalCounts.indices.contains(index) ? layout.totalCounts[index] : 0
        if count > 0 { parts.append(ArabicCount.tasks(count, locale: dates.locale)) }
        return parts.joined(separator: "، ")
    }
}

/// A month cell's numbers: the grid calendar's day (in a filled capsule today) and the other
/// calendar's beside it while there is room. Days of the months around are faint.
private struct MonthDayNumbers: View {
    let day: CalendarDay
    let isToday: Bool
    let dates: DualDateFormatter
    let tone: WidgetTone

    var body: some View {
        ViewThatFits(in: .horizontal) {
            numbers(withOther: true)
            numbers(withOther: false)
        }
        .padding(.leading, ZimamSpacing.space1 / 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    private func numbers(withOther: Bool) -> some View {
        HStack(spacing: ZimamSpacing.space1 / 2) {
            Text(dates.number(day.primaryDay))
                .font(ZimamType.caption)
                .foregroundStyle(isToday ? tone.onSolid : day.isInPeriod ? tone.ink : tone.faint)
                .padding(.horizontal, ZimamSpacing.space1)
                .background {
                    if isToday {
                        if tone.isFullColor {
                            Capsule().fill(ZimamColor.ink)
                        } else {
                            Capsule().strokeBorder(.primary, lineWidth: ZimamSpacing.space1 / 2)
                        }
                    }
                }
                .widgetAccentable(isToday)
            if withOther {
                Text(dates.number(day.secondaryDay))
                    .font(ZimamType.caption)
                    .foregroundStyle(day.isInPeriod ? tone.muted : tone.faint)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}
