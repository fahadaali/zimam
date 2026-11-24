import SwiftUI
import WidgetKit
import ZimamKit

/// «القادم مع التقويم»: the next open tasks (overdue first, then by day and time) with their time
/// or prayer and a completion circle, beside three weeks of the calendar from this week.
struct UpcomingWidget: Widget {
    static let kind = ZimamShared.WidgetKind.upcoming

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: UpcomingProvider()) { entry in
            UpcomingWidgetView(entry: entry)
        }
        .configurationDisplayName("القادم مع التقويم")
        .description("المهام القادمة بأوقاتها، وثلاثة أسابيع من التقويم.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

struct UpcomingEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// An entry now and at each of today's task times (a time gone turns late), and a new timeline
/// at midnight.
struct UpcomingProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpcomingEntry {
        let now = Date()
        return UpcomingEntry(date: now, snapshot: .placeholder(now: now))
    }

    func getSnapshot(in context: Context, completion: @escaping (UpcomingEntry) -> Void) {
        let now = Date()
        completion(UpcomingEntry(date: now, snapshot: context.isPreview ? .placeholder(now: now) : .load(now: now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UpcomingEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshot.load(now: now)
        let entries = snapshot.entryDates(now: now, atTaskTimes: true).map { UpcomingEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(snapshot.reloadDate(now: now))))
    }
}

struct UpcomingWidgetView: View {
    let entry: UpcomingEntry
    @Environment(\.widgetRenderingMode) private var mode
    @ScaledMetric(relativeTo: .headline) private var header = ZimamSpacing.space6
    @ScaledMetric(relativeTo: .caption) private var moreLine = ZimamSpacing.space4 + ZimamSpacing.space1

    var body: some View {
        let tone = WidgetTone(mode: mode)
        let snapshot = entry.snapshot
        HStack(alignment: .top, spacing: ZimamSpacing.space3) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: ZimamSpacing.space1) {
                    Image(systemName: "clock")
                        .accessibilityHidden(true)
                    Text("القادم")
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                }
                .widgetFont(.headline)
                .foregroundStyle(tone.ink)
                .widgetAccentable()
                .frame(height: header)

                if !snapshot.isSignedIn {
                    WidgetNote(text: "سجّل الدخول في زمام لتظهر مهامك هنا.", tone: tone)
                } else {
                    GeometryReader { geometry in
                        list(snapshot: snapshot, tone: tone, height: geometry.size.height)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Link(destination: AppLink.calendar.url) {
                GeometryReader { geometry in
                    MiniCalendar(snapshot: snapshot, date: entry.date, size: geometry.size, tone: tone)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .zimamWidget(padding: ZimamSpacing.space3)
        .widgetURL(AppLink.today.url)
    }

    /// As many 44pt rows as fit, stretched to share the height (their text and circle grow with
    /// them), and «+n أخرى» when some are left out.
    @ViewBuilder
    private func list(snapshot: WidgetSnapshot, tone: WidgetTone, height: CGFloat) -> some View {
        let upcoming = snapshot.calendarItems.sorted { a, b in
            (a.dueDay ?? "", a.minuteOfDay ?? -1, a.sortOrder) < (b.dueDay ?? "", b.minuteOfDay ?? -1, b.sortOrder)
        }
        let rows = WidgetRows(items: upcoming.count, available: height, minimum: WidgetMetrics.row, moreLine: moreLine)
        let shown = rows.shown
        if upcoming.isEmpty {
            WidgetNote(text: "لا مهام قادمة.", tone: tone)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(upcoming.prefix(shown)) { item in
                    UpcomingRow(item: item, snapshot: snapshot, now: entry.date, tone: tone)
                        .frame(height: rows.height)
                        .widgetTextScale(rows.scale)
                }
                if upcoming.count > shown {
                    Text("+\(snapshot.formatter.number(upcoming.count - shown)) أخرى")
                        .widgetFont(.caption)
                        .foregroundStyle(tone.muted)
                        .frame(height: moreLine)
                        .padding(.leading, ZimamSpacing.space2)
                        .accessibilityLabel("\(ArabicCount.tasks(upcoming.count - shown, locale: snapshot.formatter.locale)) غيرها")
                }
            }
        }
    }
}

/// A task: its completion circle, then its title over when it falls (late in the late color,
/// a prayer in sand). The title opens the task.
private struct UpcomingRow: View {
    let item: WidgetItem
    let snapshot: WidgetSnapshot
    let now: Date
    let tone: WidgetTone

    var body: some View {
        let when = widgetWhenText(item, snapshot: snapshot, now: now)
        let late = widgetIsLate(item, snapshot: snapshot, now: now)
        HStack(spacing: 0) {
            WidgetCompleteButton(item: item, tone: tone)
            Link(destination: AppLink.task(item.id).url) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title)
                        .widgetFont(.callout)
                        .foregroundStyle(tone.ink)
                        .lineLimit(1)
                    if let when {
                        Text(when)
                            .widgetFont(.caption)
                            .foregroundStyle(late ? tone.late : item.prayer != nil ? tone.prayer : tone.muted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityLabel([item.title, when, priorityLabel(item.priority)].compactMap { $0 }.joined(separator: "، "))
        }
        .frame(maxHeight: .infinity)
    }
}

/// This week and the two after it, the grid calendar's day numbers only; today filled, days with
/// tasks in full ink, days gone faint. Above it the current month in both calendars. Scaled to fill
/// the height it is given.
private struct MiniCalendar: View {
    let snapshot: WidgetSnapshot
    let date: Date
    let size: CGSize
    let tone: WidgetTone
    @ScaledMetric(relativeTo: .caption) private var cell = ZimamSpacing.space6
    @ScaledMetric(relativeTo: .body) private var dynamicType: CGFloat = 1

    var body: some View {
        let grid = snapshot.grid()
        let dates = snapshot.formatter
        let weeks = (0..<3).map { grid.weekDays(containing: grid.addingDays(7 * $0, to: date)) }
        let busy = Set(TaskBuckets.byDay(snapshot.calendarItems.compactMap(\.dated), days: weeks.flatMap { $0.map(\.day) }).keys)
        let kind = snapshot.calendar
        // The month and the weekdays over three weeks of cells; the two gaps do not scale.
        let gaps = ZimamSpacing.space1 * 2
        let natural = WidgetFit.textHeight([.caption, .caption], dynamicType: dynamicType) + cell * 3 + gaps
        let scale = WidgetFit.scale(natural: natural, fixed: gaps, available: size.height)
        // A day is a circle no wider than its column.
        let side = min(cell * scale, size.width / 7)
        VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
            Text("\(dates.monthName(date, in: kind))، \(dates.monthName(date, in: kind.other))")
                .widgetFont(.caption)
                .foregroundStyle(tone.muted)
                .lineLimit(1)
            WeekdayHeader(grid: grid, dates: dates, tone: tone)
            VStack(spacing: 0) {
                ForEach(weeks, id: \.self) { week in
                    HStack(spacing: 0) {
                        ForEach(week) { day in
                            dayNumber(day, isBusy: busy.contains(day.day), dates: dates, side: side)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .widgetTextScale(scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("التقويم، \(dates.dual(date))")
    }

    private func dayNumber(_ day: CalendarDay, isBusy: Bool, dates: DualDateFormatter, side: CGFloat) -> some View {
        let isToday = day.day == snapshot.today
        let style: AnyShapeStyle = isToday ? tone.onSolid : day.day < snapshot.today ? tone.faint : isBusy ? tone.ink : tone.muted
        return Text(dates.number(day.primaryDay))
            .widgetFont(.caption)
            .foregroundStyle(style)
            .lineLimit(1)
            .frame(width: side, height: side)
            .background {
                if isToday {
                    if tone.isFullColor {
                        Circle().fill(ZimamColor.ink)
                    } else {
                        Circle().strokeBorder(.primary, lineWidth: ZimamSpacing.space1 / 2)
                    }
                }
            }
            .widgetAccentable(isToday)
    }
}
