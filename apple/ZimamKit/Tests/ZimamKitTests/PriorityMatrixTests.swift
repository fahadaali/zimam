import Foundation
import Testing
@testable import ZimamKit

struct PriorityMatrixTests {
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

    @Test func importanceIsMediumOrHigh() {
        #expect(quadrant(.none, nil) == .someday)
        #expect(quadrant(.low, nil) == .someday)
        #expect(quadrant(.medium, nil) == .important)
        #expect(quadrant(.high, nil) == .important)
    }

    @Test func urgencyIsDueByTomorrowIncludingOverdue() {
        #expect(quadrant(.none, "2026-10-01") == .urgent) // overdue
        #expect(quadrant(.none, "2026-10-14") == .urgent) // yesterday
        #expect(quadrant(.none, "2026-10-15") == .urgent) // today
        #expect(quadrant(.low, "2026-10-16") == .urgent) // tomorrow
        #expect(quadrant(.low, "2026-10-17") == .someday) // the day after
        #expect(quadrant(.high, "2026-10-16") == .urgentImportant)
        #expect(quadrant(.medium, "2026-11-01") == .important)
        #expect(quadrant(.high, "not-a-day") == .important)
    }

    @Test func todayFollowsTheUsersTimeZone() {
        // 22:30 UTC on 15 October is already 16 October in Riyadh: the 17th is tomorrow there.
        let lateUTC = ISO8601DateFormatter().date(from: "2026-10-15T22:30:00Z")!
        #expect(quadrant(.none, "2026-10-17", at: lateUTC) == .urgent)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(PriorityQuadrant.quadrant(priority: .none, dueDate: "2026-10-17", today: lateUTC, calendar: utc) == .someday)
    }

    @Test func quadrantNamesAndFlags() {
        #expect(PriorityQuadrant.allCases.map(\.title) == ["مهم وعاجل", "مهم", "عاجل", "يوماً ما"])
        #expect(PriorityQuadrant(important: true, urgent: true) == .urgentImportant)
        #expect(PriorityQuadrant(important: false, urgent: true) == .urgent)
        #expect(PriorityQuadrant.urgent.isUrgent)
        #expect(!PriorityQuadrant.urgent.isImportant)
    }

    @Test func groupsOpenTasksInOrderAndLeavesOutDoneOnes() {
        let tasks = [
            TaskRecord(title: "أ", priority: .high, dueDate: "2026-10-15"),
            TaskRecord(title: "ب", status: .done, priority: .high, dueDate: "2026-10-15"),
            TaskRecord(title: "ج", priority: .medium),
            TaskRecord(title: "د", dueDate: "2026-10-16"),
            TaskRecord(title: "هـ", priority: .high, dueDate: "2026-10-10"),
            TaskRecord(title: "و"),
        ]
        let grouped = PriorityMatrix.group(tasks, today: now, calendar: riyadh)
        #expect(grouped[.urgentImportant]?.map(\.title) == ["أ", "هـ"])
        #expect(grouped[.important]?.map(\.title) == ["ج"])
        #expect(grouped[.urgent]?.map(\.title) == ["د"])
        #expect(grouped[.someday]?.map(\.title) == ["و"])
        #expect(PriorityMatrix.counts(grouped) == [.urgentImportant: 2, .important: 1, .urgent: 1, .someday: 1])

        let empty = PriorityMatrix.group([TaskRecord](), today: now, calendar: riyadh)
        #expect(Set(empty.keys) == Set(PriorityQuadrant.allCases))
    }

    // MARK: Moving between quadrants

    private func move(_ priority: TaskPriority, _ due: String?, anchored: Bool = false,
                      to target: PriorityQuadrant) -> PriorityMatrix.Move {
        PriorityMatrix.move(priority: priority, dueDate: due, isAnchored: anchored, to: target, today: now, calendar: riyadh)
    }

    @Test func movingIntoImportantRaisesALowPriorityToMedium() {
        #expect(move(.none, nil, to: .important) == .moved(priority: .medium, dueDate: nil))
        #expect(move(.low, "2026-10-15", to: .urgentImportant) == .moved(priority: .medium, dueDate: "2026-10-15"))
    }

    @Test func movingOutOfImportantLowersThePriorityToLow() {
        #expect(move(.high, nil, to: .someday) == .moved(priority: .low, dueDate: nil))
        #expect(move(.medium, "2026-10-16", to: .urgent) == .moved(priority: .low, dueDate: "2026-10-16"))
    }

    @Test func movingIntoUrgentMakesItDueTodayUnlessAlreadyUrgent() {
        #expect(move(.none, nil, to: .urgent) == .moved(priority: .none, dueDate: "2026-10-15"))
        #expect(move(.high, "2026-12-01", to: .urgentImportant) == .moved(priority: .high, dueDate: "2026-10-15"))
        // Overdue stays overdue: only the importance changes.
        #expect(move(.none, "2026-10-01", to: .urgentImportant) == .moved(priority: .medium, dueDate: "2026-10-01"))
    }

    @Test func movingOutOfUrgentClearsThePlainDayOnly() {
        #expect(move(.none, "2026-10-15", to: .someday) == .moved(priority: .none, dueDate: nil))
        #expect(move(.high, "2026-10-01", to: .important) == .moved(priority: .high, dueDate: nil))
        #expect(move(.high, "2026-10-15", anchored: true, to: .important) == .refused)
        // A move that keeps urgency never touches the day, anchored or not.
        #expect(move(.high, "2026-10-15", anchored: true, to: .urgent) == .moved(priority: .low, dueDate: "2026-10-15"))
    }

    @Test func movingToTheSameQuadrantChangesNothing() {
        #expect(move(.high, "2026-10-15", to: .urgentImportant) == .unchanged)
        #expect(move(.none, nil, to: .someday) == .unchanged)
    }
}
