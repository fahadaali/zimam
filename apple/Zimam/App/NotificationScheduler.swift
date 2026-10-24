#if os(iOS)
import CoreLocation
#endif
import Foundation
import Observation
import os
import SwiftData
import UserNotifications
import ZimamKit

/// Keeps the pending local notifications in step with the tasks, reminders and prayer alerts.
/// iOS allows 64 per app, so it schedules the soonest ones (see `ReminderPlanner`)
/// and recomputes the window on launch, after each sync that changed something and after each
/// local edit.
/// The server sends what lies beyond the window over APNs. Adhan and iqama alerts
/// (`PrayerAlertPlanner`) take up to 20 of the 60 for the next two days; the app renews
/// them whenever it runs, and in the background (`BackgroundRefresh`).
///
/// Location reminders («تذكير بالموقع») fire on iPhone and iPad, in one of two ways:
/// - With location «دائماً», `PlaceMonitor` watches each place (`PlaceWatchPlanner`, up to 20) and
///   the app shows the notification when woken, so a place and a time on one reminder fire once,
///   at whichever comes first. They take nothing from the 60 slots.
/// - With location only while using the app, they are `UNLocationNotificationTrigger`s: the system
///   watches each place and shows the notification itself without waking the app. They take up to
///   `LocationReminderPlanner.maxRegions` of the 60 slots, and a place and a time on one reminder
///   may both arrive.
/// A place alone repeats on every arrival or exit until the task is done. The Mac watches no
/// places; a reminder's time still reaches it. The server pushes only that time, never a place.
@MainActor
@Observable
final class NotificationScheduler {
    private(set) var status: UNAuthorizationStatus = .notDetermined
    /// The location reminders the device is watching now; the others are over the budget
    /// or cannot fire here (see `LocationProvider.canWatchPlaces`).
    private(set) var watchedPlaces: Set<UUID> = []

    private static let logger = Logger(subsystem: "app.zimam.ios", category: "notifications")

    private let context: ModelContext
    private let sync: SyncEngine
    private let session: SessionStore
    private let location: LocationProvider
    private let places: PlaceMonitor
    private let delegate = NotificationDelegate()
    @ObservationIgnored private var pending: Task<Void, Never>?

    static let categoryId = "zimam.task"
    static let prayerCategoryId = "zimam.prayer"
    static let doneAction = "zimam.task.done"
    static let snoozeAction = "zimam.task.snooze"
    private static let askedKey = "notifications.asked"

    init(context: ModelContext, sync: SyncEngine, session: SessionStore, location: LocationProvider, places: PlaceMonitor) {
        self.context = context
        self.sync = sync
        self.session = session
        self.location = location
        self.places = places

        let center = UNUserNotificationCenter.current()
        let done = UNNotificationAction(identifier: Self.doneAction, title: "إنجاز", options: [])
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "تأجيل ساعة", options: [])
        let category = UNNotificationCategory(identifier: Self.categoryId, actions: [done, snooze],
                                              intentIdentifiers: [], options: [])
        let prayer = UNNotificationCategory(identifier: Self.prayerCategoryId, actions: [], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category, prayer])
        delegate.onAction = { [weak self] action, taskId in
            await self?.handle(action: action, taskId: taskId)
        }
        center.delegate = delegate
        // Location reminders start or stop with the location permission.
        location.onAuthorizationChange = { [weak self] in
            self?.reschedule()
        }
    }

    var isEnabled: Bool { status == .authorized || status == .provisional }
    var isDenied: Bool { status == .denied }
    /// Quiet delivery or not asked yet: a full prompt may still be shown.
    var canAskForAlerts: Bool { status == .notDetermined || status == .provisional }

    /// The status in words, for settings.
    var statusText: String {
        switch status {
        case .authorized: "مفعّلة"
        case .provisional: "تصل بهدوء إلى مركز الإشعارات"
        case .denied: "متوقفة. فعّلها من إعدادات النظام."
        case .notDetermined: "لم تُفعَّل بعد"
        default: "مفعّلة مؤقتاً"
        }
    }

    /// On launch: asks once for quiet (provisional) delivery, which needs no prompt,
    /// then schedules.
    func prepare() async {
        if !UserDefaults.standard.bool(forKey: Self.askedKey) {
            UserDefaults.standard.set(true, forKey: Self.askedKey)
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .provisional])
        }
        await refreshStatus()
        reschedule()
    }

    /// Asks for full alerts (the system prompt). Used from settings and when the
    /// user adds a reminder while notifications are quiet or undecided.
    func requestFullAuthorization() async {
        guard canAskForAlerts else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refreshStatus()
        reschedule()
    }

    func refreshStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        status = settings.authorizationStatus
    }

    /// Recomputes the pending notifications soon, folding bursts of edits into one pass.
    func reschedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.apply()
        }
    }

    /// Recomputes now, for a background wake that may end at any moment (`BackgroundRefresh`).
    func rescheduleNow() async {
        pending?.cancel()
        await apply()
    }

    private func apply() async {
        let center = UNUserNotificationCenter.current()
        await refreshStatus()
        // A pass replaced while suspended stops here: its snapshot is stale, and removing by it
        // could take back a reminder the newer pass just added (a snooze, for one).
        guard !Task.isCancelled else { return }
        guard isEnabled, session.isSignedIn else {
            center.removeAllPendingNotificationRequests()
            watchedPlaces = []
            self.places.watch([])
            return
        }

        let (times, prayers, places, monitored) = plan()
        watchedPlaces = Set(places.map(\.reminderId)).union(monitored.flatMap(\.reminderIds))
        // With «دائماً» the app watches places itself; otherwise this stops it.
        self.places.watch(monitored)
        // Everything is replaced except places already watched as planned: registering a place
        // again while the device is inside it could fire it again.
        let existing = await center.pendingNotificationRequests()
        guard !Task.isCancelled else { return }
        let kept = Self.alreadyWatched(existing, places: places)
        center.removePendingNotificationRequests(withIdentifiers: existing.map(\.identifier).filter { !kept.contains($0) })
        #if os(iOS)
        for place in places where !kept.contains(place.id) {
            guard !Task.isCancelled else { return }
            await add(Self.request(for: place), to: center)
        }
        #endif
        for item in times {
            guard !Task.isCancelled else { return }
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default
            content.categoryIdentifier = Self.categoryId
            content.threadIdentifier = item.taskId.uuidString
            content.userInfo = ["taskId": item.taskId.uuidString]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, item.date.timeIntervalSinceNow), repeats: false)
            let request = UNNotificationRequest(identifier: item.id, content: content, trigger: trigger)
            await add(request, to: center)
        }
        for alert in prayers {
            guard !Task.isCancelled else { return }
            await add(Self.request(for: alert), to: center)
        }
    }

    /// An adhan or iqama alert: no task, so none of the task actions. The adhan sound comes later;
    /// for now the system sound.
    private static func request(for alert: PlannedPrayerAlert) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.categoryIdentifier = prayerCategoryId
        content.threadIdentifier = prayerCategoryId
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, alert.date.timeIntervalSinceNow), repeats: false)
        return UNNotificationRequest(identifier: alert.id, content: content, trigger: trigger)
    }

    /// Adds one reminder. A failure is logged, not swallowed: the reminder would silently never
    /// fire. The next pass (after the next edit or sync, or on return to the app) tries again.
    private func add(_ request: UNNotificationRequest, to center: UNUserNotificationCenter) async {
        do {
            try await center.add(request)
        } catch {
            Self.logger.error("Scheduling a reminder failed: \(error.localizedDescription)")
        }
    }

    /// The ids of pending requests that already watch a planned place as planned.
    private static func alreadyWatched(_ existing: [UNNotificationRequest], places: [PlannedRegion]) -> Set<String> {
        #if os(iOS)
        let wanted = Dictionary(places.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var kept = Set<String>()
        for request in existing {
            if let place = wanted[request.identifier], Self.request(request, watches: place) {
                kept.insert(request.identifier)
            }
        }
        return kept
        #else
        return []
        #endif
    }

    #if os(iOS)
    /// A notification on entering or leaving the place, with the same «إنجاز» and «تأجيل ساعة»
    /// as time reminders. It repeats: it fires on every arrival (or exit) until the task is done
    /// and the next reschedule drops it.
    private static func request(for place: PlannedRegion) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.body = place.body
        content.sound = .default
        content.categoryIdentifier = categoryId
        content.threadIdentifier = place.taskId.uuidString
        content.userInfo = ["taskId": place.taskId.uuidString]
        let center = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
        let region = CLCircularRegion(center: center, radius: place.radius, identifier: place.id)
        region.notifyOnEntry = place.onArrive
        region.notifyOnExit = !place.onArrive
        let trigger = UNLocationNotificationTrigger(region: region, repeats: true)
        return UNNotificationRequest(identifier: place.id, content: content, trigger: trigger)
    }

    /// Whether a pending request already watches this place with this text.
    private static func request(_ request: UNNotificationRequest, watches place: PlannedRegion) -> Bool {
        guard let trigger = request.trigger as? UNLocationNotificationTrigger,
              let region = trigger.region as? CLCircularRegion else { return false }
        return request.content.body == place.body
            && region.center.latitude == place.latitude
            && region.center.longitude == place.longitude
            && region.radius == place.radius
            && region.notifyOnEntry == place.onArrive
            && region.notifyOnExit == !place.onArrive
    }
    #endif

    /// The time window; the places the system watches without «دائماً», which come out of the
    /// same budget; and the places the app watches itself with it.
    private func plan() -> (times: [PlannedNotification], prayers: [PlannedPrayerAlert], places: [PlannedRegion],
                            monitored: [WatchedPlace]) {
        let now = Date()
        let tasks = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.pendingDelete }))) ?? []
        let reminders = (try? context.fetch(FetchDescriptor<ReminderItem>(predicate: #Predicate { !$0.pendingDelete }))) ?? []
        let plannerTasks = tasks.map { task in
            PlannerTask(id: task.id, title: task.title, dueDay: task.dueDate, dueTime: task.dueTime, duePrayer: task.duePrayer,
                        duePrayerOffset: task.duePrayerOffset, isDone: task.isDone)
        }
        let plannerReminders = reminders.map { reminder in
            PlannerReminder(id: reminder.id, taskId: reminder.taskId,
                            kind: ReminderRecord.Kind(rawValue: reminder.kindRaw) ?? .time, at: reminder.at,
                            prayer: reminder.prayerRaw.flatMap(Prayer.init(rawValue:)), offsetMinutes: reminder.offsetMinutes,
                            location: reminder.record.location, firedAt: reminder.firedAt)
        }
        let near = location.coordinate.map {
            LocationReminderPlanner.Point(latitude: $0.latitude, longitude: $0.longitude)
        }
        var places: [PlannedRegion] = []
        var monitored: [WatchedPlace] = []
        if location.canMonitorPlaces {
            monitored = PlaceWatchPlanner.plan(tasks: plannerTasks, reminders: plannerReminders, near: near, now: now)
        } else if location.canWatchPlaces {
            places = LocationReminderPlanner.plan(tasks: plannerTasks, reminders: plannerReminders, near: near, now: now)
        }
        let settings = session.user?.settings
        let formatter = DualDateFormatter(primary: settings?.calendar ?? .hijri, locale: ZimamLocale.current)
        let schedule = location.schedule(settings)
        // Adhan and iqama alerts first (at most `PrayerAlertPlanner.limit`); the reminders get the rest.
        let prayers = PrayerAlertPlanner.plan(settings: settings?.prayerAlerts ?? PrayerAlertSettings(), schedule: schedule,
                                              now: now)
        let times = ReminderPlanner.plan(tasks: plannerTasks, reminders: plannerReminders, schedule: schedule,
                                         now: now, formatter: formatter,
                                         limit: LocationReminderPlanner.timeLimit(
                                             reserving: places.count, total: ReminderPlanner.defaultLimit - prayers.count))
        return (times, prayers, places, monitored)
    }

    /// «إنجاز» completes the task; «تأجيل ساعة» adds a one-off reminder an hour from now.
    /// Both sync right away, since the app may be in the background.
    private func handle(action: String, taskId: UUID?) async {
        guard action == Self.doneAction || action == Self.snoozeAction, let taskId else { return }
        // A reminder pushed by the server may name a task this device has not pulled yet.
        if fetchTask(taskId) == nil { await sync.sync() }
        guard let task = fetchTask(taskId) else { return }
        let store = Store(context: context, sync: sync)
        switch action {
        case Self.doneAction:
            if !task.isDone { store.toggleDone(task) }
            await removeDelivered(taskId: taskId)
        case Self.snoozeAction:
            store.addTimeReminder(to: task.id, at: Date().addingTimeInterval(3600))
        default:
            return
        }
        await sync.sync()
        // Reschedule now, not after the debounce: the app may be suspended as soon as the action
        // finishes, and the snoozed reminder must be pending (and a done task's ones gone) by then.
        pending?.cancel()
        await apply()
    }

    /// Clears the task's other reminders from Notification Center once it is done.
    private func removeDelivered(taskId: UUID) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let ids = delivered
            // Pushed reminders carry the server's lowercase id, so compare as UUIDs.
            .filter { ($0.request.content.userInfo["taskId"] as? String).flatMap(UUID.init(uuidString:)) == taskId }
            .map(\.request.identifier)
        if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
    }

    private func fetchTask(_ id: UUID) -> TaskItem? {
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

/// The notification center's delegate, kept apart so the observable scheduler stays a
/// plain class. Set at launch so actions work when the app starts in the background.
/// The center may call it off the main thread, so it is not tied to the main actor (a call
/// from another thread would stop the app); `onAction` hops there. Set once, before use.
nonisolated private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onAction: (@MainActor (String, UUID?) async -> Void)?

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let taskId = (response.notification.request.content.userInfo["taskId"] as? String).flatMap(UUID.init(uuidString:))
        await onAction?(action, taskId)
    }

    /// Shows reminders while the app is open too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
