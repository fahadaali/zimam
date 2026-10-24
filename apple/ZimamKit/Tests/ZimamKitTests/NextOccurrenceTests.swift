import Foundation
import Testing
@testable import ZimamKit

/// The next occurrence the phone's `Store` and the watch add when a recurring task is completed.
struct NextOccurrenceTests {
    let riyadh = TimeZone(identifier: "Asia/Riyadh")!

    // 2026-10-13 is a Tuesday.

    @Test func aWeeklySpanKeepsItsLength() throws {
        let trip = TaskRecord(title: "رحلة", status: .done, dueDate: "2026-10-20", startDate: "2026-10-19",
                              recurrence: "FREQ=WEEKLY", completedAt: 1)
        let next = try #require(NextOccurrence.task(after: trip, today: "2026-10-20", timeZone: riyadh, now: 5))
        #expect(next.id != trip.id)
        #expect(next.status == .todo)
        #expect(next.completedAt == nil)
        #expect(next.dueDate == "2026-10-27")
        #expect(next.startDate == "2026-10-26")
        #expect(next.createdAt == nil)
        #expect(next.updatedAt == 5)
    }

    @Test func countsDownAndEnds() throws {
        let task = TaskRecord(title: "دواء", dueDate: "2026-10-13", recurrence: "FREQ=DAILY;COUNT=2")
        let next = try #require(NextOccurrence.task(after: task, today: "2026-10-13", timeZone: riyadh))
        #expect(next.dueDate == "2026-10-14")
        #expect(next.recurrence == "FREQ=DAILY;COUNT=1")
        #expect(NextOccurrence.task(after: next, today: "2026-10-14", timeZone: riyadh) == nil)
        #expect(NextOccurrence.task(after: TaskRecord(title: "مرة"), today: "2026-10-13", timeZone: riyadh) == nil)
    }

    @Test func anOverdueTaskMovesFromToday() throws {
        let task = TaskRecord(title: "رياضة", dueDate: "2026-10-01", recurrence: "FREQ=DAILY")
        let next = try #require(NextOccurrence.task(after: task, today: "2026-10-13", timeZone: riyadh))
        #expect(next.dueDate == "2026-10-13")
    }

    @Test func remindersMoveWithTheTask() throws {
        let taskId = UUID()
        let newId = UUID()
        let time = ReminderRecord(taskId: taskId, kind: .time, at: "2026-10-13T09:00:00+03:00")
        let place = ReminderRecord(taskId: taskId, kind: .location, at: "2026-10-13T17:00:00+03:00",
                                   location: .init(latitude: 24.7, longitude: 46.7, radius: 100, trigger: .arrive), firedAt: 9)
        let relative = ReminderRecord(taskId: taskId, kind: .relative, offsetMinutes: 0)
        let broken = ReminderRecord(taskId: taskId, kind: .time, at: "not a time")
        let copies = NextOccurrence.reminders([time, place, relative, broken], movedTo: newId, from: "2026-10-13",
                                              to: "2026-10-20", timeZone: riyadh, now: 7)
        #expect(copies.count == 3)
        #expect(copies.allSatisfy { $0.taskId == newId && $0.createdAt == nil && $0.updatedAt == 7 })
        #expect(Set(copies.map(\.id)).isDisjoint(with: [time.id, place.id, relative.id]))
        #expect(copies[0].at == "2026-10-20T09:00:00+03:00")
        #expect(copies[1].at == "2026-10-20T17:00:00+03:00")
        #expect(copies[1].firedAt == nil)
        #expect(copies[2].kind == .relative && copies[2].offsetMinutes == 0)
    }

    @Test func theTwinRule() {
        let projectId = UUID()
        let task = TaskRecord(projectId: projectId, title: "تقرير", status: .done, dueDate: "2026-10-13", recurrence: "FREQ=WEEKLY")
        var twin = task
        twin.id = UUID()
        twin.status = .todo
        twin.dueDate = "2026-10-20"
        #expect(NextOccurrence.isSame(twin, as: task, on: "2026-10-20"))
        #expect(!NextOccurrence.isSame(task, as: task, on: "2026-10-13"))
        #expect(!NextOccurrence.isSame(twin, as: task, on: "2026-10-21"))
        var done = twin
        done.status = .done
        #expect(!NextOccurrence.isSame(done, as: task, on: "2026-10-20"))
        var elsewhere = twin
        elsewhere.projectId = nil
        #expect(!NextOccurrence.isSame(elsewhere, as: task, on: "2026-10-20"))
    }
}
