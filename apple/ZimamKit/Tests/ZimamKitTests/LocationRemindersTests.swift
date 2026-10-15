import XCTest
@testable import ZimamKit

final class LocationRemindersTests: XCTestCase {
    let arabic = Locale(identifier: "ar-SA")
    let riyadh = LocationReminderPlanner.Point(latitude: 24.7136, longitude: 46.6753)
    let jeddah = LocationReminderPlanner.Point(latitude: 21.4858, longitude: 39.1925)

    private func place(_ point: LocationReminderPlanner.Point, name: String? = "المكتب", radius: Double = 200,
                       trigger: ReminderRecord.Location.Trigger = .arrive) -> ReminderRecord.Location {
        ReminderRecord.Location(latitude: point.latitude, longitude: point.longitude, radius: radius, name: name, trigger: trigger)
    }

    func testPlansLocationRemindersOfOpenTasksOnly() {
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
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "location-\(reminder.id.uuidString)")
        XCTAssertEqual(result[0].id, LocationReminderPlanner.regionId(for: reminder.id))
        XCTAssertEqual(result[0].reminderId, reminder.id)
        XCTAssertEqual(result[0].taskId, open.id)
        XCTAssertEqual(result[0].latitude, riyadh.latitude)
        XCTAssertEqual(result[0].longitude, riyadh.longitude)
        XCTAssertEqual(result[0].radius, 200)
        XCTAssertTrue(result[0].onArrive)
        XCTAssertEqual(result[0].body, "وصلت إلى المكتب: شراء الحليب")
    }

    func testTheTimeRemindersAreUnaffected() {
        // ReminderPlanner still skips location reminders, now that they carry a place.
        let task = PlannerTask(id: UUID(), title: "شراء الحليب")
        let reminder = PlannerReminder(id: UUID(), taskId: task.id, kind: .location, location: place(riyadh))
        let formatter = DualDateFormatter(primary: .hijri, locale: arabic, timeZone: TimeZone(identifier: "Asia/Riyadh")!)
        XCTAssertTrue(ReminderPlanner.plan(tasks: [task], reminders: [reminder], schedule: nil, now: Date(),
                                           formatter: formatter).isEmpty)
    }

    func testBodiesForArrivingAndLeaving() {
        XCTAssertEqual(LocationReminderPlanner.body(placeName: "البيت", trigger: .arrive, taskTitle: "الاتصال بأمي"),
                       "وصلت إلى البيت: الاتصال بأمي")
        XCTAssertEqual(LocationReminderPlanner.body(placeName: "المكتب", trigger: .leave, taskTitle: "إطفاء الجهاز"),
                       "غادرت المكتب: إطفاء الجهاز")
        XCTAssertEqual(LocationReminderPlanner.body(placeName: "  ", trigger: .arrive, taskTitle: "شراء الخبز"),
                       "وصلت إلى المكان المحدد: شراء الخبز")
        XCTAssertEqual(LocationReminderPlanner.body(placeName: nil, trigger: .leave, taskTitle: "شراء الخبز"),
                       "غادرت المكان المحدد: شراء الخبز")
    }

    func testLeavingWatchesTheExit() {
        let task = PlannerTask(id: UUID(), title: "إطفاء الجهاز")
        let reminder = PlannerReminder(id: UUID(), taskId: task.id, kind: .location, location: place(riyadh, trigger: .leave))
        XCTAssertEqual(LocationReminderPlanner.plan(tasks: [task], reminders: [reminder]).first?.onArrive, false)
    }

    func testKeepsTheLimitDueSoonestThenNearest() {
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
        XCTAssertEqual(all.map(\.taskId), [overdue.id, today.id, later.id, undatedNear.id, undatedFar.id])

        let three = LocationReminderPlanner.plan(tasks: tasks, reminders: reminders, near: riyadh, limit: 3)
        XCTAssertEqual(three.map(\.taskId), [overdue.id, today.id, later.id])
    }

    func testNeverMoreThanTheRegionBudget() {
        let task = PlannerTask(id: UUID(), title: "كثيرة")
        let reminders = (0..<30).map { index in
            PlannerReminder(id: UUID(), taskId: task.id, kind: .location,
                            location: place(LocationReminderPlanner.Point(latitude: 24 + Double(index) / 100, longitude: 46)))
        }
        let result = LocationReminderPlanner.plan(tasks: [task], reminders: reminders)
        XCTAssertEqual(result.count, LocationReminderPlanner.maxRegions)
        XCTAssertLessThanOrEqual(LocationReminderPlanner.maxRegions, 20) // iOS watches 20 regions per app
        XCTAssertEqual(Set(result.map(\.id)).count, result.count)
        // The order is stable from run to run.
        XCTAssertEqual(result, LocationReminderPlanner.plan(tasks: [task], reminders: reminders.reversed()))
    }

    func testTimeRemindersGetTheRestOfTheBudget() {
        XCTAssertEqual(LocationReminderPlanner.timeLimit(reserving: 0), ReminderPlanner.defaultLimit)
        XCTAssertEqual(LocationReminderPlanner.timeLimit(reserving: 3), ReminderPlanner.defaultLimit - 3)
        XCTAssertEqual(LocationReminderPlanner.timeLimit(reserving: 50),
                       ReminderPlanner.defaultLimit - LocationReminderPlanner.maxRegions)
        XCTAssertEqual(LocationReminderPlanner.timeLimit(reserving: -1), ReminderPlanner.defaultLimit)
        // Together they stay under iOS's 64 pending notifications.
        XCTAssertLessThanOrEqual(LocationReminderPlanner.timeLimit(reserving: 10) + 10, 64)
    }

    func testInvalidPlacesAreSkippedAndRadiusClamped() {
        let task = PlannerTask(id: UUID(), title: "مهمة")
        let zero = PlannerReminder(id: UUID(), taskId: task.id, kind: .location,
                                   location: place(LocationReminderPlanner.Point(latitude: 0, longitude: 0)))
        let tiny = PlannerReminder(id: UUID(), taskId: task.id, kind: .location, location: place(riyadh, radius: 10))
        let huge = PlannerReminder(id: UUID(), taskId: task.id, kind: .location, location: place(jeddah, radius: 50_000))
        let result = LocationReminderPlanner.plan(tasks: [task], reminders: [zero, tiny, huge])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map(\.radius)), [50, 10_000])
    }

    func testRadiusTextInArabicDigits() {
        XCTAssertEqual(LocationReminderPlanner.radiusText(100, locale: arabic), "١٠٠ م")
        XCTAssertEqual(LocationReminderPlanner.radiusText(550, locale: arabic), "٥٥٠ م")
        XCTAssertEqual(LocationReminderPlanner.radiusText(1_000, locale: arabic), "١ كم")
        XCTAssertEqual(LocationReminderPlanner.radiusText(1_500, locale: arabic), "١٫٥ كم")
        XCTAssertEqual(LocationReminderPlanner.radiusText(250, locale: Locale(identifier: "ar-SA@numbers=latn")), "250 م")
    }

    func testSummaryAndTriggerText() {
        XCTAssertEqual(LocationReminderPlanner.triggerText(.arrive), "عند الوصول")
        XCTAssertEqual(LocationReminderPlanner.triggerText(.leave), "عند المغادرة")
        XCTAssertEqual(LocationReminderPlanner.summary(place(riyadh, radius: 300, trigger: .leave), locale: arabic),
                       "عند المغادرة، ٣٠٠ م")
    }

    func testSliderRadiusStaysInRangeOnTheStep() {
        XCTAssertEqual(LocationReminderPlanner.sliderRadius(50), 100)
        XCTAssertEqual(LocationReminderPlanner.sliderRadius(5_000), 1_000)
        XCTAssertEqual(LocationReminderPlanner.sliderRadius(333), 350)
        XCTAssertEqual(LocationReminderPlanner.sliderRadius(LocationReminderPlanner.defaultRadius), 200)
    }

    func testDistance() {
        let distance = LocationReminderPlanner.distanceMeters(from: riyadh, to: jeddah)
        XCTAssertEqual(distance, 845_100, accuracy: 1_000)
        XCTAssertEqual(LocationReminderPlanner.distanceMeters(from: riyadh, to: riyadh), 0, accuracy: 0.001)
    }
}
