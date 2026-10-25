import Foundation
import Testing
@testable import ZimamKit

struct AppleCalendarTests {
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

    @Test func daysOfTimedAllDayAndSpanningEvents() {
        let timed = event("a", start: at(2026, 10, 20, 10), end: at(2026, 10, 20, 11))
        #expect(timed.span(timeZone: riyadh) == DaySpan(start: "2026-10-20", end: "2026-10-20"))

        // EventKit ends an all-day event at 23:59:59; an end at the next midnight is the same day.
        let allDay = event("b", start: at(2026, 10, 20), end: at(2026, 10, 20, 23, 59, 59), allDay: true)
        #expect(!allDay.span(timeZone: riyadh).isMultiDay)
        let toMidnight = event("c", start: at(2026, 10, 20), end: at(2026, 10, 21), allDay: true)
        #expect(toMidnight.span(timeZone: riyadh).end == "2026-10-20")

        let trip = event("d", start: at(2026, 10, 20), end: at(2026, 10, 22, 23, 59, 59), allDay: true)
        #expect(trip.span(timeZone: riyadh) == DaySpan(start: "2026-10-20", end: "2026-10-22"))

        let overnight = event("e", start: at(2026, 10, 20, 22), end: at(2026, 10, 21, 2))
        #expect(overnight.span(timeZone: riyadh) == DaySpan(start: "2026-10-20", end: "2026-10-21"))
    }

    @Test func taskFields() throws {
        let meeting = event("a", title: "  اجتماع الفريق ", start: at(2026, 10, 20, 9, 30), location: " قاعة ١ ",
                            notes: "أحضر التقرير", url: URL(string: "https://example.com/m"))
        let fields = try #require(meeting.taskFields(timeZone: riyadh))
        #expect(fields.title == "اجتماع الفريق")
        #expect(fields.notes == "المكان: قاعة ١\n\nأحضر التقرير\n\nhttps://example.com/m")
        #expect(fields.dueDate == "2026-10-20")
        #expect(fields.startDate == nil)
        #expect(fields.dueTime == "09:30")

        let allDay = event("b", start: at(2026, 10, 20), end: at(2026, 10, 20, 23, 59, 59), allDay: true)
        #expect(allDay.taskFields(timeZone: riyadh)?.dueTime == nil)
        #expect(allDay.taskFields(timeZone: riyadh)?.notes == nil)

        // Spanning days: from the first day to the last, without a time.
        let trip = event("c", start: at(2026, 10, 20, 22), end: at(2026, 10, 22, 8))
        let tripFields = try #require(trip.taskFields(timeZone: riyadh))
        #expect(tripFields.startDate == "2026-10-20")
        #expect(tripFields.dueDate == "2026-10-22")
        #expect(tripFields.dueTime == nil)

        #expect(event("d", title: "  ", start: at(2026, 10, 20)).taskFields(timeZone: riyadh) == nil)
    }

    @Test func keysAndDayOrder() {
        let single = event("x", start: at(2026, 10, 20, 9))
        #expect(single.importKey(timeZone: riyadh) == "x")
        // A moved occurrence keeps the day it was planned on.
        let moved = event("s", start: at(2026, 10, 21, 9), rule: .init(frequency: .weekly), detached: true,
                          occurrence: at(2026, 10, 20, 9))
        #expect(moved.importKey(timeZone: riyadh) == "s#2026-10-20")
        #expect(single.id != event("x", start: at(2026, 10, 27, 9)).id)

        let allDay = event("a", start: at(2026, 10, 20), end: at(2026, 10, 20, 23, 59, 59), allDay: true)
        let early = event("b", start: at(2026, 10, 20, 8))
        let late = event("c", start: at(2026, 10, 20, 15))
        let sorted = [late, early, allDay].sorted { AppleCalendarEvent.dayOrder($0, $1, timeZone: riyadh) }
        #expect(sorted.map(\.externalId) == ["a", "b", "c"])
    }

    @Test func windowRunsFromTodayForMonths() {
        let window = AppleCalendarImport.window(months: 3, now: now, timeZone: riyadh)
        #expect(window.start == at(2026, 10, 13))
        #expect(window.end == at(2027, 1, 13))
    }

    @Test func recurrenceFromEventKitRules() {
        let weekly = AppleRemindersImport.Repeat(frequency: .weekly, interval: 2, weekdays: [.thursday, .monday])
        #expect(AppleCalendarImport.recurrence(weekly, anchorDay: "2026-10-15", seriesStartDay: nil, timeZone: riyadh) == "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH")

        let inexact = AppleRemindersImport.Repeat(frequency: .monthly, isExact: false)
        #expect(AppleCalendarImport.recurrence(inexact, anchorDay: "2026-10-15", seriesStartDay: nil, timeZone: riyadh) == nil)

        let until = AppleRemindersImport.Repeat(frequency: .daily, until: at(2026, 12, 31, 12))
        #expect(AppleCalendarImport.recurrence(until, anchorDay: "2026-10-15", seriesStartDay: nil, timeZone: riyadh) == "FREQ=DAILY;UNTIL=20261231")

        // COUNT counts from the series' first occurrence; Zimam's counts what is left from the task.
        let counted = AppleRemindersImport.Repeat(frequency: .daily, count: 10)
        #expect(AppleCalendarImport.recurrence(counted, anchorDay: "2026-10-13", seriesStartDay: "2026-10-10",
                                                      timeZone: riyadh) == "FREQ=DAILY;COUNT=7")
        #expect(AppleCalendarImport.recurrence(counted, anchorDay: "2026-10-13", seriesStartDay: "2026-10-13",
                                                      timeZone: riyadh) == "FREQ=DAILY;COUNT=10")
        // Without the series' start the count cannot be carried; a series already over gives nothing.
        #expect(AppleCalendarImport.recurrence(counted, anchorDay: "2026-10-13", seriesStartDay: nil, timeZone: riyadh) == nil)
        let short = AppleRemindersImport.Repeat(frequency: .daily, count: 3)
        #expect(AppleCalendarImport.recurrence(short, anchorDay: "2026-10-13", seriesStartDay: "2026-10-01", timeZone: riyadh) == nil)
        // A monthly series on the 31st counts 28 February, 31 March and 30 April before the task,
        // and the task on the 30th keeps the series' day for the occurrences after it.
        let monthly = AppleRemindersImport.Repeat(frequency: .monthly, count: 5)
        #expect(AppleCalendarImport.recurrence(monthly, anchorDay: "2026-04-30", seriesStartDay: "2026-01-31",
                                                      timeZone: riyadh) == "FREQ=MONTHLY;BYMONTHDAY=31;COUNT=2")
    }

    @Test func calendarsBecomeProjectsAndEventsBecomeTasks() {
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
        #expect(plan.projects.map(\.name) == ["العمل", "العائلة"])
        #expect(plan.projects.map(\.sortOrder) == [5, 6])
        #expect(plan.tasks.map(\.title) == ["اجتماع الفريق", "مراجعة أسبوعية", "تمرين", "عشاء العائلة", "عشاء العائلة"])
        #expect(plan.untitled == 1)
        #expect(plan.expandedSeries == 1)

        let meeting = plan.tasks[0]
        #expect(meeting.projectId == plan.projects[0].id)
        #expect(meeting.dueDate == "2026-10-14")
        #expect(meeting.dueTime == "09:00")
        #expect(meeting.notes == "المكان: قاعة ١")
        #expect(meeting.recurrence == nil)

        let review = plan.tasks[1]
        #expect(review.dueDate == "2026-10-15")
        #expect(review.recurrence == "FREQ=WEEKLY")

        let workout = plan.tasks[2]
        #expect(workout.dueDate == "2026-10-17")
        #expect(workout.dueTime == "07:00")
        #expect(workout.recurrence == "FREQ=DAILY")

        #expect(plan.tasks[3].dueDate == "2026-10-20")
        #expect(plan.tasks[4].dueDate == "2026-11-20")
        #expect(plan.tasks[3].projectId == plan.projects[1].id)
        #expect(plan.tasks.map(\.sortOrder) == [0, 1, 2, 0, 1])

        #expect(Set(plan.taskRefs.keys) == ["e1", "s1", "s3", "s2#2026-10-20", "s2#2026-11-20"])
        #expect(plan.projectRefs["C2"] == plan.projects[1].id)
        #expect(AppleCalendarImport.summary(plan, locale: Locale(identifier: "ar-SA")) == "أُضيفت ٥ مهام. وما تكرر بقاعدة لا يدعمها زمام استُورد كل موعد منه مهمةً مستقلة. وتُرك ما لا عنوان له: ١.")
    }

    @Test func reimportSkipsWhatWasImportedAndReusesTheProject() {
        let monthly = AppleRemindersImport.Repeat(frequency: .monthly, isExact: false)
        let first = [
            event("e1", title: "اجتماع", start: at(2026, 10, 14, 9)),
            event("s1", title: "مراجعة", start: at(2026, 10, 15, 10), rule: .init(frequency: .weekly)),
            event("s2", title: "عشاء", start: at(2026, 10, 20, 19), rule: monthly),
        ]
        let before = AppleCalendarImport.plan(events: first, calendars: [work], knownTasks: [:], knownProjects: [:],
                                              timeZone: riyadh, now: now)
        #expect(before.tasks.count == 3)

        // A longer window now: the series' later occurrences, and one new event.
        let again = first + [
            event("s1", title: "مراجعة", start: at(2026, 10, 22, 10), rule: .init(frequency: .weekly)),
            event("s2", title: "عشاء", start: at(2026, 11, 20, 19), rule: monthly),
            event("e2", title: "موعد الطبيب", start: at(2026, 10, 25, 16)),
        ]
        let plan = AppleCalendarImport.plan(events: again, calendars: [work], knownTasks: before.taskRefs,
                                            knownProjects: before.projectRefs, timeZone: riyadh, now: now)
        #expect(plan.projects.isEmpty)
        #expect(plan.tasks.map(\.title) == ["موعد الطبيب", "عشاء"])
        #expect(plan.tasks.map(\.dueDate) == ["2026-10-25", "2026-11-20"])
        #expect(plan.tasks.first?.projectId == before.projects.first?.id)
        #expect(plan.alreadyImported == 3)
        #expect(Set(plan.taskRefs.keys) == ["e2", "s2#2026-11-20"])

        let nothing = AppleCalendarImport.plan(events: first, calendars: [work], knownTasks: before.taskRefs,
                                               knownProjects: before.projectRefs, timeZone: riyadh, now: now)
        #expect(AppleCalendarImport.summary(nothing, locale: Locale(identifier: "ar-SA")) == "لا جديد: كل الأحداث المختارة مستوردة من قبل.")
    }

    @Test func aCountedSeriesWithoutItsStartIsImportedOccurrenceByOccurrence() {
        let counted = AppleRemindersImport.Repeat(frequency: .daily, count: 5)
        let events = [
            event("s", title: "دورة", start: at(2026, 10, 14, 9), rule: counted),
            event("s", title: "دورة", start: at(2026, 10, 15, 9), rule: counted),
        ]
        let unknown = AppleCalendarImport.plan(events: events, calendars: [work], knownTasks: [:], knownProjects: [:],
                                               timeZone: riyadh, now: now)
        #expect(unknown.tasks.count == 2)
        #expect(unknown.tasks.allSatisfy { $0.recurrence == nil })

        let known = AppleCalendarImport.plan(events: events, calendars: [work], knownTasks: [:], knownProjects: [:],
                                             seriesStarts: ["s": at(2026, 10, 12, 9)], timeZone: riyadh, now: now)
        #expect(known.tasks.count == 1)
        #expect(known.tasks.first?.recurrence == "FREQ=DAILY;COUNT=3")
    }
}
