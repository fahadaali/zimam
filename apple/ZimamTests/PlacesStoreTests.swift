import Foundation
import SwiftData
import Testing
import ZimamKit
@testable import Zimam

/// Saved places («أماكني») and location reminders through `Store`, on an in-memory store as in
/// `StoreTests`.
@MainActor
struct PlacesStoreTests {
    let container: ModelContainer
    let store: Store

    init() throws {
        let schema = Schema(zimamModelTypes)
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        store = Store(context: ModelContext(container), sync: nil)
    }

    @Test func savesAPlaceTrimmedAndWithinTheServersRadius() {
        let place = store.addPlace(name: "  البيت ", latitude: 24.7, longitude: 46.6, radius: 20_000)
        #expect(place.name == "البيت")
        #expect(place.radius == LocationReminderPlanner.serverRadiusRange.upperBound)
        #expect(place.isDirty)
    }

    @Test func movingAPlaceMovesItsRemindersButNoOthers() throws {
        let home = store.addPlace(name: "البيت", latitude: 24.7, longitude: 46.6, radius: 200)
        let task = store.addTask(title: "شراء الخبز")
        let linked = store.addLocationReminder(to: task.id, place: .init(place: home.record, trigger: .arrive))
        let other = store.addLocationReminder(to: task.id, place: .init(latitude: 21.5, longitude: 39.2, radius: 300,
                                                                        name: "المكتب", trigger: .leave))
        linked.isDirty = false
        let version = home.updatedAt

        store.updatePlace(home, name: "بيتي", latitude: 24.8, longitude: 46.7, radius: 400)

        let moved = try #require(linked.record.location)
        #expect(moved.latitude == 24.8 && moved.longitude == 46.7 && moved.radius == 400 && moved.name == "بيتي")
        #expect(moved.placeId == home.id)
        // The server rewrites the copies too, so the reminder itself is not sent again.
        #expect(!linked.isDirty)
        #expect(home.updatedAt > version)
        #expect(other.record.location?.name == "المكتب")
        #expect(store.reminders(at: home.id).map(\.id) == [linked.id])
    }

    @Test func deletingAPlaceKeepsItsRemindersWhereItWas() {
        let home = store.addPlace(name: "البيت", latitude: 24.7, longitude: 46.6, radius: 200)
        let task = store.addTask(title: "شراء الخبز")
        let reminder = store.addLocationReminder(to: task.id, place: .init(place: home.record, trigger: .arrive))

        store.deletePlace(home)

        #expect(home.pendingDelete)
        #expect(reminder.record.location?.placeId == nil)
        #expect(reminder.record.location?.latitude == 24.7)
        #expect(!reminder.pendingDelete)
    }

    @Test func aPlaceWithATimeWaitsThenFiresOnce() {
        let home = store.addPlace(name: "البيت", latitude: 24.7, longitude: 46.6, radius: 200)
        let task = store.addTask(title: "شراء الخبز")
        let at = Date().addingTimeInterval(3600)
        let reminder = store.addLocationReminder(to: task.id, place: .init(place: home.record, trigger: .arrive), at: at)
        guard case .waiting = reminder.firing() else {
            Issue.record("expected the reminder to wait for the place or the time")
            return
        }

        let arrived = Date()
        store.markFired(reminder, at: arrived)
        #expect(reminder.firedAt == Milliseconds(arrived.timeIntervalSince1970 * 1000))
        #expect(!reminder.firing().watchesPlace)
        // Marking again keeps the first arrival.
        store.markFired(reminder, at: arrived.addingTimeInterval(60))
        #expect(reminder.firedAt == Milliseconds(arrived.timeIntervalSince1970 * 1000))
    }
}
