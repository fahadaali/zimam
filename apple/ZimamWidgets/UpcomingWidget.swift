import SwiftUI
import WidgetKit
import ZimamKit

/// «القادم مع التقويم»: the next open tasks (overdue first, then by day and time) with their time
/// or prayer and a completion circle, beside three weeks of the calendar from this week.
struct UpcomingWidget: Widget {
    static let kind = "app.zimam.upcoming"

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
        completion(Timeline(entries: entries, policy: .after(snapshot.nextMidnight)))
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
                        .accessibilityAddTraits(.isHeader)
                }
                .font(ZimamType.headline)
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
                MiniCalendar(snapshot: snapshot, date: entry.date, tone: tone)
            }
            .frame(maxWidth: .infinity)
        }
        .zimamWidget(padding: ZimamSpacing.space3)
        .widgetURL(AppLink.today.url)
    }

    /// As many 44pt rows as fit, and «+n أخرى» when some are left out.
    @ViewBuilder
    private func list(snapshot: WidgetSnapshot, tone: WidgetTone, height: CGFloat) -> some View {
        let upcoming = snapshot.calendarItems.sorted { a, b in
            (a.dueDay ?? "", a.minuteOfDay ?? -1, a.sortOrder) < (b.dueDay ?? "", b.minuteOfDay ?? -1, b.sortOrder)
        }
        let fitting = max(0, Int(height / WidgetMetrics.row))
        let shown = upcoming.count > fitting ? max(0, Int((height - moreLine) / WidgetMetrics.row)) : upcoming.count
        if upcoming.isEmpty {
            WidgetNote(text: "لا مهام قادمة.", tone: tone)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(upcoming.prefix(shown)) { item in
                    UpcomingRow(item: item, snapshot: snapshot, now: entry.date, tone: tone)
                }
                if upcoming.count > shown {
                    Text("+\(snapshot.formatter.number(upcoming.count - shown)) أخرى")
                        .font(ZimamType.caption)
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
                        .font(ZimamType.callout)
                        .foregroundStyle(tone.ink)
                        .lineLimit(1)
                    if let when {
                        Text(when)
                            .font(ZimamType.caption)
                            .foregroundStyle(late ? tone.late : item.prayer != nil ? tone.prayer : tone.muted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityLabel([item.title, when, priorityLabel(item.priority)].compactMap { $0 }.joined(separator: "، "))
        }
        .frame(height: WidgetMetrics.row)
    }
}

/// This week and the two after it, the grid calendar's day numbers only; today filled, days with
/// tasks in full ink, days gone faint. Above it the current month in both calendars.
private struct MiniCalendar: View {
    let snapshot: WidgetSnapshot
    let date: Date
    let tone: WidgetTone
    @ScaledMetric(relativeTo: .caption) private var cell = ZimamSpacing.space6

    var body: some View {
        let grid = snapshot.grid()
        let dates = snapshot.formatter
        let weeks = (0..<3).map { grid.weekDays(containing: grid.addingDays(7 * $0, to: date)) }
        let busy = Set(TaskBuckets.byDay(snapshot.calendarItems.compactMap(\.dated), days: weeks.flatMap { $0.map(\.day) }).keys)
        let kind = snapshot.calendar
        VStack(alignment: .leading, spacing: ZimamSpacing.space1) {
            Text("\(dates.monthName(date, in: kind))، \(dates.monthName(date, in: kind.other))")
                .font(ZimamType.caption)
                .foregroundStyle(tone.muted)
                .lineLimit(1)
            WeekdayHeader(grid: grid, dates: dates, tone: tone)
            VStack(spacing: 0) {
                ForEach(weeks.indices, id: \.self) { index in
                    HStack(spacing: 0) {
                        ForEach(weeks[index]) { day in
                            dayNumber(day, isBusy: busy.contains(day.day), dates: dates)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("التقويم، \(dates.dual(date))")
    }

    private func dayNumber(_ day: CalendarDay, isBusy: Bool, dates: DualDateFormatter) -> some View {
        let isToday = day.day == snapshot.today
        let style: AnyShapeStyle = isToday ? tone.onSolid : day.day < snapshot.today ? tone.faint : isBusy ? tone.ink : tone.muted
        return Text(dates.number(day.primaryDay))
            .font(ZimamType.caption)
            .foregroundStyle(style)
            .lineLimit(1)
            .frame(width: cell, height: cell)
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
