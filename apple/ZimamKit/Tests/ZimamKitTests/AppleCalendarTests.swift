import XCTest
@testable import ZimamKit

final class AppleCalendarTests: XCTestCase {
    let riyadh = TimeZone(identifier: "Asia/Riyadh")!
    // 2026-10-13 12:00 in Riyadh.
    let now = Date(timeIntervalSince1970: 1_791_882_000)
    let work = AppleCalendarImport.CalendarRef(id: "C1", title: "العمل", sourceTitle: "iCloud")
    let family = AppleCalendarImport.CalendarRef(id: "C2", title: "العائلة", sourceTitle: "iCloud")

    /// A moment in Riyadh.
    func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = riyadh
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    func event(_ id: String, _ calendarId: String = "C1", title: String = "حدث", start: Date, end: Date? = nil,
               allDay: Bool = false, rule: AppleRemindersImport.Repeat? = nil, recurring: Bool? = nil,
               detached: Bool = false, occurrence: Date? = nil, location: String? = nil, notes: String? = nil,
               url: URL? = nil) -> AppleCalendarEvent {
        AppleCalendarEvent(externalId: id, calendarId: calendarId, title: title, notes: notes, location: location, url: url,
                           start: start, end: end ?? start.addingTimeInterval(3600), isAllDay: allDay,
                           occurrenceDate: occurrence, isRecurring: recurring, repeatRule: rule, isDetached: detached)
    }

    func testDaysOfTimedAllDayAndSpanningEvents() {
        let timed = event("a", start: at(2026, 10, 20, 10), end: at(2026, 10, 20, 11))
        XCTAssertEqual(timed.span(timeZone: riyadh), DaySpan(start: "2026-10-20", end: "2026-10-20"))

        // EventKit ends an all-day event at 23:59:59; an end at the next midnight is the same day.
        let allDay = event("b", start: at(2026, 10, 20), end: at(2026, 10, 20, 23, 59, 59), allDay: true)
        XCTAssertFalse(allDay.span(timeZone: riyadh).isMultiDay)
        let toMidnight = event("c", start: at(2026, 10, 20), end: at(2026, 10, 21), allDay: true)
        XCTAssertEqual(toMidnight.span(timeZone: riyadh).end, "2026-10-20")

        let trip = event("d", start: at(2026, 10, 20), end: at(2026, 10, 22, 23, 59, 59), allDay: true)
        XCTAssertEqual(trip.span(timeZone: riyadh), DaySpan(start: "2026-10-20", end: "2026-10-22"))

        let overnight = event("e", start: at(2026, 10, 20, 22), end: at(2026, 10, 21, 2))
        XCTAssertEqual(overnight.span(timeZone: riyadh), DaySpan(start: "2026-10-20", end: "2026-10-21"))
    }

    func testTaskFields() throws {
        let meeting = event("a", title: "  اجتماع الفريق ", start: at(2026, 10, 20, 9, 30), location: " قاعة ١ ",
                            notes: "أحضر التقرير", url: URL(string: "https://example.com/m"))
        let fields = try XCTUnwrap(meeting.taskFields(timeZone: riyadh))
        XCTAssertEqual(fields.title, "اجتماع الفريق")
        XCTAssertEqual(fields.notes, "المكان: قاعة ١\n\nأحضر التقرير\n\nhttps://example.com/m")
        XCTAssertEqual(fields.dueDate, "2026-10-20")
        XCTAssertNil(fields.startDate)
        XCTAssertEqual(fields.dueTime, "09:30")

        let allDay = event("b", start: at(2026, 10, 20), end: at(2026, 10, 20, 23, 59, 59), allDay: true)
        XCTAssertNil(allDay.taskFields(timeZone: riyadh)?.dueTime)
        XCTAssertNil(allDay.taskFields(timeZone: riyadh)?.notes)

        // Spanning days: from the first day to the last, without a time.
        let trip = event("c", start: at(2026, 10, 20, 22), end: at(2026, 10, 22, 8))
        let tripFields = try XCTUnwrap(trip.taskFields(timeZone: riyadh))
        XCTAssertEqual(tripFields.startDate, "2026-10-20")
        XCTAssertEqual(tripFields.dueDate, "2026-10-22")
        XCTAssertNil(tripFields.dueTime)

        XCTAssertNil(event("d", title: "  ", start: at(2026, 10, 20)).taskFields(timeZone: riyadh))
    }

    func testKeysAndDayOrder() {
        let single = event("x", start: at(2026, 10, 20, 9))
        XCTAssertEqual(single.importKey(timeZone: riyadh), "x")
        // A moved occurrence keeps the day it was planned on.
        let moved = event("s", start: at(2026, 10, 21, 9), rule: .init(frequency: .weekly), detached: true,
                          occurrence: at(2026, 10, 20, 9))
        XCTAssertEqual(moved.importKey(timeZone: riyadh), "s#2026-10-20")
        XCTAssertNotEqual(single.id, event("x", start: at(2026, 10, 27, 9)).id)

        let allDay = event("a", start: at(2026, 10, 20), end: at(2026, 10, 20, 23, 59, 59), allDay: true)
        let early = event("b", start: at(2026, 10, 20, 8))
        let late = event("c", start: at(2026, 10, 20, 15))
        let sorted = [late, early, allDay].sorted { AppleCalendarEvent.dayOrder($0, $1, timeZone: riyadh) }
        XCTAssertEqual(sorted.map(\.externalId), ["a", "b", "c"])
    }

    func testWindowRunsFromTodayForMonths() {
        let window = AppleCalendarImport.window(months: 3, now: now, timeZone: riyadh)
        XCTAssertEqual(window.start, at(2026, 10, 13))
        XCTAssertEqual(window.end, at(2027, 1, 13))
    }

    func testRecurrenceFromEventKitRules() {
        let weekly = AppleRemindersImport.Repeat(frequency: .weekly, interval: 2, weekdays: [.thursday, .monday])
        XCTAssertEqual(AppleCalendarImport.recurrence(weekly, anchorDay: "2026-10-15", seriesStartDay: nil, timeZone: riyadh),
                       "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH")

        let inexact = AppleRemindersImport.Repeat(frequency: .monthly, isExact: false)
        XCTAssertNil(AppleCalendarImport.recurrence(inexact, anchorDay: "2026-10-15", seriesStartDay: nil, timeZone: riyadh))

        let until = AppleRemindersImport.Repeat(frequency: .daily, until: at(2026, 12, 31, 12))
        XCTAssertEqual(AppleCalendarImport.recurrence(until, anchorDay: "2026-10-15", seriesStartDay: nil, timeZone: riyadh),
                       "FREQ=DAILY;UNTIL=20261231")

        // COUNT counts from the series' first occurrence; Zimam's counts what is left from the task.
        let counted = AppleRemindersImport.Repeat(frequency: .daily, count: 10)
        XCTAssertEqual(AppleCalendarImport.recurrence(counted, anchorDay: "2026-10-13", seriesStartDay: "2026-10-10",
                                                      timeZone: riyadh), "FREQ=DAILY;COUNT=7")
        XCTAssertEqual(AppleCalendarImport.recurrence(counted, anchorDay: "2026-10-13", seriesStartDay: "2026-10-13",
                                                      timeZone: riyadh), "FREQ=DAILY;COUNT=10")
        // Without the series' start the count cannot be carried; a series already over gives nothing.
        XCTAssertNil(AppleCalendarImport.recurrence(counted, anchorDay: "2026-10-13", seriesStartDay: nil, timeZone: riyadh))
        let short = AppleRemindersImport.Repeat(frequency: .daily, count: 3)
        XCTAssertNil(AppleCalendarImport.recurrence(short, anchorDay: "2026-10-13", seriesStartDay: "2026-10-01", timeZone: riyadh))
    }

    func testCalendarsBecomeProjectsAndEventsBecomeTasks() {
        let weekly = AppleRemindersImport.Repeat(frequency: .weekly)
        let monthlyByPosition = AppleRemindersImport.Repeat(frequency: .monthly, isExact: false)
        let events = [
            event("e1", title: "اجتماع الفريق", start: at(2026, 10, 14, 9), location: "قاعة ١"),
            // A weekly series: one repeating task from its first occurrence.
            event("s1", title: "مراجعة أسبوعية", start: at(2026, 10, 15, 10), rule: weekly),
            event("s1", title: "مراجعة أسبوعية", start: at(2026, 10, 22, 10), rule: weekly),
            event("s1", title: "مراجعة أسبوعية", start: at(2026, 10, 29, 10), rule: weekly),
            // A rule Zimam cannot express: each occurrence on its own.
            event("s2", "C2", title: "عشاء العائلة", start: at(2026, 11, 20, 19), rule: monthlyByPosition),
            event("s2", "C2", title: "عشاء العائلة", start: at(2026, 10, 20, 19), rule: monthlyByPosition),
            event("u1", "C2", title: "   ", start: at(2026, 10, 18, 9)),
            // A series whose first occurrence here was moved: the task follows the rule's day.
            event("s3", title: "تمرين", start: at(2026, 10, 16, 15), rule: .init(frequency: .daily), detached: true,
                  occurrence: at(2026, 10, 16, 7)),
            event("s3", title: "تمرين", start: at(2026, 10, 17, 7), rule: .init(frequency: .daily)),
            event("z", "C3", title: "في تقويم لم يُختر", start: at(2026, 10, 14, 9)),
        ]
        let plan = AppleCalendarImport.plan(events: events, calendars: [work, family], knownTasks: [:], knownProjects: [:],
                                            timeZone: riyadh, now: now, firstProjectSortOrder: 5)
        XCTAssertEqual(plan.projects.map(\.name), ["العمل", "العائلة"])
        XCTAssertEqual(plan.projects.map(\.sortOrder), [5, 6])
        XCTAssertEqual(plan.tasks.map(\.title), ["اجتماع الفريق", "مراجعة أسبوعية", "تمرين", "عشاء العائلة", "عشاء العائلة"])
        XCTAssertEqual(plan.untitled, 1)
        XCTAssertEqual(plan.expandedSeries, 1)

        let meeting = plan.tasks[0]
        XCTAssertEqual(meeting.projectId, plan.projects[0].id)
        XCTAssertEqual(meeting.dueDate, "2026-10-14")
        XCTAssertEqual(meeting.dueTime, "09:00")
        XCTAssertEqual(meeting.notes, "المكان: قاعة ١")
        XCTAssertNil(meeting.recurrence)

        let review = plan.tasks[1]
        XCTAssertEqual(review.dueDate, "2026-10-15")
        XCTAssertEqual(review.recurrence, "FREQ=WEEKLY")

        let workout = plan.tasks[2]
        XCTAssertEqual(workout.dueDate, "2026-10-17")
        XCTAssertEqual(workout.dueTime, "07:00")
        XCTAssertEqual(workout.recurrence, "FREQ=DAILY")

        XCTAssertEqual(plan.tasks[3].dueDate, "2026-10-20")
        XCTAssertEqual(plan.tasks[4].dueDate, "2026-11-20")
        XCTAssertEqual(plan.tasks[3].projectId, plan.projects[1].id)
        XCTAssertEqual(plan.tasks.map(\.sortOrder), [0, 1, 2, 0, 1])

        XCTAssertEqual(Set(plan.taskRefs.keys), ["e1", "s1", "s3", "s2#2026-10-20", "s2#2026-11-20"])
        XCTAssertEqual(plan.projectRefs["C2"], plan.projects[1].id)
        XCTAssertEqual(AppleCalendarImport.summary(plan, locale: Locale(identifier: "ar-SA")),
                       "أُضيفت ٥ مهام. وما تكرر بقاعدة لا يدعمها زمام استُورد كل موعد منه مهمةً مستقلة. وتُرك ما لا عنوان له: ١.")
    }

    func testReimportSkipsWhatWasImportedAndReusesTheProject() {
        let monthly = AppleRemindersImport.Repeat(frequency: .monthly, isExact: false)
        let first = [
            event("e1", title: "اجتماع", start: at(2026, 10, 14, 9)),
            event("s1", title: "مراجعة", start: at(2026, 10, 15, 10), rule: .init(frequency: .weekly)),
            event("s2", title: "عشاء", start: at(2026, 10, 20, 19), rule: monthly),
        ]
        let before = AppleCalendarImport.plan(events: first, calendars: [work], knownTasks: [:], knownProjects: [:],
                                              timeZone: riyadh, now: now)
        XCTAssertEqual(before.tasks.count, 3)

        // A longer window now: the series' later occurrences, and one new event.
        let again = first + [
            event("s1", title: "مراجعة", start: at(2026, 10, 22, 10), rule: .init(frequency: .weekly)),
            event("s2", title: "عشاء", start: at(2026, 11, 20, 19), rule: monthly),
            event("e2", title: "موعد الطبيب", start: at(2026, 10, 25, 16)),
        ]
        let plan = AppleCalendarImport.plan(events: again, calendars: [work], knownTasks: before.taskRefs,
                                            knownProjects: before.projectRefs, timeZone: riyadh, now: now)
        XCTAssertTrue(plan.projects.isEmpty)
        XCTAssertEqual(plan.tasks.map(\.title), ["موعد الطبيب", "عشاء"])
        XCTAssertEqual(plan.tasks.map(\.dueDate), ["2026-10-25", "2026-11-20"])
        XCTAssertEqual(plan.tasks.first?.projectId, before.projects.first?.id)
        XCTAssertEqual(plan.alreadyImported, 3)
        XCTAssertEqual(Set(plan.taskRefs.keys), ["e2", "s2#2026-11-20"])

        let nothing = AppleCalendarImport.plan(events: first, calendars: [work], knownTasks: before.taskRefs,
                                               knownProjects: before.projectRefs, timeZone: riyadh, now: now)
        XCTAssertEqual(AppleCalendarImport.summary(nothing, locale: Locale(identifier: "ar-SA")),
                       "لا جديد: كل الأحداث المختارة مستوردة من قبل.")
    }

    func testACountedSeriesWithoutItsStartIsImportedOccurrenceByOccurrence() {
        let counted = AppleRemindersImport.Repeat(frequency: .daily, count: 5)
        let events = [
            event("s", title: "دورة", start: at(2026, 10, 14, 9), rule: counted),
            event("s", title: "دورة", start: at(2026, 10, 15, 9), rule: counted),
        ]
        let unknown = AppleCalendarImport.plan(events: events, calendars: [work], knownTasks: [:], knownProjects: [:],
                                               timeZone: riyadh, now: now)
        XCTAssertEqual(unknown.tasks.count, 2)
        XCTAssertTrue(unknown.tasks.allSatisfy { $0.recurrence == nil })

        let known = AppleCalendarImport.plan(events: events, calendars: [work], knownTasks: [:], knownProjects: [:],
                                             seriesStarts: ["s": at(2026, 10, 12, 9)], timeZone: riyadh, now: now)
        XCTAssertEqual(known.tasks.count, 1)
        XCTAssertEqual(known.tasks.first?.recurrence, "FREQ=DAILY;COUNT=3")
    }
}
