import Foundation
import Testing
@testable import ZimamKit

struct TaskLanesTests {
    /// Sunday 11 to Saturday 17 October 2026.
    let week = ["2026-10-11", "2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17"]

    private func task(_ n: Int, _ end: String, from start: String? = nil, minute: Int? = nil, order: Double = 0) -> DatedTask {
        DatedTask(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
                  startDay: start, endDay: end, minuteOfDay: minute, sortOrder: order)
    }

    private func taskId(_ placement: LanePlacement) -> UUID? {
        if case .task(let task) = placement.content { return task.id }
        return nil
    }

    private func more(_ placement: LanePlacement) -> Int? {
        if case .more(let count) = placement.content { return count }
        return nil
    }

    // MARK: Tasks

    @Test func datedTaskSpans() {
        #expect(!task(1, "2026-10-13").isSpan)
        #expect(task(1, "2026-10-15", from: "2026-10-13").isSpan)
        // A start after the due day is ignored.
        let backwards = task(1, "2026-10-13", from: "2026-10-20")
        #expect(backwards.startDay == "2026-10-13")
        #expect(!backwards.isSpan)
        #expect(task(1, "2026-10-15", from: "2026-10-13").covers("2026-10-14"))
        #expect(!task(1, "2026-10-15", from: "2026-10-13").covers("2026-10-16"))
    }

    @Test func bucketsByDayOrderSpansThenUntimedThenTime() {
        let late = task(1, "2026-10-13", minute: 18 * 60)
        let untimed = task(2, "2026-10-13", order: 5)
        let early = task(3, "2026-10-13", minute: 6 * 60)
        let trip = task(4, "2026-10-14", from: "2026-10-12")
        let outside = task(5, "2026-10-20")
        let byDay = TaskBuckets.byDay([late, untimed, early, trip, outside], days: week)
        #expect(byDay["2026-10-13"]?.map(\.id) == [trip.id, untimed.id, early.id, late.id])
        #expect(byDay["2026-10-12"]?.map(\.id) == [trip.id])
        #expect(byDay["2026-10-14"]?.map(\.id) == [trip.id])
        #expect(byDay["2026-10-15"] == nil)
        #expect(byDay["2026-10-20"] == nil)
    }

    // MARK: Lanes

    @Test func singleDayTasksFillLanes() {
        let a = task(1, "2026-10-13", minute: 600)
        let b = task(2, "2026-10-13", minute: 540)
        let layout = WeekLanes.layout(days: week, tasks: [a, b], lanes: 2)
        #expect(layout.placements.count == 2)
        #expect(layout.placements.map(taskId) == [b.id, a.id])
        #expect(layout.placements.map(\.lane) == [0, 1])
        #expect(layout.placements.allSatisfy { $0.firstColumn == 2 && $0.lastColumn == 2 })
        #expect(layout.hiddenCounts == [0, 0, 0, 0, 0, 0, 0])
        #expect(layout.totalCounts == [0, 0, 2, 0, 0, 0, 0])
    }

    @Test func spanIsOneBarAcrossItsDays() {
        let trip = task(1, "2026-10-17", from: "2026-10-15")
        let meeting = task(2, "2026-10-16", minute: 600)
        let layout = WeekLanes.layout(days: week, tasks: [meeting, trip], lanes: 2)
        let bar = layout.placements.first { taskId($0) == trip.id }
        #expect(bar?.lane == 0)
        #expect(bar?.firstColumn == 4)
        #expect(bar?.lastColumn == 6)
        #expect(bar?.columnCount == 3)
        #expect(bar?.continuesBefore == false)
        #expect(bar?.continuesAfter == false)
        // The one-day task goes under the bar.
        let single = layout.placements.first { taskId($0) == meeting.id }
        #expect(single?.lane == 1)
        #expect(single?.firstColumn == 5)
    }

    @Test func spanCutByTheWeekContinues() {
        let trip = task(1, "2026-10-20", from: "2026-10-08")
        let layout = WeekLanes.layout(days: week, tasks: [trip], lanes: 1)
        #expect(layout.placements.count == 1)
        #expect(layout.placements[0].firstColumn == 0)
        #expect(layout.placements[0].lastColumn == 6)
        #expect(layout.placements[0].continuesBefore)
        #expect(layout.placements[0].continuesAfter)
    }

    @Test func longerSpanTakesTheTopLane() {
        let short = task(1, "2026-10-13", from: "2026-10-12")
        let long = task(2, "2026-10-15", from: "2026-10-12")
        let layout = WeekLanes.layout(days: week, tasks: [short, long], lanes: 3)
        #expect((layout.placements.first { taskId($0) == long.id }?.lane) == 0)
        #expect((layout.placements.first { taskId($0) == short.id }?.lane) == 1)
    }

    @Test func overflowShowsMoreInTheLastLane() {
        let tasks = (1...5).map { task($0, "2026-10-14", minute: $0 * 60) }
        let layout = WeekLanes.layout(days: week, tasks: tasks, lanes: 2)
        // One task, then «+4» in the last lane.
        #expect(layout.placements.count == 2)
        #expect(taskId(layout.placements[0]) == tasks[0].id)
        #expect(layout.placements[0].lane == 0)
        #expect(more(layout.placements[1]) == 4)
        #expect(layout.placements[1].lane == 1)
        #expect(layout.placements[1].firstColumn == 3)
        #expect(layout.hiddenCounts[3] == 4)
        #expect(layout.totalCounts[3] == 5)
    }

    @Test func exactFitHasNoMore() {
        let tasks = (1...2).map { task($0, "2026-10-14") }
        let layout = WeekLanes.layout(days: week, tasks: tasks, lanes: 2)
        #expect(layout.placements.compactMap(more) == [])
        #expect(layout.hiddenCounts[3] == 0)
    }

    @Test func moreCutsABarAroundItsDay() {
        // A bar in the only lane from Monday to Thursday, and two more tasks on Tuesday.
        let trip = task(1, "2026-10-15", from: "2026-10-12")
        let call = task(2, "2026-10-13")
        let lanes = WeekLanes.layout(days: week, tasks: [trip, call], lanes: 1)
        let parts = lanes.placements.filter { taskId($0) == trip.id }.sorted { $0.firstColumn < $1.firstColumn }
        #expect(parts.count == 2)
        #expect(parts[0].firstColumn == 1)
        #expect(parts[0].lastColumn == 1)
        #expect(parts[0].continuesAfter)
        #expect(parts[1].firstColumn == 3)
        #expect(parts[1].lastColumn == 4)
        #expect(parts[1].continuesBefore)
        let moreOnTuesday = lanes.placements.first { more($0) != nil }
        #expect(moreOnTuesday?.firstColumn == 2)
        #expect(more(moreOnTuesday!) == 2)
    }

    @Test func barWithoutALaneIsHiddenOnEachDay() {
        let a = task(1, "2026-10-14", from: "2026-10-12")
        let b = task(2, "2026-10-14", from: "2026-10-12")
        let layout = WeekLanes.layout(days: week, tasks: [a, b], lanes: 1)
        // The second bar has no lane, so each of its days shows «+n» where the first bar was.
        #expect(layout.hiddenCounts == [0, 2, 2, 2, 0, 0, 0])
        #expect(layout.placements.compactMap(more) == [2, 2, 2])
    }

    @Test func noLanesHidesEverything() {
        let layout = WeekLanes.layout(days: week, tasks: [task(1, "2026-10-13")], lanes: 0)
        #expect(layout.placements.isEmpty)
        #expect(layout.hiddenCounts[2] == 1)
    }

    @Test func segmentsCoverTheRow() {
        let trip = task(1, "2026-10-15", from: "2026-10-13")
        let layout = WeekLanes.layout(days: week, tasks: [trip], lanes: 1)
        let segments = layout.segments(inLane: 0)
        #expect(segments.map(\.firstColumn) == [0, 2, 5])
        #expect(segments.map(\.columnCount) == [2, 3, 2])
        #expect((segments.map { $0.placement != nil }) == [false, true, false])
        #expect(layout.segments(inLane: 0).map(\.columnCount).reduce(0, +) == 7)
    }

    @Test func monthInWeeks() {
        let days = (1...14).map { String(format: "2026-10-%02d", $0) }
        let weeks = WeekLanes.layout(weeksOf: days, tasks: [task(1, "2026-10-09")], lanes: 2)
        #expect(weeks.count == 2)
        #expect(weeks[0].days.first == "2026-10-01")
        #expect(weeks[1].days.first == "2026-10-08")
        #expect(weeks[0].placements.isEmpty)
        #expect(weeks[1].placements.first?.firstColumn == 1)
    }
}
