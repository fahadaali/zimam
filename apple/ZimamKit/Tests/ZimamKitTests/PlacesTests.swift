import Foundation
import Testing
@testable import ZimamKit

/// Saved places («أماكني») and location reminders with a time: whichever comes first.
struct PlacesTests {
    let arabic = Locale(identifier: "ar-SA")
    let riyadh = TimeZone(identifier: "Asia/Riyadh")!
    let home = PlaceRecord(name: "البيت", latitude: 24.7136, longitude: 46.6753, radius: 200)
    let office = PlaceRecord(name: "المكتب", latitude: 21.4858, longitude: 39.1925, radius: 300)
    /// 2026-10-13 12:00 in Riyadh.
    let now = Date(timeIntervalSince1970: 1_791_882_000)

    private var formatter: DualDateFormatter {
        DualDateFormatter(primary: .hijri, locale: arabic, timeZone: riyadh)
    }

    private func iso(_ date: Date) -> String {
        ReminderPlanner.isoString(from: date, timeZone: riyadh)
    }

    // MARK: Records

    @Test func aReminderCopiesTheSavedPlace() {
        let copy = ReminderRecord.Location(place: home, trigger: .leave)
        #expect(copy == ReminderRecord.Location(latitude: home.latitude, longitude: home.longitude, radius: 200, name: "البيت",
                                                 trigger: .leave, placeId: home.id))
    }

    @Test func decodesPlacesAndTheNewReminderFields() throws {
        let json = """
        {"changes":[
          {"entity":"place","id":"3f2b8c1e-0a4d-4e6f-9b7a-1c2d3e4f5a6b","op":"upsert","data":{
            "id":"3f2b8c1e-0a4d-4e6f-9b7a-1c2d3e4f5a6b","name":"الاستراحة","latitude":24.9,"longitude":46.5,"radius":400,
            "createdAt":1000,"updatedAt":2000}},
          {"entity":"reminder","id":"7a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","op":"upsert","data":{
            "id":"7a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","taskId":"8b2c3d4e-5f6a-4b7c-9d8e-0f1a2b3c4d5e","kind":"location",
            "at":"2026-10-13T17:00:00+03:00","prayer":null,"offsetMinutes":null,
            "location":{"latitude":24.9,"longitude":46.5,"radius":400,"name":"الاستراحة","trigger":"arrive",
              "placeId":"3f2b8c1e-0a4d-4e6f-9b7a-1c2d3e4f5a6b"},
            "firedAt":5000,"createdAt":1000,"updatedAt":5000}},
          {"entity":"place","id":"3f2b8c1e-0a4d-4e6f-9b7a-1c2d3e4f5a6b","op":"delete"}
        ],"cursor":9,"hasMore":false}
        """
        let page = try JSONDecoder().decode(PullResponse.self, from: Data(json.utf8))
        guard case .place(let place)? = page.changes[0].record else {
            Issue.record("expected a place")
            return
        }
        #expect(place.name == "الاستراحة")
        #expect(place.radius == 400)
        guard case .reminder(let reminder)? = page.changes[1].record else {
            Issue.record("expected a reminder")
            return
        }
        #expect(reminder.firedAt == 5000)
        #expect(reminder.location?.placeId == place.id)
        #expect(page.changes[2].entity == .place)
        #expect(page.changes[2].record == nil)
    }

    @Test func pushesPlacesAndLeavesOutAnUnsetFiredAt() throws {
        let place = Mutation.upsert(.place(home))
        let placeData = try JSONEncoder().encode(place)
        let placeJSON = try #require(try JSONSerialization.jsonObject(with: placeData) as? [String: Any])
        #expect(placeJSON["entity"] as? String == "place")
        #expect(place.id == home.id)

        let reminder = ReminderRecord(taskId: UUID(), kind: .location, location: .init(place: home, trigger: .arrive))
        let data = try JSONEncoder().encode(Mutation.upsert(.reminder(reminder)))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let body = try #require(object["data"] as? [String: Any])
        // Left out, the server keeps what another device set.
        #expect(body["firedAt"] == nil)
        let location = try #require(body["location"] as? [String: Any])
        #expect((location["placeId"] as? String).flatMap(UUID.init(uuidString:)) == home.id)
    }

    // MARK: Whichever comes first

    @Test func firingFollowsTheTimeAndTheMark() {
        let later = now.addingTimeInterval(3600)
        let earlier = now.addingTimeInterval(-3600)
        #expect(ReminderFiring(at: nil, firedAt: nil, now: now) == .everyVisit)
        #expect(ReminderFiring(at: later, firedAt: nil, now: now) == .waiting(until: later))
        #expect(ReminderFiring(at: earlier, firedAt: nil, now: now) == .firedAtTime(earlier))
        #expect(ReminderFiring(at: later, firedAt: 1_000, now: now) == .firedAtPlace(Date(timeIntervalSince1970: 1)))
        // The place's mark wins even once the time has passed.
        #expect(ReminderFiring(at: earlier, firedAt: 1_000, now: now) == .firedAtPlace(Date(timeIntervalSince1970: 1)))
        #expect(ReminderFiring.everyVisit.watchesPlace)
        #expect(ReminderFiring.waiting(until: later).watchesPlace)
        #expect(!ReminderFiring.firedAtTime(earlier).watchesPlace)
    }

    struct DecisionCase: Sendable, CustomTestStringConvertible {
        let name: String
        let event: PlaceEvent
        let trigger: ReminderRecord.Location.Trigger
        let taskIsDone: Bool
        let firing: ReminderFiring
        let minutesSinceLast: Double?
        let expected: LocationDecision
        var testDescription: String { name }
    }

    static let soon = Date(timeIntervalSince1970: 1_791_885_600)
    static let decisions: [DecisionCase] = [
        .init(name: "arrived before the time", event: .entered, trigger: .arrive, taskIsDone: false,
              firing: .waiting(until: soon), minutesSinceLast: nil, expected: .notify),
        .init(name: "a place alone, every visit", event: .entered, trigger: .arrive, taskIsDone: false,
              firing: .everyVisit, minutesSinceLast: 180, expected: .notify),
        .init(name: "left before the time", event: .exited, trigger: .leave, taskIsDone: false,
              firing: .waiting(until: soon), minutesSinceLast: nil, expected: .notify),
        .init(name: "the time came first", event: .entered, trigger: .arrive, taskIsDone: false,
              firing: .firedAtTime(soon), minutesSinceLast: nil, expected: .skip(.alreadyFired)),
        .init(name: "another device arrived first", event: .entered, trigger: .arrive, taskIsDone: false,
              firing: .firedAtPlace(soon), minutesSinceLast: nil, expected: .skip(.alreadyFired)),
        .init(name: "the task is done", event: .entered, trigger: .arrive, taskIsDone: true,
              firing: .everyVisit, minutesSinceLast: nil, expected: .skip(.taskDone)),
        .init(name: "leaving an arrival place", event: .exited, trigger: .arrive, taskIsDone: false,
              firing: .everyVisit, minutesSinceLast: nil, expected: .skip(.otherDirection)),
        .init(name: "jitter at the edge", event: .entered, trigger: .arrive, taskIsDone: false,
              firing: .everyVisit, minutesSinceLast: 5, expected: .skip(.tooSoon)),
    ]

    @Test(arguments: decisions)
    func decidesWhetherToNotify(_ c: DecisionCase) {
        let last = c.minutesSinceLast.map { now.addingTimeInterval(-$0 * 60) }
        let decision = LocationDecision.decide(event: c.event, trigger: c.trigger, taskIsDone: c.taskIsDone,
                                               firing: c.firing, lastNotified: last, now: now)
        #expect(decision == c.expected)
    }

    // MARK: Planning

    @Test func schedulesTheTimeUntilThePlaceComesFirst() {
        let task = PlannerTask(id: UUID(), title: "شراء الخبز")
        let fire = now.addingTimeInterval(5 * 3600)
        let waiting = PlannerReminder(id: UUID(), taskId: task.id, kind: .location, at: iso(fire),
                                      location: .init(place: home, trigger: .arrive))
        var planned = ReminderPlanner.plan(tasks: [task], reminders: [waiting], schedule: nil, now: now, formatter: formatter)
        #expect(planned.map(\.id) == ["reminder-\(waiting.id.uuidString)"])
        #expect(planned.first?.body == "حان وقتها قبل وصولك إلى البيت")
        #expect(abs((planned.first?.date ?? .distantPast).timeIntervalSince(fire)) < 1)

        var arrived = waiting
        arrived.firedAt = Milliseconds(now.timeIntervalSince1970 * 1000)
        planned = ReminderPlanner.plan(tasks: [task], reminders: [arrived], schedule: nil, now: now, formatter: formatter)
        #expect(planned.isEmpty)
    }

    @Test func watchesEachPlaceOnceForAllItsReminders() {
        let bread = PlannerTask(id: UUID(), title: "شراء الخبز", dueDay: "2026-10-14")
        let call = PlannerTask(id: UUID(), title: "الاتصال بأمي", dueDay: "2026-10-13")
        let done = PlannerTask(id: UUID(), title: "منجزة", isDone: true)
        let reminders = [
            PlannerReminder(id: UUID(), taskId: bread.id, kind: .location, location: .init(place: home, trigger: .arrive)),
            PlannerReminder(id: UUID(), taskId: call.id, kind: .location, location: .init(place: home, trigger: .leave)),
            // The time already came first: no longer watched.
            PlannerReminder(id: UUID(), taskId: call.id, kind: .location, at: iso(now.addingTimeInterval(-60)),
                            location: .init(place: office, trigger: .arrive)),
            PlannerReminder(id: UUID(), taskId: done.id, kind: .location, location: .init(place: office, trigger: .arrive)),
        ]
        let watched = PlaceWatchPlanner.plan(tasks: [bread, call, done], reminders: reminders, now: now)
        #expect(watched.count == 1)
        #expect(watched[0].id == "place-\(home.id.uuidString)")
        #expect(Set(watched[0].reminderIds) == Set(reminders.prefix(2).map(\.id)))
        #expect(watched[0].radius == 200)
    }

    @Test func anUnsavedPlaceIsWatchedOnItsOwn() {
        let task = PlannerTask(id: UUID(), title: "شراء الخبز")
        let spot = ReminderRecord.Location(latitude: 24.8, longitude: 46.7, radius: 150, name: nil, trigger: .arrive)
        let reminder = PlannerReminder(id: UUID(), taskId: task.id, kind: .location, location: spot)
        let watched = PlaceWatchPlanner.plan(tasks: [task], reminders: [reminder], now: now)
        #expect(watched.map(\.id) == ["loc-\(reminder.id.uuidString)"])
    }

    @Test func keepsTheTwentySoonestPlaces() {
        var tasks: [PlannerTask] = []
        var reminders: [PlannerReminder] = []
        for day in 1...25 {
            let task = PlannerTask(id: UUID(), title: "مهمة", dueDay: String(format: "2026-10-%02d", day))
            let place = PlaceRecord(name: "مكان", latitude: 24 + Double(day) / 100, longitude: 46, radius: 200)
            tasks.append(task)
            reminders.append(PlannerReminder(id: UUID(), taskId: task.id, kind: .location,
                                             location: .init(place: place, trigger: .arrive)))
        }
        let watched = PlaceWatchPlanner.plan(tasks: tasks, reminders: reminders, now: now)
        #expect(watched.count == PlaceWatchPlanner.maxPlaces)
        #expect(watched.first?.reminderIds == [reminders[0].id])
        #expect(!watched.contains { $0.reminderIds == [reminders[24].id] })
    }

    @Test func withoutAlwaysAFiredReminderIsNoLongerWatched() {
        let task = PlannerTask(id: UUID(), title: "شراء الخبز")
        let reminder = PlannerReminder(id: UUID(), taskId: task.id, kind: .location, at: iso(now.addingTimeInterval(-60)),
                                       location: .init(place: home, trigger: .arrive))
        #expect(LocationReminderPlanner.plan(tasks: [task], reminders: [reminder], now: now).isEmpty)
    }

    // MARK: Text

    @Test func describesTheReminder() {
        let arrive = ReminderRecord.Location(place: home, trigger: .arrive)
        let leave = ReminderRecord.Location(place: office, trigger: .leave)
        #expect(LocationReminderPlanner.reminderText(arrive, firing: .everyVisit, formatter: formatter, now: now)
            == "عند الوصول إلى البيت")
        let waiting = LocationReminderPlanner.reminderText(leave, firing: .waiting(until: now.addingTimeInterval(5 * 3600)),
                                                           formatter: formatter, now: now)
        #expect(waiting.hasPrefix("عند مغادرة المكتب أو اليوم "))
        #expect(waiting.hasSuffix("، أيهما أسبق"))
        #expect(LocationReminderPlanner.reminderText(arrive, firing: .firedAtPlace(now), formatter: formatter, now: now)
            .hasPrefix("عند الوصول إلى البيت: وصلت اليوم "))
        #expect(LocationReminderPlanner.timeCameFirstBody(leave) == "حان وقتها قبل مغادرتك المكتب")
    }

    // MARK: Spoken

    @Test func readsThePlaceInASpokenSentence() throws {
        let json = """
        {"title":"شراء الخبز","dueDate":"2026-10-13","dueTime":"17:00","priority":"none","tags":[],
         "place":{"placeId":"\(home.id.uuidString.lowercased())","name":"البيت","trigger":"arrive"}}
        """
        let suggestion = try JSONDecoder().decode(TaskSuggestion.self, from: Data(json.utf8))
        #expect(suggestion.place == .init(placeId: home.id, name: "البيت", trigger: .arrive))

        let spoken = SpokenTask(suggestion: suggestion)
        #expect(spoken.placeReminderAt(today: "2026-10-13", timeZone: riyadh) == "2026-10-13T17:00:00+03:00")
        // A place without a clock time reminds at the place alone.
        var placeOnly = suggestion
        placeOnly.dueTime = nil
        #expect(SpokenTask(suggestion: placeOnly).placeReminderAt(today: "2026-10-13", timeZone: riyadh) == nil)
        var timeOnly = suggestion
        timeOnly.place = nil
        #expect(SpokenTask(suggestion: timeOnly).placeReminderAt(today: "2026-10-13", timeZone: riyadh) == nil)

        // An unsaved place comes by name; one the app cannot read is dropped, not the suggestion.
        let unsaved = try JSONDecoder().decode(TaskSuggestion.self, from: Data(
            #"{"title":"إطفاء المكيف","priority":"none","tags":[],"place":{"name":"الاستراحة","trigger":"leave"}}"#.utf8))
        #expect(unsaved.place == .init(name: "الاستراحة", trigger: .leave))
        let odd = try JSONDecoder().decode(TaskSuggestion.self, from: Data(
            #"{"title":"مهمة","priority":"none","tags":[],"place":{"name":"س","trigger":"near"}}"#.utf8))
        #expect(odd.place == nil)
    }
}
