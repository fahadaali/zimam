import Foundation
import Testing
@testable import ZimamKit

struct LocationRemindersTests {
    let arabic = Locale(identifier: "ar-SA")
    let riyadh = LocationReminderPlanner.Point(latitude: 24.7136, longitude: 46.6753)
    let jeddah = LocationReminderPlanner.Point(latitude: 21.4858, longitude: 39.1925)

    private func place(_ point: LocationReminderPlanner.Point, name: String? = "المكتب", radius: Double = 200,
                       trigger: ReminderRecord.Location.Trigger = .arrive) -> ReminderRecord.Location {
        ReminderRecord.Location(latitude: point.latitude, longitude: point.longitude, radius: radius, name: name, trigger: trigger)
    }

    @Test func plansLocationRemindersOfOpenTasksOnly() {
        let open = PlannerTask(id: UUID(), title: "شراء الحليب")
        let done = PlannerTask(id: UUID(), title: "منجزة", isDone: true)
        let reminder = PlannerReminder(id: UUID(), taskId: open.id, kind: .location, location: place(riyadh))
        let reminders = [
            reminder,
            PlannerReminder(id: UUID(), taskId: done.id, kind: .location, location: place(riyadh)),
            PlannerReminder(id: UUID(), taskId: UUID(), kind: .location, location: place(riyadh)),
            // A location reminder without its place, and other kinds, are not planned here.
            PlannerReminder(id: UUID(), taskId: open.id, kind: .location),
            PlannerReminder(id: UUID(), taskId: open.id, kind: .time, at: "2026-10-13T15:00:00+03:00"),
        ]
        let result = LocationReminderPlanner.plan(tasks: [open, done], reminders: reminders)
        #expect(result.count == 1)
        #expect(result[0].id == "location-\(reminder.id.uuidString)")
        #expect(result[0].id == LocationReminderPlanner.regionId(for: reminder.id))
        #expect(result[0].reminderId == reminder.id)
        #expect(result[0].taskId == open.id)
        #expect(result[0].latitude == riyadh.latitude)
        #expect(result[0].longitude == riyadh.longitude)
        #expect(result[0].radius == 200)
        #expect(result[0].onArrive)
        #expect(result[0].body == "وصلت إلى المكتب: شراء الحليب")
    }

    @Test func theTimeRemindersAreUnaffected() {
        // ReminderPlanner still skips location reminders, now that they carry a place.
        let task = PlannerTask(id: UUID(), title: "شراء الحليب")
        let reminder = PlannerReminder(id: UUID(), taskId: task.id, kind: .location, location: place(riyadh))
        let formatter = DualDateFormatter(primary: .hijri, locale: arabic, timeZone: TimeZone(identifier: "Asia/Riyadh")!)
        #expect(ReminderPlanner.plan(tasks: [task], reminders: [reminder], schedule: nil, now: Date(),
                                           formatter: formatter).isEmpty)
    }

    @Test func bodiesForArrivingAndLeaving() {
        #expect(LocationReminderPlanner.body(placeName: "البيت", trigger: .arrive, taskTitle: "الاتصال بأمي") == "وصلت إلى البيت: الاتصال بأمي")
        #expect(LocationReminderPlanner.body(placeName: "المكتب", trigger: .leave, taskTitle: "إطفاء الجهاز") == "غادرت المكتب: إطفاء الجهاز")
        #expect(LocationReminderPlanner.body(placeName: "  ", trigger: .arrive, taskTitle: "شراء الخبز") == "وصلت إلى المكان المحدد: شراء الخبز")
        #expect(LocationReminderPlanner.body(placeName: nil, trigger: .leave, taskTitle: "شراء الخبز") == "غادرت المكان المحدد: شراء الخبز")
    }

    @Test func leavingWatchesTheExit() {
        let task = PlannerTask(id: UUID(), title: "إطفاء الجهاز")
        let reminder = PlannerReminder(id: UUID(), taskId: task.id, kind: .location, location: place(riyadh, trigger: .leave))
        #expect(LocationReminderPlanner.plan(tasks: [task], reminders: [reminder]).first?.onArrive == false)
    }

    @Test func keepsTheLimitDueSoonestThenNearest() {
        let today = PlannerTask(id: UUID(), title: "اليوم", dueDay: "2026-10-13")
        let overdue = PlannerTask(id: UUID(), title: "متأخرة", dueDay: "2026-10-10")
        let later = PlannerTask(id: UUID(), title: "لاحقاً", dueDay: "2026-11-01")
        let undatedNear = PlannerTask(id: UUID(), title: "قريبة")
        let undatedFar = PlannerTask(id: UUID(), title: "بعيدة")
        let tasks = [today, overdue, later, undatedNear, undatedFar]
        let reminders = [
            PlannerReminder(id: UUID(), taskId: undatedFar.id, kind: .location, location: place(jeddah)),
            PlannerReminder(id: UUID(), taskId: later.id, kind: .location, location: place(riyadh)),
            PlannerReminder(id: UUID(), taskId: undatedNear.id, kind: .location, location: place(riyadh)),
            PlannerReminder(id: UUID(), taskId: today.id, kind: .location, location: place(jeddah)),
            PlannerReminder(id: UUID(), taskId: overdue.id, kind: .location, location: place(jeddah)),
        ]
        let all = LocationReminderPlanner.plan(tasks: tasks, reminders: reminders, near: riyadh)
        #expect(all.map(\.taskId) == [overdue.id, today.id, later.id, undatedNear.id, undatedFar.id])

        let three = LocationReminderPlanner.plan(tasks: tasks, reminders: reminders, near: riyadh, limit: 3)
        #expect(three.map(\.taskId) == [overdue.id, today.id, later.id])
    }

    @Test func neverMoreThanTheRegionBudget() {
        let task = PlannerTask(id: UUID(), title: "كثيرة")
        let reminders = (0..<30).map { index in
            PlannerReminder(id: UUID(), taskId: task.id, kind: .location,
                            location: place(LocationReminderPlanner.Point(latitude: 24 + Double(index) / 100, longitude: 46)))
        }
        let result = LocationReminderPlanner.plan(tasks: [task], reminders: reminders)
        #expect(result.count == LocationReminderPlanner.maxRegions)
        #expect(LocationReminderPlanner.maxRegions <= 20) // iOS watches 20 regions per app
        #expect(Set(result.map(\.id)).count == result.count)
        // The order is stable from run to run.
        #expect(result == LocationReminderPlanner.plan(tasks: [task], reminders: reminders.reversed()))
    }

    @Test func timeRemindersGetTheRestOfTheBudget() {
        #expect(LocationReminderPlanner.timeLimit(reserving: 0) == ReminderPlanner.defaultLimit)
        #expect(LocationReminderPlanner.timeLimit(reserving: 3) == (ReminderPlanner.defaultLimit - 3))
        #expect(LocationReminderPlanner.timeLimit(reserving: 50) == (ReminderPlanner.defaultLimit - LocationReminderPlanner.maxRegions))
        #expect(LocationReminderPlanner.timeLimit(reserving: -1) == ReminderPlanner.defaultLimit)
        // Together they stay under iOS's 64 pending notifications.
        #expect((LocationReminderPlanner.timeLimit(reserving: 10) + 10) <= 64)
    }

    @Test func invalidPlacesAreSkippedAndRadiusClamped() {
        let task = PlannerTask(id: UUID(), title: "مهمة")
        let zero = PlannerReminder(id: UUID(), taskId: task.id, kind: .location,
                                   location: place(LocationReminderPlanner.Point(latitude: 0, longitude: 0)))
        let tiny = PlannerReminder(id: UUID(), taskId: task.id, kind: .location, location: place(riyadh, radius: 10))
        let huge = PlannerReminder(id: UUID(), taskId: task.id, kind: .location, location: place(jeddah, radius: 50_000))
        let result = LocationReminderPlanner.plan(tasks: [task], reminders: [zero, tiny, huge])
        #expect(result.count == 2)
        #expect(Set(result.map(\.radius)) == [50, 10_000])
    }

    @Test func radiusTextInArabicDigits() {
        #expect(LocationReminderPlanner.radiusText(100, locale: arabic) == "١٠٠ م")
        #expect(LocationReminderPlanner.radiusText(550, locale: arabic) == "٥٥٠ م")
        #expect(LocationReminderPlanner.radiusText(1_000, locale: arabic) == "١ كم")
        #expect(LocationReminderPlanner.radiusText(1_500, locale: arabic) == "١٫٥ كم")
        #expect(LocationReminderPlanner.radiusText(250, locale: Locale(identifier: "ar-SA@numbers=latn")) == "250 م")
    }

    @Test func summaryAndTriggerText() {
        #expect(LocationReminderPlanner.triggerText(.arrive) == "عند الوصول")
        #expect(LocationReminderPlanner.triggerText(.leave) == "عند المغادرة")
        #expect(LocationReminderPlanner.summary(place(riyadh, radius: 300, trigger: .leave), locale: arabic) == "عند المغادرة، ٣٠٠ م")
    }

    @Test func sliderRadiusStaysInRangeOnTheStep() {
        #expect(LocationReminderPlanner.sliderRadius(50) == 100)
        #expect(LocationReminderPlanner.sliderRadius(5_000) == 1_000)
        #expect(LocationReminderPlanner.sliderRadius(333) == 350)
        #expect(LocationReminderPlanner.sliderRadius(LocationReminderPlanner.defaultRadius) == 200)
    }

    @Test func distance() {
        let distance = LocationReminderPlanner.distanceMeters(from: riyadh, to: jeddah)
        #expect(abs(distance - 845_100) <= 1_000)
        #expect(abs(LocationReminderPlanner.distanceMeters(from: riyadh, to: riyadh) - 0) <= 0.001)
    }
}
