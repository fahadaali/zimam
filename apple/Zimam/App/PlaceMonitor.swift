import CoreLocation
import Foundation
import os
import SwiftData
import UserNotifications
import ZimamKit

/// Watches the places of location reminders itself when Zimam may use location «دائماً», so a
/// place and a time on one reminder can take each other back («أيهما أسبق»).
///
/// Without «دائماً» the system watches places for the app (`UNLocationNotificationTrigger` in
/// `NotificationScheduler`) and never wakes it, so it cannot cancel anything. With it, `CLMonitor`
/// wakes the app on every crossing, even when it is closed, and the app decides
/// (`LocationDecision`): it shows the notification, takes back the pending time
/// (`reminder-<id>`), and marks the reminder fired (`Store.markFired`), which syncs so other
/// devices and the server's push skip the time. When the time comes first nothing wakes the app:
/// every device sees the time has passed (`ReminderFiring`) and stops watching.
///
/// One region per place (`PlaceWatchPlanner`): «البيت» is watched once for every reminder there.
/// The device's position never leaves it; only the reminder's fired time syncs.
@MainActor
final class PlaceMonitor {
    private let context: ModelContext
    private let sync: SyncEngine
    private var monitor: CLMonitor?
    private var listening: Task<Void, Never>?
    private var updating: Task<Void, Never>?
    /// The places to watch, kept until the monitor is ready.
    private var wanted: [WatchedPlace] = []

    private static let monitorName = "zimam.places"
    /// Inside or outside, per region id: the app is relaunched for each crossing, so this lives
    /// in defaults. A crossing is a change from the last known side; the first reading of a new
    /// region only records it, so registering a place while there does not remind.
    private static let sidesKey = "places.sides"
    /// When each reminder last notified (seconds since 1970), for `LocationDecision.quietPeriod`.
    private static let notifiedKey = "places.notified"
    private static let logger = Logger(subsystem: "app.zimam.ios", category: "places")

    init(context: ModelContext, sync: SyncEngine) {
        self.context = context
        self.sync = sync
    }

    /// Opens the monitor and listens for crossings. Called at launch, so the crossing that woke
    /// the app in the background is delivered.
    func start() {
        #if os(iOS)
        guard listening == nil else { return }
        listening = Task { [weak self] in
            let monitor = await CLMonitor(PlaceMonitor.monitorName)
            guard let self else { return }
            self.monitor = monitor
            self.watch(self.wanted)
            do {
                for try await event in await monitor.events {
                    await self.handle(identifier: event.identifier, state: event.state)
                }
            } catch {
                PlaceMonitor.logger.error("Watching places stopped: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
    }

    /// Watches exactly these places: new ones are added, moved or resized ones replaced, and the
    /// rest removed. An empty list stops watching (no «دائماً», notifications off, signed out).
    func watch(_ places: [WatchedPlace]) {
        wanted = places
        guard let monitor else { return }
        updating?.cancel()
        updating = Task { [weak self] in
            await self?.reconcile(monitor, with: places)
        }
    }

    private func reconcile(_ monitor: CLMonitor, with places: [WatchedPlace]) async {
        let wanted = Dictionary(places.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in await monitor.identifiers {
            guard !Task.isCancelled else { return }
            if let place = wanted[id], let record = await monitor.record(for: id),
               let condition = record.condition as? CLMonitor.CircularGeographicCondition,
               condition.center.latitude == place.latitude, condition.center.longitude == place.longitude,
               condition.radius == place.radius {
                continue
            }
            await monitor.remove(id)
            forgetSide(of: id)
        }
        guard !Task.isCancelled else { return }
        let watched = Set(await monitor.identifiers)
        for place in places where !watched.contains(place.id) {
            guard !Task.isCancelled else { return }
            let center = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
            await monitor.add(CLMonitor.CircularGeographicCondition(center: center, radius: place.radius), identifier: place.id)
        }
    }

    // MARK: Crossings

    private enum Side: String {
        case inside, outside
    }

    private func handle(identifier: String, state: CLMonitor.Event.State) async {
        let side: Side
        switch state {
        case .satisfied: side = .inside
        case .unsatisfied: side = .outside
        default: return
        }
        var sides = UserDefaults.standard.dictionary(forKey: Self.sidesKey) as? [String: String] ?? [:]
        let previous = sides[identifier].flatMap(Side.init(rawValue:))
        sides[identifier] = side.rawValue
        UserDefaults.standard.set(sides, forKey: Self.sidesKey)
        guard let previous, previous != side else { return }
        await crossed(identifier, event: side == .inside ? .entered : .exited)
    }

    private func forgetSide(of identifier: String) {
        var sides = UserDefaults.standard.dictionary(forKey: Self.sidesKey) as? [String: String] ?? [:]
        sides[identifier] = nil
        UserDefaults.standard.set(sides, forKey: Self.sidesKey)
    }

    /// Decides for every reminder at the place, synchronously, and records each one that will
    /// notify before anything awaits: a second crossing moments later then finds it quiet.
    private func crossed(_ identifier: String, event: PlaceEvent) async {
        let now = Date()
        var notified = UserDefaults.standard.dictionary(forKey: Self.notifiedKey) as? [String: Double] ?? [:]
        var due: [(reminder: ReminderItem, task: TaskItem, place: ReminderRecord.Location)] = []
        for reminder in reminders(watchedBy: identifier) {
            guard let place = reminder.record.location, let task = fetchTask(reminder.taskId), !task.pendingDelete else { continue }
            let last = notified[reminder.id.uuidString].map(Date.init(timeIntervalSince1970:))
            let decision = LocationDecision.decide(event: event, trigger: place.trigger, taskIsDone: task.isDone,
                                                   firing: reminder.firing(now: now), lastNotified: last, now: now)
            guard decision == .notify else { continue }
            notified[reminder.id.uuidString] = now.timeIntervalSince1970
            due.append((reminder, task, place))
        }
        // Old entries go after a day; the quiet period is half an hour.
        notified = notified.filter { now.timeIntervalSince1970 - $0.value < 86_400 }
        UserDefaults.standard.set(notified, forKey: Self.notifiedKey)
        guard !due.isEmpty else { return }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let store = Store(context: context, sync: sync)
        for (reminder, task, place) in due {
            // The time loses: take it back before showing the place, then mark the race won.
            center.removePendingNotificationRequests(withIdentifiers: ["reminder-\(reminder.id.uuidString)"])
            try? await center.add(Self.request(reminderId: reminder.id, taskId: task.id, place: place, taskTitle: task.title))
            if case .waiting = reminder.firing(now: now) { store.markFired(reminder, at: now) }
        }
        Self.logger.info("Reminded at a place for \(due.count, privacy: .public) reminders")
        // The app may be suspended again within seconds: send the mark now.
        await sync.sync()
    }

    /// «وصلت إلى البيت: شراء الخبز», with «إنجاز» and «تأجيل ساعة» like every reminder.
    private static func request(reminderId: UUID, taskId: UUID, place: ReminderRecord.Location,
                                taskTitle: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.body = LocationReminderPlanner.body(placeName: place.name, trigger: place.trigger, taskTitle: taskTitle)
        content.sound = .default
        content.categoryIdentifier = NotificationScheduler.categoryId
        content.threadIdentifier = taskId.uuidString
        content.userInfo = ["taskId": taskId.uuidString]
        return UNNotificationRequest(identifier: LocationReminderPlanner.regionId(for: reminderId), content: content, trigger: nil)
    }

    // MARK: Data

    /// The location reminders this region serves, read fresh: the app may have just been
    /// relaunched for this crossing.
    private func reminders(watchedBy identifier: String) -> [ReminderItem] {
        let kind = ReminderRecord.Kind.location.rawValue
        let all = (try? context.fetch(FetchDescriptor<ReminderItem>(
            predicate: #Predicate { $0.kindRaw == kind && !$0.pendingDelete }))) ?? []
        return all.filter { reminder in
            guard let place = reminder.record.location else { return false }
            return PlaceWatchPlanner.conditionId(for: place, reminderId: reminder.id) == identifier
        }
    }

    private func fetchTask(_ id: UUID) -> TaskItem? {
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
