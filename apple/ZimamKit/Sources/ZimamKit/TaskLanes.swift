import Foundation

/// A task as the calendar widgets place it: on one day, or across the days from its start to its
/// due date. Days are the API's local Gregorian days ("2026-10-15"), which sort as text.
public struct DatedTask: Hashable, Sendable, Identifiable {
    public let id: UUID
    /// The first day it covers.
    public let startDay: String
    /// Its due day, the last day it covers.
    public let endDay: String
    /// Minutes after midnight on its due day (its time, or its prayer's), for ordering. Nil sorts first.
    public let minuteOfDay: Int?
    public let sortOrder: Double

    /// A start after the due day is ignored: the task then covers its due day only.
    public init(id: UUID, startDay: String? = nil, endDay: String, minuteOfDay: Int? = nil, sortOrder: Double = 0) {
        self.id = id
        let start = startDay ?? endDay
        self.startDay = start <= endDay ? start : endDay
        self.endDay = endDay
        self.minuteOfDay = minuteOfDay
        self.sortOrder = sortOrder
    }

    /// Covers more than one day: drawn as a bar across them.
    public var isSpan: Bool { startDay < endDay }

    public func covers(_ day: String) -> Bool { startDay <= day && day <= endDay }

    /// Untimed tasks first, then by time of day, then by the user's order.
    static func inDayOrder(_ a: DatedTask, _ b: DatedTask) -> Bool {
        (a.minuteOfDay ?? -1, a.sortOrder, a.id.uuidString) < (b.minuteOfDay ?? -1, b.sortOrder, b.id.uuidString)
    }
}

/// Tasks grouped by day, for the lists and dots of the widgets.
public enum TaskBuckets {
    /// The tasks on each of `days` (a task over several days is on each of them), spans first,
    /// then untimed tasks, then by time of day. Days without tasks are left out.
    public static func byDay(_ tasks: [DatedTask], days: [String]) -> [String: [DatedTask]] {
        guard let first = days.min(), let last = days.max() else { return [:] }
        let wanted = Set(days)
        var result: [String: [DatedTask]] = [:]
        for task in tasks where task.startDay <= last && task.endDay >= first {
            for day in days where wanted.contains(day) && task.covers(day) {
                result[day, default: []].append(task)
            }
        }
        return result.mapValues { list in
            list.sorted { a, b in
                if a.isSpan != b.isSpan { return a.isSpan }
                return DatedTask.inDayOrder(a, b)
            }
        }
    }
}

/// One thing drawn in a week row's lanes: a task over one or more columns, or «+n» for a
/// day's tasks that did not fit.
public struct LanePlacement: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        case task(DatedTask)
        /// How many of the column's tasks are not shown.
        case more(Int)
    }

    public let content: Content
    /// 0 is the top lane.
    public let lane: Int
    /// Columns in the week's order, 0 at the leading edge (the right in Arabic).
    public let firstColumn: Int
    public let lastColumn: Int
    /// The task goes on before the first column (an earlier week, or cut for a «+n»).
    public let continuesBefore: Bool
    /// The task goes on after the last column.
    public let continuesAfter: Bool

    public var columnCount: Int { lastColumn - firstColumn + 1 }
}

/// A week row of a calendar widget laid out in lanes, like a wall calendar: tasks over several
/// days are bars across their columns, the other tasks fill each day's free lanes, and a day with
/// more than fits shows «+n» in its last lane. Pure layout, no UI.
public struct WeekLanes: Equatable, Sendable {
    /// The row's days in column order.
    public let days: [String]
    public let laneCount: Int
    public let placements: [LanePlacement]
    /// Each column's tasks that are not shown (the number in its «+n»).
    public let hiddenCounts: [Int]
    /// Each column's tasks, shown or not.
    public let totalCounts: [Int]

    /// Lays out `tasks` over `days` (consecutive days, usually seven) in `lanes` lanes.
    ///
    /// Bars are placed first, earliest and longest first, each in the top lane free across all its
    /// columns; a bar with no free lane is hidden on each of its days. Then each day's other tasks
    /// fill its free lanes in day order. A day with hidden tasks shows «+n» in a free lane, or
    /// otherwise in its last lane, which the task there gives up (a bar is cut around that day).
    public static func layout(days: [String], tasks: [DatedTask], lanes: Int) -> WeekLanes {
        let laneCount = max(0, lanes)
        let columns = days.count
        guard let first = days.first, let last = days.last, columns > 0 else {
            return WeekLanes(days: days, laneCount: laneCount, placements: [], hiddenCounts: [], totalCounts: [])
        }

        let relevant = tasks.filter { $0.startDay <= last && $0.endDay >= first }
        var totals = [Int](repeating: 0, count: columns)
        var hidden = [Int](repeating: 0, count: columns)
        for task in relevant {
            for (column, day) in days.enumerated() where task.covers(day) { totals[column] += 1 }
        }

        // Placed items by index (nil once removed); occupied[lane][column] holds an index.
        var items: [Item?] = []
        var occupied = [[Int?]](repeating: [Int?](repeating: nil, count: columns), count: laneCount)

        func place(_ item: Item) {
            items.append(item)
            for column in item.first...item.last { occupied[item.lane][column] = items.count - 1 }
        }

        // Bars: earliest first column, then longest, then the user's order.
        let bars = relevant.filter(\.isSpan).compactMap { task -> (DatedTask, Int, Int)? in
            guard let a = days.firstIndex(where: task.covers), let b = days.lastIndex(where: task.covers) else { return nil }
            return (task, a, b)
        }.sorted { x, y in
            if x.1 != y.1 { return x.1 < y.1 }
            if x.2 - x.1 != y.2 - y.1 { return x.2 - x.1 > y.2 - y.1 }
            return DatedTask.inDayOrder(x.0, y.0)
        }
        for (task, a, b) in bars {
            if let lane = (0..<laneCount).first(where: { lane in (a...b).allSatisfy { occupied[lane][$0] == nil } }) {
                place(Item(task: task, lane: lane, first: a, last: b,
                           before: task.startDay < days[a], after: task.endDay > days[b]))
            } else {
                for column in a...b { hidden[column] += 1 }
            }
        }

        // One-day tasks, each day in its own order.
        for (column, day) in days.enumerated() {
            let singles = relevant.filter { !$0.isSpan && $0.endDay == day }.sorted(by: DatedTask.inDayOrder)
            for task in singles {
                if let lane = (0..<laneCount).first(where: { occupied[$0][column] == nil }) {
                    place(Item(task: task, lane: lane, first: column, last: column, before: false, after: false))
                } else {
                    hidden[column] += 1
                }
            }
        }

        // «+n» where something is hidden: in a free lane, or in the last lane at the cost of what is there.
        var moreLanes: [Int: Int] = [:]
        if laneCount > 0 {
            for column in 0..<columns where hidden[column] > 0 {
                if let free = (0..<laneCount).first(where: { occupied[$0][column] == nil }) {
                    moreLanes[column] = free
                    continue
                }
                let lane = laneCount - 1
                guard let index = occupied[lane][column], let item = items[index] else { continue }
                items[index] = nil
                for c in item.first...item.last { occupied[lane][c] = nil }
                if item.first < column {
                    place(Item(task: item.task, lane: lane, first: item.first, last: column - 1,
                               before: item.before, after: true))
                }
                if item.last > column {
                    place(Item(task: item.task, lane: lane, first: column + 1, last: item.last,
                               before: true, after: item.after))
                }
                hidden[column] += 1
                moreLanes[column] = lane
            }
        }

        var placements = items.compactMap { $0 }.map { item in
            LanePlacement(content: .task(item.task), lane: item.lane, firstColumn: item.first, lastColumn: item.last,
                          continuesBefore: item.before, continuesAfter: item.after)
        }
        for (column, lane) in moreLanes {
            placements.append(LanePlacement(content: .more(hidden[column]), lane: lane, firstColumn: column,
                                            lastColumn: column, continuesBefore: false, continuesAfter: false))
        }
        placements.sort { ($0.lane, $0.firstColumn) < ($1.lane, $1.firstColumn) }
        return WeekLanes(days: days, laneCount: laneCount, placements: placements, hiddenCounts: hidden, totalCounts: totals)
    }

    /// `days` in rows of seven (a month grid's cells), each laid out on its own.
    public static func layout(weeksOf days: [String], tasks: [DatedTask], lanes: Int) -> [WeekLanes] {
        stride(from: 0, to: days.count, by: 7).map { start in
            layout(days: Array(days[start..<min(start + 7, days.count)]), tasks: tasks, lanes: lanes)
        }
    }

    /// What sits in `lane` from column 0 to the last, in order, with the empty columns between.
    /// Drawn as one row whose first item is at the leading edge.
    public func segments(inLane lane: Int) -> [Segment] {
        let inLane = placements.filter { $0.lane == lane }.sorted { $0.firstColumn < $1.firstColumn }
        var result: [Segment] = []
        var column = 0
        for placement in inLane {
            if placement.firstColumn > column {
                result.append(Segment(placement: nil, firstColumn: column, columnCount: placement.firstColumn - column))
            }
            result.append(Segment(placement: placement, firstColumn: placement.firstColumn, columnCount: placement.columnCount))
            column = placement.lastColumn + 1
        }
        if column < days.count {
            result.append(Segment(placement: nil, firstColumn: column, columnCount: days.count - column))
        }
        return result
    }

    /// A run of columns in a lane: a placement, or empty columns.
    public struct Segment: Hashable, Sendable, Identifiable {
        public let placement: LanePlacement?
        public let firstColumn: Int
        public let columnCount: Int

        public var id: Int { firstColumn }
    }

    private struct Item {
        let task: DatedTask
        let lane: Int
        let first: Int
        let last: Int
        let before: Bool
        let after: Bool
    }
}
