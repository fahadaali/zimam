import XCTest
@testable import ZimamKit

final class DaySpanTests: XCTestCase {
    func testSpanFromTaskFields() {
        XCTAssertNil(DaySpan(startDate: "2026-10-09", dueDate: nil))
        let one = DaySpan(startDate: nil, dueDate: "2026-10-11")
        XCTAssertEqual(one, DaySpan(start: "2026-10-11", end: "2026-10-11"))
        XCTAssertEqual(one?.isMultiDay, false)
        XCTAssertNil(one?.startDate)

        let trip = DaySpan(startDate: "2026-10-09", dueDate: "2026-10-11")
        XCTAssertEqual(trip?.isMultiDay, true)
        XCTAssertEqual(trip?.dayCount, 3)
        XCTAssertEqual(trip?.startDate, "2026-10-09")
        XCTAssertEqual(trip?.dueDate, "2026-10-11")
        XCTAssertEqual(trip?.contains("2026-10-10"), true)
        XCTAssertEqual(trip?.contains("2026-10-12"), false)

        // A start after the due day is ignored rather than trusted.
        XCTAssertEqual(DaySpan(startDate: "2026-10-12", dueDate: "2026-10-11")?.isMultiDay, false)
    }

    func testEditingKeepsStartOnOrBeforeDue() {
        let trip = DaySpan(start: "2026-10-09", end: "2026-10-11")
        XCTAssertEqual(trip.moved(by: 3), DaySpan(start: "2026-10-12", end: "2026-10-14"))
        XCTAssertEqual(trip.moved(by: -10), DaySpan(start: "2026-09-29", end: "2026-10-01"))
        XCTAssertEqual(trip.movingStart(by: -2), DaySpan(start: "2026-10-07", end: "2026-10-11"))
        XCTAssertEqual(trip.movingStart(by: 5), DaySpan(start: "2026-10-11", end: "2026-10-11"))
        XCTAssertEqual(trip.movingEnd(by: 1), DaySpan(start: "2026-10-09", end: "2026-10-12"))
        XCTAssertEqual(trip.movingEnd(by: -5), DaySpan(start: "2026-10-09", end: "2026-10-09"))
        XCTAssertEqual(trip.ending(on: "2026-11-01"), DaySpan(start: "2026-10-30", end: "2026-11-01"))
    }

    func testDayMath() {
        XCTAssertEqual(DayMath.adding(1, to: "2026-12-31"), "2027-01-01")
        XCTAssertEqual(DayMath.adding(-1, to: "2028-03-01"), "2028-02-29")
        XCTAssertEqual(DayMath.days(from: "2026-10-09", to: "2026-10-11"), 2)
        XCTAssertEqual(DayMath.days(from: "2026-10-11", to: "2026-10-09"), -2)
        XCTAssertFalse(DayMath.isDay("2026-02-30"))
        XCTAssertFalse(DayMath.isDay("15/10/2026"))
        XCTAssertEqual(DayMath.weekday(of: "2026-10-15"), 5) // Thursday
        XCTAssertEqual(DayMath.startOfWeek(containing: "2026-10-15", firstWeekday: 1), "2026-10-11")
        XCTAssertEqual(DayMath.startOfWeek(containing: "2026-10-15", firstWeekday: 7), "2026-10-10")
        XCTAssertEqual(DayMath.startOfWeek(containing: "2026-10-11", firstWeekday: 1), "2026-10-11")
    }

    func testWeekLanes() {
        // Sunday 11 to Saturday 17 October 2026.
        let week = (0..<7).compactMap { DayMath.adding($0, to: "2026-10-11") }
        let spans: [(id: Int, span: DaySpan)] = [
            (1, DaySpan(start: "2026-10-09", end: "2026-10-12")), // from last week
            (2, DaySpan(start: "2026-10-13", end: "2026-10-20")), // into next week
            (3, DaySpan(start: "2026-10-12", end: "2026-10-14")),
            (4, DaySpan(start: "2026-10-01", end: "2026-10-05")), // another week
            (5, DaySpan(start: "2026-10-14", end: "2026-10-15")),
        ]
        let layout = SpanLayout.week(spans, days: week, maxLanes: 2)
        let byId = Dictionary(uniqueKeysWithValues: layout.segments.map { ($0.id, $0) })
        XCTAssertNil(byId[4])
        XCTAssertEqual(byId[1].map { [$0.firstColumn, $0.lastColumn, $0.lane] }, [0, 1, 0])
        XCTAssertEqual(byId[1]?.continuesBefore, true)
        XCTAssertEqual(byId[3].map { [$0.firstColumn, $0.lastColumn, $0.lane] }, [1, 3, 1])
        XCTAssertEqual(byId[2].map { [$0.firstColumn, $0.lastColumn, $0.lane] }, [2, 6, 0])
        XCTAssertEqual(byId[2]?.continuesAfter, true)
        XCTAssertEqual(byId[2]?.columnCount, 5)
        // Lanes 0 and 1 are taken on the 14th and 15th: the fifth span is hidden and counted.
        XCTAssertNil(byId[5])
        XCTAssertEqual(layout.hidden, [0, 0, 0, 1, 1, 0, 0])
    }

    func testTimelineRange() {
        let range = TimelineRange.covering([], today: "2026-10-15", firstWeekday: 1)
        XCTAssertEqual(range.first, "2026-10-04") // the Sunday on or before 8 October
        XCTAssertEqual(range.dayCount % 7, 0)
        XCTAssertGreaterThanOrEqual(range.last, "2026-11-19")
        XCTAssertEqual(range.index(of: "2026-10-15"), 11)
        XCTAssertEqual(range.day(at: 11), "2026-10-15")

        let wide = TimelineRange.covering([DaySpan(start: "2026-08-01", end: "2027-01-10")], today: "2026-10-15")
        XCTAssertLessThanOrEqual(wide.first, "2026-07-30")
        XCTAssertGreaterThanOrEqual(wide.last, "2027-01-12")

        let capped = TimelineRange.covering([DaySpan(start: "2020-01-01", end: "2030-01-01")], today: "2026-10-15", maxDays: 70)
        XCTAssertLessThanOrEqual(capped.dayCount, 77)

        XCTAssertEqual(range.columns(of: DaySpan(start: "2026-10-01", end: "2026-10-06"))?.first, 0)
        XCTAssertEqual(range.columns(of: DaySpan(start: "2026-10-01", end: "2026-10-06"))?.count, 3)
        XCTAssertNil(range.columns(of: DaySpan(start: "2026-01-01", end: "2026-01-02")))
    }

    func testDragDirectionFollowsTheLayout() {
        XCTAssertEqual(TimelineDrag.days(translation: 90, dayWidth: 44, rightToLeft: false), 2)
        XCTAssertEqual(TimelineDrag.days(translation: 90, dayWidth: 44, rightToLeft: true), -2)
        XCTAssertEqual(TimelineDrag.days(translation: -20, dayWidth: 44, rightToLeft: true), 0)
        XCTAssertEqual(TimelineDrag.days(translation: 10, dayWidth: 0, rightToLeft: true), 0)
    }
}
