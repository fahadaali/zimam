import XCTest
@testable import ZimamKit

final class ReminderPlannerTests: XCTestCase {
    let riyadh = TimeZone(identifier: "Asia/Riyadh")!
    /// 2026-10-13 12:00 in Riyadh.
    let now = Date(timeIntervalSince1970: 1_791_882_000)
    lazy var formatter = DualDateFormatter(primary: .hijri, locale: Locale(identifier: "ar-SA"), timeZone: riyadh)
    lazy var schedule = PrayerSchedule(latitude: 24.7136, longitude: 46.6753, method: .ummAlQura, timeZone: riyadh)

    private func plan(_ tasks: [PlannerTask], _ reminders: [PlannerReminder], schedule: PrayerSchedule?,
                      limit: Int = ReminderPlanner.defaultLimit) -> [PlannedNotification] {
        ReminderPlanner.plan(tasks: tasks, reminders: reminders, schedule: schedule, now: now, formatter: formatter, limit: limit)
    }

    private func noon(_ day: String) -> Date {
        formatter.date(fromDay: day)!.addingTimeInterval(12 * 3600)
    }

    func testISOStringsRoundTripWithOffset() {
        XCTAssertEqual(ReminderPlanner.isoString(from: now, timeZone: riyadh), "2026-10-13T12:00:00+03:00")
        XCTAssertEqual(ReminderPlanner.date(fromISO: "2026-10-13T12:00:00+03:00"), now)
        XCTAssertEqual(ReminderPlanner.date(fromISO: "2026-10-13T09:00:00Z"), now)
        XCTAssertEqual(ReminderPlanner.date(fromISO: "2026-10-13T09:00:00.000Z"), now)
        XCTAssertNil(ReminderPlanner.date(fromISO: "tomorrow"))
    }

    func testTimeRemindersInsideTheWindowOnly() {
        let task = PlannerTask(id: UUID(), title: "مراجعة العقد", dueDay: "2026-10-14")
        let soon = PlannerReminder(id: UUID(), taskId: task.id, kind: .time, at: "2026-10-13T15:00:00+03:00")
        let past = PlannerReminder(id: UUID(), taskId: task.id, kind: .time, at: "2026-10-13T11:00:00+03:00")
        let far = PlannerReminder(id: UUID(), taskId: task.id, kind: .time, at: "2026-10-28T12:00:00+03:00")
        let result = plan([task], [soon, past, far], schedule: schedule)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "reminder-\(soon.id.uuidString)")
        XCTAssertEqual(result[0].taskId, task.id)
        XCTAssertEqual(result[0].date, now.addingTimeInterval(3 * 3600))
        XCTAssertEqual(result[0].title, "مراجعة العقد")
        XCTAssertEqual(result[0].body, "موعدها غداً")
    }

    func testTimeReminderForTaskWithoutDueDay() {
        let task = PlannerTask(id: UUID(), title: "اتصال")
        let reminder = PlannerReminder(id: UUID(), taskId: task.id, kind: .time, at: "2026-10-14T09:00:00+03:00")
        XCTAssertEqual(plan([task], [reminder], schedule: nil).first?.body, "تذكير بمهمتك")
    }

    func testDoneTasksOrphansAndLocationRemindersAreSkipped() {
        let done = PlannerTask(id: UUID(), title: "منجزة", isDone: true)
        let open = PlannerTask(id: UUID(), title: "مفتوحة")
        let reminders = [
            PlannerReminder(id: UUID(), taskId: done.id, kind: .time, at: "2026-10-13T15:00:00+03:00"),
            PlannerReminder(id: UUID(), taskId: UUID(), kind: .time, at: "2026-10-13T15:00:00+03:00"),
            PlannerReminder(id: UUID(), taskId: open.id, kind: .location),
        ]
        XCTAssertTrue(plan([done, open], reminders, schedule: schedule).isEmpty)
    }

    func testPrayerReminderWithDueDayFiresOnThatDay() {
        let task = PlannerTask(id: UUID(), title: "زيارة الوالدة", dueDay: "2026-10-15")
        let reminder = PlannerReminder(id: UUID(), taskId: task.id, kind: .prayer, prayer: .asr, offsetMinutes: 20)
        let result = plan([task], [reminder], schedule: schedule)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "reminder-\(reminder.id.uuidString)@2026-10-15")
        XCTAssertEqual(result[0].date, schedule.time(of: .asr, on: noon("2026-10-15"), offsetMinutes: 20))
        XCTAssertEqual(result[0].body, "بعد العصر بـ٢٠ د")
    }

    func testPrayerReminderWithoutDueDayRepeatsDaily() {
        let task = PlannerTask(id: UUID(), title: "ورد يومي")
        let reminder = PlannerReminder(id: UUID(), taskId: task.id, kind: .prayer, prayer: .asr, offsetMinutes: 20)
        let result = plan([task], [reminder], schedule: schedule)
        // Today's Asr is still ahead at noon; the 15th Asr falls after the 14-day window.
        XCTAssertEqual(result.count, 14)
        XCTAssertEqual(result.first?.date, schedule.time(of: .asr, on: now, offsetMinutes: 20))
        XCTAssertEqual(result.first?.id, "reminder-\(reminder.id.uuidString)@2026-10-13")
        XCTAssertEqual(result.last?.id, "reminder-\(reminder.id.uuidString)@2026-10-26")
        XCTAssertEqual(Set(result.map(\.id)).count, 14)
        XCTAssertEqual(result.map(\.date), result.map(\.date).sorted())
    }

    func testPrayerRemindersNeedASchedule() {
        let task = PlannerTask(id: UUID(), title: "ورد يومي", duePrayer: .fajr)
        let reminder = PlannerReminder(id: UUID(), taskId: task.id, kind: .prayer, prayer: .asr)
        XCTAssertTrue(plan([task], [reminder], schedule: nil).isEmpty)
    }

    func testTaskAnchoredToAPrayerFiresAtItsTime() {
        let task = PlannerTask(id: UUID(), title: "شراء الخبز", dueDay: "2026-10-14", duePrayer: .maghrib, duePrayerOffset: -10)
        let result = plan([task], [], schedule: schedule)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "task-\(task.id.uuidString)@2026-10-14")
        XCTAssertEqual(result[0].date, schedule.time(of: .maghrib, on: noon("2026-10-14"), offsetMinutes: -10))
        XCTAssertEqual(result[0].body, "قبل المغرب بـ١٠ د")
    }

    func testAReminderRepeatingTheTaskAnchorIsSentOnce() {
        let task = PlannerTask(id: UUID(), title: "مراجعة", dueDay: "2026-10-14", duePrayer: .asr, duePrayerOffset: 20)
        let reminder = PlannerReminder(id: UUID(), taskId: task.id, kind: .prayer, prayer: .asr, offsetMinutes: 20)
        XCTAssertEqual(plan([task], [reminder], schedule: schedule).count, 1)
    }

    func testKeepsTheSoonestUpToTheLimit() {
        let task = PlannerTask(id: UUID(), title: "كل ساعة")
        var reminders: [PlannerReminder] = []
        for hour in 1...100 {
            let at = ReminderPlanner.isoString(from: now.addingTimeInterval(TimeInterval(hour) * 3600), timeZone: riyadh)
            reminders.append(PlannerReminder(id: UUID(), taskId: task.id, kind: .time, at: at))
        }
        let result = plan([task], reminders.reversed(), schedule: nil)
        XCTAssertEqual(result.count, ReminderPlanner.defaultLimit)
        XCTAssertEqual(result.first?.date, now.addingTimeInterval(3600))
        XCTAssertEqual(result.last?.date, now.addingTimeInterval(TimeInterval(ReminderPlanner.defaultLimit) * 3600))
        XCTAssertEqual(plan([task], reminders, schedule: nil, limit: 5).count, 5)
    }
}
