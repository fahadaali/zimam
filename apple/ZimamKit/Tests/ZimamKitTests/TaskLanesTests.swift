import XCTest
@testable import ZimamKit

final class TaskLanesTests: XCTestCase {
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

    func testDatedTaskSpans() {
        XCTAssertFalse(task(1, "2026-10-13").isSpan)
        XCTAssertTrue(task(1, "2026-10-15", from: "2026-10-13").isSpan)
        // A start after the due day is ignored.
        let backwards = task(1, "2026-10-13", from: "2026-10-20")
        XCTAssertEqual(backwards.startDay, "2026-10-13")
        XCTAssertFalse(backwards.isSpan)
        XCTAssertTrue(task(1, "2026-10-15", from: "2026-10-13").covers("2026-10-14"))
        XCTAssertFalse(task(1, "2026-10-15", from: "2026-10-13").covers("2026-10-16"))
    }

    func testBucketsByDayOrderSpansThenUntimedThenTime() {
        let late = task(1, "2026-10-13", minute: 18 * 60)
        let untimed = task(2, "2026-10-13", order: 5)
        let early = task(3, "2026-10-13", minute: 6 * 60)
        let trip = task(4, "2026-10-14", from: "2026-10-12")
        let outside = task(5, "2026-10-20")
        let byDay = TaskBuckets.byDay([late, untimed, early, trip, outside], days: week)
        XCTAssertEqual(byDay["2026-10-13"]?.map(\.id), [trip.id, untimed.id, early.id, late.id])
        XCTAssertEqual(byDay["2026-10-12"]?.map(\.id), [trip.id])
        XCTAssertEqual(byDay["2026-10-14"]?.map(\.id), [trip.id])
        XCTAssertNil(byDay["2026-10-15"])
        XCTAssertNil(byDay["2026-10-20"])
    }

    // MARK: Lanes

    func testSingleDayTasksFillLanes() {
        let a = task(1, "2026-10-13", minute: 600)
        let b = task(2, "2026-10-13", minute: 540)
        let layout = WeekLanes.layout(days: week, tasks: [a, b], lanes: 2)
        XCTAssertEqual(layout.placements.count, 2)
        XCTAssertEqual(layout.placements.map(taskId), [b.id, a.id])
        XCTAssertEqual(layout.placements.map(\.lane), [0, 1])
        XCTAssertTrue(layout.placements.allSatisfy { $0.firstColumn == 2 && $0.lastColumn == 2 })
        XCTAssertEqual(layout.hiddenCounts, [0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(layout.totalCounts, [0, 0, 2, 0, 0, 0, 0])
    }

    func testSpanIsOneBarAcrossItsDays() {
        let trip = task(1, "2026-10-17", from: "2026-10-15")
        let meeting = task(2, "2026-10-16", minute: 600)
        let layout = WeekLanes.layout(days: week, tasks: [meeting, trip], lanes: 2)
        let bar = layout.placements.first { taskId($0) == trip.id }
        XCTAssertEqual(bar?.lane, 0)
        XCTAssertEqual(bar?.firstColumn, 4)
        XCTAssertEqual(bar?.lastColumn, 6)
        XCTAssertEqual(bar?.columnCount, 3)
        XCTAssertEqual(bar?.continuesBefore, false)
        XCTAssertEqual(bar?.continuesAfter, false)
        // The one-day task goes under the bar.
        let single = layout.placements.first { taskId($0) == meeting.id }
        XCTAssertEqual(single?.lane, 1)
        XCTAssertEqual(single?.firstColumn, 5)
    }

    func testSpanCutByTheWeekContinues() {
        let trip = task(1, "2026-10-20", from: "2026-10-08")
        let layout = WeekLanes.layout(days: week, tasks: [trip], lanes: 1)
        XCTAssertEqual(layout.placements.count, 1)
        XCTAssertEqual(layout.placements[0].firstColumn, 0)
        XCTAssertEqual(layout.placements[0].lastColumn, 6)
        XCTAssertTrue(layout.placements[0].continuesBefore)
        XCTAssertTrue(layout.placements[0].continuesAfter)
    }

    func testLongerSpanTakesTheTopLane() {
        let short = task(1, "2026-10-13", from: "2026-10-12")
        let long = task(2, "2026-10-15", from: "2026-10-12")
        let layout = WeekLanes.layout(days: week, tasks: [short, long], lanes: 3)
        XCTAssertEqual(layout.placements.first { taskId($0) == long.id }?.lane, 0)
        XCTAssertEqual(layout.placements.first { taskId($0) == short.id }?.lane, 1)
    }

    func testOverflowShowsMoreInTheLastLane() {
        let tasks = (1...5).map { task($0, "2026-10-14", minute: $0 * 60) }
        let layout = WeekLanes.layout(days: week, tasks: tasks, lanes: 2)
        // One task, then «+4» in the last lane.
        XCTAssertEqual(layout.placements.count, 2)
        XCTAssertEqual(taskId(layout.placements[0]), tasks[0].id)
        XCTAssertEqual(layout.placements[0].lane, 0)
        XCTAssertEqual(more(layout.placements[1]), 4)
        XCTAssertEqual(layout.placements[1].lane, 1)
        XCTAssertEqual(layout.placements[1].firstColumn, 3)
        XCTAssertEqual(layout.hiddenCounts[3], 4)
        XCTAssertEqual(layout.totalCounts[3], 5)
    }

    func testExactFitHasNoMore() {
        let tasks = (1...2).map { task($0, "2026-10-14") }
        let layout = WeekLanes.layout(days: week, tasks: tasks, lanes: 2)
        XCTAssertEqual(layout.placements.compactMap(more), [])
        XCTAssertEqual(layout.hiddenCounts[3], 0)
    }

    func testMoreCutsABarAroundItsDay() {
        // A bar in the only lane from Monday to Thursday, and two more tasks on Tuesday.
        let trip = task(1, "2026-10-15", from: "2026-10-12")
        let call = task(2, "2026-10-13")
        let lanes = WeekLanes.layout(days: week, tasks: [trip, call], lanes: 1)
        let parts = lanes.placements.filter { taskId($0) == trip.id }.sorted { $0.firstColumn < $1.firstColumn }
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].firstColumn, 1)
        XCTAssertEqual(parts[0].lastColumn, 1)
        XCTAssertTrue(parts[0].continuesAfter)
        XCTAssertEqual(parts[1].firstColumn, 3)
        XCTAssertEqual(parts[1].lastColumn, 4)
        XCTAssertTrue(parts[1].continuesBefore)
        let moreOnTuesday = lanes.placements.first { more($0) != nil }
        XCTAssertEqual(moreOnTuesday?.firstColumn, 2)
        XCTAssertEqual(more(moreOnTuesday!), 2)
    }

    func testBarWithoutALaneIsHiddenOnEachDay() {
        let a = task(1, "2026-10-14", from: "2026-10-12")
        let b = task(2, "2026-10-14", from: "2026-10-12")
        let layout = WeekLanes.layout(days: week, tasks: [a, b], lanes: 1)
        // The second bar has no lane, so each of its days shows «+n» where the first bar was.
        XCTAssertEqual(layout.hiddenCounts, [0, 2, 2, 2, 0, 0, 0])
        XCTAssertEqual(layout.placements.compactMap(more), [2, 2, 2])
    }

    func testNoLanesHidesEverything() {
        let layout = WeekLanes.layout(days: week, tasks: [task(1, "2026-10-13")], lanes: 0)
        XCTAssertTrue(layout.placements.isEmpty)
        XCTAssertEqual(layout.hiddenCounts[2], 1)
    }

    func testSegmentsCoverTheRow() {
        let trip = task(1, "2026-10-15", from: "2026-10-13")
        let layout = WeekLanes.layout(days: week, tasks: [trip], lanes: 1)
        let segments = layout.segments(inLane: 0)
        XCTAssertEqual(segments.map(\.firstColumn), [0, 2, 5])
        XCTAssertEqual(segments.map(\.columnCount), [2, 3, 2])
        XCTAssertEqual(segments.map { $0.placement != nil }, [false, true, false])
        XCTAssertEqual(layout.segments(inLane: 0).map(\.columnCount).reduce(0, +), 7)
    }

    func testMonthInWeeks() {
        let days = (1...14).map { String(format: "2026-10-%02d", $0) }
        let weeks = WeekLanes.layout(weeksOf: days, tasks: [task(1, "2026-10-09")], lanes: 2)
        XCTAssertEqual(weeks.count, 2)
        XCTAssertEqual(weeks[0].days.first, "2026-10-01")
        XCTAssertEqual(weeks[1].days.first, "2026-10-08")
        XCTAssertTrue(weeks[0].placements.isEmpty)
        XCTAssertEqual(weeks[1].placements.first?.firstColumn, 1)
    }
}
