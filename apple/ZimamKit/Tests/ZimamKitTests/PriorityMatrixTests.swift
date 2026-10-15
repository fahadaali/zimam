import XCTest
@testable import ZimamKit

final class PriorityMatrixTests: XCTestCase {
    let riyadh: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Riyadh")!
        return calendar
    }()

    /// 15 October 2026, 10:00 in Riyadh.
    let now = ISO8601DateFormatter().date(from: "2026-10-15T07:00:00Z")!

    private func quadrant(_ priority: TaskPriority, _ due: String?, at date: Date? = nil) -> PriorityQuadrant {
        PriorityQuadrant.quadrant(priority: priority, dueDate: due, today: date ?? now, calendar: riyadh)
    }

    func testImportanceIsMediumOrHigh() {
        XCTAssertEqual(quadrant(.none, nil), .someday)
        XCTAssertEqual(quadrant(.low, nil), .someday)
        XCTAssertEqual(quadrant(.medium, nil), .important)
        XCTAssertEqual(quadrant(.high, nil), .important)
    }

    func testUrgencyIsDueByTomorrowIncludingOverdue() {
        XCTAssertEqual(quadrant(.none, "2026-10-01"), .urgent) // overdue
        XCTAssertEqual(quadrant(.none, "2026-10-14"), .urgent) // yesterday
        XCTAssertEqual(quadrant(.none, "2026-10-15"), .urgent) // today
        XCTAssertEqual(quadrant(.low, "2026-10-16"), .urgent) // tomorrow
        XCTAssertEqual(quadrant(.low, "2026-10-17"), .someday) // the day after
        XCTAssertEqual(quadrant(.high, "2026-10-16"), .urgentImportant)
        XCTAssertEqual(quadrant(.medium, "2026-11-01"), .important)
        XCTAssertEqual(quadrant(.high, "not-a-day"), .important)
    }

    func testTodayFollowsTheUsersTimeZone() {
        // 22:30 UTC on 15 October is already 16 October in Riyadh: the 17th is tomorrow there.
        let lateUTC = ISO8601DateFormatter().date(from: "2026-10-15T22:30:00Z")!
        XCTAssertEqual(quadrant(.none, "2026-10-17", at: lateUTC), .urgent)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(PriorityQuadrant.quadrant(priority: .none, dueDate: "2026-10-17", today: lateUTC, calendar: utc), .someday)
    }

    func testQuadrantNamesAndFlags() {
        XCTAssertEqual(PriorityQuadrant.allCases.map(\.title), ["مهم وعاجل", "مهم", "عاجل", "يوماً ما"])
        XCTAssertEqual(PriorityQuadrant(important: true, urgent: true), .urgentImportant)
        XCTAssertEqual(PriorityQuadrant(important: false, urgent: true), .urgent)
        XCTAssertTrue(PriorityQuadrant.urgent.isUrgent)
        XCTAssertFalse(PriorityQuadrant.urgent.isImportant)
    }

    func testGroupsOpenTasksInOrderAndLeavesOutDoneOnes() {
        let tasks = [
            TaskRecord(title: "أ", priority: .high, dueDate: "2026-10-15"),
            TaskRecord(title: "ب", status: .done, priority: .high, dueDate: "2026-10-15"),
            TaskRecord(title: "ج", priority: .medium),
            TaskRecord(title: "د", dueDate: "2026-10-16"),
            TaskRecord(title: "هـ", priority: .high, dueDate: "2026-10-10"),
            TaskRecord(title: "و"),
        ]
        let grouped = PriorityMatrix.group(tasks, today: now, calendar: riyadh)
        XCTAssertEqual(grouped[.urgentImportant]?.map(\.title), ["أ", "هـ"])
        XCTAssertEqual(grouped[.important]?.map(\.title), ["ج"])
        XCTAssertEqual(grouped[.urgent]?.map(\.title), ["د"])
        XCTAssertEqual(grouped[.someday]?.map(\.title), ["و"])
        XCTAssertEqual(PriorityMatrix.counts(grouped), [.urgentImportant: 2, .important: 1, .urgent: 1, .someday: 1])

        let empty = PriorityMatrix.group([TaskRecord](), today: now, calendar: riyadh)
        XCTAssertEqual(Set(empty.keys), Set(PriorityQuadrant.allCases))
    }

    // MARK: Moving between quadrants

    private func move(_ priority: TaskPriority, _ due: String?, anchored: Bool = false,
                      to target: PriorityQuadrant) -> PriorityMatrix.Move {
        PriorityMatrix.move(priority: priority, dueDate: due, isAnchored: anchored, to: target, today: now, calendar: riyadh)
    }

    func testMovingIntoImportantRaisesALowPriorityToMedium() {
        XCTAssertEqual(move(.none, nil, to: .important), .moved(priority: .medium, dueDate: nil))
        XCTAssertEqual(move(.low, "2026-10-15", to: .urgentImportant), .moved(priority: .medium, dueDate: "2026-10-15"))
    }

    func testMovingOutOfImportantLowersThePriorityToLow() {
        XCTAssertEqual(move(.high, nil, to: .someday), .moved(priority: .low, dueDate: nil))
        XCTAssertEqual(move(.medium, "2026-10-16", to: .urgent), .moved(priority: .low, dueDate: "2026-10-16"))
    }

    func testMovingIntoUrgentMakesItDueTodayUnlessAlreadyUrgent() {
        XCTAssertEqual(move(.none, nil, to: .urgent), .moved(priority: .none, dueDate: "2026-10-15"))
        XCTAssertEqual(move(.high, "2026-12-01", to: .urgentImportant), .moved(priority: .high, dueDate: "2026-10-15"))
        // Overdue stays overdue: only the importance changes.
        XCTAssertEqual(move(.none, "2026-10-01", to: .urgentImportant), .moved(priority: .medium, dueDate: "2026-10-01"))
    }

    func testMovingOutOfUrgentClearsThePlainDayOnly() {
        XCTAssertEqual(move(.none, "2026-10-15", to: .someday), .moved(priority: .none, dueDate: nil))
        XCTAssertEqual(move(.high, "2026-10-01", to: .important), .moved(priority: .high, dueDate: nil))
        XCTAssertEqual(move(.high, "2026-10-15", anchored: true, to: .important), .refused)
        // A move that keeps urgency never touches the day, anchored or not.
        XCTAssertEqual(move(.high, "2026-10-15", anchored: true, to: .urgent), .moved(priority: .low, dueDate: "2026-10-15"))
    }

    func testMovingToTheSameQuadrantChangesNothing() {
        XCTAssertEqual(move(.high, "2026-10-15", to: .urgentImportant), .unchanged)
        XCTAssertEqual(move(.none, nil, to: .someday), .unchanged)
    }
}
