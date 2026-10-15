import Foundation

/// The days a task occupies: from its start day to its due day, both included. A task without a
/// start day occupies its due day alone; a task without a due day has no span.
/// Days are the API's local Gregorian days ("2026-10-15"), which sort as text.
public struct DaySpan: Hashable, Sendable {
    public var start: String
    public var end: String

    public init(start: String, end: String) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    /// The span of a task's fields; a start after the due day (never sent by the server) is ignored.
    public init?(startDate: String?, dueDate: String?) {
        guard let dueDate, DayMath.isDay(dueDate) else { return nil }
        if let startDate, DayMath.isDay(startDate), startDate < dueDate {
            self.init(start: startDate, end: dueDate)
        } else {
            self.init(start: dueDate, end: dueDate)
        }
    }

    /// More than one day: drawn as a bar across days.
    public var isMultiDay: Bool { start < end }

    /// How many days, both ends included.
    public var dayCount: Int { (DayMath.days(from: start, to: end) ?? 0) + 1 }

    /// The fields to store: `startDate` is nil for a one-day span.
    public var startDate: String? { isMultiDay ? start : nil }
    public var dueDate: String { end }

    public func contains(_ day: String) -> Bool { start <= day && day <= end }

    /// Shares at least one day with `first…last`.
    public func overlaps(_ first: String, _ last: String) -> Bool { start <= last && end >= first }

    // MARK: Editing

    /// The whole span `days` later (earlier when negative), keeping its length.
    public func moved(by days: Int) -> DaySpan {
        guard let start = DayMath.adding(days, to: start), let end = DayMath.adding(days, to: end) else { return self }
        return DaySpan(start: start, end: end)
    }

    /// The start `days` later or earlier, never past the due day.
    public func movingStart(by days: Int) -> DaySpan {
        guard let moved = DayMath.adding(days, to: start) else { return self }
        return DaySpan(start: min(moved, end), end: end)
    }

    /// The due day `days` later or earlier, never before the start.
    public func movingEnd(by days: Int) -> DaySpan {
        guard let moved = DayMath.adding(days, to: end) else { return self }
        return DaySpan(start: start, end: max(moved, start))
    }

    /// The span that ends on `day`, keeping its length: a task moved to another day in the calendar.
    public func ending(on day: String) -> DaySpan {
        guard let shift = DayMath.days(from: end, to: day) else { return self }
        return moved(by: shift)
    }
}

/// Arithmetic on API days ("2026-10-15"), with no time zone involved: a day is a date, not an
/// instant, so the Gregorian calendar in UTC counts them exactly.
public enum DayMath {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// "YYYY-MM-DD" with a real month and day.
    public static func isDay(_ text: String) -> Bool {
        date(text) != nil
    }

    /// `day` moved by `days`.
    public static func adding(_ days: Int, to day: String) -> String? {
        guard let date = date(day), let moved = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return string(moved)
    }

    /// Days from `start` to `end`: 0 for the same day, negative when `end` is earlier.
    public static func days(from start: String, to end: String) -> Int? {
        guard let a = date(start), let b = date(end) else { return nil }
        return calendar.dateComponents([.day], from: a, to: b).day
    }

    /// The weekday of a day: 1 = Sunday … 7 = Saturday.
    public static func weekday(of day: String) -> Int? {
        date(day).map { calendar.component(.weekday, from: $0) }
    }

    /// The day on or before `day` that falls on `firstWeekday` (1 = Sunday … 7 = Saturday).
    public static func startOfWeek(containing day: String, firstWeekday: Int) -> String? {
        guard let weekday = weekday(of: day) else { return nil }
        return adding(-((weekday - firstWeekday + 7) % 7), to: day)
    }

    private static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard day.count == 10, parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(dayOfMonth) else { return nil }
        let components = DateComponents(year: year, month: month, day: dayOfMonth)
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    private static func string(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: Bars across a week

/// A multi-day task's piece in one week row of the calendar: the columns it covers and the lane
/// (the line under the dates) it is drawn in.
public struct SpanSegment<ID: Hashable & Sendable>: Hashable, Sendable {
    public let id: ID
    /// Columns in the week, 0 at the leading edge (the right in Arabic).
    public let firstColumn: Int
    public let lastColumn: Int
    public let lane: Int
    /// The task started before this week, or goes on after it: the bar's end is open there.
    public let continuesBefore: Bool
    public let continuesAfter: Bool

    public var columnCount: Int { lastColumn - firstColumn + 1 }

    public init(id: ID, firstColumn: Int, lastColumn: Int, lane: Int, continuesBefore: Bool, continuesAfter: Bool) {
        self.id = id
        self.firstColumn = firstColumn
        self.lastColumn = lastColumn
        self.lane = lane
        self.continuesBefore = continuesBefore
        self.continuesAfter = continuesAfter
    }
}

public enum SpanLayout {
    /// Lays out spans over one week (`days`: the week's API days in column order, consecutive).
    /// Longer spans and earlier ones get the upper lanes; a span takes the first lane free on all
    /// its days. Spans past `maxLanes` are not drawn: `hidden` counts them per column.
    public static func week<ID: Hashable & Sendable>(_ spans: [(id: ID, span: DaySpan)], days: [String],
                                                     maxLanes: Int) -> (segments: [SpanSegment<ID>], hidden: [Int]) {
        var hidden = Array(repeating: 0, count: days.count)
        guard let first = days.first, let last = days.last else { return ([], hidden) }
        let shown = spans
            .filter { $0.span.overlaps(first, last) }
            .sorted { a, b in
                if a.span.start != b.span.start { return a.span.start < b.span.start }
                if a.span.end != b.span.end { return a.span.end > b.span.end }
                return false
            }
        var lanes: [[ClosedRange<Int>]] = []
        var segments: [SpanSegment<ID>] = []
        for item in shown {
            let from = max(item.span.start, first)
            let to = min(item.span.end, last)
            guard let firstColumn = days.firstIndex(of: from), let lastColumn = days.firstIndex(of: to) else { continue }
            let columns = firstColumn...lastColumn
            let lane = lanes.firstIndex { taken in !taken.contains { $0.overlaps(columns) } } ?? lanes.count
            guard lane < maxLanes else {
                for column in columns { hidden[column] += 1 }
                continue
            }
            if lane == lanes.count { lanes.append([]) }
            lanes[lane].append(columns)
            segments.append(SpanSegment(id: item.id, firstColumn: firstColumn, lastColumn: lastColumn, lane: lane,
                                        continuesBefore: item.span.start < first, continuesAfter: item.span.end > last))
        }
        return (segments, hidden)
    }
}

// MARK: The timeline's range

/// The days «المخطط الزمني» shows: from a week before today (or the earliest start) to a month
/// after today (or the latest due day), starting on the week's first day.
public struct TimelineRange: Equatable, Sendable {
    public let first: String
    public let dayCount: Int

    public init(first: String, dayCount: Int) {
        self.first = first
        self.dayCount = max(dayCount, 1)
    }

    /// Covers `spans` and today with some room around them, at most `maxDays` long (centred on
    /// today when the tasks reach further), from the first day of a week.
    public static func covering(_ spans: [DaySpan], today: String, firstWeekday: Int = 1, before: Int = 7,
                                after: Int = 35, maxDays: Int = 371) -> TimelineRange {
        var start = DayMath.adding(-before, to: today) ?? today
        var end = DayMath.adding(after, to: today) ?? today
        for span in spans {
            start = min(start, DayMath.adding(-2, to: span.start) ?? span.start)
            end = max(end, DayMath.adding(2, to: span.end) ?? span.end)
        }
        let half = maxDays / 2
        if let earliest = DayMath.adding(-half, to: today), start < earliest { start = earliest }
        if let latest = DayMath.adding(maxDays - half, to: today), end > latest { end = latest }
        start = DayMath.startOfWeek(containing: start, firstWeekday: firstWeekday) ?? start
        let count = (DayMath.days(from: start, to: end) ?? 0) + 1
        // Whole weeks, so the week zoom ends on a full column.
        return TimelineRange(first: start, dayCount: (count + 6) / 7 * 7)
    }

    public var last: String { day(at: dayCount - 1) }

    /// The day in column `index`, 0 being `first`.
    public func day(at index: Int) -> String {
        DayMath.adding(index, to: first) ?? first
    }

    /// The column of `day`; outside the range it is below 0 or at least `dayCount`.
    public func index(of day: String) -> Int? {
        DayMath.days(from: first, to: day)
    }

    /// Where a span is drawn, clamped to the range: its first column and how many columns.
    /// Nil when it is wholly outside.
    public func columns(of span: DaySpan) -> (first: Int, count: Int)? {
        guard let a = index(of: span.start), let b = index(of: span.end), b >= 0, a < dayCount else { return nil }
        let from = max(a, 0)
        let to = min(b, dayCount - 1)
        return (from, to - from + 1)
    }
}

/// Days a drag moved a bar by. `translation` is the finger's movement on screen (positive to the
/// right); time runs right to left in Arabic, so there a move to the right is earlier.
public enum TimelineDrag {
    public static func days(translation: Double, dayWidth: Double, rightToLeft: Bool) -> Int {
        guard dayWidth > 0 else { return 0 }
        let days = Int((translation / dayWidth).rounded())
        return rightToLeft ? -days : days
    }
}
