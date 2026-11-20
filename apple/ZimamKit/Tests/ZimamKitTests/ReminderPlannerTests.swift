import Foundation
import Testing
@testable import ZimamKit

final class ReminderPlannerTests {
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

    @Test func isoStringsRoundTripWithOffset() {
        #expect(ReminderPlanner.isoString(from: now, timeZone: riyadh) == "2026-10-13T12:00:00+03:00")
        #expect(ReminderPlanner.date(fromISO: "2026-10-13T12:00:00+03:00") == now)
        #expect(ReminderPlanner.date(fromISO: "2026-10-13T09:00:00Z") == now)
        #expect(ReminderPlanner.date(fromISO: "2026-10-13T09:00:00.000Z") == now)
        #expect(ReminderPlanner.date(fromISO: "tomorrow") == nil)
    }

    @Test func timeRemindersInsideTheWindowOnly() {
        let task = PlannerTask(id: UUID(), title: "مراجعة العقد", dueDay: "2026-10-14")
        let soon = PlannerReminder(id: UUID(), taskId: task.id, kind: .time, at: "2026-10-13T15:00:00+03:00")
        let past = PlannerReminder(id: UUID(), taskId: task.id, kind: .time, at: "2026-10-13T11:00:00+03:00")
        let far = PlannerReminder(id: UUID(), taskId: task.id, kind: .time, at: "2026-10-28T12:00:00+03:00")
        let result = plan([task], [soon, past, far], schedule: schedule)
        #expect(result.count == 1)
        #expect(result[0].id == "reminder-\(soon.id.uuidString)")
        #expect(result[0].taskId == task.id)
        #expect(result[0].date == now.addingTimeInterval(3 * 3600))
        #expect(result[0].title == "مراجعة العقد")
        #expect(result[0].body == "موعدها غداً")
    }

    @Test func timeReminderForTaskWithoutDueDay() {
        let task = PlannerTask(id: UUID(), title: "اتصال")
        let reminder = PlannerReminder(id: UUID(), taskId: task.id, kind: .time, at: "2026-10-14T09:00:00+03:00")
        #expect(plan([task], [reminder], schedule: nil).first?.body == "تذكير بمهمتك")
    }

    @Test func doneTasksOrphansAndLocationRemindersAreSkipped() {
        let done = PlannerTask(id: UUID(), title: "منجزة", isDone: true)
        let open = PlannerTask(id: UUID(), title: "مفتوحة")
        let reminders = [
            PlannerReminder(id: UUID(), taskId: done.id, kind: .time, at: "2026-10-13T15:00:00+03:00"),
            PlannerReminder(id: UUID(), taskId: UUID(), kind: .time, at: "2026-10-13T15:00:00+03:00"),
            PlannerReminder(id: UUID(), taskId: open.id, kind: .location),
        ]
        #expect(plan([done, open], reminders, schedule: schedule).isEmpty)
    }

    @Test func prayerReminderWithDueDayFiresOnThatDay() {
        let task = PlannerTask(id: UUID(), title: "زيارة الوالدة", dueDay: "2026-10-15")
        let reminder = PlannerReminder(id: UUID(), taskId: task.id, kind: .prayer, prayer: .asr, offsetMinutes: 20)
        let result = plan([task], [reminder], schedule: schedule)
        #expect(result.count == 1)
        #expect(result[0].id == "reminder-\(reminder.id.uuidString)@2026-10-15")
        #expect(result[0].date == schedule.time(of: .asr, on: noon("2026-10-15"), offsetMinutes: 20))
        #expect(result[0].body == "بعد العصر بـ٢٠ د")
    }

    @Test func prayerReminderWithoutDueDayRepeatsDaily() {
        let task = PlannerTask(id: UUID(), title: "ورد يومي")
        let reminder = PlannerReminder(id: UUID(), taskId: task.id, kind: .prayer, prayer: .asr, offsetMinutes: 20)
        let result = plan([task], [reminder], schedule: schedule)
        // Today's Asr is still ahead at noon; the 15th Asr falls after the 14-day window.
        #expect(result.count == 14)
        #expect(result.first?.date == schedule.time(of: .asr, on: now, offsetMinutes: 20))
        #expect(result.first?.id == "reminder-\(reminder.id.uuidString)@2026-10-13")
        #expect(result.last?.id == "reminder-\(reminder.id.uuidString)@2026-10-26")
        #expect(Set(result.map(\.id)).count == 14)
        #expect(result.map(\.date) == result.map(\.date).sorted())
    }

    @Test func prayerRemindersNeedASchedule() {
        let task = PlannerTask(id: UUID(), title: "ورد يومي", duePrayer: .fajr)
        let reminder = PlannerReminder(id: UUID(), taskId: task.id, kind: .prayer, prayer: .asr)
        #expect(plan([task], [reminder], schedule: nil).isEmpty)
    }

    @Test func aTaskTimeAloneDoesNotNotify() {
        let anchored = PlannerTask(id: UUID(), title: "شراء الخبز", dueDay: "2026-10-14", duePrayer: .maghrib, duePrayerOffset: -10)
        let timed = PlannerTask(id: UUID(), title: "اجتماع", dueDay: "2026-10-14", dueTime: "15:00")
        #expect(plan([anchored, timed], [], schedule: schedule).isEmpty)
    }

    @Test func atTheTimeOfAPrayerAnchoredTask() {
        let task = PlannerTask(id: UUID(), title: "شراء الخبز", dueDay: "2026-10-14", duePrayer: .maghrib, duePrayerOffset: -10)
        let reminder = PlannerReminder(id: UUID(), taskId: task.id, kind: .relative, offsetMinutes: 0)
        let result = plan([task], [reminder], schedule: schedule)
        #expect(result.count == 1)
        #expect(result[0].id == "reminder-\(reminder.id.uuidString)")
        #expect(result[0].date == schedule.time(of: .maghrib, on: noon("2026-10-14"), offsetMinutes: -10))
        #expect(result[0].body == "قبل المغرب بـ١٠ د")
    }

    @Test func relativeToAClockTime() {
        let task = PlannerTask(id: UUID(), title: "اجتماع", dueDay: "2026-10-14", dueTime: "15:00")
        let atTime = PlannerReminder(id: UUID(), taskId: task.id, kind: .relative, offsetMinutes: 0)
        let before = PlannerReminder(id: UUID(), taskId: task.id, kind: .relative, offsetMinutes: -15)
        let result = plan([task], [atTime, before], schedule: nil)
        let threePM = formatter.date(fromDay: "2026-10-14")!.addingTimeInterval(15 * 3600)
        #expect(result.map(\.date) == [threePM.addingTimeInterval(-15 * 60), threePM])
        #expect(result.map(\.body) == ["موعدها بعد ١٥ د", "حان موعدها"])
    }

    @Test func relativeToAnAllDayTaskCountsFromNine() {
        let task = PlannerTask(id: UUID(), title: "تسليم التقرير", dueDay: "2026-10-15")
        let dayBefore = PlannerReminder(id: UUID(), taskId: task.id, kind: .relative, offsetMinutes: -1440)
        let result = plan([task], [dayBefore], schedule: nil)
        #expect(result.count == 1)
        #expect(result[0].date == formatter.date(fromDay: "2026-10-14")!.addingTimeInterval(9 * 3600))
        #expect(result[0].body == "موعدها غداً")
    }

    @Test func relativeToAPrayerWithoutADayRepeatsDaily() {
        let task = PlannerTask(id: UUID(), title: "ورد يومي", duePrayer: .asr, duePrayerOffset: 20)
        let reminder = PlannerReminder(id: UUID(), taskId: task.id, kind: .relative, offsetMinutes: -5)
        let result = plan([task], [reminder], schedule: schedule)
        #expect(result.count == 14)
        #expect(result.first?.date == schedule.time(of: .asr, on: now, offsetMinutes: 15))
        #expect(result.first?.id == "reminder-\(reminder.id.uuidString)@2026-10-13")
    }

    @Test func relativeNeedsATimeToCountFrom() {
        let undated = PlannerTask(id: UUID(), title: "بلا موعد")
        let prayerWithoutPlace = PlannerTask(id: UUID(), title: "بعد العصر", dueDay: "2026-10-14", duePrayer: .asr)
        let reminders = [
            PlannerReminder(id: UUID(), taskId: undated.id, kind: .relative, offsetMinutes: 0),
            PlannerReminder(id: UUID(), taskId: prayerWithoutPlace.id, kind: .relative, offsetMinutes: 0),
        ]
        #expect(plan([undated, prayerWithoutPlace], reminders, schedule: nil).isEmpty)
    }

    @Test func aReminderRepeatingTheTaskTimeIsSentOnce() {
        let task = PlannerTask(id: UUID(), title: "مراجعة", dueDay: "2026-10-14", duePrayer: .asr, duePrayerOffset: 20)
        let atTime = PlannerReminder(id: UUID(), taskId: task.id, kind: .relative, offsetMinutes: 0)
        let prayer = PlannerReminder(id: UUID(), taskId: task.id, kind: .prayer, prayer: .asr, offsetMinutes: 20)
        #expect(plan([task], [atTime, prayer], schedule: schedule).count == 1)
    }

    @Test func keepsTheSoonestUpToTheLimit() {
        let task = PlannerTask(id: UUID(), title: "كل ساعة")
        var reminders: [PlannerReminder] = []
        for hour in 1...100 {
            let at = ReminderPlanner.isoString(from: now.addingTimeInterval(TimeInterval(hour) * 3600), timeZone: riyadh)
            reminders.append(PlannerReminder(id: UUID(), taskId: task.id, kind: .time, at: at))
        }
        let result = plan([task], reminders.reversed(), schedule: nil)
        #expect(result.count == ReminderPlanner.defaultLimit)
        #expect(result.first?.date == now.addingTimeInterval(3600))
        #expect(result.last?.date == now.addingTimeInterval(TimeInterval(ReminderPlanner.defaultLimit) * 3600))
        #expect(plan([task], reminders, schedule: nil, limit: 5).count == 5)
    }

    private func hourly(_ task: PlannerTask, hours: ClosedRange<Int>) -> [PlannerReminder] {
        hours.map { hour in
            let at = ReminderPlanner.isoString(from: now.addingTimeInterval(TimeInterval(hour) * 3600), timeZone: riyadh)
            return PlannerReminder(id: UUID(), taskId: task.id, kind: .time, at: at)
        }
    }

    @Test func aWindowThatFitsReachesItsEnd() {
        let task = PlannerTask(id: UUID(), title: "كل ساعة")
        let window = ReminderPlanner.planWindow(tasks: [task], reminders: hourly(task, hours: 1...10), schedule: nil,
                                                now: now, formatter: formatter)
        #expect(window.notifications.count == 10)
        #expect(window.scheduledThrough == nil)
        // Exactly full is not over the budget.
        let full = ReminderPlanner.planWindow(tasks: [task], reminders: hourly(task, hours: 1...10), schedule: nil,
                                              now: now, formatter: formatter, limit: 10)
        #expect(full.scheduledThrough == nil)
        // What fires after the 14 days is the server's anyway: not left out of the budget.
        let past = ReminderPlanner.planWindow(tasks: [task], reminders: hourly(task, hours: 1...400), schedule: nil,
                                              now: now, formatter: formatter, limit: 400)
        #expect(past.notifications.count == ReminderPlanner.windowDays * 24)
        #expect(past.scheduledThrough == nil)
    }

    @Test func aFullBudgetReachesJustBeforeTheFirstLeftOut() throws {
        let task = PlannerTask(id: UUID(), title: "كل ساعة")
        let reminders = hourly(task, hours: 1...100)
        let window = ReminderPlanner.planWindow(tasks: [task], reminders: reminders.reversed(), schedule: nil,
                                                now: now, formatter: formatter, limit: 5)
        #expect(window.notifications == plan([task], reminders, schedule: nil, limit: 5))
        #expect(window.notifications.last?.date == now.addingTimeInterval(5 * 3600))
        let through = try #require(window.scheduledThrough)
        let firstLeftOut = now.addingTimeInterval(6 * 3600)
        #expect(through < firstLeftOut)
        #expect(through >= window.notifications.last!.date)
        // In the server's milliseconds, the one left out is after it.
        #expect(Int64((through.timeIntervalSince1970 * 1000).rounded(.down)) < Int64(firstLeftOut.timeIntervalSince1970 * 1000))
    }

    @Test func remindersFoldedIntoOneAreNotLeftOut() {
        let task = PlannerTask(id: UUID(), title: "مراجعة")
        // Two reminders of one task in the same minute make one notification; the second is not
        // over the budget even when the budget is full.
        let at = ReminderPlanner.isoString(from: now.addingTimeInterval(3600), timeZone: riyadh)
        let reminders = [PlannerReminder(id: UUID(), taskId: task.id, kind: .time, at: at),
                         PlannerReminder(id: UUID(), taskId: task.id, kind: .time, at: at)]
        let window = ReminderPlanner.planWindow(tasks: [task], reminders: reminders, schedule: nil,
                                                now: now, formatter: formatter, limit: 1)
        #expect(window.notifications.count == 1)
        #expect(window.scheduledThrough == nil)
    }

    @Test func noBudgetSchedulesNothingAndReportsNow() throws {
        let task = PlannerTask(id: UUID(), title: "كل ساعة")
        let window = ReminderPlanner.planWindow(tasks: [task], reminders: hourly(task, hours: 1...3), schedule: nil,
                                                now: now, formatter: formatter, limit: 0)
        #expect(window.notifications.isEmpty)
        let through = try #require(window.scheduledThrough)
        #expect(through < now.addingTimeInterval(3600))
    }
}
