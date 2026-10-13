import Foundation
import Observation
import SwiftData
import UserNotifications
import ZimamKit

/// Keeps the pending local notifications in step with the tasks and reminders.
/// iOS allows 64 per app, so it schedules the soonest ones (see `ReminderPlanner`)
/// and recomputes the window on launch, after each sync and after each local edit.
/// The server sends what lies beyond the window over APNs.
@MainActor
@Observable
final class NotificationScheduler {
    private(set) var status: UNAuthorizationStatus = .notDetermined

    private let context: ModelContext
    private let sync: SyncEngine
    private let session: SessionStore
    private let location: LocationProvider
    private let delegate = NotificationDelegate()
    @ObservationIgnored private var pending: Task<Void, Never>?

    static let categoryId = "zimam.task"
    static let doneAction = "zimam.task.done"
    static let snoozeAction = "zimam.task.snooze"
    private static let askedKey = "notifications.asked"

    init(context: ModelContext, sync: SyncEngine, session: SessionStore, location: LocationProvider) {
        self.context = context
        self.sync = sync
        self.session = session
        self.location = location

        let center = UNUserNotificationCenter.current()
        let done = UNNotificationAction(identifier: Self.doneAction, title: "إنجاز", options: [])
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "تأجيل ساعة", options: [])
        let category = UNNotificationCategory(identifier: Self.categoryId, actions: [done, snooze],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
        delegate.onAction = { [weak self] action, taskId in
            await self?.handle(action: action, taskId: taskId)
        }
        center.delegate = delegate
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

    private func apply() async {
        let center = UNUserNotificationCenter.current()
        await refreshStatus()
        center.removeAllPendingNotificationRequests()
        guard isEnabled, session.isSignedIn else { return }

        for item in plan() {
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
            try? await center.add(request)
        }
    }

    private func plan() -> [PlannedNotification] {
        let tasks = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.pendingDelete }))) ?? []
        let reminders = (try? context.fetch(FetchDescriptor<ReminderItem>(predicate: #Predicate { !$0.pendingDelete }))) ?? []
        let plannerTasks = tasks.map { task in
            PlannerTask(id: task.id, title: task.title, dueDay: task.dueDate, duePrayer: task.duePrayer,
                        duePrayerOffset: task.duePrayerOffset, isDone: task.isDone)
        }
        let plannerReminders = reminders.map { reminder in
            PlannerReminder(id: reminder.id, taskId: reminder.taskId,
                            kind: ReminderRecord.Kind(rawValue: reminder.kindRaw) ?? .time, at: reminder.at,
                            prayer: reminder.prayerRaw.flatMap(Prayer.init(rawValue:)), offsetMinutes: reminder.offsetMinutes)
        }
        let settings = session.user?.settings
        let formatter = DualDateFormatter(primary: settings?.calendar ?? .hijri, locale: ZimamLocale.current)
        return ReminderPlanner.plan(tasks: plannerTasks, reminders: plannerReminders,
                                    schedule: location.schedule(method: settings?.prayerMethod ?? .ummAlQura),
                                    now: Date(), formatter: formatter)
    }

    /// «إنجاز» completes the task; «تأجيل ساعة» adds a one-off reminder an hour from now.
    /// Both sync right away, since the app may be in the background.
    private func handle(action: String, taskId: UUID?) async {
        guard let taskId, let task = fetchTask(taskId) else { return }
        let store = Store(context: context, sync: sync)
        switch action {
        case Self.doneAction:
            if !task.isDone { store.toggleDone(task) }
        case Self.snoozeAction:
            store.addTimeReminder(to: task.id, at: Date().addingTimeInterval(3600))
        default:
            return
        }
        await sync.sync()
    }

    private func fetchTask(_ id: UUID) -> TaskItem? {
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

/// The notification center's delegate, kept apart so the observable scheduler stays a
/// plain class. Set at launch so actions work when the app starts in the background.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onAction: (@MainActor (String, UUID?) async -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let taskId = (response.notification.request.content.userInfo["taskId"] as? String).flatMap(UUID.init(uuidString:))
        let handler = onAction
        Task { @MainActor in
            await handler?(action, taskId)
            completionHandler()
        }
    }

    /// Shows reminders while the app is open too.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
