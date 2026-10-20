import SwiftUI
import ZimamKit

// MARK: Axis

/// The header pinned over the rows: the months of the user's primary calendar, then the other
/// calendar's, then the days (or the weeks), each day with both its numbers.
struct GanttAxis: View {
    static let todayID = "gantt-today"

    let range: TimelineRange
    let zoom: GanttView.Zoom
    let dayWidth: CGFloat
    let kind: CalendarKind
    let today: String
    let todayIndex: Int?

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        let days = axisDays
        let dates = days.map(\.date)
        // Once for the axis, not per row or per day.
        let primary = calendar(kind)
        let other = calendar(kind.other)
        VStack(alignment: .leading, spacing: 0) {
            GanttMonthRow(segments: segments(days, in: kind), dayWidth: dayWidth, primary: true)
            GanttMonthRow(segments: segments(days, in: kind.other), dayWidth: dayWidth, primary: false)
            if zoom == .days {
                GanttDayRow(days: days, primary: primary, other: other, dayWidth: dayWidth, todayIndex: todayIndex)
            } else {
                GanttWeekRow(days: days, primary: primary, other: other, dayWidth: dayWidth, todayIndex: todayIndex)
            }
        }
        .padding(.vertical, ZimamSpacing.space1)
        .frame(width: dayWidth * CGFloat(range.dayCount), alignment: .leading)
        // Behind the numbers and the month names, so «٩» and «جمادى الأولى» stay readable over it.
        .background(alignment: .leading) {
            if let todayIndex {
                GanttTodayLine()
                    .id(Self.todayID)
                    .padding(.leading, CGFloat(todayIndex) * dayWidth + dayWidth / 2 - ZimamLayout.focusRingWidth / 2)
            }
        }
        .background(ZimamColor.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ZimamColor.line).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(dates))
    }

    /// Every column's day, with its midday for the calendars.
    private var axisDays: [GanttAxisDay] {
        (0 ..< range.dayCount).map { index in
            let day = range.day(at: index)
            return GanttAxisDay(index: index, day: day, date: noon(of: day))
        }
    }

    /// Consecutive days of the same month in `kind`, with «جمادى الأولى ١٤٤٨هـ».
    private func segments(_ days: [GanttAxisDay], in kind: CalendarKind) -> [GanttMonthSegment] {
        let calendar = self.calendar(kind)
        let names = DateFormatter()
        names.calendar = calendar
        names.locale = formatter.locale
        names.timeZone = formatter.timeZone
        names.dateFormat = "MMMM y"
        var result: [GanttMonthSegment] = []
        var key: DateComponents?
        for day in days {
            let month = calendar.dateComponents([.year, .month], from: day.date)
            if month == key, let last = result.popLast() {
                result.append(GanttMonthSegment(id: last.id, count: last.count + 1, title: last.title))
            } else {
                key = month
                result.append(GanttMonthSegment(id: day.id, count: 1, title: names.string(from: day.date) + kind.yearSuffix))
            }
        }
        return result
    }

    private func calendar(_ kind: CalendarKind) -> Calendar {
        var calendar = Calendar(identifier: kind.identifier)
        calendar.timeZone = formatter.timeZone
        return calendar
    }

    /// Midday of an API day, away from either edge of it.
    private func noon(of day: String) -> Date {
        (formatter.date(fromDay: day) ?? Date()).addingTimeInterval(12 * 3600)
    }

    private func accessibilityText(_ dates: [Date]) -> String {
        guard let first = dates.first, let last = dates.last else { return "" }
        return "المخطط من \(formatter.withKind(kind).rangeTitle(from: first, to: last, in: kind))"
    }
}

/// A column of the axis: its day, its place and its midday. Identified by its day, so a column
/// keeps its identity when the range grows or shifts.
struct GanttAxisDay: Identifiable {
    let index: Int
    let day: String
    let date: Date

    var id: String { day }
}

/// Consecutive days of the same month, identified by the first of them.
struct GanttMonthSegment: Identifiable {
    let id: String
    let count: Int
    let title: String
}

/// A row of month names in one calendar, each as wide as its days.
struct GanttMonthRow: View {
    let segments: [GanttMonthSegment]
    let dayWidth: CGFloat
    let primary: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments) { segment in
                HStack(spacing: 0) {
                    ForEach(Array(Self.chunks(of: segment.count, dayWidth: dayWidth).enumerated()), id: \.offset) { _, days in
                        Text(segment.title)
                            .font(ZimamType.caption)
                            .foregroundStyle(primary ? ZimamColor.ink : ZimamColor.inkMuted)
                            .lineLimit(1)
                            .padding(.horizontal, ZimamSpacing.space1)
                            .frame(width: CGFloat(days) * dayWidth, alignment: .leading)
                            .clipped()
                    }
                }
                // The month's start, once, however often its name is repeated.
                .overlay(alignment: .leading) {
                    Rectangle().fill(ZimamColor.line).frame(width: 1)
                }
            }
        }
    }

    /// In days, a month's name is written again every week, so one is always in view after
    /// scrolling to today (the month's first day is often off screen). A short last stretch joins
    /// the week before it, so a name is never cut to a letter or two. In weeks the month is
    /// narrow enough to show whole: one name.
    static func chunks(of count: Int, dayWidth: CGFloat) -> [Int] {
        let week = 7
        guard dayWidth >= ZimamSpacing.space11, count > week else { return [count] }
        var result = Array(repeating: week, count: count / week)
        let rest = count % week
        if rest == 0 {
            return result
        } else if rest < 4 {
            result[result.count - 1] += rest
        } else {
            result.append(rest)
        }
        return result
    }
}

/// The days, each with its weekday and both its numbers.
struct GanttDayRow: View {
    let days: [GanttAxisDay]
    let primary: Calendar
    let other: Calendar
    let dayWidth: CGFloat
    let todayIndex: Int?

    @Environment(\.dateFormatterZimam) private var formatter

    var body: some View {
        let weekdays = Calendar(identifier: .gregorian)
        // Once for the row, not per day: each call builds a calendar and its symbols.
        let symbols = formatter.weekdaySymbols(Array(1...7), short: true)
        return HStack(spacing: 0) {
            ForEach(days) { day in
                let date = day.date
                let isToday = day.index == todayIndex
                VStack(spacing: 0) {
                    Text(symbols[weekdays.component(.weekday, from: date) - 1])
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                    Text(formatter.number(primary.component(.day, from: date)))
                        .font(ZimamType.headline)
                        .foregroundStyle(isToday ? ZimamColor.timelineToday : ZimamColor.ink)
                    Text(formatter.number(other.component(.day, from: date)))
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
                .frame(width: dayWidth)
            }
        }
        .padding(.top, ZimamSpacing.space1)
    }
}

/// A column a week wide: its first day in both calendars.
struct GanttWeekRow: View {
    let days: [GanttAxisDay]
    let primary: Calendar
    let other: Calendar
    let dayWidth: CGFloat
    let todayIndex: Int?

    @Environment(\.dateFormatterZimam) private var formatter

    /// The first day of every week.
    private var weeks: [GanttAxisDay] {
        stride(from: 0, to: days.count, by: 7).map { days[$0] }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(weeks) { week in
                let start = week.index
                let date = week.date
                let hasToday = todayIndex.map { (start ..< start + 7).contains($0) } ?? false
                VStack(alignment: .leading, spacing: 0) {
                    Text(formatter.number(primary.component(.day, from: date)))
                        .font(ZimamType.headline)
                        .foregroundStyle(hasToday ? ZimamColor.timelineToday : ZimamColor.ink)
                    Text(formatter.number(other.component(.day, from: date)))
                        .font(ZimamType.caption)
                        .foregroundStyle(ZimamColor.inkMuted)
                }
                .padding(.horizontal, ZimamSpacing.space1)
                .frame(width: dayWidth * 7, alignment: .leading)
                .overlay(alignment: .leading) {
                    Rectangle().fill(ZimamColor.line).frame(width: 1)
                }
            }
        }
        .padding(.top, ZimamSpacing.space1)
    }
}
