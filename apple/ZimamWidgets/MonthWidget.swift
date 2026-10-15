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

/// The month and week widgets' setting: which calendar lays out the grid.
struct CalendarWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "التقويم"
    static var description = IntentDescription("اختر التقويم الذي تُرتَّب به الأيام.")

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
            ForEach(rows.indices, id: \.self) { index in
                weekRow(Array(days[(index * 7)..<min(index * 7 + 7, days.count)]), layout: rows[index], column: column)
                    .frame(height: rowHeight)
            }
        }
    }

    private func weekRow(_ cells: [CalendarDay], layout: WeekLanes, column: CGFloat) -> some View {
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
                dayLabel(day, cells: cells, layout: layout)
            }
        }
    }

    /// «الثلاثاء، ٢ جمادى الأولى، ١٣ أكتوبر، اليوم، ٣ مهام».
    private func dayLabel(_ day: String, cells: [CalendarDay], layout: WeekLanes) -> String {
        guard let index = cells.firstIndex(where: { $0.day == day }) else { return day }
        let date = cells[index].date
        var parts = [dates.weekday(date), dates.dual(date)]
        if day == snapshot.today { parts.append("اليوم") }
        let count = layout.totalCounts.indices.contains(index) ? layout.totalCounts[index] : 0
        if count > 0 { parts.append(ArabicCount.tasks(count, locale: dates.locale)) }
        return parts.joined(separator: "، ")
    }
}

/// Weekday initials over the columns, the week's first day at the leading edge.
struct WeekdayHeader: View {
    let grid: CalendarGrid
    let dates: DualDateFormatter
    let tone: WidgetTone

    var body: some View {
        let symbols = dates.weekdaySymbols(grid.weekdayOrder, short: true)
        HStack(spacing: 0) {
            ForEach(symbols.indices, id: \.self) { index in
                Text(symbols[index])
                    .font(ZimamType.caption)
                    .foregroundStyle(tone.muted)
                    .lineLimit(1)
                    .padding(.leading, ZimamSpacing.space1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
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

/// A week row's lanes as `WeekLanes` laid them out: bars, chips and «+n», column 0 at the leading
/// edge. Each lane is one row of segments, so the right-to-left layout places them.
struct WidgetLaneRows: View {
    let layout: WeekLanes
    let snapshot: WidgetSnapshot
    let columnWidth: CGFloat
    let laneHeight: CGFloat
    /// The week widget shows each chip's time over its title.
    let showsTime: Bool
    let tone: WidgetTone

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<layout.laneCount, id: \.self) { lane in
                HStack(spacing: 0) {
                    ForEach(layout.segments(inLane: lane)) { segment in
                        content(segment)
                            .frame(width: columnWidth * CGFloat(segment.columnCount), height: laneHeight)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ segment: WeekLanes.Segment) -> some View {
        if let placement = segment.placement {
            switch placement.content {
            case .task(let task):
                if let item = snapshot.item(task.id) {
                    WidgetTaskChip(item: item, time: showsTime && !item.isSpan ? chipTime(item) : nil,
                                   continuesBefore: placement.continuesBefore, continuesAfter: placement.continuesAfter,
                                   tone: tone)
                        .padding(.vertical, WidgetMetrics.gap / 2)
                        .padding(.leading, placement.continuesBefore ? 0 : WidgetMetrics.gap / 2)
                        .padding(.trailing, placement.continuesAfter ? 0 : WidgetMetrics.gap / 2)
                } else {
                    Color.clear
                }
            case .more(let count):
                WidgetMoreLabel(count: count, tone: tone, locale: snapshot.formatter.locale)
            }
        } else {
            Color.clear
        }
    }

    /// «١٦:٤٢», or the prayer's name for a task tied to one.
    private func chipTime(_ item: WidgetItem) -> String? {
        if let prayer = item.prayer { return prayer.arabicName }
        return item.time.map { snapshot.formatter.compactTime($0) }
    }
}

/// A transparent link over each day column, to open that day in the app's calendar.
struct WidgetDayLinks: View {
    let days: [String]
    let columnWidth: CGFloat
    let label: (String) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                Link(destination: AppLink.day(day).url) {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .frame(width: columnWidth)
                .accessibilityLabel(label(day))
            }
        }
    }
}
