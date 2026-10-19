import Foundation
import Testing
@testable import ZimamKit

struct DaySpanTests {
    @Test func spanFromTaskFields() {
        #expect(DaySpan(startDate: "2026-10-09", dueDate: nil) == nil)
        let one = DaySpan(startDate: nil, dueDate: "2026-10-11")
        #expect(one == DaySpan(start: "2026-10-11", end: "2026-10-11"))
        #expect(one?.isMultiDay == false)
        #expect(one?.startDate == nil)

        let trip = DaySpan(startDate: "2026-10-09", dueDate: "2026-10-11")
        #expect(trip?.isMultiDay == true)
        #expect(trip?.dayCount == 3)
        #expect(trip?.startDate == "2026-10-09")
        #expect(trip?.dueDate == "2026-10-11")
        #expect(trip?.contains("2026-10-10") == true)
        #expect(trip?.contains("2026-10-12") == false)

        // A start after the due day is ignored rather than trusted.
        #expect(DaySpan(startDate: "2026-10-12", dueDate: "2026-10-11")?.isMultiDay == false)
    }

    @Test func editingKeepsStartOnOrBeforeDue() {
        let trip = DaySpan(start: "2026-10-09", end: "2026-10-11")
        #expect(trip.moved(by: 3) == DaySpan(start: "2026-10-12", end: "2026-10-14"))
        #expect(trip.moved(by: -10) == DaySpan(start: "2026-09-29", end: "2026-10-01"))
        #expect(trip.movingStart(by: -2) == DaySpan(start: "2026-10-07", end: "2026-10-11"))
        #expect(trip.movingStart(by: 5) == DaySpan(start: "2026-10-11", end: "2026-10-11"))
        #expect(trip.movingEnd(by: 1) == DaySpan(start: "2026-10-09", end: "2026-10-12"))
        #expect(trip.movingEnd(by: -5) == DaySpan(start: "2026-10-09", end: "2026-10-09"))
        #expect(trip.ending(on: "2026-11-01") == DaySpan(start: "2026-10-30", end: "2026-11-01"))
    }

    @Test func dayMath() {
        #expect(DayMath.adding(1, to: "2026-12-31") == "2027-01-01")
        #expect(DayMath.adding(-1, to: "2028-03-01") == "2028-02-29")
        #expect(DayMath.days(from: "2026-10-09", to: "2026-10-11") == 2)
        #expect(DayMath.days(from: "2026-10-11", to: "2026-10-09") == -2)
        #expect(!DayMath.isDay("2026-02-30"))
        #expect(!DayMath.isDay("15/10/2026"))
        #expect(DayMath.weekday(of: "2026-10-15") == 5) // Thursday
        #expect(DayMath.startOfWeek(containing: "2026-10-15", firstWeekday: 1) == "2026-10-11")
        #expect(DayMath.startOfWeek(containing: "2026-10-15", firstWeekday: 7) == "2026-10-10")
        #expect(DayMath.startOfWeek(containing: "2026-10-11", firstWeekday: 1) == "2026-10-11")
    }

    @Test func weekLanes() {
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
        #expect(byId[4] == nil)
        #expect((byId[1].map { [$0.firstColumn, $0.lastColumn, $0.lane] }) == [0, 1, 0])
        #expect(byId[1]?.continuesBefore == true)
        #expect((byId[3].map { [$0.firstColumn, $0.lastColumn, $0.lane] }) == [1, 3, 1])
        #expect((byId[2].map { [$0.firstColumn, $0.lastColumn, $0.lane] }) == [2, 6, 0])
        #expect(byId[2]?.continuesAfter == true)
        #expect(byId[2]?.columnCount == 5)
        // Lanes 0 and 1 are taken on the 14th and 15th: the fifth span is hidden and counted.
        #expect(byId[5] == nil)
        #expect(layout.hidden == [0, 0, 0, 1, 1, 0, 0])
    }

    @Test func timelineRange() {
        let range = TimelineRange.covering([], today: "2026-10-15", firstWeekday: 1)
        #expect(range.first == "2026-10-04") // the Sunday on or before 8 October
        #expect((range.dayCount % 7) == 0)
        #expect(range.last >= "2026-11-19")
        #expect(range.index(of: "2026-10-15") == 11)
        #expect(range.day(at: 11) == "2026-10-15")

        let wide = TimelineRange.covering([DaySpan(start: "2026-08-01", end: "2027-01-10")], today: "2026-10-15")
        #expect(wide.first <= "2026-07-30")
        #expect(wide.last >= "2027-01-12")

        let capped = TimelineRange.covering([DaySpan(start: "2020-01-01", end: "2030-01-01")], today: "2026-10-15", maxDays: 70)
        #expect(capped.dayCount <= 77)

        #expect(range.columns(of: DaySpan(start: "2026-10-01", end: "2026-10-06"))?.first == 0)
        #expect(range.columns(of: DaySpan(start: "2026-10-01", end: "2026-10-06"))?.count == 3)
        #expect(range.columns(of: DaySpan(start: "2026-01-01", end: "2026-01-02")) == nil)
    }

    @Test func dragDirectionFollowsTheLayout() {
        #expect(TimelineDrag.days(translation: 90, dayWidth: 44, rightToLeft: false) == 2)
        #expect(TimelineDrag.days(translation: 90, dayWidth: 44, rightToLeft: true) == -2)
        #expect(TimelineDrag.days(translation: -20, dayWidth: 44, rightToLeft: true) == 0)
        #expect(TimelineDrag.days(translation: 10, dayWidth: 0, rightToLeft: true) == 0)
    }
}
